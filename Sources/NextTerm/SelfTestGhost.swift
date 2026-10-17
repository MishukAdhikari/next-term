import AppKit
import CryptoKit
import NextTermCore

/// What MCP reads as typed at a zsh prompt, and suggestions while typing. Keys go through the window as the keyboard's do
/// (`typeKeys`, `pressKey`); an agent's calls go through MCPControl as the socket hands them over. The tabs run zsh with a
/// config of the test's own (a debug build's ZDOTDIR override), so the user's plugins can't change what is checked, and a
/// stand-in draws a plugin's ghost where one is needed: it reads no history.
extension SelfTest {
    static func ghostTextChecks(_ c: TerminalWindowController) async {
        #if DEBUG
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-ghost-\(getpid())")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let savedMask = SecretMask.current
        defer { SecretMask.current = savedMask }
        await ghostReadTabChecks(c, dir: dir)
        GhostPreferences.testIsOn = true
        defer { GhostPreferences.testIsOn = nil }
        await ghostRecordChecks(c, dir: dir)
        await ghostOverlayChecks(c, dir: dir)
        await ghostKeyChecks(c, dir: dir)
        await ghostViChecks(c, dir: dir)
        await ghostOwnerChecks(c, dir: dir)
        await ghostSettingsChecks(c, dir: dir)
        await ghostVoiceOverChecks(c, dir: dir)
        await ghostFallbackChecks(c, dir: dir)
        #else
        note("Suggestions while typing: skipped in a release build (its tabs need the debug build's own zsh config)")
        #endif
    }

    /// A stand-in for zsh-autosuggestions' ghost: self-insert wrapped, POSTDISPLAY the rest of `git checkout main` while the
    /// line is the start of it.
    static let standInGhost = """
        __standin_insert() {
          zle .self-insert
          local s='git checkout main'
          if [[ -n $BUFFER && $s == "$BUFFER"* && $s != "$BUFFER" ]]; then POSTDISPLAY=${s#"$BUFFER"}; else POSTDISPLAY=; fi
        }
        zle -N self-insert __standin_insert

        """

    /// The stand-in with zsh-autosuggestions' own switches (autosuggest-disable and -enable, which its ghost follows) and
    /// its precmd, which drops itself once ZSH_AUTOSUGGEST_MANUAL_REBIND is set.
    static let standInPlugin = standInGhost.replacingOccurrences(
        of: "  zle .self-insert\n", with: "  zle .self-insert\n  (( ${+_ZSH_AUTOSUGGEST_DISABLED} )) && { POSTDISPLAY=; return }\n") + """
        zle -N autosuggest-fetch __standin_fetch
        __standin_fetch() { : }
        zle -N autosuggest-disable __standin_disable
        __standin_disable() { typeset -g _ZSH_AUTOSUGGEST_DISABLED; POSTDISPLAY= }
        zle -N autosuggest-enable __standin_enable
        __standin_enable() { unset _ZSH_AUTOSUGGEST_DISABLED }
        _zsh_autosuggest_start() { (( ${+ZSH_AUTOSUGGEST_MANUAL_REBIND} )) && precmd_functions=(${precmd_functions:#_zsh_autosuggest_start}); : }
        precmd_functions+=(_zsh_autosuggest_start)

        """

    /// The store's answer for `prefix`, as a suggestion asks for one.
    static func ghostQuery(_ prefix: String, folder: String? = nil) async -> [CommandHistory.Entry] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[CommandHistory.Entry], Never>) in
            CommandHistoryStore.shared.query(prefix: prefix, folder: folder) { (found: [CommandHistory.Entry]) in continuation.resume(returning: found) }
        }
    }

    /// The store's answer for `prefix` once `ready` holds for it (it records off the main queue), 3 s at most.
    static func ghostQuery(_ prefix: String, until ready: @escaping ([CommandHistory.Entry]) -> Bool) async -> [CommandHistory.Entry] {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var found = await ghostQuery(prefix)
        while !ready(found), ProcessInfo.processInfo.systemUptime < deadline {
            await pause(0.1)
            found = await ghostQuery(prefix)
        }
        return found
    }

    /// A tool called in this process, as the socket calls it, and its answer's JSON.
    static func ghostTool(_ name: String, _ arguments: [String: Any]) async -> (json: [String: Any]?, text: String) {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<MCPServer.CallResult, Never>) in
            MCPControl.call(name, arguments, caller: nil) { (result: MCPServer.CallResult) in continuation.resume(returning: result) }
        }
        return ((try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any], result.text)
    }

    #if DEBUG
    /// A zsh tab in `dir` whose own config is `zshrc` (in a fresh folder under `dir`), once the ghost hook has reported its
    /// line; with `focused`, its window in front and its terminal holding the keyboard, for real key events. nil when it
    /// can't be had (a failed check, or a note when the app can't come in front).
    static func ghostTab(_ c: TerminalWindowController, in dir: URL, zshrc: String, name: String, focused: Bool = true) async -> TerminalTab? {
        let zdotdir = dir.appendingPathComponent(".zdot-\(name)")
        try? FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)
        try? zshrc.write(to: zdotdir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        TerminalTab.testUserZDOTDIR = zdotdir.path
        let tab = c.addTab(directory: dir.path)
        TerminalTab.testUserZDOTDIR = nil
        _ = await wait(20) { tab.status.integrated }
        guard await wait(5, { tab.lastBuffer != nil }) else {
            check(false, "ghost (\(name)): the ghost hook reports the line of a zsh tab at its prompt")
            c.remove(tab)
            return nil
        }
        if focused, !(await focus(c, tab, for: "ghost (\(name))")) {
            c.remove(tab)
            return nil
        }
        return tab
    }

    /// ^C, then the hook's report of the next line, empty.
    static func ghostClear(_ tab: TerminalTab) async {
        let line = tab.lastBuffer?.report.line ?? 0
        tab.view.send(txt: "\u{3}")
        _ = await wait(3) { (tab.lastBuffer?.report.line ?? 0) > line && tab.lastBuffer?.report.buffer == "" }
        await pause(0.1)
    }

    /// read_tab and wait_for_tab at a zsh prompt: a plugin's ghost is left out of `screen`, and `input` says what is typed.
    static func ghostReadTabChecks(_ c: TerminalWindowController, dir: URL) async {
        guard let tab = await ghostTab(c, in: dir, zshrc: plainZshrc + standInGhost, name: "read"), let window = c.window else { return }
        defer { c.remove(tab) }
        let id = tab.id.uuidString.lowercased()
        typeKeys(window, "git ch")
        _ = await wait(3) { tab.lastBuffer?.report.postdisplay == "eckout main" }
        let read = await ghostTool("read_tab", ["tab_id": id, "lines": 5])
        let screen = read.json?["screen"] as? String ?? ""
        check(screen.split(separator: "\n").last?.hasSuffix("git ch") == true && !screen.contains("eckout"),
              "read_tab: a plugin's ghost is left out of the screen, whose prompt row ends at what is typed", screen)
        let input = read.json?["input"] as? [String: Any]
        check(input?["line"] as? String == "git ch" && input?["cursor"] as? Int == 6 && input?["suggestion"] as? String == "eckout main",
              "read_tab: input is the line, the cursor and the plugin's suggestion", read.text)
        let waited = await ghostTool("wait_for_tab", ["tab_id": id, "timeout_seconds": 5])
        let waitedInput = waited.json?["input"] as? [String: Any]
        check(waitedInput?["line"] as? String == "git ch" && waitedInput?["suggestion"] as? String == "eckout main"
              && (waited.json?["screen"] as? String)?.contains("eckout") == false,
              "wait_for_tab: the same input, and the same screen", waited.text)

        // An agent's text with no Return, read at once: read_tab waits for the shell's report of the new line.
        await ghostClear(tab)
        _ = await ghostTool("send_to_tab", ["tab_id": id, "text": "echo sent-line", "submit": false])
        let sent = await ghostTool("read_tab", ["tab_id": id, "lines": 5])
        check((sent.json?["input"] as? [String: Any])?["line"] as? String == "echo sent-line",
              "read_tab right after send_to_tab: input is the line just typed", sent.text)

        // A stored key typed at the prompt is masked in `line`, as on the screen.
        await ghostClear(tab)
        let value = "nt-ghost-secret-\(getpid())-value"
        let key = SymmetricKey(size: .bits256)
        SecretMask.current = SecretMask(key: key, marks: SecretMask.marks(for: SecretBytes(utf8: value), key: key))
        tab.view.send(txt: "echo \(value)")
        _ = await wait(3) { tab.lastBuffer?.report.buffer == "echo \(value)" }
        let masked = await ghostTool("read_tab", ["tab_id": id, "lines": 5])
        let line = (masked.json?["input"] as? [String: Any])?["line"] as? String
        check(line != nil && line?.contains(value) == false && !masked.text.contains(value), "read_tab: a stored key typed at the prompt is masked in input",
              masked.text)
        SecretMask.current = .empty
        await ghostClear(tab)

        // A command running: no input.
        tab.view.send(txt: "sleep 5\r")
        _ = await wait(3) { tab.status.running }
        let running = await ghostTool("read_tab", ["tab_id": id, "lines": 5])
        check(tab.status.running && running.json?["input"] == nil, "read_tab: no input while a command runs", running.text)
        tab.view.send(txt: "\u{3}")
        _ = await wait(3) { !tab.status.running }
    }

    /// The suggestion shows (placed, after the shell's redraw), within `seconds`.
    static func ghostShows(_ tab: TerminalTab, within seconds: Double = 3) async -> Bool {
        await wait(seconds) { tab.ghost.isShowing }
    }

    /// The record holds `line`, run well a moment ago in `folder`: what a suggestion is asked from.
    static func ghostSeed(_ line: String, folder: String) async {
        CommandHistoryStore.shared.record(line, folder: folder, at: Date(), exit: 0)
        _ = await ghostQuery(String(line.prefix(3))) { (found: [CommandHistory.Entry]) -> Bool in found.contains { $0.line == line } }
    }

    /// The overlay: where it shows and what never holds it, what hides it, and where it never shows.
    static func ghostOverlayChecks(_ c: TerminalWindowController, dir: URL) async {
        await ghostSeed("git checkout main", folder: dir.path)
        guard let tab = await ghostTab(c, in: dir, zshrc: plainZshrc, name: "overlay"), let window = c.window else { return }
        defer { c.remove(tab) }
        typeKeys(window, "git ch")
        check(await ghostShows(tab), "suggestions: typing `git ch` shows the rest of `git checkout main`", "\(tab.ghost.state)")
        let overlay = tab.ghost.overlay
        check(overlay.text == "eckout main", "suggestions: the overlay says `eckout main`", overlay.text)
        let cursor = tab.view.getTerminal().getCursorLocation()
        let cell = tab.view.cellSize
        let expected = CGPoint(x: CGFloat(cursor.x) * cell.width, y: tab.view.bounds.height - cell.height * CGFloat(cursor.y + 1))
        check(abs(overlay.frame.origin.x - expected.x) < 0.5 && abs(overlay.frame.origin.y - expected.y) < 0.5,
              "suggestions: the overlay starts at the cursor's cell", "\(overlay.frame.origin) for \(expected)")
        check(tab.view.subviews.first === overlay, "suggestions: the overlay is the terminal's bottom subview, under the caret")
        check(!overlay.isAccessibilityElement(), "suggestions: the overlay is no accessibility element")
        let read = await ghostTool("read_tab", ["tab_id": tab.id.uuidString.lowercased(), "lines": 5])
        let spoken = (tab.view.accessibilityValue() as? String) ?? ""
        check(!tab.screenTail(5).joined().contains("eckout") && !read.text.contains("eckout") && !spoken.contains("eckout"),
              "suggestions: the screen, read_tab and the terminal's accessibility value never hold the suggestion")

        // Each of these hides it until the next report.
        let hiders: [(String, () -> Void)] = [
            ("a resize", { window.setContentSize(NSSize(width: window.frame.width - 40, height: window.frame.height)) }),
            ("the alternate screen", { tab.view.feed(text: "\u{1b}[?1049h") }),
            ("marked text", { tab.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)) }),
            ("a selection", { tab.view.selectAll(nil) }),
        ]
        for (what, hide) in hiders {
            await ghostClear(tab)
            typeKeys(window, "git ch")
            guard await ghostShows(tab) else {
                check(false, "suggestions: hidden by \(what): it showed first")
                continue
            }
            hide()
            check(await wait(1) { !tab.ghost.isShowing }, "suggestions: \(what) hides it")
            if what == "the alternate screen" { tab.view.feed(text: "\u{1b}[?1049l") }
            if what == "marked text" { tab.view.unmarkText() }
        }
        // Scrolled back: hidden. The output first gives it somewhere to scroll.
        await ghostClear(tab)
        tab.view.send(txt: "seq 1 300\r")
        _ = await wait(5) { !tab.status.running && tab.status.commandsStarted > 0 }
        typeKeys(window, "git ch")
        if await ghostShows(tab) {
            tab.view.scroll(toPosition: 0)
            check(await wait(1) { !tab.ghost.isShowing }, "suggestions: scrolling back hides it")
            tab.view.scroll(toPosition: 1)
        } else {
            check(false, "suggestions: hidden by a scroll back: it showed first")
        }

        // Where it never shows: an agent's text, text with no key of yours on the line, and with suggestions off.
        await ghostClear(tab)
        _ = await ghostTool("send_to_tab", ["tab_id": tab.id.uuidString.lowercased(), "text": "git ch", "submit": false])
        check(!(await ghostShows(tab, within: 1)), "suggestions: none in a tab an agent drives")
        await ghostClear(tab)
        _ = await focus(c, tab)
        tab.view.send(txt: "git ch")
        check(!(await ghostShows(tab, within: 1)), "suggestions: none before a key of yours on the line")
        await ghostClear(tab)
        GhostPreferences.testIsOn = false
        typeKeys(window, "git ch")
        check(!(await ghostShows(tab, within: 1)), "suggestions: none with suggestions off")
        GhostPreferences.testIsOn = true
        await ghostClear(tab)

        // A right prompt stays whole: the suggestion ends a cell before it, with "…".
        await ghostSeed("echo " + String(repeating: "word ", count: 30) + "end", folder: dir.path)
        guard let right = await ghostTab(c, in: dir, zshrc: plainZshrc + "RPROMPT=XYZ\n", name: "rprompt") else { return }
        defer { c.remove(right) }
        typeKeys(window, "echo wo")
        if await ghostShows(right) {
            let row = right.screenTail(1).last ?? ""
            let columns = right.view.getTerminal().cols
            let ghostEnd = Int((right.ghost.overlay.frame.maxX / right.view.cellSize.width).rounded())
            check(row.hasSuffix("XYZ") && right.ghost.overlay.text.hasSuffix(GhostClip.ellipsis) && ghostEnd <= columns - 4,
                  "suggestions: a right prompt stays whole, and the suggestion ends before it with …", "\(row) / \(right.ghost.overlay.text)")
        } else {
            check(false, "suggestions: beside a right prompt: it showed")
        }
        note("suggestions: a server tab gets no ghost marks (its hook is Tab completion's alone, RemoteCompletionConsent); a paste's hide is the clipboard's, not checked here")
    }

    /// The keys that take a suggestion, each as the keyboard sends it.
    static let ghostAcceptKeys: [(name: String, characters: String, code: UInt16, flags: NSEvent.ModifierFlags, key: GhostKeys.Key)] = [
        ("→", "\u{F703}", 124, [.function, .numericPad], .right),
        ("End", "\u{F72B}", 119, [.function], .end),
        ("⌃E", "e", 14, [.control], .ctrlE),
        ("⌃F", "f", 3, [.control], .ctrlF),
    ]

    /// Accepting: each key puts the whole command on the line and runs nothing, ⌥→ one word, Esc hides it without a
    /// write (and goes on to zsh in vi insert mode), Return runs only what was typed, Tab is the Tab list's; and with no
    /// suggestion, what SwiftTerm writes for each key is what GhostKeys says, in both cursor key modes.
    static func ghostKeyChecks(_ c: TerminalWindowController, dir: URL) async {
        await ghostSeed("git checkout main", folder: dir.path)
        guard let tab = await ghostTab(c, in: dir, zshrc: plainZshrc, name: "keys"), let window = c.window else { return }
        defer { c.remove(tab) }
        func line(_ text: String) async -> Bool { await wait(3) { tab.lastBuffer?.report.buffer == text } }
        for press in ghostAcceptKeys {
            await ghostClear(tab)
            typeKeys(window, "git ch")
            guard await ghostShows(tab) else {
                check(false, "suggestions: \(press.name) takes it: it showed first", "\(tab.ghost.state)")
                continue
            }
            let started = tab.status.commandsStarted
            pressKey(window, press.characters, code: press.code, flags: press.flags)
            check(await line("git checkout main") && tab.status.commandsStarted == started && !tab.ghost.isShowing,
                  "suggestions: \(press.name) makes the line `git checkout main`, and nothing runs", "\(String(describing: tab.lastBuffer?.report))")
        }
        // ⌥→ with Option as Meta: one word.
        await ghostClear(tab)
        let meta = tab.view.optionAsMetaKey
        tab.view.optionAsMetaKey = true
        typeKeys(window, "git ch")
        if await ghostShows(tab) {
            pressKey(window, "\u{F703}", code: 124, flags: [.function, .numericPad, .option])
            check(await line("git checkout"), "suggestions: ⌥→ (Option as Meta) makes the line `git checkout`",
                  "\(String(describing: tab.lastBuffer?.report))")
        } else {
            check(false, "suggestions: ⌥→ takes a word: it showed first")
        }
        tab.view.optionAsMetaKey = meta
        // Esc: hidden, and nothing written.
        await ghostClear(tab)
        typeKeys(window, "git ch")
        if await ghostShows(tab) {
            let writes = tab.view.inputWrites
            pressKey(window, "\u{1b}", code: 53)
            check(!tab.ghost.isShowing && tab.view.inputWrites == writes, "suggestions: Esc hides it, and nothing is sent")
            typeKeys(window, "e")
            check(!(await ghostShows(tab, within: 1)), "suggestions: after Esc, none for the rest of the line")
        } else {
            check(false, "suggestions: Esc hides it: it showed first")
        }
        // Return after one showed: what runs is what was typed.
        await ghostClear(tab)
        typeKeys(window, "git ch")
        if await ghostShows(tab) {
            pressKey(window, "\r", code: 36)
            check(await wait(3) { tab.status.command == "git ch" }, "suggestions: Return runs only what was typed", tab.status.command)
            _ = await wait(3) { !tab.status.running }
        }
        // Tab with one showing: the Tab list's, and the suggestion hides.
        await ghostClear(tab)
        typeKeys(window, "git ch")
        if await ghostShows(tab) {
            pressKey(window, "\t", code: 48)
            check(await wait(1) { !tab.ghost.isShowing }, "suggestions: Tab with one showing is the Tab list's, and hides it")
            pressKey(window, "\u{1b}", code: 53)
        }

        // With no suggestion, SwiftTerm writes for each key what GhostKeys says, with application cursor keys off and on.
        await ghostClear(tab)
        var written: [UInt8] = []
        let onWrite = tab.view.onWrite
        tab.view.onWrite = { data in
            written = Array(data)
            onWrite?(data)
        }
        for application in [false, true] {
            if application { tab.view.feed(text: "\u{1b}[?1h") }
            for press in ghostAcceptKeys {
                written = []
                pressKey(window, press.characters, code: press.code, flags: press.flags)
                let expected = GhostKeys.bytes(press.key, applicationCursor: application, optionAsMeta: tab.view.optionAsMetaKey)
                check(written == expected, "suggestions: with none showing, \(press.name) sends what GhostKeys says\(application ? " (application cursor keys)" : "")",
                      "\(written) for \(expected)")
            }
            if application { tab.view.feed(text: "\u{1b}[?1l") }
        }
        tab.view.onWrite = onWrite
    }

    /// In vi insert mode, Esc hides the suggestion and goes on to zsh, which leaves insert mode.
    static func ghostViChecks(_ c: TerminalWindowController, dir: URL) async {
        guard let tab = await ghostTab(c, in: dir, zshrc: plainZshrc + "bindkey -v\n", name: "vi"), let window = c.window else { return }
        defer { c.remove(tab) }
        typeKeys(window, "git ch")
        guard await ghostShows(tab) else { return check(false, "suggestions in vi insert mode: it showed first", "\(tab.ghost.state)") }
        pressKey(window, "\u{1b}", code: 53)
        check(await wait(2) { !tab.ghost.isShowing && tab.lastBuffer?.report.keymap == "vicmd" },
              "suggestions: Esc in vi insert mode hides it and goes on to zsh (vicmd)", "\(String(describing: tab.lastBuffer?.report))")
    }

    /// Beside a plugin that draws its own (the stand-in): none of Next Term's, a notice once at an idle prompt, and each
    /// answer; a new tab told at its start; the tooltip's line for each. The user's own choices are put back after.
    static func ghostOwnerChecks(_ c: TerminalWindowController, dir: URL) async {
        let keys = [GhostPreferences.choicesKey, GhostPreferences.dismissalsKey]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        let dismissed = GhostPreferences.dismissedThisLaunch
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
            GhostPreferences.dismissedThisLaunch = dismissed
        }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        GhostPreferences.dismissedThisLaunch = []
        await ghostSeed("git checkout main", folder: dir.path)
        guard let tab = await ghostTab(c, in: dir, zshrc: plainZshrc + standInPlugin, name: "owner"), let window = c.window else { return }
        defer { c.remove(tab) }
        check(tab.ghost.hook?.enabled == true && tab.ghost.label == "Suggestions: zsh-autosuggestions",
              "suggestions: the tooltip names the plugin that draws its own", tab.ghost.label ?? "none")
        typeKeys(window, "git ch")
        _ = await wait(2) { tab.lastBuffer?.report.postdisplay == "eckout main" }
        check(!(await ghostShows(tab, within: 1)), "suggestions: where a plugin draws its own, none of Next Term's")
        check(tab.ghost.notice == nil, "suggestions: no question while a line is typed")
        // An idle prompt, after a command: the question, once.
        await ghostClear(tab)
        typeKeys(window, "true")
        pressKey(window, "\r", code: 36)
        check(await wait(4) { tab.ghost.notice != nil }, "suggestions: at an idle prompt after a command, a notice in the tab asks")
        tab.ghost.notice?.button("Use Next Term’s")?.performClick(nil)
        check(await wait(3) { tab.ghost.hook?.enabled == false } && GhostPreferences.choice(for: .autosuggestions) == .nextTerm
              && tab.ghost.notice == nil, "suggestions: Use Next Term’s turns the plugin's off in that tab")
        check(tab.ghost.label == "Suggestions: Next Term’s", "suggestions: and the tooltip says so", tab.ghost.label ?? "none")
        await ghostClear(tab)
        typeKeys(window, "git ch")
        check(await ghostShows(tab), "suggestions: then Next Term's show there", "\(tab.ghost.state)")
        // A new tab starts with the plugin's off.
        if let second = await ghostTab(c, in: dir, zshrc: plainZshrc + standInPlugin, name: "owner-new", focused: false) {
            check(second.ghostStart == "t" && second.ghost.hook?.enabled == false && second.ghost.tookOver,
                  "suggestions: a new tab starts with the plugin's off", "\(String(describing: second.ghost.hook))")
            c.remove(second)
        }
        // The plugin's chosen again (as in Settings): given back.
        await ghostClear(tab)
        GhostPreferences.choose(.plugin, for: .autosuggestions)
        GhostSession.syncAll()
        check(await wait(3) { tab.ghost.hook?.enabled == true } && tab.ghost.label == "Suggestions: zsh-autosuggestions, your choice",
              "suggestions: the plugin's chosen: given back, and the tooltip says it was your choice", tab.ghost.label ?? "none")
        // Asked again, in a tab of its own: Keep changes nothing.
        GhostPreferences.choose(nil, for: .autosuggestions)
        if let third = await ghostTab(c, in: dir, zshrc: plainZshrc + standInPlugin, name: "owner-keep") {
            typeKeys(window, "true")
            pressKey(window, "\r", code: 36)
            if await wait(4, { third.ghost.notice != nil }) {
                third.ghost.notice?.button("Keep zsh-autosuggestions")?.performClick(nil)
                await pause(0.5)
                check(third.ghost.hook?.enabled == true && GhostPreferences.choice(for: .autosuggestions) == .plugin && third.ghost.notice == nil,
                      "suggestions: Keep zsh-autosuggestions changes nothing in the shell")
            } else {
                check(false, "suggestions: asked again, the notice comes back in a new tab")
            }
            c.remove(third)
        }
        // Not Now: the plugin's until the next launch; twice, for good, as Settings says.
        GhostPreferences.choose(nil, for: .autosuggestions)
        GhostPreferences.dismissed(.autosuggestions)
        check(GhostPreferences.answer(for: .autosuggestions) == .plugin && GhostPreferences.choice(for: .autosuggestions) == nil,
              "suggestions: Not Now leaves them to the plugin until the next launch")
        GhostPreferences.dismissed(.autosuggestions)
        check(GhostPreferences.remembered.contains { $0.plugin == .autosuggestions && $0.choice == .plugin && $0.byDismissal },
              "suggestions: Not Now twice keeps the plugin's for good, and Settings says why")
        GhostPreferences.testIsOn = false
        check(tab.ghost.label == "Suggestions: off", "suggestions: the tooltip says when they are off", tab.ghost.label ?? "none")
        GhostPreferences.testIsOn = true
    }

    /// Settings › Terminal › While typing, the first-use hint, Forget This Suggestion and Private Mode. The user's own
    /// setting and hint count are put back after; Clear History… clears only the self-test's own record.
    static func ghostSettingsChecks(_ c: TerminalWindowController, dir: URL) async {
        let keys = [GhostPreferences.onKey, GhostPreferences.hintsKey]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
            GhostPreferences.testIsOn = true
            GhostPreferences.setPrivateMode(false)
        }
        UserDefaults.standard.removeObject(forKey: GhostPreferences.hintsKey)
        await ghostSeed("git checkout main", folder: dir.path)
        guard let tab = await ghostTab(c, in: dir, zshrc: plainZshrc, name: "settings"), let window = c.window else { return }
        defer { c.remove(tab) }
        func shows() async -> Bool {
            await ghostClear(tab)
            typeKeys(window, "git ch")
            return await ghostShows(tab)
        }
        // The hint: on the first two lines a suggestion shows on, not the third.
        var hinted: [Bool] = []
        for _ in 0..<3 {
            hinted.append(await shows() && tab.ghost.hint != nil)
        }
        check(hinted == [true, true, false], "suggestions: the first-use hint on the first two lines with a suggestion, not the third", "\(hinted)")

        // Off: the overlay goes at once, and a command run isn't recorded; on again, back.
        if await shows() {
            GhostPreferences.set(false)
            check(!tab.ghost.isShowing, "suggestions: Off hides the suggestion at once")
            await ghostClear(tab)
            typeKeys(window, "echo nt-ghost-off")
            pressKey(window, "\r", code: 36)
            _ = await wait(3) { tab.status.command == "echo nt-ghost-off" && !tab.status.running }
            await pause(0.3)
            let found = await ghostQuery("echo nt-ghost-o")
            check(found.isEmpty, "suggestions: Off, a command you run isn't recorded", "\(found.map(\.line))")
            GhostPreferences.set(true)
            check(await shows(), "suggestions: On again, they come back")
        }
        // Turn Off in the hint: Settings says Off.
        UserDefaults.standard.removeObject(forKey: GhostPreferences.hintsKey)
        if await shows(), let hint = tab.ghost.hint {
            hint.button("Turn Off")?.performClick(nil)
            let settings = GhostSettingsView()
            settings.refresh()
            check(!GhostPreferences.isOn && !tab.ghost.isShowing && tab.ghost.hint == nil
                  && GhostSettingsView.note(on: false).hasPrefix("Off"), "suggestions: the hint's Turn Off turns them off, as Settings shows")
            GhostPreferences.set(true)
        } else {
            check(false, "suggestions: the hint's Turn Off: the hint showed first")
        }

        // Forget This Suggestion, from the menu and from the terminal's own menu: gone from the record, never suggested again.
        if await shows() {
            NSApp.sendAction(#selector(TerminalWindowController.forgetSuggestion(_:)), to: nil, from: nil)
            let found = await ghostQuery("git ch")
            check(!found.contains { $0.line == "git checkout main" } && !tab.ghost.isShowing,
                  "suggestions: Edit › Forget This Suggestion takes it out of the record")
            await ghostClear(tab)
            typeKeys(window, "git ch")
            check(!(await ghostShows(tab, within: 1)), "suggestions: a forgotten one isn't suggested again")
        }
        await ghostSeed("git checkout main", folder: dir.path)
        if await shows() {
            let menu = c.terminalMenu(for: tab, link: nil)
            let item = menu.items.first { $0.title == "Forget This Suggestion" }
            check(item != nil, "suggestions: the terminal's menu offers Forget This Suggestion while one shows")
            if let item, let index = menu.items.firstIndex(of: item) { menu.performActionForItem(at: index) }
            let found = await ghostQuery("git ch")
            check(!found.contains { $0.line == "git checkout main" }, "suggestions: and it takes it out of the record")
        }

        // Private Mode: none shows, nothing is recorded, and the menu item is ticked; off again, back.
        await ghostSeed("git checkout main", folder: dir.path)
        GhostPreferences.setPrivateMode(true)
        let item = NSMenuItem(title: "Private Mode", action: #selector(AppDelegate.togglePrivateMode(_:)), keyEquivalent: "")
        _ = AppDelegate.shared.validateMenuItem(item)
        check(!(await shows()) && item.state == .on, "suggestions: Private Mode shows none, and View › Private Mode is ticked")
        await ghostClear(tab)
        typeKeys(window, "echo nt-ghost-private")
        pressKey(window, "\r", code: 36)
        _ = await wait(3) { tab.status.command == "echo nt-ghost-private" && !tab.status.running }
        await pause(0.3)
        check((await ghostQuery("echo nt-ghost-p")).isEmpty, "suggestions: in Private Mode, nothing is recorded")
        GhostPreferences.setPrivateMode(false)
        check(await shows(), "suggestions: Private Mode off, they come back")
        check(UserDefaults.standard.object(forKey: "ghostTextPrivateMode") == nil, "suggestions: Private Mode is never stored, so a launch starts without it")

        // The count, and Clear History… (only ever the self-test's own record).
        let settings = GhostSettingsView()
        settings.refresh()
        let count = await withCheckedContinuation { (done: CheckedContinuation<Int, Never>) in
            CommandHistoryStore.shared.count { (count: Int) in done.resume(returning: count) }
        }
        check(await wait(2) { settings.keptCount == count } && count > 0, "suggestions: Settings says how many commands are kept",
              "\(String(describing: settings.keptCount)) for \(count)")
        let temporary = CommandHistoryStore.shared.folderURL?.path.hasPrefix(NSTemporaryDirectory()) == true
        guard temporary, let folder = CommandHistoryStore.shared.folderURL else {
            return note("suggestions: Clear History… not checked: the record isn't the self-test's own")
        }
        settings.clearNow()
        check(await wait(3) { settings.keptCount == 0 }, "suggestions: Clear History… leaves none kept")
        let log = folder.appendingPathComponent(CommandHistoryFolder.logName).path
        check(!FileManager.default.fileExists(atPath: log), "suggestions: and the log is gone")
    }

    /// VoiceOver (the session told it is on): one announcement per new suggestion, none for typing through it, and the
    /// overlay never among the terminal's accessibility children.
    static func ghostVoiceOverChecks(_ c: TerminalWindowController, dir: URL) async {
        await ghostSeed("git checkout main", folder: dir.path)
        guard let tab = await ghostTab(c, in: dir, zshrc: plainZshrc, name: "voiceover"), let window = c.window else { return }
        defer { c.remove(tab) }
        GhostSession.testVoiceOver = true
        defer { GhostSession.testVoiceOver = nil }
        let before = tab.ghost.announcements
        typeKeys(window, "git ch")
        guard await ghostShows(tab) else { return check(false, "suggestions, VoiceOver: it showed first", "\(tab.ghost.state)") }
        check(await wait(2) { tab.ghost.announcements == before + 1 }, "suggestions: VoiceOver hears a new one once, after typing stops",
              "\(tab.ghost.announcements - before)")
        typeKeys(window, "e")
        await pause(1)
        check(tab.ghost.announcements == before + 1, "suggestions: typing through it is not a new one for VoiceOver")
        let children = (tab.view.accessibilityChildren() ?? []).compactMap { $0 as? NSView }
        check(!children.contains { $0 is GhostTextView }, "suggestions: the overlay is not among the terminal's accessibility children")
    }

    /// The cold start: with nothing in the record, the shell's own history in memory fills in after a pause; Forget keeps
    /// it from showing again; and none of it is ever recorded. Only with the self-test's own record, emptied first.
    static func ghostFallbackChecks(_ c: TerminalWindowController, dir: URL) async {
        guard CommandHistoryStore.shared.folderURL?.path.hasPrefix(NSTemporaryDirectory()) == true else {
            return note("suggestions from the shell's own history: not checked, the record isn't the self-test's own")
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in CommandHistoryStore.shared.clear { done.resume() } }
        let history = dir.appendingPathComponent("fallback-history").path
        let rc = plainZshrc + "HISTFILE=\(ShellQuote.quote(history))\nprint -s 'kubectl get pods'\n"
        guard let tab = await ghostTab(c, in: dir, zshrc: rc, name: "fallback"), let window = c.window else { return }
        defer { c.remove(tab) }
        typeKeys(window, "kubectl g")
        check(await ghostShows(tab) && tab.ghost.overlay.text == "et pods", "suggestions: with an empty record, zsh's own history fills in after a pause",
              tab.ghost.overlay.text)
        NSApp.sendAction(#selector(TerminalWindowController.forgetSuggestion(_:)), to: nil, from: nil)
        check(!tab.ghost.isShowing, "suggestions: Forget This Suggestion hides one from the shell's history")
        await ghostClear(tab)
        typeKeys(window, "kubectl g")
        check(!(await ghostShows(tab, within: 1.5)), "suggestions: a forgotten line of the shell's history never shows again")
        let count = await withCheckedContinuation { (done: CheckedContinuation<Int, Never>) in
            CommandHistoryStore.shared.count { (count: Int) in done.resume(returning: count) }
        }
        check(count == 0, "suggestions: nothing from the shell's history is recorded", "\(count)")
    }

    /// The record of your commands: a line an agent runs over MCP is never in it; one you type and run is, with its exit,
    /// in the self-test's own folder (SelfTest.historyFolder).
    static func ghostRecordChecks(_ c: TerminalWindowController, dir: URL) async {
        let folder = SelfTest.historyFolder?.path ?? ""
        check(mode != .plain || folder.hasPrefix(NSTemporaryDirectory()), "the record of your commands: the plain self-test keeps its own, in a temporary folder",
              folder)
        guard let tab = await ghostTab(c, in: dir, zshrc: plainZshrc, name: "record"), let window = c.window else { return }
        defer { c.remove(tab) }
        let id = tab.id.uuidString.lowercased()
        let started = tab.status.commandsStarted
        _ = await ghostTool("send_to_tab", ["tab_id": id, "text": "echo ghostagentline"])
        _ = await wait(5) { tab.status.commandsStarted > started && !tab.status.running }
        await pause(0.3)
        typeKeys(window, "echo ghostmineline")
        pressKey(window, "\r", code: 36)
        _ = await wait(5) { tab.status.commandsStarted > started + 1 && !tab.status.running }
        let mine = await ghostQuery("echo ghostmine") { !$0.isEmpty }
        let agent = await ghostQuery("echo ghostagent")
        check(agent.isEmpty, "the record of your commands: a line an agent ran over MCP is not in it", agent.map(\.line).joined(separator: ", "))
        check(mine.first?.line == "echo ghostmineline" && mine.first?.lastExit == 0 && mine.first?.folder == tab.directory,
              "the record of your commands: a line you ran is, with its exit and folder", "\(mine)")
    }
    #endif
}
