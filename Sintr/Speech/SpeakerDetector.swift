import Foundation
#if canImport(FluidAudio)
import FluidAudio
#endif

/// One stretch of a recording and which voice it belongs to.
struct VoiceTurn: Sendable {
    var speaker: String
    var start: Double
    var end: Double
}

/// Works out who spoke when ("speaker diarization"), entirely on the device, using the open
/// FluidAudio models (pyannote segmentation + WeSpeaker voice fingerprints).
/// The models (a few dozen MB) are downloaded once from Hugging Face, only when you ask.
enum SpeakerDetector {
    static var modelsFolder: URL {
        let folder = Storage.root.appendingPathComponent("Models/SpeakerDetection", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var copy = folder
        try? copy.setResourceValues(values)
        return folder
    }

    private static var marker: URL { modelsFolder.appendingPathComponent(".sintr-ready") }

    static var isAvailable: Bool {
        #if canImport(FluidAudio)
        true
        #else
        false
        #endif
    }

    static var isInstalled: Bool { isAvailable && FileManager.default.fileExists(atPath: marker.path) }

    static var sizeOnDisk: Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: modelsFolder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Never let the library reach the network except during an explicit download.
    static func blockNetwork() {
        #if canImport(FluidAudio)
        ModelHub.offlineMode = true
        #endif
    }

    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        #if canImport(FluidAudio)
        ModelHub.offlineMode = false
        defer { ModelHub.offlineMode = true }
        _ = try await OfflineDiarizerModels.load(from: modelsFolder) { update in
            progress(update.fractionCompleted)
        }
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        #else
        throw SpeakerError.notBuiltIn
        #endif
    }

    static func delete() {
        try? FileManager.default.removeItem(at: modelsFolder)
    }

    /// Who spoke when in one audio file, plus a voice fingerprint for each speaker (used to
    /// recognize the same voice across several recordings in one note).
    static func turns(in url: URL, progress: @escaping @Sendable (Double) -> Void) async throws
        -> (turns: [VoiceTurn], voices: [String: [Float]])
    {
        #if canImport(FluidAudio)
        guard isInstalled else { throw SpeakerError.notInstalled }
        blockNetwork()
        let models = try await OfflineDiarizerModels.load(from: modelsFolder)
        let manager = OfflineDiarizerManager(config: .default)
        manager.initialize(models: models)
        let result = try await manager.process(url) { done, total in
            if total > 0 { progress(Double(done) / Double(total)) }
        }
        let turns = result.segments.map {
            VoiceTurn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
        return (turns.sorted { $0.start < $1.start }, result.speakerDatabase ?? [:])
        #else
        throw SpeakerError.notBuiltIn
        #endif
    }
}

enum SpeakerError: LocalizedError {
    case notInstalled, notBuiltIn, noAudio

    var errorDescription: String? {
        switch self {
        case .notInstalled: "The speaker detection pack isn't downloaded yet. Download it in Settings → Speakers."
        case .notBuiltIn: "This build of Sintr doesn't include speaker detection."
        case .noAudio: "This note has no saved audio to detect speakers in. (Turn on “Save audio” before recording.)"
        }
    }
}

/// Rebuilds a note's transcript from its saved audio with a speaker on every line.
///
/// - Meeting recordings: your microphone is "Me". The call side is "Them" — or "Them 1",
///   "Them 2"… when several voices are heard. Where your microphone also picked up the call
///   from your speakers, those duplicate words are dropped from "Me".
/// - In-person recordings: "Speaker 1", "Speaker 2"…
/// The same voice keeps the same label across several recordings in one note.
enum SpeakerPass {
    struct Progress: Sendable {
        var message: String
        var fraction: Double
    }

    struct Track: Sendable {
        var url: URL
        var speaker: String
        var offset: Double
    }

    /// - Parameter onlyFrom: rebuild just the recording that started at this point in the note
    ///   (after "Record more"); nil rebuilds everything that has audio.
    @MainActor
    static func run(noteID: UUID, store: NoteStore, onlyFrom: Double? = nil, detectSpeakers: Bool,
                    progress: @escaping @Sendable (Progress) -> Void) async throws {
        guard let note = store.note(noteID) else { return }
        let chosen = note.recordings.filter { onlyFrom == nil || abs($0.offset - onlyFrom!) < 0.001 }
        guard !chosen.isEmpty else { throw SpeakerError.noAudio }
        guard let locale = await SpeechSupport.resolvedLocale() else { throw SpeechError.languageNotSupported }
        guard await SpeechSupport.isInstalled(locale) else { throw ImportError.needsSpeechModel }
        let tracks = chosen.map { Track(url: store.recordingURL($0.fileName), speaker: $0.speaker, offset: $0.offset) }
        let detect = detectSpeakers && SpeakerDetector.isInstalled

        let (segments, prints) = try await build(tracks: tracks, locale: locale, detectSpeakers: detect,
                                                 knownVoices: note.voicePrints, progress: progress)

        store.edit(noteID) { note in
            // Replace only the parts of the transcript that came from these recordings (a part
            // recorded without saved audio stays as it was).
            let starts = Set(chosen.map(\.offset))
            let allStarts = Set(note.recordings.map(\.offset)).sorted()
            let ranges = starts.map { start in
                (start - 0.5, allStarts.first { $0 > start + 0.001 } ?? .infinity)
            }
            note.transcript.removeAll { segment in ranges.contains { segment.start >= $0.0 && segment.start < $0.1 } }
            note.transcript += segments
            note.transcript.sort { $0.start < $1.start }
            note.voicePrints.merge(prints) { _, new in new }
            normalizeCallLabels(&note)
        }
        store.saveNow()
    }

    /// "Them 1" is shown as plain "Them" while only one voice has been heard on the call side.
    private static func normalizeCallLabels(_ note: inout Note) {
        let several = note.transcript.contains { $0.speaker.hasPrefix("Them ") && $0.speaker != "Them 1" }
        let from = several ? "Them" : "Them 1"
        let to = several ? "Them 1" : "Them"
        for index in note.transcript.indices where note.transcript[index].speaker == from {
            note.transcript[index].speaker = to
        }
        if let name = note.speakerNames[from], note.speakerNames[to] == nil {
            note.speakerNames[to] = name
            note.speakerNames[from] = nil
        }
    }

    private static func build(
        tracks: [Track],
        locale: Locale,
        detectSpeakers: Bool,
        knownVoices: [String: [Float]],
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws -> (segments: [TranscriptSegment], voices: [String: [Float]]) {
        var callVoices = knownVoices.filter { $0.key.hasPrefix("Them") }.sorted { $0.key < $1.key }.map { (label: $0.key, voice: $0.value) }
        var roomVoices = knownVoices.filter { $0.key.hasPrefix("Speaker") }.sorted { $0.key < $1.key }.map { (label: $0.key, voice: $0.value) }
        var newPrints: [String: [Float]] = [:]
        var labeled: [(word: TimedWord, label: String)] = []
        let diarized = tracks.filter { detectSpeakers && $0.speaker != "Me" }.count
        let steps = Double(tracks.count + diarized)
        var step = 0.0

        for (index, track) in tracks.enumerated() {
            let part = tracks.count > 1 ? " (\(index + 1) of \(tracks.count))" : ""
            let base = step
            let words = try await FileTranscriber.words(url: track.url, locale: locale) { fraction in
                progress(Progress(message: "Transcribing\(part)…", fraction: (base + fraction) / steps))
            }
            step += 1
            func shifted(_ word: TimedWord) -> TimedWord {
                var copy = word
                copy.start += track.offset
                copy.end += track.offset
                return copy
            }

            // Your own microphone in a meeting, or speaker detection off: one label for the whole file.
            guard detectSpeakers, track.speaker != "Me" else {
                let label = track.speaker == "Them" ? "Them 1" : track.speaker
                labeled += words.map { (word: shifted($0), label: label) }
                continue
            }

            let detectBase = step
            let (turns, voices) = try await SpeakerDetector.turns(in: track.url) { fraction in
                progress(Progress(message: "Detecting speakers\(part)…", fraction: (detectBase + fraction) / steps))
            }
            step += 1

            // Voices heard only for a moment (a cough, crosstalk) are folded into whoever was
            // talking around them rather than becoming a speaker of their own.
            var talkTime: [String: Double] = [:]
            for turn in turns { talkTime[turn.speaker, default: 0] += turn.end - turn.start }
            let total = talkTime.values.reduce(0, +)
            let minor = Set(talkTime.filter { $0.value < 8 && $0.value < total * 0.04 }.keys)
            let turns = minor.count < talkTime.count ? turns.filter { !minor.contains($0.speaker) } : turns

            // Give each voice in this file a note-wide label, reusing labels for voices heard before.
            let isCall = track.speaker == "Them"
            var mapping: [String: String] = [:]
            let order = turns.reduce(into: [String]()) { if !$0.contains($1.speaker) { $0.append($1.speaker) } }
            for id in order {
                let voice = voices[id] ?? []
                var known = isCall ? callVoices : roomVoices
                if let match = bestMatch(for: voice, in: known, excluding: Set(mapping.values)) {
                    mapping[id] = match
                } else {
                    let label = "\(isCall ? "Them" : "Speaker") \(known.count + 1)"
                    known.append((label: label, voice: voice))
                    mapping[id] = label
                }
                if !voice.isEmpty { newPrints[mapping[id]!] = voice }
                if isCall { callVoices = known } else { roomVoices = known }
            }
            let fallback = isCall ? "Them 1" : "Speaker 1"
            for word in words {
                let id = speaker(at: word, in: turns)
                labeled.append((word: shifted(word), label: id.flatMap { mapping[$0] } ?? fallback))
            }
        }

        labeled.sort { $0.word.start < $1.word.start }
        labeled = removeEcho(labeled)
        progress(Progress(message: "Putting the transcript together…", fraction: 1))
        return (group(labeled), newPrints)
    }

    /// Without headphones, the microphone also hears the call through the speakers, so the
    /// other side's words show up twice — once as theirs and once as "Me". Drop the "Me" copies:
    /// a "Me" word that matches a call-side word said within about a second.
    private static func removeEcho(_ words: [(word: TimedWord, label: String)]) -> [(word: TimedWord, label: String)] {
        let call = words.filter { $0.label.hasPrefix("Them") }.map { (time: $0.word.start, key: normalized($0.word.text)) }
        guard !call.isEmpty, words.contains(where: { $0.label == "Me" }) else { return words }
        var low = 0
        return words.filter { entry in
            guard entry.label == "Me" else { return true }
            let key = normalized(entry.word.text)
            guard key.count > 1 else { return true }
            let time = entry.word.start
            while low < call.count && call[low].time < time - 1.2 { low += 1 }
            var index = low
            while index < call.count && call[index].time <= time + 1.2 {
                if call[index].key == key { return false }
                index += 1
            }
            return true
        }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The voice talking during most of this word (or the nearest voice, in a gap).
    private static func speaker(at word: TimedWord, in turns: [VoiceTurn]) -> String? {
        var best: (id: String, overlap: Double)?
        for turn in turns where turn.end > word.start && turn.start < word.end {
            let overlap = min(turn.end, word.end) - max(turn.start, word.start)
            if overlap > (best?.overlap ?? 0) { best = (turn.speaker, overlap) }
        }
        if let best { return best.id }
        let middle = (word.start + word.end) / 2
        return turns.min { distance(middle, $0) < distance(middle, $1) }?.speaker
    }

    private static func distance(_ time: Double, _ turn: VoiceTurn) -> Double {
        time < turn.start ? turn.start - time : (time > turn.end ? time - turn.end : 0)
    }

    private static func bestMatch(for voice: [Float], in known: [(label: String, voice: [Float])],
                                  excluding used: Set<String>) -> String? {
        guard !voice.isEmpty else { return nil }
        var best: (label: String, score: Float)?
        for entry in known where entry.voice.count == voice.count && !used.contains(entry.label) {
            let score = cosine(voice, entry.voice)
            if score > (best?.score ?? 0.6) { best = (entry.label, score) }
        }
        return best?.label
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<min(a.count, b.count) {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    /// Joins words into transcript lines: a new line when the speaker changes, after a pause,
    /// or when a line gets long.
    private static func group(_ words: [(word: TimedWord, label: String)]) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var current: (label: String, start: Double, end: Double, text: String)?
        func flush() {
            guard let line = current else { return }
            let text = line.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !text.isEmpty { segments.append(TranscriptSegment(speaker: line.label, start: line.start, text: text)) }
            current = nil
        }
        for (word, label) in words {
            if let line = current {
                let pause = word.start - line.end
                let endsSentence = line.text.trimmingCharacters(in: .whitespaces).last.map { ".?!".contains($0) } ?? false
                if line.label != label || pause > 2.0 || (line.text.count > 320 && endsSentence) { flush() }
            }
            if var line = current {
                line.text += word.text
                line.end = max(line.end, word.end)
                current = line
            } else {
                current = (label, word.start, word.end, word.text)
            }
        }
        flush()
        return segments
    }
}
