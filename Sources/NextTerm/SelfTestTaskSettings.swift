import AppKit
import NextTermCore

#if DEBUG
/// Settings › Tasks' Destinations: the slice-1 rows first, then Default, This project and Connect a Tracker…; Trello as
/// the default saves at once; GitHub for the project saves nothing until Save; Use the Default clears it and an open
/// Add Task sheet follows; Reminders with the in-memory store, not asked, allowed and turned off; the shortcut popup
/// from the fake runner, a saved shortcut that is gone and a list that can't be read; Linear's team key on Save, the
/// Things note and Revert; opening at GitHub's details, and the Settings window opened at Linear's; and Connect a
/// Tracker…. Every opener is recorded and nothing opens; `tasksChecks` puts the Tasks settings back after.
extension SelfTest {
    static func taskDestinationSettingsChecks(_ c: TerminalWindowController) async {
        guard let project = c.project else { return check(false, "task settings: the window has a project") }
        let defaults = UserDefaults.standard
        TaskOpen.recordsOnly = true
        TaskOpen.opened = []
        TaskOpen.fakeInstalled = [.things]
        defer {
            TaskOpen.recordsOnly = false
            TaskOpen.opened = []
            TaskOpen.fakeInstalled = nil
            TaskReminders.fake = nil
            TaskReminders.fakeOS = nil
            TaskShortcut.fake = nil
            ConnectTrackerSheet.current?.done()
            AddTaskSheet.current?.pressCancel()
            TaskSettings.Key.all.forEach(defaults.removeObject(forKey:))
        }
        TaskSettings.Key.all.forEach(defaults.removeObject(forKey:))
        c.window?.makeKeyAndOrderFront(nil)
        let key = TaskSettings.projectKey(project)
        let pane = TaskSettingsView(frame: .zero)
        let view = pane.destinations
        check(view.projectKey == key && view.projectName.stringValue.hasPrefix("For “"),
              "task settings: This project is the project in front", view.projectName.stringValue)
        let order = pane.subviewsInOrder()
        check(order.firstIndex(of: "Todo folder:").map { first in
            [ "Default:", "This project:", "Connect a Tracker…"].allSatisfy { (order.firstIndex(of: $0) ?? -1) > first }
        } == true, "task settings: the slice-1 rows come first, then Default, This project and Connect a Tracker…",
              order.joined(separator: " | "))

        view.pick(.trello, in: .defaultDestination)
        check(TaskSettings(defaults: defaults).defaultDestination == .trello,
              "task settings: Trello as the default is saved at once")
        view.pick(.github, in: .project)
        view.owner.stringValue = "example-org"
        view.fieldsChanged()
        check(!view.save.isEnabled && TaskSettings(defaults: defaults).projects[key] == nil,
              "task settings: half-typed GitHub details save nothing and Save stays off")
        view.repo.stringValue = "web"
        view.fieldsChanged()
        check(view.save.isEnabled, "task settings: Save turns on once the repository is whole")
        check(TaskSettings(defaults: defaults).projects[key] == nil, "task settings: nothing is saved before Save")
        view.saveForm()
        let github = TaskDestination.github(owner: "example-org", repo: "web")
        check(TaskSettings(defaults: defaults).projects[key]?.destination == github,
              "task settings: Save makes GitHub the project’s, kept by its main checkout’s key")

        await useDefaultChecks(c, view, key: key)
        await reminderSettingsChecks(view)
        await shortcutSettingsChecks(view)
        await unreadableShortcutChecks(view)
        linearThingsAndRevertChecks(view)
        focusAndConnectChecks(view)
        await settingsWindowFocusCheck()
    }

    /// Use the Default clears the project's own destination, and an Add Task sheet open behind reads it again.
    private static func useDefaultChecks(_ c: TerminalWindowController, _ view: TaskDestinationsView,
                                         key: String) async {
        AddTaskSheet.present(over: c)
        guard await wait(5, { AddTaskSheet.current != nil }), let sheet = AddTaskSheet.current else {
            return check(false, "task settings: the Add Task sheet opens")
        }
        sheet.type("Check the settings")
        let before = sheet.placeText
        view.chosen(TaskDestinationsView.useDefaultTag, in: .project)
        check(TaskSettings(defaults: .standard).projects[key]?.destination == nil,
              "task settings: Use the Default clears the project’s own destination")
        let followed = await wait(5) { sheet.placeText != before }
        check(followed, "task settings: the open Add Task sheet reads the change", sheet.placeText)
        sheet.pressCancel()
    }

    /// Reminders not asked yet shows Allow Reminders… and no list; allowed, the fake's lists with Next Term first;
    /// turned off, Open Privacy & Security, recorded and not opened.
    private static func reminderSettingsChecks(_ view: TaskDestinationsView) async {
        TaskReminders.fakeOS = 14
        TaskReminders.fake = FakeRemindersStore(status: .notDetermined, lists: [])
        view.reload()
        view.pick(.reminders, in: .defaultDestination)
        check(view.allowReminders.superview != nil && view.reminderList.superview == nil,
              "task settings: Reminders not asked yet shows Allow Reminders… and no list")
        let lists = [RemindersAccess.List(id: "list-work", title: "Work"),
                     RemindersAccess.List(id: "list-home", title: "Next Term")]
        TaskReminders.fake = FakeRemindersStore(status: .fullAccess, lists: lists)
        view.showForm()
        let filled = await wait(5) { view.reminderList.numberOfItems == 2 }
        check(filled && view.reminderList.itemTitles == ["Next Term", "Work"],
              "task settings: allowed, the list popup has the lists with Next Term first",
              view.reminderList.itemTitles.joined(separator: " | "))
        TaskReminders.fake = FakeRemindersStore(status: .denied, lists: [])
        view.showForm()
        check(view.openPrivacy.superview != nil, "task settings: Reminders turned off offers Open Privacy & Security")
        TaskOpen.opened = []
        view.openPrivacy.performClick(nil)
        check(TaskOpen.opened == [RemindersAccess.privacySettings],
              "task settings: Open Privacy & Security is recorded, not opened")
        view.revertForm()
    }

    /// The shortcut popup holds the fake runner's names; a saved shortcut it doesn't list says it is gone.
    private static func shortcutSettingsChecks(_ view: TaskDestinationsView) async {
        let inbox = "0F3C9A2E-1B7D-4E55-9C3A-2D8E6F1A4B70"
        let gone = "7A1D2C3B-4E5F-4061-8273-9A0B1C2D3E4F"
        TaskShortcut.fake = FakeShortcutRunner(list: "Add to Inbox (\(inbox))\nLog Work (5B6C7D8E-9F01-4234-8567-89ABCDEF0123)\n")
        let saved = TaskDestination.shortcut(id: gone, name: "Old Inbox")
        UserDefaults.standard.set(TaskDestination.json(saved), forKey: TaskSettings.Key.defaultDestination)
        view.reload()
        view.pick(.shortcut, in: .defaultDestination)
        view.reloadShortcuts.performClick(nil)
        let listed = await wait(5) { view.shortcutPopup.itemTitles.contains("Add to Inbox") }
        check(listed && view.shortcutPopup.itemTitles.contains("Log Work"),
              "task settings: the shortcut popup holds the shortcuts listed", view.shortcutPopup.itemTitles.joined(separator: " | "))
        let line = view.details.allLabels().contains("“Old Inbox” isn’t in Shortcuts any more.")
        check(line, "task settings: a saved shortcut no longer listed says so", view.details.allLabels().joined(separator: " | "))
        UserDefaults.standard.removeObject(forKey: TaskSettings.Key.defaultDestination)
        view.reload()
    }

    /// Shortcuts that can't be read: the popup says so, a saved shortcut isn't called gone, and showing the box again
    /// while a read is under way starts no second one.
    private static func unreadableShortcutChecks(_ view: TaskDestinationsView) async {
        let runner = FakeShortcutRunner(list: nil)
        TaskShortcut.fake = runner
        let saved = TaskDestination.shortcut(id: "0F3C9A2E-1B7D-4E55-9C3A-2D8E6F1A4B70", name: "Old Inbox")
        UserDefaults.standard.set(TaskDestination.json(saved), forKey: TaskSettings.Key.defaultDestination)
        view.reload()
        view.pick(.shortcut, in: .defaultDestination)
        view.reloadShortcuts.performClick(nil)
        view.showForm()
        view.showForm()
        let read = await wait(5) { view.shortcutPopup.itemTitles.contains("Couldn’t read your shortcuts") }
        check(read, "task settings: shortcuts that can’t be read say so", view.shortcutPopup.itemTitles.joined(separator: " | "))
        let labels = view.details.allLabels()
        check(!labels.contains("“Old Inbox” isn’t in Shortcuts any more."),
              "task settings: an unread list calls no saved shortcut gone", labels.joined(separator: " | "))
        check(runner.lists == 1, "task settings: showing the box again starts no second read", "\(runner.lists)")
        UserDefaults.standard.removeObject(forKey: TaskSettings.Key.defaultDestination)
        view.reload()
    }

    /// Linear saves at once with no team, then a typed team key saves on Save and a bad one shows its problem; Things
    /// shows its Enable note until it is first saved; Revert puts back what is saved.
    private static func linearThingsAndRevertChecks(_ view: TaskDestinationsView) {
        let defaults = UserDefaults.standard
        view.pick(.linear, in: .defaultDestination)
        check(TaskSettings(defaults: defaults).defaultDestination == .linear(team: nil),
              "task settings: Linear with no team is saved at once")
        check(view.save.superview?.superview?.isHidden == false, "task settings: Linear shows Save for its team key")
        view.team.stringValue = "eng team"
        view.fieldsChanged()
        check(!view.save.isEnabled && !view.formLine.isHidden, "task settings: a bad team key shows its problem")
        view.team.stringValue = "ENG"
        view.fieldsChanged()
        check(view.save.isEnabled, "task settings: a team key turns Save on")
        view.saveForm()
        check(TaskSettings(defaults: defaults).defaultDestination == .linear(team: "ENG"),
              "task settings: Save keeps Linear’s team key")
        view.team.stringValue = "WEB"
        view.fieldsChanged()
        view.revertForm()
        check(view.team.stringValue == "ENG" && view.form.destination == .linear(team: "ENG"),
              "task settings: Revert puts back the saved team key")

        view.pick(.things, in: .defaultDestination)
        check(view.details.allLabels().contains(DestinationForm.thingsEnableNote),
              "task settings: Things says once to enable Things URLs")
        view.thingsList.stringValue = "Work"
        view.fieldsChanged()
        view.saveForm()
        check(TaskSettings(defaults: defaults).notesShown.contains(.thingsEnable),
              "task settings: saving Things marks its Enable note shown")
        view.showForm()
        check(!view.details.allLabels().contains(DestinationForm.thingsEnableNote),
              "task settings: the Enable note isn’t said again")
        view.pick(.trello, in: .defaultDestination)
    }

    /// Opening at GitHub's details for the project chooses it with the owner first; Connect a Tracker… opens its sheet.
    private static func focusAndConnectChecks(_ view: TaskDestinationsView) {
        view.focus(kind: .github, scope: .project)
        check(view.editing == .project && view.form.kind == .github && view.firstField() === view.owner,
              "task settings: opened at GitHub’s details, GitHub is chosen for the project with the owner first")
        view.revertForm()
        view.pick(.throughAgent, in: .defaultDestination)
        view.connectBeside.performClick(nil)
        check(ConnectTrackerSheet.current != nil, "task settings: Connect a Tracker… beside the tracker opens its sheet")
        ConnectTrackerSheet.current?.done()
        view.revertForm()
    }

    /// The Settings window opened at Linear's details, from outside it: the Tasks tab, with the team key in focus.
    private static func settingsWindowFocusCheck() async {
        TaskSettingsView.focus(kind: .linear, scope: .defaultDestination)
        let found = await wait(5) { settingsTasksPane() != nil }
        guard found, let pane = settingsTasksPane(), let window = pane.window else {
            return check(false, "task settings: Settings opens on its Tasks tab")
        }
        let editor = window.firstResponder as? NSTextView
        let field: NSTextField? = editor?.delegate as? NSTextField
        let typing = field === pane.destinations.team
        check(typing, "task settings: opened at Linear’s details, the team key is in focus")
        window.performClose(nil)
    }

    /// The Tasks tab of the Settings window, while it is the tab shown.
    private static func settingsTasksPane() -> TaskSettingsView? {
        let tabs = NSApp.windows.lazy.compactMap { $0.contentView as? NSTabView }
        let shown = tabs.compactMap { $0.selectedTabViewItem?.view as? TaskSettingsView }
        return shown.first { $0.window?.isVisible == true }
    }
}

extension NSView {
    /// Every label's and button's title below this view, in the order they are laid out.
    func allLabels() -> [String] {
        var found: [String] = []
        if let field = self as? NSTextField, !field.isEditable, !field.stringValue.isEmpty { found.append(field.stringValue) }
        if let button = self as? NSButton, !(self is NSPopUpButton) { found.append(button.title) }
        for view in subviews { found += view.allLabels() }
        return found
    }
}

extension TaskSettingsView {
    /// The pane's labels and buttons, top to bottom.
    func subviewsInOrder() -> [String] { allLabels() }
}
#endif
