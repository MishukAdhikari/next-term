#if DEBUG
import AppKit
import NextTermCore

/// An agent session as a chat (plan 047 U6): `nxtrm agent gemini` with the ACP stand-in first on the PATH, started as a
/// chat. The chat is drawn from the session's journal: a reply shows, a permission is the card and its choice answers
/// the session's menu, the composer types into its input line, and the terminal button shows Next Term's text view and
/// back. Every action is called directly, never as a synthetic click.
extension SelfTest {
    static func agentChatChecks() async {
        guard let app = AppDelegate.shared else { return }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), let binary = Bundle.main.executablePath else {
            return note("agent chat: skipped, no /usr/bin/python3 for the stand-in agent")
        }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("nt-agent-chat-\(UUID().uuidString.prefix(8))")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let standIn = folder.appendingPathComponent("gemini")
        try? acpAgentStandIn.write(to: standIn, atomically: true, encoding: .utf8)
        chmod(standIn.path, 0o755)

        let savedSetting = LiveChatView.isOn
        LiveChatView.isOn = true
        let holder = app.openWindow(directory: folder.path)
        guard let tab = holder.tabs.first, let window = holder.window,
              let group = holder.groups.first(where: { $0.contains(tab) }) else {
            LiveChatView.isOn = savedSetting
            return check(false, "agent chat: the window has a tab")
        }
        let pane = group.paneView(tab)
        var journal: String?
        defer {
            pane.setChat(shown: false)
            window.appearance = nil
            LiveChatView.isOn = savedSetting
            window.close()
            try? fm.removeItem(at: folder)
        }
        window.makeKeyAndOrderFront(nil)
        guard await wait(20, { tab.status.integrated }) else { return check(false, "agent chat: the tab starts its shell") }

        // Started as a chat, as the sheet's "Show as chat" and new_tab's view start it.
        AgentChatWatch.started(tab, asChat: true)
        tab.view.send(txt: "PATH=\(ShellQuote.quote(folder.path)):$PATH \(ShellQuote.quote(binary)) --cli agent gemini\r")
        let reported = await wait(15) { AgentSessionSocket.reports[tab.id]?.journal != nil }
        journal = AgentSessionSocket.reports[tab.id]?.journal
        check(reported && journal.map { ACPSessionJournal.isJournal($0, socket: MCPControlServer.shared.path) } == true,
              "agent chat: the session reports its journal, in the app's agent-chat folder", journal ?? "none")
        if let journal {
            let mode = ((try? fm.attributesOfItem(atPath: journal)[.posixPermissions]) as? Int) ?? 0
            check(mode == 0o600, "agent chat: the journal is the user's alone (0600)", String(mode, radix: 8))
        }
        let opened = await wait(5) { holder.refreshPaneHeaders(); return pane.showsChat }
        guard opened, let chat = pane.liveChat, case .session = chat.source else {
            return check(false, "agent chat: a session started as a chat shows its chat once it reports")
        }
        check(true, "agent chat: a session started as a chat shows its chat once it reports")
        let tip = pane.chatStrip.terminalButton.toolTip ?? ""
        check(tip.contains("without Gemini CLI\u{2019}s own screen") && tip.contains("text view"),
              "agent chat: the terminal button says the session has no screen of its agent's own", tip)

        // A prompt from the composer, as soon as the chat shows (the agent may not be ready yet: it is held, never lost):
        // typed into the session's input line, and the reply shows.
        func says(_ words: String) -> Bool { chat.shownBlocks.contains { "\($0.content)".contains(words) } }
        chat.composer.textView.string = "hello there"
        chat.composer.submit()
        let replied = await wait(15) { says("You said: hello there") }
        check(replied && says("hello there") && says("Read README.md"),
              "agent chat: the composer's prompt runs a turn, held until the agent is ready if it wasn't; the prompt, the tool call and the reply show",
              chat.shownBlocks.map { "\($0.content)" }.joined(separator: " | "))
        await pause(0.4)
        check(!chat.showsStateRows, "agent chat: with the turn over, no working row or card shows")

        // A permission: the card from the session's own request; a choice answers the session's menu.
        chat.composer.textView.string = "please rm it"
        chat.composer.submit()
        let started = CACurrentMediaTime()
        let carded = await wait(8) { chat.showsCard }
        let seconds = CACurrentMediaTime() - started
        check(carded && seconds < 2, "agent chat: what the agent writes shows within a second or so (the prompt's paste, its Return, the turn, the card)",
              String(format: "%.2f s", seconds))
        let names: [String] = chat.card.decision?.choices.map { $0.name } ?? []
        check(carded && names == ["Allow once", "Always allow", "Reject"] && chat.card.decision?.title == "Run rm -rf build",
              "agent chat: the permission is the card, with the agent's options and its action",
              "\(names), \(chat.card.decision?.title ?? "no card")")
        check(tab.status.state == TabState.attention, "agent chat: the tab asks, as answer_agent and notifications see it",
              tab.status.state.rawValue)
        await screenshot(window, suffix: "agent-chat-card")
        chat.card.onChoose?(2)
        let rejected = await wait(8) { says("Permission answer: no") && !chat.showsCard }
        check(rejected && tab.status.state != TabState.attention, "agent chat: Reject on the card answers the session's menu",
              chat.shownBlocks.suffix(3).map { "\($0.content)" }.joined(separator: " | "))

        for (name, suffix) in [(NSAppearance.Name.aqua, "agent-chat-light"), (.darkAqua, "agent-chat-dark")] {
            window.appearance = NSAppearance(named: name)
            await pause(0.3)
            await screenshot(window, suffix: suffix)
        }
        window.appearance = nil

        // The terminal button: Next Term's text view of the same session, and back.
        pane.chatStrip.onPick?(false)
        let terminal = await wait(3) { !pane.showsChat && !tab.view.isHidden }
        check(terminal && flatScreen(tab).contains("Permission answer: no"),
              "agent chat: the terminal button shows the session's text view, the same turns in it",
              String(flatScreen(tab).suffix(200)))
        pane.chatStrip.onPick?(true)
        let back = await wait(3) { pane.showsChat }
        // Shown at once: the session's feed stayed while the terminal showed.
        check(back && pane.liveChat.map { chat in chat.shownBlocks.contains { "\($0.content)".contains("Permission answer: no") } } == true,
              "agent chat: the chat button brings the chat back, the whole session in it")

        // switch_view works on these tabs as on a live chat tab.
        var result: MCPServer.CallResult?
        MCPControl.call("switch_view", ["tab_id": tab.id.uuidString.lowercased(), "view": "terminal"], caller: nil) { result = $0 }
        _ = await wait(5) { result != nil }
        check(result?.isError == false && !pane.showsChat, "agent chat: switch_view shows the session's terminal", result?.text ?? "no answer")

        // Ended and closed: the journal goes with the tab.
        tab.view.send(txt: "\u{04}")
        _ = await wait(6) { !tab.status.running }
        holder.remove(tab)
        if let journal {
            check(await wait(3) { !fm.fileExists(atPath: journal) }, "agent chat: the tab's journal is removed when it closes", journal)
        }
    }
}
#endif
