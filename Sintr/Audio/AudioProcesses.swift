#if os(macOS)
import CoreAudio
import Darwin
import Foundation

/// Finds the Core Audio process objects that belong to an app: its own processes, helpers
/// inside its bundle, and processes it's responsible for — like Safari's "Graphics and Media"
/// process (com.apple.WebKit.GPU), which is what actually plays a YouTube video, or Chrome's
/// audio helper. Uses only libproc and Core Audio (no AppKit), so it's safe off the main
/// thread, and has no app types, so CI can compile and check it on its own
/// (scripts/ci-audio-check.sh).
enum AudioProcesses {
    /// One process that has registered with the audio system.
    struct Entry: Hashable, Sendable {
        let object: AudioObjectID
        let pid: pid_t
        let bundleID: String
        let path: String
        /// The app macOS holds responsible for it (Safari for its WebKit processes).
        let responsible: pid_t?
    }

    /// The audio processes that belong to the app.
    static func objects(for target: AppTarget, onlyPlaying: Bool = false) -> [AudioObjectID] {
        matches(for: target, onlyPlaying: onlyPlaying).map(\.object).sorted()
    }

    static func matches(for target: AppTarget, onlyPlaying: Bool = false) -> [Entry] {
        let appPIDs = pids(inside: target)
        return processes().filter { process in
            belongs(process, to: target, appPIDs: appPIDs) && (!onlyPlaying || isPlaying(process.object))
        }
    }

    /// Whether a process belongs to the app (no system calls, so it can be tested on its own).
    static func belongs(_ process: Entry, to target: AppTarget, appPIDs: Set<pid_t>,
                        responsibleKnown: Bool = canFindResponsible) -> Bool {
        if appPIDs.contains(process.pid) { return true }
        if process.bundleID == target.bundleID || process.bundleID.hasPrefix(target.bundleID + ".") { return true }
        if let marker = target.bundleMarker, process.path.contains(marker) { return true }
        if let responsible = process.responsible, responsible != process.pid, appPIDs.contains(responsible) { return true }
        // FaceTime (and iPhone calls on the Mac) are played by a system helper, not the app itself.
        if target.bundleID == "com.apple.FaceTime", process.path.hasSuffix("/avconferenced") { return true }
        // Without the responsible-process lookup, assume Safari's media is in WebKit's GPU process.
        if !responsibleKnown, target.bundleID == "com.apple.Safari", process.bundleID == "com.apple.WebKit.GPU" { return true }
        return false
    }

    /// "Safari (412), com.apple.WebKit.GPU (518)" — for the Activity Log.
    static func describe(_ processes: [Entry]) -> String {
        processes.map { process in
            let name = process.bundleID.isEmpty ? (process.path as NSString).lastPathComponent : process.bundleID
            return "\(name) (\(process.pid))"
        }.joined(separator: ", ")
    }

    // MARK: System lookups

    /// Every process registered with the audio system.
    static func processes() -> [Entry] {
        let objects: [AudioObjectID] = readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        return objects.compactMap { object -> Entry? in
            guard let pid: pid_t = readValue(object, kAudioProcessPropertyPID), pid > 0 else { return nil }
            let bundle = readString(object, kAudioProcessPropertyBundleID) ?? ""
            return Entry(object: object, pid: pid, bundleID: bundle, path: executablePath(pid) ?? "",
                           responsible: responsiblePID(pid))
        }
    }

    /// PIDs whose executable is inside the app's bundle (wherever macOS keeps it).
    static func pids(inside target: AppTarget) -> Set<pid_t> {
        guard let marker = target.bundleMarker else { return [] }
        var result: Set<pid_t> = []
        for pid in allPIDs() where executablePath(pid)?.contains(marker) == true { result.insert(pid) }
        return result
    }

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

    /// Whether a process is currently sending audio to an output device.
    static func isPlaying(_ object: AudioObjectID) -> Bool {
        let value: UInt32? = readValue(object, kAudioProcessPropertyIsRunningOutput)
        return (value ?? 0) != 0
    }

    static func allPIDs() -> [pid_t] {
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 64)
        let bytes = pids.withUnsafeMutableBufferPointer {
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard bytes > 0 else { return [] }
        return Array(pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: Responsible process (the same lookup Activity Monitor uses to name helpers)

    private typealias ResponsibleCall = @convention(c) (pid_t) -> pid_t

    private static let responsibleCall: ResponsibleCall? = {
        // RTLD_DEFAULT: search every loaded library.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleCall.self)
    }()

    static var canFindResponsible: Bool { responsibleCall != nil }

    static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let call = responsibleCall else { return nil }
        let result = call(pid)
        return result > 0 ? result : nil
    }

    // MARK: Property helpers

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func readValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.load(as: T.self)
    }

    private static func readArray(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var items = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &items) == noErr else { return [] }
        return Array(items.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
#endif

/// An app whose audio is recorded on its own ("Meeting audio: Safari"). Worked out on the main
/// thread (it needs AppKit) and handed to the capture code.
struct AppTarget: Hashable, Sendable {
    let bundleID: String
    /// The app bundle's folder name ("Safari.app").
    let bundleName: String?
    let name: String

    /// "/Safari.app/Contents/" — any executable under a folder like this belongs to the app,
    /// wherever macOS keeps it (Safari itself runs from a system volume, not /Applications).
    var bundleMarker: String? { bundleName.map { "/\($0)/Contents/" } }
}
