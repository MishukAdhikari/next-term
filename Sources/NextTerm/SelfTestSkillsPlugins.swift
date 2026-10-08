import AppKit
import NextTermCore

/// The review of a skill folder that is also a Claude Code plugin, from a download built without the
/// network, on the self-test's own home folder. Nothing here starts Claude Code, Codex or any of the
/// plugin's parts: they are only read.
extension SelfTest {
    /// A download of `example-org/plugin` at one commit, built without the network: a skill folder that is
    /// also a Claude Code plugin with a server and hooks, and asks for MCP servers in Codex and Amp. The
    /// home facts (Claude Code's plugins, Codex's config) are read from the self-test's home, as a fetch
    /// reads them. `plain`: a plain skill, plain-notes, comes in the same download, after it.
    static func pluginDownload(home: String, plain: Bool = false) -> SkillsInstaller.Fetched {
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
        return SkillsInstaller.Fetched(resolved: resolved, info: nil, scratch: scratch, candidates: candidates,
                                       lockPath: SkillLock.path(home: home, environment: [:]), inventory: SkillsStore.inventory(),
                                       editedSinceInstall: [], projects: [], claude: claude, codex: SkillServers.codexConfig(home: home))
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
    }

    /// The review's rows: the plugin block with its lead line and what it would start, then "Needs MCP
    /// servers" with each agent's line, for the default (left out of Claude Code).
    static func pluginRowChecks(_ details: String) {
        let lines = details.components(separatedBy: "\n")
        let lead = "Also a Claude Code plugin, “demo-plugin” (.claude-plugin/plugin.json). If you add it to Claude Code, it starts the programs "
            + "below every time Claude Code opens, without asking you. It starts on."
        let server = "• An MCP server, a program or web service that gives the agent tools, from .mcp.json: “demo” runs the program `/usr/bin/true`."
        let hook = "• A hook, a command that runs on Claude Code events, from hooks/hooks.json: SessionStart runs `/usr/bin/true`."
        let block = lines.contains(lead) && lines.contains("It would start:") && lines.contains(server) && lines.contains(hook)
        check(block, "skills plugins: the review leads with what the plugin starts, and lists each part with what it is", details)
        let claudeLine = "• Claude Code, from .mcp.json: “demo” runs the program `/usr/bin/true`. Left out of Claude Code, so these don't start there."
        let codexLine = "• Codex, from agents/openai.yaml: “docs” connects to https://mcp.example.com/mcp. If you name this skill with "
            + "`$demo-plugin:demo-plugin` in Codex's own apps, Codex offers to add these to ~/.codex/config.toml."
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
        let both = !sheet.choice.view.isHidden && !sheet.claudeLink.isHidden
        let kept = sheet.choice.popup.titleOfSelectedItem == "Add it to Claude Code as a plugin"
        check(both && kept && sheet.installButton.title == "Install 2 Skills",
              "skills plugins: a plain skill and a plugin folder ticked together show the checkbox and the popup",
              "\(sheet.installButton.title) \(String(describing: sheet.choice.popup.titleOfSelectedItem))")
        click(0)
        let plainOnly = sheet.choice.view.isHidden && !sheet.claudeLink.isHidden
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
        func state(_ path: String) -> String? {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            return (SkillHash.fileDigest(path) ?? "unreadable") + " " + String(UInt32(info.st_mode & 0o777), radix: 8)
        }
        func exists(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0
        }
        func writeSettings(_ text: String) {
            manager.createFile(atPath: settings, contents: Data(text.utf8))
            chmod(settings, 0o600)
        }
        let realSettings = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
        let realBefore = state(realSettings)
        writeSettings("{\n  \"model\": \"self-test\"\n}\n")
        let before = state(settings)

        // The default: a plugin folder that runs something is left out, and the checkbox (for plain
        // skills) is not offered for it.
        let first = pluginDownload(home: home)
        defer { first.discard() }
        guard let candidate = first.candidates.first else { return check(false, "skills plugins: the plugin download is reviewed") }
        let sheet = SkillsReviewSheet(fetched: first) { _ in }
        let details = sheet.details.stringValue
        check(SkillsInstaller.defaultClaudeLink(candidate, fetched: first) == .skip && sheet.claudeLink.isHidden
              && details.contains("Goes to ~/.agents/skills/demo-plugin. Agents that load it: Codex, Command Code, \(otherReaders).")
              && !details.contains("through the Claude Code link"),
              "skills plugins: a plugin folder that runs something is left out of Claude Code by default, and every agent that loads it is named",
              details)
        let popup = sheet.choice.popup
        let leftOut = !sheet.choice.view.isHidden && popup.titleOfSelectedItem == "Leave it out of Claude Code"
            && popup.itemTitles == ["Leave it out of Claude Code", "Add it to Claude Code as a plugin"]
        let notLinked = sheet.choice.line.stringValue == "demo-plugin: not linked. npx skills update may link it again."
        check(leftOut && sheet.installButton.title == "Install" && notLinked,
              "skills plugins: the popup offers leaving it out or adding it as a plugin, on “Leave it out”, and Install reads Install",
              "\(popup.itemTitles) \(sheet.installButton.title) \(sheet.choice.line.stringValue)")
        // Picking "Add it as a plugin" says what that starts beside the popup, and the review follows it.
        popup.selectItem(at: 1)
        _ = popup.sendAction(popup.action, to: popup.target)
        let added = sheet.details.stringValue
        let said = "demo-plugin: linked. It starts the programs below every time Claude Code opens, without asking you."
        let follows = added.contains("it starts these every time Claude Code opens, without asking you, while “demo-plugin@skills-dir” is on.")
            && added.contains("Claude Code (through its link)")
        check(sheet.choice.line.stringValue == said && sheet.installButton.title == "Install" && follows,
              "skills plugins: “Add it to Claude Code as a plugin” says beside the popup what it starts, and Install still reads Install",
              sheet.choice.line.stringValue + "\n" + added)
        if case .failure(let failure) = await SkillsInstaller.install([candidate], fetched: first) {
            check(false, "skills plugins: Install with the default applies", failure.message)
        }
        let manifest = (shared as NSString).appendingPathComponent(".claude-plugin/plugin.json")
        check(manager.fileExists(atPath: manifest) && !exists(link) && state(settings) == before,
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
        check(exists(link) && manager.fileExists(atPath: manifest) && state(settings) == before && before?.hasSuffix(" 600") == true,
              "skills plugins: Add it as a plugin links it, and leaves Claude Code's settings byte for byte, mode 0600", state(settings) ?? "none")
        let linkedReview = pluginDownload(home: home)
        defer { linkedReview.discard() }
        let linkedSheet = SkillsReviewSheet(fetched: linkedReview) { _ in }
        let linkedDetails = linkedSheet.details.stringValue
        check(linkedDetails.contains("Agents that load it: Codex, Command Code, Claude Code (through its link), \(otherReaders). "
                                     + "Amp, Cursor, opencode and goose also find it through the Claude Code link."),
              "skills plugins: an update that keeps the link names Claude Code and the agents that find it through the link", linkedDetails)
        // AE6: the same parts as the installed copy keep the link by default; leaving it out would remove it.
        let linkedPopup = linkedSheet.choice.popup
        let keeps = linkedPopup.itemTitles == ["Remove it from Claude Code", "Add it to Claude Code as a plugin"] && linkedPopup.indexOfSelectedItem == 1
        check(keeps && linkedSheet.choice.line.stringValue.hasPrefix("demo-plugin: stays linked."),
              "skills plugins: an update with the same parts keeps its link, and the popup offers to remove it",
              "\(linkedPopup.itemTitles) \(linkedSheet.choice.line.stringValue)")

        // Removal names what may stay, and changes no other app's file: a Codex server with the skill's
        // address (as Codex would have added it), the plugin's parts and Amp's servers in open sessions.
        try? manager.createDirectory(atPath: (codexConfig as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        manager.createFile(atPath: codexConfig, contents: Data("[mcp_servers.docs]\nurl = \"https://mcp.example.com/mcp\"\n".utf8))
        let configBefore = state(codexConfig)
        await pluginLeftoverChecks(keyOff: false)
        check(state(codexConfig) == configBefore && state(settings) == before,
              "skills plugins: working out what removal leaves changes neither Codex's config nor Claude Code's settings")

        // The user turns it off in /plugin, which sets its key to false: Settings › Skills and list_skills
        // say "off", and the review offers the link, since Claude Code then loads nothing from it.
        writeSettings("{\n  \"enabledPlugins\": {\n    \"demo-plugin@skills-dir\": false\n  },\n  \"model\": \"self-test\"\n}\n")
        let keyed = state(settings)
        let row = SkillsStore.inventory().rows.first { $0.name == "demo-plugin" }
        let cell = row.map { SkillsSettingsView.cellText($0, agent: .claudeCode).0 } ?? "none"
        let listed = await SkillsMCP.listSkills()
        let items = listed["skills"] as? [[String: Any]] ?? []
        let agents = items.first { $0["name"] as? String == "demo-plugin" }?["agents"] as? [String: String]
        check(cell == "off" && agents?["claude-code"] == "off",
              "skills plugins: a plugin the user turned off in /plugin shows Claude Code as off", "\(cell) \(String(describing: agents))")
        let third = pluginDownload(home: home)
        defer { third.discard() }
        if let again = third.candidates.first {
            check(SkillsInstaller.defaultClaudeLink(again, fetched: third) == .link,
                  "skills plugins: with its key false, the review offers the link (Claude Code loads nothing from it)")
        }
        let offDetails = SkillsReviewSheet(fetched: third) { _ in }.details.stringValue
        check(offDetails.contains("Agents that load it: Codex, Command Code, \(otherReaders). Claude Code loads nothing from it while its plugin is off."),
              "skills plugins: with its key false, the review leaves Claude Code out of the agents that load it", offDetails)
        await pluginLeftoverChecks(keyOff: true)
        check(state(settings) == keyed, "skills plugins: working out what removal leaves keeps the user's key as it is")

        // Undo takes the link and the skill away, and leaves the settings as the user left them.
        if case .failure(let failure) = await SkillsStore.undo() { check(false, "skills plugins: Undo of the plugin install applies", failure.message) }
        check(!exists(link) && !exists(shared) && state(settings) == keyed,
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

        check(state(realSettings) == realBefore, "skills plugins: the real ~/.claude/settings.json keeps its bytes and mode")
    }

    /// The agents besides Codex, Command Code and Claude Code that read ~/.agents/skills, as the review
    /// names them.
    static let otherReaders = "Gemini CLI, Qwen Code, Cursor, opencode, Copilot CLI, Amp, Junie and goose"

    /// What removing the installed, linked demo-plugin says may stay. `keyOff`: the self-test home's
    /// settings hold "demo-plugin@skills-dir": false, so its plugin never started.
    static func pluginLeftoverChecks(keyOff: Bool) async {
        let (steps, leftovers, installed) = await SkillsInstaller.removal("demo-plugin")
        let said = leftovers.joined(separator: "\n")
        let parts = "Its Claude Code plugin's MCP servers and hooks stop with it. Claude Code sessions open now keep them until they restart."
        let amp = "Amp sessions open now keep its MCP servers until they restart."
        let codex = "Codex may have added the MCP server “docs” (https://mcp.example.com/mcp) for this skill, in ~/.codex/config.toml. "
            + "It stays there, because you may use it for other things. Remove it there if you don't."
        let key = "~/.claude/settings.json keeps “demo-plugin@skills-dir”: false. It stays, and keeps any later folder with that plugin name "
            + "turned off in Claude Code."
        let named = installed && !steps.isEmpty && leftovers.contains(amp) && leftovers.contains(codex)
            && !leftovers.contains("It asked for MCP servers: check your agents' MCP settings.")
        if keyOff {
            check(named && leftovers.contains(key) && !leftovers.contains(parts),
                  "skills plugins: removing a plugin the user turned off names the key that stays, and no parts that ran", said)
        } else {
            check(named && leftovers.contains(parts) && !leftovers.contains(key),
                  "skills plugins: removing a linked plugin names its parts, Amp's servers and the Codex server that may stay", said)
        }
    }
}
