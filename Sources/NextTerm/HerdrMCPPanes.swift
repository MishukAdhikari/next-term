import AppKit
import NextTermCore

/// Plan 040 U1–U4 over MCP: herdr's own commands for what its CLI does with panes. start_agent beside a pane or in a shell
/// pane (`pane split`, `agent start`), wait_for_tab until a state or a text (`agent wait --until`, `pane wait-output`),
/// rename_tab on an agent the caller started (`agent rename`), and new_tab beside a herdr pane running a command (`pane
/// split`, `pane run`), whose pane read_tab reads and close_tab closes. Every write asks on the Mac first, as start_agent
/// and close_tab already did; herdr does the work, Next Term never copies it.
extension HerdrMCP {
    /// Who started each agent and each pane over MCP (start_agent, new_tab beside a herdr pane), by its id: rename_tab
    /// renames only the caller's own, as MCPTabOpeners keeps it for tabs. Callers outside the tabs share one key.
    @MainActor private static var openers: [String: String] = [:]

    private static func openerKey(_ caller: TerminalTab?) -> String { caller?.id.uuidString ?? "outside" }

    @MainActor static func recordOpener(_ id: String, caller: TerminalTab?) { openers[id] = openerKey(caller) }

    /// Who started or made the agent, pane, tab or workspace with this id over MCP, as recordOpener keeps it.
    @MainActor static func openerOf(_ id: String) -> String? { openers[id] }

    private static func failure(_ text: String) -> MCPServer.CallResult { MCPControl.fail(text) }
    private static func success(_ value: Any) -> MCPServer.CallResult { MCPControl.ok(value) }

    /// The pane an id names, after its tab's checks, with or without an agent in it: the tab is there and follows herdr,
    /// the id is a pane id herdr would take, and a machine is one herdr there still lists.
    static func pane(_ target: HerdrTarget) -> Result<HerdrAgentRef, MCPControl.MCPError> {
        guard let tab = MCPControl.tab(withID: target.tabID) else { return .failure(.init("No tab with that id; list_tabs shows them.")) }
        guard HerdrTarget.isPane(target.pane) else {
            return .failure(.init("“\(target.pane)” is not a herdr pane id; list_tabs shows the agents' ids."))
        }
        guard tab.followsHerdr else {
            let why = tab.herdrWatch.note.map { " (\($0))" } ?? ""
            return .failure(.init("That tab does not follow herdr now\(why); list_tabs shows its state."))
        }
        if let machine = target.machine, LocalHerdrWatch.shared.machines(of: tab)?.machine(machine) == nil {
            return .failure(.init("herdr in that tab no longer lists the machine \(machine); list_tabs shows its agents."))
        }
        return .success(HerdrAgentRef(tab: tab, machine: target.machine, pane: target.pane))
    }

    /// A pane id herdr lists no agent in (one new_tab ran a command in, or a shell): read and closed as a pane.
    static func isPlainPane(_ target: HerdrTarget) -> Bool {
        guard case .success(let ref) = pane(target) else { return false }
        return ref.agent == nil
    }

    /// read_tab on a plain pane: herdr's own read of its recent output.
    @MainActor static func readPane(_ target: HerdrTarget, lines: Int, reply: @escaping Reply) {
        let ref: HerdrAgentRef
        switch pane(target) {
        case .failure(let error): return reply(failure(error.text))
        case .success(let found): ref = found
        }
        let count: Int = min(HerdrCommand.maxLines, max(1, lines))
        ref.run(.read(pane: target.pane, source: .recent, lines: count)) { result in
            if let problem = problem(result, pane: target.pane, sent: false) { return reply(failure(problem)) }
            guard case .text(let text) = result else { return reply(failure("herdr gave no text for \(target.pane).")) }
            reply(success(["id": ref.id, "state": "pane", "screen": screen(text, lines: count)]))
        }
    }

    /// wait_for_tab with `until` (an agent's states: `agent wait --until`) or `match` (text its pane shows: `pane
    /// wait-output`, a regular expression with regex: true). herdr itself waits, for timeout_seconds at most; a wait that
    /// ends without it answers timed_out, as a tab's does, with the pane's last lines.
    static func herdrWait(_ target: HerdrTarget, _ arguments: [String: Any], reply: @escaping Reply) {
        let ref: HerdrAgentRef
        switch pane(target) {
        case .failure(let error): return reply(failure(error.text))
        case .success(let found): ref = found
        }
        let seconds: Int = min(300, max(1, arguments["timeout_seconds"] as? Int ?? 50))
        let command: HerdrCommand
        var input: String?
        if let match = arguments["match"] as? String {
            guard !match.isEmpty else { return reply(failure("Give match: the text to wait for.")) }
            if let refusal = HerdrCommand.textRefusal(match) { return reply(failure(refusal)) }
            command = .waitOutput(pane: target.pane, regex: arguments["regex"] as? Bool ?? false, timeout: seconds * 1000)
            input = match
        } else {
            let raw: Any? = arguments["until"]
            let states: [String] = (raw as? [String]) ?? (raw as? String).map { [$0] } ?? []
            guard ref.agent != nil else {
                return reply(failure("herdr lists no agent in \(target.pane): until waits for an agent's state; match waits for text."))
            }
            command = .waitAgent(pane: target.pane, states: states.map { $0.lowercased() }, timeout: seconds * 1000)
        }
        if let refusal = command.refusal(session: nil, machine: target.machine) { return reply(failure(refusal)) }
        ref.run(command, input: input, timeout: Double(seconds) + 10) { result in
            var info: [String: Any] = ["id": ref.id]
            if let agent = ref.agent { info["state"] = agent.status.rawValue }
            if case .error(let code, _) = result, code == "timeout" {
                info["timed_out"] = true
            } else if let problem = problem(result, pane: target.pane, sent: false) {
                return reply(failure(problem))
            } else {
                info["timed_out"] = false
            }
            ref.run(.read(pane: target.pane, source: .recent, lines: 40), timeout: 10) { read in
                if case .text(let text) = read { info["screen"] = screen(text, lines: 40) }
                reply(success(info))
            }
        }
    }

    /// rename_tab on an agent's id (U3): herdr renames it (`agent rename`); an empty title clears herdr's name. Only the
    /// agents the caller started; the user renames any of them from the herdr Agent menu.
    @MainActor static func renameAgent(_ target: HerdrTarget, _ arguments: [String: Any], caller: TerminalTab?,
                                       herdrCaller: [String: String], reply: @escaping Reply) {
        let found: (ref: HerdrAgentRef, agent: HerdrAgent)
        switch agent(target, caller: caller, herdrCaller: herdrCaller, typing: false) {
        case .failure(let error): return reply(failure(error.text))
        case .success(let pair): found = pair
        }
        guard openers[found.ref.id] == openerKey(caller) else { return reply(failure(renameRefusal)) }
        let title: String = (arguments["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let command = HerdrCommand.rename(pane: found.agent.paneID, name: title.isEmpty ? nil : title)
        if let refusal = command.refusal(session: nil, machine: target.machine) { return reply(failure(refusal + " Nothing was renamed.")) }
        found.ref.run(command) { result in
            if let problem = problem(result, pane: found.agent.paneID, sent: false) { return reply(failure(problem)) }
            reply(success(["id": found.ref.id, "name": title.isEmpty ? NSNull() : title as Any, "renamed": true]))
        }
    }

    static let renameRefusal = "rename_tab renames only the herdr agents you started (start_agent); the user renames the others from the herdr Agent menu."

    /// Renames an agent for the user (the herdr Agent menu's Rename…): the same herdr command, no caller rule. The
    /// completion gets why it did not, or nil.
    @MainActor static func renameForUser(_ ref: HerdrAgentRef, pane: String, to name: String?, completion: @escaping (String?) -> Void) {
        let command = HerdrCommand.rename(pane: pane, name: name)
        if let refusal = command.refusal(session: nil, machine: ref.machine) { return completion(refusal) }
        ref.run(command) { result in completion(problem(result, pane: pane, sent: false)) }
    }

    /// close_tab on a pane herdr lists no agent in (U4): asked on the Mac first; never the caller's own pane, a machine's,
    /// nor the session's last; only while herdr still lists the pane.
    @MainActor static func closePlainPane(_ target: HerdrTarget, _ arguments: [String: Any], caller: TerminalTab?,
                                          herdrCaller: [String: String], reply: @escaping Reply) {
        if target.machine != nil {
            return reply(failure("That pane is on one of herdr's own machines: Next Term never closes those. Nothing was closed."))
        }
        let ref: HerdrAgentRef
        switch pane(target) {
        case .failure(let error): return reply(failure(error.text))
        case .success(let found): ref = found
        }
        if isCaller(target.pane, in: ref.tab, caller: herdrCaller) { return reply(failure("That is your own herdr pane. Nothing was closed.")) }
        ref.run(.panes) { counted in
            MainActor.assumeIsolated {
                guard case .json(let text) = counted, let panes = HerdrPanes.parse(text) else {
                    let why: String = problem(counted, pane: "", sent: false) ?? "herdr did not list its panes there."
                    return reply(failure(why + " Nothing was closed."))
                }
                guard panes.tabOf[target.pane] != nil else { return reply(failure("herdr no longer lists \(target.pane) there. Nothing was closed.")) }
                if let refusal = panes.lastPaneRefusal { return reply(failure(refusal)) }
                let place: String = ref.tab.remote.map { "on \($0.host.name)" } ?? "on this Mac"
                let ask = MCPWriteControl.Ask(title: "An agent asks to close a herdr pane",
                                              details: "Pane \(target.pane) in herdr \(place): what runs there stops. Next Term runs: herdr pane close \(target.pane)")
                let context = MCPWriteControl.context(arguments, caller: caller, approval: .askOnMac, requester: nil, connection: nil)
                MCPWriteControl.approve(ask, context, reply: reply) { approved, window in
                    window?.finish()
                    ref.run(.closePane(pane: target.pane)) { result in
                        if let problem = problem(result, pane: target.pane, sent: false) { return reply(failure(problem)) }
                        reply(success(["id": ref.id, "closed": true, "approved": approved]))
                    }
                }
            }
        }
    }

    /// new_tab with split_beside a herdr agent's or pane's id and a command (U4): herdr splits that pane and runs the
    /// command in the new one (`pane split`, then `pane run`), once the user approves on the Mac. The answer's id is the
    /// new pane's, for read_tab, wait_for_tab (match) and close_tab.
    @MainActor static func runBeside(_ target: HerdrTarget, _ arguments: [String: Any], caller: TerminalTab?, reply: @escaping Reply) {
        if target.machine != nil {
            return reply(failure("Next Term runs commands only in the herdr server's own panes, not on its machines. Nothing ran."))
        }
        let ref: HerdrAgentRef
        switch pane(target) {
        case .failure(let error): return reply(failure(error.text))
        case .success(let found): ref = found
        }
        guard let command = (arguments["command"] as? String)?.trimmingCharacters(in: .whitespaces), !command.isEmpty else {
            return reply(failure("Give command: what to run in the new herdr pane."))
        }
        guard !command.contains("\n") else { return reply(failure("The command must be one line.")) }
        if let refusal = HerdrCommand.textRefusal(command) { return reply(failure(refusal)) }
        let direction: HerdrCommand.SplitDirection = (arguments["direction"] as? String) == "down" ? .down : .right
        let directory: String? = (arguments["directory"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let split = HerdrCommand.split(pane: target.pane, direction: direction, directory: directory)
        if let refusal = split.refusal(session: nil) { return reply(failure(refusal + " Nothing ran.")) }
        let place: String = ref.tab.remote.map { "on \($0.host.name)" } ?? "on this Mac"
        let side: String = direction == .down ? "below" : "beside"
        let ask = MCPWriteControl.Ask(title: "An agent asks to run a command in herdr",
                                      details: "In a new pane \(side) \(target.pane), in herdr \(place): \(SecretApprovalPanel.sanitized(command, limit: 300)). Next Term runs: herdr pane split \(target.pane) --direction \(direction.rawValue), then herdr pane run <its pane> with that command.")
        let context = MCPWriteControl.context(arguments, caller: caller, approval: .askOnMac, requester: nil, connection: nil)
        MCPWriteControl.approve(ask, context, reply: reply) { approved, window in
            window?.finish()
            ref.run(split) { made in
                MainActor.assumeIsolated {
                    if let problem = problem(made, pane: target.pane, sent: false) { return reply(failure(problem + " Nothing ran.")) }
                    guard case .json(let json) = made, let pane = HerdrCommand.splitPane(json) else {
                        return reply(failure("herdr split \(target.pane) but named no new pane Next Term could read. Nothing ran."))
                    }
                    let id: String = HerdrTarget(tabID: ref.tab.id.uuidString, pane: pane).id
                    recordOpener(id, caller: caller)
                    ref.run(.run(pane: pane), input: command) { ran in
                        if let problem = problem(ran, pane: pane, sent: false) {
                            return reply(failure("herdr made pane \(pane), but the command did not start: \(problem) close_tab with \(id) closes it."))
                        }
                        reply(success(["id": id, "pane": pane, "approved": approved]))
                    }
                }
            }
        }
    }

    /// start_agent's place (U1): a new pane split beside `split_beside` (a herdr pane id in that tab, or an agent's full
    /// id), or an existing shell pane (`pane`); both nil for today's new herdr tab.
    static func startPlace(_ arguments: [String: Any]) -> (split: String?, direction: HerdrCommand.SplitDirection, pane: String?) {
        func bare(_ raw: Any?) -> String? {
            guard let text = (raw as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
            return HerdrTarget.parse(text)?.pane ?? text
        }
        let direction: HerdrCommand.SplitDirection = (arguments["direction"] as? String) == "down" ? .down : .right
        return (bare(arguments["split_beside"]), direction, bare(arguments["pane"]))
    }
}
