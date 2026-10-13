#if os(macOS)
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures everything your Mac is playing (the other side of a Zoom, Teams, FaceTime or
/// browser call) using a Core Audio process tap — no bot joins the call, and nothing leaves the Mac.
/// The first time, macOS asks for permission to record system audio.
final class SystemAudioCapture: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "Sintr.CallAudio", qos: .userInitiated)

    func start(handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTap)
        guard status == noErr else { throw CaptureError("set up call-audio capture", status) }
        tapID = newTap

        do {
            let output: AudioDeviceID = try Self.read(
                AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice,
                default: AudioDeviceID(kAudioObjectUnknown))
            let outputUID: CFString = try Self.read(output, kAudioDevicePropertyDeviceUID, default: "" as CFString)
            var streamDescription: AudioStreamBasicDescription = try Self.read(
                tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
            guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
                throw CaptureError("read the call-audio format", -1)
            }

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Sintr call audio",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID as String,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID as String]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                    ]
                ],
            ]
            var newAggregate = AudioObjectID(kAudioObjectUnknown)
            status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate)
            guard status == noErr else { throw CaptureError("create the call-audio device", status) }
            aggregateID = newAggregate

            status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inputData, _, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil)
                else { return }
                handler(buffer)
            }
            guard status == noErr else { throw CaptureError("start reading call audio", status) }

            status = AudioDeviceStart(aggregateID, procID)
            guard status == noErr else { throw CaptureError("start call-audio capture", status) }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            procID = nil
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard status == noErr else { throw CaptureError("read audio settings", status) }
        var result = value
        status = withUnsafeMutablePointer(to: &result) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { throw CaptureError("read audio settings", status) }
        return result
    }
}

struct CaptureError: LocalizedError {
    let action: String
    let status: OSStatus
    init(_ action: String, _ status: OSStatus) {
        self.action = action
        self.status = status
    }
    var errorDescription: String? { "Couldn't \(action) (Core Audio error \(status))." }
}
#endif
