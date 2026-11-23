import Foundation
import Testing
@testable import NextTermCore

/// The approval panels' words for where a request comes from, and Remember's reach and note.
@Suite struct ApprovalPlaceTextTests {
    @Test func originNamesTheProjectAndALinkedWorktreeWithItsBranch() {
        #expect(ApprovalPlaceText.origin(project: "/Users/me/Code/coding-sessions", worktree: nil, branch: nil) == "coding-sessions")
        #expect(ApprovalPlaceText.origin(project: "/Users/me/Code/coding-sessions",
                                         worktree: "/Users/me/Code/coding-sessions/.claude/worktrees/fix-login", branch: "fix-login")
                == "coding-sessions \u{00B7} worktree fix-login (branch fix-login)")
        #expect(ApprovalPlaceText.origin(project: "/p/app", worktree: "/w/app-2", branch: nil) == "app \u{00B7} worktree app-2")
        #expect(ApprovalPlaceText.origin(project: "/p/app", worktree: "/p/app", branch: "main") == "app")
        #expect(ApprovalPlaceText.origin(project: nil, worktree: nil, branch: nil) == nil)
    }

    @Test func folderIsTheWholePathWithTildeOrTheRoot() {
        let home = "/Users/me"
        #expect(ApprovalPlaceText.folder("/Users/me/Code/app/src", project: "/Users/me/Code/app", worktree: nil, home: home) == "~/Code/app/src")
        #expect(ApprovalPlaceText.folder("/Users/me/Code/app", project: "/Users/me/Code/app", worktree: nil, home: home) == "project root")
        #expect(ApprovalPlaceText.folder("/Users/me/Code/app/", project: "/Users/me/Code/app", worktree: nil, home: home) == "project root")
        #expect(ApprovalPlaceText.folder("/w/fix", project: "/Users/me/Code/app", worktree: "/w/fix", home: home) == "worktree root")
        let scratch = "/private/tmp/claude-501/x/scratchpad"
        #expect(ApprovalPlaceText.folder(scratch, project: nil, worktree: nil, home: home) == scratch)
        #expect(ApprovalPlaceText.folder("/Users/meow/x", project: nil, worktree: nil, home: home) == "/Users/meow/x")
    }

    @Test func branchIsReadFromAWorktreesHead() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("nt-branch-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        let main = base + "/main", tree = base + "/tree", gitDir = main + "/.git/worktrees/tree"
        try FileManager.default.createDirectory(atPath: gitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: tree, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(toFile: main + "/.git/HEAD", atomically: true, encoding: .utf8)
        try "ref: refs/heads/fix/login\n".write(toFile: gitDir + "/HEAD", atomically: true, encoding: .utf8)
        try "gitdir: \(gitDir)\n".write(toFile: tree + "/.git", atomically: true, encoding: .utf8)
        #expect(ApprovalPlaceText.branch(of: main) == "main")
        #expect(ApprovalPlaceText.branch(of: tree) == "fix/login")
        try "0123456789abcdef\n".write(toFile: gitDir + "/HEAD", atomically: true, encoding: .utf8)
        #expect(ApprovalPlaceText.branch(of: tree) == nil)
        #expect(ApprovalPlaceText.branch(of: base) == nil)
    }

    @Test func reachNamesTheLongestChoice() {
        #expect(ApprovalPlaceText.reach(["Only this time", "For 15 minutes", "Always in app"]) == "Up to: Always in app")
        #expect(ApprovalPlaceText.reach(["Only this time", "In this folder until Next Term quits"])
                == "Up to: In this folder until Next Term quits")
        #expect(ApprovalPlaceText.reach(["Only this time"]) == nil)
    }

    @Test func rememberNoteIsOneLineWithHowToGetAlways() {
        let shell = SecretAlwaysRules.shellSyntaxRefusal
        let note = ApprovalPlaceText.rememberNote(["PE_TOKEN asks for Touch ID every time it\u{2019}s used, so only Allow once is offered."],
                                                  refusal: shell)
        #expect(note == "PE_TOKEN asks for Touch ID every time it\u{2019}s used, so only Allow once is offered. " + shell
                + " To allow it every time, the agent can run it as one plain command, without pipes, $(\u{2026}), redirections or globs.")
        #expect(ApprovalPlaceText.rememberNote([nil], refusal: "Always isn\u{2019}t offered: npx -y fetches new code each time.")
                == "Always isn\u{2019}t offered: npx -y fetches new code each time.")
        #expect(ApprovalPlaceText.rememberNote([nil], refusal: nil) == nil)
        #expect(SecretAlwaysRules.refusal(.init(words: ["ls"], usesShellSyntax: true), scopes: [], writable: { _ in false }) == shell)
    }
}
