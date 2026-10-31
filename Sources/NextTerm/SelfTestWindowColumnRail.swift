import AppKit
import NextTermCore

#if DEBUG
/// The window column folded to its rail (plan 030). Part of NEXTTERM_SELFTEST_ONLY=windowColumn.
extension SelfTest {
    /// The rail's form; the pointer passing over it opens nothing; resting on it slides the list out over the content
    /// without moving the content or taking the keyboard; going from the rail onto the list keeps it, leaving both closes
    /// it; the list's foot says how to hide the column; a double-click pins the column unfolded and folds it back; with
    /// Reduce Motion the list shows at once. `others`: the other windows, whose rows the list shows.
    static func railChecks(_ app: AppDelegate, _ c: TerminalWindowController, others: [TerminalWindowController]) async {
        guard let window = c.window else { return }
        let host: WindowColumnHost = c.columnHost
        let column: WindowColumnView = host.column
        let saved: (open: TimeInterval, close: TimeInterval) = (WindowColumnRail.openDelay, WindowColumnRail.closeDelay)
        let motion: () -> Bool = WindowColumnHost.reducesMotion
        defer {
            WindowColumnRail.openDelay = saved.open
            WindowColumnRail.closeDelay = saved.close
            WindowColumnHost.reducesMotion = motion
            host.hideList(animated: false)
            app.windowColumnExpanded = false
        }
        app.windowColumnExpanded = false
        _ = await bringToFront(window)
        window.layoutIfNeeded()

        // At rest: 24 points and its hairline, a place of 24 points per window, no chevron.
        let places: [CGFloat] = column.shownButtons.map(\.frame.height)
        check(column.frame.width == WindowColumnWidth.folded + WindowColumnWidth.hairline && column.chevronButton.isHidden
                && !places.isEmpty && places.allSatisfy { $0 == WindowColumnRail.slot } && column.shownButtons.count == column.list.count
                && Set(([c] + others).map(\.indexID)).isSubset(of: Set(column.shownButtons.map(\.id))),
              "window column: folded, it rests as a 24-point rail, a place per window, with no chevron",
              "width \(column.frame.width), places \(places), chevron hidden \(column.chevronButton.isHidden)")
        await screenshot(c, suffix: "-rail")

        // Passing over it opens nothing.
        WindowColumnRail.openDelay = 0.35
        WindowColumnRail.closeDelay = 0.3
        let content: NSRect = host.content.frame
        let keyboard: NSResponder? = window.firstResponder
        column.onPointer?(true)
        await pause(0.15)
        column.onPointer?(false)
        await pause(0.6)
        check(!host.listShowing, "window column: the pointer passing over the rail opens nothing")

        // Resting on it slides the list out over the content: as tall as the window, beside the rail, the content and the
        // keyboard where they were.
        column.onPointer?(true)
        let opened: Bool = await wait(2) { host.listShowing }
        await pause(0.3) // the slide
        let list: WindowColumnView? = host.list
        let frame: NSRect = list?.frame ?? .zero
        let rows: Int = list?.shownButtons.count ?? 0
        let foot: String = list?.hideButton.title ?? ""
        let key: String = KeyboardShortcuts.shared.chord(for: "toggleWindowColumn:")?.display ?? ""
        check(opened && frame.minX == column.frame.maxX && frame.width == WindowColumnRail.listWidth + WindowColumnWidth.hairline
                && frame.height == host.bounds.height && list?.alphaValue == 1 && rows == column.list.count && list?.chevronButton.isHidden == true
                && host.content.frame == content && window.firstResponder === keyboard,
              "window column: resting on the rail slides the list out over the content, a row per window and no chevron, without moving the content or taking the keyboard",
              "open \(opened), list \(frame), rows \(rows), content \(content) → \(host.content.frame), keyboard kept \(window.firstResponder === keyboard)")
        check(list?.hideButton.isHidden == false && foot.hasPrefix("Hide window column") && (key.isEmpty || foot.hasSuffix(key)),
              "window column: the list's foot says how to hide the column, with its key", foot)
        await screenshot(c, suffix: "-rail-list")

        // Escape closes it, and still reaches the terminal: the list never takes a key.
        let escape: NSEvent? = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
        if let escape { NSApp.postEvent(escape, atStart: false) }
        let escaped: Bool = await wait(2) { !host.listShowing }
        check(escaped && window.firstResponder === keyboard, "window column: Escape closes the list, the keyboard where it was")
        column.onPointer?(false)
        column.onPointer?(true)
        _ = await wait(2) { host.listShowing }

        // From the rail onto the list: it stays. Off both: it goes.
        column.onPointer?(false)
        list?.onPointer?(true)
        await pause(0.6)
        let kept: Bool = host.listShowing
        list?.onPointer?(false)
        let closed: Bool = await wait(2) { !host.listShowing }
        check(kept && closed, "window column: moving from the rail onto the list keeps it, and leaving both closes it",
              "kept \(kept), closed \(closed)")

        // A click on a dot ends the hover: no list slides out after it in the window just left.
        column.onPointer?(true)
        host.chose()
        await pause(0.6)
        check(!host.listShowing, "window column: choosing a window on the rail opens no list after the click")
        column.onPointer?(false)

        // A double-click on the rail's empty space pins the column unfolded, and on the unfolded column folds it back.
        func doubleClick(_ view: NSView) {
            let point: NSPoint = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.maxY - 6), to: nil)
            let event: NSEvent? = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2,
                                                     pressure: 1)
            if let event { view.mouseDown(with: event) }
        }
        doubleClick(column)
        let pinned: Bool = await wait(2) { app.windowColumnExpanded && host.shown.form == .expanded }
        doubleClick(column)
        let folded: Bool = await wait(2) { !app.windowColumnExpanded && host.shown.form == .folded }
        check(pinned && folded, "window column: a double-click on the rail pins it unfolded, and another folds it back",
              "pinned \(pinned), folded \(folded)")

        // Reduce Motion: the list shows whole at once.
        WindowColumnHost.reducesMotion = { true }
        host.showList()
        let instant: Bool = host.listShowing && host.list?.alphaValue == 1 && host.list?.frame.minX == column.frame.maxX
        host.hideList(animated: true)
        check(instant && !host.listShowing, "window column: with Reduce Motion the list shows and goes at once")
    }
}
#endif
