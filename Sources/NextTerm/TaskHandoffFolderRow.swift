import AppKit
import NextTermCore

/// Settings › Tasks' Handoff folder row, under This project: where Wrap Up asks the project's agents to write their
/// handoffs, relative to the project and shared by every worktree of it. Choose… takes a folder inside the project
/// only: one outside, one reached through a linked folder or one with `..` is refused in red and nothing is saved.
/// Use Default goes back to `docs/handoffs`. With no project window the row is off, like This project.
@MainActor
final class TaskHandoffFolderRow: NSObject {
    /// The folder as set, relative; the default in grey.
    let value = NSTextField(labelWithString: "")
    let choose = NSButton(title: "Choose…", target: nil, action: nil)
    let useDefault = NSButton(title: "Use Default", target: nil, action: nil)
    /// Why the last pick was not saved, or why the saved one is not used.
    let problem = TaskDestinationsView.problemLabel()
    /// The project in front: its folder, and its key (its main checkout).
    private var project: String?
    private var key: String?

    static let outside = "Choose a folder inside the project"
    static let notUsed = "The saved folder isn’t a plain folder inside this project, so docs/handoffs is used."

    override init() {
        super.init()
        choose.target = self
        choose.action = #selector(chooseFolder)
        choose.toolTip = "A folder inside the project. The agents write their handoffs there."
        useDefault.target = self
        useDefault.action = #selector(backToDefault)
        useDefault.toolTip = "Handoffs go to \(TaskSettings.defaultHandoffFolder) in the project."
        value.setAccessibilityLabel("This project’s handoff folder")
    }

    /// The row for the project in front now (nil: none), as saved.
    func update(project: String?, key: String?) {
        // The problem line's whole row hides with it, so no empty row sits under the setting.
        if project != self.project || problem.isHidden { say(nil) }
        self.project = project
        self.key = key
        let enabled = project != nil && key != nil
        choose.isEnabled = enabled
        guard let project, let key else {
            show(TaskSettings.defaultHandoffFolder, isDefault: true)
            useDefault.isEnabled = false
            return
        }
        let settings = TaskSettings(defaults: .standard)
        let own = settings.projects[key]?.handoffFolder
        let usable = own.flatMap { TaskSettings.handoffFolder($0, in: project) }
        show(usable ?? TaskSettings.defaultHandoffFolder, isDefault: usable == nil)
        useDefault.isEnabled = own != nil
        if own != nil, usable == nil { say(Self.notUsed) }
    }

    private func show(_ folder: String, isDefault: Bool) {
        value.stringValue = SecretMask.current.mask(folder)
        value.textColor = isDefault ? .secondaryLabelColor : .labelColor
    }

    private func say(_ line: String?) {
        problem.stringValue = line ?? ""
        problem.isHidden = line == nil
        (problem.superview as? NSStackView)?.isHidden = line == nil
    }

    @objc private func chooseFolder() {
        guard let project else { return NSSound.beep() }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder inside the project for the agents’ handoffs."
        let current = TaskSettings(defaults: .standard).handoffFolder(for: project)
        let start = current.map { URL(fileURLWithPath: project).appendingPathComponent($0) }
        let exists = start.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        panel.directoryURL = exists ? start : URL(fileURLWithPath: project, isDirectory: true)
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.picked(url.path)
        }
        if let window = choose.window {
            panel.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(panel.runModal())
        }
    }

    /// A folder picked: saved relative when it is a plain folder inside the project, else refused in red.
    func picked(_ path: String) {
        guard let project, let key else { return }
        guard let setting = TaskSettings.handoffSetting(picked: path, in: project) else { return say(Self.outside) }
        save(setting, key: key)
    }

    @objc private func backToDefault() {
        guard let key else { return }
        save(nil, key: key)
    }

    /// Only this project's handoff folder changes; saved choices that can't be read are never written over.
    private func save(_ setting: String?, key: String) {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: TaskSettings.Key.projects)
        guard let json = TaskSettings.json(saved: saved, handoffFolder: setting, for: key) else { return NSSound.beep() }
        defaults.set(json, forKey: TaskSettings.Key.projects)
        say(nil)
        update(project: project, key: key)
    }
}

#if DEBUG
extension TaskHandoffFolderRow {
    // MARK: for the self-test

    var shownValue: String { value.stringValue }
    var problemText: String? { problem.isHidden ? nil : problem.stringValue }
    func pressUseDefault() { if useDefault.isEnabled { backToDefault() } }
}
#endif
