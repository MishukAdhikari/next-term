import Foundation

/// Go to Anything (⌘K outside a terminal, plan 034): one list to jump to any terminal tab or project by name. This
/// window's tabs come first, then every other window's, in the order the windows were last used, then projects used
/// before and closed now. Clear Terminal leads it when the window has a terminal, so a ⌘K meant to clear, pressed with
/// the editor in front, is ⌘K and Return still.
public enum GoToAnything {
    /// A terminal tab as the list shows it.
    public struct Tab: Equatable, Sendable {
        public let id: String
        public let title: String
        /// Its folder, as the user reads it (~/Code/app).
        public let folder: String
        /// What runs in front (claude, npm run dev), or nil at a prompt.
        public let program: String?
        /// The tab's mark: working, done, attention, failed, or nil.
        public let state: String?

        public init(id: String, title: String, folder: String, program: String?, state: String?) {
            self.id = id
            self.title = title
            self.folder = folder
            self.program = program
            self.state = state
        }
    }

    /// A window and its tabs.
    public struct Window: Equatable, Sendable {
        public let id: Int
        /// Its project's name, or the folder of a window with none.
        public let name: String
        public let tabs: [Tab]

        public init(id: Int, name: String, tabs: [Tab]) {
            self.id = id
            self.name = name
            self.tabs = tabs
        }
    }

    /// A project used before and closed now.
    public struct Project: Equatable, Sendable {
        public let path: String
        public let name: String

        public init(path: String, name: String) {
            self.path = path
            self.name = name
        }
    }

    public struct Item: Equatable, Sendable {
        public enum Target: Equatable, Sendable {
            case clearTerminal
            case tab(window: Int, tab: String)
            case project(String)
        }

        /// What the row is, for its symbol: a command, a shell, an agent, or a project.
        public enum Kind: Equatable, Sendable { case command, shell, agent, project }

        public let target: Target
        public let title: String
        /// The dim words after it: the window and folder, what runs, or the project's folder.
        public let detail: String
        public let state: String?
        /// What a search matches: the name last, which the matcher favours as a path's file name.
        public let searched: String
        public var kind: Kind = .shell
    }

    /// Programs that are coding agents: their tabs show an agent's symbol.
    public static let agents: Set<String> = ["claude", "codex", "cmd", "command-code", "gemini", "qwen", "opencode", "cursor-agent", "copilot", "kimi", "amp", "aider", "goose"]

    /// A path as the user reads it: ~ for the home folder.
    public static func shown(_ path: String, home: String = NSHomeDirectory()) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    public static let clearTitle = "Clear Terminal"

    /// Everything, in its order. `current`: the window ⌘K came from (its tabs first), or nil; `others`: the other
    /// windows, last used first; `closed`: projects used before, newest first (any that is open is left out).
    public static func items(current: Window?, others: [Window], closed: [Project], clearsTerminal: Bool,
                             home: String = NSHomeDirectory()) -> [Item] {
        var items: [Item] = []
        if clearsTerminal, current?.tabs.isEmpty == false {
            var clear = Item(target: .clearTerminal, title: clearTitle, detail: "The terminal tab in front",
                             state: nil, searched: "clear terminal/" + clearTitle)
            clear.kind = .command
            items.append(clear)
        }
        for window in (current.map { [$0] } ?? []) + others {
            var made: [Item] = []
            for tab in window.tabs {
                var parts: [String] = [window.name]
                if let program = tab.program, !program.isEmpty, program != tab.title { parts.append(program) }
                if tab.folder != window.name { parts.append(tab.folder) }
                let searched: String = ([window.name, tab.folder, tab.program ?? ""].joined(separator: " ")) + "/" + tab.title
                var item = Item(target: .tab(window: window.id, tab: tab.id), title: tab.title,
                                detail: parts.joined(separator: " \u{00B7} "), state: tab.state, searched: searched)
                let program = tab.program.map { ($0.split(separator: " ").first.map(String.init) ?? $0) } ?? ""
                item.kind = agents.contains((program as NSString).lastPathComponent) ? .agent : .shell
                made.append(item)
            }
            // Tabs that would read the same (three xCloud shells in one window) say which tab they are.
            let same = made
            for (index, item) in same.enumerated() where same.filter({ $0.title == item.title && $0.detail == item.detail }).count > 1 {
                var numbered = Item(target: item.target, title: item.title, detail: item.detail + " \u{00B7} tab \(index + 1)",
                                    state: item.state, searched: item.searched)
                numbered.kind = item.kind
                made[index] = numbered
            }
            items += made
        }
        let openNames: Set<String> = Set(([current].compactMap { $0 } + others).map(\.name))
        for project in closed where !openNames.contains(project.name) {
            var item = Item(target: .project(project.path), title: project.name, detail: "Not open \u{00B7} " + shown(project.path, home: home),
                            state: nil, searched: project.path)
            item.kind = .project
            items.append(item)
        }
        return items
    }

    /// The items a search keeps, best first: the letters typed, in order (Go to File's matcher), with the name counting
    /// most. An empty search keeps them all in their order.
    public static func filter(_ items: [Item], query: String) -> [Item] {
        let wanted: String = query.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return items }
        let index = FuzzyIndex(paths: items.map(\.searched))
        guard let matches = index.search(wanted) else { return [] }
        return index.sorted(matches, limit: 200).map { items[$0.index] }
    }

    /// The row a fresh list selects: the first, Clear Terminal when the window has a terminal, so a ⌘K meant to clear,
    /// pressed with the editor in front, is ⌘K and Return still; else the first tab.
    public static func initialSelection(_ items: [Item]) -> Int? {
        items.isEmpty ? nil : 0
    }
}
