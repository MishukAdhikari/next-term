import Foundation
import Testing
@testable import NextTermCore

@Suite struct ChangeTreeTests {
    let files = [
        ChangedFile(path: "app/Console/Kernel.php", status: .modified, added: 10, removed: 1),
        ChangedFile(path: "app/Console/Commands/Probe.php", status: .added, added: 139, removed: 0),
        ChangedFile(path: ".github/workflows/test.yml", status: .modified, added: 6, removed: 0),
        ChangedFile(path: "app/Enums/file10.php", status: .modified, added: 1, removed: 1),
        ChangedFile(path: "app/Enums/file2.php", status: .deleted, added: 0, removed: 4),
        ChangedFile(path: "README.md", oldPath: "readme.txt", status: .renamed, added: 2, removed: 2),
        ChangedFile(path: "logo.png", status: .added, isBinary: true),
    ]

    @Test func foldersHoldingChangesFirstThenFilesInFindersOrder() {
        let tree = ChangeTree.build(files)
        #expect(tree.map(\.name) == [".github/workflows", "app", "logo.png", "README.md"])
        // A folder holding only a folder is one row with it; one holding files is not joined.
        #expect(tree[0].isFolder && tree[0].path == ".github/workflows" && tree[0].children.map(\.name) == ["test.yml"])
        let app = tree[1]
        #expect(app.children.map(\.name) == ["Console", "Enums"])
        #expect(app.children[0].children.map(\.name) == ["Commands", "Kernel.php"])
        #expect(app.children[0].children[0].children.map(\.path) == ["app/Console/Commands/Probe.php"])
        #expect(app.children[1].children.map(\.name) == ["file2.php", "file10.php"])
        // A folder's counts are its files', added up; a file keeps its status and old name.
        #expect(app.stats == LineStats(added: 150, removed: 6, files: 4))
        #expect(tree[3].file?.status == .renamed && tree[3].file?.oldPath == "readme.txt")
        #expect(tree[2].file?.isBinary == true && tree[2].stats == LineStats(added: 0, removed: 0, files: 1))
        #expect(ChangeTree.build([]).isEmpty)
    }

    @Test func filesInTheTreesOrder() {
        let order = ChangeTree.files(in: ChangeTree.build(files)).map(\.path)
        #expect(order == [".github/workflows/test.yml", "app/Console/Commands/Probe.php", "app/Console/Kernel.php", "app/Enums/file2.php",
                          "app/Enums/file10.php", "logo.png", "README.md"])
    }

    @Test func aFileThatLeavesTheListGivesItsPlaceToTheNextOne() {
        let old = ["a", "b", "c", "d"]
        #expect(ChangeTree.neighbour(of: "b", in: old, keeping: ["a", "c", "d"]) == "c")
        #expect(ChangeTree.neighbour(of: "b", in: old, keeping: ["a", "d"]) == "d")
        // The last one: the one before it.
        #expect(ChangeTree.neighbour(of: "d", in: old, keeping: ["a", "b"]) == "b")
        #expect(ChangeTree.neighbour(of: "b", in: old, keeping: []) == nil)
        #expect(ChangeTree.neighbour(of: "x", in: old, keeping: ["a"]) == nil)
    }
}

@Suite struct ChangeBaseTests {
    let refs: Set<String> = ["refs/heads/main", "refs/heads/feat", "refs/remotes/origin/main", "refs/remotes/origin/feat",
                             "refs/remotes/fork/develop", "refs/remotes/fork/feat"]

    @Test func theUpstreamsDefaultBranchElseMainOrMaster() {
        let heads = ["origin": "refs/remotes/origin/main", "fork": "refs/remotes/fork/develop"]
        // The upstream's remote's HEAD.
        #expect(ChangeBase.pick(chosen: nil, upstream: "refs/remotes/fork/feat", refs: refs, remoteHeads: heads) == "refs/remotes/fork/develop")
        #expect(ChangeBase.pick(chosen: nil, upstream: "refs/remotes/origin/feat", refs: refs, remoteHeads: heads) == "refs/remotes/origin/main")
        // No upstream: origin's default branch.
        #expect(ChangeBase.pick(chosen: nil, upstream: nil, refs: refs, remoteHeads: heads) == "refs/remotes/origin/main")
        // No remote HEAD: the upstream remote's main, then the local main, then master.
        #expect(ChangeBase.pick(chosen: nil, upstream: "refs/remotes/origin/feat", refs: refs, remoteHeads: [:]) == "refs/remotes/origin/main")
        #expect(ChangeBase.pick(chosen: nil, upstream: nil, refs: refs, remoteHeads: [:]) == "refs/heads/main")
        #expect(ChangeBase.pick(chosen: nil, upstream: nil, refs: ["refs/heads/master", "refs/heads/x"], remoteHeads: [:]) == "refs/heads/master")
        #expect(ChangeBase.pick(chosen: nil, upstream: nil, refs: ["refs/heads/x"], remoteHeads: [:]) == nil)
        // A remote HEAD naming a branch that isn't there is passed over.
        #expect(ChangeBase.pick(chosen: nil, upstream: nil, refs: ["refs/heads/main"], remoteHeads: ["origin": "refs/remotes/origin/gone"]) == "refs/heads/main")
    }

    @Test func aChosenBaseWinsWhileItExists() {
        #expect(ChangeBase.pick(chosen: "refs/remotes/fork/develop", upstream: nil, refs: refs, remoteHeads: [:]) == "refs/remotes/fork/develop")
        #expect(ChangeBase.pick(chosen: "refs/heads/deleted", upstream: nil, refs: refs, remoteHeads: [:]) == "refs/heads/main")
    }

    @Test func onTheBaseItselfAllChangesIsUncommitted() {
        #expect(ChangeBase.isOnBase(branch: "refs/heads/main", base: "refs/heads/main", remotes: ["origin"]))
        #expect(ChangeBase.isOnBase(branch: "refs/heads/main", base: "refs/remotes/origin/main", remotes: ["origin"]))
        #expect(ChangeBase.isOnBase(branch: "refs/heads/team/main", base: "refs/remotes/origin/team/main", remotes: ["origin"]))
        #expect(!ChangeBase.isOnBase(branch: "refs/heads/feat", base: "refs/remotes/origin/main", remotes: ["origin"]))
        #expect(!ChangeBase.isOnBase(branch: "refs/heads/main", base: "refs/remotes/other/main", remotes: ["origin"]))
        #expect(!ChangeBase.isOnBase(branch: nil, base: "refs/heads/main", remotes: []))

        let feature = ChangeContext(branch: "refs/heads/feat", head: "h", base: "refs/heads/main", mergeBase: "m")
        #expect(feature.effective(.all) == .all && feature.effective(.uncommitted) == .uncommitted && feature.effective(.commit("c")) == .commit("c"))
        let onMain = ChangeContext(branch: "refs/heads/main", head: "h", base: "refs/heads/main", isOnBase: true)
        #expect(onMain.effective(.all) == .uncommitted)
        let noBase = ChangeContext(branch: "refs/heads/x", head: "h")
        #expect(noBase.effective(.all) == .uncommitted)
        #expect(feature.baseName == "main" && feature.branchName == "feat")
    }

    @Test func refsWithRemoteHeadsAndUpstreams() {
        let lines = [
            ["refs/heads/feat", "", "refs/remotes/origin/feat"],
            ["refs/heads/main", "", ""],
            ["refs/remotes/origin/HEAD", "refs/remotes/origin/main", ""],
            ["refs/remotes/origin/main", "", ""],
            ["not a ref", "", ""],
        ]
        let data = Data((lines.map { $0.joined(separator: "\0") }.joined(separator: "\n") + "\n").utf8)
        let parsed = ChangeBase.parseRefs(data)
        #expect(parsed.refs == ["refs/heads/feat", "refs/heads/main", "refs/remotes/origin/main"])
        #expect(parsed.remoteHeads == ["origin": "refs/remotes/origin/main"])
        #expect(parsed.upstreams == ["refs/heads/feat": "refs/remotes/origin/feat"])
    }

    @Test func rawAndCountsLeavingOutFilesOnlyTouched() {
        let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40), zero = String(repeating: "0", count: 40)
        let records: [String] = [
            ":100644 100644 \(a) \(zero) M", "edited.txt",
            ":100644 100644 \(a) \(zero) M", "touched.txt",
            ":100644 100644 \(a) \(zero) M", "touched, no count.txt",
            ":100644 100755 \(a) \(zero) M", "now executable",
            ":100644 100644 \(a) \(b) R090", "old.txt", "new.txt",
            ":000000 100644 \(zero) \(b) A", "logo.png",
            ":100644 000000 \(a) \(zero) D", "gone.txt",
            "3\t1\tedited.txt", "0\t0\ttouched.txt", "0\t0\tnow executable", "1\t1\t", "old.txt", "new.txt", "-\t-\tlogo.png", "0\t5\tgone.txt", "",
        ]
        let files = Changes.parseRawNumstat(Data(records.joined(separator: "\0").utf8))
        #expect(files == [
            ChangedFile(path: "edited.txt", status: .modified, added: 3, removed: 1),
            ChangedFile(path: "now executable", status: .modified, added: 0, removed: 0),
            ChangedFile(path: "new.txt", oldPath: "old.txt", status: .renamed, added: 1, removed: 1),
            ChangedFile(path: "logo.png", status: .added, isBinary: true),
            ChangedFile(path: "gone.txt", status: .deleted, added: 0, removed: 5),
        ])
        #expect(Changes.parseRawNumstat(Data()).isEmpty)
    }
}

@Suite struct UnifiedRowsTests {
    /// Lines 1 to 40, then lines 5 and 30 changed: two hunks with three lines of context each.
    let diff = """
    diff --git a/a.txt b/a.txt
    index 1111111..2222222 100644
    --- a/a.txt
    +++ b/a.txt
    @@ -2,7 +2,8 @@
     line 2
     line 3
     line 4
    -line 5
    +line five
    +line 5b
     line 6
     line 7
     line 8
    @@ -27,7 +28,7 @@
     line 27
     line 28
     line 29
    -line 30 old
    +line 30 new
     line 31
     line 32
     line 33

    """

    func whole() -> FileDiff {
        var lines = (1...40).map { " line \($0)" }
        lines[4] = "-line 5\n+line five\n+line 5b"
        lines[29] = "-line 30 old\n+line 30 new"
        return UnifiedDiff.parse("diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1,40 +1,41 @@\n" + lines.joined(separator: "\n") + "\n")[0]
    }

    @Test func foldsBetweenBeforeAndAfterTheChanges() {
        let file = UnifiedDiff.parse(diff)[0]
        let rows = UnifiedRows.rows(for: file)
        let kinds = rows.map(\.kind)
        #expect(kinds == [.fold, .context, .context, .context, .removed, .added, .added, .context, .context, .context,
                          .fold, .context, .context, .context, .removed, .added, .context, .context, .context, .fold])
        // Line 1 before the first change; 9 to 26 between; the rest of the file, whose length isn't known.
        #expect(rows[0].fold == UnifiedFold(oldStart: 1, newStart: 1, count: 1))
        #expect(rows[10].fold == UnifiedFold(oldStart: 9, newStart: 10, count: 18))
        #expect(rows[19].fold == UnifiedFold(oldStart: 34, newStart: 35, count: nil))
        #expect(rows[0].fold?.title == "1 unmodified line" && rows[10].fold?.title == "18 unmodified lines" && rows[19].fold?.title == "Show more lines")
        // Each row knows its hunk, its number and its mark; a removed line shows the old number.
        #expect(rows[4].hunk == 0 && rows[4].number == 5 && rows[4].marker == "−")
        #expect(rows[5].number == 5 && rows[6].number == 6 && rows[6].marker == "+")
        #expect(rows[15].hunk == 1 && rows[15].number == 31)
        #expect(rows[10].hunk == nil && rows[10].line == nil)
        // The changed words of a removed line and the added one after it, as side by side.
        #expect(rows[4].changes == [NSRange(location: 5, length: 1)] && rows[5].changes == [NSRange(location: 5, length: 4)])
        #expect(rows[6].changes.isEmpty)
    }

    @Test func theWholeFileFillsFoldsAndShortRunsShow() {
        let file = UnifiedDiff.parse(diff)[0]
        let fill = UnifiedRows.fill(from: whole())
        #expect(fill.count == 38 && fill[9]?.newNumber == 10 && fill[9]?.text == "line 9")
        // The one line before the first change is shown; the 18 between stay folded; the end is counted now.
        let rows = UnifiedRows.rows(for: file, fill: fill)
        #expect(rows.first?.kind == .context && rows.first?.number == 1 && rows.first?.hunk == nil)
        let folds = rows.compactMap(\.fold)
        #expect(folds == [UnifiedFold(oldStart: 9, newStart: 10, count: 18), UnifiedFold(oldStart: 34, newStart: 35, count: 7)])
        // Opened, a fold's lines are there, numbered, in no hunk.
        let open = UnifiedRows.rows(for: file, expanded: [9, 34], fill: fill)
        #expect(open.allSatisfy { $0.kind != .fold })
        #expect(open.count == rows.count - 2 + 18 + 7)
        #expect(open.last?.number == 41 && open.last?.line?.text == "line 40")
        let numbers = open.filter { $0.kind != .removed }.compactMap(\.number)
        #expect(numbers == Array(1...41))
        // The same rows without a fill once nothing is folded: hunks number the same either way.
        #expect(open.filter { $0.hunk != nil }.map(\.hunk) == UnifiedRows.rows(for: file).filter { $0.hunk != nil }.map(\.hunk))
    }

    @Test func newDeletedAndEndOfFile() {
        let text = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +one
        +two
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        --- a/gone.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -one
        -two
        diff --git a/end.txt b/end.txt
        --- a/end.txt
        +++ b/end.txt
        @@ -8,4 +8,4 @@
         a
         b
         c
        -d
        \\ No newline at end of file
        +e
        \\ No newline at end of file

        """
        let files = UnifiedDiff.parse(text)
        #expect(UnifiedRows.rows(for: files[0]).map(\.kind) == [.added, .added])
        #expect(UnifiedRows.rows(for: files[0]).map(\.number) == [1, 2])
        #expect(UnifiedRows.rows(for: files[1]).map(\.kind) == [.removed, .removed])
        // At the end of the file (no newline there): no "Show more lines" after it.
        let end = UnifiedRows.rows(for: files[2])
        #expect(end.map(\.kind) == [.fold, .context, .context, .context, .removed, .added])
        #expect(end.first?.fold?.count == 7)
        #expect(UnifiedRows.rows(for: FileDiff()).isEmpty)
    }

    @Test func untrackedFilesAreAllAdded() {
        let file = UnifiedRows.addedFile(path: "x.sh", data: Data("echo 1\r\necho 2\r\nlast".utf8))
        #expect(file.isNew && file.newPath == "x.sh" && !file.isBinary)
        #expect(file.hunks.count == 1 && file.hunks[0].newCount == 3 && file.hunks[0].newMissingNewline)
        #expect(file.hunks[0].lines.map(\.text) == ["echo 1\r", "echo 2\r", "last"])
        #expect(file.hunks[0].lines.map(\.newNumber) == [1, 2, 3])
        let ended = UnifiedRows.addedFile(path: "y", data: Data("a\nb\n".utf8))
        #expect(ended.hunks[0].lines.count == 2 && !ended.hunks[0].newMissingNewline)
        #expect(UnifiedRows.addedFile(path: "z.bin", data: Data([0x50, 0, 1])).isBinary)
        #expect(UnifiedRows.addedFile(path: "empty", data: Data()).hunks.isEmpty)
        // As git would write it: a patch of it applies to nothing.
        #expect(UnifiedDiff.patch(for: ended.hunks[0], in: ended).hasSuffix("@@ -0,0 +1,2 @@\n+a\n+b\n"))
    }
}

/// What git writes that isn't plain: names it quotes, lines that aren't UTF-8.
@Suite struct DiffTextTests {
    @Test func namesGitQuotesAreReadBack() {
        let text = #"""
        diff --git "a/quote\"name.txt" "b/quote\"name.txt"
        index 1111111111111111111111111111111111111111..2222222222222222222222222222222222222222 100644
        --- "a/quote\"name.txt"
        +++ "b/quote\"name.txt"
        @@ -1 +1 @@
        -a
        +b
        diff --git "a/back\\slash.txt" "b/tab\there.txt"
        similarity index 50%
        rename from "back\\slash.txt"
        rename to "tab\there.txt"
        diff --git a/plain.txt "b/caf\303\251.txt"
        similarity index 100%
        rename from plain.txt
        rename to "caf\303\251.txt"
        diff --git "a/new\nline.bin" "b/new\nline.bin"
        new file mode 100644
        Binary files /dev/null and "b/new\nline.bin" differ
        diff --git a/with space.txt b/with space.txt
        --- a/with space.txt\#t
        +++ b/with space.txt\#t
        @@ -1 +1 @@
        -x
        +y

        """#
        let files = UnifiedDiff.parse(text)
        #expect(files.map(\.path) == ["quote\"name.txt", "tab\there.txt", "café.txt", "new\nline.bin", "with space.txt"])
        #expect(files[0].oldPath == "quote\"name.txt" && files[0].hunks.count == 1)
        #expect(files[1].oldPath == #"back\slash.txt"# && files[1].isRename)
        #expect(files[2].oldPath == "plain.txt")
        #expect(files[3].isNew && files[3].isBinary)
        #expect(files[4].oldPath == "with space.txt")
        // The header stays as git wrote it, so a hunk's patch still applies.
        #expect(UnifiedDiff.patch(for: files[0].hunks[0], in: files[0]).hasPrefix("diff --git \"a/quote\\\"name.txt\""))
    }

    @Test func linesNotInUTF8ReadAsLatin1() {
        var data = Data("diff --git a/l.txt b/l.txt\n--- a/l.txt\n+++ b/l.txt\n@@ -1 +1 @@\n-caf".utf8)
        data.append(0xE9)
        data.append(contentsOf: Data("\n+café\n".utf8))
        let files = UnifiedDiff.parse(GitRunner.diffText(data))
        #expect(files.first?.hunks.first?.lines.map(\.text) == ["café", "café"])
        let added = UnifiedRows.addedFile(path: "l.txt", data: Data([0x63, 0x61, 0x66, 0xE9, 0x0A]))
        #expect(!added.isBinary && added.hunks.first?.lines.map(\.text) == ["café"])
    }
}

/// The scopes on a real repository: a branch with commits since main, and uncommitted work on top.
@Suite struct ChangeScopeTests {
    func run(_ git: String, _ root: URL, _ args: String...) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-C", root.path, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ root: URL, _ name: String, _ text: String) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func allChangesUncommittedAndACommit() throws {
        guard let git = GitRunner.locateGit() else { return }
        let root = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path)).appendingPathComponent("nt-changes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = run(git, root, "init", "-q")
        try write(root, "a.txt", (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n")
        try write(root, "old.txt", "x\ny\nz\n")
        _ = run(git, root, "add", "-A")
        _ = run(git, root, "commit", "-qm", "Base")
        let start = run(git, root, "rev-parse", "HEAD")

        // On main itself: All changes is Uncommitted, and there is nothing yet.
        let onMain = try #require(Changes.context(in: root.path, git: git, chosen: nil))
        #expect(onMain.branch == "refs/heads/main" && onMain.base == "refs/heads/main" && onMain.isOnBase && onMain.mergeBase == nil)
        #expect(onMain.effective(.all) == .uncommitted)
        #expect(Changes.files(.all, context: onMain, in: root.path, git: git)?.files.isEmpty == true)

        _ = run(git, root, "switch", "-qc", "feat")
        try write(root, "src/feat.txt", "feat\n")
        _ = run(git, root, "add", "-A")
        _ = run(git, root, "commit", "-qm", "Feat file")
        let featCommit = run(git, root, "rev-parse", "HEAD")
        _ = run(git, root, "mv", "old.txt", "new.txt")
        _ = run(git, root, "commit", "-qm", "Rename")
        // Uncommitted on top: a staged edit, an untracked file, and a file only touched.
        try write(root, "a.txt", (1...20).map { $0 == 3 ? "three" : "line \($0)" }.joined(separator: "\n") + "\n")
        _ = run(git, root, "add", "a.txt")
        try write(root, "notes.md", "one\ntwo\n")
        try write(root, "src/feat.txt", "feat\n") // the same text, written again

        let context = try #require(Changes.context(in: root.path, git: git, chosen: nil))
        #expect(context.branch == "refs/heads/feat" && context.base == "refs/heads/main" && !context.isOnBase)
        #expect(context.mergeBase == start && context.bases.contains("refs/heads/feat"))

        let all = try #require(Changes.files(.all, context: context, in: root.path, git: git))
        #expect(Set(all.files.map(\.path)) == ["a.txt", "new.txt", "src/feat.txt", "notes.md"])
        #expect(all.file(at: "new.txt")?.status == .renamed && all.file(at: "new.txt")?.oldPath == "old.txt")
        #expect(all.file(at: "a.txt")?.added == 1 && all.file(at: "a.txt")?.removed == 1)
        #expect(all.untracked == ["notes.md"] && all.file(at: "notes.md")?.added == 2 && all.file(at: "notes.md")?.status == .added)

        // Uncommitted: only what isn't committed; the file written with the same text is not listed.
        let uncommitted = try #require(Changes.files(.uncommitted, context: context, in: root.path, git: git))
        #expect(Set(uncommitted.files.map(\.path)) == ["a.txt", "notes.md"])

        // A commit: its own files, its parent.
        let commit = try #require(Changes.files(.commit(featCommit), context: context, in: root.path, git: git))
        #expect(commit.files.map(\.path) == ["src/feat.txt"] && commit.parent == start)

        // The All files page: every file's diff, by path.
        let diffs = try #require(Changes.diffs(.all, context: context, set: all, in: root.path, git: git))
        #expect(Set(diffs.keys) == ["a.txt", "new.txt", "src/feat.txt", "notes.md"])
        #expect(diffs["notes.md"]?.hunks.first?.lines.map(\.text) == ["one", "two"])
        #expect(diffs["a.txt"]?.hunks.first?.lines.contains { $0.kind == .added && $0.text == "three" } == true)
        let commitDiffs = try #require(Changes.diffs(.commit(featCommit), context: context, set: commit, in: root.path, git: git))
        #expect(commitDiffs["src/feat.txt"]?.isNew == true)

        // One file with the whole file as context: what fills its folds.
        let file = try #require(all.file(at: "a.txt"))
        let wholeFile = try #require(Changes.diff(of: file, scope: .all, context: context, set: all, in: root.path, git: git, lines: UnifiedRows.wholeFile))
        #expect(UnifiedRows.fill(from: wholeFile).count == 19)

        // Another base, chosen: counted from there.
        _ = run(git, root, "branch", "later", featCommit)
        let chosen = try #require(Changes.context(in: root.path, git: git, chosen: "refs/heads/later"))
        #expect(chosen.base == "refs/heads/later" && chosen.mergeBase == featCommit)
        let fromLater = try #require(Changes.files(.all, context: chosen, in: root.path, git: git))
        #expect(!fromLater.files.contains { $0.path == "src/feat.txt" })
    }

    /// A file in Latin-1 and names git quotes are on the All files page like any other, committed or not.
    @Test func latin1AndQuotedNames() throws {
        guard let git = GitRunner.locateGit() else { return }
        let root = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path)).appendingPathComponent("nt-changes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func latin1(_ text: String) throws { try #require(text.data(using: .isoLatin1)).write(to: root.appendingPathComponent("latin1.txt")) }
        let names = ["quote\"name.txt", #"back\slash.txt"#, "tab\there.txt", "naïve.txt"]
        _ = run(git, root, "init", "-q")
        try latin1("caf\u{E9}\nline 2\n")
        for name in names { try write(root, name, "one\n") }
        _ = run(git, root, "add", "-A")
        _ = run(git, root, "commit", "-qm", "Base")
        _ = run(git, root, "switch", "-qc", "feat")
        try latin1("caf\u{E9} au lait\nline 2\n")
        for name in names { try write(root, name, "two\n") }
        _ = run(git, root, "commit", "-qam", "Change them all")
        try latin1("caf\u{E9} au lait\nligne deux, d\u{E9}j\u{E0}\n") // and uncommitted on top

        let context = try #require(Changes.context(in: root.path, git: git, chosen: nil))
        for scope in [ChangeScope.all, .uncommitted] {
            let set = try #require(Changes.files(scope, context: context, in: root.path, git: git))
            let diffs = try #require(Changes.diffs(scope, context: context, set: set, in: root.path, git: git), "\(scope)")
            #expect(Set(diffs.keys) == Set(set.files.map(\.path)), "\(scope)")
            #expect(diffs["latin1.txt"]?.hunks.first?.lines.contains { $0.kind == .added && $0.text == "ligne deux, déjà" } == true, "\(scope)")
            // The file's own diff too, with the whole file as context.
            let file = try #require(set.file(at: "latin1.txt"))
            let whole = Changes.diff(of: file, scope: scope, context: context, set: set, in: root.path, git: git, lines: UnifiedRows.wholeFile)
            #expect(whole?.hunks.first?.lines.contains { $0.text == "café au lait" } == true, "\(scope)")
        }
        let all = try #require(Changes.files(.all, context: context, in: root.path, git: git))
        #expect(Set(all.files.map(\.path)) == Set(names + ["latin1.txt"]))
        #expect(Changes.diffs(.all, context: context, set: all, in: root.path, git: git)?["tab\there.txt"]?.hunks.first?.lines.last?.text == "two")
    }

    /// Past the limit, only the files listed are kept as untracked: nothing else is looked up.
    @Test func untrackedPastTheLimitAreTheListedOnes() throws {
        guard let git = GitRunner.locateGit() else { return }
        let root = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path)).appendingPathComponent("nt-changes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("many"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = run(git, root, "init", "-q")
        try write(root, "a.txt", "a\n")
        _ = run(git, root, "add", "-A")
        _ = run(git, root, "commit", "-qm", "Base")
        for i in 0..<(Changes.fileLimit + 10) { try Data("x\n".utf8).write(to: root.appendingPathComponent("many/\(i).txt")) }
        let context = try #require(Changes.context(in: root.path, git: git, chosen: nil))
        let set = try #require(Changes.files(.uncommitted, context: context, in: root.path, git: git))
        #expect(set.truncated && set.files.count == Changes.fileLimit)
        #expect(set.untracked == Set(set.files.map(\.path)))
        let diffs = try #require(Changes.diffs(.uncommitted, context: context, set: set, in: root.path, git: git))
        #expect(diffs.count == Changes.fileLimit)
    }
}
