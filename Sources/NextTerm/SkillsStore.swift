import AppKit
import NextTermCore

/// The Skills library's hands: SkillChanges (in the core, where it is unit-tested) carries out the
/// steps and keeps the last change for Undo; this says where, and tells open views. Nothing here runs
/// without the user having seen the steps (the unify sheet, the review sheet, the removal prompt).
enum SkillsStore {
    /// The home folder the library reads and writes. The self-test points it at a folder of its own.
    nonisolated(unsafe) static var home = NSHomeDirectory()
    /// Posted after a change on disk, so open views reload.
    static let changed = Notification.Name("NextTermSkillsChanged")

    typealias Failure = SkillChanges.Failure

    static func inventory() -> SkillInventory { SkillInventory.scan(home: home) }

    /// The inventory, read off the main thread (it reads every skill's SKILL.md, and hashes copies to compare).
    static func scan() async -> SkillInventory {
        let home = home
        return await Task.detached { SkillInventory.scan(home: home) }.value
    }

    private static var isOwnHome: Bool { home == NSHomeDirectory() }

    /// Next Term's own folder for the library: the undo record, the install records, downloads being reviewed.
    static var supportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Next Term", isDirectory: true)
        return isOwnHome ? base : base.appendingPathComponent("skills-test-\(getpid())", isDirectory: true)
    }

    /// The engine: the Finder's Trash for the user's own folders; a folder of its own for the self-test's.
    static var changes: SkillChanges {
        let undoFile = supportFolder.appendingPathComponent("skills-undo.json").path
        if isOwnHome { return SkillChanges(undoFile: undoFile) }
        return SkillChanges(undoFile: undoFile, trash: SkillChanges.folderTrash(supportFolder.appendingPathComponent("Trash").path))
    }

    /// The change Undo would reverse, if any (it survives quitting).
    static var lastChange: SkillChanges.Change? { changes.lastChange }

    @discardableResult
    static func apply(_ steps: [SkillStep], title: String) -> Result<Void, Failure> {
        let result = changes.apply(steps, title: title)
        notify()
        return result
    }

    @discardableResult
    static func undo() -> Result<Void, Failure> {
        let result = changes.undo()
        notify()
        return result
    }

    private static func notify() {
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
