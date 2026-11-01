import AppKit
import NextTermCore

#if DEBUG
/// The window column folded to its rail (plan 030) and the list it opens on one grid with it (plan 031). Part of
/// NEXTTERM_SELFTEST_ONLY=windowColumn.
extension SelfTest {
    /// The rail's form; the pointer passing over it opens nothing; resting on it opens the list over the rail and the
    /// content, its dots, count and well on the rail's own, without moving the content or taking the keyboard, VoiceOver
    /// hearing the windows once; going from the rail onto the list keeps it, leaving both closes it; the list's foot says
    /// how to hide the column; a pointer at rest as the window comes forward opens nothing until it moves; a double-click
    /// pins the column unfolded and folds it back, and folded under the pointer it opens nothing until the pointer leaves;
    /// with Reduce Motion the list shows at once. `others`: the other windows, whose rows the list shows.
    static func railChecks(_ app: AppDelegate, _ c: TerminalWindowController, others: [TerminalWindowController]) async {
        guard let window = c.window else { return }
        let host: WindowColumnHost = c.columnHost
        let column: WindowColumnView = host.column
        let saved: (open: TimeInterval, close: TimeInterval) = (WindowColumnRail.openDelay, WindowColumnRail.closeDelay)
        let motion: () -> Bool = WindowColumnHost.reducesMotion
        let pointer: () -> NSPoint = WindowColumnHost.pointerLocation
        defer {
            WindowColumnRail.openDelay = saved.open
            WindowColumnRail.closeDelay = saved.close
            WindowColumnHost.reducesMotion = motion
            WindowColumnHost.pointerLocation = pointer
            host.hideList(animated: false)
            app.windowColumnExpanded = false
        }
        app.windowColumnExpanded = false
        // The real pointer may rest anywhere while the run is unattended: the checks drive the pointer's comings and goings
        // themselves, so it stands far off the screen, where it is on no list.
        WindowColumnHost.pointerLocation = { NSPoint(x: -100_000, y: -100_000) }
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

        // Resting on it opens the list over the rail and the content: as tall as the window, from the window's edge, the
        // content and the keyboard where they were.
        column.onPointer?(true)
        let opened: Bool = await wait(2) { host.listShowing }
        await pause(0.3) // the reveal
        let list: WindowColumnView? = host.list
        let frame: NSRect = host.listShade?.frame ?? .zero
        let rows: Int = list?.shownButtons.count ?? 0
        let foot: String = list?.hideButton.shownWords ?? ""
        let key: String = KeyboardShortcuts.shared.chord(for: "toggleWindowColumn:")?.display ?? ""
        let full: CGFloat = WindowColumnRail.listWidth + WindowColumnWidth.hairline
        check(opened && frame.minX == column.frame.minX && frame.width == full && list?.frame.width == full
                && frame.height == host.bounds.height && rows == column.list.count && list?.chevronButton.isHidden == true
                && host.content.frame == content && window.firstResponder === keyboard,
              "window column: resting on the rail opens the list over the rail and the content, a row per window and no chevron, without moving the content or taking the keyboard",
              "open \(opened), list \(frame), rows \(rows), content \(content) → \(host.content.frame), keyboard kept \(window.firstResponder === keyboard)")
        check(list?.hideButton.isHidden == false && foot == "Hide Column" + (key.isEmpty ? "" : "  " + key),
              "window column: the list's foot says how to hide the column, with its key", foot)
        // One grid: each window's dot, the count and this window's well lie where the rail has them, in the window.
        var moved: [String] = []
        if let list {
            for rail in column.shownButtons {
                guard let row = list.button(for: rail.id) else {
                    moved.append("\(rail.id) not listed")
                    continue
                }
                let railDot: NSRect = rail.convert(rail.dotForTest, to: nil)
                let listDot: NSRect = row.convert(row.dotForTest, to: nil)
                if railDot != listDot { moved.append("\(rail.id) dot \(railDot) → \(listDot)") }
                let railWell: NSRect = rail.convert(rail.plateForTest, to: nil)
                let listWell: NSRect = row.convert(row.plateForTest, to: nil)
                if rail.isCurrent, railWell.minX != listWell.minX || railWell.minY != listWell.minY || railWell.height != listWell.height {
                    moved.append("well \(railWell) → \(listWell)")
                }
            }
            let railCount: NSRect = column.convert(column.countFrame, to: nil)
            let listCount: NSRect = list.convert(list.countFrame, to: nil)
            if railCount != listCount { moved.append("count \(railCount) → \(listCount)") }
        }
        check(list != nil && moved.isEmpty, "window column: the list lies on the rail's grid, every dot, the count and this window's well where the rail has them",
              moved.joined(separator: "; "))
        // VoiceOver hears each window once: in the list, not under it on the rail.
        let railHeard: Int = column.accessibilityChildren()?.count ?? -1
        let listHeard: Int = list?.accessibilityChildren()?.count ?? 0
        check(railHeard == 0 && listHeard >= column.list.count, "window column: while the list covers the rail, VoiceOver hears the windows in the list only",
              "rail \(railHeard), list \(listHeard)")
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

        // A click on a dot ends the hover: no list opens after it in the window just left.
        column.onPointer?(true)
        host.chose()
        await pause(0.6)
        check(!host.listShowing && (column.accessibilityChildren()?.count ?? 0) > 0,
              "window column: choosing a window on the rail opens no list after the click, and the rail is heard again")
        column.onPointer?(false)

        // The window comes forward with the pointer at rest on its rail, as one brought forward from another window's list
        // does: nothing opens until the pointer moves.
        let onRailPoint: NSPoint = window.convertPoint(toScreen: column.convert(NSPoint(x: column.bounds.midX, y: column.bounds.midY), to: nil))
        WindowColumnHost.pointerLocation = { onRailPoint }
        host.cameForward()
        column.onPointer?(true)
        await pause(0.6)
        let heldStill: Bool = !host.listShowing && host.heldAt != nil
        WindowColumnHost.pointerLocation = { NSPoint(x: onRailPoint.x, y: onRailPoint.y - 6) }
        column.onMoved?()
        let openedOnMove: Bool = await wait(2) { host.listShowing }
        check(heldStill && openedOnMove, "window column: a pointer at rest on the rail as its window comes forward opens nothing until it moves",
              "held \(heldStill), opened once moved \(openedOnMove)")
        host.hideList(animated: false)
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
        // Folded under the pointer: the list it would open is the column just folded, so nothing opens until the pointer
        // leaves the column once.
        let waited: Bool = host.waitsForExit
        column.onPointer?(true)
        await pause(0.6)
        let stayedShut: Bool = !host.listShowing
        column.onPointer?(false)
        column.onPointer?(true)
        let reopened: Bool = await wait(2) { host.listShowing }
        check(waited && stayedShut && reopened, "window column: folded under the pointer, it opens no list until the pointer has left the column",
              "waits \(waited), shut \(stayedShut), opens after leaving \(reopened)")
        host.hideList(animated: false)
        column.onPointer?(false)
        WindowColumnHost.pointerLocation = { NSPoint(x: -100_000, y: -100_000) }

        // Reduce Motion: the list shows whole at once.
        WindowColumnHost.reducesMotion = { true }
        host.showList()
        let instant: Bool = host.listShowing && host.listShade?.frame.width == full && host.listShade?.frame.minX == column.frame.minX
        host.hideList(animated: true)
        check(instant && !host.listShowing, "window column: with Reduce Motion the list shows and goes at once")
    }
    /// Two windows of one name: told apart by what is in front in them, which shows only after it has held for a second
    /// (WindowColumns.detailHold), so a command that comes and goes in a title never flashes beside a name, and is drawn
    /// unfolded after the name, dimmer. `plain`: a window with no project, whose folder a second window then opens too.
    static func detailChecks(_ app: AppDelegate, _ plain: TerminalWindowController, open: () async -> TerminalWindowController?,
                             close: (TerminalWindowController) async -> Void) async {
        guard let twin = await open() else { return check(false, "window column: a second window opens in the same folder") }
        guard let tab = plain.activeTab else { return check(false, "window column: the folder's window has a tab") }
        defer { tab.userTitle = nil }
        app.refreshWindowIndex()
        let column: WindowColumnView = plain.windowColumn
        func detail(_ c: TerminalWindowController) -> String? { column.button(for: c.indexID)?.row?.detail }
        let same: Bool = column.button(for: plain.indexID)?.row?.name == column.button(for: twin.indexID)?.row?.name
        let none: Bool = detail(plain) == nil && detail(twin) == nil
        // What is in front changes: held a second, then shown beside the name.
        tab.userTitle = "build"
        app.refreshWindowIndex()
        await pause(0.3)
        let heldBack: Bool = detail(plain) == nil
        let shown: Bool = await wait(3) { detail(plain) == "build" }
        let twinPlain: Bool = detail(twin) == nil
        check(same && none && heldBack && shown && twinPlain,
              "window column: two windows of one name are told apart by what is in front in them, shown once it has held a second",
              "same name \(same), none at first \(none), held \(heldBack), shown \(shown) (\(detail(plain) ?? "none")), the other \(detail(twin) ?? "none")")
        // A quick one, there and gone within the second: nothing drawn.
        column.resetCounters()
        tab.userTitle = "ls"
        app.refreshWindowIndex()
        await pause(0.3)
        tab.userTitle = "build"
        app.refreshWindowIndex()
        await pause(1.5)
        let drawn: Int = column.button(for: plain.indexID)?.configureCount ?? -1
        check(drawn == 0 && detail(plain) == "build", "window column: a title that comes and goes within a second changes no row",
              "configured \(drawn), detail \(detail(plain) ?? "none")")
        // Unfolded, the detail after the name.
        app.windowColumnExpanded = true
        plain.window?.layoutIfNeeded()
        await screenshot(plain, suffix: "-column-details")
        app.windowColumnExpanded = false
        await close(twin)
        app.refreshWindowIndex()
        let alone: Bool = await wait(3) { detail(plain) == nil }
        check(alone, "window column: alone with its name again, the window shows no detail")
    }
}
#endif
