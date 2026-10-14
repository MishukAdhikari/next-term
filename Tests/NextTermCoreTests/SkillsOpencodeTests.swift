import Foundation
import Testing
@testable import NextTermCore

/// OpenCode as a managed skills agent: its own folder in its config folder (`~/.config/opencode/skills`, or where
/// XDG_CONFIG_HOME moves it, and the older `skill`), the shared folder and Claude Code's, and the copy it keeps when a
/// name is in more than one: the one it reads last, its own folder's, then the shared one's, then Claude Code's.
@Suite struct SkillsOpencodeTests {
    let home: String
    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("nt-skills-oc-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    func skill(_ root: String, _ name: String, body: String = "Body", frontName: String? = nil) throws {
        let folder = (home as NSString).appendingPathComponent("\(root)/\(name)")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let named = frontName.map { $0.isEmpty ? "" : "name: \($0)\n" } ?? "name: \(name)\n"
        try "---\n\(named)description: The \(name) skill.\n---\n\(body)\n".write(toFile: folder + "/SKILL.md", atomically: true, encoding: .utf8)
    }

    func link(_ root: String, _ name: String, to target: String) throws {
        let at = (home as NSString).appendingPathComponent("\(root)/\(name)")
        try FileManager.default.createDirectory(atPath: (at as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: at, withDestinationPath: target)
    }

    func row(_ name: String) throws -> SkillRow {
        try #require(SkillInventory.scan(home: home).rows.first { $0.name == name })
    }

    func opencodeRoots(_ environment: [String: String] = [:]) -> [String] {
        SkillRoot.personal(home: home, environment: environment).filter { $0.kind == .opencode }.map(\.path)
    }

    @Test func theAgentIsNamedOpenCode() {
        #expect(SkillAgent.opencode.rawValue == "opencode" && SkillAgent.opencode.title == "OpenCode")
        #expect(SkillAgent.allCases.last == .opencode)
        #expect(SkillAgent.opencode.reload == "seen in a new session")
    }

    /// Its folder is a root only where it is, in the config folder XDG_CONFIG_HOME moves (an absolute one only).
    @Test func itsOwnFolderIsARootWhereItIs() throws {
        #expect(opencodeRoots().isEmpty)
        try FileManager.default.createDirectory(atPath: home + "/.config/opencode/skills", withIntermediateDirectories: true)
        #expect(opencodeRoots() == [home + "/.config/opencode/skills"])
        try FileManager.default.createDirectory(atPath: home + "/.config/opencode/skill", withIntermediateDirectories: true)
        #expect(opencodeRoots() == [home + "/.config/opencode/skills", home + "/.config/opencode/skill"])
        #expect(opencodeRoots(["XDG_CONFIG_HOME": home + "/xdg"]).isEmpty)
        try FileManager.default.createDirectory(atPath: home + "/xdg/opencode/skills", withIntermediateDirectories: true)
        #expect(opencodeRoots(["XDG_CONFIG_HOME": home + "/xdg"]) == [home + "/xdg/opencode/skills"])
        #expect(opencodeRoots(["XDG_CONFIG_HOME": "xdg"]).count == 2) // a relative one is ignored
        // A home that is not the user's own never takes the login shell's variables.
        #expect(SkillRoot.personal(home: home).filter { $0.kind == .opencode }.count == 2)
    }

    @Test func itReadsTheSharedFolderAndClaudeCodesToo() {
        #expect(SkillRoot(kind: .shared, path: home + "/.agents/skills").readers.contains(.opencode))
        #expect(SkillRoot(kind: .claude, path: home + "/.claude/skills").readers == [.claudeCode, .opencode])
        #expect(SkillRoot(kind: .opencode, path: home + "/.config/opencode/skills").readers == [.opencode])
        #expect(SkillRoot(kind: .opencode, path: home + "/.config/opencode/skills").title.hasSuffix(".config/opencode/skills"))
    }

    /// A skill in the shared folder, and one in OpenCode's own: it loads both, and Codex only the shared one.
    @Test func itLoadsTheSharedSkillsAndItsOwn() throws {
        try skill(".agents/skills", "pdf")
        try skill(".config/opencode/skills", "notes")
        let pdf = try row("pdf"), notes = try row("notes")
        #expect(pdf.load(for: .opencode).used?.root.kind == .shared)
        #expect(notes.load(for: .opencode).used?.root.kind == .opencode && notes.load(for: .opencode).others.isEmpty)
        #expect(notes.load(for: .codex).used == nil && notes.load(for: .claudeCode).used == nil)
        #expect(notes.health == .ok && !notes.isUnified)
    }

    /// One name in its own folder, the shared one and Claude Code's: its own copy wins, the other two are shadowed.
    @Test func itsOwnFolderWinsThenTheSharedOneThenClaudeCodes() throws {
        try skill(".config/opencode/skills", "deploy", body: "mine")
        try skill(".agents/skills", "deploy", body: "shared")
        try skill(".claude/skills", "deploy", body: "claude")
        let load = try row("deploy").load(for: .opencode)
        #expect(load.used?.root.kind == .opencode)
        #expect(load.others.map(\.root.kind) == [.shared, .claude])
        try FileManager.default.removeItem(atPath: home + "/.config/opencode/skills/deploy")
        let shared = try row("deploy").load(for: .opencode)
        #expect(shared.used?.root.kind == .shared && shared.others.map(\.root.kind) == [.claude])
        try FileManager.default.removeItem(atPath: home + "/.agents/skills/deploy")
        #expect(try row("deploy").load(for: .opencode).used?.root.kind == .claude)
    }

    /// Claude Code's link to the shared copy is that copy: OpenCode loads it once, with nothing shadowed.
    @Test func aLinkToTheSharedCopyIsThatCopy() throws {
        try skill(".agents/skills", "tidy")
        try link(".claude/skills", "tidy", to: "../../.agents/skills/tidy")
        try link(".config/opencode/skills", "tidy", to: "../../../.agents/skills/tidy")
        let tidy = try row("tidy")
        #expect(tidy.load(for: .opencode).used != nil && tidy.load(for: .opencode).others.isEmpty)
        #expect(tidy.health == .ok)
    }

    /// `skills` and the older `skill` both hold a name: the copy in `skills` is the one shown as used.
    @Test func skillsWinsOverTheOlderSkill() throws {
        try skill(".config/opencode/skill", "lint", body: "old")
        try skill(".config/opencode/skills", "lint", body: "new")
        let load = try row("lint").load(for: .opencode)
        #expect(load.used?.root.path == home + "/.config/opencode/skills" && load.others.count == 1)
    }

    /// It skips a SKILL.md whose front matter has no name, and lists a copy by the name its SKILL.md gives.
    @Test func itSkipsANamelessCopyAndListsOthersByTheirName() throws {
        try skill(".config/opencode/skills", "draft", frontName: "")
        let skipped = try row("draft").load(for: .opencode)
        #expect(skipped.used == nil && skipped.skippedBecause == "SKILL.md has no name.")
        try skill(".agents/skills", "draft")
        let shared = try row("draft").load(for: .opencode)
        #expect(shared.used?.root.kind == .shared && shared.skippedBecause == nil && shared.others.map(\.root.kind) == [.opencode])
        try skill(".config/opencode/skills", "style-guide", frontName: "ui-style-guide")
        let renamed = try row("style-guide").load(for: .opencode)
        #expect(renamed.used != nil && renamed.listedAs == "ui-style-guide")
        #expect(try row("draft").load(for: .opencode).listedAs == nil)
        #expect(try row("style-guide").copies[0].trigger(for: .opencode) == "ui-style-guide")
    }

    /// Unify leaves one shared copy, but never touches OpenCode's folder (Next Term never writes in OpenCode's config
    /// folder): OpenCode's own copy stays, and the sheet says OpenCode goes on loading it.
    @Test func unifyLeavesItsOwnFolderAlone() throws {
        try skill(".config/opencode/skills", "notes", body: "mine")
        try skill(".agents/skills", "notes", body: "shared")
        try skill(".codex/skills", "notes", body: "codex")
        let notes = try row("notes")
        #expect(!notes.isUnified && notes.health == .drifted)
        let inventory = SkillInventory.scan(home: home)
        let winner = try #require(notes.copies.first { $0.root.kind == .opencode })
        let staging = home + "/staging/notes"
        let steps = SkillUnify.plan(notes, winner: winner, in: inventory, claude: .link, staging: staging)
        #expect(steps == [.copy(from: winner.realPath, to: staging), .trash(home + "/.agents/skills/notes"),
                          .move(from: staging, to: home + "/.agents/skills/notes"), .trash(home + "/.codex/skills/notes")])
        let sharedRoot = try #require(inventory.root(.shared))
        let left = try #require(SkillInstall.opencodeLeft(notes, sharedRoot: sharedRoot))
        #expect(left.contains(".config/opencode/skills/notes stays as it is") && left.hasSuffix("Next Term never changes OpenCode's folder."))
        // Its copy is outside the library's shape: with the others unified, Unify has nothing to offer.
        try FileManager.default.removeItem(atPath: home + "/.codex/skills/notes")
        #expect(try row("notes").isUnified && row("notes").health == .drifted)
        // Only in its own folder: Unify gives the skill to the agents that read the shared one.
        try skill(".config/opencode/skills", "solo")
        #expect(SkillUnify.gained(try row("solo"), in: SkillInventory.scan(home: home)) == [.codex, .commandCode])
    }

    /// A link to the shared copy in its folder (as `npx skills` makes one) is the library's shape too; Remove leaves it,
    /// and says it points at nothing then.
    @Test func aLinkInItsFolderStaysThroughUnifyAndRemove() throws {
        try skill(".agents/skills", "tidy")
        try link(".config/opencode/skills", "tidy", to: "../../../.agents/skills/tidy")
        let tidy = try row("tidy"), inventory = SkillInventory.scan(home: home)
        let winner = try #require(tidy.copies.first { $0.root.kind == .shared })
        #expect(tidy.isUnified && SkillUnify.plan(tidy, winner: winner, in: inventory, claude: .link).isEmpty)
        #expect(SkillInstall.removal(name: "tidy", inventory: inventory) == [.trash(home + "/.agents/skills/tidy")])
        let sharedRoot = try #require(inventory.root(.shared))
        #expect(SkillInstall.opencodeLeft(tidy, sharedRoot: sharedRoot) == nil)
        #expect(SkillInstall.opencodeLeft(tidy, sharedRoot: sharedRoot, removing: true)?.contains("a link to nothing") == true)
    }

    /// An install goes to the shared folder and leaves OpenCode's own copy, which OpenCode goes on loading: the review
    /// says so, and doesn't count OpenCode among the agents that load the new copy.
    @Test func anInstallLeavesItsOwnCopy() throws {
        try skill(".config/opencode/skills", "notes", body: "mine")
        let staged = home + "/staging/notes"
        try FileManager.default.createDirectory(atPath: staged, withIntermediateDirectories: true)
        let plan = SkillInstall.plan(name: "notes", staged: staged, staging: home + "/ready/notes", inventory: SkillInventory.scan(home: home),
                                     claude: .skip, package: nil, sameSource: false)
        #expect(plan.existing == .none && plan.replaced.isEmpty && plan.agents == [.codex, .commandCode])
        #expect(!plan.steps.contains(.trash(home + "/.config/opencode/skills/notes")))
        #expect(plan.untouched.contains { $0.contains(".config/opencode/skills/notes stays as it is") })
    }
}

/// The skill library (list_skills, Settings › Skills › Project) for OpenCode: its own folders, `.opencode/skills` in a
/// project and its config folder's among the user's, rank before the shared and Claude Code's, wherever they are.
@Suite struct SkillLibraryOpencodeTests {
    func folder(_ label: String) throws -> String {
        let path = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-\(label)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func skill(_ folder: String, _ name: String, _ description: String) throws {
        let path = folder + "/" + name
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: \(description)\n---\n\nSteps.\n".write(toFile: path + "/SKILL.md", atomically: true, encoding: .utf8)
    }

    @Test func itsOwnFoldersComeFirst() throws {
        let home = try folder("home"), repo = try folder("repo")
        defer { for path in [home, repo] { try? FileManager.default.removeItem(atPath: path) } }
        try FileManager.default.createDirectory(atPath: repo + "/.git", withIntermediateDirectories: true)
        try skill(home + "/.config/opencode/skills", "notes", "The user's OpenCode notes.")
        try skill(repo + "/.agents/skills", "notes", "The project's notes.")
        try skill(home + "/.agents/skills", "pdf", "Read PDFs.")
        try skill(repo + "/.codex/skills", "codex-only", "Codex's.")
        func entry(_ name: String, _ program: String?) -> SkillLibrary.Entry? {
            SkillLibrary.entries(from: repo, home: home, nextTerm: [], reader: .init(program: program)).first { $0.name == name }
        }
        // Its config folder's copy wins over the project's shared one; it reads the user's shared folder too.
        #expect(entry("notes", "opencode")?.copy.place == "~/.config/opencode/skills" && entry("notes", "opencode")?.native == true)
        #expect(entry("notes", "opencode")?.others.map(\.place) == [".agents/skills"])
        #expect(entry("pdf", "opencode")?.native == true && entry("codex-only", "opencode")?.native == false)
        // Any other agent gets the project's copy first, and doesn't read OpenCode's folder.
        #expect(entry("notes", "codex")?.copy.place == ".agents/skills")
        #expect(entry("notes", nil)?.copy.place == ".agents/skills")
        // The project's .opencode/skills wins over everything.
        try skill(repo + "/.opencode/skills", "notes", "The project's OpenCode notes.")
        #expect(entry("notes", "opencode")?.copy.place == ".opencode/skills")
        #expect(entry("notes", "opencode")?.others.map(\.place) == ["~/.config/opencode/skills", ".agents/skills"])
        let overview = SkillLibrary.overview(project: repo, home: home, nextTerm: [])
        #expect(overview.entry("notes", for: .opencode)?.copy.place == ".opencode/skills")
        #expect(overview.skills.first { $0.name == "notes" }?.copies.map(\.place) == [".agents/skills", ".opencode/skills"])
    }
}
