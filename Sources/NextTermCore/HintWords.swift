import Foundation

/// What each hint says (plan 033 R3): short, starting with a verb, saying what to do and never how good it is, with keys
/// as the live shortcut table has them, so a user's own key reads correctly.
public enum HintWords {
    /// H1, at the foot of the window column's hover list: the button's lead, its words and its tooltip, for the side the
    /// column is not on.
    public static func columnSide(onRight: Bool) -> (lead: String, words: String, help: String) {
        let edge: String = onRight ? "left" : "right"
        return ("⇄", "Move column \(edge)", "Or ask your agent: ‘put the window column on the \(edge)’.")
    }

    /// H2, at the window column's foot: Go to Next Agent Needing You's key, as the user has it. No key, no hint: there
    /// is nothing short to say, and the Agents menu still has it.
    public static func nextAgent(key: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        return "Press \(key) to jump to it"
    }

    /// H3, beside the rail's foot, the first time the column shows.
    public static let columnBasics = "Rest here to see your windows"

    /// H7, in the terminal's tab bar after its divider was dragged to an extreme: a button that moves the terminal to
    /// the right of the editor, the common layout, and its tooltip naming the menu and the agent's way. Terminal
    /// Position has no key, so there is none to name.
    public static let terminalBeside = (words: "Move terminal to the right",
                                        help: "Or ⋯ › Move Terminal To. Or ask your agent: ‘put the terminal on the right’.")

    /// What Send to Agent's quiet button says, in a diff's toolbar and in H4: its key as the user has it, then the verb
    /// and the agent ("⌥⌘K Ask Claude Code"); without a key, the words alone. One feature, one phrase.
    public static func ask(agent: String, key: String?) -> String {
        [key, "Ask \(agent)"].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
    }

    /// H4, in the editor's tab bar while lines are selected and an agent waits for a prompt: the diff's own words, and
    /// help that says what a click does and how an agent can ask for the selection itself.
    public static func sendSelection(agent: String, key: String?) -> (words: String, help: String) {
        (ask(agent: agent, key: key), "Types the selected lines into \(agent)’s prompt. Or ask your agent: ‘look at my selection’.")
    }

    /// H8, at the window column's foot: a button that folds the first repository's worktrees into its row, and help
    /// that names it and says how they come back. No agent tool folds them, so there is no "ask your agent".
    public static func foldWorktrees(repository: String) -> (words: String, help: String) {
        ("Fold worktrees", "Folds \(repository)’s worktrees into its row. Its arrow shows them again.")
    }

    /// H5, at the front window's column foot after the second switch by a click there: Open Project…'s key, as the user
    /// has it, then Return, which picks the window just left. No key, no hint: the key is the point. ↩ is the Welcome
    /// list's default button, not a shortcut, so it is fixed.
    public static func switchBack(key: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        return "Press \(key) then ↩ to go back"
    }

    /// H5's help: the agent's way, naming the project to go back to when the window left has one.
    public static func switchBackHelp(project: String?) -> String {
        guard let project, !project.isEmpty else { return "Or ask your agent to switch to another project." }
        return "Or ask your agent: ‘switch to the \(project) project’."
    }

    /// The × on every hint, for VoiceOver and its tooltip: it closes the tip for good.
    public static let close = "Close Tip"
}

extension WindowColumnList {
    /// H8: the repositories' rows whose worktrees' windows could fold into them now, in the column's order: not folded,
    /// with `atLeast` worktree rows under them, each with how many.
    public func foldable(atLeast: Int = 2) -> [(row: WindowColumnRow, worktrees: Int)] {
        var found: [(row: WindowColumnRow, worktrees: Int)] = []
        for (index, row) in rows.enumerated() where row.foldKey != nil && !row.isFolded {
            let under: Int = rows[(index + 1)...].prefix { $0.depth > 0 }.count
            if under >= atLeast { found.append((row, under)) }
        }
        return found
    }

    /// H8's trigger in the pinned column: a repository's row that is foldable now with more worktree rows under it than
    /// `old` showed (its second one opened, or a third). Nil when none grew.
    public func newlyFoldable(since old: WindowColumnList) -> WindowColumnRow? {
        let before: [Int: Int] = Dictionary(old.foldable(atLeast: 0).map { ($0.row.id, $0.worktrees) }, uniquingKeysWith: { first, _ in first })
        return foldable().first { $0.worktrees > before[$0.row.id] ?? 0 }?.row
    }

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
