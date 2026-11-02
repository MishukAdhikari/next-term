import AppKit
import NextTermCore

/// The window column in a terminal window: its host holds it beside the window's split view, at the outer edge on the
/// sidebar's side (WindowColumnHost). The hub (WindowColumns) tells every window the rows and whether the column shows;
/// the window gives them to its column, with its own id for the outline, and the column's clicks go back to the app.
extension TerminalWindowController {
    var windowColumn: WindowColumnView { columnHost.column }

    /// Wires the column's clicks and the room it is measured by. Once, as the window is made, before its first tab: it
    /// shows from the start when it will once the window opens, so no shell starts at a width the column then narrows.
    func installWindowColumn() {
        let host: WindowColumnHost = columnHost
        let split: NSSplitView = outerSplitView
        let app: AppDelegate = AppDelegate.shared
        host.visible = app.windowColumns.visibleForNewWindow()
        host.expanded = app.windowColumnExpanded
        // Unfolded beside the sidebar as it is, so unfolding never narrows it; folded beside a minimal one, as a window
        // narrowing narrows its sidebar too (the split view shares the change out).
        host.sidebarRoom = { [weak self] () -> (shown: CGFloat, minimal: CGFloat) in
            guard let self, self.isSidebarVisible else { return (0, 0) }
            return (self.sidebar.frame.width + split.dividerThickness, ProjectSidebarView.minimumWidth + split.dividerThickness)
        }
        host.aroundColumnChange = { [weak self] (apply: () -> Void) in
            guard let self, self.isSidebarVisible else { return apply() }
            let kept: CGFloat = self.sidebar.frame.width
            self.columnMovesSidebar = true
            defer { self.columnMovesSidebar = false }
            apply()
            self.keepSidebar(width: kept)
        }
        host.onShownChange = { [weak self] (shown: WindowColumnShown) in self?.windowColumnShownChanged(shown) }
        let column: WindowColumnView = host.column
        column.onSelect = { [weak host] (id: Int) in
            host?.chose() // no list slides out in the window just left
            AppDelegate.shared.bringForward(id)
        }
        column.onToggle = { AppDelegate.shared.toggleWindowColumnExpanded(nil) }
        column.onFold = { (key: String) in AppDelegate.shared.windowColumns.toggleFold(key) }
        // Its edge dragged: as wide as the pointer says, but never past the room the editor and terminal keep beside the
        // sidebar, so the drag never folds it.
        column.onResize = { [weak self] (width: CGFloat?, ended: Bool) in
            guard let self else { return }
            let room: CGFloat = self.columnHost.unfoldedRoom()
            // Whole points under the room, so rounding never takes it past and folds it.
            AppDelegate.shared.windowColumns.setWidth(width.map { min($0, room.rounded(.down)) }, from: self, ended: ended)
        }
        column.onMore = { AppDelegate.shared.openProjectPanel(nil) }
    }

    /// The hub's rows, what changed in them, whether the column shows in every window, and whether the user unfolded it.
    /// Only a change of what shows lays the window out again.
    func applyWindowColumn(list: WindowColumnList, change: WindowColumnList.Change, visible: Bool, expanded: Bool) {
        let host: WindowColumnHost = columnHost
        host.column.update(list: list, change: change, current: indexID, expanded: host.shown.form == .expanded)
        let reshaped: Bool = host.visible != visible || host.expanded != expanded
        host.visible = visible
        host.expanded = expanded
        if reshaped { placeWindowColumn() }
    }

    /// The column and the split view where they go now: the sidebar keeps its width and the work area takes the change,
    /// each terminal resizing once, at the next layout.
    func placeWindowColumn() {
        columnHost.place()
    }

    /// The sidebar back at `kept` after the column changed width, its divider moved before anything is laid out, so the
    /// work area takes the whole change. Never wider than it was; narrower only to leave the work area its minimum, and
    /// then not below the sidebar's own, unless a resize of the window had it there already. This rule alone places it:
    /// the drag's limits are not applied (`columnMovesSidebar`).
    private func keepSidebar(width kept: CGFloat) {
        let split: NSSplitView = outerSplitView
        let room: CGFloat = split.bounds.width - split.dividerThickness - WindowColumnWidth.workMinimum
        let width: CGFloat = max(min(kept, ProjectSidebarView.minimumWidth), min(kept, room))
        guard abs(sidebar.frame.width - width) > 0.5 else { return }
        placeSidebar(width: width, layingOut: false)
    }

    /// The column showed, went or changed form in this window (two windows open, the setting, the fold, or the window's
    /// room): it draws in its form, and the traffic lights' room is taken into account.
    private func windowColumnShownChanged(_ shown: WindowColumnShown) {
        let column: WindowColumnView = columnHost.column
        column.update(list: column.list, change: .none, current: indexID, expanded: shown.form == .expanded)
        updateInsets()
    }

    /// How far the column reaches in from the window's left edge, under the traffic lights: its width with its hairline
    /// while it shows on the left outside full screen, else 0.
    var windowColumnUnderLights: CGFloat {
        guard !columnHost.columnOnRight, lightsBesideBars else { return 0 }
        return columnHost.shown.width
    }

    /// The column's own inset for the traffic lights: on the left outside full screen, a strip of title bar over its count
    /// in every form (WindowColumnGrid), so nothing sits under them and the list on hover, the rail and the pinned column
    /// keep one grid. On the right, or in full screen, it starts at the top.
    func updateWindowColumnInsets() {
        let host: WindowColumnHost = columnHost
        let underLights: Bool = !host.columnOnRight && lightsBesideBars
        let inset: CGFloat = underLights ? TabBarView.height : 0
        guard host.column.topInset != inset else { return }
        host.hideList(animated: false) // its grid was the old one's
        host.column.topInset = inset
    }
}
