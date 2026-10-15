import AppKit
import NextTermCore

/// Import From › A File… in the list: the open panel (the user's pick is the consent), the file read off the main
/// thread, and the sheet for it. A file the MCP-config import rewrites opens that import for the file alone, with its
/// own explanation, since it changes the file; the keys outside its servers then open in the copy sheet. Unlike that
/// import, a copy needs no "Let agents control Next Term": nothing is rewritten to start through it.
extension SecretsView {
    static let importMenuTitle = "Import From"
    static let fileItemTitle = "A File\u{2026}"
    static let mcpItemTitle = "MCP Configs\u{2026}"
    static let panelMessage = "Choose a file of keys: a .env file, a JSON, TOML or YAML config, an agent\u{2019}s MCP "
        + "config, or a password manager\u{2019}s export. Next Term reads it and doesn\u{2019}t change it."

    #if DEBUG
    /// The self-test's stand-in for the open panel: the file it picks.
    static var pickedForSelfTest: URL?
    #endif

    /// The pull-down: its title, then A File… and MCP Configs…, then the password managers (1Password…, Bitwarden…,
    /// Bitwarden Secrets Manager…), whose CLI the user runs in a new tab.
    func configureImportMenu() {
        importMenuButton.removeAllItems()
        importMenuButton.addItem(withTitle: Self.importMenuTitle)
        let items: [(String, Selector)] = [(Self.fileItemTitle, #selector(importFromFile)),
                                           (Self.mcpItemTitle, #selector(importKeys))]
        for (title, action) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            importMenuButton.menu?.addItem(item)
        }
        importMenuButton.menu?.addItem(.separator())
        for preset in SecretImportPreset.allCases {
            let item = NSMenuItem(title: Self.managerItemTitle(preset), action: #selector(importFromManager(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
            importMenuButton.menu?.addItem(item)
        }
        importMenuButton.bezelStyle = .rounded
        importMenuButton.setAccessibilityLabel("Import From")
    }

    /// "1Password…", "Bitwarden…", "Bitwarden Secrets Manager…".
    static func managerItemTitle(_ preset: SecretImportPreset) -> String { preset.app + "\u{2026}" }

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

    /// The picked file read off the main thread (a file near the limits takes seconds), then its sheet. `format` and
    /// `client` are `nxtrm secret import`'s: the format it named, and the importer waiting to hear how it ends.
    func readPicked(_ url: URL, format: SecretSources.Format? = nil, client: SecretImportClient? = nil) {
        let setup: SecretImportSheet.Setup = Self.importSetup()
        let home: String = setup.home
        let projects: [String] = setup.projects
        let stored: Set<String> = Set(SecretsStore.shared.index?.names ?? [])
        // As picked for the move import's check (a project's linked .mcp.json is still its own), then links followed.
        let chosen: String = url.path
        let path: String = canonicalPath(chosen)
        say("Reading \(url.lastPathComponent)\u{2026}")
        Task { @MainActor in
            let read = await Task.detached { () -> (picked: SecretSources.Picked, inGit: Bool) in
                let picked = SecretSources.readPicked(chosen, home: home, projects: projects, stored: stored,
                                                      format: format)
                return (picked, SecretImport.isInGitWorkTree(path))
            }.value
            self.say("")
            switch read.picked {
            case .copy(let report):
                self.openFileImport(path: path, report: report, inGit: read.inGit, client: client)
            case .move(let source, let rest):
                // The MCP-config import asks its own way: the importer is told that, and goes.
                client?.end(self.hasOpenSheet ? .busy : .moved)
                self.openMoveImport(only: source) { [weak self] in
                    guard !rest.rows.isEmpty else { return }
                    // After the move sheet has gone: the keys outside its servers, to copy in. The sheet checks
                    // them against the keys the move just stored.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self?.openFileImport(path: path, report: rest, outsideServers: true, inGit: read.inGit)
                        }
                    }
                }
            }
        }
    }

    /// The copy sheet for `report`. When it closes, the list says what it did and may open Rotate… for a key. `client`
    /// is `nxtrm secret import`'s importer, told when the sheet opens and how it ends; `busy` when another is open.
    func openFileImport(path: String, report: SourceReport, outsideServers: Bool = false, inGit: Bool,
                        client: SecretImportClient? = nil) {
        guard fileImportSheet == nil, let window else {
            client?.end(.busy)
            return
        }
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
        sheet.begin(on: window)
        if let report = sheet.report { client?.opened(report) }
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
        let plan: SecretCopyIn.UndoPlan = SecretCopyIn.undoPlan(record, index: SecretsStore.shared.index)
        let count: Int = plan.deletes.count
        let alert = NSAlert()
        let keys: String = "\(count) \(count == 1 ? "key" : "keys")"
        alert.messageText = count == 0 ? "Nothing to delete" : "Delete \(keys) this import copied in?"
        var lines: [String] = plan.deletes.map { (name: String) -> String in "\u{2022} " + name }
        if let kept = plan.keptText { lines.append("\n" + kept) }
        lines.append("\nThe file they came from isn\u{2019}t changed.")
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: count == 0 ? "Remove from List" : "Delete Keys").hasDestructiveAction = count > 0
        alert.addButton(withTitle: "Cancel")
        confirm(alert) { [weak self] in
            guard count > 0 else { return SecretsStore.shared.removeCopyIn(record) }
            self?.undoCopy(record)
        }
    }

    /// One Touch ID, then the keys deleted; the line under the list says what went and what stayed.
    func undoCopy(_ record: SecretCopyIn.Record) {
        Task { @MainActor in
            do {
                let plan = try await SecretsStore.shared.performCopyInUndo(record)
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
