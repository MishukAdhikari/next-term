import Foundation
import Testing
@testable import NextTermCore

/// The one rule the terminal rail, the folded tab list and the window column count their marks by.
@Suite struct MarkColumnTests {
    @Test func everyMarkFitsInItsSlotUnderTheStrip() {
        // 38 for the strip, 4, five 24-point slots and 4 under them.
        let column = MarkColumn(count: 5, height: 38 + 4 + 5 * 24 + 4, top: 38, slot: 24, margin: 4)
        let tops: [CGFloat] = column.slots.map(\.minY)
        let expected: [CGFloat] = [42, 66, 90, 114, 138]
        #expect(tops == expected)
        #expect(column.slots.allSatisfy { $0.minX == 0 && $0.width == 24 && $0.height == 24 })
        #expect(column.more == nil)
        #expect(column.hiddenCount == 0)
        #expect(column.shownCount == 5)
        #expect(column.marksTop == 42)
    }

    @Test func whatDoesNotFitIsAPlusInTheLastPlace() {
        // Room for five places: four marks, then "+4" in the fifth.
        let column = MarkColumn(count: 8, height: 38 + 4 + 5 * 24 + 4, top: 38, slot: 24, margin: 4)
        #expect(column.shownCount == 4)
        #expect(column.hiddenCount == 4)
        #expect(column.more == CGRect(x: 0, y: 42 + 4 * 24, width: 24, height: 24))
        #expect(column.place(4) == column.more)
        // One more than fits is the same: the last place is the count.
        let one = MarkColumn(count: 6, height: 38 + 4 + 5 * 24 + 4, top: 38, slot: 24, margin: 4)
        #expect(one.shownCount == 4 && one.hiddenCount == 2)
    }

    @Test func noRoomAtAllShowsNothingNotEvenTheCount() {
        let column = MarkColumn(count: 3, height: 30, top: 38, slot: 24, margin: 4)
        #expect(column.slots.isEmpty)
        #expect(column.more == nil)
        #expect(column.hiddenCount == 3)
        // Room for one place and two marks: the count alone, in that place.
        let single = MarkColumn(count: 2, height: 38 + 4 + 24 + 4, top: 38, slot: 24, margin: 4)
        #expect(single.slots.isEmpty)
        #expect(single.more == CGRect(x: 0, y: 42, width: 24, height: 24))
        #expect(single.hiddenCount == 2)
        // Nothing to show takes no place.
        let none = MarkColumn(count: 0, height: 400, top: 38, slot: 24, margin: 4)
        #expect(none.slots.isEmpty && none.more == nil && none.hiddenCount == 0)
    }

    @Test func aWindowColumnsTwentyEightPointSlotsUnderATallerTop() {
        // Under the traffic lights' strip and the header: 76, then 4, then 28-point places.
        let column = MarkColumn(count: 3, height: 600, top: 76, slot: 28, margin: 4)
        let tops: [CGFloat] = column.slots.map(\.minY)
        let expected: [CGFloat] = [80, 108, 136]
        #expect(tops == expected)
        #expect(column.slots.allSatisfy { $0.width == 28 && $0.height == 28 })
        // 76 + 4 + 4 leaves 116: four places, so five windows show three and "+2".
        let crowded = MarkColumn(count: 5, height: 200, top: 76, slot: 28, margin: 4)
        #expect(crowded.shownCount == 3)
        #expect(crowded.more == CGRect(x: 0, y: 80 + 3 * 28, width: 28, height: 28))
        #expect(crowded.hiddenCount == 2)
    }

    @Test func thePlusTakesTheMostUrgentColourOfWhatItHides() {
        #expect(MarkColumn.moreState([.idle, .done, .working]) == .done)
        #expect(MarkColumn.moreState([.working, .failed, .attention]) == .attention)
        #expect(MarkColumn.moreState([.idle, .working]) == .working)
        #expect(MarkColumn.moreState([]) == .idle)
        #expect(TabListCollapsed.moreState([.failed, .done]) == MarkColumn.moreState([.failed, .done]))
    }
}
