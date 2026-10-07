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
        let keys: [String] = entry.keys.sorted()
        let expected: [String] = ["args", "command"]
        #expect(keys == expected)
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
        let names: [String] = servers.keys.sorted()
        let expected: [String] = ["next-term", "weather"]
        #expect(names == expected)
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

    @Test func aSaveWhileTheEditIsWrittenIsLeftAlone() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let codex = try target("codex", home: home)
        let original = "model = \"gpt-5\"\n"
        try write(original, codex.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: codex.file)
        let planned = MCPRegistrar.plan(codex, command: command, programInstalled: true)
        #expect(planned.status == .registered && planned.text != nil)
        // Codex saves its file (a temporary file renamed over it) while the edit is being written: the edit would undo it.
        let saved = original + "\n[projects.\"/Users/me/code\"]\ntrust_level = \"trusted\"\n"
        var temporary: (mode: mode_t, text: String?)?
        let status = MCPRegistrar.write(planned, to: codex.file) { path in
            var info = stat()
            if lstat(path, &info) == 0 { temporary = (info.st_mode & 0o7777, try? String(contentsOfFile: path, encoding: .utf8)) }
            try? self.write(saved, codex.file)
        }
        #expect(status == .skipped("changed while being edited"))
        #expect(try read(codex.file) == saved)
        // The edit was all there, in a file only its owner can read, and nothing is left beside the file.
        #expect(temporary?.mode == 0o600 && temporary?.text == planned.text)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home + "/.codex") == ["config.toml"])
    }

    @Test func aVolumeWithoutExclusiveRenamesStillGetsANewFile() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let cursor = try target("cursor", home: home)
        let folder = home + "/.cursor"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let data = Data("{\n  \"mcpServers\": {}\n}\n".utf8)
        func put(_ exclusiveRename: (String, String) -> Int32) -> MCPRegistrar.Replacement {
            MCPRegistrar.replace(cursor.file, with: data, original: nil, beforeRename: { _ in }, exclusiveRename: exclusiveRename)
        }
        func mode() -> Int? {
            ((try? FileManager.default.attributesOfItem(atPath: cursor.file))?[.posixPermissions] as? NSNumber)?.intValue
        }
        // exFAT cannot rename only when there is no file there (ENOTSUP); a volume may also refuse the flag (EINVAL).
        for code in [ENOTSUP, EINVAL] {
            let result = put { _, _ in
                errno = code
                return -1
            }
            #expect(result == .done)
            #expect(FileManager.default.contents(atPath: cursor.file) == data && mode() == 0o600)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder) == ["mcp.json"])
            try FileManager.default.removeItem(atPath: cursor.file)
        }
        // A file that turns up meanwhile stays as it is.
        let appeared = put { _, target in
            try? "{}\n".write(toFile: target, atomically: false, encoding: .utf8)
            errno = ENOTSUP
            return -1
        }
        #expect(appeared == .changed)
        #expect(try read(cursor.file) == "{}\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder) == ["mcp.json"])
        try FileManager.default.removeItem(atPath: cursor.file)
        // Any other error is a failed write, with nothing left behind.
        let failed = put { _, _ in
            errno = EIO
            return -1
        }
        #expect(failed == .failed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder).isEmpty)
    }

    @Test func theTemporaryFileIsPrivateFromTheStart() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let codex = try target("codex", home: home)
        // Codex keeps its file 0600: it can hold its servers' tokens.
        let original = "[mcp_servers.weather]\ncommand = \"w\"\nenv = { TOKEN = \"made-up\" }\n"
        try write(original, codex.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: codex.file)
        let watcher = FolderWatcher(home + "/.codex", ignoring: "config.toml")
        for _ in 0..<100 {
            #expect(MCPRegistrar.register(codex, command: command, programInstalled: true) == .registered)
            #expect(MCPRegistrar.unregister(codex) == .removed)
        }
        let seen = watcher.stop()
        #expect(seen.allSatisfy { $0 == 0o600 }, "\(seen.map { String($0, radix: 8) })")
        #expect(try read(codex.file) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home + "/.codex") == ["config.toml"])
    }

    @Test func theEditKeepsTheFilesPermissions() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        func mode(_ path: String) -> Int? {
            ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue
        }
        let gemini = try target("gemini", home: home)
        try write("{}\n", gemini.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: gemini.file)
        #expect(MCPRegistrar.register(gemini, command: command, programInstalled: true) == .registered)
        #expect(mode(gemini.file) == 0o640)
        // A new file is its owner's alone.
        let cursor = try target("cursor", home: home)
        #expect(MCPRegistrar.register(cursor, command: command, programInstalled: true) == .registered)
        #expect(mode(cursor.file) == 0o600)
        // Through a link: the link stays, the file it points at is edited and keeps its permissions.
        let codex = try target("codex", home: home)
        let dotfile = home + "/dotfiles/config.toml"
        try write("model = \"gpt-5\"\n", dotfile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dotfile)
        try FileManager.default.createDirectory(atPath: home + "/.codex", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: codex.file, withDestinationPath: dotfile)
        #expect(MCPRegistrar.register(codex, command: command, programInstalled: true) == .registered)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: codex.file) == dotfile)
        #expect(mode(dotfile) == 0o600)
        #expect(try read(dotfile).contains("[mcp_servers.next-term]"))
        #expect(MCPRegistrar.unregister(codex) == .removed)
        #expect(try read(dotfile) == "model = \"gpt-5\"\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: home + "/dotfiles") == ["config.toml"])
    }

    @Test func deeplyNestedFilesAreRefusedNotACrash() throws {
        let gemini = try target("gemini", home: "/nonexistent")
        let codex = try target("codex", home: "/nonexistent")
        let claudeApp = try target("claude-desktop", home: "/nonexistent")
        let commandCode = try target("commandcode", home: "/nonexistent")
        func nested(_ depth: Int) -> String { String(repeating: "[", count: depth) + String(repeating: "]", count: depth) }
        func objects(_ depth: Int) -> String { String(repeating: "{\"a\": ", count: depth) + "1" + String(repeating: "}", count: depth) }
        let ours = "\n[mcp_servers.next-term]\ncommand = \"\(command)\"\n"
        let inline: String = "a = " + String(repeating: "{b = ", count: 5000) + "1" + String(repeating: "}", count: 5000)
        let json = MCPRegistrar.Status.skipped("not valid JSON")
        let toml = MCPRegistrar.Status.skipped("not valid TOML")
        // A file, registering (a command) or not, and what comes of it.
        var cases: [(MCPRegistrar.Target, String, String?, MCPRegistrar.Status)] = []
        cases.append((gemini, "{\"a\": \(nested(5000))}", command, json))
        cases.append((gemini, "{\"a\": \(nested(5000))}", nil, json))
        cases.append((gemini, objects(5000), command, json))
        cases.append((codex, "a = \(nested(5000))\n", command, toml))
        cases.append((codex, "a = \(nested(5000))\n" + ours, nil, toml))
        cases.append((codex, inline, command, toml))
        // As deep as is read, and one level more. What passes is read again by Foundation's parser, which follows objects
        // by recursion: a strict agent's whole file, and the next-term entry, ours or not.
        let limit = JSONC.maxDepth
        cases.append((gemini, "{\"a\": \(nested(limit - 1))}", command, .registered))
        cases.append((gemini, "{\"a\": \(nested(limit))}", command, json))
        cases.append((gemini, objects(limit), command, .registered))
        cases.append((gemini, objects(limit + 1), command, json))
        cases.append((codex, "a = \(nested(limit))\n", command, .registered))
        cases.append((codex, "a = \(nested(limit + 1))\n", command, toml))
        func beside(_ depth: Int) -> String { "{\"mcpServers\": {}, \"p\": \(objects(depth - 1))}" }
        for strict in [claudeApp, commandCode] {
            cases.append((strict, beside(limit), command, .registered))
            cases.append((strict, beside(limit + 1), command, json))
        }
        func inEntry(_ depth: Int, command: String) -> String {
            "{\"mcpServers\": {\"next-term\": {\"command\": \"\(command)\", \"args\": [\"mcp\"], \"e\": \(objects(depth - 3))}}}"
        }
        for registering in [command, nil] {
            cases.append((gemini, inEntry(limit, command: "npx"), registering, .nameTaken))
            cases.append((gemini, inEntry(limit + 1, command: "npx"), registering, json))
        }
        cases.append((claudeApp, inEntry(limit, command: moved), command, .registered))
        cases.append((claudeApp, inEntry(limit, command: moved), nil, .removed))
        cases.append((claudeApp, inEntry(limit + 1, command: moved), nil, json))
        // On a queue's thread, as passes run, whose stack is smaller than the main thread's.
        let statuses: [MCPRegistrar.Status] = onAQueue {
            cases.map { MCPRegistrar.plan($0.0, text: $0.1, command: $0.2).status }
        }
        let expected: [MCPRegistrar.Status] = cases.map(\.3)
        #expect(statuses == expected)
        // Claude Code's file is read by Foundation alone: one too deep for it is one it cannot read.
        let claudeCode = "{\"mcpServers\": {\"next-term\": {\"command\": \"\(command)\"}}, \"projects\": "
        let entries: [MCPRegistrar.ClaudeEntry] = onAQueue {
            [limit, limit + 1, 5000].map { (depth: Int) -> MCPRegistrar.ClaudeEntry in
                let text: String = claudeCode + objects(depth - 1) + "}"
                return MCPRegistrar.claudeEntry(configuration: text)
            }
        }
        #expect(entries == [.ours(command: command), .absent, .absent])
    }

    /// `body`'s result, run on a dispatch queue's thread.
    func onAQueue<T>(_ body: @escaping () -> T) -> T {
        var result: T?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue(label: "nextterm.tests.registration").async {
            result = body()
            done.signal()
        }
        done.wait()
        return result!
    }

    @Test func codexIsFoundByTheChatGPTAppOrItsFolder() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        // The ChatGPT app reads Codex's file; it runs its own copy of codex, not one on the PATH.
        let codex = try target("codex", home: home)
        let apps: [String] = codex.apps
        let expected: [String] = ["com.openai.codex"]
        #expect(apps == expected)
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
        // A file left alone says why; waiting for the app is not a reason.
        let readOnly: [String: MCPRegistrar.Status] = ["claude-desktop": .skipped("read-only"), "codex": .skipped("write")]
        #expect(MCPRegistrar.claudeAppNote(waiting: nil, on: true, statuses: readOnly) == " The Claude app's file was left as it is (read-only).")
        let open: [String: MCPRegistrar.Status] = ["claude-desktop": .skipped("the Claude app is open")]
        #expect(MCPRegistrar.claudeAppNote(waiting: nil, on: true, statuses: open).isEmpty)
        #expect(MCPRegistrar.claudeAppNote(waiting: nil, on: false, statuses: ["claude-desktop": .removed]).isEmpty)
    }

    @Test func claudeAppInAThirdPartySetUpHasItsOwnFile() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let app = try target("claude-desktop-3p", home: home)
        #expect(app.file == home + "/Library/Application Support/Claude-3p/claude_desktop_config.json")
        #expect(app.readOnceBy == MCPRegistrar.claudeAppBundle && app.format == .json(strict: true))
        #expect(!MCPRegistrar.isInstalled(app, found: [:]))
        // The usual folder does not count for it.
        try FileManager.default.createDirectory(atPath: home + "/Library/Application Support/Claude", withIntermediateDirectories: true)
        #expect(!MCPRegistrar.isInstalled(app, found: [:]))
        try FileManager.default.createDirectory(atPath: home + "/Library/Application Support/Claude-3p", withIntermediateDirectories: true)
        #expect(MCPRegistrar.isInstalled(app, found: [:]))
    }

    // MARK: A pass, as the app makes it

    @Test func aPassWaitsForTheClaudeAppToQuit() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let targets = MCPRegistrar.targets(home: home).filter { ["claude-desktop", "gemini"].contains($0.id) }
        let claudeOnly = targets.filter { $0.readOnceBy != nil }
        let app = try target("claude-desktop", home: home)
        let gemini = try target("gemini", home: home)
        try write(claudePreferences, app.file)
        let found = ["gemini": "/usr/local/bin/gemini"]
        var asked: [String] = []
        // On while Claude is open: Gemini is registered, the Claude app waits.
        var pass = MCPRegistrar.pass(targets, command: command, found: found) { asked.append($0); return true }
        let bundles: [String] = [MCPRegistrar.claudeAppBundle]
        #expect(asked == bundles)
        #expect(pass.statuses["gemini"] == .registered && pass.statuses["claude-desktop"] == .skipped("the Claude app is open"))
        #expect(pass.waiting == true)
        #expect(try read(app.file) == claudePreferences)
        var statuses = MCPRegistrar.merged([:], pass.statuses, whole: true)
        // Claude quits: only its file, and the others' statuses stay.
        pass = MCPRegistrar.pass(claudeOnly, command: command, found: [:]) { _ in false }
        let quit: [String: MCPRegistrar.Status] = ["claude-desktop": .registered]
        #expect(pass.statuses == quit && pass.waiting == nil)
        statuses = MCPRegistrar.merged(statuses, pass.statuses, whole: false)
        let both: [String: MCPRegistrar.Status] = ["gemini": .registered, "claude-desktop": .registered]
        #expect(statuses == both)
        // Off while Claude is open again: Gemini's goes, the Claude app's waits to be taken out.
        pass = MCPRegistrar.pass(targets, command: nil, found: found) { _ in true }
        #expect(pass.waiting == false && pass.statuses["gemini"] == .removed)
        #expect(json(app.file).map { ($0["mcpServers"] as? [String: Any])?["next-term"] != nil } == true)
        // Next Term quits before Claude does; at its next launch, with the setting off, only Claude's file is taken care of.
        let geminiText = try read(gemini.file)
        try write(geminiText.replacingOccurrences(of: "{", with: "{\"mcpServers\": {\"next-term\": {\"command\": \"\(command)\"}}, ", options: [], range: geminiText.range(of: "{")), gemini.file)
        let geminiBefore = try read(gemini.file)
        pass = MCPRegistrar.pass(claudeOnly, command: nil, found: [:]) { _ in false }
        let removed: [String: MCPRegistrar.Status] = ["claude-desktop": .removed]
        #expect(pass.statuses == removed && pass.waiting == nil)
        #expect(try read(app.file) == claudePreferences)
        #expect(try read(gemini.file) == geminiBefore)
        // Both of the Claude app's folders: one wait for both.
        try FileManager.default.createDirectory(atPath: home + "/Library/Application Support/Claude-3p", withIntermediateDirectories: true)
        let folders = MCPRegistrar.targets(home: home).filter { $0.readOnceBy != nil }
        pass = MCPRegistrar.pass(folders, command: command, found: [:]) { _ in true }
        #expect(pass.waiting == true && pass.statuses.count == 2)
    }

    @Test func aClaudeAppInstalledAfterTheLastPassIsWaitedFor() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let claudeOnly = MCPRegistrar.targets(home: home).filter { $0.readOnceBy != nil }
        let app = try target("claude-desktop", home: home)
        // Next Term's last pass: no Claude app yet.
        var pass = MCPRegistrar.pass(claudeOnly, command: command, found: [:]) { _ in false }
        #expect(pass.waiting == nil && pass.statuses["claude-desktop"] == .notInstalled)
        // Installed and opened: its first start makes its folder. The pass its opening starts (or Settings opening) writes
        // nothing and has the line say what waits; its file may not be there yet.
        try FileManager.default.createDirectory(atPath: (app.file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        pass = MCPRegistrar.pass(claudeOnly, command: command, found: [:]) { _ in true }
        #expect(pass.waiting == true && !FileManager.default.fileExists(atPath: app.file))
        let note = MCPRegistrar.claudeAppNote(waiting: pass.waiting, on: true, statuses: pass.statuses)
        #expect(note == " Quit and reopen the Claude app to add it there too.")
        try write("{}", app.file)
        pass = MCPRegistrar.pass(claudeOnly, command: command, found: [:]) { _ in true }
        #expect(pass.waiting == true)
        #expect(try read(app.file) == "{}")
        // It quits: the entry is added.
        pass = MCPRegistrar.pass(claudeOnly, command: command, found: [:]) { _ in false }
        #expect(pass.waiting == nil && pass.statuses["claude-desktop"] == .registered)
    }

    @Test func summaryNamesTheApps() {
        let home = "/nonexistent-\(UUID().uuidString)"
        let statuses: [String: MCPRegistrar.Status] = ["claude": .registered, "claude-desktop": .registered,
                                                       "claude-desktop-3p": .alreadyRegistered, "codex": .registered]
        let withApp = MCPRegistrar.summary(statuses, apps: ["com.openai.codex"], home: home)
        #expect(withApp.hasPrefix("Registered in ") && withApp.contains("the ChatGPT app") && withApp.contains("Codex"))
        let parts: Int = withApp.components(separatedBy: "the Claude app").count
        #expect(parts == 2) // once for both of its files
        #expect(withApp.contains("Claude Code"))
        #expect(!MCPRegistrar.summary(statuses, apps: [], home: home).contains("ChatGPT"))
        let taken = MCPRegistrar.summary(["claude-desktop": .nameTaken], apps: [], home: home)
        #expect(taken == "Not registered in any agent yet. The Claude app already has another server named “next-term”, left as it is.")
    }

    // MARK: Round trips: turning off gives the file back as it was

    /// Registers and unregisters `original` for `target`, expecting the file back byte for byte; the text while
    /// registered, for more checks.
    @discardableResult
    func roundTrip(_ original: String, _ target: MCPRegistrar.Target, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        try write(original, target.file)
        let added = MCPRegistrar.register(target, command: command, programInstalled: true)
        #expect(added == .registered, "\(original)", sourceLocation: sourceLocation)
        let registered = try read(target.file)
        let removed = MCPRegistrar.unregister(target)
        #expect(removed == .removed, "\(original)", sourceLocation: sourceLocation)
        let after = try read(target.file)
        #expect(after == original, sourceLocation: sourceLocation)
        return registered
    }

    @Test func commentsBesideTheServersStay() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let gemini = try target("gemini", home: home)
        let weather = "{\"command\": \"w\", \"args\": []}"
        // A comment line above a server, and comments after the servers' {.
        let above = "{\n  \"mcpServers\": {\n    // my weather server, keep\n    \"weather\": \(weather)\n  }\n}\n"
        try roundTrip(above, gemini)
        let daily = "{\n  \"mcpServers\": { // servers I use daily\n    \"weather\": \(weather)\n  }\n}\n"
        let registered = try roundTrip(daily, gemini)
        #expect(registered.contains("\"mcpServers\": { // servers I use daily\n    \"next-term\": "))
        let cursor = try target("cursor", home: home)
        try roundTrip("{\n  \"mcpServers\": { /* keep */\n    \"weather\": \(weather)\n  }\n}\n", cursor)
        // A comment above the first member stays with it.
        let theme = "{\n  // the theme I like\n  \"theme\": \"x\"\n}\n"
        let themed = try roundTrip(theme, gemini)
        #expect(themed.contains("// the theme I like\n  \"theme\": \"x\""))
        // A comment in an empty container, and on the line of the server before ours.
        try roundTrip("{\n  \"mcpServers\": {\n    // add yours here\n  }\n}\n", gemini)
        try roundTrip("{\n  \"mcpServers\": { // none yet\n  }\n}\n", gemini)
        try roundTrip("{\n  \"mcpServers\": { /* none yet */ }\n}\n", gemini)
        try roundTrip("{\n  // nothing yet\n}\n", gemini)
    }

    @Test func compactAndCRLFFilesStayAsTheyWere() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let app = try target("claude-desktop", home: home)
        // Servers on the { line: ours goes on that line too.
        let compact = "{\"mcpServers\":{\"weather\":{\"command\":\"w\",\"args\":[]}},\"preferences\":{}}"
        #expect(try !roundTrip(compact, app).contains("\n"))
        try roundTrip("{\n  \"mcpServers\": {\"weather\": {\"command\": \"w\"}},\n  \"preferences\": {}\n}\n", app)
        try roundTrip("{\n  \"mcpServers\": {\"weather\": {\"command\": \"w\"},\n    \"maps\": {\"command\": \"m\"}},\n  \"preferences\": {}\n}\n", app)
        // Windows line endings: every line break added is one too.
        let crlf = [
            "{\r\n  \"mcpServers\": {\r\n    \"weather\": {\"command\": \"w\"}\r\n  },\r\n  \"preferences\": {}\r\n}\r\n",
            "{\r\n  \"preferences\": {}\r\n}\r\n",
            "{\r\n  \"mcpServers\": {\r\n  },\r\n  \"preferences\": {}\r\n}\r\n",
        ]
        for original in crlf {
            let registered = try roundTrip(original, app)
            let bare: String = registered.replacingOccurrences(of: "\r\n", with: "")
            #expect(!bare.contains("\n"), "\(original)")
        }
    }

    @Test func emptyObjectsOverLinesStay() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let app = try target("claude-desktop", home: home)
        let gemini = try target("gemini", home: home)
        let originals = [
            "{\n  \"mcpServers\": {\n  },\n  \"preferences\": {\"a\": 1}\n}\n",
            "{\n  \"mcpServers\": {\n  }\n}\n",
            "{\n  \"mcpServers\": {\n\n  }\n}\n",
            "{\"mcpServers\": { }}",
            "{ }",
            "{\n}\n",
            "{}",
        ]
        for original in originals {
            try roundTrip(original, app)
            try roundTrip(original, gemini)
        }
    }

    @Test func repeatedKeysInsideTheEntryAreLeftAlone() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let app = try target("claude-desktop", home: home)
        // Foundation takes the first command, the Claude app the last: whose entry it is cannot be told.
        let text = "{\"mcpServers\": {\"next-term\": {\"command\": \"\(moved)\", \"command\": \"/usr/local/bin/theirs\", \"args\": [\"mcp\"]}}}"
        try write(text, app.file)
        #expect(MCPRegistrar.register(app, command: command, programInstalled: true) == .skipped("repeated keys"))
        #expect(MCPRegistrar.unregister(app) == .skipped("repeated keys"))
        #expect(try read(app.file) == text)
    }

    @Test func aReadOnlyFileIsNotWaitedFor() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let app = try target("claude-desktop", home: home)
        try write(claudePreferences, app.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: app.file)
        let open = MCPRegistrar.whileClaudeAppIsOpen(app, command: command, programInstalled: true)
        #expect(open.status == .skipped("read-only") && open.waiting == nil)
    }

    /// Made-up files in many shapes: one line or a line per member, LF or CRLF, servers or none, comments where
    /// the agent takes them.
    func shapes(count: Int, comments: Bool) -> [String] {
        var random = SplitMix(seed: comments ? 7 : 3)
        return (0..<count).map { _ in shape(&random, comments: comments) }
    }

    func shape(_ random: inout SplitMix, comments: Bool) -> String {
        let newline = Bool.random(using: &random) ? "\r\n" : "\n"
        let lines = Int.random(in: 0..<3, using: &random) // 0: compact, 1: one line with spaces, 2: a line per member
        func space(_ depth: Int) -> String {
            lines == 2 ? newline + String(repeating: "  ", count: depth) : lines == 1 ? " " : ""
        }
        func object(_ members: [String], depth: Int) -> String {
            if members.isEmpty {
                let empties = ["{}", "{ }", "{" + newline + String(repeating: "  ", count: depth) + "}"]
                return empties[Int.random(in: 0..<empties.count, using: &random)]
            }
            let comment = comments && lines == 2 && Bool.random(using: &random) ? " // mine" : ""
            return "{" + comment + space(depth + 1) + members.joined(separator: "," + space(depth + 1)) + space(depth) + "}"
        }
        let colon = lines > 0 ? ": " : ":"
        var servers: [String] = []
        for name in ["weather", "maps"] where Bool.random(using: &random) {
            servers.append("\"\(name)\"" + colon + "{\"command\": \"/usr/local/bin/\(name)\", \"args\": []}")
        }
        let preferences = "\"preferences\"" + colon + "{\"sidebarMode\": \"chat\", \"pinned\": [\"a\", \"b\"]}"
        let candidates = [preferences, "\"note\"" + colon + "\"caf\u{E9} \u{301}x\"", "\"windowSizes\"" + colon + "[800, 600]"]
        var members = candidates.filter { _ in Bool.random(using: &random) }
        if Bool.random(using: &random) {
            let container = "\"mcpServers\"" + colon + object(servers, depth: 1)
            members.insert(container, at: Int.random(in: 0...members.count, using: &random))
        }
        if comments, lines == 2, !members.isEmpty, Bool.random(using: &random) {
            members[0] = "// first" + newline + "  " + members[0]
        }
        return object(members, depth: 0) + (Bool.random(using: &random) ? newline : "")
    }

    @Test func manyShapesComeBackAsTheyWere() throws {
        // The edits of the text alone (files are the other tests' business), each in a pool of its own: the memory
        // tests that run beside this one count every byte the process holds.
        for target in MCPRegistrar.targets(home: "/nonexistent") where ["claude-desktop", "gemini"].contains(target.id) {
            for original in shapes(count: 100, comments: target.format == .json(strict: false)) { try autoreleasepool {
                let added = MCPRegistrar.plan(target, text: original, command: command)
                #expect(added.status == .registered, "\(original)")
                let registered = try #require(added.text, "\(original)")
                // While it is there, the rest of the file means what it meant.
                var file = try #require(JSONC.plain(registered).flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
                let before = try #require(JSONC.plain(original).flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
                var servers = try #require(file["mcpServers"] as? [String: Any], "\(original)")
                #expect(servers.removeValue(forKey: "next-term") != nil)
                file["mcpServers"] = servers.isEmpty && before["mcpServers"] == nil ? nil : servers
                #expect(NSDictionary(dictionary: file).isEqual(to: before), "\(original)")
                let removed = MCPRegistrar.plan(target, text: registered, command: nil)
                #expect(removed.status == .removed, "\(original)")
                #expect(removed.text == original)
            } }
        }
    }

    // MARK: Codex's TOML

    @Test func codexNeverMakesItsFileInvalid() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let codex = try target("codex", home: home)
        // Servers written inline, or as an array of tables: a [mcp_servers.next-term] table after them is not TOML.
        for text in ["mcp_servers = { weather = { command = \"w\" } }\n", "[[mcp_servers]]\nname = \"w\"\n"] {
            try write(text, codex.file)
            let status = MCPRegistrar.register(codex, command: command, programInstalled: true)
            #expect(status == .skipped("mcp_servers is not a table of its own"), "\(text)")
            #expect(try read(codex.file) == text)
        }
        // Someone else's next-term as dotted keys.
        let dotted = "[mcp_servers]\nnext-term.command = \"/opt/theirs\"\n"
        try write(dotted, codex.file)
        #expect(MCPRegistrar.register(codex, command: command, programInstalled: true) == .nameTaken)
        #expect(MCPRegistrar.unregister(codex) == .nameTaken)
        #expect(try read(codex.file) == dotted)
        // Servers as dotted keys at the top: a table of ours can follow them.
        let topDotted = "mcp_servers.weather.command = \"w\"\n"
        try write(topDotted, codex.file)
        #expect(MCPRegistrar.register(codex, command: command, programInstalled: true) == .registered)
        #expect(MCPRegistrar.unregister(codex) == .removed)
        #expect(try read(codex.file) == topDotted)
    }

    @Test func codexKeepsComments() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let codex = try target("codex", home: home)
        let original = "model = \"gpt-5\"\n"
        try write(original, codex.file)
        #expect(MCPRegistrar.register(codex, command: command, programInstalled: true) == .registered)
        // A server added after ours, with a comment above it.
        let weather = "# My weather server: do not remove\n[mcp_servers.weather]\ncommand = \"w\"\n"
        try write(try read(codex.file) + "\n" + weather, codex.file)
        #expect(MCPRegistrar.unregister(codex) == .removed)
        #expect(try read(codex.file) == original + "\n" + weather)
        // Another copy's entry: only the command's value changes, its indent and comment stay.
        let pinned = "[mcp_servers.next-term]\n  command = \"\(moved)\" # pinned by me\n  args = [\"mcp\"]\n"
        try write(pinned, codex.file)
        #expect(MCPRegistrar.register(codex, command: command, programInstalled: true) == .registered)
        #expect(try read(codex.file) == pinned.replacingOccurrences(of: moved, with: command))
    }

    @Test func codexFilesComeBackAsTheyWere() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let codex = try target("codex", home: home)
        let originals = [
            "", "model = \"gpt-5\"", "model = \"gpt-5\" # no line break at the end", "model = \"gpt-5\"\n\n",
            "model = \"gpt-5\"\r\n[mcp_servers.w]\r\ncommand = \"w\"\r\n",
            "[mcp_servers]\nweather = { command = \"w\" }\n",
            // A [ or # at the start of a line inside a string or an array is not a table or a comment.
            "x = \"\"\"\n[not a table]\n\"\"\"\n", "x = '''\n# not a comment\n'''\n[profiles.a]\nmodel = \"o3\"\n",
            "when = 1979-05-27 07:32:00Z\nlist = [\n  1, # one\n  2,\n]\n",
        ]
        for original in originals {
            let registered = try roundTrip(original, codex)
            #expect(registered.hasPrefix(original), "\(original)")
        }
    }

    @Test func codexKeepsWhatTheUserAddedAfterItsTable() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let codex = try target("codex", home: home)
        let additions = [
            // Servers kept for later, as comments.
            "\n# Servers I turned off for now:\n# [mcp_servers.github]\n# command = \"gh-mcp\"\n",
            // A comment about the tables after it, set apart by a blank line.
            "\n# ---- trusted projects (keep) ----\n\n[projects.\"/Users/me/code\"]\ntrust_level = \"trusted\"\n",
            "\n# the profile I use\n[profiles.fast]\nmodel = \"o3\"\n",
        ]
        for newline in ["\n", "\r\n"] {
            let original = "model = \"gpt-5\"" + newline
            for addition in additions.map({ $0.replacingOccurrences(of: "\n", with: newline) }) {
                try write(original, codex.file)
                #expect(MCPRegistrar.register(codex, command: command, programInstalled: true) == .registered)
                try write(try read(codex.file) + addition, codex.file)
                #expect(MCPRegistrar.unregister(codex) == .removed)
                #expect(try read(codex.file) == original + addition)
            }
            // Blank lines after ours at the end of the file go with it.
            try write(original, codex.file)
            #expect(MCPRegistrar.register(codex, command: command, programInstalled: true) == .registered)
            try write(try read(codex.file) + newline + newline, codex.file)
            #expect(MCPRegistrar.unregister(codex) == .removed)
            #expect(try read(codex.file) == original)
            // A comment just under ours is the user's too.
            #expect(MCPRegistrar.register(codex, command: command, programInstalled: true) == .registered)
            try write(try read(codex.file) + "# mine" + newline, codex.file)
            #expect(MCPRegistrar.unregister(codex) == .removed)
            #expect(try read(codex.file) == original + newline + "# mine" + newline)
        }
    }

    /// Made-up Codex files: strings and arrays over lines, inline tables, quoted and dotted keys, servers as tables, as
    /// dotted keys at the top or under [mcp_servers], arrays of tables, Codex's tools subtables, LF or CRLF.
    func tomlShapes(count: Int) -> [String] {
        var random = SplitMix(seed: 11)
        return (0..<count).map { _ in tomlShape(&random) }
    }

    func tomlShape(_ random: inout SplitMix) -> String {
        let newline = Bool.random(using: &random) ? "\r\n" : "\n"
        func lines(_ parts: [String]) -> String { parts.joined(separator: newline) }
        let dottedServers = Int.random(in: 0..<4, using: &random) == 0
        let settings: [String] = [
            "model = \"gpt-5\" # mine",
            "approval_policy = 'on-request'",
            "\"quoted key\" = \"a # not a comment\"",
            lines(["notes = \"\"\"", "[not a table]", "# not a comment", "\"\"\""]),
            lines(["raw = '''", "[[not a table either]]", "'''"]),
            "when = 1979-05-27T07:32:00Z",
            lines(["list = [", "  1, # one", "  [2, 3],", "]"]),
            "point = { x = 1, y = { z = \"}\" } }",
            "a.b.c = true",
        ]
        var top = settings.filter { _ in Bool.random(using: &random) }
        if dottedServers { top.append("mcp_servers.weather.command = \"w\"") }
        var tables: [String] = [
            lines(["[profiles.fast]", "model = \"o3\""]),
            lines(["[ profiles.\"o3 high\" ] # spaced", "model_reasoning_effort = \"high\""]),
            lines(["[projects.\"/Users/me/code\"]", "trust_level = \"trusted\""]),
            lines(["[mcp_servers.maps]", "command = \"m\"", "args = [\"--port\", \"1\"]"]),
            lines(["[[hooks]]", "run = \"x\"", "", "[[hooks]]", "run = \"y\""]),
            lines(["[tui]", "notifications = [", "  \"a\",", "]"]),
        ]
        if !dottedServers {
            tables.append(lines(["[mcp_servers.weather]", "command = \"w\"", "[mcp_servers.weather.env]", "TOKEN = \"made-up\"",
                                 "[mcp_servers.weather.tools.forecast]", "approval_mode = \"approve\""]))
            tables.append(lines(["[mcp_servers]", "docs.command = \"d\"", "docs.args = []"]))
        }
        tables = tables.filter { _ in Bool.random(using: &random) }.map { table in
            Int.random(in: 0..<3, using: &random) == 0 ? "# about this one" + newline + table : table
        }
        var parts = top.shuffled(using: &random) + tables.shuffled(using: &random)
        if parts.isEmpty || Int.random(in: 0..<5, using: &random) == 0 { parts.insert("# my settings", at: 0) }
        let separator = Bool.random(using: &random) ? newline : newline + newline
        return parts.joined(separator: separator) + (Int.random(in: 0..<4, using: &random) == 0 ? "" : newline)
    }

    @Test func codexFilesInManyShapesComeBackAsTheyWere() throws {
        let codex = try target("codex", home: "/nonexistent")
        var random = SplitMix(seed: 5)
        for original in tomlShapes(count: 800) { try autoreleasepool {
            let added = MCPRegistrar.plan(codex, text: original, command: command)
            #expect(added.status == .registered, "\(original)")
            let registered = try #require(added.text, "\(original)")
            // Byte for byte, not only as equal strings (which compare canonically).
            func bytes(_ text: String?) -> [UInt8]? { text.map { Array($0.utf8) } }
            #expect(Array(registered.utf8.prefix(original.utf8.count)) == Array(original.utf8), "\(original)")
            #expect(bytes(MCPRegistrar.plan(codex, text: registered, command: nil).text) == bytes(original), "\(original)")
            // Another copy of the app: only the command changes.
            let repointed = MCPRegistrar.plan(codex, text: registered, command: moved).text
            #expect(bytes(repointed) == bytes(registered.replacingOccurrences(of: command, with: moved)), "\(original)")
            // What the user adds after ours, a table or comments, stays when ours goes.
            let newline = original.contains("\r\n") ? "\r\n" : "\n"
            let start = (registered.hasSuffix(newline) ? "" : newline) + newline
            let table: [String] = ["# added later", "[later]", "x = 1"]
            let comments: [String] = ["# Servers I turned off for now:", "# [mcp_servers.github]"]
            let later = Bool.random(using: &random) ? table : comments
            let addition = start + later.joined(separator: newline) + newline
            let removed = MCPRegistrar.plan(codex, text: registered + addition, command: nil)
            #expect(removed.status == .removed, "\(original)")
            #expect(bytes(removed.text) == bytes(original + addition), "\(original)")
        } }
    }

    @Test func codexReadsArraysOverLines() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let codex = try target("codex", home: home)
        // A line inside an array that starts with [ is not a table.
        let theirs = "[mcp_servers.weather]\ncommand = \"w\"\n"
        let ours = "[mcp_servers.next-term]\ncommand = \"\(moved)\"\nargs = [\n  \"mcp\",\n]\nmatrix = [\n  [1, 2],\n]\n"
        try write(ours + "\n" + theirs, codex.file)
        #expect(MCPRegistrar.register(codex, command: command, programInstalled: true) == .registered)
        #expect(try read(codex.file) == ours.replacingOccurrences(of: moved, with: command) + "\n" + theirs)
        #expect(MCPRegistrar.unregister(codex) == .removed)
        #expect(try read(codex.file) == theirs)
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

/// The permissions of every file seen in a folder, but one, while it runs: a writer's temporary files.
final class FolderWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var modes = Set<mode_t>()
    private let done = DispatchSemaphore(value: 0)

    init(_ folder: String, ignoring name: String) {
        Thread.detachNewThread { [self] in
            while isRunning {
                autoreleasepool {
                    for entry in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where entry != name {
                        var info = stat()
                        guard lstat(folder + "/" + entry, &info) == 0 else { continue }
                        lock.lock()
                        modes.insert(info.st_mode & 0o7777)
                        lock.unlock()
                    }
                }
            }
            done.signal()
        }
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Stops, and the permissions seen.
    func stop() -> Set<mode_t> {
        lock.lock()
        running = false
        lock.unlock()
        done.wait()
        lock.lock()
        defer { lock.unlock() }
        return modes
    }
}

/// The same made-up files on every run.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
