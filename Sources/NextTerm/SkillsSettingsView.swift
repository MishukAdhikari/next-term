import AppKit
import NextTermCore

/// Settings › Skills: every personal skill on this Mac, and what Claude Code, Codex and Command Code
/// each load for it. Copies of one skill that drifted apart, or that an agent ignores, are marked, and
/// Unify turns them into one shared copy every agent sees (with Undo). Read-only until the user acts.
final class SkillsSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let filter = NSPopUpButton()
    private let summary = NSTextField(labelWithString: "")
    private let unifyButton = NSButton(title: "Unify…", target: nil, action: nil)
    private let openButton = NSButton(title: "Open SKILL.md", target: nil, action: nil)
    private let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private var inventory: SkillInventory?
    private var rows: [SkillRow] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(reloadFromNotification), name: SkillsStore.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: layout

    private func build() {
        let intro = NSTextField(wrappingLabelWithString: "Skills your agents load from ~/.agents/skills (shared), ~/.claude/skills, ~/.codex/skills and ~/.commandcode/skills. Claude Code reads only its own folder; Codex and Command Code also read the shared one.")
        intro.textColor = .secondaryLabelColor
        intro.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        filter.addItems(withTitles: ["All skills", "Needs attention"])
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
        for (button, action) in [(unifyButton, #selector(unify)), (openButton, #selector(openSkill)), (revealButton, #selector(reveal)), (undoButton, #selector(undo))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        let top = NSStackView(views: [filter, summary])
        top.spacing = 12
        let buttons = NSStackView(views: [unifyButton, openButton, revealButton, NSView(), undoButton])
        buttons.spacing = 8
        let stack = NSStackView(views: [intro, top, scroll, buttons])
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
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
    }

    // MARK: data

    @objc private func reloadFromNotification() { reload() }

    func reload() {
        let inventory = SkillsStore.inventory()
        self.inventory = inventory
        let needsAttention = filter.indexOfSelectedItem == 1
        rows = inventory.rows.filter { !needsAttention || Self.needsAttention($0) }
        let problems = inventory.rows.filter(Self.needsAttention).count
        summary.stringValue = "\(inventory.rows.count) skills · \(problems) need attention"
        table.reloadData()
        updateButtons()
    }

    /// Copies that differ, duplicates an agent ignores, links to nothing, or a skill an agent skips.
    static func needsAttention(_ row: SkillRow) -> Bool {
        if row.health != .ok { return true }
        return SkillAgent.allCases.contains { agent in
            let load = row.load(for: agent)
            return load.skippedBecause != nil || !load.others.isEmpty
        }
    }

    @objc private func filterChanged() { reload() }

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

    private func updateButtons() {
        let row = selectedRow
        unifyButton.isEnabled = row.map { !$0.isUnified && !$0.distinctCopies.isEmpty } ?? false
        openButton.isEnabled = row?.distinctCopies.isEmpty == false
        revealButton.isEnabled = row != nil
        let last = SkillsStore.lastChange
        undoButton.isEnabled = last != nil
        undoButton.title = last.map { "Undo \($0.title)" } ?? "Undo"
    }

    // MARK: actions

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
        guard let row = selectedRow, let inventory, let window else { return }
        let sheet = SkillsUnifySheet(row: row, inventory: inventory)
        sheet.begin(over: window) { steps in
            guard let steps else { return }
            if case .failure(let failure) = SkillsStore.apply(steps, title: "Unify \(row.name)") { Self.tell(failure.message, in: window) }
        }
    }

    static func tell(_ message: String, in window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The skills were not changed"
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
            choice.addItem(withTitle: "\(copy.root.title) — changed \(formatter.string(from: Self.modified(copy)))\(problem)")
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
        // The staging folder is a detail: show "copy the winner to the shared folder" once.
        var lines = SkillUnify.plan(row, winner: winner, in: inventory).compactMap { step -> String? in
            switch step {
            case .copy(let from, let to) where to.hasSuffix(".nextterm-unify"):
                return "Copy \(SkillStep.short(from)) to \(SkillStep.short(String(to.dropLast(".nextterm-unify".count))))"
            case .copy(let from, _) where from.hasSuffix(".nextterm-unify"): return nil
            case .trash(let path) where path.hasSuffix(".nextterm-unify"): return nil
            default: return step.summary
            }
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
