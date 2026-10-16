import Foundation

/// Without headphones, your microphone also hears the call coming out of the speakers, so the
/// other side's words get transcribed twice: once from the call audio ("Them") and once from
/// your microphone ("Me"). This spots the "Me" copies while you record.
///
/// A "Me" line counts as an echo when most of its words were also said on the call side at
/// about the same time. The two transcripts never split lines the same way, so this compares
/// bags of words within a few seconds rather than whole lines.
struct EchoFilter {
    struct Line {
        let id: UUID
        let start: Double
        let end: Double
        let words: [String]
    }

    /// How far apart in time the two copies can be.
    static let window: Double = 3.0
    /// Share of a "Me" line's words that must also appear on the call side.
    static let threshold: Double = 0.6

    private var mine: [Line] = []
    private var theirs: [Line] = []

    /// A new "Me" line. Returns true if it's an echo of the call (and shouldn't be kept).
    mutating func addMine(id: UUID, start: Double, end: Double, text: String) -> Bool {
        let line = Line(id: id, start: start, end: max(end, start), words: Self.words(text))
        prune(before: line.start)
        if Self.isEcho(line, of: theirs) { return true }
        mine.append(line)
        return false
    }

    /// A new "Them" line. Returns earlier "Me" lines that turn out to be echoes of it.
    mutating func addTheirs(id: UUID, start: Double, end: Double, text: String) -> [UUID] {
        let line = Line(id: id, start: start, end: max(end, start), words: Self.words(text))
        theirs.append(line)
        prune(before: line.start)
        let echoes = mine.filter { Self.isEcho($0, of: theirs) }.map(\.id)
        if !echoes.isEmpty {
            let gone = Set(echoes)
            mine.removeAll { gone.contains($0.id) }
        }
        return echoes
    }

    private mutating func prune(before time: Double) {
        let cutoff = time - 120
        mine.removeAll { $0.end < cutoff }
        theirs.removeAll { $0.end < cutoff }
    }

    static func isEcho(_ line: Line, of call: [Line]) -> Bool {
        guard !line.words.isEmpty else { return false }
        let nearby = call.filter { $0.end >= line.start - window && $0.start <= line.end + window }
        guard !nearby.isEmpty else { return false }
        var bag: [String: Int] = [:]
        for other in nearby { for word in other.words { bag[word, default: 0] += 1 } }
        var matched = 0
        for word in line.words where (bag[word] ?? 0) > 0 {
            bag[word]! -= 1
            matched += 1
        }
        if line.words.count >= 3 {
            return Double(matched) / Double(line.words.count) >= threshold
        }
        // One or two words ("Okay", "Thank you"): only when every word matches and the call
        // side said it at practically the same moment.
        let close = nearby.contains { $0.end >= line.start - 1.5 && $0.start <= line.end + 1.5 }
        return matched == line.words.count && close
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map { $0.replacingOccurrences(of: "'", with: "") }
            .filter { !$0.isEmpty }
    }
}
