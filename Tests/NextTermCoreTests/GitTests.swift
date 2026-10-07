import Foundation
import Testing
@testable import NextTermCore

@Suite struct GitParsingTests {
    func z(_ records: [String]) -> Data { Data(records.joined(separator: "\0").utf8 + [0]) }

    @Test func statusAndNumstat() {
        let status = z([
            "# branch.oid 1234567890abcdef1234567890abcdef12345678",
            "# branch.head feature/login",
            "# branch.upstream origin/feature/login",
            "# branch.ab +2 -1",
            "1 .M N... 100644 100644 100644 aaa bbb app/Http/Kernel.php",
            "1 A. N... 000000 100644 100644 000 ccc app/New File.php",
            "1 .D N... 100644 100644 000000 ddd ddd docs/old.md",
            "2 R. N... 100644 100644 100644 eee eee R100 src/renamed.swift", "src/original.swift",
            "u UU N... 100644 100644 100644 100644 f1 f2 f3 config/app.php",
            "? notes.txt",
            "? scratch/",
            "! node_modules/",
            "! .env",
        ])
        let numstat = z([
            "10\t2\tapp/Http/Kernel.php",
            "30\t0\tapp/New File.php",
            "0\t7\tdocs/old.md",
            "1\t1\t", "src/original.swift", "src/renamed.swift",
            "-\t-\tpublic/logo.png",
        ])
        let s = GitSnapshot.parse(root: "/r", status: status, numstat: numstat)
        #expect(s.branch == "feature/login" && s.upstream == "origin/feature/login")
        #expect(s.ahead == 2 && s.behind == 1 && s.head == "12345678")
        #expect(s.files["app/Http/Kernel.php"] == .modified)
        #expect(s.files["app/New File.php"] == .added)
        #expect(s.files["docs/old.md"] == .deleted)
        #expect(s.files["src/renamed.swift"] == .renamed)
        #expect(s.files["src/original.swift"] == nil)
        #expect(s.files["config/app.php"] == .conflicted)
        #expect(s.files["notes.txt"] == .untracked)
        #expect(s.wholeFolders["scratch"] == .untracked && s.wholeFolders["node_modules"] == .ignored)
        #expect(s.fileStats["src/renamed.swift"] == LineStats(added: 1, removed: 1, files: 1))
        #expect(s.fileStats["public/logo.png"] == LineStats(added: 0, removed: 0, files: 1))

        // Folders take their strongest change and the sum of their lines.
        #expect(s.change(at: "app", isDirectory: true) == .modified)
        #expect(s.change(at: "app/Http", isDirectory: true) == .modified)
        #expect(s.stats(at: "app", isDirectory: true) == LineStats(added: 40, removed: 2, files: 2))
        #expect(s.change(at: "config", isDirectory: true) == .conflicted)
        #expect(s.change(at: "docs", isDirectory: true) == .deleted)
        #expect(s.change(at: "", isDirectory: true) == .conflicted)
        #expect(s.totals.added == 41 && s.totals.removed == 10)
        // Inside whole untracked/ignored folders.
        #expect(s.change(at: "scratch/a/b.txt", isDirectory: false) == .untracked)
        #expect(s.change(at: "node_modules/x", isDirectory: true) == .ignored)
        // Ignored entries never colour their parents.
        #expect(s.change(at: "lib", isDirectory: true) == nil)
        #expect(s.count(of: .untracked) == 2)
    }

    @Test func detachedAndUnborn() {
        let detached = GitSnapshot.parse(root: "/r", status: z(["# branch.oid abcdef0123456789", "# branch.head (detached)"]), numstat: Data())
        #expect(detached.branch == nil && detached.head == "abcdef01")
        let unborn = GitSnapshot.parse(root: "/r", status: z(["# branch.oid (initial)", "# branch.head main"]), numstat: Data())
        #expect(unborn.branch == "main" && unborn.head == nil)
    }
}

@Suite struct GitRunnerTests {
    /// A real repository and a linked worktree of it: when a fetch last worked, in either.
    @Test func lastSuccessfulFetchIsTheNewestFetchHeadOfAnyWorkTree() throws {
        guard let git = GitRunner.locateGit() else { return } // no git on this machine
        let base = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("nt-fetch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let main = base.appendingPathComponent("main").path
        let linked = base.appendingPathComponent("linked").path
        func sh(_ args: [String], in dir: String) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", dir, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0, "git \(args.joined(separator: " "))")
        }
        /// FETCH_HEAD as a fetch leaves it: a line for each ref when it worked, empty when it failed.
        func fetchHead(_ path: String, worked: Bool, at date: Date) throws {
            let line = "0123456789abcdef0123456789abcdef01234567\t\tbranch 'main' of /r/remote.git\n"
            try Data(worked ? line.utf8 : "".utf8).write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        }
        try FileManager.default.createDirectory(atPath: main, withIntermediateDirectories: true)
        try sh(["init"], in: main)
        try sh(["commit", "--allow-empty", "-m", "one"], in: main)
        #expect(GitRunner.commonGitDir(root: main) == main + "/.git")
        #expect(GitRunner.lastSuccessfulFetch(root: main) == nil) // never fetched
        let fetched = Date(timeIntervalSince1970: 1_790_000_000)
        try fetchHead(main + "/.git/FETCH_HEAD", worked: true, at: fetched)
        #expect(GitRunner.lastSuccessfulFetch(root: main) == fetched)
        // A fetch that failed empties FETCH_HEAD: it is no fetch.
        try fetchHead(main + "/.git/FETCH_HEAD", worked: false, at: fetched.addingTimeInterval(60))
        #expect(GitRunner.lastSuccessfulFetch(root: main) == nil)
        try fetchHead(main + "/.git/FETCH_HEAD", worked: true, at: fetched)
        // A linked worktree's .git is a file, and its FETCH_HEAD its own, in worktrees/<name>. The refs are
        // shared, so a fetch in either counts for both.
        try sh(["worktree", "add", "-q", "-b", "side", linked], in: main)
        #expect(GitRunner.commonGitDir(root: linked).map(canonicalPath) == canonicalPath(main + "/.git"))
        #expect(GitRunner.lastSuccessfulFetch(root: linked) == fetched)
        let later = fetched.addingTimeInterval(3600)
        try fetchHead(main + "/.git/worktrees/linked/FETCH_HEAD", worked: true, at: later)
        #expect(GitRunner.lastSuccessfulFetch(root: main) == later && GitRunner.lastSuccessfulFetch(root: linked) == later)
        #expect(GitRunner.commonGitDir(root: base.path) == nil) // not a work tree
    }

    /// A real repository: a clone with an upstream, local commits ahead, and every kind of change.
    @Test func snapshotOfARealRepository() throws {
        guard let git = GitRunner.locateGit() else { return } // no git on this machine
        let base = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("nt-git-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let origin = base.appendingPathComponent("origin.git").path
        let work = base.appendingPathComponent("work").path
        func sh(_ args: [String], in dir: String) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", dir, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0, "git \(args.joined(separator: " "))")
        }
        func write(_ path: String, _ text: String) throws {
            let url = URL(fileURLWithPath: work).appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(atPath: base.path, withIntermediateDirectories: true)
        try sh(["init", "--bare", origin], in: base.path)
        try sh(["clone", origin, work], in: base.path)
        try write("app/main.php", "<?php\necho 1;\necho 2;\n")
        try write("old.txt", "x\n")
        try write(".gitignore", "vendor/\n")
        try write("gone.txt", "1\n2\n")
        try write("lib/a.txt", "a\n")
        try write("lib/sub/b.txt", "b\n")
        try sh(["add", "-A"], in: work)
        try sh(["commit", "-m", "one"], in: work)
        try sh(["push", "-u", "origin", "main"], in: work)
        try write("app/main.php", "<?php\necho 1;\necho 3;\necho 4;\n") // +2 -1
        try sh(["commit", "-am", "two"], in: work)                       // ahead 1
        try write("app/main.php", "<?php\necho 1;\necho 3;\necho 4;\necho 5;\n") // +1 more, unstaged
        try write("app/new.php", "a\nb\nc\n")
        try sh(["add", "app/new.php"], in: work)                          // staged new file
        try sh(["mv", "old.txt", "renamed.txt"], in: work)
        try write("notes.md", "1\n2\n")                                   // untracked
        try write("vendor/lib.php", "x\n")                                 // ignored
        try sh(["rm", "-q", "gone.txt"], in: work)                         // deleted, staged
        try FileManager.default.removeItem(atPath: work + "/lib")          // a folder deleted on disk only

        let s = try #require(GitRunner.snapshot(for: work + "/app", git: git))
        #expect(s.root == work)
        #expect(s.branch == "main" && s.upstream == "origin/main")
        #expect(s.ahead == 1 && s.behind == 0)
        #expect(s.files["app/main.php"] == .modified)
        #expect(s.fileStats["app/main.php"] == LineStats(added: 1, removed: 0, files: 1)) // vs HEAD ("two")
        #expect(s.files["app/new.php"] == .added)
        #expect(s.fileStats["app/new.php"]?.added == 3)
        #expect(s.files["renamed.txt"] == .renamed)
        #expect(s.files["notes.md"] == .untracked && s.fileStats["notes.md"]?.added == 2)
        #expect(s.wholeFolders["vendor"] == .ignored)
        #expect(s.change(at: "app", isDirectory: true) == .modified)
        #expect(s.stats(at: "app", isDirectory: true)?.files == 2)
        #expect(GitRunner.snapshot(for: base.path, git: git) == nil) // not a repository

        // Deleted files: listed where they were, so a folder's −N has rows that explain it.
        #expect(s.files["gone.txt"] == .deleted && s.fileStats["gone.txt"]?.removed == 2)
        let onDisk = Set(try FileManager.default.contentsOfDirectory(atPath: work))
        #expect(s.deletedEntries(in: "", existing: onDisk).map { "\($0.name)\($0.isDirectory ? "/" : "")" } == ["lib/", "gone.txt"])
        #expect(s.deletedEntries(in: "lib", existing: []).map { "\($0.name)\($0.isDirectory ? "/" : "")" } == ["sub/", "a.txt"])
        #expect(s.deletedEntries(in: "app", existing: ["main.php", "new.php"]).isEmpty)
        #expect(s.deletedPaths == ["gone.txt", "lib/a.txt", "lib/sub/b.txt"])
        // A staged deletion is in HEAD only: still tracked, and its diff is the removed lines.
        #expect(GitRunner.isTracked("gone.txt", in: work, git: git) && !GitRunner.isTracked("notes.md", in: work, git: git))
        let removed = try #require(GitRunner.diff(of: "gone.txt", in: work, git: git, base: .head))
        #expect(removed.hunks.flatMap(\.lines).filter { $0.kind == .removed }.count == 2)
    }
}
