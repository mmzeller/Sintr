import Foundation

extension Notification.Name {
    /// A key, token, join code or integration setting changed.
    static let sintrIntegrationsChanged = Notification.Name("SintrIntegrationsChanged")
}

/// Apps a note can be sent to. Nothing is sent unless you press Send — or, for Sectis, Notion
/// and webhooks only, you turn on "Send automatically after Enhance" for that app.
/// Keys, tokens and the Sectis join code are kept in the Keychain.
enum IntegrationKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case sectis, notion, hubspot, attio, affinity, webhook

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sectis: "Sectis"
        case .notion: "Notion"
        case .hubspot: "HubSpot"
        case .attio: "Attio"
        case .affinity: "Affinity"
        case .webhook: "Zapier / webhook"
        }
    }

    var systemImage: String {
        switch self {
        case .sectis: "checklist"
        case .notion: "doc.richtext"
        case .hubspot, .attio, .affinity: "person.crop.rectangle.stack"
        case .webhook: "bolt.horizontal"
        }
    }

    /// CRM notes are attached to a person, found by email.
    var needsContact: Bool { self == .hubspot || self == .attio || self == .affinity }
    var needsKey: Bool { self != .webhook }
    var canAutoSend: Bool { self == .sectis || self == .notion || self == .webhook }
    /// Sectis gets your action items, not the note, so the transcript never goes with it.
    var sendsWholeNote: Bool { self != .sectis }
    /// The target field can be left empty (Sectis: the names you go by).
    var targetIsOptional: Bool { self == .sectis }
    /// Personal settings that a shared team setup shouldn't carry or overwrite.
    var isPersonal: Bool { self == .sectis }

    var keyLabel: String {
        switch self {
        case .sectis: "Join code"
        case .notion: "Internal integration secret"
        case .hubspot: "Private app access token"
        case .attio: "Access token"
        case .affinity: "API key"
        case .webhook: ""
        }
    }

    var targetLabel: String? {
        switch self {
        case .sectis: "Names you go by (optional)"
        case .notion: "Page or database link"
        case .webhook: "Webhook URL"
        default: nil
        }
    }

    var setupHelp: String {
        switch self {
        case .sectis:
            "Sends only your own action items — unchecked ones whose owner is “Me” or one of the names below — to your Sectis Inbox, tagged Meeting. Turn on sync in Sectis first, then open Settings → Sync → Add Another Device, copy the code that starts with SECTIS- and save it here. Each to-do is encrypted on this \(Platform.deviceName) the same way Sectis does it."
        case .notion:
            "Create an internal integration at notion.so/profile/integrations and copy its secret. Then open the page or database notes should go to, choose ••• → Connections → add your integration, and paste that page's link here."
        case .hubspot:
            "In HubSpot: Settings → Integrations → Private Apps → Create. Give it the contacts read and write scopes, then copy the access token. Notes are attached to the contact with the email you enter when sending."
        case .attio:
            "In Attio: Workspace settings → Developers → New access token, with read-write access to notes and read access to records. Notes are attached to the person with the email you enter when sending."
        case .affinity:
            "In Affinity: Settings → API → Generate an API key. Notes are attached to the person with the email you enter when sending."
        case .webhook:
            "Paste a webhook URL — a Zapier “Catch Hook”, a Make or n8n webhook, or a Power Automate “When an HTTP request is received” flow. Sintr sends the note as JSON, so you can route it anywhere."
        }
    }

    var secretAccount: String { "integration.\(rawValue)" }
}

/// Per-app settings (no secrets).
struct IntegrationConfig: Codable, Equatable, Sendable {
    var target = ""
    var autoSend = false
    var includeTranscript = false
}

enum IntegrationSettings {
    static func load() -> [String: IntegrationConfig] {
        guard let text = UserDefaults.standard.string(forKey: AppSettings.integrations),
              let data = text.data(using: .utf8),
              let saved = try? JSONDecoder().decode([String: IntegrationConfig].self, from: data)
        else { return [:] }
        return saved
    }

    static func config(_ kind: IntegrationKind) -> IntegrationConfig {
        load()[kind.rawValue] ?? IntegrationConfig()
    }

    static func save(_ config: IntegrationConfig, for kind: IntegrationKind) {
        var all = load()
        all[kind.rawValue] = config
        if let data = try? JSONEncoder().encode(all), let text = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(text, forKey: AppSettings.integrations)
        }
        NotificationCenter.default.post(name: .sintrIntegrationsChanged, object: nil)
    }

    static func secret(_ kind: IntegrationKind) -> String? { SecretStore.get(kind.secretAccount) }
    static func setSecret(_ value: String?, for kind: IntegrationKind) {
        SecretStore.set(kind.secretAccount, value)
        NotificationCenter.default.post(name: .sintrIntegrationsChanged, object: nil)
    }

    static func isConfigured(_ kind: IntegrationKind) -> Bool {
        // The screenshot demo shows the Sectis parts of a note without a join code.
        if kind == .sectis, ScreenshotDemo.isActive { return true }
        if kind.needsKey, secret(kind) == nil { return false }
        if kind.targetLabel != nil, !kind.targetIsOptional,
           config(kind).target.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    static var configured: [IntegrationKind] { IntegrationKind.allCases.filter(isConfigured) }
}

enum IntegrationError: LocalizedError {
    case notSetUp(IntegrationKind)
    case needsEmail(IntegrationKind)
    case contactNotFound(IntegrationKind, String)
    case badTarget(String)
    case service(IntegrationKind, Int, String)

    var errorDescription: String? {
        switch self {
        case .notSetUp(let kind): "\(kind.title) isn't set up yet. Add it in Settings → Integrations."
        case .needsEmail(let kind): "\(kind.title) attaches notes to a person — enter their email address."
        case .contactNotFound(let kind, let email): "\(kind.title) has no person with the email \(email)."
        case .badTarget(let why): why
        case .service(let kind, let status, let message):
            switch status {
            case 401, 403: "\(kind.title) didn't accept the key or token (\(status)). Check it in Settings → Integrations. \(message)"
            case 404: "\(kind.title) couldn't find where to put the note (\(status)). \(message)"
            case 429: "\(kind.title) is limiting requests right now. Try again in a minute."
            default: "\(kind.title) returned an error (\(status)): \(message)"
            }
        }
    }
}

enum Integrations {
    /// Sends a note and returns a record of it (with a link when the app gives one).
    static func send(_ note: Note, to kind: IntegrationKind, contactEmail: String?, includeTranscript: Bool) async throws -> NoteSend {
        guard IntegrationSettings.isConfigured(kind) else { throw IntegrationError.notSetUp(kind) }
        let key = IntegrationSettings.secret(kind) ?? ""
        let config = IntegrationSettings.config(kind)
        let email = contactEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if kind.needsContact, email.isEmpty { throw IntegrationError.needsEmail(kind) }
        let markdown = body(of: note, includeTranscript: includeTranscript)
        let result: NoteSend
        switch kind {
        case .sectis: return try await Sectis.send(note, joinCode: key)
        case .notion: result = try await sendToNotion(note, markdown: markdown, key: key, target: config.target)
        case .hubspot: result = try await sendToHubSpot(note, markdown: markdown, key: key, email: email)
        case .attio: result = try await sendToAttio(note, markdown: markdown, key: key, email: email)
        case .affinity: result = try await sendToAffinity(note, markdown: markdown, key: key, email: email)
        case .webhook: result = try await sendToWebhook(note, includeTranscript: includeTranscript, url: config.target)
        }
        ActivityLog.add("Sent a note to \(kind.title)")
        return result
    }

    /// Checks the key/token (and, for a webhook, sends a test message).
    static func test(_ kind: IntegrationKind) async throws -> String {
        let key = IntegrationSettings.secret(kind) ?? ""
        switch kind {
        case .sectis:
            return try await Sectis.test(joinCode: key)
        case .notion:
            _ = try await request(kind, "GET", "https://api.notion.com/v1/users/me", headers: notionHeaders(key))
            return "Connected to Notion."
        case .hubspot:
            _ = try await request(kind, "GET", "https://api.hubapi.com/crm/v3/objects/contacts?limit=1", headers: bearer(key))
            return "Connected to HubSpot."
        case .attio:
            _ = try await request(kind, "GET", "https://api.attio.com/v2/self", headers: bearer(key))
            return "Connected to Attio."
        case .affinity:
            _ = try await request(kind, "GET", "https://api.affinity.co/v2/auth/whoami", headers: bearer(key))
            return "Connected to Affinity."
        case .webhook:
            let url = IntegrationSettings.config(kind).target
            _ = try await request(kind, "POST", url, json: ["app": "Sintr", "test": true, "message": "Sintr is connected."])
            return "Sent a test message."
        }
    }

    // MARK: Content

    /// The note as Markdown: the enhanced notes (or your own notes), optionally the transcript.
    static func body(of note: Note, includeTranscript: Bool) -> String {
        var parts: [String] = []
        let enhanced = note.enhanced.trimmingCharacters(in: .whitespacesAndNewlines)
        let mine = note.myNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !enhanced.isEmpty {
            parts.append(enhanced)
        } else if !mine.isEmpty {
            parts.append(mine)
        }
        if includeTranscript, !note.transcript.isEmpty {
            parts.append("## Transcript\n\n" + note.transcriptLines())
        }
        if parts.isEmpty { parts.append("(No notes yet.)") }
        return parts.joined(separator: "\n\n")
    }

    // MARK: Notion

    private static func notionHeaders(_ key: String) -> [String: String] {
        ["Authorization": "Bearer \(key)", "Notion-Version": "2022-06-28"]
    }

    /// The 32-character ID in a Notion link (or a bare ID).
    static func notionID(from link: String) -> String? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = trimmed.components(separatedBy: "?").first ?? trimmed
        // The ID is the end of the link's last part: "My-Page-<32 hex>" or a plain UUID.
        let last = path.split(separator: "/").last.map(String.init) ?? path
        let compact = last.replacingOccurrences(of: "-", with: "")
        guard compact.count >= 32 else { return nil }
        let id = String(compact.suffix(32))
        return id.allSatisfy(\.isHexDigit) ? id.lowercased() : nil
    }

    private static func sendToNotion(_ note: Note, markdown: String, key: String, target: String) async throws -> NoteSend {
        guard let id = notionID(from: target) else {
            throw IntegrationError.badTarget("That doesn't look like a Notion page or database link. Copy the link from Notion (••• → Copy link).")
        }
        let headers = notionHeaders(key)
        let title = "\(note.displayTitle) — \(note.created.formatted(date: .abbreviated, time: .omitted))"
        let titleText: [[String: Any]] = [["type": "text", "text": ["content": String(title.prefix(1900))]]]

        // A database needs its title property's name; a page just takes "title".
        var parent: [String: Any] = ["page_id": id]
        var properties: [String: Any] = ["title": ["title": titleText]]
        if let database = try? await request(.notion, "GET", "https://api.notion.com/v1/databases/\(id)", headers: headers),
           let schema = database["properties"] as? [String: Any],
           let titleName = schema.first(where: { (($0.value as? [String: Any])?["type"] as? String) == "title" })?.key {
            parent = ["database_id": id]
            properties = [titleName: ["title": titleText]]
        }

        let blocks = NotionBlocks.from(markdown)
        let created = try await request(.notion, "POST", "https://api.notion.com/v1/pages", headers: headers, json: [
            "parent": parent,
            "properties": properties,
            "children": Array(blocks.prefix(100)),
        ])
        let pageID = created["id"] as? String ?? ""
        var rest = Array(blocks.dropFirst(100))
        while !rest.isEmpty, !pageID.isEmpty {
            let batch = Array(rest.prefix(100))
            rest = Array(rest.dropFirst(100))
            _ = try await request(.notion, "PATCH", "https://api.notion.com/v1/blocks/\(pageID)/children",
                                  headers: headers, json: ["children": batch])
        }
        return NoteSend(destination: "Notion", link: created["url"] as? String)
    }

    // MARK: HubSpot

    private static func sendToHubSpot(_ note: Note, markdown: String, key: String, email: String) async throws -> NoteSend {
        let search = try await request(.hubspot, "POST", "https://api.hubapi.com/crm/v3/objects/contacts/search",
                                       headers: bearer(key), json: [
            "filterGroups": [["filters": [["propertyName": "email", "operator": "EQ", "value": email]]]],
            "properties": ["email"],
            "limit": 1,
        ])
        guard let contactID = ((search["results"] as? [[String: Any]])?.first?["id"] as? String) else {
            throw IntegrationError.contactNotFound(.hubspot, email)
        }
        let html = "<p><strong>\(SimpleHTML.escape(note.displayTitle))</strong></p>" + SimpleHTML.from(markdown)
        let created = try await request(.hubspot, "POST", "https://api.hubapi.com/crm/v3/objects/notes",
                                        headers: bearer(key), json: [
            "properties": [
                "hs_timestamp": String(Int64(note.created.timeIntervalSince1970 * 1000)),
                "hs_note_body": String(html.prefix(65_000)),
            ],
            "associations": [[
                "to": ["id": contactID],
                "types": [["associationCategory": "HUBSPOT_DEFINED", "associationTypeId": 202]],
            ]],
        ])
        _ = created
        return NoteSend(destination: "HubSpot (\(email))")
    }

    // MARK: Attio

    private static func sendToAttio(_ note: Note, markdown: String, key: String, email: String) async throws -> NoteSend {
        let found = try await request(.attio, "POST", "https://api.attio.com/v2/objects/people/records/query",
                                      headers: bearer(key), json: ["filter": ["email_addresses": email], "limit": 1])
        guard let record = (found["data"] as? [[String: Any]])?.first,
              let recordID = (record["id"] as? [String: Any])?["record_id"] as? String
        else { throw IntegrationError.contactNotFound(.attio, email) }
        _ = try await request(.attio, "POST", "https://api.attio.com/v2/notes", headers: bearer(key), json: [
            "data": [
                "parent_object": "people",
                "parent_record_id": recordID,
                "title": note.displayTitle,
                "format": "markdown",
                "content": markdown,
            ],
        ])
        return NoteSend(destination: "Attio (\(email))")
    }

    // MARK: Affinity

    private static func sendToAffinity(_ note: Note, markdown: String, key: String, email: String) async throws -> NoteSend {
        // Finding the person uses Affinity's search (API v1, key as the Basic-auth password).
        var components = URLComponents(string: "https://api.affinity.co/persons")!
        components.queryItems = [URLQueryItem(name: "term", value: email)]
        let basic = Data(":\(key)".utf8).base64EncodedString()
        let found = try await request(.affinity, "GET", components.url!.absoluteString, headers: ["Authorization": "Basic \(basic)"])
        let persons = found["persons"] as? [[String: Any]] ?? []
        let match = persons.first { person in
            let emails = (person["emails"] as? [String] ?? []) + [person["primary_email"] as? String].compactMap { $0 }
            return emails.contains { $0.caseInsensitiveCompare(email) == .orderedSame }
        } ?? persons.first
        guard let personID = match?["id"] as? Int else { throw IntegrationError.contactNotFound(.affinity, email) }
        let html = "<p><strong>\(SimpleHTML.escape(note.displayTitle))</strong></p>" + SimpleHTML.from(markdown)
        _ = try await request(.affinity, "POST", "https://api.affinity.co/v2/notes", headers: bearer(key), json: [
            "type": "entities",
            "content": ["html": html],
            "persons": [["id": personID]],
        ])
        return NoteSend(destination: "Affinity (\(email))")
    }

    // MARK: Webhook

    /// The JSON a webhook receives.
    static func webhookPayload(_ note: Note, includeTranscript: Bool) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var payload: [String: Any] = [
            "id": note.id.uuidString,
            "title": note.displayTitle,
            "created": iso.string(from: note.created),
            "duration_seconds": Int(note.duration),
            "my_notes": note.myNotes,
            "enhanced_notes": note.enhanced,
            "speakers": note.speakers.map { note.displayName(forSpeaker: $0) },
        ]
        if includeTranscript {
            payload["transcript"] = note.transcript.map {
                ["time": Note.clock($0.start), "speaker": note.displayName(forSpeaker: $0.speaker), "text": $0.text]
            }
            payload["transcript_text"] = note.transcriptLines()
        }
        return ["app": "Sintr", "sent": iso.string(from: Date()), "note": payload]
    }

    private static func sendToWebhook(_ note: Note, includeTranscript: Bool, url: String) async throws -> NoteSend {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespaces)), parsed.scheme == "https" || parsed.scheme == "http" else {
            throw IntegrationError.badTarget("The webhook URL should start with https://")
        }
        _ = try await request(.webhook, "POST", parsed.absoluteString, json: webhookPayload(note, includeTranscript: includeTranscript))
        return NoteSend(destination: "Webhook (\(parsed.host ?? "url"))")
    }

    // MARK: HTTP

    private static func bearer(_ key: String) -> [String: String] { ["Authorization": "Bearer \(key)"] }

    @discardableResult
    private static func request(_ kind: IntegrationKind, _ method: String, _ url: String,
                                headers: [String: String] = [:], json: [String: Any]? = nil) async throws -> [String: Any] {
        guard let target = URL(string: url) else { throw IntegrationError.badTarget("That address isn't a valid URL.") }
        var request = URLRequest(url: target)
        request.httpMethod = method
        request.timeoutInterval = 60
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let message = (object["message"] as? String)
                ?? ((object["error"] as? [String: Any])?["message"] as? String)
                ?? (object["error"] as? String)
                ?? String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw IntegrationError.service(kind, status, message)
        }
        return object
    }
}

/// Markdown → Notion blocks: headings, bullets, numbered items, to-dos, quotes, dividers and
/// paragraphs, with **bold** kept.
enum NotionBlocks {
    static func from(_ markdown: String) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line == "---" || line == "***" {
                blocks.append(["object": "block", "type": "divider", "divider": [String: Any]()])
                continue
            }
            let (type, text, checked) = classify(line)
            for piece in chunks(text, size: 1900) {
                var content: [String: Any] = ["rich_text": richText(piece)]
                if type == "to_do" { content["checked"] = checked }
                blocks.append(["object": "block", "type": type, type: content])
            }
        }
        return blocks
    }

    private static func classify(_ line: String) -> (String, String, Bool) {
        if line.hasPrefix("### ") { return ("heading_3", String(line.dropFirst(4)), false) }
        if line.hasPrefix("## ") { return ("heading_2", String(line.dropFirst(3)), false) }
        if line.hasPrefix("# ") { return ("heading_1", String(line.dropFirst(2)), false) }
        for prefix in ["- [ ] ", "* [ ] "] where line.hasPrefix(prefix) { return ("to_do", String(line.dropFirst(prefix.count)), false) }
        for prefix in ["- [x] ", "- [X] ", "* [x] "] where line.hasPrefix(prefix) { return ("to_do", String(line.dropFirst(prefix.count)), true) }
        for prefix in ["- ", "* ", "• "] where line.hasPrefix(prefix) { return ("bulleted_list_item", String(line.dropFirst(prefix.count)), false) }
        if let match = line.firstMatch(of: #/^\d+[.)]\s+/#) {
            return ("numbered_list_item", String(line[match.range.upperBound...]), false)
        }
        if line.hasPrefix("> ") { return ("quote", String(line.dropFirst(2)), false) }
        return ("paragraph", line, false)
    }

    private static func chunks(_ text: String, size: Int) -> [String] {
        guard text.count > size else { return [text] }
        var result: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            result.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        return result
    }

    /// Plain text with **bold** runs.
    private static func richText(_ text: String) -> [[String: Any]] {
        var parts: [[String: Any]] = []
        let pieces = text.components(separatedBy: "**")
        for (index, piece) in pieces.enumerated() where !piece.isEmpty {
            var item: [String: Any] = ["type": "text", "text": ["content": piece]]
            if index % 2 == 1, pieces.count > 2 { item["annotations"] = ["bold": true] }
            parts.append(item)
        }
        return parts.isEmpty ? [["type": "text", "text": ["content": " "]]] : parts
    }
}

/// Markdown → the small set of HTML CRMs accept in notes (paragraphs, bold, lists).
enum SimpleHTML {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func inline(_ text: String) -> String {
        let pieces = escape(text).components(separatedBy: "**")
        guard pieces.count > 2 else { return escape(text) }
        return pieces.enumerated().map { $0.offset % 2 == 1 ? "<strong>\($0.element)</strong>" : $0.element }.joined()
    }

    static func from(_ markdown: String) -> String {
        var html = ""
        var inList = false
        func closeList() {
            if inList { html += "</ul>"; inList = false }
        }
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let heading = line.firstMatch(of: #/^#{1,6}\s+/#) {
                closeList()
                html += "<p><strong>\(inline(String(line[heading.range.upperBound...])))</strong></p>"
            } else if let bullet = line.firstMatch(of: #/^([-*•]|\d+[.)])\s+(\[[ xX]\]\s+)?/#) {
                if !inList { html += "<ul>"; inList = true }
                let checkbox = bullet.output.2.map { $0.contains("x") || $0.contains("X") ? "☑ " : "☐ " } ?? ""
                html += "<li>\(checkbox)\(inline(String(line[bullet.range.upperBound...])))</li>"
            } else {
                closeList()
                html += "<p>\(inline(line))</p>"
            }
        }
        closeList()
        return html
    }
}
