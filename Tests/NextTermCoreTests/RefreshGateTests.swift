import Foundation
import Testing
@testable import NextTermCore

/// Drives a RefreshGate the way GatedRefresh does, on a fake clock: one timer, and a refresh that takes `runTime`
/// (none by default), events in time order.
struct GateClock {
    var gate = RefreshGate()
    var runTime: TimeInterval = 0
    var timer: TimeInterval?
    var runEnd: TimeInterval?
    var runs: [TimeInterval] = []
    /// When the timer went off while a refresh ran.
    var firedWhileRunning: [TimeInterval] = []

    init(runTime: TimeInterval = 0) { self.runTime = runTime }

    /// Ends the running refresh and fires the timer, in time order, up to `time`.
    mutating func advance(to time: TimeInterval) {
        while true {
            if let end = runEnd, end <= time, timer.map({ end <= $0 }) ?? true {
                runEnd = nil
                if let due = gate.finished(at: end) { timer = due }
                continue
            }
            guard let due = timer, due <= time else { return }
            timer = nil
            if gate.fire(at: due) {
                start(at: due)
            } else if gate.isRunning {
                firedWhileRunning.append(due) // the run's end reschedules
            } else {
                timer = gate.due
            }
        }
    }

    mutating func start(at time: TimeInterval) {
        gate.started(at: time)
        runs.append(time)
        if runTime > 0 {
            runEnd = time + runTime
        } else if let due = gate.finished(at: time) {
            timer = due
        }
    }

    mutating func change(at time: TimeInterval) {
        advance(to: time)
        if let due = gate.changed(at: time) { timer = due }
    }

    mutating func show(_ visible: Bool, at time: TimeInterval) {
        advance(to: time)
        if visible, let due = gate.setVisible(true, at: time) { timer = due }
        if !visible {
            _ = gate.setVisible(false, at: time)
            timer = nil
        }
    }

    /// A refresh asked for directly (a commit made here, a fetch): it runs now, whatever the gate says.
    mutating func refreshNow(at time: TimeInterval) {
        advance(to: time)
        start(at: time)
        timer = gate.due
    }
}

/// Times equal to well under a millisecond: 0.4 + 2.5 is not the literal 2.9 in floating point.
func same(_ a: [TimeInterval], _ b: [TimeInterval]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-6 }
}

@Suite struct RefreshGateTests {
    @Test func aChangeAfterQuietRefreshesSoon() {
        var clock = GateClock()
        clock.change(at: 0)
        clock.change(at: 0.1)
        clock.change(at: 0.2) // a burst: an agent writing fifty files
        clock.advance(to: 5)
        #expect(clock.runs == [0.4])
        #expect(clock.gate.interval == 2.5 && clock.gate.settle == 0.4)
    }

    @Test func aChangeEveryTenthOfASecondRefreshesAtMostEveryTwoAndAHalfSeconds() {
        var clock = GateClock()
        var t = 0.0
        while t < 10 {
            clock.change(at: t)
            t += 0.1
        }
        let lastChange = t - 0.1
        clock.advance(to: 60)
        let during = clock.runs.filter { $0 <= 10 }
        #expect(during.count <= 5)
        #expect(clock.runs.count <= 6)
        // Always one after the last change, so it is seen.
        #expect((clock.runs.last ?? 0) > lastChange)
        #expect((clock.runs.last ?? 0) - lastChange <= 2.5)
        for (a, b) in zip(clock.runs, clock.runs.dropFirst()) { #expect(b - a >= 2.5 - 1e-9) }
    }

    @Test func aChangeShowsWithinThreeSecondsEvenRightAfterARefresh() {
        var clock = GateClock()
        clock.change(at: 0)
        clock.advance(to: 0.4)
        clock.change(at: 0.41) // just missed the refresh at 0.4
        clock.advance(to: 10)
        #expect(same(clock.runs, [0.4, 2.9]))
    }

    @Test func hiddenGivesNoneAndShowingAgainGivesOne() {
        var clock = GateClock()
        clock.change(at: 0)
        clock.advance(to: 1)
        #expect(clock.runs == [0.4])
        clock.show(false, at: 1)
        var t = 1.0
        while t < 30 {
            clock.change(at: t)
            t += 0.5
        }
        clock.advance(to: 40)
        #expect(clock.runs == [0.4], "nothing while hidden")
        clock.show(true, at: 40)
        clock.advance(to: 60)
        #expect(clock.runs == [0.4, 40], "one refresh on showing again")
    }

    @Test func showingAgainWithNothingMissedRefreshesNothing() {
        var clock = GateClock()
        clock.change(at: 0)
        clock.advance(to: 1)
        clock.show(false, at: 2)
        clock.show(true, at: 3)
        clock.show(false, at: 3.5)
        clock.show(true, at: 4)
        clock.advance(to: 20)
        #expect(clock.runs == [0.4])
    }

    @Test func hidingDropsADueRefreshAndShowingBringsItBack() {
        var clock = GateClock()
        clock.change(at: 0)
        clock.advance(to: 0.4)
        clock.change(at: 1) // due at 2.9
        clock.show(false, at: 2)
        clock.advance(to: 10)
        #expect(same(clock.runs, [0.4]))
        clock.show(true, at: 11)
        clock.advance(to: 12)
        #expect(same(clock.runs, [0.4, 11]))
        // Shown again soon after a refresh: the one it owes waits out the interval.
        clock.show(false, at: 12)
        clock.change(at: 12.5)
        clock.show(true, at: 13)
        clock.advance(to: 20)
        #expect(same(clock.runs, [0.4, 11, 13.5]))
        // A refresh asked for directly while hidden covers the changes before it.
        clock.show(false, at: 20)
        clock.change(at: 21)
        clock.refreshNow(at: 22)
        clock.show(true, at: 30)
        clock.advance(to: 40)
        #expect(same(clock.runs, [0.4, 11, 13.5, 22]))
        // Shown and hidden again before the owed one was due: still owed.
        clock.refreshNow(at: 41)
        clock.show(false, at: 41.5)
        clock.change(at: 42)
        clock.show(true, at: 42.5) // due at 43.5
        clock.show(false, at: 43)
        clock.show(true, at: 50)
        clock.advance(to: 60)
        #expect(same(clock.runs, [0.4, 11, 13.5, 22, 41, 50]))
    }

    @Test func aDirectRefreshCountsAndCoversWhatCameBefore() {
        var clock = GateClock()
        clock.change(at: 0) // due at 0.4
        clock.refreshNow(at: 0.2)
        clock.advance(to: 2)
        #expect(clock.runs == [0.2], "the due one is covered")
        clock.change(at: 2) // due at 2.7, the interval after 0.2
        clock.advance(to: 10)
        #expect(same(clock.runs, [0.2, 2.7]))
    }

    @Test func aTimerThatFiresEarlyWaits() {
        var gate = RefreshGate()
        let first = gate.changed(at: 0)
        let again = gate.changed(at: 0.2)
        #expect(first == 0.4 && again == nil) // already due, and it starts after this change
        let early = gate.fire(at: 0.1)
        #expect(!early && gate.due == 0.4)
        let onTime = gate.fire(at: 0.4)
        #expect(onTime && gate.due == nil)
        let stale = gate.fire(at: 0.5)
        #expect(!stale, "a stale timer starts nothing")
        gate.started(at: 0.4)
        let firedWhileRunning = gate.fire(at: 3)
        #expect(gate.isRunning && !firedWhileRunning)
        let whileRunning = gate.changed(at: 0.5)
        #expect(whileRunning == nil && gate.due != nil, "due, but its timer waits for the end")
        let afterRun = gate.finished(at: 0.6)
        #expect(same([afterRun ?? 0], [2.9]))
        let fired = gate.fire(at: 2.9)
        #expect(fired)
        gate.started(at: 2.9)
        _ = gate.finished(at: 2.9)
        let next = gate.changed(at: 3)
        #expect(same([next ?? 0], [5.4]))
        gate.cancel()
        let cancelled = gate.fire(at: 5.4)
        #expect(gate.due == nil && !cancelled)
    }

    /// A refresh that takes 0.3 s (a 20,000-file repository) keeps the 2.5 s pace under a writer twice a second:
    /// 8 in 20 s, as measured.
    @Test func aQuickRefreshKeepsTheInterval() {
        var clock = GateClock(runTime: 0.3)
        var t = 0.0
        while t < 20 {
            clock.change(at: t)
            t += 0.5
        }
        clock.advance(to: 30)
        #expect(clock.runs.filter { $0 < 20 }.count == 8)
        for (a, b) in zip(clock.runs, clock.runs.dropFirst()) { #expect(abs(b - a - 2.5) < 1e-6) }
        #expect(clock.firedWhileRunning.isEmpty)
    }

    /// A refresh that takes 3 s (a huge monorepo) under a steady writer: never one on top of another, a rest of
    /// three times its length after each, so git is busy a quarter of the time at most, and one after the last
    /// change still comes.
    @Test func aSlowRefreshKeepsGitBusyAQuarterOfTheTimeAtMost() {
        var clock = GateClock(runTime: 3)
        var t = 0.0
        while t < 120 {
            clock.change(at: t)
            t += 0.1
        }
        let lastChange = t - 0.1
        clock.advance(to: 300)
        for (a, b) in zip(clock.runs, clock.runs.dropFirst()) { #expect(b - (a + 3) >= 9 - 1e-6, "rest after the run at \(a)") }
        let busy = Double(clock.runs.filter { $0 < 120 }.count) * 3
        #expect(busy / 120 <= 0.25 + 3 / 120.0)
        #expect((clock.runs.last ?? 0) > lastChange)
        #expect(clock.firedWhileRunning.isEmpty, "no timer goes off while a run goes on")
    }

    /// A change while a refresh runs: the refresh may not have seen it, so one comes after it, once it has rested.
    @Test func aChangeDuringARunGetsARefreshAfterIt() {
        var clock = GateClock(runTime: 1)
        clock.change(at: 0) // runs 0.4 to 1.4
        clock.change(at: 1) // during it: due at 2.9, but the run's rest lasts to 1.4 + 3
        clock.advance(to: 20)
        #expect(same(clock.runs, [0.4, 4.4]))
        // Hidden while it runs: the change is owed, and showing again after the rest brings it.
        var hidden = GateClock(runTime: 1)
        hidden.change(at: 0)
        hidden.advance(to: 0.5)
        hidden.change(at: 1)
        hidden.show(false, at: 1.2)
        hidden.advance(to: 10)
        #expect(same(hidden.runs, [0.4]))
        hidden.show(true, at: 10)
        hidden.advance(to: 20)
        #expect(same(hidden.runs, [0.4, 10]))
    }
}
