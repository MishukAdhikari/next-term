import Foundation
import Testing
@testable import NextTermCore

/// Git › Rollback…: the steps for each kind of change, read from git's own status of a real repository, the commands
/// they run, and Undo putting the index and the files back exactly, what was staged staged again.
struct RollbackTests {
    /// A repository with one file in each state: changed, changed and staged, deleted, deleted in the index, new and
    /// untracked, new in the index, marked with `git add -N`, renamed in the index, and in a folder.
    static func states() -> ScratchRepo? {
        guard let repo = ScratchRepo() else { return nil }
        let files = ["changed.txt", "staged.txt", "deleted.txt", "removed.txt", "old.txt", "lib/inner.txt", "[id].tsx"]
        try? FileManager.default.createDirectory(atPath: repo.work + "/lib", withIntermediateDirectories: true)
        for name in files { try? "\(name) one\n".write(toFile: repo.work + "/" + name, atomically: true, encoding: .utf8) }
        repo.sh(["add", "-A"])
        repo.sh(["commit", "-q", "-m", "start"])
        try? "changed two\n".write(toFile: repo.work + "/changed.txt", atomically: true, encoding: .utf8)
        try? "staged two\n".write(toFile: repo.work + "/staged.txt", atomically: true, encoding: .utf8)
        repo.sh(["add", "staged.txt"])
        try? "staged three\n".write(toFile: repo.work + "/staged.txt", atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: repo.work + "/deleted.txt")
        repo.sh(["rm", "-q", "removed.txt"])
        try? "untracked\n".write(toFile: repo.work + "/untracked.txt", atomically: true, encoding: .utf8)
        try? "added\n".write(toFile: repo.work + "/added.txt", atomically: true, encoding: .utf8)
        repo.sh(["add", "added.txt"])
        try? "intent\n".write(toFile: repo.work + "/intent.txt", atomically: true, encoding: .utf8)
        repo.sh(["add", "-N", "intent.txt"])
        repo.sh(["mv", "old.txt", "renamed.txt"])
        try? "inner two\n".write(toFile: repo.work + "/lib/inner.txt", atomically: true, encoding: .utf8)
        try? "brackets two\n".write(toFile: repo.work + "/[id].tsx", atomically: true, encoding: .utf8)
        return repo
    }

    static func snapshot(_ repo: ScratchRepo) throws -> GitSnapshot {
        try #require(GitRunner.snapshot(for: repo.work, git: repo.git))
    }

    @Test func eachKindOfChangeGetsItsOwnStep() throws {
        guard let repo = Self.states() else { return }
        defer { repo.remove() }
        let snapshot = try Self.snapshot(repo)
        func steps(_ path: String) -> [Rollback.Step]? { try? Rollback.plan([path], in: snapshot).get() }
        #expect(steps("changed.txt") == [.restore("changed.txt")])
        #expect(steps("staged.txt") == [.restore("staged.txt")])
        #expect(steps("deleted.txt") == [.restore("deleted.txt")])
        #expect(steps("removed.txt") == [.restore("removed.txt")])
        #expect(steps("untracked.txt") == [.remove("untracked.txt", staged: false)])
        #expect(steps("added.txt") == [.remove("added.txt", staged: true)])
        // `git add -N` reads as changed to the sidebar, but HEAD has nothing to restore it from.
        #expect(steps("intent.txt") == [.remove("intent.txt", staged: true)])
        #expect(steps("renamed.txt") == [.remove("renamed.txt", staged: true), .restore("old.txt")])
        // A folder takes every changed path under it; the Trash goes first.
        #expect(steps("lib") == [.restore("lib/inner.txt")])
        #expect(try Rollback.plan(["untracked.txt", "changed.txt"], in: snapshot).get()
                == [.remove("untracked.txt", staged: false), .restore("changed.txt")])
        // Nothing to roll back, and a conflict, are refused.
        #expect(Rollback.plan(["lib/missing.txt"], in: snapshot) == .failure(.unchanged("lib/missing.txt")))
        var conflicted = snapshot
        conflicted.files["changed.txt"] = .conflicted
        conflicted.codes["changed.txt"] = "UU"
        #expect(Rollback.plan(["changed.txt"], in: conflicted) == .failure(.conflicted("changed.txt")))
    }

    @Test func theCommandsTakeTheirPathsLiterally() {
        let steps: [Rollback.Step] = [.remove("new.txt", staged: true), .remove("loose.txt", staged: false), .restore("[id].tsx")]
        let commands = Rollback.commands(steps)
        #expect(commands.unstage == [["--literal-pathspecs", "rm", "--cached", "--quiet", "--ignore-unmatch", "--", "new.txt"]])
        #expect(commands.restore == [["--literal-pathspecs", "checkout", "HEAD", "--", "[id].tsx"]])
        #expect(Rollback.trashed(steps) == ["new.txt", "loose.txt"])
        #expect(Rollback.done(["src/[id].tsx"]) == "Rolled back [id].tsx")
        #expect(Rollback.done(["a", "b", "c"]) == "Rolled back 3 files")
    }

    /// The whole round trip on the real repository: the rollback leaves nothing uncommitted, and Undo puts the
    /// status and every staged and unstaged byte back as they were.
    @Test func rollbackAndUndoRoundTrip() throws {
        guard let repo = Self.states() else { return }
        defer { repo.remove() }
        let before = repo.sh(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        let stagedBefore = repo.sh(["diff", "--cached", "--binary"])
        let unstagedBefore = repo.sh(["diff", "--binary"])
        let snapshot = try Self.snapshot(repo)
        let steps = try Rollback.plan(["changed.txt", "staged.txt", "deleted.txt", "removed.txt", "untracked.txt", "added.txt",
                                       "intent.txt", "renamed.txt", "lib", "[id].tsx"], in: snapshot).get()
        let touched = Rollback.touched(steps)

        // What Undo keeps: the index entries and the files as they are.
        let entries = Rollback.indexEntries(repo.sh(Rollback.indexEntriesCommand(touched)))
        let intent = Rollback.intentToAdd(touched, in: snapshot)
        #expect(intent == ["intent.txt"])
        var saved: [String: Data] = [:]
        for path in touched { saved[path] = FileManager.default.contents(atPath: repo.work + "/" + path) }

        let commands = Rollback.commands(steps)
        for command in commands.unstage { repo.sh(command) }
        for path in Rollback.trashed(steps) { try? FileManager.default.removeItem(atPath: repo.work + "/" + path) } // the app trashes these
        for command in commands.restore { repo.sh(command) }
        #expect(repo.sh(["status", "--porcelain=v1", "--untracked-files=all"]).isEmpty, "\(repo.sh(["status", "--short"]))")

        // Undo: the files first, then the index.
        for path in touched {
            let url = URL(fileURLWithPath: repo.work + "/" + path)
            if let data = saved[path] { try data.write(to: url) } else { try? FileManager.default.removeItem(at: url) }
        }
        for command in Rollback.undoIndexCommands(touched, before: entries, intentToAdd: intent) { repo.sh(command) }
        #expect(repo.sh(["status", "--porcelain=v1", "-z", "--untracked-files=all"]) == before)
        #expect(repo.sh(["diff", "--cached", "--binary"]) == stagedBefore)
        #expect(repo.sh(["diff", "--binary"]) == unstagedBefore)
    }

    @Test func indexEntriesAreReadFromLsFiles() {
        let output = "100644 aaaa1111 0\tsrc/a.swift\0" + "100755 bbbb2222 0\tbin/run\0" + "100644 cccc3333 2\tconflict.txt\0"
        let entries = Rollback.indexEntries(output)
        #expect(entries == ["src/a.swift": .init(mode: "100644", sha: "aaaa1111"), "bin/run": .init(mode: "100755", sha: "bbbb2222")])
        #expect(Rollback.undoIndexCommands(["src/a.swift", "gone.txt"], before: entries)
                == [["update-index", "--add", "--cacheinfo", "100644,aaaa1111,src/a.swift"], ["update-index", "--force-remove", "--", "gone.txt"]])
    }
}
