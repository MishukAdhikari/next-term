import Foundation
import Testing
@testable import NextTermCore

/// MCP across a restart (plan 003's U13): stale question ids, how `nxtrm mcp` reads a socket that does not answer and
/// when it tries again, the quit's answer to calls in flight, a restored tab's details, and what a restore or an update's
/// wait refuses.
@Suite struct MCPRestartTests {
    // MARK: question ids

    /// AE12: a question asked before the update and the same one after it, in the tab that kept its id, have different
    /// ids, so an answer meant for the old one is refused.
    @Test func aQuestionIDFromBeforeTheRestartNeverMatches() {
        let tab = UUID().uuidString
        let before = AgentScreen.questionID(tab: tab, serial: 1, question: "Allow this edit? (y/n)", nonce: "launch-1")
        let after = AgentScreen.questionID(tab: tab, serial: 1, question: "Allow this edit? (y/n)", nonce: "launch-2")
        #expect(before != after)
        #expect(before == AgentScreen.questionID(tab: tab.lowercased(), serial: 1, question: "Allow this edit? (y/n)", nonce: "launch-1"))
        // Within one launch the id is stable: the default is this launch's nonce, new for each launch.
        let now = AgentScreen.questionID(tab: tab, serial: 1, question: "Q?")
        #expect(now == AgentScreen.questionID(tab: tab, serial: 1, question: "Q?", nonce: AgentScreen.launchNonce))
        #expect(now.hasPrefix("q_") && now.count == 18)
        #expect(!AgentScreen.launchNonce.isEmpty)
    }

    // MARK: the bridge

    @Test func aRefusedSocketOrAnEndWithNoAnswerReadsAsARestart() {
        #expect(MCPServer.SocketFailure(connectError: ECONNREFUSED) == .refused)
        #expect(MCPServer.SocketFailure(connectError: ENOENT) == .missing)
        #expect(MCPServer.SocketFailure(connectError: EACCES) == .unreachable)
        #expect(MCPServer.SocketFailure.refused.meansRestarting)
        #expect(MCPServer.SocketFailure.endedWithoutAnswer.meansRestarting)
        #expect(MCPServer.SocketFailure.notSent.meansRestarting)
        #expect(!MCPServer.SocketFailure.missing.meansRestarting)
        #expect(!MCPServer.SocketFailure.timedOut.meansRestarting)
        // Missing: not running, as before.
        let missing = MCPServer.failedAnswer("list_tabs", .missing, restarting: false)
        #expect(missing.isError && missing.text.contains("not running"))
        let late = MCPServer.failedAnswer("send_to_tab", .timedOut, restarting: false)
        #expect(late.isError && late.text.contains("did not answer in time"))
    }

    @Test func toolsThatOnlyReadAreTriedAgainForAboutTwentySeconds() {
        #expect(MCPServer.restartRetryWindow == 20)
        let interval = MCPServer.restartRetryInterval
        #expect(MCPServer.retryDelay("list_tabs", after: .refused, restarting: false, elapsed: 0) == interval)
        #expect(MCPServer.retryDelay("read_tab", after: .endedWithoutAnswer, restarting: false, elapsed: 5) == interval)
        #expect(MCPServer.retryDelay("wait_for_tab", after: .notSent, restarting: false, elapsed: 1) == interval)
        // The new launch removes the socket file a moment before it listens: still a restart, once one was seen.
        #expect(MCPServer.retryDelay("list_tabs", after: .missing, restarting: true, elapsed: 3) == interval)
        #expect(MCPServer.retryDelay("list_tabs", after: .missing, restarting: false, elapsed: 0) == nil)
        // Not past the window, and never after a timeout, which waited its whole time already.
        #expect(MCPServer.retryDelay("list_tabs", after: .refused, restarting: true, elapsed: 19.8) == nil)
        #expect(MCPServer.retryDelay("list_tabs", after: .timedOut, restarting: true, elapsed: 1) == nil)
        // Given up: it says Next Term did not come back.
        let gaveUp = MCPServer.failedAnswer("list_tabs", .refused, restarting: true)
        #expect(gaveUp.isError && gaveUp.text.contains("restarting") && gaveUp.text.contains("20 seconds"))
    }

    @Test func toolsThatChangeAnythingFailAtOnceAndSayNothingWasSent() {
        for tool in ["send_to_tab", "press_keys", "answer_agent", "new_tab", "close_tab", "open_project"] {
            #expect(MCPServer.retryDelay(tool, after: .refused, restarting: true, elapsed: 0) == nil, "\(tool)")
        }
        // An unknown tool is never tried again either.
        #expect(MCPServer.retryDelay("no_such_tool", after: .refused, restarting: true, elapsed: 0) == nil)
        let refused = MCPServer.failedAnswer("send_to_tab", .refused, restarting: true)
        #expect(refused.isError && refused.text.contains("restarting") && refused.text.contains("nothing was sent"))
        // An update with its box unchecked brings no tab back: no id is promised, only for the tabs it brings back.
        #expect(!refused.text.contains("ids stay the same") && refused.text.contains("brings back keep their ids"))
        let unsent = MCPServer.failedAnswer("press_keys", .notSent, restarting: true)
        #expect(unsent.text.contains("nothing was sent"))
        // The connection ended after the request went in: whether it took effect is not known, and the answer says so.
        let ended = MCPServer.failedAnswer("send_to_tab", .endedWithoutAnswer, restarting: true)
        #expect(ended.isError && ended.text.contains("restarting") && !ended.text.contains("nothing was sent"))
        #expect(ended.text.contains("send_to_tab") && ended.text.contains("list_tabs"))
    }

    // MARK: the quit's answer to calls in flight

    @Test func aWaitInFlightAtTheUpdateQuitHearsRestartingAndItsTabsPlannedOutcome() throws {
        let fixture = UpdateFixture()
        let restart = MCPServer.UpdateRestart(fixture.consent())
        let id = fixture.agent.uuidString.lowercased()
        #expect(restart.bringsTabsBack)
        #expect(restart.planned[id] == MCPServer.PlannedTab(outcome: .resume, words: "Claude Code resumes"))
        // AE14: wait_for_tab gets a definite answer, with what the update does to its tab.
        let answer = MCPServer.quitAnswer(tool: "wait_for_tab", arguments: ["tab_id": id.uppercased()], started: true, update: restart)
        #expect(!answer.isError)
        let fields = try #require(try JSONSerialization.jsonObject(with: Data(answer.text.utf8)) as? [String: Any])
        #expect(fields["id"] as? String == id)
        #expect(fields["state"] as? String == "restarting")
        #expect(fields["planned"] as? String == "Claude Code resumes")
        #expect(fields["planned_outcome"] as? String == "resume")
        let note = try #require(fields["note"] as? String)
        #expect(note.contains("restarting for an update") && note.contains("same id") && note.contains("wait_for_tab again"))
        // With the box unchecked, the tab closes, and a kept remote tab reattaches.
        let off = MCPServer.planned(fixture.consent(keep: false))
        #expect(off[id] == MCPServer.PlannedTab(outcome: nil, words: "closes"))
        #expect(off[fixture.kept.uuidString.lowercased()] == MCPServer.PlannedTab(outcome: .reattach, words: "reattaches"))
        #expect(off[fixture.ssh.uuidString.lowercased()] == MCPServer.PlannedTab(outcome: nil, words: "connection closes"))
    }

    /// With the sheet's box unchecked the relaunch brings no tab back but kept remote ones: the answers say so, and none
    /// of them promises an id that ends.
    @Test func withTheBoxUncheckedNoAnswerPromisesATabComesBack() throws {
        let fixture = UpdateFixture()
        let restart = MCPServer.UpdateRestart(fixture.consent(keep: false))
        #expect(!restart.bringsTabsBack)
        let id = fixture.agent.uuidString.lowercased()
        let waited = MCPServer.quitAnswer(tool: "wait_for_tab", arguments: ["tab_id": id], started: true, update: restart)
        let fields = try #require(try JSONSerialization.jsonObject(with: Data(waited.text.utf8)) as? [String: Any])
        let note = try #require(fields["note"] as? String)
        #expect(fields["planned"] as? String == "closes" && fields["planned_outcome"] == nil)
        #expect(note.contains("does not come back") && !note.contains("same id") && !note.contains("wait_for_tab again"))
        // A kept remote tab reattaches, by its id.
        let kept = fixture.kept.uuidString.lowercased()
        let reattached = MCPServer.quitAnswer(tool: "wait_for_tab", arguments: ["tab_id": kept], started: true, update: restart)
        let keptFields = try #require(try JSONSerialization.jsonObject(with: Data(reattached.text.utf8)) as? [String: Any])
        #expect(keptFields["planned_outcome"] as? String == "reattach" && (keptFields["note"] as? String)?.contains("same id") == true)
        // Any other call, and a wait for a tab the plan does not hold.
        let sent = MCPServer.quitAnswer(tool: "send_to_tab", arguments: ["tab_id": id], started: false, update: restart)
        let listed = MCPServer.quitAnswer(tool: "list_tabs", arguments: [:], started: true, update: restart)
        let unknown = MCPServer.quitAnswer(tool: "wait_for_tab", arguments: ["tab_id": "nope"], started: true, update: restart)
        for answer in [sent, listed, unknown] {
            #expect(answer.text.contains("restarting for an update"), "\(answer.text)")
            #expect(!answer.text.contains("ids stay") && !answer.text.contains("keep their ids") && !answer.text.contains("same id"),
                    "\(answer.text)")
            #expect(answer.text.contains("kept remote tabs"), "\(answer.text)")
        }
        // Checked, the same calls hear that the tabs it brings back keep their ids.
        let on = MCPServer.UpdateRestart(fixture.consent())
        let posted = MCPServer.quitAnswer(tool: "send_to_tab", arguments: ["tab_id": id], started: false, update: on)
        #expect(posted.text.contains("keep their ids"))
        // The instructions promise ids only for the tabs Next Term brings back.
        #expect(!MCPServer.instructions.contains("Tab ids stay the same"))
        #expect(MCPServer.instructions.contains("brings back after an update or a quit keeps its id"))
    }

    @Test func everyOtherCallInFlightHearsRestartingAndWhetherItRan() {
        let restart = MCPServer.UpdateRestart(UpdateFixture().consent())
        // Posted to the main thread, never run: not run.
        let posted = MCPServer.quitAnswer(tool: "send_to_tab", arguments: ["tab_id": "x"], started: false, update: restart)
        #expect(posted.isError && posted.text.contains("restarting for an update") && posted.text.contains("not run"))
        // Begun: what it did stays done.
        let begun = MCPServer.quitAnswer(tool: "answer_agent", arguments: [:], started: true, update: restart)
        #expect(begun.isError && begun.text.contains("restarting for an update") && !begun.text.contains("not run"))
        // A request not read yet.
        let unread = MCPServer.quitAnswer(tool: nil, arguments: [:], started: false, update: restart)
        #expect(unread.isError && unread.text.contains("restarting for an update"))
        // A wait for a tab the plan does not hold: still restarting, with no planned outcome.
        let unknown = MCPServer.quitAnswer(tool: "wait_for_tab", arguments: ["tab_id": "nope"], started: true, update: restart)
        #expect(!unknown.isError && unknown.text.contains("restarting") && !unknown.text.contains("planned_outcome"))
        // Any other quit says Next Term quit, and nothing about an update.
        let quit = MCPServer.quitAnswer(tool: "wait_for_tab", arguments: ["tab_id": "x"], started: true, update: nil)
        #expect(quit.isError && quit.text.contains("Next Term quit") && !quit.text.contains("update"))
    }

    // MARK: restored details

    func restored(_ reason: SessionSnapshot.RestoreKind = .update, _ outcome: RestoreOutcome = .resume,
                  action: SessionSnapshot.ActionState = .applied, held: Bool = false) -> MCPRestored {
        MCPRestored(reason: reason, outcome: outcome, action: action, stateBefore: .working, interrupted: true,
                    note: "Resumed Claude Code session S.", lineHeld: held)
    }

    /// AE10: the worker's tab says it resumed after the update, that it was working before, and that its work was cut off.
    @Test func aRestoredTabSaysWhyWhatAndHowItWasBefore() {
        let fields = restored().fields
        #expect(fields["reason"] as? String == "update")
        #expect(fields["outcome"] as? String == "resume")
        #expect(fields["action"] as? String == "applied")
        #expect(fields["state_before"] as? String == "working")
        #expect(fields["interrupted"] as? Bool == true)
        #expect(fields["note"] as? String == "Resumed Claude Code session S.")
        #expect(fields["line_held"] == nil)
        // Each reason by its word, quit and safe mode included.
        #expect(restored(.quit).fields["reason"] as? String == "quit")
        #expect(restored(.crash).fields["reason"] as? String == "crash")
        #expect(restored(.safeMode).fields["reason"] as? String == "safe_mode")
        // Outcomes in snake case, as MCP's other words are.
        #expect(restored(.update, .agentOnTheLine).fields["outcome"] as? String == "agent_on_the_line")
        #expect(restored(.update, .freshConnection).fields["outcome"] as? String == "fresh_connection")
        // A line still held says so; a pending action has no note yet.
        #expect(restored(.update, .commandOnTheLine, held: true).fields["line_held"] as? Bool == true)
        let pending = restored(.update, .commandOnTheLine, action: .pending).fields
        #expect(pending["action"] as? String == "pending" && pending["note"] == nil)
    }

    /// R24: the details last until the first command after the restore. The shell's first prompt starts none, and the
    /// restore's own resume is not one of the user's.
    @Test func theDetailsLastUntilTheFirstCommandAfterTheRestore() {
        #expect(restored(.update, .idle, action: .applied).shows(commands: 0))
        #expect(!restored(.update, .idle, action: .applied).shows(commands: 1))
        // The resume ran one command: the next is the first after it.
        #expect(restored(.update, .resume, action: .applied).shows(commands: 1))
        #expect(!restored(.update, .resume, action: .applied).shows(commands: 2))
        // A resume the user cancelled by typing first ran nothing of the restore's.
        #expect(!restored(.update, .resume, action: .cancelled).shows(commands: 1))
        // A line put back, then run by the user's Return: that is their first command.
        #expect(!restored(.quit, .commandOnTheLine, action: .applied).shows(commands: 1))
    }

    /// The plan and record of a restored tab, for the details made from them.
    func plan(_ outcome: RestoreOutcome, kind: SessionSnapshot.RestoreKind = .update, remote: Bool = false,
              state: SessionSnapshot.ActionState = .applied) -> (PanePlan, SessionSnapshot.Pane) {
        let id = UUID()
        let agent = outcome == .resume || outcome == .agentOnTheLine
        var note = RestoreNote(outcome: outcome)
        note.agent = agent ? .claude : nil
        note.line = agent ? "claude --resume S" : nil
        note.session = agent ? NamedSession(agent: .claude, id: "S", naming: .exact) : nil
        note.command = outcome == .commandOnTheLine ? "npm run dev" : nil
        note.interrupted = true
        note.afterQuit = kind == .quit
        let line: String? = agent ? "claude --resume S" : (outcome == .commandOnTheLine ? "npm run dev" : nil)
        let plan = PanePlan(pane: id, outcome: outcome, reason: kind, line: line, folder: nil, session: note.session, note: note,
                            listLine: "")
        var record = SessionSnapshot.Pane(id: id, stateBefore: .working, interrupted: true)
        if remote {
            let keep: KeepMode = outcome == .reattach ? .tmux : .off
            record.remote = RemoteTabRecord(hostID: "h1", destination: "sam@web-1.example", directory: "~/app", session: "nt-1", keep: keep)
        }
        record.pending = SessionSnapshot.PendingAction(action: outcome.action, state: state, reason: kind)
        return (plan, record)
    }

    /// R24: an automatic resume ran only when the restore pressed its Return, and the start watch says how it went. One
    /// put on the line instead (its session taken since, or typed over before its Return) says so, its line held until the
    /// user types, and the user's first command after it ends its details.
    @Test func aResumeThatDidNotRunSaysItsLineIsOnThePromptAndEndsAtTheUsersFirstCommand() throws {
        let (resume, record) = plan(.resume)
        func details(_ commands: Int, beforeInput: Int?, _ start: StartWatch.Report? = nil) -> MCPRestored? {
            MCPRestored(plan: resume, record: record, since: MCPRestored.Since(commands: commands, beforeInput: beforeInput), start: start)
        }
        // Ran, and the watch saw it start. It stays a resume through the user's typing into the agent, until the next
        // command.
        let started = StartWatch.Report(verdict: .resumed)
        let ran = try #require(details(1, beforeInput: nil, started))
        #expect(ran.outcome == .resume && ran.fields["outcome"] as? String == "resume" && !ran.lineHeld)
        #expect(ran.note?.hasPrefix("Resumed Claude Code session S.") == true)
        #expect(details(1, beforeInput: 1, started)?.outcome == .resume)
        #expect(details(2, beforeInput: 1, started) == nil)
        // Put back: nothing ran, so the line is on the prompt, the restore's until the user types there.
        let back = try #require(details(0, beforeInput: nil))
        #expect(back.outcome == .agentOnTheLine && back.fields["outcome"] as? String == "agent_on_the_line" && back.lineHeld)
        #expect(back.note?.contains("claude --resume S is back on the line, not run") == true)
        #expect(back.note?.contains("Resumed") == false)
        #expect(back.inputRefusal?.contains("put back") == true)
        // The user typed there: the line is theirs, and their first command ends the details.
        let typed = try #require(details(0, beforeInput: 0))
        #expect(typed.outcome == .agentOnTheLine && !typed.lineHeld && typed.inputRefusal == nil)
        #expect(details(1, beforeInput: 0) == nil)
        // Cancelled by the user's typing before it was typed: nothing of the restore's ran either.
        let (_, cancelledRecord) = plan(.resume, state: .cancelled)
        let cancelled = MCPRestored(plan: resume, record: cancelledRecord, since: MCPRestored.Since(commands: 1, beforeInput: 0))
        #expect(cancelled == nil)
        // Still waiting for its shell: pending, input refused, nothing to tell yet. MCP reads it as pending, a resume
        // planned, never as a resume.
        let (_, waiting) = plan(.resume, state: .pending)
        let pending = try #require(MCPRestored(plan: resume, record: waiting, since: MCPRestored.Since(commands: 0, beforeInput: nil)))
        #expect(pending.outcome == .resume && pending.note == nil && pending.inputRefusal?.contains("being restored") == true)
        #expect(pending.fields["outcome"] as? String == "pending" && pending.fields["planned_outcome"] as? String == "resume")
    }

    /// R26, KTD17, AE31: an automatic resume reads "resume" only once the start watch settles it as resumed. While it
    /// watches, the action is pending and MCP reads "pending": no note, input refused, and the resume's own command,
    /// started, does not end the details. A command started before the verdict does not make it a resume. A failed start
    /// reads as on the line, with the agent's error, its plain resume form held until the user types; a new session as
    /// "new_session", and an agent that ended within the watch with nothing to fall back from as "ended".
    @Test func aResumeReadsResumeOnlyAfterTheStartWatch() throws {
        let (resume, record) = plan(.resume)
        let (_, waiting) = plan(.resume, state: .pending)
        func details(_ record: SessionSnapshot.Pane, _ commands: Int, beforeInput: Int? = nil,
                     _ start: StartWatch.Report?) -> MCPRestored? {
            MCPRestored(plan: resume, record: record, since: MCPRestored.Since(commands: commands, beforeInput: beforeInput), start: start)
        }
        // Watching: its command started, and the action waits for the verdict.
        let watching = try #require(details(waiting, 1, StartWatch.Report(verdict: .watching)))
        #expect(watching.action == .pending && watching.fields["action"] as? String == "pending" && watching.note == nil)
        #expect(watching.fields["outcome"] as? String == "pending" && watching.fields["planned_outcome"] as? String == "resume")
        #expect(watching.fields["note"] == nil && !watching.lineHeld)
        #expect(watching.inputRefusal?.contains("being restored") == true && watching.inputRefusal?.contains("starts") == true)
        // A command started, the action applied, and no verdict: the restore pressed no Return, so that command is not
        // its resume but the first after the restore, which ends the details.
        #expect(details(record, 1, nil) == nil)
        // Resumed: still running at 5 s, or its session file named the session.
        let resumed = try #require(details(record, 1, StartWatch.Report(verdict: .resumed)))
        #expect(resumed.outcome == .resume && resumed.note?.hasPrefix("Resumed Claude Code session S.") == true && !resumed.lineHeld)
        #expect(resumed.fields["outcome"] as? String == "resume" && resumed.fields["planned_outcome"] == nil)
        // Failed at start: on the line, with the agent's error, held until the user types.
        let error = "claude exited at once (status 1): “error: unknown option '--permission-mode'”. The plain resume is back on the line. "
            + "Left off: --permission-mode."
        let failed = StartWatch.Report(verdict: .failedAtStart(status: 1), note: error, lineBack: true)
        let back = try #require(details(record, 1, failed))
        #expect(back.outcome == .agentOnTheLine && back.fields["outcome"] as? String == "agent_on_the_line")
        #expect(back.note == error && back.fields["note"] as? String == error)
        #expect(back.lineHeld && back.fields["line_held"] as? Bool == true && back.inputRefusal?.contains("put back") == true)
        #expect(details(record, 1, beforeInput: 1, failed)?.lineHeld == false)
        // The user runs the plain form: their first command after the restore's ends the details.
        #expect(details(record, 2, beforeInput: 1, failed) == nil)
        // A failure with no line put back (the user typed first, or the tab had its fallback): the note alone.
        let noted = try #require(details(record, 1, StartWatch.Report(verdict: .failedAtStart(status: 1), note: "claude exited at once (status 1).")))
        #expect(noted.outcome == .agentOnTheLine && !noted.lineHeld && noted.note == "claude exited at once (status 1).")
        // A new session: the agent runs, in another session, and the note says so. It is no resume of S.
        let other = "Claude Code started a new session instead of resuming session S."
        let new = try #require(details(record, 1, StartWatch.Report(verdict: .newSession("1f2e3d4c-5b6a-4978-8695-a4b3c2d1e0f9"), note: other)))
        #expect(new.fields["outcome"] as? String == "new_session" && new.note == other && !new.lineHeld)
        // Stopped by the user, ended with status 0, or its shell gone, within the watch: no agent runs, and nothing waits
        // on the line.
        let ended = try #require(details(record, 1, StartWatch.Report(verdict: .leftAsIs)))
        #expect(ended.fields["outcome"] as? String == "ended" && !ended.lineHeld && ended.inputRefusal == nil)
        #expect(ended.note == "The resume of Claude Code session S ended within 5 seconds, so no agent runs in this tab now.")
        #expect(ended.fields["note"] as? String == ended.note)
        // The rule alone: what the restore did, and what MCP reads of it.
        #expect(MCPRestored.outcome(planned: .resume, action: .pending, start: .watching) == .resume)
        #expect(MCPRestored.outcome(planned: .resume, action: .applied, start: .resumed) == .resume)
        #expect(MCPRestored.outcome(planned: .resume, action: .applied, start: .failedAtStart(status: 1)) == .agentOnTheLine)
        #expect(MCPRestored.outcome(planned: .resume, action: .applied, start: .watching) == .agentOnTheLine)
        #expect(MCPRestored.outcome(planned: .resume, action: .applied, start: nil) == .agentOnTheLine)
        let readings: [(RestoreOutcome?, SessionSnapshot.ActionState, StartWatch.Verdict?, String)] = [
            (.resume, .pending, nil, "pending"),
            (.resume, .pending, .watching, "pending"),
            (.resume, .applied, .resumed, "resume"),
            (.resume, .applied, .newSession("1f2e3d4c-5b6a-4978-8695-a4b3c2d1e0f9"), "new_session"),
            (.resume, .applied, .leftAsIs, "ended"),
            (.agentOnTheLine, .applied, .failedAtStart(status: 1), "agent_on_the_line"),
            (.agentOnTheLine, .applied, nil, "agent_on_the_line"),
            (.commandOnTheLine, .pending, nil, "command_on_the_line"),
            (nil, .cancelled, nil, "cancelled"),
        ]
        for (outcome, action, start, word) in readings {
            let read = MCPRestored.reading(outcome, action: action, start: start)
            #expect(read == word, "\(String(describing: outcome)) \(action) \(String(describing: start)): \(read)")
        }
        // Its own command counts: the next one ends the details, whatever the verdict.
        #expect(details(waiting, 2, StartWatch.Report(verdict: .watching)) == nil)
        #expect(details(record, 2, StartWatch.Report(verdict: .resumed)) == nil)
    }

    /// R24: an action that types was cancelled when something reached the tab's line before its shell was ready, so the
    /// restore typed nothing there. Its details say so, until the first command after the restore: never that the agent
    /// resumed, nor that a line waits on the prompt.
    @Test func anActionCancelledBeforeItTypedSaysItWasCancelledAndNothingWasTyped() throws {
        let typedFirst = "something was typed in the tab before its shell was ready"
        func cancelled(_ outcome: RestoreOutcome, _ commands: Int = 0) -> MCPRestored? {
            let (plan, record) = plan(outcome, state: .cancelled)
            return MCPRestored(plan: plan, record: record, since: MCPRestored.Since(commands: commands, beforeInput: 0))
        }
        // An automatic resume the user typed over before it was typed: it never ran.
        let resume = try #require(cancelled(.resume))
        #expect(resume.outcome == nil && resume.fields["outcome"] as? String == "cancelled")
        #expect(resume.fields["action"] as? String == "cancelled")
        #expect(resume.note == "Claude Code session S did not resume: \(typedFirst). Its last turn was cut off by the update. "
            + "To resume it, type: claude --resume S")
        #expect(resume.fields["note"] as? String == resume.note)
        #expect(!resume.lineHeld && resume.fields["line_held"] == nil && resume.inputRefusal == nil)
        // The user's first command ends the details, as after any restore that ran nothing of its own.
        #expect(cancelled(.resume, 1) == nil)
        // A resume command, or a command, that was to go back on the line: nothing was put there.
        let line = try #require(cancelled(.agentOnTheLine))
        #expect(line.outcome == nil && line.fields["outcome"] as? String == "cancelled")
        #expect(line.note == "Claude Code was running. Its line was not put back: \(typedFirst). To resume it, type: claude --resume S")
        let command = try #require(cancelled(.commandOnTheLine))
        #expect(command.outcome == nil && command.fields["outcome"] as? String == "cancelled" && !command.lineHeld)
        #expect(command.note == "npm run dev was running. It was not put back: \(typedFirst).")
        for each in [resume, line, command] {
            #expect(each.note?.contains("Resumed") == false && each.note?.contains("back on the line") == false)
            #expect(each.inputRefusal == nil)
        }
        // After a quit the cut-off turn names the quit.
        let (quitPlan, quitRecord) = plan(.resume, kind: .quit, state: .cancelled)
        let quit = try #require(MCPRestored(plan: quitPlan, record: quitRecord, since: MCPRestored.Since(commands: 0, beforeInput: 0)))
        #expect(quit.fields["reason"] as? String == "quit" && quit.note?.contains("cut off by the quit") == true)
        // An outcome whose action types nothing keeps its own, whatever its state.
        #expect(MCPRestored.outcome(planned: .idle, action: .cancelled) == .idle)
        #expect(MCPRestored.outcome(planned: .reattach, action: .cancelled) == .reattach)
        // Every action that types, cancelled, did nothing; applied, it did what it says.
        for planned in [RestoreOutcome.resume, .agentOnTheLine, .commandOnTheLine] {
            #expect(MCPRestored.outcome(planned: planned, action: .cancelled) == nil, "\(planned)")
        }
        #expect(MCPRestored.outcome(planned: .agentOnTheLine, action: .applied) == .agentOnTheLine)
        #expect(MCPRestored.outcome(planned: .commandOnTheLine, action: .applied) == .commandOnTheLine)
    }

    /// R24 on a server: a remote tab has no shell integration, so what it counts comes from what the host reports in
    /// front. A tab tmux or herdr kept reattaches with its program still in front, which nobody started after the restore:
    /// its details last until a command starts at the host's prompt.
    @Test func aReattachedRemoteTabKeepsItsDetailsThroughTheProgramInFront() throws {
        let npm = ForegroundProcess(isShell: false, name: "npm", arguments: ["npm", "run", "dev"])
        let node = ForegroundProcess(isShell: false, name: "node", arguments: ["node", "server.js"])
        let shell = ForegroundProcess(isShell: true, name: "zsh")
        let ls = ForegroundProcess(isShell: false, name: "ls", arguments: ["ls"])
        let (reattach, record) = plan(.reattach, remote: true)
        func details(_ status: TabStatus) -> MCPRestored? {
            MCPRestored(plan: reattach, record: record, since: MCPRestored.Since(commands: status.commandsAtPrompt, beforeInput: nil))
        }
        // tmux kept `npm run dev` running: the host reports it in front, then another of its processes.
        var tmux = TabStatus()
        tmux.observe(npm, at: 1)
        tmux.observe(node, at: 2)
        #expect(tmux.commandsRun == 2 && tmux.commandsAtPrompt == 0)
        #expect(details(tmux)?.outcome == .reattach)
        // Stopped, at its prompt: still the restore's. Then a command started there ends the details.
        tmux.observe(shell, at: 3)
        #expect(details(tmux) != nil)
        tmux.observe(ls, at: 4)
        #expect(tmux.commandsAtPrompt == 1 && details(tmux) == nil)
        // herdr: the tab shows herdr from its first report, never a command anyone ran.
        var herdr = TabStatus()
        herdr.observeAgentHost("herdr", at: 1)
        #expect(herdr.commandsRun == 1 && herdr.commandsAtPrompt == 0 && details(herdr) != nil)
        // A plain ssh tab comes back as a fresh connection at its prompt: its first command ends them.
        let (fresh, freshRecord) = plan(.freshConnection, remote: true)
        var ssh = TabStatus()
        ssh.observe(shell, at: 1)
        let before = MCPRestored(plan: fresh, record: freshRecord, since: MCPRestored.Since(commands: ssh.commandsAtPrompt, beforeInput: nil))
        ssh.observe(ls, at: 2)
        let after = MCPRestored(plan: fresh, record: freshRecord, since: MCPRestored.Since(commands: ssh.commandsAtPrompt, beforeInput: nil))
        #expect(before?.outcome == .freshConnection && !before!.lineHeld && after == nil)
    }

    /// With the integration, the commands at the prompt are those after it first reported in, as `commandsRun` counts
    /// them: what polling caught while the shell started is not one.
    @Test func withTheIntegrationTheCommandsAtThePromptAreThoseRunAfterItReported() {
        var status = TabStatus()
        status.observe(ForegroundProcess(isShell: true, name: "zsh"), at: 0)
        status.observe(ForegroundProcess(isShell: false, name: "git", arguments: ["git", "status"]), at: 0.5)
        status.commandFinished(exitCode: 0, at: 1) // the first prompt reports in
        #expect(status.commandsRun == 0 && status.commandsAtPrompt == 0)
        status.commandStarted("true", at: 2)
        #expect(status.commandsRun == 1 && status.commandsAtPrompt == 1)
        // Nothing seen yet: no command.
        #expect(TabStatus().commandsAtPrompt == 0)
    }

    // MARK: refusals

    /// AE11 and R25: input is refused while the tab's action waits, and while its prompt holds the line put back, unrun,
    /// until the user types there.
    @Test func inputIntoAPendingOrPutBackTabIsRefusedUntilTheUserTypes() {
        func held(_ action: SessionSnapshot.Action, _ state: SessionSnapshot.ActionState, typed: Bool = false, run: Int = 0) -> Bool {
            MCPRestored.lineHeld(action: action, state: state, userTyped: typed, commandsRun: run)
        }
        #expect(held(.typeIn, .applied))
        #expect(held(.onTheLine, .applied))
        #expect(!held(.typeIn, .applied, typed: true)) // one keystroke from the user: the line is theirs
        #expect(!held(.typeIn, .applied, run: 1)) // run since
        #expect(!held(.typeIn, .pending)) // not typed yet: refused as pending instead
        #expect(!held(.typeIn, .dismissed)) // timed out: nothing typed
        #expect(!held(.typeIn, .cancelled))
        #expect(!held(.note, .applied))
        // A resume that ran started its command; one that found its session taken was put back instead.
        #expect(!held(.resume, .applied, run: 1))
        #expect(held(.resume, .applied, run: 0))

        let pending = restored(.update, .commandOnTheLine, action: .pending).inputRefusal
        #expect(pending?.contains("restored") == true && pending?.contains("Nothing was typed") == true)
        let back = restored(.update, .commandOnTheLine, held: true).inputRefusal
        #expect(back?.contains("put back") == true && back?.contains("type") == true)
        #expect(restored(.update, .commandOnTheLine).inputRefusal == nil)
        // A resume that ran is the worker an orchestrator drives (KTD19): input works.
        #expect(restored(.update, .resume).inputRefusal == nil)
        // A note types nothing, so nothing waits.
        #expect(restored(.crash, .idle, action: .pending).inputRefusal == nil)
        #expect(restored(.update, .reattach, action: .pending).inputRefusal == nil)
    }

    @Test func safeModeRunsOnlyToolsThatRead() {
        for tool in ["list_tabs", "read_tab", "wait_for_tab", "read_file", "get_diff", "list_projects"] {
            #expect(MCPRestoreGate.refusal(tool: tool, tabID: nil, followUp: false, safeMode: true, waitingFor: nil) == nil, "\(tool)")
        }
        for tool in ["send_to_tab", "new_tab", "open_project", "close_tab", "answer_agent", "write_file", "settings_set"] {
            let refusal = MCPRestoreGate.refusal(tool: tool, tabID: "x", followUp: false, safeMode: true, waitingFor: nil)
            #expect(refusal?.contains("safe mode") == true && refusal?.contains("Try Again") == true, "\(tool)")
        }
        #expect(MCPRestoreGate.refusal(tool: "send_to_tab", tabID: "x", followUp: false, safeMode: false, waitingFor: nil) == nil)
        // A tool it does not know is left to the tools' own answer.
        #expect(MCPRestoreGate.refusal(tool: "no_such_tool", tabID: nil, followUp: false, safeMode: true, waitingFor: nil) == nil)
    }

    /// KTD16: while an update waits for busy tabs, input into a waited tab works, and new work elsewhere is refused with
    /// update_pending until the wait ends.
    @Test func whileAnUpdateWaitsNewWorkElsewhereIsUpdatePending() {
        let waited: Set<String> = ["a"]
        for tool in ["send_to_tab", "press_keys", "answer_agent"] {
            #expect(MCPRestoreGate.refusal(tool: tool, tabID: "A", followUp: false, safeMode: false, waitingFor: waited) == nil, "\(tool)")
            let elsewhere = MCPRestoreGate.refusal(tool: tool, tabID: "b", followUp: false, safeMode: false, waitingFor: waited)
            #expect(elsewhere?.hasPrefix("update_pending") == true, "\(tool)")
        }
        for tool in ["new_tab", "open_project", "new_remote_tab", "split_pane", "write_file"] {
            #expect(MCPRestoreGate.refusal(tool: tool, tabID: nil, followUp: false, safeMode: false, waitingFor: waited)?.hasPrefix("update_pending") == true, "\(tool)")
        }
        // Closing a waited tab or splitting it is new work too.
        #expect(MCPRestoreGate.refusal(tool: "close_tab", tabID: "a", followUp: false, safeMode: false, waitingFor: waited) != nil)
        #expect(MCPRestoreGate.refusal(tool: "split_pane", tabID: "a", followUp: false, safeMode: false, waitingFor: waited) != nil)
        // Reading always works.
        #expect(MCPRestoreGate.refusal(tool: "list_tabs", tabID: nil, followUp: false, safeMode: false, waitingFor: waited) == nil)
        #expect(MCPRestoreGate.refusal(tool: "wait_for_tab", tabID: "b", followUp: false, safeMode: false, waitingFor: waited) == nil)
        // The wait over: nothing refused.
        #expect(MCPRestoreGate.refusal(tool: "new_tab", tabID: nil, followUp: false, safeMode: false, waitingFor: nil) == nil)
        // The refusal says where to look, and promises ids only for the tabs the update brings back.
        let refusal = MCPRestoreGate.refusal(tool: "new_tab", tabID: nil, followUp: false, safeMode: false, waitingFor: waited) ?? ""
        #expect(refusal.contains("update_wait") && !refusal.contains("Tab ids stay the same"))
    }

    /// KTD16: a call that only asks again for the answer to a request already open (propose_edit with proposal_id;
    /// install_skill, remove_skill, apply_import or undo_import with request_id) starts nothing, so the wait lets it through.
    /// Every other call that changes something is still new work.
    @Test func whileAnUpdateWaitsAFollowUpOnAnOpenRequestStillWorks() {
        let waited: Set<String> = ["a"]
        for tool in ["propose_edit", "install_skill", "remove_skill", "apply_import", "undo_import"] {
            #expect(MCPRestoreGate.refusal(tool: tool, tabID: nil, followUp: true, safeMode: false, waitingFor: waited) == nil, "\(tool)")
            let asked = MCPRestoreGate.refusal(tool: tool, tabID: nil, followUp: false, safeMode: false, waitingFor: waited)
            #expect(asked?.hasPrefix("update_pending") == true, "\(tool)")
        }
        #expect(MCPRestoreGate.refusal(tool: "write_file", tabID: nil, followUp: false, safeMode: false, waitingFor: waited)?.hasPrefix("update_pending") == true)
        // Safe mode runs only the tools that read, follow-ups included.
        #expect(MCPRestoreGate.refusal(tool: "propose_edit", tabID: nil, followUp: true, safeMode: true, waitingFor: nil) != nil)

        // A follow-up is told as the handlers tell it: a non-empty id, whatever else the call gives.
        #expect(MCPRestoreGate.isFollowUp("propose_edit", ["proposal_id": "P1"]))
        #expect(MCPRestoreGate.isFollowUp("propose_edit", ["proposal_id": "p1", "path": "a.txt", "content": "x"]))
        #expect(!MCPRestoreGate.isFollowUp("propose_edit", ["proposal_id": "", "path": "a.txt", "content": "x"]))
        #expect(!MCPRestoreGate.isFollowUp("propose_edit", ["request_id": "r1"]))
        for tool in ["install_skill", "remove_skill", "apply_import", "undo_import"] {
            #expect(MCPRestoreGate.isFollowUp(tool, ["request_id": "r1"]), "\(tool)")
            #expect(MCPRestoreGate.isFollowUp(tool, ["request_id": "r1", "source": "x"]), "\(tool)")
            #expect(!MCPRestoreGate.isFollowUp(tool, ["source": "x"]), "\(tool)")
            #expect(!MCPRestoreGate.isFollowUp(tool, ["request_id": " "]), "\(tool)")
            #expect(!MCPRestoreGate.isFollowUp(tool, ["proposal_id": "p1"]), "\(tool)")
        }
        // An id on any other tool is new work.
        #expect(!MCPRestoreGate.isFollowUp("write_file", ["request_id": "r1"]))
        #expect(!MCPRestoreGate.isFollowUp("new_tab", ["proposal_id": "p1"]))
    }

    /// KTD16: list_tabs reports the wait. Each tab says whether the update waits for it, where input still works, or holds
    /// new work back; with no wait, nothing.
    @Test func whileAnUpdateWaitsEachTabSaysWhetherItIsWaitedFor() {
        let waited: Set<String> = ["a"]
        #expect(MCPRestoreGate.waitFields(tabID: "A", waitingFor: waited)["update_wait"] as? String == "waits_for_this_tab")
        #expect(MCPRestoreGate.waitFields(tabID: "b", waitingFor: waited)["update_wait"] as? String == "update_pending")
        #expect(MCPRestoreGate.waitFields(tabID: "a", waitingFor: nil).isEmpty)
    }

    // MARK: the calls the quit drains

    /// A connected pair: the serving end, and the caller's.
    func socketPair() throws -> (served: Int32, caller: Int32) {
        var fds: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return (fds[0], fds[1])
    }

    /// The drain's answer in these tests: what it knew of the call.
    static func drained(_ request: MCPCalls.Request?, _ started: Bool) -> MCPServer.CallResult {
        MCPServer.CallResult(text: "drained \(request?.tool ?? "unread") \(started)", isError: true)
    }

    /// R26: a request still being read as the quit drains is answered at once: its read ends, rather than after the read's
    /// own 10 seconds.
    @Test func aRequestStillBeingReadAtTheDrainIsAnsweredAtOnce() throws {
        let calls = MCPCalls()
        let pair = try socketPair()
        defer { Darwin.close(pair.caller) }
        let call = calls.begin(pair.served)
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(pair.served, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = write(pair.caller, "{\"tool\"", 7) // half a request
        let ended = DispatchSemaphore(value: 0)
        let reader = Thread {
            var buffer = [UInt8](repeating: 0, count: 64)
            while read(pair.served, &buffer, buffer.count) > 0 {}
            ended.signal()
            calls.end(call)
        }
        reader.start()
        Thread.sleep(forTimeInterval: 0.2)
        let started = Date()
        calls.drain(wait: 5, answer: Self.drained)
        #expect(ended.wait(timeout: .now()) == .success)
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(call.answer?.text == "drained unread false")
    }

    /// R26: a connection accepted just before the socket stopped listening, which begins while the drain waits, is
    /// answered at once.
    @Test func aCallThatBeginsWhileTheDrainWaitsIsAnsweredAtOnce() throws {
        let calls = MCPCalls()
        let first = try socketPair()
        let second = try socketPair()
        defer { [first.caller, second.caller].forEach { Darwin.close($0) } }
        let open = calls.begin(first.served)
        _ = open.asked(MCPCalls.Request(tool: "wait_for_tab", arguments: [:]))
        #expect(open.starts())
        let done = DispatchSemaphore(value: 0)
        Thread {
            calls.drain(wait: 5, answer: MCPRestartTests.drained)
            done.signal()
        }.start()
        Thread.sleep(forTimeInterval: 0.2)
        #expect(open.answer?.text == "drained wait_for_tab true")
        let late = calls.begin(second.served)
        #expect(late.answer?.text == "drained unread false")
        #expect(!late.starts())
        calls.end(open)
        calls.end(late)
        #expect(done.wait(timeout: .now() + 2) == .success)
        // The drain over, a server started again serves as before.
        let third = try socketPair()
        defer { Darwin.close(third.caller) }
        let next = calls.begin(third.served)
        #expect(next.answer == nil && next.asked(MCPCalls.Request(tool: "list_tabs", arguments: [:])) && next.starts())
        calls.end(next)
    }

    /// R26: a call posted to the main thread that the drain answered first never runs, and a tool's answer after the
    /// drain's is dropped.
    @Test func aPostedCallTheDrainAnsweredNeverRuns() throws {
        let calls = MCPCalls()
        let pair = try socketPair()
        defer { Darwin.close(pair.caller) }
        let call = calls.begin(pair.served)
        #expect(call.asked(MCPCalls.Request(tool: "send_to_tab", arguments: ["tab_id": "x"])))
        let done = DispatchSemaphore(value: 0)
        Thread {
            calls.drain(wait: 5, answer: MCPRestartTests.drained)
            done.signal()
        }.start()
        Thread.sleep(forTimeInterval: 0.2)
        #expect(!call.starts())
        call.finish(MCPServer.CallResult(text: "the tool's"))
        #expect(call.answer?.text == "drained send_to_tab false")
        calls.end(call)
        #expect(done.wait(timeout: .now() + 2) == .success)
    }

    /// `nxtrm secret run`'s request answers itself on its connection (SecretSocket): the drain gives it no answer, never
    /// stops its reading (which the wrapper's wait would read as the wrapper leaving), and doesn't wait for it, since its
    /// answer comes from the main thread the quit holds. Its connection closes once, as its call ends.
    @Test func aCallThatAnswersItselfIsLeftBeByTheDrain() throws {
        let calls = MCPCalls()
        let pair = try socketPair()
        defer { Darwin.close(pair.caller) }
        let call = calls.begin(pair.served)
        #expect(calls.answersItself(call))
        let started = Date()
        calls.drain(wait: 5, answer: Self.drained)
        #expect(Date().timeIntervalSince(started) < 1, "the drain doesn't wait for it")
        #expect(call.answer == nil)
        var byte: UInt8 = 0
        let peeked = recv(pair.served, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        let peekError = errno
        #expect(peeked < 0 && peekError == EAGAIN, "still open for reading: the wrapper hasn't left")
        _ = write(pair.caller, "x", 1)
        #expect(recv(pair.served, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 1)
        calls.end(call)
        let flags = fcntl(pair.served, F_GETFD)
        let flagsError = errno
        #expect(flags < 0 && flagsError == EBADF, "closed as its call ended")
        // A second end closes nothing: not a descriptor another connection was given since.
        let reused = try socketPair()
        defer { [reused.served, reused.caller].forEach { Darwin.close($0) } }
        calls.end(call)
        #expect(fcntl(reused.served, F_GETFD) >= 0 && fcntl(reused.caller, F_GETFD) >= 0)
    }

    /// A call the drain answered before its request was read as `nxtrm secret run`'s can't answer itself: nothing more
    /// is written to it, and the wrapper reads the closed connection.
    @Test func aCallTheDrainAnsweredFirstCantAnswerItself() throws {
        let calls = MCPCalls()
        let pair = try socketPair()
        defer { Darwin.close(pair.caller) }
        let call = calls.begin(pair.served)
        let done = DispatchSemaphore(value: 0)
        Thread {
            calls.drain(wait: 5, answer: MCPRestartTests.drained)
            done.signal()
        }.start()
        Thread.sleep(forTimeInterval: 0.2)
        #expect(!calls.answersItself(call))
        #expect(call.answer?.text == "drained unread false")
        calls.end(call)
        #expect(done.wait(timeout: .now() + 2) == .success)
        // One that begins while a drain waits is answered at once, so it can't either.
        let late = try socketPair()
        defer { Darwin.close(late.caller) }
        let other = try socketPair()
        defer { Darwin.close(other.caller) }
        let open = calls.begin(other.served)
        Thread {
            calls.drain(wait: 5, answer: MCPRestartTests.drained)
            done.signal()
        }.start()
        Thread.sleep(forTimeInterval: 0.2)
        let lateCall = calls.begin(late.served)
        #expect(!calls.answersItself(lateCall))
        calls.end(lateCall)
        calls.end(open)
        #expect(done.wait(timeout: .now() + 2) == .success)
    }

    // MARK: the socket

    /// KTD17: a process the app starts (a tab's shell, and what runs on in it after the quit) never holds the app's
    /// listener. Once the app closes its own, at an update's drain that keeps the file, a connect there is refused, which
    /// `nxtrm mcp` reads as a restart, and the next launch finds nothing answering, so it listens there again.
    @Test func aProcessTheAppStartsNeverKeepsItsSocketListening() throws {
        let path = FileManager.default.temporaryDirectory.path + "/nt-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path) }
        let listener = MCPSocket.listen(path: path)
        try #require(listener >= 0)
        #expect(DescriptorSweep.isCloseOnExec(listener))
        var info = stat()
        #expect(lstat(path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        // A connection, and the app's end of it, are not handed on either.
        let caller = MCPSocket.connect(path: path)
        try #require(caller >= 0)
        let served = MCPSocket.accept(listener)
        #expect(served >= 0 && DescriptorSweep.isCloseOnExec(served) && DescriptorSweep.isCloseOnExec(caller))
        [caller, served].filter { $0 >= 0 }.forEach { Darwin.close($0) }

        // Started with nothing closed before its program runs, as forkpty and execve start a tab's shell.
        var pid: pid_t = 0
        let command: [String] = ["/bin/sleep", "5"]
        let words: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
        defer { words.forEach { free($0) } }
        try #require(posix_spawn(&pid, "/bin/sleep", nil, nil, words, nil) == 0)
        defer {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        Darwin.close(listener) // the drain: the app's copy goes, the file stays
        let late = MCPSocket.connect(path: path)
        let code = errno
        if late >= 0 { Darwin.close(late) }
        #expect(late < 0 && code == ECONNREFUSED, "a connect after the drain is refused, not left waiting in the child's listener")
        #expect(MCPServer.SocketFailure(connectError: code) == .refused)
    }
}
