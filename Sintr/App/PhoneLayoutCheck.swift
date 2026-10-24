#if os(iOS)
import SwiftUI
import UIKit

/// `--layout-check` on iPhone (used by the automated tests, scripts/ci-screenshots.sh): measures
/// the note screen — every tab — and the record bar with its messages showing, 320, 375 and 390
/// points wide at several text sizes, the way the screen lays them out. 320 points is an iPhone
/// with Display Zoom set to Larger Text: there the old tab picker and transcript buttons were
/// wider than the phone, so the whole note screen was cut off on both sides. Prints what it
/// measured and exits with 1 if anything is wider than the screen again.
@MainActor
enum PhoneLayoutCheck {
    static var isRequested: Bool { CommandLine.arguments.contains("--layout-check") }

    static let widths: [CGFloat] = [320, 375, 390]
    static let sizes: [(DynamicTypeSize, String)] = [
        (.large, "default text"), (.xxxLarge, "largest text"),
        (.accessibility1, "accessibility text 1"), (.accessibility3, "accessibility text 3"),
    ]

    static func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let store = NoteStore()
        let hub = AudioHub()
        let post = PostProcessor()
        let recorder = Recorder(hub: hub, post: post)
        let objects = Objects(
            store: store, recorder: recorder, hub: hub, post: post, appState: AppState(),
            importer: Importer(post: post), templates: TemplateStore(), askStore: AskStore())

        // The busiest note: long title, renamed speakers, audio, translations, a chat.
        var note = ScreenshotDemo.transcriptNote
        note.id = UUID()
        note.title = "Stream test debrief with the clerk's office and the council AV vendor"
        note.speakerNames = ["Speaker 1": "Me", "Speaker 2": "Dana from the clerk's office"]
        note.translations = [
            NoteTranslation(language: "es", part: "enhanced",
                            text: "## Resumen\nLa prueba del martes se cortó dos veces.", by: "Apple Intelligence"),
            NoteTranslation(language: "pt-BR", part: "transcript",
                            text: "Vamos começar com o teste de transmissão.", by: "Gemma 3 1B on this iPhone"),
        ]
        note.chat = [
            ChatMessage(role: "user", text: "What did we decide about the firmware?"),
            ChatMessage(role: "assistant", text: "Update the Pearl-2 firmware before the next council meeting.",
                        by: "Apple Intelligence"),
        ]
        ScreenshotDemo.addRecordingFiles(of: note, to: store)
        _ = store.merge([note])
        let id = note.id
        recorder.notice = "The microphone stopped (another app took it, or it was disconnected). Sintr keeps trying to get it back."
        post.notice = "Transcript rebuilt with speaker labels. Tap a speaker's name to rename them."

        print("iPhone layout check: is anything wider than the screen?")
        var problems: [String] = []
        for width in widths {
            for (size, sizeName) in sizes {
                var widest = (name: "", width: CGFloat(0))
                func check<V: View>(_ name: String, _ view: V) {
                    let measured = measure(view.modifier(objects), width: width, size: size)
                    if measured > widest.width { widest = (name, measured) }
                    if measured > width + 0.5 {
                        problems.append("\(name): \(Int(measured.rounded())) points wide on a \(Int(width))-point screen, \(sizeName)")
                    }
                }
                for tab in NoteView.Tab.allCases {
                    check("Note screen, \(tab.rawValue) tab", NoteView(noteID: id, initialTab: tab))
                }
                check("Record bar with messages", RecordBar(noteID: id))
                print("  \(Int(width)) points, \(sizeName): widest is \(widest.name) at \(Int(widest.width.rounded()))")
            }
        }

        // Controls: the old pieces, to show this measuring catches what was wrong on the phone.
        let oldPicker = Picker("Show", selection: .constant(NoteView.Tab.myNotes)) {
            ForEach([NoteView.Tab.myNotes, .transcript, .enhanced, .ask]) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        let oldButtons = HStack(spacing: 14) {
            Button("Copy transcript", systemImage: "doc.on.doc") {}
            Spacer()
            Menu {} label: { Label("Rename speakers", systemImage: "person.text.rectangle") }.fixedSize()
            Menu {} label: { Label("From audio", systemImage: "waveform") }.fixedSize()
        }
        .font(.callout)
        .padding(.horizontal)
        for (name, view, size) in [("old tab picker", AnyView(oldPicker), DynamicTypeSize.large),
                                   ("old transcript buttons", AnyView(oldButtons), DynamicTypeSize.xxxLarge)] {
            let measured = measure(view, width: 320, size: size)
            print("Control (\(name)): \(Int(measured.rounded())) points wide on a 320-point screen"
                  + (measured > 320.5 ? " — too wide, as on the phone" : " — fits; this measuring may not match the phone's"))
        }

        store.delete(id)
        store.saveNow()
        for problem in problems { print("TOO WIDE: \(problem)") }
        print(problems.isEmpty ? "RESULT: everything fits" : "RESULT: \(problems.count) too wide")
        fflush(stdout)
        exit(problems.isEmpty ? 0 : 1)
    }

    /// How wide `view` wants to be when the screen offers it `width` points.
    private static func measure(_ view: some View, width: CGFloat, size: DynamicTypeSize) -> CGFloat {
        let host = UIHostingController(rootView: view.environment(\.dynamicTypeSize, size))
        return host.sizeThatFits(in: CGSize(width: width, height: 2000)).width
    }

    private struct Objects: ViewModifier {
        let store: NoteStore
        let recorder: Recorder
        let hub: AudioHub
        let post: PostProcessor
        let appState: AppState
        let importer: Importer
        let templates: TemplateStore
        let askStore: AskStore

        func body(content: Content) -> some View {
            content
                .environment(store).environment(recorder).environment(hub).environment(post)
                .environment(appState).environment(importer).environment(templates).environment(askStore)
        }
    }
}
#endif
