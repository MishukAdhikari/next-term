import NextTermCore

/// What a tab's screen shows, as its agent's own shapes read it.
extension TerminalTab {
    /// The tab shows OpenCode: OpenCode runs in it, or the program in front titles itself as OpenCode does
    /// ("OpenCode", "OC | <session>"), as OpenCode over ssh or in Next Term's own tmux does. Only such a tab reads
    /// OpenCode's screen shapes (AgentScreen.Opencode); every other agent's tab never sees them.
    var isOpencodeScreen: Bool {
        if AgentKind(program: status.program) == .opencode { return true }
        guard let programTitle else { return false }
        return AgentScreen.isOpencode(title: programTitle)
    }
}
