// Temporary: draws the Mac meeting panel (offer and both countdowns) with ImageRenderer and
// prints each picture as base64 between markers, so it can be looked at from the CI log.
import AppKit
import SwiftUI

@main
struct PanelPreview {
    @MainActor
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        let teams = CallApp(bundleID: "com.microsoft.teams2", name: "Microsoft Teams", isBrowser: false)
        let chrome = CallApp(bundleID: "com.google.Chrome", name: "Google Chrome", isBrowser: true)
        let icon = NSWorkspace.shared.icon(forFile: "/System/Applications/FaceTime.app")
        let views: [(String, AnyView)] = [
            ("offer", AnyView(MeetingPromptView(offer: teams, icon: icon))),
            ("offer-browser", AnyView(MeetingPromptView(offer: chrome))),
            ("goodbye", AnyView(MeetingPromptView(ending: .goodbye(stopAt: Date().addingTimeInterval(15))))),
            ("quiet", AnyView(MeetingPromptView(ending: .quiet(stopAt: Date().addingTimeInterval(90))))),
        ]
        for (name, view) in views {
            for scheme in [ColorScheme.light, .dark] {
                let content = view
                    .padding(20)
                    .background(scheme == .dark ? Color(white: 0.15) : Color(white: 0.85))
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                guard let image = renderer.cgImage else { print("no image for \(name)"); continue }
                let rep = NSBitmapImageRep(cgImage: image)
                guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                let label = "\(name)-\(scheme == .dark ? "dark" : "light")"
                print("=====BEGIN \(label) \(image.width)x\(image.height)")
                let text = png.base64EncodedString()
                var index = text.startIndex
                while index < text.endIndex {
                    let end = text.index(index, offsetBy: 3000, limitedBy: text.endIndex) ?? text.endIndex
                    print(text[index..<end])
                    index = end
                }
                print("=====END \(label)")
            }
        }
    }
}
