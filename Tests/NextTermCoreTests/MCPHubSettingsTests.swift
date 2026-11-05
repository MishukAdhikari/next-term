import Foundation
import Testing
@testable import NextTermCore

/// Settings › MCP Servers' model: the user's choices at the top of their list (a project's list approved as its bytes
/// are, a server off for one project), what the tab lists in each state, its Undo, and Paste a Config…'s reading of a
/// README's snippet with its keys taken out for Secrets.
@Suite struct MCPHubSettingsTests {
    let home: String
    let repo: String
    let userFile: String
    let projectFile: String
    let token = "ghp_" + String(repeating: "A1b2", count: 9)

    init() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("nt-mcphub-settings-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: made + "/Code/app/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: made + "/Code/app/web", withIntermediateDirectories: true)
        home = canonicalPath(made)
        repo = home + "/Code/app"
        userFile = MCPHubScope.userPath(home: home)
        projectFile = repo + "/" + MCPHubScope.projectFile
    }

    func write(_ json: String, to file: String) throws {
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try json.write(toFile: file, atomically: true, encoding: .utf8)
    }

    func text(_ file: String) -> String { (try? String(contentsOfFile: file, encoding: .utf8)) ?? "<none>" }

    func project(_ folder: String) -> [MCPHubOverview.Row] {
        let found = MCPHubScope.sources(folder: folder, home: home, userFile: userFile)
        return MCPHubOverview.project(folder, user: found.user, projects: found.projects, home: home).rows
    }

    func states(_ rows: [MCPHubOverview.Row]) -> [String] { rows.map { "\($0.name) \(MCPHubOverview.stateText($0.state))" } }

    // MARK: choices

    @Test func approvingAProjectsListMakesTheUsersListAndStartsItsServers() throws {
        try write(#"{"mcpServers": {"team": {"command": "team-server"}}}"#, to: projectFile)
        #expect(states(project(repo)) == ["team Needs your approval"])
        let source = try #require(MCPHubScope.sources(folder: repo, home: home, userFile: userFile).projects.first)
        #expect(!FileManager.default.fileExists(atPath: userFile))
        #expect(MCPHubScope.save(.approve(file: projectFile, digest: source.digest), to: userFile, place: .user) == .success(.written))
        #expect(text(userFile).contains("\"approvedLists\"") && text(userFile).contains(source.digest))
        #expect(states(project(repo)) == ["team Ready"])
        let resolution = MCPHubScope.servers(folder: repo, home: home, userFile: userFile)
        #expect(MCPHubPlan.make(resolution, folder: repo, path: [], approved: resolution.approved).servers.map(\.state) == [.ready])
        // Approving it again as it is changes nothing.
        #expect(MCPHubScope.save(.approve(file: projectFile, digest: source.digest), to: userFile, place: .user) == .success(.unchanged))

        // A commit that changes the list waits for the user again, and the next approval replaces the old one.
        try write(#"{"mcpServers": {"team": {"command": "other-server"}}}"#, to: projectFile)
        #expect(states(project(repo)) == ["team Needs your approval"])
        let changed = try #require(MCPHubScope.sources(folder: repo, home: home, userFile: userFile).projects.first)
        _ = MCPHubScope.save(.approve(file: projectFile, digest: changed.digest), to: userFile, place: .user)
        let choices = MCPHubChoices.read(try MCPHubFile.parse(Data(text(userFile).utf8)).get().document)
        #expect(choices.approved == [MCPHubChoices.Approval(file: projectFile, digest: changed.digest)])
    }

    /// Approve… shows every server of the list, with what each sets in its environment: a team's list that starts a
    /// well-known server with NODE_OPTIONS loading a script of its own is approved only with that in view, and a 13th
    /// server never hides behind "and 1 more".
    @Test func approvingShowsEveryServerAndWhatItSets() throws {
        var servers = (1...13).map { "\"s\($0)\": {\"command\": \"npx\", \"args\": [\"-y\", \"tool-\($0)@1.0.0\"]}" }
        servers[0] = #""s1": {"command": "npx", "args": ["-y", "tool-1@1.0.0"], "env": {"NODE_OPTIONS": "--require ./x.js", "A": "1"}}"#
        try write("{\"mcpServers\": {\(servers.joined(separator: ", "))}}", to: projectFile)
        let rows = project(repo).filter { $0.list == projectFile }
        let lines = MCPHubOverview.approvalLines(rows.compactMap { row in row.server.map { (row.name, $0) } })
        #expect(lines.filter { $0.hasPrefix("\u{2022} ") }.count == 13 && lines.contains("\u{2022} s13: npx -y tool-13@1.0.0"))
        let at = try #require(lines.firstIndex(of: "\u{2022} s1: npx -y tool-1@1.0.0"))
        #expect(Array(lines[(at + 1)...(at + 2)]) == ["    A=1", "    NODE_OPTIONS=--require ./x.js"])
    }

    @Test func aServerTurnedOffForAProjectIsOffThereAndInsideItOnly() throws {
        try write(#"{"mcpServers": {"github": {"command": "gh-server"}}}"#, to: userFile)
        try write(#"{"mcpServers": {"team": {"command": "team-server"}}}"#, to: projectFile)
        for name in ["github", "team"] {
            #expect(MCPHubScope.save(.turnOff(server: name, folder: repo), to: userFile, place: .user) == .success(.written))
        }
        let here = MCPHubScope.servers(folder: repo + "/web", home: home, userFile: userFile)
        #expect(here.servers.isEmpty && here.off.map(\.name) == ["github", "team"] && here.offHere == ["github", "team"])
        #expect(states(project(repo)) == ["github Off in this project", "team Off in this project"])
        try FileManager.default.createDirectory(atPath: home + "/Code/other", withIntermediateDirectories: true)
        #expect(MCPHubScope.servers(folder: home + "/Code/other", home: home, userFile: userFile).servers.map(\.name) == ["github"])

        #expect(MCPHubScope.save(.turnOn(server: "github", folder: repo), to: userFile, place: .user) == .success(.written))
        #expect(MCPHubScope.servers(folder: repo, home: home, userFile: userFile).servers.map(\.name) == ["github"])
        // Its entry is kept as it was: the choice is beside it, never in it.
        #expect(text(userFile).contains(#""github": {"#) && !text(userFile).contains("\"enabled\": false"))
        #expect(MCPHubScope.save(.turnOn(server: "team", folder: repo), to: userFile, place: .user) == .success(.written))
        #expect(!text(userFile).contains("\"nextTerm\": {\n    \"off\""))
    }

    @Test func choicesKeepTheirOwnRulesAndAreTheUsersAlone() throws {
        if case .failure(.invalid) = MCPHubFile.updated(nil, place: .project, .approve(file: projectFile, digest: "ab")) {} else {
            Issue.record("a project's list took a choice")
        }
        if case .failure(.invalid) = MCPHubFile.updated(nil, place: .user, .turnOff(server: "a", folder: "relative/path")) {} else {
            Issue.record("a relative folder was taken")
        }
        #expect(try MCPHubFile.updated(nil, place: .user, .turnOn(server: "a", folder: "/x")).get() == nil) // no file for nothing
        // Unknown keys under nextTerm stay, and a malformed record is passed over.
        let current = #"{"nextTerm": {"later": 1, "off": [{"server": "a"}, {"server": "b", "folder": "/x"}]}, "mcpServers": {}}"#
        let made = try #require(try MCPHubFile.updated(Data(current.utf8), place: .user, .turnOff(server: "c", folder: "/y")).get())
        let choices = MCPHubChoices.read(try MCPHubFile.parse(made).get().document)
        #expect(choices.off == [.init(server: "b", folder: "/x"), .init(server: "c", folder: "/y")])
        #expect(String(decoding: made, as: UTF8.self).contains("\"later\": 1"))
    }

    // MARK: what the tab lists

    @Test func personalListsEveryEntryWithItsState() throws {
        try write("""
            {"mcpServers": {
              "github": {"command": "nxtrm", "args": ["secret", "run", "GH", "--", "npx", "-y", "gh-mcp"]},
              "quiet": {"command": "a", "nextTerm": {"enabled": false}},
              "linear": {"url": "https://mcp.linear.app/mcp"},
              "broken": {"command": "a", "env": {"API_TOKEN": "\(token)"}}
            }}
            """, to: userFile)
        let user = MCPHubScope.sources(folder: nil, home: home, userFile: userFile).user
        let failed = [MCPHubOverview.runKey(list: userFile, server: "github"): MCPHubOverview.Run(failure: "npx was not found", tools: 0)]
        let rows = MCPHubOverview.personal(user, runs: failed)
        #expect(states(rows) == ["github Didn\u{2019}t start", "quiet Off", "linear Not reached yet", "broken Can\u{2019}t be used"])
        #expect(MCPHubOverview.stateTip(rows[0].state).contains("npx was not found"))
        #expect(MCPHubOverview.runsText(try #require(rows[0].server)) == "nxtrm secret run GH -- npx -y gh-mcp")
        #expect(MCPHubOverview.appliesText(rows[0], home: home) == "All projects")
        let ran = [MCPHubOverview.runKey(list: userFile, server: "github"): MCPHubOverview.Run(failure: nil, tools: 3)]
        #expect(MCPHubOverview.stateText(MCPHubOverview.personal(user, runs: ran)[0].state) == "Ready \u{00B7} 3 tools")
    }

    @Test func projectListsShadowedAndBrokenServersAfterTheOnesThatApply() throws {
        try write(#"{"mcpServers": {"team": {"command": "mine"}, "solo": {"command": "a"}}}"#, to: userFile)
        try write(#"{"mcpServers": {"team": {"command": "theirs"}, "bad": {"command": ""}}}"#, to: projectFile)
        let rows = project(repo)
        #expect(states(rows) == ["solo Ready", "team Needs your approval", "team Replaced by another", "bad Can\u{2019}t be used"])
        #expect(MCPHubOverview.appliesText(rows[1], home: home) == "app\u{2019}s list")
    }

    @Test func aWrappedCommandGivesItsKeysAndIsMadeAgain() {
        let server = MCPHubServer.local("gh", command: "nxtrm", args: ["secret", "run", "GH=GITHUB_TOKEN", "OTHER", "--", "npx", "gh"])
        let found = MCPHubOverview.keys(of: server)
        #expect(found.keys.map { "\($0.name)=\($0.variable)" } == ["GH=GITHUB_TOKEN", "OTHER=OTHER"] && found.inner == ["npx", "gh"])
        let made = MCPHubOverview.wrapped(found.inner, keys: found.keys)
        #expect(made.command == "nxtrm" && made.args == server.args)
        #expect(MCPHubOverview.wrapped(["npx", "gh"], keys: []) == ("npx", ["gh"]))
        #expect(MCPHubOverview.words(#"npx -y "@scope/a b" --flag='x y'"#) == ["npx", "-y", "@scope/a b", "--flag=x y"])
    }

    // MARK: undo

    func undone(_ written: MCPHubScope.Written) -> Bool {
        if case .success = MCPHubScope.undo(written) { return true }
        return false
    }

    @Test func undoPutsTheListBackAndTakesTheFirstFileAway() throws {
        let first = try #require(try MCPHubScope.write(.set(.local("a", command: "a")), to: userFile, place: .user).get())
        #expect(first.before == nil)
        let second = try #require(try MCPHubScope.write(.remove("a"), to: userFile, place: .user).get())
        #expect(undone(second))
        #expect(text(userFile).contains("\"a\""))
        #expect(undone(first))
        #expect(!FileManager.default.fileExists(atPath: userFile))
        // A list changed since is never overwritten.
        let third = try #require(try MCPHubScope.write(.set(.local("b", command: "b")), to: userFile, place: .user).get())
        try write(#"{"mcpServers": {}}"#, to: userFile)
        if case .failure(.write(.changed)) = MCPHubScope.undo(third) {} else { Issue.record("a changed list was undone") }
        #expect(text(userFile) == #"{"mcpServers": {}}"#)
    }

    // MARK: paste

    @Test func aReadmesBlockGivesItsServersWithTheKeyOutForSecrets() throws {
        let snippet = """
            ```json
            {
              // from the README
              "mcpServers": {
                "GitHub": {
                  "command": "npx",
                  "args": ["-y", "@modelcontextprotocol/server-github"],
                  "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "\(token)", "DEBUG": "1"},
                },
                "fetch": {"command": "uvx", "args": ["mcp-server-fetch"]}
              }
            }
            ```
            """
        let found = try MCPHubPaste.read(snippet).get()
        #expect(found.map(\.name) == ["github", "fetch"])
        let key = try #require(found[0].keys.first)
        #expect(key.name == "GITHUB_PERSONAL_ACCESS_TOKEN" && key.kind == "GitHub token" && key.value == SecretBytes(utf8: token))
        let server = try found[0].server().get()
        #expect(server.command == "nxtrm"
                && server.args == ["secret", "run", "GITHUB_PERSONAL_ACCESS_TOKEN", "--", "npx", "-y", "@modelcontextprotocol/server-github"])
        #expect(server.env == ["DEBUG": "1"])
        let bytes = try #require(try MCPHubFile.updated(nil, place: .user, .set(server)).get())
        #expect(!String(decoding: bytes, as: UTF8.self).contains(token))
        #expect(try found[1].server().get().command == "uvx" && found[1].keys.isEmpty)
    }

    @Test func otherShapesAreReadToo() throws {
        // A member cut out of a file, VS Code's servers, and one server alone.
        #expect(try MCPHubPaste.read(#""docs": {"command": "docs-mcp"},"#).get().map(\.name) == ["docs"])
        let vscode = #"{"servers": {"remote": {"type": "streamableHttp", "serverUrl": "https://mcp.example.com/mcp"}}}"#
        let remote = try MCPHubPaste.read(vscode).get()[0].server().get()
        #expect(remote.transport == .http && remote.url == "https://mcp.example.com/mcp")
        #expect(try MCPHubPaste.read(#"{"command": "npx", "args": ["-y", "@acme/weather-mcp@1.2.0"]}"#).get().map(\.name) == ["weather-mcp"])
        #expect(try MCPHubPaste.read(#"{"url": "https://mcp.linear.app/sse"}"#).get().map(\.name) == ["linear"])
        #expect(MCPHubPaste.read("not json at all") == .failure(.notJSON))
        #expect(MCPHubPaste.read(#"{"theme": "dark"}"#) == .failure(.noServers))
    }

    @Test func aPlaceholderIsAKeyToGiveAndAHeaderKeyBecomesAReference() throws {
        let snippet = """
            {"mcpServers": {
              "brave": {"command": "npx", "args": ["-y", "brave-mcp"], "env": {"BRAVE_API_KEY": "<YOUR_API_KEY>"}},
              "acme": {"url": "https://mcp.acme.dev/mcp", "headers": {"Authorization": "Bearer \(token)"}}
            }}
            """
        let found = try MCPHubPaste.read(snippet, stored: ["BRAVE_API_KEY", "ACME_TOKEN"]).get()
        let asked = try #require(found[0].keys.first)
        #expect(asked.value == nil && asked.kind == nil && asked.name == "BRAVE_API_KEY") // the stored one, by its name
        let header = try #require(found[1].keys.first)
        #expect(header.value == SecretBytes(utf8: token) && header.name == "ACME_TOKEN_2") // never a stored key's name
        let server = try found[1].server().get()
        #expect(server.headers == ["Authorization": "Bearer ${secret:ACME_TOKEN_2}"])
    }

    @Test func aKeyInAnArgumentKeepsItsServerOut() throws {
        let found = try MCPHubPaste.read(#"{"mcpServers": {"x": {"command": "x-mcp", "args": ["--api-key", "\#(token)"]}}}"#).get()
        #expect(!found[0].stuck.isEmpty)
        if case .success = found[0].server() { Issue.record("a server with a key in an argument was made") }
    }
}
