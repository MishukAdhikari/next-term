import Testing
@testable import NextTermCore

/// When a program that asked to hear about focus is told it: whenever the user stops seeing its tab with the keyboard in
/// it, once per change, and never again for what SwiftTerm told it as the keyboard moved.
@Suite struct FocusReportTests {
    @Test func aChangeIsToldAndNoChangeIsNot() {
        #expect(FocusReport.next(last: nil, now: true) == true)
        #expect(FocusReport.next(last: true, now: true) == nil)
        #expect(FocusReport.next(last: true, now: false) == false)
        #expect(FocusReport.next(last: false, now: false) == nil)
        #expect(FocusReport.next(last: false, now: true) == true)
    }

    @Test func goingToAnotherAppAndBackIsToldOnceEach() {
        var report = FocusReport()
        #expect(report.look(keyboard: true, seen: true) == nil) // SwiftTerm starts at focused
        #expect(report.look(keyboard: true, seen: false) == false)
        #expect(report.look(keyboard: true, seen: false) == nil)
        #expect(report.look(keyboard: true, seen: true) == true)
        #expect(report.told == true)
    }

    @Test func whatSwiftTermToldAsTheKeyboardMovedCountsAsTold() {
        var report = FocusReport()
        _ = report.look(keyboard: true, seen: true)
        // The editor took the keyboard: SwiftTerm said CSI O itself.
        #expect(report.look(keyboard: false, seen: true) == nil)
        #expect(report.told == false)
        // Back in the terminal: SwiftTerm said CSI I.
        #expect(report.look(keyboard: true, seen: true) == nil)
        // In the background with the keyboard still in the view: Next Term says it, then once back, again.
        #expect(report.look(keyboard: true, seen: false) == false)
        #expect(report.look(keyboard: true, seen: true) == true)
    }

    @Test func comingBackToAnotherViewTellsNothing() {
        var report = FocusReport()
        _ = report.look(keyboard: true, seen: true)
        #expect(report.look(keyboard: true, seen: false) == false)
        // The app came back with a click in the editor: SwiftTerm said CSI O (it was told already), nothing more.
        #expect(report.look(keyboard: false, seen: true) == nil)
        #expect(report.look(keyboard: false, seen: false) == nil)
    }

    @Test func aTabNeverSeenIsToldItHasNoFocus() {
        var report = FocusReport()
        #expect(report.look(keyboard: false, seen: false) == false)
        #expect(report.look(keyboard: false, seen: true) == nil)
    }
}
