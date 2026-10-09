import Foundation

// The restore planner (KTD3): one pure function from a pane's saved record to what the restore does to it. Its answer is
// a stable code, RestoreOutcome, that the keep-sessions sheet, the restore and MCP all read, with the sheet's words for
// it, the line typed once the shell is ready, and the note the tab shows. What it reads of the Mac (folders, the gate's
// facts, the agents' session stores, host names) comes in through World, so the same facts always give the same plan.
//
// Each pane, the first match wins:
// - a tab kept on a server by tmux or herdr reattaches; any other remote tab opens a fresh connection;
// - a line that held a secret is not kept, and the note says so (a remote tab keeps its outcome);
// - a shell without the integration gets a note: an agent's names its resume command;
// - agy and Aider get a note on how to resume them;
// - Claude Code, Codex and Qwen Code resume by themselves only on an update restore, with an exact id from their own
//   session file and the gate passing (KTD5); every other agent's resume command goes on the line, unrun (R6);
// - a command still running goes back on the line, unrun, when it was typed whole in the system /bin/zsh (R9);
//   any other gets a note;
// - an idle tab gets its folder back, and a note with its last command.
// A crash restore never resumes. In safe mode the plan is what Try Again would apply; until then each local tab only
// says what it held. Nothing here runs or types anything.

// MARK: - What the restore does

/// What the restore does to a pane: the code the sheet, the restore and MCP read.
public enum RestoreOutcome: String, CaseIterable, Sendable {
    /// Claude Code, Codex or Qwen Code resumes by itself once the shell is ready.
    case resume
    /// An agent's resume command waits on the prompt line, unrun.
    case agentOnTheLine
    /// A command that was running waits on the prompt line, unrun.
    case commandOnTheLine
    /// An agent in a shell without the integration: a note that names its resume command.
    case agentNote
    /// agy, Aider, or an agent the matrix does not know: a note on how to resume it.
    case agentHint
    /// A command that was running and could not be put back: a note that says why.
    case commandNote
    /// The last line held a secret: a note that it was not kept.
    case notKept
    /// An idle tab: its shell and folder, and a note with its last command.
    case idle
    /// A tab kept on a server by tmux or herdr, reattached. Nothing is typed.
    case reattach
    /// A plain ssh tab, reopened as a fresh connection with a note. Nothing is typed.
    case freshConnection

    /// The pending action that carries it out.
    public var action: SessionSnapshot.Action {
        switch self {
        case .resume: return .resume
        case .agentOnTheLine: return .onTheLine
        case .commandOnTheLine: return .typeIn
        case .reattach: return .reattach
        case .freshConnection: return .freshConnection
        case .agentNote, .agentHint, .commandNote, .notKept, .idle: return .note
        }
    }
}

/// Why a command that was running did not go back on the line.
public enum NotPutBack: String, CaseIterable, Sendable {
    /// The integration did not report it typed (polled argv, which loses its quoting).
    case notTyped
    /// Not the system /bin/zsh, where a process in the tab could forge a typed line.
    case otherShell
    case multiline
    case tooLong
    case unsafeCharacters
    /// Its checks did not finish, or this version does not know their answer.
    case unchecked

    /// The words after "It was not put back:".
    var words: String {
        switch self {
        case .notTyped: return "the shell did not report it as typed"
        case .otherShell: return "it ran in a shell other than the Mac's own /bin/zsh"
        case .multiline: return "it was more than one line"
        case .tooLong: return "it was too long"
        case .unsafeCharacters: return "it held control or invisible characters"
        case .unchecked: return "it could not be checked"
        }
    }

    /// Why `command` may not go back on the line, or nil when it may.
    static func reason(_ command: SessionSnapshot.Command, systemZsh: Bool) -> NotPutBack? {
        switch command.check {
        case .multiline: return .multiline
        case .tooLong: return .tooLong
        case .unsafeCharacters: return .unsafeCharacters
        case .secret, .unknown: return .unchecked
        case .kept: break
        }
        guard command.source == .integration else { return .notTyped }
        guard systemZsh else { return .otherShell }
        return command.line == nil ? .unchecked : nil
    }
}

/// How the session a line names was found.
public enum SessionNaming: String, CaseIterable, Sendable {
    /// Agreeing evidence: the agent's own record of its process, or the typed line and argv (KTD4).
    case exact
    /// The newest session the agent started in the folder after it started: a guess.
    case newest
    /// Only the process named it, with nothing to agree: a guess.
    case unconfirmed
}

/// The session a pane's line or resume names.
public struct NamedSession: Equatable, Sendable {
    public var agent: RestoreAgent
    public var id: String
    public var naming: SessionNaming
    /// When it was last written, when a session reader said.
    public var date: Date?

    public init(agent: RestoreAgent, id: String, naming: SessionNaming, date: Date? = nil) {
        self.agent = agent
        self.id = id
        self.naming = naming
        self.date = date
    }

    var identity: String { agent.rawValue + ":" + id }
}

/// The folder a local tab opens in.
public struct FolderChoice: Equatable, Sendable {
    public var path: String
    /// The folder it had, when that was gone: `path` is the nearest one left.
    public var movedFrom: String?

    public init(path: String, movedFrom: String? = nil) {
        self.path = path
        self.movedFrom = movedFrom
    }
}

/// Where a guessed session comes from (the plan's agent matrix): Claude Code, Codex and Command Code from their own
/// readers, Gemini CLI, Cursor Agent and opencode from `AgentSessions.newest`.
public struct SessionLookup {
    /// An agent's own reader: the sessions it recorded in exactly `folder`, files last written before the date skipped.
    public var read: (AgentKind, String, Date) -> [AgentSession]
    /// `AgentSessions.newest`: the newest session started in `folder` at or after the date, ids in the set left out.
    public var newest: (AgentKind, String, Date, Set<String>) -> AgentSession?

    public init(read: @escaping (AgentKind, String, Date) -> [AgentSession],
                newest: @escaping (AgentKind, String, Date, Set<String>) -> AgentSession?) {
        self.read = read
        self.newest = newest
    }

    /// The stores in `home`.
    public static func live(home: String = NSHomeDirectory()) -> SessionLookup {
        SessionLookup(read: { (agent: AgentKind, folder: String, since: Date) -> [AgentSession] in
            (try? agent.provider(home: home).sessions(in: canonicalPath(folder), subfolders: false, since: since)) ?? []
        }, newest: { (agent: AgentKind, folder: String, after: Date, excluding: Set<String>) -> AgentSession? in
            AgentSessions.newest(agent: agent, in: folder, after: after, excluding: excluding, home: home)
        })
    }
}

/// What the restore did to one pane, and the words for it.
public struct PanePlan: Equatable, Sendable {
    /// The pane's tab id.
    public var pane: UUID
    public var outcome: RestoreOutcome
    /// Why it was restored: an update, a crash, or safe mode, where nothing is applied until Try Again.
    public var reason: SessionSnapshot.RestoreKind
    /// What is typed once the shell is ready: the resume command run (`.resume`), or the line put back unrun. Nil for
    /// a note and for a remote tab.
    public var line: String?
    /// The folder a local tab opens in: for a resume, the session's own.
    public var folder: String?
    /// The session its line or resume names.
    public var session: NamedSession?
    public var note: RestoreNote
    /// The keep-sessions sheet's words for it ("Claude Code resumes", "connection closes"), after the tab's title.
    public var listLine: String

    /// The action that carries it out, not yet applied.
    public var pending: SessionSnapshot.PendingAction {
        SessionSnapshot.PendingAction(action: outcome.action, reason: reason)
    }
}

// MARK: - The planner

public enum RestorePlanner {
    /// What the planner reads of the Mac.
    public struct World {
        public var home: String
        /// The folder is there, found within the restore's time budget.
        public var folderExists: (String) -> Bool
        /// The gate's facts for an agent's evidence, in a tab whose folder was the one given.
        public var resumeFacts: (SessionSnapshot.Evidence, String?) -> ResumeFacts
        public var sessions: SessionLookup
        /// The names the user gave hosts, by host id.
        public var hostNames: [String: String]

        public init(home: String = NSHomeDirectory(), folderExists: @escaping (String) -> Bool = World.isFolder,
                    resumeFacts: @escaping (SessionSnapshot.Evidence, String?) -> ResumeFacts, sessions: SessionLookup? = nil,
                    hostNames: [String: String] = [:]) {
            self.home = home
            self.folderExists = folderExists
            self.resumeFacts = resumeFacts
            self.sessions = sessions ?? .live(home: home)
            self.hostNames = hostNames
        }

        public static func isFolder(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// Everything one pane's plan depends on.
    public struct PaneInput: Sendable {
        public var pane: SessionSnapshot.Pane
        /// An update restore, or a crash restore. Anything else plans as a crash: nothing resumes.
        public var kind: SessionSnapshot.RestoreKind
        public var safeMode: Bool
        /// Where a local tab opens.
        public var folder: FolderChoice?
        /// The session its agent names, or the one guessed for it.
        public var session: NamedSession?
        /// The gate's verdict, for an agent that may resume by itself.
        public var verdict: ResumeVerdict?
        /// Another pane on the same session resumes it.
        public var sharedSession: Bool
        /// A remote tab's host, by name.
        public var host: String?

        public init(pane: SessionSnapshot.Pane, kind: SessionSnapshot.RestoreKind, safeMode: Bool = false, folder: FolderChoice? = nil,
                    session: NamedSession? = nil, verdict: ResumeVerdict? = nil, sharedSession: Bool = false, host: String? = nil) {
            self.pane = pane
            self.kind = kind
            self.safeMode = safeMode
            self.folder = folder
            self.session = session
            self.verdict = verdict
            self.sharedSession = sharedSession
            self.host = host
        }
    }

    /// Every pane of `snapshot`, in reading order. Sessions are named first, so no two panes guess the same one, and of
    /// two panes on one session only the one selected last resumes.
    public static func plan(_ snapshot: SessionSnapshot, kind: SessionSnapshot.RestoreKind, safeMode: Bool = false,
                            world: World) -> [PanePlan] {
        var panes: [SessionSnapshot.Pane] = []
        var projects: [String?] = []
        for window in snapshot.windows {
            for pane in window.groups.flatMap(\.panes) {
                panes.append(pane)
                projects.append(window.project)
            }
        }
        let sessions = namedSessions(panes, lookup: world.sessions)
        var inputs: [PaneInput] = []
        for (index, pane) in panes.enumerated() {
            inputs.append(input(for: pane, project: projects[index], session: sessions[index], kind: kind, safeMode: safeMode, world: world))
        }
        var plans: [PanePlan] = inputs.map { (input: PaneInput) -> PanePlan in plan(input) }
        for index in sharing(plans, panes: panes) {
            inputs[index].sharedSession = true
            plans[index] = plan(inputs[index])
        }
        return plans
    }

    /// One pane's plan, from everything it depends on.
    public static func plan(_ input: PaneInput) -> PanePlan {
        let pane = input.pane
        let decision = decide(input)
        var note = RestoreNote(outcome: decision.outcome)
        if pane.remote == nil { note.agent = pane.agent?.agent }
        note.line = decision.noteLine
        note.session = decision.session
        note.leftOff = decision.noteLine == nil ? [] : pane.agent?.leftOff ?? []
        note.interrupted = pane.interrupted
        note.sharedSession = input.sharedSession && decision.noteLine != nil
        // An agent's typed line holds its prompt words: its note names only its put-back line (R8).
        if pane.agent == nil || pane.remote != nil {
            note.command = pane.command?.line
            note.exitCode = pane.command?.exitCode
        }
        note.notPutBack = decision.notPutBack
        note.commandNotKept = pane.command?.check == .secret
        note.host = input.host
        if let moved = input.folder?.movedFrom {
            note.movedFrom = moved
            note.openedIn = input.folder?.path
        }
        note.reminted = pane.reminted
        note.safeMode = input.safeMode && pane.remote == nil
        let reason: SessionSnapshot.RestoreKind = input.safeMode ? .safeMode : input.kind
        return PanePlan(pane: pane.id, outcome: decision.outcome, reason: reason, line: decision.line,
                        folder: decision.folder ?? input.folder?.path, session: decision.session, note: note, listLine: note.listLine)
    }

    /// The folder a local tab opens in: its own; when that is gone, the nearest folder above it inside the project, then
    /// the project, then home.
    public static func folder(for recorded: String?, project: String?, home: String, exists: (String) -> Bool) -> FolderChoice {
        guard let recorded else {
            guard let project, exists(project) else { return FolderChoice(path: home) }
            return FolderChoice(path: project)
        }
        if exists(recorded) { return FolderChoice(path: recorded) }
        var candidates: [String] = []
        if let project {
            let inside = project.hasSuffix("/") ? project : project + "/"
            var current = (recorded as NSString).deletingLastPathComponent
            while current.hasPrefix(inside) {
                candidates.append(current)
                current = (current as NSString).deletingLastPathComponent
            }
            candidates.append(project)
        }
        return FolderChoice(path: candidates.first(where: exists) ?? home, movedFrom: recorded)
    }

    /// The record a save writes for a restored pane: while its action is pending, the record it was restored from,
    /// unchanged, so a restore that fails or stops in safe mode loses nothing (KTD3); after that, the pane as it is now.
    public static func recordToSave(restored: SessionSnapshot.Pane, current: SessionSnapshot.Pane) -> SessionSnapshot.Pane {
        restored.pending?.state == .pending ? restored : current
    }

    // MARK: deciding

    private struct Decision {
        var outcome: RestoreOutcome
        /// What is typed once the shell is ready.
        var line: String?
        /// An agent's put-back line, for its note.
        var noteLine: String?
        var session: NamedSession?
        var notPutBack: NotPutBack?
        /// Where a resume runs: the session's folder.
        var folder: String?
    }

    private static func decide(_ input: PaneInput) -> Decision {
        let pane = input.pane
        if pane.remote != nil {
            let kept = pane.keep == .tmux || pane.keep == .herdr
            return Decision(outcome: kept ? .reattach : .freshConnection)
        }
        if pane.command?.check == .secret { return Decision(outcome: .notKept) }
        let integrated = pane.command?.source == .integration
        if let evidence = pane.agent { return decide(agent: evidence, input, integrated: integrated) }
        guard let command = pane.command, command.running else { return Decision(outcome: .idle) }
        if let reason = NotPutBack.reason(command, systemZsh: pane.systemZsh) {
            return Decision(outcome: .commandNote, notPutBack: reason)
        }
        return Decision(outcome: .commandOnTheLine, line: command.line)
    }

    private static func decide(agent evidence: SessionSnapshot.Evidence, _ input: PaneInput, integrated: Bool) -> Decision {
        let agent = evidence.agent
        guard let line = agent.putBackLine(id: input.session?.id, folder: evidence.sessionFolder) else {
            return Decision(outcome: .agentHint)
        }
        // The note names the session the line names, and none when the line has no id.
        let session = line == agent.program ? nil : input.session
        guard integrated else { return Decision(outcome: .agentNote, noteLine: line, session: session) }
        if case .resume(let command)? = input.verdict, input.kind == .update, !input.sharedSession, input.folder?.movedFrom == nil,
           let session, session.naming == .exact, session.id == evidence.sessionID {
            return Decision(outcome: .resume, line: command, noteLine: line, session: session, folder: evidence.sessionFolder)
        }
        return Decision(outcome: .agentOnTheLine, line: line, noteLine: line, session: session)
    }

    private static func input(for pane: SessionSnapshot.Pane, project: String?, session: NamedSession?, kind: SessionSnapshot.RestoreKind,
                              safeMode: Bool, world: World) -> PaneInput {
        var input = PaneInput(pane: pane, kind: kind, safeMode: safeMode)
        if let remote = pane.remote {
            input.host = world.hostNames[remote.hostID] ?? remote.destination ?? "the server"
            return input
        }
        input.folder = folder(for: pane.folder, project: project, home: world.home, exists: world.folderExists)
        input.session = session
        input.verdict = verdict(for: pane, kind: kind, world: world)
        return input
    }

    /// The gate's verdict, asked only where a resume could follow: an update restore, an agent that resumes by itself
    /// with an exact id from its own session file, in a shell with the integration.
    private static func verdict(for pane: SessionSnapshot.Pane, kind: SessionSnapshot.RestoreKind, world: World) -> ResumeVerdict? {
        guard kind == .update, let command = pane.command, command.check != .secret, command.source == .integration else { return nil }
        guard let evidence = pane.agent, evidence.isExact, let source = evidence.agent.fileSource, evidence.source == source else { return nil }
        return evidence.gate(world.resumeFacts(evidence, pane.folder))
    }

    /// The panes, by index, that name a session another pane resumes: of those that would resume it, the one selected
    /// last does (the first of them on a tie), and every other pane naming it keeps its line.
    private static func sharing(_ plans: [PanePlan], panes: [SessionSnapshot.Pane]) -> [Int] {
        var resumer: [String: Int] = [:]
        for (index, plan) in plans.enumerated() where plan.outcome == .resume {
            guard let key = plan.session?.identity else { continue }
            if let other = resumer[key], panes[other].lastSelected >= panes[index].lastSelected { continue }
            resumer[key] = index
        }
        return plans.indices.filter { (index: Int) -> Bool in
            guard let key = plans[index].session?.identity, let winner = resumer[key] else { return false }
            return winner != index
        }
    }

    // MARK: sessions

    /// The session each local agent pane names, by index: its own id when it has one in its agent's pattern, else the
    /// newest session its agent started in its folder since it started. The agent that started last guesses first, so
    /// the newest session goes to it, and no pane takes a session another pane names.
    static func namedSessions(_ panes: [SessionSnapshot.Pane], lookup: SessionLookup) -> [Int: NamedSession] {
        var named: [Int: NamedSession] = [:]
        var taken: [RestoreAgent: Set<String>] = [:]
        var unnamed: [(index: Int, start: Date)] = []
        for (index, pane) in panes.enumerated() {
            guard pane.remote == nil, pane.command?.check != .secret, let evidence = pane.agent, evidence.agent.hasResumeForm else { continue }
            guard let id = evidence.sessionID else {
                if let start = evidence.startedAt { unnamed.append((index, start)) }
                continue
            }
            // An id outside its pattern names nothing: the line is the program alone, and nothing is guessed in its place.
            guard evidence.agent.isSessionID(id) else { continue }
            let naming: SessionNaming = evidence.isExact ? .exact : .unconfirmed
            named[index] = NamedSession(agent: evidence.agent, id: id, naming: naming, date: evidence.sessionDate)
            taken[evidence.agent, default: []].insert(id)
        }
        unnamed.sort { (a: (index: Int, start: Date), b: (index: Int, start: Date)) -> Bool in
            a.start != b.start ? a.start > b.start : a.index < b.index
        }
        for entry in unnamed {
            let pane = panes[entry.index]
            guard let evidence = pane.agent, let folder = evidence.sessionFolder ?? pane.folder else { continue }
            let excluding = taken[evidence.agent] ?? []
            guard let found = guess(evidence.agent, in: folder, after: entry.start, excluding: excluding, lookup: lookup) else { continue }
            named[entry.index] = found
            taken[evidence.agent, default: []].insert(found.id)
        }
        return named
    }

    /// The newest session `agent` started in `folder` at or after `start`, not in `taken`, from that agent's reader
    /// (the plan's matrix): Claude Code, Codex and Command Code from their own, which also skip a session a live process
    /// has open; Gemini CLI, Cursor Agent and opencode from `AgentSessions.newest`. Nil for every other agent: Qwen Code,
    /// Copilot CLI, Amp and Junie have no reader for a guess, and Kiro CLI and Goose have no store the session list
    /// reads (no AgentKind), so `newest` has none to read.
    static func guess(_ agent: RestoreAgent, in folder: String, after start: Date, excluding taken: Set<String>,
                      lookup: SessionLookup) -> NamedSession? {
        let found: AgentSession?
        switch agent {
        case .claude, .codex, .commandCode:
            guard let kind = agent.kind else { return nil }
            let fresh = lookup.read(kind, folder, start).filter { (session: AgentSession) -> Bool in
                startTime(session) >= start && !session.isRunning && !taken.contains(session.id) && agent.isSessionID(session.id)
            }
            found = fresh.max { (a: AgentSession, b: AgentSession) -> Bool in startTime(a) < startTime(b) }
        case .gemini, .cursor, .opencode:
            guard let kind = agent.kind else { return nil }
            found = lookup.newest(kind, folder, start, taken)
        case .qwen, .copilot, .amp, .junie, .kiro, .goose, .agy, .aider, .unknown:
            return nil
        }
        guard let found, agent.isSessionID(found.id), !taken.contains(found.id) else { return nil }
        return NamedSession(agent: agent, id: found.id, naming: .newest, date: found.updatedAt)
    }

    private static func startTime(_ session: AgentSession) -> Date { session.createdAt ?? session.updatedAt }
}

// MARK: - Pending actions

extension SessionSnapshot.PendingAction {
    /// What can happen to a pane's pending action.
    public enum Event: String, CaseIterable, Sendable {
        /// The restore typed or ran it, or connected the tab.
        case applied
        /// The user typed in the tab first, so it is cancelled.
        case userInput
        /// It will not be applied: safe mode's Keep As Is, or a shell not ready in time.
        case dismissed
    }

    /// The action after `event`. Only a pending action moves, and only once: to applied, cancelled or dismissed.
    public func after(_ event: Event) -> Self {
        guard state == .pending else { return self }
        var next = self
        switch event {
        case .applied: next.state = .applied
        case .userInput: next.state = .cancelled
        case .dismissed: next.state = .dismissed
        }
        return next
    }
}

// MARK: - Notes

/// A restored tab's note, as fields. The text is made from them only when shown, and always through the sanitizer, so a
/// folder or host name cannot put anything but plain text in front of the prompt. Each note is one line, printed below
/// the restore divider just before the prompt.
public struct RestoreNote: Equatable, Sendable {
    public var outcome: RestoreOutcome
    /// The agent in a local tab.
    public var agent: RestoreAgent?
    /// An agent's put-back line: its resume form with the id, or its program alone. Never the command a resume runs.
    public var line: String?
    /// The session the line names.
    public var session: NamedSession?
    /// The options a resume leaves off, by name only.
    public var leftOff: [String] = []
    /// The restart cut the agent's turn off.
    public var interrupted = false
    /// Another tab resumes the same session.
    public var sharedSession = false
    /// The tab's kept command line (never one that failed its checks), and how it ended.
    public var command: String?
    public var exitCode: Int32?
    public var notPutBack: NotPutBack?
    /// The tab's last line held a secret.
    public var commandNotKept = false
    /// A remote tab's host, by the name the user gave it.
    public var host: String?
    /// The tab's folder was gone: the folder it had, and the one it opened in.
    public var movedFrom: String?
    public var openedIn: String?
    /// Its tab id was another tab's too, so it has a fresh one (R23).
    public var reminted = false
    /// Safe mode: nothing ran, and the note says what the tab held.
    public var safeMode = false

    public init(outcome: RestoreOutcome) {
        self.outcome = outcome
    }

    static let notKeptText = "The last command was not kept, because it looked like it held a secret."

    /// The note: one line of printable text, or nil when there is nothing to say. `dates` writes a session's date.
    public func text(dates: (Date) -> String = RestoreNote.dateText) -> String? {
        var parts: [String] = []
        if reminted { parts.append("This tab has a new id, because another tab had the same one.") }
        if let movedFrom, let openedIn { parts.append("\(movedFrom) is gone, so this tab opened in \(openedIn).") }
        let main = sentences(dates: dates)
        if safeMode {
            parts.append("Nothing ran, because the last two restores did not finish.")
            if !main.isEmpty { parts.append("This tab held: " + main.joined(separator: " ")) }
        } else {
            parts += main
        }
        return parts.isEmpty ? nil : TerminalText.oneLine(parts.joined(separator: " "))
    }

    /// A date as the user's Mac writes it.
    public static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// What the outcome says. In safe mode, an action that did not happen is told as what the tab held.
    private func sentences(dates: (Date) -> String) -> [String] {
        let name = agent?.name ?? "An agent"
        switch outcome {
        case .resume where !safeMode:
            var said = ["Resumed \(name) session \(session?.id ?? "")."]
            if interrupted { said.append("Its last turn was cut off by the update and did not continue.") }
            if let session { said += about(session, dates) }
            return said
        case .agentOnTheLine where !safeMode:
            let line = self.line ?? ""
            guard let session else {
                var said = ["\(line) is back on the line, not run. No \(name) session could be named, so Return starts a new one."]
                said += leftOffText
                return said
            }
            var said = ["\(line) is back on the line, not run. Press Return to resume \(name) session \(session.id), or edit it first."]
            said += about(session, dates)
            said += sharedText
            said += leftOffText
            return said
        case .resume, .agentOnTheLine, .agentNote:
            return typeToResume(dates)
        case .commandOnTheLine:
            let command = self.command ?? "A command"
            if safeMode { return ["\(command) was running."] }
            return ["\(command) is back on the line, not run. Press Return to run it, or edit it first."]
        case .agentHint:
            switch agent {
            case .agy?: return ["agy was running. Type /resume in agy to reopen the conversation."]
            case .aider?: return ["Aider was running. Start it with --restore-chat-history to reload the chat."]
            default: return ["An agent was running. Next Term does not know how to resume it."]
            }
        case .commandNote:
            let reason = notPutBack ?? .unchecked
            return ["\(command ?? "A command") was running. It was not put back: \(reason.words)."]
        case .notKept:
            return [Self.notKeptText]
        case .idle:
            return lastCommand.map { [$0] } ?? []
        case .reattach:
            return commandNotKept ? [Self.notKeptText] : []
        case .freshConnection:
            var said = ["New connection to \(host ?? "the server")."]
            if commandNotKept {
                said.append(Self.notKeptText)
            } else if let command {
                said.append("Last command: \(command).")
            }
            return said
        }
    }

    /// An agent's note when nothing is typed: that it was running, what is known of its session, and the line that
    /// resumes it, last, so nothing runs on after the line.
    private func typeToResume(_ dates: (Date) -> String) -> [String] {
        let name = agent?.name ?? "An agent"
        let line = self.line ?? agent?.program ?? ""
        var said = ["\(name) was running."]
        guard let session else {
            said.append("No \(name) session could be named.")
            said += leftOffText
            said.append("To start it again, type: \(line)")
            return said
        }
        said += about(session, dates)
        said += sharedText
        said += leftOffText
        said.append("To resume it, type: \(line)")
        return said
    }

    /// Whether a session is a guess, and when it was last used, when a session reader said.
    private func about(_ session: NamedSession, _ dates: (Date) -> String) -> [String] {
        var said: [String] = []
        switch session.naming {
        case .exact: break
        case .newest: said.append("This is a guess: the newest session in this folder.")
        case .unconfirmed: said.append("This is a guess: nothing confirmed this session.")
        }
        if let date = session.date { said.append("Last used \(dates(date)).") }
        return said
    }

    private var sharedText: [String] { sharedSession ? ["Another tab resumed this session."] : [] }

    private var leftOffText: [String] { leftOff.isEmpty ? [] : ["Left off: \(leftOff.joined(separator: ", "))."] }

    private var lastCommand: String? {
        guard let command else { return nil }
        guard let exitCode else { return "Last command: \(command)." }
        return "Last command: \(command) (exit \(exitCode))."
    }

    /// The keep-sessions sheet's words for the outcome. The sheet puts the tab's title or folder before them.
    public var listLine: String {
        let name = agent.flatMap { $0 == .unknown ? nil : $0.name } ?? "the agent"
        let words: String
        switch outcome {
        case .resume:
            words = "\(name) resumes"
        case .agentOnTheLine where session == nil:
            words = "\(line ?? name) goes on the line, with no session named"
        case .agentOnTheLine:
            words = "\(name)'s resume command goes on the line" + (sharedSession ? ", as another tab resumes this session" : "")
        case .commandOnTheLine:
            words = "\(command ?? "its command") goes back on the line"
        case .agentNote, .agentHint:
            words = "\(name) stops, with a note on resuming it"
        case .commandNote:
            words = "\(command ?? "its command") stops, with a note"
        case .notKept:
            words = "last command not kept"
        case .idle:
            words = "opens in its folder"
        case .reattach:
            words = "reattaches"
        case .freshConnection:
            words = "connection closes"
        }
        return TerminalText.oneLine(words)
    }
}
