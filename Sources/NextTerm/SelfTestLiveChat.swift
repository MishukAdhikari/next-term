import AppKit
import NextTermCore

/// The live chat view of an agent tab (plan 041), with a stand-in Command Code in a home of the test's own: a script named
/// command-code that writes a session file, turns bracketed paste on and writes what it reads to a file. Checks:
/// - the terminal and chat buttons show for that tab and not for a plain shell;
/// - the chat shows the session's items, and an appended line within a second or two;
/// - the composer types into the agent as one paste and Return;
/// - the agent keeps running under the chat, and the terminal comes back with the keyboard;
/// - the setting off takes the buttons and the chat away;
/// - the layout (plan 041 follow-up): nothing wider than the view and no sideways scroller, even with a 400-character
///   unbroken line; the conversation and the composer share their leading edge; hidden rows leave no gap above the
///   composer; the floating terminal and chat buttons take no room;
/// - screenshots of the chat, narrow and wide, and of the terminal with the floating buttons.
extension SelfTest {
    static func liveChatChecks() async {
        guard let app = AppDelegate.shared else { return }
        let fm = FileManager.default
        let base = canonicalPath(NSTemporaryDirectory()) + "/nt-livechat-\(getpid())"
        let home = base + "/home", project = base + "/project", bin = base + "/bin"
        try? fm.removeItem(atPath: base)
        for folder in [home + "/.commandcode/projects/p", project, bin] {
            try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        let session = home + "/.commandcode/projects/p/s1.jsonl", got = base + "/got"
        func line(_ object: [String: Any]) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self) + "\n"
        }
        let lines = [
            line(["type": "session", "version": 3, "id": "s1", "cwd": project]),
            line(["type": "message", "message": ["role": "user", "content": [["type": "text", "text": "Tidy the readme"]]]]),
            line(["type": "message", "message": ["role": "assistant", "content": [
                ["type": "thinking", "thinking": "Read it first."],
                ["type": "tool_use", "id": "r1", "name": "read_file", "input": ["file_path": "README.md"]]]]]),
            line(["type": "message", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "r1",
                                                                              "content": [["type": "text", "text": "# Title\nold words"]]]]]]),
            line(["type": "message", "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "e1", "name": "edit_file",
                 "input": ["file_path": "README.md", "old_string": "old words", "new_string": "new words\nand a second line"]]]]]),
            line(["type": "message", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "e1", "content": "Edited."]]]]),
            line(["type": "message", "message": ["role": "assistant", "content": [
                ["type": "text", "text": "Done. The readme now says **new words**, and:\n\n```sh\nnpm test\n```"]]]]),
        ]
        // The stand-in agent: the session file as it starts, then a program that takes pastes and keeps them.
        let script = """
            #!/bin/sh
            cat > \(ShellQuote.quote(session)) <<'NT_EOF'
            \(lines.joined())NT_EOF
            cols=$(tput cols 2>/dev/null || echo 80)
            printf '\033[2J\033[H%s\r\n' "$(printf '%*s' "$cols" '' | tr ' ' '-')"
            printf '\033[2;%dHstatus 42%%\r\n' $((cols - 9))
            stty raw -echo
            printf '\\033[?2004h'
            exec cat > \(ShellQuote.quote(got))
            """
        try? script.write(toFile: bin + "/command-code", atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin + "/command-code")

        let savedHome = LiveChatWatch.home, savedSetting = LiveChatView.isOn
        LiveChatWatch.home = home
        LiveChatView.isOn = true
        let holder = app.openWindow(directory: project)
        guard let tab = holder.tabs.first, let window = holder.window,
              let group = holder.groups.first(where: { $0.contains(tab) }) else { return check(false, "live chat: the window has a tab") }
        let pane = group.paneView(tab)
        defer {
            pane.setChat(shown: false)
            tab.view.send(txt: "\u{03}")
            LiveChatWatch.home = savedHome
            LiveChatView.isOn = savedSetting
            window.close()
            try? fm.removeItem(atPath: base)
        }
        window.makeKeyAndOrderFront(nil)
        _ = await wait(20) { tab.status.integrated }
        holder.refreshPaneHeaders()
        check(pane.chatStrip.isHidden, "live chat: a plain shell shows no chat buttons")

        tab.view.send(txt: ShellQuote.quote(bin + "/command-code") + "\r")
        _ = await wait(10) { fm.fileExists(atPath: got) && tab.view.getTerminal().bracketedPasteMode }
        check(await wait(5) { holder.refreshPaneHeaders(); return !pane.chatStrip.isHidden },
              "live chat: a Command Code tab shows the terminal and chat buttons, floating in its corner",
              "agent \(String(describing: tab.localAgent)), program \(tab.status.program)")
        let terminalTop = tab.view.frame.maxY

        pane.chatStrip.chatButton.performClick(nil)
        guard await wait(3, { pane.showsChat }), let chat = pane.liveChat else { return check(false, "live chat: the chat button shows the chat") }
        let shown = await wait(5) { chat.shownBlocks.count >= 6 } // prompt, thought, two tools, the change, the reply
        let words = chat.shownBlocks.map { "\($0.content)" }.joined(separator: " | ")
        check(shown && words.contains("Tidy the readme") && words.contains("read_file(README.md)") && words.contains("new words"),
              "live chat: the chat shows the session: the prompt, reasoning, tool rows, the edit and the reply", words)
        check(chat.shownBlocks.contains { if case .change(let change) = $0.content { return change.added == 2 && change.removed == 1 }; return false },
              "live chat: the edit shows as a change with its counts")
        check(window.firstResponder === chat.composer.textView, "live chat: the composer has the keyboard")

        // Appended by the agent as it works: shown within a second or two.
        if let handle = FileHandle(forWritingAtPath: session) {
            handle.seekToEndOfFile()
            handle.write(Data(line(["type": "message", "message": ["role": "assistant", "content": [["type": "text", "text": "One more thing."]]]]).utf8))
            try? handle.close()
        }
        check(await wait(3) { chat.shownBlocks.contains { "\($0.content)".contains("One more thing.") } },
              "live chat: a line the agent appends shows within a second or two")
        await screenshot(window, suffix: "live-chat")

        // Layout: a 400-character unbroken line, as code and as a word, wraps inside the view at any width.
        let unbroken = String(repeating: "abcdefghij/", count: 37).prefix(400)
        if let handle = FileHandle(forWritingAtPath: session) {
            handle.seekToEndOfFile()
            handle.write(Data(line(["type": "message", "message": ["role": "assistant", "content": [
                ["type": "text", "text": "A long one: \(unbroken)\n\n```\n\(unbroken)\n```"]]]]).utf8))
            try? handle.close()
        }
        _ = await wait(3) { chat.shownBlocks.contains { "\($0.content)".contains(String(unbroken.prefix(40))) } }
        let savedFrame = window.frame
        for (width, suffix) in [(520.0, "chat-narrow"), (1400.0, "chat-wide")] {
            window.setContentSize(NSSize(width: width, height: window.contentLayoutRect.height))
            window.contentView?.layoutSubtreeIfNeeded()
            chat.transcript.scrollToEnd()
            await pause(0.3)
            let fits = liveChatFits(chat)
            check(fits.ok, "live chat: at \(Int(width)) pt nothing is wider than the view and no sideways scroller shows", fits.detail)
            await screenshot(window, suffix: "-" + suffix)
        }
        window.setFrame(savedFrame, display: true)
        window.contentView?.layoutSubtreeIfNeeded()

        let composerX = chat.composer.convert(chat.composer.bounds, to: chat).minX
        let textX = chat.transcript.convert(NSPoint(x: chat.transcript.columnLeading, y: 0), to: chat).x
        check(abs(composerX - textX) <= 1, "live chat: the conversation and the composer share their leading edge",
              "text \(textX), composer \(composerX)")
        if !chat.showsStateRows {
            let composerTop = chat.composer.convert(chat.composer.bounds, to: chat).maxY
            let gap = chat.transcript.frame.minY - composerTop
            check(gap >= 0 && gap <= 12, "live chat: with no rows showing, the composer sits right under the conversation",
                  "gap \(gap)")
        }
        check(abs(chat.frame.maxY - pane.header.frame.minY) < 0.5 && !pane.chatStrip.isHidden,
              "live chat: the floating terminal and chat buttons take no room; the chat starts at the pane's top",
              "chat top \(chat.frame.maxY), content top \(pane.header.frame.minY)")

        // The composer types into the agent's own prompt: one paste, then Return.
        chat.composer.text = "Also fix the title"
        chat.composer.submit()
        func read() -> String { (try? String(contentsOfFile: got, encoding: .utf8)) ?? "" }
        check(await wait(5) { read().contains("\u{1b}[200~Also fix the title\u{1b}[201~\r") },
              "live chat: the composer types into the agent as one paste and Return", read().debugDescription)
        check(tab.status.running && tab.view.frame.maxY == terminalTop, "live chat: the agent keeps running under the chat, its terminal untouched")

        pane.chatStrip.terminalButton.performClick(nil)
        check(await wait(3) { !pane.showsChat } && window.firstResponder === tab.view,
              "live chat: the terminal button brings the terminal back with the keyboard")
        await screenshot(window, suffix: "-toggle-terminal")

        holder.toggleLiveChat(nil)
        check(await wait(3) { pane.showsChat }, "live chat: View › Show as Chat (⇧⌘J) shows it again")
        LiveChatView.isOn = false
        holder.liveChatSettingChanged()
        check(await wait(3) { !pane.showsChat && pane.chatStrip.isHidden }, "live chat: turned off in Settings, the chat and its buttons go")
        LiveChatView.isOn = true
        holder.liveChatSettingChanged()
        check(!pane.chatStrip.isHidden, "live chat: turned on again, the buttons come back")

        // MCP (plan 041 U5): list_tabs gives the view, switch_view changes it, a plain shell's tab is refused.
        let id = tab.id.uuidString.lowercased()
        func call(_ tool: String, _ arguments: [String: Any]) async -> MCPServer.CallResult {
            await withCheckedContinuation { done in MCPControl.call(tool, arguments, caller: nil) { done.resume(returning: $0) } }
        }
        let toChat = await call("switch_view", ["tab_id": id, "view": "chat"])
        check(!toChat.isError && toChat.text.contains("\"chat\"") && pane.showsChat, "live chat: switch_view shows the chat", toChat.text)
        let listed = await call("list_tabs", [:])
        check(listed.text.contains("\"view\" : \"chat\"") || listed.text.contains("\"view\":\"chat\""),
              "live chat: list_tabs gives the tab's view")
        let toTerminal = await call("switch_view", ["tab_id": id, "view": "terminal"])
        check(!toTerminal.isError && !pane.showsChat, "live chat: switch_view brings the terminal back", toTerminal.text)
        let other = holder.tabs.count > 1 ? holder.tabs[1] : nil
        if let other {
            let refused = await call("switch_view", ["tab_id": other.id.uuidString.lowercased(), "view": "chat"])
            check(refused.isError, "live chat: switch_view refuses a tab with no chat view", refused.text)
        }
    }
}

extension SelfTest {
    /// Whether the chat's content stays inside it: the transcript's text no wider than its clip view, and no visible
    /// sideways scroller anywhere in the chat. The detail names what is wider, for a failure.
    @MainActor static func liveChatFits(_ chat: LiveChatView) -> (ok: Bool, detail: String) {
        var problems: [String] = []
        let clip = chat.transcript.scrollView.contentView.bounds.width
        let document = chat.transcript.textView.frame.width
        if document > clip + 0.5 { problems.append("transcript document \(document) > clip \(clip)") }
        if let layout = chat.transcript.textView.layoutManager, let container = chat.transcript.textView.textContainer {
            let used = layout.usedRect(for: container).maxX + chat.transcript.textView.textContainerOrigin.x
            if used > clip + 0.5 { problems.append("text reaches \(used) > clip \(clip)") }
        }
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, scroll.hasHorizontalScroller, scroll.horizontalScroller?.isHidden == false {
                problems.append("sideways scroller in \(type(of: scroll.documentView as Any))")
            }
            let frame = view.convert(view.bounds, to: chat)
            if view !== chat, !(view.superview is NSClipView), frame.maxX > chat.bounds.maxX + 0.5 || frame.minX < -0.5 {
                problems.append("\(type(of: view)) spans \(frame.minX)–\(frame.maxX) of \(chat.bounds.width)")
            }
            view.subviews.forEach(walk)
        }
        walk(chat)
        return (problems.isEmpty, problems.prefix(6).joined(separator: "; "))
    }
}
