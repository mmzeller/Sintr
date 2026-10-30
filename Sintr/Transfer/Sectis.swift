import Foundation

/// Sends the action items in a note to Sectis, the to-do app, through the Firebase project
/// Sectis syncs with: yours as to-dos, and other people's to Sectis's Waiting For, so you know
/// to follow up (Settings → Integrations → Sectis can turn that off). Each to-do is encrypted on
/// this device with the key in your join code, exactly the way Sectis encrypts its own, so
/// Firebase only stores scrambled data. They land in the Inbox — or the project or area you
/// pick for the note or its folder — tagged "Meeting", with a link back to the note.
enum Sectis {
    /// The tag Sintr's to-dos get in Sectis (made the first time if you don't have it).
    static let tagName = "Meeting"

    // MARK: Settings

    static var options: SectisOptions { IntegrationSettings.config(.sectis).sectis ?? SectisOptions() }

    static func updateOptions(_ change: (inout SectisOptions) -> Void) {
        var config = IntegrationSettings.config(.sectis)
        var options = config.sectis ?? SectisOptions()
        change(&options)
        guard options != config.sectis else { return }
        config.sectis = options
        IntegrationSettings.save(config, for: .sectis)
    }

    /// Other people's action items go to Waiting For (Settings → Integrations → Sectis).
    static var sendsWaiting: Bool { options.waitingFor ?? true }

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

    // MARK: Where they go

    /// Where this note's to-dos go: its own choice, or else its folder's, or else the Inbox.
    static func place(for note: Note) -> SectisFormat.Place {
        if let own = note.sectisPlace { return own }
        return folderPlace(note.folderID) ?? .inbox
    }

    /// Where notes in a folder send their to-dos, when you've chosen.
    static func folderPlace(_ folderID: UUID?) -> SectisFormat.Place? {
        guard let folderID else { return nil }
        return options.folderPlaces?[folderID.uuidString]
    }

    static func setFolderPlace(_ place: SectisFormat.Place?, for folderID: UUID) {
        updateOptions { options in
            var places = options.folderPlaces ?? [:]
            places[folderID.uuidString] = place
            options.folderPlaces = places.isEmpty ? nil : places
        }
    }

    /// Your Sectis projects and areas as last read, so the picker works offline.
    static var knownPlaces: [SectisFormat.Place] { options.knownPlaces ?? [] }

    /// Reads your projects and areas from Sectis (and keeps them for next time).
    static func refreshPlaces(joinCode: String) async throws -> [SectisFormat.Place] {
        if ScreenshotDemo.isActive { return demoPlaces }
        let places = try await SectisCloud.readPlaces(connection(joinCode))
        updateOptions { $0.knownPlaces = places }
        return places
    }

    // MARK: Which items

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

    /// The note's unchecked action items for Sectis, from the enhanced notes (or, before
    /// Enhance, your own notes): yours first, then — with Waiting For on — other people's, each
    /// saying who it's waiting on.
    static func items(in note: Note, includeWaiting: Bool = Sectis.sendsWaiting) -> [ActionItem] {
        let names = myNames(for: note)
        let enhanced = note.enhanced.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = enhanced.isEmpty ? note.myNotes : enhanced
        let solo = isSolo(note, names: names)
        var seen = Set<String>()
        var mine: [ActionItem] = []
        var others: [ActionItem] = []
        for item in ActionItemParser.items(in: source, names: names, meetingDate: note.created) {
            if ActionItemParser.isMine(item, names: names, solo: solo) {
                if seen.insert(SectisFormat.dedupKey(item.title)).inserted { mine.append(item) }
            } else if includeWaiting, let person = ActionItemParser.someoneElse(item, names: names),
                      seen.insert(SectisFormat.dedupKey(item.title)).inserted {
                var theirs = item
                theirs.waitingOn = displayName(person, in: note)
                others.append(theirs)
            }
        }
        return mine + others
    }

    /// Only your own action items.
    static func myItems(in note: Note) -> [ActionItem] { items(in: note, includeWaiting: false) }

    /// "Them" or "Speaker 2" as the name you gave that speaker in the note.
    private static func displayName(_ person: String, in note: Note) -> String {
        let renamed = note.speakerNames[person]?.trimmingCharacters(in: .whitespaces) ?? ""
        return renamed.isEmpty ? person : renamed
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

    static let noItemsMessage = "There are no action items for you in this note. Sintr sends unchecked action items whose owner is you — “Me”, or a name you set in Settings → Integrations → Sectis — and, with Waiting For on, ones that name someone else."

    /// "2 for you · 1 waiting on others".
    static func countText(_ items: [ActionItem]) -> String {
        let mine = items.filter { $0.waitingOn == nil }.count
        let waiting = items.count - mine
        var parts: [String] = []
        if mine > 0 || waiting == 0 { parts.append("\(mine) action item\(mine == 1 ? "" : "s") for you") }
        if waiting > 0 { parts.append("\(waiting) waiting on others") }
        return parts.joined(separator: " · ")
    }

    // MARK: Sending

    /// Adds the note's action items to Sectis — `items` when you've picked and adjusted them,
    /// otherwise all of them — in `place` (or wherever the note sends them). An item already
    /// sent from this note (even if you've since completed or deleted it in Sectis) isn't
    /// added again.
    static func send(_ note: Note, items chosen: [ActionItem]? = nil, place chosenPlace: SectisFormat.Place? = nil,
                     joinCode: String) async throws -> NoteSend {
        let items = chosen ?? self.items(in: note)
        guard !items.isEmpty else {
            throw IntegrationError.badTarget(chosen == nil ? noItemsMessage : "Tick at least one action item to send.")
        }
        let connection = try await connection(joinCode)
        let tag = await SectisCloud.findOrCreateTag(tagName, connection)

        // A project or area that's gone from Sectis (or a project that's finished): the Inbox.
        var place = chosenPlace ?? self.place(for: note)
        var placeTags: [String] = []
        var placeGone = false
        if !place.isInbox {
            if let tags = try await liveTags(of: place, connection) {
                placeTags = tags
            } else {
                ActivityLog.add("Sectis: \(place.kind.rawValue) “\(place.title)” isn't open in Sectis; sending to the Inbox")
                place = .inbox
                placeGone = true
            }
        }
        var tags: [String] = tag.map { [$0] } ?? []
        for id in placeTags where !tags.contains(id) { tags.append(id) }

        let now = Date()
        let version = Int64(now.timeIntervalSince1970 * 1000)
        // Newest meetings at the top, each meeting's items in their own order.
        let base = -Double(Int64(now.timeIntervalSince1970))
        let header = "From “\(note.displayTitle)”, \(note.created.formatted(date: .abbreviated, time: .shortened)) — [Open in Sintr](\(link(to: note)))"
        let since = day(from: note.created)
        var writes: [[String: Any]] = []
        var ids: [String] = []
        for (index, item) in items.enumerated() {
            var notes = [header]
            let written = item.line.replacing(#/^(?:[-*+•]|\d+[.)])\s+(?:\[[ xX]\]\s*)?/#, with: "")
            if SectisFormat.dedupKey(written) != SectisFormat.dedupKey(item.title) { notes.append("“\(written)”") }
            let id = SectisFormat.itemID(noteID: note.id.uuidString, title: item.idTitle)
            let waiting = item.waitingOn.map { SectisFormat.Waiting(person: $0, since: since, followUp: item.deadline) }
            let record = SectisFormat.todoRecord(
                id: id, title: item.title, notes: notes.joined(separator: "\n"),
                deadline: waiting == nil ? item.deadline : nil, tags: tags,
                order: base + Double(index) * 0.001, now: now, place: place, checklist: item.details, waiting: waiting)
            writes.append(try SectisCloud.createWrite(connection, id: id, kind: "todo", record: record, version: version))
            ids.append(id)
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
        let waitingCount = zip(items, results).filter { $0.0.waitingOn != nil && $0.1 == .created }.count
        ActivityLog.add("Sent \(added) action item\(added == 1 ? "" : "s") to Sectis (\(waitingCount) waiting, \(place.isInbox ? "Inbox" : place.kind.rawValue))\(existing > 0 ? " (\(existing) already there)" : "")")
        var summary: String
        switch (added, existing) {
        case (0, _): summary = "already there"
        case (_, 0): summary = "\(added) to-do\(added == 1 ? "" : "s")"
        default: summary = "\(added) new, \(existing) already there"
        }
        if waitingCount > 0 { summary += ", \(waitingCount) waiting" }
        if !problems.isEmpty { summary += ", \(problems.count) not sent" }
        summary += placeGone ? " · Inbox, as that list is gone" : place.isInbox ? "" : " · \(place.title)"
        let sentIDs = zip(ids, results).filter { !isFailure($0.1) }.map(\.0)
        return NoteSend(destination: "Sectis (\(summary))", items: sentIDs)
    }

    private static func isFailure(_ result: SectisCloud.WriteResult) -> Bool {
        if case .failed = result { return true }
        return false
    }

    /// The tags a to-do takes on from a project or area (a project's and its area's, as Sectis
    /// does), or nil when it isn't an open list in Sectis any more.
    private static func liveTags(of place: SectisFormat.Place, _ connection: SectisCloud.Connection) async throws -> [String]? {
        guard case .found(let record)? = try await SectisCloud.readItems([place.id], connection)[place.id],
              record["trashed"] as? Bool != true, record["isTemplate"] as? Bool != true,
              place.kind == .area || (record["status"] as? String ?? "open") == "open" else { return nil }
        var tags = record["tags"] as? [String] ?? []
        if place.kind == .project, let areaID = record["areaId"] as? String,
           case .found(let area)? = try? await SectisCloud.readItems([areaID], connection)[areaID] {
            for id in area["tags"] as? [String] ?? [] where !tags.contains(id) { tags.append(id) }
        }
        return tags
    }

    /// The link a Sectis to-do carries back to its note.
    static func link(to note: Note) -> String { "sintr://note/\(note.id.uuidString)" }

    // MARK: Reading back

    /// The Sectis IDs of the to-dos sent from this note.
    static func sentIDs(of note: Note) -> [String] {
        var ids: [String] = []
        for send in note.sentTo where send.destination.hasPrefix(IntegrationKind.sectis.title) {
            for id in send.items ?? [] where !ids.contains(id) { ids.append(id) }
        }
        if ids.isEmpty, lastSend(of: note) != nil {
            // Sent before Sintr kept a list: the IDs come from the items, the same way.
            ids = myItems(in: note).map { SectisFormat.itemID(noteID: note.id.uuidString, title: $0.idTitle) }
        }
        return ids
    }

    /// What's become of the to-dos sent from this note, in the order they were sent; ones
    /// deleted in Sectis (or never made) are left out.
    static func states(of note: Note, joinCode: String) async throws -> [SectisFormat.TodoState] {
        let ids = sentIDs(of: note)
        guard !ids.isEmpty else { return [] }
        if ScreenshotDemo.isActive { return demoStates(ids) }
        let read = try await SectisCloud.readItems(ids, connection(joinCode))
        return ids.compactMap { id in
            let state: SectisFormat.TodoState
            switch read[id] {
            case .found(let record)?: state = SectisFormat.todoState(id: id, record: record)
            case .deleted?: state = SectisFormat.todoState(id: id, record: nil, deleted: true)
            default: state = SectisFormat.todoState(id: id, record: nil)
            }
            return state.isGone ? nil : state
        }
    }

    /// A project's or area's title from the last list read, for showing where a to-do is.
    static func placeTitle(projectID: String?, areaID: String?) -> String? {
        let id = projectID ?? areaID
        return knownPlaces.first { $0.id == id }?.title
    }

    /// Where a to-do opens in Sectis (the Mac app in your Dock opens it there): your Sectis's
    /// address, which Sintr learns when you open one of its links from Sectis.
    static func webLink(toTodo id: String) -> URL? {
        guard let address = options.address, var parts = URLComponents(string: address) else { return nil }
        parts.fragment = "todo:\(id)"
        return parts.url
    }

    /// Keeps your Sectis's address (from a link Sectis opened), if it's a web address.
    static func learnAddress(_ text: String) {
        guard var parts = URLComponents(string: text), ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host?.isEmpty == false else { return }
        parts.fragment = nil
        parts.query = nil
        guard let address = parts.string else { return }
        updateOptions { $0.address = address }
    }

    // MARK: Connecting

    /// Working out the key takes a moment, so the last connection is kept while the code is the same.
    nonisolated(unsafe) private static var cached: (code: String, connection: SectisCloud.Connection)?

    private static func connection(_ joinCode: String) async throws -> SectisCloud.Connection {
        if let cached, cached.code == joinCode { return cached.connection }
        let connection = try await SectisCloud.connect(joinCode: joinCode)
        cached = (joinCode, connection)
        return connection
    }

    // MARK: Dates

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
        let connection = try await connection(joinCode)
        let tags = try await SectisCloud.readTags(connection)
        _ = try? await refreshPlaces(joinCode: joinCode)
        return tags.isEmpty ? "Connected to your Sectis list." : "Connected to your Sectis list (\(tags.count) tags)."
    }

    // MARK: Screenshots

    /// The automated screenshots show these instead of reading from Firebase.
    static let demoPlaces: [SectisFormat.Place] = [
        .init(kind: .area, id: "demoarea1", title: "Council AV"),
        .init(kind: .project, id: "demoproj1", title: "Q4 streaming upgrade", area: "Council AV"),
        .init(kind: .area, id: "demoarea2", title: "Home"),
    ]

    private static func demoStates(_ ids: [String]) -> [SectisFormat.TodoState] {
        let samples: [(String, SectisFormat.TodoState.Status, String?)] = [
            ("Update the Pearl-2 firmware", .done, nil),
            ("Run a second stream test after the update", .open, nil),
            ("Get final Vimeo Enterprise pricing", .open, nil),
            ("Send Vimeo the attendance numbers", .open, "Dana"),
        ]
        return ids.prefix(samples.count).enumerated().map { index, id in
            let sample = samples[index]
            return SectisFormat.TodoState(id: id, title: sample.0, status: sample.1, waitingOn: sample.2,
                                          deadline: index == 2 ? "2026-10-31" : nil, projectId: "demoproj1")
        }
    }
}
