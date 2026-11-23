import Foundation

/// What Next Term tells the user once it has added its MCP server to their agents (MCPRegistrar): the agents it is in,
/// and the one file of each that holds its entry. It is told once, the first time a pass adds Next Term to an agent, and
/// again only when a pass adds it to an agent not named before; an entry merely put back (an agent that rewrote its file)
/// or pointed at another copy of the app tells nothing new.
public struct MCPRegistrationNotice: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        /// "Claude Code", "the Claude app".
        public let agent: String
        /// The file holding Next Term's entry, with the home folder as ~.
        public let file: String
    }

    /// Every agent Next Term is in now, in the order the summary names them.
    public let rows: [Row]
    /// The agents' ids (MCPRegistrar.Target.id, and "claude" for Claude Code): what is remembered once it is shown.
    public let ids: Set<String>

    /// Where the ids of the agents already named are kept.
    public static let shownKey = "mcpRegistrationNoticeShown"

    /// The agents' names, each once (the Claude app may have two files).
    public var agents: [String] {
        var seen = Set<String>()
        return rows.map(\.agent).filter { seen.insert($0).inserted }
    }

    /// "Claude Code, Codex and Command Code", the same in every locale, as the rest of the words are English.
    public var agentList: String {
        guard agents.count > 1, let last = agents.last else { return agents.first ?? "" }
        return agents.dropLast().joined(separator: ", ") + " and " + last
    }

    /// "Next Term added its tools to Claude Code, Codex and Command Code."
    public var headline: String { "Next Term added its tools to \(agentList)." }

    /// The headline's words with what they mean, as one sentence: "Next Term added its tools to Claude Code and Codex, so
    /// you can ask them to set it up or run tabs. One entry in each; nothing else changed."
    public var message: String { "Next Term added its tools to \(agentList), so you " + rest }

    /// What the headline means, on its own (under it, in Details…): "You can ask them to set it up or run tabs. One entry in
    /// each; nothing else changed."
    public var meaning: String { "You " + rest }

    private var rest: String {
        agents.count == 1 ? "can ask it to set it up or run tabs. One entry; nothing else changed."
            : "can ask them to set it up or run tabs. One entry in each; nothing else changed."
    }

    /// Each agent on a line of its own, with its file: "Codex: ~/.codex/config.toml".
    public var fileLines: [String] { rows.map { "\($0.agent): \($0.file)" } }

    /// The notice a pass's `statuses` call for (by target id, and "claude" for Claude Code), or nil: nothing was added
    /// this pass to an agent not in `shown`.
    public static func due(_ statuses: [String: MCPRegistrar.Status], shown: Set<String>,
                           home: String = NSHomeDirectory()) -> MCPRegistrationNotice? {
        let added = statuses.filter { $0.value == .registered }.keys
        guard added.contains(where: { !shown.contains($0) }) else { return nil }
        var named: [String: (agent: String, file: String)] = [
            "claude": ("Claude Code", (home as NSString).appendingPathComponent(".claude.json")),
        ]
        for target in MCPRegistrar.targets(home: home) { named[target.id] = (target.name, target.file) }
        let present = statuses.filter { $0.value == .registered || $0.value == .alreadyRegistered }.keys
        let rows = present.compactMap { id in named[id].map { (id, $0) } }
            .sorted { (MCPRegistrar.sortKey($0.1.agent), $0.0) < (MCPRegistrar.sortKey($1.1.agent), $1.0) }
        guard !rows.isEmpty else { return nil }
        return MCPRegistrationNotice(rows: rows.map { Row(agent: $0.1.agent, file: RecentProjects.abbreviate($0.1.file, home: home)) },
                                     ids: Set(rows.map(\.0)))
    }

    /// The agents already named, as `defaults` keeps them.
    public static func shown(in defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: shownKey) ?? [])
    }

    /// Keeps this notice's agents with those named before.
    public func remember(in defaults: UserDefaults) {
        defaults.set(Self.shown(in: defaults).union(ids).sorted(), forKey: Self.shownKey)
    }
}

extension MCPRegistrar {
    /// The registrar's id for an agent run in a tab ("claude" for Claude Code, which registers through its own command
    /// line).
    public static func id(of agent: AgentKind) -> String {
        switch agent {
        case .claude: return "claude"
        case .commandCode: return "commandcode"
        case .codex, .gemini, .qwen, .opencode, .cursor, .copilot: return agent.rawValue
        }
    }

    /// When a pass added Next Term to each agent this launch (`now`, on the tabs' clock), after a pass's `statuses`: an
    /// agent added again keeps its first time, and one taken out is forgotten.
    public static func landed(_ previous: [String: TimeInterval], after statuses: [String: Status],
                              at now: TimeInterval) -> [String: TimeInterval] {
        var landed = previous
        for (id, status) in statuses {
            switch status {
            case .registered: landed[id] = landed[id] ?? now
            case .removed, .notInstalled, .nameTaken: landed[id] = nil
            case .alreadyRegistered, .skipped: break
            }
        }
        return landed
    }

    /// An agent that started (`since`, on the same clock) before Next Term was added to it this launch has none of its
    /// tools until it starts again: agents read their MCP servers only as they start.
    public static func needsRestart(_ agent: AgentKind, since: TimeInterval?, landed: [String: TimeInterval]) -> Bool {
        guard let since, let added = landed[id(of: agent)] else { return false }
        return since < added
    }

    /// The order agents are named in: by name, "the Claude app" under C.
    static func sortKey(_ name: String) -> String { (name.hasPrefix("the ") ? String(name.dropFirst(4)) : name).lowercased() }
}
