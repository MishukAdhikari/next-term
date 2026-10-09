import Foundation
import Testing
@testable import NextTermCore

/// The restore planner: each pane's outcome, its line and its note, the sessions guessed for agents that named none,
/// and the pending-action machine. Every store and fact here is made up; nothing on this Mac is read, except a
/// Claude store made by hand in a temporary folder.
@Suite struct RestorePlannerTests {
    typealias Pane = SessionSnapshot.Pane
    typealias Evidence = SessionSnapshot.Evidence
    typealias Command = SessionSnapshot.Command
    typealias PendingAction = SessionSnapshot.PendingAction

    static let s = "5e4d3c2b-1a09-4f8e-9d7c-6b5a4f3e2d1c"
    static let g = "0a1b2c3d-0000-4000-8000-00000000000a"
    static let g2 = "0a1b2c3d-0000-4000-8000-00000000000b"
    static let old = "0a1b2c3d-0000-4000-8000-00000000000c"
    var s: String { Self.s }
    var g: String { Self.g }
    var g2: String { Self.g2 }

    let folder = "/Users/x/app"
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    /// Dates as seconds after `start`, so a note shows which date it was given.
    func text(_ plan: PanePlan) -> String {
        let start = self.start
        return plan.note.text { (date: Date) -> String in "T+\(Int(date.timeIntervalSince(start)))" } ?? ""
    }

    /// Each plan's line, "" for none, and each plan's outcome: typed, so comparisons stay cheap to type-check.
    func lines(_ plans: [PanePlan]) -> [String] { plans.map { (plan: PanePlan) -> String in plan.line ?? "" } }

    func outcomes(_ plans: [PanePlan]) -> [RestoreOutcome] { plans.map { (plan: PanePlan) -> RestoreOutcome in plan.outcome } }

    /// The plans' lines, checked in one place: comparing arrays inside `#expect` is slow to type-check.
    func expectLines(_ plans: [PanePlan], _ expected: String..., sourceLocation: SourceLocation = #_sourceLocation) {
        let found: [String] = lines(plans)
        let same: Bool = found == expected
        #expect(same, "lines \(found)", sourceLocation: sourceLocation)
    }

    /// The plans' outcomes, checked in one place, for the same reason.
    func expectOutcomes(_ plans: [PanePlan], _ expected: RestoreOutcome..., sourceLocation: SourceLocation = #_sourceLocation) {
        let found: [RestoreOutcome] = outcomes(plans)
        let same: Bool = found == expected
        #expect(same, "outcomes \(found)", sourceLocation: sourceLocation)
    }

    // MARK: fixtures

    /// The lookups a plan made, and the sessions they find.
    final class Lookups {
        var sessions: [AgentSession] = []
        var reads: [AgentKind] = []
        var newests: [AgentKind] = []

        var lookup: SessionLookup {
            SessionLookup(read: { (agent: AgentKind, folder: String, since: Date) -> [AgentSession] in
                self.reads.append(agent)
                return self.sessions.filter { (session: AgentSession) -> Bool in session.agent == agent && session.cwd == folder }
            }, newest: { (agent: AgentKind, folder: String, after: Date, excluding: Set<String>) -> AgentSession? in
                self.newests.append(agent)
                let found = self.sessions.filter { (session: AgentSession) -> Bool in
                    let created: Date = session.createdAt ?? .distantPast
                    return session.agent == agent && session.cwd == folder && created >= after && !excluding.contains(session.id)
                }
                return found.max { (a: AgentSession, b: AgentSession) -> Bool in
                    let first: Date = a.createdAt ?? .distantPast
                    let second: Date = b.createdAt ?? .distantPast
                    return first < second
                }
            })
        }
    }

    /// A session started `at` seconds after `start`, last written `updated` seconds after it.
    func session(_ agent: AgentKind, _ id: String, at offset: TimeInterval, updated: TimeInterval? = nil, running: Bool = false) -> AgentSession {
        let created = start.addingTimeInterval(offset)
        let written = start.addingTimeInterval(updated ?? offset + 60)
        return AgentSession(agent: agent, id: id, cwd: folder, title: "t", named: false, createdAt: created, updatedAt: written,
                            gitBranch: nil, model: nil, isRunning: running)
    }

    /// Folders in `notChecked` were not checked in time; the rest are there when `exists` says so.
    func world(facts: ResumeFacts = ResumeFacts(), lookups: Lookups = Lookups(), exists: @escaping (String) -> Bool = { _ in true },
               notChecked: Set<String> = [], hosts: [String: String] = ["h1": "web-1"]) -> RestorePlanner.World {
        let check = { (path: String) -> FolderCheck in
            if notChecked.contains(path) { return .notChecked }
            return exists(path) ? .found : .gone
        }
        let given = { (_: Evidence, _: String?, _: [String]) -> ResumeFacts in facts }
        return RestorePlanner.World(home: "/Users/x", checkFolder: check, resumeFacts: given, sessions: lookups.lookup, hostNames: hosts)
    }

    /// A line the integration reported typed in the tab, kept unless the secret detector says otherwise.
    func typed(_ line: String, running: Bool = true, source: SessionSnapshot.LineSource = .integration, exit: Int32? = nil) -> Command {
        let check: SessionSnapshot.LineCheck = CommandSecrets.mayKeep(line) ? .kept : .secret
        return Command(line: line, check: check, source: source, running: running, exitCode: exit)
    }

    func pane(_ n: Int, _ command: Command?, agent: Evidence? = nil, systemZsh: Bool = true, folder: String? = nil,
              selected: TimeInterval = 0) -> Pane {
        var pane = Pane(id: id(n), folder: folder ?? self.folder, command: command, lastSelected: start.addingTimeInterval(selected), agent: agent)
        pane.systemZsh = systemZsh
        return pane
    }

    func remote(_ n: Int, keep: KeepMode, _ command: Command?) -> Pane {
        let record = RemoteTabRecord(hostID: "h1", destination: "sam@web-1.example", directory: "~/app", session: "nt-1", keep: keep)
        return Pane(id: id(n), remote: record, command: command)
    }

    /// Claude Code with an exact id from its own session file, and facts on which every check of the gate passes.
    func exactClaude() -> (Evidence, ResumeFacts) {
        let user = geteuid()
        let link = "/Users/x/.local/bin/claude"
        var evidence = Evidence(agent: .claude, sessionID: s, source: .sessionFile, sessionFolder: folder, store: "/Users/x/.claude",
                                executable: link, startedAt: start, routingMatchesShell: true, autoContinueOff: true, ranAsTyped: true)
        evidence.flagsAllowed = true
        let binary = FileFacts(realPath: "/Users/x/.local/share/claude/2.1.280", owner: user, mode: 0o755, isRegular: true, linksFollowed: [link])
        let files: [String: FileFacts] = [
            link: binary,
            folder: FileFacts(realPath: folder, owner: user, mode: 0o755, isDirectory: true),
            "/Users/x/.claude": FileFacts(realPath: "/Users/x/.claude", owner: user, mode: 0o700, isDirectory: true),
        ]
        let facts = ResumeFacts(user: user, files: files, outside: [folder], temporaryFolders: ["/private/tmp"], sessionAvailable: true,
                                projectConfigChanged: false, settingsAutoContinue: false)
        return (evidence, facts)
    }

    func plan(_ panes: [Pane], kind: SessionSnapshot.RestoreKind = .update, safeMode: Bool = false,
              world: RestorePlanner.World) -> [PanePlan] {
        let groups: [SessionSnapshot.Group] = panes.map { SessionSnapshot.Group(root: .pane($0), focused: $0.id) }
        let header = SessionSnapshot.Header(launchID: id(900), generation: 1, clean: false, savedAt: start)
        let snapshot = SessionSnapshot(header: header, windows: [SessionSnapshot.Window(project: folder, groups: groups)])
        return RestorePlanner.plan(snapshot, kind: kind, safeMode: safeMode, world: world)
    }

    func plan(_ pane: Pane, kind: SessionSnapshot.RestoreKind = .update, safeMode: Bool = false, world: RestorePlanner.World) -> PanePlan {
        plan([pane], kind: kind, safeMode: safeMode, world: world)[0]
    }

    // MARK: agents that resume by themselves

    @Test func anExactClaudeIDWithAPassingGateResumes() {
        let (evidence, facts) = exactClaude()
        var claude = pane(1, typed("claude"), agent: evidence)
        claude.interrupted = true
        let result = plan(claude, world: world(facts: facts))
        guard case .resume(let command) = evidence.gate(facts) else {
            Issue.record("the gate did not pass")
            return
        }
        #expect(result.outcome == .resume && result.line == command)
        #expect(command.hasPrefix("/usr/bin/env -u ") && command.hasSuffix("/Users/x/.local/bin/claude --resume \(s)"))
        #expect(result.folder == folder && result.reason == .update)
        #expect(result.pending == PendingAction(action: .resume, reason: .update))
        #expect(result.session == NamedSession(agent: .claude, id: s, naming: .exact))
        #expect(text(result) == "Resumed Claude Code session \(s). Its last turn was cut off by the update and did not continue.")
        #expect(result.listLine == "Claude Code resumes")
    }

    @Test func anIDExactOnlyThroughTheTypedLineGoesOnTheLine() {
        let (base, facts) = exactClaude()
        var evidence = base
        evidence.source = .typedAndArgv
        let result = plan(pane(1, typed("claude --resume \(s)"), agent: evidence), world: world(facts: facts))
        #expect(result.outcome == .agentOnTheLine && result.line == "claude --resume \(s)")
        #expect(result.pending.action == .onTheLine)
        #expect(text(result) == "claude --resume \(s) is back on the line, not run. Press Return to resume Claude Code session \(s), or edit it first.")
        #expect(result.listLine == "Claude Code's resume command goes on the line")
    }

    @Test func aCrashRestoreNeverResumes() {
        let (evidence, facts) = exactClaude()
        let claude = pane(1, typed("claude"), agent: evidence)
        for kind in [SessionSnapshot.RestoreKind.crash, .unknown, .safeMode] {
            let result = plan(claude, kind: kind, world: world(facts: facts))
            #expect(result.outcome == .agentOnTheLine && result.line == "claude --resume \(s)", "\(kind)")
            #expect(result.pending.action == .onTheLine)
        }
        #expect(plan(claude, kind: .crash, world: world(facts: facts)).reason == .crash)
    }

    @Test func aBypassFlagPutsTheResumeOnTheLineWithoutIt() {
        let (base, facts) = exactClaude()
        var evidence = base
        evidence.leftOff = ["--dangerously-skip-permissions"]
        evidence.flagsAllowed = false
        let result = plan(pane(1, typed("claude --dangerously-skip-permissions"), agent: evidence), world: world(facts: facts))
        #expect(result.outcome == .agentOnTheLine && result.line == "claude --resume \(s)")
        let expected = "claude --resume \(s) is back on the line, not run. Press Return to resume Claude Code session \(s), or edit it first. "
            + "Left off: --dangerously-skip-permissions."
        #expect(text(result) == expected)
    }

    @Test func aWorldWritableFolderGoesOnTheLine() {
        var (evidence, facts) = exactClaude()
        facts.files[folder] = FileFacts(realPath: folder, owner: geteuid(), mode: 0o777, isDirectory: true)
        let result = plan(pane(1, typed("claude"), agent: evidence), world: world(facts: facts))
        #expect(result.outcome == .agentOnTheLine && result.line == "claude --resume \(s)")
        evidence.sessionFolder = nil
        #expect(plan(pane(1, typed("claude"), agent: evidence), world: world(facts: facts)).outcome == .agentOnTheLine)
    }

    @Test func aQwenIDThatFailsTheGateNamesItsSession() {
        let id = "7f6e5d4c-3b2a-4190-8f7e-6d5c4b3a2918"
        let evidence = Evidence(agent: .qwen, sessionID: id, source: .runtimeFile, sessionFolder: folder, startedAt: start)
        let result = plan(pane(1, typed("qwen"), agent: evidence), world: world())
        #expect(result.outcome == .agentOnTheLine && result.line == "qwen --resume \(id)")
        #expect(text(result) == "qwen --resume \(id) is back on the line, not run. Press Return to resume Qwen Code session \(id), or edit it first.")
    }

    @Test func ofTwoPanesOnOneSessionTheLaterSelectedResumes() {
        let (evidence, facts) = exactClaude()
        let older = pane(1, typed("claude"), agent: evidence, selected: 10)
        let newer = pane(2, typed("claude"), agent: evidence, selected: 20)
        let plans = plan([older, newer], world: world(facts: facts))
        expectOutcomes(plans, .agentOnTheLine, .resume)
        #expect(plans[0].line == "claude --resume \(s)")
        let expected = "claude --resume \(s) is back on the line, not run. Press Return to resume Claude Code session \(s), or edit it first. "
            + "Another tab resumed this session."
        #expect(text(plans[0]) == expected)
        #expect(plans[0].listLine == "Claude Code's resume command goes on the line, as another tab resumes this session")
        // Either way round.
        let swapped = plan([newer, older], world: world(facts: facts))
        expectOutcomes(swapped, .resume, .agentOnTheLine)
        // On a crash neither resumes, and neither note says another did.
        let crash = plan([older, newer], kind: .crash, world: world(facts: facts))
        expectOutcomes(crash, .agentOnTheLine, .agentOnTheLine)
        #expect(!text(crash[0]).contains("Another tab"))
    }

    @Test func onlyAKeptLineStillRunningLetsAnAgentResume() {
        let (evidence, facts) = exactClaude()
        let lines: [Command] = [
            Command(line: nil, check: .unknown, source: .integration, running: true),
            Command(line: "claude\nrm -rf x", check: .kept, source: .integration, running: true),
            Command(line: String(repeating: "a", count: Command.longest), check: .kept, source: .integration, running: true),
            Command(line: "claude \u{202E}x", check: .kept, source: .integration, running: true),
            Command(line: nil, check: .kept, source: .integration, running: true),
            Command(line: "claude", check: .kept, source: .integration, running: false),
        ]
        for command in lines {
            let result = plan(pane(1, command, agent: evidence), world: world(facts: facts))
            #expect(result.outcome == .agentOnTheLine && result.line == "claude --resume \(s)", "\(command.check) \(command.running)")
            #expect(!text(result).hasPrefix("Resumed"), "\(command.check) \(command.running)")
        }
    }

    @Test func aResumeRunsOnlyWhatThePanesOwnEvidenceBuilds() {
        let (evidence, facts) = exactClaude()
        let claude = pane(1, typed("claude"), agent: evidence)
        let session = NamedSession(agent: .claude, id: s, naming: .exact)
        var input = RestorePlanner.PaneInput(pane: claude, kind: .update, folder: FolderChoice(path: folder), session: session,
                                             verdict: .resume("touch /tmp/x"))
        let forged = RestorePlanner.plan(input)
        #expect(forged.outcome == .agentOnTheLine && forged.line == "claude --resume \(s)")
        input.verdict = evidence.gate(facts)
        #expect(RestorePlanner.plan(input).outcome == .resume)
    }

    @Test func theGateKeepsCodeOutOfEveryProjectTheSnapshotOpens() {
        let (evidence, base) = exactClaude()
        var facts = base
        // A world that leaves the projects out of the facts.
        facts.outside = []
        let tools = "/Users/x/.local"
        var seen: [[String]] = []
        let given = { (_: Evidence, _: String?, projects: [String]) -> ResumeFacts in
            seen.append(projects)
            return facts
        }
        let world = RestorePlanner.World(home: "/Users/x", checkFolder: { _ in .found }, resumeFacts: given, sessions: Lookups().lookup)
        let claude = pane(1, typed("claude"), agent: evidence)
        let idle = pane(2, typed("ls", running: false), folder: tools)
        let header = SessionSnapshot.Header(launchID: id(900), generation: 1, clean: false, savedAt: start)
        let windows: [SessionSnapshot.Window] = [
            SessionSnapshot.Window(project: folder, groups: [SessionSnapshot.Group(root: .pane(claude), focused: claude.id)]),
            SessionSnapshot.Window(project: tools, groups: [SessionSnapshot.Group(root: .pane(idle), focused: idle.id)]),
        ]
        let both = RestorePlanner.plan(SessionSnapshot(header: header, windows: windows), kind: .update, world: world)
        // Claude Code's real path is inside the second window's project.
        #expect(both[0].outcome == .agentOnTheLine)
        let projects: [[String]] = [[folder, tools]]
        let asked: Bool = seen == projects
        #expect(asked, "\(seen)")
        let alone = RestorePlanner.plan(SessionSnapshot(header: header, windows: [windows[0]]), kind: .update, world: world)
        #expect(alone[0].outcome == .resume)
    }

    @Test func whenTheTabSelectedLastCannotResumeNoneDoes() {
        let (evidence, facts) = exactClaude()
        var bypass = evidence
        bypass.leftOff = ["--dangerously-skip-permissions"]
        bypass.flagsAllowed = false
        let older = pane(1, typed("claude"), agent: evidence, selected: 10)
        let newer = pane(2, typed("claude --dangerously-skip-permissions"), agent: bypass, selected: 20)
        let plans = plan([older, newer], world: world(facts: facts))
        expectOutcomes(plans, .agentOnTheLine, .agentOnTheLine)
        #expect(!text(plans[0]).contains("Another tab") && !text(plans[1]).contains("Another tab"))
        #expect(plans[0].listLine == "Claude Code's resume command goes on the line")
        // An id written in capitals names the same session.
        var capitals = evidence
        capitals.sessionID = s.uppercased()
        let shouting = plan([older, pane(3, typed("claude"), agent: capitals, selected: 20)], world: world(facts: facts))
        expectOutcomes(shouting, .agentOnTheLine, .resume)
        #expect(text(shouting[0]).hasSuffix("Another tab resumed this session."))
    }

    // MARK: agents put back on the line

    @Test func aGuessedGeminiSessionGoesOnTheLineWithoutThePrompt() {
        let lookups = Lookups()
        lookups.sessions = [session(.gemini, g, at: 30, updated: 90), session(.gemini, Self.old, at: -60)]
        let gemini = pane(1, typed("gemini \"fix the login bug\""), agent: Evidence(agent: .gemini, sessionFolder: folder, startedAt: start))
        let result = plan(gemini, world: world(lookups: lookups))
        #expect(result.outcome == .agentOnTheLine && result.line == "gemini --resume \(g)")
        #expect(result.session == NamedSession(agent: .gemini, id: g, naming: .newest, date: start.addingTimeInterval(90)))
        let expected = "gemini --resume \(g) is back on the line, not run. Press Return to resume Gemini CLI session \(g), or edit it first. "
            + "This is a guess: the newest session in this folder. Last used T+90."
        #expect(text(result) == expected)
        #expect(!text(result).contains("login") && !(result.line ?? "").contains("login") && result.note.command == nil)
        #expect(lookups.newests == [.gemini] && lookups.reads.isEmpty)

        lookups.sessions = []
        let none = plan(gemini, world: world(lookups: lookups))
        #expect(none.outcome == .agentOnTheLine && none.line == "gemini" && none.session == nil)
        #expect(text(none) == "gemini is back on the line, not run. No Gemini CLI session could be named, so Return starts a new one.")
        #expect(none.listLine == "gemini goes on the line, with no session named")
    }

    @Test func twoGeminiTabsInOneFolderNameTwoSessions() {
        let lookups = Lookups()
        lookups.sessions = [session(.gemini, g, at: 5), session(.gemini, g2, at: 65)]
        let first = pane(1, typed("gemini"), agent: Evidence(agent: .gemini, sessionFolder: folder, startedAt: start))
        let second = pane(2, typed("gemini"), agent: Evidence(agent: .gemini, sessionFolder: folder, startedAt: start.addingTimeInterval(60)))
        expectLines(plan([first, second], world: world(lookups: lookups)), "gemini --resume \(g)", "gemini --resume \(g2)")
        expectLines(plan([second, first], world: world(lookups: lookups)), "gemini --resume \(g2)", "gemini --resume \(g)")
        // A session another pane names exactly is never guessed for this one.
        let exact = pane(3, typed("gemini --resume \(g2)"), agent: Evidence(agent: .gemini, sessionID: g2, source: .typedAndArgv))
        let late = pane(4, typed("gemini"), agent: Evidence(agent: .gemini, sessionFolder: folder, startedAt: start.addingTimeInterval(60)))
        expectLines(plan([late, exact], world: world(lookups: lookups)), "gemini", "gemini --resume \(g2)")
    }

    @Test func aSessionEitherTabCouldHaveStartedGoesToNeither() {
        let lookups = Lookups()
        lookups.sessions = [session(.gemini, g, at: 100)]
        let first = pane(1, typed("gemini"), agent: Evidence(agent: .gemini, sessionFolder: folder, startedAt: start))
        let second = pane(2, typed("gemini"), agent: Evidence(agent: .gemini, sessionFolder: folder, startedAt: start.addingTimeInterval(60)))
        expectLines(plan([first, second], world: world(lookups: lookups)), "gemini", "gemini")
        expectLines(plan([second, first], world: world(lookups: lookups)), "gemini", "gemini")
        // A session only the first could have started is its own; after that, the second's is its own too.
        lookups.sessions = [session(.gemini, g, at: 5), session(.gemini, g2, at: 100)]
        expectLines(plan([first, second], world: world(lookups: lookups)), "gemini --resume \(g)", "gemini --resume \(g2)")
        // A tab whose start is not known could have started any session in its folder.
        let unknownStart = pane(3, typed("gemini"), agent: Evidence(agent: .gemini, sessionFolder: folder))
        expectLines(plan([unknownStart, second], world: world(lookups: lookups)), "gemini", "gemini")
        // Another folder's tab is no rival.
        let elsewhere = pane(4, typed("gemini"), agent: Evidence(agent: .gemini, sessionFolder: "/Users/x/other", startedAt: start))
        expectLines(plan([elsewhere, second], world: world(lookups: lookups)), "gemini", "gemini --resume \(g2)")
        // The same from Claude Code's own reader.
        let claudes = Lookups()
        claudes.sessions = [session(.claude, g, at: 100)]
        let early = pane(5, typed("claude"), agent: Evidence(agent: .claude, sessionFolder: folder, startedAt: start))
        let late = pane(6, typed("claude"), agent: Evidence(agent: .claude, sessionFolder: folder, startedAt: start.addingTimeInterval(60)))
        expectLines(plan([early, late], world: world(lookups: claudes)), "claude", "claude")
    }

    @Test func aSessionAnotherTabHoldsIsNeverGuessed() {
        let lookups = Lookups()
        lookups.sessions = [session(.gemini, g, at: 100)]
        let later = pane(2, typed("gemini"), agent: Evidence(agent: .gemini, sessionFolder: folder, startedAt: start.addingTimeInterval(60)))
        // Its line held a secret, so it names nothing, but the session is still that tab's.
        let secretLine = typed("GEMINI_API_KEY=abcdefghij123456 gemini --resume \(g)")
        #expect(secretLine.check == .secret)
        let holder = Evidence(agent: .gemini, sessionID: g, source: .typedAndArgv, sessionFolder: folder, startedAt: start)
        let secret = plan([pane(1, secretLine, agent: holder), later], world: world(lookups: lookups))
        expectOutcomes(secret, .notKept, .agentOnTheLine)
        #expect(secret[1].line == "gemini")
        // An id typed in capitals is the same session.
        var capitals = holder
        capitals.sessionID = g.uppercased()
        let shouting = plan([pane(1, typed("gemini --resume \(g.uppercased())"), agent: capitals), later], world: world(lookups: lookups))
        expectLines(shouting, "gemini --resume \(g.uppercased())", "gemini")
    }

    @Test func claudeCodexAndCommandCodeGuessesComeFromTheirOwnReaders() {
        for kind in [AgentKind.claude, .codex, .commandCode] {
            let lookups = Lookups()
            let fresh = kind == .commandCode ? "cc-fresh" : g
            let running = kind == .commandCode ? "cc-running" : g2
            let before = kind == .commandCode ? "cc-old" : Self.old
            lookups.sessions = [session(kind, before, at: -60), session(kind, fresh, at: 30, updated: 400), session(kind, running, at: 40, running: true)]
            let agent = RestoreAgent(kind: kind)
            let evidence = Evidence(agent: agent, sessionFolder: folder, startedAt: start)
            let result = plan(pane(1, typed(agent.program ?? ""), agent: evidence), world: world(lookups: lookups))
            #expect(result.session == NamedSession(agent: agent, id: fresh, naming: .newest, date: start.addingTimeInterval(400)), "\(kind)")
            #expect(result.outcome == .agentOnTheLine && (result.line ?? "").contains(fresh), "\(kind)")
            #expect(text(result).contains("This is a guess: the newest session in this folder. Last used T+400."), "\(kind)")
            #expect(lookups.reads == [kind] && lookups.newests.isEmpty, "\(kind)")
        }
    }

    @Test func agentsWithNoReaderGetNoGuess() {
        for agent in [RestoreAgent.amp, .junie, .kiro, .goose, .qwen, .copilot] {
            let lookups = Lookups()
            let program = agent.program ?? ""
            let result = plan(pane(1, typed(program), agent: Evidence(agent: agent, sessionFolder: folder, startedAt: start)), world: world(lookups: lookups))
            #expect(result.outcome == .agentOnTheLine && result.line == program && result.session == nil, "\(agent)")
            #expect(text(result) == "\(program) is back on the line, not run. No \(agent.name) session could be named, so Return starts a new one.")
            #expect(lookups.reads.isEmpty && lookups.newests.isEmpty, "\(agent)")
        }
        // No start time, no guess.
        let lookups = Lookups()
        lookups.sessions = [session(.gemini, g, at: 5)]
        let unknownStart = plan(pane(1, typed("gemini"), agent: Evidence(agent: .gemini, sessionFolder: folder)), world: world(lookups: lookups))
        #expect(unknownStart.line == "gemini" && lookups.newests.isEmpty)
    }

    @Test func anExactCopilotIDFromTheTypedLineIsNamedWithNoDate() {
        let id = "c0b1a2d3-e4f5-4a6b-8c7d-9e0f1a2b3c4d"
        let evidence = Evidence(agent: .copilot, sessionID: id, source: .typedAndArgv, sessionFolder: folder, startedAt: start)
        let result = plan(pane(1, typed("copilot --resume=\(id)"), agent: evidence), world: world())
        #expect(result.outcome == .agentOnTheLine && result.line == "copilot --resume=\(id)")
        #expect(result.session == NamedSession(agent: .copilot, id: id, naming: .exact))
        #expect(text(result) == "copilot --resume=\(id) is back on the line, not run. Press Return to resume Copilot CLI session \(id), or edit it first.")
    }

    @Test func anUnconfirmedIDIsAGuessAndABadOneNamesNothing() {
        let lookups = Lookups()
        lookups.sessions = [session(.gemini, g2, at: 5)]
        let argvOnly = Evidence(agent: .gemini, sessionID: g, source: .guess, sessionFolder: folder, startedAt: start)
        let result = plan(pane(1, typed("gemini"), agent: argvOnly), world: world(lookups: lookups))
        #expect(result.line == "gemini --resume \(g)" && result.session?.naming == .unconfirmed)
        #expect(text(result).hasSuffix("or edit it first. This is a guess: nothing confirmed this session."))
        #expect(lookups.newests.isEmpty)
        var bad = argvOnly
        bad.sessionID = "not-a-uuid"
        let none = plan(pane(1, typed("gemini"), agent: bad), world: world(lookups: lookups))
        #expect(none.line == "gemini" && none.session == nil && lookups.newests.isEmpty)
    }

    @Test func agyAiderAndUnknownAgentsGetANoteOnly() {
        let cases: [(RestoreAgent, String)] = [
            (.agy, "agy was running. Type /resume in agy to reopen the conversation."),
            (.aider, "Aider was running. Start it with --restore-chat-history to reload the chat."),
            (.unknown, "An agent was running. Next Term does not know how to resume it."),
        ]
        for (agent, note) in cases {
            let result = plan(pane(1, typed(agent.program ?? "helper"), agent: Evidence(agent: agent, startedAt: start)), world: world())
            #expect(result.outcome == .agentHint && result.line == nil && result.pending.action == .note, "\(agent)")
            #expect(text(result) == note)
        }
    }

    @Test func anAgentInAShellWithoutTheIntegrationGetsANoteWithItsResumeCommand() {
        let (evidence, facts) = exactClaude()
        let bash = pane(1, typed("claude", source: .polled), agent: evidence, systemZsh: false)
        let result = plan(bash, world: world(facts: facts))
        #expect(result.outcome == .agentNote && result.line == nil && result.pending.action == .note)
        #expect(text(result) == "Claude Code was running. To resume it, type: claude --resume \(s)")
        let noLine = plan(pane(1, nil, agent: evidence, systemZsh: false), world: world(facts: facts))
        #expect(noLine.outcome == .agentNote)
        let gemini = pane(2, typed("gemini", source: .polled), agent: Evidence(agent: .gemini, startedAt: start), systemZsh: false)
        #expect(text(plan(gemini, world: world())) == "Gemini CLI was running. No Gemini CLI session could be named. To start it again, type: gemini")
    }

    // MARK: commands

    @Test func aCommandTypedInTheSystemZshGoesBackOnTheLine() {
        let dev = pane(1, typed("npm run dev"))
        for kind in [SessionSnapshot.RestoreKind.update, .crash] {
            let result = plan(dev, kind: kind, world: world())
            #expect(result.outcome == .commandOnTheLine && result.line == "npm run dev" && result.pending.action == .typeIn)
            #expect(text(result) == "npm run dev is back on the line, not run. Press Return to run it, or edit it first.")
            #expect(result.listLine == "npm run dev goes back on the line")
        }
        let brew = plan(pane(1, typed("npm run dev"), systemZsh: false), world: world())
        #expect(brew.outcome == .commandNote && brew.line == nil && brew.pending.action == .note)
        #expect(text(brew) == "npm run dev was running. It was not put back: it ran in a shell other than the Mac's own /bin/zsh.")
    }

    @Test func commandsThatCannotGoBackGetANote() {
        let polled = plan(pane(1, typed("npm run dev", source: .polled), systemZsh: false), world: world())
        #expect(polled.outcome == .commandNote)
        #expect(text(polled) == "npm run dev was running. It was not put back: the shell did not report it as typed.")
        let twoLines = Command(line: "echo a\necho b", check: .kept, source: .integration, running: true)
        let multi = plan(pane(1, twoLines), world: world())
        #expect(multi.outcome == .commandNote && text(multi) == "A command was running. It was not put back: it was more than one line.")
        let long = Command(line: String(repeating: "a", count: Command.longest), check: .kept, source: .integration, running: true)
        let tooLong = plan(pane(1, long), world: world())
        #expect(tooLong.outcome == .commandNote && text(tooLong) == "A command was running. It was not put back: it was too long.")
        let hidden = Command(line: "ls \u{202E}x", check: .kept, source: .integration, running: true)
        #expect(text(plan(pane(1, hidden), world: world())) == "A command was running. It was not put back: it held control or invisible characters.")
        #expect(multi.listLine == "its command stops, with a note")
    }

    @Test func aSecretLineIsNeverRepeated() {
        let line = "DB_PASSWORD=hunter2 npm start"
        let result = plan(pane(1, typed(line)), world: world())
        #expect(result.outcome == .notKept && result.line == nil && result.pending.action == .note)
        #expect(text(result) == "The last command was not kept, because it looked like it held a secret.")
        #expect(result.listLine == "last command not kept")
        // Even an agent with an exact id: the line that started it held the secret.
        let (evidence, facts) = exactClaude()
        let agent = plan(pane(2, typed("ANTHROPIC_API_KEY=sk-ant-abcdefghij123456 claude"), agent: evidence), world: world(facts: facts))
        #expect(agent.outcome == .notKept && agent.line == nil)
        for word in ["hunter2", "DB_PASSWORD", "npm", "sk-ant", "ANTHROPIC"] {
            #expect(!text(result).contains(word) && !result.listLine.contains(word) && !text(agent).contains(word))
        }
    }

    @Test func anIdleTabShowsItsLastCommand() {
        let result = plan(pane(1, typed("make test", running: false, exit: 2)), world: world())
        #expect(result.outcome == .idle && result.line == nil)
        #expect(result.pending.action == .note && result.folder == folder)
        #expect(text(result) == "Last command: make test (exit 2).")
        #expect(result.listLine == "opens in its folder")
        #expect(text(plan(pane(1, typed("ls", running: false)), world: world())) == "Last command: ls.")
        let nothing: PanePlan = plan(pane(1, nil), world: world())
        #expect(nothing.note.text() == nil)
    }

    // MARK: remote tabs

    @Test func remoteTabsReattachOrReconnect() {
        let kept = plan(remote(1, keep: .tmux, typed("htop")), world: world())
        #expect(kept.outcome == .reattach && kept.line == nil)
        #expect(kept.folder == nil && kept.pending.action == .reattach)
        #expect(kept.note.text() == nil && kept.listLine == "reattaches")
        let plain = plan(remote(1, keep: .off, typed("htop")), world: world())
        #expect(plain.outcome == .freshConnection && plain.pending.action == .freshConnection)
        #expect(plain.listLine == "connection closes")
        #expect(text(plain) == "New connection to web-1. Last command: htop.")
        var unknown = remote(1, keep: .tmux, nil)
        unknown.keepIsUnknown = true
        let other = plan(unknown, world: world(hosts: [:]))
        #expect(other.outcome == .freshConnection && text(other) == "New connection to sam@web-1.example.")
    }

    @Test func aRemoteTabWhoseLineHeldASecretKeepsItsOutcome() {
        let secret = typed("PGPASSWORD=x psql -h db")
        let plain = plan(remote(1, keep: .off, secret), world: world())
        #expect(plain.outcome == .freshConnection)
        #expect(text(plain) == "New connection to web-1. The last command was not kept, because it looked like it held a secret.")
        let kept = plan(remote(1, keep: .herdr, secret), world: world())
        #expect(kept.outcome == .reattach && text(kept) == "The last command was not kept, because it looked like it held a secret.")
        #expect(!text(plain).contains("psql") && !text(plain).contains("PGPASSWORD"))
    }

    // MARK: folders

    @Test func aMissingFolderFallsBackToTheNearestOneLeft() {
        let home = "/Users/x"
        let present: Set<String> = [folder, folder + "/src", home]
        func choose(_ recorded: String?, _ exists: Set<String> = present) -> FolderChoice {
            RestorePlanner.folder(for: recorded, project: folder, home: home) { (path: String) -> FolderCheck in exists.contains(path) ? .found : .gone }
        }
        #expect(choose(folder + "/src") == FolderChoice(path: folder + "/src"))
        #expect(choose(folder + "/src/gone/deeper") == FolderChoice(path: folder + "/src", movedFrom: folder + "/src/gone/deeper"))
        #expect(choose("/Users/x/app-old/gone") == FolderChoice(path: folder, movedFrom: "/Users/x/app-old/gone"))
        #expect(choose(folder + "/src", [home]) == FolderChoice(path: home, movedFrom: folder + "/src"))
        #expect(choose(nil) == FolderChoice(path: folder))
        #expect(RestorePlanner.folder(for: nil, project: nil, home: home) { _ in .found } == FolderChoice(path: home))
        // `.` and `..` are worked out first, so the walk up never leaves the project.
        let climbing = folder + "/../../../private/tmp/gone"
        #expect(choose(climbing, present.union(["/private/tmp"])) == FolderChoice(path: folder, movedFrom: "/private/tmp/gone"))
        let tidied: FolderChoice = choose(folder + "/./src/gone/..")
        #expect(tidied == FolderChoice(path: folder + "/src"))
        #expect(choose("app/src") == FolderChoice(path: folder, movedFrom: "app/src"))
    }

    @Test func aFolderNotCheckedInTimeIsNotCalledGone() {
        let slow = folder + "/net"
        let result = plan(pane(1, typed("ls", running: false, exit: 0), folder: slow), world: world(notChecked: [slow]))
        #expect(result.folder == folder && result.outcome == .idle)
        #expect(text(result) == "\(slow) could not be checked in time, so this tab opened in \(folder). Last command: ls (exit 0).")
        // Nor does a tab open in a folder above it that was not checked in time.
        let check = { (path: String) -> FolderCheck in path == self.folder ? .found : .notChecked }
        let deeper = RestorePlanner.folder(for: slow + "/deeper", project: folder, home: "/Users/x", check: check)
        #expect(deeper == FolderChoice(path: folder, movedFrom: slow + "/deeper", notChecked: true))
        let gone = RestorePlanner.folder(for: slow + "/deeper", project: folder, home: "/Users/x") { (path: String) -> FolderCheck in
            path == self.folder ? .found : .gone
        }
        #expect(gone == FolderChoice(path: folder, movedFrom: slow + "/deeper"))
    }

    @Test func nothingResumesInAFolderItFellBackTo() {
        let (evidence, facts) = exactClaude()
        let gone = folder + "/gone"
        let claude = pane(1, typed("claude"), agent: evidence, folder: gone)
        let result = plan(claude, world: world(facts: facts, exists: { $0 != gone }))
        #expect(result.outcome == .agentOnTheLine && result.folder == folder)
        #expect(text(result).hasPrefix("\(gone) is gone, so this tab opened in \(folder). claude --resume \(s) is back on the line"))
        let idle = plan(pane(2, typed("ls", running: false, exit: 0), folder: gone), world: world(exists: { $0 != gone }))
        #expect(text(idle) == "\(gone) is gone, so this tab opened in \(folder). Last command: ls (exit 0).")
    }

    @Test func anAgentsLineWaitsInItsSessionsFolder() {
        let sub = folder + "/sub"
        let evidence = Evidence(agent: .gemini, sessionID: g, source: .typedAndArgv, sessionFolder: sub, startedAt: start)
        let gemini = pane(1, typed("gemini --resume \(g)"), agent: evidence)
        let result = plan(gemini, world: world())
        #expect(result.outcome == .agentOnTheLine && result.line == "gemini --resume \(g)" && result.folder == sub)
        // The tab's folder is gone, and the session's is still there.
        let gone = folder + "/gone"
        let moved = plan(pane(1, typed("gemini --resume \(g)"), agent: evidence, folder: gone), world: world(exists: { $0 != gone }))
        #expect(moved.folder == sub && text(moved).hasPrefix("\(gone) is gone, so this tab opened in \(sub). gemini --resume"))
        // The session's folder is gone: the tab's own.
        let sessionGone: PanePlan = plan(gemini, world: world(exists: { (path: String) -> Bool in path != sub }))
        #expect(sessionGone.folder == folder)
        // In a shell without the integration, where the note's line is typed.
        let bash = plan(pane(1, typed("gemini", source: .polled), agent: evidence, systemZsh: false), world: world())
        #expect(bash.outcome == .agentNote && bash.folder == sub)
    }

    @Test func aRemintedTabSaysItHasANewID() {
        var reminted = pane(1, typed("ls", running: false, exit: 0))
        reminted.reminted = true
        #expect(text(plan(reminted, world: world())) == "This tab has a new id, because another tab had the same one. Last command: ls (exit 0).")
    }

    // MARK: safe mode

    @Test func safeModeRunsNothingAndSaysWhatEachTabHeld() {
        let (evidence, facts) = exactClaude()
        let panes = [pane(1, typed("claude"), agent: evidence), pane(2, typed("npm run dev")), pane(3, typed("make test", running: false, exit: 2)),
                     remote(4, keep: .off, typed("htop"))]
        let plans = plan(panes, kind: .update, safeMode: true, world: world(facts: facts))
        // What Try Again would apply: the update restore's own outcomes.
        expectOutcomes(plans, .resume, .commandOnTheLine, .idle, .freshConnection)
        #expect(plans.allSatisfy { $0.reason == .safeMode && $0.pending.reason == .safeMode })
        let held = "Nothing ran, because the last two restores did not finish. This tab held: "
        #expect(text(plans[0]) == held + "Claude Code was running. To resume it, type: claude --resume \(s)")
        #expect(text(plans[1]) == held + "npm run dev was running.")
        #expect(text(plans[2]) == held + "Last command: make test (exit 2).")
        #expect(text(plans[3]) == "New connection to web-1. Last command: htop.")
        let crash = plan(panes, kind: .crash, safeMode: true, world: world(facts: facts))
        expectOutcomes(crash, .agentOnTheLine, .commandOnTheLine, .idle, .freshConnection)
        #expect(text(crash[0]) == held + "Claude Code was running. To resume it, type: claude --resume \(s)")
        #expect(plan(pane(5, nil), safeMode: true, world: world()).note.text() == "Nothing ran, because the last two restores did not finish.")
    }

    @Test func safeModeNeverSaysAnythingRanAndItsListLinesWaitForTryAgain() {
        let (evidence, facts) = exactClaude()
        let older = pane(1, typed("claude"), agent: evidence, selected: 10)
        let newer = pane(2, typed("claude"), agent: evidence, selected: 20)
        let plans = plan([older, newer], safeMode: true, world: world(facts: facts))
        expectOutcomes(plans, .agentOnTheLine, .resume)
        let held = "Nothing ran, because the last two restores did not finish. This tab held: "
        let expected = held + "Claude Code was running. Another tab held this session too. To resume it, type: claude --resume \(s)"
        #expect(text(plans[0]) == expected)
        #expect(plans[1].listLine == "on Try Again, Claude Code resumes")
        #expect(plans[0].listLine == "on Try Again, Claude Code's resume command goes on the line, as another tab resumes this session")
        let dev = plan(pane(3, typed("npm run dev")), safeMode: true, world: world())
        #expect(dev.listLine == "on Try Again, npm run dev goes back on the line")
        #expect(plan(pane(4, typed("ls", running: false)), safeMode: true, world: world()).listLine == "opens in its folder")
        #expect(plan(remote(5, keep: .off, nil), safeMode: true, world: world()).listLine == "connection closes")
    }

    // MARK: every outcome and every note

    @Test func everyOutcomeHasAPlanAndEveryNoteIsOnePrintableLine() {
        let (evidence, facts) = exactClaude()
        let hostileFolder = "/Users/x/app/\u{1B}]52;c;aGk=\u{07}gone\n\u{9B}6n\u{202E}fdp.\u{200B}\u{2028}x"
        var bash = evidence
        bash.sessionID = nil
        let panes = [
            pane(1, typed("claude"), agent: evidence),
            pane(2, typed("gemini"), agent: Evidence(agent: .gemini)),
            pane(3, typed("npm run dev")),
            pane(4, typed("claude", source: .polled), agent: bash, systemZsh: false),
            pane(5, typed("aider"), agent: Evidence(agent: .aider)),
            pane(6, typed("npm run dev"), systemZsh: false),
            pane(7, typed("PGPASSWORD=x psql")),
            pane(8, typed("ls", running: false, exit: 0), folder: hostileFolder),
            remote(9, keep: .tmux, nil),
            remote(10, keep: .off, typed("htop")),
        ]
        let hosts = ["h1": "web\u{1B}[6n-1\n"]
        let exists = { (path: String) -> Bool in path != hostileFolder }
        var plans = plan(panes, world: world(facts: facts, exists: exists, hosts: hosts))
        #expect(Set(plans.map(\.outcome)) == Set(RestoreOutcome.allCases))
        plans += plan(panes, safeMode: true, world: world(facts: facts, exists: exists, hosts: hosts))
        for each in plans {
            let note = each.note.text() ?? ""
            #expect(TerminalText.oneLine(note) == note && TerminalTextTests.isPrintable(note), "\(each.outcome)")
            #expect(!note.unicodeScalars.contains(where: Command.isUnsafe), "\(each.outcome)")
            #expect(TerminalText.oneLine(each.listLine) == each.listLine, "\(each.outcome)")
            if let line = each.line { #expect(Command.problem(with: line) == nil, "\(each.outcome)") }
        }
        #expect(text(plans[7]).contains("gone") && !text(plans[7]).contains("\u{1B}"))
        #expect(text(plans[9]).hasPrefix("New connection to web[6n-1 . Last command: htop."))
    }

    @Test func eachOutcomeMapsToItsAction() {
        let actions: [RestoreOutcome: SessionSnapshot.Action] = [
            .resume: .resume, .agentOnTheLine: .onTheLine, .commandOnTheLine: .typeIn, .agentNote: .note, .agentHint: .note,
            .commandNote: .note, .notKept: .note, .idle: .note, .reattach: .reattach, .freshConnection: .freshConnection,
        ]
        for outcome in RestoreOutcome.allCases { #expect(outcome.action == actions[outcome], "\(outcome)") }
    }

    // MARK: pending actions

    @Test func aPendingActionMovesOnceAndItsRecordIsSavedUnchangedUntilThen() {
        let pending = PendingAction(action: .typeIn, reason: .update)
        #expect(pending.state == .pending)
        #expect(pending.after(.applied).state == .applied)
        #expect(pending.after(.userInput).state == .cancelled)
        #expect(pending.after(.dismissed).state == .dismissed)
        for state in [SessionSnapshot.ActionState.applied, .cancelled, .dismissed, .unknown] {
            for event in [PendingAction.Event.applied, .userInput, .dismissed] {
                #expect(PendingAction(action: .typeIn, state: state, reason: .update).after(event).state == state, "\(state) \(event)")
            }
        }
        var restored = pane(1, typed("npm run dev"))
        restored.pending = pending
        let current = pane(1, typed("vim notes.md"))
        #expect(RestorePlanner.recordToSave(restored: restored, current: current) == restored)
        for event in [PendingAction.Event.applied, .userInput, .dismissed] {
            restored.pending = pending.after(event)
            #expect(RestorePlanner.recordToSave(restored: restored, current: current) == current, "\(event)")
        }
        restored.pending = nil
        #expect(RestorePlanner.recordToSave(restored: restored, current: current) == current)
    }

    // MARK: the live lookup

    @Test func theLiveLookupReadsClaudeCodesOwnStore() throws {
        let home = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-planner-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let project = "/Users/x/app"
        let dir = home + "/.claude/projects/" + AgentSessions.claudeFolderName(project)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.claude/sessions", withIntermediateDirectories: true)
        let started = Date().addingTimeInterval(-600)
        let iso = ISO8601DateFormatter()
        func write(_ id: String, at offset: TimeInterval) throws {
            let line: [String: Any] = ["type": "user", "cwd": project, "timestamp": iso.string(from: started.addingTimeInterval(offset)),
                                       "message": ["content": "task"]]
            try JSONSerialization.data(withJSONObject: line).write(to: URL(fileURLWithPath: dir + "/\(id).jsonl"))
        }
        try write(Self.old, at: -60)
        try write(g, at: 30)
        try write(g2, at: 90)
        // This test's own process has g2 open, as a live claude would.
        let record = try JSONSerialization.data(withJSONObject: ["sessionId": g2])
        try record.write(to: URL(fileURLWithPath: home + "/.claude/sessions/\(getpid()).json"))

        let lookup = SessionLookup.live(home: home)
        let found = RestorePlanner.guess(.claude, in: project, after: started, excluding: [], lookup: lookup)
        #expect(found?.id == g && found?.naming == .newest && found?.date != nil)
        #expect(RestorePlanner.guess(.claude, in: project, after: started, excluding: [g], lookup: lookup) == nil)
        #expect(RestorePlanner.guess(.gemini, in: project, after: started, excluding: [], lookup: lookup) == nil)
    }
}
