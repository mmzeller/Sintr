import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case markdown, plainText, backup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .markdown: "Markdown (.md)"
        case .plainText: "Plain text (.txt)"
        case .backup: "Sintr backup (.json)"
        }
    }

    var explanation: String {
        switch self {
        case .markdown: "Opens in Nextpad++, Obsidian, Notes apps and any text editor. Formatting kept."
        case .plainText: "Plain text that opens anywhere."
        case .backup: "Everything, including the timed transcript — import it into Sintr on your other device to move notes over."
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .plainText: "txt"
        case .backup: "json"
        }
    }
}

enum Exporter {
    static func markdown(_ note: Note) -> String {
        var out = "# \(note.displayTitle)\n\n"
        var meta = note.created.formatted(date: .complete, time: .shortened)
        if note.duration > 0 { meta += " · \(Note.durationText(note.duration)) recorded" }
        out += "_\(meta)_\n"
        if !note.enhanced.isEmpty {
            out += "\n## Notes\n\n"
            out += shiftHeadings(note.enhanced) + "\n"
            if !note.enhancedBy.isEmpty { out += "\n_Cleaned up by \(note.enhancedBy)._\n" }
        }
        let mine = note.myNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mine.isEmpty {
            out += "\n## My notes\n\n\(mine)\n"
        }
        if !note.transcript.isEmpty {
            out += "\n## Transcript\n\n"
            for segment in note.transcript {
                var line = "**[\(Note.clock(segment.start))]"
                if !segment.speaker.isEmpty { line += " \(segment.speaker):" }
                out += line + "** \(segment.text)\n\n"
            }
        }
        return out
    }

    static func plainText(_ note: Note) -> String {
        var out = "\(note.displayTitle)\n\(note.created.formatted(date: .complete, time: .shortened))"
        if note.duration > 0 { out += " · \(Note.durationText(note.duration)) recorded" }
        out += "\n"
        if !note.enhanced.isEmpty {
            out += "\nNOTES\n\n\(note.enhanced)\n"
        }
        let mine = note.myNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mine.isEmpty { out += "\nMY NOTES\n\n\(mine)\n" }
        if !note.transcript.isEmpty { out += "\nTRANSCRIPT\n\n\(note.transcriptLines())\n" }
        return out
    }

    static func backup(_ notes: [Note]) throws -> Data {
        try NoteArchive.encoder.encode(NoteArchive(notes: notes))
    }

    /// Writes the export to a fresh temporary folder and returns the file URLs (for sharing).
    @MainActor static func writeFiles(_ notes: [Note], format: ExportFormat, store: NoteStore, includeAudio: Bool) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sintr export \(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []

        switch format {
        case .backup:
            let name = notes.count == 1
                ? "\(safeName(notes[0].displayTitle)).sintr.json"
                : "Sintr backup \(Date().formatted(.iso8601.year().month().day())).json"
            let url = folder.appendingPathComponent(name)
            try backup(notes).write(to: url, options: .atomic)
            urls.append(url)
        case .markdown, .plainText:
            var used: Set<String> = []
            for note in notes {
                var base = "\(note.created.formatted(.iso8601.year().month().day())) \(safeName(note.displayTitle))"
                var n = 2
                while used.contains(base) { base = "\(base) \(n)"; n += 1 }
                used.insert(base)
                let text = format == .markdown ? markdown(note) : plainText(note)
                let url = folder.appendingPathComponent("\(base).\(format.fileExtension)")
                try text.write(to: url, atomically: true, encoding: .utf8)
                urls.append(url)
            }
        }

        if includeAudio {
            for note in notes {
                for recording in note.recordings {
                    let source = store.recordingURL(recording.fileName)
                    guard FileManager.default.fileExists(atPath: source.path) else { continue }
                    let label = recording.speaker.isEmpty ? "" : " (\(recording.speaker))"
                    var name = "\(safeName(note.displayTitle))\(label).\(source.pathExtension)"
                    if FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                        name = "\(safeName(note.displayTitle))\(label) \(UUID().uuidString.prefix(4)).\(source.pathExtension)"
                    }
                    let destination = folder.appendingPathComponent(name)
                    try FileManager.default.copyItem(at: source, to: destination)
                    urls.append(destination)
                }
            }
        }
        return urls
    }

    static func safeName(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = title.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(80)).isEmpty ? "Note" : String(cleaned.prefix(80))
    }

    /// Enhanced notes use "##" headings; push them down a level under the export's "## Notes".
    private static func shiftHeadings(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n").map { line in
            line.hasPrefix("#") ? "#" + line : line
        }.joined(separator: "\n")
    }
}

/// Lets SwiftUI's save panel write a single file or a whole folder of exported files.
struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] { [.data, .folder, .json, .plainText] }

    let urls: [URL]
    let folderName: String

    init(urls: [URL], folderName: String) {
        self.urls = urls
        self.folderName = folderName
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    var contentType: UTType {
        guard urls.count == 1, let url = urls.first else { return .folder }
        return UTType(filenameExtension: url.pathExtension) ?? .data
    }

    var defaultFilename: String {
        urls.count == 1 ? (urls.first?.lastPathComponent ?? "Sintr export") : folderName
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        if urls.count == 1, let url = urls.first {
            return try FileWrapper(url: url, options: .immediate)
        }
        var children: [String: FileWrapper] = [:]
        for url in urls {
            let wrapper = try FileWrapper(url: url, options: .immediate)
            wrapper.preferredFilename = url.lastPathComponent
            children[url.lastPathComponent] = wrapper
        }
        let folder = FileWrapper(directoryWithFileWrappers: children)
        folder.preferredFilename = folderName
        return folder
    }
}
