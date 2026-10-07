import Darwin
import Foundation
import Testing
@testable import NextTermCore

/// The step engine on a home of its own, with a folder standing in for the Trash.
@Suite struct SkillChangesTests {
    let home: String
    let trash: String
    let engine: SkillChanges

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nt-changes-\(UUID().uuidString)").path
        home = root + "/home"
        trash = root + "/trash"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        engine = SkillChanges(undoFile: root + "/undo.json", trash: SkillChanges.folderTrash(trash))
    }

    func skill(_ path: String, body: String = "Body") throws -> String {
        let folder = (home as NSString).appendingPathComponent(path)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let name = (path as NSString).lastPathComponent
        try "---\nname: \(name)\ndescription: The \(name) skill.\n---\n\(body)\n".write(toFile: folder + "/SKILL.md", atomically: true, encoding: .utf8)
        return folder
    }

    func ok(_ result: Result<Void, SkillChanges.Failure>) -> Bool {
        if case .failure(let failure) = result { Issue.record("\(failure.message)"); return false }
        return true
    }

    func read(_ path: String) -> String? { try? String(contentsOfFile: (home as NSString).appendingPathComponent(path), encoding: .utf8) }

    /// A step that fails part-way: everything done before it is put back, and the message says so.
    @Test func aFailurePartWayPutsEverythingBack() throws {
        let claude = try skill(".claude/skills/notes", body: "claude")
        let shared = home + "/.agents/skills/notes"
        try FileManager.default.createDirectory(atPath: home + "/.agents/skills", withIntermediateDirectories: true)
        let failing = SkillChanges(undoFile: engine.undoFile) { path in
            if path.hasSuffix("/.codex/skills/notes") { throw SkillChanges.Failure(message: "the Trash refused") }
            return try SkillChanges.folderTrash(trash)(path)
        }
        _ = try skill(".codex/skills/notes", body: "codex")
        let result = failing.apply([.copy(from: claude, to: shared), .trash(claude), .link(at: claude, to: shared), .trash(home + "/.codex/skills/notes")],
                                   title: "Unify notes")
        guard case .failure(let failure) = result else { Issue.record("should fail"); return }
        #expect(failure.message.hasSuffix("Nothing was changed."))
        #expect(read(".claude/skills/notes/SKILL.md")?.contains("claude") == true && !SkillChanges.isLink(claude))
        #expect(!SkillChanges.exists(shared) && failing.lastChange == nil)
    }

    /// A kept copy that is read-only (so agents can't rewrite it) is refused before anything moves.
    @Test func aReadOnlyOrLockedCopyIsRefusedUpFront() throws {
        let kept = try skill(".claude/skills/house-style", body: "protected")
        let shared = try skill(".agents/skills/house-style", body: "the user's shared version")
        chmod(kept, 0o555)
        defer { chmod(kept, 0o755) }
        let staging = home + "/staging/house-style"
        let steps: [SkillStep] = [.copy(from: kept, to: staging), .trash(shared), .move(from: staging, to: shared)]
        guard case .failure(let failure) = engine.apply(steps, title: "Unify house-style") else { Issue.record("should refuse"); return }
        #expect(failure.message.contains("read-only") && failure.message.hasSuffix("Nothing was changed."))
        #expect(read(".agents/skills/house-style/SKILL.md")?.contains("the user's shared version") == true)
        #expect(!SkillChanges.exists(staging) && engine.lastChange == nil)

        chmod(kept, 0o755)
        let locked = kept + "/SKILL.md"
        chflags(locked, UInt32(UF_IMMUTABLE))
        defer { chflags(locked, 0) }
        guard case .failure(let lockFailure) = engine.apply(steps, title: "Unify house-style") else { Issue.record("should refuse"); return }
        #expect(lockFailure.message.contains("locked"))
    }

    /// An unreadable file would make the copy fail half-way: refused before copying.
    @Test func anUnreadableFileIsRefusedBeforeCopying() throws {
        let kept = try skill(".claude/skills/notes")
        try "secret".write(toFile: kept + "/private.md", atomically: true, encoding: .utf8)
        chmod(kept + "/private.md", 0o000)
        defer { chmod(kept + "/private.md", 0o644) }
        let result = engine.apply([.copy(from: kept, to: home + "/staging/notes")], title: "Unify notes")
        guard case .failure(let failure) = result else { Issue.record("should refuse"); return }
        #expect(failure.message.contains("can't be read") && !SkillChanges.exists(home + "/staging/notes"))
    }

    /// Unify through a staging copy, then Undo: every copy back, nothing left behind.
    @Test func undoPutsBackExactly() throws {
        let claude = try skill(".claude/skills/notes", body: "claude")
        let shared = try skill(".agents/skills/notes", body: "shared")
        let staging = home + "/staging/notes"
        try #require(ok(engine.apply([.copy(from: claude, to: staging), .trash(shared), .move(from: staging, to: shared),
                                   .trash(claude), .link(at: claude, to: shared)], title: "Unify notes")))
        #expect(read(".agents/skills/notes/SKILL.md")?.contains("claude") == true && SkillChanges.isLink(claude))
        try #require(ok(engine.undo()))
        #expect(read(".agents/skills/notes/SKILL.md")?.contains("shared") == true)
        #expect(read(".claude/skills/notes/SKILL.md")?.contains("claude") == true && !SkillChanges.isLink(claude))
        #expect(!SkillChanges.exists(staging) && engine.lastChange == nil)
    }

    /// Undo refuses, changing nothing, after an edit — also one only git's own files show.
    @Test func undoRefusesWhatChangedSinceEvenInGitData() throws {
        let claude = try skill(".claude/skills/notes", body: "claude")
        try FileManager.default.createDirectory(atPath: claude + "/.git/refs", withIntermediateDirectories: true)
        let shared = home + "/.agents/skills/notes"
        try #require(ok(engine.apply([.copy(from: claude, to: shared)], title: "Copy notes")))
        try "wip".write(toFile: shared + "/.git/refs/stash", atomically: true, encoding: .utf8)
        guard case .failure(let failure) = engine.undo() else { Issue.record("should refuse"); return }
        #expect(failure.message.contains("changed since"))
        #expect(SkillChanges.exists(shared + "/.git/refs/stash"))
    }

    /// Undo moves what a change made to the Trash (never deletes it), so a missed file stays recoverable.
    @Test func undoMovesMadeThingsToTheTrash() throws {
        let claude = try skill(".claude/skills/notes")
        let shared = home + "/.agents/skills/notes"
        try #require(ok(engine.apply([.copy(from: claude, to: shared)], title: "Copy notes")))
        try #require(ok(engine.undo()))
        #expect(!SkillChanges.exists(shared))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: trash)) ?? []).contains { $0.hasSuffix("-notes") })
    }

    /// When putting back fails too, what is left stays recorded and a later Undo finishes the job.
    @Test func aFailedRollbackIsKeptForUndo() throws {
        let claude = try skill(".claude/skills/notes", body: "claude")
        let shared = try skill(".agents/skills/notes", body: "shared")
        var refuse = true
        let flaky = SkillChanges(undoFile: engine.undoFile) { path in
            // The second step's trash fails; so does the rollback's first put-away.
            if refuse, path.hasSuffix("/.claude/skills/notes") || path.contains("staging") { throw SkillChanges.Failure(message: "busy") }
            return try SkillChanges.folderTrash(trash)(path)
        }
        let staging = home + "/staging/notes"
        let result = flaky.apply([.copy(from: claude, to: staging), .trash(shared), .move(from: staging, to: shared), .trash(claude)], title: "Unify notes")
        guard case .failure(let failure) = result else { Issue.record("should fail"); return }
        #expect(failure.message.contains("could not put back") && !failure.message.contains("Nothing was changed"))
        #expect(flaky.lastChange != nil)
        refuse = false
        try #require(ok(flaky.undo()))
        #expect(read(".agents/skills/notes/SKILL.md")?.contains("shared") == true)
        #expect(read(".claude/skills/notes/SKILL.md")?.contains("claude") == true)
    }

    /// The lock file is edited one entry at a time, read when the step runs: an entry `npx skills`
    /// added meanwhile survives, and Undo puts back only this entry.
    @Test func lockEntriesAreEditedOneAtATime() throws {
        let lock = home + "/.agents/.skill-lock.json"
        try FileManager.default.createDirectory(atPath: home + "/.agents", withIntermediateDirectories: true)
        try #"{"version": 3, "skills": {"old-skill": {"source": "a/b", "skillPath": "SKILL.md"}}}"#.write(toFile: lock, atomically: true, encoding: .utf8)
        let steps: [SkillStep] = [.lockEntry(path: lock, name: "old-skill", entry: nil)]
        // Planned; then `npx skills add` writes another entry before the user confirms.
        let added = try SkillLock.updated(try String(contentsOfFile: lock, encoding: .utf8), name: "new-skill",
                                          entry: .init(source: "c/d", sourceUrl: "u", skillPath: "SKILL.md", skillFolderHash: "h", installedAt: Date(), updatedAt: Date())).get()
        try added.write(toFile: lock, atomically: true, encoding: .utf8)
        try #require(ok(engine.apply(steps, title: "Remove old-skill")))
        let after = try #require(try? SkillLock.entries(at: lock).get())
        #expect(Set(after.keys) == ["new-skill"])
        try #require(ok(engine.undo()))
        #expect(Set(try #require(try? SkillLock.entries(at: lock).get()).keys) == ["new-skill", "old-skill"])
    }

    /// A lock file kept in a dotfiles folder (a link) is written through the link, which stays.
    @Test func aLinkedLockFileStaysALink() throws {
        try FileManager.default.createDirectory(atPath: home + "/dotfiles", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.agents", withIntermediateDirectories: true)
        try #"{"version": 3, "skills": {}}"#.write(toFile: home + "/dotfiles/skill-lock.json", atomically: true, encoding: .utf8)
        let lock = home + "/.agents/.skill-lock.json"
        try FileManager.default.createSymbolicLink(atPath: lock, withDestinationPath: "../dotfiles/skill-lock.json")
        let entry = SkillLock.Entry(source: "a/b", sourceUrl: "u", skillPath: "SKILL.md", skillFolderHash: "h", installedAt: Date(), updatedAt: Date())
        try #require(ok(engine.apply([.lockEntry(path: lock, name: "x", entry: entry)], title: "Install x")))
        #expect(SkillChanges.isLink(lock))
        #expect((try? SkillLock.entries(at: home + "/dotfiles/skill-lock.json").get())?["x"] != nil)
    }

    /// ~/.claude linked into a dotfiles folder: a link made in it is relative from where it really is.
    @Test func linksWorkWhenTheAgentFolderIsItselfALink() throws {
        try FileManager.default.createDirectory(atPath: home + "/dotfiles/claude/skills", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/.claude", withDestinationPath: "dotfiles/claude")
        let shared = try skill(".agents/skills/notes")
        let at = home + "/.claude/skills/notes"
        try #require(ok(engine.apply([.link(at: at, to: shared)], title: "Link notes")))
        #expect(FileManager.default.fileExists(atPath: at + "/SKILL.md"))
    }

    /// A link that would not reach a skill is refused, and nothing stays behind.
    @Test func aLinkThatReachesNothingIsUndone() throws {
        try FileManager.default.createDirectory(atPath: home + "/.claude/skills", withIntermediateDirectories: true)
        let result = engine.apply([.link(at: home + "/.claude/skills/ghost", to: home + "/.agents/skills/ghost")], title: "Link ghost")
        guard case .failure = result else { Issue.record("should fail"); return }
        #expect(!SkillChanges.exists(home + "/.claude/skills/ghost"))
    }

    @Test func recordsAreEditedOneAtATime() throws {
        let file = home + "/skills.json"
        let a = SkillRecord(name: "a", owner: "o", repo: "r", path: "", ref: nil, commit: "c", tree: "t", contentHash: "t", installedAt: Date(timeIntervalSince1970: 0), linkedForClaude: false)
        let b = SkillRecord(name: "b", owner: "o", repo: "r", path: "", ref: nil, commit: "c", tree: "t", contentHash: "t", installedAt: Date(timeIntervalSince1970: 0), linkedForClaude: false)
        try SkillRecord.encodeList([a]).write(to: URL(fileURLWithPath: file))
        try #require(ok(engine.apply([.recordEntry(path: file, name: "b", record: b)], title: "Install b")))
        #expect(SkillRecord.decodeList(FileManager.default.contents(atPath: file)).map(\.name) == ["a", "b"])
        try #require(ok(engine.undo()))
        #expect(SkillRecord.decodeList(FileManager.default.contents(atPath: file)).map(\.name) == ["a"])
    }
}
