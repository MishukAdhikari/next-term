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
              "kind \(tab.status.kind), program \(tab.status.program.isEmpty ? "none" : tab.status.program): \(screen().suffix(300))")
        let given = (try? String(contentsOf: folder.appendingPathComponent("gemini.mcp"), encoding: .utf8)) ?? ""
        check(given.contains("--cli") && given.contains("mcp") && given.contains("next-term"),
              "agent session: the agent is given Next Term's MCP server", given)

        let sent = await call("send_to_tab", ["tab_id": id, "text": "hello there"])
        let answered = await wait(10) { screen().contains("You said: hello there") && tab.status.state != .working }
        check(!sent.isError && answered && tab.programReports, "agent session: send_to_tab's prompt runs a turn that ends, by its reports",
              "\(sent.text), state \(tab.status.state.rawValue): \(screen().suffix(300))")
        let read = await call("read_tab", ["tab_id": id, "lines": 5])
        let readJSON = (try? JSONSerialization.jsonObject(with: Data(read.text.utf8))) as? [String: Any] ?? [:]
        check(readJSON["stop_reason"] as? String == "end_turn" && readJSON["last_message"] as? String == "You said: hello there"
                  && readJSON["agent_session"] as? String == "Gemini CLI",
              "agent session: read_tab gives the turn's stop reason and the agent's last message exactly", read.text)

        _ = await call("send_to_tab", ["tab_id": id, "text": "please rm it"])
        let asks = await wait(10) { tab.status.state == .attention }
        let choices = MCPControl.questionInfo(tab)["choices"] as? [String]
        check(asks && tab.status.question == "Do you want to allow: Run rm -rf build?" && choices == ["Allow once", "Always allow", "Reject"],
              "agent session: a permission request is the tab's question, the agent's options the choices",
              "\(tab.status.state.rawValue), \(tab.status.question ?? "no question"), \(choices ?? [])")

        // Always allow, picked by an agent, is asked of the user on the Mac; declined there, the request stays open.
        let always = await call("answer_agent", ["tab_id": id, "question_id": MCPControl.questionID(tab) ?? "", "answer": "Always allow"])
        var approval: AgentApprovalWindow?
        let shown = await wait(10) {
            approval = NSApp.windows.compactMap { $0.windowController as? AgentApprovalWindow }.first { $0.window?.title == "Allow Gemini CLI always?" }
            return approval?.window?.isVisible == true
        }
        check(!always.isError && shown && screen().contains("Waiting for your OK on the Mac"),
              "agent session: Always allow from answer_agent asks the user on the Mac first", "\(always.text): \(screen().suffix(300))")
        approval?.declineButton.performClick(nil)
        let stillOpen = await wait(10) { screen().contains("was declined on the Mac") && tab.status.state == .attention }
        check(stillOpen && !screen().contains("Permission answer"), "agent session: declined on the Mac, the agent gets no answer and the request stays open",
              screen().suffix(300).description)
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

        await claudeCodexSessionChecks(c, binary: binary)
    }
}
/// Claude Code and Codex sessions (plan 035 U6): `nxtrm agent claude` and `nxtrm agent codex` with stand-ins named claude
/// and codex first on the tab's PATH, so the user's own CLIs never run. Each stand-in writes what it was sent to a log
/// beside itself, which also proves it was the one that ran. Folder trust and the CLI versions the app keeps go to a
/// defaults suite of this part's own, so the user's lists are never touched.
extension SelfTest {
    /// A stand-in for `claude -p` with stream-json in and out and the control channel on stdio. By prompt: "please rm"
    /// asks can_use_tool for Bash with no suggestions, "always" with a suggestion, "ask" asks AskUserQuestion with two
    /// questions, "wait" starts a turn that only an interrupt ends; anything else streams a reply and runs a tool.
    /// STANDIN_MODE=auth answers the first prompt as an account that isn't signed in.
    static let claudeStandIn = #"""
    #!/usr/bin/python3
    # A stand-in for Claude Code's claude -p, for testing nxtrm agent claude. Never a real model or account.
    import json, os, sys
    log = open(sys.argv[0] + ".log", "a", buffering=1)
    def note(*words): log.write(" ".join(str(w) for w in words) + "\n")
    if "--version" in sys.argv:
        note("version")
        print(os.environ.get("STANDIN_VERSION", "2.1.4") + " (Claude Code)")
        sys.exit(0)
    args = sys.argv[1:]
    note("session", os.getpid(), json.dumps(args))
    mode = os.environ.get("STANDIN_MODE", "")
    sid = args[args.index("--resume") + 1] if "--resume" in args else "sess-standin-1"
    def send(o): sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
    def assistant(mid, content, **more):
        o = {"type": "assistant", "message": {"id": mid, "role": "assistant", "content": content}, "parent_tool_use_id": None, "session_id": sid}
        o.update(more)
        send(o)
    def text(words, mid): assistant(mid, [{"type": "text", "text": words}])
    def tool_use(tid, name, given): assistant("m-" + tid, [{"type": "tool_use", "id": tid, "name": name, "input": given}])
    def tool_result(tid, out, failed=False):
        send({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tid, "content": out, "is_error": failed}]}, "parent_tool_use_id": None, "session_id": sid})
    def result(sub="success", failed=False, words=""):
        send({"type": "result", "subtype": sub, "is_error": failed, "result": words, "total_cost_usd": 0.0123, "usage": {"input_tokens": 1200, "output_tokens": 34}, "modelUsage": {"stand-in-model": {"contextWindow": 200000}}, "session_id": sid})
    def delta(words): send({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": words}}, "parent_tool_use_id": None, "session_id": sid})
    asked = {}
    def ask(rid, tool, given, suggestions=None, kind="tool"):
        request = {"subtype": "can_use_tool", "tool_name": tool, "input": given, "tool_use_id": "tu-" + rid}
        if suggestions: request["permission_suggestions"] = suggestions
        asked[rid] = kind
        send({"type": "control_request", "request_id": rid, "request": request})
    turn = 0
    while True:
        line = sys.stdin.readline()
        if not line: break
        try: m = json.loads(line)
        except ValueError: continue
        kind = m.get("type")
        if kind == "control_request":
            sub = m["request"].get("subtype")
            note("control", sub)
            if sub == "initialize":
                send({"type": "system", "subtype": "init", "session_id": sid, "model": "stand-in-model", "tools": ["Bash", "Edit"], "mcp_servers": [], "slash_commands": ["compact"], "capabilities": ["interrupt_receipt_v1"]})
                send({"type": "control_response", "response": {"subtype": "success", "request_id": m["request_id"], "response": {"commands": []}}})
            elif sub == "interrupt":
                send({"type": "control_response", "response": {"subtype": "success", "request_id": m["request_id"], "response": {}}})
                send({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "[Request interrupted by user]"}]}, "parent_tool_use_id": None, "session_id": sid})
                result("error_during_execution", True)
            continue
        if kind == "control_response":
            r = m.get("response", {})
            rid = r.get("request_id")
            answer = r.get("response", {})
            note("answer", rid, json.dumps(answer, sort_keys=True))
            if asked.pop(rid, None) == "question":
                text("Answers: " + json.dumps(answer.get("updatedInput", {}).get("answers", {}), sort_keys=True), "m-" + rid)
            else:
                allowed = answer.get("behavior") == "allow"
                tool_result("tu-" + rid, "ok" if allowed else answer.get("message", ""), not allowed)
                text("Permission answer: " + str(answer.get("behavior")), "m-" + rid)
            result()
            continue
        if kind != "user": continue
        words = m["message"]["content"]
        if isinstance(words, list): words = " ".join(b.get("text", "") for b in words if isinstance(b, dict))
        turn += 1
        note("turn", turn, os.getpid(), words)
        if mode == "auth":
            assistant("m-auth", [{"type": "text", "text": "Invalid API key. Please run /login"}], error="authentication_failed")
            result("success", True, "Invalid API key. Please run /login")
        elif words.startswith("please rm"):
            tool_use("tu-perm-rm", "Bash", {"command": "rm -rf build"})
            ask("perm-rm", "Bash", {"command": "rm -rf build"})
        elif words.startswith("always"):
            rule = {"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "make build"}], "behavior": "allow", "destination": "localSettings"}
            tool_use("tu-perm-always", "Bash", {"command": "make build"})
            ask("perm-always", "Bash", {"command": "make build"}, [rule])
        elif words.startswith("ask"):
            questions = [
                {"question": "Which color?", "header": "Color", "multiSelect": False, "options": [{"label": "Red", "description": ""}, {"label": "Blue", "description": ""}]},
                {"question": "Which size?", "header": "Size", "multiSelect": False, "options": [{"label": "Small", "description": ""}, {"label": "Large", "description": ""}]},
            ]
            ask("perm-ask", "AskUserQuestion", {"questions": questions}, None, "question")
        elif words.startswith("wait"):
            text("Working on it", "m-wait-%d" % turn)
        else:
            mid = "m-turn-%d" % turn
            send({"type": "stream_event", "event": {"type": "message_start", "message": {"id": mid}}, "parent_tool_use_id": None, "session_id": sid})
            delta("Streamed ")
            delta("reply to: " + words)
            text("Streamed reply to: " + words, mid)
            tool_use("ls-%d" % turn, "Bash", {"command": "ls"})
            tool_result("ls-%d" % turn, "README.md")
            result()
    """#

    /// A stand-in for `codex app-server` (JSON-RPC over stdio). It has no thread/resume, so a resume falls back to a new
    /// thread. By prompt: "run" asks command approval, "other" makes a request Next Term doesn't take, "wait" starts a turn
    /// that only turn/interrupt ends; anything else answers and runs a command. STANDIN_MODE=drift answers initialize in a
    /// shape Next Term doesn't know, STANDIN_MODE=nologin reports no account.
    static let codexStandIn = #"""
    #!/usr/bin/python3
    # A stand-in for codex app-server, for testing nxtrm agent codex. Never a real model or account.
    import json, os, sys
    log = open(sys.argv[0] + ".log", "a", buffering=1)
    def note(*words): log.write(" ".join(str(w) for w in words) + "\n")
    note("session", os.getpid(), json.dumps(sys.argv[1:]))
    mode = os.environ.get("STANDIN_MODE", "")
    def send(o): sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
    def notify(method, params): send({"jsonrpc": "2.0", "method": method, "params": params})
    def answer(i, result): send({"jsonrpc": "2.0", "id": i, "result": result})
    def error(i, code, words): send({"jsonrpc": "2.0", "id": i, "error": {"code": code, "message": words}})
    thread = "thr-standin-1"
    turn = None
    turns = 0
    waiting = {}
    def say(words): notify("item/agentMessage/delta", {"threadId": thread, "turnId": turn, "itemId": "msg-%d" % turns, "delta": words})
    def command(cid, status, out=""):
        item = {"id": cid, "type": "commandExecution", "command": "make test" if cid.startswith("cmd-") else "ls", "status": status, "aggregatedOutput": out}
        notify("item/started" if status == "inProgress" else "item/completed", {"threadId": thread, "turnId": turn, "item": item})
    def done(status="completed"):
        global turn
        notify("turn/completed", {"threadId": thread, "turn": {"id": turn, "status": status, "items": []}})
        turn = None
    while True:
        line = sys.stdin.readline()
        if not line: break
        try: m = json.loads(line)
        except ValueError: continue
        method = m.get("method")
        i = m.get("id")
        if method is None and i is not None:
            cid = waiting.pop(i, None)
            if "error" in m:
                note("answer", i, "error", m["error"].get("code"))
                say("Other request answered: %s" % m["error"].get("code"))
            else:
                decision = m.get("result", {}).get("decision")
                note("answer", i, decision)
                command(cid or "cmd-0", "completed" if decision == "accept" else "declined")
                say("Approval: %s" % decision)
            done()
            continue
        note("request" if i is not None else "notification", method)
        if method == "initialize":
            if mode == "drift": answer(i, {"serverInfo": {}})
            else: answer(i, {"userAgent": "codex_cli_rs/0.154.0 (Mac OS; arm64) stand-in"})
        elif method == "account/read":
            answer(i, {"account": None if mode == "nologin" else {"type": "chatgpt"}, "requiresOpenaiAuth": True})
        elif method == "thread/resume":
            error(i, -32601, "method not found: thread/resume")
        elif method == "thread/start":
            note("thread", json.dumps(m.get("params", {}), sort_keys=True))
            answer(i, {"thread": {"id": thread}, "model": "stand-in-codex"})
        elif method == "turn/start":
            turns += 1
            turn = "turn-%d" % turns
            words = " ".join(x.get("text", "") for x in m["params"].get("input", []))
            note("turn", turns, os.getpid(), words)
            answer(i, {"turn": {"id": turn, "status": "inProgress", "items": []}})
            notify("turn/started", {"threadId": thread, "turn": {"id": turn, "status": "inProgress", "items": []}})
            if words.startswith("run"):
                cid = "cmd-%d" % turns
                command(cid, "inProgress")
                waiting[100 + turns] = cid
                send({"jsonrpc": "2.0", "id": 100 + turns, "method": "item/commandExecution/requestApproval", "params": {"threadId": thread, "turnId": turn, "itemId": cid, "command": "make test", "cwd": os.getcwd()}})
            elif words.startswith("other"):
                waiting[200 + turns] = None
                send({"jsonrpc": "2.0", "id": 200 + turns, "method": "item/tool/requestUserInput", "params": {"threadId": thread, "turnId": turn, "questions": []}})
            elif words.startswith("wait"):
                say("Working on it")
            else:
                say("Codex says: " + words)
                command("ls-%d" % turns, "inProgress")
                command("ls-%d" % turns, "completed", "README.md")
                done()
        elif method == "turn/interrupt":
            note("interrupt")
            answer(i, {})
            done("interrupted")
    """#

    static func claudeCodexSessionChecks(_ c: TerminalWindowController, binary: String) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nt-cc-\(UUID().uuidString.prefix(8))")
        let bin = root.appendingPathComponent("bin")
        let work = root.appendingPathComponent("work")
        let sub = work.appendingPathComponent("sub")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = bin.appendingPathComponent("claude")
        let codex = bin.appendingPathComponent("codex")
        try? claudeStandIn.write(to: claude, atomically: true, encoding: .utf8)
        try? codexStandIn.write(to: codex, atomically: true, encoding: .utf8)
        chmod(claude.path, 0o755)
        chmod(codex.path, 0o755)

        // Trust and versions in this part's own suite: the user's lists are never read or changed.
        let suiteName = "nt-selftest-agent-sessions-\(getpid())"
        guard let suite = UserDefaults(suiteName: suiteName) else { return note("claude and codex sessions: skipped, no defaults suite") }
        let savedTrust = AgentSessionSocket.trustStore
        let savedVersions = AgentSessionSocket.versionStore
        AgentSessionSocket.trustStore = suite
        AgentSessionSocket.versionStore = suite
        suite.set(["claude": "2.1.3"], forKey: AgentSessionSocket.versionsKey) // the version before, for the "updated" line
        var tabs: [TerminalTab] = []
        defer {
            for tab in tabs { c.remove(tab) }
            // Whatever is still asked on the Mac is declined, and this part's folders leave the trusted list.
            for window in approvals() { window.declineButton.performClick(nil) }
            var list = AgentSessionTrust.list(in: suite)
            for folder in [work, sub] { list = AgentSessionTrust.removing(folder.path, from: list) }
            suite.set(list, forKey: AgentSessionTrust.defaultsKey)
            AgentSessionSocket.trustStore = savedTrust
            AgentSessionSocket.versionStore = savedVersions
            UserDefaults().removePersistentDomain(forName: suiteName)
        }

        /// A tab in `folder` running `nxtrm agent WORDS`, the stand-ins first on its PATH.
        func session(_ folder: URL, _ words: String, env: String = "") async -> TerminalTab? {
            let tab = c.addTab(directory: folder.path, select: false)
            tabs.append(tab)
            guard await wait(20, { tab.status.integrated }) else { return nil }
            let prefix = env.isEmpty ? "" : env + " "
            tab.view.send(txt: prefix + "PATH=\(ShellQuote.quote(bin.path)):$PATH \(ShellQuote.quote(binary)) --cli agent \(words)\r")
            return tab
        }
        guard let first = await session(work, "claude") else { return check(false, "claude session: the tab starts its shell") }
        await claudeChecks(first, claudeLog: claude.appendingPathExtension("log"), session: session, work: work, sub: sub, suite: suite)
        await codexChecks(codexLog: codex.appendingPathExtension("log"), session: session, work: work)
    }

    /// The approval windows open now, by title.
    static func approvals(_ title: String? = nil) -> [AgentApprovalWindow] {
        let windows: [AgentApprovalWindow] = NSApp.windows.compactMap { $0.windowController as? AgentApprovalWindow }
        return windows.filter { window in
            guard window.window?.isVisible == true else { return false }
            return title == nil || window.window?.title == title
        }
    }

    /// A tab's screen, its whitespace runs as single spaces, so words a wrap split read whole.
    static func flatScreen(_ tab: TerminalTab) -> String {
        let screen = MCPControl.screenFields(tab, lines: 80)["screen"] as? String ?? ""
        return screen.split(whereSeparator: { $0 == " " || $0 == "\n" }).joined(separator: " ")
    }

    static func standInLog(_ url: URL) -> [String] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    /// The process ids a stand-in's turns ran in ("turn N PID words").
    static func turnPIDs(_ lines: [String]) -> Set<String> {
        var pids: Set<String> = []
        for line in lines where line.hasPrefix("turn ") {
            let words = line.split(separator: " ")
            if words.count > 2 { pids.insert(String(words[2])) }
        }
        return pids
    }

    static func agentCall(_ tool: String, _ arguments: [String: Any]) async -> (text: String, isError: Bool) {
        var result: MCPServer.CallResult?
        MCPControl.call(tool, arguments, caller: nil) { result = $0 }
        _ = await wait(10) { result != nil }
        return (result?.text ?? "(no answer)", result?.isError ?? true)
    }

    /// answer_agent with `answer` for the question the tab asks now.
    static func answerTab(_ tab: TerminalTab, _ answer: String) async -> (text: String, isError: Bool) {
        let arguments: [String: Any] = ["tab_id": tab.id.uuidString.lowercased(), "question_id": MCPControl.questionID(tab) ?? "",
                                        "answer": answer]
        return await agentCall("answer_agent", arguments)
    }

    static func prompt(_ tab: TerminalTab, _ text: String) async {
        _ = await agentCall("send_to_tab", ["tab_id": tab.id.uuidString.lowercased(), "text": text])
    }

    typealias SessionStarter = (URL, String, String) async -> TerminalTab?

    // MARK: Claude Code

    static func claudeChecks(_ a: TerminalTab, claudeLog: URL, session: SessionStarter, work: URL, sub: URL,
                             suite: UserDefaults) async {
        let trustTitle = "Trust this folder for Claude Code?"
        func log() -> [String] { standInLog(claudeLog) }
        func sessions() -> [String] { log().filter { $0.hasPrefix("session ") } }
        func answers(_ id: String) -> [String] { log().filter { $0.hasPrefix("answer " + id + " ") } }

        // AE4: the first session in a folder asks on the Mac; nothing typed answers it, and a decline runs nothing.
        let asked = await wait(15) { !approvals(trustTitle).isEmpty }
        let waiting = flatScreen(a).contains("Waiting for your OK on the Mac to trust this folder")
        a.view.send(txt: "y\r")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let typedNothing = !approvals(trustTitle).isEmpty && a.status.running && sessions().isEmpty
        check(asked && waiting && typedNothing, "claude session: the first session in a folder asks trust on the Mac, and y typed in the tab does nothing",
              "asked \(asked), waiting \(waiting), typed nothing \(typedNothing): \(flatScreen(a).suffix(300))")
        approvals(trustTitle).first?.declineButton.performClick(nil)
        let declined = await wait(10) { !a.status.running && flatScreen(a).contains("wasn\u{2019}t trusted on the Mac. Nothing ran.") }
        let untrusted = !AgentSessionTrust.isTrusted(work.path, in: AgentSessionTrust.list(in: suite))
        check(declined && untrusted && sessions().isEmpty && log().contains("version"),
              "claude session: declined on the Mac, the session ends with nothing run (only --version was read)",
              "\(log().suffix(4)): \(flatScreen(a).suffix(300))")

        // Trusted, it starts: the stand-in runs (not the user's claude), with its version, the model and the change since.
        guard let b = await session(work, "claude", "STANDIN_VERSION=2.1.4") else { return check(false, "claude session: a second tab starts") }
        let askedAgain = await wait(15) { !approvals(trustTitle).isEmpty }
        approvals(trustTitle).first?.approveButton.performClick(nil)
        let ready = await wait(15) { flatScreen(b).contains("Claude Code 2.1.4 (stand-in-model) is ready.") }
        let started = sessions().last ?? ""
        let flags = started.contains("\"--permission-prompt-tool\", \"stdio\"") && started.contains("\"--input-format\", \"stream-json\"")
        let mcp = started.contains("--mcp-config") && started.contains(MCPRegistrar.serverName)
        check(askedAgain && ready && sessions().count == 1 && flags && mcp && b.status.kind == .agent,
              "claude session: trusted on the Mac, the stand-in claude -p starts over stream-json with Next Term's MCP server, its version and model named",
              "\(started): \(flatScreen(b).suffix(300))")
        let updated = await wait(5) { flatScreen(b).contains("Claude Code updated 2.1.3 \u{2192} 2.1.4") }
        check(updated && (suite.dictionary(forKey: AgentSessionSocket.versionsKey) as? [String: String])?["claude"] == "2.1.4",
              "claude session: a version that differs from the last session's gets one line, and the app keeps the new one",
              flatScreen(b).suffix(300).description)

        // AE1: a streamed reply shown once, a tool call that ends done, Done; a second prompt in the same process.
        await prompt(b, "hello")
        let turned = await wait(10) { flatScreen(b).contains("Streamed reply to: hello") && flatScreen(b).contains("Bash(ls) \u{00B7} done") && b.status.state != .working }
        let shownOnce = flatScreen(b).components(separatedBy: "Streamed reply to: hello").count == 2
        check(turned && shownOnce && flatScreen(b).contains("Done"), "claude session: a turn shows the streamed reply once, the tool call done, and Done",
              flatScreen(b).suffix(400).description)
        await prompt(b, "hello again")
        let again = await wait(10) { flatScreen(b).contains("Streamed reply to: hello again") && b.status.state != .working }
        let pids = turnPIDs(log())
        check(again && pids.count == 1 && sessions().count == 1, "claude session: a second prompt runs in the same claude process",
              "\(log().suffix(4))")

        // AE2: a permission with no suggestions offers no Allow always; answer_agent's Reject denies with a message.
        await prompt(b, "please rm it")
        let asksRm = await wait(10) { b.status.state == .attention }
        let rmChoices = MCPControl.questionInfo(b)["choices"] as? [String] ?? []
        check(asksRm && b.status.question == "Do you want to allow: Bash(rm -rf build)?" && rmChoices == ["Allow once", "Reject"],
              "claude session: can_use_tool is the tab's question, with no Allow always when Claude offers no suggestion",
              "\(b.status.state.rawValue), \(b.status.question ?? "no question"), \(rmChoices)")
        let rejected = await answerTab(b, "Reject")
        let denied = await wait(10) { !answers("perm-rm").isEmpty && flatScreen(b).contains("Permission answer: deny") && b.status.state != .attention }
        let deny = answers("perm-rm").first ?? ""
        check(!rejected.isError && denied && deny.contains("\"behavior\": \"deny\"") && deny.contains("rejected"),
              "claude session: answer_agent picks Reject and Claude gets deny with a message", "\(rejected.text): \(deny)")

        // AE2: with a suggestion, Allow always is offered and asked on the Mac; declined there, nothing is sent.
        await prompt(b, "always make it")
        let asksAlways = await wait(10) { b.status.state == .attention }
        let alwaysChoices = MCPControl.questionInfo(b)["choices"] as? [String] ?? []
        check(asksAlways && alwaysChoices == ["Allow once", "Allow always", "Reject"],
              "claude session: with Claude's permission suggestions, Allow always is offered", "\(alwaysChoices)")
        let alwaysTitle = "Allow Claude Code always?"
        let firstAlways = await answerTab(b, "Allow always")
        let onMac = await wait(10) { !approvals(alwaysTitle).isEmpty }
        check(!firstAlways.isError && onMac && flatScreen(b).contains("Waiting for your OK on the Mac"),
              "claude session: Allow always from answer_agent asks the user on the Mac first", "\(firstAlways.text): \(flatScreen(b).suffix(300))")
        approvals(alwaysTitle).first?.declineButton.performClick(nil)
        let stillOpen = await wait(10) { flatScreen(b).contains("was declined on the Mac") && b.status.state == .attention }
        check(stillOpen && answers("perm-always").isEmpty, "claude session: declined on the Mac, Claude gets no answer and the request stays open",
              flatScreen(b).suffix(300).description)
        let secondAlways = await answerTab(b, "Allow always")
        let onMacAgain = await wait(10) { !approvals(alwaysTitle).isEmpty }
        approvals(alwaysTitle).first?.approveButton.performClick(nil)
        let allowed = await wait(10) { !answers("perm-always").isEmpty && b.status.state != .attention }
        let always = answers("perm-always").first ?? ""
        let kept = always.contains("\"destination\": \"session\"") && !always.contains("localSettings")
        check(!secondAlways.isError && onMacAgain && allowed && always.contains("\"behavior\": \"allow\"") && kept,
              "claude session: approved on the Mac, Allow always sends Claude's suggestion kept to this session", always)

        // AE7: AskUserQuestion's two questions, one menu each without the allow lead, answered in one response.
        await prompt(b, "ask me")
        let colour = await wait(10) { b.status.state == .attention && b.status.question == "Which color?" }
        let colours = MCPControl.questionInfo(b)["choices"] as? [String] ?? []
        check(colour && colours == ["Red", "Blue"] && !flatScreen(b).contains("allow: Which color"),
              "claude session: AskUserQuestion's first question is the tab's question in Claude's words, its options the choices",
              "\(b.status.question ?? "no question"), \(colours)")
        _ = await answerTab(b, "Blue")
        let size = await wait(10) { b.status.question == "Which size?" }
        let notYet = answers("perm-ask").isEmpty
        _ = await answerTab(b, "Large")
        let both = await wait(10) { !answers("perm-ask").isEmpty && flatScreen(b).contains("Answers:") && b.status.state != .attention }
        let reply = answers("perm-ask").first ?? ""
        let carried = reply.contains("\"Which color?\": \"Blue\"") && reply.contains("\"Which size?\": \"Large\"")
        check(size && notYet && both && answers("perm-ask").count == 1 && carried,
              "claude session: after the second answer, one control response carries both", reply)

        // AE8: ⌃C sends the interrupt control request; the turn says Stopped and the process stays up.
        await prompt(b, "wait a while")
        let busy = await wait(10) { flatScreen(b).contains("Working on it") && b.status.state == .working }
        b.view.send(txt: "\u{03}")
        let stopped = await wait(10) { log().contains("control interrupt") && b.status.state != .working && flatScreen(b).contains("Stopped") }
        await prompt(b, "hello once more")
        let afterStop = await wait(10) { flatScreen(b).contains("Streamed reply to: hello once more") }
        let samePids = turnPIDs(log())
        check(busy && stopped && afterStop && samePids.count == 1 && sessions().count == 1,
              "claude session: ⌃C sends the interrupt control request, the turn says Stopped, and the same process takes the next prompt",
              "\(log().suffix(5)): \(flatScreen(b).suffix(300))")
        b.view.send(txt: "\u{04}")
        let endedB = await wait(6) { !b.status.running }
        check(endedB, "claude session: ⌃D on an empty line ends the session", flatScreen(b).suffix(200).description)

        // AE4: the folder isn't asked again; --resume reaches claude.
        guard let resumed = await session(work, "claude --resume sess-old-1", "") else { return check(false, "claude session: a third tab starts") }
        var trustAsked = false
        let goesOn = await wait(15) {
            if !approvals(trustTitle).isEmpty { trustAsked = true }
            return flatScreen(resumed).contains("is ready, going on with session sess-old-1.")
        }
        let resumeArgs = sessions().last ?? ""
        check(goesOn && !trustAsked && resumeArgs.contains("\"--resume\", \"sess-old-1\"") && !flatScreen(resumed).contains("updated"),
              "claude session: a trusted folder isn't asked again, --resume reaches claude, and the same version gets no line",
              "\(resumeArgs): \(flatScreen(resumed).suffix(300))")
        resumed.view.send(txt: "\u{04}")
        _ = await wait(6) { !resumed.status.running }

        // AE4: a folder inside a trusted one is asked on its own.
        guard let inner = await session(sub, "claude", "") else { return check(false, "claude session: a tab in the subfolder starts") }
        let askedInner = await wait(15) { !approvals(trustTitle).isEmpty }
        approvals(trustTitle).first?.declineButton.performClick(nil)
        let endedInner = await wait(10) { !inner.status.running }
        check(askedInner && endedInner, "claude session: a folder inside a trusted one is asked on its own", flatScreen(inner).suffix(300).description)

        // AE6: not signed in, the session says how to sign in and ends.
        guard let unsigned = await session(work, "claude --prompt hi", "STANDIN_MODE=auth") else { return check(false, "claude session: the sign-in tab starts") }
        let signIn = await wait(15) { !unsigned.status.running && flatScreen(unsigned).contains(ClaudeStream.signInLine) }
        check(signIn, "claude session: an account that isn't signed in ends the session with the sign-in line", flatScreen(unsigned).suffix(300).description)
    }

    // MARK: Codex

    static func codexChecks(codexLog: URL, session: SessionStarter, work: URL) async {
        func log() -> [String] { standInLog(codexLog) }
        func answered(_ decision: String) -> Bool { log().contains { $0.hasPrefix("answer ") && $0.hasSuffix(" " + decision) } }

        // A resume Codex can't do starts a new thread, said so; the thread asks before acting and has Next Term's MCP server.
        guard let x = await session(work, "codex --resume thr-old-1", "") else { return check(false, "codex session: the tab starts its shell") }
        let ready = await wait(15) { flatScreen(x).contains("Codex 0.154.0 (stand-in-codex) is ready.") }
        let fellBack = flatScreen(x).contains("Codex couldn\u{2019}t go on with thread thr-old-1")
        let thread = log().first { $0.hasPrefix("thread ") } ?? ""
        let shaped = thread.contains("\"approvalPolicy\": \"on-request\"") && thread.contains(MCPRegistrar.serverName)
        check(ready && fellBack && log().contains("request thread/resume") && shaped && x.status.kind == .agent,
              "codex session: the stand-in app-server starts; a resume it can't do falls back to a new thread, asking before acting, with Next Term's MCP server",
              "\(thread): \(flatScreen(x).suffix(300))")

        await prompt(x, "hello")
        let turned = await wait(10) { flatScreen(x).contains("Codex says: hello") && flatScreen(x).contains("ls \u{00B7} done") && x.status.state != .working }
        check(turned && flatScreen(x).contains("Done"), "codex session: a turn shows the reply, the command done, and Done", flatScreen(x).suffix(300).description)

        // AE3: command approval; Allow once sends accept, Reject sends decline.
        await prompt(x, "run the tests")
        let asks = await wait(10) { x.status.state == .attention }
        let choices = MCPControl.questionInfo(x)["choices"] as? [String] ?? []
        check(asks && x.status.question == "Do you want to allow: make test?" && choices == ["Allow once", "Allow always", "Reject"],
              "codex session: a command approval is the tab's question, with Allow once, Allow always and Reject",
              "\(x.status.question ?? "no question"), \(choices)")
        let once = await answerTab(x, "Allow once")
        let accepted = await wait(10) { answered("accept") && flatScreen(x).contains("Approval: accept") && x.status.state != .attention }
        check(!once.isError && accepted, "codex session: Allow once sends accept", "\(once.text): \(log().suffix(3))")
        await prompt(x, "run them again")
        _ = await wait(10) { x.status.state == .attention }
        let reject = await answerTab(x, "Reject")
        let declined = await wait(10) { answered("decline") && flatScreen(x).contains("Approval: decline") && x.status.state != .attention }
        check(!reject.isError && declined, "codex session: Reject sends decline", "\(reject.text): \(log().suffix(3))")

        // R9: a request Next Term doesn't take gets -32601 and a note, so Codex never waits on it.
        await prompt(x, "other request")
        let refused = await wait(10) {
            log().contains { $0.hasPrefix("answer ") && $0.hasSuffix(" error -32601") } && x.status.state != .working
        }
        check(refused && flatScreen(x).contains("Codex asked for item/tool/requestUserInput"),
              "codex session: another server request is answered method-not-found, with a note", flatScreen(x).suffix(300).description)

        // AE3: ⌃C sends turn/interrupt and the turn says Stopped.
        await prompt(x, "wait a while")
        let busy = await wait(10) { flatScreen(x).contains("Working on it") && x.status.state == .working }
        x.view.send(txt: "\u{03}")
        let stopped = await wait(10) { log().contains("interrupt") && x.status.state != .working && flatScreen(x).contains("Stopped") }
        check(busy && stopped, "codex session: ⌃C sends turn/interrupt and the turn says Stopped", "\(log().suffix(3)): \(flatScreen(x).suffix(300))")
        x.view.send(txt: "\u{04}")
        _ = await wait(6) { !x.status.running }

        // AE5: an initialize answer in a shape Next Term doesn't know ends the session with the note, never a hang.
        guard let drifted = await session(work, "codex", "STANDIN_MODE=drift") else { return check(false, "codex session: the drift tab starts") }
        let noted = await wait(15) { !drifted.status.running && flatScreen(drifted).contains(CodexAppServer.driftLead) }
        check(noted, "codex session: a changed app-server ends the session with the note", flatScreen(drifted).suffix(300).description)

        // AE6: no account, the session says how to sign in and ends.
        guard let unsigned = await session(work, "codex", "STANDIN_MODE=nologin") else { return check(false, "codex session: the sign-in tab starts") }
        let signIn = await wait(15) { !unsigned.status.running && flatScreen(unsigned).contains(CodexAppServer.signInLine) }
        check(signIn, "codex session: no account ends the session with the codex login line", flatScreen(unsigned).suffix(300).description)
    }
}
#endif
