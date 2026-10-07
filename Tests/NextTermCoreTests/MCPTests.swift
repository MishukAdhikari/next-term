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
        // A comment on the { line stays there.
        let commented = "{ // mine\n  \"theme\": \"GitHub\"\n}\n"
        try write(commented, gemini.file)
        #expect(MCPRegistrar.register(gemini, command: command, programInstalled: true) == .registered)
        #expect(try read(gemini.file).hasPrefix("{ // mine\n  \"mcpServers\": {\n"))
        #expect(MCPRegistrar.unregister(gemini) == .removed)
        #expect(try read(gemini.file) == commented)
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

    // MARK: The Claude app

    /// Plain JSON only: the Claude app reads its file strictly.
    func strictJSON(_ path: String) -> [String: Any]? {
        (try? read(path)).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    /// Made-up preferences of the kind the Claude app keeps beside its servers.
    let claudePreferences = """
        {
          "preferences": {
            "sidebarMode": "chat",
            "launchOnLogin": false,
            "pinned": ["notes", "drafts"]
          },
          "windowSizes": [800, 600]
        }

        """

    @Test func claudeAppIsFoundByItsFolderAndGetsCommandAndArgs() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let app = try target("claude-desktop", home: home)
        #expect(app.programs.isEmpty && app.format == .json(strict: true) && app.container == "mcpServers")
        #expect(app.file == home + "/Library/Application Support/Claude/claude_desktop_config.json")
        #expect(NSDictionary(dictionary: app.entry(command)).isEqual(to: ["command": command, "args": ["mcp"]]))
        // No folder: not installed, nothing written.
        #expect(!MCPRegistrar.isInstalled(app, found: [:]))
        #expect(MCPRegistrar.register(app, command: command, programInstalled: false) == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: app.file))
        #expect(MCPRegistrar.unregister(app) == .notInstalled)
        // The folder without the file: the file is created, as plain JSON.
        try FileManager.default.createDirectory(atPath: home + "/Library/Application Support/Claude", withIntermediateDirectories: true)
        #expect(MCPRegistrar.isInstalled(app, found: [:]))
        #expect(MCPRegistrar.register(app, command: command, programInstalled: true) == .registered)
        let servers = try #require(strictJSON(app.file)?["mcpServers"] as? [String: Any])
        let entry = try #require(servers["next-term"] as? [String: Any])
        #expect(entry.keys.sorted() == ["args", "command"])
        #expect(entry["command"] as? String == command && entry["args"] as? [String] == ["mcp"])
    }

    @Test func claudeAppKeepsItsPreferences() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let app = try target("claude-desktop", home: home)
        try write(claudePreferences, app.file)
        #expect(MCPRegistrar.register(app, command: command, programInstalled: true) == .registered)
        let after = try read(app.file)
        // Ours goes first; every byte of the preferences stays as it was.
        let entryText = "{\"args\":[\"mcp\"],\"command\":\"\(command)\"}"
        let added = "{\n  \"mcpServers\": {\n    \"next-term\": \(entryText)\n  },"
        #expect(after == added + String(claudePreferences.dropFirst()))
        let file = try #require(strictJSON(app.file))
        let original = try #require(try JSONSerialization.jsonObject(with: Data(claudePreferences.utf8)) as? [String: Any])
        let preferences = try #require(file["preferences"] as? [String: Any])
        let originalPreferences = try #require(original["preferences"] as? [String: Any])
        #expect(NSDictionary(dictionary: preferences).isEqual(to: originalPreferences))
        #expect(file["windowSizes"] as? [Int] == [800, 600])
        let entry = (file["mcpServers"] as? [String: Any])?["next-term"] as? [String: Any]
        #expect(entry.map { NSDictionary(dictionary: $0).isEqual(to: ["command": command, "args": ["mcp"]]) } == true)
        // Again: nothing to do, nothing written.
        #expect(MCPRegistrar.register(app, command: command, programInstalled: true) == .alreadyRegistered)
        #expect(try read(app.file) == after)
        // Off: ours goes, with the container registering added; the rest is as it was.
        #expect(MCPRegistrar.unregister(app) == .removed)
        #expect(try read(app.file) == claudePreferences)
    }

    @Test func claudeAppKeepsOtherServers() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let app = try target("claude-desktop", home: home)
        let original = """
            {
              "mcpServers": {
                "weather": {
                  "command": "/usr/local/bin/weather-mcp",
                  "args": ["--units", "metric"]
                }
              },
              "preferences": {
                "sidebarMode": "chat"
              }
            }

            """
        try write(original, app.file)
        #expect(MCPRegistrar.register(app, command: command, programInstalled: true) == .registered)
        let servers = try #require(strictJSON(app.file)?["mcpServers"] as? [String: Any])
        #expect(servers.keys.sorted() == ["next-term", "weather"])
        let weather = servers["weather"] as? [String: Any]
        #expect(weather?["command"] as? String == "/usr/local/bin/weather-mcp" && weather?["args"] as? [String] == ["--units", "metric"])
        #expect(MCPRegistrar.unregister(app) == .removed)
        #expect(try read(app.file) == original) // the other server and its container stay
    }

    @Test func claudeAppAdoptsAnotherCopyAndLeavesOthersAlone() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let app = try target("claude-desktop", home: home)
        let movedText = "{\n  \"mcpServers\": {\n    \"next-term\": {\"command\": \"\(moved)\", \"args\": [\"mcp\"]}\n  },\n  \"preferences\": {\"sidebarMode\": \"chat\"}\n}\n"
        try write(movedText, app.file)
        #expect(MCPRegistrar.register(app, command: command, programInstalled: true) == .registered)
        let file = try #require(strictJSON(app.file))
        #expect(((file["mcpServers"] as? [String: Any])?["next-term"] as? [String: Any])?["command"] as? String == command)
        #expect((file["preferences"] as? [String: Any])?["sidebarMode"] as? String == "chat")
        // A `next-term` that is not Next Term's.
        let theirs = "{\"mcpServers\": {\"next-term\": {\"command\": \"/opt/next-term/server\", \"args\": []}}, \"preferences\": {}}"
        try write(theirs, app.file)
        #expect(MCPRegistrar.register(app, command: command, programInstalled: true) == .nameTaken)
        #expect(MCPRegistrar.unregister(app) == .nameTaken)
        #expect(try read(app.file) == theirs)
    }

    @Test func claudeAppRefusesFilesItCouldNotRead() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let app = try target("claude-desktop", home: home)
        let broken = "{\"preferences\": {\"sidebarMode\": \"chat\""
        try write(broken, app.file)
        #expect(MCPRegistrar.register(app, command: command, programInstalled: true) == .skipped("not valid JSON"))
        #expect(MCPRegistrar.unregister(app) == .skipped("not valid JSON"))
        #expect(try read(app.file) == broken)
        // JSON with comments or a trailing comma parses for other agents, not for the Claude app.
        let commented = "{\n  // mine\n  \"preferences\": {}\n}\n"
        try write(commented, app.file)
        #expect(MCPRegistrar.register(app, command: command, programInstalled: true) == .skipped("comments in a file that must be plain JSON"))
        #expect(try read(app.file) == commented)
        let trailing = "{\n  \"preferences\": {},\n}\n"
        try write(trailing, app.file)
        #expect(MCPRegistrar.register(app, command: command, programInstalled: true) == .skipped("trailing commas in a file that must be plain JSON"))
        #expect(try read(app.file) == trailing)
        // Taking ours out of such a file is refused too.
        let oursAndTrailing = "{\n  \"mcpServers\": {\n    \"next-term\": {\"args\":[\"mcp\"],\"command\":\"\(command)\"}\n  },\n  \"preferences\": {\"a\": 1,}\n}\n"
        try write(oursAndTrailing, app.file)
        #expect(MCPRegistrar.unregister(app) == .skipped("trailing commas in a file that must be plain JSON"))
        #expect(try read(app.file) == oursAndTrailing)
    }

    @Test func turningOffLeavesTheFileAsItWas() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let app = try target("claude-desktop", home: home)
        let originals = [
            // An empty container that was there before stays, first or not.
            "{\n  \"mcpServers\": {},\n  \"preferences\": {\n    \"sidebarMode\": \"chat\"\n  }\n}\n",
            "{\n  \"preferences\": {},\n  \"mcpServers\": {}\n}",
            // A file on one line.
            "{\"preferences\":{\"sidebarMode\":\"chat\"}}",
            "{ \"preferences\": {\"sidebarMode\": \"chat\"} }",
        ]
        for original in originals {
            try write(original, app.file)
            #expect(MCPRegistrar.register(app, command: command, programInstalled: true) == .registered, "\(original)")
            #expect((strictJSON(app.file)?["mcpServers"] as? [String: Any])?["next-term"] != nil, "\(original)")
            #expect(MCPRegistrar.unregister(app) == .removed, "\(original)")
            #expect(try read(app.file) == original)
        }
        // A byte order mark stays.
        let marked = Data([0xEF, 0xBB, 0xBF]) + Data(claudePreferences.utf8)
        try marked.write(to: URL(fileURLWithPath: app.file))
        #expect(MCPRegistrar.register(app, command: command, programInstalled: true) == .registered)
        #expect(FileManager.default.contents(atPath: app.file)?.starts(with: [0xEF, 0xBB, 0xBF]) == true)
        #expect(MCPRegistrar.unregister(app) == .removed)
        #expect(FileManager.default.contents(atPath: app.file) == marked)
    }

    @Test func textIsReadByUnicodeScalar() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let app = try target("claude-desktop", home: home)
        // A combining mark just after a quote, or a prepended one just before it, joins the quote in one Character.
        for value in ["\u{301}accent first", "number sign last\u{600}"] {
            let original = "{\n  \"preferences\": {\n    \"note\": \"\(value)\"\n  }\n}\n"
            try write(original, app.file)
            #expect(MCPRegistrar.register(app, command: command, programInstalled: true) == .registered, "\(value)")
            #expect((strictJSON(app.file)?["preferences"] as? [String: Any])?["note"] as? String == value)
            #expect(MCPRegistrar.unregister(app) == .removed, "\(value)")
            #expect(try read(app.file) == original)
        }
        #expect(JSONC.plain("{\"a\": \"\u{301}\",}") == "{\"a\": \"\u{301}\"}")
    }

    @Test func repeatedKeysAreLeftAlone() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let app = try target("claude-desktop", home: home)
        // JSON parsers take the last of repeated keys.
        let files = [
            "{\"mcpServers\": {}, \"mcpServers\": {\"weather\": {\"command\": \"w\"}}}",
            "{\"mcpServers\": {}, \"mcpServers\": null}",
            "{\"mcpServers\": {\"next-term\": {\"command\": \"\(moved)\", \"args\": [\"mcp\"]}, \"next-term\": {\"command\": \"/opt/theirs\"}}}",
        ]
        for text in files {
            try write(text, app.file)
            #expect(MCPRegistrar.register(app, command: command, programInstalled: true) == .skipped("repeated keys"), "\(text)")
            #expect(MCPRegistrar.unregister(app) == .skipped("repeated keys"), "\(text)")
            #expect(try read(app.file) == text)
        }
    }

    @Test func anotherCopysEntryKeepsWhatTheUserAdded() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let app = try target("claude-desktop", home: home)
        let original = """
            {
              "mcpServers": {
                "next-term": {
                  "command": "\(moved)",
                  "args": ["mcp"],
                  "env": {"NXTRM_LOG": "1"}
                }
              }
            }

            """
        try write(original, app.file)
        #expect(MCPRegistrar.register(app, command: command, programInstalled: true) == .registered)
        #expect(try read(app.file) == original.replacingOccurrences(of: moved, with: command))
        // opencode's command is an array: its first word changes.
        let opencode = try target("opencode", home: home)
        let theirs = "{\n  \"mcp\": {\n    \"next-term\": {\"type\": \"local\", \"command\": [\"\(moved)\", \"mcp\"], \"enabled\": false}\n  }\n}\n"
        try write(theirs, opencode.file)
        #expect(MCPRegistrar.register(opencode, command: command, programInstalled: true) == .registered)
        #expect(try read(opencode.file) == theirs.replacingOccurrences(of: moved, with: command))
    }

    @Test func aLinkToAMissingFileStaysALink() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        for id in ["claude-desktop", "codex"] {
            let target = try target(id, home: home)
            let destination = home + "/dotfiles/\(id)"
            try FileManager.default.createDirectory(atPath: (target.file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: target.file, withDestinationPath: destination)
            #expect(MCPRegistrar.register(target, command: command, programInstalled: true) == .skipped("a link to a file that is not there"), "\(id)")
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.file) == destination)
            #expect(!FileManager.default.fileExists(atPath: destination))
        }
    }

    @Test func aReadOnlyFileIsLeftAlone() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let app = try target("claude-desktop", home: home)
        try write(claudePreferences, app.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: app.file)
        #expect(MCPRegistrar.register(app, command: command, programInstalled: true) == .skipped("read-only"))
        #expect(try read(app.file) == claudePreferences)
        let codex = try target("codex", home: home)
        try write("model = \"gpt-5\"\n", codex.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: codex.file)
        #expect(MCPRegistrar.register(codex, command: command, programInstalled: true) == .skipped("read-only"))
        #expect(try read(codex.file) == "model = \"gpt-5\"\n")
        // Nothing to write: ours is there.
        let ours = "{\"mcpServers\": {\"next-term\": {\"args\": [\"mcp\"], \"command\": \"\(command)\"}}}"
        try FileManager.default.removeItem(atPath: app.file)
        try write(ours, app.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: app.file)
        #expect(MCPRegistrar.register(app, command: command, programInstalled: true) == .alreadyRegistered)
    }

    @Test func aFileSavedDuringAnEditIsLeftAlone() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let app = try target("claude-desktop", home: home)
        try write(claudePreferences, app.file)
        let planned = MCPRegistrar.plan(app, command: command, programInstalled: true)
        #expect(planned.status == .registered && planned.text != nil)
        // The agent saves its settings between the read and the write: the edit would put the old ones back.
        let saved = claudePreferences.replacingOccurrences(of: "\"chat\"", with: "\"code\"")
        try write(saved, app.file)
        #expect(MCPRegistrar.write(planned, to: app.file) == .skipped("changed while being edited"))
        #expect(try read(app.file) == saved)
    }

    @Test func codexIsFoundByTheChatGPTAppOrItsFolder() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        // The ChatGPT app reads Codex's file; it runs its own copy of codex, not one on the PATH.
        let codex = try target("codex", home: home)
        #expect(codex.apps == ["com.openai.codex"])
        #expect(!MCPRegistrar.isInstalled(codex, found: [:]))
        #expect(MCPRegistrar.isInstalled(codex, found: ["com.openai.codex": "/Applications/ChatGPT.app"]))
        try FileManager.default.createDirectory(atPath: home + "/.codex", withIntermediateDirectories: true)
        #expect(MCPRegistrar.isInstalled(codex, found: [:]))
        #expect(MCPRegistrar.register(codex, command: command, programInstalled: MCPRegistrar.isInstalled(codex, found: [:])) == .registered)
        #expect(try read(codex.file) == "[mcp_servers.next-term]\ncommand = \"\(command)\"\nargs = [\"mcp\"]\n")
    }

    @Test func claudeAppWaitsUntilItQuits() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let app = try target("claude-desktop", home: home)
        try write(claudePreferences, app.file)
        // Open: nothing written; adding Next Term waits.
        let adding = MCPRegistrar.whileClaudeAppIsOpen(app, command: command, programInstalled: true)
        #expect(adding.status == .skipped("the Claude app is open") && adding.waiting == true)
        #expect(MCPRegistrar.whileClaudeAppIsOpen(app, command: nil, programInstalled: true).waiting == nil) // nothing to take out
        #expect(try read(app.file) == claudePreferences)
        // Closed: written. Open again: nothing waits while the setting stays on; taking it out does.
        #expect(MCPRegistrar.register(app, command: command, programInstalled: true) == .registered)
        let added = try read(app.file)
        let on = MCPRegistrar.whileClaudeAppIsOpen(app, command: command, programInstalled: true)
        #expect(on.status == .alreadyRegistered && on.waiting == nil)
        let removing = MCPRegistrar.whileClaudeAppIsOpen(app, command: nil, programInstalled: true)
        #expect(removing.status == .skipped("the Claude app is open") && removing.waiting == false)
        #expect(try read(app.file) == added)
        // Someone else's next-term: nothing waits.
        let theirs = "{\"mcpServers\": {\"next-term\": {\"command\": \"/opt/next-term/server\"}}}"
        try write(theirs, app.file)
        #expect(MCPRegistrar.whileClaudeAppIsOpen(app, command: command, programInstalled: true) == (.nameTaken, nil))
    }

    @Test func claudeAppNoteFollowsTheSetting() {
        #expect(MCPRegistrar.claudeAppNote(waiting: true, on: true) == " Quit and reopen the Claude app to add it there too.")
        #expect(MCPRegistrar.claudeAppNote(waiting: false, on: false) == " Quit the Claude app to remove it there too.")
        #expect(MCPRegistrar.claudeAppNote(waiting: nil, on: true).isEmpty)
        // Just after the setting changed, the last pass was for the other one: no note until the new pass is done.
        #expect(MCPRegistrar.claudeAppNote(waiting: true, on: false).isEmpty)
        #expect(MCPRegistrar.claudeAppNote(waiting: false, on: true).isEmpty)
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
