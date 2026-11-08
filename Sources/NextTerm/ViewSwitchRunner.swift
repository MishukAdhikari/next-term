import AppKit
import NextTermCore

/// The terminal and chat switch in a tab (plan 036 U2): it gathers the facts ViewSwitch plans from, quits the agent in
/// the view the tab shows with the agent's own keys, waits for the shell's prompt, and types the other view's resume line
/// into the same tab. Each switch is one runner, kept in `running` until it ends, so a tab runs one switch at a time and
/// MCP's typing tools leave it alone meanwhile (MCPInputLine). Nothing is stored on the tab itself (KTD7).
///
/// The user's keys are never blocked: if anything but the switch reaches the tab's line before the resume line goes in,
/// the runner types nothing and says which line it left to them. If the agent hasn't quit after the fallback, it gives up
/// with a note and types nothing more (R4). No signal reaches the agent, and ⌃D is never sent.
@MainActor
final class ViewSwitchRunner {
    /// Why a switch didn't run or didn't finish, in words for the tab or for MCP.
    struct Failure: Error, Equatable {
        let text: String
    }

    /// The view a tab shows once its switch ends, or why it doesn't.
    typealias Outcome = Result<ViewSwitch.View, Failure>

    /// The switches running now, by tab id. Main thread; MCPInputLine reads it.
    nonisolated(unsafe) private(set) static var running: [UUID: ViewSwitchRunner] = [:]

    /// The terminal evidence a tab had when it last went to chat in this run of Next Term (R7), with how many commands had
    /// started in it once the chat line ran: a later command means the tab moved on, and the evidence no longer applies.
    private struct Remembered {
        weak var tab: TerminalTab?
        let evidence: SessionSnapshot.Evidence
        let commandsStarted: Int
    }

    nonisolated(unsafe) private static var remembered: [UUID: Remembered] = [:]

    /// How often the wait looks at the tab.
    private static let poll: TimeInterval = 0.1

    private weak var tab: TerminalTab?
    private let tabID: UUID
    private let plan: ViewSwitch.Plan
    private let done: (Outcome) -> Void
    /// The terminal evidence to remember once the chat line runs.
    private let evidence: SessionSnapshot.Evidence?
    /// What the tab's line had seen when the switch began, moved on by the runner's own keys: anything else is the user's.
    private let touchedAtStart: Bool
    private var expectedWrites: Int
    private let suppressedBefore: Bool
    private var ended = false

    /// The switch a tab offers now, with `switching` set while one runs in it. A running switch keeps its offer, as the
    /// agent it quits is gone from the tab's status part-way.
    static func offer(for tab: TerminalTab) -> ViewSwitch.Offer? {
        if let runner = running[tab.id] {
            return ViewSwitch.Offer(agent: runner.plan.agent, view: runner.plan.from, switching: true)
        }
        let status = tab.status
        let report = AgentSessionSocket.reports[tab.id]
        return ViewSwitch.offer(program: status.program, expandedCommand: status.expandedCommand, kind: status.kind,
                                running: status.running, sessionAgentID: report?.agentID, remote: tab.remote != nil,
                                herdr: tab.followsHerdr || status.hostsAgents)
    }

    /// Switches `tab` to `wanted` (nil: the other view). `done` gets the view the tab then shows, once the resume line is
    /// typed, or the words that say why not; a refusal comes before any key reaches the tab, and is shown in the tab
    /// unless `showsRefusal` is false (MCP answers with it instead). `showsAlready` answers with the view as it is.
    static func start(tab: TerminalTab, wanted: ViewSwitch.View? = nil, showsRefusal: Bool = true,
                      done: @escaping (Outcome) -> Void = { _ in }) {
        prune()
        let facts = self.facts(of: tab, wanted: wanted)
        let plan: ViewSwitch.Plan
        switch ViewSwitch.plan(facts) {
        case .failure(let refusal):
            if case .showsAlready(let view) = refusal { return done(.success(view)) }
            let text = refusal.text(agent: facts.offer?.agent)
            if showsRefusal { tab.view.showNote(text) }
            return done(.failure(Failure(text: text)))
        case .success(let planned):
            plan = planned
        }
        let runner = ViewSwitchRunner(tab: tab, plan: plan, evidence: facts.evidence, done: done)
        running[tab.id] = runner
        tab.delegate?.tabDidChange(tab)
        runner.run(plan.quit) { runner.waitForPrompt(since: Self.now, fallbackSent: false) }
    }

    /// What the plan is made from, read now: the terminal view's agent evidence (and Claude Code's transcript), or the
    /// chat view's last report.
    private static func facts(of tab: TerminalTab, wanted: ViewSwitch.View?) -> ViewSwitch.Facts {
        let status = tab.status
        let offer = self.offer(for: tab)
        var facts = ViewSwitch.Facts(offer: offer, launcher: ACPSessionTabs.launcher, wanted: wanted, state: status.state,
                                     question: status.question, integrated: status.integrated, switching: running[tab.id] != nil,
                                     shellFolder: tab.currentDirectory())
        guard let offer, !offer.switching else { return facts }
        switch offer.view {
        case .terminal:
            let evidence = ProcessInspector.agentEvidence(ptyFileDescriptor: tab.view.process.childfd,
                                                          shellPid: tab.view.process.shellPid, status: status)
            facts.evidence = evidence
            if offer.agent == .claude, let evidence, let id = evidence.sessionID, let store = evidence.store,
               let folder = evidence.sessionFolder ?? facts.shellFolder {
                let path = ViewSwitch.claudeTranscript(store: store, folder: folder, sessionID: id)
                facts.transcriptExists = FileManager.default.fileExists(atPath: path)
            }
        case .chat:
            if let report = AgentSessionSocket.reports[tab.id], AgentSessionSocket.record(of: tab) != nil {
                facts.report = ViewSwitch.ChatReport(sessionID: report.sessionID, turns: report.turns, state: chatState(report.state),
                                                     folder: report.folder, resumed: report.resumed)
            }
            if let kept = remembered[tab.id], kept.tab === tab, kept.commandsStarted == status.commandsStarted {
                facts.remembered = kept.evidence
            }
        }
        return facts
    }

    /// A session report's state as a tab's mark.
    private static func chatState(_ state: String) -> TabState {
        switch state {
        case "working": return .working
        case "attention": return .attention
        default: return .idle
        }
    }

    /// Drops what is remembered for tabs that have gone.
    private static func prune() {
        remembered = remembered.filter { (entry: (key: UUID, value: Remembered)) -> Bool in
            guard let tab = entry.value.tab else { return false }
            return !tab.exited
        }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private init(tab: TerminalTab, plan: ViewSwitch.Plan, evidence: SessionSnapshot.Evidence?,
                 done: @escaping (Outcome) -> Void) {
        self.tab = tab
        tabID = tab.id
        self.plan = plan
        self.evidence = evidence
        self.done = done
        touchedAtStart = tab.touchedByUser
        expectedWrites = tab.view.inputWrites
        suppressedBefore = tab.status.suppressesNotices
        // The agent's quit is the switch's, not a finish to post (R6).
        tab.status.suppressesNotices = true
    }

    /// The tab, while the switch may still act in it: a tab that exited or closed ends the switch, with no note.
    private var liveTab: TerminalTab? {
        guard let tab, !tab.exited, tab.view.acceptsInput else {
            finish(.failure(Failure(text: "The tab closed.")), note: nil)
            return nil
        }
        return tab
    }

    /// Sends `steps` in order, then runs `then`.
    private func run(_ steps: [ViewSwitch.Step], then: @escaping () -> Void) {
        guard !ended else { return }
        guard let step = steps.first else { return then() }
        let rest = Array(steps.dropFirst())
        guard let tab = liveTab else { return }
        switch step {
        case .keys(let keys):
            send(keys, to: tab)
            run(rest, then: then)
        case .keysIfRunning(let keys):
            if tab.status.running { send(keys, to: tab) }
            run(rest, then: then)
        case .pause(let milliseconds):
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { [self] in
                self.run(rest, then: then)
            }
        }
    }

    /// The runner's own keys, typed as keys (never a paste): what they add to the line's count is the switch's.
    private func send(_ keys: String, to tab: TerminalTab) {
        tab.view.send(txt: keys)
        expectedWrites = tab.view.inputWrites
    }

    /// Anything but the switch reached the tab's line since it began: the user's key, paste or drop, or other text.
    private func lineTaken(_ tab: TerminalTab) -> Bool {
        (tab.touchedByUser && !touchedAtStart) || tab.view.inputWrites != expectedWrites
    }

    /// Waits for the shell's prompt (KTD5): the integration reports the agent ended and the shell alone is in front. After
    /// `quitWait` with the agent still running, the fallback's ⌃C; `fallbackWait` after that, the switch gives up.
    private func waitForPrompt(since: TimeInterval, fallbackSent: Bool) {
        guard !ended, let tab = liveTab else { return }
        let status = tab.status
        if status.integrated, !status.running, CommandSuggestionController.atPrompt(tab) { return typeLine(in: tab) }
        if lineTaken(tab) { return leaveToUser() }
        let waited = Self.now - since
        if !fallbackSent, waited >= ViewSwitch.quitWait {
            return run(plan.fallback) { [self] in self.waitForPrompt(since: Self.now, fallbackSent: true) }
        }
        if fallbackSent, waited >= ViewSwitch.fallbackWait {
            return finish(.failure(Failure(text: gaveUpText)), note: gaveUpText)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.poll) { [self] in
            self.waitForPrompt(since: since, fallbackSent: fallbackSent)
        }
    }

    private var gaveUpText: String {
        let quitting = plan.from == .terminal ? plan.agent.name : plan.agent.name + "\u{2019}s session"
        return quitting + " didn\u{2019}t quit, so nothing more was typed."
    }

    /// The user typed while the agent quit: the line is theirs to run.
    private func leaveToUser() {
        let text = "You typed in the tab, so Next Term left the line to you: " + plan.line
        finish(.failure(Failure(text: text)), note: text)
    }

    /// At the prompt: the separator, then the line, typed and submitted as Next Term's own, kept out of the shell's history.
    private func typeLine(in tab: TerminalTab) {
        if lineTaken(tab) { return leaveToUser() }
        // On a line of its own, once what the shell printed is between sequences, as a restore's notes are.
        tab.view.feedBetweenSequences("\r\n" + RestoreLayout.noteLine(plan.separator))
        let typed = tab.view.typeText(plan.line)
        if plan.to == .chat, let evidence {
            // Counted once the chat line has started: the one command expected after this.
            let started = tab.status.commandsStarted + 1
            Self.remembered[tabID] = Remembered(tab: tab, evidence: evidence, commandsStarted: started)
        }
        tab.submitOwnLine(typed) { [self] in
            self.finish(.success(self.plan.to), note: nil)
        }
    }

    /// The switch ends, however it ends: notices are back as they were, with the quit's own dropped, the tab's icon is
    /// redrawn, and `done` is told once.
    private func finish(_ result: Outcome, note: String?) {
        guard !ended else { return }
        ended = true
        if Self.running[tabID] === self { Self.running[tabID] = nil }
        if let tab {
            if !suppressedBefore {
                _ = tab.status.takeNotice() // the quit's finish, if one waits
                tab.status.suppressesNotices = false
            }
            if let note, !tab.exited { tab.view.showNote(note) }
            tab.delegate?.tabDidChange(tab)
        }
        done(result)
    }
}
