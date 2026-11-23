import Foundation
import Testing
@testable import NextTermCore

/// Settings › Secrets › Add to Agents: where the next-term-secrets copy goes, and whose a copy on disk is. Next Term's own
/// copy is the one whose text hashes to what it wrote; anything else is the user's and is never written over.
@Suite struct SecretsSkillCopyTests {
    @Test func theCopyGoesInAgentsSkillsWithAClaudeCodeLink() {
        let paths = SecretsSkillCopy.Paths(home: "/Users/me")
        #expect(paths.folder == "/Users/me/.agents/skills/next-term-secrets")
        #expect(paths.file == "/Users/me/.agents/skills/next-term-secrets/SKILL.md")
        #expect(paths.claudeLink == "/Users/me/.claude/skills/next-term-secrets")
    }

    @Test func whoseTheCopyIs() {
        let now = "the skill, today"
        let old = "the skill, before"
        #expect(SecretsSkillCopy.state(onDisk: nil, folderExists: false, written: nil, current: now) == .absent)
        // Ours: the text Next Term wrote, now or an earlier version.
        #expect(SecretsSkillCopy.state(onDisk: now, folderExists: true, written: SecretsSkillCopy.hash(now), current: now) == .current)
        #expect(SecretsSkillCopy.state(onDisk: old, folderExists: true, written: SecretsSkillCopy.hash(old), current: now) == .stale)
        // Theirs: an edit, a copy Next Term never wrote (even one equal to today's text), a folder without SKILL.md.
        #expect(SecretsSkillCopy.state(onDisk: now + "!", folderExists: true, written: SecretsSkillCopy.hash(now), current: now) == .theirs)
        #expect(SecretsSkillCopy.state(onDisk: now, folderExists: true, written: nil, current: now) == .theirs)
        #expect(SecretsSkillCopy.state(onDisk: nil, folderExists: true, written: SecretsSkillCopy.hash(now), current: now) == .theirs)
    }

    @Test func aLinkIsOursOnlyWhenItPointsAtTheCopy() {
        let folder = "/Users/me/.agents/skills/next-term-secrets"
        let link = "/Users/me/.claude/skills/next-term-secrets"
        #expect(SecretsSkillCopy.linkIsOurs(destination: "../../.agents/skills/next-term-secrets", linkPath: link, folder: folder))
        #expect(SecretsSkillCopy.linkIsOurs(destination: folder, linkPath: link, folder: folder))
        #expect(!SecretsSkillCopy.linkIsOurs(destination: "/Users/me/Code/my-skills/next-term-secrets", linkPath: link, folder: folder))
        #expect(!SecretsSkillCopy.linkIsOurs(destination: nil, linkPath: link, folder: folder))
    }

    @Test func settingsSaysWhatItDoesAndHoldsNoKey() {
        #expect(SecretsSkillCopy.help.contains("~/.agents/skills") && SecretsSkillCopy.help.contains("never a key\u{2019}s name or value"))
        #expect(SecretsSkillCopy.summary(.theirs).contains("stays as it is"))
        #expect(SecretsSkillCopy.hash("a") == SecretsSkillCopy.hash("a") && SecretsSkillCopy.hash("a") != SecretsSkillCopy.hash("b"))
    }
}
