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
        // Colors go by the name shown, so two labels renamed to the same person match.
        let names = speakers.map { note.displayName(forSpeaker: $0) }.reduce(into: [String]()) { list, name in
            if !list.contains(name) { list.append(name) }
        }
        let color: (String) -> Color = { speaker in
            speaker == "Me" ? .accentColor : SpeakerColors.color(for: note.displayName(forSpeaker: speaker), in: names)
        }
        VStack(spacing: 0) {
            if !note.transcript.isEmpty || !note.recordings.isEmpty {
                toolbar(note: note, speakers: speakers)
                Divider()
            }
            if let downloading {
                HStack(spacing: 10) {
                    ProgressView(value: downloading)
                    Text("Downloading speaker detection…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                Divider()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Platform.isMac ? 14 : 18) {
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
                                color: color(segment.speaker),
                                text: segment.text,
                                isLive: false,
                                rename: segment.speaker.isEmpty ? nil : { startRenaming(segment.speaker) })
                        }
                        if isRecordingHere {
                            ForEach(recorder.speakers, id: \.self) { speaker in
                                if let text = recorder.volatileText[speaker], !text.isEmpty {
                                    SegmentRow(time: "now", speaker: speaker.isEmpty ? nil : speaker,
                                               color: color(speaker),
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

    /// Copy, Rename speakers and From audio. Their names when they fit on one line, icons when
    /// they don't (a narrow iPhone, large text) — never squeezed, wrapped, or past the screen edge.
    private func toolbar(note: Note, speakers: [String]) -> some View {
        ViewThatFits(in: .horizontal) {
            toolbarRow(note: note, speakers: speakers, iconsOnly: false)
            toolbarRow(note: note, speakers: speakers, iconsOnly: true)
        }
        .padding(.horizontal)
        .padding(.vertical, Platform.isMac ? 8 : 2)
    }

    private func toolbarRow(note: Note, speakers: [String], iconsOnly: Bool) -> some View {
        HStack(spacing: iconsOnly ? 4 : 14) {
            Button("Copy transcript", systemImage: "doc.on.doc") {
                Clipboard.copy(note.transcriptLines())
            }
            .modifier(TranscriptToolLabel(iconsOnly: iconsOnly))
            .disabled(note.transcript.isEmpty)
            Spacer(minLength: iconsOnly ? 8 : 16)
            if !speakers.isEmpty {
                Menu {
                    ForEach(speakers, id: \.self) { speaker in
                        Button(note.displayName(forSpeaker: speaker)) { startRenaming(speaker) }
                    }
                } label: {
                    Label("Rename speakers", systemImage: "person.text.rectangle")
                }
                .modifier(TranscriptToolLabel(iconsOnly: iconsOnly))
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
                .modifier(TranscriptToolLabel(iconsOnly: iconsOnly))
                .disabled(busy)
                .help("Rebuild the transcript from the saved recording, with or without speaker labels.")
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
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
        #if os(macOS)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                if let speaker { speakerLabel(speaker) }
                words
            }
        }
        #else
        // iPhone: the time sits beside the speaker's name, so the words get the full width
        // instead of a column of times down the left.
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let speaker { speakerLabel(speaker) }
                Text(time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            words
        }
        #endif
    }

    @ViewBuilder private func speakerLabel(_ speaker: String) -> some View {
        if let rename {
            Button(action: rename) {
                Text(speaker).font(.caption.weight(.bold)).foregroundStyle(color)
            }
            .buttonStyle(.plain)
            .help("Rename this speaker")
            .accessibilityHint("Renames this speaker")
        } else {
            Text(speaker).font(.caption.weight(.bold)).foregroundStyle(color)
        }
    }

    private var words: some View {
        Text(text)
            .italic(isLive)
            .foregroundStyle(isLive ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A transcript toolbar button: its name and icon, or (when there isn't room) just the icon
/// with a full-size tap area. The name stays on one line either way.
private struct TranscriptToolLabel: ViewModifier {
    let iconsOnly: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if iconsOnly {
            content
                .labelStyle(.iconOnly)
                .font(.body)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        } else {
            content
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize()
                .frame(minHeight: Platform.isMac ? 0 : 44)
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
