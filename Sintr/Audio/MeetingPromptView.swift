#if os(macOS)
import AppKit
import SwiftUI

/// What the meeting panel says: "Zoom call — take notes?", or "Sintr stops recording in 12 s".
/// Only data and buttons, so the automated checks can draw it on its own.
struct MeetingPromptView: View {
    var offer: CallApp?
    var ending: StopCountdown?
    /// The call app's icon.
    var icon: NSImage?
    var takeNotes: () -> Void = {}
    var notNow: () -> Void = {}
    var neverOffer: () -> Void = {}
    var keepRecording: () -> Void = {}
    var stopNow: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let ending {
                endingContent(ending)
            } else if let offer {
                offerContent(offer)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func offerContent(_ app: CallApp) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 32, height: 32)
            } else {
                Image(systemName: "phone.circle.fill").font(.largeTitle).foregroundStyle(.green)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(app.title).font(.headline)
                Text("Take notes with Sintr? It records your microphone and the call, and transcribes on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        HStack(spacing: 8) {
            Button(action: takeNotes) {
                Label("Take notes", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            Button("Not now", action: notNow)
            Spacer(minLength: 0)
            Button("Never for \(app.name)", action: neverOffer)
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func endingContent(_ ending: StopCountdown) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(ending.stopAt.timeIntervalSince(context.date).rounded(.up)))
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "stop.circle")
                        .font(.title2)
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ending.isGoodbye ? "The call has ended" : "Nothing heard for \(Int(CallEnding.quietLimit / 60)) minutes")
                            .font(.headline)
                        Text("Sintr stops recording in \(left) s. Your notes and transcript are kept.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 8) {
                    Button("Keep recording", action: keepRecording)
                        .buttonStyle(.borderedProminent)
                    Button("Stop now", action: stopNow)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
#endif
