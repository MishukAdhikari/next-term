import Foundation

/// Tells a turn that hears only lines Next Term doesn't know (plan 035 R9, U7): Codex's app-server notifications of an
/// unknown method, Claude Code's stream-json lines of an unknown type. When unknown lines keep arriving for `quiet`
/// seconds with no known one among them, the agent's protocol has changed under the session, which then ends with its
/// note rather than hanging.
///
/// Silence is never drift: a tool that runs for minutes without a word, or the user thinking over a menu, says nothing
/// either way. Only a run of unknown lines counts, each within `gap` seconds of the one before, the last one recent, and
/// the run `quiet` seconds long. A session waiting on the user (a menu or a question on the Mac) is never drifting.
public struct ProtocolDriftWatch: Equatable, Sendable {
    /// How long only unknown lines may keep arriving.
    public static let quiet: TimeInterval = 60
    /// The longest pause between two unknown lines of one run, and since the last of them.
    public static let gap: TimeInterval = 10
    /// How long the handshake (Claude Code's `initialize`, Codex's `initialize` to `thread/start`) may go unanswered
    /// before the session ends with the drift note.
    public static let startupTimeout: TimeInterval = 30

    /// Unknown lines in this turn.
    public private(set) var unknownCount = 0
    /// A turn is being watched.
    private var watching = false
    /// The first and the last unknown line of the current run: none since the last known line, or a gap, broke it.
    private var runStart: Date?
    private var lastUnknown: Date?

    public init() {}

    /// A turn starts: count from nothing.
    public mutating func turnStarted(at now: Date) {
        unknownCount = 0
        watching = true
        runStart = nil
        lastUnknown = nil
    }

    /// A line read at `now`: one Next Term doesn't know, one it knows, or one that ends the turn (which stops the watch).
    public mutating func observe(unknown: Bool, ends: Bool, at now: Date) {
        guard watching else { return }
        if ends {
            watching = false
            runStart = nil
            lastUnknown = nil
        } else if unknown {
            unknownCount += 1
            if let last = lastUnknown, runStart != nil, now.timeIntervalSince(last) <= Self.gap {
                // The run goes on.
            } else {
                runStart = now
            }
            lastUnknown = now
        } else {
            runStart = nil
            lastUnknown = nil
        }
    }

    /// Whether unknown lines, and only those, have kept arriving for `quiet` seconds. Never while the session waits on
    /// the user (`waitingOnUser`): a menu, a question, or an Allow always asked on the Mac.
    public func isDrifting(at now: Date, waitingOnUser: Bool = false) -> Bool {
        guard watching, !waitingOnUser, let runStart, let lastUnknown else { return false }
        guard now.timeIntervalSince(lastUnknown) <= Self.gap else { return false }
        return now.timeIntervalSince(runStart) >= Self.quiet
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
