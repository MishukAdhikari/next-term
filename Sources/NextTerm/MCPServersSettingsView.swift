import AppKit
import NextTermCore

/// Settings › MCP Servers: the MCP servers the user connected in Next Term, which every agent started in its tabs reaches
/// through Next Term's own MCP connection (the hub: no agent's config file is ever written for it). Laid out as Settings
/// › Skills is: Personal, the user's own list, entry by entry; Project, what agents get in a project, the project's own
/// `.next-term/mcp.json` among it, each server with its state there (MCPHubOverview, from the same reading agents' plans
/// come from).
///
/// Personal adds a server (one sheet: a command or a URL, a key into Secrets, never the file), pastes a README's config,
/// edits, removes and turns one off. Project approves a project's list as it is now, and turns a server off for the
/// project alone. Every change has one Undo (MCPHubEdits). Until the user adds a server there is no list, and the tab
/// is one line and one button.
///
/// Personal also lists, under Found in your agents (R9), the servers set up in the agents' own configs and the open
/// projects' (MCPHubAgentServers), one row a server naming each agent, the ones in the list already left out. Add… opens
/// Paste a Config…'s sheet for it, so its keys go to Secrets the same way; the agent's file is only read. With no server
/// of the user's own, the tab is the intro, Add and Paste at the top, and that list.
///
/// A server at a URL that asks for a sign-in has Sign In… under the table; signed in, Sign Out, and the agents allowed
/// to use the sign-in in its detail with Change… beside them; lapsed, Reconnect… (MCPHubSignIns).
///
/// Nothing starts or reaches a server until an agent uses it, so the State column says what is known: a dot before the
/// words (MCPHubOverview.Indicator: working, not checked yet, needs you, failing, off), the rows that need the user first
/// on Personal. Check Now reaches a server at a URL as an agent's first need would (MCPHubRemoteControl.check), and
/// opening the tab reaches, once a launch, the ones that need no key and no sign-in, which can ask nothing.
final class MCPServersSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// The open projects, for the self-test (its projects are its own).
    static var projectsForTest: [String]?

    let scope = NSSegmentedControl(labels: ["Personal", "Project"], trackingMode: .selectOne, target: nil, action: nil)
    let picker = NSPopUpButton()
    let intro = NSTextField(wrappingLabelWithString: "")
    let detail = NSTextField(wrappingLabelWithString: "")
    let note = NSTextField(wrappingLabelWithString: "")
    let table = NSTableView()
    let addButton = NSButton(title: "Add Server\u{2026}", target: nil, action: nil)
    let pasteButton = NSButton(title: "Paste a Config\u{2026}", target: nil, action: nil)
    let editButton = NSButton(title: "Edit\u{2026}", target: nil, action: nil)
    let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    let toggleButton = NSButton(title: "Turn Off", target: nil, action: nil)
    let checkButton = NSButton(title: "Check Now", target: nil, action: nil)
    let approveButton = NSButton(title: "Approve\u{2026}", target: nil, action: nil)
    let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    let signInButton = NSButton(title: "Sign In\u{2026}", target: nil, action: nil)
    let agentsButton = NSButton(title: "Change\u{2026}", target: nil, action: nil)
    /// While the browser is out for a sign-in started here: its line under the table.
    private(set) var signingIn: String?
    let foundTitle = NSTextField(labelWithString: "Found in your agents")
    let foundIntro = NSTextField(wrappingLabelWithString: "Set up in your agents\u{2019} own configs. Add one to use it in every agent in Next Term; their configs stay as they are.")
    let foundTable = NSTableView()
    private let foundSection = NSStackView()
    /// The servers Found in your agents lists: in the agents' configs, not in the user's list.
    private(set) var foundRows: [MCPHubAgents.Server] = []
    private let scroll = NSScrollView()
    private var buttons = NSStackView()
    private let content = NSStackView()
    private let empty = NSStackView()
    let emptyText = NSTextField(wrappingLabelWithString: "")
    let emptyButton = NSButton(title: "Add Server\u{2026}", target: nil, action: nil)
    private var pickerRow = NSStackView()
    private var detailRow = NSStackView()

    private(set) var rows: [MCPHubOverview.Row] = []
    /// The project shown on Project, by its real path.
    private(set) var project: String?
    /// The sheet open on Settings, kept while it shows.
    var sheet: NSWindowController?
    var approveAlert: NSAlert?
    private var keyObserver: NSObjectProtocol?

    static let emptyLine = "Connect an MCP server once, and every agent you start in Next Term can use it."

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: MCPHubControl.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shown (or Settings brought back): the lists may have changed by hand, or with a commit.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        guard let window else { return }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
        checkOnOpen()
    }

    // MARK: layout

    private func build() {
        scope.selectedSegment = 0
        scope.target = self
        scope.action = #selector(scopeChanged)
        scope.setToolTip("Your servers, for every project or the ones you pick.", forSegment: 0)
        scope.setToolTip("What agents get in a project: your servers and the project\u{2019}s own list.", forSegment: 1)
        scope.setAccessibilityLabel("MCP servers scope")

        picker.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        (picker.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingMiddle
        picker.target = self
        picker.action = #selector(picked)
        picker.setAccessibilityLabel("Project")
        // Adding sits at the top, as Settings › Skills' Browse does; what acts on the selected server sits under the table.
        pickerRow = NSStackView(views: [picker, NSView(), pasteButton, addButton])
        pickerRow.spacing = 8

        for label in [intro, detail, note] {
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }

        let columns: [(String, String, CGFloat)] = [("name", "Server", 110), ("applies", "Applies to", 110), ("runs", "Runs", 190),
                                                    ("state", "State", 160)]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = 60
            // Runs takes the room the window gives: State keeps the width of its longest words, "Needs your approval".
            column.resizingMask = id == "runs" ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.target = self
        table.doubleAction = #selector(edit)
        table.setAccessibilityLabel("MCP servers")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let actions: [(NSButton, Selector)] = [(addButton, #selector(add)), (pasteButton, #selector(paste)), (editButton, #selector(edit)),
                                               (removeButton, #selector(remove)), (toggleButton, #selector(toggle)),
                                               (checkButton, #selector(checkNow)),
                                               (approveButton, #selector(approve)), (undoButton, #selector(undo)), (emptyButton, #selector(add)),
                                               (signInButton, #selector(signInOrOut)), (agentsButton, #selector(changeAgents))]
        for (button, action) in actions {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        agentsButton.controlSize = .small
        agentsButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailRow = NSStackView(views: [detail, agentsButton])
        detailRow.spacing = 6
        detailRow.alignment = .firstBaseline
        buttons = NSStackView(views: [editButton, removeButton, toggleButton, checkButton, approveButton, signInButton, NSView(), undoButton])
        buttons.spacing = 8
        buildFound()
        for view in [pickerRow, intro, scroll, detailRow, buttons, foundSection, note] { content.addArrangedSubview(view) }
        content.setCustomSpacing(18, after: buttons)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)

        emptyText.textColor = .secondaryLabelColor
        emptyText.alignment = .center
        for view in [emptyText, emptyButton] { empty.addArrangedSubview(view) }
        empty.orientation = .vertical
        empty.alignment = .centerX
        empty.spacing = 10
        empty.isHidden = true

        for view in [scope, content, empty] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            scope.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            scope.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.topAnchor.constraint(equalTo: scope.bottomAnchor, constant: 2),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            pickerRow.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            intro.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            detailRow.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            note.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            foundSection.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -64),
        ])
    }

    /// Found in your agents: a heading, a line, and a short table whose last column is each server's Add….
    private func buildFound() {
        foundTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        foundIntro.textColor = .secondaryLabelColor
        foundIntro.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let columns: [(String, String, CGFloat)] = [("name", "Server", 130), ("agents", "Set up in", 130), ("runs", "Runs", 200), ("add", "", 64)]
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "add" ? 64 : 60
            foundTable.addTableColumn(column)
        }
        foundTable.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        foundTable.dataSource = self
        foundTable.delegate = self
        foundTable.allowsEmptySelection = true
        foundTable.rowHeight = 24
        foundTable.setAccessibilityLabel("Found in your agents")
        let foundScroll = NSScrollView()
        foundScroll.documentView = foundTable
        foundScroll.hasVerticalScroller = true
        foundScroll.borderType = .bezelBorder
        foundScroll.heightAnchor.constraint(equalToConstant: 128).isActive = true
        for view in [foundTitle, foundIntro, foundScroll] { foundSection.addArrangedSubview(view) }
        foundSection.orientation = .vertical
        foundSection.alignment = .leading
        foundSection.spacing = 6
        foundIntro.widthAnchor.constraint(equalTo: foundSection.widthAnchor).isActive = true
        foundScroll.widthAnchor.constraint(equalTo: foundSection.widthAnchor).isActive = true
    }

    // MARK: data

    var showsProject: Bool { scope.selectedSegment == 1 }

    /// Shows Personal (0) or Project (1).
    func show(_ index: Int) {
        scope.selectedSegment = index
        reload()
    }

    @objc private func scopeChanged() { reload() }

    @objc private func picked() {
        project = picker.selectedItem?.representedObject as? String
        reload()
    }

    @objc private func changed() { reload() }

    static func openProjects() -> [String] { projectsForTest ?? ProjectSkillsView.openProjects() }

    /// Reads the lists again (a few small files, so on the main thread), keeping the selected server selected.
    func reload() {
        let kept = selected.map { ($0.name, $0.list) }
        let home = NSHomeDirectory()
        let userFile = MCPHubEdits.userFile
        let runs = MCPHubControl.lastRuns
        let signIns = MCPHubSignIns.states()
        let open = Self.openProjects()
        if project.map({ !open.contains($0) }) ?? true {
            let front = Self.projectsForTest == nil ? (TerminalWindow.front?.windowController as? TerminalWindowController)?.project.map(canonicalPath) : nil
            project = front.flatMap { open.contains($0) ? $0 : nil } ?? open.first
        }
        fillPicker(open)
        picker.isHidden = !showsProject
        var unreadable: [MCPHubScope.Unreadable] = []
        if showsProject {
            if let project {
                let found = MCPHubScope.sources(folder: project, home: home, userFile: userFile)
                (rows, unreadable) = MCPHubOverview.project(project, user: found.user, projects: found.projects, home: home, runs: runs,
                                                            signIns: signIns)
            } else {
                rows = []
            }
        } else {
            let user = MCPHubScope.sources(folder: nil, home: home, userFile: userFile).user
            // The ones that need the user (amber, red) first, each group in the file's order. Selection and Undo find a
            // row by its name and list, never its place.
            let listed = MCPHubOverview.personal(user, runs: runs, signIns: signIns)
            let attention = listed.filter { MCPHubOverview.indicator($0.state).needsAttention }
            rows = attention + listed.filter { !MCPHubOverview.indicator($0.state).needsAttention }
            if case .failure(let problem)? = user?.read { unreadable = [MCPHubScope.Unreadable(file: userFile, problem: problem)] }
            // Read again where an agent's file changed; a change comes back as MCPHubControl.changed.
            MCPHubAgentServers.refresh(projects: open)
            foundRows = MCPHubAgents.notAdded(MCPHubAgentServers.found, user: user)
        }
        if showsProject { foundRows = [] }
        let name = project.map(ProjectSkillsView.title) ?? ""
        intro.stringValue = showsProject
            ? "What agents get in \(name): your servers, and the ones its .next-term/mcp.json lists for its team. A project\u{2019}s list starts nothing until you approve it."
            : "Agents you start in Next Term reach these servers through its own MCP connection. Their own configs are never changed."
        note.stringValue = unreadable.map { "\(SkillStep.short($0.file)) can\u{2019}t be used: \($0.problem.reason)." }.joined(separator: " ")
        if note.stringValue.isEmpty, !rows.isEmpty, !AppDelegate.shared.agentControl {
            note.stringValue = "Agents reach these servers only while \u{201C}Let agents control Next Term\u{201D} is on, in Settings \u{203A} Editor."
        }
        note.isHidden = note.stringValue.isEmpty
        table.reloadData()
        foundTable.reloadData()
        if let kept, let index = rows.firstIndex(where: { $0.name == kept.0 && $0.list == kept.1 }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        // After a change, the table stays, with its Undo, even when it left nothing.
        let noList = unreadable.isEmpty && rows.isEmpty && MCPHubEdits.last == nil
        // With none of the user's own and some in their agents: the intro, Add and Paste, and those.
        for view in [scroll, buttons] as [NSView] { view.isHidden = noList && !showsProject }
        foundSection.isHidden = foundRows.isEmpty
        showEmpty(noList && foundRows.isEmpty, open: open)
        updateButtons()
    }

    /// The calm empty state: one line and one button. On Project with no project open, Open Project… instead.
    private func showEmpty(_ isEmpty: Bool, open: [String]) {
        let noProject = showsProject && project == nil
        content.isHidden = isEmpty || noProject
        empty.isHidden = !(isEmpty || noProject)
        if noProject {
            emptyText.stringValue = "Open a project to see the servers agents get there."
            emptyButton.title = "Open Project\u{2026}"
            emptyButton.target = AppDelegate.shared
            emptyButton.action = #selector(AppDelegate.openProjectPanel(_:))
        } else {
            emptyText.stringValue = showsProject ? "No MCP server applies in \(project.map(ProjectSkillsView.title) ?? "this project") yet." : Self.emptyLine
            emptyButton.title = "Add Server\u{2026}"
            emptyButton.target = self
            emptyButton.action = #selector(add)
        }
    }

    /// Whether the view shows its empty state, for the self-test.
    var showsEmpty: Bool { !empty.isHidden }

    private func fillPicker(_ open: [String]) {
        picker.menu?.removeAllItems()
        for path in open {
            let item = NSMenuItem(title: ProjectSkillsView.title(path), action: nil, keyEquivalent: "")
            item.representedObject = path
            item.toolTip = path
            picker.menu?.addItem(item)
            if path == project { picker.select(item) }
        }
    }

    var selected: MCPHubOverview.Row? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === foundTable ? foundRows.count : rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        if tableView === foundTable { return foundCell(tableColumn, row: index) }
        guard let column = tableColumn, rows.indices.contains(index) else { return nil }
        let row = rows[index]
        if column.identifier.rawValue == "state" {
            let cell = MCPStateCell()
            let checking = isChecking(row)
            cell.show(cellText(row, column: "state"), indicator: checking ? .unchecked : MCPHubOverview.indicator(row.state),
                      tip: checking ? "Next Term is reaching it now." : MCPHubOverview.stateTip(row.state, remote: row.isRemote))
            return cell
        }
        let cell = NSTextField(labelWithString: cellText(row, column: column.identifier.rawValue))
        cell.lineBreakMode = .byTruncatingTail
        switch column.identifier.rawValue {
        case "runs":
            // Its start and its end (a package, a script's name) stay; the whole line, keys' wrapper and all, is its tip.
            cell.lineBreakMode = .byTruncatingMiddle
            cell.toolTip = row.server.map(MCPHubOverview.runsText) ?? cell.stringValue
            cell.textColor = .secondaryLabelColor
        case "applies": cell.toolTip = SkillStep.short(row.list)
        default: break
        }
        return cell
    }

    func cellText(_ row: MCPHubOverview.Row, column: String) -> String {
        switch column {
        case "name": return row.name
        case "applies": return MCPHubOverview.appliesText(row, home: NSHomeDirectory())
        // What it runs, as Found in your agents shows it: the command inside `nxtrm secret run`, whose keys are Secrets'.
        case "runs": return row.server.map { $0.transport == .stdio ? MCPHubOverview.keys(of: $0).inner.map(ShellQuote.quote).joined(separator: " ") : $0.url } ?? "\u{2014}"
        case "state": return isChecking(row) ? "Checking\u{2026}" : MCPHubOverview.stateText(row.state, remote: row.isRemote)
        default: return ""
        }
    }

    /// A Found in your agents cell: its name, the agents, what it runs, or its Add….
    private func foundCell(_ column: NSTableColumn?, row index: Int) -> NSView? {
        guard let column, foundRows.indices.contains(index) else { return nil }
        let server = foundRows[index]
        if column.identifier.rawValue == "add" {
            let button = NSButton(title: "Add\u{2026}", target: self, action: #selector(addFoundRow(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.tag = index
            button.setAccessibilityLabel("Add \(server.pastedName)")
            return button
        }
        let text: String
        switch column.identifier.rawValue {
        case "name": text = server.pastedName
        case "agents": text = server.agentsText
        default: text = server.runs
        }
        let cell = NSTextField(labelWithString: text)
        cell.lineBreakMode = column.identifier.rawValue == "name" || column.identifier.rawValue == "agents" ? .byTruncatingTail : .byTruncatingMiddle
        cell.toolTip = column.identifier.rawValue == "agents" ? server.files.map(SkillStep.short).joined(separator: "\n") : text
        if column.identifier.rawValue != "name" { cell.textColor = .secondaryLabelColor }
        // Centred in the row, on the line of the Add… beside it, as a label alone would sit at the row's top.
        let box = NSView()
        cell.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(cell)
        NSLayoutConstraint.activate([
            cell.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 2),
            cell.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -2),
            cell.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        cell.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return box
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) !== foundTable else { return }
        updateButtons()
    }

    private func updateButtons() {
        let row = selected
        var said = row.map { MCPHubOverview.stateTip($0.state, remote: $0.isRemote) } ?? ""
        let signedIn = row.flatMap { $0.isRemote ? $0.server.flatMap { MCPHubSignIns.record(for: $0.url) } : nil }
        var allowed = false // Change… goes with the agents it names, never beside a lapse, whose one action is Reconnect…
        if let signedIn, case .signedIn = row?.state {
            said += " Signs in at \(signedIn.metadata.issuerHost)."
            if let used = MCPHubSignInWords.usedBy(signedIn.consents) { said += " " + used + "."; allowed = true }
        }
        detail.stringValue = said
        detail.isHidden = row == nil
        detailRow.isHidden = row == nil
        agentsButton.isHidden = !allowed
        let action = signInAction(row)
        signInButton.isHidden = action == nil
        signInButton.title = action ?? ""
        signInButton.isEnabled = action != nil
        let usable = row?.server != nil
        editButton.isEnabled = usable
        removeButton.isEnabled = row != nil
        // On Project, Approve… (off for a server not waiting) gives its place to the sign-in button, so the row fits
        // Settings' width with Check Now in it.
        approveButton.isHidden = !showsProject || (action != nil && row?.state != .needsApproval)
        approveButton.isEnabled = row?.state == .needsApproval
        toggleButton.isEnabled = usable && row?.state != .shadowed
        toggleButton.title = toggleTitle(row)
        let check = checkState(row)
        checkButton.isEnabled = check.enabled
        checkButton.toolTip = check.tip
        checkButton.title = row.map { isChecking($0) } == true ? "Checking\u{2026}" : "Check Now"
        let last = MCPHubEdits.last
        undoButton.isEnabled = last != nil
        undoButton.toolTip = last.map { "Undo \u{201C}\($0.title)\u{201D}" }
    }

    /// Personal turns the entry off or on. Project turns a server off for the project alone, or on again; a server
    /// whose own entry is off is turned on there.
    func toggleTitle(_ row: MCPHubOverview.Row?) -> String {
        guard let row else { return showsProject ? "Turn Off Here" : "Turn Off" }
        if !showsProject { return row.state == .off ? "Turn On" : "Turn Off" }
        switch row.state {
        case .offHere: return "Turn On Here"
        case .off: return "Turn On"
        default: return "Turn Off Here"
        }
    }

    /// The sign-in button's title for a row, or nil when it has none: Sign In… for a server that asks, Reconnect… for a
    /// lapse or more access, Sign Out once signed in, Cancel Sign-In while the browser is out.
    func signInAction(_ row: MCPHubOverview.Row?) -> String? {
        guard let row, row.isRemote, let url = row.server?.url else { return nil }
        if MCPHubSignIns.isSigningIn(url) { return "Cancel Sign-In" }
        switch row.state {
        case .needsSignIn: return "Sign In\u{2026}"
        case .signedOut, .needsMoreAccess: return "Reconnect\u{2026}"
        case .signedIn: return "Sign Out"
        default: return nil
        }
    }

    /// Selects the row of the server at `url`, on Personal, or says it isn't listed.
    func select(url: String) {
        if showsProject { show(0) }
        let key = MCPHubOverview.signInKey(url)
        guard let at = rows.firstIndex(where: { $0.server.map { MCPHubOverview.signInKey($0.url) } == key }) else { return }
        table.selectRowIndexes(IndexSet(integer: at), byExtendingSelection: false)
        table.scrollRowToVisible(at)
        updateButtons()
    }

    // MARK: actions

    @objc func signInOrOut() {
        guard let row = selected, let server = row.server else { return }
        switch signInAction(row) {
        case "Cancel Sign-In"?:
            MCPHubSignIns.cancelSignIn(server.url)
        case "Sign Out"?:
            MCPHubSignIns.signOut(url: server.url, name: server.name) { [weak self] text in self?.said(text) }
        case .some:
            signingIn = server.name
            updateButtons()
            MCPHubSignIns.signIn(server, progress: { [weak self] line in
                self?.note.stringValue = line
                self?.note.isHidden = false
                self?.updateButtons()
            }, done: { [weak self] failure in
                self?.signingIn = nil
                self?.said(failure ?? "Signed in to \(server.name). Every agent in Next Term can use it once you allow it.")
            })
            updateButtons()
        case nil:
            return
        }
    }

    // MARK: checking

    /// Whether Check Now is reaching the row's server now.
    func isChecking(_ row: MCPHubOverview.Row) -> Bool {
        MCPHubRemoteControl.checking.contains(MCPHubOverview.runKey(list: row.list, server: row.name))
    }

    /// Whether Check Now can reach the row's server: at a URL, needing no key, in a state an agent's need would reach.
    func isCheckable(_ row: MCPHubOverview.Row) -> Bool {
        guard row.isRemote, let server = row.server, MCPHubRemoteControl.canCheck(server) else { return false }
        switch row.state {
        case .ready, .signedIn, .failed, .needsSignIn: return true
        case .off, .offHere, .shadowed, .remote, .broken, .needsApproval, .signedOut, .needsMoreAccess: return false
        }
    }

    /// Check Now's state for the selected row (or, with none, for every server it can check), with its tip saying why
    /// when it can't.
    func checkState(_ row: MCPHubOverview.Row?) -> (enabled: Bool, tip: String) {
        guard let row else {
            let any = rows.contains { isCheckable($0) && !isChecking($0) }
            return (any, any ? "Reaches every server at a URL that needs no key from Secrets, as an agent\u{2019}s first use would."
                : "No server here can be checked from Settings: each is checked the first time an agent uses it.")
        }
        if isChecking(row) { return (false, "Next Term is reaching it now.") }
        if isCheckable(row) { return (true, "Reaches it now, as an agent\u{2019}s first use would, and shows what it found.") }
        guard let server = row.server else { return (false, "It can\u{2019}t be used, so there is nothing to check.") }
        if server.transport == .stdio {
            return (false, "Next Term starts a local server only in an agent\u{2019}s session: it is checked the first time an agent uses it.")
        }
        switch row.state {
        case .signedOut, .needsMoreAccess: return (false, "Reconnect first: until then it can\u{2019}t be reached.")
        case .needsApproval: return (false, "Approve the project\u{2019}s list first.")
        case .ready, .signedIn, .failed, .needsSignIn:
            return (false, "It needs a key from Secrets, which Next Term releases only when an agent uses it: it is checked then.")
        case .off, .offHere, .shadowed, .remote, .broken: return (false, "Agents don\u{2019}t get it here, so there is nothing to check.")
        }
    }

    /// Check Now: the selected server, or every one it can check, each reached once; what it found is its state.
    @objc func checkNow() {
        let picked = selected.map { [$0] } ?? rows
        let targets = picked.filter { isCheckable($0) && !isChecking($0) }
        guard !targets.isEmpty else { return }
        var left = targets.count
        var failures: [String] = []
        for row in targets {
            check(row) { [weak self] failure in
                if let failure { failures.append(failure) }
                left -= 1
                guard left == 0 else { return }
                if targets.count == 1 {
                    self?.said(failures.first ?? "Reached \(row.name).")
                } else {
                    let reached = targets.count - failures.count
                    self?.said("Reached \(reached) of \(targets.count) servers." + (failures.isEmpty ? "" : " Select one to see why it wasn\u{2019}t."))
                }
            }
        }
        updateButtons()
    }

    private func check(_ row: MCPHubOverview.Row, done: @escaping (String?) -> Void) {
        guard let server = row.server else { return done(nil) }
        let folder = showsProject ? project ?? NSHomeDirectory() : NSHomeDirectory()
        let userFile = MCPHubControl.userFile ?? MCPHubScope.userPath()
        MCPHubRemoteControl.check(server, list: row.list, folder: folder, userFile: userFile, done: done)
    }

    /// On opening the tab: the servers at a URL nothing has reached yet that need no key and no sign-in, so reaching them
    /// can ask nothing (no Secrets panel, no presence check), each once a launch, in the background. The rest wait for
    /// Check Now or an agent's use. Never in the self-test, whose servers are made up.
    private func checkOnOpen() {
        guard Self.projectsForTest == nil, MCPHubControl.userFile == nil else { return }
        for row in rows where row.state == .ready(tools: nil) && isCheckable(row) {
            guard let server = row.server, MCPHubSignIns.record(for: server.url) == nil else { continue }
            let once = MCPHubOverview.runKey(list: row.list, server: row.name) + "\u{0}" + server.url
            guard MCPHubRemoteControl.checkedOnOpen.insert(once).inserted else { continue }
            check(row) { _ in } // its end comes back as MCPHubControl.changed, and the table reads it
        }
    }

    /// Change…: the agents allowed to use the selected server's sign-in, each to remove.
    @objc func changeAgents() {
        guard let server = selected?.server, let record = MCPHubSignIns.record(for: server.url), !record.consents.isEmpty else { return }
        let menu = NSMenu()
        for agent in record.consents {
            let item = NSMenuItem(title: "Stop \(MCPHubSignInWords.agentTitle(agent)) Using It", action: #selector(removeAgent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [server.url, agent]
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: agentsButton.bounds.height + 2), in: agentsButton)
    }

    @objc private func removeAgent(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        MCPHubSignIns.removeConsent(url: pair[0], agent: pair[1]) { [weak self] failure in
            self?.said(failure ?? "\(MCPHubSignInWords.agentTitle(pair[1])) will be asked again before it uses the sign-in.")
        }
    }

    @objc func add() { beginServerSheet(nil) }

    @objc private func addFoundRow(_ sender: NSButton) {
        guard foundRows.indices.contains(sender.tag) else { return }
        addFound(foundRows[sender.tag])
    }

    /// Add… for a server in an agent's config (a row of Found in your agents, or the new-server offer): Paste a
    /// Config…'s sheet with that server, on Personal.
    func addFound(_ server: MCPHubAgents.Server) {
        guard let window, window.attachedSheet == nil else { return }
        if showsProject { show(0) }
        let sheet = MCPPasteSheet(project: nil, preset: server) { [weak self] said in
            self?.sheet = nil
            self?.said(said)
        }
        self.sheet = sheet
        if let sheetWindow = sheet.window { window.beginSheet(sheetWindow, completionHandler: nil) }
    }

    @objc func paste() {
        guard let window, window.attachedSheet == nil else { return }
        let sheet = MCPPasteSheet(project: showsProject ? project : nil) { [weak self] said in
            self?.sheet = nil
            self?.said(said)
        }
        self.sheet = sheet
        if let sheetWindow = sheet.window { window.beginSheet(sheetWindow, completionHandler: nil) }
    }

    @objc func edit() {
        guard let row = selected, row.server != nil else { return }
        beginServerSheet(row)
    }

    func beginServerSheet(_ row: MCPHubOverview.Row?) {
        guard let window, window.attachedSheet == nil else { return }
        let sheet = MCPServerSheet(editing: row, project: showsProject ? project : nil) { [weak self] said in
            self?.sheet = nil
            self?.said(said)
        }
        sheet.onPasteInstead = { [weak self] in self?.paste() }
        self.sheet = sheet
        if let sheetWindow = sheet.window { window.beginSheet(sheetWindow, completionHandler: nil) }
    }

    /// Remove takes the entry out of its list at once: Undo puts it back as it was. The last entry for a URL Next Term
    /// is signed in to takes the sign-in with it, revoked at the server (Undo then brings the server back signed out).
    @objc func remove() {
        guard let row = selected else { return }
        let failure = MCPHubEdits.apply("Remove \(row.name)", [.init(change: .remove(row.name), file: row.list, place: row.place)])
        if failure == nil, let server = row.server, server.transport != .stdio, MCPHubSignIns.record(for: server.url) != nil,
           !Self.isStillUsed(server.url) {
            return MCPHubSignIns.signOut(url: server.url, name: server.name) { [weak self] text in
                self?.said("Removed \(row.name). " + text)
            }
        }
        said(failure ?? "Removed \(row.name). Undo puts it back.")
    }

    /// Whether another entry, in the user's list or an open project's, still names `url`: a sign-in is shared by URL.
    static func isStillUsed(_ url: String) -> Bool {
        let key = MCPHubOverview.signInKey(url)
        let home = NSHomeDirectory()
        let userFile = MCPHubEdits.userFile
        let user = MCPHubScope.sources(folder: nil, home: home, userFile: userFile).user
        if MCPHubOverview.personal(user).contains(where: { $0.server.map { MCPHubOverview.signInKey($0.url) } == key }) { return true }
        for project in openProjects() {
            let found = MCPHubScope.sources(folder: project, home: home, userFile: userFile)
            let rows = MCPHubOverview.project(project, user: nil, projects: found.projects, home: home).rows
            if rows.contains(where: { $0.place == .project && $0.server.map { MCPHubOverview.signInKey($0.url) } == key }) { return true }
        }
        return false
    }

    @objc func toggle() {
        guard let row = selected, var server = row.server else { return }
        let title = toggleTitle(row)
        let step: MCPHubEdits.Step
        if showsProject, let project, row.state != .off {
            if row.state == .offHere {
                let home = NSHomeDirectory()
                guard let record = MCPHubEdits.choices().offRecord(row.name, in: project, home: home) else { return reload() }
                step = .init(change: .turnOn(server: row.name, folder: record.folder), file: MCPHubEdits.userFile, place: .user)
            } else {
                step = .init(change: .turnOff(server: row.name, folder: project), file: MCPHubEdits.userFile, place: .user)
            }
        } else {
            server.enabled = row.state == .off
            step = .init(change: .set(server), file: row.list, place: row.place)
        }
        said(MCPHubEdits.apply("\(title) \(row.name)", [step]))
    }

    /// Approve…: the project's list as it is now, every server in it with what it runs, then one approval of those bytes.
    @objc func approve() {
        guard let row = selected, row.state == .needsApproval, let window else { return }
        let entries = rows.compactMap { found -> (name: String, server: MCPHubServer)? in
            guard found.list == row.list, let server = found.server else { return nil }
            return (found.name, server)
        }
        let alert = NSAlert()
        let name = project.map(ProjectSkillsView.title) ?? "this project"
        alert.messageText = "Approve \(name)\u{2019}s MCP servers?"
        var lines = MCPHubOverview.approvalLines(entries)
        lines.append("")
        let file = project.flatMap { row.list.hasPrefix($0 + "/") ? String(row.list.dropFirst($0.count + 1)) : nil } ?? SkillStep.short(row.list)
        lines.append("They come with the project, in \(file). Agents in Next Term start them in this project once you approve. A change to the list waits for you again.")
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Approve")
        alert.addButton(withTitle: "Cancel")
        approveAlert = alert
        let list = row.list, digest = row.digest
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.approveAlert = nil
                guard response == .alertFirstButtonReturn else { return }
                let failure = MCPHubEdits.apply("Approve \(name)\u{2019}s list",
                                                [.init(change: .approve(file: list, digest: digest), file: MCPHubEdits.userFile, place: .user)])
                self?.said(failure)
            }
        }
    }

    @objc func undo() {
        said(MCPHubEdits.undo())
    }

    /// Reloads, and says `text` (a failure, or what was done) under the table until the next change.
    func said(_ text: String?) {
        reload()
        if let text, !text.isEmpty {
            note.stringValue = text
            note.isHidden = false
        }
    }
}

/// The State column's cell: a dot marking the state at a glance (MCPHubOverview.Indicator), then the words, which say it
/// too, centred in the row. The dot is the cell's alone: VoiceOver reads the words, and the tooltip says it in a sentence.
final class MCPStateCell: NSView {
    let dot = NSImageView()
    let label = NSTextField(labelWithString: "")
    private(set) var indicator: MCPHubOverview.Indicator = .unchecked

    init() {
        super.init(frame: .zero)
        dot.setAccessibilityElement(false)
        dot.setContentHuggingPriority(.required, for: .horizontal)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [dot, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ text: String, indicator: MCPHubOverview.Indicator, tip: String) {
        self.indicator = indicator
        let look = Self.look(indicator)
        dot.image = NSImage(systemSymbolName: look.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .regular))
        dot.contentTintColor = look.dot
        label.stringValue = text
        label.textColor = look.text
        toolTip = tip
        label.toolTip = tip
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    /// Each mark's symbol and colours: green working, a hollow circle for not checked yet, amber for what needs the user,
    /// red failing, grey off. The words of what needs the user read in the label's own colour, a step above the rest.
    static func look(_ indicator: MCPHubOverview.Indicator) -> (symbol: String, dot: NSColor, text: NSColor) {
        switch indicator {
        case .working: return ("circle.fill", .systemGreen, .secondaryLabelColor)
        case .unchecked: return ("circle", .tertiaryLabelColor, .secondaryLabelColor)
        case .needsYou: return ("circle.fill", .systemOrange, .labelColor)
        case .failing: return ("circle.fill", .systemRed, .labelColor)
        case .off: return ("circle.fill", .tertiaryLabelColor, .tertiaryLabelColor)
        }
    }
}
