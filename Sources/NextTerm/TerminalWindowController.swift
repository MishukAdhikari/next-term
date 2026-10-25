import AppKit
import Combine
import NextTermCore

/// Window that handles Ctrl-Tab / Ctrl-Shift-Tab before the terminal sees it.
final class TerminalWindow: NSWindow {
    /// The terminal window in front, shown and not in the Dock: the main or key one when it is one, else the frontmost
    /// (behind Settings or a panel).
    static var front: TerminalWindow? {
        let candidates = [NSApp.mainWindow, NSApp.keyWindow] + NSApp.orderedWindows
        return candidates.lazy.compactMap { $0 as? TerminalWindow }.first { $0.isVisible && !$0.isMiniaturized }
    }

    var onControlTab: ((_ backwards: Bool) -> Void)?
    /// A key down for a terminal, before the terminal gets it (Tab completion); true: taken.
    var onTerminalKey: ((NSEvent, NextTermView) -> Bool)?
    /// A real key is being dispatched to a terminal: what it writes now is the user's (CompletionSession).
    private(set) var dispatchingKey = false
    /// Whatever took the keyboard (a click in a pane, a move between panes).
    var onFirstResponderChange: ((NSResponder?) -> Void)?

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        // A tab an agent opened that the user hasn't chosen takes no keyboard, whatever asks for it (AgentArrival).
        if let view = responder as? NextTermView, view.awaitsChoice { return false }
        let made = super.makeFirstResponder(responder)
        if made { onFirstResponderChange?(firstResponder) }
        return made
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown { UserKeys.pressed() }
        // A click on a tab an agent opened chooses it: it takes the keyboard, and the click reaches nothing in it (a
        // button in the agent's screen).
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type), let view = awaitingTerminal(at: event.locationInWindow) {
            view.awaitsChoice = false
            _ = makeFirstResponder(view)
            return
        }
        if event.type == .keyDown, event.keyCode == 48 /* Tab */,
           event.modifierFlags.intersection([.command, .option, .control]) == .control {
            onControlTab?(event.modifierFlags.contains(.shift))
            return
        }
        // A key pressed in a terminal: you are at that tab yourself (SwiftTerm's keyDown cannot be overridden).
        if event.type == .keyDown, let terminal = firstResponder as? NextTermView {
            terminal.onKeyboard?()
            if onTerminalKey?(event, terminal) == true { return }
            dispatchingKey = true
            super.sendEvent(event)
            dispatchingKey = false
            return
        }
        super.sendEvent(event)
    }

    /// The terminal under `point` (window coordinates), if it waits for the user to choose it.
    func awaitingTerminal(at point: NSPoint) -> NextTermView? {
        var view = contentView?.superview?.hitTest(point) ?? contentView?.hitTest(point)
        while let current = view {
            if let terminal = current as? NextTermView { return terminal.awaitsChoice ? terminal : nil }
            view = current.superview
        }
        return nil
    }

    #if DEBUG
    /// For the self-test: `body` runs as a key's dispatch does.
    func asKey(_ body: () -> Void) {
        dispatchingKey = true
        body()
        dispatchingKey = false
    }
    #endif
}

/// A split view whose one-point lines show only between two panes that both show (the sidebar and the work
/// area, the editor and the terminal, a tab's panes): never beside a hidden pane, where there is nothing on
/// the other side to set apart, and never over a pane.
///
/// AppKit's own dividers are never drawn: on macOS 26 each is a layer of its own above the panes, and it kept
/// the one beside a hidden pane showing, where the divider last was (the editor's share, once its last file
/// closed) until the split was laid out again, then along the edge of the pane that took the room. That drew
/// a line down through the terminal and its tab bar, over its text. The lines are this view's own instead,
/// put where SplitDivider.lines says from where the panes are, each time a pane moves, shows or hides.
class HairlineSplitView: NSSplitView {
    /// The line between two panes that show.
    var lineColor: NSColor { Theme.background }
    override var dividerColor: NSColor { .clear }
    override var dividerThickness: CGFloat { 1 }

    private var lines: [Line] = []
    /// Each pane's isHidden, watched: whatever shows or hides a pane, its lines follow.
    private var watching: [ObjectIdentifier: AnyCancellable] = [:]

    /// The lines drawn, in this view's coordinates.
    var drawnLines: [NSRect] { lines.filter { !$0.isHidden }.map(\.frame) }
    /// The panes were placed again (they moved, showed or hid): the top row's glow, placed in the window, follows.
    var onPanesPlaced: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        arrangesAllSubviews = false // the lines are subviews, not panes
        NotificationCenter.default.addObserver(self, selector: #selector(panesMoved), name: NSSplitView.didResizeSubviewsNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        placeLines()
    }

    override func adjustSubviews() {
        super.adjustSubviews()
        placeLines()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        placeLines()
    }

    override func setPosition(_ position: CGFloat, ofDividerAt dividerIndex: Int) {
        super.setPosition(position, ofDividerAt: dividerIndex)
        placeLines()
    }

    /// A divider dragged.
    @objc private func panesMoved() { placeLines() }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard !(subview is Line) else { return }
        watching[ObjectIdentifier(subview)] = subview.publisher(for: \.isHidden, options: []).sink { [weak self] _ in self?.placeLines() }
        needsLayout = true
    }

    override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        watching[ObjectIdentifier(subview)] = nil
        needsLayout = true
    }

    private func placeLines() {
        let panes = arrangedSubviews.map { SplitDivider.Pane(frame: $0.frame, hidden: $0.isHidden) }
        let rects = SplitDivider.lines(between: panes, sideBySide: isVertical, thickness: dividerThickness)
        while lines.count < rects.count {
            let line = Line()
            addSubview(line)
            lines.append(line)
        }
        // On whole pixels: a divider can sit on a half point, which a 1x screen would draw as a blurred 2-pixel line.
        let snap: AlignmentOptions = [.alignMinXNearest, .alignMinYNearest, .alignWidthNearest, .alignHeightNearest]
        for (index, line) in lines.enumerated() {
            let shows = index < rects.count
            let rect = shows ? backingAlignedRect(rects[index], options: snap) : .zero
            if shows, line.frame != rect { line.frame = rect }
            if line.isHidden == shows { line.isHidden = !shows }
            line.color = lineColor
        }
        onPanesPlaced?()
    }

    /// One line: a layer's colour, no drawing of its own. Presses go through to the split view, which
    /// grabs its divider there.
    private final class Line: NSView {
        var color: NSColor = .clear {
            didSet { if color != oldValue { needsDisplay = true } }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() { layer?.backgroundColor = color.cgColor }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Between the sidebar and the work area: a quiet line in the theme's colour.
final class ThemedSplitView: HairlineSplitView {}

/// Between the editor and the terminal: both have the same background, so the line between them must
/// show (a hairline a few shades lighter), and it is easy to grab (see effectiveRect).
final class WorkSplitView: HairlineSplitView {
    static let line = NSColor(hex: 0x393B40)
    override var lineColor: NSColor { Self.line }
}

final class TerminalWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate, NSMenuItemValidation,
                                      TabBarViewDelegate, TerminalTabDelegate, ProjectSidebarDelegate, FindInFilesDelegate,
                                      EditorAreaDelegate {
    /// The tabs in the tab bar: each one terminal, or several split side by side.
    private(set) var groups: [PaneGroup] = []
    /// Every terminal in the window, tab by tab, pane by pane.
    var tabs: [TerminalTab] { groups.flatMap(\.panes) }
    /// The tab bar's selected tab (an index into `groups`).
    private(set) var activeIndex = 0
    let tabBar = TabBarView(frame: .zero)
    /// With Tabs: Left or Right, the tabs as a list down that side of the terminal, under its bar, and where it sits
    /// and how wide (TerminalWindowTabList.swift).
    let tabList = TabListView(frame: .zero)
    let tabListPlace = TabListPlacement()
    let sidebar = ProjectSidebarView(frame: NSRect(x: 0, y: 0, width: ProjectSidebarView.defaultWidth, height: 600))
    private let splitView = ThemedSplitView()
    /// The window's split view, [sidebar | work area] or mirrored: the window column's host holds it beside the column.
    var outerSplitView: ThemedSplitView { splitView }
    /// The window's content: the window column at its outer edge, beside the split view (TerminalWindowColumn.swift).
    private(set) lazy var columnHost = WindowColumnHost(content: splitView)
    private let mainPane = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    /// [ open files ] over [ terminal tabs ], like an IDE. The editor part is hidden while no file is open.
    let workSplit = WorkSplitView()
    let editorArea = EditorArea(frame: NSRect(x: 0, y: 0, width: 800, height: 360))
    let terminalPane = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
    let container = NSView()
    /// Unsaved files were dealt with (saved or discarded) for this close.
    private var editorsConfirmed = false
    /// In full screen (or about to be): no traffic lights in the way. Set by the window's full-screen notifications, and
    /// by the self-test, which checks the insets without a real transition.
    var isFullScreen = false
    /// Last state announced to VoiceOver per tab, so each change is announced once.
    private var announcedStates: [UUID: TabState] = [:]
    private var projectKey: String?
    /// The offer to open a project for an agent in the home folder came up here (offerProjectForHomeAgent): once a window.
    private(set) var offeredProjectForAgent = false
    /// Browse Home Folder was clicked in this window's "No project open": while its tab is in no project, the tree shows
    /// the home folder, as files only (ProjectSidebarView.browsingOnly).
    private(set) var browsesHome = false
    private var ticker: Timer?
    private var tickCount = 0
    private var closeConfirmed = false
    /// Called when the window closes; the flag says the Welcome window follows if no other window is left
    /// (Close Project, or the last tab closed).
    var onClose: ((TerminalWindowController, _ welcome: Bool) -> Void)?
    /// The project this window is for: the sidebar stays on it and new tabs open in it by default
    /// (you can still `cd` anywhere). nil: a plain terminal window whose sidebar follows the active tab.
    private(set) var project: String? {
        didSet {
            let repository = project.flatMap(WorktreeWindow.repository(ofLinkedWorktree:))
            projectTitle = Self.title(ofProject: project, repository: repository)
            isWorktree = repository != nil
            repositoryCheckout = repository?.mainCheckout
            projectColorKey = ProjectColors.key(forProject: project, repository: repository)
            takeProjectColor()
        }
    }
    /// The project's name in the title, the Window menu and notifications: its folder's, or for a linked
    /// worktree "xCloud ▸ 7027-sso", its repository's and its own.
    private(set) var projectTitle = ""
    /// The project is a linked worktree, read with its title.
    private(set) var isWorktree = false
    /// For a linked worktree, its repository's main checkout, read with its title: the window column nests the window
    /// under its repository's.
    private(set) var repositoryCheckout: String?
    /// The window's id in the index of every window (AppDelegate.windowIndex): its own, the same while it is open.
    let indexID: Int
    private static var lastIndexID = 0
    /// Where the project keeps its colour (ProjectColors.key): for a linked worktree its repository's main checkout, so
    /// every worktree window of a repository has one colour. nil with no project, or the home folder: no colour.
    private(set) var projectColorKey: String?
    /// The project's colour as View › Project Color keeps it (nil: none, or None for This Project, or no project).
    private(set) var projectColorEntry: ProjectColors.Entry?
    var projectColor: ProjectColor? { projectColorEntry?.color }
    /// The window is being made key to bring an agent's tab forward (AgentArrival), not by the user.
    var keyingForAgent = false
    /// The window closed. AppDelegate drops it from its windows a moment later (windowClosed): until then, nothing may
    /// open a project or a tab in it.
    private(set) var hasClosed = false

    /// `repository`: the one `project` is a linked worktree of (WorktreeWindow.repository), read once for the title and
    /// the colour.
    static func title(ofProject project: String?, repository: WorktreeWindow.Repository?) -> String {
        guard let project else { return "" }
        let folder = (project as NSString).lastPathComponent
        guard let repository else { return folder }
        return WorktreeWindow.title(repository: repository.name, folder: folder)
    }
    private var opensWelcome = false
    /// The sheet asking to save before the last tab takes the window is up: it alone decides.
    private var askingToSave = false
    /// Save or Don't Save was answered for closing this tab, then End Session: until its tmux session has
    /// ended, the tab closes without asking again, unless a file was edited since (`edits`: the unsaved
    /// files then, and their text).
    private var saveAnswered: (tab: TerminalTab, edits: [(EditorDocument, String)])?
    /// When this window last had the keyboard, so a Dock click brings back the one used last.
    private(set) var lastKey = Date.distantPast
    private(set) lazy var finder: FindInFilesController = {
        let controller = FindInFilesController()
        controller.delegate = self
        return controller
    }()

    var activeGroup: PaneGroup? { groups[safe: activeIndex] }
    /// The terminal with the keyboard: the selected tab's focused pane.
    var activeTab: TerminalTab? { activeGroup?.focused }
    func group(of tab: TerminalTab) -> PaneGroup? { groups.first { $0.contains(tab) } }

    /// `firstTab` false: a window the restore fills (`insertRestored`), with no tab of its own. `byAgent`: an agent opened
    /// the window over MCP, so its first tab waits for the user to choose it (AgentArrival).
    init(directory: String?, project: String? = nil, firstTab: Bool = true, byAgent: Bool = false) {
        self.project = project.map(canonicalPath)
        Self.lastIndexID += 1
        indexID = Self.lastIndexID
        // Swift runs no didSet in init: the title and the colour's key here, the colour once the bars exist.
        let repository = self.project.flatMap(WorktreeWindow.repository(ofLinkedWorktree:))
        projectTitle = Self.title(ofProject: self.project, repository: repository)
        isWorktree = repository != nil
        repositoryCheckout = repository?.mainCheckout
        projectColorKey = ProjectColors.key(forProject: self.project, repository: repository)
        let window = TerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Next Term" // until its first tab names it (updateTitle)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.background
        window.minSize = NSSize(width: 420, height: 240)
        window.tabbingMode = .disallowed // our own tabs, not the system's
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)

        window.delegate = self
        window.onControlTab = { [weak self] backwards in self?.cycleTab(by: backwards ? -1 : 1) }
        // Tab completion's list first, then a suggestion's keys.
        window.onTerminalKey = { [weak self] event, view in
            guard let self else { return false }
            if self.completions.handle(event, in: view) {
                self.ghosts.tabListTook(in: view)
                return true
            }
            return self.ghosts.handle(event, in: view)
        }
        window.onFirstResponderChange = { [weak self] responder in
            self?.completions.responderChanged()
            self?.ghosts.responderChanged(to: responder)
            guard let self, let view = responder as? NextTermView, let tab = self.tabs.first(where: { $0.view === view }) else { return }
            // Typing into a folded terminal (behind the rail, or under its bar above or below the editor): it opens.
            if self.terminalCollapsed { self.expandTerminal() }
            self.paneFocused(tab)
        }

        // [ Project sidebar | tab bar over terminals ], both reaching up into the title bar, with the window column at the
        // outer edge while two or more windows are open.
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(mainPane)
        window.contentView = columnHost
        installWindowColumn()
        sidebar.delegate = self

        tabBar.delegate = self
        tabBar.moreMenu = LayoutMenu.terminal
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        terminalPane.addSubview(container)
        terminalPane.addSubview(tabBar)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: terminalPane.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: terminalPane.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: terminalPane.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            containerLeading,
            containerTrailing,
            container.bottomAnchor.constraint(equalTo: terminalPane.bottomAnchor),
        ])
        installTabList()
        installRail()
        workSplit.isVertical = false
        workSplit.dividerStyle = .thin
        workSplit.delegate = self
        workSplit.addArrangedSubview(editorArea)
        workSplit.addArrangedSubview(terminalPane)
        workSplit.translatesAutoresizingMaskIntoConstraints = false
        mainPane.addSubview(workSplit)
        NSLayoutConstraint.activate([
            workSplit.topAnchor.constraint(equalTo: mainPane.topAnchor),
            workSplit.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor),
            workSplit.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor),
            workSplit.bottomAnchor.constraint(equalTo: mainPane.bottomAnchor),
        ])
        editorArea.delegate = self
        editorArea.onShowChanges = { [weak self] url in self?.showChanges(of: url) }
        editorArea.onSendToAgent = { [weak self] items in self?.send(items) }
        editorArea.tabBar.onReveal = { [weak self] in self?.revealInSidebar(nil) }
        sidebar.header.onBranchClick = { [weak self] in self?.showBranches(nil) }
        sidebar.header.onSync = { [weak self] pull in pull ? self?.gitUpdate(nil) : self?.gitPush(nil) }
        sidebar.header.onSummaryClick = { [weak self] in self?.showUncommittedChanges() }
        sidebar.onHeadChange = { [weak self] in self?.editorArea.headMoved() }
        sidebar.onBrowseHome = { [weak self] in self?.browseHomeFolder() }
        // A right-click on the top row, whichever bar is there: View › Project Color's choices for this window.
        let colorMenu: () -> NSMenu? = { [weak self] in self?.projectColorMenu() }
        for bar in [tabBar, editorArea.tabBar] { bar.onTopRowMenu = colorMenu }
        sidebar.header.onTopRowMenu = colorMenu
        terminalRail.onTopRowMenu = colorMenu
        windowColumn.onTopRowMenu = colorMenu
        NotificationCenter.default.addObserver(self, selector: #selector(projectColorsChanged), name: ProjectColorStore.changed, object: nil)
        for split in [splitView, workSplit] as [HairlineSplitView] { split.onPanesPlaced = { [weak self] in self?.projectGlowMoved() } }
        // The collapse button's tooltip names ⌘J, or the key Settings gives it instead.
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutsChanged), name: KeyboardShortcuts.changed, object: nil)
        // Lines selected in a diff go to the agents, as the editor's selection does.
        NotificationCenter.default.addObserver(self, selector: #selector(diffSelectionChanged(_:)), name: DiffShare.changed, object: nil)
        applyLayout() // the editor area starts hidden: nothing is open
        setSidebarVisible(AppDelegate.shared.sidebarVisible)
        takeProjectColor()

        let ticker = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        ticker.tolerance = 0.03
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
        // A window that refreshed once a second while no one could see it is up to date the moment it shows again.
        for (name, ofApp) in NSWindow.visibilityNotifications {
            NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged), name: name, object: ofApp ? NSApp : window)
        }

        if firstTab { addTab(directory: self.project ?? directory, byAgent: byAgent) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: tabs

    /// `select` false: the tab opens behind the current one. `byAgent`: an agent opened it over MCP, so it waits for the
    /// user to choose it before it takes the keyboard (NextTermView.awaitsChoice, AgentArrival).
    @discardableResult
    func addTab(directory: String?, select selectIt: Bool = true, byAgent: Bool = false) -> TerminalTab {
        insert(makeTab(directory: directory, byAgent: byAgent), select: selectIt)
    }

    /// A tab on a server: ssh in its pty, to a shell, tmux session or herdr there.
    /// `atEnd`: after the last tab (restoring keeps the saved order), not next to the current one.
    @discardableResult
    func addRemoteTab(_ remote: RemoteTab, select selectIt: Bool = true, atEnd: Bool = false, byAgent: Bool = false) -> TerminalTab {
        insert(makeTab(directory: nil, remote: remote, byAgent: byAgent), select: selectIt, atEnd: atEnd)
    }

    private func insert(_ tab: TerminalTab, select selectIt: Bool, atEnd: Bool = false) -> TerminalTab {
        let group = PaneGroup(tab)
        let view = group.view
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        group.layout()
        let insertAt = groups.isEmpty ? 0 : atEnd ? groups.count : activeIndex + 1 // next to the current tab
        groups.insert(group, at: insertAt)
        container.layoutSubtreeIfNeeded() // real size before the shell starts, so it draws once
        tab.start()
        AppDelegate.shared.projectsChanged()
        if selectIt || groups.count == 1 {
            select(insertAt, arming: !tab.view.awaitsChoice)
        } else {
            view.isHidden = true
            if insertAt <= activeIndex { activeIndex += 1 }
            refresh()
        }
        return tab
    }

    /// A tab the restore puts back, with the id it had (SessionRestore). Not in the window until `insertRestored`.
    func restoredTab(directory: String?, remote: RemoteTab?, id: UUID) -> TerminalTab {
        makeTab(directory: directory, remote: remote, id: id)
    }

    /// A tab the restore built, with its panes, laid out at its real size before any shell starts, after the tabs here.
    /// `starting`: the panes whose shells start now; the restore starts the others (on a server) itself. Hidden until
    /// `select` brings it forward.
    func insertRestored(_ group: PaneGroup, starting: [TerminalTab]) {
        let view = group.view
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        groups.append(group)
        window?.contentView?.layoutSubtreeIfNeeded() // the window's real size, set before any tab, reaches the tab
        group.layout()
        container.layoutSubtreeIfNeeded() // each pane's real size before its shell starts, so it draws once
        for tab in starting { tab.start() }
        view.isHidden = groups.count - 1 != activeIndex
    }

    private func makeTab(directory: String?, remote: RemoteTab? = nil, id: UUID = UUID(), byAgent: Bool = false) -> TerminalTab {
        let tab = TerminalTab(directory: directory, fontSize: AppDelegate.shared.terminalFontSize, remote: remote, id: id)
        tab.view.awaitsChoice = byAgent
        tab.delegate = self
        // ⌘-click on "src/a.ts:42" in the output opens the editor there.
        tab.view.openFile = { [weak self] url, line, column in self?.openFile(url, line: line, column: column) }
        return tab
    }

    /// Brings a terminal to the front: its tab selected, its pane focused (and un-zoomed if hidden). `arming` false: an
    /// agent's tab is shown without being chosen for the user (it still waits for their click).
    func show(_ tab: TerminalTab, arming: Bool = true) {
        guard let index = groups.firstIndex(where: { $0.contains(tab) }) else { return }
        let group = groups[index]
        if let zoomed = group.zoomed, zoomed !== tab {
            group.zoomed = nil
            group.layout()
        }
        group.focused = tab
        group.updateDimming()
        select(index, arming: arming)
    }

    /// A pane got the keyboard (a click, or a move between panes).
    private func paneFocused(_ tab: TerminalTab) {
        guard let group = group(of: tab), group.focused !== tab else { return }
        group.focused = tab
        tab.lastSelected = Date()
        group.updateDimming()
        refreshVisibility()
        refresh()
    }

    // MARK: split panes

    @objc func splitRight(_ sender: Any?) { split(vertical: true) }
    @objc func splitDown(_ sender: Any?) { split(vertical: false) }

    /// A new terminal beside `from` (the focused pane): to its right or below it, in its folder.
    @discardableResult
    func split(vertical: Bool, from: TerminalTab? = nil, directory: String? = nil, focus: Bool = true, byAgent: Bool = false) -> TerminalTab? {
        guard let from = from ?? activeTab, let group = group(of: from) else { return nil }
        // Beside a remote tab, another one on its host, in its folder (unless a folder here was asked for).
        let new = directory == nil && from.remote != nil
            ? makeTab(directory: nil, remote: from.remote!.sibling(directory: from.directory), byAgent: byAgent)
            : makeTab(directory: directory ?? from.currentDirectory(), byAgent: byAgent)
        let focused = group.focused
        group.split(from, with: new, vertical: vertical)
        if !focus { group.focused = focused } // the keyboard stays with the pane that has it, beside `from` or not
        group.layout()
        container.layoutSubtreeIfNeeded() // the new pane's real size before its shell starts
        new.start()
        AppDelegate.shared.projectsChanged()
        if focus, group === activeGroup { window?.makeFirstResponder(new.view) }
        refreshVisibility()
        refresh()
        return new
    }

    @objc func selectPaneLeft(_ sender: Any?) { movePaneFocus(.left) }
    @objc func selectPaneRight(_ sender: Any?) { movePaneFocus(.right) }
    @objc func selectPaneAbove(_ sender: Any?) { movePaneFocus(.up) }
    @objc func selectPaneBelow(_ sender: Any?) { movePaneFocus(.down) }

    private func movePaneFocus(_ direction: PaneGroup.Direction) {
        guard let group = activeGroup, let tab = activeTab, let next = group.neighbor(of: tab, direction) else { return NSSound.beep() }
        next.view.awaitsChoice = false // moving to it is choosing it
        window?.makeFirstResponder(next.view)
    }

    @objc func selectNextPane(_ sender: Any?) { cyclePane(by: 1) }
    @objc func selectPreviousPane(_ sender: Any?) { cyclePane(by: -1) }

    private func cyclePane(by delta: Int) {
        guard let group = activeGroup, group.isSplit, let index = group.panes.firstIndex(where: { $0 === group.focused }) else {
            return NSSound.beep()
        }
        let panes = group.panes
        let next = panes[(index + delta + panes.count) % panes.count]
        next.view.awaitsChoice = false // moving to it is choosing it
        if group.zoomed != nil {
            group.zoomed = next
            group.layout()
        }
        window?.makeFirstResponder(next.view)
    }

    /// ⌘⇧↩: the focused pane fills the tab; again, the panes come back.
    @objc func toggleZoomPane(_ sender: Any?) {
        guard let group = activeGroup, group.isSplit else { return NSSound.beep() }
        group.zoomed = group.zoomed == nil ? group.focused : nil
        group.layout()
        container.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(group.focused.view)
        refreshVisibility()
        refresh()
    }

    @objc func equalizePanes(_ sender: Any?) {
        guard let group = activeGroup, group.isSplit else { return NSSound.beep() }
        group.equalize()
        group.layout()
    }

    /// `unfold` false: the tab comes forward without opening a folded terminal (the tab in front closed by
    /// itself), and the keyboard stays where it is. `arming` false: a tab an agent opened comes forward
    /// still waiting for the user to choose it (a neighbour of a closed tab, an agent showing its tab); otherwise
    /// selecting it is choosing it.
    func select(_ index: Int, unfold: Bool = true, arming: Bool = true) {
        guard groups.indices.contains(index) else { return }
        activeIndex = index
        let group = groups[index]
        group.focused.lastSelected = Date()
        if arming { group.focused.view.awaitsChoice = false }
        for (i, other) in groups.enumerated() { other.view.isHidden = i != index }
        if group.focused.view.awaitsChoice {
            // No keyboard for it, and none left with a terminal now hidden: keys go nowhere until a click.
            if window?.firstResponder is NextTermView { window?.makeFirstResponder(nil) }
        } else if unfold || !terminalCollapsed {
            // A terminal taking the keyboard unfolds it (see onFirstResponderChange).
            window?.makeFirstResponder(group.focused.view)
        }
        refreshVisibility()
        refresh()
    }

    func cycleTab(by delta: Int) {
        guard !groups.isEmpty else { return }
        select((activeIndex + delta + groups.count) % groups.count)
    }

    /// Closes a tab, asking first if closing it would stop something: a running program, or a job
    /// left suspended (Ctrl-Z) or in the background. The window's last tab takes the window with it, so
    /// files unsaved in its editor are asked about first, in a sheet that also says what closing stops.
    func requestClose(_ tab: TerminalTab) { requestClose(tab, saveAsked: false) }

    private func requestClose(_ tab: TerminalTab, saveAsked: Bool) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        if !saveAsked, asksToSave(closing: tab) {
            return askToSave(closing: [tab]) { [weak self] in self?.requestClose(tab, saveAsked: true) }
        }
        if let note = tab.keptNote, let window, let remote = tab.remote {
            // A kept tmux tab: closing detaches, and what runs there goes on. Say so, and offer to end it.
            let alert = NSAlert()
            alert.messageText = "Close “\(tab.title)”?"
            alert.informativeText = note
            alert.addButton(withTitle: group(of: tab)?.isSplit == true ? "Close Pane" : "Close Tab")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "End Session")
            alert.beginSheetModal(for: window) { [weak self] response in
                switch response {
                case .alertFirstButtonReturn: self?.remove(tab, saveAsked: saveAsked)
                case .alertThirdButtonReturn: self?.endSession(closing: tab, remote: remote, saveAsked: saveAsked)
                default: break
                }
            }
            return
        }
        // Asked about saving: that sheet said what closing stops.
        guard !saveAsked, let note = tab.closeNote, let window else {
            remove(tab, saveAsked: saveAsked)
            return
        }
        let isPane = group(of: tab)?.isSplit == true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close “\(tab.title)”?"
        alert.informativeText = CloseText.text(lead: "Closing the \(isPane ? "pane" : "tab") stops", notes: [note])
        alert.addButton(withTitle: isPane ? "Close Pane" : "Close Tab")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.remove(tab) }
        }
    }

    /// End Session on a kept tmux tab: the tab closes once the session has ended on the host. That can take
    /// up to 15 s, and the editor is in use meanwhile: a file edited after Save or Don't Save is asked about.
    private func endSession(closing tab: TerminalTab, remote: RemoteTab, saveAsked: Bool) {
        if saveAsked { saveAnswered = (tab, editorArea.dirtyDocuments.map { ($0, $0.text) }) }
        RemoteConnection.endSession(remote.host, session: remote.session) { [weak self] problem in
            guard let self else { return }
            defer { if self.saveAnswered?.tab === tab { self.saveAnswered = nil } }
            guard let problem else { return self.remove(tab) }
            // Not ended: the tab stays, so the session is not left running out of sight.
            guard let window = self.window else { return }
            let failed = NSAlert()
            failed.messageText = "Could not end the session on \(remote.host.name)"
            failed.informativeText = problem
            failed.beginSheetModal(for: window)
        }
    }

    /// Closes a tab without asking (callers have asked, or were told to force it). The exception is the
    /// window's last tab while its editor has unsaved files: the window closes with it, so the user is
    /// asked first, unless `saveAsked` says they were.
    func remove(_ tab: TerminalTab, saveAsked: Bool = false) {
        guard let index = groups.firstIndex(where: { $0.contains(tab) }) else { return }
        // The sheet asking to save is up: it decides whether the window goes (its Save and Don't Save close
        // the tab once it is down), not a close that comes meanwhile (`exit`, End Session, an agent).
        if askingToSave, closesWindow([tab]) { return }
        if !saveAsked, asksToSave(closing: tab) {
            return askToSave(closing: [tab]) { [weak self] in self?.remove(tab, saveAsked: true) }
        }
        // A rename in progress refers to tabs by position: finish it while positions still hold.
        if window?.firstResponder is NSTextView, tabBar.isEditing || tabList.isEditing { window?.makeFirstResponder(nil) }
        let group = groups[index]
        let hadKeyboard = window?.firstResponder === tab.view
        ClosedTabs.remember(tab, in: self) // for Reopen Closed Tab
        tab.terminate()
        if group.remove(tab) {
            // One pane fewer; the tab stays. Its neighbour takes the room and, if this one had it, the keyboard.
            tab.view.removeFromSuperview()
            group.layout()
            if hadKeyboard { window?.makeFirstResponder(group.focused.view) }
            refreshVisibility()
            refresh()
            return
        }
        tab.view.removeFromSuperview()
        group.view.removeFromSuperview()
        groups.remove(at: index)
        if groups.isEmpty {
            // The window goes with its last tab. As after Close Project, the Welcome window follows if no
            // other window is left.
            closeConfirmed = true
            opensWelcome = true
            window?.close()
            return
        }
        if index == activeIndex {
            select(max(0, index - 1), unfold: false, arming: false) // the left neighbour, an agent's still waiting for a click
        } else {
            // A background tab went away: keep the current one, and keep focus where it is.
            if index < activeIndex { activeIndex -= 1 }
            refresh()
        }
    }

    /// Closing `closing` takes the window's last terminal, and so the window.
    private func closesWindow(_ closing: [TerminalTab]) -> Bool {
        groups.count == 1 && groups[0].panes.allSatisfy { pane in closing.contains { $0 === pane } }
    }

    /// Closing `tab` would close the window while files in its editor are unsaved: the user is asked first
    /// (or is being asked now).
    func asksToSave(closing tab: TerminalTab) -> Bool {
        guard closesWindow([tab]) else { return false }
        if askingToSave { return true }
        let dirty = editorArea.dirtyDocuments
        guard !dirty.isEmpty else { return false }
        // Answered before End Session: asked again only about a file edited since.
        guard let answered = saveAnswered, answered.tab === tab else { return true }
        return !dirty.allSatisfy { doc in answered.edits.contains { $0.0 === doc && $0.1 == doc.text } }
    }

    /// The window's last tab is closing, and the window with it, while files in its editor are unsaved:
    /// Save, Don't Save or Cancel, as closing the window asks, and what closing stops is said too. `close`
    /// runs on Save or Don't Save. Cancel keeps the window and a shell in it: a fresh one in place of a
    /// tab whose shell ended by itself (`exit`, Ctrl-D). One that failed stays as it was, with its reason.
    private func askToSave(closing: [TerminalTab], kept: String = "", then close: @escaping () -> Void) {
        guard let window, !askingToSave else { return }
        let busy = closing.filter { $0.closeNote != nil }
        var note = "Closing the window’s last tab closes the window."
        if closing.allSatisfy(\.exited) {
            note = "The shell in the window’s last tab has ended, so the window closes."
        } else if !busy.isEmpty {
            note = Self.stopText("Closing the window’s last tab closes the window and stops", busy, otherwise: note)
        }
        let alert = saveAlert(editorArea.dirtyDocuments, note: note)
        if !kept.isEmpty { alert.informativeText += "\n\n" + kept }
        askingToSave = true
        // Asked from elsewhere (an agent's close_tab, a shell ending in a window behind): the window comes
        // forward so the question is seen, without taking the keyboard from the window in use.
        if window.isMiniaturized { window.deminiaturize(nil) } else if !window.isKeyWindow { window.orderFront(nil) }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.askingToSave = false
            // The window went meanwhile (Quit): nothing is left to decide.
            guard closing.contains(where: { tab in self.tabs.contains { $0 === tab } }) else { return }
            let saved = response == .alertFirstButtonReturn && self.editorArea.saveAll()
            if saved || response == .alertThirdButtonReturn { return close() }
            // Cancel, or a file that could not be saved.
            guard let last = closing.first, closing.allSatisfy(\.endedByItself) else { return }
            self.addTab(directory: self.project ?? (last.remote == nil ? last.directory : nil))
            for tab in closing { self.remove(tab) }
        }
    }

    /// "Save changes to “a.php” before closing?" with Save, Cancel and Don't Save: what every close that
    /// would lose edits asks. `note` comes first: what else the close does.
    private func saveAlert(_ dirty: [EditorDocument], note: String = "") -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = dirty.count == 1 ? "Save changes to “\(dirty[0].name)” before closing?"
            : "Save changes to \(dirty.count) files before closing?"
        let lost = dirty.count == 1 ? "Your changes are lost if you don’t save them."
            : "Your changes to \(Self.nameList(dirty.map(\.name))) are lost if you don’t save them."
        alert.informativeText = note.isEmpty ? lost : note + " " + lost
        alert.addButton(withTitle: dirty.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save").keyEquivalent = "d"
        return alert
    }

    /// "“a.php”, “b.ts” and “c.css”", or "“a.php”, “b.ts”, “c.css” and 2 more".
    static func nameList(_ names: [String]) -> String {
        let quoted = names.prefix(3).map { "“\($0)”" }
        let rest = names.count - quoted.count
        if rest > 0 { return quoted.joined(separator: ", ") + " and \(rest) more" }
        guard let last = quoted.last, quoted.count > 1 else { return quoted.first ?? "" }
        return quoted.dropLast().joined(separator: ", ") + " and " + last
    }

    /// Tabs whose closing would stop a program or a job, or leave one running that the user may expect to stop.
    var busyTabs: [TerminalTab] { tabs.filter { $0.closeNote != nil } }

    /// What keeps running on servers after `tabs` close (kept tmux tabs with a program in front), for the
    /// close alerts: "“claude” on web-1 (tmux session nt-app-1a2b3c)". Empty: nothing.
    static func keptList(_ tabs: [TerminalTab]) -> String {
        let kept = tabs.compactMap { tab -> String? in
            guard tab.keptNote != nil, let remote = tab.remote else { return nil }
            return "“\(tab.status.program)” on \(remote.host.name) (tmux session \(remote.session))"
        }
        guard !kept.isEmpty else { return "" }
        return "Still running after closing, on the host: " + kept.joined(separator: "; ") + ". Reopen from File › New Remote Tab…"
    }

    /// "<lead> “vim notes.md” (suspended); “claude” (running), “next-server” (started by “claude”); and more in 2
    /// other tabs." then what keeps running ("“python3 serve.py” keeps running: it ignores hangups."). The same text
    /// for every alert that stops tabs, from the plans their hangup follows. `otherwise`: the first sentence when
    /// nothing stops.
    static func stopText(_ lead: String, _ busy: [TerminalTab], otherwise: String = "") -> String {
        CloseText.text(lead: lead, notes: busy.compactMap(\.closeNote), otherwise: otherwise)
    }
    var unseenTabCount: Int { tabs.filter { $0.status.unseen != nil }.count }

    // MARK: status

    /// The user can see the active tab only while this window is in front in the active app: key, or main
    /// while its own panel or sheet has the keyboard (⌘P, Find in Files, an alert). Panels and sheets never
    /// become main; another window (Settings) does, and then this one is not in front.
    private var userCanSeeWindow: Bool {
        guard let window, NSApp.isActive, !window.isMiniaturized else { return false }
        return window.isKeyWindow || window.isMainWindow
    }

    func refreshVisibility() {
        for group in groups {
            for tab in group.panes {
                let isVisible = isOnScreen(tab)
                tab.status.setVisible(isVisible)
                tab.view.beepAllowed = isVisible && tab === group.focused
            }
        }
    }

    /// Whether you are looking at `tab`: a pane of the selected tab (every pane, unless another fills the
    /// tab), in the window in front (userCanSeeWindow) of the active app. Folded, to its rail or to its bar above
    /// or below the editor, no terminal is on screen, so what happens in the tab in front is news too. Its status
    /// and its notifications both go by this.
    func isOnScreen(_ tab: TerminalTab) -> Bool {
        guard userCanSeeWindow, !terminalCollapsed, let group = activeGroup, group.panes.contains(where: { $0 === tab }) else { return false }
        return group.zoomed == nil || group.zoomed === tab
    }

    /// What a notification says the tab is in: the window's project, else the tab's folder.
    func placeName(of tab: TerminalTab) -> String {
        if project != nil { return projectTitle }
        if tab.directory == FileManager.default.homeDirectoryForCurrentUser.path { return "~" }
        let last = (tab.directory as NSString).lastPathComponent
        return last.isEmpty ? tab.directory : last
    }

    private func tick() {
        tickCount += 1
        let now = TerminalTab.now
        refreshVisibility()
        for (index, tab) in tabs.enumerated() {
            tab.view.drawIfSeenAgain()
            if tickCount % 2 == 0 { tab.pollForeground(); tab.pollServing() } // every 0.5 s
            // The agent in sight every 0.25 s; the others every 0.5 s, half of them on each tick.
            if isOnScreen(tab) || (tickCount + index) % 2 == 0 { tab.pollAgentScreen() }
            tab.status.tick(at: now)
            if let notice = tab.status.takeNotice() {
                AppDelegate.shared.post(notice, tab: tab, in: self)
            }
        }
        if tickCount % 4 == 0 { editorArea.checkDisk() } // agents edit the files you have open
        // A window no one can see refreshes once a second (its tabs' marks still reach the Dock badge and the
        // notifications), and at once when it shows again (visibilityChanged).
        if window?.canBeSeen != false || tickCount % 4 == 0 { refresh() }
    }

    @objc private func visibilityChanged() {
        guard window?.canBeSeen == true else { return }
        refresh()
    }

    func refresh() {
        let shortcuts = Self.tabShortcuts(count: groups.count)
        let items = groups.enumerated().map { index, group -> TabBarItem in
            let tab = group.focused
            guard group.isSplit else {
                return TabBarItem(title: AgentSpinner.shown(tab.title), truncation: tab.titleTruncation, state: tab.status.state, tooltip: tab.tooltip,
                                  accessibilityStatus: tab.ownStateDescription ?? "", shortcut: shortcuts[index], remote: tab.remoteMark,
                                  shorterTitles: tab.shorterTitles.map(AgentSpinner.shown), editableTitle: tab.editableTitle)
            }
            // A split tab: named by the pane with the keyboard, marked by the pane that most needs you.
            let lines = group.panes.map(\.paneSummary)
            // VoiceOver reads the title first: the keyboard pane's line goes when it is only that title
            // ("web-1: app (connecting)"), or the connection would be said three times.
            let spoken = group.panes.filter { $0 !== tab || $0.paneSummary != $0.title }.map(\.paneSummary)
            let mark = group.remoteMark
            let others = "  +\(group.panes.count - 1)"
            return TabBarItem(title: AgentSpinner.shown(tab.title) + others, truncation: tab.titleTruncation,
                              state: Self.mostUrgent(group.panes.map(\.status.state)),
                              tooltip: ([mark?.summary].compactMap { $0 } + lines).joined(separator: "\n"),
                              accessibilityStatus: spoken.joined(separator: "; "), shortcut: shortcuts[index], remote: mark,
                              shorterTitles: tab.shorterTitles.map { AgentSpinner.shown($0) + others }, editableTitle: tab.editableTitle)
        }
        feedTabStrips(placeMarked(items))
        // An agent started or stopped, or another one is the one Send to Agent types into: the Ask hints follow.
        let asked = agentTab.map { "\(ObjectIdentifier($0).hashValue) \(Self.agentName(of: $0)) \($0.title)" }
        if asked != askedAgent {
            askedAgent = asked
            updateAskHints()
        }
        refreshPaneHeaders()
        sidebar.showRemote(activeTab?.remoteMark) // the pane with the keyboard: the tree follows it
        updateRailMarks(items)
        announceBackgroundChanges()
        updateTitle()
        AppDelegate.shared.indexed(self) // its marks across windows: Go to Next Agent Needing You, ⌘O, the Dock menu
        AppDelegate.shared.updateBadge()
        updateProjectRoot()
        updateTabPlace()
        noteAgentTabs()
        offerProjectForHomeAgent()
    }

    /// An agent Next Term recognises runs here, in a window with no project, in the home folder: once in this window, a
    /// notice offers to open a project for it (Choose Folder…, as Open… does), with Don’t Ask Again for every window
    /// (HomeAgentOffer). The agent is never held: the notice only offers.
    private func offerProjectForHomeAgent() {
        guard project == nil, !offeredProjectForAgent else { return }
        let agents: [TerminalTab] = tabs.filter { (tab: TerminalTab) -> Bool in tab.status.running && tab.status.kind == .agent }
        guard !agents.isEmpty else { return }
        let home: String = ProtectedPlaces.current.home
        let rows: [HomeAgentOffer.Tab] = agents.map { (tab: TerminalTab) -> HomeAgentOffer.Tab in
            // The agent's own folder: `cd ~/app && claude` runs in app, though the tab's folder is still the prompt's
            // until the next precmd. While the shell is still in front, no folder yet: a later tick asks again.
            let pgid: pid_t = tcgetpgrp(tab.view.process.childfd)
            let leads: Bool = pgid > 0 && pgid != tab.view.process.shellPid
            let folder: String = leads ? (ProcessInspector.currentDirectory(of: pgid) ?? "") : ""
            let local: String = folder.isEmpty ? "" : canonicalPath(folder)
            return HomeAgentOffer.Tab(directory: tab.remote != nil ? tab.directory : local, runsAgent: true, remote: tab.remote != nil)
        }
        let on: Bool = HomeAgentOffer.isOn(.standard)
        guard HomeAgentOffer.offers(on: on, windowProject: project, offered: false, tabs: rows, home: home) else { return }
        offeredProjectForAgent = true
        let tab: TerminalTab? = zip(agents, rows).first { $0.1.directory == home && !$0.1.remote }?.0
        let text: String = HomeAgentOffer.text(agent: tab.map(Self.agentName(of:)) ?? "An agent")
        // The panel comes over this window, not the key one: the notice can't be key, so a click on it leaves another
        // window key, or none. Weak, as the notice keeps its action while it shows.
        let choose: () -> Void = { [weak self] in AppDelegate.shared.chooseProjectFolder(from: self) }
        GitToast.show(text, in: window, button: "Choose Folder…", action: choose,
                      other: "Don’t Ask Again", otherAction: { HomeAgentOffer.turnOff(.standard) })
    }

    /// Needs you, then working, failed, done, idle. With Agent Spinner off a working pane shows no mark, so it never
    /// hides another pane's cross or check: it comes after them.
    static func mostUrgent(_ states: [TabState], workingShown: Bool = AgentSpinner.current != .off) -> TabState {
        let order: [TabState] = workingShown ? [.attention, .working, .failed, .done, .idle] : [.attention, .failed, .done, .working, .idle]
        return order.first { states.contains($0) } ?? .idle
    }

    /// "xCloud ▸ 7027-sso — claude" in the terminal, "xCloud — Alertable.php" while editing, "xCloud — claude — on
    /// web-1" in a remote tab (or "xCloud — web-1: app" when the tab's name says it already); with no project
    /// "~/Downloads — vim", or "web-1 — app" with a server's tab in front. The window's name comes first, so the Window
    /// menu, Mission Control and VoiceOver lead with the project (WindowTitle).
    func updateTitle() {
        window?.title = windowTitle
    }

    var windowTitle: String {
        let tab: TerminalTab? = isEditorFocused ? nil : activeTab
        // An agent's spinner frame left out: the title holds still while it works.
        let shown: String? = tab.map { (tab: TerminalTab) -> String in AgentTitle.withoutSpinnerFrame(tab.title) }
        let front: String? = isEditorFocused ? editorArea.activeName : shown
        return WindowTitle.make(name: windowName, front: front, folderName: folderName, host: tab?.remote?.host.name)
    }

    /// What the window is for, which names it: a project, a linked worktree, or no project, its tab in front on this
    /// Mac or on a server.
    var windowKind: WindowKind {
        if project != nil { return isWorktree ? .worktree : .project }
        return activeTab?.remote != nil ? .server : .plain
    }

    /// The name its title starts with: its project's title ("xCloud ▸ 7027-sso"); with no project, its tab in front's
    /// server ("web-1") or folder ("~/Downloads", "~").
    var windowName: String {
        if project != nil { return projectTitle }
        guard let tab = activeTab else { return "Next Term" }
        if let remote = tab.remote { return remote.host.name }
        let home: String = FileManager.default.homeDirectoryForCurrentUser.path
        return WindowTitle.name(ofFolder: tab.directory, home: home)
    }

    /// The title a tab at its prompt in the window's own folder has (TerminalTab.title): its project's folder name, or
    /// with no project its tab's ("~" at home). The name says it already, so the title leaves it out. None on a server.
    private var folderName: String? {
        if let project { return (project as NSString).lastPathComponent }
        guard let tab = activeTab, tab.remote == nil else { return nil }
        if tab.directory == FileManager.default.homeDirectoryForCurrentUser.path { return "~" }
        let last: String = (tab.directory as NSString).lastPathComponent
        return last.isEmpty ? tab.directory : last
    }

    /// What the index of every window holds for this one (AppDelegate.windowIndex): its name and title, and its
    /// terminals' marks, tab by tab and pane by pane, as its tab bar shows them, read from their own status.
    var indexEntry: WindowIndex.Window {
        let terminals: [WindowIndex.Tab] = tabs.map { (tab: TerminalTab) -> WindowIndex.Tab in
            let title: String = AgentTitle.withoutSpinnerFrame(tab.title)
            // A lost connection cleared the tab's status: what an agent asked there may still wait on the host.
            let lost: Bool = tab.remoteLink == .disconnected
            return WindowIndex.Tab(id: tab.id, title: title, state: tab.status.state, disconnected: lost)
        }
        let destination: String? = project == nil ? activeTab?.remote?.host.destination : nil
        return WindowIndex.Window(id: indexID, kind: windowKind, project: project, name: windowName, title: windowTitle,
                                  lastKey: lastKey, tabs: terminals, destination: destination, repository: repositoryCheckout)
    }

    /// Tells VoiceOver users when a background tab finishes, fails or asks for attention: the dots are
    /// visual, so without this they would never know.
    private func announceBackgroundChanges() {
        for (i, tab) in groups.enumerated().flatMap({ index, group in group.panes.map { (index, $0) } }) {
            let state = tab.status.state
            defer { announcedStates[tab.id] = state }
            guard i != activeIndex || terminalCollapsed, announcedStates[tab.id] != state, [.done, .failed, .attention].contains(state) else { continue }
            NSAccessibility.post(element: window as Any, notification: .announcementRequested, userInfo: [
                .announcement: "\(tab.title): \(tab.stateDescription)",
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
        let live = Set(tabs.map(\.id))
        announcedStates = announcedStates.filter { live.contains($0.key) }
    }

    // MARK: project sidebar

    var isSidebarVisible: Bool { !sidebar.isHidden }

    /// A project window's tree stays on its project. Otherwise it follows the active tab into the project it is in (its
    /// git work tree, or its folder when outside one), offering Open as Project Window; in a folder that is never a
    /// project (the home folder, /: ProjectRoot.project) it shows "No project open", and nothing there is read.
    private func updateProjectRoot() {
        guard isSidebarVisible else { return }
        if let project {
            guard projectKey != project else { return }
            projectKey = project
            sidebar.offerProjectWindow(nil)
            // A folder that is never a project (the home folder opened as one): its files, and nothing scanned there.
            sidebar.setRoot(project, browsing: ProjectRoot.isNeverRoot(project))
            return
        }
        // A remote tab's folder is on its host, not this Mac: the tree stays where it was.
        guard let tab = activeTab, tab.remote == nil else { return }
        let key = tab.id.uuidString + "\u{0}" + tab.directory
        guard key != projectKey else { return }
        projectKey = key
        if let root = ProjectRoot.project(from: tab.directory) {
            sidebar.setRoot(root)
            sidebar.offerProjectWindow(sidebar.root?.path ?? root)
        } else if browsesHome {
            sidebar.offerProjectWindow(nil)
            sidebar.setRoot(ProtectedPlaces.current.home, browsing: true)
        } else {
            sidebar.showNoProject(recent: AppDelegate.shared.recentProjects)
        }
        AppDelegate.shared.projectsChanged()
    }

    /// Browse Home Folder: the home folder's tree in this window, while its tab is in no project. Never a project: no git,
    /// Databases, Services or Agent Sessions there, and each folder in it, Desktop and Documents too, read only as the user
    /// opens it (when macOS asks for those, it is because the user did).
    func browseHomeFolder() {
        browsesHome = true
        projectKey = nil
        // With a remote tab in front the tree stays as it was (updateProjectRoot), but this click asks for it to change.
        // The next local tab is placed afresh: in the home folder it keeps this tree, in a project it shows that one.
        if activeTab?.remote != nil {
            sidebar.offerProjectWindow(nil)
            sidebar.setRoot(ProtectedPlaces.current.home, browsing: true)
            return
        }
        updateProjectRoot()
    }

    // MARK: find and replace in files

    /// The folder searches cover: the project, else what the sidebar shows, else the project the tab is in, else its
    /// folder (the home folder, whose protected places the searches leave out: ProtectedPlaces).
    var searchRoot: String {
        if let root = project ?? sidebar.root?.path { return root }
        guard let tab = activeTab, tab.remote == nil else { return NSHomeDirectory() }
        return ProjectRoot.project(from: tab.directory) ?? tab.directory
    }

    @objc func findInFiles(_ sender: Any?) {
        finder.show(root: searchRoot, replacing: false, initialText: searchSeed, current: currentFileForSearch, over: window)
    }

    @objc func replaceInFiles(_ sender: Any?) {
        finder.show(root: searchRoot, replacing: true, initialText: searchSeed, current: currentFileForSearch, over: window)
    }

    /// What ⌘⇧F starts with: the selection in the editor (or the word at the caret), or the terminal's.
    var searchSeed: String? {
        var seed: String?
        if isEditorFocused, let view = editorArea.activeTextView {
            let text = view.string as NSString
            var range = view.selectedRange()
            if range.length == 0, text.length > 0 {
                range = view.selectionRange(forProposedRange: NSRange(location: min(range.location, text.length), length: 0), granularity: .selectByWord)
            }
            if range.length > 0, NSMaxRange(range) <= text.length { seed = text.substring(with: range) }
        } else if let selection = activeTab?.view.getSelection() {
            seed = selection
        }
        guard let trimmed = seed?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty, !trimmed.contains("\n"),
              trimmed.count <= 200, trimmed.rangeOfCharacter(from: .alphanumerics) != nil else { return nil }
        return trimmed
    }

    /// The edited file, relative to the search root, so its type is listed first.
    private var currentFileForSearch: String? {
        guard let path = editorArea.activePath else { return nil }
        let root = canonicalPath(searchRoot)
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
    }

    func findInFiles(_ controller: FindInFilesController, open url: URL, line: Int) {
        openFile(url, line: line)
    }

    // MARK: projects

    /// A window nobody has used yet: no project, one tab, nothing run in it, and nothing restored into it.
    var isPristine: Bool {
        // A remote tab is never unused: commands there are seen only now and then, and its session matters.
        guard project == nil, groups.count == 1, tabs.count == 1, let tab = tabs.first, tab.remote == nil else { return false }
        return tab.isUntouched && tab.closeNote == nil
    }

    /// A tab here holds what the restore brought back, and the user has not put anything in it yet: Open Project never
    /// takes this window over or replaces its tabs, but opens a window of its own (ProjectOpening.placement).
    var holdsRestore: Bool { tabs.contains(where: \.holdsRestore) }

    /// Turns this window into `path`'s project: a fresh tab in the project, the old tabs closed.
    /// Callers confirm first if the old tabs are busy.
    func adoptProject(_ path: String) {
        let old = tabs
        project = canonicalPath(path)
        projectKey = nil
        loadTabListWidth() // as the project last had it
        addTab(directory: project)
        for tab in old { remove(tab) }
        refresh()
    }

    /// Close Project: closes the window (asking first if something is running in it).
    @objc func closeProject(_ sender: Any?) {
        guard project != nil, let window else { return NSSound.beep() }
        opensWelcome = true
        window.performClose(nil)
        if window.isVisible && window.attachedSheet == nil { opensWelcome = false } // close was refused
    }

    // MARK: project colour

    /// The project's colour on the top row: as kept, or on the project's first open the colour the other project windows
    /// use least, kept from then on. When the window takes its project and when a colour or Show Project Colors changes;
    /// never in `refresh`.
    private func takeProjectColor() {
        projectColorEntry = projectColorKey.flatMap { (key: String) -> ProjectColors.Entry? in
            ProjectColorStore.entry(for: key, inUse: colorsInUse(besides: key), open: openColorKeys)
        }
        paintProjectColor()
    }

    /// The other project windows' colours, one for each window, leaving out `key`'s own (a worktree window of this
    /// repository): what a pick for `key` should not take while another is free.
    private func colorsInUse(besides key: String) -> [ProjectColor] {
        let others: [TerminalWindowController] = AppDelegate.shared.controllers.filter { (other: TerminalWindowController) -> Bool in
            other !== self && !other.hasClosed && other.projectColorKey != key
        }
        return others.compactMap(\.projectColor)
    }

    private var openColorKeys: Set<String> {
        Set(AppDelegate.shared.controllers.compactMap(\.projectColorKey) + [projectColorKey].compactMap { $0 })
    }

    /// The bars of the top row, each with its slice of the glow.
    private var projectGlows: [ProjectGlow] {
        [sidebar.header.projectGlow, tabBar.projectGlow, editorArea.tabBar.projectGlow, terminalRail.projectGlow, windowColumn.projectGlow]
    }

    private func paintProjectColor() {
        let peak: NSColor? = ProjectColorStore.isShown ? projectColor?.glowColor : nil
        let dimmed: Bool = !isActiveWindow
        for glow in projectGlows {
            glow.peak = peak
            glow.dimmed = dimmed
        }
    }

    /// The window in use: in front of the active app, its traffic lights in colour. The others' glow is dimmed.
    private var isActiveWindow: Bool {
        guard let window, NSApp.isActive else { return false }
        return window.isMainWindow || window.isKeyWindow
    }

    /// The window came into use or went out of it, or the app did.
    func activityChanged() {
        let dimmed: Bool = !isActiveWindow
        for glow in projectGlows { glow.dimmed = dimmed }
    }

    /// A pane moved, showed or hid (HairlineSplitView.onPanesPlaced): each bar of the top row draws its slice again if it
    /// moved within the glow's reach.
    private func projectGlowMoved() {
        for glow in projectGlows { glow.moved() }
    }

    /// This window's project's colour, or another's that its repository's worktree windows share, or Show Project Colors.
    @objc private func projectColorsChanged() { takeProjectColor() }

    /// View › Project Color: a colour for this window's project, which its repository's worktree windows share,
    /// Automatic, or None for This Project.
    @objc func setProjectColor(_ sender: NSMenuItem) {
        guard let key = projectColorKey, let id = sender.representedObject as? String else { return NSSound.beep() }
        switch id {
        case ProjectColorMenu.automaticID:
            ProjectColorStore.automatic(for: key, inUse: colorsInUse(besides: key), open: openColorKeys)
        case ProjectColorMenu.noneID:
            ProjectColorStore.choose(nil, for: key, open: openColorKeys)
        default:
            guard let color = ProjectColor(id: id) else { return }
            ProjectColorStore.choose(color, for: key, open: openColorKeys)
        }
    }

    /// The window's colour checked, and Automatic while it is the one picked for it; nothing to choose without a project
    /// or while Show Project Colors is off.
    private func validateProjectColor(_ item: NSMenuItem) -> Bool {
        let id: String? = item.representedObject as? String
        let entry: ProjectColors.Entry? = projectColorEntry
        let on: Bool
        if id == ProjectColorMenu.automaticID {
            on = entry?.chosen == false
        } else if id == ProjectColorMenu.noneID {
            on = entry != nil && entry?.color == nil
        } else {
            on = entry?.color != nil && entry?.color?.id == id
        }
        item.state = on ? .on : .off
        return projectColorKey != nil && ProjectColorStore.isShown
    }

    /// The top row's right-click; none in a window with no project, which has no colour.
    func projectColorMenu() -> NSMenu? {
        projectColorKey == nil ? nil : ProjectColorMenu.contextMenu(for: self)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let valid = validateTabCommand(item) { return valid } // TabMenus.swift
        let gitActions: [Selector] = [#selector(showBranches(_:)), #selector(showWorktrees(_:)), #selector(gitFetch(_:)), #selector(gitUpdate(_:)), #selector(gitCommit(_:)),
                                      #selector(gitPush(_:)), #selector(gitNewBranch(_:))]
        // Off while a sheet is over the window (the commit sheet, a question one of them asked). Before the sheet is up, a
        // second press of the same command does nothing (gitAsking).
        if let action = item.action, gitActions.contains(action) { return gitFolder != nil && window?.attachedSheet == nil }
        if item.action == #selector(showGitLog(_:)) { return gitLogRoot != nil }
        if item.action == #selector(showGitDiff(_:)) { return gitDiffRoot != nil }
        if item.action == #selector(closeProject(_:)) { return project != nil }
        if item.action == #selector(setProjectColor(_:)) { return validateProjectColor(item) }
        if item.action == #selector(openServedURL(_:)) { return activeTab?.servedURL != nil }
        if item.action == #selector(saveDocument(_:)) { return editorArea.activeEditor != nil }
        if item.action == #selector(saveAllDocuments(_:)) { return !editorArea.dirtyDocuments.isEmpty }
        if item.action == #selector(goToLine(_:)) { return editorArea.activeEditor != nil }
        if item.action == #selector(goToHeading(_:)) { return editorArea.activeEditor?.markdown != nil }
        if item.action == #selector(gitRollback(_:)) { return gitFolder != nil && window?.attachedSheet == nil && !rollbackTargets.isEmpty }
        if item.action == #selector(showChanges(_:)) {
            return editorArea.activePath != nil || sidebar.selection.contains { !$0.isFolder } || sidebar.selectedDeleted.contains { !$0.isDirectory }
        }
        // On when the keyboard is where ⌥⌘K sends from, with something to send, even with no agent running:
        // sending then says that none is.
        if item.action == #selector(sendToAgent(_:)) {
            let page = editorArea.activeGitDiff?.allFiles
            let sendable = (editorArea.activePath != nil && editorArea.activeDiff?.proposal == nil) || (page?.isHidden == false && page?.diffShare() != nil)
            let fromSidebar = window?.firstResponder === sidebar.outline && !sidebar.selection.isEmpty
            return (isEditorFocused && sendable) || fromSidebar || terminalSelectionToSend != nil
        }
        if item.action == #selector(toggleEditorFocus(_:)) {
            item.title = isEditorFocused ? "Focus Terminal" : "Focus Editor"
            return editorArea.activeTextView != nil
        }
        if item.action == #selector(closeTab(_:)) {
            let closesFile = isEditorFocused || isSidebarFocused
            item.title = !closesFile && activeGroup?.isSplit == true ? "Close Pane" : "Close Tab"
            if isSidebarFocused { return !editorArea.isHidden && !editorArea.isEmpty }
            return isEditorFocused || !terminalRailed
        }
        let paneActions: [Selector] = [#selector(selectPaneLeft(_:)), #selector(selectPaneRight(_:)), #selector(selectPaneAbove(_:)),
                                       #selector(selectPaneBelow(_:)), #selector(selectNextPane(_:)), #selector(selectPreviousPane(_:)),
                                       #selector(toggleZoomPane(_:)), #selector(equalizePanes(_:))]
        if let action = item.action, paneActions.contains(action) {
            if action == #selector(toggleZoomPane(_:)) { item.state = activeGroup?.zoomed != nil ? .on : .off }
            return activeGroup?.isSplit == true
        }
        if item.action == #selector(splitRight(_:)) || item.action == #selector(splitDown(_:)) { return activeTab != nil }
        // With VS Code's or JetBrains' keys, ⌘K clears only the terminal: in their editors ⌘K means other things.
        if item.action == #selector(clearBuffer(_:)) {
            return !(KeyboardShortcuts.shared.preset.clearsOnlyInTerminal && isEditorFocused)
        }
        if item.action == #selector(revealInSidebar(_:)) { return editorArea.activePath != nil }
        if item.action == #selector(forgetSuggestion(_:)) { return activeTab?.ghost.isShowing == true }
        if item.action == #selector(toggleEnvValues(_:)) {
            item.state = editorArea.activeEditor?.hidesEnvValues == true ? .on : .off
            return editorArea.activeEditor?.isEnvFile == true
        }
        if item.action == #selector(toggleMarkdownPreview(_:)) {
            let editor = editorArea.activeEditor
            item.title = editor?.markdownTooLarge == true ? "Markdown Live Preview (file too large)" : "Markdown Live Preview"
            item.state = editor?.showsLivePreview == true ? .on : .off
            return editor?.preview != nil
        }
        if item.action == #selector(toggleTerminalCollapsed(_:)) {
            item.title = terminalCollapsed ? "Expand Terminal" : "Collapse Terminal"
            return !editorArea.isHidden
        }
        if item.action == #selector(toggleTabListCollapsed(_:)) { return validateTabListCollapse(item) }
        if item.action == #selector(toggleProjectSidebar(_:)) {
            item.title = isSidebarVisible ? "Hide Project Sidebar" : "Show Project Sidebar"
        }
        return true
    }

    // MARK: layout: where the sidebar and the terminal go

    private var sidebarOnRight: Bool { AppDelegate.shared.sidebarSide == .right }
    private var terminalPosition: AppDelegate.TerminalPosition { AppDelegate.shared.terminalPosition }
    /// The terminal comes before the editor (left of it, or above it).
    private var terminalFirst: Bool { terminalPosition.terminalFirst }
    /// The terminal position the work area was last laid out for (nil: not yet).
    private var workPosition: AppDelegate.TerminalPosition?

    /// Puts the sidebar and the terminal where the View menu says, keeping their sizes. Only a new terminal
    /// position lays the work area out again: the sidebar on its other side, or the same position chosen
    /// again, leaves a folded terminal folded and the divider between editor and terminal where it is.
    func applyLayout() {
        let sidebarWidth = AppDelegate.shared.sidebarWidth
        let order: [NSView] = sidebarOnRight ? [mainPane, sidebar] : [sidebar, mainPane]
        if splitView.arrangedSubviews != order {
            order.forEach(splitView.removeArrangedSubview)
            order.forEach(splitView.addArrangedSubview)
        }
        // Window resizes go to the work area, not the sidebar.
        splitView.setHoldingPriority(.init(260), forSubviewAt: sidebarOnRight ? 1 : 0)
        splitView.setHoldingPriority(.init(250), forSubviewAt: sidebarOnRight ? 0 : 1)

        let position = terminalPosition
        let relaysWork = position.relaysWork(from: workPosition)
        workPosition = position
        if relaysWork {
            workSplit.isVertical = position.sideBySide
            let work: [NSView] = terminalFirst ? [terminalPane, editorArea] : [editorArea, terminalPane]
            if workSplit.arrangedSubviews != work {
                work.forEach(workSplit.removeArrangedSubview)
                work.forEach(workSplit.addArrangedSubview)
            }
            // Window resizes go to the editor; the terminal keeps its size.
            workSplit.setHoldingPriority(.init(250), forSubviewAt: terminalFirst ? 1 : 0)
            workSplit.setHoldingPriority(.init(260), forSubviewAt: terminalFirst ? 0 : 1)
        }
        splitView.adjustSubviews()
        if relaysWork { workSplit.adjustSubviews() }
        if isSidebarVisible { placeSidebarDivider(width: sidebarWidth) }
        if relaysWork {
            terminalCollapsed = false // a new position starts unfolded
            placeWorkDivider()
        }
        applyTerminalTabs()
        updateCollapseButton()
        // The window column follows the sidebar's side: the far right with it, the order mirrored.
        columnHost.columnOnRight = sidebarOnRight
        placeWindowColumn()
        updateInsets()
    }

    /// The sidebar at `width`, wherever it is.
    func placeSidebar(width: CGFloat) { placeSidebarDivider(width: width) }

    private func placeSidebarDivider(width: CGFloat) {
        columnHost.layoutSubtreeIfNeeded() // the split view's frame comes from its host's constraints
        let position = sidebarOnRight ? splitView.bounds.width - width - splitView.dividerThickness : width
        splitView.setPosition(position, ofDividerAt: 0)
    }

    /// The editor gets its remembered share of the work area, on whichever side it is: the share kept for the
    /// terminal beside it, or above or below it. Never so much or so little that either pane goes under its
    /// minimum, as dragging the divider never does.
    private func placeWorkDivider() {
        guard !editorArea.isHidden else { return }
        workSplit.layoutSubtreeIfNeeded()
        let length = workSplit.isVertical ? workSplit.bounds.width : workSplit.bounds.height
        let thickness = workSplit.dividerThickness
        let share = AppDelegate.shared.editorFraction(sideBySide: workSplit.isVertical)
        let editor = EditorShare.editorLength(share: share, of: length, thickness: thickness,
                                              editorMinimum: workMinimum, terminalMinimum: terminalMinimum)
        workSplit.setPosition(terminalFirst ? length - editor - thickness : editor, ofDividerAt: 0)
    }

    func setSidebarVisible(_ visible: Bool) {
        sidebar.isHidden = !visible
        if visible {
            splitView.adjustSubviews()
            placeSidebarDivider(width: AppDelegate.shared.sidebarWidth)
            projectKey = nil
            updateProjectRoot()
            // Files opened while it was hidden were not revealed: the one in front is now.
            if let path = editorArea.activePath { sidebar.reveal(path) }
        } else {
            splitView.adjustSubviews()
        }
        // The column stays where it is; only the room it is measured by changed.
        columnHost.place()
        updateInsets()
    }

    // Not toggleSidebar:: NSWindow responds to it and would swallow it.
    @objc func toggleProjectSidebar(_ sender: Any?) {
        let visible = !isSidebarVisible
        AppDelegate.shared.sidebarVisible = visible
        setSidebarVisible(visible)
    }

    /// The traffic lights sit over whichever pane is top-left; full screen has none. Tab bars along the
    /// top of the window drag it, like a title bar, and have the project's glow; one lower down has neither.
    /// The window column on the left takes its width off their room in the pane after it.
    func updateInsets() {
        let column: CGFloat = windowColumnUnderLights
        let lights: CGFloat = isFullScreen ? 8 : max(8, 78 - column)
        let sidebarTopLeft = isSidebarVisible && !sidebarOnRight
        sidebar.headerInset = sidebarTopLeft && !isFullScreen ? max(8, 70 - column) : 8
        updateWindowColumnInsets()
        let corner = sidebarTopLeft ? 8 : lights
        let editorShown = !editorArea.isHidden
        // Folded to its rail on the left, the terminal has no bar: the editor's, just after the rail, has the corner.
        let railedLeft = terminalRailed && terminalFirst
        // Which bar starts at the work area's top-left corner, and which bars run along its top edge.
        let terminalAtCorner = !editorShown || (terminalFirst && !railedLeft)
        let terminalAtTop = !editorShown || terminalPosition != .bottom
        let editorAtTop = terminalPosition != .top
        tabBar.leadingInset = terminalAtCorner ? corner : 8
        tabBar.dragsWindow = terminalAtTop
        tabBar.projectGlow.onTopRow = terminalAtTop
        let afterRail = max(8, corner - TerminalRail.width - workSplit.dividerThickness)
        editorArea.tabBar.leadingInset = terminalAtCorner ? 8 : (railedLeft ? afterRail : corner)
        // The rail itself under the traffic lights: its arrow goes below them.
        terminalRail.topInset = railedLeft && corner > 8 ? TabBarView.height : 0
        editorArea.tabBar.dragsWindow = editorAtTop
        editorArea.tabBar.projectGlow.onTopRow = editorAtTop
        // The sidebar hidden: the bar at the top-left corner offers it back.
        tabBar.showsSidebarButton = !isSidebarVisible && terminalAtCorner
        editorArea.tabBar.showsSidebarButton = !isSidebarVisible && !terminalAtCorner
        tabBar.setSidebarButton(onRight: sidebarOnRight)
        editorArea.tabBar.setSidebarButton(onRight: sidebarOnRight)
        sidebar.header.onRight = sidebarOnRight
        updateUpdateButton()
    }

    /// The bar along the top at the work area's right end: where the Update button goes (as the bar at
    /// the top-left corner offers back a hidden sidebar). A terminal folded to a strip beside the editor
    /// has no room, so the editor's bar takes it.
    var topRightBar: TabBarView {
        if editorArea.isHidden { return tabBar }
        switch terminalPosition {
        case .top: return tabBar
        case .right: return terminalCollapsed ? editorArea.tabBar : tabBar
        case .bottom, .left: return editorArea.tabBar
        }
    }

    /// Shows, changes or hides the Update button as the updater's state changes.
    func updateUpdateButton() {
        let target = topRightBar
        for bar in [tabBar, editorArea.tabBar] {
            guard bar === target, let badge = Updater.shared.badge else {
                if !bar.updateButton.isHidden { bar.setUpdateButton(title: nil) }
                continue
            }
            switch badge {
            case let .update(version):
                bar.setUpdateButton(title: "Update", toolTip: "Next Term \(version) is available. Click to see what’s new and install it.")
            case let .relaunch(version):
                bar.setUpdateButton(title: "Relaunch to Update", symbol: "arrow.clockwise.circle.fill",
                                    toolTip: "Next Term \(version) is ready. Click to relaunch into it.")
            }
            bar.onUpdate = { Updater.shared.showAvailable() }
        }
    }

    /// The smallest a pane may get along the work split: room for its tabs and a few lines.
    private var workMinimum: CGFloat { workSplit.isVertical ? 240 : TabBarView.height + 60 }

    // MARK: collapsing the terminal

    /// The terminal folded down to its tab bar (beside the editor: to the rail), from the button before
    /// its ⋯ or ⌘J. Dragging the divider works as always and unfolds it.
    private(set) var terminalCollapsed = false
    private var collapsedLength: CGFloat { workSplit.isVertical ? TerminalRail.width : TabBarView.height }
    private var terminalLength: CGFloat { workSplit.isVertical ? terminalPane.frame.width : terminalPane.frame.height }
    /// The smallest the terminal may get: its tab bar while collapsed, else the usual minimum, and beside the editor
    /// the room a tab list down its side takes collapsed.
    private var terminalMinimum: CGFloat { terminalCollapsed ? collapsedLength : workMinimum + tabListRoom }

    @objc func toggleTerminalCollapsed(_ sender: Any?) {
        guard !editorArea.isHidden else { return NSSound.beep() } // the terminal is the whole area
        terminalCollapsed ? expandTerminal() : collapseTerminal()
    }

    func collapseTerminal() {
        guard !editorArea.isHidden, !terminalCollapsed else { return }
        terminalCollapsed = true
        workSplit.layoutSubtreeIfNeeded()
        containerWidth.constant = container.frame.width // what the terminals keep behind the rail
        // Before the divider moves: setPosition lays the pane out at once, and every terminal squeezed to the
        // rail for that moment would rewrap (and trim) its scrollback at 2 columns.
        if terminalRailed { keepTerminalWidth(true) }
        let length = workSplit.isVertical ? workSplit.bounds.width : workSplit.bounds.height
        workSplit.setPosition(terminalFirst ? collapsedLength : length - collapsedLength - workSplit.dividerThickness, ofDividerAt: 0)
        if isTerminalFocused, let view = editorArea.activeTextView { window?.makeFirstResponder(view) }
        // Folded, nothing of the terminal shows to type into: whatever the editor has in front takes the keyboard.
        if isTerminalFocused { editorArea.select(editorArea.activeIndex) }
        updateCollapseButton()
    }

    func expandTerminal() {
        guard terminalCollapsed else { return }
        terminalCollapsed = false
        placeWorkDivider() // back to the size it had (the editor's remembered share)
        updateCollapseButton()
    }

    private var isTerminalFocused: Bool {
        guard let view = window?.firstResponder as? NSView else { return false }
        return view.isDescendant(of: terminalPane)
    }

    @objc private func shortcutsChanged() {
        updateCollapseButton()
        updateAskHints() // "⌥⌘K Ask Claude Code" names Send to Agent's key
    }

    /// The arrow points where a click moves the tab bar: to the window's edge to collapse, back to expand.
    private func updateCollapseButton() {
        tabBar.onToggleCollapse = editorArea.isHidden ? nil : { [weak self] in self?.toggleTerminalCollapsed(nil) }
        let toward: String
        switch terminalPosition {
        case .bottom: toward = "down"
        case .top: toward = "up"
        case .left: toward = "left"
        case .right: toward = "right"
        }
        let away = ["down": "up", "up": "down", "left": "right", "right": "left"][toward]!
        let words = terminalCollapsed ? "Expand the terminal" : "Collapse the terminal"
        tabBar.setCollapseButton(symbol: "chevron.\(terminalCollapsed ? away : toward)",
                                 toolTip: KeyboardShortcuts.shared.hint(words, #selector(toggleTerminalCollapsed(_:))), label: words)
        updateUpdateButton()
        updateRail()
        refreshVisibility() // folded or not, the tab in front is out of sight or back in it
        showTabStrip() // folded to its bar above or below the editor, the bar shows the tabs a list had
    }

    // MARK: the rail

    /// The terminal folded beside the editor: a slim bar at the window's edge with each tab's mark.
    let terminalRail = TerminalRail(frame: NSRect(x: 0, y: 0, width: TerminalRail.width, height: 600))
    var terminalRailed: Bool { terminalCollapsed && workSplit.isVertical }
    /// Behind the rail the terminals keep the width they had: squeezed to it they would wrap every line,
    /// and an agent's screen could no longer be read for its status.
    lazy var containerTrailing = container.trailingAnchor.constraint(equalTo: terminalPane.trailingAnchor)
    private lazy var containerWidth = container.widthAnchor.constraint(equalToConstant: workMinimum)
    /// The terminals' leading edge, with their trailing one above: with a tab list down the terminal's side, the edge
    /// on its side sits in by the list's width (TerminalWindowTabList.swift).
    lazy var containerLeading = container.leadingAnchor.constraint(equalTo: terminalPane.leadingAnchor)

    /// The terminals at `containerWidth` whatever the pane's width, or back to following the pane.
    private func keepTerminalWidth(_ keep: Bool) {
        // One off before the other on: both at once cannot be met.
        if keep {
            containerTrailing.isActive = false
            containerWidth.isActive = true
        } else {
            containerWidth.isActive = false
            containerTrailing.isActive = true
        }
    }

    private func installRail() {
        terminalRail.isHidden = true
        terminalRail.translatesAutoresizingMaskIntoConstraints = false
        terminalPane.addSubview(terminalRail) // over the tab bar and the terminals
        NSLayoutConstraint.activate([
            terminalRail.topAnchor.constraint(equalTo: terminalPane.topAnchor),
            terminalRail.leadingAnchor.constraint(equalTo: terminalPane.leadingAnchor),
            terminalRail.trailingAnchor.constraint(equalTo: terminalPane.trailingAnchor),
            terminalRail.bottomAnchor.constraint(equalTo: terminalPane.bottomAnchor),
        ])
        terminalRail.onExpand = { [weak self] in self?.expandTerminal() }
        // Opened first, so the tab's coming forward is an ordinary focus change, not what unfolds the terminal.
        terminalRail.onSelect = { [weak self] index in
            self?.expandTerminal()
            self?.select(index)
        }
    }

    /// The tab bar's tabs as the rail's marks: the same state, the title and state as the tooltip.
    private func updateRailMarks(_ items: [TabBarItem]) {
        var marks: [TerminalRail.Mark] = []
        for (index, (group, item)) in zip(groups, items).enumerated() {
            let status = group.isSplit ? item.tooltip : item.accessibilityStatus // a split tab: its panes, line by line
            marks.append(TerminalRail.Mark(id: ObjectIdentifier(group), state: item.state, toolTip: item.title + "\n" + status,
                                           label: "\(item.title), \(item.accessibilityStatus)", selected: index == activeIndex))
        }
        terminalRail.update(marks: marks)
    }

    /// Shows the rail in place of the tab bar and terminals while folded beside the editor, and back.
    private func updateRail() {
        let railed = terminalRailed
        guard terminalRail.isHidden == railed else { return }
        keepTerminalWidth(railed)
        if !railed { terminalRail.stopPulse() }
        terminalRail.pointsLeft = terminalPosition == .right
        terminalRail.isHidden = !railed
        tabBar.isHidden = railed
        container.isHidden = railed
        updateInsets()
        refreshVisibility()
        refresh()
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        if splitView === workSplit { return terminalFirst ? terminalMinimum : workMinimum }
        // The sidebar is 160–640 wide, on either side.
        return sidebarOnRight ? max(320, splitView.bounds.width - 640) : 160
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        if splitView === workSplit {
            return (workSplit.isVertical ? splitView.bounds.width : splitView.bounds.height) - (terminalFirst ? workMinimum : terminalMinimum)
        }
        return sidebarOnRight ? splitView.bounds.width - 160 : min(640, splitView.bounds.width - 320)
    }

    /// Dragged out of the rail, the terminal is the rail or at least its usual width, never a few columns:
    /// the drag's limits are set when it starts, and folded the terminal's is the rail's.
    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        guard splitView === workSplit, workSplit.isVertical, !editorArea.isHidden else { return proposed }
        let room = workSplit.bounds.width - workSplit.dividerThickness
        let terminal = terminalFirst ? proposed : room - proposed
        let wanted = terminalRailed && terminal < workMinimum / 2 ? collapsedLength : max(terminal, workMinimum + tabListRoom)
        return terminalFirst ? wanted : room - wanted
    }

    /// A one-pixel divider is hard to hit: grab it anywhere within 3 points either side. One beside a hidden
    /// pane (the editor with nothing open, a hidden sidebar) can't be grabbed at all: it ran down the work
    /// area's edge, 3 points from the sidebar's own divider, and a press there that moved a point had AppKit
    /// show the pane by itself, empty.
    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
                   ofDividerAt dividerIndex: Int) -> NSRect {
        SplitDivider.grabArea(drawn: drawnRect, sideBySide: splitView.isVertical, hidden: isDividerHidden(splitView, dividerIndex))
    }

    /// Nor is it drawn: the pane beside it reaches the edge (the terminal fills the work area).
    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        isDividerHidden(splitView, dividerIndex)
    }

    private func isDividerHidden(_ splitView: NSSplitView, _ index: Int) -> Bool {
        SplitDivider.isHidden(at: index, panesHidden: splitView.arrangedSubviews.map(\.isHidden))
    }

    /// Set while the terminal is being given the whole work area back, so that resize is left alone.
    private var refittingTerminal = false

    func splitViewDidResizeSubviews(_ notification: Notification) {
        fitTabList() // a tab list collapses by itself when the terminal beside it gets too narrow, and opens again
        if (notification.object as? NSSplitView) === workSplit {
            let length = workSplit.isVertical ? workSplit.bounds.width : workSplit.bounds.height
            if editorArea.isHidden {
                // Nothing open: the terminal has the whole work area, whatever moved the divider. Never
                // remembered as the editor's share.
                if !refittingTerminal, terminalLength < length - 0.5 {
                    refittingTerminal = true
                    workSplit.adjustSubviews()
                    refittingTerminal = false
                }
                return
            }
            // Remember the split the user dragged to (not the one a window resize produces).
            if length > 200, NSApp.currentEvent?.type == .leftMouseDragged {
                // Dragging a collapsed terminal open unfolds it; the size it is dragged to is remembered as usual.
                if terminalCollapsed, terminalLength > collapsedLength + 8 {
                    terminalCollapsed = false
                    updateCollapseButton()
                }
                if !terminalCollapsed {
                    let editor = workSplit.isVertical ? editorArea.frame.width : editorArea.frame.height
                    AppDelegate.shared.setEditorFraction(editor / length, sideBySide: workSplit.isVertical)
                }
            }
            return
        }
        if isSidebarVisible, sidebar.frame.width >= 160 { AppDelegate.shared.sidebarWidth = sidebar.frame.width }
        // The sidebar's width is what the window column's room is measured beside.
        if (notification.object as? NSSplitView) === splitView { columnHost.place() }
    }

    func sidebar(_ sidebar: ProjectSidebarView, insert text: String) {
        guard let tab = activeTab else { return }
        tab.userInput() // the user's text: a restored action waiting in the tab is dropped, never run after it
        tab.view.typeIn(text)
        window?.makeFirstResponder(tab.view)
    }

    func sidebar(_ sidebar: ProjectSidebarView, openProject directory: String) {
        AppDelegate.shared.openProject(at: URL(fileURLWithPath: directory), from: self)
    }

    func sidebar(_ sidebar: ProjectSidebarView, openFile url: URL) {
        openFile(url)
    }

    /// A single click: never another app, and the keyboard stays in the tree to click or arrow on.
    func sidebar(_ sidebar: ProjectSidebarView, previewFile url: URL) {
        openFile(url, focus: false, preview: true, handOff: false)
    }

    func sidebar(_ sidebar: ProjectSidebarView, didMove from: String, to: String) {
        editorArea.itemMoved(from: from, to: to)
    }

    // MARK: editor

    /// Opens a file in the editor, at a line if given. What the editor cannot show (images, binaries,
    /// huge files) opens in its app instead, safely, unless `handOff` is false. `preview` opens it in the
    /// preview tab (a single click in the sidebar).
    func openFile(_ url: URL, line: Int? = nil, column: Int = 1, focus: Bool = true, preview: Bool = false, handOff: Bool = true) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            if handOff { SafeOpen.open(url, from: window) }
            return
        }
        if editorArea.open(url, line: line, column: column, focus: focus, preview: preview) != .opened {
            if handOff { SafeOpen.open(url, from: window) }
            return
        }
        let path = canonicalPath(url.path)
        // Opened from ⌘P, a search result or a link: the sidebar shows where it is, even if it was in front.
        frontFile = editorArea.activePath
        if isSidebarVisible { sidebar.reveal(path) }
        recentFiles.removeAll { $0 == path }
        recentFiles.insert(path, at: 0)
        if recentFiles.count > 50 { recentFiles.removeLast() }
    }

    // MARK: agent sessions

    private(set) lazy var sessionsPanel: SessionsPanelController = {
        let panel = SessionsPanelController()
        panel.onResume = { [weak self] session, fork in
            guard let self else { return }
            AppDelegate.shared.resume(session, fork: fork, project: self.project ?? self.searchRoot)
        }
        return panel
    }()

    /// ⌥⌘O: the project's agent sessions, to pick one up again.
    @objc func resumeSession(_ sender: Any?) {
        guard let window else { return }
        sessionsPanel.show(project: project ?? searchRoot, over: window)
    }

    /// A tab in `directory` running `command` once its shell is at the prompt. An untouched first tab in
    /// the same folder is used rather than a second one; never a restored one, which may hold a put-back line.
    @discardableResult
    func runInNewTab(directory: String, command: String, title: String?) -> TerminalTab {
        let folder = canonicalPath(directory)
        let tab: TerminalTab
        if groups.count == 1, tabs.count == 1, let only = tabs.first, only.remote == nil, only.isUntouched,
           canonicalPath(only.directory) == folder {
            tab = only
        } else {
            tab = addTab(directory: folder)
        }
        if let title { tab.userTitle = title }
        show(tab)
        tab.runWhenReady(command)
        return tab
    }

    // MARK: the open file in the sidebar

    /// The file in front in the editor, shown in the project sidebar (the sidebar comes back if hidden).
    @objc func revealInSidebar(_ sender: Any?) {
        guard let path = editorArea.activePath else { return NSSound.beep() }
        if !isSidebarVisible { toggleProjectSidebar(nil) }
        sidebar.reveal(path)
    }

    /// The file that was in front last time we looked, so moving the caret doesn't reveal it again.
    private var frontFile: String?

    /// The sidebar follows the file in front when another one comes forward (a tab, a closed tab).
    private func followActiveFile() {
        let path = editorArea.activePath
        guard path != frontFile else { return }
        frontFile = path
        if let path, isSidebarVisible { sidebar.reveal(path) }
    }

    // MARK: go to file

    /// Files opened in this window, newest first: what ⌘P lists before you type.
    private(set) var recentFiles: [String] = []

    /// Tab completion at this window's keyboard.
    private(set) lazy var completions = CompletionController(owner: self)
    /// Suggestions while typing: their keys at this window's keyboard.
    private(set) lazy var ghosts = GhostController(owner: self)

    private(set) lazy var fileFinder: GoToFileController = {
        let finder = GoToFileController()
        finder.onOpen = { [weak self] path, line, column in self?.openFile(URL(fileURLWithPath: path), line: line, column: column) }
        return finder
    }()

    private(set) lazy var headingFinder: GoToHeadingController = {
        let finder = GoToHeadingController()
        finder.onJump = { [weak self] line in
            guard let editor = self?.editorArea.activeEditor else { return }
            self?.window?.makeFirstResponder(editor.textView)
            editor.textView.go(toLine: line + 1)
        }
        return finder
    }()

    /// Edit › Go to Heading… in a Markdown file (one Live Preview reads: up to 2 MB): its headings to jump to, and its
    /// counts, or the selection's. The lines come as the styler has read them, so nothing is read again.
    @objc func goToHeading(_ sender: Any?) {
        guard let editor = editorArea.activeEditor, let styler = editor.markdown, let window else { return NSSound.beep() }
        let text = editor.document.storage.string as NSString, index = editor.document.lines
        let lines = styler.allLines()
        let selection = editor.textView.selectedRange()
        let chosen = selection.length > 0 ? selection : nil
        let stats = MarkdownOutline.stats(lines, in: text, index, selection: chosen)
        let headings = MarkdownOutline.headings(lines, in: text, index)
        headingFinder.show(headings: headings, stats: stats, ofSelection: chosen != nil, over: window)
    }

    /// ⌘P: any file in the project, by a few letters of its name or path. Selected text (in the editor or
    /// the terminal) starts the search, as it does for Find; `app/User.php:42` in a log opens at line 42.
    @objc func goToFile(_ sender: Any?) {
        guard let window else { return }
        fileFinder.show(root: searchRoot, recent: recentFiles, query: selectionSeed, over: window)
    }

    /// The selected text, if it is one short line: in the editor when it has the keyboard, else the terminal's.
    var selectionSeed: String? {
        var text: String?
        if isEditorFocused, let view = editorArea.activeTextView {
            let range = view.selectedRange()
            if range.length > 0, NSMaxRange(range) <= (view.string as NSString).length {
                text = (view.string as NSString).substring(with: range)
            }
        } else {
            text = activeTab?.view.getSelection()
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              !trimmed.contains("\n"), trimmed.count <= 200 else { return nil }
        return trimmed
    }

    var isEditorFocused: Bool {
        guard !editorArea.isHidden, let view = window?.firstResponder as? NSView else { return false }
        return view.isDescendant(of: editorArea)
    }

    /// The project sidebar has the keyboard (its tree, or a name being edited in it).
    var isSidebarFocused: Bool {
        guard isSidebarVisible, let view = window?.firstResponder as? NSView else { return false }
        return view.isDescendant(of: sidebar)
    }

    func editorAreaDidShowOrHide(_ area: EditorArea) {
        followActiveFile()
        editorShownOrHidden()
    }

    // MARK: Claude Code sees the selection

    private var selectionShare: DispatchWorkItem?
    /// The agent the diffs' Ask hints name, as last shown (refresh() runs four times a second).
    private var askedAgent: String?

    func editorAreaSelectionChanged(_ area: EditorArea) {
        followActiveFile()
        scheduleSelectionShare()
    }

    /// Lines were selected in a diff in this window, or its selection went: the agents hear it, as they hear
    /// the editor's, and the diff's Ask hint follows.
    @objc private func diffSelectionChanged(_ notification: Notification) {
        guard let view = notification.object as? NSView, view.isDescendant(of: editorArea) else { return }
        updateAskHints()
        scheduleSelectionShare()
    }

    private func scheduleSelectionShare() {
        guard ClaudeIDEServer.shared.isRunning || GeminiIDEServer.shared.isRunning || CopilotIDEServer.shared.isRunning else { return }
        selectionShare?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.shareSelectionWithClaude() }
        selectionShare = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work) // while dragging, once it settles
    }

    /// The lines selected in the diff in front (a diff tab, the Git Diff tab's file or its All files page): what
    /// the agents are told instead of the editor's selection while there are any.
    var activeDiffShare: DiffShare? {
        if let diff = editorArea.activeDiff { return diff.diffShare() }
        if let page = editorArea.activeGitDiff?.allFiles, !page.isHidden { return page.diffShare() }
        return nil
    }

    /// Tells the `claude` sessions in this window's tabs what the editor shows: the selected lines, or the
    /// file the caret is in, or nothing (no file open).
    func shareSelectionWithClaude(only clients: Set<ClaudeIDEServer.ClientID>? = nil) {
        if clients == nil, GeminiIDEServer.shared.isRunning { GeminiIDEServer.shared.setContext(openFiles: openFilesForGemini()) }
        if clients == nil { shareSelectionWithCopilot() }
        let recipients = clients ?? AppDelegate.shared.claudeClients(in: self)
        guard !recipients.isEmpty else { return }
        ClaudeIDEServer.shared.notify("selection_changed", currentSelectionForClaude(), to: recipients)
    }

    /// Gemini CLI and Qwen Code: up to 10 files by recency, the active one first with its caret and
    /// selection, 1-based. Secret-holding files (.env) are left out. Lines selected in a diff in front make
    /// its file the active one.
    func openFilesForGemini() -> [[String: Any]] {
        let share = activeDiffShare
        if let share, let file = share.geminiFile {
            let others = editorArea.documents.filter { !$0.holdsSecrets && $0.path != share.path }.sorted { $0.lastFocused > $1.lastFocused }
            return [file] + others.prefix(9).map { ["path": $0.path, "timestamp": Int($0.lastFocused.timeIntervalSince1970 * 1000)] }
        }
        let active = editorArea.activeEditor
        let documents = editorArea.documents.filter { !$0.holdsSecrets }
            .sorted { ($0 === active?.document ? 1 : 0, $0.lastFocused) > ($1 === active?.document ? 1 : 0, $1.lastFocused) }
        return documents.prefix(10).map { document in
            var file: [String: Any] = ["path": document.path, "timestamp": Int(document.lastFocused.timeIntervalSince1970 * 1000)]
            if let active, active.document === document {
                file["isActive"] = true
                let text = active.textView.string as NSString
                let range = active.textView.selectedRange()
                let line = document.lines.line(at: min(range.location, text.length))
                file["cursor"] = ["line": line + 1, "character": min(range.location, text.length) - document.lines.starts[line] + 1]
                if range.length > 0, NSMaxRange(range) <= text.length {
                    file["selectedText"] = String(text.substring(with: range).prefix(16_384))
                }
            }
            return file
        }
    }

    func currentSelectionForClaude() -> [String: Any] {
        // Lines selected in a diff: the file's lines now, or the old side's text with a caret where it was.
        if let share = activeDiffShare { return share.claudeParams }
        guard let editor = editorArea.activeEditor else {
            return ClaudeIDEServer.selectionParams(path: nil, text: "", start: (0, 0), end: (0, 0))
        }
        let text = editor.textView.string as NSString
        let range = editor.textView.selectedRange()
        let lines = editor.document.lines
        func position(_ offset: Int) -> (line: Int, character: Int) {
            let line = lines.line(at: min(offset, text.length))
            return (line, min(offset, text.length) - lines.starts[line])
        }
        let selected = range.length > 0 && NSMaxRange(range) <= text.length ? text.substring(with: range) : ""
        // A file that holds secrets, by its own name or its link's, is shared as no file at all.
        let path = editor.document.holdsSecrets ? nil : editor.document.path
        return ClaudeIDEServer.selectionParams(path: path, text: selected,
                                               start: position(range.location), end: position(NSMaxRange(range)))
    }

    /// The editor area showed or hid (it does that itself, as its first tab opens or its last closes): the
    /// terminal makes room for it or takes the whole work area back, and the bars along the top follow.
    private func editorShownOrHidden() {
        let visible = !editorArea.isHidden
        if !visible { terminalCollapsed = false } // nothing to collapse beside
        updateCollapseButton()
        workSplit.adjustSubviews()
        if visible {
            placeWorkDivider()
        } else if let view = activeTab?.view {
            window?.makeFirstResponder(view)
        }
        updateInsets()
        updateTitle()
    }

    // MARK: send to agent

    /// The tab whose agent gets what you send: the front tab if an agent runs there, else the agent tab
    /// used most recently.
    /// Only agents on this Mac: what is sent is paths of this Mac's files, which mean nothing on a server.
    var agentTab: TerminalTab? {
        if let tab = activeTab, tab.remote == nil, tab.status.running, tab.status.kind == .agent { return tab }
        return tabs.filter { $0.remote == nil && $0.status.running && $0.status.kind == .agent }.max { $0.lastSelected < $1.lastSelected }
    }

    /// ⌥⌘K: the editor's selection (or its file), the files and folders selected in the sidebar, or the text
    /// selected in the terminal.
    @objc func sendToAgent(_ sender: Any?) {
        if isEditorFocused {
            sendEditorSelection()
        } else if let window, window.firstResponder === sidebar.outline, !sidebar.selection.isEmpty {
            send(sidebar.selection.map { ContextItem(path: $0.url.path, isFolder: $0.isFolder) })
        } else if let tab = terminalSelectionToSend {
            sendSelection(of: tab)
        } else {
            NSSound.beep()
        }
    }

    /// The editor's selection as lines of its file (or the whole file when nothing is selected), and the
    /// same from a diff's new side.
    func sendEditorSelection() {
        if let editor = editorArea.activeEditor {
            let document = editor.document
            let range = editor.textView.selectedRange()
            var lines: ClosedRange<Int>?
            if range.length > 0 {
                let first = document.lines.line(at: range.location)
                // A selection ending at the start of a line does not include that line.
                let endOffset = max(range.location, NSMaxRange(range) - 1)
                lines = (first + 1)...(document.lines.line(at: endOffset) + 1)
            }
            var item = ContextItem(path: document.path, lines: lines)
            if document.isDirty {
                item.note = "unsaved changes in the editor"
                if range.length > 0 {
                    let code = (document.text as NSString).substring(with: range)
                    if !AgentPrompt.isTooLargeToInline(code) {
                        item.code = code
                        item.language = document.language ?? "text"
                    }
                }
            }
            send([item])
        } else if let notebook = editorArea.activeNotebook {
            send([ContextItem(path: notebook.path)]) // the agent reads the notebook itself
        } else if let database = editorArea.activeDatabase {
            send([database.contextItem()]) // the table, and the selected rows when they are few
        } else if let data = editorArea.activeData {
            send([data.contextItem()]) // the file, at the selected rows' lines
        } else if let diff = editorArea.activeDiff {
            // The file at the new side's selected lines, or the old side's text; never into an agent's prompt while
            // it waits on its proposal.
            guard let item = diff.contextItem() else { return NSSound.beep() }
            send([item])
        } else if let page = editorArea.activeGitDiff?.allFiles, !page.isHidden {
            guard let item = page.contextItem() else { return NSSound.beep() }
            send([item])
        }
    }

    /// The Ask hint in a diff's toolbar (or its menu's Send to Agent): what ⌥⌘K sends from there.
    func askAgent(from host: DiffSelectionHost) {
        let item = (host as? DiffPane)?.contextItem() ?? (host as? AllFilesView)?.contextItem()
        guard let item else { return NSSound.beep() }
        send([item])
    }

    /// "⌥⌘K Ask Claude Code" in a diff's toolbar, while lines of changes not committed yet are selected there (not
    /// a secret file's) and an agent runs in a tab here (the one Send to Agent types into); hidden otherwise.
    func updateAskHints() {
        let hosts: [DiffSelectionHost] = editorArea.diffs + editorArea.gitDiffs.compactMap(\.allFiles)
        guard !hosts.isEmpty else { return }
        let tab = agentTab
        let agent = tab.map { (name: Self.agentName(of: $0), tab: $0.title) }
        let key = KeyboardShortcuts.shared.key(for: #selector(sendToAgent(_:)))?.display
        for host in hosts {
            host.askRoom.show(agent: agent != nil && host.offersAsk ? agent : nil, key: key)
        }
    }

    /// The agent in a tab, as Next Term names it (Claude Code, Codex, Gemini CLI…), else its program.
    static func agentName(of tab: TerminalTab) -> String {
        let status = tab.status
        let kind = AgentKind(program: status.program) ?? AgentKind(program: CommandClassifier.programName(status.expandedCommand))
        return kind?.name ?? status.program
    }

    func sidebar(_ sidebar: ProjectSidebarView, sendToAgent urls: [(url: URL, isFolder: Bool)]) {
        send(urls.map { ContextItem(path: $0.url.path, isFolder: $0.isFolder) })
    }

    /// Why nothing was sent: no agent runs here, or the only ones run on a server (`agentTab` skips them).
    func noAgentAlert() -> NSAlert {
        let alert = NSAlert()
        if tabs.contains(where: { $0.remote != nil && $0.status.running && $0.status.kind == .agent }) {
            alert.messageText = "The agent in this window runs on a server"
            alert.informativeText = "Send to Agent types this Mac’s paths, which mean nothing there. Start an agent in a tab on this Mac to send to it."
        } else {
            alert.messageText = "No agent is running in this window"
            alert.informativeText = "Start one in a tab (claude, codex, gemini, junie…), then send again."
        }
        return alert
    }

    /// Types references to `items` into the agent's prompt, in its own syntax, relative to its folder.
    /// Never presses Enter: you add the instruction.
    func send(_ items: [ContextItem]) {
        guard let tab = agentTab, let window else {
            let alert = noAgentAlert()
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        let base = canonicalPath(tab.directory)
        let relative = items.map { item -> ContextItem in
            var item = item
            let path = canonicalPath(item.path)
            if path == base { item.path = "." } else if path.hasPrefix(base + "/") { item.path = String(path.dropFirst(base.count + 1)) }
            return item
        }
        show(tab)
        defer { window.makeFirstResponder(tab.view) }
        // Claude connected to Next Term: the mentions go into its prompt directly, as from VS Code. A mention
        // carries only the file and its lines, so anything with more to say ("as staged", "deleted") is typed.
        // OpenCode takes a mention only with lines: a whole file is typed too, in its own form.
        if let client = AppDelegate.shared.claudeClient(for: tab) {
            let canonical = items.map { item -> ContextItem in
                var item = item
                item.path = canonicalPath(item.path)
                return item
            }
            if let mentions = IDELink.mentions(canonical, opencode: ClaudeIDEServer.shared.isOpencode(client)) {
                for mention in mentions { ClaudeIDEServer.shared.notify("at_mentioned", mention.params, to: [client]) }
                return
            }
        }
        if sendToCopilot(items, in: tab) { return }
        let dialect = AgentDialect.forProgram(tab.status.program)
        let segments = AgentPrompt.segments(instruction: "", items: relative, dialect: dialect)
        // Inside a bracketed paste a line break is text, never Return, so code keeps its lines and tabs.
        // An agent that doesn't take pastes gets the references alone, on one line: a line break would send.
        let pasted = tab.view.getTerminal().bracketedPasteMode
        for (index, segment) in segments.enumerated() {
            if pasted { tab.view.typeText(segment) } else if index == 0 { tab.view.typeIn(segment) }
        }
    }

    /// For the self-test: what `send` would type into `tab`.
    func agentText(_ items: [ContextItem], for program: String) -> String {
        AgentPrompt.segments(instruction: "", items: items, dialect: AgentDialect.forProgram(program)).joined(separator: "\n")
    }

    // MARK: diffs

    /// ⌥⌘G: the changes of the file being edited, or the file selected in the sidebar, side by side in the
    /// Git Diff tab, the changed files listed beside them.
    @objc func showChanges(_ sender: Any?) {
        let fromEditor = isEditorFocused || window?.firstResponder !== sidebar.outline
        // A database file has no lines to compare, and one too large for the editor is too large to compare.
        if fromEditor, editorArea.activeDatabase != nil || editorArea.activeData?.isTooLargeForEditor == true { return NSSound.beep() }
        // A diff of the file's changes is in front already: it stays on All Changes, Unstaged or Staged, as chosen.
        if fromEditor, let diff = editorArea.activeDiff, diff.proposal == nil, diff.commit == nil { return diff.reload() }
        if let path = editorArea.activePath, fromEditor {
            return showChanges(of: URL(fileURLWithPath: path))
        }
        if let file = sidebar.selection.first(where: { !$0.isFolder }) { return showChanges(of: file.url) }
        if let gone = sidebar.selectedDeleted.first(where: { !$0.isDirectory }) { return showChanges(of: gone.url) }
        NSSound.beep()
    }

    func sidebar(_ sidebar: ProjectSidebarView, showChanges url: URL) { showChanges(of: url) }

    /// ⌥⌘Z, Git › Rollback…, by where the keyboard is:
    /// - in the editor with the caret or a selection on changed lines: those lines back to the last commit, at once
    ///   (Rollback Lines, ⌘Z undoes it);
    /// - in a diff of uncommitted changes: its current change, at once, the next one current after it (Rollback Hunk);
    /// - else the file in front or what is selected in the sidebar (files, folders, deleted files), after asking
    ///   (GitActions.rollback).
    @objc func gitRollback(_ sender: Any?) {
        if isEditorFocused, let editor = editorArea.activeEditor, editor.touchesChanges { return rollbackLines(in: editor) }
        if let diff = editorArea.activeDiff, diff.canRollBackHunk, let view = window?.firstResponder as? NSView, view.isDescendant(of: diff) {
            return diff.rollBack(hunk: diff.currentHunk, of: diff.file)
        }
        let targets = rollbackTargets
        guard !targets.isEmpty else { return NSSound.beep() }
        rollback(targets)
    }

    /// Rollback Lines in `editor`, then a notice with Undo. A file with no unsaved edits before is saved after, so git
    /// and the sidebar see what the editor shows; one with unsaved edits stays unsaved, the rollback among them.
    private func rollbackLines(in editor: CodeEditorView) {
        let document = editor.document, wasSaved = !document.isDirty
        editor.rollbackLines { [weak self, weak editor] count in
            guard let self, let editor else { return }
            guard count > 0 else { return NSSound.beep() }
            if wasSaved { self.editorArea.save(document) }
            let after = document.text
            let lines = count == 1 ? "1 line" : "\(count) lines"
            GitToast.show("Rolled back \(lines) in \(document.name)", in: self.window, button: "Undo") { [weak self, weak editor] in
                // Only while nothing was typed since: then the edit on top of the undo stack is the rollback.
                guard let self, let editor, document.text == after, editor.textView.undoManager?.canUndo == true else { return NSSound.beep() }
                editor.textView.undoManager?.undo()
                if wasSaved { self.editorArea.save(document) }
            }
        }
    }

    func sidebar(_ sidebar: ProjectSidebarView, rollback urls: [URL]) { rollback(urls) }

    /// What Git › Rollback… acts on: as Show Changes, what is in front while the sidebar doesn't have the keyboard (the
    /// file being edited, the Git Diff tab's selected file, a file's diff of its uncommitted changes), else the sidebar's
    /// selection, deleted files included. A diff of a commit or a proposal has nothing to roll back.
    var rollbackTargets: [URL] {
        let fromEditor = isEditorFocused || window?.firstResponder !== sidebar.outline
        if fromEditor, editorArea.activePane != nil {
            if let gitDiff = editorArea.activeGitDiff { return gitDiff.rollbackTarget.map { [$0] } ?? [] }
            if let diff = editorArea.activeDiff { return diff.commit == nil && diff.proposal == nil ? [URL(fileURLWithPath: diff.absolutePath)] : [] }
            if let path = editorArea.activePath { return [URL(fileURLWithPath: path)] }
        }
        return sidebar.selection.map(\.url) + sidebar.selectedDeleted.map(\.url)
    }

    /// Rolls back `urls`, all in the repository of the first: the others are left alone. Paths are read as the kernel
    /// spells them (`/tmp` is `/private/tmp`), but a file's own name as it is: a link is rolled back, not what it points to.
    func rollback(_ urls: [URL]) {
        guard let first = urls.first else { return NSSound.beep() }
        func spelled(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            if Rollback.diskKind("", root: path) == .directory { return canonicalPath(path) }
            return (canonicalPath((path as NSString).deletingLastPathComponent) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
        }
        // A folder is its own start (the project's own row is the root itself); a file, or a deleted one, its folder's.
        let start = spelled(first)
        let isFolder = Rollback.diskKind("", root: start) == .directory
        let root = canonicalPath(ProjectRoot.find(from: isFolder ? start : (start as NSString).deletingLastPathComponent))
        let paths = urls.map(spelled).compactMap { path -> String? in
            if path == root { return "" }
            return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
        }
        guard !paths.isEmpty, FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(".git")) else { return NSSound.beep() }
        withGit(at: root) { $0.rollback(paths) }
    }

    /// A Databases row's action. Hand-offs read the password from the project's file themselves.
    func sidebar(_ sidebar: ProjectSidebarView, database: DetectedDatabase, perform action: DatabaseAction) {
        guard let root = sidebar.root?.path else { return }
        switch action {
        case .open:
            if let path = database.filePath { openFile(URL(fileURLWithPath: path)) }
        case .tablePlus:
            DatabaseHandOff.openInTablePlus(database, root: root, window: window)
        case .terminal:
            DatabaseHandOff.openInTerminal(database, root: root, controller: self)
        case .vercel:
            DatabaseHandOff.openInVercel(database, root: root, controller: self)
        }
    }

    func showChanges(of url: URL, base: GitRunner.DiffBase = .head) {
        let path = canonicalPath(url.path)
        let root = canonicalPath(ProjectRoot.find(from: (path as NSString).deletingLastPathComponent))
        guard path.hasPrefix(root + "/"), FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(".git")) else {
            let alert = NSAlert()
            alert.messageText = "“\(url.lastPathComponent)” is not in a git repository"
            alert.informativeText = "Changes are shown against the last commit, so the file has to be in one."
            if let window { alert.beginSheetModal(for: window) }
            return
        }
        editorArea.openGitDiff(root: root, path: String(path.dropFirst(root.count + 1)), base: base)
    }

    @objc func saveDocument(_ sender: Any?) { editorArea.saveActive() }
    @objc func saveAllDocuments(_ sender: Any?) { editorArea.saveAll() }

    /// ⌃`: between the editor and the terminal, as in VS Code.
    @objc func toggleEditorFocus(_ sender: Any?) {
        if isEditorFocused {
            if let view = activeTab?.view { window?.makeFirstResponder(view) }
        } else if let view = editorArea.activeTextView {
            window?.makeFirstResponder(view)
        } else {
            NSSound.beep()
        }
        updateTitle()
    }

    @objc func goToLine(_ sender: Any?) {
        guard let editor = editorArea.activeEditor, let window else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "Line, or line:column, in “\(editor.document.name)” (1–\(editor.document.lines.count))."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "42 or 42:7"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let parts = field.stringValue.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let line = parts.first else { return NSSound.beep() }
            window.makeFirstResponder(editor.textView)
            editor.textView.go(toLine: line, column: parts.count > 1 ? parts[1] : 1)
        }
    }

    /// View › Hide .env Values, on or off for the file in front only (Settings › Editor does all).
    @objc func toggleEnvValues(_ sender: Any?) {
        guard let editor = editorArea.activeEditor, editor.isEnvFile else { return NSSound.beep() }
        editor.toggleEnvValues()
    }

    /// View › Markdown Live Preview, for the Markdown file in front: Live Preview or Source, remembered for that file
    /// (Settings › Editor sets what the others open in).
    @objc func toggleMarkdownPreview(_ sender: Any?) {
        guard let editor = editorArea.activeEditor, editor.preview != nil else { return NSSound.beep() }
        editor.toggleMarkdownPreview()
    }

    func sidebar(_ sidebar: ProjectSidebarView, openTabIn directory: String) {
        addTab(directory: directory)
    }

    /// The editor's size in the editors, and the terminals' size (their own, else the editor's) in the terminals.
    func applyFontSizes() {
        let font = Theme.terminalFont(size: AppDelegate.shared.terminalFontSize)
        for tab in tabs { tab.view.font = font }
        editorArea.applyFont()
    }

    // MARK: menu actions (reached through the responder chain)

    /// In a project window, new tabs start in the project; otherwise in the current tab's folder.
    /// ⌥⌘T: a tab on a server (a saved host, or a new one).
    @objc func newRemoteTab(_ sender: Any?) {
        guard let window else { return }
        RemoteTabSheet.show(over: window) { [weak self] remote in self?.addRemoteTab(remote) }
    }

    /// Opens the address the active tab's server printed (" · :5173" in its title), in the browser.
    @objc func openServedURL(_ sender: Any?) {
        guard let url = activeTab?.servedURL else { return NSSound.beep() }
        NSWorkspace.shared.open(url)
    }

    @objc func newTab(_ sender: Any?) {
        addTab(directory: newTabDirectory())
    }

    /// ⌘W closes what has the keyboard: the file being edited, or the terminal tab.
    @objc func closeTab(_ sender: Any?) {
        if isEditorFocused { return editorArea.closeActive() }
        // From the project tree, the file in front in the editor, where its files open: never a terminal tab.
        if isSidebarFocused { return editorArea.isHidden || editorArea.isEmpty ? NSSound.beep() : editorArea.closeActive() }
        if terminalRailed { return NSSound.beep() } // its tabs are folded away: nothing on screen to close
        if let tab = activeTab { requestClose(tab) }
    }

    @objc func renameTab(_ sender: Any?) {
        tabStrip.beginRename(at: activeIndex)
    }

    /// What selects each tab, as the Window menu has it now (Settings can change it): ⌘1…⌘8 the first
    /// eight, ⌘9 the last. None with a single tab, where there is nothing to switch to.
    static func tabShortcuts(count: Int) -> [String?] {
        guard count > 1 else { return Array(repeating: nil, count: count) }
        var byNumber: [Int: String] = [:]
        let action = #selector(selectTabByNumber(_:))
        for item in NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? [] where item.action == action {
            if let chord = KeyboardShortcuts.chord(of: item) { byNumber[item.tag] = chord.display }
        }
        return (0..<count).map { index in
            if index < 8 { return byNumber[index + 1] }
            return index == count - 1 ? byNumber[9] : nil
        }
    }

    // MARK: git

    private(set) lazy var branchPopup = BranchPopupController()

    /// The folder git operations act on: the sidebar's, when it is in a repository.
    private var gitFolder: String? { sidebar.git.snapshot != nil ? sidebar.root?.path : nil }

    /// ⌥⌘B, or a click on the branch at the top of the sidebar.
    @objc func showBranches(_ sender: Any?) {
        guard let anchor = branchPopupAnchor, let folder = gitFolder else { return NSSound.beep() }
        if branchPopup.isVisible { return branchPopup.close() }
        branchPopup.show(for: self, directory: folder, snapshot: sidebar.git.snapshot, anchor: anchor)
    }

    /// A git command in a terminal tab here failed because the worktree at `path` has `branch` (TerminalTab): a notice
    /// whose Free It… asks what to do with that worktree, Remove Worktree when it can go (GitActions.held, with no
    /// switch: the command is the user's to run again).
    func noticeHeldBranch(_ branch: String, at path: String, from directory: String) {
        let root = canonicalPath(ProjectRoot.find(from: directory))
        guard FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(".git")) else { return }
        let folder = (path as NSString).lastPathComponent
        GitToast.show("“\(branch)” is checked out in “\(folder)”", in: window, button: "Free It…") { [weak self] in
            self?.withGit(at: root) { $0.held(branch, at: path) }
        }
    }

    /// Git › Worktrees…: the branch popup with the first of the repository's other worktrees chosen, where each is
    /// opened, unlocked or removed from its row's menu (→).
    @objc func showWorktrees(_ sender: Any?) {
        guard let anchor = branchPopupAnchor, let folder = gitFolder else { return NSSound.beep() }
        branchPopup.focusWorktrees = true
        if branchPopup.isVisible { return branchPopup.reload() }
        branchPopup.show(for: self, directory: folder, snapshot: sidebar.git.snapshot, anchor: anchor)
    }

    /// Under the branch name at the top of the sidebar, or near the window's top left without it.
    private var branchPopupAnchor: NSRect? {
        guard let window else { return nil }
        var anchor = NSRect(x: window.frame.minX + 80, y: window.frame.maxY - 44, width: 1, height: 1)
        if isSidebarVisible {
            anchor = window.convertToScreen(sidebar.header.convert(sidebar.header.bounds, to: nil))
            anchor.origin.x += sidebar.headerInset - 4
        }
        return anchor
    }

    /// The branch popup for the repository at `root` (a Git Log's), searching for `query`.
    func showBranches(at root: String, query: String) {
        guard let anchor = branchPopupAnchor else { return }
        branchPopup.show(for: self, directory: root, snapshot: snapshot(of: root), anchor: anchor)
        branchPopup.query = query
    }

    /// GitActions for the repository at `root` (a Git Log's), with the branch popup's model read fresh.
    func withGit(at root: String, _ body: @escaping (GitActions) -> Void) {
        branchPopup.prepare(for: self, directory: root, snapshot: snapshot(of: root)) { [weak self] in
            guard let self else { return }
            body(GitActions(self.branchPopup))
        }
    }

    /// The sidebar's git state, when it is of the repository at `root`.
    private func snapshot(of root: String) -> GitSnapshot? {
        sidebar.git.snapshot.flatMap { canonicalPath($0.root) == canonicalPath(root) ? $0 : nil }
    }

    private func withGit(_ body: @escaping (GitActions) -> Void) {
        guard let folder = gitFolder else { return NSSound.beep() }
        branchPopup.prepare(for: self, directory: folder, snapshot: sidebar.git.snapshot) { [weak self] in
            guard let self else { return }
            body(GitActions(self.branchPopup))
        }
    }

    /// Update Project, Commit…, Push… and New Branch…, each from its key until its question or sheet is up, or it ends
    /// without one. Each reads first (Update Project fetches, Commit… reads what is staged, Push… its outgoing commits),
    /// and until a sheet is up the same key passes validateMenuItem again: that press does nothing, however quickly the
    /// first question is answered. Two different commands pressed together are held apart only where each asks
    /// (GitActions.sheetIsUp).
    private(set) var gitAsking: Set<Selector> = []

    private func withGitAsking(_ command: Selector, _ body: @escaping (GitActions) -> Void) {
        guard !gitAsking.contains(command) else { return }
        // Without git the read never calls back, so nothing would give the claim back.
        guard let folder = gitFolder, GitWriter.git != nil else { return NSSound.beep() }
        gitAsking.insert(command)
        final class Claim { var given = false }
        let claim = Claim()
        let settle: () -> Void = { [weak self] in
            guard !claim.given else { return } // once: a late call must not take a newer press's claim
            claim.given = true
            self?.gitAsking.remove(command)
        }
        // Never held for good, should a step not call back: a fetch or a read longer than this lets the key work again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: settle)
        branchPopup.prepare(for: self, directory: folder, snapshot: sidebar.git.snapshot) { [weak self] in
            guard let self else { return settle() }
            var actions = GitActions(self.branchPopup)
            actions.settle = settle
            body(actions)
        }
    }

    @objc func gitFetch(_ sender: Any?) { withGit { $0.fetch() } }
    @objc func gitUpdate(_ sender: Any?) { withGitAsking(#selector(gitUpdate(_:))) { $0.updateProject() } }
    @objc func gitCommit(_ sender: Any?) { withGitAsking(#selector(gitCommit(_:))) { $0.commit() } }
    @objc func gitPush(_ sender: Any?) { withGitAsking(#selector(gitPush(_:))) { $0.push() } }
    @objc func gitNewBranch(_ sender: Any?) { withGitAsking(#selector(gitNewBranch(_:))) { $0.askNewBranch(base: nil) } }
    @objc func showGitCommands(_ sender: Any?) { GitCommandsWindowController.shared.present() }

    /// ⌥⌘L: the commit history of the project's repository, in an editor tab.
    @objc func showGitLog(_ sender: Any?) {
        guard let folder = gitLogRoot else { return NSSound.beep() }
        openGitLog(root: folder)
    }

    /// The repository ⌥⌘L shows: the sidebar's, or that of a Git Log already open; nil outside one.
    private var gitLogRoot: String? { sidebar.git.snapshot?.root ?? editorArea.activeGitLog?.root ?? editorArea.gitLogs.first?.root }

    /// The Git Log of the repository containing `root`, in front; nil outside a repository.
    @discardableResult
    func openGitLog(root: String) -> GitLogPane? {
        let top = canonicalPath(ProjectRoot.find(from: root))
        guard FileManager.default.fileExists(atPath: (top as NSString).appendingPathComponent(".git")) else {
            NSSound.beep()
            return nil
        }
        return editorArea.openGitLog(root: top)
    }

    /// Opens the Git Log at one commit (from a line's blame, say): the pages down to it load at once, and
    /// a commit no branch or tag lists is shown alone.
    func showCommit(sha: String, root: String) {
        openGitLog(root: root)?.select(sha: sha)
    }

    /// Compare with Current, or Show Diff with Working Tree, for `branch` ("refs/heads/feat/x") of the
    /// work tree at `root`, in an editor tab.
    @discardableResult
    func openBranchComparison(root: String, branch: String, mode: BranchComparePane.Mode, current: String?) -> BranchComparePane {
        editorArea.openBranchComparison(root: root, branch: branch, mode: mode, current: current)
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        // ⌘1…⌘8 pick that tab; ⌘9 is always the last one, as in browsers.
        select(sender.tag == 9 ? groups.count - 1 : sender.tag - 1)
    }

    // Not selectNextTab:/selectPreviousTab:: NSWindow implements those (system tabs) and would swallow them.
    @objc func showNextTab(_ sender: Any?) { isEditorFocused ? editorArea.cycle(by: 1) : cycleTab(by: 1) }
    @objc func showPreviousTab(_ sender: Any?) { isEditorFocused ? editorArea.cycle(by: -1) : cycleTab(by: -1) }

    /// Edit › Forget This Suggestion (⇧⌘⌫): the suggestion showing in the terminal with the keyboard leaves the record.
    @objc func forgetSuggestion(_ sender: Any?) {
        if activeTab?.ghost.forget() != true { NSSound.beep() }
    }

    @objc func clearBuffer(_ sender: Any?) {
        if KeyboardShortcuts.shared.preset.clearsOnlyInTerminal && isEditorFocused { return }
        guard let tab = activeTab else { return }
        clear(tab)
    }

    /// Wipes a terminal's screen and scrollback locally; at a prompt, asks the shell to redraw it. The tab is the pane
    /// with the keyboard: a split tab's other panes are left as they are. A full-screen program (herdr, tmux, screen,
    /// vim, less: the alternate screen) draws its own screen, its panes and all, so wiping it here would blank every
    /// pane it shows until it drew them again: there ⌘K is the program's own Ctrl+L, which it gives the pane it has in
    /// front, and only that pane clears (its shell at a prompt; a program in it redraws).
    func clear(_ tab: TerminalTab) {
        if tab.view.getTerminal().isCurrentBufferAlternate { return tab.view.send(txt: "\u{0c}") }
        tab.view.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
        if !tab.status.running { tab.view.send(txt: "\u{0c}") }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeConfirmed || AppDelegate.shared.isTerminating { return true }
        let dirty = editorArea.dirtyDocuments
        if !dirty.isEmpty && !editorsConfirmed {
            let alert = saveAlert(dirty)
            alert.beginSheetModal(for: sender) { [weak self] response in
                guard let self else { return }
                switch response {
                case .alertFirstButtonReturn:
                    guard self.editorArea.saveAll() else { return self.opensWelcome = false }
                case .alertThirdButtonReturn:
                    break
                default:
                    self.opensWelcome = false
                    return
                }
                self.editorsConfirmed = true
                DispatchQueue.main.async { sender.performClose(nil) }
            }
            return false
        }
        editorsConfirmed = false
        let busy = busyTabs
        let kept = Self.keptList(tabs)
        guard !busy.isEmpty || !kept.isEmpty else { return true }
        let info = [busy.isEmpty ? "" : Self.stopText("Closing it stops", busy), kept].filter { !$0.isEmpty }.joined(separator: "\n\n")
        // A linked worktree's window (an agent's, most often) can take its worktree with it: a choice set apart, last.
        let worktree = project.flatMap { WorktreeWindow.repository(ofLinkedWorktree: $0) == nil ? nil : $0 }
        let answered: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.closeConfirmed = true
                sender.close()
            case .alertThirdButtonReturn:
                if let worktree { self.closeRemovingWorktree(worktree) }
            default:
                self.opensWelcome = false
            }
        }
        if worktree != nil {
            AlternativeAlert(title: "Close this window?", info: info, buttons: ["Close Window", "Cancel"], alternative: WorktreeRemoval.closeAndRemove,
                             note: WorktreeRemoval.closingInfo(branch: sidebar.git.snapshot?.branch)).begin(over: sender, completion: answered)
            return false
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close this window?"
        alert.informativeText = info
        alert.addButton(withTitle: "Close Window")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender, completionHandler: answered)
        return false
    }

    /// Close and Remove Worktree: when the worktree at `path` can go (WorktreeRemoval.verdict, with this window's tabs
    /// and agents left out, as they end with it), the window closes, the programs in it end, and then the worktree is
    /// removed. When it can't, says why; Close Window still closes and keeps it.
    private func closeRemovingWorktree(_ path: String) {
        withGit(at: path) { [weak self] actions in
            guard let self, let window = self.window, let model = actions.model,
                  let row = BranchPopupController.worktreeRow(at: path, in: model) else {
                self?.opensWelcome = false
                return NSSound.beep()
            }
            actions.removalVerdict(row, leaving: self) { verdict, _ in
                if let why = WorktreeRemoval.whyItStays(verdict) {
                    return GitPrompt.ask("“\(row.folder)” can’t be removed now", info: why, buttons: ["Close Window", "Cancel"], over: window) { choice in
                        guard choice == 0 else { return self.opensWelcome = false }
                        self.closeConfirmed = true
                        window.close()
                    }
                }
                // Ended here, not by the close (it finds them ended), to know when they are gone.
                let waiting = TerminalTab.terminate(self.tabs, finishLater: false)
                self.closeConfirmed = true
                window.close()
                TabHangup.finishLater(waiting) { GitActions.removeClosed(row.worktree, folder: row.folder, model: model) }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        hasClosed = true
        ticker?.invalidate()
        ticker = nil
        sidebar.stopWatching()
        _ = TerminalTab.terminate(tabs, finishLater: true)
        groups.removeAll()
        editorArea.closeAll()
        finder.close()
        onClose?(self, opensWelcome)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if !keyingForAgent { lastKey = Date() } // brought forward for an agent: not a window the user went to
        activityChanged()
        refreshVisibility()
        refresh()
        // Another window may have opened a project since: "No project open" lists it.
        if sidebar.showsNoProject { sidebar.noProject.show(recent: AppDelegate.shared.recentProjects) }
        sidebar.retryDenied() // back from System Settings, perhaps, with a folder allowed
        sidebar.scheduleSessionsReload() // agents in other terminals may have kept new ones
        if let view = activeTab?.view, window?.firstResponder !== view, !(window?.firstResponder is NSTextView), !terminalCollapsed {
            window?.makeFirstResponder(view)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        activityChanged()
        refreshVisibility()
    }
    func windowDidBecomeMain(_ notification: Notification) { activityChanged() }
    func windowDidResignMain(_ notification: Notification) {
        activityChanged()
        refreshVisibility()
    }

    func windowWillEnterFullScreen(_ notification: Notification) { isFullScreen = true; updateInsets() }
    func windowWillExitFullScreen(_ notification: Notification) { isFullScreen = false; updateInsets() }

    // MARK: TabBarViewDelegate

    /// Folded to its bar, a click chooses the tab there and the terminal stays folded: opening it on the press would
    /// move the bar (or, with a list, empty it) from under a drag or a double-click's second click. The keyboard opens it.
    func tabBar(_ bar: TabBarView, didSelect index: Int) { select(index, unfold: !terminalCollapsed) }

    func tabBar(_ bar: TabBarView, didClose index: Int) {
        guard let group = groups[safe: index] else { return }
        guard group.isSplit else { return requestClose(group.focused) }
        // The tab's × closes all its panes, asking once if that stops anything (or, as the window's last
        // tab with files unsaved, whether to save them: the window closes too).
        let busy = group.panes.filter { $0.closeNote != nil }
        let kept = Self.keptList(group.panes)
        if closesWindow(group.panes), !editorArea.dirtyDocuments.isEmpty {
            return askToSave(closing: group.panes, kept: kept) { [weak self] in group.panes.forEach { self?.remove($0, saveAsked: true) } }
        }
        guard !busy.isEmpty || !kept.isEmpty, let window else { return group.panes.forEach { remove($0) } }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close this tab and its \(group.panes.count) panes?"
        alert.informativeText = [busy.isEmpty ? "" : Self.stopText("Closing it stops", busy), kept].filter { !$0.isEmpty }.joined(separator: "\n\n")
        alert.addButton(withTitle: "Close Tab")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { group.panes.forEach { self?.remove($0) } }
        }
    }

    func tabBar(_ bar: TabBarView, didMove from: Int, to: Int) {
        guard groups.indices.contains(from), groups.indices.contains(to) else { return }
        let active = activeGroup
        let group = groups.remove(at: from)
        groups.insert(group, at: to)
        activeIndex = active.flatMap { a in groups.firstIndex { $0 === a } } ?? 0
        refresh()
    }

    func tabBar(_ bar: TabBarView, didRename index: Int, to title: String?) {
        groups[safe: index]?.focused.userTitle = title
        refresh()
    }

    func tabBarDidEndEditing(_ bar: TabBarView) {
        // After the field editor has fully let go (ending the edit may itself be inside a
        // makeFirstResponder call), give the keyboard back to the terminal.
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.activeTab?.view, !self.tabStrip.isEditing else { return }
            let window: NSWindow? = self.window
            if !self.terminalCollapsed {
                window?.makeFirstResponder(view)
                return
            }
            // Folded, no terminal shows to type into, and taking the keyboard would unfold it: the editor keeps it, or
            // takes it if the field left it with nobody.
            let nobody: Bool = window?.firstResponder == nil || window?.firstResponder === window
            if nobody, let text = self.editorArea.activeTextView { window?.makeFirstResponder(text) }
        }
    }

    func tabBarDidRequestNewTab(_ bar: TabBarView) { newTab(nil) }
    func tabBar(_ bar: TabBarView, didDoubleClick index: Int) {} // terminal tabs rename instead

    // MARK: TerminalTabDelegate

    func tabDidChange(_ tab: TerminalTab) {
        // Events (command end, bell) can land between ticks; post their notices straight away.
        if let notice = tab.status.takeNotice() { AppDelegate.shared.post(notice, tab: tab, in: self) }
        AppDelegate.shared.updateCopilotFolders() // a new folder for Copilot CLI to connect from
        refresh()
    }

    func tabDidExit(_ tab: TerminalTab) {
        // The shell exited by itself (`exit`, Ctrl-D): the tab goes away, like any terminal. As the window's
        // last, with files unsaved, it asks first; Cancel puts a fresh shell in its place.
        remove(tab)
    }
}
