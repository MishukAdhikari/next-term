/// The notice at the bottom of a window after a git action (the app's GitToast), and which of two stays up. Notices are
/// numbered as they come up; work that ends in a notice may note the count as it begins.
public enum GitNotice {
    /// The notice up now: its number, and whether it has a button (Undo).
    public struct Shown: Equatable, Sendable {
        public var number: Int
        public var hasButton: Bool

        public init(number: Int, hasButton: Bool) {
            self.number = number
            self.hasButton = hasButton
        }
    }

    /// Whether a new notice takes the place of `current`. Each does but one: a plain notice (no button, not an error)
    /// for work begun before an Undo came up leaves that Undo up. A Fetch still reading the branches when a delete
    /// queued behind it says "Deleted feat/x … Undo" would otherwise take that Undo away with "Fetched: up to date".
    /// `begun`: the count when the new notice's work began; nil, none noted (Copied comes at once).
    public static func replaces(_ current: Shown?, hasButton: Bool, isError: Bool, begun: Int?) -> Bool {
        guard let current, current.hasButton, !hasButton, !isError, let begun else { return true }
        return current.number <= begun
    }
}
