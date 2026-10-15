import Foundation
import Testing
@testable import NextTermCore

/// A prompt becomes a task by fixed rules: the title, its steps (nested by indent, done kept), notes word for word, one
/// task per item of a list; and the day it is planned for, by the calendar.
@Suite struct TaskDraftTests {
    func calendar(_ zone: String, firstWeekday: Int = 2) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    /// `2026-10-15 23:59` in `calendar`'s time zone.
    func at(_ text: String, _ calendar: Calendar) -> Date {
        let parts = text.split { $0 == "-" || $0 == " " || $0 == ":" }.compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4]))!
    }

    @Test func aPromptGivesATitleItsStepsAndNotes() throws {
        let drafts = TaskDraft.drafts(prompt: "Finish the login fix:\n- write test\n  - expired\n- ask Sam\n\nSee PR 512.")
        let draft = try #require(drafts.first)
        #expect(drafts.count == 1)
        #expect(draft.title == "Finish the login fix")
        #expect(draft.steps == [TaskDraft.Step(text: "write test"), TaskDraft.Step(text: "expired", depth: 1), TaskDraft.Step(text: "ask Sam")])
        #expect(draft.notes == "See PR 512.")
        #expect(draft.scheduled == .none && draft.context == nil && !draft.masked)
    }

    @Test func everyKindOfListLineIsAStepAndADoneBoxStaysDone() throws {
        let prompt = "Ship it\n* one\n+ two\n1. three\n2) four\n[ ] five\n[x] six\n- [X] seven\n- [ ] eight\n-flag\n3.14 is pi\n---"
        let draft = try #require(TaskDraft.drafts(prompt: prompt).first)
        #expect(draft.steps.map(\.text) == ["one", "two", "three", "four", "five", "six", "seven", "eight"])
        #expect(draft.steps.map(\.done) == [false, false, false, false, false, true, true, false])
        // Not list lines: a word after a dash, a number, a rule.
        #expect(draft.notes == "-flag\n3.14 is pi\n---")
    }

    @Test func notesKeepTheirWordsAndCodeFencesWhole() throws {
        let prompt = "Look at the crash\r\n\r\nIt fails here:\r\n```swift\r\n- not a step\r\nlet x = 1  \r\n```\r\n\r\n\r\nThen  this."
        let draft = try #require(TaskDraft.drafts(prompt: prompt).first)
        #expect(draft.title == "Look at the crash")
        #expect(draft.steps.isEmpty)
        // CRLF is LF; blank lines inside stay, those at the ends go; trailing spaces stay.
        #expect(draft.notes == "It fails here:\n```swift\n- not a step\nlet x = 1  \n```\n\n\nThen  this.")
    }

    @Test func anIndentedLineCarriesOnItsStepAndNestingFollowsTheIndent() throws {
        let prompt = "Plan\n- one\n  goes on here\n    - deep\n\t- tabbed\n- two\nA note"
        let draft = try #require(TaskDraft.drafts(prompt: prompt).first)
        #expect(draft.steps == [TaskDraft.Step(text: "one goes on here"), TaskDraft.Step(text: "deep", depth: 1),
                                TaskDraft.Step(text: "tabbed", depth: 1), TaskDraft.Step(text: "two")])
        #expect(draft.notes == "A note")
    }

    @Test func aPromptThatIsOnlyAListIsOneTaskPerItem() {
        let drafts = TaskDraft.drafts(prompt: "- Fix the login test\n  - [x] read the log\n- [ ] Update the docs:\n\n3. Tag the release\n")
        #expect(drafts.map(\.title) == ["Fix the login test", "Update the docs", "Tag the release"])
        #expect(drafts[0].steps == [TaskDraft.Step(text: "read the log", done: true)])
        #expect(drafts[1].steps.isEmpty && drafts[2].steps.isEmpty && drafts.allSatisfy { $0.notes.isEmpty })
        // A list with code: the first item is the title.
        let coded = TaskDraft.drafts(prompt: "- Fix it\n- see below\n```\ncode\n```")
        #expect(coded.map(\.title) == ["Fix it"] && coded.first?.steps.map(\.text) == ["see below"] && coded.first?.notes == "```\ncode\n```")
        // Nothing to do: no task.
        #expect(TaskDraft.drafts(prompt: "").isEmpty && TaskDraft.drafts(prompt: " \n\t\n").isEmpty && TaskDraft.drafts(prompt: "```\nx\n```").isEmpty)
    }

    @Test func addTasksTitleAndNotesTakeTheSameRules() throws {
        let draft = try #require(TaskDraft(title: "- [ ] Finish the login fix:\nfrom the review", notes: "- write test\n\nSee PR 512."))
        #expect(draft.title == "Finish the login fix")
        #expect(draft.steps == [TaskDraft.Step(text: "write test")])
        #expect(draft.notes == "from the review\n\nSee PR 512.")
        #expect(TaskDraft(title: "  \n ") == nil && TaskDraft(title: "- [ ]") == nil && TaskDraft(title: ":") == nil)
        #expect(TaskDraft(title: "Only a title")?.notes == "")
    }

    @Test func aStoredKeyIsMaskedBeforeAnyRuleSeesIt() throws {
        let key = "sk-live-7f3c2a9b4d1e"
        let mask: (String) -> String = { $0.replacingOccurrences(of: key, with: "•••") }
        let draft = try #require(TaskDraft.drafts(prompt: "Rotate \(key) today\n- revoke \(key)\n\nexport KEY=\(key)", mask: mask).first)
        #expect(draft.title == "Rotate ••• today" && draft.steps.first?.text == "revoke •••" && draft.notes == "export KEY=•••")
        #expect(draft.masked)
        let added = try #require(TaskDraft(title: "Use \(key)", notes: key, mask: mask))
        #expect(added.title == "Use •••" && added.notes == "•••" && added.masked)
        #expect(TaskDraft(title: "Nothing secret", mask: mask)?.masked == false)
        let context = TaskContext(branch: "b", tab: "tab \(key)", agent: .claude, resume: "claude --resume \(key)", addedBy: "you").masked(by: mask)
        #expect(context.tab == "tab •••" && context.resume == "claude --resume •••" && context.agent == .claude && context.addedBy == "you")
    }

    @Test func todayIsTheDayOfNowInTheUsersTimeZone() {
        let dhaka = calendar("Asia/Dhaka")
        #expect(When.parse("today", now: at("2026-10-15 23:59", dhaka), calendar: dhaka)?.description == "2026-10-15")
        #expect(When.parse("today", now: at("2026-10-16 00:01", dhaka), calendar: dhaka)?.description == "2026-10-16")
        #expect(When.parse("tomorrow", now: at("2026-10-15 23:59", dhaka), calendar: dhaka)?.description == "2026-10-16")
        // Across a month's and a year's end.
        #expect(When.parse("tomorrow", now: at("2026-01-31 12:00", dhaka), calendar: dhaka)?.description == "2026-02-01")
        #expect(When.parse("tomorrow", now: at("2026-12-31 23:30", dhaka), calendar: dhaka)?.description == "2027-01-01")
        // Across a clock change, either way: still the next day.
        let york = calendar("America/New_York")
        #expect(When.parse("tomorrow", now: at("2026-10-31 23:30", york), calendar: york)?.description == "2026-11-01")
        #expect(When.parse("tomorrow", now: at("2026-11-01 00:30", york), calendar: york)?.description == "2026-11-02")
        #expect(When.parse("tomorrow", now: at("2026-03-07 23:30", york), calendar: york)?.description == "2026-03-08")
        #expect(When.parse("tomorrow", now: at("2026-03-08 00:30", york), calendar: york)?.description == "2026-03-09")
    }

    @Test func aDateIsTakenAsWrittenAndAnythingElseIsRefused() {
        let dhaka = calendar("Asia/Dhaka")
        let now = at("2026-10-15 10:00", dhaka)
        #expect(When.parse("2026-10-16", now: now, calendar: dhaka) == TaskDay("2026-10-16"))
        #expect(When.parse("2028-02-29", now: now, calendar: dhaka)?.description == "2028-02-29")
        for bad in ["Tomorrow", "next week", "2026-1-6", "2026-02-30", "2026-13-01", "2026-10-16T09:00", "", " today", "１２３４-10-16"] {
            #expect(When.parse(bad, now: now, calendar: dhaka) == nil, "\(bad)")
        }
        let pattern = try? NSRegularExpression(pattern: When.pattern)
        func matches(_ text: String) -> Bool { pattern?.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil }
        #expect(matches("today") && matches("tomorrow") && matches("2026-10-16"))
        #expect(!matches("Tomorrow") && !matches("next week") && !matches("2026-1-6"))
    }

    @Test func nextWeekIsTheComingFirstDayOfTheWeek() {
        let monday = calendar("Asia/Dhaka", firstWeekday: 2), sunday = calendar("Asia/Dhaka", firstWeekday: 1)
        // 15 October 2026 is a Thursday.
        #expect(When.nextWeek(after: at("2026-10-15 09:00", monday), calendar: monday).description == "2026-10-19")
        #expect(When.nextWeek(after: at("2026-10-15 09:00", sunday), calendar: sunday).description == "2026-10-18")
        // On the first day itself: the one a week on, never today.
        #expect(When.nextWeek(after: at("2026-10-19 09:00", monday), calendar: monday).description == "2026-10-26")
        #expect(When.days(7, after: at("2026-10-28 09:00", monday), calendar: monday).description == "2026-11-04")
    }
}
