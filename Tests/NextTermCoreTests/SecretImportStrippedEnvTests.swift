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
    static let openaiOther = "made-up-openai-value-f-1357"
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

    /// A move whose every file can't be planned stores nothing, so no other entry drops a variable of its name: the
    /// OpenAI key moved from Cursor's x, whose file can't be read, leaves Gemini's y its own OPENAI_API_KEY, which the
    /// wrapper never takes out. A name the vault holds already is taken out all the same.
    @Test func aMoveWhoseFileCantBePlannedTakesNothingOutElsewhere() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".cursor/mcp.json", """
            {"mcpServers": {"x": {"command": "srv-x", "env": {"OPENAI_API_KEY": "\(Self.openai)"}}}}

            """)
        home.write(".gemini/settings.json", """
            {"mcpServers": {"y": {"command": "srv-y", "env": {"ANTHROPIC_API_KEY": "\(Self.anthropicB)", "OPENAI_API_KEY": "\(Self.openaiOther)"}}}}

            """)
        let x = try #require(finding(home, "OPENAI_API_KEY", server: "x"))
        let y = try #require(finding(home, "ANTHROPIC_API_KEY", server: "y"))
        let moves = [SecretImport.Move(name: "OPENAI_API_KEY", findings: [x]), SecretImport.Move(name: "ANTHROPIC_API_KEY", findings: [y])]
        let cursor: String = x.source.path
        let unreadable: (String) -> Data? = { $0 == cursor ? nil : SecretImport.readFile($0) }
        let planned = SecretImport.plan(moves, nxtrm: F.nxtrm, read: unreadable)
        #expect(planned.failures.map(\.path) == [cursor])
        let edit = try #require(planned.edits.first)
        #expect(edit.names == ["ANTHROPIC_API_KEY"])
        #expect(edit.dropped.isEmpty)
        // The vault holds an OPENAI_API_KEY already: the wrapper takes it out, so y drops it whatever Cursor's file does.
        let held = SecretImport.plan(moves, nxtrm: F.nxtrm, stored: ["OPENAI_API_KEY"], read: unreadable)
        #expect(held.edits.first?.dropped.first?.variables == ["OPENAI_API_KEY"])
        #expect(SecretImport.apply(edit) == .written)
        let entry = try #require(servers(home.read(".gemini/settings.json"))?["y"] as? [String: Any])
        #expect(entry["env"] as? [String: String] == ["OPENAI_API_KEY": Self.openaiOther])
    }

    /// The same when the file reads but its key changed since the scan: that move stores nothing either.
    @Test func aMoveWhoseKeyChangedSinceTheScanTakesNothingOutElsewhere() throws {
        let home = F.Home()
        defer { home.remove() }
        let cursorText = """
            {"mcpServers": {"x": {"command": "srv-x", "env": {"OPENAI_API_KEY": "\(Self.openai)"}}}}

            """
        home.write(".cursor/mcp.json", cursorText)
        home.write(".gemini/settings.json", """
            {"mcpServers": {"y": {"command": "srv-y", "env": {"ANTHROPIC_API_KEY": "\(Self.anthropicB)", "OPENAI_API_KEY": "\(Self.openaiOther)"}}}}

            """)
        let x = try #require(finding(home, "OPENAI_API_KEY", server: "x"))
        let y = try #require(finding(home, "ANTHROPIC_API_KEY", server: "y"))
        home.write(".cursor/mcp.json", cursorText.replacingOccurrences(of: Self.openai, with: Self.token))
        let moves = [SecretImport.Move(name: "OPENAI_API_KEY", findings: [x]), SecretImport.Move(name: "ANTHROPIC_API_KEY", findings: [y])]
        let planned = SecretImport.plan(moves, nxtrm: F.nxtrm)
        #expect(planned.failures.map(\.path) == [x.source.path])
        let edit = try #require(planned.edits.first)
        #expect(edit.names == ["ANTHROPIC_API_KEY"] && edit.dropped.isEmpty)
    }

    /// A file saved by its agent between the plan and the write is planned once more with the same names taken out:
    /// the write still drops b's ANTHROPIC_API_KEY and keeps the agent's change. Without them, JSON would read as
    /// changed and TOML would write the variable back.
    @Test func aFileSavedSinceThePlanStillDropsTheVariable() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".gemini/settings.json", """
            {"mcpServers": {
              "a": {"command": "srv-a", "env": {"ANTHROPIC_API_KEY": "\(Self.anthropicA)"}},
              "b": {"command": "srv-b", "env": {"ANTHROPIC_API_KEY": "\(Self.anthropicB)", "OPENAI_API_KEY": "\(Self.openai)"}},
              "e": {"command": "srv-e", "env": {"LOG_LEVEL": "info"}}
            }}

            """)
        let a = try #require(finding(home, "ANTHROPIC_API_KEY", server: "a"))
        let b = try #require(finding(home, "OPENAI_API_KEY", server: "b"))
        let moves = [SecretImport.Move(name: "ANTHROPIC_API_KEY", findings: [a]), SecretImport.Move(name: "OPENAI_API_KEY", findings: [b])]
        let edit = try #require(SecretImport.plan(moves, nxtrm: F.nxtrm).edits.first)
        let saved: String = home.read(".gemini/settings.json").replacingOccurrences(of: "\"info\"", with: "\"warn\"")
        home.write(".gemini/settings.json", saved)
        #expect(SecretImport.apply(edit) == .written)
        let after = try #require(servers(home.read(".gemini/settings.json")))
        #expect((after["b"] as? [String: Any])?["env"] == nil)
        #expect((after["e"] as? [String: Any])?["env"] as? [String: String] == ["LOG_LEVEL": "warn"])
    }

    /// Codex: the same, from an inline env and an env table.
    @Test func aCodexFileSavedSinceThePlanStillDropsTheVariable() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".codex/config.toml", """
            [mcp_servers.a]
            command = "srv-a"
            env = { ANTHROPIC_API_KEY = "\(Self.anthropicA)" }

            [mcp_servers.b]
            command = "srv-b"
            env = { ANTHROPIC_API_KEY = "\(Self.anthropicB)", OPENAI_API_KEY = "\(Self.openai)", LOG = "1" }

            [mcp_servers.c]
            command = "srv-c"

            [mcp_servers.c.env]
            ANTHROPIC_API_KEY = "\(Self.anthropicC)"
            C_TOKEN = "\(Self.token)"
            MODE = "test"

            [mcp_servers.e]
            command = "srv-e"

            """)
        let a = try #require(finding(home, "ANTHROPIC_API_KEY", server: "a"))
        let b = try #require(finding(home, "OPENAI_API_KEY", server: "b"))
        let c = try #require(finding(home, "C_TOKEN", server: "c"))
        let moves = [SecretImport.Move(name: "ANTHROPIC_API_KEY", findings: [a]), SecretImport.Move(name: "OPENAI_API_KEY", findings: [b]),
                     SecretImport.Move(name: "C_TOKEN", findings: [c])]
        let edit = try #require(SecretImport.plan(moves, nxtrm: F.nxtrm).edits.first)
        home.write(".codex/config.toml", home.read(".codex/config.toml").replacingOccurrences(of: "\"srv-e\"", with: "\"srv-e2\""))
        #expect(SecretImport.apply(edit) == .written)
        let text = home.read(".codex/config.toml")
        #expect(text.contains("command = \"srv-e2\""))
        for value in [Self.anthropicB, Self.anthropicC] { #expect(!text.contains(value)) }
        #expect(!text.contains("ANTHROPIC_API_KEY ="))
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
