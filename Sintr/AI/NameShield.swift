import Foundation
import NaturalLanguage

/// Replaces people's names with placeholders (Person_1, Person_2…) before text goes to Claude,
/// and puts the names back in what Claude writes — so Claude works with the meeting without
/// learning who was in it. Everything here runs on the device.
///
/// The names come from two places: the people Sintr already knows (speaker names, the voices
/// it remembers, your own name) and the personal names Apple's on-device language model finds
/// in the text. A misheard spelling of a known name ("Dayna" for "Dana") shares its
/// placeholder, so the answer comes back with the right spelling; so does a first name on its
/// own ("Dana" for "Dana Whitfield"). No audio and no network, so the automated checks test it
/// on its own (scripts/ci-logic-check.sh).
struct NameMask: Sendable {
    /// Placeholder number → the name it puts back.
    private(set) var names: [Int: String] = [:]
    /// The word placeholders are made of ("Person", unless the text already uses "Person 1").
    let word: String

    /// Lowercased spelling → placeholder number.
    private var numbers: [String: Int] = [:]
    /// Every spelling, longest first, as the one regular expression that finds them.
    private var pattern: String?

    var isEmpty: Bool { names.isEmpty }

    func placeholder(_ number: Int) -> String { "\(word)_\(number)" }

    /// - Parameters:
    ///   - known: names Sintr knows are people.
    ///   - texts: everything that's about to be sent (names are looked for in it).
    ///   - detect: also look for personal names with the on-device language model.
    init(known: [String], texts: [String], detect: Bool = true) {
        let joined = texts.joined(separator: "\n")
        word = Self.placeholderWord(avoiding: joined)

        var groups: [(spellings: [String], canonical: String, known: Bool)] = []
        func lower(_ s: String) -> String { s.lowercased() }
        func group(containing spelling: String) -> Int? {
            groups.firstIndex { $0.spellings.contains { lower($0) == lower(spelling) } }
        }

        // Known people: full names first, so "Dana" can join "Dana Whitfield".
        let knownNames = Self.uniqueIgnoringCase(known.compactMap(Self.clean))
            .sorted { ($0.split(separator: " ").count, $0.count) > ($1.split(separator: " ").count, $1.count) }
        for name in knownNames where group(containing: name) == nil {
            if !name.contains(" "), let index = Self.uniqueFirstNameMatch(name, in: groups) {
                groups[index].spellings.append(name)
            } else {
                groups.append(([name], name, true))
            }
        }
        // A known full name's first name, when only one known person has it.
        for index in groups.indices where groups[index].canonical.contains(" ") {
            let first = String(groups[index].canonical.split(separator: " ")[0])
            guard first.count >= 3, group(containing: first) == nil,
                  Self.uniqueFirstNameMatch(first, in: groups) == index else { continue }
            groups[index].spellings.append(first)
        }

        // Names found in the text.
        let found = detect ? Self.uniqueIgnoringCase(texts.flatMap { Self.personalNames(in: $0) }.compactMap(Self.clean)) : []
        for name in found.sorted(by: { $0.count > $1.count }) where group(containing: name) == nil {
            if let index = Self.similarKnown(name, in: groups) {
                groups[index].spellings.append(name)  // a misheard spelling of someone known
            } else if !name.contains(" "), let index = Self.uniqueFirstNameMatch(name, in: groups) {
                groups[index].spellings.append(name)
            } else if name.contains(" "), let first = name.split(separator: " ").first,
                      let index = groups.firstIndex(where: { $0.spellings.count == 1 && !$0.canonical.contains(" ")
                          && lower($0.canonical) == lower(String(first)) }) {
                // "Dana" was known, the text says "Dana Whitfield": the same person, now with a surname.
                groups[index].spellings.append(name)
                if !groups[index].known { groups[index].canonical = name }
            } else {
                groups.append(([name], name, false))
            }
        }

        // Only names that are actually in the text get a placeholder.
        let present = groups.filter { group in group.spellings.contains { Self.occurs($0, in: joined) } }
        var spellings: [String] = []
        for (offset, group) in present.enumerated() {
            let number = offset + 1
            names[number] = group.canonical
            for spelling in group.spellings {
                numbers[lower(spelling)] = number
                spellings.append(spelling)
            }
        }
        guard !spellings.isEmpty else { return }
        let alternatives = Self.unique(spellings.flatMap(Self.variants)).sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:))
        pattern = "(?<![\\p{L}\\p{N}_])(?:" + alternatives.joined(separator: "|") + ")(?![\\p{L}\\p{N}_])"
    }

    /// The text with every known spelling of every name replaced by its placeholder.
    func mask(_ text: String) -> String {
        guard let pattern, !text.isEmpty, let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return Self.replace(regex, in: text) { match in
            numbers[match.lowercased()].map { placeholder($0) } ?? match
        }
    }

    /// Claude's text with the names put back.
    func unmask(_ text: String) -> String {
        guard !names.isEmpty, !text.isEmpty, let regex = placeholderPattern else { return text }
        return Self.replace(regex, in: text, group: 1) { digits in
            Int(digits).flatMap { names[$0] }
        }
    }

    /// For a reply that's still arriving: the names put back, holding back a placeholder that
    /// may be cut off at the end ("Pers", "Person_1" before a "2").
    func unmaskPartial(_ text: String) -> String {
        unmask(String(text.dropLast(Self.cutOffPlaceholderLength(text, word: word))))
    }

    /// Goes at the top of the instructions Claude gets.
    var instruction: String {
        "To keep people private, their names in this text were replaced with placeholders like \(placeholder(1)) and \(placeholder(2)). Treat each placeholder as that person's name. Write every placeholder exactly as it is — keep it unchanged when translating, and never merge, rename, explain or guess at them. \"Me\" is still the person whose notes these are."
    }

    // MARK: Pieces

    private var placeholderPattern: NSRegularExpression? {
        try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: word) + "[ _]?(\\d{1,4})(?![\\p{N}])",
            options: [.caseInsensitive])
    }

    /// Words that are never anyone's name here.
    static let notNames: Set<String> = [
        "me", "you", "them", "us", "we", "i", "speaker", "person", "someone", "everyone", "unknown", "guest",
        "claude", "sintr", "sectis", "apple", "siri", "anthropic", "chatgpt", "openai", "google", "microsoft",
        "zoom", "teams", "webex", "slack", "facetime", "notion", "hubspot", "attio", "affinity", "zapier",
    ]

    /// A name tidied up, or nil if it isn't a usable name.
    static func clean(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?\"“”‘’()[]{}*_#@")))
        if name.hasSuffix("'s") || name.hasSuffix("’s") { name = String(name.dropLast(2)) }
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard name.count >= 2, name.count <= 60, name.split(separator: " ").count <= 4,
              name.contains(where: \.isLetter), !name.contains(where: \.isNumber),
              !notNames.contains(name.lowercased()) else { return nil }
        if name.range(of: #"^(them|speaker|person|participant|attendee)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }
        return name
    }

    /// The personal names Apple's on-device language model finds in a text.
    static func personalNames(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var found: [String] = []
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if tag == .personalName { found.append(String(text[range])) }
            return true
        }
        return found
    }

    /// "Person", unless the text already has something like "Person 3" in it.
    static func placeholderWord(avoiding text: String) -> String {
        for candidate in ["Person", "Participant", "Attendee", "Individual", "Member"] {
            if text.range(of: "\\b\(candidate)[ _]?\\d", options: [.regularExpression, .caseInsensitive]) == nil {
                return candidate
            }
        }
        return "Name"
    }

    /// How many characters at the end might be the start of a placeholder.
    static func cutOffPlaceholderLength(_ text: String, word: String) -> Int {
        let lowered = word.lowercased()
        let characters = Array(text.suffix(lowered.count + 6))
        for start in characters.indices {
            let tail = String(characters[start...]).lowercased()
            let before: Character? = start > 0 ? characters[start - 1] : text.dropLast(characters.count).last
            if let before, before.isLetter || before.isNumber || before == "_" { continue }
            let partOfWord = lowered.hasPrefix(tail)
            let wordAndNumber = tail.hasPrefix(lowered) && tail.dropFirst(lowered.count)
                .range(of: #"^[ _]?\d*$"#, options: .regularExpression) != nil
            if !tail.isEmpty, partOfWord || wordAndNumber { return characters.count - start }
        }
        return 0
    }

    private static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    private static func uniqueIgnoringCase(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.lowercased()).inserted }
    }

    /// How a name can appear: as given, with capitals ("dana" → "Dana"), and in capitals.
    /// Matching is otherwise exact, so a name that's also a word ("Will", "Faith") doesn't
    /// catch the word in the middle of a sentence.
    static func variants(_ name: String) -> [String] {
        let capitalized = name.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return [name, capitalized, name.uppercased()]
    }

    private static func occurs(_ spelling: String, in text: String) -> Bool {
        variants(spelling).contains { variant in
            text.range(of: "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: variant) + "(?![\\p{L}\\p{N}_])",
                       options: .regularExpression) != nil
        }
    }

    /// The one group whose full name starts with this first name.
    private static func uniqueFirstNameMatch(_ first: String,
                                             in groups: [(spellings: [String], canonical: String, known: Bool)]) -> Int? {
        let matches = groups.indices.filter { index in
            groups[index].canonical.contains(" ")
                && groups[index].canonical.split(separator: " ").first.map({ $0.lowercased() == first.lowercased() }) == true
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// A known person whose name this one is probably a misspelling of.
    private static func similarKnown(_ name: String,
                                     in groups: [(spellings: [String], canonical: String, known: Bool)]) -> Int? {
        guard name.count >= 5 else { return nil }
        var best: (index: Int, score: Double)?
        for (index, group) in groups.enumerated() where group.known {
            for spelling in group.spellings where spelling.count >= 5
                && spelling.split(separator: " ").count == name.split(separator: " ").count {
                let score = similarity(name.lowercased(), spelling.lowercased())
                if score >= 0.8, score > (best?.score ?? 0) { best = (index, score) }
            }
        }
        return best?.index
    }

    /// 1 for the same text, falling with every letter that has to change (Levenshtein).
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return x.isEmpty && y.isEmpty ? 1 : 0 }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }

    /// Replaces each match (or one capture group of it) with what `with` returns (nil: keep it).
    private static func replace(_ regex: NSRegularExpression, in text: String, group: Int = 0,
                                with: (String) -> String?) -> String {
        let source = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let range = match.range(at: group)
            guard range.location != NSNotFound, let replacement = with(source.substring(with: range)) else { continue }
            let whole = match.range
            result += source.substring(with: NSRange(location: last, length: whole.location - last))
            result += replacement
            last = whole.location + whole.length
        }
        result += source.substring(from: last)
        return result
    }
}
