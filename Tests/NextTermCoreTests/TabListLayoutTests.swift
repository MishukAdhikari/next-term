import Foundation
import Testing
@testable import NextTermCore

@Suite struct TabListLayoutTests {
    private let split2: [TabListRow.Kind] = [.tab, .pane(index: 0, count: 2), .pane(index: 1, count: 2)]

    private func plain(_ count: Int) -> [TabListRow.Kind] { Array(repeating: .tab, count: count) }

    private func layout(_ kinds: [TabListRow.Kind], _ density: TabListDensity = .oneLine) -> TabListLayout {
        TabListLayout(kinds: kinds, density: density, width: 220)
    }

    /// The list's visible part, in its content's coordinates (y down from the first row's top padding).
    private func visible(_ top: CGFloat, _ height: CGFloat) -> CGRect { CGRect(x: 0, y: top, width: 220, height: height) }

    // MARK: rows and frames

    @Test func rowsAre28OrWithFolders40AndPanes24() {
        #expect(TabListLayout.rowHeight(for: .tab, density: .oneLine) == 28)
        #expect(TabListLayout.rowHeight(for: .tab, density: .twoLines) == 40)
        #expect(TabListLayout.rowHeight(for: .pane(index: 0, count: 2), density: .oneLine) == 24)
        #expect(TabListLayout.rowHeight(for: .pane(index: 1, count: 2), density: .twoLines) == 24)
        #expect(TabListDensity(showsFolders: false) == .oneLine)
        #expect(TabListDensity(showsFolders: true) == .twoLines)
    }

    @Test func rowsStack4PointsDownWithNoGaps() {
        let compact = layout(plain(3))
        #expect(compact.frames.map(\.minY) == [4, 32, 60])
        #expect(compact.frames.allSatisfy { $0.minX == 0 && $0.width == 220 && $0.height == 28 })
        #expect(compact.contentHeight == 88) // 4 + 3 × 28
        let folders = layout(plain(3), .twoLines)
        #expect(folders.frames.map(\.minY) == [4, 44, 84])
        #expect(folders.contentHeight == 124) // 4 + 3 × 40
        // A split tab: its row, then a 24-point row per pane, then the next tab.
        let mixed = layout(split2 + [.tab])
        #expect(mixed.frames.map(\.minY) == [4, 32, 56, 80])
        #expect(mixed.frames.map(\.height) == [28, 24, 24, 28])
        #expect(mixed.contentHeight == 108) // 4 + 28 + 2 × 24 + 28
        #expect(layout([]).contentHeight == 4)
    }

    @Test func eachTabsBlockCoversItsPaneRows() {
        let mixed = layout([.tab] + split2 + [.tab])
        #expect(mixed.blocks == [0..<1, 1..<4, 4..<5])
        #expect(mixed.tabCount == 3)
        #expect(mixed.blockFrame(tab: 1) == CGRect(x: 0, y: 32, width: 220, height: 76))
        #expect(mixed.blockFrame(tab: 9) == .zero)
    }

    // MARK: keeping the selected tab in view

    @Test func theSelectedRowScrollsIntoViewByTheLeastItCan() {
        // 14 tabs, 9 of them in view.
        let list = layout(plain(14))
        let shown = visible(0, 256) // 4 + 9 × 28
        // The last selected: it comes in at the bottom, and the list is scrolled to its end.
        #expect(list.scrollTarget(selected: 13, visible: shown) == 140) // 4 + 14 × 28 − 256
        // Already in view: nothing moves.
        #expect(list.scrollTarget(selected: 5, visible: shown) == nil)
        #expect(list.scrollTarget(selected: 8, visible: shown) == nil)
        // One row past the bottom: one row's scroll.
        #expect(list.scrollTarget(selected: 9, visible: shown) == 28)
        // Above the view: it comes in at the top.
        #expect(list.scrollTarget(selected: 4, visible: visible(140, shown.height)) == 116) // 4 + 4 × 28
    }

    @Test func theFirstRowScrollsBackToTheTop() {
        let list = layout(plain(14))
        // Partly cut off: the whole row comes back, with the padding over it.
        #expect(list.scrollTarget(selected: 0, visible: visible(10, 256)) == 0)
        #expect(list.scrollTarget(selected: 0, visible: visible(140, 256)) == 0)
        #expect(list.scrollTarget(selected: 0, visible: visible(0, 256)) == nil)
    }

    @Test func aSelectedSplitTabShowsWithItsPanes() {
        // Ten tabs, then a split tab with two panes (its block 284 to 360).
        let list = layout(plain(10) + split2)
        let target = list.scrollTarget(selected: 10, visible: visible(0, 256))
        #expect(target == 104) // its bottom at the view's, 360 − 256
        let block = list.blockFrame(tab: 10)
        if let target { #expect(visible(target, 256).contains(block)) }
        // Taller than the view: its own row at the top, and as many panes as fit.
        #expect(list.scrollTarget(selected: 10, visible: visible(0, 60)) == 284)
    }

    @Test func aListThatFitsNeverScrolls() {
        let list = layout(plain(3))
        #expect(list.scrollTarget(selected: 2, visible: visible(0, 500)) == nil)
        #expect(list.scrollTarget(selected: 7, visible: visible(0, 500)) == nil)
    }

    // MARK: dragging

    @Test func aDroppedTabNeverLandsBetweenATabAndItsPanes() {
        // T0 (4–32), T1 split (32–108: its row, then its panes from 60), T2 (108–136).
        let list = layout([.tab] + split2 + [.tab])
        // Dragging T0 with its centre over T1's pane rows: after T1 and both its panes.
        #expect(list.dropIndex(dragged: 0, centreY: 70) == 1)
        #expect(list.dropIndex(dragged: 0, centreY: 90) == 1)
        // Past the last row: the end. Above the first: the start.
        #expect(list.dropIndex(dragged: 0, centreY: 500) == 2)
        #expect(list.dropIndex(dragged: 0, centreY: -50) == 0)
        #expect(list.dropIndex(dragged: 2, centreY: -50) == 0)
        // Every answer is a tab's place, whatever the pointer.
        for y in stride(from: CGFloat(-40), through: 200, by: 2) {
            #expect((0...2).contains(list.dropIndex(dragged: 0, centreY: y)))
        }
    }

    @Test func aTabAtRestStaysWhereItIs() {
        let list = layout([.tab] + split2 + [.tab] + split2)
        for tab in 0..<list.tabCount {
            let centre = list.blockFrame(tab: tab).midY
            #expect(list.dropIndex(dragged: tab, centreY: centre) == tab)
        }
    }

    @Test func aSplitTabDraggedDownGoesPastTheNextTab() {
        let list = layout([.tab] + split2 + [.tab])
        // T1's block (76 high) centred at 70; a tab's height down, it is past T2.
        #expect(list.dropIndex(dragged: 1, centreY: 70) == 1)
        #expect(list.dropIndex(dragged: 1, centreY: 98) == 2)
        #expect(list.dropIndex(dragged: 1, centreY: 42) == 0)
    }

    @Test func aDraggedBlockStaysOverTheRows() {
        let list = layout([.tab] + split2 + [.tab])
        #expect(list.dragRange(tab: 1) == 4...60) // its 76 ending at the last row's bottom, 136
        #expect(list.dragRange(tab: 0) == 4...108)
    }

    @Test func dragsNearTheEdgesScroll() {
        let list = layout(plain(14)) // 396 high
        let shown = visible(70, 256) // 70 to 326
        #expect(list.autoscrollSpeed(pointerY: 198, visible: shown) == 0)
        // At the very edge, 12 points an event; less further in; nothing 24 points in.
        #expect(list.autoscrollSpeed(pointerY: 326, visible: shown) == 12)
        #expect(list.autoscrollSpeed(pointerY: 70, visible: shown) == -12)
        #expect(list.autoscrollSpeed(pointerY: 320, visible: shown) == 9)
        #expect(list.autoscrollSpeed(pointerY: 76, visible: shown) == -9)
        #expect(list.autoscrollSpeed(pointerY: 302, visible: shown) == 0)
        #expect(list.autoscrollSpeed(pointerY: 94, visible: shown) == 0)
        // Past the edge, the fastest.
        #expect(list.autoscrollSpeed(pointerY: 600, visible: shown) == 12)
        #expect(list.autoscrollSpeed(pointerY: -30, visible: shown) == -12)
    }

    @Test func noScrollPastEitherEnd() {
        let list = layout(plain(14))
        // At the top: the top band does nothing, the bottom one scrolls down.
        #expect(list.autoscrollSpeed(pointerY: 0, visible: visible(0, 256)) == 0)
        #expect(list.autoscrollSpeed(pointerY: 256, visible: visible(0, 256)) == 12)
        // At the end: the other way round.
        #expect(list.autoscrollSpeed(pointerY: 396, visible: visible(140, 256)) == 0)
        #expect(list.autoscrollSpeed(pointerY: 140, visible: visible(140, 256)) == -12)
        // A list that fits: never.
        let short = layout(plain(3))
        #expect(short.autoscrollSpeed(pointerY: 0, visible: visible(0, 500)) == 0)
        #expect(short.autoscrollSpeed(pointerY: 500, visible: visible(0, 500)) == 0)
    }

    // MARK: the edge chips

    @Test func aChipCountsWhatNeedsALookOutOfView() {
        let list = layout(plain(14))
        var states = Array(repeating: TabState.idle, count: 14)
        // Below the first nine rows: one needs you, one failed, one works.
        states[10] = .attention
        states[12] = .failed
        states[11] = .working
        let top = list.hidden(states: states, visible: visible(0, 256))
        #expect(top.above == nil)
        #expect(top.below == TabListChip(count: 2, state: .attention, target: 10))
        // Above, from the end of the list: done and working give done.
        var early = Array(repeating: TabState.idle, count: 14)
        early[1] = .done
        early[2] = .working
        let bottom = list.hidden(states: early, visible: visible(140, 256))
        #expect(bottom.above == TabListChip(count: 1, state: .done, target: 1))
        #expect(bottom.below == nil)
    }

    @Test func workingAloneRaisesNoChip() {
        let list = layout(plain(14))
        var states = Array(repeating: TabState.idle, count: 14)
        states[12] = .working
        #expect(list.hidden(states: states, visible: visible(0, 256)) == TabListChips(above: nil, below: nil))
    }

    @Test func oneMoreNeedingYouOutOfViewShowsAsOne() {
        // 14 tabs in a list that shows 9, the first selected, the thirteenth turning to needs-you.
        let list = layout(plain(14))
        var states = Array(repeating: TabState.idle, count: 14)
        states[12] = .attention
        #expect(list.hidden(states: states, visible: visible(0, 256)).below == TabListChip(count: 1, state: .attention, target: 12))
    }

    @Test func aChipLeadsToTheMostUrgentTabNearestTheView() {
        let list = layout(plain(14))
        var states = Array(repeating: TabState.idle, count: 14)
        states[0] = .done
        states[3] = .done
        states[1] = .failed
        states[9] = .done
        states[13] = .attention
        states[10] = .attention
        let chips = list.hidden(states: states, visible: visible(140, 120)) // rows 5 to 8 whole
        #expect(chips.above == TabListChip(count: 3, state: .failed, target: 1))
        #expect(chips.below == TabListChip(count: 3, state: .attention, target: 10))
        // Two of the same: the one nearest the edge.
        var dones = Array(repeating: TabState.idle, count: 14)
        dones[1] = .done
        dones[3] = .done
        #expect(list.hidden(states: dones, visible: visible(140, 256)).above?.target == 3)
    }

    @Test func aRowCutOffAtTheEdgeCounts() {
        // Rows 0 to 8 whole and row 9 half shown: the half-shown one's mark may be under the chip.
        let list = layout(plain(14))
        var states = Array(repeating: TabState.idle, count: 14)
        states[9] = .done
        #expect(list.hidden(states: states, visible: visible(0, 256 + 14)).below == TabListChip(count: 1, state: .done, target: 9))
    }

    @Test func onlyATabsOwnRowCounts() {
        // A split tab whose row shows: its panes below the view raise no chip (the row's mark is theirs).
        let list = layout(plain(8) + split2 + plain(4))
        var states = Array(repeating: TabState.idle, count: 13)
        states[8] = .attention
        #expect(list.hidden(states: states, visible: visible(0, 256)).below == nil) // nine rows
    }

    // MARK: collapsed

    @Test func collapsedTheMarksAre24PointSlotsUnderTheChevron() {
        // 38 for the chevron, 4, five slots and 4 under them.
        let roomy = TabListLayout.collapsed(tabCount: 5, height: 38 + 4 + 5 * 24 + 4)
        #expect(roomy.slots.map(\.minY) == [42, 66, 90, 114, 138])
        #expect(roomy.slots.allSatisfy { $0.minX == 0 && $0.width == 24 && $0.height == 24 })
        #expect(roomy.more == nil)
        #expect(roomy.hiddenCount == 0)
    }

    @Test func collapsedWhatDoesNotFitIsALastPlus() {
        // Room for five: four marks, then "+4" in the fifth place, as the rail counts them.
        let crowded = TabListLayout.collapsed(tabCount: 8, height: 38 + 4 + 5 * 24 + 4)
        #expect(crowded.slots.count == 4)
        #expect(crowded.more == CGRect(x: 0, y: 42 + 4 * 24, width: 24, height: 24))
        #expect(crowded.hiddenCount == 4)
        // No room at all: nothing shows, not even the count.
        let none = TabListLayout.collapsed(tabCount: 3, height: 30)
        #expect(none.slots.isEmpty)
        #expect(none.more == nil)
        #expect(none.hiddenCount == 3)
    }

    @Test func thePlusTakesTheHiddenTabsMostUrgentColour() {
        #expect(TabListCollapsed.moreState([.idle, .done, .working]) == .done)
        #expect(TabListCollapsed.moreState([.working, .failed, .attention]) == .attention)
        #expect(TabListCollapsed.moreState([.idle, .working]) == .working)
        #expect(TabListCollapsed.moreState([]) == .idle)
    }

    // MARK: the side

    @Test func theDividerIsOnTheEdgeThatMeetsTheTerminal() {
        // On the terminal's left, the list's right edge; on its right, the list's left edge.
        #expect(TabListSide.left.dividerFrame(width: 220, height: 500) == CGRect(x: 215, y: 0, width: 5, height: 500))
        #expect(TabListSide.right.dividerFrame(width: 220, height: 500) == CGRect(x: 0, y: 0, width: 5, height: 500))
        #expect(!TabListSide.left.terminalIsLeft)
        #expect(TabListSide.right.terminalIsLeft)
    }

    @Test func dragsWidenTowardTheTerminal() {
        // On the left a drag right widens the list; on the right a drag left does.
        #expect(TabListSide.left.widthChange(pointerMoved: 30) == 30)
        #expect(TabListSide.left.widthChange(pointerMoved: -30) == -30)
        #expect(TabListSide.right.widthChange(pointerMoved: 30) == -30)
        #expect(TabListSide.right.widthChange(pointerMoved: -30) == 30)
    }

    @Test func theChevronPointsTheWayTheListOpens() {
        #expect(!TabListSide.left.expandPointsLeft)
        #expect(TabListSide.right.expandPointsLeft)
    }

    @Test func theSelectedEdgeIsOnTheSideAwayFromTheTerminal() {
        #expect(TabListSide.left.selectionEdge(rowWidth: 220, rowHeight: 28) == CGRect(x: 0, y: 0, width: 2, height: 28))
        #expect(TabListSide.right.selectionEdge(rowWidth: 220, rowHeight: 28) == CGRect(x: 218, y: 0, width: 2, height: 28))
    }

    @Test func everythingElseIsTheSameOnBothSides() {
        // Rows, drops, scrolling and chips do not depend on the side: one layout serves both.
        let list = layout(plain(14))
        #expect(list.frames.allSatisfy { $0.minX == 0 })
        #expect(TabListSide.allCases == [.left, .right])
        #expect(TabListSide(rawValue: "right") == .right)
    }
}
