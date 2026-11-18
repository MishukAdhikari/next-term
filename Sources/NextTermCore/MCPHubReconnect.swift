import Foundation

/// When Next Term tries again, on its own, to reach an MCP server at a URL it couldn't reach (plan: reconnect on its own).
/// A server out of reach is tried again while Next Term is the active app, after waiting longer each time (15 seconds,
/// then 30, 1, 2, 5 and 10 minutes), and at once when the Mac wakes or the network comes back, which also starts the
/// waits over. Only servers that need no key from Secrets are tried (those are released only for an agent's need), and
/// never one that needs a sign-in, which only the user can give. Pure: the app keeps the entries and runs the checks.
public enum MCPHubReconnect {
    public static let waits: [TimeInterval] = [15, 30, 60, 120, 300, 600]

    public struct Entry: Equatable, Sendable {
        /// Tries made since the server was last reached, or since the waits started over.
        public var tries: Int
        public var lastTry: Date

        public init(tries: Int = 0, lastTry: Date) {
            self.tries = tries
            self.lastTry = lastTry
        }

        /// When the next try is due.
        public var due: Date { lastTry.addingTimeInterval(MCPHubReconnect.wait(after: tries)) }

        /// After a try that failed again.
        public mutating func tried(at now: Date) {
            tries += 1
            lastTry = now
        }

        /// The Mac woke or the network came back: due at once, and the waits start over.
        public mutating func startOver(at now: Date) {
            tries = 0
            lastTry = now.addingTimeInterval(-MCPHubReconnect.wait(after: 0))
        }
    }

    /// The wait before try `tries + 1`.
    public static func wait(after tries: Int) -> TimeInterval { waits[min(max(tries, 0), waits.count - 1)] }

    /// The entries due at `now`, by key.
    public static func due(_ entries: [String: Entry], at now: Date) -> [String] {
        entries.filter { $0.value.due <= now }.map(\.key).sorted()
    }

    /// The soonest an entry falls due, for the one timer the app sets.
    public static func next(_ entries: [String: Entry]) -> Date? { entries.values.map(\.due).min() }
}
