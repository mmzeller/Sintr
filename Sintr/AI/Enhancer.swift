import Foundation

/// Anything that can turn a prompt into text: Apple's on-device model, the downloaded phone
/// model, or Claude.
protocol TextGenerator: Sendable {
    /// Human-readable name saved with the result, e.g. "Claude (claude-sonnet-5-5)".
    var name: String { get }
    /// About how many characters of transcript fit in one request.
    var chunkCharacters: Int { get }
    func generate(instructions: String, prompt: String, maxTokens: Int) async throws -> String
    /// A conversation. `onText` gets the reply so far as it's written (all at once for
    /// models that don't stream).
    func chat(system: String, turns: [ChatTurn], maxTokens: Int,
              onText: @escaping @Sendable (String) -> Void) async throws -> String
}

/// One message in a conversation sent to a model.
struct ChatTurn: Sendable {
    /// "user" or "assistant".
    var role: String
    var text: String
}

extension TextGenerator {
    /// Models without a conversation API get the earlier turns written into the prompt.
    func chat(system: String, turns: [ChatTurn], maxTokens: Int,
              onText: @escaping @Sendable (String) -> Void) async throws -> String {
        let prompt: String
        if turns.count <= 1 {
            prompt = turns.last?.text ?? ""
        } else {
            let earlier = turns.dropLast().map { "\($0.role == "user" ? "User" : "You"): \($0.text)" }.joined(separator: "\n\n")
            prompt = "The conversation so far:\n\n\(earlier)\n\nNow answer this:\n\(turns.last?.text ?? "")"
        }
        let reply = Enhancer.clean(try await generate(instructions: system, prompt: prompt, maxTokens: maxTokens))
        onText(reply)
        return reply
    }
}

struct EnhanceProgress: Sendable {
    var step: Int
    var steps: Int
    var message: String
}

enum Enhancer {
    static let instructions = """
        You turn someone's rough notes and a transcript into clean, accurate notes.
        Their own notes come first: keep every point they wrote, in their order, and expand each \
        one with the relevant details from the transcript. Then add anything important they missed.
        Never invent names, numbers, dates or decisions that aren't in the notes or transcript. \
        If something in the transcript is unclear, say so instead of guessing.
        "Me" in the transcript is the person whose notes these are; "Them" is everyone else on the call.
        Speaker names in the transcript ("Me", "Them", "Speaker 1" or real names) tell you who said what.
        When an action item belongs to the person whose notes these are, write "Me" as its owner.
        Write Markdown with short headings and bullet points. No introduction or sign-off.
        """

    /// Everything that would be sent, as one block of text (used for "Share to another app"
    /// and for showing what Claude will receive).
    static func fullPrompt(for note: Note, template: NoteTemplate) -> String {
        finalPrompt(note: note, template: template, transcriptPart: note.transcriptLines(), isCondensed: false)
    }

    static func run(
        note: Note,
        template: NoteTemplate,
        generator: some TextGenerator,
        progress: @escaping @Sendable (EnhanceProgress) -> Void
    ) async throws -> String {
        let transcript = note.transcriptLines()
        guard !transcript.isEmpty || !note.myNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EnhanceError.nothingToEnhance
        }

        // Short enough: one request.
        if transcript.count + note.myNotes.count <= generator.chunkCharacters {
            progress(EnhanceProgress(step: 1, steps: 1, message: "Writing your notes…"))
            let prompt = finalPrompt(note: note, template: template, transcriptPart: transcript, isCondensed: false)
            return clean(try await generator.generate(instructions: instructions, prompt: prompt, maxTokens: 1500))
        }

        // Too long for the model at once: summarize the transcript in parts, then write the notes
        // from those summaries plus your own notes.
        var parts = split(transcript, size: max(1500, generator.chunkCharacters - min(note.myNotes.count, 2000)))
        var round = 0
        while true {
            round += 1
            var summaries: [String] = []
            for (index, part) in parts.enumerated() {
                try Task.checkCancellation()
                progress(EnhanceProgress(
                    step: index + 1, steps: parts.count + 1,
                    message: round == 1
                        ? "Reading part \(index + 1) of \(parts.count)…"
                        : "Condensing \(index + 1) of \(parts.count)…"))
                let prompt = """
                    Below is part \(index + 1) of \(parts.count) of a \(round == 1 ? "transcript" : "set of notes from a long transcript").
                    List the important points, decisions, numbers, names, questions and action items as short bullet points. \
                    Only include what is actually said. No introduction.

                    \(part)
                    """
                let summary = try await generator.generate(
                    instructions: "You extract key points accurately and briefly.", prompt: prompt, maxTokens: 700)
                summaries.append(clean(summary))
            }
            let combined = summaries.enumerated()
                .map { "Part \($0.offset + 1):\n\($0.element)" }
                .joined(separator: "\n\n")
            if combined.count + note.myNotes.count <= generator.chunkCharacters || parts.count == 1 || round >= 4 {
                try Task.checkCancellation()
                progress(EnhanceProgress(step: parts.count + 1, steps: parts.count + 1, message: "Writing your notes…"))
                let prompt = finalPrompt(note: note, template: template, transcriptPart: combined, isCondensed: true)
                return clean(try await generator.generate(instructions: instructions, prompt: prompt, maxTokens: 1500))
            }
            parts = split(combined, size: generator.chunkCharacters)
        }
    }

    private static func finalPrompt(note: Note, template: NoteTemplate, transcriptPart: String, isCondensed: Bool) -> String {
        let myNotes = note.myNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let date = note.created.formatted(date: .complete, time: .shortened)
        return """
            Title: \(note.displayTitle)
            Date: \(date)
            \(glossaryLine)\(NotesLanguage.instruction)
            Use this layout. The text under each heading only describes what belongs there — \
            write the real content from this meeting in its place, and never copy the description:
            \(template.instructions)

            MY NOTES:
            \(myNotes.isEmpty ? "(none — work from the transcript)" : myNotes)

            \(isCondensed ? "KEY POINTS FROM THE TRANSCRIPT (condensed in order)" : "TRANSCRIPT"):
            \(transcriptPart.isEmpty ? "(no transcript)" : transcriptPart)
            """
    }

    /// The names-and-terms list from Settings, as a line for prompts (empty if there's none).
    static var glossaryLine: String {
        let glossary = AppSettings.glossaryText
        guard !glossary.isEmpty else { return "" }
        let terms = glossary.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return "Names and terms that may come up (spell them exactly like this, and fix transcript mistakes that sound like them): \(terms)\n"
    }

    /// Splits text into pieces of about `size` characters, at line breaks where possible.
    static func split(_ text: String, size: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(line)
            while line.count > size {
                if !current.isEmpty { pieces.append(current); current = "" }
                pieces.append(String(line.prefix(size)))
                line = String(line.dropFirst(size))
            }
            if current.count + line.count + 1 > size, !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            current += current.isEmpty ? line : "\n" + line
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pieces.append(current) }
        return pieces
    }

    /// Removes thinking blocks and wrapping code fences some models add.
    static func clean(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<think>"), let end = result.range(of: "</think>", range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            var lines = result.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}

enum EnhanceError: LocalizedError {
    case nothingToEnhance
    case unavailable(String)
    case service(String)

    var errorDescription: String? {
        switch self {
        case .nothingToEnhance: "There's nothing to work from yet — type some notes or record something first."
        case .unavailable(let why): why
        case .service(let message): message
        }
    }
}

/// The language Enhance writes in (Settings → Transcription).
enum NotesLanguage {
    static let choices = ["en", "es", "fr", "de", "it", "pt", "nl", "sv", "da", "nb", "fi", "pl", "cs",
                          "tr", "ru", "uk", "ar", "he", "hi", "ja", "ko", "zh-Hans", "zh-Hant", "vi", "th", "id"]

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    /// A line for prompts, or empty to write in the meeting's own language.
    static var instruction: String {
        let code = AppSettings.notesLanguageID
        guard !code.isEmpty else { return "Write the notes in the same language as the transcript and notes.\n" }
        let english = Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
        return "Write the notes in \(english), whatever language the meeting was in. Keep names as they are.\n"
    }
}
