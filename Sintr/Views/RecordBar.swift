import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The bar at the bottom of a note: Record/Stop, live input meters, and — like Parakeet's
/// panel — the recording options right next to it.
struct RecordBar: View {
    let noteID: UUID
    @Environment(NoteStore.self) private var store
    @Environment(Recorder.self) private var recorder
    @Environment(PostProcessor.self) private var post
    @Environment(AudioHub.self) private var hub
    @Environment(AppState.self) private var appState

    private var isThisNote: Bool { recorder.noteID == noteID || (recorder.noteID == nil && recorder.isActive) }

    var body: some View {
        VStack(spacing: 8) {
            if let notice = recorder.notice, isThisNote || !recorder.isActive {
                NoticeRow(text: notice, showsSettings: recorder.callBlocked) { recorder.notice = nil }
            }
            if let notice = post.notice, !recorder.isActive {
                NoticeRow(text: notice, icon: "info.circle.fill", tint: .secondary, showsSettings: false) { post.notice = nil }
            }
            if post.isWorking, !recorder.isRecording {
                PostProcessingRow(noteID: noteID)
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
                LiveInputs()
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
            if isThisNote { progressRow(message, value: 0) } else { elsewhere }
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
            .disabled(post.isBusy(with: noteID))
            .help(post.isBusy(with: noteID) ? "Sintr is still working on this note's last recording — press Skip to record now." : "Start recording into this note")
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
            LiveInputs(recordingLabels: recorder.speakers)
            #if os(macOS)
            if recorder.callBlocked {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.slash").foregroundStyle(.orange)
                    Text("macOS is giving Sintr silence instead of the call.").font(.footnote).foregroundStyle(.secondary)
                    Button("Allow…") {
                        Task {
                            if !(await SystemAudioPermission.request()) { SystemAudioPermission.openSettings() }
                        }
                    }
                    .font(.footnote)
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

private struct NoticeRow: View {
    let text: String
    var icon = "exclamationmark.triangle.fill"
    var tint: Color = .orange
    let showsSettings: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            #if os(macOS)
            if showsSettings {
                Button("Open Settings") { SystemAudioPermission.openSettings() }
                    .font(.callout)
            }
            #endif
            Button("Dismiss", action: dismiss)
                .buttonStyle(.borderless)
                .font(.callout)
        }
    }
}

/// "Detecting speakers… [Skip]" — the background work after a recording or import.
struct PostProcessingRow: View {
    let noteID: UUID?
    @Environment(PostProcessor.self) private var post
    @Environment(NoteStore.self) private var store
    @Environment(AppState.self) private var appState

    var body: some View {
        if let job = post.current {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(job.noteID == noteID ? post.message : "\(post.message) — “\(store.note(job.noteID)?.displayTitle ?? "a note")”")
                        .font(.callout)
                        .lineLimit(1)
                    Spacer()
                    if job.noteID != noteID {
                        Button("Go to it") { appState.selection = job.noteID }
                            .buttonStyle(.borderless)
                            .font(.callout)
                    }
                    Button("Skip") { post.skip() }
                        .font(.callout)
                        .help("Stop this and keep the live transcript as it is.")
                }
                if post.progress > 0 && post.progress < 1 {
                    ProgressView(value: post.progress)
                }
            }
        }
    }
}

/// Live input meters — your microphone and, on the Mac, call audio. Shown before recording
/// (so you can check what Sintr hears) and while recording.
struct LiveInputs: View {
    /// While recording: the speaker labels in use ("Me"/"Them", or "" in person).
    var recordingLabels: [String]? = nil
    @Environment(AudioHub.self) private var hub
    @AppStorage(AppSettings.monitorLevels) private var monitor = true

    var body: some View {
        let recording = recordingLabels != nil
        if recording || hub.micRunning || hub.callState != .off {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { meters(recording: recording) }
                VStack(alignment: .leading, spacing: 6) { meters(recording: recording) }
            }
        } else if Platform.isMac, !monitor {
            Button {
                monitor = true
            } label: {
                Label("Show live input levels", systemImage: "waveform")
            }
            .buttonStyle(.borderless)
            .font(.footnote)
            .help("Keep the microphone and call-audio meters running, so you can check what Sintr hears before you record.")
        } else if !hub.micName.isEmpty {
            Label(hub.micName, systemImage: "mic.slash")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func meters(recording: Bool) -> some View {
        let labels = recordingLabels ?? []
        InputMeter(
            icon: "mic.fill",
            label: labels.contains("Me") ? "Me" : nil,
            name: hub.micName.isEmpty ? "Microphone" : hub.micName,
            level: hub.micLevel,
            status: hub.micRunning ? (hub.micHearing ? nil : "quiet") : "off",
            warning: !hub.micRunning)
        #if os(macOS)
        if hub.callState != .off {
            InputMeter(
                icon: "speaker.wave.2.fill",
                label: labels.contains("Them") ? "Them" : nil,
                name: hub.callName,
                level: hub.callLevel,
                status: callStatus,
                warning: hub.callState == .notAllowed)
        }
        #endif
    }

    private var callStatus: String? {
        switch hub.callState {
        case .off: "off"
        case .notAllowed: "not allowed"
        case .waiting(let app): "waiting for \(app)"
        case .silent: "quiet"
        case .hearing: nil
        }
    }
}

struct InputMeter: View {
    let icon: String
    let label: String?
    let name: String
    let level: Float
    let status: String?
    var warning = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(warning ? Color.orange : .secondary)
                .frame(width: 16)
            if let label {
                Text(label).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 170, alignment: .leading)
            LevelBar(level: level)
            if let status {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(warning ? Color.orange : .secondary)
            }
        }
        .help(name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label ?? name) level\(status.map { ", \($0)" } ?? "")")
    }
}

/// A horizontal level meter: green, then yellow, then red near the top.
struct LevelBar: View {
    let level: Float
    private let segments = 14

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { index in
                let lit = Float(index) / Float(segments) < level
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(lit ? color(index) : Color.secondary.opacity(0.2))
                    .frame(width: 5, height: 10)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }

    private func color(_ index: Int) -> Color {
        let position = Double(index) / Double(segments)
        return position > 0.85 ? .red : (position > 0.65 ? .yellow : .green)
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

/// Small on/off options: checkboxes on the Mac, tinted buttons on iPhone.
struct OptionToggleStyle: ViewModifier {
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
