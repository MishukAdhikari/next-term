import AppKit
import NextTermCore

/// An agent's scratch window (AgentScratch), on temporary folders of the part's own, with a grace of seconds instead of a
/// minute (TerminalWindowController.scratchGraceForTest). A window new_tab opens there is the agent's: kept out of Recent
/// Projects, the Welcome history and the session restore, and once its shell is idle it closes by itself when the grace
/// ends, with no question and no Welcome window. A click in it before then makes it the user's, and it stays; a command
/// running in it holds the close until it ends, and the grace starts then. A temporary folder the user opens never
/// closes by itself, and is a recent project as any other. NEXTTERM_SELFTEST_ONLY=agentScratch runs it alone.
extension SelfTest {
    static func agentScratchChecks(_ c: TerminalWindowController) async {
        #if DEBUG
        guard let app = AppDelegate.shared else { return }
        let fm = FileManager.default
        let base = canonicalPath(NSTemporaryDirectory()) + "/nt-scratch-\(getpid())"
        try? fm.removeItem(atPath: base)
        for folder in ["quiet", "clicked", "busy", "users"] {
            try? fm.createDirectory(atPath: base + "/" + folder, withIntermediateDirectories: true)
        }
        let grace: TimeInterval = 2
        TerminalWindowController.scratchGraceForTest = grace
        let recentsBefore = UserDefaults.standard.stringArray(forKey: "recentProjects")
        var opened: [TerminalWindowController] = []
        defer {
            TerminalWindowController.scratchGraceForTest = nil
            for w in opened where !w.hasClosed { w.window?.close() }
            UserDefaults.standard.set(recentsBefore, forKey: "recentProjects")
            c.window?.makeKeyAndOrderFront(nil)
            try? fm.removeItem(atPath: base)
        }

        /// new_tab, as an agent outside Next Term calls it: the tab and the window it opened in.
        func newTab(_ folder: String, command: String? = nil) async -> (TerminalTab, TerminalWindowController)? {
            var result = MCPServer.CallResult(text: "", isError: false)
            var arguments: [String: Any] = ["directory": base + "/" + folder]
            if let command { arguments["command"] = command }
            MCPControl.call("new_tab", arguments, caller: nil) { result = $0 }
            _ = await wait(10) { !result.text.isEmpty }
            let json = (try? JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any]) ?? [:]
            guard let id = json["id"] as? String,
                  let owner = app.controllers.first(where: { $0.tabs.contains { $0.id.uuidString.lowercased() == id } }),
                  let tab = owner.tabs.first(where: { $0.id.uuidString.lowercased() == id }) else {
                check(false, "agent scratch: new_tab opens a tab in \(folder)", result.text)
                return nil
            }
            opened.append(owner)
            return (tab, owner)
        }
        func listed(_ path: String) -> [String] {
            var lists: [String] = []
            if app.recentProjects.contains(path) { lists.append("Recent Projects") }
            if (UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []).contains(path) { lists.append("recentProjects defaults") }
            if NSDocumentController.shared.recentDocumentURLs.contains(where: { canonicalPath($0.path) == path }) { lists.append("Open Recent") }
            if ProjectHistoryRecorder.shared.history.paths.contains(path) { lists.append("Welcome history") }
            if ProjectHistoryRecorder.shared.windowCounts[path] != nil { lists.append("Welcome open projects") }
            if SessionCapture.windows(app.controllers).contains(where: { $0.project == path }) { lists.append("session restore") }
            return lists
        }
        func welcomeShows() -> Bool { app.welcomeController?.window?.isVisible == true }

        // 1 and 4. Opened by an agent, its shell idle: in no list, and closed by itself once the grace ends.
        let quietPath = canonicalPath(base + "/quiet")
        guard let (quietTab, quiet) = await newTab("quiet") else { return }
        let openedAt = Date()
        check(quiet !== c && quiet.openedByAgent && quiet.isAgentScratch && quiet.project == quietPath,
              "agent scratch: new_tab on a temporary folder opens a window of its own, marked as opened by an agent",
              "own window \(quiet !== c), by agent \(quiet.openedByAgent), scratch \(quiet.isAgentScratch), project \(quiet.project ?? "none")")
        var integratedOpen = false
        _ = await wait(10) {
            if quietTab.status.integrated && !quiet.hasClosed { integratedOpen = true }
            return integratedOpen || quiet.hasClosed
        }
        if !quiet.hasClosed, let window = quiet.window { await screenshot(window, suffix: "-agent-scratch") }
        let whileOpen: [String] = quiet.hasClosed ? ["closed before it could be read"] : listed(quietPath)
        check(whileOpen.isEmpty, "agent scratch: while open it is in no Recent Projects, Open Recent, Welcome history or session restore",
              whileOpen.joined(separator: ", "))
        var sheet = false
        let closed = await wait(grace + 8) {
            if quiet.window?.attachedSheet != nil { sheet = true }
            return quiet.hasClosed
        }
        let after: TimeInterval = Date().timeIntervalSince(openedAt)
        check(closed && integratedOpen && after >= grace - 0.3 && !sheet,
              "agent scratch: once its shell is idle it closes by itself when the grace ends, asking nothing",
              "closed \(closed) after \(String(format: "%.1f", after)) s (grace \(grace) s), shell reported in while open \(integratedOpen), "
                + "asked \(sheet), tab exited \(quietTab.exited)")
        await pause(0.5) // AppDelegate drops it a run-loop turn later, and would show the Welcome window then
        check(!welcomeShows() && !app.controllers.contains { $0 === quiet } && c.window?.isVisible == true,
              "agent scratch: and no Welcome window comes up for it; the other windows stay",
              "Welcome \(welcomeShows()), still listed \(app.controllers.contains { $0 === quiet })")
        let afterClose: [String] = listed(quietPath)
        check(afterClose.isEmpty, "agent scratch: closed, it is in no list either", afterClose.joined(separator: ", "))

        // 2. A click in it before the grace ends: the user's, and it stays.
        guard let (clickedTab, clicked) = await newTab("clicked"), let clickedWindow = clicked.window else { return }
        _ = await wait(10) { clickedTab.status.integrated || clicked.hasClosed }
        clickedWindow.contentView?.layoutSubtreeIfNeeded()
        let view: NSView = clickedTab.view
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        var sent = false
        if !clicked.hasClosed {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: clickedWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                     pressure: type == .leftMouseDown ? 1 : 0) else { continue }
                clickedWindow.sendEvent(event)
                sent = true
            }
        }
        let clickedClosed = await wait(grace + 4) { clicked.hasClosed }
        check(sent && !clickedClosed && clicked.touchedByUser,
              "agent scratch: a click in it before the grace ends makes it the user's, and it stays past the grace",
              "click sent \(sent), closed \(clickedClosed), touched \(clicked.touchedByUser)")
        if !clicked.hasClosed { await screenshot(clickedWindow, suffix: "-agent-scratch-clicked") }
        clickedWindow.close()

        // 3. A command running in it holds the close; the grace starts once it ends. A long grace while the shell starts
        // and the command is typed, so it is the command that holds the window, then the part's short one.
        TerminalWindowController.scratchGraceForTest = 30
        guard let (busyTab, busy) = await newTab("busy", command: "sleep 5") else { return }
        let started = await wait(15) { busyTab.status.running }
        TerminalWindowController.scratchGraceForTest = grace
        var heldWhileRunning = true
        let ended = await wait(15) {
            if busy.hasClosed { heldWhileRunning = false }
            return !busyTab.status.running || busy.hasClosed
        }
        let endedAt = Date()
        check(started && ended && heldWhileRunning && !busy.hasClosed,
              "agent scratch: a command running in it (sleep 5) holds the close until it ends",
              "started \(started), ended \(ended), closed meanwhile \(busy.hasClosed)")
        let busyClosed = await wait(grace + 8) { busy.hasClosed }
        let afterEnd: TimeInterval = Date().timeIntervalSince(endedAt)
        check(busyClosed && afterEnd >= grace - 0.3,
              "agent scratch: and then closes by itself once the grace after it ends",
              "closed \(busyClosed) \(String(format: "%.1f", afterEnd)) s after the command ended (grace \(grace) s)")

        // 5. A temporary folder the user opens: theirs, never closed by itself, and a recent project as any other.
        let usersPath = canonicalPath(base + "/users")
        let users = app.openFolder(usersPath, newWindow: false)
        opened.append(users)
        _ = await wait(10) { users.activeTab?.status.integrated == true || users.hasClosed }
        let usersClosed = await wait(grace + 4) { users.hasClosed }
        check(!users.openedByAgent && !users.isAgentScratch && !usersClosed,
              "agent scratch: a temporary folder the user opens never closes by itself",
              "by agent \(users.openedByAgent), scratch \(users.isAgentScratch), closed \(usersClosed)")
        check(app.recentProjects.contains(usersPath), "agent scratch: and is a recent project as any other",
              "\(app.recentProjects.prefix(5))")
        users.window?.close()
        #endif
    }
}
