import SwiftUI

/// "Send to Notion / HubSpot / …" for one note.
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
    /// Sectis gets only your action items.
    private var items: [ActionItem] { kind == .sectis ? Sectis.myItems(in: note) : [] }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Note", value: note.displayTitle)
                    if kind == .sectis {
                        LabeledContent("Sends", value: items.isEmpty ? "Nothing yet" : "Your action items (\(items.count))")
                    } else {
                        LabeledContent("Sends", value: note.enhanced.isEmpty ? (note.myNotes.isEmpty ? "Title only" : "Your notes") : "Enhanced notes")
                        if !note.transcript.isEmpty {
                            Toggle("Include the transcript", isOn: $includeTranscript)
                        }
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
                    if kind == .sectis {
                        Text("Added to your Sectis Inbox, tagged \(Sectis.tagName). Each to-do is encrypted on this \(Platform.deviceName) before it's sent, and an item already sent from this note isn't added twice.")
                    } else {
                        Text(kind.needsContact
                             ? "The note is added to the person in \(kind.title) with this email address."
                             : "Sent to \(kind.title) over an encrypted connection. Nothing else on this \(Platform.deviceName) is sent.")
                    }
                }

                if kind == .sectis {
                    Section("Your action items") {
                        if items.isEmpty {
                            Text(Sectis.noItemsMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(items, id: \.self) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(item.title, systemImage: "circle")
                                    if let deadline = item.deadline {
                                        Text("Deadline \(Self.dayText(deadline))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding(.leading, 28)
                                    }
                                }
                            }
                        }
                    }
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
                            .disabled(result != nil || (kind.needsContact && !email.contains("@")) || (kind == .sectis && items.isEmpty))
                    }
                }
            }
        }
        .onAppear { includeTranscript = IntegrationSettings.config(kind).includeTranscript }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #endif
    }

    /// "2026-10-31" → "Oct 31, 2026".
    static func dayText(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return day }
        return date.formatted(date: .abbreviated, time: .omitted)
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

/// After Enhance: send to the apps set to receive notes automatically.
@MainActor
enum AutoSend {
    static func afterEnhance(_ noteID: UUID, store: NoteStore) {
        guard let note = store.note(noteID) else { return }
        for kind in IntegrationKind.allCases where kind.canAutoSend && IntegrationSettings.config(kind).autoSend
            && IntegrationSettings.isConfigured(kind) {
            if kind == .sectis {
                // Once per note: Enhance words items a little differently each time, so sending
                // again would add near-duplicates. Share → Send to → Sectis sends new ones later.
                if note.sentTo.contains(where: { $0.destination.hasPrefix(kind.title) }) || Sectis.myItems(in: note).isEmpty {
                    continue
                }
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

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text(kind.setupHelp)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if kind.needsKey {
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
                if kind.canAutoSend {
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
            loaded = true
        }
        .onChange(of: config) { _, value in
            if loaded { IntegrationSettings.save(value, for: kind) }
        }
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
