import Foundation
import Observation

/// A conversation in "Ask Sintr" (questions across all notes).
struct AskConversation: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var created = Date()
    var updated = Date()
    var messages: [ChatMessage] = []

    init(title: String) {
        self.title = title
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Conversation"
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? created
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
    }
}

/// Keeps Ask Sintr conversations in Ask.json inside Sintr's storage (so they stay on this
/// device, or travel with the portable version). Questions about one note are kept in that note.
@MainActor
@Observable
final class AskStore {
    private(set) var conversations: [AskConversation] = []
    var currentID: UUID?

    var current: AskConversation? { conversations.first { $0.id == currentID } }

    private var fileURL: URL { Storage.root.appendingPathComponent("Ask.json") }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? NoteArchive.decoder.decode([AskConversation].self, from: data) {
            conversations = saved.sorted { $0.updated > $1.updated }
        }
        currentID = conversations.first?.id
    }

    /// The next question starts a new conversation.
    func startNew() {
        currentID = nil
    }

    func append(_ message: ChatMessage) {
        if let index = conversations.firstIndex(where: { $0.id == currentID }) {
            var conversation = conversations.remove(at: index)
            conversation.messages.append(message)
            conversation.updated = Date()
            conversations.insert(conversation, at: 0)
        } else {
            let title = message.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Conversation"
            var conversation = AskConversation(title: String(title.prefix(70)))
            conversation.messages = [message]
            conversations.insert(conversation, at: 0)
            currentID = conversation.id
        }
        save()
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if currentID == id { currentID = conversations.first?.id }
        save()
    }

    func deleteAll() {
        conversations = []
        currentID = nil
        save()
    }

    private func save() {
        if conversations.count > 200 { conversations.removeLast(conversations.count - 200) }
        if let data = try? NoteArchive.encoder.encode(conversations) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// Runs one question at a time and shows the answer as it's written.
@MainActor
@Observable
final class AskRunner {
    private(set) var partial: String?
    private(set) var isRunning = false
    var errorText: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func run(question: String, history: [ChatMessage], scope: Ask.Scope, engine: AskEngine,
             store: NoteStore, done: @escaping (ChatMessage) -> Void) {
        guard !isRunning else { return }
        errorText = nil
        isRunning = true
        partial = ""
        let notes = store.notes
        let index = store.searchIndex
        task = Task { [weak self] in
            do {
                let generator = try engine.generator()
                let answer = try await Ask.answer(
                    question: question, history: history, scope: scope, notes: notes, index: index,
                    generator: generator
                ) { text in
                    Task { @MainActor [weak self] in
                        if self?.isRunning == true { self?.partial = text }
                    }
                }
                try Task.checkCancellation()
                done(ChatMessage(role: "assistant", text: answer.text, sources: answer.sources, by: generator.name))
            } catch is CancellationError {
            } catch {
                self?.errorText = error.localizedDescription
            }
            self?.partial = nil
            self?.isRunning = false
            self?.task = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        partial = nil
        isRunning = false
    }
}
