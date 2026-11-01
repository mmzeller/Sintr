import Foundation

/// The names Sintr knows are people, for `NameMask`.
@MainActor
enum NameShield {
    static var isOn: Bool { AppSettings.shouldHideNames }

    /// Speaker names in your notes, the voices Sintr remembers, and your own name.
    static func people(in store: NoteStore?) -> [String] {
        guard isOn else { return [] }
        var names: [String] = []
        for note in store?.notes ?? [] { names += note.speakerNames.values }
        names += VoiceLibrary.shared.voices.map(\.name)
        names += IntegrationSettings.config(.sectis).target
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        #if os(macOS)
        names.append(NSFullUserName())
        #endif
        return names
    }
}
