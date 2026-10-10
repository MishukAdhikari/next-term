import Foundation

/// When a git refresh set off by file changes runs. The first change after a quiet spell waits `settle`, so a
/// burst (an agent writing fifty files) is one refresh; after that, at most one refresh starts every
/// `interval`, and there is always one after the last change. While the window can't be seen nothing runs;
/// when it shows again, one refresh runs if a change came meanwhile.
///
/// A refresh asked for directly (after a commit made here, a fetch) runs at once whatever this says, and
/// counts: tell it with `started`. Pure: it is told the time (seconds on any steady clock), and the caller
/// keeps one timer for `due`.
public struct RefreshGate: Sendable {
    public let interval: TimeInterval
    public let settle: TimeInterval
    public private(set) var isVisible = true
    /// When the next refresh is due, if one is.
    public private(set) var due: TimeInterval?
    private var lastStart: TimeInterval?
    /// A change came while the window was hidden, and no refresh has started since.
    private var owed = false

    public init(interval: TimeInterval = 2.5, settle: TimeInterval = 0.4) {
        self.interval = interval
        self.settle = settle
    }

    /// The earliest a refresh may start, after one due at `time`.
    private func earliest(_ time: TimeInterval) -> TimeInterval {
        guard let lastStart else { return time }
        return max(time, lastStart + interval)
    }

    /// Something changed at `now`. The time to start a refresh at, when a timer is needed for it; nil when one
    /// is already due (it starts after this change, so it sees it) or the window is hidden.
    public mutating func changed(at now: TimeInterval) -> TimeInterval? {
        guard isVisible else {
            owed = true
            return nil
        }
        guard due == nil else { return nil }
        let time = earliest(now + settle)
        due = time
        return time
    }

    /// The timer went off at `now`: whether to start the refresh. False for one fired early (a timer is still
    /// needed for `due`) or no longer wanted.
    public mutating func fire(at now: TimeInterval) -> Bool {
        guard let time = due, isVisible else { return false }
        guard now >= time - 0.05 else { return false }
        due = nil
        return true
    }

    /// A refresh started at `now`, from the timer or asked for directly: it sees every change before it.
    public mutating func started(at now: TimeInterval) {
        lastStart = now
        due = nil
        owed = false
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
        return time
    }

    /// Nothing is due or owed any more (the folder changed, or its window closed).
    public mutating func cancel() {
        due = nil
        owed = false
    }
}
