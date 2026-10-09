import AppKit
import NextTermCore
import SwiftTerm

/// Scrollback on the update path (R4, KTD9) against real terminals, which Core's tests cannot link. A tab's scrollback is
/// captured as an update quit captures it: a token printed across a row wrap is masked, the line of a command that held
/// a secret is blank, a secret on a PS2 row of a shell without the integration is masked, the normal buffer behind the
/// alternate screen is read as text, and an agent's pane keeps only what came before its command. The files go through a
/// throwaway sessions folder: read back only for their marker, and none left. A tab given restored scrollback shows it
/// above the divider, each line from the left edge, and a question in it asks nothing.
extension SelfTest {
    static func scrollbackChecks(proj: URL) async {
        guard let app = AppDelegate.shared else { return }
        let fm = FileManager.default
        let home = canonicalPath(NSTemporaryDirectory()) + "/nt-scrollback-\(getpid())"
        try? fm.removeItem(atPath: home)
        try? fm.createDirectory(atPath: home + "/bin", withIntermediateDirectories: true)
        try? fm.copyItem(atPath: "/bin/sleep", toPath: home + "/bin/claude")
        let holder = app.openFolder(proj.path, newWindow: false)
        let tab = holder.addTab(directory: proj.path)
        defer {
            tab.view.send(txt: "\u{03}")
            if let owner = app.controllers.first(where: { $0.tabs.contains { $0 === tab } }) { owner.remove(tab) }
            try? fm.removeItem(atPath: home)
        }
        _ = await wait(20) { tab.status.integrated }
        let terminal = tab.view.getTerminal()

        /// Runs `line` in the tab and waits for it to finish.
        func run(_ line: String, seconds: Double = 5) async {
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

        // The alternate screen in front: the normal buffer behind it is read as text, and masked by pairs of rows.
        tab.view.send(txt: "printf '\\e[?1049halt-only'; sleep 3; printf '\\e[?1049l'\r")
        if await wait(3, { terminal.isCurrentBufferAlternate }) {
            let behind = SessionScrollback.capture(tab)
            let behindText = behind.text()
            check(behind.firstRow == nil && behind.rows.allSatisfy { $0.wrapped == nil },
                  "scrollback: behind the alternate screen, the normal buffer is read without wrap flags", "\(behind.rows.count) rows")
            check(behindText.contains(canary) && !behindText.contains("alt-only") && !behindText.contains(token),
                  "scrollback: it holds the normal buffer's lines, the wrapped token masked by the row pair",
                  behindText.components(separatedBy: "\r\n").suffix(6).joined(separator: " | "))
        } else {
            check(false, "scrollback: a tab switches to the alternate screen")
        }
        _ = await wait(6) { !terminal.isCurrentBufferAlternate && !tab.status.running }

        // An agent's pane keeps only what came before its command.
        tab.view.send(txt: home + "/bin/claude 60\r")
        if await wait(10, { tab.status.running && tab.status.kind == .agent }) {
            let agentText = SessionScrollback.capture(tab).text()
            check(tab.runningEcho != nil && agentText.contains(canary) && !agentText.contains("bin/claude"),
                  "scrollback: an agent's pane keeps only what came before its command",
                  agentText.components(separatedBy: "\r\n").suffix(3).joined(separator: " | "))
        } else {
            check(false, "scrollback: a tab runs a stand-in claude", tab.status.command)
        }
        tab.view.send(txt: "\u{03}")
        _ = await wait(5) { !tab.status.running }
        check(tab.runningEcho == nil, "scrollback: the agent's command is forgotten once it ends")

        scrollbackFileChecks(text, home: home)
        scrollbackPrefaceChecks(proj: proj)
    }

    /// The files, in a throwaway sessions folder: only those named for the claimed marker are read, a `../` reference
    /// names no file, and none is left after any launch.
    private static func scrollbackFileChecks(_ text: String, home: String) {
        let parent = URL(fileURLWithPath: home + "/Application Support", isDirectory: true)
        guard let files = try? SessionFiles.open(in: parent, bundlePath: home + "/Next Term.app"), files.lock() else {
            return check(false, "scrollback: a throwaway sessions folder opens")
        }
        defer { files.unlock() }
        let marker = UUID()
        let saved = SessionScrollback.save(text, marker: marker, in: files)
        let stray = SessionScrollback.save("another quit's", marker: UUID(), in: files)
        check(saved != nil && stray != nil && SessionScrollback.save("", marker: marker, in: files) == nil,
              "scrollback: each pane's text is a file of its own, and an empty one none")
        guard let saved, let stray else { return }
        let back = SessionScrollback.take([saved, stray], marker: marker, from: files)
        check(back[saved] == text && back[stray] == nil, "scrollback: only the claimed marker's files are read",
              back.keys.map(\.uuidString).joined(separator: ", "))
        let names = { () -> [String] in ((try? files.names()) ?? ["unreadable"]).filter { $0.hasPrefix(ScrollbackText.filePrefix) } }
        check(names().isEmpty, "scrollback: every scrollback file is gone once read", names().joined(separator: ", "))
        // A crash relaunch, safe mode or a normal launch reads none, and removes them all.
        _ = SessionScrollback.save(text, marker: marker, in: files)
        SessionScrollback.removeAll(from: files)
        check(names().isEmpty, "scrollback: a launch that restores no update removes them unread", names().joined(separator: ", "))
        // A planted reference names no file: the snapshot holds a UUID, and file names are made from UUIDs only.
        check(ScrollbackText.parseFileName(ScrollbackText.filePrefix + "../" + SessionSnapshot.fileName()) == nil
              && ScrollbackText.parseFileName("/etc/passwd") == nil, "scrollback: a planted ../ or absolute name is refused")
    }

    /// A tab given restored scrollback, never started: the lines above the divider each from the left edge (CR LF, no
    /// staircase), and a question among them reads as none where questions are read.
    private static func scrollbackPrefaceChecks(proj: URL) {
        let restored = TerminalTab(directory: proj.path, fontSize: 13)
        restored.restoredScrollback = "old line one\r\nold line two\r\nDo you want to proceed? (y/n)"
        restored.showRestoredScrollback()
        let shown = restored.screenTail(10)
        let expected = ["old line one", "old line two", "Do you want to proceed? (y/n)", ScrollbackText.divider]
        check(shown == expected && restored.restoredScrollback == nil,
              "scrollback: restored lines show once, above the divider, each from the left edge", shown.joined(separator: " | "))
        check(AgentScreen.activity(screenLines: restored.screenTail()) == .asking("Do you want to proceed?"),
              "scrollback: the replayed question reads as one on the whole screen")
        check(AgentScreen.activity(screenLines: restored.questionTail()) == .idle,
              "scrollback: questions are read only below the divider, so it asks nothing")
    }
}
