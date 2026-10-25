import Testing
@testable import NextTermCore

/// A sidebar row's line, split between its name and its dimmed detail ("OpenAI", "AI model · .env"): the name is the
/// content and stays whole; the detail gives way first, cut at its tail, and goes when only a sliver of it would show.
/// Widths are in points: a name of 50, a detail of 80, a 7-point gap, and room for at least 20 points of detail.
@Suite struct NameDetailFitTests {
    func fit(room: Double, name: Double = 50, detail: Double = 80) -> NameDetailFit {
        NameDetailFit.fit(room: room, name: name, detail: detail, gap: 7, minimumDetail: 20)
    }

    @Test func bothShowWholeWhenTheyFit() {
        #expect(fit(room: 200) == NameDetailFit(name: 50, detail: 80))
        #expect(fit(room: 137) == NameDetailFit(name: 50, detail: 80))
    }

    @Test func theDetailGivesWayFirstAndTheNameStaysWhole() {
        // 100 points: the name keeps its 50, the gap its 7, and the detail is cut at its tail to the 43 left.
        #expect(fit(room: 100) == NameDetailFit(name: 50, detail: 43))
    }

    @Test func theDetailShowsDownToItsMinimum() {
        #expect(fit(room: 77) == NameDetailFit(name: 50, detail: 20))
    }

    @Test func theDetailHidesWhenLessThanItsMinimumIsLeft() {
        #expect(fit(room: 76) == NameDetailFit(name: 50, detail: nil))
        #expect(fit(room: 60) == NameDetailFit(name: 50, detail: nil))
    }

    @Test func aHiddenDetailGivesItsGapBackToTheName() {
        // Without the detail the name needs no gap: 52 points show the whole name, not one cut to 45.
        #expect(fit(room: 52) == NameDetailFit(name: 50, detail: nil))
        #expect(fit(room: 50) == NameDetailFit(name: 50, detail: nil))
    }

    @Test func theNameIsCutOnlyWhenItAloneDoesNotFit() {
        #expect(fit(room: 40) == NameDetailFit(name: 40, detail: nil))
    }

    @Test func aShortDetailThatFitsWholeShowsEvenBelowTheMinimum() {
        // A group's count ("4") is narrower than the minimum: whole, it shows.
        #expect(fit(room: 100, detail: 12) == NameDetailFit(name: 50, detail: 12))
        #expect(fit(room: 69, detail: 12) == NameDetailFit(name: 50, detail: 12))
    }

    @Test func aShortDetailThatDoesNotFitWholeHides() {
        #expect(fit(room: 68, detail: 12) == NameDetailFit(name: 50, detail: nil))
    }

    @Test func noDetailMeansNoneShows() {
        #expect(fit(room: 200, detail: 0) == NameDetailFit(name: 50, detail: nil))
    }

    @Test func noRoomShowsNothing() {
        #expect(fit(room: 0) == NameDetailFit(name: 0, detail: nil))
        #expect(fit(room: -8) == NameDetailFit(name: 0, detail: nil))
    }
}
