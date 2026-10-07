import Foundation
import Testing
@testable import NextTermCore

@Suite struct BranchesTests {
    @Test func refsWithUpstreamStateAndWorktrees() {
        let records = [
            ["refs/heads/main", "a1b2c3d4e5", "1760000000", "origin/main", "behind 3", "*", "/repo", ""],
            ["refs/heads/feat/login", "b2c3d4e5f6", "1760000100", "origin/feat/login", "ahead 2, behind 1", " ", "", ""],
            ["refs/heads/old", "c3d4e5f6a7", "1750000000", "origin/old", "gone", " ", "", ""],
            ["refs/heads/claude/fix", "d4e5f6a7b8", "1760000200", "", "", " ", "/repo/.claude/worktrees/fix", ""],
            ["refs/remotes/origin/HEAD", "a1b2c3d4e5", "1760000000", "", "", " ", "", "refs/remotes/origin/main"],
            ["refs/remotes/origin/main", "e5f6a7b8c9", "1760000300", "", "", " ", "", ""],
        ].map { $0.joined(separator: "\0") }.joined(separator: "\n")
        let refs = BranchModel.parseRefs(Data(records.utf8))
        #expect(refs.map(\.name) == ["main", "feat/login", "old", "claude/fix", "origin/main"]) // origin/HEAD is left out
        #expect(refs[0].isHead && refs[0].behind == 3 && refs[0].ahead == 0 && refs[0].worktree == "/repo")
        #expect(refs[1].ahead == 2 && refs[1].behind == 1 && refs[1].upstream == "origin/feat/login")
        #expect(refs[2].upstreamGone)
        #expect(refs[4].isRemote && refs[4].remote == "origin" && refs[4].shortName == "main")
        #expect(BranchModel.isAgentBranch("claude/fix", worktree: nil) && BranchModel.isAgentBranch("fix/x", worktree: "/r/.claude/worktrees/x"))
        #expect(!BranchModel.isAgentBranch("feat/login", worktree: "/repo"))
        #expect(BranchModel.folder(of: "feat/login") == "feat" && BranchModel.folder(of: "main") == nil)
    }

    @Test func recentBranchesFromTheReflog() {
        let reflog = """
        checkout: moving from feat/a to main
        commit: Fix it
        checkout: moving from main to feat/a
        checkout: moving from gone-branch to main
        checkout: moving from main to 4cc062d
        checkout: moving from fix/b to main
        checkout: moving from main to fix/b
        """
        #expect(BranchModel.parseRecent(reflog, current: "main", existing: ["main", "feat/a", "fix/b"]) == ["feat/a", "fix/b"])
        #expect(BranchModel.parseRecent(reflog, current: "feat/a", existing: ["main", "feat/a", "fix/b"], limit: 1) == ["main"])
    }

    @Test func worktreeList() {
        let fields = ["worktree /repo", "HEAD aaa", "branch refs/heads/main", "",
                      "worktree /repo/.claude/worktrees/x", "HEAD bbb", "detached", "locked claude agent a1 (pid 42 start 1)", "",
                      "worktree /gone", "HEAD ccc", "branch refs/heads/old", "prunable gitdir file points to non-existent location", ""]
        let list = BranchModel.parseWorktrees(Data(fields.joined(separator: "\0").utf8 + [0]))
        #expect(list.count == 3)
        #expect(list[0] == Worktree(path: "/repo", head: "aaa", branch: "main"))
        #expect(list[1].isDetached && list[1].lockReason == "claude agent a1 (pid 42 start 1)")
        #expect(list[2].isPrunable && list[2].branch == "old")
    }

    @Test func branchNames() {
        #expect(BranchName.problem("feat/login") == nil)
        #expect(BranchName.problem("feat/login", existing: ["feat/login"]) != nil)
        for bad in ["", "-x", "a b", "a..b", "a/", "/a", "a//b", "a.", ".a", "a/.b", "a.lock", "a~1", "a^", "a:b", "a?", "a*", "a[", "a\\b",
                    "@", "HEAD", "x@{1}"] {
            #expect(BranchName.problem(bad) != nil, "\(bad)")
        }
        #expect(BranchName.problem("feat", existing: ["feat/login"]) != nil)    // a file where a folder is
        #expect(BranchName.problem("main/x", existing: ["main"]) != nil)
        #expect(BranchName.suggest(from: "  Fix the login bug ") == "Fix-the-login-bug")
        #expect(BranchName.suggest(from: "-feat/a..b: x?") == "feat/a.b-x")
        #expect(BranchName.problem(BranchName.suggest(from: "feat/new  idea!")) == nil)
    }

    @Test func gitFailures() {
        #expect(GitOutput.classify("fatal: Unable to create '/r/.git/index.lock': File exists.") == .lockHeld(path: "/r/.git/index.lock"))
        let overwritten = """
        error: Your local changes to the following files would be overwritten by checkout:
        \tsrc/a.swift
        \tREADME.md
        Please commit your changes or stash them before you switch branches.
        """
        #expect(GitOutput.classify(overwritten) == .localChanges(files: ["src/a.swift", "README.md"]))
        #expect(GitOutput.classify("fatal: 'feat/x' is already used by worktree at '/r/.claude/worktrees/x'") == .heldByWorktree(path: "/r/.claude/worktrees/x"))
        #expect(GitOutput.classify("error: the branch 'x' is not fully merged.") == .notFullyMerged)
        #expect(GitOutput.classify("To github.com:o/r.git\n!\trefs/heads/x:refs/heads/x\t[rejected] (fetch first)\nDone") == .pushRejected)
        #expect(GitOutput.classify("!\trefs/heads/x:refs/heads/x\t[rejected] (stale info)") == .leaseFailed)
        #expect(GitOutput.classify("fatal: Not possible to fast-forward, aborting.") == .diverged)
        #expect(GitOutput.classify("CONFLICT (content): Merge conflict in a.txt") == .conflicts)
        #expect(GitOutput.classify("Applying autostash resulted in conflicts.") == .conflicts)
        #expect(GitOutput.classify("git@github.com: Permission denied (publickey).") == .authentication)
        #expect(GitOutput.classify("fatal: could not read Username for 'https://github.com': terminal prompts disabled") == .authentication)
        #expect(GitOutput.classify("Host key verification failed.") == .hostKey)
        #expect(GitOutput.classify("error: gpg failed to sign the data") == .signing)
        #expect(GitOutput.classify("husky - pre-commit hook exited with code 1 (error)") == .hookFailed)
        #expect(GitOutput.classify("ssh: Could not resolve host: github.com") == .network)
        #expect(GitOutput.classify("Everything up-to-date") == .nothingToDo)
        #expect(GitOutput.classify("Switched to branch 'main'") == nil)
    }

    @Test func modelOfARealRepository() throws {
        guard let git = GitRunner.locateGit() else { return }
        let base = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path)).appendingPathComponent("nt-branches-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let origin = base.appendingPathComponent("origin.git").path, work = base.appendingPathComponent("work").path
        @discardableResult func sh(_ args: [String], in dir: String) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", dir, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        func write(_ path: String, _ text: String) throws {
            let url = URL(fileURLWithPath: work).appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(atPath: base.path, withIntermediateDirectories: true)
        sh(["init", "--bare", origin], in: base.path)
        sh(["clone", origin, work], in: base.path)
        try write("a.txt", "1\n")
        sh(["add", "-A"], in: work)
        sh(["commit", "-m", "one"], in: work)
        sh(["push", "-u", "origin", "main"], in: work)
        sh(["switch", "-c", "feat/login"], in: work)
        try write("a.txt", "2\n")
        sh(["commit", "-am", "two"], in: work)
        sh(["switch", "main"], in: work)
        sh(["branch", "claude/try"], in: work)
        sh(["worktree", "add", base.appendingPathComponent("wt").path, "claude/try"], in: work)

        let m = try #require(BranchModel.read(at: work, git: git))
        #expect(m.root == work && m.current == "main" && m.defaultBranch == "main")
        #expect(m.commonDir == work + "/.git" && m.gitDir == work + "/.git")
        #expect(Set(m.locals.map(\.name)) == ["main", "feat/login", "claude/try"])
        #expect(m.remotes.map(\.name) == ["origin/main"])
        #expect(m.recent == ["feat/login"])
        #expect(m.worktrees.count == 2 && m.worktrees[1].branch == "claude/try")
        let held = try #require(m.local("claude/try"))
        #expect(m.otherWorktree(of: held) == base.appendingPathComponent("wt").path && m.otherWorktree(of: m.currentRef!) == nil)
        #expect(m.inProgress == nil)

        // A merge that stops on a conflict is seen as in progress.
        try write("a.txt", "3\n")
        sh(["commit", "-am", "three"], in: work)
        #expect(sh(["merge", "feat/login"], in: work) != 0)
        #expect(BranchModel.read(at: work, git: git)?.inProgress == .merge)
        #expect(BranchModel.read(at: base.path, git: git) == nil) // not a repository
    }

    @Test func eachRemotesDefaultBranchIsShared() {
        let records = [
            ["refs/remotes/origin/HEAD", "a1b2c3d4e5", "1760000000", "", "", " ", "", "refs/remotes/origin/main"],
            ["refs/remotes/origin/main", "a1b2c3d4e5", "1760000000", "", "", " ", "", ""],
            ["refs/remotes/upstream/HEAD", "b2c3d4e5f6", "1760000000", "", "", " ", "", "refs/remotes/upstream/develop"],
            ["refs/remotes/my/fork/HEAD", "c3d4e5f6a7", "1760000000", "", "", " ", "", "refs/remotes/my/fork/trunk"],
        ].map { $0.joined(separator: "\0") }.joined(separator: "\n")
        let heads = BranchModel.parseRemoteHeads(Data(records.utf8))
        #expect(heads == ["origin": "main", "upstream": "develop", "my/fork": "trunk"])
        var m = BranchModel(root: "/r", gitDir: "/r/.git", commonDir: "/r/.git")
        m.defaultBranch = "main"
        m.remoteHeads = heads
        #expect(m.isShared("develop", on: "upstream") && !m.isShared("develop", on: "origin"))
        #expect(m.isShared("trunk", on: "my/fork") && m.isShared("main", on: "upstream") && m.isShared("master", on: "origin"))
        #expect(m.isShared("release/1.2", on: "origin") && !m.isShared("releases", on: "origin") && !m.isShared("feat/login", on: "upstream"))
    }

    @Test func pushingANewBranchRecordsNoDefaultBranch() throws {
        guard let git = GitRunner.locateGit() else { return }
        let base = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path)).appendingPathComponent("nt-heads-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let origin = base.appendingPathComponent("origin.git").path, work = base.appendingPathComponent("work").path
        func sh(_ args: [String], in dir: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", dir, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        try FileManager.default.createDirectory(atPath: base.path, withIntermediateDirectories: true)
        sh(["init", "--bare", "-b", "develop", origin], in: base.path)
        sh(["init", "-b", "develop", work], in: base.path)
        sh(["commit", "--allow-empty", "-m", "one"], in: work)
        sh(["remote", "add", "origin", origin], in: work)
        sh(["push", "-u", "origin", "develop"], in: work)

        // A push records no origin/HEAD, so develop, the remote's default branch, isn't known to be shared.
        let pushed = try #require(BranchModel.read(at: work, git: git))
        #expect(pushed.remoteHeads["origin"] == nil && !pushed.isShared("develop", on: "origin"))
        sh(["remote", "set-head", "origin", "--auto"], in: work)
        let known = try #require(BranchModel.read(at: work, git: git))
        #expect(known.remoteHeads == ["origin": "develop"] && known.isShared("develop", on: "origin"))
    }
}
