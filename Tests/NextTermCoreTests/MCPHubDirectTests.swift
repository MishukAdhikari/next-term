import Foundation
import Testing
@testable import NextTermCore

/// Direct tools (R5): their names (`<server>__<tool>` within every agent's limits, a digest on what had to change or
/// clash, never one of Next Term's own), the budget a session has, the cached tool list they are made from (its file,
/// round trip and cuts), and a session that lists them after the catalog and calls one as mcp_call would.
@Suite struct MCPHubDirectTests {
    /// What every agent and API takes: Anthropic's pattern, within the 64 of OpenAI-style limits once an agent's prefix
    /// is in front, and under the 63 past which Gemini CLI keeps only a name's ends.
    func agentsTake(_ name: String) -> Bool {
        let longest = "mcp__next-term__" + name, gemini = "mcp_next-term_" + name
        return name.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil && longest.count <= 64 && gemini.count <= 63
    }

    // MARK: names

    @Test func aToolKeepsItsNameWhenItCan() {
        let named = MCPHubDirect.names([("github", ["create_issue", "list-prs"]), ("fs", ["read"])])
        #expect(named == [["github__create_issue", "github__list-prs"], ["fs__read"]])
        #expect(MCPHubDirect.nameLimit == 48)
    }

    @Test func aNameThatHadToChangeOrRunsOverEndsInADigest() throws {
        let long = String(repeating: "very_long_tool_name_", count: 6)
        let named = MCPHubDirect.names([("srv", ["files.read", "naïve tool", long, ""])])[0].map { $0 ?? "" }
        for name in named {
            #expect(agentsTake(name), "\(name)")
            #expect(name.range(of: #"_[0-9a-f]{6}$"#, options: .regularExpression) != nil, "\(name)")
            #expect(name.hasPrefix("srv__"))
        }
        #expect(named[0].hasPrefix("srv__files_read_"))
        #expect(named[1].hasPrefix("srv__na_ve_tool_"))
        #expect(named[2].count == MCPHubDirect.nameLimit)
        // The same in every session, whatever else the server lists.
        let again = MCPHubDirect.names([("srv", ["other", long, "files.read"])])[0]
        #expect(again[2] == named[0] && again[1] == named[2])
        // A long server name still leaves room.
        let server = String(repeating: "s", count: 32)
        #expect(MCPHubDirect.names([(server, ["anything_at_all"])])[0].allSatisfy { $0.map(agentsTake) == true })
    }

    @Test func ofToolsWhoseNamesClashTheFirstInByteOrderKeepsIt() throws {
        // Case and - against _ don't tell names apart (Codex folds them; some APIs ignore case).
        let named = MCPHubDirect.names([("srv", ["get_user", "Get_User", "get-user", "getuser"])])[0].map { $0 ?? "" }
        #expect(named[1] == "srv__Get_User") // "Get_User" < "get-user" < "get_user" in bytes
        #expect(named[0].hasPrefix("srv__get_user_") && named[2].hasPrefix("srv__get-user_"))
        #expect(named[3] == "srv__getuser") // no clash: it has no _ to fold
        #expect(Set(named.map { $0.lowercased().replacingOccurrences(of: "-", with: "_") }).count == 4)
        // Order doesn't change who keeps it.
        let reversed = MCPHubDirect.names([("srv", ["getuser", "get-user", "Get_User", "get_user"])])[0]
        #expect(Array(reversed.reversed()) == named.map { Optional($0) })
        // Across servers too: a changed name never takes one another server kept.
        let across = MCPHubDirect.names([("a", ["b__c"]), ("a-b", ["c"])]).flatMap { $0 }.compactMap { $0 }
        #expect(Set(across.map { $0.lowercased().replacingOccurrences(of: "-", with: "_") }).count == across.count)
    }

    @Test func aNameIsNeverOneOfNextTermsOwn() throws {
        // None of Next Term's own (nor the catalog's) has a direct tool's `__`, and a reserved name is passed by.
        #expect(!MCPHubDirect.reserved.contains { MCPHubDirect.isDirectName($0) })
        let named = MCPHubDirect.names([("srv", ["x"])], reserved: ["srv__x"])[0]
        #expect(named[0] != "srv__x" && named[0]?.hasPrefix("srv__x_") == true)
        let folded = MCPHubDirect.names([("srv", ["X"])], reserved: ["srv__x"])[0]
        #expect(folded[0] != "srv__X")
    }

    // MARK: the budget

    func manifest(_ count: Int, prefix: String = "t") -> MCPHubManifest {
        MCPHubManifest(tools: (0..<count).map { MCPHubManifest.Tool(name: "\(prefix)\($0)") })
    }

    @Test func serversTakeTheBudgetInTurnAllOrNone() {
        var plan = MCPHubPlan(folder: "/w", servers: ["a", "b", "c", "d", "e"].map {
            MCPHubPlan.Server(name: $0, state: .ready, command: "x", list: "/u")
        } + [MCPHubPlan.Server(name: "f", state: .off, command: "x", list: "/u")])
        var incomplete = manifest(3)
        incomplete.count = 300
        plan.allotDirect(["a": manifest(30), "b": manifest(20), "c": manifest(5), "d": incomplete, "f": manifest(1)])
        let given = plan.servers.map { $0.tools?.count }
        // b doesn't fit in what a left; c still does. e has no cached list, d an incomplete one, f is off.
        #expect(given == [30, nil, 5, nil, nil, nil])
        #expect(plan.servers.map(\.cachedTools) == [30, 20, 5, 300, nil, nil])
        #expect(plan.server(named: "b")?.manifest == manifest(20).digest)
        #expect(MCPHubDirect.entries(plan).count == 35)
        // A server over the whole budget is never direct.
        var big = MCPHubPlan(folder: "/w", servers: [MCPHubPlan.Server(name: "big", state: .ready, command: "x", list: "/u")])
        big.allotDirect(["big": manifest(MCPHubDirect.budget + 1)])
        #expect(big.servers[0].tools == nil)
        #expect(MCPHubDirect.budget == 40)
    }

    @Test func aToolWithASchemaAgentsCantTakeStaysWithTheCatalog() {
        let listed: [[String: Any]] = [
            ["name": "ok", "inputSchema": ["type": "object", "properties": ["q": ["type": "string"]]]],
            ["name": "array", "inputSchema": ["type": "array"]],
            ["name": "huge", "inputSchema": ["type": "object", "description": String(repeating: "x", count: MCPHubManifest.schemaLimit)]],
            ["name": "none"],
            ["description": "no name"],
        ]
        let made = MCPHubManifest(listed: listed)
        #expect(made.tools.map(\.name) == ["ok", "array", "huge", "none"] && made.isComplete)
        #expect(made.tools.map { $0.inputSchema != nil } == [true, false, false, true])
        var plan = MCPHubPlan(folder: "/w", servers: [MCPHubPlan.Server(name: "s", state: .ready, command: "x", list: "/u")])
        plan.allotDirect(["s": made])
        #expect(plan.servers[0].tools?.map(\.name) == ["ok", "none"] && plan.servers[0].cachedTools == 4)
    }

    // MARK: the listing

    @Test func aDirectToolCarriesItsServersWordsHintsAndName() throws {
        let long = String(repeating: "word ", count: 400)
        let tool = try #require(MCPHubManifest.Tool(listed: [
            "name": "search", "title": "Search issues", "description": long,
            "inputSchema": ["type": "object", "properties": ["q": ["type": "string"]], "required": ["q"]],
            "annotations": ["readOnlyHint": true, "openWorldHint": false, "title": "ignored"],
        ]))
        #expect(tool.description?.count == MCPHubManifest.descriptionLimit && tool.description?.hasSuffix("\u{2026}") == true)
        let listed = MCPServer.listing([MCPHubDirect.listed(MCPHubDirect.Entry(name: "linear__search", server: "linear", tool: tool))])[0]
        #expect(listed["name"] as? String == "linear__search" && listed["title"] as? String == "linear: Search issues")
        let annotations = try #require(listed["annotations"] as? [String: Any])
        #expect(annotations["readOnlyHint"] as? Bool == true && annotations["openWorldHint"] as? Bool == false)
        // Left out: MCP's defaults, as the server's own listing would mean.
        #expect(annotations["destructiveHint"] as? Bool == true && annotations["idempotentHint"] as? Bool == false)
        #expect((listed["inputSchema"] as? [String: Any])?["required"] as? [String] == ["q"])
        // Deferred for Claude Code, tagged write as mcp_call is.
        let meta = try #require(listed["_meta"] as? [String: Any])
        #expect(meta["anthropic/alwaysLoad"] == nil && meta["next-term/scope"] as? String == "write")
        // No title: the tool's name, after its server's.
        let bare = MCPHubDirect.listed(MCPHubDirect.Entry(name: "s__t", server: "s", tool: MCPHubManifest.Tool(name: "t")))
        #expect(bare.title == "s: t" && bare.description == "t, a tool of s.")
    }

    // MARK: the cached list

    @Test func theCachedListRoundTripsBesideTheUsersList() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nt-mcphub-manifest-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let userFile = home + "/Next Term/mcp.json"
        let server = MCPHubServer.local("github", command: "npx", args: ["-y", "server"], env: ["A": "1"])
        #expect(MCPHubManifest.read(server, list: userFile, userFile: userFile) == nil)
        let made = MCPHubManifest(listed: [["name": "echo", "description": "Says hello", "annotations": ["readOnlyHint": true]]])
        #expect(MCPHubManifest.remember(made, server: server, list: userFile, userFile: userFile))
        #expect(MCPHubManifest.read(server, list: userFile, userFile: userFile) == made)
        // The same again writes nothing.
        #expect(!MCPHubManifest.remember(made, server: server, list: userFile, userFile: userFile))
        let file = MCPHubManifest.file(server, list: userFile, userFile: userFile)
        #expect(file.hasPrefix(home + "/Next Term/mcp-tools.noindex/github-") && file.hasSuffix(".json"))
        let folder = try FileManager.default.attributesOfItem(atPath: (file as NSString).deletingLastPathComponent)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        // Another command, another list, or a key named differently: none cached for it.
        var changed = server
        changed.args = ["-y", "other"]
        #expect(MCPHubManifest.read(changed, list: userFile, userFile: userFile) == nil)
        #expect(MCPHubManifest.read(server, list: home + "/p/.next-term/mcp.json", userFile: userFile) == nil)
        let remote = MCPHubServer.remote("web", url: "https://example.com/mcp", headers: ["Authorization": "Bearer ${secret:A}"])
        var other = remote
        other.headers = ["Authorization": "Bearer ${secret:B}"]
        #expect(MCPHubManifest.identity(remote, list: userFile) != MCPHubManifest.identity(other, list: userFile))
        // The digest follows the tools.
        #expect(made.digest == MCPHubManifest(listed: [["name": "echo", "description": "Says hello", "annotations": ["readOnlyHint": true]]]).digest)
        #expect(made.digest != MCPHubManifest(listed: [["name": "echo"]]).digest)
        // Masked before it is kept: a stored key's value never reaches the file.
        let leaky = MCPHubManifest(listed: [["name": "x", "description": "uses sk-123"]]).masked { $0.replacingOccurrences(of: "sk-123", with: "•••") }
        #expect(leaky.tools[0].description == "uses •••")
    }

    @Test func aPlanCarriesItsDirectToolsOverTheSocket() throws {
        var plan = MCPHubPlan(folder: "/w", servers: [MCPHubPlan.Server(name: "s", state: .ready, command: "x", list: "/u")])
        plan.allotDirect(["s": MCPHubManifest(listed: [["name": "t", "inputSchema": ["type": "object"]]])])
        let decoded = try #require(MCPHubPlan.decode(plan.text))
        #expect(decoded == plan && decoded.servers[0].tools?.first?.name == "t")
        // A plan without them reads as it did.
        let older = #"{"folder":"/w","path":[],"problems":[],"servers":[{"args":[],"command":"x","env":{},"list":"/u","name":"s","state":"ready","url":""}]}"#
        #expect(MCPHubPlan.decode(older)?.servers.first?.tools == nil)
        // What a bridge reports goes through the same cuts again.
        let sent = MCPHubManifest.Tool(name: "t", description: String(repeating: "x", count: 5_000), inputSchema: #"{"type":"string"}"#)
        let checked = MCPHubManifest.Tool(checking: sent)
        #expect(checked.description?.count == MCPHubManifest.descriptionLimit && checked.inputSchema == nil)
    }

    // MARK: in a session

    func fakeScript() throws -> (folder: String, script: String) {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("nt-mcphub-direct-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: made + "/work", withIntermediateDirectories: true)
        try MCPHubSessionTests.fake.write(toFile: made + "/fake.sh", atomically: true, encoding: .utf8)
        return (canonicalPath(made + "/work"), made + "/fake.sh")
    }

    func text(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    @Test func aSessionListsDirectToolsAfterTheCatalogAndCallsThemAsMcpCall() throws {
        let (folder, script) = try fakeScript()
        defer { try? FileManager.default.removeItem(atPath: (folder as NSString).deletingLastPathComponent) }
        let cached = MCPHubManifest(listed: [["name": "echo", "description": "Says hello back", "inputSchema": ["type": "object"]],
                                             ["name": "where", "inputSchema": ["type": "object"]]])
        var plan = MCPHubPlan(folder: folder, path: ["/usr/bin", "/bin"], servers: [
            MCPHubPlan.Server(name: "fake", state: .ready, command: "/bin/sh", args: [script], env: ["HUB_TEST": "direct"], list: "/u"),
            MCPHubPlan.Server(name: "later", state: .ready, command: "/bin/sh", args: [script], list: "/u"),
        ])
        plan.allotDirect(["fake": cached])
        let fixed = plan
        let told = Told()
        let hub = MCPHubSession(plan: fixed, refresh: { fixed }, nxtrm: ["/usr/bin/true"], environment: ["HOME": NSHomeDirectory()],
                                version: "0", remember: { server, _, manifest in told.add(server, manifest) })
        defer { hub.stop() }
        let listed = MCPServer.respond(to: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"], version: "0", extra: hub.tools) { _, _ in
            MCPServer.CallResult(text: "")
        }
        let names = ((listed?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        #expect(names == MCPServer.tools.map(\.name) + MCPHubCatalog.tools.map(\.name) + ["fake__echo", "fake__where"])

        // Called as mcp_call is: the server starts in the folder with its list's variable.
        let called = MCPServer.respond(to: ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "fake__where", "arguments": [String: Any]()]],
                                       version: "0", extra: hub.tools, callExtra: hub.call) { _, _ in MCPServer.CallResult(text: "") }
        #expect(text(called?["result"] as? [String: Any] ?? [:]) == folder + "|direct")
        #expect(text(hub.call("fake__echo", [:])) == "hello from fake")
        // The server lists six tools, not the two cached: the app is told, once.
        #expect(told.all.map(\.0) == ["fake"] && told.all.first?.1.tools.count == 6)
        _ = hub.call("fake__echo", [:])
        #expect(told.all.count == 1)

        // mcp_servers says which come as the agent's own, and which wait for the next session.
        let servers = (try? JSONSerialization.jsonObject(with: Data(text(hub.call("mcp_servers", [:])).utf8))) as? [String: Any]
        let rows = servers?["servers"] as? [[String: Any]] ?? []
        #expect(rows.first { $0["name"] as? String == "fake" }?["direct_tools"] as? Int == 2)
        #expect((rows.first { $0["name"] as? String == "later" }?["direct"] as? String)?.contains("next session") == true)
        // A name it doesn't have is unknown, as before.
        #expect(text(hub.call("fake__nothing", [:])).hasPrefix("Unknown tool"))
    }

    @Test func aSessionWhoseServerListsWhatWasCachedTellsNothing() throws {
        let (folder, script) = try fakeScript()
        defer { try? FileManager.default.removeItem(atPath: (folder as NSString).deletingLastPathComponent) }
        let server = MCPHubPlan.Server(name: "fake", state: .ready, command: "/bin/sh", args: [script], list: "/u")
        // Learn its list once, as a first session would.
        let first = Told()
        let learner = MCPHubSession(plan: MCPHubPlan(folder: folder, servers: [server]), refresh: { nil }, nxtrm: ["/usr/bin/true"],
                                    environment: ["HOME": NSHomeDirectory()], version: "0", remember: { first.add($0, $2) })
        #expect(text(learner.call("mcp_call", ["server": "fake", "tool": "echo"])) == "hello from fake")
        learner.stop()
        let learned = try #require(first.all.first?.1)
        // The next session starts with it: six direct tools, and nothing to tell.
        var plan = MCPHubPlan(folder: folder, servers: [server])
        plan.allotDirect(["fake": learned])
        let fixed = plan
        let again = Told()
        let hub = MCPHubSession(plan: fixed, refresh: { fixed }, nxtrm: ["/usr/bin/true"], environment: ["HOME": NSHomeDirectory()],
                                version: "0", remember: { again.add($0, $2) })
        defer { hub.stop() }
        #expect(hub.tools.count == MCPHubCatalog.tools.count + 6)
        #expect(text(hub.call("fake__echo", [:])) == "hello from fake")
        #expect(again.all.isEmpty)
    }

    final class Told: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(String, MCPHubManifest)] = []
        func add(_ server: String, _ manifest: MCPHubManifest) {
            lock.lock()
            values.append((server, manifest))
            lock.unlock()
        }
        var all: [(String, MCPHubManifest)] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    /// A server's words are capped by what reaches the agent: a tool named past 128 stays with the catalog, and a cut
    /// counts Unicode scalars, so combining marks can't stretch 1,024 characters into megabytes.
    @Test func aServersWordsAreCappedByWhatReachesTheAgent() {
        let long = String(repeating: "n", count: MCPHubManifest.nameLimit + 1)
        let manifest = MCPHubManifest(listed: [["name": long], ["name": "fine"]])
        #expect(manifest.tools.map(\.name) == ["fine"] && manifest.isComplete)
        let zalgo = String(repeating: "a" + String(repeating: "\u{0301}", count: 50), count: 2_000)
        let tool = MCPHubManifest.Tool(listed: ["name": "z", "description": zalgo, "title": zalgo])
        #expect(tool?.description?.unicodeScalars.count == MCPHubManifest.descriptionLimit)
        #expect(tool?.title?.unicodeScalars.count == MCPHubManifest.titleLimit)
        let checked = MCPHubManifest(tools: [MCPHubManifest.Tool(name: long), MCPHubManifest.Tool(name: "fine")], count: 2)
        #expect(checked.tools.map(\.name) == ["fine"] && !checked.isComplete) // a bridge's report with one dropped: catalog only
    }
}
