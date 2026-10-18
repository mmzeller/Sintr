import AVFoundation
import Foundation
import Observation
import UniformTypeIdentifiers

/// Brings files into Sintr:
/// - Sintr backups (.json) — notes come back exactly, transcript and all
/// - Markdown or text files — become a note with that text as "My notes"
/// - Audio or video files (Voice Memos, Zoom recordings…) — become a note and are transcribed on the device
@MainActor
@Observable
final class Importer {
    static let types: [UTType] = {
        var types: [UTType] = [.json, .plainText, .text, .audio, .movie, .audiovisualContent]
        if let markdown = UTType("net.daringfireball.markdown") { types.append(markdown) }
        return types
    }()

    private(set) var isWorking = false
    private(set) var status = ""
    private(set) var progress: Double = 0
    var summary: String?
    /// The note the last import created, so the UI can open it.
    private(set) var lastCreatedNote: UUID?
    /// Transcribing imported audio (and rebuilding transcripts) happens there, in the background.
    let post: PostProcessor

    init(post: PostProcessor) {
        self.post = post
    }

    func importFiles(_ urls: [URL], into store: NoteStore) async {
        isWorking = true
        defer {
            isWorking = false
            status = ""
            progress = 0
        }
        var lines: [String] = []
        for (index, url) in urls.enumerated() {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            status = "Importing \(url.lastPathComponent) (\(index + 1) of \(urls.count))…"
            do {
                lines.append(try await importOne(url, store: store))
            } catch {
                lines.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        store.saveNow()
        summary = lines.joined(separator: "\n")
    }

    private func importOne(_ url: URL, store: NoteStore) async throws -> String {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .audiovisualContent) == true || type?.conforms(to: .audio) == true {
            return try await importAudio(url, store: store)
        }
        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == "json" {
            if let setup = SetupProfile.decode(data) {
                return "\(url.lastPathComponent): \(setup.apply())"
            }
            let notes: [Note]
            if let archive = try? NoteArchive.decoder.decode(NoteArchive.self, from: data) {
                notes = archive.notes
            } else if let single = try? NoteArchive.decoder.decode(Note.self, from: data) {
                notes = [single]
            } else {
                throw ImportError.notSintrFile
            }
            let result = store.merge(notes)
            var parts: [String] = []
            if result.added > 0 { parts.append("\(result.added) added") }
            if result.updated > 0 { parts.append("\(result.updated) updated") }
            if result.skipped > 0 { parts.append("\(result.skipped) already up to date") }
            return "\(url.lastPathComponent): \(parts.isEmpty ? "no notes inside" : parts.joined(separator: ", "))."
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.unreadableText
        }
        var note = store.newNote(title: Self.title(from: text, fallback: url.deletingPathExtension().lastPathComponent))
        note.myNotes = text
        if let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate { note.created = date }
        store.update(note)
        lastCreatedNote = note.id
        return "\(url.lastPathComponent): added as “\(note.displayTitle)”."
    }

    private func importAudio(_ url: URL, store: NoteStore) async throws -> String {
        guard SpeechSupport.deviceSupported else { throw SpeechError.deviceNotSupported }
        guard let locale = await SpeechSupport.resolvedLocale() else { throw SpeechError.languageNotSupported }
        guard await SpeechSupport.isInstalled(locale) else { throw ImportError.needsSpeechModel }

        let note = store.newNote(title: url.deletingPathExtension().lastPathComponent)
        lastCreatedNote = note.id
        let name = store.newRecordingName(for: note.id, speaker: "")
        let destination = store.recordingURL(name)
        status = "Preparing \(url.lastPathComponent)…"
        try await Self.makeAudioCopy(of: url, at: destination)

        let file = try AVAudioFile(forReading: destination)
        let length = Double(file.length) / file.processingFormat.sampleRate
        store.edit(note.id) { note in
            note.recordings = [NoteRecording(fileName: destination.lastPathComponent, speaker: "", offset: 0)]
            note.duration = length
            if let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate { note.created = date }
        }
        let detect = AppSettings.shouldDetectSpeakers && SpeakerDetector.isInstalled
        post.enqueue(PostProcessor.Job(
            noteID: note.id, onlyFrom: nil, detectSpeakers: detect,
            title: "Transcribing \(url.lastPathComponent)",
            doneMessage: "“\(url.deletingPathExtension().lastPathComponent)” is transcribed.",
            deleteAfter: AppSettings.shouldKeepRecordings ? [] : [destination.lastPathComponent]), store: store)
        return "\(url.lastPathComponent): added (\(Note.durationText(length))). It's being transcribed in the background — you can keep working."
    }

    /// Copies audio as-is when it's a format the speech model reads directly,
    /// otherwise pulls the audio out into an .m4a (this also handles video files).
    static func makeAudioCopy(of source: URL, at destination: URL) async throws {
        let ext = source.pathExtension.lowercased()
        let destinationExt = destination.pathExtension.lowercased()
        if ["m4a", "wav", "caf", "aif", "aiff"].contains(ext), ext == destinationExt {
            try FileManager.default.copyItem(at: source, to: destination)
            return
        }
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ImportError.cantReadAudio
        }
        let target = destination.deletingPathExtension().appendingPathExtension("m4a")
        try await session.export(to: target, as: .m4a)
        if target != destination {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: target, to: destination)
        }
    }

    /// Rebuilds a note's transcript from its saved audio — with speaker labels when
    /// `detectSpeakers` is on (and the speaker pack is downloaded). Runs in the background.
    func rebuildTranscript(_ noteID: UUID, store: NoteStore, detectSpeakers: Bool) {
        guard let note = store.note(noteID), !note.recordings.isEmpty, !post.isBusy(with: noteID) else { return }
        let detect = detectSpeakers && SpeakerDetector.isInstalled
        post.enqueue(PostProcessor.Job(
            noteID: noteID, onlyFrom: nil, detectSpeakers: detect,
            title: detect ? "Identifying speakers" : "Rebuilding the transcript",
            doneMessage: detect
                ? "Transcript rebuilt with speaker labels. Click a speaker's name to rename them."
                : "Transcript rebuilt from the recording."), store: store)
    }

    private static func title(from text: String, fallback: String) -> String {
        let first = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        if first.hasPrefix("#") {
            return first.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        }
        return fallback
    }
}

enum ImportError: LocalizedError {
    case notSintrFile, unreadableText, cantReadAudio, needsSpeechModel

    var errorDescription: String? {
        switch self {
        case .notSintrFile: "This JSON file isn't a Sintr backup."
        case .unreadableText: "The text in this file couldn't be read."
        case .cantReadAudio: "This file's audio couldn't be read."
        case .needsSpeechModel: "Apple's speech model isn't downloaded yet. Download it in Settings → Transcription, then import again."
        }
    }
}
