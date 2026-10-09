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
        let planned = MCPServer.planned(fixture.consent())
        let id = fixture.agent.uuidString.lowercased()
        #expect(planned[id] == MCPServer.PlannedTab(outcome: .resume, words: "Claude Code resumes"))
        // AE14: wait_for_tab gets a definite answer, with what the update does to its tab.
        let answer = MCPServer.quitAnswer(tool: "wait_for_tab", arguments: ["tab_id": id.uppercased()], started: true,
                                          update: true, planned: planned)
        #expect(!answer.isError)
        let fields = try #require(try JSONSerialization.jsonObject(with: Data(answer.text.utf8)) as? [String: Any])
        #expect(fields["id"] as? String == id)
        #expect(fields["state"] as? String == "restarting")
        #expect(fields["planned"] as? String == "Claude Code resumes")
        #expect(fields["planned_outcome"] as? String == "resume")
        #expect((fields["note"] as? String)?.contains("restarting for an update") == true)
        // With the box unchecked, the tab closes, and a kept remote tab reattaches.
        let off = MCPServer.planned(fixture.consent(keep: false))
        #expect(off[id] == MCPServer.PlannedTab(outcome: nil, words: "closes"))
        #expect(off[fixture.kept.uuidString.lowercased()] == MCPServer.PlannedTab(outcome: .reattach, words: "reattaches"))
        #expect(off[fixture.ssh.uuidString.lowercased()] == MCPServer.PlannedTab(outcome: nil, words: "connection closes"))
    }

    @Test func everyOtherCallInFlightHearsRestartingAndWhetherItRan() {
        // Posted to the main thread, never run: not run.
        let posted = MCPServer.quitAnswer(tool: "send_to_tab", arguments: ["tab_id": "x"], started: false, update: true, planned: [:])
        #expect(posted.isError && posted.text.contains("restarting for an update") && posted.text.contains("not run"))
        // Begun: what it did stays done.
        let begun = MCPServer.quitAnswer(tool: "answer_agent", arguments: [:], started: true, update: true, planned: [:])
        #expect(begun.isError && begun.text.contains("restarting for an update") && !begun.text.contains("not run"))
        // A request not read yet.
        let unread = MCPServer.quitAnswer(tool: nil, arguments: [:], started: false, update: true, planned: [:])
        #expect(unread.isError && unread.text.contains("restarting for an update"))
        // A wait for a tab the plan does not hold: still restarting, with no planned outcome.
        let unknown = MCPServer.quitAnswer(tool: "wait_for_tab", arguments: ["tab_id": "nope"], started: true, update: true, planned: [:])
        #expect(!unknown.isError && unknown.text.contains("restarting") && !unknown.text.contains("planned_outcome"))
        // Any other quit says Next Term quit, and nothing about an update.
        let quit = MCPServer.quitAnswer(tool: "wait_for_tab", arguments: ["tab_id": "x"], started: true, update: false, planned: [:])
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
        #expect(restored(.update, .idle, action: .applied).shows(commandsRun: 0))
        #expect(!restored(.update, .idle, action: .applied).shows(commandsRun: 1))
        // The resume ran one command: the next is the first after it.
        #expect(restored(.update, .resume, action: .applied).shows(commandsRun: 1))
        #expect(!restored(.update, .resume, action: .applied).shows(commandsRun: 2))
        // A resume the user cancelled by typing first ran nothing of the restore's.
        #expect(!restored(.update, .resume, action: .cancelled).shows(commandsRun: 1))
        // A line put back, then run by the user's Return: that is their first command.
        #expect(!restored(.quit, .commandOnTheLine, action: .applied).shows(commandsRun: 1))
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
            #expect(MCPRestoreGate.refusal(tool: tool, tabID: nil, safeMode: true, waitingFor: nil) == nil, "\(tool)")
        }
        for tool in ["send_to_tab", "new_tab", "open_project", "close_tab", "answer_agent", "write_file", "settings_set"] {
            let refusal = MCPRestoreGate.refusal(tool: tool, tabID: "x", safeMode: true, waitingFor: nil)
            #expect(refusal?.contains("safe mode") == true && refusal?.contains("Try Again") == true, "\(tool)")
        }
        #expect(MCPRestoreGate.refusal(tool: "send_to_tab", tabID: "x", safeMode: false, waitingFor: nil) == nil)
        // A tool it does not know is left to the tools' own answer.
        #expect(MCPRestoreGate.refusal(tool: "no_such_tool", tabID: nil, safeMode: true, waitingFor: nil) == nil)
    }

    /// KTD16: while an update waits for busy tabs, input into a waited tab works, and new work elsewhere is refused with
    /// update_pending until the wait ends.
    @Test func whileAnUpdateWaitsNewWorkElsewhereIsUpdatePending() {
        let waited: Set<String> = ["a"]
        for tool in ["send_to_tab", "press_keys", "answer_agent"] {
            #expect(MCPRestoreGate.refusal(tool: tool, tabID: "A", safeMode: false, waitingFor: waited) == nil, "\(tool)")
            let elsewhere = MCPRestoreGate.refusal(tool: tool, tabID: "b", safeMode: false, waitingFor: waited)
            #expect(elsewhere?.hasPrefix("update_pending") == true, "\(tool)")
        }
        for tool in ["new_tab", "open_project", "new_remote_tab", "split_pane", "write_file"] {
            #expect(MCPRestoreGate.refusal(tool: tool, tabID: nil, safeMode: false, waitingFor: waited)?.hasPrefix("update_pending") == true, "\(tool)")
        }
        // Closing a waited tab or splitting it is new work too.
        #expect(MCPRestoreGate.refusal(tool: "close_tab", tabID: "a", safeMode: false, waitingFor: waited) != nil)
        #expect(MCPRestoreGate.refusal(tool: "split_pane", tabID: "a", safeMode: false, waitingFor: waited) != nil)
        // Reading always works.
        #expect(MCPRestoreGate.refusal(tool: "list_tabs", tabID: nil, safeMode: false, waitingFor: waited) == nil)
        #expect(MCPRestoreGate.refusal(tool: "wait_for_tab", tabID: "b", safeMode: false, waitingFor: waited) == nil)
        // The wait over: nothing refused.
        #expect(MCPRestoreGate.refusal(tool: "new_tab", tabID: nil, safeMode: false, waitingFor: nil) == nil)
    }
}
