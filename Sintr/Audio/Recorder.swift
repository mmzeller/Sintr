import AVFoundation
import Foundation
import Observation

/// Runs a recording: captures audio, transcribes it live on the device, writes the transcript
/// into the note as it goes, and labels speakers when it stops.
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
    /// The note being recorded into (or finished).
    private(set) var noteID: UUID?
    private(set) var startedAt: Date?
    /// Words still being worked out, per speaker label.
    private(set) var volatileText: [String: String] = [:]
    private(set) var levels: [String: Float] = [:]
    /// Speaker labels in this recording, in display order.
    private(set) var speakers: [String] = []
    /// Mac: a short line about the other side of the call ("Hearing FaceTime", "Waiting for Teams…").
    private(set) var callStatus: String?
    /// Mac: the call side seems blocked by macOS permissions.
    private(set) var callBlocked = false
    private(set) var progress: Double = 0
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

    @ObservationIgnored private var pendingNoteID: UUID?
    @ObservationIgnored private var skipSpeakerPack = false
    @ObservationIgnored private var mic: MicCapture?
    #if os(macOS)
    @ObservationIgnored private var callAudio: SystemAudioCapture?
    #endif
    @ObservationIgnored private var pipes: [AudioPipe] = []
    @ObservationIgnored private var offset: Double = 0
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var warnedSilentMic = false
    @ObservationIgnored private weak var store: NoteStore?

    // MARK: Start

    func start(noteID: UUID, store: NoteStore) async {
        guard phase == .idle else { return }
        errorMessage = nil
        notice = nil
        callBlocked = false
        callStatus = nil
        self.store = store
        phase = .preparing("Getting ready…")
        do {
            try await prepareAndStart(noteID: noteID, store: store)
        } catch {
            await abandon()
            phase = .idle
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
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
        let labels = meeting.isOn ? ["Me", "Them"] : [""]

        offset = store.note(noteID)?.duration ?? 0
        var newPipes: [AudioPipe] = []
        for label in labels {
            let transcriber = try await LiveTranscriber.make(locale: locale, speaker: label)
            // Audio is always saved while recording (speaker detection and re-transcribing need it);
            // if "Save audio" is off it's deleted when you stop.
            let fileURL = store.recordingURL(store.newRecordingName(for: noteID, speaker: label))
            newPipes.append(AudioPipe(transcriber: transcriber, saveTo: fileURL))
        }
        pipes = newPipes

        for pipe in newPipes {
            let label = pipe.transcriber.speaker
            let startOffset = offset
            try await pipe.transcriber.start(
                volatile: { text in
                    Task { @MainActor [weak self] in self?.volatileText[label] = text }
                },
                final: { start, text in
                    Task { @MainActor [weak self] in
                        self?.addSegment(
                            TranscriptSegment(speaker: label, start: startOffset + start, text: text), to: noteID)
                    }
                },
                failed: { error in
                    Task { @MainActor [weak self] in
                        self?.notice = "Live transcription stopped (\(error.localizedDescription)). The audio is still being saved — the transcript is rebuilt from it when you stop."
                    }
                })
        }
        speakers = labels
        self.noteID = noteID

        // Microphone
        let mic = MicCapture()
        let micPipe = newPipes[0]
        mic.onInterruption = { [weak self] resumed in
            self?.notice = resumed
                ? "Recording resumed after an interruption."
                : "Recording paused by another app (a call or Siri). It continues when that ends."
        }
        try mic.start { buffer in micPipe.process(buffer) }
        self.mic = mic

        // The other side of the call (Mac)
        #if os(macOS)
        if meeting.isOn, newPipes.count > 1 {
            let callPipe = newPipes[1]
            let capture = SystemAudioCapture(source: meeting)
            do {
                try capture.start { buffer in callPipe.process(buffer) }
                callAudio = capture
            } catch {
                notice = "Recording your microphone only — \(error.localizedDescription)"
            }
        }
        #endif

        startedAt = Date()
        warnedSilentMic = false
        phase = .recording
        startMonitoring()
    }

    // MARK: Stop

    func stop() async {
        guard phase == .recording, let noteID, let store else { return }
        phase = .finishing("Finishing the transcript…")
        progress = 0
        meterTask?.cancel()

        mic?.stop()
        #if os(macOS)
        callAudio?.stop()
        #endif
        for pipe in pipes { pipe.finish() }
        for pipe in pipes { await pipe.transcriber.finish() }
        await Task.yield()  // Let the last transcript updates land.

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
        #if os(macOS)
        if let call = callAudio, !call.signal.heardSound {
            if let them = saved.firstIndex(where: { $0.speaker == "Them" }) {
                try? FileManager.default.removeItem(at: store.recordingURL(saved[them].fileName))
                saved.remove(at: them)
            }
            if let me = saved.firstIndex(where: { $0.speaker == "Me" }) { saved[me].speaker = "" }
            store.edit(noteID) { note in
                for index in note.transcript.indices
                where note.transcript[index].start >= sessionOffset && note.transcript[index].speaker == "Me" {
                    note.transcript[index].speaker = ""
                }
            }
            notice = callBlocked || SystemAudioPermission.status != .allowed
                ? "Sintr didn't hear the other side of the call — macOS gave it silence. Allow Sintr in \(SystemAudioPermission.settingsPath), then record again."
                : "Sintr didn't hear any call audio during this recording, so it's labeled as an in-person recording."
            callBlocked = SystemAudioPermission.status != .allowed
        }
        #endif
        store.edit(noteID) { note in
            note.duration = max(note.duration, sessionOffset + recorded)
            note.recordings += saved
        }
        store.saveNow()

        // Label speakers from the saved audio. For calls this also removes the other side's
        // voice where the microphone picked it up from the speakers.
        let detect = AppSettings.shouldDetectSpeakers && SpeakerDetector.isInstalled
        let bothSides = saved.contains { $0.speaker == "Me" } && saved.contains { $0.speaker == "Them" }
        if !saved.isEmpty, detect || bothSides {
            phase = .finishing(detect ? "Detecting speakers…" : "Tidying the transcript…")
            do {
                try await SpeakerPass.run(noteID: noteID, store: store, onlyFrom: sessionOffset, detectSpeakers: detect) { update in
                    Task { @MainActor [weak self] in
                        self?.phase = .finishing(update.message)
                        self?.progress = update.fraction
                    }
                }
            } catch {
                notice = "Couldn't detect speakers: \(error.localizedDescription)"
            }
        }

        if !AppSettings.shouldKeepRecordings {
            for recording in saved { try? FileManager.default.removeItem(at: store.recordingURL(recording.fileName)) }
            let names = Set(saved.map(\.fileName))
            store.edit(noteID) { $0.recordings.removeAll { names.contains($0.fileName) } }
        }
        store.saveNow()
        tearDown()
        phase = .idle
    }

    // MARK: While recording

    private func addSegment(_ segment: TranscriptSegment, to noteID: UUID) {
        guard let store else { return }
        store.edit(noteID) { note in
            note.transcript.append(segment)
            note.transcript.sort { $0.start < $1.start }
        }
    }

    private func startMonitoring() {
        meterTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                var values: [String: Float] = [:]
                for pipe in self.pipes { values[pipe.transcriber.speaker] = pipe.level }
                self.levels = values
                if tick % 8 == 0 { self.checkSignals() }
                tick += 1
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    /// Warns about a silent microphone and reports how the call side is doing.
    private func checkSignals() {
        guard let started = startedAt, let micPipe = pipes.first else { return }
        let elapsed = Date().timeIntervalSince(started)
        if elapsed > 6, !micPipe.heardSound, !warnedSilentMic {
            warnedSilentMic = true
            notice = Platform.isMac
                ? "Your microphone sounds silent. It may be muted, or a different microphone may be selected — check Settings → Recording → Microphone."
                : "Your microphone sounds silent. Check that nothing is covering it and that Sintr is allowed to use it."
        }
        #if os(macOS)
        guard let call = callAudio else { callStatus = nil; return }
        let signal = call.signal
        let name: String
        switch call.source {
        case .app(let id): name = MeetingApps.displayName(for: id)
        default: name = "Mac audio"
        }
        if signal.waitingForApp {
            callStatus = "Waiting for \(name) to play sound…"
        } else if signal.heardSound && signal.secondsSinceSound < 4 {
            callStatus = "Hearing \(name)"
            callBlocked = false
        } else if !signal.heardSound && elapsed > 20 && micPipe.heardSound {
            callStatus = "Not hearing the call yet"
            if SystemAudioPermission.status != .allowed { callBlocked = true }
        } else {
            callStatus = "Listening to \(name)"
        }
        #endif
    }

    /// Undo a start that failed partway.
    private func abandon() async {
        mic?.stop()
        #if os(macOS)
        callAudio?.stop()
        #endif
        for pipe in pipes {
            pipe.finish()
            await pipe.transcriber.finish()
            if let url = pipe.fileURL { try? FileManager.default.removeItem(at: url) }
        }
        tearDown()
    }

    private func tearDown() {
        meterTask?.cancel()
        meterTask = nil
        mic = nil
        #if os(macOS)
        callAudio = nil
        #endif
        pipes = []
        noteID = nil
        startedAt = nil
        volatileText = [:]
        levels = [:]
        speakers = []
        callStatus = nil
        progress = 0
    }
}
