import AVFoundation
import Foundation

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
