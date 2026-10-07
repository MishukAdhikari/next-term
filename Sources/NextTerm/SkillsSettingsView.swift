import AppKit
import NextTermCore

/// Settings › Skills: every personal skill on this Mac, and what Claude Code, Codex and Command Code
/// each load for it. Copies of one skill that drifted apart, or that an agent ignores, are marked, and
/// Unify turns them into one shared copy every agent sees (with Undo). Read-only until the user acts.
final class SkillsSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private let table = NSTableView()
    private let filter = NSPopUpButton()
    private let summary = NSTextField(labelWithString: "")
    private let unifyButton = NSButton(title: "Unify…", target: nil, action: nil)
    private let openButton = NSButton(title: "Open SKILL.md", target: nil, action: nil)
    private let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private let linkButton = NSButton(title: "Link for Claude Code", target: nil, action: nil)
    private let updateButton = NSButton(title: "Update…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove…", target: nil, action: nil)
    private let checkButton = NSButton(title: "Check for Updates", target: nil, action: nil)
    private let browseButton = NSButton(title: "Browse Skills…", target: nil, action: nil)
    private let checkOnOpen = NSButton(checkboxWithTitle: "Check for updates when Window › Skills opens", target: nil, action: nil)
    private var inventory: SkillInventory?
    private var rows: [SkillRow] = []
    /// The project whose skills are shown, read-only (nil: the personal skills). Kept by path, so a
    /// project that closes can never be confused with another.
    private var project: String?
    private var review: SkillsReviewSheet?
    /// Counts reloads, so a slow scan never overwrites a newer one.
    private var generation = 0
    private var keyObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(reloadFromNotification), name: SkillsStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadFromNotification), name: SkillsInstaller.updatesChanged, object: nil)
    }

    /// Shown (or Settings brought back): read the folders again, since agents and `npx skills` change them.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        guard let window else { return }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: layout

    private func build() {
        let intro = NSTextField(wrappingLabelWithString: "Skills your agents load from ~/.agents/skills (shared), ~/.claude/skills, ~/.codex/skills and ~/.commandcode/skills. Claude Code reads only its own folder; Codex and Command Code also read the shared one.")
        intro.textColor = .secondaryLabelColor
        intro.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        filter.addItems(withTitles: ["All skills", "Needs attention"])
        filter.menu?.delegate = self
        filter.target = self
        filter.action = #selector(filterChanged)

        let columns: [(String, String, CGFloat)] = [("name", "Skill", 190), (SkillAgent.claudeCode.rawValue, "Claude Code", 110),
                                                    (SkillAgent.codex.rawValue, "Codex", 110), (SkillAgent.commandCode.rawValue, "Command Code", 120),
                                                    ("state", "State", 150)]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.target = self
        table.doubleAction = #selector(openSkill)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        summary.textColor = .secondaryLabelColor
        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let actions: [(NSButton, Selector)] = [(unifyButton, #selector(unify)), (openButton, #selector(openSkill)), (revealButton, #selector(reveal)),
                                               (undoButton, #selector(undo)), (linkButton, #selector(linkForClaude)), (updateButton, #selector(update)),
                                               (removeButton, #selector(remove)), (checkButton, #selector(checkForUpdates)), (browseButton, #selector(browse))]
        for (button, action) in actions {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        checkOnOpen.target = self
        checkOnOpen.action = #selector(checkOnOpenChanged)
        checkOnOpen.state = SkillsWindowController.checksOnOpen ? .on : .off
        checkOnOpen.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let top = NSStackView(views: [filter, summary, NSView(), checkButton, browseButton])
        top.spacing = 8
        let buttons = NSStackView(views: [unifyButton, linkButton, updateButton, removeButton, NSView(), undoButton])
        buttons.spacing = 8
        let more = NSStackView(views: [openButton, revealButton])
        more.spacing = 8
        let stack = NSStackView(views: [intro, top, scroll, buttons, more, checkOnOpen])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            more.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
    }

    // MARK: data

    @objc private func reloadFromNotification() { reload() }

    /// Reads the folders off the main thread (it reads every SKILL.md, and hashes copies to compare),
    /// only while the view is on screen.
    func reload() {
        guard window != nil else { return }
        generation += 1
        let mine = generation
        let home = project ?? SkillsStore.home
        Task {
            let inventory = await Task.detached { SkillInventory.scan(home: home) }.value
            guard mine == generation else { return }
            show(inventory)
        }
    }

    private func show(_ inventory: SkillInventory) {
        self.inventory = inventory
        let needsAttention = filter.indexOfSelectedItem == 1
        rows = inventory.rows.filter { !needsAttention || Self.needsAttention($0) }
        let problems = inventory.rows.filter(Self.needsAttention).count
        if let project {
            summary.stringValue = "\(inventory.rows.count) skills in \(SkillStep.short(project)), read-only"
            summary.toolTip = "Shown as they are: Next Term never changes a project."
        } else {
            summary.stringValue = "\(inventory.rows.count) skills · \(problems) need attention"
            summary.toolTip = nil
        }
        table.reloadData()
        updateButtons()
    }

    /// The inventory shown is the personal one (not a project's): only then may anything be changed.
    private var showsPersonal: Bool { project == nil && inventory?.home == SkillsStore.home }

    /// Copies that differ, duplicates an agent ignores, links to nothing, or a skill an agent skips.
    static func needsAttention(_ row: SkillRow) -> Bool {
        if row.health != .ok { return true }
        return SkillAgent.allCases.contains { agent in
            let load = row.load(for: agent)
            return load.skippedBecause != nil || !load.others.isEmpty
        }
    }

    @objc private func filterChanged() {
        project = filter.selectedItem?.representedObject as? String
        inventory = nil
        updateButtons()
        reload()
    }

    /// The filter lists the projects open right now, each time it opens (by path: two projects may
    /// share a folder name). When the chosen one has closed, the filter goes back to all skills.
    func menuNeedsUpdate(_ menu: NSMenu) {
        while menu.numberOfItems > 2 { menu.removeItem(at: 2) }
        let projects = Array(Set(SkillsInstaller.openProjects)).sorted()
        if !projects.isEmpty { menu.addItem(.separator()) }
        let names = projects.map { ($0 as NSString).lastPathComponent }
        for path in projects {
            let name = (path as NSString).lastPathComponent
            let title = names.filter { $0 == name }.count > 1 ? "Project: \(name) (\(SkillStep.short(path)))" : "Project: " + name
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = path
            menu.addItem(item)
            if path == project { filter.select(item) }
        }
        if let project, !projects.contains(project) {
            self.project = nil
            filter.selectItem(at: 0)
            inventory = nil
            updateButtons()
            reload()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard let column = tableColumn, rows.indices.contains(index) else { return nil }
        let row = rows[index]
        let cell = NSTextField(labelWithString: "")
        cell.lineBreakMode = .byTruncatingTail
        switch column.identifier.rawValue {
        case "name":
            cell.stringValue = row.name
            cell.toolTip = row.copies.first?.frontMatter?.description
        case "state":
            cell.stringValue = Self.stateText(row)
            cell.textColor = Self.needsAttention(row) ? .systemOrange : .secondaryLabelColor
            if project == nil, let state = SkillsInstaller.updates[row.name] {
                switch state {
                case .available:
                    cell.stringValue = "Update available"
                    cell.textColor = .controlAccentColor
                case .unknown(let reason):
                    cell.toolTip = "The update check could not tell: \(reason)"
                case .current: break
                }
            }
        default:
            guard let agent = SkillAgent(rawValue: column.identifier.rawValue) else { return cell }
            let (text, tip) = Self.cellText(row, agent: agent)
            cell.stringValue = text
            cell.toolTip = tip
            if text.hasPrefix("skipped") || text.contains("+") { cell.textColor = .systemOrange }
            if text == "—" || text == "off" { cell.textColor = .tertiaryLabelColor }
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    /// What one agent loads, in a word, and the path it loads it from.
    static func cellText(_ row: SkillRow, agent: SkillAgent) -> (String, String?) {
        let load = row.load(for: agent)
        if let reason = load.skippedBecause { return ("skipped", "\(agent.title) skips this skill: \(reason)") }
        guard let used = load.used else { return ("—", "\(agent.title) does not see this skill.") }
        if load.switchedOff { return ("off", "\(agent.title)'s own settings switch this skill off (\(SkillStep.short(used.realPath))).") }
        var text = used.root.kind == .shared ? "● shared" : used.isLink ? "● link" : "● own copy"
        var tip = "\(agent.title) loads \(SkillStep.short(used.realPath))"
        if !load.others.isEmpty {
            text += " + \(load.others.count)"
            let others = load.others.map { SkillStep.short($0.path) }.joined(separator: ", ")
            tip += agent == .codex ? ", and also lists \(others) (both copies show up)." : ", and ignores \(others)."
        }
        return (text, tip)
    }

    static func stateText(_ row: SkillRow) -> String {
        switch row.health {
        case .broken: return "Broken link"
        case .drifted: return "\(row.distinctCopies.count) copies differ"
        case .duplicated: return "\(row.distinctCopies.count) identical copies"
        case .ok:
            if row.isUnified { return "Shared" }
            if needsAttention(row) { return "Ignored copy" }
            return row.copies.first?.root.kind == .shared ? "Shared" : "One copy"
        }
    }

    private var selectedRow: SkillRow? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }

    /// The selected skill has a copy in the shared folder (what Install puts there, and Remove takes).
    private var sharedCopy: SkillCopy? { selectedRow?.copies.first { $0.root.kind == .shared && !$0.broken } }

    private func updateButtons() {
        let row = selectedRow
        let personal = showsPersonal
        unifyButton.isEnabled = personal && (row.map { !$0.isUnified && !$0.distinctCopies.isEmpty } ?? false)
        let claudeRoot = inventory?.root(.claude)
        linkButton.isEnabled = personal && sharedCopy != nil && claudeRoot != nil && row?.copies.contains { $0.root.kind == .claude } == false
        removeButton.isEnabled = personal && sharedCopy != nil
        // A skill neither Next Term nor npx skills installed is only moved to the Trash.
        removeButton.title = row.map { SkillsInstaller.tracksInstall($0.name) } == false ? "Move to Trash…" : "Remove…"
        if let row, case .available = SkillsInstaller.updates[row.name] { updateButton.isEnabled = personal } else { updateButton.isEnabled = false }
        checkButton.isEnabled = personal
        openButton.isEnabled = row?.distinctCopies.isEmpty == false
        revealButton.isEnabled = row != nil
        let last = SkillsStore.lastChange
        undoButton.isEnabled = last != nil
        undoButton.toolTip = last.map { "Undo “\($0.title)”" }
    }

    // MARK: actions

    @objc private func checkOnOpenChanged() { SkillsWindowController.checksOnOpen = checkOnOpen.state == .on }

    @objc private func browse() { SkillsWindowController.show() }

    @objc private func checkForUpdates() {
        checkButton.isEnabled = false
        checkButton.title = "Checking…"
        Task {
            await SkillsInstaller.checkForUpdates()
            checkButton.title = "Check for Updates"
            checkButton.isEnabled = true
            let count = SkillsInstaller.updates.values.filter { if case .available = $0 { return true }; return false }.count
            summary.stringValue += count == 0 ? " · no updates" : " · \(count) update\(count == 1 ? "" : "s")"
        }
    }

    /// Claude Code reads only ~/.claude/skills: a link there to the shared copy.
    @objc private func linkForClaude() {
        guard showsPersonal, let row = selectedRow, let inventory, let claudeRoot = inventory.root(.claude), let sharedRoot = inventory.root(.shared), let window else { return }
        let at = (claudeRoot.path as NSString).appendingPathComponent(row.name)
        let to = (sharedRoot.path as NSString).appendingPathComponent(row.name)
        if case .failure(let failure) = SkillsStore.apply([.link(at: at, to: to)], title: "Link \(row.name) for Claude Code") { Self.tell(failure.message, in: window) }
    }

    /// An update: the new commit is fetched and reviewed like an install, with what changed.
    @objc private func update() {
        guard let row = selectedRow, let window else { return }
        updateButton.isEnabled = false
        Task {
            defer { updateButtons() }
            guard let item = await SkillsInstaller.tracked().first(where: { $0.name == row.name }) else { return }
            do {
                let fetched = try await SkillsInstaller.fetch(SkillSource(owner: item.source.owner, repo: item.source.repo, ref: item.source.ref, path: item.path))
                let sheet = SkillsReviewSheet(fetched: fetched) { [weak self] installed in
                    self?.review = nil
                    if installed != nil { SkillsInstaller.updates[row.name] = .current }
                }
                review = sheet
                if let sheetWindow = sheet.window { window.beginSheet(sheetWindow, completionHandler: nil) }
            } catch {
                Self.tell((error as? SkillsGitHub.Failure)?.message ?? error.localizedDescription, in: window, title: "The update could not be fetched")
            }
        }
    }

    /// Remove: the shared copy, every agent folder's link to it, its lock entry and record, after the
    /// developer has seen exactly that, and what the skill asked for that outlives it. The steps are
    /// worked out again on confirming; if they changed meanwhile, nothing happens.
    @objc private func remove() {
        guard showsPersonal, let row = selectedRow, let window else { return }
        Task {
            let (shown, leftovers, installed) = await SkillsInstaller.removal(row.name)
            guard !shown.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = installed ? "Remove “\(row.name)”?" : "Move “\(row.name)” to the Trash?"
            var lines = shown.map { "• " + $0.summary }
            lines.append("")
            if !installed { lines.append("Neither Next Term nor npx skills installed it: it was made by hand or copied here.") }
            lines.append("Agent sessions that are open now keep it until they restart.")
            lines += leftovers.map { "• " + $0 }
            let removed = Set(shown.compactMap { step -> String? in if case .trash(let path) = step { return path }; return nil })
            let others = row.copies.filter { ($0.root.kind == .codex || $0.root.kind == .commandCode) && !removed.contains($0.path) }
            if !others.isEmpty { lines.append("Copies in \(others.map { SkillStep.short($0.path) }.joined(separator: ", ")) are not part of it and stay.") }
            lines.append("Undo puts it back.")
            alert.informativeText = lines.joined(separator: "\n")
            alert.addButton(withTitle: installed ? "Remove" : "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[0].keyEquivalent = ""
            alert.buttons[1].keyEquivalent = "\r"
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                Task {
                    let (steps, _, _) = await SkillsInstaller.removal(row.name)
                    guard steps == shown else { return Self.tell("“\(row.name)” changed since you looked. Look again before removing it.", in: window) }
                    if case .failure(let failure) = SkillsStore.apply(steps, title: "Remove \(row.name)") { Self.tell(failure.message, in: window) }
                }
            }
        }
    }

    @objc private func openSkill() {
        guard let copy = selectedRow?.distinctCopies.first else { return }
        let file = ["SKILL.md", "skill.md"].map { (copy.realPath as NSString).appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0) }
        guard let file else { return NSSound.beep() }
        AppDelegate.shared.openFile(file, line: nil, column: 1, newWindow: false)
    }

    @objc private func reveal() {
        guard let row = selectedRow else { return }
        NSWorkspace.shared.activateFileViewerSelecting(row.copies.map { URL(fileURLWithPath: $0.path) })
    }

    @objc private func undo() {
        guard let last = SkillsStore.lastChange, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Undo “\(last.title)”?"
        alert.informativeText = "Puts back the skill folders and links as they were before it."
        alert.addButton(withTitle: "Undo")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            if case .failure(let failure) = SkillsStore.undo() { Self.tell(failure.message, in: window) }
        }
    }

    /// Unify: one shared copy every agent sees. Shows the steps first; for copies that differ, the user
    /// picks the version that wins.
    @objc private func unify() {
        guard showsPersonal, let row = selectedRow, let inventory, let window else { return }
        let sheet = SkillsUnifySheet(row: row, inventory: inventory)
        sheet.begin(over: window) { steps in
            guard let steps else { return }
            if case .failure(let failure) = SkillsStore.apply(steps, title: "Unify \(row.name)") { Self.tell(failure.message, in: window) }
        }
    }

    static func tell(_ message: String, in window: NSWindow, title: String = "The skills were not changed") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
}

/// The unify sheet: which copy wins (when they differ), and the exact steps that will happen.
final class SkillsUnifySheet: NSObject {
    private let row: SkillRow
    private let inventory: SkillInventory
    private let choice = NSPopUpButton()
    private let stepsText = NSTextField(wrappingLabelWithString: "")
    private let copies: [SkillCopy]
    private weak var unifyButton: NSButton?

    init(row: SkillRow, inventory: SkillInventory) {
        self.row = row
        self.inventory = inventory
        // The copy each candidate stands for, newest first.
        copies = row.distinctCopies.sorted { Self.modified($0) > Self.modified($1) }
        super.init()
    }

    static func modified(_ copy: SkillCopy) -> Date {
        let file = (copy.realPath as NSString).appendingPathComponent("SKILL.md")
        return ((try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date) ?? .distantPast
    }

    var winner: SkillCopy? { copies.indices.contains(choice.indexOfSelectedItem) ? copies[choice.indexOfSelectedItem] : copies.first }

    /// The first copy that can win, so the sheet opens on a choice that works.
    private var firstGood: Int { copies.firstIndex { row.cannotWin($0) == nil } ?? 0 }

    func begin(over window: NSWindow, done: @escaping ([SkillStep]?) -> Void) {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        for copy in copies {
            let problem = row.cannotWin(copy) == nil ? "" : " (breaks the standard)"
            let git = copy.hasGit ? " (a git clone, with its history)" : ""
            choice.addItem(withTitle: "\(copy.root.title) — changed \(formatter.string(from: Self.modified(copy)))\(git)\(problem)")
        }
        choice.selectItem(at: firstGood)
        choice.target = self
        choice.action = #selector(choiceChanged)
        stepsText.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let drifted = row.health == .drifted
        let label = NSTextField(labelWithString: drifted ? "The copies differ. Keep:" : "Keep:")
        let chooser = NSStackView(views: [label, choice])
        chooser.spacing = 6
        let stack = NSStackView(views: [chooser, stepsText])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 460, height: 230)
        stepsText.preferredMaxLayoutWidth = 460
        choiceChanged()

        let alert = NSAlert()
        alert.messageText = "Unify “\(row.name)”?"
        alert.informativeText = "One copy stays, in ~/.agents/skills: Codex and Command Code read it there, and Claude Code through a link. The other copies go to the Trash, and links are removed (never what they point to). Undo puts everything back."
        alert.accessoryView = stack
        unifyButton = alert.addButton(withTitle: "Unify")
        alert.addButton(withTitle: "Cancel")
        choiceChanged()
        alert.beginSheetModal(for: window) { [self] response in
            guard response == .alertFirstButtonReturn, let winner, row.cannotWin(winner) == nil else { return done(nil) }
            done(SkillUnify.plan(row, winner: winner, in: inventory))
        }
    }

    @objc private func choiceChanged() {
        guard let winner else { return }
        if let problem = row.cannotWin(winner) {
            // Command Code would skip the result: this copy can't be the one kept.
            stepsText.stringValue = "This copy can't be kept: \(problem) Command Code would skip it. Fix its SKILL.md, or keep another copy."
            unifyButton?.isEnabled = false
            return
        }
        unifyButton?.isEnabled = true
        // The staging copy is a detail: show "copy the winner to the shared folder" once.
        let steps = SkillUnify.plan(row, winner: winner, in: inventory)
        var placed: [String: String] = [:]
        for step in steps { if case .move(let from, let to) = step { placed[from] = to } }
        var lines = steps.compactMap { step -> String? in
            switch step {
            case .copy(let from, let to) where placed[to] != nil: return "Copy \(SkillStep.short(from)) to \(SkillStep.short(placed[to]!))"
            case .move: return nil
            default: return step.summary
            }
        }
        if row.copies.contains(where: { $0.hasGit && $0.realPath != winner.realPath }) {
            lines.append("A copy that goes to the Trash is a git clone: its history goes with it (Undo puts it back)")
        }
        for agent in SkillUnify.switchesLost(row, in: inventory) {
            lines.append("\(agent.title) switches this skill off under its old name or place: after Unify it loads it again, until you switch it off there")
        }
        let gained = SkillUnify.gained(row, in: inventory)
        if !gained.isEmpty {
            let names = gained.map(\.title).joined(separator: " and ")
            lines.append("\(names) will load it too\(winner.hasScripts ? ", scripts included" : "")")
        }
        stepsText.stringValue = lines.map { "• " + $0 }.joined(separator: "\n")
    }
}
