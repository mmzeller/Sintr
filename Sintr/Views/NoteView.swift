import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct NoteView: View {
    let noteID: UUID

    @Environment(NoteStore.self) private var store
    @Environment(Recorder.self) private var recorder
    @Environment(AppState.self) private var appState
    @State private var tab: Tab = .myNotes
    @State private var confirmDeleteAudio = false

    enum Tab: String, CaseIterable, Identifiable {
        case myNotes = "My notes"
        case transcript = "Transcript"
        case enhanced = "Enhanced"
        var id: String { rawValue }
    }

    private var note: Note { store.note(noteID) ?? Note() }

    private func binding<T>(_ keyPath: WritableKeyPath<Note, T>) -> Binding<T> {
        Binding(
            get: { (store.note(noteID) ?? Note())[keyPath: keyPath] },
            set: { value in store.edit(noteID) { $0[keyPath: keyPath] = value } })
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Title", text: binding(\.title), prompt: Text("Untitled note"))
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 12)

            Picker("Show", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            switch tab {
            case .myNotes:
                MyNotesEditor(text: binding(\.myNotes))
            case .transcript:
                TranscriptView(noteID: noteID)
            case .enhanced:
                EnhancedView(noteID: noteID)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            RecordBar(noteID: noteID)
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    appState.enhanceNoteID = noteID
                } label: {
                    Label("Enhance", systemImage: "sparkles")
                }
                .help("Turn your notes and the transcript into clean notes")
                .disabled(recorder.noteID == noteID)

                Menu {
                    Button("Export…", systemImage: "square.and.arrow.up") {
                        appState.exportRequest = .init(noteID: noteID)
                    }
                    Button("Copy as Markdown", systemImage: "doc.on.doc") {
                        Clipboard.copy(Exporter.markdown(note))
                    }
                    if !note.recordings.isEmpty {
                        Divider()
                        Button("Delete recording (keep text)", systemImage: "waveform.slash", role: .destructive) {
                            confirmDeleteAudio = true
                        }
                        .disabled(recorder.noteID == noteID)
                    }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
        .confirmationDialog("Delete this note's audio?", isPresented: $confirmDeleteAudio, titleVisibility: .visible) {
            Button("Delete audio", role: .destructive) { store.deleteRecordings(of: noteID) }
        } message: {
            Text("Your notes and transcript stay. Without the audio you can't re-transcribe it later.")
        }
        .onAppear {
            if recorder.noteID != noteID, !note.enhanced.isEmpty { tab = .enhanced }
        }
        .onChange(of: note.enhancedAt) { _, newValue in
            if newValue != nil { tab = .enhanced }
        }
    }

    private var subtitle: String {
        var parts = [note.created.formatted(date: .abbreviated, time: .shortened)]
        if note.duration > 0 { parts.append(Note.durationText(note.duration)) }
        if !note.recordings.isEmpty { parts.append("audio saved") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - My notes

private struct MyNotesEditor: View {
    @Binding var text: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            if text.isEmpty {
                Text("Type your own notes here — just the key points, in your own words. Sintr listens while you record, and Enhance fills in the details from the transcript.")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Record bar

struct RecordBar: View {
    let noteID: UUID
    @Environment(NoteStore.self) private var store
    @Environment(Recorder.self) private var recorder
    @Environment(AppState.self) private var appState
    @AppStorage(AppSettings.captureCallAudio) private var captureCallAudio = true

    private var isThisNote: Bool { recorder.noteID == noteID || (recorder.noteID == nil && recorder.isActive) }

    var body: some View {
        VStack(spacing: 8) {
            if let notice = recorder.notice, isThisNote || !recorder.isActive {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(notice).font(.callout)
                    Spacer()
                    Button("Dismiss") { recorder.notice = nil }
                        .buttonStyle(.borderless)
                        .font(.callout)
                }
            }
            content
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var content: some View {
        switch recorder.phase {
        case .idle:
            idle
        case .preparing(let message):
            if isThisNote {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(message).font(.callout)
                        Spacer()
                    }
                    if recorder.downloadProgress > 0 && recorder.downloadProgress < 1 {
                        ProgressView(value: recorder.downloadProgress)
                    }
                }
            } else {
                elsewhere
            }
        case .recording:
            if isThisNote { recording } else { elsewhere }
        case .finishing:
            if isThisNote {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Finishing the transcript…").font(.callout)
                    Spacer()
                }
            } else {
                elsewhere
            }
        }
    }

    private var idle: some View {
        HStack(spacing: 14) {
            Button {
                Task { await recorder.start(noteID: noteID, store: store) }
            } label: {
                Label(store.note(noteID)?.duration ?? 0 > 0 ? "Record more" : "Record", systemImage: "record.circle")
                    .font(.title3.weight(.semibold))
                    .frame(minWidth: 140, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            Text(idleHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var idleHint: String {
        #if os(macOS)
        captureCallAudio
            ? "Records your microphone (“Me”) and your Mac's audio, like the other side of a call (“Them”). Transcribed on this Mac."
            : "Records your microphone. Transcribed on this Mac."
        #else
        "Transcribed on this iPhone. Keeps going with the screen locked."
        #endif
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                    .font(.title2)
                if let started = recorder.startedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(Note.clock(context.date.timeIntervalSince(started)))
                            .font(.title3.monospacedDigit().weight(.medium))
                    }
                }
                ForEach(recorder.speakers, id: \.self) { speaker in
                    LevelMeter(label: speaker.isEmpty ? nil : speaker, level: recorder.levels[speaker] ?? 0)
                }
                Spacer()
                Button {
                    Task { await recorder.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.title3.weight(.semibold))
                        .frame(minWidth: 100, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
            }
            if let live = liveLine {
                Text(live)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.default, value: live)
            }
        }
    }

    /// What's being said right now, or the last thing transcribed.
    private var liveLine: String? {
        for speaker in recorder.speakers {
            if let text = recorder.volatileText[speaker], !text.isEmpty {
                return speaker.isEmpty ? text : "\(speaker): \(text)"
            }
        }
        guard let last = store.note(noteID)?.transcript.last else { return nil }
        return last.speaker.isEmpty ? last.text : "\(last.speaker): \(last.text)"
    }

    private var elsewhere: some View {
        HStack {
            Image(systemName: "record.circle.fill").foregroundStyle(.red)
            Text("Recording in “\(store.note(recorder.noteID)?.displayTitle ?? "another note")”")
                .font(.callout)
            Spacer()
            if let other = recorder.noteID {
                Button("Go to it") { appState.selection = other }
            }
        }
    }
}

private struct LevelMeter: View {
    let label: String?
    let level: Float

    var body: some View {
        HStack(spacing: 5) {
            if let label {
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            HStack(spacing: 2) {
                ForEach(0..<6, id: \.self) { index in
                    Capsule()
                        .fill(Float(index) / 6 < level ? Color.green : Color.secondary.opacity(0.25))
                        .frame(width: 4, height: 6 + CGFloat(index) * 2.5)
                }
            }
            .frame(height: 20, alignment: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label ?? "Microphone") level")
    }
}

// MARK: - Transcript

private struct TranscriptView: View {
    let noteID: UUID
    @Environment(NoteStore.self) private var store
    @Environment(Recorder.self) private var recorder
    @Environment(Importer.self) private var importer

    private var note: Note { store.note(noteID) ?? Note() }
    private var isRecordingHere: Bool { recorder.noteID == noteID && recorder.isRecording }

    var body: some View {
        VStack(spacing: 0) {
            if !note.transcript.isEmpty || !note.recordings.isEmpty {
                HStack {
                    Button("Copy transcript", systemImage: "doc.on.doc") {
                        Clipboard.copy(note.transcriptLines())
                    }
                    .disabled(note.transcript.isEmpty)
                    Spacer()
                    if !note.recordings.isEmpty {
                        Button("Re-transcribe from audio", systemImage: "arrow.clockwise") {
                            Task { await importer.retranscribe(noteID, store: store) }
                        }
                        .disabled(recorder.noteID == noteID || importer.isWorking)
                        .help("Rebuilds the transcript from the saved recording — useful if live transcription stalled.")
                    }
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .padding(.horizontal)
                .padding(.vertical, 8)
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
                            SegmentRow(segment: segment)
                        }
                        if isRecordingHere {
                            ForEach(recorder.speakers, id: \.self) { speaker in
                                if let text = recorder.volatileText[speaker], !text.isEmpty {
                                    SegmentRow(segment: TranscriptSegment(speaker: speaker, start: 0, text: text), isLive: true)
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
    }
}

private struct SegmentRow: View {
    let segment: TranscriptSegment
    var isLive = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(isLive ? "now" : Note.clock(segment.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                if !segment.speaker.isEmpty {
                    Text(segment.speaker)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(segment.speaker == "Me" ? Color.accentColor : Color.orange)
                }
                Text(segment.text)
                    .italic(isLive)
                    .foregroundStyle(isLive ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Enhanced

private struct EnhancedView: View {
    let noteID: UUID
    @Environment(NoteStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(Recorder.self) private var recorder
    @State private var editing = false

    private var note: Note { store.note(noteID) ?? Note() }

    var body: some View {
        if note.enhanced.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text("No enhanced notes yet")
                    .font(.title3.weight(.semibold))
                Text("When you're done, Enhance combines what you typed with the transcript into clean notes with a summary, decisions and action items. You choose where that happens: on this \(Platform.deviceName), or by sending it to Claude.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 480)
                Button {
                    appState.enhanceNoteID = noteID
                } label: {
                    Label("Enhance notes…", systemImage: "sparkles")
                        .frame(minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(recorder.noteID == noteID)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack {
                    if !note.enhancedBy.isEmpty {
                        Label(byline, systemImage: "sparkles")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button(editing ? "Done" : "Edit") { editing.toggle() }
                    Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(note.enhanced) }
                        .labelStyle(.iconOnly)
                    Button("Redo", systemImage: "arrow.clockwise") { appState.enhanceNoteID = noteID }
                        .labelStyle(.iconOnly)
                        .help("Enhance again")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal)
                .padding(.vertical, 8)
                Divider()
                if editing {
                    TextEditor(text: Binding(
                        get: { store.note(noteID)?.enhanced ?? "" },
                        set: { value in store.edit(noteID) { $0.enhanced = value } }))
                        .font(.body.monospaced())
                        .scrollContentBackground(.hidden)
                        .padding(8)
                } else {
                    ScrollView {
                        MarkdownView(markdown: note.enhanced)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var byline: String {
        var text = note.enhancedBy
        if let date = note.enhancedAt { text += " · " + date.formatted(date: .abbreviated, time: .shortened) }
        return text
    }
}

/// Shows the Markdown the models write: headings, bullets, checkboxes and inline bold/italics.
struct MarkdownView: View {
    let markdown: String

    private enum Block: Hashable {
        case heading(Int, String)
        case bullet(Int, String)
        case task(Int, Bool, String)
        case numbered(Int, String, String)
        case paragraph(String)
        case rule
    }

    private var blocks: [Block] {
        markdown.components(separatedBy: "\n").compactMap { raw in
            let indentCount = raw.prefix { $0 == " " || $0 == "\t" }.count
            let indent = min(indentCount / 2, 4)
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            if line == "---" || line == "***" { return .rule }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                return .heading(level, line.dropFirst(level).trimmingCharacters(in: .whitespaces))
            }
            for marker in ["- [ ] ", "* [ ] "] where line.hasPrefix(marker) {
                return .task(indent, false, String(line.dropFirst(marker.count)))
            }
            for marker in ["- [x] ", "- [X] ", "* [x] "] where line.hasPrefix(marker) {
                return .task(indent, true, String(line.dropFirst(marker.count)))
            }
            for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
                return .bullet(indent, String(line.dropFirst(marker.count)))
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
               line[line.index(after: dot)...].hasPrefix(" ") {
                return .numbered(indent, String(line[..<dot]), line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces))
            }
            return .paragraph(line)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, level <= 2 ? 10 : 4)
        case .bullet(let indent, let text):
            row(indent: indent, marker: Text("•").foregroundStyle(.secondary), text: text)
        case .task(let indent, let done, let text):
            row(indent: indent,
                marker: Text(Image(systemName: done ? "checkmark.square" : "square")).foregroundStyle(.tint),
                text: text)
        case .numbered(let indent, let number, let text):
            row(indent: indent, marker: Text("\(number).").monospacedDigit().foregroundStyle(.secondary), text: text)
        case .paragraph(let text):
            inline(text)
        case .rule:
            Divider()
        }
    }

    private func row<Marker: View>(indent: Int, marker: Marker, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker.frame(minWidth: 16, alignment: .trailing)
            inline(text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(indent) * 18)
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
