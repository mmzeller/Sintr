import Foundation
import Observation

/// A running record of what Sintr's audio and speech parts are doing — devices, formats,
/// permissions, timings and errors, never what anyone said. It's kept in memory and in
/// "Logs/activity.log" inside Sintr's storage, so it survives a crash or force-quit.
/// Shown in the Activity Log window, with a Copy button for troubleshooting.
enum ActivityLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lines: [String] = []
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var opened = false
    /// A refresh of the Activity Log window is already on its way to the main thread.
    nonisolated(unsafe) private static var refreshPending = false
    /// The same line arriving over and over (from an audio callback, say) is written a few
    /// times, then counted, so it can't flood the log or the main thread.
    nonisolated(unsafe) private static var lastMessage = ""
    nonisolated(unsafe) private static var repeats = 0

    static var fileURL: URL {
        Storage.root.appendingPathComponent("Logs/activity.log")
    }

    static var previousFileURL: URL {
        Storage.root.appendingPathComponent("Logs/activity-previous.log")
    }

    /// Called once at launch: keeps the last run's log (to see what happened before a crash).
    static func startSession() {
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.removeItem(at: previousFileURL)
            try? fm.moveItem(at: fileURL, to: previousFileURL)
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        add("Sintr \(version) started on \(Platform.deviceName) (\(os)), storage: \(Storage.isPortable ? "portable" : "this \(Platform.deviceName)")")
    }

    static func add(_ message: String) {
        let stamp = Self.formatter.string(from: Date())
        lock.lock()
        if message == lastMessage {
            repeats += 1
            if repeats > 3 {
                lock.unlock()
                return
            }
        } else {
            if repeats > 3 { append("\(stamp)  (the line before was repeated \(repeats - 3) more times)") }
            lastMessage = message
            repeats = 0
        }
        append("\(stamp)  \(message)")
        let refresh = !refreshPending
        refreshPending = true
        lock.unlock()
        if refresh {
            Task { @MainActor in
                lock.withLock { refreshPending = false }
                ActivityLogFeed.shared.changed()
            }
        }
    }

    /// Call with the lock held.
    private static func append(_ line: String) {
        lines.append(line)
        if lines.count > 600 { lines.removeFirst(lines.count - 600) }
        if !opened {
            opened = true
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: fileURL)
            _ = try? handle?.seekToEnd()
        }
        if let data = (line + "\n").data(using: .utf8) {
            try? handle?.write(contentsOf: data)
        }
    }

    static var current: [String] {
        lock.withLock { lines }
    }

    static var previousRun: String? {
        guard let text = try? String(contentsOf: previousFileURL, encoding: .utf8), !text.isEmpty else { return nil }
        // The last 300 lines are plenty.
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(300).joined(separator: "\n")
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

/// Lets SwiftUI views refresh when new log lines arrive.
@MainActor
@Observable
final class ActivityLogFeed {
    static let shared = ActivityLogFeed()
    private(set) var revision = 0
    @ObservationIgnored private var scheduled = false

    func changed() {
        guard !scheduled else { return }
        scheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            self.scheduled = false
            self.revision += 1
        }
    }
}

#if os(macOS)
/// Reads the newest crash report macOS saved for Sintr and boils it down to the useful part.
enum CrashReports {
    struct Report {
        let date: Date
        let summary: String
    }

    static func latest() -> Report? {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let newest = files
            .filter { $0.lastPathComponent.hasPrefix("Sintr") && ["ips", "crash"].contains($0.pathExtension) }
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
                return (url, date)
            }
            .max { $0.1 < $1.1 }
        guard let (url, date) = newest, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Report(date: date, summary: summarize(text))
    }

    private static func summarize(_ text: String) -> String {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let data = String(parts[1]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return String(text.prefix(4000)) }
        var out: [String] = []
        if let version = (json["bundleInfo"] as? [String: Any])?["CFBundleShortVersionString"] { out.append("Version: \(version)") }
        if let exception = json["exception"] as? [String: Any] {
            out.append("Exception: \(exception["type"] ?? "?") \(exception["signal"] ?? "") \(exception["subtype"] ?? "")")
        }
        if let termination = json["termination"] as? [String: Any], let indicator = termination["indicator"] {
            out.append("Termination: \(indicator)")
        }
        if let asi = json["asi"] as? [String: Any] {
            for (key, value) in asi { out.append("Message (\(key)): \(value)") }
        }
        let images = json["usedImages"] as? [[String: Any]] ?? []
        if let threads = json["threads"] as? [[String: Any]],
           let crashed = threads.first(where: { ($0["triggered"] as? Bool) == true }),
           let frames = crashed["frames"] as? [[String: Any]] {
            out.append("Crashed thread\((crashed["queue"] as? String).map { " (\($0))" } ?? ""):")
            for frame in frames.prefix(25) {
                let index = frame["imageIndex"] as? Int ?? -1
                let image = index >= 0 && index < images.count ? (images[index]["name"] as? String ?? "?") : "?"
                out.append("  \(image)  \(frame["symbol"] as? String ?? "?")")
            }
        }
        return out.joined(separator: "\n")
    }
}
#endif
