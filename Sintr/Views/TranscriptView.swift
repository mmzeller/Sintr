import SwiftUI

/// The transcript, with speaker labels you can rename and tools to rebuild it from the audio.
struct TranscriptView: View {
    let noteID: UUID
    @Environment(NoteStore.self) private var store
    @Environment(Recorder.self) private var recorder
    @Environment(Importer.self) private var importer
    @Environment(PostProcessor.self) private var post
    @State private var renaming: String?
    @State private var nameDraft = ""
    @State private var askDownload = false
    @State private var downloading: Double?

    private var note: Note { store.note(noteID) ?? Note() }
    private var isRecordingHere: Bool { recorder.noteID == noteID && recorder.isRecording }
    private var busy: Bool { recorder.noteID == noteID || post.isBusy(with: noteID) || downloading != nil }

    var body: some View {
        let note = self.note
        let speakers = note.speakers
        VStack(spacing: 0) {
            if !note.transcript.isEmpty || !note.recordings.isEmpty {
                toolbar(note: note, speakers: speakers)
                Divider()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if note.transcript.isEmpty && !isRecordingHere {
                            ContentUnavailableView(
                                "No transcript yet",
                                systemImage: "waveform",
                                description: Text("Press Record and Sintr writes down what's said, on this \(Platform.deviceName)."))
                                .padding(.top, 40)
                        }
                        ForEach(note.transcript) { segment in
                            SegmentRow(
                                time: Note.clock(segment.start),
                                speaker: segment.speaker.isEmpty ? nil : note.displayName(forSpeaker: segment.speaker),
                                color: SpeakerColors.color(for: segment.speaker, in: speakers),
                                text: segment.text,
                                isLive: false,
                                rename: segment.speaker.isEmpty ? nil : { startRenaming(segment.speaker) })
                        }
                        if isRecordingHere {
                            ForEach(recorder.speakers, id: \.self) { speaker in
                                if let text = recorder.volatileText[speaker], !text.isEmpty {
                                    SegmentRow(time: "now", speaker: speaker.isEmpty ? nil : speaker,
                                               color: SpeakerColors.color(for: speaker, in: speakers),
                                               text: text, isLive: true, rename: nil)
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding()
                    .textSelection(.enabled)
                }
                .onChange(of: note.transcript.count) {
                    if isRecordingHere { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .alert("Rename \(renaming.map { note.displayName(forSpeaker: $0) } ?? "")", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $nameDraft)
            Button("Rename") { saveName() }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Every line by this speaker in this note will show the new name. Enhance uses it too.")
        }
        .alert("Download speaker detection?", isPresented: $askDownload) {
            Button("Download") { downloadThenIdentify() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Telling voices apart runs on this \(Platform.deviceName) with open models (a one-time download of a few dozen MB) from Hugging Face. Your audio is never uploaded.")
        }
    }

    private func toolbar(note: Note, speakers: [String]) -> some View {
        HStack(spacing: 14) {
            Button("Copy transcript", systemImage: "doc.on.doc") {
                Clipboard.copy(note.transcriptLines())
            }
            .disabled(note.transcript.isEmpty)
            if let downloading {
                ProgressView(value: downloading).frame(width: 120)
                Text("Downloading speaker detection…").foregroundStyle(.secondary)
            }
            Spacer()
            if !speakers.isEmpty {
                Menu {
                    ForEach(speakers, id: \.self) { speaker in
                        Button(note.displayName(forSpeaker: speaker)) { startRenaming(speaker) }
                    }
                } label: {
                    Label("Rename speakers", systemImage: "person.text.rectangle")
                }
                .fixedSize()
            }
            if !note.recordings.isEmpty {
                Menu {
                    Button("Identify speakers", systemImage: "person.2.wave.2") {
                        if SpeakerDetector.isInstalled {
                            importer.rebuildTranscript(noteID, store: store, detectSpeakers: true)
                        } else {
                            askDownload = true
                        }
                    }
                    .disabled(!SpeakerDetector.isAvailable)
                    Button("Rebuild transcript without speaker labels", systemImage: "arrow.clockwise") {
                        importer.rebuildTranscript(noteID, store: store, detectSpeakers: false)
                    }
                } label: {
                    Label("From audio", systemImage: "waveform")
                }
                .fixedSize()
                .disabled(busy)
                .help("Rebuild the transcript from the saved recording, with or without speaker labels.")
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func startRenaming(_ speaker: String) {
        nameDraft = note.speakerNames[speaker] ?? ""
        renaming = speaker
    }

    private func saveName() {
        guard let speaker = renaming else { return }
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        store.edit(noteID) { note in
            note.speakerNames[speaker] = name.isEmpty ? nil : name
        }
        renaming = nil
    }

    private func downloadThenIdentify() {
        downloading = 0
        Task {
            do {
                try await SpeakerDetector.download { value in
                    Task { @MainActor in downloading = value }
                }
                downloading = nil
                importer.rebuildTranscript(noteID, store: store, detectSpeakers: true)
            } catch {
                downloading = nil
                importer.summary = "Speaker detection didn't download: \(error.localizedDescription)"
            }
        }
    }
}

struct SegmentRow: View {
    let time: String
    let speaker: String?
    let color: Color
    let text: String
    let isLive: Bool
    let rename: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                if let speaker {
                    if let rename {
                        Button(action: rename) {
                            Text(speaker).font(.caption.weight(.bold)).foregroundStyle(color)
                        }
                        .buttonStyle(.plain)
                        .help("Rename this speaker")
                    } else {
                        Text(speaker).font(.caption.weight(.bold)).foregroundStyle(color)
                    }
                }
                Text(text)
                    .italic(isLive)
                    .foregroundStyle(isLive ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

enum SpeakerColors {
    private static let palette: [Color] = [.orange, .purple, .teal, .pink, .indigo, .brown, .mint, .cyan]

    static func color(for speaker: String, in speakers: [String]) -> Color {
        if speaker == "Me" { return .accentColor }
        let others = speakers.filter { $0 != "Me" }
        let index = others.firstIndex(of: speaker) ?? 0
        return palette[index % palette.count]
    }
}
