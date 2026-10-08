import AppKit
import NextTermCore

/// Where each local agent tab's agent works: its own folder, not its tab shell's, which stays where the agent
/// was started. The branch popup's worktree rows and its agent guard credit agents by it.
/// Design: claudedocs/2026-10-09-brainstorm-branch-aware-agents (R6).
final class AgentPlaces {
    static let shared = AgentPlaces()

    private init() {}

    // MARK: what the app asks

    /// The folder `tab`'s agent works in: its process's own folder, or the one its session record names after
    /// a `cd` its process didn't make; never the shell's, which stays where the agent was started. The
    /// branch popup credits agents to worktrees by it, and its agent guard looks for agents by it.
    func agentFolder(of tab: TerminalTab) -> String {
        Self.readFolder(of: tab, pid: tcgetpgrp(tab.view.process.childfd))
    }

    /// The agent's folder, read now: its process's (the agent leads the pty's foreground group), or the folder
    /// Claude Code's transcript names last when that was written since the agent started (its shell's `cd`).
    static func readFolder(of tab: TerminalTab, pid: Int32) -> String {
        let status = tab.status
        guard pid > 0, let since = status.runningSince else { return tab.liveDirectory }
        let started = SessionStore.startDate(of: tab, since: since)
        let agent = AgentKind(program: status.program) ?? AgentKind(program: CommandClassifier.programName(status.expandedCommand))
        let record = agent == .claude ? AgentLocation.claudeFolder(pid: pid, home: SessionStore.home) : nil
        let process = ProcessInspector.currentDirectory(of: pid)
        return AgentLocation.folder(process: process, processSince: started, record: record, startedAt: started) ?? tab.liveDirectory
    }
}
