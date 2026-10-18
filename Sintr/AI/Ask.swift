import Foundation
import NaturalLanguage

/// Which AI answers questions in Ask.
enum AskEngine: String, CaseIterable, Identifiable, Sendable {
    case apple, local, claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .local: "Local model"
        case .claude: "Claude"
        }
    }

    var systemImage: String {
        switch self {
        case .apple: "apple.intelligence"
        case .local: "cpu"
        case .claude: "paperplane"
        }
    }

    var staysOnDevice: Bool { self != .claude }

    /// Nil when it can be used, otherwise why not.
    @MainActor var unavailableReason: String? {
        switch self {
        case .apple:
            return AppleGenerator.unavailableReason
        case .local:
            if !PhoneModelGenerator.isBuiltIn { return "This build doesn't include the local model." }
            let choice = PhoneModelChoice.selected
            return ModelFiles.isDownloaded(choice.repoID)
                ? nil : "Download \(choice.title) in Settings → Local model first."
        case .claude:
            return APIKeyStore.claudeKey == nil ? "Add your Claude API key in Settings → Claude first." : nil
        }
    }

    @MainActor func generator() throws -> any TextGenerator {
        if let reason = unavailableReason { throw EnhanceError.unavailable(reason) }
        switch self {
        case .apple: return AppleGenerator()
        case .local: return PhoneModelGenerator(choice: PhoneModelChoice.selected)
        case .claude: return ClaudeGenerator(apiKey: APIKeyStore.claudeKey ?? "", model: AppSettings.claudeModelID)
        }
    }
}

/// A piece of a note that can be searched and quoted.
struct NotePassage: Sendable {
    let noteID: UUID
    let title: String
    let date: Date
    /// "Enhanced notes", "My notes" or "Transcript".
    let part: String
    let text: String
}

/// Finds the parts of your notes that answer a question — on the device, with no model:
/// keyword ranking (BM25), then a re-rank by meaning with Apple's on-device sentence
/// embeddings where the language has them.
final class SearchIndex: @unchecked Sendable {
    private struct Entry {
        let modified: Date
        let passages: [NotePassage]
        let tokens: [[String]]
        let titleTokens: Set<String>
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    /// Brings the index up to date with these notes (only changed notes are re-read).
    func update(_ notes: [Note]) {
        lock.lock()
        defer { lock.unlock() }
        let ids = Set(notes.map(\.id))
        entries = entries.filter { ids.contains($0.key) }
        for note in notes where entries[note.id]?.modified != note.modified {
            let passages = NoteSearch.passages(of: note)
            entries[note.id] = Entry(
                modified: note.modified,
                passages: passages,
                tokens: passages.map { NoteSearch.tokens($0.text) },
                titleTokens: Set(NoteSearch.tokens(note.displayTitle)))
        }
    }

    /// The best passages for `query`, best first. `limitTo` restricts the search to some notes.
    func search(_ query: String, limitTo: Set<UUID>? = nil, limit: Int = 40) -> [(passage: NotePassage, score: Double)] {
        let terms = Array(Set(NoteSearch.tokens(query)))
        guard !terms.isEmpty else { return [] }
        lock.lock()
        let chosen = entries.filter { limitTo == nil || limitTo!.contains($0.key) }.map { $0.value }
        lock.unlock()

        let documents = chosen.flatMap { entry in zip(entry.passages, entry.tokens).map { ($0, $1, entry.titleTokens) } }
        guard !documents.isEmpty else { return [] }
        let averageLength = Double(documents.reduce(0) { $0 + $1.1.count }) / Double(documents.count)
        var documentFrequency: [String: Int] = [:]
        for document in documents {
            let present = Set(document.1)
            for term in terms where present.contains(term) { documentFrequency[term, default: 0] += 1 }
        }
        let total = Double(documents.count)
        let k1 = 1.2, b = 0.75
        var results: [(passage: NotePassage, score: Double)] = []
        for (passage, tokens, titleTokens) in documents {
            var counts: [String: Int] = [:]
            for token in tokens where terms.contains(token) { counts[token, default: 0] += 1 }
            var score = 0.0
            for term in terms {
                let tf = Double(counts[term] ?? 0)
                let df = Double(documentFrequency[term] ?? 0)
                if tf > 0 {
                    let idf = log(1 + (total - df + 0.5) / (df + 0.5))
                    score += idf * tf * (k1 + 1) / (tf + k1 * (1 - b + b * Double(tokens.count) / max(averageLength, 1)))
                }
                if titleTokens.contains(term) { score += 0.8 }
            }
            if score > 0 { results.append((passage, score)) }
        }
        results.sort { $0.score > $1.score }
        return Array(NoteSearch.rerank(query, Array(results.prefix(max(limit * 2, 60)))).prefix(limit))
    }
}

enum NoteSearch {
    /// Splits a note into passages of about `size` characters.
    static func passages(of note: Note, size: Int = 900) -> [NotePassage] {
        var result: [NotePassage] = []
        func add(_ part: String, _ text: String) {
            for piece in Enhancer.split(text, size: size) where !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(NotePassage(noteID: note.id, title: note.displayTitle, date: note.created, part: part, text: piece))
            }
        }
        add("Enhanced notes", note.enhanced)
        add("My notes", note.myNotes)
        add("Transcript", note.transcriptLines())
        if result.isEmpty {
            result.append(NotePassage(noteID: note.id, title: note.displayTitle, date: note.created, part: "Title", text: note.displayTitle))
        }
        return result
    }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "about", "from", "by",
        "is", "are", "was", "were", "be", "been", "being", "it", "its", "this", "that", "these", "those", "there",
        "what", "which", "who", "whom", "when", "where", "why", "how", "did", "do", "does", "done", "doing",
        "i", "me", "my", "we", "our", "us", "you", "your", "he", "she", "they", "them", "his", "her", "their",
        "have", "has", "had", "will", "would", "can", "could", "should", "shall", "may", "might", "must",
        "not", "no", "yes", "so", "if", "then", "than", "too", "very", "just", "also", "any", "all", "some",
        "into", "over", "up", "down", "out", "as", "get", "got", "say", "said", "tell", "know", "think",
        "meeting", "meetings", "note", "notes", "call", "calls", "anything", "something", "everything",
        "um", "uh", "yeah", "okay", "ok", "like",
    ]

    /// Lowercase words without common filler, roughly stemmed.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .compactMap { raw -> String? in
                let word = String(raw)
                guard word.count > 1 || word.first?.isNumber == true, !stopWords.contains(word) else { return nil }
                return stem(word)
            }
    }

    private static func stem(_ word: String) -> String {
        if word.count > 5, word.hasSuffix("ing") { return String(word.dropLast(3)) }
        if word.count > 4, word.hasSuffix("ed") { return String(word.dropLast(2)) }
        if word.count > 4, word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }

    /// Mixes in similarity of meaning (on-device sentence embeddings), when available.
    static func rerank(_ query: String, _ candidates: [(passage: NotePassage, score: Double)]) -> [(passage: NotePassage, score: Double)] {
        guard candidates.count > 1, let top = candidates.first?.score, top > 0 else { return candidates }
        let language = NLLanguageRecognizer.dominantLanguage(for: query) ?? .english
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) ?? NLEmbedding.sentenceEmbedding(for: .english),
              let queryVector = embedding.vector(for: query)
        else { return candidates }
        return candidates.map { candidate in
            var similarity = 0.0
            if let vector = embedding.vector(for: String(candidate.passage.text.prefix(1000))) {
                similarity = max(cosine(queryVector, vector), 0)
            }
            return (candidate.passage, 0.6 * candidate.score / top + 0.4 * similarity)
        }
        .sorted { $0.score > $1.score }
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<min(a.count, b.count) {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    /// A time span mentioned in a question ("last week", "yesterday", "on Monday", "past 10 days").
    static func dateRange(in question: String, now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        let text = question.lowercased()
        let today = calendar.startOfDay(for: now)
        func days(_ n: Int, from date: Date) -> Date { calendar.date(byAdding: .day, value: n, to: date) ?? date }
        func interval(_ start: Date, _ end: Date) -> DateInterval { DateInterval(start: start, end: max(end, start)) }

        if text.contains("today") || text.contains("this morning") || text.contains("this afternoon") {
            return interval(today, now)
        }
        if text.contains("yesterday") { return interval(days(-1, from: today), today) }
        if let match = text.firstMatch(of: #/(?:past|last)\s+(\d{1,3})\s+(day|week|month)s?/#),
           let count = Int(match.1) {
            let unit: Calendar.Component = match.2 == "day" ? .day : (match.2 == "week" ? .weekOfYear : .month)
            return interval(calendar.date(byAdding: unit, value: -count, to: now) ?? now, now)
        }
        if text.contains("this week") {
            return interval(calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? days(-7, from: today), now)
        }
        if text.contains("last week") || text.contains("previous week") {
            if let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now) {
                return interval(days(-7, from: thisWeek.start), thisWeek.start)
            }
        }
        if text.contains("this month") {
            return interval(calendar.dateInterval(of: .month, for: now)?.start ?? days(-30, from: today), now)
        }
        if text.contains("last month") || text.contains("previous month") {
            if let thisMonth = calendar.dateInterval(of: .month, for: now),
               let start = calendar.date(byAdding: .month, value: -1, to: thisMonth.start) {
                return interval(start, thisMonth.start)
            }
        }
        if text.contains("recent") || text.contains("lately") {
            return interval(days(-14, from: today), now)
        }
        // A weekday: the most recent one (today counts).
        let symbols = calendar.weekdaySymbols.map { $0.lowercased() }
        for (index, name) in symbols.enumerated() where text.contains(name) {
            let weekday = index + 1
            for back in 0..<7 {
                let day = days(-back, from: today)
                if calendar.component(.weekday, from: day) == weekday {
                    return interval(day, days(1, from: day))
                }
            }
        }
        return nil
    }
}

/// Answers questions about one note, or about all of them.
enum Ask {
    enum Scope: Equatable, Sendable {
        case note(UUID)
        case library
    }

    struct Answer: Sendable {
        var text: String
        var sources: [ChatSource]
    }

    static let suggestionsForNote = [
        "What did I commit to?",
        "List the action items by person",
        "What were the key decisions?",
        "Draft a follow-up email",
        "What questions are still open?",
    ]

    static let suggestionsForLibrary = [
        "What happened in my meetings this week?",
        "What action items are still open?",
        "What did we decide about the budget?",
        "Summarize my meetings from last week",
        "Who did I meet with recently?",
    ]

    static func answer(
        question: String,
        history: [ChatMessage],
        scope: Scope,
        notes: [Note],
        index: SearchIndex,
        generator: any TextGenerator,
        onText: @escaping @Sendable (String) -> Void
    ) async throws -> Answer {
        let isClaude = generator is ClaudeGenerator
        // Room for the notes: what the model can take, less the question and earlier messages.
        let earlier = Array(history.suffix(isClaude ? 10 : 4))
        let historyTurns = earlier.map { ChatTurn(role: $0.role, text: isClaude ? $0.text : String($0.text.prefix(700))) }
        let used = question.count + historyTurns.reduce(0) { $0 + $1.text.count } + 900
        let budget = max(1_500, min(isClaude ? 160_000 : generator.chunkCharacters, generator.chunkCharacters) - used)

        let context: String
        let sources: [ChatSource]
        let system: String
        switch scope {
        case .note(let id):
            guard let note = notes.first(where: { $0.id == id }) else { throw EnhanceError.nothingToEnhance }
            context = noteContext(note, question: question, index: index, budget: budget)
            sources = []
            system = noteSystem
        case .library:
            let previous = history.last { $0.role == "user" }?.text
            (context, sources) = libraryContext(question: question, previousQuestion: previous, notes: notes,
                                                index: index, budget: budget, fullNotes: isClaude)
            system = librarySystem
        }

        let prompt = """
            \(Enhancer.glossaryLine)\(context)

            QUESTION: \(question)
            """
        let turns = historyTurns + [ChatTurn(role: "user", text: prompt)]
        let reply = Enhancer.clean(try await generator.chat(
            system: system, turns: turns, maxTokens: isClaude ? 3_000 : 800, onText: onText))
        return Answer(text: reply, sources: cited(in: reply, from: sources))
    }

    private static var today: String { Date().formatted(date: .complete, time: .omitted) }

    private static var noteSystem: String {
        """
        You help someone with one of their own meetings or notes. Answer from the note below — \
        their own notes, the enhanced notes and the transcript. "Me" in the transcript is the person \
        asking; "Them" is the other side of a call. If the note doesn't contain the answer, say so \
        plainly instead of guessing. When asked to write something (an email, a summary, a list), \
        write it ready to use. Be concise; use Markdown bullets for lists. Answer in the language of \
        the question. Today is \(today).
        """
    }

    private static var librarySystem: String {
        """
        You answer questions about someone's own meeting notes, using only the numbered notes below. \
        After each statement, cite the notes it comes from like [1] or [2][3]. If the notes don't \
        contain the answer, say so plainly — never invent meetings, names, numbers or decisions. \
        "Me" in a transcript is the person asking. Mention dates when they help. Be concise; use \
        Markdown bullets for lists. Answer in the language of the question. Today is \(today).
        """
    }

    // MARK: Context

    private static func noteContext(_ note: Note, question: String, index: SearchIndex, budget: Int) -> String {
        var header = "NOTE: \(note.displayTitle)\nDate: \(note.created.formatted(date: .complete, time: .shortened))"
        if note.duration > 0 { header += "\nLength: \(Note.durationText(note.duration))" }
        let speakers = note.speakers.map { note.displayName(forSpeaker: $0) }
        if !speakers.isEmpty { header += "\nSpeakers: \(speakers.joined(separator: ", "))" }
        let mine = note.myNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let enhanced = note.enhanced.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = note.transcriptLines()

        var parts: [String] = [header]
        if !mine.isEmpty { parts.append("MY NOTES:\n\(mine)") }
        if !enhanced.isEmpty { parts.append("ENHANCED NOTES:\n\(enhanced)") }
        let fixed = parts.joined(separator: "\n\n")
        if fixed.count + transcript.count + 20 <= budget {
            return transcript.isEmpty ? fixed : fixed + "\n\nTRANSCRIPT:\n" + transcript
        }

        // Too long: keep the notes (shortened if need be) and the transcript parts that
        // matter most for this question, in their original order.
        var shortParts = [header]
        if !mine.isEmpty { shortParts.append("MY NOTES:\n\(mine.prefix(budget / 5))") }
        if !enhanced.isEmpty { shortParts.append("ENHANCED NOTES:\n\(enhanced.prefix(budget / 3))") }
        var text = shortParts.joined(separator: "\n\n")
        let pieces = Enhancer.split(transcript, size: 700)
        guard !pieces.isEmpty else { return text }
        index.update([note])
        let ranked = index.search(question, limitTo: [note.id], limit: 30)
            .filter { $0.passage.part == "Transcript" }
            .map(\.passage.text)
        var chosen: [String] = []
        var room = budget - text.count - 60
        for piece in ranked where piece.count < room {
            chosen.append(piece)
            room -= piece.count + 6
        }
        if chosen.isEmpty {
            // Nothing matched by keyword: the start and end of the conversation.
            for piece in [pieces.first, pieces.count > 1 ? pieces.last : nil].compactMap({ $0 }) where piece.count < room {
                chosen.append(piece)
                room -= piece.count + 6
            }
        }
        let ordered = pieces.filter { piece in chosen.contains(where: { $0.hasPrefix(String(piece.prefix(80))) }) }
        text += "\n\nTRANSCRIPT EXCERPTS (most relevant parts, in order):\n" + (ordered.isEmpty ? chosen : ordered).joined(separator: "\n…\n")
        return text
    }

    private static func libraryContext(question: String, previousQuestion: String?, notes: [Note],
                                       index: SearchIndex, budget: Int, fullNotes: Bool) -> (String, [ChatSource]) {
        let range = NoteSearch.dateRange(in: question) ?? previousQuestion.flatMap { NoteSearch.dateRange(in: $0) }
        let pool = notes.filter { range == nil || range!.contains($0.created) }
        index.update(notes)

        // A short follow-up ("and what about Dana?") searches with the previous question too.
        var query = question
        if let previousQuestion, question.split(separator: " ").count < 7 { query += " " + previousQuestion }
        let ranked = index.search(query, limitTo: Set(pool.map(\.id)), limit: fullNotes ? 80 : 24)

        // Order notes by their best passage; for broad questions about a time span, also
        // include the most recent notes from it.
        var order: [UUID] = []
        var passagesByNote: [UUID: [NotePassage]] = [:]
        for (passage, _) in ranked {
            if passagesByNote[passage.noteID] == nil { order.append(passage.noteID) }
            passagesByNote[passage.noteID, default: []].append(passage)
        }
        if range != nil || ranked.count < 3 {
            for note in pool.sorted(by: { $0.created > $1.created }).prefix(fullNotes ? 40 : 12) where passagesByNote[note.id] == nil {
                order.append(note.id)
                passagesByNote[note.id] = []
            }
        }

        var blocks: [String] = []
        var sources: [ChatSource] = []
        var used = 0
        if let range {
            blocks.append("Notes from \(range.start.formatted(date: .abbreviated, time: .omitted)) to \(range.end.formatted(date: .abbreviated, time: .omitted)): \(pool.count) in total.")
        }
        for id in order {
            guard let note = notes.first(where: { $0.id == id }) else { continue }
            let number = sources.count + 1
            var body = ""
            if fullNotes {
                // Claude has room: the whole enhanced note (or own notes), plus matching passages.
                let main = !note.enhanced.isEmpty ? note.enhanced : note.myNotes
                body = String(main.prefix(12_000))
                let extra = (passagesByNote[id] ?? []).filter { $0.part == "Transcript" }.prefix(4).map(\.text)
                if !extra.isEmpty { body += "\n\nFrom the transcript:\n" + extra.joined(separator: "\n…\n") }
                if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    body = String(note.transcriptLines().prefix(12_000))
                }
            } else {
                let passages = passagesByNote[id] ?? []
                if passages.isEmpty {
                    body = String(overview(of: note).prefix(500))
                } else {
                    body = passages.prefix(2).map { "(\($0.part)) \($0.text)" }.joined(separator: "\n…\n")
                }
            }
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let block = "[\(number)] \(note.displayTitle) — \(note.created.formatted(date: .abbreviated, time: .shortened))\n\(body)"
            if used + block.count > budget {
                if blocks.count > 1 { break }
                blocks.append(String(block.prefix(budget - used)))
                sources.append(ChatSource(number: number, noteID: note.id, title: note.displayTitle, date: note.created))
                break
            }
            blocks.append(block)
            used += block.count + 2
            sources.append(ChatSource(number: number, noteID: note.id, title: note.displayTitle, date: note.created))
        }
        if sources.isEmpty {
            return ("NOTES: (no notes match this question\(range == nil ? "" : " in that time span"))", [])
        }
        return ("NOTES:\n\n" + blocks.joined(separator: "\n\n"), sources)
    }

    /// The start of a note: its enhanced notes, own notes or transcript.
    static func overview(of note: Note) -> String {
        for text in [note.enhanced, note.myNotes, note.transcriptLines(includeTimes: false)] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return note.displayTitle
    }

    /// The sources the answer actually cites; all of them (up to five) if it cites none.
    private static func cited(in text: String, from sources: [ChatSource]) -> [ChatSource] {
        guard !sources.isEmpty else { return [] }
        var numbers = Set<Int>()
        for match in text.matches(of: #/\[(\d{1,3})\]/#) {
            if let number = Int(match.1) { numbers.insert(number) }
        }
        let cited = sources.filter { numbers.contains($0.number) }
        return cited.isEmpty ? Array(sources.prefix(5)) : cited
    }
}
