#if os(macOS)
import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin
import Foundation

/// Captures what the Mac plays — everything, or just one app (FaceTime, Teams, Zoom…) — using a
/// Core Audio process tap. No bot joins the call and nothing leaves the Mac.
///
/// The tap is rebuilt automatically when the output device changes (AirPods connect) and, for a
/// single app, when that app starts making sound or adds a helper process.
final class SystemAudioCapture: @unchecked Sendable {
    struct Signal: Sendable {
        /// Any audio buffers at all have arrived.
        var receivedBuffers = false
        /// Something other than digital silence has arrived.
        var heardSound = false
        /// Seconds since the last non-silent buffer (or since start).
        var secondsSinceSound: Double = 0
        /// A single app was chosen but isn't playing any audio yet.
        var waitingForApp = false
    }

    let source: MeetingAudio
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private let ioQueue = DispatchQueue(label: "Sintr.CallAudio.io", qos: .userInitiated)
    private let controlQueue = DispatchQueue(label: "Sintr.CallAudio.control")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tappedObjects: [AudioObjectID] = []
    private var watchTimer: DispatchSourceTimer?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var stopped = false

    private let lock = NSLock()
    private var startUptime: TimeInterval = 0
    private var lastSoundUptime: TimeInterval = 0
    private var _received = false
    private var _heard = false
    private var _waiting = false

    init(source: MeetingAudio) {
        self.source = source
    }

    var signal: Signal {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            return Signal(
                receivedBuffers: _received, heardSound: _heard,
                secondsSinceSound: now - (_heard ? lastSoundUptime : startUptime),
                waitingForApp: _waiting)
        }
    }

    func start(handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        self.handler = handler
        lock.withLock { startUptime = ProcessInfo.processInfo.systemUptime }
        try controlQueue.sync { try rebuild() }
        listenForOutputChanges()
        if case .app = source { watchForAppAudio() }
    }

    func stop() {
        controlQueue.sync {
            stopped = true
            watchTimer?.cancel()
            watchTimer = nil
            removeOutputListener()
            tearDownTap()
        }
        handler = nil
    }

    deinit {
        tearDownTap()
    }

    // MARK: Building the tap (always on controlQueue)

    private func rebuild() throws {
        tearDownTap()
        guard !stopped else { return }

        let objects: [AudioObjectID]
        let description: CATapDescription
        switch source {
        case .off:
            return
        case .allAudio:
            objects = []
            let ownProcess = Self.audioObject(for: getpid()).map { [$0] } ?? []
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess)
        case .app(let bundleID):
            objects = MeetingApps.audioObjects(for: bundleID)
            lock.withLock { _waiting = objects.isEmpty }
            guard !objects.isEmpty else { return }  // The watcher builds the tap once the app makes sound.
            description = CATapDescription(stereoMixdownOfProcesses: objects)
        }
        tappedObjects = objects
        description.uuid = UUID()
        description.name = "Sintr call audio"
        description.isPrivate = true
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
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID as String]],
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

            status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, inputData, _, _, _ in
                guard let self,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil)
                else { return }
                self.noteSignal(buffer)
                self.handler?(buffer)
            }
            guard status == noErr else { throw CaptureError("start reading call audio", status) }

            status = AudioDeviceStart(aggregateID, procID)
            guard status == noErr else { throw CaptureError("start call-audio capture", status) }
        } catch {
            tearDownTap()
            throw error
        }
    }

    private func tearDownTap() {
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
        tappedObjects = []
    }

    private func noteSignal(_ buffer: AVAudioPCMBuffer) {
        var loud = false
        if let data = buffer.floatChannelData {
            let frames = Int(buffer.frameLength)
            let channels = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
            let samplesPerChannel = buffer.format.isInterleaved ? frames * Int(buffer.format.channelCount) : frames
            outer: for channel in 0..<channels {
                let samples = data[channel]
                for i in stride(from: 0, to: samplesPerChannel, by: 2) where samples[i] != 0 {
                    loud = true
                    break outer
                }
            }
        }
        lock.withLock {
            _received = true
            _waiting = false
            if loud {
                _heard = true
                lastSoundUptime = ProcessInfo.processInfo.systemUptime
            }
        }
    }

    // MARK: Keeping the tap current

    /// For a single app: every two seconds, check whether the app has started (or stopped)
    /// making sound, and rebuild the tap to match.
    private func watchForAppAudio() {
        guard case .app(let bundleID) = source else { return }
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            let current = Set(MeetingApps.audioObjects(for: bundleID))
            if !current.isEmpty, current != Set(self.tappedObjects) {
                try? self.rebuild()
            }
        }
        timer.resume()
        watchTimer = timer
    }

    private var outputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func listenForOutputChanges() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // Give the new device a moment to settle, then follow it.
            self.controlQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.stopped else { return }
                try? self.rebuild()
            }
        }
        outputListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddress, controlQueue, listener)
    }

    private func removeOutputListener() {
        guard let listener = outputListener else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddress, controlQueue, listener)
        outputListener = nil
    }

    // MARK: Helpers

    static func audioObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var pid = pid
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

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

/// Apps whose audio can be recorded on their own, for the "Meeting audio" picker.
enum MeetingApps {
    struct App: Identifiable, Hashable {
        let bundleID: String
        let name: String
        let isRunning: Bool
        var id: String { bundleID }
    }

    /// Common call apps, shown even when they aren't open yet.
    static let known: [(bundleID: String, name: String)] = [
        ("com.apple.FaceTime", "FaceTime"),
        ("com.microsoft.teams2", "Microsoft Teams"),
        ("us.zoom.xos", "Zoom"),
        ("com.cisco.webexmeetingsapp", "Webex"),
        ("Cisco-Systems.Spark", "Webex"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.hnc.Discord", "Discord"),
        ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("com.google.Chrome", "Google Chrome"),
        ("com.apple.Safari", "Safari"),
        ("com.microsoft.edgemac", "Microsoft Edge"),
        ("org.mozilla.firefox", "Firefox"),
        ("company.thebrowser.Browser", "Arc"),
    ]

    /// Known call apps that are installed, plus any other open app, sorted with open apps first.
    static func choices(including selected: String? = nil) -> [App] {
        var result: [String: App] = [:]
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        for app in running {
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { continue }
            result[id] = App(bundleID: id, name: app.localizedName ?? id, isRunning: true)
        }
        for entry in known where result[entry.bundleID] == nil {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID) != nil {
                result[entry.bundleID] = App(bundleID: entry.bundleID, name: entry.name, isRunning: false)
            }
        }
        if let selected, result[selected] == nil {
            result[selected] = App(bundleID: selected, name: displayName(for: selected), isRunning: false)
        }
        let knownIDs = Set(known.map(\.bundleID))
        return result.values.sorted {
            let a = (knownIDs.contains($0.bundleID) ? 0 : 1, $0.name.lowercased())
            let b = (knownIDs.contains($1.bundleID) ? 0 : 1, $1.name.lowercased())
            return a < b
        }
    }

    static func displayName(for bundleID: String) -> String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let name = app.localizedName {
            return name
        }
        if let entry = known.first(where: { $0.bundleID == bundleID }) { return entry.name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    static func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Core Audio objects for every process belonging to the app that has registered with the
    /// audio system — including helpers (Teams, Chrome and Slack play sound from helper processes).
    static func audioObjects(for bundleID: String) -> [AudioObjectID] {
        let bundlePaths = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleID }
            .compactMap { $0.bundleURL?.resolvingSymlinksInPath().path }
        var pids: Set<pid_t> = []
        if !bundlePaths.isEmpty {
            for pid in allPIDs() {
                guard let path = executablePath(pid) else { continue }
                if bundlePaths.contains(where: { path.hasPrefix($0 + "/") }) { pids.insert(pid) }
            }
        }
        // FaceTime (and iPhone calls on the Mac) are played by a system helper, not the app itself.
        if bundleID == "com.apple.FaceTime" {
            for pid in allPIDs() {
                if let path = executablePath(pid), path.hasSuffix("/avconferenced") { pids.insert(pid) }
            }
        }
        return pids.compactMap(SystemAudioCapture.audioObject(for:)).sorted()
    }

    private static func allPIDs() -> [pid_t] {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 64)
        let bytes = pids.withUnsafeMutableBufferPointer {
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard bytes > 0 else { return [] }
        return Array(pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
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
