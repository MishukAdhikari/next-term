import AppKit
import NextTermCore

/// Window that handles Ctrl-Tab / Ctrl-Shift-Tab before the terminal sees it.
final class TerminalWindow: NSWindow {
    var onControlTab: ((_ backwards: Bool) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 48 /* Tab */,
           event.modifierFlags.intersection([.command, .option, .control]) == .control {
            onControlTab?(event.modifierFlags.contains(.shift))
            return
        }
        super.sendEvent(event)
    }
}

/// Split view with a quiet one-pixel divider in the theme's colour.
final class ThemedSplitView: NSSplitView {
    override var dividerColor: NSColor { Theme.background }
    override var dividerThickness: CGFloat { 1 }
}

final class TerminalWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate, NSMenuItemValidation,
                                      TabBarViewDelegate, TerminalTabDelegate, ProjectSidebarDelegate {
    private(set) var tabs: [TerminalTab] = []
    private(set) var activeIndex = 0
    let tabBar = TabBarView(frame: .zero)
    let sidebar = ProjectSidebarView(frame: NSRect(x: 0, y: 0, width: ProjectSidebarView.defaultWidth, height: 600))
    private let splitView = ThemedSplitView()
    private let mainPane = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    private let container = NSView()
    private var isFullScreen = false
    /// Last state announced to VoiceOver per tab, so each change is announced once.
    private var announcedStates: [UUID: TabState] = [:]
    private var projectKey: String?
    private var ticker: Timer?
    private var tickCount = 0
    private var closeConfirmed = false
    /// Called when the window closes; the flag says it was a Close Project.
    var onClose: ((TerminalWindowController, _ closedProject: Bool) -> Void)?
    /// The project this window is for: the sidebar stays on it and new tabs open in it by default
    /// (you can still `cd` anywhere). nil: a plain terminal window whose sidebar follows the active tab.
    private(set) var project: String?
    private var closingProject = false

    var activeTab: TerminalTab? { tabs[safe: activeIndex] }

    init(directory: String?, project: String? = nil) {
        self.project = project.map(canonicalPath)
        let window = TerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Next Term"
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

        // [ Project sidebar | tab bar over terminals ], both reaching up into the title bar.
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(mainPane)
        splitView.setHoldingPriority(.init(260), forSubviewAt: 0) // window resizes go to the terminal
        splitView.setHoldingPriority(.init(250), forSubviewAt: 1)
        window.contentView = splitView
        sidebar.delegate = self

        tabBar.delegate = self
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        mainPane.addSubview(container)
        mainPane.addSubview(tabBar)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: mainPane.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: mainPane.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: mainPane.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: mainPane.bottomAnchor),
        ])
        setSidebarVisible(AppDelegate.shared.sidebarVisible)

        let ticker = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker

        addTab(directory: self.project ?? directory)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: tabs

    @discardableResult
    func addTab(directory: String?) -> TerminalTab {
        let tab = TerminalTab(directory: directory, fontSize: AppDelegate.shared.fontSize)
        tab.delegate = self
        let view = tab.view
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])
        let insertAt = tabs.isEmpty ? 0 : activeIndex + 1 // next to the current tab, like PhpStorm
        tabs.insert(tab, at: insertAt)
        container.layoutSubtreeIfNeeded() // real size before the shell starts, so it draws once
        tab.start()
        select(insertAt)
        return tab
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeIndex = index
        for (i, tab) in tabs.enumerated() { tab.view.isHidden = i != index }
        window?.makeFirstResponder(tabs[index].view)
        refreshVisibility()
        refresh()
    }

    func cycleTab(by delta: Int) {
        guard !tabs.isEmpty else { return }
        select((activeIndex + delta + tabs.count) % tabs.count)
    }

    /// Closes a tab, asking first if closing it would stop something: a running program, or a job
    /// left suspended (Ctrl-Z) or in the background.
    func requestClose(_ tab: TerminalTab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        guard let warning = tab.closeWarning, let window else {
            remove(tab)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close “\(tab.title)”?"
        alert.informativeText = "Closing the tab stops \(warning)."
        alert.addButton(withTitle: "Close Tab")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.remove(tab) }
        }
    }

    private func remove(_ tab: TerminalTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        // A rename in progress refers to tabs by position: finish it while positions still hold.
        if window?.firstResponder is NSTextView, tabBar.isEditing { window?.makeFirstResponder(nil) }
        tab.terminate()
        tab.view.removeFromSuperview()
        tabs.remove(at: index)
        if tabs.isEmpty {
            closeConfirmed = true
            window?.close()
            return
        }
        if index == activeIndex {
            select(max(0, index - 1)) // the left neighbour, like PhpStorm
        } else {
            // A background tab went away: keep the current one, and keep focus where it is.
            if index < activeIndex { activeIndex -= 1 }
            refresh()
        }
    }

    /// Tabs whose closing would stop a program or a job.
    var busyTabs: [TerminalTab] { tabs.filter { $0.closeWarning != nil } }
    var unseenTabCount: Int { tabs.filter { $0.status.unseen != nil }.count }

    // MARK: status

    /// The user can see the active tab only while this window is key in the active app.
    private var userCanSeeActiveTab: Bool {
        guard let window else { return false }
        return NSApp.isActive && window.isKeyWindow && !window.isMiniaturized
    }

    func refreshVisibility() {
        let visible = userCanSeeActiveTab
        for (i, tab) in tabs.enumerated() {
            let isVisible = visible && i == activeIndex
            tab.status.setVisible(isVisible)
            tab.view.beepAllowed = isVisible
        }
    }

    private func tick() {
        tickCount += 1
        let now = TerminalTab.now
        refreshVisibility()
        for tab in tabs {
            if tickCount % 2 == 0 { tab.pollForeground() } // every 0.5 s
            tab.status.tick(at: now)
            if let notice = tab.status.takeNotice() {
                AppDelegate.shared.post(notice, tab: tab, in: self)
            }
        }
        refresh()
    }

    func refresh() {
        let items = tabs.map { tab in
            TabBarItem(title: tab.title, state: tab.status.state, tooltip: tab.tooltip,
                       accessibilityStatus: tab.stateDescription)
        }
        tabBar.update(items: items, selectedIndex: activeIndex)
        announceBackgroundChanges()
        let name = project.map { ($0 as NSString).lastPathComponent }
        window?.title = [activeTab?.title, name, "Next Term"].compactMap { $0 }.joined(separator: " — ")
        AppDelegate.shared.updateBadge()
        updateProjectRoot()
    }

    /// Tells VoiceOver users when a background tab finishes, fails or asks for attention: the dots are
    /// visual, so without this they would never know.
    private func announceBackgroundChanges() {
        for (i, tab) in tabs.enumerated() {
            let state = tab.status.state
            defer { announcedStates[tab.id] = state }
            guard i != activeIndex, announcedStates[tab.id] != state, [.done, .failed, .attention].contains(state) else { continue }
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

    /// A project window's tree stays on its project. Otherwise it follows the active tab: its git work
    /// tree, or its folder when outside one.
    private func updateProjectRoot() {
        guard isSidebarVisible else { return }
        if let project {
            guard projectKey != project else { return }
            projectKey = project
            sidebar.setRoot(project)
            return
        }
        guard let tab = activeTab else { return }
        let key = tab.id.uuidString + "\u{0}" + tab.directory
        guard key != projectKey else { return }
        projectKey = key
        sidebar.setRoot(ProjectRoot.find(from: tab.directory))
    }

    // MARK: projects

    /// A window nobody has used yet: no project, one tab, nothing run in it.
    var isPristine: Bool {
        guard project == nil, tabs.count == 1, let tab = tabs.first else { return false }
        return tab.status.command.isEmpty && !tab.status.running && tab.closeWarning == nil
    }

    /// Turns this window into `path`'s project: a fresh tab in the project, the old tabs closed.
    /// Callers confirm first if the old tabs are busy.
    func adoptProject(_ path: String) {
        let old = tabs
        project = canonicalPath(path)
        projectKey = nil
        addTab(directory: project)
        for tab in old { remove(tab) }
        refresh()
    }

    /// Close Project: closes the window (asking first if something is running in it).
    @objc func closeProject(_ sender: Any?) {
        guard project != nil, let window else { return NSSound.beep() }
        closingProject = true
        window.performClose(nil)
        if window.isVisible && window.attachedSheet == nil { closingProject = false } // close was refused
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(closeProject(_:)) { return project != nil }
        return true
    }

    func setSidebarVisible(_ visible: Bool) {
        sidebar.isHidden = !visible
        if visible {
            splitView.adjustSubviews()
            splitView.setPosition(AppDelegate.shared.sidebarWidth, ofDividerAt: 0)
            projectKey = nil
            updateProjectRoot()
        } else {
            splitView.adjustSubviews()
        }
        updateInsets()
    }

    // Not toggleSidebar:: NSWindow responds to it and would swallow it.
    @objc func toggleProjectSidebar(_ sender: Any?) {
        let visible = !isSidebarVisible
        AppDelegate.shared.sidebarVisible = visible
        setSidebarVisible(visible)
    }

    /// Traffic lights sit over whichever pane is leftmost; full screen has none.
    private func updateInsets() {
        let lights: CGFloat = isFullScreen ? 8 : 78
        sidebar.headerInset = isFullScreen ? 8 : 70
        tabBar.leadingInset = isSidebarVisible ? 8 : lights
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        160
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        min(640, splitView.bounds.width - 320)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        if isSidebarVisible, sidebar.frame.width >= 160 { AppDelegate.shared.sidebarWidth = sidebar.frame.width }
    }

    func sidebar(_ sidebar: ProjectSidebarView, insert text: String) {
        guard let tab = activeTab else { return }
        tab.view.typeIn(text)
        window?.makeFirstResponder(tab.view)
    }

    func sidebar(_ sidebar: ProjectSidebarView, openProject directory: String) {
        AppDelegate.shared.openProject(at: URL(fileURLWithPath: directory), from: self)
    }

    func sidebar(_ sidebar: ProjectSidebarView, openFile url: URL) {
        SafeOpen.open(url, from: window)
    }

    func sidebar(_ sidebar: ProjectSidebarView, openTabIn directory: String) {
        addTab(directory: directory)
    }

    func applyFontSize(_ size: CGFloat) {
        for tab in tabs { tab.view.font = Theme.terminalFont(size: size) }
    }

    // MARK: menu actions (reached through the responder chain)

    /// In a project window, new tabs start in the project; otherwise in the current tab's folder.
    @objc func newTab(_ sender: Any?) {
        addTab(directory: project ?? activeTab?.currentDirectory())
    }

    @objc func closeTab(_ sender: Any?) {
        if let tab = activeTab { requestClose(tab) }
    }

    @objc func renameTab(_ sender: Any?) {
        tabBar.beginRename(at: activeIndex)
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        // ⌘1…⌘8 pick that tab; ⌘9 is always the last one, as in browsers.
        select(sender.tag == 9 ? tabs.count - 1 : sender.tag - 1)
    }

    // Not selectNextTab:/selectPreviousTab:: NSWindow implements those (system tabs) and would swallow them.
    @objc func showNextTab(_ sender: Any?) { cycleTab(by: 1) }
    @objc func showPreviousTab(_ sender: Any?) { cycleTab(by: -1) }

    @objc func clearBuffer(_ sender: Any?) {
        guard let tab = activeTab else { return }
        // Wipe screen and scrollback locally; at a prompt, ask the shell to redraw it.
        tab.view.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
        if !tab.status.running { tab.view.send(txt: "\u{0c}") }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeConfirmed || AppDelegate.shared.isTerminating { return true }
        let busy = busyTabs
        guard !busy.isEmpty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close this window?"
        alert.informativeText = "Closing it stops " + busy.prefix(4).compactMap(\.closeWarning).joined(separator: "; ")
            + (busy.count > 4 ? ", and more in \(busy.count - 4) other tabs." : ".")
        alert.addButton(withTitle: "Close Window")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else {
                self.closingProject = false
                return
            }
            self.closeConfirmed = true
            sender.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        ticker?.invalidate()
        ticker = nil
        for tab in tabs { tab.terminate() }
        tabs.removeAll()
        onClose?(self, closingProject)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshVisibility()
        refresh()
        if let view = activeTab?.view, window?.firstResponder !== view, !(window?.firstResponder is NSTextView) {
            window?.makeFirstResponder(view)
        }
    }

    func windowDidResignKey(_ notification: Notification) { refreshVisibility() }

    func windowWillEnterFullScreen(_ notification: Notification) { isFullScreen = true; updateInsets() }
    func windowWillExitFullScreen(_ notification: Notification) { isFullScreen = false; updateInsets() }

    // MARK: TabBarViewDelegate

    func tabBar(_ bar: TabBarView, didSelect index: Int) { select(index) }

    func tabBar(_ bar: TabBarView, didClose index: Int) {
        if let tab = tabs[safe: index] { requestClose(tab) }
    }

    func tabBar(_ bar: TabBarView, didMove from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to) else { return }
        let active = activeTab
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        activeIndex = active.flatMap { a in tabs.firstIndex { $0 === a } } ?? 0
        refresh()
    }

    func tabBar(_ bar: TabBarView, didRename index: Int, to title: String?) {
        tabs[safe: index]?.userTitle = title
        refresh()
    }

    func tabBarDidEndEditing(_ bar: TabBarView) {
        // After the field editor has fully let go (ending the edit may itself be inside a
        // makeFirstResponder call), give the keyboard back to the terminal.
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.activeTab?.view, !self.tabBar.isEditing else { return }
            self.window?.makeFirstResponder(view)
        }
    }

    func tabBarDidRequestNewTab(_ bar: TabBarView) { newTab(nil) }

    // MARK: TerminalTabDelegate

    func tabDidChange(_ tab: TerminalTab) {
        // Events (command end, bell) can land between ticks; post their notices straight away.
        if let notice = tab.status.takeNotice() { AppDelegate.shared.post(notice, tab: tab, in: self) }
        refresh()
    }

    func tabDidExit(_ tab: TerminalTab) {
        // The shell exited by itself (`exit`, Ctrl-D): the tab goes away, like any terminal.
        remove(tab)
    }
}
