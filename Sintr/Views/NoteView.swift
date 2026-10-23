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
    /// Sectis is set up, and what a note's Send to Sectis switch starts as (read once, and
    /// again when Settings change, rather than from the Keychain on every redraw).
    @State private var sectisReady = false
    @State private var sectisDefault = false
    /// Editing the enhanced notes' Markdown (Edit/Done in the toolbar).
    @State private var editingEnhanced = false

    enum Tab: String, CaseIterable, Identifiable {
        case myNotes = "My notes"
        case transcript = "Transcript"
        case enhanced = "Enhanced"
        case ask = "Ask"
        case translations = "Translations"
        var id: String { rawValue }
    }

    private var tabs: [Tab] {
        note.translations.isEmpty ? [.myNotes, .transcript, .enhanced, .ask] : Tab.allCases
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
                #if os(macOS)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        subtitleText
                        Spacer(minLength: 0)
                        sectisSwitch
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        subtitleText
                        sectisSwitch
                    }
                }
                #else
                // iPhone: the Sectis switch is on the Enhanced tab, so this stays one short line.
                subtitleText
                #endif
            }
            .padding(.horizontal)
            .padding(.top, Platform.isMac ? 12 : 4)

            Picker("Show", selection: $tab) {
                ForEach(tabs) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, Platform.isMac ? 10 : 8)

            Divider()

            switch tab {
            case .myNotes:
                MyNotesEditor(text: binding(\.myNotes))
            case .transcript:
                TranscriptView(noteID: noteID)
            case .enhanced:
                EnhancedView(noteID: noteID, editing: $editingEnhanced,
                             sectisReady: sectisReady, sectisDefault: sectisDefault)
            case .ask:
                AskView(scope: .note(noteID))
            case .translations:
                TranslationsView(noteID: noteID)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Out of the way while you edit the enhanced notes — unless you're recording.
            if !editingEnhanced || recorder.isActive {
                RecordBar(noteID: noteID)
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if tab == .enhanced, !note.enhanced.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(editingEnhanced ? "Done" : "Edit") { editingEnhanced.toggle() }
                        .fontWeight(editingEnhanced ? .semibold : .regular)
                        .help(editingEnhanced ? "Finish editing" : "Edit the enhanced notes")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    editingEnhanced = false
                    appState.enhanceNoteID = noteID
                } label: {
                    Label("Enhance", systemImage: "sparkles")
                }
                .help(note.enhanced.isEmpty ? "Turn your notes and the transcript into clean notes" : "Enhance again")
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
                    if !note.enhanced.isEmpty {
                        Button("Copy enhanced notes", systemImage: "doc.on.doc") {
                            Clipboard.copy(note.enhanced)
                        }
                    }
                    Button("Copy as Markdown", systemImage: "doc.plaintext") {
                        Clipboard.copy(Exporter.markdown(note))
                    }
                    Menu("Send to", systemImage: "paperplane") {
                        ForEach(IntegrationKind.allCases) { kind in
                            Button(kind.title + (IntegrationSettings.isConfigured(kind) ? "" : " (set up in Settings)"),
                                   systemImage: kind.systemImage) {
                                appState.sendRequest = .init(noteID: noteID, kind: kind)
                            }
                            .disabled(!IntegrationSettings.isConfigured(kind))
                        }
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
            if recorder.noteID != noteID, !note.enhanced.isEmpty || ScreenshotDemo.opensOnEnhanced { tab = .enhanced }
            refreshSectis()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sintrIntegrationsChanged)) { _ in
            refreshSectis()
        }
        .onChange(of: tab) { _, newTab in
            if newTab != .enhanced { editingEnhanced = false }
        }
        .onChange(of: note.enhancedAt) { _, newValue in
            if newValue != nil { tab = .enhanced }
        }
        .onChange(of: note.translations.count) { old, new in
            if new > old { tab = .translations }
            if new == 0 && tab == .translations { tab = .enhanced }
        }
    }

    private var subtitleText: some View {
        Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    /// Mac: this note's own switch, next to the date: whether Enhance sends your action items
    /// to Sectis. (On iPhone it's on the Enhanced tab.)
    @ViewBuilder private var sectisSwitch: some View {
        if sectisReady {
            Toggle(isOn: Binding(
                get: { Sectis.isOn(for: store.note(noteID), byDefault: sectisDefault) },
                set: { value in store.edit(noteID) { $0.sendToSectis = value } })) {
                Label("Send to Sectis", systemImage: "checklist")
            }
            .modifier(OptionToggleStyle())
            .font(.subheadline)
            .fixedSize()
            .help("After Enhance, your action items in this note go to your Sectis Inbox. Turn off to skip this meeting, or to look them over first — then use Review & send on the Enhanced tab.")
        }
    }

    private func refreshSectis() {
        sectisReady = IntegrationSettings.isConfigured(.sectis)
        sectisDefault = Sectis.isOnByDefault
    }

    /// "Oct 23, 8:52 AM · 36 min" (the year only when it isn't this year).
    private var subtitle: String {
        let thisYear = Calendar.current.isDate(note.created, equalTo: Date(), toGranularity: .year)
        var parts = [thisYear
            ? note.created.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            : note.created.formatted(date: .abbreviated, time: .shortened)]
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

/// The clean notes, with nothing above them: Edit/Done is in the toolbar, Copy is in the
/// Share menu, and who wrote them and the Sectis card follow at the end.
private struct EnhancedView: View {
    let noteID: UUID
    @Binding var editing: Bool
    let sectisReady: Bool
    let sectisDefault: Bool
    @Environment(NoteStore.self) private var store
    @Environment(AppState.self) private var appState
    @Environment(Recorder.self) private var recorder

    private var note: Note { store.note(noteID) ?? Note() }

    var body: some View {
        if note.enhanced.isEmpty {
            // Scrolls, so nothing hides behind the record bar at large text sizes.
            ScrollView {
                VStack(spacing: 14) {
                    Image(systemName: "sparkles")
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                    Text("No enhanced notes yet")
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text("Enhance turns what you typed and the transcript into clean notes: a summary, decisions and action items.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        appState.enhanceNoteID = noteID
                    } label: {
                        Label("Enhance notes…", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .disabled(recorder.noteID == noteID)
                    .padding(.top, 4)
                    #if os(iOS)
                    if sectisReady {
                        SectisCard(note: note, byDefault: sectisDefault, enhanced: false)
                            .padding(.top, 12)
                    }
                    #endif
                }
                .frame(maxWidth: 480)
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity)
            }
        } else if editing {
            TextEditor(text: Binding(
                get: { store.note(noteID)?.enhanced ?? "" },
                set: { value in store.edit(noteID) { $0.enhanced = value } }))
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(8)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    MarkdownView(markdown: note.enhanced)
                    if sectisReady {
                        SectisCard(note: note, byDefault: sectisDefault, enhanced: true)
                    }
                    if !note.enhancedBy.isEmpty {
                        Text(byline)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// "Enhanced by Apple Intelligence on this iPhone · Oct 23, 8:55 AM".
    private var byline: String {
        var text = "Enhanced by \(note.enhancedBy)"
        if let date = note.enhancedAt { text += " · " + date.formatted(date: .abbreviated, time: .shortened) }
        return text
    }
}

/// The note's Sectis card: on iPhone its Send to Sectis switch; after Enhance, how many action
/// items are yours, whether they've gone, and Review & send.
private struct SectisCard: View {
    let note: Note
    let byDefault: Bool
    /// The note has enhanced notes (so there are items to show).
    let enhanced: Bool
    @Environment(NoteStore.self) private var store
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if os(iOS)
            Toggle(isOn: Binding(
                get: { Sectis.isOn(for: store.note(note.id), byDefault: byDefault) },
                set: { value in store.edit(note.id) { $0.sendToSectis = value } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send to Sectis")
                    Text("After Enhance, your action items go to your Sectis Inbox.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            #endif
            if enhanced {
                #if os(iOS)
                Divider()
                #endif
                let count = Sectis.myItems(in: note).count
                Label(status(count), systemImage: "checklist")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Review & send…") {
                    appState.sendRequest = .init(noteID: note.id, kind: .sectis)
                }
                .buttonStyle(.bordered)
                .disabled(count == 0)
                .help("Pick which action items go to Sectis and adjust them first")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func status(_ count: Int) -> String {
        guard count > 0 else { return "No action items for you in this note" }
        let items = "\(count) action item\(count == 1 ? "" : "s") for you"
        if let sent = Sectis.lastSend(of: note) {
            return "\(items) · sent to Sectis \(sent.date.formatted(date: .abbreviated, time: .shortened))"
        }
        return "\(items) · not sent yet"
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
