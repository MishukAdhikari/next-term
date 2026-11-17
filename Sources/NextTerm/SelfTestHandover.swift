import AppKit
import NextTermCore

/// forward_prompt (plan 042), on screen. Stand-in agents (a `claude` that turns bracketed paste on and writes what it
/// reads to a file) run in windows of four projects, and a closed Claude Code session sits in a home folder of the
/// test's own; an agent's bridge in another tab hands prompts over:
/// - one clear match ("the cs tab") reaches coding-sessions, after the note, as one paste and Return;
/// - two that fit alike ask on the Mac: Cancel moves nothing and answers the candidates; choosing one delivers there;
/// - a call again with a candidate's session id delivers with no picker;
/// - a closed session is resumed in a tab, then given the prompts;
/// - a target whose agent has ended gets nothing.
/// Screenshots: the picker, and the tab that received the prompts.
extension SelfTest {
    static func handoverChecks(_ c: TerminalWindowController) async {
        guard let app = AppDelegate.shared else { return }
        let fm = FileManager.default
        let base = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory())).appendingPathComponent("nt-handover-\(getpid())")
        try? fm.removeItem(at: base)
        let bin = base.appendingPathComponent("bin").path, got = base.appendingPathComponent("got").path
        let home = base.appendingPathComponent("home")
        let work = base.appendingPathComponent("work")
        for folder in [bin, got] { try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        let projects = ["coding-sessions", "next-term", "next-term-site", "xcloud", "old-api"]
        for project in projects { try? fm.createDirectory(at: work.appendingPathComponent(project), withIntermediateDirectories: true) }
        // A stand-in Claude Code: bracketed paste on, raw, everything it reads written to got/<project>.
        let script = """
        #!/bin/sh
        \(stopsOnCtrlC)
        stty raw -echo
        printf '\\033[?2004h'
        exec cat >> "$NT_GOT/$(basename "$PWD")"

        """
        fm.createFile(atPath: bin + "/claude", contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        let env = "NT_GOT=\(ShellQuote.quote(got)) PATH=\(ShellQuote.quote(bin)):$PATH "
        func received(_ project: String) -> String { (try? String(contentsOfFile: got + "/" + project, encoding: .utf8)) ?? "" }

        // A closed session of old-api in the test's own home.
        let oldAPI = work.appendingPathComponent("old-api").path
        let claudeDir = home.appendingPathComponent(".claude/projects/" + AgentSessions.claudeFolderName(oldAPI))
        try? fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        func line(_ object: [String: Any]) -> String { String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self) }
        let when = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-300))
        let lines = [line(["type": "summary"]),
                     line(["type": "user", "cwd": oldAPI, "timestamp": when, "message": ["role": "user", "content": "Paginate the orders endpoint"]]),
                     line(["type": "assistant", "cwd": oldAPI, "timestamp": when, "message": ["content": [["type": "text", "text": "Done."]]]]),
                     line(["type": "custom-title", "customTitle": "Orders pagination"])]
        try? (lines.joined(separator: "\n") + "\n").write(to: claudeDir.appendingPathComponent("oldsession.jsonl"), atomically: true, encoding: .utf8)

        let savedHome = SessionStore.home, savedPrefix = SessionStore.commandPrefix, savedSettle = MCPHandoverControl.settle
        SessionStore.home = home.path
        SessionStore.commandPrefix = env
        MCPHandoverControl.settle = (0.3, 0.5)
        var windows: [TerminalWindowController] = []
        defer {
            for window in windows { for tab in window.tabs { tab.view.send(txt: "\u{03}") }; window.window?.close() }
            HandoverPicker.current?.close()
            SessionStore.home = savedHome
            SessionStore.commandPrefix = savedPrefix
            MCPHandoverControl.settle = savedSettle
            try? fm.removeItem(at: base)
        }
        var agents: [String: TerminalTab] = [:]
        for project in projects {
            let window = app.openWindow(directory: work.appendingPathComponent(project).path)
            windows.append(window)
            guard let tab = window.tabs.first else { return check(false, "hand-over: \(project)'s window has a tab") }
            _ = await wait(20) { tab.status.integrated }
            if project != "old-api" { // old-api has no agent open: its session is closed
                tab.view.send(txt: env + "claude\r")
                agents[project] = tab
            }
        }
        for (project, tab) in agents {
            let running = await wait(15) { tab.status.running && tab.status.kind == .agent && tab.view.getTerminal().bracketedPasteMode }
            check(running, "hand-over: a stand-in Claude Code runs in \(project)")
        }
        c.window?.makeKeyAndOrderFront(nil)

        let initialize: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                         "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                                                    "clientInfo": ["name": "self-test", "version": "1"]]]
        let userFile = MCPHubControl.userFile ?? base.appendingPathComponent("mcp.json").path
        var calls = 0
        func forward(_ arguments: [String: Any]) async -> (text: String, structured: [String: Any]) {
            calls += 1
            let call: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "forward_prompt", "arguments": arguments]]
            let answer = await bridgeInTab(c, folder: base, requests: [initialize, call], name: "handover-\(calls)", userFile: userFile)[2]
            let structured = (answer?["result"] as? [String: Any])?["structuredContent"] as? [String: Any] ?? [:]
            return (resultText(answer), structured)
        }

        // One clear match.
        let cs = await forward(["prompts": ["great now cs --live --all should show just the name /typography", "or judge with research"],
                                "hint": "hey wait find the cs tab in next term", "note": "I read coding-sessions' source and changed nothing."])
        let arrived = await wait(5) { received("coding-sessions").contains("or judge with research") }
        let text = received("coding-sessions")
        check(cs.structured["status"] as? String == "delivered" && cs.structured["project"] as? String == "coding-sessions" && arrived
              && text.hasPrefix("\u{1b}[200~(Moved here from the") && text.contains("great now cs --live --all") && text.hasSuffix("\u{1b}[201~\r"),
              "hand-over: one clear match is typed there as one paste, then Return", cs.text + " | " + text.debugDescription)
        check(received("next-term").isEmpty && received("xcloud").isEmpty, "hand-over: no other tab gets anything")
        if let window = windows.first?.window { await screenshot(window, suffix: "-handover-delivered") }

        // Two that fit alike: the picker; Cancel moves nothing.
        let ask: [String: Any] = ["prompts": ["update the release notes for next term"], "hint": "the next term tab"]
        let canceller = Task { @MainActor in
            guard await wait(30, { HandoverPicker.current?.window?.isVisible == true }), let picker = HandoverPicker.current, let window = picker.window else { return }
            check(picker.sendButton.keyEquivalent.isEmpty && !window.isKeyWindow, "hand-over: the picker takes no keyboard, Send Here only by a click")
            await screenshot(window, suffix: "-handover-picker")
            picker.cancelButton.performClick(nil)
        }
        let cancelled = await forward(ask)
        await canceller.value
        let candidates = cancelled.structured["candidates"] as? [[String: Any]] ?? []
        let projectsOffered = Set(candidates.compactMap { $0["project"] as? String })
        check(cancelled.structured["status"] as? String == "not_moved" && projectsOffered.isSuperset(of: ["next-term", "next-term-site"])
              && received("next-term").isEmpty && received("next-term-site").isEmpty,
              "hand-over: Cancel in the picker moves nothing and answers the candidates", cancelled.text)
        check(candidates.allSatisfy { $0["title"] == nil }, "hand-over: candidates carry no titles or prompts")

        // Choosing in the picker delivers there.
        let chooser = Task { @MainActor in
            guard await wait(30, { HandoverPicker.current?.window?.isVisible == true }), let picker = HandoverPicker.current else { return }
            for row in 0..<12 {
                picker.select(row)
                if picker.chosen?.project == "next-term-site" { break }
            }
            picker.sendButton.performClick(nil)
        }
        let chose = await forward(ask)
        await chooser.value
        let siteGot = await wait(5) { received("next-term-site").contains("update the release notes") }
        check(chose.structured["project"] as? String == "next-term-site" && siteGot,
              "hand-over: the session chosen in the picker gets the prompts", chose.text)

        // Again with a candidate's session id: no picker.
        if let id = candidates.first(where: { $0["project"] as? String == "next-term" })?["id"] as? String {
            let again = await forward(["prompts": ["and the changelog"], "session": id])
            let againGot = await wait(5) { received("next-term").contains("and the changelog") }
            check(again.structured["project"] as? String == "next-term" && HandoverPicker.current == nil && againGot,
                  "hand-over: a call again with the chosen session's id delivers with no picker", again.text)
        } else {
            check(false, "hand-over: the candidates include next-term")
        }

        // A closed session: resumed in a tab, then given the prompts.
        let resumed = await forward(["prompts": ["paginate the refunds endpoint too"], "hint": "old api"])
        let oldGot = await wait(10) { received("old-api").contains("paginate the refunds endpoint") }
        check(resumed.structured["resumed"] as? Bool == true && oldGot,
              "hand-over: a closed session is resumed in a tab and given the prompts", resumed.text + " | " + received("old-api").debugDescription)

        // A target whose agent has ended gets nothing.
        if let xcloud = agents["xcloud"] {
            // The stand-in reads raw, so ^C is only a byte to it: its process is ended instead.
            let group = tcgetpgrp(xcloud.view.process.childfd)
            if group > 0 { kill(-group, SIGTERM) }
            _ = await wait(10) { !xcloud.status.running }
            let gone = await forward(["prompts": ["check the invoices"], "session": xcloud.id.uuidString.lowercased()])
            check(gone.structured["status"] as? String == "not_moved" && received("xcloud").isEmpty,
                  "hand-over: a target whose agent has ended gets nothing", gone.text)
        }
    }
}
