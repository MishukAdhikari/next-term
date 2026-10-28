import AppKit
import NextTermCore

/// herdr's agents over MCP. Each one has an id of its own, its herdr tab's id, a slash and herdr's pane id (HerdrTarget),
/// which goes wherever a tab id goes: read_tab, wait_for_tab, send_to_tab, press_keys, answer_agent, show_tab and close_tab
/// are answered here (close_tab asks the user first), focus_tab by MCPWriteControl (it asks first too), and rename_tab and
/// the pane tools refuse one.
/// Every check a tab gets holds for its agents (not the caller's own, connected, not logging in, a line that is the
/// user's own), and every command is one of HerdrCommand's, run by HerdrRunner. Typing into an agent asks nothing, as
/// typing into a tab does, and makes that agent, not its whole herdr tab, driven: its finishes are the calling agent's
/// news while Next Term is in front, and its herdr neighbours' are still the user's.
enum HerdrMCP {
    typealias Reply = MCPControl.Reply

    private static func fail(_ text: String) -> MCPServer.CallResult { MCPControl.fail(text) }
    private static func ok(_ value: Any) -> MCPServer.CallResult { MCPControl.ok(value) }

    /// The most text one call sends to an agent.
    static let maxText = HerdrCommand.maxTextBytes

    // MARK: what list_tabs and host_sessions say

    /// One agent's fields, its text masked as a tab's is (MCPControl.field): pane, name (herdr's name for it: the one a
    /// naming plugin or the user gave it, when it has one), agent (what runs), state (herdr's), title, directory,
    /// workspace, tab and focused.
    static func fields(_ agent: HerdrAgent) -> [String: Any] {
        var entry: [String: Any] = ["pane": agent.paneID, "agent": MCPControl.field(agent.kind ?? "agent"), "state": agent.status.rawValue,
                                    "focused": agent.focused]
        if let name = agent.displayName ?? agent.customName { entry["name"] = MCPControl.field(name) }
        if let title = agent.title { entry["title"] = MCPControl.field(title) }
        if let directory = agent.directory { entry["directory"] = MCPControl.field(directory) }
        if let workspace = agent.workspaceID { entry["workspace"] = workspace }
        if let tab = agent.tabID { entry["tab"] = tab }
        return entry
    }

    /// list_tabs' entry for an agent of `tab`: its id, its fields, its session, its question while it waits on a
    /// decision, and "you" for the caller's own.
    static func entry(_ agent: HerdrAgent, in tab: TerminalTab, caller: [String: String]) -> [String: Any] {
        var entry = entry(agent, ref: HerdrAgentRef(tab: tab, pane: agent.paneID))
        if let session = tab.herdrSessionName { entry["session"] = session }
        if isCaller(agent.paneID, in: tab, caller: caller) { entry["you"] = true }
        return entry
    }

    /// The entry of an agent on one of the machines saved in `tab`'s herdr: `machine` (herdr's id and label) besides.
    static func entry(_ agent: HerdrAgent, in tab: TerminalTab, machine: HerdrMachineWatch.Machine) -> [String: Any] {
        var entry = entry(agent, ref: HerdrAgentRef(tab: tab, machine: machine.id, pane: agent.paneID))
        entry["machine"] = ["id": machine.id, "label": MCPControl.field(machine.label)]
        return entry
    }

    private static func entry(_ agent: HerdrAgent, ref: HerdrAgentRef) -> [String: Any] {
        var entry = fields(agent)
        entry["id"] = ref.id
        // How long it has waited (blocked, done or kept unread), since Next Term saw it start to.
        if let since = ref.tracker?.needsSince(agent.paneID) { entry["waiting_seconds"] = max(0, Int(TerminalTab.now - since)) }
        entry.merge(questionInfo(agent, ref: ref)) { $1 }
        return entry
    }

    /// The question read from a blocked agent's pane, its choices and the id answer_agent takes back.
    static func questionInfo(_ agent: HerdrAgent, ref: HerdrAgentRef) -> [String: Any] {
        guard agent.status == .blocked else { return [:] }
        guard let asked = ref.tracker?.question(agent.paneID) else {
            return ["question": MCPControl.field("\(agent.name) (\(agent.paneID)) needs a decision; read_tab shows its pane")]
        }
        var info: [String: Any] = ["question": MCPControl.field(asked.text), "question_id": questionID(asked, id: ref.id)]
        if !asked.choices.isEmpty { info["choices"] = asked.choices.map(MCPControl.field) }
        return info
    }

    static func questionID(_ asked: HerdrAgents.Question, pane: String, in tab: TerminalTab) -> String {
        questionID(asked, id: HerdrTarget(tabID: tab.id.uuidString, pane: pane).id)
    }

    /// A question's id, for the agent whose id (HerdrTarget) is `id`.
    static func questionID(_ asked: HerdrAgents.Question, id: String) -> String {
        AgentScreen.questionID(tab: id, serial: asked.serial, question: asked.text)
    }

    /// The caller runs in this pane of this herdr: the bridge says so (MCPCalls.Request.caller), for herdr on this Mac
    /// only (an agent on a server reaches no MCP socket here), and only when its socket is this tab's client's, if both
    /// are known.
    static func isCaller(_ pane: String, in tab: TerminalTab, caller: [String: String]) -> Bool {
        guard let client = tab.localHerdr, caller["herdr_pane"] == pane else { return false }
        guard let socket = caller["herdr_socket"], let own = client.environment["HERDR_SOCKET_PATH"] else { return true }
        return socket == own
    }

    // MARK: the tools

    /// A tool whose tab_id is an agent's id. Returns false for those MCPControl's own dispatch answers (focus_tab, which
    /// asks first; the pane tools, which refuse it by name; tools that take no tab).
    static func route(_ tool: String, _ target: HerdrTarget, _ arguments: [String: Any], caller: TerminalTab?,
                      herdrCaller: [String: String], reply: @escaping Reply) -> Bool {
        switch tool {
        case "read_tab", "wait_for_tab", "send_to_tab", "press_keys", "answer_agent", "show_tab":
            let typing = ["send_to_tab", "press_keys", "answer_agent"].contains(tool)
            let found: (ref: HerdrAgentRef, agent: HerdrAgent)
            switch agent(target, caller: caller, herdrCaller: herdrCaller, typing: typing) {
            case .failure(let error):
                reply(fail(error.text))
                return true
            case .success(let pair): found = pair
            }
            switch tool {
            case "read_tab": readTab(found.ref, found.agent, lines: arguments["lines"] as? Int ?? 80, reply: reply)
            case "wait_for_tab": waitFor(found.ref, arguments, reply: reply)
            case "send_to_tab": sendToTab(found.ref, found.agent, arguments, reply: reply)
            case "press_keys": pressKeys(found.ref, found.agent, arguments, reply: reply)
            case "answer_agent": answerAgent(found.ref, found.agent, arguments, reply: reply)
            default: reply(showTab(found.ref))
            }
            return true
        case "close_tab":
            MainActor.assumeIsolated { closeAgent(target, arguments, caller: caller, herdrCaller: herdrCaller, reply: reply) }
            return true
        case "rename_tab":
            reply(fail(TabRename.agentRefusal))
            return true
        default:
            return false
        }
    }

    /// start_agent (plan 010a U5b): one of herdr's agent kinds started in a new herdr tab of a tab that shows herdr, on that
    /// tab's own connection, once the user approves on the Mac, seeing herdr's commands. Every refusal comes first: the
    /// tab, the name, the kind (as herdr's own help lists its kinds there), the folder and the words. A tab herdr made for
    /// an agent that did not start stays, and the answer names it: Next Term never closes it by itself.
    @MainActor
    static func startAgent(_ arguments: [String: Any], caller: TerminalTab?, reply: @escaping Reply) {
        guard let raw = arguments["tab_id"] as? String, HerdrTarget.parse(raw) == nil, let tab = MCPControl.tab(withID: raw) else {
            return reply(fail("Give the id of a tab that shows herdr, from list_tabs (not one of its agents' ids)."))
        }
        guard tab.followsHerdr else {
            let why = tab.herdrWatch.note.map { " (\($0))" } ?? ""
            return reply(fail("That tab does not show herdr now\(why); new_remote_tab with keep herdr opens one on a server."))
        }
        guard let kind = (arguments["kind"] as? String)?.trimmingCharacters(in: .whitespaces), !kind.isEmpty else {
            return reply(fail("Give kind: one of herdr's agent kinds, such as claude or codex."))
        }
        let name: String = (arguments["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? kind
        // An empty folder is none: herdr's own folder, and the window shows no --cwd.
        let directory: String? = (arguments["directory"] as? String).map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
        // null counts as not given, as for the other tools.
        let given: Any? = arguments["words"].flatMap { $0 is NSNull ? nil : $0 }
        guard given == nil || given is [String] else { return reply(fail("words is a list of words, such as [\"--model\", \"opus\"].")) }
        let words: [String] = given as? [String] ?? []
        let begun = Date()
        // Every check that can refuse, before anything runs: the pane id stands in until herdr makes the tab.
        let newTab = HerdrCommand.newTab(directory: directory, label: name)
        let start = HerdrCommand.startAgent(name: name, kind: kind, pane: "w1:p1", words: words)
        if let refusal = newTab.refusal(session: nil) ?? start.refusal(session: nil) { return reply(fail(refusal + " Nothing was started.")) }
        HerdrRunner.run(.startKinds, for: tab) { result in
            MainActor.assumeIsolated {
                if let problem = problem(result, pane: "", sent: false) { return reply(fail(problem)) }
                guard case .text(let help) = result else { return reply(fail("herdr did not list its agent kinds there. Nothing was started.")) }
                let kinds: [String] = HerdrCommand.kinds(fromHelp: help)
                guard kinds.contains(kind) else {
                    let listed = kinds.isEmpty ? "none" : kinds.joined(separator: ", ")
                    return reply(fail("herdr there starts these kinds: \(listed). Nothing was started."))
                }
                askToStart(tab, name: name, kind: kind, words: words, newTab: newTab, begun: begun, arguments, caller: caller, reply: reply)
            }
        }
    }

    @MainActor
    private static func askToStart(_ tab: TerminalTab, name: String, kind: String, words: [String], newTab: HerdrCommand,
                                   begun: Date, _ arguments: [String: Any], caller: TerminalTab?, reply: @escaping Reply) {
        let place: String = tab.remote.map { "on \($0.host.name)" } ?? "on this Mac"
        let session: String? = tab.remote?.herdrSession ?? tab.localHerdr?.session
        let ask = MCPWriteControl.Ask(title: "An agent asks to start an agent in herdr",
                                      details: "\(kind), named “\(name)”, in a new herdr tab of herdr \(place) (\(session ?? "its default session")): it runs there until it ends. Next Term runs: \(shownCommands(newTab, name: name, kind: kind, words: words, session: session))")
        let context = MCPWriteControl.context(arguments, caller: caller, approval: .askOnMac, requester: nil, connection: nil)
        MCPWriteControl.approve(ask, context, reply: reply) { approved, window in
            window?.finish()
            guard tab.followsHerdr else { return reply(fail("That tab stopped showing herdr while you were asked. Nothing was started.")) }
            HerdrRunner.run(newTab, for: tab) { made in
                MainActor.assumeIsolated {
                    if let problem = problem(made, pane: "", sent: false) { return reply(fail(problem + " Nothing was started.")) }
                    guard case .json(let json) = made, let created = HerdrCommand.createdPane(json) else {
                        return reply(fail("herdr made no tab there that Next Term could read; read_tab on the herdr tab shows what happened."))
                    }
                    let start = HerdrCommand.startAgent(name: name, kind: kind, pane: created.pane, words: words)
                    startWhenReady(tab, start, created: created, begun: begun, firstTry: Date()) { started in
                        let id = tab.id.uuidString.lowercased() + "/" + created.pane
                        if let problem = problem(started, pane: created.pane) {
                            return reply(fail("herdr made tab \(created.tab) (pane \(created.pane)), but \(kind) did not start in it: \(problem) The tab stays; close_tab with \(id) closes that pane, and the tab with it, while herdr lists it; otherwise close it in herdr."))
                        }
                        driven.insert(id)
                        reply(ok(["id": id, "pane": created.pane, "herdr_tab": created.tab, "kind": kind, "name": name, "approved": approved]))
                    }
                }
            }
        }
    }

    /// The commands as the window shows them: herdr's own argument lists, each word shell-quoted, the new pane's id
    /// named for what it is.
    private static func shownCommands(_ newTab: HerdrCommand, name: String, kind: String, words: [String], session: String?) -> String {
        let quote: (String) -> String = { ShellQuote.quote($0) }
        let create: [String]? = newTab.argv(executable: "herdr", session: session, text: nil)?.first?.first
        // A valid pane id stands in, then shows as <its pane>: argv refuses an id herdr would not take.
        let start: [String]? = HerdrCommand.startAgent(name: name, kind: kind, pane: "w1:p1", words: words)
            .argv(executable: "herdr", session: session, text: nil)?.first?.first
        guard let create, let start else { return "herdr tab create, then herdr agent start" }
        var shown: [String] = start.map(quote)
        if let at = start.firstIndex(of: "--pane"), at + 1 < shown.count { shown[at + 1] = "<its pane>" }
        return create.map(quote).joined(separator: " ") + ", then " + shown.joined(separator: " ")
    }

    /// herdr answers these while the new pane's shell is not at its prompt yet.
    private static let paneNotReady: Set<String> = ["agent_pane_busy", "agent_pane_unavailable"]

    /// `agent start`, tried again every half second while herdr says the new pane is not ready, for up to 10 s, and only
    /// while a whole try still fits in start_agent's time (MCPServer: 120 s from the call).
    @MainActor
    private static func startWhenReady(_ tab: TerminalTab, _ start: HerdrCommand, created: (tab: String, pane: String),
                                       begun: Date, firstTry: Date, completion: @escaping (HerdrResult) -> Void) {
        let wait: Double = Double(HerdrCommand.startWait) / 1000 + 10
        HerdrRunner.run(start, for: tab, timeout: wait) { started in
            MainActor.assumeIsolated {
                guard case .error(let code, _) = started, paneNotReady.contains(code) else { return completion(started) }
                let now = Date()
                let retrying: Bool = now.timeIntervalSince(firstTry) < 10 && now.timeIntervalSince(begun) + 0.5 + wait < 118
                guard retrying else { return completion(started) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    startWhenReady(tab, start, created: created, begun: begun, firstTry: firstTry, completion: completion)
                }
            }
        }
    }

    /// close_tab with an agent's id (plan 010a U6b): herdr closes that agent's pane, and what runs there stops, once the
    /// user approves on the Mac, seeing the exact command. Every refusal comes first: the caller's own pane, an agent on
    /// one of herdr's machines, a working agent without force, the session's last pane. herdr closes the pane's tab with
    /// it when it was that tab's only pane, and the window says so (HerdrPanes); the session and its server stay. After
    /// Approve, herdr is asked again, not the last listing: the same pane must still run the same agent (kind and name),
    /// not working unless forced, and not be the session's last pane.
    @MainActor
    private static func closeAgent(_ target: HerdrTarget, _ arguments: [String: Any], caller: TerminalTab?,
                                   herdrCaller: [String: String], reply: @escaping Reply) {
        if target.machine != nil {
            return reply(fail("That agent runs on one of herdr's own machines: Next Term never ends those; stop it in herdr. Nothing was closed."))
        }
        let found: (ref: HerdrAgentRef, agent: HerdrAgent)
        switch agent(target, caller: caller, herdrCaller: herdrCaller, typing: true) {
        case .failure(let error): return reply(fail(error.text))
        case .success(let pair): found = pair
        }
        let force: Bool = arguments["force"] as? Bool ?? false
        let name: String = SecretApprovalPanel.sanitized(found.agent.name, limit: 60)
        if found.agent.status == .working, !force {
            return reply(fail("“\(name)” is working: pass force: true to end it anyway. Nothing was closed."))
        }
        let pane: String = found.agent.paneID
        found.ref.run(.panes) { counted in
            MainActor.assumeIsolated {
                let panes: HerdrPanes
                switch paneCount(counted) {
                case .failure(let error): return reply(fail(error.text))
                case .success(let read): panes = read
                }
                if let refusal = panes.lastPaneRefusal { return reply(fail(refusal)) }
                let tab = found.ref.tab
                let place: String = tab.remote.map { "on \($0.host.name)" } ?? "on this Mac"
                let closes: String = closing(pane, tab: found.agent.tabID, panes)
                let ask = MCPWriteControl.Ask(title: "An agent asks to end a herdr agent",
                                              details: "“\(name)” (\(pane), \(found.agent.status.rawValue)) in herdr \(place): \(closes) The session and its server keep running. Next Term runs: herdr pane close \(pane)")
                let context = MCPWriteControl.context(arguments, caller: caller, approval: .askOnMac, requester: nil, connection: nil)
                MCPWriteControl.approve(ask, context, reply: reply) { approved, window in
                    window?.finish()
                    closeAgain(found, force: force, approved: approved, reply: reply)
                }
            }
        }
    }

    /// After Approve: herdr's agents and panes read again, then the pane closed only if it is the agent the user was
    /// asked about. Nothing is run when herdr no longer lists it.
    @MainActor
    private static func closeAgain(_ found: (ref: HerdrAgentRef, agent: HerdrAgent), force: Bool, approved: String,
                                   reply: @escaping Reply) {
        let asked: HerdrAgent = found.agent
        let name: String = SecretApprovalPanel.sanitized(asked.name, limit: 60)
        found.ref.run(.list) { listed in
            MainActor.assumeIsolated {
                var agents: [HerdrAgent]?
                if case .json(let text) = listed, case .agents(let list) = HerdrAgent.listing(output: text, exit: 0) { agents = list }
                guard let agents else {
                    let why: String = problem(listed, pane: asked.paneID, sent: false) ?? "herdr did not list its agents there."
                    return reply(fail(why + " Nothing was closed."))
                }
                guard let now = agents.first(where: { $0.paneID == asked.paneID }) else {
                    return reply(ok(["id": found.ref.id, "closed": false, "note": "herdr no longer lists it, so nothing was run."]))
                }
                // The kind and herdr's own name: a naming plugin may change the shown name while the user is asked.
                guard now.kind == asked.kind, now.customName == asked.customName else {
                    return reply(fail("Pane \(asked.paneID) now runs another agent than the one you were asked about. Nothing was closed."))
                }
                if now.status == .working, !force {
                    return reply(fail("“\(name)” began working while you were asked: pass force: true to end it anyway. Nothing was closed."))
                }
                found.ref.run(.panes) { counted in
                    MainActor.assumeIsolated {
                        let panes: HerdrPanes
                        switch paneCount(counted) {
                        case .failure(let error): return reply(fail(error.text))
                        case .success(let read): panes = read
                        }
                        if let refusal = panes.lastPaneRefusal { return reply(fail(refusal)) }
                        let tab: String? = now.tabID ?? panes.tabOf[now.paneID]
                        let workspaceClosed: Bool = panes.isAloneInWorkspace(pane: now.paneID)
                        let tabClosed: Bool = workspaceClosed || panes.isAlone(tab: tab)
                        found.ref.run(.closePane(pane: now.paneID)) { result in
                            if let problem = problem(result, pane: now.paneID) { return reply(fail(problem)) }
                            reply(ok(["id": found.ref.id, "closed": true, "herdr_tab_closed": tabClosed,
                                      "herdr_workspace_closed": workspaceClosed, "approved": approved]))
                        }
                    }
                }
            }
        }
    }

    /// What closes with the pane, as the window says it: its workspace too when it is that workspace's only pane, its tab
    /// when it is that tab's only one (the tab from the agent list, else the pane list), and nothing more said when
    /// herdr gives neither.
    private static func closing(_ pane: String, tab: String?, _ panes: HerdrPanes) -> String {
        let tab: String? = tab ?? panes.tabOf[pane]
        if panes.isAloneInWorkspace(pane: pane) {
            return "herdr closes its pane, and its herdr tab and workspace with it (the pane is the only one in that workspace); what runs there stops."
        }
        if panes.isAlone(tab: tab) {
            return "herdr closes its pane, and its herdr tab with it (the pane is that tab's only one); what runs there stops."
        }
        if tab != nil { return "herdr closes its pane, and what runs there stops; the rest of its herdr tab stays." }
        return "herdr closes its pane, and what runs there stops."
    }

    /// herdr's panes counted, or why they could not be: nothing is closed without the count.
    private static func paneCount(_ result: HerdrResult) -> Result<HerdrPanes, MCPControl.MCPError> {
        if case .json(let text) = result, let panes = HerdrPanes.parse(text) { return .success(panes) }
        let why: String = problem(result, pane: "", sent: false) ?? "herdr did not list its panes there."
        return .failure(.init(why + " Nothing was closed."))
    }

    /// The agent an id names, after the checks its tab gets: the tab is there and follows herdr's agents, herdr lists the
    /// pane, and to type, the tab may take input and the pane is not the caller's own.
    static func agent(_ target: HerdrTarget, caller: TerminalTab?, herdrCaller: [String: String],
                      typing: Bool) -> Result<(ref: HerdrAgentRef, agent: HerdrAgent), MCPControl.MCPError> {
        guard let tab = MCPControl.tab(withID: target.tabID) else {
            return .failure(.init("No tab with that id; list_tabs shows them."))
        }
        if typing {
            switch MCPControl.target(["tab_id": target.tabID], caller: caller) {
            case .failure(let error): return .failure(error)
            case .success: break
            }
        }
        guard HerdrTarget.isPane(target.pane) else {
            return .failure(.init("“\(target.pane)” is not a herdr pane id; list_tabs shows the agents' ids."))
        }
        guard tab.followsHerdr else {
            let why = tab.herdrWatch.note.map { " (\($0))" } ?? ""
            return .failure(.init("That tab does not follow herdr's agents now\(why); list_tabs shows its state."))
        }
        let ref = HerdrAgentRef(tab: tab, machine: target.machine, pane: target.pane)
        if let machine = target.machine, LocalHerdrWatch.shared.machines(of: tab)?.machine(machine) == nil {
            return .failure(.init("herdr in that tab no longer lists the machine \(machine); list_tabs shows its agents."))
        }
        guard let agent = ref.agent else {
            return .failure(.init("herdr no longer lists \(target.pane) there; list_tabs shows its agents."))
        }
        if typing, target.machine == nil, isCaller(target.pane, in: tab, caller: herdrCaller) {
            return .failure(.init("That is your own herdr pane; type into another one."))
        }
        return .success((ref, agent))
    }

    /// What herdr's answer means for the caller, in a sentence; nil when it did what was asked.
    static func problem(_ result: HerdrResult, pane: String, sent: Bool = true) -> String? {
        let nothing = sent ? " Nothing was sent." : ""
        switch result {
        case .json, .text:
            return nil
        case let .error(code, message):
            switch code {
            case "agent_blocked": return "It waits on a decision: answer_agent answers it (list_tabs gives its question_id).\(nothing)"
            case "agent_not_found": return "herdr no longer has an agent in \(pane); list_tabs shows its agents.\(nothing)"
            case "agent_not_ready": return "herdr says the agent in \(pane) is not ready for input yet; try again in a moment.\(nothing)"
            case "timeout": return "herdr timed out: \(message)"
            case "": return "herdr said: \(message)"
            default: return "herdr refused (\(code)): \(message)"
            }
        case .unsupported(let verb):
            return "This herdr has no `herdr \(verb)`: update herdr there to use it from here.\(nothing)"
        case .cut:
            return "herdr's answer was cut off, so what it did is not known; read_tab shows the pane."
        case .unreachable(let why):
            return why
        }
    }

    private static func state(_ ref: HerdrAgentRef) -> String {
        ref.agent?.status.rawValue ?? "gone"
    }

    // MARK: read_tab

    private static func readTab(_ ref: HerdrAgentRef, _ agent: HerdrAgent, lines: Int, reply: @escaping Reply) {
        let count = min(HerdrCommand.maxLines, max(1, lines))
        ref.run(.read(pane: agent.paneID, source: .recent, lines: count)) { result in
            if let problem = problem(result, pane: agent.paneID, sent: false) { return reply(fail(problem)) }
            guard case .text(let text) = result else { return reply(fail("herdr gave no text for \(agent.paneID).")) }
            var info: [String: Any] = ["id": ref.id, "state": state(ref)]
            if let now = ref.agent { info.merge(questionInfo(now, ref: ref)) { $1 } }
            info["screen"] = screen(text, lines: count)
            reply(ok(info))
        }
    }

    /// A pane's text, its last `lines` lines, with stored keys masked over whole lines (as fieldTail masks a tab's).
    static func screen(_ text: String, lines: Int) -> String {
        var rows = text.components(separatedBy: "\n")
        while rows.last?.isEmpty == true { rows.removeLast() }
        let shown = Array(rows.suffix(lines))
        return (MCPControl.fieldMasks ? SecretMask.current.mask(rows: shown) : shown).joined(separator: "\n")
    }

    // MARK: wait_for_tab

    /// Text or keys sent to each agent, by its id: when, and herdr's count of its changes then, so a wait gives the work it
    /// starts 6 seconds to show (KTD10).
    private static var sent: [String: (at: TimeInterval, seq: Int?)] = [:]
    static let startWindow: TimeInterval = 6

    /// Text, keys or an answer went to an agent over MCP: that agent is driven, and the tab's run_with_secrets grants
    /// end, as for typing into it.
    private static func noteSent(_ ref: HerdrAgentRef, _ agent: HerdrAgent) {
        SecretRequests.tabGotInput(ref.tab.id)
        driven.insert(ref.id)
        sent[ref.id] = (TerminalTab.now, agent.stateSeq)
    }

    /// Agents an agent over MCP drives (prompted, sent keys or answered), by id, until the user types into their herdr
    /// tab or into Peek for them: while Next Term is in front, their finishes are that agent's news, not the user's
    /// (NotificationSettings.shouldNotify). Their herdr neighbours are not driven.
    private static var driven: Set<String> = []

    static func isDriven(_ id: String) -> Bool { driven.contains(id) }

    /// The user typed into the herdr tab: what its agents do is the user's again.
    static func userTyped(in tab: TerminalTab) {
        let prefix = tab.id.uuidString.lowercased() + "/"
        driven = driven.filter { !$0.hasPrefix(prefix) }
        for id in sent.keys where id.hasPrefix(prefix) { sent[id] = nil }
    }

    /// The user acted on one agent (Peek, a notice): that agent is the user's again.
    static func userActed(on id: String) {
        driven.remove(id)
    }

    /// The lines of its pane wait_for_tab gives, as many as a tab's.
    private static let waitLines = 40

    private static func waitFor(_ ref: HerdrAgentRef, _ arguments: [String: Any], reply: @escaping Reply) {
        let seconds = min(300, max(1, arguments["timeout_seconds"] as? Int ?? 50))
        wait(ref, until: TerminalTab.now + Double(seconds), reply: reply)
    }

    /// Done when herdr no longer says it works and what was sent had its 6 seconds to show (or showed); looked at every
    /// 250 ms in what the status checks left. Its answer has the pane's last lines, read then.
    private static func wait(_ ref: HerdrAgentRef, until deadline: TimeInterval, reply: @escaping Reply) {
        let id = ref.id
        let agent = ref.agent
        let busy = agent?.status == .working
        var starting = false
        if let last = sent[id], TerminalTab.now - last.at < startWindow {
            let changed = agent?.stateSeq != last.seq || busy
            if changed { sent[id] = nil } else { starting = true }
        }
        let gone = agent == nil || ref.tab.exited || !ref.tab.followsHerdr
        if gone || (!busy && !starting) || TerminalTab.now >= deadline {
            var info: [String: Any] = ["id": id, "state": agent?.status.rawValue ?? "gone", "timed_out": !gone && (busy || starting)]
            if let agent { info.merge(questionInfo(agent, ref: ref)) { $1 } }
            guard !gone, let agent else {
                info["note"] = "herdr no longer lists \(ref.pane) there (or the tab stopped following herdr); list_tabs shows its agents."
                return reply(ok(info))
            }
            // The last lines of its pane, as a tab's wait gives its screen; none when herdr gives none.
            let answer = info
            return ref.run(.read(pane: agent.paneID, source: .recent, lines: waitLines), timeout: 10) { result in
                var shown = answer
                if case .text(let text) = result { shown["screen"] = screen(text, lines: waitLines) }
                reply(ok(shown))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { wait(ref, until: deadline, reply: reply) }
    }

    // MARK: typing

    /// Text for an agent that cannot go (HerdrCommand.textRefusal): too long, one of herdr's own options, or holding a
    /// stored key's value.
    static func textRefusal(_ text: String) -> String? { HerdrCommand.textRefusal(text) }

    private static func sendToTab(_ ref: HerdrAgentRef, _ agent: HerdrAgent, _ arguments: [String: Any], reply: @escaping Reply) {
        let text = arguments["text"] as? String ?? ""
        let submit = arguments["submit"] as? Bool ?? true
        guard !text.isEmpty else { return reply(fail("Nothing to send: give the text.")) }
        if let refusal = textRefusal(text) { return reply(fail(refusal)) }
        // herdr forwards only its agent verbs to a machine: text without Return has none there.
        if ref.machine != nil, !submit {
            return reply(fail("herdr sends a machine's agents only whole prompts: give submit true, or press_keys. Nothing was sent."))
        }
        noteSent(ref, agent)
        ref.run(submit ? .prompt(pane: agent.paneID) : .text(pane: agent.paneID), input: text) { result in
            if let problem = problem(result, pane: agent.paneID) { return reply(fail(problem)) }
            reply(ok(["id": ref.id, "typed": text.count, "submitted": submit]))
        }
    }

    private static func pressKeys(_ ref: HerdrAgentRef, _ agent: HerdrAgent, _ arguments: [String: Any], reply: @escaping Reply) {
        let names = arguments["keys"] as? [String] ?? []
        guard !names.isEmpty, names.count <= 20 else { return reply(fail("Give 1 to 20 keys.")) }
        if let unknown = names.first(where: { HerdrKeys.map($0) == nil }) {
            return reply(fail("herdr takes no key “\(unknown)”. Nothing was sent."))
        }
        noteSent(ref, agent)
        ref.run(.keys(pane: agent.paneID, names)) { result in
            if let problem = problem(result, pane: agent.paneID) { return reply(fail(problem)) }
            reply(ok(["id": ref.id, "pressed": names]))
        }
    }

    // MARK: answer_agent

    /// Picks one of the choices of the question the agent's pane shows, if it is still the one the caller saw
    /// (HerdrAnswer): the pane is read again first, the arrows go (all of one answer in one `send-keys`), a second read
    /// checks that the cursor is on the choice and the question unchanged, then Return; a y/n prompt that took its letter
    /// needs none.
    private static func answerAgent(_ ref: HerdrAgentRef, _ agent: HerdrAgent, _ arguments: [String: Any], reply: @escaping Reply) {
        guard let given = arguments["question_id"] as? String, !given.isEmpty else {
            return reply(fail("Give question_id: the one that came with the question from list_tabs, read_tab or wait_for_tab."))
        }
        let choice = arguments["choice"], answer = arguments["answer"]
        if choice != nil && answer != nil { return reply(fail("Give choice or answer, not both.")) }
        if let choice, MCPServer.isBoolean(choice) || !(choice is Int) { return reply(fail("choice must be a whole number.")) }
        if let answer, !(answer is String) { return reply(fail("answer must be text.")) }
        Self.answer(ref, expected: given, choice: choice as? Int, answer: answer as? String, typing: { noteSent(ref, agent) }) { said in
            switch said {
            case .answered(let label, let index):
                reply(ok(["id": ref.id, "answered": MCPControl.field(label), "choice": index + 1]))
            case .failed(let problem):
                reply(fail(problem))
            case .refused(let refusal):
                reply(fail(sentence(refusal, ref: ref)))
            }
        }
    }

    /// A refusal in answer_agent's words, with what the calling agent can do next.
    private static func sentence(_ refusal: HerdrAnswer.Refusal, ref: HerdrAgentRef) -> String {
        switch refusal {
        case .notAsking:
            return "That agent is not asking anything now (state: \(state(ref))); nothing was typed. read_tab shows its pane."
        case let .changed(question, id):
            return "That question is gone; nothing was typed. The agent now asks “\(MCPControl.field(question))” (question_id \(id)): answer that one only if you mean to."
        case .noChoices(let question):
            return "The choices for “\(MCPControl.field(question))” cannot be read in that pane; nothing was typed. read_tab shows it, and press_keys can answer."
        case .badChoice(let why):
            return why + " Nothing was typed."
        case .noCursor(let choice):
            return "That pane does not show which choice is selected, so the way to “\(MCPControl.field(choice))” is unknown; nothing was typed. press_keys can answer."
        case .wentAway, .changedMeanwhile, .cursorElsewhere:
            return refusal.sentence + " read_tab shows the pane."
        }
    }

    /// How an answer went: the choice's words and its 0-based number; why nothing (more) was typed; or what herdr said.
    enum Answered {
        case answered(label: String, index: Int)
        case refused(HerdrAnswer.Refusal)
        case failed(String)
    }

    /// Answers the question of `pane` in `tab` whose id is `expected`, the one way MCP, Peek, Go to Agent and a notice
    /// do (HerdrAnswer). `typing` runs once, just before the first key goes: the caller says whose act it is (MCP's,
    /// so the agent is driven; the user's otherwise).
    static func answer(_ tab: TerminalTab, pane: String, expected: String, choice: Int?, answer: String?,
                       typing: @escaping () -> Void, done: @escaping (Answered) -> Void) {
        Self.answer(HerdrAgentRef(tab: tab, pane: pane), expected: expected, choice: choice, answer: answer, typing: typing, done: done)
    }

    /// The same for any of herdr's agents, one on a machine included.
    static func answer(_ ref: HerdrAgentRef, expected: String, choice: Int?, answer: String?,
                       typing: @escaping () -> Void, done: @escaping (Answered) -> Void) {
        let pane = ref.pane
        asked(ref) { read in
            let plan: HerdrAnswer.Plan
            switch HerdrAnswer.plan(read, expected: expected, choice: choice, answer: answer) {
            case .failure(let refusal): return done(.refused(refusal))
            case .success(let made): plan = made
            }
            typing()
            let finish = {
                ref.run(.keys(pane: pane, ["enter"])) { result in
                    if let problem = problem(result, pane: pane) { return done(.failed("Return was not pressed: \(problem)")) }
                    done(.answered(label: plan.label, index: plan.index))
                }
            }
            guard !plan.moves.isEmpty else { return finish() }
            // Still the same question, and in a list the cursor on the choice. herdr's send-keys only hands the keys to
            // the pane, so the pane is read a moment after, and a list's cursor up to 10 times more, as answering in a
            // tab waits for its screen. What it shows is not the tracker's: herdr has not counted the change the keys
            // bring yet (HerdrAnswer.next).
            func confirm(_ tries: Int) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    Self.shown(ref) { shown in
                        switch HerdrAnswer.next(plan, shown: shown) {
                        case .pressReturn: finish()
                        case .answered: done(.answered(label: plan.label, index: plan.index))
                        case .refused(.cursorElsewhere) where tries < 10: confirm(tries + 1)
                        case .refused(let refusal): done(.refused(refusal))
                        }
                    }
                }
            }
            ref.run(.keys(pane: pane, plan.moves)) { result in
                if let problem = problem(result, pane: pane) { return done(.failed(problem)) }
                confirm(0)
            }
        }
    }

    /// The question the agent's pane shows now and the choices under it, read again; nil when it shows none, or herdr
    /// no longer says the agent is blocked. The tracker is not told.
    private static func shown(_ ref: HerdrAgentRef, _ body: @escaping ((text: String, menu: AgentMenu?)?) -> Void) {
        ref.run(.read(pane: ref.pane, source: .visible, lines: nil)) { result in
            guard case .text(let text) = result, ref.agent?.status == .blocked else { return body(nil) }
            body(HerdrAgents.question(onScreen: text))
        }
    }

    /// The question the agent's pane shows now, read again, with its id and its menu; the tracker takes what the read
    /// found (a new question gets a new id). nil: none shows.
    private static func asked(_ ref: HerdrAgentRef, _ body: @escaping (HerdrAnswer.Asked?) -> Void) {
        ref.run(.read(pane: ref.pane, source: .visible, lines: nil)) { result in
            guard case .text(let text) = result, let read = HerdrAgents.question(onScreen: text),
                  let agent = ref.agent, agent.status == .blocked else { return body(nil) }
            ref.questionRead(seq: agent.stateSeq, text: read.text, menu: read.menu)
            guard let asked = ref.tracker?.question(ref.pane) else { return body(nil) }
            body(HerdrAnswer.Asked(id: questionID(asked, id: ref.id), text: asked.text, menu: read.menu))
        }
    }

    // MARK: show_tab

    /// Shows the agent's herdr tab as show_tab shows a tab; herdr's own view does not move.
    private static func showTab(_ ref: HerdrAgentRef) -> MCPServer.CallResult {
        let tab = ref.tab
        guard let controller = MCPControl.controller(of: tab) else { return fail("That tab is gone.") }
        let shown = controller.presentForAgent(tab, explicit: true)
        var answer: [String: Any] = ["id": ref.id, "tab_id": tab.id.uuidString.lowercased(),
                                     "shown": shown.selected, "keyboard": false,
                                     "herdr": "herdr's own view did not move; focus_tab moves it to this agent (it asks the user first)."]
        if let note = shown.note { answer["note"] = note }
        return ok(answer)
    }

    // MARK: focus_tab (MCPWriteControl, after the user approved)

    /// Moves herdr's view to the agent and gives its tab the keyboard. What herdr did is said, never more: with an older
    /// herdr, its tab only; without `agent focus` or a tab id, nothing, with the version herdr says it is.
    static func focus(_ ref: HerdrAgentRef, _ agent: HerdrAgent, approved: String, reply: @escaping Reply) {
        let tab = ref.tab, id = ref.id
        // herdr forwards only `agent focus` to a machine; its own screen's machine view stays as the user left it.
        let command = HerdrCommand.focus(pane: agent.paneID, tab: ref.machine == nil ? agent.tabID : nil)
        HerdrRunner.run(command, for: tab, machine: ref.machine, reporting: { result, verb in
            if case .unsupported = result {
                return HerdrRunner.run(.version, for: tab) { said in
                    var version = ""
                    if case .text(let text) = said {
                        version = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first ?? ""
                    }
                    let has = version.isEmpty ? "" : " (\(tab.remote == nil ? "this Mac" : "this host") has \(MCPControl.field(version)))"
                    reply(fail("herdr 0.7.5 or later is needed to move herdr's view to an agent\(has); nothing changed."))
                }
            }
            if let problem = problem(result, pane: agent.paneID, sent: false) { return reply(fail(problem + " The tab has the keyboard.")) }
            var info: [String: Any] = ["id": id, "focused": true, "approved": approved]
            if let label = ref.machineLabel {
                info["herdr"] = "herdr focused \(agent.paneID) on \(MCPControl.field(label)); herdr's own screen shows that machine only once the user picks it in herdr's sidebar."
            } else {
                info["herdr"] = verb == "tab focus"
                    ? "This herdr has no agent focus: it moved to the agent's tab \(agent.tabID ?? ""), not to its pane."
                    : "herdr moved its view to \(agent.paneID); every window attached to that session shows it."
            }
            reply(ok(info))
        })
    }
}
