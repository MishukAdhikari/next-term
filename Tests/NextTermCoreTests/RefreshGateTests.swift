import Foundation
import Testing
@testable import NextTermCore

/// Drives a RefreshGate the way GitMonitor does, on a fake clock: one timer, fired in order.
struct GateClock {
    var gate = RefreshGate()
    var timer: TimeInterval?
    var runs: [TimeInterval] = []

    /// Fires the timer if it falls due by `time`; a refresh it starts takes no time here.
    mutating func advance(to time: TimeInterval) {
        while let due = timer, due <= time {
            timer = nil
            if gate.fire(at: due) {
                gate.started(at: due)
                runs.append(due)
            } else {
                timer = gate.due
            }
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
        gate.started(at: time)
        runs.append(time)
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
        let next = gate.changed(at: 1)
        #expect(same([next ?? 0], [2.9]))
        gate.cancel()
        let cancelled = gate.fire(at: 2.9)
        #expect(gate.due == nil && !cancelled)
    }
}
