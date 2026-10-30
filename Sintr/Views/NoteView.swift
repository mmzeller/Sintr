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
    #if os(iOS)
    @FocusState private var titleFocused: Bool
    #endif

    enum Tab: String, CaseIterable, Identifiable {
        case myNotes = "My notes"
        case transcript = "Transcript"
        case enhanced = "Enhanced"
        case ask = "Ask"
        case translations = "Translations"
        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .myNotes: "square.and.pencil"
            case .transcript: "text.quote"
            case .enhanced: "sparkles"
            case .ask: "bubble.left.and.text.bubble.right"
            case .translations: "translate"
            }
        }
    }

    /// The tab to open on instead of the usual one (the iPhone layout check measures each).
    private let initialTab: Tab?

    init(noteID: UUID, initialTab: Tab? = nil) {
        self.noteID = noteID
        self.initialTab = initialTab
        _tab = State(initialValue: initialTab ?? .myNotes)
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

    #if os(iOS)
    /// The title on one line of text even though the field wraps: Return (a new line) ends editing.
    private var titleBinding: Binding<String> {
        Binding(
            get: { store.note(noteID)?.title ?? "" },
            set: { value in
                if value.contains(where: \.isNewline) {
                    let flat = value.split(whereSeparator: \.isNewline).joined(separator: " ")
                    store.edit(noteID) { $0.title = flat }
                    titleFocused = false
                } else {
                    store.edit(noteID) { $0.title = value }
                }
            })
    }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                #if os(macOS)
                TextField("Title", text: binding(\.title), prompt: Text("Untitled note"))
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)
                #else
                // Long titles wrap instead of scrolling sideways; Return finishes editing.
                TextField("Title", text: titleBinding, prompt: Text("Untitled note"), axis: .vertical)
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .submitLabel(.done)
                    .focused($titleFocused)
                #endif
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

            #if os(macOS)
            Picker("Show", selection: $tab) {
                ForEach(tabs) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 10)
            #else
            NoteTabBar(tabs: tabs, selection: $tab)
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 8)
            #endif

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
            if let demoTab = ScreenshotDemo.openingTab {
                tab = demoTab
            } else if initialTab == nil, recorder.noteID != noteID, !note.enhanced.isEmpty {
                tab = .enhanced
            }
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
            HStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { Sectis.isOn(for: store.note(noteID), byDefault: sectisDefault) },
                    set: { value in store.edit(noteID) { $0.sendToSectis = value } })) {
                    Label("Send to Sectis", systemImage: "checklist")
                }
                .modifier(OptionToggleStyle())
                .fixedSize()
                .help("After Enhance, your action items in this note go to Sectis, and other people's to its Waiting For. Turn off to skip this meeting, or to look them over first — then use Review & send on the Enhanced tab.")
                // Where they go: the Inbox, or a project or area.
                if Sectis.isOn(for: store.note(noteID), byDefault: sectisDefault) {
                    SectisPlacePicker(noteID: noteID, compact: true)
                        .menuStyle(.button)
                        .buttonStyle(.borderless)
                        .fixedSize()
                }
            }
            .font(.subheadline)
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

#if os(iOS)
// MARK: - Tabs (iPhone)

/// iPhone: the note's tabs. A segmented picker needs about 390 points for four tabs and never
/// gets narrower, so with Display Zoom (a 320-point screen) it pushed the whole note screen
/// wider than the phone. This bar always fits: every tab's name when there's room, then the open
/// tab's name with icons for the others, then icons only.
struct NoteTabBar: View {
    let tabs: [NoteView.Tab]
    @Binding var selection: NoteView.Tab

    private enum Style { case name, icon, both }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar { _ in .name }
            bar { $0 == selection ? .both : .icon }
            bar { _ in .icon }
        }
        // Grows with larger text, up to a point: past that the names give way to icons sooner.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show")
    }

    private func bar(_ style: @escaping (NoteView.Tab) -> Style) -> some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                segment(tab, style: style(tab))
            }
        }
        .padding(3)
        .background(Self.track, in: Capsule())
    }

    private func segment(_ tab: NoteView.Tab, style: Style) -> some View {
        let selected = tab == selection
        return Button {
            withAnimation(.snappy(duration: 0.22)) { selection = tab }
        } label: {
            HStack(spacing: 5) {
                if style != .name { Image(systemName: tab.systemImage) }
                if style != .icon { Text(tab.rawValue) }
            }
            .font(.subheadline.weight(selected ? .semibold : .medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background {
                if selected {
                    Capsule()
                        .fill(Self.thumb)
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private static let track = Color(uiColor: .tertiarySystemFill)
    private static let thumb = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.36, alpha: 1) : .white
    })
}
#endif

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
            .defaultScrollAnchor(ScreenshotDemo.scrollsToEnd ? .bottom : .top)
        }
    }

    /// "Enhanced by Apple Intelligence on this iPhone · Oct 23, 8:55 AM".
    private var byline: String {
        var text = "Enhanced by \(note.enhancedBy)"
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
            #if os(iOS)
            phoneHeader(translations: translations, current: current)
            #else
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
            #endif
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

    #if os(iOS)
    /// iPhone: which translation (a menu when there are several) and who wrote it, stacked so a
    /// long language and part name never pushes the Copy and Delete buttons off the screen.
    private func phoneHeader(translations: [NoteTranslation], current: NoteTranslation?) -> some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                if let current {
                    if translations.count > 1 {
                        Menu {
                            Picker("Translation", selection: Binding(
                                get: { current.id }, set: { selected = $0 })) {
                                ForEach(translations) { item in
                                    Text("\(item.languageName) — \(item.partName)").tag(item.id)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("\(current.languageName) — \(current.partName)")
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2.weight(.semibold))
                            }
                            .font(.callout.weight(.semibold))
                        }
                    } else {
                        Text("\(current.languageName) — \(current.partName)")
                            .font(.callout.weight(.semibold))
                            .lineLimit(2)
                    }
                    Text("by \(current.by)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let current {
                Button("Copy", systemImage: "doc.on.doc") { Clipboard.copy(current.text) }
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                Button("Delete", systemImage: "trash", role: .destructive) {
                    store.edit(noteID) { $0.translations.removeAll { $0.id == current.id } }
                    selected = nil
                }
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.borderless)
        .padding(.leading)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
    }
    #endif
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
