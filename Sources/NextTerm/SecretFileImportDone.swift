import AppKit
import NextTermCore

/// Import from a File's Import…: the confirm, the copy-in under one Touch ID, and the done view.
extension SecretFileImportSheet {
    static let notApprovedLine = "Not approved."

    /// The rows as the sheet shows them: each name as typed, each tick as set.
    var editedRows: [SourceRow] {
        guard let report else { return [] }
        return rows.map { (row: FileImportRow) -> SourceRow in
            var edited: SourceRow = report.rows[row.index]
            edited.name = row.name
            edited.ticked = row.isTicked
            return edited
        }
    }

    /// Where the keys came from, as Recent imports names it: ".env in rag-api", "Bitwarden".
    var sourceText: String {
        let purpose: String = report?.purpose ?? fileName
        return purpose.hasPrefix("From ") ? String(purpose.dropFirst(5)) : purpose
    }

    /// Asks once, naming every key and each it replaces; then the copy-in.
    @objc func importTicked() {
        guard importButton.isEnabled, let window, let report else { return }
        let stored: Set<String> = Set(SecretsStore.shared.index?.names ?? [])
        let holds: (String) -> Bool = { (text: String) -> Bool in SecretsStore.holdsStoredKey(text) }
        let planned: [SecretCopyIn.Planned]
        do {
            planned = try SecretCopyIn.plan(editedRows, purpose: report.purpose, stored: stored, holdsKey: holds)
        } catch {
            return refresh()
        }
        guard !planned.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Copy \(planned.count) \(planned.count == 1 ? "key" : "keys") into Secrets?"
        alert.informativeText = Self.confirmText(planned, file: fileName)
        alert.addButton(withTitle: "Copy Keys")
        alert.addButton(withTitle: "Cancel")
        confirmAlert = alert
        alert.beginSheetModal(for: window) { [weak self] (response: NSApplication.ModalResponse) in
            MainActor.assumeIsolated {
                self?.confirmAlert = nil
                if response == .alertFirstButtonReturn { self?.copyIn(planned) }
            }
        }
    }

    /// The confirm's text: the keys, the ones it replaces (which Undo can't put back), and that the file stays.
    static func confirmText(_ planned: [SecretCopyIn.Planned], file: String) -> String {
        let shown: [String] = planned.prefix(12).map { (key: SecretCopyIn.Planned) -> String in "\u{2022} " + key.name }
        var text: String = shown.joined(separator: "\n")
        if planned.count > shown.count { text += "\n\u{2022} and \(planned.count - shown.count) more" }
        let replaced: [String] = planned.filter(\.replaces).map(\.name)
        if !replaced.isEmpty {
            let one: Bool = replaced.count == 1
            let lead: String = one ? "This replaces a key you have: " : "These replace keys you have: "
            let back: String = ". Undo can\u{2019}t put back what " + (one ? "it" : "they") + " held."
            text += "\n\n" + lead + replaced.joined(separator: ", ") + back
        }
        let undo: String = "For 30 days, Undo in Recent imports deletes the keys this copies in."
        return text + "\n\n" + "\(file) stays as it is. " + undo
    }

    /// One Touch ID ("copy 3 keys from .env"), then the done view.
    func copyIn(_ planned: [SecretCopyIn.Planned]) {
        guard let report else { return }
        setBusy(true, Self.touchIDLine)
        let format: SecretSources.Format = report.format
        let reason: String = SecretReason.copyIn(planned.count, from: fileName)
        let source: String = sourceText
        Task { @MainActor in
            do {
                let saved = try await SecretsStore.shared.performCopyIn(planned, source: source, format: format,
                                                                        reason: reason)
                self.isBusy = false
                self.showDone(saved)
            } catch SecretsStore.Failure.cancelled {
                self.setBusy(false, Self.notApprovedLine)
            } catch {
                let failed: String = "Next Term couldn\u{2019}t copy the keys."
                self.setBusy(false, (error as? LocalizedError)?.errorDescription ?? failed)
            }
        }
    }

    /// Busy: Import… and Cancel are off. `status`, when given, is the line above the rows.
    func setBusy(_ busy: Bool, _ status: String? = nil) {
        isBusy = busy
        cancelButton.isEnabled = !busy
        refresh()
        if let status { statusLabel.stringValue = status }
    }
}

// MARK: done

extension SecretFileImportSheet {
    /// The rows go still; the summary says what was copied and what still holds the keys; an export gets Move Export
    /// to the Trash, ticked; a file in git gets Rotate… for each key, since git's history keeps them.
    func showDone(_ saved: SecretCopyIn.Record) {
        record = saved
        for row in rows {
            row.box.isEnabled = false
            row.nameField.isEnabled = false
        }
        let names: [String] = saved.names
        statusLabel.stringValue = SecretCopyIn.copiedText(names.count)
        var summary: [String] = []
        let exported: Bool = report?.exportedBy != nil
        let line: String? = SecretCopyIn.doneLine(names: names, file: fileName, format: report?.format ?? .env,
                                                  agent: report?.agent, exported: exported)
        if let line { summary.append(line) }
        if inGit { summary.append(SecretImportSheet.rotate) }
        summaryLabel.stringValue = summary.joined(separator: "\n\n")
        summaryLabel.isHidden = summary.isEmpty
        if exported { addDone(trashBox, Self.small(Self.trashLine)) }
        if inGit { addRotateRows(names) }
        doneStack.isHidden = doneStack.arrangedSubviews.isEmpty
        importButton.isHidden = true
        cancelButton.isHidden = true
        doneButton.isHidden = false
        doneButton.keyEquivalent = "\r"
        refresh()
        statusLabel.stringValue = SecretCopyIn.copiedText(names.count)
    }

    private func addDone(_ views: NSView...) {
        for view in views { doneStack.addArrangedSubview(view) }
    }

    /// "Rotate…" by each key's name, at most `rotateRows`; the rest are in the list.
    private func addRotateRows(_ names: [String]) {
        for name in names.prefix(Self.rotateRows) {
            let button = NSButton(title: "Rotate\u{2026}", target: self, action: #selector(rotateKey(_:)))
            button.bezelStyle = .rounded
            button.identifier = NSUserInterfaceItemIdentifier(name)
            button.setAccessibilityLabel("Rotate \(name)")
            let label = NSTextField(labelWithString: name)
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            let line = NSStackView(views: [button, label])
            line.spacing = 8
            doneStack.addArrangedSubview(line)
            rotateButtons.append(button)
        }
        let more: Int = names.count - Self.rotateRows
        if more > 0 { addDone(Self.small("And \(more) more: select each in the list and use Rotate\u{2026}.")) }
    }

    static func small(_ text: String) -> NSTextField {
        let label = SecretApprovalPanel.label(text, size: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Rotate… for one key: the sheet closes (moving an export to the Trash first, when ticked) and the list opens
    /// Rotate… for that key.
    @objc func rotateKey(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        end(rotate: name)
    }

    /// Done: an export goes to the Trash when its box is ticked, then the sheet closes.
    @objc func finish() { end(rotate: nil) }

    private func end(rotate: String?) {
        guard !isBusy, let saved = record else { return closeSheet() }
        let copied: String = SecretCopyIn.copiedText(saved.names.count)
        guard report?.exportedBy != nil, trashBox.state == .on else {
            return finishSheet(Ending(said: copied, rotate: rotate))
        }
        let url = URL(fileURLWithPath: path)
        let file: String = fileName
        isBusy = true
        NSWorkspace.shared.recycle([url]) { [weak self] (trashed: [URL: URL], error: Error?) in
            let moved: Bool = error == nil && !trashed.isEmpty
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isBusy = false
                    let said: String = moved ? "\(copied) Moved \(file) to the Trash."
                        : "\(copied) Next Term couldn\u{2019}t move \(file) to the Trash."
                    self.finishSheet(Ending(said: said, rotate: rotate))
                }
            }
        }
    }

    /// Cancel, or the end of an unreadable file's sheet: nothing was copied.
    @objc func closeSheet() {
        guard !isBusy else { return }
        finishSheet(Ending(said: nil, rotate: nil))
    }

    /// Closes the sheet and releases the report, which wipes every value it held.
    private func finishSheet(_ ending: Ending) {
        guard let window else { return }
        confirmAlert = nil
        rows = []
        for view in rowsStack.arrangedSubviews { view.removeFromSuperview() }
        report = nil
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
        done(ending)
    }
}
