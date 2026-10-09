import AppKit
import NextTermCore

/// The review of a skill folder that is also a Claude Code plugin, from a download built without the
/// network, on the self-test's own home folder. Nothing here starts Claude Code, Codex or any of the
/// plugin's parts: they are only read.
extension SelfTest {
    /// A download of `example-org/plugin` at one commit, built without the network: a skill folder that is
    /// also a Claude Code plugin with a server and hooks, and asks for MCP servers in Codex and Amp. The
    /// home facts (Claude Code's plugins, Codex's config) are read from the self-test's home, as a fetch
    /// reads them. `plain`: a plain skill, plain-notes, comes in the same download, after it. `extra`: files
    /// written over the plugin folder's own, by path in it, as a later commit would change them.
    static func pluginDownload(home: String, plain: Bool = false, extra: [String: String] = [:]) -> SkillsInstaller.Fetched {
        let manager = FileManager.default
        let scratch = SkillsInstaller.downloads.appendingPathComponent(UUID().uuidString)
        let top = scratch.appendingPathComponent("files/plugin-0123456").path
        let folder = top + "/skills/demo-plugin"
        func write(_ path: String, _ text: String) {
            let full = (folder as NSString).appendingPathComponent(path)
            try? manager.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? text.write(toFile: full, atomically: true, encoding: .utf8)
        }
        let skill = "---\nname: demo-plugin\ndescription: A skill that is also a plugin.\nlicense: MIT\n"
            + "mcpServers:\n  docs:\n    url: https://mcp.example.com/mcp\n  helper:\n    command: /usr/bin/true\n---\nUse it well.\n"
        write("SKILL.md", skill)
        write(".claude-plugin/plugin.json", #"{"name": "demo-plugin", "description": "A demo plugin."}"#)
        write(".mcp.json", #"{"mcpServers": {"demo": {"command": "/usr/bin/true"}}}"#)
        write("hooks/hooks.json", #"{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "/usr/bin/true"}]}]}}"#)
        write("agents/openai.yaml", "dependencies:\n  tools:\n    - type: \"mcp\"\n      value: \"docs\"\n      url: \"https://mcp.example.com/mcp\"\n")
        write("scripts/run.sh", "#!/bin/sh\necho hi\n")
        // Text and files that add MCP servers, or fetch server code outside the commit.
        write("setup.md", "Run `codex mcp add docs --url https://mcp.example.com/mcp`, or add this to ~/.codex/config.toml:\n\n"
              + "[mcp_servers.docs]\nurl = \"https://mcp.example.com/mcp\"\n\nA packed copy: https://example.com/releases/docs.mcpb\n")
        write("servers.json", #"{"mcpServers": {"remote": {"command": "npx", "args": ["-y", "mcp-remote@latest", "https://mcp.example.com/mcp"]}}}"#)
        write("docs.mcpb", "PK")
        for (path, text) in extra { write(path, text) }
        chmod(folder + "/scripts/run.sh", 0o755)
        var skills = [SkillsGitHub.Found(path: "skills/demo-plugin", tree: GitHash.folder(folder) ?? "")]
        if plain {
            let notes = top + "/skills/plain-notes"
            try? manager.createDirectory(atPath: notes, withIntermediateDirectories: true)
            try? "---\nname: plain-notes\ndescription: Keeps notes.\n---\nWrite them down.\n".write(toFile: notes + "/SKILL.md", atomically: true, encoding: .utf8)
            skills.append(SkillsGitHub.Found(path: "skills/plain-notes", tree: GitHash.folder(notes) ?? ""))
        }
        let source = SkillSource(owner: "example-org", repo: "plugin", path: "skills/demo-plugin")
        let resolved = SkillsGitHub.Resolved(source: source, commit: String(repeating: "0123456789", count: 4), date: nil, skills: skills, truncated: false)
        let candidates = SkillsInstaller.check(skills, top: top, repo: "plugin")
        let claude = SkillClaudeSettings.snapshot(home: home, keys: [SkillClaudeSettings.key("demo-plugin")])
        let inventory = SkillsStore.inventory()
        return SkillsInstaller.Fetched(resolved: resolved, info: nil, scratch: scratch, candidates: candidates,
                                       lockPath: SkillLock.path(home: home, environment: [:]), inventory: inventory,
                                       editedSinceInstall: [], projects: [], claude: claude, codex: SkillServers.codexConfig(home: home),
                                       installed: SkillsInstaller.installedPackages(candidates, inventory: inventory))
    }

    static func pluginReviewChecks(home: String) async {
        let fetched = pluginDownload(home: home)
        let candidates = fetched.candidates
        defer { fetched.discard() }

        let sheet = SkillsReviewSheet(fetched: fetched) { _ in }
        let row = sheet.tableView(NSTableView(), viewFor: nil, row: 0) as? NSButton
        let title = row?.title ?? "no row"
        let installable = candidates.first?.installable == true
        check(installable && title.hasSuffix("⚠︎"),
              "skills plugins: a skill folder that is also a Claude Code plugin with a server and hooks shows ⚠︎ in the list", title)
        let details = sheet.details.stringValue
        check(details.contains("Also a Claude Code plugin, “demo-plugin”") && details.contains("1 MCP server and 1 hook."),
              "skills plugins: Worth a look names the plugin and counts what it starts", details)
        check(details.contains("Claude Code starts its MCP servers and hooks by itself") && details.contains("Brings 1 file that can run (scripts or programs).")
              && !details.contains("only through its own tools"),
              "skills plugins: What it may do says Claude Code starts its parts by itself, not only the agent's tools", details)

        // The MCP servers each agent would use: read, never added or started.
        check(details.contains("Amp connects to the MCP servers it declares, and starts any program among them, when it finds the skill.")
              && !details.contains("Asks for MCP servers."),
              "skills plugins: What it may do says Amp connects to the skill's own servers when it finds the skill", details)
        check(details.contains("Declares an MCP server, “helper”, that runs a program. Amp starts it when it finds the skill."),
              "skills plugins: Worth a look warns about a skill-level server that runs a program", details)
        let servers = candidates.first?.review.servers
        let lines = servers?.lines(choice: .skip, start: .on, codex: .init(), trigger: "$demo-plugin") ?? []
        let claude: [String] = servers?.claude.map(\.name) ?? []
        let codex: [String] = servers?.codex.map(\.name) ?? []
        let amp: [String] = servers?.amp.map(\.name) ?? []
        let agents = lines.map(\.agent)
        let read = claude == ["demo"] && codex == ["docs"] && amp == ["docs", "helper"]
        check(read && agents == ["Claude Code", "Codex", "Amp"],
              "skills plugins: the review reads the servers Claude Code, Codex and Amp would use", "\(claude) \(codex) \(amp) \(agents)")
        pluginRowChecks(details)
        serverWarningChecks(details)
        bothKindsChecks(home: home)
        await pluginChoiceChecks(home: home)
        await pluginUpdateChecks(home: home)
        await installRefusalChecks(home: home)
        await settingsPluginChecks(home: home)
    }

    /// The review's rows: the plugin block with its lead line and what it would start, then "Needs MCP
    /// servers" with each agent's line, for the default (left out of Claude Code).
    static func pluginRowChecks(_ details: String) {
        let lines = details.components(separatedBy: "\n")
        let lead = "Also a Claude Code plugin, “demo-plugin” (.claude-plugin/plugin.json). If you add it to Claude Code, it starts the programs "
            + "below every time Claude Code opens, without asking you. Claude Code turns it on when it's added."
        let server = "• An MCP server, a program or web service that gives the agent tools, from .mcp.json: “demo” runs the program `/usr/bin/true`."
        let hook = "• A hook, a command that runs on Claude Code events, from hooks/hooks.json: SessionStart runs `/usr/bin/true`."
        let block = lines.contains(lead) && lines.contains("It would start:") && lines.contains(server) && lines.contains(hook)
        check(block, "skills plugins: the review leads with what the plugin starts, and lists each part with what it is", details)
        let claudeLine = "• Claude Code, from .mcp.json: “demo” runs the program `/usr/bin/true`. Left out of Claude Code, so these don't start there."
        let codexLine = "• Codex, from agents/openai.yaml: “docs” connects to https://mcp.example.com/mcp. If you name this skill with "
            + "`$demo-plugin:demo-plugin` in Codex itself (its CLI, IDE extension or app), Codex offers to add these to ~/.codex/config.toml."
        let table = lines.contains("    [mcp_servers.docs]") && lines.contains("    url = \"https://mcp.example.com/mcp\"")
        let amp = lines.contains { $0.hasPrefix("• Amp, from SKILL.md: “docs” connects to https://mcp.example.com/mcp; “helper” runs the program `/usr/bin/true`.") }
        let row = lines.contains("Needs MCP servers:") && lines.contains(claudeLine) && lines.contains { $0.hasPrefix(codexLine) }
        check(row && table && amp && lines.contains(SkillServers.closing),
              "skills plugins: Needs MCP servers gives Claude Code's, Codex's (with the table it would add) and Amp's line", details)
        check(!details.contains("the only choice is Claude Code's link"),
              "skills plugins: the review no longer says Claude Code's link is the only choice", details)
    }

    /// A plain skill and a plugin folder in one review: the checkbox and the popup each cover their own
    /// kind, and ticking a plugin folder that runs something sets the popup back to leaving it out.
    static func bothKindsChecks(home: String) {
        let fetched = pluginDownload(home: home, plain: true)
        defer { fetched.discard() }
        let sheet = SkillsReviewSheet(fetched: fetched) { _ in }
        // A click on a row's box, as the user ticks or unticks it.
        func click(_ row: Int) { (sheet.tableView(NSTableView(), viewFor: nil, row: row) as? NSButton)?.performClick(nil) }
        func pickAdd() {
            sheet.choice.popup.selectItem(at: 1)
            _ = sheet.choice.popup.sendAction(sheet.choice.popup.action, to: sheet.choice.popup.target)
        }
        let names = fetched.candidates.map(\.name)
        guard names == ["demo-plugin", "plain-notes"] else { return check(false, "skills plugins: the two-skill download is reviewed", "\(names)") }
        let leave = "Leave it out of Claude Code"
        let alone = !sheet.choice.view.isHidden && sheet.claudeLink.isHidden && sheet.choice.popup.titleOfSelectedItem == leave
        check(alone, "skills plugins: with nothing ticked, the selected plugin folder gets the popup on “Leave it out of Claude Code”",
              "\(String(describing: sheet.choice.popup.titleOfSelectedItem))")
        click(0)
        pickAdd()
        click(1)
        let both = !sheet.choice.view.isHidden && !sheet.claudeLink.isHidden && sheet.claudeLink.title == "Link the plain skill for Claude Code"
        let kept = sheet.choice.popup.titleOfSelectedItem == "Add it to Claude Code as a plugin"
        check(both && kept && sheet.installButton.title == "Install 2 Skills",
              "skills plugins: a plain skill and a plugin folder ticked together show the popup and the checkbox, which says it is for the plain skill",
              "\(sheet.installButton.title) \(sheet.claudeLink.title) \(String(describing: sheet.choice.popup.titleOfSelectedItem))")
        click(0)
        let plainOnly = sheet.choice.view.isHidden && !sheet.claudeLink.isHidden && sheet.claudeLink.title == SkillsReviewSheet.linkTitle
        click(0)
        check(plainOnly && sheet.choice.popup.titleOfSelectedItem == leave,
              "skills plugins: ticking a plugin folder that runs something sets the popup back to leaving it out",
              "\(String(describing: sheet.choice.popup.titleOfSelectedItem))")
    }

    /// Worth a look names each file that adds MCP servers or fetches server code outside the commit, and
    /// spares the files the review already lists as declaring servers.
    static func serverWarningChecks(_ details: String) {
        func warned(_ text: String, _ file: String) -> Bool { details.contains(text + " — " + file) }
        let settings = "Holds MCP server settings (mcpServers or [mcp_servers]). An agent may copy them into its own settings."
        let unpinned = "An MCP server runs a package without a pinned version (npx, bunx, pnpm dlx, yarn dlx or uvx). "
            + "MCP clients start it with no question, fetching whatever version npm or PyPI has then."
        let bundle = "An MCP bundle (.mcpb or .dxt): a packed server that Claude Code unpacks and runs. Its contents are not reviewed here."
        let adds = warned("Adds an MCP server to an agent's settings (… mcp add).", "setup.md")
        let link = warned("A link to an MCP bundle: a server fetched from the web, outside this commit.", "setup.md")
        check(adds && warned(settings, "setup.md") && link,
              "skills plugins: Worth a look warns about mcp add, [mcp_servers] and a link to an MCP bundle, with their file", details)
        check(warned(unpinned, "servers.json") && warned(settings, "servers.json"),
              "skills plugins: Worth a look warns about a server file that runs a package with no exact version", details)
        check(warned(bundle, "docs.mcpb") && !warned("An archive: its contents are not reviewed here.", "docs.mcpb"),
              "skills plugins: an MCP bundle in the folder is named as one, not as an archive", details)
        let listed = [".mcp.json", "SKILL.md", ".claude-plugin/plugin.json", "agents/openai.yaml"]
        check(!listed.contains { warned(settings, $0) },
              "skills plugins: the files the review lists as declaring servers get no second warning for them", details)
    }
}

extension SelfTest {
    /// Claude Code's link for a plugin folder: left out by default, added on request, and never a write to
    /// Claude Code's settings, in the self-test's home or the real one. The user's key set to false (as
    /// /plugin sets it) shows as "off". Only digests and modes of the real settings file are compared;
    /// nothing from it is printed or kept.
    static func pluginChoiceChecks(home: String) async {
        let manager = FileManager.default
        let settings = (home as NSString).appendingPathComponent(".claude/settings.json")
        let plugins = (home as NSString).appendingPathComponent(".claude/plugins")
        let shared = (home as NSString).appendingPathComponent(".agents/skills/demo-plugin")
        let link = (home as NSString).appendingPathComponent(".claude/skills/demo-plugin")
        let codexConfig = (home as NSString).appendingPathComponent(".codex/config.toml")
        defer {
            try? manager.removeItem(atPath: settings)
            try? manager.removeItem(atPath: plugins)
            try? manager.removeItem(atPath: codexConfig)
        }
        func writeSettings(_ text: String) {
            manager.createFile(atPath: settings, contents: Data(text.utf8))
            chmod(settings, 0o600)
        }
        let realSettings = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
        let realBefore = fileState(realSettings)
        writeSettings("{\n  \"model\": \"self-test\"\n}\n")
        let before = fileState(settings)

        // The default: a plugin folder that runs something is left out, and the checkbox (for plain
        // skills) is not offered for it.
        let first = pluginDownload(home: home)
        defer { first.discard() }
        guard let candidate = first.candidates.first else { return check(false, "skills plugins: the plugin download is reviewed") }
        let sheet = SkillsReviewSheet(fetched: first) { _ in }
        let details = sheet.details.stringValue
        check(SkillsInstaller.defaultClaudeLink(candidate, fetched: first) == .skip && sheet.claudeLink.isHidden
              && details.contains("Goes to ~/.agents/skills/demo-plugin. Agents that load it, if you use them: Codex, Command Code, \(otherReaders).")
              && !details.contains("through the Claude Code link"),
              "skills plugins: a plugin folder that runs something is left out of Claude Code by default, and every agent that loads it is named",
              details)
        let popup = sheet.choice.popup
        let leftOut = !sheet.choice.view.isHidden && popup.titleOfSelectedItem == "Leave it out of Claude Code"
            && popup.itemTitles == ["Leave it out of Claude Code", "Add it to Claude Code as a plugin"]
        let notLinked = sheet.choice.line.stringValue == "demo-plugin: left out of Claude Code, so nothing in it starts there. "
            + "Codex and the other agents still load its skill. If you use npx skills update, it may add it back."
        check(leftOut && sheet.installButton.title == "Install" && notLinked,
              "skills plugins: the popup offers leaving it out or adding it as a plugin, on “Leave it out”, and Install reads Install",
              "\(popup.itemTitles) \(sheet.installButton.title) \(sheet.choice.line.stringValue)")
        // Picking "Add it as a plugin" says what that starts beside the popup, and the review follows it.
        popup.selectItem(at: 1)
        _ = popup.sendAction(popup.action, to: popup.target)
        let added = sheet.details.stringValue
        let said = "⚠︎ demo-plugin: linked. It starts what its review lists every time Claude Code opens, without asking you: "
            + "1 MCP server and 1 hook."
        let follows = added.contains("it starts these every time Claude Code opens, without asking you, until you turn it off in Claude Code's /plugin.")
            && added.contains("Claude Code (through its link)")
        check(sheet.choice.line.stringValue == said && sheet.installButton.title == "Install" && follows,
              "skills plugins: “Add it to Claude Code as a plugin” says beside the popup what it starts, and Install still reads Install",
              sheet.choice.line.stringValue + "\n" + added)
        if case .failure(let failure) = await SkillsInstaller.install([candidate], fetched: first) {
            check(false, "skills plugins: Install with the default applies", failure.message)
        }
        let manifest = (shared as NSString).appendingPathComponent(".claude-plugin/plugin.json")
        check(manager.fileExists(atPath: manifest) && !entryExists(link) && fileState(settings) == before,
              "skills plugins: Install leaves it out: no link, its .claude-plugin kept, and Claude Code's settings untouched")
        if case .failure(let failure) = await SkillsStore.undo() { check(false, "skills plugins: Undo of the install applies", failure.message) }

        // Added as a plugin from the review: the link, and still no settings write.
        let second = pluginDownload(home: home)
        defer { second.discard() }
        var answered: [String]?? = .none
        let addSheet = SkillsReviewSheet(fetched: second) { names in answered = .some(names) }
        addSheet.choice.popup.selectItem(at: 1)
        _ = addSheet.choice.popup.sendAction(addSheet.choice.popup.action, to: addSheet.choice.popup.target)
        addSheet.installButton.performClick(nil)
        _ = await wait(10) { answered != nil }
        check(answered == .some(["demo-plugin"]), "skills plugins: Install from the review, with “Add it to Claude Code as a plugin” picked, applies",
              "\(String(describing: answered))")
        check(entryExists(link) && manager.fileExists(atPath: manifest) && fileState(settings) == before && before?.hasSuffix(" 600") == true,
              "skills plugins: Add it as a plugin links it, and leaves Claude Code's settings byte for byte, mode 0600", fileState(settings) ?? "none")
        let linkedReview = pluginDownload(home: home)
        defer { linkedReview.discard() }
        let linkedSheet = SkillsReviewSheet(fetched: linkedReview) { _ in }
        let linkedDetails = linkedSheet.details.stringValue
        check(linkedDetails.contains("Agents that load it, if you use them: Codex, Command Code, Claude Code (through its link), \(otherReaders). "
                                     + "Amp, Cursor, opencode and goose also find it through the Claude Code link."),
              "skills plugins: an update that keeps the link names Claude Code and the agents that find it through the link", linkedDetails)
        // AE6: the same parts as the installed copy keep the link by default; leaving it out would remove it.
        // The line beside the popup opens with ⚠︎, since the plugin it keeps linked starts programs (R6).
        let linkedPopup = linkedSheet.choice.popup
        let keeps = linkedPopup.itemTitles == ["Remove it from Claude Code", "Add it to Claude Code as a plugin"] && linkedPopup.indexOfSelectedItem == 1
        let staysLinked = "⚠︎ demo-plugin: stays linked. It starts what its review lists every time Claude Code opens, without asking you: "
            + "1 MCP server and 1 hook."
        check(keeps && linkedSheet.choice.line.stringValue == staysLinked,
              "skills plugins: an update with the same parts keeps its link, and the popup offers to remove it",
              "\(linkedPopup.itemTitles) \(linkedPopup.indexOfSelectedItem) \(linkedSheet.choice.line.stringValue)")

        // Removal names what may stay, and changes no other app's file: a Codex server with the skill's
        // address (as Codex would have added it), the plugin's parts and Amp's servers in open sessions.
        try? manager.createDirectory(atPath: (codexConfig as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        manager.createFile(atPath: codexConfig, contents: Data("[mcp_servers.docs]\nurl = \"https://mcp.example.com/mcp\"\n".utf8))
        let configBefore = fileState(codexConfig)
        await pluginLeftoverChecks(keyOff: false)
        check(fileState(codexConfig) == configBefore && fileState(settings) == before,
              "skills plugins: working out what removal leaves changes neither Codex's config nor Claude Code's settings")

        // The user turns it off in /plugin, which sets its key to false: Settings › Skills and list_skills
        // say "off", and the review offers the link, since Claude Code then loads nothing from it.
        writeSettings("{\n  \"enabledPlugins\": {\n    \"demo-plugin@skills-dir\": false\n  },\n  \"model\": \"self-test\"\n}\n")
        let keyed = fileState(settings)
        let row = SkillsStore.inventory().rows.first { $0.name == "demo-plugin" }
        let (cell, tip) = row.map { SkillsSettingsView.cellText($0, agent: .claudeCode) } ?? ("none", nil)
        let listed = await SkillsMCP.listSkills()
        let items = listed["skills"] as? [[String: Any]] ?? []
        let agents = items.first { $0["name"] as? String == "demo-plugin" }?["agents"] as? [String: String]
        let offTip = "Claude Code's settings turn its plugin off (“demo-plugin@skills-dir”: false), so Claude Code loads nothing from it."
        check(cell == "off" && tip == offTip && agents?["claude-code"] == "off",
              "skills plugins: a plugin the user turned off in /plugin shows Claude Code as off, and the tooltip names its key",
              "\(cell) \(tip ?? "no tooltip") \(String(describing: agents))")
        let third = pluginDownload(home: home)
        defer { third.discard() }
        if let again = third.candidates.first {
            check(SkillsInstaller.defaultClaudeLink(again, fetched: third) == .link,
                  "skills plugins: with its key false, the review offers the link (Claude Code loads nothing from it)")
        }
        let offDetails = SkillsReviewSheet(fetched: third) { _ in }.details.stringValue
        check(offDetails.contains("Agents that load it, if you use them: Codex, Command Code, \(otherReaders). Claude Code loads nothing from it while its plugin is off."),
              "skills plugins: with its key false, the review leaves Claude Code out of the agents that load it", offDetails)
        await pluginLeftoverChecks(keyOff: true)
        check(fileState(settings) == keyed, "skills plugins: working out what removal leaves keeps the user's key as it is")

        // Undo takes the link and the skill away, and leaves the settings as the user left them.
        if case .failure(let failure) = await SkillsStore.undo() { check(false, "skills plugins: Undo of the plugin install applies", failure.message) }
        check(!entryExists(link) && !entryExists(shared) && fileState(settings) == keyed,
              "skills plugins: Undo removes the link and the skill, and Claude Code's settings stay byte for byte")

        // A plugin synced from claude.ai with the same name: the review warns, and leaves it out.
        let synced = (plugins as NSString).appendingPathComponent("synced/user/demo-plugin/.claude-plugin")
        try? manager.createDirectory(atPath: synced, withIntermediateDirectories: true)
        manager.createFile(atPath: synced + "/plugin.json", contents: Data(#"{"name": "demo-plugin"}"#.utf8))
        writeSettings("{\n  \"model\": \"self-test\"\n}\n")
        let fourth = pluginDownload(home: home)
        defer { fourth.discard() }
        let clashSheet = SkillsReviewSheet(fetched: fourth) { _ in }
        let clashText = "You have a plugin named “demo-plugin” from claude.ai. Added, this folder replaces it in Claude Code sessions"
        let shown = clashSheet.details.stringValue
        let fallsBack = fourth.candidates.first.map { SkillsInstaller.defaultClaudeLink($0, fetched: fourth) } == .skip
        check(shown.contains(clashText) && fallsBack,
              "skills plugins: a plugin synced from claude.ai with the same name is named, and the folder is left out", shown)

        check(fileState(realSettings) == realBefore, "skills plugins: the real ~/.claude/settings.json keeps its bytes and mode")
    }

    /// The agents besides Codex, Command Code and Claude Code that read ~/.agents/skills, as the review
    /// names them.
    static let otherReaders = "Gemini CLI, Qwen Code, Cursor, opencode, Copilot CLI, Amp, Junie and goose"

    /// What removing the installed, linked demo-plugin says may stay. `keyOff`: the self-test home's
    /// settings hold "demo-plugin@skills-dir": false, so its plugin never started.
    static func pluginLeftoverChecks(keyOff: Bool) async {
        let (steps, leftovers, installed) = await SkillsInstaller.removal("demo-plugin")
        let said = leftovers.joined(separator: "\n")
        let parts = "This includes its Claude Code plugin's MCP servers and hooks, and the MCP servers Amp started for it."
        let amp = "This includes the MCP servers Amp started for it."
        let codex = "Codex may have added the MCP server “docs” (https://mcp.example.com/mcp) for this skill, in ~/.codex/config.toml. "
            + "It stays there, because you may use it for other things. Remove it there if you don't."
        let key = "~/.claude/settings.json keeps “demo-plugin@skills-dir”: false. It stays, and keeps any later folder with that plugin name "
            + "turned off in Claude Code."
        let named = installed && !steps.isEmpty && leftovers.contains(codex) && !leftovers.contains { $0.contains("until they restart") }
            && !leftovers.contains("It asked for MCP servers: check your agents' MCP settings.")
        if keyOff {
            check(named && leftovers.first == amp && leftovers.contains(key) && !leftovers.contains(parts),
                  "skills plugins: removing a plugin the user turned off names the key that stays, and no parts that ran", said)
        } else {
            check(named && leftovers.first == parts && !leftovers.contains(key),
                  "skills plugins: removing a linked plugin names its parts, Amp's servers and the Codex server that may stay, once each", said)
        }
    }

    /// AE6: an update of the linked demo-plugin whose new commit declares another MCP server. The review's
    /// default takes Claude Code's link away and says so beside the popup; Install puts the update in place
    /// without the link, and Undo puts the link and the old copy back. Claude Code's settings in the
    /// self-test's home keep their bytes and mode throughout. (Undo keeps one change, so this runs on an
    /// install of its own, after pluginChoiceChecks.)
    static func pluginUpdateChecks(home: String) async {
        let manager = FileManager.default
        let settings = (home as NSString).appendingPathComponent(".claude/settings.json")
        let link = (home as NSString).appendingPathComponent(".claude/skills/demo-plugin")
        let servers = (home as NSString).appendingPathComponent(".agents/skills/demo-plugin/.mcp.json")
        defer { try? manager.removeItem(atPath: settings) }
        manager.createFile(atPath: settings, contents: Data("{\n  \"model\": \"self-test\"\n}\n".utf8))
        chmod(settings, 0o600)
        let before = fileState(settings)
        func declaresSecond() -> Bool? { (try? String(contentsOfFile: servers, encoding: .utf8)).map { $0.contains("second") } }

        let first = pluginDownload(home: home)
        defer { first.discard() }
        guard let candidate = first.candidates.first else { return check(false, "skills plugins: the plugin download is reviewed, for its update") }
        if case .failure(let failure) = await SkillsInstaller.install([candidate], fetched: first, claude: ["demo-plugin": .link]) {
            return check(false, "skills plugins: adding the plugin to Claude Code, before its update, applies", failure.message)
        }
        let more = #"{"mcpServers": {"demo": {"command": "/usr/bin/true"}, "second": {"command": "/usr/bin/true"}}}"#
        let update = pluginDownload(home: home, extra: [".mcp.json": more])
        defer { update.discard() }
        var answered: [String]?? = .none
        let sheet = SkillsReviewSheet(fetched: update) { names in answered = .some(names) }
        let popup = sheet.choice.popup
        let offered = popup.itemTitles == ["Remove it from Claude Code", "Add it to Claude Code as a plugin"] && popup.indexOfSelectedItem == 0
        let said = "demo-plugin: its link is removed, so nothing in it starts in Claude Code. Codex and the other agents still load its skill. "
            + "If you use npx skills update, it may add it back."
        check(offered && sheet.choice.line.stringValue == said && sheet.installButton.title == "Update",
              "skills plugins: an update that declares another server takes Claude Code's link away by default, and says so beside the popup",
              "\(popup.itemTitles) \(popup.indexOfSelectedItem) \(sheet.choice.line.stringValue) \(sheet.installButton.title)")
        sheet.installButton.performClick(nil)
        _ = await wait(10) { answered != nil }
        check(answered == .some(["demo-plugin"]) && declaresSecond() == true && !entryExists(link) && fileState(settings) == before,
              "skills plugins: the update, with the default, goes in place without Claude Code's link, and writes no settings",
              "\(String(describing: answered))")
        if case .failure(let failure) = await SkillsStore.undo() { check(false, "skills plugins: Undo of the update applies", failure.message) }
        check(entryExists(link) && declaresSecond() == false && fileState(settings) == before,
              "skills plugins: Undo of the update puts Claude Code's link and the old copy back, and the settings stay byte for byte")

        // The skill goes as Settings › Skills' Remove takes it, before the checks after these.
        let (steps, _, _) = await SkillsInstaller.removal("demo-plugin")
        if case .failure(let failure) = await SkillsStore.apply(steps, title: "Remove demo-plugin") {
            check(false, "skills plugins: removing the plugin folder after its update applies", failure.message)
        }
    }
}

extension SelfTest {
    /// Install reads Claude Code's plugins again before it writes anything (KTD1). A plugin of the same name
    /// synced from claude.ai after the review, with "Add it to Claude Code as a plugin" picked: Install
    /// refuses and says why, the review is drawn again from the disk as it is now (the synced plugin named,
    /// the popup back on leaving it out), and nothing is installed or linked.
    static func installRefusalChecks(home: String) async {
        let manager = FileManager.default
        let plugins = (home as NSString).appendingPathComponent(".claude/plugins")
        let synced = (plugins as NSString).appendingPathComponent("synced/user/demo-plugin/.claude-plugin")
        let link = (home as NSString).appendingPathComponent(".claude/skills/demo-plugin")
        let shared = (home as NSString).appendingPathComponent(".agents/skills/demo-plugin")
        defer { try? manager.removeItem(atPath: plugins) }
        let fetched = pluginDownload(home: home)
        defer { fetched.discard() }
        var answered: [String]?? = .none
        let sheet = SkillsReviewSheet(fetched: fetched) { names in answered = .some(names) }
        guard let window = sheet.window else { return check(false, "skills plugins: the review has a window, for the refused install") }
        window.orderFront(nil)
        defer {
            if let alert = window.attachedSheet { window.endSheet(alert) }
            window.orderOut(nil)
        }
        let popup = sheet.choice.popup
        popup.selectItem(at: 1)
        _ = popup.sendAction(popup.action, to: popup.target)
        // Synced after the review was read, as claude.ai would sync it.
        try? manager.createDirectory(atPath: synced, withIntermediateDirectories: true)
        manager.createFile(atPath: synced + "/plugin.json", contents: Data(#"{"name": "demo-plugin"}"#.utf8))
        sheet.installButton.performClick(nil)
        let told = await wait(10) { window.attachedSheet != nil }
        let words = pluginSheetText(window)
        check(told && answered == nil && words.contains("Your Claude Code plugins changed since the review (demo-plugin). Nothing was installed"),
              "skills plugins: Install refuses when a plugin of the same name was synced from claude.ai after the review", words)
        let details = sheet.details.stringValue
        check(details.contains("You have a plugin named “demo-plugin” from claude.ai.") && popup.titleOfSelectedItem == "Leave it out of Claude Code",
              "skills plugins: after the refusal the review names the synced plugin, and the popup is back on leaving it out",
              "\(String(describing: popup.titleOfSelectedItem))\n" + details)
        check(!entryExists(link) && !entryExists(shared), "skills plugins: the refused install puts nothing in place and links nothing")
    }

    /// Settings › Skills for a skill folder that is also a Claude Code plugin, installed with the review's
    /// default (left out of Claude Code): Link asks first and links only on "Add with Its Programs"; Unify,
    /// keeping it over a hand-made copy in ~/.claude/skills, asks with the same popup (AE14). Neither writes
    /// Claude Code's settings, in the self-test's home or the real one. Only digests and modes of the real
    /// settings file are compared; nothing from it is printed or kept.
    static func settingsPluginChecks(home: String) async {
        let manager = FileManager.default
        let settings = (home as NSString).appendingPathComponent(".claude/settings.json")
        let link = (home as NSString).appendingPathComponent(".claude/skills/demo-plugin")
        defer { try? manager.removeItem(atPath: settings) }
        manager.createFile(atPath: settings, contents: Data("{\n  \"model\": \"self-test\"\n}\n".utf8))
        chmod(settings, 0o600)
        let before = fileState(settings)
        let realSettings = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
        let realBefore = fileState(realSettings)
        let readers = "Amp, Cursor, opencode and goose also read ~/.claude/skills."
        check(SkillsSettingsView.introText.hasSuffix(readers) && SkillsSettingsView.introTip.contains("Junie and goose"),
              "skills plugins: Settings › Skills' intro names the agents that read ~/.claude/skills, and its tooltip every reader of the shared one",
              SkillsSettingsView.introText)

        let fetched = pluginDownload(home: home)
        defer { fetched.discard() }
        guard let candidate = fetched.candidates.first else { return check(false, "skills plugins: the plugin download is reviewed, for Settings › Skills") }
        if case .failure(let failure) = await SkillsInstaller.install([candidate], fetched: fetched) {
            return check(false, "skills plugins: Install with the default applies, for Settings › Skills", failure.message)
        }
        await settingsLinkChecks(link: link)
        await unifyPluginChecks(home: home, link: link)

        // The skill goes as Settings › Skills' Remove takes it.
        let (steps, _, _) = await SkillsInstaller.removal("demo-plugin")
        if case .failure(let failure) = await SkillsStore.apply(steps, title: "Remove demo-plugin") {
            check(false, "skills plugins: removing the plugin folder after the Settings checks applies", failure.message)
        }
        check(fileState(settings) == before && before?.hasSuffix(" 600") == true && !entryExists(link),
              "skills plugins: Settings › Skills' Link, Unify and their Undo leave Claude Code's settings byte for byte, mode 0600",
              fileState(settings) ?? "none")
        check(fileState(realSettings) == realBefore, "skills plugins: the real ~/.claude/settings.json keeps its bytes and mode through the Settings checks")
    }

    /// Link on the installed plugin folder: a question first, with what it starts, "Add with Its Programs"
    /// and Cancel (on Return). Cancel links nothing; Add links it, as one change that Undo takes back.
    static func settingsLinkChecks(link: String) async {
        let view = SkillsSettingsView(frame: NSRect(x: 0, y: 0, width: 620, height: 480))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
            window.orderOut(nil)
            window.contentView = NSView()
        }
        await pause(0.5) // its first read of the folders
        view.selectForTest("demo-plugin", in: SkillsStore.inventory())
        guard await wait(5, { view.linkButton.isEnabled }) else {
            return check(false, "skills plugins: Settings › Skills offers Link for a plugin folder left out of Claude Code")
        }
        view.linkButton.performClick(nil)
        let asked = await wait(5) { window.attachedSheet != nil }
        let words = pluginSheetText(window)
        let buttons = pluginSheetButtons(window)
        let cancel = buttons.first { $0.title == "Cancel" }
        let titles = Set(buttons.map(\.title))
        let lead = "If you add it to Claude Code, it starts the programs below every time Claude Code opens, without asking you."
        let said = words.contains("Add “demo-plugin” to Claude Code?") && words.contains(lead) && words.contains("It would start:")
        check(asked && said && titles.isSuperset(of: ["Add with Its Programs", "Cancel"]) && cancel?.keyEquivalent == "\r",
              "skills plugins: Settings › Skills' Link asks first about a plugin folder that starts programs, with what it starts, and Return cancels",
              words + " | " + titles.sorted().joined(separator: ", "))
        cancel?.performClick(nil)
        _ = await wait(5) { window.attachedSheet == nil && view.linkButton.isEnabled }
        check(!entryExists(link), "skills plugins: Cancel on Link's question links nothing")

        // The folder gains a part between the question and the answer: Link reads it again and links nothing.
        let lsp = (SkillsStore.home as NSString).appendingPathComponent(".agents/skills/demo-plugin/.lsp.json")
        view.linkButton.performClick(nil)
        _ = await wait(5) { window.attachedSheet != nil }
        FileManager.default.createFile(atPath: lsp, contents: Data(#"{"go": {"command": "gopls"}}"#.utf8))
        pluginSheetButtons(window).first { $0.title == "Add with Its Programs" }?.performClick(nil)
        let changed = "“demo-plugin” changed since you looked. Look again before linking it."
        let refused = await wait(10) { pluginSheetText(window).contains(changed) }
        check(refused && !entryExists(link), "skills plugins: a plugin folder that changed after Link's question is not linked, and Link says why",
              pluginSheetText(window))
        if let alert = window.attachedSheet { window.endSheet(alert) }
        try? FileManager.default.removeItem(atPath: lsp)
        _ = await wait(5) { window.attachedSheet == nil && view.linkButton.isEnabled }

        view.linkButton.performClick(nil)
        _ = await wait(5) { window.attachedSheet != nil }
        pluginSheetButtons(window).first { $0.title == "Add with Its Programs" }?.performClick(nil)
        let linked = await wait(10) { entryExists(link) && SkillsStore.running == 0 }
        check(linked && SkillsStore.lastChange?.title == "Link demo-plugin for Claude Code",
              "skills plugins: “Add with Its Programs” links it, as one change for Undo", SkillsStore.lastChange?.title ?? "none")
        if case .failure(let failure) = await SkillsStore.undo() { check(false, "skills plugins: Undo of Link applies", failure.message) }
        check(!entryExists(link), "skills plugins: Undo of Link removes the link")
    }

    /// AE14: a hand-made demo-plugin in ~/.claude/skills, without .claude-plugin, and the installed plugin
    /// folder in ~/.agents/skills. Unify keeping the hand-made copy asks nothing; keeping the plugin folder
    /// shows the plugin block and Claude Code's popup on "Leave it out", says Claude Code loses the skill, and
    /// follows the popup.
    static func unifyPluginChecks(home: String, link: String) async {
        let manager = FileManager.default
        try? manager.createDirectory(atPath: link, withIntermediateDirectories: true)
        try? "---\nname: demo-plugin\ndescription: Mine.\n---\nhand-made\n".write(toFile: link + "/SKILL.md", atomically: true, encoding: .utf8)
        defer { try? manager.removeItem(atPath: link) }
        let inventory = SkillsStore.inventory()
        guard let row = inventory.rows.first(where: { $0.name == "demo-plugin" }),
              let shared = row.copies.first(where: { $0.root.kind == .shared }),
              let mine = row.copies.first(where: { $0.root.kind == .claude }) else {
            return check(false, "skills plugins: Unify finds the plugin folder and the hand-made copy")
        }
        let sheet = SkillsUnifySheet(row: row, inventory: inventory, plugins: SkillInstall.pluginFacts(row.distinctCopies, home: home))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
            window.orderOut(nil)
        }
        var answered: SkillsUnifySheet.Confirmed?? = .none
        sheet.begin(over: window) { answered = .some($0) }
        _ = await wait(5) { window.attachedSheet != nil }
        sheet.keepForTest(mine)
        let plainKept = sheet.claude.view.isHidden && sheet.stepsText.stringValue.contains("• Link ")
        sheet.keepForTest(shared)
        let popup = sheet.claude.choice.popup
        let block = sheet.claude.block
        let steps = sheet.stepsText.stringValue
        let asks = !sheet.claude.view.isHidden && popup.titleOfSelectedItem == "Leave it out of Claude Code"
            && block.hasPrefix("Also a Claude Code plugin, “demo-plugin”") && block.contains("It would start:")
        check(plainKept && asks && steps.contains(SkillReviewText.unifyLeftOut) && !steps.contains("• Link "),
              "skills plugins: Unify keeping a plugin folder shows its block and Claude Code's popup on “Leave it out”, and says Claude Code loses the skill",
              block + "\n" + steps)
        popup.selectItem(at: 1)
        _ = popup.sendAction(popup.action, to: popup.target)
        let added = sheet.stepsText.stringValue
        check(added.contains("• Link ") && !added.contains(SkillReviewText.unifyLeftOut),
              "skills plugins: “Add it to Claude Code as a plugin” in Unify links it", added)
        popup.selectItem(at: 0)
        _ = popup.sendAction(popup.action, to: popup.target)
        pluginSheetButtons(window).first { $0.title == "Unify" }?.performClick(nil)
        _ = await wait(5) { answered != nil }
        guard case .some(.some(let confirmed)) = answered else { return check(false, "skills plugins: Unify with the plugin left out is confirmed") }
        let makesLink = confirmed.steps.contains { if case .link = $0 { return true }; return false }
        check(confirmed.steps.contains(.trash(link)) && !makesLink && confirmed.precheck() == nil,
              "skills plugins: Unify follows the popup: Claude Code's copy goes, and no link is made", "\(confirmed.steps)")
        // The kept copy gains a part after the question: Unify's check, in the change's own turn, refuses.
        let lsp = shared.path + "/.lsp.json"
        manager.createFile(atPath: lsp, contents: Data(#"{"go": {"command": "gopls"}}"#.utf8))
        let refused = confirmed.precheck()
        try? manager.removeItem(atPath: lsp)
        check(refused == "“demo-plugin” changed since you looked. Look again before unifying it." && confirmed.precheck() == nil,
              "skills plugins: Unify's check refuses a kept plugin folder that changed after the question", refused ?? "no refusal")
        let applied = await SkillsStore.apply(confirmed.steps, title: "Unify demo-plugin", precheck: confirmed.precheck)
        if case .failure(let failure) = applied { check(false, "skills plugins: Unify with the plugin left out applies", failure.message) }
        check(!entryExists(link) && manager.fileExists(atPath: shared.path + "/.claude-plugin/plugin.json"),
              "skills plugins: after Unify, Claude Code has no copy and the plugin folder is kept whole")
        if case .failure(let failure) = await SkillsStore.undo() { check(false, "skills plugins: Undo of Unify applies", failure.message) }
        let back = (try? String(contentsOfFile: link + "/SKILL.md", encoding: .utf8))?.contains("hand-made") == true
        check(back, "skills plugins: Undo of Unify puts the hand-made copy back")
    }

    /// A file's digest and mode, or nil when it is not there.
    static func fileState(_ path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return (SkillHash.fileDigest(path) ?? "unreadable") + " " + String(UInt32(info.st_mode & 0o777), radix: 8)
    }

    /// Something is at `path`: a file, a folder, or a link (even to nothing).
    static func entryExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// The words in the sheet over `window`: an alert's title and text, and the list under them.
    private static func pluginSheetText(_ window: NSWindow) -> String {
        func texts(_ view: NSView) -> [String] {
            view.subviews.flatMap { sub -> [String] in
                if let field = sub as? NSTextField { return [field.stringValue] }
                if let text = sub as? NSTextView { return [text.string] }
                return texts(sub)
            }
        }
        return window.attachedSheet?.contentView.map(texts)?.joined(separator: "\n") ?? ""
    }

    /// The buttons in the sheet over `window`.
    private static func pluginSheetButtons(_ window: NSWindow) -> [NSButton] {
        func buttons(_ view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
        return window.attachedSheet?.contentView.map(buttons) ?? []
    }
}
