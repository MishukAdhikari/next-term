import Foundation
import Testing
@testable import NextTermCore

/// add_task after the window: what counts as the destination changing while it waited, which destinations always ask on
/// the Mac, the list the answer names, and what TasksMCP.swift never does.
@Suite struct TasksMCPSendTests {
    @Test func aListIDSavedMeanwhileIsNoChange() {
        let shown = TaskDestination.reminders(listID: nil, listName: "Next Term")
        // The sheet's Add found or made the list and saved its id: the user changed nothing.
        #expect(MCPServer.taskSameDestination(shown, now: .reminders(listID: "list-1", listName: "Next Term")))
        #expect(MCPServer.taskSameDestination(shown, now: shown))
        #expect(!MCPServer.taskSameDestination(shown, now: .reminders(listID: nil, listName: "Work")))
        #expect(!MCPServer.taskSameDestination(shown, now: .reminders(listID: "list-1", listName: "Work")))
        // A saved id that changes is another list.
        let saved = TaskDestination.reminders(listID: "list-1", listName: "Next Term")
        #expect(!MCPServer.taskSameDestination(saved, now: .reminders(listID: "list-2", listName: "Next Term")))
        #expect(!MCPServer.taskSameDestination(saved, now: shown))
        #expect(MCPServer.taskSameDestination(.trello, now: .trello))
        #expect(!MCPServer.taskSameDestination(.github(owner: "o", repo: "r"), now: .github(owner: "o", repo: "s")))
        #expect(!MCPServer.taskSameDestination(shown, now: .todoFolder))
    }

    @Test func everyDestinationButTheTodoFolderAsksOnTheMac() {
        #expect(!MCPServer.taskAlwaysAsks(.todoFolder))
        let leaving: [TaskDestination] = [.reminders(listID: nil, listName: "L"), .things(list: nil),
                                          .shortcut(id: "8F1C2D3E-0000-4000-8000-000000000001", name: "S"), .todoist,
                                          .omnifocus, .github(owner: "o", repo: "r"), .gitlab(path: "g/p"),
                                          .linear(team: nil), .trello, .azureBoards(org: "o", project: "p", type: "Task"),
                                          .throughAgent(tracker: "Linear")]
        for destination in leaving { #expect(MCPServer.taskAlwaysAsks(destination), "\(destination)") }
    }

    @Test func theAnswerNamesTheListTheReminderWentTo() {
        let draft = TaskDraft(title: "Fix the login", steps: [])
        let mask: (String) -> String = { $0.replacingOccurrences(of: "key-1", with: "•••") }
        let destination = TaskDestination.reminders(listID: "gone", listName: "Next Term")
        let taken = MCPServer.taskAnswer(approved: "on this Mac", sentTo: destination, draft: draft, list: "Home key-1",
                                         mask: mask)
        #expect(taken["list"] as? String == "Home •••")
        let saved = MCPServer.taskAnswer(approved: "on this Mac", sentTo: destination, draft: draft, mask: mask)
        #expect(saved["list"] as? String == "Next Term")
        // A list is said only for Reminders.
        let things = MCPServer.taskAnswer(approved: "x", sentTo: .things(list: nil), draft: draft, list: "Home", mask: mask)
        #expect(things["list"] == nil)
    }

    @Test func theDayIsLowercaseMidLine() {
        var facts = DestinationFacts()
        facts.installed = [.things]
        let draft = TaskDraft(title: "Fix the login", steps: [], scheduled: .day(TaskDay("2026-10-19")!))
        func line(_ destination: TaskDestination, _ day: String) -> String {
            facts.day = day
            let rendered = TaskPayload.render(draft, to: destination, project: "web", today: TaskDay("2026-10-18")!,
                                              mask: { $0 })
            return DestinationPlan.make(rendered: [rendered], destination: destination, facts: facts, mask: { $0 }).line
        }
        #expect(line(.things(list: nil), "Tomorrow, Sat 19 Oct") == "Adds to Things, scheduled tomorrow, Sat 19 Oct")
        #expect(line(.reminders(listID: "x", listName: "L"), "Today, Sat 19 Oct")
            == "Adds to Reminders, list “L”, due today, Sat 19 Oct")
        // A plain date keeps the weekday's capital.
        #expect(line(.things(list: nil), "Mon 21 Oct") == "Adds to Things, scheduled Mon 21 Oct")
    }

    @Test func theToolNeverLogsStartsAProcessOrReachesTheNetwork() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = ["Sources/NextTerm/TasksMCP.swift", "Sources/NextTermCore/MCPTaskDestinations.swift",
                     "Sources/NextTermCore/MCPTaskTools.swift"]
        let banned = ["print(", "NSLog", "os_log", "Logger", "Process(", "NSTask", "URLSession", "URLRequest",
                      "NWConnection", "import Network"]
        for file in files {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for word in banned { #expect(!source.contains(word), "\(file): \(word)") }
        }
    }
}
