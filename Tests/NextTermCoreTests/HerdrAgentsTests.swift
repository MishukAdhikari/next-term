import Foundation
import Testing
@testable import NextTermCore

/// Each of herdr's agents followed on its own across the status checks (HerdrAgents), from hand-written stand-ins of
/// herdr 0.9.1's, 0.9.4's and 0.9.5's lists.
@Suite struct HerdrAgentsTests {
    func fixture(_ name: String) throws -> [HerdrAgent] {
        let text = try String(contentsOf: HerdrListingTests.fixtures.appendingPathComponent(name), encoding: .utf8)
        return try #require(HerdrAgent.parseList(text))
    }

    func agent(_ pane: String, _ status: HerdrAgent.Status, tab: String = "w1:t1", seq: Int? = nil, done: Int? = nil,
               kind: String = "claude", name: String? = nil, focused: Bool = false, title: String? = nil,
               directory: String? = nil) -> HerdrAgent {
        HerdrAgent(paneID: pane, customName: name, kind: kind, status: status, title: title, directory: directory, tabID: tab,
                   focused: focused, stateSeq: seq, completionSeq: done)
    }

    @Test func workNextTermSawFinishesAfterFiveSeconds() {
        var agents = HerdrAgents()
        #expect(agents.update([agent("w1:p1", .idle)], focusedTab: nil, tabVisible: false, now: 0).isEmpty)
        _ = agents.update([agent("w1:p1", .working)], focusedTab: nil, tabVisible: false, now: 2)
        _ = agents.update([agent("w1:p1", .working)], focusedTab: nil, tabVisible: false, now: 4)
        #expect(agents.update([agent("w1:p1", .done)], focusedTab: nil, tabVisible: false, now: 8) == [.finished(pane: "w1:p1", duration: 6)])
        // Work shorter than that is no news: the row still shows done.
        _ = agents.update([agent("w1:p1", .working)], focusedTab: nil, tabVisible: false, now: 10)
        #expect(agents.update([agent("w1:p1", .done)], focusedTab: nil, tabVisible: false, now: 13).isEmpty)
        #expect(agents.rows.first?.state == .done)
        // Finished as the user watched it (idle, on screen): herdr took it as seen, and so does Next Term.
        _ = agents.update([agent("w1:p1", .working)], focusedTab: nil, tabVisible: true, now: 20)
        #expect(agents.update([agent("w1:p1", .idle)], focusedTab: nil, tabVisible: true, now: 40).isEmpty)
        #expect(!agents.isUnread("w1:p1"))
    }

    @Test func aTurnThatEndsAsIdleOffScreenIsAFinishKeptUnread() {
        var agents = HerdrAgents()
        // claude works in herdr's focused pane; the user went to another app, so the tab is off screen.
        _ = agents.update([agent("w1:p1", .working, focused: true)], focusedTab: nil, tabVisible: false, now: 0)
        _ = agents.update([agent("w1:p1", .working, focused: true)], focusedTab: nil, tabVisible: false, now: 30)
        // herdr says idle anyway (another client saw it, or an older herdr): a finish, and Next Term keeps it unread.
        #expect(agents.update([agent("w1:p1", .idle, focused: true)], focusedTab: nil, tabVisible: false, now: 40)
            == [.finished(pane: "w1:p1", duration: 40)])
        #expect(agents.isUnread("w1:p1") && agents.needsYou == ["w1:p1"] && agents.rows[0].state == .done && agents.rows[0].unread)
        #expect(agents.needsSince("w1:p1") == 40)
        // Still idle: it stays so, from the same time.
        _ = agents.update([agent("w1:p1", .idle, focused: true)], focusedTab: nil, tabVisible: false, now: 42)
        #expect(agents.isUnread("w1:p1") && agents.needsSince("w1:p1") == 40)
        // The user chose it: seen.
        agents.seen("w1:p1")
        #expect(!agents.isUnread("w1:p1") && agents.needsYou.isEmpty && agents.needsSince("w1:p1") == nil)
        // Kept unread again, then herdr reports it at work: herdr's news is newer.
        agents.markUnread("w1:p1", now: 50)
        #expect(agents.isUnread("w1:p1") && agents.needsSince("w1:p1") == 50)
        #expect(agents.update([agent("w1:p1", .working, focused: true)], focusedTab: nil, tabVisible: false, now: 52) == [.resolved(pane: "w1:p1")])
        #expect(!agents.isUnread("w1:p1"))
        // Nothing working or blocked is kept unread by hand.
        agents.markUnread("w1:p1", now: 53)
        #expect(!agents.isUnread("w1:p1"))
    }

    @Test func anAgentThatReadsUnknownAtRestFinishes() {
        var agents = HerdrAgents()
        _ = agents.update([agent("w1:p1", .working, kind: "codex")], focusedTab: nil, tabVisible: true, now: 0)
        _ = agents.update([agent("w1:p1", .working, kind: "codex")], focusedTab: nil, tabVisible: true, now: 28)
        #expect(agents.update([agent("w1:p1", .unknown, kind: "codex")], focusedTab: nil, tabVisible: true, now: 30)
            == [.finished(pane: "w1:p1", duration: 30)])
        #expect(agents.isUnread("w1:p1"))
        // Unknown again with nothing new: no second finish.
        #expect(agents.update([agent("w1:p1", .unknown, kind: "codex")], focusedTab: nil, tabVisible: true, now: 32).isEmpty)
    }

    @Test func herdrsCountsSayATurnEndedBetweenTwoChecks() throws {
        var agents = HerdrAgents()
        _ = agents.update([agent("w1:p1", .idle, seq: 1, done: 3)], focusedTab: nil, tabVisible: false, now: 0)
        #expect(agents.update([agent("w1:p1", .done, seq: 3, done: 4)], focusedTab: nil, tabVisible: false, now: 2)
            == [.finished(pane: "w1:p1", duration: nil)])
        #expect(!agents.isUnread("w1:p1")) // herdr shows it as done itself
        // herdr 0.9.1 has no count of turns: its state changed twice, from idle to idle, off screen.
        var older = HerdrAgents()
        _ = older.update(try fixture("agent-list-seq-jump-before.json"), focusedTab: nil, tabVisible: false, now: 0)
        #expect(older.update(try fixture("agent-list-seq-jump-after.json"), focusedTab: nil, tabVisible: false, now: 2)
            == [.finished(pane: "w1:p1", duration: nil)])
        #expect(older.isUnread("w1:p1"))
        // Once is not a turn.
        var once = HerdrAgents()
        _ = once.update([agent("w1:p1", .done, seq: 8)], focusedTab: nil, tabVisible: false, now: 4)
        #expect(once.update([agent("w1:p1", .idle, seq: 9)], focusedTab: nil, tabVisible: false, now: 6) == [.resolved(pane: "w1:p1")])
        // The first list a tab gets says nothing of what came before it.
        var fresh = HerdrAgents()
        #expect(fresh.update([agent("w1:p1", .done, seq: 40, done: 9)], focusedTab: nil, tabVisible: false, now: 0).isEmpty)
    }

    @Test func aDecisionIsReadAtOnceAndToldOnTheSecondCheck() {
        var agents = HerdrAgents()
        _ = agents.update([agent("w1:p2", .working, seq: 3)], focusedTab: nil, tabVisible: false, now: 0)
        // The first check that reads it blocked: its pane is read, so the question is ready, but nothing is told yet.
        #expect(agents.update([agent("w1:p2", .blocked, seq: 4)], focusedTab: nil, tabVisible: false, now: 2) == [.needsRead(pane: "w1:p2", seq: 4)])
        #expect(agents.nextRead?.pane == "w1:p2" && agents.nextRead?.seq == 4)
        // The row and the badge show it at once.
        #expect(agents.rows[0].state == .attention && agents.needsYou == ["w1:p2"])
        // The second: told, once.
        #expect(agents.update([agent("w1:p2", .blocked, seq: 4)], focusedTab: nil, tabVisible: false, now: 4) == [.needsDecision(pane: "w1:p2")])
        #expect(agents.update([agent("w1:p2", .blocked, seq: 4)], focusedTab: nil, tabVisible: false, now: 6).isEmpty)
        agents.setQuestion(pane: "w1:p2", seq: 4, text: "Allow rm -rf build?", choices: ["Yes", "No"], style: .list)
        #expect(agents.nextRead == nil)
        let first = agents.question("w1:p2")
        #expect(first?.text == "Allow rm -rf build?" && first?.choices == ["Yes", "No"])
        // herdr counted a change while it stayed blocked: read again, told no more, and the same words are a new question.
        #expect(agents.update([agent("w1:p2", .blocked, seq: 6)], focusedTab: nil, tabVisible: false, now: 8) == [.needsRead(pane: "w1:p2", seq: 6)])
        #expect(agents.question("w1:p2") == first) // until the read says
        agents.setQuestion(pane: "w1:p2", seq: 6, text: "Allow rm -rf build?", choices: ["Yes", "No"])
        #expect(agents.question("w1:p2")?.serial != first?.serial)
        // A read for an older change is dropped; one that found no question leaves herdr's words.
        agents.setQuestion(pane: "w1:p2", seq: 4, text: "stale?")
        #expect(agents.question("w1:p2")?.text == "Allow rm -rf build?")
        agents.setQuestion(pane: "w1:p2", seq: 6, text: nil)
        #expect(agents.question("w1:p2") == nil && agents.activity == .asking("claude (w1:p2) needs a decision"))
        // Answered: the question goes with the decision, and its notice is out of date.
        agents.setQuestion(pane: "w1:p2", seq: 6, text: "Allow?")
        #expect(agents.update([agent("w1:p2", .working, seq: 7)], focusedTab: nil, tabVisible: false, now: 10) == [.resolved(pane: "w1:p2")])
        #expect(agents.question("w1:p2") == nil && agents.nextRead == nil)
    }

    @Test func aBlockedOfOneCheckTellsNothing() {
        var agents = HerdrAgents()
        _ = agents.update([agent("w1:p1", .working, seq: 3, kind: "codex")], focusedTab: nil, tabVisible: false, now: 0)
        #expect(agents.update([agent("w1:p1", .blocked, seq: 4, kind: "codex")], focusedTab: nil, tabVisible: false, now: 2)
            == [.needsRead(pane: "w1:p1", seq: 4)])
        // Working again on the next: no decision was ever told.
        #expect(agents.update([agent("w1:p1", .working, seq: 5, kind: "codex")], focusedTab: nil, tabVisible: false, now: 4)
            == [.resolved(pane: "w1:p1")])
        // A blocked count that went back (herdr restarted) is a new decision, read and told afresh.
        _ = agents.update([agent("w1:p1", .blocked, seq: 9, kind: "codex")], focusedTab: nil, tabVisible: false, now: 6)
        _ = agents.update([agent("w1:p1", .blocked, seq: 9, kind: "codex")], focusedTab: nil, tabVisible: false, now: 8)
        #expect(agents.update([agent("w1:p1", .blocked, seq: 1, kind: "codex")], focusedTab: nil, tabVisible: false, now: 10)
            == [.needsRead(pane: "w1:p1", seq: 1)])
        #expect(agents.update([agent("w1:p1", .blocked, seq: 1, kind: "codex")], focusedTab: nil, tabVisible: false, now: 12)
            == [.needsDecision(pane: "w1:p1")])
    }

    @Test func anAgentIsOnScreenWhenHerdrShowsItsTabInTheVisibleTab() throws {
        var agents = HerdrAgents()
        let list = try fixture("agent-list-two-workspaces.json")
        _ = agents.update(list, focusedTab: nil, tabVisible: true, now: 0)
        // claude's pane has herdr's focus, in w1:t1: codex in w2:t1 and gemini in w1:t2 are off screen.
        #expect(agents.focusedTab == "w1:t1")
        #expect(agents.isOnScreen("w1:p1") && !agents.isOnScreen("w2:p1") && !agents.isOnScreen("w1:p3"))
        #expect(agents.needsYou == ["w1:p3", "w2:p1"])
        // No agent has the focus (a shell pane does): herdr's tab list says which tab; unknown counts as shown.
        let unfocused = list.map { item -> HerdrAgent in
            var copy = item
            copy.focused = false
            return copy
        }
        _ = agents.update(unfocused, focusedTab: "w2:t1", tabVisible: true, now: 2)
        #expect(agents.isOnScreen("w2:p1") && !agents.isOnScreen("w1:p1"))
        _ = agents.update(unfocused, focusedTab: nil, tabVisible: true, now: 4)
        #expect(agents.isOnScreen("w2:p1") && agents.isOnScreen("w1:p1") && agents.needsYou.isEmpty)
        // The tab hidden: nothing is on screen.
        _ = agents.update(list, focusedTab: nil, tabVisible: false, now: 6)
        #expect(!agents.isOnScreen("w1:p1") && agents.needsYou == ["w1:p3", "w2:p1"])
        // An agent listed twice is one.
        _ = agents.update(list + [list[2]], focusedTab: nil, tabVisible: false, now: 8)
        #expect(agents.needsYou == ["w1:p3", "w2:p1"] && agents.rows.count == 3)
    }

    @Test func anAgentHerdrNoLongerListsIsGoneWithItsQuestionAndItsMute() {
        var agents = HerdrAgents()
        _ = agents.update([agent("w1:p1", .blocked, seq: 1), agent("w1:p2", .idle)], focusedTab: nil, tabVisible: false, now: 0)
        agents.setQuestion(pane: "w1:p1", seq: 1, text: "Allow?")
        agents.mute("w1:p1", true)
        #expect(agents.isMuted("w1:p1") && agents.rows[0].muted)
        #expect(agents.update([agent("w1:p2", .idle)], focusedTab: nil, tabVisible: false, now: 2) == [.gone(pane: "w1:p1")])
        #expect(agents.question("w1:p1") == nil && !agents.isMuted("w1:p1"))
        // Back in the same pane: a new agent, a new decision.
        let back = agents.update([agent("w1:p1", .blocked, seq: 1), agent("w1:p2", .idle)], focusedTab: nil, tabVisible: false, now: 4)
        #expect(back == [.needsRead(pane: "w1:p1", seq: 1)])
        // Muting an agent herdr does not list does nothing.
        agents.mute("w9:p9", true)
        #expect(!agents.isMuted("w9:p9"))
    }

    @Test func aMutedAgentStillNeedsYou() {
        var agents = HerdrAgents()
        _ = agents.update([agent("w1:p1", .blocked, seq: 1)], focusedTab: nil, tabVisible: false, now: 0)
        agents.mute("w1:p1", true)
        #expect(agents.needsYou == ["w1:p1"])
        agents.mute("w1:p1", false)
        #expect(!agents.isMuted("w1:p1"))
    }

    @Test func whenEachBeganToNeedYouOrdersThemAndSurvivesAQuietCheck() {
        var agents = HerdrAgents()
        _ = agents.update([agent("w1:p1", .working), agent("w1:p2", .blocked, seq: 2)], focusedTab: nil, tabVisible: false, now: 0)
        _ = agents.update([agent("w1:p1", .blocked, seq: 5), agent("w1:p2", .blocked, seq: 2)], focusedTab: nil, tabVisible: false, now: 6)
        #expect(agents.needsSince("w1:p2") == 0 && agents.needsSince("w1:p1") == 6)
        #expect(agents.rows.map(\.needsSince) == [6, 0])
        // A check with no change keeps both times; a working agent keeps when its work began.
        _ = agents.update([agent("w1:p1", .blocked, seq: 5), agent("w1:p2", .working)], focusedTab: nil, tabVisible: false, now: 8)
        _ = agents.update([agent("w1:p1", .blocked, seq: 5), agent("w1:p2", .working)], focusedTab: nil, tabVisible: false, now: 10)
        #expect(agents.needsSince("w1:p1") == 6 && agents.workSince("w1:p2") == 8 && agents.needsSince("w1:p2") == nil)
        // A new state starts a new time: blocked, then done.
        _ = agents.update([agent("w1:p1", .done, seq: 6), agent("w1:p2", .working)], focusedTab: nil, tabVisible: false, now: 12)
        #expect(agents.needsSince("w1:p1") == 12 && agents.workSince("w1:p1") == nil)
    }

    @Test func timeInStateReadsInMinutesAndSaysNothingUnderOne() {
        let blocked = TabListRows.Agent(pane: "w1:p1", name: "codex", status: .blocked, needsSince: 100)
        #expect(blocked.time(now: 100 + 250) == "waiting 4 min" && blocked.spokenTime(now: 100 + 250) == "waiting 4 minutes")
        #expect(blocked.time(now: 150) == nil && blocked.spokenTime(now: 150) == nil)
        let working = TabListRows.Agent(pane: "w1:p2", name: "claude", status: .working, workSince: 0)
        #expect(working.time(now: 12 * 60 + 5) == "working 12 min")
        #expect(working.time(now: 65 * 60) == "working 1 h 5 min" && working.spokenTime(now: 60 * 60) == "working 1 hour")
        #expect(TabListRows.Agent(pane: "p", name: "a", status: .idle, workSince: 0).time(now: 600) == nil)
        #expect(HerdrAgents.spokenDuration(61) == "1 minute" && HerdrAgents.duration(120 * 60) == "2 h")
        // The tooltip says where the times come from.
        #expect(blocked.tooltip(now: 400).contains("waiting 5 min") && blocked.tooltip(now: 400).contains("since Next Term saw it"))
        #expect(!blocked.tooltip().contains("since Next Term"))
    }

    @Test func theTabsStateIsTheFirstDecisionNamedThenWork() {
        var agents = HerdrAgents()
        _ = agents.update([agent("w1:p1", .idle), agent("w1:p2", .working)], focusedTab: nil, tabVisible: false, now: 0)
        #expect(agents.activity == .working)
        _ = agents.update([agent("w1:p1", .done)], focusedTab: nil, tabVisible: false, now: 2)
        #expect(agents.activity == .idle)
        _ = agents.update([], focusedTab: nil, tabVisible: false, now: 4)
        #expect(agents.activity == .idle)
        let three = [agent("w1:p1", .working), agent("w1:p2", .blocked, seq: 2, kind: "codex"), agent("w1:p3", .blocked, seq: 1)]
        _ = agents.update(three, focusedTab: nil, tabVisible: false, now: 6)
        #expect(agents.activity == .asking("codex (w1:p2) needs a decision, and 1 more"))
        // Its real question, read from its pane, named.
        _ = agents.update([agent("w1:p2", .blocked, seq: 2, kind: "claude", name: "api")], focusedTab: nil, tabVisible: false, now: 8)
        agents.setQuestion(pane: "w1:p2", seq: 2, text: "Do you want to make this edit to login.ts?")
        #expect(agents.activity == .asking("api (claude): Do you want to make this edit to login.ts?"))
    }

    @Test func rowsFollowHerdrsOrderWithItsStatesAsMarks() throws {
        var agents = HerdrAgents()
        _ = agents.update(try fixture("agent-list-0.9.4.json"), focusedTab: nil, tabVisible: false, now: 0)
        let rows = agents.rows
        #expect(rows.map(\.pane) == ["w1:p1", "w1:p2", "w2:p1"] && rows.map(\.name) == ["api", "codex", "gemini"])
        #expect(rows.map(\.state) == [.working, .attention, .done])
        #expect(rows[0].title == "Fix the login" && rows[0].directory == "/home/me/api/src" && rows[0].focused)
        #expect([HerdrAgent.Status.idle, .unknown].map(HerdrAgents.state) == [.idle, .idle])
        #expect(rows.allSatisfy { $0.disambiguation == nil })
    }

    @Test func herdrsOwnNamesAndTitlesAreTheRows() throws {
        var agents = HerdrAgents()
        _ = agents.update(try fixture("agent-list-0.9.5-metadata.json"), focusedTab: nil, tabVisible: false, now: 0)
        #expect(agents.rows[0].name == "Claude: auth" && agents.rows[0].title == "Refactor auth middleware" && agents.rows[0].kind == "claude")
        #expect(agents.rows[1].name == "codex" && agents.rows[1].title == "Fix login")
        #expect(HerdrAgents.label(agents.agents[0]) == "Claude: auth (claude)" && HerdrAgents.label(agents.agents[1]) == "codex")
    }

    @Test func twoRowsThatReadTheSameSayWhereEachWorks() {
        var agents = HerdrAgents()
        let two = [agent("w1:p1", .working, title: "Fix login", directory: "/srv/api"), agent("w1:p2", .idle, title: "Fix login", directory: "/srv/web"),
                   agent("w1:p3", .idle, kind: "codex", title: "Fix login", directory: "/srv/api")]
        _ = agents.update(two, focusedTab: nil, tabVisible: false, now: 0)
        #expect(agents.rows.map(\.disambiguation) == ["api", "web", nil])
        #expect(agents.rows[0].summary() == "claude (api) · w1:p1 · Working · Fix login")
        // The same folder too: the pane says which.
        _ = agents.update([agent("w1:p1", .idle, directory: "/a/x"), agent("w1:p2", .idle, directory: "/b/x")], focusedTab: nil, tabVisible: false, now: 2)
        #expect(agents.rows.map(\.disambiguation) == ["w1:p1", "w1:p2"])
    }

    @Test func pastSixAgentsTheIdleOnesFoldIntoOneRow() {
        let statuses: [HerdrAgent.Status] = [.working, .idle, .blocked, .idle, .unknown, .done, .idle, .working, .idle]
        var rows = statuses.enumerated().map { TabListRows.Agent(pane: "w1:p\($0.offset)", name: "a\($0.offset)", status: $0.element) }
        let nine = HerdrAgents.fold(rows)
        #expect(nine.shown.map(\.pane) == ["w1:p0", "w1:p2", "w1:p5", "w1:p7"])
        #expect(nine.folded.map(\.pane) == ["w1:p1", "w1:p3", "w1:p4", "w1:p6", "w1:p8"])
        // Kept unread never folds.
        rows[1].unread = true
        #expect(HerdrAgents.fold(rows).folded.count == 4 && HerdrAgents.fold(rows).shown.map(\.pane).contains("w1:p1"))
        // Six never fold, nor a single idle one.
        #expect(HerdrAgents.fold(Array(rows.prefix(6))).folded.isEmpty)
        let oneIdle = (0..<7).map { TabListRows.Agent(pane: "p\($0)", name: "a", status: $0 == 0 ? .idle : .working) }
        #expect(HerdrAgents.fold(oneIdle).folded.isEmpty && HerdrAgents.fold(oneIdle).shown.count == 7)
    }

    @Test func aLongListCostsAStepPerAgent() {
        var agents = HerdrAgents()
        let list = (0..<500).map { agent("w\($0 / 10):p\($0)", $0 % 7 == 0 ? .blocked : .working, tab: "w\($0 / 10):t1", seq: $0) }
        _ = agents.update(list, focusedTab: nil, tabVisible: true, now: 0)
        _ = agents.update(list, focusedTab: nil, tabVisible: true, now: 2)
        #expect(agents.steps == 500 && agents.rows.count == 500)
    }
}
