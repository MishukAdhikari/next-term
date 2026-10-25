import Foundation

/// One row of the terminal's tab list, the tabs shown down the terminal's side instead of along its top: a tab, or
/// one pane of a split tab, under it. A value, so the list tells a change from nothing new by comparing; keyed by
/// what it shows, so a tab opening or closing touches its own rows and no other.
public struct TabListRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case tab
        /// One pane of a split tab: `index` counts from 0, of `count` panes.
        case pane(index: Int, count: Int)
        /// One of herdr's agents, under the row of the tab or pane that shows herdr: `index` counts from 0 in herdr's
        /// order, of `count`.
        case herdrAgent(index: Int, count: Int)
        /// A tab's idle herdr agents folded into one row ("5 idle"), past HerdrAgents.foldsPast agents; `open` while
        /// they show under it.
        case herdrFolded(count: Int, open: Bool)
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
    /// An agent's row: herdr's pane id for it.
    public var herdrPane: String?
    /// What VoiceOver says for the title when it is not the title as shown (an agent's row says its time with its
    /// state, in full words); nil: the title.
    public var spokenTitle: String?

    public init(key: String, kind: Kind = .tab, title: String, truncatesTail: Bool = false, shorterTitles: [String] = [],
                editableTitle: String? = nil, state: TabState = .idle, tooltip: String = "", spokenStatus: String = "",
                shortcut: String? = nil, remote: RemoteMark? = nil, place: String? = nil, detail: String? = nil,
                detailIsQuestion: Bool = false, focused: Bool = false, herdrPane: String? = nil) {
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
        self.herdrPane = herdrPane
    }

    /// A row under its tab's: a pane's, a herdr agent's, or the folded idle agents'.
    public var isPane: Bool { kind != .tab }

    /// One of herdr's agents.
    public var isAgent: Bool {
        if case .herdrAgent = kind { return true }
        return false
    }

    /// The row of a tab's folded idle herdr agents.
    public var isFolded: Bool {
        if case .herdrFolded = kind { return true }
        return false
    }

    /// What VoiceOver says: the top bar's words for the tab (title, state, server, place) and the second line
    /// once, unless the state said it already (a question is in "Needs your decision: …"). A pane row says where
    /// it is in its tab: "claude, pane 2 of 3, Working"; an agent's row, "codex, herdr agent 2 of 3, Needs your
    /// decision"; the folded row, "5 idle herdr agents, collapsed".
    public var accessibilityLabel: String {
        if case .herdrFolded(let count, let open) = kind {
            return "\(count) idle herdr agent\(count == 1 ? "" : "s"), \(open ? "expanded" : "collapsed")"
        }
        var parts: [String] = [spokenTitle ?? title]
        if case .pane(let index, let count) = kind { parts.append("pane \(index + 1) of \(count)") }
        if case .herdrAgent(let index, let count) = kind { parts.append("herdr agent \(index + 1) of \(count)") }
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
        /// It shows herdr: herdr's agents, each a row after this pane's (after the tab's, for a tab of one pane).
        public var herdrAgents: [Agent]
        /// Its folded idle agents show (HerdrAgents.fold).
        public var herdrIdleOpen: Bool

        public init(key: String, title: String, truncatesTail: Bool = false, shorterTitles: [String] = [],
                    editableTitle: String? = nil, state: TabState = .idle, tooltip: String = "", spokenStatus: String = "",
                    folder: String = "", question: String? = nil, remote: RemoteMark? = nil, focused: Bool = false,
                    herdrAgents: [Agent] = [], herdrIdleOpen: Bool = false) {
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
            self.herdrAgents = herdrAgents
            self.herdrIdleOpen = herdrIdleOpen
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
    /// most needs you, as the top bar's tab is. `workingShown` is false while the agent spinner is off. A pane that
    /// shows herdr has a row per agent after its own (after the tab's, for a tab of one pane), with how long each has
    /// been in its state at `now` (none without it).
    public static func make(tabs: [Source], showsFolders: Bool, home: String, workingShown: Bool = true,
                            now: TimeInterval? = nil) -> [TabListRow] {
        var rows: [TabListRow] = []
        rows.reserveCapacity(tabs.count)
        for source in tabs {
            rows.append(tabRow(source, showsFolders: showsFolders, home: home, workingShown: workingShown))
            guard source.panes.count > 1 else {
                if let pane = source.panes.first { rows += agentRows(pane, showsFolders: showsFolders, home: home, now: now) }
                continue
            }
            for (index, pane) in source.panes.enumerated() {
                rows.append(paneRow(pane, index: index, count: source.panes.count))
                rows += agentRows(pane, showsFolders: showsFolders, home: home, now: now)
            }
        }
        return rows
    }

    /// The rows of herdr's agents in `pane`, keyed `<pane's key>/herdr/<herdr's pane id>`, in herdr's order. Past
    /// HerdrAgents.foldsPast agents the idle ones fold into one row after the others, keyed `<pane's key>/herdr/idle`,
    /// and show under it while it is open.
    static func agentRows(_ pane: Pane, showsFolders: Bool, home: String, now: TimeInterval?) -> [TabListRow] {
        let agents = pane.herdrAgents
        guard !agents.isEmpty else { return [] }
        let count = agents.count
        let place = Dictionary(agents.enumerated().map { ($0.element.pane, $0.offset) }, uniquingKeysWith: { first, _ in first })
        func row(_ agent: Agent) -> TabListRow {
            agentRow(agent, in: pane, index: place[agent.pane] ?? 0, count: count, showsFolders: showsFolders, home: home, now: now)
        }
        let (shown, folded) = HerdrAgents.fold(agents)
        var rows = shown.map(row)
        guard !folded.isEmpty else { return rows }
        let names = folded.map { agent in agent.disambiguation.map { "\(agent.name) (\($0))" } ?? agent.name }
        let tip = "\(folded.count) idle herdr agents: " + names.joined(separator: ", ")
        rows.append(TabListRow(key: "\(pane.key)/herdr/idle", kind: .herdrFolded(count: folded.count, open: pane.herdrIdleOpen),
                               title: (pane.herdrIdleOpen ? "▾ " : "▸ ") + "\(folded.count) idle", tooltip: tip))
        if pane.herdrIdleOpen { rows += folded.map(row) }
        return rows
    }

    /// One agent's row: herdr's name for it, its title and what tells it from a row that reads the same ("claude · Fix
    /// login · api"), then how long it has waited or worked ("waiting 4 min"), which goes first when the row is narrow;
    /// herdr's state as the mark, and with Show Folders its question, else where it works ("web-1: /srv/api").
    static func agentRow(_ agent: Agent, in pane: Pane, index: Int, count: Int, showsFolders: Bool, home: String,
                         now: TimeInterval?) -> TabListRow {
        let named = [agent.name, agent.title, agent.disambiguation].compactMap { $0 }.joined(separator: " · ")
        let time = now.flatMap { agent.time(now: $0) }
        let title = time.map { named + " · " + $0 } ?? named
        var shorter: [String] = []
        if let time { shorter = [agent.name + " · " + time, agent.name].filter { $0 != title } }
        let spoken = [agent.words, now.flatMap { agent.spokenTime(now: $0) }].compactMap { $0 }.joined(separator: ", ")
        var row = TabListRow(key: "\(pane.key)/herdr/\(agent.pane)", kind: .herdrAgent(index: index, count: count), title: title,
                             truncatesTail: true, shorterTitles: shorter, state: agent.state, tooltip: agent.tooltip(now: now),
                             spokenStatus: spoken, focused: agent.focused, herdrPane: agent.pane)
        if time != nil { row.spokenTitle = named }
        guard showsFolders else { return row }
        let line = detail(folder: agent.directory ?? "", question: agent.question, remoteHost: pane.remote?.host, home: home)
        row.detail = line?.text
        row.detailIsQuestion = line?.isQuestion ?? false
        return row
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
