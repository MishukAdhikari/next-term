import AppKit
import CryptoKit
import NextTermCore
import SQLite3

/// Agent sessions from every agent: Gemini CLI, Qwen Code, opencode, Cursor Agent and Copilot CLI beside
/// Claude Code, in the Welcome window, ⌥⌘O and the sidebar's Agent Sessions group; a session open in a
/// tab (Go to Tab, "running"), whether it was resumed by id or started plainly; Continue Latest; More….
/// Every store is made here by hand, and the commands are echoed, not run.
extension SelfTest {
    /// The Claude Code session a tab resumes by id (Claude Code's ids are UUIDs, and only one names a session).
    static let openClaudeID = "5e55a0de-0000-4000-8000-0000000000a1"

    static func moreSessionChecks(proj: URL) async {
        guard let app = AppDelegate.shared else { return }
        let fm = FileManager.default
        let home = canonicalPath(NSTemporaryDirectory()) + "/nt-more-sessions-\(getpid())"
        let project = canonicalPath(proj.path)
        let bin = home + "/bin"
        try? fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        for name in ["claude", "gemini"] { // stand-ins that only wait
            fm.createFile(atPath: bin + "/" + name, contents: Data("#!/bin/sh\nsleep 120\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        writeSessionStores(home: home, project: project)
        SessionStore.home = home
        SessionStore.commandPrefix = "echo "
        var opened: [TerminalTab] = []
        let holder = app.openFolder(project, newWindow: false)
        defer {
            for tab in opened {
                tab.view.send(txt: "\u{03}")
                if let owner = app.controllers.first(where: { $0.tabs.contains { $0 === tab } }) { owner.remove(tab) }
            }
            SessionStore.home = NSHomeDirectory()
            SessionStore.commandPrefix = ""
            try? fm.removeItem(atPath: home)
            holder.sidebar.loadSessions()
        }
        if !holder.isSidebarVisible { holder.toggleProjectSidebar(nil) }

        // Claude Code resumed by id in one tab; Gemini CLI started plainly in another, its session made after.
        let claudeTab = holder.addTab(directory: project)
        opened.append(claudeTab)
        _ = await wait(20) { claudeTab.status.integrated }
        claudeTab.view.send(txt: bin + "/claude --resume \(openClaudeID)\r")
        check(await wait(10) { claudeTab.status.running && claudeTab.status.kind == .agent }, "sessions: a tab runs `claude --resume <id>` (a stand-in)",
              claudeTab.status.command)
        let geminiTab = holder.addTab(directory: project)
        opened.append(geminiTab)
        _ = await wait(20) { geminiTab.status.integrated }
        geminiTab.view.send(txt: bin + "/gemini\r")
        check(await wait(10) { geminiTab.status.running && geminiTab.status.kind == .agent }, "sessions: another runs plain `gemini`", geminiTab.status.command)
        await pause(1.2)
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let started = precise.string(from: Date())
        writeLines([["sessionId": "g2-session", "projectHash": "h", "startTime": started, "lastUpdated": started, "kind": "main"],
                    ["id": "m1", "timestamp": started, "type": "user", "content": [["text": "Plan the migration"]]]],
                   to: home + "/.gemini/tmp/proj/chats/session-2-g2-sessi.jsonl")

        // The Welcome window: every agent's sessions, Go to Tab for the open one, no Fork for Gemini CLI.
        app.showWelcome(nil)
        guard let welcome = app.welcomeController, let welcomeWindow = welcome.window else { return check(false, "sessions: the Welcome window opens") }
        welcome.select(project: project)
        check(await wait(10) { welcome.shownSessionTitles.count == 8 },
              "Welcome lists Gemini CLI, Qwen Code, opencode, Cursor Agent and Copilot CLI sessions beside Claude Code's",
              welcome.shownSessionTitles.joined(separator: " | "))
        check(welcome.filterIsMenu, "with six agents in a folder, the agent filter is a menu")
        welcome.selectSession(titled: "Tidy the routes")
        check(welcome.resumeTitle == "Go to Tab", "a session open in a tab offers Go to Tab instead of a second resume", welcome.resumeTitle)
        let tabCount = holder.tabs.count
        welcome.resumeSelected()
        check(await wait(5) { holder.activeTab === claudeTab } && holder.tabs.count == tabCount, "Go to Tab shows that tab, and opens none")
        welcome.selectSession(titled: "Explain the cache")
        check(welcome.resumeTitle == "Resume" && !welcome.canFork, "a Gemini CLI session resumes, and cannot fork", welcome.resumeTitle)
        await screenshot(welcomeWindow, suffix: "welcome-agents")
        welcome.close()

        // ⌥⌘O says what ↩ does.
        holder.window?.makeKeyAndOrderFront(nil)
        holder.resumeSession(nil)
        let panel = holder.sessionsPanel
        check(await wait(10) { panel.shownTitles.count == 8 }, "⌥⌘O lists them too", panel.shownTitles.joined(separator: " | "))
        panel.query = "routes"
        check(panel.hintText.hasPrefix("↩ go to tab"), "⌥⌘O: ↩ goes to the tab of a session open in one", panel.hintText)
        panel.query = "cache"
        check(panel.hintText == "↩ resume   esc close", "and offers no fork for an agent that cannot", panel.hintText)
        panel.close()

        await sidebarSessionChecks(holder, claudeTab: claudeTab, opened: &opened)
        await runningAgentChecks(holder, claudeTab: claudeTab, home: home, project: project, opened: &opened)
    }

    /// A tab's agent as the sessions see it: its own process and folder, when it started by the wall clock,
    /// and the session Claude Code's record says that process has open.
    private static func runningAgentChecks(_ holder: TerminalWindowController, claudeTab: TerminalTab, home: String, project: String,
                                           opened: inout [TerminalTab]) async {
        let agent = SessionStore.runningAgents().first { $0.key == claudeTab.id.uuidString }
        let pid = agent?.pid ?? 0
        check(pid > 0 && pid != claudeTab.view.process.shellPid && agent.map { canonicalPath($0.directory) == project } == true,
              "sessions: a tab's agent is known by its own process and folder", "pid \(pid), \(agent?.directory ?? "none")")
        let age = agent.map { Date().timeIntervalSince($0.startedAt) } ?? -1
        check(age >= 0 && age < 120, "and by when it started, on the wall clock", "\(age) s ago")

        // `cd <folder> && agent`: the shell's folder is still the one the prompt was in; the agent's is not.
        let elsewhere = holder.addTab(directory: project)
        opened.append(elsewhere)
        _ = await wait(20) { elsewhere.status.integrated }
        elsewhere.view.send(txt: "cd " + ShellQuote.quote(home + "/bin") + " && ./gemini\r")
        _ = await wait(10) { elsewhere.status.running && elsewhere.status.kind == .agent }
        var folder = ""
        _ = await wait(5) {
            folder = SessionStore.runningAgents().first { $0.key == elsewhere.id.uuidString }.map { canonicalPath($0.directory) } ?? ""
            return folder == canonicalPath(home + "/bin")
        }
        check(folder == canonicalPath(home + "/bin"), "an agent started as `cd bin && gemini` is looked for in bin", folder)

        // Claude Code's record of the session a process has open (it follows /clear) wins over the command line.
        let record = "{\"pid\": \(pid), \"sessionId\": \"s-old\"}"
        write(record, to: home + "/.claude/sessions/\(pid).json")
        let open = AgentSessions.openSessions(SessionStore.runningAgents(), home: home)
        check(open["claude:s-old"] == claudeTab.id.uuidString && open["claude:" + openClaudeID] == nil,
              "a Claude Code tab is in the session its process records, not the one its command named",
              open.map { $0.key + " → " + $0.value }.sorted().joined(separator: ", "))
    }

    /// The sidebar's Agent Sessions group: the newest five, More…, "running", Continue Latest, resume.
    private static func sidebarSessionChecks(_ holder: TerminalWindowController, claudeTab: TerminalTab, opened: inout [TerminalTab]) async {
        let sidebar = holder.sidebar
        let group = sidebar.sessionsGroup
        sidebar.loadSessions()
        let titles = { group.items.map(\.session.title).joined(separator: " | ") }
        check(await wait(10) { group.items.count == 5 && group.hasMore && group.items.first?.inTab == true },
              "the sidebar's Agent Sessions group shows the newest five and More…", titles())
        check(titles() == "Plan the migration | Tidy the routes | Explain the cache | Speed up the build | Review the PR",
              "newest first, from every agent", titles())
        check(group.items.first { $0.session.id == openClaudeID }?.inTab == true, "a session resumed by id in a tab is running there")
        check(group.items.first { $0.session.id == "g2-session" }?.inTab == true, "so is the session a plain `gemini` began after it started")
        let row = sidebar.sessionRow("claude:" + openClaudeID) ?? -1
        let cell = row >= 0 ? sidebar.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SessionRowCellView : nil
        check(cell?.badge.text == "running" && sidebar.outline.row(forItem: group.more) >= 0, "its row has a “running” badge, and More… is listed",
              "row \(row), badge \(cell?.badge.text ?? "none")")
        if let window = holder.window { await screenshot(window, suffix: "sidebar-sessions") }

        let menu = sidebar.sessionsGroupMenu().items.map(\.title)
        check(menu.contains("Continue Latest Gemini CLI Session") && menu.contains("Continue Latest Claude Code Session")
              && menu.contains("Show All Sessions…"), "the group's ⋯ continues each agent's latest session here", menu.joined(separator: ", "))
        var before = Set(holder.tabs.map(\.id))
        holder.sidebar(sidebar, session: nil, perform: .continueLatest(.qwen))
        check(await wait(10) { holder.tabs.contains { !before.contains($0.id) && $0.screenTail(10).contains("qwen --continue") } },
              "Continue Latest runs the agent's own `qwen --continue` in a new tab")
        opened += holder.tabs.filter { !before.contains($0.id) }

        before = Set(holder.tabs.map(\.id))
        if let item = group.items.first(where: { $0.session.agent == .opencode }) {
            holder.sidebar(sidebar, session: item.session, perform: .resume)
        }
        check(await wait(10) { holder.tabs.contains { !before.contains($0.id) && $0.screenTail(10).contains("opencode --session ses_1") } },
              "a double-click on a session resumes it in a new tab with its agent's command (opencode)")
        opened += holder.tabs.filter { !before.contains($0.id) }

        before = Set(holder.tabs.map(\.id))
        if let item = group.items.first(where: { $0.session.id == openClaudeID }) {
            holder.sidebar(sidebar, session: item.session, perform: .resume)
        }
        check(await wait(5) { holder.activeTab === claudeTab } && Set(holder.tabs.map(\.id)) == before, "and on one open in a tab, goes to that tab")

        holder.sidebar(sidebar, session: nil, perform: .showAll)
        check(await wait(5) { holder.sessionsPanel.isVisible }, "More… opens the whole list")
        holder.sessionsPanel.close()
    }

    /// One session per agent in its own format (two for Claude Code), newest to oldest: Claude Code 10 min
    /// ago, Gemini CLI an hour, opencode two, Copilot CLI three, Qwen Code four, Cursor Agent five, Claude
    /// Code again five days.
    private static func writeSessionStores(home: String, project: String) {
        let iso = ISO8601DateFormatter()
        func ago(_ minutes: Double) -> Date { Date().addingTimeInterval(-minutes * 60) }
        func stamp(_ minutes: Double) -> String { iso.string(from: ago(minutes)) }
        let claude = home + "/.claude/projects/" + AgentSessions.claudeFolderName(project)
        writeLines([["type": "user", "cwd": project, "timestamp": stamp(10), "message": ["content": "Tidy the routes"]]], to: claude + "/\(openClaudeID).jsonl")
        writeLines([["type": "user", "cwd": project, "timestamp": stamp(60 * 24 * 5), "message": ["content": "Bump the version"]]], to: claude + "/s-old.jsonl")

        let registry = (try? JSONSerialization.data(withJSONObject: ["projects": [project: "proj"]])) ?? Data()
        write(String(decoding: registry, as: UTF8.self), to: home + "/.gemini/projects.json")
        write(project, to: home + "/.gemini/tmp/proj/.project_root")
        writeLines([["sessionId": "g1-session", "projectHash": "h", "startTime": stamp(60), "lastUpdated": stamp(60), "kind": "main"],
                    ["id": "m1", "timestamp": stamp(60), "type": "user", "content": [["text": "Explain the cache"]]]],
                   to: home + "/.gemini/tmp/proj/chats/session-1-g1-sessi.jsonl")

        let database = home + "/.local/share/opencode/opencode.db"
        try? FileManager.default.createDirectory(atPath: (database as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var db: OpaquePointer?
        if sqlite3_open(database, &db) == SQLITE_OK {
            let ms = Int(ago(120).timeIntervalSince1970 * 1000)
            let sql = "CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT, model TEXT, time_created INTEGER,"
                + " time_updated INTEGER, time_archived INTEGER); INSERT INTO session VALUES ('ses_1', NULL, '\(project)', 'Speed up the build',"
                + " '{\"id\":\"claude-sonnet-5\"}', \(ms), \(ms), NULL);"
            sqlite3_exec(db, sql, nil, nil, nil)
        }
        sqlite3_close(db)

        write("id: c1\ncwd: \(project)\nbranch: main\nname: Review the PR\nuser_named: true\ncreated_at: \(stamp(180))\nupdated_at: \(stamp(180))\n",
              to: home + "/.copilot/session-state/c1/workspace.yaml")

        let qwenID = "0a1b2c3d-0000-4000-8000-0000000000aa"
        writeLines([["uuid": "u1", "sessionId": qwenID, "timestamp": stamp(240), "type": "user", "cwd": project, "version": "0.25.0",
                     "message": ["role": "user", "parts": [["text": "Add the tests"]]]]],
                   to: home + "/.qwen/projects/" + AgentSessions.claudeFolderName(project) + "/chats/\(qwenID).jsonl")

        let md5 = Insecure.MD5.hash(data: Data(project.utf8)).map { String(format: "%02x", $0) }.joined()
        let created = Int(ago(300).timeIntervalSince1970 * 1000)
        write("{\"createdAtMs\": \(created), \"updatedAtMs\": \(created), \"hasConversation\": true, \"title\": \"Fix the flaky test\"}",
              to: home + "/.cursor/chats/\(md5)/chat-1/meta.json")
        // Last written when they say they were: the readers go by a file's date too.
        let dates: [(String, Double)] = [(claude + "/\(openClaudeID).jsonl", 10), (claude + "/s-old.jsonl", 60 * 24 * 5),
                                         (home + "/.copilot/session-state/c1/workspace.yaml", 180)]
        for (path, minutes) in dates {
            try? FileManager.default.setAttributes([.modificationDate: ago(minutes)], ofItemAtPath: path)
        }
    }

    private static func write(_ text: String, to path: String) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func writeLines(_ lines: [[String: Any]], to path: String) {
        let text = lines.map { String(decoding: (try? JSONSerialization.data(withJSONObject: $0)) ?? Data(), as: UTF8.self) }
        write(text.joined(separator: "\n") + "\n", to: path)
    }
}
