import AppKit
import NextTermCore

/// Import From › A File… in the list: the open panel (the user's pick is the consent), the file read off the main
/// thread, and the sheet for it. A file the MCP-config import rewrites opens that import for the file alone, with its
/// own explanation, since it changes the file; the keys outside its servers then open in the copy sheet. Unlike that
/// import, a copy needs no "Let agents control Next Term": nothing is rewritten to start through it.
extension SecretsView {
    /// A File… hands an MCP config to the MCP-config import, which rewrites it.
    static let panelMessage = "Choose a file of keys: a .env file, a JSON, TOML or YAML config, an agent\u{2019}s MCP "
        + "config, or a password manager\u{2019}s export. Next Term reads it, and changes only an MCP config, once you "
        + "choose the keys to move out of it."

    #if DEBUG
    /// The self-test's stand-in for the open panel: the file it picks.
    static var pickedForSelfTest: URL?
    #endif

    /// The pull-down: its title, then A File… and MCP Configs…, then the password managers (1Password…, Bitwarden…,
    /// Bitwarden Secrets Manager…), whose CLI the user runs in a new tab. Its titles are the Secrets menu's Import From's.
    func configureImportMenu() {
        importMenuButton.removeAllItems()
        importMenuButton.addItem(withTitle: SecretsMenuModel.importTitle)
        let items: [(String, Selector)] = [(SecretsMenuModel.importFileTitle, #selector(importFromFile)),
                                           (SecretsMenuModel.importMCPTitle, #selector(importKeys))]
        for (title, action) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            importMenuButton.menu?.addItem(item)
        }
        importMenuButton.menu?.addItem(.separator())
        for preset in SecretImportPreset.allCases {
            let item = NSMenuItem(title: SecretsMenuModel.managerTitle(preset), action: #selector(importFromManager(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
            importMenuButton.menu?.addItem(item)
        }
        importMenuButton.bezelStyle = .rounded
        importMenuButton.setAccessibilityLabel(SecretsMenuModel.importTitle)
    }

    /// A password manager's sheet: what runs, its line, and Open in a New Tab.
    @objc func importFromManager(_ sender: NSMenuItem) {
        guard !hasOpenSheet, let window, let name = sender.representedObject as? String,
              let preset = SecretImportPreset(rawValue: name) else { return }
        let sheet = SecretManagerImportSheet(preset: preset, say: { [weak self] (line: String) in
            self?.say(line)
        }, done: { [weak self] in
            self?.managerSheet = nil
        })
        managerSheet = sheet
        sheet.begin(on: window)
    }

    /// The open panel, as a sheet on the list's window; any file, never a folder or a package.
    @objc func importFromFile() {
        guard !hasOpenSheet, let window else { return }
        #if DEBUG
        if let picked = Self.pickedForSelfTest { return readPicked(picked) }
        #endif
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.showsHiddenFiles = true
        panel.message = Self.panelMessage
        panel.prompt = "Read File"
        panel.beginSheetModal(for: window) { [weak self] (response: NSApplication.ModalResponse) in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                self?.readPicked(url)
            }
        }
    }

    /// A file read for an import: what it is for, its path with links followed, and whether a git work tree holds it.
    struct PickedRead: Sendable {
        let picked: SecretSources.Picked
        let path: String
        let inGit: Bool
    }

    /// The file at `url` read off the main thread (a file near the limits takes seconds), against the vault's names and
    /// the open projects as they are now. `format` is `nxtrm secret import`'s.
    static func read(_ url: URL, format: SecretSources.Format? = nil) async -> PickedRead {
        let setup: SecretImportSheet.Setup = importSetup()
        let home: String = setup.home
        let projects: [String] = setup.projects
        let stored: Set<String> = Set(SecretsStore.shared.index?.names ?? [])
        // As picked for the move import's check (a project's linked .mcp.json is still its own), then links followed.
        let chosen: String = url.path
        let path: String = canonicalPath(chosen)
        return await Task.detached { () -> PickedRead in
            let picked = SecretSources.readPicked(chosen, home: home, projects: projects, stored: stored, format: format)
            return PickedRead(picked: picked, path: path, inGit: SecretImport.isInGitWorkTree(path))
        }.value
    }

    /// The picked file read off the main thread, the line under the list saying so meanwhile, then its sheet. `format`
    /// and `client` are `nxtrm secret import`'s, run by the user in a tab of their own: the format it named, and the
    /// importer waiting to hear how it ends. Any other run of it has its file read before Secrets comes forward, and
    /// opens its sheet with `openPicked`.
    func readPicked(_ url: URL, format: SecretSources.Format? = nil, client: SecretImportClient? = nil) {
        say("Reading \(url.lastPathComponent)\u{2026}")
        Task { @MainActor in
            let read: PickedRead = await Self.read(url, format: format)
            self.say("")
            self.openPicked(read.picked, path: read.path, inGit: read.inGit, client: client)
        }
    }

    /// The sheet for a file as read: the copy sheet, or the MCP-config import for a file it rewrites, which only the
    /// user starts (the user's pick, or nxtrm secret import run in a tab of their own).
    func openPicked(_ picked: SecretSources.Picked, path: String, inGit: Bool, client: SecretImportClient? = nil) {
        switch picked {
        case .copy(let report):
            openFileImport(path: path, report: report, inGit: inGit, client: client)
        case .move(let source, let rest):
            if let client, !client.origin.runner.mayStartMove { return client.end(.moveRefused) }
            // A sheet opened while the file was read: nothing opens behind it, and the importer hears so.
            guard !hasOpenSheet else { return sayBusy(client: client) }
            // The MCP-config import asks its own way: the importer is told that, and goes.
            client?.end(.moved)
            openMoveImport(only: source) { [weak self] in
                // Keys outside its servers that couldn't be listed, such as more than the sheet lists: the line under
                // the list says so, instead of nothing.
                if let unreadable = rest.unreadable {
                    self?.say(Self.outsideServersUnlistedLine + " " + unreadable.sentence)
                    return
                }
                guard !rest.rows.isEmpty else { return }
                // After the move sheet has gone: the keys outside its servers, to copy in. The sheet checks them
                // against the keys the move just stored.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.openFileImport(path: path, report: rest, outsideServers: true, inGit: inGit)
                    }
                }
            }
        }
    }

    /// The copy sheet for `report`. When it closes, the list says what it did and may open Rotate… for a key. `client`
    /// is `nxtrm secret import`'s importer, told when the sheet opens and how it ends; `busy` when any sheet is open
    /// (a sheet begun then would wait unseen behind it). `asked` is an agent's import_secrets request: the sheet shows
    /// its banner and answers it. A sheet an agent asked for, by that request or by running nxtrm secret import, has no
    /// Return default and leaves the keyboard where it was; so does one for nxtrm secret import run where Next Term
    /// can't tell which tab ran it.
    func openFileImport(path: String, report: SourceReport, outsideServers: Bool = false, inGit: Bool,
                        client: SecretImportClient? = nil, asked: SecretImportAsk? = nil) {
        guard !hasOpenSheet, let window else { return sayBusy(client: client, asked: asked) }
        let sheet = SecretFileImportSheet(path: path, report: report, outsideServers: outsideServers, inGit: inGit,
                                          client: client) { [weak self] (ending: SecretFileImportSheet.Ending) in
            guard let self else { return }
            self.fileImportSheet = nil
            self.reload()
            if let said = ending.said { self.say(said) }
            guard let name = ending.rotate else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { _ = self.openRotate(named: name) }
            }
        }
        fileImportSheet = sheet
        // nxtrm secret import run by an agent, or by a process no tab of Next Term's is above, is handled as an agent's.
        let runner: SecretImportPipe.Runner? = client?.origin.runner
        let agentRan: Bool = runner.map { (who: SecretImportPipe.Runner) -> Bool in !who.isUser } ?? false
        if let asked {
            sheet.asked = asked
            asked.showing(sheet)
        } else if agentRan {
            // As for an agent's import_secrets, Import… answers only a click.
            SecretImportAsk.noReturnKey(action: sheet.importButton, cancel: sheet.cancelButton)
        }
        sheet.begin(on: window, keepingKeyboard: asked != nil || agentRan)
        if let report = sheet.report { client?.opened(report) }
    }
}

extension SecretsView {
    /// For a file the user picked: a sheet opened while it was read.
    static let pickBusyLine = "Finish what\u{2019}s open here, then choose the file again."
    /// After the MCP-config import of a file whose keys outside its servers couldn't be listed; the reason follows.
    static let outsideServersUnlistedLine = "Next Term didn\u{2019}t list the keys outside the file\u{2019}s MCP "
        + "servers."

    /// Nothing opens while a sheet is open: the line under the list says who asked, and the importer or the agent's
    /// request hears `busy`.
    func sayBusy(client: SecretImportClient?, asked: SecretImportAsk? = nil) {
        if client != nil {
            say(SecretPipeImport.busyLine)
        } else if asked != nil {
            say(SecretImportAsk.busyLine)
        } else {
            say(Self.pickBusyLine)
        }
        client?.end(.busy)
        asked?.end(.busy)
    }
}

// MARK: Recent imports: copy-ins

extension SecretsView {
    /// A row per copy-in of the last 30 days, with its Undo….
    func addCopyInRows(_ records: [SecretCopyIn.Record]) {
        for record in records {
            let undo = NSButton(title: "Undo\u{2026}", target: self, action: #selector(undoCopyIn(_:)))
            undo.bezelStyle = .rounded
            undo.identifier = NSUserInterfaceItemIdentifier("copy-" + record.id)
            let text: String = SecretCopyIn.recentText(record, day: SecretRequests.dayText(record.date))
            let label = SecretApprovalPanel.label(text, size: 12)
            label.preferredMaxLayoutWidth = 420
            let row = NSStackView(views: [label, NSView(), undo])
            row.spacing = 8
            importsBox.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: importsBox.widthAnchor).isActive = true
            copyInRows.append((record, undo))
        }
    }

    /// Asks first: which keys go, which stay and why. The file they came from is not touched.
    @objc func undoCopyIn(_ sender: NSButton) {
        let id: String = String((sender.identifier?.rawValue ?? "").dropFirst("copy-".count))
        let found = copyInRows.first { (row: (record: SecretCopyIn.Record, undo: NSButton)) -> Bool in
            row.record.id == id
        }
        guard let record = found?.record, alert == nil else { return }
        // Keys a later MCP-config move's entries start with stay, and the confirm says so.
        let inUse: Set<String> = SecretsStore.shared.namesMovesUse()
        let plan: SecretCopyIn.UndoPlan = SecretCopyIn.undoPlan(record, index: SecretsStore.shared.index,
                                                                usedElsewhere: inUse)
        let count: Int = plan.deletes.count
        // Nothing to delete while a move's entries start with a key it added: the record stays, so this Undo can delete
        // that key once the move is undone.
        let waits: Bool = count == 0 && !plan.inUse.isEmpty
        let alert = NSAlert()
        let keys: String = "\(count) \(count == 1 ? "key" : "keys")"
        let none: String = waits ? "Nothing to delete yet" : "Nothing to delete"
        alert.messageText = count == 0 ? none : "Delete \(keys) this import copied in?"
        var lines: [String] = plan.deletes.map { (name: String) -> String in "\u{2022} " + name }
        if let kept = plan.keptText { lines.append("\n" + kept) }
        lines.append("\nThe file they came from isn\u{2019}t changed.")
        alert.informativeText = lines.joined(separator: "\n")
        if waits {
            alert.addButton(withTitle: "OK")
        } else {
            alert.addButton(withTitle: count == 0 ? "Remove from List" : "Delete Keys").hasDestructiveAction = count > 0
            alert.addButton(withTitle: "Cancel")
        }
        confirm(alert) { [weak self] in
            guard !waits else { return }
            guard count > 0 else { return SecretsStore.shared.removeCopyIn(record) }
            self?.undoCopy(record, inUse: inUse)
        }
    }

    /// One Touch ID, then the keys deleted; the line under the list says what went and what stayed. `inUse` names the
    /// keys the confirm said stay, as other entries start with them.
    func undoCopy(_ record: SecretCopyIn.Record, inUse: Set<String> = []) {
        Task { @MainActor in
            do {
                let plan = try await SecretsStore.shared.performCopyInUndo(record, inUse: inUse)
                self.say(plan.text)
            } catch SecretsStore.Failure.cancelled {
                self.say("Not approved.")
            } catch {
                self.say((error as? LocalizedError)?.errorDescription ?? "Next Term couldn\u{2019}t delete the keys.")
            }
            self.reload()
        }
    }
}
