import AppKit
import NextTermCore

extension Notification.Name {
    /// Where tasks go was changed: an open Add Task sheet and Settings › Tasks read it again.
    static let taskDestinationChanged = Notification.Name("NextTermTaskDestinationChanged")
}

/// Tasks › Send Tasks To ▸: where the front project's tasks go, ticked, and one click to change it; in a window with no
/// project, the default. The rows are built each time the submenu opens, from the saved settings, the apps installed
/// (asked of Launch Services, nothing launched) and where Reminders stands (never asked). Opening it starts no Process
/// and sends nothing. The submenu is empty while the menu bar is built, so no destination becomes a command with a
/// key: a key per destination would mean something else in each project.
extension TasksMenu: NSMenuDelegate {
    /// One row's choice and the project it was offered for, so a window that moves to the front meanwhile changes nothing.
    final class Choice: NSObject {
        let action: DestinationChoices.MenuAction
        let key: String?

        init(_ action: DestinationChoices.MenuAction, key: String?) {
            self.action = action
            self.key = key
        }
    }

    /// The "Send Tasks To" item, with its empty submenu. Its action only lets validation turn it off with no window
    /// in front; an item with a submenu never sends it.
    func sendTasksToItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Send Tasks To", action: #selector(sendTasksTo(_:)), keyEquivalent: "")
        item.target = self
        item.toolTip = "Where this project’s tasks go, or the default in a window with no project."
        let submenu = NSMenu(title: "Send Tasks To")
        submenu.autoenablesItems = false
        submenu.delegate = self
        item.submenu = submenu
        return item
    }

    @objc func sendTasksTo(_ sender: Any?) {}

    func menuNeedsUpdate(_ menu: NSMenu) {
        fillDestinations(menu, for: front)
    }

    /// Its rows never have keys, so AppKit never fills it while it matches a key press.
    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
                              action: UnsafeMutablePointer<Selector?>) -> Bool {
        false
    }

    /// The rows for `controller`'s project, or the default's in a window with no project.
    func fillDestinations(_ menu: NSMenu, for controller: TerminalWindowController?) {
        menu.removeAllItems()
        guard let controller else {
            let none = NSMenuItem(title: "No window in front: the default is in Task Settings…", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        let scope = Self.scope(of: controller)
        var key: String?
        if case .project(let projectKey, _, _) = scope { key = projectKey }
        let rows = DestinationChoices.menuRows(scope: scope, settings: TaskSettings(defaults: .standard),
                                               facts: Self.menuFacts())
        for row in rows { menu.addItem(item(for: row, key: key)) }
    }

    private func item(for row: DestinationChoices.MenuRow, key: String?) -> NSMenuItem {
        if row.action == .separator { return .separator() }
        let item = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
        if row.action != .label {
            item.action = #selector(chooseDestination(_:))
            item.target = self
            item.representedObject = Choice(row.action, key: key)
        }
        item.isEnabled = row.enabled
        item.state = row.ticked ? .on : .off
        item.toolTip = row.tip
        return item
    }

    /// Whose destination the window shows: its project's, shared by every worktree of it, or the default's.
    static func scope(of controller: TerminalWindowController) -> DestinationChoices.MenuScope {
        guard let project = controller.project else { return .noProject }
        let key = TaskSettings.projectKey(project)
        let name = (key as NSString).lastPathComponent
        return .project(key: key, name: name, worktree: canonicalPath(project) != key)
    }

    /// What only the app knows, read now: the apps installed and where Reminders stands. Nothing is launched or asked.
    static func menuFacts() -> DestinationFacts {
        var facts = DestinationFacts()
        let apps: [TaskLink.Kind] = [.things, .todoist, .omnifocus]
        facts.installed = Set(apps.filter { TaskOpen.installed($0) })
        facts.reminders = TaskReminders.step
        return facts
    }
}

// MARK: choosing

extension TasksMenu {
    /// A row chosen: its destination saved for the project (or as the default), the project back on the default, or
    /// Settings › Tasks for details the row doesn't have. Reminders not yet allowed is explained and asked first, and
    /// saved only once macOS says yes. No notice follows: the tick is the answer.
    @objc func chooseDestination(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Choice else { return }
        choose(choice.action, key: choice.key, window: front?.window)
    }

    func choose(_ action: DestinationChoices.MenuAction, key: String?, window: NSWindow?) {
        switch action {
        case .use(let destination):
            guard destination.kind == .reminders, case .explain = TaskReminders.step else {
                return Self.save(destination, key: key)
            }
            TaskReminders.allow(from: window) { outcome in
                if outcome == nil { Self.save(destination, key: key) }
            }
        case .useDefault:
            Self.save(nil, key: key)
        case .setUp, .setUpAll:
            AppDelegate.shared.showSettings(tab: "tasks")
        case .label, .separator:
            break
        }
    }

    /// Saves `destination` as the project's own (nil: the project goes back to the default), or as the default with
    /// no project. The one-time offer is answered by this, and an open sheet and Settings read the change.
    static func save(_ destination: TaskDestination?, key: String?) {
        let defaults = UserDefaults.standard
        var settings = TaskSettings(defaults: defaults)
        if let key {
            var own = settings.projects[key] ?? ProjectTasks()
            own.destination = destination
            settings.projects[key] = own.destination == nil && own.handoffFolder == nil ? nil : own
            guard let json = TaskSettings.json(projects: settings.projects) else { return NSSound.beep() }
            defaults.set(json, forKey: TaskSettings.Key.projects)
        } else if let destination {
            guard let json = TaskDestination.json(destination) else { return NSSound.beep() }
            defaults.set(json, forKey: TaskSettings.Key.defaultDestination)
        } else {
            return
        }
        AddTaskOffer.markDone()
        NotificationCenter.default.post(name: .taskDestinationChanged, object: nil)
    }
}
