import Foundation
import CryptoKit
import CommonCrypto

/// The parts of Sectis's sync format Sintr needs: reading a join code, finding the space and
/// key it leads to, encrypting records exactly the way Sectis does (AES-GCM with a key from
/// PBKDF2), and building to-do records. Free of app types so CI can compile and check it on
/// its own against Sectis's own WebCrypto code (scripts/ci-sectis-check.sh).
enum SectisFormat {
    struct Link: Equatable, Sendable {
        var apiKey: String
        var projectId: String
        /// The sync key: where the data lives (a hash of it) and what encrypts it.
        var key: String
    }

    /// Reads a join code ("SECTIS-…"), the one Sectis shows in Settings → Sync — however it
    /// was pasted: inside other text, split over lines, with dashes swapped by smart
    /// punctuation or invisible characters picked up on the way.
    static func parseJoinCode(_ text: String) -> Link? {
        for body in candidates(in: text) {
            if let link = decode(body) { return link }
        }
        return nil
    }

    /// The join code tidied up ("SECTIS-" and the code itself), or nil if it can't be read.
    static func normalizedJoinCode(_ text: String) -> String? {
        candidates(in: text).first { decode($0) != nil }.map { "SECTIS-" + $0 }
    }

    /// Why a pasted join code can't be used, in words; nil if it's fine.
    static func joinCodeProblem(_ text: String) -> String? {
        let cleaned = clean(text)
        if cleaned.isEmpty { return "Paste the join code first." }
        if parseJoinCode(text) != nil { return nil }
        guard let range = cleaned.range(of: "SECTIS-", options: .caseInsensitive) else {
            return "That isn't a Sectis join code — it should start with SECTIS-. In Sectis, open Settings → Sync → Add Another Device and tap Copy Code."
        }
        let body = cleaned[range.upperBound...].prefix(while: isCodeCharacter)
        if body.count < 120 {
            return "That join code looks cut off (\(body.count) characters after SECTIS-; a whole one is usually 250 or more). In Sectis, tap Copy Code and paste it again."
        }
        return "That join code has been changed somewhere along the way, so it can't be read. In Sectis, tap Copy Code and paste it again."
    }

    // MARK: Reading a pasted code

    /// Dashes that smart punctuation or another app may have swapped in for "-".
    private static let dashes: [String] = ["\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}", "\u{FE63}", "\u{FF0D}"]
    /// Characters that don't show but come along when copying.
    private static let invisible: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{00AD}"]

    private static func clean(_ text: String) -> String {
        var result = text
        for dash in dashes { result = result.replacingOccurrences(of: dash, with: "-") }
        return String(String.UnicodeScalarView(result.unicodeScalars.filter {
            !invisible.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
        }))
    }

    private static func isCodeCharacter(_ character: Character) -> Bool {
        guard character.isASCII, let ascii = character.asciiValue else { return false }
        return (ascii >= 48 && ascii <= 57) || (ascii >= 65 && ascii <= 90) || (ascii >= 97 && ascii <= 122)
            || "-_+/=".contains(character)
    }

    /// The code itself (without "SECTIS-"): what follows the prefix if there is one, and the
    /// whole text as a fallback.
    private static func candidates(in text: String) -> [String] {
        let cleaned = clean(text)
        var result: [String] = []
        if let range = cleaned.range(of: "SECTIS-", options: .caseInsensitive) {
            result.append(String(cleaned[range.upperBound...].prefix(while: isCodeCharacter)))
        }
        result.append(String(cleaned.filter(isCodeCharacter)))
        return result.filter { !$0.isEmpty }
    }

    private static func decode(_ body: String) -> Link? {
        var raw = body.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        guard raw.count % 4 != 1 else { return nil }
        while raw.count % 4 != 0 { raw += "=" }
        guard let data = Data(base64Encoded: raw),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let config = object["c"] as? [String: Any],
              let apiKey = config["apiKey"] as? String, !apiKey.isEmpty,
              let projectId = config["projectId"] as? String, !projectId.isEmpty,
              let key = object["k"] as? String, key.count >= 20
        else { return nil }
        return Link(apiKey: apiKey, projectId: projectId, key: key)
    }

    /// The Firestore document under `sectis/` that holds this key's items.
    static func space(for key: String) -> String {
        let digest = SHA256.hash(data: Data("sectis-space|\(key)".utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(40))
    }

    /// The AES-256 key Sectis derives from the sync key (PBKDF2-SHA256, 150,000 rounds).
    /// Takes a moment, so call it off the main thread.
    static func encryptionKey(for key: String) -> Data? {
        let salt = Array("sectis-sync-v1|\(space(for: key))".utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), key, key.utf8.count, salt, salt.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 150_000, &derived, derived.count)
        return status == Int32(kCCSuccess) ? Data(derived) : nil
    }

    /// A record as Sectis stores it: `c` is the AES-GCM ciphertext followed by its 16-byte tag
    /// (what WebCrypto produces), `iv` the 12-byte nonce, both Base64.
    static func encrypt(_ record: [String: Any], key: Data) throws -> (c: String, iv: String) {
        let plain = try JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes])
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: nonce)
        let iv = nonce.withUnsafeBytes { Data($0) }
        return ((box.ciphertext + box.tag).base64EncodedString(), iv.base64EncodedString())
    }

    static func decrypt(c: String, iv: String, key: Data) throws -> [String: Any] {
        guard let sealed = Data(base64Encoded: c), let nonce = Data(base64Encoded: iv), sealed.count >= 16 else {
            throw CocoaError(.coderReadCorrupt)
        }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                        ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        let plain = try AES.GCM.open(box, using: SymmetricKey(data: key))
        guard let record = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return record
    }

    /// A stable ID for an action item, so sending the same item again finds the to-do it
    /// already made instead of adding a second one.
    static func itemID(noteID: String, title: String) -> String {
        let digest = SHA256.hash(data: Data("sintr|\(noteID)|\(dedupKey(title))".utf8))
        return "sn" + digest.map { String(format: "%02x", $0) }.joined().prefix(12)
    }

    /// A new random ID in the same style.
    static func randomID() -> String {
        "sn" + (0..<12).map { _ in String("0123456789abcdefghijklmnopqrstuvwxyz".randomElement()!) }.joined()
    }

    /// Lowercase letters and digits only, so small wording or punctuation changes don't matter.
    static func dedupKey(_ title: String) -> String {
        String(title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Where a to-do goes in Sectis: the Inbox, or one of your projects or areas.
    struct Place: Codable, Hashable, Sendable {
        enum Kind: String, Codable, Sendable { case inbox, project, area }
        var kind: Kind
        var id: String
        var title: String
        /// For a project: the area it's in, if any.
        var area: String?

        static let inbox = Place(kind: .inbox, id: "", title: "Inbox")
        var isInbox: Bool { kind == .inbox }
        /// "Council › Q4 rollout" for a project in an area.
        var fullTitle: String { area.map { "\($0) › \(title)" } ?? title }
    }

    /// Someone else's action item, kept in Sectis's Waiting For list: who it's waiting on, the
    /// day it started waiting, and when to follow up (the to-do comes back to Today then).
    struct Waiting: Hashable, Sendable {
        var person: String
        var since: String
        var followUp: String?
    }

    /// A to-do as Sectis stores it, with every field Sectis's own to-dos have: in the Inbox, or
    /// in a project or area (`place`); with a checklist; or waiting on someone (`waiting`), which
    /// Sectis files under Anytime and its Waiting list, back in Today on the follow-up date.
    static func todoRecord(id: String, title: String, notes: String, deadline: String?, tags: [String],
                           order: Double, now: Date, place: Place? = nil, checklist: [String] = [],
                           waiting: Waiting? = nil) -> [String: Any] {
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        let null = NSNull()
        let place = place ?? .inbox
        // Sectis's own rule: a to-do in a project or area, or waiting on someone, isn't in the Inbox.
        let start: String = place.isInbox && waiting == nil ? "inbox" : "anytime"
        let when: Any = waiting?.followUp.map { $0 as Any } ?? null
        let due: Any = deadline.map { $0 as Any } ?? null
        let projectID: Any = place.kind == .project ? (place.id as Any) : (null as Any)
        let areaID: Any = place.kind == .area ? (place.id as Any) : (null as Any)
        var items: [[String: Any]] = []
        for (index, text) in checklist.enumerated() {
            items.append(["id": "\(id)c\(index)", "title": text, "done": false])
        }
        var record: [String: Any] = [
            "id": id, "type": "todo", "title": title, "notes": notes, "status": "open", "start": start,
            "when": when, "evening": false, "deadline": due, "reminder": null,
            "projectId": projectID, "areaId": areaID, "headingId": null, "tags": tags, "checklist": items,
            "order": order, "todayOrder": 0, "createdAt": ms, "modifiedAt": ms, "completedAt": null,
            "logged": false, "trashed": false, "isTemplate": false, "repeat": null, "next": null,
            "templateId": null, "sample": false, "linkId": null,
        ]
        if let waiting {
            record["waitFor"] = waiting.person
            record["waitSince"] = waiting.since
        }
        return record
    }

    /// What became of a to-do in Sectis, read back from its record.
    struct TodoState: Hashable, Sendable {
        enum Status: String, Sendable { case open, done, canceled, trashed, deleted, missing }
        var id: String
        var title: String
        var status: Status
        var waitingOn: String?
        var deadline: String?
        var followUp: String?
        var projectId: String?
        var areaId: String?

        var isFinished: Bool { status == .done || status == .canceled }
        var isGone: Bool { status == .trashed || status == .deleted || status == .missing }
    }

    static func todoState(id: String, record: [String: Any]?, deleted: Bool = false) -> TodoState {
        guard let record else { return TodoState(id: id, title: "", status: deleted ? .deleted : .missing) }
        let text = { (key: String) -> String? in
            (record[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        }
        var status = TodoState.Status(rawValue: text("status") ?? "open") ?? .open
        if record["trashed"] as? Bool == true { status = .trashed }
        let waiting = status == .open ? text("waitFor") : nil
        return TodoState(id: id, title: text("title") ?? "", status: status, waitingOn: waiting,
                         deadline: text("deadline"), followUp: waiting == nil ? nil : text("when"),
                         projectId: text("projectId"), areaId: text("areaId"))
    }

    /// Your open projects and your areas, from their records, for picking where to-dos go.
    /// Projects come after their area, in Sectis's order.
    static func places(projects: [[String: Any]], areas: [[String: Any]]) -> [Place] {
        func order(_ record: [String: Any]) -> Double { (record["order"] as? NSNumber)?.doubleValue ?? 0 }
        func title(_ record: [String: Any], _ fallback: String) -> String {
            let text = (record["title"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            return text.isEmpty ? fallback : text
        }
        let liveAreas = areas.filter { ($0["id"] as? String) != nil }.sorted { order($0) < order($1) }
        let areaTitles = Dictionary(liveAreas.map { ($0["id"] as! String, title($0, "New Area")) }, uniquingKeysWith: { a, _ in a })
        let liveProjects = projects.filter {
            ($0["id"] as? String) != nil && ($0["status"] as? String ?? "open") == "open"
                && $0["trashed"] as? Bool != true && $0["isTemplate"] as? Bool != true && $0["blueprint"] as? Bool != true
        }.sorted { order($0) < order($1) }
        var result: [Place] = []
        for area in liveAreas {
            let id = area["id"] as! String
            result.append(Place(kind: .area, id: id, title: areaTitles[id] ?? "New Area"))
            for project in liveProjects where project["areaId"] as? String == id {
                result.append(Place(kind: .project, id: project["id"] as! String, title: title(project, "New Project"), area: areaTitles[id]))
            }
        }
        for project in liveProjects where (project["areaId"] as? String).flatMap({ areaTitles[$0] }) == nil {
            result.append(Place(kind: .project, id: project["id"] as! String, title: title(project, "New Project")))
        }
        return result
    }

    static func tagRecord(id: String, title: String) -> [String: Any] {
        ["id": id, "title": title, "parentId": NSNull(), "order": 100_000]
    }
}

/// One action item from a note.
struct ActionItem: Hashable, Sendable {
    /// The task, without its owner.
    var title: String
    /// Who it's for, as written ("Me", "Dana and me"); empty when the line doesn't say.
    var owner = ""
    /// The person or topic it was listed under, if any.
    var group = ""
    /// "YYYY-MM-DD" when the line gives a due date.
    var deadline: String?
    /// The line as it was written.
    var line: String
    /// Lines indented under it.
    var details: [String] = []
    /// The wording it was first read with, when you've changed `title` before sending.
    var originalTitle: String?
    /// The person it was listed under ("**Dana**", "### Dana", "Dana's next steps"), when the
    /// heading or label it's under names someone.
    var groupPerson: String?
    /// Someone else's item, sent to Sectis's Waiting For: who you're waiting on. Nil for yours.
    var waitingOn: String?

    /// What its Sectis ID is made from: the first wording, so an item you reworded and sent
    /// isn't added a second time.
    var idTitle: String { originalTitle ?? title }
}

/// Finds the unchecked action items in Markdown notes and works out whose they are.
enum ActionItemParser {
    /// Owner words that mean the person whose notes these are.
    static let selfWords: Set<String> = ["me", "myself", "you", "i", "yourself", "mine"]
    /// Owner words that mean everyone in the meeting, which includes you.
    static let everyoneWords: Set<String> = [
        "everyone", "everybody", "all", "all of us", "both", "both of us", "we", "us", "all attendees", "everyone here",
    ]

    // MARK: Names

    /// Lowercased, accent-free and single-spaced, for comparing names.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The names you go by, ready to compare: each one, plus the first name of a full name.
    static func names(_ list: [String]) -> Set<String> {
        var result: Set<String> = []
        for entry in list {
            let name = normalize(entry).trimmingCharacters(in: CharacterSet(charactersIn: "@.,;:() "))
            guard !name.isEmpty else { continue }
            result.insert(name)
            let words = name.split(separator: " ")
            if words.count > 1, let first = words.first, first.count > 1 { result.insert(String(first)) }
        }
        return result
    }

    /// True when an owner ("Me", "Dana and Matthew", "@matt", "everyone") includes you.
    static func ownerIncludesMe(_ owner: String, names: Set<String>) -> Bool {
        let text = normalize(owner).replacing(#/\([^)]*\)/#, with: " ")
        for piece in text.split(separator: #/\s*(?:,|;|/|&|\+|\band\b|\bwith\b|\bplus\b)\s*/#) {
            var token = String(piece).trimmingCharacters(in: CharacterSet(charactersIn: " @.:!*_-–—\"'"))
            if token.hasSuffix("'s") { token = String(token.dropLast(2)) }
            token = token.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { continue }
            if selfWords.contains(token) || everyoneWords.contains(token) || names.contains(token) { return true }
            // "Matthew Zeller" when you go by "Matthew".
            if token.contains(" "), let first = token.split(separator: " ").first, names.contains(String(first)) { return true }
        }
        return false
    }

    /// Whether an item is yours. An item with no owner counts when it's listed under you,
    /// or when nobody else is in the note (`solo`: a voice memo, or notes you typed alone).
    static func isMine(_ item: ActionItem, names: Set<String>, solo: Bool) -> Bool {
        if !item.owner.isEmpty { return ownerIncludesMe(item.owner, names: names) }
        if !item.group.isEmpty, groupIsMe(item.group, names: names) { return true }
        return solo
    }

    /// Who an item belongs to when it's someone else's: the owner it names ("Dana", "Dana and
    /// Sam"), or the person it's listed under. Nil when it's yours, or when nothing says whose
    /// it is.
    static func someoneElse(_ item: ActionItem, names: Set<String>) -> String? {
        if !item.owner.isEmpty {
            return ownerIncludesMe(item.owner, names: names) ? nil : personName(item.owner)
        }
        guard let person = item.groupPerson, !groupIsMe(item.group, names: names),
              !ownerIncludesMe(person, names: names) else { return nil }
        return person
    }

    /// An owner as a name to wait on: "@dana" → "Dana", "Dana's" → "Dana", "Dana (PM)" → "Dana".
    static func personName(_ owner: String) -> String? {
        var name = plain(owner).replacing(#/\([^)]*\)/#, with: " ")
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " @.:!*_-–—\"'“”"))
        for suffix in ["'s", "’s"] where name.hasSuffix(suffix) { name = String(name.dropLast(2)) }
        let words = name.split(whereSeparator: { $0.isWhitespace }).map { word -> String in
            let text = String(word).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            // A lowercase handle like "dana" reads better as "Dana"; "and" stays as it is.
            guard let first = text.first, first.isLowercase, !["and", "with", "plus", "or"].contains(text) else { return text }
            return first.uppercased() + text.dropFirst()
        }.filter { !$0.isEmpty }
        name = words.joined(separator: " ")
        guard !name.isEmpty, name.count <= 60, !isMetaWord(name) else { return nil }
        return name
    }

    /// The person a heading or label names: "Dana's action items", "Next steps for Dana" — or
    /// just "Dana" when it's a label of its own ("**Dana**", "Dana:") or a heading inside an
    /// action-items section. Topic headings ("## Vimeo pricing") don't count.
    static func personInGroup(_ group: String, isLabel: Bool, inActionSection: Bool) -> String? {
        var text = plain(group)
        guard !text.isEmpty else { return nil }
        let named = isActionHeading(text)
        if named {
            text = text.replacing(#/(?i)\b(?:action items?|actions|next steps?|follow[- ]?ups?|to-?dos?|to do list|task list|tasks|assignments)\b/#, with: " ")
            text = text.replacing(#/(?i)\b(?:for|owner|owners|owned by|assigned to|from)\b/#, with: " ")
        } else if !(isLabel || inActionSection) {
            return nil
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " :*_-–—()|"))
        for suffix in ["'s", "’s"] where text.hasSuffix(suffix) { text = String(text.dropLast(2)) }
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !text.isEmpty, text.split(separator: " ").count <= 3, looksLikeName(text), !isMetaWord(text),
              !otherSections.contains(normalize(text)), !selfWords.contains(normalize(text)) else { return nil }
        return text
    }

    /// A heading or label that names you: "Matthew", "Me", "My tasks", "For me",
    /// "Matthew's action items", "Next steps — Matthew".
    static func groupIsMe(_ group: String, names: Set<String>) -> Bool {
        var text = normalize(group)
        if text.firstMatch(of: #/^(?:my|mine)\b/#) != nil { return true }
        text = text.replacing(actionPhrase, with: " ")
        text = text.replacing(#/\b(?:for|owner|owners|owned by|assigned to|from)\b/#, with: " ")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " :*_-–—()"))
        guard !text.isEmpty else { return false }
        return ownerIncludesMe(text, names: names)
    }

    private static let actionPhrase = #/\b(?:action items?|actions|next steps?|follow[- ]?ups?|to-?dos?|to do list|task list|tasks|assignments)\b/#

    static func isActionHeading(_ text: String) -> Bool {
        normalize(text).firstMatch(of: actionPhrase) != nil
    }

    /// Section names that end a list of action items started by a bold label.
    private static let otherSections: Set<String> = [
        "summary", "decisions", "notes", "key points", "details", "questions", "open questions", "discussion",
        "overview", "attendees", "agenda", "highlights", "takeaways", "key takeaways", "context", "background",
    ]

    // MARK: Reading notes

    /// Every unchecked action item: checkboxes anywhere, plus plain bullets under an
    /// "Action items", "Next steps", "Follow-ups" or "To-do" heading.
    static func items(in markdown: String, names: Set<String>, meetingDate: Date, calendar: Calendar = .current) -> [ActionItem] {
        var result: [ActionItem] = []
        var actionLevel: Int?
        var group = ""
        /// The group came from a label line of its own ("**Dana**", "Dana:"), not a heading.
        var groupIsLabel = false
        var lastWasItem = false

        func add(_ text: String, _ line: String) {
            if var item = parse(text, group: group, line: line, names: names, meetingDate: meetingDate, calendar: calendar) {
                item.groupPerson = personInGroup(group, isLabel: groupIsLabel, inActionSection: actionLevel != nil)
                result.append(item)
                lastWasItem = true
            } else {
                lastWasItem = false
            }
        }

        for raw in markdown.components(separatedBy: .newlines) {
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if let heading = line.firstMatch(of: #/^(#{1,6})\s+(.+)$/#) {
                let level = heading.output.1.count
                let text = plain(String(heading.output.2)).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                if isActionHeading(text) {
                    actionLevel = level
                    group = text   // "Action items" says nothing; "Matthew's action items" does.
                } else if let parent = actionLevel, level > parent {
                    group = text
                } else {
                    actionLevel = nil
                    group = text
                }
                groupIsLabel = false
                lastWasItem = false
                continue
            }

            if let check = line.firstMatch(of: #/^(?:[-*+•]|\d+[.)])\s+\[([ xX])\]\s*(.*)$/#) {
                if check.output.1 == " " { add(String(check.output.2), line) } else { lastWasItem = false }
                continue
            }

            if let bullet = line.firstMatch(of: #/^(?:[-*+•]|\d+[.)])\s+(.+)$/#) {
                if indent >= 2, lastWasItem, !result.isEmpty {
                    result[result.count - 1].details.append(plain(String(bullet.output.1)))
                } else if actionLevel != nil {
                    add(String(bullet.output.1), line)
                } else {
                    lastWasItem = false
                }
                continue
            }

            // A line of its own naming a person or section: "**Dana**", "Dana:", "**Next steps:**".
            lastWasItem = false
            let label = plain(line).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            let isBold = line.hasPrefix("**") && line.hasSuffix("**")
            guard isBold || line.hasSuffix(":"), !label.isEmpty, label.count <= 40,
                  label.split(separator: " ").count <= 5 else { continue }
            groupIsLabel = true
            if isActionHeading(label) {
                actionLevel = actionLevel ?? 7
                group = label
            } else if actionLevel == 7, otherSections.contains(normalize(label)) {
                actionLevel = nil
                group = label
            } else {
                group = label
            }
        }
        return result
    }

    /// Text without Markdown emphasis or code marks, single-spaced.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: One line

    /// Lines that say there's nothing to do.
    private static let emptyItems: Set<String> = [
        "none", "na", "nothing", "tbd", "noneidentified", "nonenoted", "noneyet", "noactionitems", "nonextsteps",
        "nofollowups", "noactionitemsidentified", "noactionitemsweremade", "nothingtodo",
    ]

    /// Splits "Task — owner, due date" (and the other ways models write it) into its parts.
    static func parse(_ raw: String, group: String, line: String, names: Set<String>,
                      meetingDate: Date, calendar: Calendar) -> ActionItem? {
        var text = plain(raw)
        guard !text.isEmpty, !emptyItems.contains(SectisFormat.dedupKey(text)) else { return nil }
        var owner = ""
        var meta = ""

        if let label = text.firstMatch(of: #/(?i)\b(?:owners?|assignees?|assigned to|responsible|who)\s*[:=]\s*([^;()\[\]|—–]+)/#) {
            // "Send the deck (Owner: Dana, due Fri)", "Send the deck — Owner: Dana"
            owner = ownerPart(String(label.output.1), meetingDate: meetingDate, calendar: calendar)
            meta = String(text[label.range.lowerBound...])
            text = trimSeparators(String(text[..<label.range.lowerBound]))
        } else if let prefix = text.firstMatch(of: #/^@?([^:]{1,40}):\s+(.+)$/#),
                  prefix.output.1.split(separator: " ").count <= 4,
                  ownerIncludesMe(String(prefix.output.1), names: names) || looksLikeName(String(prefix.output.1)),
                  !isMetaWord(String(prefix.output.1)) {
            // "Dana: send the deck"
            owner = String(prefix.output.1)
            text = String(prefix.output.2)
            if let parts = splitDash(text) { text = parts.0; meta = parts.1 }
        } else if let parts = splitDash(text) {
            // "Send the deck — Dana, Friday", or now and then "Me — send the deck"
            let (left, right) = parts
            let rightOwner = ownerPart(right, meetingDate: meetingDate, calendar: calendar)
            if left.split(separator: " ").count <= 3, ownerIncludesMe(left, names: names),
               !ownerIncludesMe(rightOwner, names: names) {
                owner = left
                text = right
            } else {
                owner = rightOwner
                text = left
                meta = right
            }
        } else if let paren = text.firstMatch(of: #/^(.+?)\s*\(([^()]+)\)\s*\.?$/#) {
            // "Send the deck (Dana, Friday)"
            text = String(paren.output.1)
            meta = String(paren.output.2)
            owner = ownerPart(meta, meetingDate: meetingDate, calendar: calendar)
        } else if let at = text.firstMatch(of: #/^@([\p{L}][\p{L}'’.\-]*)\s+(.+)$/#) {
            // "@dana send the deck"
            owner = String(at.output.1)
            text = String(at.output.2)
        } else if let sentence = text.firstMatch(of: #/^([\p{L}][\p{L}'’.\-]*(?:\s+[\p{L}][\p{L}'’.\-]*){0,2})\s+(?:to|will|should|must|needs to|has to|is going to|is to)\s+(.+)$/#) {
            // "Dana to send the deck", "I will send the deck"
            let who = String(sentence.output.1)
            if ownerIncludesMe(who, names: names) || looksLikeName(who) {
                owner = who
                text = String(sentence.output.2)
            }
        }

        owner = owner.trimmingCharacters(in: CharacterSet(charactersIn: " .:-–—*_"))
        if isMetaWord(owner) { owner = "" }

        var deadline = dueDate(in: meta, meetingDate: meetingDate, calendar: calendar)
        if deadline == nil, let cue = text.firstMatch(of: #/(?i)\b(?:by|due|before|until|no later than)\s+(.+)$/#) {
            deadline = dueDate(in: String(cue.output.1), meetingDate: meetingDate, calendar: calendar)
        }

        var title = trimSeparators(text)
        title = title.replacing(#/^(?i)(?:to-?do|task|action)\s*:\s*/#, with: "")
        if title.hasSuffix("."), !title.hasSuffix("..") { title.removeLast() }
        if let first = title.first, first.isLowercase { title = first.uppercased() + title.dropFirst() }
        guard !title.isEmpty, !emptyItems.contains(SectisFormat.dedupKey(title)) else { return nil }
        return ActionItem(title: title, owner: owner, group: group, deadline: deadline, line: plain(line))
    }

    /// "Task — rest": split at the first em dash, en dash or bar, or failing that the first
    /// spaced hyphen ("Review Q3 - Q4 budget — Me" splits at the em dash).
    private static func splitDash(_ text: String) -> (String, String)? {
        let match = text.firstMatch(of: #/\s+(?:—|–|\|)\s+|\s*—\s*/#) ?? text.firstMatch(of: #/\s+(?:--|-)\s+/#)
        guard let match else { return nil }
        let left = trimSeparators(String(text[..<match.range.lowerBound]))
        let right = trimSeparators(String(text[match.range.upperBound...]))
        guard !left.isEmpty, !right.isEmpty else { return nil }
        return (left, right)
    }

    /// The owners at the start of "Dana, Me, by Friday" / "Me (due Fri)" / "Me by Friday":
    /// the comma-separated names before the first piece that's a date or a note.
    private static func ownerPart(_ text: String, meetingDate: Date, calendar: Calendar) -> String {
        var owners: [String] = []
        for piece in text.split(separator: #/\s*[,;]\s*/#) {
            let full = String(piece)
            let cut = full.split(separator: #/\s*[(—–|]\s*|\s+(?:by|due|before|until|eta)\b/#, maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? full
            let name = cut.trimmingCharacters(in: CharacterSet(charactersIn: " .:-*_"))
            if name.isEmpty || name.split(separator: " ").count > 4 || name.contains(where: \.isNumber)
                || isMetaWord(name) || name.firstMatch(of: #/(?i)^(?:due|by|before|until|eta|asap|deadline|priority|high|low|medium|urgent|ongoing|done|pending)\b/#) != nil
                || dueDate(in: name, meetingDate: meetingDate, calendar: calendar) != nil {
                break
            }
            owners.append(name)
            if cut.count < full.count { break }
        }
        return owners.joined(separator: ", ")
    }

    private static func trimSeparators(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "—–-|,;:(").union(.whitespaces))
    }

    /// Words that start a note about a task rather than name its owner.
    private static func isMetaWord(_ text: String) -> Bool {
        let t = normalize(text)
        return ["due", "by", "deadline", "note", "notes", "fyi", "status", "priority", "when", "date", "re", "eta",
                "follow up", "follow-up", "next step", "next steps", "action", "action item", "todo", "to-do", "task",
                "tbd", "n/a", "none", "unassigned", "unknown", "owner tbd", "someone", "anyone", "asap"].contains(t)
    }

    /// "Dana", "Dana Lee": capitalized words that aren't a common way to start a sentence.
    private static func looksLikeName(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        guard let first = words.first, words.allSatisfy({ $0.first?.isUppercase == true }) else { return false }
        let starters: Set<String> = ["need", "needs", "remember", "make", "try", "plan", "want", "have", "going", "ask",
                                     "be", "remind", "decide", "start", "continue", "check", "get", "it", "this", "that",
                                     "someone", "somebody", "team", "they", "he", "she", "send", "call", "email",
                                     "review", "update", "schedule", "set", "book", "follow", "share", "draft", "write",
                                     "confirm", "find", "look", "order", "buy", "pay", "fix", "test", "prepare", "submit"]
        return !starters.contains(normalize(String(first)))
    }

    // MARK: Due dates

    /// A due date in text like "Friday", "next Tuesday", "tomorrow", "Oct 31", "10/31",
    /// "2026-10-31" or "end of week", worked out from the meeting's date. "YYYY-MM-DD" or nil.
    static func dueDate(in text: String, meetingDate: Date, calendar: Calendar = .current) -> String? {
        guard !text.isEmpty else { return nil }
        let t = " " + normalize(text).replacingOccurrences(of: ",", with: " ") + " "
        let day = calendar.startOfDay(for: meetingDate)
        func add(_ days: Int) -> String? { calendar.date(byAdding: .day, value: days, to: day).map { ymd($0, calendar) } }

        if let iso = t.firstMatch(of: #/\b(\d{4})-(\d{1,2})-(\d{1,2})\b/#),
           let date = make(Int(iso.output.1)!, Int(iso.output.2)!, Int(iso.output.3)!, calendar) {
            return ymd(date, calendar)
        }
        if let slash = t.firstMatch(of: #/\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b/#) {
            var year = slash.output.3.flatMap { Int($0) }
            if let y = year, y < 100 { year = 2000 + y }
            if let date = resolve(month: Int(slash.output.1)!, day: Int(slash.output.2)!, year: year, after: day, calendar: calendar) {
                return ymd(date, calendar)
            }
        }
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        if let named = t.firstMatch(of: #/\b(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b(?:\s+(\d{4}))?/#),
           let month = months.firstIndex(of: String(named.output.1.prefix(3))),
           let date = resolve(month: month + 1, day: Int(named.output.2)!, year: named.output.3.flatMap { Int($0) }, after: day, calendar: calendar) {
            return ymd(date, calendar)
        }
        if let named = t.firstMatch(of: #/\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b(?:\s+(\d{4}))?/#),
           let month = months.firstIndex(of: String(named.output.2.prefix(3))),
           let date = resolve(month: month + 1, day: Int(named.output.1)!, year: named.output.3.flatMap { Int($0) }, after: day, calendar: calendar) {
            return ymd(date, calendar)
        }

        if t.contains(" today ") || t.contains(" tonight ") || t.contains(" eod ") || t.contains(" end of day ")
            || t.contains(" end of the day ") || t.contains(" cob ") {
            return add(0)
        }
        if t.contains(" tomorrow ") || t.contains(" tmrw ") || t.contains(" tmr ") { return add(1) }

        let weekday = calendar.component(.weekday, from: day) // 1 = Sunday … 7 = Saturday
        if t.contains(" eow ") || t.contains(" end of week ") || t.contains(" end of the week ") || t.contains(" this week ") {
            return add((6 - weekday + 7) % 7)
        }
        if t.contains(" eom ") || t.contains(" end of month ") || t.contains(" end of the month ") {
            guard let range = calendar.range(of: .day, in: .month, for: day) else { return nil }
            return add(range.count - calendar.component(.day, from: day))
        }

        if let match = t.firstMatch(of: #/\b(next\s+|this\s+|coming\s+)?(sun|mon|tue|tues|wed|weds|thu|thur|thurs|fri|sat)(?:day|nesday|sday|rsday|urday)?\b/#) {
            let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            guard let index = names.firstIndex(of: String(match.output.2.prefix(3))) else { return nil }
            var ahead = (index + 1 - weekday + 7) % 7
            if ahead == 0 { ahead = 7 }
            // "next Friday" said on a Monday means the Friday after this week's.
            if match.output.1?.trimmingCharacters(in: .whitespaces) == "next",
               let target = calendar.date(byAdding: .day, value: ahead, to: day),
               calendar.isDate(target, equalTo: day, toGranularity: .weekOfYear) {
                ahead += 7
            }
            return add(ahead)
        }
        return nil
    }

    private static func make(_ year: Int, _ month: Int, _ day: Int, _ calendar: Calendar) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.month, from: date) == month   // not February 30
        else { return nil }
        return date
    }

    /// A month and day without a year: the next one on or after the meeting, unless it's a
    /// few weeks before it (then it's probably a date in the past, not a due date).
    private static func resolve(month: Int, day: Int, year: Int?, after start: Date, calendar: Calendar) -> Date? {
        if let year { return make(year, month, day, calendar) }
        let thisYear = calendar.component(.year, from: start)
        guard let candidate = make(thisYear, month, day, calendar) else { return nil }
        if candidate >= start { return candidate }
        let daysBefore = calendar.dateComponents([.day], from: candidate, to: start).day ?? 0
        return daysBefore <= 45 ? nil : make(thisYear + 1, month, day, calendar)
    }

    private static func ymd(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
