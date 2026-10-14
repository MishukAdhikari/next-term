import AppKit
import NextTermCore

/// The top bar's numbers for dragging a tab, kept in one place so the list's drag stays as the bar's is: it starts
/// once the pointer has moved 4 points, the dragged tab shows at 0.85 above the others, they slide aside in 0.12
/// seconds, and the drop settles in 0.1.
enum TabListMotion {
    static let dragThreshold: CGFloat = 4
    static let draggedAlpha: CGFloat = 0.85
    static let draggedZ: CGFloat = 10
    static let slide: TimeInterval = 0.12
    static let settle: TimeInterval = 0.1
    /// How often a drag held near the list's top or bottom scrolls it on: once a frame.
    static let autoscrollPeriod: TimeInterval = 1.0 / 60
}

/// A tab's row being dragged up or down the list, with its pane rows.
struct TabListRowDrag {
    /// The tab's place when pressed, and the place it would drop into now.
    let from: Int
    var to: Int
    /// The dragged rows (the tab's, then its panes'), and each one's distance below the tab's row.
    let block: Range<Int>
    let offsets: [CGFloat]
    /// How far below the tab row's top the pointer pressed.
    let grab: CGFloat
    /// The pointer in the window, as last seen: a scroll moves the rows under a pointer held still.
    var pointer: NSPoint
    /// Periodic events run only while the pointer is near the list's top or bottom.
    var autoscrolling = false
}

/// The list's edge being dragged.
struct TabListWidthDrag {
    /// Where it was pressed, across the window, and how wide the list showed then.
    let pressX: CGFloat
    let pressWidth: CGFloat
    /// The width the list opens at: kept when the drag leaves it collapsed.
    let openWidth: CGFloat
    /// The widest the terminal beside it leaves room for.
    let widest: CGFloat
    /// How the list shows now.
    var shown: TabListWidth.Drag
    /// The window holds the terminals' width from the first move until the edge is let go.
    var held = false
}

#if DEBUG
/// One event of a tab's drag, for the self-test's smoothness budget: how long the list took over it, and how long
/// after the event's own timestamp the dragged row had its new frame, in seconds.
struct TabListDragTiming {
    let handling: TimeInterval
    let lag: TimeInterval
}
#endif

// MARK: reordering

extension TabListView {
    /// A tab's row dragged up or down reorders the tabs, as the top bar's tabs drag sideways: nothing until the
    /// pointer has moved 4 points; then the row follows it with its pane rows, the other tabs slide aside, the list
    /// scrolls while the pointer is held near its top or bottom, and updates that arrive meanwhile wait for the
    /// drop. The collapsed column does not drag: its marks only select.
    func trackDrag(of view: TabListRowView, from event: NSEvent) {
        guard let window, !isCollapsed, !view.isPane, tabRows.count > 1 else { return }
        let press: NSPoint = event.locationInWindow
        var started = false
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp, .periodic], timeout: .infinity,
                           mode: .eventTracking) { (event: NSEvent?, stop: UnsafeMutablePointer<ObjCBool>) in
            guard let event, event.type != .leftMouseUp else {
                stop.pointee = true
                return
            }
            if event.type == .periodic {
                self.autoscrollDrag()
                return
            }
            if !started {
                guard abs(event.locationInWindow.y - press.y) >= TabListMotion.dragThreshold else { return }
                guard self.startDrag(of: view, pressedAt: press) else {
                    stop.pointee = true
                    return
                }
                started = true
            }
            self.dragMoved(event)
        }
        if started { dropDrag() }
    }

    /// The pointer's height in the rows' document.
    private func documentY(_ windowPoint: NSPoint) -> CGFloat { document.convert(windowPoint, from: nil).y }

    /// Lifts the row and its panes' rows, from where they are laid out now.
    private func startDrag(of view: TabListRowView, pressedAt press: NSPoint) -> Bool {
        layoutSubtreeIfNeeded() // a selection made by the press is laid out first
        let layout: TabListLayout = rowLayout
        guard let row = rowViews.firstIndex(where: { $0 === view }), tabOfRow.indices.contains(row),
              layout.frames.count == rowViews.count else { return false }
        let tab: Int = tabOfRow[row]
        guard layout.blocks.indices.contains(tab), layout.blocks[tab].lowerBound == row else { return false }
        let block: Range<Int> = layout.blocks[tab]
        let top: CGFloat = layout.frames[row].minY
        let offsets: [CGFloat] = block.map { (index: Int) -> CGFloat in layout.frames[index].minY - top }
        let grab: CGFloat = min(max(documentY(press) - top, 0), layout.frames[row].height)
        rowDrag = TabListRowDrag(from: tab, to: tab, block: block, offsets: offsets, grab: grab, pointer: press)
        for index in block { rowViews[index].isDragging = true }
        #if DEBUG
        dragTimings = []
        #endif
        return true
    }

    private func dragMoved(_ event: NSEvent) {
        #if DEBUG
        let began: TimeInterval = ProcessInfo.processInfo.systemUptime
        #endif
        rowDrag?.pointer = event.locationInWindow
        placeDraggedRows()
        updateAutoscroll()
        #if DEBUG
        let ended: TimeInterval = ProcessInfo.processInfo.systemUptime
        dragTimings.append(TabListDragTiming(handling: ended - began, lag: ended - event.timestamp))
        #endif
    }

    /// The dragged rows under the pointer, kept over the list's rows; when the place the tab would drop into
    /// changes, the other tabs slide aside to leave it open.
    private func placeDraggedRows() {
        guard var drag = rowDrag else { return }
        let layout: TabListLayout = rowLayout
        let range: ClosedRange<CGFloat> = layout.dragRange(tab: drag.from)
        let wanted: CGFloat = documentY(drag.pointer) - drag.grab
        let top: CGFloat = min(max(wanted, range.lowerBound), range.upperBound)
        for (offset, index) in zip(drag.offsets, drag.block) where rowViews.indices.contains(index) {
            rowViews[index].frame.origin.y = top + offset
        }
        let height: CGFloat = layout.blockFrame(tab: drag.from).height
        let target: Int = layout.dropIndex(dragged: drag.from, centreY: top + height / 2)
        guard target != drag.to else { return }
        drag.to = target
        rowDrag = drag
        slideRows(to: layout.frames(movingTab: drag.from, to: target), except: drag.block)
    }

    /// The rows not dragged, to their places around the dragged tab's new one; only those that move.
    private func slideRows(to frames: [CGRect], except block: Range<Int>) {
        let views: [TabListRowView] = rowViews
        NSAnimationContext.runAnimationGroup { (context: NSAnimationContext) in
            context.duration = TabListMotion.slide
            for (index, view) in views.enumerated() where !block.contains(index) && frames.indices.contains(index) {
                if view.frame != frames[index] { view.animator().frame = frames[index] }
            }
        }
    }

    /// Periodic events, which scroll the list on, run only while the pointer is near its top or bottom: a drag held
    /// still anywhere else costs nothing.
    private func updateAutoscroll() {
        guard let drag = rowDrag else { return }
        let visible: NSRect = scrollView.contentView.bounds
        let speed: CGFloat = rowLayout.autoscrollSpeed(pointerY: documentY(drag.pointer), visible: visible)
        let wanted: Bool = speed != 0
        guard wanted != drag.autoscrolling else { return }
        rowDrag?.autoscrolling = wanted
        if wanted {
            NSEvent.startPeriodicEvents(afterDelay: 0, withPeriod: TabListMotion.autoscrollPeriod)
        } else {
            NSEvent.stopPeriodicEvents()
        }
    }

    /// One step of the scroll while the pointer is held near the list's top or bottom: the rows move up or down
    /// under it, and the dragged ones stay with the pointer.
    private func autoscrollDrag() {
        guard let drag = rowDrag else { return }
        let clip: NSClipView = scrollView.contentView
        if let top = rowLayout.autoscrolled(pointerY: documentY(drag.pointer), visible: clip.bounds) {
            clip.setBoundsOrigin(NSPoint(x: 0, y: top))
            scrollView.reflectScrolledClipView(clip)
            placeDraggedRows()
        }
        updateAutoscroll()
    }

    /// The drop: the dragged tab settles into its place, and the window moves it there, once. A tab opened or
    /// closed meanwhile drops the move, as on the top bar: the places no longer mean what they did.
    private func dropDrag() {
        guard let drag = rowDrag else { return }
        if drag.autoscrolling { NSEvent.stopPeriodicEvents() }
        rowDrag = nil
        let dragged: [TabListRowView] = drag.block.compactMap { (index: Int) -> TabListRowView? in rowViews[safe: index] }
        dragged.forEach { $0.isDragging = false }
        let pending: Update? = pendingUpdate
        pendingUpdate = nil
        let pendingTabs: Int? = pending.map { (update: Update) -> Int in update.rows.filter { !$0.isPane }.count }
        if let pending, pendingTabs != tabRows.count {
            apply(pending)
            needsLayout = true
            return
        }
        let settled: [CGRect] = rowLayout.frames(movingTab: drag.from, to: drag.to)
        let places: [CGRect] = drag.block.compactMap { (index: Int) -> CGRect? in settled[safe: index] }
        settle(dragged, at: places)
        if drag.to != drag.from {
            delegate?.tabList(self, didMove: drag.from, to: drag.to) // which feeds the list its rows in the new order
            needsLayout = true
        } else if let pending {
            apply(pending)
        }
    }

    private func apply(_ update: Update) {
        self.update(rows: update.rows, selectedIndex: update.selectedIndex, density: update.density, collapsed: update.collapsed)
    }

    /// The dropped rows into their places: in 0.1 seconds, as on the top bar, or at once under Reduce Motion.
    private func settle(_ views: [TabListRowView], at frames: [CGRect]) {
        if AgentSpinner.reducesMotion {
            for (view, frame) in zip(views, frames) { view.frame = frame }
            return
        }
        NSAnimationContext.runAnimationGroup { (context: NSAnimationContext) in
            context.duration = TabListMotion.settle
            for (view, frame) in zip(views, frames) { view.animator().frame = frame }
        }
    }
}

// MARK: the width

extension TabListView {
    /// The edge dragged: the list's width follows the pointer between 160 and 400 points, no wider than the terminal
    /// beside it leaves room for, and snaps to the column of marks in past 120, all shown as it goes. From the first
    /// move the window holds the terminals' width, so the list is drawn over the terminal's edge as it widens, and
    /// gives them the rest when the edge is let go: they change size once.
    func trackWidthDrag(from event: NSEvent) {
        guard let window else { return }
        let paneWidth: CGFloat = superview?.bounds.width ?? 0
        let pressWidth: CGFloat = isCollapsed ? TabListWidth.collapsedWidth : bounds.width
        let shown: TabListWidth.Drag = isCollapsed ? .collapsed : .width(bounds.width)
        widthDrag = TabListWidthDrag(pressX: event.locationInWindow.x, pressWidth: pressWidth, openWidth: openWidth,
                                     widest: TabListWidth.widest(paneWidth: paneWidth), shown: shown)
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity,
                           mode: .eventTracking) { (event: NSEvent?, stop: UnsafeMutablePointer<ObjCBool>) in
            guard let event, event.type == .leftMouseDragged else {
                stop.pointee = true
                return
            }
            self.resize(toPointerAt: event.locationInWindow.x)
        }
        endWidthDrag()
    }

    private func resize(toPointerAt x: CGFloat) {
        guard var drag = widthDrag else { return }
        let next: TabListWidth.Drag = TabListWidth.dragged(from: drag.pressWidth, by: x - drag.pressX, side: side, widest: drag.widest)
        // Off the edge's strip the cursor would go back to the arrow, or the terminal's I-beam.
        let cursor: TabListCursor = TabListWidth.cursor(width: next.shownWidth, collapsed: next == .collapsed, side: side, widest: drag.widest)
        TabListDivider.cursor(cursor).set()
        guard next != drag.shown else { return }
        if !drag.held {
            drag.held = true
            delegate?.tabListWillResize(self) // the terminals keep their width until the edge is let go
        }
        drag.shown = next
        widthDrag = drag
        widthConstraint.constant = next.shownWidth
        showsCollapsed(next == .collapsed)
    }

    /// Let go: the window keeps the width, and the collapsed form if the drag snapped it, and gives the terminals
    /// what is left.
    private func endWidthDrag() {
        guard let drag = widthDrag else { return }
        widthDrag = nil
        divider.refreshCursor()
        guard drag.held else { return } // pressed and let go: nothing changed
        let kept: (width: CGFloat, collapsed: Bool) = drag.shown.kept(openWidth: drag.openWidth)
        openWidth = kept.width
        delegate?.tabList(self, didResizeTo: kept.width, collapsed: kept.collapsed)
    }
}

/// The list's edge where it meets the terminal, a 5-point strip inside it: dragged, it sets the list's width;
/// double-clicked, it collapses the list or opens it again at its width. Not a split view: a split view resizes its
/// panes, and with them every terminal, on each step of a drag.
final class TabListDivider: NSView {
    weak var list: TabListView?
    /// The cursor its rect shows, as last set.
    private var shownCursor: TabListCursor?

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let list else { return }
        if event.clickCount == 2 {
            list.toggleCollapsed()
        } else {
            list.trackWidthDrag(from: event)
        }
    }

    override func resetCursorRects() {
        let kind: TabListCursor = cursorKind
        shownCursor = kind
        addCursorRect(bounds, cursor: Self.cursor(kind))
    }

    /// At either end the cursor points the one way the list can still go: wider from the column of marks, narrower
    /// at the widest.
    private var cursorKind: TabListCursor {
        guard let list else { return .leftRight }
        let widest: CGFloat = TabListWidth.widest(paneWidth: list.superview?.bounds.width ?? 0)
        return TabListWidth.cursor(width: list.bounds.width, collapsed: list.isCollapsed, side: list.side, widest: widest)
    }

    /// The cursor rect again, when the cursor it shows would change.
    func refreshCursor() {
        guard cursorKind != shownCursor else { return }
        window?.invalidateCursorRects(for: self)
    }

    static func cursor(_ kind: TabListCursor) -> NSCursor {
        switch kind {
        case .leftRight: return .resizeLeftRight
        case .left: return .resizeLeft
        case .right: return .resizeRight
        }
    }
}
