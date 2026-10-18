import AVFoundation
import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

/// One audio source's latest level, and where its audio goes while recording.
/// Called from audio threads.
final class AudioTap: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var _level: Float = 0
    private var lastBuffer: TimeInterval = 0
    private var lastSound: TimeInterval = 0

    func process(_ raw: AVAudioPCMBuffer) {
        guard let mono = AudioPipe.mono(raw) else { return }
        let level = AudioPipe.level(mono)
        let sound = AudioPipe.hasSound(mono)
        let now = ProcessInfo.processInfo.systemUptime
        let sink = lock.withLock { () -> (@Sendable (AVAudioPCMBuffer) -> Void)? in
            _level = max(level, _level * 0.7)
            lastBuffer = now
            if sound { lastSound = now }
            return self.sink
        }
        sink?(mono)
    }

    /// Recent loudness 0…1 (falls to 0 if audio stops arriving).
    var level: Float {
        lock.withLock {
            ProcessInfo.processInfo.systemUptime - lastBuffer > 0.5 ? 0 : _level
        }
    }

    var secondsSinceSound: Double {
        lock.withLock { lastSound == 0 ? .infinity : ProcessInfo.processInfo.systemUptime - lastSound }
    }

    var isReceiving: Bool {
        lock.withLock { lastBuffer > 0 && ProcessInfo.processInfo.systemUptime - lastBuffer < 1.5 }
    }

    func attach(_ sink: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        lock.withLock { self.sink = sink }
    }

    func reset() {
        lock.withLock {
            _level = 0
            lastBuffer = 0
            lastSound = 0
        }
    }
}

/// Keeps the microphone (and, on the Mac, call audio) running so the live meters always show
/// what's coming in — before and during a recording. A recording just attaches to it.
@MainActor
@Observable
final class AudioHub {
    enum CallState: Equatable {
        case off
        case notAllowed
        case waiting(String)
        case silent
        case hearing
    }

    private(set) var micLevel: Float = 0
    private(set) var callLevel: Float = 0
    private(set) var micName = ""
    private(set) var micRunning = false
    private(set) var micHearing = false
    private(set) var callState: CallState = .off
    private(set) var callName = ""
    private(set) var isRecording = false

    let micTap = AudioTap()
    let callTap = AudioTap()
    /// Forwards things the person should know (an interruption, a device that went away).
    @ObservationIgnored var onNotice: ((String) -> Void)?

    @ObservationIgnored private var mic: MicCapture?
    @ObservationIgnored private var micUID: String?
    #if os(macOS)
    @ObservationIgnored private var call: SystemAudioCapture?
    #endif
    @ObservationIgnored private var callSource: MeetingAudio = .off
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var settingsObserver: NSObjectProtocol?
    @ObservationIgnored private var lastSettings = ""
    @ObservationIgnored private var permissionChecked = Date.distantPast
    @ObservationIgnored private var permissionAllowed = true

    init() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.settingsChanged() }
        }
    }

    // MARK: Monitoring

    /// Shows live levels when the app opens (Mac), if the setting is on.
    func startMonitoringIfWanted() async {
        lastSettings = settingsKey
        #if os(macOS)
        // Wait for the setup screen, so its microphone question comes first.
        guard UserDefaults.standard.bool(forKey: AppSettings.setupDone) else { return }
        guard AppSettings.shouldMonitorLevels, !isRecording else { return }
        guard await MicCapture.requestPermission() else {
            micName = "Microphone not allowed"
            return
        }
        _ = ensureRunning(meeting: AppSettings.meetingAudioChoice)
        #endif
    }

    /// Stops all capture (when not recording).
    func stopAll() {
        guard !isRecording else { return }
        stopMic()
        #if os(macOS)
        stopCall()
        #endif
        pollTask?.cancel()
        pollTask = nil
        micLevel = 0
        callLevel = 0
        micHearing = false
        callState = .off
    }

    // MARK: Recording

    /// Makes sure the microphone (and call audio, on the Mac) are being captured.
    /// Returns the meeting audio that actually started — `.off` if call capture failed.
    @discardableResult
    func ensureRunning(meeting: MeetingAudio) -> MeetingAudio {
        if mic == nil || micUID != AppSettings.microphoneDeviceUID {
            startMic()
        }
        var effective = MeetingAudio.off
        #if os(macOS)
        if meeting != callSource || (meeting.isOn && call == nil) {
            stopCall()
            if meeting.isOn { startCall(meeting) }
        }
        effective = call != nil ? callSource : .off
        #endif
        startPolling()
        return effective
    }

    var micIsRunning: Bool { mic != nil }

    func beginRecording(micSink: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
                        callSink: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        isRecording = true
        micTap.attach(micSink)
        callTap.attach(callSink)
    }

    func endRecording() {
        micTap.attach(nil)
        callTap.attach(nil)
        isRecording = false
        #if os(macOS)
        if AppSettings.shouldMonitorLevels {
            settingsChanged()  // Apply any changes made during the recording.
            return
        }
        #endif
        stopAll()
    }

    // MARK: Pieces

    private func startMic() {
        stopMic()
        let capture = MicCapture()
        let tap = micTap
        capture.onInterruption = { [weak self] resumed in
            self?.onNotice?(resumed
                ? "Recording resumed after an interruption."
                : "The microphone stopped (another app took it, or it was disconnected). Sintr keeps trying to get it back.")
        }
        do {
            try capture.start { buffer in tap.process(buffer) }
            mic = capture
            micUID = AppSettings.microphoneDeviceUID
            micRunning = true
            micName = capture.deviceName ?? "Microphone"
        } catch {
            ActivityLog.add("Microphone: couldn't start (\(error.localizedDescription))")
            micName = "Microphone unavailable"
            micRunning = false
        }
    }

    private func stopMic() {
        mic?.stop()
        mic = nil
        micUID = nil
        micRunning = false
        micTap.reset()
    }

    #if os(macOS)
    private func startCall(_ source: MeetingAudio) {
        callSource = source
        switch source {
        case .app(let id): callName = MeetingApps.displayName(for: id)
        default: callName = "Mac audio"
        }
        let capture = SystemAudioCapture(source: source)
        let tap = callTap
        do {
            try capture.start { buffer in tap.process(buffer) }
            call = capture
        } catch {
            ActivityLog.add("Call audio: couldn't start (\(error.localizedDescription))")
            call = nil
            callState = .off
        }
    }

    private func stopCall() {
        call?.stop()
        call = nil
        callSource = .off
        callTap.reset()
    }
    #endif

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.micLevel = self.micTap.level
                self.callLevel = self.callTap.level
                if tick % 5 == 0 { self.refreshStates() }
                tick += 1
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func refreshStates() {
        micHearing = micTap.secondsSinceSound < 2
        #if os(macOS)
        guard let call else { callState = .off; return }
        let signal = call.signal
        // Asking macOS about the permission isn't free; do it now and then, and only while
        // nothing has been heard.
        if !signal.heardSound, SystemAudioPermission.canCheck, Date().timeIntervalSince(permissionChecked) > 3 {
            permissionChecked = Date()
            permissionAllowed = SystemAudioPermission.status == .allowed
        }
        if !signal.heardSound && !permissionAllowed {
            callState = .notAllowed
        } else if signal.waitingForApp {
            callState = .waiting(callName)
        } else if callTap.secondsSinceSound < 3 {
            callState = .hearing
        } else {
            callState = .silent
        }
        #endif
    }

    // MARK: Settings

    private var settingsKey: String {
        "\(AppSettings.shouldMonitorLevels)|\(AppSettings.microphoneDeviceUID)|\(AppSettings.meetingAudioChoice.rawValue)"
    }

    /// Restart what changed (not during a recording — then it waits until the recording ends).
    func settingsChanged() {
        let key = settingsKey
        guard key != lastSettings, !isRecording else { return }
        lastSettings = key
        #if os(macOS)
        if AppSettings.shouldMonitorLevels {
            Task { await startMonitoringIfWanted() }
        } else {
            stopAll()
        }
        #endif
    }
}
