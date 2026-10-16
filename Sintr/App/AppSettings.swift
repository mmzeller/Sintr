import Foundation

/// Names and defaults for everything kept in UserDefaults.
/// Views read these with @AppStorage(AppSettings.key), other code with AppSettings.value.
enum AppSettings {
    /// BCP-47 language for transcription; empty means the device's language.
    static let language = "transcriptionLanguage"
    /// Keep the audio files after a recording (needed to re-transcribe or detect speakers later).
    static let keepRecordings = "keepRecordings"
    /// iPhone: let notes go into iCloud/Finder backups of the phone.
    static let includeInBackups = "includeInBackups"
    /// Mac: what to record besides the microphone — see `MeetingAudio`.
    static let meetingAudio = "meetingAudio"
    /// Older on/off switch for call audio, read once to set `meetingAudio`.
    static let captureCallAudio = "captureCallAudio"
    /// Label who's speaking after a recording (on-device).
    static let detectSpeakers = "detectSpeakers"
    /// Mac: Core Audio UID of the microphone to use; empty means the system default.
    static let microphoneUID = "microphoneUID"
    /// The template Enhance uses (a `NoteTemplate` id).
    static let template = "template"
    /// Names, jargon and spellings to get right (used by Enhance and Translate).
    static let glossary = "glossary"
    static let translateTarget = "translateTarget"
    static let translateEngine = "translateEngine"
    static let claudeModel = "claudeModel"
    static let phoneModel = "phoneModel"
    /// Mac: keep the input meters live even when not recording.
    static let monitorLevels = "monitorLevels"
    /// Drop lines the microphone picked up from the speakers (call audio heard twice).
    static let removeEcho = "removeEcho"

    static let defaultClaudeModel = "claude-sonnet-5-5"

    static func register() {
        let defaults = UserDefaults.standard
        // Version 1.0 had a simple on/off switch for call audio. (Checked before registering
        // defaults, so only a value the person actually saved counts.)
        if defaults.object(forKey: captureCallAudio) != nil {
            if defaults.object(forKey: meetingAudio) == nil, !defaults.bool(forKey: captureCallAudio) {
                defaults.set(MeetingAudio.off.rawValue, forKey: meetingAudio)
            }
            defaults.removeObject(forKey: captureCallAudio)
        }
        defaults.register(defaults: [
            language: "",
            keepRecordings: true,
            includeInBackups: false,
            meetingAudio: MeetingAudio.allAudio.rawValue,
            detectSpeakers: true,
            microphoneUID: "",
            template: NoteTemplate.defaultID,
            glossary: "",
            translateTarget: "es",
            translateEngine: TranslateEngine.apple.rawValue,
            claudeModel: defaultClaudeModel,
            phoneModel: PhoneModelChoice.defaultChoice.rawValue,
            monitorLevels: true,
            removeEcho: true,
        ])
    }

    static var languageID: String { UserDefaults.standard.string(forKey: language) ?? "" }
    static var shouldKeepRecordings: Bool { UserDefaults.standard.bool(forKey: keepRecordings) }
    static var shouldIncludeInBackups: Bool { UserDefaults.standard.bool(forKey: includeInBackups) }
    static var shouldDetectSpeakers: Bool { UserDefaults.standard.bool(forKey: detectSpeakers) }
    static var meetingAudioChoice: MeetingAudio {
        MeetingAudio(rawValue: UserDefaults.standard.string(forKey: meetingAudio) ?? "") ?? .allAudio
    }
    static var shouldMonitorLevels: Bool { UserDefaults.standard.bool(forKey: monitorLevels) }
    static var shouldRemoveEcho: Bool { UserDefaults.standard.bool(forKey: removeEcho) }
    static var microphoneDeviceUID: String { UserDefaults.standard.string(forKey: microphoneUID) ?? "" }
    static var glossaryText: String {
        (UserDefaults.standard.string(forKey: glossary) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static var claudeModelID: String {
        let value = UserDefaults.standard.string(forKey: claudeModel) ?? ""
        return value.trimmingCharacters(in: .whitespaces).isEmpty ? defaultClaudeModel : value
    }
}

/// What a Mac recording captures besides the microphone.
/// Stored as "off", "all", or "app:<bundle id>".
enum MeetingAudio: Hashable, Sendable {
    /// Microphone only — in-person meetings and voice notes.
    case off
    /// Everything the Mac plays: the other side of FaceTime, Teams, Zoom, Meet in a browser…
    case allAudio
    /// Only what one app plays.
    case app(bundleID: String)

    init?(rawValue: String) {
        switch rawValue {
        case "off": self = .off
        case "all": self = .allAudio
        default:
            guard rawValue.hasPrefix("app:"), rawValue.count > 4 else { return nil }
            self = .app(bundleID: String(rawValue.dropFirst(4)))
        }
    }

    var rawValue: String {
        switch self {
        case .off: "off"
        case .allAudio: "all"
        case .app(let id): "app:\(id)"
        }
    }

    var isOn: Bool { self != .off }
}

enum Platform {
    #if os(macOS)
    static let isMac = true
    static let deviceName = "Mac"
    #else
    static let isMac = false
    static let deviceName = "iPhone"
    #endif
}
