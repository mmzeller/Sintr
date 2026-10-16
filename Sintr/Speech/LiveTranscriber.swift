import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Turns one live audio source (your microphone, or call audio on the Mac) into text,
/// entirely on the device, using Apple's SpeechAnalyzer.
final class LiveTranscriber: @unchecked Sendable {
    let speaker: String
    /// The audio format the speech model wants. Feed only buffers in this format.
    let format: AVAudioFormat

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Never>?
    private var started = false

    private init(speaker: String, format: AVAudioFormat, transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer) {
        self.speaker = speaker
        self.format = format
        self.transcriber = transcriber
        self.analyzer = analyzer
        let pair = AsyncStream.makeStream(of: AnalyzerInput.self)
        input = pair.stream
        inputContinuation = pair.continuation
    }

    static func make(locale: Locale, speaker: String) async throws -> LiveTranscriber {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechError.noAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        return LiveTranscriber(speaker: speaker, format: format, transcriber: transcriber, analyzer: analyzer)
    }

    /// Starts listening. `volatile` gets the words still being worked out (shown greyed),
    /// `final` gets each finished stretch of speech with its time from the start of this recording.
    func start(
        volatile: @escaping @Sendable (String) -> Void,
        final: @escaping @Sendable (Double, String) -> Void,
        failed: @escaping @Sendable (Error) -> Void
    ) async throws {
        let transcriber = self.transcriber
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        volatile("")
                        guard !text.isEmpty else { continue }
                        let start = result.text.runs.compactMap(\.audioTimeRange).first?.start.seconds ?? 0
                        final(start.isFinite ? start : 0, text)
                    } else {
                        volatile(text)
                    }
                }
            } catch {
                if !(error is CancellationError) { failed(error) }
            }
        }
        try await analyzer.start(inputSequence: input)
        started = true
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        inputContinuation.yield(AnalyzerInput(buffer: buffer))
    }

    /// Lets the model finish the last words, then stops.
    func finish() async {
        inputContinuation.finish()
        guard started else {
            resultsTask?.cancel()
            return
        }
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
        }
        await resultsTask?.value
    }
}

/// One recognized word (or word piece) and when it was said, in seconds from the start of the file.
struct TimedWord: Sendable {
    var start: Double
    var end: Double
    /// Includes any leading space, so words can be joined back together as-is.
    var text: String
}

/// Transcribes a saved audio file (a recording, or one you imported).
enum FileTranscriber {
    /// Transcribes with a time for every word — used to work out who said what.
    static func words(
        url: URL,
        locale: Locale,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TimedWord] {
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let length = Double(file.length) / file.processingFormat.sampleRate
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)

        var words: [TimedWord] = []
        for try await result in transcriber.results {
            try Task.checkCancellation()
            let text = result.text
            for run in text.runs {
                let piece = String(text[run.range].characters)
                guard !piece.isEmpty else { continue }
                if let range = run.audioTimeRange, range.start.seconds.isFinite, range.end.seconds.isFinite {
                    words.append(TimedWord(start: range.start.seconds, end: range.end.seconds, text: piece))
                } else if !words.isEmpty {
                    words[words.count - 1].text += piece  // punctuation and spacing without a time
                }
            }
            // Keep a space between consecutive results.
            if let last = words.last, !last.text.hasSuffix(" ") { words[words.count - 1].text += " " }
            if length > 0 {
                let done = result.resultsFinalizationTime.seconds / length
                if done.isFinite { progress(min(max(done, 0), 1)) }
            }
        }
        progress(1)
        return words
    }

    static func transcribe(
        url: URL,
        locale: Locale,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [(start: Double, text: String)] {
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let length = Double(file.length) / file.processingFormat.sampleRate
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)

        var pieces: [(start: Double, text: String)] = []
        for try await result in transcriber.results {
            try Task.checkCancellation()
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let start = result.text.runs.compactMap(\.audioTimeRange).first?.start.seconds ?? 0
                pieces.append((start.isFinite ? start : 0, text))
            }
            if length > 0 {
                let done = result.resultsFinalizationTime.seconds / length
                if done.isFinite { progress(min(max(done, 0), 1)) }
            }
        }
        progress(1)
        return pieces
    }
}
