import AppKit
import NextTermCore
import SwiftTerm

/// Scrollback on the update and quit paths (R4, KTD9) against real terminals, which Core's tests cannot link. A tab's
/// scrollback is captured as a quit captures it: a token printed across a row wrap is masked, the line of a command that
/// held a secret is blank, a secret on a PS2 row of a shell without the integration is masked, the normal buffer behind
/// the alternate screen is read as text (a secret command wrapped over three rows blank there too), and an agent's pane
/// keeps only what came before its command. The files go through a throwaway sessions folder: read back only for their
/// quit, and none left. A tab given restored scrollback shows it above the divider, each line from the left edge, and a
/// question or an ssh refusal in it is not read as live; the same text printed below the divider hides nothing, and a tab
/// that has started shows none.
extension SelfTest {
    static func scrollbackChecks(proj: URL) async {
        guard let app = AppDelegate.shared else { return }
        let fm = FileManager.default
        let home = canonicalPath(NSTemporaryDirectory()) + "/nt-scrollback-\(getpid())"
        try? fm.removeItem(atPath: home)
        try? fm.createDirectory(atPath: home + "/bin", withIntermediateDirectories: true)
        check(sleepStandIn(at: home + "/bin/claude"), "scrollback: the stand-in claude is made and runs")
        let holder = app.openFolder(proj.path, newWindow: false)
        let tab = holder.addTab(directory: proj.path)
        defer {
            tab.view.send(txt: "\u{03}")
            if let owner = app.controllers.first(where: { $0.tabs.contains { $0 === tab } }) { owner.remove(tab) }
            try? fm.removeItem(atPath: home)
        }
        _ = await wait(20) { tab.status.integrated }
        let terminal = tab.view.getTerminal()

        /// Waits for the shell's line editor to take the line: it switches bracketed paste on as it starts reading one,
        /// after the integration's end mark and the rest of precmd. A line typed before that is echoed by the tty on its
        /// own, a copy without the prompt that the command's echo record does not cover, and is masked rather than blank.
        func atPrompt() async {
            _ = await wait(5) { terminal.bracketedPasteMode && !tab.status.running }
        }
        /// Runs `line` in the tab once its prompt is up, and waits for it to finish.
        func run(_ line: String, seconds: Double = 5) async {
            await atPrompt()
            let before = tab.status.commandsStarted
            tab.view.send(txt: line + "\r")
            _ = await wait(seconds) { tab.status.commandsStarted > before && !tab.status.running }
        }

        // A token printed across a wrap: the line typed holds neither half of it, the output holds it whole.
        let canary = "nt-scrollback-canary-\(getpid())"
        let pad = String(repeating: "x", count: max(1, terminal.cols - 8))
        let token = "ghp_abcdefghijklmnop1234QRST"
        await run("printf '%s\\n' \(canary); printf '%s%s%s\\n' \(pad) ghp_ abcdefghijklmnop1234QRST")
        var text = SessionScrollback.capture(tab).text()
        var lines = text.components(separatedBy: "\r\n")
        check(lines.contains(canary), "scrollback: a tab's output is captured", lines.suffix(6).joined(separator: " | "))
        check(lines.contains(pad + "•••") && !text.contains(token), "scrollback: a token printed across a row wrap is masked",
              lines.suffix(4).joined(separator: " | "))

        // A command whose line held a secret: its line is blank, its output stays.
        let dropped = tab.droppedEchoes.count
        await run("export NT_SELFTEST_TOKEN=ghp_Zq7Lw2Xr9Tb4Mn8Kc1Vd6Hs3; echo dropped-\(canary)")
        text = SessionScrollback.capture(tab).text()
        check(tab.droppedEchoes.count == dropped + 1, "scrollback: a command whose line held a secret is noted",
              "\(tab.droppedEchoes.count)")
        check(text.contains("dropped-" + canary) && !text.contains("NT_SELFTEST_TOKEN") && !text.contains("Zq7Lw2Xr9"),
              "scrollback: its line is blank in the saved scrollback, its output kept",
              text.components(separatedBy: "\r\n").suffix(4).joined(separator: " | "))

        // A shell without the integration: a secret on a PS2 row is masked, the row keeps its prompt.
        let secret = "s3cret-\(getpid())"
        await atPrompt()
        tab.view.send(txt: "/bin/bash --norc --noprofile\r")
        _ = await wait(5) { tab.status.running }
        await pause(1)
        tab.view.send(txt: "true --password \\\r")
        await pause(0.4)
        tab.view.send(txt: secret + "\r")
        await pause(0.4)
        tab.view.send(txt: "exit\r")
        _ = await wait(5) { !tab.status.running }
        text = SessionScrollback.capture(tab).text()
        lines = text.components(separatedBy: "\r\n")
        check(lines.contains("> •••") && !text.contains(secret), "scrollback: a secret on a PS2 continuation row is masked",
              lines.suffix(6).joined(separator: " | "))

        // A command that held a secret, wrapped over three rows or more: its line is blank there, then behind the alternate
        // screen too, where it is found over its rows by what it showed. Its name holds a secret word: a value this short
        // under a plain name is no secret.
        let longSecret = "Hs3Vd6Kc1Mn8Tb4Xr9Lw2Zq7"
        let longPad = String(repeating: "y", count: terminal.cols * 2)
        await run(": \(longPad); export NT_SELFTEST_LONG_TOKEN=\(longSecret); echo long-\(canary)")
        let longText = SessionScrollback.capture(tab).text()
        check(!longText.contains("NT_SELFTEST_LONG") && !longText.contains(longSecret),
              "scrollback: a secret command over three rows is blank", longText.components(separatedBy: "\r\n").suffix(5).joined(separator: " | "))

        // The alternate screen in front: the normal buffer behind it is read as text, and masked by the lines its rows
        // probably were. What it prints there is "alt-only", which the line typed does not hold.
        await atPrompt()
        tab.view.send(txt: "printf '\\e[?1049h%s-%s' alt only; sleep 3; printf '\\e[?1049l'\r")
        if await wait(3, { terminal.isCurrentBufferAlternate }) {
            let behind = SessionScrollback.capture(tab)
            let behindText = behind.text()
            check(behind.firstRow == nil && behind.rows.allSatisfy { $0.wrapped == nil },
                  "scrollback: behind the alternate screen, the normal buffer is read without wrap flags", "\(behind.rows.count) rows")
            check(behind.rows.contains { $0.full == true }, "scrollback: a row a line wrapped from reads as filling the width")
            check(behindText.contains(canary) && !behindText.contains("alt-only") && !behindText.contains(token),
                  "scrollback: it holds the normal buffer's lines, the wrapped token masked across its rows",
                  behindText.components(separatedBy: "\r\n").suffix(6).joined(separator: " | "))
            check(behindText.contains("long-" + canary) && !behindText.contains("NT_SELFTEST_LONG") && !behindText.contains(longSecret),
                  "scrollback: behind it, a secret command wrapped over three rows is blank, its output kept",
                  behindText.components(separatedBy: "\r\n").suffix(8).joined(separator: " | "))
        } else {
            check(false, "scrollback: a tab switches to the alternate screen")
        }
        _ = await wait(6) { !terminal.isCurrentBufferAlternate && !tab.status.running }

        // ⌘K in a full-screen program (herdr, tmux): its own Ctrl+L, for the pane it has in front, never a wipe here of
        // every pane it drew. `cat -v` stands in for its pane: it prints the ^L it was given, and what was drawn stays.
        // The alternate-screen command above must be over first (its sleep would take this line as input).
        _ = await wait(10) { !terminal.isCurrentBufferAlternate && !tab.status.running }
        await atPrompt()
        tab.view.send(txt: "printf '\\e[?1049hPANE-A  PANE-B\\n'; cat -v; printf '\\e[?1049l'\r")
        if await wait(8, { terminal.isCurrentBufferAlternate && tab.screenTail().joined().contains("PANE-A") }) {
            holder.clear(tab)
            let given = await wait(3) { tab.screenTail().joined().contains("^L") }
            check(given && tab.screenTail().joined().contains("PANE-A  PANE-B"),
                  "Clear Buffer in a full-screen program gives it Ctrl+L for its pane, and wipes nothing else it drew",
                  tab.screenTail().suffix(4).joined(separator: " | "))
        } else {
            check(false, "Clear Buffer: a full-screen stand-in starts in the tab",
                  "alternate \(terminal.isCurrentBufferAlternate), running \(tab.status.running): " + tab.screenTail().suffix(3).joined(separator: " | "))
        }
        // ^D twice: the line with the ^L, then the end, so cat stops and the line's printf leaves the alternate screen
        // (^C would stop the whole line, printf too). Whatever happened, the tab is back at its prompt after.
        tab.view.send(txt: "\u{04}\u{04}")
        if !(await wait(6) { !terminal.isCurrentBufferAlternate && !tab.status.running }) {
            tab.view.send(txt: "\u{03}")
            tab.view.feed(text: "\u{1b}[?1049l")
            _ = await wait(4) { !tab.status.running }
        }

        // An agent's pane keeps only what came before its command.
        await atPrompt()
        tab.view.send(txt: home + "/bin/claude 60\r")
        if await wait(10, { tab.status.running && tab.status.kind == .agent }) {
            let agentText = SessionScrollback.capture(tab).text()
            check(tab.runningEcho != nil && agentText.contains(canary) && !agentText.contains("bin/claude"),
                  "scrollback: an agent's pane keeps only what came before its command",
                  agentText.components(separatedBy: "\r\n").suffix(3).joined(separator: " | "))
        } else {
            check(false, "scrollback: a tab runs a stand-in claude", ([tab.status.command] + tab.screenTail(2)).joined(separator: " | "))
        }
        tab.view.send(txt: "\u{03}")
        _ = await wait(5) { !tab.status.running }
        check(tab.runningEcho == nil, "scrollback: the agent's command is forgotten once it ends")

        // A tab that has started shows no restored scrollback: it would land among what its shell printed.
        tab.restoredScrollback = ("late", .update)
        tab.showRestoredScrollback()
        check(tab.restoredScrollback == nil && tab.restoreDivider == nil && !tab.screenTail(6).contains("late"),
              "scrollback: set once a tab has started, it is not shown")

        scrollbackFileChecks(SessionScrollback.capture(tab), home: home)
        scrollbackPrefaceChecks(proj: proj)
    }

    /// The files, in a throwaway sessions folder: only those named for the restored quit are read, a `../` reference
    /// names no file, and none is left after any launch.
    private static func scrollbackFileChecks(_ capture: SessionScrollback.Capture, home: String) {
        let parent = URL(fileURLWithPath: home + "/Application Support", isDirectory: true)
        guard let files = try? SessionFiles.open(in: parent, bundlePath: home + "/Next Term.app"), files.lock() else {
            return check(false, "scrollback: a throwaway sessions folder opens")
        }
        defer { files.unlock() }
        // An update quit names its files for its marker, a quit under Resume for its snapshot's launch id; the ids are
        // chosen at capture, before the file is written.
        let marker = UUID()
        let launch = UUID()
        let text = capture.text()
        let saved = capture.id
        let stray = UUID()
        let quitSaved = UUID()
        check(ScrollbackText.save(text, id: saved, quit: marker, in: files)
              && ScrollbackText.save("another quit's", id: stray, quit: UUID(), in: files)
              && !ScrollbackText.save("", id: UUID(), quit: marker, in: files),
              "scrollback: each pane's text is a file of its own, under the id chosen at capture, and an empty one none")
        let back = ScrollbackText.take([saved, stray], quit: marker, from: files)
        check(back[saved] == text && back[stray] == nil, "scrollback: only the restored update's files are read",
              back.keys.map(\.uuidString).joined(separator: ", "))
        let names = { () -> [String] in ((try? files.names()) ?? ["unreadable"]).filter { $0.hasPrefix(ScrollbackText.filePrefix) } }
        check(names().isEmpty, "scrollback: every scrollback file is gone once read", names().joined(separator: ", "))
        _ = ScrollbackText.save(text, id: quitSaved, quit: launch, in: files)
        check(ScrollbackText.take([quitSaved], quit: launch, from: files)[quitSaved] == text && names().isEmpty,
              "scrollback: a quit restore reads those named for its snapshot's launch id")
        // A crash relaunch, safe mode or a normal launch reads none, and removes them all.
        _ = ScrollbackText.save(text, id: saved, quit: marker, in: files)
        ScrollbackText.removeAll(from: files)
        check(names().isEmpty, "scrollback: a launch that restores no quit removes them unread", names().joined(separator: ", "))
        // A planted reference names no file: the snapshot holds a UUID, and file names are made from UUIDs only.
        check(ScrollbackText.parseFileName(ScrollbackText.filePrefix + "../" + SessionSnapshot.fileName()) == nil
              && ScrollbackText.parseFileName("/etc/passwd") == nil, "scrollback: a planted ../ or absolute name is refused")
    }

    /// Tabs given restored scrollback, never started: the lines above the divider each from the left edge (CR LF, no
    /// staircase), and a question or an ssh refusal among them reads as none where live text is read.
    private static func scrollbackPrefaceChecks(proj: URL) {
        let restored = TerminalTab(directory: proj.path, fontSize: 13)
        let divider = ScrollbackText.SavedAt.update.divider
        restored.restoredScrollback = ("old line one\r\nPermission denied (publickey).\r\nDo you want to proceed? (y/n)", .update)
        restored.showRestoredScrollback()
        let shown = restored.screenTail(10)
        let expected = ["old line one", "Permission denied (publickey).", "Do you want to proceed? (y/n)", divider]
        check(shown == expected && restored.restoredScrollback == nil,
              "scrollback: restored lines show once, above the divider, each from the left edge", shown.joined(separator: " | "))
        check(AgentScreen.activity(screenLines: restored.screenTail()) == .asking("Do you want to proceed?"),
              "scrollback: the replayed question reads as one on the whole screen")
        check(AgentScreen.activity(screenLines: restored.liveTail()) == .idle,
              "scrollback: questions are read only below the divider, so it asks nothing")
        check(TerminalTab.loginRefusal(restored.screenTail(16)) != nil && TerminalTab.loginRefusal(restored.liveTail(16)) == nil,
              "scrollback: a replayed ssh refusal is not this connection's")
        // A program that prints the divider's text after its question hides nothing: the divider is known by its row.
        restored.view.feed(text: "Do you want to proceed? (y/n)\r\n" + divider + "\r\n")
        check(restored.liveTail().contains("Do you want to proceed? (y/n)"),
              "scrollback: the divider's text printed below it hides nothing", restored.liveTail().joined(separator: " | "))

        // After a quit under Resume the divider says so.
        let afterQuit = TerminalTab(directory: proj.path, fontSize: 13)
        afterQuit.restoredScrollback = ("old", .quit)
        afterQuit.showRestoredScrollback()
        check(afterQuit.screenTail(4) == ["old", ScrollbackText.SavedAt.quit.divider],
              "scrollback: after a quit under Resume the divider names the quit", afterQuit.screenTail(4).joined(separator: " | "))
    }
}
