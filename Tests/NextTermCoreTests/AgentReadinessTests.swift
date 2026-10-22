import Foundation
import Testing
@testable import NextTermCore

@Suite struct AgentReadinessTests {
    private typealias Tab = AgentReadiness.Tab

    private func agentTab(_ state: TabState = .idle) -> Tab {
        Tab(state: state, agent: .claude, lineHasText: false)
    }

    @Test func eachStateGivesItsReason() {
        #expect(AgentReadiness.check(agentTab(.working)) == .notReady(.working))
        var asking = agentTab(.attention)
        asking.question = "Do you want to make this edit?"
        #expect(AgentReadiness.check(asking) == .notReady(.asking))
        var typed = agentTab()
        typed.lineHasText = true
        #expect(AgentReadiness.check(typed) == .notReady(.hasText))
        #expect(AgentReadiness.check(agentTab(.done)) == .ready)
        #expect(AgentReadiness.check(agentTab(.idle)) == .ready)
        var remote = agentTab()
        remote.remote = true
        #expect(AgentReadiness.check(remote) == .notReady(.remote))
        let shell = Tab(state: .idle, agent: nil, lineHasText: false)
        #expect(AgentReadiness.check(shell) == .notReady(.notAgent))
        var exited = agentTab()
        exited.exited = true
        #expect(AgentReadiness.check(exited) == .notReady(.exited))
        var locked = agentTab()
        locked.locked = true
        #expect(AgentReadiness.check(locked) == .notReady(.locked))
    }

    @Test func busyOrJustSentCountsAsWorking() {
        var busy = agentTab()
        busy.busy = true
        #expect(AgentReadiness.check(busy) == .notReady(.working))
        var starting = agentTab()
        starting.starting = true // input sent 2 s ago, no work seen yet: a second request must not stack on it
        #expect(AgentReadiness.check(starting) == .notReady(.working))
    }

    @Test func aLineInDoubtIsNotReady() {
        let unknown = Tab(state: .idle, agent: .claude, lineHasText: nil)
        #expect(AgentReadiness.check(unknown) == .notReady(.unseenPrompt))
    }

    @Test func herdrIsReadyOnlyWhenIdleOrDoneWithAKnownEmptyLine() {
        var herdr = Tab(state: .idle, agent: nil, lineHasText: nil)
        herdr.herdr = true
        herdr.remote = true
        #expect(AgentReadiness.check(herdr) == .notReady(.unseenPrompt))
        herdr.state = .working
        #expect(AgentReadiness.check(herdr) == .notReady(.working))
        herdr.state = .done
        herdr.lineHasText = false
        #expect(AgentReadiness.check(herdr) == .notReady(.notAgent))
        herdr.agent = .claude
        #expect(AgentReadiness.check(herdr) == .ready)
    }

    @Test func aFailedAgentTabIsNotReady() {
        #expect(AgentReadiness.check(agentTab(.failed)) == .notReady(.unseenPrompt))
    }

    @Test func reasonsReadAsShort() {
        #expect(AgentReadiness.Reason.working.text == "working")
        #expect(AgentReadiness.Reason.hasText.text == "has your text in its prompt")
        #expect(AgentReadiness.Reason.remote.text == "on a server")
        #expect(AgentReadiness.Reason.unseenPrompt.text == "can’t see its prompt")
    }

    // MARK: the watch of each tab's line

    @Test func anAgentTabsLineIsWatchedFromItsFirstWrite() {
        let readiness = AgentReadiness()
        let id = UUID()
        #expect(readiness.lineHasText(id, agentRunning: true, working: false) == false)
        readiness.written(Array("abc".utf8)[...], id: id, agentRunning: true, working: false)
        #expect(readiness.lineHasText(id, agentRunning: true, working: false) == true)
        readiness.written(Array("\r".utf8)[...], id: id, agentRunning: true, working: false)
        #expect(readiness.lineHasText(id, agentRunning: true, working: false) == false)
    }

    @Test func theLineEmptiesWhenTheAgentStartsWorking() {
        let readiness = AgentReadiness()
        let id = UUID()
        readiness.written(Array("abc".utf8)[...], id: id, agentRunning: true, working: false)
        #expect(readiness.lineHasText(id, agentRunning: true, working: true) == false)
        #expect(readiness.lineHasText(id, agentRunning: true, working: false) == false)
    }

    /// Agents let the user type ahead while they work; the draft stays in the prompt when the work ends.
    @Test func textTypedWhileTheAgentWorksOutlastsTheWork() {
        let readiness = AgentReadiness()
        let id = UUID()
        readiness.written(Array("fix tests".utf8)[...], id: id, agentRunning: true, working: true)
        #expect(readiness.lineHasText(id, agentRunning: true, working: false) == true)
        readiness.written(Array("\r".utf8)[...], id: id, agentRunning: true, working: false)
        #expect(readiness.lineHasText(id, agentRunning: true, working: false) == false)
    }

    @Test func closedTabsAreSweptAway() {
        let readiness = AgentReadiness()
        let open = UUID()
        let closed = UUID()
        readiness.written(Array("a".utf8)[...], id: open, agentRunning: true, working: false)
        readiness.written(Array("b".utf8)[...], id: closed, agentRunning: true, working: false)
        readiness.keep(only: [open])
        #expect(readiness.watchedCount == 1)
        #expect(readiness.lineHasText(open, agentRunning: true, working: false) == true)
    }

    @Test func aTabWithNoAgentIsNeitherWatchedNorKnown() {
        let readiness = AgentReadiness()
        let id = UUID()
        readiness.written(Array("abc".utf8)[...], id: id, agentRunning: true, working: false)
        readiness.written(Array("x".utf8)[...], id: id, agentRunning: false, working: false)
        #expect(readiness.watchedCount == 0)
        #expect(readiness.lineHasText(id, agentRunning: false, working: false) == nil)
    }

    /// The hot path: every key in every tab passes here. A tab nothing watches returns after one lookup and a flag,
    /// keeping no state, so a million writes into shells leave nothing behind.
    @Test func anUnwatchedTabCostsNothing() {
        let readiness = AgentReadiness()
        let id = UUID()
        let data: [UInt8] = Array("ls -la\r".utf8)
        for _ in 0..<1_000_000 {
            readiness.written(data[...], id: id, agentRunning: false, working: false)
        }
        #expect(readiness.watchedCount == 0)
    }

    @Test func forgettingATabDropsItsLine() {
        let readiness = AgentReadiness()
        let id = UUID()
        readiness.written(Array("abc".utf8)[...], id: id, agentRunning: true, working: false)
        readiness.forget(id)
        #expect(readiness.watchedCount == 0)
    }
}
