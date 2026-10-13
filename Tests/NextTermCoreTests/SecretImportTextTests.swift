import Foundation
import Testing
@testable import NextTermCore

/// Places in a file are UTF-8 offsets. Text with characters of two, three and four bytes (and a combining mark just after
/// a quote) before an entry and inside it is scanned, planned, written and put back byte for byte, in JSON and in TOML.
/// In ASCII text a UTF-8 offset and a scalar count are the same number, so the other fixtures can't tell them apart.
@Suite struct SecretImportTextTests {
    static let password = "pässwörd-日本-🔑-1234"
    static let apiKey = "clé-secrète-🔐-0001"

    static let cursorJSON = """
        {
          // Serveurs — café ☕️, 日本語, 👨‍👩‍👧 and 🇧🇩
          "mcpServers": {
            "før-ünïcødé": {"command": "npx", "args": ["-y", "srv-ñ", "--label=日本語"],
                            "env": {"NOTE": "\u{0301}naïve ☕️", "GITHUB_TOKEN": "\(F.github)", "DB_PASSWORD": "\(password)"}},
            "après": {"command": "x", "args": ["é"], "env": {"API_KEY": "\(apiKey)"}},
            "fin": {"command": "y", "args": ["🇧🇩"]}
          }
        }

        """

    static let codexTOML = """
        # Réglages — café ☕️, 日本語, 👨‍👩‍👧 and 🇧🇩
        model = "gpt-5"

        [mcp_servers."før-ünïcødé"]
        command = "npx"
        args = ["-y", "srv-ñ", "--label=日本語"]
        env = { NOTE = "\u{0301}naïve ☕️", GITHUB_TOKEN = "\(F.github)", DB_PASSWORD = "\(password)" }

        [mcp_servers."après"]
        command = "x"
        args = ["é"]

        [mcp_servers."après".env]
        API_KEY = "\(apiKey)"

        [profiles."ünï"]
        model = "ñ-🇧🇩"

        """

    /// Scans `relative`, moves GITHUB_TOKEN and API_KEY out of it (DB_PASSWORD stays), checks what was written, puts
    /// both entries back, and gives the file's text after each step.
    func roundTrip(_ home: F.Home, _ relative: String, _ text: String) throws -> (written: String, backups: [SecretImport.EntryBackup]) {
        home.write(relative, text)
        let found = SecretImport.scan(F.sources(home))
        let path = home.file(relative)
        let here = found.findings.filter { $0.source.path == path }
        #expect(Set(here.map(\.variable)) == ["GITHUB_TOKEN", "DB_PASSWORD", "API_KEY"] && found.unreadable.isEmpty)
        let token = try #require(here.first { $0.variable == "GITHUB_TOKEN" })
        let key = try #require(here.first { $0.variable == "API_KEY" })
        let password = try #require(here.first { $0.variable == "DB_PASSWORD" })
        #expect(token.location.server == "før-ünïcødé" && key.location.server == "après" && password.value == SecretBytes(utf8: Self.password))
        #expect(token.lastFour == String(F.github.suffix(4)) && password.lastFour == "1234")

        let moves = [SecretImport.Move(name: "GITHUB_TOKEN", findings: [token]), SecretImport.Move(name: "API_KEY", findings: [key])]
        let planned = SecretImport.plan(moves, nxtrm: F.nxtrm)
        #expect(planned.failures.isEmpty)
        let edit = try #require(planned.edits.first)
        #expect(planned.edits.count == 1 && edit.backups.count == 2)
        let first = try #require(edit.backups.first { $0.location.server == "før-ünïcødé" })
        #expect(first.original.contains("\"⟦nextterm:GITHUB_TOKEN⟧\"") && first.original.contains("\"⟦nextterm:kept:0⟧\"")
                && first.original.contains("\"\u{0301}naïve ☕️\"") && first.original.contains("--label=日本語"))
        #expect(first.keptValues == [SecretBytes(utf8: Self.password)])
        for backup in edit.backups {
            for value in [F.github, Self.password, Self.apiKey] { #expect(!backup.original.contains(value)) }
        }

        #expect(SecretImport.apply(edit) == .written)
        let written = home.read(relative)
        #expect(written == edit.plan.text)
        #expect(!written.contains(F.github) && !written.contains(Self.apiKey) && written.contains(Self.password))
        #expect(written.contains("Serveurs — café ☕️, 日本語, 👨‍👩‍👧 and 🇧🇩") || written.contains("Réglages — café ☕️, 日本語, 👨‍👩‍👧 and 🇧🇩"))

        // Both entries back, one after the other: the file is as it was, byte for byte.
        let values = ["GITHUB_TOKEN": SecretBytes(utf8: F.github), "API_KEY": SecretBytes(utf8: Self.apiKey)]
        for backup in edit.backups.reversed() {
            #expect(SecretImport.undo(backup, values: values, kept: backup.keptValues, home: home.path) == .written)
        }
        #expect(home.data(relative) == Data(text.utf8))
        return (written, edit.backups)
    }

    @Test func multibyteTextInJSONGoesThroughScanPlanWriteAndUndo() throws {
        let home = F.Home()
        defer { home.remove() }
        let (written, _) = try roundTrip(home, ".cursor/mcp.json", Self.cursorJSON)
        let servers = JSONC(written)?.root?.object(in: written) as? [String: Any]
        let all = servers?["mcpServers"] as? [String: Any]
        let moved = all?["før-ünïcødé"] as? [String: Any]
        #expect(moved?["env"] as? [String: String] == ["NOTE": "\u{0301}naïve ☕️", "DB_PASSWORD": Self.password])
        #expect(moved?["args"] as? [String] == ["secret", "run", "GITHUB_TOKEN", "--", "npx", "-y", "srv-ñ", "--label=日本語"])
        #expect((all?["après"] as? [String: Any])?["env"] == nil)
        #expect(written.contains("\"fin\": {\"command\": \"y\", \"args\": [\"🇧🇩\"]}"))
    }

    @Test func multibyteTextInTOMLGoesThroughScanPlanWriteAndUndo() throws {
        let home = F.Home()
        defer { home.remove() }
        let (written, _) = try roundTrip(home, ".codex/config.toml", Self.codexTOML)
        #expect(written.contains("args = [\"secret\", \"run\", \"GITHUB_TOKEN\", \"--\", \"npx\", \"-y\", \"srv-ñ\", \"--label=日本語\"]"))
        #expect(written.contains("env = { NOTE = \"\u{0301}naïve ☕️\", DB_PASSWORD = \"\(Self.password)\" }"))
        #expect(written.contains("args = [\"secret\", \"run\", \"API_KEY\", \"--\", \"x\", \"é\"]"))
        #expect(written.hasSuffix("[profiles.\"ünï\"]\nmodel = \"ñ-🇧🇩\"\n"))
    }
}
