// Compiled with Sintr/Transfer/SectisFormat.swift and SectisCloud.swift by scripts/ci-sectis-check.sh:
//   sectis-selftest <fixture.json> <out.json>
// Reads a join code and a record that Sectis's own code made, checks Sintr reads both,
// encrypts a to-do for Sectis to read back, and checks the action-item reader on sample notes.
// With FIRESTORE_EMULATOR_HOST set (inside `firebase emulators:exec`), it also writes a tag and
// to-dos through the Firestore emulator running Sectis's rules, for sectis-check.mjs to read.
import Foundation

@main
struct SectisSelfTest {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        print(condition ? "✓ \(message)" : "✗ \(message)")
        if !condition { failures += 1 }
    }

    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)   // keep every line even if something crashes
        let args = CommandLine.arguments
        guard args.count == 3 else { print("usage: sectis-selftest <fixture.json> <out.json>"); exit(2) }
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [String: Any]

        // MARK: Join code, space, key
        let link = SectisFormat.parseJoinCode(fixture["joinCode"] as! String)
        check(link != nil, "reads a Sectis join code (with a line break and URL-safe characters)")
        guard let link else { exit(1) }
        check(link.apiKey == fixture["apiKey"] as? String, "API key from the code")
        check(link.projectId == fixture["projectId"] as? String, "project from the code")
        check(link.key == fixture["key"] as? String, "sync key from the code")
        check(SectisFormat.parseJoinCode("SECTIS-nonsense") == nil, "rejects a broken code")
        check(SectisFormat.parseJoinCode("") == nil, "rejects an empty code")

        let space = SectisFormat.space(for: link.key)
        check(space == fixture["space"] as? String, "same space as Sectis: \(space)")
        let started = Date()
        guard let key = SectisFormat.encryptionKey(for: link.key) else { check(false, "derives the key"); exit(1) }
        check(key.count == 32, "derives a 256-bit key in \(Int(Date().timeIntervalSince(started) * 1000)) ms")

        // MARK: Sectis → Sintr
        let tag = try? SectisFormat.decrypt(c: fixture["tagC"] as! String, iv: fixture["tagIv"] as! String, key: key)
        check(tag?["title"] as? String == "Meeting Ü ✓", "decrypts a tag Sectis encrypted")
        check(tag?["id"] as? String == "tag123", "tag id")

        // MARK: Sintr → Sectis (checked by sectis-check.mjs verify)
        let id = SectisFormat.itemID(noteID: "B1A2C3D4-0000-4000-8000-000000000001", title: "Send the budget — café ✓")
        check(id == SectisFormat.itemID(noteID: "B1A2C3D4-0000-4000-8000-000000000001", title: "send the budget, cafe"),
              "same item id when only case, accents or punctuation change")
        check(id != SectisFormat.itemID(noteID: "B1A2C3D4-0000-4000-8000-000000000002", title: "Send the budget — café ✓"),
              "different notes give different ids")
        let notes = "From “Weekly sync”, Oct 22, 2026 (Sintr)\n“Send the budget — Me, by Friday”\n• with the \"final\" numbers / v2"
        let record = SectisFormat.todoRecord(id: id, title: "Send the budget — café ✓", notes: notes, deadline: "2026-10-23",
                                             tags: ["tag123"], order: -1_761_134_400.002, now: Date())
        let sealed = try SectisFormat.encrypt(record, key: key)
        let roundTrip = try SectisFormat.decrypt(c: sealed.c, iv: sealed.iv, key: key)
        check(roundTrip["title"] as? String == "Send the budget — café ✓", "decrypts its own to-do")
        let out: [String: Any] = [
            "space": space, "c": sealed.c, "iv": sealed.iv,
            "expected": ["id": id, "title": "Send the budget — café ✓", "notes": notes, "deadline": "2026-10-23"],
        ]
        try JSONSerialization.data(withJSONObject: out).write(to: URL(fileURLWithPath: args[2]))

        // MARK: Action items
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Indiana/Indianapolis")!
        calendar.firstWeekday = 1
        // Thursday, October 22, 2026, 10:00
        let meeting = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 10))!
        let names = ActionItemParser.names(["Matthew Zeller", "Matt"])
        check(names == ["matthew zeller", "matthew", "matt"], "names: \(names.sorted())")

        func due(_ text: String) -> String? { ActionItemParser.dueDate(in: text, meetingDate: meeting, calendar: calendar) }
        let dates: [(String, String?)] = [
            ("Friday", "2026-10-23"), ("by Fri", "2026-10-23"), ("next Friday", "2026-10-30"), ("next Monday", "2026-10-26"),
            ("Thursday", "2026-10-29"), ("tomorrow", "2026-10-23"), ("today", "2026-10-22"), ("EOD", "2026-10-22"),
            ("end of week", "2026-10-23"), ("EOM", "2026-10-31"), ("Oct 31", "2026-10-31"), ("October 31st", "2026-10-31"),
            ("31 Oct", "2026-10-31"), ("10/31", "2026-10-31"), ("11/15/26", "2026-11-15"), ("2026-11-02", "2026-11-02"),
            ("Jan 5", "2027-01-05"), ("Oct 1", nil), ("next week", nil), ("Dana", nil), ("May", nil), ("Feb 30", nil),
            ("Me", nil), ("Wednesday", "2026-10-28"), ("weds", "2026-10-28"), ("thurs", "2026-10-29"),
        ]
        for (text, expected) in dates {
            check(due(text) == expected, "due “\(text)” → \(expected ?? "none") (got \(due(text) ?? "none"))")
        }

        check(ActionItemParser.ownerIncludesMe("Dana and me", names: names), "owner “Dana and me” includes you")
        check(ActionItemParser.ownerIncludesMe("@matt", names: names), "owner “@matt” is you")
        check(ActionItemParser.ownerIncludesMe("Matthew Z.", names: names), "owner “Matthew Z.” is you")
        check(ActionItemParser.ownerIncludesMe("Matt's", names: names), "owner “Matt's” is you")
        check(!ActionItemParser.ownerIncludesMe("Dana", names: names), "owner “Dana” isn't you")
        check(!ActionItemParser.ownerIncludesMe("Matthias", names: names), "owner “Matthias” isn't you")

        func mine(_ markdown: String, solo: Bool) -> [ActionItem] {
            ActionItemParser.items(in: markdown, names: names, meetingDate: meeting, calendar: calendar)
                .filter { ActionItemParser.isMine($0, names: names, solo: solo) }
        }
        func expect(_ label: String, _ markdown: String, solo: Bool, _ expected: [(String, String?)]) {
            let got = mine(markdown, solo: solo)
            let gotPairs = got.map { "\($0.title) | \($0.deadline ?? "-")" }
            let wanted = expected.map { "\($0.0) | \($0.1 ?? "-")" }
            check(gotPairs == wanted, "\(label): \(gotPairs.count) of yours")
            if gotPairs != wanted {
                print("    expected: \(wanted)")
                print("    got:      \(gotPairs)")
                for item in ActionItemParser.items(in: markdown, names: names, meetingDate: meeting, calendar: calendar) {
                    print("    parsed: title=\(item.title) owner=\(item.owner) group=\(item.group) due=\(item.deadline ?? "-")")
                }
            }
        }

        expect("meeting notes from a call", """
            ## Summary
            We reviewed the Q4 rollout. Dana will handle the room.
            ## Decisions
            - Go with Vimeo Enterprise
            ## Action items
            - [ ] Send the updated budget to finance — Me, by Friday
            - [ ] Book the conference room — Dana
            - [ ] Review Q3 - Q4 numbers — Matthew
            - [ ] Draft the announcement (Owner: Matt, due Oct 31)
            - [x] Order cables — Me
            - [ ] Share slides — Dana, Me
            - [ ] Me — call the vendor about pricing by next Monday
            - [ ] Update the wiki
            - [ ] **Dana**: test the stream
            - [ ] Everyone — read the policy
            - [ ] I will email the agenda tomorrow
            - [ ] Dana to send me the contract
            - [ ] Follow up re: pricing — Me
            - [ ] Check the Pearl-2 firmware — Me (Oct 30)
              - Version 4.24 or later
            """, solo: false, [
                ("Send the updated budget to finance", "2026-10-23"),
                ("Review Q3 - Q4 numbers", nil),
                ("Draft the announcement", "2026-10-31"),
                ("Share slides", nil),
                ("Call the vendor about pricing by next Monday", "2026-10-26"),
                ("Read the policy", nil),
                ("Email the agenda tomorrow", nil),
                ("Follow up re: pricing", nil),
                ("Check the Pearl-2 firmware", "2026-10-30"),
            ])

        let grouped = mine("""
            **Matthew**
            - [ ] Renew the SSL certificate by 11/15
            - [ ] Ask IT about the Pearl-2 firmware
            **Dana**
            - [ ] Order HDMI cables
            ### Me
            - [ ] Email the council clerk
            ## Matt's next steps
            - Post the agenda
            ## Dana's next steps
            - Post the minutes
            """, solo: false)
        check(grouped.map(\.title) == ["Renew the SSL certificate by 11/15", "Ask IT about the Pearl-2 firmware", "Email the council clerk", "Post the agenda"],
              "to-do list grouped by person: \(grouped.map(\.title))")
        check(grouped.first?.deadline == "2026-11-15", "due date from “by 11/15”")

        expect("voice memo (nobody else in it)", """
            ## Key points
            - Garage needs a new door seal
            ## Follow-ups
            - Call the plumber about the well pump
            - Buy heat tape for the dog house before Nov 15
            - Dana: pick up the dog food
            """, solo: true, [
                ("Call the plumber about the well pump", nil),
                ("Buy heat tape for the dog house before Nov 15", "2026-11-15"),
            ])

        expect("nothing to do", """
            ## Action items
            - None noted
            - [ ] N/A
            """, solo: true, [])

        expect("owner-less items in a meeting aren't sent", """
            ## Next steps
            - [ ] Send the report to Dana
            - Schedule the follow-up
            """, solo: false, [])

        expect("bold label for the section", """
            **Action items:**
            - Send the deck — Matt
            - Book travel — Dana
            **Decisions:**
            - Keep the budget
            """, solo: false, [("Send the deck", nil)])

        expect("numbered list and plain hyphen", """
            ## To-do
            1. Update the runbook - Me
            2. Call Dana - Dana
            """, solo: false, [("Update the runbook", nil)])

        if let host = ProcessInfo.processInfo.environment["FIRESTORE_EMULATOR_HOST"] {
            do {
                try await cloudChecks(joinCode: fixture["joinCode"] as! String, host: host, space: space, out: args[2])
            } catch {
                check(false, "emulator: \(error.localizedDescription) — \((error as? SectisCloud.Failure)?.detail ?? "\(error)")")
            }
        }

        print(failures == 0 ? "All Sectis checks passed." : "\(failures) Sectis check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Firestore emulator

    static func cloudChecks(joinCode: String, host: String, space: String, out: String) async throws {
        print("— Firestore emulator at \(host) —")
        let connection = try await SectisCloud.connect(joinCode: joinCode, baseURL: "http://\(host)/v1/")
        check(connection.space == space, "connects to the same space")

        let before = try await SectisCloud.readTags(connection)
        check(before.isEmpty, "reads tags (none yet)")
        let tagID = await SectisCloud.findOrCreateTag("Meeting", connection)
        check(tagID != nil, "makes the Meeting tag")
        let again = await SectisCloud.findOrCreateTag("meeting", connection)
        check(again == tagID, "finds that tag next time instead of making another")
        let tags = try await SectisCloud.readTags(connection)
        check(tags.count == 1 && tags.first?.title == "Meeting", "reads the tag back: \(tags.map(\.title))")

        let now = Date()
        let version = Int64(now.timeIntervalSince1970 * 1000)
        let noteID = UUID().uuidString
        let titles = ["Send the updated budget to finance", "Call the vendor about pricing"]
        var ids: [String] = []
        var writes: [[String: Any]] = []
        for (index, title) in titles.enumerated() {
            let id = SectisFormat.itemID(noteID: noteID, title: title)
            ids.append(id)
            let record = SectisFormat.todoRecord(id: id, title: title, notes: "From “Weekly sync” (Sintr)",
                                                 deadline: index == 0 ? "2026-10-23" : nil, tags: [tagID ?? ""],
                                                 order: -Double(Int64(now.timeIntervalSince1970)) + Double(index) * 0.001, now: now)
            writes.append(try SectisCloud.createWrite(connection, id: id, kind: "todo", record: record, version: version))
        }
        let first = try await SectisCloud.batchWrite(connection, writes)
        check(first == [.created, .created], "Sectis's rules accept the new to-dos: \(first)")
        let second = try await SectisCloud.batchWrite(connection, writes)
        check(second == [.exists, .exists], "sending the same items again changes nothing: \(second)")

        // Outside the space Sectis's rules allow (shorter than 40 characters): refused.
        let outside = SectisCloud.Connection(projectId: connection.projectId, apiKey: connection.apiKey, space: "short",
                                             key: connection.key, baseURL: connection.baseURL)
        let record = SectisFormat.todoRecord(id: "snrefused0001", title: "x", notes: "", deadline: nil, tags: [], order: 0, now: now)
        let refusedWrite = try SectisCloud.createWrite(outside, id: "snrefused0001", kind: "todo", record: record, version: version)
        do {
            let results = try await SectisCloud.batchWrite(outside, [refusedWrite])
            if case .failed(let message)? = results.first {
                check(message.contains("rules"), "a write the rules refuse says the rules need setting up")
            } else {
                check(false, "a write the rules refuse is reported as failed: \(results)")
            }
        } catch {
            check(error.localizedDescription.contains("rules"), "a request the rules refuse says the rules need setting up: \(error.localizedDescription)")
        }

        var output = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: out)))) as? [String: Any] ?? [:]
        output["cloud"] = ["tagID": tagID ?? "", "ids": ids, "titles": titles] as [String: Any]
        try JSONSerialization.data(withJSONObject: output).write(to: URL(fileURLWithPath: out))
    }
}
