import AVFoundation
import Foundation
import Observation

/// Runs a recording: takes audio from the `AudioHub`, transcribes it live on the device and
/// writes the transcript into the note as it goes. When it stops, the note is free again
/// within seconds; the slower speaker work is handed to the `PostProcessor`.
@MainActor
@Observable
final class Recorder {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case recording
        case finishing(String)
    }

    private(set) var phase: Phase = .idle
    /// The note being recorded into.
    private(set) var noteID: UUID?
    private(set) var startedAt: Date?
    /// Words still being worked out, per speaker label.
    private(set) var volatileText: [String: String] = [:]
    /// Speaker labels in this recording, in display order.
    private(set) var speakers: [String] = []
    /// Mac: the call side seems blocked by macOS permissions.
    private(set) var callBlocked = false
    var errorMessage: String?
    var notice: String?
    /// Set when Apple's speech model must be downloaded before recording can start.
    var pendingModelDownload: Locale?
    /// Set when "Detect speakers" is on but the speaker pack isn't downloaded yet.
    var pendingSpeakerDownload = false
    private(set) var downloadProgress: Double = 0

    var isActive: Bool { phase != .idle }
    var isRecording: Bool { phase == .recording }
    var isFinishing: Bool {
        if case .finishing = phase { return true }
        return false
    }

    let hub: AudioHub
    let post: PostProcessor

    @ObservationIgnored private var pendingNoteID: UUID?
    @ObservationIgnored private var skipSpeakerPack = false
    @ObservationIgnored private var pipes: [AudioPipe] = []
    @ObservationIgnored private var offset: Double = 0
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var warnedSilentMic = false
    @ObservationIgnored private var loggedNoWords: Set<String> = []
    @ObservationIgnored private var lineCounts: [String: Int] = [:]
    @ObservationIgnored private var echo = EchoFilter()
    @ObservationIgnored private var echoesRemoved = 0
    /// Lines are accepted only for the recording that's running (late ones are dropped).
    @ObservationIgnored private var session: UUID?
    @ObservationIgnored private weak var store: NoteStore?

    init(hub: AudioHub, post: PostProcessor) {
        self.hub = hub
        self.post = post
        hub.onNotice = { [weak self] text in
            ActivityLog.add(text)
            if self?.isRecording == true { self?.notice = text }
        }
    }

    // MARK: Start

    func start(noteID: UUID, store: NoteStore) async {
        guard phase == .idle else { return }
        guard !post.isBusy(with: noteID) else {
            notice = "Sintr is still working on this note's last recording (\(post.message)). Press Skip to record right away."
            return
        }
        errorMessage = nil
        notice = nil
        callBlocked = false
        self.store = store
        phase = .preparing("Getting ready…")
        do {
            try await prepareAndStart(noteID: noteID, store: store)
        } catch {
            await abandon()
            phase = .idle
            if !(error is CancellationError) {
                ActivityLog.add("Recording didn't start: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
        }
    }

    /// The person agreed to download Apple's speech model; do that, then start recording.
    func downloadModelAndStart() async {
        guard let locale = pendingModelDownload, let noteID = pendingNoteID, let store else { return }
        pendingModelDownload = nil
        pendingNoteID = nil
        phase = .preparing("Downloading Apple's speech model…")
        downloadProgress = 0
        do {
            try await SpeechSupport.install(locale) { value in
                Task { @MainActor [weak self] in self?.downloadProgress = value }
            }
            phase = .idle
            await start(noteID: noteID, store: store)
        } catch {
            phase = .idle
            errorMessage = "The speech model didn't download: \(error.localizedDescription)"
        }
    }

    /// Answer to "Download speaker detection?": download it first, or record without it this time.
    func answerSpeakerDownload(download: Bool) async {
        guard let noteID = pendingNoteID, let store else { return }
        pendingSpeakerDownload = false
        pendingNoteID = nil
        if download {
            phase = .preparing("Downloading speaker detection…")
            downloadProgress = 0
            do {
                try await SpeakerDetector.download { value in
                    Task { @MainActor [weak self] in self?.downloadProgress = value }
                }
            } catch {
                notice = "Speaker detection didn't download (\(error.localizedDescription)). Recording without speaker labels."
                skipSpeakerPack = true
            }
            phase = .idle
        } else {
            skipSpeakerPack = true
        }
        await start(noteID: noteID, store: store)
    }

    private func prepareAndStart(noteID: UUID, store: NoteStore) async throws {
        guard SpeechSupport.deviceSupported else { throw SpeechError.deviceNotSupported }
        guard await MicCapture.requestPermission() else { throw SpeechError.microphoneDenied }
        guard let locale = await SpeechSupport.resolvedLocale() else { throw SpeechError.languageNotSupported }
        guard await SpeechSupport.isInstalled(locale) else {
            pendingModelDownload = locale  // The UI asks "Download speech model?"
            pendingNoteID = noteID
            throw CancellationError()
        }
        if AppSettings.shouldDetectSpeakers, SpeakerDetector.isAvailable, !SpeakerDetector.isInstalled, !skipSpeakerPack {
            pendingSpeakerDownload = true  // The UI asks "Download speaker detection?"
            pendingNoteID = noteID
            throw CancellationError()
        }

        var meeting = MeetingAudio.off
        #if os(macOS)
        meeting = AppSettings.meetingAudioChoice
        if meeting.isOn, SystemAudioPermission.canCheck, SystemAudioPermission.status != .allowed {
            phase = .preparing("Asking macOS for permission to hear calls…")
            if !(await SystemAudioPermission.request()) {
                callBlocked = true
                notice = "Recording your microphone only. To also record the other side of calls, allow Sintr in \(SystemAudioPermission.settingsPath), then record again."
                meeting = .off
            }
        }
        #endif

        // The hub is usually already listening (that's what drives the meters).
        phase = .preparing("Starting the microphone…")
        let running = await hub.ensureRunning(meeting: meeting)
        guard hub.micIsRunning else { throw SpeechError.noMicrophone }
        if meeting.isOn, !running.isOn {
            notice = "Recording your microphone only — call audio couldn't start. (Details: Help → Activity Log.)"
        }
        meeting = running

        let labels = meeting.isOn ? ["Me", "Them"] : [""]
        ActivityLog.add("Recording started: \(meeting.isOn ? "microphone + \(meeting.rawValue == "all" ? "all Mac audio" : meeting.rawValue)" : "microphone only"), language \(locale.identifier)")
        phase = .preparing("Starting transcription…")
        offset = store.note(noteID)?.duration ?? 0
        var newPipes: [AudioPipe] = []
        for label in labels {
            let transcriber = try await LiveTranscriber.make(locale: locale, speaker: label)
            // Audio is always saved while recording (speaker detection and re-transcribing need it);
            // if "Save audio" is off it's deleted afterwards.
            let fileURL = store.recordingURL(store.newRecordingName(for: noteID, speaker: label))
            newPipes.append(AudioPipe(transcriber: transcriber, saveTo: fileURL))
        }
        pipes = newPipes

        let session = UUID()
        self.session = session
        echo = EchoFilter()
        echoesRemoved = 0
        lineCounts = [:]
        loggedNoWords = []
        for pipe in newPipes {
            let label = pipe.transcriber.speaker
            let startOffset = offset
            try await pipe.transcriber.start(
                volatile: { text in
                    Task { @MainActor [weak self] in
                        guard let self, self.session == session else { return }
                        self.volatileText[label] = text
                    }
                },
                final: { start, end, text in
                    Task { @MainActor [weak self] in
                        self?.addLine(label: label, start: startOffset + start, end: startOffset + end,
                                      text: text, noteID: noteID, session: session)
                    }
                },
                failed: { error in
                    Task { @MainActor [weak self] in
                        guard let self, self.session == session else { return }
                        self.notice = "Live transcription stopped (\(error.localizedDescription)). The audio is still being saved, and the transcript is rebuilt from it when you stop."
                    }
                })
        }
        speakers = labels
        self.noteID = noteID

        let micPipe = newPipes[0]
        var callSink: (@Sendable (AVAudioPCMBuffer) -> Void)?
        if newPipes.count > 1 {
            let callPipe = newPipes[1]
            callSink = { buffer in callPipe.process(buffer) }
        }
        hub.beginRecording(micSink: { buffer in micPipe.process(buffer) }, callSink: callSink)

        startedAt = Date()
        warnedSilentMic = false
        phase = .recording
        startChecks()
    }

    // MARK: Stop

    func stop() async {
        guard phase == .recording, let noteID, let store else { return }
        phase = .finishing("Finishing the transcript…")
        checkTask?.cancel()
        let pipes = self.pipes

        // Stop taking audio (the meters keep going on the Mac), then let the speech engine
        // finish its last words — never for long.
        hub.endRecording()
        for pipe in pipes { pipe.finish() }
        await withTaskGroup(of: Void.self) { group in
            for pipe in pipes {
                let transcriber = pipe.transcriber
                group.addTask { await transcriber.finish(within: .seconds(12)) }
            }
        }
        try? await Task.sleep(for: .milliseconds(200))  // Let the last lines land.
        session = nil

        let recorded = pipes.map(\.seconds).max() ?? 0
        let sessionOffset = offset
        var saved: [NoteRecording] = []
        for pipe in pipes {
            guard let url = pipe.fileURL else { continue }
            if pipe.seconds > 0.5 {
                saved.append(NoteRecording(fileName: url.lastPathComponent, speaker: pipe.transcriber.speaker, offset: sessionOffset))
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }

        // A call side that never carried sound only adds an empty track.
        if let callPipe = pipes.first(where: { $0.transcriber.speaker == "Them" }), !callPipe.heardSound {
            if let them = saved.firstIndex(where: { $0.speaker == "Them" }) {
                try? FileManager.default.removeItem(at: store.recordingURL(saved[them].fileName))
                saved.remove(at: them)
            }
            if let me = saved.firstIndex(where: { $0.speaker == "Me" }) { saved[me].speaker = "" }
            store.edit(noteID) { note in
                for index in note.transcript.indices
                where note.transcript[index].start >= sessionOffset - 0.5 && note.transcript[index].speaker == "Me" {
                    note.transcript[index].speaker = ""
                }
            }
            #if os(macOS)
            let blocked = SystemAudioPermission.canCheck && SystemAudioPermission.status != .allowed
            notice = blocked
                ? "Sintr didn't hear the other side of the call — macOS gave it silence. Allow Sintr in \(SystemAudioPermission.settingsPath), then record again."
                : "Sintr didn't hear any call audio during this recording, so it's labeled as an in-person recording."
            callBlocked = blocked
            #endif
        }
        store.edit(noteID) { note in
            note.duration = max(note.duration, sessionOffset + recorded)
            note.recordings += saved
        }
        store.saveNow()
        let summary = pipes.map { "\($0.transcriber.speaker.isEmpty ? "mic" : $0.transcriber.speaker) \(lineCounts[$0.transcriber.speaker] ?? 0) lines" }
        ActivityLog.add("Recording stopped after \(Int(recorded)) s: \(summary.joined(separator: ", "))\(echoesRemoved > 0 ? ", \(echoesRemoved) echoed lines dropped" : "")")

        // The note is free again; the rest happens in the background.
        tearDown()
        phase = .idle

        let detect = AppSettings.shouldDetectSpeakers && SpeakerDetector.isInstalled
        let bothSides = saved.contains { $0.speaker == "Me" } && saved.contains { $0.speaker == "Them" }
        let deleteAfter = AppSettings.shouldKeepRecordings ? [] : saved.map(\.fileName)
        if !saved.isEmpty, detect || (bothSides && AppSettings.shouldRemoveEcho) {
            post.enqueue(PostProcessor.Job(
                noteID: noteID, onlyFrom: sessionOffset, detectSpeakers: detect,
                title: detect ? "Detecting speakers" : "Tidying the transcript",
                deleteAfter: deleteAfter), store: store)
        } else if !deleteAfter.isEmpty {
            for name in deleteAfter { try? FileManager.default.removeItem(at: store.recordingURL(name)) }
            let names = Set(deleteAfter)
            store.edit(noteID) { $0.recordings.removeAll { names.contains($0.fileName) } }
            store.saveNow()
        }
    }

    // MARK: While recording

    private func addLine(label: String, start: Double, end: Double, text: String, noteID: UUID, session: UUID) {
        guard self.session == session, let store else { return }  // A late line from a recording that's over.
        let segment = TranscriptSegment(speaker: label, start: start, text: text)
        if AppSettings.shouldRemoveEcho, speakers.count == 2 {
            if label == "Me" {
                if echo.addMine(id: segment.id, start: start, end: end, text: text) {
                    echoesRemoved += 1
                    return
                }
            } else {
                let echoes = Set(echo.addTheirs(id: segment.id, start: start, end: end, text: text))
                if !echoes.isEmpty {
                    echoesRemoved += echoes.count
                    lineCounts["Me", default: 0] -= echoes.count
                    store.edit(noteID) { $0.transcript.removeAll { echoes.contains($0.id) } }
                }
            }
        }
        lineCounts[label, default: 0] += 1
        store.edit(noteID) { note in
            note.transcript.append(segment)
            note.transcript.sort { $0.start < $1.start }
        }
    }

    private func startChecks() {
        checkTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.checkSignals()
            }
        }
    }

    /// Warns about a silent microphone, notices a blocked call side, and notes in the
    /// Activity Log when a source carries sound but no words come out.
    private func checkSignals() {
        guard let started = startedAt, let micPipe = pipes.first else { return }
        let elapsed = Date().timeIntervalSince(started)
        if elapsed > 6, !micPipe.heardSound, !warnedSilentMic {
            warnedSilentMic = true
            ActivityLog.add("Microphone: silent for the first 6 s")
            notice = Platform.isMac
                ? "Your microphone sounds silent. It may be muted, or a different microphone may be selected — check Settings → Recording → Microphone."
                : "Your microphone sounds silent. Check that nothing is covering it and that Sintr is allowed to use it."
        }
        #if os(macOS)
        if hub.callState == .notAllowed, elapsed > 10 { callBlocked = true }
        if hub.callState == .hearing { callBlocked = false }
        #endif
        for pipe in pipes {
            let label = pipe.transcriber.speaker
            if pipe.heardSound, pipe.seconds > 45, (lineCounts[label] ?? 0) == 0,
               (volatileText[label] ?? "").isEmpty, !loggedNoWords.contains(label) {
                loggedNoWords.insert(label)
                ActivityLog.add("\(label.isEmpty ? "Microphone" : label): \(Int(pipe.seconds)) s of audio with sound, but no words recognized yet")
            }
        }
    }

    /// Undo a start that failed partway.
    private func abandon() async {
        session = nil
        hub.endRecording()
        for pipe in pipes {
            pipe.finish()
            await pipe.transcriber.finish(within: .seconds(4))
            if let url = pipe.fileURL { try? FileManager.default.removeItem(at: url) }
        }
        tearDown()
    }

    private func tearDown() {
        checkTask?.cancel()
        checkTask = nil
        pipes = []
        noteID = nil
        startedAt = nil
        volatileText = [:]
        speakers = []
    }
}
