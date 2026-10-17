import AppKit
import NextTermCore

/// The strip that shows a window's terminal tabs, for what renames one there: the bar along the terminal's top, or
/// the list down its side.
protocol TerminalTabStrip: AnyObject {
    var isEditing: Bool { get }
    func beginRename(at index: Int)
}

extension TabBarView: TerminalTabStrip {}
extension TabListView: TerminalTabStrip {}

/// Where a window's tab list sits and how wide it is: the constraints that place it, the width the user gave it and
/// whether they collapsed it, and how it shows now. Only the list's edge and the collapse commands change the user's
/// width; the window's size changes only how it shows.
final class TabListPlacement {
    /// The side it is laid out on; nil while the tabs are in the bar.
    var side: TabListSide?
    /// The width it opens at, and the user's own collapse, as this window keeps them.
    var width: CGFloat = TabListWidth.defaultWidth
    var userCollapsed = false
    /// How it shows now: open at its width, or collapsed by the user or for want of room.
    var shown = TabListWidth.Shown(width: TabListWidth.defaultWidth, collapsed: false, byRoom: false)
    /// The list's edge is being dragged, or it collapses or opens: the terminals keep their width until it is let go.
    var holding = false
    /// A collapsed list is open over the terminal for a rename: it collapses again when the field closes, and the
    /// user's width and collapse stay as they were.
    var renaming = false
    /// Which strips showed the tabs, as last put.
    var listShown = false
    var barShowsTabs = true
    /// The rows the list was last given, given again when only its form changes.
    var rows: [TabListRow] = []
    /// Its top and bottom under the bar and its width, on with either side; and its edge on each side.
    var along: [NSLayoutConstraint] = []
    var edges: [TabListSide: NSLayoutConstraint] = [:]
}

/// The window's half of the tab list: where it sits in the terminal pane, what feeds it, what its clicks do, and its
/// width. Everything else in the window stays as it is with the list: the bar keeps its +, its fold arrow, its ⋯ and
/// the window drag, the sidebar and the editor stay where they are, and every key that acts on a tab acts the same.
extension TerminalWindowController: TabListViewDelegate {
    // MARK: where the tabs show

    /// The side the list sits on, as laid out; nil while the tabs are on top.
    var tabListSide: TabListSide? { tabListPlace.side }

    /// The bar shows the tabs with Top, and with a list while the terminal is folded to its bar above or below the
    /// editor, so the marks stay in sight; beside the editor the rail shows them, as with Top.
    var barShowsTabs: Bool { tabListPlace.side == nil || (terminalCollapsed && !terminalRailed) }
    /// The list shows the tabs: Left or Right, and the terminal not folded.
    var listShowsTabs: Bool { tabListPlace.side != nil && !terminalCollapsed }

    /// The strip a rename goes to: the list, unless the bar shows the tabs.
    var tabStrip: TerminalTabStrip { barShowsTabs ? tabBar : tabList }

    /// Beside the editor, the room the list takes collapsed: the terminal pane never gets so narrow that the column of
    /// marks leaves the terminal under its minimum. Above or below the editor the list takes no height, so none.
    var tabListRoom: CGFloat { tabListPlace.side != nil && workSplit.isVertical ? TabListWidth.collapsedWidth : 0 }

    /// The list in the terminal pane, after the terminals and the bar and before the rail: it draws over the
    /// terminals' edge while its own edge is dragged, and the rail covers it while the terminal is folded beside the
    /// editor. Its constraints are made once and switched on with Left or Right.
    func installTabList() {
        tabList.isHidden = true
        tabList.delegate = self
        tabList.translatesAutoresizingMaskIntoConstraints = false
        terminalPane.addSubview(tabList)
        let place = tabListPlace
        place.along = [tabList.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
                       tabList.bottomAnchor.constraint(equalTo: terminalPane.bottomAnchor),
                       tabList.widthConstraint]
        place.edges = [.left: tabList.leadingAnchor.constraint(equalTo: terminalPane.leadingAnchor),
                       .right: tabList.trailingAnchor.constraint(equalTo: terminalPane.trailingAnchor)]
        loadTabListWidth()
    }

    /// Puts the tabs where Settings › Terminal › Tabs says: on the list's side, the list under the bar and the
    /// terminals beside it, which change size once. Nothing else moves, and a folded terminal stays folded. The side
    /// it has already changes nothing.
    func applyTerminalTabs() {
        let side: TabListSide? = AppDelegate.shared.terminalTabs.listSide
        let place = tabListPlace
        if side != place.side {
            // A rename in the list ends first, while its row and the list's open form for it still hold.
            if window?.firstResponder is NSTextView, tabList.isEditing { window?.makeFirstResponder(nil) }
            if let old = place.side { place.edges[old]?.isActive = false } // one edge off before the other is on
            if let side {
                tabList.side = side
                if place.side == nil { NSLayoutConstraint.activate(place.along) }
                place.edges[side]?.isActive = true
            } else {
                NSLayoutConstraint.deactivate(place.along)
                // Back on top: the list lets its rows go, and starts afresh if it comes back.
                place.rows = []
                tabList.update(rows: [], selectedIndex: 0, density: .oneLine, collapsed: false)
            }
            place.side = side
            place.shown = shownTabList()
            placeTabList()
        }
        showTabStrip()
    }

    /// The tabs in the strip that shows them, and the list shown or hidden to match: when the setting or the fold
    /// changes. Without its tabs the bar is no longer a tab group to VoiceOver, so it finds one, the list.
    func showTabStrip() {
        let place = tabListPlace
        let list: Bool = listShowsTabs
        let bar: Bool = barShowsTabs
        guard list != place.listShown || bar != place.barShowsTabs else { return }
        place.listShown = list
        place.barShowsTabs = bar
        tabList.isHidden = !list
        tabBar.setAccessibilityRole(bar ? .tabGroup : .group)
        tabBar.setAccessibilityLabel(bar ? "Terminal tabs" : "Terminal bar")
        if list { fitTabList() } // the pane's width may have changed while it was hidden
        if !groups.isEmpty { refresh() }
    }

    // MARK: feeding

    /// The tabs to the strip that shows them, from the window's tick as the bar always was: the bar its items, or
    /// none with the list; the list a row per tab, each split tab followed by a row per pane. The list is fed only
    /// while it shows.
    func feedTabStrips(_ items: [TabBarItem]) {
        let inBar: Bool = barShowsTabs
        tabBar.update(items: inBar ? items : [], selectedIndex: inBar ? activeIndex : 0)
        guard listShowsTabs else { return }
        let folders: Bool = AppDelegate.shared.tabListShowsFolders
        var sources: [TabListRows.Source] = []
        sources.reserveCapacity(groups.count)
        for (group, item) in zip(groups, items) { sources.append(tabListSource(group, item, folders: folders)) }
        let workingShown: Bool = AgentSpinner.current != .off
        let rows: [TabListRow] = TabListRows.make(tabs: sources, showsFolders: folders, home: NSHomeDirectory(), workingShown: workingShown,
                                                  now: TerminalTab.now)
        tabListPlace.rows = rows
        let collapsed: Bool = tabListPlace.shown.collapsed && !tabListPlace.renaming
        tabList.update(rows: rows, selectedIndex: activeIndex, density: TabListDensity(showsFolders: folders), collapsed: collapsed)
    }

    /// One tab as the list shows it, from what its bar item already holds: the same title, mark, tooltip, words and
    /// key. A split tab's panes each give their own. Keyed by the tab's pane group and each pane's id, which never
    /// meet: a tab opening or closing touches its own rows alone.
    private func tabListSource(_ group: PaneGroup, _ item: TabBarItem, folders: Bool) -> TabListRows.Source {
        let key = "tab \(UInt(bitPattern: ObjectIdentifier(group)))"
        guard group.isSplit else {
            let tab: TerminalTab = group.focused
            let pane = TabListRows.Pane(key: "pane \(tab.id.uuidString)", title: item.title, truncatesTail: item.truncation == .byTruncatingTail,
                                        shorterTitles: item.shorterTitles, editableTitle: item.editableTitle, state: item.state,
                                        tooltip: item.tooltip, spokenStatus: item.accessibilityStatus, folder: folders ? tab.directory : "",
                                        question: folders ? tab.status.question : nil, remote: item.remote, focused: true,
                                        herdrAgents: tab.herdrRows, herdrIdleOpen: tab.herdrIdleOpen)
            return TabListRows.Source(key: key, panes: [pane], shortcut: item.shortcut, place: item.place)
        }
        let focused: TerminalTab = group.focused
        let panes: [TabListRows.Pane] = group.panes.map { (tab: TerminalTab) -> TabListRows.Pane in
            tabListPane(tab, focused: tab === focused, folders: folders)
        }
        return TabListRows.Source(key: key, panes: panes, shortcut: item.shortcut, place: item.place, tooltip: item.tooltip,
                                  spokenStatus: item.accessibilityStatus)
    }

    /// One pane of a split tab: its own title, mark, tooltip and words, as its pane header has them.
    private func tabListPane(_ tab: TerminalTab, focused: Bool, folders: Bool) -> TabListRows.Pane {
        let shorter: [String] = tab.shorterTitles.map(AgentSpinner.shown)
        return TabListRows.Pane(key: "pane \(tab.id.uuidString)", title: AgentSpinner.shown(tab.title),
                                truncatesTail: tab.titleTruncation == .byTruncatingTail, shorterTitles: shorter,
                                editableTitle: tab.editableTitle, state: tab.status.state, tooltip: tab.tooltip,
                                spokenStatus: tab.ownStateDescription ?? "", folder: folders ? tab.directory : "",
                                question: folders ? tab.status.question : nil, remote: tab.remoteMark, focused: focused,
                                herdrAgents: tab.herdrRows, herdrIdleOpen: tab.herdrIdleOpen)
    }

    /// The list given its rows again as last made, in the form it shows now: when only its width or its collapse
    /// changed. At once, so the list never waits for the tick to show its new form.
    private func refeedTabList() {
        guard tabListPlace.side != nil else { return }
        let density = TabListDensity(showsFolders: AppDelegate.shared.tabListShowsFolders)
        let collapsed: Bool = tabListPlace.shown.collapsed && !tabListPlace.renaming
        tabList.update(rows: tabListPlace.rows, selectedIndex: activeIndex, density: density, collapsed: collapsed)
    }

    // MARK: the width

    /// How the list shows in the pane now, at the user's width and collapse. It is measured only while it shows:
    /// hidden (the tabs on top, or folded behind the rail) the pane's width says nothing about the room beside it.
    private func shownTabList() -> TabListWidth.Shown {
        let place = tabListPlace
        let paneWidth: CGFloat = listShowsTabs ? terminalPane.frame.width : 0
        return TabListWidth.shown(paneWidth: paneWidth, width: place.width, userCollapsed: place.userCollapsed)
    }

    /// The list at the width it shows, and the terminals in the rest of the pane: their edge on the list's side sits
    /// in by the list's width. Changed once per change, so each terminal changes size once.
    private func placeTabList() {
        let place = tabListPlace
        let width: CGFloat = place.side == nil ? 0 : place.shown.width
        if place.side != nil, tabList.widthConstraint.constant != width { tabList.widthConstraint.constant = width }
        let leading: CGFloat = place.side == .left ? width : 0
        let trailing: CGFloat = place.side == .right ? -width : 0
        if containerLeading.constant != leading { containerLeading.constant = leading }
        if containerTrailing.constant != trailing { containerTrailing.constant = trailing }
        tabList.openWidth = place.width
    }

    /// Collapses the list for want of room when the terminal beside it would be narrower than its minimum, and opens it
    /// again once there is room: after the window, the sidebar or the editor changed the pane's width. Touched only when
    /// what it shows changes, and never while its edge is held. The user's own collapse is never undone.
    func fitTabList() {
        guard listShowsTabs, !tabListPlace.holding else { return }
        let shown: TabListWidth.Shown = shownTabList()
        guard shown != tabListPlace.shown else { return }
        tabListPlace.shown = shown
        placeTabList()
        refeedTabList()
    }

    /// Where this window's list starts: as its project last had it, else open at the width last set in any window,
    /// else 220. Read when the window opens and when it takes a project.
    func loadTabListWidth() {
        let defaults = UserDefaults.standard
        let widths = TabListWidths(propertyList: defaults.dictionary(forKey: TabListWidths.key))
        let last: Double? = defaults.object(forKey: TabListWidth.lastKey) as? Double
        let start: (width: CGFloat, collapsed: Bool) = widths.start(for: project, last: last)
        tabListPlace.width = start.width
        tabListPlace.userCollapsed = start.collapsed
        tabList.openWidth = start.width
        guard tabListPlace.side != nil else { return }
        tabListPlace.shown = shownTabList()
        placeTabList()
        refeedTabList()
    }

    /// The width and collapse the user set, kept: under the project's folder for its windows to come, and as the
    /// width a new window starts at. Only the edge and the collapse commands get here, never a window's resize,
    /// minimising or full screen, so nothing resets it. Folders that are gone are dropped as it is written.
    private func saveTabListWidth() {
        let defaults = UserDefaults.standard
        let place = tabListPlace
        defaults.set(Double(place.width), forKey: TabListWidth.lastKey)
        guard let project else { return }
        let stored = TabListWidths(propertyList: defaults.dictionary(forKey: TabListWidths.key))
        let kept: TabListWidths = stored.pruned { (folder: String) -> Bool in FileManager.default.fileExists(atPath: folder) }
            .setting(width: place.width, collapsed: place.userCollapsed, for: project, now: Date().timeIntervalSince1970)
        defaults.set(kept.propertyList, forKey: TabListWidths.key)
    }

    func tabListWillResize(_ list: TabListView) {
        tabListPlace.holding = true // the terminals stay where they are: placeTabList is not run until the release
    }

    func tabList(_ list: TabListView, didResizeTo width: CGFloat, collapsed: Bool) {
        let place = tabListPlace
        place.holding = false
        place.width = TabListWidth.clamp(width)
        place.userCollapsed = collapsed
        saveTabListWidth()
        place.shown = shownTabList()
        placeTabList()
        refeedTabList()
    }

    /// View › Terminal Tabs › Collapse Tab List or Expand Tab List, and the terminal's ⋯ item: as a double-click on
    /// the list's edge.
    @objc func toggleTabListCollapsed(_ sender: Any?) {
        guard listShowsTabs else { return NSSound.beep() }
        tabList.toggleCollapsed()
    }

    /// Its title follows what the list shows. It needs the list in sight: folded, the bar or the rail has the tabs.
    func validateTabListCollapse(_ item: NSMenuItem) -> Bool {
        let shows: Bool = listShowsTabs
        item.title = shows && tabList.isCollapsed ? "Expand Tab List" : "Collapse Tab List"
        return shows
    }

    // MARK: TabListViewDelegate: the bar's own calls, so every rule they keep holds for the list

    func tabList(_ list: TabListView, didSelect index: Int) { tabBar(tabBar, didSelect: index) }

    /// A pane's row: its tab comes forward with that pane in front (a zoomed tab shows its panes again) and the pane
    /// takes the keyboard, as a click in it does; for a tab an agent opened, the click chooses it.
    func tabList(_ list: TabListView, didSelectPane pane: Int, of index: Int) {
        guard let tab = groups[safe: index]?.panes[safe: pane] else { return }
        show(tab)
    }

    /// A herdr agent's row: its tab comes forward and herdr's view moves to the agent's pane (HerdrAgentMenu.show).
    func tabList(_ list: TabListView, didSelectAgent pane: String, of index: Int) {
        guard let tab = herdrTab(showing: pane, in: index) else { return }
        HerdrAgentMenu.show(tab: tab, pane: pane)
    }

    /// A herdr agent's row's menu.
    func tabList(_ list: TabListView, menuForAgent pane: String, of index: Int) -> NSMenu? {
        herdrTab(showing: pane, in: index).map { HerdrAgentMenu.rowMenu(tab: $0, pane: pane) }
    }

    /// The folded row of a tab's idle herdr agents: open, or closed (`open` nil: the other way).
    func tabList(_ list: TabListView, foldIdleAgentsOf index: Int, open: Bool?) {
        guard let tab = groups[safe: index]?.panes.first(where: { !$0.herdrRows.isEmpty }) else { return }
        let next = open ?? !tab.herdrIdleOpen
        guard next != tab.herdrIdleOpen else { return }
        tab.herdrIdleOpen = next
        refresh()
    }

    /// Peek at an agent's row, or at a tab row whose tab runs an agent; anything else beeps.
    func tabList(_ list: TabListView, peekAt pane: String?, of index: Int, row: NSView) {
        if let pane {
            guard let tab = herdrTab(showing: pane, in: index) else { return NSSound.beep() }
            return AgentPeek.show(tab, pane: pane, relativeTo: row.bounds, of: row)
        }
        guard let tab = groups[safe: index]?.focused, tab.status.running, tab.status.kind == .agent, !tab.followsHerdr else {
            return NSSound.beep()
        }
        AgentPeek.show(tab, pane: nil, relativeTo: row.bounds, of: row)
    }

    /// The pane of tab `index` whose herdr lists `pane`.
    private func herdrTab(showing pane: String, in index: Int) -> TerminalTab? {
        groups[safe: index]?.panes.first { tab in tab.herdrRows.contains { $0.pane == pane } }
    }

    func tabList(_ list: TabListView, didClose index: Int) { tabBar(tabBar, didClose: index) }
    func tabList(_ list: TabListView, didMove from: Int, to: Int) { tabBar(tabBar, didMove: from, to: to) }
    func tabList(_ list: TabListView, didRename index: Int, to title: String?) { tabBar(tabBar, didRename: index, to: title) }
    func tabListDidRequestNewTab(_ list: TabListView) { tabBarDidRequestNewTab(tabBar) }
    func tabList(_ list: TabListView, menuFor index: Int) -> NSMenu? { tabBar(tabBar, menuFor: index) }

    /// A rename on a collapsed list: it opens over the terminal at its width, as while its edge is dragged, so the
    /// terminals keep theirs, and nothing the user set changes or is saved. Never wider than the pane.
    func tabListWillOpenForRename(_ list: TabListView) {
        let place = tabListPlace
        place.renaming = true
        place.holding = true // fitTabList waits for the field to close
        let pane: CGFloat = terminalPane.frame.width
        tabList.widthConstraint.constant = pane > 0 ? min(place.width, pane) : place.width
    }

    func tabListDidEndEditing(_ list: TabListView) {
        let place = tabListPlace
        if place.renaming {
            // Shown as before the rename, measured again in case the pane changed meanwhile.
            place.renaming = false
            place.holding = false
            place.shown = shownTabList()
            placeTabList()
            refeedTabList()
        }
        tabBarDidEndEditing(tabBar)
    }
}
