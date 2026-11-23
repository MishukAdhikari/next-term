import Foundation
import Testing
@testable import NextTermCore

/// The places look slows while nothing moves, the Codex listing waits unless its folder moved, and herdr's local check
/// slows while no one can see it.
@Suite struct PollPaceTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func aQuietLookSlowsToTheCap() {
        var pace = QuietBackoff()
        #expect(pace.interval == 1)
        let changed1 = pace.note(moved: false)
        #expect(changed1)
        #expect(pace.interval == 2)
        let changed2 = pace.note(moved: false)
        #expect(changed2)
        #expect(pace.interval == 4)
        let changed3 = pace.note(moved: false)
        #expect(!changed3)
        #expect(pace.interval == 4)
    }

    @Test func anyMoveIsBackAtOnce() {
        var pace = QuietBackoff()
        pace.note(moved: false)
        pace.note(moved: false)
        let changed4 = pace.note(moved: true)
        #expect(changed4)
        #expect(pace.interval == 1)
        let changed5 = pace.note(moved: true)
        #expect(!changed5)
        #expect(pace.interval == 1)
    }

    @Test func resetIsBackToTheFirstStep() {
        var pace = QuietBackoff()
        pace.note(moved: false)
        let changed6 = pace.reset()
        #expect(changed6)
        #expect(pace.interval == 1)
        let changed7 = pace.reset()
        #expect(!changed7)
    }

    @Test func theFirstListingIsDue() {
        let relisting = Relisting(every: 4)
        #expect(relisting.due("/repo", at: start))
    }

    @Test func anUnchangedFolderWaitsItsTurn() {
        var relisting = Relisting(every: 4)
        relisting.listed("/repo", at: start)
        #expect(!relisting.due("/repo", at: start.addingTimeInterval(1)))
        #expect(!relisting.due("/repo", at: start.addingTimeInterval(3.9)))
        #expect(relisting.due("/repo", at: start.addingTimeInterval(4)))
    }

    @Test func aMovedFolderListsAtOnce() {
        var relisting = Relisting(every: 4)
        relisting.listed("/repo", at: start)
        #expect(relisting.due("/repo/sub", at: start.addingTimeInterval(1)))
    }

    @Test func herdrIsExactWhileSeenInTheAppInUse() {
        #expect(HerdrPace.interval(seen: true, active: true, deciding: false) == HerdrPace.watching)
        #expect(HerdrPace.watching == 2)
    }

    @Test func herdrSlowsWhenUnseenOrInTheBackground() {
        #expect(HerdrPace.interval(seen: false, active: true, deciding: false) == HerdrPace.background)
        #expect(HerdrPace.interval(seen: true, active: false, deciding: false) == HerdrPace.background)
        #expect(HerdrPace.interval(seen: false, active: false, deciding: false) == HerdrPace.background)
        #expect(HerdrPace.background == 6)
    }

    @Test func aDecisionKeepsHerdrExact() {
        #expect(HerdrPace.interval(seen: false, active: false, deciding: true) == HerdrPace.watching)
    }
}
