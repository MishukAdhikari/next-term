import AppKit
import NextTermCore

/// The tab tools on a chat tab (plan 037 U7, KTD14): the same fields a session tab gives, read from the chat's host
/// instead of a screen, and the same tools acting on the host instead of typing into a terminal. MCPControl asks here
/// first, one line per tool, once it has found the tab. Main thread.
enum ChatTabMCP {
    /// The keys `press_keys` takes in a chat tab, said when another one is asked for.
    static let keysRefusal = "A chat tab takes enter, escape, ctrl+c, up, down and digits."

    // MARK: reading

    /// read_tab's and wait_for_tab's `screen` (the transcript as plain text, its last `lines` lines) and `input` (the
    /// draft), masked as a terminal's are; nil for a terminal tab.
    static func screenFields(_ tab: TerminalTab, lines: Int) -> [String: Any]? {
        guard let host = tab.chatHost else { return nil }
        let blocks = ChatTranscript.blocks(from: host.session, expanded: host.expanded, thoughtTimes: host.thoughtTimes)
        return ["screen": MCPControl.field(ChatTranscript.plainText(blocks, lastLines: lines)), "input": MCPControl.field(host.draft)]
    }

    /// The menu under a chat tab's question: its card's choices, while the card is the question the tab reports. This
    /// is what list_tabs and read_tab list as `choices`, what a notice's buttons offer, and what answer_agent picks from.
    static func fieldMenu(_ tab: TerminalTab, question: String) -> AgentMenu? {
        guard let decision = tab.chatHost?.decision, decision.question == question else { return nil }
        return decision.menu(question: question)
    }

    // MARK: typing

    /// send_to_tab on a chat tab: with `submit` the text goes as a prompt (refused while a turn runs or a card is open),
    /// without it the text joins the draft. False for a terminal tab, which MCPControl types into.
    static func sendToTab(_ tab: TerminalTab, _ arguments: [String: Any], reply: @escaping MCPControl.Reply) -> Bool {
        guard let host = tab.chatHost else { return false }
        let text = arguments["text"] as? String ?? ""
        let submit = arguments["submit"] as? Bool ?? true
        guard !text.isEmpty || submit else { reply(MCPControl.fail("Nothing to type.")); return true }
        let id = tab.id.uuidString.lowercased()
        guard submit else {
            host.draft += text
            host.view.refresh()
            SecretRequests.tabGotInput(tab.id)
            MCPControl.driven.insert(tab.id)
            reply(MCPControl.ok(["id": id, "typed": text.count, "submitted": false]))
            return true
        }
        // With a draft waiting, the text sent is the draft and the text, as typing it after the draft and Return would be.
        let prompt = host.draft.isEmpty ? text : host.draft + text
        if let refusal = sendRefusal(host) { reply(MCPControl.fail(refusal)); return true }
        switch host.send(prompt) {
        case .sent:
            host.draft = ""
            host.view.refresh()
            MCPControl.sent(to: tab)
            reply(MCPControl.ok(["id": id, "typed": text.count, "submitted": true]))
        case .terminalOnly(let word):
            reply(MCPControl.fail(ConversationHandoff.terminalOnlyLine(word, shortcut: nil) + ": nothing was sent. continue_in opens it there."))
        case .refused(let words):
            reply(MCPControl.fail(words))
        }
        return true
    }

    /// A Reply from a notice, or any line MCPControl types into a chat tab: a prompt, or the draft. False for a terminal
    /// tab.
    static func type(_ text: String, into tab: TerminalTab, submit: Bool) -> Bool {
        guard let host = tab.chatHost else { return false }
        if !submit {
            host.draft += text
        } else if sendRefusal(host) == nil, host.send(host.draft + text) == .sent {
            host.draft = ""
            MCPControl.sent(to: tab)
        }
        host.view.refresh()
        return true
    }

    /// Why a prompt can't go now, in MCP's words (KTD14), or nil.
    private static func sendRefusal(_ host: ChatTabHost) -> String? {
        switch host.state {
        case .working: return host.agentName + " is working; wait_for_tab, then send."
        case .asking: return host.agentName + " is asking you something; answer_agent answers it."
        default: return nil
        }
    }

    /// press_keys on a chat tab (KTD14): enter sends the draft or picks the card's highlighted choice; escape and ctrl+c
    /// stop the turn or reject the card; up and down move the card's highlight; a digit picks that choice. Every key is
    /// checked before any acts. False for a terminal tab.
    static func pressKeys(_ tab: TerminalTab, _ arguments: [String: Any], reply: @escaping MCPControl.Reply) -> Bool {
        guard let host = tab.chatHost else { return false }
        let names = arguments["keys"] as? [String] ?? []
        guard !names.isEmpty, names.count <= 20 else { reply(MCPControl.fail("Give 1 to 20 keys.")); return true }
        let known: Set<String> = ["enter", "escape", "ctrl+c", "up", "down"]
        for name in names where !known.contains(name.lowercased()) && digit(name) == nil {
            reply(MCPControl.fail("\u{201C}\(name)\u{201D} isn\u{2019}t one: " + keysRefusal))
            return true
        }
        for (index, name) in names.enumerated() {
            if let problem = press(name.lowercased(), in: host) {
                reply(MCPControl.fail("Stopped after \(index) of \(names.count) keys: " + problem))
                return true
            }
        }
        MCPControl.sent(to: tab)
        host.view.refresh()
        reply(MCPControl.ok(["id": tab.id.uuidString.lowercased(), "pressed": names]))
        return true
    }

    private static func digit(_ name: String) -> Int? {
        guard name.count == 1, let value = Int(name), (1...9).contains(value) else { return nil }
        return value
    }

    /// One key in a chat tab; why it did nothing, or nil.
    private static func press(_ key: String, in host: ChatTabHost) -> String? {
        let card = host.decision
        switch key {
        case "enter":
            if let card { host.choose(card.highlighted); return nil }
            guard !host.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            if let refusal = sendRefusal(host) { return refusal }
            switch host.send(host.draft) {
            case .sent: host.draft = ""; return nil
            case .terminalOnly(let word): return ConversationHandoff.terminalOnlyLine(word, shortcut: nil) + "; the draft stays."
            case .refused(let words): return words
            }
        case "escape", "ctrl+c":
            if let card, let reject = card.rejectIndex { host.choose(reject) } else { host.stop() }
            return nil
        case "up", "down":
            if card != nil { host.moveHighlight(key == "up" ? -1 : 1) }
            return nil
        default:
            guard let number = digit(key) else { return keysRefusal }
            guard let card else { return "no card is open, so \(number) picks nothing." }
            guard number <= card.choices.count else { return "the card has \(card.choices.count) choices." }
            host.choose(number - 1)
            return nil
        }
    }

    // MARK: answering

    /// answer_agent on a chat tab: the question id checked as for any tab, then the card's choice picked through the
    /// host, which asks on the Mac first for Allow always. False for a terminal tab.
    static func answerAgent(_ tab: TerminalTab, _ arguments: [String: Any], reply: @escaping MCPControl.Reply) -> Bool {
        guard let host = tab.chatHost else { return false }
        guard let given = arguments["question_id"] as? String, !given.isEmpty else {
            reply(MCPControl.fail("Give question_id: the one that came with the question from list_tabs, read_tab or wait_for_tab."))
            return true
        }
        let choice = arguments["choice"], answer = arguments["answer"]
        if choice != nil && answer != nil { reply(MCPControl.fail("Give choice or answer, not both.")); return true }
        if let choice, MCPServer.isBoolean(choice) || !(choice is Int) { reply(MCPControl.fail("choice must be a whole number.")); return true }
        if let answer, !(answer is String) { reply(MCPControl.fail("answer must be text.")); return true }
        guard let question = tab.status.question, let current = MCPControl.questionID(tab), let card = host.decision else {
            reply(MCPControl.fail("That tab is not asking anything now (state: \(tab.status.state.rawValue)); nothing was picked. read_tab shows its transcript."))
            return true
        }
        guard given == current else {
            reply(MCPControl.fail("That question is gone; nothing was picked. The tab now asks \u{201C}\(MCPControl.field(question))\u{201D} (question_id \(current)): answer that one only if you mean to."))
            return true
        }
        let menu = card.menu(question: question)
        let index: Int
        switch menu.index(choice: choice as? Int, answer: answer as? String) {
        case .failure(let error): reply(MCPControl.fail(error.text + " Nothing was picked.")); return true
        case .success(let found): index = found
        }
        let label = MCPControl.field(menu.choices[index])
        let needsMac = card.choices[index].needsMac
        MCPControl.sent(to: tab)
        host.choose(index)
        host.view.refresh()
        var info: [String: Any] = ["id": tab.id.uuidString.lowercased(), "answered": label, "choice": index + 1,
                                   "state_after": tab.status.state.rawValue]
        if let after = MCPControl.questionID(tab) {
            if after == current {
                info["note"] = needsMac
                    ? "\u{201C}\(label)\u{201D} is asked on the Mac first; the card stays open until the user answers there."
                    : "The question is still open; read_tab shows what the agent did with the answer."
            } else {
                info["question_after"] = tab.status.question.map(MCPControl.field)
                info["question_id_after"] = after
            }
        }
        reply(MCPControl.ok(info))
        return true
    }

    // MARK: opening

    /// new_tab's chat (plan 037 R19, R18): `agent_session` always opens a chat tab, and a bare `claude` or `codex` does
    /// when Settings says to open it in Chat. The prompt is the chat's first. False when the call opens a terminal tab,
    /// which MCPControl goes on with.
    static func newTab(_ arguments: [String: Any], directory: String, title: String?, caller: TerminalTab?,
                       reply: @escaping MCPControl.Reply) -> Bool {
        let prompt = (arguments["prompt"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let command = (arguments["command"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        var start: ChatStart
        if let name = arguments["agent_session"] as? String {
            if command != nil { reply(MCPControl.fail("Give command or agent_session, not both.")); return true }
            switch ACPSessionTabs.agent(named: name) {
            case .failure(let refusal): reply(MCPControl.fail(refusal.text)); return true
            case .success(let agent): start = ChatStart(agentID: agent.id, folder: directory, prompt: prompt)
            }
        } else if let command, let chat = AgentOpenView.newTabStart(command: command, prompt: prompt, folder: directory,
                                                                    defaults: AgentOpenView.defaults) {
            start = chat
        } else {
            return false
        }
        start.title = title
        let tab: TerminalTab
        let controller: TerminalWindowController
        if let besideID = arguments["split_beside"] {
            guard let beside = (besideID as? String).flatMap(MCPControl.tab(withID:)), let owner = MCPControl.controller(of: beside) else {
                reply(MCPControl.fail("No tab with that split_beside id; list_tabs shows them."))
                return true
            }
            let down = (arguments["direction"] as? String) == "down"
            guard let pane = ChatTabs.open(start, in: owner, splitBeside: beside, vertical: !down, select: false, byAgent: true) else {
                reply(MCPControl.fail("Could not split that tab."))
                return true
            }
            (tab, controller) = (pane, owner)
        } else {
            let ownWindow: TerminalWindowController? = arguments["new_window"] as? Bool == true ? nil : caller.flatMap { MCPControl.controller(of: $0) }
            let owner = MCPControl.window(for: directory, else: ownWindow).controller
            guard let opened = ChatTabs.open(start, in: owner, select: false, byAgent: true) else {
                reply(MCPControl.fail("Could not open a chat tab there."))
                return true
            }
            (tab, controller) = (opened, owner)
        }
        let arrived = controller.presentForAgent(arguments["split_beside"] == nil ? tab : nil)
        MCPControl.driven.insert(tab.id)
        if arguments["hand_off"] as? Bool != true { tab.openedBy = caller?.id }
        MCPTabOpeners.record(tab, openedBy: caller)
        if start.prompt != nil { MCPControl.sent(to: tab) } // wait_for_tab waits for the first turn
        controller.refresh()
        var info: [String: Any] = ["id": tab.id.uuidString.lowercased(), "directory": tab.directory,
                                   "project": (controller.project as Any?) ?? NSNull(), "selected": arrived.selected, "kind": "chat"]
        if let note = arrived.note { info["note"] = note }
        reply(MCPControl.ok(info))
        return true
    }
}
