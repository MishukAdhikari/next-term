import Foundation

/// Connect a Tracker's catalog: for each tracker, its official MCP server and, per agent, the line that agent's own
/// docs or the tracker's own page print to add it. Lines are copied from those pages as they are, with one change:
/// Claude Code's get `--scope user`, so the tracker works in every project. A pair with no such line is held, with its
/// reason and the page that would change that; a line is never guessed. Next Term types a line into a new tab and
/// never runs it, so the agent's own command writes its own config after the user presses Return.
public enum TrackerLines {
    /// What one agent gets for one tracker.
    public enum Cell: Equatable, Sendable {
        /// The agent's add line, and the page it was copied from.
        case line(String, source: URL)
        /// No line: why, and the page that would give one.
        case held(String, page: URL)
        /// The agent adds servers interactively only: a link to its own page about it.
        case showHow(URL)

        /// Why the pair is held, or nil.
        public var reason: String? {
            if case .held(let why, _) = self { return why }
            return nil
        }

        /// The page a click on the row opens.
        public var page: URL {
            switch self {
            case .line(_, let source): return source
            case .held(_, let page): return page
            case .showHow(let page): return page
            }
        }
    }

    public struct Tracker: Sendable, Equatable {
        public let name: String
        /// Its official remote MCP server, or nil when it has none an agent can add.
        public let url: String?
        /// The tracker's own page about its MCP server.
        public let page: URL
        /// The domains its own pages are on.
        public let domains: [String]
        let lines: [AgentKind: Cell]
        let notes: [AgentKind: String]

        /// The agent's cell: its line, or why there is none.
        public func cell(for agent: AgentKind) -> Cell {
            if agent == .opencode { return .showHow(TrackerLines.opencodePage) }
            return lines[agent] ?? .held(TrackerLines.noLine(name), page: page)
        }

        /// A sentence under the agent's line, or nil.
        public func note(for agent: AgentKind) -> String? { notes[agent] }

        /// The sentences under the agent's line: its sign-in step, then the tracker's note.
        public func notes(for agent: AgentKind, line: String) -> [String] {
            let parts: [String?] = [TrackerLines.signIn(agent, line: line), note(for: agent)]
            return parts.compactMap { $0 }
        }

        /// At least one agent has a line for it.
        public var hasLine: Bool {
            TrackerLines.agents.contains { (agent: AgentKind) -> Bool in
                if case .line = cell(for: agent) { return true }
                return false
            }
        }
    }

    /// The agents the sheet lists, in its order. The others have no tracker line on any page.
    public static let agents: [AgentKind] = [.claude, .codex, .gemini, .opencode]

    /// The program an agent's line starts with.
    public static func program(_ agent: AgentKind) -> String? {
        switch agent {
        case .claude: return "claude"
        case .codex: return "codex"
        case .gemini: return "gemini"
        case .opencode: return "opencode"
        default: return nil
        }
    }

    /// The domains of the agent's own docs.
    public static func agentDomains(_ agent: AgentKind) -> [String] {
        switch agent {
        case .claude: return ["code.claude.com"]
        case .codex: return ["learn.chatgpt.com"]
        case .gemini: return ["github.com"]
        case .opencode: return ["github.com"]
        default: return []
        }
    }

    /// opencode's page about MCP servers: `opencode mcp add` asks its questions one by one, so there is no line.
    public static let opencodePage = URL(string: "https://github.com/anomalyco/opencode/blob/dev/packages/web/src/content/docs/mcp-servers.mdx")!

    static func noLine(_ name: String) -> String { "No line from \(name)\u{2019}s own page yet." }

    /// What the agent asks next, once the line has run: signing in is the agent's. A Codex line that reads a token from
    /// the environment has no sign-in step, since `codex mcp login` is the OAuth sign-in.
    public static func signIn(_ agent: AgentKind, line: String) -> String? {
        switch agent {
        case .claude: return "Then, in Claude Code: /mcp"
        case .codex:
            let words: [String] = line.split(separator: " ").map(String.init)
            guard words.count > 3, !words.contains("--bearer-token-env-var") else { return nil }
            return "Then: codex mcp login \(words[3])"
        default: return nil
        }
    }

    /// The trackers not listed yet, one row each: its name and why.
    public static var heldSummary: [String] {
        held.map { (tracker: Tracker) -> String in
            let why: String = tracker.cell(for: .claude).reason ?? ""
            return "\(tracker.name): \(why)"
        }
    }

    /// The trackers the sheet offers: those with a line, Linear first, then by name.
    public static var shown: [Tracker] {
        let with: [Tracker] = catalog.filter(\.hasLine)
        let first: [Tracker] = with.filter { $0.name == "Linear" }
        let rest: [Tracker] = with.filter { $0.name != "Linear" }.sorted { (one: Tracker, two: Tracker) -> Bool in
            one.name.localizedCaseInsensitiveCompare(two.name) == .orderedAscending
        }
        return first + rest
    }

    /// The trackers with no line for any agent yet, named under the list with why.
    public static var held: [Tracker] { catalog.filter { !$0.hasLine } }
}
