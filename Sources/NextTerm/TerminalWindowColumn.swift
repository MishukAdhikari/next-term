import AppKit
import NextTermCore

/// The window column in a terminal window: its host holds it beside the window's split view, at the outer edge on the
/// sidebar's side (WindowColumnHost). The hub (WindowColumns) tells every window the rows and whether the column shows;
/// the window gives them to its column, with its own id for the outline, and the column's clicks go back to the app.
extension TerminalWindowController {
    var windowColumn: WindowColumnView { columnHost.column }

    /// Wires the column's clicks and the room it is measured by. Once, as the window is made.
    func installWindowColumn() {
        let host: WindowColumnHost = columnHost
        let split: NSSplitView = outerSplitView
        host.sidebarWidth = { [weak self] () -> CGFloat in
            guard let self, self.isSidebarVisible else { return 0 }
            return self.sidebar.frame.width + split.dividerThickness
        }
        host.onShownChange = { [weak self] (shown: WindowColumnShown) in self?.windowColumnShownChanged(shown) }
        let column: WindowColumnView = host.column
        column.onSelect = { (id: Int) in AppDelegate.shared.bringForward(id) }
        column.onToggle = { AppDelegate.shared.toggleWindowColumnExpanded(nil) }
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

    /// The column and the split view where they go now, in this one pass: the sidebar keeps its width and the work area
    /// takes the change, each terminal resizing once.
    func placeWindowColumn() {
        let sidebarWidth: CGFloat = sidebar.frame.width
        columnHost.place()
        guard isSidebarVisible, sidebarWidth >= 160 else { return }
        // A guard, not the mechanism: the split view's holding priorities give the change to the work area.
        outerSplitView.layoutSubtreeIfNeeded()
        if abs(sidebar.frame.width - sidebarWidth) > 0.5 { placeSidebar(width: sidebarWidth) }
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
        guard !columnHost.columnOnRight, !isFullScreen else { return 0 }
        return columnHost.shown.width
    }

    /// The column's own insets for the traffic lights: folded at the top-left, a strip of title bar over its chevron;
    /// unfolded, its header's words after them. On the right, or in full screen, it starts at the top.
    func updateWindowColumnInsets() {
        let column: WindowColumnView = columnHost.column
        let underLights: Bool = !columnHost.columnOnRight && !isFullScreen
        column.topInset = underLights && columnHost.shown.form == .folded ? TabBarView.height : 0
        column.headerLeading = underLights ? 78 : 8
    }
}
