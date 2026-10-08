import Foundation
import Testing
@testable import NextTermCore

/// agents/openai.yaml as Codex reads it: entries of type mcp in `dependencies.tools`.
@Suite struct SkillServersCodexTests {
    /// The layout Codex's docs and openai/skills use.
    static let documented = """
    interface:
      display_name: "Linear"
      short_description: "Manage issues in Linear"
    dependencies:
      tools:
        - type: "mcp"
          value: "linear"
          description: "Linear MCP server"
          transport: "streamable_http"
          url: "https://mcp.linear.app/mcp"
    """

    static func servers(_ yaml: String) throws -> SkillServers {
        try SkillFixture().write("agents/openai.yaml", yaml).servers
    }

    @Test func theDocumentedExampleGivesOneServer() throws {
        let servers = try Self.servers(Self.documented)
        let linear = SkillPackage.Server(name: "linear", transport: .http, command: nil, args: [], url: "https://mcp.linear.app/mcp",
                                         bundle: nil, headersHelper: nil, file: "agents/openai.yaml")
        #expect(servers.codex == [linear])
        #expect(servers.codexFile == "agents/openai.yaml" && servers.unread.isEmpty)
        #expect(servers.amp.isEmpty && servers.claude.isEmpty)
    }

    @Test func transportsAndTypesFollowCodex() throws {
        let yaml = """
        dependencies:
          tools:
            - type: mcp
              value: docs
              transport: stdio
              command: node
            - type: MCP
              value: plain
              url: https://plain.example/mcp
            - type: mcp
              value: shouting
              transport: Streamable_HTTP
              url: https://shouting.example/mcp
            - type: "env_var"
              value: "LINEAR_TOKEN"
        """
        let servers = try Self.servers(yaml)
        #expect(servers.codex.map(\.name) == ["docs", "plain", "shouting"])
        #expect(servers.codex.map(\.transport) == [.stdio, .http, .http])
        #expect(servers.codex.first?.command == "node" && servers.codex.first?.args == [])
        #expect(servers.unread.isEmpty)
    }

    /// Codex warns about an entry it can't use and skips it: Next Term says it could not read it.
    @Test(arguments: [
        "  - type: mcp\n    value: docs\n    transport: stdio\n",
        "  - type: mcp\n    value: docs\n",
        "  - type: mcp\n    url: https://x.example/mcp\n",
        "  - type: mcp\n    value: docs\n    transport: sse\n    url: https://x.example/mcp\n",
        "  - value: docs\n    url: https://x.example/mcp\n",
    ])
    func anEntryCodexCanNotUseIsUnread(_ entry: String) throws {
        let servers = try Self.servers("dependencies:\n  tools:\n" + entry)
        #expect(servers.codex.isEmpty)
        #expect(servers.unread.map(\.file) == ["agents/openai.yaml"], "\(entry)")
    }

    /// Real-world layouts: quoted and bare values, two and four spaces, comments, list items at the
    /// parent key's indent, and a colon inside a value.
    @Test(arguments: [
        "dependencies:\n  tools:\n  - type: mcp\n    value: linear\n    url: https://mcp.linear.app/mcp\n",
        "dependencies:\n    tools:\n        -   type: mcp\n            value: linear\n            url: https://mcp.linear.app/mcp\n",
        "---\n# Codex metadata\ndependencies:   # what it needs\n  tools:\n    - type: mcp # an MCP server\n\n      value: 'linear'\n      url: \"https://mcp.linear.app/mcp\"  # hosted\n",
        "interface:\n  default_prompt: |\n    Use $linear.\n    tools: [x]\ndependencies:\n  tools:\n    - type: mcp\n      value: linear\n      url: https://mcp.linear.app/mcp\n",
        "dependencies:\n  tools:\n    -\n      type: mcp\n      value: linear\n      url: https://mcp.linear.app/mcp\n",
    ])
    func everydayLayoutsAreRead(_ yaml: String) throws {
        let servers = try Self.servers(yaml)
        #expect(servers.codex.map(\.name) == ["linear"], "\(yaml)")
        #expect(servers.codex.first?.url == "https://mcp.linear.app/mcp")
        #expect(servers.unread.isEmpty, "\(servers.unread)")
    }

    /// Forms the reader doesn't read make the file unread, never "none".
    @Test(arguments: [
        "dependencies:\n  tools: [{type: mcp, value: linear, url: \"https://mcp.linear.app/mcp\"}]\n",
        "dependencies:\n  tools:\n    - {type: mcp, value: linear, url: \"https://mcp.linear.app/mcp\"}\n",
        "base: &base\n  type: mcp\ndependencies:\n  tools:\n    - value: linear\n      type: mcp\n      url: https://mcp.linear.app/mcp\n",
        "dependencies:\n  tools:\n    - *linear\n",
        "dependencies:\n  tools:\n    - <<: {}\n      type: mcp\n      value: linear\n      url: https://mcp.linear.app/mcp\n",
        "dependencies:\n  tools:\n    - type: mcp\n      value: linear\n      url: |\n        https://mcp.linear.app/mcp\n",
        "dependencies:\n  tools:\n    - type: !!str mcp\n      value: linear\n      url: https://mcp.linear.app/mcp\n",
        "dependencies:\n  tools:\n    - \"type\": mcp\n      value: linear\n      url: https://mcp.linear.app/mcp\n",
        "dependencies:\n  ? tools\n  : - type: mcp\n",
        "\"dependencies\":\n  tools:\n    - type: mcp\n      value: linear\n      url: https://mcp.linear.app/mcp\n",
        "interface:\n  short_description: Works with the Linear MCP\n",
        "dependencies:\n  tools:\n    - type: mcp\n      value: linear\n      url: https://mcp.linear.app/mcp\n     stray: line\n",
        "dependencies:\n\ttools:\n",
    ])
    func formsItDoesNotReadMakeTheFileUnread(_ yaml: String) throws {
        let servers = try Self.servers(yaml)
        #expect(servers.unread.map(\.file) == ["agents/openai.yaml"], "\(yaml)")
        let lines = servers.lines(choice: .skip, start: .on, codex: .init(), trigger: "$demo")
        let codex = try #require(lines.first { $0.agent == "Codex" })
        #expect(codex.text.contains("could not read every entry in agents/openai.yaml"), "\(codex.text)")
    }

    @Test func aFileTooLargeOrOutsideIsUnread() throws {
        let big = try SkillFixture().data("agents/openai.yaml", Data(repeating: 0x20, count: SkillReview.maxReadSize + 1))
        #expect(big.servers.unread.first?.reason.contains("5 MB") == true)
        let outside = try SkillFixture()
        try outside.write("../elsewhere.yaml", Self.documented)
        try outside.link("agents/openai.yaml", to: "../../elsewhere.yaml")
        #expect(outside.servers.codex.isEmpty && outside.servers.unread.map(\.file) == ["agents/openai.yaml"])
    }

    @Test func noServersGiveNoLines() throws {
        let plain = try SkillFixture().write("agents/openai.yaml", "interface:\n  display_name: Demo\n").servers
        #expect(plain.isEmpty && plain.unread.isEmpty)
        #expect(plain.lines(choice: .link, start: .on, codex: .init(), trigger: "$demo").isEmpty)
        #expect(try SkillFixture().servers.isEmpty)
    }
}

/// The line Codex's servers get, the tables it would add, and how they match ~/.codex/config.toml.
@Suite struct SkillServersCodexLineTests {
    static func line(_ yaml: String = SkillServersCodexTests.documented, config: String? = nil, trigger: String = "$demo") throws -> SkillServers.Line {
        let servers = try SkillServersCodexTests.servers(yaml)
        let lines = servers.lines(choice: .skip, start: .on, codex: SkillServers.codexConfig(config), trigger: trigger)
        return try #require(lines.first { $0.agent == "Codex" })
    }

    /// Covers AE7: the name, the $name condition, the full-access condition, and the table.
    @Test func theLineNamesTheServerTheConditionsAndTheTable() throws {
        let line = try Self.line(trigger: "$writing-helper")
        #expect(line.text.hasPrefix("Codex, from agents/openai.yaml: “linear” connects to https://mcp.linear.app/mcp."))
        #expect(line.text.contains("If you name this skill with `$writing-helper` in Codex itself (its CLI, IDE extension or app), Codex offers to add "
            + "these to ~/.codex/config.toml."))
        #expect(line.text.contains("If you let Codex work without asking and with full access, it adds them without asking you."))
        #expect(line.text.hasSuffix("It would add:"))
        #expect(line.preview == ["[mcp_servers.linear]", "url = \"https://mcp.linear.app/mcp\""])
    }

    @Test func aProgramServerKeepsItsCommandOnly() throws {
        let yaml = "dependencies:\n  tools:\n    - type: mcp\n      value: docs.v2\n      transport: stdio\n      command: \"node \\\"server\\\".js\"\n"
        let line = try Self.line(yaml)
        #expect(line.preview == ["[mcp_servers.\"docs.v2\"]", "command = \"node \\\"server\\\".js\""])
        #expect(line.text.contains("Codex keeps a program's command, with no arguments."))
    }

    /// Covers AE7: matched by transport and address, as Codex matches; a name alone never matches.
    @Test func whatIsAlreadyThereIsSaid() throws {
        let sameURL = "[mcp_servers.linear-hosted]\nurl = \"https://mcp.linear.app/mcp\"\n"
        let present = try Self.line(config: sameURL)
        #expect(present.text.contains("Already in your Codex config: “linear” (as “linear-hosted”)."))
        #expect(present.preview.isEmpty && !present.text.contains("It would add"))

        let spaced = SkillServersCodexTests.documented.replacingOccurrences(of: "\"https://mcp.linear.app/mcp\"", with: "\"https://mcp.linear.app/mcp  \"")
        #expect(try Self.line(spaced, config: sameURL).text.contains("Already in your Codex config"))

        let stdio = "dependencies:\n  tools:\n    - type: mcp\n      value: docs\n      transport: STDIO\n      command: docs-server\n"
        let sameCommand = "[mcp_servers.docs]\ncommand = \"docs-server\"\nargs = [\n  \"--port\", # its port\n  \"8080\",\n]\n"
        #expect(try Self.line(stdio, config: sameCommand).text.contains("Already in your Codex config: “docs”."))

        let otherURL = "[mcp_servers.linear]\nurl = \"https://linear.example.com/mcp\"\n"
        let keeps = try Self.line(config: otherURL)
        #expect(keeps.text.contains("Codex would ask, then keep your own “linear”, which connects elsewhere."))
        #expect(keeps.preview.isEmpty)

        let elsewhere = "[mcp_servers.notes]\nurl = \"https://notes.example.com/mcp\"\n"
        #expect(try Self.line(config: elsewhere).preview == ["[mcp_servers.linear]", "url = \"https://mcp.linear.app/mcp\""])
    }

    @Test func statusFollowsCodex() throws {
        let dependency = try #require(try SkillServersCodexTests.servers(SkillServersCodexTests.documented).codex.first)
        let table = { (name: String, url: String?, command: String?) in SkillServers.CodexConfig.Table(name: name, url: url, command: command) }
        #expect(SkillServers.codexStatus(dependency, in: .init()) == .adds)
        #expect(SkillServers.codexStatus(dependency, in: .init(tables: [table("x", " https://mcp.linear.app/mcp ", nil)])) == .present("x"))
        #expect(SkillServers.codexStatus(dependency, in: .init(tables: [table("linear", nil, "https://mcp.linear.app/mcp")])) == .keepsYours)
        #expect(SkillServers.codexStatus(dependency, in: .init(tables: [table("x", nil, nil)])) == .adds)
        #expect(SkillServers.codexStatus(dependency, in: .init(tables: [table("x", "https://mcp.linear.app/mcp", nil)], complete: false)) == .unknown)
    }
}

/// ~/.codex/config.toml's [mcp_servers.<name>] tables.
@Suite struct SkillServersCodexConfigTests {
    @Test func tablesAreRead() {
        let text = """
        model = "gpt-5"
        # [mcp_servers.commented]
        [mcp_servers."docs.v2"]
        url = "https://docs.example.com/mcp#top" # hosted
        [mcp_servers.docs.v2.env]
        TOKEN = "x"
        [mcp_servers.local]
        command = 'node'
        args = [
          "server.js", "[not a table]",
        ]
        env = { PORT = "8080" }
        tools.search.enabled = true
        [mcp_servers.local.env]
        url = "https://not-a-server.example"
        [profiles.fast]
        model = "gpt-5-mini"
        """
        let config = SkillServers.codexConfig(text)
        #expect(config.complete)
        #expect(config.tables.map(\.name) == ["docs.v2", "local"])
        #expect(config.tables.first?.url == "https://docs.example.com/mcp#top")
        #expect(config.tables.last?.command == "node" && config.tables.last?.url == nil)
        #expect(SkillServers.codexConfig(nil) == .init())
    }

    /// Forms that can define a server the reader doesn't see: the lines say to check the file.
    @Test(arguments: [
        "[mcp_servers]\nlinear = { url = \"https://mcp.linear.app/mcp\" }\n",
        "mcp_servers = { linear = { url = \"https://mcp.linear.app/mcp\" } }\n",
        "mcp_servers.linear.url = \"https://mcp.linear.app/mcp\"\n",
        "[mcp_servers]\nlinear.url = \"https://mcp.linear.app/mcp\"\n",
        "instructions = \"\"\"\n[mcp_servers.fake]\nurl = \"https://mcp.linear.app/mcp\"\n\"\"\"\n",
        "[[mcp_servers.linear]]\nurl = \"https://mcp.linear.app/mcp\"\n",
        "[mcp_servers.linear]\nurl = [\"https://mcp.linear.app/mcp\"]\n",
        "[mcp_servers.linear\nurl = \"https://mcp.linear.app/mcp\"\n",
        "[mcp_servers.a]\nurl = \"https://a.example\"\n[mcp_servers.a]\nurl = \"https://b.example\"\n",
    ])
    func formsThatCouldHideAServerMakeItIncomplete(_ text: String) throws {
        let config = SkillServers.codexConfig(text)
        #expect(!config.complete, "\(text)")
        let line = try SkillServersCodexLineTests.line(config: text)
        #expect(line.text.contains("Next Term could not read all of ~/.codex/config.toml: check it for “linear”."), "\(line.text)")
        #expect(!line.text.contains("Already in your Codex config") && line.preview.isEmpty)
    }

    @Test func theConfigIsReadFromTheHome() throws {
        let home = try SkillFixture("home")
        #expect(SkillServers.codexConfig(home: home.root) == .init())
        try home.write(".codex/config.toml", "[mcp_servers.linear]\nurl = \"https://mcp.linear.app/mcp\"\n")
        #expect(SkillServers.codexConfig(home: home.root).tables.map(\.name) == ["linear"])
        try home.data(".codex/config.toml", Data(repeating: 0x20, count: SkillReview.maxReadSize + 1))
        #expect(!SkillServers.codexConfig(home: home.root).complete)
    }
}

/// Amp: mcpServers in SKILL.md's front matter, else an mcp.json beside it.
@Suite struct SkillServersAmpTests {
    static let skill = """
    ---
    name: demo
    description: >
      The demo skill, described
      over two lines.
    mcpServers:
      docs:
        url: https://mcp.example.com/mcp
      tool:
        command: npx
        args: ["-y", "tool@1.2.3"]
        includeTools:
          - search
    ---
    Use it well.
    """

    /// Covers AE8.
    @Test func frontMatterServersAreRead() throws {
        let fixture = try SkillFixture(skill: Self.skill)
        let servers = fixture.servers
        #expect(servers.amp.map(\.name) == ["docs", "tool"])
        #expect(servers.amp.first?.url == "https://mcp.example.com/mcp" && servers.amp.first?.transport == .http)
        #expect(servers.amp.last?.command == "npx" && servers.amp.last?.args == ["-y", "tool@1.2.3"])
        #expect(servers.ampFile == "SKILL.md" && servers.unread.isEmpty && !servers.frontMatterUnread)
        #expect(servers.frontMatterServersRead)
        let line = try #require(servers.lines(choice: .skip, start: .on, codex: .init(), trigger: "$demo").first)
        #expect(line.agent == "Amp")
        #expect(line.text.hasPrefix("Amp, from SKILL.md: “docs” connects to https://mcp.example.com/mcp; “tool” runs the program `npx -y tool@1.2.3`."))
        #expect(line.text.contains("It connects to these, and starts any program among them, when it finds the skill, and shows their tools once the skill loads."))
    }

    @Test func aBlockListOfArgumentsIsRead() throws {
        let skill = "---\nname: demo\ndescription: Demo.\nmcpServers:\n  tool:\n    command: uvx\n    args:\n    - tool==1.0\n    - --stdio\n---\n"
        let servers = try SkillFixture(skill: skill).servers
        #expect(servers.amp.first?.args == ["tool==1.0", "--stdio"] && servers.unread.isEmpty)
    }

    @Test(arguments: [
        "mcpServers:\n  tool: {command: npx}\n",
        "mcpServers:\n  tool:\n    command: npx\n    args: [-y, tool]\n",
        "mcpServers:\n  tool:\n    args: [\"x\"]\n",
        "mcpServers:\n  \"tool\":\n    command: npx\n",
        "mcpServers: {}\n",
        "mcpServers:\n",
        "mcpServers:\n  - command: npx\n",
    ])
    func serversItCanNotReadAreUnread(_ block: String) throws {
        let servers = try SkillFixture(skill: "---\nname: demo\ndescription: Demo.\n" + block + "---\n").servers
        #expect(servers.unread.map(\.file) == ["SKILL.md"], "\(block)")
        #expect(!servers.frontMatterServersRead)
        let line = try #require(servers.lines(choice: .skip, start: .on, codex: .init(), trigger: "$demo").first { $0.agent == "Amp" })
        #expect(line.text.contains("could not read every entry in SKILL.md"))
    }

    @Test func aJSONMapInTheFrontMatterIsRead() throws {
        let skill = "---\nname: demo\ndescription: Demo.\nmcpServers: {\"docs\": {\"url\": \"https://mcp.example.com/mcp\"}}  # one server\n---\n"
        #expect(try SkillFixture(skill: skill).servers.amp.map(\.name) == ["docs"])
    }

    @Test func aSiblingMCPJSONIsReadAndLosesToTheFrontMatter() throws {
        let alone = try SkillFixture().write("mcp.json", #"{"tool": {"command": "node", "args": ["server.js"]}}"#)
        #expect(alone.servers.amp.map(\.command) == ["node"] && alone.servers.ampFile == "mcp.json")
        let wrapped = try SkillFixture().write("mcp.json", #"{"mcpServers": {"docs": {"url": "https://mcp.example.com/mcp"}}}"#)
        #expect(wrapped.servers.amp.map(\.name) == ["docs"] && wrapped.servers.ampIgnored == nil)

        let both = try SkillFixture(skill: Self.skill).write("mcp.json", #"{"other": {"command": "node"}}"#)
        let servers = both.servers
        #expect(servers.amp.map(\.name) == ["docs", "tool"] && servers.ampFile == "SKILL.md" && servers.ampIgnored == "mcp.json")
        let line = try #require(servers.lines(choice: .skip, start: .on, codex: .init(), trigger: "$demo").first)
        #expect(line.text.contains("Amp uses SKILL.md's mcpServers and ignores mcp.json."))
    }

    @Test func aBrokenMCPJSONIsUnread() throws {
        let fixture = try SkillFixture().write("mcp.json", #"{"tool": {"command": "node"}, "tool": {"command": "evil"}}"#)
        #expect(fixture.servers.amp.isEmpty && fixture.servers.unread.map(\.file) == ["mcp.json"])
        #expect(fixture.review.flags.contains { $0.level == .warning && $0.file == "mcp.json" && $0.text.contains("could not read every MCP server entry") })
    }

    /// R5 and R18: Amp's own line in "What it may do", and a warning for a server that runs a program.
    @Test func whatItMayDoAndWorthALookNameAmp() throws {
        let review = try SkillFixture(skill: Self.skill).write("scripts/run.sh", "#!/bin/sh\necho hi\n", executable: true).review
        #expect(review.capabilities.contains("Amp connects to the MCP servers it declares, and starts any program among them, when it finds the skill."))
        #expect(!review.capabilities.contains("Asks for MCP servers."))
        #expect(review.capabilities.contains("Brings 1 file that can run (scripts or programs)."), "\(review.capabilities)")
        let flags = review.flags.filter { $0.text.contains("Amp starts it") }
        #expect(flags.map(\.text) == ["Declares an MCP server, “tool”, that runs a program. Amp starts it when it finds the skill."])
        #expect(flags.first?.file == "SKILL.md" && flags.first?.level == .warning)

        let urlOnly = try SkillFixture(skill: "---\nname: demo\ndescription: Demo.\nmcpServers:\n  docs:\n    url: https://x.example/mcp\n---\n").review
        #expect(!urlOnly.flags.contains { $0.text.contains("Amp starts it") })
        #expect(urlOnly.capabilities.contains { $0.hasPrefix("Amp connects") })
        #expect(!(try SkillFixture().review.capabilities.contains { $0.hasPrefix("Amp connects") }))
    }

    /// Forms that can bring in keys the review doesn't see; a block scalar or a flow list elsewhere can't.
    @Test func frontMatterFormsItDoesNotReadAreFlagged() throws {
        for block in ["base: &base\n  x: 1\nother:\n  <<: *base\n", "? hooks\n: x\n", "tags: !!set\n  a: null\n", "{hooks: x}\n"] {
            let review = try SkillFixture(skill: "---\nname: demo\ndescription: Demo.\n" + block + "---\n").review
            #expect(review.servers.frontMatterUnread, "\(block)")
            #expect(review.flags.contains { $0.file == "SKILL.md" && $0.text == "SKILL.md's front matter uses YAML forms Next Term does not read. Agents may read keys this review doesn't show." })
        }
        let usual = "---\nname: demo\ndescription: |\n  Two\n  lines.\nallowed-tools: [Read, Grep]\nmetadata:\n  \"version\": 1.0\n  tags: [a, b]\n---\n"
        let review = try SkillFixture(skill: usual).review
        #expect(!review.servers.frontMatterUnread && !review.flags.contains { $0.text.contains("front matter") })
    }
}

/// The Claude Code line follows the choice and the start state.
@Suite struct SkillServersClaudeTests {
    static func servers(_ extra: String = "") throws -> SkillServers {
        try SkillFixture().claudeManifest("writing-helper", extra)
            .write(".mcp.json", #"{"mcpServers": {"docs": {"command": "node", "args": ["server.js"]}, "linear": {"type": "http", "url": "https://mcp.linear.app/mcp", "headersHelper": "./token.sh"}}}"#)
            .servers
    }

    static func line(_ servers: SkillServers, _ choice: SkillInstall.ClaudeLink, _ start: SkillPackage.Start,
                     clashes: [SkillInstall.Clash] = [], readsShared: Bool = false) throws -> String {
        let lines = servers.lines(choice: choice, start: start, clashes: clashes, readsShared: readsShared, codex: .init(), trigger: "$demo")
        return try #require(lines.first { $0.agent == "Claude Code" }).text
    }

    @Test func eachChoiceAndStartState() throws {
        let servers = try Self.servers()
        #expect(servers.claude.map(\.name) == ["docs", "linear"])
        let lead = "Claude Code, from .mcp.json: “docs” runs the program `node server.js`; “linear” connects to https://mcp.linear.app/mcp, and runs `./token.sh` for its headers. "
        #expect(try Self.line(servers, .skip, .on) == lead + "Left out of Claude Code, so these don't start there.")
        #expect(try Self.line(servers, .link, .on)
                == lead + "If you add it to Claude Code, it starts these every time Claude Code opens, without asking you, until you turn it off in Claude Code's /plugin.")
        #expect(try Self.line(servers, .link, .offByManifest)
                == lead + "Claude Code adds the plugin turned off, only because its manifest says so. These start once it is on.")
        #expect(try Self.line(servers, .link, .offByKey)
                == lead + "Your Claude Code settings keep the plugin off (“writing-helper@skills-dir”: false), so these don't start until you turn it on in /plugin.")
        #expect(try Self.line(servers, .skip, .offByKey).hasSuffix("Left out of Claude Code, so these don't start there."))
    }

    /// Hand check H7: a plugin of the same name installed for the user is the one Claude Code keeps, even
    /// turned off, so these don't start; one installed for a project leaves them starting elsewhere.
    @Test func anInstalledPluginOfTheSameNameKeepsTheseFromStarting() throws {
        let servers = try Self.servers()
        let installed = SkillInstall.Clash(kind: .installed, name: "writing-helper", text: "")
        #expect(try Self.line(servers, .link, .on, clashes: [installed])
                .hasSuffix(" Claude Code keeps your installed “writing-helper”, so these don't start there (as of October 2026)."))
        #expect(try Self.line(servers, .skip, .on, clashes: [installed]).hasSuffix("Left out of Claude Code, so these don't start there."))
        let project = SkillInstall.Clash(kind: .installedForProject, name: "writing-helper", text: "")
        #expect(try Self.line(servers, .link, .on, clashes: [project]).hasSuffix("until you turn it off in Claude Code's /plugin."))
    }

    /// ~/.claude/skills linked to the shared folder: Claude Code reads the folder there whatever the choice.
    @Test func aLinkedClaudeFolderStartsTheseWhateverTheChoice() throws {
        let servers = try Self.servers()
        let shared = "Claude Code reads ~/.agents/skills through your linked ~/.claude/skills, so it starts these every time Claude Code "
            + "opens, without asking you, until you turn it off in Claude Code's /plugin."
        for choice in [SkillInstall.ClaudeLink.skip, .link] {
            let text = try Self.line(servers, choice, .on, readsShared: true)
            #expect(text.hasSuffix(shared) && !text.contains("Left out"), "\(choice)")
        }
        #expect(try Self.line(servers, .skip, .offByKey, readsShared: true).hasSuffix("so these don't start until you turn it on in /plugin."))
    }

    @Test func theStartStateComesFromTheKeyThenTheManifest() throws {
        let on = try #require(try SkillFixture().claudeManifest().package?.claude)
        let off = try #require(try SkillFixture().claudeManifest("demo", #""defaultEnabled": false"#).package?.claude)
        #expect(on.start(key: nil) == .on && off.start(key: nil) == .offByManifest)
        #expect(off.start(key: true) == .on && on.start(key: false) == .offByKey && off.start(key: false) == .offByKey)
    }

    /// Hand check H2: without a usable name, Claude Code loads only the plain skill.
    @Test func aPluginWithoutAUsableNameStartsNothingForNow() throws {
        let fixture = try SkillFixture().write(".claude-plugin/plugin.json", #"{"description": "No name."}"#)
            .write(".mcp.json", #"{"mcpServers": {"docs": {"command": "node"}}}"#)
        let text = try Self.line(fixture.servers, .link, .on)
        #expect(text.contains("its plugin.json has no usable name, so these don't start there (as of October 2026). A later version may start them."))
    }

    @Test func bundlesAndLongListsAreSaid() throws {
        let fixture = try SkillFixture().claudeManifest("demo", #""mcpServers": ["./server.mcpb", "https://example.com/tool.dxt"]"#)
        let text = try Self.line(fixture.servers, .skip, .on)
        #expect(text.contains("“server” is an MCP bundle at ./server.mcpb, which Claude Code unpacks and runs"))
        #expect(text.contains("“tool” is an MCP bundle from https://example.com/tool.dxt, which Claude Code downloads, unpacks and runs"))

        let many = (1...30).map { "\"s\($0)\": {\"command\": \"node\"}" }.joined(separator: ", ")
        let long = try SkillFixture().claudeManifest().write(".mcp.json", "{\"mcpServers\": {\(many)}}")
        #expect(try Self.line(long.servers, .skip, .on).contains("; and 10 more. Left out"))
    }

    /// Text from a skill's files stays on one line, hidden characters written out.
    @Test func namesAndAddressesStayOnOneLine() throws {
        let fixture = try SkillFixture().claudeManifest()
            .write(".mcp.json", "{\"mcpServers\": {\"a\\nb\": {\"url\": \"https://x.example/\\u2028mcp\"}}}")
            .write("agents/openai.yaml", "dependencies:\n  tools:\n    - type: mcp\n      value: \"c\\u2029d\"\n      url: \"https://y.example/\\nmcp\"\n")
        let lines = fixture.servers.lines(choice: .link, start: .on, codex: .init(), trigger: "$demo")
        #expect(lines.map(\.agent) == ["Claude Code", "Codex"])
        for line in lines {
            #expect(!line.text.contains("\n") && !line.text.contains("\u{2028}") && !line.text.contains("\u{2029}"), "\(line.text)")
            #expect(line.preview.allSatisfy { !$0.contains("\n") && !$0.contains("\u{2028}") })
        }
        #expect(lines[0].text.contains("“a⟦U+000A⟧b” connects to https://x.example/⟦U+2028⟧mcp"))
        #expect(lines[1].preview.first == "[mcp_servers.\"c⟦U+2029⟧d\"]")
    }

    @Test func theRowListsItsFilesAndEndsWithWhatNextTermDoes() throws {
        let fixture = try SkillFixture(skill: SkillServersAmpTests.skill).claudeManifest()
            .write(".mcp.json", #"{"mcpServers": {"docs": {"command": "node"}}}"#)
            .write("agents/openai.yaml", SkillServersCodexTests.documented)
        let servers = fixture.servers
        #expect(servers.files == [".mcp.json", "agents/openai.yaml", "SKILL.md"])
        let lines = servers.lines(choice: .skip, start: .on, codex: .init(), trigger: "$demo")
        #expect(lines.map(\.agent) == ["Claude Code", "Codex", "Amp"])
        #expect(SkillServers.closing == "Next Term adds none of these. Each agent decides as above.")
        #expect(SkillServers.codexTrigger(name: "demo", package: fixture.package) == "$demo:demo")
        #expect(SkillServers.codexTrigger(name: "demo", package: nil) == "$demo")
    }
}
