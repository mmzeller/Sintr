import Foundation

/// Decides where Sintr keeps everything (notes, recordings, downloaded models, settings).
///
/// On the Mac, if a folder named "Sintr Data" sits next to Sintr.app, Sintr runs in
/// portable mode and keeps everything in that folder — so a "Sintr Portable" folder on a
/// thumb drive (or anywhere) carries the app and its notes together.
/// Otherwise (and always on iPhone) it uses the app's normal private folder.
struct StorageLocation: Sendable {
    let root: URL
    let isPortable: Bool
    /// Something the person should know, e.g. macOS blocked the portable folder.
    let warning: String?
}

enum Storage {
    static let dataFolderName = "Sintr Data"

    static let current: StorageLocation = resolve()
    static var root: URL { current.root }
    static var isPortable: Bool { current.isPortable }

    /// This device's normal private folder (Application Support/Sintr).
    static var standardRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sintr", isDirectory: true)
    }

    private static func resolve() -> StorageLocation {
        var warning: String?
        #if os(macOS)
        let fm = FileManager.default
        let app = Bundle.main.bundleURL
        let parent = app.deletingLastPathComponent()
        let portable = parent.appendingPathComponent(dataFolderName, isDirectory: true)

        if app.path.contains("/AppTranslocation/") {
            // macOS runs downloaded apps from a hidden read-only copy until they're "cleared".
            warning = """
                macOS is running Sintr from a temporary copy, so it can't see the “\(dataFolderName)” folder next to it. \
                Your notes aren't lost. Quit Sintr, then in Terminal run:
                xattr -dr com.apple.quarantine "/path/to/Sintr Portable"
                (drag the Sintr Portable folder into Terminal to fill in the path), and open Sintr again.
                For now Sintr is using this Mac's own storage.
                """
        } else {
            var isFolder: ObjCBool = false
            if fm.fileExists(atPath: portable.path, isDirectory: &isFolder), isFolder.boolValue {
                if fm.isWritableFile(atPath: portable.path) {
                    return StorageLocation(root: portable, isPortable: true, warning: nil)
                }
                warning = "Sintr found its “\(dataFolderName)” folder but can't write to it (is the drive locked or read-only?). For now it's using this Mac's own storage."
            } else if !canList(parent) {
                warning = """
                    macOS didn't let Sintr look inside the folder it's running from, so it can't use a “\(dataFolderName)” folder there. \
                    If you're running Sintr from a thumb drive or your Desktop/Documents, open System Settings → Privacy & Security → \
                    Files & Folders → Sintr and turn on access, then reopen Sintr. For now it's using this Mac's own storage.
                    """
            }
        }
        #endif
        return StorageLocation(root: standardRoot, isPortable: false, warning: warning)
    }

    #if os(macOS)
    private static func canList(_ folder: URL) -> Bool {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            return true
        } catch let error as NSError {
            let denied = error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError
            let posixDenied = (error.userInfo[NSUnderlyingErrorKey] as? NSError).map {
                $0.domain == NSPOSIXErrorDomain && ($0.code == Int(EPERM) || $0.code == Int(EACCES))
            } ?? false
            return !(denied || posixDenied)
        }
    }

    /// Where the sandboxed first version of Sintr kept its data. Read once to bring old notes over.
    static var oldSandboxRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/io.github.mmzeller.Sintr/Data/Library/Application Support/Sintr",
                                    isDirectory: true)
    }
    #endif

    /// True for macOS's hidden "._name" companion files on thumb drives formatted exFAT or FAT.
    static func isAppleDouble(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("._")
    }
}

/// In portable mode, settings are saved in "Sintr Data/Settings.plist" so they travel with
/// the notes. (The Claude API key stays in each Mac's Keychain and never goes on the drive.)
enum PortableSettings {
    private static var fileURL: URL { Storage.root.appendingPathComponent("Settings.plist") }
    private static let keys = [
        AppSettings.language, AppSettings.keepRecordings, AppSettings.meetingAudio,
        AppSettings.detectSpeakers, AppSettings.template, AppSettings.glossary,
        AppSettings.translateTarget, AppSettings.translateEngine,
        AppSettings.claudeModel, AppSettings.phoneModel, AppSettings.monitorLevels, AppSettings.removeEcho,
        AppSettings.claudeEffort, AppSettings.askEngine, AppSettings.notesLanguage, AppSettings.allowAIApps,
        AppSettings.localAPI, AppSettings.localAPIPort, AppSettings.integrations,
    ]
    nonisolated(unsafe) private static var observer: NSObjectProtocol?
    nonisolated(unsafe) private static var lastWritten: [String: Any] = [:]

    /// Loads the drive's settings into this Mac's settings, then keeps the file up to date.
    static func start() {
        guard Storage.isPortable, observer == nil else { return }
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for key in keys {
                if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            }
        }
        saveNow()
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in saveNow() }
    }

    static func saveNow() {
        guard Storage.isPortable else { return }
        var values: [String: Any] = [:]
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) { values[key] = value }
        }
        guard !NSDictionary(dictionary: values).isEqual(to: lastWritten) else { return }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0) else { return }
        if (try? data.write(to: fileURL, options: .atomic)) != nil {
            lastWritten = values
        }
    }
}

#if os(macOS)
/// `Sintr --storage-check` (used by the automated tests): shows where Sintr would keep its
/// data, saves and re-reads a throwaway note there, then quits.
@MainActor
enum StorageCheck {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--storage-check") else { return }
        let location = Storage.current
        print("root=\(location.root.path)")
        print("portable=\(location.isPortable)")
        if let warning = location.warning { print("warning=\(warning)") }

        let store = NoteStore()
        let note = store.newNote(title: "Storage check")
        store.saveNow()
        let savedAndReadBack = NoteStore().note(note.id) != nil
        store.delete(note.id)

        PortableSettings.saveNow()
        let settingsFile = location.root.appendingPathComponent("Settings.plist")
        let settingsOK = !location.isPortable || FileManager.default.fileExists(atPath: settingsFile.path)
        print("note=\(savedAndReadBack) settings=\(settingsOK)")
        exit(savedAndReadBack && settingsOK ? 0 : 1)
    }
}
#endif
