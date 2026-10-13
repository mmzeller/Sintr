import SwiftUI

struct SettingsView: View {
    @Environment(NoteStore.self) private var store
    @AppStorage(AppSettings.language) private var language = ""
    @AppStorage(AppSettings.keepRecordings) private var keepRecordings = true
    @AppStorage(AppSettings.includeInBackups) private var includeInBackups = false
    @AppStorage(AppSettings.captureCallAudio) private var captureCallAudio = true
    @AppStorage(AppSettings.claudeModel) private var claudeModel = AppSettings.defaultClaudeModel
    @AppStorage(AppSettings.phoneModel) private var phoneModelRaw = PhoneModelChoice.defaultChoice.rawValue

    @State private var locales: [Locale] = []
    @State private var resolved: Locale?
    @State private var modelInstalled: Bool?
    @State private var speechDownload: Double?
    @State private var speechError: String?

    @State private var apiKeyDraft = ""
    @State private var hasKey = APIKeyStore.claudeKey != nil

    @State private var phoneDownload: Double?
    @State private var phoneTask: Task<Void, Never>?
    @State private var phoneError: String?
    @State private var phoneSizes: [String: Int64] = [:]
    @State private var refresh = 0

    private var phoneModel: PhoneModelChoice { PhoneModelChoice(rawValue: phoneModelRaw) ?? .defaultChoice }

    var body: some View {
        Form {
            privacySection
            transcriptionSection
            recordingSection
            phoneModelSection
            claudeSection
            aboutSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task { await loadSpeechInfo() }
        .onChange(of: language) { Task { await loadSpeechInfo() } }
        .onChange(of: includeInBackups) { store.applyBackupSetting() }
    }

    // MARK: Sections

    private var privacySection: some View {
        Section {
            Label {
                Text("Your notes, transcripts and recordings stay on this \(Platform.deviceName). Sintr only uses the internet when you tap **Send to Claude**, **Share**, or **Download** below — and for nothing else.")
            } icon: {
                Image(systemName: "lock.shield").foregroundStyle(.green)
            }
        }
    }

    private var transcriptionSection: some View {
        Section {
            Picker("Language", selection: $language) {
                Text("Same as this \(Platform.deviceName)").tag("")
                ForEach(locales, id: \.identifier) { locale in
                    Text(SpeechSupport.displayName(locale)).tag(locale.identifier)
                }
            }
            if !SpeechSupport.deviceSupported {
                Text("This device can't run Apple's on-device speech model.")
                    .foregroundStyle(.red)
            } else if let resolved {
                LabeledContent("Speech model") {
                    if let speechDownload {
                        ProgressView(value: speechDownload).frame(width: 120)
                    } else if modelInstalled == true {
                        Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if modelInstalled == false {
                        Button("Download") { Task { await downloadSpeech(resolved) } }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            if let speechError {
                Text(speechError).foregroundStyle(.red).font(.footnote)
            }
        } header: {
            Text("Transcription")
        } footer: {
            Text("Transcription uses Apple's speech model, entirely on this \(Platform.deviceName). Apple provides the model as a one-time download for each language.")
        }
    }

    private var recordingSection: some View {
        Section {
            #if os(macOS)
            Toggle("Also record call audio (“Them”)", isOn: $captureCallAudio)
            #endif
            Toggle("Keep audio recordings", isOn: $keepRecordings)
            #if os(iOS)
            Toggle("Include notes in iPhone backups", isOn: $includeInBackups)
            #endif
            LabeledContent("Recordings use", value: ByteCountFormatter.string(fromByteCount: store.recordingsSize(), countStyle: .file))
                .id(refresh)
        } header: {
            Text("Recording")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                #if os(macOS)
                Text("Call audio is everything your Mac plays — the other side of Zoom, Teams, FaceTime or a browser call. The first time, macOS asks to allow Sintr to record system audio. If “Them” stays empty, check System Settings → Privacy & Security → Screen & System Audio Recording.")
                #endif
                Text("Kept recordings let you re-transcribe a note later or export the audio. About 15–30 MB per hour.")
                #if os(iOS)
                Text("Backups are off by default so notes never go to iCloud. With this off, export a Sintr backup now and then so you have a copy.")
                #endif
            }
        }
    }

    private var phoneModelSection: some View {
        Section {
            if PhoneModelGenerator.isBuiltIn {
                Picker("Model", selection: $phoneModelRaw) {
                    ForEach(PhoneModelChoice.allCases) { choice in
                        Text(choice.title).tag(choice.rawValue)
                    }
                }
                Text(phoneModel.detail).font(.footnote).foregroundStyle(.secondary)
                let downloaded = ModelFiles.isDownloaded(phoneModel.repoID)
                if let phoneDownload {
                    HStack {
                        ProgressView(value: phoneDownload)
                        Button("Stop") { phoneTask?.cancel() }
                    }
                } else if downloaded {
                    LabeledContent("On this \(Platform.deviceName)") {
                        Text(ByteCountFormatter.string(fromByteCount: ModelFiles.sizeOnDisk(phoneModel.repoID), countStyle: .file))
                    }
                    Button("Delete model", role: .destructive) {
                        Task { await PhoneModelRuntimeBridge.unload() }
                        ModelFiles.delete(phoneModel.repoID)
                        refresh += 1
                    }
                } else {
                    Button("Download from Hugging Face") { downloadPhoneModel() }
                }
                if let phoneError {
                    Text(phoneError).foregroundStyle(.red).font(.footnote)
                }
            } else {
                Text("The downloadable phone model arrives in the next update of Sintr.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Phone model")
        } footer: {
            Text("A small open model that runs on this \(Platform.deviceName) for Enhance, with no internet needed after the download. It works on an iPhone 12, but it's slower and less polished than Apple Intelligence or Claude.")
        }
        .id(refresh)
    }

    private var claudeSection: some View {
        Section {
            if hasKey {
                LabeledContent("API key") {
                    Label("Saved in Keychain", systemImage: "key.fill").foregroundStyle(.green)
                }
                Button("Remove API key", role: .destructive) {
                    APIKeyStore.claudeKey = nil
                    hasKey = false
                }
            } else {
                SecureField("Paste your API key (sk-ant-…)", text: $apiKeyDraft)
                    .textContentType(.password)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                Button("Save key") {
                    APIKeyStore.claudeKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    apiKeyDraft = ""
                    hasKey = APIKeyStore.claudeKey != nil
                }
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            TextField("Model", text: $claudeModel)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Menu("Choose a model") {
                Button("Claude Sonnet 5.5 (recommended)") { claudeModel = "claude-sonnet-5-5" }
                Button("Claude Opus 5.5 (most capable, slower)") { claudeModel = "claude-opus-5-5" }
                Button("Claude Haiku 5.5 (fastest, cheapest)") { claudeModel = "claude-haiku-5-5" }
            }
        } header: {
            Text("Claude")
        } footer: {
            Text("Used only when you tap Send to Claude and confirm. Get a key at console.anthropic.com — it's billed per use and is separate from a Claude.ai subscription. The key is kept in this \(Platform.deviceName)'s Keychain.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
            LabeledContent("Notes", value: "\(store.notes.count)")
        }
    }

    // MARK: Actions

    private func loadSpeechInfo() async {
        guard SpeechSupport.deviceSupported else { return }
        locales = await SpeechSupport.supportedLocales()
        resolved = await SpeechSupport.resolvedLocale()
        if let resolved {
            modelInstalled = await SpeechSupport.isInstalled(resolved)
        }
    }

    private func downloadSpeech(_ locale: Locale) async {
        speechError = nil
        speechDownload = 0
        do {
            try await SpeechSupport.install(locale) { value in
                Task { @MainActor in speechDownload = value }
            }
            modelInstalled = true
        } catch {
            speechError = "Download failed: \(error.localizedDescription)"
        }
        speechDownload = nil
    }

    private func downloadPhoneModel() {
        phoneError = nil
        phoneDownload = 0
        let repo = phoneModel.repoID
        phoneTask = Task {
            do {
                try await ModelFiles.download(repo) { value in
                    Task { @MainActor in phoneDownload = value }
                }
            } catch is CancellationError {
                phoneError = "Download stopped. Tap Download to continue where it left off."
            } catch {
                phoneError = "Download failed: \(error.localizedDescription)"
            }
            phoneDownload = nil
            phoneTask = nil
            refresh += 1
        }
    }
}

/// Lets Settings free the phone model's memory without depending on MLX directly.
enum PhoneModelRuntimeBridge {
    static func unload() async {
        #if canImport(MLXLLM)
        await PhoneModelRuntime.shared.unload()
        #endif
    }
}
