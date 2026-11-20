import Foundation
import Testing
@testable import NextTermCore

/// Each agent's "Opens as": terminal unless the user picks chat, each agent's own choice kept.
@Suite struct ChatFirstTests {
    private func fresh() -> UserDefaults {
        let name = "nt-chatfirst-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func everyAgentOpensAsItsTerminalUntilTheUserPicks() {
        let defaults = fresh()
        #expect(ChatFirst.agentIDs.allSatisfy { !ChatFirst.opensAsChat($0, in: defaults) })
        #expect(ChatFirst.chatAgents(in: defaults).isEmpty)
    }

    @Test func eachAgentKeepsItsOwnChoice() {
        let defaults = fresh()
        ChatFirst.set("claude", asChat: true, in: defaults)
        #expect(ChatFirst.opensAsChat("claude", in: defaults))
        #expect(!ChatFirst.opensAsChat("codex", in: defaults))
        ChatFirst.set("codex", asChat: true, in: defaults)
        #expect(ChatFirst.chatAgents(in: defaults) == ["claude", "codex"])
        ChatFirst.set("claude", asChat: false, in: defaults)
        #expect(ChatFirst.chatAgents(in: defaults) == ["codex"])
    }

    @Test func chatAgentsAreTheSessionAgentsAndCommandCode() {
        #expect(ChatFirst.agentIDs.isSuperset(of: ["claude", "codex", "commandcode", "opencode", "cursor", "gemini"]))
        #expect(!ChatFirst.agentIDs.contains("aider"))
        #expect(LiveChat.Agent.allCases.allSatisfy { ChatFirst.agentIDs.contains(ChatFirst.id(of: $0)) })
    }
}
