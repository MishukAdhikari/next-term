import AppKit
import Darwin
import NextTermCore

/// MCP across a restart (plan 003's U13), in one process, on a made-up quit restore built as the launch hook builds it:
/// list_tabs lists every restored tab with its pending outcome while the restore runs, and refuses input into a pending
/// tab, whose resume then runs once; open_project then gives the restored window, not a second one; each tab says why it
/// came back ("quit"), what the restore did, its state before and whether its work was cut off, through the shell's first
/// prompt and the resume, until the first command after them; a put-back line refuses send_to_tab and press_keys until the
/// user presses a key there (AE11); a resume whose session was taken says its line is on the prompt, and the user's first
/// command ends its details; while an update waits, input into the waited tab works, new work elsewhere is update_pending
/// until Stop Waiting, and list_tabs marks the wait; with the update sheet open every tool is called once on real tabs,
/// and no consent is set, the box and the sheet stay and nothing quits (AE13); and at the update quit a wait in flight
/// hears "restarting" with its tab's plan, a call posted that never ran hears it was not run, and `nxtrm mcp` fails a
/// tool that changes things at once and tries one that reads again until the socket listens again; at any other quit a
/// request still being read hears at once that Next Term quit. The relaunch harness checks the rest across a real update
/// quit (SelfTestRestore), the plain quit dialog's AE13 among them.
extension SelfTest {
    static func restoreMCPChecks(proj: URL) async {
        guard let app = AppDelegate.shared else { return }
        let fm = FileManager.default
        let home = canonicalPath(NSTemporaryDirectory()) + "/nt-restore-mcp-\(getpid())"
        try? fm.removeItem(atPath: home)
        let project = home + "/project"
        let resumed = home + "/resumed"
        let standIn = home + "/bin/claude"
        try? fm.createDirectory(atPath: project, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: home + "/bin", withIntermediateDirectories: true)
        // It runs past the start watch's window, so MCP reads its resume as one (KTD17): an agent that ended within it
        // reads "ended".
        let script = "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \(ShellQuote.quote(resumed))\nsleep \(Int(StartWatch.window) + 1)\n"
        let made = fm.createFile(atPath: standIn, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        var opened: [TerminalWindowController] = []
        defer {
            for controller in opened { controller.window?.close() }
            try? fm.removeItem(atPath: home)
        }
        guard made else { return check(false, "MCP restore: the stand-in agent is written") }

        func typed(_ line: String, running: Bool = true, exit: Int32? = nil) -> SessionSnapshot.Command {
            SessionSnapshot.Command(line: line, check: .kept, source: .integration, running: running, exitCode: exit)
        }
        func pane(_ command: SessionSnapshot.Command, before: SessionSnapshot.PriorState) -> SessionSnapshot.Pane {
            var pane = SessionSnapshot.Pane(id: UUID(), folder: project, command: command, stateBefore: before,
                                            interrupted: command.running)
            pane.systemZsh = true
            return pane
        }
        func bottomLine(_ tab: TerminalTab) -> String {
            tab.liveTail(4).last { (line: String) -> Bool in !line.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        }
        func restored(_ answer: MCPServer.CallResult, _ tab: TerminalTab) -> [String: Any]? {
            let windows = mcpJSON(answer.text)?["windows"] as? [[String: Any]] ?? []
            let tabs: [[String: Any]] = windows.flatMap { (window: [String: Any]) -> [[String: Any]] in window["tabs"] as? [[String: Any]] ?? [] }
            let listed = tabs.first { ($0["id"] as? String) == tab.id.uuidString.lowercased() }
            return listed?["restored"] as? [String: Any]
        }

        // A quit restore of one project window: `npm run dev` put back in a split beside an idle pane, and a worker agent
        // that was working, which resumes through the stand-in as after a consented quit.
        let session = UUID().uuidString.lowercased()
        let back = pane(typed("npm run dev"), before: .running)
        let idle = pane(typed("ls", running: false, exit: 0), before: .idle)
        var worker = pane(typed("claude"), before: .working)
        worker.agent = SessionSnapshot.Evidence(agent: .claude, sessionID: session, source: .sessionFile, sessionFolder: project)
        let split = SessionSnapshot.Split(vertical: true, children: [.pane(back), .pane(idle)], dividers: [0.5])
        let groups = [SessionSnapshot.Group(root: .split(split), focused: back.id), SessionSnapshot.Group(root: .pane(worker), focused: worker.id)]
        let header = SessionSnapshot.Header(launchID: UUID(), generation: 1, clean: true, savedAt: Date())
        let snapshot = SessionSnapshot(header: header, windows: [SessionSnapshot.Window(project: project, groups: groups)])
        var planned = RestorePlanning.plan(snapshot, kind: .quit, safeMode: false, quitConsent: false)
        if let index = planned.plans.firstIndex(where: { (plan: PanePlan) -> Bool in plan.pane == worker.id }) {
            planned.plans[index].outcome = .resume
            planned.plans[index].line = ShellQuote.quote(standIn) + " --resume " + session
        }
        let built = RestoreBuild.build(snapshot, planned: planned, scrollback: [:], savedAt: nil)
        MCPRestoredTabs.restored(built.panes)
        opened = built.windows
        var byPane: [UUID: TerminalTab] = [:]
        for pane in built.panes { byPane[pane.plan.pane] = pane.tab }
        guard let controller = built.windows.first, let window = controller.window, let backTab = byPane[back.id],
              let idleTab = byPane[idle.id], let workerTab = byPane[worker.id] else {
            return check(false, "MCP restore: the quit restore builds its window")
        }

        // While the restore runs: every restored tab listed with its pending outcome, and input into a pending tab refused.
        let during = await mcpTool("list_tabs", [:])
        let pending = [backTab, idleTab, workerTab].allSatisfy { (tab: TerminalTab) -> Bool in
            let details = restored(during, tab)
            return details?["action"] as? String == "pending" && details?["reason"] as? String == "quit" && details?["outcome"] != nil
        }
        check(pending, "MCP restore: list_tabs lists every restored tab with its pending outcome while the restore runs", during.text)
        _ = await wait(20) { workerTab.status.integrated }
        let early = await mcpTool("send_to_tab", ["tab_id": workerTab.id.uuidString, "text": "echo early"])
        check(early.isError && early.text.contains("being restored"), "MCP restore: send_to_tab into a tab whose restore waits is refused",
              early.text)
        let reopened = await mcpTool("open_project", ["path": project])
        let windows = app.controllers.filter { $0.project == project }.count
        check(!reopened.isError && windows == 1, "MCP restore: open_project during the restore gives the restored window, not a second",
              "\(windows) windows")

        let actions = RestoreActions(panes: built.panes, safeMode: false)
        actions.sessionAvailable = { (_: SessionSnapshot.Evidence) -> Bool in true }
        actions.start()
        let settled = await wait(30) { !actions.isWaiting }
        _ = await wait(10) { workerTab.status.commandsRun >= 1 && !workerTab.status.running }
        await pause(0.5)
        let runs: [String] = ((try? String(contentsOfFile: resumed, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        check(settled && runs == ["--resume " + session], "MCP restore: the resume a refused send_to_tab waited for runs once", "\(runs)")

        // AE10, after a quit: the worker resumed, was working before, and its work was cut off; the shell's first prompt and
        // the resume leave every tab's details in place.
        let after = await mcpTool("list_tabs", [:])
        let workerDetails = restored(after, workerTab)
        check(workerDetails?["reason"] as? String == "quit" && workerDetails?["outcome"] as? String == "resume"
              && workerDetails?["action"] as? String == "applied" && workerDetails?["state_before"] as? String == "working"
              && workerDetails?["interrupted"] as? Bool == true,
              "MCP restore: the worker's tab says it resumed after the quit, was working before, and its work was cut off",
              "\(workerDetails ?? [:])")
        let backDetails = restored(after, backTab)
        check(backDetails?["outcome"] as? String == "command_on_the_line" && backDetails?["line_held"] as? Bool == true
              && restored(after, idleTab)?["outcome"] as? String == "idle",
              "MCP restore: the put-back tab and the idle tab keep their details past the shell's first prompt", "\(backDetails ?? [:])")
        let read = await mcpTool("read_tab", ["tab_id": idleTab.id.uuidString])
        let waited = await mcpTool("wait_for_tab", ["tab_id": idleTab.id.uuidString, "timeout_seconds": 1])
        let readDetails = mcpJSON(read.text)?["restored"] as? [String: Any]
        let waitDetails = mcpJSON(waited.text)?["restored"] as? [String: Any]
        check(readDetails?["reason"] as? String == "quit" && waitDetails?["reason"] as? String == "quit",
              "MCP restore: read_tab and wait_for_tab give the restored details too", read.text)

        // AE11: the put-back line refuses send_to_tab with Return and press_keys, runs nothing and stays; one key from the
        // user, and input works.
        let lineBefore = bottomLine(backTab)
        let returned = await mcpTool("send_to_tab", ["tab_id": backTab.id.uuidString, "text": "", "submit": true])
        let pressed = await mcpTool("press_keys", ["tab_id": backTab.id.uuidString, "keys": ["enter"]])
        await pause(0.5)
        check(returned.isError && returned.text.contains("put back") && pressed.isError && bottomLine(backTab) == lineBefore
              && lineBefore.contains("npm run dev") && backTab.status.commandsRun == 0,
              "MCP restore: send_to_tab and press_keys with Return are refused on a put-back line, which stays unrun",
              returned.text + " / line “\(bottomLine(backTab))”")
        controller.select(0)
        window.makeFirstResponder(backTab.view)
        pressKey(window, String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), code: 124)
        let cleared = await mcpTool("press_keys", ["tab_id": backTab.id.uuidString, "keys": ["ctrl+c"]])
        let sent = await mcpTool("send_to_tab", ["tab_id": backTab.id.uuidString, "text": "true"])
        check(!cleared.isError && !sent.isError, "MCP restore: after one key from the user, press_keys and send_to_tab work there",
              cleared.text + " / " + sent.text)

        // The first command after the restore ends the details: the idle tab's first, the worker's after its resume.
        let idleRun = await mcpTool("send_to_tab", ["tab_id": idleTab.id.uuidString, "text": "true"])
        let workerRun = await mcpTool("send_to_tab", ["tab_id": workerTab.id.uuidString, "text": "true"])
        _ = await wait(10) { idleTab.status.commandsRun >= 1 && workerTab.status.commandsRun >= 2 && backTab.status.commandsRun >= 1 }
        let later = await mcpTool("list_tabs", [:])
        check(!idleRun.isError && !workerRun.isError && restored(later, idleTab) == nil && restored(later, workerTab) == nil
              && restored(later, backTab) == nil,
              "MCP restore: the first command after the restore, the user's or MCP's, ends a tab's details", later.text)

        await takenSessionChecks(project: project, standIn: standIn, resumed: resumed)
        await updateWaitMCPChecks(controller: controller, project: project, idle: idleTab)
        await drainChecks(controller: controller)
    }

    /// R24 on an update restore whose automatic resume did not run: another process had its session open as its turn came,
    /// so the agent's resume command went on the line instead. list_tabs says so (on the line, held, and not "Resumed"),
    /// nothing ran, and the user's first command there ends its details.
    private static func takenSessionChecks(project: String, standIn: String, resumed: String) async {
        let session = UUID().uuidString.lowercased()
        let command = SessionSnapshot.Command(line: "claude", check: .kept, source: .integration, running: true)
        var pane = SessionSnapshot.Pane(id: UUID(), folder: project, command: command, stateBefore: .working, interrupted: true)
        pane.systemZsh = true
        pane.agent = SessionSnapshot.Evidence(agent: .claude, sessionID: session, source: .sessionFile, sessionFolder: project)
        let group = SessionSnapshot.Group(root: .pane(pane), focused: pane.id)
        let header = SessionSnapshot.Header(launchID: UUID(), generation: 1, clean: false, savedAt: Date())
        let snapshot = SessionSnapshot(header: header, windows: [SessionSnapshot.Window(project: project, groups: [group])])
        var planned = RestorePlanning.plan(snapshot, kind: .update, safeMode: false, quitConsent: false)
        if let index = planned.plans.firstIndex(where: { (plan: PanePlan) -> Bool in plan.pane == pane.id }) {
            planned.plans[index].outcome = .resume
            planned.plans[index].line = ShellQuote.quote(standIn) + " --resume " + session
        }
        let built = RestoreBuild.build(snapshot, planned: planned, scrollback: [:], savedAt: nil)
        MCPRestoredTabs.restored(built.panes)
        defer { for controller in built.windows { controller.window?.close() } }
        guard let controller = built.windows.first, let window = controller.window, let tab = built.panes.first?.tab else {
            return check(false, "MCP restore: the update restore with a taken session builds its window")
        }
        let actions = RestoreActions(panes: built.panes, safeMode: false)
        actions.sessionAvailable = { (_: SessionSnapshot.Evidence) -> Bool in false }
        actions.start()
        let settled = await wait(30) { !actions.isWaiting }
        await pause(0.5)
        let now = await mcpTool("list_tabs", [:])
        let details = listed(now, tab)?["restored"] as? [String: Any]
        let note = details?["note"] as? String ?? ""
        let runs = ((try? String(contentsOfFile: resumed, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        let ran = runs.contains { (line: String) -> Bool in line.contains(session) }
        let onTheLine = details?["outcome"] as? String == "agent_on_the_line" && details?["line_held"] as? Bool == true
        check(settled && onTheLine && details?["reason"] as? String == "update" && !note.contains("Resumed") && !ran,
              "MCP restore: a resume whose session was taken says its line is on the prompt, held, and that nothing resumed",
              "\(details ?? [:]), ran \(ran)")

        // The user's key, then their first command: it ends the details, as the restore ran nothing of its own.
        controller.select(0)
        window.makeFirstResponder(tab.view)
        pressKey(window, String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), code: 124)
        let cleared = await mcpTool("press_keys", ["tab_id": tab.id.uuidString, "keys": ["ctrl+c"]])
        let sent = await mcpTool("send_to_tab", ["tab_id": tab.id.uuidString, "text": "true"])
        _ = await wait(10) { tab.status.commandsRun >= 1 && !tab.status.running }
        let after = await mcpTool("list_tabs", [:])
        check(!cleared.isError && !sent.isError && listed(after, tab) != nil && listed(after, tab)?["restored"] == nil,
              "MCP restore: after a resume that did not run, the user's first command ends the details", after.text)
    }

    /// A tool called in this process, as the socket calls it.
    private static func mcpTool(_ name: String, _ arguments: [String: Any]) async -> MCPServer.CallResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<MCPServer.CallResult, Never>) in
            MCPControl.call(name, arguments, caller: nil) { (result: MCPServer.CallResult) in continuation.resume(returning: result) }
        }
    }

    private static func mcpJSON(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// While an update waits for a busy tab: input into it works, new work elsewhere is update_pending, and reading works,
    /// until Stop Waiting. Then, with the update sheet open, every tool once (AE13).
    private static func updateWaitMCPChecks(controller: TerminalWindowController, project: String, idle: TerminalTab) async {
        let sessions = UpdateKeepSessions.shared
        let version = AppVersion("99.0.0")!
        let busy = controller.addTab(directory: project, select: false)
        defer { controller.remove(busy) }
        guard await wait(20, { busy.status.integrated }) else { return check(false, "MCP restore: the update's busy tab starts its shell") }
        busy.view.send(txt: "sleep 600\r")
        guard await wait(5, { busy.status.running }) else { return check(false, "MCP restore: a command runs for the update's wait") }
        sessions.show(version: version, from: .updateButton)
        sessions.pressed(.waitForThem)
        guard sessions.isWaiting, sessions.flow?.waitSet.contains(busy.id) == true else {
            if sessions.flow != nil { sessions.pressed(.cancel) }
            return check(false, "MCP restore: Wait for Them waits for the busy tab", "\(String(describing: sessions.flow?.state))")
        }
        let input = await mcpTool("press_keys", ["tab_id": busy.id.uuidString, "keys": ["right"]])
        let elsewhere = await mcpTool("send_to_tab", ["tab_id": idle.id.uuidString, "text": "echo elsewhere"])
        let newTab = await mcpTool("new_tab", ["directory": project])
        let reading = await mcpTool("list_tabs", [:])
        check(!input.isError && elsewhere.text.hasPrefix("update_pending") && newTab.text.hasPrefix("update_pending") && !reading.isError,
              "MCP restore: while an update waits, input into the waited tab works, new work elsewhere is update_pending, and reading works",
              input.text + " / " + elsewhere.text)
        // KTD16: list_tabs reports the wait, on each tab.
        let waitedMark = listed(reading, busy)?["update_wait"] as? String
        let heldMark = listed(reading, idle)?["update_wait"] as? String
        check(waitedMark == "waits_for_this_tab" && heldMark == "update_pending",
              "MCP restore: while an update waits, list_tabs marks the tab it waits for and holds new work in the others",
              "\(waitedMark ?? "none"), \(heldMark ?? "none")")
        sessions.pressed(.stopWaiting)
        let lifted = await mcpTool("send_to_tab", ["tab_id": idle.id.uuidString, "text": "true"])
        let after = await mcpTool("list_tabs", [:])
        check(!sessions.isWaiting && !lifted.isError && listed(after, busy)?["update_wait"] == nil,
              "MCP restore: Stop Waiting lifts update_pending, and list_tabs no longer reports a wait", lifted.text)

        // AE13: the sheet open, every tool once with real tabs; no consent, the box and the sheet as they were, nothing quits.
        sessions.show(version: version, from: .updateButton)
        guard let sheet = sessions.sheet, let mcp = MCPTestClient(socket: MCPControlServer.shared.path) else {
            if sessions.flow != nil { sessions.pressed(.cancel) }
            return check(false, "MCP restore: the update sheet opens, and `nxtrm mcp` starts")
        }
        defer { mcp.close() }
        let parent = AppDelegate.shared.controllers.first { $0.window != nil && $0.window === sheet.window?.parent }
        let shown = parent?.activeTab ?? busy
        let box = sheet.keepBox.state
        let state = sessions.flow?.state
        _ = await mcp.call(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "selftest", "version": "1"]])
        let calls = await everyToolOnce(mcp, project: project, shown: shown, firstID: 10)
        let consent = Updater.shared.validConsent == nil && !SessionRestore.shared.quitConsent
        let shownStill = sessions.sheet === sheet && sheet.window?.isVisible == true
        let sheetUp = shownStill && sessions.flow?.state == state && !sessions.isWaiting
        check(calls.complete && consent && sheet.keepBox.state == box && sheetUp && !AppDelegate.shared.isTerminating,
              "MCP restore: with the update sheet open, every tool once on real tabs sets no consent, leaves the box and the sheet, "
                  + "and quits nothing", calls.detail)
        sessions.pressed(.cancel)
        busy.view.send(txt: "\u{03}")
    }

    /// The tab's entry in a list_tabs answer.
    private static func listed(_ answer: MCPServer.CallResult, _ tab: TerminalTab) -> [String: Any]? {
        let windows = mcpJSON(answer.text)?["windows"] as? [[String: Any]] ?? []
        let tabs: [[String: Any]] = windows.flatMap { (window: [String: Any]) -> [[String: Any]] in window["tabs"] as? [[String: Any]] ?? [] }
        return tabs.first { ($0["id"] as? String) == tab.id.uuidString.lowercased() }
    }

    /// What calling every tool once left (AE13).
    struct EveryTool {
        var called = 0
        var answered = 0
        /// The id of the tab new_tab opened, which close_tab closed last.
        var opened: String?
        /// Every tool was called, each answered, and new_tab's tab took the calls that act on a tab.
        var complete: Bool { called == MCPServer.tools.count && answered == called && opened != nil }
        var detail: String { "answered \(answered) of \(called), of \(MCPServer.tools.count) tools, new tab \(opened ?? "none")" }
    }

    /// AE13: every tool in MCPServer.tools called once through `nxtrm mcp` (`mcp`, initialized), with real arguments where
    /// it takes a tab or a project. Return, Enter and Space go into a tab new_tab opens in `project`; `shown`, a tab of the
    /// window the update sheet sits over or behind the quit dialog, is read, shown and asked to take the keyboard; the new
    /// tab is split, closed, zoomed and laid out, and closed last. A tool that asks on the Mac is declined, as closing its
    /// window does; settings_set asks for "At launch", which no tool may change; hosts and skills get no arguments, so
    /// nothing outside the app changes.
    static func everyToolOnce(_ mcp: MCPTestClient, project: String, shown: TerminalTab, firstID: Int) async -> EveryTool {
        let decline = Task { @MainActor in
            while !Task.isCancelled {
                MCPWriteControl.pending?.window?.close()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { decline.cancel() }
        var result = EveryTool()
        let showing = shown.id.uuidString.lowercased()
        let file = project + "/nt-ae13.txt"
        func arguments(_ tool: String, opened tab: String) -> [String: Any] {
            switch tool {
            case "read_tab", "show_tab", "focus_tab": return ["tab_id": showing]
            case "wait_for_tab": return ["tab_id": showing, "timeout_seconds": 1]
            case "read_file", "propose_edit": return ["project": project, "path": file]
            case "find_in_files": return ["project": project, "query": "nt-ae13"]
            case "git_status", "get_diff", "set_layout": return ["project": project]
            case "open_project": return ["path": project]
            case "new_tab": return ["directory": project]
            case "send_to_tab": return ["tab_id": tab, "text": "", "submit": true]
            case "press_keys": return ["tab_id": tab, "keys": ["enter", "space", "enter"]]
            case "answer_agent": return ["tab_id": tab, "question_id": "q_0000000000000000", "choice": 1]
            case "close_tab", "close_pane", "zoom_pane": return ["tab_id": tab]
            case "split_pane": return ["tab_id": tab, "direction": "right"]
            case "write_file", "create_file": return ["project": project, "path": file, "content": "AE13"]
            case "stage": return ["project": project, "paths": [file]]
            case "commit": return ["project": project, "message": "AE13", "paths": [file]]
            case "open_in_editor": return ["path": file]
            case "settings_set": return ["values": ["at_launch": "welcome"]]
            default: return [:]
            }
        }
        // close_tab last, on the tab new_tab opened; with none opened, on no tab at all.
        let tools: [String] = MCPServer.tools.map(\.name).filter { $0 != "close_tab" } + ["close_tab"]
        for (index, tool) in tools.enumerated() {
            let call: [String: Any] = ["name": tool, "arguments": arguments(tool, opened: result.opened ?? UUID().uuidString)]
            let reply = await mcp.call(firstID + index, "tools/call", call, timeout: 40)
            result.called += 1
            guard let answer = reply?["result"] as? [String: Any] else { continue }
            result.answered += 1
            if tool == "new_tab", answer["isError"] as? Bool != true {
                let text = (answer["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
                result.opened = mcpJSON(text)?["id"] as? String
            }
        }
        // Closed already, unless close_tab could not: then here, so the windows are as they were.
        if let opened = result.opened {
            for controller in AppDelegate.shared.controllers {
                if let tab = controller.tabs.first(where: { $0.id.uuidString.lowercased() == opened }) { controller.remove(tab) }
            }
        }
        return result
    }

    /// The update quit's drain, then `nxtrm mcp` across the restart of the socket.
    private static func drainChecks(controller: TerminalWindowController) async {
        let server = MCPControlServer.shared
        let path = server.path
        let busy = controller.addTab(directory: controller.project, select: false)
        defer {
            if !server.isRunning { server.start(path: path) }
            controller.remove(busy)
        }
        guard await wait(20, { busy.status.integrated }) else { return check(false, "MCP restore: the drain's busy tab starts its shell") }
        busy.view.send(txt: "sleep 600\r")
        guard await wait(5, { busy.status.running }), let mcp = MCPTestClient(socket: path) else {
            return check(false, "MCP restore: a command runs for the drain, and `nxtrm mcp` starts")
        }
        defer { mcp.close() }
        _ = await mcp.call(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "selftest", "version": "1"]])
        let id = busy.id.uuidString.lowercased()
        let waiting = Task { @MainActor in
            await mcp.call(2, "tools/call", ["name": "wait_for_tab", "arguments": ["tab_id": id, "timeout_seconds": 120]], timeout: 30)
        }
        await pause(1)

        let request = MCPServer.request(tool: "list_tabs", arguments: [:]) ?? Data()
        let consent = UpdateConsent(version: "99.0.0", keep: true, covered: UpdatePlanning.plan())
        let posted = sendAndDrain(path, request: request, consent: consent).answer
        check(posted?.isError == true && posted?.text.contains("restarting for an update") == true && posted?.text.contains("not run") == true,
              "MCP restore: a call posted as the update quit starts hears Next Term restarts, and that it was not run",
              posted?.text ?? "no answer")
        let reply = await waiting.value
        let text = ((reply?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        let fields = mcpJSON(text)
        check(fields?["state"] as? String == "restarting" && fields?["planned"] != nil && fields?["id"] as? String == id,
              "MCP restore: a wait_for_tab in flight at the update quit returns restarting, with its tab's planned outcome", text)

        // The socket file stays and nothing listens: a tool that changes things fails at once, saying nothing was sent;
        // one that reads is tried again until the socket listens again.
        let started = Date()
        let sent = await mcp.call(3, "tools/call", ["name": "send_to_tab", "arguments": ["tab_id": id, "text": "echo no"]], timeout: 10)
        let sentText = ((sent?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        check(sentText.contains("nothing was sent") && Date().timeIntervalSince(started) < 3,
              "MCP restore: while Next Term restarts, a tool that changes things fails at once and says nothing was sent", sentText)
        let reading = Task { @MainActor in
            await mcp.call(4, "tools/call", ["name": "list_tabs", "arguments": [String: Any]()], timeout: 30)
        }
        await pause(2)
        server.start(path: path)
        let listed = await reading.value
        let result = listed?["result"] as? [String: Any]
        check(server.isRunning && result?["isError"] as? Bool == false && Date().timeIntervalSince(started) > 1.5,
              "MCP restore: a tool that reads is tried again until Next Term listens again, and answers",
              "\(listed ?? [:])")

        // Any other quit: a request still being read hears at once that Next Term quit, not after its read's 10 seconds,
        // and the socket file goes.
        let half = Data("{\"tool\": \"list_".utf8)
        let unread = sendAndDrain(path, request: half, consent: nil)
        let gone = !FileManager.default.fileExists(atPath: path)
        check(unread.answer?.text.contains("Next Term quit") == true && unread.took < 3 && gone,
              "MCP restore: at a quit that is not an update's, a request still being read hears at once that Next Term quit, "
                  + "and the socket file goes", "\(unread.answer?.text ?? "no answer") in \(unread.took) s, file gone \(gone)")
        server.start(path: path)
        busy.view.send(txt: "\u{03}")
    }
}

extension SelfTest {
    /// A call in flight as the quit starts, and its answer, read off the socket with how long it took from the drain.
    /// A whole `request` is read and posted to the main thread, which is held meanwhile, so the drain comes first and it
    /// never runs; half of one is still being read. `consent`: the update's quit, or nil for any other.
    private static func sendAndDrain(_ path: String, request: Data, consent: UpdateConsent?) -> (answer: MCPServer.CallResult?, took: TimeInterval) {
        let fd = MCPControlServer.connectSocket(path)
        guard fd >= 0 else {
            MCPRestoredTabs.drainAtQuit(update: consent)
            return (nil, 0)
        }
        defer { close(fd) }
        if !request.isEmpty {
            _ = request.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in write(fd, raw.baseAddress!, raw.count) }
        }
        Thread.sleep(forTimeInterval: 0.3)
        let started = Date()
        MCPRestoredTabs.drainAtQuit(update: consent)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = read(fd, &buffer, buffer.count)
        let took = Date().timeIntervalSince(started)
        guard count > 0, let end = buffer[0..<count].firstIndex(of: 0x0A) else { return (nil, took) }
        return (MCPServer.decodeAnswer(Data(buffer[0..<end])), took)
    }
}

#if DEBUG
/// The relaunch harness's MCP checks, across a real update quit and relaunch (SelfTestRestore). An `nxtrm mcp` started
/// before the quit writes its answers to a file in the harness's folder, so the next launch reads what the update quit
/// answered a call in flight.
extension SelfTestRestore {
    private static var acrossClient: (process: Process, input: Pipe)?

    private static func acrossFile(_ harness: Harness) -> URL { harness.folder.appendingPathComponent("mcp-across.jsonl") }

    /// The name the user gives the running command's tab before the update quit, which comes back with its id (AE10).
    static let workerTitle = "worker"

    /// Before the update quit: the running command's tab named as the user names it, then list_tabs, and a wait_for_tab on
    /// that tab, left in flight.
    static func mcpBeforeUpdateQuit(_ harness: Harness, busy tab: TerminalTab) async {
        let owner = AppDelegate.shared.controllers.first { (controller: TerminalWindowController) -> Bool in
            controller.tabs.contains { $0 === tab }
        }
        owner?.renamePane(tab, to: workerTitle)
        let file = acrossFile(harness)
        guard let socket = harness.mcpSocket, FileManager.default.createFile(atPath: file.path, contents: nil),
              let output = try? FileHandle(forWritingTo: file) else { return check(false, "MCP across the update: its client's file is made") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        process.arguments = ["--cli", "mcp"]
        var environment = ProcessInfo.processInfo.environment
        environment[MCPServer.socketVariable] = socket
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return check(false, "MCP across the update: `nxtrm mcp` starts") }
        acrossClient = (process, input)
        let calls: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [:],
                                                                         "clientInfo": ["name": "harness", "version": "1"]]],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "list_tabs", "arguments": [String: Any]()]],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
             "params": ["name": "wait_for_tab", "arguments": ["tab_id": tab.id.uuidString.lowercased(), "timeout_seconds": 300]]],
        ]
        for call in calls {
            guard var data = try? JSONSerialization.data(withJSONObject: call) else { continue }
            data.append(0x0A)
            input.fileHandleForWriting.write(data)
        }
        let listed = await SelfTest.wait(15) { answers(harness)[2] != nil }
        check(listed, "MCP across the update: list_tabs answers before the quit, and a wait_for_tab is left in flight")
    }

    /// What the client before the quit read, by request id.
    private static func answers(_ harness: Harness) -> [Int: [String: Any]] {
        let text = (try? String(contentsOf: acrossFile(harness), encoding: .utf8)) ?? ""
        var found: [Int: [String: Any]] = [:]
        for line in text.split(separator: "\n") {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let id = object["id"] as? Int else { continue }
            found[id] = object
        }
        return found
    }

    private static func text(_ answer: [String: Any]?) -> String {
        ((answer?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    }

    /// Every tab in a list_tabs answer.
    private static func tabs(_ listed: String) -> [[String: Any]] {
        let object = (try? JSONSerialization.jsonObject(with: Data(listed.utf8))) as? [String: Any]
        let windows = object?["windows"] as? [[String: Any]] ?? []
        return windows.flatMap { (window: [String: Any]) -> [[String: Any]] in window["tabs"] as? [[String: Any]] ?? [] }
    }

    /// Each tab's id, whether it is a split pane, and its place in the tab bar, from list_tabs.
    private static func layout(_ listed: String) -> [String] {
        let rows: [String] = tabs(listed).map { (tab: [String: Any]) -> String in
            let split = tab["split"] as? Bool ?? false
            return "\(tab["id"] as? String ?? "") \(split) \(tab["tab_bar_position"] as? Int ?? 0)"
        }
        return rows.sorted()
    }

    /// The title list_tabs gives the tab with `id`.
    private static func title(_ id: String, in listed: String) -> String? {
        tabs(listed).first { (tab: [String: Any]) -> Bool in tab["id"] as? String == id }?["title"] as? String
    }

    /// After the relaunch: the wait in flight heard "restarting" with its tab's plan (AE14); list_tabs gives the same ids,
    /// splits and user-set title (AE10), and the running command's tab its restored details, with its put-back line
    /// refusing input (AE11).
    static func mcpAfterUpdate(_ harness: Harness) async {
        let before = answers(harness)
        let waited = (try? JSONSerialization.jsonObject(with: Data(text(before[3]).utf8))) as? [String: Any]
        check(waited?["state"] as? String == "restarting" && waited?["planned_outcome"] as? String == "command_on_the_line",
              "MCP across the update: the wait_for_tab in flight at the update quit returned restarting, with its tab's plan",
              text(before[3]))
        guard let socket = harness.mcpSocket, let mcp = MCPTestClient(socket: socket) else {
            return check(false, "MCP across the update: `nxtrm mcp` starts after the relaunch")
        }
        defer { mcp.close() }
        _ = await mcp.call(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "harness", "version": "1"]])
        let now = await mcp.call(2, "tools/call", ["name": "list_tabs", "arguments": [String: Any]()])
        let nowText = text(now)
        let same = layout(nowText) == layout(text(before[2]))
        check(same && !layout(nowText).isEmpty, "MCP across the update: list_tabs gives the same tab ids and splits as before the quit",
              "before \(layout(text(before[2]))), now \(layout(nowText))")
        guard let id = waited?["id"] as? String else { return }
        let titled = title(id, in: text(before[2]))
        let titledNow = title(id, in: nowText)
        check(titled == workerTitle && titledNow == workerTitle,
              "MCP across the update: the title the user gave a tab comes back with its id",
              "before \(titled ?? "none"), now \(titledNow ?? "none")")
        let details = tabs(nowText).first { (tab: [String: Any]) -> Bool in tab["id"] as? String == id }?["restored"] as? [String: Any]
        check(details?["reason"] as? String == "update" && details?["state_before"] as? String == "running"
              && details?["interrupted"] as? Bool == true && details?["outcome"] as? String == "command_on_the_line",
              "MCP across the update: the running command's tab says it came back from the update, running before and cut off",
              "\(details ?? [:])")
        let restored = AppDelegate.shared.controllers.flatMap(\.tabs).first { (tab: TerminalTab) -> Bool in
            tab.id.uuidString.lowercased() == id
        }
        _ = await SelfTest.wait(10) { restored?.restoredRecord?.pending?.state == .applied }
        let refused = await mcp.call(3, "tools/call", ["name": "send_to_tab", "arguments": ["tab_id": id, "text": "", "submit": true]])
        check(text(refused).contains("put back"), "MCP across the update: send_to_tab with Return into the put-back tab is refused",
              text(refused))
    }

    // MARK: AE13 across the real quits

    /// With the update sheet open over the staged update, before its Update Now: every tool once on real tabs sets neither
    /// consent, leaves the sheet's box and state, and quits nothing, and the tabs are as they were for the update quit.
    static func mcpWithUpdateSheet(_ harness: Harness) async {
        let app = AppDelegate.shared!
        let sessions = UpdateKeepSessions.shared
        guard let socket = harness.mcpSocket, let sheet = sessions.sheet, let mcp = MCPTestClient(socket: socket) else {
            return check(false, "MCP with the update sheet open: the sheet shows, and `nxtrm mcp` starts")
        }
        defer { mcp.close() }
        let parent = app.controllers.first { (controller: TerminalWindowController) -> Bool in
            controller.window != nil && controller.window === sheet.window?.parent
        }
        guard let shown = (parent ?? app.controllers.first)?.activeTab else {
            return check(false, "MCP with the update sheet open: the window under it has a tab")
        }
        let open: [UUID] = app.controllers.flatMap(\.tabs).map(\.id)
        let box = sheet.keepBox.state
        let state = sessions.flow?.state
        _ = await mcp.call(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "harness", "version": "1"]])
        let calls = await SelfTest.everyToolOnce(mcp, project: harness.project.path, shown: shown, firstID: 10)
        let consent = Updater.shared.validConsent == nil && !SessionRestore.shared.quitConsent
        let shownStill = sessions.sheet === sheet && sheet.window?.isVisible == true
        let sheetUp = shownStill && sessions.flow?.state == state && !sessions.isWaiting
        let same = app.controllers.flatMap(\.tabs).map(\.id) == open
        check(calls.complete && consent && sheet.keepBox.state == box && sheetUp && same && !app.isTerminating,
              "MCP with the update sheet open: every tool once on real tabs sets no consent, leaves the box and the sheet, and quits nothing",
              calls.detail + ", consent none \(consent), sheet up \(sheetUp), tabs as they were \(same)")
    }

    /// With the plain quit dialog of the user's ⌘Q open: every tool once on real tabs sets no consent, leaves the dialog's
    /// box and the dialog itself, and quits nothing. The quit then goes on as the user answers it.
    static func mcpWithQuitDialog(_ harness: Harness) async {
        let app = AppDelegate.shared!
        let shows = await SelfTest.wait(20) { resumeBox() != nil }
        guard shows, let dialog = NSApp.modalWindow, let box = resumeBox(), let socket = harness.mcpSocket,
              let mcp = MCPTestClient(socket: socket) else {
            return check(false, "MCP with the quit dialog open: the plain quit dialog shows, and `nxtrm mcp` starts")
        }
        defer { mcp.close() }
        let window = app.controllers.first { (controller: TerminalWindowController) -> Bool in controller.project == harness.project.path }
        guard let shown = (window ?? app.controllers.first)?.activeTab else {
            return check(false, "MCP with the quit dialog open: a window behind it has a tab")
        }
        let checked = box.state
        _ = await mcp.call(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "harness", "version": "1"]])
        let calls = await SelfTest.everyToolOnce(mcp, project: harness.project.path, shown: shown, firstID: 10)
        let consent = !SessionRestore.shared.quitConsent && Updater.shared.validConsent == nil
        let dialogUp = NSApp.modalWindow === dialog && dialog.isVisible
        let still = dialogUp && box.state == checked && !app.isTerminating
        check(calls.complete && consent && still,
              "MCP with the quit dialog open: every tool once on real tabs sets no consent, leaves its box, and quits nothing",
              calls.detail + ", consent none \(consent), dialog and box as they were \(still)")
    }

    /// The resume checkbox of the app-modal dialog showing, if any.
    private static func resumeBox() -> NSButton? {
        guard let content = NSApp.modalWindow?.contentView else { return nil }
        return checkboxes(in: content).first { (button: NSButton) -> Bool in button.title == QuitPolicy.checkboxTitle }
    }

    private static func checkboxes(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { (subview: NSView) -> [NSButton] in (subview as? NSButton).map { [$0] } ?? checkboxes(in: subview) }
    }
}
#endif
