import Foundation

/// The switch between a Claude Code or Codex tab's two views (plan 036): the agent's own terminal interface (the terminal
/// view) and Next Term's agent session, `nxtrm agent claude|codex` (the chat view), with the same conversation, in the
/// same tab. These are the rules alone: which tabs offer the switch and the icon each shows, which reasons refuse it, and
/// the keys and the line a switch sends. ViewSwitchRunner, in the app, gathers the facts and acts.
///
/// Two tiers keep the tab bar cheap (KTD2): `offer` reads only what a tab's status holds already, several times a second;
/// `plan` runs once a switch is asked for, on the evidence read then. So a tab may show the icon and still refuse.
public enum ViewSwitch {
    /// What a Claude Code or Codex tab shows.
    public enum View: String, CaseIterable, Sendable {
        case terminal, chat

        public var other: View { self == .terminal ? .chat : .terminal }

        /// "Chat", "Terminal": as a menu item and a separator line name it.
        public var title: String { self == .terminal ? "Terminal" : "Chat" }
    }

    /// The agents whose tabs switch: the only two with a session that resumes the agent's own conversation.
    public enum Agent: String, CaseIterable, Sendable {
        case claude, codex

        /// The agent a tab's program is, by its name (`claude`, `codex`).
        public init?(program: String) {
            self.init(rawValue: program)
        }

        /// The agent a session reported, by its catalog id.
        public init?(sessionAgentID: String?) {
            guard let id = sessionAgentID else { return nil }
            self.init(rawValue: id)
        }

        /// The session list's agent, when it is one of the two.
        public init?(kind: AgentKind) {
            switch kind {
            case .claude: self = .claude
            case .codex: self = .codex
            default: return nil
            }
        }

        /// The restore's agent: its resume form, its id pattern and its put-back line.
        public var restoreAgent: RestoreAgent { self == .claude ? .claude : .codex }

        /// The session catalog's agent: its session and resume lines.
        public var sessionAgent: ACPAgent {
            ACPAgent.named(rawValue) ?? ACPAgent(id: rawValue, name: name, program: rawValue, arguments: [])
        }

        /// What product text calls it.
        public var name: String { self == .claude ? "Claude Code" : "Codex" }

        /// The slash command that quits its terminal interface.
        public var quitWord: String { self == .claude ? "/exit" : "/quit" }
    }

    /// A tab that offers the switch: its agent, the view it shows, and whether a switch runs in it now.
    public struct Offer: Equatable, Sendable {
        public var agent: Agent
        public var view: View
        public var switching: Bool

        public init(agent: Agent, view: View, switching: Bool = false) {
            self.agent = agent
            self.view = view
            self.switching = switching
        }
    }

    /// The cheap tier (KTD2): the switch a tab offers from what its status holds, or nil. A local tab running `claude` or
    /// `codex` as an agent shows the terminal view; `nxtrm agent` whose session reported Claude Code or Codex shows the
    /// chat view. A remote tab, a tab that shows herdr, a stopped program and anything else offer none (R1).
    ///
    /// A launcher alias (`cw` for `claude --model opus`, as a switch back puts it back) names itself as the program, so
    /// `expandedCommand`, the line with aliases expanded (TabStatus.expandedCommand), names the agent then.
    public static func offer(program: String, expandedCommand: String = "", kind: CommandKind, running: Bool,
                             sessionAgentID: String?, remote: Bool, herdr: Bool) -> Offer? {
        guard running, !remote, !herdr else { return nil }
        if program == CommandClassifier.agentSessionProgram {
            return Agent(sessionAgentID: sessionAgentID).map { Offer(agent: $0, view: .chat) }
        }
        guard kind == .agent else { return nil }
        let expanded = expandedCommand.isEmpty ? "" : CommandClassifier.programName(expandedCommand)
        guard let agent = Agent(program: program) ?? Agent(program: expanded) else { return nil }
        return Offer(agent: agent, view: .terminal)
    }

    // MARK: the icon

    /// The icon's two glyphs.
    public enum Glyph: String, Sendable {
        case chat, terminal

        /// The SF Symbol it draws.
        public var symbolName: String { self == .chat ? "bubble.left" : "terminal" }
    }

    /// What the icon beside a tab's × shows (R8, R9). The app adds the shortcut to the tooltip, from the user's keys.
    public struct Mark: Equatable, Sendable {
        public var glyph: Glyph
        /// Drawn at half strength: a chat view at rest, or a switch running.
        public var dimmed: Bool
        /// A click switches. Off while a switch runs.
        public var enabled: Bool
        public var tooltip: String
        /// What VoiceOver says.
        public var spoken: String

        public init(glyph: Glyph, dimmed: Bool, enabled: Bool, tooltip: String, spoken: String) {
            self.glyph = glyph
            self.dimmed = dimmed
            self.enabled = enabled
            self.tooltip = tooltip
            self.spoken = spoken
        }
    }

    /// The icon a tab shows (R8), as Chrome's mute icon does: a terminal view shows the chat bubble only under the pointer
    /// or selected; a chat view always shows a dim bubble, which turns into the terminal glyph under the pointer or
    /// selected. While a switch runs, its destination shows dimmed and off. Nil: no icon.
    public static func mark(offer: Offer?, hovering: Bool, selected: Bool) -> Mark? {
        guard let offer else { return nil }
        let destination = offer.view.other
        let words = "Switch to " + destination.title
        let glyph: Glyph = destination == .chat ? .chat : .terminal
        if offer.switching {
            let switching = "Switching to " + destination.title
            return Mark(glyph: glyph, dimmed: true, enabled: false, tooltip: switching, spoken: switching)
        }
        let shown = hovering || selected
        switch offer.view {
        case .terminal:
            guard shown else { return nil }
            return Mark(glyph: .chat, dimmed: false, enabled: true, tooltip: words, spoken: words)
        case .chat:
            if shown { return Mark(glyph: .terminal, dimmed: false, enabled: true, tooltip: words, spoken: words) }
            return Mark(glyph: .chat, dimmed: true, enabled: true, tooltip: words, spoken: "Chat view, " + words)
        }
    }

    /// Where the icon sits in a tab of the top bar and a row of the tab list (KTD9): the ×'s size, 2 points before it (the
    /// × is at `width − 24`). While it shows, the title ends 4 points before it and the "⌘N" hint gives way, in both.
    public enum Slot {
        public static let size: CGFloat = 18
        public static func x(width: CGFloat) -> CGFloat { width - 44 }
        public static func titleEnd(width: CGFloat) -> CGFloat { width - 48 }
    }

    // MARK: the plan

    /// What a chat-view tab's session last reported (AgentSessionSocket's report).
    public struct ChatReport: Equatable, Sendable {
        /// Claude Code's session id or Codex's thread id.
        public var sessionID: String?
        /// Turns ended in this session.
        public var turns: Int
        /// working, attention, or anything else as idle.
        public var state: TabState
        /// The folder the session runs in.
        public var folder: String?
        /// The session went on with a conversation it was given (`--resume`): it holds turns before its first.
        public var resumed: Bool

        public init(sessionID: String?, turns: Int, state: TabState, folder: String?, resumed: Bool = false) {
            self.sessionID = sessionID
            self.turns = turns
            self.state = state
            self.folder = folder
            self.resumed = resumed
        }
    }

    /// What a switch is planned from, read as it is asked for.
    public struct Facts: Equatable, Sendable {
        /// The tab's offer; nil when it offers none.
        public var offer: Offer?
        /// How the tab's shell starts `nxtrm` (ACPSessionTabs.launcher).
        public var launcher: String
        /// The view asked for (MCP's `view`); nil: the other one.
        public var wanted: View?
        /// The tab's mark and the question its agent waits on, from its status.
        public var state: TabState
        public var question: String?
        /// The shell integration reports in this tab: the only sign the shell's prompt is back.
        public var integrated: Bool
        /// A switch runs in this tab already.
        public var switching: Bool
        /// The terminal view's agent evidence (ProcessInspector.agentEvidence), read now.
        public var evidence: SessionSnapshot.Evidence?
        /// Claude Code's transcript of the evidence's session exists (`claudeTranscript`): it has had a turn.
        public var transcriptExists: Bool
        /// The chat view's last report.
        public var report: ChatReport?
        /// The terminal evidence this tab had when it last went to chat in this run of Next Term (R7).
        public var remembered: SessionSnapshot.Evidence?
        /// The shell's folder now.
        public var shellFolder: String?
        /// What the chat view's session offered the terminal view for (R13), while its bar is open: the switch then goes
        /// by `offerPlan`.
        public var terminalOffer: TerminalOffer?
        /// The chat view's session still runs. One that offered the terminal view as it ended has nothing to quit.
        public var sessionRunning: Bool

        public init(offer: Offer?, launcher: String, wanted: View? = nil, state: TabState = .idle, question: String? = nil,
                    integrated: Bool = true, switching: Bool = false, evidence: SessionSnapshot.Evidence? = nil,
                    transcriptExists: Bool = false, report: ChatReport? = nil, remembered: SessionSnapshot.Evidence? = nil,
                    shellFolder: String? = nil, terminalOffer: TerminalOffer? = nil, sessionRunning: Bool = true) {
            self.offer = offer
            self.launcher = launcher
            self.wanted = wanted
            self.state = state
            self.question = question
            self.integrated = integrated
            self.switching = switching
            self.evidence = evidence
            self.transcriptExists = transcriptExists
            self.report = report
            self.remembered = remembered
            self.shellFolder = shellFolder
            self.terminalOffer = terminalOffer
            self.sessionRunning = sessionRunning
        }
    }

    /// Why a switch doesn't run (the plan's refusal table). Each is said before any key reaches the tab.
    public enum Refusal: Error, Equatable, Sendable {
        /// The tab runs neither agent here (MCP's words; the icon and the menu are off there).
        case notOffered
        /// It shows the view asked for: MCP answers ok, with the words as its note.
        case showsAlready(View)
        case alreadySwitching
        case working
        case asking
        case noExactID
        case noTurnYet
        case noIntegration

        /// Not a failure: the answer is that nothing needed doing.
        public var isAnswer: Bool {
            if case .showsAlready = self { return true }
            return false
        }

        /// The words shown in the tab, or MCP's error text. `agent` names the tab's agent.
        public func text(agent: Agent?) -> String {
            let name = agent?.name ?? "The agent"
            switch self {
            case .notOffered: return "That tab doesn\u{2019}t run Claude Code or Codex on this Mac."
            case .showsAlready(let view): return "It shows " + view.rawValue + " already."
            case .alreadySwitching: return "This tab is switching views already."
            case .working: return name + " is working. Switch when its turn ends."
            case .asking: return name + " is asking you something. Answer it first."
            case .noExactID: return "Next Term can\u{2019}t tell which " + name + " conversation this is."
            case .noTurnYet: return "No conversation to carry over yet: send a prompt first."
            case .noIntegration: return "Switching needs Next Term\u{2019}s shell integration in this tab."
            }
        }
    }

    /// One thing a switch sends, in order.
    public enum Step: Equatable, Sendable {
        /// Keys sent as typed, never as a paste (a paste may not open a slash menu).
        case keys(String)
        /// A wait, in milliseconds.
        case pause(Int)
        /// Keys sent only while the agent still runs: once it has gone they would reach the shell.
        case keysIfRunning(String)
    }

    /// A switch that may run.
    public struct Plan: Equatable, Sendable {
        public var from: View
        public var to: View
        public var agent: Agent
        /// The conversation carried over; empty when an offer's terminal view starts the agent plain.
        public var sessionID: String
        /// The agent's own quit (KTD4).
        public var quit: [Step]
        /// Sent when the agent still runs after `quitWait`.
        public var fallback: [Step]
        /// Typed at the shell's prompt once the agent has gone, kept out of its history.
        public var line: String
        /// The dim line fed into the tab to mark the switch.
        public var separator: String
    }

    /// How long the agent has to quit before the fallback, and then before the switch gives up (KTD5).
    public static let quitWait: TimeInterval = 5
    public static let fallbackWait: TimeInterval = 3

    /// ⌃C: it clears a draft, stops a turn, or arms the quit. ⌃D is never sent: at the shell's prompt it would end the
    /// shell.
    static let interrupt = "\u{3}"

    /// The switch `facts` allow, or the first reason in the table's order that refuses it. A switch already running is
    /// said first, as what the agent it quits shows meanwhile is no reason. Only an exact id moves a conversation
    /// (KTD3): a guess would resume another one in the user's tab.
    public static func plan(_ facts: Facts) -> Result<Plan, Refusal> {
        if let terminalOffer = facts.terminalOffer { return offerPlan(facts, terminalOffer) }
        guard let offer = facts.offer else { return .failure(.notOffered) }
        let agent = offer.agent
        let to = offer.view.other
        if let wanted = facts.wanted, wanted == offer.view { return .failure(.showsAlready(wanted)) }
        if facts.switching || offer.switching { return .failure(.alreadySwitching) }
        let reported = offer.view == .chat ? facts.report?.state : nil
        if facts.state == .working || reported == .working { return .failure(.working) }
        if facts.question != nil || reported == .attention { return .failure(.asking) }
        switch offer.view {
        case .terminal:
            guard let evidence = facts.evidence, evidence.agent == agent.restoreAgent, evidence.isExact,
                  let id = evidence.sessionID, agent.restoreAgent.isSessionID(id) else { return .failure(.noExactID) }
            // Codex's open rollout is its conversation, with or without a turn: an empty thread resumes as one.
            if agent == .claude, !facts.transcriptExists { return .failure(.noTurnYet) }
            guard facts.integrated else { return .failure(.noIntegration) }
            let resume = agent.sessionAgent.resumeLine(launcher: facts.launcher, sessionID: id) + " --resume-only"
            let line = inFolder(evidence.sessionFolder, shell: facts.shellFolder, resume)
            return .success(Plan(from: .terminal, to: to, agent: agent, sessionID: id, quit: terminalQuit(agent),
                                 fallback: fallback, line: line,
                                 separator: separator(to: to, agent: agent, id: id, dropped: optionNames(evidence))))
        case .chat:
            guard let report = facts.report, let id = report.sessionID, agent.restoreAgent.isSessionID(id) else {
                return .failure(.noExactID)
            }
            if report.turns == 0, !report.resumed { return .failure(.noTurnYet) }
            guard facts.integrated else { return .failure(.noIntegration) }
            let line = inFolder(report.folder, shell: facts.shellFolder,
                                terminalLine(agent: agent, id: id, folder: report.folder, remembered: facts.remembered))
            return .success(Plan(from: .chat, to: to, agent: agent, sessionID: id, quit: fallback, fallback: fallback, line: line,
                                 separator: separator(to: to, agent: agent, id: id, dropped: [])))
        }
    }

    /// The switch a chat view's offer runs (R13): to the terminal view, with the conversation when the session has one,
    /// else the agent started plain, as the offer's reason (signing in, a command, the trust question) needs the
    /// terminal view whether or not there is a conversation yet. A resume that couldn't go on names its id, which is the
    /// conversation to try there. A session that has ended has nothing to quit; one that runs is refused while it works or
    /// asks, as any switch is.
    static func offerPlan(_ facts: Facts, _ terminalOffer: TerminalOffer) -> Result<Plan, Refusal> {
        guard let offer = facts.offer, offer.view == .chat else { return .failure(.notOffered) }
        let agent = offer.agent
        if let wanted = facts.wanted, wanted == offer.view { return .failure(.showsAlready(wanted)) }
        if facts.switching || offer.switching { return .failure(.alreadySwitching) }
        if facts.sessionRunning {
            if facts.state == .working || facts.report?.state == .working { return .failure(.working) }
            if facts.question != nil || facts.report?.state == .attention { return .failure(.asking) }
        }
        guard facts.integrated else { return .failure(.noIntegration) }
        let report = facts.report
        var id = ""
        if let reported = report?.sessionID, agent.restoreAgent.isSessionID(reported),
           terminalOffer == .resumeFailed || report?.resumed == true || (report?.turns ?? 0) > 0 {
            id = reported
        }
        let start = id.isEmpty ? agent.rawValue
            : terminalLine(agent: agent, id: id, folder: report?.folder, remembered: facts.remembered)
        let line = inFolder(report?.folder, shell: facts.shellFolder, start)
        let quit = facts.sessionRunning ? fallback : []
        let separator = id.isEmpty ? "Switched to Terminal: " + agent.name
            : self.separator(to: .terminal, agent: agent, id: id, dropped: [])
        return .success(Plan(from: .chat, to: .terminal, agent: agent, sessionID: id, quit: quit, fallback: quit, line: line,
                             separator: separator))
    }

    /// The terminal view's quit: ⌃C, then the agent's quit word as keys, then Return, a moment apart.
    static func terminalQuit(_ agent: Agent) -> [Step] {
        [.keys(interrupt), .pause(150), .keys(agent.quitWord), .pause(150), .keys("\r")]
    }

    /// ⌃C, and a second only while the agent still runs: a session's quit, and both agents' double ⌃C.
    static let fallback: [Step] = [.keys(interrupt), .pause(300), .keysIfRunning(interrupt)]

    /// The terminal view's line (KTD6): the user's own launch with the resume form, when this tab went to chat from
    /// it with this conversation; otherwise the agent's plain resume line.
    static func terminalLine(agent: Agent, id: String, folder: String?, remembered: SessionSnapshot.Evidence?) -> String {
        if let remembered, remembered.agent == agent.restoreAgent, remembered.sessionID == id,
           let back = remembered.putBack(id: id, folder: folder), back.namesSession {
            return back.line
        }
        return agent.restoreAgent.putBackLine(id: id, folder: folder) ?? agent.rawValue
    }

    /// `line`, run in the session's folder when the shell is elsewhere: both agents find a conversation by its folder.
    static func inFolder(_ folder: String?, shell: String?, _ line: String) -> String {
        guard let folder, folder.hasPrefix("/") else { return line }
        if let shell, ProtectedPlaces.trimmed(shell) == ProtectedPlaces.trimmed(folder) { return line }
        return "cd -- " + ShellQuote.quote(folder) + " && " + line
    }

    /// The names of the options the terminal view ran with, which the chat line doesn't carry: names only, never a
    /// value, and only those a note may show.
    static func optionNames(_ evidence: SessionSnapshot.Evidence) -> [String] {
        var names: [String] = []
        for option in evidence.options ?? [] {
            let name = option.name
            guard RestoreAgent.isOptionName(name), !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    /// "Switched to Chat: Claude Code conversation 8f3a1c2e", and what the chat line drops, by name.
    static func separator(to view: View, agent: Agent, id: String, dropped: [String]) -> String {
        let text = "Switched to " + view.title + ": " + agent.name + " conversation " + String(id.prefix(8))
        return dropped.isEmpty ? text : text + ". Not carried: " + dropped.joined(separator: ", ")
    }

    // MARK: the chat view's offers

    /// What a chat view's session offers the terminal view for (R13, KTD13), as its report's `terminal_offer` says it:
    /// `sign_in`, `command:/login`, `trust_declined` or `resume_failed`. Nothing else is read.
    public enum TerminalOffer: Equatable, Sendable {
        /// The agent isn't signed in: only its terminal interface signs in.
        case signIn
        /// A terminal-only command the session didn't send (`/login`).
        case command(String)
        /// Claude Code's folder trust was declined on the Mac.
        case trustDeclined
        /// A switch's resume couldn't go on (`--resume-only`).
        case resumeFailed

        /// The offer a report's field names, or nil. A command must be one some agent's terminal view runs.
        public init?(raw: String) {
            switch raw {
            case "sign_in": self = .signIn
            case "trust_declined": self = .trustDeclined
            case "resume_failed": self = .resumeFailed
            default:
                guard raw.hasPrefix("command:") else { return nil }
                let word = String(raw.dropFirst("command:".count))
                guard ACPAgent.known.contains(where: { $0.terminalOnlyCommands.contains(word) }) else { return nil }
                self = .command(word)
            }
        }

        /// The field's value, as `init(raw:)` reads it.
        public var raw: String {
            switch self {
            case .signIn: return "sign_in"
            case .command(let word): return "command:" + word
            case .trustDeclined: return "trust_declined"
            case .resumeFailed: return "resume_failed"
            }
        }

        /// The words on the bar over the tab, beside its Open in Terminal button.
        public func text(agent: Agent) -> String {
            switch self {
            case .signIn: return agent.name + " needs you to sign in, in the terminal view."
            case .command(let word): return word + " works in the terminal view."
            case .trustDeclined: return agent.name + "\u{2019}s own trust question is in the terminal view."
            case .resumeFailed: return "This conversation couldn\u{2019}t go on in Chat. Open it in Terminal."
            }
        }
    }

    /// The session's own line when it drops a terminal-only command (R13): where the command works, and what the bar's
    /// button carries there.
    public static func terminalOnlyLine(_ word: String, agent: Agent, hasConversation: Bool) -> String {
        let carries = hasConversation ? "carries this conversation there" : "starts " + agent.name + " there"
        return word + " works in the terminal view: Open in Terminal (\u{21E7}\u{2318}J) " + carries + "."
    }

    /// Where Claude Code keeps session `sessionID`'s transcript in `folder`, under its store: it exists once the session
    /// has had a turn.
    public static func claudeTranscript(store: String, folder: String, sessionID: String) -> String {
        (store as NSString).appendingPathComponent("projects/" + AgentSessions.claudeFolderName(folder) + "/" + sessionID + ".jsonl")
    }
}
