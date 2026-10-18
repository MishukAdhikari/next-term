import AppKit
import NextTermCore

/// One of herdr's agents as Next Term reaches it: through a tab that shows herdr, and, for a herdr that runs in a tab on
/// this Mac, on one of the machines saved in it (`machine`, herdr's id for it), reached through that herdr
/// (`--machine`). What MCP, Peek, Go to Agent and the notices do to an agent goes through this, so a machine's agents
/// take the same paths as the herdr server's own.
struct HerdrAgentRef {
    let tab: TerminalTab
    let machine: String?
    let pane: String

    init(tab: TerminalTab, machine: String? = nil, pane: String) {
        self.tab = tab
        self.machine = machine
        self.pane = pane
    }

    /// Its id over MCP and for its notices (HerdrTarget).
    var id: String { HerdrTarget(tabID: tab.id.uuidString, machine: machine, pane: pane).id }

    /// The tracker that follows it: the tab's own, or its machine's.
    var tracker: HerdrAgents? {
        guard let machine else { return tab.herdrTracker }
        return LocalHerdrWatch.shared.machines(of: tab)?.machine(machine)?.tracker
    }

    /// herdr's agent as last listed; nil once herdr no longer lists it.
    var agent: HerdrAgent? { tracker?.agents.first { $0.paneID == pane } }

    /// The machine's label in herdr ("Build machine"), for one on a machine.
    var machineLabel: String? { machine.flatMap { LocalHerdrWatch.shared.machines(of: tab)?.machine($0)?.label } }

    /// Runs `command` for it, through the tab's herdr, on its machine when it has one.
    func run(_ command: HerdrCommand, input: String? = nil, timeout: TimeInterval = 15, completion: @escaping (HerdrResult) -> Void) {
        HerdrRunner.run(command, for: tab, machine: machine, input: input, timeout: timeout, completion: completion)
    }

    /// The user acted on it (a notice's button, its Reply): Next Term's unread flag clears and its notice goes, in
    /// every tab of the session for the tab's own agents.
    func seen() {
        guard let machine else { return tab.herdrSeen(pane) }
        LocalHerdrWatch.shared.machines(of: tab)?.machine(machine)?.tracker.seen(pane)
        AppDelegate.shared.withdrawHerdrNotice(id)
        tab.delegate?.tabDidChange(tab)
    }

    /// What a read of its pane found (answer_agent's, or the watch's own): its question, or none.
    func questionRead(seq: Int?, text: String?, menu: AgentMenu?) {
        guard let machine else { return tab.herdrQuestionRead(pane, seq: seq, text: text, menu: menu) }
        LocalHerdrWatch.shared.machines(of: tab)?.questionRead(machine, pane: pane, seq: seq, text: text, menu: menu)
    }
}
