import Foundation

/// The agents Next Term knows that speak ACP themselves, with the command that starts each in ACP mode (research
/// Part A §3.1, the ACP Registry's commands on 2026-10-26). `nxtrm agent NAME` runs one; an agent's program has to be
/// on the PATH, and Next Term installs nothing (R2, R4). Claude Code and Codex speak ACP only through adapters run with
/// npx, which wait for the consent sheet of a later slice. Plan 030.
public struct ACPAgent: Equatable, Sendable {
    /// What `nxtrm agent` and `new_tab` take: gemini, qwen, opencode, ...
    public let id: String
    /// What the tab and the menu call it.
    public let name: String
    /// The program looked for on the PATH.
    public let program: String
    /// Its arguments for ACP mode.
    public let arguments: [String]

    public init(id: String, name: String, program: String, arguments: [String]) {
        self.id = id
        self.name = name
        self.program = program
        self.arguments = arguments
    }

    /// Native ACP agents, in the order the menu lists them.
    public static let known: [ACPAgent] = [
        ACPAgent(id: "gemini", name: "Gemini CLI", program: "gemini", arguments: ["--acp"]),
        ACPAgent(id: "qwen", name: "Qwen Code", program: "qwen", arguments: ["--acp"]),
        ACPAgent(id: "opencode", name: "OpenCode", program: "opencode", arguments: ["acp"]),
        ACPAgent(id: "cursor", name: "Cursor CLI", program: "cursor-agent", arguments: ["acp"]),
        ACPAgent(id: "copilot", name: "Copilot CLI", program: "copilot", arguments: ["--acp"]),
        ACPAgent(id: "goose", name: "goose", program: "goose", arguments: ["acp"]),
        ACPAgent(id: "kimi", name: "Kimi CLI", program: "kimi", arguments: ["acp"]),
        ACPAgent(id: "auggie", name: "Auggie", program: "auggie", arguments: ["--acp"]),
        ACPAgent(id: "kiro", name: "Kiro CLI", program: "kiro-cli", arguments: ["acp"]),
        ACPAgent(id: "cline", name: "Cline", program: "cline", arguments: ["--acp"]),
        ACPAgent(id: "junie", name: "Junie", program: "junie", arguments: ["--acp=true"]),
        ACPAgent(id: "droid", name: "Factory Droid", program: "droid", arguments: ["exec", "--output-format", "acp-daemon"]),
        ACPAgent(id: "devin", name: "Devin CLI", program: "devin", arguments: ["acp"]),
        ACPAgent(id: "vibe", name: "Mistral Vibe", program: "vibe-acp", arguments: []),
    ]

    /// The agent `id` names, by its id or its program's name (`cursor-agent`), any case.
    public static func named(_ id: String) -> ACPAgent? {
        let wanted = id.lowercased()
        return known.first { $0.id == wanted || $0.program == wanted }
    }

    /// The known agents whose program is in one of `path`'s folders (`exists` checks a file there).
    public static func installed(path: String, exists: (String) -> Bool) -> [ACPAgent] {
        let folders = path.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        return known.filter { agent in folders.contains { exists(($0 as NSString).appendingPathComponent(agent.program)) } }
    }

    /// The ids, for a refusal that says which would run.
    public static func listed(_ agents: [ACPAgent]) -> String {
        agents.isEmpty ? "none of them is installed here" : agents.map(\.id).joined(separator: ", ")
    }
}
