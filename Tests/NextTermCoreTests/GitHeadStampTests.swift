import Foundation
import Testing
@testable import NextTermCore

@Suite struct GitHeadStampTests {
    let sha = "1234567890abcdef1234567890abcdef12345678"

    /// A repository as git leaves it on disk, made by hand (no git run): .git/HEAD on a branch, its loose ref,
    /// and a file two folders down.
    func repository() throws -> (root: String, file: String) {
        let fm = FileManager.default
        let root = canonicalPath(fm.temporaryDirectory.path) + "/nt-headstamp-" + String(UUID().uuidString.prefix(8))
        try fm.createDirectory(atPath: root + "/.git/refs/heads", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/src/app", withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(toFile: root + "/.git/HEAD", atomically: true, encoding: .utf8)
        try (sha + "\n").write(toFile: root + "/.git/refs/heads/main", atomically: true, encoding: .utf8)
        try "let x = 1\n".write(toFile: root + "/src/app/main.swift", atomically: true, encoding: .utf8)
        return (root, root + "/src/app/main.swift")
    }

    @Test func watchesHeadTheCheckedOutBranchAndPackedRefs() {
        let files = GitHeadStamp.watchedFiles(gitDir: "/r/.git", commonDir: "/r/.git", head: "ref: refs/heads/feature/x\n")
        #expect(files == ["/r/.git/HEAD", "/r/.git/refs/heads/feature/x", "/r/.git/packed-refs", "/r/.git/reftable/tables.list"])
        // Detached: HEAD names the commit itself.
        #expect(GitHeadStamp.watchedFiles(gitDir: "/r/.git", commonDir: "/r/.git", head: sha + "\n")
            == ["/r/.git/HEAD", "/r/.git/packed-refs", "/r/.git/reftable/tables.list"])
        // A linked worktree: its own HEAD, the shared refs.
        #expect(GitHeadStamp.watchedFiles(gitDir: "/r/.git/worktrees/w", commonDir: "/r/.git", head: "ref: refs/heads/w\n")
            == ["/r/.git/worktrees/w/HEAD", "/r/.git/refs/heads/w", "/r/.git/packed-refs", "/r/.git/reftable/tables.list"])
    }

    @Test func sameWhileNothingMovesDifferentOnceTheBranchDoes() throws {
        let (root, file) = try repository()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let first = try #require(GitHeadStamp(file: file))
        #expect(GitHeadStamp(file: file) == first)
        // The working file and the index changing say nothing about the last commit.
        try "let x = 2\n".write(toFile: file, atomically: true, encoding: .utf8)
        try "index".write(toFile: root + "/.git/index", atomically: true, encoding: .utf8)
        #expect(GitHeadStamp(file: file) == first)
        // A commit moves the branch.
        try "abcdefabcdefabcdefabcdefabcdefabcdefabcd\n".write(toFile: root + "/.git/refs/heads/main", atomically: true, encoding: .utf8)
        let committed = try #require(GitHeadStamp(file: file))
        #expect(committed != first)
        // A checkout rewrites HEAD.
        try "ref: refs/heads/other\n".write(toFile: root + "/.git/HEAD", atomically: true, encoding: .utf8)
        #expect(GitHeadStamp(file: file) != committed)
    }

    @Test func packingTheRefsCounts() throws {
        let (root, file) = try repository()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let first = try #require(GitHeadStamp(file: file))
        try FileManager.default.removeItem(atPath: root + "/.git/refs/heads/main")
        try "# pack-refs\n\(sha) refs/heads/main\n".write(toFile: root + "/.git/packed-refs", atomically: true, encoding: .utf8)
        #expect(GitHeadStamp(file: file) != first)
    }

    @Test func aLinkedWorktreeFollowsItsGitFile() throws {
        let (root, _) = try repository()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/.git/worktrees/w", withIntermediateDirectories: true)
        try "ref: refs/heads/w\n".write(toFile: root + "/.git/worktrees/w/HEAD", atomically: true, encoding: .utf8)
        try "../..\n".write(toFile: root + "/.git/worktrees/w/commondir", atomically: true, encoding: .utf8)
        let tree = root + "/wt"
        try fm.createDirectory(atPath: tree, withIntermediateDirectories: true)
        try "gitdir: \(root)/.git/worktrees/w\n".write(toFile: tree + "/.git", atomically: true, encoding: .utf8)
        try "".write(toFile: tree + "/a.txt", atomically: true, encoding: .utf8)
        let first = try #require(GitHeadStamp(file: tree + "/a.txt"))
        try (sha + "\n").write(toFile: root + "/.git/refs/heads/w", atomically: true, encoding: .utf8)
        #expect(GitHeadStamp(file: tree + "/a.txt") != first)
    }

    @Test func outsideARepositoryThereIsNone() throws {
        let fm = FileManager.default
        let folder = canonicalPath(fm.temporaryDirectory.path) + "/nt-headstamp-none-" + String(UUID().uuidString.prefix(8))
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: folder) }
        try "".write(toFile: folder + "/a.txt", atomically: true, encoding: .utf8)
        #expect(GitHeadStamp(file: folder + "/a.txt") == nil)
    }

    @Test func anotherFileInTheSameRepositoryIsAnotherStamp() throws {
        let (root, file) = try repository()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "".write(toFile: root + "/README.md", atomically: true, encoding: .utf8)
        #expect(GitHeadStamp(file: file) != GitHeadStamp(file: root + "/README.md"))
    }
}
