import Foundation
import Testing
@testable import NextTermCore

/// Settings' "Open Claude Code in" and "Open Codex in" (plan 037 U2, from plan 036): which kind of tab a start Next
/// Term makes itself opens, and the chat it starts. Only a bare program word turns into a chat; anything else stays as
/// given, in a terminal tab.
@Suite struct AgentOpenViewTests {
    private let id = "8f3a1c2e-1b2c-4d5e-8f90-0a1b2c3d4e5f"

    @Test func withNothingSetEveryAgentOpensInTheTerminal() throws {
        let (defaults, name) = try TestDefaults.make("agent-open-view")
        defer { TestDefaults.remove(defaults, name) }
        #expect(AgentOpenView.opensIn(.claude, defaults: defaults) == .terminal)
        #expect(AgentOpenView.opensIn(.codex, defaults: defaults) == .terminal)
        #expect(AgentOpenView.newTabStart(command: "claude", prompt: nil, folder: "/p", defaults: defaults) == nil)
        #expect(AgentOpenView.resumeStart(agent: .claude, sessionID: id, fork: false, folder: "/p", defaults: defaults) == nil)
        // A value this build doesn't know reads as the terminal.
        defaults.set("sideways", forKey: AgentOpenView.key(.claude))
        #expect(AgentOpenView.opensIn(.claude, defaults: defaults) == .terminal)
    }

    @Test func setToChatABareProgramStartsAChat() throws {
        let (defaults, name) = try TestDefaults.make("agent-open-view")
        defer { TestDefaults.remove(defaults, name) }
        AgentOpenView.set(.chat, for: .claude, defaults: defaults)
        #expect(defaults.string(forKey: "agentOpensIn.claude") == "chat")
        let start = AgentOpenView.newTabStart(command: "claude", prompt: "fix it", folder: "/p", defaults: defaults)
        #expect(start == ChatStart(agentID: "claude", folder: "/p", prompt: "fix it"))
        #expect(AgentOpenView.newTabStart(command: " claude ", prompt: nil, folder: nil, defaults: defaults)
                == ChatStart(agentID: "claude", folder: nil))
        // A blank prompt is no prompt.
        #expect(AgentOpenView.newTabStart(command: "claude", prompt: "  ", folder: nil, defaults: defaults)?.prompt == nil)
    }

    @Test func aCommandWithOptionsOrAnotherNameStaysAsTyped() throws {
        let (defaults, name) = try TestDefaults.make("agent-open-view")
        defer { TestDefaults.remove(defaults, name) }
        AgentOpenView.set(.chat, for: .claude, defaults: defaults)
        for command in ["claude --model opus", "claude-auto", "npx claude", "codex", "claude; ls", ""] {
            #expect(AgentOpenView.newTabStart(command: command, prompt: nil, folder: nil, defaults: defaults) == nil, "\(command)")
        }
    }

    @Test func theSidebarsResumeOpensAChatButAForkNever() throws {
        let (defaults, name) = try TestDefaults.make("agent-open-view")
        defer { TestDefaults.remove(defaults, name) }
        AgentOpenView.set(.chat, for: .claude, defaults: defaults)
        #expect(AgentOpenView.resumeStart(agent: .claude, sessionID: id, fork: false, folder: "/p", defaults: defaults)
                == ChatStart(agentID: "claude", folder: "/p", resumeID: id, resumeOnly: true))
        #expect(AgentOpenView.resumeStart(agent: .claude, sessionID: id, fork: true, folder: "/p", defaults: defaults) == nil)
        // An id that isn't one plain word never starts anything.
        #expect(AgentOpenView.resumeStart(agent: .claude, sessionID: "x; rm -rf ~", fork: false, folder: "/p", defaults: defaults) == nil)
    }

    @Test func codexsDefaultIsItsOwn() throws {
        let (defaults, name) = try TestDefaults.make("agent-open-view")
        defer { TestDefaults.remove(defaults, name) }
        AgentOpenView.set(.chat, for: .codex, defaults: defaults)
        #expect(AgentOpenView.opensIn(.claude, defaults: defaults) == .terminal)
        #expect(AgentOpenView.opensIn(.codex, defaults: defaults) == .chat)
        #expect(AgentOpenView.newTabStart(command: "codex", prompt: nil, folder: nil, defaults: defaults)?.agentID == "codex")
        #expect(AgentOpenView.newTabStart(command: "claude", prompt: nil, folder: nil, defaults: defaults) == nil)
        AgentOpenView.set(.terminal, for: .codex, defaults: defaults)
        #expect(AgentOpenView.opensIn(.codex, defaults: defaults) == .terminal)
    }
}
