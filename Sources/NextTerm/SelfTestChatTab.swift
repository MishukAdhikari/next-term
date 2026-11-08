#if DEBUG
import AppKit
import NextTermCore

/// Chat tabs (plan 037 U9, AE1–AE10), on screen, with stand-ins named claude and codex: first on every chat agent's
/// PATH (ChatEnvironment.testOverlay) and on the PATH of every terminal tab this part opens (its own zsh config,
/// TerminalTab.testUserZDOTDIR), so the user's own CLIs never run. Each is a dispatcher: `claude -p`, `claude --version`
/// and `codex app-server` go to plan 035's stand-ins (SelfTestAgentSession, in bin/chat), anything else to the stand-in
/// of the agent's own terminal interface (SelfTestViewSwitch's, in bin/tui). Folder trust, the CLI versions and the
/// Settings default go to a defaults suite of this part's own; the handoff's "Don't ask again" and New Chat's last agent
/// are put back as they were.
///
/// Two lessons from the view switch's part hold here: a freshly started terminal agent is marked working by its first
/// frame until it has been quiet a while, so the part waits for that mark to clear before acting on it; and a command
/// line a tab shows may wrap mid-word, so lines are compared with their whitespace dropped.
extension SelfTest {
    static func chatTabChecks(_ c: TerminalWindowController) async {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), Bundle.main.executablePath != nil else {
            return note("chat tab: skipped, no /usr/bin/python3 for the stand-ins")
        }
        guard let rig = ChatTabRig(c) else { return check(false, "chat tab: the stand-ins and their folders are made") }
        defer { rig.tearDown() }
        await chatNewChatChecks(rig)
        await chatEndStray(rig, "the New Chat checks")
        await chatMCPChecks(rig)
        await chatTrustAndOrphanChecks(rig)
        await chatHandoffChecks(rig)
        await chatEndStray(rig, "the handoff checks")
        await chatContinueInChecks(rig)
        await chatDefaultChecks(rig)
        await chatRestoreChecks(rig)
        await chatEndStray(rig, "the restore checks")
    }

    /// A sheet or a Mac question a group left up fails it and is answered no, so the next group starts clean.
    private static func chatEndStray(_ rig: ChatTabRig, _ group: String) async {
        for window in approvals() {
            check(false, "chat tab: \(group) leave no question on the Mac", window.window?.title ?? "")
            window.declineButton.performClick(nil)
        }
        await endStrayQuestions(after: "chat tab: " + group)
    }

    // MARK: AE1–AE4, AE9's view: New Chat…, a turn, the card's keys, the input box

    static func chatNewChatChecks(_ rig: ChatTabRig) async {
        let c = rig.c
        guard let window = c.window else { return check(false, "chat tab: the self-test window is there") }
        // The project folder New Chat… offers first is trusted in the part's own suite.
        rig.trust(c.project ?? c.searchRoot)
        let before = c.tabs.count
        c.newChat(nil)
        let sheetUp = await wait(5) { window.attachedSheet != nil }
        let sheet = window.attachedSheet?.contentView
        let pickers = sheet.map(rig.popups(in:)) ?? []
        let agentPicker = pickers.first { $0.accessibilityLabel() == "Agent" }
        let folderPicker = pickers.first { $0.accessibilityLabel() == "Folder" }
        let offered = agentPicker?.itemTitles ?? []
        check(sheetUp && offered.contains("Claude Code") && offered.contains("Codex") && folderPicker?.titleOfSelectedItem != nil
                  && !sheetText(window).contains("nxtrm"),
              "chat tab: Agents › New Chat… asks for the agent (the stand-ins found first on the PATH) and the folder, typing no command",
              "\(offered), folder \(folderPicker?.titleOfSelectedItem ?? "none"): \(sheetText(window))")
        agentPicker?.selectItem(withTitle: "Claude Code")
        let start = sheet.flatMap { SelfTestRestore.buttons(in: $0).first { $0.title == "Start" } }
        start?.performClick(nil)
        _ = await wait(5) { window.attachedSheet == nil }
        guard await wait(5, { c.tabs.count == before + 1 }), let tab = c.activeTab, let host = tab.chatHost else {
            return check(false, "chat tab: New Chat… opens a chat tab", "\(c.tabs.count) tabs")
        }
        rig.opened.append(tab)
        let ready = await rig.ready(tab)
        let line = host.header.line
        let input = host.view.input.textView
        check(ready && ChatTabs.glyph(for: tab) == .chat && tab.title == "Claude Code"
                  && line.hasPrefix("Claude Code \u{00B7} stand-in-model \u{00B7} 9.9.9 \u{00B7} ") && window.firstResponder === input
                  && input.placeholder == "Message Claude Code",
              "chat tab: New Chat… opens a chat tab with the bubble, the header naming agent, model, version and folder, and the input focused",
              "ready \(ready), glyph \(String(describing: ChatTabs.glyph(for: tab))), \(tab.title): \(line), responder \(String(describing: window.firstResponder))")
        let env = rig.chatEnvironment("claude")
        check((env["PATH"] ?? "").hasPrefix(rig.bin + ":") && env["TERM_PROGRAM"] == "NextTerm",
              "chat tab: the agent starts with the login shell's environment, Next Term's name, and (here) the stand-ins first on PATH",
              "PATH \((env["PATH"] ?? "").prefix(120)), TERM_PROGRAM \(env["TERM_PROGRAM"] ?? "unset")")

        await chatTurnChecks(rig, tab)
        await chatInputChecks(rig, tab)
        await chatCardChecks(rig, tab)
        rig.close(tab)
    }

    /// AE1: Return sends; the prompt, a thought, streamed Markdown with a code block, the plan, a Bash row that runs then
    /// ends done, an Edit row with +2 −1 and Open Diff, and the closing line with the usage. Then 200 chunks a second.
    static func chatTurnChecks(_ rig: ChatTabRig, _ tab: TerminalTab) async {
        guard let host = tab.chatHost else { return }
        let c = rig.c
        rig.typeAndReturn(tab, "markdown please")
        var sawRunning = false
        let turned = await wait(15) {
            if let tool = rig.tool(tab, titled: "ls -la"), tool.status != .completed { sawRunning = true }
            return rig.plain(tab).contains("Context 1.2k of 200k") && host.state == .ready
        }
        let kinds = rig.kinds(tab)
        check(turned && ChatTabRig.ordered(["prompt", "thought", "message", "plan", "tool", "tool", "change", "turnEnded"], in: kinds),
              "chat tab: a turn shows the prompt, a folded thought, the reply, the plan, the tool rows, the file change and the closing line, in order",
              "\(kinds): \(rig.plain(tab).suffix(400))")
        check(sawRunning && rig.tool(tab, titled: "ls -la")?.status == .completed,
              "chat tab: the Bash row shows running, then done", "\(String(describing: rig.tool(tab, titled: "ls -la")))")
        let shown = host.view.transcript.textView
        let text = shown.string as NSString
        let code = text.range(of: "let a = 2")
        let font = code.location == NSNotFound ? nil : shown.textStorage?.attribute(.font, at: code.location, effectiveRange: nil) as? NSFont
        let heading = text.range(of: "The change")
        let headingFont = heading.location == NSNotFound ? nil : shown.textStorage?.attribute(.font, at: heading.location, effectiveRange: nil) as? NSFont
        check(font?.isFixedPitch == true && !text.contains("```") && !text.contains("## ") && (headingFont?.pointSize ?? 0) > (font?.pointSize ?? 99),
              "chat tab: the reply is rendered Markdown: a heading, and the code block in a monospaced font with no fences",
              "code font \(font?.fontName ?? "none"), heading \(headingFont?.pointSize ?? 0): \(text.length > 300 ? text.substring(to: 300) : text as String)")
        let thought = rig.blocks(tab).compactMap { (block: ChatBlock) -> ChatThought? in
            if case .thought(let thought) = block.content { return thought }
            return nil
        }.first
        check(thought?.folded == true && thought?.title.hasPrefix("Thought") == true, "chat tab: the thought is one folded row",
              thought?.title ?? "none")
        let change = rig.blocks(tab).first { (block: ChatBlock) -> Bool in
            if case .change(let row) = block.content { return row.path.hasSuffix("src/a.swift") && row.added == 2 && row.removed == 1 }
            return false
        }
        check(change != nil && rig.plain(tab).contains("src/a.swift (+2 \u{2212}1)"),
              "chat tab: the Edit's file change is its own row, src/a.swift +2 −1", rig.plain(tab).suffix(300).description)
        if let change {
            host.view.transcript.onLink?(.diff(change.id))
            let opened = await wait(5) { c.editorArea.activePath.map(canonicalPath) == canonicalPath(rig.editFile) }
            check(opened, "chat tab: the change's Open Diff opens the file in the editor", c.editorArea.activePath ?? "nothing open")
            if let editor = c.editorArea.activeEditor { c.editorArea.close(editor) }
        }
        check(rig.plain(tab).contains("Done") && host.header.usage?.contains("Context 1.2k of 200k") == true,
              "chat tab: the closing line and the header carry the usage", "\(host.header.usage ?? "none"): \(rig.plain(tab).suffix(160))")

        // 200 chunks a second: the reply is whole, once, and the turn ends.
        rig.typeAndReturn(tab, "stream please")
        let expected = (0..<200).map { String(format: "c%03d ", $0) }.joined()
        let streamed = await wait(15) { host.state == .ready && rig.plain(tab).contains(expected.trimmingCharacters(in: .whitespaces)) }
        let messages = rig.blocks(tab).filter { (block: ChatBlock) -> Bool in
            if case .message(let markdown, _) = block.content { return markdown.contains("c000") }
            return false
        }
        check(streamed && messages.count == 1 && host.view.transcript.textView.string.contains("c199"),
              "chat tab: 200 streamed chunks a second end as one whole reply, drawn", "\(messages.count) replies: \(rig.plain(tab).suffix(200))")
    }

    /// AE4: ⇧Return makes a second line and Return sends both as one prompt; during a turn Return keeps the draft and
    /// sends nothing, the box says how to stop, ⌘. stops it; /login isn't sent.
    static func chatInputChecks(_ rig: ChatTabRig, _ tab: TerminalTab) async {
        guard let host = tab.chatHost else { return }
        let box = host.view.input.textView
        box.string = ""
        box.insertText("first line", replacementRange: NSRange(location: 0, length: 0))
        box.doCommand(by: #selector(NSResponder.insertLineBreak(_:)))
        box.insertText("second line", replacementRange: box.selectedRange())
        let twoLines = box.string == "first line\nsecond line"
        box.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let sent = await wait(10) {
            rig.blocks(tab).contains { (block: ChatBlock) -> Bool in
                if case .prompt(let text) = block.content { return text == "first line\nsecond line" }
                return false
            } && host.state == .ready
        }
        check(twoLines && sent && box.string.isEmpty, "chat tab: a line break makes a second line, and Return sends both as one prompt",
              "box \(box.string.debugDescription): \(rig.plain(tab).suffix(200))")

        let turnsBefore = rig.turns("claude")
        host.view.input.clear()
        rig.typeAndReturn(tab, "wait a while")
        let working = await wait(10) { host.state == .working }
        box.insertText("a draft", replacementRange: box.selectedRange())
        box.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try? await Task.sleep(nanoseconds: 500_000_000)
        check(working && box.string == "a draft" && box.placeholder == "Claude Code is working. \u{2318}. stops it."
                  && rig.turns("claude") == turnsBefore + 1 && !host.view.header.stopButton.isHidden,
              "chat tab: during a turn Return sends nothing and keeps the draft, the box says how to stop it, Stop shows",
              "box \(box.string.debugDescription), placeholder \(box.placeholder), turns \(rig.turns("claude") - turnsBefore)")
        box.cancelOperation(nil) // ⌘. reaches the box as cancelOperation
        let stopped = await wait(10) { rig.chatLog("claude").contains("control interrupt") && host.state == .ready && rig.plain(tab).contains("Stopped") }
        check(stopped && box.string == "a draft", "chat tab: ⌘. sends the interrupt, the turn says Stopped, the draft stays",
              rig.plain(tab).suffix(200).description)
        host.view.input.clear()

        let turnsThen = rig.turns("claude")
        rig.typeAndReturn(tab, "/login")
        let noted = await wait(5) { rig.plain(tab).contains("/login works in the terminal: Open in Terminal") }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let key = ChatTabs.handoffShortcut.map { " (" + $0 + ")" } ?? ""
        check(noted && rig.plain(tab).contains("/login works in the terminal: Open in Terminal" + key) && rig.turns("claude") == turnsThen,
              "chat tab: /login isn't sent; a note offers Open in Terminal with its key", rig.plain(tab).suffix(200).description)
        host.view.input.clear()
    }

    /// AE2, AE3, R3: the permission card, its keys and the 400 ms guard, answer_agent, Allow always on the Mac, and
    /// AskUserQuestion; then Esc stops a turn, and a notice's Reply is a prompt.
    static func chatCardChecks(_ rig: ChatTabRig, _ tab: TerminalTab) async {
        guard let host = tab.chatHost else { return }
        let card = host.view.card
        let id = tab.id.uuidString.lowercased()
        func denies() -> Int { rig.answers("perm-rm").filter { $0.contains("\"behavior\": \"deny\"") }.count }
        func allows() -> Int { rig.answers("perm-rm").filter { $0.contains("\"behavior\": \"allow\"") }.count }
        func cardUp() async -> Bool { await wait(10) { !card.isHidden && card.decision != nil && tab.status.state == .attention } }
        func settled() async { _ = await wait(10) { host.state == .ready && tab.status.state != .attention } }

        // The card, the tab's question and its notice's choices.
        rig.typeAndReturn(tab, "please rm it")
        let up = await cardUp()
        // A Return already on its way when the card appears answers nothing.
        card.keyDown(with: ChatTabRig.key(36, "\r"))
        let decision = card.decision
        let question = tab.status.question ?? ""
        let menu = MCPControl.fieldMenu(tab, question: question)
        let labels = SelfTestRestore.buttons(in: card).map { $0.accessibilityLabel() ?? "" }
        check(up && decision?.title == "Bash(rm -rf build)" && decision?.lead == "Claude Code asks to:"
                  && decision?.choices.map(\.name) == ["Allow once", "Reject"] && menu?.choices == ["Allow once", "Reject"]
                  && labels == ["Allow once, 1 of 2", "Reject, 2 of 2"],
              "chat tab: can_use_tool is a card with the whole action and one button per choice, the tab's question, and its notice's choices",
              "\(decision?.title ?? "no card"), \(decision?.choices.map(\.name) ?? []), menu \(menu?.choices ?? []), labels \(labels)")
        let readTab = await agentCall("read_tab", ["tab_id": id, "lines": 20])
        let read = (try? JSONSerialization.jsonObject(with: Data(readTab.text.utf8))) as? [String: Any] ?? [:]
        check(read["question"] as? String == question && read["choices"] as? [String] == ["Allow once", "Reject"]
                  && read["question_id"] as? String == MCPControl.questionID(tab) && read["kind"] as? String == "chat",
              "chat tab: read_tab gives the card's question, choices and question_id", readTab.text)
        check(rig.c.window?.firstResponder === card, "chat tab: with the input empty, the card takes the keyboard",
              String(describing: rig.c.window?.firstResponder))
        try? await Task.sleep(nanoseconds: 300_000_000)
        check(rig.answers("perm-rm").isEmpty && !card.isHidden, "chat tab: a Return within 400 ms of the card appearing answers nothing",
              "\(rig.answers("perm-rm"))")
        try? await Task.sleep(nanoseconds: 300_000_000)
        card.keyDown(with: ChatTabRig.key(125, "\u{F701}"))
        card.keyDown(with: ChatTabRig.key(36, "\r"))
        let second = await wait(10) { denies() == 1 }
        await settled()
        check(second && rig.plain(tab).contains("Rejected: Bash(rm -rf build)"),
              "chat tab: ↓ then Return picks the second choice, and the card becomes a row", rig.plain(tab).suffix(200).description)

        rig.typeAndReturn(tab, "please rm it")
        _ = await cardUp()
        try? await Task.sleep(nanoseconds: 500_000_000)
        card.keyDown(with: ChatTabRig.key(18, "1"))
        let first = await wait(10) { allows() == 1 }
        await settled()
        rig.typeAndReturn(tab, "please rm it")
        _ = await cardUp()
        try? await Task.sleep(nanoseconds: 500_000_000)
        card.keyDown(with: ChatTabRig.key(53, "\u{1b}"))
        let escaped = await wait(10) { denies() == 2 }
        await settled()
        check(first && escaped && rig.plain(tab).contains("Allowed once: Bash(rm -rf build)"),
              "chat tab: 1 picks the first choice, Esc rejects", "\(rig.answers("perm-rm"))")

        // answer_agent and press_keys pick from the card as from any tab's menu.
        rig.typeAndReturn(tab, "please rm it")
        _ = await cardUp()
        let rejected = await answerTab(tab, "Reject")
        let byMCP = await wait(10) { denies() == 3 }
        await settled()
        rig.typeAndReturn(tab, "please rm it")
        _ = await cardUp()
        let pressed = await agentCall("press_keys", ["tab_id": id, "keys": ["1"]])
        let byKeys = await wait(10) { allows() == 2 }
        await settled()
        check(!rejected.isError && byMCP && !pressed.isError && byKeys, "chat tab: answer_agent's Reject and press_keys' 1 answer the card",
              "\(rejected.text) / \(pressed.text)")

        // Allow always: asked on the Mac, declined there the card stays; the card's own button, approved there, sends it.
        rig.typeAndReturn(tab, "always make it")
        _ = await cardUp()
        let alwaysTitle = "Allow Claude Code always?"
        let viaMCP = await answerTab(tab, "Allow always")
        let asked = await wait(10) { !approvals(alwaysTitle).isEmpty }
        approvals(alwaysTitle).first?.declineButton.performClick(nil)
        let kept = await wait(10) { rig.plain(tab).contains("was declined on the Mac") && !card.isHidden }
        check(!viaMCP.isError && asked && kept && rig.answers("perm-always").isEmpty,
              "chat tab: Allow always is asked on the Mac; declined there, nothing is sent and the card stays", viaMCP.text)
        let button = SelfTestRestore.buttons(in: card).first { $0.title == "Allow always" }
        button?.performClick(nil)
        let askedAgain = await wait(10) { !approvals(alwaysTitle).isEmpty }
        approvals(alwaysTitle).first?.approveButton.performClick(nil)
        let allowed = await wait(10) { !rig.answers("perm-always").isEmpty }
        await settled()
        let always = rig.answers("perm-always").first ?? ""
        check(button != nil && askedAgain && allowed && always.contains("\"behavior\": \"allow\"") && always.contains("\"destination\": \"session\""),
              "chat tab: the card's Allow always, approved on the Mac, sends Claude's suggestion kept to this session", always)

        // AskUserQuestion: a card of answers with no allow lead, one response for both questions.
        rig.typeAndReturn(tab, "ask me")
        let colour = await cardUp()
        let asking = card.decision
        try? await Task.sleep(nanoseconds: 500_000_000)
        card.keyDown(with: ChatTabRig.key(19, "2"))
        let size = await wait(10) { card.decision?.title == "Which size?" }
        _ = await answerTab(tab, "Large")
        let both = await wait(10) { !rig.answers("perm-ask").isEmpty }
        await settled()
        let reply = rig.answers("perm-ask").first ?? ""
        check(colour && asking?.isQuestion == true && asking?.lead == nil && asking?.choices.map(\.name) == ["Red", "Blue"] && size && both
                  && reply.contains("\"Which color?\": \"Blue\"") && reply.contains("\"Which size?\": \"Large\""),
              "chat tab: AskUserQuestion is a card of its answers, 2 picks Blue, and one response carries both answers",
              "\(asking?.title ?? "no card"), \(asking?.choices.map(\.name) ?? []): \(reply)")

        // Esc in the box stops a running turn.
        let interrupts = rig.chatLog("claude").filter { $0 == "control interrupt" }.count
        rig.typeAndReturn(tab, "wait a while")
        _ = await wait(10) { host.state == .working }
        host.view.input.textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        let stopped = await wait(10) { rig.chatLog("claude").filter { $0 == "control interrupt" }.count == interrupts + 1 && host.state == .ready }
        check(stopped, "chat tab: Esc in the box stops the turn", rig.plain(tab).suffix(200).description)

        // A notice's Reply is a prompt.
        let app: AppDelegate = AppDelegate.shared
        app.respond(to: "nt-chat-reply", title: "Claude Code is waiting for you", info: ["tab": tab.id.uuidString],
                    action: NoticeActions.reply, text: "reply from the notice")
        let replied = await wait(10) { rig.plain(tab).contains("Streamed reply to: reply from the notice") && host.state == .ready }
        check(replied, "chat tab: a notice's Reply sends its line as a prompt", rig.plain(tab).suffix(200).description)
    }

    // MARK: AE5: MCP on a chat tab

    static func chatMCPChecks(_ rig: ChatTabRig) async {
        guard let tab = await rig.chat("claude", env: ["STANDIN_SESSION_ID": ChatTabRig.newID()]), await rig.ready(tab), let host = tab.chatHost else {
            return check(false, "chat tab: a chat for the MCP checks starts", rig.chatLog("claude").suffix(3).joined(separator: " | "))
        }
        let id = tab.id.uuidString.lowercased()
        let listed = await rig.listed(id)
        check(listed?["kind"] as? String == "chat" && listed?["agent_session"] as? String == "Claude Code"
                  && listed?["agent_version"] as? String == "9.9.9" && listed?["model"] as? String == "stand-in-model",
              "chat tab: list_tabs gives kind chat and the session's agent, version and model", "\(listed ?? [:])")
        let sent = await agentCall("send_to_tab", ["tab_id": id, "text": "list files"])
        let waited = await rig.call("wait_for_tab", ["tab_id": id, "timeout_seconds": 30], within: 35)
        let json = (try? JSONSerialization.jsonObject(with: Data(waited.text.utf8))) as? [String: Any] ?? [:]
        check(!sent.isError && json["stop_reason"] as? String == "end_turn" && json["last_message"] as? String == "Streamed reply to: list files"
                  && json["timed_out"] as? Bool != true,
              "chat tab: send_to_tab starts a turn, and wait_for_tab returns when it ends with its stop reason and reply", waited.text)
        let read = await agentCall("read_tab", ["tab_id": id, "lines": 40])
        let readJSON = (try? JSONSerialization.jsonObject(with: Data(read.text.utf8))) as? [String: Any] ?? [:]
        let screen = readJSON["screen"] as? String ?? ""
        check(screen.contains("\u{203A} list files") && screen.contains("Streamed reply to: list files") && readJSON["input"] as? String == "",
              "chat tab: read_tab's screen is the transcript as text, its input the draft", read.text)
        let drafted = await agentCall("send_to_tab", ["tab_id": id, "text": "kept for later", "submit": false])
        check(!drafted.isError && host.draft == "kept for later" && host.view.input.textView.string == "kept for later",
              "chat tab: send_to_tab without submit puts the text in the input box", drafted.text)
        host.view.input.clear()

        // The agent's own nxtrm mcp finds its chat tab: "you": true.
        if MCPControlServer.shared.isRunning {
            await prompt(tab, "mcp please")
            let answered = await wait(25) { rig.plain(tab).contains("MCP answered") && host.state == .ready }
            let you = rig.mcpAnswerYou(id)
            check(answered && you == true, "chat tab: list_tabs from the chat agent's own Next Term MCP server marks its tab you",
                  rig.mcpAnswer().prefix(300).description)
        } else {
            note("chat tab: the you check skipped, the control socket isn't running")
        }
        rig.close(tab)
    }

    // MARK: AE9: folder trust, and no orphans

    static func chatTrustAndOrphanChecks(_ rig: ChatTabRig) async {
        // The first Claude Code chat in a new folder waits for the Mac; declined, it ends with nothing run.
        let trustTitle = "Trust this folder for Claude Code?"
        let sessions = rig.sessions("claude")
        if let tab = await rig.chat("claude", folder: rig.untrusted), let host = tab.chatHost {
            let asked = await wait(15) { !approvals(trustTitle).isEmpty }
            let waiting = host.state == .trusting && host.view.input.textView.placeholder == AgentSessionTrust.waitingLine
            approvals(trustTitle).first?.declineButton.performClick(nil)
            let ended = await wait(10) { host.state == .ended }
            check(asked && waiting && ended && !host.view.endCard.isHidden && rig.sessions("claude") == sessions,
                  "chat tab: the first chat in a folder waits for the Mac's trust in the input; declined, an end card and nothing run",
                  "asked \(asked), waiting \(waiting), \(host.state.rawValue): \(rig.plain(tab).suffix(200))")
            rig.close(tab)
        } else {
            check(false, "chat tab: a chat in an untrusted folder opens")
        }

        // Closing a chat ends its agent and the child it started.
        guard let tab = await rig.chat("claude"), await rig.ready(tab), let host = tab.chatHost else {
            return check(false, "chat tab: a chat for the orphan check starts")
        }
        await prompt(tab, "child please")
        let started = await wait(10) { rig.plain(tab).contains("Started a child") && host.state == .ready }
        let agent = host.agentPid ?? 0
        let child = rig.lastChild("claude")
        rig.close(tab)
        let gone = await wait(10) { !ChatTabRig.alive(agent) && !ChatTabRig.alive(child) }
        check(started && agent > 0 && child > 0 && gone, "chat tab: closing a chat ends its agent and the child it started (no orphans)",
              "agent \(agent) alive \(ChatTabRig.alive(agent)), child \(child) alive \(ChatTabRig.alive(child))")
    }

    // MARK: AE6, AE7: the handoffs and their refusals

    static func chatHandoffChecks(_ rig: ChatTabRig) async {
        let c = rig.c
        let id = ChatTabRig.newID()
        guard let shell = await rig.shell(), let source = await rig.tui("claude", id: id) else {
            return check(false, "chat tab: a tab runs the stand-in claude", rig.tuiLog("claude").suffix(3).joined(separator: " | "))
        }
        // AE7: before its first turn, while it works, while it asks: refused, nothing typed.
        let fresh = await rig.handOff(source)
        check(rig.refusal(fresh) == "No conversation to carry over yet: send a prompt first." && rig.tuiKeys("claude", since: 0).isEmpty,
              "chat tab: Continue in Chat before the first turn is refused, nothing typed", rig.refusal(fresh) ?? "it ran")
        guard await rig.turn(source, "hello") else { return check(false, "chat tab: the stand-in claude takes a turn", rig.flat(source)) }
        rig.type(source, "busy")
        let busy = await wait(8) { source.status.state == .working }
        let mark = rig.tuiLog("claude").count
        let working = await rig.handOff(source)
        check(busy && rig.refusal(working) == "Claude Code is working. Try again when its turn ends." && rig.tuiKeys("claude", since: mark).isEmpty,
              "chat tab: while claude shows esc to interrupt, Continue in Chat is refused, nothing typed", rig.refusal(working) ?? "it ran")
        _ = await wait(8) { source.status.state != .working }
        rig.type(source, "ask")
        let asks = await wait(8) { source.status.question != nil }
        let asked = rig.tuiLog("claude").count
        let asking = await rig.handOff(source)
        check(asks && rig.refusal(asking) == "Claude Code is asking you something. Answer it first." && rig.tuiKeys("claude", since: asked).isEmpty,
              "chat tab: while claude asks, Continue in Chat is refused, nothing typed", rig.refusal(asking) ?? "it ran")
        source.view.send(txt: "1")
        _ = await wait(6) { source.status.question == nil && source.status.state != .working }

        // ⇧⌘J's item follows the tab: off in front of a shell, Continue in Chat in front of claude.
        guard let item = rig.handoffItem() else { return check(false, "chat tab: Agents has Continue in Chat") }
        rig.front(shell)
        let offShell = !c.validateMenuItem(item)
        rig.front(source)
        let onClaude = c.validateMenuItem(item) && item.title == "Continue in Chat"
        check(offShell && onClaude && MenuKeys.defaults["handOffConversation:"]?.display == "\u{21E7}\u{2318}J",
              "chat tab: Agents › Continue in Chat is on ⇧⌘J, on for a claude tab and off for a shell", "shell \(offShell), claude \(onClaude)")

        // AE6: ⇧⌘J asks first; Cancel changes nothing.
        guard let window = c.window else { return }
        let keysBefore = rig.tuiLog("claude").count
        c.handOffConversation(item)
        let sheet = await wait(5) { rig.sheetButton("Continue") != nil }
        let words = sheetText(window)
        check(sheet && words.contains("Continue this conversation in Chat?") && words.contains("Claude Code quits in this tab.")
                  && rig.sheetButton("Don\u{2019}t ask again") != nil,
              "chat tab: ⇧⌘J asks Continue this conversation in Chat?, with Don't ask again", words)
        rig.sheetButton("Cancel")?.performClick(nil)
        _ = await wait(3) { window.attachedSheet == nil }
        try? await Task.sleep(nanoseconds: 500_000_000)
        check(rig.tuiKeys("claude", since: keysBefore).isEmpty && source.status.running && ConversationHandoff.asksFirst(defaults: .standard),
              "chat tab: Cancel changes nothing", "\(rig.tuiKeys("claude", since: keysBefore))")

        // Continue: ⌃C, /exit and Return; the shell's prompt, a dim note, and the chat right after the source, resumed.
        let tabsBefore = c.tabs.count
        var outcome: HandoffRunner.Outcome?
        HandoffRunner.start(tab: source) { outcome = $0 }
        _ = await wait(5) { rig.sheetButton("Continue") != nil }
        rig.sheetButton("Continue")?.performClick(nil)
        _ = await wait(25) { outcome != nil }
        let keys = rig.tuiKeys("claude", since: keysBefore)
        let noted = rig.showsNote(source, "Continued in Chat: Claude Code conversation \(id.prefix(8))")
        check(keys == ["ctrl-c", "line /exit", "exit 0"] && noted && !source.status.running,
              "chat tab: Continue quits claude with ⌃C, /exit and Return, and the source shows a dim note at its prompt",
              "\(keys), note \(noted): \(rig.refusal(outcome) ?? "")")
        guard let chat = rig.opened(outcome), let host = chat.chatHost else { return check(false, "chat tab: Continue opens a chat tab", rig.refusal(outcome) ?? "") }
        rig.opened.append(chat)
        let resumed = await wait(15) { rig.reportResumed(chat, id) && host.state == .ready }
        let after = rig.groupIndex(of: chat) == rig.groupIndex(of: source).map { $0 + 1 }
        check(resumed && after && c.tabs.count == tabsBefore + 1 && rig.chatLog("claude").contains("resume \(id)"),
              "chat tab: the chat opens right after the source, going on with the conversation by its id (--resume)",
              "after \(after), \(rig.chatLog("claude").suffix(3))")

        // AE7 on the chat side: working, asking.
        host.send("wait a while")
        _ = await wait(10) { host.state == .working }
        let chatWorking = await rig.handOff(chat)
        host.stop()
        _ = await wait(10) { host.state == .ready }
        host.send("please rm it")
        _ = await wait(10) { host.state == .asking }
        let chatAsking = await rig.handOff(chat)
        host.choose(1)
        _ = await wait(10) { host.state == .ready && chat.status.state != .attention }
        check(rig.refusal(chatWorking) == "Claude Code is working. Try again when its turn ends."
                  && rig.refusal(chatAsking) == "Claude Code is asking you something. Answer it first.",
              "chat tab: Open in Terminal is refused while the chat works or asks", "\(rig.refusal(chatWorking) ?? "ran") / \(rig.refusal(chatAsking) ?? "ran")")

        // Open in Terminal by ⇧⌘J, with Don't ask again ticked: the chat's agent and its child end first, then a terminal
        // tab after it runs claude --resume ID; the chat shows Continued in Terminal with Show Tab.
        host.send("child please")
        _ = await wait(10) { rig.plain(chat).contains("Started a child") && host.state == .ready }
        let agent = host.agentPid ?? 0
        let child = rig.lastChild("claude")
        rig.front(chat)
        let openTitle = c.validateMenuItem(item) && item.title == "Open in Terminal"
        let tuiMark = rig.tuiLog("claude").count
        c.handOffConversation(item)
        _ = await wait(5) { rig.sheetButton("Continue") != nil }
        let chatWords = sheetText(window)
        if let box = rig.sheetButton("Don\u{2019}t ask again") { box.state = .on }
        rig.sheetButton("Continue")?.performClick(nil)
        let back = await wait(20) { rig.tuiStarted("claude", since: tuiMark, resuming: id) }
        let ended = await wait(8) { !ChatTabRig.alive(agent) && !ChatTabRig.alive(child) }
        check(openTitle && chatWords.contains("Open this conversation in Terminal?") && back && ended,
              "chat tab: Open in Terminal (⇧⌘J, confirmed) ends the chat's agent and its child, then claude --resume ID runs in a terminal tab",
              "title \(openTitle), \(chatWords), agent \(ChatTabRig.alive(agent)), child \(ChatTabRig.alive(child))")
        let terminal = rig.groupIndex(of: chat).flatMap { (index: Int) -> TerminalTab? in
            c.groups.indices.contains(index + 1) ? c.groups[index + 1].focused : nil
        }
        if let terminal { rig.opened.append(terminal) }
        var continued = false
        if case .continued(_, let open)? = host.endState { continued = open }
        let showTab = SelfTestRestore.buttons(in: host.view.endCard).first { $0.title == "Show Tab" }
        check(terminal.map { rig.shows($0, "claude --resume \(id)") } == true && continued && !host.view.endCard.isHidden && showTab != nil
                  && rig.plain(chat).contains("Continued in Terminal") && !ConversationHandoff.asksFirst(defaults: .standard),
              "chat tab: the terminal tab is right after the chat, which ends with Continued in Terminal and Show Tab; Don't ask again is kept",
              rig.plain(chat).suffix(200).description)
        rig.front(chat)
        showTab?.performClick(nil)
        check(terminal != nil && c.activeTab === terminal, "chat tab: Show Tab brings the terminal tab forward",
              String(describing: c.activeTab?.title))
        if let terminal {
            rig.type(terminal, "/exit")
            _ = await wait(6) { !terminal.status.running }
        }

        await chatCodexHandoffChecks(rig)

        // No exact id: a chat whose session id isn't one Claude Code takes is refused.
        if let guess = await rig.chat("claude"), await rig.ready(guess), let guessHost = guess.chatHost {
            guessHost.send("hello")
            _ = await wait(10) { rig.plain(guess).contains("Streamed reply to: hello") && guessHost.state == .ready }
            let unsure = await rig.handOff(guess)
            check(rig.refusal(unsure) == "Next Term can\u{2019}t tell which Claude Code conversation this is.",
                  "chat tab: a chat with no exact conversation id is refused", rig.refusal(unsure) ?? "it ran")
            rig.close(guess)
        }
    }

    /// Codex both ways, with Don't ask again ticked: no question, /quit, thread/resume, then codex resume ID.
    static func chatCodexHandoffChecks(_ rig: ChatTabRig) async {
        let id = ChatTabRig.newID()
        guard let source = await rig.tui("codex", id: id), await rig.turn(source, "hello") else {
            return check(false, "chat tab: a tab runs the stand-in codex", rig.tuiLog("codex").suffix(3).joined(separator: " | "))
        }
        let mark = rig.tuiLog("codex").count
        var sheet = false
        var outcome: HandoffRunner.Outcome?
        HandoffRunner.start(tab: source) { outcome = $0 }
        _ = await wait(25) {
            if rig.c.window?.attachedSheet != nil { sheet = true }
            return outcome != nil
        }
        let keys = rig.tuiKeys("codex", since: mark)
        guard let chat = rig.opened(outcome), let host = chat.chatHost else {
            return check(false, "chat tab: codex goes on in a chat", "\(keys): \(rig.refusal(outcome) ?? "")")
        }
        rig.opened.append(chat)
        let resumed = await wait(15) { rig.chatLog("codex").contains("thread resumed \(id)") && host.state == .ready }
        check(!sheet && keys == ["ctrl-c", "line /quit", "exit 0"] && resumed,
              "chat tab: with Don't ask again, Continue in Chat asks nothing; codex quits with /quit and the chat resumes its thread",
              "sheet \(sheet), \(keys), \(rig.chatLog("codex").suffix(3))")
        let back = rig.tuiLog("codex").count
        let toTerminal = await rig.handOff(chat)
        let started = await wait(20) { rig.tuiStarted("codex", since: back, resuming: id) }
        let terminal = rig.opened(toTerminal)
        if let terminal { rig.opened.append(terminal) }
        check(started && terminal.map { rig.shows($0, "codex resume \(id)") } == true,
              "chat tab: Open in Terminal from a Codex chat runs codex resume ID", rig.refusal(toTerminal) ?? "")
        if let terminal {
            rig.type(terminal, "/quit")
            _ = await wait(6) { !terminal.status.running }
        }
    }

    // MARK: AE10: continue_in

    static func chatContinueInChecks(_ rig: ChatTabRig) async {
        let id = ChatTabRig.newID()
        guard let tab = await rig.chat("claude", env: ["STANDIN_SESSION_ID": id]), await rig.ready(tab), let host = tab.chatHost else {
            return check(false, "chat tab: a chat for continue_in starts")
        }
        let tabID = tab.id.uuidString.lowercased()
        host.send("hello")
        _ = await wait(10) { rig.plain(tab).contains("Streamed reply to: hello") && host.state == .ready }
        host.send("wait a while")
        _ = await wait(10) { host.state == .working }
        let working = await rig.call("continue_in", ["tab_id": tabID])
        check(working.isError && working.text.contains("is working") && MCPWriteControl.pending == nil,
              "chat tab: continue_in on a working chat fails with the refusal's words, before any question", working.text)
        host.stop()
        _ = await wait(10) { host.state == .ready }
        let declined = await rig.asked("continue_in", ["tab_id": tabID, "view": "terminal"], approve: false)
        check(declined.asked && declined.result.isError && host.state == .ready && host.holdsConversation,
              "chat tab: continue_in asks on the Mac, and Decline changes nothing", declined.result.text)
        let mark = rig.tuiLog("claude").count
        let approved = await rig.asked("continue_in", ["tab_id": tabID, "view": "terminal"], approve: true)
        let answer = (try? JSONSerialization.jsonObject(with: Data(approved.result.text.utf8))) as? [String: Any] ?? [:]
        let started = await wait(20) { rig.tuiStarted("claude", since: mark, resuming: id) }
        let opened = rig.adopt(answer["new_tab_id"] as? String)
        check(approved.asked && !approved.result.isError && answer["kind"] as? String == "terminal" && answer["session_id"] as? String == id
                  && opened != nil && started,
              "chat tab: approved, continue_in answers the new terminal tab, which goes on with the conversation", approved.result.text)
        if let opened {
            rig.type(opened, "/exit")
            _ = await wait(6) { !opened.status.running }
        }
        rig.close(tab)
    }

    // MARK: AE10, R18: the Settings default and new_tab; a slow cold start

    static func chatDefaultChecks(_ rig: ChatTabRig) async {
        // Settings › Editor's popup writes Claude Code's key alone.
        let control = AgentOpenViewControls.control(.claude)
        let popup = control.subviews.compactMap { $0 as? NSPopUpButton }.first
        popup?.selectItem(withTitle: "Chat")
        if let popup, let action = popup.action { NSApp.sendAction(action, to: popup.target, from: popup) }
        check(AgentOpenView.opensIn(.claude, defaults: rig.suite) == .chat && AgentOpenView.opensIn(.codex, defaults: rig.suite) == .terminal,
              "chat tab: Settings' Open Claude Code in: Chat writes Claude Code's key and leaves Codex's",
              rig.suite.string(forKey: AgentOpenView.key(.claude)) ?? "unset")

        let bare = await rig.call("new_tab", ["directory": rig.work, "command": "claude", "prompt": "fix it"])
        let bareJSON = (try? JSONSerialization.jsonObject(with: Data(bare.text.utf8))) as? [String: Any] ?? [:]
        let bareTab = rig.adopt(bareJSON["id"] as? String)
        let ran = await wait(20) { rig.chatLog("claude").contains { $0.hasPrefix("turn ") && $0.hasSuffix(" fix it") } }
        check(!bare.isError && bareJSON["kind"] as? String == "chat" && bareTab?.isChat == true && ran,
              "chat tab: with Chat, new_tab's bare claude with a prompt opens a chat tab running it, and answers kind chat", bare.text)
        if let bareTab { rig.close(bareTab) }

        let mark = rig.tuiLog("claude").count
        let options = await rig.call("new_tab", ["directory": rig.work, "command": "claude --model opus"])
        let optionsJSON = (try? JSONSerialization.jsonObject(with: Data(options.text.utf8))) as? [String: Any] ?? [:]
        let optionsTab = rig.adopt(optionsJSON["id"] as? String)
        let terminal = await wait(20) { rig.tuiLog("claude").dropFirst(mark).contains { $0.hasPrefix("start ") && $0.contains("\"--model\", \"opus\"") } }
        check(!options.isError && optionsJSON["kind"] as? String != "chat" && optionsTab?.isChat == false && terminal,
              "chat tab: new_tab's claude --model opus stays a terminal tab", options.text)
        if let optionsTab {
            rig.type(optionsTab, "/exit")
            _ = await wait(6) { !optionsTab.status.running }
            rig.close(optionsTab)
        }

        let codex = await rig.call("new_tab", ["directory": rig.work, "agent_session": "codex"])
        let codexJSON = (try? JSONSerialization.jsonObject(with: Data(codex.text.utf8))) as? [String: Any] ?? [:]
        let codexTab = rig.adopt(codexJSON["id"] as? String)
        let codexReady = await wait(15) { codexTab?.chatHost?.state == .ready }
        check(!codex.isError && codexJSON["kind"] as? String == "chat" && codexReady,
              "chat tab: new_tab with agent_session codex opens a Codex chat tab", codex.text)
        if let codexTab { rig.close(codexTab) }

        // A slow cold start: wait_for_tab after new_tab's first prompt waits for that turn's end.
        rig.setChatEnvironment(["STANDIN_SLOW": "3"])
        let began = Date()
        let slow = await rig.call("new_tab", ["directory": rig.work, "agent_session": "claude", "prompt": "hello slow"])
        let slowJSON = (try? JSONSerialization.jsonObject(with: Data(slow.text.utf8))) as? [String: Any] ?? [:]
        let slowTab = rig.adopt(slowJSON["id"] as? String)
        if let slowTab { _ = await rig.launched(slowTab) }
        rig.setChatEnvironment([:])
        let waited = await rig.call("wait_for_tab", ["tab_id": slowJSON["id"] as? String ?? "", "timeout_seconds": 40], within: 45)
        let took = Date().timeIntervalSince(began)
        let json = (try? JSONSerialization.jsonObject(with: Data(waited.text.utf8))) as? [String: Any] ?? [:]
        check(slowTab?.isChat == true && json["stop_reason"] as? String == "end_turn" && json["last_message"] as? String == "Streamed reply to: hello slow"
                  && took >= 3,
              "chat tab: after a slow cold start, wait_for_tab returns once new_tab's first prompt has its reply",
              String(format: "%.1f s: ", took) + waited.text)
        if let slowTab { rig.close(slowTab) }
    }

    // MARK: AE8: restores

    static func chatRestoreChecks(_ rig: ChatTabRig) async {
        let resumeID = ChatTabRig.newID()
        let crashID = ChatTabRig.newID()
        let sessionTabID = ChatTabRig.newID()
        var updatePane = SessionSnapshot.Pane(id: UUID(), folder: rig.work)
        updatePane.chat = SessionSnapshot.ChatTabRecord(agent: "claude", sessionID: resumeID, folder: rig.work, draft: "a kept draft")
        var crashPane = SessionSnapshot.Pane(id: UUID(), folder: rig.work)
        crashPane.chat = SessionSnapshot.ChatTabRecord(agent: "claude", sessionID: crashID, folder: rig.work)
        var sessionPane = SessionSnapshot.Pane(id: UUID(), folder: rig.work,
                                               command: SessionSnapshot.Command(line: "nxtrm agent claude", check: .kept, source: .integration, running: true))
        sessionPane.agentSession = SessionSnapshot.AgentSessionRecord(agent: "claude", sessionID: sessionTabID, folder: rig.work)

        // An update restore: the chat comes back with its id, resumed by its conversation's id, its draft in the box.
        let sessions = rig.sessions("claude")
        let updated = rig.restore([updatePane], kind: .update)
        let updateTab = updated.first { $0.id == updatePane.id }
        let resumed = await wait(15) {
            rig.sessions("claude") > sessions && rig.chatLog("claude").contains("resume \(resumeID)") && updateTab?.chatHost?.state == .ready
        }
        check(updateTab?.isChat == true && resumed && updateTab?.chatHost?.draft == "a kept draft",
              "chat tab: an update restore brings the chat back with its tab id, resumed by its conversation's id, its draft kept",
              rig.chatLog("claude").suffix(3).joined(separator: " | "))
        rig.closeRestored()

        // A crash restore: idle with Resume, nothing run until it is pressed; a saved nxtrm agent tab comes back a chat.
        let before = rig.sessions("claude")
        let crashed = rig.restore([crashPane, sessionPane], kind: .crash)
        let crashTab = crashed.first { $0.id == crashPane.id }
        let sessionTab = crashed.first { $0.id == sessionPane.id }
        let idle = await wait(5) { crashTab?.chatHost?.state == .idle && sessionTab?.chatHost?.state == .idle }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let resume = crashTab.flatMap { (tab: TerminalTab) -> NSButton? in
            tab.chatHost.flatMap { SelfTestRestore.buttons(in: $0.view.endCard).first { $0.title == "Resume" } }
        }
        check(idle && rig.sessions("claude") == before && resume != nil && sessionTab?.chatHost?.start.agentID == "claude",
              "chat tab: a crash restore brings chats back idle with Resume and nothing run, a saved nxtrm agent tab as a chat",
              "\(crashTab?.chatHost?.state.rawValue ?? "none") / \(sessionTab?.chatHost?.state.rawValue ?? "none")")
        resume?.performClick(nil)
        let went = await wait(15) { rig.chatLog("claude").contains("resume \(crashID)") && crashTab?.chatHost?.state == .ready }
        check(went, "chat tab: Resume goes on with the conversation", rig.chatLog("claude").suffix(3).joined(separator: " | "))
        rig.closeRestored()
    }
}

/// What the chat tab part works in: its folders and stand-ins, its own zsh config, its defaults suite and the stores it
/// swapped, and the tabs and windows it opened, all undone by `tearDown`.
@MainActor
final class ChatTabRig {
    let c: TerminalWindowController
    let root: String
    let bin: String
    /// The folder the tabs run in, by its real path, trusted in the part's suite.
    let work: String
    /// A folder no chat has been trusted in.
    let untrusted: String
    /// The file the stand-in's Edit names.
    let editFile: String
    let suite: UserDefaults
    var opened: [TerminalTab] = []
    private let suiteName: String
    private let claudeStore: String
    private let codexHome: String
    private let savedTrust: UserDefaults
    private let savedVersions: UserDefaults
    private let savedOpenView: UserDefaults
    private let savedZDOTDIR: String?
    private let savedSkip: Any?
    private let savedLastAgent: Any?
    private let savedFront: TerminalTab?
    private let windowsBefore: [TerminalWindowController]
    private var restored: [TerminalWindowController] = []

    init?(_ c: TerminalWindowController) {
        self.c = c
        let fm = FileManager.default
        root = canonicalPath(NSTemporaryDirectory()) + "/nt-chat-\(getpid())-\(UUID().uuidString.prefix(6))"
        bin = root + "/bin"
        work = root + "/work"
        untrusted = root + "/untrusted"
        editFile = work + "/src/a.swift"
        let zdot = root + "/zsh"
        claudeStore = root + "/claude-store"
        codexHome = root + "/codex-home"
        for folder in [bin + "/tui", bin + "/chat", work + "/src", untrusted, claudeStore, codexHome] {
            try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        let files: [(String, String)] = [
            ("claude", SelfTest.standInDispatcher), ("codex", SelfTest.standInDispatcher),
            ("tui/claude", SelfTest.tuiStandIn), ("tui/codex", SelfTest.tuiStandIn),
            ("chat/claude", SelfTest.claudeStandIn), ("chat/codex", SelfTest.codexStandIn),
        ]
        for (name, text) in files {
            let path = bin + "/" + name
            guard (try? text.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return nil }
            chmod(path, 0o755)
        }
        guard (try? "let a = 1\n".write(toFile: editFile, atomically: true, encoding: .utf8)) != nil else { return nil }
        // Every terminal tab this part opens reads this config: the stand-ins first on its PATH, and their stores.
        guard IsolatedShellConfig.prepare(URL(fileURLWithPath: zdot, isDirectory: true)) else { return nil }
        let exports = "export PATH=\(ShellQuote.quote(bin)):$PATH CLAUDE_CONFIG_DIR=\(ShellQuote.quote(claudeStore)) "
            + "CODEX_HOME=\(ShellQuote.quote(codexHome))\n"
        let zshrc = (try? String(contentsOfFile: zdot + "/.zshrc", encoding: .utf8)) ?? ""
        guard (try? (zshrc + exports).write(toFile: zdot + "/.zshrc", atomically: true, encoding: .utf8)) != nil else { return nil }

        // Trust, versions and the Settings default in this part's own suite: the user's are never read or changed.
        suiteName = "nt-selftest-chat-tab-\(getpid())"
        guard let suite = UserDefaults(suiteName: suiteName) else { return nil }
        self.suite = suite
        suite.set(AgentSessionTrust.adding(work, to: []), forKey: AgentSessionTrust.defaultsKey)
        savedTrust = AgentSessionSocket.trustStore
        savedVersions = AgentSessionSocket.versionStore
        savedOpenView = AgentOpenView.defaults
        savedZDOTDIR = TerminalTab.testUserZDOTDIR
        savedSkip = UserDefaults.standard.object(forKey: ConversationHandoff.skipConfirmKey)
        savedLastAgent = UserDefaults.standard.object(forKey: NewChatChoices.lastAgentKey)
        UserDefaults.standard.removeObject(forKey: ConversationHandoff.skipConfirmKey)
        AgentSessionSocket.trustStore = suite
        AgentSessionSocket.versionStore = suite
        AgentOpenView.defaults = suite
        TerminalTab.testUserZDOTDIR = zdot
        savedFront = c.activeTab
        windowsBefore = AppDelegate.shared.controllers
        setChatEnvironment([:])
    }

    func tearDown() {
        if let pending = MCPWriteControl.pending?.window { pending.declineButton.performClick(nil) }
        for window in SelfTest.approvals() { window.declineButton.performClick(nil) }
        // Children a stand-in started that are still there: ended, so nothing outlives the part even when a check failed.
        for line in chatLog("claude") where line.hasPrefix("child ") {
            if let pid = pid_t(line.dropFirst(6)), Self.alive(pid) { kill(pid, SIGKILL) }
        }
        for tab in opened { close(tab) }
        closeRestored()
        for controller in AppDelegate.shared.controllers where !windowsBefore.contains(where: { $0 === controller }) {
            for tab in controller.tabs { controller.remove(tab) }
            controller.window?.close()
        }
        if let savedFront { front(savedFront) }
        ChatEnvironment.testOverlay = nil
        TerminalTab.testUserZDOTDIR = savedZDOTDIR
        AgentSessionSocket.trustStore = savedTrust
        AgentSessionSocket.versionStore = savedVersions
        AgentOpenView.defaults = savedOpenView
        if let savedSkip { UserDefaults.standard.set(savedSkip, forKey: ConversationHandoff.skipConfirmKey) }
        else { UserDefaults.standard.removeObject(forKey: ConversationHandoff.skipConfirmKey) }
        if let savedLastAgent { UserDefaults.standard.set(savedLastAgent, forKey: NewChatChoices.lastAgentKey) }
        else { UserDefaults.standard.removeObject(forKey: NewChatChoices.lastAgentKey) }
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(atPath: root)
    }

    /// `folder` trusted for Claude Code in the part's suite.
    func trust(_ folder: String) {
        let list = AgentSessionTrust.list(in: suite)
        suite.set(AgentSessionTrust.adding(AgentSessionTrust.canonical(folder), to: list), forKey: AgentSessionTrust.defaultsKey)
    }

    // MARK: chats

    /// What every chat agent starts with while the part runs: the stand-ins first on PATH, their stores, Codex's resume,
    /// a version and the Edit's file, plus `extra`.
    func setChatEnvironment(_ extra: [String: String]) {
        var variables: [String: String] = ["CLAUDE_CONFIG_DIR": claudeStore, "CODEX_HOME": codexHome, "STANDIN_CODEX_RESUMES": "1",
                                           "STANDIN_VERSION": "9.9.9", "STANDIN_EDIT_PATH": editFile]
        for (name, value) in extra { variables[name] = value }
        ChatEnvironment.testOverlay = ChatEnvironment.TestOverlay(pathFront: bin, variables: variables)
    }

    /// A chat tab of `agent` in `folder` (the trusted work folder by default), `env` in its agent's environment, once
    /// its agent was started (the environment is read as it starts).
    func chat(_ agent: String, folder: String? = nil, prompt: String? = nil, env: [String: String] = [:]) async -> TerminalTab? {
        setChatEnvironment(env)
        defer { setChatEnvironment([:]) }
        guard let tab = ChatTabs.open(ChatStart(agentID: agent, folder: folder ?? work, prompt: prompt), in: c, select: false) else { return nil }
        opened.append(tab)
        _ = await launched(tab)
        return tab
    }

    /// The chat's engine was made (its environment read), or its start ended.
    @discardableResult
    func launched(_ tab: TerminalTab) async -> Bool {
        await SelfTest.wait(15) { tab.chatHost?.engine != nil || tab.chatHost?.state == .ended }
    }

    func ready(_ tab: TerminalTab, within seconds: Double = 15) async -> Bool {
        await SelfTest.wait(seconds) { tab.chatHost?.state == .ready }
    }

    /// Types `text` into the chat's box and presses Return there.
    func typeAndReturn(_ tab: TerminalTab, _ text: String) {
        guard let box = tab.chatHost?.view.input.textView else { return }
        box.string = ""
        box.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        box.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }

    /// The transcript as read_tab words it.
    func plain(_ tab: TerminalTab) -> String {
        guard let host = tab.chatHost else { return "" }
        let blocks = ChatTranscript.blocks(from: host.session, expanded: host.expanded, thoughtTimes: host.thoughtTimes)
        return ChatTranscript.plainText(blocks, lastLines: 4000)
    }

    /// The blocks the transcript view shows.
    func blocks(_ tab: TerminalTab) -> [ChatBlock] { tab.chatHost?.view.transcript.blocks ?? [] }

    /// The kinds of the last turn's blocks, from its prompt on.
    func kinds(_ tab: TerminalTab) -> [String] {
        let all = blocks(tab)
        let start = all.lastIndex { (block: ChatBlock) -> Bool in
            if case .prompt = block.content { return true }
            return false
        } ?? 0
        return all[start...].map { (block: ChatBlock) -> String in
            switch block.content {
            case .prompt: return "prompt"
            case .message: return "message"
            case .thought: return "thought"
            case .tool: return "tool"
            case .change: return "change"
            case .plan: return "plan"
            case .answered: return "answered"
            case .note: return "note"
            case .turnEnded: return "turnEnded"
            }
        }
    }

    /// `wanted` appears in `all` in this order, others between.
    static func ordered(_ wanted: [String], in all: [String]) -> Bool {
        var rest = wanted[...]
        for kind in all where kind == rest.first { rest = rest.dropFirst() }
        return rest.isEmpty
    }

    func tool(_ tab: TerminalTab, titled words: String) -> ChatTool? {
        guard let host = tab.chatHost else { return nil }
        let all = ChatTranscript.blocks(from: host.session, expanded: host.expanded, thoughtTimes: host.thoughtTimes)
        return all.compactMap { (block: ChatBlock) -> ChatTool? in
            if case .tool(let tool) = block.content, tool.title.contains(words) { return tool }
            return nil
        }.last
    }

    /// The chat was started to go on with conversation `id`, and its session reports that id.
    func reportResumed(_ tab: TerminalTab, _ id: String) -> Bool {
        tab.chatHost?.start.resumeID == id && AgentSessionSocket.reports[tab.id]?.sessionID == id
    }

    static func newID() -> String { UUID().uuidString.lowercased() }

    static func alive(_ pid: pid_t) -> Bool { pid > 0 && kill(pid, 0) == 0 }

    static func key(_ code: UInt16, _ characters: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: code) ?? NSEvent()
    }

    // MARK: the stand-ins' logs

    func chatLog(_ agent: String) -> [String] { SelfTest.standInLog(URL(fileURLWithPath: bin + "/chat/\(agent).log")) }
    func tuiLog(_ agent: String) -> [String] { SelfTest.standInLog(URL(fileURLWithPath: bin + "/tui/\(agent).log")) }

    /// The sessions the chat stand-in started (its "session" lines).
    func sessions(_ agent: String) -> Int { chatLog(agent).filter { $0.hasPrefix("session ") }.count }

    func turns(_ agent: String) -> Int { chatLog(agent).filter { $0.hasPrefix("turn ") }.count }

    /// The claude stand-in's answers to request `id`.
    func answers(_ id: String) -> [String] { chatLog("claude").filter { $0.hasPrefix("answer " + id + " ") } }

    /// The last child a chat stand-in started, or 0.
    func lastChild(_ agent: String) -> pid_t {
        chatLog(agent).last { $0.hasPrefix("child ") }.flatMap { pid_t($0.dropFirst(6)) } ?? 0
    }

    /// The environment the last chat stand-in started with.
    func chatEnvironment(_ agent: String) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: bin + "/chat/\(agent).env") else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:]
    }

    func mcpAnswer() -> String { (try? String(contentsOfFile: bin + "/chat/claude.mcp-answer", encoding: .utf8)) ?? "" }

    /// What list_tabs, called by the chat agent's own MCP server, said of tab `id`'s "you".
    func mcpAnswerYou(_ id: String) -> Bool? {
        guard let line = (try? JSONSerialization.jsonObject(with: Data(mcpAnswer().utf8))) as? [String: Any],
              let result = line["result"] as? [String: Any], let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String,
              let listed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
        let windows = listed["windows"] as? [[String: Any]] ?? []
        let tabs = windows.flatMap { (window: [String: Any]) -> [[String: Any]] in window["tabs"] as? [[String: Any]] ?? [] }
        return tabs.first { $0["id"] as? String == id }?["you"] as? Bool
    }

    func tuiKeys(_ agent: String, since: Int) -> [String] {
        tuiLog(agent).dropFirst(since).filter { (line: String) -> Bool in
            line.hasPrefix("ctrl-c") || line.hasPrefix("line ") || line.hasPrefix("exit ") || line == "quit ignored"
        }
    }

    func tuiStarted(_ agent: String, since: Int, resuming id: String) -> Bool {
        tuiLog(agent).dropFirst(since).contains { $0.hasPrefix("start ") && $0.hasSuffix(" resume \(id)") }
    }

    // MARK: terminal tabs

    func shell() async -> TerminalTab? {
        let tab = c.addTab(directory: work, select: false)
        opened.append(tab)
        guard await SelfTest.wait(20, { tab.status.integrated }) else { return nil }
        return tab
    }

    /// A tab running the terminal interface's stand-in of `agent` with session `id`, once its start-up mark has cleared:
    /// its first frame, drawn later than a keystroke's echo, marks it working until it has been quiet a while.
    func tui(_ agent: String, id: String, env: String = "") async -> TerminalTab? {
        guard let tab = await shell() else { return nil }
        type(tab, "export STANDIN_ID=\(id)" + (env.isEmpty ? "" : " " + env))
        type(tab, agent)
        let ready = await SelfTest.wait(15) {
            tab.status.running && tab.status.kind == .agent && flat(tab).contains("stand-in, new session \(id)")
                && tab.status.state != .working
        }
        return ready ? tab : nil
    }

    func turn(_ tab: TerminalTab, _ words: String) async -> Bool {
        type(tab, words)
        return await SelfTest.wait(10) { flat(tab).contains("Reply to: \(words)") && tab.status.state != .working }
    }

    func type(_ tab: TerminalTab, _ line: String) { tab.view.send(txt: line + "\r") }

    func flat(_ tab: TerminalTab) -> String { SelfTest.flatScreen(tab) }

    /// The tab's screen shows `text`, its whitespace dropped on both sides: a long line wraps mid-word.
    func shows(_ tab: TerminalTab, _ text: String) -> Bool {
        func squeezed(_ words: String) -> String { words.filter { !$0.isWhitespace } }
        return squeezed(flat(tab)).contains(squeezed(text))
    }

    /// The dim note a terminal tab shows now is `text`.
    func showsNote(_ tab: TerminalTab, _ text: String) -> Bool {
        tab.view.subviews.contains { ($0 as? NSTextField)?.stringValue == text }
    }

    func front(_ tab: TerminalTab) {
        guard let owner = MCPControl.controller(of: tab), let index = owner.groups.firstIndex(where: { $0.contains(tab) }) else { return }
        owner.select(index)
    }

    func groupIndex(of tab: TerminalTab) -> Int? { c.groups.firstIndex { $0.contains(tab) } }

    func adopt(_ id: String?) -> TerminalTab? {
        guard let id else { return nil }
        let tab = AppDelegate.shared.controllers.flatMap(\.tabs).first { $0.id.uuidString.lowercased() == id }
        if let tab { opened.append(tab) }
        return tab
    }

    func close(_ tab: TerminalTab) {
        MCPControl.controller(of: tab)?.remove(tab)
    }

    // MARK: menus and sheets

    /// Agents › Continue in Chat (its title follows the tab).
    func handoffItem() -> NSMenuItem? {
        let action = #selector(TerminalWindowController.handOffConversation(_:))
        for top in NSApp.mainMenu?.items ?? [] {
            if let item = top.submenu?.items.first(where: { $0.action == action }) { return item }
        }
        return nil
    }

    func sheetButton(_ title: String) -> NSButton? {
        guard let content = c.window?.attachedSheet?.contentView else { return nil }
        return SelfTestRestore.buttons(in: content).first { $0.title == title }
    }

    func popups(in view: NSView) -> [NSPopUpButton] {
        view.subviews.flatMap { (sub: NSView) -> [NSPopUpButton] in (sub as? NSPopUpButton).map { [$0] } ?? popups(in: sub) }
    }

    // MARK: the handoff

    /// Runs the handoff as ⇧⌘J does, without its question, and waits for how it ends.
    func handOff(_ tab: TerminalTab, within seconds: Double = 25) async -> HandoffRunner.Outcome? {
        var outcome: HandoffRunner.Outcome?
        HandoffRunner.start(tab: tab, confirm: false) { outcome = $0 }
        _ = await SelfTest.wait(seconds) { outcome != nil }
        return outcome
    }

    func refusal(_ outcome: HandoffRunner.Outcome?) -> String? {
        guard case .failure(let failure)? = outcome else { return nil }
        return failure.text
    }

    func opened(_ outcome: HandoffRunner.Outcome?) -> TerminalTab? {
        guard case .success(let done)? = outcome else { return nil }
        return done.tab
    }

    // MARK: MCP

    func call(_ tool: String, _ arguments: [String: Any], within seconds: Double = 30) async -> (text: String, isError: Bool) {
        var result: MCPServer.CallResult?
        MCPControl.call(tool, arguments, caller: nil) { result = $0 }
        _ = await SelfTest.wait(seconds) { result != nil }
        return (result?.text ?? "(no answer)", result?.isError ?? true)
    }

    /// A tool that asks on the Mac, answered there as the user would.
    func asked(_ tool: String, _ arguments: [String: Any], approve: Bool) async -> (asked: Bool, result: (text: String, isError: Bool)) {
        var result: MCPServer.CallResult?
        MCPControl.call(tool, arguments, caller: nil) { result = $0 }
        let asked = await SelfTest.wait(10) { MCPWriteControl.pending?.window != nil || result != nil }
        let window = MCPWriteControl.pending?.window
        if approve { window?.approveButton.performClick(nil) } else { window?.declineButton.performClick(nil) }
        _ = await SelfTest.wait(30) { result != nil }
        return (asked && window != nil, (result?.text ?? "(no answer)", result?.isError ?? true))
    }

    /// list_tabs' entry for tab `id`.
    func listed(_ id: String) async -> [String: Any]? {
        let listed = await call("list_tabs", [:])
        let json = (try? JSONSerialization.jsonObject(with: Data(listed.text.utf8))) as? [String: Any] ?? [:]
        let windows = json["windows"] as? [[String: Any]] ?? []
        let tabs = windows.flatMap { (window: [String: Any]) -> [[String: Any]] in window["tabs"] as? [[String: Any]] ?? [] }
        return tabs.first { $0["id"] as? String == id }
    }

    // MARK: restores

    /// `panes` restored as `kind` would, each a tab of one new window: the tabs made, their chats claimed as they start.
    func restore(_ panes: [SessionSnapshot.Pane], kind: SessionSnapshot.RestoreKind) -> [TerminalTab] {
        let groups = panes.map { SessionSnapshot.Group(root: .pane($0), focused: $0.id) }
        let header = SessionSnapshot.Header(launchID: UUID(), generation: 1, clean: kind != .crash, savedAt: Date())
        let snapshot = SessionSnapshot(header: header, windows: [SessionSnapshot.Window(project: work, groups: groups)])
        let planned = RestorePlanning.plan(snapshot, kind: kind, safeMode: false, quitConsent: false)
        let built = RestoreBuild.build(snapshot, planned: planned, scrollback: [:], savedAt: nil)
        restored += built.windows
        return built.panes.map(\.tab)
    }

    func closeRestored() {
        for controller in restored {
            for tab in controller.tabs { controller.remove(tab) }
            controller.window?.close()
        }
        restored = []
    }
}
#endif
