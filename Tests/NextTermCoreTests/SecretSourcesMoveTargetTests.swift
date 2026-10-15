import Foundation
import Testing
@testable import NextTermCore

/// Which chosen files go to the MCP-config import, which rewrites them, instead of a copy: the agents' own configs and
/// a project's, followed through links. An open project's `opencode.json` joins that import. Files are made up, under a
/// temporary home.
@Suite struct SecretSourcesMoveTargetTests {
    typealias I = SecretImportFixtures

    @Test func theImportsOwnFilesAreMoveTargetsThroughLinks() throws {
        let home = I.Home()
        defer { home.remove() }
        let claude: String = home.write(".claude.json", "{}")
        let project: String = home.write("triage-agent/.mcp.json", "{}")
        let zed: String = home.write(".config/zed/settings.json", "{}")
        let opencode: String = home.write("rag-api/opencode.json", "{}")
        let env: String = home.write("rag-api/.env", "A=1\n")
        try FileManager.default.createDirectory(atPath: home.file("links"), withIntermediateDirectories: true)
        let link: String = home.file("links/team-mcp.json")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: project)
        #expect(SecretSources.isMoveTarget(path: claude, home: home.path))
        #expect(SecretSources.isMoveTarget(path: project, home: home.path))
        #expect(SecretSources.isMoveTarget(path: link, home: home.path))
        #expect(SecretSources.isMoveTarget(path: opencode, home: home.path))
        #expect(!SecretSources.isMoveTarget(path: zed, home: home.path))
        #expect(!SecretSources.isMoveTarget(path: env, home: home.path))
        let source = try #require(SecretSources.moveSource(path: link, home: home.path))
        #expect(source.path == project && source.client == .claudeCode && source.project == home.path + "/triage-agent")
    }

    @Test func anOpenProjectsOpencodeFileJoinsTheImport() throws {
        let home = I.Home()
        defer { home.remove() }
        let project: String = home.path + "/rag-api"
        let file: String = home.write("rag-api/opencode.json", I.opencodeJSON)
        let sources: [SecretImport.Source] = SecretImport.sources(home: home.path, projects: [project])
        let listed = try #require(sources.first { (source: SecretImport.Source) -> Bool in source.path == file })
        #expect(listed.client == .opencode && listed.format == .json && listed.project == project)
        #expect(listed.containers == [["mcp"]])
        #expect(sources.contains { (source: SecretImport.Source) -> Bool in source.path == project + "/opencode.jsonc" })
        #expect(SecretImport.isConfigFile(project + "/opencode.jsonc", home: home.path))
        let scan: SecretImport.Scan = SecretImport.scan(sources)
        let finding = try #require(scan.findings.first { (found: SecretImport.Finding) -> Bool in
            found.variable == "TAVILY_API_KEY"
        })
        #expect(finding.source.path == file && finding.notMovable == nil)
        let planned = SecretImport.plan([SecretImport.Move(name: "TAVILY_API_KEY", findings: [finding])], nxtrm: I.nxtrm)
        let edit = try #require(planned.edits.first)
        #expect(SecretImport.apply(edit, lockWait: 0.3) == .written)
        let text: String = home.read("rag-api/opencode.json")
        let json = try #require(JSONC(text)?.root?.object(in: text) as? [String: Any])
        let search = (json["mcp"] as? [String: Any])?["search"] as? [String: Any]
        let command: [String] = [I.nxtrm[0], "secret", "run", "TAVILY_API_KEY", "--", "npx", "-y", "search-mcp"]
        #expect(search?["command"] as? [String] == command)
        #expect(search?["environment"] as? [String: String] == ["REF": "{env:REF}"])
    }

    @Test func aProjectPassedInNamesTheSourcesProject() throws {
        let home = I.Home()
        defer { home.remove() }
        let project: String = home.path + "/rag-api"
        let gemini: String = home.write("rag-api/.gemini/settings.json", "{}")
        let notes: String = home.write("rag-api/notes/settings.json", "{}")
        #expect(SecretSources.isMoveTarget(path: gemini, home: home.path, projects: [project]))
        #expect(!SecretSources.isMoveTarget(path: notes, home: home.path, projects: [project]))
        let source = try #require(SecretSources.moveSource(path: gemini, home: home.path, projects: [project]))
        #expect(source.client == .gemini && source.project == project)
    }

    @Test func anOpenProjectsOpencodeJSONCIsScannedAndRewritten() throws {
        let home = I.Home()
        defer { home.remove() }
        let project: String = home.path + "/rag-api"
        let commented: String = "// made up for a test\n" + I.opencodeJSON
        let file: String = home.write("rag-api/opencode.jsonc", commented)
        let sources: [SecretImport.Source] = SecretImport.sources(home: home.path, projects: [project])
        let scan: SecretImport.Scan = SecretImport.scan(sources)
        let finding = try #require(scan.findings.first { (found: SecretImport.Finding) -> Bool in
            found.variable == "TAVILY_API_KEY"
        })
        #expect(finding.source.path == file && finding.source.client == .opencode && finding.notMovable == nil)
        let planned = SecretImport.plan([SecretImport.Move(name: "TAVILY_API_KEY", findings: [finding])], nxtrm: I.nxtrm)
        let edit = try #require(planned.edits.first)
        #expect(SecretImport.apply(edit, lockWait: 0.3) == .written)
        let text: String = home.read("rag-api/opencode.jsonc")
        #expect(text.hasPrefix("// made up for a test\n"))
        let json = try #require(JSONC(text)?.root?.object(in: text) as? [String: Any])
        let search = (json["mcp"] as? [String: Any])?["search"] as? [String: Any]
        let command: [String] = [I.nxtrm[0], "secret", "run", "TAVILY_API_KEY", "--", "npx", "-y", "search-mcp"]
        #expect(search?["command"] as? [String] == command)
    }
}
