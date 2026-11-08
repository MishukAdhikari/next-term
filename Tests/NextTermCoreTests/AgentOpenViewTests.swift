import Foundation
import Testing
@testable import NextTermCore

/// Settings' "Open Claude Code in" and "Open Codex in" (plan 036 U1): which view a start Next Term makes itself opens
/// in, and the line it runs. Only a bare program word turns into a session; anything else stays as given.
@Suite struct AgentOpenViewTests {
    private let launcher = "nxtrm"
    private let id = "8f3a1c2e-1b2c-4d5e-8f90-0a1b2c3d4e5f"

    @Test func withNothingSetEveryAgentOpensInTheTerminal() throws {
        let (defaults, name) = try TestDefaults.make("agent-open-view")
        defer { TestDefaults.remove(defaults, name) }
        #expect(AgentOpenView.opensIn(.claude, defaults: defaults) == .terminal)
        #expect(AgentOpenView.opensIn(.codex, defaults: defaults) == .terminal)
        #expect(AgentOpenView.startLine(command: "claude", prompt: nil, launcher: launcher, defaults: defaults) == nil)
        #expect(AgentOpenView.resumeLine(agent: .claude, sessionID: id, fork: false, launcher: launcher, defaults: defaults) == nil)
        // A value this build doesn't know reads as the terminal.
        defaults.set("sideways", forKey: AgentOpenView.key(.claude))
        #expect(AgentOpenView.opensIn(.claude, defaults: defaults) == .terminal)
    }

    @Test func setToChatABareProgramStartsASession() throws {
        let (defaults, name) = try TestDefaults.make("agent-open-view")
        defer { TestDefaults.remove(defaults, name) }
        AgentOpenView.set(.chat, for: .claude, defaults: defaults)
        #expect(defaults.string(forKey: "agentOpensIn.claude") == "chat")
        let start = AgentOpenView.startLine(command: "claude", prompt: "fix it", launcher: launcher, defaults: defaults)
        #expect(start?.line == "nxtrm agent claude --prompt 'fix it'")
        #expect(start?.view == .chat)
        #expect(AgentOpenView.startLine(command: " claude ", prompt: nil, launcher: launcher, defaults: defaults)?.line == "nxtrm agent claude")
    }

    @Test func aCommandWithOptionsOrAnotherNameStaysAsTyped() throws {
        let (defaults, name) = try TestDefaults.make("agent-open-view")
        defer { TestDefaults.remove(defaults, name) }
        AgentOpenView.set(.chat, for: .claude, defaults: defaults)
        for command in ["claude --model opus", "claude-auto", "npx claude", "codex", "claude; ls", ""] {
            #expect(AgentOpenView.startLine(command: command, prompt: nil, launcher: launcher, defaults: defaults) == nil)
        }
    }

    @Test func theSidebarsResumeOpensInChatButAForkNever() throws {
        let (defaults, name) = try TestDefaults.make("agent-open-view")
        defer { TestDefaults.remove(defaults, name) }
        AgentOpenView.set(.chat, for: .claude, defaults: defaults)
        #expect(AgentOpenView.resumeLine(agent: .claude, sessionID: id, fork: false, launcher: launcher, defaults: defaults)
                == "nxtrm agent claude --resume " + id)
        #expect(AgentOpenView.resumeLine(agent: .claude, sessionID: id, fork: true, launcher: launcher, defaults: defaults) == nil)
        // An id that isn't one plain word is never put in a line.
        #expect(AgentOpenView.resumeLine(agent: .claude, sessionID: "x; rm -rf ~", fork: false, launcher: launcher, defaults: defaults) == nil)
    }

    @Test func codexsDefaultIsItsOwn() throws {
        let (defaults, name) = try TestDefaults.make("agent-open-view")
        defer { TestDefaults.remove(defaults, name) }
        AgentOpenView.set(.chat, for: .codex, defaults: defaults)
        #expect(AgentOpenView.opensIn(.claude, defaults: defaults) == .terminal)
        #expect(AgentOpenView.opensIn(.codex, defaults: defaults) == .chat)
        #expect(AgentOpenView.startLine(command: "codex", prompt: nil, launcher: launcher, defaults: defaults)?.line == "nxtrm agent codex")
        #expect(AgentOpenView.startLine(command: "claude", prompt: nil, launcher: launcher, defaults: defaults) == nil)
        AgentOpenView.set(.terminal, for: .codex, defaults: defaults)
        #expect(AgentOpenView.opensIn(.codex, defaults: defaults) == .terminal)
    }
}
