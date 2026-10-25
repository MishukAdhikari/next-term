import Foundation
import Testing
@testable import NextTermCore

@Suite struct TabListModelTests {
    private let home = "/Users/test"

    private func pane(_ key: String, _ title: String, _ state: TabState = .idle, focused: Bool = false, folder: String = "/Users/test/work",
                      question: String? = nil, remote: RemoteMark? = nil) -> TabListRows.Pane {
        TabListRows.Pane(key: key, title: title, state: state, tooltip: "\(title) tip", spokenStatus: state.rawValue.capitalized, folder: folder,
                         question: question, remote: remote, focused: focused)
    }

    private func tab(_ key: String, _ panes: [TabListRows.Pane], shortcut: String? = nil, place: String? = nil) -> TabListRows.Source {
        TabListRows.Source(key: key, panes: panes, shortcut: shortcut, place: place)
    }

    private func rows(_ tabs: [TabListRows.Source], folders: Bool = false) -> [TabListRow] {
        TabListRows.make(tabs: tabs, showsFolders: folders, home: home)
    }

    @Test func threePlainTabsAreThreeTabRows() {
        let made = rows([tab("a", [pane("a1", "next-term")], shortcut: "⌘1"), tab("b", [pane("b1", "claude")], shortcut: "⌘2"),
                         tab("c", [pane("c1", "npm run dev · :5173")], shortcut: "⌘3")])
        #expect(made.map(\.kind) == [.tab, .tab, .tab])
        #expect(made.map(\.key) == ["a", "b", "c"])
        // Word for word the top bar's titles, the served port included.
        #expect(made.map(\.title) == ["next-term", "claude", "npm run dev · :5173"])
        #expect(made.map(\.shortcut) == ["⌘1", "⌘2", "⌘3"])
        #expect(made.allSatisfy { !$0.isPane })
    }

    @Test func aSplitTabIsItsRowThenARowPerPane() {
        let split = tab("g", [pane("p1", "claude", .done, focused: true), pane("p2", "pytest -x", .working)], shortcut: "⌘1")
        let made = rows([split])
        #expect(made.count == 3)
        // The tab's row: the keyboard pane's title, the most urgent pane's mark.
        #expect(made[0].kind == .tab)
        #expect(made[0].key == "g")
        #expect(made[0].title == "claude")
        #expect(made[0].state == .working)
        #expect(made[0].shortcut == "⌘1")
        // Each pane's row: its own title and mark, in the group's order, keyed by the pane.
        #expect(made[1].kind == .pane(index: 0, count: 2))
        #expect(made[1].key == "p1")
        #expect(made[1].title == "claude")
        #expect(made[1].state == .done)
        #expect(made[1].focused)
        #expect(made[2].kind == .pane(index: 1, count: 2))
        #expect(made[2].title == "pytest -x")
        #expect(made[2].state == .working)
        #expect(!made[2].focused)
        // A pane row has no key of its own, no rename and no place: those act on the tab.
        #expect(made[1].shortcut == nil && made[2].shortcut == nil)
        #expect(made[1].editableTitle == nil && made[2].editableTitle == nil)
        // No title says how many panes there are, and none carries typed spaces.
        for row in made {
            #expect(!row.title.contains("+1"))
            #expect(!row.title.contains("  "))
        }
    }

    @Test func theTabRowFollowsThePaneWithTheKeyboard() {
        var focusedSecond = pane("p2", "vim notes.md", focused: true)
        focusedSecond.truncatesTail = true
        focusedSecond.shorterTitles = ["notes"]
        focusedSecond.editableTitle = "editor"
        let made = rows([tab("g", [pane("p1", "zsh"), focusedSecond])])
        #expect(made[0].title == "vim notes.md")
        #expect(made[0].truncatesTail)
        #expect(made[0].shorterTitles == ["notes"])
        #expect(made[0].editableTitle == "editor")
        // No pane said it has the keyboard: the first one stands for the tab.
        let unfocused = rows([tab("h", [pane("q1", "first"), pane("q2", "second")])])
        #expect(unfocused[0].title == "first")
    }

    @Test func aTabRowSaysWhatTheTopBarsTabSays() {
        // A split tab's tooltip and spoken status are the bar's, given whole.
        var split = tab("g", [pane("p1", "claude", .working, focused: true), pane("p2", "zsh")])
        split.tooltip = "claude: Working\nzsh: Idle"
        split.spokenStatus = "zsh: Idle"
        let made = rows([split])
        #expect(made[0].tooltip == "claude: Working\nzsh: Idle")
        #expect(made[0].spokenStatus == "zsh: Idle")
        // A plain tab without them: its pane's own.
        let plain = rows([tab("a", [pane("a1", "claude", .done)])])
        #expect(plain[0].tooltip == "claude tip")
        #expect(plain[0].spokenStatus == "Done")
        // Each pane row: its own.
        #expect(made[2].tooltip == "zsh tip")
        #expect(made[2].spokenStatus == "Idle")
    }

    @Test func theOrderIsTheTabsOwnWhateverTheirMarks() {
        // Nothing needing you moves up: ⌘3 stays on the third tab.
        let made = rows([tab("a", [pane("a1", "one", .idle)]), tab("b", [pane("b1", "two", .done)]),
                         tab("c", [pane("c1", "three", .attention)])])
        #expect(made.map(\.key) == ["a", "b", "c"])
    }

    @Test func aTabWithNoPanesKeepsItsPlace() {
        // Tab numbers stay the window's: the row is there, with nothing to show.
        let made = rows([tab("a", []), tab("b", [pane("b1", "claude")])])
        #expect(made.map(\.key) == ["a", "b"])
        #expect(made[0].title == "")
        #expect(made[0].state == .idle)
    }

    @Test func urgencyGoesNeedsYouWorkingFailedDoneIdle() {
        #expect(TabListRows.mostUrgent([.working, .attention]) == .attention)
        #expect(TabListRows.mostUrgent([.done, .failed]) == .failed)
        #expect(TabListRows.mostUrgent([.idle, .idle]) == .idle)
        #expect(TabListRows.mostUrgent([.done, .working]) == .working)
        #expect(TabListRows.mostUrgent([]) == .idle)
        // With the spinner off a working pane shows no mark, so it never hides another pane's cross or check.
        #expect(TabListRows.mostUrgent([.done, .working], workingShown: false) == .done)
        #expect(TabListRows.mostUrgent([.idle, .working], workingShown: false) == .working)
        let split = tab("g", [pane("p1", "a", .done, focused: true), pane("p2", "b", .working)])
        let still = TabListRows.make(tabs: [split], showsFolders: false, home: home, workingShown: false)
        #expect(still[0].state == .done)
    }

    @Test func withOneLineNoRowHasASecondLine() {
        let made = rows([tab("a", [pane("a1", "api", folder: "/Users/test/work/api", question: "Do you want to make this edit?")]),
                         tab("g", [pane("p1", "claude", focused: true), pane("p2", "zsh")])])
        #expect(made.allSatisfy { $0.detail == nil && !$0.detailIsQuestion })
    }

    @Test func withFoldersTheSecondLineIsTheFolderOrTheQuestion() {
        let made = rows([
            tab("a", [pane("a1", "api", folder: "/Users/test/work/api")]),
            tab("b", [pane("b1", "~", folder: "/Users/test")]),
            tab("c", [pane("c1", "srv", folder: "/srv/www")]),
            tab("d", [pane("d1", "claude", .attention, folder: "/Users/test/work/api", question: "Do you want to make this edit to x?")]),
        ], folders: true)
        #expect(made[0].detail == "~/work/api")
        #expect(!made[0].detailIsQuestion)
        #expect(made[1].detail == "~")
        #expect(made[2].detail == "/srv/www")
        #expect(made[3].detail == "Do you want to make this edit to x?")
        #expect(made[3].detailIsQuestion)
    }

    @Test func aRemoteTabsSecondLineNamesItsHost() {
        let mark = RemoteMark(host: "web-1", destination: "deploy@203.0.113.5", link: .connected)
        let made = rows([tab("r", [pane("r1", "web-1: app", folder: "~/app", remote: mark)])], folders: true)
        #expect(made[0].detail == "web-1: ~/app")
        #expect(made[0].remote == mark)
        // A folder on the host is the host's: this Mac's home means nothing there.
        let homeLike = rows([tab("r", [pane("r1", "web-1", folder: "/Users/test/app", remote: mark)])], folders: true)
        #expect(homeLike[0].detail == "web-1: /Users/test/app")
    }

    @Test func theSecondLineRule() {
        let question = TabListRows.detail(folder: "/Users/test/x", question: "Allow this?", remoteHost: "web-1", home: home)
        #expect(question?.text == "Allow this?")
        #expect(question?.isQuestion == true)
        // A question of only spaces is none.
        #expect(TabListRows.detail(folder: "/Users/test/x", question: "  ", remoteHost: nil, home: home)?.text == "~/x")
        // Nothing to say: no line.
        #expect(TabListRows.detail(folder: "", question: nil, remoteHost: nil, home: home) == nil)
        #expect(TabListRows.detail(folder: "", question: nil, remoteHost: "web-1", home: home)?.text == "web-1")
        // A folder that only starts like the home is not under it.
        #expect(TabListRows.detail(folder: "/Users/testing", question: nil, remoteHost: nil, home: home)?.text == "/Users/testing")
    }

    @Test func aSplitTabsSecondLineIsTheAskingPanesQuestionElseTheKeyboardPanesFolder() {
        let asking = rows([tab("g", [pane("p1", "zsh", focused: true, folder: "/Users/test/a"),
                                     pane("p2", "claude", .attention, folder: "/Users/test/b", question: "Run tests?")])], folders: true)
        #expect(asking[0].detail == "Run tests?")
        #expect(asking[0].detailIsQuestion)
        let quiet = rows([tab("g", [pane("p1", "zsh", folder: "/Users/test/a"), pane("p2", "claude", focused: true, folder: "/Users/test/b")])],
                         folders: true)
        #expect(quiet[0].detail == "~/b")
        // Pane rows are one line, always.
        #expect(quiet[1].detail == nil && quiet[2].detail == nil)
    }

    @Test func aSplitTabsServerMarkIsItsWeakestPanes() {
        let up = RemoteMark(host: "web-1", destination: "web-1", link: .connected)
        let down = RemoteMark(host: "web-2", destination: "web-2", link: .disconnected)
        let made = rows([tab("g", [pane("p1", "a", focused: true, remote: up), pane("p2", "b", remote: down)])])
        #expect(made[0].remote == down)
        #expect(made[1].remote == up)
        #expect(made[2].remote == down)
    }

    @Test func voiceOverHearsATabAsTheBarSaysItAndAPaneWithItsPlace() {
        let mark = RemoteMark(host: "web-1", destination: "deploy@203.0.113.5", link: .connected)
        var source = tab("g", [pane("p1", "claude", .working, focused: true), pane("p2", "pytest -x"), pane("p3", "zsh", remote: mark)],
                         place: "Works in fix/sso")
        source.spokenStatus = "Working"
        let made = rows([source])
        // Title, state, server, place: the bar's order.
        #expect(made[0].accessibilityLabel == "claude, Working, Remote: web-1 (deploy@203.0.113.5), connected, Works in fix/sso")
        #expect(made[1].accessibilityLabel == "claude, pane 1 of 3, Working")
        #expect(made[2].accessibilityLabel == "pytest -x, pane 2 of 3, Idle")
        #expect(made[3].accessibilityLabel == "zsh, pane 3 of 3, Idle, Remote: web-1 (deploy@203.0.113.5), connected")
    }

    @Test func theSecondLineIsSaidOnce() {
        let asking = TabListRows.Pane(key: "a1", title: "claude", state: .attention, spokenStatus: "Needs your decision: Run tests?",
                                      folder: "/Users/test/a", question: "Run tests?", focused: true)
        let made = rows([tab("a", [asking]), tab("b", [pane("b1", "zsh", folder: "/Users/test/b")])], folders: true)
        // The question is in the spoken status already.
        #expect(made[0].accessibilityLabel == "claude, Needs your decision: Run tests?")
        // The folder is not.
        #expect(made[1].accessibilityLabel == "zsh, Idle, ~/b")
    }

    @Test func eachTabsBlockIsItsRowAndItsPaneRows() {
        let made = rows([tab("a", [pane("a1", "one")]), tab("g", [pane("p1", "two", focused: true), pane("p2", "three")]),
                         tab("c", [pane("c1", "four")])])
        #expect(TabListRows.blocks(of: made.map(\.kind)) == [0..<1, 1..<4, 4..<5])
        #expect(TabListRows.blocks(of: []) == [])
    }

    @Test func movingATabTakesItsPaneRowsWithIt() {
        let made = rows([tab("a", [pane("a1", "one")]), tab("g", [pane("p1", "two", focused: true), pane("p2", "three")]),
                         tab("c", [pane("c1", "four")])])
        #expect(TabListRows.moving(made, tab: 1, to: 2).map(\.key) == ["a", "c", "g", "p1", "p2"])
        #expect(TabListRows.moving(made, tab: 1, to: 0).map(\.key) == ["g", "p1", "p2", "a", "c"])
        #expect(TabListRows.moving(made, tab: 0, to: 2).map(\.key) == ["g", "p1", "p2", "c", "a"])
        // Nowhere to go: as it was.
        #expect(TabListRows.moving(made, tab: 1, to: 1).map(\.key) == made.map(\.key))
        #expect(TabListRows.moving(made, tab: 5, to: 0).map(\.key) == made.map(\.key))
    }
}

/// herdr's agents as rows under the tab or pane that shows herdr: herdr's order, its names and titles, the time in
/// their states, and the idle ones folded past six.
@Suite struct TabListHerdrRowsTests {
    let web1 = RemoteMark(host: "web-1", destination: "deploy@203.0.113.5", link: .connected)
    let three: [TabListRows.Agent] = [
        TabListRows.Agent(pane: "w1:p1", name: "api", kind: "claude", title: "Fix the login", directory: "/srv/api/src", status: .working),
        TabListRows.Agent(pane: "w2:p1", name: "codex", kind: "codex", directory: "/srv/web", status: .blocked, question: "Allow rm -rf build?",
                          needsSince: 100),
        TabListRows.Agent(pane: "w2:p2", name: "gemini", status: .done),
    ]

    func herdrPane(_ key: String, focused: Bool = true, agents: [TabListRows.Agent]? = nil, open: Bool = false) -> TabListRows.Pane {
        TabListRows.Pane(key: key, title: "web-1: herdr", state: .attention, folder: "/srv", remote: web1, focused: focused,
                         herdrAgents: agents ?? three, herdrIdleOpen: open)
    }

    @Test func aHerdrTabIsItsRowThenARowPerAgent() {
        let made = TabListRows.make(tabs: [TabListRows.Source(key: "t", panes: [herdrPane("pane x")])], showsFolders: false, home: "/Users/test")
        #expect(made.map(\.key) == ["t", "pane x/herdr/w1:p1", "pane x/herdr/w2:p1", "pane x/herdr/w2:p2"])
        #expect(made.dropFirst().map(\.kind) == [.herdrAgent(index: 0, count: 3), .herdrAgent(index: 1, count: 3), .herdrAgent(index: 2, count: 3)])
        #expect(made.dropFirst().map(\.state) == [.working, .attention, .done])
        #expect(made.dropFirst().map(\.herdrPane) == ["w1:p1", "w2:p1", "w2:p2"])
        #expect(made[1].title == "api · Fix the login" && made[2].title == "codex")
        #expect(made.dropFirst().allSatisfy { $0.isPane && $0.isAgent && !$0.isFolded && $0.detail == nil })
        // One block: the agents go with their tab.
        #expect(TabListRows.blocks(of: made.map(\.kind)) == [0..<4])
        #expect(made[1].tooltip == "api · w1:p1 · Working · Fix the login\n/srv/api/src")
    }

    @Test func inASplitTabTheAgentsFollowThePaneThatShowsHerdr() {
        let shell = TabListRows.Pane(key: "pane s", title: "zsh", focused: false)
        let split = TabListRows.Source(key: "g", panes: [shell, herdrPane("pane h", focused: false)])
        let made = TabListRows.make(tabs: [split], showsFolders: false, home: "/Users/test")
        #expect(made.map(\.key) == ["g", "pane s", "pane h", "pane h/herdr/w1:p1", "pane h/herdr/w2:p1", "pane h/herdr/w2:p2"])
        #expect(made[1].kind == .pane(index: 0, count: 2) && made[2].kind == .pane(index: 1, count: 2))
    }

    @Test func theSecondLineIsTheQuestionElseWhereTheAgentWorks() {
        let made = TabListRows.make(tabs: [TabListRows.Source(key: "t", panes: [herdrPane("p")])], showsFolders: true, home: "/Users/test")
        #expect(made[1].detail == "web-1: /srv/api/src" && !made[1].detailIsQuestion)
        #expect(made[2].detail == "Allow rm -rf build?" && made[2].detailIsQuestion)
        #expect(made[3].detail == "web-1")
        // On this Mac, the home folder is ~.
        let local = TabListRows.Pane(key: "l", title: "herdr", folder: "/Users/test", focused: true,
                                     herdrAgents: [TabListRows.Agent(pane: "w1:p1", name: "claude", directory: "/Users/test/app")])
        let mine = TabListRows.make(tabs: [TabListRows.Source(key: "t", panes: [local])], showsFolders: true, home: "/Users/test")
        #expect(mine[1].detail == "~/app")
        // Rows of two lines are as tall as a tab's; of one, as a pane's.
        #expect(TabListLayout.rowHeight(for: .herdrAgent(index: 0, count: 1), density: .twoLines) == TabListLayout.twoLineHeight)
        #expect(TabListLayout.rowHeight(for: .herdrAgent(index: 0, count: 1), density: .oneLine) == TabListLayout.paneHeight)
        #expect(TabListLayout.rowHeight(for: .herdrFolded(count: 5, open: false), density: .twoLines) == TabListLayout.paneHeight)
    }

    @Test func noAgentsNoRowsAndVoiceOverSaysWhereEachIs() {
        let empty = TabListRows.Pane(key: "p", title: "herdr", focused: true)
        #expect(TabListRows.make(tabs: [TabListRows.Source(key: "t", panes: [empty])], showsFolders: true, home: "/").count == 1)
        let made = TabListRows.make(tabs: [TabListRows.Source(key: "t", panes: [herdrPane("p")])], showsFolders: false, home: "/")
        #expect(made[2].accessibilityLabel == "codex, herdr agent 2 of 3, Needs your decision")
        #expect(made[3].accessibilityLabel == "gemini, herdr agent 3 of 3, Done")
    }

    @Test func aRowSaysHowLongItHasWaitedAndGivesItsTitleWayFirst() {
        let made = TabListRows.make(tabs: [TabListRows.Source(key: "t", panes: [herdrPane("p")])], showsFolders: false, home: "/",
                                    now: 100 + 250)
        #expect(made[2].title == "codex · waiting 4 min" && made[2].shorterTitles == ["codex"])
        #expect(made[2].accessibilityLabel == "codex, herdr agent 2 of 3, Needs your decision, waiting 4 minutes")
        #expect(made[2].tooltip.contains("since Next Term saw it"))
        // Under a minute: nothing.
        let soon = TabListRows.make(tabs: [TabListRows.Source(key: "t", panes: [herdrPane("p")])], showsFolders: false, home: "/", now: 150)
        #expect(soon[2].title == "codex" && soon[2].shorterTitles.isEmpty)
        // A row that reads the same as another says where it works, before its time.
        var twins = three
        twins[1].title = "Fix the login"
        twins[1].disambiguation = "web"
        let named = TabListRows.make(tabs: [TabListRows.Source(key: "t", panes: [herdrPane("p", agents: twins)])], showsFolders: false,
                                     home: "/", now: 400)
        #expect(named[2].title == "codex · Fix the login · web · waiting 5 min")
        #expect(named[2].shorterTitles == ["codex · waiting 5 min", "codex"])
    }

    @Test func pastSixAgentsTheIdleOnesFoldIntoOneRowThatOpens() {
        let statuses: [HerdrAgent.Status] = [.working, .idle, .blocked, .idle, .unknown, .done, .idle, .working, .idle]
        let nine = statuses.enumerated().map { TabListRows.Agent(pane: "w1:p\($0.offset)", name: "a\($0.offset)", status: $0.element) }
        let shut = TabListRows.make(tabs: [TabListRows.Source(key: "t", panes: [herdrPane("p", agents: nine)])], showsFolders: false, home: "/")
        #expect(shut.map(\.key) == ["t", "p/herdr/w1:p0", "p/herdr/w1:p2", "p/herdr/w1:p5", "p/herdr/w1:p7", "p/herdr/idle"])
        #expect(shut[5].kind == .herdrFolded(count: 5, open: false) && shut[5].isFolded && shut[5].title == "▸ 5 idle")
        #expect(shut[5].accessibilityLabel == "5 idle herdr agents, collapsed" && shut[5].tooltip.hasPrefix("5 idle herdr agents: a1, a3"))
        // Its agents keep their place among herdr's.
        #expect(shut[2].kind == .herdrAgent(index: 2, count: 9))
        let open = TabListRows.make(tabs: [TabListRows.Source(key: "t", panes: [herdrPane("p", agents: nine, open: true)])],
                                    showsFolders: false, home: "/")
        #expect(open.count == 11 && open[5].title == "▾ 5 idle" && open[5].accessibilityLabel == "5 idle herdr agents, expanded")
        #expect(open.suffix(5).map(\.herdrPane) == ["w1:p1", "w1:p3", "w1:p4", "w1:p6", "w1:p8"])
        #expect(TabListRows.blocks(of: open.map(\.kind)) == [0..<11])
    }
}
