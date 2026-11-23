import AppKit
import NextTermCore

/// Settings › MCP Servers › Add Server… and Edit…: one sheet. A name; what it runs, a command or a URL; a key, picked
/// from Secrets or given here, which goes into Secrets and never into the list (R13): a command gets it through
/// `nxtrm secret run`, a URL as `Authorization: Bearer ${secret:NAME}`, which only the app fills in. And where it
/// applies: every project, one project, or a project's own list for its team. Add is the one primary button.
///
/// Editing changes only what the sheet shows: the entry's other keys, its other keys from Secrets and its variables stay
/// as written (MCPHubServer.merged).
///
/// A new server at a URL with no key is asked once, unsigned, when its URL rests (MCPHubRemote's rules): when it asks
/// for a sign-in, the Key row becomes one line saying so, and the primary becomes Sign In… (Add is gone, so there is
/// still one primary). Sign In… opens the browser (MCPHubSignIns) and adds the server once signed in. "Use a key
/// instead" brings the Key row back. With no answer, or no network, Add stays the primary.
///
/// **The user's own OAuth app**, for a server that can't register Next Term (GitHub's: discovery finds no registration
/// endpoint and no client metadata documents, so the rows open by themselves), or by "Use your own OAuth app": a Client
/// ID, kept in the entry (`nextTerm.oauth`, not a secret), and a Client secret, a key picked from Secrets or given here,
/// which goes into Secrets; the entry names it, and Sign In… reads it at token time only. One line says which callback
/// URL to register at the provider.
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
    let signInLine = NSTextField(wrappingLabelWithString: "")
    let keyInsteadButton = NSButton(title: "Use a key instead", target: nil, action: nil)
    let ownAppButton = NSButton(title: "Use your own OAuth app", target: nil, action: nil)
    let clientIDField = NSTextField()
    /// The app's exact callback URL, for a provider that holds it to its port (Slack); empty for any port.
    let callbackField = NSTextField()
    let secretPopUp = NSPopUpButton()
    let newSecretName = NSTextField()
    let newSecretValue = NSSecureTextField()
    let ownAppHelp = NSTextField(wrappingLabelWithString: "")
    /// Opens the provider's page that makes the OAuth app ("Create a Slack App…"), filled in where it takes that.
    let createAppButton = NSButton(title: "Create an OAuth App\u{2026}", target: nil, action: nil)
    let copyCallbackButton = NSButton(title: "Copy", target: nil, action: nil)
    /// Watching the clipboard for the client ID copied on the provider's page: from the create button until it fills in.
    private var clipboardWatch: Timer?
    private var clipboardSeen = 0
    private var createRow = NSStackView()
    /// The own-app rows are open: by the user, or because the server can't register Next Term.
    private(set) var ownApp = false
    /// Discovery found no way for Next Term to register (no registration endpoint, no client metadata documents).
    private(set) var cantRegister = false
    /// Opened from Settings' Sign In… for a server that can't register Next Term: the own-app rows are open, the line
    /// above them says why, and the primary button signs in (the change is saved once signed in).
    private(set) var signsInAfterSave = false
    /// The user typed in the Callback field: Slack's is no longer filled in for them.
    private var callbackTouched = false
    /// The authorization server discovery found, kept with the app so its secret is never sent to another.
    private var discoveredIssuer: String?
    private var ownLinkRow = NSStackView()
    private var clientIDRow = NSStackView()
    private var callbackRow = NSStackView()
    private var secretRow = NSStackView()
    private var newSecretRow = NSStackView()
    private var ownHelpRow = NSStackView()
    /// The server answered the unsigned probe with a Bearer challenge: the sheet offers Sign In….
    private(set) var asksSignIn = false
    private(set) var keyInstead = false
    private var probed: String?
    private var probeChallenge: String?
    private var probeWork: DispatchWorkItem?
    private var keyRow = NSStackView()
    private var signInRow = NSStackView()
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
        clientIDField.placeholderString = "Ov23li\u{2026}"
        newSecretName.placeholderString = "GITHUB_OAUTH_CLIENT_SECRET"
        newSecretValue.placeholderString = "Paste the client secret"
        callbackField.placeholderString = "Any port (\(MCPHubOAuthRegistration.redirect))"
        callbackField.setAccessibilityLabel("Callback URL")
        for field in [clientIDField, newSecretName, callbackField] {
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.delegate = self
            field.usesSingleLineMode = true
            field.cell?.wraps = false
            field.lineBreakMode = .byTruncatingMiddle
        }
        newSecretValue.delegate = self
        clientIDField.setAccessibilityLabel("Client ID")
        secretPopUp.setAccessibilityLabel("Client secret")
        newSecretName.setAccessibilityLabel("The client secret\u{2019}s name in Secrets")
        newSecretValue.setAccessibilityLabel("The client secret, hidden")
        secretPopUp.target = self
        secretPopUp.action = #selector(changed)
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

        keyRow = row("Key", keyPopUp)
        signInLine.font = .systemFont(ofSize: 12)
        signInLine.preferredMaxLayoutWidth = 300
        keyInsteadButton.isBordered = false
        keyInsteadButton.contentTintColor = .linkColor
        keyInsteadButton.font = .systemFont(ofSize: 11)
        keyInsteadButton.target = self
        keyInsteadButton.action = #selector(useKeyInstead)
        signInRow = row("Key", signInLine)
        signInRow.addArrangedSubview(keyInsteadButton)
        signInRow.alignment = .firstBaseline
        signInRow.isHidden = true
        ownAppButton.isBordered = false
        ownAppButton.contentTintColor = .linkColor
        ownAppButton.font = .systemFont(ofSize: 11)
        ownAppButton.target = self
        ownAppButton.action = #selector(toggleOwnApp)
        ownLinkRow = row("", ownAppButton)
        clientIDRow = row("Client ID", clientIDField)
        secretRow = row("Secret", secretPopUp)
        callbackRow = row("Callback", callbackField)
        newSecretRow = NSStackView(views: [NSView(), newSecretName, newSecretValue])
        newSecretRow.spacing = 8
        newSecretRow.views.first?.widthAnchor.constraint(equalToConstant: 80).isActive = true
        ownAppHelp.font = .systemFont(ofSize: 11)
        ownAppHelp.textColor = .secondaryLabelColor
        ownAppHelp.preferredMaxLayoutWidth = 392
        ownAppHelp.isSelectable = true // the callback URL, to copy
        ownHelpRow = row("", ownAppHelp)
        for (button, action) in [(createAppButton, #selector(createApp)), (copyCallbackButton, #selector(copyCallback))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        copyCallbackButton.toolTip = "Copy the callback URL"
        createRow = row("", createAppButton)
        callbackRow.addArrangedSubview(copyCallbackButton)
        callbackRow.alignment = .centerY
        let stack = form
        stack.setViews([heading, row("Name", nameField), row("Runs", kind), row("", runsField), keyRow, signInRow,
                        ownLinkRow, createRow, ownHelpRow, clientIDRow, secretRow, newSecretRow, callbackRow,
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
            clientIDField.widthAnchor.constraint(equalToConstant: 260),
            callbackField.widthAnchor.constraint(equalToConstant: 300),
            newSecretName.widthAnchor.constraint(equalToConstant: 180),
            newSecretValue.widthAnchor.constraint(equalToConstant: 204),
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

        let app = server?.oauth
        clientIDField.stringValue = app?.clientID ?? ""
        callbackField.stringValue = app?.redirect ?? ""
        ownApp = app != nil
        discoveredIssuer = app?.issuer
        secretPopUp.removeAllItems()
        secretPopUp.addItem(withTitle: Self.noKey)
        if !stored.isEmpty { secretPopUp.menu?.addItem(.separator()) }
        for name in stored { secretPopUp.addItem(withTitle: name) }
        if let named = app?.secretName, !stored.contains(named) { secretPopUp.addItem(withTitle: named) }
        secretPopUp.menu?.addItem(.separator())
        secretPopUp.addItem(withTitle: Self.newKey)
        secretPopUp.selectItem(withTitle: app?.secretName ?? Self.noKey)

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
    var isNewSecret: Bool { usesOwnApp && secretPopUp.titleOfSelectedItem == Self.newKey }

    /// The own-app rows can be offered: a server at a URL that gets no key in a header.
    var offersOwnApp: Bool { isURL && keyName == nil && !keyInstead && (asksSignIn || editing != nil || ownApp) }
    /// The own-app rows are open, so what they hold is saved.
    var usesOwnApp: Bool { offersOwnApp && ownApp }

    /// The client secret picked or given, by name; nil for none.
    var secretName: String? {
        guard usesOwnApp else { return nil }
        if isNewSecret { return newSecretName.stringValue.isEmpty ? nil : newSecretName.stringValue }
        let title = secretPopUp.titleOfSelectedItem ?? Self.noKey
        return title == Self.noKey ? nil : title
    }

    var clientID: String { clientIDField.stringValue.trimmingCharacters(in: .whitespaces) }
    var callback: String { callbackField.stringValue.trimmingCharacters(in: .whitespaces) }

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
            if usesOwnApp, !clientID.isEmpty {
                // The issuer stays bound to the same client ID (or comes from discovery); a new client ID starts unbound.
                let old = editing?.server?.oauth
                let issuer = discoveredIssuer ?? (old?.clientID == clientID ? old?.issuer : nil)
                server.oauth = MCPHubServer.OAuthApp(clientID: clientID, secretName: secretName, issuer: issuer,
                                                     redirect: callback.isEmpty ? nil : callback)
            } else {
                server.oauth = nil
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
            server.oauth = nil
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
        if usesOwnApp {
            if clientID.isEmpty { return "" }
            if clientID.count > 256 || clientID.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.properties.generalCategory == .control }) {
                return "A client ID is one word, as the provider shows it."
            }
            if !callback.isEmpty, MCPHubServer.OAuthApp.redirectPort(callback) == nil {
                return "The callback is a URL on this Mac with a port, such as \(MCPOwnAppGuide.fixedPortCallback)."
            }
            if isNewSecret {
                guard StoredSecretName.isValid(newSecretName.stringValue) else { return StoredSecretName.rule }
                if Self.storedKeys.contains(newSecretName.stringValue) { return "\(newSecretName.stringValue) is in Secrets already: pick it from the menu." }
                if newSecretValue.stringValue.isEmpty { return "" }
            }
            if cantRegister, secretName == nil, discoveredIssuer.flatMap({ URL(string: $0)?.host }) == "github.com" {
                return "GitHub needs the app\u{2019}s client secret too."
            }
            if secretName == nil, guide.provider == "Slack" {
                return "Slack needs the app\u{2019}s client secret too: put it in Secret."
            }
        } else if cantRegister, offersSignIn {
            return "" // nothing to sign in as until the app is given
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

    func controlTextDidChange(_ notification: Notification) {
        if (notification.object as? NSTextField) === callbackField { callbackTouched = true }
        refresh()
    }

    /// Whether the sheet offers Sign In… in place of Add: a new server at a URL that asked for a sign-in, with no key.
    var offersSignIn: Bool { asksSignIn && !keyInstead && editing == nil && isURL && keyName == nil }

    func refresh() {
        probeIfResting()
        keyRow.isHidden = offersSignIn
        signInRow.isHidden = !offersSignIn
        let named = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let who = named.isEmpty ? "This server" : named
        signInLine.stringValue = cantRegister
            ? "\(who) asks you to sign in, and doesn\u{2019}t let apps register themselves: sign in with your own OAuth app."
            : "\(who) asks you to sign in. Next Term keeps you signed in for every agent."
        ownLinkRow.isHidden = !offersOwnApp || cantRegister || signsInAfterSave
        ownAppButton.title = ownApp ? "Don\u{2019}t use your own OAuth app" : "Use your own OAuth app"
        for each in [clientIDRow, secretRow, callbackRow, ownHelpRow] { each.isHidden = !usesOwnApp }
        // A provider that matches the callback port and all (Slack, HubSpot, Entra…): a fixed one, filled in until the
        // user writes their own.
        if usesOwnApp, callback.isEmpty, !callbackTouched, let fixed = self.guide.fixedCallback { callbackField.stringValue = fixed }
        newSecretRow.isHidden = !isNewSecret
        let guide = self.guide
        createAppButton.title = guide.createTitle
        createRow.isHidden = !usesOwnApp || guide.createURL == nil
        clientIDField.placeholderString = guide.clientIDExample
        let steps = guide.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        ownAppHelp.stringValue = (signsInAfterSave && usesOwnApp ? "\(who) doesn\u{2019}t let apps register themselves, so sign in with an "
            + "OAuth app of your own.\n" : "") + steps
        addButton.title = offersSignIn || signsInAfterSave ? "Sign In\u{2026}" : editing == nil ? "Add" : "Save"
        newKeyRow.isHidden = !isNewKey
        variableField.isHidden = isURL || keyName == nil
        variableCaption.isHidden = isURL || keyName == nil
        sentAs.isHidden = !isURL || keyName == nil
        variableRow.isHidden = keyName == nil
        runsField.placeholderString = isURL ? "https://mcp.example.com/mcp" : "npx -y @modelcontextprotocol/server-github"
        // Where a URL server may be: MCPHubAddress's rule, as its refusals recommend it.
        runsField.toolTip = isURL ? "A server on this Mac, or on the internet or your own network. " + MCPHubAddress.recommendation : nil
        if variableField.stringValue.isEmpty, let keyName { variableField.placeholderString = keyName }
        let why = reason
        reasonLabel.textColor = .systemOrange
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

    // MARK: the probe

    /// Once the URL rests 0.6 seconds, one unsigned request, as MCPHubRemote makes it: a 401 with a Bearer challenge
    /// means the server asks for a sign-in. Asked once for each URL.
    private func probeIfResting() {
        guard editing == nil, isURL, keyName == nil, !keyInstead else { return }
        let typed = runsField.stringValue.trimmingCharacters(in: .whitespaces)
        guard typed != probed else { return }
        probeWork?.cancel()
        if asksSignIn { asksSignIn = false }
        if cantRegister { cantRegister = false }
        var candidate = MCPHubServer(name: "probe", transport: .http)
        candidate.url = typed
        guard let url = URL(string: typed), MCPHubRules.reasons(candidate, place: .user).isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.probed = typed
            DispatchQueue.global(qos: .userInitiated).async {
                let answer = MCPHubRemote(name: "probe", clientVersion: "probe").tools(.init(url: url), until: Date().addingTimeInterval(8))
                var challenge: String?
                if case .failure(let failure) = answer, case .unauthorized(401, let header) = failure.kind,
                   MCPHubOAuthChallenge.bearer(header) != nil { challenge = header }
                // Where it signs in, and whether Next Term can register there: GitHub's can't, so the own-app rows open.
                var metadata: MCPHubOAuthDiscovery.Metadata?
                if let challenge, case .success(let found) = MCPHubOAuthDiscovery.discover(server: url, name: "probe",
                                                                                          challenge: MCPHubOAuthChallenge.bearer(challenge),
                                                                                          fetch: MCPHubOAuthHTTP(server: url).asFetch) {
                    metadata = found
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard self.runsField.stringValue.trimmingCharacters(in: .whitespaces) == typed else { return }
                        self.asksSignIn = challenge != nil
                        self.probeChallenge = challenge
                        self.discoveredIssuer = metadata?.issuer
                        // CIMD isn't Next Term's yet (no metadata document published): only registration counts.
                        self.cantRegister = metadata.map { $0.registrationEndpoint == nil } ?? false
                        if self.cantRegister { self.ownApp = true }
                        self.refresh()
                    }
                }
            }
        }
        probeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Settings' Sign In… found that the server can't register Next Term: the own-app rows, open, with the client ID
    /// field to type in, and Sign In… as the sheet's one action.
    func showOwnApp() {
        ownApp = true
        signsInAfterSave = true
        refresh()
        window?.makeFirstResponder(clientIDField)
    }

    // MARK: getting a client ID

    /// The callback the app must hold: the one typed, else Next Term's any-port one.
    var callbackToRegister: String { callback.isEmpty ? guide.fixedCallback ?? MCPHubOAuthRegistration.redirect : callback }

    /// How to get a client ID for this server: its provider's page, steps and client ID shape.
    var guide: MCPOwnAppGuide {
        MCPOwnAppGuide.guide(server: runsField.stringValue.trimmingCharacters(in: .whitespaces), issuer: discoveredIssuer,
                             callback: callback.isEmpty ? nil : callback)
    }

    /// Opens the page that makes the app, with the callback on the clipboard when the page doesn't already hold it, and
    /// watches the clipboard: the client ID copied there fills in here.
    @objc func createApp() {
        let guide = self.guide
        guard let url = guide.createURL else { return }
        if !guide.createHoldsCallback { copy(callbackToRegister) }
        NSWorkspace.shared.open(url)
        watchClipboard()
    }

    @objc private func copyCallback() {
        copy(callbackToRegister)
        copyCallbackButton.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.copyCallbackButton.title = "Copy" }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        clipboardSeen = NSPasteboard.general.changeCount
    }

    /// From now on, while the Client ID field is empty: a client ID copied anywhere fills it in. Checked twice a second,
    /// and the moment the sheet comes back to the front.
    func watchClipboard() {
        clipboardSeen = NSPasteboard.general.changeCount
        clipboardWatch?.invalidate()
        clipboardWatch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkClipboard() }
        }
        clipboardWatch?.tolerance = 0.1 // its wakeups may join the system's others
    }

    private func stopWatchingClipboard() {
        clipboardWatch?.invalidate()
        clipboardWatch = nil
    }

    /// Fills the Client ID field from the clipboard once it holds a new copy shaped like this provider's client IDs.
    func checkClipboard() {
        guard clipboardWatch != nil else { return }
        guard usesOwnApp, clientID.isEmpty, window?.isVisible == true else { return stopWatchingClipboard() }
        let board = NSPasteboard.general
        guard board.changeCount != clipboardSeen else { return }
        clipboardSeen = board.changeCount
        guard let text = board.string(forType: .string), guide.looksLikeClientID(text) else { return }
        clientIDField.stringValue = text.trimmingCharacters(in: .whitespacesAndNewlines)
        stopWatchingClipboard()
        refresh()
        NSAccessibility.post(element: clientIDField, notification: .announcementRequested,
                             userInfo: [.announcement: "Client ID filled in from the clipboard", .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func windowDidBecomeKey(_ notification: Notification) { checkClipboard() }

    @objc private func toggleOwnApp() {
        ownApp.toggle()
        refresh()
        if ownApp { window?.makeFirstResponder(clientIDField) }
    }

    @objc private func useKeyInstead() {
        keyInstead = true
        refresh()
    }

    @objc func cancel() {
        if isBusy, offersSignIn { MCPHubSignIns.cancelSignIn(server.url) }
        end(nil)
    }

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
        var planned: [SecretCopyIn.Planned] = []
        if isNewKey {
            planned.append(SecretCopyIn.Planned(name: newKeyName.stringValue, value: SecretBytes(utf8: newKeyValue.stringValue),
                                                purpose: Self.purpose(server.name), replaces: false))
        }
        if isNewSecret {
            planned.append(SecretCopyIn.Planned(name: newSecretName.stringValue, value: SecretBytes(utf8: newSecretValue.stringValue),
                                                purpose: Self.secretPurpose(server.name), replaces: false))
        }
        let signsIn = offersSignIn || signsInAfterSave
        guard !planned.isEmpty else { return signsIn ? signIn(server, title: title, steps: steps) : end(MCPHubEdits.apply(title, steps)) }
        isBusy = true
        refresh()
        Task { @MainActor in
            let reason = planned.count == 1 ? SecretReason.save(planned[0].name) : SecretReason.copyIn(planned.count, from: "Settings \u{203A} MCP Servers")
            if let failure = await Self.copyIn(planned, reason: reason) {
                isBusy = false
                refresh()
                reasonLabel.stringValue = failure
                reasonLabel.isHidden = false
                fit()
                return
            }
            newKeyValue.stringValue = ""
            newSecretValue.stringValue = ""
            if signsIn {
                // Saved: the sheet now names it from Secrets, so a failed sign-in doesn't ask to save it twice.
                if let name = planned.last?.name, isNewSecret { refillSecrets(selecting: name) }
                isBusy = false
                return signIn(server, title: title, steps: steps)
            }
            end(MCPHubEdits.apply(title, steps))
        }
    }

    /// Sign In…: the browser, and the server added once signed in; on a failure the sheet stays, with why.
    private func signIn(_ server: MCPHubServer, title: String, steps: [MCPHubEdits.Step]) {
        if let probeChallenge { MCPHubSignIns.challenges[MCPHubOverview.signInKey(server.url)] = probeChallenge }
        isBusy = true
        refresh()
        MCPHubSignIns.signIn(server, progress: { [weak self] line in
            self?.say(line, problem: false)
        }, done: { [weak self] failure in
            guard let self else { return }
            self.isBusy = false
            if let failure {
                self.refresh()
                return self.say(failure, problem: true)
            }
            guard self.window?.isVisible == true else { return } // cancelled meanwhile
            let added = MCPHubEdits.apply(title, steps)
            self.end(added ?? "Signed in to \(server.name). Every agent in Next Term can use it once you allow it.")
        })
    }

    /// A line under the form: the browser's progress, or why not.
    private func say(_ text: String, problem: Bool) {
        reasonLabel.stringValue = text
        reasonLabel.textColor = problem ? .systemOrange : .secondaryLabelColor
        reasonLabel.isHidden = text.isEmpty
        fit()
    }

    func end(_ said: String?) {
        stopWatchingClipboard()
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
        done(said)
    }

    // MARK: keys

    static func purpose(_ server: String) -> String { "The \(server) MCP server\u{2019}s key, from Settings \u{203A} MCP Servers" }

    static func secretPurpose(_ server: String) -> String {
        "Your OAuth app\u{2019}s client secret for the \(server) MCP server, from Settings \u{203A} MCP Servers"
    }

    /// The Secret menu again, from Secrets as it is now, with `name` picked.
    private func refillSecrets(selecting name: String) {
        secretPopUp.removeAllItems()
        secretPopUp.addItem(withTitle: Self.noKey)
        let stored = Self.storedKeys
        if !stored.isEmpty { secretPopUp.menu?.addItem(.separator()) }
        for each in stored { secretPopUp.addItem(withTitle: each) }
        if !stored.contains(name) { secretPopUp.addItem(withTitle: name) }
        secretPopUp.menu?.addItem(.separator())
        secretPopUp.addItem(withTitle: Self.newKey)
        secretPopUp.selectItem(withTitle: name)
    }

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
