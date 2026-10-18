import Foundation

/// Read-only access to notes for the MCP server, the command line and the local API — the
/// same answers in the same shape from all three.
enum NoteLibrary {
    /// Reads every note from disk (this device's and shared folders'), for the MCP server and
    /// command line, which run without the app's window.
    static func loadFromDisk() -> (notes: [Note], folders: [NoteFolder]) {
        let root = Storage.root
        var folders: [NoteFolder] = []
        if let data = try? Data(contentsOf: root.appendingPathComponent("Folders.json")),
           let saved = try? NoteArchive.decoder.decode([NoteFolder].self, from: data) {
            folders = saved
        }
        var notes: [Note] = []
        let notesFolder = root.appendingPathComponent("Notes", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: notesFolder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" && !Storage.isAppleDouble(file) {
            if let data = try? Data(contentsOf: file), let note = try? NoteArchive.decoder.decode(Note.self, from: data) {
                notes.append(note)
            }
        }
        for folder in folders where folder.isShared {
            guard let location = SharedFolderIO.resolve(folder), let shared = SharedFolderIO.readNotes(in: location) else { continue }
            for var note in shared where !notes.contains(where: { $0.id == note.id }) {
                note.folderID = folder.id
                notes.append(note)
            }
        }
        return (notes.sorted { $0.created > $1.created }, folders)
    }

    // MARK: Queries

    static func list(_ notes: [Note], folders: [NoteFolder], folder: String?, since: String?, limit: Int) -> [Note] {
        var result = notes
        if let folder, !folder.isEmpty {
            let wanted = folders.filter { $0.name.localizedCaseInsensitiveCompare(folder) == .orderedSame || $0.id.uuidString == folder }
            let ids = Set(wanted.map(\.id))
            result = result.filter { $0.folderID.map(ids.contains) ?? false }
        }
        if let since, let date = parseSince(since) {
            result = result.filter { $0.created >= date }
        }
        return Array(result.sorted { $0.created > $1.created }.prefix(max(1, min(limit, 500))))
    }

    static func search(_ notes: [Note], index: SearchIndex, query: String, limit: Int) -> [(note: Note, snippets: [String])] {
        index.update(notes)
        var order: [UUID] = []
        var snippets: [UUID: [String]] = [:]
        for (passage, _) in index.search(query, limit: max(limit * 4, 20)) {
            if snippets[passage.noteID] == nil { order.append(passage.noteID) }
            if (snippets[passage.noteID]?.count ?? 0) < 2 {
                snippets[passage.noteID, default: []].append("(\(passage.part)) " + String(passage.text.prefix(400)))
            }
        }
        return order.prefix(max(1, min(limit, 100))).compactMap { id in
            notes.first { $0.id == id }.map { ($0, snippets[id] ?? []) }
        }
    }

    static func find(_ notes: [Note], id: String) -> Note? {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        if let uuid = UUID(uuidString: trimmed) { return notes.first { $0.id == uuid } }
        // Allow the start of an ID, as printed by the command line.
        let matches = notes.filter { $0.id.uuidString.lowercased().hasPrefix(trimmed.lowercased()) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// "2026-10-01", "7d", "2w", "3m", "today", "yesterday".
    static func parseSince(_ text: String) -> Date? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        let calendar = Calendar.current
        if value == "today" { return calendar.startOfDay(for: Date()) }
        if value == "yesterday" { return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date())) }
        if let match = value.wholeMatch(of: #/(\d{1,4})([dwm])/#), let count = Int(match.1) {
            let unit: Calendar.Component = match.2 == "d" ? .day : (match.2 == "w" ? .weekOfYear : .month)
            return calendar.date(byAdding: unit, value: -count, to: Date())
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        if let date = formatter.date(from: String(value.prefix(10))) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    // MARK: Shapes

    private static let iso = ISO8601DateFormatter()

    static func summary(_ note: Note, folders: [NoteFolder]) -> [String: Any] {
        var item: [String: Any] = [
            "id": note.id.uuidString,
            "title": note.displayTitle,
            "created": iso.string(from: note.created),
            "modified": iso.string(from: note.modified),
            "duration_seconds": Int(note.duration),
            "has_enhanced_notes": !note.enhanced.isEmpty,
            "has_transcript": !note.transcript.isEmpty,
            "preview": String(note.preview.prefix(200)),
        ]
        if let folder = folders.first(where: { $0.id == note.folderID }) {
            item["folder"] = ["id": folder.id.uuidString, "name": folder.name, "shared": folder.isShared]
        }
        return item
    }

    static func detail(_ note: Note, folders: [NoteFolder], includeTranscript: Bool) -> [String: Any] {
        var item = summary(note, folders: folders)
        item["my_notes"] = note.myNotes
        item["enhanced_notes"] = note.enhanced
        item["enhanced_by"] = note.enhancedBy
        item["speakers"] = note.speakers.map { note.displayName(forSpeaker: $0) }
        if includeTranscript {
            item["transcript"] = note.transcript.map {
                ["start_seconds": $0.start, "time": Note.clock($0.start),
                 "speaker": $0.speaker.isEmpty ? "" : note.displayName(forSpeaker: $0.speaker), "text": $0.text]
            }
        }
        return item
    }

    /// The note as Markdown, for AI apps and the command line.
    static func markdown(_ note: Note, folders: [NoteFolder], includeTranscript: Bool) -> String {
        var lines = ["# \(note.displayTitle)", "",
                     "- ID: \(note.id.uuidString)",
                     "- Date: \(note.created.formatted(date: .complete, time: .shortened))"]
        if note.duration > 0 { lines.append("- Length: \(Note.durationText(note.duration))") }
        if let folder = folders.first(where: { $0.id == note.folderID }) { lines.append("- Folder: \(folder.name)") }
        let speakers = note.speakers.map { note.displayName(forSpeaker: $0) }
        if !speakers.isEmpty { lines.append("- Speakers: \(speakers.joined(separator: ", "))") }
        if !note.myNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines += ["", "## My notes", "", note.myNotes]
        }
        if !note.enhanced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines += ["", "## Enhanced notes", "", note.enhanced]
        }
        if includeTranscript, !note.transcript.isEmpty {
            lines += ["", "## Transcript", "", note.transcriptLines()]
        } else if !note.transcript.isEmpty {
            lines += ["", "(Transcript available: \(note.transcript.count) lines — ask for it with include_transcript.)"]
        }
        return lines.joined(separator: "\n")
    }

    static func line(_ note: Note, folders: [NoteFolder]) -> String {
        var text = "\(note.id.uuidString)  \(note.created.formatted(date: .abbreviated, time: .shortened))  \(note.displayTitle)"
        if let folder = folders.first(where: { $0.id == note.folderID }) { text += "  [\(folder.name)]" }
        return text
    }

    static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}
