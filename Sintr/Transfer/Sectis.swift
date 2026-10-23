import Foundation

/// Sends your own action items from a note to Sectis, the to-do app, through the Firebase
/// project Sectis syncs with. Each to-do is encrypted on this device with the key in your
/// join code, exactly the way Sectis encrypts its own, so Firebase only stores scrambled data.
/// The to-dos land in Sectis's Inbox, tagged "Meeting", the next time Sectis syncs.
enum Sectis {
    /// The tag Sintr's to-dos get in Sectis (made the first time if you don't have it).
    static let tagName = "Meeting"

    // MARK: The note's switch

    /// What a note's switch starts as: Settings → Integrations → Sectis → Send after Enhance.
    static var isOnByDefault: Bool { IntegrationSettings.config(.sectis).autoSend }

    /// Whether Enhance sends this note's action items to Sectis.
    static func isOn(for note: Note?, byDefault: Bool = Sectis.isOnByDefault) -> Bool {
        note?.sendToSectis ?? byDefault
    }

    /// The last time this note's items went to Sectis.
    static func lastSend(of note: Note) -> NoteSend? {
        note.sentTo.last { $0.destination.hasPrefix(IntegrationKind.sectis.title) }
    }

    // MARK: Which items are yours

    /// The names that mean you: Settings → Integrations → Sectis, what you renamed "Me" to in
    /// this note, and on a Mac (when nothing is set) the name of your Mac account.
    static func myNames(for note: Note?) -> Set<String> {
        var list = IntegrationSettings.config(.sectis).target
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        #if os(macOS)
        if list.isEmpty { list.append(NSFullUserName()) }
        #endif
        if let renamed = note?.speakerNames["Me"] { list.append(renamed) }
        return ActionItemParser.names(list)
    }

    /// The Mac account's name, shown as the default in Settings.
    static var defaultName: String? {
        #if os(macOS)
        let name = NSFullUserName().trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
        #else
        return nil
        #endif
    }

    /// The note's unchecked action items that are yours: the enhanced notes (or, before
    /// Enhance, your own notes).
    static func myItems(in note: Note) -> [ActionItem] {
        let names = myNames(for: note)
        let enhanced = note.enhanced.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = enhanced.isEmpty ? note.myNotes : enhanced
        let solo = isSolo(note, names: names)
        var seen = Set<String>()
        return ActionItemParser.items(in: source, names: names, meetingDate: note.created).filter {
            ActionItemParser.isMine($0, names: names, solo: solo) && seen.insert(SectisFormat.dedupKey($0.title)).inserted
        }
    }

    /// Nobody else is in the note: no transcript, only you, or a single voice (a voice memo).
    /// Then an action item that doesn't say whose it is counts as yours.
    static func isSolo(_ note: Note, names: Set<String>) -> Bool {
        let labels = note.speakers
        let others = labels.filter {
            $0 != "Me" && !ActionItemParser.ownerIncludesMe(note.displayName(forSpeaker: $0), names: names)
        }
        return others.isEmpty || (labels.count == 1 && labels[0] != "Them")
    }

    static let noItemsMessage = "There are no action items for you in this note. Sintr sends unchecked action items whose owner is you — “Me”, or a name you set in Settings → Integrations → Sectis."

    // MARK: Sending

    /// Adds your action items from the note to your Sectis Inbox — `items` when you've picked
    /// and adjusted them, otherwise all of them. An item already sent from this note (even if
    /// you've since completed or deleted it in Sectis) isn't added again.
    static func send(_ note: Note, items chosen: [ActionItem]? = nil, joinCode: String) async throws -> NoteSend {
        let items = chosen ?? myItems(in: note)
        guard !items.isEmpty else {
            throw IntegrationError.badTarget(chosen == nil ? noItemsMessage : "Tick at least one action item to send.")
        }
        let connection = try await SectisCloud.connect(joinCode: joinCode)
        let tag = await SectisCloud.findOrCreateTag(tagName, connection)

        let now = Date()
        let version = Int64(now.timeIntervalSince1970 * 1000)
        // Newest meetings at the top of the Inbox, each meeting's items in their own order.
        let base = -Double(Int64(now.timeIntervalSince1970))
        let header = "From “\(note.displayTitle)”, \(note.created.formatted(date: .abbreviated, time: .shortened)) (Sintr)"
        var writes: [[String: Any]] = []
        for (index, item) in items.enumerated() {
            var notes = [header]
            let written = item.line.replacing(#/^(?:[-*+•]|\d+[.)])\s+(?:\[[ xX]\]\s*)?/#, with: "")
            if SectisFormat.dedupKey(written) != SectisFormat.dedupKey(item.title) { notes.append("“\(written)”") }
            notes += item.details.map { "• \($0)" }
            let id = SectisFormat.itemID(noteID: note.id.uuidString, title: item.idTitle)
            let record = SectisFormat.todoRecord(
                id: id, title: item.title, notes: notes.joined(separator: "\n"), deadline: item.deadline,
                tags: tag.map { [$0] } ?? [], order: base + Double(index) * 0.001, now: now)
            writes.append(try SectisCloud.createWrite(connection, id: id, kind: "todo", record: record, version: version))
        }

        let results = try await SectisCloud.createEach(connection, writes)
        let added = results.filter { $0 == .created }.count
        let existing = results.filter { $0 == .exists }.count
        let problems = results.compactMap { result -> String? in
            if case .failed(let message) = result { return message }
            return nil
        }
        if added == 0, existing == 0, let problem = problems.first {
            throw SectisCloud.Failure(message: problem)
        }
        ActivityLog.add("Sent \(added) action item\(added == 1 ? "" : "s") to Sectis\(existing > 0 ? " (\(existing) already there)" : "")")
        var summary: String
        switch (added, existing) {
        case (0, _): summary = "already there"
        case (_, 0): summary = "\(added) to-do\(added == 1 ? "" : "s")"
        default: summary = "\(added) new, \(existing) already there"
        }
        if !problems.isEmpty { summary += ", \(problems.count) not sent" }
        return NoteSend(destination: "Sectis (\(summary))")
    }

    /// "2026-10-31" ↔ a date, for deadlines.
    static func date(fromDay day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func day(from date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Checks the join code, the Firebase project and its rules by reading your tags.
    static func test(joinCode: String) async throws -> String {
        let connection = try await SectisCloud.connect(joinCode: joinCode)
        let tags = try await SectisCloud.readTags(connection)
        return tags.isEmpty ? "Connected to your Sectis list." : "Connected to your Sectis list (\(tags.count) tags)."
    }
}
