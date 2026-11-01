import Foundation
import Observation

/// Voices Sintr remembers across notes, under the names you gave them — starting with your own
/// ("Me"). Kept in Voices.json in Sintr's own folder on this device (or in the portable
/// folder); never sent anywhere, and not part of exports or shared folders.
@MainActor
@Observable
final class VoiceLibrary {
    static let shared = VoiceLibrary()

    /// Your voice first, then by name.
    private(set) var voices: [KnownVoice] = []
    var lastError: String?

    private let fileURL: URL

    init(root: URL = Storage.root) {
        fileURL = root.appendingPathComponent("Voices.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? NoteArchive.decoder.decode([KnownVoice].self, from: data) {
            voices = Self.sorted(saved.filter { !$0.samples.isEmpty })
        }
    }

    var isOn: Bool { AppSettings.shouldRecognizeVoices }

    func voice(_ id: UUID?) -> KnownVoice? {
        guard let id else { return nil }
        return voices.first { $0.id == id }
    }

    func voice(named name: String) -> KnownVoice? {
        voices.first { VoiceMatcher.sameName($0.name, name) }
    }

    /// Learns `name`'s voice from one speaker in one note: adds the sample to the voice of
    /// that name, or starts a new one. Whatever this speaker taught other voices before (a
    /// recognition you've now corrected) is taken back first.
    @discardableResult
    func remember(name: String, print: [Float], noteID: UUID, label: String, confirmed: Bool) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !print.isEmpty, !VoiceMatcher.isGenericLabel(trimmed) else { return nil }
        let sample = VoiceSample(print: print, noteID: noteID, label: label, confirmed: confirmed)
        removeSamples(noteID: noteID, label: label, except: trimmed)
        let id: UUID
        if let index = voices.firstIndex(where: { VoiceMatcher.sameName($0.name, trimmed) }) {
            voices[index] = VoiceMatcher.adding(sample, to: voices[index])
            id = voices[index].id
        } else {
            let voice = KnownVoice(name: VoiceMatcher.isMe(trimmed) ? "Me" : trimmed, samples: [sample])
            voices.append(voice)
            id = voice.id
        }
        save()
        return id
    }

    /// Takes back what one speaker in one note taught (after "Not Dana", or a new name).
    func forgetSample(noteID: UUID, label: String) {
        removeSamples(noteID: noteID, label: label, except: nil)
        save()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !VoiceMatcher.isGenericLabel(trimmed),
              let index = voices.firstIndex(where: { $0.id == id }) else { return }
        // Renamed to a name another voice already has: they're the same person.
        if let other = voices.firstIndex(where: { $0.id != id && VoiceMatcher.sameName($0.name, trimmed) }) {
            var merged = voices[other]
            for sample in voices[index].samples { merged = VoiceMatcher.adding(sample, to: merged) }
            voices[other] = merged
            voices.remove(at: index)
        } else {
            voices[index].name = VoiceMatcher.isMe(trimmed) ? "Me" : trimmed
        }
        save()
    }

    func forget(_ id: UUID) {
        voices.removeAll { $0.id == id }
        save()
    }

    func forgetAll() {
        voices = []
        save()
    }

    /// A recognized voice was heard again: keep the new sample if it was a close match.
    func reinforce(_ id: UUID, print: [Float], noteID: UUID, label: String, score: Float) {
        guard let index = voices.firstIndex(where: { $0.id == id }) else { return }
        if score >= VoiceMatcher.reinforceAbove {
            voices[index] = VoiceMatcher.adding(VoiceSample(print: print, noteID: noteID, label: label), to: voices[index])
        } else {
            voices[index].lastHeard = Date()
        }
        save()
    }

    private func removeSamples(noteID: UUID, label: String, except keepName: String?) {
        for index in voices.indices where keepName.map({ !VoiceMatcher.sameName(voices[index].name, $0) }) ?? true {
            voices[index].samples.removeAll { $0.noteID == noteID && $0.label == label }
        }
        voices.removeAll { $0.samples.isEmpty }
    }

    private func save() {
        voices = Self.sorted(voices)
        do {
            if voices.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
            } else {
                try NoteArchive.encoder.encode(voices).write(to: fileURL, options: .atomic)
            }
            lastError = nil
        } catch {
            lastError = "Couldn't save remembered voices: \(error.localizedDescription)"
        }
    }

    private static func sorted(_ list: [KnownVoice]) -> [KnownVoice] {
        list.sorted { a, b in
            if a.isMe != b.isMe { return a.isMe }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

/// Puts names on the speakers of a note whose voices Sintr remembers. Runs after speaker
/// detection, on the device; only speakers you haven't named yourself are touched.
@MainActor
enum VoiceRecognition {
    /// - Parameter prints: the voice fingerprints the speaker pass just made (label → print).
    static func apply(noteID: UUID, store: NoteStore, prints: [String: [Float]]) {
        let library = VoiceLibrary.shared
        guard library.isOn, !library.voices.isEmpty, let note = store.note(noteID) else { return }

        // Speakers still without a name of yours (or named by an earlier recognition).
        let open = prints.filter { label, _ in
            let name = note.speakerNames[label]?.trimmingCharacters(in: .whitespaces) ?? ""
            return name.isEmpty || note.recognizedVoices[label] != nil
        }
        guard !open.isEmpty else { return }
        // A name you gave another speaker in this note is taken.
        let namedElsewhere = note.speakerNames.filter { open[$0.key] == nil && note.recognizedVoices[$0.key] == nil }.values
        let taken = Set(library.voices.filter { voice in namedElsewhere.contains { VoiceMatcher.sameName($0, voice.name) } }.map(\.id))
        // On a call your microphone is already "Me", so the other side can't be you.
        let matches = VoiceMatcher.assign(open, to: library.voices, excluding: taken,
                                          allowMe: { !$0.hasPrefix("Them") })

        store.edit(noteID) { note in
            for label in open.keys where note.recognizedVoices[label] != nil && matches[label] == nil {
                // Recognized before, not any more (the voice was forgotten, or the audio changed).
                note.speakerNames[label] = nil
                note.recognizedVoices[label] = nil
            }
            for (label, match) in matches {
                guard let voice = library.voice(match.id) else { continue }
                note.speakerNames[label] = voice.name
                note.recognizedVoices[label] = voice.id
            }
        }
        for (label, match) in matches {
            if let print = open[label] {
                library.reinforce(match.id, print: print, noteID: noteID, label: label, score: match.score)
            }
        }
        ActivityLog.add("Voices: recognized \(matches.count) of \(open.count) speaker\(open.count == 1 ? "" : "s") from \(library.voices.count) remembered voice\(library.voices.count == 1 ? "" : "s")")
    }

    /// You named a speaker (or changed the name Sintr gave them): learn the voice if asked to,
    /// and take back what a wrong recognition taught.
    static func named(_ label: String, as name: String, in noteID: UUID, store: NoteStore, remember: Bool) {
        let library = VoiceLibrary.shared
        guard let note = store.note(noteID) else { return }
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = VoiceMatcher.isMe(typed) ? "Me" : typed
        let recognized = library.voice(note.recognizedVoices[label])
        store.edit(noteID) { note in
            note.speakerNames[label] = trimmed.isEmpty ? nil : trimmed
            note.recognizedVoices[label] = nil
        }
        let print = note.voicePrint(for: label)
        if remember, library.isOn, let print, !trimmed.isEmpty, !VoiceMatcher.isGenericLabel(trimmed) {
            library.remember(name: trimmed, print: print, noteID: noteID, label: label, confirmed: true)
        } else if recognized != nil {
            library.forgetSample(noteID: noteID, label: label)
        }
    }

    /// "Not Dana": the voice was recognized wrongly. The speaker goes back to its own label,
    /// and nothing this note taught Dana's voice is kept.
    static func reject(_ label: String, in noteID: UUID, store: NoteStore) {
        let library = VoiceLibrary.shared
        store.edit(noteID) { note in
            note.speakerNames[label] = nil
            note.recognizedVoices[label] = nil
        }
        library.forgetSample(noteID: noteID, label: label)
    }
}
