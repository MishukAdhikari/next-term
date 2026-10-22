import Foundation
import Testing
@testable import NextTermCore

/// add_task beyond the todo folder: its answer per destination, the approval window's text, and every refusal that comes
/// before anyone is asked.
@Suite struct TasksMCPAnswerTests {
    static let today = TaskDay("2026-10-18")!
    static let draft = TaskDraft(title: "Fix the login", steps: [.init(text: "write test")], notes: "See PR 512.",
                                 scheduled: .day(TaskDay("2026-10-19")!), context: TaskContext(branch: "fix/login", addedBy: "you"))

    static func facts(_ change: (inout DestinationFacts) -> Void = { _ in }) -> DestinationFacts {
        var facts = DestinationFacts()
        facts.installed = [.things, .todoist, .omnifocus]
        facts.day = "Tomorrow, Sat 19 Oct"
        change(&facts)
        return facts
    }

    func plan(_ destination: TaskDestination, _ draft: TaskDraft = Self.draft, facts: DestinationFacts = Self.facts(),
              mask: @escaping (String) -> String = { $0 }) -> DestinationPlan {
        let rendered = TaskPayload.render(draft, to: destination, project: "web", today: Self.today, mask: mask)
        return DestinationPlan.make(rendered: [rendered], destination: destination, facts: facts, mask: mask)
    }

    @Test func theAnswerPerDestination() {
        let file = MCPServer.TaskFileAnswer(path: "/p/todo/2026-10-18-fix-the-login.md",
                                            relativePath: "todo/2026-10-18-fix-the-login.md", createdFolder: false)
        let folder = MCPServer.taskAnswer(approved: "on this Mac", sentTo: .todoFolder, draft: Self.draft, file: file, mask: { $0 })
        #expect(folder["destination"] as? String == "todo_folder" && folder["path"] as? String == file.path)
        #expect(folder["relative_path"] as? String == file.relativePath && folder["created_folder"] as? Bool == false)
        #expect(folder["waiting_for_user"] == nil && folder["note"] == nil)

        let things = MCPServer.taskAnswer(approved: "on this Mac", sentTo: .things(list: "Work"), draft: Self.draft, mask: { $0 })
        #expect(Set(things.keys) == ["approved", "destination", "title", "steps", "scheduled"])
        #expect(things["destination"] as? String == "things" && things["steps"] as? Int == 1 && things["scheduled"] as? String == "2026-10-19")

        let github = MCPServer.taskAnswer(approved: "on this Mac", sentTo: .github(owner: "o", repo: "r"), draft: Self.draft,
                                          mask: { $0 })
        #expect(github["destination"] as? String == "github" && github["waiting_for_user"] as? Bool == true)
        #expect(github["note"] as? String == "The page is open for the user to submit; nothing is added until they do.")

        let list = "Work key-123"
        let reminders = MCPServer.taskAnswer(approved: "on this Mac", sentTo: .reminders(listID: "id-1", listName: list),
                                             draft: Self.draft) { $0.replacingOccurrences(of: "key-123", with: "•••") }
        #expect(reminders["destination"] as? String == "reminders" && reminders["list"] as? String == "Work •••")
        #expect(reminders["waiting_for_user"] == nil)

        // Only the todo folder answers a path, even when a file is passed; never a link or an id.
        let all: [TaskDestination] = [.reminders(listID: "id-1", listName: "L"), .things(list: nil),
                                      .shortcut(id: "8F1C2D3E-0000-4000-8000-000000000001", name: "S"), .todoist, .omnifocus,
                                      .github(owner: "o", repo: "r"), .gitlab(path: "g/p"), .linear(team: nil), .trello,
                                      .azureBoards(org: "o", project: "p", type: "Task")]
        for destination in all {
            let answer = MCPServer.taskAnswer(approved: "x", sentTo: destination, draft: Self.draft, file: file, mask: { $0 })
            #expect(answer["path"] == nil && answer["relative_path"] == nil && answer["created_folder"] == nil, "\(destination)")
            #expect(answer["url"] == nil && answer["id"] == nil && JSONSerialization.isValidJSONObject(answer))
            #expect(answer["destination"] as? String == destination.kind.rawValue)
        }
        let quick: [TaskDestination] = [.todoist, .omnifocus, .gitlab(path: "g/p"), .linear(team: nil), .trello]
        for destination in quick {
            let answer = MCPServer.taskAnswer(approved: "x", sentTo: destination, draft: Self.draft, mask: { $0 })
            #expect(answer["waiting_for_user"] as? Bool == true, "\(destination)")
        }
    }

    @Test func theWindowShowsWhereAndExactlyWhatLeaves() throws {
        let github = TaskDestination.github(owner: "o", repo: "r")
        let made = plan(github)
        let details = MCPServer.taskDetails(made, duplicate: nil, mask: { $0 })
        #expect(details.hasPrefix("To: GitHub o/r: opens a new issue in o/r on github.com, filled in: nothing is created until you "
            + "press Create\n\n"))
        #expect(details.hasSuffix(made.sent.hasSuffix("\n") ? String(made.sent.dropLast()) : made.sent))
        // The text shown is what the link carries: its decoded title and body are both in the window.
        guard case .link(let url) = try #require(made.payloads.first).form else { Issue.record("no link"); return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let body = try #require(items.first { $0.name == "body" }?.value)
        let title = try #require(items.first { $0.name == "title" }?.value)
        #expect(details.contains(body) && details.contains(title) && body.contains("fix/login"))

        let again = MCPServer.taskDetails(made, duplicate: "GitHub o/r", mask: { $0 })
        #expect(again.hasPrefix("Added a minute ago. Add again? The same task went to GitHub o/r less than a minute ago.\nTo: GitHub o/r: "))

        let folder = DestinationPlan.todoFolder(line: "Saves to todo/2026-10-18-fix-the-login.md in web", texts: ["---\nfile\n"],
                                                refusal: false)
        #expect(MCPServer.taskDetails(folder, duplicate: nil, mask: { $0 })
            == "To: the todo folder: saves to todo/2026-10-18-fix-the-login.md in web\n\n---\nfile")
    }

    @Test func aStoredKeyIsMaskedInTheLineAndTheText() throws {
        let key = "sk-live-7f3c2a9b4d1e"
        let mask: (String) -> String = { $0.replacingOccurrences(of: key, with: "•••") }
        let masked = try #require(TaskDraft(title: "Rotate \(key)", notes: "It was \(key).", mask: mask))
        let destination = TaskDestination.github(owner: "o", repo: "r")
        let made = plan(destination, masked, mask: mask)
        let details = MCPServer.taskDetails(made, duplicate: nil, mask: mask)
        guard case .link(let url) = try #require(made.payloads.first).form else { Issue.record("no link"); return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let body = try #require(items.first { $0.name == "body" }?.value)
        #expect(!details.contains(key) && details.contains("Rotate •••") && details.contains(body) && !url.absoluteString.contains(key))
        // A list's name holding a key is masked in the line too.
        let list = plan(.reminders(listID: "id", listName: "Work \(key)"), masked, mask: mask)
        let shown = MCPServer.taskDetails(list, duplicate: nil, mask: mask)
        #expect(!shown.contains(key) && shown.hasPrefix("To: Reminders “Work •••”: adds to Reminders, list “Work •••”"))
    }

    @Test func refusedBeforeAnyoneIsAsked() {
        let none = Self.facts { $0.installed = [] }
        let mask: (String) -> String = { $0.replacingOccurrences(of: "key-9", with: "•••") }
        func refusal(_ destination: TaskDestination, problem: String? = nil, facts: DestinationFacts = Self.facts()) -> String? {
            MCPServer.taskRefusal(destination, savedProblem: problem, facts: facts, mask: mask)
        }
        #expect(refusal(.throughAgent(tracker: "Linear key-9")) == "This project’s tasks go to Linear ••• through your agent: post it "
            + "with your own Linear ••• tools, or pass destination todo_folder. Nothing was added.")
        let tail = "; pass destination todo_folder, or the user changes it in Tasks › Send Tasks To. Nothing was added."
        #expect(refusal(.things(list: nil), facts: none) == "Things isn’t installed" + tail)
        #expect(refusal(.todoist, facts: none) == "Todoist isn’t installed" + tail)
        #expect(refusal(.omnifocus, facts: none)?.hasSuffix(tail) == true)
        for step: RemindersAccess.Step in [.explain(.fullAccess), .blocked("Denied.", settings: true)] {
            let said = refusal(.reminders(listID: nil, listName: "Next Term"), facts: Self.facts { $0.reminders = step })
            #expect(said == "Next Term isn’t allowed to use Reminders yet; the user turns it on from Tasks › Add Task…" + tail)
        }
        let shortcut = TaskDestination.shortcut(id: "8F1C2D3E-0000-4000-8000-000000000001", name: "S")
        #expect(refusal(shortcut, facts: Self.facts { $0.shortcutListed = false }) == "The shortcut is gone" + tail)
        #expect(refusal(shortcut, facts: Self.facts { $0.shortcutListed = true }) == nil)
        #expect(refusal(.todoFolder, problem: "The saved destination is missing some of its details.")
            == "The saved destination is missing some of its details" + tail)
        let fine: [TaskDestination] = [.todoFolder, .reminders(listID: nil, listName: "L"), .things(list: nil), .todoist,
                                       .github(owner: "o", repo: "r"), .trello, .linear(team: nil)]
        for destination in fine { #expect(refusal(destination) == nil, "\(destination)") }
        #expect(MCPServer.taskDestinationChanged == "The project’s destination changed while the user was asked. Nothing was added.")
    }

    @Test func theProjectsDestinationIsReadFreshAndABadValueIsRefused() {
        var settings = TaskSettings()
        #expect(MCPServer.taskDestination(settings, projectKey: "/p").destination == .todoFolder)
        #expect(MCPServer.taskDestination(settings, projectKey: "/p").problem == nil)
        settings.defaultDestination = .things(list: nil)
        settings.projects["/p"] = ProjectTasks(destination: .github(owner: "o", repo: "r"))
        #expect(MCPServer.taskDestination(settings, projectKey: "/p").destination == .github(owner: "o", repo: "r"))
        #expect(MCPServer.taskDestination(settings, projectKey: "/q").destination == .things(list: nil))
        #expect(MCPServer.taskDestination(settings, projectKey: nil).destination == .things(list: nil))
        var broken = ProjectTasks()
        broken.problem = "The saved destination is missing some of its details."
        settings.projects["/b"] = broken
        #expect(MCPServer.taskDestination(settings, projectKey: "/b").problem == broken.problem)
    }
}
