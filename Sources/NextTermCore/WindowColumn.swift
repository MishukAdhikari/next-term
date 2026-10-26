import Foundation

// The window column: a strip at every Next Term window's outer edge, on the project sidebar's side, listing each open
// window, folded to a badge apiece or unfolded to a row apiece. Its rows come from the index of every window
// (WindowIndex), the same list ⌘O, ⇧⌘U and the Dock menu read, so they agree. Values in, rows out: the views only draw
// them, and a change to one window's entry says which row, if any, has to be drawn again.

/// One window's row in the window column: its badge when the column is folded, its row when unfolded.
public struct WindowColumnRow: Equatable, Sendable {
    /// The window's id in the index.
    public let id: Int
    /// 1 for a linked worktree's window under its repository's own window; 0 for every other.
    public let depth: Int
    /// The name shown: the window's, or for a worktree nested under its repository only its own part ("7027-sso").
    public let name: String
    /// The badge's two letters ("NT", "7S", "Sh", "~").
    public let letters: String
    /// The project's colour; nil for none (a neutral badge).
    public let color: ProjectColor?
    /// The badge's dot: the most urgent of needs you, failed and done; nil for none (working puts no dot on a badge).
    public let urgent: TabState?
    /// The unfolded row's marks, with counts, as ⌘O shows them.
    public let marks: [AgentMarks.Mark]
    /// "<title>\n<marks in words>", or the title alone.
    public let toolTip: String
    /// What VoiceOver reads: "xCloud ▸ 7027-sso: 1 needs you", or the title alone.
    public let label: String

    /// What is drawn: a change here draws the badge or row again.
    public struct Face: Equatable, Sendable {
        public let depth: Int
        public let name: String
        public let letters: String
        public let color: ProjectColor?
        public let urgent: TabState?
        public let marks: [AgentMarks.Mark]
    }

    /// What is only read, by the tooltip and VoiceOver: a change here draws nothing.
    public struct Words: Equatable, Sendable {
        public let toolTip: String
        public let label: String
    }

    public var face: Face { Face(depth: depth, name: name, letters: letters, color: color, urgent: urgent, marks: marks) }
    public var words: Words { Words(toolTip: toolTip, label: label) }

    /// `window`'s row at `depth`, in `color` (left out for a window with no project), its marks with working shown or
    /// not as View › Agent Spinner says (`showsWorking`).
    public init(window: WindowIndex.Window, depth: Int, color: ProjectColor?, showsWorking: Bool) {
        let shown: String = depth > 0 ? WindowColumnBadge.ownPart(of: window.name) : window.name
        let spoken: String? = window.marks.spoken(working: showsWorking)
        self.id = window.id
        self.depth = depth
        self.name = shown
        self.letters = WindowColumnBadge.letters(name: window.name, kind: window.kind)
        self.color = window.kind.hasProject ? color : nil
        self.urgent = WindowColumnBadge.urgent(window.marks)
        self.marks = window.marks.shown(working: showsWorking)
        self.toolTip = spoken.map { (words: String) -> String in window.title + "\n" + words } ?? window.title
        self.label = spoken.map { (words: String) -> String in window.title + ": " + words } ?? window.title
    }
}

/// What a badge shows of its window.
public enum WindowColumnBadge {
    /// Two letters of the window's name: the first letters of its first two words, with words split at spaces,
    /// punctuation and lower-to-upper changes ("next-term" NT, "xCloud" XC, "7027-sso" 7S, "web-1" W1); a single word's
    /// first two letters, the first capitalised ("shop" Sh). A worktree's own part is its name ("xCloud ▸ 7027-sso" 7S),
    /// and a window with no project goes by its folder's name ("~/Downloads" Do); the home folder is "~".
    /// Whether the letters are set a little apart: two characters or more with no lowercase ("XC", "73", "7S"), as short
    /// capitals and figures read best that way; mixed case ("Ag") and one character ("~") as the font sets them.
    public static func tracks(_ letters: String) -> Bool {
        letters.count >= 2 && !letters.contains { (character: Character) -> Bool in character.isLowercase }
    }

    public static func letters(name: String, kind: WindowKind) -> String {
        var source: String = name
        switch kind {
        case .worktree:
            source = ownPart(of: name)
        case .plain:
            if name == "~" { return "~" }
            source = (name as NSString).lastPathComponent
        case .project, .server:
            break
        }
        let found: [String] = words(source)
        if found.count >= 2, let first = found[0].first, let second = found[1].first {
            return (String(first) + String(second)).uppercased()
        }
        if let word = found.first, let first = word.first {
            let rest: String = word.dropFirst().first.map(String.init) ?? ""
            return String(first).uppercased() + rest
        }
        // Nothing to spell with ("~", "/"): its first character.
        return source.first.map(String.init) ?? "?"
    }

    /// A worktree's own part of its name: "7027-sso" of "xCloud ▸ 7027-sso"; any other name as it is.
    public static func ownPart(of name: String) -> String {
        guard let range = name.range(of: WorktreeWindow.separator) else { return name }
        let own: String = String(name[range.upperBound...])
        return own.isEmpty ? name : own
    }

    /// The badge's dot: needs you over failed over done, as Go to Next Agent Needing You goes; none for working, a lost
    /// connection or nothing.
    public static func urgent(_ marks: AgentMarks) -> TabState? {
        if marks.attention > 0 { return .attention }
        if marks.failed > 0 { return .failed }
        if marks.done > 0 { return .done }
        return nil
    }

    /// Runs of letters and digits, split again where a lower-case letter meets an upper-case one.
    static func words(_ text: String) -> [String] {
        var found: [String] = []
        var current: String = ""
        var previous: Character?
        for character in text {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { found.append(current) }
                current = ""
                previous = nil
                continue
            }
            if let previous, previous.isLowercase, character.isUppercase, !current.isEmpty {
                found.append(current)
                current = ""
            }
            current.append(character)
            previous = character
        }
        if !current.isEmpty { found.append(current) }
        return found
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
    public static func build(windows: [WindowIndex.Window], colors: [Int: ProjectColor], showsWorking: Bool) -> WindowColumnList {
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
        list.rows = rows
        list.windows = windows
        list.colors = colors
        return list
    }

    /// The list with `window`'s entry as it is now, and what that asks of a column. Only that window's row is made again:
    /// the same row is `.none` (its lastKey, or a tab's title it does not show), a different one `.rows` with its id. A
    /// window not listed yet, or one that moved into or out of a group, is `.structure`, with the whole list made again.
    public func updating(_ window: WindowIndex.Window, color: ProjectColor?, showsWorking: Bool) -> (list: WindowColumnList, change: Change) {
        var next: WindowColumnList = self
        next.colors[window.id] = color
        guard let at = windows.firstIndex(where: { (known: WindowIndex.Window) -> Bool in known.id == window.id }),
              let place = rows.firstIndex(where: { (row: WindowColumnRow) -> Bool in row.id == window.id }) else {
            next.windows.append(window)
            return (Self.build(windows: next.windows, colors: next.colors, showsWorking: showsWorking), .structure)
        }
        let old: WindowIndex.Window = windows[at]
        next.windows[at] = window
        let regrouped: Bool = Self.group(of: old) != Self.group(of: window) || (old.kind == .worktree) != (window.kind == .worktree)
        if regrouped { return (Self.build(windows: next.windows, colors: next.colors, showsWorking: showsWorking), .structure) }
        let before: WindowColumnRow = rows[place]
        let row = WindowColumnRow(window: window, depth: before.depth, color: color, showsWorking: showsWorking)
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
