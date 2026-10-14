import Foundation
import Testing
@testable import NextTermCore

/// A wrapped entry drops the env variables `nxtrm secret run` takes out when it starts the server (every stored key's
/// name but the ones the entry asks for), so the file never says a server gets a variable it doesn't. The sheet names
/// each one, and Undo puts them back with the rest of the entry (review finding #18). No value here is a real key.
@Suite struct SecretImportStrippedEnvTests {
    static let anthropicA = "made-up-anthropic-value-a-0123"
    static let anthropicB = "made-up-anthropic-value-b-4567"
    static let anthropicC = "made-up-anthropic-value-c-89ab"
    static let openai = "made-up-openai-value-d-cdef"
    static let token = "made-up-token-value-e-0246"

    func finding(_ home: F.Home, _ variable: String, server: String) -> SecretImport.Finding? {
        SecretImport.scan(F.sources(home)).findings.first { $0.variable == variable && $0.location.server == server }
    }

    func servers(_ text: String) -> [String: Any]? {
        (JSONC(text)?.root?.object(in: text) as? [String: Any])?["mcpServers"] as? [String: Any]
    }

    /// Servers a and b both set ANTHROPIC_API_KEY, to different values, and b also OPENAI_API_KEY. Moving a's Anthropic
    /// key and b's OpenAI key wraps b with OPENAI_API_KEY alone, so b's ANTHROPIC_API_KEY, now a stored key's name,
    /// would be taken out at start: it leaves the entry too, and the edit names it.
    @Test func aVariableNamedLikeAKeyAnotherEntryMovesIsTakenOut() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".gemini/settings.json", """
            {"mcpServers": {
              "a": {"command": "srv-a", "env": {"ANTHROPIC_API_KEY": "\(Self.anthropicA)"}},
              "b": {"command": "srv-b", "env": {"ANTHROPIC_API_KEY": "\(Self.anthropicB)", "OPENAI_API_KEY": "\(Self.openai)", "LOG_LEVEL": "debug"}}
            }}

            """)
        let a = try #require(finding(home, "ANTHROPIC_API_KEY", server: "a"))
        let b = try #require(finding(home, "OPENAI_API_KEY", server: "b"))
        let moves = [SecretImport.Move(name: "ANTHROPIC_API_KEY", findings: [a]), SecretImport.Move(name: "OPENAI_API_KEY", findings: [b])]
        let planned = SecretImport.plan(moves, nxtrm: F.nxtrm)
        let edit = try #require(planned.edits.first)
        #expect(planned.failures.isEmpty)
        #expect(edit.dropped.map(\.server) == ["b"] && edit.dropped.first?.variables == ["ANTHROPIC_API_KEY"])
        #expect(SecretImport.apply(edit) == .written)
        let after = home.read(".gemini/settings.json")
        let entry = try #require(servers(after)?["b"] as? [String: Any])
        #expect(entry["args"] as? [String] == ["secret", "run", "OPENAI_API_KEY", "--", "srv-b"])
        #expect(entry["env"] as? [String: String] == ["LOG_LEVEL": "debug"])
        #expect(!after.contains(Self.anthropicB) && !after.contains(Self.anthropicA))
        // Undo puts b back as it was, the variable taken out included.
        let backup = try #require(edit.backups.first { $0.location.server == "b" })
        let values = ["OPENAI_API_KEY": SecretBytes(utf8: Self.openai)]
        #expect(SecretImport.undo(backup, values: values, kept: backup.keptValues, home: home.path) == .written)
        let restored = try #require(servers(home.read(".gemini/settings.json"))?["b"] as? [String: Any])
        let env = restored["env"] as? [String: String]
        #expect(env == ["ANTHROPIC_API_KEY": Self.anthropicB, "OPENAI_API_KEY": Self.openai, "LOG_LEVEL": "debug"])
    }

    /// A variable named like a key the vault already holds is taken out too, whatever its value (a reference or a
    /// plain setting), unless the entry asks for that name; one named like nothing stored stays.
    @Test func aVariableNamedLikeAStoredKeyIsTakenOutUnlessTheEntryAsksForIt() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".gemini/settings.json", """
            {"mcpServers": {
              "c": {"command": "srv-c", "env": {"C_TOKEN": "\(Self.token)", "SEARCH_URL": "https://search.invalid", "GITHUB_TOKEN": "${GITHUB_TOKEN}", "LOG_LEVEL": "debug"}}
            }}

            """)
        let c = try #require(finding(home, "C_TOKEN", server: "c"))
        let stored = ["C_TOKEN", "GITHUB_TOKEN", "SEARCH_URL", "UNUSED_KEY"]
        let planned = SecretImport.plan([SecretImport.Move(name: "C_TOKEN_2", findings: [c])], nxtrm: F.nxtrm, stored: stored)
        let edit = try #require(planned.edits.first)
        #expect(planned.failures.isEmpty)
        #expect(edit.dropped.map(\.server) == ["c"] && edit.dropped.first?.variables == ["GITHUB_TOKEN", "SEARCH_URL"])
        #expect(SecretImport.apply(edit) == .written)
        let entry = try #require(servers(home.read(".gemini/settings.json"))?["c"] as? [String: Any])
        #expect(entry["args"] as? [String] == ["secret", "run", "C_TOKEN_2=C_TOKEN", "--", "srv-c"])
        #expect(entry["env"] as? [String: String] == ["LOG_LEVEL": "debug"])
    }

    /// With nothing stored under a name the entry keeps, nothing more leaves it and the edit names nothing.
    @Test func nothingMoreLeavesWhenNoKeptNameIsAKey() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".gemini/settings.json", """
            {"mcpServers": {"d": {"command": "srv-d", "env": {"D_TOKEN": "\(Self.token)", "LOG_LEVEL": "debug"}}}}

            """)
        let d = try #require(finding(home, "D_TOKEN", server: "d"))
        let edit = try #require(SecretImport.plan([SecretImport.Move(name: "D_TOKEN", findings: [d])], nxtrm: F.nxtrm, stored: ["OTHER"]).edits.first)
        #expect(edit.dropped.isEmpty)
        #expect(SecretImport.apply(edit) == .written)
        let entry = try #require(servers(home.read(".gemini/settings.json"))?["d"] as? [String: Any])
        #expect(entry["env"] as? [String: String] == ["LOG_LEVEL": "debug"])
    }

    /// Codex: the variable leaves an inline env and an env table alike.
    @Test func codexTakesItOutOfAnInlineEnvAndAnEnvTable() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".codex/config.toml", """
            [mcp_servers.a]
            command = "srv-a"
            env = { ANTHROPIC_API_KEY = "\(Self.anthropicA)", LOG = "1" }

            [mcp_servers.b]
            command = "srv-b"
            env = { ANTHROPIC_API_KEY = "\(Self.anthropicB)", OPENAI_API_KEY = "\(Self.openai)", LOG = "1" }

            [mcp_servers.c]
            command = "srv-c"

            [mcp_servers.c.env]
            ANTHROPIC_API_KEY = "\(Self.anthropicC)"
            C_TOKEN = "\(Self.token)"
            MODE = "test"

            """)
        let a = try #require(finding(home, "ANTHROPIC_API_KEY", server: "a"))
        let b = try #require(finding(home, "OPENAI_API_KEY", server: "b"))
        let c = try #require(finding(home, "C_TOKEN", server: "c"))
        let moves = [SecretImport.Move(name: "ANTHROPIC_API_KEY", findings: [a]), SecretImport.Move(name: "OPENAI_API_KEY", findings: [b]),
                     SecretImport.Move(name: "C_TOKEN", findings: [c])]
        let planned = SecretImport.plan(moves, nxtrm: F.nxtrm)
        let edit = try #require(planned.edits.first)
        #expect(planned.failures.isEmpty)
        #expect(edit.dropped.map(\.server) == ["b", "c"] && edit.dropped.map(\.variables) == [["ANTHROPIC_API_KEY"], ["ANTHROPIC_API_KEY"]])
        #expect(SecretImport.apply(edit) == .written)
        let text = home.read(".codex/config.toml")
        let wrappedB = "args = [\"secret\", \"run\", \"OPENAI_API_KEY\", \"--\", \"srv-b\"]\nstartup_timeout_sec = 30\nenv = { LOG = \"1\" }\n"
        #expect(text.contains(wrappedB))
        #expect(text.contains("[mcp_servers.c.env]\nMODE = \"test\"\n"))
        #expect(text.contains("env = { LOG = \"1\" }\n\n[mcp_servers.b]"))
        for value in [Self.anthropicA, Self.anthropicB, Self.anthropicC, Self.openai, Self.token] { #expect(!text.contains(value)) }
        #expect(SecretImport.verify(edit, written: home.data(".codex/config.toml")))
    }

    /// The sheet's line naming what left which server: nothing when nothing did, and a long server name cut short.
    @Test func theSheetNamesWhatLeftEachServer() {
        #expect(SecretImport.droppedText([]) == nil)
        let one = SecretImport.droppedText([(server: "b", variables: ["ANTHROPIC_API_KEY"])])
        #expect(one == "Also taken out, because nxtrm secret run removes the name of every key in Secrets that a server "
                + "doesn’t ask for: ANTHROPIC_API_KEY from “b”. Undo puts it back.")
        let long = String(repeating: "s", count: 100)
        let two = SecretImport.droppedText([(server: "c", variables: ["GITHUB_TOKEN", "SEARCH_URL"]), (server: long, variables: ["A_KEY"])])
        let cut: String = String(repeating: "s", count: 60) + "…"
        #expect(two?.contains("GITHUB_TOKEN and SEARCH_URL from “c”; A_KEY from “\(cut)”. Undo puts them back.") == true)
    }
}
