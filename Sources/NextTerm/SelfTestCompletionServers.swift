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

        /// tmux on this Mac (NEXTTERM_TEST_TMUX, or where Homebrew puts it), for the tmux checks.
        var tmux: String? {
            ([ProcessInfo.processInfo.environment["NEXTTERM_TEST_TMUX"]].compactMap { $0 } + ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"])
                .first { FileManager.default.isExecutableFile(atPath: $0) }
        }

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
        // tmux, if there is one, on the fake server's PATH, with a socket folder of its own (TMUX_TMPDIR).
        try? fm.createDirectory(at: server.base.appendingPathComponent("tmux"), withIntermediateDirectories: true)
        if let tmux = server.tmux { try? fm.createSymbolicLink(atPath: server.bin.appendingPathComponent("tmux").path, withDestinationPath: tmux) }
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
            export HOME=\(RemoteShell.quote(server.home.path)) SHELL=/bin/zsh PATH=\(RemoteShell.quote(server.bin.path)):/usr/bin:/bin:/usr/sbin:/sbin TMUX_TMPDIR="$B/tmux"
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

        // In tmux, when there is one: the pane's folder read as the listing runs, on tmux's alternate screen.
        if server.tmux != nil {
            let kept = RemoteHost(name: "complete-tmux", destination: "nt@complete-tmux.invalid", directory: server.project.path, keep: .tmux)
            RemoteHosts.save(kept)
            let keptMaster = CompletionStandInMaster(path: RemoteConnection.controlPath(kept))
            keptMaster.start()
            let inTmux = c.addRemoteTab(RemoteTab(host: kept))
            if await wait(20, { inTmux.remoteConnected && inTmux.remoteReady }), await wait(8, { inTmux.completion.screenReady }), await focus(c, inTmux) {
                inTmux.view.send(txt: "ls fo")
                await pause(0.6)
                pressKey(window, "\t", code: 48)
                check(await wait(4) { popup.isVisible && popup.shownTexts == ["foo", "food.txt"] },
                      "Tab completion, servers: in tmux, `ls fo` lists the pane's folder", "\(popup.shownTexts)")
                pressKey(window, "\u{1b}", code: 53)
                inTmux.view.send(txt: "\u{15}")
            } else {
                check(false, "Tab completion, servers: a tmux tab on the stand-in server is ready", "\(inTmux.completion.reportsSinceReturn)")
            }
            c.remove(inTmux)
            let kill = Process()
            kill.executableURL = server.bin.appendingPathComponent("tmux")
            kill.arguments = ["-L", "nextterm", "kill-server"]
            kill.environment = ["TMUX_TMPDIR": server.base.appendingPathComponent("tmux").path, "PATH": "/usr/bin:/bin"]
            try? kill.run()
            kill.waitUntilExit()
            keptMaster.stop()
        } else {
            note("Tab completion, servers: the tmux check is skipped (no tmux here; NEXTTERM_TEST_TMUX names one)")
        }

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

    /// Step 3, U12 and U13: the hook on a stand-in server, only after the question; zsh's own completions there
    /// (AE7's second half, for zsh: bash's hook waits for the owner's word); a hook deleted on the server, Turn On
    /// Again, Remove leaving the files as they were, and a home that can't be written.
    static func completionServerHookChecks(_ c: TerminalWindowController, dir: URL) async {
        let started = Date()
        defer { note("Tab completion, the server hook: \(String(format: "%.1f", Date().timeIntervalSince(started))) s (budget 120 s)") }
        guard let window = c.window as? TerminalWindow else { return }
        let server = makeCompletionServer(in: dir.appendingPathComponent("hooked"))
        let fm = FileManager.default
        // A git repository with two branches, and zsh's completion system, on the server.
        let repo = server.project.appendingPathComponent("repo")
        try? fm.createDirectory(at: repo, withIntermediateDirectories: true)
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
        try? "PS1='server%# '\nunsetopt beep\nautoload -Uz compinit && compinit -u -D\n".write(to: server.home.appendingPathComponent(".zshrc"),
                                                                                              atomically: true, encoding: .utf8)
        try? fm.createDirectory(at: server.home.appendingPathComponent(".cache/next-term/tabs"), withIntermediateDirectories: true)
        RemoteConnection.testSSHPath = server.bin.appendingPathComponent("ssh").path
        defer { RemoteConnection.testSSHPath = nil }
        let savedHosts = RemoteHosts.all
        defer { RemoteHosts.all = savedHosts }
        let host = RemoteHost(name: "hooked", destination: "nt@hooked.invalid", directory: repo.path, keep: .off)
        RemoteHosts.save(host)
        // The user's own consents are put back after the run.
        let savedConsents = UserDefaults.standard.object(forKey: "remoteCompletionHooks")
        defer {
            if let savedConsents { UserDefaults.standard.set(savedConsents, forKey: "remoteCompletionHooks") }
            else { UserDefaults.standard.removeObject(forKey: "remoteCompletionHooks") }
        }
        CompletionPreferences.mode = .auto
        let cache = server.home.appendingPathComponent(".cache/next-term")
        func cacheFiles() -> [String] { (fm.subpaths(atPath: cache.path) ?? []).filter { !$0.hasPrefix("tabs") }.sorted() }
        func allow() async -> String? {
            var message: String?? = .none
            RemoteCompletionConsent.allow(host, over: window) { message = .some($0) }
            _ = await wait(3) { message != nil || RemoteCompletionConsent.question != nil }
            RemoteCompletionConsent.question?.buttons.first?.performClick(nil)
            _ = await wait(15) { message != nil }
            return message ?? "no answer"
        }

        // No connection: nothing is asked and nothing is written.
        let before = cacheFiles()
        let refused = await allow()
        check(refused?.contains("no open connection") == true && RemoteCompletionConsent.state(host) == .notAllowed && cacheFiles() == before,
              "Tab completion, the server hook: with no connection, Allow says so and writes nothing", refused ?? "nil")
        let master = CompletionStandInMaster(path: RemoteConnection.controlPath(host))
        master.start()
        defer { master.stop() }

        // The question first; Return answers nothing; Cancel writes nothing.
        var answer: String?? = .none
        RemoteCompletionConsent.allow(host, over: window) { answer = .some($0) }
        if await wait(3, { RemoteCompletionConsent.question != nil }), let sheet = window.attachedSheet {
            pressAppKey(sheet, "\r", code: 36)
            await pause(0.4)
            check(RemoteCompletionConsent.question != nil, "Tab completion, the server hook: Return allows nothing")
            RemoteCompletionConsent.question?.buttons.last?.performClick(nil)
        }
        check(await wait(3) { answer != nil } && cacheFiles() == before && RemoteCompletionConsent.state(host) == .notAllowed,
              "Tab completion, the server hook: Cancel writes nothing")

        // A home that can't be written: a message, and still not allowed.
        try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: cache.path)
        let failed = await allow()
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cache.path)
        check(failed?.contains("could not be written") == true && RemoteCompletionConsent.state(host) == .notAllowed && cacheFiles() == before,
              "Tab completion, the server hook: a home that can't be written leaves it off, with a message", failed ?? "nil")

        // Allowed: the files, and the nonce in a file only the user can read.
        let allowed = await allow()
        let nonceFile = cache.appendingPathComponent("completion/nonce")
        let mode = (try? fm.attributesOfItem(atPath: nonceFile.path)[.posixPermissions] as? Int) ?? 0
        let nonce = RemoteCompletionConsent.nonce(for: host) ?? "none"
        check(allowed == nil && RemoteCompletionConsent.state(host) == .allowed && mode == 0o600
              && (try? String(contentsOf: nonceFile, encoding: .utf8)) == nonce + "\n",
              "Tab completion, the server hook: Allow writes the hook, its nonce in a 0600 file", "\(allowed ?? "nil") \(String(mode, radix: 8))")
        let row = RemoteCompletionRow()
        row.show(host, over: window)
        check(row.buttonTitle == "Remove" && row.text.hasPrefix("On:"), "Tab completion, the server hook: New Remote Tab's line says it is on", row.text)

        // With Tab completion Off, a new tab starts without the hook, as a zsh tab on this Mac does.
        CompletionPreferences.set(.off)
        let offTab = c.addRemoteTab(RemoteTab(host: host))
        let offReady = await wait(20) { offTab.remoteConnected && offTab.remoteReady }
        await pause(1)
        check(offReady && offTab.completion.state.arm == nil, "Tab completion, the server hook: a tab opened while it is Off starts without it")
        c.remove(offTab)
        CompletionPreferences.set(.auto)

        // A new tab starts through the hook: zsh's own completions on the server (AE7, zsh).
        let tab = c.addRemoteTab(RemoteTab(host: host))
        let session = tab.completion
        let popup = c.completions.popup
        let armed = await wait(20) { session.state.isArmed }
        check(armed && !session.usesScreen && session.state.arm?.completionSystem == true,
              "Tab completion, the server hook: a new tab's zsh arms under the host's nonce", "\(session.state.phase)")
        check(!tab.status.integrated, "and sends no command marks: its status still comes from the status checks")
        if armed, await focus(c, tab) {
            tab.view.send(txt: "git checkout ")
            await pause(0.5)
            pressKey(window, "\t", code: 48)
            check(await wait(5) { popup.shownTexts.contains("main") && popup.shownTexts.contains("feature/x") },
                  "AE7: `git checkout ` on the server lists its branches, through the hook", "\(popup.shownTexts)")
            if let index = popup.shownTexts.firstIndex(of: "main") {
                for _ in 0..<index { pressKey(window, "", code: 125) }
                pressKey(window, "\r", code: 36)
                check(await wait(3) { promptLine(tab).hasSuffix("git checkout main") }, "and Return puts it on the line, zsh's way", promptLine(tab))
            }
            tab.view.send(txt: "\u{3}")
            _ = await wait(3) { session.state.isArmed }
        }
        // Marks under another nonce are not taken.
        tab.view.feed(text: "\u{1b}]6973;deadbeef;arm;1;main;start;1;0;x;builtin;;0\u{7}")
        check(session.state.arm?.tabWidget != "x", "Tab completion, the server hook: a mark under another nonce is ignored")

        // The connection drops: what the hook said goes with it. The hook is gone on the server too by the time it
        // comes back, so the shell it reconnects to is plain, and a Tab there never sends the private key.
        try? fm.removeItem(at: cache.appendingPathComponent("completion"))
        master.stop()
        tab.view.send(txt: "exit 255\r")
        check(await wait(5) { tab.disconnected } && session.state.arm == nil && session.usesScreen,
              "Tab completion, the server hook: a dropped connection forgets what the hook said", "\(session.state.phase)")
        master.start()
        tab.reconnect()
        if await wait(20, { tab.remoteConnected && tab.remoteReady }), await wait(8, { session.screenReady }), await focus(c, tab) {
            tab.view.send(txt: "ls ~/app/fo")
            await pause(0.5)
            pressKey(window, "\t", code: 48)
            await pause(1)
            var privateKey = false
            if case .privateKey = session.lastTab { privateKey = true }
            check(!privateKey && session.state.arm == nil && !tab.screenTail(3).joined().contains("6973"),
                  "and a Tab in the plain shell it reconnects to sends no private key", "\(session.lastTab) | \(promptLine(tab))")
            if popup.isVisible { pressKey(window, "\u{1b}", code: 53) }
            tab.view.send(txt: "\u{15}")
            // Off, its status reports check nothing on the server (the hook deleted there still reads as on here); on
            // again, they do.
            CompletionPreferences.set(.off)
            await pause(1)
            RemoteCompletionConsent.forgetChecks()
            if RemoteCompletionConsent.state(host) == .allowed {
                let reports = session.reportsSinceReturn
                _ = await wait(8) { session.reportsSinceReturn >= reports + 2 }
                check(RemoteCompletionConsent.state(host) == .allowed, "Tab completion, the server hook: Off, the status reports check nothing there")
                CompletionPreferences.set(.auto)
                check(await wait(8) { RemoteCompletionConsent.state(host) == .removedOnServer }, "and on, they check it again")
            } else {
                note("Tab completion, the server hook: the Off check is skipped (a check had already found the hook gone)")
            }
            CompletionPreferences.set(.auto)
        } else {
            check(false, "Tab completion, the server hook: the tab reconnects to the stand-in server", tab.screenTail(3).joined(separator: " | "))
        }
        c.remove(tab)

        // Deleted on the server: the host says so, and the next tab starts plain. Never put back by Next Term.
        try? fm.removeItem(at: cache.appendingPathComponent("completion"))
        RemoteCompletionConsent.verify(host, force: true)
        check(await wait(5) { RemoteCompletionConsent.state(host) == .removedOnServer }, "Tab completion, the server hook: one deleted there shows as removed")
        let plain = c.addRemoteTab(RemoteTab(host: host))
        _ = await wait(20) { plain.remoteConnected && plain.remoteReady }
        await pause(1)
        check(plain.completion.usesScreen && !fm.fileExists(atPath: cache.appendingPathComponent("completion").path),
              "and the next tab starts plain, with the hook left deleted")
        c.remove(plain)
        row.show(host, over: window)
        check(row.buttonTitle == "Turn On Again", "Tab completion, the server hook: New Remote Tab offers Turn On Again", row.buttonTitle)

        // Turn On Again: a new nonce. Remove: the files as they were before Allow, and the nonce forgotten.
        let again = await allow()
        let second = RemoteCompletionConsent.nonce(for: host)
        check(again == nil && second != nil && second != nonce, "Tab completion, the server hook: Turn On Again writes it with a new nonce")
        var removed: String?? = .none
        RemoteCompletionConsent.remove(host) { removed = .some($0) }
        _ = await wait(10) { removed != nil }
        check(removed == .some(nil) && cacheFiles() == before && RemoteCompletionConsent.nonce(for: host) == nil,
              "Tab completion, the server hook: Remove leaves the server's files as they were", "\(Set(cacheFiles()).symmetricDifference(before).sorted())")

        // A host removed from Next Term takes its consent with it.
        _ = await allow()
        RemoteHosts.remove(id: host.id)
        check(RemoteCompletionConsent.state(host) == .notAllowed, "Tab completion, the server hook: a removed host's consent goes with it")
    }
    #endif
}

extension CompletionSession.TabOutcome {
    var isListing: Bool {
        if case .listing = self { return true }
        return false
    }
}
