import Foundation

/// Settings' "Open Claude Code in" and "Open Codex in" (plan 036 KTD11): the view a start Next Term makes itself opens in,
/// Terminal unless the user chose Chat. It applies to `new_tab` with the agent's bare program, the Welcome window's set-up
/// card and the sidebar's and Agents menu's Resume, never to a line the user types, a restore, or a fork.
public enum AgentOpenView {
    /// The defaults key for `agent`: `agentOpensIn.claude`, `agentOpensIn.codex`.
    public static func key(_ agent: ViewSwitch.Agent) -> String { "agentOpensIn." + agent.rawValue }

    /// The view `agent` opens in. Nothing set, or a value this build doesn't know, reads as the terminal.
    public static func opensIn(_ agent: ViewSwitch.Agent, defaults: UserDefaults) -> ViewSwitch.View {
        defaults.string(forKey: key(agent)).flatMap(ViewSwitch.View.init(rawValue:)) ?? .terminal
    }

    public static func set(_ view: ViewSwitch.View, for agent: ViewSwitch.Agent, defaults: UserDefaults) {
        defaults.set(view.rawValue, forKey: key(agent))
    }

    /// The line a start runs in its new tab, and the view it opens in, when the user chose Chat for the agent the command
    /// names. Only the bare program word (`claude`, `codex`) turns into a session: options such as `--model` have no chat
    /// form, so any other command stays as given (nil).
    public static func startLine(command: String, prompt: String?, launcher: String,
                                 defaults: UserDefaults) -> (line: String, view: ViewSwitch.View)? {
        let word = command.trimmingCharacters(in: .whitespaces)
        guard let agent = ViewSwitch.Agent(program: word), opensIn(agent, defaults: defaults) == .chat else { return nil }
        return (agent.sessionAgent.sessionLine(launcher: launcher, prompt: prompt), .chat)
    }

    /// The line the sidebar's or the Agents menu's Resume runs when the user chose Chat for `agent`: the session that goes
    /// on with `sessionID`. Nil for a fork, which only the agent's own terminal makes, for the terminal default, and for
    /// an id that isn't one of the agent's.
    public static func resumeLine(agent: ViewSwitch.Agent, sessionID: String, fork: Bool, launcher: String,
                                  defaults: UserDefaults) -> String? {
        guard !fork, opensIn(agent, defaults: defaults) == .chat, agent.restoreAgent.isSessionID(sessionID) else { return nil }
        return agent.sessionAgent.resumeLine(launcher: launcher, sessionID: sessionID)
    }
}
