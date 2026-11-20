import Testing
@testable import NextTermCore

/// The live chat's reading column: the pane's width less a margin either side, at every width.
@Suite struct ChatColumnTests {
    @Test func itFillsThePaneLessTheMargins() {
        #expect(ChatColumn.layout(width: 800) == ChatColumn(leading: 20, width: 760))
        #expect(ChatColumn.layout(width: 520) == ChatColumn(leading: 20, width: 480))
    }

    @Test func aWideTerminalGetsAWideChatWithNoRoomLeftOver() {
        // No cap and no centring: the chat follows the terminal's width.
        for width in [1400.0, 2400, 3600] {
            #expect(ChatColumn.layout(width: width) == ChatColumn(leading: 20, width: width - 40))
        }
    }

    @Test func neverWiderThanTheViewNorNegative() {
        for width in [0.0, 1, 10, 39, 40, 41, 300, 899, 2000, -5, .infinity, .nan] {
            let column = ChatColumn.layout(width: width)
            let total = max(0, width.isFinite ? width : 0)
            #expect(column.width >= 0 && column.leading >= 0)
            #expect(column.leading * 2 + column.width == total)
        }
    }
}
