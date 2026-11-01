// Compiled with Sintr/Speech/VoiceMatcher.swift, Sintr/AI/NameShield.swift and
// Sintr/Audio/MeetingDetection.swift by scripts/ci-logic-check.sh. Checks the parts of
// "Recognize voices", "Hide people's names from Claude" and meeting detection that decide
// things — which remembered voice a speaker is, which words are names and how they come back,
// and when a call starts and ends.
import Foundation

@main
struct LogicSelfTest {
    static var failures = 0
    static var warnings = 0

    static func check(_ condition: Bool, _ message: String) {
        print(condition ? "✓ \(message)" : "✗ \(message)")
        if !condition { failures += 1 }
    }

    /// For what depends on Apple's language model, which can change between macOS versions.
    static func soft(_ condition: Bool, _ message: String) {
        print(condition ? "✓ \(message)" : "⚠ \(message) (Apple's name finder didn't — not counted as a failure)")
        if !condition { warnings += 1 }
    }

    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        voices()
        names()
        meetings()
        print(failures == 0 ? "\nAll checks passed\(warnings > 0 ? " (\(warnings) warning\(warnings == 1 ? "" : "s"))" : "")." : "\n\(failures) check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Voices

    /// A made-up voice fingerprint: mostly one direction, a little of another.
    static func fingerprint(_ main: Int, _ other: Int, _ amount: Float, size: Int = 32) -> [Float] {
        var v = [Float](repeating: 0.01, count: size)
        v[main] = 1
        v[other] += amount
        return v
    }

    static func voices() {
        print("== Voices")
        let me = KnownVoice(name: "Me", samples: [VoiceSample(print: fingerprint(0, 1, 0.1), confirmed: true)])
        let dana = KnownVoice(name: "Dana", samples: [VoiceSample(print: fingerprint(2, 3, 0.1), confirmed: true)])
        let sam = KnownVoice(name: "Sam", samples: [VoiceSample(print: fingerprint(4, 5, 0.1), confirmed: true)])
        let library = [me, dana, sam]

        let result = VoiceMatcher.assign(
            ["Speaker 1": fingerprint(2, 6, 0.3), "Speaker 2": fingerprint(0, 7, 0.25), "Speaker 3": fingerprint(10, 11, 0.2)],
            to: library)
        check(result["Speaker 1"]?.id == dana.id, "a speaker who sounds like Dana is Dana")
        check(result["Speaker 2"]?.id == me.id, "a speaker who sounds like you is Me")
        check(result["Speaker 3"] == nil, "a new voice gets no name")

        let both = VoiceMatcher.assign(["Speaker 1": fingerprint(2, 3, 0.15), "Speaker 2": fingerprint(2, 8, 0.5)], to: library)
        check(both["Speaker 1"]?.id == dana.id && both["Speaker 2"] == nil,
              "two speakers can't both be Dana — the closer one is")

        let call = VoiceMatcher.assign(["Them 1": fingerprint(0, 1, 0.1)], to: library, allowMe: { !$0.hasPrefix("Them") })
        check(call["Them 1"] == nil, "the other side of a call is never you")

        let taken = VoiceMatcher.assign(["Speaker 1": fingerprint(2, 3, 0.1)], to: library, excluding: [dana.id])
        check(taken["Speaker 1"] == nil, "a name already used in the note isn't given twice")

        // Equally like two remembered voices: too close to call.
        var twin = KnownVoice(name: "Dana's twin", samples: [VoiceSample(print: fingerprint(2, 3, 0.1))])
        twin.id = UUID()
        let unsure = VoiceMatcher.assign(["Speaker 1": fingerprint(2, 3, 0.1)], to: [dana, twin])
        check(unsure["Speaker 1"] == nil, "a voice that fits two people equally well stays unnamed")

        // Samples: same note and speaker replaces; past the limit, unconfirmed ones go first.
        let note = UUID()
        var grown = KnownVoice(name: "Dana", samples: [VoiceSample(print: fingerprint(2, 3, 0.1), added: Date(timeIntervalSince1970: 0), confirmed: true)])
        for i in 1...12 {
            grown = VoiceMatcher.adding(VoiceSample(print: fingerprint(2, 3, 0.1), noteID: UUID(), label: "Speaker 1",
                                                    added: Date(timeIntervalSince1970: Double(i))), to: grown)
        }
        check(grown.samples.count == VoiceMatcher.maxSamples, "keeps at most \(VoiceMatcher.maxSamples) samples")
        check(grown.samples.contains { $0.confirmed }, "keeps the sample you named over ones Sintr recognized")
        grown = VoiceMatcher.adding(VoiceSample(print: fingerprint(2, 3, 0.2), noteID: note, label: "Speaker 2"), to: grown)
        grown = VoiceMatcher.adding(VoiceSample(print: fingerprint(2, 3, 0.3), noteID: note, label: "Speaker 2"), to: grown)
        check(grown.samples.filter { $0.noteID == note }.count == 1, "one sample per speaker per note")

        check(VoiceMatcher.isGenericLabel("Speaker 2") && VoiceMatcher.isGenericLabel("Them")
              && VoiceMatcher.isGenericLabel("them 3") && VoiceMatcher.isGenericLabel(" "), "Sintr's own labels aren't names")
        check(!VoiceMatcher.isGenericLabel("Dana") && !VoiceMatcher.isGenericLabel("Me"), "real names are names")
        check(VoiceMatcher.isMe(" me ") && !VoiceMatcher.isMe("Mel"), "“me” is you, “Mel” isn't")

        // Saved and read back, including from a file missing newer fields.
        let encoded = try? JSONEncoder().encode([dana])
        let decoded = encoded.flatMap { try? JSONDecoder().decode([KnownVoice].self, from: $0) }
        check(decoded?.first?.name == "Dana" && decoded?.first?.samples.count == 1, "voices save and load")
        let old = #"[{"name":"Sam","samples":[{"print":[1,0,0]}]}]"#.data(using: .utf8)!
        check((try? JSONDecoder().decode([KnownVoice].self, from: old))?.first?.samples.first?.print.count == 3,
              "reads a voices file with missing fields")
    }

    // MARK: Names

    static func names() {
        print("== Names")
        let text = """
            Dana Whitfield said Dana's budget is fine and Sam agreed.
            [12:03] Me: I will send the report to Dayna Whitfield tomorrow.
            [12:04] Speaker 2: Thanks, Claude can draft it. Them 1 agreed.
            """
        let mask = NameMask(known: ["Dana Whitfield", "Sam", "Me", "Speaker 2"], texts: [text])
        let masked = mask.mask(text)
        Swift.print("   masked: \(masked.replacingOccurrences(of: "\n", with: " ⏎ "))")
        check(!masked.contains("Dana") && !masked.contains("Sam "), "known names are hidden (full name, first name, possessive)")
        check(masked.contains("\(mask.placeholder(1))'s budget"), "a possessive keeps its 's")
        check(masked.contains("Me:") && masked.contains("Speaker 2:") && masked.contains("Claude") && masked.contains("Them 1"),
              "Me, speaker labels and Claude stay as they are")
        check(masked.contains("I will send"), "the word “will” isn't touched")
        soft(!masked.contains("Dayna"), "a misheard spelling of Dana is found")
        let restored = mask.unmask(masked)
        check(restored.contains("Dana Whitfield said") && restored.contains("Sam agreed"), "names come back")
        check(!restored.contains(mask.placeholder(1)), "no placeholder left behind")
        if !masked.contains("Dayna") {
            check(restored.contains("report to Dana Whitfield"), "the misheard name comes back spelled right")
        }

        // A known name that's also a word.
        let will = NameMask(known: ["Will"], texts: ["Will said he will call."], detect: false)
        check(will.mask("Will said he will call.") == "\(will.placeholder(1)) said he will call.",
              "a name that's also a word is only hidden where it's the name")

        // Placeholders Claude might write slightly differently.
        let one = NameMask(known: ["Dana Whitfield"], texts: ["Dana Whitfield"], detect: false)
        for variant in ["Person_1", "person_1", "Person 1", "PERSON_1", "Person1"] {
            check(one.unmask("Ask \(variant) today") == "Ask Dana Whitfield today", "“\(variant)” comes back as the name")
        }
        check(one.unmask("Person_12 and Person_2") == "Person_12 and Person_2", "an unknown placeholder is left alone")

        // A reply that's still arriving.
        check(one.unmaskPartial("Thanks Pers") == "Thanks ", "a placeholder cut off at the end waits")
        check(one.unmaskPartial("Thanks Person_1") == "Thanks ", "…even when it looks complete")
        check(one.unmaskPartial("Thanks Person_1, see") == "Thanks Dana Whitfield, see", "…and shows once more arrives")
        check(one.unmaskPartial("Next step") == "Next step", "an ordinary word ending isn't held back")

        // The text already says "Person 2".
        let busy = NameMask(known: ["Dana"], texts: ["Dana met Person 2."], detect: false)
        check(busy.word != "Person" && busy.mask("Dana met Person 2.").contains("Person 2"),
              "placeholders don't clash with “Person 2” already in the text")

        // Names Apple's language model finds on its own.
        let found = NameMask(known: [], texts: ["Yesterday Michael Johnson met Sarah Williams in Chicago."])
        let hidden = found.mask("Yesterday Michael Johnson met Sarah Williams in Chicago.")
        Swift.print("   found: \(hidden)")
        soft(!hidden.contains("Michael") && !hidden.contains("Sarah"), "finds names nobody told it about")
        check(hidden.contains("Chicago"), "places aren't hidden")
        check(NameMask(known: [], texts: ["Nothing personal here."], detect: false).isEmpty, "no names, nothing to do")
        check(NameMask.similarity("dayna whitfield", "dana whitfield") >= 0.8 && NameMask.similarity("dana", "sam") < 0.5,
              "spelling similarity")
    }

    // MARK: Meetings

    static func meetings() {
        print("== Meetings")
        let zoom = CallApp(bundleID: "us.zoom.xos", name: "Zoom", isBrowser: false)
        let chrome = CallApp(bundleID: "com.google.Chrome", name: "Google Chrome", isBrowser: true)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

        var d = MeetingDetection()
        d.update([chrome], now: at(0))
        d.update([chrome, zoom], now: at(1))
        check(d.offer(now: at(2)) == nil, "a microphone blip isn't a call")
        check(d.offer(now: at(6)) == zoom, "a call app is offered before a browser")
        d.dismiss(zoom.bundleID)
        check(d.offer(now: at(7)) == chrome, "after “Not now” for Zoom, the browser call is offered")
        d.dismiss(chrome.bundleID)
        check(d.offer(now: at(8)) == nil, "“Not now” for both: nothing offered")
        d.update([chrome], now: at(20))
        check(!d.hasEnded(zoom.bundleID, now: at(25)), "the call isn't over the moment Zoom lets go")
        check(d.hasEnded(zoom.bundleID, now: at(30)), "…but is after the grace period")
        d.update([chrome], now: at(31))
        d.update([chrome, zoom], now: at(40))
        check(d.offer(now: at(45)) == zoom, "the next Zoom call is offered again")
        check(d.isActive(zoom.bundleID) && !d.hasEnded(zoom.bundleID, now: at(45)), "a call that's back isn't over")
        d.ignored = [zoom.bundleID]
        check(d.offer(now: at(46)) == nil, "never offered for an app you turned off (the browser is still “Not now”)")
        check(d.activeApp(now: at(46)) == zoom, "the call going on is still known (for stopping later)")

        // Which app a process belongs to.
        let helper = CallApps.identify(bundleID: "com.google.Chrome.helper", responsibleBundleID: "com.google.Chrome",
                                       path: "/Applications/Google Chrome.app/Contents/Frameworks/x/Google Chrome Helper")
        check(helper?.bundleID == "com.google.Chrome" && helper?.isBrowser == true, "Chrome's helper is a call in Chrome")
        check(CallApps.identify(bundleID: "", responsibleBundleID: nil, path: "/usr/libexec/avconferenced")?.name == "FaceTime",
              "FaceTime's call helper is FaceTime")
        check(CallApps.identify(bundleID: "com.apple.WebKit.GPU", responsibleBundleID: "com.apple.Safari", path: "")?.name == "Safari",
              "Safari's media process is Safari")
        check(CallApps.identify(bundleID: "com.apple.WebKit.GPU", responsibleBundleID: "com.apple.mail", path: "") == nil,
              "Mail's media process isn't a call")
        check(CallApps.identify(bundleID: "com.apple.VoiceMemos", responsibleBundleID: nil, path: "") == nil,
              "Voice Memos isn't a call")
        check(CallApps.identify(bundleID: "com.microsoft.teams2", responsibleBundleID: "com.microsoft.teams2", path: "")?.title == "Microsoft Teams call",
              "a Teams note is called “Microsoft Teams call”")

        // Goodbyes.
        check(CallEnding.soundsLikeGoodbye("Okay, I think that's everything. Thanks everyone, bye!"), "“Thanks everyone, bye!”")
        check(CallEnding.soundsLikeGoodbye("Sounds good. Talk to you later."), "“Talk to you later.”")
        check(CallEnding.soundsLikeGoodbye("Perfekt, tschüss!"), "“Tschüss!”")
        check(!CallEnding.soundsLikeGoodbye("Let's move on to the next item on the agenda."), "the next agenda item isn't goodbye")
        check(!CallEnding.soundsLikeGoodbye("We'll stand by for the update."), "“stand by” isn't “bye”")
        let long = "bye " + String(repeating: "and then we talked about the budget ", count: 20)
        check(!CallEnding.soundsLikeGoodbye(long), "only the last words count")
    }
}
