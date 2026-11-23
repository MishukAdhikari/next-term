import Foundation
import Testing
@testable import NextTermCore

/// The MCP hub's list file: read strictly, what Next Term doesn't know kept on every rewrite, and no file made until
/// the first server is added.
@Suite struct MCPHubFileTests {
    let github = MCPHubServer.local("github", command: "nxtrm",
                                    args: ["secret", "run", "GITHUB_TOKEN", "--", "npx", "-y", "@modelcontextprotocol/server-github"])

    func text(_ data: Data?) -> String { data.map { String(decoding: $0, as: UTF8.self) } ?? "<nothing>" }

    func read(_ json: String) throws -> MCPHubFile.Read {
        try MCPHubFile.parse(Data(json.utf8)).get()
    }

    func updated(_ current: String?, _ change: MCPHubFile.Change, place: MCPHubFile.Place = .user) throws -> String? {
        try MCPHubFile.updated(current.map { Data($0.utf8) }, place: place, change).get().map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: no file until the first server

    @Test func aMissingFileGetsBytesOnlyWhenAServerIsAdded() throws {
        #expect(try updated(nil, .remove("github")) == nil)
        let first = try #require(try updated(nil, .set(github)))
        #expect(first == """
            {
              "version": 1,
              "mcpServers": {
                "github": {
                  "command": "nxtrm",
                  "args": ["secret", "run", "GITHUB_TOKEN", "--", "npx", "-y", "@modelcontextprotocol/server-github"],
                  "nextTerm": {
                    "enabled": true,
                    "projects": "all"
                  }
                }
              }
            }

            """)
        // A server that breaks a rule makes no file either.
        let broken = MCPHubFile.updated(nil, place: .user, .set(.local("GitHub", command: "npx")))
        #expect(throws: MCPHubFile.Refusal.self) { try broken.get() }
    }

    @Test func aChangeThatChangesNothingWritesNothing() throws {
        let file = try #require(try updated(nil, .set(github)))
        #expect(try updated(file, .set(github)) == nil)
        #expect(try updated(file, .remove("linear")) == nil)
    }

    /// Removing the last server leaves the file, empty: it was the user's, and may hold more than servers.
    @Test func removingTheLastServerKeepsTheFile() throws {
        let file = try #require(try updated(nil, .set(github)))
        let emptied = try #require(try updated(file, .remove("github")))
        #expect(emptied == "{\n  \"version\": 1,\n  \"mcpServers\": {}\n}\n")
        #expect(try read(emptied).document.entries.isEmpty)
    }

    // MARK: reading

    @Test func anEmptyFileIsAnEmptyList() throws {
        #expect(try read("").document.entries.isEmpty)
        #expect(try read("  \n").document.entries.isEmpty)
        #expect(try read("{}").document.entries.isEmpty)
        // And a server can be added to it.
        #expect(try updated("", .set(github))?.contains("\"github\"") == true)
    }

    @Test func aBrokenFileIsRefusedAndNeverOverwritten() throws {
        let cases: [(String, MCPHubFile.Problem)] = [
            ("{\"mcpServers\": {},}", .json(.trailingComma)),
            ("// mine\n{}", .json(.comment)),
            ("{\"mcpServers\": ", .json(.notJSON)),
            ("[]", .notAnObject),
            ("{\"mcpServers\": {}, \"mcpServers\": {}}", .keyTwice("mcpServers")),
            ("{\"mcpServers\": []}", .serversNotAnObject),
            ("{\"version\": \"1\"}", .badVersion),
            ("{\"version\": 1.5}", .badVersion),
        ]
        for (json, problem) in cases {
            #expect(MCPHubFile.parse(Data(json.utf8)) == .failure(problem), "\(json)")
            #expect(MCPHubFile.updated(Data(json.utf8), place: .user, .set(github)) == .failure(.unreadable(problem)), "\(json)")
        }
        let large = Data(repeating: 0x20, count: MCPHubFile.maxBytes + 1)
        #expect(MCPHubFile.parse(large) == .failure(.tooLarge))
    }

    /// A newer Next Term's file is read as far as this one knows, and never changed.
    @Test func aNewerFileIsReadButNotWritten() throws {
        let json = "{\"version\": 2, \"mcpServers\": {\"docs\": {\"url\": \"https://docs.example.com/mcp\"}}}"
        let found = try read(json)
        #expect(found.newer == 2 && found.document.entries.map(\.key) == ["docs"])
        #expect(MCPHubFile.updated(Data(json.utf8), place: .user, .remove("docs")) == .failure(.unreadable(.newer(2))))
    }

    /// A name twice is named, and neither copy is picked; setting it leaves one, and removing it leaves none.
    @Test func aNameTwiceIsRefusedUntilChanged() throws {
        let json = """
            {"mcpServers": {"docs": {"url": "https://a.example.com/mcp"}, "other": {"command": "x"}, "docs": {"url": "https://b.example.com/mcp"}}}
            """
        #expect(try read(json).twice == ["docs"])
        let set = try #require(try updated(json, .set(.remote("docs", url: "https://c.example.com/mcp"))))
        let after = try read(set)
        #expect(after.twice.isEmpty && after.document.entries.map(\.key) == ["docs", "other"])
        #expect(after.document.entries[0].value.member("url") == .string("https://c.example.com/mcp"))
        let removed = try #require(try updated(json, .remove("docs")))
        #expect(try read(removed).document.entries.map(\.key) == ["other"])
    }

    // MARK: keeping what Next Term doesn't know

    @Test func unknownKeysAreKeptAsWritten() throws {
        let json = """
            {
              "$schema": "https://example.com/schema.json",
              "mcpServers": {
                "github": {
                  "command": "npx",
                  "args": ["-y", "@modelcontextprotocol/server-github"],
                  "cwd": "/tmp",
                  "timeout": 1.50e3,
                  "alwaysAllow": [{"tool": "search", "why": null}],
                  "nextTerm": {"enabled": true, "projects": "all", "ask": true}
                }
              },
              "version": 1
            }
            """
        var server = try MCPHubServer.decode(name: "github", try read(json).document.entries[0].value, place: .user).get()
        server.enabled = false
        let written = try #require(try updated(json, .set(server)))
        let entry = try read(written).document.entries[0].value
        #expect(entry.members?.map(\.key) == ["command", "args", "cwd", "timeout", "alwaysAllow", "nextTerm"])
        #expect(entry.member("timeout") == .number("1.50e3"))
        #expect(entry.member("alwaysAllow") == .array([.object([MCPHubFile.Member("tool", .string("search")), MCPHubFile.Member("why", .null)])]))
        #expect(entry.member("nextTerm") == .object([MCPHubFile.Member("enabled", .bool(false)), MCPHubFile.Member("projects", .string("all")),
                                                     MCPHubFile.Member("ask", .bool(true))]))
        let top = try read(written).document.members.map(\.key)
        #expect(top == ["$schema", "mcpServers", "version"])
    }

    /// A change to one field replaces that key where it was; a key the new kind of server has no use for goes.
    @Test func aChangeRewritesOnlyWhatChanged() throws {
        let json = "{\"mcpServers\": {\"docs\": {\"type\": \"stdio\", \"command\": \"docs-mcp\", \"args\": [], \"env\": {\"B\": \"2\", \"A\": \"1\"}}}}"
        var server = try MCPHubServer.decode(name: "docs", try read(json).document.entries[0].value, place: .project).get()
        server.args = ["--verbose"]
        let changed = try read(try #require(try updated(json, .set(server), place: .project))).document.entries[0].value
        // env's order is the file's: its meaning didn't change. A project's list gets no projects.
        #expect(changed.members?.map(\.key) == ["type", "command", "args", "env", "nextTerm"])
        #expect(changed.member("env")?.members?.map(\.key) == ["B", "A"])
        #expect(changed.member("nextTerm") == .object([MCPHubFile.Member("enabled", .bool(true))]))

        let remote = try read(try #require(try updated(json, .set(.remote("docs", url: "https://docs.example.com/mcp")), place: .project)))
        #expect(remote.document.entries[0].value.members?.map(\.key) == ["type", "url", "nextTerm"])
        #expect(remote.document.entries[0].value.member("type") == .string("http"))
    }

    // MARK: text

    @Test func textRoundTrips() throws {
        let tricky = MCPHubServer.local("tricky", command: "/Applications/My App/bin/mcp",
                                        args: ["say \"hi\"", "back\\slash", "tab\tnew\nline", "\u{01}", "é ✓ 😀", "/path/with/slashes"],
                                        projects: .only(["~/Code/app", "/Volumes/Work/x"]))
        let data = try #require(try MCPHubFile.updated(nil, place: .user, .set(tricky)).get())
        // Foundation reads what Next Term writes, and it means the same.
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entry = try #require((object["mcpServers"] as? [String: Any])?["tricky"] as? [String: Any])
        #expect(entry["args"] as? [String] == tricky.args)
        #expect(text(data).contains("\"\\u0001\"") && text(data).contains("/path/with/slashes"))
        let back = try MCPHubServer.decode(name: "tricky", try MCPHubFile.parse(data).get().document.entries[0].value, place: .user).get()
        #expect(back == tricky)
        // Writing what was read gives the same bytes.
        #expect(MCPHubFile.text(try MCPHubFile.parse(data).get().document) == data)
    }
}
