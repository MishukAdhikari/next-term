import AppKit
import NextTermCore

/// The way in, and a project switcher: your projects and servers on the left in one list, open projects first, driven
/// from its search field, with the three ways in at its foot (Open…, Connect to Server…, New Terminal); on the right the
/// chosen project with every agent's saved sessions for it, newest first, each one a click from running again in a tab
/// in the right folder, or the chosen server, or on a launch with nothing to list the three ways in as cards.
final class WelcomeWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
                                     NSSearchFieldDelegate, NSMenuItemValidation {
    private let search = NSSearchField()
    /// Open…, Connect to Server… and New Terminal, at the foot of the list's column: three rows alike, none of them
    /// Return's, in one order whatever was used last.
    private let waysInRows = WaysInRows()
    /// The right pane with nothing to list: the three as cards.
    private let waysInCards = WaysInCards()
    /// "At launch:" at the foot of the right pane, the setting Settings › General shows too.
    private let atLaunch = AtLaunchFooter(defaults: AppDelegate.shared?.launchDefaults ?? .standard)
    /// Under the PROJECTS heading with nothing to list: "Projects you open are listed here."
    private let emptyList = NSTextField(wrappingLabelWithString: SwitcherText.emptyList)
    private let projectsTable = NSTableView()
    /// The projects and the saved servers, in that one table.
    private lazy var switcher = WelcomeSwitcherList(table: projectsTable)
    /// Everything there is to list, before the search narrows it.
    private var list = SwitcherList(projects: [], servers: [])
    /// The saved hosts, the one connected to last first: what a server's row connects to.
    private var hosts: [RemoteHost] = []
    /// A closed linked worktree's title ("xCloud ▸ 7027-sso"), by path, once read from git's files.
    private var titles: [String: String] = [:]
    /// The history's folders that were not on disk at the last look. A show looks on the main thread, so the list is
    /// right as it appears; a refresh while it shows leaves these out and looks again off the main thread, so up to 50
    /// folders, one on a network drive that stopped answering among them, never hold the window up as it comes forward.
    private var missing: Set<String> = []
    /// Counts the looks at the folders, so only the newest one's `missing` is kept.
    private var folderLook = 0
    /// The right pane while a server is selected.
    private let serverPane = WelcomeServerPane()
    private let hintLine = SwitcherHintLine()
    /// Over the list when the search finds nothing.
    private let noMatch = NSTextField(wrappingLabelWithString: "")
    /// Tells the rows while ⌘ is held, as long as the window is key.
    private var modifierMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    /// The projects search's count VoiceOver hears once typing settles.
    private var listAnnouncement: DispatchWorkItem?
    private let sessionsTable = NSTableView()
    private let projectName = NSTextField(labelWithString: "")
    private let projectPath = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: "Open Project", target: nil, action: nil)
    private let filter = NSSegmentedControl()
    /// The filter when more agents have sessions here than the buttons fit.
    private let agentMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sessionsTitle = NSTextField(labelWithString: "")
    /// Narrows the chosen project's sessions as you type, within the agent filter (`SearchWords`, as the
    /// projects search and ⌥⌘O match), over each session's title, agent, branch and model. Emptied when another
    /// project is chosen, and when the window is shown again after a close.
    private let sessionSearch = NSSearchField()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let resumeButton = NSButton(title: "Resume", target: nil, action: nil)
    private let forkButton = NSButton(title: "Fork", target: nil, action: nil)
    private let detailPane = NSView()

    private var sessions: [AgentSession] = []
    private var shownSessions: [AgentSession] = []
    /// The sessions the search leaves, before the agent filter: what the filter's counts count.
    private var matchedSessions: [AgentSession] = []
    /// The shown project's sessions are still being read (none cached), and the agents that could not be.
    private var sessionsLoading = false
    private var sessionProblems: [AgentKind: String] = [:]
    /// The search text the list was last narrowed by, and the count VoiceOver hears once typing settles.
    private var appliedSessionQuery = ""
    private var countAnnouncement: DispatchWorkItem?
    private var branches: [String: String] = [:]
    /// Sessions already read, per project, so moving through the list is instant (refreshed in the background).
    private var cache: [String: [AgentSession]] = [:]
    private var agentFilter: AgentKind?
    /// The tabs the shown project's sessions are open in.
    private var sessionTabs = SessionTabs()

    init() {
        let window = WelcomeWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 580),
                                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Welcome to Next Term"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = Theme.background
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 440)
        // File › Open Project… shows it from a project window in full screen too: it comes over that window, on the
        // Space you are in, rather than taking you to the desktop.
        window.collectionBehavior.formUnion([.fullScreenAuxiliary, .moveToActiveSpace])
        super.init(window: window)
        window.delegate = self
        window.keyEquivalentHandler = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }
        window.cancelHandler = { [weak self] in self?.cancel() ?? false }
        build()
        window.center()
        // While it shows, the list follows the windows (a project opened, closed, or in a window more), the history
        // (⌘⌫, Clear Menu) and the keys the jumps and the hint line name.
        let center = NotificationCenter.default
        let history = center.addObserver(forName: ProjectHistoryRecorder.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.listChanged() }
        }
        let keys = center.addObserver(forName: KeyboardShortcuts.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.listChanged() }
        }
        observers = [history, keys]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
    }

    override func showWindow(_ sender: Any?) {
        // Shown again after a close (this controller lives as long as the app), it lists every session, as for
        // another project. Shown while up, or brought back from the Dock, it keeps what was typed.
        if let window, !window.isVisible, !window.isMiniaturized { resetSessionSearch() }
        // Each show starts the selection afresh: shown from a project window, on the other open project used last, so
        // the key that showed it, then Return, switches back.
        reloadProjects(selection: .start)
        super.showWindow(sender)
        window?.makeFirstResponder(projectsTable)
    }

    // MARK: layout

    private func build() {
        guard let content = window?.contentView else { return }

        // Left: the app, search, projects and servers, and the three ways in.
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
        search.placeholderString = "Search projects and servers"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)
        switcher.onSelect = { [weak self] in self?.showSelection() }
        switcher.onActivate = { [weak self] in self?.activateSelection(newWindow: false) }
        switcher.onForget = { [weak self] path in self?.forget(path) }
        let projectsScroll = Self.scroll(projectsTable)
        noMatch.font = .systemFont(ofSize: 12)
        noMatch.textColor = Theme.textDim
        noMatch.maximumNumberOfLines = 3
        noMatch.isHidden = true
        emptyList.font = .systemFont(ofSize: 12)
        emptyList.textColor = Theme.textDim
        emptyList.maximumNumberOfLines = 3
        emptyList.isHidden = true
        for view in [icon, name, versionLabel, search, projectsScroll, noMatch, emptyList, hintLine, waysInRows] as [NSView] {
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
        // Figures all one width, so a count narrowed by the search (padded to the total's width) keeps the filter's size.
        filter.font = .monospacedDigitSystemFont(ofSize: filter.font?.pointSize ?? NSFont.systemFontSize, weight: .regular)
        agentMenu.font = .monospacedDigitSystemFont(ofSize: agentMenu.font?.pointSize ?? NSFont.systemFontSize, weight: .regular)
        sessionSearch.placeholderString = "Search sessions"
        sessionSearch.setAccessibilityLabel("Search agent sessions")
        sessionSearch.delegate = self
        sessionSearch.sendsSearchStringImmediately = true
        sessionSearch.target = self
        sessionSearch.action = #selector(sessionSearchChanged)
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
        for view in [projectName, projectPath, openButton, sessionsTitle, filter, agentMenu, sessionSearch, sessionsScroll, empty,
                     resumeButton, forkButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            detailPane.addSubview(view)
        }

        serverPane.connectButton.target = self
        serverPane.connectButton.action = #selector(openSelectedProject)
        serverPane.isHidden = true
        waysInCards.isHidden = true
        // The cards take the right pane's place; the footer stays under whichever pane shows.
        for view in [left, detailPane, serverPane, waysInCards, atLaunch] as [NSView] {
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
            // The PROJECTS heading is the list's first row, standing where its label stood.
            projectsScroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            projectsScroll.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 6),
            projectsScroll.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -6),
            projectsScroll.bottomAnchor.constraint(equalTo: hintLine.topAnchor, constant: -8),
            noMatch.topAnchor.constraint(equalTo: projectsScroll.topAnchor, constant: 12),
            noMatch.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 6 + SwitcherRowStyle.nameX),
            noMatch.trailingAnchor.constraint(lessThanOrEqualTo: left.trailingAnchor, constant: -20),
            // Under the PROJECTS heading, where the first project's name would start.
            emptyList.topAnchor.constraint(equalTo: projectsScroll.topAnchor, constant: WelcomeSwitcherList.headingRowHeight + 6),
            emptyList.leadingAnchor.constraint(equalTo: noMatch.leadingAnchor),
            emptyList.trailingAnchor.constraint(lessThanOrEqualTo: left.trailingAnchor, constant: -20),
            hintLine.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 20),
            hintLine.trailingAnchor.constraint(lessThanOrEqualTo: left.trailingAnchor, constant: -16),
            // The rows sit 6 pt inside the column, as the list does, so their titles start where the names do.
            hintLine.bottomAnchor.constraint(equalTo: waysInRows.topAnchor, constant: -8),
            waysInRows.leadingAnchor.constraint(equalTo: left.leadingAnchor, constant: 6),
            waysInRows.trailingAnchor.constraint(equalTo: left.trailingAnchor, constant: -6),
            waysInRows.bottomAnchor.constraint(equalTo: left.bottomAnchor, constant: -10),

            detailPane.topAnchor.constraint(equalTo: content.topAnchor),
            detailPane.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            detailPane.leadingAnchor.constraint(equalTo: left.trailingAnchor),
            detailPane.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            serverPane.topAnchor.constraint(equalTo: detailPane.topAnchor),
            serverPane.bottomAnchor.constraint(equalTo: detailPane.bottomAnchor),
            serverPane.leadingAnchor.constraint(equalTo: detailPane.leadingAnchor),
            serverPane.trailingAnchor.constraint(equalTo: detailPane.trailingAnchor),
            waysInCards.topAnchor.constraint(equalTo: detailPane.topAnchor),
            waysInCards.bottomAnchor.constraint(equalTo: atLaunch.topAnchor, constant: -12),
            waysInCards.leadingAnchor.constraint(equalTo: detailPane.leadingAnchor),
            waysInCards.trailingAnchor.constraint(equalTo: detailPane.trailingAnchor),
            // Bottom left, where the project's name starts, level with Resume at the bottom right.
            atLaunch.leadingAnchor.constraint(equalTo: detailPane.leadingAnchor, constant: 28),
            atLaunch.centerYAnchor.constraint(equalTo: resumeButton.centerYAnchor),
            atLaunch.trailingAnchor.constraint(lessThanOrEqualTo: forkButton.leadingAnchor, constant: -16),

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
            // The search sits between the heading and the rows, as the projects search does on the left: the heading
            // and the buttons stay where they were, and the rows start below it.
            sessionSearch.topAnchor.constraint(equalTo: sessionsTitle.bottomAnchor, constant: 10),
            sessionSearch.leadingAnchor.constraint(equalTo: detailPane.leadingAnchor, constant: 24),
            sessionSearch.trailingAnchor.constraint(equalTo: detailPane.trailingAnchor, constant: -24),
            sessionsScroll.topAnchor.constraint(equalTo: sessionSearch.bottomAnchor, constant: 8),
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

    /// A small heading in capitals, letterspaced so the caps don't crowd: 0.8 pt on 11 pt, 7.3 percent, added to the
    /// font's own tracking (`.kern` would set the pairs' kerning instead, and 0 there turns kerning off).
    static func headingText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: Theme.textDim, .tracking: 0.8,
        ])
    }

    // MARK: projects

    /// For the self-test.
    var shownProjects: [String] { switcher.shown.projects.map(\.path) }
    var shownSessionTitles: [String] { shownSessions.map(\.title) }

    /// Where the selection goes when the list is read again.
    enum Selection {
        /// Where a show starts it (`SwitcherSelection.initial`), or with text in the search, on the best match.
        case start
        /// On the same project or server while it is still listed, else on the row that took its place.
        case keep
    }

    /// The projects and servers, read again, keeping the selection: when the window comes to the front, and while it
    /// shows whenever the windows, the history, Recent Projects or the saved hosts change.
    func reloadProjects() { reloadProjects(selection: .keep) }

    private func reloadProjects(selection: Selection) {
        buildList(looksAtFolders: selection == .start)
        applySearch(selection, reloadSessions: selection == .start)
        readBranchesAndTitles()
    }

    /// For the self-test: these projects listed, closed, instead of the open and used ones, and no server.
    func list(projects paths: [String]) {
        list = SwitcherList.build(open: [], history: [], recents: paths, servers: [])
        hosts = []
        applySearch(.keep)
    }

    /// What there is to list: the open projects (as many windows each as the history's recorder last counted, and the
    /// newest time one was in front), then the ones used before, newest first, then Recent Projects' with no recorded
    /// use, then the saved servers. `looksAtFolders` (a show): which of the history's folders are gone is read from
    /// disk here; otherwise the last look's `missing` is left out.
    private func buildList(looksAtFolders: Bool = false) {
        let recorder = ProjectHistoryRecorder.shared
        let open: [SwitcherList.Window] = openWindows(recorder.windowCounts)
        let stored: ProjectHistory = recorder.history
        let history: [ProjectHistory.Entry]
        if looksAtFolders {
            history = stored.existing()
            missing = Self.missing(stored, present: history)
            folderLook += 1
        } else {
            history = stored.entries.filter { (entry: ProjectHistory.Entry) -> Bool in !missing.contains(entry.path) }
        }
        let recents: [String] = AppDelegate.shared.recentProjects
        hosts = Self.savedHosts()
        let servers: [SwitcherServer] = hosts.map { (host: RemoteHost) -> SwitcherServer in SwitcherServer(host) }
        list = SwitcherList.build(open: open, history: history, recents: recents, servers: servers, titles: titles)
    }

    /// A window for each one `counts` has on a project, in the order of the windows, each with its project's title and
    /// the newest time one of its windows was in front.
    private func openWindows(_ counts: [String: Int]) -> [SwitcherList.Window] {
        let controllers: [TerminalWindowController] = AppDelegate.shared.controllers.filter { !$0.hasClosed }
        var windows: [SwitcherList.Window] = []
        var listed: Set<String> = []
        for controller in controllers {
            guard let path = controller.project, let count = counts[path], listed.insert(path).inserted else { continue }
            let same: [TerminalWindowController] = controllers.filter { $0.project == path }
            let lastKey: Date = same.map(\.lastKey).max() ?? .distantPast
            let window = SwitcherList.Window(path: path, title: controller.projectTitle, lastKey: lastKey)
            windows.append(contentsOf: Array(repeating: window, count: count))
        }
        return windows
    }

    /// The saved hosts, the one connected to last first.
    private static func savedHosts() -> [RemoteHost] {
        let last: String? = UserDefaults.standard.string(forKey: "lastRemoteHost")
        var hosts: [RemoteHost] = RemoteHosts.all
        if let index = hosts.firstIndex(where: { $0.id == last }) { hosts.insert(hosts.remove(at: index), at: 0) }
        return hosts
    }

    /// Each listed project's branch, and a linked worktree's title, read off the main thread from git's files, with
    /// which of the history's folders are gone; then the list shows them, the search finds the branches, and the
    /// selection stays. A folder gone at the last look is read too, so one that is back shows with its branch.
    private func readBranchesAndTitles() {
        let stored: ProjectHistory = ProjectHistoryRecorder.shared.history
        let paths: [String] = list.projects.map(\.path) + missing.sorted()
        folderLook += 1
        let look: Int = folderLook
        DispatchQueue.global(qos: .userInitiated).async {
            let gone: Set<String> = Self.missing(stored, present: stored.existing())
            var branches: [String: String] = [:]
            var titles: [String: String] = [:]
            for path in paths where !gone.contains(path) {
                branches[path] = SessionStore.branch(of: path)
                titles[path] = WelcomeSwitcherList.title(ofProject: path)
            }
            DispatchQueue.main.async { [weak self] in
                self?.read(paths, branches: branches, titles: titles, missing: gone, look: look)
            }
        }
    }

    private func read(_ paths: [String], branches found: [String: String], titles named: [String: String],
                      missing gone: Set<String>, look: Int) {
        var changed = false
        // A show or a newer read looked since: theirs stands.
        if look == folderLook, gone != missing {
            missing = gone
            changed = true
        }
        for path in paths {
            branches[path] = found[path]
            if titles[path] != named[path] { changed = true }
            titles[path] = named[path]
        }
        if changed { buildList() }
        applySearch(.keep)
    }

    /// The history's folders not among `present`, the ones on disk.
    private nonisolated static func missing(_ history: ProjectHistory, present: [ProjectHistory.Entry]) -> Set<String> {
        let found: Set<String> = Set(present.map(\.path))
        return Set(history.paths).subtracting(found)
    }

    /// For the self-test: the search field holding `text`, as if typed.
    func searchProjects(_ text: String) {
        search.stringValue = text
        searchChanged()
    }

    /// The search text the list was last narrowed by.
    private var appliedQuery = ""

    @objc private func searchChanged() {
        // Its action and its text-change notice both come for each key: the list is narrowed once.
        guard search.stringValue != appliedQuery else { return }
        applySearch(.start)
        announceListCount()
    }

    func controlTextDidChange(_ obj: Notification) {
        // Two search fields, one delegate: the sessions search must never rerun the projects search.
        if (obj.object as? NSSearchField) === sessionSearch { sessionSearchChanged() } else { searchChanged() }
    }

    /// The list as the search narrows it now, over every project and every saved server.
    private func applySearch(_ selection: Selection, reloadSessions: Bool = false) {
        let query: String = search.stringValue
        appliedQuery = query
        let kept: SwitcherEntry.ID? = switcher.selectedEntry?.id
        let keptIndex: Int? = switcher.selectedIndex
        let lastPick: String? = UserDefaults.standard.string(forKey: SwitcherSelection.lastPickKey)
        let home: String = NSHomeDirectory()
        let shown: SwitcherShown = SwitcherSearch.filter(list, query: query, home: home, branches: branches,
                                                         lastPick: lastPick)
        let origin: String? = AppDelegate.shared.welcomeOrigin?.project
        let start: Int? = SwitcherSelection.afterSearch(shown, query: query, origin: origin, lastPick: lastPick)
        var index: Int? = start
        if selection == .keep, kept != nil || keptIndex != nil {
            let count: Int = shown.entries.count
            let same: Int? = kept.flatMap { (id: SwitcherEntry.ID) -> Int? in shown.index(of: id) }
            let near: Int? = keptIndex.map { (row: Int) -> Int in min(row, count - 1) }
            index = same ?? (count > 0 ? near : nil)
        }
        let searching: Bool = !SearchWords(query).isEmpty
        var folders: [String: String] = [:]
        for host in hosts { folders[host.id] = host.directory }
        switcher.show(shown, openCount: list.openCount, searching: searching, branches: branches, keys: switcherKeys,
                      folders: folders)
        switcher.select(index)
        let none: Bool = searching && shown.isEmpty
        noMatch.stringValue = none ? SwitcherSearch.noMatch(query) : ""
        noMatch.isHidden = !none
        emptyList.isHidden = searching || !list.isEmpty
        showSelection(reloadSessions: reloadSessions)
    }

    /// The jumps' and Close's keys as the menus have them now, so a rebinding carries over.
    private var switcherKeys: SwitcherKeys {
        let shortcuts = KeyboardShortcuts.shared
        let jumps: [KeyChord?] = SwitcherKeys.jumpCommands.map { (id: String) -> KeyChord? in shortcuts.chord(for: id) }
        return SwitcherKeys(jumps: jumps, close: shortcuts.chord(for: SwitcherKeys.closeCommand))
    }

    /// The project shown on the right (kept here: its sessions are read for it).
    private var current: String?
    var selectedProject: String? { current }

    func select(project: String) {
        guard let index = switcher.shown.index(of: .project(project)) else { return }
        switcher.select(index)
        showSelection()
    }

    /// The right pane for the selection: a project with its sessions, a server, or nothing chosen; with nothing at all
    /// to list and nothing typed, the three ways in as cards. A project's sessions are read again when another one is
    /// chosen, or with `reloadSessions` (the window shown again).
    private func showSelection(reloadSessions: Bool = false) {
        let entry: SwitcherEntry? = switcher.selectedEntry
        let host: RemoteHost? = entry?.server.flatMap { (server: SwitcherServer) -> RemoteHost? in
            hosts.first { (host: RemoteHost) -> Bool in host.id == server.id }
        }
        if let host { serverPane.show(host) }
        let cards: Bool = SwitcherWaysIn.showsCards(list, query: appliedQuery)
        waysInCards.isHidden = !cards
        serverPane.isHidden = host == nil || cards
        detailPane.isHidden = host != nil || cards
        showProject(entry?.project, reloadSessions: reloadSessions)
        updateReturnKey()
        updateHint()
    }

    /// Return acts on the selection only, through the right pane's button: Go to Window or Open Project, or Connect.
    /// With nothing selected (nothing listed, or nothing matching) no button has it, and Return does nothing. Outside
    /// the sessions search (where it resumes, `handleKeyEquivalent`) it never resumes a session.
    private func updateReturnKey() {
        let entry: SwitcherEntry? = switcher.selectedEntry
        openButton.keyEquivalent = entry?.project != nil ? "\r" : ""
        serverPane.connectButton.keyEquivalent = entry?.server != nil ? "\r" : ""
    }

    private func showProject(_ project: SwitcherProject?, reloadSessions: Bool) {
        let previous = current
        current = project?.path
        if current != previous { resetSessionSearch() }
        sessionSearch.isEnabled = current != nil
        guard let project else {
            projectName.stringValue = list.projects.isEmpty ? "No projects yet" : "No project matches"
            projectPath.stringValue = list.projects.isEmpty ? "Open a folder to start; it will be listed here." : ""
            projectPath.toolTip = nil
            openButton.isEnabled = false
            openButton.title = "Open Project"
            sessions = []
            sessionsLoading = false
            sessionProblems = [:]
            applyFilter()
            return
        }
        openButton.isEnabled = true
        openButton.title = project.isOpen ? "Go to Window" : "Open Project"
        openButton.toolTip = project.isOpen ? "Bring its window to the front, the one you were in last" : nil
        projectName.stringValue = project.title
        projectPath.attributedStringValue = pathLine(project.path)
        projectPath.toolTip = project.path
        guard current != previous || reloadSessions else { return }
        let path: String = project.path
        sessions = cache[path] ?? []
        sessionTabs = SessionTabs()
        sessionsLoading = cache[path] == nil
        sessionProblems = [:]
        applyFilter()
        SessionStore.load(path) { [weak self] listing, tabs in
            guard let self else { return }
            self.cache[path] = listing.sessions
            guard self.selectedProject == path else { return }
            self.sessions = listing.sessions
            self.sessionTabs = tabs
            self.sessionsLoading = false
            self.sessionProblems = listing.problems
            self.applyFilter()
        }
    }

    /// "~/Code/shop", then its branch after the app's gap, as the list marks a branch.
    private func pathLine(_ path: String) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 12)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.textDim]
        let line = NSMutableAttributedString(string: RecentProjects.abbreviate(path), attributes: attributes)
        if let branch = branches[path] ?? SessionStore.branch(of: path) {
            line.append(Typography.gap(14, font: font))
            line.append(SwitcherRowStyle.branch(branch, font: font, symbolSize: 11, color: Theme.textDim))
        }
        return Typography.truncating(line, .byTruncatingMiddle)
    }

    /// Return, a double-click, the right pane's button: the selection.
    @objc func openSelectedProject() { activateSelection(newWindow: false) }

    private func activateSelection(newWindow: Bool) {
        guard let entry = switcher.selectedEntry else { return }
        activate(entry, newWindow: newWindow)
    }

    /// An open project: its window comes forward and this one closes. A closed one opens as Open Project does, by the
    /// "Open projects in" setting. `newWindow` (⌘↩): in a new window without asking, a second one on an open project.
    /// A server: a window with a tab on it, remembered so the next show starts on it.
    private func activate(_ entry: SwitcherEntry, newWindow: Bool) {
        switch entry {
        case .project(let project):
            // For projects the list's order already starts on the one used last: only a server is remembered.
            UserDefaults.standard.removeObject(forKey: SwitcherSelection.lastPickKey)
            if newWindow {
                AppDelegate.shared.openFolder(project.path, newWindow: true)
            } else if project.isOpen, let window = frontWindow(of: project.path) {
                // Its window in front last: Open Project would bring the first one made.
                window.makeKeyAndOrderFront(nil)
                close()
            } else if WorktreeWindow.repository(ofLinkedWorktree: project.path) != nil {
                // A linked worktree opens in a window of its own, as the Git menu opens it, and stays out of
                // File › Open Recent, which Open Project would add it to.
                AppDelegate.shared.openWorktreeWindow(project.path)
            } else {
                let url = URL(fileURLWithPath: project.path)
                AppDelegate.shared.openProject(at: url, from: AppDelegate.shared.welcomeOrigin)
            }
        case .server(let server):
            guard let host = hosts.first(where: { (host: RemoteHost) -> Bool in host.id == server.id }) else { return }
            UserDefaults.standard.set(host.id, forKey: SwitcherSelection.lastPickKey)
            AppDelegate.shared.connect(to: host)
        }
    }

    /// The window on `path` that was in front last.
    private func frontWindow(of path: String) -> NSWindow? {
        let controllers: [TerminalWindowController] = AppDelegate.shared.controllers
        let windows: [TerminalWindowController] = controllers.filter { (controller: TerminalWindowController) -> Bool in
            controller.project == path && !controller.hasClosed
        }
        let newest: TerminalWindowController? = windows.max { (a: TerminalWindowController, b: TerminalWindowController) -> Bool in
            a.lastKey < b.lastKey
        }
        return newest?.window
    }

    /// ⌘⌫ or Remove from List on a closed project: it leaves this list and File › Open Recent. By its path, as the list
    /// may be read again while Remove from List's menu is up; one that has opened since stays.
    private func forget(_ path: String) {
        let project: SwitcherProject? = switcher.shown.projects.first { (project: SwitcherProject) -> Bool in
            project.path == path
        }
        guard let project, !project.isOpen else { return }
        ProjectHistoryRecorder.shared.forget(project.path)
        // While the window shows, the recorder and Recent Projects tell it as they change.
        if window?.isVisible != true { reloadProjects() }
    }

    // MARK: the switcher's keys

    /// ↓ ↑ (⌃N ⌃P), the page keys, Return and Esc in the projects search move and act on the list while the search
    /// keeps the keyboard. Return and Esc are the switcher's even when they do nothing: with no selection, or Esc on an
    /// empty search with no other window to go back to.
    private func projectsSearchCommand(_ selector: Selector) -> Bool {
        let name: String = NSStringFromSelector(selector)
        if let action = escapeOrSearchAction(name) {
            perform(action)
            return true
        }
        return name == "insertNewline:" || name == "cancelOperation:"
    }

    /// Esc where no field took it, the list having the keyboard: as in the projects search. In the sessions search it
    /// is left as it was.
    private func cancel() -> Bool {
        guard keyboardFocus != .sessions else { return false }
        if let action = escapeOrSearchAction("cancelOperation:") { perform(action) }
        return true
    }

    /// What the projects search's command `selector` does to the list now.
    private func escapeOrSearchAction(_ selector: String) -> SwitcherAction? {
        let empty: Bool = search.stringValue.isEmpty
        let selection: SwitcherEntry? = switcher.selectedEntry
        return SwitcherKeys.action(selector: selector, searchEmpty: empty, selection: selection, otherWindows: otherWindowsOpen)
    }

    private func perform(_ action: SwitcherAction) {
        switch action {
        case .move(let step):
            move(by: step)
        case .page(let pages):
            move(by: pages * switcher.pageSize)
        case .activate(let newWindow):
            activateSelection(newWindow: newWindow)
        case .jump(let row):
            guard let project = switcher.shown.projects[safe: row] else { return }
            activate(.project(project), newWindow: false)
        case .clearSearch:
            (search.currentEditor() as? NSTextView)?.string = ""
            search.stringValue = ""
            searchChanged()
        case .close:
            close()
        case .forget:
            guard case .project(let project)? = switcher.selectedEntry else { return }
            forget(project.path)
        }
    }

    private func move(by step: Int) {
        let count: Int = switcher.shown.entries.count
        guard let index = SwitcherSelection.moved(switcher.selectedIndex, by: step, count: count) else { return }
        switcher.select(index)
        showSelection()
    }

    /// Where the keyboard is: the projects search or the list, the sessions search or theirs, or elsewhere.
    private var keyboardFocus: SwitcherKeys.Focus {
        guard let responder = window?.firstResponder else { return .elsewhere }
        let inSearch: Bool = search.currentEditor().map { (editor: NSText) -> Bool in editor === responder } ?? false
        if responder === projectsTable || inSearch { return .projects }
        let inSessions: Bool = sessionSearch.currentEditor().map { (editor: NSText) -> Bool in editor === responder } ?? false
        if responder === sessionsTable || inSessions { return .sessions }
        return .elsewhere
    }

    /// Another Next Term window is open, shown or minimized (a terminal window, Settings): Esc may close this one
    /// without leaving Next Term with no window at all.
    private var otherWindowsOpen: Bool {
        NSApp.windows.contains { (other: NSWindow) -> Bool in
            guard other !== window, !other.isSheet, !(other is NSPanel) else { return false }
            guard other.styleMask.contains(.titled) else { return false }
            return other.isVisible || other.isMiniaturized
        }
    }

    /// The hint line under the list, for the selection now, and the keys the three ways in show, as the menus have them
    /// now: a rebinding in Settings carries over, and one removed shows no key, nor one this window takes first
    /// (`handleKeyEquivalent`), which would do something else here.
    private func updateHint() {
        let shortcuts = KeyboardShortcuts.shared
        let menus = SwitcherWaysIn { (id: String) -> KeyChord? in shortcuts.chord(for: id) }
        let waysIn: SwitcherWaysIn = menus.notTaken(by: switcherKeys)
        waysInRows.show(waysIn)
        waysInCards.show(waysIn)
        let selection: SwitcherEntry? = switcher.selectedEntry
        let empty: Bool = search.stringValue.isEmpty
        let parts: [String] = SwitcherHint.parts(selection: selection, searchEmpty: empty, otherWindows: otherWindowsOpen,
                                                 waysIn: waysIn)
        hintLine.show(parts)
    }

    /// For the self-test.
    var hintParts: [String] { hintLine.parts }
    var noMatchText: String? { noMatch.isHidden ? nil : noMatch.stringValue }
    var emptyListText: String? { emptyList.isHidden ? nil : emptyList.stringValue }
    /// Open…, Connect to Server… and New Terminal: the rows at the foot of the list, and the first launch's cards.
    var wayInRows: [WayInRow] { waysInRows.rows }
    var wayInCards: [WayInCard] { waysInCards.cards }
    var cardsShown: Bool { !waysInCards.isHidden }
    var atLaunchFooter: AtLaunchFooter { atLaunch }
    var selectedEntry: SwitcherEntry? { switcher.selectedEntry }
    var returnButtonTitle: String? {
        guard let entry = switcher.selectedEntry else { return nil }
        return entry.server != nil ? serverPane.connectButton.title : openButton.title
    }

    /// What VoiceOver hears once typing settles in the projects search: "3 projects, 1 server".
    var listCountText: String {
        let shown: SwitcherShown = switcher.shown
        guard !shown.isEmpty else { return "No project or server matches" }
        var parts: [String] = []
        if !shown.projects.isEmpty { parts.append(Self.counted(shown.projects.count, "project")) }
        if !shown.servers.isEmpty { parts.append(Self.counted(shown.servers.count, "server")) }
        return parts.joined(separator: ", ")
    }

    private static func counted(_ count: Int, _ noun: String) -> String {
        count == 1 ? "1 " + noun : "\(count) \(noun)s"
    }

    /// For the self-test: what VoiceOver was last told of the list.
    private(set) var announcedListCount: String?

    private func announceListCount() {
        listAnnouncement?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let window = self.window, window.isVisible else { return }
            let text: String = self.listCountText
            self.announcedListCount = text
            NSAccessibility.post(element: window, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        listAnnouncement = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.announceDelay, execute: work)
    }

    // MARK: window

    /// Back in front, the list is read again: windows may have opened, closed or come forward behind it.
    func windowDidBecomeKey(_ notification: Notification) {
        reloadProjects()
        // A quit's resume question can have set it since.
        atLaunch.refresh()
        watchModifiers(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        watchModifiers(false)
    }

    /// The list follows what it lists while the window shows; hidden, the next show reads it.
    private func listChanged() {
        guard window?.isVisible == true else { return }
        reloadProjects()
    }

    /// ⌘ held while the window is key shows the jump keys in the first nine projects' rows. A local monitor: the
    /// search's field editor has the keyboard, and the window would not be told.
    private func watchModifiers(_ on: Bool) {
        if on, modifierMonitor == nil {
            modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.modifiersChanged(event.modifierFlags)
                return event
            }
            modifiersChanged(NSEvent.modifierFlags)
        } else if !on {
            if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
            modifierMonitor = nil
            switcher.showJumps(false)
        }
    }

    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        guard window?.isKeyWindow == true else { return switcher.showJumps(false) }
        switcher.showJumps(flags.intersection(.deviceIndependentFlagsMask).contains(.command))
    }

    // MARK: servers

    /// For the self-test.
    var shownServers: [String] { switcher.shown.servers.map(\.name) }
    /// Connect to Server…'s row: the sheet for a server not listed.
    var connectServerButton: NSButton { waysInRows.row(.connect) }
    var serverPaneShown: Bool { !serverPane.isHidden }
    var serverPaneLines: [String] { serverPane.shownLines }

    /// For the self-test: a button whose click connects to the listed server at `index`, as its row's Return does.
    func serverEntry(at index: Int) -> NSButton? {
        guard let server = switcher.shown.servers[safe: index] else { return nil }
        let button = NSButton(title: server.name, target: self, action: #selector(serverEntryClicked(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(server.id)
        return button
    }

    @objc private func serverEntryClicked(_ sender: NSButton) {
        let id: String? = sender.identifier?.rawValue
        guard let server = switcher.shown.servers.first(where: { (server: SwitcherServer) -> Bool in server.id == id }) else { return }
        activate(.server(server), newWindow: false)
    }

    /// The sheet behind Connect to Server… can save or remove hosts.
    func windowDidEndSheet(_ notification: Notification) { reloadProjects() }

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
    /// menu when there are more than fit; nothing for one agent. While a search narrows the list, the counts are
    /// of the sessions it matches, and the agents stay: one with no match shows 0.
    private func showAgentFilter(_ agents: [AgentKind], searching: Bool) {
        func label(_ name: String, _ agent: AgentKind?) -> String {
            let total = agent.map { agent in sessions.filter { $0.agent == agent }.count } ?? sessions.count
            guard searching else { return "\(name)  \(total)" }
            let matched = agent.map { agent in matchedSessions.filter { $0.agent == agent }.count } ?? matchedSessions.count
            return Self.countLabel(name, matched, total: total)
        }
        let buttons = agents.count > 1 && agents.count <= Self.filterButtons
        filter.segmentCount = buttons ? agents.count + 1 : 0
        if buttons {
            filter.setLabel(label("All", nil), forSegment: 0)
            for (i, agent) in agents.enumerated() {
                filter.setLabel(label(agent.name, agent), forSegment: i + 1)
            }
            filter.selectedSegment = agentFilter.flatMap { agents.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        }
        filter.isHidden = !buttons
        agentMenu.isHidden = agents.count <= Self.filterButtons
        if !agentMenu.isHidden {
            agentMenu.removeAllItems()
            agentMenu.addItem(withTitle: label("All agents", nil))
            for agent in agents { agentMenu.addItem(withTitle: label(agent.name, agent)) }
            agentMenu.selectItem(at: agentFilter.flatMap { agents.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        }
    }

    /// "Claude Code  3" for 3 of 50: figure spaces in front keep the count as wide as the total it narrows, so the
    /// filter keeps its size as you type (its font's figures are all one width).
    static func countLabel(_ name: String, _ count: Int, total: Int) -> String {
        let figures = String(count)
        let room = max(0, String(total).count - figures.count)
        return name + "  " + String(repeating: "\u{2007}", count: room) + figures
    }

    /// Every agent whose sessions are listed: "Claude Code, Codex, … or Copilot CLI".
    static var agentNames: String {
        let names = AgentKind.allCases.map(\.name)
        return names.dropLast().joined(separator: ", ") + " or " + (names.last ?? "")
    }

    /// The agents that have sessions here, in a fixed order.
    private var presentAgents: [AgentKind] { AgentKind.allCases.filter { agent in sessions.contains { $0.agent == agent } } }

    /// The list: the project's sessions the search matches, of the agent chosen in the filter.
    private func applyFilter() {
        let agents = presentAgents
        if let agentFilter, !agents.contains(agentFilter) { self.agentFilter = nil }
        let query = sessionSearch.stringValue
        appliedSessionQuery = query
        matchedSessions = AgentSessions.matching(sessions, query)
        showAgentFilter(agents, searching: !SearchWords(query).isEmpty)
        shownSessions = agentFilter.map { agent in matchedSessions.filter { $0.agent == agent } } ?? matchedSessions
        sessionsTable.reloadData()
        if !shownSessions.isEmpty { sessionsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        let none = shownSessions.isEmpty
        empty.isHidden = !none
        if none {
            let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            var text = sessionsLoading ? "Reading sessions…"
                : "No agent sessions here yet. Conversations you have with \(Self.agentNames) in this folder appear here, ready to pick up again."
            if !typed.isEmpty, !sessions.isEmpty {
                text = "No sessions match “" + typed + "”."
            } else if !sessionsLoading, !sessionProblems.isEmpty {
                text += "\n\nCould not read " + sessionProblems.keys.map(\.name).sorted().joined(separator: ", ") + " (its format may have changed)."
            }
            empty.stringValue = text
        }
        updateSessionButtons()
    }

    // MARK: sessions search

    @objc private func sessionSearchChanged() {
        // Its action and its text-change notice both come for each key: the list is narrowed once.
        guard sessionSearch.stringValue != appliedSessionQuery else { return }
        applyFilter()
        announceSessionCount()
    }

    /// Another project: an empty search, so its sessions all show.
    private func resetSessionSearch() {
        countAnnouncement?.cancel()
        countAnnouncement = nil
        sessionSearch.stringValue = ""
    }

    /// How many the search leaves, as VoiceOver says it.
    var sessionCountText: String {
        switch shownSessions.count {
        case 0: return "No sessions match"
        case 1: return "1 session"
        default: return "\(shownSessions.count) sessions"
        }
    }

    /// For the self-test: what VoiceOver was last told.
    private(set) var announcedSessionCount: String?

    /// VoiceOver hears the count once typing settles, not after every key.
    private func announceSessionCount() {
        countAnnouncement?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let window = self.window, window.isVisible else { return }
            let text = self.sessionCountText
            self.announcedSessionCount = text
            NSAccessibility.post(element: window, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        countAnnouncement = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.announceDelay, execute: work)
    }

    static let announceDelay = 0.6

    /// ↓ and ↑ move the selection in the list while the search keeps the keyboard; Return does what Resume does
    /// while it is on (and nothing else: never Open Project); Esc empties the search, and on an empty one does
    /// what it did before.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === search { return projectsSearchCommand(selector) }
        guard control === sessionSearch else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSessionSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)): moveSessionSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)): resumeFromSearch()
        case #selector(NSResponder.cancelOperation(_:)):
            guard !textView.string.isEmpty else { return false }
            textView.string = ""
            sessionSearch.stringValue = ""
            sessionSearchChanged()
        default: return false
        }
        return true
    }

    private func moveSessionSelection(by step: Int) {
        guard !shownSessions.isEmpty else { return }
        let row = max(0, min(shownSessions.count - 1, sessionsTable.selectedRow + step))
        sessionsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        sessionsTable.scrollRowToVisible(row)
    }

    private func resumeFromSearch() {
        if resumeButton.isEnabled { resumeSelected() }
    }

    /// The sessions search is being typed in.
    private var sessionSearchHasKeyboard: Bool {
        guard let editor = sessionSearch.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    /// The keys the window takes before its buttons and the menus do: Find… (⌘F) goes to the sessions search while
    /// a project's sessions show, and Return in that search resumes (the right pane's button holds Return everywhere
    /// else). Then the switcher's, while this window has the keyboard: ⌘1 to ⌘9 (Select Tab 1 to 9's keys) and ⌘W
    /// (Close Tab's) anywhere in it; ⌘↩, ⌘⌫ (on an empty search only) and ⌃N ⌃P in the projects search or the list.
    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let chord = KeyboardShortcuts.chord(from: event)
        if let chord, chord == Self.findChord { return focusSessionSearch() }
        if sessionSearchHasKeyboard, chord == KeyChord(key: "\r") {
            resumeFromSearch()
            return true
        }
        guard let chord, let window, window.isKeyWindow, window.attachedSheet == nil else { return false }
        let keys: SwitcherKeys = switcherKeys
        let action: SwitcherAction? = keys.action(chord: chord, focus: keyboardFocus, searchEmpty: search.stringValue.isEmpty,
                                                  selection: switcher.selectedEntry, projects: switcher.shown.projects.count)
        guard let action else { return false }
        perform(action)
        return true
    }

    /// Find…'s key now (⌘F, unless it was given another).
    private static var findChord: KeyChord? {
        let item = KeyboardShortcuts.shared.commands.first { $0.id == "performFindPanelAction:#1" }?.item
        return item.flatMap(KeyboardShortcuts.chord(of:))
    }

    /// Find… chosen in the menu bar, as its key does (`handleKeyEquivalent`).
    @objc func performFindPanelAction(_ sender: Any?) {
        if !focusSessionSearch() { NSSound.beep() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(performFindPanelAction(_:)) else { return true }
        return current != nil && item.tag == Int(NSFindPanelAction.showFindPanel.rawValue)
    }

    /// To the sessions search, its text selected; false with no project's sessions shown.
    @discardableResult
    func focusSessionSearch() -> Bool {
        guard current != nil, let window else { return false }
        window.makeFirstResponder(sessionSearch)
        sessionSearch.currentEditor()?.selectAll(nil)
        return true
    }

    /// For the self-test.
    var sessionQuery: String {
        get { sessionSearch.stringValue }
        set {
            sessionSearch.stringValue = newValue
            sessionSearchChanged()
        }
    }
    var sessionSearchField: NSSearchField { sessionSearch }
    /// For the self-test: the filter set to `agent` (nil: All), as a click on it does.
    func filterSessions(by agent: AgentKind?) {
        agentFilter = agent
        applyFilter()
    }
    var sessionFilterLabels: [String] {
        filterIsMenu ? agentMenu.itemTitles : (0..<filter.segmentCount).compactMap { filter.label(forSegment: $0) }
    }
    var emptyText: String? { empty.isHidden ? nil : empty.stringValue }
    var selectedSessionTitle: String? { selectedSession?.title }

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

    // The sessions'; the projects and servers have their own (`WelcomeSwitcherList`).
    func numberOfRows(in tableView: NSTableView) -> Int { shownSessions.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GoToFileRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: SessionCell.identifier, owner: self) as? SessionCell ?? SessionCell()
        cell.show(shownSessions[row], project: selectedProject, inTab: sessionTabs.tab(of: shownSessions[row]) != nil)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if (notification.object as? NSTableView) === sessionsTable { updateSessionButtons() }
    }
}

/// The Welcome window, which lets its controller take a key before its buttons and the menus do
/// (`WelcomeWindowController.handleKeyEquivalent`), and Esc that no field took.
final class WelcomeWindow: NSWindow {
    var keyEquivalentHandler: ((NSEvent) -> Bool)?
    var cancelHandler: (() -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyEquivalentHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if cancelHandler?() == true { return }
        super.cancelOperation(sender)
    }
}
