import AppKit
import CryptoKit
import Darwin
import NextTermCore

/// herdr's agents one by one, against the stand-in ssh (SelfTestRemote) and a stand-in herdr that logs every call it gets:
/// a row per agent with herdr's own names and titles, its click and Go to Agent… moving herdr's view, decisions told on
/// the second check, notices per agent that go once answered and carry the question's choices, the Dock badge and
/// menu, Go to Next Agent Needing You, Peek, the tab tools on an agent's id over MCP, herdr's sessions, an older herdr's
/// verbs, a host with no herdr tab, a drop copied to the host, herdr run in a tab on this Mac with the machines saved in
/// it, and the focus reports herdr's screen gets. Never a real herdr: the stand-in answers from files in the test's
/// folder.
extension SelfTest {
    #if DEBUG
    /// The stand-in herdr at `path`, with its files in `base`: herdr-agents (agent list), herdr-tabs (tab list),
    /// herdr-sessions (session list --json), herdr-read (any read; herdr-read-next takes its place at the next keys, as an
    /// agent's screen moves), herdr-explain (agent explain), herdr-machines (machine list), herdr-machine-agents (agent
    /// list on a machine), and herdr-old (no agent verbs, as herdr before 0.7.5). Each call goes to herdr-calls with the
    /// socket it was given; with no verb it is herdr's screen until `q`, which turns focus reports on and keeps every byte
    /// it gets in herdr-screen-input.
    static func herdrStandIn(at path: URL, base: URL) {
        let file = { (name: String) in RemoteShell.quote(base.appendingPathComponent(name).path) }
        let body = """
            #!/bin/sh
            printf '%s|%s\\n' "$*" "${HERDR_SOCKET_PATH:-}" >> \(file("herdr-calls"))
            m=
            case "$1" in
              --session) shift 2 ;;
              --machine) m=$2; shift 2 ;;
            esac
            if [ $# -eq 0 ] || [ "$1 $2" = 'session attach' ]; then
              printf '\\033[?1004h'
              printf 'herdr stand-in\\r\\n'
              stty -icanon -echo min 1 time 0 2>/dev/null
              while c=$(dd bs=1 count=1 2>/dev/null); [ "$c" != q ]; do
                printf '%s' "$c" >> \(file("herdr-screen-input"))
              done
              exit 0
            fi
            if [ -e \(file("herdr-old")) ]; then
              case "$1 $2" in
                '--version '*) echo 'herdr 0.7.0'; exit 0 ;;
                'agent list') ;;
                agent*) echo "error: unrecognized subcommand '$2'" >&2; exit 2 ;;
              esac
              case "$*" in *--source*) echo "error: unexpected argument '--source' found" >&2; exit 2 ;; esac
            fi
            case "$1 $2" in
              '--version '*) echo 'herdr 0.9.5' ;;
              'agent list') if [ -n "$m" ]; then cat \(file("herdr-machine-agents")); else cat \(file("herdr-agents")); fi ;;
              'tab list') cat \(file("herdr-tabs")) ;;
              'session list') cat \(file("herdr-sessions")) ;;
              'machine list') cat \(file("herdr-machines")) ;;
              'agent explain') cat \(file("herdr-explain")) ;;
              'agent read'|'pane read') cat \(file("herdr-read")) ;;
              'agent send-keys') [ -e \(file("herdr-read-next")) ] && mv -f \(file("herdr-read-next")) \(file("herdr-read")) ;;
              'agent focus') echo '{"id":"cli:agent:focus","result":{"type":"agent_info"}}' ;;
            esac
            exit 0
            """
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? body.write(to: path, atomically: true, encoding: .utf8)
        chmod(path.path, 0o755)
    }

    /// herdr's list as the stand-in gives it: claude in w1:p1 (herdr's focus, in w1:t1; a naming plugin's name and title
    /// on it) and codex in w2:p1, in `codex`'s state, with herdr's change count `seq`.
    static func standInAgents(codex: String, claude: String = "working", seq: Int = 4) -> String {
        let session = #""agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"6f1c2a"}"#
        let claudeAgent = #"{"terminal_id":"t1","agent":"claude","display_agent":"Claude: auth","title":"Refactor auth","terminal_title":"✳ Claude Code","terminal_title_stripped":"Claude Code","agent_status":"\#(claude)",\#(session),"workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","focused":true,"state_change_seq":9,"cwd":"/srv/api","revision":3}"#
        let codexAgent = #"{"terminal_id":"t4","agent":"codex","terminal_title_stripped":"Fix login","agent_status":"\#(codex)","workspace_id":"w2","tab_id":"w2:t1","pane_id":"w2:p1","focused":false,"state_change_seq":\#(seq),"cwd":"/srv/web","revision":7}"#
        return #"{"id":"cli:agent:list","result":{"type":"agent_list","agents":[\#(claudeAgent),\#(codexAgent)]}}"#
    }

    /// One MCP call, in the app, as `nxtrm mcp` would make it; `herdr`: what the bridge says of the caller's herdr pane.
    static func herdrTool(_ name: String, _ arguments: [String: Any],
                          herdr: [String: String] = [:]) async -> (json: [String: Any]?, text: String, isError: Bool) {
        let result = await withCheckedContinuation { (done: CheckedContinuation<MCPServer.CallResult, Never>) in
            MCPControl.call(name, arguments, caller: nil, herdrCaller: herdr) { done.resume(returning: $0) }
        }
        return ((try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any], result.text, result.isError)
    }

    /// Go to Agent's items, its alternates and headings left out.
    static func agentItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { $0.representedObject != nil && !$0.isAlternate && $0.submenu == nil }
    }

    static func herdrAgentChecks(_ c: TerminalWindowController, host saved: RemoteHost, base: URL, home: URL, bin: URL,
                                 flag: (String, Bool) -> Void) async {
        let calls = base.appendingPathComponent("herdr-calls")
        let read = { (try? String(contentsOf: calls, encoding: .utf8)) ?? "" }
        func write(_ name: String, _ text: String) { try? text.write(to: base.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        func clearCalls() { unlink(calls.path) }
        let herdr = bin.appendingPathComponent("herdr")
        let pgrep = bin.appendingPathComponent("pgrep")
        try? "#!/bin/sh\nexit 1\n".write(to: pgrep, atomically: true, encoding: .utf8)
        chmod(pgrep.path, 0o755)
        herdrStandIn(at: herdr, base: base)
        write("herdr-agents", standInAgents(codex: "working"))
        write("herdr-tabs", #"{"result":{"type":"tab_list","tabs":[{"tab_id":"w1:t1","workspace_id":"w1","focused":true},{"tab_id":"w2:t1","workspace_id":"w2","focused":false}]}}"#)
        write("herdr-sessions", #"{"sessions":[{"name":"default","default":true,"running":true},{"name":"review","default":false,"running":true}]}"#)
        write("herdr-read", "• Cleaning the build folder.\n\n  Allow rm -rf build? (y/n)\n")
        write("herdr-explain", #"{"agent":"codex","state":"blocked","manifest_source":"builtin","manifest_version":"2026.10.2","matched_rule":{"id":"codex.approval","priority":90,"region":"bottom","state":"blocked"},"warning":null}"#)
        flag("loginsh", true)
        let names = ["herdr-agents", "herdr-tabs", "herdr-sessions", "herdr-read", "herdr-read-next", "herdr-old", "herdr-calls",
                     "herdr-explain", "herdr-machines", "herdr-machine-agents", "herdr-screen-input"]
        defer {
            flag("loginsh", false)
            for name in names { unlink(base.appendingPathComponent(name).path) }
            unlink(herdr.path)
            unlink(pgrep.path)
        }
        var host = saved
        host.keep = .herdr
        RemoteHosts.save(host)
        let app: AppDelegate = AppDelegate.shared

        // Two agents, a row each under the tab, with herdr's own names and titles and its states.
        let tab = c.addRemoteTab(RemoteTab(host: host, keep: .herdr))
        let followed = await wait(20) { tab.followsHerdr && tab.herdrRows.count == 2 }
        check(followed && tab.herdrRows.map(\.name) == ["Claude: auth", "codex"] && tab.herdrRows.map(\.state) == [.working, .working],
              "herdr agents: a row per agent under the tab, with herdr's names and states", "\(tab.herdrRows)")
        check(tab.herdrRows.first?.title == "Refactor auth" && tab.herdrRows.last?.title == "Fix login",
              "herdr agents: a row has herdr's own title for its agent, else its terminal's", "\(tab.herdrRows.map(\.title))")

        // Clicking codex's row moves herdr's view to its pane; Go to Agent… is ⌃⌘A.
        clearCalls()
        let codexRow = "pane \(tab.id.uuidString)/herdr/w2:p1"
        if let index = c.groups.firstIndex(where: { $0.contains(tab) }) {
            c.tabList(c.tabList, didSelectAgent: "w2:p1", rowKey: codexRow, of: index)
        }
        check(await wait(10) { read().contains("agent focus w2:p1|") }, "herdr agents: clicking a row runs herdr's agent focus on it", read())
        let windowMenu = NSApp.mainMenu?.items.first { $0.title == "Window" }?.submenu
        let item = windowMenu?.items.first { $0.action == #selector(TerminalWindowController.goToAgent(_:)) }
        check(item?.keyEquivalent == "a" && item?.keyEquivalentModifierMask == [.command, .control] && c.validateMenuItem(item ?? NSMenuItem()),
              "herdr agents: Window › Go to Agent… is ⌃⌘A, on while agents are known")
        let next = windowMenu?.items.first { $0.action == #selector(TerminalWindowController.goToNextAgentNeedingYou(_:)) }
        check(next?.keyEquivalent == "n" && next?.keyEquivalentModifierMask == [.command, .control],
              "herdr agents: Window › Go to Next Agent Needing You is ⌃⌘N")

        // A blocked of one check posts nothing; of two, one notice with the question read from its pane, with its choices.
        let other = c.addTab(directory: base.path) // herdr's tab off screen: its agents' notices are the user's news
        defer { c.remove(other) }
        let before = app.testNotifications.count
        write("herdr-agents", standInAgents(codex: "blocked", seq: 5))
        _ = await wait(6) { tab.herdrTracker.agents.last?.status == .blocked }
        write("herdr-agents", standInAgents(codex: "working", seq: 6))
        _ = await wait(6) { tab.herdrTracker.agents.last?.status == .working }
        await pause(2.5)
        let flicker = app.testNotifications.dropFirst(before).filter { $0.content.userInfo["herdr_pane"] as? String == "w2:p1" }
        check(flicker.isEmpty, "herdr agents: a blocked that lasts one check posts no notice", flicker.map(\.content.title).joined(separator: "; "))
        write("herdr-agents", standInAgents(codex: "blocked", seq: 7))
        let asked = await wait(15) { tab.herdrTracker.question("w2:p1")?.text == "Allow rm -rf build?" }
        check(asked, "herdr agents: a blocked agent's question is read from its own pane", "\(tab.herdrTracker.question("w2:p1") as Any)")
        let notice = await wait(10) { app.testNotifications.contains { $0.content.userInfo["herdr_pane"] as? String == "w2:p1" } }
        let posted = app.testNotifications.filter { $0.content.userInfo["herdr_pane"] as? String == "w2:p1" }
        let content = posted.first?.content
        check(notice && posted.count == 1 && content?.body == "Allow rm -rf build?" && content?.title == "codex needs your decision",
              "herdr agents: on the second blocked check, one notice for the agent, with its question", posted.map(\.content.title).joined(separator: "; "))
        let category = content?.categoryIdentifier ?? ""
        check(app.noticeActions[category]?.map(\.title) == ["1 Yes", "2 No"] && content?.userInfo["question_id"] as? String != nil,
              "herdr agents: the decision notice carries the question's choices as buttons", "\(app.noticeActions[category] ?? [])")
        check(tab.status.question == "codex: Allow rm -rf build?", "herdr agents: the tab's question is the agent's own, named", tab.status.question ?? "none")
        check(tab.herdrTracker.needsYou.contains("w2:p1"), "herdr agents: the agent needing a decision counts toward the badge", "\(tab.herdrTracker.needsYou)")

        // The queue: Needs You first, a digit each, the time it has waited; ⌃⌘N and the Dock menu go to the same one.
        let menu = HerdrAgentMenu.menu()
        let titles = agentItems(menu).map(\.title)
        check(titles.first?.hasPrefix("codex — Needs your decision") == true && titles.count == 2 && agentItems(menu).first?.keyEquivalent == "1",
              "herdr agents: Go to Agent… lists the agents, the one needing you first, with digits", titles.joined(separator: "; "))
        check(menu.items.contains { $0.isAlternate && $0.title.hasPrefix("Peek at codex") }, "herdr agents: ⌥ turns each item into Peek")
        let waited = HerdrAgentMenu.queue().needsYou.first
        check(waited?.menuTitle(now: (waited?.needsSince ?? 0) + 70).hasSuffix("waiting 1 min") == true,
              "herdr agents: an item says how long its agent has waited", waited?.menuTitle(now: (waited?.needsSince ?? 0) + 70) ?? "none")
        let dock = app.applicationDockMenu(NSApp)?.items.map(\.title) ?? []
        check(dock.first == "codex — \(host.name) — Needs your decision", "herdr agents: the Dock menu lists what needs you first", dock.joined(separator: "; "))
        clearCalls()
        HerdrAgentMenu.goToNext()
        check(await wait(10) { read().contains("agent focus w2:p1|") }, "herdr agents: ⌃⌘N goes to the agent that has waited longest", read())
        c.show(other)

        // Answering from the notice: the second choice, through a read before the keys and one before Return.
        write("herdr-read-next", "  Allow rm -rf build? (y/n) n\n")
        clearCalls()
        if let request = posted.first {
            var info: [String: String] = [:]
            for (key, value) in request.content.userInfo { if let key = key as? String, let value = value as? String { info[key] = value } }
            app.respond(to: request.identifier, title: request.content.title, info: info, action: "choice.2", text: nil)
        }
        check(await wait(10) { read().contains("agent send-keys w2:p1 n|") }, "herdr notices: a choice's button answers it through herdr, after a read",
              read())
        // Once codex works again, its notice goes.
        write("herdr-agents", standInAgents(codex: "working", seq: 8))
        check(await wait(10) { !app.testNotifications.contains { $0.content.userInfo["herdr_pane"] as? String == "w2:p1" } },
              "herdr notices: a decision's notice is withdrawn once the agent works again")

        // MCP: list_tabs gives each agent's id and fields; read_tab, send_to_tab and press_keys reach that pane through herdr.
        write("herdr-read", "Do you want to run npm test?\n❯ 1. Yes\n  2. No, and tell Codex what to do differently (esc)\n")
        write("herdr-agents", standInAgents(codex: "blocked", seq: 9))
        _ = await wait(15) { tab.herdrTracker.question("w2:p1")?.text == "Do you want to run npm test?" }
        let id = HerdrTarget(tabID: tab.id.uuidString, pane: "w2:p1").id
        let listed = await herdrTool("list_tabs", [:])
        let windows = listed.json?["windows"] as? [[String: Any]] ?? []
        let entries = windows.flatMap { ($0["tabs"] as? [[String: Any]]) ?? [] }.compactMap { $0["herdr_agents"] as? [[String: Any]] }.joined()
        let codex = entries.first { $0["pane"] as? String == "w2:p1" }
        let claude = entries.first { $0["pane"] as? String == "w1:p1" }
        check(codex?["id"] as? String == id && codex?["state"] as? String == "blocked" && codex?["agent"] as? String == "codex"
              && (codex?["choices"] as? [String])?.count == 2 && codex?["question_id"] as? String != nil && codex?["tab"] as? String == "w2:t1"
              && codex?["waiting_seconds"] as? Int != nil,
              "herdr MCP: list_tabs gives each agent its id, its fields, its question and how long it has waited", "\(codex ?? [:])")
        check(claude?["name"] as? String == "Claude: auth" && claude?["agent"] as? String == "claude",
              "herdr MCP: an agent's name is herdr's, its agent the kind that runs", "\(claude ?? [:])")
        let question = tab.herdrTracker.question("w2:p1").map { HerdrMCP.questionID($0, pane: "w2:p1", in: tab) } ?? ""
        clearCalls()
        write("herdr-read-next", "Do you want to run npm test?\n  1. Yes\n❯ 2. No, and tell Codex what to do differently (esc)\n")
        let answered = await herdrTool("answer_agent", ["tab_id": id, "question_id": question, "choice": 2])
        check(!answered.isError && read().contains("agent send-keys w2:p1 down|") && read().contains("agent send-keys w2:p1 enter|"),
              "herdr MCP: answer_agent moves to the choice and presses Return through herdr", answered.text + " | " + read())
        write("herdr-read", "• Working (2s • esc to interrupt)\n")
        let again = await herdrTool("answer_agent", ["tab_id": id, "question_id": question, "choice": 1])
        check(again.isError, "herdr MCP: a second answer to the same question is refused", again.text)
        write("herdr-agents", standInAgents(codex: "working", seq: 10))
        _ = await wait(10) { tab.herdrTracker.agents.last?.status == .working }
        write("herdr-read", "> run the tests\n⏺ All 42 tests pass.\n")
        let screen = await herdrTool("read_tab", ["tab_id": id, "lines": 20])
        check(!screen.isError && (screen.json?["screen"] as? String)?.contains("All 42 tests pass") == true,
              "herdr MCP: read_tab on an agent's id reads its pane", screen.text)
        clearCalls()
        let prompted = await herdrTool("send_to_tab", ["tab_id": id, "text": "run the tests"])
        check(!prompted.isError && read().contains("agent prompt w2:p1 run the tests|"),
              "herdr MCP: send_to_tab prompts the agent through herdr, its text on the script's stdin", read())
        check(HerdrMCP.isDriven(id) && !HerdrMCP.isDriven(HerdrTarget(tabID: tab.id.uuidString, pane: "w1:p1").id),
              "herdr MCP: typing into an agent drives that agent, not its herdr neighbours")
        let keys = await herdrTool("press_keys", ["tab_id": id, "keys": ["escape"]])
        check(!keys.isError && read().contains("agent send-keys w2:p1 esc|"), "herdr MCP: press_keys sends herdr's key names", read())
        // A stored key's value (a mask of the test's own, put back after): refused, and herdr is asked nothing.
        let value = "Rk7vQp2xLm9nWz4cTb8hYq3sJ6dF"
        let key = SymmetricKey(size: .bits256)
        let mask = SecretMask.current
        SecretMask.current = SecretMask(key: key, marks: SecretMask.marks(for: SecretBytes(utf8: value), key: key))
        clearCalls()
        let secret = await herdrTool("send_to_tab", ["tab_id": id, "text": "use \(value)"])
        SecretMask.current = mask
        check(secret.isError && !read().contains("prompt"), "herdr MCP: text holding a stored key is refused, and nothing is sent", secret.text)

        // focus_tab asks first: Decline sends nothing, Approve runs agent focus. show_tab moves nothing in herdr.
        for approve in [false, true] {
            clearCalls()
            let call = Task { await herdrTool("focus_tab", ["tab_id": id]) }
            _ = await wait(20) { MCPWriteControl.pending?.window != nil }
            let window = MCPWriteControl.pending?.window
            check(window != nil, "herdr MCP: focus_tab on an agent asks on the Mac first")
            if approve { window?.approveButton.performClick(nil) } else { window?.declineButton.performClick(nil) }
            let result = await call.value
            let focused = read().contains("agent focus w2:p1|")
            check(approve ? (!result.isError && focused) : (result.isError && !focused),
                  approve ? "herdr MCP: focus_tab, approved, moves herdr's view to the agent" : "herdr MCP: focus_tab, declined, sends herdr nothing", result.text)
        }
        c.show(other)
        clearCalls()
        let shown = await herdrTool("show_tab", ["tab_id": id])
        check(!shown.isError && !read().contains("focus"), "herdr MCP: show_tab shows the herdr tab and leaves herdr's view", shown.text)
        let closed = await herdrTool("close_tab", ["tab_id": id])
        let split = await herdrTool("split_pane", ["tab_id": id])
        check(closed.isError && split.isError && c.tabs.contains { $0 === tab }, "herdr MCP: close_tab and split_pane refuse an agent's id",
              closed.text + " | " + split.text)
        c.show(other)
        let waiting = Task { await herdrTool("wait_for_tab", ["tab_id": id, "timeout_seconds": 20]) }
        await pause(1)
        write("herdr-agents", standInAgents(codex: "idle", seq: 11))
        let stopped = await waiting.value
        check(stopped.json?["state"] as? String == "idle" && stopped.json?["timed_out"] as? Bool == false,
              "herdr MCP: wait_for_tab on an agent returns once herdr says it stopped", stopped.text)

        // A finish while the tab is off screen: claude works, then reads idle. One notice, and Next Term keeps it unread.
        let finishes = app.testNotifications.count
        write("herdr-agents", standInAgents(codex: "idle", claude: "working", seq: 11))
        await pause(6.5)
        write("herdr-agents", standInAgents(codex: "idle", claude: "idle", seq: 11))
        let finished = await wait(10) { app.testNotifications.dropFirst(finishes).contains { $0.content.userInfo["herdr_pane"] as? String == "w1:p1" } }
        check(finished && tab.herdrTracker.isUnread("w1:p1") && tab.herdrRows.first?.state == .done,
              "herdr agents: a turn that ends as idle off screen is a finish, kept unread", "\(tab.herdrRows.first as Any)")
        let finishNotice = app.testNotifications.last { $0.content.userInfo["herdr_pane"] as? String == "w1:p1" }
        check(finishNotice?.content.categoryIdentifier == NoticeActions.finishCategory, "herdr notices: a finish carries Reply")
        clearCalls()
        if let finishNotice {
            app.respond(to: finishNotice.identifier, title: finishNotice.content.title, info: ["tab": tab.id.uuidString, "herdr_pane": "w1:p1"],
                        action: NoticeActions.reply, text: "run the linter")
        }
        check(await wait(10) { read().contains("agent prompt w1:p1 run the linter|") }, "herdr notices: Reply prompts the agent through herdr", read())
        check(await wait(5) { !tab.herdrTracker.isUnread("w1:p1") }, "herdr notices: and marks it seen")
        // Muted: no notice, still in the badge.
        if let index = c.groups.firstIndex(where: { $0.contains(tab) }) {
            let rowMenu = c.tabList(c.tabList, menuForAgent: "w2:p1", rowKey: codexRow, of: index)
            if let mute = rowMenu?.items.first(where: { $0.title == "Mute Notices" }) { HerdrAgentMenu.Target.shared.mute(mute) }
        }
        check(tab.herdrTracker.isMuted("w2:p1"), "herdr agents: Mute Notices on a row mutes that agent")
        let muted = app.testNotifications.count
        write("herdr-agents", standInAgents(codex: "blocked", claude: "idle", seq: 12))
        _ = await wait(10) { tab.herdrTracker.needsYou.contains("w2:p1") }
        await pause(3)
        check(app.testNotifications.count == muted && tab.herdrTracker.needsYou.contains("w2:p1"),
              "herdr agents: a muted agent posts nothing and still counts in the badge")
        tab.muteHerdr("w2:p1", false)

        // Peek: the agent's recent text, its question's buttons, a line sent as herdr's prompt; herdr's view does not move.
        write("herdr-read", "Allow rm -rf build? (y/n)\n")
        _ = await wait(10) { tab.herdrTracker.question("w2:p1") != nil }
        clearCalls()
        AgentPeek.show(tab, pane: "w2:p1")
        let peek = AgentPeek.current
        check(await wait(10) { peek?.shownText.contains("Allow rm -rf build?") == true && peek?.shownChoices.count == 2 },
              "Peek: an agent's recent text and its question's buttons", "\(peek?.shownText ?? "no Peek") \(peek?.shownChoices ?? [])")
        peek?.explain()
        check(await wait(10) { peek?.shownText.contains("rule: codex.approval (region bottom, priority 90)") == true } && read().contains("agent explain w2:p1 --json|"),
              "Peek: Why This State? shows herdr's own agent explain", peek?.shownText ?? "")
        peek?.showScreen()
        write("herdr-agents", standInAgents(codex: "working", claude: "idle", seq: 13))
        _ = await wait(10) { tab.herdrTracker.agents.last?.status == .working }
        peek?.send(line: "use make clean instead")
        check(await wait(10) { read().contains("agent prompt w2:p1 use make clean instead|") } && !read().contains("agent focus"),
              "Peek: a line sent goes as herdr's prompt, and herdr's view does not move", read())
        peek?.close()
        // The Conversation: claude's transcript at the path its agent_session names, on the host.
        let transcript = home.appendingPathComponent(".claude/projects/-srv-api/6f1c2a.jsonl")
        try? FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        let turns = """
            {"type":"user","message":{"role":"user","content":"partial line"}}
            {"type":"user","message":{"role":"user","content":"Refactor the auth middleware"}}
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done: the middleware is split."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}

            """
        try? turns.write(to: transcript, atomically: true, encoding: .utf8)
        AgentPeek.show(tab, pane: "w1:p1")
        AgentPeek.current?.showConversation()
        check(await wait(10) { AgentPeek.current?.shownText.contains("You: Refactor the auth middleware") == true },
              "Peek: ⌘2 shows the conversation from the transcript herdr names", AgentPeek.current?.shownText ?? "")
        AgentPeek.current?.close()
        AgentPeek.show(tab, pane: "w2:p1")
        check(await wait(10) { AgentPeek.current?.shownNote.contains("herdr names no session for this agent") == true },
              "Peek: an agent with no session shows its screen, and says why", AgentPeek.current?.shownNote ?? "")
        AgentPeek.current?.showScreen()
        AgentPeek.current?.close()

        // An older herdr: read_tab falls back to pane read.
        write("herdr-old", "")
        clearCalls()
        let old = await herdrTool("read_tab", ["tab_id": id])
        check(!old.isError && read().contains("pane read w2:p1|"), "herdr MCP: on an older herdr, read_tab falls back to pane read", read())
        unlink(base.appendingPathComponent("herdr-old").path)

        // Sessions: new_remote_tab opens one herdr lists, and refuses another; host_sessions lists them.
        clearCalls()
        let review = await herdrTool("new_remote_tab", ["host": host.name, "keep": "herdr", "session": "review"])
        let reviewTab = c.tabs.first { $0.id.uuidString.lowercased() == (review.json?["id"] as? String ?? "") }
        check(await wait(20) { read().contains("--session review|") } && reviewTab?.remote?.herdrSession == "review",
              "herdr sessions: new_remote_tab with session opens that herdr session", review.text + " | " + read())
        check(await wait(10) { reviewTab?.herdrRows.isEmpty == false }, "herdr sessions: its agents are followed as the default session's are")
        if let reviewTab { c.remove(reviewTab) }
        let unlisted = await herdrTool("new_remote_tab", ["host": host.name, "keep": "herdr", "session": "nope"])
        check(unlisted.isError && unlisted.text.contains("lists no session"), "herdr sessions: a session herdr does not list is refused", unlisted.text)
        let sessions = await herdrTool("host_sessions", ["host": host.name])
        let named = (sessions.json?["herdr_sessions"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        check(named == ["default", "review"], "herdr sessions: host_sessions lists herdr's sessions", sessions.text)

        // A drop on a remote tab is copied to the host first, and its path there typed in.
        let dropped = base.appendingPathComponent("drop/shot.png")
        try? FileManager.default.createDirectory(at: dropped.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: dropped)
        let plain = c.addRemoteTab(RemoteTab(host: host, keep: .off))
        _ = await wait(20) { plain.remoteReady }
        RemoteDrop.drop([dropped], into: plain)
        check(await wait(15) { plain.screenTail(6).joined().contains("next-term-drop.") && plain.screenTail(6).joined().contains("shot.png") },
              "remote drops: a drop is copied to the host, and its path there pasted", plain.screenTail(6).joined(separator: " | "))

        // No herdr tab on the host any more: its agents are still in Go to Agent, under "(no herdr tab)".
        c.remove(tab)
        write("herdr-agents", standInAgents(codex: "blocked", claude: "idle", seq: 14))
        let overview = await wait(15) { HerdrAgentMenu.queue().items.contains { $0.group == AgentQueue.noHerdrTab(host.name) } }
        check(overview, "herdr hosts: a connected herdr host with no herdr tab lists its agents in Go to Agent",
              HerdrAgentMenu.queue().items.map(\.group).joined(separator: "; "))
        clearCalls()
        if let agent = HerdrAgentMenu.queue().items.first(where: { $0.target == .host(id: host.id, pane: "w2:p1") }) {
            HerdrAgentMenu.go(to: agent.target)
        }
        check(await wait(25) { read().contains("agent focus w2:p1|") }, "herdr hosts: choosing one opens a herdr tab there, on its pane", read())
        for opened in c.tabs where opened.remote?.keep == .herdr { c.remove(opened) }
        c.remove(plain)
    }

    /// herdr run in a tab on this Mac: the tab follows its agents through the client's own herdr and socket, and the
    /// machines saved in it through `--machine`; its screen hears when the tab loses the focus; ending it posts no notice
    /// and stops every read.
    static func localHerdrChecks(_ c: TerminalWindowController, base: URL) async {
        let script = base.appendingPathComponent("local/herdr")
        herdrStandIn(at: script, base: base)
        let calls = base.appendingPathComponent("herdr-calls")
        let input = base.appendingPathComponent("herdr-screen-input")
        func write(_ name: String, _ text: String) { try? text.write(to: base.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        write("herdr-agents", standInAgents(codex: "working"))
        write("herdr-machines", #"[{"id":"m1","label":"Build machine","target":"me@build.example.internal","session":"default","enabled":true,"selected":false}]"#)
        write("herdr-machine-agents", #"{"result":{"agents":[{"pane_id":"w1:p1","agent":"codex","agent_status":"blocked","state_change_seq":2,"tab_id":"w1:t1"}]}}"#)
        write("herdr-read", "Allow rm -rf build? (y/n)\n")
        defer {
            unlink(script.path)
            for name in ["herdr-calls", "herdr-agents", "herdr-machines", "herdr-machine-agents", "herdr-read", "herdr-screen-input"] {
                unlink(base.appendingPathComponent(name).path)
            }
        }
        let tab = c.addTab(directory: base.path)
        defer { c.remove(tab) }
        _ = await wait(10) { tab.status.integrated }
        let socket = base.appendingPathComponent("standin.sock").path
        tab.runWhenReady("HERDR_SOCKET_PATH=\(ShellQuote.quote(socket)) \(ShellQuote.quote(script.path))")
        let rows = await wait(8) { tab.localHerdr != nil && tab.herdrRows.count == 2 }
        check(rows && tab.status.hostsAgents, "herdr on this Mac: a local tab running herdr follows its agents, a row each",
              "\(tab.localHerdr as Any) \(tab.herdrRows)")
        let said = { (try? String(contentsOf: calls, encoding: .utf8)) ?? "" }
        check(said().contains("agent list|\(socket)"), "herdr on this Mac: its herdr is asked with the client's own socket", said())

        // Focus reports: another tab chosen tells herdr's screen focus left (CSI O); back, it came (CSI I); once each.
        let other = c.addTab(directory: base.path)
        let screenInput = { (try? String(contentsOf: input, encoding: .isoLatin1)) ?? "" }
        check(await wait(5) { screenInput().contains("\u{1b}[O") }, "focus reports: herdr's screen hears that the focus left when another tab is chosen",
              screenInput().debugDescription)
        c.show(tab)
        check(await wait(5) { screenInput().hasSuffix("\u{1b}[I") }, "focus reports: and that it came back", screenInput().debugDescription)
        check(screenInput().components(separatedBy: "\u{1b}[O").count == 2, "focus reports: each change is said once", screenInput().debugDescription)
        c.remove(other)

        // herdr's own machines: read through --machine, never with --session; their agents in Go to Agent, peeked at.
        let machine = await wait(15) { HerdrAgentMenu.queue().items.contains { $0.group == AgentQueue.onMachine("Build machine") } }
        check(machine && said().contains("--machine m1 agent list|") && !said().contains("--machine m1 --session"),
              "herdr machines: a local herdr's saved machines are read through it, their agents under the machine's name", said())
        let posted = await wait(25) { AppDelegate.shared.testNotifications.contains { $0.content.userInfo["herdr_machine"] as? String == "m1" } }
        check(posted, "herdr machines: an agent there needing a decision posts its notice")
        unlink(calls.path)
        HerdrAgentMenu.go(to: .machine(tab: tab.id.uuidString, machine: "m1", pane: "w1:p1"))
        check(await wait(10) { AgentPeek.current != nil } && !said().contains("agent focus"), "herdr machines: choosing one peeks at it, moving nothing")
        AgentPeek.current?.close()

        let before = AppDelegate.shared.testNotifications.count
        tab.view.send(txt: "q")
        let ended = await wait(10) { !tab.status.running && tab.localHerdr == nil }
        await pause(1)
        check(ended && AppDelegate.shared.testNotifications.count == before && tab.status.unseen == nil,
              "herdr on this Mac: leaving herdr posts no notice and marks nothing", "\(tab.status.unseen as Any)")
        unlink(calls.path)
        await pause(5)
        check(!said().contains("--machine"), "herdr machines: and nothing more is read on its machines", said())
    }
    #endif
}
