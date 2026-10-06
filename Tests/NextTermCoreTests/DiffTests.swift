import Foundation
import Testing
@testable import NextTermCore

@Suite struct DiffParsingTests {
    let modified = """
    diff --git a/src/app.swift b/src/app.swift
    index 1111111..2222222 100644
    --- a/src/app.swift
    +++ b/src/app.swift
    @@ -1,4 +1,5 @@ struct App {
     let a = 1
    -let b = 2
    +let b = 20
    +let c = 3
     let d = 4
     let e = 5
    @@ -10 +11 @@ func tail()
    -old tail
    \\ No newline at end of file
    +new tail
    \\ No newline at end of file
    diff --git a/old name.txt b/new name.txt
    similarity index 90%
    rename from old name.txt
    rename to new name.txt
    diff --git a/logo.png b/logo.png
    new file mode 100644
    index 0000000..3333333
    Binary files /dev/null and b/logo.png differ
    diff --git a/gone.md b/gone.md
    deleted file mode 100644
    index 4444444..0000000
    --- a/gone.md
    +++ /dev/null
    @@ -1 +0,0 @@
    -bye

    """

    @Test func files() {
        let files = UnifiedDiff.parse(modified)
        #expect(files.map(\.path) == ["src/app.swift", "new name.txt", "logo.png", "gone.md"])
        let app = files[0]
        #expect(app.hunks.count == 2)
        #expect(app.hunks[0].section == "struct App {")
        #expect(app.hunks[0].added == 2 && app.hunks[0].removed == 1)
        #expect(app.hunks[0].lines[2] == DiffLine(kind: .added, text: "let b = 20", oldNumber: nil, newNumber: 2))
        #expect(app.hunks[0].lines[4] == DiffLine(kind: .context, text: "let d = 4", oldNumber: 3, newNumber: 4))
        #expect(app.hunks[1].oldStart == 10 && app.hunks[1].oldCount == 1)
        #expect(app.hunks[1].oldMissingNewline && app.hunks[1].newMissingNewline)
        #expect(files[1].isRename && files[1].oldPath == "old name.txt")
        #expect(files[2].isBinary && files[2].isNew)
        #expect(files[3].isDeleted && files[3].hunks[0].lines.first?.text == "bye")
    }

    @Test func sideBySidePairsChangesAndKeepsColumnsAligned() {
        let rows = SideBySide.rows(for: UnifiedDiff.parse(modified)[0])
        let kinds = rows.map(\.kind)
        #expect(kinds == [.hunkHeader, .unchanged, .changed, .added, .unchanged, .unchanged, .hunkHeader, .changed])
        let changed = rows[2]
        #expect(changed.left?.text == "let b = 2" && changed.right?.text == "let b = 20")
        #expect(changed.leftChanges == [NSRange(location: 8, length: 1)] && changed.rightChanges == [NSRange(location: 8, length: 2)])
        #expect(rows[3].left == nil && rows[3].right?.text == "let c = 3") // filler on the left
    }

    @Test func wordDiff() {
        let (old, new) = WordDiff.changes(old: "return user.name", new: "return user.fullName ?? \"\"")
        #expect((("return user.name" as NSString).substring(with: old[0])) == "name")
        #expect(new.count == 1 && (("return user.fullName ?? \"\"" as NSString).substring(with: new[0])) == "fullName ?? \"\"")
        let (o2, n2) = WordDiff.changes(old: "same", new: "same")
        #expect(o2.isEmpty && n2.isEmpty)
    }

    @Test func singleHunkPatchKeepsNoNewlineMarkers() {
        let file = UnifiedDiff.parse(modified)[0]
        let patch = UnifiedDiff.patch(for: file.hunks[1], in: file)
        #expect(patch.contains("@@ -10,1 +11,1 @@ func tail()\n-old tail\n\\ No newline at end of file\n+new tail\n\\ No newline at end of file\n"))
        #expect(!patch.contains("index "))
    }
}

@Suite struct GitDiffTests {
    @Test func stageOneHunkAndRevertAnother() throws {
        guard let git = GitRunner.locateGit() else { return }
        let root = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path)).appendingPathComponent("nt-diff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func sh(_ args: String...) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", root.path, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        let file = root.appendingPathComponent("a.txt")
        let original = (1...30).map { "line \($0)" }.joined(separator: "\n") // no final newline
        try original.write(to: file, atomically: true, encoding: .utf8)
        sh("init", "-q")
        sh("add", "-A")
        sh("commit", "-qm", "one")
        var lines = original.components(separatedBy: "\n")
        lines[1] = "line 2 changed"   // hunk 1, near the top
        lines[29] = "line 30 changed" // hunk 2, the last line (still no final newline)
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let diff = try #require(GitRunner.diff(of: "a.txt", in: root.path, git: git))
        #expect(diff.hunks.count == 2)
        // Stage only the first hunk.
        #expect(GitRunner.apply(UnifiedDiff.patch(for: diff.hunks[0], in: diff), in: root.path, git: git, cached: true, reverse: false))
        let staged = try #require(GitRunner.diff(of: "a.txt", in: root.path, git: git, base: .staged))
        #expect(staged.hunks.count == 1 && staged.hunks[0].lines.contains { $0.text == "line 2 changed" })
        // Revert the second hunk in the working tree.
        let unstaged = try #require(GitRunner.diff(of: "a.txt", in: root.path, git: git, base: .unstaged))
        #expect(unstaged.hunks.count == 1 && unstaged.hunks[0].newMissingNewline)
        #expect(GitRunner.apply(UnifiedDiff.patch(for: unstaged.hunks[0], in: unstaged), in: root.path, git: git, cached: false, reverse: true))
        let now = try String(contentsOf: file, encoding: .utf8)
        #expect(now.hasSuffix("line 30") && now.contains("line 2 changed"))
        // A patch that no longer fits changes nothing.
        #expect(!GitRunner.apply(UnifiedDiff.patch(for: unstaged.hunks[0], in: unstaged), in: root.path, git: git, cached: false, reverse: true))
        // An untracked file diffs against nothing.
        try "new\nfile\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let untracked = try #require(GitRunner.diff(of: "b.txt", in: root.path, git: git, untracked: true))
        #expect(untracked.isNew && untracked.hunks.first?.added == 2)
    }
}

@Suite struct GitIndexSafetyTests {
    /// Reading git state must never rewrite .git/index: while it holds index.lock, an agent's
    /// `git add` or `git commit` in the same repository fails.
    @Test func refreshAndDiffsLeaveTheIndexAlone() throws {
        guard let git = GitRunner.locateGit() else { return }
        let root = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path)).appendingPathComponent("nt-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func sh(_ args: String...) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", root.path, "-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        try "same\n".write(to: a, atomically: true, encoding: .utf8)
        try "one\n".write(to: b, atomically: true, encoding: .utf8)
        sh("init", "-q")
        sh("add", "-A")
        sh("commit", "-qm", "one")
        // Stat-dirty: same content, newer timestamp. This is what makes porcelain git refresh the index.
        Thread.sleep(forTimeInterval: 1.1)
        try "same\n".write(to: a, atomically: true, encoding: .utf8)
        try "two\n".write(to: b, atomically: true, encoding: .utf8)
        let index = root.appendingPathComponent(".git/index")
        let before = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        let bytes = try Data(contentsOf: index)

        let snapshot = try #require(GitRunner.snapshot(for: root.path, git: git))
        #expect(snapshot.files["b.txt"] == .modified)
        _ = GitRunner.diff(of: "b.txt", in: root.path, git: git, base: .head)
        _ = GitRunner.diff(of: "b.txt", in: root.path, git: git, base: .staged)
        _ = GitRunner.diff(of: "b.txt", in: root.path, git: git, base: .unstaged)
        _ = ProjectSearch.files(in: root.path, git: git)

        let after = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        #expect(before == after, "the index was rewritten")
        #expect(try Data(contentsOf: index) == bytes)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index.lock").path))
        #expect(snapshot.fileStats["b.txt"] == LineStats(added: 1, removed: 1, files: 1))
    }
}

@Suite struct CRLFDiffTests {
    @Test func crlfLinesStaySeparateAndKeepTheirCarriageReturn() {
        let diff = "diff --git a/w.bat b/w.bat\r\n".replacingOccurrences(of: "\r\n", with: "\n")
            + "--- a/w.bat\n+++ b/w.bat\n@@ -1,2 +1,2 @@\n echo one\r\n-echo two\r\n+echo 2\r\n"
        let file = UnifiedDiff.parse(diff)[0]
        #expect(file.hunks[0].lines.count == 3)
        #expect(file.hunks[0].lines[1] == DiffLine(kind: .removed, text: "echo two\r", oldNumber: 2, newNumber: nil))
        // The patch keeps the \r, so it applies to the CRLF file byte for byte.
        #expect(UnifiedDiff.patch(for: file.hunks[0], in: file).contains("-echo two\r\n+echo 2\r\n"))
    }
}

@Suite struct HunkOpsTests {
    func repo() throws -> (URL, String)? {
        guard let git = GitRunner.locateGit() else { return nil }
        let root = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.path)).appendingPathComponent("nt-hunk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for args in [["init", "-q"]] { run(git, root, args) }
        try (1...20).map { "line \($0)" }.joined(separator: "\n").appending("\n").write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        run(git, root, ["add", "-A"])
        run(git, root, ["-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-qm", "one"])
        return (root, git)
    }
    func run(_ git: String, _ root: URL, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-C", root.path] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
    func edit(_ root: URL, line: Int, to text: String) throws {
        let url = root.appendingPathComponent("a.txt")
        var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        lines[line - 1] = text
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func stageUnstageRevertWithChecks() throws {
        guard let (root, git) = try repo() else { return }
        defer { try? FileManager.default.removeItem(at: root) }
        try edit(root, line: 2, to: "two")
        try edit(root, line: 18, to: "eighteen")
        let unstaged = try #require(GitRunner.diff(of: "a.txt", in: root.path, git: git, base: .unstaged))
        #expect(unstaged.oldBlob?.count == 40 && unstaged.newBlob?.count == 40)
        #expect(HunkOps.perform(.stage, hunk: unstaged.hunks[0], in: unstaged, root: root.path, git: git) == .done)
        // The same diff is now stale for staging: the index moved on.
        #expect(HunkOps.perform(.stage, hunk: unstaged.hunks[1], in: unstaged, root: root.path, git: git) == .changedSinceDiff)
        let staged = try #require(GitRunner.diff(of: "a.txt", in: root.path, git: git, base: .staged))
        #expect(staged.hunks.count == 1)
        #expect(HunkOps.perform(.unstage, hunk: staged.hunks[0], in: staged, root: root.path, git: git) == .done)
        #expect(GitRunner.diff(of: "a.txt", in: root.path, git: git, base: .staged)?.hunks.isEmpty ?? true)
        // Revert one hunk in the working tree; a later edit makes the old diff stale.
        let fresh = try #require(GitRunner.diff(of: "a.txt", in: root.path, git: git, base: .unstaged))
        try edit(root, line: 10, to: "ten (an agent edited this meanwhile)")
        #expect(HunkOps.perform(.revert, hunk: fresh.hunks[0], in: fresh, root: root.path, git: git) == .changedSinceDiff)
        let current = try #require(GitRunner.diff(of: "a.txt", in: root.path, git: git, base: .unstaged))
        #expect(HunkOps.perform(.revert, hunk: current.hunks[0], in: current, root: root.path, git: git) == .done)
        let text = try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(text.contains("line 2\n") && text.contains("ten (an agent") && text.contains("eighteen"))
    }

    @Test func busyIndexIsReported() throws {
        guard let (root, git) = try repo() else { return }
        defer { try? FileManager.default.removeItem(at: root) }
        try edit(root, line: 5, to: "five")
        let diff = try #require(GitRunner.diff(of: "a.txt", in: root.path, git: git, base: .unstaged))
        let lock = root.appendingPathComponent(".git/index.lock")
        try Data().write(to: lock)
        #expect(HunkOps.perform(.stage, hunk: diff.hunks[0], in: diff, root: root.path, git: git) == .gitBusy)
        try FileManager.default.removeItem(at: lock)
        #expect(HunkOps.perform(.stage, hunk: diff.hunks[0], in: diff, root: root.path, git: git) == .done)
    }
}
