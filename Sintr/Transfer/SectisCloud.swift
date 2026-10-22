import Foundation

/// Talks to the Firestore database Sectis syncs through, using Firestore's REST API: reads
/// your tags and creates encrypted items that Sectis picks up. Free of app types, so CI runs
/// it against the Firestore emulator with Sectis's own rules (scripts/ci-sectis-check.sh).
enum SectisCloud {
    struct Failure: LocalizedError {
        let message: String
        /// What Firebase actually said, for the Activity Log.
        var detail = ""
        /// The HTTP status and Firestore status ("ALREADY_EXISTS"…); 0 when Firebase wasn't reached.
        var httpStatus = 0
        var code = ""
        var errorDescription: String? { message }
    }

    static let firestoreAPI = "https://firestore.googleapis.com/v1/"
    static let joinCodeHelp = "In Sectis, open Settings → Sync → Add Another Device and copy the code that starts with SECTIS-."

    struct Connection: Sendable {
        let projectId: String
        let apiKey: String
        let space: String
        let key: Data
        /// Firestore's REST API (the emulator in tests).
        var baseURL = SectisCloud.firestoreAPI
        var documents: String { "projects/\(projectId)/databases/(default)/documents" }
        var items: String { "\(documents)/sectis/\(space)/items" }
    }

    static func connect(joinCode: String, baseURL: String = firestoreAPI) async throws -> Connection {
        guard let link = SectisFormat.parseJoinCode(joinCode) else {
            throw Failure(message: "That isn't a Sectis join code. \(joinCodeHelp)")
        }
        // Making the key takes a moment (150,000 rounds), so it happens off the main thread.
        let derived = await Task.detached(priority: .userInitiated) { () -> (String, Data?) in
            (SectisFormat.space(for: link.key), SectisFormat.encryptionKey(for: link.key))
        }.value
        guard let key = derived.1 else { throw Failure(message: "Couldn't make the encryption key from that join code.") }
        return Connection(projectId: link.projectId, apiKey: link.apiKey, space: derived.0, key: key, baseURL: baseURL)
    }

    // MARK: Tags

    /// Your Sectis tags (decrypted), skipping deleted ones.
    static func readTags(_ connection: Connection) async throws -> [(id: String, title: String)] {
        let query: [String: Any] = [
            "structuredQuery": [
                "from": [["collectionId": "items"]],
                "where": ["fieldFilter": [
                    "field": ["fieldPath": "k"], "op": "EQUAL", "value": ["stringValue": "tag"],
                ] as [String: Any]],
            ] as [String: Any],
        ]
        let response = try await request("\(connection.documents)/sectis/\(connection.space):runQuery",
                                         connection: connection, body: query)
        var tags: [(id: String, title: String)] = []
        for row in response as? [[String: Any]] ?? [] {
            guard let document = row["document"] as? [String: Any],
                  let name = document["name"] as? String,
                  let fields = document["fields"] as? [String: Any] else { continue }
            if (fields["d"] as? [String: Any])?["booleanValue"] as? Bool == true { continue }
            guard let c = (fields["c"] as? [String: Any])?["stringValue"] as? String,
                  let iv = (fields["iv"] as? [String: Any])?["stringValue"] as? String,
                  let record = try? SectisFormat.decrypt(c: c, iv: iv, key: connection.key),
                  let title = record["title"] as? String else { continue }
            let id = (record["id"] as? String) ?? String(name.split(separator: "/").last ?? "")
            tags.append((id, title))
        }
        return tags
    }

    /// The ID of the tag with this title (any capitalization), made if it doesn't exist yet.
    /// Nil if that fails, so to-dos can still be sent without it.
    static func findOrCreateTag(_ title: String, _ connection: Connection) async -> String? {
        do {
            let wanted = ActionItemParser.normalize(title)
            if let existing = try await readTags(connection).first(where: { ActionItemParser.normalize($0.title) == wanted }) {
                return existing.id
            }
            let id = SectisFormat.randomID()
            let write = try createWrite(connection, id: id, kind: "tag", record: SectisFormat.tagRecord(id: id, title: title),
                                        version: Int64(Date().timeIntervalSince1970 * 1000))
            return try await createEach(connection, [write]).first == .created ? id : nil
        } catch {
            return nil
        }
    }

    // MARK: Writing

    enum WriteResult: Equatable, Sendable {
        case created
        /// Something with this ID is already there (or was deleted in Sectis): left alone.
        case exists
        case failed(String)
    }

    /// A write that creates one encrypted item, and changes nothing if the ID is already taken.
    static func createWrite(_ connection: Connection, id: String, kind: String,
                            record: [String: Any], version: Int64) throws -> [String: Any] {
        let sealed = try SectisFormat.encrypt(record, key: connection.key)
        // Exactly the fields Sectis's rules allow: k, m, d, c, iv and t.
        let fields: [String: [String: Any]] = [
            "k": ["stringValue": kind],
            "m": ["integerValue": String(version)],
            "d": ["booleanValue": false],
            "c": ["stringValue": sealed.c],
            "iv": ["stringValue": sealed.iv],
        ]
        let update: [String: Any] = ["name": "\(connection.items)/\(id)", "fields": fields]
        return [
            "update": update,
            // Sectis picks up changes in order of this server time.
            "updateTransforms": [["fieldPath": "t", "setToServerValue": "REQUEST_TIME"]],
            "currentDocument": ["exists": false],
        ]
    }

    /// Applies the writes one at a time and says what happened to each. (Each is its own
    /// commit, the call the Firebase SDK uses: Firestore keeps batch writes for admin servers,
    /// and in one commit a single item that's already there would stop all the others.)
    static func createEach(_ connection: Connection, _ writes: [[String: Any]]) async throws -> [WriteResult] {
        var results: [WriteResult] = []
        for write in writes {
            do {
                _ = try await request("\(connection.documents):commit", connection: connection, body: ["writes": [write]])
                results.append(.created)
            } catch let failure as Failure where failure.httpStatus == 409 || failure.code == "ALREADY_EXISTS" || failure.code == "FAILED_PRECONDITION" {
                results.append(.exists)
            } catch let failure as Failure where failure.httpStatus != 0 {
                results.append(.failed(failure.message))
            }
        }
        return results
    }

    // MARK: HTTP

    private static func request(_ path: String, connection: Connection, body: [String: Any], withKey: Bool = true) async throws -> Any {
        let address = connection.baseURL + path + (withKey ? "?key=\(connection.apiKey)" : "")
        guard let url = URL(string: address) else { throw Failure(message: "The Firebase project in that join code doesn't look right.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure(message: "Can't reach Firebase right now. Check the internet connection and try again.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = try? JSONSerialization.jsonObject(with: data)
        guard (200..<300).contains(status) else {
            let error = ((object as? [String: Any])?["error"] ?? (object as? [[String: Any]])?.first?["error"]) as? [String: Any]
            let message = error?["message"] as? String ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
            // A web API key limited to certain websites: Firestore works without it.
            if withKey, status == 400 || status == 403,
               ["api key", "api_key", "referer"].contains(where: { message.localizedCaseInsensitiveContains($0) }) {
                return try await self.request(path, connection: connection, body: body, withKey: false)
            }
            let code = error?["status"] as? String ?? ""
            throw Failure(message: friendlyMessage(httpStatus: status, code: code, message: message),
                          detail: "HTTP \(status) \(String(data: data.prefix(600), encoding: .utf8) ?? "")",
                          httpStatus: status, code: code)
        }
        return object ?? [String: Any]()
    }

    static func friendlyMessage(httpStatus: Int, code: String, message: String) -> String {
        if code == "PERMISSION_DENIED" || httpStatus == 403 {
            return "Your Firebase project's rules don't allow Sectis yet. Add the Sectis rules in the Firebase console (they're in Sectis's README, under Sync your Mac and iPhone)."
        }
        if code == "NOT_FOUND" || httpStatus == 404 {
            return "This Firebase project has no Firestore database yet. Create one in the Firebase console."
        }
        if code == "RESOURCE_EXHAUSTED" || httpStatus == 429 {
            return "Firebase is limiting requests right now. Try again in a minute."
        }
        if httpStatus == 401 || message.localizedCaseInsensitiveContains("api key") {
            return "Firebase didn't accept the project in that join code. \(joinCodeHelp)"
        }
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Sectis sync returned an error\(httpStatus > 0 ? " (\(httpStatus))" : "")\(detail.isEmpty ? "." : ": \(detail)")"
    }
}
