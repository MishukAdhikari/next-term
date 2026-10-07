import Foundation
import Testing
@testable import NextTermCore

@Suite struct SkillInstallTests {
    let home: String
    let staged: String
    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("nt-install-\(UUID().uuidString)").path
        staged = home + "/staging/skill-creator"
        try FileManager.default.createDirectory(atPath: staged, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.claude/skills", withIntermediateDirectories: true)
    }

    func skill(_ root: String, _ name: String, body: String = "Body") throws {
        let folder = (home as NSString).appendingPathComponent("\(root)/\(name)")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: The \(name) skill.\n---\n\(body)\n".write(toFile: folder + "/SKILL.md", atomically: true, encoding: .utf8)
    }

    @Test func aNewSkillGoesInTheSharedFolderWithALinkForClaude() {
        let plan = SkillInstall.plan(name: "skill-creator", staged: staged, inventory: SkillInventory.scan(home: home), linkForClaude: true, sameSource: false)
        #expect(plan.existing == .none)
        #expect(plan.steps == [.copy(from: staged, to: home + "/.agents/skills/skill-creator"),
                               .link(at: home + "/.claude/skills/skill-creator", to: home + "/.agents/skills/skill-creator")])
        #expect(plan.agents == [.claudeCode, .codex, .commandCode])

        let noLink = SkillInstall.plan(name: "skill-creator", staged: staged, inventory: SkillInventory.scan(home: home), linkForClaude: false, sameSource: false)
        #expect(noLink.steps.count == 1 && noLink.agents == [.codex, .commandCode])
    }

    /// The same name made by hand in two agents: Replace moves both away; nothing is installed beside them.
    @Test func anExistingNameIsAConflictThatReplaceClears() throws {
        try skill(".commandcode/skills", "skill-creator", body: "hand-made")
        try skill(".claude/skills", "skill-creator", body: "another")
        let plan = SkillInstall.plan(name: "skill-creator", staged: staged, inventory: SkillInventory.scan(home: home), linkForClaude: true, sameSource: false)
        #expect(plan.existing == .conflict && plan.replaced.count == 2)
        #expect(plan.steps.prefix(2).allSatisfy { if case .trash = $0 { return true }; return false })
        #expect(plan.steps.contains(.link(at: home + "/.claude/skills/skill-creator", to: home + "/.agents/skills/skill-creator")))
    }

    /// Installed before from the same source, linked for Claude: an update that keeps the link.
    @Test func theSameSourceIsAnUpdateAndKeepsTheLink() throws {
        try skill(".agents/skills", "skill-creator", body: "v1")
        try FileManager.default.createSymbolicLink(atPath: home + "/.claude/skills/skill-creator", withDestinationPath: "../../.agents/skills/skill-creator")
        let plan = SkillInstall.plan(name: "skill-creator", staged: staged, inventory: SkillInventory.scan(home: home), linkForClaude: true, sameSource: true)
        #expect(plan.existing == .update && plan.keptLink != nil)
        #expect(plan.steps == [.trash(home + "/.agents/skills/skill-creator"), .copy(from: staged, to: home + "/.agents/skills/skill-creator")])
        // From another source, the same files are a conflict.
        #expect(SkillInstall.plan(name: "skill-creator", staged: staged, inventory: SkillInventory.scan(home: home), linkForClaude: true, sameSource: false).existing == .conflict)
    }

    @Test func foldersNextTermDoesNotOwnAreNamedNotTouched() throws {
        try skill(".claude/skills/synced", "skill-creator")
        try skill(".codex/skills/.system", "skill-creator")
        let project = home + "/code/app"
        try skill("code/app/.claude/skills", "skill-creator")
        let plan = SkillInstall.plan(name: "skill-creator", staged: staged, inventory: SkillInventory.scan(home: home), linkForClaude: true,
                                     sameSource: false, projects: [project])
        #expect(plan.existing == .none && plan.untouched.count == 3)
        #expect(!plan.steps.contains { if case .trash = $0 { return true }; return false })
    }

    @Test func aNameThatHidesAClaudeCommandIsNamed() {
        let plan = SkillInstall.plan(name: "usage", staged: staged, inventory: SkillInventory.scan(home: home), linkForClaude: true, sameSource: false)
        #expect(plan.untouched.contains { $0.contains("/usage") })
    }

    /// Something the inventory leaves out (a stray file) at the target is a conflict, not a surprise.
    @Test func aStrayFileAtTheTargetIsAConflict() throws {
        try FileManager.default.createDirectory(atPath: home + "/.agents/skills", withIntermediateDirectories: true)
        try "stray".write(toFile: home + "/.agents/skills/skill-creator", atomically: true, encoding: .utf8)
        let plan = SkillInstall.plan(name: "skill-creator", staged: staged, inventory: SkillInventory.scan(home: home), linkForClaude: false, sameSource: false)
        #expect(plan.existing == .conflict && plan.steps.first == .trash(home + "/.agents/skills/skill-creator"))
    }

    /// npx skills links a skill from ~/.commandcode/skills too: an update keeps that link.
    @Test func npxLinksStayAnUpdate() throws {
        try skill(".agents/skills", "skill-creator", body: "v1")
        try FileManager.default.createDirectory(atPath: home + "/.commandcode/skills", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/.commandcode/skills/skill-creator", withDestinationPath: "../../.agents/skills/skill-creator")
        let plan = SkillInstall.plan(name: "skill-creator", staged: staged, inventory: SkillInventory.scan(home: home), linkForClaude: false, sameSource: true)
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
