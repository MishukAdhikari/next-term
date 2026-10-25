import Foundation
import Testing
@testable import NextTermCore

/// list_shortcuts: the set, each command's live key, and a query that narrows by words or by a key.
@Suite struct MCPShortcutsTests {
    let commands = [
        MCPShortcuts.Command(title: "New Tab", place: "File › New Tab", key: "⌘T", defaultKey: "⌘T", changed: false),
        MCPShortcuts.Command(title: "New Remote Tab…", place: "File › New Remote Tab…", key: "⌥⌘T", defaultKey: "⌥⌘T", changed: false),
        MCPShortcuts.Command(title: "Split Right", place: "Window › Split Right", key: "⌃⌘D", defaultKey: "⌘D", changed: true,
                             note: "⌘D is Duplicate Line while the editor has the keyboard"),
        MCPShortcuts.Command(title: "Copy Path", place: "Project Sidebar", key: nil, defaultKey: nil, changed: false),
    ]

    func titles(_ answer: [String: Any]) -> [String] {
        (answer["commands"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
    }

    @Test func everyCommandWithoutAQuery() {
        let answer = MCPShortcuts.answer(set: "VS Code", commands: commands, query: nil)
        #expect(answer["shortcut_set"] as? String == "VS Code" && answer["count"] as? Int == 4 && titles(answer).count == 4)
        #expect((answer["change_keys"] as? String)?.contains("show_settings with tab keys") == true)
        #expect(titles(MCPShortcuts.answer(set: "Next Term", commands: commands, query: "  ")).count == 4)
    }

    @Test func wordsInTheTitleOrPlaceAllCount() {
        #expect(titles(MCPShortcuts.answer(set: "Next Term", commands: commands, query: "new tab")) == ["New Tab", "New Remote Tab…"])
        #expect(titles(MCPShortcuts.answer(set: "Next Term", commands: commands, query: "remote TAB")) == ["New Remote Tab…"])
        #expect(titles(MCPShortcuts.answer(set: "Next Term", commands: commands, query: "sidebar")) == ["Copy Path"])
        #expect(titles(MCPShortcuts.answer(set: "Next Term", commands: commands, query: "colours")).isEmpty)
    }

    @Test func aKeyFindsItsCommand() {
        #expect(titles(MCPShortcuts.answer(set: "Next Term", commands: commands, query: "⌥⌘T")) == ["New Remote Tab…"])
        #expect(titles(MCPShortcuts.answer(set: "Next Term", commands: commands, query: "⌘T")) == ["New Tab"])
    }

    @Test func aChangedKeyKeepsItsDefaultAndNote() throws {
        let rows = try #require(MCPShortcuts.answer(set: "Next Term", commands: commands, query: "split")["commands"] as? [[String: Any]])
        #expect(rows.count == 1 && rows[0]["key"] as? String == "⌃⌘D" && rows[0]["changed"] as? Bool == true && rows[0]["default_key"] as? String == "⌘D")
        #expect((rows[0]["note"] as? String)?.contains("Duplicate Line") == true)
        let plain = try #require(MCPShortcuts.answer(set: "Next Term", commands: commands, query: "new tab")["commands"] as? [[String: Any]])
        #expect(plain[0]["changed"] == nil && plain[0]["default_key"] == nil)
        let none = try #require(MCPShortcuts.answer(set: "Next Term", commands: commands, query: "copy path")["commands"] as? [[String: Any]])
        #expect(none[0]["key"] is NSNull)
    }

    /// new_tab's line: the prompt quoted for the shell, so nothing in it runs.
    @Test func newTabQuotesThePrompt() {
        #expect(MCPServer.commandLine("codex", prompt: nil) == "codex" && MCPServer.commandLine("codex", prompt: "") == "codex")
        #expect(MCPServer.commandLine("codex", prompt: "Fix the login test") == "codex 'Fix the login test'")
        #expect(MCPServer.commandLine("claude", prompt: "Don't run $(rm -rf ~) or `id`") == #"claude 'Don'\''t run $(rm -rf ~) or `id`'"#)
        #expect(!MCPServer.commandLine("gemini -i", prompt: "one\ntwo").contains("\n"))
    }

    /// A linked worktree inside an open project's folder opens in its own window; its project, a plain folder or a
    /// submodule-free subfolder stay in the owner's.
    @Test func aWorktreeInsideAProjectGetsItsOwnWindow() throws {
        guard let git = GitRunner.locateGit() else { return }
        let repo = try TemporaryRepository(git: git)
        defer { repo.remove() }
        let nested = repo.path + "/.claude/worktrees/side"
        repo.run(["worktree", "add", "-q", "-b", "side", nested])
        try FileManager.default.createDirectory(atPath: repo.path + "/src", withIntermediateDirectories: true)
        #expect(MCPServer.ownWorktree(of: nested, inside: repo.path) == canonicalPath(nested))
        try FileManager.default.createDirectory(atPath: nested + "/lib", withIntermediateDirectories: true)
        #expect(MCPServer.ownWorktree(of: nested + "/lib", inside: repo.path) == canonicalPath(nested))
        #expect(MCPServer.ownWorktree(of: repo.path + "/src", inside: repo.path) == nil)
        #expect(MCPServer.ownWorktree(of: nested, inside: nested) == nil)
    }
}
