import Foundation

// The window column: a strip at every Next Term window's outer edge, on the project sidebar's side, listing each open
// window, folded to its rail (a dot apiece) or unfolded to a row apiece. Its rows come from the index of every window
// (WindowIndex), the same list ⌘O, ⇧⌘U and the Dock menu read, so they agree. Values in, rows out: the views only draw
// them, and a change to one window's entry says which row, if any, has to be drawn again.

/// One window's row in the window column: its dot on the rail, its row when unfolded.
public struct WindowColumnRow: Equatable, Sendable {
    /// The window's id in the index.
    public let id: Int
    /// 1 for a linked worktree's window under its repository's own window; 0 for every other.
    public let depth: Int
    /// The name shown (WindowColumnName.shown): the project's, a worktree's own part, a folder's, a server's.
    public let name: String
    /// Before the name, dimmer: a worktree's repository when no window of the repository is open ("xCloud"); else nil.
    public let prefix: String?
    /// After the name, dimmer, only while another row shows the same name: where the window is, or else what is in front
    /// in it (WindowColumnList.build); else nil.
    public let detail: String?
    /// The project's colour; nil for none (a neutral dot).
    public let color: ProjectColor?
    /// The most urgent of needs you, failed and done; nil for none (working is no dot's business).
    public let urgent: TabState?
    /// The unfolded row's marks, with counts, as ⌘O shows them.
    public let marks: [AgentMarks.Mark]
    /// "<title>\n<marks in words>", or the title alone.
    public let toolTip: String
    /// What VoiceOver reads: "xCloud ▸ 7027-sso: 1 needs you", or the title alone.
    public let label: String

    /// What is drawn: a change here draws the dot or row again.
    public struct Face: Equatable, Sendable {
        public let depth: Int
        public let name: String
        public let prefix: String?
        public let detail: String?
        public let color: ProjectColor?
        public let urgent: TabState?
        public let marks: [AgentMarks.Mark]
    }

    /// What is only read, by the tooltip and VoiceOver: a change here draws nothing.
    public struct Words: Equatable, Sendable {
        public let toolTip: String
        public let label: String
    }

    public var face: Face { Face(depth: depth, name: name, prefix: prefix, detail: detail, color: color, urgent: urgent, marks: marks) }
    public var words: Words { Words(toolTip: toolTip, label: label) }

    /// `window`'s row at `depth`, in `color` (left out for a window with no project), its marks with working shown or
    /// not as View › Agent Spinner says (`showsWorking`), and `detail` after its name.
    public init(window: WindowIndex.Window, depth: Int, color: ProjectColor?, showsWorking: Bool, detail: String? = nil) {
        let shown: (prefix: String?, name: String) = WindowColumnName.shown(window, depth: depth)
        let spoken: String? = window.marks.spoken(working: showsWorking)
        self.id = window.id
        self.depth = depth
        self.name = shown.name
        self.prefix = shown.prefix
        self.detail = detail == shown.name ? nil : detail
        self.color = window.kind.hasProject ? color : nil
        self.urgent = Self.urgent(window.marks)
        self.marks = window.marks.shown(working: showsWorking)
        self.toolTip = spoken.map { (words: String) -> String in window.title + "\n" + words } ?? window.title
        self.label = spoken.map { (words: String) -> String in window.title + ": " + words } ?? window.title
    }

    /// The row with `detail` after its name instead.
    func with(detail: String?) -> WindowColumnRow {
        WindowColumnRow(id: id, depth: depth, name: name, prefix: prefix, detail: detail == name ? nil : detail, color: color,
                        urgent: urgent, marks: marks, toolTip: toolTip, label: label)
    }

    private init(id: Int, depth: Int, name: String, prefix: String?, detail: String?, color: ProjectColor?, urgent: TabState?,
                 marks: [AgentMarks.Mark], toolTip: String, label: String) {
        self.id = id
        self.depth = depth
        self.name = name
        self.prefix = prefix
        self.detail = detail
        self.color = color
        self.urgent = urgent
        self.marks = marks
        self.toolTip = toolTip
        self.label = label
    }

    /// What the row is known by on the screen: its prefix and its name. Two rows with the same are told apart by a detail.
    var shownKey: String { (prefix.map { (prefix: String) -> String in prefix + WorktreeWindow.separator } ?? "") + name }

    /// The dot's mark: needs you over failed over done, as Go to Next Agent Needing You goes; none for working, a lost
    /// connection or nothing. The rail shows only needs you and failed; the list's marks say the rest.
    public static func urgent(_ marks: AgentMarks) -> TabState? {
        if marks.attention > 0 { return .attention }
        if marks.failed > 0 { return .failed }
        if marks.done > 0 { return .done }
        return nil
    }
}

/// What a row of the window column calls its window. The tooltip, VoiceOver, the Window menu and ⌘O keep the whole title;
/// the row shows the part that tells it from the windows around it.
public enum WindowColumnName {
    /// What the row shows of `window` at `depth`: a project's or a server's name as it is; a window with no project by its
    /// folder ("Downloads" of "~/Downloads", "~" at home); a worktree by its own part without its repository's name in front
    /// ("cx-8858" of "xCloud ▸ xCloud-cx-8858"), under its repository's row, or with no window of the repository open after
    /// it as a dimmer prefix ("xCloud", then "cx-8858").
    public static func shown(_ window: WindowIndex.Window, depth: Int) -> (prefix: String?, name: String) {
        switch window.kind {
        case .worktree:
            guard let repository = repositoryPart(of: window.name) else { return (nil, window.name) }
            let own: String = stripped(ownPart(of: window.name), repository: repository)
            return depth > 0 ? (nil, own) : (repository, own)
        case .plain:
            if window.name == "~" { return (nil, "~") }
            let last: String = (window.name as NSString).lastPathComponent
            return (nil, last.isEmpty ? window.name : last)
        case .project, .server:
            return (nil, window.name)
        }
    }

    /// A worktree's own part of its name: "7027-sso" of "xCloud ▸ 7027-sso"; any other name as it is.
    public static func ownPart(of name: String) -> String {
        guard let range = name.range(of: WorktreeWindow.separator) else { return name }
        let own: String = String(name[range.upperBound...])
        return own.isEmpty ? name : own
    }

    /// The repository's part of a worktree's name: "xCloud" of "xCloud ▸ 7027-sso"; nil for a name without one.
    public static func repositoryPart(of name: String) -> String? {
        guard let range = name.range(of: WorktreeWindow.separator) else { return nil }
        let repository: String = String(name[..<range.lowerBound])
        return repository.isEmpty || name[range.upperBound...].isEmpty ? nil : repository
    }

    /// A worktree's own part without its repository's name and the "-", "_" or "." after it, in any case: "cx-8858" of
    /// "xCloud-cx-8858" in xCloud. As it is when nothing would be left, or it does not start so ("7027-sso").
    public static func stripped(_ own: String, repository: String) -> String {
        guard !repository.isEmpty, own.count > repository.count + 1, own.lowercased().hasPrefix(repository.lowercased()) else { return own }
        let rest: Substring = own.dropFirst(repository.count)
        guard let joint = rest.first, "-_.".contains(joint) else { return own }
        let left: String = String(rest.dropFirst())
        return left.isEmpty ? own : left
    }

    /// Where a window is, to tell it from another of the same name: a project's or worktree's parent folder ("~/Code"),
    /// a window with no project's folder's parent ("~/Work" of "~/Work/app"; none for "~" or "/"), a server's destination.
    public static func place(of window: WindowIndex.Window, home: String) -> String? {
        switch window.kind {
        case .project, .worktree:
            guard let project = window.project else { return nil }
            let parent: String = (project as NSString).deletingLastPathComponent
            return parent.isEmpty || parent == project ? nil : RecentProjects.abbreviate(parent, home: home)
        case .plain:
            let parent: String = (window.name as NSString).deletingLastPathComponent
            return parent.isEmpty || parent == window.name ? nil : parent
        case .server:
            return window.destination
        }
    }
}

/// The window column's rows, in order: windows in the order they opened, a linked worktree's window right under its
/// repository's own (the one exception to that order), and the count for its header.
public struct WindowColumnList: Equatable, Sendable {
    /// What a change to the windows asks of a column: nothing; drawing these windows' rows again (or only their tooltips
    /// and VoiceOver labels, which a view tells by their faces); or laying the column out again (a window opened or
    /// closed, or moved in or out of a repository's rows).
    public enum Change: Equatable, Sendable {
        case none
        case rows([Int])
        case structure
    }

    public private(set) var rows: [WindowColumnRow] = []
    /// The windows as the index has them, in its order, and their colours: what a later change is laid against.
    private var windows: [WindowIndex.Window] = []
    private var colors: [Int: ProjectColor] = [:]
    /// The home folder places are shortened by ("~/Code").
    private var home: String = NSHomeDirectory()

    public init() {}

    /// How many windows are open: the header's count.
    public var count: Int { rows.count }

    public func row(_ id: Int) -> WindowColumnRow? {
        rows.first { (row: WindowColumnRow) -> Bool in row.id == id }
    }

    /// The rows for `windows`, in the index's order (the order they opened), each in its `colors` entry.
    /// - Windows group by their repository (a linked worktree's main checkout), else their project; a window with no
    ///   project is a group of its own. Groups go in the order their first window opened.
    /// - In a group, the repository's own windows first, then its worktrees' windows, each in the order it opened; the
    ///   worktrees one deep, under the repository's, when one of its own is open, and showing only their own part.
    /// - Rows that show the same name get a detail apiece (`details`); `home` shortens their places.
    public static func build(windows: [WindowIndex.Window], colors: [Int: ProjectColor], showsWorking: Bool,
                             home: String = NSHomeDirectory()) -> WindowColumnList {
        var order: [String] = []
        var members: [String: [WindowIndex.Window]] = [:]
        for window in windows {
            let key: String = group(of: window)
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(window)
        }
        var rows: [WindowColumnRow] = []
        rows.reserveCapacity(windows.count)
        for key in order {
            let group: [WindowIndex.Window] = members[key] ?? []
            let own: [WindowIndex.Window] = group.filter { (window: WindowIndex.Window) -> Bool in window.kind != .worktree }
            let trees: [WindowIndex.Window] = group.filter { (window: WindowIndex.Window) -> Bool in window.kind == .worktree }
            let depth: Int = own.isEmpty ? 0 : 1
            for window in own {
                rows.append(WindowColumnRow(window: window, depth: 0, color: colors[window.id], showsWorking: showsWorking))
            }
            for window in trees {
                rows.append(WindowColumnRow(window: window, depth: depth, color: colors[window.id], showsWorking: showsWorking))
            }
        }
        var list = WindowColumnList()
        list.rows = details(rows, windows: windows, home: home)
        list.windows = windows
        list.colors = colors
        list.home = home
        return list
    }

    /// Rows that show the same name, each with a detail after it: where its window is, when those differ (its parent
    /// folder, a server's destination); among rows still alike there, what is in front in each (its title after the name:
    /// an agent, a command, a file), when those differ; and among rows alike in that too, a worktree's own part as its
    /// folder names it, before the repository's name came off. A row alone with its name has none: the name is enough.
    static func details(_ rows: [WindowColumnRow], windows: [WindowIndex.Window], home: String) -> [WindowColumnRow] {
        var named: [String: [Int]] = [:]
        for (index, row) in rows.enumerated() { named[row.shownKey, default: []].append(index) }
        var told: [WindowColumnRow] = rows
        for indices in named.values where indices.count > 1 {
            let entries: [WindowIndex.Window?] = indices.map { (index: Int) -> WindowIndex.Window? in
                windows.first { (window: WindowIndex.Window) -> Bool in window.id == rows[index].id }
            }
            let ways: [[String?]] = [
                entries.map { (window: WindowIndex.Window?) -> String? in window.flatMap { WindowColumnName.place(of: $0, home: home) } },
                entries.map { (window: WindowIndex.Window?) -> String? in window?.front },
                entries.map { (window: WindowIndex.Window?) -> String? in
                    window.flatMap { $0.kind == .worktree ? WindowColumnName.ownPart(of: $0.name) : nil }
                },
            ]
            var chosen: [String?] = Array(repeating: nil, count: indices.count)
            tellApart(Array(indices.indices), ways: ways[...], into: &chosen)
            for (at, index) in indices.enumerated() { told[index] = rows[index].with(detail: chosen[at]) }
        }
        return told
    }

    /// `members` (places in a group of rows alike so far) told apart by the first of `ways` that differs among them; those
    /// still alike in it, by the next.
    private static func tellApart(_ members: [Int], ways: ArraySlice<[String?]>, into chosen: inout [String?]) {
        guard members.count > 1, let way = ways.first else { return }
        let values: [String?] = members.map { (member: Int) -> String? in way[member] }
        guard Set(values).count > 1 else { return tellApart(members, ways: ways.dropFirst(), into: &chosen) }
        var alike: [String?: [Int]] = [:]
        for member in members {
            chosen[member] = way[member]
            alike[way[member], default: []].append(member)
        }
        for group in alike.values where group.count > 1 { tellApart(group, ways: ways.dropFirst(), into: &chosen) }
    }

    /// The list with `window`'s entry as it is now, and what that asks of a column. Only that window's row is made again:
    /// the same row is `.none` (its lastKey, or a tab's title it does not show), a different one `.rows` with its id. A row
    /// whose shown name changed, or one sharing its name with others, makes the rows again, as their details may change
    /// with it, and `.rows` names the ones that did. A window not listed yet, or one that moved into or out of a group, is
    /// `.structure`, with the whole list made again.
    public func updating(_ window: WindowIndex.Window, color: ProjectColor?, showsWorking: Bool) -> (list: WindowColumnList, change: Change) {
        var next: WindowColumnList = self
        next.colors[window.id] = color
        guard let at = windows.firstIndex(where: { (known: WindowIndex.Window) -> Bool in known.id == window.id }),
              let place = rows.firstIndex(where: { (row: WindowColumnRow) -> Bool in row.id == window.id }) else {
            next.windows.append(window)
            return (Self.build(windows: next.windows, colors: next.colors, showsWorking: showsWorking, home: home), .structure)
        }
        let old: WindowIndex.Window = windows[at]
        next.windows[at] = window
        let regrouped: Bool = Self.group(of: old) != Self.group(of: window) || (old.kind == .worktree) != (window.kind == .worktree)
        if regrouped { return (Self.build(windows: next.windows, colors: next.colors, showsWorking: showsWorking, home: home), .structure) }
        let before: WindowColumnRow = rows[place]
        let row = WindowColumnRow(window: window, depth: before.depth, color: color, showsWorking: showsWorking)
        let shared: Bool = rows.contains { (other: WindowColumnRow) -> Bool in other.id != before.id && other.shownKey == before.shownKey }
        if row.shownKey != before.shownKey || shared {
            let remade = Self.build(windows: next.windows, colors: next.colors, showsWorking: showsWorking, home: home)
            return (remade, Self.change(from: self, to: remade))
        }
        next.rows[place] = row
        return (next, row == before ? .none : .rows([window.id]))
    }

    /// What going from `old` to `new` asks of a column (a colour or View › Agent Spinner changed, and every row was made
    /// again): `.structure` when the windows or their nesting differ, else the rows that differ.
    public static func change(from old: WindowColumnList, to new: WindowColumnList) -> Change {
        let oldIDs: [Int] = old.rows.map(\.id)
        let newIDs: [Int] = new.rows.map(\.id)
        let oldDepths: [Int] = old.rows.map(\.depth)
        let newDepths: [Int] = new.rows.map(\.depth)
        guard oldIDs == newIDs, oldDepths == newDepths else { return .structure }
        var changed: [Int] = []
        for (before, after) in zip(old.rows, new.rows) where before != after { changed.append(after.id) }
        return changed.isEmpty ? .none : .rows(changed)
    }

    /// Lists are the same when they show the same rows.
    public static func == (lhs: WindowColumnList, rhs: WindowColumnList) -> Bool { lhs.rows == rhs.rows }

    /// The group a window's row goes in: its repository's (a linked worktree's main checkout), else its project's; a
    /// window with no project is one of its own.
    static func group(of window: WindowIndex.Window) -> String {
        if window.kind.hasProject, let path = window.repository ?? window.project { return "project:" + path }
        return "window:\(window.id)"
    }
}
