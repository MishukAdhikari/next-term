import AppKit
import CryptoKit
import NextTermCore

/// Tasks, end to end: the Tasks menu after Agents with Add Task… on ⌃⌘T; the sheet filled from a terminal selection, the
/// bytes it writes as TodoFile renders them, its notice's Undo, and a second add within a minute; add_task through
/// `nxtrm mcp` (Approve, Decline, no answer, a stored key shown as •••, a day it can't read, no project, a worktree
/// window); Settings › Tasks right before Secrets; Reminders with an in-memory store, never the user's own; and Run a
/// Shortcut with a fake runner, which starts no command.
/// Everything goes to the self-test project's own todo folder, or to a repository of the part's own, and is removed
/// after. NEXTTERM_SELFTEST_ONLY=tasks runs it alone.
extension SelfTest {
    static func tasksChecks(_ given: TerminalWindowController, proj: URL) async {
        // The part works in a window of the test project's own: the self-test's first window has no project of its own,
        // it follows its tab, and a todo folder belongs to a project.
        let opened = given.project == nil ? AppDelegate.shared.openWindow(directory: proj.path, project: canonicalPath(proj.path)) : nil
        let c = opened ?? given
        defer { if let opened, !opened.hasClosed { opened.window?.close() } }
        let defaults = UserDefaults.standard
        let saved = TaskSettings.Key.all.map { defaults.object(forKey: $0) }
        let savedBindings = defaults.data(forKey: "keyBindings")
        TaskSettings.Key.all.forEach(defaults.removeObject(forKey:))
        let shortcuts = KeyboardShortcuts.shared
        shortcuts.bindings = KeyBindings()
        shortcuts.apply()
        let folder = TodoFolder.resolve(project: c.project, settings: TaskSettings()).folder
        let hadFolder = folder.map { FileManager.default.fileExists(atPath: $0.path) } ?? true
        defer {
            for (key, value) in zip(TaskSettings.Key.all, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            defaults.set(savedBindings, forKey: "keyBindings")
            shortcuts.apply()
            GitToast.dismiss()
            // The todo folder this part made in the self-test's project, and nothing else.
            if !hadFolder, let folder { try? FileManager.default.removeItem(at: folder) }
        }
        guard let folder else { return check(false, "tasks: the self-test's project has a todo folder", c.project ?? "no project") }
        tasksMenuChecks(c, folder: folder)
        await addTaskSheetChecks(c, folder: folder)
        await addTaskToolChecks(c, proj: proj, folder: folder)
        taskSettingsChecks()
        #if DEBUG
        await remindersChecks(c)
        await shortcutChecks()
        await destinationSheetChecks(c)
        await sendTasksToChecks(c, other: given)
        #else
        // Its in-memory store is debug-only, so a release build never reaches the user's real Reminders.
        note("reminders: skipped in a release build; its checks run in a debug build")
        // Its fake runner is debug-only, so a release build never runs the user's shortcuts.
        note("shortcut: skipped in a release build; its checks run in a debug build")
        // Its openers record only in a debug build, so a release build never opens a page or an app.
        note("destinations: skipped in a release build; its checks run in a debug build")
        note("send to: skipped in a release build; its checks run in a debug build")
        #endif
    }

    /// Today's date as the files are named, on this Mac.
    private static var today: String { TaskDay(Date(), calendar: .current).description }

    private static func read(_ path: String) -> String? { FileManager.default.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) } }

    /// The bar's order, the menu's items, Add Task…'s key, and Show Todo Folder off until the folder is there.
    private static func tasksMenuChecks(_ c: TerminalWindowController, folder: URL) {
        let bar = NSApp.mainMenu?.items ?? []
        check(bar.dropFirst().map(\.title) == MenuBar.titles, "tasks: the menu bar's order is MenuBar.titles, with Tasks right after Agents",
              bar.map(\.title).joined(separator: ", "))
        guard let menu = bar.first(where: { $0.title == "Tasks" })?.submenu else { return check(false, "tasks: the menu bar has Tasks") }
        let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        check(titles == ["Add Task…", "Show Todo Folder", "—", "Send Tasks To", "Task Settings…"],
              "tasks: Add Task…, Show Todo Folder, Send Tasks To, then Task Settings…", titles.joined(separator: " | "))
        // Send Tasks To ▸ is filled when it opens, so no destination is a command with a key.
        let sendTo = menu.items.first { $0.title == "Send Tasks To" }
        let listed = KeyboardShortcuts.shared.commands.contains { $0.path.hasPrefix("Tasks › Send Tasks To") }
        check(sendTo?.submenu?.items.isEmpty == true && !listed,
              "tasks: Send Tasks To is empty until it opens, and Keyboard Shortcuts lists none of its rows")
        let add = menu.items.first { $0.action == #selector(TasksMenu.addTask(_:)) }
        let command = KeyboardShortcuts.shared.commands.first { $0.id == "addTask:" }
        let keyed = add.flatMap(KeyboardShortcuts.chord(of:))?.display == "⌃⌘T" && add?.target === TasksMenu.shared
        check(keyed && command?.path == "Tasks" && command?.defaultChord == MenuKeys.defaults["addTask:"],
              "tasks: Add Task… is ⌃⌘T, and Settings › Keyboard Shortcuts lists it under Tasks", command?.path ?? "not listed")
        if !FileManager.default.fileExists(atPath: folder.path) {
            check(TasksMenu.shared.existingFolder(of: c) == nil, "tasks: Show Todo Folder is off while the project has no todo folder")
        }
    }

    /// The sheet: its prefill, its lines, the file's bytes, Undo, Undo after an edit, and a second add within a minute.
    private static func addTaskSheetChecks(_ c: TerminalWindowController, folder: URL) async {
        let fm = FileManager.default
        guard let tab = c.activeTab, tab.remote == nil else { return check(false, "tasks: the window has a tab") }
        c.window?.makeFirstResponder(tab.view)
        tab.view.feed(text: "\r\nFinish the login fix:\r\n")
        tab.view.selectAll(nil)
        AddTaskSheet.present(over: c)
        guard await wait(5, { AddTaskSheet.current != nil }), let sheet = AddTaskSheet.current else {
            return check(false, "tasks: Add Task… opens its sheet over the window")
        }
        check(sheet.promptText.contains("Finish the login fix:"), "tasks: the sheet starts from the terminal's selection", sheet.promptText)
        sheet.type("Finish the login fix:\n- write test\n  - expired\n- ask Sam\n\nSee PR 512.")
        sheet.choose(.tomorrow)
        let tomorrow = When.days(1, after: Date(), calendar: .current).description
        check(sheet.summaryText.hasPrefix("Finish the login fix · 3 steps · notes · Tomorrow, "),
              "tasks: the sheet's line says the title, its steps, notes and the day", sheet.summaryText)
        let name = "\(today)-finish-the-login-fix.md"
        let projectName = (c.project.map { ($0 as NSString).lastPathComponent }) ?? ""
        check(sheet.placeText.hasPrefix("Saves to todo/\(name) in \(projectName)") && sheet.placeText.contains("makes the todo folder"),
              "tasks: and where it goes, with the folder it makes", sheet.placeText)
        sheet.pressAdd()
        let file = folder.appendingPathComponent(name).path
        guard await wait(3, { fm.fileExists(atPath: file) }), let written = read(file) else {
            return check(false, "tasks: ⌘↩ adds the task as todo/\(name)")
        }
        // The bytes are TodoFile.render's for the same draft at the time written in it.
        let createdLine = written.split(separator: "\n").first { $0.hasPrefix("created: ") }.map { String($0.dropFirst(9)) } ?? ""
        let created = ISO8601DateFormatter().date(from: createdLine)
        let expected = created.flatMap { sheet.texts(at: $0).first }
        check(written == expected && written.contains("scheduled: \(tomorrow)\n") && written.contains("added_by: you\n"),
              "tasks: the file holds exactly what TodoFile renders, scheduled for tomorrow and added by you", written)
        check(written.hasSuffix("- [ ] Finish the login fix\n  - [ ] write test\n    - [ ] expired\n  - [ ] ask Sam\n\nSee PR 512.\n"),
              "tasks: the title's box, its steps nested under it, then the notes", written)
        check(GitToast.text == "Added to todo/" && AddTaskSheet.current == nil, "tasks: a notice says where it went, with Undo",
              GitToast.text ?? "no notice")
        check(TasksMenu.shared.existingFolder(of: c)?.path == folder.path, "tasks: Show Todo Folder is on once the folder is there")
        GitToast.pressButtonForTest()
        check(!fm.fileExists(atPath: file) && !fm.fileExists(atPath: folder.path),
              "tasks: Undo moves the unchanged file to the Trash, and the folder made for it goes too")

        // Undo after an edit leaves the file, and says so.
        guard let edited = await addFromSheet(c, "Edit me later", folder: folder) else { return }
        try? Data("- [x] Edit me later\n".utf8).write(to: edited)
        GitToast.pressButtonForTest()
        check(fm.fileExists(atPath: edited.path) && GitToast.text?.contains("edited since") == true,
              "tasks: Undo after the file was edited leaves it, and says why", GitToast.text ?? "no notice")

        // The same title again within a minute asks first; Cancel adds nothing, Add Again adds the next name.
        AddTaskSheet.present(over: c)
        guard await wait(5, { AddTaskSheet.current != nil }), let again = AddTaskSheet.current else {
            return check(false, "tasks: the sheet opens again")
        }
        again.type("Edit me later")
        again.pressAdd()
        let asked = await wait(3) { again.askingAgain?.contains("Added a minute ago. Add again?") == true }
        again.answerAgain(false)
        let second = folder.appendingPathComponent("\(today)-edit-me-later-2.md").path
        check(asked && !fm.fileExists(atPath: second), "tasks: a second add of the same title within a minute asks, and Cancel adds nothing",
              again.askingAgain ?? "no question")
        again.pressAdd()
        _ = await wait(3) { again.askingAgain != nil }
        again.answerAgain(true)
        check(await wait(3) { fm.fileExists(atPath: second) }, "tasks: Add Again adds it under the next name")
        GitToast.dismiss()
    }

    /// Adds `prompt` from a fresh sheet; the file it wrote.
    private static func addFromSheet(_ c: TerminalWindowController, _ prompt: String, folder: URL) async -> URL? {
        AddTaskSheet.present(over: c)
        guard await wait(5, { AddTaskSheet.current != nil }), let sheet = AddTaskSheet.current else {
            check(false, "tasks: the sheet opens for “\(prompt)”")
            return nil
        }
        sheet.type(prompt)
        sheet.pressAdd()
        let file = folder.appendingPathComponent("\(today)-\(TodoFile.slug(prompt)).md")
        guard await wait(3, { FileManager.default.fileExists(atPath: file.path) }) else {
            check(false, "tasks: “\(prompt)” is added", sheet.placeText)
            return nil
        }
        return file
    }

    /// add_task through `nxtrm mcp`, as an agent outside the tabs calls it.
    private static func addTaskToolChecks(_ c: TerminalWindowController, proj: URL, folder: URL) async {
        let fm = FileManager.default
        let server = MCPControlServer.shared
        guard server.isRunning, let mcp = MCPTestClient(socket: server.path) else { return check(false, "tasks: `nxtrm mcp` starts") }
        let savedWait = MCPWriteControl.answerWithin
        let savedMask = SecretMask.current
        MCPWriteControl.answerWithin = 20
        defer {
            mcp.close()
            MCPWriteControl.answerWithin = savedWait
            MCPWriteControl.stopped = []
            SecretMask.current = savedMask
        }
        _ = await mcp.call(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "selftest", "version": "1"]])
        let client = TaskClient(mcp)
        func call(_ arguments: [String: Any]) async -> (text: String, isError: Bool) { await client.call(arguments) }
        func asked(_ arguments: [String: Any], approve: Bool?) async -> TaskClient.Asked { await client.asked(arguments, approve: approve) }
        func json(_ text: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:] }

        // Approve: the file, and an answer that says where it went.
        let arguments: [String: Any] = ["title": "Ship the tasks part", "notes": "- read the plan\n\nFrom the self-test.", "when": "tomorrow",
                                        "project": proj.path, "reason": "So it is there tomorrow."]
        let approved = await asked(arguments, approve: true)
        let answer = json(approved.text)
        let relative = "todo/\(today)-ship-the-tasks-part.md"
        let path = folder.appendingPathComponent("\(today)-ship-the-tasks-part.md").path
        let answered = answer["destination"] as? String == "todo_folder" && answer["relative_path"] as? String == relative
            && answer["approved"] as? String == "on this Mac" && answer["steps"] as? Int == 1
        check(!approved.isError && answered && fm.fileExists(atPath: path), "tasks: add_task writes the task once the user approves", approved.text)
        let shownFile = read(path).map { approved.shown.contains($0.trimmingCharacters(in: .newlines)) } ?? false
        check(approved.shown.contains("An agent asks to add a task") && approved.shown.contains("Creates \(relative)") && shownFile,
              "tasks: the window names the file and shows its exact text", approved.shown)
        check(read(path)?.contains("added_by: \"an agent outside Next Term’s tabs\"\n") == true, "tasks: the file says who asked", read(path) ?? "")

        // The same task again within a minute: the window says so. Decline writes nothing.
        let declined = await asked(arguments, approve: false)
        let declinedPath = folder.appendingPathComponent("\(today)-ship-the-tasks-part-2.md").path
        check(declined.isError && declined.text.contains("Declined on the Mac") && !fm.fileExists(atPath: declinedPath),
              "tasks: Decline writes nothing", declined.text)
        check(declined.shown.contains("Added a minute ago. Add again?"), "tasks: the window says the same task was added a minute ago", declined.shown)

        // No answer within the wait: nothing written, and the window goes.
        MCPWriteControl.answerWithin = 2
        let unanswered = await asked(["title": "Nobody answers this", "project": proj.path], approve: nil)
        MCPWriteControl.answerWithin = 20
        let none = folder.appendingPathComponent("\(today)-nobody-answers-this.md").path
        check(unanswered.isError && unanswered.text.contains("No answer on the Mac") && !fm.fileExists(atPath: none) && MCPWriteControl.pending == nil,
              "tasks: with no answer nothing is written", unanswered.text)

        // A stored key shows as ••• in the window, the file and the answer.
        let value = "nt-task-key-" + UUID().uuidString.prefix(12)
        let key = SymmetricKey(size: .bits256)
        SecretMask.current = SecretMask(key: key, marks: SecretMask.marks(for: SecretBytes(utf8: value), key: key))
        let masked = await asked(["title": "Rotate \(value) today", "notes": "It was \(value).", "project": proj.path], approve: true)
        let maskedPath = (json(masked.text)["path"] as? String) ?? ""
        let maskedFile = read(maskedPath) ?? ""
        check(!masked.isError && maskedFile.contains("- [ ] Rotate ••• today") && !maskedFile.contains(value),
              "tasks: a stored key's value is ••• in the file", maskedFile)
        check(masked.shown.contains("Rotate ••• today") && !masked.shown.contains(value) && !masked.text.contains(value),
              "tasks: and in the window and the answer", masked.shown)
        SecretMask.current = savedMask

        // A day it can't read: refused at once, with no window.
        let bad = await call(["title": "Someday", "when": "someday", "project": proj.path])
        check(bad.isError && bad.text.contains(When.pattern) && MCPWriteControl.pending == nil, "tasks: a bad when is refused before anyone is asked", bad.text)

        await worktreeTaskChecks(client)
    }

    /// A worktree window's task goes to its main checkout's todo folder; with several projects and none named, a caller
    /// outside the tabs is refused with no window. In a repository of the part's own.
    private static func worktreeTaskChecks(_ client: TaskClient) async {
        guard let git = GitRunner.locateGit(), let app = AppDelegate.shared else { return }
        let fm = FileManager.default
        let base = canonicalPath(NSTemporaryDirectory()) + "/nt-tasks-\(getpid())"
        try? fm.removeItem(atPath: base)
        let repo = base + "/app", linked = base + "/app-wt-tasks"
        try? fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try? "x\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        gitOutput(git, repo, ["init", "-q"])
        gitOutput(git, repo, ["add", "a.txt"])
        gitOutput(git, repo, ["commit", "-qm", "One"])
        gitOutput(git, repo, ["worktree", "add", "-q", "-b", "tasks", linked])
        let w = app.openFolder(linked, newWindow: true)
        defer {
            if !w.hasClosed { w.window?.close() }
            try? fm.removeItem(atPath: base)
        }
        let added = await client.asked(["title": "From the worktree", "project": linked], approve: true)
        let file = repo + "/todo/\(today)-from-the-worktree.md"
        check(!added.isError && fm.fileExists(atPath: file) && !fm.fileExists(atPath: linked + "/todo"),
              "tasks: a worktree window's task goes to its main checkout's todo folder", added.text)
        check(added.shown.contains("in app"), "tasks: and the window names the main checkout", added.shown)
        let unnamed = await client.call(["title": "Which project?"])
        check(unnamed.isError && unnamed.text.hasPrefix("Give project: one of the open projects") && MCPWriteControl.pending == nil,
              "tasks: with several projects open and none named, a caller outside the tabs is refused with no window", unnamed.text)
    }

    /// Settings › Tasks: right before Secrets, its defaults, and each control saving what it says.
    private static func taskSettingsChecks() {
        let defaults = UserDefaults.standard
        let tabs = (SettingsWindowController().window?.contentView as? NSTabView)?.tabViewItems ?? []
        let identifiers = tabs.compactMap { $0.identifier as? String }
        let tasks = identifiers.firstIndex(of: "tasks")
        check(tasks.map { identifiers[safe: $0 + 1] == "secrets" && identifiers[safe: $0 - 1] == "skills" } == true
                && tabs.first { $0.identifier as? String == "tasks" }?.label == "Tasks",
              "tasks: Settings › Tasks sits between Skills and Secrets", identifiers.joined(separator: ", "))
        TaskSettings.Key.all.forEach(defaults.removeObject(forKey:))
        let view = TaskSettingsView(frame: .zero)
        check(view.folder.stringValue == "todo" && view.folderScope.stringValue == "in each project" && view.includeContext.state == .on
                && view.outside.titleOfSelectedItem == "None",
              "tasks: Settings › Tasks shows todo in each project, where you are on, and no folder outside projects",
              "\(view.folder.stringValue) \(view.folderScope.stringValue) \(view.outside.titleOfSelectedItem ?? "")")
        view.folder.stringValue = "docs/todo"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.folder))
        check(TaskSettings(defaults: defaults).folder == "docs/todo", "tasks: a folder typed is saved")
        view.folder.stringValue = "../elsewhere"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.folder))
        check(TaskSettings(defaults: defaults).folder == "docs/todo" && !view.problem.isHidden,
              "tasks: one outside the project is not saved, and the pane says why", view.problem.stringValue)
        view.includeContext.performClick(nil)
        check(TaskSettings(defaults: defaults).includeContext == false, "tasks: Add where you are is saved off")
        TaskSettings.Key.all.forEach(defaults.removeObject(forKey:))
    }
}

/// add_task through `nxtrm mcp`, as an agent outside the tabs calls it, for the tasks part.
@MainActor
private final class TaskClient {
    /// What a call that asks gave: its answer, and what its window said.
    struct Asked {
        let text: String
        let isError: Bool
        let shown: String
    }

    private let mcp: MCPTestClient
    private var next = 10

    init(_ mcp: MCPTestClient) { self.mcp = mcp }

    func call(_ arguments: [String: Any]) async -> (text: String, isError: Bool) {
        next += 1
        let reply = await mcp.call(next, "tools/call", ["name": "add_task", "arguments": arguments], timeout: 60)
        let result = reply?["result"] as? [String: Any]
        let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "(no answer)"
        return (text, result?["isError"] as? Bool ?? true)
    }

    /// Calls add_task, answers its window as the user would (nil: not at all), and gives what the window said.
    func asked(_ arguments: [String: Any], approve: Bool?) async -> Asked {
        let pending = Task { await self.call(arguments) }
        _ = await SelfTest.wait(30) { MCPWriteControl.pending?.window != nil }
        let window = MCPWriteControl.pending?.window
        let shown = SelfTest.texts(window?.window?.contentView)
        if approve == true { window?.approveButton.performClick(nil) }
        if approve == false { window?.declineButton.performClick(nil) }
        let result = await pending.value
        return Asked(text: result.text, isError: result.isError, shown: shown)
    }
}
