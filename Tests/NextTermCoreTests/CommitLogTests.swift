import Foundation
import Testing
@testable import NextTermCore

@Suite struct CommitLogTests {
    @Test func decorations() {
        let refs = CommitRef.parse(decoration: "HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1.0, refs/stash")
        #expect(refs == [
            CommitRef(kind: .branch, name: "main", fullName: "refs/heads/main", isCurrent: true),
            CommitRef(kind: .remote, name: "origin/main", fullName: "refs/remotes/origin/main"),
            CommitRef(kind: .tag, name: "v1.0", fullName: "refs/tags/v1.0"),
            CommitRef(kind: .other, name: "stash", fullName: "refs/stash"),
        ])
        #expect(CommitRef.parse(decoration: "HEAD, refs/heads/feat/x") == [
            CommitRef(kind: .head, name: "HEAD", fullName: "HEAD"),
            CommitRef(kind: .branch, name: "feat/x", fullName: "refs/heads/feat/x"),
        ])
        #expect(CommitRef.parse(decoration: "").isEmpty)
    }

    @Test func logRecords() {
        let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40), c = String(repeating: "c", count: 40)
        let records = [
            [a, "\(b) \(c)", "Ann", "ann@x", "1700000000", "Bo", "bo@x", "1700000100", "HEAD -> refs/heads/main", "Merge feat"],
            [b, c, "Ann", "ann@x", "1690000000", "Ann", "ann@x", "1690000000", "", "Subject with\ttab"],
        ].map { $0.joined(separator: "\0") + "\0" }.joined()
        let commits = CommitLog.parse(Data(records.utf8))
        #expect(commits.count == 2)
        #expect(commits[0].sha == a && commits[0].parents == [b, c] && commits[0].isMerge && commits[0].shortSHA == "aaaaaaa")
        #expect(commits[0].committerName == "Bo" && commits[0].authorDate == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(commits[0].refs.first?.isCurrent == true)
        #expect(commits[1].parents == [c] && commits[1].subject == "Subject with\ttab" && !commits[1].isMerge)
    }

    @Test func changedFiles() {
        let records = [":100644 100644 aaa bbb M", "b.txt", ":000000 100644 000 ccc A", "bin.dat", ":100644 100644 ddd ddd R100", "a.txt", "c.txt",
                       "1\t0\tb.txt", "-\t-\tbin.dat", "0\t0\t", "a.txt", "c.txt", ""]
        let files = CommitLog.parseChanges(Data(records.joined(separator: "\0").utf8))
        #expect(files == [
            ChangedFile(path: "b.txt", status: .modified, added: 1, removed: 0),
            ChangedFile(path: "bin.dat", status: .added, isBinary: true),
            ChangedFile(path: "c.txt", oldPath: "a.txt", status: .renamed, added: 0, removed: 0),
        ])
    }

    @Test func hashPrefixes() {
        #expect(CommitQuery(text: " 4CC062d ").hashPrefix == "4cc062d")
        #expect(CommitQuery(text: "abc12").hashPrefix == nil) // too short to be taken for a hash
        #expect(CommitQuery(text: "fix login").hashPrefix == nil)
        #expect(CommitQuery(text: "fix").isConnected == false && CommitQuery(author: "ann").isConnected == false)
        #expect(CommitQuery(paths: ["a"]).isConnected && CommitQuery(paths: ["a"]).isFiltered && !CommitQuery().isFiltered)
    }

    @Test func queryArguments() {
        let all = CommitQuery().arguments(skip: 0, limit: 10, includeHead: true)
        #expect(Array(all.suffix(6)) == ["--branches", "--remotes", "--tags", "--end-of-options", "HEAD", "--"])
        #expect(all.contains("--topo-order") && all.contains("--max-count=10") && all.last == "--")
        let filtered = CommitQuery(scope: .ref("refs/heads/main"), text: "a.b", regex: true, author: "Ann (QA)", since: "2 weeks ago", paths: ["src", "x y"])
            .arguments(skip: 1000, limit: 1000, includeHead: false)
        #expect(filtered.contains("--extended-regexp") && filtered.contains("--grep=a.b") && filtered.contains("--author=Ann \\(QA\\)"))
        #expect(filtered.contains("--since=2 weeks ago") && filtered.contains("--parents") && filtered.contains("--skip=1000"))
        #expect(Array(filtered.suffix(5)) == ["--end-of-options", "refs/heads/main", "--", "src", "x y"])
        let fixed = CommitQuery(text: "a.b", author: "Ann").arguments(skip: 0, limit: 1, includeHead: true)
        #expect(fixed.contains("--fixed-strings") && fixed.contains("--regexp-ignore-case") && fixed.contains("--author=Ann") && !fixed.contains("--parents"))
    }

    /// main: one, then x by Ann; feat: a rename; a merge of feat; a tag on the first commit.
    @Test func logOfARealRepository() throws {
        guard let git = GitRunner.locateGit() else { return }
        let work = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path)).appendingPathComponent("nt-log-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: work) }
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        @discardableResult func sh(_ args: [String], name: String = "T", email: String = "t@t") -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", work, "-c", "user.name=\(name)", "-c", "user.email=\(email)", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false",
                           "-c", "tag.gpgsign=false"] + args
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("nt-log-out-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: out.path, contents: nil)
            defer { try? FileManager.default.removeItem(at: out) }
            let handle = try? FileHandle(forWritingTo: out)
            p.standardOutput = handle
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            try? handle?.close()
            return ((try? String(contentsOf: out, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func write(_ path: String, _ text: String) throws {
            try text.write(toFile: (work as NSString).appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        sh(["init"])
        #expect(CommitLog.page(CommitQuery(), in: work, git: git) == []) // no commits yet

        try write("a.txt", (1...20).map { "line \($0)\n" }.joined())
        sh(["add", "-A"])
        sh(["commit", "-qm", "One"])
        let one = sh(["rev-parse", "HEAD"])
        sh(["tag", "v1"])
        sh(["switch", "-qc", "feat"])
        sh(["mv", "a.txt", "b.txt"])
        try write("b.txt", (1...20).map { "line \($0)\n" }.joined() + "line 21\n")
        sh(["add", "-A"])
        sh(["commit", "-qm", "Rename a to b\n\nKeeps the lines, adds one."])
        let rename = sh(["rev-parse", "HEAD"])
        sh(["switch", "-q", "main"])
        try write("x.txt", "x\n")
        sh(["add", "x.txt"])
        sh(["commit", "-qm", "Add x"], name: "Ann Lee", email: "ann@example.com")
        let x = sh(["rev-parse", "HEAD"])
        sh(["merge", "-q", "--no-ff", "--no-edit", "feat"])
        let merge = sh(["rev-parse", "HEAD"])

        let all = try #require(CommitLog.page(CommitQuery(), in: work, git: git))
        #expect(all.map(\.sha).first == merge && Set(all.map(\.sha)) == [one, rename, x, merge])
        #expect(all[0].parents == [x, rename] && all[0].refs.contains { $0.name == "main" && $0.isCurrent })
        #expect(all.first { $0.sha == one }?.refs.contains(CommitRef(kind: .tag, name: "v1", fullName: "refs/tags/v1")) == true)
        // Topological: every commit is listed after all of its children.
        let position = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1.sha, $0) })
        #expect(all.allSatisfy { commit in commit.parents.allSatisfy { (position[$0] ?? .max) > position[commit.sha]! } })
        // In the graph: two lanes, from the merge down to where feat started, and nothing left open.
        var graph = CommitGraph()
        let rows = graph.add(all)
        #expect(rows[0].isMerge && rows.map(\.width).max() == 2 && rows.last?.column == 0 && graph.openLanes == 0)

        // Paging.
        let first = try #require(CommitLog.page(CommitQuery(), skip: 0, limit: 2, in: work, git: git))
        let second = try #require(CommitLog.page(CommitQuery(), skip: 2, limit: 2, in: work, git: git))
        #expect((first + second).map(\.sha) == all.map(\.sha))

        // Filters.
        #expect(CommitLog.page(CommitQuery(author: "ANN"), in: work, git: git)?.map(\.sha) == [x])
        #expect(CommitLog.page(CommitQuery(author: "ann@example"), in: work, git: git)?.map(\.sha) == [x])
        #expect(CommitLog.page(CommitQuery(text: "rename A"), in: work, git: git)?.map(\.sha) == [rename])
        #expect(CommitLog.page(CommitQuery(text: "a.t"), in: work, git: git)?.isEmpty == true) // a fixed string, not a pattern
        #expect(CommitLog.page(CommitQuery(text: "^add .$", regex: true), in: work, git: git)?.map(\.sha) == [x])
        #expect(CommitLog.page(CommitQuery(text: String(rename.prefix(9))), in: work, git: git)?.map(\.sha) == [rename]) // a hash
        #expect(CommitLog.page(CommitQuery(scope: .ref("refs/heads/feat")), in: work, git: git)?.map(\.sha) == [rename, one])
        #expect(CommitLog.page(CommitQuery(scope: .ref("refs/tags/v1")), in: work, git: git)?.map(\.sha) == [one])
        #expect(CommitLog.page(CommitQuery(since: "2099-01-01"), in: work, git: git) == [])
        #expect(CommitLog.page(CommitQuery(scope: .ref("refs/heads/missing")), in: work, git: git) == nil)
        // Limited to a path, parents are the nearest commits that are listed.
        let onX = try #require(CommitLog.page(CommitQuery(paths: ["x.txt"]), in: work, git: git))
        #expect(onX.map(\.sha) == [x] && onX[0].parents.isEmpty)
        #expect(CommitLog.page(CommitQuery(paths: ["b.txt"]), in: work, git: git)?.map(\.sha) == [rename])

        // Details: the whole message, files with status and counts; a merge against its first parent.
        let renamed = try #require(CommitLog.details(of: rename, in: work, git: git))
        #expect(renamed.message == "Rename a to b\n\nKeeps the lines, adds one." && renamed.body == "Keeps the lines, adds one.")
        #expect(renamed.commit.subject == "Rename a to b" && renamed.commit.refs.contains { $0.name == "feat" })
        #expect(renamed.files == [ChangedFile(path: "b.txt", oldPath: "a.txt", status: .renamed, added: 1, removed: 0)])
        #expect(CommitLog.details(of: merge, in: work, git: git)?.files.map(\.path) == ["b.txt"])
        let root = try #require(CommitLog.details(of: one, in: work, git: git))
        #expect(root.files == [ChangedFile(path: "a.txt", status: .added, added: 20, removed: 0)] && root.totals == LineStats(added: 20, removed: 0, files: 1))
        let capped = try #require(CommitLog.details(of: merge, in: work, git: git, fileLimit: 0))
        #expect(capped.files.isEmpty && capped.truncated)

        // One file's diff in a commit: a rename compares with where it came from.
        let diff = try #require(CommitLog.diff(of: "b.txt", oldPath: "a.txt", commit: rename, parent: one, in: work, git: git))
        #expect(diff.isRename && diff.hunks.count == 1 && diff.hunks[0].added == 1 && diff.hunks[0].removed == 0)
        let added = try #require(CommitLog.diff(of: "a.txt", commit: one, parent: nil, in: work, git: git))
        #expect(added.isNew && added.hunks.first?.added == 20)

        #expect(CommitLog.tags(in: work, git: git) == ["v1"])
        // The refs' signature changes with a branch switch at the same commit, and not otherwise.
        sh(["branch", "same"])
        let signature = CommitLog.refsSignature(in: work, git: git)
        #expect(signature != nil && CommitLog.refsSignature(in: work, git: git) == signature)
        sh(["switch", "-q", "same"])
        #expect(CommitLog.refsSignature(in: work, git: git) != signature)
        #expect(CommitLog.resolve("v1", in: work, git: git) == one && CommitLog.resolve("nope", in: work, git: git) == nil)
    }

    /// Paths are file names: brackets, stars and a leading colon are not pattern syntax.
    @Test func pathsAreFileNames() throws {
        let repo = try #require(ScratchRepo())
        defer { repo.remove() }
        var made: [String: String] = [:]
        for name in [":weird.txt", "1.txt", "[1].txt", "f*.txt", "foo.txt"] {
            try repo.write(name, "\(name)\n")
            made[name] = repo.commit("add \(name)", [name])
        }
        for name in made.keys.sorted() {
            #expect(CommitLog.page(CommitQuery(paths: [name]), in: repo.work, git: repo.git)?.map(\.subject) == ["add \(name)"], "\(name)")
        }
        let weird = try #require(made[":weird.txt"])
        #expect(CommitLog.details(of: weird, in: repo.work, git: repo.git)?.files.map(\.path) == [":weird.txt"])
        let diff = CommitLog.diff(of: ":weird.txt", commit: weird, parent: nil, in: repo.work, git: repo.git)
        #expect(diff?.isNew == true && diff?.hunks.first?.added == 1)
    }

    /// Ignoring case covers letters beyond A to Z, in the message and in names. (A Cyrillic name: Process
    /// passes “ë” decomposed, and git would keep a name given with -c that way.)
    @Test func searchIgnoresCaseBeyondASCII() throws {
        let repo = try #require(ScratchRepo())
        defer { repo.remove() }
        try repo.write("a.txt", "a\n")
        let sha = repo.commit("Über alles: ÉCOLE fix", name: "Жанна Ли", email: "zh@x")
        try repo.write("b.txt", "b\n")
        repo.commit("Other")
        for query in [CommitQuery(text: "über"), CommitQuery(text: "école"), CommitQuery(text: "^über", regex: true), CommitQuery(author: "жанна л")] {
            #expect(CommitLog.page(query, in: repo.work, git: repo.git)?.map(\.sha) == [sha], "\(query)")
        }
    }

    /// In a partial clone, reading a commit's files downloads nothing: they are listed without counts.
    @Test func aPartialCloneIsNotFetchedFrom() throws {
        let repo = try #require(ScratchRepo())
        defer { repo.remove() }
        try repo.write("a.txt", "one\n")
        repo.commit("One")
        try repo.write("a.txt", "two\n")
        try repo.write("b.txt", "b\n")
        let two = repo.commit("Two")
        let clone = repo.work + "-partial"
        defer { try? FileManager.default.removeItem(atPath: clone) }
        repo.sh(["config", "uploadpack.allowFilter", "true"]) // read by the serving side
        repo.sh(["clone", "-q", "--filter=blob:none", "--no-checkout", "file://" + repo.work, clone])
        let packs = { (try? FileManager.default.contentsOfDirectory(atPath: clone + "/.git/objects/pack"))?.sorted() ?? [] }
        let before = packs()
        try #require(!before.isEmpty)
        let details = try #require(CommitLog.details(of: two, in: clone, git: repo.git))
        #expect(details.files.map(\.path) == ["a.txt", "b.txt"] && details.files.map(\.status) == [.modified, .added])
        #expect(!details.isCounted && packs() == before)
        #expect(CommitLog.details(of: two, in: repo.work, git: repo.git)?.isCounted == true)
    }
}

/// A repository in a temporary folder, removed with `remove()`.
struct ScratchRepo {
    let git: String
    let work: String

    init?() {
        guard let git = GitRunner.locateGit() else { return nil }
        self.git = git
        work = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path)).appendingPathComponent("nt-log-\(UUID().uuidString)").path
        guard (try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)) != nil else { return nil }
        sh(["init", "-q"])
    }

    func remove() { try? FileManager.default.removeItem(atPath: work) }

    @discardableResult func sh(_ args: [String], name: String = "T", email: String = "t@t") -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-C", work, "-c", "user.name=\(name)", "-c", "user.email=\(email)", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false",
                       "-c", "tag.gpgsign=false"] + args
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("nt-log-out-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: out) }
        let handle = try? FileHandle(forWritingTo: out)
        p.standardOutput = handle
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        try? handle?.close()
        return ((try? String(contentsOf: out, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ path: String, _ text: String) throws {
        try text.write(toFile: (work as NSString).appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    /// Commits these paths (all changes when empty); the new commit's id.
    @discardableResult func commit(_ message: String, _ paths: [String] = [], name: String = "T", email: String = "t@t") -> String {
        sh(["add", "-A", "--"] + paths.map { ":(literal)" + $0 })
        sh(["commit", "-qm", message], name: name, email: email)
        return sh(["rev-parse", "HEAD"])
    }
}
