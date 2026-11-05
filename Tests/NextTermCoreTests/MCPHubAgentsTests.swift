import Foundation
import Testing
@testable import NextTermCore

/// The MCP hub's ways in from agents: Found in your agents (R9), the servers in agents' own configs, read only, one row a
/// server; the one offer for a server added to one after the update (R11), never for what was there; and the agent tools
/// add_mcp_server and list_mcp_servers (R10), which refuse a key before anyone is asked and never answer one.
@Suite struct MCPHubAgentsTests {
    let home: String
    let token = "ghp_" + String(repeating: "A1b2", count: 9)

    init() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("nt-mcphub-agents-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true)
        home = canonicalPath(made)
    }

    func write(_ text: String, to relative: String) throws -> String {
        let file = home + "/" + relative
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Codex's, Claude Code's and Cursor's files, and OpenCode's, as their agents write them.
    func agentFiles() throws -> [SecretImport.Source] {
        let codex = try write("""
            model = "o3"

            [mcp_servers.linear]
            command = "npx"
            args = ["-y", "linear-mcp@2.1.0"]

            [mcp_servers.linear.env]
            LINEAR_API_KEY = "lin_api_8fK2pQz7LmN4vX9tR1sW6yB3cD5eH0jA"
            LOG_LEVEL = "info"

            [mcp_servers.docs]
            url = "https://mcp.docs.example.com/mcp"
            bearer_token_env_var = "DOCS_TOKEN"

            [mcp_servers.next-term]
            command = "nxtrm"
            args = ["mcp"]
            """, to: ".codex/config.toml")
        let claude = try write("""
            {"numStartups": 4, "mcpServers": {
              "github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github@2025.4.8"], "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "\(token)"}},
              "next-term": {"command": "/Applications/Next Term.app/Contents/MacOS/NextTerm", "args": ["--cli", "mcp"]}
            }, "projects": {"/Users/me/Code/app": {"mcpServers": {"app-db": {"command": "db-mcp", "args": ["--read-only"]}}}}}
            """, to: ".claude.json")
        let cursor = try write("""
            {
              // Cursor's
              "mcpServers": {"github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github@2025.4.8"], "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "\(token)"}}}
            }
            """, to: ".cursor/mcp.json")
        let opencode = try write("""
            {"mcp": {"browser": {"type": "local", "command": ["npx", "-y", "browser-mcp@1.0.0"], "environment": {"HEADLESS": "1"}}}}
            """, to: ".config/opencode/opencode.json")
        return [
            SecretImport.Source(path: codex, client: .codex, format: .toml, containers: [["mcp_servers"]]),
            SecretImport.Source(path: claude, client: .claudeCode, format: .json, containers: nil),
            SecretImport.Source(path: cursor, client: .cursor, format: .json, containers: [["mcpServers"]]),
            SecretImport.Source(path: opencode, client: .opencode, format: .json, containers: [["mcp"]]),
        ]
    }

    // MARK: Found in your agents (R9)

    @Test func everyAgentsServersAreFoundOnceEachWithTheirKeysOutForSecrets() throws {
        let sources = try agentFiles()
        let before = try sources.map { try Data(contentsOf: URL(fileURLWithPath: $0.path)) }
        let found = MCPHubAgents.servers(in: sources)
        #expect(found.map(\.name) == ["linear", "docs", "github", "app-db", "browser"])
        // Next Term's own entry is never one, by name or by its command.
        #expect(!found.contains { $0.name.hasPrefix("next-term") })

        // One server in two agents is one row naming both.
        let github = try #require(found.first { $0.name == "github" })
        #expect(github.agents == [.claudeCode, .cursor] && github.agentsText == "Claude Code and Cursor" && github.files.count == 2)
        #expect(github.runs == "npx -y @modelcontextprotocol/server-github@2025.4.8")
        #expect(github.found.keys.map(\.name) == ["GITHUB_PERSONAL_ACCESS_TOKEN"] && github.found.keys.first?.kind != nil)
        // Added, the key is a reference: never the value.
        let made = try github.found.server().get()
        #expect(made.command == "nxtrm" && made.args.prefix(4) == ["secret", "run", "GITHUB_PERSONAL_ACCESS_TOKEN", "--"])
        #expect(!(made.args + Array(made.env.values)).contains(token))

        // Codex's env table, its key out and the rest kept; its bearer variable a key it asks for.
        let linear = try #require(found.first { $0.name == "linear" })
        #expect(linear.agentsText == "Codex" && linear.found.keys.map(\.name) == ["LINEAR_API_KEY"])
        #expect(try linear.found.server().get().env == ["LOG_LEVEL": "info"])
        let docs = try #require(found.first { $0.name == "docs" })
        #expect(docs.runs == "https://mcp.docs.example.com/mcp" && docs.found.keys.count == 1 && docs.found.keys[0].value == nil)
        // Claude Code's servers for one project carry that project, for Add's "Only in".
        #expect(found.first { $0.name == "app-db" }?.project == "/Users/me/Code/app")
        // OpenCode's one array and environment are the common shape.
        let browser = try #require(found.first { $0.name == "browser" })
        #expect(try browser.found.server().get().args == ["-y", "browser-mcp@1.0.0"] && browser.runs == "npx -y browser-mcp@1.0.0")
        #expect(try browser.found.server().get().env == ["HEADLESS": "1"])

        // Only read: every agent's file is as it was.
        #expect(try sources.map { try Data(contentsOf: URL(fileURLWithPath: $0.path)) } == before)
    }

    @Test func aServerTheUsersListHasIsNotListedAgain() throws {
        let found = MCPHubAgents.servers(in: try agentFiles())
        let userFile = MCPHubScope.userPath(home: home)
        // github by its name; another name running what linear runs.
        _ = MCPHubScope.save(.set(.local("github", command: "npx", args: ["-y", "other"])), to: userFile, place: .user)
        _ = MCPHubScope.save(.set(.local("my-linear", command: "nxtrm", args: ["secret", "run", "LINEAR_API_KEY", "--", "npx", "-y", "linear-mcp@2.1.0"])),
                             to: userFile, place: .user)
        let user = MCPHubScope.sources(folder: nil, home: home, userFile: userFile).user
        #expect(MCPHubAgents.notAdded(found, user: user).map(\.name) == ["docs", "app-db", "browser"])
        #expect(MCPHubAgents.notAdded(found, user: nil).count == found.count)
    }

    @Test func aFileThatIsntThereOrIsntReadableAddsNothing() throws {
        let missing = SecretImport.Source(path: home + "/.codex/none.toml", client: .codex, format: .toml, containers: [["mcp_servers"]])
        let broken = SecretImport.Source(path: try write("{ not json", to: ".cursor/mcp.json"), client: .cursor, format: .json, containers: [["mcpServers"]])
        #expect(MCPHubAgents.servers(in: [missing, broken]).isEmpty)
    }

    // MARK: the offer (R11)

    func files(_ sources: [SecretImport.Source]) -> [(path: String, read: MCPHubAgents.FileRead)] {
        sources.map { ($0.path, MCPHubAgents.read($0)) }
    }

    @Test func whatWasThereAtTheUpdateIsNeverOfferedAndANewServerIsOfferedOnce() throws {
        let sources = try agentFiles()
        let found = MCPHubAgents.servers(in: sources)
        // The first look of this version: everything there is the baseline, and nothing is offered.
        let first = MCPHubAgents.due(files(sources), seen: nil, added: [])
        #expect(first.offer.isEmpty && first.seen.servers == Set(found.map(\.name)) && first.seen.files == Set(sources.map(\.path)))
        #expect(MCPHubAgents.due(files(sources), seen: first.seen, added: []).offer.isEmpty)

        // Codex gets a new server: it is offered, naming Codex.
        let codex = sources[0]
        var text = try String(contentsOfFile: codex.path, encoding: .utf8)
        text += "\n[mcp_servers.sentry]\ncommand = \"npx\"\nargs = [\"-y\", \"sentry-mcp@0.9.0\"]\n"
        try text.write(toFile: codex.path, atomically: true, encoding: .utf8)
        let second = MCPHubAgents.due(files(sources), seen: first.seen, added: [])
        #expect(second.offer.map(\.name) == ["sentry"])
        #expect(MCPHubAgents.offerText(second.offer[0]) == "Codex has a new MCP server, \u{201C}sentry\u{201D}. Use it in every agent in Next Term?")
        // Once offered (seen as it shows), never again, whatever the answer.
        var seen = second.seen
        seen.servers.insert("sentry")
        #expect(MCPHubAgents.due(files(sources), seen: seen, added: []).offer.isEmpty)
        // One the user added to Next Term first is seen, not offered.
        let added = MCPHubAgents.due(files(sources), seen: first.seen, added: ["sentry"])
        #expect(added.offer.isEmpty && added.seen.servers.contains("sentry"))
    }

    /// An agent's file that couldn't be read at the first look (larger than Secrets reads, or caught mid-save) is no
    /// baseline of nothing: the first time it reads, what it has is its baseline, never an offer. One that wasn't there
    /// at all is: a server it gets later is new.
    @Test func aFileUnreadableAtTheFirstLookIsNeverTakenForNew() throws {
        let sources = try agentFiles()
        let claude = sources[1]
        let whole = try Data(contentsOf: URL(fileURLWithPath: claude.path))
        try Data(whole.prefix(40)).write(to: URL(fileURLWithPath: claude.path)) // half saved
        let cursorConfig = home + "/.cursor/new.json"
        let later = SecretImport.Source(path: cursorConfig, client: .cursor, format: .json, containers: [["mcpServers"]])
        #expect(MCPHubAgents.read(claude) == .unreadable && MCPHubAgents.read(later) == .missing)
        // Too large to read is unreadable too, never missing.
        #expect(MCPHubAgents.read(claude, read: { _ in nil }) == .unreadable)

        let first = MCPHubAgents.due(files(sources + [later]), seen: nil, added: [])
        #expect(first.offer.isEmpty && !first.seen.files.contains(claude.path) && first.seen.files.contains(cursorConfig))
        #expect(!first.seen.servers.contains("app-db"))

        // Its save done, Claude Code's servers are its baseline: nothing offered, app-db included.
        try whole.write(to: URL(fileURLWithPath: claude.path))
        let second = MCPHubAgents.due(files(sources + [later]), seen: first.seen, added: [])
        #expect(second.offer.isEmpty && second.seen.servers.isSuperset(of: ["github", "app-db"]) && second.seen.files.contains(claude.path))

        // A file that wasn't there at the first look: what it gets is new.
        _ = try write(#"{"mcpServers": {"figma": {"command": "npx", "args": ["-y", "figma-mcp@1.0.0"]}}}"#, to: ".cursor/new.json")
        #expect(MCPHubAgents.due(files(sources + [later]), seen: second.seen, added: []).offer.map(\.name) == ["figma"])
    }

    /// A key Found in your agents can't take out (one in an argument, or in the URL) is masked in what it runs, so
    /// Settings never shows it.
    @Test func aKeyLeftInAFoundServersCommandIsNeverShown() throws {
        let file = try write("""
            {"mcpServers": {"stripe": {"command": "npx", "args": ["-y", "stripe-mcp@1.0.0", "--api-key", "\(token)"]},
             "hosted": {"url": "https://mcp.example.com/mcp?token=\(token)"}}}
            """, to: ".cursor/mcp.json")
        let found = MCPHubAgents.servers(in: [SecretImport.Source(path: file, client: .cursor, format: .json, containers: [["mcpServers"]])])
        #expect(found.map(\.name) == ["stripe", "hosted"])
        #expect(found.allSatisfy { !$0.runs.contains(token) })
        #expect(found[0].runs.hasPrefix("npx -y stripe-mcp@1.0.0 --api-key "))
    }

    @Test func anOfferForAServerInTwoAgentsNamesBoth() throws {
        let github = try #require(MCPHubAgents.servers(in: try agentFiles()).first { $0.name == "github" })
        #expect(MCPHubAgents.offerText(github) == "Claude Code and Cursor have a new MCP server, \u{201C}github\u{201D}. Use it in every agent in Next Term?")
    }

    // MARK: add_mcp_server and list_mcp_servers (R10)

    @Test func theAgentToolsAreDeferredAndTagged() throws {
        for name in ["add_mcp_server", "list_mcp_servers"] {
            let tool = try #require(MCPServer.tool(named: name))
            #expect(!tool.alwaysLoad && MCPServer.isDeferred(name) && MCPServer.isHubTool(name) && tool.meta["anthropic/alwaysLoad"] == nil, "\(name)")
            #expect(tool.description.contains("This Mac only") && !tool.openWorld, "\(name)")
        }
        #expect(MCPServer.tool(named: "list_mcp_servers")?.scope == .read && MCPServer.tool(named: "list_mcp_servers")?.readOnly == true)
        #expect(MCPServer.tool(named: "add_mcp_server")?.scope == .write && MCPServer.tool(named: "add_mcp_server")?.destructive == true)
        #expect(MCPServer.tool(named: "add_mcp_server")?.description.contains("request_secret") == true)
        for inTab in [false, true] {
            for tabs in [false, true] { #expect(MCPServer.instructions(inTab: inTab, offeringTabs: tabs).utf16.count <= 2048) }
        }
    }

    /// R17: until the user has a list of servers, tools/list and the instructions are as they were: neither tool, no
    /// `mcp` in show_settings, the old words. Once there is one, both tools come, after Next Term's control tools.
    @Test func theAgentToolsAreListedOnlyOnceTheUserHasAList() throws {
        func listed(hub: Bool) -> [[String: Any]] {
            let answer = MCPServer.respond(to: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"], version: "0", hub: hub) { _, _ in
                MCPServer.CallResult(text: "")
            }
            return (answer?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        }
        func enumOfShowSettings(_ tools: [[String: Any]]) -> [String] {
            let tool = tools.first { $0["name"] as? String == "show_settings" }
            let schema = tool?["inputSchema"] as? [String: Any], properties = schema?["properties"] as? [String: Any]
            return (properties?["tab"] as? [String: Any])?["enum"] as? [String] ?? []
        }
        let before = listed(hub: false), after = listed(hub: true)
        #expect(before.count == MCPServer.tools.count - 2 && after.count == MCPServer.tools.count)
        #expect(!before.contains { MCPServer.isHubTool($0["name"] as? String ?? "") })
        #expect(after.filter { MCPServer.isHubTool($0["name"] as? String ?? "") }.count == 2)
        #expect(!enumOfShowSettings(before).contains("mcp") && enumOfShowSettings(after).contains("mcp"))
        let described = before.first { $0["name"] as? String == "show_settings" }?["description"] as? String
        #expect(described?.contains("skills, tasks (where") == true && described?.contains("MCP") == false)
        for inTab in [false, true] {
            #expect(!MCPServer.instructions(inTab: inTab, offeringTabs: true).contains("add_mcp_server"))
            #expect(MCPServer.instructions(inTab: inTab, offeringTabs: true, hub: true).contains("add_task and add_mcp_server ask the user"))
        }
        #expect(MCPServer.instructions(inTab: false, offeringTabs: true) == MCPServer.instructions)
    }

    @Test func addMakesTheServerWithItsKeysByName() throws {
        let local = try MCPServer.addServerRequest([
            "name": "github", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github@2025.4.8"],
            "secrets": ["GH_TOKEN=GITHUB_PERSONAL_ACCESS_TOKEN"], "env": ["LOG": "1"], "reason": "for the issues",
        ]).get()
        #expect(local.server.command == "nxtrm" && local.server.args == ["secret", "run", "GH_TOKEN=GITHUB_PERSONAL_ACCESS_TOKEN", "--", "npx", "-y",
                                                                         "@modelcontextprotocol/server-github@2025.4.8"])
        #expect(local.server.env == ["LOG": "1"] && local.secrets == ["GH_TOKEN"] && local.project == nil && local.server.projects == .all)
        let details = MCPServer.addServerDetails(local.server, appliesTo: "every project")
        #expect(details.contains("Runs: npx -y @modelcontextprotocol/server-github@2025.4.8") && details.contains("Keys from Secrets: GH_TOKEN as GITHUB_PERSONAL_ACCESS_TOKEN"))
        #expect(details.contains("Applies to: every project") && details.contains("No agent\u{2019}s own config changes."))
        #expect(!MCPServer.addServerDetails(local.server, appliesTo: "x", commandShown: true).contains("Runs:"))

        let remote = try MCPServer.addServerRequest(["name": "linear", "url": "https://mcp.linear.app/mcp", "secrets": ["LINEAR_API_KEY"]]).get()
        #expect(remote.server.transport == .http && remote.server.headers == ["Authorization": "Bearer ${secret:LINEAR_API_KEY}"])
        #expect(remote.secrets == ["LINEAR_API_KEY"])
        #expect(MCPServer.addServerDetails(remote.server, appliesTo: "every project").contains("Reaches: https://mcp.linear.app/mcp"))
        // A key named in a header counts as one to check is stored.
        let header = try MCPServer.addServerRequest(["name": "api", "url": "https://api.example.com/mcp", "headers": ["X-Api-Key": "${secret:API_KEY}"]]).get()
        #expect(header.secrets == ["API_KEY"])
    }

    @Test func addRefusesAKeyAndEverythingElseWrongBeforeAnyoneIsAsked() {
        func refusal(_ arguments: [String: Any]) -> String {
            if case .failure(let error) = MCPServer.addServerRequest(arguments) { return error.text }
            return "accepted"
        }
        let inEnv = refusal(["name": "github", "command": "npx", "env": ["GITHUB_TOKEN": token]])
        #expect(inEnv.contains("looks like a key") && inEnv.contains("request_secret") && inEnv.hasSuffix("Nothing was asked."))
        #expect(refusal(["name": "github", "command": "npx", "args": ["--token", token]]).contains("request_secret"))
        #expect(refusal(["name": "linear", "url": "https://mcp.linear.app/mcp", "headers": ["Authorization": "Bearer " + token]]).contains("request_secret"))
        #expect(refusal(["name": "GitHub", "command": "npx"]).contains("Try github."))
        #expect(refusal(["name": "x", "command": "npx", "url": "https://a.example.com"]).contains("one of the two"))
        #expect(refusal(["name": "x"]).contains("one of the two"))
        #expect(refusal(["name": "x", "command": "npx", "cwd": "/tmp"]).contains("takes no argument cwd"))
        #expect(refusal(["name": "x", "command": "npx", "secrets": ["lower"]]).contains("not a key's name"))
        #expect(refusal(["name": "x", "url": "https://a.example.com", "secrets": ["A", "B"]]).contains("one key"))
        #expect(refusal(["name": "x", "url": "http://example.com/mcp"]).contains("accepted") == false)
        #expect(refusal(["name": "x", "command": "npx", "headers": ["A": "b"]]).contains("remote server"))
        #expect(refusal(["name": "next-term", "command": "npx"]).contains("Next Term's own"))
    }

    @Test func listAnswersNamesKindsScopeAndStateButNeverAKey() throws {
        let userFile = MCPHubScope.userPath(home: home)
        _ = MCPHubScope.save(.set(.local("github", command: "nxtrm", args: ["secret", "run", "GITHUB_TOKEN", "--", "npx", "-y", "gh"])),
                             to: userFile, place: .user)
        _ = MCPHubScope.save(.set(.remote("linear", url: "https://mcp.linear.app/mcp", headers: ["Authorization": "Bearer ${secret:LINEAR_API_KEY}"],
                                          projects: .only(["~/Code/app"]))), to: userFile, place: .user)
        let user = MCPHubScope.sources(folder: nil, home: home, userFile: userFile).user
        let personal = MCPHubOverview.personal(user, runs: [MCPHubOverview.runKey(list: userFile, server: "github"): .init(failure: nil, tools: 3)])
        let answer = MCPServer.listServersAnswer(personal: personal, project: nil, home: home)
        let servers = try #require(answer["servers"] as? [[String: Any]])
        #expect(servers.map { $0["name"] as? String } == ["github", "linear"])
        #expect(servers[0]["kind"] as? String == "local" && servers[0]["applies"] as? String == "all projects" && servers[0]["state"] as? String == "ready")
        #expect(servers[0]["tools"] as? Int == 3)
        #expect(servers[1]["kind"] as? String == "remote" && servers[1]["applies"] as? [String] == ["~/Code/app"] && servers[1]["state"] as? String == "not_reached")
        let text = MCPServer.json(answer)
        #expect(!text.contains("GITHUB_TOKEN") && !text.contains("LINEAR_API_KEY") && !text.contains("secret"))
        let empty = MCPServer.listServersAnswer(personal: [], project: nil, home: home)
        #expect((empty["note"] as? String)?.contains("add_mcp_server") == true)
    }

    @Test func aPastedOpenCodeEntryReadsToo() throws {
        let found = try MCPHubPaste.read(#"{"mcp": {"browser": {"type": "local", "command": ["npx", "-y", "browser-mcp@1.0.0"]}}}"#).get()
        #expect(found.map(\.name) == ["browser"])
        let server = try found[0].server().get()
        #expect(server.command == "npx" && server.args == ["-y", "browser-mcp@1.0.0"] && server.transport == .stdio)
    }
}
