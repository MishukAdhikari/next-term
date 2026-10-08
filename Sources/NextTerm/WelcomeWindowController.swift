import AppKit
import NextTermCore

/// The way in: your projects on the left (search, open, a new terminal), and your servers under them; on
/// the right the chosen project with every agent's saved sessions for it, newest first, each one a click
/// from running again in a tab in the right folder.
final class WelcomeWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
                                     NSSearchFieldDelegate {
    private let search = NSSearchField()
    private var openTip: ShortcutToolTip?
    /// The saved hosts, each a click from a tab on it, and Connect to Server… for another.
    private let serversLabel = NSTextField(labelWithString: "")
    private let serverList = NSStackView()
    private let connectButton = NSButton(title: "Connect to Server…", target: nil, action: nil)
    private var connectTip: ShortcutToolTip?
    private var servers: [RemoteHost] = []
    /// More are in the sheet behind Connect to Server…: the projects keep the room.
    static let serverLimit = 3
    private let projectsTable = NSTableView()
    private let sessionsTable = NSTableView()
    private let projectName = NSTextField(labelWithString: "")
    private let projectPath = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: "Open Project", target: nil, action: nil)
    private let filter = NSSegmentedControl()
    /// The filter when more agents have sessions here than the buttons fit.
    private let agentMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sessionsTitle = NSTextField(labelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let resumeButton = NSButton(title: "Resume", target: nil, action: nil)
    private let forkButton = NSButton(title: "Fork", target: nil, action: nil)
    private let detailPane = NSView()

    private var allProjects: [String] = []
    private var projects: [String] = []
    private var sessions: [AgentSession] = []
    private var shownSessions: [AgentSession] = []
    private var branches: [String: String] = [:]
    /// Sessions already read, per project, so moving through the list is instant (refreshed in the background).
    private var cache: [String: [AgentSession]] = [:]
    private var agentFilter: AgentKind?
    /// The tabs the shown project's sessions are open in.
    private var sessionTabs = SessionTabs()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 580),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Welcome to Next Term"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = Theme.background
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 440)
        super.init(window: window)
        window.delegate = self
        build()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func showWindow(_ sender: Any?) {
        reloadProjects()
        reloadServers()
        super.showWindow(sender)
        window?.makeFirstResponder(projectsTable)
    }

    // MARK: layout

    private func build() {
        guard let content = window?.contentView else { return }

        // Left: the app, search, projects, and the two ways to start.
        let left = NSView()
        left.wantsLayer = true
        left.layer?.backgroundColor = Theme.bar.cgColor
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(labelWithString: "Next Term")
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.textColor = Theme.text
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let versionLabel = NSTextField(labelWithString: version.map { "Version \($0)" } ?? "Development build")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = Theme.textDim
        search.placeholderString = "Search projects"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)
        let projectsLabel = Self.heading("Projects")
        configure(projectsTable, rowHeight: 44, action: #selector(projectClicked), double: #selector(openSelectedProject))
        let projectsScroll = Self.scroll(projectsTable)
        let open = NSButton(title: "Open…", target: NSApp.delegate, action: #selector(AppDelegate.openProjectPanel(_:)))
        open.bezelStyle = .rounded
        openTip = ShortcutToolTip(open, "Open a folder as a project", #selector(AppDelegate.openProjectPanel(_:)))
        let terminal = NSButton(title: "New Terminal", target: self, action: #selector(newTerminal))
        terminal.bezelStyle = .rounded
        serversLabel.attributedStringValue = Self.headingText("Servers")
        serverList.orientation = .vertical
        serverList.alignment = .leading
        serverList.spacing = 0
        connectButton.bezelStyle = .rounded
        connectButton.target = NSApp.delegate
        connectButton.action = #selector(AppDelegate.newRemoteTab(_:))
        connectTip = ShortcutToolTip(connectButton, "Open a tab on one of your servers, over ssh", #selector(AppDelegate.newRemoteTab(_:)))
        for view in [icon, name, versionLabel, search, projectsLabel, projectsScroll, serversLabel, serverList, connectButton, open, terminal] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            left.addSubview(view)
        }

        // Right: the chosen project and its sessions.
        projectName.font = .systemFont(ofSize: 20, weight: .semibold)
        projectName.textColor = Theme.text
        Typography.singleLine(projectName, truncation: .byTruncatingMiddle)
        projectPath.font = .systemFont(ofSize: 12)
        projectPath.textColor = Theme.textDim
        Typography.singleLine(projectPath, truncation: .byTruncatingMiddle)
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"
        openButton.target = self
        openButton.action = #selector(openSelectedProject)
        sessionsTitle.attributedStringValue = Self.headingText("Agent sessions")
        filter.segmentStyle = .roundRect
        filter.target = self
        filter.action = #selector(filterChanged)
        filter.setAccessibilityLabel("Show sessions of")
        agentMenu.controlSize = .small
        agentMenu.target = self
        agentMenu.action = #selector(agentMenuChanged)
        agentMenu.setAccessibilityLabel("Show sessions of")
        agentMenu.isHidden = true
        configure(sessionsTable, rowHeight: 50, action: nil, double: #selector(resumeSelected))
        let sessionsScroll = Self.scroll(sessionsTable)
        empty.textColor = Theme.textDim
        empty.font = .systemFont(ofSize: 12)
        empty.alignment = .center
        resumeButton.bezelStyle = .rounded
        resumeButton.target = self
        resumeButton.action = #selector(resumeSelected)
        resumeButton.toolTip = "Continue it in a new tab, in the folder it was started in"
        forkButton.bezelStyle = .rounded
        forkButton.target = self
        forkButton.action = #selector(forkSelected)
        forkButton.toolTip = "Continue a copy, leaving this one as it is (safe while it is open in another terminal)"
        for view in [projectName, projectPath, openButton, sessionsTitle, filter, agentMenu, sessionsScroll, empty, resumeButton, forkButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            detailPane.addSubview(view)
        }

        for view in [left, detailPane] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            left.topAnchor.constraint(equalTo: content.topAnchor),
            left.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            left.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            left.widthAnchor.constraint(equalToConstant: 300),

            icon.topAnchor.constraint(equalTo: left.topAnchor, constant: 40),
            icon.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 20),
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            name.bottomAnchor.constraint(equalTo: icon.centerYAnchor, constant: 1),
            versionLabel.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            versionLabel.topAnchor.constraint(equalTo: icon.centerYAnchor, constant: 2),
            search.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 18),
            search.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 16),
            search.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -16),
            projectsLabel.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 16),
            projectsLabel.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 20),
            projectsScroll.topAnchor.constraint(equalTo: projectsLabel.bottomAnchor, constant: 6),
            projectsScroll.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 6),
            projectsScroll.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -6),
            projectsScroll.bottomAnchor.constraint(equalTo: serversLabel.topAnchor, constant: -14),
            serversLabel.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 20),
            serverList.topAnchor.constraint(equalTo: serversLabel.bottomAnchor, constant: 4),
            serverList.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 6),
            serverList.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -6),
            connectButton.topAnchor.constraint(equalTo: serverList.bottomAnchor, constant: 6),
            connectButton.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 16),
            open.topAnchor.constraint(equalTo: connectButton.bottomAnchor, constant: 8),
            open.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 16),
            open.bottomAnchor.constraint(equalTo: left.bottomAnchor, constant: -16),
            terminal.leadingAnchor.constraint(equalTo: open.trailingAnchor, constant: 8),
            terminal.centerYAnchor.constraint(equalTo: open.centerYAnchor),

            detailPane.topAnchor.constraint(equalTo: content.topAnchor),
            detailPane.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            detailPane.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            detailPane.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            projectName.topAnchor.constraint(equalTo: detailPane.topAnchor, constant: 40),
            projectName.leadingAnchor.constraint(equalTo: detailPane.leadingAnchor, constant: 28),
            projectName.trailingAnchor.constraint(lessThanOrEqualTo: openButton.leadingAnchor, constant: -16),
            projectPath.topAnchor.constraint(equalTo: projectName.bottomAnchor, constant: 3),
            projectPath.leadingAnchor.constraint(equalTo: projectName.leadingAnchor),
            projectPath.trailingAnchor.constraint(lessThanOrEqualTo: detailPane.trailingAnchor, constant: -28),
            openButton.trailingAnchor.constraint(equalTo: detailPane.trailingAnchor, constant: -24),
            openButton.centerYAnchor.constraint(equalTo: projectName.centerYAnchor),
            sessionsTitle.topAnchor.constraint(equalTo: projectPath.bottomAnchor, constant: 28),
            sessionsTitle.leadingAnchor.constraint(equalTo: projectName.leadingAnchor),
            filter.centerYAnchor.constraint(equalTo: sessionsTitle.centerYAnchor),
            filter.trailingAnchor.constraint(equalTo: detailPane.trailingAnchor, constant: -24),
            agentMenu.centerYAnchor.constraint(equalTo: sessionsTitle.centerYAnchor),
            agentMenu.trailingAnchor.constraint(equalTo: detailPane.trailingAnchor, constant: -24),
            sessionsScroll.topAnchor.constraint(equalTo: sessionsTitle.bottomAnchor, constant: 10),
            sessionsScroll.leadingAnchor.constraint(equalTo: detailPane.leadingAnchor, constant: 14),
            sessionsScroll.trailingAnchor.constraint(equalTo: detailPane.trailingAnchor, constant: -14),
            sessionsScroll.bottomAnchor.constraint(equalTo: resumeButton.topAnchor, constant: -12),
            empty.centerXAnchor.constraint(equalTo: sessionsScroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: sessionsScroll.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            resumeButton.trailingAnchor.constraint(equalTo: detailPane.trailingAnchor, constant: -24),
            resumeButton.bottomAnchor.constraint(equalTo: detailPane.bottomAnchor, constant: -16),
            forkButton.trailingAnchor.constraint(equalTo: resumeButton.leadingAnchor, constant: -8),
            forkButton.centerYAnchor.constraint(equalTo: resumeButton.centerYAnchor),
        ])
    }

    private func configure(_ table: NSTableView, rowHeight: CGFloat, action: Selector?, double: Selector) {
        table.addTableColumn(NSTableColumn(identifier: .init("main")))
        table.headerView = nil
        table.rowHeight = rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = action
        table.doubleAction = double
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    }

    private static func scroll(_ table: NSTableView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    /// A small heading in capitals, letterspaced so the caps don't crowd.
    private static func headingText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: Theme.textDim, .kern: 0.8,
        ])
    }

    private static func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = headingText(text)
        return label
    }

    // MARK: projects

    /// For the self-test.
    var shownProjects: [String] { projects }
    var shownSessionTitles: [String] { shownSessions.map(\.title) }

    private func reloadProjects() {
        let open = AppDelegate.shared.controllers.compactMap(\.project)
        var seen = Set<String>()
        allProjects = (AppDelegate.shared.recentProjects + open).filter { seen.insert($0).inserted }
        DispatchQueue.global(qos: .userInitiated).async { [allProjects] in
            var found: [String: String] = [:]
            for path in allProjects { found[path] = SessionStore.branch(of: path) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.branches = found
                self.projectsTable.reloadData()
                self.reselect()
            }
        }
        applySearch()
    }

    @objc private func searchChanged() { applySearch() }
    func controlTextDidChange(_ obj: Notification) { applySearch() }

    private func applySearch() {
        let previous = current
        let words = search.stringValue.lowercased().split(separator: " ")
        projects = words.isEmpty ? allProjects : allProjects.filter { path in words.allSatisfy { path.lowercased().contains($0) } }
        projectsTable.reloadData()
        let row = previous.flatMap { projects.firstIndex(of: $0) } ?? (projects.isEmpty ? -1 : 0)
        if row >= 0 { projectsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        showProject()
    }

    /// The project shown on the right (kept here: a table reload must not lose it).
    private var current: String?
    var selectedProject: String? { current }

    private func reselect() {
        if let current, let row = projects.firstIndex(of: current), projectsTable.selectedRow != row {
            projectsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    @objc private func projectClicked() { showProject() }

    func select(project: String) {
        guard let row = projects.firstIndex(of: project) else { return }
        projectsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        showProject()
    }

    private func showProject() {
        current = projects[safe: projectsTable.selectedRow]
        guard let project = current else {
            projectName.stringValue = allProjects.isEmpty ? "No projects yet" : "No project matches"
            projectPath.stringValue = allProjects.isEmpty ? "Open a folder to start; it will be listed here." : ""
            openButton.isEnabled = false
            sessions = []
            applyFilter()
            return
        }
        openButton.isEnabled = true
        projectName.stringValue = (project as NSString).lastPathComponent
        var path = RecentProjects.abbreviate(project)
        if let branch = branches[project] ?? SessionStore.branch(of: project) { path += "   ⎇ " + branch }
        projectPath.stringValue = path
        projectPath.toolTip = project
        sessions = cache[project] ?? []
        sessionTabs = SessionTabs()
        applyFilter(loading: cache[project] == nil)
        SessionStore.load(project) { [weak self] listing, tabs in
            guard let self else { return }
            self.cache[project] = listing.sessions
            guard self.selectedProject == project else { return }
            self.sessions = listing.sessions
            self.sessionTabs = tabs
            self.applyFilter(problems: listing.problems)
        }
    }

    @objc func openSelectedProject() {
        guard let project = selectedProject else { return }
        AppDelegate.shared.openProject(at: URL(fileURLWithPath: project), from: nil)
    }

    @objc private func newTerminal() {
        AppDelegate.shared.newWindow(nil)
    }

    // MARK: servers

    /// For the self-test.
    var shownServers: [String] { servers.map(\.name) }
    var connectServerButton: NSButton { connectButton }
    func serverEntry(at index: Int) -> NSButton? { serverList.arrangedSubviews[safe: index] as? NSButton }

    /// The saved hosts, the one connected to last first. With none, only Connect to Server… shows.
    private func reloadServers() {
        let last = UserDefaults.standard.string(forKey: "lastRemoteHost")
        var hosts = RemoteHosts.all
        if let index = hosts.firstIndex(where: { $0.id == last }) { hosts.insert(hosts.remove(at: index), at: 0) }
        servers = Array(hosts.prefix(Self.serverLimit))
        serverList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, host) in servers.enumerated() {
            let entry = ServerEntryButton(host: host)
            entry.tag = index
            entry.target = self
            entry.action = #selector(serverClicked(_:))
            serverList.addArrangedSubview(entry)
            entry.widthAnchor.constraint(equalTo: serverList.widthAnchor).isActive = true
        }
        serversLabel.isHidden = servers.isEmpty
    }

    @objc private func serverClicked(_ sender: NSButton) {
        guard let host = servers[safe: sender.tag] else { return }
        AppDelegate.shared.connect(to: host)
    }

    /// The sheet behind Connect to Server… can save or remove hosts.
    func windowDidEndSheet(_ notification: Notification) { reloadServers() }

    // MARK: sessions

    @objc private func filterChanged() {
        let agents = presentAgents
        agentFilter = filter.selectedSegment <= 0 ? nil : agents[safe: filter.selectedSegment - 1]
        applyFilter()
    }

    @objc private func agentMenuChanged() {
        agentFilter = agentMenu.indexOfSelectedItem <= 0 ? nil : presentAgents[safe: agentMenu.indexOfSelectedItem - 1]
        applyFilter()
    }

    /// Up to three agents fit as buttons beside the heading; more, and they go in a menu.
    static let filterButtons = 3

    /// Shows the agents that have sessions here as filter buttons ("All 12", "Claude Code 9"…), or in a
    /// menu when there are more than fit; nothing for one agent.
    private func showAgentFilter(_ agents: [AgentKind]) {
        let count = { (agent: AgentKind) in self.sessions.filter { $0.agent == agent }.count }
        let buttons = agents.count > 1 && agents.count <= Self.filterButtons
        filter.segmentCount = buttons ? agents.count + 1 : 0
        if buttons {
            filter.setLabel("All  \(sessions.count)", forSegment: 0)
            for (i, agent) in agents.enumerated() {
                filter.setLabel("\(agent.name)  \(count(agent))", forSegment: i + 1)
            }
            filter.selectedSegment = agentFilter.flatMap { agents.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        }
        filter.isHidden = !buttons
        agentMenu.isHidden = agents.count <= Self.filterButtons
        if !agentMenu.isHidden {
            agentMenu.removeAllItems()
            agentMenu.addItem(withTitle: "All agents  \(sessions.count)")
            for agent in agents { agentMenu.addItem(withTitle: "\(agent.name)  \(count(agent))") }
            agentMenu.selectItem(at: agentFilter.flatMap { agents.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        }
    }

    /// Every agent whose sessions are listed: "Claude Code, Codex, … or Copilot CLI".
    static var agentNames: String {
        let names = AgentKind.allCases.map(\.name)
        return names.dropLast().joined(separator: ", ") + " or " + (names.last ?? "")
    }

    /// The agents that have sessions here, in a fixed order.
    private var presentAgents: [AgentKind] { AgentKind.allCases.filter { agent in sessions.contains { $0.agent == agent } } }

    private func applyFilter(loading: Bool = false, problems: [AgentKind: String] = [:]) {
        let agents = presentAgents
        if let agentFilter, !agents.contains(agentFilter) { self.agentFilter = nil }
        showAgentFilter(agents)
        shownSessions = agentFilter.map { agent in sessions.filter { $0.agent == agent } } ?? sessions
        sessionsTable.reloadData()
        if !shownSessions.isEmpty { sessionsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        let none = shownSessions.isEmpty
        empty.isHidden = !none
        if none {
            var text = loading ? "Reading sessions…"
                : "No agent sessions here yet. Conversations you have with \(Self.agentNames) in this folder appear here, ready to pick up again."
            if !loading, !problems.isEmpty {
                text += "\n\nCould not read " + problems.keys.map(\.name).sorted().joined(separator: ", ") + " (its format may have changed)."
            }
            empty.stringValue = text
        }
        resumeButton.keyEquivalent = none ? "" : "\r"
        openButton.keyEquivalent = none ? "\r" : ""
        updateSessionButtons()
    }

    private var selectedSession: AgentSession? { shownSessions[safe: sessionsTable.selectedRow] }

    /// Resume, or Go to Tab for a session open in a tab now; Fork only for an agent that can.
    private func updateSessionButtons() {
        let session = selectedSession
        let inTab = session.map { sessionTabs.tab(of: $0) != nil } ?? false
        resumeButton.title = inTab ? "Go to Tab" : "Resume"
        resumeButton.toolTip = inTab ? "It is open in a tab now: show that tab rather than start it a second time"
            : "Continue it in a new tab, in the folder it was started in"
        resumeButton.isEnabled = session != nil
        forkButton.isEnabled = session?.agent.canFork == true
        if let session, !session.agent.canFork {
            forkButton.toolTip = "\(session.agent.name) cannot fork a session from the command line"
        } else {
            forkButton.toolTip = "Continue a copy, leaving this one as it is (safe while it is open in another terminal)"
        }
    }

    /// For the self-test.
    var resumeTitle: String { resumeButton.title }
    var canFork: Bool { forkButton.isEnabled }
    var filterIsMenu: Bool { !agentMenu.isHidden }

    /// Selects the shown session with this title (the self-test's click).
    func selectSession(titled title: String) {
        guard let row = shownSessions.firstIndex(where: { $0.title == title }) else { return }
        sessionsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    @objc func resumeSelected() {
        guard let session = selectedSession, let project = selectedProject else { return NSSound.beep() }
        AppDelegate.shared.resume(session, fork: false, project: project, tabs: sessionTabs)
    }

    @objc func forkSelected() {
        guard let session = selectedSession, session.agent.canFork, let project = selectedProject else { return NSSound.beep() }
        AppDelegate.shared.resume(session, fork: true, project: project)
    }

    // MARK: tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === projectsTable ? projects.count : shownSessions.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GoToFileRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === sessionsTable {
            let cell = tableView.makeView(withIdentifier: SessionCell.identifier, owner: self) as? SessionCell ?? SessionCell()
            cell.show(shownSessions[row], project: selectedProject, inTab: sessionTabs.tab(of: shownSessions[row]) != nil)
            return cell
        }
        let cell = tableView.makeView(withIdentifier: ProjectCell.identifier, owner: self) as? ProjectCell ?? ProjectCell()
        let path = projects[row]
        cell.show(path: path, branch: branches[path], isOpen: AppDelegate.shared.controllers.contains { $0.project == path })
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if (notification.object as? NSTableView) === projectsTable { showProject() }
        if (notification.object as? NSTableView) === sessionsTable { updateSessionButtons() }
    }
}

/// A saved host on the Welcome window: a server, its name and where it points, lined up with the projects
/// above. A click opens a tab on it.
final class ServerEntryButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }

    init(host: RemoteHost) {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        let icon = NSImageView(image: NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        icon.contentTintColor = Theme.textDim
        let name = NSTextField(labelWithString: host.name)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = Theme.text
        Typography.singleLine(name, truncation: .byTruncatingMiddle)
        let destination = NSTextField(labelWithString: host.destination)
        destination.font = .systemFont(ofSize: 11)
        destination.textColor = Theme.textDim
        Typography.singleLine(destination, truncation: .byTruncatingMiddle)
        destination.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [icon, name, destination] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setAccessibilityElement(false) // the button says it all
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            destination.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 8),
            destination.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            destination.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])
        toolTip = "Open a tab on \(host.name) (\(host.destination)), in \(host.directory)"
        setAccessibilityLabel("\(host.name), \(host.destination)")
        setAccessibilityHelp("Opens a tab on this server")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The labels inside take no clicks: anywhere on the row is the button.
    override func hitTest(_ point: NSPoint) -> NSView? { !isHidden && frame.contains(point) ? self : nil }

    private var rowShape: NSBezierPath { NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 5, yRadius: 5) }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering || isHighlighted else { return }
        Theme.tabHover.setFill()
        rowShape.fill()
    }

    // With the keyboard (Full Keyboard Access), the ring goes round the row.
    override func drawFocusRingMask() { rowShape.fill() }
    override var focusRingMaskBounds: NSRect { bounds }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

/// A project in the Welcome list: its name, its folder (home as ~), and its branch.
final class ProjectCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ProjectCell")
    private let name = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")
    private let branch = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        Typography.singleLine(name, truncation: .byTruncatingMiddle)
        Typography.singleLine(path, truncation: .byTruncatingMiddle)
        Typography.singleLine(branch, truncation: .byTruncatingTail)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = Theme.text
        path.font = .systemFont(ofSize: 11)
        path.textColor = Theme.textDim
        branch.font = .systemFont(ofSize: 11)
        branch.textColor = Theme.textDim
        branch.alignment = .right
        branch.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [name, path, branch] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            name.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            name.trailingAnchor.constraint(lessThanOrEqualTo: branch.leadingAnchor, constant: -8),
            branch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            branch.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            branch.widthAnchor.constraint(lessThanOrEqualToConstant: 110),
            path.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            path.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            path.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(path folder: String, branch head: String?, isOpen: Bool) {
        name.stringValue = (folder as NSString).lastPathComponent + (isOpen ? "  ·  open" : "")
        path.stringValue = RecentProjects.abbreviate((folder as NSString).deletingLastPathComponent)
        branch.stringValue = head.map { "⎇ " + $0 } ?? ""
        toolTip = folder
        setAccessibilityLabel((folder as NSString).lastPathComponent + (head.map { ", branch \($0)" } ?? ""))
    }
}
