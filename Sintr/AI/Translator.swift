import Foundation
import NaturalLanguage
import Translation

/// Where a translation is done.
enum TranslateEngine: String, CaseIterable, Identifiable {
    /// Apple's Translate models, on the device (about 20 languages; each is a one-time download from Apple).
    case apple
    /// Apple Intelligence's on-device model (Mac; iPhone 15 Pro or newer).
    case appleIntelligence
    /// The downloaded phone model.
    case phone
    /// Anthropic's Claude — only when you choose it.
    case claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Apple Translate"
        case .appleIntelligence: "Apple Intelligence"
        case .phone: "Phone model"
        case .claude: "Claude"
        }
    }

    var staysOnDevice: Bool { self != .claude }
}

enum TranslateLanguages {
    struct Language: Identifiable, Hashable {
        let code: String
        var id: String { code }
        var name: String { Locale.current.localizedString(forIdentifier: code) ?? code }
    }

    static let all: [Language] = [
        "ar", "zh-Hans", "zh-Hant", "cs", "da", "nl", "en", "en-GB", "fi", "fr", "de", "el", "he", "hi", "hu",
        "id", "it", "ja", "ko", "ms", "nb", "pl", "pt-BR", "pt-PT", "ro", "ru", "es", "sv", "tl", "th", "tr",
        "uk", "vi",
    ].map(Language.init).sorted { $0.name < $1.name }

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    /// The main language of a text, if it can tell.
    static func detect(_ text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(4000)))
        guard let language = recognizer.dominantLanguage else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }
}

enum Translator {
    /// Translates Markdown line by line with Apple's on-device models, keeping headings, bullets
    /// and checkboxes intact.
    static func translateWithApple(_ markdown: String, session: TranslationSession,
                                   progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let lines = markdown.components(separatedBy: "\n")
        var prefixes: [String] = []
        var bodies: [String] = []
        for line in lines {
            let (prefix, body) = splitMarkdownPrefix(line)
            prefixes.append(prefix)
            bodies.append(body)
        }
        let requests = bodies.enumerated().compactMap { index, body -> TranslationSession.Request? in
            body.trimmingCharacters(in: .whitespaces).isEmpty ? nil
                : TranslationSession.Request(sourceText: body, clientIdentifier: String(index))
        }
        var translated = bodies
        var done = 0
        // In batches, so progress can be shown on long transcripts.
        for start in stride(from: 0, to: requests.count, by: 40) {
            try Task.checkCancellation()
            let batch = Array(requests[start..<min(start + 40, requests.count)])
            let responses = try await session.translations(from: batch)
            for response in responses {
                if let id = response.clientIdentifier, let index = Int(id) { translated[index] = response.targetText }
            }
            done += batch.count
            progress(Double(done) / Double(max(requests.count, 1)))
        }
        return zip(prefixes, translated).map { $0 + $1 }.joined(separator: "\n")
    }

    /// Translates with a language model (Apple Intelligence, the phone model or Claude), a few
    /// paragraphs at a time.
    static func translateWithModel(_ markdown: String, to languageCode: String, generator: some TextGenerator,
                                   progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let language = TranslateLanguages.name(languageCode)
        let pieces = Enhancer.split(markdown, size: max(1200, generator.chunkCharacters / 2))
        var output: [String] = []
        for (index, piece) in pieces.enumerated() {
            try Task.checkCancellation()
            let prompt = """
                Translate the text below into \(language). Keep the Markdown formatting, line breaks, \
                speaker names and timestamps exactly as they are. Output only the translation.
                \(Enhancer.glossaryLine)
                TEXT:
                \(piece)
                """
            let result = try await generator.generate(
                instructions: "You are a careful, faithful translator. Never add or leave out content.",
                prompt: prompt, maxTokens: 2000)
            output.append(Enhancer.clean(result))
            progress(Double(index + 1) / Double(pieces.count))
        }
        return output.joined(separator: "\n")
    }

    /// Splits "## Heading", "- [ ] task", "**[01:02] Me:** words" into the part to keep as-is and
    /// the words to translate.
    static func splitMarkdownPrefix(_ line: String) -> (prefix: String, body: String) {
        let patterns = [
            #"^\s*#{1,6}\s+"#,
            #"^\s*[-*•]\s+\[[ xX]\]\s+"#,
            #"^\s*[-*•]\s+"#,
            #"^\s*\d+[.)]\s+"#,
            #"^\s*>\s+"#,
            #"^\*\*\[[0-9:]+\][^*]*\*\*\s*"#,
            #"^\[[0-9:]+\]\s*[^:]{0,40}:\s+"#,
        ]
        for pattern in patterns {
            if let range = line.range(of: pattern, options: .regularExpression) {
                return (String(line[range]), String(line[range.upperBound...]))
            }
        }
        return ("", line)
    }
}
