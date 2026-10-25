import AppKit
import NextTermCore

/// Add…, Edit… and Replace… in Settings › Secrets and the Secrets window. Save asks for Touch ID or the Mac
/// password once; cancelling it leaves the sheet as it was. A paste into the value field is cleared from the
/// clipboard on Save, when nothing was copied since. Add… and Edit… also set "Where it came from" (`SecretLinkField`),
/// "Remind me to rotate" and "Ask for Touch ID every time it’s used"; Add… and Replace…, "Never show this key".
@MainActor
final class SecretEditSheet: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    enum Mode {
        case add
        /// The name, what it's for, its page, its reminder and whether it asks every time.
        case edit(SecretVault.Entry)
        /// A new value, and "Never show this key".
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
    /// "Where it came from", in Add… and Edit….
    private(set) var linkField: SecretLinkField?
    /// "Remind me to rotate", in Add… and Edit…: each item's tag is its days, 0 for Never.
    private(set) var remindPopUp: NSPopUpButton?
    /// "Ask for Touch ID every time it’s used", in Add… and Edit….
    private(set) var asksBox: NSButton?
    /// The pastes that reach the value field (`SecretPasteWatch`), when the sheet has one.
    private var pasteWatch: SecretPasteWatch?
    /// The pasteboard's change count at the last paste into the value field.
    var pastedAt: Int? { pasteWatch?.pastedAt }
    private(set) var isBusy = false

    init(_ mode: Mode, done: @escaping (_ saved: String?) -> Void) {
        self.mode = mode
        self.done = done
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        // Only a paste that reaches the value field counts, not one made in another window meanwhile.
        if hasValue { pasteWatch = SecretPasteWatch(valueField) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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
        let hint = SecretApprovalPanel.label(StoredSecretName.rule, size: 11)
        hint.textColor = .secondaryLabelColor
        views += [Self.caption("Name"), nameField, savedAsLabel, hint]
        if case .replace = mode {} else {
            purposeField.stringValue = entry?.purpose ?? ""
            purposeField.placeholderString = "What it's for (agents see this)"
            purposeField.delegate = self
            purposeField.setAccessibilityLabel("What it's for")
            views += [Self.caption("What it's for"), purposeField]
            let link = SecretLinkField(stored: entry?.link, from: entry?.linkFrom)
            link.onChange = { [weak self] in self?.refresh() }
            link.value = { [weak self] in self.flatMap { $0.hasValue ? $0.typedValue : nil } }
            linkField = link
            // A new key starts with the reminder Settings › Secrets sets for new keys; a stored key shows its own.
            let remind: Int? = entry == nil ? SecretReminderRecords.newKeyDays : entry?.remindDays
            views += [link, reminderRow(remind)]
            // So does asking every time: an old key, saved before the box, asks.
            let asks: Bool = entry?.asksEveryUse ?? SecretNewKeyDefaults.asksEveryUse
            views += asksRows(asks)
        }
        if hasValue {
            valueField.placeholderString = "Paste or type the key"
            valueField.delegate = self
            valueField.setAccessibilityLabel("Value, hidden key")
            shortLabel.font = .systemFont(ofSize: 11)
            shortLabel.textColor = .secondaryLabelColor
            shortLabel.isHidden = true
            writeOnlyBox = NSButton(checkboxWithTitle: SecretNewKeyDefaults.keyNeverShowTitle, target: self, action: #selector(changed))
            // In Add…, as Settings › Secrets' New keys default says; in Replace…, on only when the key is never shown
            // already, and then dimmed, since it can't be undone.
            let neverShow: Bool = entry.map(\.writeOnly) ?? SecretNewKeyDefaults.neverShow
            writeOnlyBox.state = neverShow ? .on : .off
            writeOnlyBox.isEnabled = !keepsNeverShow
            writeOnlyBox.toolTip = keepsNeverShow ? SecretRequestWindow.neverShownTip : nil
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
        suggestLink()
        refresh()
    }

    /// "Remind me to rotate" and its pop-up: Never, or 30, 90, 180 or 365 days; a key saved with another age keeps it
    /// as an item of its own.
    private func reminderRow(_ days: Int?) -> NSView {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        var choices: [Int] = SecretEditSheet.remindChoices
        if let days, !choices.contains(days) { choices.append(days) }
        for choice in choices.sorted() {
            popUp.addItem(withTitle: choice == 0 ? "Never" : "\(choice) days")
            popUp.lastItem?.tag = choice
        }
        popUp.selectItem(withTag: days ?? 0)
        popUp.target = self
        popUp.action = #selector(changed)
        popUp.setAccessibilityLabel("Remind me to rotate")
        remindPopUp = popUp
        let row = NSStackView(views: [Self.caption("Remind me to rotate"), popUp, NSView()])
        row.spacing = 8
        return row
    }

    /// Replace… of a key never shown: its "Never show this key" stays ticked, and can't be unticked.
    private var keepsNeverShow: Bool {
        guard case .replace(let entry) = mode else { return false }
        return entry.writeOnly
    }

    /// The reminder's choices, in days; 0 is Never.
    static let remindChoices = [0, 30, 90, 180, 365]

    /// "Ask for Touch ID every time it’s used", and what unticking it allows.
    private func asksRows(_ asks: Bool) -> [NSView] {
        let box = NSButton(checkboxWithTitle: SecretNewKeyDefaults.keyAsksTitle, target: self, action: #selector(changed))
        box.state = asks ? .on : .off
        asksBox = box
        let help = SecretApprovalPanel.label(SecretNewKeyDefaults.keyAsksHelp, size: 11)
        help.textColor = .secondaryLabelColor
        return [box, help]
    }

    /// Whether the key asks for Touch ID every time it's used, as ticked.
    var asksEveryUse: Bool { asksBox?.state != .off }

    /// The reminder chosen: nil for Never.
    var remindDays: Int? {
        guard let tag = remindPopUp?.selectedTag(), tag > 0 else { return nil }
        return tag
    }

    /// The value as typed, for the link's suggestion and its check: never kept.
    private var typedValue: SecretBytes { SecretBytes(utf8: valueField.stringValue) }

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

    func controlTextDidChange(_ notification: Notification) {
        let field = notification.object as? NSTextField
        if field === nameField {
            let shown = SecretRequestWindow.normalized(nameField.stringValue)
            if shown != nameField.stringValue { nameField.stringValue = shown }
        }
        if field === nameField || field === valueField { suggestLink() }
        refresh()
    }

    /// The link's suggestion, off the value's first bytes and the name; the field keeps a link the user typed.
    func suggestLink() {
        linkField?.suggest(value: hasValue ? typedValue : nil, name: name)
    }

    @objc private func changed() { refresh() }

    /// "Saved as …", or why the name can't be saved; the short-value line; Save's state.
    func refresh() {
        let name = self.name
        let taken = name != mode.entry?.name && SecretsStore.shared.index?.entry(named: name) != nil
        if !StoredSecretName.isValid(name) {
            savedAsLabel.stringValue = name.isEmpty ? "" : StoredSecretName.rule
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
        linkField?.refresh()
        let linkOK: Bool = linkField?.blocksSave != true
        let valueOK: Bool = !hasValue || length > 0
        saveButton?.isEnabled = !isBusy && StoredSecretName.isValid(name) && !taken && purposeOK && linkOK && valueOK
    }

    // MARK: saving

    /// The change Save makes, or nil when Edit changed nothing.
    func action() -> SecretsStore.Action? {
        let purpose = purposeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .add:
            let link: String? = linkField.map { $0.text.isEmpty ? nil : $0.text } ?? nil
            return .add(name: name, purpose: purpose, purposeBy: .user, origin: .settings, writeOnly: writeOnlyBox.state == .on,
                        value: SecretBytes(utf8: valueField.stringValue), link: link, linkFrom: link == nil ? nil : linkField?.linkFrom,
                        remindDays: remindDays, asksEveryUse: asksEveryUse)
        case .edit(let entry):
            let newName = name == entry.name ? nil : name
            let newPurpose = purpose == entry.purpose ? nil : purpose
            let change = linkChange()
            let newRemind: Int?? = remindDays == entry.remindDays ? nil : .some(remindDays)
            let newAsks: Bool? = asksEveryUse == entry.asksEveryUse ? nil : asksEveryUse
            let changes: [Bool] = [newName != nil, newPurpose != nil, change.link != nil, newRemind != nil, newAsks != nil]
            guard changes.contains(true) else { return nil }
            return .edit(name: entry.name, newName: newName, purpose: newPurpose, purposeBy: .user, link: change.link,
                         linkFrom: change.from, remindDays: newRemind, asksEveryUse: newAsks)
        case .replace(let entry):
            // A key never shown stays so (the vault keeps it too).
            let writeOnly: Bool = entry.writeOnly || writeOnlyBox.state == .on
            return .replace(name: entry.name, value: SecretBytes(utf8: valueField.stringValue), writeOnly: writeOnly,
                            origin: .settings)
        }
    }

    /// Edit's link: nil when it is as stored, `.some(nil)` to clear it, or the new link and where it came from.
    private func linkChange() -> (link: String??, from: SecretVault.LinkFrom?) {
        guard let linkField, linkField.isChanged else { return (nil, nil) }
        let text = linkField.text
        guard !text.isEmpty else { return (.some(nil), nil) }
        return (.some(text), linkField.linkFrom)
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
        writeOnlyBox?.isEnabled = !busy && !keepsNeverShow
        asksBox?.isEnabled = !busy
        linkField?.setEnabled(!busy)
        remindPopUp?.isEnabled = !busy
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
