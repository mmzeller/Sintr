import Foundation

extension Notification.Name {
    /// Templates or settings were replaced by an imported setup.
    static let sintrSetupImported = Notification.Name("SintrSetupImported")
}

/// "Share your setup": a file a team passes around so everyone's Sintr works the same way —
/// templates, names and terms, recording defaults, the notes language, the AI choices and the
/// integration targets. Never keys, tokens or notes. No accounts or admin console needed:
/// whoever keeps the file up to date manages the team's setup.
struct SetupProfile: Codable {
    var app = "Sintr"
    var kind = "setup"
    var formatVersion = 1
    var exported = Date()
    var templates: [NoteTemplate] = []
    var settings: [String: String] = [:]
    var switches: [String: Bool] = [:]
    var integrations: [String: IntegrationConfig] = [:]

    private static let textKeys = [
        AppSettings.language, AppSettings.meetingAudio, AppSettings.glossary, AppSettings.template,
        AppSettings.notesLanguage, AppSettings.claudeModel, AppSettings.claudeEffort, AppSettings.askEngine,
        AppSettings.translateTarget, AppSettings.translateEngine,
    ]
    private static let switchKeys = [
        AppSettings.detectSpeakers, AppSettings.keepRecordings, AppSettings.removeEcho,
    ]

    static func current(templates: [NoteTemplate]) -> SetupProfile {
        var profile = SetupProfile()
        profile.templates = templates
        let defaults = UserDefaults.standard
        for key in textKeys { if let value = defaults.string(forKey: key) { profile.settings[key] = value } }
        for key in switchKeys { profile.switches[key] = defaults.bool(forKey: key) }
        profile.integrations = IntegrationSettings.load()
        return profile
    }

    /// Writes the profile to a temporary file to share.
    static func exportFile(templates: [NoteTemplate]) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Sintr setup.json")
        guard let data = try? NoteArchive.encoder.encode(current(templates: templates)) else { return nil }
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }

    static func decode(_ data: Data) -> SetupProfile? {
        guard let profile = try? NoteArchive.decoder.decode(SetupProfile.self, from: data),
              profile.app == "Sintr", profile.kind == "setup" else { return nil }
        return profile
    }

    /// Applies the profile on this device and says what changed.
    func apply() -> String {
        let defaults = UserDefaults.standard
        for (key, value) in settings where Self.textKeys.contains(key) { defaults.set(value, forKey: key) }
        for (key, value) in switches where Self.switchKeys.contains(key) { defaults.set(value, forKey: key) }
        // Integration targets and options; keys stay whatever this device already has.
        for (name, config) in integrations {
            if let kind = IntegrationKind(rawValue: name) { IntegrationSettings.save(config, for: kind) }
        }
        // Templates: same ID replaces, new ones are added, the person's other templates stay.
        let file = Storage.root.appendingPathComponent("Templates.json")
        var saved = (try? JSONDecoder().decode([NoteTemplate].self, from: Data(contentsOf: file))) ?? NoteTemplate.builtIns
        for template in templates {
            if let index = saved.firstIndex(where: { $0.id == template.id }) {
                saved[index] = template
            } else {
                saved.append(template)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(saved) { try? data.write(to: file, options: .atomic) }
        NotificationCenter.default.post(name: .sintrSetupImported, object: nil)
        return "Setup imported: \(templates.count) templates, \(settings.count + switches.count) settings, \(integrations.count) integration targets. Add your own keys in Settings → Integrations."
    }
}
