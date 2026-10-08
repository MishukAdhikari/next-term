import Foundation
import Testing
@testable import NextTermCore

@Suite struct BranchCommandsTests {
    @Test func commandsAsTyped() {
        #expect(BranchCommand.deleteOnRemote(remote: "origin", branch: "feat/x", sha: "abc")
            == ["push", "--porcelain", "--force-with-lease=refs/heads/feat/x:abc", "origin", "--delete", "refs/heads/feat/x"])
        #expect(BranchCommand.restoreOnRemote(remote: "origin", branch: "feat/x", sha: "abc") == ["push", "--porcelain", "origin", "abc:refs/heads/feat/x"])
        #expect(BranchCommand.fetchInto(local: "feat/x", remote: "my/fork", upstream: "x") == ["fetch", "my/fork", "refs/heads/x:refs/heads/feat/x"])
        #expect(BranchCommand.checkoutAndUpdate("main") == [["switch", "main"], ["merge", "--ff-only", "--autostash", "@{upstream}"]])
        #expect(BranchCommand.lock(worktree: "/w", reason: "") == ["worktree", "lock", "/w"])
        #expect(BranchCommand.lock(worktree: "/w", reason: "why") == ["worktree", "lock", "--reason", "why", "/w"])
        #expect(BranchCommand.unlock(worktree: "/w") == ["worktree", "unlock", "/w"])
    }

    @Test func remotesWithASlashInTheirName() {
        var m = BranchModel(root: "/r", gitDir: "/r/.git", commonDir: "/r/.git")
        func split(_ name: String) -> String? { m.remoteAndBranch(of: name).map { $0.remote + " " + $0.branch } }
        func upstream(_ ref: BranchRef) -> String? { m.upstream(of: ref).map { $0.remote + " " + $0.branch } }
        #expect(split("origin/feat/x") == "origin feat/x") // no list read: the first "/"
        #expect(upstream(BranchRef(name: "y", isRemote: false, sha: "a", upstream: "feat/x")) == nil) // nor is a local "feat/x" taken for one
        m.configuredRemotes = ["origin", "my", "my/fork"]
        #expect(split("my/fork/trunk") == "my/fork trunk" && split("my/trunk") == "my trunk" && split("origin/feat/x") == "origin feat/x")
        #expect(split("nowhere/x") == nil && split("origin/") == nil)
        #expect(upstream(BranchRef(name: "x", isRemote: false, sha: "a", upstream: "my/fork/x")) == "my/fork x")
        #expect(upstream(BranchRef(name: "x", isRemote: false, sha: "a", upstream: "origin/x", upstreamGone: true)) == nil)
        #expect(upstream(BranchRef(name: "x", isRemote: false, sha: "a", upstream: "main")) == nil) // tracks a local branch
    }

    @Test func theWorktreeAFolderIsIn() throws {
        let base = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path)).appendingPathComponent("nt-wt-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        for folder in ["/repo/src", "/repo/.claude/worktrees/x/src", "/repo-other"] {
            try FileManager.default.createDirectory(atPath: base + folder, withIntermediateDirectories: true)
        }
        var m = BranchModel(root: base + "/repo", gitDir: "", commonDir: "")
        m.worktrees = [Worktree(path: base + "/repo", head: "a", branch: "main"), Worktree(path: base + "/repo/.claude/worktrees/x", head: "b", branch: nil)]
        #expect(m.worktree(containing: base + "/repo/src")?.branch == "main")
        #expect(m.worktree(containing: base + "/repo/.claude/worktrees/x/src")?.head == "b") // the nested one, not the repository around it
        #expect(m.worktree(containing: base + "/repo/.claude/worktrees/x")?.head == "b")
        #expect(m.worktree(containing: base + "/repo-other") == nil)
    }

    @Test func lockHolders() throws {
        let claude = try #require(LockHolder.parse("claude agent agent-a39109cc29b9d32bf (pid 7639 start Tue Oct  6 06:05:05 2026)"))
        #expect(claude.pid == 7639 && claude.program == "claude")
        #expect(claude.started == Date(timeIntervalSince1970: 1_791_266_705)) // 2026-10-06 06:05:05 UTC
        #expect(LockHolder.parse("claude agent a1 (pid 42)") == LockHolder(pid: 42, started: nil, program: "claude"))
        #expect(LockHolder.parse("claude agent a1 (pid 42 start 1)")?.started == nil)
        #expect(LockHolder.parse("moving it to the new disk") == nil && LockHolder.parse("(pid 0)") == nil)
        // Alive: that pid runs and started in that second. A pid that ended, or was given to a later process, is not.
        let start = try #require(claude.started)
        #expect(claude.isAlive { $0 == 7639 ? start.addingTimeInterval(0.6) : nil })
        #expect(!claude.isAlive { _ in start.addingTimeInterval(3600) })
        #expect(!claude.isAlive { _ in nil })
        #expect(LockHolder(pid: 42, started: nil, program: "x").isAlive { _ in Date() })
    }

    /// A lock as Claude Code writes it, for this process: alive. For a process that has ended: stale.
    @Test func aRealProcessHoldsTheLock() throws {
        func lstart(_ pid: Int32) -> String {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["-o", "lstart=", "-p", String(pid)]
            p.environment = ["LC_ALL": "C", "TZ": "UTC"]
            p.standardOutput = out
            try? p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let holder = try #require(LockHolder.parse("claude agent agent-1 (pid \(me) start \(lstart(me)))"))
        #expect(holder.started != nil && holder.isAlive())
        let ended = Process()
        ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try ended.run()
        ended.waitUntilExit()
        #expect(LockHolder.startTime(of: ended.processIdentifier) == nil)
        #expect(!LockHolder(pid: ended.processIdentifier, started: holder.started, program: "claude").isAlive())
        #expect(AgentName.of(program: "claude") == "Claude Code" && AgentName.of(program: "codex") == "Codex" && AgentName.of(program: "zork") == "zork")
    }

    /// The branch popup's writes against a remote, in real repositories: update a branch that isn't
    /// checked out (forward only), delete a branch on the remote and put it back, checkout and update.
    @Test func writesAgainstARemote() throws {
        let origin = try #require(ScratchRepo())
        defer { origin.remove() }
        let work = ScratchRepo(existing: origin.work + "-work", git: origin.git)
        let theirs = ScratchRepo(existing: origin.work + "-theirs", git: origin.git)
        defer { work.remove(); theirs.remove() }
        try origin.write("a.txt", "1\n")
        origin.commit("One")
        origin.sh(["branch", "feat/x"])
        origin.sh(["clone", "-q", origin.work, work.work])
        origin.sh(["clone", "-q", origin.work, theirs.work])
        work.sh(["branch", "--track", "feat/x", "origin/feat/x"])
        theirs.sh(["switch", "-q", "feat/x"])
        try theirs.write("b.txt", "theirs\n")
        let ahead = theirs.commit("Theirs")
        theirs.sh(["push", "-q", "origin", "feat/x"])

        // Behind only, checked out nowhere: fetched into, forward.
        let model = try #require(BranchModel.read(at: work.work, git: work.git))
        let feat = try #require(model.local("feat/x"))
        let (remote, upstream) = try #require(model.upstream(of: feat))
        #expect(remote == "origin" && upstream == "feat/x" && model.configuredRemotes == ["origin"])
        #expect(work.status(BranchCommand.fetchInto(local: "feat/x", remote: remote, upstream: upstream)) == 0)
        #expect(work.sh(["rev-parse", "feat/x"]) == ahead)

        // Diverged: refused, the branch stays, and the counts are fresh to say so.
        work.sh(["switch", "-q", "feat/x"])
        try work.write("c.txt", "mine\n")
        let mine = work.commit("Mine")
        work.sh(["switch", "-q", "main"])
        try theirs.write("b.txt", "theirs again\n")
        theirs.commit("Theirs again")
        theirs.sh(["push", "-q", "origin", "feat/x"])
        let refused = work.output(BranchCommand.fetchInto(local: "feat/x", remote: remote, upstream: upstream))
        #expect(refused.status != 0 && GitOutput.classify(refused.text) == .pushRejected, "\(refused.text)")
        #expect(work.sh(["rev-parse", "feat/x"]) == mine)
        let diverged = try #require(BranchModel.read(at: work.work, git: work.git)?.local("feat/x"))
        #expect(diverged.ahead == 1 && diverged.behind == 1)

        // Checked out: git refuses to fetch into it.
        work.sh(["switch", "-q", "feat/x"])
        let held = work.output(BranchCommand.fetchInto(local: "feat/x", remote: remote, upstream: upstream))
        if case .heldByWorktree? = GitOutput.classify(held.text) {} else { Issue.record("not held: \(held.text)") }
        work.sh(["switch", "-q", "main"])

        // Delete on Remote after someone pushed since your last fetch: refused as stale, nothing deleted.
        work.sh(["fetch", "-q", "origin"])
        let shown = work.sh(["rev-parse", "origin/feat/x"])
        try theirs.write("b.txt", "theirs, after your fetch\n")
        let pushedSince = theirs.commit("Theirs, after your fetch")
        theirs.sh(["push", "-q", "origin", "feat/x"])
        let stale = work.output(BranchCommand.deleteOnRemote(remote: "origin", branch: "feat/x", sha: shown))
        #expect(stale.status != 0 && GitOutput.classify(stale.text) == .leaseFailed, "\(stale.text)")
        #expect(origin.sh(["rev-parse", "feat/x"]) == pushedSince)

        // Delete on Remote of what you saw, then its Undo.
        work.sh(["fetch", "-q", "origin"])
        let tip = work.sh(["rev-parse", "origin/feat/x"])
        #expect(tip == pushedSince)
        #expect(work.status(BranchCommand.deleteOnRemote(remote: "origin", branch: "feat/x", sha: tip)) == 0)
        #expect(origin.status(["rev-parse", "--verify", "--quiet", "refs/heads/feat/x"]) != 0)
        #expect(work.status(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/feat/x"]) != 0) // the remote-tracking branch goes too
        #expect(work.status(BranchCommand.restoreOnRemote(remote: "origin", branch: "feat/x", sha: tip)) == 0)
        #expect(origin.sh(["rev-parse", "feat/x"]) == tip)

        // Checkout and Update: a branch behind its upstream is switched to and moved forward.
        work.sh(["fetch", "-q", "origin"])
        work.sh(["branch", "-q", "-f", "--track", "behind", "origin/main"])
        try origin.write("a.txt", "2\n")
        let newer = origin.commit("Two")
        work.sh(["fetch", "-q", "origin"])
        for step in BranchCommand.checkoutAndUpdate("behind") { #expect(work.status(step) == 0, "\(step)") }
        #expect(work.sh(["rev-parse", "--abbrev-ref", "HEAD"]) == "behind" && work.sh(["rev-parse", "HEAD"]) == newer)
    }
}

extension ScratchRepo {
    /// What git printed, standard output and error together, and how it ended.
    func output(_ args: [String]) -> (text: String, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-C", work] + args
        p.environment = ProcessInfo.processInfo.environment.merging(["LANGUAGE": "en", "LC_ALL": "en_US.UTF-8"]) { $1 }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nt-out-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try? FileHandle(forWritingTo: file)
        p.standardOutput = handle
        p.standardError = handle
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return ("", -1) }
        p.waitUntilExit()
        try? handle?.close()
        return ((try? String(contentsOf: file, encoding: .utf8)) ?? "", p.terminationStatus)
    }
}
