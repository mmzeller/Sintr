import Foundation
import Observation

/// Keeps every note as its own JSON file in the app's private folder
/// (Application Support/Sintr/Notes) and recordings in Application Support/Sintr/Recordings.
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

    @ObservationIgnored private var pendingSaves: Set<UUID> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        rootFolder = support.appendingPathComponent("Sintr", isDirectory: true)
        notesFolder = rootFolder.appendingPathComponent("Notes", isDirectory: true)
        recordingsFolder = rootFolder.appendingPathComponent("Recordings", isDirectory: true)
        for folder in [rootFolder, notesFolder, recordingsFolder] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        applyBackupSetting()
        load()
    }

    // MARK: Reading

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: notesFolder, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Note] = []
        var unreadable = 0
        for file in files where file.pathExtension == "json" {
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
    }

    func note(_ id: UUID?) -> Note? {
        guard let id else { return nil }
        return notes.first { $0.id == id }
    }

    // MARK: Changing

    @discardableResult
    func newNote(title: String = "") -> Note {
        var note = Note()
        note.title = title
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
        return files.reduce(0) { total, url in
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
