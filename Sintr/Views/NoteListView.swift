import SwiftUI
#if os(macOS)
import AppKit
#endif

struct NoteListView: View {
    @Environment(NoteStore.self) private var store
    @Environment(Recorder.self) private var recorder
    @Environment(PostProcessor.self) private var post
    @Environment(AppState.self) private var appState
    @State private var search = ""
    @State private var pendingDelete: Note?
    @State private var folderNameDraft = ""
    @State private var namingFolder: FolderNaming?
    @State private var removingFolder: NoteFolder?
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    private enum FolderNaming: Identifiable {
        case new
        case rename(NoteFolder)
        var id: String {
            switch self {
            case .new: "new"
            case .rename(let folder): folder.id.uuidString
            }
        }
    }

    private func inFilter(_ note: Note) -> Bool {
        switch appState.folderFilter {
        case .all: true
        case .unfiled: store.folder(note.folderID) == nil
        case .folder(let id): note.folderID == id
        }
    }

    private var filtered: [Note] {
        let all = store.notes.filter(inFilter).sorted { $0.created > $1.created }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.searchableText.localizedCaseInsensitiveContains(query) }
    }

    private var filterTitle: String {
        switch appState.folderFilter {
        case .all: "Sintr"
        case .unfiled: "Not in a folder"
        case .folder(let id): store.folder(id)?.name ?? "Sintr"
        }
    }

    private var currentFolderID: UUID? {
        if case .folder(let id) = appState.folderFilter { return id }
        return nil
    }

    private struct NoteSection: Identifiable {
        let title: String
        var notes: [Note]
        var id: String { title }
    }

    private var sections: [NoteSection] {
        let calendar = Calendar.current
        var result: [NoteSection] = []
        for note in filtered {
            let title: String
            if calendar.isDateInToday(note.created) {
                title = "Today"
            } else if calendar.isDateInYesterday(note.created) {
                title = "Yesterday"
            } else if let days = calendar.dateComponents([.day], from: note.created, to: .now).day, days < 7 {
                title = note.created.formatted(.dateTime.weekday(.wide))
            } else {
                title = note.created.formatted(.dateTime.month(.wide).year())
            }
            if let index = result.firstIndex(where: { $0.title == title }) {
                result[index].notes.append(note)
            } else {
                result.append(NoteSection(title: title, notes: [note]))
            }
        }
        return result
    }

    var body: some View {
        @Bindable var appState = appState
        List(selection: $appState.selection) {
            if search.isEmpty {
                foldersSection
            }
            if store.notes.isEmpty {
                ContentUnavailableView(
                    "No notes yet",
                    systemImage: "note.text",
                    description: Text("Tap \(Image(systemName: "square.and.pencil")) to start one, or import a recording."))
            }
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.notes) { note in
                        NoteRow(note: note, isRecording: recorder.noteID == note.id,
                                isProcessing: post.current?.noteID == note.id,
                                folder: appState.folderFilter == .all ? store.folder(note.folderID) : nil)
                            .tag(note.id)
                            .draggable(note.id.uuidString)
                            .contextMenu {
                                if !store.folders.isEmpty {
                                    Menu("Move to", systemImage: "folder") {
                                        Button("No folder") { store.move(note.id, to: nil) }
                                            .disabled(store.folder(note.folderID) == nil)
                                        Divider()
                                        ForEach(store.folders) { folder in
                                            Button(folder.name) { store.move(note.id, to: folder.id) }
                                                .disabled(note.folderID == folder.id)
                                        }
                                    }
                                    .disabled(recorder.noteID == note.id)
                                }
                                Button("Export…", systemImage: "square.and.arrow.up") {
                                    appState.exportRequest = .init(noteID: note.id)
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    pendingDelete = note
                                }
                                .disabled(recorder.noteID == note.id)
                            }
                            .swipeActions {
                                Button("Delete", systemImage: "trash") { pendingDelete = note }
                                    .tint(.red)
                                    .disabled(recorder.noteID == note.id)
                            }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Search notes and transcripts")
        .navigationTitle(filterTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.selection = store.newNote(folderID: currentFolderID).id
                } label: {
                    Label("New note", systemImage: "square.and.pencil")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    #if os(macOS)
                    openWindow(id: "ask")
                    #else
                    appState.showAsk = true
                    #endif
                } label: {
                    Label("Ask about your notes", systemImage: "bubble.left.and.text.bubble.right")
                }
                .help("Ask about your notes (⌘J)")
            }
            #if os(macOS)
            ToolbarItem(placement: .secondaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings — meeting audio, speakers, templates, models")
            }
            #endif
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    Button("New folder…", systemImage: "folder.badge.plus") {
                        folderNameDraft = ""
                        namingFolder = .new
                    }
                    Button("Open shared folder…", systemImage: "folder.badge.person.crop") {
                        appState.folderPick = .open
                    }
                    Divider()
                    Button("Import files…", systemImage: "square.and.arrow.down") { appState.showImporter = true }
                    Button("Export all notes…", systemImage: "square.and.arrow.up") {
                        appState.exportRequest = .init(noteID: nil)
                    }
                    .disabled(store.notes.isEmpty)
                    #if os(iOS)
                    Divider()
                    Button("Settings", systemImage: "gear") { appState.showSettings = true }
                    #endif
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.displayTitle ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete note and recording", role: .destructive) {
                if let note = pendingDelete {
                    if appState.selection == note.id { appState.selection = nil }
                    post.cancel(noteID: note.id)
                    store.delete(note.id)
                }
                pendingDelete = nil
            }
        } message: {
            Text("This can't be undone. Export it first if you might want it back.")
        }
        .alert(namingTitle, isPresented: Binding(get: { namingFolder != nil }, set: { if !$0 { namingFolder = nil } })) {
            TextField("Name", text: $folderNameDraft)
            Button(namingButton) { finishNaming() }
            Button("Cancel", role: .cancel) { namingFolder = nil }
        }
        .confirmationDialog(
            removingFolder.map { $0.isShared ? "Stop using “\($0.name)” on this \(Platform.deviceName)?" : "Delete the folder “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { removingFolder != nil }, set: { if !$0 { removingFolder = nil } }),
            titleVisibility: .visible
        ) {
            Button(removingFolder?.isShared == true ? "Stop using it here" : "Delete folder, keep notes", role: .destructive) {
                if let folder = removingFolder {
                    if currentFolderID == folder.id { appState.folderFilter = .all }
                    store.removeFolder(folder.id)
                }
                removingFolder = nil
            }
        } message: {
            Text(removingFolder?.isShared == true
                 ? "Its notes stay in the shared place for everyone else, and you can open it again any time."
                 : "Its notes stay in Sintr, outside any folder.")
        }
    }

    // MARK: Folders

    @ViewBuilder private var foldersSection: some View {
        if !store.folders.isEmpty {
            Section("Folders") {
                folderRow(title: "All notes", systemImage: "tray.full", count: store.notes.count, filter: .all)
                ForEach(store.folders) { folder in
                    folderRow(
                        title: folder.name,
                        systemImage: folder.isShared ? "folder.badge.person.crop" : "folder",
                        count: store.notes.filter { $0.folderID == folder.id }.count,
                        filter: .folder(folder.id),
                        problem: store.folderProblems[folder.id])
                        .dropDestination(for: String.self) { items, _ in
                            for item in items { if let id = UUID(uuidString: item) { store.move(id, to: folder.id) } }
                            return true
                        }
                        .contextMenu { folderMenu(folder) }
                }
                folderRow(title: "Not in a folder", systemImage: "tray", count: store.notes.filter { store.folder($0.folderID) == nil }.count,
                          filter: .unfiled)
                    .dropDestination(for: String.self) { items, _ in
                        for item in items { if let id = UUID(uuidString: item) { store.move(id, to: nil) } }
                        return true
                    }
            }
        }
    }

    private func folderRow(title: String, systemImage: String, count: Int, filter: AppState.FolderFilter,
                           problem: String? = nil) -> some View {
        Button {
            appState.folderFilter = filter
        } label: {
            HStack {
                Label(title, systemImage: problem == nil ? systemImage : "exclamationmark.triangle")
                    .foregroundStyle(problem == nil ? Color.primary : Color.orange)
                Spacer()
                Text("\(count)").foregroundStyle(.secondary).font(.caption)
                if appState.folderFilter == filter {
                    Image(systemName: "checkmark").foregroundStyle(.tint).font(.caption)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fontWeight(appState.folderFilter == filter ? .semibold : .regular)
        .help(problem ?? title)
    }

    @ViewBuilder private func folderMenu(_ folder: NoteFolder) -> some View {
        Button("New note here", systemImage: "square.and.pencil") {
            appState.folderFilter = .folder(folder.id)
            appState.selection = store.newNote(folderID: folder.id).id
        }
        Button("Rename…", systemImage: "pencil") {
            folderNameDraft = folder.name
            namingFolder = .rename(folder)
        }
        if folder.isShared {
            #if os(macOS)
            if let location = store.sharedLocation(folder.id) {
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([location])
                }
            }
            #endif
            Button("Check for changes", systemImage: "arrow.clockwise") { store.refreshSharedFolders() }
        } else {
            Button("Share…", systemImage: "folder.badge.person.crop") { appState.folderPick = .share(folder.id) }
        }
        Button("Export…", systemImage: "square.and.arrow.up") {
            appState.exportRequest = .init(noteID: nil, folderID: folder.id)
        }
        Divider()
        Button(folder.isShared ? "Stop using here…" : "Delete folder…", systemImage: "trash", role: .destructive) {
            removingFolder = folder
        }
    }

    private var namingTitle: String {
        if case .rename = namingFolder { return "Rename folder" }
        return "New folder"
    }

    private var namingButton: String {
        if case .rename = namingFolder { return "Rename" }
        return "Create"
    }

    private func finishNaming() {
        let name = folderNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { namingFolder = nil; return }
        switch namingFolder {
        case .new:
            let folder = store.createFolder(named: name)
            appState.folderFilter = .folder(folder.id)
        case .rename(let folder):
            store.renameFolder(folder.id, to: name)
        case nil:
            break
        }
        namingFolder = nil
    }
}

private struct NoteRow: View {
    let note: Note
    let isRecording: Bool
    let isProcessing: Bool
    var folder: NoteFolder?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if isRecording {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                } else if isProcessing {
                    ProgressView().controlSize(.mini)
                }
                Text(note.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !note.enhanced.isEmpty {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.tint)
                        .font(.caption)
                }
            }
            HStack(spacing: 6) {
                Text(note.created.formatted(date: .omitted, time: .shortened))
                if note.duration > 0 {
                    Text("·")
                    Text(Note.durationText(note.duration))
                }
                if let folder {
                    Text("·")
                    Label(folder.name, systemImage: folder.isShared ? "folder.badge.person.crop" : "folder")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            let preview = note.preview
            if !preview.isEmpty {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }
}
