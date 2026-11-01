#if os(macOS)
import CoreAudio
import Darwin
import Foundation

/// Watches which other apps are using a microphone, through Core Audio's per-process state
/// (the same thing that lights up the orange dot in the menu bar). It needs no permission,
/// reads no audio, and touches nothing in the other app, so nobody on a call can tell.
/// Event-driven: Core Audio says when the list of audio processes, or one of them, changes.
final class MicUseWatcher: @unchecked Sendable {
    /// A process using a microphone.
    struct User: Hashable, Sendable {
        let pid: pid_t
        let bundleID: String
        let path: String
        /// The app macOS holds responsible for it (Safari for its media process).
        let responsible: pid_t?
    }

    private let queue = DispatchQueue(label: "Sintr.MicUse", qos: .utility)
    private let onChange: @Sendable ([User]) -> Void
    private let ownPID = getpid()
    // Only touched on `queue`.
    private var listListener: AudioObjectPropertyListenerBlock?
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var last: [User]?

    /// `onChange` is called on a background queue with every process (other than Sintr)
    /// using a microphone, whenever that changes.
    init(onChange: @escaping @Sendable ([User]) -> Void) {
        self.onChange = onChange
    }

    func start() {
        queue.async { [self] in
            guard listListener == nil else { return }
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            var address = AudioProcesses.address(kAudioHardwarePropertyProcessObjectList)
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            if status == noErr {
                listListener = listener
            } else {
                ActivityLog.add("Meeting detection: couldn't watch audio processes (Core Audio error \(status))")
            }
            refresh()
        }
    }

    func stop() {
        queue.async { [self] in
            Self.remove(list: listListener, processes: processListeners, queue: queue)
            listListener = nil
            processListeners = [:]
            last = nil
        }
    }

    /// Re-reads the audio processes: listens to new ones, forgets ones that are gone, and
    /// reports who's using a microphone if that changed.
    private func refresh() {
        let entries = AudioProcesses.processes()
        let objects = Set(entries.map(\.object))
        for (object, listener) in processListeners where !objects.contains(object) {
            var address = AudioProcesses.address(kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
            processListeners[object] = nil
        }
        for entry in entries where processListeners[entry.object] == nil {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            var address = AudioProcesses.address(kAudioProcessPropertyIsRunningInput)
            if AudioObjectAddPropertyListenerBlock(entry.object, &address, queue, listener) == noErr {
                processListeners[entry.object] = listener
            }
        }
        let users = entries
            .filter { $0.pid != ownPID && AudioProcesses.isUsingInput($0.object) }
            .map { User(pid: $0.pid, bundleID: $0.bundleID, path: $0.path, responsible: $0.responsible) }
            .sorted { $0.pid < $1.pid }
        guard users != last else { return }
        last = users
        onChange(users)
    }

    private static func remove(list: AudioObjectPropertyListenerBlock?,
                               processes: [AudioObjectID: AudioObjectPropertyListenerBlock], queue: DispatchQueue) {
        if let list {
            var address = AudioProcesses.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, list)
        }
        for (object, listener) in processes {
            var address = AudioProcesses.address(kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
        }
    }
}
#endif
