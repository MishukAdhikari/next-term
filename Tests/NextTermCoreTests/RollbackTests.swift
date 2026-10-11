import Foundation
import Testing
@testable import NextTermCore

/// Git › Rollback…: the plan for each kind of change, read from git's own status of a real repository and from the disk,
/// the refusals when something is in the way, the question it asks, the commands, and Undo putting the index and the
/// files back exactly, what was staged staged again.
struct RollbackTests {
    /// A repository with one file in each state: changed, changed and staged, deleted, deleted in the index, new and
    /// untracked, new in the index, new and changed again after staging, marked with `git add -N`, renamed in the index,
    /// in a folder, a literal name with brackets, and a new folder.
    static func states() -> ScratchRepo? {
        guard let repo = ScratchRepo() else { return nil }
        let files = ["changed.txt", "staged.txt", "deleted.txt", "removed.txt", "old.txt", "lib/inner.txt", "[id].tsx"]
        try? FileManager.default.createDirectory(atPath: repo.work + "/lib", withIntermediateDirectories: true)
        for name in files { write(repo, "\(name) one\n", name) }
        repo.sh(["add", "-A"])
        repo.sh(["commit", "-q", "-m", "start"])
        write(repo, "changed two\n", "changed.txt")
        write(repo, "staged two\n", "staged.txt")
        repo.sh(["add", "staged.txt"])
        write(repo, "staged three\n", "staged.txt")
        try? FileManager.default.removeItem(atPath: repo.work + "/deleted.txt")
        repo.sh(["rm", "-q", "removed.txt"])
        write(repo, "untracked\n", "untracked.txt")
        write(repo, "added\n", "added.txt")
        repo.sh(["add", "added.txt"])
        write(repo, "again one\n", "again.txt")
        repo.sh(["add", "again.txt"])
        write(repo, "again two\n", "again.txt")
        write(repo, "intent\n", "intent.txt")
        repo.sh(["add", "-N", "intent.txt"])
        repo.sh(["mv", "old.txt", "renamed.txt"])
        write(repo, "inner two\n", "lib/inner.txt")
        write(repo, "brackets two\n", "[id].tsx")
        try? FileManager.default.createDirectory(atPath: repo.work + "/fresh/deep", withIntermediateDirectories: true)
        write(repo, "fresh\n", "fresh/deep/a.txt")
        return repo
    }

    static func write(_ repo: ScratchRepo, _ text: String, _ name: String) {
        try? text.write(toFile: repo.work + "/" + name, atomically: true, encoding: .utf8)
    }

    static func snapshot(_ repo: ScratchRepo) throws -> GitSnapshot {
        try #require(GitRunner.snapshot(for: repo.work, git: repo.git))
    }

    static func plan(_ paths: [String], _ repo: ScratchRepo, _ snapshot: GitSnapshot) -> Result<Rollback.Plan, Rollback.Refusal> {
        Rollback.plan(paths, in: snapshot) { Rollback.diskKind($0, root: repo.work) }
    }

    @Test func eachKindOfChangeGetsItsOwnStep() throws {
        guard let repo = Self.states() else { return }
        defer { repo.remove() }
        let snapshot = try Self.snapshot(repo)
        func steps(_ path: String) -> [Rollback.Step]? { try? Self.plan([path], repo, snapshot).get().steps }
        #expect(steps("changed.txt") == [.restore("changed.txt")])
        #expect(steps("staged.txt") == [.restore("staged.txt")])
        #expect(steps("deleted.txt") == [.restore("deleted.txt")])
        #expect(steps("removed.txt") == [.restore("removed.txt")])
        #expect(steps("untracked.txt") == [.remove("untracked.txt", staged: false)])
        #expect(steps("added.txt") == [.remove("added.txt", staged: true)])
        #expect(steps("again.txt") == [.remove("again.txt", staged: true)])
        // `git add -N` reads as changed to the sidebar, but HEAD has nothing to restore it from.
        #expect(steps("intent.txt") == [.remove("intent.txt", staged: true)])
        #expect(steps("renamed.txt") == [.remove("renamed.txt", staged: true), .restore("old.txt")])
        // A folder takes every changed path under it; a new folder goes to the Trash whole, a file in one alone.
        #expect(steps("lib") == [.restore("lib/inner.txt")])
        #expect(steps("fresh") == [.remove("fresh", staged: false)])
        #expect(steps("fresh/deep/a.txt") == [.remove("fresh/deep/a.txt", staged: false)])
        let both = try Self.plan(["untracked.txt", "changed.txt"], repo, snapshot).get()
        #expect(both.steps == [.remove("untracked.txt", staged: false), .restore("changed.txt")])
        // A rename is one file, by its new name.
        #expect(try Self.plan(["renamed.txt"], repo, snapshot).get().files == ["renamed.txt"])
        // Nothing there, a conflict and a submodule are refused.
        #expect(Self.plan(["lib/missing.txt"], repo, snapshot) == .failure(.unchanged("lib/missing.txt")))
        var conflicted = snapshot
        conflicted.files["changed.txt"] = .conflicted
        conflicted.codes["changed.txt"] = "UU"
        #expect(Self.plan(["changed.txt"], repo, conflicted) == .failure(.conflicted("changed.txt")))
        var submodule = snapshot
        submodule.submodules = ["changed.txt"]
        #expect(Self.plan(["changed.txt"], repo, submodule) == .failure(.submodule("changed.txt")))
    }

    /// What a checkout would delete or overwrite is never in its way: refused, or to the Trash first when it is a new file.
    @Test func nothingInTheWayIsLost() throws {
        guard let repo = ScratchRepo() else { return }
        defer { repo.remove() }
        try FileManager.default.createDirectory(atPath: repo.work + "/dir", withIntermediateDirectories: true)
        for name in ["dir/a.txt", "foo", "old.txt"] { Self.write(repo, "one\n", name) }
        repo.sh(["add", "-A"])
        repo.sh(["commit", "-q", "-m", "start"])
        // A file where a deleted folder was: the folder's file can't come back through it.
        try FileManager.default.removeItem(atPath: repo.work + "/dir")
        Self.write(repo, "precious\n", "dir")
        // A folder where a deleted file was.
        try FileManager.default.removeItem(atPath: repo.work + "/foo")
        try FileManager.default.createDirectory(atPath: repo.work + "/foo", withIntermediateDirectories: true)
        Self.write(repo, "work\n", "foo/work.txt")
        // A rename whose old name a new file took again.
        repo.sh(["mv", "old.txt", "new.txt"])
        Self.write(repo, "new work\n", "old.txt")
        let snapshot = try Self.snapshot(repo)
        #expect(Self.plan(["dir/a.txt"], repo, snapshot) == .failure(.blocked("dir/a.txt", by: "dir")))
        #expect(Self.plan(["foo"], repo, snapshot) == .failure(.blocked("foo", by: "foo")))
        #expect(try Self.plan(["new.txt"], repo, snapshot).get().steps
                == [.remove("new.txt", staged: true), .remove("old.txt", staged: false), .restore("old.txt")])
        #expect(Rollback.refusal(.blocked("dir/a.txt", by: "dir")).info == "“dir” is a file where a folder has to be. Move it out of the way, then roll back again.")
    }

    @Test func theQuestionNamesWhatItDoes() {
        let one = Rollback.Plan(steps: [.restore("src/main.swift")], files: ["src/main.swift"])
        #expect(Rollback.question(one, named: ["src/main.swift"], root: "/r/app")
                == ("Roll back “main.swift”?", "It goes back to the last commit.\n\nUndo, on the notice after, puts everything back."))
        let new = Rollback.Plan(steps: [.remove("notes.md", staged: false)], files: ["notes.md"])
        #expect(Rollback.question(new, named: ["notes.md"], root: "/r/app").info.hasPrefix("It isn’t in the last commit, so it goes to the Trash."))
        let folder = Rollback.Plan(steps: [.remove("src/b.swift", staged: true), .restore("src/a.swift")], files: ["src/a.swift", "src/b.swift"])
        let asked = Rollback.question(folder, named: ["src"], root: "/r/app")
        #expect(asked.title == "Roll back 2 files in “src”?")
        #expect(asked.info == "src/a.swift\nsrc/b.swift\n\nThey go back to the last commit; the 1 new one goes to the Trash.\n\nUndo, on the notice after, puts everything back.")
        #expect(Rollback.question(folder, named: [""], root: "/r/app").title == "Roll back all 2 changed files in “app”?")
        #expect(Rollback.question(folder, named: ["src/a.swift", "src/b.swift"], root: "/r/app").title == "Roll back 2 files?")
    }

    @Test func theCommandsTakeTheirPathsLiterally() {
        let steps: [Rollback.Step] = [.remove("new.txt", staged: true), .remove("loose.txt", staged: false), .restore("[id].tsx")]
        let commands = Rollback.commands(steps)
        #expect(commands.unstage == [["--literal-pathspecs", "rm", "--cached", "--force", "--quiet", "--ignore-unmatch", "--", "new.txt"]])
        #expect(commands.restore == [["--literal-pathspecs", "checkout", "HEAD", "--", "[id].tsx"]])
        #expect(Rollback.trashed(steps) == ["new.txt", "loose.txt"])
        #expect(Rollback.restoredPaths(steps) == ["[id].tsx"])
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
        let plan = try Self.plan(["changed.txt", "staged.txt", "deleted.txt", "removed.txt", "untracked.txt", "added.txt", "again.txt",
                                  "intent.txt", "renamed.txt", "lib", "[id].tsx", "fresh"], repo, snapshot).get()
        let steps = plan.steps, touched = Rollback.touched(steps)

        // What Undo keeps: the index entries, copies of what comes back from HEAD, and what went to the "Trash".
        let entries = Rollback.indexEntries(repo.sh(Rollback.indexEntriesCommand(touched)))
        let intent = Rollback.intentToAdd(touched, in: snapshot)
        #expect(intent == ["intent.txt"])
        var saved: [String: Data] = [:]
        for path in Rollback.restoredPaths(steps) { saved[path] = FileManager.default.contents(atPath: repo.work + "/" + path) }
        let trash = repo.work + ".trash"
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: trash) }

        // As the app does it: the Trash first, before git changes anything, then the index, then HEAD's files back.
        for (index, path) in Rollback.trashed(steps).enumerated() where FileManager.default.fileExists(atPath: repo.work + "/" + path) {
            try FileManager.default.moveItem(atPath: repo.work + "/" + path, toPath: trash + "/\(index)")
        }
        let commands = Rollback.commands(steps)
        for command in commands.unstage { repo.sh(command) }
        for command in commands.restore { repo.sh(command) }
        #expect(repo.sh(["status", "--porcelain=v1", "--untracked-files=all"]).isEmpty, "\(repo.sh(["status", "--short"]))")

        // Undo: the files first (out of the Trash, then the copies), then the index.
        for (index, path) in Rollback.trashed(steps).enumerated() where FileManager.default.fileExists(atPath: trash + "/\(index)") {
            try FileManager.default.moveItem(atPath: trash + "/\(index)", toPath: repo.work + "/" + path)
        }
        for path in Rollback.restoredPaths(steps) {
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
