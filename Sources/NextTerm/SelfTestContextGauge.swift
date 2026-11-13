import AppKit
import NextTermCore

/// How full an agent's context is, on its tab: a stand-in Claude Code writes its session record and a transcript in a
/// home of the test's own; the tab gets the gauge at the transcript's percent and the tooltip its line, the gauge turns
/// amber's side of the line once the transcript grows past 80%, and both go when the agent ends.
extension SelfTest {
    static func contextGaugeChecks() async {
        guard let app = AppDelegate.shared else { return }
        let fm = FileManager.default
        let base = canonicalPath(NSTemporaryDirectory()) + "/nt-context-\(getpid())"
        try? fm.removeItem(atPath: base)
        let home = base + "/home", bin = base + "/bin", work = base + "/work"
        let projects = home + "/.claude/projects/-work"
        for folder in [home + "/.claude/sessions", projects, bin, work] { try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        func line(_ used: Int) -> String {
            #"{"type":"assistant","isSidechain":false,"message":{"model":"claude-sonnet-5-5","usage":{"input_tokens":\#(used),"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}"#
        }
        let transcript = projects + "/nt-context-session.jsonl"
        try? (line(84_000) + "\n").write(toFile: transcript, atomically: true, encoding: .utf8)
        // A stand-in for Claude Code: its record names the session, as Claude Code's does for its process.
        let script = """
        #!/bin/sh
        \(stopsOnCtrlC)
        printf '{"sessionId":"nt-context-session","pid":%s}' $$ > "$NT_HOME/.claude/sessions/$$.json"
        while true; do printf '\\r\\033[K> %s' "$SECONDS"; \(standInWait("0.3")); done

        """
        fm.createFile(atPath: bin + "/claude", contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        let watch = AgentUsageWatch.shared
        watch.home = home
        let holder = app.openWindow(directory: work)
        guard let tab = holder.tabs.first else { return check(false, "context: the window has a tab") }
        defer {
            tab.view.send(txt: "\u{03}")
            watch.home = NSHomeDirectory()
            holder.window?.close()
            try? fm.removeItem(atPath: base)
        }
        _ = await wait(20) { tab.status.integrated }
        tab.view.send(txt: "NT_HOME=\(ShellQuote.quote(home)) PATH=\(ShellQuote.quote(bin)):$PATH claude\r")
        let running = await wait(10) { tab.status.running && tab.status.kind == .agent }
        check(running, "context: a stand-in Claude Code runs")
        func index() -> Int { holder.groups.firstIndex { $0.contains(tab) } ?? -1 }
        func percent() -> Int? { holder.tabBar.shownContextPercent(at: index()) }
        func tip() -> String { holder.tabBar.toolTip(at: index()) ?? "" }
        let shown = await wait(15) { watch.poll(); holder.refresh(); return percent() == 42 }
        check(shown, "context: the tab's gauge shows 42%", percent().map(String.init) ?? "none")
        check(tip().contains("Context 84k of 200k (42%)"), "context: the tooltip says how full", tip())
        check(tab.contextUsage?.fields["percent"] as? Int == 42, "context: list_tabs gets the field")

        try? (line(84_000) + "\n" + line(170_000) + "\n").write(toFile: transcript, atomically: true, encoding: .utf8)
        let grew = await wait(15) { watch.poll(); holder.refresh(); return percent() == 85 }
        check(grew, "context: the gauge follows the transcript", percent().map(String.init) ?? "none")

        // The tab list down the terminal's side shows the same gauge on the tab's row, then the bar's tabs come back.
        let tabsBefore = app.terminalTabs
        app.moveTerminalTabs(to: .left)
        holder.refresh()
        let row = { holder.tabList.rowView(at: holder.tabList.rows.firstIndex { !$0.isPane && $0.context != nil } ?? -1) }
        let listed = await wait(5) { holder.refresh(); return row()?.shownContextPercent == 85 }
        check(listed, "context: the tab list's row shows the gauge too", row()?.shownContextPercent.map(String.init) ?? "none")
        app.moveTerminalTabs(to: tabsBefore)
        holder.refresh()

        tab.view.send(txt: "\u{03}")
        let gone = await wait(15) { watch.poll(); holder.refresh(); return percent() == nil && !tab.status.running }
        check(gone, "context: the gauge goes when the agent ends", percent().map(String.init) ?? "none")
    }
}
