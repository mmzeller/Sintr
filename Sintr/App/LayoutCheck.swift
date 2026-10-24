#if os(macOS)
import AppKit
import SwiftUI

/// `Sintr --layout-check` (used by the automated tests): measures the note screen with a long
/// notice in the record bar, the way macOS works out a window's smallest size — by asking for
/// the size at zero width and height. A notice that grew to fit wrapped one character per line
/// there, and the window laid out thousands of points tall: the note went blank and the note
/// list slid up. Prints the sizes and exits with 1 if anything is that tall again.
@MainActor
enum LayoutCheck {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--layout-check") else { return }
        _ = NSApplication.shared
        let store = NoteStore()
        let hub = AudioHub()
        let post = PostProcessor()
        let recorder = Recorder(hub: hub, post: post)
        let appState = AppState()
        let importer = Importer(post: post)
        let note = store.newNote(title: "Layout check")
        recorder.notice = "The microphone stopped (another app took it, or it was disconnected). Sintr keeps trying to get it back."
        post.notice = "Detecting speakers finished, but one of the recordings couldn't be read, so its lines keep their labels."
        appState.selection = note.id

        let bar = NSHostingController(rootView: RecordBar(noteID: note.id)
            .environment(store).environment(recorder).environment(hub).environment(post).environment(appState))
        let window = NSHostingController(rootView: ContentView()
            .environment(store).environment(recorder).environment(hub).environment(post)
            .environment(importer).environment(appState).environment(TemplateStore()).environment(AskStore())
            .environment(LocalAPIServer()))

        var ok = true
        func measure(_ name: String, _ host: NSHostingController<some View>, limit: CGFloat) {
            let smallest = host.sizeThatFits(in: .zero)
            let usual = host.sizeThatFits(in: CGSize(width: 900, height: 700))
            let fine = smallest.height.isFinite && smallest.height < limit
            print("\(name): smallest \(Int(smallest.width))×\(Int(smallest.height)), at 900 wide \(Int(usual.width))×\(Int(usual.height)) — \(fine ? "ok" : "TOO TALL (limit \(Int(limit)))")")
            if !fine { ok = false }
        }
        measure("Record bar with notices", bar, limit: 500)
        measure("Window with that note open", window, limit: 1000)

        // Control: the old "grow to fit" notice, to show this measuring catches the bug.
        let control = NSHostingController(rootView: HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(recorder.notice ?? "").fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss") {}
        })
        let controlHeight = control.sizeThatFits(in: .zero).height
        print("Control (old notice): smallest height \(Int(controlHeight))\(controlHeight > 500 ? " — the bug, as expected" : " — not tall; this measuring may not match the window's")")

        store.delete(note.id)
        store.saveNow()
        exit(ok ? 0 : 1)
    }
}
#endif
