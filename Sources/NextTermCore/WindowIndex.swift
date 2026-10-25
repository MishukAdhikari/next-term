import Foundation

// Every terminal window and its agents, in one place. Each window tells it what its tabs show as it refreshes them, from
// their own status (nothing is polled for it), with herdr's agents one by one, and that it closed. Three things read it:
// Agents › Go to Next Agent Needing You, which goes through the terminals and herdr's agents that wait for you, the
// Welcome window's switcher, which gives each window a row with its marks, and the Dock menu, which lists the windows
// waiting for you.

/// What a terminal window is for, which says how it is named.
public enum WindowKind: String, Sendable {
    /// A project's window: its folder's name.
    case project
    /// A linked worktree's window: "xCloud ▸ 7027-sso", its repository's name and its own.
    case worktree
    /// A window with no project (New Terminal), named after its tab's folder: "~/Downloads".
    case plain
    /// A window with no project whose tab in front is on a server, named after the server.
    case server

    /// A window on a folder opened as a project, a worktree's too.
    public var hasProject: Bool { self == .project || self == .worktree }
}

/// How many of a window's terminals, tab by tab and pane by pane, and of herdr's agents it leads to, show each mark: what
/// its row in the Welcome window and its item in the Dock menu show of its agents.
public struct AgentMarks: Equatable, Sendable {
    /// A decision an agent waits on, or a bell: the amber mark.
    public var attention = 0
    public var failed = 0
    /// An agent that stopped, or a command that finished, not seen yet.
    public var done = 0
    public var working = 0
    /// A terminal on a server whose connection dropped, with nothing else to show: what it holds now is not known, so
    /// it is not counted idle. Go to Next Agent Needing You leaves it out.
    public var disconnected = 0

    public init() {}

    public init(_ states: [TabState]) {
        for state in states { add(state) }
    }

    public mutating func add(_ state: TabState) {
        switch state {
        case .attention: attention += 1
        case .failed: failed += 1
        case .done: done += 1
        case .working: working += 1
        case .idle: break
        }
    }

    /// The terminals and herdr's agents that need you: the ones Go to Next Agent Needing You goes to.
    public var needingYou: Int { attention + failed + done }

    /// One mark, and how many terminals show it.
    public struct Mark: Equatable, Sendable {
        public let state: TabState
        public let count: Int
        /// The server mark of a lost connection, drawn as the tab bar draws it, for terminals whose `state` is idle as
        /// far as they know.
        public let disconnected: Bool

        public init(state: TabState, count: Int, disconnected: Bool = false) {
            self.state = state
            self.count = count
            self.disconnected = disconnected
        }
    }

    /// The marks to show, in the order Go to Next Agent Needing You goes through them, then working, then a lost
    /// connection; none for a mark no terminal has. `working` false leaves working out, as the tab bar does with View ›
    /// Agent Spinner set to Off.
    public func shown(working showsWorking: Bool = true) -> [Mark] {
        let all: [Mark] = [
            Mark(state: .attention, count: attention), Mark(state: .failed, count: failed), Mark(state: .done, count: done),
            Mark(state: .working, count: showsWorking ? working : 0),
            Mark(state: .idle, count: disconnected, disconnected: true),
        ]
        return all.filter { (mark: Mark) -> Bool in mark.count > 0 }
    }

    /// What VoiceOver hears of them: "1 needs you, 2 done, 1 disconnected"; nil with none shown.
    public func spoken(working showsWorking: Bool = true) -> String? {
        let parts: [String] = shown(working: showsWorking).map { (mark: Mark) -> String in
            "\(mark.count) " + Self.words(mark)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func words(_ mark: Mark) -> String {
        if mark.disconnected { return "disconnected" }
        switch mark.state {
        case .attention: return mark.count == 1 ? "needs you" : "need you"
        case .failed: return "failed"
        case .done: return "done"
        case .working: return "working"
        case .idle: return "idle"
        }
    }
}

/// Every terminal window, in the order they opened, with what each one's terminals show.
public struct WindowIndex: Sendable {
    /// One terminal: a tab, or a pane of a split tab.
    public struct Tab: Equatable, Sendable {
        public let id: UUID
        /// Its title as its tab shows it, an agent's spinner frame left out.
        public let title: String
        public let state: TabState
        /// On a server, and its connection dropped: its status was cleared with it, so an idle `state` says nothing.
        public let disconnected: Bool
        /// It shows herdr and follows its agents one by one, each in its window's `agents`: they wait and count there, and
        /// its own mark, which stands for them, does neither.
        public let showsAgents: Bool

        public init(id: UUID, title: String, state: TabState, disconnected: Bool = false, showsAgents: Bool = false) {
            self.id = id
            self.title = title
            self.state = state
            self.disconnected = disconnected
            self.showsAgents = showsAgents
        }
    }

    /// One of herdr's agents a window leads to: one a herdr tab of it shows, one on a machine saved in a herdr run in a tab
    /// of it, or one on a connected server with no herdr tab, whose tabs are in this window (a herdr tab there opens in
    /// it). Each waits on its own, as a terminal does, and is gone to as Window › Go to Agent… goes to it.
    public struct Agent: Equatable, Sendable {
        /// One per agent however many tabs show it (AgentQueue.Item's key).
        public let key: String
        /// Where going to it leads (AgentQueue.Item's target).
        public let target: AgentQueue.Item.Target
        /// The tab it is reached from: the one that shows its herdr, or a tab on its server.
        public let tab: UUID
        public let state: TabState
        /// herdr's view in that tab shows it, as herdr said: in front when the tab is.
        public let inView: Bool

        public init(key: String, target: AgentQueue.Item.Target, tab: UUID, state: TabState, inView: Bool = false) {
            self.key = key
            self.target = target
            self.tab = tab
            self.state = state
            self.inView = inView
        }
    }

    public struct Window: Equatable, Sendable {
        /// The same while the window is open.
        public let id: Int
        public let kind: WindowKind
        /// The project's folder; nil for a plain or server window.
        public let project: String?
        /// The window's name, first in its title: the project's ("xCloud ▸ 7027-sso"), else its tab's folder
        /// ("~/Downloads") or server ("web-1").
        public let name: String
        /// The whole title, as the Window menu, Mission Control and VoiceOver read it (WindowTitle).
        public let title: String
        /// When it last had the keyboard; `Date.distantPast` for one that never had.
        public let lastKey: Date
        /// Its terminals, tab by tab and pane by pane, in the tab bar's order.
        public let tabs: [Tab]
        /// For a server window, what ssh connects to there: "deploy@203.0.113.5".
        public let destination: String?
        /// herdr's agents it leads to, in its tabs' order, then those of servers with no herdr tab.
        public let agents: [Agent]

        public init(id: Int, kind: WindowKind, project: String?, name: String, title: String, lastKey: Date,
                    tabs: [Tab], destination: String? = nil, agents: [Agent] = []) {
            self.id = id
            self.kind = kind
            self.project = project
            self.name = name
            self.title = title
            self.lastKey = lastKey
            self.tabs = tabs
            self.destination = destination
            self.agents = agents
        }

        /// Its terminals' marks, with herdr's agents in place of the tabs that show them, each agent once; an idle
        /// terminal whose connection dropped shows that instead.
        public var marks: AgentMarks {
            let own: [Tab] = tabs.filter { (tab: Tab) -> Bool in !tab.showsAgents }
            var seen: Set<String> = []
            let agentStates: [TabState] = agents.compactMap { (agent: Agent) -> TabState? in
                seen.insert(agent.key).inserted ? agent.state : nil
            }
            var marks = AgentMarks(own.map { (tab: Tab) -> TabState in tab.state } + agentStates)
            let lost: [Tab] = own.filter { (tab: Tab) -> Bool in tab.disconnected && tab.state == .idle }
            marks.disconnected = lost.count
            return marks
        }

        /// What the index knows its entries by: each terminal's id, and each of herdr's agents' key.
        var keys: [String] {
            tabs.map { (tab: Tab) -> String in tab.id.uuidString } + agents.map { (agent: Agent) -> String in agent.key }
        }
    }

    /// A terminal or one of herdr's agents that needs you, and the window it is in.
    public struct Waiting: Equatable, Sendable {
        public let window: Int
        /// The terminal: the one that needs you, or the tab one of herdr's agents is reached from.
        public let tab: UUID
        public let state: TabState
        /// One of herdr's agents: where going to it leads (AgentQueue.Item's target); nil for the terminal itself.
        public let agent: AgentQueue.Item.Target?
        /// One of herdr's agents that herdr's view in its tab shows.
        let inView: Bool
        let key: String
        /// When the index first saw it needing you this way, as a count: the lower, the longer it has waited. No two are
        /// the same, so the order is total.
        let since: Int
    }

    /// The windows, in the order the index first heard of them.
    public private(set) var windows: [Window] = []
    /// When each terminal and agent that needs you was first seen needing you, and how, by its key (Window.keys): one that
    /// goes from done to a decision has waited since the decision.
    private var noticed: [String: Noticed] = [:]
    private var count = 0
    /// The terminal Go to Next Agent Needing You went to last.
    private var last: Waiting?

    private struct Noticed: Sendable {
        let state: TabState
        let at: Int
    }

    public init() {}

    /// A window's terminals as they show now, from its refresh; one not heard of yet comes after the others. True when
    /// the window's entry changed, for a list that shows it to follow.
    @discardableResult
    public mutating func update(_ window: Window) -> Bool {
        var gone: [String] = []
        let changed: Bool
        if let index = windows.firstIndex(where: { (known: Window) -> Bool in known.id == window.id }) {
            changed = windows[index] != window
            let kept: Set<String> = Set(window.keys)
            gone = windows[index].keys.filter { (key: String) -> Bool in !kept.contains(key) }
            windows[index] = window
        } else {
            windows.append(window)
            changed = true
        }
        for tab in window.tabs {
            notice(tab.id.uuidString, tab.showsAgents ? .idle : tab.state)
        }
        for agent in window.agents { notice(agent.key, agent.state) }
        forget(gone)
        return changed
    }

    /// A terminal or agent as it shows now: needing you, it waits from when it began to need you this way.
    private mutating func notice(_ key: String, _ state: TabState) {
        guard Self.needsYou(state) else {
            noticed[key] = nil
            return
        }
        if noticed[key]?.state == state { return }
        count += 1
        noticed[key] = Noticed(state: state, at: count)
    }

    /// A window closed: it, its terminals and its agents leave the index.
    public mutating func remove(window id: Int) {
        guard let index = windows.firstIndex(where: { (known: Window) -> Bool in known.id == id }) else { return }
        let keys: [String] = windows[index].keys
        windows.remove(at: index)
        forget(keys)
    }

    /// Terminals and agents gone from a window: forgotten, unless another window has them now (a tab moved there, or
    /// another tab of the same herdr session shows the agent).
    private mutating func forget(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        let held: Set<String> = Set(windows.flatMap { (window: Window) -> [String] in window.keys })
        for key in keys where !held.contains(key) { noticed[key] = nil }
    }

    public func window(_ id: Int) -> Window? {
        windows.first { (window: Window) -> Bool in window.id == id }
    }

    /// Every terminal and agent of herdr's that needs you, each once: decisions (and bells) first, then failures, then
    /// finished agents and commands; in each, the one waiting longest first. A tab that shows herdr's agents waits through
    /// them, not itself.
    public var waiting: [Waiting] {
        var found: [Waiting] = []
        var listed: Set<String> = []
        for window in windows {
            for tab in window.tabs where !tab.showsAgents && Self.needsYou(tab.state) {
                let key: String = tab.id.uuidString
                guard listed.insert(key).inserted else { continue }
                found.append(Waiting(window: window.id, tab: tab.id, state: tab.state, agent: nil, inView: false, key: key,
                                     since: noticed[key]?.at ?? Int.max))
            }
            for agent in window.agents where Self.needsYou(agent.state) {
                guard listed.insert(agent.key).inserted else { continue }
                found.append(Waiting(window: window.id, tab: agent.tab, state: agent.state, agent: agent.target,
                                     inView: agent.inView, key: agent.key, since: noticed[agent.key]?.at ?? Int.max))
            }
        }
        return found.sorted(by: Self.goesBefore)
    }

    /// Where Go to Next Agent Needing You goes, `front` being the terminal in front now (the key window's): the one after
    /// it while it needs you, so pressing again goes on; after the one gone to last when that is still in front, though it
    /// needs you no more (a finished agent, seen now); after the agent of herdr's that its view shows, in a herdr tab in
    /// front; from anywhere else, the one waiting longest. Round to the first after the last. Nil when nothing needs you.
    public mutating func next(from front: UUID?) -> Waiting? {
        let list: [Waiting] = waiting
        guard !list.isEmpty else { return nil }
        var chosen: Waiting = list[0]
        if let front, let index = list.firstIndex(where: { (waiting: Waiting) -> Bool in waiting.tab == front && waiting.agent == nil }) {
            chosen = list[(index + 1) % list.count]
        } else if let last, front == last.tab {
            let after: Waiting? = list.first { (waiting: Waiting) -> Bool in Self.goesBefore(last, waiting) }
            chosen = after ?? list[0]
        } else if let front, let index = list.firstIndex(where: { (waiting: Waiting) -> Bool in waiting.tab == front && waiting.inView }) {
            chosen = list[(index + 1) % list.count]
        }
        last = chosen
        return chosen
    }

    /// The windows with terminals or herdr's agents that need you, the one with what Go to Next Agent Needing You goes to
    /// first at the top: what the Dock menu lists.
    public var windowsWaiting: [Window] {
        var order: [Int] = []
        for waiting in waiting where !order.contains(waiting.window) { order.append(waiting.window) }
        return order.compactMap { (id: Int) -> Window? in window(id) }
    }

    /// The terminal or agent in window `id` that needs you most, in the order Go to Next Agent Needing You goes: where the
    /// Dock menu's item for the window goes, and the mark it shows. Nil when nothing in it needs you.
    public func firstWaiting(in id: Int) -> Waiting? {
        waiting.first { (waiting: Waiting) -> Bool in waiting.window == id }
    }

    /// What the notice says when Go to Next Agent Needing You finds nothing: no beep, as nothing went wrong.
    public static let nothingWaiting = "No agent needs you right now"

    static func needsYou(_ state: TabState) -> Bool {
        state == .attention || state == .failed || state == .done
    }

    private static func rank(_ state: TabState) -> Int {
        switch state {
        case .attention: return 0
        case .failed: return 1
        default: return 2
        }
    }

    private static func goesBefore(_ a: Waiting, _ b: Waiting) -> Bool {
        let first: Int = rank(a.state), second: Int = rank(b.state)
        return first != second ? first < second : a.since < b.since
    }
}

/// A terminal window's title, as the Window menu, Mission Control and VoiceOver read it: its name first, so each window
/// leads with its project, then what is in front in it. "xCloud ▸ 7027-sso — claude", "~/Downloads — vim", "web-1 — app".
public enum WindowTitle {
    /// The name of a window with no project, from its tab's folder: "~/Downloads", "~" for the home folder, any other
    /// folder as it is.
    public static func name(ofFolder folder: String, home: String) -> String {
        var home: String = home
        while home.count > 1 && home.hasSuffix("/") { home.removeLast() }
        return RecentProjects.abbreviate(folder, home: home)
    }

    /// - `name`: the window's name (its project's title, or `name(ofFolder:home:)`, or the server's name).
    /// - `front`: what is in front: the file the editor has the keyboard in, else the tab's title.
    /// - `folderName`: the name of the window's own folder (its project's, or its tab's): the title a tab at its prompt
    ///   there has, left out as the name says it.
    /// - `host`: the server the tab in front is on. Named once: as the name, "on web-1" after the tab, or not again when
    ///   the tab's title starts with it ("web-1: app").
    public static func make(name: String, front: String?, folderName: String? = nil, host: String? = nil) -> String {
        var shown: String? = front.flatMap { (text: String) -> String? in text.isEmpty ? nil : text }
        let prefix: String? = host.map { (host: String) -> String in host + ": " }
        let saysHost: Bool = prefix.map { (prefix: String) -> Bool in shown?.hasPrefix(prefix) ?? false } ?? false
        // A server's window: its name says the host, so a tab's "web-1: app" is "app" after it.
        let serverWindow: Bool = host != nil && host == name
        if serverWindow, saysHost, let text = shown, let prefix { shown = String(text.dropFirst(prefix.count)) }
        var parts: [String] = [name]
        if let text = shown, text != name, text != folderName { parts.append(text) }
        if let host, !serverWindow, !saysHost { parts.append("on " + host) }
        return parts.joined(separator: " — ")
    }
}
