import AppKit
import NextTermCore

#if DEBUG
/// Tasks › Send Tasks To ▸: built when it opens, with the project's destination ticked; choosing Things saves it for
/// the project and leaves the default; Reminders not yet allowed explains first and a no saves nothing; an open sheet
/// on "(this project’s)" follows a change; and opening it opens nothing. The rest are in SelfTestTaskMenuCases. Every
/// opener is recorded, nothing opens, and `tasksChecks` puts the Tasks settings back after.
extension SelfTest {
    static func sendTasksToChecks(_ c: TerminalWindowController, other: TerminalWindowController) async {
        guard let project = c.project else { return check(false, "send to: the window has a project") }
        TaskOpen.recordsOnly = true
        TaskOpen.opened = []
        TaskOpen.fakeInstalled = [.things]
        let defaults = UserDefaults.standard
        defer {
            TaskOpen.recordsOnly = false
            TaskOpen.opened = []
            TaskOpen.fakeInstalled = nil
            AddTaskSheet.current?.pressCancel()
            TaskSettings.Key.all.forEach(defaults.removeObject(forKey:))
        }
        TaskSettings.Key.all.forEach(defaults.removeObject(forKey:))
        let key = TaskSettings.projectKey(project)
        let menu = NSMenu()
        TasksMenu.shared.fillDestinations(menu, for: c)
        let ticked = menu.items.filter { $0.state == .on }.map(\.title)
        check(ticked == ["Todo Folder (the default)"], "send to: with nothing saved the todo folder is ticked",
              ticked.joined(separator: " | "))
        check(TaskOpen.opened.isEmpty, "send to: opening it opens nothing")
        guard let things = menu.items.first(where: { $0.title == "Things" }), things.isEnabled else {
            return check(false, "send to: Things is offered while it is installed")
        }
        TasksMenu.shared.chooseDestination(things)
        let settings = TaskSettings(defaults: defaults)
        check(settings.projects[key]?.destination == .things(list: nil) && settings.defaultDestination == nil,
              "send to: choosing Things saves it for the project and leaves the default")
        check(settings.destinationOffer == .done, "send to: a choice answers the one-time offer")
        TasksMenu.shared.fillDestinations(menu, for: c)
        let now = menu.items.filter { $0.state == .on }.map(\.title)
        let back = menu.items.contains { $0.title == "Use the Default (Todo Folder)" }
        check(now == ["Things"] && back, "send to: Things is ticked, with Use the Default", now.joined(separator: " | "))
        if other.project == nil {
            TasksMenu.shared.fillDestinations(menu, for: other)
            let outside = menu.items.filter { $0.state == .on }.map(\.title)
            check(outside == ["Todo Folder"] && menu.items.first?.title == "For windows with no project (the default)",
                  "send to: a window with no project still shows the default", outside.joined(separator: " | "))
        }
        TasksMenu.shared.choose(.useDefault, key: key, window: c.window)
        check(TaskSettings(defaults: defaults).projects[key] == nil, "send to: Use the Default clears the project’s own")
        await remindersAskChecks(c, key: key)
        await remindersYesChecks(c, key: key)
        await openSheetChecks(c, key: key)
        await movedSheetChecks(c, key: key)
        await sendTasksToMoreChecks(c, key: key)
    }

    /// Reminders while macOS hasn't been asked: Next Term's sheet first, and a no there saves nothing.
    private static func remindersAskChecks(_ c: TerminalWindowController, key: String) async {
        TaskReminders.fake = FakeRemindersStore(status: .notDetermined, lists: [])
        TaskReminders.fakeOS = 14
        RemindersSheets.fakeAnswer = false
        RemindersSheets.shown = []
        defer {
            TaskReminders.fake = nil
            TaskReminders.fakeOS = nil
            RemindersSheets.fakeAnswer = nil
            RemindersSheets.shown = []
        }
        let reminders = TaskDestination.reminders(listID: nil, listName: DestinationChoices.remindersList)
        TasksMenu.shared.choose(.use(reminders), key: key, window: c.window)
        let explained = await wait(3) { RemindersSheets.shown.contains(RemindersAccess.explanation) }
        check(explained, "send to: Reminders not yet allowed explains before macOS asks")
        let saved = TaskSettings(defaults: .standard).projects[key]?.destination
        check(saved == nil, "send to: a no there saves nothing")
    }

    /// A sheet open on "(this project’s)" follows the submenu's change.
    private static func openSheetChecks(_ c: TerminalWindowController, key: String) async {
        guard let sheet = await destinationSheet(c, "Fix the login") else { return }
        TasksMenu.shared.choose(.use(.github(owner: "o", repo: "r")), key: key, window: c.window)
        let follows = await wait(3) { sheet.placeText.hasPrefix("Opens a new issue in o/r") }
        check(follows, "send to: an open sheet on the project’s destination follows the change", sheet.placeText)
        sheet.pressCancel()
        check(TaskOpen.opened.isEmpty, "send to: nothing opened")
    }
}
#endif
