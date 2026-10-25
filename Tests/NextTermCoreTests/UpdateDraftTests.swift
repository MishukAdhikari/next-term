import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// Post Update's draft: Done, Next and Blocked from today's handoffs, today's posted tasks and today's commits, in a
/// fixed order, with every key masked; and the update saved in the project under a name no file holds.
@Suite struct UpdateDraftTests {
    static let handoff = """
        ## Done
        - Fixed the login redirect
        - Wrote the migration

        ## Next
        - Add a test for the expired token
        - Move the retry into the client
        - Ask design about the error page

        ## Open questions
        - Should the token live a day?

        ## How to resume
        Run the tests.
        """

    static let now = Date(timeIntervalSince1970: 1_792_300_000)

    static func task(_ title: String, _ kind: TaskDestination.Kind = .reminders, key: String = "x",
                     waited: Bool = false) -> TaskRecord.Entry {
        TaskRecord.Entry(at: now, kind: kind, key: key, title: title, slug: TodoFile.slug(title), project: "p",
                         waited: waited)
    }

    static func mask(_ value: String) -> SecretMask {
        let key = SymmetricKey(size: .bits256)
        return SecretMask(key: key, marks: SecretMask.marks(for: SecretBytes(utf8: value), key: key))
    }

    static func source(_ text: String,
                       _ file: String = "docs/handoffs/2026-10-18-api.md") -> UpdateDraft.HandoffSource {
        UpdateDraft.HandoffSource(file: file, handoff: Handoff.parse(text))
    }

    @Test func eachSourceGoesToItsSectionInSourceOrder() {
        let tasks = [Self.task("Rotate the staging keys"),
                     Self.task("Ship the banner", .github, key: "acme/shop")]
        let commits = TodayCommits.Outcome.subjects(["Fix A", "Fix B", "Fix C"])
        let draft = UpdateDraft.build(project: "shop", handoffs: [Self.source(Self.handoff)], tasks: tasks,
                                      commits: commits, mask: { $0 })
        #expect(draft.done == ["Fixed the login redirect", "Wrote the migration", "Fix A", "Fix B", "Fix C"])
        #expect(draft.next == ["Add a test for the expired token", "Move the retry into the client",
                               "Ask design about the error page", "Rotate the staging keys (Reminders)",
                               "Ship the banner (acme/shop)"])
        #expect(draft.blocked == ["Should the token live a day?"])
        #expect(draft.sourceLine == "From 1 handoff, 2 tasks and 3 commits today.")
    }

    @Test func aHandoffItemPostedAsATaskAppearsOnceAsTheTask() {
        let tasks = [Self.task("Move the retry into the client", .linear, key: "")]
        let draft = UpdateDraft.build(project: "shop", handoffs: [Self.source(Self.handoff)], tasks: tasks,
                                      commits: .subjects([]), mask: { $0 })
        #expect(draft.next == ["Add a test for the expired token", "Ask design about the error page",
                               "Move the retry into the client (Linear)"])
    }

    @Test func noSourcesGiveThreeNoneSections() {
        let draft = UpdateDraft.build(project: "shop", handoffs: [], tasks: [], commits: .subjects([]), mask: { $0 })
        #expect(draft.sourceLine == "Nothing found for today.")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Dhaka") ?? .current
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 9)) ?? Self.now
        let text = draft.text(date: day, calendar: calendar, locale: Locale(identifier: "en_GB"))
        let expected = """
            ## Update: shop, 18 October 2026

            ### Done
            - None

            ### Next
            - None

            ### Blocked
            - None

            """
        #expect(text == expected)
    }

    @Test func tickedNextItemsAreDoneAndAHandoffWithNoSectionsIsNamed() {
        let ticked = "## Next\n- [x] Merged the fix\n- [ ] Tag the release\n"
        let loose = UpdateDraft.HandoffSource(file: "docs/handoffs/2026-10-18-web.md",
                                              handoff: Handoff.parse("Just some notes.\n"))
        let draft = UpdateDraft.build(project: "shop", handoffs: [Self.source(ticked), loose], tasks: [],
                                      commits: .subjects([]), mask: { $0 })
        #expect(draft.done == ["Merged the fix"])
        #expect(draft.next == ["Tag the release"])
        #expect(draft.unshaped == ["docs/handoffs/2026-10-18-web.md"])
        #expect(draft.notes.contains("1 handoff had no sections: docs/handoffs/2026-10-18-web.md"))
        #expect(draft.sourceLine == "From 1 handoff today.")
    }

    @Test func aReasonForNoCommitsIsANote() {
        let draft = UpdateDraft.build(project: "shop", handoffs: [], tasks: [], commits: .noEmail, mask: { $0 })
        #expect(draft.notes == ["No commits: git has no user.email in this project."])
        #expect(draft.done.isEmpty)
    }

    @Test func aPageTaskSaysThePageWasOnlyOpened() {
        let tasks = [Self.task("Ship the banner", .github, key: "acme/shop", waited: true),
                     Self.task("Buy milk", .todoist, key: "", waited: true)]
        let draft = UpdateDraft.build(project: "shop", handoffs: [], tasks: tasks, commits: .subjects([]),
                                      mask: { $0 })
        #expect(draft.next == ["Ship the banner (acme/shop, page opened)", "Buy milk (Todoist, opened)"])
    }

    @Test func keysInEverySourceAreMaskedInTheDraftAndItsText() {
        let mask = Self.mask("sk-ant-abc123def456")
        let handoff = "## Done\n- set token sk-ant-abc123def456\n"
        let tasks = [Self.task("call with sk-ant-abc123def456")]
        let commits = TodayCommits.Outcome.subjects(["fix token=sk-ant-abc123def456"])
        let draft = UpdateDraft.build(project: "sk-ant-abc123def456", handoffs: [Self.source(handoff)],
                                      tasks: tasks, commits: commits, mask: { mask.mask($0) })
        #expect(draft.done == ["set token •••", "fix token=•••"])
        #expect(draft.next == ["call with ••• (Reminders)"])
        let text = draft.text(date: Self.now)
        #expect(!text.contains("sk-ant"))
        #expect(text.contains("•••"))
    }
}

// MARK: saving and sending

extension UpdateDraftTests {
    func project() throws -> String {
        let dir = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-update-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func savingTwiceGivesTheDayAndThenItsSecondName() throws {
        let dir = try project()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let day = try #require(TaskDay("2026-10-18"))
        let first = try UpdateFile.save("one\n", in: dir, day: day)
        let second = try UpdateFile.save("two\n", in: dir, day: day)
        #expect(first == "docs/updates/2026-10-18.md")
        #expect(second == "docs/updates/2026-10-18-2.md")
        let read = try String(contentsOfFile: dir + "/" + first, encoding: .utf8)
        #expect(read == "one\n")
    }

    @Test func aLinkedUpdatesFolderIsRefusedAndNothingIsWritten() throws {
        let dir = try project()
        let elsewhere = try project()
        defer {
            try? FileManager.default.removeItem(atPath: dir)
            try? FileManager.default.removeItem(atPath: elsewhere)
        }
        try FileManager.default.createDirectory(atPath: dir + "/docs", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dir + "/docs/updates", withDestinationPath: elsewhere)
        let day = try #require(TaskDay("2026-10-18"))
        #expect(throws: UpdateFile.Failure.notPlainFolder) { try UpdateFile.save("x\n", in: dir, day: day) }
        let left = try FileManager.default.contentsOfDirectory(atPath: elsewhere)
        #expect(left.isEmpty)
        #expect(UpdateFile.Failure.notPlainFolder.message
            == "Choose Copy instead: docs/updates is not a plain folder in this project.")
    }

    @Test func aLinkedDocsFolderIsRefusedToo() throws {
        let dir = try project()
        let elsewhere = try project()
        defer {
            try? FileManager.default.removeItem(atPath: dir)
            try? FileManager.default.removeItem(atPath: elsewhere)
        }
        try FileManager.default.createSymbolicLink(atPath: dir + "/docs", withDestinationPath: elsewhere)
        let day = try #require(TaskDay("2026-10-18"))
        #expect(throws: UpdateFile.Failure.notPlainFolder) { try UpdateFile.save("x\n", in: dir, day: day) }
        #expect(!FileManager.default.fileExists(atPath: elsewhere + "/updates"))
    }

    @Test func whenEveryNameIsTakenItSaysSo() throws {
        let dir = try project()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let day = try #require(TaskDay("2026-10-18"))
        let names = UpdateFile.names(day: day)
        #expect(names.count == 99 && names.first == "2026-10-18.md" && names.last == "2026-10-18-99.md")
        try FileManager.default.createDirectory(atPath: dir + "/docs/updates", withIntermediateDirectories: true)
        for name in names {
            FileManager.default.createFile(atPath: dir + "/docs/updates/" + name, contents: Data())
        }
        #expect(throws: UpdateFile.Failure.namesUsedUp) { try UpdateFile.save("x\n", in: dir, day: day) }
        #expect(UpdateFile.Failure.namesUsedUp.message == "Today’s update names are used up.")
    }

    @Test func theAgentRequestNamesWhereAndRefusesALongText() {
        let request = UpdateDraft.request(text: "## Update\n- a\n", to: "  Slack #team ")
        #expect(request == "Post this update to Slack #team, exactly as written:\n\n## Update\n- a")
        #expect(UpdateDraft.request(text: "x", to: "  ") == nil)
        #expect(UpdateDraft.request(text: "x", to: "Slack\n#team") == nil)
        #expect(UpdateDraft.request(text: "  \n", to: "Slack") == nil)
        let long = String(repeating: "a", count: UpdateDraft.longestTyped + 1)
        #expect(UpdateDraft.request(text: long, to: "Slack") == nil)
        #expect(UpdateDraft.isTooLong(long))
        #expect(!UpdateDraft.isTooLong(String(repeating: "a", count: UpdateDraft.longestTyped)))
    }
}
