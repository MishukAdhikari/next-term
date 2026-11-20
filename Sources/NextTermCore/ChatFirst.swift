import Foundation

/// Settings › Agents › each agent's "Opens as" (plan 047 D5, the owner's per-agent choice beside Auto-update): whether a
/// new session of that agent shows its chat first or its terminal. Terminal unless the user picks Chat, in Settings or
/// by asking an agent (settings_set agents_open_as_chat). New sessions only: a tab open already, or brought back at
/// launch, keeps its view.
public enum ChatFirst {
    /// Each agent's choice, by its catalog id (`AgentCLIs.Agent.id`): true for chat.
    public static let settingKey = "agentsOpenAsChat"

    /// The agents whose sessions can show as a chat: Command Code's own screen, and every agent a session runs
    /// (Claude Code, Codex, and the ACP agents).
    public static var agentIDs: Set<String> { Set(ACPAgent.known.map(\.id)).union(["commandcode"]) }

    /// The catalog id of a live chat's agent (plan 041).
    public static func id(of agent: LiveChat.Agent) -> String {
        switch agent {
        case .claude: return "claude"
        case .codex: return "codex"
        case .commandCode: return "commandcode"
        }
    }

    /// An agent's name, as Settings › Agents shows it.
    public static func name(of id: String) -> String {
        if id == "commandcode" { return "Command Code" }
        return ACPAgent.known.first { $0.id == id }?.name ?? id
    }

    /// Whether a new session of agent `id` opens as its chat.
    public static func opensAsChat(_ id: String, in defaults: UserDefaults = .standard) -> Bool {
        let choices = defaults.dictionary(forKey: settingKey) as? [String: Bool] ?? [:]
        return choices[id] ?? false
    }

    /// The agents whose new sessions open as chat, sorted.
    public static func chatAgents(in defaults: UserDefaults = .standard) -> [String] {
        agentIDs.filter { opensAsChat($0, in: defaults) }.sorted()
    }

    public static func set(_ id: String, asChat: Bool, in defaults: UserDefaults = .standard) {
        var choices = defaults.dictionary(forKey: settingKey) as? [String: Bool] ?? [:]
        choices[id] = asChat
        defaults.set(choices, forKey: settingKey)
    }
}

