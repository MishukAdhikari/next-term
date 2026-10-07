import AppKit
import Darwin
import NextTermCore

/// Remote tabs (Connect VPS) end to end, against a stand-in ssh that runs the "remote" side on this Mac
/// under a fake home (CI has no sshd), and a stand-in master: a Unix socket at the host's control path
/// that accepts connections, as ssh's does. The real ssh is never involved; everything else is the real
/// path: the tab's pty, the base64 scripts, the pid files and connection tokens, the status checks,
/// reconnecting, and the MCP tools. tmux checks run when a tmux binary is found (PATH or
/// NEXTTERM_TEST_TMUX), on a tmux socket folder of the test's own: the user's sessions are never touched.
extension SelfTest {
    static func remoteChecks(_ c: TerminalWindowController) async {
        remoteTabBarChecks()
        remoteMarkShapeChecks()
        remoteFilesNoteChecks()
        #if DEBUG
        await remoteChecksWithStandInSSH(c)
        #else
        note("remote: checks need a debug build (the stand-in ssh is debug-only)")
        #endif
    }

    /// Remote tabs in a tab bar of their own, offscreen, with made-up items: what a tab too narrow for its
    /// whole title keeps, and the ⌘N hints in a narrow bar.
    private static func remoteTabBarChecks() {
        func mark(_ link: RemoteLink) -> RemoteMark { RemoteMark(host: "web-1", destination: "deploy@203.0.113.5", link: link) }
        let items = [
            TabBarItem(title: "next-term", state: .idle, tooltip: "", accessibilityStatus: "Idle", shortcut: "⌘1"),
            TabBarItem(title: "web-1: app (connecting)", state: .idle, tooltip: "", accessibilityStatus: "", shortcut: "⌘2",
                       remote: mark(.connecting), shorterTitles: ["app (connecting)", "app"]),
            TabBarItem(title: "web-1: app (disconnected)", state: .idle, tooltip: "", accessibilityStatus: "", shortcut: "⌘3",
                       remote: mark(.disconnected), shorterTitles: ["app (disconnected)", "app"]),
            TabBarItem(title: "claude", state: .done, tooltip: "", accessibilityStatus: "Done", shortcut: "⌘4"),
        ]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: TabBarView.height), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        func bar(width: CGFloat, with others: [TabBarItem]? = nil, selected: Int = 0) -> TabBarView {
            let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: width, height: TabBarView.height))
            bar.leadingInset = 12
            window.setContentSize(bar.frame.size)
            window.contentView = bar
            bar.update(items: others ?? items, selectedIndex: selected)
            bar.layoutSubtreeIfNeeded()
            return bar
        }
        // The widest tabs (220 pt) have no room for "web-1: app (connecting)" next to the server mark: the
        // host goes, the note stays (the only words for the dot's colour).
        let wide = bar(width: 2000)
        let wideTitles = items.indices.map { wide.shownTitle(at: $0) ?? "" }
        check(wideTitles == ["next-term", "app (connecting)", "app (disconnected)", "claude"],
              "remote tabs: a title that does not fit drops the host first and keeps the connection's note", "\(wideTitles)")
        let narrow = bar(width: 12 + 36 + 24 + TabBarView.minTabWidth * CGFloat(items.count))
        check(narrow.shownTitle(at: 1) == "app" && narrow.shownTitle(at: 2) == "app", "remote tabs: and the narrowest shows the folder alone",
              "\(items.indices.map { narrow.shownTitle(at: $0) ?? "" })")
        // A remote tab's title starts after its server mark, so it has less room for "⌘2" than a local tab:
        // the bar makes one choice for all of them, or the numbering looks broken.
        let uneven = stride(from: TabBarView.minTabWidth, through: 140, by: 2).filter { tabWidth in
            let tabs = bar(width: 12 + 36 + 24 + tabWidth * CGFloat(items.count))
            return Set((1..<items.count).map { tabs.shownShortcut(at: $0) == nil }).count > 1 // the unselected ones
        }
        check(uneven.isEmpty, "remote tabs: in a narrow bar, local and remote tabs show their ⌘N alike", "they differ at tab widths \(uneven)")
        // Selecting a tab (or pointing at it, which shows its × the same way) does not change its words: the
        // tab you look at says what it says among the others.
        let connected = TabBarItem(title: "web-1: app", state: .idle, tooltip: "", accessibilityStatus: "", shortcut: "⌘5",
                                   remote: mark(.connected), shorterTitles: ["app"])
        let all = items + [connected]
        let changing = stride(from: TabBarView.minTabWidth, through: TabBarView.maxTabWidth, by: 2).flatMap { tabWidth -> [String] in
            let width = 12 + 36 + 24 + tabWidth * CGFloat(all.count)
            let unselected = bar(width: width, with: all)
            let shown = (1..<all.count).map { unselected.shownTitle(at: $0) ?? "" }
            return (1..<all.count).compactMap { index -> String? in
                let selected = bar(width: width, with: all, selected: index).shownTitle(at: index) ?? ""
                return selected == shown[index - 1] ? nil : "\(Int(tabWidth)) pt: \(shown[index - 1]) / \(selected)"
            }
        }
        check(changing.isEmpty, "remote tabs: a selected tab keeps the words it has unselected", changing.prefix(4).joined(separator: ", "))
        window.contentView = nil
    }

    /// The server marks read without colour: drawn into a bitmap and taken as ink or not (white is a cut,
    /// like the bar), each connection's mark has a shape of its own. A few pixels at the edges always differ.
    private static func remoteMarkShapeChecks() {
        let size = RemoteMarkView.size
        func shape(_ link: RemoteLink) -> [Bool] {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 3, pixelsHigh: Int(size.height) * 3,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return [] }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            RemoteMarkView.draw(link, tint: .gray, in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            return (0..<rep.pixelsWide * rep.pixelsHigh).map { i in
                guard let pixel = rep.colorAt(x: i % rep.pixelsWide, y: i / rep.pixelsWide) else { return false }
                let lightness = (pixel.redComponent + pixel.greenComponent + pixel.blueComponent) / 3
                return pixel.alphaComponent > 0.5 && lightness < 0.9
            }
        }
        let links: [RemoteLink] = [.connected, .connecting, .disconnected, .ended]
        let shapes = links.map(shape)
        let alike = links.indices.flatMap { i in
            links.indices.filter { $0 > i }.compactMap { j -> String? in
                let differ = zip(shapes[i], shapes[j]).filter { $0 != $1 }.count
                return differ >= 20 ? nil : "\(links[i].rawValue) and \(links[j].rawValue) (\(differ) pixels apart)"
            }
        }
        check(!shapes[0].isEmpty && alike.isEmpty, "remote tabs: each connection's server mark has a shape of its own, not only a colour",
              alike.joined(separator: ", "))
    }

    /// The sidebar's line while a remote tab is active: VoiceOver reads its sentence, not that and then its
    /// parts ("Files on this Mac", "web-1") again after it.
    private static func remoteFilesNoteChecks() {
        let note = RemoteFilesNote(frame: NSRect(x: 0, y: 0, width: 280, height: RemoteFilesNote.height))
        note.show(RemoteMark(host: "web-1", destination: "deploy@203.0.113.5", link: .connected))
        note.layoutSubtreeIfNeeded()
        let parts = (note.accessibilityChildren() ?? []).map { "\(type(of: $0))" }
        check(note.accessibilityLabel()?.hasSuffix("runs on web-1 (deploy@203.0.113.5), connected.") == true && parts.isEmpty,
              "remote tabs: VoiceOver reads the sidebar's line about this Mac's files once, not its parts after it",
              "\(note.accessibilityLabel() ?? "no label") / parts: \(parts)")
    }

    #if DEBUG
    /// Accepts connections on a control path, like a live ssh master; stop() is the connection dropping.
    private final class StandInMaster {
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

    private static func remoteChecksWithStandInSSH(_ c: TerminalWindowController) async {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-remote-\(getpid())")
        let home = base.appendingPathComponent("home")
        let bin = base.appendingPathComponent("bin")
        let project = home.appendingPathComponent("app")
        let tmuxDir = base.appendingPathComponent("tmux") // TMUX_TMPDIR: the test's own tmux servers
        for folder in [project, bin, tmuxDir] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: base) }

        // tmux, if there is one, on the fake host's PATH.
        let tmux = ([ProcessInfo.processInfo.environment["NEXTTERM_TEST_TMUX"]].compactMap { $0 }
                    + ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"])
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        if let tmux { try? FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("tmux").path, withDestinationPath: tmux) }

        // Flags in the test folder: "deny" makes ssh refuse the login (a wrong password), "unreachable"
        // fails the network, "drop" ends a tab's connection (255) once its remote command ends. Only a
        // tab's ssh (-t) takes "drop": a status check (-T) running at that moment must not use it up.
        let fakeSSH = bin.appendingPathComponent("ssh")
        let script = """
            #!/bin/bash
            # Stand-in for ssh: runs the remote command here, through a login shell's -c, like sshd.
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
            B=\(RemoteShell.quote(base.path))
            [ "$op" = exit ] && exit 0
            if [ -e "$B/deny" ]; then echo 'nt@selftest.invalid: Permission denied (publickey).' >&2; exit 255; fi
            if [ -e "$B/unreachable" ]; then echo 'ssh: connect to host selftest.invalid port 22: Connection refused' >&2; exit 255; fi
            export HOME=\(RemoteShell.quote(home.path)) SHELL=/bin/zsh PATH=\(RemoteShell.quote(bin.path)):/usr/bin:/bin:/usr/sbin:/sbin TMUX_TMPDIR="$B/tmux"
            unset ZDOTDIR NEXTTERM_USER_ZDOTDIR
            cd "$HOME"
            /bin/zsh -f -c "$cmd"
            status=$?
            if [ -n "$tty" ] && [ -e "$B/drop" ]; then rm -f "$B/drop"; exit 255; fi
            exit $status
            """
        try? script.write(to: fakeSSH, atomically: true, encoding: .utf8)
        chmod(fakeSSH.path, 0o755)
        RemoteConnection.testSSHPath = fakeSSH.path
        defer { RemoteConnection.testSSHPath = nil }
        func flag(_ name: String, _ on: Bool) {
            let path = base.appendingPathComponent(name).path
            if on { FileManager.default.createFile(atPath: path, contents: nil) } else { unlink(path) }
        }

        func sh(_ line: String) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", line]
            process.environment = ["HOME": home.path, "PATH": bin.path + ":/usr/bin:/bin", "TMUX_TMPDIR": tmuxDir.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }

        let savedHosts = RemoteHosts.all
        defer { RemoteHosts.all = savedHosts }
        var host = RemoteHost(name: "selftest", destination: "nt@selftest.invalid", directory: project.path, keep: .off)
        RemoteHosts.save(host)
        let master = StandInMaster(path: RemoteConnection.controlPath(host))
        master.start()
        defer { master.stop() }
        check(RemoteConnection.masterAlive(host), "remote: a master that accepts connections counts as up")
        let config = RemoteConnection.configFile ?? ""
        check(!config.isEmpty && !config.contains(" ") && (try? String(contentsOfFile: config, encoding: .utf8))?.contains("StrictHostKeyChecking ask") == true,
              "remote: Next Term's ssh config sits at a path with no spaces (ssh passes it to ProxyJump hops unquoted)", config)

        // A plain remote shell: ssh in the tab's pty, the host's prompt, status from the host.
        let plain = c.addRemoteTab(RemoteTab(host: host))
        check(!plain.remoteConnected && plain.title.hasPrefix("selftest: "), "remote: a new tab is named after its host and counts as connecting", plain.title)
        // Its tab: the server mark, with the connection's state on it, in words for VoiceOver too.
        func shownMark(_ tab: TerminalTab? = nil) -> (link: RemoteLink?, spoken: String) {
            c.refresh()
            let index = c.groups.firstIndex { $0.contains(tab ?? plain) } ?? -1
            return (c.tabBar.shownRemoteLink(at: index), c.tabBar.spokenLabel(at: index) ?? "")
        }
        let early = shownMark()
        check(plain.remoteConnected || early.link?.isOnItsWay == true, "remote: the tab's server mark shows the connection on its way",
              "\(early.link?.rawValue ?? "no mark") / \(early.spoken)")
        check(await wait(20) { plain.remoteConnected }, "remote: the host proves this tab's own login (its connection token)")
        let up = shownMark()
        check(up.link == .connected && up.spoken.contains("Remote: selftest (nt@selftest.invalid), connected"),
              "remote: once connected, the tab's mark and its spoken label say so", "\(up.link?.rawValue ?? "no mark") / \(up.spoken)")
        check(plain.paneSummary == "\(plain.title): \(plain.stateDescription)", "remote: and a split tab's line for the pane gives its state",
              plain.paneSummary)
        // The window title names the host once: "selftest: app — …", or "sleep — on selftest — …" (below).
        // It names the editor's file while that has the keyboard, so the tab takes it first.
        c.window?.makeFirstResponder(plain.view)
        c.refresh()
        check(c.activeTab === plain && !c.isEditorFocused, "remote: the new remote tab has the keyboard",
              "\(c.activeTab?.title ?? "no tab") / \(c.window?.firstResponder.map { "\(type(of: $0))" } ?? "nothing")")
        let windowTitle = c.window?.title ?? ""
        check(!c.sidebar.remoteNote.isHidden && c.sidebar.remoteNote.shown?.host == "selftest"
              && windowTitle.hasPrefix("selftest: ") != windowTitle.contains("— on selftest —"),
              "remote: the sidebar says its files are this Mac's, and the window title names the host once",
              "\(c.sidebar.remoteNote.shown?.host ?? "no note") / \(windowTitle)")
        let local = c.groups.firstIndex { $0.focused.remote == nil }
        check(local.map { c.tabBar.shownRemoteLink(at: $0) == nil && !(c.tabBar.spokenLabel(at: $0) ?? "").contains("Remote") } ?? true,
              "remote: a tab on this Mac has no server mark")
        check(await wait(20) { plain.remoteReady }, "remote: the host reports the tab's shell at its prompt",
              plain.screenTail(6).joined(separator: " | "))
        check(!plain.view.opensFiles, "remote: ⌘-click does not open this Mac's files from a remote tab")
        plain.view.send(txt: "sleep 4\r")
        check(await wait(8) { plain.status.running && plain.status.program == "sleep" }, "remote: what runs in front on the host is seen",
              "\(plain.status.running) \(plain.status.program)")
        c.window?.makeFirstResponder(plain.view)
        c.refresh()
        check(c.activeTab === plain && c.window?.title.contains(" — on selftest — ") == true,
              "remote: while a program runs, the window title says on which host", c.window?.title ?? "")
        check(await wait(10) { !plain.status.running }, "remote: and when it ends")
        plain.view.send(txt: "sleep 60 &\r")
        check(await wait(8) { plain.closeWarning?.contains("sleep") == true }, "remote: closing warns about the shell's background jobs on the host",
              plain.closeWarning ?? "nil")
        plain.view.send(txt: "kill %1; printf 'remote-%s\\n' ok\r")
        check(await wait(8) { plain.screenTail(10).contains { $0.contains("remote-ok") } }, "remote: typed commands run on the host")

        // The connection drops: the tab stays, says so, and Return reconnects (a new shell, for keep off).
        let pidFile = home.appendingPathComponent(".cache/next-term/tabs/\(plain.remoteKey)").path
        let pid = Int32(((try? String(contentsOfFile: pidFile, encoding: .utf8)) ?? "").split(separator: " ").first ?? "") ?? 0
        check(pid > 0, "remote: the tab's shell pid is recorded on the host")
        master.stop()
        flag("drop", true)
        if pid > 0 { kill(pid, SIGKILL) }
        check(await wait(10) { plain.disconnected }, "remote: a dropped connection keeps the tab, marked disconnected")
        check(plain.screenTail(4).joined().contains("Return opens a new shell") && plain.title.contains("(disconnected)"),
              "remote: and says so, in the tab and its title", plain.title + " / " + plain.screenTail(4).joined(separator: " | "))
        check(plain.shorterTitles.first?.hasSuffix(" (disconnected)") == true && plain.shorterTitles.first?.hasPrefix("selftest") == false,
              "remote: a tab too narrow for its title drops the host before the note", "\(plain.shorterTitles)")
        let down = shownMark()
        check(down.link == .disconnected && down.spoken.contains("Remote: selftest (nt@selftest.invalid), disconnected")
              && c.sidebar.remoteNote.shown?.link == .disconnected,
              "remote: and on its server mark (and the sidebar's)", "\(down.link?.rawValue ?? "no mark") / \(down.spoken)")
        let plainItem = c.groups.firstIndex { $0.contains(plain) }.flatMap { c.tabBar.items[safe: $0] }
        check(plainItem?.editableTitle == plain.title.replacingOccurrences(of: " (disconnected)", with: ""),
              "remote: renaming it starts from its name without the note (which would stay in the name)",
              "\(plainItem?.editableTitle ?? "no item") / \(plain.title)")
        // The title's note and the remote part: not a third time as the tab's state.
        let saidTimes = down.spoken.lowercased().components(separatedBy: "disconnected").count - 1
        check(saidTimes == 2 && !plain.tooltip.contains("\nDisconnected"), "remote: VoiceOver and the tooltip say the connection once, not as the state too",
              down.spoken + " / " + plain.tooltip.replacingOccurrences(of: "\n", with: " | "))
        // A split tab lists its panes the same way: "selftest: app (disconnected)", not ": Disconnected" after it.
        check(plain.paneSummary == plain.title, "remote: a split tab's line for the pane says the connection once", plain.paneSummary)
        // Split, VoiceOver hears the title, the other pane's line and the remote part: "disconnected" twice,
        // not a third time in the line for the pane the title is named after.
        if let beside = c.split(vertical: true, from: plain, directory: project.path, focus: false) {
            let split = shownMark()
            let splitTimes = split.spoken.lowercased().components(separatedBy: "disconnected").count - 1
            check(splitTimes == 2 && split.spoken.contains("+1"), "remote: a split tab says the connection once besides its title too",
                  split.spoken)
            c.remove(beside)
        } else {
            check(false, "remote: a split beside a remote tab opens")
        }
        check(MCPControl.canType(plain) == false, "remote MCP: nothing is typed into a disconnected tab")
        master.start()
        plain.view.send(txt: "\r")
        check(await wait(20) { !plain.disconnected && plain.remoteReady }, "remote: Return reconnects")

        // A remote shell's own `exit 255` is not a dropped connection: the master is still up.
        let exiting = c.addRemoteTab(RemoteTab(host: host))
        _ = await wait(20) { exiting.remoteReady }
        exiting.view.send(txt: "exit 255\r")
        check(await wait(10) { exiting.exited }, "remote: a shell that exits 255 ends its tab like any shell (not 'connection lost')",
              exiting.screenTail(4).joined(separator: " | "))
        let endedMark = shownMark(exiting)
        check(endedMark.link == .ended && !endedMark.spoken.lowercased().contains("disconnected") && !exiting.title.contains("("),
              "remote: its server mark says the shell ended, not that the connection dropped (Return would not reconnect it)",
              "\(endedMark.link?.rawValue ?? "no mark") / \(exiting.title) / \(endedMark.spoken)")
        c.remove(exiting)

        // MCP: hosts and remote tabs, as an orchestrating agent sees them.
        let server = MCPControlServer.shared
        if let mcp = MCPTestClient(socket: server.path) {
            defer { mcp.close() }
            _ = await mcp.call(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "selftest", "version": "1"]])
            var nextID = 100
            func tool(_ name: String, _ arguments: [String: Any] = [:], timeout: Double = 30) async -> (json: [String: Any]?, text: String, isError: Bool) {
                nextID += 1
                let reply = await mcp.call(nextID, "tools/call", ["name": name, "arguments": arguments], timeout: timeout)
                let result = reply?["result"] as? [String: Any]
                let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "(no answer: \(reply ?? [:]))"
                return ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], text, result?["isError"] as? Bool ?? true)
            }
            let hosts = await tool("list_hosts")
            check(!hosts.isError && hosts.text.contains("nt@selftest.invalid"), "remote MCP: list_hosts shows the host", hosts.text)
            let bad = await tool("add_host", ["name": "evil", "destination": "-oProxyCommand=touch /tmp/x"])
            check(bad.isError, "remote MCP: a destination ssh would read as an option is refused", bad.text)
            let repoint = await tool("add_host", ["name": "selftest", "destination": "nt@elsewhere.invalid"])
            check(repoint.isError && RemoteHosts.all.first { $0.id == host.id }?.destination == host.destination,
                  "remote MCP: add_host does not re-point a saved host", repoint.text)
            let listed = await tool("list_tabs")
            check(listed.text.contains("\"host\" : \"selftest\""), "remote MCP: list_tabs names a remote tab's host", String(listed.text.prefix(400)))
            let probe = await tool("check_host", ["host": "selftest"])
            check(!probe.isError && (probe.json?["os"] as? String)?.contains("Darwin") == true, "remote MCP: check_host reports what the host has", probe.text)

            _ = sh("cd \(RemoteShell.quote(project.path)) && git init -q && git -c user.email=a@b -c user.name=a commit -q --allow-empty -m init && printf 'agent\\n' > done.txt")
            let changes = await tool("host_changes", ["host": "selftest"])
            check(!changes.isError && (changes.json?["files"] as? [String])?.contains("?? done.txt") == true, "remote MCP: host_changes shows what changed there", changes.text)

            let nowhere = await tool("new_remote_tab", ["host": "selftest", "directory": project.path + "/missing", "command": "echo never"], timeout: 60)
            check(nowhere.isError && nowhere.json?["command_typed"] as? Bool == false, "remote MCP: a missing folder is reported, and the command is not run in home", nowhere.text)
            if let id = nowhere.json?["id"] as? String, let tab = c.tabs.first(where: { $0.id.uuidString.lowercased() == id }) { c.remove(tab) }
            let worker = await tool("new_remote_tab", ["host": "selftest", "command": "printf 'worker-%s\\n' up", "title": "remote worker"], timeout: 60)
            let workerID = worker.json?["id"] as? String ?? ""
            check(!worker.isError && worker.json?["command_typed"] as? Bool == true, "remote MCP: new_remote_tab opens a tab and runs the command at the host's prompt", worker.text)
            let workerTab = c.tabs.first { $0.id.uuidString.lowercased() == workerID }
            _ = await wait(8) { workerTab?.screenTail(10).contains { $0.contains("worker-up") } ?? false }
            let read = await tool("read_tab", ["tab_id": workerID])
            check((read.json?["screen"] as? String)?.contains("worker-up") == true, "remote MCP: read_tab reads the remote tab", read.text)
            if let workerTab { c.remove(workerTab) }

            // A login ssh refuses is not retried by itself; a network failure is, until it works.
            host.keep = .tmux
            RemoteHosts.save(host)
            master.stop()
            flag("deny", true)
            let denied = c.addRemoteTab(RemoteTab(host: host, keep: .tmux))
            check(await wait(10) { denied.disconnected }, "remote: a refused login leaves the tab disconnected")
            await pause(3)
            check(denied.disconnected && denied.screenTail(4).joined().contains("ssh could not log in"), "remote: and is not retried by itself",
                  denied.screenTail(4).joined(separator: " | "))
            c.remove(denied)
            flag("deny", false)
            flag("unreachable", true)
            let offline = c.addRemoteTab(RemoteTab(host: host, keep: .off))
            check(await wait(10) { offline.disconnected }, "remote: an unreachable host leaves a plain tab waiting for Return")
            c.remove(offline)
            if tmux != nil {
                let booting = c.addRemoteTab(RemoteTab(host: host, keep: .tmux))
                check(await wait(10) { booting.disconnected && booting.screenTail(4).joined().contains("Trying again") },
                      "remote: a kept tab that cannot reach its host tries again by itself", booting.screenTail(4).joined(separator: " | "))
                flag("unreachable", false)
                master.start()
                check(await wait(20) { !booting.disconnected && booting.remoteConnected }, "remote: and connects once the host answers")

                // Closing a kept tab detaches; the session can be found and reattached, or ended.
                _ = await wait(10) { booting.remoteReady }
                booting.view.send(txt: "sleep 300\r")
                _ = await wait(10) { booting.status.running }
                let session = booting.remote?.session ?? ""
                let closed = await tool("close_tab", ["tab_id": booting.id.uuidString.lowercased()])
                check(closed.json?["detached"] as? Bool == true && closed.json?["still_running"] as? String == "sleep",
                      "remote MCP: close_tab on a kept tab says it only detached, and what still runs", closed.text)
                let listedSessions = await tool("host_sessions", ["host": "selftest"])
                check(listedSessions.text.contains(session), "remote MCP: host_sessions lists the detached session", listedSessions.text)
                let back = await tool("new_remote_tab", ["host": "selftest", "session": session], timeout: 60)
                let backTab = c.tabs.first { $0.id.uuidString.lowercased() == (back.json?["id"] as? String ?? "") }
                check(await wait(20) { backTab?.status.program == "sleep" }, "remote MCP: new_remote_tab with session reattaches to it",
                      backTab?.screenTail(4).joined(separator: " | ") ?? back.text)
                let ended = await tool("close_tab", ["tab_id": backTab?.id.uuidString.lowercased() ?? "", "force": true])
                let gone = await wait(10) { !sh("tmux -L nextterm list-sessions -F '#{session_name}' 2>/dev/null").contains(session) }
                check(ended.json?["session_ended"] as? String == session && gone, "remote MCP: close_tab force ends the session", ended.text)
            } else {
                flag("unreachable", false)
                master.start()
            }
        } else {
            check(false, "remote MCP: `nxtrm mcp` starts")
        }
        c.remove(plain)

        // tmux: the session outlives the connection, and the tab reattaches to it by itself.
        guard tmux != nil else {
            note("remote: no tmux here, tmux checks skipped (set NEXTTERM_TEST_TMUX)")
            return
        }
        host.keep = .tmux
        RemoteHosts.save(host)
        let kept = c.addRemoteTab(RemoteTab(host: host))
        let session = kept.remote?.session ?? ""
        check(await wait(20) { kept.remoteReady }, "remote tmux: the tab's shell runs in Next Term's tmux session",
              kept.screenTail(6).joined(separator: " | "))
        kept.view.send(txt: "export NT_MARK=kept-\(getpid()); echo $NT_MARK\r")
        check(await wait(8) { kept.screenTail(20).contains { $0.contains("kept-\(getpid())") } }, "remote tmux: typed commands run in the session")
        check(sh("tmux -L nextterm list-sessions -F '#{session_name}'").contains(session), "remote tmux: the session is on the host's private tmux server")
        await pause(10.5) // a connection that worked for a while reconnects by itself when it drops
        var clientPID: Int32?
        _ = await wait(10) {
            let listed = sh("tmux -L nextterm list-clients -t \(RemoteShell.quote(session)) -F '#{client_pid}'")
            clientPID = Int32(listed.split(separator: "\n").first?.trimmingCharacters(in: .whitespaces) ?? "")
            return clientPID != nil
        }
        check(clientPID != nil, "remote tmux: the tab is a client of its tmux session", "tmux list-clients found none for \(session)")
        master.stop()
        flag("drop", true)
        if let clientPID { kill(clientPID, SIGKILL) }
        check(await wait(10) { kept.disconnected }, "remote tmux: the dropped connection is seen", kept.screenTail(4).joined(separator: " | "))
        check(sh("tmux -L nextterm list-sessions -F '#{session_name}'").contains(session), "remote tmux: the session keeps running without a client")
        master.start()
        check(await wait(20) { !kept.disconnected && kept.remoteReady }, "remote tmux: the tab reconnects by itself")
        kept.view.send(txt: "echo again-$NT_MARK\r")
        check(await wait(8) { kept.screenTail(20).contains { $0.contains("again-kept-\(getpid())") } }, "remote tmux: to the same session (its shell kept its state)",
              kept.screenTail(8).joined(separator: " | "))
        c.remove(kept)
        check(await wait(5) { sh("tmux -L nextterm list-sessions -F '#{session_name}'").contains(session) }, "remote tmux: closing the tab only detaches")
        _ = sh("tmux -L nextterm kill-server") // the test's own server (TMUX_TMPDIR)
    }
    #endif
}
