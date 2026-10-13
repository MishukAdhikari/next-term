import AppKit
import NextTermCore

/// Settings › Skills › Project: a project's own skills, and for Claude Code, Codex and Command Code the copy each loads
/// there. Found by SkillLibrary as list_skills finds them for an agent at the project's top, so Settings and what agents
/// are told never disagree. Read-only: a project's skills are usually its team's, in git. The last row is Next Term's
/// own next-term-tabs, which agents get over MCP and which is never written.
///
/// The project is the front window's, followed while the user hasn't picked another; nothing is read while hidden.
final class ProjectSkillsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    /// The open projects, for the self-test (its home is its own, so Next Term's windows are not its projects).
    static var projectsForTest: [String]?

    let picker = NSPopUpButton()
    let summary = NSTextField(labelWithString: "")
    let intro = NSTextField(wrappingLabelWithString: "")
    private let personalButton = NSButton(title: "Show Personal", target: nil, action: nil)
    private let table = NSTableView()
    let openButton = NSButton(title: "Open SKILL.md", target: nil, action: nil)
    let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let content = NSStackView()
    private let empty = NSStackView()
    var onShowPersonal: (() -> Void)?

    /// One row: a skill of the project, or one of Next Term's own, by name.
    enum Row: Equatable {
        case skill(SkillLibrary.Overview.Skill)
        case builtIn(String)

        var name: String {
            switch self {
            case .skill(let skill): return skill.name
            case .builtIn(let name): return name
            }
        }
    }

    /// The project shown, by its real path.
    private(set) var project: String?
    /// The front window's project when last looked: a new one in front is followed, else the user's pick stays.
    private var lastFront: String?
    private(set) var overview: SkillLibrary.Overview?
    /// For names with two or more copies in the project: whether they differ.
    private(set) var differ: [String: Bool] = [:]
    private(set) var rows: [Row] = []
    private var generation = 0
    private var keyObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: SkillsStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: AppDelegate.offerTabsChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shown (or Settings brought back): the front project may have changed, and agents change skills.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        guard let window else { return }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload(following: true) }
        }
        reload(following: true)
    }

    // MARK: layout

    private func build() {
        picker.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        (picker.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingMiddle
        picker.target = self
        picker.action = #selector(picked)
        picker.setAccessibilityLabel("Project")
        for label in [summary, intro] {
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        intro.toolTip = Self.rulesTip

        let columns: [(String, String, CGFloat)] = [("name", "Skill", 150), ("where", "Where", 130),
                                                    (SkillAgent.claudeCode.rawValue, "Claude Code", 95), (SkillAgent.codex.rawValue, "Codex", 85),
                                                    (SkillAgent.commandCode.rawValue, "Command Code", 100)]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 60
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.menu = NSMenu()
        table.menu?.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        for (button, action) in [(openButton, #selector(openSelected)), (revealButton, #selector(reveal)), (personalButton, #selector(showPersonal))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        let top = NSStackView(views: [picker, summary, NSView()])
        top.spacing = 8
        let buttons = NSStackView(views: [openButton, revealButton])
        buttons.spacing = 8
        for view in [top, intro, personalButton, scroll, buttons] { content.addArrangedSubview(view) }
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)

        let emptyText = NSTextField(wrappingLabelWithString: "Open a project to see the skills agents get there.")
        emptyText.textColor = .secondaryLabelColor
        emptyText.alignment = .center
        let openProject = NSButton(title: "Open Project…", target: AppDelegate.shared, action: #selector(AppDelegate.openProjectPanel(_:)))
        openProject.bezelStyle = .rounded
        for view in [emptyText, openProject] { empty.addArrangedSubview(view) }
        empty.orientation = .vertical
        empty.alignment = .centerX
        empty.spacing = 10
        empty.isHidden = true

        for view in [content, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            top.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            intro.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -64),
        ])
    }

    /// Each agent's rule, as of October 2026 (SkillLibrary.Reader).
    static let rulesTip = """
        Claude Code reads .claude/skills and takes your copy of a skill over the project's. Codex reads .agents/skills \
        and lists both copies. Command Code reads .commandcode/skills, then .agents/skills, and takes the project's copy. \
        An agent in a Next Term tab can also use the others through Next Term's skill library (list_skills, get_skill).
        """

    // MARK: data

    /// The open projects, the front window's first: each once, by its real path, never the home folder.
    static func openProjects() -> [String] {
        if let projectsForTest { return projectsForTest }
        let ordered = NSApp.orderedWindows.compactMap { $0.windowController as? TerminalWindowController }
        let home = canonicalPath(NSHomeDirectory())
        var seen = Set<String>(), result: [String] = []
        for project in (ordered + AppDelegate.shared.controllers).compactMap(\.project).map(canonicalPath)
        where project != home && seen.insert(project).inserted {
            result.append(project)
        }
        return result
    }

    /// A project as its window names it ("xCloud ▸ 7027-sso" for a linked worktree).
    static func title(_ project: String) -> String {
        let named = AppDelegate.shared.controllers.first { $0.project.map(canonicalPath) == project }?.projectTitle ?? ""
        return named.isEmpty ? (project as NSString).lastPathComponent : named
    }

    /// Reads the project's skills off the main thread, only while shown. `following`: a project newly in front is
    /// shown; one the user picked stays while the front one is the same.
    func reload(following: Bool = false) {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return }
        let open = Self.openProjects()
        let front = Self.projectsForTest == nil ? (TerminalWindow.front?.windowController as? TerminalWindowController)?.project.map(canonicalPath) : nil
        if following, let front, front != lastFront, open.contains(front) { project = front }
        if let front { lastFront = front }
        if project.map({ !open.contains($0) }) ?? true { project = front.flatMap { open.contains($0) ? $0 : nil } ?? open.first }
        fillPicker(open)
        content.isHidden = project == nil
        empty.isHidden = project != nil
        guard let project else { return }
        generation += 1
        let mine = generation, home = SkillsStore.home
        let app: AppDelegate = AppDelegate.shared
        let nextTerm = app.builtInSkills
        Task {
            let (overview, differ) = await Task.detached { () -> (SkillLibrary.Overview, [String: Bool]) in
                let overview = SkillLibrary.overview(project: project, home: home, nextTerm: nextTerm)
                var differ: [String: Bool] = [:]
                // Only names with two folders in the project are hashed: one copy can't differ.
                for skill in overview.skills where skill.copies.count > 1 {
                    let hashes = skill.copies.map { $0.folder.flatMap(SkillHash.folder) ?? UUID().uuidString }
                    differ[skill.name] = Set(hashes).count > 1
                }
                return (overview, differ)
            }.value
            guard mine == generation, project == self.project else { return }
            show(overview, differ: differ)
        }
    }

    private func fillPicker(_ open: [String]) {
        picker.menu?.removeAllItems()
        let titles = open.map(Self.title)
        for (path, title) in zip(open, titles) {
            let shown = titles.filter { $0 == title }.count > 1 ? "\(title) (\(SkillStep.short(path)))" : title
            let item = NSMenuItem(title: shown, action: nil, keyEquivalent: "")
            item.representedObject = path
            item.toolTip = path
            picker.menu?.addItem(item)
            if path == project { picker.select(item) }
        }
    }

    @objc private func picked() {
        project = picker.selectedItem?.representedObject as? String
        reload()
    }

    @objc private func changed() { reload() }

    @objc private func showPersonal() { onShowPersonal?() }

    private func show(_ overview: SkillLibrary.Overview, differ: [String: Bool]) {
        let kept = selected?.name
        self.overview = overview
        self.differ = differ
        rows = overview.skills.map(Row.skill) + BuiltInSkill.all.map { Row.builtIn($0.name) }
        let count = overview.skills.count, name = project.map(Self.title) ?? ""
        summary.stringValue = "\(count) \(count == 1 ? "skill" : "skills") · read-only"
        summary.toolTip = Self.totals(overview, reachable: AppDelegate.shared.agentControl)
        intro.stringValue = count == 0
            ? "No skills in \(name). Agents here look in .agents/skills, .claude/skills, .codex/skills and .commandcode/skills, in its folder and each one above it up to the repository's top. They still get your \(overview.personal) personal skills."
            : "Skills that come with \(name), in its folder and each one above it up to the repository's top. Each agent's column shows the copy it loads."
        personalButton.isHidden = count != 0
        table.reloadData()
        if let kept, let index = rows.firstIndex(where: { $0.name == kept }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        updateButtons()
    }

    /// How many skills each agent gets here, for the summary's tooltip: every description takes room in its context.
    static func totals(_ overview: SkillLibrary.Overview, reachable: Bool) -> String {
        let lines = SkillAgent.allCases.map { agent -> String in
            let entries = overview.byAgent[agent] ?? []
            let native = entries.filter(\.native)
            let fromProject = native.filter { $0.copy.scope == .project }.count
            var line = "\(agent.title) loads \(native.count) here itself (\(fromProject) from this project, \(native.count - fromProject) of yours)"
            let more = entries.count - native.count
            if reachable, more > 0 { line += "; in a Next Term tab it can use \(more) more through Next Term" }
            return line + "."
        }
        return (lines + ["Each skill's description takes room in the agent's context."]).joined(separator: "\n")
    }

    // MARK: cells

    /// A cell's text, tooltip and colour. `agentControl`, `offerTabs`: what Next Term's own row and "via Next Term" say.
    static func cell(_ row: Row, column: String, overview: SkillLibrary.Overview?, differ: [String: Bool],
                     agentControl: Bool, offerTabs: Bool) -> (text: String, tip: String?, color: NSColor) {
        switch (row, column) {
        case (.builtIn(let name), "name"): return (name, BuiltInSkill.named(name)?.description, .labelColor)
        case (.builtIn, "where"):
            return ("Next Term", "Agents get it from Next Term over MCP (get_skill). Nothing is written in their folders.", .secondaryLabelColor)
        case (.builtIn(let name), _):
            if !agentControl { return ("—", "Agents can't reach Next Term: agent control is off.", .tertiaryLabelColor) }
            if !offerTabs, BuiltInSkill.named(name)?.offersTabs == true {
                return ("off", "Off in Settings › Editor › Agents offer to run parallel work in tabs.", .tertiaryLabelColor)
            }
            return ("via Next Term", "In a Next Term tab, its MCP instructions say when to read it, and get_skill gives the rules.", .secondaryLabelColor)
        case (.skill(let skill), "name"): return (skill.name, skill.description.isEmpty ? nil : skill.description, .labelColor)
        case (.skill(let skill), "where"): return whereText(skill, differ: differ[skill.name])
        case (.skill(let skill), _):
            guard let agent = SkillAgent(rawValue: column), let entry = overview?.entry(skill.name, for: agent) else {
                return ("—", nil, .tertiaryLabelColor)
            }
            return agentText(skill, entry, agent: agent, agentControl: agentControl)
        }
    }

    /// Where the project's copies are: one place, or two that are the same or differ.
    static func whereText(_ skill: SkillLibrary.Overview.Skill, differ: Bool?) -> (text: String, tip: String?, color: NSColor) {
        let places = skill.copies.map(\.place)
        guard places.count > 1 else { return (places.first ?? "", skill.copies.first?.folder.map(SkillStep.short), .secondaryLabelColor) }
        let list = places.joined(separator: ", ")
        switch differ {
        case true?: return ("\(places.count) copies differ", "The copies differ: \(list).", .systemOrange)
        case false?:
            let short = places.map { $0.hasSuffix("/skills") ? String($0.dropLast("/skills".count)) : $0 }
            return (short.joined(separator: " + "), "\(places.count) identical copies: \(list).", .secondaryLabelColor)
        case nil: return (places.joined(separator: " + "), list, .secondaryLabelColor)
        }
    }

    /// What one agent gets of a skill here: the project's copy, the user's in its place, more than one copy, or the
    /// skill only through Next Term.
    static func agentText(_ skill: SkillLibrary.Overview.Skill, _ entry: SkillLibrary.Entry, agent: SkillAgent,
                          agentControl: Bool) -> (text: String, tip: String?, color: NSColor) {
        let reader = SkillLibrary.Reader(program: agent.rawValue), title = agent.title
        func at(_ copy: SkillLibrary.Copy) -> String { copy.place + "/" + skill.name }
        if entry.native {
            if entry.copy.scope == .personal {
                // Shadowing is always said: people expect the project's copy to win.
                if let theirs = skill.copies.first(where: reader.reads) {
                    return ("● personal", "\(title) loads \(at(entry.copy)), not this project's \(at(theirs)): it takes your copy first.", .systemOrange)
                }
                let theirs = skill.copies.first.map(at) ?? skill.name
                return ("● personal", "\(title) loads \(at(entry.copy)). It doesn't read this project's \(theirs).", .systemOrange)
            }
            let others = entry.others.filter(reader.reads)
            guard !others.isEmpty else { return ("● project", "\(title) loads \(at(entry.copy)).", .labelColor) }
            let list = SkillPackage.list(others.map(at))
            let tip = "\(title) loads \(at(entry.copy))" + (agent == .codex ? ", and also lists \(list) (both copies show up)." : ", and ignores \(list).")
            return ("● project +\(others.count)", tip, .systemOrange)
        }
        guard agentControl else {
            return ("—", "\(title) doesn't read \(at(entry.copy)), and agents can't reach Next Term while agent control is off.", .tertiaryLabelColor)
        }
        return ("via Next Term", "\(title) doesn't read \(at(entry.copy)) itself. In a Next Term tab it can still use it through Next Term's skill library (list_skills, get_skill).", .secondaryLabelColor)
    }

    /// A cell as the table shows it.
    func cellText(_ row: Row, column: String) -> (text: String, tip: String?, color: NSColor) {
        let app: AppDelegate = AppDelegate.shared
        return Self.cell(row, column: column, overview: overview, differ: differ, agentControl: app.agentControl, offerTabs: app.agentsOfferTabs)
    }

    /// No project is open: the view asks for one.
    var showsEmpty: Bool { !empty.isHidden }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard let column = tableColumn, rows.indices.contains(index) else { return nil }
        let (text, tip, color) = cellText(rows[index], column: column.identifier.rawValue)
        let cell = NSTextField(labelWithString: text)
        cell.lineBreakMode = .byTruncatingTail
        cell.toolTip = tip
        cell.textColor = color
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    // MARK: actions

    private var selected: Row? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }

    private func updateButtons() {
        let row = selected
        if case .builtIn? = row { openButton.title = "View Instructions" } else { openButton.title = "Open SKILL.md" }
        openButton.isEnabled = row != nil
        if case .skill? = row { revealButton.isEnabled = true } else { revealButton.isEnabled = false }
    }

    /// Opens the nearest copy's SKILL.md in its own project's window (where git shows its changes), or shows Next
    /// Term's own skill.
    @objc private func openSelected() {
        switch selected {
        case .builtIn(let name)?: viewInstructions(name)
        case .skill(let skill)?: open(skill.copies.first?.folder)
        case nil: break
        }
    }

    private func open(_ folder: String?) {
        guard let folder, let file = ["SKILL.md", "skill.md"].map({ folder + "/" + $0 }).first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return NSSound.beep()
        }
        AppDelegate.shared.openFile(file, line: nil, column: 1, newWindow: false)
    }

    @objc private func reveal() {
        guard case .skill(let skill)? = selected else { return }
        NSWorkspace.shared.activateFileViewerSelecting(skill.copies.compactMap(\.folder).map { URL(fileURLWithPath: $0) })
    }

    /// One of Next Term's own skills, as agents get it: there is no file to open.
    func viewInstructions(_ name: String) {
        guard let skill = BuiltInSkill.named(name) else { return }
        let alert = NSAlert()
        alert.messageText = skill.name
        alert.informativeText = "Next Term's own skill, as agents in its tabs get it over MCP (get_skill). Nothing is written in their folders. "
            + (skill.offersTabs ? "Settings › Editor › Agents offer to run parallel work in tabs turns it off." : "It is there while agents may control Next Term.")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
        let text = NSTextView(frame: scroll.bounds)
        text.string = skill.text
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Done")
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// The row's menu: what the buttons do, the path, and the user's own copy where an agent loads it instead.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard rows.indices.contains(table.clickedRow) else { return }
        table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        func add(_ title: String, _ action: Selector, _ object: Any? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = object
            menu.addItem(item)
        }
        switch rows[table.clickedRow] {
        case .builtIn(let name):
            add("View Instructions", #selector(openSelected))
            if BuiltInSkill.named(name)?.offersTabs == true { add("Turn Off in Settings › Editor…", #selector(showEditor)) }
        case .skill(let skill):
            add("Open SKILL.md", #selector(openSelected))
            add("Show in Finder", #selector(reveal))
            add("Copy Path", #selector(copyPath(_:)), skill.copies.first?.folder)
            var yours: [String] = []
            for agent in SkillAgent.allCases {
                guard let entry = overview?.entry(skill.name, for: agent), entry.native, entry.copy.scope == .personal,
                      let folder = entry.copy.folder, !yours.contains(folder) else { continue }
                yours.append(folder)
                add("Open Your Copy (\(entry.copy.place)/\(skill.name))", #selector(openYours(_:)), folder)
            }
        }
    }

    @objc private func showEditor() { AppDelegate.shared.showSettings(tab: "editor") }

    @objc private func openYours(_ sender: NSMenuItem) { open(sender.representedObject as? String) }

    @objc private func copyPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}
