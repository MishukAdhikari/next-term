import AppKit
import NextTermCore
import SwiftTerm

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
            printf '\\033[2J\\033[H%s\\r\\n' "$(printf '%*s' "$cols" '' | tr ' ' '-')"
            printf '\\033[2;%dHstatus 42%%\\r\\n' $((cols - 9))
            ( i=0; while [ -d \(ShellQuote.quote(base)) ]; do
                if [ -e \(ShellQuote.quote(base + "/tick")) ]; then i=$((i+1)); printf 'tick %d\\r\\n' "$i"; fi
                sleep 0.05
            done ) &
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
        // Over the terminal the buttons stay out of the agent's text until the pointer comes to the corner.
        pane.chatStrip.pointerNear(false)
        check(await wait(1) { pane.chatStrip.alphaValue < 0.01 } && !pane.chatStrip.isRevealed,
              "live chat: over the terminal, the buttons are hidden with the pointer away", "alpha \(pane.chatStrip.alphaValue)")
        await screenshot(window, suffix: "-toggle-terminal")
        pane.chatStrip.pointerNear(true)
        check(await wait(1) { pane.chatStrip.alphaValue > 0.99 } && pane.chatStrip.isRevealed,
              "live chat: over the terminal, the buttons fade in with the pointer in the corner", "alpha \(pane.chatStrip.alphaValue)")
        await screenshot(window, suffix: "-toggle-terminal-hover")
        pane.chatStrip.pointerNear(false)

        holder.toggleLiveChat(nil)
        check(await wait(3) { pane.showsChat }, "live chat: View › Show as Chat (⇧⌘J) shows it again")
        check(await wait(1) { pane.chatStrip.alphaValue > 0.99 } && pane.chatStrip.isRevealed,
              "live chat: over the chat, the buttons always show, the pointer away", "alpha \(pane.chatStrip.alphaValue)")
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
        await liveChatQuietAndSmooth(pane: pane, tab: tab, window: window, tickFlag: base + "/tick")
    }

    /// Draws of one terminal view, counted while a self-test watches it (`countDraws`).
    nonisolated(unsafe) private static var drawsCounted = 0
    nonisolated(unsafe) private static weak var drawsOf: NSView?
    nonisolated(unsafe) private static var drawCounterInstalled = false

    /// Counts `view`'s draws from now on: NextTermView gets a draw(_:) of its own that counts and then draws as
    /// SwiftTerm does. For the self-test only; nothing in the app calls it.
    @MainActor static func countDraws(of view: NextTermView) {
        drawsOf = view
        drawsCounted = 0
        guard !drawCounterInstalled else { return }
        drawCounterInstalled = true
        let selector = #selector(NSView.draw(_:))
        guard let inherited = class_getInstanceMethod(TerminalView.self, selector) else { return }
        typealias Draw = @convention(c) (AnyObject, Selector, NSRect) -> Void
        let draw = unsafeBitCast(method_getImplementation(inherited), to: Draw.self)
        let counting: @convention(block) (AnyObject, NSRect) -> Void = { object, rect in
            if object === drawsOf { drawsCounted += 1 }
            draw(object, selector, rect)
        }
        class_addMethod(NextTermView.self, selector, imp_implementationWithBlock(counting), method_getTypeEncoding(inherited))
    }

    /// Small scroll steps over the chat's transcript, up from the end and back: each step's main-thread time (the
    /// scroll and the drawing it causes), in ms, sorted.
    @MainActor static func scrollSteps(_ transcript: ChatTranscriptView, window: NSWindow) -> [Double] {
        let clip = transcript.scrollView.contentView
        let document = transcript.textView
        transcript.scrollToEnd()
        window.displayIfNeeded()
        var steps: [Double] = []
        var y = clip.bounds.origin.y
        let top = -transcript.scrollView.contentInsets.top
        for direction in [-1.0, 1.0] {
            for _ in 0..<150 {
                y = max(top, min(document.frame.height - clip.bounds.height, y + direction * 14))
                let started = CACurrentMediaTime()
                clip.scroll(to: NSPoint(x: 0, y: y))
                transcript.scrollView.reflectScrolledClipView(clip)
                // The layout and drawing the step causes, inside the timing.
                window.contentView?.layoutSubtreeIfNeeded()
                transcript.textView.displayIfNeeded()
                window.displayIfNeeded()
                CATransaction.flush()
                steps.append((CACurrentMediaTime() - started) * 1000)
            }
        }
        return steps.sorted()
    }

    /// The chat as the owner asked for it: smooth and doing no work nobody sees.
    /// - With the chat over it, the terminal view is out of drawing: no draws for 2 s while the stand-in agent prints a
    ///   line every 50 ms behind the chat, its buffer still growing; back on the terminal, it draws and shows the
    ///   latest line.
    /// - Scrolling about 300 blocks in 14 pt steps, idle and with the agent printing behind: each step's main-thread
    ///   time, budget under 8 ms at the 95th percentile, the numbers noted for both runs.
    /// - A new block never pulls back a user who scrolled up, and is followed at the end.
    @MainActor static func liveChatQuietAndSmooth(pane: PaneView, tab: TerminalTab, window: NSWindow, tickFlag: String) async {
        let fm = FileManager.default
        func screen() -> String {
            let terminal = tab.view.getTerminal()
            return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }.joined(separator: "\n")
        }
        func lastTick() -> Int {
            screen().components(separatedBy: "tick ").dropFirst().compactMap { Int($0.prefix { $0.isNumber }) }.max() ?? 0
        }
        pane.setChat(shown: true)
        guard await wait(3, { pane.showsChat }), let chat = pane.liveChat else { return check(false, "live chat: the chat shows for the timing") }
        check(await wait(2) { tab.view.isHidden }, "live chat: under the chat the terminal view is out of drawing, as in a background tab")

        var blocks: [ChatBlock] = []
        for index in 0..<75 {
            blocks.append(ChatBlock(id: "p\(index)", content: .prompt(text: "Question \(index): why does the build take so long on the second run?")))
            blocks.append(ChatBlock(id: "m\(index)", content: .message(markdown: """
                The second run reuses the cache, **but** the module map is rebuilt each time, so the compiler checks every \
                header again. Here is what to change, in `Package.swift` number \(index):

                ```swift
                let settings: [SwiftSetting] = [.unsafeFlags(["-Xfrontend", "-warn-long-function-bodies=200"])]
                ```

                - Keep the flags in one place.
                - Run it twice and compare.
                """, streaming: false)))
            blocks.append(ChatBlock(id: "c\(index)", content: .change(ChatChange(toolID: "c\(index)", path: "Sources/App/File\(index).swift",
                                                                                 added: index % 9 + 1, removed: index % 4, created: false))))
            blocks.append(ChatBlock(id: "n\(index)", content: .note(text: "Note \(index): the cache was warm.", tone: .info)))
        }
        // The session's own blocks first, then the feed is set aside, so the 300 blocks stay what the chat shows
        // (a feed arriving late would replace them with the session's few, and the timing would scroll nothing).
        _ = await wait(3) { chat.shownBlocks.count >= 6 }
        guard case .live(let feed) = chat.source else { return }
        feed.onChange = nil
        defer {
            feed.onChange = { [weak chat] _, _ in chat?.refresh() }
            chat.refresh()
        }
        let transcript = chat.transcript
        var started = CACurrentMediaTime()
        transcript.show(blocks, sizes: LiveChatView.sizes, offersTerminal: true)
        window.displayIfNeeded()
        let loadMs = (CACurrentMediaTime() - started) * 1000
        await pause(0.3)
        let clip = transcript.scrollView.contentView
        func atBottom() -> Bool { clip.bounds.maxY >= transcript.textView.frame.height - 24 }
        check(atBottom(), "live chat: 300 blocks load scrolled to the end", "clip \(clip.bounds), document \(transcript.textView.frame.height)")

        func summary(_ steps: [Double]) -> (p95: Double, words: String) {
            let median = steps[steps.count / 2], p95 = steps[Int(Double(steps.count) * 0.95)], worst = steps.last ?? 0
            return (p95, String(format: "median %.2f ms, 95th %.2f ms, worst %.2f ms", median, p95, worst))
        }
        let room = transcript.textView.frame.height - clip.bounds.height
        check(room > 150 * 14 && transcript.textView.string.count > 20_000,
              "live chat: the timing has 300 blocks to scroll through", "room \(room), characters \(transcript.textView.string.count)")
        let idle = summary(scrollSteps(transcript, window: window))

        // The agent prints a line every 50 ms behind the chat.
        countDraws(of: tab.view)
        let ticksBefore = lastTick()
        fm.createFile(atPath: tickFlag, contents: nil)
        let busyStarted = Date()
        _ = await wait(3) { lastTick() > ticksBefore }
        let busy = summary(scrollSteps(transcript, window: window))
        await pause(max(0, 2 - Date().timeIntervalSince(busyStarted)))
        let ticksAfter = lastTick()
        let drawsHidden = drawsCounted

        let numbers = String(format: "300 blocks loaded in %.1f ms; 300 steps of 14 pt; idle: ", loadMs) + idle.words
            + "; agent printing every 50 ms: " + busy.words
        note("live chat scrolling: " + numbers)
        check(idle.p95 < 8, "live chat: scrolling 300 blocks stays under 8 ms a step (95th percentile), idle", numbers)
        check(busy.p95 < 8, "live chat: scrolling 300 blocks stays under 8 ms a step (95th percentile) with the agent printing", numbers)
        check(drawsHidden == 0 && ticksAfter >= ticksBefore + 20,
              "live chat: under the chat the terminal draws nothing for 2 s while its screen keeps up with the agent",
              "draws \(drawsHidden), ticks \(ticksBefore) → \(ticksAfter)")

        // Scrolled up, a new block never pulls the view back; at the end it follows.
        clip.scroll(to: NSPoint(x: 0, y: -transcript.scrollView.contentInsets.top))
        transcript.scrollView.reflectScrolledClipView(clip)
        let before = clip.bounds.origin.y
        blocks.append(ChatBlock(id: "late1", content: .message(markdown: "One more, while you read above.", streaming: false)))
        transcript.show(blocks, sizes: LiveChatView.sizes, offersTerminal: true)
        check(abs(clip.bounds.origin.y - before) < 0.5, "live chat: a new block leaves a user who scrolled up where they are",
              "from \(before) to \(clip.bounds.origin.y)")
        transcript.scrollToEnd()
        blocks.append(ChatBlock(id: "late2", content: .message(markdown: "And one at the end.", streaming: false)))
        started = CACurrentMediaTime()
        transcript.show(blocks, sizes: LiveChatView.sizes, offersTerminal: true)
        let appendMs = (CACurrentMediaTime() - started) * 1000
        check(atBottom(), "live chat: at the end, a new block is followed", String(format: "append %.2f ms", appendMs))

        // Back on the terminal: it draws at once and shows the agent's latest line.
        try? fm.removeItem(atPath: tickFlag)
        await pause(0.2)
        let latest = lastTick()
        pane.setChat(shown: false)
        check(await wait(2) { !tab.view.isHidden && drawsCounted > drawsHidden } && screen().contains("tick \(latest)"),
              "live chat: back on the terminal it draws at once, showing the agent's latest line",
              "hidden \(tab.view.isHidden), draws \(drawsCounted - drawsHidden), latest tick \(latest)")
        drawsOf = nil
        await screenshot(window, suffix: "-terminal-after-chat")
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
