import AVFoundation
import Foundation
import Observation

/// Runs a recording: captures audio, transcribes it live on the device, and writes the
/// transcript into the note as it goes.
@MainActor
@Observable
final class Recorder {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case recording
        case finishing
    }

    private(set) var phase: Phase = .idle
    /// The note being recorded into.
    private(set) var noteID: UUID?
    private(set) var startedAt: Date?
    /// Words still being worked out, per speaker label.
    private(set) var volatileText: [String: String] = [:]
    private(set) var levels: [String: Float] = [:]
    /// Speaker labels in this recording, in display order.
    private(set) var speakers: [String] = []
    var errorMessage: String?
    var notice: String?
    /// Set when the speech model must be downloaded before recording can start.
    var pendingModelDownload: Locale?
    @ObservationIgnored private var pendingNoteID: UUID?
    private(set) var downloadProgress: Double = 0

    var isActive: Bool { phase != .idle }
    var isRecording: Bool { phase == .recording }

    @ObservationIgnored private var mic: MicCapture?
    #if os(macOS)
    @ObservationIgnored private var callAudio: SystemAudioCapture?
    #endif
    @ObservationIgnored private var pipes: [AudioPipe] = []
    @ObservationIgnored private var offset: Double = 0
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private weak var store: NoteStore?

    // MARK: Start

    func start(noteID: UUID, store: NoteStore) async {
        guard phase == .idle else { return }
        errorMessage = nil
        notice = nil
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

    /// The person agreed to download the speech model; do that, then start recording.
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

    private func prepareAndStart(noteID: UUID, store: NoteStore) async throws {
        guard SpeechSupport.deviceSupported else { throw SpeechError.deviceNotSupported }
        guard await MicCapture.requestPermission() else { throw SpeechError.microphoneDenied }
        guard let locale = await SpeechSupport.resolvedLocale() else { throw SpeechError.languageNotSupported }
        guard await SpeechSupport.isInstalled(locale) else {
            // Ask first: the UI shows a "Download speech model?" prompt.
            pendingModelDownload = locale
            pendingNoteID = noteID
            throw CancellationError()
        }

        var wantCallAudio = false
        #if os(macOS)
        wantCallAudio = AppSettings.shouldCaptureCallAudio
        #endif
        let labels = wantCallAudio ? ["Me", "Them"] : [""]

        offset = store.note(noteID)?.duration ?? 0
        var newPipes: [AudioPipe] = []
        for label in labels {
            let transcriber = try await LiveTranscriber.make(locale: locale, speaker: label)
            // Audio is always saved while recording (so a stalled live transcript can be redone);
            // if "Keep recordings" is off it's deleted when you stop.
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
                        self?.notice = "Live transcription stopped (\(error.localizedDescription)). The audio is still being saved — use Re-transcribe afterwards."
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

        // Call audio (Mac)
        #if os(macOS)
        if wantCallAudio, newPipes.count > 1 {
            let callPipe = newPipes[1]
            let capture = SystemAudioCapture()
            do {
                try capture.start { buffer in callPipe.process(buffer) }
                callAudio = capture
            } catch {
                notice = "Recording your microphone only — \(error.localizedDescription)"
            }
        }
        #endif

        startedAt = Date()
        phase = .recording
        startMeters()
    }

    // MARK: Stop

    func stop() async {
        guard phase == .recording, let noteID, let store else { return }
        phase = .finishing
        meterTask?.cancel()

        mic?.stop()
        #if os(macOS)
        callAudio?.stop()
        #endif
        for pipe in pipes { pipe.finish() }
        for pipe in pipes { await pipe.transcriber.finish() }
        // Let the last transcript updates land.
        await Task.yield()

        let recorded = pipes.map(\.seconds).max() ?? 0
        let keep = AppSettings.shouldKeepRecordings
        var saved: [NoteRecording] = []
        for pipe in pipes {
            guard let url = pipe.fileURL else { continue }
            if keep, pipe.seconds > 0.5 {
                saved.append(NoteRecording(fileName: url.lastPathComponent, speaker: pipe.transcriber.speaker, offset: offset))
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        store.edit(noteID) { note in
            note.duration = max(note.duration, self.offset + recorded)
            note.recordings += saved
        }
        store.saveNow()
        tearDown()
        phase = .idle
    }

    // MARK: Helpers

    private func addSegment(_ segment: TranscriptSegment, to noteID: UUID) {
        guard let store else { return }
        store.edit(noteID) { note in
            note.transcript.append(segment)
            note.transcript.sort { $0.start < $1.start }
        }
    }

    private func startMeters() {
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                var values: [String: Float] = [:]
                for pipe in self.pipes { values[pipe.transcriber.speaker] = pipe.level }
                self.levels = values
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
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
    }
}
