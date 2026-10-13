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
