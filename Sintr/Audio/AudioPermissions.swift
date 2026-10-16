#if os(macOS)
import AppKit
import CoreGraphics
import Foundation

/// The Mac permission that lets Sintr hear the other side of a call.
///
/// macOS hands an app *silence* — with no error — when it taps system audio without the
/// "System Audio Recording" permission (or, as a fallback, Screen Recording). Apple offers no
/// public way to check or request that permission, so this uses the same private calls the
/// System Settings pane does, and falls back to opening the pane if they're unavailable.
enum SystemAudioPermission {
    enum Status: Equatable {
        case allowed
        case denied
        case notAsked
    }

    private static let service = "kTCCServiceAudioCapture" as CFString

    static var status: Status {
        if let preflight = preflightCall {
            switch preflight(service, nil) {
            case 0: return .allowed
            case 1: return screenRecordingAllowed ? .allowed : .denied
            default: return screenRecordingAllowed ? .allowed : .notAsked
            }
        }
        return screenRecordingAllowed ? .allowed : .notAsked
    }

    /// Whether this Mac lets Sintr check the permission (if not, Sintr just tries and
    /// watches for silence).
    static var canCheck: Bool { preflightCall != nil }

    /// Screen Recording also unlocks system audio taps.
    static var screenRecordingAllowed: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows macOS's "Allow Sintr to record system audio?" prompt. If macOS has already been
    /// told no, opens System Settings at the right place instead.
    static func request() async -> Bool {
        if status == .allowed { return true }
        if status == .denied {
            openSettings()
            return false
        }
        guard let request = requestCall else {
            openSettings()
            return false
        }
        ActivityLog.add("Asking macOS for permission to record system audio")
        let once = ResumeOnce()
        let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            once.set(continuation)
            request(service, nil) { granted in once.resume(granted) }
        }
        ActivityLog.add("System audio permission: \(granted ? "allowed" : "not allowed")")
        return granted
    }

    /// System Settings → Privacy & Security → Screen & System Audio Recording.
    static func openSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    static let settingsPath = "System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only"

    /// macOS's callback could, in theory, arrive twice; resuming twice would crash.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        func set(_ continuation: CheckedContinuation<Bool, Never>) { lock.withLock { self.continuation = continuation } }
        func resume(_ value: Bool) {
            let continuation = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(returning: value)
        }
    }

    // MARK: Private calls into TCC (the privacy database), looked up at run time.

    private typealias PreflightType = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestType = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflightCall: PreflightType? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: PreflightType.self)
    }()

    private static let requestCall: RequestType? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(symbol, to: RequestType.self)
    }()
}
#endif
