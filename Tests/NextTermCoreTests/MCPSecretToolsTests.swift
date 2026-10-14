import Foundation
import Testing
@testable import NextTermCore

/// run_with_secrets' answer for a tab it opened, and what its description tells the agent of that tab: it comes
/// forward as new_tab's does (AgentArrival), and the answer says whether it was selected when it opened.
@Suite struct MCPSecretToolsTests {
    @Test func theAnswerSaysWhetherTheTabWasSelected() {
        let started: [String: Any] = ["status": "started", "approved": "once", "tab_id": "t1"]
        let shown = MCPServer.withArrival(started, selected: true, note: nil)
        #expect(shown["selected"] as? Bool == true && shown["note"] == nil)
        #expect(shown["status"] as? String == "started" && shown["approved"] as? String == "once" && shown["tab_id"] as? String == "t1")
        let behind = MCPServer.withArrival(started, selected: false, note: nil)
        #expect(behind["selected"] as? Bool == false && behind.count == started.count + 1)
    }

    @Test func theArrivalsNoteGoesAfterTheAnswersOwn() {
        let arrival = "Its window is on another Space, so it was not brought forward."
        // An answer with no note of its own takes the arrival's.
        let started = MCPServer.withArrival(["status": "started"], selected: true, note: arrival)
        #expect(started["note"] as? String == arrival)
        // One with a note keeps it first, then the arrival's, one space between.
        let late = MCPServer.withArrival(["status": "refused", "note": "The tab's shell did not start nxtrm within 30 seconds."],
                                         selected: false, note: arrival)
        #expect(late["note"] as? String == "The tab's shell did not start nxtrm within 30 seconds. \(arrival)")
        #expect(late["status"] as? String == "refused" && late["selected"] as? Bool == false)
        // No arrival note: the answer's own note is left as it is.
        let declined = MCPServer.withArrival(["status": "declined", "note": "The user declined."], selected: true, note: nil)
        #expect(declined["note"] as? String == "The user declined.")
    }

    @Test func runWithSecretsSaysItsTabComesForwardAndAnswersSelected() throws {
        let description = try #require(MCPServer.tool(named: "run_with_secrets")).description
        // As new_tab says it (the same setting, the user's window, the keyboard).
        #expect(description.contains("its window comes forward (Settings: agents_bring_tabs_forward)"))
        #expect(description.contains("in the window the user works in it opens behind their tab"))
        #expect(description.contains("never takes the user's keyboard until they click it"))
        // selected, worked out as the tab opened: the user may have chosen it since.
        #expect(description.contains("selected (whether it was the selected tab in its window when it opened)"))
        #expect(!description.contains("opens without taking the keyboard"))
    }

    /// The keys sit in the command's environment, where any program running as the user can read them while it runs:
    /// the description says so, and no longer says "environment only" (review finding #14).
    @Test func runWithSecretsSaysWhoCanReadItsEnvironment() throws {
        let description = try #require(MCPServer.tool(named: "run_with_secrets")).description
        #expect(!description.contains("environment only"))
        #expect(description.contains("in that command's environment, never the tab's shell's"))
        #expect(description.contains("While the command runs, any program running as the user can read that environment"))
    }
}
