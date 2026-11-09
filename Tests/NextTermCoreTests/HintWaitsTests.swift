import Foundation
import Testing
@testable import NextTermCore

struct HintWaitsTests {
    @Test func aTriggerWaitsUntilItNoLongerHoldsOrHasWaitedTenMinutes() {
        var waits = HintWaits()
        #expect(waits.isEmpty)
        waits.start(.columnBasics, now: 100)
        waits.start(.nextAgent, now: 150)
        waits.drop(now: 100 + HintWaits.atMost, holds: { _ in true })
        #expect(waits.contains(.columnBasics) && waits.contains(.nextAgent))
        waits.drop(now: 100 + HintWaits.atMost + 1, holds: { _ in true })
        #expect(!waits.contains(.columnBasics) && waits.contains(.nextAgent))
        waits.drop(now: 160, holds: { $0 != .nextAgent })
        #expect(waits.isEmpty)
    }

    @Test func firedAgainItWaitsFromThenAndTheyAreTriedInOneOrder() {
        var waits = HintWaits()
        waits.start(.columnBasics, now: 0)
        waits.start(.columnBasics, now: 500)
        waits.drop(now: 700, holds: { _ in true })
        #expect(waits.contains(.columnBasics) && waits.since[.columnBasics] == 500)
        waits.start(.nextAgent, now: 700)
        #expect(waits.order == [.nextAgent, .columnBasics])
        waits.remove(.nextAgent)
        #expect(waits.order == [.columnBasics])
        waits.removeAll()
        #expect(waits.isEmpty)
    }
}
