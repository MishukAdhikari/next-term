import Testing
@testable import NextTermCore

/// The live chat's reading column: from the leading margin, the width less both margins, at most 90 characters.
@Suite struct ChatColumnTests {
    @Test func anOrdinaryWidthFillsLessTheMargins() {
        let column = ChatColumn.layout(width: 800, cap: 900)
        #expect(column == ChatColumn(leading: 20, width: 760))
    }

    @Test func aNarrowWidthKeepsTheSameMargin() {
        #expect(ChatColumn.layout(width: 520, cap: 900) == ChatColumn(leading: 20, width: 480))
    }

    @Test func aWideViewStopsAtTheMeasureAndStaysAtTheLeadingEdge() {
        // Left-aligned, ragged right: never centred, so the left side never grows.
        for width in [700.0, 1400, 2400] {
            let column = ChatColumn.layout(width: width, cap: 600)
            #expect(column.leading == 20)
            #expect(column.width == min(600, width - 40))
        }
    }

    @Test func theMeasureIsNinetyAverageLetters() {
        // A 13 pt body's alphabet is about 170 pt: 90 letters, about 588 pt.
        #expect(ChatColumn.cap(alphabetWidth: 170) == 588)
        #expect(ChatColumn.cap(alphabetWidth: 26) == 90)
        // It grows with the font (View › Bigger).
        #expect(ChatColumn.cap(alphabetWidth: 200) > ChatColumn.cap(alphabetWidth: 170))
        #expect(ChatColumn.cap(alphabetWidth: 0) == 0 && ChatColumn.cap(alphabetWidth: .nan) == 0)
    }

    @Test func neverWiderThanTheViewNorNegative() {
        for width in [0.0, 1, 10, 39, 40, 41, 300, 899, 2000, -5, .infinity, .nan] {
            for cap in [0.0, 500, .infinity] {
                let column = ChatColumn.layout(width: width, cap: cap)
                let total = max(0, width.isFinite ? width : 0)
                #expect(column.width >= 0 && column.leading >= 0)
                #expect(column.leading + column.width <= total)
            }
        }
    }
}
