import AppKit
import NextTermCore

/// Settings › Agents (plan 038): the coding agents on the login shell's PATH, however they were installed — each with
/// its version, what installed it, the latest version, and its auto-update (Off · Daily · Weekly, Off until the user
/// picks one). Update Now runs the exact update command in a new tab, where the user sees it; Check for Updates asks the
/// latest versions again. A tool that updates itself says so: with a lasting switch of its own, its schedule here is for
/// when that is off; with none, there is no schedule. A copy Next Term can't update (an administrator's folder, npx's
/// temporary one) says why, and offers nothing. The agents not installed show behind Show agents you don't have; one
/// with an official one-line installer has Install…, which types it in a tab for the user to run.
///
/// Opening the section looks along PATH and asks the latest versions (cached a day, off the main thread): nothing is
/// read before.
final class AgentsSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let intro = NSTextField(wrappingLabelWithString: "The coding agents on your PATH, however they were installed. "
        + "Next Term updates one only when you click Update Now, or on a schedule you pick.")
    let table = NSTableView()
    let detail = NSTextField(wrappingLabelWithString: "")
    let updateButton = NSButton(title: "Update Now", target: nil, action: nil)
    let installButton = NSButton(title: "Install\u{2026}", target: nil, action: nil)
    let checkButton = NSButton(title: "Check for Updates", target: nil, action: nil)
    let showAll = NSButton(checkboxWithTitle: "Show agents you don\u{2019}t have", target: nil, action: nil)
    let status = NSTextField(labelWithString: "")
    let emptyTitle = NSTextField(labelWithString: "No coding agents on your PATH")
    let emptyText = NSTextField(wrappingLabelWithString: "Agents you install with npm, Homebrew or their own installers show here.")
    private let emptyShowAll = NSButton(title: "Show Agents You Don\u{2019}t Have", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let content = NSStackView()
    private let empty = NSStackView()
    private var keyObserver: NSObjectProtocol?

    /// The rows shown: the installed agents, then (with Show agents you don't have) the others.
    private(set) var rows: [AgentCLIs.Status] = []
    private var manager: AgentCLIManager { AgentCLIManager.shared }

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: AgentCLIManager.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shown, or Settings brought back after an update in a tab: look again (the latest versions from the day's cache).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        guard let window else { return }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
        look()
    }

    private func look() {
        guard !manager.checking else { return }
        manager.reload(fetch: true)
    }

    // MARK: layout

    private func build() {
        for label in [intro, detail, status, emptyText] {
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        let columns: [(String, String, CGFloat)] = [("agent", "Agent", 112), ("version", "Version", 128), ("method", "Installed by", 108),
                                                    ("latest", "Latest", 92), ("schedule", "Auto-update", 116)]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 60
            column.resizingMask = id == "agent" ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.setAccessibilityLabel("Coding agents")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let actions: [(NSButton, Selector)] = [(updateButton, #selector(updateNow)), (installButton, #selector(install)),
                                               (checkButton, #selector(checkNow)), (showAll, #selector(toggleAll)),
                                               (emptyShowAll, #selector(showMissing))]
        for (button, action) in actions {
            button.target = self
            button.action = action
            if button !== showAll { button.bezelStyle = .rounded }
        }
        let buttons = NSStackView(views: [updateButton, installButton, NSView(), status, checkButton])
        buttons.spacing = 8
        for view in [intro, scroll, detail, buttons, showAll] as [NSView] { content.addArrangedSubview(view) }
        content.setCustomSpacing(14, after: buttons)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)

        emptyTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        emptyText.alignment = .center
        emptyShowAll.bezelStyle = .rounded
        for view in [emptyTitle, emptyText, emptyShowAll] { empty.addArrangedSubview(view) }
        empty.orientation = .vertical
        empty.alignment = .centerX
        empty.spacing = 8
        empty.setCustomSpacing(14, after: emptyText)
        empty.isHidden = true

        for view in [content, empty] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            intro.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            detail.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            empty.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        detail.setContentHuggingPriority(.required, for: .vertical)
        reload()
    }

    // MARK: state

    @objc private func changed() { reload() }

    /// The rows from the manager's last look, the selection kept by agent.
    func reload() {
        let selected = table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow].agent.id : nil
        let installed = manager.statuses.filter(\.installed)
        rows = installed + (showAll.state == .on ? manager.statuses.filter { !$0.installed } : [])
        table.reloadData()
        if let selected, let index = rows.firstIndex(where: { $0.agent.id == selected }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if !rows.isEmpty, table.selectedRow < 0 {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        // With no agent at all, and the others hidden: one calm line, and the way to see the others.
        let nothing = installed.isEmpty && showAll.state == .off && manager.looked
        content.isHidden = nothing
        empty.isHidden = !nothing
        checkButton.isEnabled = !manager.checking && !installed.isEmpty
        if manager.checking {
            status.stringValue = "Checking\u{2026}"
        } else if let checked = manager.checkedAt {
            status.stringValue = "Checked \(checked.formatted(date: .omitted, time: .shortened))"
        } else {
            status.stringValue = ""
        }
        selectionChanged()
    }

    private var selected: AgentCLIs.Status? {
        table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow] : nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) { selectionChanged() }

    private func selectionChanged() {
        guard let row = selected else {
            updateButton.isEnabled = false
            installButton.isHidden = true
            detail.stringValue = ""
            return
        }
        let agent = row.agent
        guard let copy = row.copy else {
            updateButton.isHidden = true
            installButton.isHidden = agent.installer == nil
            installButton.toolTip = agent.installer.map { "Types \u{201C}\($0)\u{201D} in a new tab, for you to run" }
            detail.stringValue = agent.installer == nil
                ? "\(agent.name) isn\u{2019}t on your PATH."
                : "\(agent.name) isn\u{2019}t on your PATH. Install\u{2026} types its official installer in a new tab, for you to read and run."
            return
        }
        updateButton.isHidden = false
        installButton.isHidden = true
        let command = AgentCLIs.updateCommand(agent, copy)
        updateButton.isEnabled = command != nil && !manager.updating.contains(agent.id)
        updateButton.toolTip = command.map { "Runs \u{201C}\($0)\u{201D} in a new tab" }
        detail.stringValue = Self.detail(row)
    }

    /// The selected agent's lines: where it runs from and what updates it, whether it updates itself, and any other
    /// copy PATH hides behind it.
    static func detail(_ row: AgentCLIs.Status) -> String {
        guard let copy = row.copy else { return "" }
        let agent = row.agent
        var first = "Runs from \(abbreviated(copy.path))."
        if let refusal = AgentCLIs.refusal(agent, copy) {
            first += " " + refusal
        } else if let command = AgentCLIs.updateCommand(agent, copy) {
            first += " Update Now runs \u{201C}\(command)\u{201D} in a new tab."
        }
        var lines = [first]
        switch agent.selfUpdate(copy.method) {
        case .yes(let off?):
            lines.append("\(agent.name) updates itself; its own switch is \(off). A schedule here is for when that is off.")
        case .yes(nil):
            lines.append("\(agent.name) updates itself, so there is no schedule for it here.")
        case .notifies:
            lines.append("\(agent.name) tells you about its updates, and installs none itself.")
        case .no: break
        }
        for other in row.copies.dropFirst() {
            let version = other.version.map { " \($0)" } ?? ""
            lines.append("Also on your PATH, after it: \(other.method.name)\(version) at \(abbreviated(other.path)).")
        }
        return lines.joined(separator: "\n")
    }

    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: actions

    @objc private func updateNow() {
        guard let row = selected, row.installed else { return }
        manager.updateInTab(row)
    }

    @objc private func install() {
        guard let row = selected, !row.installed else { return }
        manager.installInTab(row.agent)
    }

    @objc private func checkNow() { manager.reload(fetch: true, force: true) }

    @objc private func toggleAll() { reload() }

    @objc private func showMissing() {
        showAll.state = .on
        reload()
    }

    @objc private func scheduleChanged(_ sender: NSPopUpButton) {
        let index = sender.tag
        guard index >= 0, index < rows.count, let picked = sender.selectedItem?.representedObject as? String,
              let schedule = AgentCLIs.Schedule(rawValue: picked) else { return }
        manager.setSchedule(schedule, for: rows[index].agent.id)
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, row < rows.count else { return nil }
        let status = rows[row]
        if id == "schedule", let copy = status.copy, AgentCLIs.offersSchedule(status.agent, copy) {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            // The row's own type size, as the other cells: a smaller popup reads as a lesser column.
            popup.controlSize = .regular
            popup.font = .systemFont(ofSize: NSFont.systemFontSize)
            popup.isBordered = false
            for schedule in AgentCLIs.Schedule.allCases {
                popup.addItem(withTitle: schedule.title)
                popup.lastItem?.representedObject = schedule.rawValue
            }
            popup.selectItem(at: AgentCLIs.Schedule.allCases.firstIndex(of: status.schedule) ?? 0)
            popup.tag = row
            popup.target = self
            popup.action = #selector(scheduleChanged(_:))
            popup.setAccessibilityLabel("Auto-update \(status.agent.name)")
            return popup
        }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: text(id, status))
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = secondary(id, status) ? .secondaryLabelColor : .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// A cell's words.
    func text(_ column: String, _ status: AgentCLIs.Status) -> String {
        guard let copy = status.copy else {
            switch column {
            case "agent": return status.agent.name
            case "version": return "Not installed"
            default: return ""
            }
        }
        switch column {
        case "agent": return status.agent.name
        case "version": return copy.version ?? "\u{2014}"
        case "method": return copy.method.name
        case "latest":
            if manager.updating.contains(status.agent.id) { return "Updating\u{2026}" }
            guard let latest = status.latest else { return manager.checking ? "" : "\u{2014}" }
            guard let version = copy.version else { return latest }
            return AgentCLIs.isNewer(latest, than: version) ? latest : "Up to date"
        case "schedule":
            if case .yes = status.agent.selfUpdate(copy.method) { return "Updates itself" }
            return "\u{2014}"
        default: return ""
        }
    }

    private func secondary(_ column: String, _ status: AgentCLIs.Status) -> Bool {
        guard status.installed else { return true }
        switch column {
        case "latest": return !status.updateAvailable
        case "schedule", "method": return true
        default: return false
        }
    }
}
