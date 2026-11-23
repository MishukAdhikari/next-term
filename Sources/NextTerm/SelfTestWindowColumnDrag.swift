#if DEBUG
import AppKit
import NextTermCore

/// The pinned window column's edge dragged in (plan 033, R12 and R13): it holds at its narrowest, folds to the rail past
/// half of it in this window, unfolds back out, and released folded folds every window with the width from before kept.
extension SelfTest {
    /// The pinned column's edge dragged in (R12, R13): held at 140 to the snap, folded past it in this window, unfolded
    /// back out, and at a release folded every window folds with the width from before the drag kept and no list open.
    /// Each step is timed: under a frame (16 ms) on average.
    static func dragFoldChecks(_ app: AppDelegate, _ c: TerminalWindowController, all: [TerminalWindowController]) async {
        let savedWidth: Any? = UserDefaults.standard.object(forKey: WindowColumnSettings.widthKey)
        let savedExpanded: Bool = app.windowColumnExpanded
        defer {
            restoreDefault(savedWidth, WindowColumnSettings.widthKey)
            WindowColumnWidth.expanded = WindowColumnWidth.expandedWidth(CGFloat(UserDefaults.standard.double(forKey: WindowColumnSettings.widthKey)))
            app.windowColumnExpanded = savedExpanded
            for each in all { each.placeWindowColumn() }
        }
        UserDefaults.standard.set(Double(180), forKey: WindowColumnSettings.widthKey)
        WindowColumnWidth.expanded = 180
        app.windowColumnExpanded = true
        c.window?.layoutIfNeeded()
        let column: WindowColumnView = c.windowColumn
        guard c.columnHost.shown.form == .expanded, column.onResize != nil else {
            return note("window column side: the drag's fold not checked, as the window had no room to unfold its column")
        }
        let start: CFTimeInterval = CACurrentMediaTime()
        var steps = 0
        for width in stride(from: CGFloat(180), through: 141, by: -3) {
            column.onResize?(width, false)
            c.window?.layoutIfNeeded()
            c.window?.displayIfNeeded()
            steps += 1
        }
        let perStep: Double = (CACurrentMediaTime() - start) * 1000 / Double(steps)
        note(String(format: "window column side: a drag step takes %.1f ms on average (%d steps)", perStep, steps))
        column.onResize?(100, false)
        c.window?.layoutIfNeeded()
        let held: Bool = column.frame.width == 140 + WindowColumnWidth.hairline && c.columnHost.shown.form == .expanded
        column.onResize?(60, false)
        c.window?.layoutIfNeeded()
        let foldedHere: Bool = c.columnHost.shown.form == .folded
        let othersStill: Bool = all.filter { $0 !== c }.allSatisfy { $0.columnHost.shown.form == .expanded || $0.columnHost.shown.form == .hidden }
        column.onResize?(150, false)
        c.window?.layoutIfNeeded()
        let backOut: Bool = c.columnHost.shown.form == .expanded && column.frame.width == 150 + WindowColumnWidth.hairline
        column.onResize?(60, false)
        column.onResize?(60, true)
        for each in all { each.window?.layoutIfNeeded() }
        let allFolded: Bool = !app.windowColumnExpanded && all.allSatisfy { $0.columnHost.shown.form != .expanded }
        let widthKept: Bool = WindowColumnWidth.expanded == 180 && UserDefaults.standard.double(forKey: WindowColumnSettings.widthKey) == 180
        let noList: Bool = !c.columnHost.listShowing
        app.windowColumnExpanded = true
        c.window?.layoutIfNeeded()
        let unfoldsAt180: Bool = column.frame.width == 180 + WindowColumnWidth.hairline
        check(held && foldedHere && othersStill && backOut && allFolded && widthKept && noList && unfoldsAt180,
              "window column side: dragging the pinned edge in holds at 140, folds this window past 70, unfolds back out, and released folded folds every window, keeps 180 and opens no list",
              "held \(held), folded here \(foldedHere), others still \(othersStill), back out \(backOut), all folded \(allFolded), width kept \(widthKept), no list \(noList), unfolds at 180 \(unfoldsAt180)")
        check(perStep < 16, "window column side: each drag step lays the window out in under a frame (16 ms)", String(format: "%.1f ms", perStep))
    }
}
#endif
