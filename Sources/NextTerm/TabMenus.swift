import AppKit
import NextTermCore

/// Terminal tabs closed lately, for Shell › Reopen Closed Tab (⇧⌘T): where each one was and the name you
/// gave it. What ran in it ended with it, so it comes back with a fresh shell. App-wide, newest last.
enum ClosedTabs {
    struct Entry {
        let directory: String
        /// The name you gave the tab. A program's own title is not kept: it named what ran.
        let title: String?
        let remote: RemoteTab?
        /// The window it was in, to come back there while that is open.
        weak var window: TerminalWindowController?
    }

    private(set) static var entries: [Entry] = []
    static let limit = 25
    static var isEmpty: Bool { entries.isEmpty }

    /// Called as a tab closes. A shell on this Mac that nothing ran in, that stayed in the folder it started
    /// in and that has no name is not kept: there is nothing to bring back (and a new window's first shell
    /// makes way for a remote tab that way).
    static func remember(_ tab: TerminalTab, in window: TerminalWindowController) {
        if tab.remote == nil, tab.userTitle == nil, tab.status.commandsStarted == 0, !tab.leftStartFolder { return }
        let directory = tab.exited ? tab.directory : tab.liveDirectory // an ended shell's process is gone
        entries.append(Entry(directory: directory, title: tab.userTitle, remote: tab.remote, window: window))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    static func takeLast() -> Entry? { entries.popLast() }

    /// A closed remote tab again, on its host as saved now (nil once the host was removed). A tab tmux kept
    /// reattaches to its session, which closing only detached from, unless another tab shows it now; any
    /// other gets a new shell in its folder.
    static func reopening(_ remote: RemoteTab, directory: String) -> RemoteTab? {
        guard let host = RemoteHosts.all.first(where: { $0.id == remote.host.id }) else { return nil }
        let tabs = AppDelegate.shared.controllers.flatMap(\.tabs)
        let shown = tabs.contains { !$0.exited && $0.remote?.session == remote.session }
        if remote.keep == .tmux, !shown {
            return RemoteTab(host: host, directory: remote.directory, session: remote.session, keep: remote.keep)
        }
        return RemoteTab(host: host, directory: directory, keep: remote.keep)
    }
}

extension NSMenu {
    /// A right-click menu's command. It runs `run` on what was clicked, and shows the key its menu-bar
    /// command has now (`command` is that command's id, as Settings › Keyboard Shortcuts lists it).
    @discardableResult
    func addCommand(_ title: String, _ command: String?, enabled: Bool = true, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = addBlock(title, enabled: enabled, run)
        if let command {
            item.identifier = NSUserInterfaceItemIdentifier(command)
            let menuBarItem = KeyboardShortcuts.shared.commands.first { $0.id == command }?.item
            KeyboardShortcuts.set(menuBarItem.flatMap(KeyboardShortcuts.chord(of:)), on: item)
        }
        return item
    }
}

/// The right-click menus of the terminal, its tabs and the editor's tabs, and the menu-bar commands they
/// share (Duplicate Tab, Reopen Closed Tab, Close Other Tabs, Close Tabs to the Right, and the open file's
/// Reveal in Finder, Copy Path and Copy Relative Path), so Settings can give any of them a key.
extension TerminalWindowController {
    // MARK: the terminal

    /// The terminal's right-click menu. The pane clicked takes the keyboard first, as a click there would,
    /// so the menu acts where you clicked. `link`: the link or path under the pointer.
    func terminalMenu(for tab: TerminalTab, link: String?) -> NSMenu {
        show(tab)
        let view = tab.view
        let menu = NSMenu()
        if let link, let target = view.target(of: link) {
            addLinkItems(to: menu, target, in: view)
            menu.addItem(.separator())
        }
        let selected = view.selectionActive
        // Whether there is text to paste, without reading it: macOS may ask you first when an app reads the clipboard.
        let pasteable = view.acceptsInput && NSPasteboard.general.availableType(from: [.string]) != nil
        menu.addCommand("Copy", "copy:", enabled: selected) { view.copy(view) }
        menu.addCommand("Paste", "paste:", enabled: pasteable) { view.paste(view) }
        menu.addCommand("Select All", "selectAll:") { view.selectAll(nil) }
        menu.addItem(.separator())
        menu.addCommand("Clear", "clearBuffer:") { [weak self] in self?.clear(tab) }
        menu.addCommand("Find…", "performFindPanelAction:#1") { [weak self] in self?.showFind(in: tab) }
        menu.addItem(.separator())
        menu.addCommand("Split Right", "splitRight:") { [weak self] in self?.split(vertical: true, from: tab) }
        menu.addCommand("Split Down", "splitDown:") { [weak self] in self?.split(vertical: false, from: tab) }
        if selected, agentTab != nil {
            menu.addItem(.separator())
            menu.addCommand("Send Selection to Agent", "sendToAgent:") { [weak self] in self?.sendSelection(of: tab) }
        }
        return menu
    }

    /// A web or mail link opens in its app; a file, as ⌘-click opens it (in the editor, at its line).
    private func addLinkItems(to menu: NSMenu, _ target: NextTermView.LinkTarget, in view: NextTermView) {
        switch target {
        case .web(let url):
            menu.addCommand("Open Link", nil) { view.open(target) }
            menu.addCommand("Copy Link", nil) { Self.copyToPasteboard(url.absoluteString) }
        case .file(let url, _, _):
            let name = Typography.shortened(url.lastPathComponent, to: 40)
            menu.addCommand("Open “\(name)”", nil) { view.open(target) }
            menu.addCommand("Reveal in Finder", nil) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    /// Edit › Find › Find… in `tab`: the terminal's find bar, starting from its selection.
    private func showFind(in tab: TerminalTab) {
        window?.makeFirstResponder(tab.view)
        let find = NSMenuItem()
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        tab.view.performFindPanelAction(find)
    }

    /// The terminal with the keyboard, when text is selected in it: what Send to Agent sends from there.
    var terminalSelectionToSend: TerminalTab? {
        guard let tab = activeTab, window?.firstResponder === tab.view, tab.view.selectionActive else { return nil }
        return tab
    }

    /// Send to Agent from a terminal: the text selected in `tab`, typed into the agent's prompt as a quote it
    /// reads as output. Enter is left to you. Up to 200 lines (16 KB), as for code from the editor.
    func sendSelection(of tab: TerminalTab) {
        guard let window, let text = tab.view.getSelection(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return NSSound.beep()
        }
        guard !AgentPrompt.isTooLargeToInline(text) else {
            let alert = NSAlert()
            alert.messageText = "The selection is too long to send"
            alert.informativeText = "Send to Agent types up to \(AgentPrompt.maxInlineLines) lines (16 KB) of terminal text. Select less, or copy it."
            return alert.beginSheetModal(for: window)
        }
        guard let agent = agentTab(receivingFrom: tab) else { return noAgentAlert().beginSheetModal(for: window) }
        show(agent)
        // Inside a bracketed paste a line break is text; an agent that takes no pastes gets one line.
        if agent.view.getTerminal().bracketedPasteMode {
            agent.view.typeText(AgentPrompt.quote(text))
        } else {
            agent.view.typeIn(AgentPrompt.quoteOnOneLine(text))
        }
        window.makeFirstResponder(agent.view)
    }

    /// The agent that text selected in `tab` goes to: another one than the agent whose output it is, the one
    /// used last, when one runs; else as for anything sent to an agent.
    func agentTab(receivingFrom tab: TerminalTab) -> TerminalTab? {
        let others = tabs.filter { $0 !== tab && $0.remote == nil && $0.status.running && $0.status.kind == .agent }
        return others.max { $0.lastSelected < $1.lastSelected } ?? agentTab
    }

    // MARK: terminal tabs

    func tabBar(_ bar: TabBarView, menuFor index: Int) -> NSMenu? {
        bar === tabBar ? terminalTabMenu(at: index) : nil
    }

    /// A terminal tab's right-click menu. It acts on that tab, in front or not.
    func terminalTabMenu(at index: Int) -> NSMenu? {
        guard let group = groups[safe: index] else { return nil }
        let menu = NSMenu()
        menu.addCommand("Rename…", "renameTab:") { [weak self] in self?.rename(group) }
        menu.addItem(.separator())
        menu.addCommand("Split Right", "splitRight:") { [weak self] in self?.split(group, vertical: true) }
        menu.addCommand("Split Down", "splitDown:") { [weak self] in self?.split(group, vertical: false) }
        menu.addCommand("Duplicate Tab", "duplicateTab:") { [weak self] in self?.duplicate(group) }
        menu.addItem(.separator())
        menu.addCommand("Close Tab", "closeTab:") { [weak self] in self?.closeGroup(group) }
        menu.addCommand("Close Other Tabs", "closeOtherTabs:", enabled: groups.count > 1) { [weak self] in
            guard let self else { return }
            self.closeTabs(self.groups.filter { $0 !== group })
        }
        menu.addCommand("Close Tabs to the Right", "closeTabsToTheRight:", enabled: index < groups.count - 1) { [weak self] in
            self?.closeTabs(toTheRightOf: group)
        }
        return menu
    }

    private func rename(_ group: PaneGroup) {
        guard let index = groups.firstIndex(where: { $0 === group }) else { return }
        tabBar.beginRename(at: index)
    }

    /// A split of the tab's pane with the keyboard, the tab brought to the front first.
    private func split(_ group: PaneGroup, vertical: Bool) {
        guard let index = groups.firstIndex(where: { $0 === group }) else { return }
        select(index)
        split(vertical: vertical, from: group.focused)
    }

    /// As the tab's ×: all its panes, asking once if that stops anything.
    private func closeGroup(_ group: PaneGroup) {
        guard let index = groups.firstIndex(where: { $0 === group }) else { return }
        tabBar(tabBar, didClose: index)
    }

    private func closeTabs(toTheRightOf group: PaneGroup) {
        guard let index = groups.firstIndex(where: { $0 === group }) else { return }
        closeTabs(Array(groups.dropFirst(index + 1)))
    }

    /// A new tab next to `group`, in the folder of its pane with the keyboard (on its server, for a remote
    /// tab): a fresh shell there, not a copy of what runs.
    @discardableResult
    func duplicate(_ group: PaneGroup) -> TerminalTab? {
        guard let index = groups.firstIndex(where: { $0 === group }) else { return nil }
        if index != activeIndex { select(index) } // a new tab goes next to the one in front
        let from = group.focused
        if let remote = from.remote { return addRemoteTab(remote.sibling(directory: from.directory)) }
        return addTab(directory: from.currentDirectory())
    }

    /// Closes several tabs, each with all its panes, asking once if that would stop anything (what runs in
    /// them, what tmux keeps running on a server), as closing one tab does. One tab always stays, so the
    /// window never closes this way.
    func closeTabs(_ closing: [PaneGroup]) {
        let panes = closing.flatMap(\.panes)
        guard !panes.isEmpty else { return }
        let busy = panes.filter { $0.closeWarning != nil }
        let kept = Self.keptList(panes)
        guard !busy.isEmpty || !kept.isEmpty, let window else { return panes.forEach { remove($0) } }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = closing.count == 1 ? "Close “\(closing[0].focused.title)”?" : "Close \(closing.count) tabs?"
        let stops = busy.isEmpty ? "" : "Closing \(closing.count == 1 ? "it" : "them") stops " + Self.stopList(busy)
        alert.informativeText = [stops, kept].filter { !$0.isEmpty }.joined(separator: "\n\n")
        alert.addButton(withTitle: closing.count == 1 ? "Close Tab" : "Close Tabs")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            panes.forEach { self?.remove($0) }
        }
    }

    // MARK: editor tabs

    /// An editor tab's right-click menu. It acts on that tab, in front or not.
    func editorTabMenu(at index: Int) -> NSMenu? {
        let area = editorArea
        guard let pane = area.panes[safe: index] else { return nil }
        let menu = NSMenu()
        menu.addCommand("Close", "closeTab:") { area.close(pane) }
        menu.addCommand("Close Others", "closeOtherTabs:", enabled: area.panes.count > 1) {
            area.close(area.panes.filter { $0 !== pane }, keeping: pane)
        }
        menu.addCommand("Close Tabs to the Right", "closeTabsToTheRight:", enabled: index < area.panes.count - 1) {
            guard let at = area.panes.firstIndex(where: { $0 === pane }) else { return }
            area.close(Array(area.panes.dropFirst(at + 1)), keeping: pane)
        }
        guard let path = area.path(of: pane) else { return menu }
        menu.addItem(.separator())
        menu.addCommand("Show in Project Sidebar", "revealInSidebar:") { [weak self] in self?.showInSidebar(path) }
        menu.addCommand("Copy Path", "copyFilePath:") { Self.copyToPasteboard(path) }
        menu.addCommand("Copy Relative Path", "copyRelativeFilePath:") { [weak self] in
            if let self { Self.copyToPasteboard(self.relativePath(path)) }
        }
        menu.addCommand("Reveal in Finder", "revealInFinder:") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        return menu
    }

    /// The project sidebar shows `path`, coming back first if it was hidden.
    func showInSidebar(_ path: String) {
        if !isSidebarVisible { toggleProjectSidebar(nil) }
        sidebar.reveal(path)
    }

    /// `path` from the top of the folder the sidebar shows, as the sidebar's Copy Relative Path has it; the
    /// whole path when it is outside.
    func relativePath(_ path: String) -> String {
        let root = canonicalPath(sidebar.root?.path ?? searchRoot)
        let full = canonicalPath(path)
        return full.hasPrefix(root + "/") ? String(full.dropFirst(root.count + 1)) : path
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: menu-bar commands

    /// Shell › Duplicate Tab: a new tab in the folder of the one in front (on its server, for a remote tab).
    @objc func duplicateTab(_ sender: Any?) {
        guard let group = activeGroup else { return NSSound.beep() }
        duplicate(group)
    }

    /// Shell › Reopen Closed Tab (⇧⌘T): the terminal tab closed last comes back, in the window it was in
    /// while that is open, else in this one.
    @objc func reopenClosedTab(_ sender: Any?) {
        guard let entry = ClosedTabs.takeLast() else { return NSSound.beep() }
        let open = entry.window.flatMap { window in AppDelegate.shared.controllers.contains { $0 === window } ? window : nil }
        let target = open ?? self
        if target !== self { target.window?.makeKeyAndOrderFront(nil) }
        target.reopen(entry)
    }

    /// A closed tab back, next to the one in front: its folder and its name, with a fresh shell (nil when
    /// its server was removed since).
    @discardableResult
    func reopen(_ entry: ClosedTabs.Entry) -> TerminalTab? {
        let tab: TerminalTab
        if let remote = entry.remote {
            guard let again = ClosedTabs.reopening(remote, directory: entry.directory) else {
                NSSound.beep()
                return nil
            }
            tab = addRemoteTab(again)
        } else {
            tab = addTab(directory: entry.directory)
        }
        if let title = entry.title {
            tab.userTitle = title
            refresh()
        }
        return tab
    }

    /// Shell › Close Other Tabs: of the editor's tabs while it has the keyboard, else of the terminal's.
    @objc func closeOtherTabs(_ sender: Any?) {
        if isEditorFocused, let pane = editorArea.activePane {
            return editorArea.close(editorArea.panes.filter { $0 !== pane }, keeping: pane)
        }
        guard let group = activeGroup, !terminalRailed else { return NSSound.beep() }
        closeTabs(groups.filter { $0 !== group })
    }

    /// Shell › Close Tabs to the Right: as Close Other Tabs, for the tabs after the one in front.
    @objc func closeTabsToTheRight(_ sender: Any?) {
        if isEditorFocused, let pane = editorArea.activePane {
            return editorArea.close(Array(editorArea.panes.dropFirst(editorArea.activeIndex + 1)), keeping: pane)
        }
        guard let group = activeGroup, !terminalRailed else { return NSSound.beep() }
        closeTabs(toTheRightOf: group)
    }

    /// Shell › Reveal in Finder: the file in front in the editor.
    @objc func revealInFinder(_ sender: Any?) {
        guard let path = editorArea.activePath else { return NSSound.beep() }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Shell › Copy Path: the file in front in the editor.
    @objc func copyFilePath(_ sender: Any?) {
        guard let path = editorArea.activePath else { return NSSound.beep() }
        Self.copyToPasteboard(path)
    }

    /// Shell › Copy Relative Path: the file in front in the editor, from the top of the sidebar's folder.
    @objc func copyRelativeFilePath(_ sender: Any?) {
        guard let path = editorArea.activePath else { return NSSound.beep() }
        Self.copyToPasteboard(relativePath(path))
    }

    /// Whether this file's menu-bar commands are on now (nil for any other item): what they act on is there.
    func validateTabCommand(_ item: NSMenuItem) -> Bool? {
        guard let action = item.action else { return nil }
        let editing = isEditorFocused
        switch action {
        case #selector(reopenClosedTab(_:)):
            return !ClosedTabs.isEmpty
        case #selector(duplicateTab(_:)):
            return activeGroup != nil
        case #selector(closeOtherTabs(_:)):
            if editing { return editorArea.panes.count > 1 }
            return groups.count > 1 && !terminalRailed
        case #selector(closeTabsToTheRight(_:)):
            if editing { return editorArea.activeIndex + 1 < editorArea.panes.count }
            return activeIndex + 1 < groups.count && !terminalRailed
        case #selector(revealInFinder(_:)), #selector(copyFilePath(_:)), #selector(copyRelativeFilePath(_:)):
            return editorArea.activePath != nil
        default:
            return nil
        }
    }
}
