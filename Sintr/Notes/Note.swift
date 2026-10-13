import Foundation

/// One stretch of speech in a transcript.
struct TranscriptSegment: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    /// "Me" or "Them" when Sintr recorded both your microphone and call audio (Mac),
    /// otherwise empty.
    var speaker = ""
    /// Seconds from the start of the note's first recording.
    var start: Double = 0
    var text = ""

    init(id: UUID = UUID(), speaker: String = "", start: Double = 0, text: String = "") {
        self.id = id
        self.speaker = speaker
        self.start = start
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        speaker = try c.decodeIfPresent(String.self, forKey: .speaker) ?? ""
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }
}

/// An audio file saved with a note.
struct NoteRecording: Codable, Hashable, Sendable {
    /// File name inside the app's Recordings folder.
    var fileName: String
    var speaker: String
    /// Where this recording starts on the note's timeline, in seconds.
    var offset: Double

    init(fileName: String, speaker: String, offset: Double) {
        self.fileName = fileName
        self.speaker = speaker
        self.offset = offset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try c.decode(String.self, forKey: .fileName)
        speaker = try c.decodeIfPresent(String.self, forKey: .speaker) ?? ""
        offset = try c.decodeIfPresent(Double.self, forKey: .offset) ?? 0
    }
}

struct Note: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var title = ""
    var created = Date()
    var modified = Date()
    /// What you typed yourself.
    var myNotes = ""
    var transcript: [TranscriptSegment] = []
    /// Cleaned-up notes in Markdown.
    var enhanced = ""
    /// Which engine wrote `enhanced`, e.g. "Apple Intelligence on this Mac".
    var enhancedBy = ""
    var enhancedAt: Date?
    /// Total recorded time in seconds.
    var duration: Double = 0
    var recordings: [NoteRecording] = []

    init() {}

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled note" : trimmed
    }

    var transcriptText: String {
        transcript.map { $0.text }.joined(separator: " ")
    }

    /// One line per segment: "[12:03] Them: text".
    func transcriptLines(includeTimes: Bool = true) -> String {
        transcript.map { segment in
            var line = ""
            if includeTimes { line += "[\(Self.clock(segment.start))] " }
            if !segment.speaker.isEmpty { line += "\(segment.speaker): " }
            return line + segment.text
        }.joined(separator: "\n")
    }

    /// Text used for search.
    var searchableText: String {
        [title, myNotes, enhanced, transcriptText].joined(separator: "\n")
    }

    var preview: String {
        for source in [myNotes, enhanced, transcriptText] {
            let line = source
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("#") }
            if let line { return line }
        }
        return ""
    }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static func durationText(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if seconds < 60 { return "\(Int(seconds)) sec" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) hr \(minutes % 60) min"
    }

    // Every field is optional when reading, so files from older versions
    // (or hand-edited ones) still import.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? created
        myNotes = try c.decodeIfPresent(String.self, forKey: .myNotes) ?? ""
        transcript = try c.decodeIfPresent([TranscriptSegment].self, forKey: .transcript) ?? []
        enhanced = try c.decodeIfPresent(String.self, forKey: .enhanced) ?? ""
        enhancedBy = try c.decodeIfPresent(String.self, forKey: .enhancedBy) ?? ""
        enhancedAt = try c.decodeIfPresent(Date.self, forKey: .enhancedAt)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        recordings = try c.decodeIfPresent([NoteRecording].self, forKey: .recordings) ?? []
    }
}

/// The file format for "Sintr backup" exports: one or more notes, no audio.
struct NoteArchive: Codable {
    var app = "Sintr"
    var formatVersion = 1
    var exported = Date()
    var notes: [Note]

    init(notes: [Note]) {
        self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = try c.decodeIfPresent(String.self, forKey: .app) ?? "Sintr"
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        exported = try c.decodeIfPresent(Date.self, forKey: .exported) ?? Date()
        notes = try c.decode([Note].self, forKey: .notes)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
