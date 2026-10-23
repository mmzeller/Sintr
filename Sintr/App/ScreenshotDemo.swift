import Foundation

/// For the automated screenshots (scripts/ci-screenshots.sh): launching with
/// `--demo-note enhanced|new|review|card|empty` opens a sample note, so the note screen can be checked
/// at different text sizes without a phone. Does nothing without that launch argument.
enum ScreenshotDemo {
    static let mode: String? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--demo-note") else { return nil }
        return index + 1 < arguments.count ? arguments[index + 1] : "enhanced"
    }()

    static var isActive: Bool { mode != nil }

    /// "empty": a new note opened on the Enhanced tab.
    static var opensOnEnhanced: Bool { mode == "empty" }

    /// Before the first screen: skip the recording setup sheet.
    static func prepare() {
        guard isActive else { return }
        UserDefaults.standard.set(true, forKey: AppSettings.setupDone)
    }

    /// Adds the sample note and opens it (and, for "review", the Send to Sectis sheet).
    @MainActor
    static func open(store: NoteStore, appState: AppState) {
        guard let mode else { return }
        let note: Note
        switch mode {
        case "new", "empty": note = newNote
        case "card": note = shortNote
        default: note = enhancedNote
        }
        _ = store.merge([note])
        appState.selection = note.id
        if mode == "review" {
            appState.sendRequest = .init(noteID: note.id, kind: .sectis)
        }
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
