import Foundation

/// Tells a turn that hears only lines Next Term doesn't know (plan 035 R9, U7): Codex's app-server notifications of an
/// unknown method, Claude Code's stream-json lines of an unknown type. After `quiet` seconds of nothing else, the agent's
/// protocol has changed under the session, which then ends with its note rather than hanging.
public struct ProtocolDriftWatch: Equatable, Sendable {
    /// How long only unknown lines may arrive.
    public static let quiet: TimeInterval = 60

    /// Unknown lines in this turn.
    public private(set) var unknownCount = 0
    private var lastKnown: Date?
    /// An unknown line came since the last known one.
    private var unknownSinceKnown = false

    public init() {}

    /// A turn starts: count from nothing.
    public mutating func turnStarted(at now: Date) {
        unknownCount = 0
        unknownSinceKnown = false
        lastKnown = now
    }

    /// A line read at `now`: one Next Term doesn't know, one it knows, or one that ends the turn (which stops the watch).
    public mutating func observe(unknown: Bool, ends: Bool, at now: Date) {
        guard lastKnown != nil else { return }
        if ends {
            lastKnown = nil
            unknownSinceKnown = false
        } else if unknown {
            unknownCount += 1
            unknownSinceKnown = true
        } else {
            lastKnown = now
            unknownSinceKnown = false
        }
    }

    /// Whether the turn has heard only unknown lines for `quiet` seconds.
    public func isDrifting(at now: Date) -> Bool {
        guard let lastKnown, unknownSinceKnown else { return false }
        return now.timeIntervalSince(lastKnown) >= Self.quiet
    }

    /// A Codex event: an unknown notification counts, a turn's end, a sign-in failure or drift stops the watch.
    public mutating func observe(_ event: CodexAppServer.Event, at now: Date) {
        switch event {
        case .unknownNotification: observe(unknown: true, ends: false, at: now)
        case .turnEnded, .authFailure, .drift: observe(unknown: false, ends: true, at: now)
        default: observe(unknown: false, ends: false, at: now)
        }
    }

    /// A Claude Code event: a line of an unknown type counts, a turn's end or a sign-in failure stops the watch.
    public mutating func observe(claude event: ClaudeStream.Event, at now: Date) {
        switch event {
        case .unknownLine: observe(unknown: true, ends: false, at: now)
        case .turnEnded, .authFailure: observe(unknown: false, ends: true, at: now)
        default: observe(unknown: false, ends: false, at: now)
        }
    }
}
