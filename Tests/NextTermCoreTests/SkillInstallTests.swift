import Foundation
import Testing
@testable import NextTermCore

@Suite struct SkillInstallTests {
    let home: String
    let staged: String
    let ready: String
    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("nt-install-\(UUID().uuidString)").path
        staged = home + "/staging/skill-creator"
        ready = home + "/ready/skill-creator"
        try FileManager.default.createDirectory(atPath: staged, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.claude/skills", withIntermediateDirectories: true)
    }

    func skill(_ root: String, _ name: String, body: String = "Body") throws {
        let folder = (home as NSString).appendingPathComponent("\(root)/\(name)")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: The \(name) skill.\n---\n\(body)\n".write(toFile: folder + "/SKILL.md", atomically: true, encoding: .utf8)
    }

    @Test func aNewSkillGoesInTheSharedFolderWithALinkForClaude() {
        let plan = SkillInstall.plan(name: "skill-creator", staged: staged, staging: ready, inventory: SkillInventory.scan(home: home), claude: .link, package: nil, sameSource: false)
        #expect(plan.existing == .none)
        #expect(plan.steps == [.copy(from: staged, to: ready), .move(from: ready, to: home + "/.agents/skills/skill-creator"),
                               .link(at: home + "/.claude/skills/skill-creator", to: home + "/.agents/skills/skill-creator")])
        #expect(plan.agents == [.claudeCode, .codex, .commandCode])

        let noLink = SkillInstall.plan(name: "skill-creator", staged: staged, staging: ready, inventory: SkillInventory.scan(home: home), claude: .skip, package: nil, sameSource: false)
        #expect(noLink.steps.count == 2 && noLink.agents == [.codex, .commandCode])
    }

    /// The same name made by hand in two agents: Replace moves both away; nothing is installed beside them.
    @Test func anExistingNameIsAConflictThatReplaceClears() throws {
        try skill(".commandcode/skills", "skill-creator", body: "hand-made")
        try skill(".claude/skills", "skill-creator", body: "another")
        let plan = SkillInstall.plan(name: "skill-creator", staged: staged, staging: ready, inventory: SkillInventory.scan(home: home), claude: .link, package: nil, sameSource: false)
        #expect(plan.existing == .conflict && plan.replaced.count == 2)
        // The new copy is made first; only then do the others go, and it takes their place.
        #expect(plan.steps.first == .copy(from: staged, to: ready))
        #expect(plan.steps.dropFirst().prefix(2).allSatisfy { if case .trash = $0 { return true }; return false })
        #expect(plan.steps.contains(.link(at: home + "/.claude/skills/skill-creator", to: home + "/.agents/skills/skill-creator")))
    }

    /// Installed before from the same source, linked for Claude: an update that keeps the link.
    @Test func theSameSourceIsAnUpdateAndKeepsTheLink() throws {
        try skill(".agents/skills", "skill-creator", body: "v1")
        try FileManager.default.createSymbolicLink(atPath: home + "/.claude/skills/skill-creator", withDestinationPath: "../../.agents/skills/skill-creator")
        let plan = SkillInstall.plan(name: "skill-creator", staged: staged, staging: ready, inventory: SkillInventory.scan(home: home), claude: .link, package: nil, sameSource: true)
        #expect(plan.existing == .update && plan.keptLink != nil)
        #expect(plan.steps == [.copy(from: staged, to: ready), .trash(home + "/.agents/skills/skill-creator"),
                               .move(from: ready, to: home + "/.agents/skills/skill-creator")])
        // From another source, the same files are a conflict.
        #expect(SkillInstall.plan(name: "skill-creator", staged: staged, staging: ready, inventory: SkillInventory.scan(home: home), claude: .link, package: nil, sameSource: false).existing == .conflict)
    }

    @Test func foldersNextTermDoesNotOwnAreNamedNotTouched() throws {
        try skill(".claude/skills/synced", "skill-creator")
        try skill(".codex/skills/.system", "skill-creator")
        let project = home + "/code/app"
        try skill("code/app/.claude/skills", "skill-creator")
        let plan = SkillInstall.plan(name: "skill-creator", staged: staged, staging: ready, inventory: SkillInventory.scan(home: home), claude: .link, package: nil,
                                     sameSource: false, projects: [project])
        #expect(plan.existing == .none && plan.untouched.count == 3)
        #expect(!plan.steps.contains { if case .trash = $0 { return true }; return false })
    }

    @Test func aNameThatHidesAClaudeCommandIsNamed() {
        let plan = SkillInstall.plan(name: "usage", staged: staged, staging: ready, inventory: SkillInventory.scan(home: home), claude: .link, package: nil, sameSource: false)
        #expect(plan.untouched.contains { $0.contains("/usage") })
    }

    /// Something the inventory leaves out (a stray file) at the target is a conflict, not a surprise.
    @Test func aStrayFileAtTheTargetIsAConflict() throws {
        try FileManager.default.createDirectory(atPath: home + "/.agents/skills", withIntermediateDirectories: true)
        try "stray".write(toFile: home + "/.agents/skills/skill-creator", atomically: true, encoding: .utf8)
        let plan = SkillInstall.plan(name: "skill-creator", staged: staged, staging: ready, inventory: SkillInventory.scan(home: home), claude: .skip, package: nil, sameSource: false)
        #expect(plan.existing == .conflict && plan.steps.dropFirst().first == .trash(home + "/.agents/skills/skill-creator"))
    }

    /// npx skills links a skill from ~/.commandcode/skills too: an update keeps that link.
    @Test func npxLinksStayAnUpdate() throws {
        try skill(".agents/skills", "skill-creator", body: "v1")
        try FileManager.default.createDirectory(atPath: home + "/.commandcode/skills", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/.commandcode/skills/skill-creator", withDestinationPath: "../../.agents/skills/skill-creator")
        let plan = SkillInstall.plan(name: "skill-creator", staged: staged, staging: ready, inventory: SkillInventory.scan(home: home), claude: .skip, package: nil, sameSource: true)
        #expect(plan.existing == .update && plan.keptOtherLinks.count == 1)
        #expect(!plan.steps.contains(.trash(home + "/.commandcode/skills/skill-creator")))
        // Removing it takes that link too, so nothing is left pointing at nothing.
        #expect(SkillInstall.removal(name: "skill-creator", inventory: SkillInventory.scan(home: home)).contains(.trash(home + "/.commandcode/skills/skill-creator")))
    }

    @Test func removalTakesTheSharedCopyAndItsClaudeLinkOnly() throws {
        try skill(".agents/skills", "skill-creator")
        try FileManager.default.createSymbolicLink(atPath: home + "/.claude/skills/skill-creator", withDestinationPath: "../../.agents/skills/skill-creator")
        try skill(".codex/skills", "skill-creator", body: "hand-made")
        let steps = SkillInstall.removal(name: "skill-creator", inventory: SkillInventory.scan(home: home))
        #expect(steps == [.trash(home + "/.claude/skills/skill-creator"), .trash(home + "/.agents/skills/skill-creator")])
    }
}

/// Claude Code's link to a skill folder that is also a Claude Code plugin: what the review offers first,
/// what each choice does on disk, and the plugins its name meets. Nothing here writes Claude Code's files.
@Suite struct SkillClaudeLinkTests {
    let home: String
    let staged: String
    let ready: String
    let link: String
    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("nt-claude-link-\(UUID().uuidString)").path
        staged = home + "/staging/writing-helper"
        ready = home + "/ready/writing-helper"
        link = home + "/.claude/skills/writing-helper"
        try FileManager.default.createDirectory(atPath: staged, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.claude/skills", withIntermediateDirectories: true)
    }

    static let server = #"{"mcpServers": {"docs": {"command": "node", "args": ["server.js"]}}}"#
    static let hooks = #"{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "./start.sh"}]}]}}"#

    func write(_ path: String, _ text: String) throws {
        let full = (home as NSString).appendingPathComponent(path)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: full, atomically: true, encoding: .utf8)
    }

    /// A skill folder in `folder` (under the home), a Claude Code plugin named `plugin` unless nil.
    func skill(_ folder: String, plugin: String?, manifest: String = "", body: String = "Body", _ files: [String: String] = [:]) throws {
        let name = (folder as NSString).lastPathComponent
        try write(folder + "/SKILL.md", "---\nname: \(name)\ndescription: The \(name) skill.\n---\n\(body)\n")
        if let plugin { try write(folder + "/.claude-plugin/plugin.json", "{\"name\": \"\(plugin)\"" + (manifest.isEmpty ? "" : ", " + manifest) + "}") }
        for (path, text) in files { try write(folder + "/" + path, text) }
    }

    /// The download, read as the review reads it.
    func stage(plugin: String? = "writing-helper", manifest: String = "", body: String = "Body", _ files: [String: String] = [:]) throws -> SkillPackage? {
        try skill("staging/writing-helper", plugin: plugin, manifest: manifest, body: body, files)
        return SkillPackage.read(folder: staged, folderName: "writing-helper")
    }

    /// Installed before in the shared folder, and linked for Claude Code unless `linked` is false.
    @discardableResult
    func install(plugin: String? = "writing-helper", linked: Bool = true, _ files: [String: String] = [:]) throws -> SkillPackage? {
        try skill(".agents/skills/writing-helper", plugin: plugin, body: "v1", files)
        if linked { try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "../../.agents/skills/writing-helper") }
        return SkillPackage.read(folder: home + "/.agents/skills/writing-helper", folderName: "writing-helper")
    }

    func plan(_ claude: SkillInstall.ClaudeLink, _ package: SkillPackage?, facts: SkillClaudeSettings.Snapshot = .init(),
              ticked: [String: String] = [:]) -> SkillInstallPlan {
        SkillInstall.plan(name: "writing-helper", staged: staged, staging: ready, inventory: SkillInventory.scan(home: home), claude: claude,
                          package: package, facts: facts, ticked: ticked, sameSource: true)
    }

    func defaultLink(_ package: SkillPackage?, installed: SkillPackage? = nil, facts: SkillClaudeSettings.Snapshot = .init(),
                     ticked: [String: String] = [:]) -> SkillInstall.ClaudeLink {
        let shown = plan(.skip, package, facts: facts, ticked: ticked)
        return SkillInstall.defaultClaudeLink(shown, package: package, installed: installed, facts: facts)
    }

    func makesLink(_ plan: SkillInstallPlan) -> Bool { plan.steps.contains { if case .link = $0 { return true }; return false } }

    // MARK: the default (the High-Level Technical Design's table)

    /// AE1: a plugin with a server and hooks is left out of Claude Code by default.
    @Test func aPluginThatRunsSomethingIsLeftOut() throws {
        let package = try stage([".mcp.json": Self.server, "hooks/hooks.json": Self.hooks])
        #expect(defaultLink(package) == .skip)
        let left = plan(.skip, package)
        #expect(!makesLink(left) && !left.agents.contains(.claudeCode) && left.agents == [.codex, .commandCode])
        let added = plan(.link, package)
        #expect(makesLink(added) && added.agents.contains(.claudeCode))
    }

    /// AE5: a manifest with only allowlisted keys and no parts is linked, as the checkbox always was; a
    /// plain skill too. `defaultEnabled: false` alone does not make a plugin that runs something safe.
    @Test func aPluginThatRunsNothingIsLinked() throws {
        #expect(defaultLink(try stage(manifest: #""skills": ["./"]"#)) == .link)
        #expect(defaultLink(try stage(plugin: nil)) == .link)
        let offByManifest = try stage(manifest: #""defaultEnabled": false"#, [".mcp.json": Self.server])
        #expect(offByManifest?.claude?.defaultEnabled == false && defaultLink(offByManifest) == .skip)
    }

    /// Row 1: the user turned the plugin off in /plugin. Claude Code loads nothing from it until it is
    /// turned on there, so it is linked, with or without a link already, clash or not; nothing is written.
    @Test func theUsersKeyFalseLinksIt() throws {
        let package = try stage([".mcp.json": Self.server])
        let off = SkillClaudeSettings.Snapshot(values: ["writing-helper@skills-dir": false], synced: [.init(name: "writing-helper", displayName: nil)])
        #expect(defaultLink(package, facts: off) == .link)
        let on = SkillClaudeSettings.Snapshot(values: ["writing-helper@skills-dir": true])
        #expect(defaultLink(package, facts: on) == .skip)
        let installed = try install()
        #expect(defaultLink(package, installed: installed, facts: off) == .link)
    }

    /// Row 2 and AE6: an update keeps its link while it declares the same parts; a new server takes it away.
    @Test func anUpdateKeepsItsLinkUntilItsPartsChange() throws {
        let installed = try install([".mcp.json": Self.server, "hooks/hooks.json": Self.hooks])
        let same = try stage(manifest: #""version": "2.0.0", "description": "Newer.""#, body: "New text",
                             [".mcp.json": Self.server, "hooks/hooks.json": Self.hooks])
        #expect(defaultLink(same, installed: installed) == .link)
        let kept = plan(.link, same)
        #expect(kept.keptLink != nil && !makesLink(kept) && !kept.steps.contains(.trash(link)) && kept.agents.contains(.claudeCode))

        let more = try stage([".mcp.json": Self.server, "hooks/hooks.json": Self.hooks, ".lsp.json": #"{"go": {"command": "gopls"}}"#])
        #expect(defaultLink(more, installed: installed) == .skip)
        // Left out, the link goes before the new copy moves into place; Undo puts it back.
        let left = plan(.skip, more)
        let trash = try #require(left.steps.firstIndex(of: .trash(link)))
        let move = try #require(left.steps.firstIndex(of: .move(from: ready, to: home + "/.agents/skills/writing-helper")))
        #expect(trash < move && !left.agents.contains(.claudeCode) && !makesLink(left))
    }

    /// AE6 as the self-test reviews it: the same folder again over its linked install. The link stays by
    /// default, the popup offers to remove it, and the line beside the popup says it stays linked and what it
    /// starts, opening with ⚠︎ since it starts programs by itself. Left out, the line says the link goes.
    @Test func anUpdateWithTheSamePartsKeepsItsLinkAndOffersToRemoveIt() throws {
        let files = [".mcp.json": Self.server, "hooks/hooks.json": Self.hooks]
        let installed = try install(files)
        let package = try stage(files)
        let plugin = try #require(package?.claude)
        let shown = plan(.skip, package)
        let preset = SkillInstall.defaultClaudeLink(shown, package: package, installed: installed, facts: .init())
        #expect(shown.keptLink != nil && shown.clashes.isEmpty && preset == .link)
        let items = SkillReviewText.choiceItems(count: 1, removesLink: shown.keptLink != nil)
        #expect(items == ["Remove it from Claude Code", "Add it to Claude Code as a plugin"])
        let start = plugin.start(key: nil)
        let warns = SkillReviewText.choiceWarns(plugin, start: start, clashes: shown.clashes)
        func summary(_ choice: SkillInstall.ClaudeLink) -> String {
            let clause = SkillReviewText.choiceLine(skill: "writing-helper", plugin: plugin, choice: choice, start: start,
                                                    keptLink: true, clashes: shown.clashes)
            return SkillReviewText.choiceSummary([clause], choice: choice, warns: warns)
        }
        #expect(warns && summary(.link) == "⚠︎ writing-helper: stays linked. It starts what its review lists every time Claude Code opens, "
            + "without asking you: 1 MCP server and 1 hook.")
        #expect(summary(.skip).hasPrefix("writing-helper: its link is removed, so nothing in it starts in Claude Code."))
    }

    /// A changed hook command, a new key outside the allowlist or a new program in bin/ are new parts.
    @Test(arguments: [
        ["hooks/hooks.json": #"{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "./other.sh"}]}]}}"#],
        [".claude-plugin/plugin.json": #"{"name": "writing-helper", "userConfig": {"token": {"type": "string"}}}"#],
        ["bin/tidy": "#!/bin/sh\n"],
    ])
    func newPartsAreNotTheSame(_ files: [String: String]) throws {
        let installed = try install(["hooks/hooks.json": Self.hooks])
        let package = try stage(["hooks/hooks.json": Self.hooks].merging(files) { $1 })
        #expect(defaultLink(package, installed: installed) == .skip)
    }

    /// With no link today, the same parts don't make a link: a plugin that runs something stays out.
    @Test func samePartsWithoutALinkStayOut() throws {
        let installed = try install(linked: false, [".mcp.json": Self.server])
        #expect(defaultLink(try stage([".mcp.json": Self.server]), installed: installed) == .skip)
    }

    /// Anything unread counts as running (KTD13), and an installed copy that can't be read is never the same.
    @Test func unreadFilesLeaveItOut() throws {
        let installed = try install([".mcp.json": Self.server])
        let broken = try stage([".mcp.json": "{\"mcpServers\": "])
        #expect(broken?.claude?.unread.isEmpty == false && defaultLink(broken, installed: installed) == .skip)
        try write(".agents/skills/writing-helper/.mcp.json", "{")
        let unreadable = SkillPackage.read(folder: home + "/.agents/skills/writing-helper", folderName: "writing-helper")
        #expect(defaultLink(try stage([".mcp.json": Self.server]), installed: unreadable) == .skip)
    }

    @Test func severalPluginFoldersTakeTheSafestDefault() {
        #expect(SkillInstall.ClaudeLink.safest([.link, .skip, .link]) == .skip)
        #expect(SkillInstall.ClaudeLink.safest([.link, .link]) == .link)
        #expect(SkillInstall.ClaudeLink.safest([]) == .link)
    }

    // MARK: what each choice does

    /// A plain skill left out keeps the link it has, as an unticked box always did.
    @Test func aPlainSkillLeftOutKeepsItsLink() throws {
        try install(plugin: nil)
        let plan = plan(.skip, try stage(plugin: nil))
        #expect(plan.keptLink != nil && !plan.steps.contains(.trash(link)) && plan.agents.contains(.claudeCode))
    }

    /// Only a link looks for something in the way in Claude Code's folder.
    @Test func onlyALinkLooksInClaudesFolder() throws {
        try write(".claude/skills/writing-helper", "A stray file.")
        let package = try stage([".mcp.json": Self.server])
        let linked = plan(.link, package)
        #expect(linked.existing == .conflict && linked.steps.contains(.trash(link)))
        let left = plan(.skip, package)
        #expect(left.existing == .none && !left.steps.contains(.trash(link)))
    }

    /// No choice writes anything but the skill folders: never Claude Code's settings.
    @Test func noPlanWritesOutsideTheSkillFolders() throws {
        try install([".mcp.json": Self.server])
        try write(".claude/settings.json", #"{"enabledPlugins": {"writing-helper@skills-dir": false}}"#)
        let facts = SkillClaudeSettings.snapshot(home: home, keys: ["writing-helper@skills-dir"])
        let places = [staged, ready, home + "/.agents/skills/", home + "/.claude/skills/"]
        for package in [try stage([".mcp.json": Self.server]), try stage(plugin: nil)] {
            for choice in [SkillInstall.ClaudeLink.link, .skip] {
                for step in plan(choice, package, facts: facts).steps {
                    let paths: [String]
                    switch step {
                    case .trash(let path): paths = [path]
                    case .copy(_, let to): paths = [to]
                    case .link(let at, _): paths = [at]
                    case .move(_, let to): paths = [to]
                    case .lockEntry(let path, _, _), .recordEntry(let path, _, _): paths = [path]
                    }
                    #expect(paths.allSatisfy { path in places.contains { path.hasPrefix($0) } }, "\(step)")
                }
            }
        }
    }

    /// A link for Claude Code is made only where Claude Code is: ~/.claude there, and ~/.claude/skills a folder
    /// of its own. A missing ~/.claude/skills is still made, as a link in it always has been.
    @Test func claudeCodeIsAvailableOnlyWhereItIs() throws {
        #expect(SkillInventory.scan(home: home).claudeAvailable)
        let bare = FileManager.default.temporaryDirectory.appendingPathComponent("nt-no-claude-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: bare + "/.agents/skills", withIntermediateDirectories: true)
        let none = SkillInventory.scan(home: bare)
        #expect(!none.claudeAvailable && !none.claudeReadsShared)
        try FileManager.default.createDirectory(atPath: bare + "/.claude", withIntermediateDirectories: true)
        #expect(SkillInventory.scan(home: bare).claudeAvailable)
    }

    /// ~/.claude/skills linked to the shared folder as a whole: Claude Code reads the folder there, so no
    /// choice leaves it out, and the plan names Claude Code with no link of its own to make or remove.
    @Test func aLinkedClaudeFolderReadsTheSharedFolder() throws {
        try FileManager.default.removeItem(atPath: home + "/.claude/skills")
        try FileManager.default.createDirectory(atPath: home + "/.agents/skills", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/.claude/skills", withDestinationPath: "../.agents/skills")
        let inventory = SkillInventory.scan(home: home)
        #expect(inventory.claudeReadsShared && !inventory.claudeAvailable)
        let package = try stage([".mcp.json": Self.server])
        let left = plan(.skip, package)
        #expect(left.agents.contains(.claudeCode) && !makesLink(left) && !left.linksClaude)
    }

    // MARK: clashes

    /// AE4: a plugin synced from claude.ai of the same name, compared as Claude Code compares names.
    @Test func aSyncedPluginOfTheSameNameIsAWarningAndLeavesItOut() throws {
        let package = try stage(manifest: #""skills": ["./"]"#)
        for synced in ["writing-helper", "Writing-Helper"] {
            let facts = SkillClaudeSettings.Snapshot(synced: [.init(name: synced, displayName: nil)])
            let plan = plan(.skip, package, facts: facts)
            #expect(plan.clashes.map(\.kind) == [.synced] && plan.clashes.allSatisfy(\.warning))
            let text = "You have a plugin named “\(synced)” from claude.ai. Added, this folder replaces it in Claude Code sessions, "
                + "and Claude Code reports yours as not loaded."
            #expect(plan.untouched.contains(text))
            #expect(defaultLink(package, facts: facts) == .skip, "even though it runs nothing")
        }
    }

    /// AE4: a look-alike of a name or a display name.
    @Test func aLookalikeIsAWarningAndLeavesItOut() throws {
        let package = try stage(manifest: #""skills": ["./"]"#)
        let underscore = SkillClaudeSettings.Snapshot(synced: [.init(name: "writing_helper", displayName: nil)])
        let plan = plan(.skip, package, facts: underscore)
        #expect(plan.clashes.map(\.kind) == [.lookalike] && plan.clashes.first?.warning == true)
        #expect(plan.untouched.contains("Its plugin name looks like your plugin “writing_helper” from claude.ai, so it could be mistaken for it."))
        #expect(defaultLink(package, facts: underscore) == .skip)
        let display = SkillClaudeSettings.Snapshot(synced: [.init(name: "wh", displayName: "Writing Helper")])
        #expect(self.plan(.skip, package, facts: display).clashes.map(\.kind) == [.lookalike])
        let installed = SkillClaudeSettings.Snapshot(installed: [.init(name: "writing.helper", marketplace: "m", scopes: ["user"], enabled: true)])
        #expect(self.plan(.skip, package, facts: installed).untouched.contains("Its plugin name looks like your plugin “writing.helper” from “m”, "
            + "so it could be mistaken for it."))
        let unrelated = SkillClaudeSettings.Snapshot(synced: [.init(name: "reading-helper", displayName: "Reader")])
        #expect(self.plan(.skip, package, facts: unrelated).clashes.isEmpty && defaultLink(package, facts: unrelated) == .link)
    }

    /// H7: installed for the user, on or off, Claude Code keeps that one; installed for a project, only there.
    @Test func installedPluginsGiveTheirNote() throws {
        let package = try stage([".mcp.json": Self.server])
        let user = "You have a plugin named “writing-helper” installed from “some-market”. Claude Code keeps that one, even turned off, "
            + "and won't load this folder as a plugin."
        for enabled in [true, false] {
            let facts = SkillClaudeSettings.Snapshot(installed: [.init(name: "writing-helper", marketplace: "some-market", scopes: ["user"], enabled: enabled)])
            let plan = plan(.skip, package, facts: facts)
            #expect(plan.clashes.map(\.kind) == [.installed] && plan.untouched.contains(user) && !plan.clashes[0].warning)
        }
        let project = SkillClaudeSettings.Snapshot(installed: [.init(name: "writing-helper", marketplace: "some-market", scopes: ["project", "local"], enabled: nil)])
        let text = "You have a plugin named “writing-helper” from “some-market”, installed for a project. In that project Claude Code keeps it; "
            + "elsewhere it loads this folder as a plugin."
        #expect(plan(.skip, package, facts: project).untouched.contains(text))
        #expect(plan(.skip, package, facts: project).clashes.map(\.kind) == [.installedForProject])
        #expect(defaultLink(try stage(manifest: #""skills": ["./"]"#), facts: project) == .skip)
    }

    /// Another folder Claude Code reads, or another ticked skill, with the same plugin name. The skill's
    /// own link does not count.
    @Test func anotherFolderOrTickedSkillWithThePluginName() throws {
        let package = try stage(manifest: #""skills": ["./"]"#)
        try install()
        #expect(plan(.skip, package).clashes.isEmpty && defaultLink(package) == .link)
        try skill(".claude/skills/other-helper", plugin: "Writing-Helper")
        let plan = plan(.skip, package)
        let text = "~/.claude/skills/other-helper is also a Claude Code plugin named “Writing-Helper”. Claude Code loads only one of them, "
            + "and turning one off in Claude Code's /plugin turns off both."
        #expect(plan.clashes.map(\.kind) == [.skillsDir] && plan.untouched.contains(text))
        #expect(defaultLink(package) == .skip)
        let ticked = self.plan(.skip, package, ticked: ["writing-helper": "writing-helper", "notes": "writing-helper"])
        #expect(ticked.untouched.contains { $0.hasPrefix("“notes”, also ticked here, is also a Claude Code plugin named “writing-helper”.") })
        #expect(ticked.clashes.count == 2)
    }

    /// A plain skill has no plugin, so no clash, whatever the user has.
    @Test func aPlainSkillHasNoClash() throws {
        let facts = SkillClaudeSettings.Snapshot(synced: [.init(name: "writing-helper", displayName: nil)])
        #expect(plan(.link, try stage(plugin: nil), facts: facts).clashes.isEmpty)
    }
}

/// What removal names as outliving a skill: servers another agent may have added for it, what open
/// sessions keep, and Claude Code's key the user set. Read only: no other app's file is changed.
@Suite struct SkillLeftoversTests {
    let home: String
    let folder: String
    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("nt-leftovers-\(UUID().uuidString)").path
        folder = home + "/.agents/skills/writing-helper"
        try FileManager.default.createDirectory(atPath: home + "/.claude/skills", withIntermediateDirectories: true)
    }

    static let linear = "dependencies:\n  tools:\n    - type: \"mcp\"\n      value: \"linear\"\n      description: \"Linear\"\n"
        + "      transport: \"streamable_http\"\n      url: \"https://mcp.linear.app/mcp\"\n"
    static let server = #"{"mcpServers": {"docs": {"command": "node", "args": ["server.js"]}}}"#
    static let hooks = #"{"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "./start.sh"}]}]}}"#
    static let codexLine = "Codex may have added the MCP server “linear” (https://mcp.linear.app/mcp) for this skill, in ~/.codex/config.toml. "
        + "It stays there, because you may use it for other things. Remove it there if you don't."
    static let pluginLine = "This includes its Claude Code plugin's MCP servers and hooks."

    func write(_ path: String, _ text: String) throws {
        let full = (home as NSString).appendingPathComponent(path)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: full, atomically: true, encoding: .utf8)
    }

    /// The installed copy, with `front` added to its front matter and `files` beside SKILL.md.
    func skill(front: String = "", _ files: [String: String] = [:]) throws {
        try write(".agents/skills/writing-helper/SKILL.md", "---\nname: writing-helper\ndescription: Helps you write.\n\(front)---\nBody\n")
        for (path, text) in files { try write(".agents/skills/writing-helper/" + path, text) }
    }

    func link() throws {
        try FileManager.default.createSymbolicLink(atPath: home + "/.claude/skills/writing-helper", withDestinationPath: "../../.agents/skills/writing-helper")
    }

    func leftovers() -> [String] {
        let front = (try? String(contentsOfFile: folder + "/SKILL.md", encoding: .utf8)).flatMap(SkillFrontMatter.parse)
        return SkillInstall.leftovers(frontMatter: front, folder: folder, home: home)
    }

    func codex(_ lines: [String]) -> [String] { lines.filter { $0.contains("Codex") } }

    // MARK: Codex

    /// AE11: a table with the dependency's address is named, with its file, and the config is not changed.
    @Test func aCodexServerWithTheSkillsAddressIsNamedAndStays() throws {
        try skill(["agents/openai.yaml": Self.linear])
        let config = "model = \"o3\"\n\n[mcp_servers.linear]\nurl = \"https://mcp.linear.app/mcp\"\n"
        try write(".codex/config.toml", config)
        #expect(leftovers() == [Self.codexLine])
        #expect(try String(contentsOfFile: home + "/.codex/config.toml", encoding: .utf8) == config)
    }

    /// Codex matches by address, never by name: a table of that name elsewhere is the user's own.
    @Test func aTableWithOnlyTheSameNameIsNotNamed() throws {
        try skill(["agents/openai.yaml": Self.linear])
        try write(".codex/config.toml", "[mcp_servers.linear]\nurl = \"https://example.com/linear\"\n")
        #expect(codex(leftovers()).isEmpty)
        try write(".codex/config.toml", "model = \"o3\"\n")
        #expect(codex(leftovers()).isEmpty)
        try FileManager.default.removeItem(atPath: home + "/.codex/config.toml")
        #expect(codex(leftovers()).isEmpty)
    }

    /// A table with the address under another name is named as the config names it; a program server by
    /// its command; several in one line.
    @Test func matchesAreNamedAsTheConfigNamesThem() throws {
        let tools = Self.linear + "    - type: mcp\n      value: local\n      transport: stdio\n      command: npx\n"
        try skill(["agents/openai.yaml": tools])
        try write(".codex/config.toml", "[mcp_servers.linear-hosted]\nurl = \" https://mcp.linear.app/mcp \"\n\n[mcp_servers.local]\ncommand = \"npx\"\nargs = [\"-y\", \"x\"]\n")
        let text = "Codex may have added the MCP servers “linear-hosted” (https://mcp.linear.app/mcp) and “local” (the program `npx`) for this skill, "
            + "in ~/.codex/config.toml. They stay there, because you may use them for other things. Remove them there if you don't."
        #expect(codex(leftovers()) == [text])
    }

    /// A config Next Term could not read in full: the dependencies are named, and the file is to be checked.
    @Test func anUnreadConfigSaysCheckIt() throws {
        try skill(["agents/openai.yaml": Self.linear])
        try write(".codex/config.toml", "mcp_servers = { linear = { url = \"https://mcp.linear.app/mcp\" } }\n")
        let text = "Codex may have added MCP servers for this skill (“linear”). Next Term could not read all of ~/.codex/config.toml: check it there."
        #expect(codex(leftovers()) == [text])
    }

    /// An agents/openai.yaml Next Term could not read in full: never "none".
    @Test func anUnreadDependencyFileSaysCheckIt() throws {
        try skill(["agents/openai.yaml": "dependencies:\n  tools: [{type: mcp, value: linear}]\n"])
        let text = "Next Term could not read every MCP entry in its agents/openai.yaml, so Codex may have added servers for it that aren't named here: "
            + "check ~/.codex/config.toml."
        #expect(codex(leftovers()) == [text])
    }

    // MARK: Claude Code and Amp

    /// A plugin Claude Code loads: what it starts stops with it, after open sessions restart.
    @Test func aLinkedPluginsPartsStopWithIt() throws {
        try skill([".claude-plugin/plugin.json": #"{"name": "writing-helper"}"#, ".mcp.json": Self.server, "hooks/hooks.json": Self.hooks])
        #expect(leftovers().isEmpty, "not linked: Claude Code never started them")
        try link()
        #expect(leftovers() == [Self.pluginLine])
    }

    /// Only bin/ (or a part Next Term can't name): the plugin goes, and open sessions keep what it started.
    @Test func aPluginWithOtherPartsGoesWithIt() throws {
        try skill([".claude-plugin/plugin.json": #"{"name": "writing-helper"}"#, "bin/tidy": "#!/bin/sh\n"])
        try link()
        #expect(leftovers() == ["This includes what its Claude Code plugin started."])
    }

    /// Off by the user's key, by its manifest, or not loaded as a plugin (no usable name, H2): nothing ran.
    /// The key stays, and is named.
    @Test func aPluginThatNeverStartedHasNoPartsLine() throws {
        try skill([".claude-plugin/plugin.json": #"{"name": "writing-helper"}"#, ".mcp.json": Self.server])
        try link()
        try write(".claude/settings.json", "{\n  \"enabledPlugins\": {\n    \"writing-helper@skills-dir\": false\n  }\n}\n")
        let key = "~/.claude/settings.json keeps “writing-helper@skills-dir”: false. It stays, and keeps any later folder with that plugin name "
            + "turned off in Claude Code."
        #expect(leftovers() == [key])
        try write(".claude/settings.json", "{\"enabledPlugins\": {\"writing-helper@skills-dir\": true}}")
        #expect(leftovers() == ["This includes its Claude Code plugin's MCP servers."])
        try FileManager.default.removeItem(atPath: home + "/.claude/settings.json")
        try write(".agents/skills/writing-helper/.claude-plugin/plugin.json", #"{"name": "writing-helper", "defaultEnabled": false}"#)
        #expect(leftovers().isEmpty)
        try write(".agents/skills/writing-helper/.claude-plugin/plugin.json", #"{"description": "No name."}"#)
        #expect(leftovers().isEmpty)
    }

    /// H7: a plugin of the same name installed for the user wins, so the folder's parts never ran; one
    /// installed for a project wins only there.
    @Test func anInstalledPluginOfTheSameNameMeansNothingRan() throws {
        try skill([".claude-plugin/plugin.json": #"{"name": "writing-helper"}"#, ".mcp.json": Self.server])
        try link()
        let installed = #"{"version": 2, "plugins": {"Writing-Helper@some-market": [{"scope": "user", "installPath": "/x"}]}}"#
        try write(".claude/plugins/installed_plugins.json", installed)
        #expect(leftovers().isEmpty)
        let project = #"{"version": 2, "plugins": {"writing-helper@some-market": [{"scope": "project", "projectPath": "/p", "installPath": "/x"}]}}"#
        try write(".claude/plugins/installed_plugins.json", project)
        #expect(leftovers() == ["This includes its Claude Code plugin's MCP servers."])
    }

    /// Amp's servers: open sessions keep them, in place of the old "check your agents" line.
    @Test func ampServersStayInOpenSessions() throws {
        try skill(front: "mcpServers:\n  docs:\n    url: https://mcp.example.com/mcp\n")
        #expect(leftovers() == ["This includes the MCP servers Amp started for it."])
        try FileManager.default.removeItem(atPath: folder + "/SKILL.md")
        try skill(front: "", ["mcp.json": #"{"mcpServers": {"docs": {"command": "node", "args": ["x.js"]}}}"#])
        #expect(leftovers() == ["This includes the MCP servers Amp started for it."])
    }

    /// The alert already says open sessions keep the skill: what they keep running for it is one line,
    /// first, and the key line after it.
    @Test func whatOpenSessionsKeepIsOneLine() throws {
        try skill(front: "hooks:\n  PreToolUse: []\nmcpServers:\n  docs:\n    url: https://mcp.example.com/mcp\n",
                  [".claude-plugin/plugin.json": #"{"name": "writing-helper"}"#, ".mcp.json": Self.server, "hooks/hooks.json": Self.hooks])
        try link()
        #expect(leftovers() == ["This includes the hooks it added to Claude Code, its Claude Code plugin's MCP servers and hooks, "
            + "and the MCP servers Amp started for it."])
        #expect(leftovers().allSatisfy { !$0.contains("until they restart") })
    }

    // MARK: as before

    /// A plain skill gives today's lines, and nothing else.
    @Test func aPlainSkillGivesTodaysLines() throws {
        try skill(front: "hooks:\n  PreToolUse: []\nallowed-tools: Bash(git:*)\n", ["scripts/run.sh": "echo hi\n"])
        #expect(leftovers() == ["This includes the hooks it added to Claude Code.", "It pre-approved these tools while it ran: Bash(git:*)."])
        try skill(front: "")
        #expect(leftovers().isEmpty)
        #expect(SkillInstall.leftovers(frontMatter: nil, folder: nil, home: home).isEmpty)
    }

    /// Front matter that names mcpServers in a form the Amp reader doesn't reach keeps the old line.
    @Test func mcpServersNoReaderReachesKeepTheOldLine() {
        var front = SkillFrontMatter()
        front.keys = ["name", "mcpServers"]
        #expect(SkillInstall.leftovers(frontMatter: front, folder: nil, home: home) == ["It asked for MCP servers: check your agents' MCP settings."])
    }
}

/// Who loads a skill from the shared folder, and through Claude Code's link (AE12).
@Suite struct SkillReadersTests {
    static let others = "Gemini CLI, Qwen Code, Cursor, opencode, Copilot CLI, Amp, Junie and goose"

    @Test func withTheLink() {
        let text = SkillReaders.loadedBy([.claudeCode, .codex, .commandCode], linked: true, pluginOff: false)
        #expect(text == "Agents that load it, if you use them: Codex, Command Code, Claude Code (through its link), \(Self.others). "
            + "Amp, Cursor, opencode and goose also find it through the Claude Code link.")
    }

    @Test func withoutTheLink() {
        #expect(SkillReaders.loadedBy([.codex, .commandCode], linked: false, pluginOff: false) == "Agents that load it, if you use them: Codex, Command Code, \(Self.others).")
        #expect(SkillReaders.loadedBy([.codex, .commandCode], linked: false, pluginOff: true) == "Agents that load it, if you use them: Codex, Command Code, \(Self.others).")
    }

    /// Its plugin's key false: Claude Code loads nothing from it, though the others still find the link.
    @Test func withThePluginOff() {
        let text = SkillReaders.loadedBy([.claudeCode, .codex, .commandCode], linked: true, pluginOff: true)
        #expect(text == "Agents that load it, if you use them: Codex, Command Code, \(Self.others). Claude Code loads nothing from it while its plugin is off. "
            + "Amp, Cursor, opencode and goose also find it through the Claude Code link.")
    }

    /// ~/.claude/skills linked to the shared folder as a whole: Claude Code reads it there, with no link of
    /// its own.
    @Test func throughALinkedFolder() {
        #expect(SkillReaders.loadedBy([.claudeCode, .codex, .commandCode], linked: false, pluginOff: false)
            == "Agents that load it, if you use them: Codex, Command Code, Claude Code, \(Self.others).")
    }

    /// The plan says whether Claude Code reads it through a link: made, kept, or dropped.
    @Test func thePlanSaysWhetherClaudeCodeHasALink() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nt-readers-\(UUID().uuidString)").path
        let staged = home + "/staging/notes"
        try FileManager.default.createDirectory(atPath: staged, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.claude/skills", withIntermediateDirectories: true)
        func plan(_ claude: SkillInstall.ClaudeLink, package: SkillPackage? = nil) -> SkillInstallPlan {
            SkillInstall.plan(name: "notes", staged: staged, staging: home + "/ready/notes", inventory: SkillInventory.scan(home: home),
                              claude: claude, package: package, sameSource: true)
        }
        #expect(plan(.link).linksClaude && !plan(.skip).linksClaude)
        try FileManager.default.createDirectory(atPath: home + "/.agents/skills/notes", withIntermediateDirectories: true)
        try "---\nname: notes\ndescription: Notes.\n---\nBody\n".write(toFile: home + "/.agents/skills/notes/SKILL.md", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: home + "/.claude/skills/notes", withDestinationPath: "../../.agents/skills/notes")
        #expect(plan(.skip).linksClaude, "a plain skill keeps its link")
        try FileManager.default.createDirectory(atPath: staged + "/.claude-plugin", withIntermediateDirectories: true)
        try #"{"name": "notes"}"#.write(toFile: staged + "/.claude-plugin/plugin.json", atomically: true, encoding: .utf8)
        let package = SkillPackage.read(folder: staged, folderName: "notes")
        #expect(!plan(.skip, package: package).linksClaude, "a plugin left out loses it")
        #expect(plan(.link, package: package).linksClaude)
    }
}

/// Settings › Skills' Link and Unify for a skill folder that is also a Claude Code plugin (R10): what they
/// ask, and the default Unify's popup offers. Read only: Claude Code's files are never written.
@Suite struct SkillPluginLinkTests {
    let home: String
    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("nt-plugin-link-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home + "/.claude/skills", withIntermediateDirectories: true)
    }

    static let server = SkillClaudeLinkTests.server
    static let hooks = SkillClaudeLinkTests.hooks

    func write(_ path: String, _ text: String) throws {
        let full = (home as NSString).appendingPathComponent(path)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: full, atomically: true, encoding: .utf8)
    }

    /// A skill folder `name` in `root`, a Claude Code plugin named `plugin` unless nil, with `files` beside SKILL.md.
    func skill(_ root: String, name: String = "writing-helper", plugin: String? = "writing-helper", body: String = "Body",
               _ files: [String: String] = [:]) throws {
        let folder = root + "/" + name
        try write(folder + "/SKILL.md", "---\nname: \(name)\ndescription: The \(name) skill.\n---\n\(body)\n")
        if let plugin { try write(folder + "/.claude-plugin/plugin.json", "{\"name\": \"\(plugin)\"}") }
        for (path, text) in files { try write(folder + "/" + path, text) }
    }

    func link(_ name: String = "writing-helper") throws {
        try FileManager.default.createSymbolicLink(atPath: home + "/.claude/skills/" + name, withDestinationPath: "../../.agents/skills/" + name)
    }

    /// What Link asks about the shared copy of writing-helper now.
    func question() -> SkillInstall.PluginLink? {
        SkillInstall.pluginLink(skill: "writing-helper", inventory: SkillInventory.scan(home: home))
    }

    func row(_ inventory: SkillInventory) throws -> SkillRow {
        try #require(inventory.rows.first { $0.name == "writing-helper" })
    }

    func makesLink(_ steps: [SkillStep]) -> Bool { steps.contains { if case .link = $0 { return true }; return false } }

    // MARK: Link

    /// R10: a plugin that runs something is asked about, with how it starts and the review's default.
    @Test func linkAsksAboutAPluginThatRunsSomething() throws {
        try skill(".agents/skills", [".mcp.json": Self.server, "hooks/hooks.json": Self.hooks])
        let asked = try #require(question())
        #expect(asked.asks && asked.skill == "writing-helper" && asked.plugin.name == "writing-helper" && asked.plugin.serverCount == 1)
        #expect(asked.start == .on && asked.clashes.isEmpty && asked.preset == .skip)
    }

    /// A plain folder, or a plugin that runs nothing and meets no other plugin, is linked as before.
    @Test func aPlainFolderOrAQuietPluginIsNotAsked() throws {
        try skill(".agents/skills", plugin: nil)
        #expect(question() == nil)
        try write(".agents/skills/writing-helper/.claude-plugin/plugin.json", #"{"name": "writing-helper", "skills": ["./"]}"#)
        let quiet = try #require(question())
        #expect(!quiet.asks && quiet.preset == .link)
        // No shared copy: nothing to link, nothing to ask.
        #expect(SkillInstall.pluginLink(skill: "other", inventory: SkillInventory.scan(home: home)) == nil)
    }

    /// A clash makes even a plugin that runs nothing ask: another folder Claude Code reads with that plugin
    /// name, or a plugin synced from claude.ai.
    @Test func aClashMakesLinkAsk() throws {
        try skill(".agents/skills")
        try skill(".claude/skills", name: "other-helper", plugin: "Writing-Helper")
        let asked = try #require(question())
        #expect(asked.asks && asked.plugin.runsNothing && asked.clashes.map(\.kind) == [.skillsDir] && asked.preset == .skip)
        try FileManager.default.removeItem(atPath: home + "/.claude/skills/other-helper")
        try write(".claude/plugins/synced/user/writing-helper/.claude-plugin/plugin.json", #"{"name": "writing-helper"}"#)
        let synced = try #require(question())
        #expect(synced.asks && synced.clashes.map(\.kind) == [.synced])
    }

    /// The user's key is read, never written: turned off in /plugin, the default links it (Claude Code loads
    /// nothing from it), and Link still asks, saying so.
    @Test func theUsersKeyIsReadNotWritten() throws {
        try skill(".agents/skills", [".mcp.json": Self.server])
        let settings = "{\n  \"enabledPlugins\": {\"writing-helper@skills-dir\": false}\n}\n"
        try write(".claude/settings.json", settings)
        let asked = try #require(question())
        #expect(asked.start == .offByKey && asked.preset == .link && asked.asks)
        #expect(try String(contentsOfFile: home + "/.claude/settings.json", encoding: .utf8) == settings)
    }

    /// Read again after the folder changed, the question is another one: Link then links nothing.
    @Test func aChangedFolderIsAnotherQuestion() throws {
        try skill(".agents/skills", plugin: nil)
        #expect(question() == nil)
        try write(".agents/skills/writing-helper/.claude-plugin/plugin.json", #"{"name": "writing-helper"}"#)
        let quiet = question()
        #expect(quiet != nil)
        try write(".agents/skills/writing-helper/hooks/hooks.json", Self.hooks)
        #expect(question() != quiet)
    }

    // MARK: Unify

    /// AE14: a hand-made copy in ~/.claude/skills without .claude-plugin, and the plugin folder in the
    /// shared one. Keeping the shared copy asks, leaving it out by default, and Unify follows the choice;
    /// keeping Claude Code's own copy asks nothing.
    @Test func unifyAsksWhenTheKeptCopyIsAPlugin() throws {
        try skill(".agents/skills", [".mcp.json": Self.server, "hooks/hooks.json": Self.hooks])
        try skill(".claude/skills", plugin: nil, body: "hand-made")
        let inventory = SkillInventory.scan(home: home)
        let row = try row(inventory)
        let read = SkillInstall.pluginFacts(row.distinctCopies, home: home)
        let shared = try #require(row.copies.first { $0.root.kind == .shared })
        let mine = try #require(row.copies.first { $0.root.kind == .claude })
        let asked = try #require(SkillUnify.pluginLink(row, winner: shared, in: inventory, read: read))
        #expect(asked.preset == .skip && asked.plugin.serverCount == 1 && asked.start == .on)
        #expect(SkillUnify.pluginLink(row, winner: mine, in: inventory, read: read) == nil)
        let claude = home + "/.claude/skills/writing-helper"
        let left = SkillUnify.plan(row, winner: shared, in: inventory, claude: asked.preset)
        #expect(left.contains(.trash(claude)) && !makesLink(left))
        let added = SkillUnify.plan(row, winner: shared, in: inventory, claude: .link)
        #expect(added.contains(.link(at: claude, to: home + "/.agents/skills/writing-helper")))
    }

    /// Claude Code already loads the same plugin with the same parts: Unify keeps it there by default, as an
    /// update keeps its link. Another plugin name (another key) or new parts are not the same.
    @Test func unifyKeepsClaudeCodeOnTheSamePlugin() throws {
        try skill(".agents/skills", body: "shared", [".mcp.json": Self.server])
        try skill(".claude/skills", body: "Claude Code's", [".mcp.json": Self.server])
        func preset() throws -> SkillInstall.ClaudeLink? {
            let inventory = SkillInventory.scan(home: home)
            let row = try row(inventory)
            let shared = try #require(row.copies.first { $0.root.kind == .shared })
            let read = SkillInstall.pluginFacts(row.distinctCopies, home: home)
            return SkillUnify.pluginLink(row, winner: shared, in: inventory, read: read)?.preset
        }
        #expect(try preset() == .link)
        try write(".claude/skills/writing-helper/.claude-plugin/plugin.json", #"{"name": "other-name"}"#)
        #expect(try preset() == .skip)
        try write(".claude/skills/writing-helper/.claude-plugin/plugin.json", #"{"name": "writing-helper"}"#)
        try write(".agents/skills/writing-helper/hooks/hooks.json", Self.hooks)
        #expect(try preset() == .skip)
    }

    /// Already linked to the shared winner: the same copy, so the link stays by default.
    @Test func unifyKeepsAnExistingLinkToTheKeptCopy() throws {
        try skill(".agents/skills", [".mcp.json": Self.server])
        try link()
        try skill(".commandcode/skills", plugin: nil, body: "old")
        let inventory = SkillInventory.scan(home: home)
        let row = try row(inventory)
        let shared = try #require(row.copies.first { $0.root.kind == .shared })
        let read = SkillInstall.pluginFacts(row.distinctCopies, home: home)
        #expect(SkillUnify.pluginLink(row, winner: shared, in: inventory, read: read)?.preset == .link)
    }

    /// Claude Code without the skill: Unify makes no link for it, so there is nothing to ask.
    @Test func unifyAsksNothingWhenClaudeCodeDidNotHaveIt() throws {
        try skill(".agents/skills", [".mcp.json": Self.server])
        try skill(".codex/skills", plugin: nil, body: "codex")
        let inventory = SkillInventory.scan(home: home)
        let row = try row(inventory)
        let shared = try #require(row.copies.first { $0.root.kind == .shared })
        #expect(SkillUnify.pluginLink(row, winner: shared, in: inventory, read: SkillInstall.pluginFacts(row.distinctCopies, home: home)) == nil)
    }

    /// Each folder is read once, by its real path, with its plugin's key; a plain one has no package.
    @Test func pluginFactsReadEachFolderOnce() throws {
        try skill(".agents/skills", [".mcp.json": Self.server])
        try link()
        try skill(".commandcode/skills", plugin: nil)
        try write(".claude/settings.json", #"{"enabledPlugins": {"writing-helper@skills-dir": true, "other@skills-dir": false}}"#)
        let row = try row(SkillInventory.scan(home: home))
        let read = SkillInstall.pluginFacts(row.copies, home: home)
        let shared = try #require(row.copies.first { $0.root.kind == .shared })
        #expect(read.packages.count == 1 && read.packages[shared.realPath]?.claude?.name == "writing-helper")
        #expect(read.facts.values == ["writing-helper@skills-dir": true])
    }
}
