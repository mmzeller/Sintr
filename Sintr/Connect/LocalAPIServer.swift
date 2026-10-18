#if os(macOS)
import Foundation
import Network
import Observation
import Security

/// A small read-only HTTP API on this Mac (127.0.0.1 only) while Sintr is open, for scripts,
/// Shortcuts, Power Automate Desktop and the like. Every request needs the token from
/// Settings → Connections. Off until you turn it on.
///
///     GET /v1/notes?folder=&since=7d&limit=20
///     GET /v1/notes/{id}?transcript=true&format=markdown
///     GET /v1/search?q=budget&limit=10
///     GET /v1/folders
@MainActor
@Observable
final class LocalAPIServer {
    private(set) var isRunning = false
    private(set) var status = "Off"

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private weak var store: NoteStore?
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?
    @ObservationIgnored private var runningPort = 0

    static var token: String {
        if let saved = SecretStore.get("local-api-token") { return saved }
        return regenerateToken()
    }

    @discardableResult
    static func regenerateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = "sintr_" + bytes.map { String(format: "%02x", $0) }.joined()
        SecretStore.set("local-api-token", token)
        return token
    }

    func attach(_ store: NoteStore) {
        self.store = store
        apply()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.apply() }
        }
    }

    /// Starts, stops or moves the server to match Settings.
    func apply() {
        let wanted = AppSettings.localAPIEnabled
        let port = AppSettings.localAPIPortNumber
        if wanted, listener != nil, port == runningPort { return }
        if !wanted, listener == nil { return }
        stop()
        if wanted { start(port: port) }
    }

    private func start(port: Int) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.update(state, port: port) }
            }
            listener.start(queue: .main)
            self.listener = listener
            runningPort = port
        } catch {
            status = "Couldn't start on port \(port): \(error.localizedDescription)"
            ActivityLog.add("Local API: \(status)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        runningPort = 0
        isRunning = false
        status = "Off"
    }

    private func update(_ state: NWListener.State, port: Int) {
        switch state {
        case .ready:
            isRunning = true
            status = "Running at http://127.0.0.1:\(port)"
            ActivityLog.add("Local API: running on port \(port)")
        case .failed(let error):
            isRunning = false
            status = "Stopped: \(error.localizedDescription)"
            ActivityLog.add("Local API: \(status)")
            listener?.cancel()
            listener = nil
            runningPort = 0
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    // MARK: Requests

    private func accept(_ connection: NWConnection) {
        // Only this Mac may talk to it.
        if case .hostPort(let host, _) = connection.endpoint {
            let text = "\(host)"
            guard text.hasPrefix("127.") || text == "::1" || text.hasPrefix("::ffff:127.") || text == "localhost" else {
                connection.cancel()
                return
            }
        }
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                var buffer = buffer
                if let data { buffer.append(data) }
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                    self?.respond(to: head, on: connection)
                } else if isComplete || error != nil || buffer.count > 65_536 {
                    connection.cancel()
                } else {
                    self?.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let (status, body, type) = route(
            method: parts.count > 0 ? String(parts[0]) : "",
            target: parts.count > 1 ? String(parts[1]) : "/",
            headers: headers)
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "OK"
        let payload = Data(body.utf8)
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type); charset=utf-8\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func route(method: String, target: String, headers: [String: String]) -> (Int, String, String) {
        let json = "application/json"
        func error(_ status: Int, _ message: String) -> (Int, String, String) {
            (status, NoteLibrary.json(["error": message]), json)
        }
        // Browsers can't use it (no CORS), and the token keeps other apps out.
        if headers["origin"] != nil { return error(403, "Requests from web pages aren't allowed.") }
        guard method == "GET" else { return error(405, "The local API is read-only (GET).") }
        guard headers["authorization"] == "Bearer \(Self.token)" else {
            return error(401, "Add the header “Authorization: Bearer <token>” — the token is in Sintr → Settings → Connections.")
        }
        guard let store else { return error(404, "Not ready.") }

        let components = URLComponents(string: "http://localhost" + target)
        let path = components?.path ?? "/"
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let notes = store.notes
        let folders = store.folders
        let segments = path.split(separator: "/").map(String.init)

        switch segments {
        case [], ["v1"]:
            return (200, NoteLibrary.json([
                "app": "Sintr",
                "endpoints": ["/v1/notes", "/v1/notes/{id}", "/v1/search?q=", "/v1/folders"],
            ]), json)
        case ["v1", "notes"]:
            if let q = query["q"], !q.isEmpty {
                return (200, NoteLibrary.json(searchResults(q, limit: Int(query["limit"] ?? "") ?? 20, notes: notes, folders: folders)), json)
            }
            let found = NoteLibrary.list(notes, folders: folders, folder: query["folder"], since: query["since"],
                                         limit: Int(query["limit"] ?? "") ?? 50)
            return (200, NoteLibrary.json(["notes": found.map { NoteLibrary.summary($0, folders: folders) }]), json)
        case ["v1", "search"]:
            let q = query["q"] ?? ""
            guard !q.isEmpty else { return error(400, "Add ?q=words to search.") }
            return (200, NoteLibrary.json(searchResults(q, limit: Int(query["limit"] ?? "") ?? 10, notes: notes, folders: folders)), json)
        case ["v1", "folders"]:
            return (200, NoteLibrary.json(["folders": folders.map { folder -> [String: Any] in
                ["id": folder.id.uuidString, "name": folder.name, "shared": folder.isShared,
                 "notes": notes.filter { $0.folderID == folder.id }.count]
            }]), json)
        case let parts where parts.count == 3 && parts[0] == "v1" && parts[1] == "notes":
            guard let note = NoteLibrary.find(notes, id: parts[2]) else { return error(404, "No note with that ID.") }
            let transcript = ["1", "true", "yes"].contains((query["transcript"] ?? "").lowercased())
            if query["format"] == "markdown" {
                return (200, NoteLibrary.markdown(note, folders: folders, includeTranscript: transcript), "text/markdown")
            }
            return (200, NoteLibrary.json(NoteLibrary.detail(note, folders: folders, includeTranscript: transcript)), json)
        default:
            return error(404, "No such endpoint. Try /v1/notes.")
        }
    }

    private func searchResults(_ q: String, limit: Int, notes: [Note], folders: [NoteFolder]) -> [String: Any] {
        let found = NoteLibrary.search(notes, index: store?.searchIndex ?? SearchIndex(), query: q, limit: limit)
        return ["query": q, "results": found.map { item -> [String: Any] in
            var summary = NoteLibrary.summary(item.note, folders: folders)
            summary["excerpts"] = item.snippets
            return summary
        }]
    }
}
#endif
