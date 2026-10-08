import AppKit
import NextTermCore

/// Tab completion. Keys go through the window (`window.sendEvent`) as the keyboard's do, since a view's own
/// `keyDown` would skip where Tab is caught; an agent's keys go through `nxtrm mcp`. Each part keeps to a time
/// budget and says how long it took.
extension SelfTest {
    static func completionChecks(_ c: TerminalWindowController) async {
        let saved = UserDefaults.standard.object(forKey: CompletionPreferences.previewKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: CompletionPreferences.previewKey) }
            else { UserDefaults.standard.removeObject(forKey: CompletionPreferences.previewKey) }
        }
        await completionKeyChecks(c)
    }

    /// A key down sent through the window, as AppKit hands it over.
    static func pressKey(_ window: NSWindow, _ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
        window.sendEvent(event)
    }

    /// The prompt's line as drawn, for checks on what Tab did to it.
    static func promptLine(_ tab: TerminalTab) -> String { tab.screenTail(2).last ?? "" }

    /// Step 1: a real Tab at a zsh prompt goes to the hook as the private key, and zsh's own completion answers;
    /// everything else gets a plain Tab, as before.
    private static func completionKeyChecks(_ c: TerminalWindowController) async {
        let started = Date()
        defer { note("Tab completion, keys: \(String(format: "%.1f", Date().timeIntervalSince(started))) s (budget 90 s)") }
        guard let window = c.window as? TerminalWindow else { return check(false, "Tab completion: a terminal window") }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-complete-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // The switch is read as a shell starts: a tab opened with it on loads the hook.
        CompletionPreferences.isOn = true
        let tab = c.addTab(directory: dir.path)
        defer { c.remove(tab) }
        _ = await wait(20) { tab.status.integrated }
        let session = tab.completion
        check(await wait(5) { session.state.isArmed }, "Tab completion: the hook arms a zsh tab at its prompt", "\(session.state.phase)")
        guard session.state.isArmed else { return }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        c.show(tab)
        _ = window.makeFirstResponder(tab.view)
        let isKey = await wait(3) { NSApp.isActive && NSApp.keyWindow === window && window.firstResponder === tab.view }
        check(isKey, "Tab completion: the window has the keyboard for real key events")
        guard isKey else { return }
        func tabKey() { pressKey(window, "\t", code: 48) }
        func clearLine() async {
            tab.view.send(txt: "\u{3}")
            _ = await wait(3) { session.state.isArmed }
        }

        // A real Tab: the private key, then zsh's own completion (the hook steps back to it in this step).
        tab.view.send(txt: "echo /Syst")
        await pause(0.3)
        tabKey()
        if case .privateKey(let id) = session.lastTab {
            check(await wait(3) { session.lastDone?.id == id || session.reports > 0 }, "Tab completion: a real Tab goes to the hook as the private key",
                  "\(session.state.phase)")
        } else {
            check(false, "Tab completion: a real Tab goes to the hook as the private key", "\(session.lastTab)")
        }
        check(await wait(3) { promptLine(tab).contains("echo /System/") }, "and zsh's own completion answers it", promptLine(tab))
        await clearLine()

        // Scrolled back, Tab jumps to the bottom first.
        tab.view.send(txt: "seq 1 300\r")
        _ = await wait(5) { session.state.isArmed && !tab.status.running }
        if tab.view.canScroll {
            tab.view.scroll(toPosition: 0)
            tabKey()
            check(tab.view.scrollPosition == 1, "Tab completion: Tab while scrolled back jumps to the bottom", "\(tab.view.scrollPosition)")
            _ = await wait(2) { !session.state.holding }
            await clearLine()
        }

        // A program in front gets Tab itself (AE5).
        let got = dir.appendingPathComponent("key")
        tab.view.send(txt: "read -rk 1 x; printf %d \"'$x\" > \(got.path)\r")
        _ = await wait(3) { tab.status.running }
        await pause(0.3)
        let before = session.lastTab
        tabKey()
        check(await wait(3) { (try? String(contentsOf: got, encoding: .utf8)) == "9" } && session.lastTab == before,
              "Tab completion: a program that runs gets Tab itself", (try? String(contentsOf: got, encoding: .utf8)) ?? "nothing")
        _ = await wait(3) { session.state.isArmed }

        // Text an input method is composing keeps Tab.
        tab.view.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = session.lastTab
        if tab.view.hasMarkedText() {
            tabKey()
            check(session.lastTab == marked, "Tab completion: Tab with marked text is not caught", "\(session.lastTab)")
        }
        tab.view.unmarkText()
        await clearLine()

        // The alternate screen keeps Tab: `less`, and a screen switched while the prompt is armed.
        tab.view.send(txt: "less /etc/hosts\r")
        _ = await wait(3) { tab.view.getTerminal().isCurrentBufferAlternate }
        let inLess = session.lastTab
        tabKey()
        check(session.lastTab == inLess && tab.status.running, "Tab completion: Tab in `less` goes to less")
        tab.view.send(txt: "q")
        _ = await wait(3) { session.state.isArmed }
        tab.view.feed(text: "\u{1b}[?1049h")
        let alternate = session.lastTab
        tabKey()
        check(session.lastTab == alternate, "Tab completion: Tab on the alternate screen is not caught", "\(session.lastTab)")
        tab.view.feed(text: "\u{1b}[?1049l")
        await clearLine()

        // Ctrl-Tab still cycles tabs.
        let index = c.activeIndex
        pressKey(window, "\t", code: 48, flags: .control)
        check(c.activeIndex != index, "Tab completion: Ctrl-Tab still cycles tabs")
        c.show(tab)
        _ = window.makeFirstResponder(tab.view)

        // Forged marks in output (no nonce, or another one) arm nothing.
        tab.view.send(txt: "sleep 0.5; printf '\\e]6973;arm;1;main;start;1;0;x;builtin;;0\\a\\e]6973;deadbeef;arm;1;main;start;1;0;x;builtin;;0\\a'; sleep 1\r")
        _ = await wait(3) { tab.status.running }
        await pause(1)
        check(tab.status.running && !session.state.isArmed, "Tab completion: forged `arm` marks in output are ignored", "\(session.state.phase)")
        _ = await wait(4) { session.state.isArmed }

        // An agent's Tab over MCP is a plain Tab (AE6): no private key, no line report.
        if let mcp = MCPTestClient(socket: MCPControlServer.shared.path) {
            _ = await mcp.call(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "selftest", "version": "1"]])
            tab.view.send(txt: "echo /Syst")
            await pause(0.3)
            let reports = session.reports, last = session.lastTab
            _ = await mcp.call(2, "tools/call", ["name": "press_keys", "arguments": ["tab_id": tab.id.uuidString.lowercased(), "keys": ["tab"]]])
            check(await wait(3) { promptLine(tab).contains("echo /System/") } && session.reports == reports && session.lastTab == last,
                  "Tab completion: an agent's Tab over MCP is the shell's own", promptLine(tab))
            #if DEBUG
            check(session.lastWrite == [0x09], "and it goes to the shell as exactly ^I", "\(session.lastWrite)")
            #endif
            mcp.close()
            await clearLine()
        } else {
            check(false, "Tab completion: `nxtrm mcp` starts")
        }

        // With the switch off, Tab is exactly ^I, even in a tab that loaded the hook.
        CompletionPreferences.isOn = false
        tab.view.send(txt: "echo /Syst")
        await pause(0.3)
        let off = session.lastTab
        tabKey()
        check(await wait(3) { promptLine(tab).contains("echo /System/") } && session.lastTab == off,
              "Tab completion: with the switch off, Tab is the shell's own", promptLine(tab))
        #if DEBUG
        check(session.lastWrite == [0x09], "and it goes to the shell as exactly ^I", "\(session.lastWrite)")
        #endif
        await clearLine()
    }
}
