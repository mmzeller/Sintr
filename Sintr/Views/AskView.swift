import SwiftUI

/// Chat about one note, or across all of them. Answers come from Apple Intelligence or the
/// local model on this device, or from Claude when you pick it.
struct AskView: View {
    let scope: Ask.Scope
    /// Opens a note an answer cites.
    var openNote: ((UUID) -> Void)?

    @Environment(NoteStore.self) private var store
    @Environment(AskStore.self) private var askStore
    @AppStorage(AppSettings.askEngine) private var engineRaw = AskEngine.apple.rawValue
    @State private var runner = AskRunner()
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var engine: AskEngine { AskEngine(rawValue: engineRaw) ?? .apple }

    private var messages: [ChatMessage] {
        switch scope {
        case .note(let id): store.note(id)?.chat ?? []
        case .library: askStore.current?.messages ?? []
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if messages.isEmpty && runner.partial == nil {
                            emptyState
                        }
                        ForEach(messages) { message in
                            ChatMessageRow(message: message, openNote: openNote)
                        }
                        if let partial = runner.partial {
                            ChatMessageRow(
                                message: ChatMessage(role: "assistant", text: partial.isEmpty ? "Thinking…" : partial),
                                isLive: true)
                        }
                        if let error = runner.errorText {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.callout)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding()
                    .textSelection(.enabled)
                }
                .onChange(of: messages.count) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: runner.partial) { proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            Divider()
            inputBar
        }
    }

    // MARK: Pieces

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(scope == .library ? "Ask about all your notes" : "Ask about this note",
                  systemImage: "bubble.left.and.text.bubble.right")
                .font(.headline)
            Text(scope == .library
                 ? "Sintr finds the notes that answer your question on this \(Platform.deviceName), then the AI you pick answers with links to them. Try “last week”, “on Monday” or a name."
                 : "Questions, summaries, follow-up emails — answered from this note's own notes and transcript.")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(scope == .library ? Ask.suggestionsForLibrary : Ask.suggestionsForNote, id: \.self) { suggestion in
                    Button(suggestion) { send(suggestion) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(runner.isRunning || engine.unavailableReason != nil)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Picker("Answer with", selection: $engineRaw) {
                        ForEach(AskEngine.allCases) { option in
                            Label(option.title + (option.unavailableReason == nil ? "" : " (not set up)"),
                                  systemImage: option.systemImage)
                                .tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: engine.systemImage)
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Which AI answers: \(engine.title)")

                TextField(scope == .library ? "Ask about your notes…" : "Ask about this note…",
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit { send(draft) }
                    .padding(8)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))

                if runner.isRunning {
                    Button {
                        runner.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill").font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop")
                } else {
                    Button {
                        send(draft)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || engine.unavailableReason != nil)
                    .help("Send")
                }
            }
            Text(engine.unavailableReason ?? privacyLine)
                .font(.caption)
                .foregroundStyle(engine.unavailableReason == nil ? Color.secondary : Color.orange)
        }
        .padding(10)
    }

    private var privacyLine: String {
        switch engine {
        case .apple, .local:
            "\(engine.title) answers on this \(Platform.deviceName). Nothing leaves it."
        case .claude:
            scope == .library
                ? "Sends your question and the matching parts of your notes to Claude (\(ClaudeModels.title(for: AppSettings.claudeModelID)))."
                : "Sends your question and this note to Claude (\(ClaudeModels.title(for: AppSettings.claudeModelID)))."
        }
    }

    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !runner.isRunning, engine.unavailableReason == nil else { return }
        draft = ""
        let history = messages
        append(ChatMessage(role: "user", text: question))
        runner.run(question: question, history: history, scope: scope, engine: engine, store: store) { answer in
            append(answer)
        }
    }

    private func append(_ message: ChatMessage) {
        switch scope {
        case .note(let id): store.edit(id) { $0.chat.append(message) }
        case .library: askStore.append(message)
        }
    }
}

struct ChatMessageRow: View {
    let message: ChatMessage
    var isLive = false
    var openNote: ((UUID) -> Void)?

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                MarkdownView(markdown: message.text)
                    .opacity(isLive ? 0.75 : 1)
                if !message.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sources").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(message.sources, id: \.self) { source in
                            Button {
                                openNote?(source.noteID)
                            } label: {
                                HStack(spacing: 6) {
                                    Text("[\(source.number)]").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(source.title).font(.caption).lineLimit(1)
                                    Text(source.date.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(openNote == nil)
                        }
                    }
                }
                if !isLive {
                    HStack(spacing: 10) {
                        if !message.by.isEmpty {
                            Text(message.by).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(message.text) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "Ask Sintr" — questions across every note, with saved conversations.
struct LibraryAskView: View {
    @Environment(AskStore.self) private var askStore
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        AskView(scope: .library) { id in
            appState.selection = id
            #if os(macOS)
            openWindow(id: "main")
            #else
            dismiss()
            #endif
        }
        .id(askStore.currentID)
        .navigationTitle(askStore.current?.title ?? "Ask Sintr")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    askStore.startNew()
                } label: {
                    Label("New conversation", systemImage: "square.and.pencil")
                }
                .disabled(askStore.current == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if askStore.conversations.isEmpty {
                        Text("No conversations yet")
                    }
                    ForEach(askStore.conversations.prefix(30)) { conversation in
                        Button {
                            askStore.currentID = conversation.id
                        } label: {
                            Text(conversation.title)
                            Text(conversation.updated.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    if let current = askStore.current {
                        Divider()
                        Button("Delete this conversation", systemImage: "trash", role: .destructive) {
                            askStore.delete(current.id)
                        }
                    }
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
            }
            #if os(iOS)
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            #endif
        }
    }
}
