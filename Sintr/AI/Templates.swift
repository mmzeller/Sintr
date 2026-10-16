import Foundation
import Observation

/// How Enhance shapes your notes — like Granola's templates and Parakeet's summary templates.
/// The built-in ones can be edited (and reset); you can add your own.
struct NoteTemplate: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// What the finished notes should contain and how they're laid out.
    var instructions: String

    static let defaultID = "meeting"

    static let builtIns: [NoteTemplate] = [
        NoteTemplate(id: "meeting", name: "Meeting notes", instructions: """
            ## Summary
            Two or three sentences.
            ## Notes
            Organized under the person's own headings or topics, in their order.
            ## Decisions
            ## Action items
            - [ ] Task — owner, due date if mentioned
            """),
        NoteTemplate(id: "memo", name: "Voice memo", instructions: """
            A tidy memo of the key points, in the speaker's own voice.
            ## Key points
            ## Details
            ## Follow-ups (only if any were mentioned)
            """),
        NoteTemplate(id: "todo", name: "To-do list", instructions: """
            Only a checklist of everything actionable, grouped by person or topic when that helps:
            - [ ] Task — owner, due date if mentioned
            Nothing else.
            """),
        NoteTemplate(id: "oneOnOne", name: "1:1 / check-in", instructions: """
            ## Summary
            ## What we talked about
            ## Follow-ups
            - [ ] Task — owner
            """),
        NoteTemplate(id: "interview", name: "Interview", instructions: """
            A question-and-answer write-up.
            ## Summary
            ## Questions and answers
            **Q:** question — **A:** answer, in brief
            ## Strengths
            ## Concerns or open questions
            ## Next steps
            """),
        NoteTemplate(id: "lecture", name: "Lecture or training", instructions: """
            ## Summary
            ## Key ideas
            Organized under headings in the order they were taught.
            ## Details and examples
            ## Takeaways
            ## Questions to review
            """),
    ]

    var isBuiltIn: Bool { Self.builtIns.contains { $0.id == id } }
}

/// Keeps the templates in Templates.json inside Sintr's storage (so they travel with the
/// portable version).
@MainActor
@Observable
final class TemplateStore {
    private(set) var templates: [NoteTemplate] = NoteTemplate.builtIns

    private var fileURL: URL { Storage.root.appendingPathComponent("Templates.json") }

    init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([NoteTemplate].self, from: data),
              !saved.isEmpty
        else { return }
        // Keep every built-in (edited or not), then the person's own.
        var merged = NoteTemplate.builtIns.map { builtIn in saved.first { $0.id == builtIn.id } ?? builtIn }
        merged += saved.filter { !$0.isBuiltIn }
        templates = merged
    }

    func template(_ id: String) -> NoteTemplate {
        templates.first { $0.id == id } ?? templates.first { $0.id == NoteTemplate.defaultID } ?? NoteTemplate.builtIns[0]
    }

    func update(_ template: NoteTemplate) {
        if let index = templates.firstIndex(where: { $0.id == template.id }) {
            templates[index] = template
        } else {
            templates.append(template)
        }
        save()
    }

    @discardableResult
    func add() -> NoteTemplate {
        let template = NoteTemplate(id: UUID().uuidString, name: "New template", instructions: """
            ## Summary
            ## Notes
            ## Action items
            """)
        templates.append(template)
        save()
        return template
    }

    func delete(_ id: String) {
        guard let template = templates.first(where: { $0.id == id }), !template.isBuiltIn else { return }
        templates.removeAll { $0.id == id }
        save()
    }

    func reset(_ id: String) {
        guard let original = NoteTemplate.builtIns.first(where: { $0.id == id }) else { return }
        update(original)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(templates) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
