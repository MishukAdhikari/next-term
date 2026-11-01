import Foundation
import Testing
@testable import NextTermCore

/// The window column's rows from made-up windows: ids are fixed, so a test can name them.
@Suite struct WindowColumnTests {
    private static let xcloud = "/Users/sam/Code/xCloud"

    private func tab(_ n: Int, _ state: TabState = .idle) -> WindowIndex.Tab {
        WindowIndex.Tab(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!, title: "zsh", state: state)
    }

    private func project(_ id: Int, _ name: String, _ tabs: [WindowIndex.Tab] = [], lastKey: Double = 0) -> WindowIndex.Window {
        WindowIndex.Window(id: id, kind: .project, project: "/Users/sam/Code/" + name, name: name, title: name,
                           lastKey: Date(timeIntervalSince1970: lastKey), tabs: tabs)
    }

    private func worktree(_ id: Int, _ own: String = "7027-sso", _ tabs: [WindowIndex.Tab] = [], title: String? = nil) -> WindowIndex.Window {
        let name: String = WorktreeWindow.title(repository: "xCloud", folder: own)
        return WindowIndex.Window(id: id, kind: .worktree, project: "/Users/sam/Code/xCloud-wt-" + own, name: name, title: title ?? name,
                                  lastKey: .distantPast, tabs: tabs, repository: Self.xcloud)
    }

    private func plain(_ id: Int, _ name: String = "~/Downloads", front: String? = nil) -> WindowIndex.Window {
        WindowIndex.Window(id: id, kind: .plain, project: nil, name: name, title: front.map { name + " — " + $0 } ?? name,
                           lastKey: .distantPast, tabs: [])
    }

    private func server(_ id: Int, _ name: String = "web-1", front: String = "app", destination: String = "deploy@203.0.113.5") -> WindowIndex.Window {
        WindowIndex.Window(id: id, kind: .server, project: nil, name: name, title: name + " — " + front, lastKey: .distantPast, tabs: [],
                           destination: destination)
    }

    private func project(_ id: Int, _ name: String, in folder: String, front: String? = nil) -> WindowIndex.Window {
        WindowIndex.Window(id: id, kind: .project, project: folder + "/" + name, name: name, title: front.map { name + " — " + $0 } ?? name,
                           lastKey: .distantPast, tabs: [])
    }

    private func list(_ windows: [WindowIndex.Window], colors: [Int: ProjectColor] = [:], working: Bool = true) -> WindowColumnList {
        WindowColumnList.build(windows: windows, colors: colors, showsWorking: working, home: "/Users/sam")
    }

    private func details(_ list: WindowColumnList) -> [String?] { list.rows.map(\.detail) }

    private func ids(_ list: WindowColumnList) -> [Int] { list.rows.map(\.id) }
    private func depths(_ list: WindowColumnList) -> [Int] { list.rows.map(\.depth) }
    private func names(_ list: WindowColumnList) -> [String] { list.rows.map(\.name) }

    // MARK: order and nesting

    @Test func rowsKeepTheOrderTheWindowsOpenedInAndALaterOneGoesLast() {
        let first: WindowColumnList = list([project(1, "next-term"), plain(2), server(3)])
        let order: [Int] = ids(first)
        #expect(order == [1, 2, 3])
        #expect(first.count == 3)
        // A window that has the keyboard later moves nothing: the order is the index's, not by use.
        let used: WindowColumnList = list([project(1, "next-term", lastKey: 5), plain(2), server(3), project(4, "shop", lastKey: 9)])
        let after: [Int] = ids(used)
        #expect(after == [1, 2, 3, 4])
    }

    @Test func aWorktreeGoesUnderItsRepositorysWindowShowingItsOwnPart() {
        let rows: WindowColumnList = list([project(1, "xCloud"), project(2, "shop"), worktree(3)])
        let order: [Int] = ids(rows)
        let nesting: [Int] = depths(rows)
        let shown: [String] = names(rows)
        #expect(order == [1, 3, 2])
        #expect(nesting == [0, 1, 0])
        #expect(shown == ["xCloud", "7027-sso", "shop"])
    }

    @Test func aWorktreeWithNoRepositoryWindowOpenStaysAtTheTopAfterItsRepositorysName() {
        let rows: WindowColumnList = list([project(2, "shop"), worktree(3)])
        let nesting: [Int] = depths(rows)
        let shown: [String] = names(rows)
        let prefixes: [String?] = rows.rows.map(\.prefix)
        #expect(nesting == [0, 0])
        #expect(shown == ["shop", "7027-sso"])
        #expect(prefixes == [nil, "xCloud"])
        // Under its repository's row, the prefix goes: the row above says it.
        let nested: WindowColumnList = list([project(1, "xCloud"), worktree(3)])
        let under: [String?] = nested.rows.map(\.prefix)
        #expect(under == [nil, nil])
    }

    @Test func aMainCheckoutOpenedAfterItsWorktreeLeadsItsGroup() {
        // The worktree opened first, so the group sits where it opened; the repository's window then leads it.
        let rows: WindowColumnList = list([worktree(1), project(2, "shop"), project(3, "xCloud"), worktree(4, "aichat")])
        let order: [Int] = ids(rows)
        let nesting: [Int] = depths(rows)
        let shown: [String] = names(rows)
        #expect(order == [3, 1, 4, 2])
        #expect(nesting == [0, 1, 1, 0])
        #expect(shown == ["xCloud", "7027-sso", "aichat", "shop"])
    }

    @Test func fiveWindowsOfEveryKindGiveFiveRowsInOrder() {
        // Two projects, the worktree, a ⌘N window and a server's: AE4's five, with an agent waiting in the worktree.
        let windows: [WindowIndex.Window] = [project(1, "next-term"), project(2, "xCloud"), worktree(3, "7027-sso", [tab(1), tab(2, .attention)]),
                                             plain(4), server(5)]
        let rows: WindowColumnList = list(windows, colors: [1: .sky, 2: .amber, 3: .amber])
        let order: [Int] = ids(rows)
        let shown: [String] = names(rows)
        let dots: [TabState?] = rows.rows.map(\.urgent)
        #expect(order == [1, 2, 3, 4, 5])
        #expect(shown == ["next-term", "xCloud", "7027-sso", "Downloads", "web-1"])
        #expect(dots == [nil, nil, .attention, nil, nil])
        #expect(rows.row(3)?.color == .amber && rows.row(2)?.color == .amber)
        // Every name differs: no row needs a detail.
        #expect(details(rows).allSatisfy { $0 == nil })
    }

    // MARK: names

    @Test func whatARowCallsEachKindOfWindow() {
        func shown(_ window: WindowIndex.Window, _ depth: Int = 0) -> String {
            let parts = WindowColumnName.shown(window, depth: depth)
            return (parts.prefix.map { $0 + " | " } ?? "") + parts.name
        }
        #expect(shown(project(1, "next-term")) == "next-term")
        #expect(shown(server(1)) == "web-1")
        #expect(shown(plain(1, "~")) == "~")
        #expect(shown(plain(1, "~/Downloads")) == "Downloads")
        #expect(shown(plain(1, "~/Code/next-term")) == "next-term")
        #expect(shown(plain(1, "/")) == "/")
        #expect(shown(plain(1, "/tmp")) == "tmp")
        #expect(shown(worktree(1, "7027-sso"), 1) == "7027-sso")
        #expect(shown(worktree(1, "7027-sso"), 0) == "xCloud | 7027-sso")
        // A worktree's folder named after its repository: the repository's name goes, as the row above says it.
        #expect(shown(worktree(1, "xCloud-cx-8858"), 1) == "cx-8858")
        #expect(shown(worktree(1, "xcloud_cx-8858"), 0) == "xCloud | cx-8858")
        #expect(WindowColumnName.stripped("xCloud-cx-8858", repository: "xCloud") == "cx-8858")
        #expect(WindowColumnName.stripped("xCloud.next", repository: "xcloud") == "next")
        #expect(WindowColumnName.stripped("xCloud-", repository: "xCloud") == "xCloud-")
        #expect(WindowColumnName.stripped("xCloudy", repository: "xCloud") == "xCloudy")
        #expect(WindowColumnName.stripped("7027-sso", repository: "xCloud") == "7027-sso")
        #expect(WindowColumnName.ownPart(of: "xCloud ▸ 7027-sso") == "7027-sso")
        #expect(WindowColumnName.ownPart(of: "shop") == "shop")
        #expect(WindowColumnName.repositoryPart(of: "xCloud ▸ 7027-sso") == "xCloud")
        #expect(WindowColumnName.repositoryPart(of: "shop") == nil)
    }

    @Test func whatIsInFrontIsTheTitleAfterTheName() {
        #expect(plain(1, "~", front: "claude").front == "claude")
        #expect(plain(1, "~").front == nil)
        #expect(server(1, front: "app").front == "app")
        #expect(project(1, "shop").front == nil)
    }

    // MARK: telling windows apart

    @Test func windowsOfTheSameNameAreToldApartByWhatIsInFront() {
        // Three windows at home: two with an agent each, one at its prompt.
        let rows: WindowColumnList = list([plain(1, "~", front: "claude"), plain(2, "~", front: "codex"), plain(3, "~"), project(4, "shop")])
        #expect(names(rows) == ["~", "~", "~", "shop"])
        #expect(details(rows) == ["claude", "codex", nil, nil])
        // The same in front in each tells nothing: none.
        let same: WindowColumnList = list([plain(1, "~", front: "zsh"), plain(2, "~", front: "zsh")])
        #expect(details(same) == [nil, nil])
    }

    @Test func windowsOfTheSameNameInDifferentFoldersAreToldApartByTheirFolders() {
        let rows: WindowColumnList = list([project(1, "app", in: "/Users/sam/Code", front: "claude"), project(2, "app", in: "/Users/sam/Work"),
                                           plain(3, "~/Code/api"), plain(4, "/srv/api")])
        #expect(details(rows) == ["~/Code", "~/Work", "~/Code", "/srv"])
        // Two windows on one server: what is in front, as their places are the same.
        let servers: WindowColumnList = list([server(1, front: "app"), server(2, front: "logs"), server(3, "web-2")])
        #expect(details(servers) == ["app", "logs", nil])
        // Two of three alike in their folder: those two by what is in front in them, the third by its folder.
        let mixed: WindowColumnList = list([plain(1, "~/Code/api", front: "claude"), plain(2, "~/Code/api", front: "codex"), plain(3, "/srv/api")])
        #expect(details(mixed) == ["claude", "codex", "/srv"])
        // Rows alike at a deeper step keep their folder where that step has nothing for them.
        let four: WindowColumnList = list([plain(1, "~/Code/api", front: "claude"), plain(2, "~/Code/api"), plain(3, "/srv/api", front: "npm run dev"),
                                           plain(4, "/srv/api")])
        #expect(details(four) == ["claude", "~/Code", "npm run dev", "/srv"])
        // Two worktrees whose own parts came to the same name: their folders' names tell them apart.
        let trees: WindowColumnList = list([project(1, "xCloud"), worktree(2, "xCloud-fix"), worktree(3, "fix")])
        #expect(names(trees) == ["xCloud", "fix", "fix"])
        #expect(details(trees) == [nil, "xCloud-wt-xCloud-fix", "xCloud-wt-fix"])
        // The same name on two servers: where each connects.
        let hosts: WindowColumnList = list([server(1, destination: "deploy@a"), server(2, destination: "deploy@b")])
        #expect(details(hosts) == ["deploy@a", "deploy@b"])
    }

    @Test func aRowsDetailFollowsItsWindowAndTheRowsBesideIt() {
        let start: WindowColumnList = list([plain(1, "~", front: "claude"), plain(2, "~"), project(3, "shop")])
        #expect(details(start) == ["claude", nil, nil])
        // The second starts a command: both rows are made again, and only the one whose detail changed is drawn.
        let ran = start.updating(plain(2, "~", front: "npm test"), color: nil, showsWorking: true)
        #expect(details(ran.list) == ["claude", "npm test", nil])
        #expect(ran.change == .rows([2]))
        // The first goes elsewhere: alone with its name now, neither row needs a detail.
        let moved = ran.list.updating(plain(1, "~/Downloads", front: "claude"), color: nil, showsWorking: true)
        #expect(names(moved.list) == ["Downloads", "~", "shop"])
        #expect(details(moved.list) == [nil, nil, nil])
        #expect(moved.change == .rows([1, 2]))
        // A row alone with its name: its title changes its words and nothing else.
        let retitled = moved.list.updating(project(3, "shop", in: "/Users/sam/Code", front: "vim"), color: nil, showsWorking: true)
        #expect(retitled.change == .rows([3]))
        #expect(retitled.list.row(3)?.face == moved.list.row(3)?.face)
    }

    @Test func theDotIsTheMostUrgentOfNeedsYouFailedAndDoneAndWorkingGivesNone() {
        #expect(WindowColumnRow.urgent(AgentMarks([.done, .failed, .attention])) == .attention)
        #expect(WindowColumnRow.urgent(AgentMarks([.done, .failed, .working])) == .failed)
        #expect(WindowColumnRow.urgent(AgentMarks([.done, .working, .idle])) == .done)
        #expect(WindowColumnRow.urgent(AgentMarks([.working, .working])) == nil)
        #expect(WindowColumnRow.urgent(AgentMarks()) == nil)
        var lost = AgentMarks()
        lost.disconnected = 1
        #expect(WindowColumnRow.urgent(lost) == nil)
        // The unfolded row still shows working, as ⌘O does, unless Agent Spinner is off.
        let busy: WindowColumnRow = list([project(1, "shop", [tab(1, .working)])]).rows[0]
        #expect(busy.marks == [AgentMarks.Mark(state: .working, count: 1)])
        let still: WindowColumnRow = list([project(1, "shop", [tab(1, .working)])], working: false).rows[0]
        #expect(still.marks.isEmpty)
    }

    @Test func theWordsGiveTheTitleAndTheMarks() {
        let waiting: WindowColumnRow = list([worktree(3, "7027-sso", [tab(1, .attention)])]).rows[0]
        #expect(waiting.label == "xCloud ▸ 7027-sso: 1 needs you")
        #expect(waiting.toolTip == "xCloud ▸ 7027-sso\n1 needs you")
        let quiet: WindowColumnRow = list([project(1, "shop")]).rows[0]
        #expect(quiet.label == "shop")
        #expect(quiet.toolTip == "shop")
        // The whole title, though the row shows less of it.
        let titled: WindowColumnRow = list([project(1, "xCloud"), worktree(3, "7027-sso", [tab(1, .done)], title: "xCloud ▸ 7027-sso — claude")]).rows[1]
        #expect(titled.name == "7027-sso")
        #expect(titled.label == "xCloud ▸ 7027-sso — claude: 1 done")
    }

    @Test func plainAndServerWindowsHaveNoColour() {
        let rows: WindowColumnList = list([plain(1), server(2), project(3, "shop")], colors: [1: .sky, 2: .rust, 3: .grass])
        let colors: [ProjectColor?] = rows.rows.map(\.color)
        #expect(colors == [nil, nil, .grass])
    }

    // MARK: changes

    @Test func aChangeSaysWhatItAsksOfAColumn() {
        let start: WindowColumnList = list([project(1, "shop", [tab(1)]), project(2, "xCloud", [tab(2)])])
        // Only when it last had the keyboard: nothing.
        let used = start.updating(project(1, "shop", [tab(1)], lastKey: 50), color: nil, showsWorking: true)
        #expect(used.change == .none)
        // Its title: the words, not the face.
        let renamed = WindowIndex.Window(id: 1, kind: .project, project: "/Users/sam/Code/shop", name: "shop", title: "shop — vim",
                                         lastKey: .distantPast, tabs: [tab(1)])
        let retitled = start.updating(renamed, color: nil, showsWorking: true)
        #expect(retitled.change == .rows([1]))
        let wasFace: WindowColumnRow.Face? = start.row(1)?.face
        let isFace: WindowColumnRow.Face? = retitled.list.row(1)?.face
        #expect(wasFace == isFace)
        #expect(start.row(1)?.words != retitled.list.row(1)?.words)
        // A bell: the face.
        let rang = start.updating(project(1, "shop", [tab(1, .attention)]), color: nil, showsWorking: true)
        #expect(rang.change == .rows([1]))
        #expect(rang.list.row(1)?.urgent == .attention)
        #expect(rang.list.row(2) == start.row(2))
        // A window not listed yet: the structure.
        let opened = start.updating(plain(3), color: nil, showsWorking: true)
        #expect(opened.change == .structure)
        let order: [Int] = ids(opened.list)
        #expect(order == [1, 2, 3])
    }

    @Test func aWindowTakingAProjectMovesIntoItsGroup() {
        let start: WindowColumnList = list([project(1, "xCloud"), plain(2), project(3, "shop")])
        // The plain window becomes the worktree's (Open as Project Window): it goes under its repository.
        let moved = start.updating(worktree(2), color: nil, showsWorking: true)
        #expect(moved.change == .structure)
        let order: [Int] = ids(moved.list)
        let nesting: [Int] = depths(moved.list)
        #expect(order == [1, 2, 3])
        #expect(nesting == [0, 1, 0])
    }

    @Test func aColourOrTheSpinnerChangedRedrawsOnlyTheRowsItChanged() {
        let windows: [WindowIndex.Window] = [project(1, "shop", [tab(1, .working)]), project(2, "xCloud"), plain(3)]
        let before: WindowColumnList = list(windows, colors: [1: .sky, 2: .amber])
        let recoloured: WindowColumnList = list(windows, colors: [1: .sky, 2: .plum])
        #expect(WindowColumnList.change(from: before, to: recoloured) == .rows([2]))
        let still: WindowColumnList = list(windows, colors: [1: .sky, 2: .amber], working: false)
        #expect(WindowColumnList.change(from: before, to: still) == .rows([1]))
        #expect(WindowColumnList.change(from: before, to: before) == .none)
        let closed: WindowColumnList = list(Array(windows.dropLast()), colors: [1: .sky, 2: .amber])
        #expect(WindowColumnList.change(from: before, to: closed) == .structure)
    }

    /// Done's quiet green (Theme.doneQuiet in the app, kept here as its hex) still reads as a mark, 3:1 at least, against
    /// the bar, the selected tab and a hovered one, and its dark ✓ (the bar's colour) against it.
    @Test func theQuietDoneMarkStillReads() {
        let quiet: UInt32 = 0x529558
        for back: UInt32 in [0x2B2D30, 0x1E1F22, 0x393B40] {
            #expect(ProjectColor.contrast(quiet, back) >= 3, "\(String(back, radix: 16))")
        }
        #expect(ProjectColor.contrast(0x2B2D30, quiet) >= 3)
        // Plain green, with Increase Contrast, under the same dark ✓.
        #expect(ProjectColor.contrast(0x2B2D30, 0x5FB865) >= 5)
    }
}

