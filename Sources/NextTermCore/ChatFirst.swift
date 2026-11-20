import Foundation

/// Settings › Agents › each agent's "Opens as" (plan 047 D5, the owner's per-agent choice beside Auto-update): whether a
/// new session of that agent shows its chat first or its terminal. New sessions only: a tab open already, or brought
/// back at launch, keeps its view. Chat for a new install, Terminal for one used before (decided once at the first
/// launch with this code, as single clicks in the sidebar are), so updating changes nothing.
public enum ChatFirst {
    /// Each agent's choice, by its catalog id (`AgentCLIs.Agent.id`): true for chat.
    public static let settingKey = "agentsOpenAsChat"
    /// The choice of an agent that has none of its own: settled at the first launch.
    public static let defaultKey = "agentsOpenAsChatDefault"

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

    /// Whether a new session of agent `id` opens as its chat.
    public static func opensAsChat(_ id: String, in defaults: UserDefaults = .standard) -> Bool {
        let choices = defaults.dictionary(forKey: settingKey) as? [String: Bool] ?? [:]
        return choices[id] ?? defaults.bool(forKey: defaultKey)
    }

    public static func set(_ id: String, asChat: Bool, in defaults: UserDefaults = .standard) {
        var choices = defaults.dictionary(forKey: settingKey) as? [String: Bool] ?? [:]
        choices[id] = asChat
        defaults.set(choices, forKey: settingKey)
    }

    /// Stores the default for a new install (chat) or one used before (terminal), once; nil when one is stored already.
    /// Runs before the launch writes any of `SidebarClick.usedInstallKeys`.
    @discardableResult
    public static func settleDefault(in defaults: UserDefaults) -> Bool? {
        guard defaults.object(forKey: defaultKey) == nil else { return nil }
        let usedBefore = SidebarClick.usedInstallKeys.contains { defaults.object(forKey: $0) != nil }
        defaults.set(!usedBefore, forKey: defaultKey)
        return !usedBefore
    }
}
