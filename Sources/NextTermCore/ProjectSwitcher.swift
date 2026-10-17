import Foundation

// The Welcome window as a project switcher: what it lists and in which order, what a search finds and how it ranks
// it, where the selection starts, what each key does and what the hint line says. All of it here, as plain values, so
// the window only reads AppKit's state into these and acts on the answers.

/// A row of the projects list: a project, open in one or more windows or used before; or one window, so that every
/// window is a row away: another window on an open project (the project's row goes to the one in front last), or a
/// window with no project, New Terminal's or a server's.
public struct SwitcherProject: Equatable, Sendable {
    /// The project's folder; empty for a window with no project.
    public let path: String
    /// What its row shows: a linked worktree's "xCloud ▸ 7027-sso", as its window's title reads, else the
    /// folder's name. A window's own row shows the window's whole title: "shop — claude", "~/Downloads — vim".
    public let title: String
    /// The windows that have it open; none for a closed project, one for a window's own row.
    public let windows: Int
    /// Open: when its window was last in front, the newest of its windows. Closed: its last use in the history. Nil for
    /// a Recent Projects entry with no use recorded (from before the history, or imported).
    public let lastUsed: Date?
    /// The window a window's own row stands for; nil for a project's row.
    public let window: SwitcherWindow?
    /// The marks of the agents in the window the row goes to: for an open project, its window in front last (its other
    /// windows have rows of their own); none for a closed one.
    public let marks: AgentMarks

    public init(path: String, title: String, windows: Int, lastUsed: Date?, window: SwitcherWindow? = nil,
                marks: AgentMarks = AgentMarks()) {
        self.path = path
        self.title = title
        self.windows = windows
        self.lastUsed = lastUsed
        self.window = window
        self.marks = marks
    }

    /// The folder's name, which the search ranks first; empty for a window with no project.
    public var name: String { (path as NSString).lastPathComponent }

    public var isOpen: Bool { windows > 0 }

    /// A project's row, or another window on one: what ⌘↩ can open a new window on. Not a window with no project.
    public var hasProject: Bool { window?.kind.hasProject ?? true }
}

/// What a window's own row in the switcher knows of the window.
public struct SwitcherWindow: Equatable, Sendable {
    /// Its id in the index (`WindowIndex.Window.id`), to bring it to the front.
    public let id: Int
    public let kind: WindowKind
    /// For a server's window, what ssh connects to there, which its second line shows.
    public let destination: String?

    public init(id: Int, kind: WindowKind, destination: String? = nil) {
        self.id = id
        self.kind = kind
        self.destination = destination
    }

    public init(_ window: WindowIndex.Window) {
        self.init(id: window.id, kind: window.kind, destination: window.destination)
    }
}

/// A saved server the switcher lists.
public struct SwitcherServer: Equatable, Sendable {
    /// The saved host's id.
    public let id: String
    public let name: String
    /// What ssh connects to, which the search also looks in.
    public let destination: String

    public init(id: String, name: String, destination: String) {
        self.id = id
        self.name = name
        self.destination = destination
    }

    public init(_ host: RemoteHost) {
        self.init(id: host.id, name: host.name, destination: host.destination)
    }
}

/// One row the selection can be on: a project or a server. Headings are not entries.
public enum SwitcherEntry: Equatable, Sendable {
    case project(SwitcherProject)
    case server(SwitcherServer)

    /// What stays the same when the list is rebuilt, so the selection can stay on it.
    public enum ID: Hashable, Sendable {
        case project(String)
        /// A window's own row, by the window's id.
        case window(Int)
        case server(String)
    }

    public var id: ID {
        switch self {
        case .project(let project):
            guard let window = project.window else { return .project(project.path) }
            return .window(window.id)
        case .server(let server):
            return .server(server.id)
        }
    }

    public var project: SwitcherProject? {
        if case .project(let project) = self { return project }
        return nil
    }

    public var server: SwitcherServer? {
        if case .server(let server) = self { return server }
        return nil
    }
}

/// Everything the switcher can list, in its order: the open projects and the windows with no project, the one in front
/// last first, each project's other windows under it; then the closed projects, the one used last first; then Recent
/// Projects' entries with no recorded use, in their stored order; then the saved servers, as given.
public struct SwitcherList: Equatable, Sendable {
    /// How many servers show while nothing is typed. A search looks through every saved one.
    public static let serverLimit = 3

    public let projects: [SwitcherProject]
    public let servers: [SwitcherServer]

    public init(projects: [SwitcherProject], servers: [SwitcherServer]) {
        self.projects = projects
        self.servers = servers
    }

    /// The number the PROJECTS heading shows: the open projects, not their windows.
    public var openCount: Int {
        projects.filter { (project: SwitcherProject) -> Bool in project.isOpen && project.window == nil }.count
    }

    /// Nothing to list at all: a first launch shows the three ways in instead.
    public var isEmpty: Bool { projects.isEmpty && servers.isEmpty }
}

extension SwitcherList {
    /// The list from what is open now and what was used before.
    /// - `open`: every terminal window, as the index has them, in any order. Windows on the same folder make one project,
    ///   counted, whose row goes to the one in front last; each of its other windows has a row of its own under it, and so
    ///   does each window with no project.
    /// - `history`: the projects used before, newest first, as `ProjectHistory` keeps them.
    /// - `recents`: Recent Projects' paths, in their stored order; those the history has a time for are listed there.
    /// - `servers`: the saved servers in the order they are listed, the one connected to last first.
    /// - `titles`: a closed project's title when it is not its folder's name (a linked worktree's), once read.
    public static func build(open: [WindowIndex.Window], history: [ProjectHistory.Entry], recents: [String],
                             servers: [SwitcherServer], titles: [String: String] = [:]) -> SwitcherList {
        var listed: Set<String> = []
        var projects: [SwitcherProject] = openRows(open)
        for project in projects where project.window == nil { listed.insert(project.path) }
        for entry in history where !listed.contains(entry.path) {
            listed.insert(entry.path)
            let title: String = titles[entry.path] ?? (entry.path as NSString).lastPathComponent
            projects.append(SwitcherProject(path: entry.path, title: title, windows: 0, lastUsed: entry.lastUsed))
        }
        for path in recents where !listed.contains(path) {
            listed.insert(path)
            let title: String = titles[path] ?? (path as NSString).lastPathComponent
            projects.append(SwitcherProject(path: path, title: title, windows: 0, lastUsed: nil))
        }
        return SwitcherList(projects: projects, servers: servers)
    }

    /// One row per project, with its window count and its newest time in front, and its other windows' rows under it; one
    /// per window with no project. The newest first, and those in front at the same moment in the order their first
    /// window was given.
    private static func openRows(_ windows: [WindowIndex.Window]) -> [SwitcherProject] {
        var groups: [OpenGroup] = []
        var byPath: [String: Int] = [:]
        for window in windows {
            guard let path = window.project else {
                groups.append(OpenGroup(windows: [window], rank: groups.count))
                continue
            }
            if let index = byPath[path] {
                groups[index].windows.append(window)
            } else {
                byPath[path] = groups.count
                groups.append(OpenGroup(windows: [window], rank: groups.count))
            }
        }
        let sorted: [OpenGroup] = groups.sorted { (a: OpenGroup, b: OpenGroup) -> Bool in
            a.lastKey != b.lastKey ? a.lastKey > b.lastKey : a.rank < b.rank
        }
        return sorted.flatMap(\.rows)
    }

    /// A project's windows, or one window with no project.
    private struct OpenGroup {
        var windows: [WindowIndex.Window]
        /// Where its first window stood in the windows given.
        let rank: Int

        var lastKey: Date {
            windows.map { (window: WindowIndex.Window) -> Date in window.lastKey }.max() ?? .distantPast
        }

        /// The project's row, for its window in front last, then a row for each of its other windows, the newest first;
        /// or the one window's row.
        var rows: [SwitcherProject] {
            let order: [Int] = windows.indices.sorted { (a: Int, b: Int) -> Bool in
                let first: Date = windows[a].lastKey, second: Date = windows[b].lastKey
                return first != second ? first > second : a < b
            }
            let ordered: [WindowIndex.Window] = order.map { (index: Int) -> WindowIndex.Window in windows[index] }
            guard let front = ordered.first else { return [] }
            guard let path = front.project else { return [Self.row(front, path: "")] }
            let project = SwitcherProject(path: path, title: front.name, windows: windows.count, lastUsed: lastKey,
                                          marks: front.marks)
            let others: [SwitcherProject] = ordered.dropFirst().map { (window: WindowIndex.Window) -> SwitcherProject in
                Self.row(window, path: path)
            }
            return [project] + others
        }

        /// A window's own row, titled as the window is.
        private static func row(_ window: WindowIndex.Window, path: String) -> SwitcherProject {
            SwitcherProject(path: path, title: window.title, windows: 1, lastUsed: window.lastKey,
                            window: SwitcherWindow(window), marks: window.marks)
        }
    }
}

/// What the list shows for what is typed: the projects, then the servers, each best match first.
public struct SwitcherShown: Equatable, Sendable {
    public let projects: [SwitcherProject]
    public let servers: [SwitcherServer]

    public init(projects: [SwitcherProject], servers: [SwitcherServer]) {
        self.projects = projects
        self.servers = servers
    }

    /// The rows the selection moves through, in order: the projects, then the servers.
    public var entries: [SwitcherEntry] {
        let projectEntries: [SwitcherEntry] = projects.map { (project: SwitcherProject) -> SwitcherEntry in
            .project(project)
        }
        let serverEntries: [SwitcherEntry] = servers.map { (server: SwitcherServer) -> SwitcherEntry in
            .server(server)
        }
        return projectEntries + serverEntries
    }

    /// No match: Return does nothing, and the hint line gives the three ways in.
    public var isEmpty: Bool { projects.isEmpty && servers.isEmpty }

    /// Where an entry is in `entries` now, to keep it selected when the list is rebuilt.
    public func index(of id: SwitcherEntry.ID) -> Int? {
        switch id {
        case .project(let path):
            return projects.firstIndex(where: { (project: SwitcherProject) -> Bool in
                project.path == path && project.window == nil
            })
        case .window(let windowID):
            return projects.firstIndex(where: { (project: SwitcherProject) -> Bool in project.window?.id == windowID })
        case .server(let serverID):
            let index: Int? = servers.firstIndex(where: { (server: SwitcherServer) -> Bool in server.id == serverID })
            return index.map { (index: Int) -> Int in projects.count + index }
        }
    }
}

/// The projects search. Each word typed must be found, in any order, with case and accents ignored, as every list
/// search here matches (`SearchWords`). Where it is found ranks the entry: the start of its name, the start of a word
/// in its name, anywhere in its name, then its folder (as `~/…`), its branch or its worktree title; for a server its
/// name the same way, then its destination. An entry ranks by its weakest word, and equal ranks keep the list's order.
/// Projects stay above servers.
public enum SwitcherSearch {
    /// The entries `query` finds, best first. With nothing typed, every project and the first `serverLimit` servers,
    /// with the server picked last in the window among them (`lastPick`, its id): further down the saved ones, it takes
    /// the last place, so the selection can start on it. `home` is the home folder: a project in it is matched from "~"
    /// down, so typing "Users" or one's own short name does not find every project; one outside it, as its row shows
    /// it. `branches` holds each project's branch, by path, as far as it is read.
    public static func filter(_ list: SwitcherList, query: String, home: String,
                              branches: [String: String] = [:], lastPick: String? = nil) -> SwitcherShown {
        let search = SearchWords(query)
        guard !search.isEmpty else {
            let servers: [SwitcherServer] = firstServers(list.servers, keeping: lastPick)
            return SwitcherShown(projects: list.projects, servers: servers)
        }
        let words: [String] = search.words
        let projects: [SwitcherProject] = ranked(list.projects) { (project: SwitcherProject) -> Int? in
            rank(project, words, home: home, branch: branches[project.path])
        }
        let servers: [SwitcherServer] = ranked(list.servers) { (server: SwitcherServer) -> Int? in
            rank(server, words)
        }
        return SwitcherShown(projects: projects, servers: servers)
    }

    /// The line the list shows when nothing matches, with the text as typed in curly quotes.
    public static func noMatch(_ query: String) -> String {
        let typed: String = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return "No project or server matches “" + typed + "”."
    }

    /// The first `serverLimit` servers; the one picked last, when it is saved but further down, in the last place.
    private static func firstServers(_ servers: [SwitcherServer], keeping lastPick: String?) -> [SwitcherServer] {
        var shown: [SwitcherServer] = Array(servers.prefix(SwitcherList.serverLimit))
        guard let lastPick, !shown.isEmpty else { return shown }
        let isPick: (SwitcherServer) -> Bool = { (server: SwitcherServer) -> Bool in server.id == lastPick }
        guard !shown.contains(where: isPick), let picked = servers.first(where: isPick) else { return shown }
        shown[shown.count - 1] = picked
        return shown
    }

    /// Ranks, best first.
    fileprivate static let namePrefix = 0, wordStart = 1, inName = 2, elsewhere = 3

    private static func rank(_ project: SwitcherProject, _ words: [String], home: String, branch: String?) -> Int? {
        let name = Name(project.name)
        var others: [String] = [searchedFolder(project.path, home: home)]
        if let branch { others.append(branch) }
        if project.title != project.name { others.append(project.title) }
        // One field to a line: a word has no line break in it, so it never matches across two fields.
        let rest: String = SearchWords.fold(others.joined(separator: "\n"))
        return weakest(words) { (word: String) -> Int? in
            name.rank(word) ?? (rest.contains(word) ? elsewhere : nil)
        }
    }

    private static func rank(_ server: SwitcherServer, _ words: [String]) -> Int? {
        let name = Name(server.name)
        let destination: String = SearchWords.fold(server.destination)
        return weakest(words) { (word: String) -> Int? in
            name.rank(word) ?? (destination.contains(word) ? elsewhere : nil)
        }
    }

    /// The worst rank of the words, or nil when one is not found.
    private static func weakest(_ words: [String], _ rank: (String) -> Int?) -> Int? {
        var worst: Int = namePrefix
        for word in words {
            guard let found = rank(word) else { return nil }
            worst = max(worst, found)
        }
        return worst
    }

    /// The items `rank` finds, best first, equal ranks in the order given.
    private static func ranked<Item>(_ items: [Item], by rank: (Item) -> Int?) -> [Item] {
        var found: [Found<Item>] = []
        for (index, item) in items.enumerated() {
            guard let value = rank(item) else { continue }
            found.append(Found(rank: value, index: index, item: item))
        }
        found.sort { (a: Found<Item>, b: Found<Item>) -> Bool in
            a.rank != b.rank ? a.rank < b.rank : a.index < b.index
        }
        return found.map(\.item)
    }

    private struct Found<Item> {
        let rank: Int
        let index: Int
        let item: Item
    }
}

extension SwitcherSearch {
    /// A name, folded for matching, with the folded text from each word's start in it.
    private struct Name {
        let folded: String
        let fromWordStarts: [String]

        init(_ name: String) {
            folded = SearchWords.fold(name)
            fromWordStarts = SwitcherSearch.wordStarts(name).map { (start: String.Index) -> String in
                SearchWords.fold(String(name[start...]))
            }
        }

        /// How well `word` (folded) is found in the name, or nil when it is not.
        func rank(_ word: String) -> Int? {
            if folded.hasPrefix(word) { return SwitcherSearch.namePrefix }
            let atWordStart: Bool = fromWordStarts.contains { (rest: String) -> Bool in rest.hasPrefix(word) }
            if atWordStart { return SwitcherSearch.wordStart }
            return folded.contains(word) ? SwitcherSearch.inName : nil
        }
    }

    /// Where a word starts in a name, after its first character: after a character that is neither a letter nor a
    /// digit ("bash-shell", "my_tools.v2"), at a capital after a small letter ("myShelf"), at the last capital of a run
    /// that a small letter follows ("XMLParser"), and where letters turn to digits or back ("site2024").
    private static func wordStarts(_ name: String) -> [String.Index] {
        var starts: [String.Index] = []
        var previous: Character?
        var index: String.Index = name.startIndex
        while index < name.endIndex {
            let character: Character = name[index]
            let next: String.Index = name.index(after: index)
            let following: Character? = next < name.endIndex ? name[next] : nil
            if let previous, startsWord(character, after: previous, before: following) { starts.append(index) }
            previous = character
            index = next
        }
        return starts
    }

    private static func startsWord(_ character: Character, after previous: Character, before next: Character?) -> Bool {
        guard isWordCharacter(character) else { return false }
        guard isWordCharacter(previous) else { return true }
        if previous.isLetter != character.isLetter { return true }
        if previous.isLowercase && character.isUppercase { return true }
        guard previous.isUppercase && character.isUppercase, let next else { return false }
        return next.isLowercase
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    /// The folder as the search sees it, the way its row shows it: "~/Code/shop" under the home folder, so the home
    /// folder's own name and the folders above it never match a project in it; anywhere else, as it is
    /// ("/Users/Shared/demo"), so the text a row shows always finds it.
    private static func searchedFolder(_ path: String, home: String) -> String {
        var home: String = home
        while home.hasSuffix("/") { home.removeLast() }
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

/// Where the selection starts when the window shows, and how it moves.
public enum SwitcherSelection {
    /// Where the defaults keep the id of the server picked last in the Welcome window. Picking a project there clears
    /// it: for projects the list's order already starts on the one used last.
    public static let lastPickKey = "welcomeLastPick"

    /// The row the selection starts on, an index in `shown.entries`; nil with nothing listed.
    /// - `origin`: the folder of the project window the switcher was shown from. The selection starts on the other open
    ///   project or window used last, else on the first closed project, so the key that showed it, then Return, switches
    ///   back; with neither, on the first row.
    /// - `originWindow`: the id of the window it was shown from (`WindowIndex.Window.id`), a project's or not. Shown from
    ///   a window with no project, the selection starts on the other open project or window used last too.
    /// - `lastPick`: the id of the server picked last in the window. Shown from anywhere else, or from a window with no
    ///   project and no other window open, the selection starts on it while it is listed (`SwitcherSearch.filter` lists
    ///   it while it is saved), else on the first row.
    public static func initial(_ shown: SwitcherShown, origin: String?, originWindow: Int? = nil,
                               lastPick: String?) -> Int? {
        guard !shown.isEmpty else { return nil }
        let projects: [SwitcherProject] = shown.projects
        let other: Int? = projects.firstIndex { (project: SwitcherProject) -> Bool in
            guard project.isOpen else { return false }
            if let originWindow, project.window?.id == originWindow { return false }
            return origin == nil || project.path != origin
        }
        if origin != nil {
            if let other { return other }
            let closed: Int? = projects.firstIndex { (project: SwitcherProject) -> Bool in !project.isOpen }
            return closed ?? 0
        }
        if originWindow != nil, let other { return other }
        if let lastPick, let index = shown.index(of: .server(lastPick)) { return index }
        return 0
    }

    /// The row the selection is on after the search text changes, an index in `shown.entries`. With text, the best
    /// match, which is the first row; nil with no match, so Return does nothing. Emptied (or only spaces left), the
    /// whole list is back and the selection goes where `initial` started it, so clearing the search, then Return, still
    /// switches back.
    public static func afterSearch(_ shown: SwitcherShown, query: String, origin: String?, originWindow: Int? = nil,
                                   lastPick: String?) -> Int? {
        guard !SearchWords(query).isEmpty else {
            return initial(shown, origin: origin, originWindow: originWindow, lastPick: lastPick)
        }
        return shown.isEmpty ? nil : 0
    }

    /// The row `step` rows (or a page's) from `index`, kept to the list's ends; nil with nothing listed. From no
    /// selection, a step down lands on the first row and a step up on the last.
    public static func moved(_ index: Int?, by step: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return step >= 0 ? 0 : count - 1 }
        return min(max(index + step, 0), count - 1)
    }
}

/// Where the window comes up when it was not showing, or was showing on another display: over the window it was asked
/// from, on that window's screen, so it never opens on another display than the one being looked at.
public enum SwitcherPlacement {
    /// A frame of `size` centred over `origin`, moved as little as it takes to sit inside `visible` (the screen's frame
    /// less the menu bar and the Dock), on whole points. Bigger than the screen (made so on a bigger display), it
    /// shrinks to fit, never below `minSize`; still too big then, it keeps its left edge and its top, the title bar, on
    /// it. Screen coordinates: y grows upward.
    public static func frame(size wanted: CGSize, minSize: CGSize, over origin: CGRect,
                             within visible: CGRect) -> CGRect {
        let width: CGFloat = max(min(wanted.width, visible.width), minSize.width)
        let height: CGFloat = max(min(wanted.height, visible.height), minSize.height)
        let centredX: CGFloat = (origin.midX - width / 2).rounded()
        let centredY: CGFloat = (origin.midY - height / 2).rounded()
        let left: CGFloat = visible.minX
        let bottom: CGFloat = visible.maxY - height
        let x: CGFloat = kept(centredX, from: left, to: visible.maxX - width, tooBig: left)
        let y: CGFloat = kept(centredY, from: visible.minY, to: bottom, tooBig: bottom)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Which of `screens` (their frames) holds most of `frame`: the screen a window is on, as AppKit counts it. Nil
    /// when none holds any of it, its display unplugged since.
    public static func screen(of frame: CGRect, among screens: [CGRect]) -> Int? {
        var best: Int?
        var bestArea: CGFloat = 0
        for (index, screen) in screens.enumerated() {
            let shared: CGRect = screen.intersection(frame)
            let area: CGFloat = shared.isNull ? 0 : shared.width * shared.height
            if area > bestArea {
                best = index
                bestArea = area
            }
        }
        return best
    }

    /// `value` kept between `low` and `high`; `tooBig` when there is no room between them.
    private static func kept(_ value: CGFloat, from low: CGFloat, to high: CGFloat, tooBig: CGFloat) -> CGFloat {
        guard high >= low else { return tooBig }
        return min(max(value, low), high)
    }
}

/// What a key does in the switcher.
public enum SwitcherAction: Equatable, Sendable {
    /// The selection moves by rows: ↓ and ↑, ⌃N and ⌃P.
    case move(Int)
    /// By pages: Page Down and Page Up.
    case page(Int)
    /// To the selected project's window, or open it; to the selected server's window, or connect to it. With
    /// `newWindow`, the project opens in a new window without asking, a second one when it is open already, and the
    /// server connects in a new window though one is open on it.
    case activate(newWindow: Bool)
    /// The project at this index in the list, as Return would.
    case jump(Int)
    case clearSearch
    case close
    /// The selected closed project leaves the list, and Open Recent.
    case forget
    /// The key is the switcher's, and does nothing now: ⌘⌫ held down, repeating. One press forgets one project at most,
    /// and the press that emptied the search none; the repeats reach neither the field nor a menu.
    case ignore
}

/// The switcher's keys. Two places take them, as the window gets them: the projects search's own commands
/// (`action(selector:…)`: arrows, pages, Return, Esc), and the window's key equivalents, before the menus see them
/// (`action(chord:…)`). The keys stay fixed, except the ones read from menu commands, whose current keys are passed in,
/// so a rebinding carries over.
public struct SwitcherKeys: Equatable, Sendable {
    /// Where the keyboard is in the Welcome window.
    public enum Focus: Sendable {
        /// The projects search, or the list.
        case projects
        /// The sessions search, or their list: ⌥⌘O gives ⌘↩ to Fork there, so it keeps it.
        case sessions
        case elsewhere
    }

    /// ⌘↩: the selected project in a new window.
    public static let newWindow = KeyChord(key: "\r", command: true)
    /// ⌘⌫: forget the selected closed project. Only while the search is empty: with text, the field's own delete to
    /// the start of the line, so clearing a query never drops a project. Only the press, never its repeats: held down,
    /// the selection moves on to the next closed project after each forget, and a repeat would take that one too. The
    /// Delete key is U+0008 here, as the menus spell it and as `KeyboardShortcuts.chord(from:)` reads an event; the
    /// event's own U+007F does not match.
    public static let forget = KeyChord(key: "\u{8}", command: true)
    private static let down = KeyChord(key: "n", control: true)
    private static let up = KeyChord(key: "p", control: true)

    /// Window › Select Tab 1 to 9 (the ninth is "Select Last Tab" in the menu, and here the ninth row), by command id.
    public static let jumpCommands: [String] = (1...9).map { (n: Int) -> String in "selectTabByNumber:#\(n)" }
    /// File › Close Tab, whose key closes the window here.
    public static let closeCommand = "closeTab:"

    /// The menus' default keys: ⌘1 to ⌘9 and ⌘W.
    public static let standard: SwitcherKeys = {
        let jumps: [KeyChord?] = (1...9).map { (n: Int) -> KeyChord? in KeyChord(key: "\(n)", command: true) }
        return SwitcherKeys(jumps: jumps, close: KeyChord(key: "w", command: true))
    }()

    /// The keys of `jumpCommands` now, nil for one with no key.
    public let jumps: [KeyChord?]
    /// The key of `closeCommand` now.
    public let close: KeyChord?

    public init(jumps: [KeyChord?], close: KeyChord?) {
        self.jumps = jumps
        self.close = close
    }

    /// What a row shows in its branch's place while the jumps' modifiers are held (`showsJumps`): its jump's key,
    /// "⌘1". Only the first nine projects the list shows have one (`projects`, how many it shows now): nil for a
    /// server's row, past the ninth, or for a jump with no key.
    public func jumpHint(_ row: Int, projects: Int) -> String? {
        guard row < projects, jumps.indices.contains(row) else { return nil }
        return jumps[row]?.display
    }

    /// Whether the rows show their jump keys with these modifiers held: every modifier of the first jump that has a
    /// key (Select Tab 1's, unless it has none), as the menus have it now, so a rebinding carries over; more held shows
    /// them too. Never with no jump key, nor for one with no modifier, which would show them with nothing held.
    public func showsJumps(command: Bool, shift: Bool, option: Bool, control: Bool) -> Bool {
        let first: KeyChord? = jumps.lazy.compactMap { (jump: KeyChord?) -> KeyChord? in jump }.first
        guard let first, first.command || first.shift || first.option || first.control else { return false }
        if first.command && !command { return false }
        if first.shift && !shift { return false }
        if first.option && !option { return false }
        return !first.control || control
    }

    /// Whether the Welcome window may take `chord` before the menus, in some state: a jump, Close, ⌘↩, ⌘⌫, ⌃N or ⌃P.
    /// A way in whose menu command has one of these shows no key there (`SwitcherWaysIn.notTaken(by:)`).
    public func takes(_ chord: KeyChord) -> Bool {
        if jumps.contains(chord) { return true }
        if let close, chord == close { return true }
        let own: [KeyChord] = [Self.newWindow, Self.forget, Self.down, Self.up]
        return own.contains(chord)
    }

    /// A key equivalent pressed while the Welcome window is key; nil leaves it to the window and the menus. The jumps
    /// and Close work anywhere in the window; ⌘↩, ⌘⌫, ⌃N and ⌃P only for the projects. A jump reaches only the projects
    /// the list shows (`projects`, how many it shows now), never a server; past them it is nil. `isRepeat`: the key is
    /// held down and this is one of its repeats, which never forgets.
    public func action(chord: KeyChord, focus: Focus, searchEmpty: Bool, selection: SwitcherEntry?,
                       projects: Int, isRepeat: Bool = false) -> SwitcherAction? {
        let row: Int? = jumps.firstIndex { (jump: KeyChord?) -> Bool in jump == chord }
        if let row { return row < projects ? .jump(row) : nil }
        if let close, chord == close { return .close }
        guard focus == .projects else { return nil }
        switch chord {
        case Self.down: return .move(1)
        case Self.up: return .move(-1)
        case Self.newWindow:
            // A server: ⌘↩ connects in a new window, though Return would go to one open on it. A window with no project
            // has nothing to open again: ⌘↩ goes to it.
            guard let selection else { return nil }
            if selection.server != nil { return .activate(newWindow: true) }
            return .activate(newWindow: selection.project?.hasProject ?? false)
        case Self.forget:
            // With text, the field's, held or not. On the empty search a repeat does nothing: held down, each forget
            // would select the next closed project for the next repeat to take.
            guard searchEmpty else { return nil }
            if isRepeat { return .ignore }
            // Open projects stay listed while open.
            guard let project = selection?.project, !project.isOpen else { return nil }
            return .forget
        default:
            return nil
        }
    }

    /// A command the projects search's field editor is about to run; nil leaves it to the field. Return with nothing
    /// selected does nothing. Esc empties a search with text; on an empty one it closes the window while another Next
    /// Term window is open, and with none it does nothing, so one key never leaves the app without a window.
    public static func action(selector: String, searchEmpty: Bool, selection: SwitcherEntry?,
                              otherWindows: Bool) -> SwitcherAction? {
        switch selector {
        case "moveDown:": return .move(1)
        case "moveUp:": return .move(-1)
        case "pageDown:", "scrollPageDown:": return .page(1)
        case "pageUp:", "scrollPageUp:": return .page(-1)
        case "insertNewline:": return selection == nil ? nil : .activate(newWindow: false)
        case "cancelOperation:":
            if !searchEmpty { return .clearSearch }
            return otherWindows ? .close : nil
        default: return nil
        }
    }
}

/// The keys of the three ways in, Open…, Connect to Server… and New Terminal, as the menus have them now.
public struct SwitcherWaysIn: Equatable, Sendable {
    public var open: KeyChord?
    public var connect: KeyChord?
    public var newTerminal: KeyChord?

    public init(open: KeyChord?, connect: KeyChord?, newTerminal: KeyChord?) {
        self.open = open
        self.connect = connect
        self.newTerminal = newTerminal
    }

    /// Each one's key read by its menu command's id, as `chord` gives it now.
    public init(chord: (String) -> KeyChord?) {
        self.init(open: chord(SwitcherWayIn.open.command), connect: chord(SwitcherWayIn.connect.command),
                  newTerminal: chord(SwitcherWayIn.newTerminal.command))
    }

    /// File › Open Project…, New Remote Tab… and New Window, by command id, in the three's order.
    public static let commands: [String] = SwitcherWayIn.allCases.map { (way: SwitcherWayIn) -> String in way.command }

    /// The menus' default keys: ⌘O, ⌥⌘T and ⌘N.
    public static let standard = SwitcherWaysIn(open: KeyChord(key: "o", command: true),
                                                connect: KeyChord(key: "t", command: true, option: true),
                                                newTerminal: KeyChord(key: "n", command: true))

    /// The key `way` has now; nil when its command has none.
    public func key(for way: SwitcherWayIn) -> KeyChord? {
        switch way {
        case .open: return open
        case .connect: return connect
        case .newTerminal: return newTerminal
        }
    }

    /// The keys the rows, the cards and the hint line show in the Welcome window. A key the window takes first
    /// (`SwitcherKeys.takes(_:)`) does something else there, New Window given ⌘↩ opening the selection in a new window,
    /// so the way in shows no key rather than one that does not do what it does.
    public func notTaken(by keys: SwitcherKeys) -> SwitcherWaysIn {
        func kept(_ chord: KeyChord?) -> KeyChord? {
            guard let chord, !keys.takes(chord) else { return nil }
            return chord
        }
        return SwitcherWaysIn(open: kept(open), connect: kept(connect), newTerminal: kept(newTerminal))
    }

    /// With nothing at all to list, a first launch, the right pane shows the three ways in as cards, until something is
    /// typed: a search hides them, as it hides the list's “Projects you open are listed here.”, and emptying it brings
    /// them back. `query` is the search's text; spaces alone search for nothing.
    public static func showsCards(_ list: SwitcherList, query: String) -> Bool {
        list.isEmpty && SearchWords(query).isEmpty
    }
}

/// The three ways in, for three kinds of user: Open… for one who works in a project, Connect to Server… for one who
/// works on a server, New Terminal for one who wants a shell now. Always all three, in this order, none of them the
/// default and none moved by habit.
public enum SwitcherWayIn: CaseIterable, Sendable {
    case open, connect, newTerminal

    /// The row's and the card's title.
    public var title: String {
        switch self {
        case .open: return "Open…"
        case .connect: return "Connect to Server…"
        case .newTerminal: return "New Terminal"
        }
    }

    /// The SF Symbol in the row's gutter and on the card: the app's one server mark, a folder and a terminal.
    public var symbol: String {
        switch self {
        case .open: return "folder"
        case .connect: return "server.rack"
        case .newTerminal: return "terminal"
        }
    }

    /// The tooltip's words, which the key the menus give it follows: "Open a window with a shell (⌘N)".
    public var help: String {
        switch self {
        case .open: return "Open a folder as a project"
        case .connect: return "Open a tab on one of your servers, over ssh"
        case .newTerminal: return "Open a window with a shell"
        }
    }

    /// What its first-launch card says it opens, in one sentence that fits three lines in the narrowest card (87 pt of
    /// 12 pt text, in a window 720 pt wide), measured with the system font.
    public var sentence: String {
        switch self {
        case .open: return "A folder or git repository, as a project."
        case .connect: return "A terminal on your server, over ssh."
        case .newTerminal: return "A shell in your home folder, no project."
        }
    }

    /// After its key in the hint line: "⌘O open…".
    public var hintLabel: String {
        switch self {
        case .open: return "open…"
        case .connect: return "connect to server…"
        case .newTerminal: return "new terminal"
        }
    }

    /// The menu command whose key it shows, by id: File › Open Project… (which is Open… on the Welcome window), New
    /// Remote Tab… and New Window.
    public var command: String {
        switch self {
        case .open: return "openProjectPanel:"
        case .connect: return "newRemoteTab:"
        case .newTerminal: return "newWindow:"
        }
    }
}

/// The hint line under the list: what the keys do for the selection. Its parts are plain strings; the window sets
/// the gaps between them, never typed spaces.
public enum SwitcherHint {
    /// "↩ go to window", "↩ open" or "↩ connect"; then "⌘↩ new window" for a project, and for a server with a window
    /// open on it (`serverWindowOpen`), where Return goes to that window; then "esc close" while Esc closes the window
    /// (the search is empty and another window is open). With nothing selected, no match or nothing listed, the three
    /// ways in with their keys instead, leaving out one with no key.
    public static func parts(selection: SwitcherEntry?, searchEmpty: Bool, otherWindows: Bool,
                             waysIn: SwitcherWaysIn = .standard, serverWindowOpen: Bool = false) -> [String] {
        let enter: String = KeyChord(key: "\r").display
        var parts: [String] = []
        switch selection {
        case .project(let project)?:
            parts.append(enter + " " + (project.isOpen ? "go to window" : "open"))
            if project.hasProject { parts.append(SwitcherKeys.newWindow.display + " new window") }
        case .server?:
            parts.append(enter + " " + (serverWindowOpen ? "go to window" : "connect"))
            if serverWindowOpen { parts.append(SwitcherKeys.newWindow.display + " new window") }
        case nil:
            for way in SwitcherWayIn.allCases {
                if let key = waysIn.key(for: way) { parts.append(key.display + " " + way.hintLabel) }
            }
        }
        if searchEmpty && otherWindows { parts.append("esc close") }
        return parts
    }
}

/// What the PROJECTS heading and a project's row say, on screen and to VoiceOver. The row says open with a dot only;
/// VoiceOver hears the word.
public enum SwitcherText {
    /// The list's one line on a first launch, with nothing to list.
    public static let emptyList = "Projects you open are listed here."

    /// Beside the heading: "3 open"; nothing with none open.
    public static func openCount(_ count: Int) -> String? {
        count > 0 ? "\(count) open" : nil
    }

    /// The heading to VoiceOver: "Projects, 3 open".
    public static func heading(openCount count: Int) -> String {
        guard let open = openCount(count) else { return "Projects" }
        return "Projects, " + open
    }

    /// After the folder on the row's second line: "2 windows" for a project open in two or more, and "another window" on
    /// the row of each of its other windows, which may be titled as the project is (a tab at its prompt there); nothing
    /// for a project in one window, nor for a window with no project.
    public static func windows(_ project: SwitcherProject) -> String? {
        if let window = project.window { return window.kind.hasProject ? "another window" : nil }
        return project.windows > 1 ? "\(project.windows) windows" : nil
    }

    /// What a window with no project says on its second line, in a folder's place.
    public static let noProject = "No project"

    /// The folder the project is in, on its second line: "~/Code", for another window on it too. In its place, a window
    /// with no project says so, and a server's says what ssh connects to there.
    public static func folder(of project: SwitcherProject, home: String) -> String {
        if let window = project.window, !window.kind.hasProject {
            return window.kind == .server ? (window.destination ?? "") : noProject
        }
        var home: String = home
        while home.count > 1 && home.hasSuffix("/") { home.removeLast() }
        let parent: String = (project.path as NSString).deletingLastPathComponent
        return RecentProjects.abbreviate(parent, home: home)
    }

    /// A server's row to VoiceOver: "staging, deploy@staging.example.com".
    public static func accessibilityLabel(_ server: SwitcherServer) -> String {
        server.name + ", " + server.destination
    }

    /// What VoiceOver hears of a row the keys selected from the search, as the row says it.
    public static func accessibilityLabel(_ entry: SwitcherEntry, branch: String?, home: String,
                                          working: Bool = true) -> String {
        switch entry {
        case .project(let project): return accessibilityLabel(project, branch: branch, home: home, working: working)
        case .server(let server): return accessibilityLabel(server)
        }
    }

    /// "wiki, open, branch main", "api, open in 2 windows, 1 needs you, branch main", or for a closed project
    /// "Agents, in ~/Code, branch main". A window's own row: "shop — claude, another window, 2 done, in ~/Code, branch
    /// main", "~/Downloads — vim, a window with no project", "web-1 — app, a window on deploy@203.0.113.5". `working`
    /// false leaves out the working agents, as the row does with View › Agent Spinner set to Off.
    public static func accessibilityLabel(_ project: SwitcherProject, branch: String?, home: String,
                                          working: Bool = true) -> String {
        var parts: [String] = [project.title]
        if let window = project.window {
            switch window.kind {
            case .project, .worktree: parts.append("another window")
            case .plain: parts.append("a window with no project")
            case .server: parts.append("a window on " + (window.destination ?? "a server"))
            }
        } else if project.windows > 1 {
            parts.append("open in \(project.windows) windows")
        } else if project.isOpen {
            parts.append("open")
        } else {
            parts.append("in " + folder(of: project, home: home))
        }
        if let marks = project.marks.spoken(working: working) { parts.append(marks) }
        if project.window != nil, project.hasProject { parts.append("in " + folder(of: project, home: home)) }
        if let branch, !branch.isEmpty { parts.append("branch " + branch) }
        return parts.joined(separator: ", ")
    }
}

/// The agent sessions read per project, so going back to one shows them at once while they are read again: the `limit`
/// projects read last, the others let go, so moving through a long list never keeps every project's sessions.
public struct SwitcherSessionCache<Value> {
    /// How many projects the Welcome window keeps.
    public static var standardLimit: Int { 20 }

    public let limit: Int
    private var values: [String: Value] = [:]
    /// The paths kept, the one read last first.
    public private(set) var paths: [String] = []

    /// `limit`: how many projects it keeps, `standardLimit` unless given.
    public init(limit: Int? = nil) {
        self.limit = max(1, limit ?? Self.standardLimit)
    }

    /// A project's sessions as read last; nil when not kept. Looking does not count as a read. Set: read now, it is the
    /// newest kept, and past `limit` the one read longest ago goes; nil lets it go.
    public subscript(path: String) -> Value? {
        get { values[path] }
        set {
            paths.removeAll { (kept: String) -> Bool in kept == path }
            guard let newValue else {
                values[path] = nil
                return
            }
            values[path] = newValue
            paths.insert(path, at: 0)
            while paths.count > limit { values[paths.removeLast()] = nil }
        }
    }
}
