import Foundation
import Testing
@testable import NextTermCore

/// Each agent's "Opens as": chat for a new install, terminal for one used before, each agent's own choice kept.
@Suite struct ChatFirstTests {
    private func fresh() -> UserDefaults {
        let name = "nt-chatfirst-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aNewInstallOpensAsChat() {
        let defaults = fresh()
        #expect(ChatFirst.settleDefault(in: defaults) == true)
        #expect(ChatFirst.opensAsChat("claude", in: defaults))
        #expect(ChatFirst.opensAsChat("commandcode", in: defaults))
    }

    @Test func anInstallUsedBeforeKeepsTheTerminal() {
        let defaults = fresh()
        defaults.set([String](), forKey: "sessionProjects")
        #expect(ChatFirst.settleDefault(in: defaults) == false)
        #expect(!ChatFirst.opensAsChat("codex", in: defaults))
    }

    @Test func theDefaultIsSettledOnce() {
        let defaults = fresh()
        ChatFirst.settleDefault(in: defaults)
        defaults.set([String](), forKey: "sessionProjects")
        #expect(ChatFirst.settleDefault(in: defaults) == nil)
        #expect(ChatFirst.opensAsChat("claude", in: defaults))
    }

    @Test func eachAgentKeepsItsOwnChoice() {
        let defaults = fresh()
        defaults.set([String](), forKey: "sessionProjects")
        ChatFirst.settleDefault(in: defaults)
        ChatFirst.set("claude", asChat: true, in: defaults)
        #expect(ChatFirst.opensAsChat("claude", in: defaults))
        #expect(!ChatFirst.opensAsChat("codex", in: defaults))
        ChatFirst.set("claude", asChat: false, in: defaults)
        #expect(!ChatFirst.opensAsChat("claude", in: defaults))
    }

    @Test func chatAgentsAreTheSessionAgentsAndCommandCode() {
        #expect(ChatFirst.agentIDs.isSuperset(of: ["claude", "codex", "commandcode", "opencode", "cursor", "gemini"]))
        #expect(!ChatFirst.agentIDs.contains("aider"))
        #expect(LiveChat.Agent.allCases.allSatisfy { ChatFirst.agentIDs.contains(ChatFirst.id(of: $0)) })
    }
}
