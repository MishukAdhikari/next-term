import Foundation
import Testing
@testable import NextTermCore

/// The remote door's tool catalogue: the options a connection holds, the presets named from them, the tools they
/// admit with the remote limits, the remote instructions, and the parameterised respond that answers with them.
@Suite struct RemoteAccessToolsTests {
    typealias ID = RemoteAccessOption.ID

    /// Read only's ten tools, in MCPServer's order.
    let readOnlyNames = ["list_tabs", "read_tab", "wait_for_tab", "list_projects", "get_editor_selection", "get_open_files",
                         "read_file", "find_in_files", "git_status", "get_diff"]
    let serverReadNames = ["list_hosts", "check_host", "host_sessions", "host_changes"]

    func names(_ options: RemoteAccessOptions) -> [String] {
        RemoteAccessTools.tools(for: options).map(\.name)
    }

    func remoteAnswer(_ message: [String: Any], options: RemoteAccessOptions,
                      call: (String, [String: Any]) -> MCPServer.CallResult) -> [String: Any]? {
        let tools = RemoteAccessTools.tools(for: options)
        let instructions = RemoteAccessTools.instructions(for: options)
        return MCPServer.respond(to: message, version: "1.2.3", tools: tools, instructions: instructions,
                                 listChanged: true, call: call)
    }

    func schema(_ tool: MCPServer.Tool) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8))
        return try #require(object as? [String: Any])
    }

    func property(_ name: String, of tool: String, in tools: [MCPServer.Tool]) throws -> [String: Any] {
        let found = try #require(tools.first { $0.name == tool })
        let properties = try #require(try schema(found)["properties"] as? [String: Any])
        return try #require(properties[name] as? [String: Any])
    }

    func sortedJSON(_ value: Any?) -> Data? {
        guard let value, JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    // MARK: the option table

    @Test func theTableHasOneRowPerOptionInItsOrder() {
        let ids = RemoteAccessOption.all.map(\.id)
        #expect(ids == ID.allCases)
        let keys = Set(ID.allCases.map(\.rawValue))
        #expect(keys.count == ID.allCases.count)
        let labels = Set(RemoteAccessOption.all.map(\.label))
        #expect(labels.count == RemoteAccessOption.all.count)
        // The groups come in the order the options view shows them, each in one run.
        var seen: [RemoteAccessOption.Group] = []
        for option in RemoteAccessOption.all where seen.last != option.group {
            #expect(!seen.contains(option.group), "\(option.group) is split")
            seen.append(option.group)
        }
        #expect(seen == RemoteAccessOption.Group.allCases)
    }

    @Test func labelsAreThePlansWordForWord() {
        let labels: [ID: String] = [
            .tabs: "Tabs and their output",
            .projectFiles: "Project files, diffs and git",
            .editor: "Editor selection and open files",
            .serversRead: "Servers: list, check and read changes",
            .typeAsking: "Type into agents that ask before acting",
            .typeNeverAsking: "Type into agents that never ask, or whose mode can't be read",
            .answerOnce: "Answer with a one-time choice",
            .answerStanding: "Answer with standing choices, such as always or don't ask again",
            .slashAllowlist: "/ commands on the allowlist",
            .anySlash: "Any / command",
            .shellAndMemory: "! shell lines and # memory lines",
            .safeKeys: "Arrows, Return and Escape",
            .everyKey: "Every key",
            .typeShells: "Type into shell tabs",
            .openAgentTab: "Open a tab that runs a listed agent",
            .openAnyTab: "Open a tab with any command, or a plain shell",
            .closeIdleTabs: "Close tabs where nothing runs",
            .closeBusyTabs: "Close busy tabs",
            .showOnMac: "Open projects and show things on the Mac",
            .servers: "Servers: add, remove and open tabs",
            .skills: "Skills",
            .writeTools: "Next Term's write tools",
            .listSecrets: "List secret names",
            .useSecrets: "Use secrets",
            .askOnMac: "Ask on this Mac before changes",
            .notify: "Notify on this Mac",
            .rateLimit: "At most 10 control calls a minute",
        ]
        #expect(labels.count == ID.allCases.count)
        for (id, label) in labels { #expect(RemoteAccessOption.option(id).label == label, "\(id)") }
        let titles = RemoteAccessOption.Group.allCases.map(\.title)
        #expect(titles == ["See", "Agents", "Text", "Keys", "Shells", "Tabs", "More tools", "Secrets", "Checks"])
    }

    /// Allow by name (R21): only the See options name tools until the control options do (U14). The Secrets
    /// options are a stub until plan 007's tools are in the base, and nothing names the import tools.
    @Test func onlyTheSeeOptionsNameToolsAndEveryNameIsATool() {
        let known = Set(MCPServer.tools.map(\.name))
        for option in RemoteAccessOption.all {
            for name in option.tools { #expect(known.contains(name), "\(option.id) names \(name)") }
            if option.group != .see { #expect(option.tools.isEmpty, "\(option.id)") }
        }
        let named = Set(RemoteAccessOption.all.flatMap(\.tools))
        for tool in MCPServer.importTools { #expect(!named.contains(tool.name), "\(tool.name)") }
        #expect(RemoteAccessOption.option(.listSecrets).tools.isEmpty && RemoteAccessOption.option(.useSecrets).tools.isEmpty)
        let seeNames = RemoteAccessOption.all.filter { $0.group == .see }.flatMap(\.tools)
        #expect(Set(seeNames) == Set(readOnlyNames + serverReadNames))
    }

    // MARK: presets

    @Test func presetsAreNamedFromTheirOwnValues() {
        #expect(RemoteAccessOptions.readOnly.preset == .readOnly)
        #expect(RemoteAccessOptions.control.preset == .control)
        #expect(RemoteAccessOptions.customStart.preset == .custom)
        #expect(RemoteAccessPreset.preselected == .readOnly)
        for preset in RemoteAccessPreset.allCases {
            let options = preset.options
            #expect(options.preset == preset, "\(preset)")
        }
        #expect(RemoteAccessPreset.custom.options == RemoteAccessOptions.customStart)
        var more = RemoteAccessOptions.readOnly
        more[.serversRead] = true
        #expect(more.preset == .custom)
        #expect(RemoteAccessPreset.readOnly.title == "Read only")
        #expect(RemoteAccessPreset.control.title == "Control")
        #expect(RemoteAccessPreset.custom.title == "Custom")
    }

    @Test func theChecksNeverChangeReadOnlyAndOnlyAskingChangesControl() {
        var control = RemoteAccessOptions.control
        control[.notify] = false
        #expect(control.preset == .control)
        control = RemoteAccessOptions.control
        control[.rateLimit] = true
        #expect(control.preset == .control)
        control = RemoteAccessOptions.control
        control[.askOnMac] = true
        #expect(control.preset == .custom)
        for id in [ID.everyKey, .anySlash] {
            control = RemoteAccessOptions.control
            control[id] = false
            #expect(control.preset == .custom, "\(id)")
        }
        for id in [ID.notify, .askOnMac] {
            var readOnly = RemoteAccessOptions.readOnly
            readOnly[id] = false
            #expect(readOnly.preset == .readOnly, "\(id)")
        }
        for id in [ID.slashAllowlist, .safeKeys] {
            var readOnly = RemoteAccessOptions.readOnly
            readOnly[id] = true
            #expect(readOnly.preset == .custom, "\(id)")
        }
    }

    @Test func presetValuesFollowTheTable() {
        let textAndKeys = RemoteAccessOption.all.filter { $0.group == .text || $0.group == .keys }
        #expect(textAndKeys.count == 5)
        for option in textAndKeys {
            #expect(RemoteAccessOptions.readOnly[option.id] == false, "\(option.id)")
            #expect(RemoteAccessOptions.control[option.id] == true, "\(option.id)")
        }
        // Read only: the first three See options; the Checks as Custom starts; nothing else.
        let readOnlyOn: Set<ID> = [.tabs, .projectFiles, .editor, .askOnMac, .notify, .rateLimit]
        #expect(RemoteAccessOptions.readOnly.on == readOnlyOn)
        // Control: everything outside Checks, and Notify; never Ask or the control rate limit.
        let controlOff: Set<ID> = [.askOnMac, .rateLimit]
        #expect(RemoteAccessOptions.control.on == Set(ID.allCases).subtracting(controlOff))
        // Custom starts from the safe values.
        let customOn: Set<ID> = [.tabs, .projectFiles, .editor, .typeAsking, .answerOnce, .slashAllowlist, .safeKeys,
                                 .openAgentTab, .closeIdleTabs, .writeTools, .askOnMac, .notify, .rateLimit]
        #expect(RemoteAccessOptions.customStart.on == customOn)
    }

    /// An option the grant file does not hold (one a later release adds) starts safe: on for Checks, off elsewhere.
    @Test func aMissingOptionReadsOnOnlyInChecks() throws {
        var stored = RemoteAccessOptions.control.stored
        stored[ID.typeShells.rawValue] = nil
        stored[ID.everyKey.rawValue] = nil
        stored[ID.rateLimit.rawValue] = nil
        let options = RemoteAccessOptions(stored: stored)
        #expect(options[.typeShells] == false)
        #expect(options[.everyKey] == false)
        #expect(options[.rateLimit] == true)
        let empty = RemoteAccessOptions(stored: [:])
        #expect(empty.on == Set(RemoteAccessOption.all.filter { $0.group == .checks }.map(\.id)))
        // The grant file holds the values by key, and reads them back the same.
        let data = try JSONEncoder().encode(options)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Bool])
        #expect(object[ID.tabs.rawValue] == true && object[ID.everyKey.rawValue] == nil)
        let decoded = try JSONDecoder().decode(RemoteAccessOptions.self, from: data)
        #expect(decoded == options && decoded[.rateLimit] && !decoded[.everyKey])
    }

    // MARK: the catalogue

    @Test func readOnlyListsTheTenReadToolsAsLocally() throws {
        #expect(names(.readOnly) == readOnlyNames)
        let message: [String: Any] = ["jsonrpc": "2.0", "id": "a", "method": "tools/list"]
        let reply = remoteAnswer(message, options: .readOnly) { _, _ in .init(text: "") }
        let listed = try #require((reply?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(listed.map { $0["name"] as? String ?? "" } == readOnlyNames)
        let local = MCPServer.listing()
        for tool in listed {
            let name = tool["name"] as? String ?? ""
            let same = try #require(local.first { $0["name"] as? String == name })
            #expect(sortedJSON(tool["annotations"]) == sortedJSON(same["annotations"]), "\(name)")
            #expect(sortedJSON(tool["_meta"]) == sortedJSON(same["_meta"]), "\(name)")
            #expect(tool["title"] as? String == same["title"] as? String, "\(name)")
            #expect(tool["description"] as? String == same["description"] as? String, "\(name)")
        }
    }

    @Test func readOnlyListsNoToolThatActsOrReachesAServer() {
        let listed = Set(names(.readOnly))
        for name in ["send_to_tab", "close_tab", "press_keys", "answer_agent", "new_tab"] + serverReadNames {
            #expect(!listed.contains(name), "\(name)")
        }
        for name in ["add_host", "remove_host", "new_remote_tab", "write_file", "install_skill", "list_import_sources"] {
            #expect(!listed.contains(name), "\(name)")
        }
        var servers = RemoteAccessOptions.readOnly
        servers[.serversRead] = true
        let added = Set(names(servers)).subtracting(listed)
        #expect(added == Set(serverReadNames))
        // A tool no option names, such as one a later release adds, is never listed.
        let base = MCPServer.tool(named: "list_projects")!
        let madeUp = MCPServer.Tool(name: "made_up", title: "Made up", description: "Made up.", inputSchema: base.inputSchema,
                                    readOnly: true, destructive: false, idempotent: true, timeout: 15)
        let table = MCPServer.tools + [madeUp]
        let fromTable = RemoteAccessTools.tools(for: .readOnly, from: table).map(\.name)
        #expect(fromTable == readOnlyNames)
        let control = RemoteAccessTools.tools(for: .control, from: table).map(\.name)
        #expect(!control.contains("made_up"))
    }

    /// Until the control options name their tools (U14), Control lists what the See options name, and the
    /// Secrets options admit nothing.
    @Test func controlListsWhatItsOptionsName() {
        let expected = MCPServer.tools.map(\.name).filter { Set(readOnlyNames + serverReadNames).contains($0) }
        #expect(names(.control) == expected)
        #expect(names(.customStart) == readOnlyNames)
    }

    @Test func theRemoteLimitsAreInTheSchemas() throws {
        let tools = RemoteAccessTools.tools(for: .control)
        let readTab = try property("lines", of: "read_tab", in: tools)
        #expect(readTab["maximum"] as? Int == 400)
        let wait = try property("timeout_seconds", of: "wait_for_tab", in: tools)
        #expect(wait["maximum"] as? Int == 50 && wait["minimum"] as? Int == 1)
        let readFile = try property("limit", of: "read_file", in: tools)
        #expect(readFile["maximum"] as? Int == 500)
        let diff = try property("max_chars", of: "get_diff", in: tools)
        #expect(diff["maximum"] as? Int == 60_000)
        let hostChanges = try property("max_bytes", of: "host_changes", in: tools)
        #expect(hostChanges["maximum"] as? Int == 60_000)
        // The sentence about the default says the remote limit, not the local one.
        #expect((wait["description"] as? String)?.contains("300") == false)
        #expect((hostChanges["description"] as? String)?.contains("Default 60000") == true)
        #expect((readTab["description"] as? String)?.contains("400") == true)
        #expect(RemoteAccessLimits.readTabLines == 400 && RemoteAccessLimits.waitSeconds == 50)
        #expect(RemoteAccessLimits.readFileLines == 500 && RemoteAccessLimits.diffChars == 60_000)
        #expect(RemoteAccessLimits.hostChangesBytes == 60_000 && RemoteAccessLimits.resultChars == 64_000)
    }

    /// Only the limited arguments change: every other field is copied, schema included.
    @Test func everyOtherFieldIsCopied() throws {
        let limited: [String: String] = ["read_tab": "lines", "wait_for_tab": "timeout_seconds", "read_file": "limit",
                                         "get_diff": "max_chars", "host_changes": "max_bytes"]
        for remote in RemoteAccessTools.tools(for: .control) {
            let local = try #require(MCPServer.tool(named: remote.name))
            #expect(remote.title == local.title && remote.description == local.description, "\(remote.name)")
            #expect(remote.readOnly == local.readOnly && remote.destructive == local.destructive, "\(remote.name)")
            #expect(remote.idempotent == local.idempotent && remote.openWorld == local.openWorld, "\(remote.name)")
            #expect(remote.alwaysLoad == local.alwaysLoad && remote.timeout == local.timeout, "\(remote.name)")
            var remoteSchema = try schema(remote)
            var localSchema = try schema(local)
            if let argument = limited[remote.name] {
                var remoteProperties = try #require(remoteSchema["properties"] as? [String: Any])
                var localProperties = try #require(localSchema["properties"] as? [String: Any])
                remoteProperties[argument] = nil
                localProperties[argument] = nil
                remoteSchema["properties"] = remoteProperties
                localSchema["properties"] = localProperties
            }
            #expect(sortedJSON(remoteSchema) == sortedJSON(localSchema), "\(remote.name)")
        }
    }

    // MARK: the scope tag cross-check

    @Test func theStartCheckRefusesOnlyASeeToolTaggedWrite() throws {
        #expect(RemoteAccessTools.startCheck() == nil)
        var tags = MCPServer.scopeTags
        tags["read_tab"] = .write
        let refused = RemoteAccessTools.startCheck(tools: MCPServer.tools) { tags[$0.name] }
        #expect(refused?.tools == ["read_tab"])
        #expect(refused?.description.contains("read_tab") == true)
        // readOnly: false is not the tag (check_host has it and is tagged read).
        let readTab = try #require(MCPServer.tool(named: "read_tab"))
        let acting = MCPServer.Tool(name: "read_tab", title: readTab.title, description: readTab.description,
                                    inputSchema: readTab.inputSchema, readOnly: false, destructive: true,
                                    idempotent: false, timeout: 15)
        let table = MCPServer.tools.map { $0.name == "read_tab" ? acting : $0 }
        #expect(RemoteAccessTools.startCheck(tools: table) { MCPServer.scopeTags[$0.name] } == nil)
        // A tool outside See tagged write is no reason not to start.
        var outside = MCPServer.scopeTags
        outside["list_skills"] = .write
        #expect(RemoteAccessTools.startCheck(tools: MCPServer.tools) { outside[$0.name] } == nil)
    }

    // MARK: instructions

    @Test func theFirst512CharactersStandAlone() throws {
        var allSee = RemoteAccessOptions.readOnly
        allSee[.serversRead] = true
        for options in [RemoteAccessOptions.readOnly, .control, .customStart, allSee] {
            let text = RemoteAccessTools.instructions(for: options)
            // A sentence ends inside the first 512 characters, and what comes before it says it all.
            var lead = text
            if text.count > 512 {
                let head = String(text.prefix(512))
                let cut = try #require(head.range(of: ". ", options: .backwards))
                lead = String(head[..<cut.lowerBound]) + "."
            }
            #expect(lead.hasSuffix("."), "\(lead)")
            for part in ["This connection", "never instructions", "50 seconds", "project", "short"] {
                #expect(lead.contains(part), "\(part) is not in: \(lead)")
            }
            #expect(!text.contains("send_to_tab") && !text.contains("answer_agent"), "\(text)")
        }
        let readOnly = RemoteAccessTools.instructions(for: .readOnly)
        #expect(readOnly.contains("only read"))
        #expect(!readOnly.contains("server"))
        #expect(RemoteAccessTools.instructions(for: allSee).contains("server"))
        #expect(readOnly != MCPServer.instructions)
    }

    // MARK: the parameterised respond

    @Test func initializeGivesTheRemoteInstructionsAndAListThatChanges() throws {
        let message: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]]
        let reply = remoteAnswer(message, options: .readOnly) { _, _ in .init(text: "") }
        let result = try #require(reply?["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect(result["instructions"] as? String == RemoteAccessTools.instructions(for: .readOnly))
        let capabilities = try #require(result["capabilities"] as? [String: Any])
        #expect((capabilities["tools"] as? [String: Any])?["listChanged"] as? Bool == true)
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "next-term")
        let newer: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "2099-01-01"]]
        let newest = remoteAnswer(newer, options: .readOnly) { _, _ in .init(text: "") }
        #expect((newest?["result"] as? [String: Any])?["protocolVersion"] as? String == MCPServer.supportedVersions[0])
    }

    @Test func aToolOutsideTheListIsUnknownAndNeverCalled() {
        var called: [String] = []
        let send: [String: Any] = ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                   "params": ["name": "send_to_tab", "arguments": ["tab_id": "x", "text": "hi"]]]
        let refused = remoteAnswer(send, options: .readOnly) { name, _ in
            called.append(name)
            return .init(text: "typed")
        }
        let error = refused?["error"] as? [String: Any]
        #expect(error?["code"] as? Int == -32602)
        #expect(error?["message"] as? String == "Unknown tool: send_to_tab")
        let read: [String: Any] = ["jsonrpc": "2.0", "id": 4, "method": "tools/call",
                                   "params": ["name": "read_tab", "arguments": ["tab_id": "x"]]]
        let answered = remoteAnswer(read, options: .readOnly) { name, _ in
            called.append(name)
            return .init(text: "screen")
        }
        let content = ((answered?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first
        #expect(content?["text"] as? String == "screen")
        #expect(called == ["read_tab"])
    }

    /// nxtrm mcp answers byte for byte as before: the old entry point is the new one with the full list, the
    /// local instructions and a list that never changes.
    @Test func theLocalAnswerIsTheSame() {
        let messages: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25"]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "list_import_sources"]],
            ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "rm_rf"]],
        ]
        for message in messages {
            let old = MCPServer.respond(to: message, version: "1.2.3") { name, _ in .init(text: name) }
            let new = MCPServer.respond(to: message, version: "1.2.3", tools: MCPServer.tools,
                                        instructions: MCPServer.instructions, listChanged: false) { name, _ in .init(text: name) }
            #expect(sortedJSON(old) != nil)
            #expect(sortedJSON(old) == sortedJSON(new), "\(message["method"] ?? "")")
        }
        let listed = MCPServer.listing(of: MCPServer.tools)
        #expect(sortedJSON(listed) == sortedJSON(MCPServer.listing()))
    }
}
