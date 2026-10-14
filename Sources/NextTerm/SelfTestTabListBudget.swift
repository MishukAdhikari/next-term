import AppKit
import NextTermCore
import ObjectiveC
import SwiftTerm

#if DEBUG
/// The tab list's smoothness, measured against the top bar's in the same run, on the same build, in a window of its
/// own in front: an idle list does no work at all; one tab's status change touches its own row and nothing else; ⌘1
/// and ⌘2 show the selection as quickly as the bar does; a dragged row keeps up with the pointer as a dragged top tab
/// does; and the list's edge, dragged, leaves every terminal's size alone until it is let go, then changes it once.
/// Each measure writes its numbers into the report. A debug build's own counters make them, so a release build has
/// none of this.
extension SelfTest {
    static func tabListBudgetChecks(_ c: TerminalWindowController) async {
        let app: AppDelegate = AppDelegate.shared
        let defaults = UserDefaults.standard
        let saved = (tabs: app.terminalTabs, folders: app.tabListShowsFolders, blinks: defaults.object(forKey: "terminalCursorBlink"),
                     width: defaults.object(forKey: TabListWidth.lastKey), widths: defaults.object(forKey: TabListWidths.key))
        let dir = canonicalPath(NSTemporaryDirectory())
        app.moveTerminalTabs(to: .top)
        app.tabListShowsFolders = false
        // A steady cursor: a blinking one draws its terminal twice a second, which says nothing about the tabs.
        app.setTerminalCursor(blinks: false)
        let w = app.openWindow(directory: dir)
        defer {
            w.window?.close()
            app.moveTerminalTabs(to: saved.tabs)
            app.tabListShowsFolders = saved.folders
            restoreDefault(saved.blinks, "terminalCursorBlink")
            app.setTerminalCursor()
            restoreDefault(saved.width, TabListWidth.lastKey)
            restoreDefault(saved.widths, TabListWidths.key)
            c.window?.makeKeyAndOrderFront(nil)
        }
        guard let window = w.window else { return check(false, "tab list budget: its window opens") }
        // Room for twenty rows down the list and eight tabs along the bar.
        let screen: NSRect = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let size = NSSize(width: min(1200, screen.width - 40), height: min(820, screen.height - 40))
        window.setFrame(NSRect(origin: NSPoint(x: screen.minX + 20, y: screen.maxY - 20 - size.height), size: size), display: true)
        guard await bringToFront(window) else { return note("tab list budget: skipped, " + notFrontmost(window)) }
        while w.groups.count < 10 { _ = w.addTab(directory: dir, select: false) }
        for tab in w.tabs { _ = await wait(20) { tab.status.integrated } }
        w.select(0)
        window.layoutIfNeeded()
        DrawCounter.install()
        guard let barTab = w.tabBar.tabView(at: 0), BarTabCalls.install(on: barTab) else {
            return check(false, "tab list budget: the top bar's tabs are counted from outside its file",
                         "\(w.tabBar.tabView(at: 0).map { String(describing: type(of: $0)) } ?? "no tab")")
        }

        await idleBudget(w)
        await statusChangeBudget(w, dir: dir)
        await switchingBudget(w, window: window)
        await edgeDragBudget(w, side: .left)
        await edgeDragBudget(w, side: .right)
        await dragBudget(w, dir: dir)
    }

    // MARK: an idle tick

    /// With ten tabs at the prompt, five seconds of the window's tick (twenty of them) lay out neither the list nor
    /// any row, and draw no row. The top bar's tabs are counted the same way with Top, as the baseline, which is not
    /// gated: the bar's file is not the list's.
    private static func idleBudget(_ w: TerminalWindowController) async {
        let app: AppDelegate = AppDelegate.shared
        let list: TabListView = w.tabList
        app.moveTerminalTabs(to: .left)
        w.window?.layoutIfNeeded()
        await pause(3) // the quiet before
        list.resetCounters()
        await pause(5)
        let rows: [TabListRowView] = rowViews(of: list)
        let rowLayouts: Int = rows.reduce(0) { (sum: Int, row: TabListRowView) -> Int in sum + row.layoutCount }
        let rowDraws: Int = rows.reduce(0) { (sum: Int, row: TabListRowView) -> Int in sum + row.drawCount }
        let listLayouts: Int = list.layoutCount
        check(listLayouts == 0 && rowLayouts == 0 && rowDraws == 0,
              "tab list budget: 20 idle ticks with 10 tabs lay out neither the list nor a row, and draw no row",
              "\(listLayouts) list layouts, \(rowLayouts) row layouts, \(rowDraws) row draws in 5 s")

        app.moveTerminalTabs(to: .top)
        w.window?.layoutIfNeeded()
        await pause(3)
        let tabs: [NSView] = barTabViews(w)
        BarTabCalls.reset(tabs)
        await pause(5)
        note("tab list budget: idle, 10 tabs, 5 s: the list \(listLayouts) layouts, its rows \(rowLayouts) layouts and \(rowDraws) draws; "
             + "the top bar's tabs \(BarTabCalls.draws(tabs)) draws (the baseline, not gated)")
    }

    // MARK: a status change

    /// A stand-in agent in a tab behind works, then waits for you (done): its row draws twice at most (its title as the
    /// agent starts, and what follows), no other row lays out or draws, and no other tab's terminal draws.
    private static func statusChangeBudget(_ w: TerminalWindowController, dir: String) async {
        let app: AppDelegate = AppDelegate.shared
        app.moveTerminalTabs(to: .left)
        w.select(0)
        w.window?.layoutIfNeeded()
        let folder = (dir as NSString).appendingPathComponent("nextterm-tablist-agent-\(getpid())")
        let agent = (folder as NSString).appendingPathComponent("claude")
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let script = """
        #!/bin/sh
        i=0; while [ $i -lt 8 ]; do echo "thinking $i"; sleep 0.2; i=$((i+1)); done
        echo "waiting for you"; read answer
        """
        let index = 5
        let written: Bool = (try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)) != nil
            && (try? script.write(toFile: agent, atomically: true, encoding: .utf8)) != nil && chmod(agent, 0o755) == 0
        guard written, let tab = w.groups[safe: index]?.focused else { return check(false, "tab list budget: a stand-in agent to run") }
        await pause(1)
        let list: TabListView = w.tabList
        let others: [TerminalTab] = w.tabs.filter { (other: TerminalTab) -> Bool in other !== tab }
        for other in others { DrawCounter.reset(other.view) }
        list.resetCounters()
        tab.view.send(txt: "PATH=\(ShellQuote.quote(folder)):$PATH claude\r")
        let worked: Bool = await wait(5) { tab.status.state == .working }
        let done: Bool = await wait(10) { tab.status.state == .done }
        await pause(1) // what the change still lays out or draws
        let row: TabListRowView? = list.tabRowView(at: index)
        let rowDraws: Int = row?.drawCount ?? -1
        let otherRows: [TabListRowView] = rowViews(of: list).filter { (view: TabListRowView) -> Bool in view !== row }
        let otherLayouts: Int = otherRows.reduce(0) { (sum: Int, view: TabListRowView) -> Int in sum + view.layoutCount }
        let otherDraws: Int = otherRows.reduce(0) { (sum: Int, view: TabListRowView) -> Int in sum + view.drawCount }
        let terminalDraws: Int = others.reduce(0) { (sum: Int, other: TerminalTab) -> Int in sum + DrawCounter.count(other.view) }
        note("tab list budget: a tab working then done: its row \(rowDraws) draws; the other rows \(otherLayouts) layouts and "
             + "\(otherDraws) draws; the other tabs' terminals \(terminalDraws) draws")
        check(worked && done && rowDraws >= 0 && rowDraws <= 2 && otherLayouts == 0 && otherDraws == 0 && terminalDraws == 0,
              "tab list budget: a tab working then done draws its own row twice at most, and nothing else",
              "worked \(worked), done \(done) (\(tab.status.state.rawValue)); row \(rowDraws) draws, other rows \(otherLayouts) layouts and "
                + "\(otherDraws) draws, other terminals \(terminalDraws) draws")
        tab.view.send(txt: "yes\r")
        _ = await wait(5) { !tab.status.running }
    }

    // MARK: switching

    /// ⌘2 and ⌘1 as the keyboard sends them, 20 times each, with the list and then with the bar, each timed from the
    /// key to its selection drawn. The window's layout and display run at once, and Core Animation's changes go out,
    /// so each time is the strip's own work and the shown terminal's draw, not how soon the run loop came round. The
    /// list's median is within a millisecond of the bar's, and nineteen switches in twenty take under a frame (16 ms).
    private static func switchingBudget(_ w: TerminalWindowController, window: NSWindow) async {
        let app: AppDelegate = AppDelegate.shared
        var times: [TerminalTabsSetting: [TimeInterval]] = [:]
        var missed: [TerminalTabsSetting: Int] = [:]
        for tabs in [TerminalTabsSetting.left, .top] {
            app.moveTerminalTabs(to: tabs)
            w.select(0)
            window.layoutIfNeeded()
            await pause(0.5)
            var taken: [TimeInterval] = []
            var wrong = 0
            for press in 0..<40 {
                let target: Int = press % 2 == 0 ? 1 : 0
                let began: TimeInterval = ProcessInfo.processInfo.systemUptime
                keyStroke(window, code: target == 1 ? 19 : 18, .command) // ⌘2, ⌘1
                window.layoutIfNeeded()
                window.displayIfNeeded()
                CATransaction.flush()
                let shown: TimeInterval = ProcessInfo.processInfo.systemUptime
                let stripSelected: Bool = tabs == .top ? w.tabBar.selectedIndex == target : w.tabList.selectedIndex == target
                if w.activeIndex == target && stripSelected { taken.append(shown - began) } else { wrong += 1 }
                await pause(0.05) // each key from a quiet window
            }
            times[tabs] = taken
            missed[tabs] = wrong
        }
        let list: [TimeInterval] = times[.left] ?? []
        let bar: [TimeInterval] = times[.top] ?? []
        let listMedian: TimeInterval = quantile(list, 0.5)
        let barMedian: TimeInterval = quantile(bar, 0.5)
        let list95: TimeInterval = quantile(list, 0.95)
        let bar95: TimeInterval = quantile(bar, 0.95)
        let numbers = "list median \(millis(listMedian)), p95 \(millis(list95)); bar median \(millis(barMedian)), p95 \(millis(bar95)); "
            + "keys that selected nothing: list \(missed[.left] ?? 0), bar \(missed[.top] ?? 0)"
        note("tab list budget: ⌘1 and ⌘2, 20 each, key to selection drawn: " + numbers)
        let allSelected: Bool = list.count == 40 && bar.count == 40
        check(allSelected && listMedian <= barMedian + 0.001, "tab list budget: ⌘1 and ⌘2 show the list's selection within a millisecond of the bar's",
              numbers)
        check(allSelected && list95 <= 0.016, "tab list budget: 19 switches in 20 with the list take under a frame", numbers)
    }

    // MARK: the list's edge

    /// The list's edge dragged from 220 to 300 points over a second on `side` (toward the terminal: right on the left,
    /// left on the right): no terminal changes size, nor its columns, until the edge is let go; then each changes size
    /// once at most, the one in front once, and the list keeps 300.
    private static func edgeDragBudget(_ w: TerminalWindowController, side: TabListSide) async {
        let app: AppDelegate = AppDelegate.shared
        guard let window = w.window else { return }
        app.moveTerminalTabs(to: side == .left ? .left : .right)
        let list: TabListView = w.tabList
        w.tabListWillResize(list)
        w.tabList(list, didResizeTo: 220, collapsed: false)
        window.layoutIfNeeded()
        await pause(0.3)
        let terminals: [TerminalTab] = w.tabs
        let views: [NSView] = terminals.map { (tab: TerminalTab) -> NSView in tab.view }
        let columns: [Int] = terminals.map { (tab: TerminalTab) -> Int in tab.view.getTerminal().cols }
        let resizes = TerminalResizes(views)
        let divider: TabListDivider = list.divider
        let start: NSPoint = divider.convert(NSPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
        let wider: CGFloat = side == .left ? 80 : -80
        let drag = PacedDrag(in: window, from: start, to: NSPoint(x: start.x + wider, y: start.y), steps: 60)
        var resizedDuring = 0
        var columnsMoved = false
        var widest: CGFloat = 0
        drag.beforeEvent = { (_: Int) in
            resizedDuring = max(resizedDuring, resizes.most)
            widest = max(widest, list.widthConstraint.constant)
            let now: [Int] = terminals.map { (tab: TerminalTab) -> Int in tab.view.getTerminal().cols }
            if now != columns { columnsMoved = true }
        }
        let tracked: Bool = drag.run(on: divider)
        window.layoutIfNeeded()
        await pause(0.3)
        resizes.stop()
        let front: NSView? = w.activeGroup?.focused.view
        let frontOnce: Bool = front.map { (view: NSView) -> Bool in resizes.count(view) == 1 } ?? false
        let changed: Int = views.filter { (view: NSView) -> Bool in resizes.count(view) > 0 }.count
        let kept: CGFloat = w.tabListPlace.width
        let name: String = side == .left ? "left" : "right"
        let numbers = "pressed \(tracked), widest shown \(widest), kept \(kept); during the drag the most resizes \(resizedDuring), "
            + "columns moved \(columnsMoved); after it \(changed) of \(views.count) terminals changed size, the most \(resizes.most) times"
        note("tab list budget: the list's edge on the \(name) dragged from 220 to 300: " + numbers)
        check(tracked && widest >= 299 && resizedDuring == 0 && !columnsMoved,
              "tab list budget: on the \(name), the list's edge dragged changes no terminal's size or columns until it is let go", numbers)
        check(tracked && frontOnce && resizes.most == 1 && abs(kept - 300) < 1,
              "tab list budget: on the \(name), let go, each terminal changes size once at most, the one in front once, and the list keeps 300", numbers)
        w.tabListWillResize(list)
        w.tabList(list, didResizeTo: TabListWidth.defaultWidth, collapsed: false)
        window.layoutIfNeeded()
    }

    // MARK: dragging

    /// A tab's row dragged down twenty rows over a second, then a top tab across eight, each as a hand drags (an event
    /// every 1/60 s). The list takes 2 ms at most over nineteen events in twenty. For both the dragged view has its new
    /// place within 8 ms of its event nineteen times in twenty, and within a frame (16 ms) every time; the list is no
    /// more than a millisecond behind the bar. The list's times are its own drag loop's; the bar's are read off its
    /// tab's frame as it is set.
    private static func dragBudget(_ w: TerminalWindowController, dir: String) async {
        let app: AppDelegate = AppDelegate.shared
        guard let window = w.window else { return }
        var added: [TerminalTab] = []
        while w.groups.count < 20 { added.append(w.addTab(directory: dir, select: false)) }
        for tab in added { _ = await wait(20) { tab.status.integrated } }
        app.moveTerminalTabs(to: .left)
        w.select(0)
        window.layoutIfNeeded()
        await pause(1)
        let list: TabListView = w.tabList
        guard let first = list.tabRowView(at: 0), let last = list.tabRowView(at: w.groups.count - 1) else {
            return check(false, "tab list budget: twenty rows to drag across", "\(list.rows.count) rows")
        }
        let start: NSPoint = first.convert(NSPoint(x: first.bounds.midX, y: first.bounds.midY), to: nil)
        let end: NSPoint = last.convert(NSPoint(x: last.bounds.midX, y: last.bounds.midY), to: nil)
        let listDrag = PacedDrag(in: window, from: start, to: NSPoint(x: start.x, y: end.y), steps: 60)
        let listTracked: Bool = listDrag.run(on: first)
        let timings: [TabListDragTiming] = list.dragTimings
        let handling: [TimeInterval] = timings.map(\.handling)
        let listLags: [TimeInterval] = timings.map(\.lag)

        // Eight tabs on top, the first dragged across the others.
        w.select(0)
        let extra: [TerminalTab] = Array(w.groups.dropFirst(8)).map(\.focused)
        for tab in extra { w.requestClose(tab) }
        _ = await wait(3) { w.groups.count == 8 }
        _ = await endSheets(over: window)
        app.moveTerminalTabs(to: .top)
        w.select(0)
        window.layoutIfNeeded()
        await pause(1)
        let bar: TabBarView = w.tabBar
        let lastShown: Int = max(0, min(7, bar.visibleRange.upperBound - 1))
        guard let tab = bar.tabView(at: 0), let across = bar.tabView(at: lastShown), lastShown > 0 else {
            return check(false, "tab list budget: top tabs to drag across", "\(bar.items.count) tabs")
        }
        let from: NSPoint = tab.convert(NSPoint(x: tab.bounds.midX, y: tab.bounds.midY), to: nil)
        let to: NSPoint = across.convert(NSPoint(x: across.bounds.midX, y: across.bounds.midY), to: nil)
        let barDrag = PacedDrag(in: window, from: from, to: to, steps: 60)
        var barLags: [TimeInterval] = []
        BarTabCalls.framed = { (view: NSView, old: NSRect, new: NSRect) in
            guard view === tab, barDrag.dragging, old != new else { return }
            // The event being handled, when the tracking loop made it the app's current one; else the last one posted.
            let event: NSEvent? = NSApp.currentEvent
            let current: TimeInterval? = event.flatMap { (e: NSEvent) -> TimeInterval? in
                e.type == .leftMouseDragged && e.timestamp >= barDrag.pressed ? e.timestamp : nil
            }
            barLags.append(ProcessInfo.processInfo.systemUptime - (current ?? barDrag.lastPosted))
        }
        let barTracked: Bool = barDrag.run(on: tab)
        BarTabCalls.framed = nil

        let handling95: TimeInterval = quantile(handling, 0.95)
        let list95: TimeInterval = quantile(listLags, 0.95)
        let listMost: TimeInterval = listLags.max() ?? .infinity
        let bar95: TimeInterval = quantile(barLags, 0.95)
        let barMost: TimeInterval = barLags.max() ?? .infinity
        let numbers = "the list over \(timings.count) events: handling p95 \(millis(handling95)), lag p95 \(millis(list95)), max \(millis(listMost)); "
            + "the bar over \(barLags.count) (across \(lastShown + 1) tabs): lag p95 \(millis(bar95)), max \(millis(barMost))"
        note("tab list budget: dragging, " + numbers)
        let listMeasured: Bool = listTracked && timings.count >= 30
        let barMeasured: Bool = barTracked && barLags.count >= 20
        check(listMeasured && handling95 <= 0.002, "tab list budget: 19 drag events in 20 take the list 2 ms at most", numbers)
        check(listMeasured && list95 <= 0.008 && listMost <= 0.016,
              "tab list budget: a dragged row is in its place within 8 ms of its event 19 times in 20, and within a frame every time", numbers)
        check(barMeasured && bar95 <= 0.008 && barMost <= 0.016,
              "tab list budget: so is a dragged top tab", numbers)
        check(listMeasured && barMeasured && list95 <= bar95 + 0.001,
              "tab list budget: a dragged row keeps up with the pointer within a millisecond of a dragged top tab", numbers)
    }

    // MARK: helpers

    private static func rowViews(of list: TabListView) -> [TabListRowView] {
        (0..<list.rows.count).compactMap { (index: Int) -> TabListRowView? in list.rowView(at: index) }
    }

    private static func barTabViews(_ w: TerminalWindowController) -> [NSView] {
        (0..<w.tabBar.items.count).compactMap { (index: Int) -> NSView? in w.tabBar.tabView(at: index) }
    }

    /// The value at fraction `p` of the sorted values (0.5 the median, 0.95 where the slowest twentieth starts);
    /// infinity for none, which no budget passes.
    private static func quantile(_ values: [TimeInterval], _ p: Double) -> TimeInterval {
        guard !values.isEmpty else { return .infinity }
        let sorted: [TimeInterval] = values.sorted()
        let rank: Int = Int((Double(sorted.count - 1) * p).rounded(.up))
        return sorted[min(rank, sorted.count - 1)]
    }

    private static func millis(_ seconds: TimeInterval) -> String {
        seconds.isFinite ? String(format: "%.2f ms", seconds * 1000) : "none"
    }

    /// A key down as the keyboard sends it: made from a CGEvent, so AppKit reads its characters off the keyboard layout as
    /// it does a real key's, and sent to the app, which gives the menus their keys first.
    private static func keyStroke(_ window: NSWindow, code: UInt16, _ flags: NSEvent.ModifierFlags) {
        let masks: [(NSEvent.ModifierFlags, CGEventFlags)] = [(.command, .maskCommand), (.shift, .maskShift), (.option, .maskAlternate),
                                                              (.control, .maskControl)]
        guard let key = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: true) else { return }
        key.flags = CGEventFlags(masks.filter { flags.contains($0.0) }.map(\.1))
        guard let event = NSEvent(cgEvent: key) else { return }
        NSApp.sendEvent(event)
    }
}

/// A drag as a hand makes one: the press, then one drag event every 1/60 s, each stamped with the moment it is posted,
/// then the release, all from a timer that runs while the pressed view's tracking loop waits for them. Queued at once,
/// as a click's drags are, they would be taken as fast as the loop can go, and every lag would be the time spent
/// behind the others.
@MainActor final class PacedDrag: NSObject {
    static let rate: Double = 60
    private let window: NSWindow
    private let start: NSPoint
    private let end: NSPoint
    private let steps: Int
    /// Before each drag event is posted, with its number from 1, and once more before the release.
    var beforeEvent: ((Int) -> Void)?
    /// When the press was made, and the last event posted.
    private(set) var pressed: TimeInterval = 0
    private(set) var lastPosted: TimeInterval = 0
    /// The drag events are still coming: from the press until the release is posted.
    private(set) var dragging = false
    private var step = 0
    private var timer: Timer?
    private var released = false

    init(in window: NSWindow, from start: NSPoint, to end: NSPoint, steps: Int) {
        self.window = window
        self.start = start
        self.end = end
        self.steps = max(1, steps)
    }

    private func event(_ type: NSEvent.EventType, at location: NSPoint) -> NSEvent? {
        lastPosted = ProcessInfo.processInfo.systemUptime
        return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: lastPosted, windowNumber: window.windowNumber,
                                  context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
    }

    /// Presses `view` at the start, and returns once its tracking loop has taken the release: true then. A view that
    /// tracks nothing returns at once, before the release: false, and the events not taken are dropped.
    func run(on view: NSView) -> Bool {
        guard let down = event(.leftMouseDown, at: start) else { return false }
        pressed = lastPosted
        dragging = true
        let ticker = Timer(timeInterval: 1 / Self.rate, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer = ticker
        RunLoop.main.add(ticker, forMode: .common) // the tracking loop runs the run loop in its own mode
        view.mouseDown(with: down)
        let tracked = released
        stop()
        while NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantPast, inMode: .default, dequeue: true) != nil {}
        return tracked
    }

    @objc private func tick() {
        step += 1
        beforeEvent?(step)
        guard step > steps else {
            let f: CGFloat = CGFloat(step) / CGFloat(steps)
            let location = NSPoint(x: start.x + (end.x - start.x) * f, y: start.y + (end.y - start.y) * f)
            if let drag = event(.leftMouseDragged, at: location) { NSApp.postEvent(drag, atStart: false) }
            return
        }
        stop()
        if let up = event(.leftMouseUp, at: end) { NSApp.postEvent(up, atStart: false) }
        released = true
    }

    private func stop() {
        dragging = false
        timer?.invalidate()
        timer = nil
    }
}

/// The top bar's tab view, timed and counted from outside the bar's file, which has no counters: its draws (its class
/// draws itself, and only its own method is wrapped), and the moments its frame is set (its class sets none of its
/// own, so one is added that calls NSView's: wrapping NSView's own would time every view in the app). Installed once,
/// for the rest of the run.
@MainActor enum BarTabCalls {
    private static var installedOn: ObjectIdentifier?
    private static var drawCounts: [ObjectIdentifier: Int] = [:]
    /// After a bar tab's frame is set: the tab, its frame before and the one set.
    static var framed: ((NSView, NSRect, NSRect) -> Void)?

    static func install(on tab: NSView) -> Bool {
        let tabClass: AnyClass = type(of: tab)
        if let installedOn { return installedOn == ObjectIdentifier(tabClass) }
        let draw = #selector(NSView.draw(_:))
        let setFrame = #selector(setter: NSView.frame)
        guard let parent = class_getSuperclass(tabClass), let ownDraw = class_getInstanceMethod(tabClass, draw),
              ownDraw != class_getInstanceMethod(parent, draw), let inheritedFrame = class_getInstanceMethod(parent, setFrame),
              class_getInstanceMethod(tabClass, setFrame) == inheritedFrame else { return false }
        typealias RectCall = @convention(c) (NSView, Selector, NSRect) -> Void
        let drawn = unsafeBitCast(method_getImplementation(ownDraw), to: RectCall.self)
        let counting: @convention(block) (NSView, NSRect) -> Void = { view, rect in
            MainActor.assumeIsolated { drawCounts[ObjectIdentifier(view), default: 0] += 1 }
            drawn(view, draw, rect)
        }
        let setInherited = unsafeBitCast(method_getImplementation(inheritedFrame), to: RectCall.self)
        let timing: @convention(block) (NSView, NSRect) -> Void = { view, frame in
            let old: NSRect = view.frame
            setInherited(view, setFrame, frame)
            MainActor.assumeIsolated { framed?(view, old, frame) }
        }
        guard class_addMethod(tabClass, setFrame, imp_implementationWithBlock(timing), method_getTypeEncoding(inheritedFrame)) else { return false }
        method_setImplementation(ownDraw, imp_implementationWithBlock(counting))
        installedOn = ObjectIdentifier(tabClass)
        return true
    }

    static func reset(_ views: [NSView]) {
        for view in views { drawCounts[ObjectIdentifier(view)] = 0 }
    }

    static func draws(_ views: [NSView]) -> Int {
        views.reduce(0) { (sum: Int, view: NSView) -> Int in sum + (drawCounts[ObjectIdentifier(view)] ?? 0) }
    }
}
#endif
