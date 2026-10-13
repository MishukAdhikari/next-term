import Foundation
import Testing
@testable import NextTermCore

/// Codex reads a server's env however the file writes it: inline, as a table, with dotted keys, in an inline server
/// table, or as a multi-line string. Every key it reads is listed, so "no keys found" is never a false all-clear; only
/// the inline and table shapes, each written once, move. An env written twice is TOML Codex refuses.
@Suite struct SecretImportTOMLEnvTests {
    /// The findings of a Codex file with `text`, and the files the scan couldn't read.
    func scanned(_ text: String) -> SecretImport.Scan {
        let home = F.Home()
        defer { home.remove() }
        home.write(".codex/config.toml", text)
        return SecretImport.scan(F.sources(home))
    }

    func value(_ finding: SecretImport.Finding?) -> String? { finding?.value.utf8String() }

    @Test func anEnvWrittenTwiceIsListedAndNotMovable() {
        let token = "GITHUB_TOKEN = \"\(F.github)\""
        let twice = [
            "[mcp_servers.a]\ncommand = \"npx\"\n\n[mcp_servers.a.env]\n\(token)\n\n[mcp_servers.a.env]\nLOG = \"1\"\n",
            "[mcp_servers.a]\ncommand = \"npx\"\nenv = { LOG = \"1\" }\n\n[mcp_servers.a.env]\n\(token)\n",
            "[mcp_servers.a]\ncommand = \"npx\"\nenv = { \(token) }\nenv = { LOG = \"1\" }\n",
            "[mcp_servers.a]\ncommand = \"npx\"\nenv.LOG = \"1\"\n\n[mcp_servers.a.env]\n\(token)\n",
            "[mcp_servers.a]\ncommand = \"npx\"\nenv = { \(token) }\nenv.LOG = \"1\"\n",
        ]
        for (index, text) in twice.enumerated() {
            let found = scanned(text)
            let finding = found.findings.first { $0.variable == "GITHUB_TOKEN" }
            #expect(value(finding) == F.github && finding?.notMovable == "repeated keys", "case \(index)")
            #expect(found.unreadable.isEmpty, "case \(index)")
        }
        // An array of tables is not the map Codex reads.
        let array = scanned("[mcp_servers.a]\ncommand = \"npx\"\n\n[[mcp_servers.a.env]]\n\(token)\n")
        #expect(array.findings.map(\.notMovable) == [SecretImport.envShapeReason])
        // Written once, as a table, it moves.
        let once = scanned("[mcp_servers.a]\ncommand = \"npx\"\n\n[mcp_servers.a.env]\n\(token)\nLOG = \"1\"\n")
        #expect(once.findings.count == 1 && once.findings.allSatisfy(\.movable))
    }

    /// The review's case: a plan made after a second env table was added refuses, as the scan would.
    @Test func anEnvTableWrittenAgainAfterTheScanIsNotMoved() throws {
        let home = F.Home()
        defer { home.remove() }
        let once = "[mcp_servers.a]\ncommand = \"npx\"\n\n[mcp_servers.a.env]\nGITHUB_TOKEN = \"\(F.github)\"\n"
        home.write(".codex/config.toml", once)
        let finding = try #require(SecretImport.scan(F.sources(home)).findings.first)
        #expect(finding.movable)
        home.write(".codex/config.toml", once + "\n[mcp_servers.a.env]\nLOG = \"1\"\n")
        let planned = SecretImport.plan([SecretImport.Move(name: "GITHUB_TOKEN", findings: [finding])], nxtrm: F.nxtrm)
        #expect(planned.edits.isEmpty && planned.failures.map(\.reason) == ["repeated keys"])
    }

    /// Each shape below is TOML Codex reads (checked with Python's tomllib): every key is listed with its value, none
    /// moves, and the file is read.
    @Test func anEnvKeyWrittenDottedOrInlineIsListed() {
        let g = F.github
        let files: [(text: String, servers: [String: [String: String]])] = [
            // The review's case: dotted keys in the server's own table.
            ("[mcp_servers.a]\ncommand = \"npx\"\nenv.GITHUB_TOKEN = \"\(g)\"\nenv.LOG = \"1\"\n", ["a": ["GITHUB_TOKEN": g]]),
            // Dotted from the top, the env inline or dotted down to the key.
            ("""
            mcp_servers.r.command = "x"
            mcp_servers.r.env = { R_TOKEN = "\(g)R" }
            mcp_servers.s.command = "x"
            mcp_servers.s.env.S_TOKEN = "\(g)S"

            [profiles.fast]
            model = "m"

            """, ["r": ["R_TOKEN": g + "R"], "s": ["S_TOKEN": g + "S"]]),
            // Under [mcp_servers]: a dotted server with an inline env, and a server written as an inline table.
            ("""
            [mcp_servers]
            b.command = "x"
            b.env = { B_TOKEN = "\(g)B" }
            c = { command = "x", args = ["a", { k = "v" }], env = { C_TOKEN = "\(g)C", LOG = "1" } }

            """, ["b": ["B_TOKEN": g + "B"], "c": ["C_TOKEN": g + "C"]]),
            // All the servers as one inline table, a quoted key in it.
            ("mcp_servers = { f = { command = \"x\", env = { \"F_TOKEN\" = \"\(g)F\" } } }\n", ["f": ["F_TOKEN": g + "F"]]),
            // Multi-line strings, in an env table and inline; the line break just after the quotes is not part of one.
            ("""
            [mcp_servers.g]
            command = "x"

            [mcp_servers.g.env]
            G_TOKEN = \"\"\"\(g)G\"\"\"
            H_TOKEN = '''
            \(g)H'''

            [mcp_servers.i]
            command = "x"
            env = { I_TOKEN = \"\"\"\(g)I\"\"\" }

            """, ["g": ["G_TOKEN": g + "G", "H_TOKEN": g + "H"], "i": ["I_TOKEN": g + "I"]]),
            // A server written as an array of tables, and an env table with no server table.
            ("""
            [[mcp_servers.j]]
            command = "x"
            env = { J_TOKEN = "\(g)J" }

            [mcp_servers.k.env]
            K_TOKEN = "\(g)K"

            """, ["j": ["J_TOKEN": g + "J"], "k": ["K_TOKEN": g + "K"]]),
        ]
        for (text, servers) in files {
            let found = scanned(text)
            var listed: [String: [String: String]] = [:]
            for finding in found.findings { listed[finding.location.server, default: [:]][finding.variable] = value(finding) }
            #expect(listed == servers, "\(text)")
            #expect(found.findings.allSatisfy { !$0.movable } && found.unreadable.isEmpty && found.read.count == 1, "\(text)")
        }
    }

    /// 20,000 env tables for one server: listed in time, and not movable.
    @Test func anEnvTableWrittenThousandsOfTimesIsListedInTime() {
        var text = "[mcp_servers.a]\ncommand = \"npx\"\n\n[mcp_servers.a.env]\nGITHUB_TOKEN = \"\(F.github)\"\n"
        for _ in 0..<20_000 { text += "\n[mcp_servers.a.env]\nLOG = \"1\"\n" }
        var found = SecretImport.Scan()
        let took = ContinuousClock().measure { found = scanned(text) }
        #expect(took < .seconds(5), "the scan took \(took)")
        #expect(found.findings.count == 1 && found.findings.first?.notMovable == "repeated keys")
    }
}
