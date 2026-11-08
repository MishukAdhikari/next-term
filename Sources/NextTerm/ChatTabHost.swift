import AppKit
import NextTermCore

/// One chat tab's agent session, hosted in the app (plan 037 U4, KTD1): it starts the agent's CLI in a process group of
/// its own with the login shell's environment, drives the same session engine `nxtrm agent` runs, asks on the Mac
/// directly (`ChatAppBridge`), keeps the tab's report and status as a session tab's are, and ends the group when the
/// tab closes. The native view (U6) reads it and calls its actions. Main queue only.
final class ChatTabHost: AgentSessionPresenter {
    weak var tab: TerminalTab?
    let tabID: UUID
    /// How the chat starts; a restart keeps it, with the conversation it reported.
    private(set) var start: ChatStart
    private(set) var engine: AgentSessionEngine?
    /// The transcript before the current engine (a restart, or a start that failed): the next engine goes on from it.
    private var carried = ACPSession()
    /// Brought back after a crash, or in safe mode: no agent runs until Resume (`begin`).
    private(set) var isIdle = false
    /// Why the session ended, when it has; a start that never made an engine ends as `.fatal`.
    private(set) var ending: AgentSessionEngine.Ending?
    /// The tab is closing: nothing is reported or shown any more.
    private var closing = false
    /// The conversation went on in another tab (Open in Terminal, plan 037 U8): its note, and the tab it went to.
    private(set) var continuedNote: String?
    private(set) weak var continuedTab: TerminalTab?

    /// The tool and thinking rows the user unfolded, by block id.
    var expanded: Set<String> = []
    /// Each thought's span from its first chunk to its last, by item index ("Thought for 12 s").
    private(set) var thoughtTimes: [Int: TimeInterval] = [:]
    private var thoughtSpans: [Int: (first: Date, last: Date, length: Int)] = [:]
    /// The input box's draft, kept across turns and restarts.
    var draft = ""
    /// The last prompt sent, for ↑ in an empty box.
    private(set) var lastPrompt: String?
    /// The fallback environment's note was told: once a tab.
    private var toldFallback = false
    /// The Mac's questions open for this chat, closed unanswered when it ends.
    private var gates: [AgentApprovals.Gate] = []

    /// The view's hook: called when what it shows changed; `soon` for streamed chunks, which it may coalesce.
    var onChange: ((_ soon: Bool) -> Void)?

    /// What the tab's pane shows (`TerminalTab.contentView`): the native chat view.
    private(set) lazy var view: ChatView = ChatView(source: self)

    init(tab: TerminalTab, start: ChatStart) {
        self.tab = tab
        tabID = tab.id
        self.start = start
        if tab.userTitle?.isEmpty != false { tab.userTitle = automaticTitle }
    }

    /// The tab's name when the user gave none: the start's title, else the agent's name.
    var automaticTitle: String { start.title ?? ACPAgent.named(start.agentID)?.name ?? start.agentID }

    /// The agent runs now, so the conversation it reported is live in this tab (KTD11); an ended or idle chat holds none.
    var holdsConversation: Bool { engine.map { !$0.isEnded } ?? false }

    var agent: ACPAgent? { ACPAgent.named(start.agentID) }

    /// The session as it stands: the engine's, or the carried one while none runs.
    var session: ACPSession { engine?.session ?? carried }

    var state: ChatHostState {
        if isIdle { return .idle }
        guard let engine else { return ending != nil ? .ended : .starting }
        return ChatHostStatus.state(ended: engine.isEnded, waiting: !(engine.waitingLine ?? "").isEmpty,
                                    asking: engine.session.pending != nil, working: engine.session.working, ready: engine.isReady)
    }

    var inputState: ChatInputState {
        ChatInputState.make(session: session, waitingLine: engine?.waitingLine, ended: state == .ended || state == .idle,
                            agentName: agent?.name ?? start.agentID)
    }

    var header: ChatHeader {
        ChatHeader.make(agent: agent?.name ?? start.agentID, model: engine?.model, version: engine?.agentVersion,
                        folder: folder, home: NSHomeDirectory(), usage: session.usage, state: state)
    }

    /// The folder the agent runs in: the start's, else the tab's.
    var folder: String { start.folder ?? tab?.directory ?? NSHomeDirectory() }

    /// The conversation's id as the session reported it (Claude Code's session id, Codex's thread id).
    var sessionID: String? { engine?.sessionID ?? start.resumeID }

    /// The agent's process while it runs: what `nxtrm mcp` started by it walks up to (KTD8).
    var agentPid: pid_t? { engine?.agentPid }

    /// "The chat in “Claude Code”": who asks, as the Mac's question names it.
    var requester: String { "The chat in \u{201C}\(tab?.title ?? agent?.name ?? "Next Term")\u{201D}" }

    // MARK: starting

    /// Shows the tab idle, its agent not started: a crash restore's or safe mode's (R12). Resume calls `begin`.
    func showIdle(note: String? = nil) {
        isIdle = true
        if let note { carried.note(note) }
        notify()
    }

    /// Starts the agent: the environment is read off the main queue (the login shell's probe may still run), then the
    /// engine starts on it.
    func begin() {
        guard !closing, engine.map({ $0.isEnded }) ?? true else { return }
        isIdle = false
        ending = nil
        let starting = start
        notify()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let made = ChatEnvironment.make()
            DispatchQueue.main.async { self?.launch(starting, environment: made.environment, fromLoginShell: made.fromLoginShell) }
        }
    }

    private func launch(_ start: ChatStart, environment: [String: String], fromLoginShell: Bool) {
        guard !closing else { return }
        guard let agent = ACPAgent.named(start.agentID) else {
            return endBeforeStart("\(start.agentID) isn\u{2019}t an agent Next Term runs in a chat.")
        }
        guard let program = ChatEnvironment.locate(agent.program, in: environment) else {
            return endBeforeStart("\(agent.name) (\(agent.program)) isn\u{2019}t on your shell\u{2019}s PATH. Install it, or check your shell\u{2019}s setup, then restart the chat.")
        }
        let engine = AgentSessionEngine(agent: agent, program: program, folder: folder, firstPrompt: start.prompt,
                                        launch: .ownGroup(environment: environment), bridge: ChatAppBridge(host: self))
        if agent.resumesSessions, let id = start.resumeID, AgentSessionVersion.isSessionID(id) {
            engine.resumeID = id
            engine.resumeOnly = start.resumeOnly
        }
        engine.session = carried
        if !fromLoginShell, !toldFallback {
            toldFallback = true
            engine.session.note(ChatAgentEnvironment.fallbackNote)
        }
        engine.presenter = self
        self.engine = engine
        engine.start()
    }

    /// A start that couldn't make a session (no such agent, the CLI not found): the chat ends with `note`.
    private func endBeforeStart(_ note: String) {
        carried.note(note)
        ending = .fatal(note)
        reportEnded()
        notify()
    }

    // MARK: the user's actions (the view, MCP, notifications)

    enum SendOutcome: Equatable {
        case sent
        /// A command only the agent's terminal runs: not sent, a note says where it works.
        case terminalOnly(String)
        /// Not sent, with the input box's words for why.
        case refused(String)
    }

    /// Sends `text` as a prompt, unless a turn runs, a card is open, the session isn't ready or ended, or it is a
    /// terminal-only command.
    @discardableResult
    func send(_ text: String) -> SendOutcome {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return .refused("Nothing to send.") }
        let input = inputState
        guard let engine, !engine.isEnded else { return .refused(input.placeholder) }
        if let word = engine.terminalOnlyCommand(prompt) {
            engine.session.note(ConversationHandoff.terminalOnlyLine(word, shortcut: ChatTabs.handoffShortcut))
            notify()
            return .terminalOnly(word)
        }
        guard input.canSend else { return .refused(input.placeholder) }
        guard engine.isReady else { return .refused((agent?.name ?? "The agent") + " isn\u{2019}t ready yet.") }
        lastPrompt = prompt
        engine.send(prompt)
        return .sent
    }

    /// ⌘., Esc or Stop: the turn stops, an open card answered cancel or deny.
    func stop() {
        engine?.cancelTurn()
        notify()
    }

    /// Picks choice `index` of the open card. Allow always is asked on the Mac first, by the engine, whoever picked it.
    func choose(_ index: Int) {
        engine?.choose(index)
    }

    func moveHighlight(_ step: Int) {
        engine?.moveHighlight(step)
    }

    /// Restart (the end card's) or Resume (an idle tab's): a new engine on the same start, going on with the
    /// conversation the session reported, never a new one in its place.
    func restart() {
        guard !closing, state == .ended || state == .idle else { return }
        continuedNote = nil
        continuedTab = nil
        // One place per conversation (KTD11): one live in another tab stays there, said so here.
        if let id = engine?.sessionID ?? start.resumeID, let tab,
           let owner = MainActor.assumeIsolated({ ConversationOwners.owner(agent: start.agentID, sessionID: id, excluding: tab) }) {
            let words = ConversationHandoff.Refusal.openElsewhere(owner.title).text(agent: nil)
            if let engine { engine.session.note(words) } else { carried.note(words) }
            return notify()
        }
        if let engine {
            guard engine.isEnded else { return }
            carried = engine.session
            if let id = engine.sessionID {
                start.resumeID = id
                start.resumeOnly = true
            }
            self.engine = nil
        }
        start.prompt = nil
        begin()
    }

    // MARK: the handoff (plan 037 U8)

    /// Open in Terminal: the chat ends here, its agent's whole group gone (KTD7) before `then` runs, so only one process
    /// ever writes the conversation; `note` is the ended row the transcript and the end card show. An ended chat has
    /// nothing to end. `then` comes on the main queue, at most 6 seconds on (the group's end takes 5 at most).
    func endForHandoff(note: String, then: @escaping () -> Void) {
        continuedNote = note
        guard let engine, !engine.isEnded else {
            carried.note(note)
            notify()
            return then()
        }
        let group = engine.agentPid
        engine.session.note(note)
        engine.finish(0, why: .closed)
        notify()
        guard let group, group > 0 else { return then() }
        let deadline = Date().addingTimeInterval(6)
        func check() {
            // ESRCH once no process is left in the agent's group (its leader reaped by the group's end).
            if killpg(group, 0) != 0 || Date() >= deadline { return then() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() }
        }
        check()
    }

    /// A note row in the transcript: a handoff's refusal, said where the user asked for it.
    func showNote(_ text: String) {
        if let engine { engine.session.note(text) } else { carried.note(text) }
        notify()
    }

    /// The tab the conversation went on in, once it is open: the end card's Show Tab brings it forward.
    func continued(in tab: TerminalTab) {
        continuedTab = tab
        notify()
    }

    /// The end card's Show Tab: the tab the conversation went on in, in front.
    func showContinuedTab() {
        guard let target = continuedTab, let controller = MCPControl.controller(of: target) else { return NSSound.beep() }
        controller.show(target)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// The tab closes (`ChatTabs.closed`): the agent's group ends (KTD7), the Mac's questions close unanswered.
    func close() {
        guard !closing else { return }
        closing = true
        closeGates()
        engine?.finish(0)
        ChatTabs.setAgentPid(nil, for: tabID)
        onChange = nil
    }

    /// Next Term quits: the group handed back to end with the others, waited for by `ChatTabs.endAll`.
    func closeForQuit() -> pid_t? {
        closing = true
        closeGates()
        return engine?.finishForQuit()
    }

    // MARK: the presenter

    func writeTitle(_ title: String) {}

    func changed() {
        followThoughts()
        notify()
    }

    func changedSoon() {
        followThoughts()
        notify(soon: true)
    }

    func turnFinished() {
        notify()
    }

    /// OSC 7501 is a terminal's: the tab's state comes from the reports (`reported`).
    func stateReported(_ fields: String) {}

    func ended(code: Int32) {
        ChatTabs.setAgentPid(nil, for: tabID)
        guard !closing else { return }
        ending = engine?.ending
        closeGates()
        reportEnded()
        notify()
    }

    func startAfresh() {
        // Claude Code couldn't go on with the session it was given: a new one, said so (the engine's note), as `nxtrm
        // agent` runs again without --resume.
        if let engine { carried = engine.session }
        engine = nil
        start.resumeID = nil
        start.resumeOnly = false
        begin()
    }

    func agentStarted(pid: pid_t) {
        ChatTabs.setAgentPid(pid, for: tabID)
    }

    // MARK: the tab

    /// A report from the engine: kept as a session tab's is (the socket's parser), and the tab's state follows it.
    /// The version this agent ran before, when it differs.
    fileprivate func reported(_ update: [String: Any]) -> String? {
        guard !closing, let tab else { return nil }
        let previous = MainActor.assumeIsolated { AgentSessionReports.record(update, for: tab) }
        follow(state: update["state"] as? String ?? "idle")
        return previous
    }

    /// The tab's status as a session tab's: one running agent whose state is the report's.
    private func follow(state: String) {
        guard let tab else { return }
        let before = (tab.status.state, tab.status.question)
        tab.status.observeChatSession(program: CommandClassifier.agentSessionProgram, at: TerminalTab.now)
        let question = session.pending.map(ACPTranscript.question)
        tab.status.observe(agentScreen: ChatHostStatus.activity(state: state, question: question), at: TerminalTab.now)
        if before != (tab.status.state, tab.status.question) { tab.delegate?.tabDidChange(tab) }
    }

    /// The session ended: the tab reports idle (its conversation's id kept, for a handoff or a restart) and a run's
    /// end is told to the secrets a command in it was granted, as a tab's run ending is.
    private func reportEnded() {
        guard let tab else { return }
        var update: [String: Any] = ["op": "report", "agent": agent?.name ?? start.agentID, "state": "idle",
                                     "turns": engine?.turnsEnded ?? 0, "last_message": session.lastMessage,
                                     "agent_id": start.agentID, "folder": folder]
        if let stop = session.lastStop { update["stop_reason"] = stop.rawValue }
        if let version = engine?.agentVersion { update["agent_version"] = version }
        if let model = engine?.model { update["model"] = model }
        if let id = sessionID { update["session_id"] = id }
        _ = MainActor.assumeIsolated { AgentSessionReports.record(update, for: tab) }
        follow(state: "idle")
        SecretRequests.tabRunChanged(tabID, tab: nil)
    }

    /// Times each thought: only the last item grows, so only it is looked at.
    private func followThoughts() {
        let items = session.items
        guard let last = items.last, case .thought(let text) = last else { return }
        let index = items.count - 1
        let now = Date()
        if var span = thoughtSpans[index] {
            guard span.length != text.count else { return }
            span.last = now
            span.length = text.count
            thoughtSpans[index] = span
        } else {
            thoughtSpans[index] = (now, now, text.count)
        }
        if let span = thoughtSpans[index] { thoughtTimes[index] = span.last.timeIntervalSince(span.first) }
    }

    private func notify(soon: Bool = false) {
        guard !closing else { return }
        onChange?(soon)
    }

    // MARK: the Mac's questions

    fileprivate func opened(_ gate: AgentApprovals.Gate) {
        gates.append(gate)
    }

    fileprivate func answered(_ gate: AgentApprovals.Gate) {
        gates.removeAll { $0 === gate }
    }

    /// The chat ended or closed: its open questions close unanswered, and a later click does nothing.
    private func closeGates() {
        let open = gates
        gates = []
        for gate in open where gate.expire() {
            MainActor.assumeIsolated { gate.closeWindow() }
        }
    }
}

/// A chat tab's way to the app (plan 037 KTD2): reports go straight to the tab's record and status, and an Allow always
/// or a folder trust is asked in the same window `nxtrm agent`'s socket shows, kept open until the user answers or the
/// chat ends. Main queue only.
final class ChatAppBridge: AgentSessionBridge {
    private weak var host: ChatTabHost?

    init(host: ChatTabHost) {
        self.host = host
    }

    var isConnected: Bool { true }

    var offersMCP: Bool { MCPControlServer.shared.isRunning }

    func report(_ update: [String: Any], then: @escaping ([String: Any]?) -> Void) {
        let previous = MainActor.assumeIsolated { host?.reported(update) }
        var answer: [String: Any] = ["ok": true]
        if let previous { answer["previous_version"] = previous }
        // Answered after the call returns, as the socket's answer comes: the engine's code around it runs first.
        DispatchQueue.main.async { then(answer) }
    }

    func confirmAlways(agent: String, action: String, option: String, then: @escaping (Bool) -> Void) {
        guard let host else { return then(false) }
        let gate = AgentApprovals.Gate()
        host.opened(gate)
        MainActor.assumeIsolated {
            AgentApprovals.confirmAlways(agent: agent, action: action, option: option, requester: host.requester, gate: gate) { [weak host] approved in
                host?.answered(gate)
                then(approved)
            }
        }
    }

    func trustFolder(agent: String, folder: String, then: @escaping (Bool?) -> Void) {
        guard let host else { return then(nil) }
        let gate = AgentApprovals.Gate()
        host.opened(gate)
        MainActor.assumeIsolated {
            AgentApprovals.trustFolder(agent: agent, folder: folder, requester: host.requester, gate: gate) { [weak host] trusted in
                host?.answered(gate)
                then(trusted)
            }
        }
    }
}
