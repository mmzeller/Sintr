import SwiftUI

// MARK: - Where the to-dos go

/// Where a note's to-dos go in Sectis: the Inbox, or one of your projects or areas — and, for
/// a note in a folder, whether that's where the whole folder's notes go. Reads your lists
/// from Sectis the first time it shows (they're kept, so it works offline after that).
struct SectisPlacePicker: View {
    let noteID: UUID
    /// Just the list's name (the Mac's note header); otherwise "Goes to …".
    var compact = false

    @Environment(NoteStore.self) private var store
    @State private var places: [SectisFormat.Place] = Sectis.knownPlaces
    @State private var loading = false
    @State private var problem: String?
    /// Read once each time Sintr runs; Refresh Lists reads again.
    nonisolated(unsafe) private static var loadedThisRun = false

    private var note: Note { store.note(noteID) ?? Note() }

    var body: some View {
        let current = Sectis.place(for: note)
        let folder = store.folder(note.folderID)
        Menu {
            Button {
                choose(.inbox)
            } label: {
                Label("Inbox", systemImage: current.isInbox ? "checkmark" : "tray")
            }
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                Section(group.title) {
                    ForEach(group.places, id: \.self) { place in
                        Button {
                            choose(place)
                        } label: {
                            Label(place.title, systemImage: current == place ? "checkmark" : icon(place))
                        }
                    }
                }
            }
            if let folder {
                Divider()
                if Sectis.folderPlace(folder.id) == current {
                    Label("Where “\(folder.name)” notes go", systemImage: "folder")
                } else {
                    Button("Use for Every Note in “\(folder.name)”", systemImage: "folder") {
                        Sectis.setFolderPlace(current.isInbox ? nil : current, for: folder.id)
                        if current.isInbox { store.edit(noteID) { $0.sectisPlace = nil } }
                    }
                }
            }
            Divider()
            Button(loading ? "Reading Your Lists…" : "Refresh Lists", systemImage: "arrow.clockwise") {
                Task { await load() }
            }
            .disabled(loading)
            if let problem {
                Text(problem)
            }
        } label: {
            if compact {
                Label(current.title, systemImage: icon(current))
            } else {
                Label("Goes to \(current.fullTitle)", systemImage: icon(current))
            }
        }
        .help("Where this note's to-dos go in Sectis: the Inbox, or one of your projects or areas")
        .task {
            if !Self.loadedThisRun || places.isEmpty { await load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sintrIntegrationsChanged)) { _ in
            places = Sectis.knownPlaces
        }
    }

    private struct PlaceGroup {
        let title: String
        let places: [SectisFormat.Place]
    }

    /// Each area with its projects, then projects that aren't in an area.
    private var groups: [PlaceGroup] {
        var result: [PlaceGroup] = []
        var loose: [SectisFormat.Place] = []
        for place in places {
            if place.kind == .area {
                result.append(PlaceGroup(title: place.title, places: [place]))
            } else if place.area != nil, let last = result.indices.last, result[last].title == place.area {
                result[last] = PlaceGroup(title: result[last].title, places: result[last].places + [place])
            } else {
                loose.append(place)
            }
        }
        if !loose.isEmpty { result.append(PlaceGroup(title: "Projects", places: loose)) }
        return result
    }

    private func icon(_ place: SectisFormat.Place) -> String {
        switch place.kind {
        case .inbox: "tray"
        case .project: "circle.dashed"
        case .area: "square.stack"
        }
    }

    private func choose(_ place: SectisFormat.Place) {
        store.edit(noteID) { $0.sectisPlace = place }
    }

    private func load() async {
        guard let code = IntegrationSettings.secret(.sectis) ?? (ScreenshotDemo.isActive ? "" : nil) else { return }
        loading = true
        problem = nil
        do {
            places = try await Sectis.refreshPlaces(joinCode: code)
            Self.loadedThisRun = true
        } catch {
            problem = "Couldn't read your lists: \(error.localizedDescription)"
        }
        loading = false
    }
}

// MARK: - What became of them

/// The to-dos a note sent to Sectis and what's become of them — done, still open, or waiting
/// on someone — read from Sectis when the note opens. On a Mac, each opens in Sectis.
struct SectisSentList: View {
    let note: Note

    @Environment(\.openURL) private var openURL
    @State private var states: [SectisFormat.TodoState]?
    @State private var loading = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(summary)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await load() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Check Sectis again")
                }
            }
            ForEach(states ?? [], id: \.id) { state in
                #if os(macOS)
                if let url = Sectis.webLink(toTodo: state.id) {
                    Button {
                        openURL(url)
                    } label: {
                        row(state)
                    }
                    .buttonStyle(.plain)
                    .help("Open in Sectis")
                } else {
                    row(state)
                }
                #else
                row(state)
                #endif
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: note.sentTo.count) { await load() }
    }

    private var summary: String {
        guard let states else { return "In Sectis" }
        if states.isEmpty { return "Not in Sectis any more" }
        let done = states.filter(\.isFinished).count
        return "\(done) of \(states.count) done in Sectis"
    }

    private func row(_ state: SectisFormat.TodoState) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol(state))
                .foregroundStyle(color(state))
                .accessibilityLabel(Text(statusWord(state)))
            VStack(alignment: .leading, spacing: 1) {
                Text(state.title.isEmpty ? "Untitled to-do" : state.title)
                    .strikethrough(state.isFinished)
                    .foregroundStyle(state.isFinished ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = detail(state) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .contentShape(Rectangle())
    }

    private func symbol(_ state: SectisFormat.TodoState) -> String {
        if state.status == .done { return "checkmark.circle.fill" }
        if state.status == .canceled { return "xmark.circle" }
        return state.waitingOn != nil ? "hourglass" : "circle"
    }

    private func color(_ state: SectisFormat.TodoState) -> Color {
        if state.status == .done { return .green }
        if state.waitingOn != nil { return .orange }
        return .secondary
    }

    private func statusWord(_ state: SectisFormat.TodoState) -> String {
        switch state.status {
        case .done: "Done"
        case .canceled: "Canceled"
        default: state.waitingOn != nil ? "Waiting" : "Open"
        }
    }

    /// "Waiting on Dana · follow up Oct 30 · Q4 streaming upgrade".
    private func detail(_ state: SectisFormat.TodoState) -> String? {
        var parts: [String] = []
        if let person = state.waitingOn {
            parts.append("Waiting on \(person)")
            if let day = state.followUp, let date = Sectis.date(fromDay: day) {
                parts.append("follow up \(shortDate(date))")
            }
        } else if !state.isFinished, let day = state.deadline, let date = Sectis.date(fromDay: day) {
            parts.append("Due \(shortDate(date))")
        }
        if state.status == .canceled { parts.append("Canceled") }
        if let place = Sectis.placeTitle(projectID: state.projectId, areaID: state.areaId) { parts.append(place) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Oct 31".
    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func load() async {
        guard let code = IntegrationSettings.secret(.sectis) ?? (ScreenshotDemo.isActive ? "" : nil) else { return }
        loading = true
        do {
            states = try await Sectis.states(of: note, joinCode: code)
            problem = nil
        } catch {
            problem = "Couldn't check Sectis: \(error.localizedDescription)"
        }
        loading = false
    }
}

// MARK: - The note's card

/// The note's Sectis card: on iPhone its Send to Sectis switch; where the to-dos go; after
/// Enhance, how many action items there are, Review & send, and — once sent — what's become
/// of them in Sectis.
struct SectisCard: View {
    let note: Note
    let byDefault: Bool
    /// The note has enhanced notes (so there are items to show).
    let enhanced: Bool
    @Environment(NoteStore.self) private var store
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if os(iOS)
            Toggle(isOn: Binding(
                get: { Sectis.isOn(for: store.note(note.id), byDefault: byDefault) },
                set: { value in store.edit(note.id) { $0.sendToSectis = value } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send to Sectis")
                    Text("After Enhance, your action items go to Sectis, and other people's to Waiting For.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            #endif
            SectisPlacePicker(noteID: note.id)
                .font(.subheadline)
            if enhanced {
                Divider()
                let items = Sectis.items(in: note)
                Label(status(items), systemImage: "checklist")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Review & send…") {
                    appState.sendRequest = .init(noteID: note.id, kind: .sectis)
                }
                .buttonStyle(.bordered)
                .disabled(items.isEmpty)
                .help("Pick which action items go to Sectis and adjust them first")
                if Sectis.lastSend(of: note) != nil {
                    Divider()
                    SectisSentList(note: note)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func status(_ items: [ActionItem]) -> String {
        guard !items.isEmpty else { return "No action items for you in this note" }
        let counts = Sectis.countText(items)
        if let sent = Sectis.lastSend(of: note) {
            return "\(counts) · sent \(sent.date.formatted(date: .abbreviated, time: .shortened))"
        }
        return "\(counts) · not sent yet"
    }
}

// MARK: - Review & send

/// Review the action items before they go to Sectis: untick any you don't want, fix the
/// wording or the deadline, change who an item is waiting on, and pick where they go.
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
        /// Someone else's: who it's waiting on.
        var person: String
        var hasDeadline: Bool
        /// For your items, the deadline; for someone else's, when to follow up.
        var deadline: Date

        var isWaiting: Bool { item.waitingOn != nil }

        init(_ item: ActionItem) {
            self.item = item
            title = item.title
            person = item.waitingOn ?? ""
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
            if isWaiting {
                let name = person.trimmingCharacters(in: .whitespacesAndNewlines)
                result.waitingOn = name.isEmpty ? item.waitingOn : name
            }
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
                    SectisPlacePicker(noteID: noteID)
                } footer: {
                    Text("Each to-do links back to this note, and is tagged \(Sectis.tagName).")
                }

                Section {
                    if loaded, drafts.isEmpty {
                        Text(Sectis.noItemsMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach($drafts) { $draft in
                        if !draft.isWaiting { DraftRow(draft: $draft) }
                    }
                } header: {
                    Text("Your action items in “\(note.displayTitle)”")
                } footer: {
                    Text("Untick any you don't want and fix the wording or deadline. They're encrypted on this \(Platform.deviceName) first. One that's already in Sectis isn't added twice — even if you reworded it.")
                }

                if drafts.contains(where: \.isWaiting) {
                    Section {
                        ForEach($drafts) { $draft in
                            if draft.isWaiting { DraftRow(draft: $draft) }
                        }
                    } header: {
                        Text("Waiting on others")
                    } footer: {
                        Text("These go to Sectis's Waiting For, under the person's name, and come back to Today on the follow-up date.")
                    }
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
            drafts = Sectis.items(in: note).map(Draft.init)
            loaded = true
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
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

    /// One action item: a tick, its wording, who it's waiting on, and its date.
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
                Group {
                    if draft.isWaiting {
                        HStack(spacing: 6) {
                            Image(systemName: "hourglass")
                                .foregroundStyle(.secondary)
                            TextField("Waiting on", text: $draft.person, prompt: Text("Who"))
                                .labelsHidden()
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.words)
                                #endif
                        }
                    }
                    HStack(spacing: 8) {
                        if draft.hasDeadline {
                            Image(systemName: draft.isWaiting ? "calendar" : "flag")
                                .foregroundStyle(.secondary)
                            DatePicker(draft.isWaiting ? "Follow up" : "Deadline", selection: $draft.deadline, displayedComponents: .date)
                                .labelsHidden()
                                .fixedSize()
                            Button {
                                draft.hasDeadline = false
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(draft.isWaiting ? "No follow-up date" : "Remove deadline")
                            .help(draft.isWaiting ? "No follow-up date" : "No deadline")
                        } else {
                            Button {
                                draft.hasDeadline = true
                            } label: {
                                Label(draft.isWaiting ? "Add follow-up date" : "Add deadline",
                                      systemImage: draft.isWaiting ? "calendar" : "flag")
                            }
                            .buttonStyle(.borderless)
                        }
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
