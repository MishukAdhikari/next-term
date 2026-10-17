import Foundation

// Every terminal window and its agents, in one place. Each window tells it what its tabs show as it refreshes them, from
// their own status (nothing is polled for it), and that it closed. Three things read it: Agents › Go to Next Agent Needing
// You, which goes through the terminals that wait for you, the Welcome window's switcher, which gives each window a row
// with its marks, and the Dock menu, which lists the windows waiting for you.

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

/// How many of a window's terminals, tab by tab and pane by pane, show each mark: what its row in the Welcome window and
/// its item in the Dock menu show of its agents.
public struct AgentMarks: Equatable, Sendable {
    /// A decision an agent waits on, or a bell: the amber mark.
    public var attention = 0
    public var failed = 0
    /// An agent that stopped, or a command that finished, not seen yet.
    public var done = 0
    public var working = 0

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

    /// The terminals that need you: the ones Go to Next Agent Needing You goes to.
    public var needingYou: Int { attention + failed + done }

    /// One mark, and how many terminals show it.
    public struct Mark: Equatable, Sendable {
        public let state: TabState
        public let count: Int

        public init(state: TabState, count: Int) {
            self.state = state
            self.count = count
        }
    }

    /// The marks to show, in the order Go to Next Agent Needing You goes through them, then working; none for a mark no
    /// terminal has. `working` false leaves working out, as the tab bar does with View › Agent Spinner set to Off.
    public func shown(working showsWorking: Bool = true) -> [Mark] {
        let all: [Mark] = [
            Mark(state: .attention, count: attention), Mark(state: .failed, count: failed), Mark(state: .done, count: done),
            Mark(state: .working, count: showsWorking ? working : 0),
        ]
        return all.filter { (mark: Mark) -> Bool in mark.count > 0 }
    }

    /// What VoiceOver hears of them: "1 needs you, 2 done"; nil with none shown.
    public func spoken(working showsWorking: Bool = true) -> String? {
        let parts: [String] = shown(working: showsWorking).map { (mark: Mark) -> String in
            "\(mark.count) " + Self.words(mark)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func words(_ mark: Mark) -> String {
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

        public init(id: UUID, title: String, state: TabState) {
            self.id = id
            self.title = title
            self.state = state
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
        /// The whole title, as the Window menu, ⌘` and Mission Control read it (WindowTitle).
        public let title: String
        /// When it last had the keyboard; `Date.distantPast` for one that never had.
        public let lastKey: Date
        /// Its terminals, tab by tab and pane by pane, in the tab bar's order.
        public let tabs: [Tab]
        /// For a server window, what ssh connects to there: "deploy@203.0.113.5".
        public let destination: String?

        public init(id: Int, kind: WindowKind, project: String?, name: String, title: String, lastKey: Date,
                    tabs: [Tab], destination: String? = nil) {
            self.id = id
            self.kind = kind
            self.project = project
            self.name = name
            self.title = title
            self.lastKey = lastKey
            self.tabs = tabs
            self.destination = destination
        }

        public var marks: AgentMarks {
            AgentMarks(tabs.map { (tab: Tab) -> TabState in tab.state })
        }
    }

    /// A terminal that needs you, and the window it is in.
    public struct Waiting: Equatable, Sendable {
        public let window: Int
        public let tab: UUID
        public let state: TabState
        /// When the index first saw it needing you this way, as a count: the lower, the longer it has waited. No two are
        /// the same, so the order is total.
        let since: Int
    }

    /// The windows, in the order the index first heard of them.
    public private(set) var windows: [Window] = []
    /// When each terminal that needs you was first seen needing you, and how: one that goes from done to a decision has
    /// waited since the decision.
    private var noticed: [UUID: Noticed] = [:]
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
        var gone: [UUID] = []
        let changed: Bool
        if let index = windows.firstIndex(where: { (known: Window) -> Bool in known.id == window.id }) {
            changed = windows[index] != window
            let kept: Set<UUID> = Set(window.tabs.map(\.id))
            gone = windows[index].tabs.map(\.id).filter { (id: UUID) -> Bool in !kept.contains(id) }
            windows[index] = window
        } else {
            windows.append(window)
            changed = true
        }
        for tab in window.tabs {
            guard Self.needsYou(tab.state) else {
                noticed[tab.id] = nil
                continue
            }
            if noticed[tab.id]?.state == tab.state { continue }
            count += 1
            noticed[tab.id] = Noticed(state: tab.state, at: count)
        }
        forget(gone)
        return changed
    }

    /// A window closed: it and its terminals leave the index.
    public mutating func remove(window id: Int) {
        guard let index = windows.firstIndex(where: { (known: Window) -> Bool in known.id == id }) else { return }
        let tabs: [UUID] = windows[index].tabs.map(\.id)
        windows.remove(at: index)
        forget(tabs)
    }

    /// Terminals gone from a window: forgotten, unless another window has them now (a tab moved there).
    private mutating func forget(_ tabs: [UUID]) {
        guard !tabs.isEmpty else { return }
        let held: Set<UUID> = Set(windows.flatMap { (window: Window) -> [UUID] in window.tabs.map(\.id) })
        for id in tabs where !held.contains(id) { noticed[id] = nil }
    }

    public func window(_ id: Int) -> Window? {
        windows.first { (window: Window) -> Bool in window.id == id }
    }

    /// Every terminal that needs you: decisions (and bells) first, then failures, then finished agents and commands; in
    /// each, the one waiting longest first.
    public var waiting: [Waiting] {
        var found: [Waiting] = []
        for window in windows {
            for tab in window.tabs where Self.needsYou(tab.state) {
                let since: Int = noticed[tab.id]?.at ?? Int.max
                found.append(Waiting(window: window.id, tab: tab.id, state: tab.state, since: since))
            }
        }
        return found.sorted(by: Self.goesBefore)
    }

    /// Where Go to Next Agent Needing You goes, `front` being the terminal in front now (the key window's): the one after
    /// it while it needs you, so pressing again goes on; after the one gone to last when that is still in front, though it
    /// needs you no more (a finished agent, seen now); from anywhere else, the one waiting longest. Round to the first after
    /// the last. Nil when nothing needs you.
    public mutating func next(from front: UUID?) -> Waiting? {
        let list: [Waiting] = waiting
        guard !list.isEmpty else { return nil }
        var chosen: Waiting = list[0]
        if let front, let index = list.firstIndex(where: { (waiting: Waiting) -> Bool in waiting.tab == front }) {
            chosen = list[(index + 1) % list.count]
        } else if let last, front == last.tab {
            let after: Waiting? = list.first { (waiting: Waiting) -> Bool in Self.goesBefore(last, waiting) }
            chosen = after ?? list[0]
        }
        last = chosen
        return chosen
    }

    /// The windows with terminals that need you, the one with the terminal Go to Next Agent Needing You goes to first at
    /// the top: what the Dock menu lists.
    public var windowsWaiting: [Window] {
        var order: [Int] = []
        for waiting in waiting where !order.contains(waiting.window) { order.append(waiting.window) }
        return order.compactMap { (id: Int) -> Window? in window(id) }
    }

    /// The terminal in window `id` that needs you most, in the order Go to Next Agent Needing You goes: where the Dock
    /// menu's item for the window goes, and the mark it shows. Nil when nothing in it needs you.
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

/// A terminal window's title, as the Window menu, ⌘` and Mission Control read it: its name first, so each window leads
/// with its project, then what is in front in it. "xCloud ▸ 7027-sso — claude", "~/Downloads — vim", "web-1 — app".
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
