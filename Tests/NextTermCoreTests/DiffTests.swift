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
