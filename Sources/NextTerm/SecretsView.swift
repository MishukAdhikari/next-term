import AppKit
import NextTermCore

/// The list of stored keys, shared by Settings › Secrets and Window › Secrets: what guards them, each key with what
/// it's for, its write-only badge and its last use; the key buttons; the approvals in force; what is paused; and the
/// limits, said plainly. Each change asks for Touch ID or the Mac password once.
@MainActor
final class SecretsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    /// Whether "Let agents control Next Term" is on (the self-test sets its own, so the socket stays up).
    static var agentControlIsOn: () -> Bool = { AppDelegate.shared.agentControl }
    /// Where the import looks and what runs now (the self-test points it at a temporary home).
    static var importSetup: () -> SecretImportSheet.Setup = {
        var setup = SecretImportSheet.Setup()
        var seen = Set<String>()
        setup.projects = AppDelegate.shared.controllers.compactMap(\.project).filter { seen.insert($0).inserted }
        setup.agentControl = SecretsView.agentControlIsOn()
        setup.isOpen = { SecretsView.isRunning($0) }
        setup.nxtrm = SecretImportSheet.nxtrmCommand()
        return setup
    }

    /// Whether the app with this bundle identifier runs now: asked each time, on any thread.
    nonisolated static func isRunning(_ bundle: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
    }
    static let docsURL = URL(string: "https://nxtrm.mishuk.me/docs/secrets/")!

    static let secureEnclaveLine = "Protected by this Mac's Secure Enclave. Using a key needs your approval with Touch ID or your password."
    static let recoveryLine = "Protected by this Mac's Secure Enclave, with a copy of its key in your login keychain so updates keep working. "
        + "Using a key needs your approval with Touch ID or your password."
    static let lessProtectedLine = "Less protected: this Mac has no Secure Enclave. Next Term asks for Touch ID or your password, but the key "
        + "that opens Secrets is in your login keychain."
    static let cantOpenLine = "These keys were saved on another Mac, or this Mac's Secure Enclave was reset, so they can't be opened here."
    static let tamperedLine = "Secrets' file was changed outside Next Term, so no key is released. Start Over, or restore the file from a backup."
    static let tooLargeLine = "Secrets’ file is larger than Next Term can read (8 MB), so no key is released. Start Over, or restore an "
        + "older copy of the file from a backup."
    static let unlistedLine = "Next Term's list of the vaults it made on this Mac is missing from the login keychain, so it can't tell these "
        + "keys are its own, and no key is released. Start Over to make a new vault."
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
    /// Recent imports.
    let importsBox = NSStackView()
    private var resumeActions: [ObjectIdentifier: () -> Void] = [:]

    private(set) var entries: [SecretVault.Entry] = []
    /// The confirm on screen (Make Write-Only…, Delete…, Start Over…), for the self-test.
    private(set) var alert: NSAlert?
    private(set) var sheet: SecretEditSheet?
    private(set) var revealPopover: NSPopover?
    private(set) var revealField: NSTextField?
    private(set) var importSheet: SecretImportSheet?
    /// Recent imports, by batch, with their Undo buttons.
    private(set) var importRows: [(batch: String, backups: [SecretImport.EntryBackup], undo: NSButton)] = []
    /// The checkbox in Undo's confirm: also delete the keys from Secrets.
    private(set) var undoDeleteBox: NSButton?
    private var timer: Timer?
    /// The Mac locking and Next Term hiding end Reveal.
    private var endObservers: [NSObjectProtocol] = []
    /// Watch the window this view is in, whichever it is, for its close and its minimizing.
    private var windowObservers: [NSObjectProtocol] = []
    /// A Reveal still asking for Touch ID.
    private var revealTask: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: SecretsStore.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: SecretRequests.changed, object: nil)
        for name in [SecretsStore.locked, NSApplication.willHideNotification] {
            endObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.endReveal() }
            })
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        for observer in endObservers + windowObservers { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        watchWindow()
        guard window != nil else { return endReveal() } // another Settings tab: a revealed key, and one asked for, go with it
        // Time left on approvals, once a minute.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        SecretsStore.shared.reloadIfChanged()
        reload()
    }

    /// Closing a window leaves its content view in it, so Settings closing (⌘W) would leave a revealed key behind: the
    /// window's close ends Reveal, whichever window holds this view. So does its minimizing, so a Touch ID up for
    /// Reveal can't be approved for a value nobody would see, and a value shown doesn't come back with the window.
    private func watchWindow() {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = []
        guard let window else { return }
        for name in [NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.endReveal() }
            })
        }
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
        // The selected key, by its id, before the list changes: its row may hold another key after a delete elsewhere,
        // and a rename keeps the id, not the name.
        let selected = selectedEntry?.id
        entries = store.index?.entries ?? []
        table.reloadData()
        if let row = store.index?.row(of: selected) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        statusLabel.stringValue = Self.statusText(store.protection, waitingForKeychain: store.isWaitingForKeychain,
                                                  unlisted: store.isUnlisted, tooLarge: store.isTooLarge)
        let broken = store.protection == .cantOpen || store.protection == .tampered
        statusLabel.textColor = broken ? .systemOrange : .labelColor
        statusLabel.setAccessibilityLabel(broken ? "Warning: \(statusLabel.stringValue)" : nil)
        startOverButton.isHidden = !broken
        agentControlLabel.isHidden = entries.isEmpty || Self.agentControlIsOn()
        emptyLabel.isHidden = !entries.isEmpty || broken
        addButton.isEnabled = !broken
        importButton.isEnabled = !broken
        refreshButtons()
        reloadAllowed()
        reloadImports()
        reloadPaused()
    }

    /// `unlisted`: a refused vault is one this Mac has no record of, not one whose file changed. `tooLarge`: its file is
    /// past the read cap.
    static func statusText(_ protection: SecretsStore.Protection, waitingForKeychain: Bool, unlisted: Bool = false,
                           tooLarge: Bool = false) -> String {
        let line: String
        switch protection {
        case .none: line = SecureEnclaveKeyring.isAvailable ? secureEnclaveLine : lessProtectedLine
        case .secureEnclave: line = secureEnclaveLine
        case .secureEnclaveWithRecovery: line = recoveryLine
        case .lessProtected: line = lessProtectedLine
        case .cantOpen: line = cantOpenLine
        case .tampered: line = tooLarge ? tooLargeLine : unlisted ? unlistedLine : tamperedLine
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

    /// The Touch ID it asks for ends with Reveal (`endReveal`), and an approval that comes after that shows nothing:
    /// the value is dropped, its bytes wiped.
    @objc func reveal() {
        guard let entry = selectedEntry, !entry.writeOnly else { return }
        revealTask?.cancel() // the newer Reveal asks instead
        revealTask = run(.reveal(name: entry.name)) { [weak self] values in
            guard let self, !Task.isCancelled, let value = values[entry.name] else { return }
            self.revealTask = nil
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

    @objc func importKeys() {
        guard importSheet == nil, let window else { return }
        let sheet = SecretImportSheet(Self.importSetup()) { [weak self] in
            guard let self else { return }
            if self.importSheet?.window?.sheetParent == nil { self.importSheet = nil }
            self.reload()
        }
        importSheet = sheet
        sheet.begin(on: window)
    }

    // MARK: Recent imports

    private func reloadImports() {
        for view in importsBox.arrangedSubviews { view.removeFromSuperview() }
        importRows = []
        let backups = SecretsStore.shared.recentBackups()
        importsBox.isHidden = backups.isEmpty
        guard !backups.isEmpty else { return }
        importsBox.addArrangedSubview(Self.heading("Recent imports"))
        var batches: [String] = []
        for backup in backups where !batches.contains(backup.batch) { batches.append(backup.batch) }
        for batch in batches {
            let entries = backups.filter { $0.batch == batch }
            let undo = NSButton(title: "Undo…", target: self, action: #selector(undoImport(_:)))
            undo.bezelStyle = .rounded
            undo.identifier = NSUserInterfaceItemIdentifier(batch)
            let label = SecretApprovalPanel.label(Self.importText(entries), size: 12)
            label.preferredMaxLayoutWidth = 420
            let row = NSStackView(views: [label, NSView(), undo])
            row.spacing = 8
            importsBox.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: importsBox.widthAnchor).isActive = true
            importRows.append((batch, entries, undo))
        }
    }

    /// "9 Oct: GITHUB_TOKEN from 3 entries in 2 files".
    static func importText(_ entries: [SecretImport.EntryBackup]) -> String {
        let names = Array(Set(entries.flatMap(\.names))).sorted()
        let files = Set(entries.map(\.path)).count
        let day = entries.first.map { SecretRequests.dayText($0.date) } ?? ""
        return "\(day): \(SecretRun.keysText(names)) from \(entries.count) \(entries.count == 1 ? "entry" : "entries") in \(files) "
            + (files == 1 ? "file" : "files")
    }

    @objc func undoImport(_ sender: NSButton) {
        guard let batch = sender.identifier?.rawValue, let row = importRows.first(where: { $0.batch == batch }), self.alert == nil,
              let window else { return }
        let names = Array(Set(row.backups.flatMap(\.names))).sorted()
        let alert = NSAlert()
        alert.messageText = "Put \(names.count) \(names.count == 1 ? "key" : "keys") back into these files as plain text?"
        alert.informativeText = Set(row.backups.map(\.path)).sorted().map { "• " + SecretImportSheet.file($0) }.joined(separator: "\n")
        alert.addButton(withTitle: "Put Back")
        alert.addButton(withTitle: "Cancel")
        let box = NSButton(checkboxWithTitle: "Also delete these keys from Secrets", target: nil, action: nil)
        box.state = .off
        alert.accessoryView = box
        undoDeleteBox = box
        self.alert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.alert = nil
                let delete = box.state == .on
                self.undoDeleteBox = nil
                if response == .alertFirstButtonReturn { self.putBack(row.backups, names: names, delete: delete) }
            }
        }
    }

    /// One Touch ID, then each entry put back while it is what Next Term wrote; the backups that went back are removed.
    /// An entry that holds a write-only key is left: Next Term never shows that key again, in a file either.
    func putBack(_ backups: [SecretImport.EntryBackup], names: [String], delete: Bool) {
        let importSetup = Self.importSetup()
        let isOpen = importSetup.isOpen
        let lockWait = importSetup.lockWait
        let home = importSetup.home
        let writeOnly = Set(names.filter { SecretsStore.shared.index?.entry(named: $0)?.writeOnly == true })
        let held = backups.filter { !$0.names.contains(where: writeOnly.contains) }
        let refusals = backups.filter { $0.names.contains(where: writeOnly.contains) }.map { backup -> String in
            let name = backup.names.first(where: writeOnly.contains) ?? ""
            return "\(name) is write-only: Next Term never shows it again, so it left the “\(backup.location.server)” entry in "
                + "\(SecretImportSheet.file(backup.path)) as it is."
        }
        guard !held.isEmpty else { return say(refusals.joined(separator: " ")) }
        let asked = Array(Set(held.flatMap(\.names))).sorted()
        // Only keys these moves stored themselves are deleted, and none that entries this Undo doesn't put back still
        // name: another import's in the list, or one of this import's left wrapped for its write-only key.
        let ids = Set(held.map(\.id))
        let others: [SecretImport.EntryBackup] = importRows.flatMap { $0.backups }.filter { !ids.contains($0.id) }
        let undoKeys = SecretImport.UndoKeys(undoing: held, others: others)
        let deletable = undoKeys.deletable
        var kept: [String: Data] = [:]
        for backup in held { if let box = backup.keptBox { kept[backup.id] = box } }
        let outcome = UndoOutcome()
        Task { @MainActor in
            do {
                try await SecretsStore.shared.performUndo(names: asked, kept: kept, delete: delete, reason: SecretReason.putBack(asked.count)) { values, opened in
                    var back = Set(asked)
                    for backup in held {
                        let result = SecretImport.undo(backup, values: values, kept: opened[backup.id] ?? [], home: home, lockWait: lockWait,
                                                       isOpen: isOpen)
                        outcome.add(backup, result)
                        if result != .written { back.subtract(backup.names) }
                    }
                    return back.intersection(deletable)
                }
                for (backup, result) in outcome.results where result == .written { SecretsStore.shared.removeBackup(backup) }
                let left = refusals + outcome.results.compactMap { pair -> String? in
                    if case .skipped(let reason) = pair.1 { return reason }
                    return pair.1 == .written ? nil : SecretImportSheet.text(pair.1)
                }
                let back = outcome.results.filter { $0.1 == .written }.count
                var said = left.isEmpty ? "Put \(back) \(back == 1 ? "entry" : "entries") back." : left.joined(separator: " ")
                // Asked to delete the keys: the ones it kept, and why.
                let notBack = Set(outcome.results.filter { $0.1 != .written }.flatMap { $0.0.names })
                let wentBack = Set(asked).subtracting(notBack)
                if delete, let keptText = undoKeys.keptText(wentBack) { said += " " + keptText }
                self.say(said)
            } catch SecretsStore.Failure.cancelled {
                self.say("Not approved.")
            } catch {
                self.say((error as? LocalizedError)?.errorDescription ?? "Next Term couldn’t put the keys back.")
            }
            self.reload()
        }
    }

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

    /// One presence check, then the action; "Not approved." when the user, or macOS, cancelled it. A check this view
    /// cancelled itself (Reveal's end) says nothing: nobody said no.
    @discardableResult
    private func run(_ action: SecretsStore.Action, then: @escaping ([String: SecretBytes]) -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            do {
                let values = try await SecretsStore.shared.perform(action, facts: SecretsStore.Facts(who: "you, in Settings › Secrets"))
                then(values)
            } catch SecretsStore.Failure.cancelled {
                if !Task.isCancelled { self.say("Not approved.") }
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
    /// closed, the Mac locks, Next Term hides, or its window closes, minimizes or loses this view. It can't be selected:
    /// Copy, which marks the pasteboard for this Mac only and clears it, is the one way a value reaches the pasteboard.
    private func showReveal(_ value: SecretBytes, for name: String) {
        closeReveal()
        // Only by its row, on screen: never by a table in a closed window or in none.
        guard let window, window.isVisible, table.window === window else { return }
        let field = NSTextField(labelWithString: value.utf8String() ?? "")
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.isSelectable = false
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

    /// Reveal ends with the view: its window closing or minimizing, another Settings tab, the Mac locking, Next Term
    /// hiding. The value on screen is wiped and goes, and a Touch ID still up for one is cancelled.
    func endReveal() {
        revealTask?.cancel()
        revealTask = nil
        closeReveal()
    }

    func closeReveal() {
        revealField?.stringValue = ""
        revealField = nil
        revealPopover?.close()
        revealPopover = nil
    }
}

/// What an Undo did to each entry, filled on the store's queue while the view waits.
final class UndoOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [(SecretImport.EntryBackup, SecretImport.Applied)] = []

    func add(_ backup: SecretImport.EntryBackup, _ result: SecretImport.Applied) {
        lock.lock()
        list.append((backup, result))
        lock.unlock()
    }

    var results: [(SecretImport.EntryBackup, SecretImport.Applied)] {
        lock.lock()
        defer { lock.unlock() }
        return list
    }
}

/// A document view whose rows start at the top.
private final class SecretsFlippedView: NSView {
    override var isFlipped: Bool { true }
}
