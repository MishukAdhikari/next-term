import Foundation

/// What closed tabs still wait for off the main thread: the processes that get SIGTERM if they outlive the
/// hangup's grace. Quit takes them all and waits for them with its own tabs, so a SIGTERM due a moment after a
/// tab closed is not lost when the app exits first. Safe from any thread.
public final class PendingHangups: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [ProcessRecord] = []

    public init() {}

    public func add(_ records: [ProcessRecord]) {
        lock.lock()
        waiting += records
        lock.unlock()
    }

    /// The wait for `records` is over (they ended, or got their SIGTERM).
    public func remove(_ records: [ProcessRecord]) {
        lock.lock()
        waiting.removeAll { record in records.contains { $0.pid == record.pid && $0.started == record.started } }
        lock.unlock()
    }

    /// Everything still waited for, and none any more.
    public func takeAll() -> [ProcessRecord] {
        lock.lock()
        defer {
            waiting = []
            lock.unlock()
        }
        return waiting
    }
}
