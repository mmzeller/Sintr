import SwiftUI
import Translation

/// Translate part of a note into another language — on the device with Apple Translate or
/// Apple Intelligence, with the phone model, or with Claude when you choose it.
struct TranslateSheet: View {
    let noteID: UUID

    @Environment(NoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.translateTarget) private var target = "es"
    @AppStorage(AppSettings.translateEngine) private var engineRaw = TranslateEngine.apple.rawValue
    @AppStorage(AppSettings.phoneModel) private var phoneModelRaw = PhoneModelChoice.defaultChoice.rawValue
    @State private var part = "enhanced"
    @State private var appleStatus: LanguageAvailability.Status?
    @State private var configuration: TranslationSession.Configuration?
    @State private var working = false
    @State private var progress: Double = 0
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?
    @State private var confirmClaude = false

    private var note: Note { store.note(noteID) ?? Note() }
    private var engine: TranslateEngine { TranslateEngine(rawValue: engineRaw) ?? .apple }
    private var phoneModel: PhoneModelChoice { PhoneModelChoice(rawValue: phoneModelRaw) ?? .defaultChoice }

    private var parts: [(id: String, name: String)] {
        var list: [(String, String)] = []
        if !note.enhanced.isEmpty { list.append(("enhanced", "Enhanced notes")) }
        if !note.transcript.isEmpty { list.append(("transcript", "Transcript")) }
        if !note.myNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { list.append(("myNotes", "My notes")) }
        return list
    }

    private var sourceText: String {
        switch part {
        case "transcript": note.transcriptLines()
        case "myNotes": note.myNotes
        default: note.enhanced
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Translate", selection: $part) {
                        ForEach(parts, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    Picker("Into", selection: $target) {
                        ForEach(TranslateLanguages.all) { Text($0.name).tag($0.code) }
                    }
                }

                Section {
                    Picker("Using", selection: $engineRaw) {
                        ForEach(TranslateEngine.allCases) { engine in
                            Text(engine.title + (engine.staysOnDevice ? "" : " (sends this text)")).tag(engine.rawValue)
                        }
                    }
                    Text(engineNote).font(.footnote).foregroundStyle(engineProblem == nil ? Color.secondary : Color.orange)
                }

                if working {
                    Section {
                        ProgressView(value: progress)
                        Button("Cancel", role: .cancel) { cancel() }
                    }
                }
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Translate")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Translate") { start() }
                        .disabled(working || engineProblem != nil || sourceText.isEmpty)
                }
            }
            .alert("Send to Claude?", isPresented: $confirmClaude) {
                Button("Send") { runWithModel() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This sends the \(parts.first { $0.id == part }?.name.lowercased() ?? "text") of “\(note.displayTitle)” to Anthropic's Claude API to translate it. Nothing else is sent.")
            }
            // Apple Translate: macOS/iOS asks to download a language the first time it's needed.
            .translationTask(configuration) { session in
                await runWithApple(session)
            }
        }
        .onAppear {
            if !parts.contains(where: { $0.id == part }) { part = parts.first?.id ?? "enhanced" }
        }
        .task(id: "\(target)|\(part)") { await checkApple() }
        .interactiveDismissDisabled(working)
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
    }

    // MARK: Engines

    private var engineProblem: String? {
        switch engine {
        case .apple:
            if appleStatus == .unsupported { return "Apple Translate can't do this language pair. Pick Apple Intelligence or Claude instead." }
            return nil
        case .appleIntelligence:
            return AppleGenerator.unavailableReason
        case .phone:
            if !PhoneModelGenerator.isBuiltIn { return "This build doesn't include the phone model." }
            return ModelFiles.isDownloaded(phoneModel.repoID) ? nil : "Download the phone model in Settings first."
        case .claude:
            return APIKeyStore.claudeKey == nil ? "Add your Claude API key in Settings first." : nil
        }
    }

    private var engineNote: String {
        if let engineProblem { return engineProblem }
        switch engine {
        case .apple:
            return appleStatus == .supported
                ? "Runs on this \(Platform.deviceName). \(TranslateLanguages.name(target)) needs a one-time download from Apple, which macOS asks about."
                : "Runs on this \(Platform.deviceName). Nothing is uploaded."
        case .appleIntelligence: return "Runs on this \(Platform.deviceName). Nothing is uploaded."
        case .phone: return "Runs on this \(Platform.deviceName). Slower, and weaker for rarer languages."
        case .claude: return "Best for any language. Sends just this text to Anthropic's Claude API."
        }
    }

    private func checkApple() async {
        let sample = String(sourceText.prefix(500))
        guard !sample.isEmpty else { return }
        appleStatus = try? await LanguageAvailability().status(for: sample, to: Locale.Language(identifier: target))
    }

    private func start() {
        errorText = nil
        switch engine {
        case .apple:
            if var config = configuration {
                config.target = Locale.Language(identifier: target)
                config.source = TranslateLanguages.detect(sourceText)
                config.invalidate()
                configuration = config
            } else {
                configuration = TranslationSession.Configuration(
                    source: TranslateLanguages.detect(sourceText), target: Locale.Language(identifier: target))
            }
        case .claude:
            confirmClaude = true
        default:
            runWithModel()
        }
    }

    private func runWithApple(_ session: TranslationSession) async {
        guard engine == .apple, !working else { return }
        working = true
        progress = 0
        defer { working = false }
        do {
            let text = try await Translator.translateWithApple(sourceText, session: session) { value in
                Task { @MainActor in progress = value }
            }
            save(text, by: "Apple Translate on this \(Platform.deviceName)")
        } catch is CancellationError {
        } catch {
            errorText = "Apple Translate couldn't finish: \(error.localizedDescription)"
        }
    }

    private func runWithModel() {
        let text = sourceText
        let code = target
        let engine = engine
        let phone = phoneModel
        working = true
        progress = 0
        task = Task {
            defer { working = false; task = nil }
            do {
                let result: String
                let name: String
                switch engine {
                case .claude:
                    guard let key = APIKeyStore.claudeKey else { return }
                    let generator = ClaudeGenerator(apiKey: key, model: AppSettings.claudeModelID)
                    name = generator.name
                    result = try await Translator.translateWithModel(text, to: code, generator: generator) { value in
                        Task { @MainActor in progress = value }
                    }
                case .phone:
                    let generator = PhoneModelGenerator(choice: phone)
                    name = generator.name
                    result = try await Translator.translateWithModel(text, to: code, generator: generator) { value in
                        Task { @MainActor in progress = value }
                    }
                default:
                    let generator = AppleGenerator()
                    name = generator.name
                    result = try await Translator.translateWithModel(text, to: code, generator: generator) { value in
                        Task { @MainActor in progress = value }
                    }
                }
                save(result, by: name)
            } catch is CancellationError {
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func save(_ text: String, by: String) {
        let translation = NoteTranslation(language: target, part: part, text: text, by: by)
        store.edit(noteID) { $0.translations.append(translation) }
        store.saveNow()
        dismiss()
    }

    private func cancel() {
        task?.cancel()
        task = nil
        configuration = nil
        working = false
    }
}
