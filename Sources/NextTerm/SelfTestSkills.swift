import AppKit
import NextTermCore

/// The Skills library on a home folder of its own: the inventory, Settings › Skills, Unify and Undo.
/// The user's real skill folders are never read or written here.
extension SelfTest {
    static func skillsChecks() async {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-skills-\(getpid())").path
        let savedHome = SkillsStore.home
        SkillsStore.home = home
        defer {
            SkillsStore.home = savedHome
            try? FileManager.default.removeItem(atPath: home)
        }
        func skill(_ root: String, _ name: String, body: String) {
            let folder = (home as NSString).appendingPathComponent("\(root)/\(name)")
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? "---\nname: \(name)\ndescription: The \(name) skill.\n---\n\(body)\n".write(toFile: folder + "/SKILL.md", atomically: true, encoding: .utf8)
        }
        func read(_ path: String) -> String? { try? String(contentsOfFile: (home as NSString).appendingPathComponent(path), encoding: .utf8) }
        func isLink(_ path: String) -> Bool {
            var info = stat()
            return lstat((home as NSString).appendingPathComponent(path), &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
        }

        // The same skill copied by hand into three agents, and edited differently in each.
        skill(".claude/skills", "release-notes", body: "claude version")
        skill(".codex/skills", "release-notes", body: "codex version")
        skill(".commandcode/skills", "release-notes", body: "command code version")
        skill(".agents/skills", "tidy-prose", body: "shared")

        let view = SkillsSettingsView(frame: NSRect(x: 0, y: 0, width: 620, height: 480))
        let inventory = SkillsStore.inventory()
        let sync = inventory.rows.first { $0.name == "release-notes" }
        check(inventory.rows.count == 2 && sync?.health == .drifted, "skills: the inventory finds every agent's copies, and sees that they differ",
              inventory.rows.map { "\($0.name): \($0.health)" }.joined(separator: ", "))
        check(SkillsSettingsView.needsAttention(sync!) && SkillsSettingsView.stateText(sync!) == "3 copies differ",
              "skills: Settings › Skills marks it as needing attention", SkillsSettingsView.stateText(sync!))
        check(SkillsSettingsView.cellText(inventory.rows.first { $0.name == "tidy-prose" }!, agent: .claudeCode).0 == "—",
              "skills: a shared skill without a link is not seen by Claude Code, and says so")
        _ = view // built without errors on this home

        // Unify, keeping Claude Code's version.
        guard let winner = sync?.copies.first(where: { $0.root.kind == .claude }) else { return check(false, "skills: the Claude copy is found") }
        let steps = SkillUnify.plan(sync!, winner: winner, in: inventory)
        let applied = SkillsStore.apply(steps, title: "Unify release-notes")
        if case .failure(let failure) = applied { check(false, "skills: Unify applies", failure.message) }
        let after = SkillsStore.inventory().rows.first { $0.name == "release-notes" }
        check(read(".agents/skills/release-notes/SKILL.md")?.contains("claude version") == true && isLink(".claude/skills/release-notes"),
              "skills: Unify leaves one shared copy with the chosen version, linked for Claude Code")
        check(after?.isUnified == true && SkillAgent.allCases.allSatisfy { after?.load(for: $0).used?.root.kind != nil },
              "skills: and every agent loads that one copy", after.map { r in SkillAgent.allCases.map { "\($0): \(String(describing: r.load(for: $0).used?.path))" }.joined(separator: "; ") } ?? "none")
        check(read(".codex/skills/release-notes/SKILL.md") == nil && read(".commandcode/skills/release-notes/SKILL.md") == nil,
              "skills: the other copies are gone from the agents' folders")
        check(SkillsStore.lastChange?.title == "Unify release-notes", "skills: the change is remembered for Undo")

        // Undo puts every copy back as it was.
        if case .failure(let failure) = SkillsStore.undo() { check(false, "skills: Undo applies", failure.message) }
        check(read(".claude/skills/release-notes/SKILL.md")?.contains("claude version") == true && !isLink(".claude/skills/release-notes")
              && read(".codex/skills/release-notes/SKILL.md")?.contains("codex version") == true
              && read(".commandcode/skills/release-notes/SKILL.md")?.contains("command code version") == true
              && read(".agents/skills/release-notes/SKILL.md") == nil,
              "skills: Undo puts every copy back exactly, and removes what Unify made")
        check(SkillsStore.lastChange == nil, "skills: and there is nothing left to undo")
    }
}
