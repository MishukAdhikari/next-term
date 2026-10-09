import AppKit
import NextTermCore

/// The list of stored keys, shared by Settings › Secrets and Window › Secrets (U7): what guards them, each key with what
/// it's for, its write-only badge and its last use; the key buttons; the approvals in force; what is paused; and the
/// limits, said plainly. Each change asks for Touch ID or the Mac password once (KTD4).
@MainActor
final class SecretsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    /// Whether "Let agents control Next Term" is on (the self-test sets its own, so the socket stays up).
    static var agentControlIsOn: () -> Bool = { AppDelegate.shared.agentControl }
    static let docsURL = URL(string: "https://nxtrm.mishuk.me/docs/secrets/")!

    static let secureEnclaveLine = "Protected by this Mac's Secure Enclave. Using a key needs your approval with Touch ID or your password."
    static let recoveryLine = "Protected by this Mac's Secure Enclave, with a copy of its key in your login keychain so updates keep working. "
        + "Using a key needs your approval with Touch ID or your password."
    static let lessProtectedLine = "Less protected: this Mac has no Secure Enclave. Next Term asks for Touch ID or your password, but the key "
        + "that opens Secrets is in your login keychain."
    static let cantOpenLine = "These keys were saved on another Mac, or this Mac's Secure Enclave was reset, so they can't be opened here."
    static let tamperedLine = "Secrets' file was changed outside Next Term, so no key is released. Start Over, or restore the file from a backup."
    static let agentControlLine = "Agents and MCP servers can't use these keys while “Let agents control Next Term” is off "
        + "(Settings › Editor › Agents)."
    static let writeOnlyLine = "Write-only: Next Term never shows this key again. Replace it to change it."
    static let emptyLine = "No keys yet. Add one, or move keys out of your MCP configs."
    static let footer = "A command you allow gets the key and can send it anywhere. While it runs, other programs and agents running as "
        + "you can read it. Masking hides stored keys in what agents read through Next Term, but not keys under 12 characters or keys a "
        + "program changes before printing. Write-only means Next Term never shows a key again."
    static let revokeHelp = "Stops new starts. A server already running keeps the key until it quits."

    private let content = NSStackView()
    private(set) var statusLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var startOverButton = NSButton(title: "Start Over…", target: nil, action: nil)
    private(set) var agentControlLabel = NSTextField(wrappingLabelWithString: SecretsView.agentControlLine)
    private(set) var table = NSTableView()
    private let tableScroll = NSScrollView()
    private(set) var emptyLabel = NSTextField(wrappingLabelWithString: SecretsView.emptyLine)
    private(set) var writeOnlyLabel = NSTextField(wrappingLabelWithString: SecretsView.writeOnlyLine)
    private(set) var actionLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var addButton = NSButton(title: "Add…", target: nil, action: nil)
    private(set) var editButton = NSButton(title: "Edit…", target: nil, action: nil)
    private(set) var replaceButton = NSButton(title: "Replace…", target: nil, action: nil)
    private(set) var deleteButton = NSButton(title: "Delete…", target: nil, action: nil)
    private(set) var revealButton = NSButton(title: "Reveal", target: nil, action: nil)
    private(set) var copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private(set) var writeOnlyButton = NSButton(title: "Make Write-Only…", target: nil, action: nil)
    private(set) var importButton = NSButton(title: "Import from MCP Configs…", target: nil, action: nil)
    private let allowedBox = NSStackView()
    private(set) var allowedRows: [(grant: SecretGrant, revoke: NSButton)] = []
    private(set) var revokeAllButton = NSButton(title: "Revoke All", target: nil, action: nil)
    private let pausedBox = NSStackView()
    private(set) var pausedRows: [(text: String, resume: NSButton)] = []
    /// Recent imports (U8 fills it).
    let importsBox = NSStackView()
    private var resumeActions: [ObjectIdentifier: () -> Void] = [:]

    private(set) var entries: [SecretVault.Entry] = []
    /// The confirm on screen (Make Write-Only…, Delete…, Start Over…), for the self-test.
    private(set) var alert: NSAlert?
    private(set) var sheet: SecretEditSheet?
    private(set) var revealPopover: NSPopover?
    private(set) var revealField: NSTextField?
    private var timer: Timer?
    private var lockObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: SecretsStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: SecretRequests.changed, object: nil)
        lockObserver = NotificationCenter.default.addObserver(forName: SecretsStore.locked, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeReveal() }
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let lockObserver { NotificationCenter.default.removeObserver(lockObserver) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return closeReveal() } // Settings closed: a revealed key goes with it
        // Time left on approvals, once a minute.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        SecretsStore.shared.reloadIfChanged()
        reload()
    }

    // MARK: layout

    private func build() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = SecretsFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        addSubview(scroll)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        statusLabel.font = .systemFont(ofSize: 12)
        startOverButton.target = self
        startOverButton.action = #selector(startOver)
        startOverButton.bezelStyle = .rounded
        agentControlLabel.font = .systemFont(ofSize: 12)
        agentControlLabel.textColor = .systemOrange
        buildTable()
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        writeOnlyLabel.font = .systemFont(ofSize: 12)
        writeOnlyLabel.textColor = .secondaryLabelColor
        actionLabel.font = .systemFont(ofSize: 12)
        actionLabel.isHidden = true
        let keyActions: [(NSButton, Selector)] = [(addButton, #selector(add)), (editButton, #selector(edit)), (replaceButton, #selector(replace)),
                                                  (deleteButton, #selector(deleteKey)), (revealButton, #selector(reveal)),
                                                  (copyButton, #selector(copyKey)), (writeOnlyButton, #selector(makeWriteOnly)),
                                                  (importButton, #selector(importKeys)), (revokeAllButton, #selector(revokeAll))]
        for (button, action) in keyActions {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        importButton.isEnabled = false // U8: the import assistant
        let keyButtons = NSStackView(views: [addButton, editButton, replaceButton, deleteButton])
        keyButtons.spacing = 8
        let valueButtons = NSStackView(views: [revealButton, copyButton, writeOnlyButton, NSView(), importButton])
        valueButtons.spacing = 8
        for box in [allowedBox, pausedBox, importsBox] {
            box.orientation = .vertical
            box.alignment = .leading
            box.spacing = 6
        }
        let footer = SecretApprovalPanel.label(Self.footer, size: 11)
        footer.textColor = .secondaryLabelColor
        let docs = NSButton(title: "What Secrets protects, and what it doesn't", target: self, action: #selector(openDocs))
        docs.bezelStyle = .inline
        let rows: [NSView] = [statusLabel, startOverButton, agentControlLabel, tableScroll, emptyLabel, writeOnlyLabel, keyButtons,
                              valueButtons, actionLabel, allowedBox, importsBox, pausedBox, footer, docs]
        for row in rows { content.addArrangedSubview(row) }
        for row in [statusLabel, agentControlLabel, tableScroll, emptyLabel, writeOnlyLabel, keyButtons, valueButtons, actionLabel,
                    allowedBox, importsBox, pausedBox, footer] {
            row.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32).isActive = true
        }
        // At least six rows high.
        tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 6 * 24 + 28).isActive = true
    }

    private func buildTable() {
        let columns: [(String, String, CGFloat)] = [("name", "Name", 160), ("purpose", "What it's for", 190), ("writeOnly", "Write-only", 80),
                                                    ("used", "Last used", 150)]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.target = self
        table.doubleAction = #selector(edit)
        table.setAccessibilityLabel("Stored keys")
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder
    }

    // MARK: data

    @objc func reload() {
        let store = SecretsStore.shared
        entries = store.index?.entries ?? []
        let selected = selectedEntry?.name
        table.reloadData()
        if let selected, let row = entries.firstIndex(where: { $0.name == selected }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        statusLabel.stringValue = Self.statusText(store.protection, waitingForKeychain: store.isWaitingForKeychain)
        let broken = store.protection == .cantOpen || store.protection == .tampered
        statusLabel.textColor = broken ? .systemOrange : .labelColor
        statusLabel.setAccessibilityLabel(broken ? "Warning: \(statusLabel.stringValue)" : nil)
        startOverButton.isHidden = !broken
        agentControlLabel.isHidden = entries.isEmpty || Self.agentControlIsOn()
        emptyLabel.isHidden = !entries.isEmpty || broken
        addButton.isEnabled = !broken
        refreshButtons()
        reloadAllowed()
        reloadPaused()
    }

    static func statusText(_ protection: SecretsStore.Protection, waitingForKeychain: Bool) -> String {
        let line: String
        switch protection {
        case .none: line = SecureEnclaveKeyring.isAvailable ? secureEnclaveLine : lessProtectedLine
        case .secureEnclave: line = secureEnclaveLine
        case .secureEnclaveWithRecovery: line = recoveryLine
        case .lessProtected: line = lessProtectedLine
        case .cantOpen: line = cantOpenLine
        case .tampered: line = tamperedLine
        }
        return waitingForKeychain ? line + " Waiting for the keychain…" : line
    }

    var selectedEntry: SecretVault.Entry? {
        entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil
    }

    /// Selects the key named `name`, as a click would.
    func select(_ name: String) {
        guard let row = entries.firstIndex(where: { $0.name == name }) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        refreshButtons()
    }

    private func refreshButtons() {
        let store = SecretsStore.shared
        let usable = store.protection != .cantOpen && store.protection != .tampered
        let entry = selectedEntry
        let shown = entry.map { !$0.writeOnly } ?? false
        for button in [editButton, replaceButton, deleteButton] { button.isEnabled = usable && entry != nil }
        for button in [revealButton, copyButton, writeOnlyButton] { button.isEnabled = usable && shown }
        writeOnlyLabel.isHidden = entry?.writeOnly != true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let cell = NSTextField(labelWithString: "")
        cell.lineBreakMode = .byTruncatingTail
        switch tableColumn?.identifier.rawValue {
        case "name":
            cell.stringValue = entry.name
            cell.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        case "purpose":
            cell.stringValue = entry.purpose + (entry.purposeBy == .agent ? " (an agent wrote this)" : "")
            cell.toolTip = cell.stringValue
        case "writeOnly":
            cell.stringValue = entry.writeOnly ? "Write-only" : ""
            cell.textColor = .secondaryLabelColor
            if entry.writeOnly { cell.setAccessibilityLabel("Write-only") }
        default:
            cell.stringValue = SecretsStore.shared.lastUse[entry.name].map(Self.lastUsedText) ?? "Never used"
            cell.textColor = .secondaryLabelColor
        }
        return cell
    }

    /// "5 min ago by Claude Code in “api”".
    static func lastUsedText(_ line: SecretAudit.Line) -> String {
        let text = SecretApprovalPanel.lastUsedText(line)
        guard let folder = line.folder, !folder.isEmpty else { return text }
        return text + " in “\((folder as NSString).lastPathComponent)”"
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshButtons()
        actionLabel.isHidden = true
    }

    /// The right-click menu: the row's commands.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard entries.indices.contains(row) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        refreshButtons()
        for button in [editButton, replaceButton, revealButton, copyButton, writeOnlyButton, deleteButton] {
            let item = NSMenuItem(title: button.title, action: button.action, keyEquivalent: "")
            item.target = self
            item.isEnabled = button.isEnabled
            menu.addItem(item)
        }
    }

    // MARK: approvals and pauses

    private func reloadAllowed() {
        for view in allowedBox.arrangedSubviews { view.removeFromSuperview() }
        allowedRows = []
        let grants = SecretRequests.shared.grants
        allowedBox.isHidden = grants.isEmpty
        guard !grants.isEmpty else { return }
        allowedBox.addArrangedSubview(Self.heading("Allowed now"))
        for grant in grants {
            let revoke = NSButton(title: "Revoke", target: self, action: #selector(revokeOne(_:)))
            revoke.bezelStyle = .rounded
            revoke.identifier = NSUserInterfaceItemIdentifier(grant.id)
            let text = SecretApprovalPanel.label(Self.grantText(grant), size: 12)
            text.preferredMaxLayoutWidth = 420
            let row = NSStackView(views: [text, NSView(), revoke])
            row.spacing = 8
            allowedBox.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: allowedBox.widthAnchor).isActive = true
            allowedRows.append((grant, revoke))
        }
        let help = SecretApprovalPanel.label(Self.revokeHelp, size: 11)
        help.textColor = .secondaryLabelColor
        let bottom = NSStackView(views: [help, NSView(), revokeAllButton])
        bottom.spacing = 8
        allowedBox.addArrangedSubview(bottom)
        bottom.widthAnchor.constraint(equalTo: allowedBox.widthAnchor).isActive = true
    }

    /// "Codex: GITHUB_TOKEN for npx -y … in api, 12 min".
    static func grantText(_ grant: SecretGrant, now: ContinuousClock.Instant = .now) -> String {
        let binding = grant.binding
        let who = binding.program.isEmpty ? "A command" : AgentName.of(program: binding.program)
        let command = SecretApprovalPanel.sanitized(binding.command.joined(separator: " "), limit: 80)
        let folder = (binding.folder as NSString).lastPathComponent
        let left: String
        if let expires = grant.expires {
            let seconds = max(0, SecretRequests.seconds(expires - now))
            left = "\(max(1, Int((seconds / 60).rounded(.up)))) min"
        } else {
            left = "until the Mac locks"
        }
        return "\(who): \(SecretRun.keysText(binding.names)) for \(command) in “\(folder)”, \(left)"
    }

    private func reloadPaused() {
        for view in pausedBox.arrangedSubviews { view.removeFromSuperview() }
        pausedRows = []
        resumeActions = [:]
        let requests = SecretRequests.shared
        let limits = requests.limits
        var rows: [(String, () -> Void)] = []
        if let until = requests.pausedUntil {
            rows.append(("Pausing key requests until \(SecretRequests.clockText(until)).", { requests.resumeAsking() }))
        }
        for (binding, pause) in limits.activePauses(at: requests.now()) {
            let command = SecretApprovalPanel.sanitized(binding.command.joined(separator: " "), limit: 80)
            rows.append(("\(SecretRun.keysText(binding.names)) for \(command): you declined it, so it is paused until "
                         + "\(SecretRequests.clockText(pause.untilDate)).", { requests.resume(binding) }))
        }
        for asker in limits.stopped.sorted() {
            rows.append(("\(Self.askerText(asker)): you chose Decline and Stop Asking.", { requests.resume(asker: asker) }))
        }
        for asker in limits.limitedAskers where !limits.stopped.contains(asker) {
            rows.append(("\(Self.askerText(asker)): asked too often this session.", { requests.resume(asker: asker) }))
        }
        pausedBox.isHidden = rows.isEmpty
        guard !rows.isEmpty else { return }
        pausedBox.addArrangedSubview(Self.heading("Paused"))
        for (index, (text, action)) in rows.enumerated() {
            let title = index == 0 && requests.pausedUntil != nil ? "Resume Asking" : "Resume"
            let button = NSButton(title: title, target: self, action: #selector(resume(_:)))
            button.bezelStyle = .rounded
            resumeActions[ObjectIdentifier(button)] = action
            let label = SecretApprovalPanel.label(text, size: 12)
            label.preferredMaxLayoutWidth = 420
            let row = NSStackView(views: [label, NSView(), button])
            row.spacing = 8
            pausedBox.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: pausedBox.widthAnchor).isActive = true
            pausedRows.append((text, button))
        }
    }

    /// Who an asker is, in words.
    static func askerText(_ asker: String) -> String {
        if asker == "outside" { return "Agents outside Next Term's tabs" }
        if asker.hasPrefix("remote") { return "A remote connection" }
        if asker.hasPrefix("wrapper:") {
            let path = asker.dropFirst("wrapper:".count).split(separator: ":").first.map(String.init) ?? "none"
            return path == "none" ? "nxtrm secret run, with no agent above it" : "nxtrm secret run under \((path as NSString).lastPathComponent)"
        }
        if let tab = AppDelegate.shared.controllers.flatMap(\.tabs).first(where: { $0.id.uuidString == asker }) {
            return "The agent in the tab “\(SecretApprovalPanel.sanitized(tab.title, limit: 60))”"
        }
        return "An agent in a tab that has closed"
    }

    private static func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    @objc private func revokeOne(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        SecretRequests.shared.revoke(id)
    }

    @objc private func revokeAll() { SecretRequests.shared.revokeAll() }

    @objc private func resume(_ sender: NSButton) { resumeActions[ObjectIdentifier(sender)]?() }

    // MARK: key actions

    @objc func add() { openSheet(.add) }

    @objc func edit() {
        guard let entry = selectedEntry else { return }
        openSheet(.edit(entry))
    }

    @objc func replace() {
        guard let entry = selectedEntry else { return }
        openSheet(.replace(entry))
    }

    private func openSheet(_ mode: SecretEditSheet.Mode) {
        guard sheet == nil, let window else { return }
        let opened = SecretEditSheet(mode) { [weak self] saved in
            guard let self else { return }
            self.sheet = nil
            if let saved, !saved.isEmpty { self.say(saved) }
            self.reload()
        }
        sheet = opened
        opened.begin(on: window)
    }

    @objc func reveal() {
        guard let entry = selectedEntry, !entry.writeOnly else { return }
        run(.reveal(name: entry.name)) { [weak self] values in
            guard let self, let value = values[entry.name] else { return }
            self.showReveal(value, for: entry.name)
        }
    }

    @objc func copyKey() {
        guard let entry = selectedEntry, !entry.writeOnly else { return }
        run(.copy(name: entry.name)) { [weak self] values in
            guard let self, let value = values[entry.name] else { return }
            if SecretClipboard.shared.copy(value) { self.say(SecretClipboard.copiedLine) }
        }
    }

    @objc func makeWriteOnly() {
        guard let entry = selectedEntry, !entry.writeOnly else { return }
        let alert = NSAlert()
        alert.messageText = "Make \(entry.name) write-only?"
        alert.informativeText = "You can't show or copy it again. To change it, replace it with a new value."
        alert.addButton(withTitle: "Make Write-Only")
        alert.addButton(withTitle: "Cancel")
        confirm(alert) { [weak self] in self?.run(.makeWriteOnly(name: entry.name)) { _ in } }
    }

    @objc func deleteKey() {
        guard let entry = selectedEntry else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(entry.name)?"
        alert.informativeText = "Commands and MCP servers that use it will stop getting it. A server already running keeps it until it quits."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        confirm(alert) { [weak self] in self?.run(.delete(name: entry.name)) { _ in } }
    }

    @objc func startOver() {
        let folder = SecretsStore.shared.folder.url
        let parent = folder.deletingLastPathComponent()
        let name = SecretFolder.oldName(day: SecretFolder.day(of: Date())) { taken in
            FileManager.default.fileExists(atPath: parent.appendingPathComponent(taken).path)
        }
        let alert = NSAlert()
        alert.messageText = "Start over with an empty Secrets?"
        alert.informativeText = "Next Term keeps the old folder as \(name). MCP servers that use these keys won't start until you add them again."
        alert.addButton(withTitle: "Start Over")
        alert.addButton(withTitle: "Cancel")
        confirm(alert) { [weak self] in
            do {
                try SecretsStore.shared.startOver()
            } catch {
                self?.say((error as? LocalizedError)?.errorDescription ?? "Next Term couldn’t start over.")
            }
        }
    }

    @objc func importKeys() {}

    @objc private func openDocs() { NSWorkspace.shared.open(Self.docsURL) }

    /// The confirm, as a sheet; `then` runs on its first button.
    private func confirm(_ alert: NSAlert, then: @escaping () -> Void) {
        guard self.alert == nil, let window else { return }
        self.alert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.alert = nil
                if response == .alertFirstButtonReturn { then() }
            }
        }
    }

    /// One presence check, then the action; "Not approved." when it was cancelled.
    private func run(_ action: SecretsStore.Action, then: @escaping ([String: SecretBytes]) -> Void) {
        Task { @MainActor in
            do {
                let values = try await SecretsStore.shared.perform(action, facts: SecretsStore.Facts(who: "you, in Settings › Secrets"))
                then(values)
            } catch SecretsStore.Failure.cancelled {
                self.say("Not approved.")
            } catch {
                self.say((error as? LocalizedError)?.errorDescription ?? "Next Term couldn’t do that.")
            }
            self.reload()
        }
    }

    func say(_ text: String) {
        actionLabel.stringValue = text
        actionLabel.isHidden = text.isEmpty
        guard !text.isEmpty, let window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: Reveal

    /// The value in a popover by its row, in a window kept out of screen sharing and screenshots. It stays until it is
    /// closed, the Mac locks, or Settings closes.
    private func showReveal(_ value: SecretBytes, for name: String) {
        closeReveal()
        let field = NSTextField(labelWithString: value.utf8String() ?? "")
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.isSelectable = true
        field.lineBreakMode = .byCharWrapping
        field.preferredMaxLayoutWidth = 360
        field.setAccessibilityLabel("The value of \(name)")
        let close = NSButton(title: "Close", target: self, action: #selector(hideReveal))
        close.bezelStyle = .rounded
        let stack = NSStackView(views: [field, close])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        let controller = NSViewController()
        controller.view = stack
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .applicationDefined
        let row = entries.firstIndex { $0.name == name } ?? max(0, table.selectedRow)
        let rect = row < entries.count ? table.rect(ofRow: row) : table.bounds
        popover.show(relativeTo: rect, of: table, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.sharingType = .none
        revealPopover = popover
        revealField = field
    }

    @objc private func hideReveal() { closeReveal() }

    func closeReveal() {
        revealField?.stringValue = ""
        revealField = nil
        revealPopover?.close()
        revealPopover = nil
    }
}

/// A document view whose rows start at the top.
private final class SecretsFlippedView: NSView {
    override var isFlipped: Bool { true }
}
