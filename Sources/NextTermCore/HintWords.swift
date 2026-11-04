import Foundation

/// What each hint says (plan 033 R3): short, starting with a verb, saying what to do and never how good it is, with keys
/// as the live shortcut table has them, so a user's own key reads correctly.
public enum HintWords {
    /// H1, at the foot of the window column's hover list: the button's lead, its words and its tooltip, for the side the
    /// column is not on.
    public static func columnSide(onRight: Bool) -> (lead: String, words: String, help: String) {
        let edge: String = onRight ? "left" : "right"
        return ("⇄", "Move to the \(edge) edge", "Or ask your agent: “put the window column on the \(edge)”.")
    }

    /// H2, at the window column's foot: Go to Next Agent Needing You's key, as the user has it. No key, no hint: there
    /// is nothing short to say, and the Agents menu still has it.
    public static func nextAgent(key: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        return "Press \(key) to jump to it"
    }

    /// H3, beside the rail's foot, the first time the column shows.
    public static let columnBasics = "Rest here to see your windows · double-click to keep open"

    /// The × on every hint, for VoiceOver and its tooltip: it closes the tip for good.
    public static let close = "Close Tip"
}

extension WindowColumnList {
    /// The rows that now show a window needing you or failed where `old` did not: a mark has just appeared in them
    /// (H2's trigger). A row already marked, or one whose mark only changed between the two, is not new.
    public func newlyUrgent(since old: WindowColumnList) -> [WindowColumnRow] {
        func marked(_ state: TabState?) -> Bool { state == .attention || state == .failed }
        return rows.filter { (row: WindowColumnRow) -> Bool in
            guard marked(row.urgent) else { return false }
            // Its windows as they were: the row itself, or the repository's row it was folded into.
            let before: [WindowColumnRow] = ([row.id] + row.hidden).compactMap { old.row(showing: $0) }
            return !before.contains { marked($0.urgent) }
        }
    }
}
