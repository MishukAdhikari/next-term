import Foundation
import Testing
@testable import NextTermCore

@Suite struct LineChangesTests {
    func marks(_ old: String, _ new: String) throws -> LineChanges.Marks {
        let git = try #require(GitRunner.locateGit())
        let diff = try #require(GitRunner.diff(old: old, new: new, git: git, context: 0))
        return LineChanges.marks(from: diff)
    }

    @Test func addedChangedAndDeleted() throws {
        let old = "a\nb\nc\nd\ne\n"
        // b changed, a line added after c, e deleted.
        let result = try marks(old, "a\nB\nc\nnew\nd\n")
        #expect(result.lines == [1: .modified, 3: .added])
        #expect(result.deletedBefore == [5]) // e was the last line: the mark sits at the end
    }

    @Test func aChangeThatGrows() throws {
        let result = try marks("a\nb\nc\n", "a\nB1\nB2\nB3\nc\n")
        #expect(result.lines == [1: .modified, 2: .added, 3: .added])
        #expect(result.deletedBefore.isEmpty)
    }

    @Test func deletionsAtTheTopAndInTheMiddle() throws {
        let result = try marks("x\na\nb\ny\nc\n", "a\nb\nc\n")
        #expect(result.lines.isEmpty)
        #expect(result.deletedBefore == [0, 2])
    }

    @Test func unchangedHasNoMarks() throws {
        #expect(try marks("same\n", "same\n").isEmpty)
    }

    @Test func headTextOfACommittedFile() throws {
        let git = try #require(GitRunner.locateGit())
        let repo = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-head-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try FileManager.default.createDirectory(atPath: repo + "/src", withIntermediateDirectories: true)
        try "one\n".write(toFile: repo + "/src/a.txt", atomically: true, encoding: .utf8)
        for args in [["init", "-q"], ["add", "."], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", repo] + args
            try p.run(); p.waitUntilExit()
        }
        try "two\n".write(toFile: repo + "/src/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: repo + "/src/b.txt", atomically: true, encoding: .utf8)
        #expect(GitRunner.headText(of: repo + "/src/a.txt", git: git) == "one\n")
        #expect(GitRunner.headText(of: repo + "/src/b.txt", git: git) == nil) // not committed
        #expect(GitRunner.headText(of: "/tmp/not-a-repo-\(UUID().uuidString)/x.txt", git: git) == nil)
    }
}
