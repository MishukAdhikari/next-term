import Foundation
import Testing
@testable import NextTermCore

@Suite struct BranchCompareTests {
    @Test func commitsWithTheirMarks() {
        let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40), c = String(repeating: "c", count: 40)
        let fields: [[String]] = [
            ["<", a, "aaaaaaa", "Ann", "1700000000", "Only here"],
            ["=", b, "bbbbbbb", "Bo", "1700000100", "Picked: same change on the other side"],
            [">", c, "ccccccc", "Cy", "1700000200", "Tab\tin it, and a CR\r"],
            ["<", "abc", "abc", "Short", "1", "not a full id"],
            ["?", a, "a", "No mark", "1", "x"],
            ["<", a, "only four fields"],
        ]
        let records: [String] = fields.map { $0.joined(separator: "\0") }
        let lines = records.joined(separator: "\n") + "\n"
        let commits = BranchCompare.parseLog(Data(lines.utf8), side: .current)
        #expect(commits.map(\.sha) == [a, b, c])
        #expect(commits.allSatisfy { $0.side == .current })
        #expect(commits.map(\.isEquivalent) == [false, true, false])
        #expect(commits[0] == ComparedCommit(side: .current, sha: a, shortSHA: "aaaaaaa", authorName: "Ann",
                                             authorDate: Date(timeIntervalSince1970: 1_700_000_000), subject: "Only here"))
        // A subject keeps its tab, and a "\r" before the line's end doesn't join two commits.
        #expect(commits[2].subject == "Tab\tin it, and a CR\r")
        #expect(commits[2].authorName == "Cy")
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

    @Test func rawWithRenamesAndIDs() {
        let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40), zero = String(repeating: "0", count: 40)
        let records: [String] = [
            ":100644 100644 \(a) \(zero) M", "touched.txt",
            ":100644 100644 \(a) \(b) M", "staged.txt",
            ":100644 100755 \(a) \(zero) M", "now executable",
            ":100644 100644 \(a) \(a) R100", "old name.txt", "new name.txt",
            ":000000 100644 \(zero) \(zero) A", "added.txt",
            ":100644 000000 \(a) \(zero) D", "gone.txt",
            ":120000 120000 \(a) \(zero) M", "link",
            ":100644 100644 \(a) \(zero) M", "\"quoted\".txt",
            "",
        ]
        let changes = BranchCompare.parseRaw(Data(records.joined(separator: "\0").utf8))
        #expect(changes.map(\.file) == [
            ChangedFile(path: "touched.txt", status: .modified),
            ChangedFile(path: "staged.txt", status: .modified),
            ChangedFile(path: "now executable", status: .modified),
            ChangedFile(path: "new name.txt", oldPath: "old name.txt", status: .renamed),
            ChangedFile(path: "added.txt", status: .added),
            ChangedFile(path: "gone.txt", status: .deleted),
            ChangedFile(path: "link", status: .modified),
            ChangedFile(path: "\"quoted\".txt", status: .modified),
        ])
        #expect(changes[0] == BranchCompare.RawChange(file: changes[0].file, oldMode: "100644", newMode: "100644", oldID: a, newID: zero))
        // Only a plain file with the same mode and no id on disk may be unchanged: the rest are changes.
        // A name hash-object would read as quoted is a change too.
        let unsure: [Bool] = changes.map(\.mayBeUnchanged)
        #expect(unsure == [true, false, false, false, false, false, false, false])
        #expect(BranchCompare.parseRaw(Data()).isEmpty)
        // Cut short: what is whole is kept.
        let short = ":100644 100644 \(a) \(b) M\0a.txt\0:100644 100644 \(a) \(a) R100\0old.txt"
        #expect(BranchCompare.parseRaw(Data(short.utf8)).map(\.file) == [ChangedFile(path: "a.txt", status: .modified)])
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
        // From the merge base the comparison read, not `--merge-base`: that refuses a criss-cross.
        let mergeBase = String(repeating: "b", count: 40)
        #expect(BranchCompare.filesArguments(branch: "refs/heads/x", base: mergeBase) == [
            "diff-tree", "-r", "-z", "--name-status", "-M", "--end-of-options", mergeBase, "refs/heads/x", "--",
        ])
        let one = BranchCompare.fileDiffArguments(path: "new.txt", oldPath: "old.txt", branch: "refs/heads/x", base: mergeBase)
        #expect(one.prefix(5) == ["diff-tree", "-r", "-p", "--histogram", "-M"])
        let tail: [String] = Array(one.suffix(6))
        #expect(tail == ["--end-of-options", mergeBase, "refs/heads/x", "--", "old.txt", "new.txt"])
        #expect(["--src-prefix=a/", "-U3", "--no-ext-diff"].allSatisfy(one.contains))
        #expect(!one.contains("--merge-base"))
        #expect(BranchCompare.fileDiffArguments(path: "a.txt", branch: "refs/heads/x", base: mergeBase).suffix(2) == ["--", "a.txt"])
        #expect(BranchCompare.workingTreeArguments(branch: "refs/heads/x") == ["diff-index", "-z", "-M", "--end-of-options", "refs/heads/x", "--"])
        // Paths are names, not patterns; reads never take a lock.
        #expect(BranchCompare.base("/r") == ["-C", "/r", "--no-optional-locks", "--literal-pathspecs", "-c", "core.quotepath=off", "-c", "log.showSignature=false"])
        #expect(BranchCompare.displayName("refs/heads/feat/x") == "feat/x")
        #expect(BranchCompare.displayName("refs/remotes/origin/x") == "origin/x")
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
        #expect(c.current == "main" && c.mergeBase == base && !c.isSameCommit && !c.filesUnread)
        #expect(c.branchOnly.map(\.subject) == ["Rename", "The fix", "Feat only"])
        #expect(c.branchCount == 3)
        #expect(c.currentOnly.map(\.subject) == ["The fix", "Main only"])
        #expect(c.currentCount == 2)
        // The cherry-pick is marked on both sides, each on its own side.
        let pickedOnBranch: [String] = c.branchOnly.filter(\.isEquivalent).map(\.sha)
        let pickedHere: [String] = c.currentOnly.filter(\.isEquivalent).map(\.sha)
        #expect(pickedOnBranch == [fix] && pickedHere == [picked])
        #expect(c.branchOnly.allSatisfy { $0.side == .branch })
        #expect(c.currentOnly.allSatisfy { $0.side == .current })
        #expect(c.files == [
            ChangedFile(path: "a.txt", status: .modified),
            ChangedFile(path: "f.txt", status: .added),
            ChangedFile(path: "new.txt", oldPath: "old.txt", status: .renamed),
        ])
        // At a limit of one a side, each lists one and counts them all.
        let limited = try #require(BranchCompare.compare("refs/heads/feat", in: work, git: git, limit: 1))
        #expect(limited.branchOnly.count == 1 && limited.branchCount == 3)
        #expect(limited.currentOnly.count == 1 && limited.currentCount == 2)

        // One file's change on the branch: since the merge base, a rename as one.
        let renamed = try #require(BranchCompare.diff(of: "new.txt", oldPath: "old.txt", branch: "refs/heads/feat", base: base, in: work, git: git))
        #expect(renamed.oldPath == "old.txt" && renamed.newPath == "new.txt" && renamed.hunks.isEmpty)
        let changed = try #require(BranchCompare.diff(of: "a.txt", branch: "refs/heads/feat", base: base, in: work, git: git))
        let addedOnBranch: [String] = changed.hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text)
        #expect(addedOnBranch == ["fix"])

        // The files on disk against the branch: main's own file, the branch's file missing, and the rename backwards.
        try write("a.txt", "on disk\n")
        let disk = try #require(BranchCompare.workingTreeFiles(against: "refs/heads/feat", in: work, git: git))
        #expect(disk == [
            ChangedFile(path: "a.txt", status: .modified),
            ChangedFile(path: "f.txt", status: .deleted),
            ChangedFile(path: "m.txt", status: .added),
            ChangedFile(path: "old.txt", oldPath: "new.txt", status: .renamed),
        ])
        // A file the branch tracks, on disk here but untracked (ignored here, tracked there): not
        // compared, like any untracked file, rather than listed as deleted. A folder in its place is.
        try write("f.txt", "feat\n")
        let untracked = try #require(BranchCompare.workingTreeFiles(against: "refs/heads/feat", in: work, git: git))
        let untrackedPaths: [String] = untracked.map(\.path)
        #expect(untrackedPaths == ["a.txt", "m.txt", "old.txt"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("f.txt"))
        try write("f.txt/inside.txt", "a folder now\n")
        let folder = try #require(BranchCompare.workingTreeFiles(against: "refs/heads/feat", in: work, git: git))
        let folderPaths: [String] = folder.map(\.path)
        #expect(folderPaths == ["a.txt", "f.txt", "m.txt", "old.txt"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("f.txt"))
        // A file's diff: the branch's version first, the disk's second.
        let file = try #require(GitRunner.diff(of: "a.txt", in: work, git: git, base: .ref("refs/heads/feat")))
        let lines = file.hunks.flatMap(\.lines)
        let removed: [String] = lines.filter { $0.kind == .removed }.map(\.text)
        let added: [String] = lines.filter { $0.kind == .added }.map(\.text)
        #expect(removed == ["1", "2", "3", "fix"])
        #expect(added == ["on disk"])
        let back = try #require(GitRunner.diff(of: "old.txt", in: work, git: git, base: .ref("refs/heads/feat"), oldPath: "new.txt"))
        #expect(back.oldPath == "new.txt" && back.newPath == "old.txt")
        #expect(GitRunner.diffs(in: work, git: git, base: .ref("refs/heads/feat"))?.map(\.path).sorted() == ["a.txt", "f.txt", "m.txt", "old.txt"])
        #expect(try Data(contentsOf: index) == indexBefore, "reading rewrote the index")
        sh("checkout", "-q", "--", "a.txt")
        #expect(BranchCompare.workingTreeFiles(against: "refs/heads/main", in: work, git: git) == [])
        // Rewritten with the same text, later: git lists it until it reads it again, which it doesn't
        // here (that would write the index). It is left out, and a real change still shows.
        try write("a.txt", "1\n2\n3\nfix\n")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: root.appendingPathComponent("a.txt").path)
        let raw = try #require(GitRunner.run(git, BranchCompare.base(work) + BranchCompare.workingTreeArguments(branch: "refs/heads/main"), timeout: 10))
        #expect(BranchCompare.parseRaw(raw).map(\.file.path) == ["a.txt"], "the file git hasn't read again is listed by diff-index")
        #expect(BranchCompare.workingTreeFiles(against: "refs/heads/main", in: work, git: git) == [])
        try write("m.txt", "changed\n")
        #expect(BranchCompare.workingTreeFiles(against: "refs/heads/main", in: work, git: git) == [ChangedFile(path: "m.txt", status: .modified)])
        sh("checkout", "-q", "--", "m.txt")

        // The same commit: nothing either way, no files.
        sh("branch", "same")
        let same = try #require(BranchCompare.compare("refs/heads/same", in: work, git: git))
        #expect(same.isSameCommit && same.files.isEmpty)
        #expect(same.mergeBase == picked)
        // Nothing in common: the commits, and no merge base to compare files from.
        sh("switch", "-q", "--orphan", "lonely")
        sh("commit", "-q", "--allow-empty", "-m", "Lonely")
        sh("switch", "-qf", "main")
        let lonely = try #require(BranchCompare.compare("refs/heads/lonely", in: work, git: git))
        #expect(lonely.mergeBase == nil && lonely.files.isEmpty)
        #expect(lonely.branchOnly.map(\.subject) == ["Lonely"])
        #expect(lonely.currentCount == 3)
        // Detached, HEAD is the current side.
        sh("switch", "-q", "--detach", "feat")
        #expect(BranchCompare.compare("refs/heads/main", in: work, git: git)?.current == nil)
        #expect(BranchCompare.compare("refs/heads/no-such-branch", in: work, git: git) == nil)
    }

    /// Two branches that merged each other (a criss-cross) have two merge bases: `--merge-base` refuses
    /// them, and `git diff main...feat` picks one. The comparison reads from the one it picks too.
    @Test func branchesThatMergedEachOther() throws {
        let repo = try #require(ScratchRepo())
        defer { repo.remove() }
        try repo.write("a.txt", "1\n")
        repo.commit("Base")
        repo.sh(["switch", "-qc", "feat"])
        try repo.write("f.txt", "f\n")
        repo.commit("Feat 1")
        repo.sh(["switch", "-q", "main"])
        try repo.write("m.txt", "m\n")
        repo.commit("Main 1")
        repo.sh(["branch", "main1"])
        repo.sh(["merge", "-q", "--no-edit", "-m", "Main merges feat", "feat"])
        repo.sh(["switch", "-q", "feat"])
        repo.sh(["merge", "-q", "--no-edit", "-m", "Feat merges main", "main1"])
        try repo.write("f2.txt", "f2\n")
        repo.commit("Feat 2")
        repo.sh(["switch", "-q", "main"])
        try repo.write("m2.txt", "m2\n")
        repo.commit("Main 2")
        let bases = repo.sh(["merge-base", "--all", "HEAD", "feat"]).split(separator: "\n")
        #expect(bases.count == 2, "the history isn't a criss-cross")
        let picked = repo.sh(["merge-base", "HEAD", "feat"])

        let c = try #require(BranchCompare.compare("refs/heads/feat", in: repo.work, git: repo.git))
        #expect(c.branchOnly.map(\.subject) == ["Feat 2", "Feat merges main"])
        #expect(c.currentOnly.map(\.subject) == ["Main 2", "Main merges feat"])
        #expect(c.mergeBase == picked && !c.filesUnread)
        // What `git diff HEAD...feat` lists.
        let lines = repo.sh(["diff", "--name-status", "HEAD...feat"]).split(separator: "\n")
        let expected: [String] = lines.map { String($0.split(separator: "\t").last ?? "") }
        let files: [String] = c.files.map(\.path)
        #expect(!files.isEmpty)
        #expect(files == expected)
        let diff = try #require(BranchCompare.diff(of: "f2.txt", branch: "refs/heads/feat", base: picked, in: repo.work, git: repo.git))
        let added: [String] = diff.hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text)
        #expect(added == ["f2"])
    }

    /// A file's diff against a branch is that file's: "a[1].txt" is a name, not a pattern that also
    /// matches "a1.txt" (Next.js and SvelteKit routes are named like it). The same file as on the branch
    /// is an empty diff; a branch git can't read (deleted) is nil.
    @Test func aFileDiffAgainstABranchIsThatFiles() throws {
        let repo = try #require(ScratchRepo())
        defer { repo.remove() }
        try repo.write("a1.txt", "one\n")
        try repo.write("a[1].txt", "bracket\n")
        try repo.write("same.txt", "same\n")
        repo.commit("Base")
        repo.sh(["branch", "feat"])
        try repo.write("a1.txt", "one changed\n")
        try repo.write("a[1].txt", "bracket changed\n")
        let feat = GitRunner.DiffBase.ref("refs/heads/feat")
        for base in [feat, .head] {
            let bracket = try #require(GitRunner.diff(of: "a[1].txt", in: repo.work, git: repo.git, base: base))
            let added: [String] = bracket.hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text)
            #expect(bracket.newPath == "a[1].txt", "\(base)")
            #expect(added == ["bracket changed"], "\(base)")
            let all: [String]? = GitRunner.diffs(in: repo.work, git: repo.git, base: base, paths: ["a[1].txt"])?.map(\.path)
            #expect(all == ["a[1].txt"], "\(base)")
        }
        let same = try #require(GitRunner.diff(of: "same.txt", in: repo.work, git: repo.git, base: feat))
        #expect(same.hunks.isEmpty)
        #expect(same.oldPath == nil && same.newPath == nil)
        repo.sh(["branch", "-D", "feat"])
        #expect(GitRunner.diff(of: "a1.txt", in: repo.work, git: repo.git, base: feat) == nil)
        #expect(GitRunner.diff(of: "same.txt", in: repo.work, git: repo.git, base: feat) == nil)
    }

    /// hash-object reads a path that starts with a double quote as C-quoted: "\"q\".txt" would hash the
    /// file q. A changed file named like that is listed, even with a q beside it holding its old text.
    @Test func aChangedFileNamedWithAQuoteIsListed() throws {
        let repo = try #require(ScratchRepo())
        defer { repo.remove() }
        try repo.write("\"q\".txt", "one\n")
        repo.commit("Base")
        try repo.write("\"q\".txt", "two\n")
        try repo.write("q", "one\n")
        let files = try #require(BranchCompare.workingTreeFiles(against: "refs/heads/main", in: repo.work, git: repo.git))
        #expect(files == [ChangedFile(path: "\"q\".txt", status: .modified)])
    }
}
