import Foundation

/// Every agent the user may need to get to, in one queue: each of herdr's agents and each Next Term tab whose program is
/// an agent, so the user never has to know which kind is waiting. Window › Go to Agent…, Go to Next Agent Needing You and
/// the Dock menu are made from it; the tab list is not (its rows keep their place). Built from what the last checks left:
/// nothing runs to make it.
///
/// Needs You comes first: what waits on a decision (a blocked herdr agent, a tab whose agent asks), then what finished
/// and is not seen (herdr's done, what Next Term keeps unread, a tab's done mark), oldest first within each, as herdr's
/// own priority sort orders them; the agent on screen is left out. The rest follow under one heading per place ("This
/// Mac" first, then each host and herdr session), in the order they were given: herdr's agents in herdr's order, tabs in
/// tab order.
public struct AgentQueue: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        /// What choosing it goes to.
        public enum Target: Equatable, Hashable, Sendable {
            /// A Next Term tab whose program is an agent: the tab's id.
            case tab(String)
            /// One of herdr's agents: the id of a Next Term tab that shows its herdr, and herdr's pane id.
            case herdr(tab: String, pane: String)
            /// One of herdr's agents on a connected host with no herdr tab: the host's id and herdr's pane id. Choosing
            /// it opens a herdr tab there.
            case host(id: String, pane: String)
            /// A saved host kept with herdr that is not connected: choosing it opens a herdr tab there.
            case saved(id: String)
        }

        public var target: Target
        /// One per agent however many tabs show it: a tab's id, or herdr's place (host and session) and pane.
        public var key: String
        public var name: String
        /// The heading it goes under: "This Mac", "web-1", "web-1 — review".
        public var group: String
        public var state: TabState
        /// Its state in words: "Needs your decision", "Done", "Working".
        public var words: String
        /// When it began to need the user (a decision, or a finish not seen), and when it began to work, as Next Term
        /// saw them; nil when not known.
        public var needsSince: TimeInterval?
        public var workSince: TimeInterval?
        /// The user is looking at it.
        public var onScreen: Bool
        /// The question it waits on, and its choices when they were read.
        public var question: String?
        public var choices: [String]
        /// Its tooltip in the menu.
        public var tooltip: String

        public init(target: Target, key: String, name: String, group: String, state: TabState, words: String,
                    needsSince: TimeInterval? = nil, workSince: TimeInterval? = nil, onScreen: Bool = false,
                    question: String? = nil, choices: [String] = [], tooltip: String = "") {
            self.target = target
            self.key = key
            self.name = name
            self.group = group
            self.state = state
            self.words = words
            self.needsSince = needsSince
            self.workSince = workSince
            self.onScreen = onScreen
            self.question = question
            self.choices = choices
            self.tooltip = tooltip
        }

        /// 0: waits on a decision; 1: finished and not seen; 2: works; 3: idle.
        public var rank: Int {
            switch state {
            case .attention: return 0
            case .done, .failed: return 1
            case .working: return 2
            case .idle: return 3
            }
        }

        /// It needs the user: a decision, or a finish not seen.
        public var needsYou: Bool { rank <= 1 }

        /// How long it has waited ("waiting 4 min") or worked ("working 12 min") at `now`; nil under a minute.
        public func time(now: TimeInterval) -> String? {
            if needsYou, let since = needsSince, let said = HerdrAgents.duration(now - since) { return "waiting " + said }
            if state == .working, let since = workSince, let said = HerdrAgents.duration(now - since) { return "working " + said }
            return nil
        }

        /// Its line in Go to Agent: "codex — Needs your decision · waiting 4 min". It starts with the name, so typing
        /// the name selects it.
        public func menuTitle(now: TimeInterval?) -> String {
            let time = now.flatMap { self.time(now: $0) }
            return "\(name) — " + ([words, time].compactMap { $0 }.joined(separator: " · "))
        }

        /// Its line in the Dock menu: "codex — web-1 — Needs your decision".
        public var dockTitle: String { [name, group, words].joined(separator: " — ") }
    }

    /// One heading of Go to Agent and the agents under it.
    public struct Section: Equatable, Sendable {
        public var title: String
        public var items: [Item]

        public init(title: String, items: [Item]) {
            self.title = title
            self.items = items
        }
    }

    /// The heading of this Mac's own agents, which comes before every host's.
    public static let thisMac = "This Mac"
    /// The heading of the saved herdr hosts that are not connected.
    public static let notConnected = "Not Connected"

    /// The heading of a connected host's agents while no tab shows its herdr: "web-2 (no herdr tab)".
    public static func noHerdrTab(_ host: String) -> String { "\(host) (no herdr tab)" }

    /// One item per saved host kept with herdr that has no connection ("web-3 — not connected"), in the hosts' order;
    /// none for a host kept another way, or connected. Nothing is run for them.
    public static func notConnected(_ hosts: [(id: String, name: String, keep: KeepMode)], connected: Set<String>) -> [Item] {
        hosts.filter { $0.keep == .herdr && !connected.contains($0.id) }.map { host in
            Item(target: .saved(id: host.id), key: "saved \(host.id)", name: host.name, group: notConnected, state: .idle,
                 words: "not connected", tooltip: "Opens a herdr tab on \(host.name)")
        }
    }
    /// The heading of what needs the user.
    public static let needsYouTitle = "Needs You"

    /// Each agent once, in the order given.
    public private(set) var items: [Item]
    /// What needs the user and is not on screen, most urgent first, oldest first within each.
    public private(set) var needsYou: [Item]
    /// The rest, under their headings.
    public private(set) var groups: [Section]

    /// The queue of `items`, given tabs in tab order and each herdr's agents in herdr's order. An agent given twice (two
    /// tabs on one herdr session) is one, on screen if either says so.
    public init(_ given: [Item]) {
        var kept: [Item] = []
        var index: [String: Int] = [:]
        for item in given {
            if let at = index[item.key] {
                if item.onScreen { kept[at].onScreen = true }
                continue
            }
            index[item.key] = kept.count
            kept.append(item)
        }
        items = kept
        let waiting = Self.ordered(kept.filter(\.needsYou))
        needsYou = waiting.filter { !$0.onScreen }
        let listed = Set(needsYou.map(\.key))
        var sections: [Section] = []
        for item in kept where !listed.contains(item.key) {
            if let at = sections.firstIndex(where: { $0.title == item.group }) {
                sections[at].items.append(item)
            } else {
                sections.append(Section(title: item.group, items: [item]))
            }
        }
        // This Mac first; the others as they came.
        let mine = sections.filter { $0.title == Self.thisMac }
        groups = mine + sections.filter { $0.title != Self.thisMac }
    }

    /// Most urgent first, then oldest first (an agent with no time after those with one), then as given.
    static func ordered(_ items: [Item]) -> [Item] {
        items.enumerated().sorted { left, right in
            let (a, b) = (left.element, right.element)
            if a.rank != b.rank { return a.rank < b.rank }
            let (x, y) = (a.needsSince ?? .infinity, b.needsSince ?? .infinity)
            if x != y { return x < y }
            return left.offset < right.offset
        }.map(\.element)
    }

    public var isEmpty: Bool { items.isEmpty }

    /// Go to Agent's headings: Needs You first, when anything does, then the places.
    public var sections: [Section] {
        (needsYou.isEmpty ? [] : [Section(title: Self.needsYouTitle, items: needsYou)]) + groups
    }

    /// The items in the order Go to Agent shows them, for its digits: the first nine take 1-9.
    public var shownItems: [Item] { sections.flatMap(\.items) }

    /// Go to Agent's key for the item at `index` of `shownItems`: "1" to "9", then none.
    public static func digit(_ index: Int) -> String? { (0..<9).contains(index) ? String(index + 1) : nil }

    /// Go to Next Agent Needing You: after `key` (the one it went to last), the next that needs the user and is not on
    /// screen, round to the first after the last; from the first when `key` is nil or needs nothing now. The agent it
    /// went to last is on screen now, so the round counts it to know where it was: pressed again, it moves on. nil
    /// when nothing off screen needs the user.
    public func next(after key: String?) -> Item? {
        let round = Self.ordered(items.filter(\.needsYou))
        let start = key.flatMap { key in round.firstIndex { $0.key == key }.map { $0 + 1 } } ?? 0
        for step in 0..<round.count {
            let item = round[(start + step) % round.count]
            if !item.onScreen { return item }
        }
        return nil
    }

    /// The Dock menu's agents: Needs You in its order, `limit` at most.
    public func dockItems(limit: Int = 8) -> [Item] { Array(needsYou.prefix(limit)) }
}
