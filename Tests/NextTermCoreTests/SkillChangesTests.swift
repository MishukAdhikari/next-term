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
        let trashFolder = trash
        let flaky = SkillChanges(undoFile: engine.undoFile) { path in
            // The last step fails, and the Trash has just turned read-only, so the shared copy can't
            // come back out of it either.
            if path.hasSuffix("/.claude/skills/notes") {
                chmod(trashFolder, 0o555)
                throw SkillChanges.Failure(message: "busy")
            }
            return try SkillChanges.folderTrash(trashFolder)(path)
        }
        defer { chmod(trashFolder, 0o755) }
        let staging = home + "/staging/notes"
        let result = flaky.apply([.copy(from: claude, to: staging), .trash(shared), .move(from: staging, to: shared), .trash(claude)], title: "Unify notes")
        guard case .failure(let failure) = result else { Issue.record("should fail"); return }
        #expect(failure.message.contains("could not put back") && !failure.message.contains("Nothing was changed"))
        #expect(flaky.lastChange != nil)
        chmod(trashFolder, 0o755)
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

/// Cases from the second verification round, each reproduced first.
@Suite struct SkillChangesRoundTwoTests {
    let home: String
    let trash: String
    let engine: SkillChanges

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nt-changes2-\(UUID().uuidString)").path
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

    func succeeded(_ result: Result<Void, SkillChanges.Failure>) -> Bool {
        if case .failure(let failure) = result { Issue.record("\(failure.message)"); return false }
        return true
    }

    /// A later change that fails and rolls back cleanly must not erase the earlier change's Undo.
    @Test func aCleanRollbackKeepsTheEarlierUndo() throws {
        let first = try skill(".agents/skills/first")
        try #require(succeeded(engine.apply([.trash(first)], title: "Remove first")))
        let second = try skill(".claude/skills/second")
        let trashFolder = trash
        let failing = SkillChanges(undoFile: engine.undoFile) { path in
            // Only the step itself fails; putting back what was done works.
            if path.hasSuffix("/.claude/skills/second") { throw SkillChanges.Failure(message: "the Trash refused") }
            return try SkillChanges.folderTrash(trashFolder)(path)
        }
        guard case .failure(let failure) = failing.apply([.copy(from: second, to: home + "/.agents/skills/second"), .trash(second)], title: "Unify second") else {
            Issue.record("should fail"); return
        }
        #expect(failure.message.hasSuffix("Nothing was changed."))
        #expect(engine.lastChange?.title == "Remove first")
        try #require(succeeded(engine.undo()))
        #expect(FileManager.default.fileExists(atPath: first + "/SKILL.md"))
    }

    /// A shared entry that links to the developer's own folder: Claude's link goes to the shared entry,
    /// not through it, so Remove still finds and removes it.
    @Test func claudesLinkPointsAtTheSharedEntryEvenWhenThatIsALink() throws {
        let own = try skill("Code/my-skills/x")
        try FileManager.default.createDirectory(atPath: home + "/.agents/skills", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.claude/skills", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/.agents/skills/x", withDestinationPath: own)
        try #require(succeeded(engine.apply([.link(at: home + "/.claude/skills/x", to: home + "/.agents/skills/x")], title: "Link x")))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: home + "/.claude/skills/x") == "../../.agents/skills/x")
        let removal = SkillInstall.removal(name: "x", inventory: SkillInventory.scan(home: home))
        #expect(removal.contains(.trash(home + "/.claude/skills/x")))
    }

    /// A lock file that links to a dotfiles copy not checked out yet: the reason given is the missing
    /// target, not "read-only".
    @Test func aDanglingLockLinkSaysWhatIsMissing() throws {
        try FileManager.default.createDirectory(atPath: home + "/.agents", withIntermediateDirectories: true)
        let lock = home + "/.agents/.skill-lock.json"
        try FileManager.default.createSymbolicLink(atPath: lock, withDestinationPath: "../dotfiles/skill-lock.json")
        #expect(SkillLock.isDanglingLink(lock))
        let entry = SkillLock.Entry(source: "a/b", sourceUrl: "u", skillPath: "SKILL.md", skillFolderHash: "h", installedAt: Date(), updatedAt: Date())
        guard case .failure(let failure) = engine.apply([.lockEntry(path: lock, name: "x", entry: entry)], title: "Install x") else {
            Issue.record("should refuse"); return
        }
        #expect(failure.message.contains("missing") && !failure.message.contains("read-only"))
        #expect(SkillChanges.isLink(lock))
    }

    /// The Trash moved the item but did not say where: the message must not claim nothing changed.
    @Test func aTrashWithoutALocationIsReportedHonestly() throws {
        let shared = try skill(".agents/skills/notes", body: "the user's shared version")
        let elsewhere = home + "/somewhere-in-the-trash"
        let vague = SkillChanges(undoFile: engine.undoFile) { path in
            try FileManager.default.moveItem(atPath: path, toPath: elsewhere)
            throw SkillChanges.Failure(message: "went to the Trash, but macOS did not say where")
        }
        guard case .failure(let failure) = vague.apply([.trash(shared)], title: "Remove notes") else { Issue.record("should fail"); return }
        #expect(!failure.message.contains("Nothing was changed"))
        #expect(failure.message.contains("Put Back"))
    }
}

@Suite struct SkillChangesRoundThreeTests {
    let home: String
    let trash: String
    let engine: SkillChanges

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nt-changes3-\(UUID().uuidString)").path
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

    func succeeded(_ result: Result<Void, SkillChanges.Failure>) -> Bool {
        if case .failure(let failure) = result { Issue.record("\(failure.message)"); return false }
        return true
    }

    func entry() -> SkillLock.Entry {
        SkillLock.Entry(source: "example/skills", sourceUrl: "https://github.com/example/skills.git", skillPath: "skills/first/SKILL.md",
                        skillFolderHash: "aaaa", installedAt: Date(), updatedAt: Date())
    }

    /// A Trash that moves the item but does not say where: the change below keeps its Undo, and nothing
    /// that Undo could never reverse is recorded.
    @Test func aTrashWithoutALocationKeepsTheEarlierUndo() throws {
        let first = try skill(".agents/skills/first")
        try #require(succeeded(engine.apply([.trash(first)], title: "Remove first")))
        let other = try skill(".codex/skills/other")
        let elsewhere = home + "/somewhere-in-the-trash"
        let vague = SkillChanges(undoFile: engine.undoFile) { path in
            try FileManager.default.moveItem(atPath: path, toPath: elsewhere)
            throw SkillChanges.Failure(message: "\(SkillStep.short(path)) went to the Trash, but macOS did not say where.")
        }
        guard case .failure(let failure) = vague.apply([.trash(other)], title: "Move other to the Trash") else {
            Issue.record("should fail"); return
        }
        #expect(failure.message.contains("Put Back"))
        #expect(!failure.message.contains("Undo can try again"))
        #expect(engine.lastChange?.title == "Remove first")
        try #require(succeeded(engine.undo()))
        #expect(FileManager.default.fileExists(atPath: first + "/SKILL.md"))
    }

    /// An undo record written before this fix, holding a Trash move with no known location, doesn't
    /// block the change below it.
    @Test func anOldRecordWithAnUnknownTrashPlaceIsSkipped() throws {
        let first = try skill(".agents/skills/first")
        try #require(succeeded(engine.apply([.trash(first)], title: "Remove first")))
        var list = engine.changes
        list.append(SkillChanges.Change(title: "Move x to the Trash", entries: [.init(kind: .trashed, path: home + "/.codex/skills/x", other: nil)]))
        engine.store(list)
        #expect(engine.lastChange?.title == "Remove first")
        try #require(succeeded(engine.undo()))
        #expect(FileManager.default.fileExists(atPath: first + "/SKILL.md"))
    }

    /// Two removals of the same skill, both planned before either ran: the second finds nothing to do,
    /// and the first one's Undo still brings the skill and its lock entry back.
    @Test func aChangeThatDoesNothingKeepsTheEarlierUndo() throws {
        let first = try skill(".agents/skills/first")
        let lock = home + "/.agents/.skill-lock.json"
        guard case .success(let text) = SkillLock.updated(nil, name: "first", entry: entry()) else { Issue.record("lock"); return }
        try text.write(toFile: lock, atomically: true, encoding: .utf8)
        let removal: [SkillStep] = [.trash(first), .lockEntry(path: lock, name: "first", entry: nil)]
        try #require(succeeded(engine.apply(removal, title: "Remove first")))
        try #require(succeeded(engine.apply(removal, title: "Remove first")))
        #expect(engine.changes.count == 1)
        #expect(engine.lastChange?.entries.count == 2)
        try #require(succeeded(engine.undo()))
        #expect(FileManager.default.fileExists(atPath: first + "/SKILL.md"))
        #expect(SkillLock.rawItem(try String(contentsOfFile: lock, encoding: .utf8), name: "first") != nil)
    }

    /// Undo reverses the change the user confirmed, or nothing: another change that landed in between
    /// (from another window, or an agent) is not reversed in its place.
    @Test func undoReversesOnlyTheChangeConfirmed() throws {
        let alpha = try skill(".agents/skills/alpha")
        try #require(succeeded(engine.apply([.link(at: home + "/.claude/skills/alpha", to: alpha)], title: "Link alpha")))
        let shown = try #require(engine.lastChange)
        let beta = try skill(".agents/skills/beta")
        try #require(succeeded(engine.apply([.trash(beta)], title: "Remove beta")))
        guard case .failure(let failure) = engine.undo(expecting: shown) else { Issue.record("should refuse"); return }
        #expect(failure.message.contains("Remove beta") && failure.message.contains("Nothing was undone"))
        #expect(!FileManager.default.fileExists(atPath: beta))
        #expect(SkillChanges.isLink(home + "/.claude/skills/alpha"))
        try #require(succeeded(engine.undo(expecting: engine.lastChange)))
        #expect(FileManager.default.fileExists(atPath: beta + "/SKILL.md"))
    }

    /// A check after the last step that finds a problem puts this change back (even what was edited
    /// since it was made), keeps the earlier change's Undo, and says so.
    @Test func aFailedCheckPutsBackOnlyThisChange() throws {
        let other = try skill(".codex/skills/other")
        try #require(succeeded(engine.apply([.trash(other)], title: "Remove other")))
        let old = try skill(".agents/skills/demo", body: "version 1")
        let staged = try skill("staged/demo", body: "version 2")
        let shared = home + "/.agents/skills/demo"
        let steps: [SkillStep] = [.trash(old), .copy(from: staged, to: shared), .link(at: home + "/.claude/skills/demo", to: shared)]
        let result = engine.apply(steps, title: "Update demo") {
            // Changed between the copy and the check: what the check exists to catch.
            try? "tampered".write(toFile: shared + "/extra.txt", atomically: true, encoding: .utf8)
            return "The installed files did not match the reviewed commit."
        }
        guard case .failure(let failure) = result else { Issue.record("should fail"); return }
        #expect(failure.message == "The installed files did not match the reviewed commit. Nothing was changed.")
        #expect(try String(contentsOfFile: shared + "/SKILL.md", encoding: .utf8).contains("version 1"))
        #expect(!FileManager.default.fileExists(atPath: shared + "/extra.txt"))
        #expect(!SkillChanges.exists(home + "/.claude/skills/demo"))
        #expect(engine.lastChange?.title == "Remove other")
        // A check that passes records the change as usual.
        try #require(succeeded(engine.apply(steps, title: "Update demo") { nil }))
        #expect(engine.lastChange?.title == "Update demo")
    }

    /// The same for a hand-made skill moved to the Trash twice: the record is not deleted.
    @Test func aTrashOfSomethingAlreadyGoneKeepsTheRecord() throws {
        let notes = try skill(".claude/skills/notes")
        try #require(succeeded(engine.apply([.trash(notes)], title: "Move notes to the Trash")))
        try #require(succeeded(engine.apply([.trash(notes)], title: "Move notes to the Trash")))
        #expect(engine.lastChange?.title == "Move notes to the Trash")
        try #require(succeeded(engine.undo()))
        #expect(FileManager.default.fileExists(atPath: notes + "/SKILL.md"))
    }
}
