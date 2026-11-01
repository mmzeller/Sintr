#if os(macOS)
import AppKit
import Observation
import SwiftUI

/// Mac: notices when a call starts (Zoom, Teams, FaceTime, Slack, a call in the browser…) and
/// offers to take notes in a small panel at the top of the screen; while a call is being
/// recorded, notices when it ends and offers to stop. Nothing is recorded until you press
/// Take notes, and nothing stops without a countdown you can cancel.
@MainActor
@Observable
final class MeetingWatcher {
    /// Why a recording is about to stop by itself.
    enum Ending: Equatable {
        case goodbye(stopAt: Date)
        case quiet(stopAt: Date)

        var stopAt: Date {
            switch self {
            case .goodbye(let date), .quiet(let date): date
            }
        }
    }

    /// The call to offer notes for.
    private(set) var offer: CallApp?
    /// A countdown to stopping the recording.
    private(set) var ending: Ending?
    /// The call the current recording belongs to.
    private(set) var recordingCall: CallApp?

    private let store: NoteStore
    private let recorder: Recorder
    private let appState: AppState
    private let hub: AudioHub
    @ObservationIgnored private var detection = MeetingDetection()
    @ObservationIgnored private var watcher: MicUseWatcher?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var panel: MeetingPanel?
    /// "Keep recording" after goodbyes: don't ask again until the call comes back.
    @ObservationIgnored private var keptAfterGoodbye = false
    /// Quiet is counted from here (the end of the call, or the last "Keep recording").
    @ObservationIgnored private var quietFrom: Date?
    @ObservationIgnored private var lastLoggedApps: Set<String> = []

    init(store: NoteStore, recorder: Recorder, appState: AppState, hub: AudioHub) {
        self.store = store
        self.recorder = recorder
        self.appState = appState
        self.hub = hub
    }

    /// Starts watching (once). Cheap: Core Audio tells Sintr when something changes.
    func start() {
        guard watcher == nil else { return }
        let watcher = MicUseWatcher { [weak self] users in
            Task { @MainActor [weak self] in self?.micUsersChanged(users) }
        }
        self.watcher = watcher
        watcher.start()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    // MARK: What the panel's buttons do

    func takeNotes(_ app: CallApp) {
        offer = nil
        detection.dismiss(app.bundleID)
        guard !recorder.isActive else { return }
        let note = store.newNote(title: app.title)
        appState.selection = note.id
        recordingCall = app
        // Record this call's audio even if Meeting audio is off (that's for in-person meetings).
        let setting = AppSettings.meetingAudioChoice
        let meeting = setting.isOn ? setting : MeetingAudio.app(bundleID: app.bundleID)
        ActivityLog.add("Meeting detection: taking notes for a \(app.name) call")
        updatePanel()
        Task {
            await recorder.start(noteID: note.id, store: store, meeting: meeting)
            // Sintr needs to ask something first (a download, a permission) or couldn't start:
            // bring its window forward so you see why.
            if !recorder.isRecording {
                NSApp.activate()
                NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "Sintr" }?.makeKeyAndOrderFront(nil)
            }
        }
    }

    func notNow(_ app: CallApp) {
        detection.dismiss(app.bundleID)
        offer = nil
        updatePanel()
    }

    func neverOffer(for app: CallApp) {
        var ignored = AppSettings.ignoredMeetingAppIDs
        ignored.insert(app.bundleID)
        AppSettings.setIgnoredMeetingAppIDs(ignored)
        detection.ignored = ignored
        offer = nil
        updatePanel()
    }

    func keepRecording() {
        if case .goodbye = ending { keptAfterGoodbye = true }
        quietFrom = Date()
        ending = nil
        updatePanel()
    }

    func stopNow() {
        ending = nil
        updatePanel()
        guard recorder.isRecording else { return }
        Task { await recorder.stop() }
    }

    // MARK: Watching

    private func micUsersChanged(_ users: [MicUseWatcher.User]) {
        let apps = users.compactMap { user -> CallApp? in
            let responsible = user.responsible.flatMap { pid in
                pid == user.pid ? nil : NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            }
            return CallApps.identify(bundleID: user.bundleID, responsibleBundleID: responsible, path: user.path)
        }
        let ids = Set(apps.map(\.bundleID))
        if ids != lastLoggedApps {
            lastLoggedApps = ids
            ActivityLog.add(ids.isEmpty ? "Meeting detection: no call app is using the microphone"
                                        : "Meeting detection: microphone in use by \(Set(apps.map(\.name)).sorted().joined(separator: ", "))")
        }
        detection.update(apps, now: Date())
        tick()
    }

    private func tick() {
        let now = Date()
        detection.ignored = AppSettings.ignoredMeetingAppIDs

        let newOffer = AppSettings.shouldDetectMeetings && !recorder.isActive ? detection.offer(now: now) : nil
        if newOffer != offer { offer = newOffer }

        if recorder.isRecording {
            if recordingCall == nil, let app = detection.activeApp(now: now) { recordingCall = app }
            checkForEnd(now)
        } else if !recorder.isActive {
            recordingCall = nil
            ending = nil
            keptAfterGoodbye = false
            quietFrom = nil
        }
        updatePanel()
    }

    private func checkForEnd(_ now: Date) {
        guard AppSettings.shouldAutoStopMeetings, let call = recordingCall, let started = recorder.startedAt else {
            ending = nil
            return
        }
        // The call is on (again): nothing to stop.
        if detection.isActive(call.bundleID) {
            ending = nil
            keptAfterGoodbye = false
            quietFrom = nil
            return
        }
        guard detection.hasEnded(call.bundleID, now: now),
              now.timeIntervalSince(started) >= CallEnding.minimumRecording else { return }
        if let ending {
            if now >= ending.stopAt {
                if case .goodbye = ending {
                    ActivityLog.add("Meeting detection: the call ended with goodbyes; stopped recording")
                } else {
                    ActivityLog.add("Meeting detection: no call and nothing heard for \(Int(CallEnding.quietLimit / 60)) minutes; stopped recording")
                }
                stopNow()
            }
            return
        }
        if !keptAfterGoodbye, CallEnding.soundsLikeGoodbye(recentWords()) {
            ending = .goodbye(stopAt: now.addingTimeInterval(CallEnding.goodbyeCountdown))
            return
        }
        let callEnded = detection.released[call.bundleID] ?? now
        let since = max(callEnded, quietFrom ?? .distantPast, started)
        let heard = min(hub.micTap.secondsSinceSound, hub.callTap.secondsSinceSound)
        if min(heard, now.timeIntervalSince(since)) >= CallEnding.quietLimit {
            ending = .quiet(stopAt: now.addingTimeInterval(CallEnding.quietCountdown))
        }
    }

    /// The last things said in the recording (finished lines and what's being worked out now).
    private func recentWords() -> String {
        guard let id = recorder.noteID, let note = store.note(id) else { return "" }
        let lines = note.transcript.suffix(12).map(\.text)
        return (lines + recorder.speakers.compactMap { recorder.volatileText[$0] }).joined(separator: " ")
    }

    // MARK: The panel

    private func updatePanel() {
        let showing = offer != nil || ending != nil
        if showing {
            if panel == nil { panel = MeetingPanel(content: AnyView(MeetingPromptView(watcher: self))) }
            panel?.present()
        } else {
            panel?.orderOut(nil)
        }
    }
}

/// The floating panel at the top right of the screen. It never takes focus from your call app.
final class MeetingPanel: NSPanel {
    private let hosting: NSHostingView<AnyView>

    init(content: AnyView) {
        hosting = NSHostingView(rootView: content)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        contentView = hosting
    }

    required init?(coder: NSCoder) {
        fatalError("MeetingPanel is made in code")
    }

    override var canBecomeKey: Bool { true }

    /// Shows the panel at the top right of the screen, sized to what it says. Once it's showing
    /// it stays where it is (you can drag it), growing or shrinking from its top edge.
    func present() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        if isVisible {
            guard contentRect(forFrameRect: frame).size != size else { return }
            let top = frame.maxY
            setContentSize(size)
            setFrameOrigin(NSPoint(x: frame.minX, y: top - frame.height))
            return
        }
        setContentSize(size)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let area = screen.visibleFrame
            setFrameOrigin(NSPoint(x: area.maxX - size.width - 16, y: area.maxY - size.height - 12))
        }
        orderFrontRegardless()
    }
}

/// What the panel says: "Zoom call — take notes?", or "Stopping in 12 s".
struct MeetingPromptView: View {
    let watcher: MeetingWatcher

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let ending = watcher.ending {
                endingContent(ending)
            } else if let app = watcher.offer {
                offerContent(app)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func offerContent(_ app: CallApp) -> some View {
        HStack(alignment: .top, spacing: 10) {
            appIcon(app)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.title).font(.headline)
                Text("Take notes with Sintr? It records your microphone and the call, and transcribes on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        HStack(spacing: 8) {
            Button {
                watcher.takeNotes(app)
            } label: {
                Label("Take notes", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            Button("Not now") { watcher.notNow(app) }
            Spacer(minLength: 0)
            Button("Never for \(app.name)") { watcher.neverOffer(for: app) }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .controlSize(.regular)
    }

    @ViewBuilder private func endingContent(_ ending: MeetingWatcher.Ending) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(ending.stopAt.timeIntervalSince(context.date).rounded(.up)))
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "stop.circle")
                        .font(.title2)
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isGoodbye(ending) ? "The call has ended" : "Nothing heard for \(Int(CallEnding.quietLimit / 60)) minutes")
                            .font(.headline)
                        Text("Sintr stops recording in \(left) s. Your notes and transcript are kept.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 8) {
                    Button("Keep recording") { watcher.keepRecording() }
                        .buttonStyle(.borderedProminent)
                    Button("Stop now") { watcher.stopNow() }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func isGoodbye(_ ending: MeetingWatcher.Ending) -> Bool {
        if case .goodbye = ending { return true }
        return false
    }

    @ViewBuilder private func appIcon(_ app: CallApp) -> some View {
        if let icon = MeetingApps.icon(for: app.bundleID) {
            Image(nsImage: icon).resizable().frame(width: 32, height: 32)
        } else {
            Image(systemName: "phone.circle.fill").font(.largeTitle).foregroundStyle(.green)
        }
    }
}
#endif
