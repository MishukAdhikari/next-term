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

    /// A server's table written twice is TOML Codex refuses. Each place is listed with its own keys, an env table with the
    /// server's table above it (or its first, when none is above), and neither place moves.
    @Test func aServerTableWrittenTwiceIsListedPlaceByPlaceAndNotMovable() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".codex/config.toml", """
            [mcp_servers.twice.env]
            EARLY_TOKEN = "\(F.stripe)"

            [mcp_servers.twice]
            command = "npx"
            env = { FIRST_TOKEN = "\(F.openai)" }

            [mcp_servers.once]
            command = "npx"
            args = ["-y", "gh"]
            env = { GITHUB_TOKEN = "\(F.github)" }

            [mcp_servers.twice]
            command = "node"
            args = ["server.js"]

            [mcp_servers.twice.env]
            SECOND_TOKEN = "\(F.github)"

            """)
        let entries = try #require(SecretImport.tomlEntries(home.read(".codex/config.toml")))
        let places = entries.filter { $0.location.server == "twice" }
        #expect(places.map(\.command) == [["npx"], ["node"]] && places.map(\.args) == [[], ["server.js"]])
        #expect(places.map { $0.detected.map(\.variable) } == [["FIRST_TOKEN", "EARLY_TOKEN"], ["SECOND_TOKEN"]])
        #expect(places.allSatisfy { $0.notMovable == "repeated keys" })
        let found = SecretImport.scan(F.sources(home))
        let twice = found.findings.filter { $0.location.server == "twice" }
        #expect(twice.map(\.variable) == ["FIRST_TOKEN", "EARLY_TOKEN", "SECOND_TOKEN"])
        #expect(twice.allSatisfy { $0.notMovable == "repeated keys" })
        #expect(try finding(home, "GITHUB_TOKEN", server: "once").movable)
    }

    /// A table written again after the scan: the plan, which reads the file again, refuses it as the scan would.
    @Test func aServerTableWrittenAgainAfterTheScanIsNotMoved() throws {
        let home = F.Home()
        defer { home.remove() }
        let once = "[mcp_servers.once]\ncommand = \"npx\"\nargs = [\"-y\", \"gh\"]\nenv = { GITHUB_TOKEN = \"\(F.github)\" }\n"
        home.write(".codex/config.toml", once)
        let scanned = try finding(home, "GITHUB_TOKEN", server: "once")
        #expect(scanned.movable)
        home.write(".codex/config.toml", once + "\n[mcp_servers.once]\ncommand = \"other\"\n")
        let planned = SecretImport.plan([SecretImport.Move(name: "GITHUB_TOKEN", findings: [scanned])], nxtrm: F.nxtrm)
        #expect(planned.edits.isEmpty && planned.failures.map(\.reason) == ["repeated keys"])
    }
}
