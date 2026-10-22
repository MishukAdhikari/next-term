import Foundation
import NextTermCore

/// The tab side of AgentReadiness: a tab's own state, read into the plain values the check takes.
extension AgentReadiness {
    /// Every write into a tab: keys, pastes, and text anything typed there. A tab not running a local agent costs
    /// three stored flags and, only while some agent tab is watched, one dictionary lookup.
    func written(_ data: ArraySlice<UInt8>, tab: TerminalTab) {
        let agentRunning = Self.runsLocalAgent(tab)
        guard agentRunning || watchedCount > 0 else { return }
        let working = agentRunning && tab.status.state == .working
        written(data, id: tab.id, agentRunning: agentRunning, working: working)
    }

    /// Whether Next Term may type into the tab now, and if not, why. send_to_tab's busy and starting checks count,
    /// so a tab it would refuse is never offered.
    @MainActor func check(_ tab: TerminalTab) -> Verdict {
        let status = tab.status
        let agentRunning = Self.runsLocalAgent(tab)
        let working = status.state == .working
        let herdr = tab.remote?.keep == .herdr && !tab.fellBack
        // herdr's agents draw their prompt on the server: nothing here sees what is typed there.
        let line: Bool? = herdr ? nil : lineHasText(tab.id, agentRunning: agentRunning, working: working)
        let agent: AgentKind? = TaskWriter.agent(of: tab)
        var values = Tab(state: status.state, question: status.question, agent: agent, lineHasText: line)
        values.remote = tab.remote != nil
        values.herdr = herdr
        values.exited = tab.exited
        values.busy = MCPControl.isBusy(tab)
        values.starting = MCPControl.isStarting(tab)
        values.locked = MCPInputLine.refusal(tab) != nil
        return Self.check(values)
    }

    private static func runsLocalAgent(_ tab: TerminalTab) -> Bool {
        tab.remote == nil && tab.status.running && tab.status.kind == .agent
    }
}
