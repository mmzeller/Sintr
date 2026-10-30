import SwiftUI

struct ContentView: View {
    @Environment(NoteStore.self) private var store
    @Environment(Recorder.self) private var recorder
    @Environment(Importer.self) private var importer
    @Environment(AppState.self) private var appState
    @Environment(PostProcessor.self) private var post
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @State private var showStorageWarning = Storage.current.warning != nil
    /// The shared-folder action the file picker is open for (kept after the picker closes).
    @State private var activePick: AppState.FolderPick?
    @AppStorage(AppSettings.setupDone) private var setupDone = false

    var body: some View {
        @Bindable var appState = appState
        @Bindable var importer = importer

        NavigationSplitView(columnVisibility: $columnVisibility) {
            NoteListView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            if let id = appState.selection, store.note(id) != nil {
                NoteView(noteID: id)
                    .id(id)
            } else {
                EmptyDetailView()
            }
        }
        .fileImporter(
            isPresented: Binding(
                get: { appState.showImporter || appState.folderPick != nil },
                set: { if !$0 { appState.showImporter = false; appState.folderPick = nil } }),
            allowedContentTypes: appState.folderPick == nil && activePick == nil ? Importer.types : [.folder],
            allowsMultipleSelection: appState.folderPick == nil && activePick == nil
        ) { result in
            if let pick = activePick {
                activePick = nil
                guard case .success(let urls) = result, let url = urls.first else { return }
                do {
                    switch pick {
                    case .share(let id):
                        try store.share(id, at: url)
                    case .open:
                        let folder = try store.openSharedFolder(at: url)
                        appState.folderFilter = .folder(folder.id)
                    }
                } catch {
                    appState.folderError = error.localizedDescription
                }
                return
            }
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            Task {
                await importer.importFiles(urls, into: store)
                if urls.count == 1, let created = importer.lastCreatedNote {
                    appState.selection = created
                }
            }
        }
        .task { ScreenshotDemo.open(store: store, appState: appState, post: post) }
        // sintr:// links from Sectis: open a note, or start one (SintrLinks.swift).
        .modifier(SintrLinkHandling())
        .onChange(of: appState.folderPick) { _, pick in
            if let pick { activePick = pick }
        }
        .onChange(of: appState.showImporter) { _, showing in
            if showing { activePick = nil }
        }
        .alert("Folder problem", isPresented: Binding(
            get: { appState.folderError != nil },
            set: { if !$0 { appState.folderError = nil } }
        )) {
            Button("OK") { appState.folderError = nil }
        } message: {
            Text(appState.folderError ?? "")
        }
        #if os(iOS)
        .sheet(isPresented: $appState.showAsk) {
            NavigationStack {
                LibraryAskView()
            }
        }
        #endif
        .sheet(item: $appState.exportRequest) { request in
            ExportSheet(request: request)
        }
        .sheet(isPresented: Binding(
            get: { appState.showSetup || !setupDone },
            set: { if !$0 { appState.showSetup = false; setupDone = true } }
        )) {
            SetupView()
        }
        .sheet(item: $appState.sendRequest) { request in
            if request.kind == .sectis {
                SectisSendSheet(noteID: request.noteID)
            } else {
                SendSheet(noteID: request.noteID, kind: request.kind)
            }
        }
        .sheet(isPresented: $appState.showSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { appState.showSettings = false }
                        }
                    }
            }
        }
        .sheet(item: Binding(
            get: { appState.enhanceNoteID.map(IdentifiedID.init) },
            set: { appState.enhanceNoteID = $0?.id }
        )) { item in
            EnhanceSheet(noteID: item.id)
        }
        .sheet(item: Binding(
            get: { appState.translateNoteID.map(IdentifiedID.init) },
            set: { appState.translateNoteID = $0?.id }
        )) { item in
            TranslateSheet(noteID: item.id)
        }
        .overlay(alignment: .bottom) {
            if importer.isWorking {
                ImportProgressBanner()
                    .padding()
            }
        }
        .alert("Import", isPresented: Binding(
            get: { importer.summary != nil },
            set: { if !$0 { importer.summary = nil } }
        )) {
            Button("OK") { importer.summary = nil }
        } message: {
            Text(importer.summary ?? "")
        }
        .alert("Download Apple's speech model?", isPresented: Binding(
            get: { recorder.pendingModelDownload != nil },
            set: { if !$0 { recorder.pendingModelDownload = nil } }
        )) {
            Button("Download") { Task { await recorder.downloadModelAndStart() } }
            Button("Not now", role: .cancel) { recorder.pendingModelDownload = nil }
        } message: {
            Text("Transcription runs entirely on this \(Platform.deviceName), using a speech model Apple provides. It needs a one-time download from Apple for \(recorder.pendingModelDownload.map(SpeechSupport.displayName) ?? "your language"). Your audio and notes are never uploaded.")
        }
        .alert("Download speaker detection?", isPresented: Binding(
            get: { recorder.pendingSpeakerDownload },
            set: { if !$0 { recorder.pendingSpeakerDownload = false } }
        )) {
            Button("Download") { Task { await recorder.answerSpeakerDownload(download: true) } }
            Button("Not now") { Task { await recorder.answerSpeakerDownload(download: false) } }
        } message: {
            Text("“Detect speakers” is on. Telling voices apart runs on this \(Platform.deviceName) with open models — a few dozen MB, downloaded once from Hugging Face. Your audio is never uploaded. (You can turn it off next to the Record button.)")
        }
        .alert("Recording problem", isPresented: Binding(
            get: { recorder.errorMessage != nil },
            set: { if !$0 { recorder.errorMessage = nil } }
        )) {
            Button("OK") { recorder.errorMessage = nil }
        } message: {
            Text(recorder.errorMessage ?? "")
        }
        .alert("Where your notes are", isPresented: $showStorageWarning) {
            Button("OK") {}
        } message: {
            Text(Storage.current.warning ?? "")
        }
        .alert("Sintr", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }
}

struct IdentifiedID: Identifiable {
    let id: UUID
}

private struct ImportProgressBanner: View {
    @Environment(Importer.self) private var importer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(importer.status.isEmpty ? "Working…" : importer.status)
                .font(.callout)
            ProgressView(value: importer.progress)
        }
        .padding()
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 8)
    }
}

private struct EmptyDetailView: View {
    @Environment(NoteStore.self) private var store
    @Environment(Recorder.self) private var recorder
    @Environment(AppState.self) private var appState
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("Private notes for meetings")
                .font(.title2.weight(.semibold))
            Text("Type your own notes while Sintr listens and writes a transcript on this \(Platform.deviceName). Afterwards, Enhance turns both into clean notes.\nNothing leaves this \(Platform.deviceName) unless you send or export it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            HStack(spacing: 12) {
                Button {
                    appState.selection = store.newNote().id
                } label: {
                    Label("New note", systemImage: "square.and.pencil")
                }
                .buttonStyle(.bordered)
                Button {
                    let id = store.newNote().id
                    appState.selection = id
                    Task { await recorder.start(noteID: id, store: store) }
                } label: {
                    Label("Record now", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(recorder.isActive)
                if !store.notes.isEmpty {
                    Button {
                        #if os(macOS)
                        openWindow(id: "ask")
                        #else
                        appState.showAsk = true
                        #endif
                    } label: {
                        Label("Ask about your notes", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.large)
            PostProcessingRow(noteID: nil)
                .frame(maxWidth: 520)
            LiveInputs()
                .padding(.top, 6)
        }
        .padding(30)
    }
}
