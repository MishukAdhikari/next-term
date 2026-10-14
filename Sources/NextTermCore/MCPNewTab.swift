import Foundation

/// new_tab's rules that need no window: the line it types, and the window a linked worktree's folder opens in.
extension MCPServer {
    /// What new_tab types: `command`, then `prompt` quoted for the shell (ShellQuote), so an agent never quotes the user's
    /// words itself, where `$(…)`, backticks and `$` would run. OpenCode's after `--prompt` (`promptOption`).
    public static func commandLine(_ command: String, prompt: String?) -> String {
        guard let prompt, !prompt.isEmpty else { return command }
        return command + " " + promptOption(for: command) + ShellQuote.quote(prompt)
    }

    /// "--prompt " when `command` starts OpenCode's screen with no prompt yet: OpenCode reads a word after its options as
    /// the project folder (`opencode 'Fix the login test'` finds no such folder and exits), and takes a first prompt with
    /// `--prompt`. Its first word runs OpenCode (`opencodePrograms`, by name or path), and AgentCLI.opencode reads no
    /// one-shot in the rest: no `--prompt`, and no `run`, whose message is its words. Empty for every other command.
    static func promptOption(for command: String) -> String {
        let words: [String] = command.split(whereSeparator: { (character: Character) -> Bool in character.isWhitespace })
            .map { (word: Substring) -> String in String(word) }
        guard let program = words.first, opencodePrograms.contains((program as NSString).lastPathComponent) else { return "" }
        let reading: AgentCLI.Reading = AgentCLI.opencode.read(Array(words.dropFirst()))
        let takesPrompt: Bool = reading.pieces.contains { (piece: AgentCLI.Piece) -> Bool in
            guard case .known(_, _, let option) = piece else { return false }
            return option.kind == .oneShot
        }
        return takesPrompt ? "" : "--prompt "
    }

    /// OpenCode's command, 2.x's `opencode2` and npm's native `opencode.exe` (CommandClassifier's names for it).
    static let opencodePrograms: Set<String> = ["opencode", "opencode2", "opencode.exe"]

    /// When `directory` is in a linked worktree that sits inside `owner`, the project of an open window (a worktree in
    /// its .claude/worktrees): that worktree, which new_tab opens in a window of its own, titled "repo ▸ folder", as Open
    /// Worktree does. nil: the owner's window it is.
    public static func ownWorktree(of directory: String, inside owner: String) -> String? {
        let root = canonicalPath(ProjectRoot.find(from: directory)), owner = canonicalPath(owner)
        guard root.hasPrefix(owner + "/"), WorktreeWindow.repository(ofLinkedWorktree: root) != nil else { return nil }
        return root
    }
}
