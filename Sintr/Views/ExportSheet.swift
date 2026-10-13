import SwiftUI

/// Export one note or all of them as Markdown, text or a Sintr backup — share it (AirDrop,
/// Mail, Files…) or save it to a folder. Nothing is sent until you pick where it goes.
struct ExportSheet: View {
    let request: AppState.ExportRequest

    @Environment(NoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var format: ExportFormat = .markdown
    @State private var includeAudio = false
    @State private var files: [URL] = []
    @State private var errorText: String?
    @State private var showSave = false
    @State private var savedMessage: String?

    private var notes: [Note] {
        if let id = request.noteID { return store.note(id).map { [$0] } ?? [] }
        return store.notes.sorted { $0.created > $1.created }
    }

    private var hasAudio: Bool { notes.contains { !$0.recordings.isEmpty } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text(request.noteID == nil ? "Export all \(notes.count) notes as" : "Export “\(notes.first?.displayTitle ?? "")” as")
                } footer: {
                    Text(format.explanation)
                }

                if hasAudio {
                    Section {
                        Toggle("Include audio recordings", isOn: $includeAudio)
                    } footer: {
                        Text("Adds the .m4a audio files. A Sintr backup on its own carries no audio; import the audio separately to keep it.")
                    }
                }

                Section {
                    if files.isEmpty {
                        Text(errorText ?? "Preparing…").foregroundStyle(.secondary)
                    } else {
                        ShareLink(items: files) {
                            Label(Platform.isMac ? "Share (AirDrop, Mail, Messages…)" : "Share (AirDrop, Files, Mail…)",
                                  systemImage: "square.and.arrow.up")
                        }
                        Button {
                            showSave = true
                        } label: {
                            Label(Platform.isMac ? "Save to a folder…" : "Save to Files…", systemImage: "folder")
                        }
                        Text(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let savedMessage {
                        Label(savedMessage, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Export")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileExporter(
                isPresented: $showSave,
                document: ExportDocument(urls: files, folderName: folderName),
                contentType: ExportDocument(urls: files, folderName: folderName).contentType,
                defaultFilename: ExportDocument(urls: files, folderName: folderName).defaultFilename
            ) { result in
                switch result {
                case .success(let url): savedMessage = "Saved \(url.lastPathComponent)"
                case .failure(let error): errorText = error.localizedDescription
                }
            }
        }
        .onAppear {
            format = request.format
            prepare()
        }
        .onChange(of: format) { prepare() }
        .onChange(of: includeAudio) { prepare() }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }

    private var folderName: String {
        "Sintr notes \(Date().formatted(.iso8601.year().month().day()))"
    }

    private func prepare() {
        savedMessage = nil
        do {
            errorText = nil
            files = try Exporter.writeFiles(notes, format: format, store: store, includeAudio: includeAudio)
        } catch {
            files = []
            errorText = "Couldn't prepare the export: \(error.localizedDescription)"
        }
    }
}
