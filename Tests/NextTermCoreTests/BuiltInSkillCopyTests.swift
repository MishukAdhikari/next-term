import Foundation
import Testing
@testable import NextTermCore

/// Next Term's own skills on disk: a copy of each in ~/.agents/skills with a link for Claude Code, kept current. Next
/// Term's own copy is the one whose text hashes to what it wrote; anything else is the user's and is never written over,
/// and a copy the user deleted is never written again.
@Suite struct BuiltInSkillCopyTests {
    @Test func eachCopyGoesInAgentsSkillsWithAClaudeCodeLink() {
        let paths = BuiltInSkillCopy.Paths(home: "/Users/me", name: "next-term-worktrees")
        #expect(paths.folder == "/Users/me/.agents/skills/next-term-worktrees")
        #expect(paths.file == "/Users/me/.agents/skills/next-term-worktrees/SKILL.md")
        #expect(paths.claudeLink == "/Users/me/.claude/skills/next-term-worktrees")
    }

    @Test func whoseTheCopyIs() {
        let now = "the skill, today"
        let old = "the skill, before"
        #expect(BuiltInSkillCopy.state(onDisk: nil, folderExists: false, written: nil, current: now) == .absent)
        // Ours: the text Next Term wrote, now or an earlier version.
        #expect(BuiltInSkillCopy.state(onDisk: now, folderExists: true, written: BuiltInSkillCopy.hash(now), current: now) == .current)
        #expect(BuiltInSkillCopy.state(onDisk: old, folderExists: true, written: BuiltInSkillCopy.hash(old), current: now) == .stale)
        // Theirs: an edit, a copy Next Term never wrote (even one equal to today's text), a folder without SKILL.md.
        #expect(BuiltInSkillCopy.state(onDisk: now + "!", folderExists: true, written: BuiltInSkillCopy.hash(now), current: now) == .theirs)
        #expect(BuiltInSkillCopy.state(onDisk: now, folderExists: true, written: nil, current: now) == .theirs)
        #expect(BuiltInSkillCopy.state(onDisk: nil, folderExists: true, written: BuiltInSkillCopy.hash(now), current: now) == .theirs)
    }

    @Test func aLinkIsOursOnlyWhenItPointsAtTheCopy() {
        let folder = "/Users/me/.agents/skills/next-term-secrets"
        let link = "/Users/me/.claude/skills/next-term-secrets"
        #expect(BuiltInSkillCopy.linkIsOurs(destination: "../../.agents/skills/next-term-secrets", linkPath: link, folder: folder))
        #expect(BuiltInSkillCopy.linkIsOurs(destination: folder, linkPath: link, folder: folder))
        #expect(!BuiltInSkillCopy.linkIsOurs(destination: "/Users/me/Code/my-skills/next-term-secrets", linkPath: link, folder: folder))
        #expect(!BuiltInSkillCopy.linkIsOurs(destination: nil, linkPath: link, folder: folder))
    }

    /// Every state, wanted or not, declined or not. `deleted`: absent, but Next Term has a hash on record, so the copy it
    /// wrote was deleted by someone.
    @Test func thePlanMatrix() {
        typealias A = BuiltInSkillCopy.Action
        func act(_ state: BuiltInSkillCopy.State, wanted: Bool, declined: Bool = false, recorded: Bool = false) -> A {
            BuiltInSkillCopy.action(state: state, recorded: recorded, wanted: wanted, declined: declined)
        }
        // Wanted, and not declined.
        #expect(act(.absent, wanted: true) == .write)
        #expect(act(.absent, wanted: true, recorded: true) == .decline) // the user deleted it: never written again
        #expect(act(.stale, wanted: true, recorded: true) == .refresh)
        #expect(act(.current, wanted: true, recorded: true) == .link)
        #expect(act(.theirs, wanted: true) == .leave)
        #expect(act(.theirs, wanted: true, recorded: true) == .leave)
        // Not wanted: agent control off, or next-term-tabs with tabs off. Only Next Term's own copy goes.
        #expect(act(.absent, wanted: false) == .nothing)
        #expect(act(.absent, wanted: false, recorded: true) == .nothing)
        #expect(act(.stale, wanted: false, recorded: true) == .remove)
        #expect(act(.current, wanted: false, recorded: true) == .remove)
        #expect(act(.theirs, wanted: false) == .leave)
        // Declined: never written, and a copy of Next Term's own still there goes, wanted or not.
        for wanted in [true, false] {
            #expect(act(.absent, wanted: wanted, declined: true) == .nothing)
            #expect(act(.absent, wanted: wanted, declined: true, recorded: true) == .nothing)
            #expect(act(.stale, wanted: wanted, declined: true, recorded: true) == .remove)
            #expect(act(.current, wanted: wanted, declined: true, recorded: true) == .remove)
            #expect(act(.theirs, wanted: wanted, declined: true) == .leave)
        }
    }

    @Test func thePlanCoversEveryBuiltInAndWantsOnlyTheOffered() {
        let absent = BuiltInSkillCopy.plan(states: [:], written: [:], wanted: BuiltInSkill.offered(tabs: false), declined: [])
        #expect(absent.map(\.skill.name) == BuiltInSkill.all.map(\.name))
        // Every skill offered is written; one not offered (the tabs skill, with tabs off) is left alone.
        let offered = Set(BuiltInSkill.offered(tabs: false).map(\.name))
        #expect(absent.map(\.action) == BuiltInSkill.all.map { offered.contains($0.name) ? .write : .nothing })
        // A copy Next Term wrote and someone edited is theirs, whatever the hash on record: left as it is.
        let edited = BuiltInSkill.worktrees.text + "\nMy own line.\n"
        let state = BuiltInSkillCopy.state(onDisk: edited, folderExists: true, written: BuiltInSkillCopy.hash(BuiltInSkill.worktrees.text),
                                           current: BuiltInSkill.worktrees.text)
        let plan = BuiltInSkillCopy.plan(states: ["next-term-worktrees": state],
                                         written: ["next-term-worktrees": BuiltInSkillCopy.hash(BuiltInSkill.worktrees.text)],
                                         wanted: BuiltInSkill.all, declined: [])
        #expect(state == .theirs && plan.first { $0.skill.name == "next-term-worktrees" }?.action == .leave)
    }

    /// The text written is the very text get_skill serves for each built-in, so the two cannot differ.
    @Test func thePlannedTextIsWhatGetSkillServes() throws {
        let home = NSTemporaryDirectory() + "nt-builtin-copy-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let plan = BuiltInSkillCopy.plan(states: [:], written: [:], wanted: BuiltInSkill.all, declined: [])
        for step in plan {
            #expect(step.action == .write && step.text == BuiltInSkill.named(step.skill.name)?.text, "\(step.skill.name)")
            let served = SkillLibrary.skill(step.skill.name, scope: .nextTerm, from: nil, home: home, nextTerm: BuiltInSkill.all)?.text
            #expect(step.text == served, "\(step.skill.name)")
            // Written to disk, the copy get_skill now finds there is the same text.
            let paths = BuiltInSkillCopy.Paths(home: home, name: step.skill.name)
            try FileManager.default.createDirectory(atPath: paths.folder, withIntermediateDirectories: true)
            try step.text.write(toFile: paths.file, atomically: true, encoding: .utf8)
            #expect(SkillLibrary.skill(step.skill.name, from: nil, home: home, nextTerm: BuiltInSkill.all)?.text == step.text)
        }
    }

    @Test func theOldSecretsHashMovesIntoTheRecords() {
        let old = BuiltInSkillCopy.hash("the secrets text an earlier Next Term wrote")
        #expect(BuiltInSkillCopy.migrate(written: [:], oldSecretsHash: old) == ["next-term-secrets": old])
        #expect(BuiltInSkillCopy.migrate(written: [:], oldSecretsHash: nil) == [:])
        // A record already there wins over the old key.
        let newer = BuiltInSkillCopy.hash("newer")
        #expect(BuiltInSkillCopy.migrate(written: ["next-term-secrets": newer], oldSecretsHash: old) == ["next-term-secrets": newer])
        // Migrated, an earlier copy of Next Term's own is brought up to date, and a declined one stays declined.
        let migrated = BuiltInSkillCopy.migrate(written: [:], oldSecretsHash: old)
        let stale = BuiltInSkillCopy.state(onDisk: "the secrets text an earlier Next Term wrote", folderExists: true,
                                           written: migrated["next-term-secrets"], current: BuiltInSkill.secrets.text)
        #expect(stale == .stale)
        let secrets = { (plan: [BuiltInSkillCopy.Step]) in plan.first { $0.skill == .secrets }?.action }
        #expect(secrets(BuiltInSkillCopy.plan(states: ["next-term-secrets": stale], written: migrated, wanted: BuiltInSkill.all,
                                              declined: [])) == .refresh)
        #expect(secrets(BuiltInSkillCopy.plan(states: [:], written: migrated, wanted: BuiltInSkill.all, declined: ["next-term-secrets"])) == .nothing)
    }

    @Test func settingsSaysWhatItDoesAndHoldsNoKey() {
        #expect(BuiltInSkillCopy.secretsHelp.contains("~/.agents/skills") && BuiltInSkillCopy.secretsHelp.contains("never a key\u{2019}s name or value"))
        #expect(BuiltInSkillCopy.secretsSummary(.theirs, declined: false).contains("stays as it is"))
        #expect(BuiltInSkillCopy.secretsSummary(.absent, declined: true).contains("Restore"))
        #expect(BuiltInSkillCopy.hash("a") == BuiltInSkillCopy.hash("a") && BuiltInSkillCopy.hash("a") != BuiltInSkillCopy.hash("b"))
    }
}
