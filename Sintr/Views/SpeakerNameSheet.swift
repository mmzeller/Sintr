import SwiftUI

/// A speaker label being renamed (for `.sheet(item:)`).
struct SpeakerRef: Identifiable, Hashable {
    let id: String
}

/// Names a speaker: type a name or pick one (yourself, voices Sintr remembers), and choose
/// whether Sintr should recognize this voice in future notes.
struct SpeakerNameSheet: View {
    let noteID: UUID
    let label: String

    @Environment(NoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.recognizeVoices) private var recognizeVoices = true
    @State private var name = ""
    @State private var remember = true
    @State private var loaded = false

    private var note: Note { store.note(noteID) ?? Note() }
    private var library: VoiceLibrary { VoiceLibrary.shared }

    var body: some View {
        let note = self.note
        let recognized = library.voice(note.recognizedVoices[label])
        let canRemember = recognizeVoices && note.voicePrint(for: label) != nil
        let picks = suggestions(note)
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .onSubmit(save)
                        #if os(iOS)
                        .textInputAutocapitalization(.words)
                        #endif
                    if !picks.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(picks, id: \.self) { pick in
                                    Button(VoiceMatcher.isMe(pick) ? "Me (this is you)" : pick) { name = pick }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } footer: {
                    Text("Every line by this speaker in this note shows the new name, and Enhance uses it. Name yourself “Me” so your action items are known to be yours.")
                }

                if let recognized {
                    Section {
                        Label("Sintr recognized this voice as \(recognized.name) from earlier notes.",
                              systemImage: "person.crop.circle.badge.checkmark")
                        Button("Not \(recognized.name)", role: .destructive) {
                            VoiceRecognition.reject(label, in: noteID, store: store)
                            dismiss()
                        }
                    } footer: {
                        Text("“Not \(recognized.name)” puts the speaker's own label back, and Sintr forgets what it learned about \(recognized.name)'s voice from this note.")
                    }
                }

                if canRemember {
                    Section {
                        Toggle("Recognize this voice in future notes", isOn: $remember)
                    } footer: {
                        Text("Sintr keeps a voice fingerprint — numbers that describe how the voice sounds, not a recording — on this \(Platform.deviceName) only, and puts this name on the voice when it hears it again. Settings → Speakers lists the voices it remembers.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Rename \(note.displayName(forSpeaker: label))")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = note.speakerNames[label] ?? ""
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 380)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }

    /// You, then the voices Sintr remembers — leaving out names other speakers in this note
    /// already have.
    private func suggestions(_ note: Note) -> [String] {
        let others = note.speakers.filter { $0 != label }.map { note.displayName(forSpeaker: $0) }
        let current = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [String] = []
        for candidate in ["Me"] + library.voices.map(\.name) {
            guard !others.contains(where: { VoiceMatcher.sameName($0, candidate) }),
                  !VoiceMatcher.sameName(candidate, current),
                  !result.contains(where: { VoiceMatcher.sameName($0, candidate) }) else { continue }
            result.append(candidate)
        }
        return Array(result.prefix(10))
    }

    private func save() {
        let note = self.note
        let canRemember = recognizeVoices && note.voicePrint(for: label) != nil
        VoiceRecognition.named(label, as: name, in: noteID, store: store, remember: remember && canRemember)
        dismiss()
    }
}

/// Settings → Speakers: the voices Sintr remembers, to rename or forget.
struct RememberedVoicesList: View {
    @State private var renaming: KnownVoice?
    @State private var draft = ""
    @State private var confirmForgetAll = false

    private var library: VoiceLibrary { VoiceLibrary.shared }

    var body: some View {
        let voices = library.voices
        Group {
            if voices.isEmpty {
                Text("No voices remembered yet. Name a speaker in a transcript and leave “Recognize this voice in future notes” on.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(voices) { voice in
                    HStack(spacing: 10) {
                        Image(systemName: voice.isMe ? "person.crop.circle.fill" : "person.crop.circle")
                            .foregroundStyle(voice.isMe ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(voice.isMe ? "Me (you)" : voice.name)
                            Text(detail(voice))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Rename") {
                            draft = voice.name
                            renaming = voice
                        }
                        .buttonStyle(.borderless)
                        Button("Forget", role: .destructive) { library.forget(voice.id) }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Forget all voices", role: .destructive) { confirmForgetAll = true }
            }
            if let error = library.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .alert("Rename voice", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draft)
            Button("Rename") {
                if let voice = renaming { library.rename(voice.id, to: draft) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Notes already named stay as they are; the new name is used from now on. Use a name another voice has to join the two.")
        }
        .confirmationDialog("Forget every voice Sintr remembers?", isPresented: $confirmForgetAll) {
            Button("Forget all voices", role: .destructive) { library.forgetAll() }
        } message: {
            Text("Names already in your notes stay. Sintr just won't recognize these voices any more.")
        }
    }

    private func detail(_ voice: KnownVoice) -> String {
        let samples = voice.samples.count
        return "Learned from \(samples) recording\(samples == 1 ? "" : "s") · last heard \(voice.lastHeard.formatted(date: .abbreviated, time: .omitted))"
    }
}
