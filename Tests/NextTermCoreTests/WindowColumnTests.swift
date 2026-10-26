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

    private func plain(_ id: Int, _ name: String = "~/Downloads") -> WindowIndex.Window {
        WindowIndex.Window(id: id, kind: .plain, project: nil, name: name, title: name, lastKey: .distantPast, tabs: [])
    }

    private func server(_ id: Int, _ name: String = "web-1") -> WindowIndex.Window {
        WindowIndex.Window(id: id, kind: .server, project: nil, name: name, title: name + " — app", lastKey: .distantPast, tabs: [],
                           destination: "deploy@203.0.113.5")
    }

    private func list(_ windows: [WindowIndex.Window], colors: [Int: ProjectColor] = [:], working: Bool = true) -> WindowColumnList {
        WindowColumnList.build(windows: windows, colors: colors, showsWorking: working)
    }

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

    @Test func aWorktreeWithNoRepositoryWindowOpenStaysAtTheTopWithItsWholeName() {
        let rows: WindowColumnList = list([project(2, "shop"), worktree(3)])
        let nesting: [Int] = depths(rows)
        let shown: [String] = names(rows)
        #expect(nesting == [0, 0])
        #expect(shown == ["shop", "xCloud ▸ 7027-sso"])
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

    @Test func fiveWindowsOfEveryKindGiveFiveBadgesInOrder() {
        // Two projects, the worktree, a ⌘N window and a server's: AE4's five, with an agent waiting in the worktree.
        let windows: [WindowIndex.Window] = [project(1, "next-term"), project(2, "xCloud"), worktree(3, "7027-sso", [tab(1), tab(2, .attention)]),
                                             plain(4), server(5)]
        let rows: WindowColumnList = list(windows, colors: [1: .sky, 2: .amber, 3: .amber])
        let order: [Int] = ids(rows)
        let letters: [String] = rows.rows.map(\.letters)
        let dots: [TabState?] = rows.rows.map(\.urgent)
        #expect(order == [1, 2, 3, 4, 5])
        #expect(letters == ["NT", "XC", "7S", "Do", "W1"])
        #expect(dots == [nil, nil, .attention, nil, nil])
        #expect(rows.row(3)?.color == .amber && rows.row(2)?.color == .amber)
    }

    // MARK: badges

    @Test func theLettersOfEachKindOfName() {
        #expect(WindowColumnBadge.letters(name: "next-term", kind: .project) == "NT")
        #expect(WindowColumnBadge.letters(name: "xCloud", kind: .project) == "XC")
        #expect(WindowColumnBadge.letters(name: "xCloud ▸ 7027-sso", kind: .worktree) == "7S")
        #expect(WindowColumnBadge.letters(name: "7027-sso", kind: .worktree) == "7S")
        #expect(WindowColumnBadge.letters(name: "web-1", kind: .server) == "W1")
        #expect(WindowColumnBadge.letters(name: "shop", kind: .project) == "Sh")
        #expect(WindowColumnBadge.letters(name: "~", kind: .plain) == "~")
        #expect(WindowColumnBadge.letters(name: "~/Downloads", kind: .plain) == "Do")
        #expect(WindowColumnBadge.letters(name: "/", kind: .plain) == "/")
        #expect(WindowColumnBadge.letters(name: "a", kind: .project) == "A")
        #expect(WindowColumnBadge.letters(name: "my app", kind: .project) == "MA")
        #expect(WindowColumnBadge.ownPart(of: "xCloud ▸ 7027-sso") == "7027-sso")
        #expect(WindowColumnBadge.ownPart(of: "shop") == "shop")
    }

    @Test func theDotIsTheMostUrgentOfNeedsYouFailedAndDoneAndWorkingGivesNone() {
        #expect(WindowColumnBadge.urgent(AgentMarks([.done, .failed, .attention])) == .attention)
        #expect(WindowColumnBadge.urgent(AgentMarks([.done, .failed, .working])) == .failed)
        #expect(WindowColumnBadge.urgent(AgentMarks([.done, .working, .idle])) == .done)
        #expect(WindowColumnBadge.urgent(AgentMarks([.working, .working])) == nil)
        #expect(WindowColumnBadge.urgent(AgentMarks()) == nil)
        var lost = AgentMarks()
        lost.disconnected = 1
        #expect(WindowColumnBadge.urgent(lost) == nil)
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

    @Test func capitalsAndFiguresAreSetApartMixedCaseNot() {
        for letters in ["XC", "7S", "73", "MV"] { #expect(WindowColumnBadge.tracks(letters), "\(letters)") }
        for letters in ["Ai", "Sh", "Ag", "~", "X", ""] { #expect(!WindowColumnBadge.tracks(letters), "\(letters)") }
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

