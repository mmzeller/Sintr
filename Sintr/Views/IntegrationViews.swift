import SwiftUI

/// "Send to Notion / HubSpot / …" for one note. (Sectis has its own sheet, where you pick
/// and adjust the action items: `SectisSendSheet`.)
struct SendSheet: View {
    let noteID: UUID
    let kind: IntegrationKind

    @Environment(NoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var email = ""
    @State private var includeTranscript = false
    @State private var sending = false
    @State private var result: NoteSend?
    @State private var errorText: String?

    private var note: Note { store.note(noteID) ?? Note() }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Note", value: note.displayTitle)
                    LabeledContent("Sends", value: note.enhanced.isEmpty ? (note.myNotes.isEmpty ? "Title only" : "Your notes") : "Enhanced notes")
                    if !note.transcript.isEmpty {
                        Toggle("Include the transcript", isOn: $includeTranscript)
                    }
                    if kind.needsContact {
                        TextField("Their email address", text: $email)
                            #if os(iOS)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                    }
                } footer: {
                    Text(kind.needsContact
                         ? "The note is added to the person in \(kind.title) with this email address."
                         : "Sent to \(kind.title) over an encrypted connection. Nothing else on this \(Platform.deviceName) is sent.")
                }

                if let result {
                    Section {
                        Label("Sent to \(result.destination)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        if let link = result.link, let url = URL(string: link) {
                            Button("Open in \(kind.title)") { openURL(url) }
                        }
                    }
                }
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                let earlier = note.sentTo.filter { $0.destination.hasPrefix(kind == .webhook ? "Webhook" : kind.title) }
                if !earlier.isEmpty {
                    Section("Sent before") {
                        ForEach(earlier.suffix(5), id: \.self) { sent in
                            LabeledContent(sent.destination, value: sent.date.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Send to \(kind.title)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result == nil ? "Cancel" : "Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Send") { send() }
                            .disabled(result != nil || (kind.needsContact && !email.contains("@")))
                    }
                }
            }
        }
        .onAppear { includeTranscript = IntegrationSettings.config(kind).includeTranscript }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #endif
    }

    private func send() {
        errorText = nil
        sending = true
        let note = self.note
        let email = self.email
        let includeTranscript = self.includeTranscript
        Task {
            do {
                let sent = try await Integrations.send(note, to: kind, contactEmail: email, includeTranscript: includeTranscript)
                store.edit(noteID) { $0.sentTo.append(sent) }
                result = sent
            } catch {
                errorText = error.localizedDescription
            }
            sending = false
        }
    }
}

/// After Enhance: send to the apps set to receive notes automatically — for Sectis, when the
/// note's own "Send to Sectis" switch is on.
@MainActor
enum AutoSend {
    static func afterEnhance(_ noteID: UUID, store: NoteStore) {
        guard let note = store.note(noteID) else { return }
        for kind in IntegrationKind.allCases where kind.canAutoSend && IntegrationSettings.isConfigured(kind) {
            if kind == .sectis {
                // Once per note: Enhance words items a little differently each time, so sending
                // again would add near-duplicates. Review & send on the Enhanced tab sends new ones.
                guard Sectis.isOn(for: note), Sectis.lastSend(of: note) == nil, !Sectis.items(in: note).isEmpty else {
                    continue
                }
            } else if !IntegrationSettings.config(kind).autoSend {
                continue
            }
            let include = IntegrationSettings.config(kind).includeTranscript
            Task {
                do {
                    let sent = try await Integrations.send(note, to: kind, contactEmail: nil, includeTranscript: include)
                    store.edit(noteID) { $0.sentTo.append(sent) }
                } catch {
                    store.lastError = "Couldn't send “\(note.displayTitle)” to \(kind.title): \(error.localizedDescription)"
                }
            }
        }
    }
}

/// Settings → Integrations.
struct IntegrationsSettingsSection: View {
    var body: some View {
        Section {
            ForEach(IntegrationKind.allCases) { kind in
                IntegrationSettingsRow(kind: kind)
            }
        } header: {
            Text("Integrations")
        } footer: {
            Text("A note is sent only when you choose Share → Send to… on it — or after Enhance, for the apps you set to receive notes automatically. Keys and tokens stay in this \(Platform.deviceName)'s Keychain.")
        }
    }
}

private struct IntegrationSettingsRow: View {
    let kind: IntegrationKind
    @State private var config = IntegrationConfig()
    @State private var keyDraft = ""
    @State private var hasKey = false
    @State private var testing = false
    @State private var status: String?
    @State private var loaded = false
    /// Sectis: why the pasted join code can't be used, and which Firebase project the saved
    /// one points to.
    @State private var keyProblem: String?
    @State private var sectisProject: String?

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text(kind.setupHelp)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if kind == .sectis {
                    sectisJoinCode
                } else if kind.needsKey {
                    if hasKey {
                        HStack {
                            Label("\(kind.keyLabel) saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Spacer()
                            Button("Remove", role: .destructive) {
                                IntegrationSettings.setSecret(nil, for: kind)
                                hasKey = false
                                status = nil
                            }
                        }
                    } else {
                        HStack {
                            SecureField(kind.keyLabel, text: $keyDraft)
                            Button("Save") {
                                IntegrationSettings.setSecret(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines), for: kind)
                                keyDraft = ""
                                hasKey = IntegrationSettings.secret(kind) != nil
                            }
                            .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                if let label = kind.targetLabel {
                    if kind == .sectis {
                        TextField(label, text: $config.target,
                                  prompt: Text(Sectis.defaultName.map { "Leave empty to use “\($0)”" } ?? "For example: Matthew, Matt"))
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.words)
                            #endif
                        Text("Separate names with commas. “Me”, “you” and “everyone” always count as you, and so does the name you give the Me speaker in a note.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        TextField(label, text: $config.target)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                    }
                }
                if kind.sendsWholeNote {
                    Toggle("Include the transcript", isOn: $config.includeTranscript)
                }
                if kind == .sectis {
                    Toggle("Send after Enhance", isOn: $config.autoSend)
                    Text("Each note has its own Send to Sectis switch, under its title. This is what that switch starts as; turn it off in a note to skip that meeting, or to look the items over and send them yourself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Send other people's items to Waiting For", isOn: Binding(
                        get: { config.sectis?.waitingFor ?? true },
                        set: { value in
                            var options = config.sectis ?? SectisOptions()
                            options.waitingFor = value
                            config.sectis = options
                        }))
                    Text("An action item that names someone else (“Send the quote — Dana”) goes to Sectis's Waiting For under their name, so you know to follow up. It comes back to Today on its date.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    #if os(macOS)
                    TextField("Sectis address", text: Binding(
                        get: { config.sectis?.address ?? "" },
                        set: { value in
                            var options = config.sectis ?? SectisOptions()
                            let text = value.trimmingCharacters(in: .whitespaces)
                            options.address = text.isEmpty ? nil : text
                            config.sectis = options
                        }), prompt: Text("https://you.github.io/sectis/"))
                        .autocorrectionDisabled()
                    Text("Lets a note's to-dos open in Sectis. Filled in for you the first time you open a Sintr link from Sectis.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    #endif
                } else if kind.canAutoSend {
                    Toggle("Send automatically after Enhance", isOn: $config.autoSend)
                }
                HStack {
                    Button(kind == .webhook ? "Send a test" : "Test connection") { test() }
                        .disabled(testing || !IntegrationSettings.isConfigured(kind))
                    if testing { ProgressView().controlSize(.small) }
                    if let status {
                        Text(status).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                Label(kind.title, systemImage: kind.systemImage)
                Spacer()
                if loaded, IntegrationSettings.isConfigured(kind) {
                    Text(config.autoSend ? "On · automatic" : "On").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            config = IntegrationSettings.config(kind)
            hasKey = IntegrationSettings.secret(kind) != nil
            if kind == .sectis { sectisProject = IntegrationSettings.secret(.sectis).flatMap(SectisFormat.parseJoinCode)?.projectId }
            loaded = true
        }
        .onChange(of: config) { _, value in
            guard loaded else { return }
            var saved = value
            if kind == .sectis {
                // Only what this row shows: the lists and folder choices may have changed since.
                var options = IntegrationSettings.config(.sectis).sectis ?? SectisOptions()
                options.waitingFor = value.sectis?.waitingFor
                options.address = value.sectis?.address
                saved.sectis = options
            }
            IntegrationSettings.save(saved, for: kind)
        }
    }

    /// Sectis: paste the join code (or type it), checked before it's saved. Not a password
    /// field: you can see what was pasted, and Paste reads the clipboard straight in.
    @ViewBuilder private var sectisJoinCode: some View {
        if hasKey {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Join code saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(sectisProject.map { "Firebase project: \($0)" } ?? "This saved code can't be read — remove it and paste it again.")
                        .font(.caption)
                        .foregroundStyle(sectisProject == nil ? Color.orange : .secondary)
                }
                Spacer()
                Button("Remove", role: .destructive) {
                    IntegrationSettings.setSecret(nil, for: kind)
                    hasKey = false
                    sectisProject = nil
                    status = nil
                }
                .buttonStyle(.borderless)
            }
        } else {
            HStack(spacing: 10) {
                PasteButton(payloadType: String.self) { strings in
                    let text = strings.joined(separator: "\n")
                    Task { @MainActor in saveJoinCode(text) }
                }
                .labelStyle(.titleAndIcon)
                Text("the code from Sectis → Settings → Sync → Add Another Device → Copy Code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            HStack {
                TextField("Join code", text: $keyDraft, prompt: Text("Or type it: SECTIS-…"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .privacySensitive()
                Button("Save") { saveJoinCode(keyDraft) }
                    .buttonStyle(.borderless)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let keyProblem {
                Label(keyProblem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .lineLimit(5)
            }
        }
    }

    private func saveJoinCode(_ text: String) {
        if let problem = SectisFormat.joinCodeProblem(text) {
            keyProblem = problem
            return
        }
        guard let code = SectisFormat.normalizedJoinCode(text) else { return }
        IntegrationSettings.setSecret(code, for: .sectis)
        keyDraft = ""
        keyProblem = nil
        status = nil
        hasKey = IntegrationSettings.secret(.sectis) != nil
        sectisProject = SectisFormat.parseJoinCode(code)?.projectId
        if !hasKey { keyProblem = "The join code couldn't be saved in this \(Platform.deviceName)'s Keychain. Try again." }
    }

    private func test() {
        testing = true
        status = nil
        Task {
            do {
                status = try await Integrations.test(kind)
            } catch {
                status = error.localizedDescription
            }
            testing = false
        }
    }
}
