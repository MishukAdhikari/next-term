import Foundation

/// new_tab's rules that need no window: the line it types, and the window a linked worktree's folder opens in.
extension MCPServer {
    /// What new_tab types: `command`, then `prompt` quoted for the shell (ShellQuote), so an agent never quotes the user's
    /// words itself, where `$(…)`, backticks and `$` would run.
    public static func commandLine(_ command: String, prompt: String?) -> String {
        guard let prompt, !prompt.isEmpty else { return command }
        return command + " " + ShellQuote.quote(prompt)
    }

    /// When `directory` is in a linked worktree that sits inside `owner`, the project of an open window (a worktree in
    /// its .claude/worktrees): that worktree, which new_tab opens in a window of its own, titled "repo ▸ folder", as Open
    /// Worktree does. nil: the owner's window it is.
    public static func ownWorktree(of directory: String, inside owner: String) -> String? {
        let root = canonicalPath(ProjectRoot.find(from: directory)), owner = canonicalPath(owner)
        guard root.hasPrefix(owner + "/"), WorktreeWindow.repository(ofLinkedWorktree: root) != nil else { return nil }
        return root
    }
}
