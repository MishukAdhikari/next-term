import Foundation

/// When a refresh set off by file changes runs (the sidebar's git refresh, its Databases scan). The first change
/// after a quiet spell waits `settle`, so a burst (an agent writing fifty files) is one refresh; after that, at most
/// one refresh starts every `interval`, and there is always one after the last change. While the window can't be
/// seen nothing runs; when it shows again, one refresh runs if a change came meanwhile.
///
/// One runs at a time, and a slow one earns a rest: the next starts no sooner than `restFactor` times its length
/// after it ended, so in a repository where `git status` takes seconds a steady writer keeps git busy a quarter of
/// the time at most, not all of it. A quick one (a few tenths of a second) leaves the pace at `interval`.
///
/// A refresh asked for directly (after a commit made here, a fetch) runs at once whatever this says, and counts:
/// tell it with `started` and `finished`. Pure: it is told the time (seconds on any steady clock), and the caller
/// keeps one timer for `due`.
public struct RefreshGate: Sendable {
    public let interval: TimeInterval
    public let settle: TimeInterval
    public let restFactor: Double
    public private(set) var isVisible = true
    /// When the next refresh is due, if one is.
    public private(set) var due: TimeInterval?
    /// A refresh has started and not finished: nothing else starts until it does.
    public private(set) var isRunning = false
    private var lastStart: TimeInterval?
    /// The end of the last refresh plus its rest.
    private var restedAt: TimeInterval?
    /// A change came while the window was hidden, and no refresh has started since.
    private var owed = false

    public init(interval: TimeInterval = 2.5, settle: TimeInterval = 0.4, restFactor: Double = 3) {
        self.interval = interval
        self.settle = settle
        self.restFactor = restFactor
    }

    /// The earliest a refresh may start, after one due at `time`.
    private func earliest(_ time: TimeInterval) -> TimeInterval {
        var start = time
        if let lastStart { start = max(start, lastStart + interval) }
        if let restedAt { start = max(start, restedAt) }
        return start
    }

    /// Something changed at `now`. The time to start a refresh at, when a timer is needed for it; nil when one
    /// is already due (it starts after this change, so it sees it), one is running (its end says when the next
    /// one is due) or the window is hidden.
    public mutating func changed(at now: TimeInterval) -> TimeInterval? {
        guard isVisible else {
            owed = true
            return nil
        }
        guard due == nil else { return nil }
        let time = earliest(now + settle)
        due = time
        return isRunning ? nil : time
    }

    /// The timer went off at `now`: whether to start the refresh. False for one fired early (a timer is still
    /// needed for `due`), while one runs (its end reschedules) or when none is wanted any more.
    public mutating func fire(at now: TimeInterval) -> Bool {
        guard let time = due, isVisible, !isRunning else { return false }
        guard now >= time - 0.05 else { return false }
        due = nil
        return true
    }

    /// A refresh started at `now`, from the timer or asked for directly: it sees every change before it.
    public mutating func started(at now: TimeInterval) {
        lastStart = now
        isRunning = true
        due = nil
        owed = false
    }

    /// The refresh that started last ended at `now`. The time to start the next at, when a change came while it
    /// ran (it may not have seen it).
    public mutating func finished(at now: TimeInterval) -> TimeInterval? {
        guard isRunning else { return nil }
        isRunning = false
        if let lastStart { restedAt = now + restFactor * max(0, now - lastStart) }
        guard let time = due else { return nil }
        due = earliest(time)
        return due
    }

    /// The window was shown or hidden at `now`. The time to start a refresh at, when one is owed on showing.
    public mutating func setVisible(_ visible: Bool, at now: TimeInterval) -> TimeInterval? {
        guard visible != isVisible else { return nil }
        isVisible = visible
        if !visible {
            if due != nil { owed = true }
            due = nil
            return nil
        }
        guard owed else { return nil }
        owed = false
        let time = earliest(now)
        due = time
        return isRunning ? nil : time
    }

    /// Nothing is due or owed any more (the folder changed, or its window closed). A refresh still running
    /// still ends with `finished`.
    public mutating func cancel() {
        due = nil
        owed = false
    }
}
