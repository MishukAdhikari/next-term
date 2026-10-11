import Testing
@testable import NextTermCore

/// A terminal draws only while its window can be seen, and draws once, whole, when it can be seen again.
@Suite struct DrawGateTests {
    /// What the gate answers to each step: "d" an invalidation drawn, "-" dropped; "show"/"hide" true when it
    /// asks for a whole redraw.
    func answers(_ gate: inout DrawGate, _ steps: [String]) -> [Bool] {
        steps.map { step in
            switch step {
            case "show": return gate.setVisible(true)
            case "hide": return gate.setVisible(false)
            default: return gate.invalidate()
            }
        }
    }

    @Test func aVisibleTerminalDrawsEveryChange() {
        var gate = DrawGate(visible: true)
        let drawn = answers(&gate, Array(repeating: "change", count: 100))
        #expect(drawn.allSatisfy { $0 })
        #expect(gate.dropped == 0 && !gate.stale)
        let again = answers(&gate, ["show"])
        #expect(again == [false]) // already visible: nothing to catch up
    }

    @Test func aHiddenTerminalDrawsNothingAndOnceWhenShown() {
        var gate = DrawGate(visible: true)
        let hidden = answers(&gate, ["hide"] + Array(repeating: "change", count: 600)) // a spinner at 60 fps for 10 s
        #expect(hidden.allSatisfy { !$0 })
        #expect(gate.dropped == 600 && gate.stale)
        let shown = answers(&gate, ["show", "show", "change"])
        #expect(shown == [true, false, true]) // one whole redraw, then every change again
        #expect(!gate.stale)
    }

    @Test func nothingChangedWhileHiddenNeedsNoRedraw() {
        var gate = DrawGate(visible: true)
        #expect(answers(&gate, ["hide", "show"]) == [false, false])
        #expect(gate.dropped == 0)
    }

    @Test func flickeringVisibilityRedrawsOnlyWhatWentStale() {
        var gate = DrawGate(visible: true)
        // A second "hidden" (minimized while covered) changes nothing; hidden again with no output needs no redraw.
        let steps = ["hide", "change", "hide", "show", "hide", "show", "hide", "change", "change", "show"]
        #expect(answers(&gate, steps) == [false, false, false, true, false, false, false, false, false, true])
        #expect(gate.dropped == 3)
    }

    /// A terminal made before it has a window (a new tab) or taken out of one keeps what it is asked to draw for
    /// when it is in a window that can be seen.
    @Test func noWindowYetCountsAsNotSeen() {
        var gate = DrawGate(visible: false)
        // Put into a window on another Space first, then seen.
        #expect(answers(&gate, ["change", "hide", "show"]) == [false, false, true])
    }
}
