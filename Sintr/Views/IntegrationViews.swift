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

/// Review your action items before they go to Sectis: untick any you don't want, and fix
/// the wording or the deadline.
struct SectisSendSheet: View {
    let noteID: UUID

    @Environment(NoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [Draft] = []
    @State private var loaded = false
    @State private var sending = false
    @State private var result: NoteSend?
    @State private var errorText: String?

    struct Draft: Identifiable {
        let id = UUID()
        let item: ActionItem
        var include = true
        var title: String
        var hasDeadline: Bool
        var deadline: Date

        init(_ item: ActionItem) {
            self.item = item
            title = item.title
            let due = item.deadline.flatMap(Sectis.date(fromDay:))
            hasDeadline = due != nil
            deadline = due ?? Calendar.current.startOfDay(for: Date())
        }

        /// The item as it will be sent.
        var adjusted: ActionItem {
            var result = item
            result.originalTitle = item.idTitle
            result.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            result.deadline = hasDeadline ? Sectis.day(from: deadline) : nil
            return result
        }
    }

    private var note: Note { store.note(noteID) ?? Note() }
    private var sendTitle: String { chosen.isEmpty ? "Send" : "Send \(chosen.count)" }
    private var chosen: [ActionItem] {
        drafts.filter { $0.include && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }.map(\.adjusted)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if loaded, drafts.isEmpty {
                        Text(Sectis.noItemsMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach($drafts) { $draft in
                        DraftRow(draft: $draft)
                    }
                } header: {
                    Text("Your action items in “\(note.displayTitle)”")
                } footer: {
                    Text("Untick any you don't want and fix the wording or deadline. They go to your Sectis Inbox, tagged \(Sectis.tagName), encrypted on this \(Platform.deviceName) first. One that's already in Sectis isn't added twice — even if you reworded it.")
                }

                if let result {
                    Section {
                        Label("Sent to \(result.destination)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                let earlier = note.sentTo.filter { $0.destination.hasPrefix(IntegrationKind.sectis.title) }
                if !earlier.isEmpty {
                    Section("Sent before") {
                        ForEach(earlier.suffix(5), id: \.self) { sent in
                            LabeledContent(sent.destination, value: sent.date.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Send to Sectis")
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
                        Button(sendTitle) { send() }
                            .disabled(result != nil || chosen.isEmpty)
                    }
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            drafts = Sectis.myItems(in: note).map(Draft.init)
            loaded = true
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 440)
        #endif
    }

    private func send() {
        errorText = nil
        sending = true
        let note = self.note
        let items = chosen
        Task {
            do {
                guard let code = IntegrationSettings.secret(.sectis) else { throw IntegrationError.notSetUp(.sectis) }
                let sent = try await Sectis.send(note, items: items, joinCode: code)
                store.edit(noteID) { $0.sentTo.append(sent) }
                result = sent
            } catch {
                errorText = error.localizedDescription
            }
            sending = false
        }
    }

    /// One action item: a tick, its wording and its deadline.
    private struct DraftRow: View {
        @Binding var draft: Draft

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button {
                        draft.include.toggle()
                    } label: {
                        Image(systemName: draft.include ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(draft.include ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text(draft.include ? "Will be sent" : "Won't be sent"))
                    .help(Text(draft.include ? "Don't send this one" : "Send this one"))
                    TextField("To-do", text: $draft.title, prompt: Text("To-do"), axis: .vertical)
                        .labelsHidden()
                        .foregroundStyle(draft.include ? .primary : .secondary)
                }
                HStack(spacing: 8) {
                    if draft.hasDeadline {
                        Image(systemName: "flag")
                            .foregroundStyle(.secondary)
                        DatePicker("Deadline", selection: $draft.deadline, displayedComponents: .date)
                            .labelsHidden()
                            .fixedSize()
                        Button {
                            draft.hasDeadline = false
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove deadline")
                        .help("No deadline")
                    } else {
                        Button {
                            draft.hasDeadline = true
                        } label: {
                            Label("Add deadline", systemImage: "flag")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .font(.callout)
                .padding(.leading, 34)
                .disabled(!draft.include)
            }
            .padding(.vertical, 2)
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
                guard Sectis.isOn(for: note), Sectis.lastSend(of: note) == nil, !Sectis.myItems(in: note).isEmpty else {
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
                if kind == .sectis {
                    Toggle("Send after Enhance", isOn: $config.autoSend)
                    Text("Each note has its own Send to Sectis switch, under its title. This is what that switch starts as; turn it off in a note to skip that meeting, or to look the items over and send them yourself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
