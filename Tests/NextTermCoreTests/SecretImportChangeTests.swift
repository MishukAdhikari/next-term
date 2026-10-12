import Foundation
import Testing
@testable import NextTermCore

/// A key changed in its file after the scan is never taken out of it: the plan, and the plan made again at write time,
/// compare each value with the one Secrets stores. An env that names a variable twice is not movable, so the row ticked
/// is the value taken out.
@Suite struct SecretImportChangeTests {
    /// A rotated GitHub token: made up, like every fixture.
    static let rotated = "ghp_" + "Zz9Yy8Xx7Ww6Vv5Uu4Tt3Ss2Rr1Qq0PpOoNn98"

    func finding(_ home: F.Home, _ variable: String, server: String) throws -> SecretImport.Finding {
        let found = SecretImport.scan(F.sources(home))
        return try #require(found.findings.first { $0.variable == variable && $0.location.server == server })
    }

    @Test func aJSONKeyChangedAfterTheScanStaysInItsFile() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".cursor/mcp.json", F.cursorJSON)
        let move = SecretImport.Move(name: "GITHUB_TOKEN", findings: [try finding(home, "GITHUB_TOKEN", server: "github")])
        let rotated = F.cursorJSON.replacingOccurrences(of: "{\"GITHUB_TOKEN\": \"\(F.github)\"}", with: "{\"GITHUB_TOKEN\": \"\(Self.rotated)\"}")
        #expect(rotated != F.cursorJSON)

        // Rotated before Move: the plan leaves the file.
        home.write(".cursor/mcp.json", rotated)
        let planned = SecretImport.plan([move], nxtrm: F.nxtrm)
        #expect(planned.edits.isEmpty && planned.failures.map(\.reason) == [SecretImport.changedReason("GITHUB_TOKEN")])

        // Rotated during the Touch ID wait: planned again at write time, refused, and the new key is still in the file.
        home.write(".cursor/mcp.json", F.cursorJSON)
        let edit = try #require(SecretImport.plan([move], nxtrm: F.nxtrm).edits.first)
        home.write(".cursor/mcp.json", rotated)
        #expect(SecretImport.apply(edit) == .changed)
        #expect(home.read(".cursor/mcp.json") == rotated)

        // Unchanged, it moves as before.
        home.write(".cursor/mcp.json", F.cursorJSON)
        #expect(SecretImport.apply(edit) == .written && !home.read(".cursor/mcp.json").contains("{\"GITHUB_TOKEN\""))
    }

    @Test func aTOMLKeyChangedAfterTheScanStaysInItsFile() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".codex/config.toml", F.codexTOML)
        let inline = SecretImport.Move(name: "GITHUB_TOKEN", findings: [try finding(home, "GITHUB_TOKEN", server: "github")])
        let table = SecretImport.Move(name: "STRIPE_SECRET_KEY", findings: [try finding(home, "STRIPE_SECRET_KEY", server: "stripe")])

        // In an inline env, and in an [mcp_servers.NAME.env] table.
        let rotatedInline = F.codexTOML.replacingOccurrences(of: "GITHUB_TOKEN = \"\(F.github)\"", with: "GITHUB_TOKEN = \"\(Self.rotated)\"")
        let rotatedTable = F.codexTOML.replacingOccurrences(of: "STRIPE_SECRET_KEY = \"\(F.stripe)\"", with: "STRIPE_SECRET_KEY = \"\(F.stripe)2\"")
        #expect(rotatedInline != F.codexTOML && rotatedTable != F.codexTOML)
        home.write(".codex/config.toml", rotatedInline)
        #expect(SecretImport.plan([inline], nxtrm: F.nxtrm).failures.map(\.reason) == [SecretImport.changedReason("GITHUB_TOKEN")])
        home.write(".codex/config.toml", rotatedTable)
        #expect(SecretImport.plan([table], nxtrm: F.nxtrm).failures.map(\.reason) == [SecretImport.changedReason("STRIPE_SECRET_KEY")])

        home.write(".codex/config.toml", F.codexTOML)
        let edit = try #require(SecretImport.plan([inline], nxtrm: F.nxtrm).edits.first)
        home.write(".codex/config.toml", rotatedInline)
        #expect(SecretImport.apply(edit) == .changed)
        #expect(home.read(".codex/config.toml") == rotatedInline)
    }

    @Test func anEnvThatNamesAVariableTwiceIsNotMovable() throws {
        let home = F.Home()
        defer { home.remove() }
        // JSON parsers take the second; the scan lists both.
        home.write(".gemini/settings.json", """
            {"mcpServers": {"one": {"command": "npx", "args": ["one"], "env": {"API_KEY": "\(F.openai)", "API_KEY": "\(F.stripe)"}}}}
            """)
        home.write(".codex/config.toml", """
            [mcp_servers.inline]
            command = "x"
            env = { TWICE_TOKEN = "\(F.openai)", TWICE_TOKEN = "\(F.stripe)" }

            [mcp_servers.both]
            command = "y"
            env = { BOTH_TOKEN = "\(F.openai)" }

            [mcp_servers.both.env]
            BOTH_TOKEN = "\(F.stripe)"

            """)
        let found = SecretImport.scan(F.sources(home))
        for server in ["one", "inline", "both"] {
            let listed = found.findings.filter { $0.location.server == server }
            #expect(listed.count == 2 && listed.allSatisfy { $0.notMovable == "repeated keys" }, "\(server)")
        }
        #expect(SecretImport.groups(found.findings, stored: []).isEmpty)
    }
}
