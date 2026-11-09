import CoreGraphics
import Testing
@testable import NextTermCore

struct HintRoomTests {
    @Test func aLineGoesAtTheStripsTrailingEndWhenItFitsWhole() {
        let placed = HintRoom.place(width: 120, start: 300, end: 600)
        #expect(placed?.x == 480 && placed?.width == 120)
    }

    @Test func itNeedsItsWholeWidthAndTheStripsClearRoom() {
        // Exactly enough: its width and the room kept clear.
        #expect(HintRoom.place(width: 120, start: 300, end: 300 + 120 + HintRoom.keepClear)?.x == 324)
        // A point short: none, never cut.
        #expect(HintRoom.place(width: 120, start: 300, end: 300 + 120 + HintRoom.keepClear - 1) == nil)
        // A strip the tabs filled, or one turned negative by a narrow window: none.
        #expect(HintRoom.place(width: 120, start: 600, end: 600) == nil)
        #expect(HintRoom.place(width: 120, start: 600, end: 500) == nil)
        #expect(HintRoom.place(width: 0, start: 0, end: 600) == nil)
    }
}
