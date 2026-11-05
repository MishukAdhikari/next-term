#if DEBUG
import AppKit
import NextTermCore

/// The MCP hub, step 3: Settings › MCP Servers, on a list and a project of the self-test's own (MCPHubControl.userFile,
/// MCPServersSettingsView.projectsForTest). Empty, the tab is one line and one Add button, and no list is made. A
/// server added through the sheet lands in the list; a pasted README block with a key in it puts the key in Secrets
/// (the self-test's own vault) and only a reference in the list; a project's list waits until it is approved, then
/// starts for agents there. Screenshots: the tab empty and with servers, the project's side, and each sheet. The
/// user's own list, Secrets and projects are never read or written here.
///
/// Steps 5 and 6: Found in your agents lists a server in an agent's config (a Codex file of the self-test's own, never
/// the user's agents), and its Add… opens the paste sheet with it and adds it, the file as it was; the new-server offer's
/// notice, with Add… its one primary; and the agent tools, list_mcp_servers' answer and add_mcp_server's refusals,
/// which ask nothing.
extension SelfTest {
    static func mcpHubSettingsChecks() async {
        let manager = FileManager.default
        let dir = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory())).appendingPathComponent("nt-mcphub-settings-\(getpid())")
        let project = dir.appendingPathComponent("app").path
        try? manager.createDirectory(atPath: project + "/.git", withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("fake-server.sh").path
        try? hubFakeServer.write(toFile: script, atomically: true, encoding: .utf8)
        let userFile = dir.appendingPathComponent("hub/mcp.json").path
        let savedFile = MCPHubControl.userFile, savedProjects = MCPServersSettingsView.projectsForTest
        let savedAgents = MCPHubAgentServers.sourcesForTest
        MCPHubControl.userFile = userFile
        MCPServersSettingsView.projectsForTest = [project]
        MCPHubAgentServers.sourcesForTest = []
        let view = MCPServersSettingsView(frame: NSRect(x: 0, y: 0, width: 620, height: 560))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Settings"
        window.contentView = view
        window.center()
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            MCPHubControl.userFile = savedFile
            MCPServersSettingsView.projectsForTest = savedProjects
            MCPHubAgentServers.sourcesForTest = savedAgents
            GitToast.dismiss()
            try? manager.removeItem(at: dir)
        }

        check(MCPShortcuts.settingsTabs.contains("mcp"), "MCP settings: show_settings opens the MCP Servers tab as mcp")
        view.show(0)
        check(view.showsEmpty && view.emptyText.stringValue == MCPServersSettingsView.emptyLine && view.emptyButton.title == "Add Server\u{2026}"
              && !manager.fileExists(atPath: userFile),
              "MCP settings: with no server, the tab is one line and one Add button, and no list is made", view.emptyText.stringValue)
        await screenshot(window, suffix: "-mcp-settings-empty")

        // Add Server…: a name and a command, and the list is made with it.
        view.add()
        guard let add = view.sheet as? MCPServerSheet, let addWindow = add.window else { return check(false, "MCP settings: Add opens its sheet") }
        add.nameField.stringValue = "fake"
        add.runsField.stringValue = "/bin/sh " + ShellQuote.quote(script)
        add.refresh()
        check(add.addButton.isEnabled && add.title == "Add an MCP Server", "MCP settings: the Add sheet takes a name and a command",
              add.reasonLabel.stringValue)
        await screenshot(addWindow, suffix: "-mcp-settings-add")
        add.confirm()
        _ = await wait(5) { view.rows.contains { $0.name == "fake" } }
        let listed = (try? String(contentsOfFile: userFile, encoding: .utf8)) ?? ""
        check(view.rows.map(\.name) == ["fake"] && listed.contains("\"fake\"") && listed.contains(script),
              "MCP settings: a server added through the sheet is in the list and the table", listed)

        // Paste a Config…: a README's block with a key in it. The key goes to Secrets; the list gets its name only.
        let fakeKey = "ghp_" + String(repeating: "Q7zX", count: 9)
        view.paste()
        guard let paste = view.sheet as? MCPPasteSheet, let pasteWindow = paste.window else { return check(false, "MCP settings: Paste opens its sheet") }
        paste.textView.string = """
            {
              "mcpServers": {
                "demo": {
                  "command": "npx",
                  "args": ["-y", "demo-mcp@1.0.0"],
                  "env": {"DEMO_API_KEY": "\(fakeKey)"}
                }
              }
            }
            """
        paste.refresh()
        let key = paste.found.first?.keys.first
        check(paste.found.map(\.name) == ["demo"] && key?.name == "DEMO_API_KEY" && key?.kind != nil,
              "MCP settings: a pasted block's server is found, and its key is listed for Secrets", paste.status.stringValue)
        await screenshot(pasteWindow, suffix: "-mcp-settings-paste")
        if AppDelegate.shared.agentControl {
            paste.confirm()
            _ = await wait(5) { paste.confirmAlert != nil }
            check(paste.confirmAlert?.messageText == "Copy 1 key into Secrets?", "MCP settings: Add asks before it copies the key",
                  paste.confirmAlert?.messageText ?? "no confirm")
            if let alertWindow = paste.confirmAlert?.window { await screenshot(alertWindow, suffix: "-mcp-settings-paste-confirm") }
            paste.confirmAlert?.buttons.first?.performClick(nil)
            _ = await wait(10) { view.rows.contains { $0.name == "demo" } }
            let after = (try? String(contentsOfFile: userFile, encoding: .utf8)) ?? ""
            check(!after.contains(fakeKey) && after.contains("\"DEMO_API_KEY\", \"--\", \"npx\"")
                  && (SecretsStore.shared.index?.names ?? []).contains("DEMO_API_KEY"),
                  "MCP settings: the pasted key is in Secrets, and the list starts the server with nxtrm secret run, never the key", after)
        } else {
            note("MCP settings: agent control is off here, so the pasted key isn't copied in")
            paste.cancel()
        }

        // Remove, then Undo: the server is back as it was.
        if let at = view.rows.firstIndex(where: { $0.name == "fake" }) {
            view.table.selectRowIndexes(IndexSet(integer: at), byExtendingSelection: false)
            let before = (try? Data(contentsOf: URL(fileURLWithPath: userFile))) ?? Data()
            view.remove()
            let removed = !view.rows.contains { $0.name == "fake" }
            view.undo()
            check(removed && view.rows.contains { $0.name == "fake" } && (try? Data(contentsOf: URL(fileURLWithPath: userFile))) == before,
                  "MCP settings: Remove takes a server out, and Undo puts the list back byte for byte")
        }
        await screenshot(window, suffix: "-mcp-settings-servers")

        // A project's list: listed, waiting, until approved as it is; then an agent there gets it ready.
        let list = project + "/" + MCPHubScope.projectFile
        try? manager.createDirectory(atPath: project + "/" + MCPHubScope.projectFolder, withIntermediateDirectories: true)
        try? #"{"mcpServers": {"team": {"command": "/bin/sh", "args": ["\#(script)"]}}}"#.write(toFile: list, atomically: true, encoding: .utf8)
        view.show(1)
        let waiting = view.rows.firstIndex { $0.name == "team" && $0.state == .needsApproval }
        check(waiting != nil && view.approveButton.isHidden == false, "MCP settings: a project's list waits for approval",
              view.rows.map { "\($0.name) \(MCPHubOverview.stateText($0.state))" }.joined(separator: ", "))
        await screenshot(window, suffix: "-mcp-settings-project")
        if let waiting {
            view.table.selectRowIndexes(IndexSet(integer: waiting), byExtendingSelection: false)
            check(view.approveButton.isEnabled, "MCP settings: Approve… is offered for the waiting list")
            view.approve()
            _ = await wait(5) { view.approveAlert != nil }
            if let alertWindow = view.approveAlert?.window { await screenshot(alertWindow, suffix: "-mcp-settings-approve") }
            check(view.approveAlert?.buttons.first?.title == "Approve" && view.approveAlert?.informativeText.contains("team") == true,
                  "MCP settings: Approve names each server and what it runs, with Approve its one primary", view.approveAlert?.informativeText ?? "none")
            view.approveAlert?.buttons.first?.performClick(nil)
            _ = await wait(5) { view.rows.contains { $0.name == "team" && $0.state == .ready(tools: nil) } }
            let resolution = MCPHubScope.servers(folder: project, userFile: userFile)
            let plan = MCPHubPlan.make(resolution, folder: project, path: [], approved: resolution.approved)
            check(plan.server(named: "team")?.state == .ready, "MCP settings: once approved, an agent in the project gets the list's server ready",
                  "\(plan.servers.map { "\($0.name) \($0.state.rawValue)" })")
        }
        view.show(0)
        await agentsChecks(view, window: window, dir: dir, script: script, userFile: userFile)
    }

    /// Found in your agents, the new-server offer's notice, and the agent tools.
    private static func agentsChecks(_ view: MCPServersSettingsView, window: NSWindow, dir: URL, script: String, userFile: String) async {
        let codex = dir.appendingPathComponent("codex/config.toml").path
        try? FileManager.default.createDirectory(atPath: (codex as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // An argument of its own: a server that runs what one in the list runs is that one, and left out (notAdded).
        let config = "[mcp_servers.found-demo]\ncommand = \"/bin/sh\"\nargs = [\"\(script)\", \"found\"]\n"
        try? config.write(toFile: codex, atomically: true, encoding: .utf8)
        MCPHubAgentServers.sourcesForTest = [SecretImport.Source(path: codex, client: .codex, format: .toml, containers: [["mcp_servers"]])]
        view.reload()
        _ = await wait(5) { view.foundRows.contains { $0.name == "found-demo" } }
        let row = view.foundRows.first { $0.name == "found-demo" }
        check(row?.agentsText == "Codex" && row?.runs.contains(script) == true && !view.foundTable.isHidden,
              "MCP agents: Found in your agents lists a server in Codex\u{2019}s config, naming Codex",
              view.foundRows.map { "\($0.name) in \($0.agentsText)" }.joined(separator: ", "))
        await screenshot(window, suffix: "-mcp-settings-found")

        if let row {
            // The offer's notice for it: Add… is its one primary, and it takes no keyboard.
            GitToast.show(MCPHubAgents.offerText(row), in: window, button: "Add\u{2026}", action: {}, other: "Not Now", otherAction: {}, primary: true)
            check(GitToast.text == "Codex has a new MCP server, \u{201C}found-demo\u{201D}. Use it in every agent in Next Term?",
                  "MCP agents: the new-server offer names the agent and the server", GitToast.text ?? "none")
            // The notice is a panel of its own, a child of the window: the window's capture leaves it out.
            await screenshot(window.childWindows?.last ?? window, suffix: "-mcp-offer")
            GitToast.dismiss()

            view.addFound(row)
            guard let sheet = view.sheet as? MCPPasteSheet, let sheetWindow = sheet.window else {
                return check(false, "MCP agents: Add\u{2026} opens the paste sheet with the server")
            }
            check(sheet.preset?.name == "found-demo" && sheet.found.map(\.name) == ["found-demo"] && sheet.addButton.isEnabled,
                  "MCP agents: Add\u{2026} opens the paste sheet with the agent\u{2019}s server in place of the text", sheet.status.stringValue)
            await screenshot(sheetWindow, suffix: "-mcp-settings-found-add")
            let before = try? Data(contentsOf: URL(fileURLWithPath: codex))
            sheet.confirm()
            _ = await wait(5) { view.rows.contains { $0.name == "found-demo" } }
            check(view.rows.contains { $0.name == "found-demo" } && !view.foundRows.contains { $0.name == "found-demo" }
                  && (try? Data(contentsOf: URL(fileURLWithPath: codex))) == before,
                  "MCP agents: once added it is in the list, no longer under Found in your agents, and Codex\u{2019}s file is as it was")
        }

        // The agent tools: list_mcp_servers names the servers with their state, never a key; add_mcp_server refuses a key
        // and an unknown one before anything is asked.
        let listed = MCPHubAgentTools.list(caller: nil).text
        check(listed.contains("\"found-demo\"") && listed.contains("\"state\"") && !listed.contains("DEMO_API_KEY"),
              "MCP agents: list_mcp_servers names each server and its state, never a key", listed)
        var answers: [MCPServer.CallResult] = []
        MCPHubAgentTools.add(["name": "x", "command": "npx", "env": ["GITHUB_TOKEN": "ghp_" + String(repeating: "Q7zX", count: 9)]], caller: nil) {
            answers.append($0)
        }
        MCPHubAgentTools.add(["name": "y", "command": "npx", "secrets": ["NT_SELFTEST_NO_SUCH_KEY"]], caller: nil) { answers.append($0) }
        check(answers.count == 2 && answers.allSatisfy(\.isError) && answers[0].text.contains("request_secret")
              && answers[1].text.contains("is not in Secrets") && MCPWriteControl.pending == nil,
              "MCP agents: add_mcp_server refuses a key, and a key that isn\u{2019}t stored, without asking", answers.map(\.text).joined(separator: " | "))
        MCPHubAgentServers.sourcesForTest = []
    }
}
#endif
