import AVFoundation
import Foundation
#if os(macOS)
import AudioToolbox
import CoreAudio
#endif

/// Captures the microphone with AVAudioEngine.
/// On iPhone it keeps recording with the screen locked (the app declares background audio).
final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var observers: [NSObjectProtocol] = []
    /// Called on the main thread when recording was interrupted (a phone call, Siri…) and
    /// whether it could resume.
    var onInterruption: ((_ resumed: Bool) -> Void)?

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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        handler = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        #if os(macOS)
        // Use the microphone chosen in Settings, if it's connected.
        if let device = MicDevices.deviceID(forUID: AppSettings.microphoneDeviceUID), let unit = input.audioUnit {
            var id = device
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        #endif
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechError.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handler?(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func observeChanges() {
        let center = NotificationCenter.default
        // Headphones plugged in, Bluetooth connected, a different input chosen: the engine
        // stops and needs a fresh tap in the new format.
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.handler != nil else { return }
            try? self.installTapAndStart()
        })
        #if os(iOS)
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
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
