import Foundation

/// A call app that's using the microphone.
struct CallApp: Hashable, Sendable {
    /// The app's bundle ID (what "Meeting audio: this app" records).
    var bundleID: String
    var name: String
    var isBrowser: Bool

    /// What the note is called: "Zoom call", "Call in Safari".
    var title: String { isBrowser ? "Call in \(name)" : "\(name) call" }
}

/// Which apps count as call apps, and which app a process using the microphone belongs to.
enum CallApps {
    struct Known: Sendable {
        let prefix: String
        let bundleID: String
        let name: String
        var isBrowser = false
    }

    static let known: [Known] = [
        Known(prefix: "us.zoom.", bundleID: "us.zoom.xos", name: "Zoom"),
        Known(prefix: "com.microsoft.teams", bundleID: "com.microsoft.teams2", name: "Microsoft Teams"),
        Known(prefix: "com.cisco.webex", bundleID: "com.cisco.webexmeetingsapp", name: "Webex"),
        Known(prefix: "Cisco-Systems.Spark", bundleID: "Cisco-Systems.Spark", name: "Webex"),
        Known(prefix: "com.tinyspeck.slackmacgap", bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
        Known(prefix: "com.apple.FaceTime", bundleID: "com.apple.FaceTime", name: "FaceTime"),
        Known(prefix: "com.hnc.Discord", bundleID: "com.hnc.Discord", name: "Discord"),
        Known(prefix: "net.whatsapp.WhatsApp", bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp"),
        Known(prefix: "com.google.Chrome", bundleID: "com.google.Chrome", name: "Google Chrome", isBrowser: true),
        Known(prefix: "com.apple.Safari", bundleID: "com.apple.Safari", name: "Safari", isBrowser: true),
        Known(prefix: "com.microsoft.edgemac", bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", isBrowser: true),
        Known(prefix: "org.mozilla.firefox", bundleID: "org.mozilla.firefox", name: "Firefox", isBrowser: true),
        Known(prefix: "company.thebrowser.", bundleID: "company.thebrowser.Browser", name: "Arc", isBrowser: true),
        Known(prefix: "com.brave.Browser", bundleID: "com.brave.Browser", name: "Brave", isBrowser: true),
    ]

    /// The call app a process using the microphone belongs to, if any: the app macOS holds
    /// responsible for it (Safari for its media process, Chrome for its helpers), else its own
    /// bundle ID — or FaceTime, for the system helper that carries FaceTime and iPhone calls.
    static func identify(bundleID: String, responsibleBundleID: String?, path: String) -> CallApp? {
        if path.hasSuffix("/avconferenced") {
            return CallApp(bundleID: "com.apple.FaceTime", name: "FaceTime", isBrowser: false)
        }
        for id in [responsibleBundleID, bundleID].compactMap({ $0 }).filter({ !$0.isEmpty }) {
            if let app = known.first(where: { id.hasPrefix($0.prefix) }) {
                // The responsible app's own ID is the one to record ("com.google.Chrome", not a helper).
                let recordID = id == responsibleBundleID ? id : app.bundleID
                return CallApp(bundleID: recordID, name: app.name, isBrowser: app.isBrowser)
            }
        }
        return nil
    }

    /// Every call app name, for the "never offer for" list.
    static func name(for bundleID: String) -> String {
        known.first { bundleID.hasPrefix($0.prefix) }?.name ?? bundleID
    }
}

/// Decides when to offer "Take notes" and when a call is over, from which call apps are using
/// the microphone. Pure, and driven by the times passed in, so the automated checks can test it
/// (scripts/ci-logic-check.sh).
struct MeetingDetection: Sendable {
    /// How long an app must hold the microphone before it counts as a call (not a blip, like a
    /// browser checking the microphone).
    var debounce: TimeInterval = 4
    /// How long the microphone must be let go before the call counts as over (apps briefly
    /// release it when you switch devices or rejoin).
    var endGrace: TimeInterval = 8
    /// Apps never to offer notes for (bundle IDs).
    var ignored: Set<String> = []

    private struct Use: Sendable {
        var app: CallApp
        var since: Date
    }

    /// Call apps using the microphone now, by bundle ID.
    private var active: [String: Use] = [:]
    /// When each call app last let go of the microphone.
    private(set) var released: [String: Date] = [:]
    /// "Not now" for an app lasts until it lets go of the microphone (this call).
    private(set) var dismissed: Set<String> = []

    init() {}

    mutating func update(_ apps: [CallApp], now: Date) {
        let current = Dictionary(apps.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        for id in active.keys where current[id] == nil {
            active[id] = nil
            released[id] = now
        }
        for (id, app) in current where active[id] == nil {
            active[id] = Use(app: app, since: now)
            released[id] = nil
        }
        // A call that's really over: forget "Not now" for it.
        for id in dismissed where active[id] == nil && (released[id].map { now.timeIntervalSince($0) >= endGrace } ?? true) {
            dismissed.remove(id)
        }
    }

    /// The call to offer notes for, if any — a call app (Zoom, Teams…) before a browser.
    func offer(now: Date) -> CallApp? {
        ordered(now: now).first { !dismissed.contains($0.bundleID) && !ignored.contains($0.bundleID) }
    }

    /// The call going on now (past the debounce), if any.
    func activeApp(now: Date) -> CallApp? {
        ordered(now: now).first
    }

    func isActive(_ bundleID: String) -> Bool { active[bundleID] != nil }

    /// True once the app has let go of the microphone for longer than the grace period.
    func hasEnded(_ bundleID: String, now: Date) -> Bool {
        guard active[bundleID] == nil, let released = released[bundleID] else { return false }
        return now.timeIntervalSince(released) >= endGrace
    }

    mutating func dismiss(_ bundleID: String) { dismissed.insert(bundleID) }

    private func ordered(now: Date) -> [CallApp] {
        active.values
            .filter { now.timeIntervalSince($0.since) >= debounce }
            .sorted { ($0.app.isBrowser ? 1 : 0, $0.since) < ($1.app.isBrowser ? 1 : 0, $1.since) }
            .map(\.app)
    }
}

/// A recording of a call that's about to stop by itself, and why.
enum StopCountdown: Equatable, Sendable {
    /// The call ended with goodbyes.
    case goodbye(stopAt: Date)
    /// No call, and nothing heard for a long time.
    case quiet(stopAt: Date)

    var stopAt: Date {
        switch self {
        case .goodbye(let date), .quiet(let date): date
        }
    }

    var isGoodbye: Bool {
        if case .goodbye = self { return true }
        return false
    }
}

/// When a recording of a call offers to stop by itself. Leaving the call isn't enough on its
/// own — you might rejoin, or keep talking in the room — so it offers to stop when the last
/// words sound like goodbyes, or after a long quiet stretch with no call. Either way there's a
/// countdown with "Keep recording".
enum CallEnding {
    /// Recordings shorter than this never stop by themselves (a dropped call, a quick rejoin).
    static let minimumRecording: TimeInterval = 120
    /// The countdown after a call ends with goodbyes.
    static let goodbyeCountdown: TimeInterval = 15
    /// No call and nothing heard for this long: offer to stop.
    static let quietLimit: TimeInterval = 600
    /// The countdown after a long quiet stretch.
    static let quietCountdown: TimeInterval = 90
    /// How many of the last words are looked at.
    static let lastWords = 60

    /// True when the end of `text` sounds like people saying goodbye.
    static func soundsLikeGoodbye(_ text: String) -> Bool {
        let words = text.lowercased()
            .split { !($0.isLetter || $0 == "'" || $0 == "’") }
            .map { $0.replacingOccurrences(of: "’", with: "'") }
            .suffix(lastWords)
        guard !words.isEmpty else { return false }
        let tail = Array(words)
        return farewells.contains { phrase in
            let parts = phrase.split(separator: " ").map(String.init)
            guard parts.count <= tail.count else { return false }
            return (0...(tail.count - parts.count)).contains { start in
                Array(tail[start..<(start + parts.count)]) == parts
            }
        }
    }

    static let farewells = [
        "bye", "goodbye", "see you", "see ya", "talk soon", "talk to you later", "talk to you soon", "talk later",
        "speak soon", "speak to you soon", "take care", "have a good one", "have a good day", "have a great day",
        "have a nice day", "have a good weekend", "have a great weekend", "have a good night", "have a good evening",
        "thanks everyone", "thank you everyone", "thanks everybody", "thank you everybody", "thanks all",
        "thank you all", "catch you later", "later everyone", "until next time", "i'll let you go", "signing off",
        "adiós", "hasta luego", "hasta pronto", "chao", "au revoir", "à bientôt", "tschüss", "bis bald", "bis dann",
        "ciao", "arrivederci", "tchau", "até logo", "tot ziens", "doei", "hej då",
    ]
}
