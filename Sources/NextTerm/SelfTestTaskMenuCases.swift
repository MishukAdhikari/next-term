import AppKit
import NextTermCore

#if DEBUG
/// More of Tasks › Send Tasks To ▸: with no window in front it is off and says where the default is; opening it with a
/// shortcut saved reads no shortcut list and runs nothing; a window with no project saves the default, and the
/// default's ticked row in a project changes nothing; a worktree window shares its repository's choice; Reminders saves
/// only once macOS says yes; and a sheet whose popup the user moved keeps it.
extension SelfTest {
    static func sendTasksToMoreChecks(_ c: TerminalWindowController, key: String) async {
        noWindowChecks(c)
        quietOpenChecks(c, key: key)
        defaultChecks(c, key: key)
        await worktreeChecks()
    }

    /// No window in front: Send Tasks To is off, and its one row says the default is in Task Settings.
    private static func noWindowChecks(_ c: TerminalWindowController) {
        let item = TasksMenu.shared.sendTasksToItem()
        check(!TasksMenu.shared.validate(item, front: nil) && TasksMenu.shared.validate(item, front: c),
              "send to: off with no window in front, on with one")
        let menu = NSMenu()
        TasksMenu.shared.fillDestinations(menu, for: nil)
        let only = menu.items.map(\.title)
        check(only == ["No window in front: the default is in Task Settings…"] && menu.items.first?.isEnabled == false,
              "send to: with no window in front one greyed row says where the default is", only.joined(separator: " | "))
    }

    /// A shortcut saved for the project shows its saved name; opening the submenu asks for no shortcut list, runs
    /// nothing and opens nothing.
    private static func quietOpenChecks(_ c: TerminalWindowController, key: String) {
        let runner = FakeShortcutRunner(list: nil)
        TaskShortcut.fake = runner
        defer {
            TaskShortcut.fake = nil
            TasksMenu.save(nil, key: key)
        }
        let shortcut = TaskDestination.shortcut(id: "8F1C2D3E-0000-4000-8000-000000000001", name: "Add to Inbox")
        TasksMenu.save(shortcut, key: key)
        let menu = NSMenu()
        TasksMenu.shared.fillDestinations(menu, for: c)
        let ticked = menu.items.filter { $0.state == .on }.map(\.title)
        check(ticked == ["Run “Add to Inbox”"], "send to: a saved shortcut shows its saved name", ticked.joined(separator: " | "))
        check(runner.lists == 0 && runner.runs.isEmpty && TaskOpen.opened.isEmpty,
              "send to: opening it lists no shortcuts, runs nothing and opens nothing",
              "lists \(runner.lists), runs \(runner.runs.count), opened \(TaskOpen.opened.count)")
    }

    /// With no project the choice is the default; in a project that follows it, its ticked row changes nothing.
    private static func defaultChecks(_ c: TerminalWindowController, key: String) {
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: TaskSettings.Key.defaultDestination) }
        TasksMenu.shared.choose(.use(.trello), key: nil, window: nil)
        let saved = TaskSettings(defaults: defaults)
        check(saved.defaultDestination == .trello && saved.projects[key] == nil,
              "send to: a window with no project saves the default and leaves the project")
        let menu = NSMenu()
        TasksMenu.shared.fillDestinations(menu, for: c)
        guard let ticked = menu.items.first(where: { $0.state == .on }), ticked.title == "Trello (the default)" else {
            return check(false, "send to: the project shows the default ticked", menu.items.map(\.title).joined(separator: " | "))
        }
        TasksMenu.shared.chooseDestination(ticked)
        let after = TaskSettings(defaults: defaults)
        check(after.projects[key] == nil, "send to: the default’s ticked row leaves the project on the default")
    }

    /// A linked worktree's window shows its repository's choice, says so, and saves for the whole repository.
    private static func worktreeChecks() async {
        guard let git = GitRunner.locateGit(), let app = AppDelegate.shared else {
            return note("send to: worktree skipped, no git")
        }
        let fm = FileManager.default
        let base = canonicalPath(NSTemporaryDirectory()) + "/nt-sendto-\(getpid())"
        try? fm.removeItem(atPath: base)
        let repo = base + "/web", tree = base + "/web-wt-login"
        try? fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        @discardableResult func sh(_ args: String...) -> String { gitOutput(git, repo, args) }
        try? "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        sh("init", "-q", "-b", "main")
        sh("add", "-A")
        sh("commit", "-q", "-m", "start")
        sh("worktree", "add", "-q", "-b", "fix/login", tree)
        let w = app.openWorktreeWindow(tree)
        let key = TaskSettings.projectKey(repo)
        defer {
            TasksMenu.save(nil, key: key)
            if !w.hasClosed { w.window?.close() }
            sh("worktree", "remove", "--force", tree)
            try? fm.removeItem(atPath: base)
        }
        TasksMenu.shared.choose(.use(.things(list: nil)), key: key, window: nil)
        let menu = NSMenu()
        TasksMenu.shared.fillDestinations(menu, for: w)
        let ticked = menu.items.filter { $0.state == .on }.map(\.title)
        check(menu.items.first?.title == "For “web” and its worktrees" && ticked == ["Things"],
              "send to: a worktree window shows its repository’s choice", menu.items.first?.title ?? "none")
        guard let trello = menu.items.first(where: { $0.title == "Trello" }) else {
            return check(false, "send to: the worktree window offers Trello")
        }
        TasksMenu.shared.chooseDestination(trello)
        let saved = TaskSettings(defaults: .standard).projects[key]?.destination
        check(saved == .trello, "send to: a choice in a worktree window saves for its repository")
    }

    /// Reminders while macOS hasn't been asked, with a yes on Next Term's sheet: saved once macOS grants it, and
    /// nothing saved when macOS says no.
    static func remindersYesChecks(_ c: TerminalWindowController, key: String) async {
        let store = FakeRemindersStore(status: .notDetermined, lists: [])
        TaskReminders.fake = store
        TaskReminders.fakeOS = 14
        RemindersSheets.fakeAnswer = true
        RemindersSheets.shown = []
        defer {
            TaskReminders.fake = nil
            TaskReminders.fakeOS = nil
            RemindersSheets.fakeAnswer = nil
            RemindersSheets.shown = []
            TasksMenu.save(nil, key: key)
        }
        let reminders = TaskDestination.reminders(listID: nil, listName: DestinationChoices.remindersList)
        store.grants = false
        TasksMenu.shared.choose(.use(reminders), key: key, window: c.window)
        let denied = await wait(3) { RemindersSheets.shown.contains(RemindersAccess.deniedLine) }
        let none = TaskSettings(defaults: .standard).projects[key]?.destination
        check(denied && none == nil, "send to: a yes that macOS then denies saves nothing and says so")
        store.currentStatus = .notDetermined
        store.grants = true
        TasksMenu.shared.choose(.use(reminders), key: key, window: c.window)
        let saved = await wait(3) { TaskSettings(defaults: .standard).projects[key]?.destination == reminders }
        check(saved, "send to: a yes that macOS grants saves Reminders for the project")
    }

    /// A sheet whose popup the user moved off "(this project’s)" keeps it; back on that row, it follows again.
    static func movedSheetChecks(_ c: TerminalWindowController, key: String) async {
        guard let sheet = await destinationSheet(c, "Fix the logout") else { return }
        defer { sheet.pressCancel() }
        sheet.pickDestination(titled: "Things")
        TasksMenu.shared.choose(.use(.trello), key: key, window: c.window)
        check(sheet.chosenDestination == .things(list: nil), "send to: a sheet the user moved off the project’s keeps it")
        guard let first = sheet.destinationTitles.first else { return check(false, "send to: the sheet has rows") }
        sheet.pickDestination(titled: first)
        TasksMenu.shared.choose(.use(.github(owner: "o", repo: "r")), key: key, window: c.window)
        check(sheet.chosenDestination == .github(owner: "o", repo: "r"),
              "send to: back on the project’s row, the sheet follows again")
    }
}
#endif
