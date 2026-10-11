import AppKit
import NextTermCore

/// Closing tabs ends what runs in front of them and what that started outside the terminal (an agent's dev server),
/// SIGTERMs a program that shrugs off the hangup, and leaves the shell's disowned and nohup'd jobs and a program
/// ignoring SIGHUP running; the close alert says which is which. And a new tab's shell inherits no other tab's pty
/// master and no socket of the app's.
extension SelfTest {
    static func tabHangupChecks(_ c: TerminalWindowController) async {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") else { return note("hangup checks skipped: no perl") }
        let dir = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory())).appendingPathComponent("nt-hangup-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let w = AppDelegate.shared.openWindow(directory: dir.path)
        defer {
            w.window?.close()
            c.window?.makeKeyAndOrderFront(nil)
        }
        let agent = w.addTab(directory: dir.path)
        let jobs = w.addTab(directory: dir.path)
        let ignorer = w.addTab(directory: dir.path)
        let tabs = [agent, jobs, ignorer]
        let ready = await wait(20) { tabs.allSatisfy { $0.status.integrated } }
        guard ready else { return check(false, "hangup: three more shells start") }

        // Fix 3: the newest shell holds no pty master of an earlier tab, and none of the app's sockets (MCP).
        let held = descriptors(of: ignorer.view.process.shellPid)
        check(held.total >= 3 && held.ptmx == 0 && held.sockets == 0, "a new tab's shell inherits no other tab's pty master and no socket",
              "\(held.total) descriptors: \(held.ptmx) pty masters, \(held.sockets) sockets")

        // An agent stand-in in front starts a "next-server" in a session of its own, with no terminal, as Claude
        // Code's tools do.
        agent.view.send(txt: "perl -e 'use POSIX (); if (!fork) { POSIX::setsid(); exec q(/bin/zsh), q(-c), q(exec -a next-server /bin/sleep 300) } sleep 300'\r")
        // At the prompt, a disowned job and a nohup'd one; then, in front, a program that catches SIGHUP and carries on.
        jobs.view.send(txt: "/bin/sleep 300 & disown; nohup /bin/sleep 301 > /dev/null 2>&1 &\r")
        await pause(0.5)
        jobs.view.send(txt: "perl -e '$SIG{HUP} = sub {}; sleep 1 while 1'\r")
        // In front, a program that ignores SIGHUP (as under nohup).
        ignorer.view.send(txt: "perl -e '$SIG{HUP} = q(IGNORE); sleep 300'\r")

        var server: ProcessRecord?, standIn: ProcessRecord?, catcher: ProcessRecord?, ignoring: ProcessRecord?
        var sleeps: [ProcessRecord] = []
        let started = await wait(8) {
            let all = ProcessSnapshot.take() ?? []
            let underAgent = descendants(of: agent.view.process.shellPid, in: all)
            server = underAgent.first { TerminalTab.displayName($0) == "next-server" }
            standIn = underAgent.first { $0.name.hasPrefix("perl") }
            let underJobs = descendants(of: jobs.view.process.shellPid, in: all)
            sleeps = underJobs.filter { $0.name == "sleep" }
            catcher = underJobs.first { $0.name.hasPrefix("perl") }
            ignoring = descendants(of: ignorer.view.process.shellPid, in: all).first { $0.name.hasPrefix("perl") && $0.ignoresHangup }
            return server != nil && standIn != nil && sleeps.count == 2 && catcher != nil && ignoring != nil
                && tabs.allSatisfy { $0.status.running }
        }
        let leftovers = [server, standIn, catcher, ignoring].compactMap { $0 } + sleeps
        defer { for record in leftovers where alive(record) { kill(record.pid, SIGKILL) } }
        guard started, let server, let standIn, let catcher, let ignoring else {
            return check(false, "hangup: the stand-ins start", "server \(server != nil), agent \(standIn != nil), sleeps \(sleeps.count), "
                         + "catcher \(catcher != nil), ignoring \(ignoring != nil)")
        }
        let jobSleeps = sleeps

        // Fix 2b: the alerts name what closing stops, from the plan the hangup follows, and what it leaves running.
        let agentStops = agent.closeNote?.stops ?? []
        check(agentStops.count == 2 && agentStops[1].hasPrefix("“next-server” (started by"), "the close alert names the server the agent started",
              agentStops.joined(separator: " | "))
        let ignorerNote = ignorer.closeNote
        check(ignorerNote?.stops.isEmpty == true && ignorerNote?.keeps.count == 1, "and says a program ignoring SIGHUP keeps running",
              String(describing: ignorerNote))
        let text = TerminalWindowController.stopText("Closing it stops", tabs)
        check(text.contains("“next-server” (started by") && text.contains("keeps running: it ignores hangups."), "the window's alert says both", text)
        // The update sheet names it too: the update quit hangs it up as a close does.
        let pane = UpdatePlanning.plan().panes.first { $0.id == agent.id }
        check(pane?.isBusy == true && pane?.started?.hasPrefix("“next-server” (started by") == true,
              "the update sheet counts the agent's tab busy and names the server it started", String(describing: pane?.started))

        // Close all three (as closing their window does): the agent's tree is gone within 1.5 s; the catcher gets
        // SIGTERM after a second; the disowned and nohup'd jobs and the SIGHUP-ignorer keep running.
        let closed = Date()
        for tab in tabs { w.remove(tab) }
        let treeGone = await wait(1.5) { !alive(server) && !alive(standIn) }
        let tookTree = Date().timeIntervalSince(closed)
        check(treeGone, "closing the tab ends the agent stand-in and the server it started, within 1.5 s", String(format: "%.2f s", tookTree))
        let catcherGone = await wait(3) { !alive(catcher) }
        check(catcherGone, "a program that shrugs off the hangup gets SIGTERM after a second",
              String(format: "%.2f s", Date().timeIntervalSince(closed)))
        await pause(max(0, 2.5 - Date().timeIntervalSince(closed)))
        check(jobSleeps.allSatisfy(alive), "the shell's disowned and nohup'd jobs keep running", "\(jobSleeps.filter(alive).count) of 2 alive")
        check(alive(ignoring), "and so does a program ignoring SIGHUP")
    }

    /// Still running as the same process (same pid, same start).
    private static func alive(_ record: ProcessRecord) -> Bool {
        ProcessSnapshot.record(of: record.pid)?.started == record.started
    }

    /// Every process below `pid` in `all`, through the parent links.
    private static func descendants(of pid: pid_t, in all: [ProcessRecord]) -> [ProcessRecord] {
        var found: [ProcessRecord] = []
        var parents: Set<pid_t> = [pid]
        var added = true
        while added {
            added = false
            for record in all where parents.contains(record.parent) && !parents.contains(record.pid) {
                parents.insert(record.pid)
                found.append(record)
                added = true
            }
        }
        return found
    }

    /// A process's descriptors: how many, how many are pty masters (/dev/ptmx), how many are sockets.
    private static func descriptors(of pid: pid_t) -> (total: Int, ptmx: Int, sockets: Int) {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return (0, 0, 0) }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 8)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        let list = fds.prefix(max(0, Int(filled)) / stride)
        let sockets = list.filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }.count
        let ptmx = ProcessInspector.openFiles(of: pid).filter { $0 == "/dev/ptmx" }.count
        return (list.count, ptmx, sockets)
    }
}
