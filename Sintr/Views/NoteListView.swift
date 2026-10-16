import SwiftUI

struct NoteListView: View {
    @Environment(NoteStore.self) private var store
    @Environment(Recorder.self) private var recorder
    @Environment(PostProcessor.self) private var post
    @Environment(AppState.self) private var appState
    @State private var search = ""
    @State private var pendingDelete: Note?

    private var filtered: [Note] {
        let all = store.notes.sorted { $0.created > $1.created }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.searchableText.localizedCaseInsensitiveContains(query) }
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
                                isProcessing: post.current?.noteID == note.id)
                            .tag(note.id)
                            .contextMenu {
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
        .navigationTitle("Sintr")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.selection = store.newNote().id
                } label: {
                    Label("New note", systemImage: "square.and.pencil")
                }
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
    }
}

private struct NoteRow: View {
    let note: Note
    let isRecording: Bool
    let isProcessing: Bool

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
