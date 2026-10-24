import AVFoundation
import Foundation

/// Starts and stops the microphone and call-audio capture on its own queue, so the window
/// never waits on audio hardware. Bluetooth headsets (AirPods) can take seconds to switch,
/// and Core Audio calls can stall while devices come and go; on the main thread that froze
/// the whole window. Everything here runs on `queue`, one step at a time.
final class CaptureController: @unchecked Sendable {
    struct Status: Sendable {
        var micRunning = false
        var micName = ""
        /// The meeting audio that's actually running (`.off` if call capture failed).
        var callSource: MeetingAudio = .off
    }

    let queue = DispatchQueue(label: "Sintr.AudioControl", qos: .userInitiated)
    /// Things the person should know (an interruption, a device that went away). Any thread.
    var onNotice: (@Sendable (String) -> Void)?
    /// The microphone switched devices by itself (AirPods connected). Any thread.
    var onMicName: (@Sendable (String) -> Void)?

    // Only touched on `queue`.
    private var mic: MicCapture?
    private var micUID: String?
    private var micName = ""
    private var callSource: MeetingAudio = .off
    private var callTarget: AppTarget?

    #if os(macOS)
    /// Read from the main thread for the meters, so it's behind a lock.
    private let callLock = NSLock()
    private var _call: SystemAudioCapture?
    private var call: SystemAudioCapture? {
        get { callLock.withLock { _call } }
        set { callLock.withLock { _call = newValue } }
    }

    /// The call side's signal, for the meters (safe from any thread).
    var callSignal: SystemAudioCapture.Signal? { call?.signal }
    #endif

    /// Makes sure the microphone (with this device) and the meeting audio are running.
    func ensure(micUID wanted: String, meeting: MeetingAudio, target: AppTarget?,
                micTap: AudioTap, callTap: AudioTap) async -> Status {
        await run {
            if self.mic == nil || self.micUID != wanted {
                self.startMic(wanted, tap: micTap)
            }
            #if os(macOS)
            if meeting != self.callSource || target != self.callTarget || (meeting.isOn && self.call == nil) {
                self.stopCall(tap: callTap)
                if meeting.isOn { self.startCall(meeting, target: target, tap: callTap) }
            }
            #endif
            return self.status
        }
    }

    /// Stops everything.
    func stopAll(micTap: AudioTap, callTap: AudioTap) async -> Status {
        await run {
            self.stopMic(tap: micTap)
            #if os(macOS)
            self.stopCall(tap: callTap)
            #endif
            return self.status
        }
    }

    private var status: Status {
        var result = Status(micRunning: mic != nil, micName: micName)
        #if os(macOS)
        result.callSource = call != nil ? callSource : .off
        #endif
        return result
    }

    private func run(_ work: @escaping () -> Status) async -> Status {
        await withCheckedContinuation { continuation in
            queue.async {
                let result = work()
                HangWatch.step("")
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: Microphone

    private func startMic(_ uid: String, tap: AudioTap) {
        stopMic(tap: tap)
        HangWatch.step("Microphone: starting")
        let capture = MicCapture(queue: queue)
        capture.onRestarted = { [weak self] name in
            self?.micName = name
            self?.onMicName?(name)
        }
        capture.onInterruption = { [weak self] resumed in
            self?.onNotice?(resumed
                ? "Recording resumed after an interruption."
                : "The microphone stopped (another app took it, or it was disconnected). Sintr keeps trying to get it back.")
        }
        do {
            try capture.start { buffer in tap.process(buffer) }
            mic = capture
            micUID = uid
            micName = capture.deviceName ?? "Microphone"
        } catch {
            ActivityLog.add("Microphone: couldn't start (\(error.localizedDescription))")
            mic = nil
            micUID = nil
            micName = "Microphone unavailable"
        }
    }

    private func stopMic(tap: AudioTap) {
        guard let mic else { return }
        HangWatch.step("Microphone: stopping")
        mic.stop()
        self.mic = nil
        micUID = nil
        micName = ""
        tap.reset()
    }

    // MARK: Call audio

    #if os(macOS)
    private func startCall(_ source: MeetingAudio, target: AppTarget?, tap: AudioTap) {
        callSource = source
        callTarget = target
        HangWatch.step("Call audio: starting")
        let capture = SystemAudioCapture(source: source, target: target, queue: queue)
        do {
            try capture.start { buffer in tap.process(buffer) }
            call = capture
        } catch {
            ActivityLog.add("Call audio: couldn't start (\(error.localizedDescription))")
            call = nil
        }
    }

    private func stopCall(tap: AudioTap) {
        if let capture = call {
            HangWatch.step("Call audio: stopping")
            capture.stop()
        }
        call = nil
        callSource = .off
        callTarget = nil
        tap.reset()
    }
    #endif
}
