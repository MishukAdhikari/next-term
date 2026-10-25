import Foundation
import Testing
@testable import NextTermCore

/// Next Term spells the product as OpenCode does, "OpenCode", wherever it names it: the sessions list, the restore's
/// notes, the MCP registration summary (and every agent name taken from it), Secrets' import and Suggest a Command.
/// What is the program's stays `opencode`: raw values, program names, command lines and the words a notification takes
/// from the program ("opencode needs your decision", as "claude" does for Claude Code).
@Suite struct OpencodeNameTests {
    let home: String
    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("nt-oc-name-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    @Test func theSessionsListNamesOpenCode() {
        #expect(AgentKind.opencode.name == "OpenCode")
        #expect(AgentKind.opencode.shortName == "OpenCode")
        // Its raw value, program and commands stay the program's.
        #expect(AgentKind.opencode.rawValue == "opencode" && AgentKind(program: "opencode") == .opencode)
        #expect(AgentKind.opencode.continueCommand == "opencode --continue")
        #expect(AgentKind.opencode.resumeCommand(id: "ses_7f3a9c", cwd: "/work/demo", fork: false) == "opencode --session ses_7f3a9c")
    }

    /// A search for the product finds its sessions, as typed in either case.
    @Test func aSearchFindsItsSessionsByName() {
        let session = AgentSession(agent: .opencode, id: "ses_7f3a9c", cwd: "/work/demo", title: "Tidy the routes", named: false,
                                   createdAt: nil, updatedAt: Date(), gitBranch: nil, model: nil, isRunning: false)
        #expect(session.matches(SearchWords("OpenCode")) && session.matches(SearchWords("opencode routes")))
    }

    /// The restore's notes name the agent from its kind; the line it puts back stays the program's.
    @Test func theRestoreNamesOpenCode() {
        #expect(RestoreAgent.opencode.name == "OpenCode")
        #expect(RestoreAgent.opencode.program == "opencode")
    }

    @Test func theRegistrarsTargetIsOpenCode() throws {
        let targets = MCPRegistrar.targets(home: home, environment: [:])
        let target = try #require(targets.first { $0.id == "opencode" })
        #expect(target.name == "OpenCode" && target.programs == ["opencode"])
        let lowercase = targets.filter { $0.name == "opencode" }
        #expect(lowercase.isEmpty)
    }

    /// The name worktrees, the branch popup and Secrets give the agent a program runs as.
    @Test func theProgramsAgentNameIsOpenCode() {
        #expect(AgentName.of(program: "opencode") == "OpenCode")
    }

    @Test func theSettingsSummaryNamesOpenCode() {
        let one = MCPRegistrar.summary(["opencode": .registered], apps: [], home: home)
        #expect(one == "Registered in OpenCode.")
        let taken = MCPRegistrar.summary(["opencode": .nameTaken], apps: [], home: home)
        #expect(taken == "Not registered in any agent yet. OpenCode already has another server named “next-term”, left as it is.")
        let both = MCPRegistrar.summary(["codex": .registered, "opencode": .alreadyRegistered], apps: [], home: home)
        #expect(both.contains("Codex") && both.contains("OpenCode") && !both.contains("opencode"))
    }

    @Test func secretsImportNamesOpenCode() {
        #expect(SecretImport.Client.opencode.name == "OpenCode")
        #expect(SecretImport.Client.opencode.rawValue == "opencode")
        #expect(SecretImport.Client(rawValue: "opencode") == .opencode)
    }

    @Test func suggestACommandNamesOpenCode() {
        let names: [String] = CommandSuggestion.leftOut.map(\.name)
        #expect(names.contains("OpenCode") && !names.contains("opencode"))
    }

    /// Every name Next Term gives an agent, in one place or another, spells it as OpenCode does.
    @Test func noAgentNameSpellsItLowercase() {
        var names: [String] = AgentKind.allCases.map(\.name) + AgentKind.allCases.map(\.shortName)
        names += SkillAgent.allCases.map(\.title) + SecretImport.Client.allCases.map(\.name)
        names += MCPRegistrar.targets(home: home, environment: [:]).map(\.name)
        names += SkillReaders.shared + SkillReaders.claude
        #expect(!names.contains { $0.lowercased() == "opencode" && $0 != "OpenCode" }, "\(names)")
    }
}
