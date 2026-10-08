import AppKit
import NextTermCore

/// Pane headers: in a tab split into panes, each pane has a header with its mark and title, and a × that
/// closes that pane alone, asking first when something runs there. A click on a header gives its pane the
/// keyboard, a double-click renames it. One pane, or a maximized one, has no header, and a header never
/// takes the terminal's rows. Splitting keeps a pane's history. The pane you type in keeps the keyboard
/// whatever happens to the panes beside it.
extension SelfTest {
    static func paneHeaderChecks(_ c: TerminalWindowController) async {
        guard let window = c.window, let base = c.activeTab, let group = c.activeGroup, !group.isSplit else {
            return check(false, "pane headers: a tab of one pane to split")
        }
        c.show(base)
        window.makeFirstResponder(base.view)
        let tabsBefore = c.groups.count
        func header(_ tab: TerminalTab) -> PaneHeaderView { group.paneView(tab).header }
        /// The terminal fills its pane below the header (4 points under it), or from the top without one.
        func terminalTop(_ tab: TerminalTab) -> CGFloat {
            let pane = group.paneView(tab)
            return pane.bounds.height - tab.view.frame.maxY
        }
        check(header(base).isHidden && abs(terminalTop(base) - 4) < 1, "pane headers: a tab of one pane has none", "\(terminalTop(base))")

        // History the pane has before it is split, to find whole after each split. Short lines: one row at any
        // pane's width, a dozen at the two columns a squeeze would rewrap them to, far past the scrollback's
        // 10,000. From the line's start, with blank lines after it where the prompt redraws on a resize.
        let marker = "pane history line"
        base.view.feed(text: "\r\n" + (1...3000).map { "\(marker) \($0)" }.joined(separator: "\r\n") + "\r\n\r\n\r\n\r\n")
        func history(_ tab: TerminalTab) -> Int {
            let terminal = tab.view.getTerminal()
            var row = 0, count = 0
            while let line = terminal.getScrollInvariantLine(row: row) {
                if line.translateToString(trimRight: true).hasPrefix(marker) { count += 1 }
                row += 1
            }
            return count
        }
        let before = history(base)
        check(before == 3000, "the pane has its history before the split", "\(before) lines")
        guard let other = c.split(vertical: true, from: base) else { return check(false, "pane headers: Split Right adds a pane") }
        _ = await wait(20) { other.status.integrated }
        check(history(base) == before, "Split Right keeps the pane's history", "\(before) → \(history(base)) lines")
        guard let third = c.split(vertical: false, from: base) else { return check(false, "pane headers: Split Down adds a pane") }
        _ = await wait(20) { third.status.integrated }
        check(history(base) == before, "a pane split down beside another keeps its history", "\(before) → \(history(base)) lines")
        c.refresh()
        let all = [base, other, third]
        check(all.allSatisfy { !header($0).isHidden }, "a split shows a header on each pane")
        check(all.allSatisfy { header($0).shownTitle == $0.title }, "each header shows its pane's title",
              all.map { "\(header($0).shownTitle) / \($0.title)" }.joined(separator: ", "))
        check(header(third).focused && !header(base).focused && !header(other).focused, "the pane with the keyboard has the stronger header")
        check(all.allSatisfy { abs(terminalTop($0) - PaneHeaderView.height - 4) < 1 }, "the header comes out of the pane's height, above its terminal's rows",
              all.map { "\(terminalTop($0))" }.joined(separator: ", "))
        check(c.groups.count == tabsBefore && c.tabBar.items[safe: c.activeIndex]?.title.hasSuffix("+2") == true,
              "the tab bar still shows one tab for the split", c.tabBar.items[safe: c.activeIndex]?.title ?? "")

        // Marks: an agent at work in one pane shows on that pane's header, not on the others'.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nt-pane-headers-\(getpid())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "#!/bin/sh\nwhile true; do printf '\\r\\342\\234\\273 Working (esc to interrupt) %s' $(date +%S); sleep 0.3; done\n"
            .write(to: dir.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        chmod(dir.appendingPathComponent("claude").path, 0o755)
        other.view.send(txt: "PATH=\(dir.path):$PATH claude\r")
        let working = await wait(5) {
            c.refresh()
            return other.status.state == .working
        }
        check(working && header(other).shownState == .working && header(base).shownState == base.status.state && base.status.state != .working,
              "a pane's header shows its own mark", "\(header(other).shownState.rawValue), \(header(base).shownState.rawValue)")
        check(header(other).shownTitle == other.title && other.title == "claude", "and its own title", header(other).shownTitle)

        // A click on a header gives that pane the keyboard.
        func mouse(_ type: NSEvent.EventType, on view: NSView, clicks: Int = 1) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: 60, y: view.bounds.midY), to: nil), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: clicks, pressure: 1)
        }
        if let down = mouse(.leftMouseDown, on: header(base)) { header(base).mouseDown(with: down) }
        check(group.focused === base && window.firstResponder === base.view && header(base).focused && !header(third).focused,
              "clicking a header gives its pane the keyboard")

        // A double-click renames the pane, as the tab bar's rename does.
        if let down = mouse(.leftMouseDown, on: header(third), clicks: 2) { header(third).mouseDown(with: down) }
        let field = header(third).subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable }
        check(header(third).isEditing && field != nil, "double-clicking a header starts a rename")
        field?.currentEditor()?.string = "api server"
        window.makeFirstResponder(nil) // ends the edit, as Return does
        c.refresh()
        check(third.userTitle == "api server" && header(third).shownTitle == "api server", "the rename names that pane", third.title)
        _ = await wait(2) { window.firstResponder === third.view }
        check(window.firstResponder === third.view, "and the keyboard goes back to it")
        c.renamePane(third, to: nil)

        // The × shows under the pointer, and closes that pane alone: an idle one at once.
        if let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) {
            header(other).mouseEntered(with: enter)
        }
        check(!header(third).closeButton.isHidden && !header(other).closeButton.isHidden && header(base).closeButton.isHidden,
              "the × shows on the pane with the keyboard and under the pointer, not on the others")
        check(header(other).closeButton.accessibilityLabel() == "Close pane \(other.title)", "VoiceOver calls it Close pane and the title",
              header(other).closeButton.accessibilityLabel() ?? "")
        c.show(third)
        window.makeFirstResponder(third.view)
        header(third).closeButton.performClick(nil)
        check(await wait(3) { !group.contains(third) } && window.attachedSheet == nil && group.panes.count == 2 && c.groups.count == tabsBefore,
              "a header's × closes only its pane, at once when nothing runs there")
        check(!header(base).isHidden && !header(other).isHidden, "the other panes keep their headers")
        check(window.firstResponder === base.view && group.focused === base, "its neighbour takes the keyboard")

        // Maximized: no header, the terminal from the top as in a tab of one pane.
        c.show(base)
        window.makeFirstResponder(base.view)
        c.toggleZoomPane(nil)
        check(group.zoomed === base && header(base).isHidden && abs(terminalTop(base) - 4) < 1, "a maximized pane has no header", "\(terminalTop(base))")
        c.toggleZoomPane(nil)
        check(group.zoomed == nil && !header(base).isHidden && !header(other).isHidden, "and the headers come back with the panes")

        // The panes built again around the pane you type in: it keeps the keyboard.
        c.equalizePanes(nil)
        check(window.firstResponder === base.view, "Make Panes Equal leaves the keyboard where it was")
        guard let beside = c.split(vertical: false, from: other, focus: false) else { return check(false, "a pane opens beside another") }
        check(window.firstResponder === base.view && group.focused === base,
              "a pane opened beside another without the keyboard (an agent's split_beside) leaves it where it was")
        _ = await wait(20) { beside.status.integrated }
        beside.view.send(txt: "\u{15}exit\r")
        check(await wait(5) { !group.contains(beside) } && window.firstResponder === base.view && group.focused === base,
              "a pane whose shell exits beside the one you type in leaves you the keyboard")
        // Maximized, on to the next pane, then all panes back: the keyboard stays with the pane you moved to.
        c.toggleZoomPane(nil)
        c.selectNextPane(nil)
        c.toggleZoomPane(nil)
        check(group.zoomed == nil && group.focused === other && window.firstResponder === other.view,
              "the pane you moved to while one was maximized keeps the keyboard when the panes come back")
        c.show(base)
        window.makeFirstResponder(base.view)

        // Something runs in it: the × asks first, as ⌘W on that pane does, and Cancel keeps it.
        header(other).closeButton.performClick(nil)
        let asked = await wait(3) { window.attachedSheet != nil }
        func buttons(_ view: NSView) -> [String] { view.subviews.flatMap { ($0 as? NSButton).map { [$0.title] } ?? buttons($0) } }
        check(asked && window.attachedSheet?.contentView.map(buttons)?.contains("Close Pane") == true,
              "a header's × asks first when something runs in its pane")
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        await pause(0.2)
        check(group.contains(other) && group.panes.count == 2, "Cancel keeps the pane")
        header(other).closeButton.performClick(nil)
        _ = await wait(3) { window.attachedSheet != nil }
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        check(await wait(3) { !group.contains(other) } && group.panes.count == 1 && c.groups.count == tabsBefore, "Close Pane closes that pane alone")
        check(window.firstResponder === base.view, "closing another pane leaves the keyboard where it was")
        check(header(base).isHidden && abs(terminalTop(base) - 4) < 1, "with one pane left, its header is gone", "\(terminalTop(base))")
    }
}
