import Foundation

/// A folder of notes. A shared folder lives in a place you choose — a OneDrive, Dropbox,
/// Google Drive or iCloud Drive folder, or a network share — so everyone who opens that
/// place in Sintr sees and edits the same notes. Sintr itself never uploads anything:
/// whatever syncs that place does, under your control.
struct NoteFolder: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var created = Date()
    /// Where a shared folder lives (nil for a folder kept only on this device).
    var bookmark: Data?
    var path: String?

    var isShared: Bool { bookmark != nil || path != nil }

    init(name: String) {
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Folder"
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        path = try c.decodeIfPresent(String.self, forKey: .path)
    }
}

/// The file that marks a place as a Sintr shared folder.
struct SharedFolderManifest: Codable, Sendable {
    var app = "Sintr"
    var id: UUID
    var name: String
    var created = Date()

    static let fileName = "Sintr Shared Folder.json"
}

/// File work for shared folders, done off the main thread (cloud drives and network shares
/// can be slow) and coordinated with whatever syncs the folder.
enum SharedFolderIO {
    static let queue = DispatchQueue(label: "Sintr.SharedFolders", qos: .utility)

    static func notesDirectory(in root: URL) -> URL {
        root.appendingPathComponent("Notes", isDirectory: true)
    }

    static func noteURL(_ id: UUID, in root: URL) -> URL {
        notesDirectory(in: root).appendingPathComponent("\(id.uuidString).json")
    }

    /// Opens a folder the person picked, keeping access to it for later launches.
    static func makeBookmark(for url: URL) -> Data? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The folder's location now (and keeps access open while Sintr runs).
    static func resolve(_ folder: NoteFolder) -> URL? {
        if let bookmark = folder.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
                return url
            }
        }
        if let path = folder.path, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return nil
    }

    static func readManifest(in root: URL) -> SharedFolderManifest? {
        let url = root.appendingPathComponent(SharedFolderManifest.fileName)
        guard let data = coordinatedRead(url) else { return nil }
        return try? NoteArchive.decoder.decode(SharedFolderManifest.self, from: data)
    }

    static func writeManifest(_ manifest: SharedFolderManifest, in root: URL) throws {
        try FileManager.default.createDirectory(at: notesDirectory(in: root), withIntermediateDirectories: true)
        try coordinatedWrite(try NoteArchive.encoder.encode(manifest), to: root.appendingPathComponent(SharedFolderManifest.fileName))
    }

    /// Every note in a shared folder. Nil if the folder can't be read right now.
    static func readNotes(in root: URL) -> [Note]? {
        let directory = notesDirectory(in: root)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        var notes: [Note] = []
        for name in names {
            // Cloud drives may keep a file only online until it's asked for.
            if name.hasPrefix("."), name.hasSuffix(".json.icloud") {
                let real = directory.appendingPathComponent(String(name.dropFirst().dropLast(".icloud".count)))
                try? FileManager.default.startDownloadingUbiquitousItem(at: real)
                continue
            }
            guard name.hasSuffix(".json"), !name.hasPrefix("._") else { continue }
            let url = directory.appendingPathComponent(name)
            if let data = coordinatedRead(url), let note = try? NoteArchive.decoder.decode(Note.self, from: data) {
                notes.append(note)
            }
        }
        return notes
    }

    static func coordinatedRead(_ url: URL) -> Data? {
        var result: Data?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [.withoutChanges], error: &error) { url in
            result = try? Data(contentsOf: url)
        }
        return result
    }

    static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var error: NSError?
        var thrown: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [.forReplacing], error: &error) { url in
            do { try data.write(to: url, options: .atomic) } catch { thrown = error }
        }
        if let error { throw error }
        if let thrown { throw thrown }
    }

    static func coordinatedDelete(_ url: URL) {
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [.forDeleting], error: &error) { url in
            try? FileManager.default.removeItem(at: url)
        }
    }
}

enum FolderError: LocalizedError {
    case alreadyShared(String)

    var errorDescription: String? {
        switch self {
        case .alreadyShared(let name):
            "That place already holds the shared folder “\(name)”. Use “Open Shared Folder…” to join it instead."
        }
    }
}
