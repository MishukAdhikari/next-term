import Foundation
import Testing
@testable import NextTermCore

@Suite struct SkillFrontMatterTests {
    @Test func readsTheFieldsSkillsUse() throws {
        let text = """
            ---
            name: tidy-prose
            description: |
              Tidy up prose: shorter sentences, plain words.
              Use when editing prose.
            license: MIT
            allowed-tools: Bash(git:*) Read
            metadata:
              version: "3.0.0"
            ---
            # Tidy prose
            """
        let front = try #require(SkillFrontMatter.parse(text))
        #expect(front.name == "tidy-prose")
        #expect(front.description == "Tidy up prose: shorter sentences, plain words.\nUse when editing prose.")
        #expect(front.license == "MIT")
        #expect(front.allowedTools == "Bash(git:*) Read")
        #expect(front.keys == ["name", "description", "license", "allowed-tools", "metadata"])
        #expect(front.problem(folder: "tidy-prose") == nil)
    }

    @Test func quotedFoldedAndListValues() throws {
        let front = try #require(SkillFrontMatter.parse("---\nname: \"fill-forms\"\ndescription: >\n  Fill forms\n  and read PDFs.\nallowed-tools:\n  - Read\n  - Write\n---\n"))
        #expect(front.name == "fill-forms")
        #expect(front.description == "Fill forms and read PDFs.")
        #expect(front.allowedTools == "Read Write")
        #expect(SkillFrontMatter.parse("# no front matter") == nil)
    }

    /// YAML reads a quoted key as the key itself, colon and all.
    @Test func quotedKeysAreKeys() throws {
        let front = try #require(SkillFrontMatter.parse("---\nname: demo\n\"hooks\":\n  Stop: x\n'mcpServers': {}\n\"a:b\": c\n# note: no\n---\n"))
        #expect(front.keys == ["name", "hooks", "mcpServers", "a:b"])
        #expect(front.name == "demo")
        let quotedName = try #require(SkillFrontMatter.parse("---\n\"name\": demo\n---\n"))
        #expect(quotedName.name == "demo")
    }

    @Test func theStandardsNameRules() {
        func problem(_ name: String?, folder: String, description: String? = "d") -> String? {
            var front = SkillFrontMatter()
            front.name = name
            front.description = description
            return front.problem(folder: folder)
        }
        #expect(problem("ui-style-guide", folder: "style-guide") != nil) // name differs from folder
        #expect(problem("My Style Guide", folder: "My Style Guide") != nil)
        #expect(problem("bad--name", folder: "bad--name") != nil)
        #expect(problem("-x", folder: "-x") != nil)
        #expect(problem("ok-1", folder: "ok-1") == nil)
        #expect(problem("ok", folder: "ok", description: "") != nil)
        #expect(problem(nil, folder: "x") != nil)
        #expect(problem("humаnizer", folder: "humаnizer") != nil) // a Cyrillic а
        #expect(problem("synced", folder: "synced") != nil)
    }
}

@Suite struct SkillInventoryTests {
    let home: String
    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("nt-skills-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    func skill(_ root: String, _ name: String, body: String = "Body", frontName: String? = nil, extra: [String: String] = [:]) throws {
        let folder = (home as NSString).appendingPathComponent("\(root)/\(name)")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let text = "---\nname: \(frontName ?? name)\ndescription: The \(name) skill.\n---\n\(body)\n"
        try text.write(toFile: folder + "/SKILL.md", atomically: true, encoding: .utf8)
        for (path, content) in extra {
            let full = (folder as NSString).appendingPathComponent(path)
            try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try content.write(toFile: full, atomically: true, encoding: .utf8)
        }
    }

    func link(_ root: String, _ name: String, to target: String) throws {
        let at = (home as NSString).appendingPathComponent("\(root)/\(name)")
        try FileManager.default.createDirectory(atPath: (at as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: at, withDestinationPath: target)
    }

    func row(_ name: String) throws -> SkillRow {
        try #require(SkillInventory.scan(home: home).rows.first { $0.name == name })
    }

    @Test func aSharedCopyLinkedForClaudeIsUnifiedAndSeenByAllThree() throws {
        try skill(".agents/skills", "tidy-prose")
        try link(".claude/skills", "tidy-prose", to: "../../.agents/skills/tidy-prose")
        let tidyProse = try row("tidy-prose")
        #expect(tidyProse.health == .ok && tidyProse.isUnified)
        for agent in SkillAgent.allCases { #expect(tidyProse.load(for: agent).used != nil, "\(agent)") }
        #expect(tidyProse.load(for: .claudeCode).used?.isLink == true)
    }

    @Test func handCopiesThatDifferAreDrifted() throws {
        try skill(".claude/skills", "release-notes", body: "v3")
        try skill(".codex/skills", "release-notes", body: "v1")
        try skill(".commandcode/skills", "release-notes", body: "v2")
        let sync = try row("release-notes")
        #expect(sync.health == .drifted && !sync.isUnified)
        #expect(sync.distinctCopies.count == 3)
    }

    @Test func identicalCopiesAreDuplicatedAndCachesDoNotCount() throws {
        try skill(".claude/skills", "fill-forms")
        try skill(".commandcode/skills", "fill-forms", extra: ["__pycache__/x.pyc": "cache", ".DS_Store": "finder"])
        #expect(try row("fill-forms").health == .duplicated)
    }

    @Test func commandCodePrefersItsOwnFolderAndSkipsNamesThatBreakTheStandard() throws {
        try skill(".agents/skills", "plan-review", body: "new")
        try skill(".commandcode/skills", "plan-review", body: "old")
        let plans = try row("plan-review")
        let load = plans.load(for: .commandCode)
        #expect(load.used?.root.kind == .commandCode)
        #expect(load.others.first?.root.kind == .shared) // shadowed
        #expect(plans.load(for: .codex).used?.root.kind == .shared)
        #expect(plans.load(for: .claudeCode).used == nil)

        try skill(".commandcode/skills", "style-guide", frontName: "ui-style-guide")
        let styleGuide = try row("style-guide").load(for: .commandCode)
        #expect(styleGuide.used == nil && styleGuide.skippedBecause?.contains("differs from its folder") == true)
    }

    @Test func codexListsBothOfItsCopiesWhenTheyDiffer() throws {
        try skill(".agents/skills", "page-layout", body: "a")
        try skill(".codex/skills", "page-layout", body: "b")
        let load = try row("page-layout").load(for: .codex)
        #expect(load.used?.root.kind == .shared && load.others.count == 1)
    }

    @Test func brokenLinksSyncedAndSystemSkills() throws {
        try link(".claude/skills", "gone", to: "../../.agents/skills/gone")
        try skill(".claude/skills/synced", "account-skill")
        try skill(".codex/skills/.system", "skill-creator")
        let inventory = SkillInventory.scan(home: home)
        #expect(inventory.rows.first { $0.name == "gone" }?.health == .broken)
        #expect(!inventory.rows.contains { $0.name == "synced" || $0.name == "account-skill" || $0.name == "skill-creator" })
    }

    @Test func scriptsAreNoticed() throws {
        try skill(".agents/skills", "with-script", extra: ["scripts/run.sh": "#!/bin/sh\necho hi\n"])
        try skill(".agents/skills", "plain")
        #expect(try row("with-script").copies[0].hasScripts)
        #expect(try !row("plain").copies[0].hasScripts)
    }

    @Test func theUnifyPlanLeavesOneSharedCopyLinkedForClaude() throws {
        try skill(".claude/skills", "release-notes", body: "v3")
        try skill(".codex/skills", "release-notes", body: "v1")
        try skill(".commandcode/skills", "release-notes", body: "v2")
        let sync = try row("release-notes")
        let winner = try #require(sync.copies.first { $0.root.kind == .claude })
        let staging = home + "/Library/Application Support/Next Term/skill-staging/release-notes-1"
        let steps = SkillUnify.plan(sync, winner: winner, in: SkillInventory.scan(home: home), staging: staging)
        let shared = home + "/.agents/skills/release-notes"
        // The winner is copied aside (never into an agent folder, where a leftover would load as a
        // skill), then moved into place, before anything is thrown away.
        #expect(steps.first == .copy(from: winner.realPath, to: staging))
        #expect(steps[1] == .move(from: staging, to: shared))
        #expect(steps.contains(.trash(home + "/.claude/skills/release-notes")))
        #expect(steps.contains(.link(at: home + "/.claude/skills/release-notes", to: shared)))
        #expect(steps.contains(.trash(home + "/.codex/skills/release-notes")))
        #expect(steps.contains(.trash(home + "/.commandcode/skills/release-notes")))
        #expect(!steps.contains { if case .trash(let path) = $0 { return path.contains("skill-staging") }; return false })
    }

    @Test func anAlreadySharedWinnerOnlyFixesTheOthers() throws {
        try skill(".agents/skills", "tidy-prose")
        try link(".commandcode/skills", "tidy-prose", to: "../../.agents/skills/tidy-prose")
        let tidyProse = try row("tidy-prose")
        let winner = try #require(tidyProse.copies.first { $0.root.kind == .shared })
        let steps = SkillUnify.plan(tidyProse, winner: winner, in: SkillInventory.scan(home: home))
        #expect(steps == [.trash(home + "/.commandcode/skills/tidy-prose")]) // the redundant link only
        // Claude Code did not have it: Unify does not hand it a new skill.
        #expect(SkillUnify.gained(tidyProse, in: SkillInventory.scan(home: home)).isEmpty)
    }

    /// `~/.claude/skills` linked as a whole to `~/.agents/skills`: one folder, read by all three. Unify
    /// must not trash the "Claude copy" (it is the shared one) or link a skill to itself.
    @Test func aWholeFolderLinkIsOneFolder() throws {
        try skill(".agents/skills", "plan-review", body: "new")
        try FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/.claude/skills", withDestinationPath: "../.agents/skills")
        try skill(".commandcode/skills", "plan-review", body: "old")
        let inventory = SkillInventory.scan(home: home)
        #expect(inventory.root(.claude) == nil && inventory.root(.shared)?.readers.contains(.claudeCode) == true)
        let plans = try row("plan-review")
        #expect(plans.copies.count == 2 && plans.load(for: .claudeCode).used?.root.kind == .shared)
        let winner = try #require(plans.copies.first { $0.root.kind == .shared })
        #expect(SkillUnify.plan(plans, winner: winner, in: inventory) == [.trash(home + "/.commandcode/skills/plan-review")])
    }

    /// A skill linked from the developer's own repository stays there: the shared entry links to it, and
    /// nothing is copied out of it or moved.
    @Test func aLinkToTheDevelopersOwnFolderIsKept() throws {
        let repo = home + "/code/my-skill"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        try "---\nname: my-skill\ndescription: Mine.\n---\nBody\n".write(toFile: repo + "/SKILL.md", atomically: true, encoding: .utf8)
        try link(".claude/skills", "my-skill", to: repo)
        try skill(".commandcode/skills", "my-skill", body: "an old copy")
        let inventory = SkillInventory.scan(home: home)
        let mine = try row("my-skill")
        let winner = try #require(mine.copies.first { $0.root.kind == .claude })
        let steps = SkillUnify.plan(mine, winner: winner, in: inventory)
        let shared = home + "/.agents/skills/my-skill"
        #expect(steps.first == .link(at: shared, to: winner.realPath))
        #expect(!steps.contains { if case .copy = $0 { return true }; return false })
        #expect(steps.contains(.trash(home + "/.claude/skills/my-skill")) && steps.contains(.link(at: home + "/.claude/skills/my-skill", to: shared)))
        #expect(SkillUnify.gained(mine, in: inventory) == [.codex])
    }

    @Test func aCopyThatBreaksTheStandardCannotWin() throws {
        try skill(".claude/skills", "style-guide", frontName: "ui-style-guide")
        try skill(".commandcode/skills", "style-guide")
        let styleGuide = try row("style-guide")
        #expect(styleGuide.cannotWin(styleGuide.copies.first { $0.root.kind == .claude }!) != nil)
        #expect(styleGuide.cannotWin(styleGuide.copies.first { $0.root.kind == .commandCode }!) == nil)
    }

    @Test func eachAgentsOwnSwitchesAreRead() throws {
        try skill(".claude/skills", "slide-maker")
        try skill(".agents/skills", "fill-forms")
        try FileManager.default.createDirectory(atPath: home + "/.codex", withIntermediateDirectories: true)
        try #"{"skillOverrides": {"slide-maker": "off"}}"#.write(toFile: home + "/.claude/settings.json", atomically: true, encoding: .utf8)
        try "[[skills.config]]\npath = \"\(home)/.agents/skills/fill-forms/SKILL.md\"\nenabled = false # not now\n\n[other]\nenabled = false\n"
            .write(toFile: home + "/.codex/config.toml", atomically: true, encoding: .utf8)
        #expect(try row("slide-maker").load(for: .claudeCode).switchedOff)
        #expect(try row("fill-forms").load(for: .codex).switchedOff)
        #expect(try !row("fill-forms").load(for: .commandCode).switchedOff)
    }

    /// Claude Code switched the skill off under a name Unify won't keep: the sheet must say it comes back on.
    @Test func unifyWarnsWhenAnAgentsSwitchWouldStopMatching() throws {
        try skill(".claude/skills", "style-guide", frontName: "My Style Guide")
        try skill(".commandcode/skills", "style-guide")
        try #"{"skillOverrides": {"My Style Guide": "off"}}"#.write(toFile: home + "/.claude/settings.json", atomically: true, encoding: .utf8)
        let inventory = SkillInventory.scan(home: home)
        let styleGuide = try row("style-guide")
        #expect(styleGuide.off == [.claudeCode])
        #expect(SkillUnify.switchesLost(styleGuide, in: inventory) == [.claudeCode])
        try #"{"skillOverrides": {"style-guide": "off"}}"#.write(toFile: home + "/.claude/settings.json", atomically: true, encoding: .utf8)
        #expect(SkillUnify.switchesLost(try row("style-guide"), in: SkillInventory.scan(home: home)).isEmpty)
    }

    @Test func triggersFollowPluginsAndUserInvocable() throws {
        try skill(".agents/skills", "tidy-prose", extra: [".claude-plugin/plugin.json": #"{"name": "tidy-prose"}"#])
        let copy = try row("tidy-prose").copies[0]
        #expect(copy.trigger(for: .codex) == "$tidy-prose:tidy-prose")
        #expect(copy.trigger(for: .commandCode) == "/tidy-prose")
    }

    /// Codex names a skill after the first manifest in its own order; Claude Code keys its plugin by its
    /// own manifest's name, else by the entry's name (a link's name in ~/.claude/skills).
    @Test func pluginNamesFollowEachAgent() throws {
        try skill(".agents/skills", "both", extra: [".codex-plugin/plugin.json": #"{"name": "a"}"#, ".claude-plugin/plugin.json": #"{"name": "b"}"#])
        try skill(".agents/skills", "claude-only", extra: [".claude-plugin/plugin.json": #"{"name": "b"}"#])
        try skill(".agents/skills", "nameless", extra: [".claude-plugin/plugin.json": "{}"])
        try skill(".agents/skills", "plain")
        try link(".claude/skills", "renamed", to: "../../.agents/skills/nameless")
        let both = try row("both").copies[0]
        #expect(both.trigger(for: .codex) == "$a:both" && both.claudePluginName == "b")
        let claudeOnly = try row("claude-only").copies[0]
        #expect(claudeOnly.trigger(for: .codex) == "$b:claude-only" && claudeOnly.claudePluginName == "b")
        #expect(try row("nameless").copies[0].claudePluginName == "nameless")
        #expect(try row("nameless").copies[0].trigger(for: .codex) == "$nameless")
        #expect(try row("renamed").copies[0].claudePluginName == "renamed")
        #expect(try row("plain").copies[0].claudePluginName == nil)
    }

    @Test func linksAreRelativeLikeTheSkillsCLIMakesThem() {
        #expect(SkillUnify.relativeTarget(at: "/Users/me/.claude/skills/x", to: "/Users/me/.agents/skills/x") == "../../.agents/skills/x")
    }

    /// A skill with one copy has nothing to compare: its files are not read for a hash at all.
    @Test func aSingleCopyIsNotHashed() throws {
        try skill(".agents/skills", "solo", extra: ["big.txt": String(repeating: "x", count: 100_000)])
        try skill(".claude/skills", "pair", body: "a")
        try skill(".codex/skills", "pair", body: "b")
        #expect(try row("solo").copies.allSatisfy { $0.contentHash == nil })
        #expect(try row("pair").copies.allSatisfy { $0.contentHash != nil })
    }

    /// A git clone and the same files without history are not the same copy.
    @Test func aGitCloneIsNotIdenticalToAPlainCopy() throws {
        try skill(".claude/skills", "tidy")
        try skill(".codex/skills", "tidy")
        try FileManager.default.createDirectory(atPath: home + "/.claude/skills/tidy/.git", withIntermediateDirectories: true)
        #expect(try row("tidy").health == .drifted)
    }
}

@Suite struct SkillHashRoundTwoTests {
    /// Two clones with the same files but different history are not the same copy.
    @Test func clonesWithDifferentHistoryDiffer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nt-hash2-\(UUID().uuidString)").path
        for (name, ref) in [("a", "1111"), ("b", "2222")] {
            let folder = root + "/" + name
            try FileManager.default.createDirectory(atPath: folder + "/.git/refs/heads", withIntermediateDirectories: true)
            try "same".write(toFile: folder + "/SKILL.md", atomically: true, encoding: .utf8)
            try "ref: refs/heads/main\n".write(toFile: folder + "/.git/HEAD", atomically: true, encoding: .utf8)
            try ref.write(toFile: folder + "/.git/refs/heads/main", atomically: true, encoding: .utf8)
        }
        #expect(SkillHash.folder(root + "/a") != SkillHash.folder(root + "/b"))
    }

    /// What the installed copy is compared with leaves out caches Python writes when the skill runs.
    @Test func runningASkillIsNotAnEdit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nt-edit-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder + "/scripts", withIntermediateDirectories: true)
        try "print(1)\n".write(toFile: folder + "/scripts/helper.py", atomically: true, encoding: .utf8)
        let before = SkillEdits.installedHash(folder)
        try FileManager.default.createDirectory(atPath: folder + "/scripts/__pycache__", withIntermediateDirectories: true)
        try "cache".write(toFile: folder + "/scripts/__pycache__/helper.cpython-314.pyc", atomically: true, encoding: .utf8)
        #expect(SkillEdits.installedHash(folder) == before)
    }

    /// npx skills leaves out metadata.json and caches: compared blob by blob, an untouched copy is not edited.
    @Test func npxCopiesCompareBlobByBlob() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nt-npx-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder + "/rules", withIntermediateDirectories: true)
        try "skill".write(toFile: folder + "/SKILL.md", atomically: true, encoding: .utf8)
        try "rule".write(toFile: folder + "/rules/a.md", atomically: true, encoding: .utf8)
        let tree: [String: SkillEdits.Blob] = [
            "SKILL.md": .init(sha: GitHash.blob(Data("skill".utf8)), link: false),
            "rules/a.md": .init(sha: GitHash.blob(Data("rule".utf8)), link: false),
            "metadata.json": .init(sha: "x", link: false),
        ]
        #expect(SkillEdits.differs(folder, from: tree) == false)
        try "edited".write(toFile: folder + "/rules/a.md", atomically: true, encoding: .utf8)
        #expect(SkillEdits.differs(folder, from: tree) == true)
        // A tree with a link can't be compared (npx copies what links point to): no verdict.
        #expect(SkillEdits.differs(folder, from: ["l": .init(sha: "s", link: true)]) == nil)
    }
}
