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

    /// Changes run one at a time, off the main thread: copying, checking and hashing a large skill
    /// takes seconds, and the window must keep answering meanwhile.
    private static let queue = DispatchQueue(label: "NextTerm.skill-changes")
    /// Posted when a change starts or ends, so views turn off (or back on) what would start another.
    static let busyChanged = Notification.Name("NextTermSkillsBusyChanged")

    /// Changes asked for and not finished yet. Quitting waits until it is 0: a change cut off part-way
    /// would leave a half-made skill and no Undo.
    @MainActor private(set) static var running = 0
    @MainActor private static var whenIdle: [() -> Void] = []

    /// Runs `body` once no change is running (now, if none is).
    @MainActor static func afterChanges(_ body: @escaping () -> Void) {
        if running == 0 { body() } else { whenIdle.append(body) }
    }

    /// Queued from the main actor, so changes run in the order they were asked for.
    @MainActor private static func run(_ work: @escaping @Sendable (SkillChanges) -> Result<Void, Failure>) async -> Result<Void, Failure> {
        let engine = changes
        running += 1
        NotificationCenter.default.post(name: busyChanged, object: nil)
        let result = await withCheckedContinuation { (done: CheckedContinuation<Result<Void, Failure>, Never>) in
            queue.async { done.resume(returning: work(engine)) }
        }
        running -= 1
        notify()
        NotificationCenter.default.post(name: busyChanged, object: nil)
        if running == 0 {
            let waiting = whenIdle
            whenIdle = []
            waiting.forEach { $0() }
        }
        return result
    }

    /// `verify` runs right after the last step, in the same turn on the queue: a problem it names puts
    /// the change back before anything else can run.
    @discardableResult
    @MainActor static func apply(_ steps: [SkillStep], title: String, verify: (@Sendable () -> String?)? = nil) async -> Result<Void, Failure> {
        await run { $0.apply(steps, title: title, verify: verify) }
    }

    /// `expected`: the change the user confirmed; if another one landed since, nothing is undone.
    @discardableResult
    @MainActor static func undo(expecting expected: SkillChanges.Change? = nil) async -> Result<Void, Failure> {
        await run { $0.undo(expecting: expected) }
    }

    private static func notify() {
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
