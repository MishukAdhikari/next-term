import Foundation
import Testing
@testable import NextTermCore

/// What each destination receives for one task: the exact link, text or reminder fields, built from a fixed template
/// per destination, cut visibly at a line end when a destination takes less, and with stored keys masked.
@Suite struct TaskPayloadTests {
    static let today = TaskDay("2026-10-19")!
    static let context = TaskContext(branch: "fix/login", tab: "api", agent: .claude, resume: "claude --resume 42", addedBy: "you")
    static let draft = TaskDraft(title: "Fix the login",
                                 steps: [.init(text: "Check refresh"), .init(text: "Add a test", depth: 1)],
                                 notes: "Drops after 1h.", scheduled: .day(today), context: context)

    /// The team body (steps, notes, branch), encoded.
    static let team = "-%20%5B%20%5D%20Check%20refresh%0A%20%20-%20%5B%20%5D%20Add%20a%20test%0A%0ADrops%20after%201h.%0A%0A"
        + "Branch%3A%20fix%2Flogin"
    /// The context lines a personal destination gets, encoded.
    static let where_ = "web%20%C2%B7%20fix%2Flogin%20%C2%B7%20api%20%C2%B7%20Claude%20Code%0AResume%3A%20claude%20--resume%2042"
    /// The personal body (steps, notes, context), encoded.
    static let personal = "-%20%5B%20%5D%20Check%20refresh%0A%20%20-%20%5B%20%5D%20Add%20a%20test%0A%0ADrops%20after%201h.%0A%0A"
        + where_
    static let personalText = "- [ ] Check refresh\n  - [ ] Add a test\n\nDrops after 1h.\n\n"
        + "web · fix/login · api · Claude Code\nResume: claude --resume 42"
    static let teamText = "- [ ] Check refresh\n  - [ ] Add a test\n\nDrops after 1h.\n\nBranch: fix/login"

    func render(_ draft: TaskDraft, _ destination: TaskDestination,
                mask: (String) -> String = { $0 }) throws -> TaskPayload {
        let payload = TaskPayload.render(draft, to: destination, project: "web", today: Self.today, mask: mask)
        return try #require(payload)
    }

    func render(_ destination: TaskDestination) throws -> TaskPayload {
        try render(Self.draft, destination)
    }

    func link(_ payload: TaskPayload) throws -> String {
        guard case .link(let url) = payload.form else { throw Unexpected() }
        return url.absoluteString
    }

    struct Unexpected: Error {}

    @Test func goldenLinks() throws {
        let things = "things:///add?title=Fix%20the%20login&notes=Drops%20after%201h.%0A%0A" + Self.where_
            + "&when=today&list=Work&checklist-items=Check%20refresh%0AAdd%20a%20test"
        #expect(try link(render(.things(list: "Work"))) == things)
        #expect(try link(render(.todoist)) == "todoist://openquickadd?content=Fix%20the%20login&description=" + Self.personal)
        #expect(try link(render(.omnifocus)) == "omnifocus:///add?name=Fix%20the%20login&note=" + Self.personal)
        let github = "https://github.com/example-org/web.app/issues/new?title=Fix%20the%20login&body=" + Self.team
        #expect(try link(render(.github(owner: "example-org", repo: "web.app"))) == github)
        let gitlab = "https://gitlab.com/group/sub/project/-/work_items/new?issue%5Btitle%5D=Fix%20the%20login"
            + "&issue%5Bdescription%5D=" + Self.team
        #expect(try link(render(.gitlab(path: "group/sub/project"))) == gitlab)
        let plusTeam = Self.team.replacingOccurrences(of: "%20", with: "+")
        #expect(try link(render(.linear(team: "ENG")))
            == "https://linear.app/team/ENG/new?title=Fix%20the%20login&description=" + plusTeam)
        #expect(try link(render(.linear(team: nil))) == "https://linear.new?title=Fix%20the%20login&description=" + plusTeam)
        #expect(try link(render(.trello)) == "https://trello.com/add-card?name=Fix%20the%20login")
        let azure = "https://dev.azure.com/Example%20Org/Web%20App/_workItems/create/User%20Story"
            + "?%5BSystem.Title%5D=Fix%20the%20login&%5BSystem.Description%5D=" + Self.team
        #expect(try link(render(.azureBoards(org: "Example Org", project: "Web App", type: "User Story"))) == azure)
    }

    @Test func goldenTexts() throws {
        let reminder = try render(.reminders(listID: nil, listName: "Next Term"))
        let due = DateComponents(year: 2026, month: 10, day: 19)
        #expect(reminder.form == .reminder(title: "Fix the login", notes: Self.personalText, due: due))
        let shortcut = try render(.shortcut(id: "8F1C2D3E-0000-4000-8000-000000000001", name: "Inbox"))
        #expect(shortcut.form == .stdin("Fix the login\n\nPlanned: 2026-10-19\n\n" + Self.personalText))
        let agent = try render(.throughAgent(tracker: "Linear"))
        let request = "Add this task to Linear with your Linear tools, exactly as written, then tell me its link.\n\n"
        #expect(agent.form == .agentRequest(request + "Fix the login\n\n" + Self.teamText))
        let folder = TaskPayload.render(Self.draft, to: .todoFolder, project: "web", today: Self.today, mask: { $0 })
        #expect(folder == nil)
        for payload in [reminder, shortcut, agent] { #expect(!payload.cut) }
    }

    @Test func sentDecodesEachParameter() throws {
        let github = try render(.github(owner: "example-org", repo: "web.app"))
        #expect(github.sent == "github.com/example-org/web.app/issues/new\n\ntitle\nFix the login\n\nbody\n" + Self.teamText)
        let reminder = try render(.reminders(listID: nil, listName: "Next Term"))
        #expect(reminder.sent == "Title: Fix the login\nList: Next Term\nDue: 2026-10-19 (all-day)\n\n" + Self.personalText)
        let shortcut = try render(.shortcut(id: "8F1C2D3E-0000-4000-8000-000000000001", name: "Inbox"))
        guard case .stdin(let text) = shortcut.form else { throw Unexpected() }
        #expect(shortcut.sent == text)
    }

    @Test func aTitleCantAddAParameter() throws {
        var draft = Self.draft
        draft.title = "a&when=someday"
        let things = try link(render(draft, .things(list: nil)))
        #expect(things.hasPrefix("things:///add?title=a%26when%3Dsomeday&"))
        let items = URLComponents(string: things)?.queryItems ?? []
        #expect(items.filter { $0.name == "when" }.map(\.value) == ["today"])
        draft.title = "1+1 is two"
        draft.notes = "a+b c"
        draft.steps = []
        draft.context = nil
        #expect(try link(render(draft, .github(owner: "o", repo: "r"))).hasSuffix("?title=1%2B1%20is%20two&body=a%2Bb%20c"))
        #expect(try link(render(draft, .linear(team: nil))).hasSuffix("?title=1%2B1%20is%20two&description=a%2Bb+c"))
    }

    @Test func thingsDaysAndChecklist() throws {
        var draft = Self.draft
        draft.scheduled = .none
        #expect(try !link(render(draft, .things(list: nil))).contains("when="))
        draft.scheduled = .day(TaskDay("2026-10-20")!)
        #expect(try link(render(draft, .things(list: nil))).contains("&when=tomorrow&"))
        let calendar = Calendar(identifier: .gregorian)
        let monday = When.nextWeek(after: Self.today.start(in: calendar)!, calendar: calendar)
        draft.scheduled = .day(monday)
        #expect(try link(render(draft, .things(list: nil))).contains("&when=\(monday)&"))
        draft.context = nil
        draft.notes = "Notes."
        draft.steps = (1...120).map { TaskDraft.Step(text: "step \($0)") }
        let url = try #require(URLComponents(string: try link(render(draft, .things(list: nil)))))
        let value = { (name: String) in url.queryItems?.first { $0.name == name }?.value ?? "" }
        let items = value("checklist-items").components(separatedBy: "\n")
        #expect(items.count == 100 && items.first == "step 1" && items.last == "step 100")
        let notes = value("notes").components(separatedBy: "\n")
        #expect(notes.prefix(20) == ArraySlice((101...120).map { "- [ ] step \($0)" }))
        #expect(notes.suffix(2) == ["", "Notes."])
    }

    @Test func thingsNotesAreCutAtALineEnd() throws {
        var draft = Self.draft
        draft.context = nil
        draft.steps = []
        draft.notes = (1...200).map { _ in String(repeating: "n", count: 59) }.joined(separator: "\n")
        #expect(draft.notes.count == 11_999)
        let payload = try render(draft, .things(list: nil))
        let url = try #require(URLComponents(string: try link(payload)))
        let notes = url.queryItems?.first { $0.name == "notes" }?.value ?? ""
        #expect(payload.cut && notes.count <= 10_000)
        #expect(notes.hasSuffix(String(repeating: "n", count: 59) + "\n\n(Cut by Next Term: Things takes 10,000 characters.)"))
    }

    @Test func pagesAreCutToTheirLinkLength() throws {
        var draft = Self.draft
        draft.context = nil
        draft.steps = []
        draft.notes = (1...150).map { _ in String(repeating: "x", count: 59) }.joined(separator: "\n")
        let payload = try render(draft, .github(owner: "o", repo: "r"))
        let url = try link(payload)
        #expect(payload.cut && url.utf8.count <= 6_000)
        #expect(url.hasSuffix("%0A%0A%28Cut%20by%20Next%20Term%20to%20fit%20GitHub%E2%80%99s%20link%20length.%29"))
        draft.notes = String(repeating: "y", count: 1_000)
        let short = try render(draft, .github(owner: "o", repo: "r"))
        let shortLink = try link(short)
        #expect(!short.cut && shortLink.hasSuffix(String(repeating: "y", count: 1_000)))
    }

    @Test func azureAndTrello() throws {
        var draft = Self.draft
        draft.context = nil
        draft.steps = []
        draft.notes = (1...50).map { _ in String(repeating: "z", count: 49) }.joined(separator: "\n")
        let azure = try render(draft, .azureBoards(org: "o", project: "p", type: "Task"))
        let url = try #require(URLComponents(string: try link(azure)))
        let description = url.queryItems?.first { $0.name == "[System.Description]" }?.value ?? ""
        #expect(azure.cut && description.count <= 2_000 && description.hasSuffix("Azure Boards takes 2,000 characters.)"))
        let trello = try #require(URLComponents(string: try link(render(.trello))))
        #expect(trello.queryItems?.map(\.name) == ["name"])
        draft.title = String(repeating: "t", count: 400)
        let long = try render(draft, .trello)
        let name = URLComponents(string: try link(long))?.queryItems?.first?.value ?? ""
        #expect(long.cut && name.count == 300 && name.hasSuffix("…"))
    }

    @Test func contextOnlyWherePersonalAndOn() throws {
        let personal: [TaskDestination] = [.reminders(listID: nil, listName: "L"), .things(list: nil), .todoist, .omnifocus,
                                           .shortcut(id: "8F1C2D3E-0000-4000-8000-000000000001", name: "S")]
        let team: [TaskDestination] = [.github(owner: "o", repo: "r"), .gitlab(path: "g/p"), .linear(team: nil), .trello,
                                       .azureBoards(org: "o", project: "p", type: "Task"), .throughAgent(tracker: "Jira")]
        let words = ["Resume", "api", "Claude Code"]
        for destination in personal {
            let shown = try render(destination).sent
            #expect(words.allSatisfy { shown.contains($0) }, "\(destination)")
        }
        for destination in team {
            let shown = try render(destination).sent
            #expect(!words.contains { shown.contains($0) }, "\(destination)")
        }
        var off = Self.draft
        off.context = TaskContext(addedBy: "you")
        for destination in personal + team {
            let shown = try render(off, destination).sent
            #expect(!(words + ["web ·", "Branch:"]).contains { shown.contains($0) }, "\(destination)")
        }
    }

    @Test func storedKeysAreMaskedEverywhere() throws {
        let key = "sk-ant-api03-EXAMPLEEXAMPLE"
        let mask: (String) -> String = { $0.replacingOccurrences(of: key, with: "•••") }
        let parsed = try #require(TaskDraft(title: "Rotate the key", notes: "old: \(key)", mask: mask))
        var draft = parsed
        draft.context = TaskContext(branch: "main", tab: "tab \(key)", resume: "claude --resume \(key)")
        for destination in TaskDestinationTests.every where destination != .todoFolder {
            let payload = try render(draft, destination, mask: mask)
            #expect(!payload.sent.contains(key) && !payload.sent.contains("sk-ant"), "\(destination)")
            if case .trello = destination { continue }
            #expect(payload.sent.contains("•••"), "\(destination)")
        }
        var leaky = Self.draft
        leaky.title = "Use \(key)"
        let link = try link(render(leaky, .github(owner: "o", repo: "r"), mask: mask))
        #expect(!link.contains("sk-ant") && link.contains("%E2%80%A2%E2%80%A2%E2%80%A2"))
    }

    @Test func theHostIsTheTemplates() throws {
        let hostile: [TaskDestination] = [.github(owner: "evil.com#", repo: "r"), .gitlab(path: "evil.com?/x"),
                                          .linear(team: "a/../../evil.com"), .azureBoards(org: "@evil.com", project: "p#", type: "Task"),
                                          .github(owner: "..", repo: "x")]
        for destination in hostile {
            let payload = TaskPayload.render(Self.draft, to: destination, project: "web", today: Self.today, mask: { $0 })
            #expect(payload == nil, "\(destination)")
        }
        let parts = TaskPayload.segments(["evil.com#", "a?b", "@x/y"])
        let url = try #require(URL(string: "https://github.com/" + parts + "/issues/new"))
        #expect(url.host == "github.com" && url.user == nil && url.fragment == nil && url.query == nil)
        #expect(url.path == "/evil.com#/a?b/@x/y/issues/new")
    }

    @Test func remindersDueDays() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try #require(Self.today.start(in: calendar)).addingTimeInterval(9 * 3600)
        let days: [TaskDay] = [
            try #require(When.parse("today", now: now, calendar: calendar)),
            try #require(When.parse("tomorrow", now: now, calendar: calendar)),
            When.nextWeek(after: now, calendar: calendar),
            try #require(TaskDay("2027-02-28")),
        ]
        for day in days {
            var draft = Self.draft
            draft.scheduled = .day(day)
            guard case .reminder(_, _, let due) = try render(draft, .reminders(listID: nil, listName: "L")).form else { throw Unexpected() }
            #expect(due == DateComponents(year: day.year, month: day.month, day: day.day))
            #expect(due?.hour == nil && due?.minute == nil)
        }
        var none = Self.draft
        none.scheduled = .none
        guard case .reminder(_, _, let due) = try render(none, .reminders(listID: nil, listName: "L")).form else { throw Unexpected() }
        #expect(due == nil)
    }

    func value(_ payload: TaskPayload, _ name: String) throws -> String {
        let url = try #require(URLComponents(string: try link(payload)))
        return url.queryItems?.first { $0.name == name }?.value ?? ""
    }

    func bare(_ notes: String, title: String = "Fix the login") -> TaskDraft {
        var draft = Self.draft
        draft.title = title
        draft.context = nil
        draft.steps = []
        draft.notes = notes
        return draft
    }

    @Test func gitlabRunsNoQuickActions() throws {
        let draft = bare("/assign @someone\n/label ~x\n/due tomorrow\nnot /due here")
        let gitlab = try value(render(draft, .gitlab(path: "g/p")), "issue[description]")
        #expect(gitlab == "\\/assign @someone\n\\/label ~x\n\\/due tomorrow\nnot /due here")
        let github = try value(render(draft, .github(owner: "o", repo: "r")), "body")
        #expect(github.hasPrefix("/assign @someone\n/label"))
    }

    @Test func aSingleLongLineIsCutInsideNotDropped() throws {
        let github = try render(bare(String(repeating: "a", count: 9_000)), .github(owner: "o", repo: "r"))
        let body = try value(github, "body")
        let githubLink = try link(github)
        #expect(github.cut && githubLink.utf8.count <= 6_000)
        #expect(body.hasPrefix(String(repeating: "a", count: 4_000)))
        #expect(body.hasSuffix("a…\n\n(Cut by Next Term to fit GitHub’s link length.)"))
        let azure = try render(bare(String(repeating: "b", count: 2_500)), .azureBoards(org: "o", project: "p", type: "Task"))
        let description = try value(azure, "[System.Description]")
        #expect(description.count <= 2_000 && description.hasPrefix(String(repeating: "b", count: 1_900)))
        #expect(description.hasSuffix("b…\n\n(Cut by Next Term: Azure Boards takes 2,000 characters.)"))
        let things = try render(bare(String(repeating: "n", count: 12_000)), .things(list: nil))
        let notes = try value(things, "notes")
        #expect(notes.utf16.count <= 10_000 && notes.hasPrefix(String(repeating: "n", count: 9_900)))
    }

    @Test func multibyteTextIsCutByTheLinkAndSaysSo() throws {
        let cjk = (1...30).map { _ in String(repeating: "漢", count: 49) }.joined(separator: "\n")
        let azure = try render(bare(cjk), .azureBoards(org: "o", project: "p", type: "Task"))
        let description = try value(azure, "[System.Description]")
        let azureLink = try link(azure)
        #expect(azure.cut && azureLink.utf8.count <= 6_000 && description.count < 2_000)
        #expect(description.hasSuffix("漢\n\n(Cut by Next Term to fit Azure Boards’s link length.)"))
        let github = try render(bare(cjk), .github(owner: "o", repo: "r"))
        let githubLink = try link(github)
        #expect(github.cut && githubLink.utf8.count <= 6_000)
        #expect(try value(github, "body").hasSuffix("漢\n\n(Cut by Next Term to fit GitHub’s link length.)"))
    }

    @Test func thingsCapsEveryValue() throws {
        let long = try render(bare("", title: String(repeating: "t", count: 5_000)), .things(list: String(repeating: "l", count: 4_500)))
        let title = try value(long, "title"), list = try value(long, "list")
        #expect(long.cut && title.utf16.count == 4_000 && title.hasSuffix("…"))
        #expect(list.utf16.count == 4_000 && list.hasSuffix("…"))
        var draft = bare("")
        draft.steps = (1...100).map { TaskDraft.Step(text: "\($0)" + String(repeating: "s", count: 1_000)) }
        let steps = try render(draft, .things(list: nil))
        let checklist = try value(steps, "checklist-items")
        #expect(checklist.utf16.count <= 4_000 && checklist.components(separatedBy: "\n").count == 3)
        #expect(try value(steps, "notes").hasPrefix("- [ ] 4sss"))
    }

    @Test func hiddenCharactersNeverReachTheTextOrTheView() throws {
        var draft = bare("one\r\ntwo\u{7}", title: "Fix\u{1b}[31m the\u{202E} login\u{2066}")
        draft.steps = [.init(text: "a\u{9b}b")]
        let agent = try render(draft, .throughAgent(tracker: "Linear"))
        guard case .agentRequest(let text) = agent.form else { throw Unexpected() }
        #expect(text.hasSuffix("Fix[31m the login\n\n- [ ] ab\n\none\ntwo"))
        #expect(agent.sent == text)
        let hidden = text.unicodeScalars.contains { TaskPayload.hidden($0) && $0 != "\n" }
        #expect(!hidden)
    }

    @Test func smallEdges() throws {
        let titleOnly = try render(bare("", title: String(repeating: "t", count: 7_000)), .github(owner: "o", repo: "r"))
        let url = try link(titleOnly)
        #expect(titleOnly.cut && url.utf8.count <= 6_000 && !url.contains("body=") && !url.contains("Cut%20by"))
        let shortcut = try render(bare("\n  \n\nHello\n\n"), .shortcut(id: "8F1C2D3E-0000-4000-8000-000000000001", name: "S"))
        #expect(shortcut.form == .stdin("Fix the login\n\nPlanned: 2026-10-19\n\nHello"))
    }
}
