import SwiftUI

/// Choose where the clean-up happens. Nothing is sent anywhere until you pick an option
/// (and, for Claude, confirm).
struct EnhanceSheet: View {
    let noteID: UUID

    @Environment(NoteStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(TemplateStore.self) private var templates
    @AppStorage(AppSettings.template) private var templateID = NoteTemplate.defaultID
    @AppStorage(AppSettings.phoneModel) private var phoneModelRaw = PhoneModelChoice.defaultChoice.rawValue
    @AppStorage(AppSettings.claudeModel) private var claudeModel = AppSettings.defaultClaudeModel
    @State private var task: Task<Void, Never>?
    @State private var progress: EnhanceProgress?
    @State private var errorText: String?
    @State private var confirmClaude = false
    @State private var sectisReady = false

    private var note: Note { store.note(noteID) ?? Note() }
    private var template: NoteTemplate { templates.template(templateID) }
    private var phoneModel: PhoneModelChoice { PhoneModelChoice(rawValue: phoneModelRaw) ?? .defaultChoice }
    private var isRunning: Bool { task != nil }
    private var claudeKey: String? { APIKeyStore.claudeKey }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Template", selection: $templateID) {
                        ForEach(templates.templates) { template in
                            Text(template.name).tag(template.id)
                        }
                    }
                } footer: {
                    Text("\(wordCount(note.myNotes)) words of your notes · \(wordCount(note.transcriptText)) words of transcript")
                }

                if sectisReady {
                    Section {
                        Toggle(isOn: Binding(
                            get: { Sectis.isOn(for: store.note(noteID)) },
                            set: { value in store.edit(noteID) { $0.sendToSectis = value } })) {
                            Label("Send my action items to Sectis", systemImage: "checklist")
                        }
                        .disabled(isRunning)
                        if Sectis.isOn(for: store.note(noteID)) {
                            SectisPlacePicker(noteID: noteID)
                                .disabled(isRunning)
                        }
                    } footer: {
                        Text(sectisFooter)
                    }
                }

                if let progress {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(progress.message)
                            ProgressView(value: Double(progress.step - 1), total: Double(max(progress.steps, 1)))
                            if !Platform.isMac {
                                Text("Keep Sintr open until this finishes.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("Cancel", role: .cancel) { cancel() }
                    }
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    optionRow(
                        title: "Apple Intelligence",
                        systemImage: "apple.intelligence",
                        detail: "On this \(Platform.deviceName). Private and free.",
                        unavailable: AppleGenerator.unavailableReason
                    ) {
                        run(AppleGenerator())
                    }
                    optionRow(
                        title: phoneModel.title,
                        systemImage: "cpu",
                        detail: "On this \(Platform.deviceName), using the model you downloaded. Private and free, but slower and less polished.",
                        unavailable: phoneModelUnavailable
                    ) {
                        run(PhoneModelGenerator(choice: phoneModel))
                    }
                } header: {
                    Text("Stays on this \(Platform.deviceName)")
                }

                Section {
                    optionRow(
                        title: "Send to Claude",
                        systemImage: "paperplane",
                        detail: "Sends this note and its transcript to Anthropic's Claude API (\(claudeModel)). Best results; uses your API key.",
                        unavailable: claudeKey == nil ? "Add your Claude API key in Settings first." : nil
                    ) {
                        confirmClaude = true
                    }
                    ShareLink(item: shareText, subject: Text(note.displayTitle)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("Share to another app…", systemImage: "square.and.arrow.up")
                            Text("Opens the share sheet with the notes, transcript and instructions — for the Claude app, ChatGPT, Mail, AirDrop. Paste the answer back in Enhanced → Edit.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(isRunning)
                } header: {
                    Text("Leaves this \(Platform.deviceName) — only when you choose")
                }

                if !Platform.isMac {
                    Section {
                        Button {
                            dismiss()
                            appState.exportRequest = .init(noteID: noteID, format: .backup)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Do it on your Mac", systemImage: "laptopcomputer")
                                Text("Export this note as a Sintr backup and AirDrop it to your Mac (AirDrop goes directly between your devices). Import it in Sintr on the Mac, Enhance there with Apple Intelligence, and send it back the same way.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(isRunning)
                    }
                }

                if claudeKey == nil || phoneModelUnavailable != nil {
                    Section {
                        settingsButton
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Enhance notes")
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
            }
            .alert("Send to Claude?", isPresented: $confirmClaude) {
                Button("Send") {
                    if let key = claudeKey {
                        run(ClaudeGenerator(apiKey: key, model: AppSettings.claudeModelID))
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This sends “\(note.displayTitle)” — \(wordCount(note.myNotes)) words of your notes and \(wordCount(note.transcriptText)) words of transcript — to Anthropic's Claude API over an encrypted connection. Nothing else on this \(Platform.deviceName) is sent.")
            }
        }
        .interactiveDismissDisabled(isRunning)
        .onAppear { sectisReady = IntegrationSettings.isConfigured(.sectis) }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 600)
        #endif
    }

    private var sectisFooter: String {
        if let sent = Sectis.lastSend(of: note) {
            return "Already sent \(sent.date.formatted(date: .abbreviated, time: .shortened)), so Enhance won't send again — use Review & send on the Enhanced tab for anything new."
        }
        return Sectis.sendsWaiting
            ? "Other people's action items go to Sectis's Waiting For. Turn off to skip this meeting, or to look the items over first and send them yourself from the Enhanced tab."
            : "Turn off to skip this meeting, or to look the items over first and send them yourself from the Enhanced tab."
    }

    @ViewBuilder
    private var settingsButton: some View {
        #if os(macOS)
        SettingsLink {
            Label("Open Settings", systemImage: "gear")
        }
        #else
        Button {
            dismiss()
            appState.showSettings = true
        } label: {
            Label("Open Settings", systemImage: "gear")
        }
        #endif
    }

    private var phoneModelUnavailable: String? {
        if !PhoneModelGenerator.isBuiltIn { return "Coming in the next update of Sintr." }
        if !ModelFiles.isDownloaded(phoneModel.repoID) {
            return "Download \(phoneModel.title) in Settings → Local model first (one time, from Hugging Face)."
        }
        return nil
    }

    private var shareText: String {
        Enhancer.instructions + "\n\n" + Enhancer.fullPrompt(for: note, template: template)
    }

    private func optionRow(
        title: String, systemImage: String, detail: String, unavailable: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 28)
                    .foregroundStyle(unavailable == nil ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(unavailable == nil ? .primary : .secondary)
                    Text(unavailable ?? detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if unavailable == nil {
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(unavailable != nil || isRunning)
    }

    private func run(_ generator: some TextGenerator) {
        errorText = nil
        let note = self.note
        let template = self.template
        let name = generator.name
        progress = EnhanceProgress(step: 1, steps: 1, message: "Starting…")
        task = Task {
            do {
                let text = try await Enhancer.run(note: note, template: template, generator: generator) { update in
                    Task { @MainActor in progress = update }
                }
                store.edit(noteID) { note in
                    note.enhanced = text
                    note.enhancedBy = name
                    note.enhancedAt = Date()
                }
                store.saveNow()
                AutoSend.afterEnhance(noteID, store: store)
                task = nil
                progress = nil
                dismiss()
            } catch is CancellationError {
                task = nil
                progress = nil
            } catch {
                errorText = error.localizedDescription
                task = nil
                progress = nil
            }
        }
    }

    private func cancel() {
        task?.cancel()
        task = nil
        progress = nil
    }

    private func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}
