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
    #endif
}
