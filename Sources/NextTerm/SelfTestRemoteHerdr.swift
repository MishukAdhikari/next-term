import AppKit
import Darwin
import NextTermCore
import SwiftTerm

/// herdr tabs against the stand-in ssh (SelfTestRemote): on a host without herdr, the tab says where it looked and points
/// to herdr's install page; once herdr is there, that tab says so; a herdr found on the login shell's PATH is what a new
/// tab runs, its agents are the tab's, a list that fails is said in herdr's words, and a right-click reaches it. The
/// host's PATH starts with a stand-in pgrep that finds no herdr server, so a herdr the user runs on this Mac is never
/// found, and its login shell is a stand-in that runs what it is given (the "loginsh" flag).
extension SelfTest {
    #if DEBUG
    static func remoteHerdrChecks(_ c: TerminalWindowController, host saved: RemoteHost, base: URL, home: URL, bin: URL,
                                  flag: (String, Bool) -> Void) async {
        let fm = FileManager.default
        func script(_ url: URL, _ body: String) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            chmod(url.path, 0o755)
        }
        let herdr = bin.appendingPathComponent("herdr")
        let pgrep = bin.appendingPathComponent("pgrep")
        script(pgrep, "exit 1")
        // The host's login shell: a real zsh when asked for a shell of its own, else the command it is given.
        script(base.appendingPathComponent("shells/zsh"), """
            [ "$1" = -l ] && [ $# -eq 1 ] && exec /bin/zsh -l
            while [ $# -gt 1 ]; do shift; done
            exec /bin/sh -c "$1"
            """)
        flag("loginsh", true)
        defer {
            flag("loginsh", false)
            unlink(herdr.path)
            unlink(pgrep.path)
        }
        var host = saved
        host.keep = .herdr
        RemoteHosts.save(host)

        // No herdr on the host: a plain shell that says where Next Term looked, and where herdr is installed from.
        let onThisMac = ["/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"].contains { fm.isExecutableFile(atPath: $0) }
        var fellBack: TerminalTab?
        if onThisMac {
            note("remote herdr: herdr is installed on this Mac where a host's finder looks; the missing-herdr checks are skipped")
        } else {
            let tab = c.addRemoteTab(RemoteTab(host: host, keep: .herdr))
            fellBack = tab
            let fell = await wait(20) { tab.remoteConnected && tab.fellBack }
            let screen = tab.screenTail(12).joined()
            check(fell && screen.contains("herdr was not found on this host") && screen.contains(RemoteShell.herdrInstallPage),
                  "remote herdr: a host without herdr gives a plain shell that says where Next Term looked and links herdr's install page",
                  tab.screenTail(8).joined(separator: " | "))
            let info = MCPControl.describe(tab, in: c, caller: nil)
            let reason: String = info["herdr_missing_reason"] as? String ?? ""
            let said: Bool = info["fell_back"] as? Bool == true && reason.contains(RemoteShell.herdrInstallPage)
            check(said && tab.tooltip.contains("Sessions kept: Off (herdr wasn’t found on the host)"),
                  "remote herdr: its tooltip and list_tabs say herdr wasn't found", tab.tooltip.replacingOccurrences(of: "\n", with: " | "))
        }

        // herdr is installed: a stand-in that answers --version and `agent list` (from a file, or the error file's JSON
        // on stderr), and as herdr itself turns the mouse on and keeps every byte it gets.
        let list = base.appendingPathComponent("herdr-list")
        let failure = base.appendingPathComponent("herdr-error")
        let input = base.appendingPathComponent("herdr-input")
        try? #"{"id":"cli:agent:list","result":{"type":"agent_list","agents":[{"terminal_id":"t1","agent":"claude","agent_status":"blocked","workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","focused":true,"revision":1}]}}"#
            .write(to: list, atomically: true, encoding: .utf8)
        script(herdr, """
            case "$1 $2" in
              '--version '*) echo 'herdr 0.9.4'; exit 0 ;;
              'agent list')
                if [ -e \(RemoteShell.quote(failure.path)) ]; then cat \(RemoteShell.quote(failure.path)) >&2; exit 1; fi
                cat \(RemoteShell.quote(list.path)); exit 0 ;;
            esac
            printf '\\033[?1000h\\033[?1003h\\033[?1006h'
            printf 'herdr stand-in\\r\\n'
            stty -icanon -echo min 1 time 0
            exec dd bs=1 of=\(RemoteShell.quote(input.path)) 2>/dev/null
            """)
        if let fellBack {
            check(await wait(10) { fellBack.tooltip.contains("herdr is now on the host: open a new herdr tab to use it") },
                  "remote herdr: a tab that fell back says so once herdr is on the host", fellBack.tooltip.replacingOccurrences(of: "\n", with: " | "))
            c.remove(fellBack)
        }

        // A herdr tab: the copy on the login shell's PATH is what runs, and the status checks find it where the tab did.
        let tab = c.addRemoteTab(RemoteTab(host: host, keep: .herdr))
        defer { c.remove(tab) }
        let up = await wait(20) { tab.remoteConnected && tab.screenTail(6).contains { $0.contains("herdr stand-in") } }
        check(up && !tab.fellBack, "remote herdr: a herdr tab runs the user's herdr", tab.screenTail(6).joined(separator: " | "))
        let cache = try? String(contentsOf: home.appendingPathComponent(".cache/next-term/herdr"), encoding: .utf8)
        check(cache?.contains("path\t\(herdr.path)\nhow\tlogin") == true, "remote herdr: it was found on the login shell's PATH, and kept for the status checks",
              cache ?? "no cache")
        check(await wait(10) { tab.status.state == .attention && tab.herdrAgents.map(\.status) == [.blocked] },
              "remote herdr: the tab shows herdr's agent that needs a decision", "\(tab.status.state) \(tab.herdrAgents)")
        let agents = MCPControl.describe(tab, in: c, caller: nil)["herdr_agents"] as? [[String: Any]]
        check(agents?.first?["state"] as? String == "blocked" && agents?.first?["pane"] as? String == "w1:p1",
              "remote herdr: list_tabs gives herdr's agents", "\(agents ?? [])")

        // A right-click in herdr reaches herdr (its tab menu), button 2, press and release.
        let view = tab.view
        if await wait(5, { view.getTerminal().mouseMode == .anyEvent }) {
            let cell = (col: 2, row: 1)
            if let down = otherButtonEvent(.rightMouseDown, button: 1, cell: cell, in: view) { view.rightMouseDown(with: down) }
            if let release = otherButtonEvent(.rightMouseUp, button: 1, cell: cell, in: view) { view.rightMouseUp(with: release) }
            let got = { (try? String(contentsOf: input, encoding: .isoLatin1)) ?? "" }
            check(await wait(5) { got().contains("\u{1b}[<2;3;2M") && got().contains("\u{1b}[<2;3;2m") },
                  "remote herdr: a right-click in herdr reaches it as button 2, press and release", got().debugDescription)
        } else {
            check(false, "remote herdr: the stand-in herdr turns mouse reporting on", "\(view.getTerminal().mouseMode)")
        }

        // herdr's list fails (no server on the socket asked): after three checks the tooltip says so in herdr's words.
        try? #"{"id":"cli:agent:list","error":{"code":"server_not_running","message":"no herdr server is running at /srv/herdr.sock"}}"#
            .write(to: failure, atomically: true, encoding: .utf8)
        check(await wait(15) { tab.tooltip.contains("herdr’s list came from a session that isn’t running (no herdr server is running at /srv/herdr.sock)") },
              "remote herdr: a list that keeps failing is said in the tooltip, in herdr's words", tab.tooltip.replacingOccurrences(of: "\n", with: " | "))
        check(MCPControl.describe(tab, in: c, caller: nil)["herdr_agents"] == nil, "remote herdr: and list_tabs gives no stale agents")
        unlink(failure.path)
        check(await wait(10) { !tab.tooltip.contains("isn’t running") && tab.herdrAgents.count == 1 }, "remote herdr: and it clears once herdr answers again")
    }
    #endif
}
