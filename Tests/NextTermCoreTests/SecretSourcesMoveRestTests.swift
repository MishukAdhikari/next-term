import Foundation
import Testing
@testable import NextTermCore

/// A file the MCP-config import moves keys out of can hold keys outside its servers too: Codex's shell `set` and model
/// providers' tokens, OpenCode's providers' keys. The app sends the servers to that import and offers these as a copy,
/// each noted that the file still holds it. Files are made up, under a temporary home.
@Suite struct SecretSourcesMoveRestTests {
    typealias C = ConfigFixtures
    typealias F = SecretSourcesFixtures
    typealias I = SecretImportFixtures
    typealias T = SecretSourcesConfigsTests

    static func rest(_ path: String, home: I.Home, projects: [String]) throws -> SourceReport {
        let source = try #require(SecretSources.moveSource(path: path, home: home.path, projects: projects))
        var bytes: [UInt8] = Array(home.data(String(path.dropFirst(home.path.count + 1))))
        return SecretSources.readOutsideServers(&bytes, of: source)
    }

    @Test func codexsShellSetAndModelProvidersAreCopiedAndItsServersMoved() throws {
        let home = I.Home()
        defer { home.remove() }
        let project: String = home.path + "/rag-api"
        let path: String = home.write("rag-api/.codex/config.toml", C.codexTOML)
        #expect(SecretSources.isMoveTarget(path: path, home: home.path, projects: [project]))
        let report = try Self.rest(path, home: home, projects: [project])
        #expect(report.format == .toml && report.agent == "Codex" && report.fileNote == .stillInFile)
        #expect(T.names(report) == ["AZURE_OPENAI_API_KEY", "OPENAI_API_KEY"])
        #expect(report.rows.allSatisfy { (row: SourceRow) -> Bool in row.ticked && row.note == .stillInFile })
        // The servers' values are the move import's: neither a row nor counted here.
        let places: [String] = report.notKeys.map(\.place) + report.rows.map(\.place)
        #expect(!places.contains { (place: String) -> Bool in place.hasPrefix("mcp_servers") })
        #expect(report.purpose == "From config.toml in rag-api")
    }

    @Test func opencodesProviderKeysAreCopied() throws {
        let home = I.Home()
        defer { home.remove() }
        let project: String = home.path + "/rag-api"
        let text: String = #"{"provider": {"openai": {"options": {"apiKey": "\#(F.openAI)"}}}, "#
            + #""mcp": {"search": {"type": "local", "command": ["npx"], "environment": {"A_TOKEN": "\#(C.github)"}}}}"#
        let path: String = home.write("rag-api/opencode.json", text)
        let report = try Self.rest(path, home: home, projects: [project])
        #expect(report.format == .json && report.agent == "OpenCode" && report.fileNote == .stillInFile)
        // A provider's key is named as OpenCode's providers read it from the environment.
        #expect(T.names(report) == ["OPENAI_API_KEY"])
        #expect(report.rows.first?.place == "provider.openai.options.apiKey" && report.rows.first?.note == .stillInFile)
    }

    @Test func aFileOfServersOnlyOrClaudeCodesOwnGivesNoRows() throws {
        let home = I.Home()
        defer { home.remove() }
        let project: String = home.path + "/triage-agent"
        let servers: String = #"{"mcpServers": {"github": {"command": "npx", "env": {"GITHUB_TOKEN": "\#(C.github)"}}}}"#
        let mcp: String = home.write("triage-agent/.mcp.json", servers)
        #expect(try Self.rest(mcp, home: home, projects: [project]).rows.isEmpty)
        let state: String = #"{"userID": "made-up", "primaryApiKey": "\#(F.openAI)", "mcpServers": {}}"#
        let claude: String = home.write(".claude.json", state)
        let report = try Self.rest(claude, home: home, projects: [])
        #expect(report.rows.isEmpty && report.notKeys.isEmpty)
    }
}
