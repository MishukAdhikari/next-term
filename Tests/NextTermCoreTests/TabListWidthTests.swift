import Foundation
import Testing
@testable import NextTermCore

@Suite struct TabListWidthTests {
    @Test func theListsMeasures() {
        #expect(TabListWidth.range == 160...400)
        #expect(TabListWidth.defaultWidth == 220)
        #expect(TabListWidth.collapsedWidth == 24)
        #expect(TabListWidth.snapBelow == 120)
        #expect(TabListWidth.terminalMinimum == 240)
    }

    @Test func aWidthIsKeptBetween160And400() {
        #expect(TabListWidth.clamp(130) == 160)
        #expect(TabListWidth.clamp(500) == 400)
        #expect(TabListWidth.clamp(300) == 300)
        #expect(TabListWidth.clamp(160) == 160)
        #expect(TabListWidth.clamp(400) == 400)
        // Not a width at all: the first one.
        #expect(TabListWidth.clamp(.nan) == 220)
        #expect(TabListWidth.clamp(.infinity) == 220)
    }

    @Test func aDragPast120SnapsTheListCollapsed() {
        #expect(TabListWidth.afterDrag(100) == .collapsed)
        #expect(TabListWidth.afterDrag(119) == .collapsed)
        #expect(TabListWidth.afterDrag(0) == .collapsed)
        #expect(TabListWidth.afterDrag(120) == .width(160))
        #expect(TabListWidth.afterDrag(130) == .width(160))
        #expect(TabListWidth.afterDrag(300) == .width(300))
        #expect(TabListWidth.afterDrag(500) == .width(400))
    }

    @Test func onTheLeftADragRightWidensIt() {
        #expect(TabListWidth.dragged(from: 220, by: 80, side: .left) == .width(300))
        #expect(TabListWidth.dragged(from: 220, by: -60, side: .left) == .width(160))
        #expect(TabListWidth.dragged(from: 220, by: -120, side: .left) == .collapsed)
        // From the column of marks, back out.
        #expect(TabListWidth.dragged(from: TabListWidth.collapsedWidth, by: 200, side: .left) == .width(224))
        #expect(TabListWidth.dragged(from: TabListWidth.collapsedWidth, by: 50, side: .left) == .collapsed)
    }

    @Test func onTheRightADragLeftWidensIt() {
        #expect(TabListWidth.dragged(from: 220, by: -80, side: .right) == .width(300))
        #expect(TabListWidth.dragged(from: 220, by: 80, side: .right) == .width(160))
        #expect(TabListWidth.dragged(from: 220, by: 120, side: .right) == .collapsed)
        #expect(TabListWidth.dragged(from: TabListWidth.collapsedWidth, by: -200, side: .right) == .width(224))
        #expect(TabListWidth.dragged(from: 300, by: -400, side: .right) == .width(400))
    }

    @Test func aDragShowsItsWidthAndKeepsItWhenLetGo() {
        #expect(TabListWidth.Drag.width(300).shownWidth == 300)
        #expect(TabListWidth.Drag.collapsed.shownWidth == 24)
        let open = TabListWidth.Drag.width(300).kept(openWidth: 220)
        #expect(open.width == 300 && !open.collapsed)
        // Snapped collapsed: it keeps the width it had, to open at again.
        let collapsed = TabListWidth.Drag.collapsed.kept(openWidth: 220)
        #expect(collapsed.width == 220 && collapsed.collapsed)
        #expect(TabListWidth.Drag.collapsed.kept(openWidth: 50).width == 160)
    }

    @Test func aDragLeavesTheTerminalItsRoom() {
        // 640 across leaves room for 400; 560 for 320; 400 for 160; under that, none.
        #expect(TabListWidth.widest(paneWidth: 640) == 400)
        #expect(TabListWidth.widest(paneWidth: 1200) == 400)
        #expect(TabListWidth.widest(paneWidth: 560) == 320)
        #expect(TabListWidth.widest(paneWidth: 560, terminalMinimum: 300) == 260)
        #expect(TabListWidth.widest(paneWidth: 0) == 400) // not measured: no limit
        let widest = TabListWidth.widest(paneWidth: 560)
        #expect(TabListWidth.dragged(from: 220, by: 300, side: .left, widest: widest) == .width(320))
        #expect(TabListWidth.dragged(from: 220, by: -300, side: .right, widest: widest) == .width(320))
        #expect(TabListWidth.dragged(from: 220, by: 50, side: .left, widest: widest) == .width(270))
        // Dragged as wide as it goes, the list is still open once let go.
        #expect(!TabListWidth.shown(paneWidth: 560, width: 320, userCollapsed: false).collapsed)
        // The snap is the same whatever the room.
        #expect(TabListWidth.dragged(from: 220, by: -110, side: .left, widest: widest) == .collapsed)
        // No room to open: a drag out of the column of marks leaves it collapsed.
        let none = TabListWidth.widest(paneWidth: 380)
        #expect(TabListWidth.dragged(from: TabListWidth.collapsedWidth, by: 200, side: .left, widest: none) == .collapsed)
        #expect(TabListWidth.dragged(from: TabListWidth.collapsedWidth, by: -200, side: .right, widest: none) == .collapsed)
    }

    @Test func aDoubleClickCollapsesAndOpensAtTheSameWidth() {
        let collapsed = TabListWidth.toggled(width: 300, shownCollapsed: false)
        #expect(collapsed.width == 300 && collapsed.collapsed)
        let open = TabListWidth.toggled(width: collapsed.width, shownCollapsed: true)
        #expect(open.width == 300 && !open.collapsed)
        // Snapped collapsed by a drag from 220, then a double-click: back at 220.
        #expect(TabListWidth.toggled(width: 220, shownCollapsed: true).width == 220)
        #expect(TabListWidth.toggled(width: 1000, shownCollapsed: true).width == 400)
    }

    @Test func aListWithNoRoomCollapsesByItself() {
        // 420 across with the list at 220 leaves the terminal 200, under its 240.
        let narrow = TabListWidth.shown(paneWidth: 420, width: 220, userCollapsed: false)
        #expect(narrow == TabListWidth.Shown(width: 24, collapsed: true, byRoom: true))
        // 500 across: room again, at its own width.
        #expect(TabListWidth.shown(paneWidth: 500, width: 220, userCollapsed: false) == TabListWidth.Shown(width: 220, collapsed: false, byRoom: false))
        // Exactly 240 left is room.
        #expect(!TabListWidth.shown(paneWidth: 460, width: 220, userCollapsed: false).collapsed)
        #expect(TabListWidth.shown(paneWidth: 459, width: 220, userCollapsed: false).byRoom)
        // A narrower list fits where a wider one does not.
        #expect(!TabListWidth.shown(paneWidth: 420, width: 160, userCollapsed: false).collapsed)
    }

    @Test func theUsersOwnCollapseHoldsAtAnyWidth() {
        for pane in [CGFloat(300), 500, 2000] {
            #expect(TabListWidth.shown(paneWidth: pane, width: 220, userCollapsed: true) == TabListWidth.Shown(width: 24, collapsed: true, byRoom: false))
        }
    }

    @Test func aPaneNotMeasuredYetDecidesNothing() {
        // Hidden or not laid out: never collapsed for want of room it has not measured.
        #expect(TabListWidth.shown(paneWidth: 0, width: 220, userCollapsed: false) == TabListWidth.Shown(width: 220, collapsed: false, byRoom: false))
        #expect(TabListWidth.shown(paneWidth: 0, width: 220, userCollapsed: true).collapsed)
    }

    @Test func theTerminalsMinimumCanBeGiven() {
        #expect(TabListWidth.shown(paneWidth: 500, width: 220, userCollapsed: false, terminalMinimum: 300).byRoom)
        #expect(!TabListWidth.shown(paneWidth: 520, width: 220, userCollapsed: false, terminalMinimum: 300).collapsed)
    }

    @Test func theLastWidthSetAnywhereReadsBack() {
        #expect(TabListWidth.stored(nil) == 220)
        // UserDefaults reads a missing number as 0.
        #expect(TabListWidth.stored(0) == 220)
        #expect(TabListWidth.stored(-5) == 220)
        #expect(TabListWidth.stored(.nan) == 220)
        #expect(TabListWidth.stored(300) == 300)
        #expect(TabListWidth.stored(1000) == 400)
        #expect(TabListWidth.stored(50) == 160)
    }

    @Test func theEdgesCursorSaysWhichWayItCanGo() {
        // Between the ends, both ways (a drag in past 120 still collapses it from 160).
        #expect(TabListWidth.cursor(width: 220, collapsed: false, side: .left) == .leftRight)
        #expect(TabListWidth.cursor(width: 160, collapsed: false, side: .left) == .leftRight)
        // Collapsed, only wider: toward the terminal.
        #expect(TabListWidth.cursor(width: 220, collapsed: true, side: .left) == .right)
        #expect(TabListWidth.cursor(width: 220, collapsed: true, side: .right) == .left)
        // At 400, only narrower: away from it.
        #expect(TabListWidth.cursor(width: 400, collapsed: false, side: .left) == .left)
        #expect(TabListWidth.cursor(width: 400, collapsed: false, side: .right) == .right)
        // Where the terminal leaves less room, that is the widest.
        #expect(TabListWidth.cursor(width: 320, collapsed: false, side: .left, widest: 320) == .left)
        #expect(TabListWidth.cursor(width: 320, collapsed: false, side: .right, widest: 320) == .right)
        #expect(TabListWidth.cursor(width: 300, collapsed: false, side: .left, widest: 320) == .leftRight)
        #expect(TabListWidth.cursor(width: 400, collapsed: false, side: .left, widest: 900) == .left)
    }
}

@Suite struct TabListWidthsTests {
    @Test func aFoldersWidthIsKept() {
        let widths = TabListWidths().setting(width: 300, collapsed: false, for: "/Users/test/work/api", now: 10)
        #expect(widths.entry(for: "/Users/test/work/api") == TabListWidths.Entry(width: 300, collapsed: false, setAt: 10))
        #expect(widths.entry(for: "/Users/test/work/web") == nil)
        // Set again: the second.
        let again = widths.setting(width: 260, collapsed: true, for: "/Users/test/work/api", now: 20)
        #expect(again.entry(for: "/Users/test/work/api") == TabListWidths.Entry(width: 260, collapsed: true, setAt: 20))
        #expect(again.entries.count == 1)
        // What is kept is a width the list can have.
        #expect(TabListWidths().setting(width: 999, collapsed: false, for: "/x", now: 1).entry(for: "/x")?.width == 400)
    }

    @Test func atMost50FoldersTheLeastRecentlySetGoingFirst() {
        var widths = TabListWidths()
        for i in 0..<51 { widths = widths.setting(width: 200, collapsed: false, for: "/Users/test/p\(i)", now: Double(i)) }
        #expect(widths.entries.count == 50)
        #expect(widths.entry(for: "/Users/test/p0") == nil)
        #expect(widths.entry(for: "/Users/test/p1") != nil)
        #expect(widths.entry(for: "/Users/test/p50") != nil)
        // An old folder set again is recent again: the next oldest goes.
        widths = widths.setting(width: 300, collapsed: false, for: "/Users/test/p1", now: 100)
        widths = widths.setting(width: 300, collapsed: false, for: "/Users/test/new", now: 101)
        #expect(widths.entry(for: "/Users/test/p1") != nil)
        #expect(widths.entry(for: "/Users/test/p2") == nil)
        #expect(widths.entries.count == 50)
    }

    @Test func foldersGoneAreDropped() {
        let widths = TabListWidths()
            .setting(width: 300, collapsed: false, for: "/Users/test/here", now: 1)
            .setting(width: 200, collapsed: true, for: "/Users/test/gone", now: 2)
        let pruned = widths.pruned { $0 == "/Users/test/here" }
        #expect(pruned.entry(for: "/Users/test/here") != nil)
        #expect(pruned.entry(for: "/Users/test/gone") == nil)
    }

    @Test func theyGoToPreferencesAndBack() {
        let widths = TabListWidths()
            .setting(width: 300, collapsed: false, for: "/Users/test/a", now: 1)
            .setting(width: 180, collapsed: true, for: "/Users/test/b", now: 2)
        let list = widths.propertyList
        #expect(PropertyListSerialization.propertyList(list, isValidFor: .binary))
        #expect(TabListWidths(propertyList: list) == widths)
        #expect(TabListWidths.key == "tabListWidths")
    }

    @Test func whatIsNotAnEntryIsLeftOut() {
        let stored: [String: Any] = [
            "/Users/test/good": ["width": 260.0, "collapsed": true, "setAt": 5.0],
            "/Users/test/number": NSNumber(value: 300),
            "/Users/test/words": ["width": "wide"],
            "/Users/test/infinite": ["width": Double.infinity],
            "/Users/test/bare": ["width": NSNumber(value: 250)],
        ]
        let widths = TabListWidths(propertyList: stored)
        #expect(widths.entries.count == 2)
        #expect(widths.entry(for: "/Users/test/good") == TabListWidths.Entry(width: 260, collapsed: true, setAt: 5))
        // Only a width: open, and set long ago.
        #expect(widths.entry(for: "/Users/test/bare") == TabListWidths.Entry(width: 250, collapsed: false, setAt: 0))
        // Not a dictionary at all: none kept, and nothing breaks.
        #expect(TabListWidths(propertyList: "x").entries.isEmpty)
        #expect(TabListWidths(propertyList: nil).entries.isEmpty)
        #expect(TabListWidths(propertyList: [1, 2]).entries.isEmpty)
    }

    @Test func aWidthStoredOutOfRangeReadsBackInRange() {
        let widths = TabListWidths(propertyList: ["/Users/test/a": ["width": 1000.0], "/Users/test/b": ["width": 20.0]])
        #expect(widths.entry(for: "/Users/test/a")?.width == 400)
        #expect(widths.entry(for: "/Users/test/b")?.width == 160)
    }

    @Test func aWindowStartsAtItsFoldersWidthElseTheLastOneSet() {
        let widths = TabListWidths().setting(width: 300, collapsed: true, for: "/Users/test/work/api", now: 1)
        let known = widths.start(for: "/Users/test/work/api", last: 260)
        #expect(known.width == 300 && known.collapsed)
        // A project seen for the first time, and a window with none: the last width set anywhere, open.
        let fresh = widths.start(for: "/Users/test/work/web", last: 260)
        #expect(fresh.width == 260 && !fresh.collapsed)
        let none = widths.start(for: nil, last: 260)
        #expect(none.width == 260 && !none.collapsed)
        // Nothing set anywhere yet: 220.
        #expect(TabListWidths().start(for: nil, last: nil).width == 220)
    }
}
