import AppKit
import NextTermCore

/// `request_secret`'s window (KTD16, U6): an agent asks the user to type or paste a key into Next Term. The agent gets
/// back only the status and the name.
///
/// It is an ordinary window, listed in the Window menu and in the ⌘` cycle (KTD23), but it never takes the keyboard on
/// its own: it opens in front without becoming key, and clicking a field makes it key. It has no default button, even
/// once it is key, so a Return meant for something else never saves. Closing it declines.
@MainActor
final class SecretRequestWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    struct Content {
        /// "Codex asks you to add STRIPE_KEY".
        var title: String
        /// Who asks, as Next Term knows it.
        var askedBy: String
        /// The agent's reason, in its own words.
        var agentWords: String?
        /// The name the agent asked for.
        var name: String
        /// What it's for, prefilled from the agent's reason (cut to 200 characters).
        var purpose: String
    }

    /// What the user filled in.
    struct Form {
        var name: String
        var purpose: String
        /// `agent` until the user edits what it's for.
        var purposeBy: SecretVault.PurposeBy
        var value: SecretBytes
        var writeOnly: Bool
    }

    static let writeOnlyLine = "Next Term never shows or copies this key again. Commands you allow still get it. "
        + "Keep your own copy if you'll need it on another Mac."
    static let shortLine = "Shorter than 12 characters: Next Term can't hide it by value in what agents read."

    private let content: Content
    private let onSave: (Form) -> Void
    private let onDecline: (_ stopAsking: Bool) -> Void

    private(set) var nameField = NSTextField()
    private(set) var purposeField = NSTextField()
    private(set) var valueField = NSSecureTextField()
    private(set) var writeOnlyBox: NSButton!
    private(set) var saveButton: NSButton!
    private(set) var declineButton: NSButton!
    private(set) var stopButton: NSButton!
    private let savedAsLabel = NSTextField(labelWithString: "")
    private let replaceLabel = NSTextField(wrappingLabelWithString: "")
    private let shortLabel = NSTextField(wrappingLabelWithString: SecretRequestWindow.shortLine)
    private(set) var statusLabel = NSTextField(wrappingLabelWithString: "")
    private var purposeEdited = false
    /// The pasteboard's change count at the last paste into the value field.
    private(set) var pastedAt: Int?
    private var answered = false
    private(set) var isBusy = false
    private var menuObserver: NSObjectProtocol?

    init(_ content: Content, onSave: @escaping (Form) -> Void, onDecline: @escaping (_ stopAsking: Bool) -> Void) {
        self.content = content
        self.onSave = onSave
        self.onDecline = onDecline
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 420), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = SecretApprovalPanel.sanitized(content.title, limit: 200)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        // A paste into the value field, by ⌘V, Edit › Paste or the field's menu: its change count, never its contents.
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didSendActionNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.userInfo?["MenuItem"] as? NSMenuItem
            MainActor.assumeIsolated {
                guard let self, item?.action == #selector(NSText.paste(_:)), self.isEditingValue else { return }
                self.recordPaste()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) }
    }

    // MARK: building

    private func build() {
        guard let view = window?.contentView else { return }
        let title = SecretApprovalPanel.label(SecretApprovalPanel.sanitized(content.title, limit: 200), size: 14, weight: .semibold)
        let asked = SecretApprovalPanel.label("Asked by \(SecretApprovalPanel.sanitized(content.askedBy, limit: 300)).", size: 12)
        asked.textColor = .secondaryLabelColor
        var views: [NSView] = [title, asked]
        if let words = content.agentWords.map({ SecretApprovalPanel.sanitized($0, limit: 500) }), !words.isEmpty {
            let quote = SecretApprovalPanel.label("The agent says: “\(words)”", size: 12)
            quote.font = NSFontManager.shared.convert(.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
            quote.toolTip = "These are the agent's words, not Next Term's."
            quote.setAccessibilityLabel("The agent says, in its own words: \(words)")
            views.append(quote)
        }
        views.append(contentsOf: fieldRows())
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.isHidden = true
        views.append(statusLabel)
        views.append(buttonRow())

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        var constraints = [
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 500),
        ]
        for row in stack.arrangedSubviews { constraints.append(row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36)) }
        NSLayoutConstraint.activate(constraints)
        refreshName()
    }

    private func fieldRows() -> [NSView] {
        nameField.stringValue = content.name
        nameField.placeholderString = "NAME"
        nameField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        nameField.delegate = self
        nameField.setAccessibilityLabel("Name")
        savedAsLabel.font = .systemFont(ofSize: 11)
        savedAsLabel.textColor = .secondaryLabelColor
        replaceLabel.font = .systemFont(ofSize: 12)
        replaceLabel.isHidden = true
        purposeField.stringValue = content.purpose
        purposeField.placeholderString = "What it's for (agents see this)"
        purposeField.delegate = self
        purposeField.setAccessibilityLabel("What it's for")
        valueField.placeholderString = "Paste or type the key"
        valueField.delegate = self
        valueField.setAccessibilityLabel("Value, hidden key")
        shortLabel.font = .systemFont(ofSize: 11)
        shortLabel.textColor = .secondaryLabelColor
        shortLabel.isHidden = true
        writeOnlyBox = NSButton(checkboxWithTitle: "Write-only", target: self, action: #selector(changed))
        writeOnlyBox.state = .off
        let writeOnlyLine = SecretApprovalPanel.label(Self.writeOnlyLine, size: 11)
        writeOnlyLine.textColor = .secondaryLabelColor
        return [Self.caption("Name"), nameField, savedAsLabel, replaceLabel, Self.caption("What it's for"), purposeField,
                Self.caption("Value"), valueField, shortLabel, writeOnlyBox, writeOnlyLine]
    }

    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        return label
    }

    private func buttonRow() -> NSView {
        stopButton = NSButton(title: "Decline and Stop Asking", target: self, action: #selector(declineAndStop))
        declineButton = NSButton(title: "Decline", target: self, action: #selector(decline))
        saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        for button in [stopButton, declineButton, saveButton] {
            button?.bezelStyle = .rounded
            button?.keyEquivalent = "" // no default button, even once the window is key
        }
        let row = NSStackView(views: [stopButton, NSView(), declineButton, saveButton])
        row.spacing = 8
        return row
    }

    // MARK: showing

    /// The windows on screen, kept until they close: one that says Saved outlives its request.
    private static var onScreen: [SecretRequestWindow] = []

    /// In front without taking the keyboard; the Dock icon bounces when Next Term is in the background.
    func present() {
        guard let window else { return }
        Self.onScreen.append(self)
        window.layoutIfNeeded()
        window.center()
        window.orderFront(nil)
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// The name as it will be saved: uppercased, spaces and hyphens made `_`.
    nonisolated static func normalized(_ typed: String) -> String {
        String(typed.uppercased().map { $0 == " " || $0 == "-" ? "_" : $0 })
    }

    var name: String { Self.normalized(nameField.stringValue.trimmingCharacters(in: .whitespaces)) }

    private var isEditingValue: Bool {
        guard let window, window.isKeyWindow, let editor = window.firstResponder as? NSText else { return false }
        return editor.delegate === valueField || window.firstResponder === valueField
    }

    /// A paste into the value field: the change count it is compared with on Save.
    func recordPaste() {
        pastedAt = SecretClipboard.shared.recordPaste()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === nameField {
            let shown = Self.normalized(nameField.stringValue)
            if shown != nameField.stringValue { nameField.stringValue = shown }
        } else if field === purposeField {
            purposeEdited = true
        }
        refreshName()
    }

    @objc private func changed() { refreshName() }

    /// "Saved as …" or the rule, the replace line for a stored name, the short-value line, and Save's state.
    private func refreshName() {
        let name = self.name
        let valid = SecretName.isValid(name)
        savedAsLabel.stringValue = valid ? "Saved as \(name)" : SecretName.rule
        savedAsLabel.textColor = valid ? .secondaryLabelColor : .systemOrange
        let stored = valid ? SecretsStore.shared.index?.entry(named: name) : nil
        replaceLabel.stringValue = stored.map { Self.replaceLine($0) } ?? ""
        replaceLabel.isHidden = stored == nil
        replaceLabel.setAccessibilityLabel(stored == nil ? nil : "Warning: \(replaceLabel.stringValue)")
        // A stored key keeps what it's for: Save replaces only its value.
        purposeField.isEnabled = stored == nil
        let length = valueField.stringValue.trimmingCharacters(in: .whitespaces).utf8.count
        shortLabel.isHidden = length == 0 || length >= SecretMask.minimumLength
        saveButton?.isEnabled = !isBusy && !answered && valid && length > 0
    }

    /// The line for a name already stored.
    static func replaceLine(_ entry: SecretVault.Entry) -> String {
        let day = SecretRequests.dayText(entry.created)
        let whose = entry.addedByUser ? "the key you added on \(day)" : "the key an agent saved on \(day)"
        return "This replaces \(whose). Commands and MCP servers that use it will get the value you enter here. "
            + "What it's for stays as it is."
    }

    // MARK: answers

    @objc private func save() {
        guard !answered, !isBusy else { return }
        let name = self.name
        guard SecretName.isValid(name) else { return }
        let value = SecretBytes(utf8: valueField.stringValue)
        let purpose = purposeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(Form(name: name, purpose: purpose, purposeBy: purposeEdited ? .user : .agent, value: value,
                    writeOnly: writeOnlyBox.state == .on))
    }

    @objc private func decline() { answer(stopAsking: false) }

    @objc private func declineAndStop() { answer(stopAsking: true) }

    private func answer(stopAsking: Bool) {
        guard !answered, !isBusy else { return }
        answered = true
        onDecline(stopAsking)
        close()
    }

    /// Save is waiting for Touch ID or the password.
    func setBusy(_ busy: Bool) {
        isBusy = busy
        for field in [nameField, purposeField, valueField] { field.isEnabled = !busy }
        for button in [stopButton, declineButton, writeOnlyBox] { button?.isEnabled = !busy }
        window?.standardWindowButton(.closeButton)?.isEnabled = !busy
        setStatus(busy ? "Waiting for Touch ID or your password…" : "")
        refreshName()
    }

    /// Touch ID or the password was cancelled or failed: back to where the user was.
    func notApproved(_ text: String = "Not approved.") {
        setBusy(false)
        setStatus(text)
    }

    /// Saved: the value field is emptied, and the window says so, with the clipboard line when it cleared one.
    func showSaved(_ name: String, clearedClipboard: Bool) {
        answered = true
        isBusy = false
        valueField.stringValue = ""
        for field in [nameField, purposeField, valueField] { field.isEnabled = false }
        for button in [stopButton, declineButton, writeOnlyBox] { button?.isHidden = true }
        saveButton.title = "Close"
        saveButton.isEnabled = true
        saveButton.action = #selector(closeSaved)
        window?.standardWindowButton(.closeButton)?.isEnabled = true
        setStatus("Saved \(name)." + (clearedClipboard ? " " + SecretClipboard.clearedLine : ""))
    }

    @objc private func closeSaved() { close() }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.isHidden = text.isEmpty
        guard !text.isEmpty, let window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Ends the window after its request was answered elsewhere (a pause, a drop).
    func finish() {
        answered = true
        valueField.stringValue = ""
        close()
    }

    /// Closing the window without choosing is a decline.
    func windowWillClose(_ notification: Notification) {
        valueField.stringValue = ""
        let closing = self
        DispatchQueue.main.async { MainActor.assumeIsolated { Self.onScreen.removeAll { $0 === closing } } }
        guard !answered else { return }
        answered = true
        onDecline(false)
    }
}
