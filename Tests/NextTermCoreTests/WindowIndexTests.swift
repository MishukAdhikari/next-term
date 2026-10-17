import Foundation
import Testing
@testable import NextTermCore

/// Made-up windows and tabs: ids are fixed, so a test can name them.
@Suite struct WindowIndexTests {
    private func tab(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    private func terminal(_ n: Int, _ state: TabState, _ title: String = "claude") -> WindowIndex.Tab {
        WindowIndex.Tab(id: tab(n), title: title, state: state)
    }

    private func window(_ id: Int, _ tabs: [WindowIndex.Tab], kind: WindowKind = .project, name: String = "shop",
                        lastKey: Double = 0) -> WindowIndex.Window {
        let project: String? = kind.hasProject ? "/Users/sam/Code/" + name : nil
        let at = Date(timeIntervalSince1970: lastKey)
        return WindowIndex.Window(id: id, kind: kind, project: project, name: name, title: name, lastKey: at, tabs: tabs)
    }

    private func tabs(_ waiting: [WindowIndex.Waiting]) -> [UUID] { waiting.map(\.tab) }

    private func check(_ found: [UUID], _ expected: [Int]) {
        // Compared outside `#expect`, where arrays are slow to type-check.
        let wanted: [UUID] = expected.map(tab)
        let same: Bool = found == wanted
        #expect(same, "\(found), expected \(wanted)")
    }

    /// Go to Next Agent Needing You pressed once with each of `fronts` in front (a terminal's number; nil for none), in
    /// turn: the terminal each press went to, nil for none. Outside `#expect`, which can't call a mutating method.
    private func presses(_ index: inout WindowIndex, from fronts: [Int?]) -> [UUID?] {
        fronts.map { (front: Int?) -> UUID? in index.next(from: front.map(tab))?.tab }
    }

    private func check(_ went: [UUID?], _ expected: [Int?]) {
        let wanted: [UUID?] = expected.map { (n: Int?) -> UUID? in n.map(tab) }
        let same: Bool = went == wanted
        #expect(same, "\(went), expected \(wanted)")
    }

    // MARK: the order

    @Test func decisionsComeFirstThenFailuresThenFinishedEachTheLongestWaitingFirst() {
        var index = WindowIndex()
        index.update(window(1, [terminal(1, .done), terminal(2, .working), terminal(3, .failed)]))
        index.update(window(2, [terminal(4, .attention), terminal(5, .idle)], name: "wiki"))
        index.update(window(3, [terminal(6, .done), terminal(7, .attention)], kind: .plain, name: "~"))
        check(tabs(index.waiting), [4, 7, 3, 1, 6])
        // In one window, the same order: its failure before its finished agent.
        #expect(index.firstWaiting(in: 1)?.tab == tab(3))
        // A tab that has waited longer comes first, wherever its window is.
        var later = WindowIndex()
        later.update(window(2, [terminal(4, .idle)], name: "wiki"))
        later.update(window(1, [terminal(1, .done)]))
        later.update(window(2, [terminal(4, .done)], name: "wiki"))
        check(tabs(later.waiting), [1, 4])
    }

    @Test func aTabWaitsFromWhenItsMarkChanged() {
        var index = WindowIndex()
        index.update(window(1, [terminal(1, .done), terminal(2, .idle)]))
        index.update(window(1, [terminal(1, .done), terminal(2, .done)]))
        check(tabs(index.waiting), [1, 2])
        // The first finished long ago, then rang the bell: among decisions it waits from the bell, and a refresh that
        // finds it the same keeps its place.
        index.update(window(2, [terminal(3, .attention)], name: "wiki"))
        index.update(window(1, [terminal(1, .attention), terminal(2, .done)]))
        index.update(window(1, [terminal(1, .attention), terminal(2, .done)]))
        check(tabs(index.waiting), [3, 1, 2])
        // Seen, it leaves; needing you again, it waits from then.
        index.update(window(1, [terminal(1, .idle), terminal(2, .done)]))
        index.update(window(1, [terminal(1, .done), terminal(2, .done)]))
        check(tabs(index.waiting), [3, 2, 1])
    }

    @Test func workingAndIdleTerminalsDoNotWait() {
        var index = WindowIndex()
        index.update(window(1, [terminal(1, .working), terminal(2, .idle)]))
        #expect(index.waiting.isEmpty)
        #expect(index.windowsWaiting.isEmpty)
        check(presses(&index, from: [nil, 1]), [nil, nil])
    }

    // MARK: going through them

    @Test func eachPressGoesToTheNextAndRoundToTheFirst() {
        var index = WindowIndex()
        index.update(window(1, [terminal(1, .attention), terminal(2, .done)]))
        index.update(window(2, [terminal(3, .failed)], name: "wiki"))
        // From a tab that needs nothing: the one waiting longest, a decision. In front now and still waiting (a decision
        // is answered, not seen): the next one, in another window too, then round to the first.
        check(presses(&index, from: [nil, 1, 3, 2]), [1, 3, 2, 1])
        let next: WindowIndex.Waiting? = index.next(from: tab(1))
        #expect(next?.window == 2 && next?.state == .failed)
    }

    @Test func aFinishedAgentSeenNowGoesOnFromWhereItWas() {
        var index = WindowIndex()
        index.update(window(1, [terminal(1, .attention), terminal(2, .done), terminal(3, .done)]))
        check(presses(&index, from: [nil, 1]), [1, 2])
        // Gone to, tab 2 is seen: it needs nothing now, and the next press goes on to tab 3, not back to the decision.
        index.update(window(1, [terminal(1, .attention), terminal(2, .idle), terminal(3, .done)]))
        check(presses(&index, from: [2]), [3])
        // Seen too, and the last: round to the first.
        index.update(window(1, [terminal(1, .attention), terminal(2, .idle), terminal(3, .idle)]))
        check(presses(&index, from: [3]), [1])
    }

    @Test func fromSomewhereElseItStartsAgainAtTheLongestWaiting() {
        var index = WindowIndex()
        index.update(window(1, [terminal(1, .attention), terminal(2, .done), terminal(3, .idle)]))
        // The user went to tab 3 by hand after two presses: the next press starts over, and so does one from no terminal.
        check(presses(&index, from: [nil, 1, 3, nil]), [1, 2, 1, 1])
    }

    // MARK: windows of each kind

    @Test func windowsOfEachKindAreKeptInTheOrderTheyOpened() {
        var index = WindowIndex()
        let project = window(1, [terminal(1, .idle)], name: "shop")
        let worktree = window(2, [terminal(2, .done)], kind: .worktree, name: "xCloud ▸ 7027-sso")
        let plain = window(3, [terminal(3, .attention)], kind: .plain, name: "~/Downloads")
        let server = WindowIndex.Window(id: 4, kind: .server, project: nil, name: "web-1", title: "web-1 — app",
                                        lastKey: .distantPast, tabs: [terminal(4, .failed, "web-1: app")],
                                        destination: "deploy@203.0.113.5")
        for window in [project, worktree, plain, server] { index.update(window) }
        let kinds: [WindowKind] = index.windows.map(\.kind)
        #expect(kinds == [.project, .worktree, .plain, .server])
        #expect(index.window(4)?.destination == "deploy@203.0.113.5")
        #expect(index.window(1)?.project == "/Users/sam/Code/shop" && index.window(3)?.project == nil)
        // The Dock menu: the windows waiting, the one Go to Next Agent Needing You goes to first at the top, each item
        // going to its window's terminal that needs you most.
        let dock: [Int] = index.windowsWaiting.map(\.id)
        #expect(dock == [3, 4, 2])
        #expect(index.firstWaiting(in: 4)?.tab == tab(4) && index.firstWaiting(in: 4)?.state == .failed)
        #expect(index.firstWaiting(in: 1) == nil && index.firstWaiting(in: 9) == nil)
        #expect(WindowKind.worktree.hasProject && !WindowKind.server.hasProject && !WindowKind.plain.hasProject)
    }

    @Test func anUpdateSaysWhetherAnythingChanged() {
        var index = WindowIndex()
        let first = window(1, [terminal(1, .working)])
        let added: Bool = index.update(first)
        let same: Bool = index.update(first)
        let marked: Bool = index.update(window(1, [terminal(1, .done)]))
        let renamed: Bool = index.update(window(1, [terminal(1, .done, "claude: tests pass")]))
        #expect(added && !same && marked && renamed)
    }

    // MARK: stale entries

    @Test func aClosedWindowLeavesWithItsTerminals() {
        var index = WindowIndex()
        index.update(window(1, [terminal(1, .attention)]))
        index.update(window(2, [terminal(2, .done)], name: "wiki"))
        check(presses(&index, from: [nil]), [1])
        index.remove(window: 1)
        #expect(index.window(1) == nil)
        check(tabs(index.waiting), [2])
        // The tab gone to last was in it: from it, the next press finds what is left.
        check(presses(&index, from: [1]), [2])
        index.remove(window: 2)
        #expect(index.waiting.isEmpty && index.windows.isEmpty)
        check(presses(&index, from: [2]), [nil])
        // Removing one never heard of changes nothing.
        index.remove(window: 9)
        #expect(index.windows.isEmpty)
    }

    @Test func aClosedTabIsForgottenAndATabMovedKeepsItsPlace() {
        var index = WindowIndex()
        index.update(window(1, [terminal(1, .done), terminal(2, .done)]))
        index.update(window(2, [terminal(3, .done)], name: "wiki"))
        // Tab 1 closed: gone from the list; were it to come back, it would wait from then.
        index.update(window(1, [terminal(2, .done)]))
        check(tabs(index.waiting), [2, 3])
        index.update(window(1, [terminal(1, .done), terminal(2, .done)]))
        check(tabs(index.waiting), [2, 3, 1])
        // Tab 2 dragged to the other window: it keeps how long it has waited.
        index.update(window(2, [terminal(3, .done), terminal(2, .done)], name: "wiki"))
        index.update(window(1, [terminal(1, .done)]))
        check(tabs(index.waiting), [2, 3, 1])
        // Its window closed with tab 1 still in it: tab 1 goes, the others stay.
        index.remove(window: 1)
        check(tabs(index.waiting), [2, 3])
    }

    // MARK: marks

    @Test func marksCountEachStateMostUrgentFirst() {
        let marks = AgentMarks([.done, .working, .attention, .done, .idle, .failed, .working])
        #expect(marks.attention == 1 && marks.failed == 1 && marks.done == 2 && marks.working == 2)
        #expect(marks.needingYou == 4)
        let states: [TabState] = marks.shown().map(\.state)
        #expect(states == [.attention, .failed, .done, .working])
        #expect(marks.shown(working: false).map(\.state) == [.attention, .failed, .done])
        #expect(marks.shown().last?.count == 2)
        #expect(marks.spoken() == "1 needs you, 1 failed, 2 done, 2 working")
        #expect(AgentMarks([.attention, .attention]).spoken() == "2 need you")
        #expect(AgentMarks([.working]).spoken(working: false) == nil)
        #expect(AgentMarks([.idle]).spoken() == nil && AgentMarks().shown().isEmpty)
        let marked: WindowIndex.Window = window(1, [terminal(1, .done), terminal(2, .working)])
        #expect(marked.marks == AgentMarks([.done, .working]))
    }
}

/// The window title: its name first, then what is in front.
@Suite struct WindowTitleTests {
    private let home = "/Users/sam"

    @Test func aProjectWindowLeadsWithItsProject() {
        #expect(WindowTitle.make(name: "xCloud ▸ 7027-sso", front: "claude") == "xCloud ▸ 7027-sso — claude")
        #expect(WindowTitle.make(name: "xCloud", front: "Alertable.php", folderName: "xCloud") == "xCloud — Alertable.php")
        // A tab at its prompt in the project's folder is named after it: the name says it already.
        #expect(WindowTitle.make(name: "xCloud", front: "xCloud", folderName: "xCloud") == "xCloud")
        #expect(WindowTitle.make(name: "xCloud ▸ 7027-sso", front: "xCloud-wt-7027-sso", folderName: "xCloud-wt-7027-sso")
            == "xCloud ▸ 7027-sso")
        #expect(WindowTitle.make(name: "xCloud", front: "src", folderName: "xCloud") == "xCloud — src")
        #expect(WindowTitle.make(name: "xCloud", front: nil) == "xCloud")
        #expect(WindowTitle.make(name: "xCloud", front: "") == "xCloud")
    }

    @Test func aWindowWithNoProjectIsNamedByItsFolder() {
        #expect(WindowTitle.name(ofFolder: "/Users/sam/Downloads", home: home) == "~/Downloads")
        #expect(WindowTitle.name(ofFolder: "/Users/sam", home: home + "/") == "~")
        #expect(WindowTitle.name(ofFolder: "/Users/samuel", home: home) == "/Users/samuel")
        #expect(WindowTitle.name(ofFolder: "/tmp", home: home) == "/tmp")
        #expect(WindowTitle.make(name: "~/Downloads", front: "zsh", folderName: "Downloads") == "~/Downloads — zsh")
        #expect(WindowTitle.make(name: "~/Downloads", front: "Downloads", folderName: "Downloads") == "~/Downloads")
        #expect(WindowTitle.make(name: "~", front: "~", folderName: "~") == "~")
        #expect(WindowTitle.make(name: "~", front: "vim", folderName: "~") == "~ — vim")
    }

    @Test func aServerIsNamedOnce() {
        // In a project's window, after the tab, unless the tab's own name says it.
        #expect(WindowTitle.make(name: "xCloud", front: "claude", host: "web-1") == "xCloud — claude — on web-1")
        #expect(WindowTitle.make(name: "xCloud", front: "web-1: app", host: "web-1") == "xCloud — web-1: app")
        #expect(WindowTitle.make(name: "xCloud", front: "web-1: app (connecting)", host: "web-1")
            == "xCloud — web-1: app (connecting)")
        // A server's window is named after it: the tab's name goes without it.
        #expect(WindowTitle.make(name: "web-1", front: "web-1: app", host: "web-1") == "web-1 — app")
        #expect(WindowTitle.make(name: "web-1", front: "claude", host: "web-1") == "web-1 — claude")
        #expect(WindowTitle.make(name: "web-1", front: nil, host: "web-1") == "web-1")
        // The editor in front: no host, the file is this Mac's.
        #expect(WindowTitle.make(name: "xCloud", front: "notes.md", host: nil) == "xCloud — notes.md")
    }
}
