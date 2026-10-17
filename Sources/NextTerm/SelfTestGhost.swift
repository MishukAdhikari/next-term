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
