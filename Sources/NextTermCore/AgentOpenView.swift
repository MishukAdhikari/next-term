import Foundation

/// Settings' "Open Claude Code in" and "Open Codex in" (plan 037 R18, from plan 036): the kind of tab a start Next Term
/// makes itself opens, Terminal unless the user chose Chat. It applies to `new_tab` with the agent's bare program, the
/// Welcome window's set-up card and the sidebar's and Agents menu's Resume, never to a line the user types, a restore, or
/// a fork.
public enum AgentOpenView {
    /// The defaults key for `agent`: `agentOpensIn.claude`, `agentOpensIn.codex`.
    public static func key(_ agent: ConversationHandoff.Agent) -> String { "agentOpensIn." + agent.rawValue }

    /// The kind `agent` opens in. Nothing set, or a value this build doesn't know, reads as the terminal.
    public static func opensIn(_ agent: ConversationHandoff.Agent, defaults: UserDefaults) -> ConversationHandoff.Kind {
        defaults.string(forKey: key(agent)).flatMap(ConversationHandoff.Kind.init(rawValue:)) ?? .terminal
    }

    public static func set(_ kind: ConversationHandoff.Kind, for agent: ConversationHandoff.Agent, defaults: UserDefaults) {
        defaults.set(kind.rawValue, forKey: key(agent))
    }

    /// The chat a new tab opens when the user chose Chat for the agent `command` names, with `prompt` as its first
    /// prompt. Only the bare program word (`claude`, `codex`) turns into a chat: options such as `--model` have no chat
    /// form, so any other command stays as given, in a terminal tab (nil).
    public static func newTabStart(command: String, prompt: String?, folder: String?, defaults: UserDefaults) -> ChatStart? {
        let word = command.trimmingCharacters(in: .whitespaces)
        guard let agent = ConversationHandoff.Agent(program: word), opensIn(agent, defaults: defaults) == .chat else { return nil }
        let first = prompt.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return ChatStart(agentID: agent.rawValue, folder: folder, prompt: first)
    }

    /// The chat the sidebar's or the Agents menu's Resume opens when the user chose Chat for `agent`: it goes on with
    /// `sessionID`, and never starts a new conversation in its place. Nil for a fork, which only the agent's own
    /// terminal makes, for the terminal default, and for an id that isn't one of the agent's.
    public static func resumeStart(agent: ConversationHandoff.Agent, sessionID: String, fork: Bool, folder: String?,
                                   defaults: UserDefaults) -> ChatStart? {
        guard !fork, opensIn(agent, defaults: defaults) == .chat, agent.restoreAgent.isSessionID(sessionID) else { return nil }
        return ChatStart(agentID: agent.rawValue, folder: folder, resumeID: sessionID, resumeOnly: true)
    }
}
