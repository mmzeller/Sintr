import Foundation
import SwiftUI

/// For the automated screenshots (scripts/ci-screenshots.sh): launching with
/// `--demo-note enhanced|new|review|card|sent|empty|transcript` opens a sample note, so the note screen
/// can be checked at different text sizes without a phone. `--demo-width 320` also lays the app
/// out 320 points wide — an iPhone with Display Zoom set to Larger Text — with red lines at the
/// edges, so anything wider than that screen shows past them. Does nothing without these.
enum ScreenshotDemo {
    static let mode: String? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--demo-note") else { return nil }
        return index + 1 < arguments.count ? arguments[index + 1] : "enhanced"
    }()

    static let width: CGFloat? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--demo-width"), index + 1 < arguments.count,
              let value = Double(arguments[index + 1]) else { return nil }
        return CGFloat(value)
    }()

    static var isActive: Bool { mode != nil }

    /// The tab the sample note opens on, when it isn't the usual one: "empty" is a new note on
    /// the Enhanced tab; "transcript" is the enhanced note on its Transcript tab.
    static var openingTab: NoteView.Tab? {
        switch mode ?? "" {
        case "empty": return .enhanced
        case "transcript": return .transcript
        default: return nil
        }
    }

    /// Before the first screen: skip the recording setup sheet.
    static func prepare() {
        guard isActive else { return }
        UserDefaults.standard.set(true, forKey: AppSettings.setupDone)
    }

    /// Adds the sample note and opens it (and, for "review", the Send to Sectis sheet; for
    /// "transcript", the message speaker detection leaves when it's done).
    @MainActor
    static func open(store: NoteStore, appState: AppState, post: PostProcessor) {
        guard let mode else { return }
        let note: Note
        switch mode {
        case "new", "empty": note = newNote
        case "card": note = shortNote
        case "sent": note = sentNote
        case "transcript": note = transcriptNote
        default: note = enhancedNote
        }
        addRecordingFiles(of: note, to: store)
        _ = store.merge([note])
        appState.selection = note.id
        if mode == "review" {
            appState.sendRequest = .init(noteID: note.id, kind: .sectis)
        }
        if mode == "transcript" {
            post.notice = "Transcript rebuilt with speaker labels. \(Platform.isMac ? "Click" : "Tap") a speaker's name to rename them."
        }
    }

    /// A note only keeps recordings whose files exist, so the sample's gets an empty stand-in.
    @MainActor
    static func addRecordingFiles(of note: Note, to store: NoteStore) {
        for recording in note.recordings {
            let url = store.recordingURL(recording.fileName)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: Data())
            }
        }
    }

    /// The enhanced note with a longer transcript, two detected speakers and its audio saved
    /// (so Rename speakers and From audio show).
    static var transcriptNote: Note {
        var note = enhancedNote
        note.id = UUID(uuidString: "5A5A5A5A-0000-4000-8000-000000000004")!
        note.title = "Stream test debrief with the clerk's office"
        note.transcript = [
            TranscriptSegment(speaker: "Speaker 1", start: 2, text: "Okay, recording. Let's go over Tuesday's stream test first."),
            TranscriptSegment(speaker: "Speaker 2", start: 9, text: "It dropped twice, and both times it was right when the Pearl switched layouts."),
            TranscriptSegment(speaker: "Speaker 1", start: 18, text: "So not the network. I'll update the firmware before the next council meeting and we'll run it again."),
            TranscriptSegment(speaker: "Speaker 2", start: 31, text: "Sounds good. Can you also send Vimeo the attendance numbers?"),
            TranscriptSegment(speaker: "Speaker 1", start: 38, text: "Yes, by Friday."),
        ]
        note.speakerNames = ["Speaker 1": "Me"]
        note.duration = 48
        note.recordings = [NoteRecording(fileName: "demo.m4a", speaker: "", offset: 0)]
        return note
    }

    /// A note whose action items went to a Sectis project: its card lists them, done or not.
    private static var sentNote: Note {
        var note = enhancedNote
        note.id = UUID(uuidString: "5A5A5A5A-0000-4000-8000-000000000005")!
        note.title = "Council AV check-in (sent)"
        note.enhanced = """
            ## Summary
            The Tuesday stream test dropped twice when the Pearl-2 switched layouts.

            ## Action items
            - [ ] Update the Pearl-2 firmware — Me, by Friday
            - [ ] Run a second stream test after the update — Me, next Tuesday
            - [ ] Get final Vimeo Enterprise pricing — Me, Oct 31
            - [ ] Send Vimeo the attendance numbers — Dana
            """
        note.sectisPlace = Sectis.demoPlaces[1]
        let ids = Sectis.items(in: note, includeWaiting: true).map { SectisFormat.itemID(noteID: note.id.uuidString, title: $0.idTitle) }
        note.sentTo = [NoteSend(destination: "Sectis (4 to-dos, 1 waiting · Q4 streaming upgrade)", items: ids)]
        return note
    }

    private static var newNote: Note {
        var note = Note()
        note.id = UUID(uuidString: "5A5A5A5A-0000-4000-8000-000000000002")!
        note.created = Date()
        note.modified = Date()
        return note
    }

    /// Short enough that the Sectis card and the byline after the notes are on screen.
    private static var shortNote: Note {
        var note = enhancedNote
        note.id = UUID(uuidString: "5A5A5A5A-0000-4000-8000-000000000003")!
        note.title = "Firmware follow-up"
        note.enhanced = """
            ## Summary
            Quick check on the Pearl-2 update.

            ## Action items
            - [ ] Update the Pearl-2 firmware — Me, by Friday
            - [ ] Send Vimeo the attendance numbers — Dana
            """
        return note
    }

    private static var enhancedNote: Note {
        var note = Note()
        note.id = UUID(uuidString: "5A5A5A5A-0000-4000-8000-000000000001")!
        note.title = "Council AV check-in"
        note.created = Date().addingTimeInterval(-3 * 3600)
        note.modified = Date()
        note.duration = 36 * 60
        note.myNotes = "Stream test\nPearl firmware\nVimeo pricing"
        note.transcript = [
            TranscriptSegment(speaker: "Me", start: 4, text: "Let's start with the stream test from Tuesday."),
            TranscriptSegment(speaker: "Them", start: 11, text: "It dropped twice, both times when the Pearl switched layouts."),
        ]
        note.enhanced = """
            ## Summary
            The Tuesday stream test dropped twice when the Pearl-2 switched layouts. The team agreed to update its firmware before the next council meeting and to get final Vimeo Enterprise pricing.

            ## Notes
            - Both drops happened on a layout change, not during steady streaming.
            - Q-SYS scheduling worked; the Outlook trigger started the stream on time.
            - Vimeo Enterprise is still the front-runner; pricing is due this week.

            ## Decisions
            - Update the Pearl-2 firmware before the next meeting.
            - Keep the Outlook trigger as it is.

            ## Action items
            - [ ] Update the Pearl-2 firmware — Me, by Friday
            - [ ] Run a second stream test after the update — Me, next Tuesday
            - [ ] Send Vimeo the attendance numbers — Dana
            - [ ] Get final Vimeo Enterprise pricing — Me, Oct 31
            """
        note.enhancedBy = "Gemma 3 1B on this \(Platform.deviceName)"
        note.enhancedAt = Date().addingTimeInterval(-2 * 3600)
        return note
    }
}

/// `--demo-width`: the whole app laid out at that width, centered, with red lines at its edges.
struct DemoWidthFrame: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if let width = ScreenshotDemo.width {
            content
                .frame(width: width)
                .overlay {
                    HStack(spacing: width) {
                        Rectangle().fill(.red).frame(width: 1)
                        Rectangle().fill(.red).frame(width: 1)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}
