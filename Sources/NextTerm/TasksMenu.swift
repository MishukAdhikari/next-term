import AppKit
import NextTermCore

/// The Tasks menu, after Agents: Add Task… turns a prompt into a todo file in the project's todo folder (AddTaskSheet),
/// Show Todo Folder shows where they are, Send Tasks To ▸ shows and changes where the project's tasks go, Connect a
/// Tracker to Your Agents… gives each agent's own line to add a tracker, and Task Settings… opens Settings › Tasks.
/// Each item is a command of its own, so Settings › Keyboard Shortcuts can give one a key. The places marked below are
/// kept for the commands that come next, so the menu keeps the order its self-test checks.
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
        // Here, after Add Task…: Wrap Up… and Post Update….
        add("Show Todo Folder", #selector(showTodoFolder(_:)))
        menu.addItem(.separator())
        menu.addItem(sendTasksToItem())
        add("Connect a Tracker to Your Agents…", #selector(connectTracker(_:)),
            tip: "Your agent’s own command to add a tracker’s MCP server, typed into a new tab for you to run.")
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

    func validateMenuItem(_ item: NSMenuItem) -> Bool { validate(item, front: front) }

    /// Whether `item` can be chosen with `front` the window in front (nil: none).
    func validate(_ item: NSMenuItem, front: TerminalWindowController?) -> Bool {
        switch item.action {
        case #selector(addTask(_:)): return front != nil
        case #selector(showTodoFolder(_:)): return front.flatMap(existingFolder(of:)) != nil
        // With no window in front the default is set in Settings › Tasks.
        case #selector(sendTasksTo(_:)): return front != nil
        default: return true
        }
    }
}
