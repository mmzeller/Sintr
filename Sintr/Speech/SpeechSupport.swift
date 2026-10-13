import Foundation
import Speech

/// Apple's on-device speech model: which languages it handles here, and its one-time download.
enum SpeechSupport {
    /// False on devices too old for Apple's new speech model (iPhone 11 and earlier).
    static var deviceSupported: Bool { SpeechTranscriber.isAvailable }

    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
            .sorted { displayName($0) < displayName($1) }
    }

    static func displayName(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// The supported language closest to the one chosen in Settings (or the device language).
    static func resolvedLocale() async -> Locale? {
        let id = AppSettings.languageID
        let wanted = id.isEmpty ? Locale.current : Locale(identifier: id)
        let supported = await SpeechTranscriber.supportedLocales
        if let exact = supported.first(where: { same($0, wanted) }) { return exact }
        let language = wanted.language.languageCode?.identifier
        let region = wanted.region?.identifier
        let sameLanguage = supported.filter { $0.language.languageCode?.identifier == language }
        return sameLanguage.first { $0.region?.identifier == region }
            ?? sameLanguage.first { $0.region?.identifier == "US" }
            ?? sameLanguage.first
    }

    static func isInstalled(_ locale: Locale) async -> Bool {
        await SpeechTranscriber.installedLocales.contains { same($0, locale) }
    }

    /// Downloads Apple's speech model for `locale` if it isn't on the device yet.
    /// This is the only network use in transcription, and it comes from Apple, not from your notes.
    static func install(_ locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { same($0, locale) }) {
            // There's a limit on how many languages an app can reserve; make room.
            for other in reserved {
                _ = await AssetInventory.release(reservedLocale: other)
            }
            _ = try await AssetInventory.reserve(locale: locale)
        }
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return  // already installed
        }
        let watcher = Task {
            while !Task.isCancelled && !request.progress.isFinished {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { watcher.cancel() }
        try await request.downloadAndInstall()
        progress(1)
    }

    private static func same(_ a: Locale, _ b: Locale) -> Bool {
        a.identifier(.bcp47) == b.identifier(.bcp47)
    }
}

enum SpeechError: LocalizedError {
    case deviceNotSupported
    case languageNotSupported
    case noAudioFormat
    case microphoneDenied
    case noMicrophone

    var errorDescription: String? {
        switch self {
        case .deviceNotSupported:
            "This device can't run Apple's on-device speech model (it needs an iPhone 12 or newer, or a Mac with Apple silicon)."
        case .languageNotSupported:
            "Apple's speech model doesn't support the language you chose. Pick another one in Settings → Transcription."
        case .noAudioFormat:
            "The speech model didn't report an audio format it can use."
        case .microphoneDenied:
            "Sintr isn't allowed to use the microphone. Turn it on in Settings → Privacy & Security → Microphone."
        case .noMicrophone:
            "No microphone was found."
        }
    }
}
