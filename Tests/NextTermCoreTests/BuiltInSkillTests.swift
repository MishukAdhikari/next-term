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
        let entries = SkillLibrary.entries(from: package, home: home, nextTerm: true)
        #expect(entries.map(\.name) == ["lint", "deploy", "review", "notes", "next-term-tabs"])
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
            SkillLibrary.entries(from: package, home: home, nextTerm: true, reader: .init(program: program)).first { $0.name == name }
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
        let overview = SkillLibrary.overview(project: package, home: home, nextTerm: true)
        for agent in SkillAgent.allCases {
            #expect(overview.byAgent[agent] == SkillLibrary.entries(from: package, home: home, nextTerm: true, reader: .init(program: agent.rawValue)))
        }
        // The project's skills only, A to Z; a link and its folder are one copy.
        #expect(overview.skills.map(\.name) == ["deploy", "lint"] && overview.skills[0].copies.count == 1 && overview.personal == 3)
        // Claude Code has no copy of its own in ~/.claude/skills: the project's. Codex reads the project's link first.
        #expect(overview.entry("deploy", for: .claudeCode)?.copy.place == ".claude/skills")
        #expect(overview.entry("deploy", for: .codex)?.copy.place == ".agents/skills" && overview.entry("deploy", for: .codex)?.native == true)
    }

    @Test func getSkillGivesTheTextAndFilesAndTheSwitchTakesItsOwnOut() throws {
        let (home, repo, package) = try fixture()
        defer { for path in [home, repo] { try? FileManager.default.removeItem(atPath: path) } }
        let lint = try #require(SkillLibrary.skill("lint", from: package, home: home, nextTerm: false))
        #expect(lint.text.contains("description: Lint the web package.") && lint.files == ["scripts/run.sh"])
        let theirs = try #require(SkillLibrary.skill("deploy", scope: .personal, from: package, home: home, nextTerm: false))
        #expect(theirs.copy.description == "The user's deploy." && theirs.entry.copy.scope == .project)
        #expect(SkillLibrary.skill("deploy", scope: .nextTerm, from: package, home: home, nextTerm: true) == nil)
        #expect(SkillLibrary.skill("missing", from: package, home: home, nextTerm: true) == nil)
        // Next Term's own: served from the app, only while it is on; nothing is written.
        #expect(SkillLibrary.skill("next-term-tabs", from: nil, home: home, nextTerm: true)?.text == BuiltInSkill.text)
        #expect(SkillLibrary.skill("next-term-tabs", from: nil, home: home, nextTerm: false) == nil)
        #expect(!FileManager.default.fileExists(atPath: home + "/.agents/skills/next-term-tabs"))
        // The user's or the project's own skill of that name comes first; Next Term's is named after it.
        try skill(repo + "/.agents/skills", "next-term-tabs", "Mine.")
        let mine = try #require(SkillLibrary.entries(from: repo, home: home, nextTerm: true).first { $0.name == "next-term-tabs" })
        #expect(mine.copy.description == "Mine." && mine.others.map(\.place) == ["Next Term"])
    }

    @Test func theSkillSaysWhenItApplies() {
        let text = BuiltInSkill.text
        #expect(text.hasPrefix("---\nname: next-term-tabs\ndescription: "))
        #expect(text.contains("\"you\": true") && text.contains("opened_by") && text.contains("Only a message the user typed to you counts as a yes"))
        #expect(text.contains("its own tokens") && text.contains("--dangerously-skip-permissions"))
        #expect(BuiltInSkill.description.contains("Next Term tabs"))
    }

    /// Within the 2,048 characters older Claude Code keeps, the offer whole in the first 512 some clients read.
    @Test func theOfferLeadsTheInstructionsOnlyInsideNextTerm() {
        let with = MCPServer.instructions(offeringTabs: true), without = MCPServer.instructions(offeringTabs: false)
        #expect(with.count <= 2_048 && without == MCPServer.instructions)
        let first = String(with.prefix(512))
        #expect(first.contains("offer once to run them in Next Term tabs") && first.contains("only after the user types yes")
                && first.contains("when the user named subagents") && first.contains("opened_by")
                && first.contains("get_skill next-term-tabs"))
        #expect(!without.contains("offer once"))
        // Still says what the tests of the rest pin.
        #expect(without.contains("list_tabs") && without.contains("brings back after an update or a quit keeps its id"))
    }

    @Test func aBridgeKnowsWhetherNextTermStartedIt() throws {
        // This test runs under some process (swift-testing's runner, a shell): its parent is found; a made-up app isn't.
        let parent = try #require(ProcessSnapshot.record(of: getpid())?.parent)
        let path = try #require(IDEPeer.executablePath(parent))
        #expect(MCPServer.runsUnder(executable: path))
        #expect(!MCPServer.runsUnder(executable: "/Applications/Not Next Term.app/Contents/MacOS/NotNextTerm"))
    }
}
