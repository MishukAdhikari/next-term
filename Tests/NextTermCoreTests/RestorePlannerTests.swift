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
        evidence.options = []
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

    func plan(_ panes: [Pane], kind: SessionSnapshot.RestoreKind = .update, safeMode: Bool = false, quitConsent: Bool = false,
              world: RestorePlanner.World) -> [PanePlan] {
        let groups: [SessionSnapshot.Group] = panes.map { SessionSnapshot.Group(root: .pane($0), focused: $0.id) }
        let header = SessionSnapshot.Header(launchID: id(900), generation: 1, clean: false, savedAt: start)
        let snapshot = SessionSnapshot(header: header, windows: [SessionSnapshot.Window(project: folder, groups: groups)])
        return RestorePlanner.plan(snapshot, kind: kind, safeMode: safeMode, quitConsent: quitConsent, world: world)
    }

    func plan(_ pane: Pane, kind: SessionSnapshot.RestoreKind = .update, safeMode: Bool = false, quitConsent: Bool = false,
              world: RestorePlanner.World) -> PanePlan {
        plan([pane], kind: kind, safeMode: safeMode, quitConsent: quitConsent, world: world)[0]
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

    /// An agent's typed line holds its prompt words, which the file never keeps: read back, the pane holds the agent's
    /// program alone, and it still resumes, from its evidence (R8).
    @Test func anAgentReadBackWithItsProgramAloneStillResumes() throws {
        let (evidence, facts) = exactClaude()
        let claude = pane(1, typed("claude \"the staging db password is Tr0ub4dor\""), agent: evidence)
        let groups = [SessionSnapshot.Group(root: .pane(claude), focused: claude.id)]
        let header = SessionSnapshot.Header(launchID: id(900), generation: 1, clean: false, savedAt: start)
        let data = try SessionSnapshot(header: header, windows: [SessionSnapshot.Window(project: folder, groups: groups)]).encoded()
        #expect(!String(decoding: data, as: UTF8.self).contains("Tr0ub4dor"))
        let read = try #require(try SessionSnapshot.decode(data).panes.first)
        #expect(read.command?.line == "claude" && read.command?.check == .kept)
        let result = plan(read, world: world(facts: facts))
        #expect(result.outcome == .resume && result.line == evidence.resumeCommand)
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
            // A quit consent counts on a quit restore only.
            for consent in [false, true] {
                let result = plan(claude, kind: kind, quitConsent: consent, world: world(facts: facts))
                #expect(result.outcome == .agentOnTheLine && result.line == "claude --resume \(s)", "\(kind), \(consent)")
                #expect(result.pending.action == .onTheLine)
            }
        }
        #expect(plan(claude, kind: .crash, world: world(facts: facts)).reason == .crash)
    }

    /// AE17 and AE18: after a quit under "Resume where I left off", Claude Code resumes by itself only when the user let
    /// that quit go ahead with the box checked. Without it, its resume command waits on the line, as after a crash.
    @Test func aQuitRestoreResumesOnlyWithTheQuitConsent() {
        let (evidence, facts) = exactClaude()
        var claude = pane(1, typed("claude"), agent: evidence)
        claude.interrupted = true
        let consented = plan(claude, kind: .quit, quitConsent: true, world: world(facts: facts))
        guard case .resume(let command) = evidence.gate(facts) else {
            Issue.record("the gate did not pass")
            return
        }
        #expect(consented.outcome == .resume && consented.line == command)
        #expect(consented.reason == .quit && consented.pending == PendingAction(action: .resume, reason: .quit))
        #expect(text(consented) == "Resumed Claude Code session \(s). Its last turn was cut off by the quit and did not continue.")
        let without = plan(claude, kind: .quit, world: world(facts: facts))
        #expect(without.outcome == .agentOnTheLine && without.line == "claude --resume \(s)")
        #expect(without.reason == .quit && without.pending == PendingAction(action: .onTheLine, reason: .quit))
        // The gate still decides: a failed check puts it on the line with the consent too.
        var failing = facts
        failing.sessionAvailable = false
        #expect(plan(claude, kind: .quit, quitConsent: true, world: world(facts: failing)).outcome == .agentOnTheLine)
        // Safe mode after a quit runs nothing until Try Again.
        let safe = plan(claude, kind: .quit, safeMode: true, quitConsent: true, world: world(facts: facts))
        #expect(safe.reason == .safeMode && safe.note.safeMode)
    }

    /// Commands and idle tabs come back after a quit as after an update.
    @Test func aQuitRestorePutsCommandsBackAsAnUpdateRestoreDoes() {
        let dev = pane(1, typed("npm run dev"))
        let idle = pane(2, typed("ls", running: false, exit: 0))
        for consent in [false, true] {
            let plans = plan([dev, idle], kind: .quit, quitConsent: consent, world: world())
            expectOutcomes(plans, .commandOnTheLine, .idle)
            expectLines(plans, "npm run dev", "")
        }
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
        // A permission option argv alone shows: on the line.
        var bypass = evidence
        bypass.options = [SessionSnapshot.LaunchOption(["--dangerously-skip-permissions"])]
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

    // MARK: the user's launch, back (AE15, AE23-AE30)

    /// `/usr/bin/env` with Claude Code's auto-continue variables unset, and the path the fixtures record.
    var claudeRuns: String {
        let unset = RestoreAgent.claude.autoContinueVariables.map { "-u " + $0 }.joined(separator: " ")
        return "/usr/bin/env \(unset) /Users/x/.local/bin/claude"
    }

    /// What capture makes of a launch: `argv` run as the tab's verified leader from `executable`, typed as `typed`, and
    /// expanded to `expanded` when the typed word was an alias. Nothing it reads is on this Mac.
    func captured(_ argv: [String], typed: String, expanded: String? = nil, executable: String = "/Users/x/.local/bin/claude",
                  environment: [String: String] = [:]) throws -> Evidence {
        let leader = AgentProcess(pid: 7, startedAt: start, executable: executable, arguments: argv, environment: environment,
                                  directory: folder)
        let input = AgentEvidence.Capture(leader: leader, verified: true, typedLine: typed, expandedLine: expanded, home: "/Users/x")
        return try #require(AgentEvidence.capture(input), "\(argv)")
    }

    /// The same, as Claude Code with the exact id `S` from its own session file, and facts on which every other check
    /// passes: what the restore's gate then makes of the launch's options and the line it was typed as.
    func launched(_ argv: [String], typed line: String, expanded: String? = nil,
                  environment: [String: String] = [:]) throws -> (Pane, RestorePlanner.World) {
        let (exact, facts) = exactClaude()
        var evidence = try captured(argv, typed: line, expanded: expanded, environment: environment)
        evidence.sessionID = exact.sessionID
        evidence.source = exact.source
        evidence.store = exact.store
        evidence.routingMatchesShell = true
        return (pane(1, typed(line), agent: evidence), world(facts: facts))
    }

    /// The text a put-back line's note starts with.
    func back(_ line: String, _ agent: String = "Claude Code", _ id: String = RestorePlannerTests.s) -> String {
        "\(line) is back on the line, not run. Press Return to resume \(agent) session \(id), or edit it first."
    }

    /// AE15: a permission option typed with the agent comes back on an update restore, and the note names it. After a
    /// crash, the launch goes back on the line.
    @Test func ae15APermissionOptionTypedWithTheAgentComesBack() throws {
        let (claude, world) = try launched(["claude", "--dangerously-skip-permissions"], typed: "claude --dangerously-skip-permissions")
        let update = plan(claude, world: world)
        #expect(update.outcome == .resume && update.line == claudeRuns + " --resume \(s) --dangerously-skip-permissions")
        #expect(text(update) == "Resumed Claude Code session \(s) with --dangerously-skip-permissions.")
        let waiting = update.note.shownBeforeShell() ?? ""
        #expect(waiting == "Claude Code session \(s) resumes with --dangerously-skip-permissions \(RestoreNote.onceReady).")
        let crash = plan(claude, kind: .crash, world: world)
        #expect(crash.outcome == .agentOnTheLine && crash.line == "claude --dangerously-skip-permissions --resume \(s)")
        #expect(text(crash) == back("claude --dangerously-skip-permissions --resume \(s)"))
    }

    /// AE23, AE24: an alias whose expansion is the agent and a permission option resumes with it on an update restore,
    /// or a quit restore with the quit consent. After a crash, or a quit without the consent, the alias is replayed.
    @Test func ae23AndAe24AnAliasResumesWithItsOptionOrIsReplayed() throws {
        let (claude, world) = try launched(["claude", "--dangerously-skip-permissions"], typed: "claude-auto-danger",
                                           expanded: "claude --dangerously-skip-permissions")
        for (kind, consent) in [(SessionSnapshot.RestoreKind.update, false), (.quit, true)] {
            let resumed = plan(claude, kind: kind, quitConsent: consent, world: world)
            #expect(resumed.outcome == .resume && resumed.line == claudeRuns + " --resume \(s) --dangerously-skip-permissions", "\(kind)")
            #expect(text(resumed) == "Resumed Claude Code session \(s) with --dangerously-skip-permissions.", "\(kind)")
        }
        for (kind, consent) in [(SessionSnapshot.RestoreKind.crash, false), (.quit, false)] {
            let put = plan(claude, kind: kind, quitConsent: consent, world: world)
            #expect(put.outcome == .agentOnTheLine && put.line == "claude-auto-danger --resume \(s)", "\(kind)")
            #expect(text(put) == back("claude-auto-danger --resume \(s)"), "\(kind)")
        }
    }

    /// AE25: a function's option shows in argv alone, which can't confirm it: its launch is rebuilt from argv and goes on
    /// the line on every restore.
    @Test func ae25AFunctionsOptionGoesOnTheLineOnEveryRestore() throws {
        let (claude, world) = try launched(["claude", "--dangerously-skip-permissions"], typed: "claude-auto-danger")
        for (kind, consent) in [(SessionSnapshot.RestoreKind.update, false), (.quit, true), (.quit, false), (.crash, false)] {
            let put = plan(claude, kind: kind, quitConsent: consent, world: world)
            #expect(put.outcome == .agentOnTheLine && put.line == "claude --dangerously-skip-permissions --resume \(s)", "\(kind)")
            #expect(text(put) == back("claude --dangerously-skip-permissions --resume \(s)"), "\(kind)")
        }
        // Expanded by the shell as itself, a function shows the same.
        let (same, sameWorld) = try launched(["claude", "--dangerously-skip-permissions"], typed: "claude-auto-danger",
                                             expanded: "claude-auto-danger")
        #expect(plan(same, world: sameWorld).line == "claude --dangerously-skip-permissions --resume \(s)")
    }

    /// AE26: plain options within their patterns and a confirmed permission option are carried; the prompt never is.
    @Test func ae26OptionsComeBackAndThePromptNever() throws {
        let argv = ["claude", "--model", "opus[1m]", "--permission-mode", "bypassPermissions", "fix the tests"]
        let typed = "claude --model 'opus[1m]' --permission-mode bypassPermissions \"fix the tests\""
        let (claude, world) = try launched(argv, typed: typed)
        let update = plan(claude, world: world)
        let command = claudeRuns + " --resume \(s) --model 'opus[1m]' --permission-mode bypassPermissions"
        #expect(update.outcome == .resume && update.line == command)
        #expect(text(update) == "Resumed Claude Code session \(s) with --permission-mode bypassPermissions.")
        let crash = plan(claude, kind: .crash, world: world)
        #expect(crash.line == "claude --model 'opus[1m]' --permission-mode bypassPermissions --resume \(s)")
        for result in [update, crash] {
            #expect(!(result.line ?? "").contains("fix the tests") && !text(result).contains("fix the tests"))
        }
    }

    /// AE27: an alias that sets a variable fails the gate on that prefix, and is replayed, so the session is looked for in
    /// the store the alias names.
    @Test func ae27AnAliasThatSetsAVariableIsReplayed() throws {
        let (claude, world) = try launched(["claude"], typed: "cw", expanded: "CLAUDE_CONFIG_DIR=/Users/x/.claude-work claude",
                                           environment: ["CLAUDE_CONFIG_DIR": "/Users/x/.claude-work"])
        let failed: [ResumeCheck] = {
            guard let evidence = claude.agent, case .onTheLine(let failed) = evidence.gate(exactClaude().1) else { return [] }
            return failed
        }()
        #expect(failed.contains(.typedLine))
        let update = plan(claude, world: world)
        #expect(update.outcome == .agentOnTheLine && update.line == "cw --resume \(s)")
        #expect(text(update) == back("cw --resume \(s)"))
    }

    /// AE28: a code-loading option never runs by itself, and comes back on the line on every restore.
    @Test func ae28ACodeLoadingOptionGoesOnTheLine() throws {
        let (claude, world) = try launched(["claude", "--mcp-config", "./mcp.json"], typed: "claude --mcp-config ./mcp.json")
        for (kind, consent) in [(SessionSnapshot.RestoreKind.update, false), (.quit, true), (.crash, false)] {
            let put = plan(claude, kind: kind, quitConsent: consent, world: world)
            #expect(put.outcome == .agentOnTheLine && put.line == "claude --mcp-config ./mcp.json --resume \(s)", "\(kind)")
        }
    }

    /// AE29: Codex resumes with `--yolo` after its resume form; Gemini CLI's and Copilot CLI's launches go on the line,
    /// and Copilot's `-r` is dropped, never left off.
    @Test func ae29CodexResumesAndGeminiAndCopilotGoOnTheLine() throws {
        let user = geteuid()
        var codex = try captured(["codex", "--yolo"], typed: "codex --yolo", executable: "/opt/homebrew/bin/codex")
        codex.sessionID = s
        codex.source = .openRollout
        codex.store = "/Users/x/.codex"
        codex.routingMatchesShell = true
        let files: [String: FileFacts] = [
            "/opt/homebrew/bin/codex": FileFacts(realPath: "/opt/homebrew/Caskroom/codex/0.154.0/codex", owner: 0, mode: 0o755, isRegular: true),
            folder: FileFacts(realPath: folder, owner: user, mode: 0o755, isDirectory: true),
            "/Users/x/.codex": FileFacts(realPath: "/Users/x/.codex", owner: user, mode: 0o700, isDirectory: true),
        ]
        let facts = ResumeFacts(user: user, files: files, outside: [folder], temporaryFolders: ["/private/tmp"], sessionAvailable: true,
                                projectConfigChanged: false, settingsAutoContinue: false)
        let resumed = plan(pane(1, typed("codex --yolo"), agent: codex), world: world(facts: facts))
        #expect(resumed.outcome == .resume && resumed.line == "/usr/bin/env /opt/homebrew/bin/codex resume \(s) -C \(folder) --yolo")
        #expect(text(resumed) == "Resumed Codex session \(s) with --yolo.")

        let lookups = Lookups()
        lookups.sessions = [session(.gemini, g, at: 30, updated: 90)]
        let gemini = try captured(["gemini", "--approval-mode=yolo"], typed: "gemini --approval-mode=yolo", executable: "/opt/homebrew/bin/gemini")
        let guessed = plan(pane(1, typed("gemini --approval-mode=yolo"), agent: gemini), world: world(lookups: lookups))
        #expect(guessed.outcome == .agentOnTheLine && guessed.line == "gemini --approval-mode=yolo --resume \(g)")
        #expect(text(guessed).hasPrefix(back("gemini --approval-mode=yolo --resume \(g)", "Gemini CLI", g)))

        let copilot = try captured(["copilot", "-r", s, "--allow-all"], typed: "copilot -r \(s) --allow-all",
                                   executable: "/opt/homebrew/bin/copilot")
        let put = plan(pane(1, typed("copilot -r \(s) --allow-all"), agent: copilot), world: world())
        #expect(put.outcome == .agentOnTheLine && put.line == "copilot --allow-all --resume=\(s)")
        #expect(text(put) == back("copilot --allow-all --resume=\(s)", "Copilot CLI"))
    }

    /// AE30: an option the table does not know, followed by a word that may be a prompt's, is left off with that word and
    /// named; joined to its value by `=`, it is kept.
    @Test func ae30AnUnknownOptionIsKeptOnlyWithAPlainValue() throws {
        let (unclear, world) = try launched(["claude", "--newflag", "value"], typed: "claude --newflag value")
        let left = plan(unclear, world: world)
        #expect(left.outcome == .agentOnTheLine && left.line == "claude --resume \(s)")
        #expect(text(left) == back("claude --resume \(s)") + " Left off: --newflag (Next Term can't tell its value from a prompt).")
        let (joined, joinedWorld) = try launched(["claude", "--newflag=value"], typed: "claude --newflag=value")
        let kept = plan(joined, world: joinedWorld)
        #expect(kept.outcome == .agentOnTheLine && kept.line == "claude --newflag=value --resume \(s)")
        #expect(text(kept) == back("claude --newflag=value --resume \(s)"))
        // Two named at once, in a note with no session named.
        var two = unclear
        two.agent?.options = [SessionSnapshot.LaunchOption(["--newflag"], unclear: true), SessionSnapshot.LaunchOption(["--other"], unclear: true)]
        two.agent?.sessionID = nil
        two.agent?.launcher = nil
        let none = plan(two, kind: .crash, world: world)
        #expect(none.line == "claude")
        let said = "claude is back on the line, not run. No Claude Code session could be named, so Return starts a new one. "
            + "Left off: --newflag, --other (Next Term can't tell their values from a prompt)."
        #expect(text(none) == said)
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

    /// Aider's note names the permission options it ran with (R7), from argv's options or, without them, the typed line's.
    @Test func aidersNoteNamesThePermissionOptionsItRanWith() {
        let note = "Aider was running. Start it with --restore-chat-history --yes-always to reload the chat."
        let fromArgv = Evidence(agent: .aider, startedAt: start, options: [.init(["--yes-always"]), .init(["--model", "sonnet"])])
        let fromTyped = Evidence(agent: .aider, startedAt: start, confirmed: [.init(["--yes-always"])])
        for evidence in [fromArgv, fromTyped] {
            let result = plan(pane(1, typed("aider --yes-always --model sonnet"), agent: evidence), world: world())
            #expect(result.outcome == .agentHint && result.line == nil && result.pending.action == .note)
            #expect(text(result) == note)
            #expect(!text(result).contains("--model"))
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
        // What Try Again would apply: the update restore's outcomes, with each agent's resume command on the line, unrun.
        // The launch that held the restore back used the update's consent (R21, KTD2).
        expectOutcomes(plans, .agentOnTheLine, .commandOnTheLine, .idle, .freshConnection)
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
        expectOutcomes(plans, .agentOnTheLine, .agentOnTheLine)
        let held = "Nothing ran, because the last two restores did not finish. This tab held: "
        let expected = held + "Claude Code was running. Another tab held this session too. To resume it, type: claude --resume \(s)"
        #expect(text(plans[0]) == expected)
        #expect(plans[1].listLine == "on Try Again, Claude Code's resume command goes on the line")
        #expect(plans[0].listLine == "on Try Again, Claude Code's resume command goes on the line")
        let dev = plan(pane(3, typed("npm run dev")), safeMode: true, world: world())
        #expect(dev.listLine == "on Try Again, npm run dev goes back on the line")
        #expect(plan(pane(4, typed("ls", running: false)), safeMode: true, world: world()).listLine == "opens in its folder")
        #expect(plan(remote(5, keep: .off, nil), safeMode: true, world: world()).listLine == "connection closes")
    }

    /// Safe mode's Try Again never resumes an agent, whatever restore it holds back (R21, KTD2, KTD13): the launch that
    /// claimed the marker or the quit's consent id used that consent, whether or not its restore finished. Each agent's
    /// resume command goes on the line, unrun, and the alert promises no resume.
    @Test func safeModesTryAgainNeverResumes() {
        let (evidence, facts) = exactClaude()
        let panes = [pane(1, typed("claude"), agent: evidence), pane(2, typed("npm run dev"))]
        let crash = plan(panes, kind: .crash, safeMode: true, world: world(facts: facts))
        let quit = plan(panes, kind: .quit, safeMode: true, quitConsent: true, world: world(facts: facts))
        let update = plan(panes, kind: .update, safeMode: true, world: world(facts: facts))
        for plans in [crash, quit, update] {
            expectOutcomes(plans, .agentOnTheLine, .commandOnTheLine)
            #expect(plans[0].line == "claude --resume \(s)")
        }
        // Out of safe mode, the same update restore resumes.
        let resumes = plan(panes, kind: .update, world: world(facts: facts))
        expectOutcomes(resumes, .resume, .commandOnTheLine)
        // A resume held by safe mode never runs as Try Again applies it, whatever planned it: its resume command goes on
        // the line, unrun, with no word of a session taken.
        var held = resumes[0]
        held.reason = .safeMode
        #expect(RestoreLayout.resumeStart(held, sessionAvailable: true) == .putBack(line: "claude --resume \(s)", note: nil))
        #expect(RestoreLayout.resumeStart(resumes[0], sessionAvailable: true) == .run(resumes[0].line ?? ""))
        #expect(!RestoreAlertText.safeModeText.contains("resumes"))
    }

    // MARK: before the shell is ready

    /// The note as the tab shows it before its shell starts, dates as in `text`.
    func shown(_ plan: PanePlan) -> String {
        let start = self.start
        return plan.note.shownBeforeShell { (date: Date) -> String in "T+\(Int(date.timeIntervalSince(start)))" } ?? ""
    }

    /// A note is shown before the shell starts, and an action that types waits for the shell: it may never happen, as the
    /// user typing first drops it. So its note says what happens once the shell is ready, unless the user types first.
    @Test func beforeItsShellIsReadyATabSaysWhatHappensThenUnlessTheUserTypesFirst() {
        let (evidence, facts) = exactClaude()
        var claude = pane(1, typed("claude"), agent: evidence)
        claude.interrupted = true
        let resume = plan(claude, world: world(facts: facts))
        #expect(shown(resume) == "Claude Code session \(s) resumes once the shell is ready, unless you type first. "
            + "Its last turn was cut off by the update and does not continue.")
        var typedOnly = evidence
        typedOnly.source = .typedAndArgv
        let line = plan(pane(2, typed("claude --resume \(s)"), agent: typedOnly), world: world(facts: facts))
        #expect(shown(line) == "claude --resume \(s) goes back on the line, not run, once the shell is ready, unless you type first. "
            + "Press Return to resume Claude Code session \(s), or edit it first.")
        let gemini = plan(pane(3, typed("gemini"), agent: Evidence(agent: .gemini)), world: world())
        #expect(shown(gemini) == "gemini goes back on the line, not run, once the shell is ready, unless you type first. "
            + "No Gemini CLI session could be named, so Return starts a new one.")
        let dev = plan(pane(4, typed("npm run dev")), world: world())
        #expect(shown(dev) == "npm run dev goes back on the line, not run, once the shell is ready, unless you type first. "
            + "Press Return to run it, or edit it first.")
        // What happened, once it has: the note's own words.
        #expect(text(dev) == "npm run dev is back on the line, not run. Press Return to run it, or edit it first.")
        // A note that waits for nothing, and safe mode, which applies nothing until Try Again, read the same either way.
        let idle = plan(pane(5, typed("make test", running: false, exit: 2)), world: world())
        #expect(shown(idle) == text(idle))
        let held = plan(pane(6, typed("npm run dev")), safeMode: true, world: world())
        #expect(shown(held) == text(held))
        let kept = plan(remote(7, keep: .off, typed("htop")), world: world())
        #expect(shown(kept) == text(kept))
    }

    /// As an automatic resume's turn comes, its session is read again (KTD5): one a process took since is not resumed. Its
    /// resume command goes on the line instead, unrun, and the tab says why.
    @Test func aResumeWhoseSessionAProcessTookPutsItsLineBackAndSaysWhy() {
        let (evidence, facts) = exactClaude()
        let resume = plan(pane(1, typed("claude"), agent: evidence), world: world(facts: facts))
        let command = resume.line ?? ""
        #expect(resume.outcome == .resume && command.hasPrefix("/usr/bin/env "))
        #expect(RestoreLayout.resumeStart(resume, sessionAvailable: true) == .run(command))
        let taken = "Claude Code session \(s) did not resume, because another process has it open. "
            + "claude --resume \(s) is on the line, not run."
        #expect(resume.note.sessionTakenText == taken)
        #expect(RestoreLayout.resumeStart(resume, sessionAvailable: false) == .putBack(line: "claude --resume \(s)", note: taken))
        // Only a resume has that note, and only a resume runs.
        let dev = plan(pane(2, typed("npm run dev")), world: world())
        #expect(dev.note.sessionTakenText == nil)
        #expect(RestoreLayout.resumeStart(dev, sessionAvailable: true) == .putBack(line: nil, note: nil))
    }

    /// What a tab's note says once its action that types was cancelled, because something reached the line before the
    /// shell was ready: nothing was typed, so no agent resumed and no line waits. It names what would resume the agent,
    /// last, and never the words of a note that says it happened.
    func cancelled(_ plan: PanePlan) -> String {
        let start = self.start
        return plan.note.cancelledText { (date: Date) -> String in "T+\(Int(date.timeIntervalSince(start)))" } ?? ""
    }

    @Test func aCancelledActionSaysNothingWasTypedAndHowToResume() {
        let typedFirst = "something was typed in the tab before its shell was ready"
        let (evidence, facts) = exactClaude()
        var claude = pane(1, typed("claude"), agent: evidence)
        claude.interrupted = true
        let resume = plan(claude, world: world(facts: facts))
        #expect(resume.outcome == .resume)
        #expect(cancelled(resume) == "Claude Code session \(s) did not resume: \(typedFirst). "
            + "Its last turn was cut off by the update. To resume it, type: claude --resume \(s)")
        let afterQuit = plan(claude, kind: .quit, quitConsent: true, world: world(facts: facts))
        #expect(afterQuit.outcome == .resume && cancelled(afterQuit).contains("cut off by the quit."))
        // A guessed session says it is a guess, and its date.
        let lookups = Lookups()
        lookups.sessions = [session(.gemini, g, at: 30, updated: 90)]
        let gemini = plan(pane(2, typed("gemini \"fix the login bug\""), agent: Evidence(agent: .gemini, sessionFolder: folder, startedAt: start)),
                          world: world(lookups: lookups))
        #expect(gemini.outcome == .agentOnTheLine)
        #expect(cancelled(gemini) == "Gemini CLI was running. Its line was not put back: \(typedFirst). "
            + "This is a guess: the newest session in this folder. Last used T+90. To resume it, type: gemini --resume \(g)")
        let nameless = plan(pane(3, typed("gemini"), agent: Evidence(agent: .gemini)), world: world())
        #expect(cancelled(nameless) == "Gemini CLI was running. Its line was not put back: \(typedFirst). "
            + "No Gemini CLI session could be named. To start it again, type: gemini")
        let dev = plan(pane(4, typed("npm run dev")), world: world())
        #expect(dev.outcome == .commandOnTheLine)
        #expect(cancelled(dev) == "npm run dev was running. It was not put back: \(typedFirst).")
        for each in [resume, afterQuit, gemini, nameless, dev] {
            let said = cancelled(each)
            #expect(!said.contains("Resumed") && !said.contains("back on the line") && !said.contains("Press Return"), "\(said)")
            #expect(TerminalText.oneLine(said) == said)
        }
        // A note that types nothing, and safe mode, whose note already says nothing ran, read as they always do.
        let idle = plan(pane(5, typed("make test", running: false, exit: 2)), world: world())
        #expect(cancelled(idle) == text(idle))
        let held = plan(pane(6, typed("npm run dev")), safeMode: true, world: world())
        #expect(cancelled(held) == text(held))
        let kept = plan(remote(7, keep: .off, typed("htop")), world: world())
        #expect(cancelled(kept) == text(kept))
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
            for note in [each.note.text() ?? "", each.note.shownBeforeShell() ?? "", each.note.sessionTakenText ?? ""] {
                #expect(TerminalText.oneLine(note) == note && TerminalTextTests.isPrintable(note), "\(each.outcome)")
                #expect(!note.unicodeScalars.contains(where: Command.isUnsafe), "\(each.outcome)")
            }
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

    /// The gate's session check (KTD5), as the restore reads it when the action runs: the session is in the store the
    /// agent used, the one this Mac's home keeps for it, and no live process holds it.
    @Test func aSessionIsAvailableOnlyInItsOwnStoreWithNoProcessHoldingIt() throws {
        let home = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-available-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let project = "/Users/x/app"
        let dir = home + "/.claude/projects/" + AgentSessions.claudeFolderName(project)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.claude/sessions", withIntermediateDirectories: true)
        for id in [g, g2] {
            let line: [String: Any] = ["type": "user", "cwd": project, "timestamp": "2026-10-09T10:00:00Z", "message": ["content": "task"]]
            try JSONSerialization.data(withJSONObject: line).write(to: URL(fileURLWithPath: dir + "/\(id).jsonl"))
        }
        // This test's own process holds g2, as a live claude would.
        let record = try JSONSerialization.data(withJSONObject: ["sessionId": g2])
        try record.write(to: URL(fileURLWithPath: home + "/.claude/sessions/\(getpid()).json"))
        let lookup = SessionLookup.live(home: home)
        func evidence(_ id: String, store: String? = nil, folder: String? = "/Users/x/app") -> Evidence {
            Evidence(agent: .claude, sessionID: id, source: .sessionFile, sessionFolder: folder, store: store ?? home + "/.claude")
        }
        #expect(lookup.available(evidence(g), home: home))
        #expect(lookup.available(evidence(g.uppercased()), home: home))
        #expect(!lookup.available(evidence(g2), home: home))
        #expect(!lookup.available(evidence(Self.s), home: home))
        #expect(!lookup.available(evidence(g, store: home + "/claude-work"), home: home))
        #expect(!lookup.available(evidence(g, folder: nil), home: home))
        #expect(!lookup.available(evidence(g, folder: "/Users/x/web"), home: home))
        var noID = evidence(g)
        noID.sessionID = nil
        #expect(!lookup.available(noID, home: home))
        var gemini = evidence(g)
        gemini.agent = .gemini
        #expect(!lookup.available(gemini, home: home))
    }

    /// The update sheet plans before the quit, while the tab's own claude still holds its session (R14, KTD5): a session
    /// only processes the quit stops hold reads as free there, to the gate's session check and to a guess alike, as it
    /// will once they have stopped. One any other process holds does not, and the restore itself frees none.
    @Test func onTheSheetASessionHeldOnlyByTheTabsOwnProcessCountsAsFree() throws {
        let home = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-freed-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let project = "/Users/x/app"
        let dir = home + "/.claude/projects/" + AgentSessions.claudeFolderName(project)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.claude/sessions", withIntermediateDirectories: true)
        for id in [g, g2] {
            let line: [String: Any] = ["type": "user", "cwd": project, "timestamp": "2026-10-09T10:00:00Z", "message": ["content": "task"]]
            try JSONSerialization.data(withJSONObject: line).write(to: URL(fileURLWithPath: dir + "/\(id).jsonl"))
        }
        // This test's own process holds g2, as the tab's live claude would, and its parent holds g; a record of a process
        // gone, or of no process, holds nothing.
        let own = getpid(), parent = getppid()
        let sessions = home + "/.claude/sessions/"
        try JSONSerialization.data(withJSONObject: ["sessionId": g2]).write(to: URL(fileURLWithPath: sessions + "\(own).json"))
        try JSONSerialization.data(withJSONObject: ["sessionId": g]).write(to: URL(fileURLWithPath: sessions + "\(parent).json"))
        try JSONSerialization.data(withJSONObject: ["sessionId": g2]).write(to: URL(fileURLWithPath: sessions + "999999.json"))
        try JSONSerialization.data(withJSONObject: ["sessionId": g2]).write(to: URL(fileURLWithPath: sessions + "0.json"))
        let holders = AgentSessions.claudeHolders(home: home)
        #expect(holders == [g2: [own], g: [parent]])
        #expect(AgentSessions.claudeRunning(home: home) == [g, g2])

        // Held only by a process the quit stops: freed, by its id in lower case.
        let quitStops = { (pid: Int32) -> Bool in pid == own }
        let freed = SessionLookup.freedAtQuit(holders: holders, stops: quitStops)
        #expect(freed == [g2.lowercased()])
        #expect(SessionLookup.freedAtQuit(holders: [g2.uppercased(): [own]], stops: quitStops) == [g2.lowercased()])
        // Held by another process too, under any case of its id, or by none the quit stops: still taken.
        #expect(SessionLookup.freedAtQuit(holders: [g2: [own, own + 1]], stops: quitStops).isEmpty)
        #expect(SessionLookup.freedAtQuit(holders: [g2: [own], g2.uppercased(): [parent]], stops: quitStops).isEmpty)
        #expect(SessionLookup.freedAtQuit(holders: holders) { (_: Int32) -> Bool in false }.isEmpty)

        // The gate's session check: taken as the restore reads it, free as the sheet reads it.
        let evidence = Evidence(agent: .claude, sessionID: g2, source: .sessionFile, sessionFolder: project, store: home + "/.claude")
        let lookup = SessionLookup.live(home: home)
        let sheet = lookup.freeing(freed)
        #expect(!lookup.available(evidence, home: home))
        #expect(sheet.available(evidence, home: home))
        var upper = evidence
        upper.sessionID = g2.uppercased()
        #expect(sheet.available(upper, home: home))
        // Freeing one session frees no other: g stays its holder's.
        var other = evidence
        other.sessionID = g
        #expect(!sheet.available(other, home: home))
        #expect(!lookup.freeing([]).available(evidence, home: home))

        // A guess reads the same: the sheet finds the tab's own session, as the relaunch will.
        #expect(RestorePlanner.guess(.claude, in: project, after: .distantPast, excluding: [], lookup: lookup) == nil)
        let guessed = RestorePlanner.guess(.claude, in: project, after: .distantPast, excluding: [], lookup: sheet)
        #expect(guessed?.id == g2 && guessed?.naming == .newest)
    }
}
