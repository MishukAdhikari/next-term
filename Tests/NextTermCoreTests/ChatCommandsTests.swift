import Foundation
import Testing
@testable import NextTermCore

/// The prompt box's "/" menu: what counts as typing a command, which commands match, and the user's own command files.
@Suite struct ChatCommandsTests {
    let list = ["compact", "clear", "config", "context", "model", "review"].map { ChatCommand(name: $0, description: "", source: .builtIn) }

    @Test func onlyALeadingSlashWordOpensTheMenu() {
        #expect(ChatCommands.typed("/") == "")
        #expect(ChatCommands.typed("/comp") == "comp")
        #expect(ChatCommands.typed("/compact keep tests") == nil)
        #expect(ChatCommands.typed("/compact\nmore") == nil)
        #expect(ChatCommands.typed("say /compact") == nil)
        #expect(ChatCommands.typed("/usr/bin") == nil)
    }

    @Test func namesThatStartWithItComeFirstThenThoseThatHoldIt() {
        #expect(ChatCommands.matches(list, typed: "co").map(\.name) == ["compact", "config", "context"])
        #expect(ChatCommands.matches(list, typed: "e").map(\.name) == ["clear", "context", "model", "review"])
        #expect(ChatCommands.matches(list, typed: "CL").map(\.name) == ["clear"])
        #expect(ChatCommands.matches(list, typed: "").count == list.count)
        #expect(ChatCommands.matches(list, typed: "xyz").isEmpty)
    }

    @Test func aNameTypedInFullAloneLeavesNothingToOffer() {
        #expect(ChatCommands.matches(list, typed: "model").isEmpty)
        #expect(ChatCommands.matches(list, typed: "con").map(\.name) == ["config", "context"])
    }

    @Test func atMostEightShow() {
        let many = (0..<20).map { ChatCommand(name: "c\($0)", description: "", source: .custom) }
        #expect(ChatCommands.matches(many, typed: "c").count == ChatCommands.shownAtMost)
    }

    @Test func eachAgentHasItsOwnBuiltInsAndScreensAreMarked() {
        let claude = ChatCommands.builtIn(for: .claude)
        #expect(claude.contains { $0.name == "compact" && !$0.opensScreen })
        #expect(claude.contains { $0.name == "model" && $0.opensScreen })
        #expect(ChatCommands.builtIn(for: .codex).contains { $0.name == "diff" })
        #expect(ChatCommands.builtIn(for: .gemini).isEmpty)
    }

    @Test func sessionCommandsDropTheirSlashAndRepeats() {
        #expect(ChatCommands.session(["/plan", "plan", "web", ""]).map(\.name) == ["plan", "web"])
    }

    @Test func commandFilesGiveTheirDescriptionOrFirstLine() {
        #expect(ChatCommands.summary(of: "---\ndescription: \"Ship it\"\nmodel: x\n---\nBody") == "Ship it")
        #expect(ChatCommands.summary(of: "\n# Tidy the readme\nmore") == "Tidy the readme")
        #expect(ChatCommands.summary(of: "---\nallowed-tools: x\n---\n\nDo the thing") == "Do the thing")
    }

    @Test func claudeCodeCommandFilesAndCodexPromptsAreRead() throws {
        let fm = FileManager.default
        let base = NSTemporaryDirectory() + "nt-chatcommands-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: base) }
        let home = base + "/home", project = base + "/home/work/proj"
        try fm.createDirectory(atPath: project + "/.git", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: project + "/.claude/commands", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/.claude/commands", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/.codex/prompts", withIntermediateDirectories: true)
        try "Ship the branch".write(toFile: project + "/.claude/commands/ship.md", atomically: true, encoding: .utf8)
        try "Mine".write(toFile: home + "/.claude/commands/ship.md", atomically: true, encoding: .utf8)
        try "Built in".write(toFile: home + "/.claude/commands/compact.md", atomically: true, encoding: .utf8)
        try "Draft notes".write(toFile: home + "/.codex/prompts/notes.md", atomically: true, encoding: .utf8)

        let claude = ChatCommands.custom(for: .claude, folder: project, home: home)
        #expect(claude.filter { $0.name == "ship" }.map(\.description) == ["Ship the branch"]) // the project's first
        #expect(!claude.contains { $0.name == "compact" }) // the built-in keeps its name
        #expect(ChatCommands.custom(for: .codex, folder: project, home: home).map(\.name) == ["prompts:notes"])
    }
}
