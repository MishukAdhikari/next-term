import AppKit
import Darwin
import NextTermCore

/// MCP across a restart (plan 003's U13), in one process, on a made-up quit restore built as the launch hook builds it:
/// list_tabs lists every restored tab with its pending outcome while the restore runs, and refuses input into a pending
/// tab, whose resume then runs once; open_project then gives the restored window, not a second one; each tab says why it
/// came back ("quit"), what the restore did, its state before and whether its work was cut off, through the shell's first
/// prompt and the resume, until the first command after them; a put-back line refuses send_to_tab and press_keys until the
/// user presses a key there (AE11); while an update waits, input into the waited tab works and new work elsewhere is
/// update_pending until Stop Waiting; with the update sheet open every tool is called once, and no consent is set, the box
/// stays and nothing quits (AE13); and at the update quit a wait in flight hears "restarting" with its tab's plan, a call
/// posted that never ran hears it was not run, and `nxtrm mcp` fails a tool that changes things at once and tries one
/// that reads again until the socket listens again. The relaunch harness checks the rest across a real update quit
/// (SelfTestRestore).
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
        let script = "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \(ShellQuote.quote(resumed))\n"
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

        await updateWaitMCPChecks(controller: controller, project: project, idle: idleTab)
        await drainChecks(controller: controller)
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
        sessions.pressed(.stopWaiting)
        let lifted = await mcpTool("send_to_tab", ["tab_id": idle.id.uuidString, "text": "true"])
        check(!sessions.isWaiting && !lifted.isError, "MCP restore: Stop Waiting lifts update_pending", lifted.text)

        // AE13: the sheet open, every tool once; no consent, the box as it was, nothing quits.
        sessions.show(version: version, from: .updateButton)
        guard let sheet = sessions.sheet, let mcp = MCPTestClient(socket: MCPControlServer.shared.path) else {
            if sessions.flow != nil { sessions.pressed(.cancel) }
            return check(false, "MCP restore: the update sheet opens, and `nxtrm mcp` starts")
        }
        defer { mcp.close() }
        let box = sheet.keepBox.state
        _ = await mcp.call(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "selftest", "version": "1"]])
        // A tool that asks on the Mac is declined, as a close is.
        let decline = Task { @MainActor in
            while !Task.isCancelled {
                MCPWriteControl.pending?.window?.close()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        var answered = 0
        for (index, entry) in MCPServer.tools.enumerated() {
            let reply = await mcp.call(10 + index, "tools/call", ["name": entry.name, "arguments": [String: Any]()], timeout: 40)
            if reply?["result"] != nil { answered += 1 }
        }
        decline.cancel()
        let consent = Updater.shared.validConsent == nil && !SessionRestore.shared.quitConsent
        check(answered == MCPServer.tools.count && consent && sheet.keepBox.state == box && !AppDelegate.shared.isTerminating
              && sessions.sheet === sheet,
              "MCP restore: with the update sheet open, every tool once sets no consent, leaves the box, and quits nothing",
              "answered \(answered) of \(MCPServer.tools.count)")
        sessions.pressed(.cancel)
        busy.view.send(txt: "\u{03}")
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

        let posted = postAndDrain(path, consent: UpdateConsent(version: "99.0.0", keep: true, covered: UpdatePlanning.plan()))
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
        busy.view.send(txt: "\u{03}")
    }
}

extension SelfTest {
    /// A call posted to the main thread as the update quit starts: the main thread is held while the call is read and
    /// posted, and the drain comes first, so it never runs. The call's answer, read off the socket.
    private static func postAndDrain(_ path: String, consent: UpdateConsent) -> MCPServer.CallResult? {
        let fd = MCPControlServer.connectSocket(path)
        guard fd >= 0 else {
            MCPRestoredTabs.drainAtQuit(update: consent)
            return nil
        }
        defer { close(fd) }
        if let request = MCPServer.request(tool: "list_tabs", arguments: [:]) {
            _ = request.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in write(fd, raw.baseAddress!, raw.count) }
            Thread.sleep(forTimeInterval: 0.3)
        }
        MCPRestoredTabs.drainAtQuit(update: consent)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0, let end = buffer[0..<count].firstIndex(of: 0x0A) else { return nil }
        return MCPServer.decodeAnswer(Data(buffer[0..<end]))
    }
}

#if DEBUG
/// The relaunch harness's MCP checks, across a real update quit and relaunch (SelfTestRestore). An `nxtrm mcp` started
/// before the quit writes its answers to a file in the harness's folder, so the next launch reads what the update quit
/// answered a call in flight.
extension SelfTestRestore {
    private static var acrossClient: (process: Process, input: Pipe)?

    private static func acrossFile(_ harness: Harness) -> URL { harness.folder.appendingPathComponent("mcp-across.jsonl") }

    /// Before the update quit: list_tabs, and a wait_for_tab on the running command, left in flight.
    static func mcpBeforeUpdateQuit(_ harness: Harness, busy tab: TerminalTab) async {
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

    /// Each tab's id, whether it is a split pane, and its place in the tab bar, from list_tabs.
    private static func layout(_ listed: String) -> [String] {
        let object = (try? JSONSerialization.jsonObject(with: Data(listed.utf8))) as? [String: Any]
        let windows = object?["windows"] as? [[String: Any]] ?? []
        var rows: [String] = []
        for window in windows {
            for tab in window["tabs"] as? [[String: Any]] ?? [] {
                let split = tab["split"] as? Bool ?? false
                rows.append("\(tab["id"] as? String ?? "") \(split) \(tab["tab_bar_position"] as? Int ?? 0)")
            }
        }
        return rows.sorted()
    }

    /// After the relaunch: the wait in flight heard "restarting" with its tab's plan (AE14); list_tabs gives the same ids
    /// and splits (AE10), and the running command's tab its restored details, with its put-back line refusing input (AE11).
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
        let object = (try? JSONSerialization.jsonObject(with: Data(nowText.utf8))) as? [String: Any]
        let tabs = (object?["windows"] as? [[String: Any]] ?? []).flatMap { $0["tabs"] as? [[String: Any]] ?? [] }
        let details = tabs.first { $0["id"] as? String == id }?["restored"] as? [String: Any]
        check(details?["reason"] as? String == "update" && details?["state_before"] as? String == "running"
              && details?["interrupted"] as? Bool == true && details?["outcome"] as? String == "command_on_the_line",
              "MCP across the update: the running command's tab says it came back from the update, running before and cut off",
              "\(details ?? [:])")
        _ = await SelfTest.wait(10) { tabs.isEmpty || AppDelegate.shared.controllers.flatMap(\.tabs).contains { $0.id.uuidString.lowercased() == id && $0.restoredRecord?.pending?.state == .applied } }
        let refused = await mcp.call(3, "tools/call", ["name": "send_to_tab", "arguments": ["tab_id": id, "text": "", "submit": true]])
        check(text(refused).contains("put back"), "MCP across the update: send_to_tab with Return into the put-back tab is refused",
              text(refused))
    }
}
#endif
