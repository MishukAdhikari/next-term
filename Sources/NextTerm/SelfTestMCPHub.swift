#if DEBUG
import AppKit
import CryptoKit
import NextTermCore

/// The MCP hub, step 2: a fake local server added to a list of the self-test's own (MCPHubControl.userFile), for one
/// folder, and the real `nxtrm mcp` run from a tab's shell as an agent there starts it. The bridge asks the app for its
/// plan, lists the catalog after Next Term's own tools, and starts the server on its first call, in the tab's folder with
/// the list's variable; the server ends with the bridge. A tab in another folder gets Next Term's own tools and no
/// catalog, and no agent's config file changes. Step 4: the server's tool list, kept beside the self-test's list after that
/// first use, gives the next agent there its tools as its own. The user's own list is never read or written here.
extension SelfTest {
    /// The fake server: `echo` says hello, `where` says its folder, HUB_TEST and its process id.
    static let hubFakeServer = #"""
    #!/bin/sh
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"1"}}}\n' "$id" ;;
        *'"method":"tools/list"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","description":"Says hello back","inputSchema":{"type":"object"}},{"name":"where","description":"Its folder, variable and process","inputSchema":{"type":"object"}}]}}\n' "$id" ;;
        *'"name":"echo"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"hello from fake"}]}}\n' "$id" ;;
        *'"name":"where"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"%s|%s|%s"}]}}\n' "$id" "$(pwd -P)" "$HUB_TEST" "$$" ;;
      esac
    done
    """#

    static func mcpHubChecks(_ c: TerminalWindowController, proj: URL) async {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-mcphub-\(getpid())")
        let inScope = dir.appendingPathComponent("app"), outside = dir.appendingPathComponent("other")
        for folder in [inScope, outside] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let script = dir.appendingPathComponent("fake-server.sh").path
        try? hubFakeServer.write(toFile: script, atomically: true, encoding: .utf8)
        let userFile = dir.appendingPathComponent("hub/mcp.json").path
        let savedFile = MCPHubControl.userFile
        MCPHubControl.userFile = userFile
        defer {
            MCPHubControl.userFile = savedFile
            try? FileManager.default.removeItem(at: dir)
        }
        let configs = agentConfigDigests()
        let own = MCPServer.respond(to: ["jsonrpc": "2.0", "id": 2, "method": "tools/list"], version: "0") { _, _ in MCPServer.CallResult(text: "") }
        let ownTools = sortedJSON((own?["result"] as? [String: Any])?["tools"])

        // Before any server (R17): no list and no catalog, nothing is made, and Next Term's own tools are all there,
        // add_mcp_server and list_mcp_servers among them, so an agent can add the first server.
        let initialize: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                         "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                                                    "clientInfo": ["name": "self-test", "version": "1"]]]
        let listTools: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "tools/list"]
        let none = await bridgeInTab(c, folder: inScope, requests: [initialize, listTools], name: "none", userFile: userFile)
        let noneNames = toolNames(none[2])
        check(sortedJSON((none[2]?["result"] as? [String: Any])?["tools"]) == ownTools && noneNames == MCPServer.tools.map(\.name)
                && noneNames.contains("add_mcp_server") && noneNames.contains("list_mcp_servers")
                && !noneNames.contains { MCPHubCatalog.isCatalogTool($0) } && !FileManager.default.fileExists(atPath: userFile),
              "MCP hub: with no server, an agent gets Next Term's own tools, add_mcp_server among them, no catalog, and no list is made",
              "\(noneNames.count) tools")

        // Through the hub's own API, as Settings › MCP will: the file and its folder are made with the first server.
        let fake = MCPHubServer.local("fake", command: "/bin/sh", args: [script], env: ["HUB_TEST": "selftest"],
                                      projects: .only([canonicalPath(inScope.path)]))
        let saved = MCPHubScope.save(.set(fake), to: userFile, place: .user)
        check(saved == .success(.written) && FileManager.default.fileExists(atPath: userFile), "MCP hub: a server added makes the list",
              "\(saved)")

        // An agent in the folder: initialize, its tool list, then the catalog.
        let requests: [[String: Any]] = [
            initialize,
            listTools,
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "mcp_servers", "arguments": [String: Any]()]],
            ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "mcp_call", "arguments": ["server": "fake", "tool": "echo"]]],
            ["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "mcp_call", "arguments": ["server": "fake", "tool": "where"]]],
        ]
        let answers = await bridgeInTab(c, folder: inScope, requests: requests, name: "in", userFile: userFile)
        let names = toolNames(answers[2])
        check(names == MCPServer.tools.map(\.name) + MCPHubCatalog.tools.map(\.name),
              "MCP hub: an agent in the server's folder gets the catalog after Next Term's own tools",
              "\(answers.count) answers; last tools: \(names.suffix(4))")
        let listed = resultText(answers[3])
        // Asked beside the two calls, so it may be started already.
        check(listed.contains("\"fake\"") && (listed.contains("\"ready\"") || listed.contains("\"running\"")),
              "MCP hub: mcp_servers lists the server", listed)
        check(resultText(answers[4]) == "hello from fake", "MCP hub: mcp_call reaches the server's tool", resultText(answers[4]))
        let whereParts = resultText(answers[5]).split(separator: "|").map(String.init)
        check(whereParts.count == 3 && whereParts[0] == canonicalPath(inScope.path) && whereParts[1] == "selftest",
              "MCP hub: the server runs in the tab's folder with its list's variable", resultText(answers[5]))
        if whereParts.count == 3, let pid = pid_t(whereParts[2]) {
            let ended = await wait(5) { kill(pid, 0) != 0 }
            check(ended, "MCP hub: the server ends with the agent's session", "pid \(pid)")
        }

        // Step 4: that session's start kept the server's tools beside the list, so the next agent there has them as its
        // own (R5), after the catalog, and a call to one is mcp_call's.
        let sidecar = MCPHubManifest.file(fake, list: userFile, userFile: userFile)
        check(FileManager.default.fileExists(atPath: sidecar) && sidecar.hasPrefix(dir.path),
              "MCP hub: a server's first use keeps its tool list beside the self-test's list", sidecar)
        let direct = await bridgeInTab(c, folder: inScope, requests: [
            initialize, listTools,
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "fake__echo", "arguments": [String: Any]()]],
            ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "mcp_servers", "arguments": [String: Any]()]],
        ], name: "direct", userFile: userFile)
        let directNames = toolNames(direct[2])
        check(directNames == MCPServer.tools.map(\.name) + MCPHubCatalog.tools.map(\.name) + ["fake__echo", "fake__where"],
              "MCP hub: the next agent gets the server's tools as its own, after the catalog", "\(directNames.suffix(5))")
        check(resultText(direct[3]) == "hello from fake", "MCP hub: a direct tool reaches the server's tool", resultText(direct[3]))
        check(resultText(direct[4]).contains("\"direct_tools\" : 2"), "MCP hub: mcp_servers says which tools are the agent's own",
              resultText(direct[4]))

        // An agent elsewhere: Next Term's own tools, byte for byte once sorted, and no catalog.
        let elsewhere = await bridgeInTab(c, folder: outside, requests: [initialize, listTools], name: "out", userFile: userFile)
        check(sortedJSON((elsewhere[2]?["result"] as? [String: Any])?["tools"]) == ownTools,
              "MCP hub: an agent in a folder the server isn't for gets Next Term's own tools and no catalog", "\(toolNames(elsewhere[2]).count) tools")

        await mcpHubRemoteChecks(c, folder: inScope, userFile: userFile, initialize: initialize)

        check(agentConfigDigests() == configs, "MCP hub: no agent's config file changed")
    }

    /// Step 7: a server at a URL (a fake on this Mac, MCPHubFakeRemote), reached by the app for the agent's bridge, over
    /// Streamable HTTP with a session; and one that wants a key Next Term doesn't send, whose 401 tells the agent where
    /// the user checks it. Settings' state for each is what the need ended in.
    private static func mcpHubRemoteChecks(_ c: TerminalWindowController, folder: URL, userFile: String, initialize: [String: Any]) async {
        guard let open = try? MCPHubFakeRemote(), let locked = try? MCPHubFakeRemote() else {
            return check(false, "MCP hub: the fake remote servers listen on this Mac")
        }
        defer { open.stop(); locked.stop() }
        open.sessions = true
        locked.bearer = "never-sent"
        let scope = MCPHubServer.Projects.only([canonicalPath(folder.path)])
        for server in [MCPHubServer.remote("remote", url: open.url.absoluteString, projects: scope),
                       MCPHubServer.remote("locked", url: locked.url.absoluteString, projects: scope)] {
            _ = MCPHubScope.save(.set(server), to: userFile, place: .user)
        }
        let requests: [[String: Any]] = [
            initialize,
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "mcp_call", "arguments": ["server": "remote", "tool": "echo", "arguments": ["say": "hi"]]]],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "mcp_tools", "arguments": ["server": "locked"]]],
            ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "mcp_servers", "arguments": [String: Any]()]],
        ]
        let answers = await bridgeInTab(c, folder: folder, requests: requests, name: "remote", userFile: userFile)
        check(resultText(answers[2]) == "hello from remote", "MCP hub: mcp_call reaches a server at a URL through the app", resultText(answers[2]))
        let seen = open.seen
        check(seen.map(\.method).prefix(4) == ["initialize", "notifications/initialized", "tools/list", "tools/call"]
                && seen.dropFirst().allSatisfy { $0.headers["mcp-session-id"] != nil && $0.headers["user-agent"]?.hasPrefix("NextTerm/") == true },
              "MCP hub: the app speaks Streamable HTTP to it, with one session", seen.map(\.method).joined(separator: ", "))
        check(resultText(answers[3]).contains("Settings › MCP Servers"), "MCP hub: a 401 tells the agent where the user checks the key",
              resultText(answers[3]))
        check(resultText(answers[4]).contains("\"running\""), "MCP hub: mcp_servers lists the remote server running", resultText(answers[4]))
        // The app kept the remote server's tools as it listed them, so the next agent has them as its own too.
        let next = await bridgeInTab(c, folder: folder, requests: [
            initialize, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "remote__echo", "arguments": ["say": "hi"]]],
        ], name: "remote-direct", userFile: userFile)
        check(toolNames(next[2]).contains("remote__echo") && !toolNames(next[2]).contains { $0.hasPrefix("locked__") },
              "MCP hub: a remote server's tools are the next agent's own, and one that refused isn't", "\(toolNames(next[2]).suffix(6))")
        check(resultText(next[3]) == "hello from remote", "MCP hub: a remote server's direct tool reaches it through the app", resultText(next[3]))
        let ran = MCPHubControl.lastRuns[MCPHubOverview.runKey(list: userFile, server: "remote")]
        let refused = MCPHubControl.lastRuns[MCPHubOverview.runKey(list: userFile, server: "locked")]
        check(ran == MCPHubOverview.Run(failure: nil, tools: 3) && refused?.failure?.contains("HTTP 401") == true,
              "MCP hub: Settings shows the remote servers ready and failed, with why", "\(String(describing: ran)) \(String(describing: refused))")
        for name in ["remote", "locked"] { _ = MCPHubScope.save(.remove(name), to: userFile, place: .user) }
    }

    /// Runs `nxtrm mcp` in a new tab in `folder`, as an agent there starts it, with `requests` on its stdin and the
    /// self-test's list for the user's: its answers, by id, once it ends.
    private static func bridgeInTab(_ c: TerminalWindowController, folder: URL, requests: [[String: Any]], name: String,
                                    userFile: String) async -> [Int: [String: Any]] {
        let input = folder.deletingLastPathComponent().appendingPathComponent("\(name).jsonl")
        let output = folder.deletingLastPathComponent().appendingPathComponent("\(name)-answers.jsonl")
        let lines = requests.compactMap { try? JSONSerialization.data(withJSONObject: $0, options: [.withoutEscapingSlashes]) }
            .map { String(decoding: $0, as: UTF8.self) }
        try? (lines.joined(separator: "\n") + "\n").write(to: input, atomically: true, encoding: .utf8)
        let tab = c.addTab(directory: folder.path, select: false)
        defer { c.remove(tab) }
        guard await wait(20, { tab.status.integrated }) else {
            check(false, "MCP hub: the \(name) tab starts its shell")
            return [:]
        }
        let program = ShellQuote.quote(Bundle.main.executablePath ?? CommandLine.arguments[0])
        let socket = ShellQuote.quote(MCPControlServer.shared.path)
        let list = MCPBridgeHub.selfTestUserFileVariable + "=" + ShellQuote.quote(userFile)
        tab.view.send(txt: "\(MCPServer.socketVariable)=\(socket) \(list) \(program) --cli mcp < \(ShellQuote.quote(input.path)) > \(ShellQuote.quote(output.path)); echo HUB\"\"DONE\r")
        _ = await wait(30) { tab.screenTail(6).contains { $0.contains("HUBDONE") } }
        let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        var answers: [Int: [String: Any]] = [:]
        for line in text.split(separator: "\n") {
            if let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let id = object["id"] as? Int {
                answers[id] = object
            }
        }
        return answers
    }

    private static func toolNames(_ answer: [String: Any]?) -> [String] {
        ((answer?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    private static func resultText(_ answer: [String: Any]?) -> String {
        (((answer?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    private static func sortedJSON(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Every agent config file Next Term registers in (MCPRegistrar), by path: its bytes' SHA-256, or "none"; and Claude
    /// Code's servers in `~/.claude.json`, which Claude Code itself rewrites all the time (a session running beside the
    /// self-test included), so only its `mcpServers` count. Only read.
    private static func agentConfigDigests() -> [String: String] {
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        var digests: [String: String] = [:]
        for file in MCPRegistrar.targets().map(\.file) {
            digests[file] = FileManager.default.contents(atPath: file).map(digest) ?? "none"
        }
        let claude = (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")
        let servers = FileManager.default.contents(atPath: claude)
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["mcpServers"]
        digests[claude + " mcpServers"] = sortedJSON(servers)
        return digests
    }
}
#endif
