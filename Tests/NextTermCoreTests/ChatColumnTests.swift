import Testing
@testable import NextTermCore

/// The live chat's reading column: a margin that fills the width, a cap only in a very wide view.
@Suite struct ChatColumnTests {
    @Test func anOrdinaryWidthFillsLessTheMargin() {
        let column = ChatColumn.layout(width: 800)
        #expect(column.leading == 20)
        #expect(column.width == 760)
    }

    @Test func aNarrowWidthKeepsTheSameMargin() {
        let column = ChatColumn.layout(width: 520)
        #expect(column.leading == 20)
        #expect(column.width == 480)
    }

    @Test func aVeryWideViewCapsTheColumnAndCentresIt() {
        let column = ChatColumn.layout(width: 1400)
        #expect(column.width == ChatColumn.cap)
        #expect(column.leading == 270)
        #expect(column.leading * 2 + column.width == 1400)
    }

    @Test func theCapStartsJustPastItsMargins() {
        #expect(ChatColumn.layout(width: 900) == ChatColumn(leading: 20, width: 860))
        #expect(ChatColumn.layout(width: 902) == ChatColumn(leading: 21, width: 860))
    }

    @Test func neverWiderThanTheViewNorNegative() {
        for width in [0.0, 1, 10, 39, 40, 41, 300, 899, 2000, -5, .infinity, .nan] {
            let column = ChatColumn.layout(width: width)
            let total = max(0, width.isFinite ? width : 0)
            #expect(column.width >= 0)
            #expect(column.leading >= 0)
            #expect(column.leading * 2 + column.width == total)
        }
    }
}
