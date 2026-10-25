import Foundation
import Testing
@testable import NextTermCore

/// Every agent in one queue (AgentQueue): Needs You first, oldest first, the one on screen left out, each agent once;
/// the rest under their places, This Mac first.
@Suite struct AgentQueueTests {
    func herdr(_ pane: String, _ state: TabState, since: TimeInterval? = nil, place: String = "web-1", tab: String = "T1",
               onScreen: Bool = false, choices: [String] = []) -> AgentQueue.Item {
        AgentQueue.Item(target: .herdr(tab: tab, pane: pane), key: "herdr \(place)\u{0}\(pane)", name: pane, group: place, state: state,
                        words: "\(state)", needsSince: since, onScreen: onScreen, choices: choices)
    }

    func tab(_ id: String, _ state: TabState, since: TimeInterval? = nil, group: String = AgentQueue.thisMac,
             onScreen: Bool = false) -> AgentQueue.Item {
        AgentQueue.Item(target: .tab(id), key: "tab \(id)", name: id, group: group, state: state, words: "\(state)", needsSince: since,
                        onScreen: onScreen)
    }

    @Test func decisionsThenFinishesOldestFirstAndTheOneOnScreenLeftOut() {
        let queue = AgentQueue([
            herdr("w1:p1", .working), herdr("w2:p1", .attention, since: 602), tab("claude", .attention, since: 605),
            herdr("w3:p1", .done, since: 10, place: "web-2"), herdr("w4:p1", .attention, since: 300, onScreen: true), tab("idle", .idle),
        ])
        #expect(queue.needsYou.map(\.name) == ["w2:p1", "claude", "w3:p1"])
        // The rest, under their places: This Mac first, then the hosts as they came; the one on screen with them.
        #expect(queue.groups.map(\.title) == [AgentQueue.thisMac, "web-1"])
        #expect(queue.groups[0].items.map(\.name) == ["idle"] && queue.groups[1].items.map(\.name) == ["w1:p1", "w4:p1"])
        #expect(queue.sections.map(\.title) == [AgentQueue.needsYouTitle, AgentQueue.thisMac, "web-1"])
        // Nothing needs you: no Needs You heading.
        #expect(AgentQueue([tab("idle", .idle)]).sections.map(\.title) == [AgentQueue.thisMac])
    }

    @Test func twoTabsOnOneSessionGiveOneItemPerPane() {
        let queue = AgentQueue([herdr("w1:p1", .done, tab: "T1"), herdr("w1:p1", .done, tab: "T2", onScreen: true), herdr("w1:p2", .idle)])
        #expect(queue.items.count == 2)
        // The agent is on screen in one of the tabs: it is on screen.
        #expect(queue.needsYou.isEmpty && queue.items[0].onScreen)
        // The same pane on another host is another agent.
        #expect(AgentQueue([herdr("w1:p1", .idle), herdr("w1:p1", .idle, place: "web-2")]).items.count == 2)
    }

    @Test func agentsWithNoTimeComeAfterThoseWithOneAndThenAsGiven() {
        let queue = AgentQueue([herdr("a", .attention), herdr("b", .attention, since: 50), herdr("c", .attention), herdr("d", .done, since: 1)])
        #expect(queue.needsYou.map(\.name) == ["b", "a", "c", "d"])
    }

    @Test func theFirstNineShownItemsTakeADigitAndAnItemSaysHowLongItWaited() {
        let items = (0..<12).map { herdr("w1:p\($0)", .idle) }
        let queue = AgentQueue(items)
        #expect(queue.shownItems.count == 12)
        #expect((0..<12).map(AgentQueue.digit) == ["1", "2", "3", "4", "5", "6", "7", "8", "9", nil, nil, nil])
        var codex = herdr("w2:p1", .attention, since: 100)
        codex.name = "codex"
        codex.words = "Needs your decision"
        #expect(codex.menuTitle(now: 100 + 250) == "codex — Needs your decision · waiting 4 min")
        #expect(codex.menuTitle(now: 150) == "codex — Needs your decision" && codex.menuTitle(now: nil) == "codex — Needs your decision")
        var working = herdr("w1:p1", .working)
        working.workSince = 0
        working.words = "Working"
        #expect(working.menuTitle(now: 12 * 60) == "w1:p1 — Working · working 12 min")
    }

    @Test func savedHerdrHostsThatAreNotConnectedAreOneItemEachAndHostsWithNoHerdrTabKeyAsItsTabWould() {
        let hosts: [(id: String, name: String, keep: KeepMode)] = [("h1", "web-1", .herdr), ("h2", "web-2", .tmux), ("h3", "web-3", .herdr)]
        let saved = AgentQueue.notConnected(hosts, connected: ["h1"])
        #expect(saved.map(\.name) == ["web-3"] && saved.first?.target == .saved(id: "h3"))
        #expect(saved.first?.menuTitle(now: nil) == "web-3 — not connected" && saved.first?.group == AgentQueue.notConnected)
        // An agent of a host with no herdr tab and the same agent in a herdr tab of its default session are one.
        let overview = AgentQueue.Item(target: .host(id: "h1", pane: "w1:p1"), key: "herdr h1 \u{0}w1:p1", name: "codex",
                                       group: AgentQueue.noHerdrTab("web-1"), state: .attention, words: "Needs your decision", needsSince: 5)
        let inTab = AgentQueue.Item(target: .herdr(tab: "T", pane: "w1:p1"), key: "herdr h1 \u{0}w1:p1", name: "codex", group: "web-1",
                                    state: .attention, words: "Needs your decision", needsSince: 5)
        let queue = AgentQueue([inTab, overview] + saved)
        #expect(queue.items.count == 2 && queue.needsYou.map(\.target) == [.herdr(tab: "T", pane: "w1:p1")])
        #expect(AgentQueue.noHerdrTab("web-2") == "web-2 (no herdr tab)")
        #expect(queue.groups.map(\.title) == [AgentQueue.notConnected])
    }
}
