import Foundation
import Observation

/// Keeps every note as its own JSON file in Notes/ and recordings in Recordings/, inside
/// Storage.root — the app's private folder, or "Sintr Data" next to the app in portable mode.
/// Nothing here touches the network.
@MainActor
@Observable
final class NoteStore {
    /// Newest first.
    private(set) var notes: [Note] = []
    var lastError: String?

    let rootFolder: URL
    let notesFolder: URL
    let recordingsFolder: URL
    /// On-device search over every note (used by Ask, the MCP server and the local API).
    let searchIndex = SearchIndex()

    /// Folders, in the order shown.
    private(set) var folders: [NoteFolder] = []
    /// Shared folders that can't be reached right now (folder ID → why).
    private(set) var folderProblems: [UUID: String] = [:]

    @ObservationIgnored private var pendingSaves: Set<UUID> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Where each shared folder is on disk right now.
    @ObservationIgnored private var sharedRoots: [UUID: URL] = [:]
    /// The `modified` date of each shared note as last read from or written to its folder.
    @ObservationIgnored private var diskVersions: [UUID: Date] = [:]
    /// Shared notes with a write on its way.
    @ObservationIgnored private var inFlight: Set<UUID> = []
    /// Shared notes to replace with the folder's copy on the next read (after a conflict).
    @ObservationIgnored private var forceReload: Set<UUID> = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(root: URL = Storage.root) {
        rootFolder = root
        notesFolder = rootFolder.appendingPathComponent("Notes", isDirectory: true)
        recordingsFolder = rootFolder.appendingPathComponent("Recordings", isDirectory: true)
        for folder in [rootFolder, notesFolder, recordingsFolder] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        #if os(macOS)
        if !Storage.isPortable, root == Storage.standardRoot { Self.bringOverSandboxedNotes(into: root) }
        #endif
        applyBackupSetting()
        load()
    }

    #if os(macOS)
    /// The first Mac version kept its data inside a sandbox container. Copy it to the
    /// normal folder once, if there's nothing here yet. The old copy is left untouched.
    private static func bringOverSandboxedNotes(into root: URL) {
        let fm = FileManager.default
        let marker = root.appendingPathComponent(".checked-old-location")
        guard !fm.fileExists(atPath: marker.path) else { return }
        defer { fm.createFile(atPath: marker.path, contents: Data()) }
        let old = Storage.oldSandboxRoot
        let container = old.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard fm.fileExists(atPath: container.path) else { return }
        let here = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("Notes").path)) ?? []
        guard here.filter({ $0.hasSuffix(".json") }).isEmpty else { return }
        for sub in ["Notes", "Recordings"] {
            let from = old.appendingPathComponent(sub)
            let to = root.appendingPathComponent(sub)
            for name in (try? fm.contentsOfDirectory(atPath: from.path)) ?? [] {
                try? fm.copyItem(at: from.appendingPathComponent(name), to: to.appendingPathComponent(name))
            }
        }
    }
    #endif

    // MARK: Reading

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: notesFolder, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Note] = []
        var unreadable = 0
        for file in files where file.pathExtension == "json" && !Storage.isAppleDouble(file) {
            do {
                let data = try Data(contentsOf: file)
                loaded.append(try NoteArchive.decoder.decode(Note.self, from: data))
            } catch {
                unreadable += 1
            }
        }
        notes = loaded.sorted { $0.created > $1.created }
        if unreadable > 0 {
            lastError = "\(unreadable) note file(s) couldn't be read and were skipped."
        }
        loadFolders()
        refreshSharedFolders()
        startWatchingSharedFolders()
    }

    func note(_ id: UUID?) -> Note? {
        guard let id else { return nil }
        return notes.first { $0.id == id }
    }

    // MARK: Changing

    @discardableResult
    func newNote(title: String = "", folderID: UUID? = nil) -> Note {
        var note = Note()
        note.title = title
        note.folderID = folder(folderID) == nil ? nil : folderID
        notes.insert(note, at: 0)
        scheduleSave(note.id)
        return note
    }

    /// Replaces the stored copy of `note` and saves it shortly after.
    func update(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        guard notes[index] != note else { return }
        var changed = note
        changed.modified = Date()
        notes[index] = changed
        scheduleSave(note.id)
    }

    /// Changes one note in place.
    func edit(_ id: UUID, _ change: (inout Note) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        var copy = notes[index]
        change(&copy)
        update(copy)
    }

    /// Adds notes from an import. A note that already exists is replaced only if the
    /// imported copy was changed more recently.
    func merge(_ imported: [Note]) -> (added: Int, updated: Int, skipped: Int) {
        var added = 0, updated = 0, skipped = 0
        for var note in imported {
            // Recordings aren't part of a backup file, so don't point at files we don't have.
            note.recordings = note.recordings.filter {
                FileManager.default.fileExists(atPath: recordingURL($0.fileName).path)
            }
            if folder(note.folderID) == nil { note.folderID = nil }
            if let index = notes.firstIndex(where: { $0.id == note.id }) {
                if note.modified > notes[index].modified {
                    note.recordings = notes[index].recordings
                    notes[index] = note
                    scheduleSave(note.id)
                    updated += 1
                } else {
                    skipped += 1
                }
            } else {
                notes.append(note)
                scheduleSave(note.id)
                added += 1
            }
        }
        notes.sort { $0.created > $1.created }
        return (added, updated, skipped)
    }

    func delete(_ id: UUID) {
        guard let note = note(id) else { return }
        for recording in note.recordings {
            try? FileManager.default.removeItem(at: recordingURL(recording.fileName))
        }
        try? FileManager.default.removeItem(at: fileURL(for: id))
        if let folderID = note.folderID, let root = sharedRoots[folderID] {
            let url = SharedFolderIO.noteURL(id, in: root)
            SharedFolderIO.queue.async { SharedFolderIO.coordinatedDelete(url) }
        }
        diskVersions[id] = nil
        notes.removeAll { $0.id == id }
        pendingSaves.remove(id)
    }

    func deleteRecordings(of id: UUID) {
        guard let note = note(id) else { return }
        for recording in note.recordings {
            try? FileManager.default.removeItem(at: recordingURL(recording.fileName))
        }
        edit(id) { $0.recordings = [] }
    }

    // MARK: Folders

    func folder(_ id: UUID?) -> NoteFolder? {
        guard let id else { return nil }
        return folders.first { $0.id == id }
    }

    private var foldersFile: URL { rootFolder.appendingPathComponent("Folders.json") }

    private func loadFolders() {
        if let data = try? Data(contentsOf: foldersFile),
           let saved = try? NoteArchive.decoder.decode([NoteFolder].self, from: data) {
            folders = saved
        }
    }

    private func saveFolders() {
        if let data = try? NoteArchive.encoder.encode(folders) {
            try? data.write(to: foldersFile, options: .atomic)
        }
    }

    @discardableResult
    func createFolder(named name: String) -> NoteFolder {
        let folder = NoteFolder(name: name.isEmpty ? "New folder" : name)
        folders.append(folder)
        saveFolders()
        return folder
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        folders[index].name = name
        saveFolders()
        if let root = sharedRoots[id] {
            let manifest = SharedFolderManifest(id: id, name: name, created: folders[index].created)
            SharedFolderIO.queue.async { try? SharedFolderIO.writeManifest(manifest, in: root) }
        }
    }

    /// A folder on this device: its notes go back to "no folder". A shared folder: Sintr stops
    /// showing it here; the notes stay in the shared place for everyone else.
    func removeFolder(_ id: UUID) {
        guard let folder = folder(id) else { return }
        if folder.isShared {
            for note in notes where note.folderID == id { diskVersions[note.id] = nil; pendingSaves.remove(note.id) }
            notes.removeAll { $0.folderID == id }
            sharedRoots[id]?.stopAccessingSecurityScopedResource()
            sharedRoots[id] = nil
        } else {
            for index in notes.indices where notes[index].folderID == id {
                notes[index].folderID = nil
                pendingSaves.insert(notes[index].id)
            }
            scheduleSaveSoon()
        }
        folders.removeAll { $0.id == id }
        folderProblems[id] = nil
        saveFolders()
    }

    /// Moves a note into a folder (nil: out of any folder).
    func move(_ noteID: UUID, to folderID: UUID?) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }), notes[index].folderID != folderID else { return }
        let old = notes[index]
        // Leaving a shared folder: remove it there. Leaving this device: remove the local file.
        if let oldFolder = old.folderID, let root = sharedRoots[oldFolder] {
            let url = SharedFolderIO.noteURL(noteID, in: root)
            SharedFolderIO.queue.async { SharedFolderIO.coordinatedDelete(url) }
            diskVersions[noteID] = nil
        }
        if let newFolder = folder(folderID), newFolder.isShared {
            try? FileManager.default.removeItem(at: fileURL(for: noteID))
        }
        notes[index].folderID = folderID
        notes[index].modified = Date()
        pendingSaves.insert(noteID)
        scheduleSaveSoon()
    }

    /// Turns a folder on this device into a shared one at `location`, moving its notes there.
    func share(_ folderID: UUID, at location: URL) throws {
        guard let index = folders.firstIndex(where: { $0.id == folderID }), !folders[index].isShared else { return }
        let access = location.startAccessingSecurityScopedResource()
        defer { if access { location.stopAccessingSecurityScopedResource() } }
        if let existing = SharedFolderIO.readManifest(in: location), existing.id != folderID {
            throw FolderError.alreadyShared(existing.name)
        }
        try SharedFolderIO.writeManifest(SharedFolderManifest(id: folderID, name: folders[index].name, created: folders[index].created), in: location)
        folders[index].bookmark = SharedFolderIO.makeBookmark(for: location)
        folders[index].path = location.path
        saveFolders()
        sharedRoots[folderID] = SharedFolderIO.resolve(folders[index]) ?? location
        for note in notes where note.folderID == folderID {
            try? FileManager.default.removeItem(at: fileURL(for: note.id))
            pendingSaves.insert(note.id)
        }
        saveNow()
        ActivityLog.add("Shared folder created")
    }

    /// Opens a shared folder someone made (or creates one in an empty place).
    @discardableResult
    func openSharedFolder(at location: URL) throws -> NoteFolder {
        let access = location.startAccessingSecurityScopedResource()
        defer { if access { location.stopAccessingSecurityScopedResource() } }
        var folder: NoteFolder
        if let manifest = SharedFolderIO.readManifest(in: location) {
            if let existing = folders.first(where: { $0.id == manifest.id }) {
                folder = existing
            } else {
                folder = NoteFolder(name: manifest.name)
                folder.id = manifest.id
                folder.created = manifest.created
            }
        } else {
            folder = NoteFolder(name: location.lastPathComponent)
            try SharedFolderIO.writeManifest(SharedFolderManifest(id: folder.id, name: folder.name), in: location)
        }
        folder.bookmark = SharedFolderIO.makeBookmark(for: location)
        folder.path = location.path
        if let index = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[index] = folder
        } else {
            folders.append(folder)
        }
        saveFolders()
        refreshSharedFolders()
        ActivityLog.add("Shared folder opened")
        return folder
    }

    /// Where a shared folder is, for "Show in Finder".
    func sharedLocation(_ folderID: UUID) -> URL? { sharedRoots[folderID] }

    // MARK: Shared folders: keeping up to date

    private func startWatchingSharedFolders() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.refreshSharedFolders()
            }
        }
    }

    /// Reads every shared folder in the background and brings in what others changed.
    func refreshSharedFolders() {
        let shared = folders.filter(\.isShared)
        guard !shared.isEmpty else { return }
        for folder in shared where sharedRoots[folder.id] == nil {
            sharedRoots[folder.id] = SharedFolderIO.resolve(folder)
        }
        let roots = sharedRoots
        Task.detached(priority: .utility) { [weak self] in
            var results: [UUID: [Note]?] = [:]
            for folder in shared {
                results.updateValue(roots[folder.id].flatMap { SharedFolderIO.readNotes(in: $0) }, forKey: folder.id)
            }
            await self?.apply(results)
        }
    }

    private func apply(_ results: [UUID: [Note]?]) {
        var changed = false
        for (folderID, found) in results {
            guard folder(folderID) != nil else { continue }
            guard let found else {
                folderProblems[folderID] = "Can't be reached right now — check that the drive or cloud folder is available."
                continue
            }
            folderProblems[folderID] = nil
            var onDisk = Set<UUID>()
            for var incoming in found {
                incoming.folderID = folderID
                onDisk.insert(incoming.id)
                if let index = notes.firstIndex(where: { $0.id == incoming.id }) {
                    let current = notes[index]
                    let forced = forceReload.contains(incoming.id)
                    if (incoming.modified > current.modified || forced), !pendingSaves.contains(incoming.id), !inFlight.contains(incoming.id) {
                        forceReload.remove(incoming.id)
                        // Someone else changed it. Recordings are only ever on the device that made them.
                        incoming.recordings = current.recordings
                        notes[index] = incoming
                        changed = true
                    }
                } else {
                    incoming.recordings = incoming.recordings.filter {
                        FileManager.default.fileExists(atPath: recordingURL($0.fileName).path)
                    }
                    notes.append(incoming)
                    changed = true
                }
                diskVersions[incoming.id] = max(diskVersions[incoming.id] ?? .distantPast, incoming.modified)
            }
            // Notes someone else removed (that were there before, and aren't being written).
            let gone = notes.filter {
                $0.folderID == folderID && !onDisk.contains($0.id) && diskVersions[$0.id] != nil
                    && !pendingSaves.contains($0.id) && !inFlight.contains($0.id)
            }
            if !gone.isEmpty {
                let ids = Set(gone.map(\.id))
                notes.removeAll { ids.contains($0.id) }
                for id in ids { diskVersions[id] = nil }
                changed = true
            }
        }
        if changed { notes.sort { $0.created > $1.created } }
    }

    /// Saves a shared note in its folder. If someone else saved a newer version since this
    /// device last read it, theirs is kept and this version is saved next to it as a copy.
    private func writeShared(_ note: Note, folderID: UUID) {
        if sharedRoots[folderID] == nil, let folder = folder(folderID) {
            sharedRoots[folderID] = SharedFolderIO.resolve(folder)
        }
        guard let root = sharedRoots[folderID] else {
            lastError = "“\(note.displayTitle)” couldn't be saved: its shared folder can't be reached. It's kept here and saved when the folder is back."
            pendingSaves.insert(note.id)
            return
        }
        let known = diskVersions[note.id]
        inFlight.insert(note.id)
        diskVersions[note.id] = note.modified
        SharedFolderIO.queue.async { [weak self] in
            let url = SharedFolderIO.noteURL(note.id, in: root)
            var problem: String?
            var conflictCopy = false
            do {
                try FileManager.default.createDirectory(at: SharedFolderIO.notesDirectory(in: root), withIntermediateDirectories: true)
                if let known, let data = SharedFolderIO.coordinatedRead(url),
                   let onDisk = try? NoteArchive.decoder.decode(Note.self, from: data),
                   onDisk.modified.timeIntervalSince(known) > 1 {
                    var copy = note
                    copy.id = UUID()
                    copy.title = note.displayTitle + " (conflict copy)"
                    try SharedFolderIO.coordinatedWrite(try NoteArchive.encoder.encode(copy), to: SharedFolderIO.noteURL(copy.id, in: root))
                    conflictCopy = true
                } else {
                    try SharedFolderIO.coordinatedWrite(try NoteArchive.encoder.encode(note), to: url)
                }
            } catch {
                problem = error.localizedDescription
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inFlight.remove(note.id)
                if let problem {
                    self.lastError = "Couldn't save “\(note.displayTitle)” to its shared folder: \(problem)"
                    self.pendingSaves.insert(note.id)
                }
                if conflictCopy {
                    ActivityLog.add("Shared folder: saved a conflict copy")
                    self.diskVersions[note.id] = known
                    self.forceReload.insert(note.id)
                    self.refreshSharedFolders()
                }
            }
        }
    }

    private func scheduleSaveSoon() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.saveNow()
        }
    }

    // MARK: Files

    nonisolated func fileURL(for id: UUID) -> URL {
        notesFolder.appendingPathComponent("\(id.uuidString).json")
    }

    nonisolated func recordingURL(_ fileName: String) -> URL {
        recordingsFolder.appendingPathComponent(fileName)
    }

    /// A new, unused file name for a recording of `noteID`.
    func newRecordingName(for noteID: UUID, speaker: String, fileExtension: String = "m4a") -> String {
        let label = speaker.isEmpty ? "audio" : speaker.lowercased()
        var index = 1
        while true {
            let name = "\(noteID.uuidString)-\(label)-\(index).\(fileExtension)"
            if !FileManager.default.fileExists(atPath: recordingURL(name).path) { return name }
            index += 1
        }
    }

    func recordingsSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: recordingsFolder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { !Storage.isAppleDouble($0) }.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    // MARK: Saving

    private func scheduleSave(_ id: UUID) {
        pendingSaves.insert(id)
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            self?.saveNow()
        }
    }

    /// Writes every note with unsaved changes. Called automatically, and when the app goes to the background.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let ids = pendingSaves
        pendingSaves.removeAll()
        for id in ids {
            guard let note = note(id) else { continue }
            if let folderID = note.folderID, let folder = folder(folderID), folder.isShared {
                writeShared(note, folderID: folderID)
                continue
            }
            do {
                let data = try NoteArchive.encoder.encode(note)
                try data.write(to: fileURL(for: id), options: [.atomic])
            } catch {
                lastError = "Couldn't save “\(note.displayTitle)”: \(error.localizedDescription)"
                pendingSaves.insert(id)
            }
        }
    }

    /// iPhone only: keep notes out of iCloud and computer backups unless the person opts in.
    func applyBackupSetting() {
        #if os(iOS)
        var values = URLResourceValues()
        values.isExcludedFromBackup = !AppSettings.shouldIncludeInBackups
        var folder = rootFolder
        try? folder.setResourceValues(values)
        #endif
    }
}
