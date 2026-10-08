import AppKit
import Darwin
import NextTermCore

/// Tab completion in server tabs, against a stand-in ssh that runs the "server" here under a fake home (CI has no
/// sshd), copied from the remote checks' with flags of its own: "slow" holds each check 2 s, "drop" ends each
/// check with ssh's 255 and nothing printed, "refused" refuses each check as sshd does past MaxSessions. Real key
/// events go through the window, as in the other completion checks.
extension SelfTest {
    #if DEBUG
    /// Accepts connections on a control path, as a live ssh master does (the remote checks have their own).
    private final class CompletionStandInMaster {
        let path: String
        private var source: DispatchSourceRead?

        init(path: String) { self.path = path }

        func start() {
            guard source == nil else { return }
            unlink(path)
            let sock = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: bytes)
                buffer[bytes.count] = 0
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, listen(sock, 16) == 0 else { close(sock); return }
            let source = DispatchSource.makeReadSource(fileDescriptor: sock, queue: .global())
            source.setEventHandler { let client = accept(sock, nil, nil); if client >= 0 { close(client) } }
            source.setCancelHandler { close(sock) }
            source.resume()
            self.source = source
        }

        func stop() {
            source?.cancel()
            source = nil
            unlink(path)
        }
    }

    /// The fake server: its home (with `app/` and a few names in it), its bin with a stand-in ssh, and its flags.
    struct CompletionServer {
        let base: URL
        var home: URL { base.appendingPathComponent("home") }
        var bin: URL { base.appendingPathComponent("bin") }
        var project: URL { home.appendingPathComponent("app") }

        func flag(_ name: String, _ on: Bool) {
            let path = base.appendingPathComponent(name).path
            if on { FileManager.default.createFile(atPath: path, contents: nil) } else { unlink(path) }
        }

        /// Every file under the fake home but the shell's own history and the tabs' pid files (written by the tab's
        /// own script at login): what "nothing written" compares.
        func files() -> [String] {
            let all = FileManager.default.subpaths(atPath: home.path) ?? []
            return all.filter { !$0.hasPrefix(".zsh_history") && !$0.hasPrefix(".cache/next-term/tabs") && $0 != ".cache/next-term/tmux.conf" }.sorted()
        }
    }

    static func makeCompletionServer(in dir: URL) -> CompletionServer {
        let server = CompletionServer(base: dir.appendingPathComponent("server"))
        let fm = FileManager.default
        for folder in ["foo", "Sources", "lib"] {
            try? fm.createDirectory(at: server.project.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try? fm.createDirectory(at: server.bin, withIntermediateDirectories: true)
        for file in ["food.txt", "My file.txt"] { fm.createFile(atPath: server.project.appendingPathComponent(file).path, contents: nil) }
        let script = """
            #!/bin/bash
            # Stand-in for ssh: runs the remote command here, through a login shell's -c, like sshd. Stdin is the
            # command's, as ssh's is.
            op=""; cmd=""; tty=""
            while [ $# -gt 0 ]; do
              case "$1" in
                -o|-p|-F) shift 2;;
                -O) op=$2; shift 2;;
                -t) tty=1; shift;;
                --) cmd=$3; shift $#;;
                *) shift;;
              esac
            done
            B=\(RemoteShell.quote(server.base.path))
            [ "$op" = exit ] && exit 0
            if [ -z "$tty" ] && [ -e "$B/refused" ]; then echo 'mux_client_request_session: session request failed: Session open refused by peer' >&2; exit 255; fi
            if [ -z "$tty" ] && [ -e "$B/drop" ]; then exit 255; fi
            if [ -z "$tty" ] && [ -e "$B/slow" ]; then sleep 2; fi
            export HOME=\(RemoteShell.quote(server.home.path)) SHELL=/bin/zsh PATH=\(RemoteShell.quote(server.bin.path)):/usr/bin:/bin:/usr/sbin:/sbin
            unset ZDOTDIR NEXTTERM_USER_ZDOTDIR
            cd "$HOME"
            exec /bin/zsh -f -c "$cmd"
            """
        let ssh = server.bin.appendingPathComponent("ssh")
        try? script.write(to: ssh, atomically: true, encoding: .utf8)
        chmod(ssh.path, 0o755)
        // The server's zsh: a plain prompt, and no beep.
        try? "PS1='server%# '\nunsetopt beep\n".write(to: server.home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        return server
    }

    /// Step 3, U11: a server tab whose shell has no hook. Tab lists the server's folders and files over the tab's
    /// connection, for a plain word read off the screen, and nothing is written there.
    static func completionServerChecks(_ c: TerminalWindowController, dir: URL) async {
        let started = Date()
        defer { note("Tab completion, servers: \(String(format: "%.1f", Date().timeIntervalSince(started))) s (budget 120 s)") }
        guard let window = c.window as? TerminalWindow else { return }
        let server = makeCompletionServer(in: dir)
        RemoteConnection.testSSHPath = server.bin.appendingPathComponent("ssh").path
        defer { RemoteConnection.testSSHPath = nil }
        let savedHosts = RemoteHosts.all
        defer { RemoteHosts.all = savedHosts }
        let host = RemoteHost(name: "complete", destination: "nt@complete.invalid", directory: server.project.path, keep: .off)
        RemoteHosts.save(host)
        let master = CompletionStandInMaster(path: RemoteConnection.controlPath(host))
        master.start()
        defer { master.stop() }
        RemoteCompletion.shared.forget()
        CompletionPreferences.mode = .auto

        let tab = c.addRemoteTab(RemoteTab(host: host))
        defer { c.remove(tab) }
        let session = tab.completion
        let popup = c.completions.popup
        guard await wait(20, { tab.remoteConnected && tab.remoteReady }) else {
            return check(false, "Tab completion, servers: the stand-in server's tab connects", tab.screenTail(4).joined(separator: " | "))
        }
        let before = server.files()
        check(session.usesScreen && tab.tooltip.contains("server’s folders and files"), "Tab completion, servers: a tab with no hook reads its screen",
              tab.tooltip.replacingOccurrences(of: "\n", with: " | "))
        guard await wait(8, { session.screenReady }), await focus(c, tab) else {
            return check(false, "Tab completion, servers: the tab is ready after two status reports", "\(session.reportsSinceReturn)")
        }
        func tabKey() { pressKey(window, "\t", code: 48) }
        /// ^U: the line is cleared without a Return (which would wait for two more reports).
        func clear() async {
            tab.view.send(txt: "\u{15}")
            await pause(0.4)
        }
        func type(_ line: String) async {
            tab.view.send(txt: line)
            await pause(0.5)
        }

        // `cd /va`: the folder goes in, over the connection (AE7's first half). Here `/private` matches too (v, a in
        // order), so the list may open with var first.
        await type("cd /va")
        tabKey()
        check(session.lastTab.isListing, "Tab completion, servers: a real Tab lists the server's folder", "\(session.lastTab)")
        if await wait(3, { popup.isVisible || promptLine(tab).hasSuffix("cd /var/") }), popup.isVisible {
            check(popup.shownTexts.first == "var", "Tab completion, servers: `/va` lists var first", "\(popup.shownTexts)")
            pressKey(window, "\r", code: 36)
        }
        check(await wait(3) { promptLine(tab).hasSuffix("cd /var/") } && !popup.isVisible, "AE7: `cd /va` + Tab gives `cd /var/` on a server",
              promptLine(tab))
        await clear()

        // `ls ~/app/fo`: the list opens; typing narrows it from the screen; Return puts the name on the line.
        await type("ls ~/app/fo")
        tabKey()
        check(await wait(3) { popup.isVisible && popup.shownTexts == ["foo", "food.txt"] }, "Tab completion, servers: `ls ~/app/fo` lists foo and food.txt",
              "\(popup.shownTexts)")
        check(window.firstResponder === tab.view, "Tab completion, servers: the terminal keeps the keyboard")
        typeKeys(window, "od")
        check(await wait(3) { popup.shownTexts == ["food.txt"] }, "Tab completion, servers: typing narrows the list from the screen", "\(popup.shownTexts)")
        pressKey(window, "\r", code: 36)
        check(await wait(3) { promptLine(tab).hasSuffix("ls ~/app/food.txt") } && !popup.isVisible,
              "Tab completion, servers: Return types the rest of the name", promptLine(tab))
        await clear()

        // The shell's own folder (lsof on this Mac's stand-in, /proc on Linux), and a name with a space, quoted.
        await type("cat My")
        tabKey()
        check(await wait(3) { promptLine(tab).hasSuffix("cat My\\ file.txt") }, "Tab completion, servers: a name in the shell's folder goes in quoted",
              promptLine(tab))
        await clear()

        // A word that stops being plain closes the list; a quoted word gets the shell's own Tab.
        await type("ls ~/app/")
        tabKey()
        if await wait(3, { popup.isVisible }) {
            typeKeys(window, "f")
            _ = await wait(2) { popup.shownTexts.first == "foo" }
            pressKey(window, "'", code: 39)
            check(await wait(3) { !popup.isVisible }, "Tab completion, servers: a word that stops being plain closes the list")
        } else {
            check(false, "Tab completion, servers: `ls ~/app/` opens the list")
        }
        await clear()
        await type("ls 'fo")
        tabKey()
        check(await wait(2) { session.lastWrite == [0x09] } && !popup.isVisible, "Tab completion, servers: a quoted word gets the shell's own Tab",
              "\(session.lastWrite)")
        await clear()

        // A slow server: the shell's own Tab after the deadline; keys typed while it lists go after that Tab.
        RemoteCompletion.shared.forget()
        server.flag("slow", true)
        await type("ls ~/app/li")
        tabKey()
        check(await wait(3) { promptLine(tab).hasSuffix("ls ~/app/lib/") }, "Tab completion, servers: a listing that takes too long is the shell's own Tab",
              promptLine(tab))
        await clear()
        RemoteCompletion.shared.forget()
        await type("ls ~/app/li")
        tabKey()
        typeKeys(window, "x")
        check(await wait(3) { promptLine(tab).hasSuffix("ls ~/app/lib/x") }, "Tab completion, servers: keys typed while it lists go after the shell's own Tab",
              promptLine(tab))
        server.flag("slow", false)
        await clear()
        // A dropped check: the shell's own Tab.
        RemoteCompletion.shared.forget()
        _ = await wait(4) { !(tab.controlPath.map(RemoteCompletion.shared.isListing(on:)) ?? false) }
        server.flag("drop", true)
        await type("ls ~/app/li")
        tabKey()
        check(await wait(3) { promptLine(tab).hasSuffix("ls ~/app/lib/") }, "Tab completion, servers: a check that drops gives the shell's own Tab",
              promptLine(tab))
        server.flag("drop", false)
        await clear()

        // Right after Return the poll lags: Tab is the shell's own until the second report.
        tab.view.send(txt: "cd ~/app\r")
        await pause(0.3)
        await type("ls fo")
        let lagging = session.screenReady
        tabKey()
        check(!lagging && session.lastTab == .plain, "Tab completion, servers: a Tab right after Return is the shell's own (the poll lags)",
              "\(session.reportsSinceReturn) reports")
        await clear()
        check(await wait(8) { session.screenReady }, "and Tab completes again after the second report", "\(session.reportsSinceReturn) reports")

        // Off: no prefetch when the folder changes. Only where the status checks report the shell's folder (/proc).
        if session.serverFolderKnown {
            CompletionPreferences.set(.off)
            RemoteCompletion.shared.forget()
            tab.view.send(txt: "cd ~/app/Sources\r")
            _ = await wait(8) { tab.directory.hasSuffix("/Sources") && session.reportsSinceReturn >= 3 }
            check(!RemoteCompletion.shared.cachedKeys.contains { $0.hasSuffix("/Sources") }, "Tab completion, servers: Off, no folder is prefetched")
            CompletionPreferences.set(.auto)
            tab.view.send(txt: "cd ~/app/lib\r")
            check(await wait(8) { RemoteCompletion.shared.cachedKeys.contains { $0.hasSuffix("/app/lib") } },
                  "Tab completion, servers: on, the tab's new folder is prefetched", "\(RemoteCompletion.shared.cachedKeys.count) kept")
        } else {
            note("Tab completion, servers: prefetch checks skipped (this server's checks report no folder: no /proc)")
        }

        // Seven tabs on one connection: Tab is the shell's own, nothing is listed, and the status checks go on.
        var others: [TerminalTab] = []
        for _ in 0..<6 { others.append(c.addRemoteTab(RemoteTab(host: host), select: false)) }
        _ = await wait(20) { others.allSatisfy(\.remoteConnected) }
        _ = await focus(c, tab)
        let path = tab.controlPath ?? ""
        let crowded = AppDelegate.shared.controllers.flatMap(\.tabs).filter { $0.controlPath == path && !$0.exited }.count
        RemoteCompletion.shared.forget()
        await type("ls ~/app/fo")
        tabKey()
        check(crowded >= 7 && session.lastTab == .plain && !RemoteCompletion.shared.isListing(on: path),
              "Tab completion, servers: on a connection with 7 tabs, Tab is the shell's own and nothing is listed", "\(crowded) tabs, \(session.lastTab)")
        await clear()
        tab.view.send(txt: "sleep 3\r")
        check(await wait(8) { tab.status.running }, "and the status checks go on")
        _ = await wait(8) { !tab.status.running }
        for other in others { c.remove(other) }

        check(server.files() == before, "Tab completion, servers: nothing was written under the server's home",
              "\(Set(server.files()).symmetricDifference(before).sorted().prefix(6))")

        // A connection that refuses sessions (sshd's MaxSessions): the shell's own Tab. Last: checks pause 30 s.
        _ = await focus(c, tab)
        _ = await wait(8) { session.screenReady }
        RemoteCompletion.shared.forget()
        server.flag("refused", true)
        await type("ls ~/app/li")
        tabKey()
        check(await wait(3) { promptLine(tab).hasSuffix("ls ~/app/lib/") }, "Tab completion, servers: a refused session gives the shell's own Tab",
              promptLine(tab))
        await clear()
        await type("ls ~/app/li")
        tabKey()
        check(session.lastTab == .plain, "and Tab stays the shell's own while the connection refuses", "\(session.lastTab)")
        server.flag("refused", false)
        await clear()
    }
    #endif
}

extension CompletionSession.TabOutcome {
    var isListing: Bool {
        if case .listing = self { return true }
        return false
    }
}
