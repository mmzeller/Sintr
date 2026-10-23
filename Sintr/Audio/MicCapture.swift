import AVFoundation
import Foundation
#if os(macOS)
import AudioToolbox
import CoreAudio
#endif

/// Captures the microphone with AVAudioEngine.
/// On iPhone it keeps recording with the screen locked (the app declares background audio).
///
/// Everything — starting, stopping, and restarting after a device change — happens on the
/// queue it's given (the `CaptureController`'s), never on the main thread: a Bluetooth headset
/// can take seconds to switch, and the window shouldn't wait for it.
final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue: DispatchQueue
    /// Device-change notifications are handled on `queue` too.
    private let operations: OperationQueue
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var observers: [NSObjectProtocol] = []
    /// Called on the capture queue when recording was interrupted (a phone call, Siri, a
    /// device that went away) and whether it could resume.
    var onInterruption: ((_ resumed: Bool) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
        operations = OperationQueue()
        operations.underlyingQueue = queue
        operations.maxConcurrentOperationCount = 1
    }

    /// The name of the microphone in use right now.
    var deviceName: String? { Self.currentDeviceName(engine.inputNode) }

    static func requestPermission() async -> Bool {
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }

    func start(handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        self.handler = handler
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true)
        #endif
        try installTapAndStart()
        observeChanges()
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        handler = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        ActivityLog.add("Microphone: stopped")
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        #if os(macOS)
        // Use the microphone chosen in Settings, if it's connected.
        let chosen = AppSettings.microphoneDeviceUID
        if let device = MicDevices.deviceID(forUID: chosen), let unit = input.audioUnit {
            var id = device
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { ActivityLog.add("Microphone: couldn't switch to the chosen microphone (\(status))") }
        } else if !chosen.isEmpty {
            ActivityLog.add("Microphone: the chosen microphone isn't connected; using the system default")
        }
        #endif
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            ActivityLog.add("Microphone: no usable input device (format \(AudioPipe.describe(format)))")
            throw SpeechError.noMicrophone
        }
        ActivityLog.add("Microphone: \(Self.currentDeviceName(input) ?? "input") — \(AudioPipe.describe(format))")
        // No format given: the tap uses whatever the device delivers, which avoids the
        // "format mismatch" crash when a device changes underneath us. The handler is captured
        // directly (not read from `self` on the audio thread while `stop()` clears it).
        guard let handler else { return }
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            handler(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private static func currentDeviceName(_ input: AVAudioInputNode) -> String? {
        #if os(macOS)
        guard let unit = input.audioUnit else { return nil }
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size) == noErr
        else { return nil }
        return MicDevices.name(forDevice: device)
        #else
        return AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName
        #endif
    }

    /// After a device change: try again a few times (a Bluetooth headset can take a moment).
    private func restartAfterChange(attempt: Int = 1) {
        guard handler != nil else { return }
        HangWatch.step("Microphone: restarting after a device change (attempt \(attempt))")
        defer { HangWatch.step("") }
        do {
            try installTapAndStart()
            ActivityLog.add("Microphone: restarted after a device change")
        } catch {
            ActivityLog.add("Microphone: restart attempt \(attempt) failed (\(error.localizedDescription))")
            guard attempt < 5 else { onInterruption?(false); return }
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.restartAfterChange(attempt: attempt + 1)
            }
        }
    }

    private func observeChanges() {
        let center = NotificationCenter.default
        // Headphones plugged in, Bluetooth connected, a different input chosen: the engine
        // stops and needs a fresh tap in the new format.
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: operations
        ) { [weak self] _ in
            guard let self, self.handler != nil else { return }
            ActivityLog.add("Microphone: audio devices changed")
            self.restartAfterChange()
        })
        #if os(iOS)
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: operations
        ) { [weak self] note in
            guard let self, self.handler != nil,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            if type == .ended {
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    try self.installTapAndStart()
                    self.onInterruption?(true)
                } catch {
                    self.onInterruption?(false)
                }
            } else {
                self.onInterruption?(false)
            }
        })
        #endif
    }
}

#if os(macOS)
/// The Mac's microphones, for the picker in Settings.
enum MicDevices {
    struct Device: Identifiable, Hashable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    static func all() -> [Device] {
        deviceIDs().compactMap { id -> Device? in
            guard hasInput(id), !isHidden(id),
                  let uid: CFString = read(id, kAudioDevicePropertyDeviceUID),
                  let name: CFString = read(id, kAudioObjectPropertyName)
            else { return nil }
            let text = name as String
            guard !text.hasPrefix("Sintr call audio") else { return nil }
            return Device(uid: uid as String, name: text)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        return deviceIDs().first { id in
            let value: CFString? = read(id, kAudioDevicePropertyDeviceUID)
            return (value as String?) == uid
        }
    }

    static func name(forUID uid: String) -> String? {
        all().first { $0.uid == uid }?.name
    }

    static func name(forDevice id: AudioDeviceID) -> String? {
        read(id, kAudioObjectPropertyName).map { $0 as String }
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func isHidden(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &hidden) == noErr && hidden != 0
    }

    private static func read(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> CFString? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue()
    }
}
#endif
