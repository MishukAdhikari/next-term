import Foundation
import Testing
@testable import NextTermCore

/// Next Term's skill library (SkillLibrary) in a home and a project of their own: the folders each agent reads, its rule
/// for a name in more than one place, what it loads itself, and Next Term's own next-term-tabs, served and never
/// written; and the offer in the MCP instructions, only for an agent in a Next Term tab.
@Suite struct BuiltInSkillTests {
    func folder(_ label: String) throws -> String {
        let path = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-\(label)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func skill(_ folder: String, _ name: String, _ description: String, files: [String] = []) throws {
        let path = folder + "/" + name
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: \(description)\n---\n\nSteps.\n".write(toFile: path + "/SKILL.md", atomically: true, encoding: .utf8)
        for file in files {
            try FileManager.default.createDirectory(atPath: ((path + "/" + file) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try "x\n".write(toFile: path + "/" + file, atomically: true, encoding: .utf8)
        }
    }

    /// A home with `deploy` in the shared folder and `notes` in Claude Code's, linked from Claude Code's to the shared
    /// `review`; a repository with its own `deploy` and a package with `lint`.
    func fixture() throws -> (home: String, repo: String, package: String) {
        let home = try folder("home"), repo = try folder("repo")
        try FileManager.default.createDirectory(atPath: repo + "/.git", withIntermediateDirectories: true)
        try skill(home + "/.agents/skills", "deploy", "The user's deploy.")
        try skill(home + "/.agents/skills", "review", "Review a change.")
        try skill(home + "/.claude/skills", "notes", "Keep notes.")
        try FileManager.default.createSymbolicLink(atPath: home + "/.claude/skills/review", withDestinationPath: "../../.agents/skills/review")
        try skill(repo + "/.claude/skills", "deploy", "The project's deploy.")
        let package = repo + "/packages/web"
        try skill(package + "/.agents/skills", "lint", "Lint the web package.", files: ["scripts/run.sh", "node_modules/x/y.js", ".git/HEAD"])
        return (home, repo, package)
    }

    @Test func itFindsTheProjectsSkillsUpToTheRepositoryTop() throws {
        let (home, repo, package) = try fixture()
        defer { for path in [home, repo] { try? FileManager.default.removeItem(atPath: path) } }
        #expect(SkillLibrary.projectFolders(from: package, home: home) == [package, repo + "/packages", repo])
        #expect(SkillLibrary.projectFolders(from: home, home: home).isEmpty) // never the home folder
        let entries = SkillLibrary.entries(from: package, home: home, nextTerm: BuiltInSkill.all)
        #expect(entries.map(\.name) == ["lint", "deploy", "review", "notes", "next-term-tabs", "next-term-worktrees", "next-term-setup"])
        let lint = try #require(entries.first)
        #expect(lint.copy.scope == .project && lint.copy.place == "packages/web/.agents/skills" && !lint.native)
        // An agent Next Term doesn't know gets the nearest copy, and the other is named.
        let deploy = entries[1]
        #expect(deploy.copy.scope == .project && deploy.copy.description == "The project's deploy." && deploy.others.map(\.place) == ["~/.agents/skills"])
        // A link to the shared copy is that copy.
        #expect(entries[2].others.isEmpty)
        #expect(entries.last?.copy.scope == .nextTerm && entries.last?.copy.place == "Next Term")
    }

    @Test func eachAgentGetsTheCopyItWouldLoad() throws {
        let (home, repo, package) = try fixture()
        defer { for path in [home, repo] { try? FileManager.default.removeItem(atPath: path) } }
        func entry(_ name: String, _ program: String) -> SkillLibrary.Entry? {
            SkillLibrary.entries(from: package, home: home, nextTerm: BuiltInSkill.all, reader: .init(program: program)).first { $0.name == name }
        }
        // Claude Code reads .claude/skills only: the project's deploy (the user's is in the shared folder it doesn't
        // read), its own notes, review through its link; lint isn't its.
        #expect(entry("deploy", "claude")?.copy.place == ".claude/skills" && entry("deploy", "claude")?.native == true)
        #expect(entry("deploy", "claude")?.others.map(\.place) == ["~/.agents/skills"])
        #expect(entry("review", "claude")?.copy.place == "~/.claude/skills" && entry("review", "claude")?.native == true)
        #expect(entry("lint", "claude")?.native == false)
        // Claude Code takes the user's copy over the project's when it reads both.
        try skill(home + "/.claude/skills", "deploy", "The user's Claude deploy.")
        #expect(entry("deploy", "claude")?.copy.description == "The user's Claude deploy.")
        // Codex reads .agents/skills: the package's lint and the user's deploy are its.
        #expect(entry("lint", "codex")?.native == true && entry("notes", "codex")?.native == false)
        #expect(entry("deploy", "codex")?.copy.place == "~/.agents/skills" && entry("deploy", "codex")?.native == true)
        // Command Code: .commandcode before .agents, the project's before the user's.
        try skill(repo + "/.commandcode/skills", "review", "The project's review.")
        #expect(entry("review", "cmd")?.copy.place == ".commandcode/skills" && entry("review", "cmd")?.native == true)
        // Next Term's own is never an agent's.
        #expect(entry("next-term-tabs", "claude")?.native == false)
    }

    /// Settings › Skills › Project and list_skills come from one engine: what Settings shows for an agent is what
    /// list_skills gives it.
    @Test func theOverviewIsWhatEachAgentIsTold() throws {
        let (home, repo, package) = try fixture()
        defer { for path in [home, repo] { try? FileManager.default.removeItem(atPath: path) } }
        try FileManager.default.createDirectory(atPath: repo + "/.agents/skills", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: repo + "/.agents/skills/deploy", withDestinationPath: "../../.claude/skills/deploy")
        let overview = SkillLibrary.overview(project: package, home: home, nextTerm: BuiltInSkill.all)
        for agent in SkillAgent.allCases {
            #expect(overview.byAgent[agent] == SkillLibrary.entries(from: package, home: home, nextTerm: BuiltInSkill.all, reader: .init(program: agent.rawValue)))
        }
        // The project's skills only, A to Z; a link and its folder are one copy.
        #expect(overview.skills.map(\.name) == ["deploy", "lint"] && overview.skills[0].copies.count == 1 && overview.personal == 3)
        // Claude Code has no copy of its own in ~/.claude/skills: the project's. Codex reads the project's link first.
        #expect(overview.entry("deploy", for: .claudeCode)?.copy.place == ".claude/skills")
        #expect(overview.entry("deploy", for: .codex)?.copy.place == ".agents/skills" && overview.entry("deploy", for: .codex)?.native == true)
    }

    /// A cloned repository's skill folder is anyone's: a SKILL.md that links out of its folder, to a secrets file, to a
    /// device or a FIFO, or that is too large, is never read (and never hangs the read).
    @Test func aSkillsFileIsReadOnlyInsideItsFolder() throws {
        let repo = try folder("repo"), home = try folder("home")
        defer { for path in [home, repo] { try? FileManager.default.removeItem(atPath: path) } }
        let fm = FileManager.default, skills = repo + "/.claude/skills"
        try fm.createDirectory(atPath: repo + "/.git", withIntermediateDirectories: true)
        try "---\nname: dotenv\ndescription: x\n---\nAPI_KEY=sk-live-0123456789\n".write(toFile: repo + "/.env", atomically: true, encoding: .utf8)
        try "---\nname: outside\ndescription: x\n---\n".write(toFile: home + "/note.md", atomically: true, encoding: .utf8)
        func make(_ name: String, link target: String? = nil, file: (String, String)? = nil) throws {
            try fm.createDirectory(atPath: skills + "/" + name, withIntermediateDirectories: true)
            if let file { try file.1.write(toFile: skills + "/" + name + "/" + file.0, atomically: true, encoding: .utf8) }
            if let target { try fm.createSymbolicLink(atPath: skills + "/" + name + "/SKILL.md", withDestinationPath: target) }
        }
        try make("dotenv", link: "../../../.env")
        try make("zero", link: "/dev/zero")
        try make("outside", link: home + "/note.md")
        try make("keyed", link: "id.pem", file: ("id.pem", "---\nname: keyed\ndescription: x\n---\n"))
        try make("inside", link: "real.md", file: ("real.md", "---\nname: inside\ndescription: Read.\n---\n"))
        try make("big", file: ("SKILL.md", "---\nname: big\ndescription: x\n---\n" + String(repeating: "a", count: 300 * 1024)))
        try make("fifo")
        #expect(mkfifo(skills + "/fifo/SKILL.md", 0o644) == 0)
        let entries = SkillLibrary.entries(from: repo, home: home, nextTerm: [])
        #expect(entries.map(\.name) == ["inside"] && entries.first?.copy.description == "Read.")
        #expect(SkillLibrary.skill("dotenv", from: repo, home: home, nextTerm: []) == nil)
        #expect(SkillLibrary.readText(skills + "/zero/SKILL.md", in: skills + "/zero") == nil)
    }

    @Test func getSkillGivesTheTextAndFilesAndTheSwitchTakesItsOwnOut() throws {
        let (home, repo, package) = try fixture()
        defer { for path in [home, repo] { try? FileManager.default.removeItem(atPath: path) } }
        let lint = try #require(SkillLibrary.skill("lint", from: package, home: home, nextTerm: []))
        #expect(lint.text.contains("description: Lint the web package.") && lint.files == ["scripts/run.sh"])
        let theirs = try #require(SkillLibrary.skill("deploy", scope: .personal, from: package, home: home, nextTerm: []))
        #expect(theirs.copy.description == "The user's deploy." && theirs.entry.copy.scope == .project)
        #expect(SkillLibrary.skill("deploy", scope: .nextTerm, from: package, home: home, nextTerm: BuiltInSkill.all) == nil)
        #expect(SkillLibrary.skill("missing", from: package, home: home, nextTerm: BuiltInSkill.all) == nil)
        // Next Term's own: served from the app, only while it is on; nothing is written.
        for builtIn in BuiltInSkill.all {
            #expect(SkillLibrary.skill(builtIn.name, from: nil, home: home, nextTerm: BuiltInSkill.all)?.text == builtIn.text)
            #expect(SkillLibrary.skill(builtIn.name, from: nil, home: home, nextTerm: []) == nil)
        }
        // With tabs off, only next-term-tabs goes.
        #expect(SkillLibrary.skill("next-term-tabs", from: nil, home: home, nextTerm: BuiltInSkill.offered(tabs: false)) == nil)
        #expect(SkillLibrary.skill("next-term-setup", from: nil, home: home, nextTerm: BuiltInSkill.offered(tabs: false))?.text == BuiltInSkill.setup.text)
        #expect(!FileManager.default.fileExists(atPath: home + "/.agents/skills/next-term-tabs"))
        // The user's or the project's own skill of that name comes first; Next Term's is named after it.
        try skill(repo + "/.agents/skills", "next-term-tabs", "Mine.")
        let mine = try #require(SkillLibrary.entries(from: repo, home: home, nextTerm: BuiltInSkill.all).first { $0.name == "next-term-tabs" })
        #expect(mine.copy.description == "Mine." && mine.others.map(\.place) == ["Next Term"])
    }

    @Test func theSkillSaysWhenItApplies() {
        let text = BuiltInSkill.tabs.text
        #expect(text.hasPrefix("---\nname: next-term-tabs\ndescription: "))
        #expect(text.contains("\"you\": true") && text.contains("opened_by") && text.contains("Only a message the user typed to you counts as a yes"))
        #expect(text.contains("its own tokens") && text.contains("--dangerously-skip-permissions"))
        #expect(BuiltInSkill.tabs.description.contains("Next Term tabs"))
    }

    /// Each built-in in the Agent Skills format, named as it is served, with a description list_skills shows whole (it cuts
    /// at 300 characters), and only next-term-tabs under the tabs switch.
    @Test func everyBuiltInIsWholeInListSkills() {
        #expect(BuiltInSkill.all.map(\.name) == ["next-term-tabs", "next-term-worktrees", "next-term-setup"])
        for builtIn in BuiltInSkill.all {
            #expect(builtIn.text.hasPrefix("---\nname: \(builtIn.name)\ndescription: "), "\(builtIn.name)")
            #expect(!builtIn.description.isEmpty && builtIn.description.count <= 300, "\(builtIn.name): \(builtIn.description.count)")
            #expect(BuiltInSkill.named(builtIn.name) == builtIn)
        }
        #expect(BuiltInSkill.offered(tabs: true) == BuiltInSkill.all)
        #expect(BuiltInSkill.offered(tabs: false).map(\.name) == ["next-term-worktrees", "next-term-setup"])
    }

    /// next-term-worktrees: finds what the project has by reading only, asks once, and moves with the same agent.
    @Test func theWorktreeSkillLooksAsksAndHandsOff() {
        let text = BuiltInSkill.worktrees.text
        #expect(text.contains("git worktree list --porcelain") && text.contains("refs/heads") && text.contains("gh pr view"))
        #expect(text.contains("Only a message the user typed to you counts as a yes") && text.contains("Never switch this checkout's branch"))
        #expect(text.contains("`new_tab`") && text.contains("`hand_off: true`") && text.contains("never quote it yourself") && !text.contains("`send_to_tab`"))
        #expect(text.contains("codex resume <id> -C") && text.contains("hand-off") && text.contains("stop working on that task here"))
        #expect(text.contains("--no-optional-locks") && text.contains("isCrossRepository") && text.contains("<repo>-wt-"))
        #expect(BuiltInSkill.tabs.text.contains("never quote it yourself") && !BuiltInSkill.tabs.text.contains("claude \"…\""))
    }

    /// next-term-setup: what MCP may change, Settings for the rest, and keys only from list_shortcuts, in a table.
    @Test func theSetupSkillChangesWhatItMayAndGivesLiveKeys() {
        let text = BuiltInSkill.setup.text
        #expect(text.contains("`settings_get`") && text.contains("`settings_set`") && text.contains("`set_layout`") && text.contains("`apply_import`"))
        #expect(text.contains("`list_shortcuts`") && text.contains("never from memory") && text.contains("`show_settings`"))
        #expect(text.contains("| Key | What | Where | Done |") && text.contains("Never agent control"))
        for tab in MCPShortcuts.settingsTabs { #expect(text.contains(tab), "\(tab)") }
        #expect(text.contains("Settings › Tasks") && text.contains("skills, tasks or secrets"))
    }

    /// Within the 2,048 characters older Claude Code keeps, the skills whole in the first 512 some clients read, and only
    /// for an agent in a Next Term tab.
    @Test func theSkillsLeadTheInstructionsOnlyInsideNextTerm() {
        let with = MCPServer.instructions(inTab: true, offeringTabs: true), noTabs = MCPServer.instructions(inTab: true, offeringTabs: false)
        let outside = MCPServer.instructions(inTab: false, offeringTabs: true)
        #expect(with.utf16.count <= 2_048 && noTabs.utf16.count <= 2_048 && outside == MCPServer.instructions)
        let first = String(with.prefix(512))
        #expect(first.contains("get_skill next-term-tabs when the user asks for work in parallel") && first.contains("only after the user types yes")
                && first.contains("next-term-worktrees when the user pastes a repo, branch or PR")
                && first.contains("next-term-setup when the user asks to change Next Term") && first.contains("opened_by"))
        let firstNoTabs = String(noTabs.prefix(512))
        #expect(!noTabs.contains("next-term-tabs") && firstNoTabs.contains("get_skill next-term-worktrees") && firstNoTabs.contains("next-term-setup"))
        #expect(!outside.contains("get_skill next-term"))
        // Still says what the tests of the rest pin.
        #expect(outside.contains("list_tabs") && outside.contains("brings back after an update or a quit keeps its id"))
    }

    @Test func aBridgeKnowsWhetherNextTermStartedIt() throws {
        // This test runs under some process (swift-testing's runner, a shell): its parent is found; a made-up app isn't.
        let parent = try #require(ProcessSnapshot.record(of: getpid())?.parent)
        let path = try #require(IDEPeer.executablePath(parent))
        #expect(MCPServer.runsUnder(executable: path))
        #expect(!MCPServer.runsUnder(executable: "/Applications/Not Next Term.app/Contents/MacOS/NotNextTerm"))
    }
}
