import Foundation
import Testing
@testable import NextTermCore

/// Made-up folders under a made-up home, made-up hosts.
@Suite struct ProjectSwitcherTests {
    private let home = "/Users/sam"

    private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    private func window(_ path: String, _ seconds: Double, title: String? = nil) -> SwitcherList.Window {
        let name: String = (path as NSString).lastPathComponent
        return SwitcherList.Window(path: path, title: title ?? name, lastKey: at(seconds))
    }

    private func used(_ path: String, _ seconds: Double) -> ProjectHistory.Entry {
        ProjectHistory.Entry(path: path, lastUsed: at(seconds))
    }

    private func project(_ path: String, windows: Int = 0, title: String? = nil) -> SwitcherProject {
        let name: String = (path as NSString).lastPathComponent
        return SwitcherProject(path: path, title: title ?? name, windows: windows, lastUsed: nil)
    }

    private func server(_ name: String, _ destination: String = "deploy@203.0.113.5") -> SwitcherServer {
        SwitcherServer(id: "id-" + name, name: name, destination: destination)
    }

    private func paths(_ projects: [SwitcherProject]) -> [String] { projects.map(\.path) }

    private func names(_ shown: SwitcherShown) -> [String] {
        let projects: [String] = shown.projects.map(\.name)
        let servers: [String] = shown.servers.map(\.name)
        return projects + servers
    }

    private func check(_ found: [String], _ expected: [String]) {
        // Compared outside `#expect`, where arrays are slow to type-check.
        let same: Bool = found == expected
        #expect(same, "\(found), expected \(expected)")
    }

    // MARK: the list

    @Test func openProjectsComeFirstByTheirNewestWindowThenTheHistoryThenRecents() {
        let windows: [SwitcherList.Window] = [
            window("/Users/sam/Code/api", 100),
            window("/Users/sam/Code/shop", 300),
            window("/Users/sam/Code/api", 200),
        ]
        let history: [ProjectHistory.Entry] = [
            used("/Users/sam/Code/docs", 250),
            used("/Users/sam/Code/wiki", 150),
            used("/Users/sam/Code/shop", 50),
        ]
        // wiki is in the history too, shop is open, old is given twice.
        let recents: [String] = [
            "/Users/sam/Code/wiki", "/Users/sam/Code/old", "/Users/sam/Code/shop", "/Users/sam/Code/old",
        ]
        let list = SwitcherList.build(open: windows, history: history, recents: recents, servers: [])
        let expected: [String] = ["shop", "api", "docs", "wiki", "old"].map { "/Users/sam/Code/" + $0 }
        check(paths(list.projects), expected)
        #expect(list.projects[0].windows == 1)
        #expect(list.projects[0].lastUsed == at(300))
        #expect(list.projects[1].windows == 2)
        #expect(list.projects[1].lastUsed == at(200))
        #expect(list.projects[2].windows == 0)
        #expect(list.projects[2].lastUsed == at(250))
        #expect(list.projects[4].lastUsed == nil)
        #expect(list.openCount == 2)
        #expect(list.projects[0].isOpen && !list.projects[2].isOpen)
    }

    @Test func openProjectsInFrontAtTheSameMomentKeepTheOrderGiven() {
        let windows: [SwitcherList.Window] = [
            window("/Users/sam/b", 100), window("/Users/sam/a", 100), window("/Users/sam/c", 200),
        ]
        let list = SwitcherList.build(open: windows, history: [], recents: [], servers: [])
        check(paths(list.projects), ["/Users/sam/c", "/Users/sam/b", "/Users/sam/a"])
        // A window never in front sorts after every other, and is still open.
        let never = SwitcherList.Window(path: "/Users/sam/d", title: "d", lastKey: .distantPast)
        let withNever = SwitcherList.build(open: [never] + windows, history: [], recents: [], servers: [])
        #expect(withNever.projects.last?.path == "/Users/sam/d")
        #expect(withNever.projects.last?.isOpen == true)
    }

    @Test func aWorktreeKeepsItsTitleOpenOrClosed() {
        let worktree = "/Users/sam/Code/xCloud-worktrees/7027-sso"
        let open = window(worktree, 100, title: "xCloud ▸ 7027-sso")
        let list = SwitcherList.build(open: [open], history: [], recents: [], servers: [])
        #expect(list.projects.first?.title == "xCloud ▸ 7027-sso")
        #expect(list.projects.first?.name == "7027-sso")
        // Closed: the title read for it, else its folder's name until it is read.
        let history: [ProjectHistory.Entry] = [used(worktree, 50), used("/Users/sam/Code/shop", 40)]
        let titles: [String: String] = [worktree: "xCloud ▸ 7027-sso"]
        let closed = SwitcherList.build(open: [], history: history, recents: [], servers: [], titles: titles)
        #expect(closed.projects.first?.title == "xCloud ▸ 7027-sso")
        #expect(closed.projects.last?.title == "shop")
        let unread = SwitcherList.build(open: [], history: history, recents: [], servers: [])
        #expect(unread.projects.first?.title == "7027-sso")
    }

    @Test func serversFollowAsGivenAndAnEmptySearchListsThree() {
        let servers: [SwitcherServer] = [server("staging"), server("prod"), server("db"), server("ci")]
        let list = SwitcherList.build(open: [], history: [], recents: [], servers: servers)
        check(list.servers.map(\.name), ["staging", "prod", "db", "ci"])
        #expect(SwitcherList.serverLimit == 3)
        let shown = SwitcherSearch.filter(list, query: "  ", home: home)
        check(shown.servers.map(\.name), ["staging", "prod", "db"])
        #expect(!list.isEmpty)
        #expect(SwitcherList.build(open: [], history: [], recents: [], servers: []).isEmpty)
    }

    // MARK: the search

    @Test func ranksTheNameStartThenAWordStartThenInsideTheNameThenTheFolder() {
        // In the list's order, which is not the ranking's.
        let projects: [SwitcherProject] = [
            project("/Users/sam/sh-tools/zeta"),
            project("/Users/sam/Code/fresh"),
            project("/Users/sam/Code/bash-shell"),
            project("/Users/sam/Code/shop"),
            project("/Users/sam/Code/myShelf"),
        ]
        let list = SwitcherList(projects: projects, servers: [])
        let shown = SwitcherSearch.filter(list, query: "sh", home: home)
        check(names(shown), ["shop", "bash-shell", "myShelf", "fresh", "zeta"])
        // Case and accents are ignored.
        let accented = SwitcherList(projects: [project("/Users/sam/Code/Résumé-site")], servers: [])
        #expect(SwitcherSearch.filter(accented, query: "RESUME", home: home).projects.count == 1)
    }

    @Test func everyWordMustMatchAndAnEntryRanksByItsWeakestWord() {
        let projects: [SwitcherProject] = [
            project("/Users/sam/Code/api"),
            project("/Users/sam/Work/api"),
            project("/Users/sam/Work/api-core"),
        ]
        let list = SwitcherList(projects: projects, servers: [])
        // "co" is only in ~/Code/api's folder and api-core's name.
        let shown = SwitcherSearch.filter(list, query: "co api", home: home)
        check(paths(shown.projects), ["/Users/sam/Work/api-core", "/Users/sam/Code/api"])
        let one = SwitcherSearch.filter(list, query: "api", home: home)
        check(paths(one.projects), paths(projects))
        #expect(SwitcherSearch.filter(list, query: "api zz", home: home).isEmpty)
    }

    @Test func theFoldersAboveTheHomeFolderNeverMatch() {
        let projects: [SwitcherProject] = [project("/Users/sam/Code/shop"), project("/Users/sam/Work/samples")]
        let list = SwitcherList(projects: projects, servers: [])
        check(paths(SwitcherSearch.filter(list, query: "sam", home: home).projects), ["/Users/sam/Work/samples"])
        #expect(SwitcherSearch.filter(list, query: "users", home: home).isEmpty)
        #expect(SwitcherSearch.filter(list, query: "users", home: home + "/").isEmpty)
        // The folder from the home down still matches.
        check(paths(SwitcherSearch.filter(list, query: "~/code", home: home).projects), ["/Users/sam/Code/shop"])
        // A folder outside the home is matched as it is.
        let outside = SwitcherList(projects: [project("/Volumes/Disk/site")], servers: [])
        #expect(SwitcherSearch.filter(outside, query: "volumes", home: home).projects.count == 1)
    }

    @Test func branchesAndWorktreeTitlesMatchAfterNames() {
        let worktree = "/Users/sam/Code/xCloud-worktrees/7027-sso"
        let projects: [SwitcherProject] = [
            project("/Users/sam/Code/shop"),
            project(worktree, title: "xCloud ▸ 7027-sso"),
            project("/Users/sam/Code/docs"),
            project("/Users/sam/Code/main-site"),
            project("/Users/sam/Code/xCloud"),
        ]
        let list = SwitcherList(projects: projects, servers: [])
        let branches: [String: String] = [
            "/Users/sam/Code/shop": "main", "/Users/sam/Code/docs": "dev", "/Users/sam/Code/main-site": "dev",
        ]
        let main = SwitcherSearch.filter(list, query: "main", home: home, branches: branches)
        check(names(main), ["main-site", "shop"])
        let xcloud = SwitcherSearch.filter(list, query: "xcloud", home: home, branches: branches)
        check(names(xcloud), ["xCloud", "7027-sso"])
        let sso = SwitcherSearch.filter(list, query: "sso", home: home, branches: branches)
        check(names(sso), ["7027-sso"])
    }

    @Test func tiesKeepTheListOrder() {
        let projects: [SwitcherProject] = [
            project("/Users/sam/b/web-app"), project("/Users/sam/a/web-site"), project("/Users/sam/web"),
        ]
        let list = SwitcherList(projects: projects, servers: [])
        check(names(SwitcherSearch.filter(list, query: "web", home: home)), ["web-app", "web-site", "web"])
    }

    @Test func serversAreSearchedPastTheFirstThreeByNameThenDestination() {
        let servers: [SwitcherServer] = [
            server("staging", "deploy@staging.example.com"),
            server("db"),
            server("ci"),
            server("prod", "root@198.51.100.7"),
            server("web-prod-2", "web@203.0.113.9"),
        ]
        let list = SwitcherList(projects: [project("/Users/sam/Code/product")], servers: servers)
        let pro = SwitcherSearch.filter(list, query: "pro", home: home)
        check(names(pro), ["product", "prod", "web-prod-2"])
        let staging = SwitcherSearch.filter(list, query: "staging", home: home)
        check(names(staging), ["staging"])
        let byDestination = SwitcherSearch.filter(list, query: "198.51", home: home)
        check(names(byDestination), ["prod"])
        // Projects come before servers, and entries list both in that order.
        let entries: [SwitcherEntry.ID] = pro.entries.map(\.id)
        let expected: [SwitcherEntry.ID] = [
            .project("/Users/sam/Code/product"), .server("id-prod"), .server("id-web-prod-2"),
        ]
        let same: Bool = entries == expected
        #expect(same, "\(entries)")
    }

    @Test func noMatchSaysWhatWasTyped() {
        let list = SwitcherList(projects: [project("/Users/sam/Code/shop")], servers: [server("prod")])
        let shown = SwitcherSearch.filter(list, query: "staging", home: home)
        #expect(shown.isEmpty)
        #expect(shown.entries.isEmpty)
        #expect(SwitcherSearch.noMatch(" staging ") == "No project or server matches “staging”.")
    }

    // MARK: where the selection starts

    /// shop and api open, shop's window in front last; docs closed; the servers staging and prod.
    private var twoOpen: SwitcherShown {
        let windows: [SwitcherList.Window] = [window("/Users/sam/Code/api", 100), window("/Users/sam/Code/shop", 200)]
        let history: [ProjectHistory.Entry] = [used("/Users/sam/Code/docs", 50)]
        let servers: [SwitcherServer] = [server("prod"), server("staging")]
        let list = SwitcherList.build(open: windows, history: history, recents: [], servers: servers)
        return SwitcherSearch.filter(list, query: "", home: home)
    }

    @Test func fromAProjectWindowOnTheOtherOpenProjectUsedLast() {
        let shown = twoOpen
        check(names(shown), ["shop", "api", "docs", "prod", "staging"])
        #expect(SwitcherSelection.initial(shown, origin: "/Users/sam/Code/shop", lastPick: nil) == 1)
        // From api's window, shop is the other one.
        #expect(SwitcherSelection.initial(shown, origin: "/Users/sam/Code/api", lastPick: nil) == 0)
        // A server picked last does not move it: Return switches back.
        #expect(SwitcherSelection.initial(shown, origin: "/Users/sam/Code/shop", lastPick: "id-staging") == 1)
    }

    @Test func fromTheOnlyOpenProjectOnTheFirstClosedOne() {
        let windows: [SwitcherList.Window] = [window("/Users/sam/Code/shop", 200)]
        let history: [ProjectHistory.Entry] = [used("/Users/sam/Code/docs", 50), used("/Users/sam/Code/wiki", 40)]
        let list = SwitcherList.build(open: windows, history: history, recents: [], servers: [server("prod")])
        let shown = SwitcherSearch.filter(list, query: "", home: home)
        #expect(SwitcherSelection.initial(shown, origin: "/Users/sam/Code/shop", lastPick: nil) == 1)
        // Nothing else listed but servers: the first row.
        let alone = SwitcherList.build(open: windows, history: [], recents: [], servers: [server("prod")])
        let aloneShown = SwitcherSearch.filter(alone, query: "", home: home)
        #expect(SwitcherSelection.initial(aloneShown, origin: "/Users/sam/Code/shop", lastPick: nil) == 0)
    }

    @Test func notFromAProjectWindowOnTheServerPickedLastWhileItIsSaved() {
        let shown = twoOpen
        #expect(SwitcherSelection.initial(shown, origin: nil, lastPick: "id-staging") == 4)
        #expect(SwitcherSelection.initial(shown, origin: nil, lastPick: "id-gone") == 0)
        #expect(SwitcherSelection.initial(shown, origin: nil, lastPick: nil) == 0)
        let empty = SwitcherSearch.filter(SwitcherList(projects: [], servers: []), query: "", home: home)
        #expect(SwitcherSelection.initial(empty, origin: nil, lastPick: "id-staging") == nil)
        #expect(SwitcherSelection.initial(empty, origin: "/Users/sam/Code/shop", lastPick: nil) == nil)
        #expect(SwitcherSelection.lastPickKey == "welcomeLastPick")
    }

    @Test func theServerPickedLastIsListedAndSelectedPastTheFirstThree() {
        // Connected to three others since, from the remote sheet: staging is fourth in the saved order.
        let servers: [SwitcherServer] = [server("a"), server("b"), server("c"), server("staging"), server("d")]
        let list = SwitcherList.build(open: [], history: [used("/Users/sam/Code/shop", 50)], recents: [],
                                      servers: servers)
        let shown = SwitcherSearch.filter(list, query: "", home: home, lastPick: "id-staging")
        // Still three servers, the pick in the third place.
        check(names(shown), ["shop", "a", "b", "staging"])
        #expect(SwitcherSelection.initial(shown, origin: nil, lastPick: "id-staging") == 3)
        // Among the first three already: the three as given.
        let inFirstThree = SwitcherSearch.filter(list, query: "", home: home, lastPick: "id-b")
        check(names(inFirstThree), ["shop", "a", "b", "c"])
        // No longer saved, or none: the first three.
        let gone = SwitcherSearch.filter(list, query: "", home: home, lastPick: "id-gone")
        check(names(gone), ["shop", "a", "b", "c"])
        #expect(SwitcherSelection.initial(gone, origin: nil, lastPick: "id-gone") == 0)
        // A search lists what it finds, picked last or not.
        let typed = SwitcherSearch.filter(list, query: "b", home: home, lastPick: "id-staging")
        check(names(typed), ["b"])
    }

    @Test func typingSelectsTheBestMatchAndEmptyingGoesBackToTheStart() {
        // Nothing open; api used an hour ago, shop yesterday, docs last week. Servers staging (picked last) and prod.
        let history: [ProjectHistory.Entry] = [
            used("/Users/sam/Code/api", 300), used("/Users/sam/Code/shop", 200), used("/Users/sam/Code/docs", 100),
        ]
        let list = SwitcherList.build(open: [], history: history, recents: [],
                                      servers: [server("staging"), server("prod")])
        let all = SwitcherSearch.filter(list, query: "", home: home)
        #expect(SwitcherSelection.initial(all, origin: nil, lastPick: nil) == 0)
        let sh = SwitcherSearch.filter(list, query: "sh", home: home)
        check(names(sh), ["shop"])
        #expect(SwitcherSelection.afterSearch(sh, query: "sh", origin: nil, lastPick: nil) == 0)
        // Starting on staging, "pro" finds only prod, and selects it.
        #expect(SwitcherSelection.initial(all, origin: nil, lastPick: "id-staging") == 3)
        let pro = SwitcherSearch.filter(list, query: "pro", home: home, lastPick: "id-staging")
        check(names(pro), ["prod"])
        #expect(SwitcherSelection.afterSearch(pro, query: "pro", origin: nil, lastPick: "id-staging") == 0)
        // No match: nothing selected, so Return does nothing.
        let none = SwitcherSearch.filter(list, query: "zz", home: home)
        #expect(SwitcherSelection.afterSearch(none, query: "zz", origin: nil, lastPick: nil) == nil)
        // Emptied, or only spaces left: where the window started it.
        #expect(SwitcherSelection.afterSearch(all, query: "", origin: nil, lastPick: "id-staging") == 3)
        #expect(SwitcherSelection.afterSearch(all, query: "  ", origin: nil, lastPick: "id-staging") == 3)
        let fromShop = twoOpen
        #expect(SwitcherSelection.afterSearch(fromShop, query: "", origin: "/Users/sam/Code/shop", lastPick: nil) == 1)
    }

    @Test func movingStopsAtTheEnds() {
        #expect(SwitcherSelection.moved(nil, by: 1, count: 3) == 0)
        #expect(SwitcherSelection.moved(nil, by: -1, count: 3) == 2)
        #expect(SwitcherSelection.moved(0, by: -1, count: 3) == 0)
        #expect(SwitcherSelection.moved(1, by: 1, count: 3) == 2)
        #expect(SwitcherSelection.moved(1, by: 10, count: 3) == 2)
        #expect(SwitcherSelection.moved(2, by: -10, count: 3) == 0)
        let inNothing: Int? = SwitcherSelection.moved(0, by: 1, count: 0)
        #expect(inNothing == nil)
    }

    // MARK: keys

    private var openShop: SwitcherEntry { .project(project("/Users/sam/Code/shop", windows: 1)) }
    private var closedDocs: SwitcherEntry { .project(project("/Users/sam/Code/docs")) }
    private var prod: SwitcherEntry { .server(server("prod")) }

    private func command(_ key: String) -> KeyChord { KeyChord(key: key, command: true) }

    @Test func theSearchMovesSwitchesAndClears() {
        func act(_ selector: String, empty: Bool = true, selection: SwitcherEntry? = nil,
                 others: Bool = true) -> SwitcherAction? {
            let entry: SwitcherEntry = selection ?? openShop
            return SwitcherKeys.action(selector: selector, searchEmpty: empty, selection: entry, otherWindows: others)
        }
        #expect(act("moveDown:") == .move(1))
        #expect(act("moveUp:") == .move(-1))
        #expect(act("pageDown:") == .page(1))
        #expect(act("scrollPageDown:") == .page(1))
        #expect(act("pageUp:") == .page(-1))
        #expect(act("scrollPageUp:") == .page(-1))
        #expect(act("insertNewline:") == .activate(newWindow: false))
        #expect(act("insertNewline:", selection: prod) == .activate(newWindow: false))
        // No match, nothing selected: Return does nothing.
        let nothing: SwitcherAction? = SwitcherKeys.action(selector: "insertNewline:", searchEmpty: false,
                                                           selection: nil, otherWindows: true)
        #expect(nothing == nil)
        #expect(act("cancelOperation:", empty: false) == .clearSearch)
        #expect(act("cancelOperation:", empty: false, others: false) == .clearSearch)
        #expect(act("cancelOperation:") == .close)
        // The only window: Esc never leaves the app without one.
        #expect(act("cancelOperation:", others: false) == nil)
        #expect(act("moveLeft:") == nil)
        #expect(act("deleteToBeginningOfLine:", empty: false) == nil)
    }

    @Test func commandKeysTakenBeforeTheMenus() {
        let keys = SwitcherKeys.standard
        func act(_ chord: KeyChord, _ focus: SwitcherKeys.Focus = .projects, empty: Bool = true,
                 selection: SwitcherEntry? = nil) -> SwitcherAction? {
            let entry: SwitcherEntry = selection ?? openShop
            return keys.action(chord: chord, focus: focus, searchEmpty: empty, selection: entry, projects: 12)
        }
        #expect(act(command("1")) == .jump(0))
        #expect(act(command("3")) == .jump(2))
        #expect(act(command("9")) == .jump(8))
        #expect(act(command("3"), .sessions) == .jump(2))
        #expect(act(command("w")) == .close)
        #expect(act(command("w"), .elsewhere) == .close)
        #expect(act(SwitcherKeys.newWindow) == .activate(newWindow: true))
        #expect(act(SwitcherKeys.newWindow, selection: closedDocs) == .activate(newWindow: true))
        // On a server ⌘↩ does what Return does.
        #expect(act(SwitcherKeys.newWindow, selection: prod) == .activate(newWindow: false))
        // ⌥⌘O gives ⌘↩ to Fork: the sessions search keeps it.
        #expect(act(SwitcherKeys.newWindow, .sessions) == nil)
        #expect(act(SwitcherKeys.newWindow, .elsewhere) == nil)
        let noSelection: SwitcherAction? = keys.action(chord: SwitcherKeys.newWindow, focus: .projects,
                                                       searchEmpty: false, selection: nil, projects: 0)
        #expect(noSelection == nil)
        #expect(act(KeyChord(key: "n", control: true)) == .move(1))
        #expect(act(KeyChord(key: "p", control: true)) == .move(-1))
        #expect(act(KeyChord(key: "n", control: true), .sessions) == nil)
        #expect(act(command("0")) == nil)
        #expect(act(KeyChord(key: "3", command: true, shift: true)) == nil)
    }

    @Test func forgetOnlyAClosedProjectWhileTheSearchIsEmpty() {
        let keys = SwitcherKeys.standard
        let forget: KeyChord = SwitcherKeys.forget
        #expect(forget == KeyChord(key: "\u{8}", command: true))
        func act(_ focus: SwitcherKeys.Focus = .projects, empty: Bool = true,
                 selection: SwitcherEntry?) -> SwitcherAction? {
            keys.action(chord: forget, focus: focus, searchEmpty: empty, selection: selection, projects: 2)
        }
        #expect(act(selection: closedDocs) == .forget)
        // Open projects cannot be forgotten, nor servers here.
        #expect(act(selection: openShop) == nil)
        #expect(act(selection: prod) == nil)
        // With text, the field's own delete to the start of the line.
        #expect(act(empty: false, selection: closedDocs) == nil)
        #expect(act(.sessions, selection: closedDocs) == nil)
        #expect(act(selection: nil) == nil)
    }

    @Test func rebindingsCarryOver() {
        var jumps: [KeyChord?] = (1...9).map { (n: Int) -> KeyChord? in KeyChord(key: "\(n)", command: true) }
        jumps[0] = KeyChord(key: "1", control: true)
        jumps[8] = nil
        let keys = SwitcherKeys(jumps: jumps, close: KeyChord(key: "w", command: true, option: true))
        func act(_ chord: KeyChord) -> SwitcherAction? {
            keys.action(chord: chord, focus: .projects, searchEmpty: true, selection: openShop, projects: 12)
        }
        #expect(act(KeyChord(key: "1", control: true)) == .jump(0))
        #expect(act(command("1")) == nil)
        #expect(act(command("9")) == nil)
        #expect(act(command("2")) == .jump(1))
        #expect(act(KeyChord(key: "w", command: true, option: true)) == .close)
        #expect(act(command("w")) == nil)
        let standard: [KeyChord?] = SwitcherKeys.standard.jumps
        #expect(standard.count == 9)
        #expect(SwitcherKeys.standard.close == command("w"))
    }

    @Test func jumpsReachOnlyTheProjectsListed() {
        let keys = SwitcherKeys.standard
        func act(_ chord: KeyChord, projects: Int) -> SwitcherAction? {
            keys.action(chord: chord, focus: .projects, searchEmpty: true, selection: openShop, projects: projects)
        }
        // One project listed: ⌘1 jumps to it, ⌘3 is left to the menus.
        #expect(act(command("1"), projects: 1) == .jump(0))
        #expect(act(command("3"), projects: 1) == nil)
        // Two projects, then servers: the third row is a server, which ⌘3 does not reach.
        #expect(act(command("2"), projects: 2) == .jump(1))
        #expect(act(command("3"), projects: 2) == nil)
        // A search that finds no project: no jump at all.
        #expect(act(command("1"), projects: 0) == nil)
        // Past nine projects, the tenth has no key.
        #expect(act(command("9"), projects: 20) == .jump(8))
        // No hint on a row a jump does not reach, a server's among them.
        #expect(keys.jumpHint(1, projects: 2) == "⌘2")
        #expect(keys.jumpHint(2, projects: 2) == nil)
        #expect(keys.jumpHint(0, projects: 0) == nil)
    }

    @Test func heldCommandShowsEachRowsJumpKey() {
        let keys = SwitcherKeys.standard
        #expect(keys.jumpHint(0, projects: 12) == "⌘1")
        #expect(keys.jumpHint(8, projects: 12) == "⌘9")
        #expect(keys.jumpHint(9, projects: 12) == nil)
        #expect(keys.jumpHint(-1, projects: 12) == nil)
        // A number whose command has no key: no jump and no hint.
        var jumps: [KeyChord?] = keys.jumps
        jumps[2] = nil
        let unbound = SwitcherKeys(jumps: jumps, close: nil)
        #expect(unbound.jumpHint(2, projects: 12) == nil)
        let noClose: SwitcherAction? = unbound.action(chord: command("w"), focus: .projects, searchEmpty: true,
                                                      selection: openShop, projects: 12)
        #expect(noClose == nil)
        // Read from Window › Select Tab 1–9 and File › Close Tab.
        let ids: [String] = (1...9).map { (n: Int) -> String in "selectTabByNumber:#\(n)" }
        check(SwitcherKeys.jumpCommands, ids)
        #expect(SwitcherKeys.closeCommand == "closeTab:")
    }

    // MARK: the hint line

    @Test func theHintSaysWhatTheKeysDoForTheSelection() {
        let open = SwitcherHint.parts(selection: openShop, searchEmpty: true, otherWindows: true)
        check(open, ["↩ go to window", "⌘↩ new window", "esc close"])
        let closed = SwitcherHint.parts(selection: closedDocs, searchEmpty: true, otherWindows: true)
        check(closed, ["↩ open", "⌘↩ new window", "esc close"])
        let server = SwitcherHint.parts(selection: prod, searchEmpty: true, otherWindows: true)
        check(server, ["↩ connect", "esc close"])
        // At launch, the only window: Esc does not close it.
        let alone = SwitcherHint.parts(selection: openShop, searchEmpty: true, otherWindows: false)
        check(alone, ["↩ go to window", "⌘↩ new window"])
        // With text, Esc empties the search first.
        let typing = SwitcherHint.parts(selection: closedDocs, searchEmpty: false, otherWindows: true)
        check(typing, ["↩ open", "⌘↩ new window"])
    }

    @Test func withNothingSelectedTheHintGivesTheThreeWaysInWithTheirKeys() {
        let none = SwitcherHint.parts(selection: nil, searchEmpty: false, otherWindows: true)
        check(none, ["⌘O open…", "⌥⌘T connect to server…", "⌘N new terminal"])
        // An empty list on an empty search, another window open: Esc closes.
        let empty = SwitcherHint.parts(selection: nil, searchEmpty: true, otherWindows: true)
        check(empty, ["⌘O open…", "⌥⌘T connect to server…", "⌘N new terminal", "esc close"])
        // The menus' keys now: a rebinding carries over, a way in with no key is left out.
        let shiftO = KeyChord(key: "o", command: true, shift: true)
        let rebound = SwitcherWaysIn(open: shiftO, connect: nil, newTerminal: command("n"))
        let parts = SwitcherHint.parts(selection: nil, searchEmpty: false, otherWindows: false, waysIn: rebound)
        check(parts, ["⇧⌘O open…", "⌘N new terminal"])
        #expect(SwitcherWaysIn.standard.connect == KeyChord(key: "t", command: true, option: true))
        check(SwitcherWaysIn.commands, ["openProjectPanel:", "newRemoteTab:", "newWindow:"])
    }

    @Test func hintsUseOneEllipsisAndNoSpacesForLayout() {
        let entries: [SwitcherEntry?] = [openShop, closedDocs, prod, nil]
        for entry in entries {
            for part in SwitcherHint.parts(selection: entry, searchEmpty: true, otherWindows: true) {
                #expect(!part.contains("  "), "\(part)")
                #expect(!part.contains("..."), "\(part)")
                #expect(part == part.trimmingCharacters(in: .whitespaces), "\(part)")
            }
        }
    }

    // MARK: the three ways in

    @Test func theThreeWaysInKeepOneOrderAndSayWhatTheyOpen() {
        let ways: [SwitcherWayIn] = SwitcherWayIn.allCases
        #expect(ways == [.open, .connect, .newTerminal])
        check(ways.map(\.title), ["Open…", "Connect to Server…", "New Terminal"])
        check(ways.map(\.symbol), ["folder", "server.rack", "terminal"])
        // What each one's tooltip says, before the key the menus give it.
        let help: [String] = ways.map(\.help)
        check(help, ["Open a folder as a project", "Open a tab on one of your servers, over ssh", "Open a window with a shell"])
        // The menu commands whose keys they show, in the same order.
        check(ways.map(\.command), SwitcherWaysIn.commands)
        check(ways.map(\.hintLabel), ["open…", "connect to server…", "new terminal"])
    }

    @Test func aFirstLaunchCardSaysWhatItOpensInOneSentence() {
        let sentences: [String] = SwitcherWayIn.allCases.map(\.sentence)
        check(sentences, [
            "A folder or a git repository, with its files, branches and agent sessions.",
            "A terminal on your server over ssh, from a saved host or a new one.",
            "A shell in your home folder, no project needed.",
        ])
        let lines: [String] = sentences + SwitcherWayIn.allCases.map(\.title) + [SwitcherText.emptyList]
        for line in lines {
            #expect(!line.contains("..."), "\(line)")
            #expect(!line.contains("  "), "\(line)")
            #expect(!line.contains("\"") && !line.contains("'"), "\(line)")
        }
        #expect(SwitcherText.emptyList == "Projects you open are listed here.")
    }

    @Test func eachWayInShowsTheKeyItsMenuCommandHasNow() {
        let standard = SwitcherWaysIn.standard
        let keys: [String?] = SwitcherWayIn.allCases.map { (way: SwitcherWayIn) -> String? in standard.key(for: way)?.display }
        let shown: [String] = keys.map { (key: String?) -> String in key ?? "none" }
        check(shown, ["⌘O", "⌥⌘T", "⌘N"])
        // Rebound or removed in Settings: the row follows, or shows no key.
        let rebound = SwitcherWaysIn(open: KeyChord(key: "o", command: true, shift: true), connect: nil, newTerminal: nil)
        #expect(rebound.key(for: .open)?.display == "⇧⌘O")
        #expect(rebound.key(for: .connect) == nil)
        #expect(rebound.key(for: .newTerminal) == nil)
        // Read by each one's menu command.
        let read = SwitcherWaysIn { (id: String) -> KeyChord? in id == "newWindow:" ? self.command("n") : nil }
        #expect(read.open == nil && read.connect == nil)
        #expect(read.newTerminal == command("n"))
    }

    @Test func theCardsShowOnlyWhenThereIsNothingToList() {
        let none = SwitcherList(projects: [], servers: [])
        #expect(SwitcherWaysIn.showsCards(none))
        let oneServer = SwitcherList(projects: [], servers: [server("staging")])
        #expect(!SwitcherWaysIn.showsCards(oneServer))
        let oneProject = SwitcherList(projects: [project("/Users/sam/Code/shop")], servers: [])
        #expect(!SwitcherWaysIn.showsCards(oneProject))
    }

    // MARK: what the heading and a row say

    @Test func theHeadingCountsTheOpenProjects() {
        #expect(SwitcherText.openCount(3) == "3 open")
        #expect(SwitcherText.openCount(1) == "1 open")
        #expect(SwitcherText.openCount(0) == nil)
        #expect(SwitcherText.heading(openCount: 3) == "Projects, 3 open")
        #expect(SwitcherText.heading(openCount: 0) == "Projects")
    }

    @Test func aRowSaysOpenOnlyToVoiceOver() {
        let api = project("/Users/sam/Code/api", windows: 2)
        let wiki = project("/Users/sam/Code/wiki", windows: 1)
        let agents = project("/Users/sam/Code/Agents")
        #expect(SwitcherText.windows(api) == "2 windows")
        #expect(SwitcherText.windows(wiki) == nil)
        #expect(SwitcherText.windows(agents) == nil)
        #expect(SwitcherText.folder(of: agents, home: home) == "~/Code")
        #expect(SwitcherText.folder(of: project("/Users/sam/notes"), home: home) == "~")
        #expect(SwitcherText.folder(of: project("/Volumes/Disk/site"), home: home) == "/Volumes/Disk")
        #expect(SwitcherText.accessibilityLabel(wiki, branch: "main", home: home) == "wiki, open, branch main")
        let twoWindows: String = SwitcherText.accessibilityLabel(api, branch: "main", home: home)
        #expect(twoWindows == "api, open in 2 windows, branch main")
        #expect(SwitcherText.accessibilityLabel(agents, branch: "main", home: home) == "Agents, in ~/Code, branch main")
        #expect(SwitcherText.accessibilityLabel(agents, branch: nil, home: home) == "Agents, in ~/Code")
        // A worktree is read by the title its row shows.
        let worktree = project("/Users/sam/Code/xCloud-worktrees/7027-sso", windows: 1, title: "xCloud ▸ 7027-sso")
        #expect(SwitcherText.accessibilityLabel(worktree, branch: nil, home: home) == "xCloud ▸ 7027-sso, open")
    }

    // MARK: more of the search

    @Test func aFolderOutsideTheHomeIsMatchedAsItsRowShowsIt() {
        let demo: SwitcherProject = project("/Users/Shared/demo")
        let list = SwitcherList(projects: [demo, project("/Users/sam/Code/shop")], servers: [])
        // Its second line reads "/Users/Shared", and that text finds it; the projects in the home are not found.
        let shown: String = SwitcherText.folder(of: demo, home: home)
        #expect(shown == "/Users/Shared")
        check(paths(SwitcherSearch.filter(list, query: shown, home: home).projects), ["/Users/Shared/demo"])
        check(paths(SwitcherSearch.filter(list, query: "users", home: home).projects), ["/Users/Shared/demo"])
        check(paths(SwitcherSearch.filter(list, query: "shared", home: home).projects), ["/Users/Shared/demo"])
        // The home folder opened as a project is found by the name its row shows, and only by that.
        let homeRow = SwitcherList(projects: [project(home), project("/Users/sam/Code/shop")], servers: [])
        check(paths(SwitcherSearch.filter(homeRow, query: "sam", home: home).projects), [home])
        // A home with no folder above it to hide, and none given.
        let root = SwitcherList(projects: [project("/srv/app")], servers: [])
        #expect(SwitcherSearch.filter(root, query: "srv", home: "/").projects.count == 1)
        #expect(SwitcherSearch.filter(root, query: "srv", home: "").projects.count == 1)
    }

    @Test func wordStartsFollowSeparatorsCapitalsAndDigits() {
        let projects: [SwitcherProject] = [
            project("/Users/sam/a/parsers"),
            project("/Users/sam/b/XMLParser"),
            project("/Users/sam/c/site2024"),
            project("/Users/sam/d/my_tools.v2"),
        ]
        let list = SwitcherList(projects: projects, servers: [])
        check(names(SwitcherSearch.filter(list, query: "parser", home: home)), ["parsers", "XMLParser"])
        check(names(SwitcherSearch.filter(list, query: "2024", home: home)), ["site2024"])
        check(names(SwitcherSearch.filter(list, query: "tools", home: home)), ["my_tools.v2"])
        // "arser" is inside both names, at no word's start: the list's order.
        check(names(SwitcherSearch.filter(list, query: "arser", home: home)), ["parsers", "XMLParser"])
        // A digit after a letter starts a word, in both names: the list's order.
        check(names(SwitcherSearch.filter(list, query: "2", home: home)), ["site2024", "my_tools.v2"])
    }

    @Test func theSelectedEntryIsFoundAgainAfterARebuild() {
        let shown = twoOpen
        #expect(shown.index(of: .project("/Users/sam/Code/docs")) == 2)
        #expect(shown.index(of: .server("id-staging")) == 4)
        #expect(shown.index(of: .project("/Users/sam/Code/gone")) == nil)
        #expect(shown.entries[0].project?.path == "/Users/sam/Code/shop")
        #expect(shown.entries[4].server?.name == "staging")
        #expect(shown.entries[4].project == nil)
    }

    @Test func aSavedHostIsListedByItsNameAndDestination() {
        let host = RemoteHost(id: "h-1", name: "staging", destination: "deploy@staging.example.com", directory: "~/app")
        let server = SwitcherServer(host)
        #expect(server.id == "h-1")
        #expect(server.name == "staging")
        #expect(server.destination == "deploy@staging.example.com")
    }
}
