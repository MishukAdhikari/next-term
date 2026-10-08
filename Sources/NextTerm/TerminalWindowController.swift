import AppKit
import NextTermCore

/// Window that handles Ctrl-Tab / Ctrl-Shift-Tab before the terminal sees it.
final class TerminalWindow: NSWindow {
    var onControlTab: ((_ backwards: Bool) -> Void)?
    /// Whatever took the keyboard (a click in a pane, a move between panes).
    var onFirstResponderChange: ((NSResponder?) -> Void)?

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let made = super.makeFirstResponder(responder)
        if made { onFirstResponderChange?(firstResponder) }
        return made
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 48 /* Tab */,
           event.modifierFlags.intersection([.command, .option, .control]) == .control {
            onControlTab?(event.modifierFlags.contains(.shift))
            return
        }
        // A key pressed in a terminal: you are at that tab yourself (SwiftTerm's keyDown cannot be overridden).
        if event.type == .keyDown, let terminal = firstResponder as? NextTermView { terminal.onKeyboard?() }
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
    /// The tabs in the tab bar: each one terminal, or several split side by side.
    private(set) var groups: [PaneGroup] = []
    /// Every terminal in the window, tab by tab, pane by pane.
    var tabs: [TerminalTab] { groups.flatMap(\.panes) }
    /// The tab bar's selected tab (an index into `groups`).
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
    /// Called when the window closes; the flag says the Welcome window follows if no other window is left
    /// (Close Project, or the last tab closed).
    var onClose: ((TerminalWindowController, _ welcome: Bool) -> Void)?
    /// The project this window is for: the sidebar stays on it and new tabs open in it by default
    /// (you can still `cd` anywhere). nil: a plain terminal window whose sidebar follows the active tab.
    private(set) var project: String?
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
        window.onFirstResponderChange = { [weak self] responder in
            guard let self, let view = responder as? NextTermView, let tab = self.tabs.first(where: { $0.view === view }) else { return }
            if self.terminalRailed { self.expandTerminal() } // typing into a terminal behind the rail: it opens
            self.paneFocused(tab)
        }

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
            containerTrailing,
            container.bottomAnchor.constraint(equalTo: terminalPane.bottomAnchor),
        ])
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
        sidebar.onHeadChange = { [weak self] in self?.editorArea.headMoved() }
        // The collapse button's tooltip names ⌘J, or the key Settings gives it instead.
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutsChanged), name: KeyboardShortcuts.changed, object: nil)
        applyLayout() // the editor area starts hidden: nothing is open
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
        insert(makeTab(directory: directory), select: selectIt)
    }

    /// A tab on a server: ssh in its pty, to a shell, tmux session or herdr there.
    /// `atEnd`: after the last tab (restoring keeps the saved order), not next to the current one.
    @discardableResult
    func addRemoteTab(_ remote: RemoteTab, select selectIt: Bool = true, atEnd: Bool = false) -> TerminalTab {
        insert(makeTab(directory: nil, remote: remote), select: selectIt, atEnd: atEnd)
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
            select(insertAt)
        } else {
            view.isHidden = true
            if insertAt <= activeIndex { activeIndex += 1 }
            refresh()
        }
        return tab
    }

    private func makeTab(directory: String?, remote: RemoteTab? = nil) -> TerminalTab {
        let tab = TerminalTab(directory: directory, fontSize: AppDelegate.shared.fontSize, remote: remote)
        tab.delegate = self
        // ⌘-click on "src/a.ts:42" in the output opens the editor there.
        tab.view.openFile = { [weak self] url, line, column in self?.openFile(url, line: line, column: column) }
        return tab
    }

    /// Brings a terminal to the front: its tab selected, its pane focused (and un-zoomed if hidden).
    func show(_ tab: TerminalTab) {
        guard let index = groups.firstIndex(where: { $0.contains(tab) }) else { return }
        let group = groups[index]
        if let zoomed = group.zoomed, zoomed !== tab {
            group.zoomed = nil
            group.layout()
        }
        group.focused = tab
        group.updateDimming()
        select(index)
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
    func split(vertical: Bool, from: TerminalTab? = nil, directory: String? = nil, focus: Bool = true) -> TerminalTab? {
        guard let from = from ?? activeTab, let group = group(of: from) else { return nil }
        // Beside a remote tab, another one on its host, in its folder (unless a folder here was asked for).
        let new = directory == nil && from.remote != nil
            ? makeTab(directory: nil, remote: from.remote!.sibling(directory: from.directory))
            : makeTab(directory: directory ?? from.currentDirectory())
        group.split(from, with: new, vertical: vertical)
        if !focus { group.focused = from }
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

    /// `unfold` false: the tab comes forward without opening a terminal folded to its rail (the tab in
    /// front closed by itself), and the keyboard stays where it is.
    func select(_ index: Int, unfold: Bool = true) {
        guard groups.indices.contains(index) else { return }
        activeIndex = index
        let group = groups[index]
        group.focused.lastSelected = Date()
        for (i, other) in groups.enumerated() { other.view.isHidden = i != index }
        // A terminal taking the keyboard opens the rail (see onFirstResponderChange).
        if unfold || !terminalRailed { window?.makeFirstResponder(group.focused.view) }
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
            alert.addButton(withTitle: "Close Tab")
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
        guard !saveAsked, let warning = tab.closeWarning, let window else {
            remove(tab, saveAsked: saveAsked)
            return
        }
        let isPane = group(of: tab)?.isSplit == true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close “\(tab.title)”?"
        alert.informativeText = "Closing the \(isPane ? "pane" : "tab") stops \(warning)."
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
        if window?.firstResponder is NSTextView, tabBar.isEditing { window?.makeFirstResponder(nil) }
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
            select(max(0, index - 1), unfold: false) // the left neighbour
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
        let busy = closing.filter { $0.closeWarning != nil }
        var note = "Closing the window’s last tab closes the window."
        if closing.allSatisfy(\.exited) {
            note = "The shell in the window’s last tab has ended, so the window closes."
        } else if !busy.isEmpty {
            note = "Closing the window’s last tab closes the window and stops " + Self.stopList(busy)
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

    /// Tabs whose closing would stop a program or a job.
    var busyTabs: [TerminalTab] { tabs.filter { $0.closeWarning != nil } }

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

    /// "“vim notes.md” (suspended); “npm run dev” (running); and more in 2 other tabs." The same ending
    /// for every alert that stops tabs.
    static func stopList(_ busy: [TerminalTab]) -> String {
        let listed = busy.prefix(4).compactMap(\.closeWarning).joined(separator: "; ")
        let rest = busy.count - 4
        return listed + (rest > 0 ? "; and more in \(rest) other tab\(rest == 1 ? "" : "s")." : ".")
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
    /// tab), in the window in front (userCanSeeWindow) of the active app. Folded to its rail, no terminal is on
    /// screen, so what happens in the tab in front is news too. Its status and its notifications both go by this.
    func isOnScreen(_ tab: TerminalTab) -> Bool {
        guard userCanSeeWindow, !terminalRailed, let group = activeGroup, group.panes.contains(where: { $0 === tab }) else { return false }
        return group.zoomed == nil || group.zoomed === tab
    }

    /// What a notification says the tab is in: the window's project, else the tab's folder.
    func placeName(of tab: TerminalTab) -> String {
        if let project { return (project as NSString).lastPathComponent }
        if tab.directory == FileManager.default.homeDirectoryForCurrentUser.path { return "~" }
        let last = (tab.directory as NSString).lastPathComponent
        return last.isEmpty ? tab.directory : last
    }

    private func tick() {
        tickCount += 1
        let now = TerminalTab.now
        refreshVisibility()
        for tab in tabs {
            if tickCount % 2 == 0 { tab.pollForeground(); tab.pollServing() } // every 0.5 s
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
        let shortcuts = Self.tabShortcuts(count: groups.count)
        let items = groups.enumerated().map { index, group -> TabBarItem in
            let tab = group.focused
            guard group.isSplit else {
                return TabBarItem(title: tab.title, truncation: tab.titleTruncation, state: tab.status.state, tooltip: tab.tooltip,
                                  accessibilityStatus: tab.ownStateDescription ?? "", shortcut: shortcuts[index], remote: tab.remoteMark,
                                  shorterTitles: tab.shorterTitles, editableTitle: tab.editableTitle)
            }
            // A split tab: named by the pane with the keyboard, marked by the pane that most needs you.
            let lines = group.panes.map(\.paneSummary)
            // VoiceOver reads the title first: the keyboard pane's line goes when it is only that title
            // ("web-1: app (connecting)"), or the connection would be said three times.
            let spoken = group.panes.filter { $0 !== tab || $0.paneSummary != $0.title }.map(\.paneSummary)
            let mark = group.remoteMark
            let others = "  +\(group.panes.count - 1)"
            return TabBarItem(title: tab.title + others, truncation: tab.titleTruncation,
                              state: Self.mostUrgent(group.panes.map(\.status.state)),
                              tooltip: ([mark?.summary].compactMap { $0 } + lines).joined(separator: "\n"),
                              accessibilityStatus: spoken.joined(separator: "; "), shortcut: shortcuts[index], remote: mark,
                              shorterTitles: tab.shorterTitles.map { $0 + others }, editableTitle: tab.editableTitle)
        }
        tabBar.update(items: items, selectedIndex: activeIndex)
        sidebar.showRemote(activeTab?.remoteMark) // the pane with the keyboard: the tree follows it
        updateRailMarks(items)
        announceBackgroundChanges()
        updateTitle()
        AppDelegate.shared.updateBadge()
        updateProjectRoot()
        noteAgentTabs()
    }

    /// Needs you, then working, failed, done, idle.
    static func mostUrgent(_ states: [TabState]) -> TabState {
        let order: [TabState] = [.attention, .working, .failed, .done, .idle]
        return order.first { states.contains($0) } ?? .idle
    }

    /// "Alertable.php — xCloud" while editing, "zsh — xCloud" in the terminal, "claude — on web-1 — xCloud"
    /// in a remote tab (the Window menu, Mission Control and VoiceOver say where it runs), but "web-1: app —
    /// xCloud" when the tab's name says it already.
    func updateTitle() {
        let name = project.map { ($0 as NSString).lastPathComponent }
        let focus = isEditorFocused ? editorArea.activeName : activeTab?.title
        let host = isEditorFocused ? nil : activeTab?.remote.flatMap { remote -> String? in
            focus?.hasPrefix(remote.host.name + ": ") == true ? nil : "on \(remote.host.name)"
        }
        window?.title = [focus, host, name, "Next Term"].compactMap { $0 }.joined(separator: " — ")
    }

    /// Tells VoiceOver users when a background tab finishes, fails or asks for attention: the dots are
    /// visual, so without this they would never know.
    private func announceBackgroundChanges() {
        for (i, tab) in groups.enumerated().flatMap({ index, group in group.panes.map { (index, $0) } }) {
            let state = tab.status.state
            defer { announcedStates[tab.id] = state }
            guard i != activeIndex || terminalRailed, announcedStates[tab.id] != state, [.done, .failed, .attention].contains(state) else { continue }
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
        // A remote tab's folder is on its host, not this Mac: the tree stays where it was.
        guard let tab = activeTab, tab.remote == nil else { return }
        let key = tab.id.uuidString + "\u{0}" + tab.directory
        guard key != projectKey else { return }
        projectKey = key
        sidebar.setRoot(ProjectRoot.find(from: tab.directory))
        AppDelegate.shared.projectsChanged()
    }

    // MARK: find and replace in files

    /// The folder searches cover: the project, else what the sidebar shows, else the tab's git root.
    var searchRoot: String {
        project ?? sidebar.root?.path ?? activeTab.flatMap { $0.remote == nil ? ProjectRoot.find(from: $0.directory) : nil } ?? NSHomeDirectory()
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

    /// A window nobody has used yet: no project, one tab, nothing run in it.
    var isPristine: Bool {
        // A remote tab is never unused: commands there are seen only now and then, and its session matters.
        guard project == nil, groups.count == 1, tabs.count == 1, let tab = tabs.first, tab.remote == nil else { return false }
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
        opensWelcome = true
        window.performClose(nil)
        if window.isVisible && window.attachedSheet == nil { opensWelcome = false } // close was refused
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let valid = validateTabCommand(item) { return valid } // TabMenus.swift
        let gitActions: [Selector] = [#selector(showBranches(_:)), #selector(gitFetch(_:)), #selector(gitUpdate(_:)), #selector(gitCommit(_:)),
                                      #selector(gitPush(_:)), #selector(gitNewBranch(_:))]
        if let action = item.action, gitActions.contains(action) { return gitFolder != nil }
        if item.action == #selector(showGitLog(_:)) { return gitLogRoot != nil }
        if item.action == #selector(closeProject(_:)) { return project != nil }
        if item.action == #selector(openServedURL(_:)) { return activeTab?.servedURL != nil }
        if item.action == #selector(saveDocument(_:)) { return editorArea.activeEditor != nil }
        if item.action == #selector(saveAllDocuments(_:)) { return !editorArea.dirtyDocuments.isEmpty }
        if item.action == #selector(goToLine(_:)) { return editorArea.activeEditor != nil }
        if item.action == #selector(showChanges(_:)) {
            return editorArea.activePath != nil || sidebar.selection.contains { !$0.isFolder } || sidebar.selectedDeleted.contains { !$0.isDirectory }
        }
        // On when the keyboard is where ⌥⌘K sends from, with something to send, even with no agent running:
        // sending then says that none is.
        if item.action == #selector(sendToAgent(_:)) {
            let sendable = editorArea.activePath != nil && editorArea.activeDiff?.proposal == nil
            let fromSidebar = window?.firstResponder === sidebar.outline && !sidebar.selection.isEmpty
            return (isEditorFocused && sendable) || fromSidebar || terminalSelectionToSend != nil
        }
        if item.action == #selector(toggleEditorFocus(_:)) {
            item.title = isEditorFocused ? "Focus Terminal" : "Focus Editor"
            return editorArea.activeTextView != nil
        }
        if item.action == #selector(closeTab(_:)) {
            item.title = !isEditorFocused && activeGroup?.isSplit == true ? "Close Pane" : "Close Tab"
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
        if item.action == #selector(toggleEnvValues(_:)) {
            item.state = editorArea.activeEditor?.hidesEnvValues == true ? .on : .off
            return editorArea.activeEditor?.isEnvFile == true
        }
        if item.action == #selector(toggleTerminalCollapsed(_:)) {
            item.title = terminalCollapsed ? "Expand Terminal" : "Collapse Terminal"
            return !editorArea.isHidden
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
        terminalCollapsed = false // a new layout starts unfolded
        placeWorkDivider()
        updateCollapseButton()
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
            // Files opened while it was hidden were not revealed: the one in front is now.
            if let path = editorArea.activePath { sidebar.reveal(path) }
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
        // Folded to its rail on the left, the terminal has no bar: the editor's, just after the rail, has the corner.
        let railedLeft = terminalRailed && terminalFirst
        // Which bar starts at the work area's top-left corner, and which bars run along its top edge.
        let terminalAtCorner = !editorShown || (terminalFirst && !railedLeft)
        let terminalAtTop = !editorShown || terminalPosition != .bottom
        let editorAtTop = terminalPosition != .top
        tabBar.leadingInset = terminalAtCorner ? corner : 8
        tabBar.dragsWindow = terminalAtTop
        let afterRail = max(8, corner - TerminalRail.width - workSplit.dividerThickness)
        editorArea.tabBar.leadingInset = terminalAtCorner ? 8 : (railedLeft ? afterRail : corner)
        // The rail itself under the traffic lights: its arrow goes below them.
        terminalRail.topInset = railedLeft && corner > 8 ? TabBarView.height : 0
        editorArea.tabBar.dragsWindow = editorAtTop
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
    /// The smallest the terminal may get: its tab bar while collapsed, else the usual minimum.
    private var terminalMinimum: CGFloat { terminalCollapsed ? collapsedLength : workMinimum }

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
        // Behind the rail nothing of the terminal shows to type into: whatever the editor has in front takes the keyboard.
        if isTerminalFocused, terminalRailed { editorArea.select(editorArea.activeIndex) }
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

    @objc private func shortcutsChanged() { updateCollapseButton() }

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
                                 toolTip: KeyboardShortcuts.shared.hint(words, #selector(toggleTerminalCollapsed(_:))))
        updateUpdateButton()
        updateRail()
    }

    // MARK: the rail

    /// The terminal folded beside the editor: a slim bar at the window's edge with each tab's mark.
    let terminalRail = TerminalRail(frame: NSRect(x: 0, y: 0, width: TerminalRail.width, height: 600))
    var terminalRailed: Bool { terminalCollapsed && workSplit.isVertical }
    /// Behind the rail the terminals keep the width they had: squeezed to it they would wrap every line,
    /// and an agent's screen could no longer be read for its status.
    private lazy var containerTrailing = container.trailingAnchor.constraint(equalTo: terminalPane.trailingAnchor)
    private lazy var containerWidth = container.widthAnchor.constraint(equalToConstant: workMinimum)

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
        let wanted = terminalRailed && terminal < workMinimum / 2 ? collapsedLength : max(terminal, workMinimum)
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
                    AppDelegate.shared.editorFraction = editor / length
                }
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
    /// the same folder is used rather than a second one.
    @discardableResult
    func runInNewTab(directory: String, command: String, title: String?) -> TerminalTab {
        let folder = canonicalPath(directory)
        let tab: TerminalTab
        if groups.count == 1, tabs.count == 1, let only = tabs.first, only.remote == nil, only.status.command.isEmpty, !only.status.running,
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

    private(set) lazy var fileFinder: GoToFileController = {
        let finder = GoToFileController()
        finder.onOpen = { [weak self] path, line, column in self?.openFile(URL(fileURLWithPath: path), line: line, column: column) }
        return finder
    }()

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

    func editorAreaDidShowOrHide(_ area: EditorArea) {
        followActiveFile()
        editorShownOrHidden()
    }

    // MARK: Claude Code sees the selection

    private var selectionShare: DispatchWorkItem?

    func editorAreaSelectionChanged(_ area: EditorArea) {
        followActiveFile()
        guard ClaudeIDEServer.shared.isRunning || GeminiIDEServer.shared.isRunning || CopilotIDEServer.shared.isRunning else { return }
        selectionShare?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.shareSelectionWithClaude() }
        selectionShare = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work) // while dragging, once it settles
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
    /// selection, 1-based. Secret-holding files (.env) are left out.
    func openFilesForGemini() -> [[String: Any]] {
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
            // The file, at the new side's selected lines; never into an agent's prompt while it waits on its proposal.
            guard let item = diff.contextItem() else { return NSSound.beep() }
            send([item])
        }
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
        if let client = AppDelegate.shared.claudeClient(for: tab), items.allSatisfy({ !$0.isFolder && $0.code == nil && $0.note == nil }) {
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

    /// ⌥⌘G: the changes of the file being edited, or the file selected in the sidebar, side by side.
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
        editorArea.openDiff(root: root, path: String(path.dropFirst(root.count + 1)), base: base)
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

    func sidebar(_ sidebar: ProjectSidebarView, openTabIn directory: String) {
        addTab(directory: directory)
    }

    func applyFontSize(_ size: CGFloat) {
        for tab in tabs { tab.view.font = Theme.terminalFont(size: size) }
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
        addTab(directory: project ?? activeTab.flatMap { $0.remote == nil ? $0.currentDirectory() : nil })
    }

    /// ⌘W closes what has the keyboard: the file being edited, or the terminal tab.
    @objc func closeTab(_ sender: Any?) {
        if isEditorFocused { return editorArea.closeActive() }
        if terminalRailed { return NSSound.beep() } // its tabs are folded away: nothing on screen to close
        if let tab = activeTab { requestClose(tab) }
    }

    @objc func renameTab(_ sender: Any?) {
        tabBar.beginRename(at: activeIndex)
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

    @objc func gitFetch(_ sender: Any?) { withGit { $0.fetch() } }
    @objc func gitUpdate(_ sender: Any?) { withGit { $0.updateProject() } }
    @objc func gitCommit(_ sender: Any?) { withGit { $0.commit() } }
    @objc func gitPush(_ sender: Any?) { withGit { $0.push() } }
    @objc func gitNewBranch(_ sender: Any?) { withGit { $0.askNewBranch(base: nil) } }
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

    @objc func clearBuffer(_ sender: Any?) {
        if KeyboardShortcuts.shared.preset.clearsOnlyInTerminal && isEditorFocused { return }
        guard let tab = activeTab else { return }
        clear(tab)
    }

    /// Wipes a terminal's screen and scrollback locally; at a prompt, asks the shell to redraw it.
    func clear(_ tab: TerminalTab) {
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
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close this window?"
        alert.informativeText = [busy.isEmpty ? "" : "Closing it stops " + Self.stopList(busy), kept].filter { !$0.isEmpty }.joined(separator: "\n\n")
        alert.addButton(withTitle: "Close Window")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else {
                self.opensWelcome = false
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
        groups.removeAll()
        editorArea.closeAll()
        finder.close()
        onClose?(self, opensWelcome)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        lastKey = Date()
        refreshVisibility()
        refresh()
        sidebar.scheduleSessionsReload() // agents in other terminals may have kept new ones
        if let view = activeTab?.view, window?.firstResponder !== view, !(window?.firstResponder is NSTextView), !terminalRailed {
            window?.makeFirstResponder(view)
        }
    }

    func windowDidResignKey(_ notification: Notification) { refreshVisibility() }
    func windowDidResignMain(_ notification: Notification) { refreshVisibility() }

    func windowWillEnterFullScreen(_ notification: Notification) { isFullScreen = true; updateInsets() }
    func windowWillExitFullScreen(_ notification: Notification) { isFullScreen = false; updateInsets() }

    // MARK: TabBarViewDelegate

    func tabBar(_ bar: TabBarView, didSelect index: Int) { select(index) }

    func tabBar(_ bar: TabBarView, didClose index: Int) {
        guard let group = groups[safe: index] else { return }
        guard group.isSplit else { return requestClose(group.focused) }
        // The tab's × closes all its panes, asking once if that stops anything (or, as the window's last
        // tab with files unsaved, whether to save them: the window closes too).
        let busy = group.panes.filter { $0.closeWarning != nil }
        let kept = Self.keptList(group.panes)
        if closesWindow(group.panes), !editorArea.dirtyDocuments.isEmpty {
            return askToSave(closing: group.panes, kept: kept) { [weak self] in group.panes.forEach { self?.remove($0, saveAsked: true) } }
        }
        guard !busy.isEmpty || !kept.isEmpty, let window else { return group.panes.forEach { remove($0) } }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close this tab and its \(group.panes.count) panes?"
        alert.informativeText = [busy.isEmpty ? "" : "Closing it stops " + Self.stopList(busy), kept].filter { !$0.isEmpty }.joined(separator: "\n\n")
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
            guard let self, let view = self.activeTab?.view, !self.tabBar.isEditing else { return }
            self.window?.makeFirstResponder(view)
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
