import AppKit
import NextTermCore

/// Rotate… in Settings › Secrets and Window › Secrets: a key rotation in three steps, all shown, the current ones on.
///
/// 1. **Open \<host\>** opens the key's page, where the user makes a new key. GitHub's fine-grained tokens page opens
///    its new-token form, filled with the key's name and today's date. A key with no page gets "Where it came from"
///    here, with its suggestion, and the page is saved with the new value.
/// 2. The new key is pasted. The key it has now is refused as it is typed, found by its masking marks, since the sheet
///    never holds the old value; the store checks again inside the unlock. Save asks for Touch ID once ("rotate NAME").
/// 3. The user deletes or deactivates the old key on that page. Meanwhile it stays masked for 30 days.
///
/// Next Term makes no network call for any of it. A paste into the value field is cleared from the clipboard on Save,
/// when nothing was copied since (`SecretPasteWatch`).
@MainActor
final class SecretRotateSheet: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    static let makeLine = "Make a new key there, then copy it."
    static let formLine = "GitHub\u{2019}s form opens filled in: the key\u{2019}s name, today\u{2019}s date and a "
        + "\(KeyPage.githubExpiryDays)-day expiry."
    static let noPageLine = "Type or choose its page, then open it and make a new key there."
    static let currentLine = SecretVault.Failure.sameValue("").errorDescription ?? ""
    static let deleteLine = "Now delete or deactivate the old key on that page."
    static let deleteElsewhereLine = "Now delete or deactivate the old key where you made it."
    static let restartLine = "MCP servers that started before now keep the old key until they restart: /mcp in Claude "
        + "Code, or restart the agent."

    let entry: SecretVault.Entry
    private let done: (_ said: String?) -> Void

    /// Step 1 with a page: the button that opens it, named by its host.
    private(set) var openButton = NSButton(title: "Open Page", target: nil, action: nil)
    /// Step 1 with no page (or one that can't be opened): "Where it came from".
    private(set) var linkField: SecretLinkField?
    private(set) var valueField = NSSecureTextField()
    private(set) var tipLabel = NSTextField(wrappingLabelWithString: "")
    /// Under the value: the key it has now, another provider's look, or a value too short to mask.
    private(set) var checkLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var remindPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private(set) var saveButton = NSButton(title: "Save", target: nil, action: nil)
    private(set) var cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private(set) var doneLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var openAgainButton = NSButton(title: "Open Page Again", target: nil, action: nil)
    private(set) var remindTomorrowButton = NSButton(title: "Remind Me Tomorrow", target: nil, action: nil)
    private(set) var doneButton = NSButton(title: "Done", target: nil, action: nil)
    private(set) var statusLabel = NSTextField(wrappingLabelWithString: "")
    private var steps: [NSStackView] = []
    private var bottomRow = NSStackView()
    /// The pastes that reach the value field.
    private var pasteWatch: SecretPasteWatch?
    var pastedAt: Int? { pasteWatch?.pastedAt }
    /// A paste into the value field, as its watch records one: for the self-test, whose sheet may not be key.
    func recordPaste() { pasteWatch?.record() }
    private(set) var isBusy = false
    /// Save went through: step 3 is the current one.
    private(set) var isSaved = false

    init(_ entry: SecretVault.Entry, done: @escaping (_ said: String?) -> Void) {
        self.entry = entry
        self.done = done
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        pasteWatch = SecretPasteWatch(valueField)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var name: String { entry.name }

    /// The key's page as stored, checked again as it is shown: nil when it has none or it can't be opened, and then
    /// step 1 is "Where it came from".
    var storedPage: URL? {
        guard case .success(let url) = SecretsStore.shared.pageLink(of: name) else { return nil }
        return url
    }

    /// The page a link typed in step 1 opens, once it passes the link rules with the stored keys and the value typed.
    var typedPage: URL? {
        guard let linkField, !linkField.text.isEmpty, linkField.refusal == nil else { return nil }
        let mask: (String) -> Bool = { (candidate: String) -> Bool in SecretsStore.holdsStoredKey(candidate) }
        guard case .success(let url) = SecretLink.check(linkField.text, mask: mask, value: typedValue) else { return nil }
        return url
    }

    /// The page the tip and the provider check go by.
    var page: URL? { linkField == nil ? storedPage : typedPage }

    /// The value as typed, for its checks: never kept.
    private var typedValue: SecretBytes { SecretBytes(utf8: valueField.stringValue) }

    /// The key's entry now, for its marks: the one the sheet opened with when it is gone meanwhile.
    private var current: SecretVault.Entry { SecretsStore.shared.index?.entry(named: name) ?? entry }
}

// MARK: - Building

extension SecretRotateSheet {
    private func build() {
        guard let view = window?.contentView else { return }
        let heading = SecretApprovalPanel.label("Rotate \(name)", size: 14, weight: .semibold)
        steps = [pageStep(), valueStep(), deleteStep()]
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.isHidden = true
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        bottomRow = NSStackView(views: [NSView(), cancelButton, saveButton])
        bottomRow.spacing = 8
        let stack = NSStackView(views: [heading] + steps + [statusLabel, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        var constraints: [NSLayoutConstraint] = [
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 480),
        ]
        for row in stack.arrangedSubviews { constraints.append(row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36)) }
        NSLayoutConstraint.activate(constraints)
        for button in [openButton, saveButton, cancelButton, openAgainButton, remindTomorrowButton, doneButton] {
            button.bezelStyle = .rounded
        }
        linkField?.suggest(value: nil, name: name)
        refresh()
    }

    /// One step: its caption, then its rows, each as wide as the step.
    private func step(_ caption: String, _ rows: [NSView]) -> NSStackView {
        let label = NSTextField(labelWithString: caption)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        let box = NSStackView(views: [label] + rows)
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 6
        for row in rows { row.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true }
        return box
    }

    private static func note(_ text: String) -> NSTextField {
        let label = SecretApprovalPanel.label(text, size: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Step 1: Open <host>, with a line for GitHub's filled-in form; or, with no page to open, "Where it came from".
    private func pageStep() -> NSStackView {
        openButton.target = self
        openButton.action = #selector(openPage)
        if let url = storedPage {
            openButton.title = "Open " + (SecretLink.host(of: url) ?? "Page")
            let fills: Bool = SecretRotation.pageToOpen(url, name: name, date: Date()) != url
            let line = Self.note(fills ? Self.formLine : Self.makeLine)
            return step("1. Make a new key", [line, NSStackView(views: [openButton, NSView()])])
        }
        let field = SecretLinkField(stored: entry.link, from: entry.linkFrom)
        field.onChange = { [weak self] in self?.refresh() }
        field.value = { [weak self] in self?.typedValue }
        linkField = field
        return step("1. Make a new key", [Self.note(Self.noPageLine), field, NSStackView(views: [openButton, NSView()])])
    }

    /// Step 2: the tip, the paste field, what the typed key is, and "Remind me to rotate".
    private func valueStep() -> NSStackView {
        tipLabel.font = .systemFont(ofSize: 11)
        tipLabel.textColor = .secondaryLabelColor
        valueField.placeholderString = "Paste the new key"
        valueField.delegate = self
        valueField.setAccessibilityLabel("New key, hidden")
        checkLabel.font = .systemFont(ofSize: 11)
        checkLabel.isHidden = true
        var choices: [Int] = SecretEditSheet.remindChoices
        if let days = entry.remindDays, !choices.contains(days) { choices.append(days) }
        for choice in choices.sorted() {
            remindPopUp.addItem(withTitle: choice == 0 ? "Never" : "\(choice) days")
            remindPopUp.lastItem?.tag = choice
        }
        remindPopUp.selectItem(withTag: entry.remindDays ?? 0)
        remindPopUp.setAccessibilityLabel("Remind me to rotate")
        let caption = NSTextField(labelWithString: "Remind me to rotate")
        caption.font = .systemFont(ofSize: 12)
        let remind = NSStackView(views: [caption, remindPopUp, NSView()])
        remind.spacing = 8
        return step("2. Paste the new key", [tipLabel, valueField, checkLabel, remind])
    }

    /// Step 3: delete the old key at its page; on once the new one is saved.
    private func deleteStep() -> NSStackView {
        doneLabel.font = .systemFont(ofSize: 12)
        doneLabel.stringValue = Self.deleteLine
        let actions: [(NSButton, Selector)] = [(openAgainButton, #selector(openPageAgain)),
                                               (remindTomorrowButton, #selector(remindTomorrow)), (doneButton, #selector(finishDone))]
        for (button, action) in actions {
            button.target = self
            button.action = action
        }
        let buttons = NSStackView(views: [openAgainButton, NSView(), remindTomorrowButton, doneButton])
        buttons.spacing = 8
        return step("3. Delete the old key", [doneLabel, buttons])
    }

    /// Shows the sheet on `parent`, with the paste field taking the keyboard.
    func begin(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window, completionHandler: nil)
        window.makeFirstResponder(valueField)
    }
}

// MARK: - Checking as the user types

extension SecretRotateSheet {
    /// What the typed key is: the one the key has now (Save off), another provider's than its page (a warning; Save
    /// stays on), or too short to mask. Then step 1's button, the tip, and which steps are on.
    func refresh() {
        let length: Int = valueField.stringValue.trimmingCharacters(in: .whitespaces).utf8.count
        let value: SecretBytes = typedValue
        let isCurrent: Bool = length > 0 && SecretMask.current.isHeld(value, by: current)
        let page: URL? = self.page
        let warning: String? = length > 0 && !isCurrent ? SecretRotation.warning(value: value, link: page) : nil
        var line = ""
        var warns = false
        if isCurrent {
            line = Self.currentLine
            warns = true
        } else if let warning {
            line = warning
            warns = true
        } else if length > 0, length < SecretMask.minimumLength {
            line = SecretRequestWindow.shortLine
        }
        checkLabel.stringValue = line
        checkLabel.textColor = warns ? .systemOrange : .secondaryLabelColor
        checkLabel.isHidden = line.isEmpty
        checkLabel.setAccessibilityLabel(warns ? "Warning: \(line)" : nil)
        let tip: String? = SecretRotation.tip(for: page)
        tipLabel.stringValue = tip ?? ""
        tipLabel.isHidden = tip == nil
        linkField?.refresh()
        if linkField != nil {
            let host: String? = page.flatMap { (url: URL) -> String? in SecretLink.host(of: url) }
            openButton.title = host.map { (name: String) -> String in "Open " + name } ?? "Open Page"
        }
        let linkOK: Bool = linkField?.blocksSave != true
        let editing: Bool = !isBusy && !isSaved
        openButton.isEnabled = editing && page != nil
        saveButton.isEnabled = editing && length > 0 && !isCurrent && linkOK
        cancelButton.isEnabled = !isBusy
        valueField.isEnabled = editing
        remindPopUp.isEnabled = editing
        linkField?.setEnabled(editing)
        for button in [openAgainButton, remindTomorrowButton, doneButton] { button.isEnabled = isSaved }
        steps.first?.alphaValue = isSaved ? 0.45 : 1
        if steps.count > 1 { steps[1].alphaValue = isSaved ? 0.45 : 1 }
        steps.last?.alphaValue = isSaved ? 1 : 0.45
    }

    func controlTextDidChange(_ notification: Notification) {
        if (notification.object as? NSTextField) === valueField { linkField?.suggest(value: typedValue, name: name) }
        refresh()
    }

    /// The reminder chosen: nil for Never.
    var remindDays: Int? {
        let tag: Int = remindPopUp.selectedTag()
        return tag > 0 ? tag : nil
    }

    /// Step 1's page: the stored one once the store has checked vault.json's bytes are the ones Next Term wrote or
    /// checked (an unlock first when they aren't), or the one typed here. GitHub's fine-grained tokens page opens its
    /// new-token form, when that passes the link rules too.
    @objc func openPage() {
        if linkField != nil {
            guard let url = typedPage else { return NSSound.beep() }
            return open(form(of: url))
        }
        Task { @MainActor in
            do {
                let url = try await SecretsStore.shared.checkedPage(of: self.name)
                self.open(self.form(of: url))
            } catch SecretsStore.Failure.cancelled {
                self.setStatus("Not approved.")
            } catch {
                self.setStatus((error as? LocalizedError)?.errorDescription ?? "Next Term couldn\u{2019}t open the page.")
            }
        }
    }

    /// The page to open for `url`: its new-token form when it has one that passes the link rules, else `url`.
    private func form(of url: URL) -> URL {
        let filled: URL = SecretRotation.pageToOpen(url, name: name, date: Date())
        guard filled != url else { return url }
        let mask: (String) -> Bool = { (candidate: String) -> Bool in SecretsStore.holdsStoredKey(candidate) }
        guard case .success(let checked) = SecretLink.check(filled.absoluteString, mask: mask, value: nil) else { return url }
        return checked
    }

    private func open(_ url: URL) {
        ServiceLinks.open(url, from: window)
    }
}

// MARK: - Saving, and step 3

extension SecretRotateSheet {
    /// The rotation Save makes: the new value, with step 1's page when it was typed here and the reminder when it
    /// changed.
    func rotation() -> SecretsStore.KeyRotation {
        var change = SecretsStore.KeyRotation(name: name, value: typedValue)
        if let linkField, linkField.isChanged {
            let text: String = linkField.text
            change.link = .some(text.isEmpty ? nil : text)
            change.linkFrom = text.isEmpty ? nil : linkField.linkFrom
        }
        let remind: Int? = remindDays
        if remind != entry.remindDays { change.remindDays = .some(remind) }
        return change
    }

    @objc func save() {
        guard !isBusy, !isSaved, saveButton.isEnabled else { return }
        let change = rotation()
        let pasted = pastedAt
        setBusy(true)
        Task { @MainActor in
            do {
                try await SecretsStore.shared.perform(.rotate(change), facts: SecretsStore.Facts(who: "you, in Settings › Secrets"))
                let cleared = SecretClipboard.shared.clearAfterSave(pastedAt: pasted)
                self.showSaved(clearedClipboard: cleared)
            } catch SecretsStore.Failure.cancelled {
                self.setBusy(false)
                self.setStatus("Not approved.")
            } catch {
                self.setBusy(false)
                self.setStatus((error as? LocalizedError)?.errorDescription ?? "Next Term couldn\u{2019}t save the key.")
            }
        }
    }

    /// Step 3 is the current one: what to do at the page, that the old key stays masked, and what to restart.
    private func showSaved(clearedClipboard: Bool) {
        valueField.stringValue = ""
        isSaved = true
        isBusy = false
        let hasPage: Bool = SecretsStore.shared.index?.entry(named: name)?.link != nil
        var lines: [String] = [hasPage ? Self.deleteLine : Self.deleteElsewhereLine, SecretRotation.keptMaskedLine, Self.restartLine]
        if clearedClipboard { lines.append(SecretClipboard.clearedLine) }
        doneLabel.stringValue = lines.joined(separator: " ")
        openAgainButton.isHidden = !hasPage
        bottomRow.isHidden = true
        saveButton.keyEquivalent = ""
        cancelButton.keyEquivalent = ""
        doneButton.keyEquivalent = "\r"
        setStatus("")
        refresh()
        window?.makeFirstResponder(doneButton)
        guard let window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: "Rotated \(name). " + doneLabel.stringValue,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// The key's page as it is stored now, to delete the old key there.
    @objc func openPageAgain() {
        Task { @MainActor in
            do {
                let url = try await SecretsStore.shared.checkedPage(of: self.name)
                self.open(url)
            } catch SecretsStore.Failure.cancelled {
                self.setStatus("Not approved.")
            } catch {
                self.setStatus((error as? LocalizedError)?.errorDescription ?? "Next Term couldn\u{2019}t open the page.")
            }
        }
    }

    /// One reminder tomorrow to delete the old key, then the sheet closes.
    @objc func remindTomorrow() {
        guard isSaved else { return }
        SecretReminderRecords.remindTomorrow(name)
        finish(said: "Next Term will remind you tomorrow to delete the old \(name).")
    }

    @objc func finishDone() {
        guard isSaved else { return }
        finish(said: "Rotated \(name).")
    }

    @objc func cancel() {
        guard !isBusy, !isSaved else { return }
        finish(said: nil)
    }

    private func finish(said: String?) {
        valueField.stringValue = ""
        if let window, let parent = window.sheetParent { parent.endSheet(window) } else { window?.close() }
        done(said)
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
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
