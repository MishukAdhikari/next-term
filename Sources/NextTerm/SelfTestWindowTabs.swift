import AppKit
import NextTermCore

#if DEBUG
/// Project windows as tabs of one window (plan 032). Part of NEXTTERM_SELFTEST_ONLY=windowTabs.
extension SelfTest {
    static func windowTabsChecks(_ c: TerminalWindowController) async {
        // Windows merge in this part only (SelfTest.run pins it off for the others).
        WindowTabbing.suppressed = false
        NSWindow.allowsAutomaticWindowTabbing = true
        defer {
            WindowTabbing.suppressed = true
            NSWindow.allowsAutomaticWindowTabbing = false
        }
        await tabBarLayoutChecks(c)
        await mergedWindowChecks(c)
        await columnMergeChecks(c) // the window column's right-click has Merge All Windows too
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
        window.tabbingIdentifier = WindowTabbing.projectIdentifier
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

    /// Two project windows merged into one and split again: both lay out under the one tab bar, the tab behind counts as
    /// unseen, ⌃⌘[ and ⌃⌘] switch them, the menus hold one item per tab command (macOS adds none of its own), a save
    /// records the group, an agent's tab in the project behind stays behind, a notice for it waits for its tab, and Close
    /// Window closes the whole window.
    static func mergedWindowChecks(_ c: TerminalWindowController) async {
        let app: AppDelegate = AppDelegate.shared
        guard let host = c.window, await bringToFront(host), NSApp.isActive else {
            return note("merged window checks skipped: Next Term isn't the app in front (" + (c.window.map(notFrontmost) ?? "no window") + ")")
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-tabs-\(getpid())")
        let third = root.appendingPathComponent("third")
        try? FileManager.default.createDirectory(at: third, withIntermediateDirectories: true)
        let saved: (mode: NSWindow.TabbingMode, id: String) = (host.tabbingMode, host.tabbingIdentifier)
        host.tabbingMode = .automatic // made while windows were kept apart
        host.tabbingIdentifier = WindowTabbing.projectIdentifier
        let other = app.openWindow(directory: root.path, project: root.path)
        var made: [TerminalWindowController] = [other]
        defer {
            for controller in made where !controller.hasClosed {
                if controller.window?.tabGroup?.windows.count ?? 0 > 1 { controller.window?.moveTabToNewWindow(nil) }
                for tab in controller.tabs { controller.remove(tab) } // its last tab takes the window
            }
            if host.tabGroup?.windows.count ?? 0 > 1 { host.moveTabToNewWindow(nil) }
            host.tabbingMode = saved.mode
            host.tabbingIdentifier = saved.id
            c.titleBarChanged(force: true)
            try? FileManager.default.removeItem(at: root)
        }
        guard let second = other.window else { return check(false, "window tabs: a second project window opens") }
        _ = await wait(20) { other.tabs.first?.status.integrated == true }

        // Merged: one tab bar over both, the second in front.
        host.addTabbedWindow(second, ordered: .above)
        second.makeKeyAndOrderFront(nil)
        let merged: Bool = await wait(3) { c.columnHost.topCover > 0 && other.columnHost.topCover > 0 && host.tabGroup?.selectedWindow === second }
        check(merged && host.tabGroup?.windows.count == 2 && host.isBackgroundTab && !second.isBackgroundTab
              && c.columnHost.topCover == other.columnHost.topCover && WindowTabbing.measuredCover == other.columnHost.topCover,
              "window tabs: two project windows merged share one tab bar, each laid out below it, the one behind known as behind",
              "merged \(merged), group \(host.tabGroup?.windows.count ?? 0), covers \(c.columnHost.topCover) and \(other.columnHost.topCover), "
                  + "measured \(WindowTabbing.measuredCover ?? -1), behind \(host.isBackgroundTab)")
        check(!host.canBeSeen && TerminalWindow.front === second && second.shownWindow === second && host.shownWindow === second,
              "window tabs: the project behind counts as unseen, and the one in front is the front window",
              "host seen \(host.canBeSeen), front \(TerminalWindow.front?.title ?? "none")")
        await screenshot(other, suffix: "-merged")
        await mergedTabHoverCheck(other)
        // The tab bar a while later, and with the window no longer in front (a reported fade).
        await pause(6)
        await screenshot(other, suffix: "-merged-later")
        NSApp.hide(nil)
        await pause(1)
        NSApp.unhide(nil)
        // Unhidden, the app need not be active again (another took the front while it was hidden): with no key window
        // the keys below reach no tab and nothing takes the keyboard, so it is brought back as the user would.
        if !(await bringToFront(second)) { note("merged windows: the app did not come back in front after being unhidden") }
        await pause(1)
        await screenshot(other, suffix: "-merged-back")
        let ids: Set<Int> = [c.indexID, other.indexID]
        check(c.columnHost.column.merged == ids && other.columnHost.column.merged == ids,
              "window tabs: each merged window's column knows the windows merged with it, for the bracket beside their rows",
              "\(c.columnHost.column.merged) and \(other.columnHost.column.merged) of \(ids)")

        // One item per tab command in the menus, Next Term's; Close Window is Next Term's, not AppKit's performClose:.
        NSApp.mainMenu?.update()
        let items: [NSMenuItem] = allItems(NSApp.mainMenu)
        let actions: [Selector] = [#selector(NSWindow.selectNextTab(_:)), #selector(NSWindow.selectPreviousTab(_:)),
                                   #selector(NSWindow.moveTabToNewWindow(_:)), #selector(NSWindow.mergeAllWindows(_:)),
                                   #selector(NSWindow.toggleTabBar(_:)), #selector(NSWindow.toggleTabOverview(_:))]
        let counts: [Int] = actions.map { action in items.filter { $0.action == action }.count }
        let closers: [String] = items.filter { $0.action == #selector(NSWindow.performClose(_:)) }.map(\.title)
        let toggle: String = items.first { $0.action == #selector(NSWindow.toggleTabBar(_:)) }.map { item in
            _ = (second as? TerminalWindow)?.validateMenuItem(item)
            return item.title
        } ?? ""
        check(counts.allSatisfy { $0 == 1 } && closers.isEmpty && toggle == "Hide Project Tab Bar",
              "window tabs: the menus hold one item for each tab command, named for projects, and macOS adds no Close Tab of its own",
              "counts \(counts), performClose items \(closers), tab bar item “\(toggle)”")

        // ⌃⌘[ and ⌃⌘] go to the previous and next project tab.
        pressKey(second, code: 33, [.command, .control]) // [
        let back: Bool = await wait(3) { host.tabGroup?.selectedWindow === host }
        pressKey(host, code: 30, [.command, .control]) // ]
        let forth: Bool = await wait(3) { host.tabGroup?.selectedWindow === second }
        check(back && forth, "window tabs: ⌃⌘[ and ⌃⌘] switch to the previous and next project tab", "back \(back), forth \(forth)")

        // A save records the group: both in it, in the tab bar's order, the one in front marked, one frame.
        let windows: [SessionSnapshot.Window] = SessionCapture.windows([c, other])
        let tabs: [SessionSnapshot.WindowTab] = windows.compactMap(\.windowTab)
        let units: [RestoreLayout.Unit] = RestoreLayout.units(windows)
        let group: [NSWindow] = host.tabGroup?.windows ?? []
        let order: [Int] = [host, second].map { window in group.firstIndex { $0 === window } ?? -1 }
        let savedOther = windows.first { $0.project == other.project }, savedHost = windows.first { $0.project != other.project }
        let placed: [Int] = [savedHost, savedOther].map { $0?.windowTab?.place ?? -1 }
        check(tabs.count == 2 && Set(tabs.map(\.group)).count == 1 && tabs.filter(\.front).count == 1 && placed == order
              && Set(windows.map { $0.frame.map { "\($0)" } ?? "" }).count == 1 && units.count == 1 && units.first?.members.count == 2,
              "window tabs: a save records the merged windows, in their tab order with the one in front, at one frame",
              "tabs \(tabs), places \(placed) of \(order), units \(units)")

        // The project tab: its colour's dot and its name.
        other.updateProjectTab()
        let title: String = second.tab.attributedTitle?.string ?? ""
        check(title.hasPrefix("\u{25CF}") && title.contains(WindowColumnName.shown(other.indexEntry, depth: 0).name),
              "window tabs: a project's tab shows its colour's dot and its name", "“\(title)”")

        // An agent's tab in the project behind (the second, behind the first): it opens there, behind, and nothing moves.
        host.makeKeyAndOrderFront(nil)
        let usersTab: Bool = await wait(3) { NSApp.keyWindow === host && host.tabGroup?.selectedWindow === host }
        let modeBefore = app.agentArrival
        app.agentArrival = .focus
        UserKeys.ignoredForTest = true
        var result = MCPServer.CallResult(text: "", isError: false)
        MCPControl.call("new_tab", ["directory": root.path], caller: nil) { result = $0 }
        _ = await wait(10) { !result.text.isEmpty }
        let answer = (try? JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any]) ?? [:]
        let agentTab: TerminalTab? = other.tabs.first { $0.id.uuidString.lowercased() == answer["id"] as? String }
        _ = await wait(1) { false } // a raise would come on a later turn
        check(usersTab && agentTab != nil && host.tabGroup?.selectedWindow === host && NSApp.keyWindow === host
              && agentTab?.view.awaitsChoice == true && answer["selected"] as? Bool == false,
              "window tabs: an agent's tab in the project behind opens there, and the tab in use stays in front with the keyboard",
              "\(answer), selected \(host.tabGroup?.selectedWindow?.title ?? "none"), key \(NSApp.keyWindow?.title ?? "none"), set up \(usersTab), "
                  + "in the second \(agentTab != nil), waits \(agentTab?.view.awaitsChoice == true)")
        if let agentTab { other.remove(agentTab) }
        app.agentArrival = modeBefore
        UserKeys.ignoredForTest = false
        second.makeKeyAndOrderFront(nil)
        _ = await wait(3) { host.tabGroup?.selectedWindow === second }

        // A notice for the project behind waits for its tab, and the one in front's stays.
        GitToast.dismiss()
        GitToast.show("Merged windows: a notice from behind", in: host)
        let held: Bool = !GitToast.isShowing
        host.tabGroup?.selectedWindow = host
        let shownLater: Bool = await wait(3) { GitToast.isShowing }
        GitToast.dismiss()
        check(held && shownLater, "window tabs: a notice for the project behind waits until its tab comes to the front",
              "held \(held), shown later \(shownLater)")
        second.makeKeyAndOrderFront(nil)

        // Split: each its own window again, its top row back beside the traffic lights.
        second.moveTabToNewWindow(nil)
        let split: Bool = await wait(3) { c.columnHost.topCover == 0 && other.columnHost.topCover == 0 }
        check(split && !host.isBackgroundTab && !second.isBackgroundTab,
              "window tabs: Move Project to New Window splits them, each laid out as before",
              "covers \(c.columnHost.topCover) and \(other.columnHost.topCover)")

        // Merge All Windows, as the user merges them: the window merged in lays out under the tab bar as the one it joined
        // does, whichever is in front, and both come back beside the traffic lights once split again.
        host.makeKeyAndOrderFront(nil)
        _ = await wait(3) { NSApp.keyWindow === host }
        host.mergeAllWindows(nil)
        let mergedAll: Bool = await wait(3) { host.tabGroup?.windows.contains(second) == true && c.columnHost.topCover > 0 }
        let hostBelow: String? = topRowAboveTabBar(c)
        host.tabGroup?.selectedWindow = second
        second.makeKeyAndOrderFront(nil)
        let secondCovered: Bool = await wait(3) { host.tabGroup?.selectedWindow === second && other.columnHost.topCover > 0 }
        let secondBelow: String? = topRowAboveTabBar(other)
        await screenshot(other, suffix: "-merged-all")
        check(mergedAll && secondCovered && hostBelow == nil && secondBelow == nil,
              "window tabs: after Merge All Windows, each window's top row (the window merged in too) starts below the tab bar",
              "merged \(mergedAll), second covered \(secondCovered), covers \(c.columnHost.topCover) and \(other.columnHost.topCover); "
                  + "first: \(hostBelow ?? "below"), second: \(secondBelow ?? "below")")
        second.moveTabToNewWindow(nil)
        let splitAgain: Bool = await wait(3) { c.columnHost.topCover == 0 && other.columnHost.topCover == 0 }
        check(splitAgain, "window tabs: split again after Merge All Windows, both top rows are back beside the traffic lights",
              "covers \(c.columnHost.topCover) and \(other.columnHost.topCover)")

        // Close Window on a merged window closes every project in it, and nothing else.
        let last = app.openWindow(directory: third.path, project: third.path)
        made.append(last)
        guard let lastWindow = last.window else { return check(false, "window tabs: a third project window opens") }
        _ = await wait(20) { last.tabs.first?.status.integrated == true }
        second.addTabbedWindow(lastWindow, ordered: .above)
        lastWindow.makeKeyAndOrderFront(nil)
        _ = await wait(3) { lastWindow.tabGroup?.windows.count == 2 }
        last.closeWindow(nil)
        let closed: Bool = await wait(5) { other.hasClosed && last.hasClosed }
        check(closed && !c.hasClosed && host.isVisible, "window tabs: Close Window closes every project merged into the window, and no other window",
              "second closed \(other.hasClosed), third closed \(last.hasClosed), sheet \(lastWindow.attachedSheet != nil)")
    }

    /// In a merged window, where the terminal's tab bar sits below the system tab bar and out of the title strip: resting
    /// on a tab whose name is cut short still shows its whole name.
    private static func mergedTabHoverCheck(_ c: TerminalWindowController) async {
        guard let tab = c.activeTab else { return check(false, "window tabs: the merged window in front has a tab") }
        let long = "A tab with a name far too long to fit in its place in the tab bar of a merged window, so it is cut short"
        tab.userTitle = long
        c.refresh()
        defer { tab.userTitle = nil; c.refresh(); HoverTip.shared.hide() }
        let index: Int = c.groups.firstIndex { $0.contains(tab) } ?? 0
        await pause(0.3)
        c.window?.layoutIfNeeded()
        HoverTip.shared.hide()
        c.tabBar.restPointerForTest(at: index)
        let shown: Bool = await wait(2) { HoverTip.shared.shownText == long }
        check(shown && c.tabBar.shownTitle(at: index) != long,
              "window tabs: in a merged window, resting on a tab whose name is cut short shows its whole name",
              "showing “\(HoverTip.shared.shownText ?? "")”, state \(c.tabBar.hoverState(at: index))")
    }

    /// The first of a window's top-row views (the terminal's and the editor's tab bars, the sidebar header, the window
    /// column) that reaches above the unobscured area under a system tab bar, with where it sits; nil when all are below.
    private static func topRowAboveTabBar(_ c: TerminalWindowController) -> String? {
        guard let window = c.window else { return "no window" }
        window.layoutIfNeeded()
        let layoutTop: CGFloat = window.contentLayoutRect.maxY
        let views: [(String, NSRect)] = [
            ("terminal bar", frameInWindow(c.tabBar)),
            ("editor bar", c.editorArea.isHidden ? .zero : frameInWindow(c.editorArea.tabBar)),
            ("sidebar header", c.isSidebarVisible ? frameInWindow(c.sidebar.header) : .zero),
            ("window column", c.windowColumn.isHidden ? .zero : frameInWindow(c.windowColumn)),
        ]
        guard let above = views.first(where: { $0.1 != .zero && $0.1.maxY > layoutTop + 0.5 }) else { return nil }
        return "\(above.0) \(above.1) above the layout top \(layoutTop)"
    }

    private static func allItems(_ menu: NSMenu?) -> [NSMenuItem] {
        (menu?.items ?? []).flatMap { [$0] + allItems($0.submenu) }
    }

    private static func frameInWindow(_ view: NSView) -> NSRect {
        view.isHidden || view.window == nil ? .zero : view.convert(view.bounds, to: nil)
    }
}
#endif
