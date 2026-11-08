import Foundation

/// The agents Next Term runs as sessions: those that speak ACP themselves, with the command that starts each in ACP mode
/// (research Part A §3.1, the ACP Registry's commands on 2026-10-26), and Claude Code and Codex, each over its own
/// protocol (plan 035). `nxtrm agent NAME` runs one; an agent's program has to be on the PATH, and Next Term installs
/// nothing (R2, R4). Plan 030.
public struct ACPAgent: Equatable, Sendable {
    /// How Next Term talks to the agent.
    public enum ProtocolKind: String, Equatable, Sendable {
        /// The Agent Client Protocol, with `arguments` for its ACP mode.
        case acp
        /// Claude Code's `claude -p` with stream-json in and out and its control channel (`ClaudeStream`).
        case claudeStream
        /// Codex's `codex app-server`, JSON-RPC over stdio.
        case codexAppServer
    }

    /// What `nxtrm agent` and `new_tab` take: gemini, qwen, opencode, ...
    public let id: String
    /// What the tab and the menu call it.
    public let name: String
    /// The program looked for on the PATH.
    public let program: String
    /// Its arguments for ACP mode. Empty for Claude Code and Codex, whose drivers build their own.
    public let arguments: [String]
    public let protocolKind: ProtocolKind
    /// One line for the new session sheet on what still needs the agent's own terminal tab (R10), or nil.
    public let terminalNote: String?

    public init(id: String, name: String, program: String, arguments: [String], protocolKind: ProtocolKind = .acp,
                terminalNote: String? = nil) {
        self.id = id
        self.name = name
        self.program = program
        self.arguments = arguments
        self.protocolKind = protocolKind
        self.terminalNote = terminalNote
    }

    /// The agents, in the order the menu lists them: Claude Code and Codex, then the native ACP agents.
    public static let known: [ACPAgent] = [
        ACPAgent(id: "claude", name: "Claude Code", program: "claude", arguments: [], protocolKind: .claudeStream,
                 terminalNote: "Claude Code\u{2019}s /usage, /rewind and /login, and its plugin and MCP panels, work in a terminal tab running claude."),
        ACPAgent(id: "codex", name: "Codex", program: "codex", arguments: [], protocolKind: .codexAppServer,
                 terminalNote: "Codex\u{2019}s own screens, such as /status and /approvals, work in a terminal tab running codex."),
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

    /// Whether a session of this agent comes back after an update (plan 035 U7): Claude Code's by `claude --resume`,
    /// Codex's by `thread/resume`. An ACP agent's session is a command like any other.
    public var resumesSessions: Bool { protocolKind != .acp }

    /// The line that resumes session `sessionID` of this agent in a restored tab: `launcher agent ID --resume SESSION`. The
    /// id is one `AgentSessionVersion.isSessionID` takes, quoted all the same.
    public func resumeLine(launcher: String, sessionID: String) -> String {
        launcher + " agent " + id + " --resume " + ShellQuote.quote(sessionID)
    }

    /// The slash commands only the agent's own terminal interface runs (plan 037 R4, from plan 036): a chat tab doesn't
    /// send them and offers Open in Terminal instead. None for an ACP agent, which has no terminal kind here.
    public var terminalOnlyCommands: [String] {
        switch id {
        case "claude": return ["/login", "/logout", "/mcp", "/plugin", "/usage", "/rewind"]
        case "codex": return ["/login", "/logout", "/mcp", "/status", "/approvals"]
        default: return []
        }
    }

    /// The terminal-only command a typed prompt is (`/login`, `/login extra`, ` /mcp`), by its first word; nil for any
    /// other prompt, a slash command the session runs itself, or a word that isn't at the start.
    public func terminalOnly(_ typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let word = String(trimmed.prefix { !$0.isWhitespace })
        return terminalOnlyCommands.contains(word) ? word : nil
    }

    /// The ids, for a refusal that says which would run.
    public static func listed(_ agents: [ACPAgent]) -> String {
        agents.isEmpty ? "none of them is installed here" : agents.map(\.id).joined(separator: ", ")
    }
}
