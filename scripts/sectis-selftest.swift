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

        // However it gets pasted (a phone's clipboard, a chat app, smart punctuation…).
        let code = (fixture["joinCode"] as! String).components(separatedBy: .whitespacesAndNewlines).joined()
        let body = String(code.dropFirst("SECTIS-".count))
        func reads(_ text: String, _ label: String) {
            let parsed = SectisFormat.parseJoinCode(text)
            check(parsed == link, "reads a join code \(label)")
            check(SectisFormat.normalizedJoinCode(text) == code, "…and tidies it back to the original")
            check(SectisFormat.joinCodeProblem(text) == nil, "…with no complaint")
        }
        reads("Here's the code: \(code). Thanks!", "inside a sentence")
        reads("\u{201C}\(code)\u{201D}", "in curly quotes")
        reads(code.replacingOccurrences(of: "-", with: "\u{2014}"), "whose dashes became em dashes")
        reads(code.replacingOccurrences(of: "-", with: "\u{2013}"), "whose dashes became en dashes")
        reads(String(code.prefix(40)) + "\u{200B}" + String(code.dropFirst(40)), "with an invisible space in it")
        reads(String(code.prefix(60)) + "\n" + String(code.dropFirst(60)) + "\n", "split over lines")
        reads(code.lowercased().hasPrefix("sectis-") ? code : "sectis-" + body, "with a lowercase prefix")
        check(SectisFormat.parseJoinCode(body) == link, "reads the code without its SECTIS- prefix")

        let cut = String(code.prefix(90))
        check(SectisFormat.parseJoinCode(cut) == nil, "rejects a cut-off code")
        check(SectisFormat.joinCodeProblem(cut)?.contains("cut off") == true,
              "says a cut-off code is cut off: \(SectisFormat.joinCodeProblem(cut) ?? "nil")")
        check(SectisFormat.joinCodeProblem("hunter2")?.contains("start with SECTIS-") == true, "says a non-code isn't a join code")
        check(SectisFormat.joinCodeProblem("  ")?.hasPrefix("Paste") == true, "asks for a code when there's nothing")
        var changed = Array(code)
        changed[30] = changed[30] == "A" ? "B" : "A"
        check(SectisFormat.parseJoinCode(String(changed)) == nil || SectisFormat.parseJoinCode(String(changed)) != link,
              "doesn't accept a changed code as the original")

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
        let project = SectisFormat.Place(kind: .project, id: "proj123", title: "Q4 rollout", area: "Council")
        let waitingID = SectisFormat.itemID(noteID: "B1A2C3D4-0000-4000-8000-000000000001", title: "Send the revised quote")
        let waitingRecord = SectisFormat.todoRecord(
            id: waitingID, title: "Send the revised quote", notes: "From “Weekly sync” — [Open in Sintr](sintr://note/B1A2C3D4-0000-4000-8000-000000000001)",
            deadline: nil, tags: ["tag123", "ptag"], order: -5, now: Date(), place: project,
            checklist: ["With the new rates", "Copy finance"],
            waiting: .init(person: "Dana", since: "2026-10-22", followUp: "2026-10-30"))
        let waitingSealed = try SectisFormat.encrypt(waitingRecord, key: key)
        let areaRecord = SectisFormat.todoRecord(id: "snarea0000001", title: "Book the room", notes: "", deadline: nil, tags: [],
                                                 order: 0, now: Date(), place: .init(kind: .area, id: "area9", title: "Home"))
        let areaSealed = try SectisFormat.encrypt(areaRecord, key: key)
        let out: [String: Any] = [
            "space": space, "c": sealed.c, "iv": sealed.iv,
            "expected": ["id": id, "title": "Send the budget — café ✓", "notes": notes, "deadline": "2026-10-23"],
            "waiting": ["c": waitingSealed.c, "iv": waitingSealed.iv, "id": waitingID],
            "area": ["c": areaSealed.c, "iv": areaSealed.iv],
        ]
        try JSONSerialization.data(withJSONObject: out).write(to: URL(fileURLWithPath: args[2]))

        // MARK: Projects, areas and what became of a to-do
        let places = SectisFormat.places(
            projects: [
                ["id": "p1", "title": "Q4 rollout", "areaId": "a1", "status": "open", "order": 2],
                ["id": "p2", "title": "Done project", "areaId": "a1", "status": "done", "order": 1],
                ["id": "p3", "title": "", "areaId": NSNull(), "status": "open", "order": 0],
                ["id": "p4", "title": "Trashed", "status": "open", "trashed": true],
                ["id": "p5", "title": "A template", "status": "open", "isTemplate": true],
                ["id": "p6", "title": "Lost area", "areaId": "gone", "status": "open", "order": 5],
            ],
            areas: [["id": "a2", "title": "Home", "order": 2], ["id": "a1", "title": "Council", "order": 1]])
        check(places.map(\.fullTitle) == ["Council", "Council › Q4 rollout", "Home", "New Project", "Lost area"],
              "projects and areas to pick from, open projects under their area: \(places.map(\.fullTitle))")
        check(places[1].kind == .project && places[1].id == "p1" && places[0].kind == .area, "kinds and ids")
        let placeJSON = try JSONEncoder().encode(places[1])
        check((try? JSONDecoder().decode(SectisFormat.Place.self, from: placeJSON)) == places[1], "a place is saved and read back")

        let doneState = SectisFormat.todoState(id: "x", record: ["title": "Send it", "status": "done", "waitFor": "Dana", "when": "2026-10-30"])
        check(doneState.status == .done && doneState.isFinished && doneState.waitingOn == nil, "a completed to-do is done (no longer waiting)")
        let waitState = SectisFormat.todoState(id: "y", record: ["title": "Quote", "status": "open", "waitFor": "Dana", "when": "2026-10-30", "projectId": "p1"])
        check(waitState.waitingOn == "Dana" && waitState.followUp == "2026-10-30" && waitState.projectId == "p1", "an open waiting to-do says who and when")
        check(SectisFormat.todoState(id: "z", record: ["title": "Old", "status": "open", "trashed": true]).isGone, "a to-do in Sectis's Trash is gone")
        check(SectisFormat.todoState(id: "z", record: nil, deleted: true).status == .deleted, "a deleted one is deleted")

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

        // Other people's items, for Waiting For.
        func theirs(_ markdown: String, solo: Bool) -> [String] {
            ActionItemParser.items(in: markdown, names: names, meetingDate: meeting, calendar: calendar)
                .filter { !ActionItemParser.isMine($0, names: names, solo: solo) }
                .compactMap { item in ActionItemParser.someoneElse(item, names: names).map { "\(item.title) | \($0) | \(item.deadline ?? "-")" } }
        }
        let meetingNotes = """
            ## Summary
            - [ ] Vimeo pricing still open
            ## Action items
            - [ ] Send the updated budget to finance — Me, by Friday
            - [ ] Book the conference room — Dana
            - [ ] Share slides — Dana, Me
            - [ ] **Sam**: test the stream by Oct 30
            - [ ] Dana to send me the contract
            - [ ] Order cables (Owner: Dana Lee, due Friday)
            - [ ] Update the wiki
            - [ ] Everyone — read the policy
            - [ ] Check the mics — Owner TBD
            ### Priya
            - [ ] Draft the press release
            ## Vimeo Pricing
            - [ ] Ask about the nonprofit rate
            """
        let others = theirs(meetingNotes, solo: false)
        let wantOthers = [
            "Book the conference room | Dana | -",
            "Test the stream by Oct 30 | Sam | 2026-10-30",
            "Send me the contract | Dana | -",
            "Order cables | Dana Lee | 2026-10-23",
            "Draft the press release | Priya | -",
        ]
        check(others == wantOthers, "other people's items, for Waiting For: \(others.count)")
        if others != wantOthers {
            print("    expected: \(wantOthers)")
            print("    got:      \(others)")
        }
        let groupedOthers = theirs("""
            **Matthew**
            - [ ] Renew the SSL certificate
            **Dana**
            - [ ] Order HDMI cables
            ## Dana's next steps
            - Post the minutes
            ## Next steps for Sam
            - Fix the projector
            **Decisions:**
            - [ ] Keep the budget
            """, solo: false)
        check(groupedOthers == ["Order HDMI cables | Dana | -", "Post the minutes | Dana | -", "Fix the projector | Sam | -"],
              "items listed under someone else: \(groupedOthers)")
        check(theirs("## Follow-ups\n- Call the plumber\n- Dana: pick up the dog food", solo: true) == ["Pick up the dog food | Dana | -"],
              "a voice memo's item for someone else")
        check(ActionItemParser.personName("@dana") == "Dana" && ActionItemParser.personName("Dana's") == "Dana"
              && ActionItemParser.personName("Dana (PM)") == "Dana" && ActionItemParser.personName("dana and sam") == "Dana and Sam",
              "names to wait on read cleanly")
        check(ActionItemParser.personName("TBD") == nil && ActionItemParser.personName("unassigned") == nil, "no one to wait on for TBD")

        // Reworded before sending: the Sectis ID still comes from the first wording.
        let call = mine("- [ ] Send the updated budget to finance — Me, by Friday", solo: false).first
        if let call {
            var edited = call
            edited.originalTitle = call.idTitle
            edited.title = "Send finance the Q4 budget"
            check(edited.idTitle == "Send the updated budget to finance", "a reworded item keeps its first wording for its ID")
            check(SectisFormat.itemID(noteID: "N", title: edited.idTitle) == SectisFormat.itemID(noteID: "N", title: call.idTitle),
                  "so sending it again doesn't add it twice")
        } else {
            check(false, "reads a single action item")
        }

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
        let first = try await SectisCloud.createEach(connection, writes)
        check(first == [.created, .created], "Sectis's rules accept the new to-dos: \(first)")
        let second = try await SectisCloud.createEach(connection, writes)
        check(second == [.exists, .exists], "sending the same items again changes nothing: \(second)")

        // A project and an area as Sectis writes them; Sintr lists them and reads items back.
        let areaRecord: [String: Any] = ["id": "areaemu00001", "title": "Council", "tags": ["atag"], "order": 1]
        let projectRecord: [String: Any] = [
            "id": "projemu00001", "type": "project", "title": "Q4 rollout", "notes": "", "status": "open", "start": "anytime",
            "areaId": "areaemu00001", "tags": ["ptag"], "order": 0, "trashed": false, "isTemplate": false, "logged": false,
        ]
        let listWrites = [
            try SectisCloud.createWrite(connection, id: "areaemu00001", kind: "area", record: areaRecord, version: version),
            try SectisCloud.createWrite(connection, id: "projemu00001", kind: "project", record: projectRecord, version: version),
        ]
        check(try await SectisCloud.createEach(connection, listWrites) == [.created, .created], "writes a project and an area (as Sectis would)")
        let places = try await SectisCloud.readPlaces(connection)
        check(places.map(\.fullTitle) == ["Council", "Council › Q4 rollout"], "reads your projects and areas: \(places.map(\.fullTitle))")

        let project = places.first { $0.kind == .project }
        let waitingID = SectisFormat.itemID(noteID: noteID, title: "Send the revised quote")
        let waitingRecord = SectisFormat.todoRecord(
            id: waitingID, title: "Send the revised quote", notes: "From “Weekly sync” — [Open in Sintr](sintr://note/\(noteID))",
            deadline: nil, tags: [tagID ?? "", "ptag", "atag"], order: -1, now: now, place: project,
            checklist: ["With the new rates"], waiting: .init(person: "Dana", since: "2026-10-22", followUp: "2026-10-30"))
        let waitingWrite = try SectisCloud.createWrite(connection, id: waitingID, kind: "todo", record: waitingRecord, version: version)
        check(try await SectisCloud.createEach(connection, [waitingWrite]) == [.created], "Sectis's rules accept a to-do waiting on someone, in a project")
        ids.append(waitingID)

        let read = try await SectisCloud.readItems(ids + ["snnotthere001"], connection)
        if case .found(let record)? = read[waitingID] {
            let state = SectisFormat.todoState(id: waitingID, record: record)
            check(state.waitingOn == "Dana" && state.projectId == "projemu00001" && state.status == .open,
                  "reads the waiting to-do back: waiting on \(state.waitingOn ?? "nobody"), project \(state.projectId ?? "none")")
        } else {
            check(false, "reads the waiting to-do back")
        }
        if case .found(let record)? = read[ids[0]] {
            check(record["title"] as? String == titles[0], "reads a sent to-do back by its ID")
        } else {
            check(false, "reads a sent to-do back by its ID")
        }
        if case .missing? = read["snnotthere001"] {
            check(true, "an ID that isn't there reads as missing")
        } else {
            check(false, "an ID that isn't there reads as missing")
        }

        // Outside the space Sectis's rules allow (shorter than 40 characters): refused.
        let outside = SectisCloud.Connection(projectId: connection.projectId, apiKey: connection.apiKey, space: "short",
                                             key: connection.key, baseURL: connection.baseURL)
        let record = SectisFormat.todoRecord(id: "snrefused0001", title: "x", notes: "", deadline: nil, tags: [], order: 0, now: now)
        let refusedWrite = try SectisCloud.createWrite(outside, id: "snrefused0001", kind: "todo", record: record, version: version)
        do {
            let results = try await SectisCloud.createEach(outside, [refusedWrite])
            if case .failed(let message)? = results.first {
                check(message.contains("rules"), "a write the rules refuse says the rules need setting up")
            } else {
                check(false, "a write the rules refuse is reported as failed: \(results)")
            }
        } catch {
            check(error.localizedDescription.contains("rules"), "a request the rules refuse says the rules need setting up: \(error.localizedDescription)")
        }

        var output = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: out)))) as? [String: Any] ?? [:]
        output["cloud"] = ["tagID": tagID ?? "", "ids": Array(ids.prefix(titles.count)), "titles": titles, "waitingID": waitingID,
                           "projectID": "projemu00001", "areaID": "areaemu00001"] as [String: Any]
        try JSONSerialization.data(withJSONObject: output).write(to: URL(fileURLWithPath: out))
    }
}
