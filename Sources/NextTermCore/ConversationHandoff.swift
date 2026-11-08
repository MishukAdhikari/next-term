import Foundation

/// Continue in Chat and Open in Terminal (plan 037 KTD10): one Claude Code or Codex conversation carried, by its exact
/// id, from a tab of one kind into a new tab of the other kind beside it. A terminal tab runs the agent's own interface;
/// a chat tab is Next Term's native view of the agent's session. These are the rules alone: which tabs offer a handoff,
/// which reasons refuse it, and what the new tab opens. HandoffRunner, in the app, gathers the facts and acts.
///
/// The source's agent always ends first, after the user agrees: both agents append to one transcript or rollout file per
/// conversation, and two live processes writing one conversation would interleave its turns.
///
/// Two tiers keep menus cheap: `offer` reads only what a tab's status holds already; `plan` runs once a handoff is asked
/// for, on the evidence read then. So a tab may offer a handoff and still refuse it.
public enum ConversationHandoff {
    /// The two kinds of tab a conversation can live in.
    public enum Kind: String, CaseIterable, Sendable {
        case terminal, chat

        public var other: Kind { self == .terminal ? .chat : .terminal }

        /// "Chat", "Terminal": as a menu item and a note name it.
        public var title: String { self == .terminal ? "Terminal" : "Chat" }
    }

    /// The agents whose conversations move between kinds: the only two whose chat resumes the agent's own conversation.
    public enum Agent: String, CaseIterable, Sendable {
        case claude, codex

        /// The agent a tab's program is, by its name (`claude`, `codex`).
        public init?(program: String) {
            self.init(rawValue: program)
        }

        /// The agent a chat tab hosts, by its catalog id.
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

        /// The session catalog's agent.
        public var sessionAgent: ACPAgent {
            ACPAgent.named(rawValue) ?? ACPAgent(id: rawValue, name: name, program: rawValue, arguments: [])
        }

        /// What product text calls it.
        public var name: String { self == .claude ? "Claude Code" : "Codex" }

        /// The slash command that quits its terminal interface.
        public var quitWord: String { self == .claude ? "/exit" : "/quit" }
    }

    /// A tab that offers a handoff: its agent, the kind it is, and whether a handoff runs in it now.
    public struct Offer: Equatable, Sendable {
        public var agent: Agent
        public var from: Kind
        public var handingOff: Bool

        public init(agent: Agent, from: Kind, handingOff: Bool = false) {
            self.agent = agent
            self.from = from
            self.handingOff = handingOff
        }

        /// The kind the handoff opens.
        public var to: Kind { from.other }

        /// The menu item's title: "Continue in Chat" from a terminal tab, "Open in Terminal" from a chat tab.
        public var title: String { from == .terminal ? "Continue in Chat" : "Open in Terminal" }
    }

    /// The cheap tier: the handoff a tab offers from what its status holds, or nil.
    ///
    /// `chatAgentID` is the agent a chat tab hosts (nil for a terminal tab): Claude Code or Codex offer Open in Terminal,
    /// running or ended, as the end card offers it too. A local terminal tab running `claude` or `codex` as an agent
    /// offers Continue in Chat. A remote tab, a tab that shows herdr, a stopped program, an ACP agent and anything else
    /// offer none.
    ///
    /// A launcher alias (`cw` for `claude --model opus`) names itself as the program, so `expandedCommand`, the line with
    /// aliases expanded (TabStatus.expandedCommand), names the agent then.
    public static func offer(chatAgentID: String?, program: String, expandedCommand: String = "", kind: CommandKind,
                             running: Bool, remote: Bool, herdr: Bool) -> Offer? {
        guard !remote, !herdr else { return nil }
        if let chatAgentID { return Agent(sessionAgentID: chatAgentID).map { Offer(agent: $0, from: .chat) } }
        guard running, kind == .agent else { return nil }
        let expanded = expandedCommand.isEmpty ? "" : CommandClassifier.programName(expandedCommand)
        guard let agent = Agent(program: program) ?? Agent(program: expanded) else { return nil }
        return Offer(agent: agent, from: .terminal)
    }

    // MARK: the plan

    /// What a chat tab's session last reported (its host's report).
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
        /// A resume of `sessionID` couldn't go on in the chat: that conversation is the one to try in the terminal.
        public var resumeFailed: Bool

        public init(sessionID: String?, turns: Int, state: TabState, folder: String?, resumed: Bool = false,
                    resumeFailed: Bool = false) {
            self.sessionID = sessionID
            self.turns = turns
            self.state = state
            self.folder = folder
            self.resumed = resumed
            self.resumeFailed = resumeFailed
        }
    }

    /// What a handoff is planned from, read as it is asked for.
    public struct Facts: Equatable, Sendable {
        /// The tab's offer; nil when it offers none.
        public var offer: Offer?
        /// The kind asked for (MCP's `view`); nil: the other one.
        public var wanted: Kind?
        /// The tab's mark and the question its agent waits on, from its status.
        public var state: TabState
        public var question: String?
        /// A terminal source's shell integration reports: the only sign the shell's prompt is back once the agent quits.
        public var integrated: Bool
        /// A handoff runs in this tab already.
        public var handingOff: Bool
        /// A terminal source's agent evidence (ProcessInspector.agentEvidence), read now.
        public var evidence: SessionSnapshot.Evidence?
        /// Claude Code's transcript of the evidence's session exists (`claudeTranscript`): it has had a turn.
        public var transcriptExists: Bool
        /// A chat source's last report.
        public var report: ChatReport?
        /// The terminal evidence this tab had when it last continued in chat in this run of Next Term: the line back
        /// puts the user's own launch back.
        public var remembered: SessionSnapshot.Evidence?
        /// The name of another tab where this conversation is live already (ConversationOwners), or nil.
        public var liveElsewhere: String?
        /// The source tab's folder: where the new tab opens when the conversation's folder isn't known.
        public var sourceFolder: String?
        /// A chat source whose agent has ended: nothing to end, and its last state is no reason to refuse.
        public var chatEnded: Bool

        public init(offer: Offer?, wanted: Kind? = nil, state: TabState = .idle, question: String? = nil,
                    integrated: Bool = true, handingOff: Bool = false, evidence: SessionSnapshot.Evidence? = nil,
                    transcriptExists: Bool = false, report: ChatReport? = nil, remembered: SessionSnapshot.Evidence? = nil,
                    liveElsewhere: String? = nil, sourceFolder: String? = nil, chatEnded: Bool = false) {
            self.offer = offer
            self.wanted = wanted
            self.state = state
            self.question = question
            self.integrated = integrated
            self.handingOff = handingOff
            self.evidence = evidence
            self.transcriptExists = transcriptExists
            self.report = report
            self.remembered = remembered
            self.liveElsewhere = liveElsewhere
            self.sourceFolder = sourceFolder
            self.chatEnded = chatEnded
        }
    }

    /// Why a handoff doesn't run (the plan's refusal table). Each is said before any key or signal reaches the source.
    public enum Refusal: Error, Equatable, Sendable {
        /// The tab runs neither agent here (MCP's words; the menu item is off there).
        case notOffered
        /// The tab is the kind asked for: MCP answers ok, with the words as its note.
        case isAlready(Kind)
        case alreadyHandingOff
        case working
        case asking
        case noExactID
        case noTurnYet
        case noIntegration
        /// The conversation is live in another tab, named.
        case openElsewhere(String)

        /// Not a failure: the answer is that nothing needed doing.
        public var isAnswer: Bool {
            if case .isAlready = self { return true }
            return false
        }

        /// The words shown in the tab, or MCP's error text. `agent` names the tab's agent.
        public func text(agent: Agent?) -> String {
            let name = agent?.name ?? "The agent"
            switch self {
            case .notOffered: return "That tab doesn\u{2019}t run Claude Code or Codex on this Mac."
            case .isAlready(let kind): return "It is a " + kind.rawValue + " tab already."
            case .alreadyHandingOff: return "This tab is handing its conversation over already."
            case .working: return name + " is working. Try again when its turn ends."
            case .asking: return name + " is asking you something. Answer it first."
            case .noExactID: return "Next Term can\u{2019}t tell which " + name + " conversation this is."
            case .noTurnYet: return "No conversation to carry over yet: send a prompt first."
            case .noIntegration: return "Continuing needs Next Term\u{2019}s shell integration in this tab."
            case .openElsewhere(let tab): return "This conversation is open in \u{201C}" + tab + "\u{201D}."
            }
        }
    }

    /// One thing sent to a terminal source to quit its agent, in order.
    public enum Step: Equatable, Sendable {
        /// Keys sent as typed, never as a paste (a paste may not open a slash menu).
        case keys(String)
        /// A wait, in milliseconds.
        case pause(Int)
        /// Keys sent only while the agent still runs: once it has gone they would reach the shell.
        case keysIfRunning(String)
    }

    /// A handoff that may run: what ends in the source, and what the new tab opens.
    public struct Target: Equatable, Sendable {
        /// The kind of the new tab.
        public var kind: Kind
        public var agent: Agent
        /// The conversation carried over; empty when an ended chat's terminal starts the agent plain.
        public var sessionID: String
        /// The folder the new tab opens in: the conversation's, else the source tab's.
        public var folder: String?
        /// A chat target's start: the conversation resumed, and never a new one in its place.
        public var chat: ChatStart?
        /// A terminal target's line, run in the new tab, for a tab opened in `folder`.
        public var terminalLine: String?
        /// A terminal source's quit: the agent's own keys. Empty for a chat source, whose host ends its own process.
        public var quit: [Step]
        /// Sent when a terminal source's agent still runs after `quitWait`.
        public var fallback: [Step]
        /// The source tab's dim note (a terminal) or ended row (a chat).
        public var note: String
        /// The folder the conversation belongs to, when known: a terminal line opened elsewhere goes there first.
        var conversationFolder: String?

        /// The terminal line for a new tab that opened in `folder` rather than `self.folder`: it goes to the
        /// conversation's folder first, as both agents find a conversation by its folder.
        public func terminalLine(openedIn folder: String?) -> String? {
            terminalLine.map { ConversationHandoff.inFolder(conversationFolder, shell: folder, $0) }
        }
    }

    /// How long a terminal source's agent has to quit before the fallback, and then before the handoff gives up.
    public static let quitWait: TimeInterval = 5
    public static let fallbackWait: TimeInterval = 3

    /// ⌃C: it clears a draft, stops a turn, or arms the quit. ⌃D is never sent: at the shell's prompt it would end the
    /// shell.
    static let interrupt = "\u{3}"

    /// The handoff `facts` allow, or the first reason in the table's order that refuses it. A handoff already running is
    /// said first, as what the agent it is ending shows meanwhile is no reason. Only an exact id moves a conversation: a
    /// guess would resume another one. Only the agent's own record of the conversation it has open counts for a terminal
    /// source (Claude Code's session file, Codex's open rollout): an id from the typed line and argv is the one it
    /// started with, and the user may have moved to another conversation inside it since. A conversation live in
    /// another tab is said last, as it needs the exact id to look for.
    public static func plan(_ facts: Facts) -> Result<Target, Refusal> {
        guard let offer = facts.offer else { return .failure(.notOffered) }
        let agent = offer.agent
        if facts.handingOff || offer.handingOff { return .failure(.alreadyHandingOff) }
        if let wanted = facts.wanted, wanted == offer.from { return .failure(.isAlready(wanted)) }
        switch offer.from {
        case .terminal: return terminalSource(facts, agent: agent)
        case .chat: return chatSource(facts, agent: agent)
        }
    }

    private static func terminalSource(_ facts: Facts, agent: Agent) -> Result<Target, Refusal> {
        if facts.state == .working { return .failure(.working) }
        if facts.question != nil { return .failure(.asking) }
        guard let evidence = facts.evidence, evidence.agent == agent.restoreAgent, ownRecord.contains(evidence.source),
              let id = evidence.sessionID, agent.restoreAgent.isSessionID(id) else { return .failure(.noExactID) }
        // Codex's open rollout is its conversation, with or without a turn: an empty thread resumes as one.
        if agent == .claude, !facts.transcriptExists { return .failure(.noTurnYet) }
        guard facts.integrated else { return .failure(.noIntegration) }
        if let tab = facts.liveElsewhere { return .failure(.openElsewhere(tab)) }
        let conversation = absolute(evidence.sessionFolder)
        let folder = conversation ?? facts.sourceFolder
        let start = ChatStart(agentID: agent.rawValue, folder: folder, resumeID: id, resumeOnly: true)
        let note = continued(in: .chat, agent: agent, id: id, dropped: optionNames(evidence))
        return .success(Target(kind: .chat, agent: agent, sessionID: id, folder: folder, chat: start, terminalLine: nil,
                               quit: terminalQuit(agent), fallback: fallback, note: note, conversationFolder: conversation))
    }

    private static func chatSource(_ facts: Facts, agent: Agent) -> Result<Target, Refusal> {
        let report = facts.report
        if facts.chatEnded { return endedChatSource(facts, agent: agent) }
        if facts.state == .working || report?.state == .working { return .failure(.working) }
        if facts.question != nil || report?.state == .attention { return .failure(.asking) }
        guard let report, let id = report.sessionID, agent.restoreAgent.isSessionID(id) else { return .failure(.noExactID) }
        if report.turns == 0, !report.resumed { return .failure(.noTurnYet) }
        if let tab = facts.liveElsewhere { return .failure(.openElsewhere(tab)) }
        let conversation = absolute(report.folder)
        let line = terminalLine(agent: agent, id: id, folder: report.folder, remembered: facts.remembered)
        return .success(Target(kind: .terminal, agent: agent, sessionID: id, folder: conversation ?? facts.sourceFolder,
                               chat: nil, terminalLine: line, quit: [], fallback: [],
                               note: continued(in: .terminal, agent: agent, id: id, dropped: []), conversationFolder: conversation))
    }

    /// An ended chat's Open in Terminal: the conversation when the session has one (a turn, a resume, or a resume that
    /// couldn't go on here), else the agent started plain, as signing in or a terminal-only command needs the terminal
    /// whether or not there is a conversation yet.
    private static func endedChatSource(_ facts: Facts, agent: Agent) -> Result<Target, Refusal> {
        let report = facts.report
        var id = ""
        if let reported = report?.sessionID, agent.restoreAgent.isSessionID(reported),
           report?.resumeFailed == true || report?.resumed == true || (report?.turns ?? 0) > 0 {
            id = reported
        }
        if !id.isEmpty, let tab = facts.liveElsewhere { return .failure(.openElsewhere(tab)) }
        let conversation = absolute(report?.folder)
        let line = id.isEmpty ? agent.rawValue
            : terminalLine(agent: agent, id: id, folder: report?.folder, remembered: facts.remembered)
        let note = id.isEmpty ? "Continued in Terminal: " + agent.name
            : continued(in: .terminal, agent: agent, id: id, dropped: [])
        return .success(Target(kind: .terminal, agent: agent, sessionID: id, folder: conversation ?? facts.sourceFolder,
                               chat: nil, terminalLine: line, quit: [], fallback: [], note: note, conversationFolder: conversation))
    }

    /// The id sources a handoff moves a conversation by: the agent's own record of the one it has open now.
    static let ownRecord: Set<SessionSnapshot.IDSource> = [.sessionFile, .openRollout]

    /// A terminal source's quit: ⌃C, then the agent's quit word as keys, then Return, a moment apart; the word and the
    /// Return only while the agent still runs, as one that quit on the ⌃C would leave them to the shell.
    static func terminalQuit(_ agent: Agent) -> [Step] {
        [.keys(interrupt), .pause(150), .keysIfRunning(agent.quitWord), .pause(150), .keysIfRunning("\r")]
    }

    /// ⌃C, and a second only while the agent still runs: both agents' double ⌃C.
    static let fallback: [Step] = [.keys(interrupt), .pause(300), .keysIfRunning(interrupt)]

    /// A terminal target's line: the user's own launch with the resume form, when this tab continued in chat from it
    /// with this conversation; otherwise the agent's plain resume line.
    static func terminalLine(agent: Agent, id: String, folder: String?, remembered: SessionSnapshot.Evidence?) -> String {
        if let remembered, remembered.agent == agent.restoreAgent, remembered.sessionID == id,
           let back = remembered.putBack(id: id, folder: folder), back.namesSession {
            return back.line
        }
        return agent.restoreAgent.putBackLine(id: id, folder: folder) ?? agent.rawValue
    }

    /// `line`, run in `folder` when the shell is elsewhere.
    static func inFolder(_ folder: String?, shell: String?, _ line: String) -> String {
        guard let folder = absolute(folder) else { return line }
        if let shell, ProtectedPlaces.trimmed(shell) == ProtectedPlaces.trimmed(folder) { return line }
        return "cd -- " + ShellQuote.quote(folder) + " && " + line
    }

    /// `folder` when it is a plain absolute path, else nil.
    static func absolute(_ folder: String?) -> String? {
        guard let folder, folder.hasPrefix("/") else { return nil }
        return folder
    }

    /// The names of the options a terminal source ran with, which a chat doesn't carry: names only, never a value, and
    /// only those a note may show.
    static func optionNames(_ evidence: SessionSnapshot.Evidence) -> [String] {
        var names: [String] = []
        for option in evidence.options ?? [] {
            let name = option.name
            guard RestoreAgent.isOptionName(name), !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    /// "Continued in Chat: Claude Code conversation 8f3a1c2e", and what the chat drops, by name.
    static func continued(in kind: Kind, agent: Agent, id: String, dropped: [String]) -> String {
        let text = "Continued in " + kind.title + ": " + agent.name + " conversation " + String(id.prefix(8))
        return dropped.isEmpty ? text : text + ". Not carried: " + dropped.joined(separator: ", ")
    }

    // MARK: words around a handoff

    /// The confirmation's words, asked on the source's window before anything ends.
    public struct Confirmation: Equatable, Sendable {
        public var title: String
        public var detail: String
        public var button: String
        public var cancel: String
        /// The box that stops the question being asked again (`setAsksFirst`).
        public var suppression: String
    }

    public static func confirmation(for offer: Offer) -> Confirmation {
        let name = offer.agent.name
        switch offer.from {
        case .terminal:
            return Confirmation(title: "Continue this conversation in Chat?", detail: name + " quits in this tab.",
                                button: "Continue", cancel: "Cancel", suppression: "Don\u{2019}t ask again")
        case .chat:
            return Confirmation(title: "Open this conversation in Terminal?",
                                detail: "This chat ends, and " + name + " goes on in a terminal tab beside it.",
                                button: "Continue", cancel: "Cancel", suppression: "Don\u{2019}t ask again")
        }
    }

    /// The defaults key of the confirmation's "Don't ask again" box. MCP's `continue_in` asks on the Mac whatever it says.
    public static let skipConfirmKey = "handoff.skipConfirm"

    /// Whether ⇧⌘J and the menus ask before a handoff: until the user ticks "Don't ask again".
    public static func asksFirst(defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: skipConfirmKey)
    }

    public static func setAsksFirst(_ asks: Bool, defaults: UserDefaults) {
        defaults.set(!asks, forKey: skipConfirmKey)
    }

    /// The chat's note when it doesn't send a terminal-only command (`/login`): where the command works. `shortcut` is
    /// the user's key for the handoff, when it has one.
    public static func terminalOnlyLine(_ word: String, shortcut: String?) -> String {
        let key = shortcut.map { " (" + $0 + ")" } ?? ""
        return word + " works in the terminal: Open in Terminal" + key
    }

    /// Where Claude Code keeps session `sessionID`'s transcript in `folder`, under its store: it exists once the session
    /// has had a turn.
    public static func claudeTranscript(store: String, folder: String, sessionID: String) -> String {
        (store as NSString).appendingPathComponent("projects/" + AgentSessions.claudeFolderName(folder) + "/" + sessionID + ".jsonl")
    }
}

/// How a chat tab starts (plan 037): the agent, the folder, and either a first prompt or the conversation it resumes.
/// A handoff, a restore and the Chat default for a start Next Term makes all open a chat tab with one.
public struct ChatStart: Equatable, Sendable {
    /// The session catalog's agent id (`claude`, `codex`, `gemini`, ...).
    public var agentID: String
    /// The folder the agent runs in; nil: the window's.
    public var folder: String?
    /// The first prompt, sent once the session is ready.
    public var prompt: String?
    /// The conversation to go on with (Claude Code's session id, Codex's thread id).
    public var resumeID: String?
    /// A resume that can't go on ends the session with an Open in Terminal offer instead of starting a new conversation.
    public var resumeOnly: Bool
    /// The tab's title; nil: the agent's name.
    public var title: String?

    public init(agentID: String, folder: String?, prompt: String? = nil, resumeID: String? = nil, resumeOnly: Bool = false,
                title: String? = nil) {
        self.agentID = agentID
        self.folder = folder
        self.prompt = prompt
        self.resumeID = resumeID
        self.resumeOnly = resumeOnly
        self.title = title
    }
}
