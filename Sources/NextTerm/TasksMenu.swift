import AppKit
import NextTermCore

/// The Tasks menu, after Agents: Add Task… turns a prompt into a todo file in the project's todo folder (AddTaskSheet),
/// Wrap Up… asks the window's ready agent tabs for handoffs and turns their next steps into tasks once reviewed
/// (WrapUpSheet), Post Update… drafts Done, Next and Blocked from today's local work (PostUpdateSheet), Show Todo
/// Folder shows where the tasks are, Send Tasks To ▸ shows and changes where the project's tasks go, Connect a
/// Tracker to Your Agents… gives each agent's own line to add a tracker, and Task Settings… opens Settings › Tasks.
/// Each item is a command of its own, so Settings › Keyboard Shortcuts can give one a key; the menu keeps the order its
/// self-test checks.
@MainActor
final class TasksMenu: NSObject, NSMenuItemValidation {
    static let shared = TasksMenu()

    /// The menu's items, under `menu`.
    func fill(_ menu: NSMenu) {
        func add(_ title: String, _ action: Selector, _ key: String = "", tip: String? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = key.isEmpty ? [] : [.command, .control]
            item.target = self
            item.toolTip = tip
            menu.addItem(item)
        }
        add("Add Task…", #selector(addTask(_:)), "t",
            tip: "A prompt becomes a task: a Markdown file in the project’s todo folder that tomorrow’s agent there can read.")
        add("Wrap Up…", #selector(wrapUp(_:)), "w", tip: Self.tips[#selector(wrapUp(_:))])
        add("Post Update…", #selector(postUpdate(_:)), tip: Self.tips[#selector(postUpdate(_:))])
        add("Show Todo Folder", #selector(showTodoFolder(_:)))
        menu.addItem(.separator())
        menu.addItem(sendTasksToItem())
        add("Connect a Tracker to Your Agents…", #selector(connectTracker(_:)),
            tip: "Your agent’s own command to add a tracker’s MCP server, typed into a new tab for you to run.")
        menu.addItem(.separator())
        add("Task Settings…", #selector(showTaskSettings(_:)))
    }

    /// The project window in front, with or without a project.
    var front: TerminalWindowController? {
        (NSApp.keyWindow?.windowController as? TerminalWindowController) ?? (NSApp.mainWindow?.windowController as? TerminalWindowController)
    }

    // MARK: the commands

    @objc func addTask(_ sender: Any?) {
        guard let controller = front else { return NSSound.beep() }
        AddTaskSheet.present(over: controller)
    }

    @objc func wrapUp(_ sender: Any?) {
        guard let controller = front, controller.project != nil else { return NSSound.beep() }
        WrapUpSheet.present(over: controller)
    }

    @objc func postUpdate(_ sender: Any?) {
        guard let controller = front, controller.project != nil else { return NSSound.beep() }
        _ = PostUpdateSheet.present(over: controller)
    }

    /// The todo folder selected and open in the sidebar, or in the Finder when the sidebar doesn't hold it (one folder
    /// for every project, a worktree's main checkout).
    @objc func showTodoFolder(_ sender: Any?) {
        guard let controller = front, let folder = existingFolder(of: controller) else { return NSSound.beep() }
        let root = controller.sidebar.root?.path
        guard let root, canonicalPath(folder.path).hasPrefix(root + "/") else {
            return NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
        if !controller.isSidebarVisible { controller.toggleProjectSidebar(nil) }
        controller.sidebar.reveal(folder.path, expanding: true)
    }

    @objc func connectTracker(_ sender: Any?) {
        ConnectTrackerSheet.present(over: front?.window)
    }

    @objc func showTaskSettings(_ sender: Any?) {
        AppDelegate.shared.showSettings(tab: "tasks")
    }

    /// The todo folder of `controller`'s project, while it is there. One in a protected place counts as there: a look
    /// would ask macOS, and choosing the command is the user's own.
    func existingFolder(of controller: TerminalWindowController) -> URL? {
        let resolution = TodoFolder.resolve(project: controller.project, settings: TaskSettings(defaults: .standard))
        switch resolution {
        case .inProject(let url, _, false): return url
        case .shared(let url, _): return url
        case .inProject, .missing, .noProject, .refused: return nil
        }
    }

    // MARK: validation

    /// The tooltips the project-only items show while they can be chosen.
    static let tips: [Selector: String] = [
        #selector(wrapUp(_:)): "Your agent tabs each write a handoff; you review their next steps before they become tomorrow’s tasks.",
        #selector(postUpdate(_:)): "A Done / Next / Blocked draft from today’s handoffs, tasks and commits, for you to copy, save or hand to an agent.",
    ]

    func validateMenuItem(_ item: NSMenuItem) -> Bool { validate(item, front: front) }

    /// Whether `item` can be chosen with `front` the window in front (nil: none).
    func validate(_ item: NSMenuItem, front: TerminalWindowController?) -> Bool {
        switch item.action {
        case #selector(addTask(_:)): return front != nil
        case #selector(wrapUp(_:)), #selector(postUpdate(_:)):
            // Both work in a project: the handoffs, the posted record and the commits are the project's.
            let enabled = front?.project != nil
            item.toolTip = enabled ? item.action.flatMap { Self.tips[$0] } : "Open a project window first."
            return enabled
        case #selector(showTodoFolder(_:)): return front.flatMap(existingFolder(of:)) != nil
        // With no window in front the default is set in Settings › Tasks.
        case #selector(sendTasksTo(_:)): return front != nil
        default: return true
        }
    }
}
