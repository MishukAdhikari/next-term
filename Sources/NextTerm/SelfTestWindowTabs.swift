import AppKit
import NextTermCore

#if DEBUG
/// Project windows as tabs of one window (plan 032). Part of NEXTTERM_SELFTEST_ONLY=windowTabs.
extension SelfTest {
    static func windowTabsChecks(_ c: TerminalWindowController) async {
        await tabBarLayoutChecks(c)
    }

    /// A system tab bar over a project window (one tab, as Show Tab Bar shows it): the window's top row (the terminal's
    /// and the editor's tab bars, the sidebar header, the window column's count) moves below it, the traffic lights' room
    /// goes from our bars, and the strip it covers takes the bar's colour; without it, all comes back as it was.
    static func tabBarLayoutChecks(_ c: TerminalWindowController) async {
        guard let window = c.window else { return }
        _ = await bringToFront(window)
        let saved: (mode: NSWindow.TabbingMode, id: String) = (window.tabbingMode, window.tabbingIdentifier)
        defer {
            if window.tabGroup?.isTabBarVisible == true { window.toggleTabBar(nil) }
            window.tabbingMode = saved.mode
            window.tabbingIdentifier = saved.id
            c.titleBarChanged(force: true)
        }
        window.layoutIfNeeded()
        let before: (cover: CGFloat, header: CGFloat, bar: NSRect) = (c.columnHost.topCover, c.sidebar.headerInset, frameInWindow(c.tabBar))
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "NextTerm.project"
        window.toggleTabBar(nil)
        let shown: Bool = await wait(2) { c.columnHost.topCover > 0 }
        window.layoutIfNeeded()
        let layoutTop: CGFloat = window.contentLayoutRect.maxY
        let cover: CGFloat = c.columnHost.topCover
        let bar: NSRect = frameInWindow(c.tabBar)
        let editorBar: NSRect = c.editorArea.isHidden ? .zero : frameInWindow(c.editorArea.tabBar)
        let header: NSRect = c.isSidebarVisible ? frameInWindow(c.sidebar.header) : .zero
        let column: NSRect = c.windowColumn.isHidden ? .zero : frameInWindow(c.windowColumn)
        let below: Bool = [bar, editorBar, header, column].allSatisfy { $0 == .zero || $0.maxY <= layoutTop + 0.5 }
        let lightsGone: Bool = !c.lightsBesideBars && c.sidebar.headerInset == 8 && c.windowColumn.topInset == 0
        await screenshot(c, suffix: "-tab-bar")
        check(shown && below && lightsGone,
              "window tabs: with a system tab bar over the window, its tab bars, sidebar header and window column sit below it, the traffic lights' room gone from them",
              "shown \(shown), cover \(cover), layout top \(layoutTop), terminal bar \(bar), editor bar \(editorBar), header \(header), column \(column), "
                  + "header inset \(c.sidebar.headerInset), column inset \(c.windowColumn.topInset)")
        window.toggleTabBar(nil)
        let gone: Bool = await wait(2) { c.columnHost.topCover == 0 }
        window.layoutIfNeeded()
        let back: Bool = gone && c.sidebar.headerInset == before.header && frameInWindow(c.tabBar) == before.bar && before.cover == 0
        check(back, "window tabs: without the tab bar, the top row is back beside the traffic lights, as before",
              "cover \(c.columnHost.topCover), header inset \(c.sidebar.headerInset) of \(before.header), bar \(frameInWindow(c.tabBar)) of \(before.bar)")
    }

    private static func frameInWindow(_ view: NSView) -> NSRect {
        view.isHidden || view.window == nil ? .zero : view.convert(view.bounds, to: nil)
    }
}
#endif
