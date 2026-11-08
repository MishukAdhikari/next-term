import AppKit
import NextTermCore

/// Continue in Chat and Open in Terminal (plan 037 U8, KTD10): it gathers the facts ConversationHandoff plans from, asks
/// the user, ends the source's agent, and only then opens the same conversation in a new tab of the other kind right
/// after the source tab. A terminal source's agent is quit with its own keys and the shell's prompt waited for; a chat
/// source's host ends its own process group. Nothing is ever typed into the source tab beyond the quit keys.
///
/// Each handoff is one runner, kept in `running` until it ends, so a tab hands off once at a time and MCP's typing tools
/// leave it alone meanwhile (an MCPInputLine rule). The user's keys win: if anything but the runner reaches a terminal
/// source's line while its agent quits, nothing opens and a note says so. If the agent hasn't quit after the fallback,
/// the runner gives up with a note. No signal reaches a terminal source's agent, and ⌃D is never sent.
@MainActor
final class HandoffRunner {
    /// Why a handoff didn't run or didn't finish, in words for the tab or for MCP; `refusal` when the plan said no.
    struct Failure: Error {
        let text: String
        var refusal: ConversationHandoff.Refusal?
    }

    /// A handoff that ran: the tab the conversation went on in, and what was planned.
    struct Done {
        let tab: TerminalTab
        let target: ConversationHandoff.Target
    }

    typealias Outcome = Result<Done, Failure>

    /// The program a terminal source's handoff quits: the tab's foreground process group's leader as the handoff began,
    /// by its pid and when it started (a pid the kernel gave another process since is not it).
    private struct Leader: Equatable {
        let pid: pid_t
        let startedAt: Date?
    }

    /// The handoffs running now, by source tab id. Main thread.
    nonisolated(unsafe) private(set) static var running: [UUID: HandoffRunner] = [:]

    /// The terminal evidence a chat tab was continued from in this run of Next Term, by the chat tab's id: the line back
    /// to the terminal puts the user's own launch back (`cw --resume ID`).
    private struct Remembered {
        weak var tab: TerminalTab?
        let evidence: SessionSnapshot.Evidence
    }

    nonisolated(unsafe) private static var remembered: [UUID: Remembered] = [:]

    /// How often the wait looks at the tab.
    private static let poll: TimeInterval = 0.1

    private weak var tab: TerminalTab?
    private let tabID: UUID
    private let target: ConversationHandoff.Target
    private let evidence: SessionSnapshot.Evidence?
    /// The new tab opens in front and takes the keyboard (the user asked); for MCP it waits for the user's click.
    private let byAgent: Bool
    private let done: (Outcome) -> Void
    /// What the source's line had seen when the handoff began, moved on by the runner's own keys: anything else is the
    /// user's.
    private let touchedAtStart: Bool
    private var expectedWrites: Int
    private let suppressedBefore: Bool
    private let leader: Leader?
    private var ended = false

    // MARK: the offer and the facts

    /// The handoff a tab offers now, with `handingOff` set while one runs in it.
    static func offer(for tab: TerminalTab) -> ConversationHandoff.Offer? {
        if let runner = running[tab.id] {
            return ConversationHandoff.Offer(agent: runner.target.agent, from: runner.target.kind.other, handingOff: true)
        }
        let status = tab.status
        return ConversationHandoff.offer(chatAgentID: tab.chatHost?.start.agentID, program: status.program,
                                         expandedCommand: status.expandedCommand, kind: status.kind,
                                         running: status.running && !tab.exited, remote: tab.remote != nil,
                                         herdr: tab.followsHerdr || status.hostsAgents)
    }

    /// What the plan is made from, read now: a terminal source's agent evidence (and Claude Code's transcript), or a chat
    /// source's host and report; and whether the conversation is live in another tab.
    static func facts(of tab: TerminalTab, wanted: ConversationHandoff.Kind? = nil) -> ConversationHandoff.Facts {
        prune()
        let status = tab.status
        let offer = offer(for: tab)
        var facts = ConversationHandoff.Facts(offer: offer, wanted: wanted, state: status.state, question: status.question,
                                              integrated: status.integrated, handingOff: running[tab.id] != nil)
        guard let offer, !offer.handingOff else { return facts }
        var sessionID: String?
        switch offer.from {
        case .terminal:
            facts.sourceFolder = tab.currentDirectory()
            let evidence = ProcessInspector.agentEvidence(ptyFileDescriptor: tab.view.process.childfd, shellPid: tab.view.process.shellPid,
                                                          status: status, home: RestorePlanning.agentHome)
            facts.evidence = evidence
            sessionID = evidence?.sessionID
            if offer.agent == .claude, let evidence, let id = evidence.sessionID, let store = evidence.store,
               let folder = evidence.sessionFolder ?? facts.sourceFolder {
                let path = ConversationHandoff.claudeTranscript(store: store, folder: folder, sessionID: id)
                facts.transcriptExists = FileManager.default.fileExists(atPath: path)
            }
        case .chat:
            guard let host = tab.chatHost else { return facts }
            facts.sourceFolder = host.folder
            let report = AgentSessionSocket.reports[tab.id]
            var resumeFailed = false
            if case .resumeFailed = host.ending { resumeFailed = true }
            sessionID = host.sessionID ?? report?.sessionID
            facts.report = ConversationHandoff.ChatReport(sessionID: sessionID, turns: report?.turns ?? 0, state: chatState(host.state),
                                                          folder: host.folder, resumed: host.start.resumeID != nil,
                                                          resumeFailed: resumeFailed)
            facts.chatEnded = host.state == .ended || host.state == .idle
            if facts.chatEnded {
                // An ended chat's last mark is no reason to refuse: nothing runs to be working or asking.
                facts.state = .idle
                facts.question = nil
            }
            if let kept = remembered[tab.id], kept.tab === tab { facts.remembered = kept.evidence }
        }
        if let id = sessionID, let owner = ConversationOwners.owner(agent: offer.agent.rawValue, sessionID: id, excluding: tab) {
            facts.liveElsewhere = owner.title
        }
        return facts
    }

    /// A chat host's state as a tab's mark, for the plan.
    private static func chatState(_ state: ChatHostState) -> TabState {
        switch state {
        case .working, .starting, .trusting: return .working
        case .asking: return .attention
        default: return .idle
        }
    }

    private static func prune() {
        remembered = remembered.filter { (entry: (key: UUID, value: Remembered)) -> Bool in entry.value.tab != nil }
    }

    // MARK: running

    /// Hands `tab`'s conversation over to a new tab of `wanted` kind (nil: the other one). The user is asked first,
    /// on the source's window, unless `confirm` is false (MCP asked on the Mac already) or they ticked "Don't ask again".
    /// A refusal comes before anything changes, and is shown in the tab unless `showsRefusal` is false (MCP answers with
    /// it instead). `expecting` is the agent and conversation the user approved (continue_in): a fresh plan for another
    /// one is refused. `done` gets the new tab once it is open, or the words that say why not.
    static func start(tab: TerminalTab, wanted: ConversationHandoff.Kind? = nil, confirm: Bool = true, showsRefusal: Bool = true,
                      byAgent: Bool = false, expecting: (agent: ConversationHandoff.Agent, sessionID: String)? = nil,
                      done: @escaping (Outcome) -> Void = { _ in }) {
        func refuse(_ text: String, _ refusal: ConversationHandoff.Refusal? = nil) {
            if showsRefusal { show(text, in: tab) }
            done(.failure(Failure(text: text, refusal: refusal)))
        }
        let facts = self.facts(of: tab, wanted: wanted)
        let target: ConversationHandoff.Target
        switch ConversationHandoff.plan(facts) {
        case .failure(let refusal):
            let text = refusal.text(agent: facts.offer?.agent)
            if refusal.isAnswer { return done(.failure(Failure(text: text, refusal: refusal))) }
            return refuse(text, refusal)
        case .success(let planned):
            target = planned
        }
        if let expecting, expecting.agent != target.agent || expecting.sessionID != target.sessionID {
            return refuse("The tab moved on meanwhile; nothing changed.")
        }
        // Text another feature put on a terminal source's line is not the handoff's to send keys over.
        if target.kind == .chat, let why = MCPInputLine.refusal(tab) { return refuse(why) }
        guard confirm, ConversationHandoff.asksFirst(defaults: .standard), let offer = facts.offer else {
            return begin(tab: tab, target: target, evidence: facts.evidence, byAgent: byAgent, done: done)
        }
        ask(ConversationHandoff.confirmation(for: offer), over: tab) { agreed in
            guard agreed else { return done(.failure(Failure(text: "Cancelled; nothing changed."))) }
            // Planned again from what the tab holds now: the same conversation the user agreed to, or nothing.
            start(tab: tab, wanted: wanted, confirm: false, showsRefusal: showsRefusal, byAgent: byAgent,
                  expecting: (target.agent, target.sessionID), done: done)
        }
    }

    /// The confirmation, as a sheet on the source's window, with its "Don't ask again" box.
    private static func ask(_ words: ConversationHandoff.Confirmation, over tab: TerminalTab, then: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = words.title
        alert.informativeText = words.detail
        alert.addButton(withTitle: words.button)
        alert.addButton(withTitle: words.cancel)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = words.suppression
        let answer: (NSApplication.ModalResponse) -> Void = { response in
            let agreed = response == .alertFirstButtonReturn
            if agreed, alert.suppressionButton?.state == .on { ConversationHandoff.setAsksFirst(false, defaults: .standard) }
            then(agreed)
        }
        if let window = MCPControl.controller(of: tab)?.window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: answer)
        } else {
            answer(alert.runModal())
        }
    }

    /// Words in the tab: a dim note in a terminal, a note row in a chat.
    static func show(_ text: String, in tab: TerminalTab) {
        if let host = tab.chatHost { host.showNote(text) } else if !tab.exited { tab.view.showNote(text) }
    }

    private static func begin(tab: TerminalTab, target: ConversationHandoff.Target, evidence: SessionSnapshot.Evidence?,
                              byAgent: Bool, done: @escaping (Outcome) -> Void) {
        registerInputRule()
        let runner = HandoffRunner(tab: tab, target: target, evidence: evidence, byAgent: byAgent, done: done)
        running[tab.id] = runner
        tab.delegate?.tabDidChange(tab)
        if let host = tab.chatHost {
            host.endForHandoff(note: target.note) { runner.openTarget() }
        } else {
            runner.run(target.quit) { runner.waitForPrompt(since: Self.now, fallbackSent: false) }
        }
    }

    /// MCP's typing tools leave a tab alone while it hands off: its line is the handoff's until it ends.
    private static var ruleRegistered = false
    private static func registerInputRule() {
        guard !ruleRegistered else { return }
        ruleRegistered = true
        MCPInputLine.rules.append { (tab: TerminalTab) -> String? in
            MainActor.assumeIsolated { running[tab.id] != nil } ? ConversationHandoff.Refusal.alreadyHandingOff.text(agent: nil) : nil
        }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private init(tab: TerminalTab, target: ConversationHandoff.Target, evidence: SessionSnapshot.Evidence?, byAgent: Bool,
                 done: @escaping (Outcome) -> Void) {
        self.tab = tab
        tabID = tab.id
        self.target = target
        self.evidence = evidence
        self.byAgent = byAgent
        self.done = done
        touchedAtStart = tab.touchedByUser
        expectedWrites = tab.view.inputWrites
        suppressedBefore = tab.status.suppressesNotices
        leader = target.quit.isEmpty ? nil : Self.frontLeader(of: tab)
        // The agent's quit is the handoff's, not a finish to post.
        tab.status.suppressesNotices = true
    }

    // MARK: a terminal source's quit

    /// The pty's foreground group's leader, when it isn't the tab's shell.
    private static func frontLeader(of tab: TerminalTab) -> Leader? {
        let fd = tab.view.process.childfd
        guard fd >= 0 else { return nil }
        let pgid = tcgetpgrp(fd)
        guard pgid > 0, pgid != tab.view.process.shellPid else { return nil }
        return Leader(pid: pgid, startedAt: ProcessInspector.startTime(of: pgid))
    }

    /// The shell's own group is in front of the tab.
    private static func shellInFront(_ tab: TerminalTab) -> Bool {
        let fd = tab.view.process.childfd
        return fd >= 0 && tcgetpgrp(fd) == tab.view.process.shellPid
    }

    /// The program the handoff quits is still the one in front: keys sent now reach it, and nothing else.
    private func agentInFront(_ tab: TerminalTab) -> Bool {
        guard let leader else { return false }
        return Self.frontLeader(of: tab) == leader
    }

    /// The tab, while the handoff may still act in it: a tab that exited or closed ends the handoff, with no note.
    private var liveTab: TerminalTab? {
        guard let tab, !tab.exited, tab.view.acceptsInput else {
            finish(.failure(Failure(text: "The tab closed.")), note: nil)
            return nil
        }
        return tab
    }

    /// Sends `steps` in order, then runs `then`.
    private func run(_ steps: [ConversationHandoff.Step], then: @escaping () -> Void) {
        guard !ended else { return }
        guard let step = steps.first else { return then() }
        let rest = Array(steps.dropFirst())
        guard let tab = liveTab else { return }
        switch step {
        case .keys(let keys):
            if lineTaken(tab) { return leaveToUser() }
            send(keys, to: tab)
            run(rest, then: then)
        case .keysIfRunning(let keys):
            if lineTaken(tab) { return leaveToUser() }
            // Once the agent has gone they would reach the shell, or whatever runs next.
            if agentInFront(tab) { send(keys, to: tab) }
            run(rest, then: then)
        case .pause(let milliseconds):
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { [self] in
                self.run(rest, then: then)
            }
        }
    }

    /// The runner's own keys, typed as keys (never a paste): what this write adds to the line's count is the handoff's.
    private func send(_ keys: String, to tab: TerminalTab) {
        let before = tab.view.inputWrites
        tab.view.send(txt: keys)
        expectedWrites += tab.view.inputWrites - before
    }

    /// Anything but the handoff reached the tab's line since it began: the user's key, paste or drop, or other text.
    private func lineTaken(_ tab: TerminalTab) -> Bool {
        (tab.touchedByUser && !touchedAtStart) || tab.view.inputWrites != expectedWrites
    }

    /// Waits for the agent to be gone and the shell back in front, its integration reporting no command running. After
    /// `quitWait` with the agent still in front, the fallback's ⌃C; `fallbackWait` after that, the handoff gives up. The
    /// fallback goes only to the program the handoff quits: if another runs in front by then (`claude && npm test`), the
    /// handoff ends with a note and opens nothing.
    private func waitForPrompt(since: TimeInterval, fallbackSent: Bool) {
        guard !ended, let tab = liveTab else { return }
        if lineTaken(tab) { return leaveToUser() }
        let status = tab.status
        if status.integrated, !status.running, !agentInFront(tab), Self.shellInFront(tab) { return openTarget() }
        let waited = Self.now - since
        if !fallbackSent, waited >= ConversationHandoff.quitWait {
            if agentInFront(tab) {
                return run(target.fallback) { [self] in self.waitForPrompt(since: Self.now, fallbackSent: true) }
            }
            if !Self.shellInFront(tab) {
                let text = target.agent.name + " quit, but another program runs in the tab, so nothing was opened."
                return finish(.failure(Failure(text: text)), note: text)
            }
            return waitForPrompt(since: Self.now, fallbackSent: true)
        }
        if fallbackSent, waited >= ConversationHandoff.fallbackWait {
            let text = target.agent.name + " didn\u{2019}t quit, so nothing was opened."
            return finish(.failure(Failure(text: text)), note: text)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.poll) { [self] in
            self.waitForPrompt(since: since, fallbackSent: fallbackSent)
        }
    }

    /// The user typed while the agent quit: the tab is theirs, and nothing opens.
    private func leaveToUser() {
        let text = "You typed in the tab, so Next Term opened nothing: \(target.agent.name)\u{2019}s conversation stays here."
        finish(.failure(Failure(text: text)), note: text)
    }

    // MARK: the new tab

    /// The source's agent has ended: the conversation opens in a new tab of the other kind right after the source.
    private func openTarget() {
        guard !ended else { return }
        guard let tab, let controller = MCPControl.controller(of: tab) else {
            return finish(.failure(Failure(text: "The tab closed.")), note: nil)
        }
        let opened: TerminalTab?
        switch target.kind {
        case .chat:
            guard let start = target.chat else { return finish(.failure(Failure(text: "Nothing to open.")), note: nil) }
            opened = ChatTabs.open(start, in: controller, after: tab, select: !byAgent, byAgent: byAgent)
            if let opened, let evidence { Self.remembered[opened.id] = Remembered(tab: opened, evidence: evidence) }
        case .terminal:
            let folder = target.folder ?? tab.directory
            let line = target.terminalLine(openedIn: folder) ?? target.agent.rawValue
            let new = controller.addTab(directory: folder, select: !byAgent, byAgent: byAgent)
            ChatTabs.place(new, after: tab, in: controller)
            new.runWhenReady(line)
            opened = new
        }
        guard let opened else {
            let text = "Next Term couldn\u{2019}t open the new tab."
            return finish(.failure(Failure(text: text)), note: text)
        }
        if byAgent { _ = controller.presentForAgent(opened) }
        tab.chatHost?.continued(in: opened)
        // A terminal source's dim note; a chat source's ended row is its host's.
        finish(.success(Done(tab: opened, target: target)), note: tab.isChat ? nil : target.note)
    }

    /// The handoff ends, however it ends: notices are back as they were, with the quit's own dropped, the tab strips
    /// redrawn, and `done` told once.
    private func finish(_ result: Outcome, note: String?) {
        guard !ended else { return }
        ended = true
        if Self.running[tabID] === self { Self.running[tabID] = nil }
        if let tab {
            if !suppressedBefore {
                _ = tab.status.takeNotice() // the quit's finish, if one waits
                tab.status.suppressesNotices = false
            }
            if let note { Self.show(note, in: tab) }
            tab.delegate?.tabDidChange(tab)
        }
        done(result)
    }
}
