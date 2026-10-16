import SwiftUI
#if os(macOS)
import AppKit
#endif

struct SettingsView: View {
    @Environment(NoteStore.self) private var store
    @Environment(TemplateStore.self) private var templates
    @AppStorage(AppSettings.language) private var language = ""
    @AppStorage(AppSettings.keepRecordings) private var keepRecordings = true
    @AppStorage(AppSettings.includeInBackups) private var includeInBackups = false
    @AppStorage(AppSettings.meetingAudio) private var meetingRaw = MeetingAudio.allAudio.rawValue
    @AppStorage(AppSettings.microphoneUID) private var microphoneUID = ""
    @AppStorage(AppSettings.detectSpeakers) private var detectSpeakers = true
    @AppStorage(AppSettings.glossary) private var glossary = ""
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
    @State private var speakerDownload: Double?
    @State private var speakerError: String?
    @State private var editingTemplate: NoteTemplate?
    #if os(macOS)
    @State private var permission = SystemAudioPermission.status
    @State private var microphones: [MicDevices.Device] = []
    #endif

    private var phoneModel: PhoneModelChoice { PhoneModelChoice(rawValue: phoneModelRaw) ?? .defaultChoice }

    var body: some View {
        Form {
            privacySection
            #if os(macOS)
            storageSection
            #endif
            recordingSection
            transcriptionSection
            speakersSection
            templatesSection
            glossarySection
            phoneModelSection
            claudeSection
            aboutSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .sheet(item: $editingTemplate) { template in
            TemplateEditor(template: template)
        }
        .task { await loadSpeechInfo() }
        #if os(macOS)
        .onAppear { microphones = MicDevices.all() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permission = SystemAudioPermission.status
            microphones = MicDevices.all()
        }
        #endif
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

    #if os(macOS)
    private var storageSection: some View {
        Section {
            LabeledContent("Mode") {
                if Storage.isPortable {
                    Label("Portable", systemImage: "externaldrive").foregroundStyle(.tint)
                } else {
                    Text("This Mac")
                }
            }
            LabeledContent("Notes are in") {
                Text(Storage.root.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([Storage.root])
            }
        } header: {
            Text("Storage")
        } footer: {
            Text(Storage.isPortable
                 ? "Portable mode: notes, recordings, downloaded models and settings live in the “\(Storage.dataFolderName)” folder next to Sintr. Keep the two together, and quit Sintr before ejecting the drive. Each Mac keeps only its own permissions, Apple's speech model, and your Claude key if you add one."
                 : "To carry Sintr and your notes on a thumb drive or in any folder, build the portable version — see “Portable version” in the README.")
        }
    }
    #endif

    private var transcriptionSection: some View {
        Section {
            Picker("Language", selection: $language) {
                Text("Automatic (this \(Platform.deviceName)'s language)").tag("")
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
            LabeledContent("Meeting audio") {
                MeetingAudioPicker(selection: $meetingRaw, showsLabel: false)
            }
            if (MeetingAudio(rawValue: meetingRaw) ?? .allAudio).isOn {
                LabeledContent("Permission to hear calls") {
                    if permission == .allowed {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow…") {
                            Task {
                                _ = await SystemAudioPermission.request()
                                permission = SystemAudioPermission.status
                            }
                        }
                    }
                }
            }
            Picker("Microphone", selection: $microphoneUID) {
                Text("System default").tag("")
                ForEach(microphones) { mic in
                    Text(mic.name).tag(mic.uid)
                }
                if !microphoneUID.isEmpty && !microphones.contains(where: { $0.uid == microphoneUID }) {
                    Text("Not connected").tag(microphoneUID)
                }
            }
            #endif
            Toggle("Save audio with notes", isOn: $keepRecordings)
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
                Text("Meeting audio is what Sintr records besides your microphone. “All Mac audio” hears the other side of FaceTime, Teams, Zoom, Webex, Slack, WhatsApp or a call in your browser, and labels it “Them”. Pick one app to leave out other sounds (music, notifications). Off is for in-person meetings and voice notes.")
                Text("macOS gives Sintr silence instead of the call until you allow it: \(SystemAudioPermission.settingsPath). Wear headphones if you can — otherwise the microphone also hears the call from your speakers (Sintr removes most of those duplicates).")
                #endif
                Text("Saved audio lets you rebuild a transcript, detect speakers later, or export the recording. About 15–30 MB per hour.")
                #if os(iOS)
                Text("Backups are off by default so notes never go to iCloud. With this off, export a Sintr backup now and then so you have a copy.")
                #endif
            }
        }
    }

    private var speakersSection: some View {
        Section {
            Toggle("Detect speakers after recording", isOn: $detectSpeakers)
            LabeledContent("Speaker detection pack") {
                if !SpeakerDetector.isAvailable {
                    Text("Not in this build").foregroundStyle(.secondary)
                } else if let speakerDownload {
                    ProgressView(value: speakerDownload).frame(width: 120)
                } else if SpeakerDetector.isInstalled {
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: SpeakerDetector.sizeOnDisk, countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button("Delete", role: .destructive) {
                            SpeakerDetector.delete()
                            refresh += 1
                        }
                    }
                } else {
                    Button("Download") { downloadSpeakerPack() }
                }
            }
            .id(refresh)
            if let speakerError {
                Text(speakerError).foregroundStyle(.red).font(.footnote)
            }
        } header: {
            Text("Speakers")
        } footer: {
            Text("On calls, your microphone is “Me” and the call is “Them” (or Them 1, Them 2… when several people talk). In person, voices are labeled Speaker 1, Speaker 2… Click a speaker's name in a transcript to rename them. Runs on this \(Platform.deviceName) with open models (a one-time download of a few dozen MB) from Hugging Face; your audio is never uploaded.")
        }
    }

    private var templatesSection: some View {
        Section {
            ForEach(templates.templates) { template in
                HStack {
                    Text(template.name)
                    Spacer()
                    Button("Edit") { editingTemplate = template }
                        .buttonStyle(.borderless)
                }
            }
            Button("Add a template", systemImage: "plus") {
                editingTemplate = templates.add()
            }
        } header: {
            Text("Templates")
        } footer: {
            Text("Templates decide how Enhance lays out your notes. Edit the built-in ones or add your own.")
        }
    }

    private var glossarySection: some View {
        Section {
            TextEditor(text: $glossary)
                .frame(minHeight: 70)
                .font(.body)
        } header: {
            Text("Names and terms")
        } footer: {
            Text("People, places, products and jargon that come up in your meetings, one per line or separated by commas — for example “Q-SYS, Epiphan Pearl, NinjaOne”. Enhance and Translate use them to spell names correctly and fix transcript mistakes. (Apple's speech model doesn't accept custom words, so the transcript itself may still mishear them.)")
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

    private func downloadSpeakerPack() {
        speakerError = nil
        speakerDownload = 0
        Task {
            do {
                try await SpeakerDetector.download { value in
                    Task { @MainActor in speakerDownload = value }
                }
            } catch {
                speakerError = "Download failed: \(error.localizedDescription)"
            }
            speakerDownload = nil
            refresh += 1
        }
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
