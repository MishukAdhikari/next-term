import Foundation
import Testing
@testable import NextTermCore

@Suite struct MCPRegistrationNoticeTests {
    let home = "/nonexistent-\(UUID().uuidString)"

    @Test func aFirstAddNamesEveryAgentNextTermIsInWithItsFile() throws {
        let statuses: [String: MCPRegistrar.Status] = ["claude": .registered, "codex": .alreadyRegistered,
                                                       "commandcode": .registered, "gemini": .notInstalled, "amp": .nameTaken]
        let notice = try #require(MCPRegistrationNotice.due(statuses, shown: [], home: home))
        #expect(notice.agents == ["Claude Code", "Codex", "Command Code"])
        #expect(notice.headline == "Next Term added its tools to Claude Code, Codex and Command Code.")
        #expect(notice.message == "Next Term added its tools to Claude Code, Codex and Command Code, so you can ask them to set it up "
            + "or run tabs. One entry in each; nothing else changed.")
        #expect(notice.fileLines == ["Claude Code: ~/.claude.json", "Codex: ~/.codex/config.toml", "Command Code: ~/.commandcode/mcp.json"])
        #expect(notice.meaning == "You can ask them to set it up or run tabs. One entry in each; nothing else changed.")
        #expect(notice.ids == ["claude", "codex", "commandcode"])
    }

    @Test func oneAgentIsNamedInTheSingular() throws {
        let notice = try #require(MCPRegistrationNotice.due(["codex": .registered], shown: [], home: home))
        #expect(notice.message == "Next Term added its tools to Codex, so you can ask it to set it up or run tabs. One entry; nothing else changed.")
    }

    @Test func nothingIsDueUnlessAnAgentNotNamedBeforeWasAdded() {
        // Already there (an earlier version added it): nothing was added, so nothing is said.
        #expect(MCPRegistrationNotice.due(["claude": .alreadyRegistered, "codex": .alreadyRegistered], shown: [], home: home) == nil)
        // Put back in an agent named before (Gemini rewrote its file): nothing new.
        #expect(MCPRegistrationNotice.due(["gemini": .registered, "claude": .alreadyRegistered], shown: ["gemini", "claude"], home: home) == nil)
        // Nothing in any agent.
        #expect(MCPRegistrationNotice.due(["codex": .notInstalled, "claude": .skipped("x")], shown: [], home: home) == nil)
        // A new agent: due again, naming every agent Next Term is in.
        let again = MCPRegistrationNotice.due(["codex": .registered, "claude": .alreadyRegistered], shown: ["claude"], home: home)
        #expect(again?.agents == ["Claude Code", "Codex"])
    }

    @Test func theClaudeAppIsNamedOnceForBothOfItsFiles() throws {
        let statuses: [String: MCPRegistrar.Status] = ["claude-desktop": .registered, "claude-desktop-3p": .registered]
        let notice = try #require(MCPRegistrationNotice.due(statuses, shown: [], home: home))
        #expect(notice.agents == ["the Claude app"])
        #expect(notice.fileLines.count == 2)
    }

    @Test func whatWasShownIsRememberedWithWhatWasBefore() throws {
        let suite = "nt-notice-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(MCPRegistrationNotice.shown(in: defaults).isEmpty)
        try #require(MCPRegistrationNotice.due(["claude": .registered], shown: [], home: home)).remember(in: defaults)
        try #require(MCPRegistrationNotice.due(["codex": .registered], shown: ["claude"], home: home)).remember(in: defaults)
        #expect(MCPRegistrationNotice.shown(in: defaults) == ["claude", "codex"])
        #expect(MCPRegistrationNotice.due(["codex": .registered, "claude": .registered], shown: MCPRegistrationNotice.shown(in: defaults),
                                          home: home) == nil)
    }

    @Test func eachAgentKindHasItsRegistrarID() {
        let ids = Set(MCPRegistrar.targets(home: home).map(\.id) + ["claude"])
        for agent in AgentKind.allCases { #expect(ids.contains(MCPRegistrar.id(of: agent)), "\(agent)") }
    }

    @Test func anAgentStartedBeforeNextTermWasAddedNeedsARestart() {
        var landed = MCPRegistrar.landed([:], after: ["claude": .registered, "codex": .alreadyRegistered], at: 100)
        #expect(landed == ["claude": 100])
        #expect(MCPRegistrar.needsRestart(.claude, since: 90, landed: landed))
        #expect(!MCPRegistrar.needsRestart(.claude, since: 110, landed: landed))
        #expect(!MCPRegistrar.needsRestart(.claude, since: nil, landed: landed))
        // Codex had it before this launch: an agent running there has the tools.
        #expect(!MCPRegistrar.needsRestart(.codex, since: 1, landed: landed))
        // Added again later (Gemini or another copy of the app): the first time stays.
        landed = MCPRegistrar.landed(landed, after: ["claude": .registered], at: 200)
        #expect(landed["claude"] == 100)
        // Taken out: no agent needs a restart for tools it no longer has.
        landed = MCPRegistrar.landed(landed, after: ["claude": .removed], at: 300)
        #expect(!MCPRegistrar.needsRestart(.claude, since: 90, landed: landed))
    }
}
