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
    @Environment(PostProcessor.self) private var post
    @Environment(AppState.self) private var appState
    @State private var tab: Tab = .myNotes
    @State private var confirmDeleteAudio = false

    enum Tab: String, CaseIterable, Identifiable {
        case myNotes = "My notes"
        case transcript = "Transcript"
        case enhanced = "Enhanced"
        case translations = "Translations"
        var id: String { rawValue }
    }

    private var tabs: [Tab] {
        note.translations.isEmpty ? [.myNotes, .transcript, .enhanced] : Tab.allCases
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
                ForEach(tabs) { tab in
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
            case .translations:
                TranslationsView(noteID: noteID)
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

                Button {
                    appState.translateNoteID = noteID
                } label: {
                    Label("Translate", systemImage: "translate")
                }
                .help("Translate this note into another language")
                .disabled(recorder.noteID == noteID || (note.enhanced.isEmpty && note.transcript.isEmpty && note.myNotes.isEmpty))

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
                        .disabled(recorder.noteID == noteID || post.isBusy(with: noteID))
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
        .onChange(of: note.translations.count) { old, new in
            if new > old { tab = .translations }
            if new == 0 && tab == .translations { tab = .enhanced }
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

// MARK: - Translations

private struct TranslationsView: View {
    let noteID: UUID
    @Environment(NoteStore.self) private var store
    @State private var selected: UUID?

    private var note: Note { store.note(noteID) ?? Note() }

    var body: some View {
        let translations = note.translations.sorted { $0.created > $1.created }
        let current = translations.first { $0.id == selected } ?? translations.first
        VStack(spacing: 0) {
            HStack {
                if translations.count > 1 {
                    Picker("Translation", selection: Binding(
                        get: { current?.id ?? UUID() }, set: { selected = $0 })) {
                        ForEach(translations) { item in
                            Text("\(item.languageName) — \(item.partName)").tag(item.id)
                        }
                    }
                    .fixedSize()
                } else if let current {
                    Text("\(current.languageName) — \(current.partName)").font(.callout.weight(.semibold))
                }
                if let current {
                    Text("by \(current.by)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let current {
                    Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(current.text) }
                        .labelStyle(.iconOnly)
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        store.edit(noteID) { $0.translations.removeAll { $0.id == current.id } }
                        selected = nil
                    }
                    .labelStyle(.iconOnly)
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                if let current {
                    MarkdownView(markdown: current.text)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
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
