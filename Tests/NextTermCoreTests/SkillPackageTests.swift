import Foundation
import Testing
@testable import NextTermCore

@Suite struct SkillPackageShapeTests {
    @Test(arguments: SkillFixture.shapes)
    func eachShapeGivesItsOneManifest(_ shape: SkillFixture.Shape) throws {
        let package = try SkillFixture.shape(shape).package
        guard let kind = shape.kind else {
            #expect(package == nil, "\(shape)")
            return
        }
        let manifests = try #require(package?.manifests)
        #expect(manifests.map(\.kind) == [kind], "\(shape)")
        #expect(manifests.first?.agent == shape.agent)
        #expect(manifests.first?.name == "demo")
    }

    @Test func twoManifestsGiveBoth() throws {
        let fixture = try SkillFixture().claudeManifest().write("gemini-extension.json", #"{"name": "demo"}"#)
        let kinds = try #require(fixture.package).manifests.map(\.kind)
        #expect(kinds == [.claudePlugin, .geminiExtension])
    }

    /// Only the root counts: Claude Code ignores a manifest in a subfolder (hand check H8), so it is a note.
    @Test func aNestedManifestIsANoteAndNoPlugin() throws {
        let fixture = try SkillFixture().write("sub/.claude-plugin/plugin.json", #"{"name": "nested"}"#)
            .write("sub/.mcp.json", #"{"mcpServers": {"x": {"command": "node"}}}"#)
        let package = try #require(fixture.package)
        #expect(package.claude == nil && package.manifests.isEmpty)
        #expect(package.nested == ["sub/.claude-plugin/plugin.json"])
        #expect(fixture.review.flags.contains { $0.level == .note && $0.file == "sub/.claude-plugin/plugin.json" })
        // With a root manifest too, only the root's parts are read.
        try fixture.claudeManifest()
        let both = try #require(fixture.package)
        #expect(both.claude?.serverCount == 0 && both.nested == ["sub/.claude-plugin/plugin.json"])
    }

    /// Files are opened by their paths, so the volume's case rules apply as they do for Claude Code. The
    /// manifest's own folder must be spelled `.claude-plugin`: Claude Code adopts no other spelling.
    @Test(.enabled(if: SkillFixture.caseInsensitive))
    func caseSpellingsFollowTheVolume() throws {
        let fixture = try SkillFixture().write(".claude-plugin/Plugin.json", #"{"name": "demo"}"#)
            .write(".MCP.json", #"{"mcpServers": {"docs": {"command": "node", "args": ["server.js"]}}}"#)
            .write("Hooks/hooks.json", #"{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "echo hi"}]}]}}"#)
            .write("BIN/tidy", "#!/bin/sh\n", executable: true)
        let plugin = try #require(fixture.package?.claude)
        #expect(plugin.servers.map(\.name) == ["docs"] && plugin.servers.first?.file == ".MCP.json")
        #expect(plugin.parts.contains { $0.kind == .hook && $0.file == "Hooks/hooks.json" })
        #expect(plugin.programs == ["tidy"])
        #expect(plugin.startsPrograms && !plugin.runsNothing)

        let misspelled = try SkillFixture().write(".Claude-Plugin/plugin.json", #"{"name": "demo"}"#)
            .write(".mcp.json", #"{"mcpServers": {"docs": {"command": "node"}}}"#)
        let package = try #require(misspelled.package)
        #expect(package.claude == nil)
        #expect(package.misspelled == [".Claude-Plugin/plugin.json"])
        #expect(misspelled.review.flags.contains { $0.level == .note && $0.text.contains(".claude-plugin") })
    }

    /// Parts reached through links inside the folder are read where the links lead, and named with their targets.
    @Test func partsThroughLinksAreReadAndNamed() throws {
        let fixture = try SkillFixture().write("meta/plugin.json", #"{"name": "demo"}"#).link(".claude-plugin", to: "meta")
            .write("tools/tidy", "#!/bin/sh\n", executable: true).write("tools/lint", "#!/bin/sh\n", executable: true)
            .link("bin", to: "tools")
            .write("x/hooks.json", #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}}"#)
            .link("hooks", to: "x")
            .write("conf/servers.json", #"{"mcpServers": {"docs": {"url": "https://docs.example.com/mcp"}}}"#)
            .link(".mcp.json", to: "conf/servers.json")
        let plugin = try #require(fixture.package?.claude)
        #expect(plugin.programs == ["lint", "tidy"] && plugin.programCount == 2)
        #expect(plugin.parts.map(\.detail) == ["say done"])
        #expect(plugin.servers.first?.url == "https://docs.example.com/mcp")
        let links = Dictionary(uniqueKeysWithValues: plugin.links.map { ($0.path, $0.target) })
        #expect(links == [".claude-plugin": "meta", "bin": "tools", "hooks": "x", ".mcp.json": "conf/servers.json"])
        #expect(!fixture.review.refused)
    }
}

@Suite struct SkillPackageClaudeTests {
    /// AE1: a server that runs a program, and hooks.
    @Test func aPluginWithAServerAndHooksStartsPrograms() throws {
        let fixture = try SkillFixture("writing-helper").claudeManifest("writing-helper")
            .write(".mcp.json", #"{"mcpServers": {"helper": {"command": "node", "args": ["server.js"]}}}"#)
            .write("hooks/hooks.json", #"{"hooks": {"PostToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "./fmt.sh"}]}]}}"#)
        let plugin = try #require(fixture.package?.claude)
        #expect(plugin.name == "writing-helper" && plugin.declaredName == "writing-helper" && plugin.loadsAsPlugin)
        #expect(plugin.servers == [SkillPackage.Server(name: "helper", transport: .stdio, command: "node", args: ["server.js"],
                                                       url: nil, bundle: nil, headersHelper: nil, file: ".mcp.json")])
        #expect(plugin.parts == [SkillPackage.Part(kind: .hook, name: "PostToolUse (Edit)", detail: "./fmt.sh", file: "hooks/hooks.json")])
        #expect(plugin.startsPrograms && !plugin.runsNothing && plugin.defaultEnabled)
        let review = fixture.review
        #expect(review.package?.claude?.name == "writing-helper")
        #expect(review.flags.contains { $0.level == .warning && $0.file == ".claude-plugin/plugin.json" && $0.text.contains("Claude Code plugin") })
    }

    /// Every form `mcpServers` takes in plugin.json: a path, an inline map, a bundle path, a bundle address,
    /// and a list of these.
    @Test func everyFormOfMCPServersIsRead() throws {
        let fixture = try SkillFixture().write("servers.json", #"{"mcpServers": {"from-file": {"command": "python3", "args": ["s.py"]}}}"#)
        let list = #"["./servers.json", {"inline": {"type": "http", "url": "https://x.example/mcp", "headersHelper": "./token.sh"}}, "./server.mcpb", "https://example.com/tool.dxt"]"#
        try fixture.claudeManifest("demo", "\"mcpServers\": " + list)
        let plugin = try #require(fixture.package?.claude)
        #expect(plugin.servers.map(\.name) == ["from-file", "inline", "server", "tool"])
        #expect(plugin.servers.filter { $0.transport == .bundle }.map(\.bundle) == ["./server.mcpb", "https://example.com/tool.dxt"])
        #expect(plugin.servers[1].headersHelper == "./token.sh" && plugin.servers[1].transport == .http)
        #expect(plugin.servers[0].file == "servers.json" && plugin.servers[1].file == ".claude-plugin/plugin.json")
        for single in [#""./servers.json""#, #"{"one": {"command": "node"}}"#, #""./server.mcpb""#, #""https://example.com/tool.dxt""#] {
            try fixture.claudeManifest("demo", "\"mcpServers\": " + single)
            #expect(fixture.package?.claude?.serverCount == 1, "\(single)")
        }
        // A server that runs nothing but a header helper still starts a program.
        let helper = try SkillFixture().claudeManifest("demo", #""mcpServers": {"h": {"type": "http", "url": "https://h.example", "headersHelper": "get-token"}}"#)
        #expect(helper.package?.claude?.startsPrograms == true)
    }

    @Test func pathsOutsideTheFolderAreFlagged() throws {
        let fixture = try SkillFixture().write("servers.json", #"{"inside": {"command": "node"}}"#)
        let paths = #"["../shared/mcp.json", "${CLAUDE_PLUGIN_ROOT}/../x.json", "/etc/x.json", "~/x.json", "${CLAUDE_PLUGIN_ROOT}/servers.json"]"#
        try fixture.claudeManifest("demo", "\"mcpServers\": " + paths)
        let plugin = try #require(fixture.package(home: fixture.parent + "/home")?.claude)
        #expect(plugin.outside == ["../shared/mcp.json", "${CLAUDE_PLUGIN_ROOT}/../x.json", "/etc/x.json", "~/x.json"])
        #expect(plugin.servers.map(\.name) == ["inside"])
        #expect(plugin.startsPrograms && !plugin.runsNothing)
        #expect(fixture.review.flags.contains { $0.level == .warning && $0.text.contains("outside the skill folder") })
        // `~` inside the folder (an installed copy under the home folder) stays inside.
        let home = try SkillFixture("home")
        try home.write(".agents/skills/demo/.claude-plugin/plugin.json", #"{"name": "demo", "mcpServers": "~/.agents/skills/demo/s.json"}"#)
            .write(".agents/skills/demo/s.json", #"{"s": {"command": "node"}}"#)
        let installed = try #require(SkillPackage.read(folder: home.at(".agents/skills/demo"), folderName: "demo", home: home.root)?.claude)
        #expect(installed.outside.isEmpty && installed.serverCount == 1)
    }

    /// `${CLAUDE_PLUGIN_ROOT}-x` is a sibling folder once expanded, and a variable Next Term can't work
    /// out may lead anywhere: both count as outside, never as a file inside that happens to be missing.
    @Test func pathsThatOnlyLookInsideAreOutside() throws {
        let paths = #"["${CLAUDE_PLUGIN_ROOT}-x/servers.json", "$CLAUDE_PLUGIN_ROOT/servers.json", "./${HOME}/s.json"]"#
        let fixture = try SkillFixture().claudeManifest("demo", "\"mcpServers\": " + paths)
        let plugin = try #require(fixture.package?.claude)
        #expect(plugin.outside == ["${CLAUDE_PLUGIN_ROOT}-x/servers.json", "$CLAUDE_PLUGIN_ROOT/servers.json", "./${HOME}/s.json"])
        #expect(plugin.startsPrograms && !plugin.runsNothing)
    }

    /// A bundle is a server wherever it is, and one outside the folder is also flagged as outside.
    @Test func bundlesOutsideTheFolderAreFlagged() throws {
        let fixture = try SkillFixture().claudeManifest("demo", #""mcpServers": ["../tools/x.mcpb", "/opt/y.dxt", "./z.mcpb"]"#)
        let plugin = try #require(fixture.package?.claude)
        #expect(plugin.servers.map(\.name) == ["x", "y", "z"] && plugin.servers.allSatisfy { $0.transport == .bundle })
        #expect(plugin.outside == ["../tools/x.mcpb", "/opt/y.dxt"])
        #expect(fixture.review.flags.contains { $0.level == .warning && $0.text.contains("outside the skill folder") })
    }

    /// AE5: a manifest with only the allowlisted keys, and no part on disk, runs nothing.
    @Test func onlyTheAllowlistRunsNothing() throws {
        let fixture = try SkillFixture().claudeManifest("demo", #""skills": ["./"], "description": "D.", "author": {"name": "A"}"#)
        let plugin = try #require(fixture.package?.claude)
        #expect(plugin.runsNothing && !plugin.startsPrograms && plugin.unknownKeys.isEmpty && plugin.defaultEnabled)
        #expect(!fixture.review.flags.contains { $0.level >= .warning })
        try fixture.claudeManifest("demo", #""skills": ["./"], "defaultEnabled": false"#)
        let off = try #require(fixture.package?.claude)
        #expect(!off.defaultEnabled && off.runsNothing)
    }

    @Test(arguments: [
        ("channels", [".claude-plugin/plugin.json": #"{"name": "demo", "channels": [{"server": "x"}]}"#]),
        ("userConfig", [".claude-plugin/plugin.json": #"{"name": "demo", "userConfig": {"token": {"type": "string"}}}"#]),
        ("experimental.monitors", [".claude-plugin/plugin.json": #"{"name": "demo", "experimental": {"monitors": [{"name": "w", "command": "watch.sh"}]}}"#]),
        ("commands/", [".claude-plugin/plugin.json": #"{"name": "demo"}"#, "commands/go.md": "Go."]),
        ("output-styles/", [".claude-plugin/plugin.json": #"{"name": "demo"}"#, "output-styles/terse.md": "Terse."]),
        ("skills/", [".claude-plugin/plugin.json": #"{"name": "demo"}"#, "skills/other/SKILL.md": "---\nname: other\ndescription: O.\n---\n"]),
        ("settings.json", [".claude-plugin/plugin.json": #"{"name": "demo"}"#, "settings.json": #"{"agent": "reviewer"}"#]),
    ])
    func eachOtherKeyOrPartRunsSomething(_ name: String, _ files: [String: String]) throws {
        let fixture = try SkillFixture()
        for (path, text) in files { try fixture.write(path, text) }
        let plugin = try #require(fixture.package?.claude)
        #expect(!plugin.runsNothing, "\(name)")
    }

    @Test func unknownKeysAndPartsAreNamed() throws {
        let fixture = try SkillFixture().claudeManifest("demo", #""channels": [], "experimental": {"monitors": [{"name": "w", "command": "watch.sh"}], "x": 1}"#)
            .write("settings.json", #"{"agent": "reviewer", "subagentStatusLine": {"command": "status.sh"}}"#)
        let plugin = try #require(fixture.package?.claude)
        #expect(plugin.unknownKeys == ["channels", "experimental.x"])
        #expect(plugin.parts.contains { $0.kind == .monitor && $0.name == "w" && $0.detail == "watch.sh" })
        let settings = try #require(plugin.parts.first { $0.kind == .settings })
        #expect(settings.detail.contains("reviewer") && settings.detail.contains("status line"))
        #expect(plugin.startsPrograms)
    }

    /// `agents/openai.yaml` is Codex's file, not a Claude Code agent.
    @Test func onlyMarkdownInAgentsIsAnAgent() throws {
        let yaml = try SkillFixture().claudeManifest().write("agents/openai.yaml", "interface:\n  display_name: Demo\n")
        let plugin = try #require(yaml.package?.claude)
        #expect(plugin.brings.isEmpty && plugin.runsNothing)
        try yaml.write("agents/reviewer.md", "---\nname: reviewer\n---\nReview.\n")
        let withAgent = try #require(yaml.package?.claude)
        #expect(withAgent.brings.map(\.file) == ["agents/reviewer.md"] && withAgent.brings.first?.kind == .agent)
        #expect(!withAgent.runsNothing && !withAgent.startsPrograms)
    }

    /// Anything not read counts as running, and never crashes.
    @Test func whatCanNotBeReadCountsAsRunning() throws {
        let broken = try SkillFixture().write(".claude-plugin/plugin.json", #"{"name": "demo", "#)
        let big = try SkillFixture().claudeManifest().data(".mcp.json", Data(repeating: 0x20, count: SkillReview.maxReadSize + 1))
        let number = try SkillFixture().claudeManifest("demo", #""mcpServers": 3"#)
        let duplicate = try SkillFixture().claudeManifest()
            .write("hooks/hooks.json", #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "a"}]}], "Stop": []}}"#)
        let entry = try SkillFixture().claudeManifest().write("hooks/hooks.json", #"{"hooks": {"Stop": "say done"}}"#)
        let comment = try SkillFixture().claudeManifest().write(".lsp.json", "{\n  // go\n  \"go\": {\"command\": \"gopls\"}\n}")
        for (fixture, file) in [(broken, ".claude-plugin/plugin.json"), (big, ".mcp.json"), (number, ".claude-plugin/plugin.json"),
                                (duplicate, "hooks/hooks.json"), (entry, "hooks/hooks.json"), (comment, ".lsp.json")] {
            let plugin = try #require(fixture.package?.claude)
            #expect(plugin.unread.map(\.file).contains(file), "\(file): \(plugin.unread)")
            #expect(!plugin.runsNothing && plugin.startsPrograms, "\(file)")
            #expect(fixture.review.flags.contains { $0.level == .warning && $0.file == file && $0.text.contains("could not read") }, "\(file)")
        }
    }

    @Test func longListsAreCut() throws {
        let servers = (1...30).map { "\"s\($0)\": {\"command\": \"node\"}" }.joined(separator: ", ")
        let fixture = try SkillFixture().claudeManifest().write(".mcp.json", "{\"mcpServers\": {\(servers)}}")
        for index in 1...25 { try fixture.write("bin/tool\(index)", "#!/bin/sh\n", executable: true) }
        let plugin = try #require(fixture.package?.claude)
        #expect(plugin.servers.count == 20 && plugin.serverCount == 30)
        #expect(SkillPackage.more(plugin.serverCount - plugin.servers.count) == "and 10 more")
        #expect(plugin.programs.count == 20 && plugin.programCount == 25)
        #expect(SkillPackage.more(0) == nil)
    }

    /// Claude Code adds bin/ to the end of its shell's PATH (hand check H6): a program named like a
    /// common command runs wherever that command is missing.
    @Test func binProgramsNamedLikeCommonCommandsWarn() throws {
        let fixture = try SkillFixture().claudeManifest().write("bin/git", "#!/bin/sh\n", executable: true)
            .write("bin/tidy", "#!/bin/sh\n", executable: true)
        let plugin = try #require(fixture.package?.claude)
        #expect(plugin.commonCommands == ["git"])
        let flags = fixture.review.flags
        #expect(flags.contains { $0.level == .warning && $0.file == "bin/git" && $0.text.contains("PATH") })
        #expect(!flags.contains { $0.file == "bin/tidy" && $0.text.contains("PATH") })
    }

    /// Hand check H2: with no name Claude Code loads the folder as a plain skill, keyed by its folder name.
    @Test func aManifestWithoutANameIsKeyedByTheFolder() throws {
        let fixture = try SkillFixture().write(".claude-plugin/plugin.json", "{}")
        let plugin = try #require(fixture.package?.claude)
        #expect(plugin.name == "demo" && plugin.declaredName == nil && !plugin.loadsAsPlugin)
        #expect(fixture.review.flags.contains { $0.level == .note && $0.text.contains("no usable name") })
        // Nothing is known about a manifest that can't be read: no note about its name.
        let broken = try SkillFixture().write(".claude-plugin/plugin.json", "{oops")
        #expect(!broken.review.flags.contains { $0.text.contains("no usable name") })
        let spaced = try SkillFixture().claudeManifest("my plugin")
        #expect(spaced.package?.claude?.loadsAsPlugin == false)
        let odd = try SkillFixture().claudeManifest("Probe_x.y")
        #expect(odd.package?.claude?.loadsAsPlugin == true)
    }

    @Test func otherManifestsListTheirServersAndHooks() throws {
        let fixture = try SkillFixture()
            .write("gemini-extension.json", #"{"name": "demo", "mcpServers": {"a": {"command": "node"}, "b": {"httpUrl": "https://b.example"}}}"#)
            .write(".codex-plugin/plugin.json", #"{"name": "demo", "mcpServers": "./.mcp.json"}"#)
            .write(".mcp.json", #"{"mcpServers": {"c": {"command": "npx"}}}"#)
            .write("hooks/hooks.json", #"{"hooks": {}}"#)
        let package = try #require(fixture.package)
        let gemini = try #require(package.manifests.first { $0.kind == .geminiExtension })
        #expect(gemini.servers.map(\.name) == ["a", "b"] && gemini.hooks == ["hooks/hooks.json"])
        let codex = try #require(package.manifests.first { $0.kind == .codexPlugin })
        #expect(codex.servers.map(\.name) == ["c"] && codex.servers.first?.file == ".mcp.json")
        let flags = fixture.review.flags
        #expect(flags.contains { $0.level == .warning && $0.file == "gemini-extension.json" && $0.text.hasSuffix("Next Term didn't check what Gemini CLI does with them.") })
        #expect(flags.contains { $0.text.contains("Gemini CLI extension, with MCP servers “a” and “b”, and hooks.") })
        #expect(flags.contains { $0.text.contains("Codex plugin, with the MCP server “c” and hooks.") })
        #expect(flags.contains { $0.level == .warning && $0.file == ".codex-plugin/plugin.json" })
        let quiet = try SkillFixture().write("qwen-extension.json", #"{"name": "demo"}"#)
        #expect(!quiet.review.flags.contains { $0.level >= .warning })
        let unread = try SkillFixture().write("gemini-extension.json", #"{"name": "demo", "#)
        #expect(unread.review.flags.contains { $0.file == "gemini-extension.json" && $0.text.contains("could not read") })
    }

    /// What a plugin also brings is listed, and each skill and command gets SKILL.md's checks.
    @Test func whatItAlsoBringsIsCheckedLikeASkill() throws {
        let fixture = try SkillFixture().claudeManifest("demo", #""commands": "./extra""#)
            .write("commands/deploy.md", "---\nallowed-tools: Bash(*)\n---\nRun !`git push` now.\n")
            .write("extra/sub/more.md", "More.\n")
            .write("skills/other/SKILL.md", "---\nname: other\ndescription: O.\n---\n```!\nrm -rf build\n```\n")
            .write("output-styles/terse.md", "Terse.\n")
        let plugin = try #require(fixture.package?.claude)
        let files = plugin.brings.map(\.file)
        #expect(files == ["commands/deploy.md", "extra/sub/more.md", "output-styles/terse.md", "skills/other/SKILL.md"])
        let deploy = try #require(plugin.brings.first { $0.file == "commands/deploy.md" })
        #expect(deploy.kind == .command && deploy.capabilities.contains { $0.contains("Bash(*)") } && deploy.capabilities.contains { $0.contains("!`") })
        #expect(plugin.brings.first { $0.kind == .skill }?.capabilities.contains { $0.contains("shell commands") } == true)
        #expect(!plugin.startsPrograms && !plugin.runsNothing)
    }
}

@Suite struct SkillPackageNameTests {
    /// Claude Code compares plugin names after NFC and lowercasing; a look-alike also folds separators.
    @Test func namesCompareAsClaudeCodeComparesThem() {
        #expect(SkillPackage.normalized("Writing-Helper") == SkillPackage.normalized("writing-helper"))
        #expect(SkillPackage.normalized("caf\u{E9}") == SkillPackage.normalized("cafe\u{301}"))
        #expect(SkillPackage.normalized("writing_helper") != SkillPackage.normalized("writing-helper"))
        #expect(SkillPackage.lookalike("writing_helper") == SkillPackage.lookalike("writing-helper"))
        #expect(SkillPackage.lookalike("Writing.Helper") == SkillPackage.lookalike("writing helper"))
        #expect(SkillPackage.lookalike("ｗｒｉｔｉｎｇ-helper") == SkillPackage.lookalike("writing-helper"))
        #expect(SkillPackage.isASCII("writing-helper") && !SkillPackage.isASCII("writing-h\u{0435}lper"))
    }

    @Test func nonASCIIPluginAndServerNamesAreFlagged() throws {
        let fixture = try SkillFixture().claudeManifest("writing-h\u{0435}lper")
            .write(".mcp.json", "{\"mcpServers\": {\"d\u{043E}cs\": {\"command\": \"node\"}}}")
        let texts = fixture.review.flags.filter { $0.level == .warning }.map(\.text)
        #expect(texts.contains { $0.contains("plugin name") && $0.contains("outside ASCII") })
        #expect(texts.contains { $0.contains("server name") && $0.contains("outside ASCII") })
    }

    /// KTD10: Codex's namespace comes from the first manifest with a name, in Codex's order.
    @Test func codexsNamespaceFollowsItsManifestOrder() throws {
        let both = try SkillFixture().write(".codex-plugin/plugin.json", #"{"name": "a"}"#).claudeManifest("b")
        #expect(SkillPackage.names(folder: both.root) == SkillPackage.Names(codex: "a", claude: "b", isClaudePlugin: true))
        #expect(both.package?.codexName == "a")
        let claude = try SkillFixture().claudeManifest("b")
        #expect(SkillPackage.names(folder: claude.root) == SkillPackage.Names(codex: "b", claude: "b", isClaudePlugin: true))
        let agentPlugin = try SkillFixture().claudeManifest("b")
            .write("plugin.json", #"{"$schema": "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json", "name": "c"}"#)
        #expect(SkillPackage.names(folder: agentPlugin.root).codex == "c")
        let cursor = try SkillFixture().write(".cursor-plugin/plugin.json", #"{"name": "d"}"#)
        #expect(SkillPackage.names(folder: cursor.root) == SkillPackage.Names(codex: "d", claude: nil, isClaudePlugin: false))
        let nameless = try SkillFixture().write(".claude-plugin/plugin.json", "{}")
        #expect(SkillPackage.names(folder: nameless.root) == SkillPackage.Names(codex: nil, claude: nil, isClaudePlugin: true))
    }
}

@Suite struct SkillReviewPackageTests {
    @Test func aPluginThatStartsProgramsSaysWhoRunsThem() throws {
        let fixture = try SkillFixture().claudeManifest()
            .write("hooks/hooks.json", #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "./done.sh"}]}]}}"#)
            .write("done.sh", "#!/bin/sh\necho done\n", executable: true)
        let capabilities = fixture.review.capabilities
        #expect(capabilities.contains { $0.hasPrefix("Claude Code starts its hooks by itself") })
        #expect(capabilities.contains { $0.contains("Brings 1 file that can run") })
        #expect(!capabilities.contains { $0.contains("only through its own tools") })
    }

    /// bin/ programs are not started by Claude Code: they are put on its shell's PATH.
    @Test func aPluginWithOnlyProgramsSaysTheyGoOnThePath() throws {
        let fixture = try SkillFixture().claudeManifest().write("bin/tidy", "#!/bin/sh\n", executable: true)
        let capabilities = fixture.review.capabilities
        #expect(capabilities.contains { $0.hasPrefix("Claude Code puts the programs in its bin/ folder on its shell's PATH") })
        #expect(!capabilities.contains { $0.contains("Claude Code starts") })
        #expect(capabilities.contains("Brings 1 file that can run (scripts or programs)."))
    }

    @Test func aPlainSkillsScriptLineIsUnchanged() throws {
        let fixture = try SkillFixture().write("scripts/run.sh", "#!/bin/sh\necho hi\n", executable: true)
        let capabilities = fixture.review.capabilities
        #expect(capabilities.contains("Brings 1 file that can run (scripts or programs); the agent runs them only through its own tools."))
        #expect(!capabilities.contains { $0.contains("Claude Code starts") })
    }

    @Test func fencedShellBlocksCount() throws {
        let fenced = try SkillFixture(skill: "---\nname: demo\ndescription: D.\n---\nFirst:\n\n```!\ngit status\n```\n")
        #expect(fenced.review.capabilities.contains { $0.contains("Runs shell commands before the agent reads it") })
        let plain = try SkillFixture(skill: "---\nname: demo\ndescription: D.\n---\n```sh\ngit status\n```\n")
        #expect(!plain.review.capabilities.contains { $0.contains("Runs shell commands") })
    }

    @Test func oneLineWritesOutLineBreaksAndCuts() {
        #expect(SkillReview.oneLine("a\nb\rc\u{85}d\u{2028}e\u{2029}f") == "a⟦U+000A⟧b⟦U+000D⟧c⟦U+0085⟧d⟦U+2028⟧e⟦U+2029⟧f")
        #expect(SkillReview.oneLine("x\u{200B}y") == "x⟦U+200B⟧y")
        #expect(SkillReview.oneLine(String(repeating: "a", count: 250)) == String(repeating: "a", count: 200) + "…")
        #expect(SkillReview.oneLine("abcdef", limit: 3) == "abc…")
        // A cut never leaves half of a written-out character.
        #expect(SkillReview.oneLine("abc\ndef", limit: 6) == "abc…")
        #expect(SkillReview.oneLine("short") == "short")
    }
}

/// What an update compares with the installed copy to keep Claude Code's link: the parts that start by
/// themselves, not the skill's text, the version or the other allowlisted keys.
@Suite struct SkillPackagePartsTests {
    static let server = #"{"mcpServers": {"docs": {"command": "node", "args": ["server.js"]}}}"#
    static let hooks = #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "./stop.sh"}]}]}}"#

    func plugin(_ fixture: SkillFixture) throws -> SkillPackage.ClaudePlugin { try #require(fixture.package?.claude) }

    func installed() throws -> SkillFixture {
        try SkillFixture().claudeManifest("demo", #""version": "1.0.0", "mcpServers": ["./.mcp.json", "./server.mcpb"]"#).write(".mcp.json", Self.server)
            .write("hooks/hooks.json", Self.hooks).write("bin/tidy", "#!/bin/sh\n", executable: true).write("server.mcpb", "PK v1")
    }

    @Test func theTextAndTheAllowlistedKeysDontCount() throws {
        let old = try installed()
        let new = try SkillFixture(skill: "---\nname: demo\ndescription: Newer.\n---\nNew text.\n")
            .claudeManifest("demo", #""version": "2.0.0", "description": "Newer.", "keywords": ["x"], "mcpServers": ["./.mcp.json", "./server.mcpb"]"#)
            .write(".mcp.json", Self.server).write("hooks/hooks.json", Self.hooks).write("bin/tidy", "#!/bin/sh\n", executable: true)
            .write("server.mcpb", "PK v1").write("notes.md", "Other text.")
        #expect(try plugin(new).sameParts(as: plugin(old)))
        try new.write("bin/lint", "#!/bin/sh\n", executable: true)
        #expect(try !plugin(new).sameParts(as: plugin(old)))
    }

    @Test(arguments: [
        (".mcp.json", #"{"mcpServers": {"docs": {"command": "node", "args": ["other.js"]}}}"#),
        (".mcp.json", #"{"mcpServers":{"docs":{"command":"node","args":["server.js"]}}}"#),
        ("hooks/hooks.json", #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "./stop.sh", "timeout": 5}]}]}}"#),
        (".claude-plugin/plugin.json", #"{"name": "demo", "channels": []}"#),
        ("settings.json", #"{"agent": "reviewer"}"#),
        // A program in bin/ and a bundle in the folder are compared by their bytes: an update can swap the code.
        ("bin/tidy", "#!/bin/sh\necho newer\n"),
        ("server.mcpb", "PK v2"),
    ])
    func anyChangeToWhatStartsIsNotTheSame(_ path: String, _ text: String) throws {
        let old = try installed()
        let new = try installed().write(path, text)
        #expect(try !plugin(new).sameParts(as: plugin(old)), "\(path)")
    }

    /// Something unread, outside the folder, or no installed copy: never the same.
    @Test func whatCantBeReadIsNeverTheSame() throws {
        let old = try installed()
        #expect(try !plugin(old).sameParts(as: nil))
        let unread = try installed().write("hooks/hooks.json", "{")
        #expect(try plugin(unread).partsFingerprint == nil && !plugin(unread).sameParts(as: plugin(unread)))
        // A program in bin/ that is a link out of the folder can't be compared.
        let linkedOut = try installed()
        try FileManager.default.removeItem(atPath: linkedOut.at("bin/tidy"))
        try linkedOut.link("bin/tidy", to: "/bin/sh")
        #expect(try plugin(linkedOut).partsFingerprint == nil)
        let outside = try installed().claudeManifest("demo", #""mcpServers": "../shared/mcp.json""#)
        #expect(try plugin(outside).partsFingerprint == nil)
        #expect(try plugin(installed()).sameParts(as: plugin(old)))
    }
}
