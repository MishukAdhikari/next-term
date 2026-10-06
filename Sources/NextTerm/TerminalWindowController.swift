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

/// Between the editor and the terminal: both have the same background, so the line between them must
/// show (a hairline a few shades lighter), and it is easy to grab (see effectiveRect).
final class WorkSplitView: NSSplitView {
    static let line = NSColor(hex: 0x393B40)
    override var dividerColor: NSColor { Self.line }
    override var dividerThickness: CGFloat { 1 }
}

final class TerminalWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate, NSMenuItemValidation,
                                      TabBarViewDelegate, TerminalTabDelegate, ProjectSidebarDelegate, FindInFilesDelegate,
                                      EditorAreaDelegate {
    private(set) var tabs: [TerminalTab] = []
    private(set) var activeIndex = 0
    let tabBar = TabBarView(frame: .zero)
    let sidebar = ProjectSidebarView(frame: NSRect(x: 0, y: 0, width: ProjectSidebarView.defaultWidth, height: 600))
    private let splitView = ThemedSplitView()
    private let mainPane = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    /// [ open files ] over [ terminal tabs ], like an IDE. The editor part is hidden while no file is open.
    private let workSplit = WorkSplitView()
    let editorArea = EditorArea(frame: NSRect(x: 0, y: 0, width: 800, height: 360))
    private let terminalPane = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
    private let container = NSView()
    /// Unsaved files were dealt with (saved or discarded) for this close.
    private var editorsConfirmed = false
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
    private(set) lazy var finder: FindInFilesController = {
        let controller = FindInFilesController()
        controller.delegate = self
        return controller
    }()

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
        window.contentView = splitView
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
            container.leadingAnchor.constraint(equalTo: terminalPane.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: terminalPane.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: terminalPane.bottomAnchor),
        ])
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
        editorArea.isHidden = true
        applyLayout()
        setSidebarVisible(AppDelegate.shared.sidebarVisible)

        let ticker = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker

        addTab(directory: self.project ?? directory)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: tabs

    /// `select` false: the tab opens behind the current one (an agent opening tabs leaves you where you are).
    @discardableResult
    func addTab(directory: String?, select selectIt: Bool = true) -> TerminalTab {
        let tab = TerminalTab(directory: directory, fontSize: AppDelegate.shared.fontSize)
        tab.delegate = self
        // ⌘-click on "src/a.ts:42" in the output opens the editor there.
        tab.view.openFile = { [weak self] url, line, column in self?.openFile(url, line: line, column: column) }
        let view = tab.view
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])
        let insertAt = tabs.isEmpty ? 0 : activeIndex + 1 // next to the current tab
        tabs.insert(tab, at: insertAt)
        container.layoutSubtreeIfNeeded() // real size before the shell starts, so it draws once
        tab.start()
        AppDelegate.shared.projectsChanged()
        if selectIt || tabs.count == 1 {
            select(insertAt)
        } else {
            view.isHidden = true
            if insertAt <= activeIndex { activeIndex += 1 }
            refresh()
        }
        return tab
    }

    func select(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeIndex = index
        tabs[index].lastSelected = Date()
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

    /// Closes a tab without asking (callers have asked, or were told to force it).
    func remove(_ tab: TerminalTab) {
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
            select(max(0, index - 1)) // the left neighbour
        } else {
            // A background tab went away: keep the current one, and keep focus where it is.
            if index < activeIndex { activeIndex -= 1 }
            refresh()
        }
    }

    /// Tabs whose closing would stop a program or a job.
    var busyTabs: [TerminalTab] { tabs.filter { $0.closeWarning != nil } }

    /// "“vim notes.md” (suspended); “npm run dev” (running); and more in 2 other tabs." The same ending
    /// for every alert that stops tabs.
    static func stopList(_ busy: [TerminalTab]) -> String {
        let listed = busy.prefix(4).compactMap(\.closeWarning).joined(separator: "; ")
        let rest = busy.count - 4
        return listed + (rest > 0 ? "; and more in \(rest) other tab\(rest == 1 ? "" : "s")." : ".")
    }
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
            tab.pollAgentScreen()
            tab.status.tick(at: now)
            if let notice = tab.status.takeNotice() {
                AppDelegate.shared.post(notice, tab: tab, in: self)
            }
        }
        if tickCount % 4 == 0 { editorArea.checkDisk() } // agents edit the files you have open
        refresh()
    }

    func refresh() {
        let items = tabs.map { tab in
            TabBarItem(title: tab.title, truncation: tab.titleTruncation, state: tab.status.state, tooltip: tab.tooltip,
                       accessibilityStatus: tab.stateDescription)
        }
        tabBar.update(items: items, selectedIndex: activeIndex)
        announceBackgroundChanges()
        updateTitle()
        AppDelegate.shared.updateBadge()
        updateProjectRoot()
    }

    /// "Alertable.php — xCloud" while editing, "zsh — xCloud" in the terminal.
    func updateTitle() {
        let name = project.map { ($0 as NSString).lastPathComponent }
        let focus = isEditorFocused ? editorArea.activeEditor?.document.name : activeTab?.title
        window?.title = [focus, name, "Next Term"].compactMap { $0 }.joined(separator: " — ")
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
        AppDelegate.shared.projectsChanged()
    }

    // MARK: find and replace in files

    /// The folder searches cover: the project, else what the sidebar shows, else the tab's git root.
    var searchRoot: String {
        project ?? sidebar.root?.path ?? activeTab.map { ProjectRoot.find(from: $0.directory) } ?? NSHomeDirectory()
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
        if isEditorFocused, let view = editorArea.activeEditor?.textView {
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
        guard let path = editorArea.activeEditor?.document.path else { return nil }
        let root = canonicalPath(searchRoot)
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
    }

    func findInFiles(_ controller: FindInFilesController, open url: URL, line: Int) {
        openFile(url, line: line)
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
        if item.action == #selector(saveDocument(_:)) { return editorArea.activeEditor != nil }
        if item.action == #selector(saveAllDocuments(_:)) { return !editorArea.dirtyDocuments.isEmpty }
        if item.action == #selector(goToLine(_:)) { return editorArea.activeEditor != nil }
        if item.action == #selector(showChanges(_:)) { return editorArea.activeEditor != nil || sidebar.selection.contains { !$0.isFolder } }
        if item.action == #selector(sendToAgent(_:)) { return agentTab != nil && (editorArea.activeEditor != nil || !sidebar.selection.isEmpty) }
        if item.action == #selector(toggleEditorFocus(_:)) {
            item.title = isEditorFocused ? "Focus Terminal" : "Focus Editor"
            return editorArea.activeEditor != nil
        }
        if item.action == #selector(toggleProjectSidebar(_:)) {
            item.title = isSidebarVisible ? "Hide Project Sidebar" : "Show Project Sidebar"
        }
        return true
    }

    // MARK: layout: where the sidebar and the terminal go

    private var sidebarOnRight: Bool { AppDelegate.shared.sidebarSide == .right }
    private var terminalPosition: AppDelegate.TerminalPosition { AppDelegate.shared.terminalPosition }
    /// The terminal comes before the editor (left of it, or above it).
    private var terminalFirst: Bool { terminalPosition == .left || terminalPosition == .top }

    /// Puts the sidebar and the terminal where the View menu says, keeping their sizes.
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

        workSplit.isVertical = terminalPosition == .left || terminalPosition == .right
        let work: [NSView] = terminalFirst ? [terminalPane, editorArea] : [editorArea, terminalPane]
        if workSplit.arrangedSubviews != work {
            work.forEach(workSplit.removeArrangedSubview)
            work.forEach(workSplit.addArrangedSubview)
        }
        // Window resizes go to the editor; the terminal keeps its size.
        workSplit.setHoldingPriority(.init(250), forSubviewAt: terminalFirst ? 1 : 0)
        workSplit.setHoldingPriority(.init(260), forSubviewAt: terminalFirst ? 0 : 1)
        splitView.adjustSubviews()
        workSplit.adjustSubviews()
        if isSidebarVisible { placeSidebarDivider(width: sidebarWidth) }
        placeWorkDivider()
        updateInsets()
    }

    private func placeSidebarDivider(width: CGFloat) {
        splitView.layoutSubtreeIfNeeded()
        let position = sidebarOnRight ? splitView.bounds.width - width - splitView.dividerThickness : width
        splitView.setPosition(position, ofDividerAt: 0)
    }

    /// The editor gets its remembered share of the work area, on whichever side it is.
    private func placeWorkDivider() {
        guard !editorArea.isHidden else { return }
        workSplit.layoutSubtreeIfNeeded()
        let length = workSplit.isVertical ? workSplit.bounds.width : workSplit.bounds.height
        let editor = round(length * AppDelegate.shared.editorFraction)
        workSplit.setPosition(terminalFirst ? length - editor - workSplit.dividerThickness : editor, ofDividerAt: 0)
    }

    func setSidebarVisible(_ visible: Bool) {
        sidebar.isHidden = !visible
        if visible {
            splitView.adjustSubviews()
            placeSidebarDivider(width: AppDelegate.shared.sidebarWidth)
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

    /// The traffic lights sit over whichever pane is top-left; full screen has none. Tab bars along the
    /// top of the window drag it, like a title bar; one lower down does not.
    private func updateInsets() {
        let lights: CGFloat = isFullScreen ? 8 : 78
        let sidebarTopLeft = isSidebarVisible && !sidebarOnRight
        sidebar.headerInset = sidebarTopLeft && !isFullScreen ? 70 : 8
        let corner = sidebarTopLeft ? 8 : lights
        let editorShown = !editorArea.isHidden
        // Which bar starts at the work area's top-left corner, and which bars run along its top edge.
        let terminalAtCorner = !editorShown || terminalFirst
        let terminalAtTop = !editorShown || terminalPosition != .bottom
        let editorAtTop = terminalPosition != .top
        tabBar.leadingInset = terminalAtCorner ? corner : 8
        tabBar.dragsWindow = terminalAtTop
        editorArea.tabBar.leadingInset = terminalAtCorner ? 8 : corner
        editorArea.tabBar.dragsWindow = editorAtTop
    }

    /// The smallest a pane may get along the work split: room for its tabs and a few lines.
    private var workMinimum: CGFloat { workSplit.isVertical ? 240 : TabBarView.height + 60 }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        if splitView === workSplit { return workMinimum }
        // The sidebar is 160–640 wide, on either side.
        return sidebarOnRight ? max(320, splitView.bounds.width - 640) : 160
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        if splitView === workSplit {
            return (workSplit.isVertical ? splitView.bounds.width : splitView.bounds.height) - workMinimum
        }
        return sidebarOnRight ? splitView.bounds.width - 160 : min(640, splitView.bounds.width - 320)
    }

    /// A one-pixel divider is hard to hit: grab it anywhere within 3 points either side.
    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
                   ofDividerAt dividerIndex: Int) -> NSRect {
        splitView.isVertical ? drawnRect.insetBy(dx: -3, dy: 0) : drawnRect.insetBy(dx: 0, dy: -3)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        if (notification.object as? NSSplitView) === workSplit {
            // Remember the split the user dragged to (not the one a window resize produces).
            let length = workSplit.isVertical ? workSplit.bounds.width : workSplit.bounds.height
            if !editorArea.isHidden, length > 200, NSApp.currentEvent?.type == .leftMouseDragged {
                let editor = workSplit.isVertical ? editorArea.frame.width : editorArea.frame.height
                AppDelegate.shared.editorFraction = editor / length
            }
            return
        }
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
        openFile(url)
    }

    func sidebar(_ sidebar: ProjectSidebarView, didMove from: String, to: String) {
        editorArea.itemMoved(from: from, to: to)
    }

    // MARK: editor

    /// Opens a file in the editor, at a line if given. What the editor cannot show (images, binaries,
    /// huge files) opens in its app instead, safely.
    func openFile(_ url: URL, line: Int? = nil, column: Int = 1) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return SafeOpen.open(url, from: window)
        }
        if editorArea.open(url, line: line, column: column) != .opened { SafeOpen.open(url, from: window) }
    }

    var isEditorFocused: Bool {
        guard !editorArea.isHidden, let view = window?.firstResponder as? NSView else { return false }
        return view.isDescendant(of: editorArea)
    }

    func editorAreaDidChangeDocuments(_ area: EditorArea) {
        setEditorVisible(!area.isEmpty)
    }

    // MARK: Claude Code sees the selection

    private var selectionShare: DispatchWorkItem?

    func editorAreaSelectionChanged(_ area: EditorArea) {
        guard ClaudeIDEServer.shared.isRunning || GeminiIDEServer.shared.isRunning else { return }
        selectionShare?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.shareSelectionWithClaude() }
        selectionShare = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work) // while dragging, once it settles
    }

    /// Tells the `claude` sessions in this window's tabs what the editor shows: the selected lines, or the
    /// file the caret is in, or nothing (no file open).
    func shareSelectionWithClaude(only clients: Set<ClaudeIDEServer.ClientID>? = nil) {
        if clients == nil, GeminiIDEServer.shared.isRunning { GeminiIDEServer.shared.setContext(openFiles: openFilesForGemini()) }
        let recipients = clients ?? AppDelegate.shared.claudeClients(in: self)
        guard !recipients.isEmpty else { return }
        ClaudeIDEServer.shared.notify("selection_changed", currentSelectionForClaude(), to: recipients)
    }

    /// Gemini CLI and Qwen Code: up to 10 files by recency, the active one first with its caret and
    /// selection, 1-based. Secret-holding files (.env) are left out.
    func openFilesForGemini() -> [[String: Any]] {
        let active = editorArea.activeEditor
        let documents = editorArea.documents.filter { !ClaudeIDEServer.isSensitive($0.path) }
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
        return ClaudeIDEServer.selectionParams(path: editor.document.path, text: selected,
                                               start: position(range.location), end: position(NSMaxRange(range)))
    }

    private func setEditorVisible(_ visible: Bool) {
        guard editorArea.isHidden == visible else { return }
        editorArea.isHidden = !visible
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
    var agentTab: TerminalTab? {
        if let tab = activeTab, tab.status.running, tab.status.kind == .agent { return tab }
        return tabs.filter { $0.status.running && $0.status.kind == .agent }.max { $0.lastSelected < $1.lastSelected }
    }

    /// ⌥⌘K: the editor's selection (or its file), or the files and folders selected in the sidebar.
    @objc func sendToAgent(_ sender: Any?) {
        if isEditorFocused {
            sendEditorSelection()
        } else if let window, window.firstResponder === sidebar.outline, !sidebar.selection.isEmpty {
            send(sidebar.selection.map { ContextItem(path: $0.url.path, isFolder: $0.isFolder) })
        } else {
            NSSound.beep()
        }
    }

    /// The editor's selection as lines of its file (or the whole file when nothing is selected).
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
        }
    }

    func sidebar(_ sidebar: ProjectSidebarView, sendToAgent urls: [(url: URL, isFolder: Bool)]) {
        send(urls.map { ContextItem(path: $0.url.path, isFolder: $0.isFolder) })
    }

    /// Types references to `items` into the agent's prompt, in its own syntax, relative to its folder.
    /// Never presses Enter: you add the instruction.
    func send(_ items: [ContextItem]) {
        guard let tab = agentTab, let window else {
            let alert = NSAlert()
            alert.messageText = "No agent is running in this window"
            alert.informativeText = "Start one in a tab (claude, codex, gemini, junie…), then send again."
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
        if let index = tabs.firstIndex(where: { $0 === tab }) { select(index) }
        defer { window.makeFirstResponder(tab.view) }
        // Claude connected to Next Term: the mentions go into its prompt directly, as from VS Code.
        if let client = AppDelegate.shared.claudeClient(for: tab), items.allSatisfy({ !$0.isFolder && $0.code == nil }) {
            for item in items {
                var params: [String: Any] = ["filePath": canonicalPath(item.path)]
                if let lines = item.lines {
                    params["lineStart"] = lines.lowerBound - 1
                    params["lineEnd"] = lines.upperBound - 1
                }
                ClaudeIDEServer.shared.notify("at_mentioned", params, to: [client])
            }
            return
        }
        let dialect = AgentDialect.forProgram(tab.status.program)
        let segments = AgentPrompt.segments(instruction: "", items: relative, dialect: dialect)
        for segment in segments { tab.view.typeIn(segment) }
    }

    /// For the self-test: what `send` would type into `tab`.
    func agentText(_ items: [ContextItem], for program: String) -> String {
        AgentPrompt.segments(instruction: "", items: items, dialect: AgentDialect.forProgram(program)).joined(separator: "\n")
    }

    // MARK: diffs

    /// ⌘D: the changes of the file being edited, or the file selected in the sidebar, side by side.
    @objc func showChanges(_ sender: Any?) {
        if let editor = editorArea.activeEditor, isEditorFocused || window?.firstResponder !== sidebar.outline {
            return showChanges(of: editor.document.url)
        }
        if let file = sidebar.selection.first(where: { !$0.isFolder }) { return showChanges(of: file.url) }
        NSSound.beep()
    }

    func sidebar(_ sidebar: ProjectSidebarView, showChanges url: URL) { showChanges(of: url) }

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
        editorArea.openDiff(root: root, path: String(path.dropFirst(root.count + 1)), base: base)
    }

    @objc func saveDocument(_ sender: Any?) { editorArea.saveActive() }
    @objc func saveAllDocuments(_ sender: Any?) { editorArea.saveAll() }

    /// ⌃`: between the editor and the terminal, as in VS Code.
    @objc func toggleEditorFocus(_ sender: Any?) {
        if isEditorFocused {
            if let view = activeTab?.view { window?.makeFirstResponder(view) }
        } else if let editor = editorArea.activeEditor {
            window?.makeFirstResponder(editor.textView)
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

    func sidebar(_ sidebar: ProjectSidebarView, openTabIn directory: String) {
        addTab(directory: directory)
    }

    func applyFontSize(_ size: CGFloat) {
        for tab in tabs { tab.view.font = Theme.terminalFont(size: size) }
        editorArea.applyFont()
    }

    // MARK: menu actions (reached through the responder chain)

    /// In a project window, new tabs start in the project; otherwise in the current tab's folder.
    @objc func newTab(_ sender: Any?) {
        addTab(directory: project ?? activeTab?.currentDirectory())
    }

    /// ⌘W closes what has the keyboard: the file being edited, or the terminal tab.
    @objc func closeTab(_ sender: Any?) {
        if isEditorFocused { return editorArea.closeActive() }
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
    @objc func showNextTab(_ sender: Any?) { isEditorFocused ? editorArea.cycle(by: 1) : cycleTab(by: 1) }
    @objc func showPreviousTab(_ sender: Any?) { isEditorFocused ? editorArea.cycle(by: -1) : cycleTab(by: -1) }

    @objc func clearBuffer(_ sender: Any?) {
        guard let tab = activeTab else { return }
        // Wipe screen and scrollback locally; at a prompt, ask the shell to redraw it.
        tab.view.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
        if !tab.status.running { tab.view.send(txt: "\u{0c}") }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeConfirmed || AppDelegate.shared.isTerminating { return true }
        let dirty = editorArea.dirtyDocuments
        if !dirty.isEmpty && !editorsConfirmed {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = dirty.count == 1 ? "Save changes to “\(dirty[0].name)” before closing?"
                : "Save changes to \(dirty.count) files before closing?"
            alert.informativeText = "Your changes are lost if you don’t save them."
            alert.addButton(withTitle: dirty.count == 1 ? "Save" : "Save All")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don’t Save").keyEquivalent = "d"
            alert.beginSheetModal(for: sender) { [weak self] response in
                guard let self else { return }
                switch response {
                case .alertFirstButtonReturn:
                    guard self.editorArea.saveAll() else { return self.closingProject = false }
                case .alertThirdButtonReturn:
                    break
                default:
                    self.closingProject = false
                    return
                }
                self.editorsConfirmed = true
                DispatchQueue.main.async { sender.performClose(nil) }
            }
            return false
        }
        editorsConfirmed = false
        let busy = busyTabs
        guard !busy.isEmpty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close this window?"
        alert.informativeText = "Closing it stops " + Self.stopList(busy)
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
        editorArea.closeAll()
        finder.close()
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
