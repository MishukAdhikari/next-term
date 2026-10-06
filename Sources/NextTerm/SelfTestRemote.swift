import AppKit
import NextTermCore

/// Remote tabs (Connect VPS) end to end, against a stand-in ssh that runs the "remote" side on this Mac
/// under a fake home (CI has no sshd). The real ssh is never involved; everything else is the real path:
/// the tab's pty, the base64 scripts, the pid files, the status checks over the "master", reconnecting,
/// and the MCP tools. tmux checks run when a tmux binary is found (PATH or NEXTTERM_TEST_TMUX).
extension SelfTest {
    static func remoteChecks(_ c: TerminalWindowController) async {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-remote-\(getpid())")
        let home = base.appendingPathComponent("home")
        let bin = base.appendingPathComponent("bin")
        let project = home.appendingPathComponent("app")
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // tmux, if there is one, on the fake host's PATH.
        let tmux = ([ProcessInfo.processInfo.environment["NEXTTERM_TEST_TMUX"]].compactMap { $0 }
                    + ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"])
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        if let tmux { try? FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("tmux").path, withDestinationPath: tmux) }

        let fakeSSH = bin.appendingPathComponent("ssh")
        let script = """
            #!/bin/bash
            # Stand-in for ssh: runs the remote command here, through a login shell's -c, like sshd.
            cp=""; op=""; cmd=""
            while [ $# -gt 0 ]; do
              case "$1" in
                -o) case "$2" in ControlPath=*) cp=${2#ControlPath=}; cp=${cp#\\"}; cp=${cp%\\"};; esac; shift 2;;
                -p) shift 2;;
                -O) op=$2; shift 2;;
                --) cmd=$3; shift $#;;
                *) shift;;
              esac
            done
            if [ "$op" = exit ]; then rm -f "$cp"; exit 0; fi
            [ -n "$cp" ] && : > "$cp"
            export HOME=\(RemoteShell.quote(home.path)) SHELL=/bin/zsh PATH=\(RemoteShell.quote(bin.path)):/usr/bin:/bin:/usr/sbin:/sbin
            unset ZDOTDIR NEXTTERM_USER_ZDOTDIR
            cd "$HOME"
            /bin/zsh -f -c "$cmd"
            status=$?
            if [ -e "$HOME/drop" ]; then rm -f "$HOME/drop"; exit 255; fi
            exit $status
            """
        try? script.write(to: fakeSSH, atomically: true, encoding: .utf8)
        chmod(fakeSSH.path, 0o755)
        RemoteConnection.testSSHPath = fakeSSH.path
        defer { RemoteConnection.testSSHPath = nil }

        func sh(_ line: String) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", line]
            process.environment = ["HOME": home.path, "PATH": bin.path + ":/usr/bin:/bin"]
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

        // A plain remote shell: ssh in the tab's pty, the host's prompt, status from the host.
        let plain = c.addRemoteTab(RemoteTab(host: host))
        check(plain.remote != nil && plain.title.hasPrefix("selftest: "), "remote: a tab on a host is named after it", plain.title)
        check(await wait(20) { plain.remoteReady }, "remote: the host reports the tab's shell at its prompt",
              plain.screenTail(6).joined(separator: " | "))
        plain.view.send(txt: "sleep 4\r")
        check(await wait(8) { plain.status.running && plain.status.program == "sleep" }, "remote: what runs in front on the host is seen",
              "\(plain.status.running) \(plain.status.program)")
        check(await wait(10) { !plain.status.running }, "remote: and when it ends")
        plain.view.send(txt: "printf 'remote-%s\\n' ok\r")
        check(await wait(8) { plain.screenTail(10).contains { $0.contains("remote-ok") } }, "remote: typed commands run on the host")
        check(plain.closeWarning == nil, "remote: an idle plain remote tab closes without asking")

        // The connection drops: the tab stays, says so, and Return reconnects (a new shell, for keep off).
        let pidFile = home.appendingPathComponent(".cache/next-term/tabs/\(plain.remoteKey)").path
        let pid = Int32((try? String(contentsOfFile: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        check(pid > 0, "remote: the tab's shell pid is recorded on the host")
        FileManager.default.createFile(atPath: home.appendingPathComponent("drop").path, contents: nil)
        if pid > 0 { kill(pid, SIGKILL) }
        check(await wait(10) { plain.disconnected }, "remote: a dropped connection keeps the tab, marked disconnected")
        check(plain.screenTail(4).joined().contains("Return opens a new shell"), "remote: and says how to reconnect",
              plain.screenTail(4).joined(separator: " | "))
        check(!plain.exited && plain.stateDescription == "Disconnected", "remote: the tab is not gone")
        plain.view.send(txt: "\r")
        check(await wait(20) { !plain.disconnected && plain.remoteReady }, "remote: Return reconnects")

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
            let listed = await tool("list_tabs")
            check(listed.text.contains("\"host\" : \"selftest\""), "remote MCP: list_tabs names a remote tab's host", String(listed.text.prefix(400)))
            let probe = await tool("check_host", ["host": "selftest"])
            check(!probe.isError && (probe.json?["os"] as? String)?.contains("Darwin") == true, "remote MCP: check_host reports what the host has", probe.text)

            _ = sh("cd \(RemoteShell.quote(project.path)) && git init -q && git -c user.email=a@b -c user.name=a commit -q --allow-empty -m init && printf 'agent\\n' > done.txt")
            let changes = await tool("host_changes", ["host": "selftest"])
            check(!changes.isError && (changes.json?["files"] as? [String])?.contains("?? done.txt") == true, "remote MCP: host_changes shows what changed there", changes.text)

            let worker = await tool("new_remote_tab", ["host": "selftest", "command": "printf 'worker-%s\\n' up", "title": "remote worker"], timeout: 60)
            let workerID = worker.json?["id"] as? String ?? ""
            check(!worker.isError && worker.json?["command_typed"] as? Bool == true, "remote MCP: new_remote_tab opens a tab and runs the command at the host's prompt", worker.text)
            let workerTab = c.tabs.first { $0.id.uuidString.lowercased() == workerID }
            _ = await wait(8) { workerTab?.screenTail(10).contains { $0.contains("worker-up") } ?? false }
            let read = await tool("read_tab", ["tab_id": workerID])
            check((read.json?["screen"] as? String)?.contains("worker-up") == true, "remote MCP: read_tab reads the remote tab", read.text)
            if let tab = c.tabs.first(where: { $0.id.uuidString.lowercased() == workerID }) { c.remove(tab) }
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
        let client = sh("tmux -L nextterm list-clients -t \(RemoteShell.quote(session)) -F '#{client_pid}'").trimmingCharacters(in: .whitespacesAndNewlines)
        FileManager.default.createFile(atPath: home.appendingPathComponent("drop").path, contents: nil)
        if let clientPID = Int32(client.split(separator: "\n").first ?? "") { kill(clientPID, SIGKILL) }
        check(await wait(10) { kept.disconnected }, "remote tmux: the dropped connection is seen")
        check(sh("tmux -L nextterm list-sessions -F '#{session_name}'").contains(session), "remote tmux: the session keeps running without a client")
        check(await wait(20) { !kept.disconnected && kept.remoteReady }, "remote tmux: the tab reconnects by itself")
        kept.view.send(txt: "echo again-$NT_MARK\r")
        check(await wait(8) { kept.screenTail(20).contains { $0.contains("again-kept-\(getpid())") } }, "remote tmux: to the same session (its shell kept its state)",
              kept.screenTail(8).joined(separator: " | "))
        c.remove(kept)
        check(await wait(5) { sh("tmux -L nextterm list-sessions -F '#{session_name}'").contains(session) }, "remote tmux: closing the tab only detaches")
        _ = sh("tmux -L nextterm kill-server")
    }
}
