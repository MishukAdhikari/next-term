import Foundation

/// An agent “Set up with your agent” offers (claudedocs/research_first-run-setup_2026-11-02, R4): one whose program is on
/// PATH and that Next Term added its tools to, with the line that starts it in a new tab with the setup prompt
/// (`MCPServer.setupPrompt`) as its first message. The line starts the agent as the user would, so its own trust and
/// permission questions show in the tab for the user to answer; it never carries an option that answers them.
public struct SetupAgent: Equatable, Sendable {
    /// MCPRegistrar.Target.id, and "claude" for Claude Code.
    public let id: String
    /// "Claude Code", "Command Code".
    public let name: String
    /// The program's name as found on PATH ("command-code"): the new tab's login shell finds it the same way.
    public let program: String

    /// What the new tab types: the program, then the setup prompt as its first message, quoted as new_tab quotes one.
    public var commandLine: String { Self.commandLine(id: id, program: program) }

    /// The agents first, in this order: the ones the setup prompt was written with. The rest follow by name.
    static let leading = ["claude", "codex", "commandcode"]

    /// What goes between each agent's program and a first prompt it keeps talking after. Most take the prompt as a word
    /// of their own (OpenCode's is joined to `--prompt=` by `MCPServer.commandLine`). Gemini CLI and Qwen Code read a bare
    /// prompt as a one-shot that answers and exits, and Copilot CLI's bare prompt is not a first message, so those three
    /// take it after `-i`. An agent not listed (Amp, Junie) has no way to start a conversation with a first message,
    /// so it is not offered.
    static let promptOption: [String: String] = [
        "claude": "", "codex": "", "commandcode": "", "opencode": "", "cursor": "",
        "gemini": " -i", "qwen": " -i", "copilot": " -i",
    ]

    /// The agents to offer, in order: those registered now (`statuses`, by target id and "claude", as MCPRegistration
    /// keeps them) whose program the last look along PATH found (`programs`: name → path), with a known first prompt.
    /// A desktop app (the Claude app, the ChatGPT app) has no program, so it never shows.
    public static func offered(programs: [String: String], statuses: [String: MCPRegistrar.Status],
                               home: String = NSHomeDirectory()) -> [SetupAgent] {
        var candidates: [(id: String, name: String, programs: [String])] = [("claude", "Claude Code", ["claude"])]
        for target in MCPRegistrar.targets(home: home, environment: [:]) {
            candidates.append((target.id, target.name, target.programs))
        }
        let agents: [SetupAgent] = candidates.compactMap { candidate in
            guard promptOption[candidate.id] != nil, let status = statuses[candidate.id],
                  status == .registered || status == .alreadyRegistered,
                  let program = candidate.programs.first(where: { programs[$0] != nil }) else { return nil }
            return SetupAgent(id: candidate.id, name: candidate.name, program: program)
        }
        return agents.sorted { order($0) < order($1) }
    }

    /// Where an agent goes in the list: its place among `leading`, else after them by name.
    private static func order(_ agent: SetupAgent) -> (Int, String) {
        (leading.firstIndex(of: agent.id) ?? leading.count, MCPRegistrar.sortKey(agent.name))
    }

    /// The line for the agent `id` run as `program`, with the setup prompt as its first message.
    public static func commandLine(id: String, program: String) -> String {
        MCPServer.commandLine(ShellQuote.quote(program) + (promptOption[id] ?? ""), prompt: MCPServer.setupPrompt)
    }
}
