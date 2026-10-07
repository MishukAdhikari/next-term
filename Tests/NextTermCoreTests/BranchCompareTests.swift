import Foundation
import Testing
@testable import NextTermCore

@Suite struct BranchCompareTests {
    @Test func commitsWithTheirMarks() {
        let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40), c = String(repeating: "c", count: 40)
        let lines = [
            ["<", a, "aaaaaaa", "Ann", "1700000000", "Only here"],
            ["=", b, "bbbbbbb", "Bo", "1700000100", "Picked: same change on the other side"],
            [">", c, "ccccccc", "Cy", "1700000200", "Tab\tin it, and a CR\r"],
            ["<", "abc", "abc", "Short", "1", "not a full id"],
            ["?", a, "a", "No mark", "1", "x"],
            ["<", a, "only four fields"],
        ].map { $0.joined(separator: "\0") }.joined(separator: "\n") + "\n"
        let commits = BranchCompare.parseLog(Data(lines.utf8), side: .current)
        #expect(commits.map(\.sha) == [a, b, c])
        #expect(commits.allSatisfy { $0.side == .current })
        #expect(commits.map(\.isEquivalent) == [false, true, false])
        #expect(commits[0] == ComparedCommit(side: .current, sha: a, shortSHA: "aaaaaaa", authorName: "Ann",
                                             authorDate: Date(timeIntervalSince1970: 1_700_000_000), subject: "Only here"))
        // A subject keeps its tab, and a "\r" before the line's end doesn't join two commits.
        #expect(commits[2].subject == "Tab\tin it, and a CR\r" && commits[2].authorName == "Cy")
        #expect(BranchCompare.parseLog(Data(), side: .branch).isEmpty)
    }

    @Test func nameStatusWithRenames() {
        let records = ["M", "a.txt", "A", "dir/new file.txt", "R100", "old.txt", "moved/new.txt", "C075", "x.txt", "copy.txt", "D", "gone.txt", "T", "link", ""]
        let files = BranchCompare.parseNameStatus(Data(records.joined(separator: "\0").utf8))
        #expect(files == [
            ChangedFile(path: "a.txt", status: .modified),
            ChangedFile(path: "dir/new file.txt", status: .added),
            ChangedFile(path: "moved/new.txt", oldPath: "old.txt", status: .renamed),
            ChangedFile(path: "copy.txt", oldPath: "x.txt", status: .copied),
            ChangedFile(path: "gone.txt", status: .deleted),
            ChangedFile(path: "link", status: .typeChanged),
        ])
        #expect(BranchCompare.parseNameStatus(Data()).isEmpty)
        // Cut short: what is whole is kept.
        #expect(BranchCompare.parseNameStatus(Data("M\0a.txt\0R090\0old.txt".utf8)) == [ChangedFile(path: "a.txt", status: .modified)])
    }

    @Test func counts() {
        #expect(BranchCompare.parseCounts(Data("2\t1234\n".utf8)).map { [$0.current, $0.branch] } == [2, 1234])
        #expect(BranchCompare.parseCounts(Data("x\n".utf8)) == nil)
    }

    @Test func commandLines() {
        let format = "--format=%m%x00%H%x00%h%x00%an%x00%at%x00%s"
        #expect(BranchCompare.logArguments(branch: "refs/heads/feat/x", side: .branch) == [
            "log", "--left-right", "--right-only", "--cherry-mark", "--max-count=500", "--no-color", "--encoding=UTF-8", format,
            "--end-of-options", "HEAD...refs/heads/feat/x", "--",
        ])
        #expect(BranchCompare.logArguments(branch: "refs/remotes/origin/x", side: .current, limit: 20).contains("--left-only"))
        #expect(BranchCompare.logArguments(branch: "refs/remotes/origin/x", side: .current, limit: 20).contains("--max-count=20"))
        #expect(BranchCompare.countArguments(branch: "refs/heads/x") == ["rev-list", "--left-right", "--count", "--end-of-options", "HEAD...refs/heads/x", "--"])
        #expect(BranchCompare.filesArguments(branch: "refs/heads/x") == [
            "diff-tree", "-r", "-z", "--name-status", "-M", "--merge-base", "--end-of-options", "HEAD", "refs/heads/x", "--",
        ])
        let one = BranchCompare.fileDiffArguments(path: "new.txt", oldPath: "old.txt", branch: "refs/heads/x")
        #expect(one.prefix(6) == ["diff-tree", "-r", "-p", "--histogram", "-M", "--merge-base"])
        #expect(Array(one.suffix(6)) == ["--end-of-options", "HEAD", "refs/heads/x", "--", "old.txt", "new.txt"])
        #expect(one.contains("--src-prefix=a/") && one.contains("-U3") && one.contains("--no-ext-diff"))
        #expect(BranchCompare.fileDiffArguments(path: "a.txt", branch: "refs/heads/x").suffix(2) == ["--", "a.txt"])
        #expect(BranchCompare.workingTreeArguments(branch: "refs/heads/x") == ["diff-index", "-z", "--name-status", "-M", "--end-of-options", "refs/heads/x", "--"])
        // Paths are names, not patterns; reads never take a lock.
        #expect(BranchCompare.base("/r") == ["-C", "/r", "--no-optional-locks", "--literal-pathspecs", "-c", "core.quotepath=off", "-c", "log.showSignature=false"])
        #expect(BranchCompare.displayName("refs/heads/feat/x") == "feat/x" && BranchCompare.displayName("refs/remotes/origin/x") == "origin/x")
        #expect(BranchRef(name: "origin/x", isRemote: true, sha: "").fullName == "refs/remotes/origin/x")
        #expect(BranchRef(name: "feat/x", isRemote: false, sha: "").fullName == "refs/heads/feat/x")
    }

    /// Two branches that parted: commits on each side, one change cherry-picked across, a rename, then
    /// the files on disk against the branch, and a branch with nothing in common.
    @Test func aRealRepository() throws {
        guard let git = GitRunner.locateGit() else { return }
        let root = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path)).appendingPathComponent("nt-compare-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let work = root.path
        @discardableResult func sh(_ args: String...) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", work, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try? p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        sh("init", "-q")
        try write("a.txt", "1\n2\n3\n")
        try write("old.txt", "x\ny\nz\n")
        sh("add", "-A")
        sh("commit", "-qm", "base")
        let base = sh("rev-parse", "HEAD")
        sh("switch", "-qc", "feat")
        try write("f.txt", "feat\n")
        sh("add", "f.txt")
        sh("commit", "-qm", "Feat only")
        try write("a.txt", "1\n2\n3\nfix\n")
        sh("commit", "-qam", "The fix")
        let fix = sh("rev-parse", "HEAD")
        sh("mv", "old.txt", "new.txt")
        sh("commit", "-qm", "Rename")
        sh("switch", "-q", "main")
        try write("m.txt", "main\n")
        sh("add", "m.txt")
        sh("commit", "-qm", "Main only")
        sh("cherry-pick", fix)
        let picked = sh("rev-parse", "HEAD")

        let index = root.appendingPathComponent(".git/index")
        let indexBefore = try Data(contentsOf: index)
        let c = try #require(BranchCompare.compare("refs/heads/feat", in: work, git: git))
        #expect(c.current == "main" && c.mergeBase == base && !c.isSameCommit)
        #expect(c.branchOnly.map(\.subject) == ["Rename", "The fix", "Feat only"] && c.branchCount == 3)
        #expect(c.currentOnly.map(\.subject) == ["The fix", "Main only"] && c.currentCount == 2)
        // The cherry-pick is marked on both sides, each on its own side.
        #expect(c.branchOnly.filter(\.isEquivalent).map(\.sha) == [fix] && c.currentOnly.filter(\.isEquivalent).map(\.sha) == [picked])
        #expect(c.branchOnly.allSatisfy { $0.side == .branch } && c.currentOnly.allSatisfy { $0.side == .current })
        #expect(c.files == [
            ChangedFile(path: "a.txt", status: .modified),
            ChangedFile(path: "f.txt", status: .added),
            ChangedFile(path: "new.txt", oldPath: "old.txt", status: .renamed),
        ])
        // At a limit of one a side, each lists one and counts them all.
        let limited = try #require(BranchCompare.compare("refs/heads/feat", in: work, git: git, limit: 1))
        #expect(limited.branchOnly.count == 1 && limited.branchCount == 3 && limited.currentOnly.count == 1 && limited.currentCount == 2)

        // One file's change on the branch: since the merge base, a rename as one.
        let renamed = try #require(BranchCompare.diff(of: "new.txt", oldPath: "old.txt", branch: "refs/heads/feat", in: work, git: git))
        #expect(renamed.oldPath == "old.txt" && renamed.newPath == "new.txt" && renamed.hunks.isEmpty)
        let changed = try #require(BranchCompare.diff(of: "a.txt", branch: "refs/heads/feat", in: work, git: git))
        #expect(changed.hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text) == ["fix"])

        // The files on disk against the branch: main's own file, the branch's file missing, and the rename backwards.
        try write("a.txt", "on disk\n")
        let disk = try #require(BranchCompare.workingTreeFiles(against: "refs/heads/feat", in: work, git: git))
        #expect(disk == [
            ChangedFile(path: "a.txt", status: .modified),
            ChangedFile(path: "f.txt", status: .deleted),
            ChangedFile(path: "m.txt", status: .added),
            ChangedFile(path: "old.txt", oldPath: "new.txt", status: .renamed),
        ])
        // A file's diff: the branch's version first, the disk's second.
        let file = try #require(GitRunner.diff(of: "a.txt", in: work, git: git, base: .ref("refs/heads/feat")))
        let lines = file.hunks.flatMap(\.lines)
        #expect(lines.filter { $0.kind == .removed }.map(\.text) == ["1", "2", "3", "fix"] && lines.filter { $0.kind == .added }.map(\.text) == ["on disk"])
        let back = try #require(GitRunner.diff(of: "old.txt", in: work, git: git, base: .ref("refs/heads/feat"), oldPath: "new.txt"))
        #expect(back.oldPath == "new.txt" && back.newPath == "old.txt")
        #expect(GitRunner.diffs(in: work, git: git, base: .ref("refs/heads/feat"))?.map(\.path).sorted() == ["a.txt", "f.txt", "m.txt", "old.txt"])
        #expect(try Data(contentsOf: index) == indexBefore, "reading rewrote the index")
        sh("checkout", "-q", "--", "a.txt")
        #expect(BranchCompare.workingTreeFiles(against: "refs/heads/main", in: work, git: git) == [])

        // The same commit: nothing either way, no files.
        sh("branch", "same")
        let same = try #require(BranchCompare.compare("refs/heads/same", in: work, git: git))
        #expect(same.isSameCommit && same.files.isEmpty && same.mergeBase == picked)
        // Nothing in common: the commits, and no merge base to compare files from.
        sh("switch", "-q", "--orphan", "lonely")
        sh("commit", "-q", "--allow-empty", "-m", "Lonely")
        sh("switch", "-qf", "main")
        let lonely = try #require(BranchCompare.compare("refs/heads/lonely", in: work, git: git))
        #expect(lonely.mergeBase == nil && lonely.files.isEmpty && lonely.branchOnly.map(\.subject) == ["Lonely"] && lonely.currentCount == 3)
        // Detached, HEAD is the current side.
        sh("switch", "-q", "--detach", "feat")
        #expect(BranchCompare.compare("refs/heads/main", in: work, git: git)?.current == nil)
        #expect(BranchCompare.compare("refs/heads/no-such-branch", in: work, git: git) == nil)
    }
}
