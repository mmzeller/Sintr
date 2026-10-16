import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The bar at the bottom of a note: Record/Stop, and — like Parakeet's panel — the recording
/// options right next to it.
struct RecordBar: View {
    let noteID: UUID
    @Environment(NoteStore.self) private var store
    @Environment(Recorder.self) private var recorder
    @Environment(AppState.self) private var appState

    private var isThisNote: Bool { recorder.noteID == noteID || (recorder.noteID == nil && recorder.isActive) }

    var body: some View {
        VStack(spacing: 8) {
            if let notice = recorder.notice, isThisNote || !recorder.isActive {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(notice).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    #if os(macOS)
                    if recorder.callBlocked {
                        Button("Open Settings") { SystemAudioPermission.openSettings() }
                            .font(.callout)
                    }
                    #endif
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
            VStack(alignment: .leading, spacing: 10) {
                recordButtonRow
                RecordingOptions()
            }
        case .preparing(let message):
            if isThisNote {
                progressRow(message, value: recorder.downloadProgress)
            } else {
                elsewhere
            }
        case .recording:
            if isThisNote { recording } else { elsewhere }
        case .finishing(let message):
            if isThisNote { progressRow(message, value: recorder.progress) } else { elsewhere }
        }
    }

    private func progressRow(_ message: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ProgressView().controlSize(.small)
                Text(message).font(.callout)
                Spacer()
            }
            if value > 0 && value < 1 {
                ProgressView(value: value)
            }
        }
    }

    private var recordButtonRow: some View {
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
            Text(hint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @AppStorage(AppSettings.meetingAudio) private var meetingRaw = MeetingAudio.allAudio.rawValue

    private var hint: String {
        #if os(macOS)
        switch MeetingAudio(rawValue: meetingRaw) ?? .allAudio {
        case .off: "Records your microphone — for in-person meetings and voice notes."
        case .allAudio: "Records your microphone (“Me”) and everything your Mac plays, like the other side of a call (“Them”)."
        case .app(let id): "Records your microphone (“Me”) and \(MeetingApps.displayName(for: id)) (“Them”)."
        }
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
            #if os(macOS)
            if let status = recorder.callStatus {
                HStack(spacing: 6) {
                    Image(systemName: recorder.callBlocked ? "speaker.slash" : "speaker.wave.2")
                        .foregroundStyle(recorder.callBlocked ? .orange : .secondary)
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                    if recorder.callBlocked {
                        Button("Allow…") {
                            Task {
                                if !(await SystemAudioPermission.request()) { SystemAudioPermission.openSettings() }
                            }
                        }
                        .font(.footnote)
                    }
                }
            }
            #endif
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
        guard let note = store.note(noteID), let last = note.transcript.last else { return nil }
        return last.speaker.isEmpty ? last.text : "\(note.displayName(forSpeaker: last.speaker)): \(last.text)"
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

/// Meeting audio, speaker detection, saving audio and language — the switches Parakeet shows
/// next to its Record button.
struct RecordingOptions: View {
    @AppStorage(AppSettings.meetingAudio) private var meetingRaw = MeetingAudio.allAudio.rawValue
    @AppStorage(AppSettings.detectSpeakers) private var detectSpeakers = true
    @AppStorage(AppSettings.keepRecordings) private var saveAudio = true
    @AppStorage(AppSettings.language) private var language = ""
    @State private var locales: [Locale] = []
    #if os(macOS)
    @State private var permission = SystemAudioPermission.status
    #endif

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { items }
            VStack(alignment: .leading, spacing: 8) { items }
        }
        .font(.callout)
        .task { locales = await SpeechSupport.supportedLocales() }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permission = SystemAudioPermission.status
        }
        #endif
    }

    @ViewBuilder private var items: some View {
        #if os(macOS)
        HStack(spacing: 6) {
            MeetingAudioPicker(selection: $meetingRaw)
            if (MeetingAudio(rawValue: meetingRaw) ?? .allAudio).isOn && permission != .allowed {
                Button {
                    Task {
                        _ = await SystemAudioPermission.request()
                        permission = SystemAudioPermission.status
                    }
                } label: {
                    Label("Allow call audio…", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
                .help("macOS gives Sintr silence instead of the call until you allow it to record system audio.")
            }
        }
        #endif
        Toggle("Detect speakers", isOn: $detectSpeakers)
            .help("Label who's speaking — Me/Them on calls, Speaker 1, 2… in person. Runs on this device after you stop.")
            .modifier(OptionToggleStyle())
        Toggle("Save audio", isOn: $saveAudio)
            .help("Keep the recording with the note, so you can rebuild the transcript or detect speakers later.")
            .modifier(OptionToggleStyle())
        Picker("Language", selection: $language) {
            Text("Automatic").tag("")
            ForEach(locales, id: \.identifier) { locale in
                Text(SpeechSupport.displayName(locale)).tag(locale.identifier)
            }
        }
        .fixedSize()
    }
}

private struct OptionToggleStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.toggleStyle(.checkbox)
        #else
        content.toggleStyle(.button).buttonStyle(.bordered).controlSize(.small)
        #endif
    }
}

#if os(macOS)
/// "Meeting audio: Off / All Mac audio / one app".
struct MeetingAudioPicker: View {
    @Binding var selection: String
    var showsLabel = true

    var body: some View {
        let current = MeetingAudio(rawValue: selection) ?? .allAudio
        Menu {
            Button {
                selection = MeetingAudio.off.rawValue
            } label: {
                Label("Off — microphone only (in person)", systemImage: current == .off ? "checkmark" : "mic")
            }
            Button {
                selection = MeetingAudio.allAudio.rawValue
            } label: {
                Label("All Mac audio — any call app", systemImage: current == .allAudio ? "checkmark" : "speaker.wave.2")
            }
            Divider()
            Section("Only one app") {
                ForEach(MeetingApps.choices(including: appID(current))) { app in
                    Button {
                        selection = MeetingAudio.app(bundleID: app.bundleID).rawValue
                    } label: {
                        if appID(current) == app.bundleID {
                            Label(app.name, systemImage: "checkmark")
                        } else if let icon = MeetingApps.icon(for: app.bundleID) {
                            Label { Text(app.isRunning ? app.name : "\(app.name) (not open)") } icon: { Image(nsImage: icon) }
                        } else {
                            Text(app.name)
                        }
                    }
                }
            }
        } label: {
            Label(showsLabel ? "Meeting audio: \(title(current))" : title(current), systemImage: icon(current))
        }
        .fixedSize()
        .help("What Sintr records besides your microphone. “All Mac audio” catches FaceTime, Teams, Zoom, Meet and any other call app.")
    }

    private func appID(_ value: MeetingAudio) -> String? {
        if case .app(let id) = value { return id }
        return nil
    }

    private func title(_ value: MeetingAudio) -> String {
        switch value {
        case .off: "Off"
        case .allAudio: "All Mac audio"
        case .app(let id): MeetingApps.displayName(for: id)
        }
    }

    private func icon(_ value: MeetingAudio) -> String {
        switch value {
        case .off: "mic"
        case .allAudio: "speaker.wave.2"
        case .app: "app.badge"
        }
    }
}
#endif

struct LevelMeter: View {
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
