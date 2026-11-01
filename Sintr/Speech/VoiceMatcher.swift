import Foundation

/// One voice fingerprint taken from one speaker in one note.
struct VoiceSample: Codable, Hashable, Sendable {
    /// The fingerprint (numbers describing how the voice sounds — not a recording).
    var print: [Float]
    /// The note and speaker label it came from, so a correction can take it back.
    var noteID: UUID?
    var label: String?
    var added = Date()
    /// You named or confirmed this speaker yourself (rather than Sintr recognizing them).
    var confirmed = false

    init(print: [Float], noteID: UUID? = nil, label: String? = nil, added: Date = Date(), confirmed: Bool = false) {
        self.print = print
        self.noteID = noteID
        self.label = label
        self.added = added
        self.confirmed = confirmed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        print = try c.decodeIfPresent([Float].self, forKey: .print) ?? []
        noteID = try c.decodeIfPresent(UUID.self, forKey: .noteID)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        added = try c.decodeIfPresent(Date.self, forKey: .added) ?? Date()
        confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
    }
}

/// A voice Sintr remembers, under the name you gave it ("Me", "Dana"…).
struct KnownVoice: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var samples: [VoiceSample] = []
    var created = Date()
    /// The last time this voice was named or recognized in a note.
    var lastHeard = Date()

    init(name: String, samples: [VoiceSample] = []) {
        self.name = name
        self.samples = samples
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        samples = try c.decodeIfPresent([VoiceSample].self, forKey: .samples) ?? []
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        lastHeard = try c.decodeIfPresent(Date.self, forKey: .lastHeard) ?? created
    }

    /// Your own voice.
    var isMe: Bool { VoiceMatcher.isMe(name) }
}

/// Decides which remembered voice a speaker is. No audio and no models here — just comparing
/// fingerprints — so the automated checks can test it on its own (scripts/ci-logic-check.sh).
enum VoiceMatcher {
    /// How alike two fingerprints must be (cosine similarity) to count as the same person.
    /// Stricter than matching voices within one note (0.6), because a different day, room or
    /// microphone changes how a voice comes across, and a wrong name is worse than none.
    static let threshold: Float = 0.64
    /// When two remembered voices both fit, the best must win by this much, or neither is used.
    static let margin: Float = 0.05
    /// A recognized voice this close is also kept as a new sample, so the voice is recognized
    /// in more rooms and on more microphones over time.
    static let reinforceAbove: Float = 0.74
    /// Samples kept per voice.
    static let maxSamples = 8

    /// The best similarity between a fingerprint and any of a voice's samples.
    static func similarity(_ print: [Float], to voice: KnownVoice) -> Float {
        voice.samples.reduce(Float(-1)) { best, sample in
            sample.print.count == print.count ? max(best, cosine(print, sample.print)) : best
        }
    }

    /// Which remembered voice each speaker is (label → voice and how close it was). One voice
    /// per speaker and one speaker per voice; a speaker whose best fit is too weak, or too
    /// close to a second voice, stays unnamed.
    ///
    /// - Parameters:
    ///   - excluding: voices already used in the note (a name you gave another speaker there).
    ///   - allowMe: whether your own voice can be among them (not on the other side of a call,
    ///     where your microphone is already "Me").
    static func assign(_ speakers: [String: [Float]], to voices: [KnownVoice],
                       excluding: Set<UUID> = [], allowMe: (String) -> Bool = { _ in true })
        -> [String: (id: UUID, score: Float)]
    {
        var candidates: [(label: String, id: UUID, score: Float)] = []
        for (label, print) in speakers where !print.isEmpty {
            let scored = voices
                .filter { !excluding.contains($0.id) && (allowMe(label) || !$0.isMe) }
                .map { (id: $0.id, score: similarity(print, to: $0)) }
                .sorted { $0.score > $1.score }
            guard let best = scored.first, best.score >= threshold else { continue }
            if scored.count > 1, best.score - scored[1].score < margin { continue }
            candidates.append((label, best.id, best.score))
        }
        // Most certain first, so a voice goes to the speaker it fits best.
        var result: [String: (id: UUID, score: Float)] = [:]
        var used = Set<UUID>()
        for candidate in candidates.sorted(by: { $0.score > $1.score || ($0.score == $1.score && $0.label < $1.label) })
        where !used.contains(candidate.id) {
            result[candidate.label] = (candidate.id, candidate.score)
            used.insert(candidate.id)
        }
        return result
    }

    /// The voice with this sample added. A sample from the same speaker in the same note
    /// replaces the old one; past the limit, the oldest samples Sintr recognized by itself go
    /// first, then the oldest you named.
    static func adding(_ sample: VoiceSample, to voice: KnownVoice) -> KnownVoice {
        var copy = voice
        copy.samples.removeAll { $0.noteID != nil && $0.noteID == sample.noteID && $0.label == sample.label }
        copy.samples.append(sample)
        while copy.samples.count > maxSamples {
            let unconfirmed = copy.samples.enumerated().filter { !$0.element.confirmed }
            let pool = unconfirmed.isEmpty ? Array(copy.samples.enumerated()) : unconfirmed
            guard let oldest = pool.min(by: { $0.element.added < $1.element.added }) else { break }
            copy.samples.remove(at: oldest.offset)
        }
        copy.lastHeard = max(copy.lastHeard, sample.added)
        return copy
    }

    /// "Me" (any capitalization) — your own voice.
    static func isMe(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "me"
    }

    /// Labels Sintr gives speakers by itself — never remembered as someone's name.
    static func isGenericLabel(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return trimmed.range(of: #"^(them|speaker|person|unknown|someone|guest|voice)(\s*\d+)?$"#,
                             options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Two names for the same voice ("dana" and "Dana").
    static func sameName(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<min(a.count, b.count) {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }
}
