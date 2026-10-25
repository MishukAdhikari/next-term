import Foundation

/// What VoiceOver hears of suggestions while typing: one quiet announcement per new suggestion, half a second after typing
/// stops, never the suggestion read as part of the line (the overlay is no accessibility element). Typing through a
/// suggestion (a trim) is not a new one, but it is typing: the half second starts again. A suggestion that goes before its
/// time says nothing.
public struct GhostAnnouncer: Sendable {
    /// What is said (Settings › Terminal › While typing › VoiceOver says).
    public enum Words: String, CaseIterable, Sendable {
        /// "git checkout main, → accepts".
        case whole
        /// "Suggestion, → accepts".
        case short
        case none
    }

    /// How long after the last key or new suggestion it is said.
    public static let delay: TimeInterval = 0.5

    /// The suggestion waiting to be said, and since when nothing new was typed or suggested.
    private var pending: String?
    private var since: TimeInterval = 0

    public init() {}

    /// A new suggestion shows: `command`, the whole of it.
    public mutating func suggested(_ command: String, at time: TimeInterval) {
        pending = command
        since = time
    }

    /// A key that kept the suggestion (typed through it): the wait starts again.
    public mutating func typed(at time: TimeInterval) {
        since = max(since, time)
    }

    /// The suggestion went: nothing to say.
    public mutating func hidden() {
        pending = nil
    }

    /// When to look again for something to say; nil when nothing waits.
    public var dueAt: TimeInterval? { pending == nil ? nil : since + Self.delay }

    /// What to say at `time`, once: nil before its time, after it was said, or with `none`.
    public mutating func due(at time: TimeInterval, words: Words) -> String? {
        guard let command = pending, time >= since + Self.delay else { return nil }
        pending = nil
        return Self.text(command, words: words)
    }

    public static func text(_ command: String, words: Words) -> String? {
        switch words {
        case .whole: return "\(command), → accepts"
        case .short: return "Suggestion, → accepts"
        case .none: return nil
        }
    }
}
