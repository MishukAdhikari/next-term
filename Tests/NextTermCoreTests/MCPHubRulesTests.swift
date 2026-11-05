import Foundation
import Testing
@testable import NextTermCore

/// The rules a hub server must keep: its name, its command or URL, and no key in it (they stay in Secrets).
@Suite struct MCPHubRulesTests {
    func reasons(_ server: MCPHubServer, place: MCPHubFile.Place = .user) -> [String] {
        MCPHubRules.reasons(server, place: place)
    }

    func decode(_ json: String, place: MCPHubFile.Place = .user) throws -> Result<MCPHubServer, MCPHubServer.Broken> {
        let value = try MCPHubFile.parse(Data("{\"mcpServers\": {\"s\": \(json)}}".utf8)).get().document.entries[0].value
        return MCPHubServer.decode(name: "s", value, place: place)
    }

    // MARK: names

    @Test func namesAreLowercaseWordsJoinedByHyphens() {
        for good in ["github", "a", "my-server-2", "0x", String(repeating: "a", count: 32)] {
            #expect(MCPHubRules.nameReason(good) == nil, "\(good)")
        }
        for bad in ["", "GitHub", "my_server", "my.server", "-a", "a-", "a--b", "a b", "ä", String(repeating: "a", count: 33)] {
            #expect(MCPHubRules.nameReason(bad) != nil, "\(bad)")
        }
        #expect(MCPHubRules.nameReason("next-term")?.contains("Next Term's own") == true)
    }

    @Test func aNameIsSuggestedFromAnyText() {
        #expect(MCPHubRules.suggestedName(from: "GitHub") == "github")
        #expect(MCPHubRules.suggestedName(from: "my_server") == "my-server")
        #expect(MCPHubRules.suggestedName(from: "  @scope/Some Server!! ") == "scope-some-server")
        #expect(MCPHubRules.suggestedName(from: "Next Term") == "next-term-2")
        #expect(MCPHubRules.suggestedName(from: "✓✓") == "server")
        #expect(MCPHubRules.suggestedName(from: String(repeating: "ab-", count: 20)).count <= MCPHubRules.maxName)
        for text in ["GitHub", "x__y", "a.b.c", "Ünïcode", String(repeating: "z", count: 40)] {
            #expect(MCPHubRules.nameReason(MCPHubRules.suggestedName(from: text)) == nil, "\(text)")
        }
    }

    // MARK: commands

    @Test func aCommandIsOneProgram() {
        #expect(reasons(.local("s", command: "npx", args: ["-y", "pkg@1.2.3"])).isEmpty)
        #expect(reasons(.local("s", command: "/Applications/My App/bin/mcp")).isEmpty)
        #expect(reasons(.local("s", command: "")) == ["Its command is empty."])
        #expect(reasons(.local("s", command: "  ")) == ["Its command is empty."])
        #expect(reasons(.local("s", command: " npx")).count == 1)
        #expect(reasons(.local("s", command: "npx\n-y")).count == 1)
        #expect(reasons(.local("s", command: "x", args: ["a\u{0}b"])) == ["An argument holds a NUL character."])
        #expect(reasons(.local("s", command: "x", env: ["1BAD": "v"])) == ["1BAD can't be an environment variable's name."])
        #expect(reasons(.local("s", command: "x", env: ["DEBUG": "1", "_OK": "yes"])).isEmpty)
    }

    /// A command wrapped in nxtrm secret run must be one it runs.
    @Test func aWrappedCommandMustParse() {
        #expect(reasons(.local("s", command: "nxtrm", args: ["secret", "run", "GH_TOKEN=GITHUB_TOKEN", "--", "npx", "-y", "x"])).isEmpty)
        #expect(reasons(.local("s", command: "/Applications/Next Term.app/Contents/MacOS/NextTerm",
                               args: ["--cli", "secret", "run", "GH_TOKEN", "--", "x"])).isEmpty)
        #expect(reasons(.local("s", command: "nxtrm", args: ["secret", "run", "GH_TOKEN", "npx"])) == ["Its nxtrm secret run is wrong: no -- before the command."])
        #expect(reasons(.local("s", command: "nxtrm", args: ["secret", "run", "--", "npx"])).first?.contains("no key named") == true)
    }

    // MARK: keys stay in Secrets

    @Test func aKeyInACommandIsRefused() {
        let token = "ghp_" + String(repeating: "A1b2", count: 9)
        let inEnv = reasons(.local("s", command: "npx", env: ["GITHUB_PERSONAL_ACCESS_TOKEN": token]))
        #expect(inEnv.count == 1 && inEnv[0].hasPrefix("GITHUB_PERSONAL_ACCESS_TOKEN looks like a key (GitHub token)") && inEnv[0].contains("nxtrm secret run"))
        #expect(reasons(.local("s", command: "npx", env: ["API_KEY": "hunter2hunter2"])).count == 1) // by its name
        #expect(reasons(.local("s", command: "npx", args: ["--api-key", "hunter2hunter2"])).count == 1)
        #expect(reasons(.local("s", command: "npx", args: ["--token=" + token])).count == 1)
        #expect(reasons(.local("s", command: "npx", args: [token])).count == 1)
        // What is not a key: a reference the program fills in itself, a placeholder, a setting, the wrapper's key names.
        #expect(reasons(.local("s", command: "npx", env: ["API_KEY": "${API_KEY}", "TOKEN": "your-token-here", "LOG": "debug"])).isEmpty)
        #expect(reasons(.local("s", command: "nxtrm", args: ["secret", "run", "API_TOKEN=NXTRM_API_TOKEN", "--", "npx", "-y", "mcp-remote@0.15.2",
                                                            "https://mcp.example.com/mcp", "--header", "Authorization: Bearer ${NXTRM_API_TOKEN}"])).isEmpty)
    }

    /// ${secret:NAME} is filled in only for a remote server: in a command it would reach the server as written.
    @Test func theSecretPlaceholderIsRefusedInACommand() {
        let found = reasons(.local("s", command: "npx", env: ["TOKEN": "${secret:GITHUB_TOKEN}"]))
        #expect(found.count == 1 && found[0].contains("nxtrm secret run"))
        #expect(reasons(.local("s", command: "npx", args: ["--key", "${secret:K}"])).count == 1)
    }

    // MARK: URLs

    @Test func onlyHTTPSAndThisMacsHTTPAreReached() {
        #expect(reasons(.remote("s", url: "https://mcp.linear.app/mcp")).isEmpty)
        #expect(reasons(.remote("s", url: "HTTPS://Example.com:8443/mcp?x=1")).isEmpty)
        for local in ["http://localhost:3000/mcp", "http://127.0.0.1:8080/", "http://[::1]:9000/mcp", "http://app.localhost/mcp"] {
            #expect(reasons(.remote("s", url: local)).isEmpty, "\(local)")
        }
        for remote in ["http://example.com/mcp", "http://127.0.0.1.example.com/", "http://nas.local/mcp", "http://evil-ts.net/mcp"] {
            #expect(reasons(.remote("s", url: remote)).first?.contains("http:// to another machine") == true, "\(remote)")
            #expect(reasons(.remote("s", url: remote)).first?.contains(MCPHubAddress.recommendation) == true, "\(remote)")
        }
        // A Tailscale name may take http (its addresses are checked when it is reached); https to any domain may be used.
        #expect(reasons(.remote("s", url: "http://box.tail1234.ts.net:8080/mcp")).isEmpty)
        #expect(reasons(.remote("s", url: "https://mcp.home.example.com/mcp")).isEmpty)
        // An IP literal in a private network: refused, with the server's own domain recommended.
        for literal in ["http://10.0.0.5/mcp", "https://10.0.0.5/mcp", "https://[fd12::5]/mcp", "https://169.254.169.254/"] {
            #expect(reasons(.remote("s", url: literal)).first?.contains("own domain over https") == true, "\(literal)")
        }
        for scheme in ["javascript:alert(1)", "data:text/html,<b>x</b>", "file:///etc/passwd", "ftp://example.com/", "JavaScript:void(0)"] {
            #expect(reasons(.remote("s", url: scheme)).first?.contains("Next Term reaches only https://") == true, "\(scheme)")
        }
        #expect(reasons(.remote("s", url: "")) == ["Its URL is empty."])
        #expect(reasons(.remote("s", url: "https://")) == ["Its URL has no server name."])
        #expect(reasons(.remote("s", url: "mcp.example.com")).count == 1)
        #expect(reasons(.remote("s", url: "https://exa mple.com")).first?.contains("space") == true)
    }

    @Test func aKeyInAURLIsRefused() {
        #expect(reasons(.remote("s", url: "https://me:hunter2@example.com/mcp")).first?.contains("user name or password") == true)
        #expect(reasons(.remote("s", url: "https://example.com/mcp?api_key=hunter2hunter2")).first?.contains("api_key looks like a key") == true)
        #expect(reasons(.remote("s", url: "https://example.com/" + "sk-ant-api03-" + String(repeating: "Ab3x", count: 20) + "/mcp")).count == 1)
        #expect(reasons(.remote("s", url: "https://example.com/mcp?api_key=${secret:EXAMPLE_KEY}")).isEmpty)
        #expect(reasons(.remote("s", url: "https://example.com/u/${secret:EXAMPLE_KEY}/mcp")).isEmpty)
        // A key can't name the server, and other references are not filled in.
        #expect(reasons(.remote("s", url: "https://${secret:HOST}/mcp")).first?.contains("server name can't come from a key") == true)
        #expect(reasons(.remote("s", url: "https://example.com/mcp?k=${API_KEY}")).first?.contains("doesn't fill in") == true)
        #expect(reasons(.remote("s", url: "https://example.com/mcp?k=${secret:lower}")).first?.contains("without a key's name") == true)
        #expect(reasons(.remote("s", url: "https://example.com/mcp?k=${secret:OPEN")).first?.contains("without a key's name") == true)
    }

    @Test func headersHoldNoKey() {
        #expect(reasons(.remote("s", url: "https://x.example.com", headers: ["Authorization": "Bearer ${secret:LINEAR_API_KEY}"])).isEmpty)
        #expect(reasons(.remote("s", url: "https://x.example.com", headers: ["X-Team": "platform"])).isEmpty)
        // Two keys side by side are still two names, not a long value that looks like a key.
        #expect(reasons(.remote("s", url: "https://x.example.com/mcp?api_key=${secret:A}${secret:B}",
                                headers: ["X-API-Key": "${secret:KEY_ONE}${secret:KEY_TWO}"])).isEmpty)
        let plain = reasons(.remote("s", url: "https://x.example.com", headers: ["Authorization": "Bearer lin_api_" + String(repeating: "aB3", count: 10)]))
        #expect(plain.count == 1 && plain[0].contains("${secret:NAME}"))
        #expect(reasons(.remote("s", url: "https://x.example.com", headers: ["X-API-Key": "hunter2hunter2"])).count == 1)
        #expect(reasons(.remote("s", url: "https://x.example.com", headers: ["Authorization": "Bearer ${LINEAR}"])).first?.contains("doesn't fill in") == true)
        #expect(reasons(.remote("s", url: "https://x.example.com", headers: ["Authorization": "Bearer ${secret:nope}"])).count == 1)
        #expect(reasons(.remote("s", url: "https://x.example.com", headers: ["Bad Name": "v"])) == ["Bad Name can't be a header's name."])
        #expect(reasons(.remote("s", url: "https://x.example.com", headers: ["X": "a\r\nInjected: 1"])).count == 1)
    }

    @Test func secretNamesAreFoundInOrder() {
        #expect(MCPHubRules.secretNames(in: "Bearer ${secret:A} and ${secret:B_2}") == ["A", "B_2"])
        #expect(MCPHubRules.secretNames(in: "${secret:OPEN").isEmpty)
        #expect(MCPHubRules.secretNames(in: "plain").isEmpty)
    }

    // MARK: projects

    @Test func aUsersProjectListNamesFullPaths() {
        #expect(reasons(.local("s", command: "x", projects: .only(["~/Code/app", "/Volumes/W", "~"]))).isEmpty)
        #expect(reasons(.local("s", command: "x", projects: .only([]))).count == 1)
        #expect(reasons(.local("s", command: "x", projects: .only(["Code/app"]))) == ["Code/app is not a folder's full path."])
        // A project's own list has no projects.
        #expect(reasons(.local("s", command: "x", projects: .only([])), place: .project).isEmpty)
    }

    // MARK: reading an entry

    @Test func aCloudflareAccessServiceTokenIsTwoKeyedHeaders() throws {
        let headers = ["CF-Access-Client-Id": "${secret:CF_ACCESS_CLIENT_ID}", "CF-Access-Client-Secret": "${secret:CF_ACCESS_CLIENT_SECRET}"]
        let server = MCPHubServer.remote("tunnel", url: "https://mcp.example.com/mcp", headers: headers)
        #expect(reasons(server).isEmpty)
        let json = #"{"url": "https://mcp.example.com/mcp", "headers": {"CF-Access-Client-Id": "${secret:CF_ACCESS_CLIENT_ID}", "CF-Access-Client-Secret": "${secret:CF_ACCESS_CLIENT_SECRET}"}}"#
        #expect(try decode(json).get().headers == headers)
    }

    @Test func theTypeComesFromTheEntry() throws {
        #expect(try decode(#"{"command": "x"}"#).get().transport == .stdio)
        #expect(try decode(#"{"url": "https://x.example.com"}"#).get().transport == .http)
        #expect(try decode(#"{"type": "sse", "url": "https://x.example.com/sse"}"#).get().transport == .sse)
        #expect(try decode(#"{"type": "stdio", "command": "x", "url": "ignored"}"#).get().url == "")
        let fails: [(String, String)] = [
            (#"[]"#, "It is not a JSON object."),
            (#"{}"#, "It has no command to run and no url to reach."),
            (#"{"command": "x", "url": "https://x.example.com"}"#, "It has both a command and a url; give it a type, or keep one."),
            (#"{"type": "ws", "url": "wss://x"}"#, "Its type is ws; Next Term runs stdio, http and sse servers."),
            (#"{"type": "http", "command": "x"}"#, "Its type is http, and it has no url."),
            (#"{"type": "stdio"}"#, "Its type is stdio, and it has no command."),
            (#"{"command": 1}"#, "Its command is not text."),
            (#"{"command": "x", "args": "-y"}"#, "Its args is not a list."),
            (#"{"command": "x", "args": ["-y", 2]}"#, "Its args has something other than text in it."),
            (#"{"command": "x", "env": {"A": 1}}"#, "Its env.A is not text."),
            (#"{"command": "x", "env": {"A": "1", "A": "2"}}"#, "Its env has A twice."),
            (#"{"command": "x", "command": "y"}"#, "It has command twice."),
            (#"{"command": "x", "nextTerm": true}"#, "Its nextTerm is not an object."),
            (#"{"command": "x", "nextTerm": {"enabled": "yes"}}"#, "Its nextTerm.enabled is not true or false."),
            (#"{"command": "x", "nextTerm": {"enabled": true, "enabled": false}}"#, "Its nextTerm has enabled twice."),
            (#"{"command": "x", "nextTerm": {"projects": "some"}}"#, "Its nextTerm.projects is neither \"all\" nor a list of folders."),
        ]
        for (json, reason) in fails {
            let found = try decode(json)
            #expect(found == .failure(MCPHubServer.Broken(reasons: [reason])), "\(json): \(found)")
        }
        // The rules apply to what is read.
        guard case .failure(let broken) = try decode(#"{"url": "javascript:alert(1)"}"#) else { Issue.record("javascript: was read"); return }
        #expect(broken.reasons.first?.contains("Next Term reaches only https://") == true)
    }

    @Test func defaultsAreOnForAllProjects() throws {
        let server = try decode(#"{"command": "x", "nextTerm": {"projects": ["~/a"]}}"#).get()
        #expect(server.enabled && server.projects == .only(["~/a"]))
        #expect(try decode(#"{"command": "x", "nextTerm": {"projects": "nonsense"}}"#, place: .project).get().projects == .all)
        #expect(try decode(#"{"command": "x"}"#).get() == .local("s", command: "x"))
    }
}
