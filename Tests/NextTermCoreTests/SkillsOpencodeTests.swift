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

    /// Unify never touches OpenCode's folder (Next Term never writes in OpenCode's config folder). Keeping another copy,
    /// OpenCode's own stays, and the sheet says OpenCode goes on loading it; keeping OpenCode's, the shared entry becomes a
    /// link to it where it is, as for the developer's own folder, so there is one copy and nothing left to unify.
    @Test func unifyLeavesItsOwnFolderAlone() throws {
        try skill(".config/opencode/skills", "notes", body: "mine")
        try skill(".agents/skills", "notes", body: "shared")
        try skill(".codex/skills", "notes", body: "codex")
        let notes = try row("notes")
        #expect(!notes.isUnified && notes.health == .drifted)
        let inventory = SkillInventory.scan(home: home)
        let sharedRoot = try #require(inventory.root(.shared))
        let own = try #require(notes.copies.first { $0.root.kind == .opencode })
        let shared = try #require(notes.copies.first { $0.root.kind == .shared })
        let sharedPath = home + "/.agents/skills/notes", codexPath = home + "/.codex/skills/notes"
        #expect(SkillUnify.plan(notes, winner: own, in: inventory, claude: .link) == [.trash(sharedPath), .link(at: sharedPath, to: own.realPath), .trash(codexPath)])
        #expect(SkillInstall.opencodeLeft(notes, sharedRoot: sharedRoot, keeping: own) == nil)
        #expect(SkillUnify.plan(notes, winner: shared, in: inventory, claude: .link) == [.trash(codexPath)])
        let left = try #require(SkillInstall.opencodeLeft(notes, sharedRoot: sharedRoot, keeping: shared))
        #expect(left.contains(".config/opencode/skills/notes stays as it is") && left.contains("goes on loading that copy rather than the shared one"))
        #expect(left.hasSuffix("Next Term never changes OpenCode's folder."))
        // With the others gone, OpenCode's own copy still differs: Unify is offered, and keeping the shared copy changes
        // nothing (the sheet says so), while keeping OpenCode's shares it.
        try FileManager.default.removeItem(atPath: codexPath)
        let two = try row("notes"), after = SkillInventory.scan(home: home)
        #expect(!two.isUnified && two.health == .drifted)
        let keptShared = try #require(two.copies.first { $0.root.kind == .shared })
        #expect(SkillUnify.plan(two, winner: keptShared, in: after, claude: .link).isEmpty)
        // Only in its own folder: Unify links the shared entry to it, and gives it to the agents that read the shared one.
        try skill(".config/opencode/skills", "solo")
        let solo = try row("solo"), soloCopy = try #require(solo.copies.first)
        #expect(SkillUnify.gained(solo, in: SkillInventory.scan(home: home)) == [.codex, .commandCode])
        let soloSteps = SkillUnify.plan(solo, winner: soloCopy, in: SkillInventory.scan(home: home), claude: .link)
        #expect(soloSteps == [.link(at: home + "/.agents/skills/solo", to: soloCopy.realPath)])
    }

    /// A shared entry that links to OpenCode's own copy (as 0.11 left it, or Unify makes it) stays a link through Unify:
    /// OpenCode's folder is not one Next Term manages, as the developer's own folder isn't, so no second copy is made.
    @Test func aSharedLinkIntoItsFolderStays() throws {
        try skill(".config/opencode/skills", "x", body: "mine")
        try link(".agents/skills", "x", to: home + "/.config/opencode/skills/x")
        try skill(".codex/skills", "x", body: "codex")
        let x = try row("x"), inventory = SkillInventory.scan(home: home)
        let shared = try #require(x.copies.first { $0.root.kind == .shared })
        let own = try #require(x.copies.first { $0.root.kind == .opencode })
        #expect(!x.isUnified && !inventory.isInsideRoots(own.realPath))
        #expect(SkillUnify.plan(x, winner: shared, in: inventory, claude: .link) == [.trash(home + "/.codex/skills/x")])
        #expect(SkillUnify.plan(x, winner: own, in: inventory, claude: .link) == [.trash(home + "/.codex/skills/x")])
        let sharedRoot = try #require(inventory.root(.shared))
        #expect(SkillInstall.opencodeLeft(x, sharedRoot: sharedRoot, keeping: shared) == nil)
        // Once Codex's copy is gone: one copy, every agent reads it, nothing needs attention.
        try FileManager.default.removeItem(atPath: home + "/.codex/skills/x")
        let unified = try row("x")
        #expect(unified.isUnified && unified.health == .ok)
        #expect(unified.load(for: .opencode).others.isEmpty && unified.load(for: .codex).used?.root.kind == .shared)
        // Remove takes the shared link only, and says OpenCode goes on loading its own copy.
        let removing = try #require(SkillInstall.opencodeLeft(unified, sharedRoot: sharedRoot, removing: true))
        #expect(removing.contains("goes on loading that copy.") && !removing.contains("rather than"))
        #expect(SkillInstall.removal(name: "x", inventory: SkillInventory.scan(home: home)) == [.trash(home + "/.agents/skills/x")])
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

    /// OpenCode skips its own copy when that SKILL.md gives no name: it loads the new shared copy, and the note says its
    /// own copy stays but is skipped, not that OpenCode goes on loading it.
    @Test func anInstallBesideANamelessCopyReachesIt() throws {
        try skill(".config/opencode/skills", "notes", frontName: "")
        let staged = home + "/staging/notes"
        try FileManager.default.createDirectory(atPath: staged, withIntermediateDirectories: true)
        let plan = SkillInstall.plan(name: "notes", staged: staged, staging: home + "/ready/notes", inventory: SkillInventory.scan(home: home),
                                     claude: .skip, package: nil, sameSource: false)
        #expect(plan.agents == [.codex, .commandCode, .opencode])
        let note = try #require(plan.untouched.first { $0.contains(".config/opencode/skills/notes") })
        #expect(note.contains("stays as it is, and OpenCode skips it.") && !note.contains("goes on loading"))
    }

    /// OpenCode also reads `.opencode` in the home folder, after its config folder (ConfigPaths.directories in 1.19), so a
    /// copy there is the one it keeps.
    @Test func theHomeFoldersOpencodeIsARootToo() throws {
        try skill(".config/opencode/skills", "deploy", body: "config")
        try skill(".opencode/skills", "deploy", body: "home")
        try skill(".agents/skills", "deploy", body: "shared")
        #expect(opencodeRoots() == [home + "/.config/opencode/skills", home + "/.opencode/skills"])
        let load = try row("deploy").load(for: .opencode)
        #expect(load.used?.root.path == home + "/.opencode/skills")
        #expect(load.others.map(\.root.path) == [home + "/.config/opencode/skills", home + "/.agents/skills"])
        #expect(try row("deploy").load(for: .codex).used?.root.kind == .shared)
        // Next Term doesn't manage it either: Unify keeping it links the shared entry to it.
        let deploy = try row("deploy"), inventory = SkillInventory.scan(home: home)
        let own = try #require(deploy.copies.first { $0.root.path == home + "/.opencode/skills" })
        let steps = SkillUnify.plan(deploy, winner: own, in: inventory, claude: .link)
        #expect(steps == [.trash(home + "/.agents/skills/deploy"), .link(at: home + "/.agents/skills/deploy", to: own.realPath)])
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
        // `.opencode` in the home folder is read after the project's, so its copy comes first of all.
        try skill(home + "/.opencode/skills", "notes", "The user's older OpenCode notes.")
        #expect(entry("notes", "opencode")?.copy.place == "~/.opencode/skills" && entry("notes", "opencode")?.native == true)
        #expect(entry("notes", "opencode")?.others.map(\.place) == [".opencode/skills", "~/.config/opencode/skills", ".agents/skills"])
        #expect(entry("notes", "codex")?.copy.place == ".agents/skills")
    }

    /// OpenCode skips a SKILL.md whose front matter gives no name, so list_skills agrees with Settings › Skills: the
    /// named shared copy is the one it loads, and get_skill gives that one's text.
    @Test func aNamelessCopyIsNotTheOneItLoads() throws {
        let home = try folder("home")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let nameless = home + "/.config/opencode/skills/draft"
        try FileManager.default.createDirectory(atPath: nameless, withIntermediateDirectories: true)
        try "---\ndescription: No name here.\n---\n\nSkipped.\n".write(toFile: nameless + "/SKILL.md", atomically: true, encoding: .utf8)
        let reader = SkillLibrary.Reader(program: "opencode")
        let alone = SkillLibrary.entries(from: nil, home: home, nextTerm: [], reader: reader).first { $0.name == "draft" }
        #expect(alone?.native == false)
        try skill(home + "/.agents/skills", "draft", "Drafts.")
        let entry = SkillLibrary.entries(from: nil, home: home, nextTerm: [], reader: reader).first { $0.name == "draft" }
        #expect(entry?.copy.place == "~/.agents/skills" && entry?.native == true)
        #expect(entry?.others.map(\.place) == ["~/.config/opencode/skills"])
        let got = SkillLibrary.skill("draft", from: nil, home: home, nextTerm: [], reader: reader)
        #expect(got?.text.contains("Drafts.") == true)
        // Settings › Skills says the same.
        let row = SkillInventory.scan(home: home).rows.first { $0.name == "draft" }
        #expect(row?.load(for: .opencode).used?.root.kind == .shared)
        let skipped = try #require(entry?.others.first), loaded = try #require(entry?.copy)
        #expect(!reader.reads(skipped) && reader.reads(loaded))
    }

    /// Its config folder where XDG_CONFIG_HOME puts it outside the home folder is said by its full path.
    @Test func itsConfigFolderOutsideHomeIsSaidInFull() throws {
        let home = try folder("home"), elsewhere = try folder("xdg")
        defer { for path in [home, elsewhere] { try? FileManager.default.removeItem(atPath: path) } }
        let environment = ["XDG_CONFIG_HOME": elsewhere]
        let folders = SkillLibrary.personalFolders(".opencode/skills", home: home, environment: environment)
        #expect(folders.map(\.path) == [home + "/.opencode/skills", elsewhere + "/opencode/skills"])
        #expect(folders.map(\.place) == ["~/.opencode/skills", elsewhere + "/opencode/skills"])
        #expect(SkillLibrary.personalFolders(".agents/skills", home: home, environment: environment).map(\.place) == ["~/.agents/skills"])
        let inside = SkillLibrary.personalFolders(".opencode/skill", home: home, environment: ["XDG_CONFIG_HOME": home + "/cfg"])
        #expect(inside.map(\.place) == ["~/.opencode/skill", "~/cfg/opencode/skill"])
    }
}
