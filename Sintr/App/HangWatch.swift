import Foundation

/// Mac: notes in the Activity Log when Sintr stops responding (the window can't redraw), and
/// which audio step was running at the time — so a freeze leaves a trace even if Sintr has to
/// be force-quit (the log is on disk; the next launch shows it as the previous run).
///
/// Once a second it sends a tiny job to the main thread and checks how long the last one has
/// been waiting, so a timer delayed by App Nap doesn't count as a freeze.
enum HangWatch {
    private static let lock = NSLock()
    /// When the job now waiting for the main thread was sent (nil: none waiting).
    nonisolated(unsafe) private static var pendingSince: TimeInterval?
    nonisolated(unsafe) private static var reported = false
    /// Seconds in a row the main thread was slow to answer (busy, not frozen), and whether
    /// that's been noted.
    nonisolated(unsafe) private static var slowBeats = 0
    nonisolated(unsafe) private static var slowWorst: Double = 0
    nonisolated(unsafe) private static var reportedSlow = false
    nonisolated(unsafe) private static var currentStep = ""
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?

    /// What the audio code is doing right now ("Call audio: creating the device"); "" when idle.
    static func step(_ text: String) {
        lock.withLock { currentStep = text }
    }

    static func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "Sintr.HangWatch", qos: .utility))
        source.schedule(deadline: .now() + 2, repeating: 1)
        source.setEventHandler { tick() }
        source.resume()
        timer = source
    }

    private static func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        enum Action { case send, report(Double, String), wait }
        let action = lock.withLock { () -> Action in
            guard let since = pendingSince else {
                pendingSince = now
                return .send
            }
            if now - since > 3, !reported {
                reported = true
                return .report(now - since, currentStep)
            }
            return .wait
        }
        switch action {
        case .send:
            DispatchQueue.main.async { answered() }
        case .report(let seconds, let step):
            ActivityLog.add("Sintr stopped responding (\(Int(seconds)) s so far). Audio was: \(step.isEmpty ? "idle" : step)")
        case .wait:
            break
        }
    }

    /// Runs on the main thread.
    private static func answered() {
        let now = ProcessInfo.processInfo.systemUptime
        enum Outcome { case nothing, recovered(Double), busy(Double, String), calm }
        let outcome = lock.withLock { () -> Outcome in
            let waited = now - (pendingSince ?? now)
            let wasReported = reported
            pendingSince = nil
            reported = false
            if wasReported { return .recovered(waited) }
            // Busy: answering, but so slowly the window barely gets to draw.
            if waited > 0.25 {
                slowBeats += 1
                slowWorst = max(slowWorst, waited)
                if slowBeats == 5, !reportedSlow {
                    reportedSlow = true
                    return .busy(slowWorst, currentStep)
                }
            } else {
                slowBeats = 0
                slowWorst = 0
                if reportedSlow {
                    reportedSlow = false
                    return .calm
                }
            }
            return .nothing
        }
        switch outcome {
        case .nothing: break
        case .recovered(let waited): ActivityLog.add("Sintr is responding again after \(Int(waited)) s")
        case .busy(let worst, let step):
            ActivityLog.add("Sintr's window is very busy (up to \(Int(worst * 1000)) ms to answer, 5 s in a row). Audio was: \(step.isEmpty ? "idle" : step)")
        case .calm: ActivityLog.add("Sintr's window is answering normally again")
        }
    }
}
