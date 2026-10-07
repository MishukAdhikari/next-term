import Foundation
import Testing
@testable import NextTermCore

@Suite struct MCPServerTests {
    func answer(_ message: [String: Any]) -> [String: Any]? {
        MCPServer.respond(to: message, version: "1.2.3") { name, arguments in
            MCPServer.CallResult(text: "\(name) \(arguments["tab_id"] as? String ?? "")")
        }
    }

    @Test func initializeEchoesASupportedVersion() {
        let reply = answer(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        let result = reply?["result"] as? [String: Any]
        #expect(result?["protocolVersion"] as? String == "2025-06-18")
        #expect((result?["serverInfo"] as? [String: Any])?["name"] as? String == "next-term")
        #expect((result?["instructions"] as? String)?.contains("list_tabs") == true)
        // A version it does not know: the newest it does.
        let newer = answer(["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "2099-01-01"]])
        #expect((newer?["result"] as? [String: Any])?["protocolVersion"] as? String == MCPServer.supportedVersions[0])
    }

    @Test func toolsAreListedWithHonestAnnotations() throws {
        let reply = answer(["jsonrpc": "2.0", "id": "a", "method": "tools/list"])
        let tools = try #require((reply?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.count == MCPServer.tools.count)
        func hints(_ name: String) -> [String: Any] {
            tools.first { $0["name"] as? String == name }?["annotations"] as? [String: Any] ?? [:]
        }
        #expect(hints("list_tabs")["readOnlyHint"] as? Bool == true)
        #expect(hints("read_tab")["readOnlyHint"] as? Bool == true)
        // Typing into a terminal can run anything: clients must be able to ask first.
        #expect(hints("send_to_tab")["destructiveHint"] as? Bool == true)
        #expect(hints("new_tab")["destructiveHint"] as? Bool == true)
        #expect(hints("close_tab")["destructiveHint"] as? Bool == true)
        #expect(hints("open_in_editor")["destructiveHint"] as? Bool == false)
        // Answering an agent's question decides for the user: clients ask first.
        #expect(hints("answer_agent")["readOnlyHint"] as? Bool == false && hints("answer_agent")["destructiveHint"] as? Bool == true)
        #expect(hints("answer_agent")["idempotentHint"] as? Bool == false)
        // The project tools only read.
        for name in ["read_file", "find_in_files", "git_status", "get_diff"] {
            #expect(hints(name)["readOnlyHint"] as? Bool == true && hints(name)["destructiveHint"] as? Bool == false, "\(name)")
            #expect(hints(name)["idempotentHint"] as? Bool == true, "\(name)")
        }
        let answer = try #require(tools.first { $0["name"] as? String == "answer_agent" }?["inputSchema"] as? [String: Any])
        #expect(answer["required"] as? [String] == ["tab_id", "question_id"])
        // Only the tools that reach a server over ssh go beyond this Mac; everything else stays local.
        let remote: Set<String> = ["check_host", "new_remote_tab", "host_sessions", "host_changes"]
        #expect(tools.allSatisfy { (($0["annotations"] as? [String: Any])?["openWorldHint"] as? Bool) == remote.contains($0["name"] as? String ?? "") })
        // Saving hosts, opening remote tabs and running anything on a host: clients ask first.
        for name in ["add_host", "remove_host", "check_host", "new_remote_tab", "host_sessions", "host_changes"] {
            #expect(hints(name)["destructiveHint"] as? Bool == true)
        }
        #expect(hints("list_hosts")["readOnlyHint"] as? Bool == true)
        // A saved host is never re-pointed by add_host (RemoteMCP refuses it): the description says so.
        let addHost = tools.first { $0["name"] as? String == "add_host" }?["description"] as? String ?? ""
        #expect(addHost.contains("only directory and keep change") && addHost.contains("remove_host") && !addHost.contains("is updated"))
        // Every schema is a JSON object schema (the raw strings parse).
        #expect(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })
        #expect(tools.allSatisfy { (($0["_meta"] as? [String: Any])?["anthropic/alwaysLoad"] as? Bool) == true })
    }

    @Test func callsGoToTheAppAndUnknownsAreErrors() {
        let reply = answer(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "read_tab", "arguments": ["tab_id": "x"]]])
        let content = ((reply?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first
        #expect(content?["text"] as? String == "read_tab x")
        let unknown = answer(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "rm_rf"]])
        #expect((unknown?["error"] as? [String: Any])?["code"] as? Int == -32602)
        let method = answer(["jsonrpc": "2.0", "id": 5, "method": "sampling/createMessage"])
        #expect((method?["error"] as? [String: Any])?["code"] as? Int == -32601)
        // Notifications get no answer.
        #expect(answer(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
    }

    @Test func socketLinesRoundTrip() throws {
        let request = try #require(MCPServer.request(tool: "send_to_tab", arguments: ["tab_id": "t", "text": "hi\nthere"]))
        #expect(request.last == 0x0A && request.dropLast().contains(0x0A) == false) // one line, newlines escaped
        let answer = MCPServer.encodeAnswer(.init(text: "a\nb", isError: true))
        let decoded = try #require(MCPServer.decodeAnswer(answer.dropLast()))
        #expect(decoded.text == "a\nb" && decoded.isError)
    }

    @Test func keys() {
        #expect(MCPServer.keyBytes("enter") == "\r")
        #expect(MCPServer.keyBytes("Escape") == "\u{1b}")
        #expect(MCPServer.keyBytes("shift+tab") == "\u{1b}[Z")
        #expect(MCPServer.keyBytes("ctrl+c") == "\u{03}")
        #expect(MCPServer.keyBytes("1") == "1")
        #expect(MCPServer.keyBytes("\u{1b}") == nil) // no raw control characters
        #expect(MCPServer.keyBytes("rm") == nil)
    }
}

@Suite struct MCPRegistrarTests {
    let command = "/Applications/Next Term.app/Contents/Resources/bin/nxtrm"
    let moved = "/Users/me/Apps/Next Term.app/Contents/Resources/bin/nxtrm"

    func home() throws -> String {
        let dir = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-mcp-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func target(_ id: String, home: String) throws -> MCPRegistrar.Target {
        try #require(MCPRegistrar.targets(home: home).first { $0.id == id })
    }

    func write(_ text: String, _ path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func read(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }

    func json(_ path: String) -> [String: Any]? {
        (try? read(path)).flatMap { JSONC.plain($0) }.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    // MARK: Codex

    @Test func codexAppendsATableAndLeavesTheRest() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let codex = try target("codex", home: home)
        let original = "model = \"gpt-5\" # mine\n\n[mcp_servers.node_repl]\ncommand = \"node\"\nargs = [\"repl.js\"]\n"
        try write(original, codex.file)
        #expect(MCPRegistrar.register(codex, command: command, programInstalled: true) == .registered)
        let after = try read(codex.file)
        #expect(after == original + "\n[mcp_servers.next-term]\ncommand = \"\(command)\"\nargs = [\"mcp\"]\n")
        #expect(MCPRegistrar.register(codex, command: command, programInstalled: true) == .alreadyRegistered)
        // The app moved: only the command line changes; Codex's own "Always allow" tables stay.
        try write(after + "\n[mcp_servers.next-term.tools.read_tab]\napproval_mode = \"approve\"\n", codex.file)
        #expect(MCPRegistrar.register(codex, command: moved, programInstalled: true) == .registered)
        let movedText = try read(codex.file)
        #expect(movedText.contains("command = \"\(moved)\"\nargs = [\"mcp\"]\n") && movedText.contains("approval_mode = \"approve\""))
        // Off: our table and its subtables go; the file is back to what it was.
        #expect(MCPRegistrar.unregister(codex) == .removed)
        #expect(try read(codex.file) == original)
    }

    @Test func codexNeverDuplicatesOrTakesAnotherServer() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let codex = try target("codex", home: home)
        let theirs = "[mcp_servers]\nnext-term = { command = \"/usr/bin/other\" }\n"
        try write(theirs, codex.file)
        #expect(MCPRegistrar.register(codex, command: command, programInstalled: true) == .nameTaken)
        #expect(MCPRegistrar.unregister(codex) == .nameTaken)
        #expect(try read(codex.file) == theirs)
        let quoted = "[mcp_servers.\"next-term\"]\ncommand = \"x\"\n"
        try write(quoted, codex.file)
        #expect(MCPRegistrar.register(codex, command: command, programInstalled: true) == .nameTaken)
        #expect(try read(codex.file) == quoted)
    }

    @Test func cursorIsFoundByItsFolder() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let cursor = try target("cursor", home: home)
        #expect(!MCPRegistrar.isInstalled(cursor, found: [:]))
        try FileManager.default.createDirectory(atPath: home + "/.cursor", withIntermediateDirectories: true)
        #expect(MCPRegistrar.isInstalled(cursor, found: [:]))
        #expect(MCPRegistrar.isInstalled(try target("codex", home: home), found: ["codex": "/usr/local/bin/codex"]))
    }

    @Test func notInstalledMeansNothingWritten() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        for target in MCPRegistrar.targets(home: home) {
            #expect(MCPRegistrar.register(target, command: command, programInstalled: false) == .notInstalled)
            #expect(!FileManager.default.fileExists(atPath: target.file))
        }
    }

    // MARK: JSON family

    @Test func everyJSONAgentGetsItsOwnShape() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        for target in MCPRegistrar.targets(home: home) where target.format != .toml {
            #expect(MCPRegistrar.register(target, command: command, programInstalled: true) == .registered, "\(target.id)")
            let file = try #require(json(target.file), "\(target.id)")
            let entry = (file[target.container] as? [String: Any])?["next-term"] as? [String: Any]
            #expect(entry.map { NSDictionary(dictionary: $0).isEqual(to: target.entry(command)) } == true, "\(target.id)")
            #expect(MCPRegistrar.register(target, command: command, programInstalled: true) == .alreadyRegistered, "\(target.id)")
            #expect(MCPRegistrar.unregister(target) == .removed, "\(target.id)")
            #expect(json(target.file)?[target.container] == nil, "\(target.id)")
        }
        // opencode's command is one array; Qwen's file is versioned.
        let opencode = try target("opencode", home: home)
        #expect(MCPRegistrar.isOurs(command: MCPRegistrar.command(of: opencode.entry(command))))
        #expect(try read(try target("qwen", home: home).file).contains("\"$version\": 4"))
    }

    @Test func commentsAndOtherServersSurvive() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let cursor = try target("cursor", home: home)
        let original = """
            {
              // shared with Cursor.app
              "mcpServers": {
                "browsermcp": {"command": "npx", "args": ["@browsermcp/mcp@latest"]}, // the browser
              },
            }

            """
        try write(original, cursor.file)
        #expect(MCPRegistrar.register(cursor, command: command, programInstalled: true) == .registered)
        let after = try read(cursor.file)
        #expect(after.contains("// shared with Cursor.app") && after.contains("// the browser"))
        #expect(after.contains("\"browsermcp\": {\"command\": \"npx\", \"args\": [\"@browsermcp/mcp@latest\"]}, // the browser"))
        let servers = json(cursor.file)?["mcpServers"] as? [String: Any]
        #expect(servers?.keys.sorted() == ["browsermcp", "next-term"])
        #expect(MCPRegistrar.unregister(cursor) == .removed)
        #expect(try read(cursor.file) == original)
    }

    @Test func aFileWithoutTheContainerGetsIt() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let gemini = try target("gemini", home: home)
        let original = "{\n  \"theme\": \"GitHub\",\n  \"ide\": {\"enabled\": true}\n}\n"
        try write(original, gemini.file)
        #expect(MCPRegistrar.register(gemini, command: command, programInstalled: false) == .registered) // the file exists
        let after = try read(gemini.file)
        #expect(after.hasSuffix("\"theme\": \"GitHub\",\n  \"ide\": {\"enabled\": true}\n}\n"))
        #expect(json(gemini.file)?["theme"] as? String == "GitHub")
        #expect(MCPRegistrar.unregister(gemini) == .removed)
        #expect(try read(gemini.file) == original) // the container it added goes too
        // An empty file object.
        try write("{}", gemini.file)
        #expect(MCPRegistrar.register(gemini, command: command, programInstalled: true) == .registered)
        #expect((json(gemini.file)?["mcpServers"] as? [String: Any])?["next-term"] != nil)
    }

    @Test func someoneElsesNextTermIsLeftAlone() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let junie = try target("junie", home: home)
        let theirs = "{\"mcpServers\": {\"next-term\": {\"command\": \"/opt/next-term/server\"}}}"
        try write(theirs, junie.file)
        #expect(MCPRegistrar.register(junie, command: command, programInstalled: true) == .nameTaken)
        #expect(MCPRegistrar.unregister(junie) == .nameTaken)
        #expect(try read(junie.file) == theirs)
    }

    @Test func aMovedAppIsPointedHere() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let amp = try target("amp", home: home)
        try write("{\n  \"amp.mcpServers\": {\n    \"next-term\": {\"args\":[\"mcp\"],\"command\":\"\(moved)\"},\n    \"other\": {\"command\": \"x\"}\n  }\n}\n", amp.file)
        #expect(MCPRegistrar.register(amp, command: command, programInstalled: true) == .registered)
        let servers = json(amp.file)?["amp.mcpServers"] as? [String: Any]
        #expect((servers?["next-term"] as? [String: Any])?["command"] as? String == command)
        #expect((servers?["other"] as? [String: Any])?["command"] as? String == "x")
    }

    @Test func strictJSONWithCommentsIsNotTouched() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let commandCode = try target("commandcode", home: home)
        let commented = "{\n  // mine\n  \"mcpServers\": {}\n}\n"
        try write(commented, commandCode.file)
        #expect(MCPRegistrar.register(commandCode, command: command, programInstalled: true) == .skipped("comments in a file that must be plain JSON"))
        #expect(try read(commandCode.file) == commented)
        try write("{\"mcpServers\": {}}", commandCode.file)
        #expect(MCPRegistrar.register(commandCode, command: command, programInstalled: true) == .registered)
        #expect((try? JSONSerialization.jsonObject(with: Data(try read(commandCode.file).utf8))) != nil) // still plain JSON
    }

    @Test func brokenFilesAreSkipped() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let copilot = try target("copilot", home: home)
        try write("{\"mcpServers\": {", copilot.file)
        #expect(MCPRegistrar.register(copilot, command: command, programInstalled: true) == .skipped("not valid JSON"))
        #expect(try read(copilot.file) == "{\"mcpServers\": {")
    }

    // MARK: Claude Code and ownership

    @Test func claudeEntry() {
        #expect(MCPRegistrar.claudeEntry(configuration: nil) == .absent)
        #expect(MCPRegistrar.claudeEntry(configuration: "{\"mcpServers\": {}}") == .absent)
        #expect(MCPRegistrar.claudeEntry(configuration: "{\"mcpServers\": {\"next-term\": {\"command\": \"\(command)\", \"args\": [\"mcp\"]}}}") == .ours(command: command))
        #expect(MCPRegistrar.claudeEntry(configuration: "{\"mcpServers\": {\"next-term\": {\"command\": \"npx\"}}}") == .taken)
        let json = MCPRegistrar.claudeJSON(command: command)
        #expect(json == "{\"args\":[\"mcp\"],\"command\":\"\(command)\",\"type\":\"stdio\"}")
    }

    @Test func ownership() {
        #expect(MCPRegistrar.isOurs(command: command))
        #expect(MCPRegistrar.isOurs(command: "/Applications/Next Term Beta.app/Contents/Resources/bin/nxtrm"))
        #expect(!MCPRegistrar.isOurs(command: "/usr/local/bin/nxtrm"))
        #expect(!MCPRegistrar.isOurs(command: "/Applications/Other.app/Contents/Resources/bin/server"))
        #expect(!MCPRegistrar.isOurs(command: nil))
    }

    @Test func jsoncParsesWhatAgentsWrite() throws {
        let text = "{\"a\": [1, {\"b\": \"}\"}], /* c */ \"d\": \"\\\"q\", \"e\": true,}"
        let document = try #require(JSONC(text))
        #expect(document.hasComments)
        guard case .object(let root)? = document.root else { Issue.record("not an object"); return }
        #expect(root.members.map(\.key) == ["a", "d", "e"])
        #expect(root.member("d")?.value.object(in: text) as? String == "\"q")
        #expect(JSONC("{\"a\": }") == nil)
        #expect(JSONC("{\"a\": 1} trailing") == nil)
    }
}
