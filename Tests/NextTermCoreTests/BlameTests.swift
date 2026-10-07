import Foundation
import Testing
@testable import NextTermCore

@Suite struct BlameTests {
    let ann = "b96133ddf7931ce0501e51d6e9e24710a227ddf1"
    let bob = "68c90362f1d5ba9c1aceb880c11956cf17b2420b"

    /// A commit's details come once, with its first line; later lines have only the header.
    @Test func parsesPorcelain() throws {
        let zero = String(repeating: "0", count: 40)
        let text = """
        \(ann) 1 1 1
        author Ann Lee
        author-mail <ann@example.com>
        author-time 1700000000
        author-tz +0000
        summary First
        boundary
        filename old.txt
        \ta
        \(bob) 2 2 1
        author Bob
        author-mail <bob@example.com>
        author-time 1700086400
        summary Second
        previous \(ann) old.txt
        filename f.txt
        \tB
        \(zero) 3 3 1
        author Not Committed Yet
        author-mail <not.committed.yet>
        author-time 1700090000
        summary Version of f.txt from f.txt
        filename f.txt
        \tC
        \(bob) 4 4 1
        \td

        """
        let blame = try #require(Blame.parse(Data(text.utf8)))
        #expect(blame.lines.map(\.sha) == [ann, bob, nil, bob])
        #expect(blame.lines.map(\.originalLine) == [1, 2, 0, 4])
        #expect(blame.commits.count == 2) // never the not-committed one
        let first = try #require(blame.commits[ann])
        #expect(first.author == "Ann Lee" && first.shortAuthor == "Ann" && first.authorMail == "ann@example.com")
        #expect(first.summary == "First" && first.path == "old.txt" && first.shortSHA == "b96133d")
        #expect(first.authorTime == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(first.isBoundary && !blame.isShallowBoundary(first)) // the first commit, in a full clone
        #expect(blame.commit(blame.lines[3])?.summary == "Second")
        #expect(Blame.parse(Data("\(ann) 1 1 1\nauthor A\n\tx\0y\n".utf8)) == nil) // binary
        // SHA-256 names, and its 64 zeros for a line not committed.
        let long = String(repeating: "ab", count: 32), zeros = String(repeating: "0", count: 64)
        let sha256 = try #require(Blame.parse(Data("\(long) 1 1 1\nauthor Ann\n\ta\n\(zeros) 2 2 1\nauthor Not Committed Yet\n\tb\n".utf8)))
        #expect(sha256.lines.map(\.sha) == [long, nil] && sha256.commits.keys.sorted() == [long])
    }

    @Test func compactAges() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func age(_ seconds: Double) -> String { Blame.compactAge(of: now.addingTimeInterval(-seconds), now: now) }
        #expect(age(5) == "now")
        #expect(age(5 * 60) == "5m")
        #expect(age(3 * 3600) == "3h")
        #expect(age(2 * 86400) == "2d")
        #expect(age(15 * 86400) == "2w")
        #expect(age(100 * 86400) == "3mo")
        #expect(age(800 * 86400) == "2y")
        #expect(age(-60) == "now") // a clock ahead of the commit's
    }

    /// A real repository: two authors, a rename, and a change on disk not committed yet.
    @Test func blameOfARealRepository() throws {
        guard let git = GitRunner.locateGit() else { return }
        let repo = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-blame-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func sh(_ args: String...) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", repo, "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0, "git \(args.joined(separator: " "))")
        }
        func write(_ name: String, _ text: String) throws { try text.write(toFile: repo + "/" + name, atomically: true, encoding: .utf8) }

        try sh("init", "-q")
        #expect(GitRunner.blame(of: repo + "/a.txt", git: git) == .notCommitted(root: repo)) // no commit yet
        try write("a.txt", "one\ntwo\nthree\n")
        try sh("add", "a.txt")
        try sh("-c", "user.name=Ann Lee", "-c", "user.email=ann@example.com", "commit", "-qm", "First")
        try write("a.txt", "one\nTWO\nthree\nfour\n")
        try sh("-c", "user.name=Bob", "-c", "user.email=bob@example.com", "commit", "-qam", "Second")
        try sh("mv", "a.txt", "b.txt")
        try sh("-c", "user.name=Cy", "-c", "user.email=cy@example.com", "commit", "-qm", "Rename")
        try write("b.txt", "one\nTWO\nTHREE\nfour\n") // on disk only

        guard case .annotated(let blame) = GitRunner.blame(of: repo + "/b.txt", git: git) else { return #expect(Bool(false), "b.txt has a blame") }
        #expect(blame.root == repo && blame.head.count == 40)
        let authors = blame.lines.map { blame.commit($0)?.author ?? "-" }
        #expect(authors == ["Ann Lee", "Bob", "Ann Lee", "Bob"]) // as committed: the rename moved no line
        #expect(blame.commit(blame.lines[0])?.path == "a.txt") // its name back then
        #expect(blame.commit(blame.lines[1])?.summary == "Second")
        #expect(blame.lines[2].originalLine == 3)

        guard case .annotated(let disk) = GitRunner.blame(of: repo + "/b.txt", git: git, workingTree: true) else { return #expect(Bool(false)) }
        #expect(disk.lines.map(\.isCommitted) == [true, true, false, true])

        // Cached by file and HEAD: blamed again only after a commit.
        let cache = BlameCache(limit: 2)
        let first = GitRunner.blame(of: repo + "/b.txt", git: git, cache: cache)
        #expect(first == .annotated(blame) && cache.count == 1)
        #expect(GitRunner.blame(of: repo + "/b.txt", git: git, cache: cache) == first && cache.count == 1)
        try sh("-c", "user.name=Dee", "-c", "user.email=d@x", "commit", "-qam", "Third")
        guard case .annotated(let after) = GitRunner.blame(of: repo + "/b.txt", git: git, cache: cache) else { return #expect(Bool(false)) }
        #expect(after.commit(after.lines[2])?.author == "Dee" && cache.count == 2)

        try write("new.txt", "x\n")
        #expect(GitRunner.blame(of: repo + "/new.txt", git: git) == .notCommitted(root: repo)) // untracked
        #expect(GitRunner.blame(of: repo + "/b.txt", git: git, maxSize: 4) == .tooLarge)
        try Data([0x61, 0x00, 0x62, 0x0A]).write(to: URL(fileURLWithPath: repo + "/bin.dat"))
        try sh("add", "bin.dat")
        try sh("-c", "user.name=Ann", "-c", "user.email=a@x", "commit", "-qm", "Binary")
        #expect(GitRunner.blame(of: repo + "/bin.dat", git: git) == .binary)
        #expect(GitRunner.blame(of: "/tmp/nt-no-repo-\(UUID().uuidString)/x.txt", git: git) == .notInRepository)

        // A blame that takes too long is remembered for this HEAD, not run again every few seconds.
        let slow = BlameCache()
        #expect(GitRunner.blame(of: repo + "/b.txt", git: git, timeout: 0, cache: slow) == .timedOut)
        #expect(GitRunner.blame(of: repo + "/b.txt", git: git, cache: slow) == .timedOut && slow.count == 1)
    }

    func committed(_ shas: [String?]) -> Blame {
        var blame = Blame()
        for (i, sha) in shas.enumerated() {
            blame.lines.append(Blame.Line(sha: sha, originalLine: i + 1))
            if let sha, blame.commits[sha] == nil {
                blame.commits[sha] = Blame.Commit(sha: sha, author: sha, authorMail: "", authorTime: Date(timeIntervalSince1970: Double(i) * 1000),
                                                  summary: "", path: "f")
            }
        }
        return blame
    }

    /// The committed blame carried over to the text being edited by the diff between them.
    @Test func alignsToEditedText() throws {
        let git = try #require(GitRunner.locateGit())
        let blame = committed(["a", "a", "b", "b", "c"])
        let old = "1\n2\n3\n4\n5\n"
        func aligned(_ new: String) throws -> [String?] {
            let diff = try #require(GitRunner.diff(old: old, new: new, git: git, context: 0))
            return EditedBlame(blame, diff: diff, lineCount: EditedBlame.lineCount(of: new)).lines.map(\.sha)
        }
        let counts: [Int] = ["", "a", "a\n", "a\n\nb"].map { EditedBlame.lineCount(of: $0) }
        #expect(counts == [0, 1, 1, 3])
        #expect(EditedBlame(blame, diff: nil, lineCount: 5).lines.map(\.sha) == ["a", "a", "b", "b", "c"])
        #expect(try aligned("0\n1\n2\n3\n4\n5\n") == [nil, "a", "a", "b", "b", "c"])    // added at the top
        #expect(try aligned("1\n2\nX\n4\n5\n") == ["a", "a", nil, "b", "c"])            // changed
        #expect(try aligned("1\n4\n5\n") == ["a", "b", "c"])                             // deleted
        #expect(try aligned("1\n2\n3\n4\n5\n6\n7\n") == ["a", "a", "b", "b", "c", nil, nil]) // added at the end
        #expect(try aligned("1\n2\nY\nZ\nW\n4\n") == ["a", "a", nil, nil, nil, "b"])    // grown, last one gone
    }

    /// Between diffs, edits shift the lines after them; the lines edited are not committed.
    @Test func shiftsWithEdits() {
        var edited = EditedBlame(committed(["a", "a", "b", "c"]), diff: nil, lineCount: 4)
        edited.edit(lines: 1...1, nowEndingAt: 2, lineCount: 5) // Return in line 2
        #expect(edited.lines.map(\.sha) == ["a", nil, nil, "b", "c"])
        edited.edit(lines: 2...3, nowEndingAt: 2, lineCount: 4) // joined two lines
        #expect(edited.lines.map(\.sha) == ["a", nil, nil, "c"])
        edited.edit(lines: 4...4, nowEndingAt: 4, lineCount: 4) // typed on the empty last line: git has no line there
        #expect(edited.lines.count == 4)
        #expect(EditedBlame.notCommitted(lineCount: 3, root: "/r").lines == Array(repeating: .notCommitted, count: 3))
    }

    /// Typing in a 20,000-line file: each edit only moves an array, so a thousand stay well under a frame each.
    @Test func editsOnALongFileStayCheap() {
        let count = 20_000
        let blame = committed((0..<count).map { "c\($0 / 50)" })
        var edited = EditedBlame(blame, diff: nil, lineCount: count)
        let start = Date()
        for i in 0..<1000 {
            let line = (i * 37) % (count - 2)
            edited.edit(lines: line...line, nowEndingAt: line + i % 2, lineCount: count + (i + 1) / 2)
        }
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(edited.lines.count == count + 500)
    }

    @Test func blocksAndRecency() throws {
        let edited = EditedBlame(committed(["a", "a", nil, "b", "b", "b"]), diff: nil, lineCount: 6)
        #expect((0..<6).filter(edited.isBlockStart) == [0, 2, 3])
        #expect(edited.block(containing: 4) == 3...5 && edited.block(containing: 2) == 2...2)
        #expect(edited.block(containing: 9) == nil && edited.commit(at: 2) == nil && edited.commit(at: 3)?.sha == "b")
        let a = try #require(edited.blame.commits["a"]), b = try #require(edited.blame.commits["b"])
        #expect(edited.recency(of: a) == 0 && edited.recency(of: b) == 1)
    }

    /// Settings in the user's git config that change what blame reads, or stop it.
    @Test func blameIgnoresConfigThatWouldChangeIt() throws {
        guard let repo = try ScratchRepo() else { return }
        defer { repo.remove() }
        try repo.write("f.txt", "one\ntwo\n")
        try repo.commit("Ann", "First")
        // A list of commits to skip that this repository lacks (set globally, as GitHub suggests).
        try repo.git("config", "blame.ignoreRevsFile", ".missing-ignore-revs")
        guard case .annotated(let blame) = GitRunner.blame(of: repo.path + "/f.txt", git: repo.gitPath) else {
            return #expect(Bool(false), "a missing blame.ignoreRevsFile still gives a blame")
        }
        #expect(blame.lines.count == 2)
        // A textconv filter is not run: the lines are the file's own.
        try repo.write(".gitattributes", "*.txt diff=upper\n")
        try repo.git("config", "diff.upper.textconv", "sh -c 'echo EXTRA; tr a-z A-Z < \"$0\"'")
        try repo.commit("Bob", "Attributes")
        guard case .annotated(let plain) = GitRunner.blame(of: repo.path + "/f.txt", git: repo.gitPath) else { return #expect(Bool(false)) }
        #expect(plain.lines.count == 2)
    }
    /// A repository with SHA-256 object names: 64-character hashes, and 64 zeros for lines not committed.
    @Test func blameOfASHA256Repository() throws {
        guard let repo = try ScratchRepo(["--object-format=sha256"]) else { return }
        defer { repo.remove() }
        try repo.write("f.txt", "one\ntwo\n")
        try repo.commit("Ann", "First")
        guard case .annotated(let blame) = GitRunner.blame(of: repo.path + "/f.txt", git: repo.gitPath) else { return #expect(Bool(false)) }
        #expect(blame.head.count == 64 && blame.lines.count == 2)
        #expect(blame.lines.allSatisfy { blame.commit($0)?.author == "Ann" })
        try repo.write("f.txt", "one\nTWO\n")
        guard case .annotated(let disk) = GitRunner.blame(of: repo.path + "/f.txt", git: repo.gitPath, workingTree: true) else {
            return #expect(Bool(false))
        }
        #expect(disk.lines.map(\.isCommitted) == [true, false] && disk.commits.count == 1)
    }
    /// A shallow clone has no history before its oldest commit: lines git puts there are marked as such,
    /// and a full repository's first commit is not.
    @Test func blameOfAShallowClone() throws {
        guard let repo = try ScratchRepo() else { return }
        let clone = repo.path + "-shallow"
        defer { repo.remove(); try? FileManager.default.removeItem(atPath: clone) }
        try repo.write("f.txt", "one\ntwo\nthree\n")
        try repo.commit("Ann", "First")
        try repo.write("f.txt", "one\nTWO\nthree\n")
        try repo.commit("Bob", "Second")
        guard case .annotated(let full) = GitRunner.blame(of: repo.path + "/f.txt", git: repo.gitPath) else { return #expect(Bool(false)) }
        #expect(!full.isShallow && full.commits.values.allSatisfy { !full.isShallowBoundary($0) })
        try repo.write("f.txt", "one\nTWO\nthree\nfour\n")
        try repo.commit("Cy", "Third")

        try repo.git("clone", "-q", "--depth", "2", "file://" + repo.path, clone)
        guard case .annotated(let blame) = GitRunner.blame(of: clone + "/f.txt", git: repo.gitPath) else { return #expect(Bool(false)) }
        #expect(blame.isShallow)
        let cut = blame.lines.map { blame.commit($0).map(blame.isShallowBoundary) }
        #expect(cut == [true, true, true, false]) // Bob's commit is the oldest the clone has: Ann's older lines land there too
        let edited = EditedBlame(blame, diff: nil, lineCount: 4)
        let bob = try #require(blame.commit(blame.lines[0]))
        let cy = try #require(blame.commit(blame.lines[3]))
        #expect(edited.recency(of: bob) == 0 && edited.recency(of: cy) == 1)
    }
}

/// A repository in a temporary folder, for tests that run git.
struct ScratchRepo {
    let path: String
    let gitPath: String

    init?(_ initArguments: [String] = []) throws {
        guard let git = GitRunner.locateGit() else { return nil }
        gitPath = git
        path = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-blame-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try self.git(["init", "-q"] + initArguments)
    }

    func remove() { try? FileManager.default.removeItem(atPath: path) }

    func write(_ name: String, _ text: String) throws { try text.write(toFile: path + "/" + name, atomically: true, encoding: .utf8) }

    func git(_ args: String...) throws { try git(args) }

    func git(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gitPath)
        p.arguments = ["-C", path, "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "git \(args.joined(separator: " "))")
    }

    /// Commits everything as `author`.
    func commit(_ author: String, _ message: String) throws {
        try git("add", "-A")
        try git("-c", "user.name=\(author)", "-c", "user.email=\(author.lowercased())@example.com", "commit", "-qm", message)
    }
}
