import AppKit
import NextTermCore

/// Settings › MCP Servers › Paste a Config…: the `mcpServers` block from a server's README, one server or several
/// (MCPHubPaste reads it as it is typed). The sheet shows what it found: each server, what it runs, and each key in it,
/// or each key it asks for, with the name it gets in Secrets. Add copies the keys into Secrets as Secrets' own import
/// does (one confirm, one Touch ID, its Undo in Recent imports), then adds the servers with the keys as references
/// (R13). A key that can't be taken out for the user (in an argument, in a URL) keeps its server out until it is fixed.
///
/// A server found in an agent's own config (Found in your agents, or the new-server offer) opens the same sheet with that
/// server in place of the text (`preset`): its keys go the same way, and the agent's file stays as it is.
final class MCPPasteSheet: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    static let title = "Paste a Config"
    static let intro = "Paste the mcpServers block from a server\u{2019}s README. Any key in it goes to Secrets, never into Next Term\u{2019}s list."

    let done: (_ said: String?) -> Void
    let textView = NSTextView()
    let status = NSTextField(wrappingLabelWithString: "")
    let foundStack = NSStackView()
    let appliesPopUp = NSPopUpButton()
    let addButton = NSButton(title: "Add", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let project: String?
    /// The server from an agent's config the sheet adds, instead of pasted text.
    let preset: MCPHubAgents.Server?
    private(set) var found: [MCPHubPaste.Found] = []
    /// Each server's name field, and each key's name and value fields, in `found`'s order.
    private(set) var nameFields: [NSTextField] = []
    private(set) var keyFields: [[(name: NSTextField, value: NSSecureTextField?)]] = []
    var confirmAlert: NSAlert?
    private(set) var isBusy = false

    init(project: String?, preset: MCPHubAgents.Server? = nil, done: @escaping (_ said: String?) -> Void) {
        self.project = preset?.project ?? project
        self.preset = preset
        self.done = done
        // With no text to paste, the sheet is the server and its keys alone.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: preset == nil ? 520 : 340), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: preset == nil ? 420 : 300)
        super.init(window: window)
        window.delegate = self
        build()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: building

    private func build() {
        guard let view = window?.contentView else { return }
        let heading = SecretApprovalPanel.label(preset.map { "Add \u{201C}\($0.pastedName)\u{201D}" } ?? Self.title, size: 14, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: preset.map(Self.presetIntro) ?? Self.intro)
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor

        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.delegate = self
        textView.setAccessibilityLabel("The config")
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        let textScroll = NSScrollView()
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .bezelBorder

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        foundStack.orientation = .vertical
        foundStack.alignment = .leading
        foundStack.spacing = 6
        // Room for the fields' bezels and focus rings, which the scroll view would otherwise clip at its edge.
        foundStack.edgeInsets = NSEdgeInsets(top: 2, left: 3, bottom: 2, right: 3)
        let foundScroll = NSScrollView()
        let flipped = PasteFlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        foundStack.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(foundStack)
        foundScroll.documentView = flipped
        foundScroll.hasVerticalScroller = true
        foundScroll.drawsBackground = false
        NSLayoutConstraint.activate([
            foundStack.topAnchor.constraint(equalTo: flipped.topAnchor),
            foundStack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            foundStack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            foundStack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            flipped.widthAnchor.constraint(equalTo: foundScroll.contentView.widthAnchor),
        ])

        appliesPopUp.addItem(withTitle: "All projects")
        appliesPopUp.lastItem?.representedObject = "all"
        var folders = MCPServersSettingsView.openProjects()
        if let project, let at = folders.firstIndex(of: project) { folders.insert(folders.remove(at: at), at: 0) }
        // A server an agent has for one project, in a project not open now: that project is offered first all the same.
        if let project, !folders.contains(project) { folders.insert(project, at: 0) }
        for folder in folders {
            appliesPopUp.addItem(withTitle: "Only in " + ProjectSkillsView.title(folder))
            appliesPopUp.lastItem?.representedObject = folder
        }
        if let project, let item = appliesPopUp.itemArray.first(where: { $0.representedObject as? String == project }) { appliesPopUp.select(item) }
        let applies = NSStackView(views: [NSTextField(labelWithString: "Applies to"), appliesPopUp])
        applies.spacing = 8

        addButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
        for (button, action) in [(addButton, #selector(confirm)), (cancelButton, #selector(cancel))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        let buttons = NSStackView(views: [applies, NSView(), cancelButton, addButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [heading, intro, textScroll, status, foundScroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        textScroll.isHidden = preset != nil
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            textScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            textScroll.heightAnchor.constraint(equalToConstant: preset == nil ? 140 : 0),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            foundScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            foundScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
    }

    // MARK: reading

    func textDidChange(_ notification: Notification) { refresh() }

    func controlTextDidChange(_ notification: Notification) { updateButton() }

    /// The text as pasted, read again; the rows are made again only when what it found changed, so names and keys
    /// typed in them stay.
    func refresh() {
        let text = textView.string
        guard preset != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            show([])
            status.stringValue = ""
            return updateButton()
        }
        let read = preset.map { Result<[MCPHubPaste.Found], MCPHubPaste.Problem>.success([$0.found]) }
            ?? MCPHubPaste.read(text, stored: Set(MCPServerSheet.storedKeys))
        switch read {
        case .failure(let problem):
            show([])
            status.stringValue = problem.sentence
            status.textColor = .systemOrange
        case .success(let servers):
            if servers != found { show(servers) }
            let keys = servers.reduce(0) { $0 + $1.keys.count }
            var line = "Found \(servers.count) \(servers.count == 1 ? "server" : "servers")"
            line += keys == 0 ? "." : ", and \(keys) \(keys == 1 ? "key" : "keys") for Secrets."
            status.stringValue = line
            status.textColor = .secondaryLabelColor
        }
        updateButton()
    }

    private func show(_ servers: [MCPHubPaste.Found]) {
        found = servers
        foundStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        nameFields = []
        keyFields = []
        let stored = Set(MCPServerSheet.storedKeys)
        for server in servers {
            let name = NSTextField(string: server.name)
            name.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            name.delegate = self
            name.setAccessibilityLabel("Server name")
            name.widthAnchor.constraint(equalToConstant: 160).isActive = true
            let runs = NSTextField(labelWithString: (try? server.server().get()).map(MCPHubOverview.runsText) ?? "")
            runs.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            runs.textColor = .secondaryLabelColor
            runs.lineBreakMode = .byTruncatingMiddle
            runs.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            foundStack.addArrangedSubview(NSStackView(views: [name, runs]))
            nameFields.append(name)
            var fields: [(NSTextField, NSSecureTextField?)] = []
            for key in server.keys {
                let place = NSTextField(labelWithString: key.whereText)
                place.font = .systemFont(ofSize: 11)
                place.widthAnchor.constraint(equalToConstant: 170).isActive = true
                place.lineBreakMode = .byTruncatingMiddle
                let keyName = NSTextField(string: key.name)
                keyName.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                keyName.delegate = self
                keyName.setAccessibilityLabel("Its name in Secrets")
                keyName.widthAnchor.constraint(equalToConstant: 170).isActive = true
                var views: [NSView] = [NSView(), place, NSTextField(labelWithString: "\u{2192}"), keyName]
                views[0].widthAnchor.constraint(equalToConstant: 8).isActive = true
                var value: NSSecureTextField?
                if let kind = key.kind {
                    let what = NSTextField(labelWithString: "\(kind), from the config")
                    what.font = .systemFont(ofSize: 11)
                    what.textColor = .secondaryLabelColor
                    views.append(what)
                } else {
                    let field = NSSecureTextField()
                    field.placeholderString = stored.contains(key.name) ? "Uses your stored key" : "Paste the key"
                    field.delegate = self
                    field.setAccessibilityLabel("The key, hidden")
                    field.widthAnchor.constraint(equalToConstant: 150).isActive = true
                    views.append(field)
                    value = field
                }
                let row = NSStackView(views: views)
                row.spacing = 6
                foundStack.addArrangedSubview(row)
                fields.append((keyName, value))
            }
            keyFields.append(fields)
            for reason in server.stuck {
                let line = NSTextField(wrappingLabelWithString: reason)
                line.font = .systemFont(ofSize: 11)
                line.textColor = .systemOrange
                line.preferredMaxLayoutWidth = 520
                foundStack.addArrangedSubview(line)
            }
        }
    }

    /// The intro for a server from an agent's config: whose it is, and that their file stays as it is.
    static func presetIntro(_ server: MCPHubAgents.Server) -> String {
        let whose = server.agents.count == 1 ? "\(server.agentsText)\u{2019}s config" : "the configs of \(server.agentsText)"
        return "From \(whose), which stays as it is. Any key in it goes to Secrets, never into Next Term\u{2019}s list."
    }

    // MARK: what it would add

    /// The servers as the rows have them now: names and keys' names as typed.
    var edited: [MCPHubPaste.Found] {
        found.enumerated().map { index, server in
            var server = server
            if nameFields.indices.contains(index) { server.name = nameFields[index].stringValue.trimmingCharacters(in: .whitespaces) }
            for (at, fields) in (keyFields.indices.contains(index) ? keyFields[index] : []).enumerated() where server.keys.indices.contains(at) {
                server.keys[at].name = fields.name.stringValue.trimmingCharacters(in: .whitespaces)
            }
            return server
        }
    }

    var projects: MCPHubServer.Projects {
        guard let folder = appliesPopUp.selectedItem?.representedObject as? String, folder != "all" else { return .all }
        return .only([folder])
    }

    /// The keys to copy into Secrets: each pasted, or typed for one the config asked for. A key it asked for and left
    /// empty is the stored one of its name.
    var planned: [SecretCopyIn.Planned] {
        let servers = edited
        var out: [SecretCopyIn.Planned] = []
        for (index, server) in servers.enumerated() {
            for (at, key) in server.keys.enumerated() {
                let typed = keyFields[index][at].value?.stringValue ?? ""
                guard let value = key.value ?? (typed.isEmpty ? nil : SecretBytes(utf8: typed)) else { continue }
                out.append(SecretCopyIn.Planned(name: key.name, value: value, purpose: MCPServerSheet.purpose(server.name), replaces: false))
            }
        }
        return out
    }

    /// Why Add can't go on now, or nil.
    var reason: String? {
        guard !found.isEmpty else { return "" }
        let servers = edited
        let stored = Set(MCPServerSheet.storedKeys)
        let taken = Set(MCPServerSheet.names(in: MCPHubEdits.userFile))
        var names = Set<String>(), keyNames = Set<String>()
        for (index, server) in servers.enumerated() {
            if !server.stuck.isEmpty { return "Fix what\u{2019}s marked, then paste again." }
            if taken.contains(server.name) { return "A server named \(server.name) is in your list already." }
            if !names.insert(server.name).inserted { return "Two servers here are named \(server.name)." }
            for (at, key) in server.keys.enumerated() {
                guard StoredSecretName.isValid(key.name) else { return "\(key.name): " + StoredSecretName.rule }
                let typed = keyFields[index][at].value?.stringValue ?? ""
                let given = key.value != nil || !typed.isEmpty
                if given, stored.contains(key.name) { return "\(key.name) is in Secrets already: give the key another name." }
                if !given, !stored.contains(key.name) { return "" }
                if given, !keyNames.insert(key.name).inserted { return "Two keys here are named \(key.name)." }
            }
            var withProjects: MCPHubServer
            switch server.server() {
            case .failure(let broken): return "\(server.name): " + broken.reasons.joined(separator: " ")
            case .success(let made): withProjects = made
            }
            withProjects.projects = projects
            let reasons = MCPHubRules.reasons(withProjects, place: .user)
            if !reasons.isEmpty { return "\(server.name): " + reasons.joined(separator: " ") }
        }
        if !planned.isEmpty, !AppDelegate.shared.agentControl { return SecretImportSheet.refusal }
        return nil
    }

    private func updateButton() {
        let count = found.count
        addButton.title = count > 1 ? "Add \(count) Servers" : "Add"
        let why = reason
        addButton.isEnabled = why == nil && !isBusy
        if let why, !why.isEmpty, !found.isEmpty {
            status.stringValue = why
            status.textColor = .systemOrange
        }
    }

    // MARK: acting

    @objc func cancel() { end(nil) }

    /// Add: the keys first, after one confirm (as Secrets' own import asks), then every server in one change.
    @objc func confirm() {
        guard reason == nil, !isBusy, let window else { return updateButton() }
        let planned = planned
        guard !planned.isEmpty else { return add() }
        let alert = NSAlert()
        alert.messageText = "Copy \(planned.count) \(planned.count == 1 ? "key" : "keys") into Secrets?"
        alert.informativeText = SecretFileImportSheet.confirmText(planned, file: nil)
        alert.addButton(withTitle: planned.count == 1 ? "Copy Key and Add" : "Copy Keys and Add")
        alert.addButton(withTitle: "Cancel")
        confirmAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.confirmAlert = nil
                guard response == .alertFirstButtonReturn else { return }
                self.isBusy = true
                self.updateButton()
                Task { @MainActor in
                    let from = self.preset.map { "\($0.agentsText)\u{2019}s MCP config" } ?? "a pasted MCP config"
                    let failure = await MCPServerSheet.copyIn(planned, reason: SecretReason.copyIn(planned.count, from: from))
                    self.isBusy = false
                    if let failure {
                        self.status.stringValue = failure
                        self.status.textColor = .systemOrange
                        return self.updateButton()
                    }
                    self.add()
                }
            }
        }
    }

    /// The servers, with their keys as references, added to the user's list in one change.
    private func add() {
        var steps: [MCPHubEdits.Step] = []
        let projects = projects
        for found in edited {
            guard case .success(var server) = found.server() else { continue }
            server.projects = projects
            steps.append(.init(change: .set(server), file: MCPHubEdits.userFile, place: .user))
        }
        let names = steps.compactMap { step -> String? in if case .set(let server) = step.change { return server.name }; return nil }
        end(MCPHubEdits.apply(names.count == 1 ? "Add \(names[0])" : "Add \(names.count) servers", steps))
    }

    func end(_ said: String?) {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
        done(said)
    }
}

/// The found list's document view, its rows from the top.
private final class PasteFlippedView: NSView {
    override var isFlipped: Bool { true }
}
