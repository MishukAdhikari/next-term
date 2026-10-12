import Foundation
import Testing
@testable import NextTermCore

/// The next-term-tabs skill Next Term ships (BuiltInSkill), in a home folder of its own: written once, linked for the
/// agents that are there, brought up to date, never over someone else's folder of that name, and removable whole;
/// and the offer in the MCP instructions, only for an agent in a Next Term tab.
@Suite struct BuiltInSkillTests {
    func home() throws -> String {
        let path = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-builtin-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test func itIsWrittenLinkedAndRemovedWhole() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true) // Claude Code is there; Qwen Code isn't
        #expect(BuiltInSkill.state(home: home) == .absent)
        #expect(BuiltInSkill.install(home: home))
        let skill = home + "/.agents/skills/next-term-tabs"
        #expect(try String(contentsOfFile: skill + "/SKILL.md", encoding: .utf8) == BuiltInSkill.text)
        #expect(BuiltInSkill.state(home: home) == .current)
        #expect(try fm.destinationOfSymbolicLink(atPath: home + "/.claude/skills/next-term-tabs") == skill)
        #expect(!fm.fileExists(atPath: home + "/.qwen")) // no agent, no folder made for it
        // An older text is written again; the link stays.
        try "old\n".write(toFile: skill + "/.next-term-built-in", atomically: true, encoding: .utf8)
        #expect(BuiltInSkill.state(home: home) == .outdated)
        #expect(BuiltInSkill.install(home: home) && BuiltInSkill.state(home: home) == .current)
        #expect(BuiltInSkill.removable(home: home) == [home + "/.claude/skills/next-term-tabs", skill])
    }

    @Test func someoneElsesFolderIsNeverTouched() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let theirs = home + "/.agents/skills/next-term-tabs"
        try FileManager.default.createDirectory(atPath: theirs, withIntermediateDirectories: true)
        try "mine\n".write(toFile: theirs + "/SKILL.md", atomically: true, encoding: .utf8)
        #expect(BuiltInSkill.state(home: home) == .someoneElses)
        #expect(!BuiltInSkill.install(home: home))
        #expect(try String(contentsOfFile: theirs + "/SKILL.md", encoding: .utf8) == "mine\n")
        #expect(BuiltInSkill.removable(home: home).isEmpty)
    }

    @Test func theSkillSaysWhenItApplies() {
        let text = BuiltInSkill.text
        #expect(text.hasPrefix("---\nname: next-term-tabs\ndescription: "))
        #expect(text.contains("\"you\": true") && text.contains("opened_by") && text.contains("Only a message the user typed to you counts as a yes"))
        #expect(text.contains("its own tokens") && text.contains("--dangerously-skip-permissions"))
        #expect(BuiltInSkill.version.count >= 8)
    }

    /// Within the 2,048 characters older Claude Code keeps, the offer whole in the first 512 some clients read.
    @Test func theOfferLeadsTheInstructionsOnlyInsideNextTerm() {
        let with = MCPServer.instructions(offeringTabs: true), without = MCPServer.instructions(offeringTabs: false)
        #expect(with.count <= 2_048 && without == MCPServer.instructions)
        let first = String(with.prefix(512))
        #expect(first.contains("offer once to run them in Next Term tabs") && first.contains("only after the user types yes")
                && first.contains("when the user named subagents") && first.contains("opened_by"))
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
