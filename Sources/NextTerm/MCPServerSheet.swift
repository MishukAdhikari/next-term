import AppKit
import NextTermCore

/// Settings › MCP Servers › Add Server… and Edit…: one sheet. A name; what it runs, a command or a URL; a key, picked
/// from Secrets or given here, which goes into Secrets and never into the list (R13): a command gets it through
/// `nxtrm secret run`, a URL as `Authorization: Bearer ${secret:NAME}`, which only the app fills in. And where it
/// applies: every project, one project, or a project's own list for its team. Add is the one primary button.
///
/// Editing changes only what the sheet shows: the entry's other keys, its other keys from Secrets and its variables stay
/// as written (MCPHubServer.merged).
final class MCPServerSheet: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    /// Where a server goes, as the Applies to menu lists them.
    enum Target: Equatable {
        case all
        case only(String)
        /// The project's own `.next-term/mcp.json`, for its team.
        case team(String)
        /// The several folders an entry names already, kept as they are.
        case kept
    }

    static let noKey = "None"
    static let newKey = "New Key\u{2026}"

    let editing: MCPHubOverview.Row?
    let done: (_ said: String?) -> Void
    let nameField = NSTextField()
    let kind = NSSegmentedControl(labels: ["Command", "URL"], trackingMode: .selectOne, target: nil, action: nil)
    let runsField = NSTextField()
    let keyPopUp = NSPopUpButton()
    let newKeyName = NSTextField()
    let newKeyValue = NSSecureTextField()
    let variableField = NSTextField()
    let variableCaption = NSTextField(labelWithString: "Passed as")
    let sentAs = NSTextField(labelWithString: "Sent as Authorization: Bearer, filled in by Next Term.")
    let appliesPopUp = NSPopUpButton()
    let reasonLabel = NSTextField(wrappingLabelWithString: "")
    let addButton = NSButton(title: "Add", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let pasteButton = NSButton(title: "Paste a Config\u{2026}", target: nil, action: nil)
    private var newKeyRow = NSStackView()
    private var variableRow = NSStackView()
    private var form = NSStackView()
    private let project: String?
    private(set) var isBusy = false

    /// `editing`: the row of the server to change; nil adds one. `project`: the one Project shows, offered first.
    init(editing: MCPHubOverview.Row?, project: String?, done: @escaping (_ said: String?) -> Void) {
        self.editing = editing
        self.project = project
        self.done = done
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 340), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        fill()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var title: String { editing.map { "Edit \u{201C}\($0.name)\u{201D}" } ?? "Add an MCP Server" }

    // MARK: building

    private func build() {
        guard let view = window?.contentView else { return }
        let heading = SecretApprovalPanel.label(title, size: 14, weight: .semibold)
        nameField.placeholderString = "github"
        runsField.placeholderString = "npx -y @modelcontextprotocol/server-github"
        newKeyName.placeholderString = "GITHUB_TOKEN"
        newKeyValue.placeholderString = "Paste or type the key"
        variableField.placeholderString = "GITHUB_PERSONAL_ACCESS_TOKEN"
        for field in [nameField, runsField, newKeyName, variableField] {
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.delegate = self
            // One line: a long command keeps its start and its end, never a first line cut at a slash.
            field.usesSingleLineMode = true
            field.cell?.wraps = false
            field.lineBreakMode = .byTruncatingMiddle
        }
        newKeyValue.delegate = self
        nameField.setAccessibilityLabel("Name")
        runsField.setAccessibilityLabel("Command or URL")
        newKeyName.setAccessibilityLabel("The new key's name")
        newKeyValue.setAccessibilityLabel("The new key, hidden")
        variableField.setAccessibilityLabel("The variable the server reads it as")
        kind.selectedSegment = 0
        kind.target = self
        kind.action = #selector(changed)
        keyPopUp.target = self
        keyPopUp.action = #selector(changed)
        appliesPopUp.target = self
        appliesPopUp.action = #selector(changed)
        for label in [sentAs, reasonLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        reasonLabel.textColor = .systemOrange
        reasonLabel.preferredMaxLayoutWidth = 470

        func row(_ caption: String, _ control: NSView) -> NSStackView {
            let label = NSTextField(labelWithString: caption)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 80).isActive = true
            let stack = NSStackView(views: [label, control])
            stack.spacing = 8
            return stack
        }
        variableCaption.alignment = .right
        variableCaption.widthAnchor.constraint(equalToConstant: 80).isActive = true
        newKeyRow = NSStackView(views: [NSView(), newKeyName, newKeyValue])
        newKeyRow.spacing = 8
        newKeyRow.views.first?.widthAnchor.constraint(equalToConstant: 80).isActive = true
        variableRow = NSStackView(views: [variableCaption, variableField, sentAs])
        variableRow.spacing = 8

        addButton.title = editing == nil ? "Add" : "Save"
        addButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
        for (button, action) in [(addButton, #selector(confirm)), (cancelButton, #selector(cancel)), (pasteButton, #selector(pasteInstead))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        pasteButton.isHidden = editing != nil
        let buttons = NSStackView(views: [pasteButton, NSView(), cancelButton, addButton])
        buttons.spacing = 8

        let stack = form
        stack.setViews([heading, row("Name", nameField), row("Runs", kind), row("", runsField), row("Key", keyPopUp),
                                        newKeyRow, variableRow, row("Applies to", appliesPopUp), reasonLabel, buttons], in: .top)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: heading)
        stack.setCustomSpacing(16, after: reasonLabel)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            nameField.widthAnchor.constraint(equalToConstant: 200),
            runsField.widthAnchor.constraint(equalToConstant: 392),
            newKeyName.widthAnchor.constraint(equalToConstant: 180),
            newKeyValue.widthAnchor.constraint(equalToConstant: 204),
            variableField.widthAnchor.constraint(equalToConstant: 260),
        ])
    }

    /// The keys stored in Secrets, by name.
    static var storedKeys: [String] { (SecretsStore.shared.index?.names ?? []).sorted() }

    /// The fields from the server being edited, and the menus' items.
    private func fill() {
        let server = editing?.server
        nameField.stringValue = server?.name ?? ""
        var keyName: String?
        if let server {
            kind.selectedSegment = server.transport == .stdio ? 0 : 1
            if server.transport == .stdio {
                let found = MCPHubOverview.keys(of: server)
                runsField.stringValue = found.inner.map(ShellQuote.quote).joined(separator: " ")
                keyName = found.keys.first?.name
                variableField.stringValue = found.keys.first?.variable ?? ""
            } else {
                runsField.stringValue = server.url
                keyName = server.headers["Authorization"].flatMap { MCPHubRules.secretNames(in: $0).first }
            }
        }
        keyPopUp.removeAllItems()
        keyPopUp.addItem(withTitle: Self.noKey)
        let stored = Self.storedKeys
        if !stored.isEmpty { keyPopUp.menu?.addItem(.separator()) }
        for name in stored { keyPopUp.addItem(withTitle: name) }
        if let keyName, !stored.contains(keyName) { keyPopUp.addItem(withTitle: keyName) } // named, not stored (yet)
        keyPopUp.menu?.addItem(.separator())
        keyPopUp.addItem(withTitle: Self.newKey)
        keyPopUp.selectItem(withTitle: keyName ?? Self.noKey)

        appliesPopUp.removeAllItems()
        func item(_ title: String, _ target: Target) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = target.represented
            appliesPopUp.menu?.addItem(item)
        }
        if let editing, editing.place == .project {
            let top = Self.top(of: editing.list)
            item(ProjectSkillsView.title(top) + "\u{2019}s list, for its team", .team(top))
            appliesPopUp.isEnabled = false
            return
        }
        item("All projects", .all)
        var folders = MCPServersSettingsView.openProjects()
        if let project, let at = folders.firstIndex(of: project) { folders.insert(folders.remove(at: at), at: 0) }
        if case .only(let listed)? = server?.projects {
            for folder in listed where !folders.contains(canonicalPath(folder)) { folders.append(folder) }
        }
        for folder in folders { item("Only in " + ProjectSkillsView.title(folder), .only(folder)) }
        if editing == nil, !folders.isEmpty {
            appliesPopUp.menu?.addItem(.separator())
            for folder in folders { item(ProjectSkillsView.title(folder) + "\u{2019}s list, for its team", .team(folder)) }
        }
        switch server?.projects {
        case .only(let listed)? where listed.count == 1: select(.only(canonicalPath(listed[0])))
        case .only(let listed)?:
            item(listed.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "), .kept)
            select(.kept)
        default: select(editing == nil ? project.map(Target.only) ?? .all : .all)
        }
    }

    private func select(_ target: Target) {
        if let item = appliesPopUp.itemArray.first(where: { $0.representedObject as? String == target.represented }) {
            appliesPopUp.select(item)
        }
    }

    /// The project folder a project's list is in.
    static func top(of list: String) -> String {
        ((list as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
    }

    // MARK: what it would save

    var isURL: Bool { kind.selectedSegment == 1 }
    var isNewKey: Bool { keyPopUp.titleOfSelectedItem == Self.newKey }

    /// The key picked or given, by name; nil for none.
    var keyName: String? {
        if isNewKey { return newKeyName.stringValue.isEmpty ? nil : newKeyName.stringValue }
        let title = keyPopUp.titleOfSelectedItem ?? Self.noKey
        return title == Self.noKey ? nil : title
    }

    var target: Target {
        Target(represented: appliesPopUp.selectedItem?.representedObject as? String ?? "") ?? .all
    }

    /// The list it goes in, and that list's place.
    var destination: (file: String, place: MCPHubFile.Place) {
        if let editing { return (editing.list, editing.place) }
        if case .team(let folder) = target { return (folder + "/" + MCPHubScope.projectFile, .project) }
        return (MCPHubEdits.userFile, .user)
    }

    /// The server the sheet describes now.
    var server: MCPHubServer {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        var server = editing?.server ?? MCPHubServer(name: name, transport: isURL ? .http : .stdio)
        server.name = name
        let typed = runsField.stringValue.trimmingCharacters(in: .whitespaces)
        if isURL {
            server.transport = server.transport == .stdio ? .http : server.transport
            server.command = ""
            server.args = []
            server.env = [:]
            server.url = typed
            if let keyName {
                server.headers["Authorization"] = "Bearer ${secret:\(keyName)}"
            } else if let old = server.headers["Authorization"], !MCPHubRules.secretNames(in: old).isEmpty {
                server.headers["Authorization"] = nil // the key picked in the sheet was taken away
            }
        } else {
            let old = editing?.server.map(MCPHubOverview.keys(of:))?.keys ?? []
            var keys = Array(old.dropFirst())
            if let keyName {
                let variable = variableField.stringValue.trimmingCharacters(in: .whitespaces)
                keys.insert((keyName, variable.isEmpty ? keyName : variable), at: 0)
            }
            let made = MCPHubOverview.wrapped(MCPHubOverview.words(typed), keys: keys)
            server.transport = .stdio
            server.command = made.command
            server.args = made.args
            server.url = ""
            server.headers = [:]
        }
        switch target {
        case .all: server.projects = .all
        case .only(let folder): server.projects = .only([folder])
        case .team: server.projects = .all
        case .kept: break
        }
        return server
    }

    /// Why it can't be saved as it is, or nil.
    var reason: String? {
        if runsField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        let server = server
        let list = destination
        if server.name.isEmpty { return "" }
        if server.name != editing?.name, Self.names(in: list.file).contains(server.name) {
            return "A server named \(server.name) is in that list already."
        }
        if isNewKey {
            guard StoredSecretName.isValid(newKeyName.stringValue) else { return StoredSecretName.rule }
            if Self.storedKeys.contains(newKeyName.stringValue) { return "\(newKeyName.stringValue) is in Secrets already: pick it from the menu." }
            if newKeyValue.stringValue.isEmpty { return "" }
        }
        if keyName != nil, !AppDelegate.shared.agentControl { return SecretImportSheet.refusal }
        let reasons = MCPHubRules.reasons(server, place: list.place)
        return reasons.isEmpty ? nil : reasons.joined(separator: " ")
    }

    static func names(in file: String) -> [String] {
        let folder = (file as NSString).deletingLastPathComponent
        guard let text = SkillLibrary.readText(file, in: folder), case .success(let read) = MCPHubFile.parse(Data(text.utf8)) else { return [] }
        return read.document.entries.map(\.key)
    }

    // MARK: acting

    @objc private func changed() { refresh() }

    func controlTextDidChange(_ notification: Notification) { refresh() }

    func refresh() {
        newKeyRow.isHidden = !isNewKey
        variableField.isHidden = isURL || keyName == nil
        variableCaption.isHidden = isURL || keyName == nil
        sentAs.isHidden = !isURL || keyName == nil
        variableRow.isHidden = keyName == nil
        runsField.placeholderString = isURL ? "https://mcp.example.com/mcp" : "npx -y @modelcontextprotocol/server-github"
        if variableField.stringValue.isEmpty, let keyName { variableField.placeholderString = keyName }
        let why = reason
        reasonLabel.stringValue = why ?? ""
        reasonLabel.isHidden = (why ?? "").isEmpty
        addButton.isEnabled = why == nil && !isBusy
        fit()
    }

    /// The sheet as tall as what it shows: rows come and go (a new key, its variable, the reason), and no space is left
    /// under the buttons.
    private func fit() {
        guard let window else { return }
        window.layoutIfNeeded()
        let height = form.fittingSize.height
        guard height > 0, abs(window.contentLayoutRect.height - height) > 0.5 else { return }
        window.setContentSize(NSSize(width: window.contentLayoutRect.width, height: height))
    }

    @objc func cancel() { end(nil) }

    /// Paste a Config… in place of this sheet: set by Settings, which opens it.
    var onPasteInstead: (() -> Void)?

    @objc private func pasteInstead() {
        end(nil)
        DispatchQueue.main.async { [onPasteInstead] in onPasteInstead?() }
    }

    /// Add or Save: a key given here goes into Secrets first (one Touch ID), then the list is written.
    @objc func confirm() {
        guard reason == nil, !isBusy else { return refresh() }
        let server = server, list = destination
        var steps: [MCPHubEdits.Step] = []
        if let editing, editing.name != server.name { steps.append(.init(change: .remove(editing.name), file: editing.list, place: editing.place)) }
        steps.append(.init(change: .set(server), file: list.file, place: list.place))
        let title = editing == nil ? "Add \(server.name)" : "Edit \(server.name)"
        guard isNewKey else { return end(MCPHubEdits.apply(title, steps)) }
        let planned = SecretCopyIn.Planned(name: newKeyName.stringValue, value: SecretBytes(utf8: newKeyValue.stringValue),
                                           purpose: Self.purpose(server.name), replaces: false)
        isBusy = true
        refresh()
        Task { @MainActor in
            if let failure = await Self.copyIn([planned], reason: SecretReason.save(planned.name)) {
                isBusy = false
                refresh()
                reasonLabel.stringValue = failure
                reasonLabel.isHidden = false
                fit()
                return
            }
            newKeyValue.stringValue = ""
            end(MCPHubEdits.apply(title, steps))
        }
    }

    func end(_ said: String?) {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
        done(said)
    }

    // MARK: keys

    static func purpose(_ server: String) -> String { "The \(server) MCP server\u{2019}s key, from Settings \u{203A} MCP Servers" }

    /// The keys saved in Secrets under one Touch ID, as Secrets' own import saves them (with its Undo, in Recent
    /// imports). Nil when saved, else why not, in a sentence.
    static func copyIn(_ planned: [SecretCopyIn.Planned], reason: String) async -> String? {
        do {
            _ = try await SecretsStore.shared.performCopyIn(planned, source: "Settings \u{203A} MCP Servers", format: .json, reason: reason)
            return nil
        } catch SecretsStore.Failure.cancelled {
            return "Not approved, so nothing was saved."
        } catch SecretsStore.Failure.vault(.nameTaken(let name)) {
            return "\(name) is in Secrets already: pick it instead."
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "Next Term couldn\u{2019}t save the key."
        }
    }
}

extension MCPServerSheet.Target {
    /// As a menu item carries it.
    var represented: String {
        switch self {
        case .all: return "all"
        case .only(let folder): return "only:" + folder
        case .team(let folder): return "team:" + folder
        case .kept: return "kept"
        }
    }

    init?(represented: String) {
        if represented == "all" {
            self = .all
        } else if represented == "kept" {
            self = .kept
        } else if represented.hasPrefix("only:") {
            self = .only(String(represented.dropFirst(5)))
        } else if represented.hasPrefix("team:") {
            self = .team(String(represented.dropFirst(5)))
        } else {
            return nil
        }
    }
}
