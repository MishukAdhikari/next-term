import Foundation
import Testing
@testable import NextTermCore

/// The control options' catalogue and rules that need no screen (U14): the remote schemas that follow the options, the
/// rules the door's policy applies before the main thread, the text rule it calls for agent tabs, the control rate
/// limit, and the plan's Error texts word for word.
@Suite struct RemoteAccessControlTests {
    typealias ID = RemoteAccessOption.ID

    func tool(_ name: String, _ options: RemoteAccessOptions) throws -> [String: Any] {
        let found = try #require(RemoteAccessTools.tools(for: options).first { $0.name == name })
        let object = try JSONSerialization.jsonObject(with: Data(found.inputSchema.utf8))
        return try #require(object as? [String: Any])
    }

    func property(_ name: String, of schema: [String: Any]) -> [String: Any]? {
        (schema["properties"] as? [String: Any])?[name] as? [String: Any]
    }

    func refusal(_ tool: String, _ arguments: [String: Any], _ options: RemoteAccessOptions) -> String? {
        switch RemoteAccessPolicy.decide(tool: tool, arguments: arguments, options: options) {
        case .refuse(let text), .invalidParams(let text): return text
        case .unknownTool(let text): return text
        case .allow: return nil
        }
    }

    // MARK: schemas

    @Test func customsSchemasFollowItsStartingValues() throws {
        let custom = RemoteAccessOptions.customStart
        let send = try tool("send_to_tab", custom)
        #expect(property("text", of: send)?["maxLength"] as? Int == 8_000)
        #expect((property("submit", of: send)?["description"] as? String)?.contains("Always true") == true)
        let keys = try tool("press_keys", custom)
        let items = property("keys", of: keys)?["items"] as? [String: Any]
        #expect(items?["enum"] as? [String] == ["up", "down", "left", "right", "enter", "escape"])
        let newTab = try tool("new_tab", custom)
        #expect((newTab["required"] as? [String])?.contains("command") == true)
        let close = try tool("close_tab", custom)
        #expect(property("force", of: close) == nil)
        #expect(close["additionalProperties"] as? Bool == false)
    }

    @Test func controlKeepsTheLocalArgumentsWithTheTextLimit() throws {
        let control = RemoteAccessOptions.control
        let send = try tool("send_to_tab", control)
        #expect(property("text", of: send)?["maxLength"] as? Int == 8_000)
        #expect((property("submit", of: send)?["description"] as? String)?.contains("Always true") != true)
        let keys = try tool("press_keys", control)
        #expect((property("keys", of: keys)?["items"] as? [String: Any])?["enum"] == nil)
        #expect((try tool("new_tab", control)["required"] as? [String]) == ["directory"])
        #expect(property("force", of: try tool("close_tab", control)) != nil)
    }

    // MARK: the rules before the main thread

    @Test func submitFalseKeysAndCommandsFollowTheOptions() {
        let custom = RemoteAccessOptions.customStart
        #expect(refusal("send_to_tab", ["tab_id": "t", "text": "hi", "submit": false], custom) == RemoteAccessText.alwaysReturn)
        #expect(refusal("send_to_tab", ["tab_id": "t", "text": "hi", "submit": true], custom) == nil)
        for key in ["tab", "shift+tab", "ctrl+c", "1", "y", "n"] {
            #expect(refusal("press_keys", ["tab_id": "t", "keys": ["down", key]], custom) == RemoteAccessText.keyOff, "\(key)")
        }
        #expect(refusal("press_keys", ["tab_id": "t", "keys": ["up", "down", "left", "right", "enter", "escape"]], custom) == nil)
        for command in ["", "bash", "aider", "claude --dangerously-skip-permissions", "codex"] {
            let arguments: [String: Any] = command.isEmpty ? ["directory": "/srv/app"] : ["directory": "/srv/app", "command": command]
            #expect(refusal("new_tab", arguments, custom) == RemoteAccessText.commandOff, "\(command)")
        }
        #expect(refusal("new_tab", ["directory": "/srv/app", "command": "claude"], custom) == nil)
        #expect(refusal("new_tab", ["directory": "/srv/app", "command": "claude", "prompt": "Fix it"], custom) == RemoteAccessText.commandOff)
        // close_tab's force is no argument without "Close busy tabs", and the text names it.
        let force = refusal("close_tab", ["tab_id": "t", "force": true], custom) ?? ""
        #expect(force.hasPrefix("Invalid params: force is not an argument of close_tab.") && force.contains("“Close busy tabs”"))
        // Every key widens them all.
        var every = custom
        every[.everyKey] = true
        every[.openAnyTab] = true
        #expect(refusal("send_to_tab", ["tab_id": "t", "text": "hi", "submit": false], every) == nil)
        #expect(refusal("press_keys", ["tab_id": "t", "keys": ["tab", "ctrl+c", "1"]], every) == nil)
        #expect(refusal("new_tab", ["directory": "/srv/app", "command": "bash"], every) == nil)
        #expect(refusal("new_tab", ["directory": "/srv/app"], every) == nil)
    }

    @Test func textMayStartOnlyAsTheTextOptionsSay() {
        let custom = RemoteAccessOptions.customStart
        func said(_ text: String, _ options: RemoteAccessOptions = .customStart) -> String? {
            RemoteAccessPolicy.textRefusal(text, options: options)
        }
        #expect(said("!ls") == RemoteAccessText.shellAndMemoryOff)
        #expect(said("  # remember this") == RemoteAccessText.shellAndMemoryOff)
        for text in ["/model opus", "/mcp", "/compactx", "/"] {
            #expect(said(text) == RemoteAccessText.slashOff(.anySlash), "\(text)")
        }
        #expect(said("/compact") == nil && said("  /clear") == nil && said("/help me") == nil)
        #expect(said("fix the login") == nil && said("") == nil)
        var noAllowlist = custom
        noAllowlist[.slashAllowlist] = false
        #expect(said("/compact", noAllowlist) == RemoteAccessText.slashOff(.slashAllowlist))
        var any = noAllowlist
        any[.anySlash] = true
        #expect(said("/model opus", any) == nil && said("/compact", any) == nil)
        var shell = custom
        shell[.shellAndMemory] = true
        #expect(said("!ls", shell) == nil && said("# note", shell) == nil)
    }

    @Test func onlyCallsThatActOnTheMacAreControlCalls() {
        for tool in ["send_to_tab", "press_keys", "new_tab", "close_tab", "write_file", "commit", "install_skill", "run_with_secrets"] {
            #expect(RemoteAccessPolicy.isControlCall(tool), "\(tool)")
        }
        for tool in ["read_tab", "list_tabs", "settings_get", "list_skills", "get_skill", "list_secrets", "check_host"] {
            #expect(!RemoteAccessPolicy.isControlCall(tool), "\(tool)")
        }
    }

    @Test func atMostTenControlCallsAMinutePerConnection() {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000_000) }
        let clock = Clock()
        let calls = RemoteAccessCalls(clock: { clock.now })
        for _ in 0..<10 { #expect(calls.takeControlCall(grant: "g1")) }
        #expect(!calls.takeControlCall(grant: "g1"))
        #expect(calls.takeControlCall(grant: "g2"))
        clock.now = clock.now.addingTimeInterval(61)
        #expect(calls.takeControlCall(grant: "g1"))
    }

    // MARK: the texts

    @Test func theTextsAreThePlansWordForWord() {
        let tail = " for this connection in Settings › Remote Access on your Mac."
        #expect(RemoteAccessText.shellTab == "That is a shell tab. Turn on “Type into shell tabs”" + tail)
        #expect(RemoteAccessText.modeHidden == "Next Term can't see this agent's permission mode right now. Try again when its input line shows. "
            + "Or turn on “Type into agents that never ask, or whose mode can't be read”" + tail)
        #expect(RemoteAccessText.inputLine == "That agent's input line has text in it, or Next Term can't see it. Clear it on your Mac. "
            + "Or turn on “Any / command” and “! shell lines and # memory lines”" + tail)
        #expect(RemoteAccessText.busyTab == "That tab is busy. Close it on your Mac. Or turn on “Close busy tabs”" + tail)
        #expect(RemoteAccessText.controlRate == "Too many control calls; try again in a minute. Or turn off “At most 10 control calls a minute”" + tail)
        #expect(RemoteAccessText.commandOff == "That command is off for this connection. A new tab can run one agent name with no arguments, "
            + "such as claude. Turn on “Open a tab with any command, or a plain shell”" + tail)
        #expect(RemoteAccessText.slashOff(.slashAllowlist) == "That slash command is off for this connection. Turn on “/ commands on the allowlist”" + tail)
        #expect(RemoteAccessText.standingChoice == "That choice isn't a one-time choice Next Term knows. Turn on “Answer with standing choices, "
            + "such as always or don't ask again”" + tail)
        #expect(RemoteAccessText.enterWithText == "Return is off while the agent's input line has text. Clear it on your Mac. Or turn on “Every key”" + tail)
    }
}
