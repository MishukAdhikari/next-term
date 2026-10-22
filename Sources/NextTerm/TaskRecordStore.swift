import Foundation
import NextTermCore

/// The app's one posted record (TaskRecord), in Next Term's folder in Application Support, or the self-test's own
/// folder (SelfTest.historyFolder), so a self-test never reads or writes yours. Every call runs on one serial queue and
/// returns when done: the file is small and read only to its cap. A write that fails never stops the task, which is
/// sent already; the caller says it wasn't remembered. Nothing here is logged, and nothing that leaves the Mac reads it.
final class TaskRecordStore: @unchecked Sendable {
    static let shared = TaskRecordStore(file: SelfTest.historyFolder.map { TaskRecordFile(support: $0) })

    private let file: TaskRecordFile?
    private let queue = DispatchQueue(label: "nextterm.tasks.record", qos: .userInitiated)
    /// When old lines were last dropped, on `queue`: at most once a day.
    private var prunedAt: Date?

    init(file: TaskRecordFile?) {
        self.file = file
    }

    /// Records one post. False when it couldn't be: the done line then adds that it isn't remembered for the
    /// duplicate check.
    @discardableResult
    func record(_ entry: TaskRecord.Entry, now: Date = Date()) -> Bool {
        queue.sync {
            guard let file else { return false }
            do {
                try file.append(entry)
            } catch {
                return false
            }
            pruneIfDue(file, now: now)
            return true
        }
    }

    /// The newest post of the same title to the same place within a minute, if any.
    func recentDuplicate(kind: TaskDestination.Kind, key: String, slug: String, now: Date = Date()) -> TaskRecord.Entry? {
        let entries = read()
        return TaskRecord.recentDuplicate(entries, kind: kind, key: key, slug: slug, now: now)
    }

    /// Today's posts for `project` (every project when nil), oldest first.
    func today(project: String?, now: Date = Date()) -> [TaskRecord.Entry] {
        TaskRecord.today(read(), project: project, now: now)
    }

    /// Forgets the item `itemID` made in `kind`, after its Undo removed it, so the duplicate warning doesn't fire on a
    /// task that no longer exists.
    func remove(itemID: String, kind: TaskDestination.Kind) {
        queue.sync {
            try? file?.remove(itemID: itemID, kind: kind)
        }
    }

    private func read() -> [TaskRecord.Entry] {
        queue.sync {
            guard let file else { return [] }
            return (try? file.read()) ?? []
        }
    }

    /// On `queue`.
    private func pruneIfDue(_ file: TaskRecordFile, now: Date) {
        if let prunedAt, now.timeIntervalSince(prunedAt) < 86_400 { return }
        prunedAt = now
        try? file.prune(now: now)
    }
}
