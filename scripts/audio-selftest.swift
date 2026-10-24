// Compiled with Sintr/Audio/AudioProcesses.swift by scripts/ci-audio-check.sh. Checks that Sintr
// can tell which processes belong to an app on this Mac — including the helpers that really
// play the sound, like Safari's "Graphics and Media" (WebKit GPU) process.
import CoreAudio
import Darwin
import Foundation

@main
struct AudioSelfTest {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        print(condition ? "✓ \(message)" : "✗ \(message)")
        if !condition { failures += 1 }
    }

    static func main() throws {
        setvbuf(stdout, nil, _IONBF, 0)

        // MARK: Which processes belong to which app (sample cases)
        let safari = AppTarget(bundleID: "com.apple.Safari", bundleName: "Safari.app", name: "Safari")
        let chrome = AppTarget(bundleID: "com.google.Chrome", bundleName: "Google Chrome.app", name: "Google Chrome")
        let faceTime = AppTarget(bundleID: "com.apple.FaceTime", bundleName: "FaceTime.app", name: "FaceTime")
        let safariMain = AudioProcesses.Entry(
            object: 1, pid: 400, bundleID: "com.apple.Safari",
            path: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari", responsible: 400)
        let safariMedia = AudioProcesses.Entry(
            object: 2, pid: 500, bundleID: "com.apple.WebKit.GPU",
            path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU",
            responsible: 400)
        let mailMedia = AudioProcesses.Entry(
            object: 3, pid: 510, bundleID: "com.apple.WebKit.GPU",
            path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU",
            responsible: 600)
        let chromeHelper = AudioProcesses.Entry(
            object: 4, pid: 710, bundleID: "com.google.Chrome.helper",
            path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
            responsible: 700)
        let music = AudioProcesses.Entry(
            object: 5, pid: 800, bundleID: "com.apple.Music",
            path: "/System/Applications/Music.app/Contents/MacOS/Music", responsible: 800)
        let avconferenced = AudioProcesses.Entry(
            object: 6, pid: 900, bundleID: "", path: "/usr/libexec/avconferenced", responsible: 1)

        let safariPIDs: Set<pid_t> = [400]
        check(AudioProcesses.belongs(safariMain, to: safari, appPIDs: safariPIDs, responsibleKnown: true),
              "Safari itself, running from the system volume")
        check(AudioProcesses.belongs(safariMedia, to: safari, appPIDs: safariPIDs, responsibleKnown: true),
              "Safari Graphics and Media (plays YouTube)")
        check(!AudioProcesses.belongs(mailMedia, to: safari, appPIDs: safariPIDs, responsibleKnown: true),
              "not Mail's media process")
        check(AudioProcesses.belongs(safariMedia, to: safari, appPIDs: safariPIDs, responsibleKnown: false),
              "Safari's media process even without the responsible-process lookup")
        check(AudioProcesses.belongs(chromeHelper, to: chrome, appPIDs: [700], responsibleKnown: true),
              "Chrome's helper")
        check(!AudioProcesses.belongs(music, to: safari, appPIDs: safariPIDs, responsibleKnown: true), "not Music")
        check(!AudioProcesses.belongs(safariMedia, to: chrome, appPIDs: [700], responsibleKnown: true),
              "not Safari's media process for Chrome")
        check(AudioProcesses.belongs(avconferenced, to: faceTime, appPIDs: [], responsibleKnown: true),
              "FaceTime's call audio helper")
        check(!AudioProcesses.belongs(avconferenced, to: safari, appPIDs: safariPIDs, responsibleKnown: true),
              "not FaceTime's helper for Safari")

        // MARK: This Mac's real lookups
        check(AudioProcesses.canFindResponsible, "this macOS has the responsible-process lookup")
        let me = getpid()
        let myResponsible = AudioProcesses.responsiblePID(me)
        check((myResponsible ?? 0) > 0, "responsible process for this test: \(myResponsible.map(String.init) ?? "none")")

        // A helper app bundle of our own, with a copy of /bin/sleep inside.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SintrAudioTest-\(me)")
        let macOS = folder.appendingPathComponent("Fake Player.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let binary = macOS.appendingPathComponent("Fake Player")
        try? FileManager.default.removeItem(at: binary)
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: binary.path)
        let child = Foundation.Process()
        child.executableURL = binary
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate(); try? FileManager.default.removeItem(at: folder) }
        Thread.sleep(forTimeInterval: 0.3)
        let fake = AppTarget(bundleID: "test.fake.player", bundleName: "Fake Player.app", name: "Fake Player")
        let inside = AudioProcesses.pids(inside: fake)
        check(inside.contains(child.processIdentifier), "finds a process by its app bundle (\(inside.sorted()))")
        check(AudioProcesses.executablePath(child.processIdentifier)?.contains("/Fake Player.app/Contents/") == true,
              "reads a process's executable path")
        if let mine = myResponsible {
            check(AudioProcesses.responsiblePID(child.processIdentifier) == mine,
                  "a child process has the same responsible process as its parent")
        }

        // The private calls Sintr uses to check and ask for "System Audio Recording" permission.
        // Without them Sintr still works (it records and watches for silence), so this warns.
        let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
        let tccOK = tcc != nil && dlsym(tcc, "TCCAccessPreflight") != nil && dlsym(tcc, "TCCAccessRequest") != nil
        if tccOK {
            print("✓ the system-audio permission check is available")
        } else {
            print("⚠ the system-audio permission check isn't available on this macOS; Sintr falls back to watching for silence")
            if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil {
                print("::warning title=Permission check::TCCAccessPreflight/TCCAccessRequest not found on this macOS")
            }
        }

        let audio = AudioProcesses.processes()
        print("Processes registered with Core Audio here: \(audio.count) — \(AudioProcesses.describe(Array(audio.prefix(12))))")
        check(true, "lists Core Audio's processes without errors")

        print(failures == 0 ? "All audio checks passed." : "\(failures) audio check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
