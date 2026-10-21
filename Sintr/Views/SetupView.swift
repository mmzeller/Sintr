import AVFoundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Microphone permission, in one place for both platforms.
enum MicPermission {
    enum Status { case allowed, denied, notAsked }

    static var status: Status {
        #if os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .allowed
        case .notDetermined: return .notAsked
        default: return .denied
        }
        #else
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .allowed
        case .undetermined: return .notAsked
        default: return .denied
        }
        #endif
    }

    @MainActor static func openSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #endif
    }
}

/// "Let Sintr transcribe your meetings": everything recording needs, on one screen —
/// shown the first time Sintr opens, and any time from ⋯ → Set Up Recording….
struct SetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AudioHub.self) private var hub
    @AppStorage(AppSettings.setupDone) private var setupDone = false
    @AppStorage(AppSettings.meetingAudio) private var meetingRaw = MeetingAudio.allAudio.rawValue
    @AppStorage(AppSettings.detectSpeakers) private var detectSpeakers = true

    @State private var mic = MicPermission.status
    #if os(macOS)
    @State private var callAudio = SystemAudioPermission.status
    #endif
    @State private var locale: Locale?
    @State private var speechInstalled: Bool?
    @State private var speechProgress: Double?
    @State private var speakerInstalled = SpeakerDetector.isInstalled
    @State private var speakerProgress: Double?
    @State private var problem: String?

    private var meetingOn: Bool { (MeetingAudio(rawValue: meetingRaw) ?? .allAudio).isOn }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Let Sintr transcribe your meetings")
                        .font(.largeTitle.weight(.semibold))
                        .fontDesign(.serif)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Platform.isMac
                         ? "Sintr listens to your Mac's microphone and the audio it plays, and writes the transcript on this Mac. Nothing is uploaded, and no bot joins your meeting."
                         : "Sintr listens with the iPhone's microphone and writes the transcript on the iPhone. Nothing is uploaded, and no bot joins your meeting.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 0) {
                    SetupRow(title: "Transcribe my voice", detail: "Your microphone.") { micControl }
                    #if os(macOS)
                    Divider()
                    SetupRow(title: "Transcribe other people's voices",
                             detail: "The other side of Teams, Zoom, FaceTime, Meet — whatever your Mac plays.") { callControl }
                    #endif
                    Divider()
                    SetupRow(title: "Transcribe on this \(Platform.deviceName)",
                             detail: "Apple's speech model for \(locale.map(SpeechSupport.displayName) ?? "your language") — a one-time download from Apple.") { speechControl }
                    Divider()
                    SetupRow(title: "See who's speaking",
                             detail: "Tells voices apart on this \(Platform.deviceName): Me and Them on calls, Speaker 1, 2… in person. Click a label to put a name to it. A one-time download of a few dozen MB.") { speakerControl }
                }
                .background(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))

                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }

                HStack {
                    Button("Later") { finish() }
                        .buttonStyle(.borderless)
                    Spacer()
                    Button("Continue") { finish() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(mic != .allowed)
                }
            }
            .padding(Platform.isMac ? 32 : 20)
        }
        #if os(macOS)
        .frame(width: 600, height: 640)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        #else
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refresh() }
        #endif
        .task {
            refresh()
            locale = await SpeechSupport.resolvedLocale()
            if let locale { speechInstalled = await SpeechSupport.isInstalled(locale) }
        }
        .interactiveDismissDisabled(speechProgress != nil || speakerProgress != nil)
    }

    // MARK: Controls

    @ViewBuilder private var micControl: some View {
        switch mic {
        case .allowed:
            EnabledBadge()
        case .notAsked:
            Button("Allow") {
                Task {
                    _ = await MicCapture.requestPermission()
                    refresh()
                }
            }
            .buttonStyle(.borderedProminent)
        case .denied:
            Button("Open Settings") { MicPermission.openSettings() }
                .help("Turn on Sintr under Privacy & Security → Microphone.")
        }
    }

    #if os(macOS)
    @ViewBuilder private var callControl: some View {
        if !meetingOn {
            Button("Turn on") {
                meetingRaw = MeetingAudio.allAudio.rawValue
                askForCallAudio()
            }
            .buttonStyle(.borderedProminent)
        } else if callAudio == .allowed {
            EnabledBadge()
        } else if callAudio == .denied {
            Button("Open Settings") { SystemAudioPermission.openSettings() }
                .help("Turn on Sintr in \(SystemAudioPermission.settingsPath).")
        } else {
            Button("Allow") { askForCallAudio() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func askForCallAudio() {
        Task {
            let allowed = await SystemAudioPermission.request()
            refresh()
            if !allowed, callAudio != .allowed {
                problem = "macOS didn't allow call audio. Turn on Sintr in \(SystemAudioPermission.settingsPath)."
            }
        }
    }
    #endif

    @ViewBuilder private var speechControl: some View {
        if !SpeechSupport.deviceSupported {
            Text("Not supported here").font(.callout).foregroundStyle(.secondary)
        } else if let speechProgress {
            ProgressView(value: speechProgress).frame(width: 110)
        } else if speechInstalled == true {
            EnabledBadge()
        } else if speechInstalled == false, let locale {
            Button("Download") {
                speechProgress = 0
                Task {
                    do {
                        try await SpeechSupport.install(locale) { value in
                            Task { @MainActor in speechProgress = value }
                        }
                        speechInstalled = true
                    } catch {
                        problem = "The speech model didn't download: \(error.localizedDescription)"
                    }
                    speechProgress = nil
                }
            }
            .buttonStyle(.borderedProminent)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder private var speakerControl: some View {
        if !SpeakerDetector.isAvailable {
            Text("Not in this build").font(.callout).foregroundStyle(.secondary)
        } else if let speakerProgress {
            ProgressView(value: speakerProgress).frame(width: 110)
        } else if speakerInstalled && detectSpeakers {
            EnabledBadge()
        } else if speakerInstalled {
            Button("Turn on") { detectSpeakers = true }
                .buttonStyle(.borderedProminent)
        } else {
            Button("Download") {
                speakerProgress = 0
                Task {
                    do {
                        try await SpeakerDetector.download { value in
                            Task { @MainActor in speakerProgress = value }
                        }
                        speakerInstalled = true
                        detectSpeakers = true
                    } catch {
                        problem = "Speaker detection didn't download: \(error.localizedDescription)"
                    }
                    speakerProgress = nil
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func refresh() {
        mic = MicPermission.status
        #if os(macOS)
        callAudio = SystemAudioPermission.status
        #endif
        speakerInstalled = SpeakerDetector.isInstalled
    }

    private func finish() {
        setupDone = true
        dismiss()
        Task { await hub.startMonitoringIfWanted() }
    }
}

/// One requirement: what it is on the left, its status or button on the right — or, on an
/// iPhone (and with larger text anywhere), the button underneath, so nothing gets squeezed.
private struct SetupRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let control: Control

    @Environment(\.dynamicTypeSize) private var typeSize

    private var stacked: Bool {
        #if os(iOS)
        return true
        #else
        return typeSize >= .xxLarge
        #endif
    }

    var body: some View {
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        layout {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
                .fixedSize()
        }
        .padding(.horizontal, stacked ? 16 : 18)
        .padding(.vertical, 16)
    }
}

private struct EnabledBadge: View {
    var body: some View {
        Label("Enabled", systemImage: "checkmark")
            .font(.callout.weight(.medium))
            .foregroundStyle(.green)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.green.opacity(0.14), in: Capsule())
    }
}
