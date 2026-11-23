import AppKit
import NextTermCore

/// Settings › Remote Access's connections (R15, R22, R60): each one's name, its client (claude.ai or chatgpt.com),
/// the preset its options carry the name of, when it was last used and when it ends, with Edit… and Revoke; and
/// Revoke All below. A Control connection carries the Control mark, as in the status item, so it is easy to find and
/// revoke. Revoke ends a connection at once and answers its open calls (R38).
@MainActor
final class RemoteAccessConnectionsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let width: CGFloat = 548
    static let rowHeight: CGFloat = 26
    static let tableHeight: CGFloat = 150

    let table = NSTableView()
    let revokeAllButton = NSButton(title: "Revoke All", target: nil, action: nil)
    let emptyLabel = NSTextField(wrappingLabelWithString: RemoteAccessSettingsText.noConnections)
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    /// The rows shown.
    private(set) var rows: [RemoteAccessConnectionRow] = []
    /// Edit… while its sheet is open.
    private(set) var editing: RemoteAccessEditSheet?
    private let scroll = NSScrollView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        let columns: [(String, String, CGFloat)] = [
            ("name", "Name", 100), ("client", "Client", 82), ("preset", "What it may do", 96),
            ("used", "Last used", 74), ("ends", "Ends", 66), ("actions", "", 112),
        ]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "name" ? 80 : width
            column.resizingMask = id == "name" ? .autoresizingMask : []
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = Self.rowHeight
        table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = true
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Connections")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        for label in [emptyLabel, messageLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = Self.width
        }
        messageLabel.isHidden = true
        revokeAllButton.target = self
        revokeAllButton.action = #selector(revokeAll)
        revokeAllButton.bezelStyle = .rounded
        revokeAllButton.toolTip = "Ends every connection now. Each client connects again only after you allow it here."
        let buttons = NSStackView(views: [revokeAllButton, NSView()])

        let stack = NSStackView(views: [emptyLabel, scroll, buttons, messageLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
            scroll.widthAnchor.constraint(equalToConstant: Self.width),
            scroll.heightAnchor.constraint(equalToConstant: Self.tableHeight),
            buttons.widthAnchor.constraint(equalToConstant: Self.width),
            emptyLabel.widthAnchor.constraint(equalToConstant: Self.width),
            messageLabel.widthAnchor.constraint(equalToConstant: Self.width),
        ])
    }

    /// Shows `rows`; with none, says how to add one.
    func show(_ rows: [RemoteAccessConnectionRow]) {
        self.rows = rows
        table.reloadData()
        scroll.isHidden = rows.isEmpty
        emptyLabel.isHidden = !rows.isEmpty
        revokeAllButton.isEnabled = !rows.isEmpty
    }

    private func say(_ text: String?) {
        messageLabel.stringValue = text ?? ""
        messageLabel.textColor = .systemRed
        messageLabel.isHidden = text == nil
    }

    // MARK: actions, as a click makes them

    /// Edit… on a row: the options view in a sheet, set to that connection's options.
    func edit(row index: Int) {
        guard rows.indices.contains(index), editing == nil else { return }
        say(nil)
        let sheet = RemoteAccessEditSheet(row: rows[index])
        editing = sheet
        sheet.onClose = { [weak self] in self?.editing = nil }
        sheet.present(on: window)
    }

    /// Revoke on a row: the connection ends now.
    func revoke(row index: Int) {
        guard rows.indices.contains(index) else { return }
        say(RemoteAccess.shared.revoke(rows[index].id))
    }

    @objc private func editClicked(_ sender: NSButton) {
        edit(row: sender.tag)
    }

    @objc private func revokeClicked(_ sender: NSButton) {
        revoke(row: sender.tag)
    }

    @objc func revokeAll() {
        say(RemoteAccess.shared.revokeAll())
    }

    // MARK: the table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, rows.indices.contains(row) else { return nil }
        let shown = rows[row]
        switch id {
        case "name": return cell(shown.name, tip: shown.name)
        case "client": return cell(shown.client, tip: clientTip(shown))
        case "preset": return presetCell(shown)
        case "used": return cell(shown.lastUsed)
        case "ends": return cell(shown.expires)
        case "actions": return actionsCell(row: row, name: shown.name)
        default: return nil
        }
    }

    private func clientTip(_ row: RemoteAccessConnectionRow) -> String {
        guard let words = row.clientWords, !words.isEmpty else { return "Goes back to \(row.client)" }
        return "Goes back to \(row.client). It calls itself “\(words)”: its own words, not Next Term's."
    }

    private func cell(_ text: String, tip: String? = nil) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = tip
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return centered(label)
    }

    /// The preset's name, after the Control mark on a Control connection.
    private func presetCell(_ row: RemoteAccessConnectionRow) -> NSView {
        let label = NSTextField(labelWithString: row.presetTitle)
        label.font = .systemFont(ofSize: 12, weight: row.isControl ? .semibold : .regular)
        guard row.isControl else { return centered(label) }
        let mark = NSImageView()
        mark.image = RemoteAccessStatusItem.markImage()
        mark.contentTintColor = .systemOrange
        mark.setAccessibilityLabel("Control mark")
        mark.toolTip = "Control: anything this connection sends can run commands on this Mac without asking."
        let both = NSStackView(views: [mark, label])
        both.spacing = 3
        return centered(both)
    }

    private func actionsCell(row: Int, name: String) -> NSView {
        let edit = NSButton(title: "Edit…", target: self, action: #selector(editClicked(_:)))
        let revoke = NSButton(title: "Revoke", target: self, action: #selector(revokeClicked(_:)))
        for button in [edit, revoke] {
            button.tag = row
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        edit.setAccessibilityLabel("Edit “\(name)”")
        revoke.setAccessibilityLabel("Revoke “\(name)”")
        let both = NSStackView(views: [edit, revoke])
        both.spacing = 4
        return centered(both)
    }

    /// A cell holding `view`, centered in the row's height.
    private func centered(_ view: NSView) -> NSView {
        let cell = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            view.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            view.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// Edit… on a connection (R60, AE21): U8's options view in a sheet, set to the connection's options, with Save and
/// Cancel. R22's sentences show above Save, as they show above Allow at pairing. Save asks for Touch ID or the Mac
/// password, with a reason that names the connection; only then are the new options saved (U4) and given to the
/// authority (U3), from the connection's next call on. Cancel, or a confirmation that fails, changes nothing. Like the
/// pairing window, it has no default button, so a Return meant for something else saves nothing.
@MainActor
final class RemoteAccessEditSheet: NSWindowController {
    #if DEBUG
    /// The sheet while it is open, for the self-test (U12).
    static weak var shown: RemoteAccessEditSheet?
    #endif

    static let width: CGFloat = 520

    let grantID: String
    let name: String
    let optionsView: RemoteAccessOptionsView
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var saveButton: NSButton!
    private(set) var cancelButton: NSButton!
    /// Told once the sheet has closed.
    var onClose: (() -> Void)?

    /// The options the sheet opened with.
    private let started: RemoteAccessOptions
    private let stack = NSStackView()
    private var confirming: RemoteAccessConfirmation.Asking?
    private weak var parent: NSWindow?

    init(row: RemoteAccessConnectionRow) {
        grantID = row.id
        name = row.name
        started = row.options
        optionsView = RemoteAccessOptionsView(options: row.options, showsList: true)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Edit “\(row.name)”"
        super.init(window: panel)
        build(row)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build(_ row: RemoteAccessConnectionRow) {
        guard let content = window?.contentView else { return }
        let inner = Self.width - 36
        let title = NSTextField(wrappingLabelWithString: "What “\(row.name)” may do")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let goes = NSTextField(wrappingLabelWithString: "It goes back to \(row.client). New options apply from its "
            + "next call; a call that runs now finishes under the old ones.")
        goes.font = .systemFont(ofSize: 11)
        goes.textColor = .secondaryLabelColor
        optionsView.onChange = { [weak self] _ in self?.fit() }
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.isHidden = true

        cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        for button in [cancelButton!, saveButton!] {
            button.bezelStyle = .rounded
            button.keyEquivalent = "" // no default button: see the type's comment
        }
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton.refusesFirstResponder = true
        let buttons = NSStackView(views: [NSView(), cancelButton, saveButton])
        buttons.spacing = 8

        let views: [NSView] = [title, goes, optionsView, messageLabel, buttons]
        for view in views { stack.addArrangedSubview(view) }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(14, after: optionsView)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
            buttons.widthAnchor.constraint(equalToConstant: inner),
        ])
        for label in [title, goes, messageLabel] {
            label.preferredMaxLayoutWidth = inner
            label.widthAnchor.constraint(equalToConstant: inner).isActive = true
        }
    }

    /// Shows the sheet on `parent`, or as its own window when there is none.
    func present(on parent: NSWindow?) {
        guard let window else { return }
        #if DEBUG
        Self.shown = self
        #endif
        self.parent = parent
        fit()
        if let parent {
            parent.beginSheet(window)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// The sheet's height follows what shows.
    private func fit() {
        guard let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        window.setContentSize(stack.fittingSize)
    }

    private func say(_ text: String, problem: Bool) {
        messageLabel.stringValue = text
        messageLabel.textColor = problem ? .systemRed : .secondaryLabelColor
        messageLabel.isHidden = text.isEmpty
        fit()
    }

    // MARK: answers

    /// Save: unchanged options just close. Otherwise Touch ID or the password, then the options shown are saved,
    /// if they are still what was confirmed.
    /// The master key was entered for this Save: the next pass goes on to Touch ID.
    private var masterKeyPassed = false

    @objc func save() {
        guard confirming == nil else { return }
        let options = optionsView.options
        guard options != started else { return finish() }
        guard RemoteAccess.shared.connectionOptions(grantID) != nil else {
            return say("That connection ended, so there is nothing to change.", problem: true)
        }
        saveButton.isEnabled = false
        // Widening needs the master key first (owner, 2026-11-23); narrowing needs only Touch ID, as before.
        if options.widens(from: started), !masterKeyPassed {
            say("Enter your master key…", problem: false)
            MasterKeyGate.require("give “\(name)” more access", over: window, presence: false) { [weak self] passed in
                guard let self else { return }
                self.saveButton.isEnabled = true
                guard passed else { return self.say("The master key wasn’t entered, so nothing changed.", problem: true) }
                self.masterKeyPassed = true
                self.save()
            }
            return
        }
        masterKeyPassed = false
        say("Confirm on this Mac…", problem: false)
        let reason = RemoteAccessSettingsText.editReason(name: name)
        confirming = RemoteAccessConfirmation.ask(reason) { [weak self] confirmed in
            self?.confirmed(confirmed, options: options)
        }
    }

    private func confirmed(_ confirmed: Bool, options: RemoteAccessOptions) {
        guard confirming != nil else { return }
        confirming = nil
        saveButton.isEnabled = true
        guard confirmed else {
            return say("Not confirmed, so nothing changed. Click Save to try again.", problem: true)
        }
        // What the user confirmed must still be what shows.
        guard optionsView.options == options else {
            return say("The options changed while you confirmed. Click Save again.", problem: true)
        }
        if let problem = RemoteAccess.shared.changeOptions(of: grantID, to: options) {
            return say(problem, problem: true)
        }
        finish()
    }

    /// Cancel: nothing changes, a confirmation being asked included.
    @objc func cancel() {
        confirming?.cancel()
        confirming = nil
        finish()
    }

    private func finish() {
        guard let window else { return }
        if let parent = window.sheetParent ?? parent, parent.attachedSheet === window {
            parent.endSheet(window)
        }
        window.orderOut(nil)
        onClose?()
        onClose = nil
    }
}
