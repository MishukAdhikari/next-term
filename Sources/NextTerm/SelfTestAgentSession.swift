#if DEBUG
import AppKit
import NextTermCore

/// Agent sessions (plan 030): `nxtrm agent gemini` in a tab, with a stand-in ACP agent named gemini first on the PATH.
/// The tab is an agent tab that follows the session's reports: working, done, and attention on a permission request
/// whose menu send_to_tab, list_tabs and answer_agent see as any agent's question.
extension SelfTest {
    /// A stand-in ACP agent (Python, as the system's /usr/bin/python3 runs it): a message, a plan and tool calls for a
    /// prompt, and a permission request for one that says "rm". It writes the MCP servers it was given beside itself.
    static let acpAgentStandIn = #"""
    #!/usr/bin/python3
    # A stand-in ACP agent for testing nxtrm agent: answers initialize, session/new, and a prompt with a message,
    # a tool call, a plan, and (for a prompt containing "rm") a permission request.
    import json, sys
    def send(o): sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
    def upd(u): send({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":u}})
    pending = None
    for line in sys.stdin:
        m = json.loads(line)
        meth = m.get("method")
        if meth == "initialize":
            send({"jsonrpc":"2.0","id":m["id"],"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}})
        elif meth == "session/new":
            open(sys.argv[0] + ".mcp", "w").write(json.dumps(m["params"]["mcpServers"]))
            send({"jsonrpc":"2.0","id":m["id"],"result":{"sessionId":"s1"}})
        elif meth == "session/prompt":
            text = m["params"]["prompt"][0]["text"]
            upd({"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"Thinking about it"}})
            upd({"sessionUpdate":"plan","entries":[{"content":"Read","status":"completed","priority":"high"},{"content":"Answer","status":"in_progress","priority":"high"}]})
            upd({"sessionUpdate":"tool_call","toolCallId":"t1","title":"Read README.md","kind":"read","status":"completed"})
            if "rm" in text:
                pending = m["id"]
                upd({"sessionUpdate":"tool_call","toolCallId":"t2","title":"Run rm -rf build","kind":"execute","status":"pending"})
                send({"jsonrpc":"2.0","id":"perm1","method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t2"},"options":[{"optionId":"ok","name":"Allow once","kind":"allow_once"},{"optionId":"always","name":"Always allow","kind":"allow_always"},{"optionId":"no","name":"Reject","kind":"reject_once"}]}})
                continue
            upd({"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"You said: " + text}})
            send({"jsonrpc":"2.0","id":m["id"],"result":{"stopReason":"end_turn"}})
        elif m.get("id") == "perm1":
            choice = m["result"]["outcome"].get("optionId", "cancelled")
            upd({"sessionUpdate":"tool_call_update","toolCallId":"t2","status":"completed" if choice == "ok" else "failed"})
            upd({"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Permission answer: " + choice}})
            send({"jsonrpc":"2.0","id":pending,"result":{"stopReason":"end_turn"}})
        elif meth == "session/cancel":
            pass
    """#

    static func agentSessionChecks(_ c: TerminalWindowController) async {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), let binary = Bundle.main.executablePath else {
            return note("agent session: skipped, no /usr/bin/python3 for the stand-in agent")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nt-acp-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let standIn = folder.appendingPathComponent("gemini")
        try? acpAgentStandIn.write(to: standIn, atomically: true, encoding: .utf8)
        chmod(standIn.path, 0o755)
        let tab = c.addTab(directory: nil, select: false)
        defer { c.remove(tab) }
        guard await wait(20, { tab.status.integrated }) else { return check(false, "agent session: the tab starts its shell") }
        tab.view.send(txt: "PATH=\(ShellQuote.quote(folder.path)):$PATH \(ShellQuote.quote(binary)) --cli agent gemini\r")
        let id = tab.id.uuidString.lowercased()
        func screen() -> String { MCPControl.screenFields(tab, lines: 60)["screen"] as? String ?? "" }
        func call(_ tool: String, _ arguments: [String: Any]) async -> (text: String, isError: Bool) {
            var result: MCPServer.CallResult?
            MCPControl.call(tool, arguments, caller: nil) { result = $0 }
            _ = await wait(10) { result != nil }
            return (result?.text ?? "(no answer)", result?.isError ?? true)
        }

        let ready = await wait(15) { screen().contains("Gemini CLI is ready.") }
        check(ready && tab.status.kind == .agent && tab.status.program == CommandClassifier.agentSessionProgram,
              "agent session: nxtrm agent runs the agent over ACP in an agent tab named for the session",
              "kind \(tab.status.kind), program \(tab.status.program ?? "none"): \(screen().suffix(300))")
        let given = (try? String(contentsOf: folder.appendingPathComponent("gemini.mcp"), encoding: .utf8)) ?? ""
        check(given.contains("--cli") && given.contains("mcp") && given.contains("next-term"),
              "agent session: the agent is given Next Term's MCP server", given)

        let sent = await call("send_to_tab", ["tab_id": id, "text": "hello there"])
        let answered = await wait(10) { screen().contains("You said: hello there") && tab.status.state != .working }
        check(!sent.isError && answered && tab.programReports, "agent session: send_to_tab's prompt runs a turn that ends, by its reports",
              "\(sent.text), state \(tab.status.state.rawValue): \(screen().suffix(300))")

        _ = await call("send_to_tab", ["tab_id": id, "text": "please rm it"])
        let asks = await wait(10) { tab.status.state == .attention }
        let choices = MCPControl.questionInfo(tab)["choices"] as? [String]
        check(asks && tab.status.question == "Do you want to allow: Run rm -rf build?" && choices == ["Allow once", "Reject"],
              "agent session: a permission request is the tab's question, its options (no standing allow) the choices",
              "\(tab.status.state.rawValue), \(tab.status.question ?? "no question"), \(choices ?? [])")
        let picked = await call("answer_agent", ["tab_id": id, "question_id": MCPControl.questionID(tab) ?? "", "answer": "Reject"])
        let rejected = await wait(10) { screen().contains("Permission answer: no") && tab.status.state != .attention }
        check(!picked.isError && rejected, "agent session: answer_agent picks Reject and the agent gets it",
              "\(picked.text): \(screen().suffix(300))")

        // new_tab refuses a name it can't run before opening anything, and says which would.
        let before = c.tabs.count
        let refused = await call("new_tab", ["directory": folder.path, "agent_session": "no-such-agent"])
        check(refused.isError && refused.text.contains("Installed here") && c.tabs.count == before,
              "agent session: new_tab refuses an agent_session it can't run, opening nothing", refused.text)

        tab.view.send(txt: "\u{04}")
        let ended = await wait(6) { !tab.status.running }
        check(ended, "agent session: ⌃D on an empty line ends the session and the agent", screen().suffix(200).description)
    }
}
#endif
