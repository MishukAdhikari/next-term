import AppKit
import NextTermCore

/// Add…, Edit… and Replace… in Settings › Secrets and Window › Secrets (U7). Save asks for Touch ID or the Mac
/// password once (KTD4); cancelling it leaves the sheet as it was. A paste into the value field is cleared from the
/// clipboard on Save, when nothing was copied since (KTD24).
@MainActor
final class SecretEditSheet: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    enum Mode {
        case add
        /// The name and what it's for.
        case edit(SecretVault.Entry)
        /// A new value, and the write-only flag.
        case replace(SecretVault.Entry)

        var entry: SecretVault.Entry? {
            switch self {
            case .add: return nil
            case .edit(let entry), .replace(let entry): return entry
            }
        }
    }

    let mode: Mode
    private let done: (_ saved: String?) -> Void

    private(set) var nameField = NSTextField()
    private(set) var purposeField = NSTextField()
    private(set) var valueField = NSSecureTextField()
    private(set) var writeOnlyBox: NSButton!
    private(set) var saveButton: NSButton!
    private(set) var cancelButton: NSButton!
    private let savedAsLabel = NSTextField(labelWithString: "")
    private let shortLabel = NSTextField(wrappingLabelWithString: SecretRequestWindow.shortLine)
    private(set) var statusLabel = NSTextField(wrappingLabelWithString: "")
    /// The pasteboard's change count at the last paste into the value field.
    private(set) var pastedAt: Int?
    private(set) var isBusy = false
    private var menuObserver: NSObjectProtocol?

    init(_ mode: Mode, done: @escaping (_ saved: String?) -> Void) {
        self.mode = mode
        self.done = done
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
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

    var title: String {
        switch mode {
        case .add: return "Add a Key"
        case .edit(let entry): return "Edit \(entry.name)"
        case .replace(let entry): return "Replace \(entry.name)"
        }
    }

    private var hasValue: Bool {
        if case .edit = mode { return false }
        return true
    }

    // MARK: building

    private func build() {
        guard let view = window?.contentView else { return }
        let heading = SecretApprovalPanel.label(title, size: 14, weight: .semibold)
        var views: [NSView] = [heading]
        let entry = mode.entry
        nameField.stringValue = entry?.name ?? ""
        nameField.placeholderString = "GITHUB_TOKEN"
        nameField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        nameField.delegate = self
        nameField.setAccessibilityLabel("Name")
        if case .replace = mode { nameField.isEditable = false }
        savedAsLabel.font = .systemFont(ofSize: 11)
        let hint = SecretApprovalPanel.label(SecretName.rule, size: 11)
        hint.textColor = .secondaryLabelColor
        views += [Self.caption("Name"), nameField, savedAsLabel, hint]
        if case .replace = mode {} else {
            purposeField.stringValue = entry?.purpose ?? ""
            purposeField.placeholderString = "What it's for (agents see this)"
            purposeField.delegate = self
            purposeField.setAccessibilityLabel("What it's for")
            views += [Self.caption("What it's for"), purposeField]
        }
        if hasValue {
            valueField.placeholderString = "Paste or type the key"
            valueField.delegate = self
            valueField.setAccessibilityLabel("Value, hidden key")
            shortLabel.font = .systemFont(ofSize: 11)
            shortLabel.textColor = .secondaryLabelColor
            shortLabel.isHidden = true
            writeOnlyBox = NSButton(checkboxWithTitle: "Write-only", target: self, action: #selector(changed))
            // On in Replace only when the key is write-only already.
            writeOnlyBox.state = entry?.writeOnly == true ? .on : .off
            let line = SecretApprovalPanel.label(SecretRequestWindow.writeOnlyLine, size: 11)
            line.textColor = .secondaryLabelColor
            views += [Self.caption("Value"), valueField, shortLabel, writeOnlyBox, line]
        }
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.isHidden = true
        views.append(statusLabel)
        cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        for button in [cancelButton, saveButton] { button?.bezelStyle = .rounded }
        let buttons = NSStackView(views: [NSView(), cancelButton, saveButton])
        buttons.spacing = 8
        views.append(buttons)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        var constraints = [
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 460),
        ]
        for row in stack.arrangedSubviews { constraints.append(row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36)) }
        NSLayoutConstraint.activate(constraints)
        refresh()
    }

    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        return label
    }

    /// Shows the sheet on `parent`.
    func begin(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window, completionHandler: nil)
        if case .replace = mode {
            window.makeFirstResponder(valueField)
        } else {
            window.makeFirstResponder(nameField)
        }
    }

    // MARK: the fields

    var name: String { SecretRequestWindow.normalized(nameField.stringValue.trimmingCharacters(in: .whitespaces)) }

    private var isEditingValue: Bool {
        guard hasValue, let window, let editor = window.firstResponder as? NSText else { return false }
        return editor.delegate === valueField
    }

    /// A paste into the value field: the change count it is compared with on Save.
    func recordPaste() {
        pastedAt = SecretClipboard.shared.recordPaste()
    }

    func controlTextDidChange(_ notification: Notification) {
        if (notification.object as? NSTextField) === nameField {
            let shown = SecretRequestWindow.normalized(nameField.stringValue)
            if shown != nameField.stringValue { nameField.stringValue = shown }
        }
        refresh()
    }

    @objc private func changed() { refresh() }

    /// "Saved as …", or why the name can't be saved; the short-value line; Save's state.
    func refresh() {
        let name = self.name
        let taken = name != mode.entry?.name && SecretsStore.shared.index?.entry(named: name) != nil
        if !SecretName.isValid(name) {
            savedAsLabel.stringValue = name.isEmpty ? "" : SecretName.rule
            savedAsLabel.textColor = .systemOrange
        } else if taken {
            savedAsLabel.stringValue = "A key named \(name) is stored already."
            savedAsLabel.textColor = .systemOrange
        } else {
            savedAsLabel.stringValue = "Saved as \(name)"
            savedAsLabel.textColor = .secondaryLabelColor
        }
        let length = valueField.stringValue.trimmingCharacters(in: .whitespaces).utf8.count
        shortLabel.isHidden = !hasValue || length == 0 || length >= SecretMask.minimumLength
        let purposeOK = purposeField.stringValue.count <= SecretVault.maxPurposeLength
        saveButton?.isEnabled = !isBusy && SecretName.isValid(name) && !taken && purposeOK && (!hasValue || length > 0)
    }

    // MARK: saving

    /// The change Save makes, or nil when Edit changed nothing.
    func action() -> SecretsStore.Action? {
        let purpose = purposeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .add:
            return .add(name: name, purpose: purpose, purposeBy: .user, origin: .settings, writeOnly: writeOnlyBox.state == .on,
                        value: SecretBytes(utf8: valueField.stringValue))
        case .edit(let entry):
            let newName = name == entry.name ? nil : name
            let newPurpose = purpose == entry.purpose ? nil : purpose
            guard newName != nil || newPurpose != nil else { return nil }
            return .edit(name: entry.name, newName: newName, purpose: newPurpose, purposeBy: .user)
        case .replace(let entry):
            return .replace(name: entry.name, value: SecretBytes(utf8: valueField.stringValue), writeOnly: writeOnlyBox.state == .on,
                            origin: .settings)
        }
    }

    @objc func save() {
        guard !isBusy, saveButton.isEnabled else { return }
        guard let action = action() else { return finish(saved: nil) }
        let pasted = pastedAt
        setBusy(true)
        Task { @MainActor in
            do {
                try await SecretsStore.shared.perform(action, facts: SecretsStore.Facts(who: "you, in Settings › Secrets"))
                let cleared = SecretClipboard.shared.clearAfterSave(pastedAt: pasted)
                self.finish(saved: cleared ? SecretClipboard.clearedLine : "")
            } catch SecretsStore.Failure.cancelled {
                self.setBusy(false)
                self.setStatus("Not approved.")
            } catch {
                self.setBusy(false)
                self.setStatus((error as? LocalizedError)?.errorDescription ?? "Next Term couldn’t save the key.")
            }
        }
    }

    @objc func cancel() {
        guard !isBusy else { return }
        finish(saved: nil)
    }

    private func finish(saved: String?) {
        valueField.stringValue = ""
        if let window, let parent = window.sheetParent { parent.endSheet(window) } else { window?.close() }
        done(saved)
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        for field in [nameField, purposeField, valueField] { field.isEnabled = !busy }
        writeOnlyBox?.isEnabled = !busy
        cancelButton.isEnabled = !busy
        setStatus(busy ? "Waiting for Touch ID or your password…" : "")
        refresh()
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.isHidden = text.isEmpty
        guard !text.isEmpty, let window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
