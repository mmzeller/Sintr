#if os(macOS)
import Foundation

/// `Sintr --mcp`: a Model Context Protocol server over standard input/output, so AI apps on
/// this Mac (Claude Desktop, Claude Code, and others that speak MCP) can search and read
/// your notes. It runs only while an AI app runs it, it's read-only, and it answers only when
/// Settings → Connections → "Let AI apps read my notes" is on. Nothing goes over the network
/// from Sintr; what the AI app does with an answer is up to that app.
enum MCPServer {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--mcp") else { return }
        run()
        exit(0)
    }

    private static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private static func run() {
        var library: (notes: [Note], folders: [NoteFolder])?
        var loadedAt = Date.distantPast
        let index = SearchIndex()
        func current() -> (notes: [Note], folders: [NoteFolder]) {
            // Re-read now and then, so new notes show up during a long AI session.
            if library == nil || Date().timeIntervalSince(loadedAt) > 20 {
                library = NoteLibrary.loadFromDisk()
                loadedAt = Date()
            }
            return library!
        }

        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  let data = line.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data)
            else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            if let batch = parsed as? [[String: Any]] {
                let replies = batch.compactMap { handle($0, library: current, index: index) }
                if !replies.isEmpty { sendArray(replies) }
            } else if let message = parsed as? [String: Any], let reply = handle(message, library: current, index: index) {
                send(reply)
            }
        }
    }

    private static func handle(_ message: [String: Any], library: () -> (notes: [Note], folders: [NoteFolder]),
                               index: SearchIndex) -> [String: Any]? {
        guard let method = message["method"] as? String else { return nil }  // A response to us: ignore.
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]
        guard id != nil else { return nil }  // Notifications get no reply.

        func result(_ value: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id!, "result": value] }
        func error(_ code: Int, _ text: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id!, "error": ["code": code, "message": text]]
        }

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? supportedVersions[0]
            let version = supportedVersions.contains(asked) ? asked : supportedVersions[0]
            let client = (params["clientInfo"] as? [String: Any])?["name"] as? String ?? "an AI app"
            ActivityLog.add("MCP: \(client) connected")
            return result([
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "sintr", "title": "Sintr notes", "version": appVersion],
                "instructions": "Sintr holds the user's meeting notes: their own notes, AI-enhanced notes and transcripts. Use search_notes to find meetings about a topic, list_notes for recent meetings or a date range, and get_note for the full note (add include_transcript for exact wording). Cite notes by title and date.",
            ])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard AppSettings.aiAppsAllowed else {
                return result(toolResult("Sintr isn't sharing notes with AI apps right now. The person can turn this on in Sintr → Settings → Connections → “Let AI apps read my notes”.", isError: true))
            }
            return result(call(name, arguments, library: library(), index: index))
        case "resources/list":
            return result(["resources": []])
        case "prompts/list":
            return result(["prompts": []])
        default:
            return error(-32601, "Method not found: \(method)")
        }
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
    }

    private static let tools: [[String: Any]] = [
        [
            "name": "search_notes",
            "title": "Search notes",
            "description": "Search the user's meeting notes and transcripts. Returns the best-matching notes with short excerpts and their IDs.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Words to look for — topics, names, projects."],
                    "limit": ["type": "integer", "description": "Most notes to return (default 8)."],
                ],
                "required": ["query"],
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "list_notes",
            "title": "List notes",
            "description": "List the user's notes, newest first, optionally only in one folder or since a date.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "folder": ["type": "string", "description": "Folder name."],
                    "since": ["type": "string", "description": "A date like 2026-10-01, or 7d / 2w / 3m, or today / yesterday."],
                    "limit": ["type": "integer", "description": "Most notes to return (default 20)."],
                ],
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "get_note",
            "title": "Get a note",
            "description": "Get one note in full: the user's own notes, the enhanced notes, and optionally the timed transcript.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The note's ID from search_notes or list_notes."],
                    "include_transcript": ["type": "boolean", "description": "Include the full transcript (can be long)."],
                ],
                "required": ["id"],
            ],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "list_folders",
            "title": "List folders",
            "description": "List the user's note folders and how many notes each holds.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
    ]

    private static func call(_ name: String, _ arguments: [String: Any], library: (notes: [Note], folders: [NoteFolder]),
                             index: SearchIndex) -> [String: Any] {
        let (notes, folders) = library
        switch name {
        case "search_notes":
            let query = arguments["query"] as? String ?? ""
            let limit = arguments["limit"] as? Int ?? 8
            let found = NoteLibrary.search(notes, index: index, query: query, limit: limit)
            guard !found.isEmpty else { return toolResult("No notes match “\(query)”.") }
            let text = found.map { item in
                ([NoteLibrary.line(item.note, folders: folders)] + item.snippets.map { "    " + $0.replacingOccurrences(of: "\n", with: " ") })
                    .joined(separator: "\n")
            }.joined(separator: "\n\n")
            return toolResult(text)
        case "list_notes":
            let found = NoteLibrary.list(notes, folders: folders, folder: arguments["folder"] as? String,
                                         since: arguments["since"] as? String, limit: arguments["limit"] as? Int ?? 20)
            guard !found.isEmpty else { return toolResult("No notes found.") }
            return toolResult(found.map { NoteLibrary.line($0, folders: folders) }.joined(separator: "\n"))
        case "get_note":
            guard let note = NoteLibrary.find(notes, id: arguments["id"] as? String ?? "") else {
                return toolResult("No note with that ID. Use search_notes or list_notes to find IDs.", isError: true)
            }
            let transcript = arguments["include_transcript"] as? Bool ?? false
            return toolResult(NoteLibrary.markdown(note, folders: folders, includeTranscript: transcript))
        case "list_folders":
            guard !folders.isEmpty else { return toolResult("No folders. \(notes.count) notes in total.") }
            let text = folders.map { folder in
                "\(folder.name)\(folder.isShared ? " (shared)" : ""): \(notes.filter { $0.folderID == folder.id }.count) notes"
            }.joined(separator: "\n")
            return toolResult(text + "\nAll notes: \(notes.count)")
        default:
            return toolResult("Unknown tool \(name).", isError: true)
        }
    }

    private static func toolResult(_ text: String, isError: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private static func send(_ object: [String: Any]) {
        write(object)
    }

    private static func sendArray(_ objects: [[String: Any]]) {
        write(objects)
    }

    private static func write(_ object: Any) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}

/// `Sintr --cli …`: read notes from Terminal or a script.
enum SintrCommandLine {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let start = arguments.firstIndex(of: "--cli") else { return }
        let words = Array(arguments[(start + 1)...])
        let code = run(words)
        exit(code)
    }

    private static func run(_ words: [String]) -> Int32 {
        let command = words.first ?? "help"
        var rest = Array(words.dropFirst())
        func option(_ name: String) -> String? {
            guard let index = rest.firstIndex(of: name), index + 1 < rest.count else { return nil }
            let value = rest[index + 1]
            rest.removeSubrange(index...(index + 1))
            return value
        }
        func flag(_ name: String) -> Bool {
            guard let index = rest.firstIndex(of: name) else { return false }
            rest.remove(at: index)
            return true
        }
        let asJSON = flag("--json")
        let (notes, folders) = NoteLibrary.loadFromDisk()

        switch command {
        case "list":
            let folder = option("--folder")
            let since = option("--since")
            let limit = option("--limit").flatMap(Int.init) ?? 20
            let found = NoteLibrary.list(notes, folders: folders, folder: folder, since: since, limit: limit)
            print(asJSON ? NoteLibrary.json(found.map { NoteLibrary.summary($0, folders: folders) })
                         : found.map { NoteLibrary.line($0, folders: folders) }.joined(separator: "\n"))
        case "search":
            let limit = option("--limit").flatMap(Int.init) ?? 10
            let query = rest.joined(separator: " ")
            guard !query.isEmpty else { printError("Usage: --cli search <words> [--limit N] [--json]"); return 2 }
            let found = NoteLibrary.search(notes, index: SearchIndex(), query: query, limit: limit)
            if asJSON {
                print(NoteLibrary.json(found.map { item -> [String: Any] in
                    var summary = NoteLibrary.summary(item.note, folders: folders)
                    summary["excerpts"] = item.snippets
                    return summary
                }))
            } else {
                print(found.map { item in
                    ([NoteLibrary.line(item.note, folders: folders)] + item.snippets.map { "    " + $0.replacingOccurrences(of: "\n", with: " ") })
                        .joined(separator: "\n")
                }.joined(separator: "\n\n"))
            }
        case "get":
            let transcript = flag("--transcript")
            guard let id = rest.first, let note = NoteLibrary.find(notes, id: id) else {
                printError("No note with that ID. Usage: --cli get <id> [--transcript] [--json]")
                return 1
            }
            print(asJSON ? NoteLibrary.json(NoteLibrary.detail(note, folders: folders, includeTranscript: transcript))
                         : NoteLibrary.markdown(note, folders: folders, includeTranscript: transcript))
        case "folders":
            if asJSON {
                print(NoteLibrary.json(folders.map { folder -> [String: Any] in
                    ["id": folder.id.uuidString, "name": folder.name, "shared": folder.isShared,
                     "notes": notes.filter { $0.folderID == folder.id }.count]
                }))
            } else {
                print(folders.isEmpty ? "No folders." : folders.map {
                    "\($0.name)\($0.isShared ? " (shared)" : "")"
                }.joined(separator: "\n"))
            }
        default:
            print("""
                Sintr command line — reads your notes on this Mac.

                  --cli list [--folder NAME] [--since 7d|2026-10-01] [--limit N] [--json]
                  --cli search WORDS… [--limit N] [--json]
                  --cli get ID [--transcript] [--json]
                  --cli folders [--json]

                IDs can be shortened to their first few characters.
                """)
        }
        return 0
    }

    private static func printError(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
#endif
