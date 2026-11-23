import Foundation

/// How often the windows' shared clock beats (WindowTicker), from what the windows show: as fast as a person can
/// notice only while they can see something running, and rarely when nothing runs at all.
public enum TickerPace: TimeInterval, Sendable {
    /// Next Term is the app in use and a window someone can see runs a command or an agent.
    case watching = 0.25
    /// Something runs, but in a window no one is looking at, or with another app in use.
    case background = 1
    /// Nothing runs anywhere.
    case idle = 2

    /// How long output keeps the beat at the watching pace, so what follows a keystroke (a command starting, a `cd`
    /// the sidebar follows, a file appearing) shows as quickly as it always has.
    public static let afterOutput: TimeInterval = 2

    /// The pace for these windows: each one whether it can be seen and whether something runs in it; `recentOutput`
    /// when a terminal printed within `afterOutput`.
    public static func pace(active: Bool, windows: [(seen: Bool, runs: Bool)], recentOutput: Bool = false) -> TickerPace {
        if active && windows.contains(where: { $0.seen && ($0.runs || recentOutput) }) { return .watching }
        return windows.contains(where: \.runs) ? .background : .idle
    }

    /// The beat's tolerance: a quarter of it, so macOS can fold the wakeup in with others.
    public var tolerance: TimeInterval { rawValue / 4 }
}
