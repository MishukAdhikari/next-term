import AppKit
import NextTermCore

/// The machines saved in a herdr that runs in a tab on this Mac, and their agents, read through that herdr only: its
/// `machine list --json` every 30 s, and one `herdr --machine <id> agent list` per 2-second check, in turn over the
/// first four enabled machines, each with 5 s to answer (`--machine` rides herdr's own SSH connection to the machine;
/// Next Term opens none). Each machine's agents are followed as a herdr tab's are (a tracker of their own): they go in
/// Go to Agent under "<label> (herdr)", count in the Dock badge and post their notices; they are not tab-list rows,
/// which stay that herdr's own server's. A machine that fails three reads in a row is one item, "herdr can't reach
/// it", until a read works. Nothing is written to herdr's list of machines, and everything stops when that herdr
/// leaves its tab.
final class HerdrMachineWatch {
    /// One of herdr's machines, followed.
    final class Machine {
        let id: String
        var label: String
        var tracker = HerdrAgents()
        /// Reads in a row that failed, and what the last one said.
        var failures = 0
        var problem: String?
        /// A read of a blocked agent's pane for its question is running.
        var reading = false

        init(id: String, label: String) {
            self.id = id
            self.label = label
        }

        /// herdr reached it at one of its last three reads.
        var reachable: Bool { failures < HerdrMachines.failuresBeforeUnreachable }
    }

    /// The tab whose herdr this is (the first of that herdr's tabs).
    private(set) weak var tab: TerminalTab?
    private(set) var machines: [Machine] = []
    private var listedAt: TimeInterval = -.infinity
    private var tick = 0
    private var busy = false

    static let listEvery: TimeInterval = 30
    static let readTimeout: TimeInterval = 5

    init(tab: TerminalTab) {
        self.tab = tab
    }

    func machine(_ id: String) -> Machine? { machines.first { $0.id == id } }

    /// The owner of a machine's notices (AppDelegate.herdrDelivered).
    func owner(_ machine: Machine) -> String { "machine:\(tab?.id.uuidString ?? "")/\(machine.id)" }

    /// One 2-second check: herdr's list of machines when it is due, else one machine's agents, in turn.
    func check() {
        guard !busy, let tab, !tab.exited, tab.localHerdr != nil else { return }
        if TerminalTab.now - listedAt >= Self.listEvery { return list(tab) }
        let followed = machines.map { HerdrMachine(id: $0.id, label: $0.label) }
        guard let next = HerdrMachines.machine(at: tick, of: followed) else { return }
        tick &+= 1
        read(next.id, in: tab)
    }

    /// herdr's machines: before herdr 0.9.0, or on any error, none.
    private func list(_ tab: TerminalTab) {
        busy = true
        listedAt = TerminalTab.now
        HerdrRunner.run(.machines, for: tab, timeout: 10) { [weak self] result in
            guard let self else { return }
            self.busy = false
            var listed: [HerdrMachine] = []
            if case .json(let text) = result { listed = HerdrMachines.parse(text) ?? [] }
            self.take(HerdrMachines.followedMachines(listed))
        }
    }

    /// The machines followed now: each kept with what it had, a new one added, one herdr no longer lists (or disabled)
    /// dropped with its notices.
    private func take(_ listed: [HerdrMachine]) {
        var kept: [Machine] = []
        for found in listed {
            let machine = self.machine(found.id) ?? Machine(id: found.id, label: found.label)
            machine.label = found.label
            kept.append(machine)
        }
        let ids = Set(listed.map(\.id))
        for gone in machines where !ids.contains(gone.id) { AppDelegate.shared.withdrawHerdrNotices(owner: owner(gone)) }
        machines = kept
        if let tab { tab.delegate?.tabDidChange(tab) }
    }

    private func read(_ id: String, in tab: TerminalTab) {
        busy = true
        HerdrRunner.run(.list, for: tab, machine: id, timeout: Self.readTimeout) { [weak self] result in
            guard let self else { return }
            self.busy = false
            guard let machine = self.machine(id) else { return }
            var listing: HerdrListing?
            if case .json(let text) = result { listing = HerdrAgent.listing(output: text, exit: 0) }
            guard case .agents(let agents) = listing else {
                machine.failures += 1
                machine.problem = HerdrMCP.problem(result, pane: "", sent: false) ?? "herdr did not list its agents there."
                if !machine.reachable, !machine.tracker.agents.isEmpty {
                    machine.tracker = HerdrAgents()
                    AppDelegate.shared.withdrawHerdrNotices(owner: self.owner(machine))
                }
                tab.delegate?.tabDidChange(tab)
                return
            }
            machine.failures = 0
            machine.problem = nil
            self.follow(machine, agents, in: tab)
        }
    }

    /// One read's list of a machine's agents: each followed, decisions and finishes posted, out-of-date notices withdrawn.
    /// None of them is on screen: herdr cannot be told which machine its screen shows.
    private func follow(_ machine: Machine, _ agents: [HerdrAgent], in tab: TerminalTab) {
        let events = machine.tracker.update(TerminalTab.masked(agents), focusedTab: nil, tabVisible: false, now: TerminalTab.now)
        for event in events {
            switch event {
            case .needsDecision(let pane): post(machine, pane, decision: true, duration: nil)
            case .finished(let pane, let duration): post(machine, pane, decision: false, duration: duration)
            case .needsRead, .resolved, .gone: break
            }
        }
        readQuestion(machine, in: tab)
        AppDelegate.shared.withdrawStaleHerdrNotices(owner: owner(machine), tracker: machine.tracker)
        tab.delegate?.tabDidChange(tab)
    }

    private func post(_ machine: Machine, _ pane: String, decision: Bool, duration: TimeInterval?) {
        guard let tab, let agent = machine.tracker.agents.first(where: { $0.paneID == pane }) else { return }
        let question = decision ? machine.tracker.question(pane)?.text ?? "\(agent.name) (\(pane)) needs a decision" : nil
        AppDelegate.shared.post(machineAgent: agent, question: question, duration: duration, machine: machine, owner: owner(machine), tab: tab)
    }

    /// The next blocked agent's question, read from its own pane on its machine, one read at a time.
    private func readQuestion(_ machine: Machine, in tab: TerminalTab) {
        guard !machine.reading, let next = machine.tracker.nextRead else { return }
        machine.reading = true
        let ref = HerdrAgentRef(tab: tab, machine: machine.id, pane: next.pane)
        ref.run(.read(pane: next.pane, source: .visible, lines: nil), timeout: Self.readTimeout) { [weak self] result in
            machine.reading = false
            var found: (text: String, menu: AgentMenu?)?
            if case .text(let screen) = result { found = HerdrAgents.question(onScreen: screen) }
            self?.questionRead(machine.id, pane: next.pane, seq: next.seq, text: found?.text, menu: found?.menu)
            self?.readQuestion(machine, in: tab)
        }
    }

    /// What a read of a machine agent's pane found (here, or answer_agent's own read).
    func questionRead(_ id: String, pane: String, seq: Int?, text: String?, menu: AgentMenu?) {
        guard let machine = machine(id) else { return }
        machine.tracker.setQuestion(pane: pane, seq: seq, text: text, choices: menu?.choices ?? [], style: menu?.style)
    }

    /// That herdr left its tab, or the tab closed: every machine's notices go.
    func end() {
        for machine in machines { AppDelegate.shared.withdrawHerdrNotices(owner: owner(machine)) }
        machines = []
    }
}
