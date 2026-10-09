import Foundation
import Testing
@testable import NextTermCore

typealias F = SecretImportFixtures

/// The import moves keys out of each client's config in its own format, with per-entry backups that hold no value and
/// an Undo that puts an entry back only while it is what Next Term wrote.
@Suite struct SecretImportTests {
    func scan(_ home: F.Home, projects: [String] = [], isOpen: (String) -> Bool = { _ in false }) -> SecretImport.Scan {
        SecretImport.scan(F.sources(home, projects: projects), isOpen: isOpen)
    }

    func finding(_ scan: SecretImport.Scan, _ variable: String, server: String? = nil) -> SecretImport.Finding? {
        scan.findings.first { $0.variable == variable && (server == nil || $0.location.server == server) }
    }

    /// Moves the one finding named `variable` as `name`, and writes it.
    @discardableResult
    func move(_ home: F.Home, _ variable: String, as name: String, server: String? = nil) -> (edit: SecretImport.FileEdit?, applied: SecretImport.Applied?) {
        let found = scan(home)
        guard let finding = finding(found, variable, server: server) else { return (nil, nil) }
        let planned = SecretImport.plan([SecretImport.Move(name: name, findings: [finding])], nxtrm: F.nxtrm)
        guard let edit = planned.edits.first else { return (nil, nil) }
        return (edit, SecretImport.apply(edit, lockWait: 0.3))
    }

    /// The file as Foundation objects; comments and trailing commas allowed.
    func object(_ text: String) -> [String: Any]? {
        JSONC(text)?.root?.object(in: text) as? [String: Any]
    }

    // MARK: Claude Code

    @Test func claudeCodeUserAndLocalScope() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".claude.json", F.claudeJSON)
        let found = scan(home)
        let user = try #require(finding(found, "GITHUB_PERSONAL_ACCESS_TOKEN"))
        #expect(user.location == SecretImport.Location(container: ["mcpServers"], server: "github") && user.kind == "GitHub token" && user.movable)
        #expect(finding(found, "GITHUB_TOKEN") == nil) // ${GITHUB_TOKEN} is a reference
        #expect(finding(found, "LOG_LEVEL") == nil)
        let local = try #require(finding(found, "OPENAI_API_KEY"))
        #expect(local.location == SecretImport.Location(container: ["projects", "/Users/me/api", "mcpServers"], server: "x'; touch /tmp/p; '"))

        let before = F.claudeJSON
        let planned = SecretImport.plan([SecretImport.Move(name: "GITHUB_TOKEN", findings: [user]),
                                         SecretImport.Move(name: "OPENAI_API_KEY", findings: [local])], nxtrm: F.nxtrm)
        let edit = try #require(planned.edits.first)
        #expect(planned.failures.isEmpty && planned.edits.count == 1 && edit.source.isClaudeConfig)
        #expect(SecretImport.apply(edit, lockWait: 0.3) == .written)
        let after = home.read(".claude.json")
        let json = try #require(object(after))
        let github = (json["mcpServers"] as? [String: Any])?["github"] as? [String: Any]
        #expect(github?["command"] as? String == F.nxtrm[0])
        #expect(github?["args"] as? [String] == ["secret", "run", "GITHUB_TOKEN=GITHUB_PERSONAL_ACCESS_TOKEN", "--", "npx", "-y",
                                                 "@modelcontextprotocol/server-github"])
        #expect(github?["env"] as? [String: String] == ["LOG_LEVEL": "debug"] && github?["type"] as? String == "stdio")
        let project = ((json["projects"] as? [String: Any])?["/Users/me/api"] as? [String: Any])?["mcpServers"] as? [String: Any]
        let odd = project?["x'; touch /tmp/p; '"] as? [String: Any]
        #expect(odd?["args"] as? [String] == ["secret", "run", "OPENAI_API_KEY", "--", "uvx", "openai-mcp"] && odd?["env"] == nil)
        #expect(!after.contains(F.github) && !after.contains(F.openai))
        // Every other byte is as it was: the text outside the two entries.
        #expect(after.hasPrefix(String(before.prefix(upTo: before.range(of: "\"github\": {")!.upperBound))))
        #expect(after.hasSuffix(String(before[before.range(of: "\"tipsHistory\"")!.lowerBound...])))
        #expect(after.contains(#""ref": {"command": "npx", "args": ["ref-server"], "env": {"GITHUB_TOKEN": "${GITHUB_TOKEN}"}}"#))
        #expect(after.contains("\"numStartups\": 12,"))
    }

    @Test func claudeCodesLockIsWaitedForAndAlwaysLetGo() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".claude.json", F.claudeJSON)
        let lock = home.file(".claude.json") + ".lock"
        let user = try #require(finding(scan(home), "GITHUB_PERSONAL_ACCESS_TOKEN"))
        let edit = try #require(SecretImport.plan([SecretImport.Move(name: "GITHUB_TOKEN", findings: [user])], nxtrm: F.nxtrm).edits.first)

        // Claude Code holds it: Next Term waits, then gives up, writing nothing and leaving the folder.
        try FileManager.default.createDirectory(atPath: lock, withIntermediateDirectories: false)
        let started = Date()
        #expect(SecretImport.apply(edit, lockWait: 0.4) == .locked)
        #expect(Date().timeIntervalSince(started) >= 0.35)
        #expect(home.read(".claude.json") == F.claudeJSON && FileManager.default.fileExists(atPath: lock))
        try FileManager.default.removeItem(atPath: lock)

        // Free: Next Term takes it while it reads and writes, then removes it.
        var heldWhileReading = false
        let applied = SecretImport.apply(edit, lockWait: 0.4, read: { path in
            heldWhileReading = heldWhileReading || FileManager.default.fileExists(atPath: lock)
            return SecretImport.readFile(path)
        })
        #expect(applied == .written && heldWhileReading && !FileManager.default.fileExists(atPath: lock))

        // A write that fails, with the lock taken, lets it go too: the file turns read-only while Next Term reads it.
        home.write(".claude.json", F.claudeJSON)
        let again = try #require(finding(scan(home), "GITHUB_PERSONAL_ACCESS_TOKEN"))
        let second = try #require(SecretImport.plan([SecretImport.Move(name: "GITHUB_TOKEN", findings: [again])], nxtrm: F.nxtrm).edits.first)
        let failed = SecretImport.apply(second, lockWait: 0.4, read: { path in
            let data = SecretImport.readFile(path)
            chmod(path, 0o400)
            return data
        })
        #expect(failed == .skipped("read-only") && !FileManager.default.fileExists(atPath: lock))
        chmod(home.file(".claude.json"), 0o600)
    }

    @Test func undoOfAClaudeCodeEntryIsTheSameEditUnderTheSameLock() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".claude.json", F.claudeJSON)
        let (edit, applied) = move(home, "GITHUB_PERSONAL_ACCESS_TOKEN", as: "GITHUB_TOKEN")
        let backup = try #require(edit?.backups.first)
        #expect(applied == .written)
        let lock = home.file(".claude.json") + ".lock"
        try FileManager.default.createDirectory(atPath: lock, withIntermediateDirectories: false)
        #expect(SecretImport.undo(backup, values: ["GITHUB_TOKEN": SecretBytes(utf8: F.github)], kept: [], home: home.path, lockWait: 0.3) == .locked)
        try FileManager.default.removeItem(atPath: lock)
        #expect(SecretImport.undo(backup, values: ["GITHUB_TOKEN": SecretBytes(utf8: F.github)], kept: [], home: home.path, lockWait: 0.3) == .written)
        let json = try #require(object(home.read(".claude.json")))
        let github = (json["mcpServers"] as? [String: Any])?["github"] as? [String: Any]
        #expect((github?["env"] as? [String: String])?["GITHUB_PERSONAL_ACCESS_TOKEN"] == F.github && github?["command"] as? String == "npx")
        #expect(!FileManager.default.fileExists(atPath: lock))
    }

    // MARK: Codex

    @Test func codexInlineAndTableEnvAndItsTimeout() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".codex/config.toml", F.codexTOML)
        let found = scan(home)
        let inline = try #require(finding(found, "GITHUB_TOKEN"))
        let table = try #require(finding(found, "STRIPE_SECRET_KEY"))
        let slow = try #require(finding(found, "SLOW_TOKEN"))
        let old = try #require(finding(found, "OLD_API_KEY"))
        let dotted = try #require(finding(found, "DOTTED_TOKEN"))
        #expect(inline.movable && table.movable && slow.movable && old.movable)
        #expect(!dotted.movable && dotted.notMovable?.contains("By hand") == true)
        #expect(finding(found, "STRIPE_MODE") == nil && finding(found, "LOG") == nil)
        let moves = [inline, table, slow, old].map { SecretImport.Move(name: SecretName.suggested(from: $0.variable), findings: [$0]) }
        let edit = try #require(SecretImport.plan(moves, nxtrm: F.nxtrm).edits.first)
        #expect(SecretImport.apply(edit) == .written)
        let text = home.read(".codex/config.toml")
        let outline = try #require(TOMLOutline(text))
        func value(_ server: String, _ key: String) -> String? {
            guard let found = outline.keys.first(where: { $0.table == ["mcp_servers", server] && $0.path == [key] }) else { return nil }
            return SecretImport.bareValue(at: found.value, in: text).text
        }
        #expect(text.contains("[mcp_servers.github]\ncommand = \"\(F.nxtrm[0])\"\nargs = [\"secret\", \"run\", \"GITHUB_TOKEN\", \"--\", \"npx\", \"-y\", \"@modelcontextprotocol/server-github\"]\nstartup_timeout_sec = 30\nenv = { LOG = \"1\" }\n"))
        #expect(value("stripe", "startup_timeout_sec") == "30") // raised from 10
        #expect(text.contains("[mcp_servers.stripe.env]\nSTRIPE_MODE = \"test\"\n"))
        #expect(value("slow", "startup_timeout_sec") == "60") // left at 60
        #expect(text.contains("[mcp_servers.slow]\ncommand = \"\(F.nxtrm[0])\"\nargs = [\"secret\", \"run\", \"SLOW_TOKEN\", \"--\", \"slow-server\"]\nstartup_timeout_sec = 60\n\n"))
        #expect(value("old", "startup_timeout_ms") == "30000" && value("old", "startup_timeout_sec") == nil)
        for value in [F.github, F.stripe, F.openai, F.stripe + "X"] { #expect(!text.contains("\"" + value + "\"")) }
        // The rest of the file as it was.
        #expect(text.hasPrefix("model = \"gpt-5\"\n\n# GitHub, for the agent\n[mcp_servers.github]\n"))
        #expect(text.hasSuffix("[mcp_servers]\ndotted.command = \"dotted-server\"\ndotted.env.DOTTED_TOKEN = \"\(F.github)Z\"\n\n[profiles.fast]\nmodel = \"gpt-5-mini\"\n"))
        #expect(SecretImport.verify(edit, written: home.data(".codex/config.toml")))
    }

    /// The commonest Codex shape: the only env member moves and there is no timeout, so the new lines go where the env
    /// line was taken out. With no args, the args line goes there too.
    @Test func codexEntryWhoseOnlyEnvMemberMoves() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".codex/config.toml", """
            [mcp_servers.github]
            command = "npx"
            args = ["-y", "@modelcontextprotocol/server-github"]
            env = { GITHUB_PERSONAL_ACCESS_TOKEN = "\(F.github)" }

            [mcp_servers.local]
            command = "local-server"
            env = { LOCAL_API_KEY = "\(F.openai)" }

            """)
        let found = scan(home)
        let github = try #require(finding(found, "GITHUB_PERSONAL_ACCESS_TOKEN"))
        let local = try #require(finding(found, "LOCAL_API_KEY"))
        let planned = SecretImport.plan([SecretImport.Move(name: "GITHUB_TOKEN", findings: [github]),
                                         SecretImport.Move(name: "LOCAL_API_KEY", findings: [local])], nxtrm: F.nxtrm)
        #expect(planned.failures.isEmpty)
        let edit = try #require(planned.edits.first)
        #expect(SecretImport.apply(edit, lockWait: 0.3) == .written)
        #expect(home.read(".codex/config.toml") == """
            [mcp_servers.github]
            command = "\(F.nxtrm[0])"
            args = ["secret", "run", "GITHUB_TOKEN=GITHUB_PERSONAL_ACCESS_TOKEN", "--", "npx", "-y", "@modelcontextprotocol/server-github"]
            startup_timeout_sec = 30

            [mcp_servers.local]
            command = "\(F.nxtrm[0])"
            args = ["secret", "run", "LOCAL_API_KEY", "--", "local-server"]
            startup_timeout_sec = 30

            """)
    }

    /// An insertion goes before a change that starts where it does, whatever order they come in; ranges that overlap or
    /// run past the end refuse the edit.
    @Test func replacingOrdersAnInsertionFirstAndRefusesOverlaps() {
        let text = "ab\ncd\n"
        #expect(SecretImport.replacing(text, [(3..<6, ""), (3..<3, "X\n")]) == "ab\nX\n")
        #expect(SecretImport.replacing(text, [(3..<3, "X\n"), (3..<6, "")]) == "ab\nX\n")
        #expect(SecretImport.replacing(text, [(3..<3, "1"), (3..<3, "2")]) == "ab\n12cd\n")
        #expect(SecretImport.replacing(text, [(0..<4, "A"), (2..<5, "B")]) == nil)
        #expect(SecretImport.replacing(text, [(4..<9, "")]) == nil)
    }

    // MARK: JSON clients

    @Test func cursorWithCommentsKeepsThemOutsideTheEntry() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".cursor/mcp.json", F.cursorJSON)
        let found = scan(home)
        #expect(finding(found, "API_KEY") == nil) // ${env:API_KEY}
        let header = try #require(found.findings.first { $0.field == .header("Authorization") })
        #expect(!header.movable && header.notMovable == "takes its key in a header; Next Term can't wrap it yet. Use the server's sign-in if it has one.")
        let argument = try #require(found.findings.first { $0.location.server == "argued" })
        #expect(!argument.movable && argument.notMovable == "the key is in the command's arguments" && argument.field == .argument(1))
        let first = try #require(finding(found, "GITHUB_TOKEN"))
        #expect(first.loses) // a comment inside the entry is lost
        #expect(SecretImport.apply(try #require(SecretImport.plan([SecretImport.Move(name: "GITHUB_TOKEN", findings: [first])],
                                                                  nxtrm: F.nxtrm).edits.first)) == .written)
        let text = home.read(".cursor/mcp.json")
        #expect(text.contains("// Cursor's servers") && text.contains("/* the second copy */") && !text.contains("// the official one"))
        #expect(text.contains(#""github-2": {"command": "npx", "args": ["-y", "gh-lite"], "env": {"GH_TOKEN": ""# + F.github))
        let document = try #require(JSONC(text))
        guard case .object(let root)? = document.root else { return #expect(Bool(false)) }
        #expect(SecretImport.object(at: ["mcpServers"], in: root)?.members.count == 5)
    }

    @Test func opencodeHasItsCommandArrayAndEnvironment() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".config/opencode/opencode.json", F.opencodeJSON)
        let found = scan(home)
        #expect(finding(found, "REF") == nil) // {env:REF}
        let (_, applied) = move(home, "TAVILY_API_KEY", as: "TAVILY_API_KEY")
        #expect(applied == .written)
        let json = try #require(object(home.read(".config/opencode/opencode.json")))
        let search = (json["mcp"] as? [String: Any])?["search"] as? [String: Any]
        #expect(search?["command"] as? [String] == [F.nxtrm[0], "secret", "run", "TAVILY_API_KEY", "--", "npx", "-y", "search-mcp"])
        #expect(search?["environment"] as? [String: String] == ["REF": "{env:REF}"] && search?["args"] == nil && search?["type"] as? String == "local")
    }

    @Test func vscodeUsesServersAndSkipsInputs() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write("Library/Application Support/Code/User/mcp.json", F.vscodeJSON)
        #expect(finding(scan(home), "ASKED") == nil)
        let (_, applied) = move(home, "FETCH_API_KEY", as: "FETCH_API_KEY")
        #expect(applied == .written)
        let json = try #require(object(home.read("Library/Application Support/Code/User/mcp.json")))
        let fetch = (json["servers"] as? [String: Any])?["fetch"] as? [String: Any]
        #expect(fetch?["args"] as? [String] == ["secret", "run", "FETCH_API_KEY", "--", "uvx", "mcp-fetch"])
        #expect(fetch?["env"] as? [String: String] == ["ASKED": "${input:key}"] && json["inputs"] != nil)
    }

    @Test func eachOtherAgentHasOneKeyMoved() throws {
        let files: [(String, String, String)] = [
            (".copilot/mcp-config.json", "mcpServers", ""), (".gemini/settings.json", "mcpServers", ""),
            (".qwen/settings.json", "mcpServers", "\"$version\": 4, "), (".config/amp/settings.json", "amp.mcpServers", ""),
            (".junie/mcp/mcp.json", "mcpServers", ""), (".commandcode/mcp.json", "mcpServers", ""),
        ]
        for (relative, container, extra) in files {
            let home = F.Home()
            defer { home.remove() }
            home.write(relative, F.standard(container: container, variable: "ONE_API_KEY", value: F.stripe, extra: extra))
            let (edit, applied) = move(home, "ONE_API_KEY", as: "ONE_API_KEY")
            #expect(applied == .written, "\(relative)")
            let json = try #require(object(home.read(relative)), "\(relative)")
            let one = (json[container] as? [String: Any])?["one"] as? [String: Any]
            #expect(one?["command"] as? String == F.nxtrm[0] && one?["env"] == nil, "\(relative)")
            #expect(edit?.backups.first?.original.contains("⟦nextterm:ONE_API_KEY⟧") == true, "\(relative)")
        }
    }

    @Test func theClaudeAppsStrictFileStaysPlainJSON() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write("Library/Application Support/Claude/claude_desktop_config.json", F.claudeAppJSON)
        // While the Claude app is open, the row says to quit it.
        let open = scan(home) { $0 == MCPRegistrar.claudeAppBundle }
        #expect(finding(open, "GITHUB_TOKEN")?.notMovable == SecretImport.claudeAppOpenReason)
        let (_, applied) = move(home, "GITHUB_TOKEN", as: "GITHUB_TOKEN")
        #expect(applied == .written)
        let text = home.read("Library/Application Support/Claude/claude_desktop_config.json")
        let plain = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        #expect(plain?["preferences"] != nil && !text.contains(F.github))
    }

    @Test func aByteOrderMarkStaysAndOddFilesAreSkipped() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".gemini/settings.json", F.standard(container: "mcpServers", variable: "ONE_TOKEN", value: F.openai), bom: true)
        let (_, applied) = move(home, "ONE_TOKEN", as: "ONE_TOKEN")
        #expect(applied == .written && home.data(".gemini/settings.json").starts(with: [0xEF, 0xBB, 0xBF]))

        // Read-only, and a link to a file that is not there.
        home.write(".qwen/settings.json", F.standard(container: "mcpServers", variable: "ONE_TOKEN", value: F.openai))
        let found = try #require(scan(home).findings.first { $0.source.path == home.file(".qwen/settings.json") })
        let edit = try #require(SecretImport.plan([SecretImport.Move(name: "ONE_TOKEN", findings: [found])], nxtrm: F.nxtrm).edits.first)
        chmod(home.file(".qwen/settings.json"), 0o400)
        #expect(SecretImport.apply(edit) == .skipped("read-only"))
        chmod(home.file(".qwen/settings.json"), 0o600)
        try FileManager.default.removeItem(atPath: home.file(".qwen/settings.json"))
        try FileManager.default.createSymbolicLink(atPath: home.file(".qwen/settings.json"), withDestinationPath: home.file("gone.json"))
        #expect(SecretImport.apply(edit) == .skipped("a link to a file that is not there"))
        #expect(scan(home).findings.allSatisfy { $0.source.path != home.file(".qwen/settings.json") })
    }

    // MARK: groups and backups

    /// One entry holding a value under two variables gets a key for each, and every entry's new args parse as the
    /// wrapper's. Moves that give both variables one name are refused, and the file is left as it was.
    @Test func anEntryHoldingOneValueUnderTwoVariables() throws {
        let home = F.Home()
        defer { home.remove() }
        let settings = """
            {
              "mcpServers": {
                "github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"],
                           "env": {"GITHUB_TOKEN": "\(F.github)", "GITHUB_PERSONAL_ACCESS_TOKEN": "\(F.github)"}},
                "lite": {"command": "npx", "args": ["-y", "gh-lite"], "env": {"GH_TOKEN": "\(F.github)"}}
              }
            }

            """
        home.write(".gemini/settings.json", settings)
        let found = scan(home)
        let groups = SecretImport.groups(found.findings, stored: [])
        #expect(groups.map(\.name) == ["GITHUB_TOKEN", "GITHUB_PERSONAL_ACCESS_TOKEN"])
        #expect(groups.first?.findings.map(\.variable) == ["GITHUB_TOKEN", "GH_TOKEN"])
        let moves = groups.map { SecretImport.Move(name: $0.name, findings: $0.findings) }
        let planned = SecretImport.plan(moves, nxtrm: F.nxtrm)
        #expect(planned.failures.isEmpty)
        let edit = try #require(planned.edits.first)
        #expect(SecretImport.apply(edit, lockWait: 0.3) == .written)
        let servers = try #require(object(home.read(".gemini/settings.json"))?["mcpServers"] as? [String: Any])
        let github = (servers["github"] as? [String: Any])?["args"] as? [String]
        #expect(github == ["secret", "run", "GITHUB_TOKEN", "GITHUB_PERSONAL_ACCESS_TOKEN", "--", "npx", "-y",
                           "@modelcontextprotocol/server-github"])
        for server in ["github", "lite"] {
            let args = try #require((servers[server] as? [String: Any])?["args"] as? [String], "\(server)")
            #expect(Array(args.prefix(2)) == ["secret", "run"], "\(server)")
            if case .failure(let error) = SecretRun.parse(Array(args.dropFirst(2))) { Issue.record("\(server): \(error.reason)") }
        }

        home.write(".gemini/settings.json", settings)
        let both = scan(home).findings.filter { $0.location.server == "github" }
        #expect(both.count == 2)
        let refused = SecretImport.plan([SecretImport.Move(name: "GITHUB_TOKEN", findings: both)], nxtrm: F.nxtrm)
        #expect(refused.edits.isEmpty)
        #expect(refused.failures.first?.reason.contains("GITHUB_TOKEN is named twice") == true)
        #expect(home.read(".gemini/settings.json") == settings)
    }

    @Test func oneValueInThreeServersIsOneGroup() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".cursor/mcp.json", F.cursorJSON)
        home.write(".codex/config.toml", F.codexTOML)
        let found = scan(home)
        let groups = SecretImport.groups(found.findings, stored: [])
        let github = try #require(groups.first { $0.value == SecretBytes(utf8: F.github) })
        #expect(github.findings.count == 3 && github.name == "GITHUB_TOKEN" && github.summary == "Same value in 3 servers")
        // A clash with a stored key adds _2.
        let clashing = SecretImport.groups(found.findings, stored: ["GITHUB_TOKEN"])
        #expect(clashing.first { $0.value == SecretBytes(utf8: F.github) }?.name == "GITHUB_TOKEN_2")
        // Not movable rows are not grouped.
        #expect(groups.allSatisfy { $0.findings.allSatisfy(\.movable) })

        // AE9: the three entries run the wrapper, Codex's gains its timeout, and the backups hold markers, never the token.
        let planned = SecretImport.plan([SecretImport.Move(name: "GITHUB_TOKEN", findings: github.findings)], nxtrm: F.nxtrm)
        #expect(planned.edits.count == 2 && planned.failures.isEmpty)
        for edit in planned.edits { #expect(SecretImport.apply(edit) == .written) }
        let codex = home.read(".codex/config.toml")
        #expect(codex.contains("args = [\"secret\", \"run\", \"GITHUB_TOKEN\", \"--\", \"npx\", \"-y\", \"@modelcontextprotocol/server-github\"]\nstartup_timeout_sec = 30"))
        let cursor = try #require(object(home.read(".cursor/mcp.json")))
        let second = (cursor["mcpServers"] as? [String: Any])?["github-2"] as? [String: Any]
        #expect(second?["args"] as? [String] == ["secret", "run", "GITHUB_TOKEN=GH_TOKEN", "--", "npx", "-y", "gh-lite"])
        let backups = planned.edits.flatMap(\.backups)
        #expect(backups.count == 3)
        for backup in backups {
            let record = String(decoding: backup.encoded() ?? Data(), as: UTF8.self)
            #expect(backup.original.contains("⟦nextterm:GITHUB_TOKEN⟧") && !record.contains(F.github) && !record.contains("Ab1Cd2Ef3"))
        }
    }

    @Test func aBackupMarksMovedAndKeptValuesAndHoldsNoOtherServer() throws {
        let home = F.Home()
        defer { home.remove() }
        let text = """
            {"mcpServers": {
              "both": {"command": "srv", "args": ["--token", "\(F.openai)"], "env": {"A_TOKEN": "\(F.github)", "B_SECRET": "\(F.stripe)"}},
              "other": {"command": "x", "env": {"OTHER_KEY": "other-secret-value-1234"}}
            }}

            """
        home.write(".gemini/settings.json", text)
        let found = scan(home)
        let moved = try #require(finding(found, "A_TOKEN"))
        let edit = try #require(SecretImport.plan([SecretImport.Move(name: "A_TOKEN", findings: [moved])], nxtrm: F.nxtrm).edits.first)
        let backup = try #require(edit.backups.first)
        #expect(backup.original.contains("\"⟦nextterm:A_TOKEN⟧\"") && backup.original.contains("\"⟦nextterm:kept:0⟧\"")
                && backup.original.contains("\"⟦nextterm:kept:1⟧\""))
        #expect(backup.keptCount == 2 && backup.keptValues == [SecretBytes(utf8: F.openai), SecretBytes(utf8: F.stripe)])
        for value in [F.github, F.openai, F.stripe, "other-secret-value-1234", "OTHER_KEY"] { #expect(!backup.original.contains(value)) }
        #expect(!String(decoding: backup.encoded() ?? Data(), as: UTF8.self).contains(F.stripe))
        // Kept values stay in the file: only the moved one leaves it.
        #expect(SecretImport.apply(edit) == .written)
        let after = home.read(".gemini/settings.json")
        #expect(after.contains(F.openai) && after.contains(F.stripe) && !after.contains(F.github))
        // Undo fills both kinds of marker.
        #expect(SecretImport.undo(backup, values: ["A_TOKEN": SecretBytes(utf8: F.github)], kept: backup.keptValues, home: home.path) == .written)
        let restored = try #require(object(home.read(".gemini/settings.json")))
        let both = (restored["mcpServers"] as? [String: Any])?["both"] as? [String: Any]
        #expect(both?["env"] as? [String: String] == ["A_TOKEN": F.github, "B_SECRET": F.stripe] && both?["args"] as? [String] == ["--token", F.openai])
    }

    @Test func verifyAndUndoFollowTheEntry() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".cursor/mcp.json", F.cursorJSON)
        let (edit, applied) = move(home, "GITHUB_TOKEN", as: "GITHUB_TOKEN", server: "github")
        let backup = try #require(edit?.backups.first)
        #expect(applied == .written)
        let written = home.read(".cursor/mcp.json")
        #expect(SecretImport.verify(try #require(edit), written: Data(written.utf8)))
        // Another server changed, or the entry Next Term wrote: verify fails either way.
        let otherChanged = written.replacingOccurrences(of: "gh-lite", with: "gh-lite-2")
        #expect(!SecretImport.verify(try #require(edit), written: Data(otherChanged.utf8)))
        let entryChanged = written.replacingOccurrences(of: "\"secret\",\"run\"", with: "\"secret\",\"run\",\"-v\"")
        #expect(!SecretImport.verify(try #require(edit), written: Data(entryChanged.utf8)))
        // Undo after another part of the file changed puts the entry back and keeps that change.
        let values = ["GITHUB_TOKEN": SecretBytes(utf8: F.github)]
        guard case .text(let restored) = SecretImport.undoPlan(backup, current: otherChanged, values: values, kept: backup.keptValues) else {
            return #expect(Bool(false))
        }
        #expect(restored.contains("gh-lite-2") && restored.contains(F.github) && restored.contains("// the official one"))
        #expect(SecretImport.undoPlan(backup, current: entryChanged, values: values, kept: []) == .changedSince)
        #expect(SecretImport.undoPlan(backup, current: written, values: [:], kept: []) == .keyMissing("GITHUB_TOKEN"))
        // And the TOML way round: Codex rewrote other parts of its file.
        home.write(".codex/config.toml", F.codexTOML)
        let (codexEdit, codexApplied) = move(home, "GITHUB_TOKEN", as: "GITHUB_TOKEN", server: "github")
        let codexBackup = try #require(codexEdit?.backups.first)
        #expect(codexApplied == .written)
        let rewritten = home.read(".codex/config.toml").replacingOccurrences(of: "model = \"gpt-5\"", with: "model = \"gpt-6\"")
        home.write(".codex/config.toml", rewritten)
        #expect(SecretImport.undo(codexBackup, values: values, kept: codexBackup.keptValues, home: home.path) == .written)
        let back = home.read(".codex/config.toml")
        #expect(back.contains("model = \"gpt-6\"") && back.contains("env = { GITHUB_TOKEN = \"\(F.github)\", LOG = \"1\" }")
                && back.contains("command = \"npx\"") && !back.contains("startup_timeout_sec = 30\nenv"))
    }

    @Test func aFileSavedSinceThePlanIsPlannedOnceMore() throws {
        let home = F.Home()
        defer { home.remove() }
        home.write(".cursor/mcp.json", F.cursorJSON)
        let first = try #require(finding(scan(home), "GITHUB_TOKEN", server: "github"))
        let edit = try #require(SecretImport.plan([SecretImport.Move(name: "GITHUB_TOKEN", findings: [first])], nxtrm: F.nxtrm).edits.first)
        // Cursor saved another server meanwhile: planned again, written, and that change kept.
        home.write(".cursor/mcp.json", F.cursorJSON.replacingOccurrences(of: "gh-lite", with: "gh-lite-2"))
        #expect(SecretImport.apply(edit) == .written)
        let text = home.read(".cursor/mcp.json")
        #expect(text.contains("gh-lite-2") && text.contains("\"secret\",\"run\",\"GITHUB_TOKEN\""))
        // The entry itself changed meanwhile: left as it is.
        home.write(".cursor/mcp.json", F.cursorJSON.replacingOccurrences(of: "\"-y\", \"@modelcontextprotocol", with: "\"@modelcontextprotocol"))
        let before = home.read(".cursor/mcp.json")
        #expect(SecretImport.apply(edit) == .changed && home.read(".cursor/mcp.json") == before)
    }

    @Test func namesAndReferences() {
        for name in ["GITHUB_PERSONAL_ACCESS_TOKEN", "api-key", "apiKey", "GH_PAT", "DB_PASSWORD", "CREDENTIALS", "APIKEY", "AUTH"] {
            #expect(SecretImport.nameLooksSecret(name), "\(name)")
        }
        for name in ["PATH", "AUTHOR", "LOG_LEVEL", "MONKEY_COUNT", "KEYBOARD"] { #expect(!SecretImport.nameLooksSecret(name), "\(name)") }
        for value in ["${X}", "$X", "{env:X}", "{file:./x}", "${input:k}", "${user_config.key}", "op://vault/item/field"] {
            #expect(SecretImport.detect(name: "API_KEY", value: value) == nil, "\(value)")
        }
        #expect(SecretImport.detect(name: "LOG_LEVEL", value: "debug") == nil)
        #expect(SecretImport.detect(name: "API_KEY", value: "short") == nil)
        #expect(SecretImport.detect(name: "WHATEVER", value: F.github) == "GitHub token")
        #expect(SecretImport.detect(name: "WHATEVER", value: "Zq8Lm2Np7Rt4Vx9Bc3Df6Gh") == "a key, by its shape")
        #expect(SecretImport.detect(name: "DB_PASSWORD", value: "correct horse battery") == "a key, by its name")
        #expect(SecretImport.valueRefusal(variable: "api_key", value: "x")?.contains("can't set") == true)
        #expect(SecretImport.valueRefusal(variable: "NODE_OPTIONS", value: "x")?.contains("can't set") == true)
        // "\r\n" is one Character, so the line break is looked for by scalar.
        #expect(SecretImport.valueRefusal(variable: "API_KEY", value: "abc\r\ndef")?.contains("line breaks") == true)
    }
}
