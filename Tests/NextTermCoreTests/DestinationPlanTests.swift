import Foundation
import Testing
@testable import NextTermCore

/// The sheet's one line under Destination, its What's sent text, and whether Add may go, for every destination: the
/// same plan Add uses, so what is shown is what leaves.
@Suite struct DestinationPlanTests {
    static let today = TaskDay("2026-10-18")!
    static let tomorrow = TaskDay("2026-10-19")!
    static let draft = TaskDraft(title: "Finish the login fix", steps: [.init(text: "write test")], notes: "See PR 512.",
                                 scheduled: .day(tomorrow), context: TaskContext(branch: "fix/login", addedBy: "you"))
    static let shortcutID = "8F1C2D3E-0000-4000-8000-000000000001"

    static func facts(_ change: (inout DestinationFacts) -> Void = { _ in }) -> DestinationFacts {
        var facts = DestinationFacts()
        facts.installed = [.things, .todoist, .omnifocus]
        facts.day = "Tomorrow, Sat 19 Oct"
        facts.agentTab = .init(title: "api", agent: .claude, bracketedPaste: true)
        change(&facts)
        return facts
    }

    func plan(_ destination: TaskDestination, _ drafts: [TaskDraft] = [draft], facts: DestinationFacts = facts(),
              mask: @escaping (String) -> String = { $0 }) -> DestinationPlan {
        let rendered = drafts.map { TaskPayload.render($0, to: destination, project: "web", today: Self.today, mask: mask) }
        return DestinationPlan.make(rendered: rendered, destination: destination, facts: facts, mask: mask)
    }

    @Test func theLineForEachKind() {
        let lines: [(TaskDestination, String)] = [
            (.reminders(listID: "x", listName: "Next Term"), "Adds to Reminders, list “Next Term”, due Tomorrow, Sat 19 Oct"),
            (.things(list: "Work"), "Adds to Things, scheduled Tomorrow, Sat 19 Oct, in “Work”"),
            (.shortcut(id: Self.shortcutID, name: "Add to Inbox"), "Runs the shortcut “Add to Inbox” with the task as its input"),
            (.todoist, "Opens Todoist Quick Add, filled in: press Add there, and set the day there"),
            (.omnifocus, "Opens OmniFocus Quick Add, filled in: press Add there, and set the day there"),
            (.github(owner: "o", repo: "r"),
             "Opens a new issue in o/r on github.com, filled in: nothing is created until you press Create"),
            (.gitlab(path: "g/p"), "Opens a new issue in g/p on gitlab.com, filled in: nothing is created until you press Create"),
            (.linear(team: "ENG"),
             "Opens a new issue in team ENG on linear.app, filled in: nothing is created until you press Create"),
            (.linear(team: nil),
             "Opens a new issue on linear.new, filled in: choose the team there; nothing is created until you press Create"),
            (.trello, "Opens Trello’s Add Card with the title only: choose the board there"),
            (.azureBoards(org: "org", project: "web", type: "Task"),
             "Opens a new Task in org/web on dev.azure.com, filled in: nothing is created until you press Save"),
            (.throughAgent(tracker: "Linear"), "Types a request to post it to Linear into “api” (Claude Code), with no Return"),
        ]
        for (destination, line) in lines {
            let made = plan(destination)
            #expect(made.line == line)
            #expect(made.canAdd && !made.refused)
        }
    }

    @Test func remindersWords() {
        var noDay = Self.draft
        noDay.scheduled = .none
        let list = TaskDestination.reminders(listID: nil, listName: "Next Term")
        #expect(plan(list, [noDay], facts: Self.facts { $0.day = nil }).line
            == "Adds to Reminders, list “Next Term”, no due date")
        #expect(plan(list, facts: Self.facts { $0.makesList = true }).line
            == "Adds to Reminders, new list “Next Term”, due Tomorrow, Sat 19 Oct")
        let asks = plan(list, facts: Self.facts { $0.reminders = .explain(.fullAccess) })
        #expect(asks.line == "Adds to Reminders, list “Next Term”, due Tomorrow, Sat 19 Oct · Reminders asks for permission first")
        let denied = plan(list, facts: Self.facts { $0.reminders = .blocked(RemindersAccess.deniedLine, settings: true) })
        #expect(denied.refused && denied.line == RemindersAccess.deniedLine && denied.offersTodoFolder)
        #expect(plan(.things(list: nil), [noDay], facts: Self.facts { $0.day = nil }).line == "Adds to Things’ Inbox")
        #expect(plan(.reminders(listID: nil, listName: "Next Term")).addTitle == "Add Task")
    }

    @Test func refusalsTurnAddOff() {
        let things = plan(.things(list: nil), facts: Self.facts { $0.installed = [] })
        #expect(things.refused && things.line == "Things isn’t installed: choose another destination or Use Todo Folder")
        #expect(things.offersTodoFolder && !things.canAdd)
        let gone = plan(.shortcut(id: Self.shortcutID, name: "Inbox"), facts: Self.facts { $0.shortcutListed = false })
        #expect(gone.refused && gone.line == ShortcutList.goneLine)
        let none = plan(.throughAgent(tracker: "Linear"), facts: Self.facts { $0.agentTab = nil })
        #expect(none.refused && none.line == DestinationPlan.noReadyTab && !none.offersTodoFolder)
        let busy = plan(.throughAgent(tracker: "Linear"), facts: Self.facts { $0.agentTab?.notReady = .working })
        #expect(busy.refused && busy.line == "“api” (Claude Code) isn’t ready: working. Nothing was typed.")
    }

    @Test func addSaysWhatItDoes() {
        #expect(plan(.things(list: nil)).addTitle == "Add Task")
        #expect(plan(.shortcut(id: Self.shortcutID, name: "Inbox")).addTitle == "Add Task")
        #expect(plan(.github(owner: "o", repo: "r")).addTitle == "Open Page")
        #expect(plan(.trello).addTitle == "Open Page")
        #expect(plan(.todoist).addTitle == "Open Quick Add")
        #expect(plan(.throughAgent(tracker: "Linear")).addTitle == "Type into Tab")
        #expect(DestinationPlan.todoFolder(line: "Saves to todo/a.md", texts: ["a"], refusal: false).addTitle == "Add Task")
    }

    @Test func aCutEndsTheLine() {
        var long = Self.draft
        long.notes = (1...900).map { "line \($0) of a long note" }.joined(separator: "\n")
        let made = plan(.github(owner: "o", repo: "r"), [long])
        #expect(made.cut && made.line.hasSuffix(" · cut to fit"))
        #expect(made.sent.contains("(Cut by Next Term"))
    }

    @Test func todoFolderLineIsSliceOnes() {
        let line = "Saves to todo/2026-10-19-finish-the-login-fix.md in next-term"
        let made = DestinationPlan.todoFolder(line: line, texts: ["file text\n"], refusal: false)
        #expect(made.line == line && made.sent == "file text\n" && made.canAdd)
        let two = DestinationPlan.todoFolder(line: line, texts: ["one\n", "two\n"], refusal: false)
        #expect(two.sent == "1 of 2\n\none\n\n\n2 of 2\n\ntwo\n")
        #expect(!DestinationPlan.todoFolder(line: "No folder.", texts: [], refusal: true).canAdd)
    }

    /// Each link's query, decoded as the app or page reads it: `+` is a space only where the renderer wrote spaces so.
    func decoded(_ url: URL, plusSpaces: Bool) -> [String] {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        return query.split(separator: "&").flatMap { pair -> [String] in
            let sides = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let value = plusSpaces ? sides[1].replacingOccurrences(of: "+", with: " ") : sides[1]
            return [sides[0].removingPercentEncoding ?? "", value.removingPercentEncoding ?? ""]
        }
    }

    @Test func sentIsWhatTheLinkCarries() throws {
        var draft = Self.draft
        draft.title = "Fix a&b + c #1"
        draft.notes = "first line\nsecond & third + #4"
        let kinds: [TaskDestination] = [.things(list: "Work"), .todoist, .omnifocus, .github(owner: "o", repo: "r"),
                                        .gitlab(path: "g/p"), .linear(team: "ENG"), .linear(team: nil), .trello,
                                        .azureBoards(org: "org", project: "web", type: "Task")]
        for destination in kinds {
            let made = plan(destination, [draft])
            guard case .link(let url) = try #require(made.payloads.first).form else { throw Unexpected() }
            let pairs = decoded(url, plusSpaces: destination.kind == .linear)
            var lines: [String] = []
            for index in stride(from: 0, to: pairs.count, by: 2) { lines.append(pairs[index] + "\n" + pairs[index + 1]) }
            let place = try #require(made.sent.components(separatedBy: "\n\n").first)
            #expect(made.sent == ([place] + lines).joined(separator: "\n\n"))
            #expect(pairs[1].hasPrefix("Fix a&b + c #1") || destination.kind == .things)
        }
    }

    @Test func aStoredKeyStaysMasked() {
        let secret = "nt-made-up-key-1234"
        let mask = { (text: String) in text.replacingOccurrences(of: secret, with: "•••") }
        let draft = TaskDraft(title: "Rotate \(secret)", steps: [], notes: "It was \(secret).", scheduled: .day(Self.tomorrow))
        let facts = Self.facts { $0.agentTab = .init(title: "tab \(secret)", agent: .codex, bracketedPaste: true) }
        let kinds: [TaskDestination] = [.reminders(listID: nil, listName: "Next Term"), .things(list: nil),
                                        .shortcut(id: Self.shortcutID, name: "Inbox"), .todoist, .omnifocus,
                                        .github(owner: "o", repo: "r"), .gitlab(path: "g/p"), .linear(team: nil), .trello,
                                        .azureBoards(org: "org", project: "web", type: "Task"),
                                        .throughAgent(tracker: "Linear")]
        for destination in kinds {
            let made = plan(destination, [draft], facts: facts, mask: mask)
            #expect(!made.sent.contains(secret) && !made.line.contains(secret))
            #expect(made.sent.contains("•••"))
        }
        let agent = plan(.throughAgent(tracker: "Linear"), [draft], facts: facts, mask: mask)
        #expect(agent.line.contains("“tab •••”") && agent.typed?.contains(secret) == false)
    }

    @Test func theAgentRequestKeepsOrJoinsLines() throws {
        let tracker = TaskDestination.throughAgent(tracker: "Linear")
        let pasted = plan(tracker)
        let typed = try #require(pasted.typed)
        #expect(typed.contains("\n") && pasted.sent == typed)
        let flat = plan(tracker, facts: Self.facts { $0.agentTab?.bracketedPaste = false })
        let line = try #require(flat.typed)
        #expect(!line.contains("\n") && !line.contains("\r") && flat.sent == line)
        #expect(line == "Add this task to Linear with your Linear tools, exactly as written, then tell me its link. / "
            + "Finish the login fix / - [ ] write test / See PR 512. / Branch: fix/login")
        let three = (1...3).map { TaskDraft(title: "Task \($0)", steps: []) }
        let refused = plan(tracker, three, facts: Self.facts { $0.agentTab?.bracketedPaste = false })
        #expect(refused.refused && refused.line == "“api” takes one line at a time: add these one by one.")
        let together = try #require(plan(tracker, three).typed)
        #expect(together == "Add these 3 tasks to Linear with your Linear tools, exactly as written, then tell me their "
            + "links.\n\n1. Task 1\n\n2. Task 2\n\n3. Task 3")
        #expect(plan(tracker, three).line == "Types a request to post 3 tasks to Linear into “api” (Claude Code), with no Return")
    }

    @Test func severalTasks() {
        let six = (1...6).map { TaskDraft(title: "Card \($0)", steps: []) }
        let over = plan(.trello, six)
        #expect(over.refused && over.line == "Trello opens one page per task: add at most 5 at once.")
        let five = plan(.trello, Array(six.prefix(5)))
        #expect(five.canAdd && five.payloads.count == 5)
        #expect(five.line == "Opens Trello’s Add Card for each of 5 tasks with the title only: choose the board there")
        #expect(five.sent.hasPrefix("1 of 5\n\ntrello.com/add-card\n\nname\nCard 1\n\n2 of 5\n\n"))
        let quick = plan(.todoist, six)
        #expect(quick.refused && quick.line == "Todoist opens one Quick Add per task: add at most 5 at once.")
        #expect(plan(.reminders(listID: "x", listName: "Inbox"), six).line
            == "Adds 6 tasks to Reminders, list “Inbox”, due Tomorrow, Sat 19 Oct")
        #expect(plan(.github(owner: "o", repo: "r"), Array(six.prefix(2))).line
            == "Opens 2 new issues in o/r on github.com, filled in: nothing is created until you press Create")
    }

    struct Unexpected: Error {}
}
