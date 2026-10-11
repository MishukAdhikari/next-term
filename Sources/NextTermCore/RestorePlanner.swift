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
// - Claude Code, Codex and Qwen Code resume by themselves only on an update restore, or a quit restore with the quit
//   consent (R30), still running from a line that passed its checks, with an exact id from their own session file and
//   the gate passing (KTD5), and only in the tab selected last of those that held the session (R5), carrying the
//   permission options the typed line confirmed, which their note names; every other agent's resume command (the
//   user's launch with the resume form, KTD7) goes on the line, unrun (R6), in the folder its session ran in;
// - a command still running goes back on the line, unrun, when it was typed whole in the system /bin/zsh (R9);
//   any other gets a note;
// - an idle tab gets its folder back, and a note with its last command.
// A crash restore never resumes, and neither does safe mode, whatever restore it holds back (R21). In safe mode the plan
// is what Try Again would apply; until then each local tab only says what it held, and its list line says it waits for
// Try Again. Nothing here runs or types anything.

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

    /// The agent and id, whatever the id's case: an id typed in capitals names the same session.
    var identity: String { agent.rawValue + ":" + id.lowercased() }
}

/// What the restore found of a folder within its time budget.
public enum FolderCheck: Sendable {
    case found
    case gone
    /// Not found in time: it may still be there.
    case notChecked
}

/// The folder a local tab opens in.
public struct FolderChoice: Equatable, Sendable {
    public var path: String
    /// The folder it had, when that was gone or could not be checked in time: `path` is the nearest one left.
    public var movedFrom: String?
    /// `movedFrom` could not be checked in time, so it may still be there.
    public var notChecked: Bool

    public init(path: String, movedFrom: String? = nil, notChecked: Bool = false) {
        self.path = path
        self.movedFrom = movedFrom
        self.notChecked = notChecked
    }
}

/// Where a guessed session comes from (the plan's agent matrix): Claude Code, Codex and Command Code from their own
/// readers, Gemini CLI, Cursor Agent and opencode from `AgentSessions.newest`.
public struct SessionLookup {
    /// An agent's own reader: the sessions it recorded in exactly `folder`, files last written before the date skipped.
    public var read: (AgentKind, String, Date) -> [AgentSession]
    /// `AgentSessions.newest`: the newest session started in `folder` at or after the date, ids in the set left out.
    public var newest: (AgentKind, String, Date, Set<String>) -> AgentSession?
    /// A folder as the stores name it: two tabs whose folders read the same share one folder's sessions.
    public var canonical: (String) -> String

    /// Without `canonical`, folders are compared as their text reads, `.` and `..` worked out.
    public init(read: @escaping (AgentKind, String, Date) -> [AgentSession],
                newest: @escaping (AgentKind, String, Date, Set<String>) -> AgentSession?,
                canonical: @escaping (String) -> String = { (path: String) -> String in RestorePlanner.lexical(path) ?? path }) {
        self.read = read
        self.newest = newest
        self.canonical = canonical
    }

    /// Whether `evidence`'s session may be resumed now (KTD5's session check, read when the action runs): Claude Code,
    /// Codex or Qwen Code, with its id, in the store this Mac's home keeps for that agent (a session read in a store moved
    /// by CLAUDE_CONFIG_DIR or CODEX_HOME is not looked for), found by that agent's reader in the folder the session
    /// recorded, and no live process holding it as far as the reader can tell. Anything less is false.
    public func available(_ evidence: SessionSnapshot.Evidence, home: String) -> Bool {
        let agent = evidence.agent
        guard agent.resumesAutomatically, let kind = agent.kind, let id = evidence.sessionID, let folder = evidence.sessionFolder,
              let store = evidence.store, store == AgentEvidence.store(of: agent, environment: [:], home: home) else { return false }
        let wanted = id.lowercased()
        return read(kind, folder, .distantPast).contains { (session: AgentSession) -> Bool in
            session.id.lowercased() == wanted && !session.isRunning
        }
    }

    /// The same lookup, with the sessions in `freed` (by lowercased id) read as no live process holding them: how the
    /// update sheet plans before the quit, which stops their only holders (`freedAtQuit`), so that its session check and
    /// its guesses read what the relaunch will (R14, KTD5). The restore itself frees none.
    public func freeing(_ freed: Set<String>) -> SessionLookup {
        guard !freed.isEmpty else { return self }
        let read = self.read
        var lookup = self
        lookup.read = { (agent: AgentKind, folder: String, since: Date) -> [AgentSession] in
            read(agent, folder, since).map { (session: AgentSession) -> AgentSession in
                guard session.isRunning, freed.contains(session.id.lowercased()) else { return session }
                return AgentSession(agent: session.agent, id: session.id, cwd: session.cwd, title: session.title,
                                    named: session.named, createdAt: session.createdAt, updatedAt: session.updatedAt,
                                    gitBranch: session.gitBranch, model: session.model, isRunning: false)
            }
        }
        return lookup
    }

    /// The sessions, by lowercased id, whose every live holder is a process the update quit stops (`stops`: one in a
    /// local tab of this Next Term), such as the tab's own agent, read by the sheet before the quit (R14). A session any
    /// other process also holds is not among them.
    public static func freedAtQuit(holders: [String: Set<Int32>], stops: (Int32) -> Bool) -> Set<String> {
        var held: [String: Bool] = [:]
        for (id, pids) in holders where !pids.isEmpty {
            let key = id.lowercased()
            held[key] = (held[key] ?? true) && pids.allSatisfy(stops)
        }
        return Set(held.filter { (entry: (key: String, value: Bool)) -> Bool in entry.value }.keys)
    }

    /// The stores in `home`.
    public static func live(home: String = NSHomeDirectory()) -> SessionLookup {
        SessionLookup(read: { (agent: AgentKind, folder: String, since: Date) -> [AgentSession] in
            (try? agent.provider(home: home).sessions(in: canonicalPath(folder), subfolders: false, since: since)) ?? []
        }, newest: { (agent: AgentKind, folder: String, after: Date, excluding: Set<String>) -> AgentSession? in
            AgentSessions.newest(agent: agent, in: folder, after: after, excluding: excluding, home: home)
        }, canonical: canonicalPath)
    }
}

/// What the restore did to one pane, and the words for it.
public struct PanePlan: Equatable, Sendable {
    /// The pane's tab id.
    public var pane: UUID
    public var outcome: RestoreOutcome
    /// Why it was restored: an update, a quit, a crash, or safe mode, where nothing is applied until Try Again.
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
        /// What the restore found of a folder within its time budget.
        public var checkFolder: (String) -> FolderCheck
        /// The gate's facts for an agent's evidence, in a tab whose folder was the one given, with every project the
        /// snapshot opens (ResumeFacts.read).
        public var resumeFacts: (SessionSnapshot.Evidence, String?, [String]) -> ResumeFacts
        public var sessions: SessionLookup
        /// The names the user gave hosts, by host id.
        public var hostNames: [String: String]

        public init(home: String = NSHomeDirectory(), checkFolder: @escaping (String) -> FolderCheck = World.check,
                    resumeFacts: @escaping (SessionSnapshot.Evidence, String?, [String]) -> ResumeFacts, sessions: SessionLookup? = nil,
                    hostNames: [String: String] = [:]) {
            self.home = home
            self.checkFolder = checkFolder
            self.resumeFacts = resumeFacts
            self.sessions = sessions ?? .live(home: home)
            self.hostNames = hostNames
        }

        /// A folder is found when it is a directory now. The time budget is the caller's to set.
        public static func check(_ path: String) -> FolderCheck {
            var isDirectory: ObjCBool = false
            let found = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            return found ? .found : .gone
        }
    }

    /// Everything one pane's plan depends on. Only the planner makes one, so a verdict always comes from the gate.
    struct PaneInput: Sendable {
        var pane: SessionSnapshot.Pane
        /// An update, quit or crash restore. Anything else plans as a crash: nothing resumes.
        var kind: SessionSnapshot.RestoreKind
        var safeMode: Bool
        /// A quit restore whose quit consent id was unused (R30): agents may resume by themselves, as on an update.
        var quitConsent = false
        /// Where a local tab opens.
        var folder: FolderChoice?
        /// The session its agent names, or the one guessed for it.
        var session: NamedSession?
        /// The folder its agent's session ran in, when that is still there: an agent's line finds its session only there.
        var sessionFolder: String?
        /// The gate's verdict, for an agent that may resume by itself.
        var verdict: ResumeVerdict?
        /// Another pane that holds the same session was selected later: only that one may resume it (R5).
        var selectedEarlier: Bool
        /// That pane resumes it.
        var sharedSession: Bool
        /// A remote tab's host, by name.
        var host: String?

        init(pane: SessionSnapshot.Pane, kind: SessionSnapshot.RestoreKind, safeMode: Bool = false, folder: FolderChoice? = nil,
             session: NamedSession? = nil, sessionFolder: String? = nil, verdict: ResumeVerdict? = nil, selectedEarlier: Bool = false,
             sharedSession: Bool = false, host: String? = nil) {
            self.pane = pane
            self.kind = kind
            self.safeMode = safeMode
            self.folder = folder
            self.session = session
            self.sessionFolder = sessionFolder
            self.verdict = verdict
            self.selectedEarlier = selectedEarlier
            self.sharedSession = sharedSession
            self.host = host
        }
    }

    /// Every pane of `snapshot`, in reading order. Sessions are named first, so no two panes guess the same one, and of
    /// the panes that hold one session only the one selected last may resume it. `quitConsent` counts on a quit restore
    /// only: the launch found the quit's consent id unused.
    public static func plan(_ snapshot: SessionSnapshot, kind: SessionSnapshot.RestoreKind, safeMode: Bool = false,
                            quitConsent: Bool = false, world: World) -> [PanePlan] {
        var panes: [SessionSnapshot.Pane] = []
        var projects: [String?] = []
        for window in snapshot.windows {
            for pane in window.groups.flatMap(\.panes) {
                panes.append(pane)
                projects.append(window.project)
            }
        }
        let opened: [String] = snapshot.windows.compactMap(\.project)
        let sessions = namedSessions(panes, lookup: world.sessions)
        var inputs: [PaneInput] = []
        for (index, pane) in panes.enumerated() {
            let place = Place(project: projects[index], projects: opened)
            let consent = kind == .quit && quitConsent
            inputs.append(input(for: pane, place: place, session: sessions[index], kind: kind, safeMode: safeMode, consent: consent,
                                world: world))
        }
        var plans: [PanePlan] = inputs.map { (input: PaneInput) -> PanePlan in plan(input) }
        for (index, last) in selectedEarlier(sessions, panes: panes) {
            inputs[index].selectedEarlier = true
            // Safe mode resumes nothing, and its note says another tab held the session too.
            inputs[index].sharedSession = plans[last].outcome == .resume || safeMode
            plans[index] = plan(inputs[index])
        }
        return plans
    }

    /// One pane's plan, from everything it depends on.
    static func plan(_ input: PaneInput) -> PanePlan {
        let pane = input.pane
        let decision = decide(input)
        let folder = decision.folder ?? input.folder?.path
        var note = RestoreNote(outcome: decision.outcome)
        if pane.remote == nil { note.agent = pane.agent?.agent }
        note.line = decision.noteLine
        note.session = decision.session
        note.leftOff = decision.noteLine == nil ? [] : decision.leftOff
        note.permissions = decision.permissions
        note.interrupted = pane.interrupted
        note.afterQuit = input.kind == .quit
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
            note.openedIn = folder
            note.folderNotChecked = input.folder?.notChecked ?? false
        }
        note.reminted = pane.reminted
        note.safeMode = input.safeMode && pane.remote == nil
        let reason: SessionSnapshot.RestoreKind = input.safeMode ? .safeMode : input.kind
        return PanePlan(pane: pane.id, outcome: decision.outcome, reason: reason, line: decision.line, folder: folder,
                        session: decision.session, note: note, listLine: note.listLine)
    }

    /// The folder a local tab opens in: its own; when that is gone or was not found in time, the nearest folder above it
    /// inside the project, then the project, then home. `.` and `..` are worked out first, so the walk up never leaves
    /// the project, and only a folder found in time is opened.
    public static func folder(for recorded: String?, project: String?, home: String, check: (String) -> FolderCheck) -> FolderChoice {
        func found(_ path: String) -> Bool { check(path) == .found }
        let project = project.flatMap(lexical)
        guard let recorded else {
            guard let project, found(project) else { return FolderChoice(path: home) }
            return FolderChoice(path: project)
        }
        // A folder that is not absolute names nowhere: the tab opens as if its own were gone.
        let path = lexical(recorded)
        let state: FolderCheck = path.map(check) ?? .gone
        if let path, state == .found { return FolderChoice(path: path) }
        var candidates: [String] = []
        if let project {
            let inside = project.hasSuffix("/") ? project : project + "/"
            var current = ((path ?? "") as NSString).deletingLastPathComponent
            while current.hasPrefix(inside) {
                candidates.append(current)
                current = (current as NSString).deletingLastPathComponent
            }
            candidates.append(project)
        }
        let opened = candidates.first(where: found) ?? home
        return FolderChoice(path: opened, movedFrom: path ?? recorded, notChecked: state == .notChecked)
    }

    /// `path` with `.`, `..` and repeated slashes worked out from its text alone, or nil when it is not absolute.
    public static func lexical(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." {
                _ = parts.popLast()
            } else {
                parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
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
        /// Where an agent's resume or line runs: its session's folder.
        var folder: String?
        /// The options an agent's line leaves off, by name: the table can't tell their value from a prompt word.
        var leftOff: [String] = []
        /// The permission options an automatic resume carries, or that Aider's note names, each as its words.
        var permissions: [String] = []
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
        // The user's launch with the resume form (KTD7): the launcher replayed, or the program and argv's options.
        guard let putBack = evidence.putBack(id: input.session?.id, folder: evidence.sessionFolder) else {
            // Aider's note names the permission options it ran with (R7): argv's, or the typed line's without them.
            let cli = evidence.agent.cli
            let named = (evidence.options ?? evidence.confirmed)
                .filter { cli.options[$0.name]?.kind == .permission }
                .map { $0.words.joined(separator: " ") }
            return Decision(outcome: .agentHint, permissions: named)
        }
        let line = putBack.line
        // The note names the session the line names, and none when the line has no id.
        let session = putBack.namesSession ? input.session : nil
        // Most agents find a session by the folder they run in, so the line waits in the session's own.
        guard integrated else {
            return Decision(outcome: .agentNote, noteLine: line, session: session, folder: input.sessionFolder, leftOff: putBack.leftOff)
        }
        if let command = resumeCommand(input, evidence: evidence, session: session) {
            // Its note names each permission option it carries, so a bypass is never silent (R5).
            let permissions = evidence.launch.permissions.map { (words: [String]) -> String in words.joined(separator: " ") }
            return Decision(outcome: .resume, line: command, noteLine: line, session: session, folder: evidence.sessionFolder,
                            leftOff: putBack.leftOff, permissions: permissions)
        }
        return Decision(outcome: .agentOnTheLine, line: line, noteLine: line, session: session, folder: input.sessionFolder,
                        leftOff: putBack.leftOff)
    }

    /// The command an automatic resume runs, when it may run: an update restore or a consented quit restore, the gate
    /// passed, the pane selected last of those on its session, in its own folder, with the exact id its evidence holds.
    /// Only the command the gate builds from this pane's own evidence runs.
    private static func resumeCommand(_ input: PaneInput, evidence: SessionSnapshot.Evidence, session: NamedSession?) -> String? {
        guard case .resume(let command)? = input.verdict, mayResume(input.kind, consent: input.quitConsent, safeMode: input.safeMode),
              !input.selectedEarlier else {
            return nil
        }
        guard input.folder?.movedFrom == nil, let session, session.naming == .exact, session.id == evidence.sessionID else { return nil }
        return command == evidence.resumeCommand ? command : nil
    }

    /// Where a pane is: its window's project, and every project the snapshot opens.
    private struct Place {
        var project: String?
        var projects: [String]
    }

    /// Agents may resume by themselves after an update the user agreed to, or a quit the user let go ahead with the box
    /// checked (R5, R30). Never after a crash, and never in safe mode, whatever restore it holds back: the launch that
    /// claimed the marker or found the consent id unused used that consent, so Try Again puts each agent's resume command
    /// on the line, unrun (R21, KTD2, KTD13).
    static func mayResume(_ kind: SessionSnapshot.RestoreKind, consent: Bool, safeMode: Bool) -> Bool {
        guard !safeMode else { return false }
        return kind == .update || (kind == .quit && consent)
    }

    private static func input(for pane: SessionSnapshot.Pane, place: Place, session: NamedSession?, kind: SessionSnapshot.RestoreKind,
                              safeMode: Bool, consent: Bool, world: World) -> PaneInput {
        var input = PaneInput(pane: pane, kind: kind, safeMode: safeMode)
        input.quitConsent = consent
        if let remote = pane.remote {
            input.host = world.hostNames[remote.hostID] ?? remote.destination ?? "the server"
            return input
        }
        input.folder = folder(for: pane.folder, project: place.project, home: world.home, check: world.checkFolder)
        input.session = session
        if let recorded = pane.agent?.sessionFolder, let sessionFolder = lexical(recorded), world.checkFolder(sessionFolder) == .found {
            input.sessionFolder = sessionFolder
        }
        input.verdict = verdict(for: pane, kind: kind, consent: consent, safeMode: safeMode, projects: place.projects, world: world)
        return input
    }

    /// The gate's verdict, asked only where a resume could follow: an update restore or a consented quit restore, an
    /// agent that resumes by itself with an exact id from its own session file, still running from a line typed in a shell
    /// with the integration that passed every check. A fact not known asks nothing.
    private static func verdict(for pane: SessionSnapshot.Pane, kind: SessionSnapshot.RestoreKind, consent: Bool, safeMode: Bool,
                                projects: [String], world: World) -> ResumeVerdict? {
        guard mayResume(kind, consent: consent, safeMode: safeMode), let command = pane.command, command.check == .kept,
              command.line != nil else {
            return nil
        }
        guard command.running, command.source == .integration else { return nil }
        guard let evidence = pane.agent, evidence.isExact, let source = evidence.agent.fileSource, evidence.source == source else { return nil }
        var facts = world.resumeFacts(evidence, pane.folder, projects)
        // Whatever the facts say, what runs stays out of every project, the tab's folder and the session's (KTD5).
        let folders: [String] = projects + [pane.folder, evidence.sessionFolder].compactMap { $0 }
        for folder in folders where !facts.outside.contains(folder) {
            facts.outside.append(folder)
        }
        return evidence.gate(facts)
    }

    /// The panes, by index, that hold a session another pane holds too and was selected after them, each with that
    /// pane's index: of the panes that hold one session, only the one selected last may resume it (the first of them on
    /// a tie), and every other keeps its line (R5).
    private static func selectedEarlier(_ sessions: [Int: NamedSession], panes: [SessionSnapshot.Pane]) -> [(index: Int, last: Int)] {
        let held: [Int] = sessions.keys.sorted()
        var last: [String: Int] = [:]
        for index in held {
            guard let key = sessions[index]?.identity else { continue }
            if let other = last[key], panes[other].lastSelected >= panes[index].lastSelected { continue }
            last[key] = index
        }
        return held.compactMap { (index: Int) -> (index: Int, last: Int)? in
            guard let key = sessions[index]?.identity, let winner = last[key], winner != index else { return nil }
            return (index, winner)
        }
    }

    // MARK: sessions

    /// A local pane's agent, as it bears on naming sessions.
    private struct Holder {
        var index: Int
        var agent: RestoreAgent
        /// The folder its sessions are looked up in, and that folder as the stores name it.
        var folder: String?
        var place: String?
        /// When its agent started. Not known, it could have started any session.
        var start: Date?
        /// It names no session of its own, so one may be guessed for it.
        var guesses: Bool
    }

    /// The session each local agent pane holds, by index: its own id when it has one in its agent's pattern, else the
    /// newest session its agent started in its folder since it started. A pane whose line held a secret names none, but
    /// the session it holds is still its own. Ids match whatever their case.
    ///
    /// Time alone cannot tell two panes of one agent in one folder apart, so a session goes to a pane only when no other
    /// such pane still unnamed could have started it: better no pane than the wrong one. Panes guess earliest start
    /// first, so once one has its session, the next can take the one after.
    static func namedSessions(_ panes: [SessionSnapshot.Pane], lookup: SessionLookup) -> [Int: NamedSession] {
        var named: [Int: NamedSession] = [:]
        var taken: [RestoreAgent: Set<String>] = [:]
        var holders: [Holder] = []
        for (index, pane) in panes.enumerated() {
            guard pane.remote == nil, let evidence = pane.agent, evidence.agent.hasResumeForm else { continue }
            let folder = evidence.sessionFolder ?? pane.folder
            let holder = Holder(index: index, agent: evidence.agent, folder: folder, place: folder.map(lookup.canonical),
                                start: evidence.startedAt, guesses: evidence.sessionID == nil)
            holders.append(holder)
            // An id outside its pattern names nothing: the line is the program alone, and nothing is guessed in its place.
            guard let id = evidence.sessionID, evidence.agent.isSessionID(id) else { continue }
            let naming: SessionNaming = evidence.isExact ? .exact : .unconfirmed
            named[index] = NamedSession(agent: evidence.agent, id: id, naming: naming, date: evidence.sessionDate)
            taken[evidence.agent, default: []].insert(id.lowercased())
        }
        let unnamed = holders.filter { (holder: Holder) -> Bool in holder.guesses && holder.start != nil }
        let waiting = unnamed.sorted { (a: Holder, b: Holder) -> Bool in
            let first: Date = a.start ?? .distantPast
            let second: Date = b.start ?? .distantPast
            return first != second ? first < second : a.index < b.index
        }
        for holder in waiting {
            guard let start = holder.start, let folder = holder.folder else { continue }
            let rivals = holders.filter { (other: Holder) -> Bool in
                other.index != holder.index && named[other.index] == nil && other.agent == holder.agent && other.place == holder.place
            }
            let before: Date? = rivals.map { (other: Holder) -> Date in other.start ?? .distantPast }.min()
            let excluding = taken[holder.agent] ?? []
            let found = guess(holder.agent, in: folder, after: start, before: before, excluding: excluding, lookup: lookup)
            guard let found else { continue }
            named[holder.index] = found
            taken[holder.agent, default: []].insert(found.id.lowercased())
        }
        return named
    }

    /// The newest session `agent` started in `folder` at or after `start`, and before `limit` when there is one, not in
    /// `taken` whatever its case, from that agent's reader (the plan's matrix): Claude Code, Codex and Command Code from
    /// their own, which also skip a session a live process has open; Gemini CLI, Cursor Agent and opencode from
    /// `AgentSessions.newest`. Nil for every other agent: Qwen Code, Copilot CLI, Amp and Junie have no reader for a
    /// guess, and Kiro CLI and Goose have no store the session list reads (no AgentKind), so `newest` has none to read.
    static func guess(_ agent: RestoreAgent, in folder: String, after start: Date, before limit: Date? = nil, excluding taken: Set<String>,
                      lookup: SessionLookup) -> NamedSession? {
        if let limit, limit <= start { return nil }
        let taken = Set(taken.map { (id: String) -> String in id.lowercased() })
        func fits(_ session: AgentSession) -> Bool {
            let started = startTime(session)
            guard started >= start, !taken.contains(session.id.lowercased()), agent.isSessionID(session.id) else { return false }
            return limit.map { (limit: Date) -> Bool in started < limit } ?? true
        }
        let found: AgentSession?
        switch agent {
        case .claude, .codex, .commandCode:
            guard let kind = agent.kind else { return nil }
            let fresh = lookup.read(kind, folder, start).filter { (session: AgentSession) -> Bool in !session.isRunning && fits(session) }
            found = fresh.max { (a: AgentSession, b: AgentSession) -> Bool in startTime(a) < startTime(b) }
        case .gemini, .cursor, .opencode:
            guard let kind = agent.kind else { return nil }
            found = newest(kind, in: folder, after: start, excluding: taken, fits: fits, lookup: lookup)
        case .qwen, .copilot, .amp, .junie, .kiro, .goose, .agy, .aider, .unknown:
            return nil
        }
        guard let found else { return nil }
        return NamedSession(agent: agent, id: found.id, naming: .newest, date: found.updatedAt)
    }

    /// `AgentSessions.newest`, asked again with each session it gave that does not fit left out, a few times at most.
    private static func newest(_ kind: AgentKind, in folder: String, after start: Date, excluding taken: Set<String>,
                               fits: (AgentSession) -> Bool, lookup: SessionLookup) -> AgentSession? {
        var excluding = taken
        for _ in 0..<8 {
            guard let found = lookup.newest(kind, folder, start, excluding) else { return nil }
            if fits(found) { return found }
            excluding.insert(found.id)
        }
        return nil
    }

    private static func startTime(_ session: AgentSession) -> Date { session.createdAt ?? session.updatedAt }
}

// MARK: - Pending actions

extension SessionSnapshot.Action {
    /// It types into the tab's shell once it is ready: an automatic resume, or a line put back.
    public var types: Bool { self == .resume || self == .onTheLine || self == .typeIn }
}

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
    /// An agent's put-back line: the user's launch with the resume form and the id, or without them when no id is
    /// known. Never the command a resume runs.
    public var line: String?
    /// The session the line names.
    public var session: NamedSession?
    /// The options the line leaves off, by name only: the table can't tell their value from a prompt word.
    public var leftOff: [String] = []
    /// The permission options an automatic resume carried, or that Aider's note names, each as its words: named, so a
    /// bypass is never silent (R5, R7).
    public var permissions: [String] = []
    /// The restart cut the agent's turn off.
    public var interrupted = false
    /// The restart was a quit under "Resume where I left off", not an update.
    public var afterQuit = false
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
    /// The folder it had was not found in time, so it is not said to be gone.
    public var folderNotChecked = false
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
        render(dates: dates, when: .done)
    }

    /// The note as its tab shows it, before the shell starts. An action that types (a resume, a line put back) waits for
    /// the shell to be ready, and the user typing first drops it, so its note says what happens then, unless the user
    /// types first; `text` says what happened. Every other note, and safe mode's, reads the same either way.
    public func shownBeforeShell(dates: (Date) -> String = RestoreNote.dateText) -> String? {
        render(dates: dates, when: .waiting)
    }

    /// The note once an action that types was cancelled: something reached the tab's line before its shell was ready
    /// (`RestoreLayout.LineWatch`), so the restore typed nothing there. No agent resumed and no line waits on the prompt;
    /// it says how to resume the agent, or which command was not put back. Every other note, and safe mode's, which
    /// already says nothing ran, reads as `text`.
    public func cancelledText(dates: (Date) -> String = RestoreNote.dateText) -> String? {
        render(dates: dates, when: .cancelled)
    }

    /// What an automatic resume's tab says when, as its turn came, a process had its session open (KTD5): it did not
    /// resume, and its resume command is on the line instead, unrun. Nil for any other outcome.
    public var sessionTakenText: String? {
        guard outcome == .resume, !safeMode, let line else { return nil }
        let name = agent?.name ?? "An agent"
        let why = "\(name) session \(session?.id ?? "") did not resume, because another process has it open."
        return TerminalText.oneLine(why + " \(line) is on the line, not run.")
    }

    /// What MCP says of an automatic resume that ended within its start watch with nothing to fall back from
    /// (`StartWatch.Verdict.leftAsIs`: status 0, Ctrl-C, a key pressed first, or its shell gone): no agent runs in the tab.
    /// Nil for any other outcome.
    public var endedText: String? {
        guard outcome == .resume, !safeMode else { return nil }
        let name = agent?.name ?? "an agent"
        let seconds = Int(StartWatch.window)
        return TerminalText.oneLine("The resume of \(name) session \(session?.id ?? "") ended within \(seconds) seconds, "
            + "so no agent runs in this tab now.")
    }

    /// When an action that types happens: once the shell is ready, unless the user types first.
    static let onceReady = "once the shell is ready, unless you type first"
    /// Why an action that types was cancelled.
    static let typedFirst = "something was typed in the tab before its shell was ready"

    /// Where the note's action stands as it is told: it has happened, it waits for the shell, or it was cancelled.
    private enum Moment {
        case done, waiting, cancelled
    }

    private func render(dates: (Date) -> String, when: Moment) -> String? {
        var parts: [String] = []
        if reminted { parts.append("This tab has a new id, because another tab had the same one.") }
        if let movedFrom, let openedIn {
            let why = folderNotChecked ? "could not be checked in time" : "is gone"
            parts.append("\(movedFrom) \(why), so this tab opened in \(openedIn).")
        }
        let main = sentences(dates: dates, when: when)
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

    /// What the outcome says. In safe mode, an action that did not happen is told as what the tab held. `waiting`: an
    /// action that types has not happened yet, and says what happens once the shell is ready; `cancelled`: it never will.
    private func sentences(dates: (Date) -> String, when: Moment) -> [String] {
        let name = agent?.name ?? "An agent"
        let waiting = when == .waiting
        let back = waiting ? "goes back on the line, not run, \(Self.onceReady)." : "is back on the line, not run."
        switch outcome {
        case .resume where !safeMode && when == .cancelled:
            var said = ["\(name) session \(session?.id ?? "") did not resume: \(Self.typedFirst)."]
            if interrupted { said.append("Its last turn was cut off by \(afterQuit ? "the quit" : "the update").") }
            if let session { said += about(session, dates) }
            said += leftOffText
            said.append("To resume it, type: \(line ?? agent?.program ?? "")")
            return said
        case .agentOnTheLine where !safeMode && when == .cancelled:
            var said = typeToResume(dates)
            said.insert("Its line was not put back: \(Self.typedFirst).", at: 1)
            return said
        case .commandOnTheLine where !safeMode && when == .cancelled:
            return ["\(command ?? "A command") was running. It was not put back: \(Self.typedFirst)."]
        case .resume where !safeMode:
            let id = session?.id ?? ""
            let with = permissions.isEmpty ? "" : " with " + permissions.joined(separator: ", ")
            var said = [waiting ? "\(name) session \(id) resumes\(with) \(Self.onceReady)." : "Resumed \(name) session \(id)\(with)."]
            if interrupted {
                let by = afterQuit ? "the quit" : "the update"
                said.append("Its last turn was cut off by \(by) and \(waiting ? "does not continue" : "did not continue").")
            }
            if let session { said += about(session, dates) }
            return said
        case .agentOnTheLine where !safeMode:
            let line = self.line ?? ""
            guard let session else {
                var said = ["\(line) \(back) No \(name) session could be named, so Return starts a new one."]
                said += leftOffText
                return said
            }
            var said = ["\(line) \(back) Press Return to resume \(name) session \(session.id), or edit it first."]
            said += about(session, dates)
            said += sharedText
            said += leftOffText
            return said
        case .resume, .agentOnTheLine, .agentNote:
            return typeToResume(dates)
        case .commandOnTheLine:
            let command = self.command ?? "A command"
            if safeMode { return ["\(command) was running."] }
            return ["\(command) \(back) Press Return to run it, or edit it first."]
        case .agentHint:
            switch agent {
            case .agy?: return ["agy was running. Type /resume in agy to reopen the conversation."]
            case .aider?:
                let with = permissions.isEmpty ? "" : " " + permissions.joined(separator: " ")
                return ["Aider was running. Start it with --restore-chat-history\(with) to reload the chat."]
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

    /// Another tab resumes the session. In safe mode nothing has resumed yet, so it only held it.
    private var sharedText: [String] {
        guard sharedSession else { return [] }
        return [safeMode ? "Another tab held this session too." : "Another tab resumed this session."]
    }

    /// The options a line leaves off, and why: only ones whose value the table can't tell from a prompt word (KTD7).
    private var leftOffText: [String] {
        guard !leftOff.isEmpty else { return [] }
        let values = leftOff.count == 1 ? "its value" : "their values"
        return ["Left off: \(leftOff.joined(separator: ", ")) (Next Term can't tell \(values) from a prompt)."]
    }

    private var lastCommand: String? {
        guard let command else { return nil }
        guard let exitCode else { return "Last command: \(command)." }
        return "Last command: \(command) (exit \(exitCode))."
    }

    /// The keep-sessions sheet's words for the outcome. The sheet puts the tab's title or folder before them. In safe
    /// mode nothing ran, so what would type or run says it waits for Try Again.
    public var listLine: String {
        let name = agent.flatMap { $0 == .unknown ? nil : $0.name } ?? "the agent"
        let words: String
        switch outcome {
        case .resume:
            words = "\(name) resumes"
        case .agentOnTheLine where session == nil:
            words = "\(line ?? name) goes on the line, with no session named"
        case .agentOnTheLine:
            words = "\(name)'s resume command goes on the line" + (sharedSession && !safeMode ? ", as another tab resumes this session" : "")
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
        let waits = safeMode && outcome.action != .note
        return TerminalText.oneLine(waits ? "on Try Again, " + words : words)
    }
}
