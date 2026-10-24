import SwiftUI

@main
struct SintrApp: App {
    @State private var store = NoteStore()
    @State private var hub: AudioHub
    @State private var post: PostProcessor
    @State private var recorder: Recorder
    @State private var importer: Importer
    @State private var appState = AppState()
    @State private var templates = TemplateStore()
    @State private var askStore = AskStore()
    #if os(macOS)
    @State private var localAPI = LocalAPIServer()
    #endif
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppSettings.register()
        ScreenshotDemo.prepare()
        PortableSettings.start()
        SpeakerDetector.blockNetwork()
        #if os(macOS)
        StorageCheck.runIfRequested()
        LayoutCheck.runIfRequested()
        // Command-line uses of the same app: these never open a window and exit when done.
        MCPServer.runIfRequested()
        SintrCommandLine.runIfRequested()
        #endif
        ActivityLog.startSession()
        #if os(macOS)
        HangWatch.start()
        #endif
        let hub = AudioHub()
        let post = PostProcessor()
        _hub = State(initialValue: hub)
        _post = State(initialValue: post)
        _recorder = State(initialValue: Recorder(hub: hub, post: post))
        _importer = State(initialValue: Importer(post: post))
    }

    var body: some Scene {
        #if os(macOS)
        Window("Sintr", id: "main") {
            root
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 1100, height: 760)
        .commands { SintrCommands(store: store, recorder: recorder, appState: appState) }

        SwiftUI.Settings {
            SettingsView()
                .environment(store)
                .environment(recorder)
                .environment(hub)
                .environment(post)
                .environment(templates)
                .environment(localAPI)
                .frame(width: 640, height: 780)
        }

        Window("Ask Sintr", id: "ask") {
            NavigationStack {
                LibraryAskView()
            }
            .environment(store)
            .environment(askStore)
            .environment(appState)
            .frame(minWidth: 520, minHeight: 480)
        }
        .defaultSize(width: 720, height: 720)

        Window("Activity Log", id: ActivityLogView.windowID) {
            ActivityLogView()
        }
        .defaultSize(width: 760, height: 520)
        #else
        WindowGroup {
            root
        }
        #endif
    }

    private var root: some View {
        ContentView()
            .environment(store)
            .environment(recorder)
            .environment(hub)
            .environment(post)
            .environment(importer)
            .environment(appState)
            .environment(templates)
            .environment(askStore)
            #if os(macOS)
            .environment(localAPI)
            .task { localAPI.attach(store) }
            #endif
            .task { await hub.startMonitoringIfWanted() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { store.saveNow() }
            }
    }
}

/// Which note is open and which sheets are showing; shared with the Mac menu commands.
@MainActor
@Observable
final class AppState {
    var selection: UUID?
    var showImporter = false
    var exportRequest: ExportRequest?
    var showSettings = false
    var enhanceNoteID: UUID?
    var translateNoteID: UUID?
    /// iPhone: Ask Sintr is showing.
    var showAsk = false
    /// The recording setup screen is showing (it also shows by itself the first time).
    var showSetup = false
    /// Which notes the list shows.
    var folderFilter: FolderFilter = .all
    /// Sending a note to another app.
    var sendRequest: SendRequest?
    /// Picking a place for a shared folder.
    var folderPick: FolderPick?
    var folderError: String?

    struct SendRequest: Identifiable {
        let id = UUID()
        let noteID: UUID
        let kind: IntegrationKind
    }

    enum FolderPick: Equatable {
        case share(UUID)
        case open
    }

    enum FolderFilter: Hashable {
        case all
        case unfiled
        case folder(UUID)
    }

    struct ExportRequest: Identifiable {
        let id = UUID()
        /// nil means every note (or every note in `folderID`).
        let noteID: UUID?
        var folderID: UUID?
        var format: ExportFormat = .markdown

        init(noteID: UUID?, folderID: UUID? = nil, format: ExportFormat = .markdown) {
            self.noteID = noteID
            self.folderID = folderID
            self.format = format
        }
    }
}

#if os(macOS)
struct SintrCommands: Commands {
    let store: NoteStore
    let recorder: Recorder
    let appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") {
                appState.selection = store.newNote().id
            }
            .keyboardShortcut("n")
        }
        CommandGroup(after: .newItem) {
            Button("Import…") { appState.showImporter = true }
                .keyboardShortcut("o")
            Button("Export All Notes…") { appState.exportRequest = .init(noteID: nil) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Divider()
            Button("Ask About Your Notes…") { openWindow(id: "ask") }
                .keyboardShortcut("j")
        }
        CommandMenu("Recording") {
            Button(recorder.isRecording ? "Stop Recording" : "Start Recording") {
                Task {
                    if recorder.isRecording {
                        await recorder.stop()
                    } else {
                        let id = appState.selection ?? store.newNote().id
                        appState.selection = id
                        await recorder.start(noteID: id, store: store)
                    }
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(recorder.isFinishing || (!recorder.isRecording && recorder.isActive))
            Divider()
            Button("Set Up Recording…") { appState.showSetup = true }
        }
        CommandGroup(after: .help) {
            Button("Activity Log…") { openWindow(id: ActivityLogView.windowID) }
        }
    }
}
#endif
