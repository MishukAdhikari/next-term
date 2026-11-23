import Foundation

/// How often a look repeats while what it reads stays the same: each look that finds nothing new waits the next step
/// longer, up to the last, and a look that finds a change goes back to the first. Where each agent works is looked at
/// once a second while something moves, and every 4 seconds while nothing does (AgentPlaces).
public struct QuietBackoff: Sendable {
    public let steps: [TimeInterval]
    private var step = 0

    public init(steps: [TimeInterval] = [1, 2, 4]) {
        precondition(!steps.isEmpty)
        self.steps = steps
    }

    /// The wait before the next look.
    public var interval: TimeInterval { steps[step] }

    /// What the last look found. True when the wait changed, so the clock is set again.
    @discardableResult
    public mutating func note(moved: Bool) -> Bool {
        let before = step
        step = moved ? 0 : min(step + 1, steps.count - 1)
        return step != before
    }

    /// Back to the first step, whatever the last look found (an agent started or ended, Next Term moved HEAD itself).
    @discardableResult
    public mutating func reset() -> Bool { note(moved: true) }
}

/// When a costly listing is asked again: at once when what it depends on (`signature`) changed since the last, else
/// only once `every` has passed. Codex's open files are listed for its rollout at most every 4 seconds while its
/// folder stays the same; between listings the rollout found last is followed as it grows.
public struct Relisting: Sendable {
    public let every: TimeInterval
    private var last: (signature: String, at: Date)?

    public init(every: TimeInterval) {
        self.every = every
    }

    public func due(_ signature: String, at now: Date) -> Bool {
        guard let last else { return true }
        return last.signature != signature || now.timeIntervalSince(last.at) >= every
    }

    public mutating func listed(_ signature: String, at now: Date) {
        last = (signature, now)
    }
}

/// How often herdr run in local tabs is asked for its agents (LocalHerdrWatch): every 2 seconds while a window following
/// it can be seen and Next Term is the app in use, or while one of its agents waits on a decision, so its question and
/// its answer show as soon as they did; every 6 seconds otherwise, which still brings notices and the Dock badge within
/// a few seconds. Each `herdr` run is a process, so the slower pace is most of what an unseen herdr costs.
public enum HerdrPace {
    public static let watching: TimeInterval = 2
    public static let background: TimeInterval = 6

    public static func interval(seen: Bool, active: Bool, deciding: Bool) -> TimeInterval {
        deciding || (seen && active) ? watching : background
    }
}
