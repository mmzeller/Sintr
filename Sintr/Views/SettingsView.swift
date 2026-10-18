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
    @AppStorage(AppSettings.monitorLevels) private var monitorLevels = true
    @AppStorage(AppSettings.removeEcho) private var removeEcho = true
    @AppStorage(AppSettings.claudeEffort) private var claudeEffort = ClaudeEffort.modelDefault.rawValue
    @AppStorage(AppSettings.notesLanguage) private var notesLanguage = ""
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(LocalAPIServer.self) private var localAPI
    @AppStorage(AppSettings.allowAIApps) private var allowAIApps = false
    @AppStorage(AppSettings.localAPI) private var localAPIOn = false
    @AppStorage(AppSettings.localAPIPort) private var localAPIPort = 52817
    @State private var apiToken = ""
    @State private var showToken = false
    @State private var connectMessage: String?
    #endif

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
    @State private var setupFile: URL?
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
            IntegrationsSettingsSection()
            connectionsSection
            teamSetupSection
            troubleshootingSection
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
                Text("Your notes, transcripts and recordings stay on this \(Platform.deviceName). Sintr only uses the internet when you choose Claude, **Send to…** an app, **Share**, or **Download** below — and for nothing else. No account, and nothing is ever used to train AI: Apple Intelligence and the local model run on this \(Platform.deviceName), and Anthropic doesn't train on what its API receives without your express permission.")
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
            Picker("Write enhanced notes in", selection: $notesLanguage) {
                Text("The meeting's language").tag("")
                ForEach(NotesLanguage.choices, id: \.self) { code in
                    Text(NotesLanguage.name(code)).tag(code)
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
            Toggle("Live input meters when not recording", isOn: $monitorLevels)
            LabeledContent("Hearing now") {
                LiveInputs()
            }
            Toggle("Remove echo of the call from my microphone", isOn: $removeEcho)
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
                Text("macOS gives Sintr silence instead of the call until you allow it: \(SystemAudioPermission.settingsPath).")
                Text("Live input meters keep the microphone (and call audio) open so you can see what Sintr hears before you record — macOS shows its microphone indicator meanwhile. Nothing is saved or transcribed until you press Record.")
                Text("Without headphones your microphone also hears the call from your speakers. “Remove echo” drops those duplicate lines from “Me” — while recording, and again more precisely afterwards. Headphones still work best.")
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
                    ForEach(PhoneModelChoice.available) { choice in
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
            Text("Local model")
        } footer: {
            Text(Platform.isMac
                 ? "An open model that runs on this Mac for Enhance and Ask, with no internet needed after the download. The bigger Qwen3 models are the most capable that stay on your Mac; they think step by step when you ask them to."
                 : "A small open model that runs on this iPhone for Enhance and Ask, with no internet needed after the download. It works on an iPhone 12, but it's slower and less polished than Apple Intelligence or Claude.")
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
            Picker("Model", selection: $claudeModel) {
                ForEach(ClaudeModels.choices, id: \.id) { choice in
                    Text(choice.title).tag(choice.id)
                }
                if !ClaudeModels.choices.contains(where: { $0.id == claudeModel }) {
                    Text(claudeModel.isEmpty ? "Default" : claudeModel).tag(claudeModel)
                }
            }
            if let detail = ClaudeModels.choices.first(where: { $0.id == claudeModel })?.detail {
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Picker("Thinking", selection: $claudeEffort) {
                ForEach(ClaudeEffort.allCases) { effort in
                    Text(effort.title).tag(effort.rawValue)
                }
            }
            DisclosureGroup("Use another model ID") {
                TextField("Model ID", text: $claudeModel)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }
        } header: {
            Text("Claude")
        } footer: {
            Text("Used only when you choose Claude for Enhance, Ask or Translate. Claude thinks before it answers; “Thinking” sets how much — more is slower and costs more. Get a key at console.anthropic.com — it's billed per use and is separate from a Claude.ai subscription. The key is kept in this \(Platform.deviceName)'s Keychain.")
        }
    }

    private var teamSetupSection: some View {
        Section {
            if let setupFile {
                ShareLink(item: setupFile) {
                    Label("Share your setup…", systemImage: "person.2.badge.gearshape")
                }
            }
        } header: {
            Text("Team setup")
        } footer: {
            Text("A file with your templates, names and terms, recording defaults, notes language, AI choices and integration targets — never keys, tokens or notes. Teammates open it with Import… to get the same setup. Send an updated file whenever the team's setup changes.")
        }
        .onAppear { setupFile = SetupProfile.exportFile(templates: templates.templates) }
    }

    @ViewBuilder private var connectionsSection: some View {
        #if os(macOS)
        Section {
            Toggle("Let AI apps read my notes (MCP)", isOn: $allowAIApps)
            if allowAIApps {
                HStack {
                    Button("Add to Claude Desktop") { addToClaudeDesktop() }
                    Button("Copy Claude Code command") {
                        Clipboard.copy("claude mcp add sintr -- \"\(Self.executablePath)\" --mcp")
                        connectMessage = "Copied. Paste it into Terminal."
                    }
                    Button("Copy MCP config") {
                        Clipboard.copy(NoteLibrary.json(["mcpServers": ["sintr": ["command": Self.executablePath, "args": ["--mcp"]]]]))
                        connectMessage = "Copied the JSON for any MCP-capable app."
                    }
                }
                if let connectMessage {
                    Text(connectMessage).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Toggle("Local API on this Mac", isOn: $localAPIOn)
            if localAPIOn {
                LabeledContent("Status", value: localAPI.status)
                TextField("Port", value: $localAPIPort, format: .number.grouping(.never))
                LabeledContent("Token") {
                    HStack {
                        Text(showToken ? apiToken : String(repeating: "•", count: 20))
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(showToken ? "Hide" : "Show") { showToken.toggle() }
                        Button("Copy") { Clipboard.copy(apiToken) }
                        Button("New") { apiToken = LocalAPIServer.regenerateToken() }
                    }
                }
                Button("Copy an example request") {
                    Clipboard.copy("curl -H \"Authorization: Bearer \(apiToken)\" \"http://127.0.0.1:\(localAPIPort)/v1/notes?since=7d\"")
                }
            }
            LabeledContent("Command line") {
                Button("Copy example") {
                    Clipboard.copy("\"\(Self.executablePath)\" --cli search budget")
                }
            }
        } header: {
            Text("Connections")
        } footer: {
            Text("All three are read-only and stay on this Mac. MCP lets Claude Desktop, Claude Code and other AI apps search and read your notes when you ask them to — what they do with an answer is up to that app. The local API answers only this Mac, needs the token, and runs while Sintr is open: GET /v1/notes, /v1/notes/{id}, /v1/search?q=, /v1/folders. The command line (--cli list, search, get, folders) is for scripts.")
        }
        .onAppear { apiToken = LocalAPIServer.token }
        #endif
    }

    #if os(macOS)
    private static var executablePath: String { Bundle.main.executableURL?.path ?? "/Applications/Sintr.app/Contents/MacOS/Sintr" }

    private func addToClaudeDesktop() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude")
        let file = folder.appendingPathComponent("claude_desktop_config.json")
        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: file), !data.isEmpty {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                connectMessage = "Claude Desktop's settings file couldn't be read, so it wasn't changed. Use “Copy MCP config” and add it by hand."
                return
            }
            config = parsed
        }
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers["sintr"] = ["command": Self.executablePath, "args": ["--mcp"]]
        config["mcpServers"] = servers
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: file, options: .atomic)
            connectMessage = "Added. Quit and reopen Claude Desktop, then ask it about your meetings."
        } catch {
            connectMessage = "Couldn't update Claude Desktop's settings: \(error.localizedDescription)"
        }
    }
    #endif

    private var troubleshootingSection: some View {
        Section {
            #if os(macOS)
            Button("Open Activity Log", systemImage: "list.bullet.rectangle") {
                openWindow(id: ActivityLogView.windowID)
            }
            #else
            NavigationLink {
                ActivityLogView()
            } label: {
                Label("Activity Log", systemImage: "list.bullet.rectangle")
            }
            #endif
        } header: {
            Text("Troubleshooting")
        } footer: {
            Text("What Sintr's audio and speech parts are doing — devices, formats, timings and errors, never what anyone said. If something goes wrong, copy it into a message.")
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
