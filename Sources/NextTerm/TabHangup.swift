import Foundation
import NextTermCore

/// Carries out a tab's hangup (TabProcessTree's plan): SIGHUP to each target group, and after a grace of up to a
/// second SIGTERM to each target still alive as the same process, unless it ignores SIGHUP (nohup). Never SIGKILL:
/// these are the user's programs.
enum TabHangup {
    static let grace: TimeInterval = 1

    static func send(_ plan: HangupPlan) {
        for group in plan.groups { killpg(group, SIGHUP) }
        for group in plan.stoppedGroups { killpg(group, SIGCONT) } // a stopped process gets the hangup once continued
    }

    /// Waits until every process in `waiting` has ended or `seconds` have passed, looking every 50 ms, then sends
    /// SIGTERM to those still alive as themselves. Returns them. It blocks: Quit calls it once for all its tabs, so
    /// they share one deadline, and quits at once when nothing outlived the hangup.
    @discardableResult
    static func finish(_ waiting: [ProcessRecord], within seconds: TimeInterval = grace) -> [ProcessRecord] {
        var left = waiting
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !left.isEmpty {
            left = TabProcessTree.outlived(left, now: ProcessSnapshot.record(of:))
            if left.isEmpty || ProcessInfo.processInfo.systemUptime >= deadline { break }
            usleep(50_000)
        }
        for record in left { kill(record.pid, SIGTERM) }
        return left
    }

    /// The same, off the main thread: closing a tab or a window doesn't wait for it.
    static func finishLater(_ waiting: [ProcessRecord]) {
        guard !waiting.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { finish(waiting) }
    }
}
