#if DEBUG
import AppKit
import NextTermCore

/// Pinned tabs (plan 045), on screen: Pin Tab moves the tab first, with its pin where the × would be and a hairline
/// after it; a drag keeps pinned tabs together; Close Other Tabs leaves a pinned tab; ⌘W on it asks first and Cancel
/// keeps it; the pin is in the session and in list_tabs; Unpin puts it back after the pinned ones; the vertical tab
/// list shows the pin and the hairline. Screenshots: the bar and the list with a pinned tab.
extension SelfTest {
    static func pinnedTabsChecks() async {
        guard let app = AppDelegate.shared else { return }
        let base = canonicalPath(NSTemporaryDirectory()) + "/nt-pinned-\(getpid())"
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let w = app.openWindow(directory: base)
        defer {
            for group in w.groups { group.pinned = false }
            w.window?.close()
            try? FileManager.default.removeItem(atPath: base)
        }
        guard let first = w.tabs.first else { return check(false, "pinned tabs: the window has a tab") }
        first.userTitle = "one"
        let two = w.addTab(directory: base)
        two.userTitle = "two"
        let api = w.addTab(directory: base)
        api.userTitle = "api"
        w.refresh()
        w.window?.makeKeyAndOrderFront(nil)
        func titles() -> [String] { w.groups.map { $0.focused.title } }

        // Pin Tab: first, the pin shown, a hairline after it.
        guard let apiGroup = w.group(of: api) else { return check(false, "pinned tabs: the tab has a group") }
        w.setPinned(apiGroup, true)
        w.tabBar.layoutSubtreeIfNeeded()
        check(titles() == ["api", "one", "two"] && apiGroup.pinned, "pinned tabs: Pin Tab moves the tab first", titles().joined(separator: " "))
        check(w.tabBar.showsPin(at: 0) && !w.tabBar.showsPin(at: 1) && w.tabBar.showsPinDivider, "pinned tabs: the pin stands where the × would, with a hairline after the pinned tabs")
        check(w.terminalTabMenu(at: 0)?.items.contains { $0.title == "Unpin Tab" } == true
              && w.terminalTabMenu(at: 1)?.items.contains { $0.title == "Pin Tab" } == true,
              "pinned tabs: the tab's menu offers Unpin Tab on a pinned tab, Pin Tab on the others")
        if let window = w.window { await screenshot(window, suffix: "-pinned-bar") }

        // A drag keeps a tab on its side of the hairline.
        w.tabBar(w.tabBar, didMove: 2, to: 0)
        check(titles().first == "api", "pinned tabs: a dragged tab never goes before a pinned one", titles().joined(separator: " "))

        // The session keeps the pin; list_tabs says it.
        let saved = SessionCapture.window(w, scrollback: [:])
        check(saved.groups.first?.pinned == true && saved.groups.dropFirst().allSatisfy { !$0.pinned },
              "pinned tabs: the pin is kept in the session")
        check(MCPControl.describe(api, in: w, caller: nil)["pinned"] as? Bool == true
              && MCPControl.describe(first, in: w, caller: nil)["pinned"] == nil, "pinned tabs: list_tabs says which tab is pinned")

        // Close Other Tabs leaves the pinned tab.
        w.select(w.groups.firstIndex { $0.contains(two) } ?? 1)
        w.closeOtherTabs(nil)
        _ = await wait(3) { w.groups.count == 2 }
        check(titles() == ["api", "two"], "pinned tabs: Close Other Tabs leaves the pinned tab", titles().joined(separator: " "))

        // ⌘W on the pinned tab asks first; Cancel keeps it.
        w.select(0)
        w.closeTab(nil)
        let asked = await wait(3) { w.window?.attachedSheet != nil }
        let question = (w.window?.attachedSheet?.contentView?.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue) ?? []).joined(separator: " ")
        check(asked && question.contains(PinnedTabs.closeQuestion(title: "api")), "pinned tabs: ⌘W on a pinned tab asks first", question)
        if let sheet = w.window?.attachedSheet {
            if let cancel = sheet.contentView?.subviews.flatMap({ [$0] + $0.subviews }).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Cancel" }) {
                cancel.performClick(nil)
            } else {
                w.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
            }
        }
        _ = await wait(3) { w.window?.attachedSheet == nil }
        check(w.groups.contains { $0 === apiGroup }, "pinned tabs: Cancel keeps the pinned tab open")

        // The vertical tab list: the pin and the hairline.
        let before = app.terminalTabs
        app.moveTerminalTabs(to: .left)
        w.refresh()
        let row = await wait(5) { w.refresh(); return w.tabList.rowView(at: 0)?.showsPin == true }
        check(row, "pinned tabs: the tab list shows the pin on the pinned tab's row")
        if let window = w.window { await screenshot(window, suffix: "-pinned-list") }
        app.moveTerminalTabs(to: before)
        w.refresh()

        // Unpin: back after the pinned ones, as an ordinary tab.
        w.setPinned(apiGroup, false)
        check(!apiGroup.pinned && !w.tabBar.showsPinDivider, "pinned tabs: Unpin Tab makes it an ordinary tab again")
    }
}
#endif
