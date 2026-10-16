import SwiftUI

@main
struct SintrApp: App {
    @State private var store = NoteStore()
    @State private var recorder = Recorder()
    @State private var importer = Importer()
    @State private var appState = AppState()
    @State private var templates = TemplateStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppSettings.register()
        PortableSettings.start()
        SpeakerDetector.blockNetwork()
        #if os(macOS)
        StorageCheck.runIfRequested()
        #endif
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
                .environment(templates)
                .frame(width: 620, height: 720)
        }
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
            .environment(importer)
            .environment(appState)
            .environment(templates)
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

    struct ExportRequest: Identifiable {
        let id = UUID()
        /// nil means every note.
        let noteID: UUID?
        var format: ExportFormat = .markdown
    }
}

#if os(macOS)
struct SintrCommands: Commands {
    let store: NoteStore
    let recorder: Recorder
    let appState: AppState

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
            .disabled(recorder.isFinishing)
        }
    }
}
#endif
