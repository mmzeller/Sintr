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
/// single app, when that app starts playing sound from a new process. Started and stopped by
/// the `CaptureController` on its own queue — never on the main thread.
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
    /// For a single app: which one, worked out on the main thread (it needs AppKit).
    let target: AppTarget?
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private let ioQueue = DispatchQueue(label: "Sintr.CallAudio.io", qos: .userInitiated)
    private let controlQueue = DispatchQueue(label: "Sintr.CallAudio.control")
    /// Property listeners must not run on the queue that removes them, or removing can deadlock.
    private let listenerQueue = DispatchQueue(label: "Sintr.CallAudio.listener")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tappedObjects: [AudioObjectID] = []
    private var watchTimer: DispatchSourceTimer?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var stopped = false
    private var generation = 0

    private let lock = NSLock()
    private var startUptime: TimeInterval = 0
    private var lastSoundUptime: TimeInterval = 0
    private var _received = false
    private var _heard = false
    private var _waiting = false
    /// The format buffers are read with; its sample rate is corrected if the device delivers
    /// a different rate than the tap claims.
    private var format: AVAudioFormat?
    private var rateCheckStart: TimeInterval = 0
    private var rateCheckFrames: Double = 0
    private var rateChecked = false

    init(source: MeetingAudio, target: AppTarget?) {
        self.source = source
        if case .app(let bundleID) = source {
            self.target = target ?? AppTarget(bundleID: bundleID, bundleName: nil, name: bundleID)
        } else {
            self.target = nil
        }
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
        try controlQueue.sync { try rebuild(reason: "start") }
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
        ActivityLog.add("Call audio: stopped")
    }

    deinit {
        tearDownTap()
    }

    // MARK: Building the tap (always on controlQueue)

    private func rebuild(reason: String) throws {
        defer { HangWatch.step("") }
        tearDownTap()
        guard !stopped else { return }

        let objects: [AudioObjectID]
        let description: CATapDescription
        switch source {
        case .off:
            return
        case .allAudio:
            objects = []
            let ownProcess = AudioProcesses.audioObject(for: getpid()).map { [$0] } ?? []
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess)
        case .app:
            guard let target else { return }
            HangWatch.step("Call audio: finding \(target.name)'s audio processes")
            let found = AudioProcesses.matches(for: target)
            objects = found.map(\.object).sorted()
            lock.withLock { _waiting = objects.isEmpty }
            guard !objects.isEmpty else {
                ActivityLog.add("Call audio: waiting for \(target.name) to use audio")
                return  // The watcher builds the tap once the app makes sound.
            }
            ActivityLog.add("Call audio: \(target.name) plays through \(AudioProcesses.describe(found))")
            description = CATapDescription(stereoMixdownOfProcesses: objects)
        }
        tappedObjects = objects
        description.uuid = UUID()
        description.name = "Sintr call audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        HangWatch.step("Call audio: creating the tap (\(reason))")
        var newTap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTap)
        guard status == noErr else {
            ActivityLog.add("Call audio: creating the tap failed (\(status))")
            throw CaptureError("set up call-audio capture", status)
        }
        tapID = newTap

        do {
            let output: AudioDeviceID = try Self.read(
                AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                default: AudioDeviceID(kAudioObjectUnknown))
            let outputUID: CFString = try Self.read(output, kAudioDevicePropertyDeviceUID, default: "" as CFString)
            let outputName: CFString = (try? Self.read(output, kAudioObjectPropertyName, default: "" as CFString)) ?? "" as CFString
            var streamDescription: AudioStreamBasicDescription = try Self.read(
                tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
            guard let tapFormat = AVAudioFormat(streamDescription: &streamDescription) else {
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
            HangWatch.step("Call audio: creating the capture device on \(outputName as String)")
            var newAggregate = AudioObjectID(kAudioObjectUnknown)
            status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate)
            guard status == noErr else { throw CaptureError("create the call-audio device", status) }
            aggregateID = newAggregate

            // The tap's own format can claim 48 kHz whatever the device runs at; trust the device.
            let nominal: Float64 = (try? Self.read(aggregateID, kAudioDevicePropertyNominalSampleRate, default: Float64(0))) ?? 0
            let rate = nominal > 0 ? nominal : tapFormat.sampleRate
            let readFormat = AVAudioFormat(
                commonFormat: tapFormat.commonFormat, sampleRate: rate,
                channels: tapFormat.channelCount, interleaved: tapFormat.isInterleaved) ?? tapFormat
            lock.withLock {
                format = readFormat
                rateChecked = false
                rateCheckFrames = 0
                rateCheckStart = 0
            }
            let what: String
            switch source {
            case .app: what = "\(target?.name ?? "the app") (\(objects.count) process\(objects.count == 1 ? "" : "es"))"
            default: what = "all Mac audio"
            }
            ActivityLog.add("Call audio (\(reason)): tapping \(what) via \(outputName as String) — tap says \(Int(tapFormat.sampleRate)) Hz, device runs at \(Int(nominal)) Hz, \(tapFormat.channelCount) ch")

            generation += 1
            let myGeneration = generation
            guard let handler else { return }
            status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, inputData, _, _, _ in
                guard let self, let format = self.usableFormat(for: inputData, generation: myGeneration),
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil),
                      buffer.frameLength > 0
                else { return }
                self.noteSignal(buffer)
                handler(buffer)
            }
            guard status == noErr else { throw CaptureError("start reading call audio", status) }

            HangWatch.step("Call audio: starting capture on \(outputName as String)")
            status = AudioDeviceStart(aggregateID, procID)
            guard status == noErr else { throw CaptureError("start call-audio capture", status) }
        } catch {
            ActivityLog.add("Call audio: \(error.localizedDescription)")
            tearDownTap()
            throw error
        }
    }

    /// The format to read this callback's audio as. If the buffers Core Audio hands over don't
    /// have the layout we expected (channel count or interleaving), adopt their actual layout
    /// rather than read past the end of them.
    private func usableFormat(for data: UnsafePointer<AudioBufferList>, generation: Int) -> AVAudioFormat? {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: data))
        guard list.count > 0, list.allSatisfy({ $0.mData != nil }) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let format else { return nil }
        let expectedBuffers = format.isInterleaved ? 1 : Int(format.channelCount)
        let channelsOK = format.isInterleaved
            ? list[0].mNumberChannels == format.channelCount
            : list.allSatisfy { $0.mNumberChannels == 1 }
        if list.count == expectedBuffers, channelsOK { return format }

        let interleaved = list.count == 1 && list[0].mNumberChannels > 1
        let channels = interleaved ? list[0].mNumberChannels : UInt32(list.count)
        guard channels > 0, let fixed = AVAudioFormat(
            commonFormat: format.commonFormat, sampleRate: format.sampleRate,
            channels: AVAudioChannelCount(channels), interleaved: interleaved)
        else { return nil }
        let old = AudioPipe.describe(format)
        self.format = fixed
        ActivityLog.add("Call audio: buffers arrive as \(AudioPipe.describe(fixed)), not \(old) — adjusted")
        return fixed
    }

    private func tearDownTap() {
        if aggregateID != kAudioObjectUnknown || tapID != kAudioObjectUnknown {
            HangWatch.step("Call audio: removing the old capture device")
        }
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
        let now = ProcessInfo.processInfo.systemUptime
        var corrected: Double?
        lock.lock()
        _received = true
        _waiting = false
        if loud {
            if !_heard { ActivityLog.add("Call audio: first sound") }
            _heard = true
            lastSoundUptime = now
        }
        // Check how fast frames really arrive; if it's clearly not the rate we assumed, fix it.
        if !rateChecked, let format {
            if rateCheckStart == 0 {
                rateCheckStart = now
            } else {
                rateCheckFrames += Double(buffer.frameLength)
                let elapsed = now - rateCheckStart
                if elapsed >= 4 {
                    rateChecked = true
                    let measured = rateCheckFrames / elapsed
                    let assumed = format.sampleRate
                    if abs(measured - assumed) / assumed > 0.04 {
                        let standard: [Double] = [16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 176400, 192000]
                        let nearest = standard.min { abs($0 - measured) < abs($1 - measured) } ?? measured
                        if let fixed = AVAudioFormat(commonFormat: format.commonFormat, sampleRate: nearest,
                                                     channels: format.channelCount, interleaved: format.isInterleaved) {
                            self.format = fixed
                            corrected = nearest
                        }
                    }
                    ActivityLog.add("Call audio: measured \(Int(measured)) frames/s (assumed \(Int(assumed)) Hz)")
                }
            }
        }
        lock.unlock()
        if let corrected { ActivityLog.add("Call audio: corrected the sample rate to \(Int(corrected)) Hz") }
    }

    // MARK: Keeping the tap current

    /// For a single app: every two seconds, check whether the app has started making sound
    /// from a process that isn't tapped yet, and rebuild the tap to include it.
    private func watchForAppAudio() {
        guard let target else { return }
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            let playing = Set(AudioProcesses.objects(for: target, onlyPlaying: true))
            let tapped = Set(self.tappedObjects)
            if !playing.isEmpty, !playing.isSubset(of: tapped) {
                try? self.rebuild(reason: "app started playing from \(playing.subtracting(tapped).count) new process(es)")
            }
        }
        timer.resume()
        watchTimer = timer
    }

    private var outputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func listenForOutputChanges() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // Give the new device a moment to settle, then follow it.
            self.controlQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.stopped else { return }
                ActivityLog.add("Call audio: the output device changed")
                try? self.rebuild(reason: "output device changed")
            }
        }
        outputListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddress, listenerQueue, listener)
    }

    private func removeOutputListener() {
        guard let listener = outputListener else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddress, listenerQueue, listener)
        outputListener = nil
    }

    // MARK: Helpers

    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T) throws -> T {
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

    /// The app to record on its own, for the capture code (call on the main thread).
    static func target(for bundleID: String) -> AppTarget {
        let url = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        return AppTarget(bundleID: bundleID, bundleName: url?.lastPathComponent, name: displayName(for: bundleID))
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
