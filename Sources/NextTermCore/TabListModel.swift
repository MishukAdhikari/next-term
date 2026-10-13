import Foundation

/// One row of the terminal's tab list, the tabs shown down the terminal's side instead of along its top: a tab, or
/// one pane of a split tab, under it. A value, so the list tells a change from nothing new by comparing; keyed by
/// what it shows, so a tab opening or closing touches its own rows and no other.
public struct TabListRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case tab
        /// One pane of a split tab: `index` counts from 0, of `count` panes.
        case pane(index: Int, count: Int)
    }

    /// Stable while what it shows lives: the tab's pane group for a tab row, the pane itself for a pane row. The
    /// caller takes the two from different spaces, so no tab row and pane row share one.
    public var key: String
    public var kind: Kind
    /// The top bar's title for the same tab, word for word (the served port's " · :5173" with it), without the
    /// bar's "+N" for a split tab: its panes are the rows under it.
    public var title: String
    /// A title a program set is prose and gives way at its end; a folder's or a program's name keeps both ends.
    public var truncatesTail: Bool
    /// Shorter forms of the title, tried in order when it does not fit ("app (connecting)", then "app").
    public var shorterTitles: [String]
    /// What the rename field starts with; nil for a pane row, which renames nothing (the tab is renamed).
    public var editableTitle: String?
    public var state: TabState
    public var tooltip: String
    /// The state in words, as the top bar's tab says it to VoiceOver ("" when the server mark says it).
    public var spokenStatus: String
    /// "⌘3"; nil for a pane row and for a tab with no key.
    public var shortcut: String?
    /// A tab on a server: the mark before its title, with the connection's dot.
    public var remote: RemoteMark?
    /// What the place mark after the title says; nil without one.
    public var place: String?
    /// The second line, with Show Folders: the tab's folder, or the question its agent is asking. Whole: the row
    /// shortens it to fit. nil with one line, and always for a pane row.
    public var detail: String?
    public var detailIsQuestion: Bool
    /// A pane row's pane has the keyboard in its tab.
    public var focused: Bool

    public init(key: String, kind: Kind = .tab, title: String, truncatesTail: Bool = false, shorterTitles: [String] = [],
                editableTitle: String? = nil, state: TabState = .idle, tooltip: String = "", spokenStatus: String = "",
                shortcut: String? = nil, remote: RemoteMark? = nil, place: String? = nil, detail: String? = nil,
                detailIsQuestion: Bool = false, focused: Bool = false) {
        self.key = key
        self.kind = kind
        self.title = title
        self.truncatesTail = truncatesTail
        self.shorterTitles = shorterTitles
        self.editableTitle = editableTitle
        self.state = state
        self.tooltip = tooltip
        self.spokenStatus = spokenStatus
        self.shortcut = shortcut
        self.remote = remote
        self.place = place
        self.detail = detail
        self.detailIsQuestion = detailIsQuestion
        self.focused = focused
    }

    public var isPane: Bool { kind != .tab }

    /// What VoiceOver says: the top bar's words for the tab (title, state, server, place) and the second line
    /// once, unless the state said it already (a question is in "Needs your decision: …"). A pane row says where
    /// it is in its tab: "claude, pane 2 of 3, Working".
    public var accessibilityLabel: String {
        var parts: [String] = [title]
        if case .pane(let index, let count) = kind { parts.append("pane \(index + 1) of \(count)") }
        parts.append(spokenStatus)
        parts.append(remote?.summary ?? "")
        parts.append(place ?? "")
        if let detail, !spokenStatus.contains(detail) { parts.append(detail) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// The tab list's rows, made from plain values the window already holds: nothing is read on its tick to make
/// them, and no git runs.
public enum TabListRows {
    /// One pane of a tab, as the list shows it.
    public struct Pane: Equatable, Sendable {
        public var key: String
        public var title: String
        public var truncatesTail: Bool
        public var shorterTitles: [String]
        public var editableTitle: String?
        public var state: TabState
        public var tooltip: String
        public var spokenStatus: String
        /// Where its shell is: on this Mac, or on its server for a remote one.
        public var folder: String
        /// The question its agent is waiting on, as read from its screen.
        public var question: String?
        public var remote: RemoteMark?
        /// It has the keyboard in its tab.
        public var focused: Bool

        public init(key: String, title: String, truncatesTail: Bool = false, shorterTitles: [String] = [],
                    editableTitle: String? = nil, state: TabState = .idle, tooltip: String = "", spokenStatus: String = "",
                    folder: String = "", question: String? = nil, remote: RemoteMark? = nil, focused: Bool = false) {
            self.key = key
            self.title = title
            self.truncatesTail = truncatesTail
            self.shorterTitles = shorterTitles
            self.editableTitle = editableTitle
            self.state = state
            self.tooltip = tooltip
            self.spokenStatus = spokenStatus
            self.folder = folder
            self.question = question
            self.remote = remote
            self.focused = focused
        }
    }

    /// One tab: its panes in its own order, and what belongs to the tab.
    public struct Source: Equatable, Sendable {
        public var key: String
        public var panes: [Pane]
        public var shortcut: String?
        public var place: String?
        /// The tab's tooltip and spoken status as the top bar has them (a split tab's name each pane); nil for the
        /// pane with the keyboard's own.
        public var tooltip: String?
        public var spokenStatus: String?

        public init(key: String, panes: [Pane], shortcut: String? = nil, place: String? = nil, tooltip: String? = nil,
                    spokenStatus: String? = nil) {
            self.key = key
            self.panes = panes
            self.shortcut = shortcut
            self.place = place
            self.tooltip = tooltip
            self.spokenStatus = spokenStatus
        }
    }

    /// A row per tab, in the tabs' own order whatever their marks (so "⌘3" stays on the third tab), each split tab
    /// followed by a row per pane. A tab's row is named by the pane with the keyboard and marked by the pane that
    /// most needs you, as the top bar's tab is. `workingShown` is false while the agent spinner is off.
    public static func make(tabs: [Source], showsFolders: Bool, home: String, workingShown: Bool = true) -> [TabListRow] {
        var rows: [TabListRow] = []
        rows.reserveCapacity(tabs.count)
        for source in tabs {
            rows.append(tabRow(source, showsFolders: showsFolders, home: home, workingShown: workingShown))
            guard source.panes.count > 1 else { continue }
            for (index, pane) in source.panes.enumerated() {
                rows.append(paneRow(pane, index: index, count: source.panes.count))
            }
        }
        return rows
    }

    private static func tabRow(_ source: Source, showsFolders: Bool, home: String, workingShown: Bool) -> TabListRow {
        guard let focused = source.panes.first(where: \.focused) ?? source.panes.first else {
            return TabListRow(key: source.key, title: "", shortcut: source.shortcut, place: source.place)
        }
        let split = source.panes.count > 1
        let state: TabState = mostUrgent(source.panes.map(\.state), workingShown: workingShown)
        let remote: RemoteMark? = split ? RemoteMark.split(focused: focused.remote, panes: source.panes.compactMap(\.remote)) : focused.remote
        var row = TabListRow(key: source.key, title: focused.title, truncatesTail: focused.truncatesTail, shorterTitles: focused.shorterTitles,
                             editableTitle: focused.editableTitle, state: state, tooltip: source.tooltip ?? focused.tooltip,
                             spokenStatus: source.spokenStatus ?? focused.spokenStatus, shortcut: source.shortcut, remote: remote,
                             place: source.place)
        guard showsFolders else { return row }
        // The pane that asks says so on the tab's line, the keyboard's first; else the keyboard pane's folder.
        let asking: Pane? = ([focused] + source.panes).first { hasQuestion($0.question) }
        let line = detail(folder: focused.folder, question: asking?.question, remoteHost: focused.remote?.host, home: home)
        row.detail = line?.text
        row.detailIsQuestion = line?.isQuestion ?? false
        return row
    }

    private static func paneRow(_ pane: Pane, index: Int, count: Int) -> TabListRow {
        TabListRow(key: pane.key, kind: .pane(index: index, count: count), title: pane.title, truncatesTail: pane.truncatesTail,
                   shorterTitles: pane.shorterTitles, state: pane.state, tooltip: pane.tooltip, spokenStatus: pane.spokenStatus,
                   remote: pane.remote, focused: pane.focused)
    }

    /// Needs you, then working, failed, done, idle: the mark a split tab shows for its panes, as on the top bar.
    /// With the agent spinner off a working pane shows no mark, so it never hides another pane's cross or check:
    /// it comes after them.
    public static func mostUrgent(_ states: [TabState], workingShown: Bool = true) -> TabState {
        let order: [TabState] = workingShown ? [.attention, .working, .failed, .done, .idle] : [.attention, .failed, .done, .working, .idle]
        return order.first { states.contains($0) } ?? .idle
    }

    /// The second line: the question while an agent asks one; else the folder, the home folder as "~"; for a tab
    /// on a server, "web-1: ~/app", its folder there as the server names it. nil with nothing to say.
    public static func detail(folder: String, question: String?, remoteHost: String?, home: String) -> (text: String, isQuestion: Bool)? {
        if let question, hasQuestion(question) { return (question, true) }
        if let remoteHost { return (folder.isEmpty ? remoteHost : "\(remoteHost): \(folder)", false) }
        guard !folder.isEmpty else { return nil }
        return (RecentProjects.abbreviate(folder, home: home), false)
    }

    private static func hasQuestion(_ question: String?) -> Bool {
        guard let question else { return false }
        return !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Each tab's rows: its own and its panes', as ranges of `kinds`. Rows begin with a tab's, as `make` gives them.
    public static func blocks(of kinds: [TabListRow.Kind]) -> [Range<Int>] {
        var blocks: [Range<Int>] = []
        var start = 0
        for (index, kind) in kinds.enumerated() where kind == .tab && index > start {
            blocks.append(start..<index)
            start = index
        }
        if start < kinds.count { blocks.append(start..<kinds.count) }
        return blocks
    }

    /// `rows` with tab `from` and its pane rows moved to tab place `to`: a dragged tab takes its panes with it.
    public static func moving(_ rows: [TabListRow], tab from: Int, to: Int) -> [TabListRow] {
        let blocks = blocks(of: rows.map(\.kind))
        guard from != to, blocks.indices.contains(from), blocks.indices.contains(to) else { return rows }
        var tabs: [ArraySlice<TabListRow>] = blocks.map { rows[$0] }
        let moved = tabs.remove(at: from)
        tabs.insert(moved, at: to)
        return Array(tabs.joined())
    }
}
