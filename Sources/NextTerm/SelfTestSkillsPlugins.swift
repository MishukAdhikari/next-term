import AppKit
import NextTermCore

/// The review of a skill folder that is also a Claude Code plugin, from a download built without the
/// network, on the self-test's own home folder. Nothing here starts Claude Code, Codex or any of the
/// plugin's parts: they are only read.
extension SelfTest {
    static func pluginReviewChecks(home: String) async {
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
            + "mcpServers:\n  docs:\n    url: https://mcp.example.com/mcp\n---\nUse it well.\n"
        write("SKILL.md", skill)
        write(".claude-plugin/plugin.json", #"{"name": "demo-plugin", "description": "A demo plugin."}"#)
        write(".mcp.json", #"{"mcpServers": {"demo": {"command": "/usr/bin/true"}}}"#)
        write("hooks/hooks.json", #"{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "/usr/bin/true"}]}]}}"#)
        write("agents/openai.yaml", "dependencies:\n  tools:\n    - type: \"mcp\"\n      value: \"docs\"\n      url: \"https://mcp.example.com/mcp\"\n")
        write("scripts/run.sh", "#!/bin/sh\necho hi\n")
        chmod(folder + "/scripts/run.sh", 0o755)
        let found = SkillsGitHub.Found(path: "skills/demo-plugin", tree: GitHash.folder(folder) ?? "")
        let source = SkillSource(owner: "example-org", repo: "plugin", path: "skills/demo-plugin")
        let resolved = SkillsGitHub.Resolved(source: source, commit: String(repeating: "0123456789", count: 4), date: nil, skills: [found], truncated: false)
        let candidates = SkillsInstaller.check([found], top: top, repo: "plugin")
        let fetched = SkillsInstaller.Fetched(resolved: resolved, info: nil, scratch: scratch, candidates: candidates,
                                              lockPath: SkillLock.path(home: home, environment: [:]), inventory: SkillsStore.inventory(),
                                              editedSinceInstall: [], projects: [])
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
    }
}
