import Foundation
import Testing
@testable import NextTermCore

/// Plan 046: why a restore held an agent. The report each launch leaves (`last-restore.json`), the reason a held tab's
/// note and MCP's `restored` give, and the gate on a pane whose agent was not typed through the zsh integration. Every
/// fact here is made up; the one file written goes in a temporary folder of the test's own.
extension RestorePlannerTests {
    /// A Claude Code pane whose line was not reported by the integration: polled argv in a bash shell, no typed line.
    func polledClaude(_ n: Int, _ evidence: Evidence, systemZsh: Bool) -> Pane {
        pane(n, typed("claude", source: .polled), agent: evidence, systemZsh: systemZsh)
    }

    /// The decision of an update launch whose marker checked out.
    func updateDecision(_ kind: LaunchRestoreKind = .restore(.update), marker: UpdateMarker.Check = .valid) -> RestoreDecision {
        RestoreDecision(kind: kind, marker: marker, saves: true, consumes: [], quitConsent: false, scrollback: .read, scrollbackQuit: nil,
                        installAlert: nil, didNotInstallNote: false, attemptsReset: .afterRestore)
    }

    func snapshot(_ panes: [Pane]) -> SessionSnapshot {
        let groups: [SessionSnapshot.Group] = panes.map { SessionSnapshot.Group(root: .pane($0), focused: $0.id) }
        let header = SessionSnapshot.Header(launchID: id(900), generation: 1, clean: false, savedAt: start)
        return SessionSnapshot(header: header, windows: [SessionSnapshot.Window(project: folder, groups: groups)])
    }

    func json(_ report: RestoreReport) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: report.data) as? [String: Any])
    }

    // MARK: no zsh dependence

    /// An agent started without the integration (bash, a script, polled argv) passes the gate on what ran: an update
    /// restore resumes it. In a shell that never reports it is ready (not the system zsh, no integration), its restored
    /// tab cannot take a typed line, so it gets a note, as before.
    @Test func anAgentStartedWithoutTheIntegrationResumes() {
        let (exact, facts) = exactClaude()
        var evidence = exact
        evidence.ranAsTyped = false
        evidence.confirmed = []
        let zsh = plan(polledClaude(1, evidence, systemZsh: true), world: world(facts: facts))
        #expect(zsh.outcome == .resume && zsh.line == evidence.resumeCommand && zsh.heldBecause.isEmpty && zsh.stop == nil)
        let bash = plan(polledClaude(2, evidence, systemZsh: false), world: world(facts: facts))
        #expect(bash.outcome == .agentNote)
        // After a crash, or in safe mode, it never resumes, whatever ran.
        #expect(plan(polledClaude(1, evidence, systemZsh: true), kind: .crash, world: world(facts: facts)).outcome == .agentOnTheLine)
        #expect(plan(polledClaude(1, evidence, systemZsh: true), safeMode: true, world: world(facts: facts)).outcome == .agentOnTheLine)
        // A permission option argv alone shows is held by the flags policy, and says so.
        var flagged = evidence
        flagged.options = [SessionSnapshot.LaunchOption(["--dangerously-skip-permissions"])]
        let held = plan(polledClaude(1, flagged, systemZsh: true), world: world(facts: facts))
        #expect(held.outcome == .agentOnTheLine && held.heldBecause == [.flags])
        #expect(text(held).hasSuffix("Held: its launch flags."))
    }

    /// The selected-last-pane rule holds without the integration too: of two panes on one session, only the later one
    /// resumes, and the other's note says another tab resumed it.
    @Test func withoutTheIntegrationOnlyThePaneSelectedLastResumes() {
        let (exact, facts) = exactClaude()
        var first = polledClaude(1, exact, systemZsh: true)
        var second = polledClaude(2, exact, systemZsh: true)
        first.lastSelected = start
        second.lastSelected = start.addingTimeInterval(60)
        let plans = plan([first, second], world: world(facts: facts))
        #expect(plans.map(\.outcome) == [.agentOnTheLine, .resume])
        #expect(plans[0].heldBecause.isEmpty && text(plans[0]).hasSuffix("Another tab resumed this session."))
    }

    /// The executable that ran is the one the resume runs: another file at its path is held, with that reason.
    @Test func aChangedProgramIsHeldWithItsReason() {
        var (evidence, facts) = exactClaude()
        evidence.ranPath = "/Users/x/.local/share/claude/2.1.279"
        let result = plan(polledClaude(1, evidence, systemZsh: true), world: world(facts: facts))
        #expect(result.outcome == .agentOnTheLine && result.heldBecause == [.executableChanged])
        #expect(text(result).contains("Held: its program changed since it started."))
        // Now in a project: its location too.
        facts.files["/Users/x/.local/bin/claude"]?.realPath = folder + "/node_modules/.bin/claude"
        let moved = plan(polledClaude(1, evidence, systemZsh: true), world: world(facts: facts))
        #expect(moved.heldBecause == [.executableChanged, .location])
        #expect(text(moved).contains("Held: its program changed since it started and where its program lies."))
    }

    // MARK: the report

    /// The report names each pane's planned outcome, the checks that held an agent, where the gate was not asked the
    /// condition that stopped it, and the marker's check, with nothing of what the panes ran but the agent's name.
    @Test func theReportSaysWhyEachPaneCameBackAsItDid() throws {
        let (exact, facts) = exactClaude()
        var flagged = exact
        flagged.options = [SessionSnapshot.LaunchOption(["--dangerously-skip-permissions"])]
        var typedOnly = exact
        typedOnly.source = .typedAndArgv
        let panes = [
            pane(1, typed("claude"), agent: exact),
            pane(2, typed("claude --dangerously-skip-permissions fix the login bug"), agent: flagged, selected: 10),
            pane(3, typed("claude --resume \(s)"), agent: typedOnly, selected: -10),
            pane(4, nil),
        ]
        var resumable = panes
        // Each pane holds its own session, so the selected-last rule takes none of them.
        resumable[1].agent?.sessionID = "aaaaaaaa-1111-4222-8333-444444444444"
        resumable[2].agent?.sessionID = "bbbbbbbb-1111-4222-8333-444444444444"
        let shot = snapshot(resumable)
        let plans = RestorePlanner.plan(shot, kind: .update, world: world(facts: facts))
        let written = Date(timeIntervalSince1970: 1_790_000_000)
        let report = RestoreReport(decision: updateDecision(), snapshot: shot, plans: plans, planTimedOut: false, appVersion: "0.11.61",
                                   writtenAt: written)
        #expect(report.launch == .restore && report.kind == .update && report.marker == .valid)
        #expect(report.panes.map(\.outcome) == [.resume, .agentOnTheLine, .agentOnTheLine, .idle])
        #expect(report.panes.map(\.heldBecause) == [[], [.flags], [.sessionFile], []])
        #expect(report.panes.map(\.stop) == [nil, nil, .notFromFile, .noCommand])
        #expect(report.panes.map(\.tab) == [0, 1, 2, 3] && report.panes.allSatisfy { $0.window == 0 })
        #expect(report.panes.map(\.id) == resumable.map(\.id))

        let object = try json(report)
        #expect(object["format"] as? Int == 1 && object["launch"] as? String == "restore")
        #expect(object["restore_kind"] as? String == "update" && object["marker"] as? String == "valid")
        #expect(object["app_version"] as? String == "0.11.61" && object["plan_timed_out"] as? Bool == false)
        #expect(object["written_at"] as? String == ISO8601DateFormatter().string(from: written))
        let listed = try #require(object["panes"] as? [[String: Any]])
        #expect(listed.map { $0["outcome"] as? String } == ["resume", "agent_on_the_line", "agent_on_the_line", "idle"])
        #expect(listed[1]["held_because"] as? [String] == ["flags"] && listed[1]["agent"] as? String == "claude")
        #expect(listed[2]["stopped_before_gate"] as? String == "not_from_file")
        #expect(listed[3]["stopped_before_gate"] as? String == "no_command" && listed[3]["agent"] == nil)
        #expect(listed[0]["pane"] as? String == resumable[0].id.uuidString.lowercased())
        // No line, argument, folder or secret.
        let text = String(decoding: report.data, as: UTF8.self)
        for word in ["--dangerously", "login bug", folder, "--resume", s] {
            #expect(!text.contains(word), "\(word)")
        }
    }

    /// A crash or safe mode stops every agent before the gate, and the report says so; a launch that restored nothing
    /// names no pane, and every marker check has its own word.
    @Test func theReportNamesTheLaunchAndTheMarker() throws {
        let (exact, facts) = exactClaude()
        let shot = snapshot([pane(1, typed("claude"), agent: exact)])
        let crash = RestorePlanner.plan(shot, kind: .crash, world: world(facts: facts))
        let crashed = RestoreReport(decision: updateDecision(.restore(.crash), marker: .missing), snapshot: shot, plans: crash,
                                    planTimedOut: true, appVersion: "1")
        #expect(crashed.panes.map(\.stop) == [.restoreKind] && crashed.panes[0].heldBecause.isEmpty)
        #expect(try json(crashed)["plan_timed_out"] as? Bool == true)
        let safe = RestorePlanner.plan(shot, kind: .update, safeMode: true, world: world(facts: facts))
        let held = RestoreReport(decision: updateDecision(.safeMode(.update)), snapshot: shot, plans: safe, planTimedOut: false, appVersion: "1")
        #expect(held.launch == .safeMode && held.panes.map(\.stop) == [.restoreKind])
        #expect(try json(held)["launch"] as? String == "safe_mode")
        let normal = RestoreReport(decision: updateDecision(.normal, marker: .notAwaited), snapshot: nil, plans: [], planTimedOut: false,
                                   appVersion: "1")
        let object = try json(normal)
        #expect(object["launch"] as? String == "normal" && object["restore_kind"] == nil && object["marker"] as? String == "not_awaited")
        #expect((object["panes"] as? [Any])?.isEmpty == true)
        let checks: [UpdateMarker.Check] = [.valid, .missing, .notAwaited, .consumed, .otherBoot, .stale, .otherVersion]
        #expect(Set(checks.map(\.word)).count == checks.count)
    }

    /// The report is written whole as a private file in the sessions folder, and the next launch's replaces it.
    @Test func theReportIsAPrivateFileTheNextLaunchReplaces() throws {
        let path = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-report-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let files = try SessionFiles.open(in: URL(fileURLWithPath: path), bundlePath: "/Users/x/Applications/Next Term.app")
        #expect(files.lock())
        defer { files.unlock() }
        let first = RestoreReport(launch: .restore, kind: .update, marker: .valid, appVersion: "1", writtenAt: start)
        #expect(first.write(in: files))
        let second = RestoreReport(launch: .normal, kind: nil, marker: .missing, appVersion: "2", writtenAt: start)
        #expect(second.write(in: files))
        let read = try #require(try files.read(RestoreReport.fileName, maxSize: 1 << 20))
        #expect(read == second.data)
        let file = files.url.appendingPathComponent(RestoreReport.fileName).path
        let attributes = try FileManager.default.attributesOfItem(atPath: file)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    // MARK: MCP

    /// list_tabs' `restored` names the checks that held an agent on the line, by their words; a resume or another
    /// outcome names none.
    @Test func restoredDetailsSayWhatHeldTheAgent() throws {
        let (exact, facts) = exactClaude()
        var flagged = exact
        flagged.options = [SessionSnapshot.LaunchOption(["--dangerously-skip-permissions"])]
        flagged.ranPath = "/Users/x/.local/share/claude/2.1.1"
        let held = plan(pane(1, typed("claude"), agent: flagged), world: world(facts: facts))
        var record = pane(1, typed("claude"), agent: flagged)
        record.pending = SessionSnapshot.PendingAction(action: .onTheLine, state: .applied, reason: .update)
        let details = try #require(MCPRestored(plan: held, record: record, since: MCPRestored.Since(commands: 0, beforeInput: nil)))
        #expect(details.fields["outcome"] as? String == "agent_on_the_line" && details.lineHeld)
        #expect(details.fields["held_because"] as? [String] == ["flags", "executable_changed"])
        #expect(details.note?.contains("Held: its launch flags and its program changed since it started.") == true)
        // A resume names none.
        let resumed = plan(pane(1, typed("claude"), agent: exact), world: world(facts: facts))
        var resumedRecord = record
        resumedRecord.pending = SessionSnapshot.PendingAction(action: .resume, state: .applied, reason: .update)
        let ran = MCPRestored(plan: resumed, record: resumedRecord, since: MCPRestored.Since(commands: 1, beforeInput: nil),
                              start: StartWatch.Report(verdict: .resumed))
        #expect(ran?.fields["held_because"] == nil)
    }
}
