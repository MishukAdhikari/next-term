import AppKit
import NextTermCore

/// The agents a chat tab runs (plans 030, 035, 037): Claude Code, Codex or an agent over ACP, for Agents › New Chat… and
/// `new_tab`'s `agent_session`.
enum ACPSessionTabs {
    /// The agents Next Term runs as sessions (Claude Code, Codex and those that speak ACP) whose program is on the login
    /// shell's PATH.
    static var installed: [ACPAgent] {
        ACPAgent.installed(path: ChatEnvironment.searchPath) { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `new_tab`'s check of an `agent_session` name: the agent, or the refusal naming the ones that would run.
    static func agent(named name: String) -> Result<ACPAgent, MCPRefusal> {
        let here = installed
        guard let agent = ACPAgent.named(name) else {
            return .failure(MCPRefusal("\(name) isn't an agent Next Term runs as a session. Installed here: \(ACPAgent.listed(here))."))
        }
        guard here.contains(agent) else {
            return .failure(MCPRefusal("\(agent.name) (\(agent.program)) isn't on the PATH. Installed here: \(ACPAgent.listed(here))."))
        }
        return .success(agent)
    }
}

/// A refusal's words, for MCP.
struct MCPRefusal: Error {
    let text: String
    init(_ text: String) { self.text = text }
}
