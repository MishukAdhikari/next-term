import AppKit
import NextTermCore

#if DEBUG
/// add_task with a project destination, through `nxtrm mcp`, with every opener recorded and Reminders in memory: a
/// project with none set still writes the todo file; Through your agent, an app not installed and Reminders not yet
/// allowed are refused with no window, and Reminders is never asked; a GitHub project opens one recorded page after
/// Approve and none after Decline; a destination changed while the window waits sends nothing; the same title twice
/// within a minute says so. Called from `tasksChecks`, which puts the Tasks settings back after.
extension SelfTest {
    static func addTaskDestinationChecks(_ c: TerminalWindowController, proj: URL, folder: URL) async {
        let server = MCPControlServer.shared
        guard server.isRunning, let mcp = MCPTestClient(socket: server.path) else {
            return check(false, "add_task destinations: `nxtrm mcp` starts")
        }
        let savedWait = MCPWriteControl.answerWithin
        MCPWriteControl.answerWithin = 20
        TaskOpen.recordsOnly = true
        TaskOpen.opened = []
        TaskOpen.fakeInstalled = []
        let fake = FakeRemindersStore(status: .notDetermined)
        TaskReminders.fake = fake
        TaskReminders.fakeOS = 14
        let key = TaskSettings.projectKey(proj.path)
        defer {
            mcp.close()
            MCPWriteControl.answerWithin = savedWait
            MCPWriteControl.stopped = []
            TaskOpen.recordsOnly = false
            TaskOpen.opened = []
            TaskOpen.fakeInstalled = nil
            TaskReminders.fake = nil
            TaskReminders.fakeOS = nil
            TasksMenu.save(nil, key: key)
            GitToast.dismiss()
        }
        _ = await mcp.call(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:],
                                             "clientInfo": ["name": "selftest", "version": "1"]])
        let client = TaskClient(mcp)
        TasksMenu.save(nil, key: key)
        UserDefaults.standard.removeObject(forKey: TaskSettings.Key.defaultDestination)

        // No destination set: today's todo file, answered as the todo folder.
        let plain = await client.asked(["title": "Plain destination check", "project": proj.path], approve: true)
        let plainFile = folder.appendingPathComponent("\(TaskDay(Date(), calendar: .current))-plain-destination-check.md")
        let plainAnswer = taskJSON(plain.text)
        check(!plain.isError && plainAnswer["destination"] as? String == "todo_folder"
                && FileManager.default.fileExists(atPath: plainFile.path),
              "add_task destinations: with none set the task is the todo file", plain.text)
        try? FileManager.default.removeItem(at: plainFile)

        await refusedChecks(client, proj: proj, key: key, folder: folder, fake: fake)
        await pageToolChecks(client, proj: proj, key: key)
    }

    /// Refused with no window: Through your agent (and passed with todo_folder), an app not installed, Reminders not
    /// allowed yet, which is never asked for.
    private static func refusedChecks(_ client: TaskClient, proj: URL, key: String, folder: URL,
                                      fake: FakeRemindersStore) async {
        TasksMenu.save(.throughAgent(tracker: "Linear"), key: key)
        let agent = await client.call(["title": "Through the agent", "project": proj.path])
        check(agent.isError && agent.text == MCPServer.taskThroughAgent("Linear") && MCPWriteControl.pending == nil,
              "add_task destinations: Through your agent is refused with no window", agent.text)
        let local = await client.asked(["title": "Into the todo folder", "project": proj.path,
                                        "destination": "todo_folder"], approve: true)
        let localPath = taskJSON(local.text)["path"] as? String ?? ""
        check(!local.isError && local.shown.contains("To: the todo folder: saves to")
                && FileManager.default.fileExists(atPath: localPath),
              "add_task destinations: destination todo_folder asks and writes the file", local.text)
        try? FileManager.default.removeItem(atPath: localPath)

        TasksMenu.save(.things(list: nil), key: key)
        let things = await client.call(["title": "Into Things", "project": proj.path])
        check(things.isError && things.text.hasPrefix("Things isn’t installed;") && MCPWriteControl.pending == nil,
              "add_task destinations: an app not installed is refused with no window", things.text)

        TasksMenu.save(.reminders(listID: nil, listName: "Next Term"), key: key)
        let reminders = await client.call(["title": "Into Reminders", "project": proj.path])
        let asked = TaskReminders.quiet { fake.asked }
        check(reminders.isError && reminders.text.hasPrefix(MCPServer.taskRemindersNotAllowed) && asked.isEmpty
                && MCPWriteControl.pending == nil,
              "add_task destinations: Reminders not allowed is refused, and macOS is never asked", reminders.text)
    }

    /// A GitHub project: Approve records one page and one posted line and answers that the page waits; Decline
    /// records nothing; a change while the window waits sends nothing; the same title again says so.
    private static func pageToolChecks(_ client: TaskClient, proj: URL, key: String) async {
        let github = TaskDestination.github(owner: "example-org", repo: "web")
        TasksMenu.save(github, key: key)
        TaskOpen.opened = []
        let before = postedToday()
        let title = "Open the tool page"
        let approved = await client.asked(["title": title, "project": proj.path], approve: true)
        let answer = taskJSON(approved.text)
        check(!approved.isError && answer["destination"] as? String == "github" && answer["waiting_for_user"] as? Bool == true
                && answer["path"] == nil,
              "add_task destinations: a GitHub project's task answers that the page waits for the user", approved.text)
        check(approved.shown.contains("To: GitHub example-org/web: opens a new issue") && approved.shown.contains(title),
              "add_task destinations: the window names the page and shows what it carries", approved.shown)
        check(TaskOpen.opened.count == 1 && TaskOpen.opened.first?.host == "github.com",
              "add_task destinations: Approve records one github.com link and opens nothing",
              TaskOpen.opened.map(\.absoluteString).joined(separator: " "))
        check(await wait(3) { postedToday() == before + 1 }, "add_task destinations: one line goes in the posted record")

        TaskOpen.opened = []
        let declined = await client.asked(["title": title, "project": proj.path], approve: false)
        check(declined.isError && TaskOpen.opened.isEmpty, "add_task destinations: Decline opens nothing", declined.text)
        check(declined.shown.contains("Added a minute ago. Add again?"),
              "add_task destinations: the same title within a minute says so", declined.shown)

        let changed = await client.asked(["title": "Changed meanwhile", "project": proj.path], approve: true) {
            TasksMenu.save(.trello, key: key)
        }
        check(changed.isError && changed.text == MCPServer.taskDestinationChanged && TaskOpen.opened.isEmpty,
              "add_task destinations: a destination changed while the window waits sends nothing", changed.text)
    }

    static func taskJSON(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }
}
#endif
