import AppKit
import NextTermCore

/// Settings › Tasks' Destinations: where tasks go by default, where the project in front sends its own (every
/// worktree of it shares one), and the details the destination being edited needs. A kind with nothing to fill saves
/// as it is chosen; one with fields saves only on Save, so half-typed details never become where tasks go. Every save
/// posts the change, so an open Add Task sheet and Tasks › Send Tasks To read it again. Nothing here is checked against
/// a service, nothing is logged, and every name shown from the user's lists goes through the secret mask.
final class TaskDestinationsView: NSView, NSTextFieldDelegate {
    /// Whose destination the details box edits.
    enum Scope: Equatable {
        case defaultDestination
        case project
    }

    let defaultPopup = NSPopUpButton()
    let projectPopup = NSPopUpButton()
    /// "For “next-term” and its worktrees", or "No project window open".
    let projectName = NSTextField(labelWithString: "")
    /// Why a saved value can't be used, under its popup.
    let defaultProblem = TaskDestinationsView.problemLabel()
    let projectProblem = TaskDestinationsView.problemLabel()
    /// Where Wrap Up's handoffs go in the project in front.
    let handoffRow = TaskHandoffFolderRow()
    /// "Details for the default:" or "Details for “next-term”:".
    let detailsTitle = NSTextField(labelWithString: "")
    /// The rows of the kind being edited, rebuilt when it changes.
    let details = NSStackView()
    /// Why Save is off, or what Use This Project's Remote found.
    let formLine = TaskDestinationsView.problemLabel()
    let save = NSButton(title: "Save", target: nil, action: nil)
    let revert = NSButton(title: "Revert", target: nil, action: nil)

    // Each kind's fields.
    let reminderList = NSPopUpButton()
    let remindersAlarm = NSButton(checkboxWithTitle: "Alert at 9:00 on the day", target: nil, action: nil)
    let allowReminders = NSButton(title: "Allow Reminders…", target: nil, action: nil)
    let openPrivacy = NSButton(title: "Open Privacy & Security", target: nil, action: nil)
    let shortcutPopup = NSPopUpButton()
    let reloadShortcuts = NSButton(title: "Reload", target: nil, action: nil)
    let thingsList = NSTextField()
    let owner = NSTextField()
    let repo = NSTextField()
    let gitlabPath = NSTextField()
    let useRemote = NSButton(title: "Use This Project’s Remote", target: nil, action: nil)
    let team = NSTextField()
    let org = NSTextField()
    let azureProject = NSTextField()
    let azureType = NSPopUpButton()
    let tracker = NSTextField()
    let connectBeside = NSButton(title: "Connect a Tracker…", target: nil, action: nil)

    /// The destination being edited, as typed.
    private(set) var form = DestinationForm(saved: nil)
    private(set) var editing: Scope = .defaultDestination
    /// The project in front: its key and its folder; nil with no project window.
    private(set) var projectKey: String?
    private var projectPath: String?
    /// Read when the box opens, never at launch; nil until read.
    private var shortcuts: [ShortcutList.Shortcut]?
    /// A read of the shortcuts is under way, so another isn't started.
    private var readingShortcuts = false
    /// The last read failed: nothing is known, so no saved shortcut is called gone.
    private var shortcutsUnreadable = false
    private var reminderLists: [RemindersAccess.List] = []
    /// What Use This Project's Remote said; cleared when the kind changes.
    private var remoteLine: String?

    /// The kinds in the popups, in the order every list of destinations takes; a held row has no kind.
    private var rows: [DestinationForm.ChoiceRow] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        setUpControls()
        let stack = NSStackView(views: layoutRows())
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(changedElsewhere),
                                               name: .taskDestinationChanged, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    static func problemLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.textColor = Theme.failed
        label.font = .systemFont(ofSize: 11)
        label.preferredMaxLayoutWidth = 400
        label.isHidden = true
        return label
    }

    /// A row with its label right-aligned in the slice-1 rows' column.
    static func row(_ title: String, _ views: [NSView]) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let stack = NSStackView(views: [label] + views)
        stack.spacing = 10
        return stack
    }

    private func layoutRows() -> [NSView] {
        let heading = NSTextField(labelWithString: "Destinations")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        detailsTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        detailsTitle.textColor = .secondaryLabelColor
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 8
        let buttons = NSStackView(views: [revert, save])
        buttons.spacing = 8
        return [
            heading,
            Self.row("Default:", [defaultPopup]),
            Self.row("", [defaultProblem]),
            Self.row("This project:", [projectPopup, projectName]),
            Self.row("", [projectProblem]),
            Self.row("Handoff folder:", [handoffRow.value, handoffRow.choose, handoffRow.useDefault]),
            Self.row("", [handoffRow.problem]),
            Self.row("", [detailsTitle]),
            details,
            Self.row("", [formLine]),
            Self.row("", [buttons]),
        ]
    }
}

// MARK: the controls

extension TaskDestinationsView {
    private func setUpControls() {
        defaultPopup.autoenablesItems = false
        defaultPopup.target = self
        defaultPopup.action = #selector(defaultChosen)
        defaultPopup.setAccessibilityLabel("Default destination")
        defaultPopup.toolTip = "Where tasks go from a project that names no place of its own, and from windows with no project."
        projectPopup.autoenablesItems = false
        projectPopup.target = self
        projectPopup.action = #selector(projectChosen)
        projectPopup.setAccessibilityLabel("This project’s destination")
        projectPopup.toolTip = "Where the tasks of the project in front go. Every worktree of it shares one choice."
        projectName.textColor = .secondaryLabelColor
        save.bezelStyle = .rounded
        save.keyEquivalent = ""
        save.target = self
        save.action = #selector(saveForm)
        save.toolTip = "Tasks go here from now on. Until then they go where they went."
        revert.bezelStyle = .rounded
        revert.target = self
        revert.action = #selector(revertForm)
        revert.toolTip = "Puts back what is saved."

        reminderList.target = self
        reminderList.action = #selector(reminderListChosen)
        reminderList.setAccessibilityLabel("Reminders list")
        reminderList.toolTip = "The list new reminders go to. “Next Term” is made on the first Add if it isn’t there."
        remindersAlarm.target = self
        remindersAlarm.action = #selector(alarmChanged)
        remindersAlarm.toolTip = "A reminder with a day gets an alert at 9:00 that day."
        allowReminders.bezelStyle = .rounded
        allowReminders.target = self
        allowReminders.action = #selector(allowRemindersPressed)
        allowReminders.toolTip = "Next Term explains what it reads first, then macOS asks."
        openPrivacy.bezelStyle = .rounded
        openPrivacy.target = self
        openPrivacy.action = #selector(openPrivacyPressed)
        openPrivacy.toolTip = "System Settings › Privacy & Security, where Reminders is turned on for Next Term."
        shortcutPopup.target = self
        shortcutPopup.action = #selector(shortcutChosen)
        shortcutPopup.setAccessibilityLabel("Shortcut")
        shortcutPopup.toolTip = "The shortcut that gets each task’s text as its input."
        reloadShortcuts.bezelStyle = .rounded
        reloadShortcuts.target = self
        reloadShortcuts.action = #selector(reloadShortcutsPressed)
        reloadShortcuts.toolTip = "Reads your shortcuts again."
        useRemote.bezelStyle = .rounded
        useRemote.target = self
        useRemote.action = #selector(useRemotePressed)
        useRemote.toolTip = "Fills the repository from this project’s origin remote, read from its git config."
        azureType.addItems(withTitles: TaskDestination.azureTypes)
        azureType.target = self
        azureType.action = #selector(fieldsChanged)
        azureType.setAccessibilityLabel("Work item type")
        azureType.toolTip = "Which types exist depends on the project’s process."
        connectBeside.bezelStyle = .rounded
        connectBeside.target = self
        connectBeside.action = #selector(connectTracker)
        connectBeside.toolTip = "Your agent’s own command to add a tracker’s MCP server, typed into a new tab for you to run."

        let fields: [(NSTextField, String, String, String, CGFloat)] = [
            (thingsList, "Things list", "Inbox", "A list or area in Things; empty is the Inbox.", 200),
            (owner, "GitHub owner", "owner", "The user or organization that owns the repository.", 140),
            (repo, "GitHub repository", "repository", "The repository’s name.", 160),
            (gitlabPath, "GitLab project path", "group/project", "The project’s path on gitlab.com; subgroups are allowed.", 260),
            (team, "Linear team key", "ENG", "Optional. Empty: Linear asks for the team.", 90),
            (org, "Azure DevOps organization", "organization", "The organization in dev.azure.com/organization.", 160),
            (azureProject, "Azure DevOps project", "project", "The project in that organization.", 160),
            (tracker, "Tracker name", "Jira", "The tracker your agent posts to with its own tools: 1 to 40 characters.", 160),
        ]
        for (field, label, placeholder, tip, width) in fields {
            field.setAccessibilityLabel(label)
            field.placeholderString = placeholder
            field.toolTip = tip
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
    }

    @objc private func connectTracker() { ConnectTrackerSheet.present(over: window) }
}

// MARK: what is saved

extension TaskDestinationsView {
    /// The tag of "Use the Default (…)" in This project's popup; a kind's row is tagged by its place in `rows`.
    static let useDefaultTag = -1

    /// What is saved for `scope`: the default (nil: the todo folder), or the project's own (nil: it follows the default).
    func saved(_ scope: Scope) -> TaskDestination? {
        let settings = TaskSettings(defaults: .standard)
        switch scope {
        case .defaultDestination: return settings.defaultDestination
        case .project: return projectKey.flatMap { settings.projects[$0]?.destination }
        }
    }

    /// The popups and the box as saved, for the project in front now. Edits in the box stay unless what they edit
    /// was changed meanwhile.
    func reload() {
        let settings = TaskSettings(defaults: .standard)
        let front = NSApp.orderedWindows.lazy.compactMap { $0.windowController as? TerminalWindowController }.first
        let before = projectKey
        if let front, let path = front.project {
            projectPath = path
            projectKey = TaskSettings.projectKey(path)
            if case .project(_, let name, let worktree) = TasksMenu.scope(of: front) {
                let shown: String = SecretMask.current.mask(name)
                projectName.stringValue = "For “\(shown)”" + (worktree ? " and its worktrees" : "")
            }
        } else {
            projectPath = nil
            projectKey = nil
            projectName.stringValue = "No project window open"
            if editing == .project { editing = .defaultDestination }
        }
        if projectKey != before, editing == .project {
            // Another project came to the front: details typed for the last one are dropped, never saved to this one.
            editing = saved(.project) == nil ? .defaultDestination : .project
            form = DestinationForm(saved: saved(editing))
            remoteLine = nil
        }
        rows = DestinationForm.rows(facts: TasksMenu.menuFacts())
        let fallback = settings.defaultDestination ?? .todoFolder
        fill(defaultPopup, selecting: fallback.kind, useDefault: nil)
        let useDefault = "Use the Default (" + DestinationChoices.name(fallback) + ")"
        let own = saved(.project)
        fill(projectPopup, selecting: own?.kind, useDefault: useDefault)
        projectPopup.isEnabled = projectKey != nil
        handoffRow.update(project: projectPath, key: projectKey)
        show(defaultProblem, settings.defaultDestinationProblem)
        let ownProblem = projectKey.flatMap { settings.projects[$0]?.problem } ?? settings.projectsProblem
        show(projectProblem, projectKey == nil || own != nil ? nil : ownProblem)
        if form.saved != saved(editing) {
            // What the box edited was changed meanwhile: a project put back on the default shows the default's.
            if editing == .project, saved(.project) == nil { editing = .defaultDestination }
            form = DestinationForm(saved: saved(editing))
        }
        // The popup being edited shows the kind in the box, saved or not yet.
        select(form.kind, in: editing == .project ? projectPopup : defaultPopup)
        showForm()
    }

    /// A popup's rows; `useDefault` first when given. A kind of nil selects Use the Default.
    private func fill(_ popup: NSPopUpButton, selecting kind: TaskDestination.Kind?, useDefault: String?) {
        popup.removeAllItems()
        if let useDefault {
            popup.addItem(withTitle: useDefault)
            popup.lastItem?.tag = Self.useDefaultTag
            popup.menu?.addItem(.separator())
        }
        for (index, row) in rows.enumerated() {
            let item = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
            item.tag = index
            item.isEnabled = row.enabled
            item.toolTip = row.tip
            popup.menu?.addItem(item)
        }
        select(kind, in: popup)
    }

    private func select(_ kind: TaskDestination.Kind?, in popup: NSPopUpButton) {
        guard let kind, let index = rows.firstIndex(where: { $0.kind == kind }) else {
            popup.selectItem(withTag: Self.useDefaultTag)
            return
        }
        popup.selectItem(withTag: index)
    }

    private func show(_ label: NSTextField, _ problem: String?) {
        // The saved value is the user's own, but it is shown masked like every other name.
        label.stringValue = problem.map { SecretMask.current.mask($0) } ?? ""
        label.isHidden = problem == nil
        (label.superview as? NSStackView)?.isHidden = problem == nil
    }

    @objc private func changedElsewhere() { reload() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        let center = NotificationCenter.default
        if let window { center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window) }
        if let newWindow {
            // Back in Settings after another project window was in front: This project names that one.
            center.addObserver(self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification,
                               object: newWindow)
        }
    }

    @objc private func windowBecameKey() { reload() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { reload() }
    }
}

// MARK: choosing and saving

extension TaskDestinationsView {
    @objc private func defaultChosen() { chosen(defaultPopup.selectedTag(), in: .defaultDestination) }

    @objc private func projectChosen() { chosen(projectPopup.selectedTag(), in: .project) }

    /// A row chosen: Use the Default clears the project's own; a kind with nothing to fill is saved at once; a kind
    /// with fields opens them in the box and waits for Save.
    func chosen(_ tag: Int, in scope: Scope) {
        if scope == .project, tag == Self.useDefaultTag {
            editing = .defaultDestination
            form = DestinationForm(saved: saved(.defaultDestination))
            store(nil, in: .project)
            return
        }
        guard rows.indices.contains(tag), let kind = rows[tag].kind else { return reload() }
        editing = scope
        remoteLine = nil
        if let destination = DestinationForm.atOnce(kind, saved: saved(scope)) {
            form = DestinationForm(saved: destination)
            if destination != saved(scope) { return store(destination, in: scope) }
            return reload()
        }
        form = DestinationForm(kind: kind, saved: saved(scope))
        // The other popup goes back to what is saved for it.
        reload()
    }

    /// Saves for `scope` (nil on the project: back on the default) and posts the change; every view reads it again.
    private func store(_ destination: TaskDestination?, in scope: Scope) {
        switch scope {
        case .defaultDestination:
            guard let destination else { return }
            TasksMenu.save(destination, key: nil)
        case .project:
            guard let projectKey else { return NSSound.beep() }
            TasksMenu.save(destination, key: projectKey)
        }
        reload()
    }

    @objc func saveForm() {
        guard form.canSave else { return NSSound.beep() }
        let destination = form.destination
        let scope = editing
        let finish: () -> Void = { [weak self] in
            if destination.kind == .things { TaskSettings.markShown(.thingsEnable, in: .standard) }
            self?.form.didSave()
            self?.store(destination, in: scope)
        }
        // Reminders not asked yet: Next Term explains, macOS asks, and it is saved only once allowed.
        guard destination.kind == .reminders, case .explain = TaskReminders.step else { return finish() }
        TaskReminders.allow(from: window) { outcome in
            if outcome == nil { finish() }
        }
    }

    @objc func revertForm() {
        form.revert()
        remoteLine = nil
        reload()
    }

    /// Settings › Tasks at `kind`'s details for `scope` (the default with no project window): the kind chosen and its
    /// first field in focus. Nothing is saved until Save, unless the kind has nothing to fill.
    func focus(kind: TaskDestination.Kind, scope: Scope) {
        reload()
        let target: Scope = scope == .project && projectKey != nil ? .project : .defaultDestination
        guard pick(kind, in: target) else { return }
        if let first = firstField() { window?.makeFirstResponder(first) }
    }

    /// `kind` chosen in `scope`'s popup, as a click there does; false when it can't be chosen now.
    @discardableResult
    func pick(_ kind: TaskDestination.Kind, in scope: Scope) -> Bool {
        guard let tag = rows.firstIndex(where: { $0.kind == kind }), rows[tag].enabled else { return false }
        let popup = scope == .project ? projectPopup : defaultPopup
        popup.selectItem(withTag: tag)
        chosen(tag, in: scope)
        return true
    }

    /// The control a user fills first for the kind in the box.
    func firstField() -> NSView? {
        switch form.kind {
        case .reminders: return reminderList.superview == nil ? allowReminders : reminderList
        case .things: return thingsList
        case .shortcut: return shortcutPopup
        case .github: return owner
        case .gitlab: return gitlabPath
        case .linear: return team
        case .azureBoards: return org
        case .throughAgent: return tracker
        default: return nil
        }
    }
}

// MARK: the details box

extension TaskDestinationsView {
    /// The box for the kind being edited: its fields as the form holds them, its note, and Save and Revert.
    func showForm() {
        let whose: String
        if editing == .project, let path = projectPath {
            let name = (TaskSettings.projectKey(path) as NSString).lastPathComponent
            whose = "Details for “" + SecretMask.current.mask(name) + "”:"
        } else {
            whose = "Details for the default:"
        }
        detailsTitle.stringValue = whose + " " + DestinationChoices.kindName(form.kind)
        details.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for view in detailRows() { details.addArrangedSubview(view) }
        syncFields()
        updateState()
    }

    private func detailRows() -> [NSView] {
        var built: [NSView] = []
        func row(_ title: String, _ views: [NSView]) { built.append(Self.row(title, views)) }
        func line(_ text: String, failed: Bool = false) {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 11)
            label.textColor = failed ? Theme.failed : .secondaryLabelColor
            label.preferredMaxLayoutWidth = 400
            row("", [label])
        }
        switch form.kind {
        case .reminders:
            switch TaskReminders.step {
            case .ready:
                row("List:", [reminderList])
                row("", [remindersAlarm])
                loadReminderLists()
            case .explain:
                row("", [allowReminders])
                line("Next Term reads only the names of your lists, and adds only what you add.")
            case .blocked(let text, let settings):
                line(text == RemindersAccess.deniedLine ? "Reminders isn’t allowed for Next Term." : text, failed: true)
                if settings { row("", [openPrivacy]) }
            }
        case .shortcut:
            row("Shortcut:", [shortcutPopup, reloadShortcuts])
            if shortcuts == nil, !readingShortcuts { loadShortcuts() }
            if let gone = goneShortcutLine() { line(gone, failed: true) }
        case .things:
            if let missing = rows.first(where: { $0.kind == .things && !$0.enabled })?.tip {
                line(missing, failed: true)
            } else {
                row("List:", [thingsList])
                if !TaskSettings(defaults: .standard).notesShown.contains(.thingsEnable) {
                    line(DestinationForm.thingsEnableNote)
                }
            }
        case .github:
            row("Repository:", [owner, NSTextField(labelWithString: "/"), repo])
            row("", [useRemote])
        case .gitlab:
            row("Project path:", [gitlabPath])
            row("", [useRemote])
        case .linear:
            row("Team key:", [team])
            line("Optional, such as ENG. Empty: Linear asks for the team.")
        case .azureBoards:
            row("Organization:", [org])
            row("Project:", [azureProject])
            row("Type:", [azureType])
        case .throughAgent:
            row("Tracker:", [tracker, connectBeside])
        case .todoFolder, .todoist, .omnifocus, .trello:
            break
        }
        if let note = DestinationForm.note(form.kind) { line(note) }
        if form.kind == .github || form.kind == .gitlab {
            useRemote.isEnabled = projectPath != nil
        }
        return built
    }

    /// The fields as the form holds them.
    private func syncFields() {
        thingsList.stringValue = form.thingsList
        owner.stringValue = form.owner
        repo.stringValue = form.repo
        gitlabPath.stringValue = form.gitlabPath
        team.stringValue = form.team
        org.stringValue = form.org
        azureProject.stringValue = form.project
        azureType.selectItem(withTitle: form.azureType)
        tracker.stringValue = form.tracker
        remindersAlarm.state = TaskSettings(defaults: .standard).remindersAlarm ? .on : .off
        fillShortcuts()
        fillReminderLists()
    }

    /// Save and Revert, and the line that says why Save is off.
    func updateState() {
        save.isEnabled = form.canSave
        revert.isEnabled = form != DestinationForm(saved: form.saved)
        let needsFields = DestinationForm.hasFields(form.kind)
        let changed = form.destination != form.saved
        let line: String? = remoteLine ?? (needsFields && changed ? form.problem : nil)
        formLine.stringValue = line.map { SecretMask.current.mask($0) } ?? ""
        formLine.isHidden = line == nil
        let buttons = save.superview?.superview
        buttons?.isHidden = !needsFields
    }

    func controlTextDidChange(_ notification: Notification) { fieldsChanged() }

    /// The form takes what is typed; nothing is saved until Save.
    @objc func fieldsChanged() {
        form.thingsList = thingsList.stringValue
        form.owner = owner.stringValue
        form.repo = repo.stringValue
        form.gitlabPath = gitlabPath.stringValue
        form.team = team.stringValue
        form.org = org.stringValue
        form.project = azureProject.stringValue
        form.azureType = azureType.titleOfSelectedItem ?? TaskDestination.azureTypes[0]
        form.tracker = tracker.stringValue
        remoteLine = nil
        updateState()
    }
}

// MARK: Reminders, Shortcuts and the remote

extension TaskDestinationsView {
    /// The user's list names, read when the box shows Reminders and access is given; never asks.
    private func loadReminderLists() {
        TaskReminders.lists { [weak self] lists in
            self?.reminderLists = lists
            self?.fillReminderLists()
        }
    }

    /// "Next Term" first (made on the first Add when it isn't there), then the user's lists, the form's selected.
    private func fillReminderLists() {
        let home = DestinationChoices.remindersList
        reminderList.removeAllItems()
        let hasHome = reminderLists.contains { $0.title == home }
        reminderList.addItem(withTitle: hasHome ? home : home + " (made on the first Add)")
        reminderList.lastItem?.representedObject = reminderLists.first { $0.title == home }.map { [$0.id, $0.title] }
        for list in reminderLists where list.title != home {
            let shown: String = SecretMask.current.mask(list.title)
            let item = NSMenuItem(title: shown, action: nil, keyEquivalent: "")
            item.representedObject = [list.id, list.title]
            reminderList.menu?.addItem(item)
        }
        let index = reminderList.itemArray.firstIndex { item in
            guard let pair = item.representedObject as? [String] else { return form.listName == home }
            return pair[0] == form.listID || (form.listID == nil && pair[1] == form.listName)
        }
        reminderList.selectItem(at: index ?? 0)
    }

    @objc private func reminderListChosen() {
        if let pair = reminderList.selectedItem?.representedObject as? [String] {
            form.listID = pair[0]
            form.listName = pair[1]
        } else {
            form.listID = nil
            form.listName = DestinationChoices.remindersList
        }
        updateState()
    }

    @objc private func alarmChanged() {
        UserDefaults.standard.set(remindersAlarm.state == .on, forKey: TaskSettings.Key.remindersAlarm)
    }

    @objc private func allowRemindersPressed() {
        TaskReminders.allow(from: window) { [weak self] _ in self?.showForm() }
    }

    @objc private func openPrivacyPressed() { TaskOpen.openSettings(RemindersAccess.privacySettings) }

    private func loadShortcuts() {
        shortcutPopup.removeAllItems()
        shortcutPopup.addItem(withTitle: "Reading your shortcuts…")
        shortcutPopup.isEnabled = false
        readingShortcuts = true
        TaskShortcut.list { [weak self] found in
            guard let self else { return }
            self.readingShortcuts = false
            self.shortcutsUnreadable = found == nil
            self.shortcuts = found ?? []
            self.shortcutPopup.isEnabled = true
            if self.form.kind == .shortcut { self.showForm() }
        }
    }

    /// The user's shortcuts by name; "Choose a Shortcut" while none of them is chosen.
    private func fillShortcuts() {
        guard let shortcuts else { return }
        shortcutPopup.removeAllItems()
        let listed = shortcuts.contains { $0.id == form.shortcutID }
        if !listed {
            let empty = shortcutsUnreadable ? "Couldn’t read your shortcuts" : "No shortcuts found"
            shortcutPopup.addItem(withTitle: shortcuts.isEmpty ? empty : "Choose a Shortcut")
        }
        for shortcut in shortcuts {
            let shown: String = SecretMask.current.mask(shortcut.name)
            let item = NSMenuItem(title: shown, action: nil, keyEquivalent: "")
            item.representedObject = shortcut.id
            shortcutPopup.menu?.addItem(item)
        }
        let index = shortcutPopup.itemArray.firstIndex { $0.representedObject as? String == form.shortcutID }
        shortcutPopup.selectItem(at: index ?? 0)
    }

    /// "“<name>” isn’t in Shortcuts any more", for a saved shortcut the list no longer has.
    private func goneShortcutLine() -> String? {
        guard let shortcuts, !shortcutsUnreadable, !form.shortcutID.isEmpty,
              !shortcuts.contains(where: { $0.id == form.shortcutID }) else { return nil }
        return "“" + SecretMask.current.mask(form.shortcutName) + "” isn’t in Shortcuts any more."
    }

    @objc private func shortcutChosen() {
        guard let id = shortcutPopup.selectedItem?.representedObject as? String,
              let shortcut = shortcuts?.first(where: { $0.id == id }) else { return }
        form.shortcutID = shortcut.id
        form.shortcutName = shortcut.name
        updateState()
    }

    @objc private func reloadShortcutsPressed() {
        guard !readingShortcuts else { return }
        shortcuts = nil
        showForm()
    }

    /// Fills the repository from the project's origin remote; the URL itself is never shown.
    @objc private func useRemotePressed() {
        guard let projectPath, let git = GitRunner.locateGit() else { return NSSound.beep() }
        useRemote.isEnabled = false
        let kind = form.kind
        let scope = editing
        let key = projectKey
        DispatchQueue.global(qos: .userInitiated).async {
            let url = DestinationForm.originURL(project: projectPath, git: git)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.useRemote.isEnabled = true
                // The kind, the scope or the project changed while git read the config: nothing is filled.
                guard self.form.kind == kind, self.editing == scope, self.projectKey == key else { return }
                self.remoteLine = self.form.useRemote(url)
                self.syncFields()
                self.updateState()
            }
        }
    }
}
