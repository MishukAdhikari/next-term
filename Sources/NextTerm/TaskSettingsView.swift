import AppKit
import NextTermCore

/// Settings › Tasks: where the todo folder is (a path in each project, or one folder for every project), the folder for
/// windows with no project, and whether new tasks say where they were added. Each is saved as it changes and read as a
/// task is added (TaskSettings), by Tasks › Add Task… and add_task alike.
final class TaskSettingsView: NSView, NSTextFieldDelegate {
    static let docsURL = URL(string: "https://nxtrm.mishuk.me/docs/tasks/")!

    /// The todo folder as typed: `todo`, `docs/todo`, or an absolute folder.
    let folder = NSTextField()
    /// "in each project", or "for every project" for an absolute folder.
    let folderScope = NSTextField(labelWithString: "")
    let chooseFolder = NSButton(title: "Choose Folder…", target: nil, action: nil)
    let reveal = NSButton(title: "Reveal", target: nil, action: nil)
    /// Why the folder as typed can't be used.
    let problem = NSTextField(wrappingLabelWithString: "")
    /// None, the folder chosen, Choose Folder….
    let outside = NSPopUpButton()
    let includeContext = NSButton(checkboxWithTitle: "Add where you are to new tasks (project, branch, tab, agent)", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        folder.placeholderString = TaskSettings.defaultFolder
        folder.delegate = self
        folder.widthAnchor.constraint(equalToConstant: 180).isActive = true
        folder.setAccessibilityLabel("Todo folder")
        folder.toolTip = "A folder in each project, such as todo or docs/todo: an agent working there reads its tasks with its own tools. "
            + "In a worktree it is in the main checkout, so every worktree shares one list. It is made when the first task is added."
        folderScope.textColor = .secondaryLabelColor
        chooseFolder.bezelStyle = .rounded
        chooseFolder.target = self
        chooseFolder.action = #selector(chooseSharedFolder)
        chooseFolder.toolTip = "One folder for the tasks of every project. Next Term never makes it: it must be there when a task is added."
        reveal.bezelStyle = .rounded
        reveal.target = self
        reveal.action = #selector(revealFolder)
        reveal.toolTip = "Shows the todo folder of the project in front in the Finder."
        problem.textColor = Theme.failed
        problem.font = .systemFont(ofSize: 11)
        problem.preferredMaxLayoutWidth = 400
        outside.target = self
        outside.action = #selector(outsideChanged)
        outside.setAccessibilityLabel("Outside a project")
        outside.toolTip = "Where a task goes from a window with no project. None: such a task needs a project."
        includeContext.target = self
        includeContext.action = #selector(includeContextChanged)
        includeContext.toolTip = "The branch, the tab’s title, its agent and the command that resumes the agent’s session go in the file’s "
            + "front matter, so tomorrow’s session can pick up where you were. Stored keys show as •••."

        func row(_ title: String, _ views: [NSView]) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let stack = NSStackView(views: [label] + views)
            stack.spacing = 10
            return stack
        }
        let format = NSButton(title: "Format…", target: self, action: #selector(openFormat))
        format.bezelStyle = .inline
        format.toolTip = Self.docsURL.absoluteString
        let connect = NSButton(title: "Connect a Tracker…", target: self, action: #selector(connectTracker))
        connect.bezelStyle = .rounded
        connect.toolTip = "Your agent’s own command to add a tracker’s MCP server, typed into a new tab for you to run."
        let note = NSTextField(wrappingLabelWithString: "Tasks are Markdown files your agents can read: one per task, with - [ ] lines, "
            + "named by the day they were added. Next Term never edits .gitignore: add the folder to it to keep tasks out of git, "
            + "or commit them to share them.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.preferredMaxLayoutWidth = 420
        let stack = NSStackView(views: [
            row("Todo folder:", [folder, folderScope]),
            row("", [chooseFolder, reveal]),
            row("", [problem]),
            row("Outside a project:", [outside]),
            row("New tasks:", [includeContext]),
            note,
            format,
            connect,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refresh() }
    }

    /// The controls as saved.
    func refresh() {
        let settings = TaskSettings(defaults: .standard)
        if folder.currentEditor() == nil { folder.stringValue = settings.folder }
        showScope(folder.stringValue)
        outside.removeAllItems()
        outside.addItem(withTitle: "None")
        if let path = settings.outsideFolder {
            outside.addItem(withTitle: TodoFolder.shown(path))
            outside.lastItem?.representedObject = path
        }
        outside.menu?.addItem(.separator())
        outside.addItem(withTitle: "Choose Folder…")
        outside.lastItem?.tag = 1
        outside.selectItem(at: settings.outsideFolder == nil ? 0 : 1)
        includeContext.state = settings.includeContext ? .on : .off
    }

    private func showScope(_ typed: String) {
        let setting = TaskSettings(folder: typed.isEmpty ? TaskSettings.defaultFolder : typed)
        folderScope.stringValue = setting.isShared ? "for every project" : "in each project"
        problem.stringValue = TodoFolder.problem(with: typed) ?? ""
        problem.isHidden = problem.stringValue.isEmpty
    }

    // MARK: choosing

    func controlTextDidChange(_ notification: Notification) {
        showScope(folder.stringValue)
        save(folder: folder.stringValue)
    }

    /// The folder as typed, saved unless it can't be used; empty is the default.
    private func save(folder typed: String) {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TodoFolder.problem(with: text) == nil else { return }
        if text.isEmpty || text == TaskSettings.defaultFolder {
            UserDefaults.standard.removeObject(forKey: TaskSettings.Key.folder)
        } else {
            UserDefaults.standard.set(text, forKey: TaskSettings.Key.folder)
        }
    }

    @objc private func chooseSharedFolder() {
        pick(title: "One folder for the tasks of every project") { [weak self] path in
            self?.folder.stringValue = path
            self?.save(folder: path)
            self?.showScope(path)
        }
    }

    @objc private func outsideChanged() {
        if outside.selectedItem?.tag == 1 {
            refresh() // the choice stays as saved until a folder is picked
            pick(title: "The folder for tasks from windows with no project") { [weak self] path in
                UserDefaults.standard.set(path, forKey: TaskSettings.Key.outsideFolder)
                self?.refresh()
            }
        } else if outside.indexOfSelectedItem == 0 {
            UserDefaults.standard.removeObject(forKey: TaskSettings.Key.outsideFolder)
        }
    }

    @objc private func includeContextChanged() {
        UserDefaults.standard.set(includeContext.state == .on, forKey: TaskSettings.Key.includeContext)
    }

    /// An absolute folder from an open panel, over the Settings window.
    private func pick(title: String, _ chosen: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = title
        panel.prompt = "Use Folder"
        let done: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            chosen(url.path)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    /// The front project's todo folder in the Finder; one not made yet shows its project.
    @objc private func revealFolder() {
        let front = NSApp.orderedWindows.lazy.compactMap { $0.windowController as? TerminalWindowController }.first
        let resolution = TodoFolder.resolve(project: front?.project, settings: TaskSettings(defaults: .standard))
        switch resolution {
        case .inProject(let url, let root, let mustCreate):
            NSWorkspace.shared.activateFileViewerSelecting([mustCreate ? URL(fileURLWithPath: root) : url])
        case .shared(let url, _) where FileManager.default.fileExists(atPath: url.path):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        default:
            NSSound.beep()
        }
    }

    @objc private func connectTracker() { ConnectTrackerSheet.present(over: window) }

    @objc private func openFormat() { NSWorkspace.shared.open(Self.docsURL) }
}
