import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Shows the Activity Log — what the audio and speech parts are doing — with a Copy button,
/// the log from the previous run (useful after a crash or force-quit), and on the Mac a
/// summary of the last crash report.
struct ActivityLogView: View {
    static let windowID = "activity-log"

    private let feed = ActivityLogFeed.shared
    @State private var session: Which = .current
    #if os(macOS)
    @State private var crash: CrashReports.Report?
    #endif
    @State private var copied = false

    enum Which: String, CaseIterable, Identifiable {
        case current = "This session"
        case previous = "Previous session"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Picker("Session", selection: $session) {
                    ForEach(Which.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    Clipboard.copy(fullText)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
                #if os(macOS)
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ActivityLog.fileURL])
                }
                #endif
            }
            .padding(12)
            Text("Devices, formats, timings and errors — never what anyone said.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(logText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: feed.revision) {
                    if session == .current { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            #if os(macOS)
            if let crash {
                Divider()
                DisclosureGroup("Last crash report — \(crash.date.formatted(date: .abbreviated, time: .shortened))") {
                    ScrollView {
                        Text(crash.summary)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }
                .padding(12)
            }
            #endif
        }
        .navigationTitle("Activity Log")
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 380)
        .task { crash = CrashReports.latest() }
        #endif
    }

    private var logText: String {
        _ = feed.revision  // Refresh when lines arrive.
        switch session {
        case .current:
            let lines = ActivityLog.current
            return lines.isEmpty ? "Nothing yet." : lines.joined(separator: "\n")
        case .previous:
            return ActivityLog.previousRun ?? "No log from a previous session."
        }
    }

    private var fullText: String {
        var parts = ["Sintr Activity Log — \(session.rawValue)", logText]
        #if os(macOS)
        if let crash {
            parts.append("Last crash report (\(crash.date.formatted())):\n\(crash.summary)")
        }
        #endif
        return parts.joined(separator: "\n\n")
    }
}
