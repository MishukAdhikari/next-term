import Foundation
import Testing
@testable import NextTermCore

/// The review's plugin block: what a Claude Code plugin folder is, how it starts, what it would start and
/// what else it brings.
@Suite struct SkillReviewTextPluginTests {
    static let adds = "If you add it to Claude Code, it starts the programs below every time Claude Code opens, without asking you."

    /// AE1's folder: a server that runs a program, and hooks.
    static func writingHelper() throws -> SkillFixture {
        try SkillFixture("writing-helper").claudeManifest("writing-helper")
            .write(".mcp.json", #"{"mcpServers": {"helper": {"command": "node", "args": ["server.js"]}}}"#)
            .write("hooks/hooks.json", #"{"hooks": {"PostToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "./fmt.sh"}]}]}}"#)
    }

    /// AE1: the lead line, the start state, and each part with its gloss and file.
    @Test func aPluginThatStartsProgramsLeadsWithIt() throws {
        let plugin = try #require(try Self.writingHelper().package?.claude)
        #expect(SkillReviewText.pluginBlock(plugin, start: .on, clashes: []) == [
            "Also a Claude Code plugin, “writing-helper” (.claude-plugin/plugin.json). " + Self.adds + " It starts on.",
            "It would start:",
            "• An MCP server, a program or web service that gives the agent tools, from .mcp.json: “helper” runs the program `node server.js`.",
            "• A hook, a command that runs on Claude Code events, from hooks/hooks.json: PostToolUse (Edit) runs `./fmt.sh`.",
        ])
    }

    /// R2: the start state from the user's key, else the manifest.
    @Test func theStartStateIsSaid() throws {
        let plugin = try #require(try Self.writingHelper().package?.claude)
        let byManifest = try #require(SkillReviewText.pluginBlock(plugin, start: .offByManifest, clashes: []).first)
        #expect(byManifest.hasSuffix(Self.adds + " It starts off only because its manifest says so. A later version can change that."))
        let byKey = try #require(SkillReviewText.pluginBlock(plugin, start: .offByKey, clashes: []).first)
        #expect(byKey.hasSuffix(" Your Claude Code settings keep it off (“writing-helper@skills-dir”: false), so Claude Code loads nothing "
            + "from it, not even its skill, until you turn it on in /plugin."))
    }

    /// AE5: only allowlisted keys and no part on disk.
    @Test func aPluginThatRunsNothingSaysSo() throws {
        let plugin = try #require(try SkillFixture("writing-helper").claudeManifest("writing-helper", #""skills": ["./"]"#).package?.claude)
        #expect(SkillReviewText.pluginBlock(plugin, start: .on, clashes: []) == [
            "Also a Claude Code plugin, “writing-helper” (.claude-plugin/plugin.json). It declares nothing that starts by itself.",
        ])
        let off = SkillReviewText.pluginBlock(plugin, start: .offByKey, clashes: [])
        #expect(off.first?.contains("Your Claude Code settings keep it off") == true)
    }

    /// Commands, agents, output styles and skills load with it, each with SKILL.md's "What it may do" checks.
    @Test func whatItAlsoBringsIsListedWithItsChecks() throws {
        let fixture = try SkillFixture().claudeManifest("demo", #""displayName": "Demo Tools""#)
            .write("commands/go.md", "---\ndescription: Go.\nallowed-tools: Bash(git:*)\n---\nNow: !`date`\n")
            .write("agents/reviewer.md", "---\nname: reviewer\n---\nReview.\n")
        let plugin = try #require(fixture.package?.claude)
        let block = SkillReviewText.pluginBlock(plugin, start: .on, clashes: [])
        #expect(block.first == "Also a Claude Code plugin, “demo” (.claude-plugin/plugin.json), shown as “Demo Tools”. It declares nothing that starts by itself.")
        #expect(!block.contains("It would start:"))
        let brings = Array(block.drop { $0 != "It also brings:" }.dropFirst())
        #expect(brings == [
            "• agents/reviewer.md, an agent.",
            "• commands/go.md, a command: Runs these tools without asking while it is used: Bash(git:*). Runs shell commands before the agent "
                + "reads it (!`…` lines or ```! blocks). The agent may use it on its own when the task fits its description.",
        ])
    }

    /// Every kind of part that starts by itself is listed, so "the programs below" always names something.
    @Test func everyKindOfPartIsListed() throws {
        let manifest = #""channels": [], "monitors": [{"name": "watcher", "command": "watch.sh", "args": ["-q"]}], "#
            + #""lspServers": {"swift": {"command": "sourcekit-lsp"}}, "mcpServers": "../shared/mcp.json""#
        let fixture = try SkillFixture().claudeManifest("demo", manifest)
            .write("hooks/hooks.json", #"{"hooks": {"Stop": [{"hooks": [{"type": "http", "url": "https://hooks.example/stop"}, {"type": "command", "command": "say done"}]}]}}"#)
            .write("settings.json", #"{"agent": "reviewer"}"#)
            .write("bin/tidy", "#!/bin/sh\n", executable: true)
            .write("bin/git", "#!/bin/sh\n", executable: true)
        let plugin = try #require(fixture.package?.claude)
        let block = SkillReviewText.pluginBlock(plugin, start: .on, clashes: [])
        #expect(block.contains("• 2 hooks, commands that run on Claude Code events, from hooks/hooks.json: Stop sends a web request to "
            + "https://hooks.example/stop; Stop runs `say done`."))
        #expect(block.contains("• A monitor, a program that keeps running in the background, from .claude-plugin/plugin.json: “watcher” runs `watch.sh -q`."))
        #expect(block.contains("• An LSP server, a program that reads code as Claude Code edits it, from .claude-plugin/plugin.json: “swift” runs `sourcekit-lsp`."))
        #expect(block.contains("• Its settings.json, which can make a plugin agent the main agent or run a status line command: it makes its agent “reviewer” the main agent."))
        #expect(block.contains("• 2 programs in bin/, which Claude Code's shell can run by name: git and tidy."))
        #expect(block.contains("• Keys in its plugin.json that Next Term does not check: channels."))
        #expect(block.contains("• Paths outside the skill folder, which Claude Code would read from there and which are not reviewed here: ../shared/mcp.json."))
    }

    @Test func unreadFilesCountAsStarting() throws {
        let fixture = try SkillFixture().claudeManifest().write(".mcp.json", "{")
        let plugin = try #require(fixture.package?.claude)
        let block = SkillReviewText.pluginBlock(plugin, start: .on, clashes: [])
        #expect(block.first?.contains(Self.adds) == true)
        #expect(block.contains { $0.hasPrefix("• Files Next Term could not read, which count as parts that may start programs: .mcp.json (") })
        // A manifest that can't be read is not "no usable name": nothing is known about it, so it counts as starting.
        let broken = try #require(try SkillFixture().write(".claude-plugin/plugin.json", "{").package?.claude)
        let brokenBlock = SkillReviewText.pluginBlock(broken, start: .on, clashes: [])
        #expect(brokenBlock.first?.contains(Self.adds) == true && brokenBlock.first?.contains("no usable name") == false)
    }

    /// H2: without a usable name, Claude Code loads the plain skill only.
    @Test func aManifestWithoutAUsableNameLoadsOnlyTheSkill() throws {
        let fixture = try SkillFixture().write(".claude-plugin/plugin.json", #"{"description": "No name."}"#)
            .write(".mcp.json", #"{"mcpServers": {"docs": {"command": "node"}}}"#)
        let plugin = try #require(fixture.package?.claude)
        let lead = try #require(SkillReviewText.pluginBlock(plugin, start: .on, clashes: []).first)
        #expect(lead == "Also a Claude Code plugin, “demo” (.claude-plugin/plugin.json). Claude Code loads only its skill, not its plugin, "
            + "because its plugin.json has no usable name (as of October 2026). A later version may start the programs below.")
    }

    @Test func clashesAndLinksFollowTheLead() throws {
        let fixture = try SkillFixture().write("meta/plugin.json", #"{"name": "demo"}"#).link(".claude-plugin", to: "meta")
            .write("tools/tidy", "#!/bin/sh\n", executable: true).link("bin", to: "tools")
        let plugin = try #require(fixture.package?.claude)
        let synced = SkillInstall.Clash(kind: .synced, name: "demo", text: "You have a plugin named “demo” from claude.ai.")
        let other = SkillInstall.Clash(kind: .skillsDir, name: "demo", text: "~/.claude/skills/x is also a Claude Code plugin named “demo”.")
        let block = SkillReviewText.pluginBlock(plugin, start: .on, clashes: [synced, other])
        #expect(Array(block.dropFirst().prefix(3)) == [
            "⚠︎ You have a plugin named “demo” from claude.ai.",
            "• ~/.claude/skills/x is also a Claude Code plugin named “demo”.",
            "Links inside the folder: .claude-plugin is a link to meta; bin is a link to tools.",
        ])
    }

    @Test func longListsAreCapped() throws {
        let fixture = try SkillFixture().claudeManifest()
        for index in 0..<25 { try fixture.write(String(format: "bin/tool%02d", index), "#!/bin/sh\n", executable: true) }
        let plugin = try #require(fixture.package?.claude)
        let line = try #require(SkillReviewText.pluginBlock(plugin, start: .on, clashes: []).first { $0.hasPrefix("• 25 programs in bin/") })
        #expect(line.hasSuffix(": tool00, tool01, tool02, tool03, tool04, tool05, tool06, tool07, tool08, tool09, tool10, tool11, tool12, "
            + "tool13, tool14, tool15, tool16, tool17, tool18, tool19, and 5 more."))
        #expect(!line.contains("tool20"))
    }

    /// Text from the folder's files stays on one line, with hidden characters written out.
    @Test func namesFromTheFolderStayOnOneLine() throws {
        let fixture = try SkillFixture().claudeManifest("demo\u{200B}x")
            .write("hooks/hooks.json", #"{"hooks": {"Stop\nNow": [{"hooks": [{"type": "command", "command": "a​b"}]}]}}"#)
        let plugin = try #require(fixture.package?.claude)
        let block = SkillReviewText.pluginBlock(plugin, start: .on, clashes: [])
        #expect(block.first?.hasPrefix("Also a Claude Code plugin, “demo⟦U+200B⟧x”") == true)
        #expect(block.contains { $0.contains("Stop⟦U+000A⟧Now runs `a⟦U+200B⟧b`") })
        #expect(block.allSatisfy { !$0.contains("\n") && !$0.contains("\u{2028}") })
    }
}

/// The other packages a folder is, the "Needs MCP servers" row, and the line beside Claude Code's popup.
@Suite struct SkillReviewTextRowsTests {
    @Test func otherPackagesAreNamedOnceUnchecked() throws {
        let fixture = try SkillFixture().claudeManifest()
            .write("gemini-extension.json", #"{"name": "demo", "mcpServers": {"a": {"command": "node"}, "b": {"httpUrl": "https://b.example"}}}"#)
            .write(".codex-plugin/plugin.json", #"{"name": "demo"}"#)
        let package = try #require(fixture.package)
        #expect(SkillReviewText.otherPackages(package) == [
            "Also a Codex plugin (.codex-plugin/plugin.json).",
            "Also a Gemini CLI extension (gemini-extension.json), with MCP servers “a” and “b”.",
            "Not checked for other agents.",
        ])
        let hooks = try #require(try SkillFixture().write("qwen-extension.json", #"{"name": "demo", "mcpServers": {"a": {"command": "node"}}}"#)
            .write("hooks/hooks.json", "{}").package)
        #expect(SkillReviewText.otherPackages(hooks).first == "Also a Qwen Code extension (qwen-extension.json), with the MCP server “a” and hooks.")
        let claudeOnly = try #require(try SkillFixture().claudeManifest().package)
        #expect(SkillReviewText.otherPackages(claudeOnly).isEmpty)
    }

    /// AE7: the Codex line with the table it would add, indented under it, and the row's closing line.
    @Test func theServerRowListsEachAgentWithItsTables() throws {
        let yaml = "dependencies:\n  tools:\n    - type: \"mcp\"\n      value: \"linear\"\n      url: \"https://mcp.linear.app/mcp\"\n"
        let servers = try SkillFixture("writing-helper").write("agents/openai.yaml", yaml).servers
        let rows = SkillReviewText.serverRows(servers, choice: .skip, start: .on, codex: .init(), trigger: "$writing-helper")
        #expect(rows.first == "Needs MCP servers:")
        #expect(rows.dropFirst().first?.hasPrefix("• Codex, from agents/openai.yaml: “linear” connects to https://mcp.linear.app/mcp. If you name this skill with `$writing-helper`") == true)
        #expect(Array(rows.suffix(3)) == ["    [mcp_servers.linear]", "    url = \"https://mcp.linear.app/mcp\"", SkillServers.closing])
        let plain = try SkillFixture().servers
        #expect(SkillReviewText.serverRows(plain, choice: .link, start: .on, codex: .init(), trigger: "$demo").isEmpty)
    }

    /// AE1 and AE2: the row's Claude Code line follows the choice.
    @Test func theClaudeCodeServerLineFollowsTheChoice() throws {
        let servers = try SkillReviewTextPluginTests.writingHelper().servers
        let out = SkillReviewText.serverRows(servers, choice: .skip, start: .on, codex: .init(), trigger: "$writing-helper")
        #expect(out.contains { $0.hasPrefix("• Claude Code, from .mcp.json:") && $0.hasSuffix("Left out of Claude Code, so these don't start there.") })
        let added = SkillReviewText.serverRows(servers, choice: .link, start: .on, codex: .init(), trigger: "$writing-helper")
        #expect(added.contains { $0.hasSuffix("it starts these every time Claude Code opens, without asking you, while “writing-helper@skills-dir” is on.") })
    }

    /// The line beside the popup, one clause per plugin folder, for each choice and start.
    @Test func theChoiceLineNamesWhatInstallDoes() throws {
        let plugin = try #require(try SkillReviewTextPluginTests.writingHelper().package?.claude)
        func line(_ choice: SkillInstall.ClaudeLink, _ start: SkillPackage.Start = .on, kept: Bool = false,
                  clashes: [SkillInstall.Clash] = []) -> String {
            SkillReviewText.choiceLine(skill: "writing-helper", plugin: plugin, choice: choice, start: start, keptLink: kept, clashes: clashes)
        }
        #expect(line(.link) == "writing-helper: linked. It starts the programs below every time Claude Code opens, without asking you.")
        #expect(line(.link, kept: true) == "writing-helper: stays linked. It starts the programs below every time Claude Code opens, without asking you.")
        #expect(line(.link, .offByKey) == "writing-helper: linked. Your Claude Code settings keep it off (“writing-helper@skills-dir”: false) "
            + "until you turn it on in /plugin.")
        #expect(line(.link, .offByManifest) == "writing-helper: linked. Its manifest starts it off; once it is on, it starts the programs below "
            + "every time Claude Code opens, without asking you.")
        #expect(line(.skip) == "writing-helper: not linked. npx skills update may link it again.")
        #expect(line(.skip, kept: true) == "writing-helper: its link is removed, so Claude Code doesn't load it. npx skills update may link it again.")
        let installed = SkillInstall.Clash(kind: .installed, name: "writing-helper", text: "")
        #expect(line(.link, clashes: [installed]) == "writing-helper: linked as a plain skill. Claude Code keeps your installed plugin "
            + "“writing-helper” and doesn't load this one as a plugin.")
        let quiet = try #require(try SkillFixture("writing-helper").claudeManifest("writing-helper").package?.claude)
        #expect(SkillReviewText.choiceLine(skill: "writing-helper", plugin: quiet, choice: .link, start: .on, keptLink: false, clashes: [])
            == "writing-helper: linked. It declares nothing that starts by itself.")
        let unnamed = try #require(try SkillFixture().write(".claude-plugin/plugin.json", "{}").package?.claude)
        #expect(SkillReviewText.choiceLine(skill: "demo", plugin: unnamed, choice: .link, start: .on, keptLink: false, clashes: [])
            == "demo: linked as a plain skill. Claude Code doesn't load its plugin, because its plugin.json has no usable name (as of October 2026).")
    }

    @Test func thePopupItemsFollowTheCountAndTheLink() {
        #expect(SkillReviewText.choiceItems(count: 1, removesLink: false) == ["Leave it out of Claude Code", "Add it to Claude Code as a plugin"])
        #expect(SkillReviewText.choiceItems(count: 1, removesLink: true) == ["Remove it from Claude Code", "Add it to Claude Code as a plugin"])
        #expect(SkillReviewText.choiceItems(count: 2, removesLink: false) == ["Leave them out of Claude Code", "Add them to Claude Code as plugins"])
        #expect(SkillReviewText.choiceItems(count: 3, removesLink: true) == ["Remove them from Claude Code", "Add them to Claude Code as plugins"])
    }
}
