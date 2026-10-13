import Foundation

/// Names and defaults for everything kept in UserDefaults.
/// Views read these with @AppStorage(AppSettings.key), other code with AppSettings.value.
enum AppSettings {
    /// BCP-47 language for transcription; empty means the device's language.
    static let language = "transcriptionLanguage"
    /// Keep the audio files after a recording (needed to re-transcribe).
    static let keepRecordings = "keepRecordings"
    /// iPhone: let notes go into iCloud/Finder backups of the phone.
    static let includeInBackups = "includeInBackups"
    /// Mac: record the other side of calls as well as the microphone.
    static let captureCallAudio = "captureCallAudio"
    static let enhanceStyle = "enhanceStyle"
    static let claudeModel = "claudeModel"
    static let phoneModel = "phoneModel"

    static let defaultClaudeModel = "claude-sonnet-5-5"

    static func register() {
        UserDefaults.standard.register(defaults: [
            language: "",
            keepRecordings: true,
            includeInBackups: false,
            captureCallAudio: true,
            enhanceStyle: EnhanceStyle.meeting.rawValue,
            claudeModel: defaultClaudeModel,
            phoneModel: PhoneModelChoice.defaultChoice.rawValue,
        ])
    }

    static var languageID: String { UserDefaults.standard.string(forKey: language) ?? "" }
    static var shouldKeepRecordings: Bool { UserDefaults.standard.bool(forKey: keepRecordings) }
    static var shouldIncludeInBackups: Bool { UserDefaults.standard.bool(forKey: includeInBackups) }
    static var shouldCaptureCallAudio: Bool { UserDefaults.standard.bool(forKey: captureCallAudio) }
    static var claudeModelID: String {
        let value = UserDefaults.standard.string(forKey: claudeModel) ?? ""
        return value.trimmingCharacters(in: .whitespaces).isEmpty ? defaultClaudeModel : value
    }
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
