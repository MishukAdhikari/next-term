import Testing
@testable import NextTermCore

@Suite struct TickerPaceTests {
    @Test func watchesOnlyWhatSomeoneCanSeeRunningWhileTheAppIsInUse() {
        #expect(TickerPace.pace(active: true, windows: [(seen: true, runs: true)]) == .watching)
        // Another app in use, or the running window covered: once a second is enough for notices and the badge.
        #expect(TickerPace.pace(active: false, windows: [(seen: true, runs: true)]) == .background)
        #expect(TickerPace.pace(active: true, windows: [(seen: false, runs: true), (seen: true, runs: false)]) == .background)
    }

    @Test func nothingRunningIsIdle() {
        #expect(TickerPace.pace(active: true, windows: [(seen: true, runs: false), (seen: false, runs: false)]) == .idle)
        #expect(TickerPace.pace(active: true, windows: []) == .idle)
    }

    @Test func eachBeatHasAQuarterOfItselfAsTolerance() {
        #expect(TickerPace.watching.tolerance == 0.0625)
        #expect(TickerPace.idle.tolerance == 0.5)
    }
}
