import AppKit
import NextTermCore

/// Tab completion. Keys go through the window (`window.sendEvent`) as the keyboard's do, since a view's own
/// `keyDown` would skip where Tab is caught; an agent's keys go through `nxtrm mcp`. The tabs run zsh with a
/// zsh config of the test's own (a debug build's ZDOTDIR override), so the user's plugins can't change what
/// is checked. Each part keeps to a time budget and says how long it took.
extension SelfTest {
    static func completionChecks(_ c: TerminalWindowController) async {
        let saved = UserDefaults.standard.object(forKey: CompletionPreferences.modeKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: CompletionPreferences.modeKey) }
            else { UserDefaults.standard.removeObject(forKey: CompletionPreferences.modeKey) }
        }
        #if DEBUG
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-complete-\(getpid())")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        await completionKeyChecks(c, dir: dir)
        await completionPopupChecks(c, dir: dir)
        await completionZshChecks(c, dir: dir)
        await completionSettingChecks(c, dir: dir)
        #else
        note("Tab completion: skipped in a release build (its tabs need the debug build's own zsh config)")
        #endif
    }

    /// A key down sent through the window, as AppKit hands it over.
    static func pressKey(_ window: NSWindow, _ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
        window.sendEvent(event)
    }

    /// Letters typed as real keys (the list stays open for them; a write that isn't a key closes it).
    static func typeKeys(_ window: NSWindow, _ text: String) {
        let codes: [Character: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
                                          "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
                                          "j": 38, "k": 40, "n": 45, "m": 46, " ": 49]
        for character in text {
            let lower = Character(character.lowercased())
            let flags: NSEvent.ModifierFlags = character.isUppercase ? [.shift] : []
            pressKey(window, String(character), code: codes[lower] ?? 0, flags: flags)
        }
    }

    /// The prompt's line as drawn, for checks on what Tab did to it.
    static func promptLine(_ tab: TerminalTab) -> String { tab.screenTail(2).last ?? "" }

    #if DEBUG
    /// A zsh tab in `dir` whose own config is `zshrc` (in a fresh folder under `dir`), at its prompt, with the
    /// keyboard. nil (and a failed check) when its hook never armed.
    static func completionTab(_ c: TerminalWindowController, in dir: URL, zshrc: String, name: String) async -> TerminalTab? {
        let zdotdir = dir.appendingPathComponent(".zdot-\(name)")
        try? FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)
        try? zshrc.write(to: zdotdir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        TerminalTab.testUserZDOTDIR = zdotdir.path
        let tab = c.addTab(directory: dir.path)
        TerminalTab.testUserZDOTDIR = nil
        _ = await wait(20) { tab.status.integrated }
        guard await wait(5, { tab.completion.state.isArmed }) else {
            check(false, "Tab completion (\(name)): the hook arms a zsh tab at its prompt", "\(tab.completion.state.phase)")
            c.remove(tab)
            return nil
        }
        guard await focus(c, tab) else {
            check(false, "Tab completion (\(name)): the window has the keyboard for real key events")
            c.remove(tab)
            return nil
        }
        return tab
    }

    /// The tab's window in front with the tab's terminal holding the keyboard.
    static func focus(_ c: TerminalWindowController, _ tab: TerminalTab) async -> Bool {
        guard let window = c.window else { return false }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        c.show(tab)
        _ = window.makeFirstResponder(tab.view)
        return await wait(3) { NSApp.isActive && NSApp.keyWindow === window && window.firstResponder === tab.view }
    }

    /// ^C, then the next prompt: a clean line.
    static func clearLine(_ tab: TerminalTab) async {
        tab.view.send(txt: "\u{3}")
        _ = await wait(3) { tab.completion.state.isArmed }
        await pause(0.2)
    }

    /// Plain zsh, as on a stock Mac: no completion system, so Next Term's own engine answers.
    static let plainZshrc = "PS1='$ '\nunsetopt beep\n"

    /// Step 1: a real Tab at a zsh prompt goes to the hook as the private key; everything else gets a plain Tab,
    /// as before.
    private static func completionKeyChecks(_ c: TerminalWindowController, dir: URL) async {
        let started = Date()
        defer { note("Tab completion, keys: \(String(format: "%.1f", Date().timeIntervalSince(started))) s (budget 90 s)") }
        guard let window = c.window as? TerminalWindow else { return check(false, "Tab completion: a terminal window") }
        // The mode is read as a shell starts: a tab opened with it on loads the hook.
        CompletionPreferences.mode = .nextTerm
        guard let tab = await completionTab(c, in: dir, zshrc: plainZshrc, name: "keys") else { return }
        defer { c.remove(tab) }
        let session = tab.completion
        func tabKey() { pressKey(window, "\t", code: 48) }

        // A real Tab: the private key; the one folder goes in.
        tab.view.send(txt: "echo /Syst")
        await pause(0.3)
        tabKey()
        if case .privateKey(let id) = session.lastTab {
            check(await wait(3) { session.lastDone?.id == id || session.reports > 0 }, "Tab completion: a real Tab goes to the hook as the private key",
                  "\(session.state.phase)")
        } else {
            check(false, "Tab completion: a real Tab goes to the hook as the private key", "\(session.lastTab)")
        }
        check(await wait(3) { promptLine(tab).contains("echo /System/") }, "and the line completes", promptLine(tab))
        await clearLine(tab)

        // Scrolled back, Tab jumps to the bottom first.
        tab.view.send(txt: "seq 1 300\r")
        _ = await wait(5) { session.state.isArmed && !tab.status.running }
        if tab.view.canScroll {
            tab.view.scroll(toPosition: 0)
            tabKey()
            check(tab.view.scrollPosition == 1, "Tab completion: Tab while scrolled back jumps to the bottom", "\(tab.view.scrollPosition)")
            _ = await wait(2) { !session.state.holding }
            await clearLine(tab)
        }

        // A program in front gets Tab itself (AE5).
        let got = dir.appendingPathComponent("key")
        tab.view.send(txt: "read -rk 1 x; printf %d \"'$x\" > \(got.path)\r")
        _ = await wait(3) { tab.status.running }
        await pause(0.3)
        let before = session.lastTab
        tabKey()
        check(await wait(3) { (try? String(contentsOf: got, encoding: .utf8)) == "9" } && session.lastTab == before,
              "Tab completion: a program that runs gets Tab itself (AE5)", (try? String(contentsOf: got, encoding: .utf8)) ?? "nothing")
        _ = await wait(3) { session.state.isArmed }

        // Text an input method is composing keeps Tab.
        tab.view.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = session.lastTab
        if tab.view.hasMarkedText() {
            tabKey()
            check(session.lastTab == marked && !c.completions.popup.isVisible, "Tab completion: Tab with marked text is not caught",
                  "\(session.lastTab)")
        }
        tab.view.unmarkText()
        await clearLine(tab)

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
        await clearLine(tab)

        // Ctrl-Tab still cycles tabs.
        let index = c.activeIndex
        pressKey(window, "\t", code: 48, flags: .control)
        check(c.activeIndex != index, "Tab completion: Ctrl-Tab still cycles tabs")
        _ = await focus(c, tab)

        // Forged marks in output (no nonce, or another one) arm nothing.
        tab.view.send(txt: "sleep 0.5; printf '\\e]6973;arm;1;main;start;1;0;x;builtin;;0\\a\\e]6973;deadbeef;arm;1;main;start;1;0;x;builtin;;0\\a'; sleep 1\r")
        _ = await wait(3) { tab.status.running }
        await pause(1)
        check(tab.status.running && !session.state.isArmed, "Tab completion: forged `arm` marks in output are ignored", "\(session.state.phase)")
        _ = await wait(4) { session.state.isArmed }

        // An agent's Tab over MCP is a plain Tab (AE6): no private key, no line report, no list.
        if let mcp = MCPTestClient(socket: MCPControlServer.shared.path) {
            _ = await mcp.call(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "selftest", "version": "1"]])
            tab.view.send(txt: "echo /Syst")
            await pause(0.3)
            let reports = session.reports, last = session.lastTab
            _ = await mcp.call(2, "tools/call", ["name": "press_keys", "arguments": ["tab_id": tab.id.uuidString.lowercased(), "keys": ["tab"]]])
            check(await wait(3) { promptLine(tab).contains("echo /System/") } && session.reports == reports && session.lastTab == last,
                  "Tab completion: an agent's Tab over MCP is the shell's own (AE6)", promptLine(tab))
            check(session.lastWrite == [0x09] && !c.completions.popup.isVisible, "and it goes to the shell as exactly ^I", "\(session.lastWrite)")
            mcp.close()
            await clearLine(tab)
        } else {
            check(false, "Tab completion: `nxtrm mcp` starts")
        }

        // Off: Tab is exactly ^I, even in a tab that loaded the hook.
        CompletionPreferences.set(.off)
        tab.view.send(txt: "echo /Syst")
        await pause(0.3)
        let off = session.lastTab
        tabKey()
        check(await wait(3) { promptLine(tab).contains("echo /System/") } && session.lastTab == off,
              "Tab completion: Off, Tab is the shell's own", promptLine(tab))
        check(session.lastWrite == [0x09], "and it goes to the shell as exactly ^I", "\(session.lastWrite)")
        await clearLine(tab)
        CompletionPreferences.mode = .nextTerm
    }

    /// Step 2: the list at the caret, filled by Next Term's own folders and files (no completion system).
    private static func completionPopupChecks(_ c: TerminalWindowController, dir: URL) async {
        let started = Date()
        defer { note("Tab completion, the list: \(String(format: "%.1f", Date().timeIntervalSince(started))) s (budget 150 s)") }
        guard let window = c.window as? TerminalWindow else { return }
        let tree = dir.appendingPathComponent("tree")
        let fm = FileManager.default
        for folder in ["Sources", "Resources", "Tests", "My Fo'lder $x", "thousand", "many"] {
            try? fm.createDirectory(at: tree.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        fm.createFile(atPath: tree.appendingPathComponent("Sourcery.txt").path, contents: nil)
        fm.createFile(atPath: tree.appendingPathComponent("My Fo'lder $x/inside.txt").path, contents: nil)
        for i in 0..<1000 { fm.createFile(atPath: tree.appendingPathComponent("thousand/entry-\(i)").path, contents: nil) }
        for i in 0..<2500 { fm.createFile(atPath: tree.appendingPathComponent("many/file-\(i)").path, contents: nil) }
        CompletionPreferences.mode = .nextTerm
        guard let tab = await completionTab(c, in: tree, zshrc: plainZshrc, name: "list") else { return }
        defer { c.remove(tab) }
        let session = tab.completion
        let popup = c.completions.popup
        func tabKey() { pressKey(window, "\t", code: 48) }
        func key(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) { pressKey(window, characters, code: code, flags: flags) }
        /// Types `line` (as the shell's input, before any list is open) and presses Tab; true once the list shows.
        func open(_ line: String) async -> Bool {
            tab.view.send(txt: line)
            await pause(0.3)
            tabKey()
            return await wait(3) { popup.isVisible && !popup.shownTexts.isEmpty }
        }

        // AE1: `cd So` lists Sources then Resources, and not the file; the terminal keeps the keyboard.
        check(await open("cd So"), "Tab completion: `cd So` + Tab opens the list", "\(session.state.phase)")
        check(popup.shownTexts == ["Sources", "Resources"], "AE1: Sources first, Resources second, and not the file", "\(popup.shownTexts)")
        check(window.firstResponder === tab.view && window.isKeyWindow && !popup.window.isKeyWindow,
              "Tab completion: the terminal keeps the keyboard while the list shows")
        check(popup.window.parent === window && popup.window.frame.maxY <= window.frame.maxY,
              "Tab completion: the list is a child of the terminal's window, at the caret", "\(popup.window.frame)")
        // Return puts it on the line, and runs nothing.
        key("\r", 36)
        check(await wait(3) { promptLine(tab).hasSuffix("cd Sources/") } && !popup.isVisible, "Tab completion: Return puts the chosen folder on the line",
              promptLine(tab))
        await pause(0.4)
        check(!tab.status.running && session.state.isArmed, "and runs nothing")
        await clearLine(tab)

        // AE2: one match goes in at once, with no list.
        tab.view.send(txt: "cd Te")
        await pause(0.3)
        tabKey()
        check(await wait(3) { promptLine(tab).hasSuffix("cd Tests/") } && !popup.isVisible, "AE2: `cd Te` + Tab gives `cd Tests/` with no list",
              promptLine(tab))
        await clearLine(tab)

        // Typing narrows the list, Backspace widens it; Esc closes it and the shell gets nothing.
        check(await open("cd "), "Tab completion: `cd ` + Tab lists the folders")
        let all = popup.shownTexts
        check(all == ["many", "My Fo'lder $x", "Resources", "Sources", "Tests", "thousand"], "and only the folders, by name", "\(all)")
        typeKeys(window, "R")
        check(await wait(2) { popup.shownTexts.first == "Resources" && popup.shownTexts.count < all.count }, "Tab completion: typing narrows the list",
              "\(popup.shownTexts)")
        key("\u{7f}", 51)
        check(await wait(2) { popup.shownTexts == all }, "and Backspace widens it again", "\(popup.shownTexts)")
        let written = session.lastWrite
        key("\u{1b}", 53)
        check(await wait(2) { !popup.isVisible } && session.lastWrite == written && session.state.isArmed,
              "Tab completion: Esc closes the list and sends the shell nothing", "\(session.lastWrite)")
        await clearLine(tab)

        // ↓ then Tab takes the second row; ⇧Tab moves up; a click inserts; → closes and goes to the shell.
        if await open("cd ") {
            key("", 125)
            check(popup.selected == 1, "Tab completion: ↓ moves the selection", "\(popup.selected)")
            tabKey()
            check(await wait(3) { promptLine(tab).hasSuffix("cd My\\ Fo\\'lder\\ \\$x/") }, "and Tab inserts that row, quoted", promptLine(tab))
            await clearLine(tab)
        }
        if await open("cd ") {
            key("", 125)
            key("", 125)
            key("\t", 48, .shift)
            check(popup.selected == 1, "Tab completion: ⇧Tab moves the selection up", "\(popup.selected)")
            popup.onPick?(4)
            check(await wait(3) { promptLine(tab).hasSuffix("cd Tests/") } && !popup.isVisible, "Tab completion: a click on a row inserts it",
                  promptLine(tab))
            await clearLine(tab)
        }
        if await open("cd ") {
            key("", 124)
            check(await wait(2) { !popup.isVisible } && session.state.isArmed, "Tab completion: → closes the list")
            await clearLine(tab)
        }

        // AE3: a name with a quote, a space and a $ goes in so that `ls` lists that folder.
        if await open("ls My") {
            check(popup.shownTexts.first == "My Fo'lder $x", "Tab completion: `ls My` lists the folder first", "\(popup.shownTexts)")
            key("\r", 36)
            _ = await wait(3) { promptLine(tab).hasSuffix("/") }
            tab.view.send(txt: "\r")
            check(await wait(3) { tab.screenTail(6).joined(separator: "\n").contains("inside.txt") }, "AE3: `ls` on the inserted name lists that folder",
                  tab.screenTail(4).joined(separator: " | "))
            _ = await wait(3) { session.state.isArmed }
        } else {
            check(false, "AE3: `ls My` + Tab opens the list")
            await clearLine(tab)
        }

        // AE9: `cd /etc/` offers only folders.
        if await open("cd /etc/") {
            let rows = session.list?.rows ?? []
            check(!rows.isEmpty && rows.allSatisfy(\.isFolder) && !popup.shownTexts.contains("hosts") && popup.shownTexts.contains("ssh"),
                  "AE9: `cd /etc/` lists only folders", "\(popup.shownTexts.prefix(8))")
            key("\u{1b}", 53)
        } else {
            check(false, "AE9: `cd /etc/` + Tab opens the list")
        }
        await clearLine(tab)

        // Over 2,000: the best 2,000, and a footer that says so.
        if await open("ls many/") {
            check(popup.shownTexts.count == 2000 && popup.footerText.contains("2,500"), "Tab completion: 2,500 files list 2,000, with a footer",
                  "\(popup.shownTexts.count) \(popup.footerText)")
            key("\u{1b}", 53)
        } else {
            check(false, "Tab completion: `ls many/` + Tab opens the list")
        }
        await clearLine(tab)

        // Tab to a shown list in under 50 ms on a 1,000-entry folder.
        tab.view.send(txt: "ls thousand/")
        await pause(0.3)
        let pressed = Date()
        tabKey()
        while !popup.isVisible, Date().timeIntervalSince(pressed) < 2 { try? await Task.sleep(nanoseconds: 2_000_000) }
        let elapsed = Date().timeIntervalSince(pressed) * 1000
        check(popup.isVisible && elapsed < 50, "Tab completion: Tab to a shown list under 50 ms for 1,000 entries",
              String(format: "%.0f ms", elapsed))
        note(String(format: "Tab completion: Tab to a shown list, 1,000 entries: %.0f ms", elapsed))
        key("\u{1b}", 53)
        await clearLine(tab)

        // What closes it: the window going to the back, an agent's text over MCP, a drop, output that moves the caret.
        if await open("cd ") {
            let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            other.makeKeyAndOrderFront(nil)
            check(await wait(2) { !popup.isVisible }, "Tab completion: the window going to the back closes the list")
            other.close()
            _ = await focus(c, tab)
            await clearLine(tab)
        }
        if await open("cd "), let mcp = MCPTestClient(socket: MCPControlServer.shared.path) {
            _ = await mcp.call(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "selftest", "version": "1"]])
            _ = await mcp.call(2, "tools/call", ["name": "send_to_tab", "arguments": ["tab_id": tab.id.uuidString.lowercased(), "text": "Tes", "submit": false]])
            check(await wait(3) { !popup.isVisible && promptLine(tab).hasSuffix("cd Tes") }, "Tab completion: an agent's text over MCP closes the list",
                  promptLine(tab))
            mcp.close()
            await clearLine(tab)
        }
        if await open("cd ") {
            tab.view.typeIn("/tmp ")
            check(await wait(2) { !popup.isVisible }, "Tab completion: a drop closes the list")
            await clearLine(tab)
        }
        tab.view.send(txt: "(sleep 1.2; print bg-output) &!\r")
        _ = await wait(3) { session.state.isArmed }
        if await open("cd ") {
            check(await wait(4) { !popup.isVisible }, "Tab completion: output that moves the caret's row closes the list")
            await clearLine(tab)
        }
    }

    /// zsh's own completions: with `compinit`, `git checkout ` lists the branches (AE8); a slow completer shows
    /// Loading first, and Esc drops its late result.
    private static func completionZshChecks(_ c: TerminalWindowController, dir: URL) async {
        let started = Date()
        defer { note("Tab completion, zsh's completions: \(String(format: "%.1f", Date().timeIntervalSince(started))) s (budget 60 s)") }
        guard let window = c.window as? TerminalWindow else { return }
        let repo = dir.appendingPathComponent("repo")
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for arguments in [["init", "-q", "-b", "main"], ["-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "first"],
                          ["branch", "feature/x"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["-C", repo.path] + arguments
            git.standardOutput = FileHandle.nullDevice
            git.standardError = FileHandle.nullDevice
            try? git.run()
            git.waitUntilExit()
        }
        let zshrc = plainZshrc + "autoload -Uz compinit && compinit -u -D\n_ntslow() { sleep 1; compadd one two }\ncompdef _ntslow ntslow\n"
        CompletionPreferences.mode = .nextTerm
        guard let tab = await completionTab(c, in: repo, zshrc: zshrc, name: "compinit") else { return }
        defer { c.remove(tab) }
        let session = tab.completion
        let popup = c.completions.popup
        check(session.state.arm?.completionSystem == true, "Tab completion: the hook says zsh's completion system is loaded")

        tab.view.send(txt: "git checkout ")
        await pause(0.3)
        pressKey(window, "\t", code: 48)
        check(await wait(5) { popup.shownTexts.contains("main") && popup.shownTexts.contains("feature/x") },
              "AE8: `git checkout ` lists the branches, from zsh", "\(popup.shownTexts)")
        if let index = popup.shownTexts.firstIndex(of: "main") {
            for _ in 0..<index { pressKey(window, "", code: 125) }
            pressKey(window, "\r", code: 36)
            check(await wait(3) { promptLine(tab).hasSuffix("git checkout main") } && !popup.isVisible, "and Return inserts the branch zsh's way",
                  promptLine(tab))
        }
        await clearLine(tab)

        // A completer that takes a second: Loading first, then its matches.
        tab.view.send(txt: "ntslow ")
        await pause(0.3)
        pressKey(window, "\t", code: 48)
        check(await wait(0.8) { popup.isVisible && popup.loading }, "Tab completion: a slow completer shows Loading first")
        pressKey(window, "\r", code: 36)
        check(popup.isVisible && popup.loading, "and Return does nothing while it loads")
        check(await wait(3) { popup.shownTexts == ["one", "two"] }, "then its matches", "\(popup.shownTexts)")
        pressKey(window, "\u{1b}", code: 53)
        await clearLine(tab)
        // Esc while it loads: its late matches are dropped.
        tab.view.send(txt: "ntslow ")
        await pause(0.3)
        pressKey(window, "\t", code: 48)
        _ = await wait(0.8) { popup.isVisible }
        pressKey(window, "\u{1b}", code: 53)
        await pause(1.5)
        check(!popup.isVisible && promptLine(tab).hasSuffix("ntslow"), "Tab completion: Esc while Loading drops the late matches", promptLine(tab))
        await clearLine(tab)
    }

    /// The setting: Off gives the shell's Tab, Auto brings the list back, the tooltip says who answers, an
    /// unknown stored value reads as Auto, and the row sits in Settings › Terminal.
    private static func completionSettingChecks(_ c: TerminalWindowController, dir: URL) async {
        let started = Date()
        defer { note("Tab completion, the setting: \(String(format: "%.1f", Date().timeIntervalSince(started))) s (budget 40 s)") }
        guard let window = c.window as? TerminalWindow else { return }
        CompletionPreferences.mode = .auto
        guard let tab = await completionTab(c, in: dir, zshrc: plainZshrc, name: "setting") else { return }
        defer { c.remove(tab) }
        let session = tab.completion
        let popup = c.completions.popup
        check(tab.tooltip.contains("Tab completion: Next Term’s list of folders and files"), "Tab completion: the tooltip says who answers Tab",
              tab.tooltip.replacingOccurrences(of: "\n", with: " | "))
        CompletionPreferences.set(.off)
        check(tab.tooltip.contains("Tab completion: the shell’s own"), "and says the shell's own when it is Off")
        tab.view.send(txt: "cd /")
        await pause(0.3)
        pressKey(window, "\t", code: 48)
        await pause(0.5)
        check(!popup.isVisible && session.lastWrite == [0x09], "Tab completion: switched Off, Tab in an open tab is ^I", "\(session.lastWrite)")
        await clearLine(tab)
        CompletionPreferences.set(.auto)
        tab.view.send(txt: "cd /")
        await pause(0.3)
        pressKey(window, "\t", code: 48)
        check(await wait(3) { popup.isVisible }, "Tab completion: back to Auto, the list comes back")
        pressKey(window, "\u{1b}", code: 53)
        await clearLine(tab)

        UserDefaults.standard.set("sometimes", forKey: CompletionPreferences.modeKey)
        check(CompletionPreferences.mode == .auto, "Tab completion: an unknown stored value reads as Auto")
        CompletionPreferences.mode = .auto

        // A shell that replaced itself has no hook: the shell's own Tab.
        tab.view.send(txt: "exec /bin/zsh -f\r")
        check(await wait(3) { tab.tooltip.contains("Tab completion: the shell’s own") }, "Tab completion: after `exec zsh` the tooltip says the shell's own")

        // The row in Settings › Terminal, whole at the default size and as narrow as the window goes.
        let settings = SettingsWindowController()
        settings.showTab("terminal")
        guard let settingsWindow = settings.window, let tabs = settingsWindow.contentView as? NSTabView,
              let view = tabs.selectedTabViewItem?.view else { return check(false, "Tab completion: Settings › Terminal opens") }
        func find(_ root: NSView) -> CompletionSettingsView? {
            if let row = root as? CompletionSettingsView { return row }
            for sub in root.subviews { if let row = find(sub) { return row } }
            return nil
        }
        guard let row = find(view) else { return check(false, "Tab completion: the row is in Settings › Terminal") }
        for size in [NSSize(width: 620, height: 560), NSSize(width: 480, height: 400)] {
            settingsWindow.setContentSize(size)
            settingsWindow.layoutIfNeeded()
            let frame = row.convert(row.bounds, to: view)
            check(view.bounds.contains(frame), "Tab completion: the row shows whole in Settings › Terminal at \(Int(size.width)) pt",
                  "\(frame) in \(view.bounds)")
        }
        settingsWindow.setContentSize(NSSize(width: 480, height: 320))
        settingsWindow.layoutIfNeeded()
        let smallest = row.convert(row.bounds, to: view)
        note("Tab completion: at Settings' smallest size the row is \(view.bounds.contains(smallest) ? "whole" : "cut") (\(smallest) in \(view.bounds))")
        settings.close()
    }
    #endif
}
