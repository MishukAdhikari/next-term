import AppKit
import NextTermCore

/// Settings › Agents (plan 038), as the user sees it, with made-up agents on a PATH of the part's own: a native Claude
/// Code with an npm copy behind it, a standalone Codex, Gemini CLI from npm, Goose from Homebrew and Cursor's own install.
/// The latest versions come from a stub (no network), the schedules from a defaults domain of the part's own, the logs
/// from a folder of its own. Screenshots: the section with its agents, an update running, and the empty section. Each
/// of the eleven toolbar names is whole and the window keeps its one size.
extension SelfTest {
    static func agentsSettingsChecks() async {
        let manager = AgentCLIManager.shared
        let root = canonicalPath(NSTemporaryDirectory()) + "/nt-agents-settings-\(getpid())"
        try? FileManager.default.removeItem(atPath: root)
        let suite = "nt-selftest-agentclis-part-\(getpid())"
        guard let defaults = UserDefaults(suiteName: suite) else { return check(false, "agents settings: a defaults domain of its own") }
        defaults.removePersistentDomain(forName: suite)
        defer {
            AgentCLIManager.pathForTest = nil
            AgentCLIManager.latestForTest = nil
            AgentCLIManager.defaultsForTest = nil
            AgentCLIManager.logFolderForTest = nil
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(atPath: root)
        }
        let made = makeFakeAgents(root)
        guard made else { return check(false, "agents settings: the made-up agents are laid out", root) }
        AgentCLIManager.pathForTest = ["\(root)/local-bin", "\(root)/brew/bin", "\(root)/node/bin"]
        AgentCLIManager.defaultsForTest = defaults
        AgentCLIManager.logFolderForTest = "\(root)/logs"
        let latest: [String: String] = ["npm:@google/gemini-cli": "0.67.0", "claude:latest": "2.1.319",
                                        "formula:block-goose-cli": "1.57.0", "npm:@openai/codex": "0.167.0"]
        AgentCLIManager.latestForTest = { latest[$0.key] }

        AppDelegate.shared.showSettings(tab: "agents")
        guard await wait(3, { AppDelegate.shared.openSettings?.window?.isVisible == true }),
              let settings = AppDelegate.shared.openSettings, let window = settings.window,
              let pane = (window.contentView as? NSTabView)?.selectedTabViewItem?.view as? AgentsSettingsView else {
            return check(false, "agents settings: Settings opens at Agents")
        }
        let looked = await wait(8) { manager.looked && !manager.checking && pane.rows.count == 5 }
        func row(_ id: String) -> AgentCLIs.Status? { pane.rows.first { $0.agent.id == id } }
        func cell(_ id: String, _ column: String) -> String { row(id).map { pane.text(column, $0) } ?? "(no row)" }
        check(looked && pane.rows.map(\.agent.id) == ["claude", "codex", "gemini", "cursor", "goose"],
              "agents settings: the installed agents are listed, in the catalog's order", pane.rows.map(\.agent.id).joined(separator: ","))
        check(cell("claude", "version") == "2.1.280" && cell("claude", "method") == "Own installer" && cell("claude", "latest") == "2.1.319"
              && cell("codex", "latest") == "Up to date" && cell("gemini", "method") == "npm" && cell("goose", "method") == "Homebrew"
              && cell("cursor", "schedule") == "Updates itself" && cell("cursor", "latest") == "\u{2014}",
              "agents settings: each agent's version, what installed it and its latest version",
              ["claude", "codex", "gemini", "cursor", "goose"].map { id in
                  ["version", "method", "latest", "schedule"].map { cell(id, $0) }.joined(separator: "/")
              }.joined(separator: " | "))
        // Nothing is scheduled until the user picks: every agent's auto-update is Off, and no try was ever made.
        check(pane.rows.allSatisfy { $0.schedule == .off && $0.lastTry == nil } && defaults.dictionary(forKey: AgentCLIManager.schedulesKey) == nil,
              "agents settings: every auto-update is Off by default")
        if let claude = row("claude") {
            let line = AgentsSettingsView.detail(claude)
            check(line.contains("Also on your PATH, after it: npm 2.1.211") && line.contains("updates itself; its own switch is DISABLE_AUTOUPDATER"),
                  "agents settings: the copy PATH hides is named, and Claude Code's own updater with its switch", line)
        }
        if let cursor = row("cursor") {
            check(AgentCLIs.decide(cursor.agent, copy: cursor.copy, schedule: .daily, lastTry: nil, now: Date(), running: false,
                                   latest: "2099.01.01") == .skip(.updatesItself),
                  "agents settings: a tool that updates itself with no switch of its own is never scheduled")
        }
        // The toolbar: eleven names, each whole, none in an overflow menu.
        let items = settings.toolbarItems
        let visible = window.toolbar?.visibleItems?.count ?? 0
        check(items.count == 11 && visible == 11 && items.map(\.label) == SettingsWindowController.sections.map(\.label),
              "agents settings: the toolbar shows all eleven sections, every name whole", "\(visible) of \(items.count) visible")
        if let cut = settingsSectionCutOff(in: window) { check(false, "agents settings: nothing in the section is cut off", cut) }
        await screenshot(window, suffix: "-agents-settings")

        // Show agents you don't have: the others too, as not installed; Install… only with an official one-line installer.
        pane.showAll.performClick(nil)
        check(pane.rows.count == AgentCLIs.catalog.count && cell("amp", "version") == "Not installed",
              "agents settings: Show agents you don't have lists the others as not installed", "\(pane.rows.count)")
        if let amp = pane.rows.firstIndex(where: { $0.agent.id == "amp" }) {
            pane.table.selectRowIndexes(IndexSet(integer: amp), byExtendingSelection: false)
            check(!pane.installButton.isHidden && pane.updateButton.isHidden, "agents settings: a missing agent with an installer has Install…")
        }
        if let crush = pane.rows.firstIndex(where: { $0.agent.id == "crush" }) {
            pane.table.selectRowIndexes(IndexSet(integer: crush), byExtendingSelection: false)
            check(pane.installButton.isHidden, "agents settings: no Install… without an official one-line installer")
        }
        await screenshot(window, suffix: "-agents-settings-all")
        pane.showAll.performClick(nil)

        // A scheduled update: Gemini CLI daily, due, its fake npm takes two seconds and moves it to 0.67.0.
        manager.setSchedule(.daily, for: "gemini")
        manager.look()
        let running = await wait(6) { manager.updating.contains("gemini") }
        check(running && cell("gemini", "latest") == "Updating\u{2026}", "agents settings: a due update runs in the background, shown as Updating…",
              cell("gemini", "latest"))
        await screenshot(window, suffix: "-agents-settings-updating")
        let finished = await wait(15) { !manager.updating.contains("gemini") && cell("gemini", "version") == "0.67.0" }
        let notices = AppDelegate.shared.testNotifications.map(\.content)
        let updated = notices.first { $0.title == "Gemini CLI updated to 0.67.0" }
        check(finished && updated != nil && updated?.userInfo[AgentCLIManager.logKey] as? String == manager.logURL("gemini").path,
              "agents settings: one notification says it updated, with its log", notices.map(\.title).joined(separator: " | "))
        let log = (try? String(contentsOf: manager.logURL("gemini"), encoding: .utf8)) ?? ""
        check(log.contains("install -g @google/gemini-cli@latest") && log.contains("added 1 package") && log.contains("exit 0"),
              "agents settings: the update's output is in its log", log)
        check(manager.lastTry("gemini") != nil && cell("gemini", "latest") == "Up to date",
              "agents settings: the try is kept, and the row shows it up to date")
        // Not due again within the day: a second look runs nothing.
        let before = AppDelegate.shared.testNotifications.count
        manager.look()
        await pause(0.5)
        check(!manager.updating.contains("gemini") && AppDelegate.shared.testNotifications.count == before,
              "agents settings: a look within the day runs nothing")

        // One that fails: Homebrew's Goose, whose fake brew stops with an error. The note names it; Show Log opens the log.
        manager.setSchedule(.weekly, for: "goose")
        manager.look()
        _ = await wait(6) { manager.updating.contains("goose") }
        _ = await wait(15) { !manager.updating.contains("goose") }
        let failed = AppDelegate.shared.testNotifications.map(\.content).first { $0.title == "Couldn\u{2019}t update Goose" }
        check(failed?.body == "Error: block-goose-cli is busy (made up)" && failed?.categoryIdentifier == "agent-cli-update",
              "agents settings: a failed update says why, in one notification with Show Log",
              "\(failed?.title ?? "none"): \(failed?.body ?? "")")

        // list_agent_clis: read-only, the same rows.
        let answer: String = await withCheckedContinuation { done in
            MCPControl.call("list_agent_clis", [:], caller: nil) { result in done.resume(returning: result.text) }
        }
        let listed = ((try? JSONSerialization.jsonObject(with: Data(answer.utf8))) as? [String: Any])?["agents"] as? [[String: Any]] ?? []
        let goose = listed.first { $0["id"] as? String == "goose" }
        let gemini = listed.first { $0["id"] as? String == "gemini" }
        check(listed.count == 5 && goose?["installed_by"] as? String == "Homebrew" && gemini?["auto_update"] as? String == "daily"
              && gemini?["version"] as? String == "0.67.0",
              "agents settings: list_agent_clis lists them for agents", String(answer.prefix(400)))

        // One steady size, with Agents among eleven sections.
        let steady = window.frame
        var moved: [String] = []
        for section in SettingsWindowController.sections {
            settings.showTab(section.id)
            window.layoutIfNeeded()
            if window.frame != steady { moved.append(section.label) }
        }
        check(moved.isEmpty, "agents settings: every one of the eleven sections keeps the window's one size", moved.joined(separator: ", "))
        settings.showTab("agents")

        // No agent on PATH: one calm line and the way to the others.
        AgentCLIManager.pathForTest = ["\(root)/empty"]
        manager.reload(fetch: false)
        let emptied = await wait(5) { !manager.checking && pane.rows.isEmpty }
        check(emptied && !pane.emptyTitle.isHiddenOrHasHiddenAncestor, "agents settings: with no agent on PATH, the empty state shows")
        await screenshot(window, suffix: "-agents-settings-empty")
        window.close()
        // The manager's rows go back to none of the part's agents.
        AgentCLIManager.pathForTest = nil
        manager.setSchedule(.off, for: "gemini")
        manager.setSchedule(.off, for: "goose")
    }

    /// The made-up agents under `root`, laid out as their installers leave them, each a shell script.
    private static func makeFakeAgents(_ root: String) -> Bool {
        let manager = FileManager.default
        func program(_ relative: String, _ text: String = "#!/bin/sh\necho 1.0.0\n") throws {
            let path = root + "/" + relative
            try manager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        func file(_ relative: String, _ text: String) throws {
            let path = root + "/" + relative
            try manager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        func link(_ relative: String, _ target: String) throws {
            let path = root + "/" + relative
            try manager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try manager.createSymbolicLink(atPath: path, withDestinationPath: target)
        }
        do {
            try manager.createDirectory(atPath: root + "/empty", withIntermediateDirectories: true)
            // Claude Code's own install, and an npm copy after it on PATH.
            try program("share/claude/versions/2.1.280")
            try link("local-bin/claude", root + "/share/claude/versions/2.1.280")
            // Codex's standalone install.
            try program(".codex/packages/standalone/releases/0.167.0-aarch64-apple-darwin/bin/codex")
            try link("local-bin/codex", root + "/.codex/packages/standalone/releases/0.167.0-aarch64-apple-darwin/bin/codex")
            // Cursor's own install, by its legacy name.
            try program("share/cursor-agent/versions/2026.11.05-86047df/cursor-agent")
            try link("local-bin/cursor-agent", root + "/share/cursor-agent/versions/2026.11.05-86047df/cursor-agent")
            // npm: Gemini CLI 0.66.0 and Claude Code 2.1.211, with an npm that takes two seconds to move Gemini to 0.67.0.
            let gemini = root + "/node/lib/node_modules/@google/gemini-cli/package.json"
            try file("node/lib/node_modules/@google/gemini-cli/package.json", #"{"name": "@google/gemini-cli", "version": "0.66.0"}"#)
            try program("node/lib/node_modules/@google/gemini-cli/dist/index.js")
            try link("node/bin/gemini", "../lib/node_modules/@google/gemini-cli/dist/index.js")
            try file("node/lib/node_modules/@anthropic-ai/claude-code/package.json", #"{"version": "2.1.211"}"#)
            try program("node/lib/node_modules/@anthropic-ai/claude-code/cli.js")
            try link("node/bin/claude", "../lib/node_modules/@anthropic-ai/claude-code/cli.js")
            try program("node/bin/npm", """
                #!/bin/sh
                sleep 2
                /usr/bin/sed -i '' 's/0\\.66\\.0/0.67.0/' \(ShellQuote.quote(gemini))
                echo "added 1 package in 2s"
                """)
            // Homebrew's Goose, with a brew that fails.
            try program("brew/Cellar/block-goose-cli/1.56.0/bin/goose")
            try link("brew/bin/goose", "../Cellar/block-goose-cli/1.56.0/bin/goose")
            try program("brew/bin/brew", "#!/bin/sh\nsleep 1\necho 'Error: block-goose-cli is busy (made up)' >&2\nexit 1\n")
            return true
        } catch {
            return false
        }
    }
}
