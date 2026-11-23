import AppKit
import NextTermCore

/// Keeps a `GitSnapshot` fresh for one folder. At most one git run at a time. Refreshes set off by file
/// changes go through a `GatedRefresh`: a burst (an agent writing fifty files) is one refresh, a steady writer
/// gets one every 2.5 s at most (less often where a refresh is slow), and a window nobody can see gets none
/// until it shows again. While those refreshes find the same snapshot (a writer in a file git ignores) the pace
/// backs off to 5 s and then 10 s; one that finds something new, or a git command run here, brings it back.
final class GitMonitor {
    private(set) var snapshot: GitSnapshot?
    /// Called on the main thread after every refresh, with nil when the folder is not in a repository.
    var onChange: ((GitSnapshot?) -> Void)?

    private var directory: String?
    private var running = false
    private var pending = false
    /// The refresh owed after the running one was asked for directly, not set off by file changes.
    private var pendingDirect = false
    /// Bumped when the folder changes, so a slow git run for the old folder is ignored.
    private var generation = 0
    private let gated = GatedRefresh(interval: 2.5, settle: 0.4)
    private let queue = DispatchQueue(label: "nextterm.git", qos: .utility)
    private static let git = GitRunner.locateGit()

    static var isAvailable: Bool { git != nil }

    /// Refreshes started so far, for the self-test.
    private(set) var refreshCount = 0

    /// The window whose visibility gates refreshes set off by file changes; nil counts as visible.
    var window: NSWindow? {
        get { gated.window }
        set { gated.window = newValue }
    }

    init() {
        gated.run = { [weak self] in self?.start(direct: false) }
    }

    func watch(_ folder: String) {
        guard folder != directory else { return }
        directory = folder
        generation += 1
        snapshot = nil
        gated.cancel()
        onChange?(nil)
        refresh()
    }

    /// Watches nothing: the window closed, or its tree shows no project. The last snapshot goes too.
    func stop() {
        directory = nil
        generation += 1
        snapshot = nil
        gated.cancel()
    }

    /// Something changed in the folder: refresh when the gate says.
    func refreshSoon() {
        gated.changed()
    }

    /// Refresh now: after a git command run here, a fetch, or when asked to show the latest.
    func refresh() {
        start(direct: true)
    }

    /// Starts a refresh. One the gate started (`direct` false) that finds the snapshot it already had tells the gate
    /// so, and the gate backs off; a direct one never does.
    private func start(direct: Bool) {
        guard let folder = directory, let git = Self.git else { return }
        if running {
            pending = true
            pendingDirect = pendingDirect || direct
            return
        }
        running = true
        refreshCount += 1
        gated.started()
        let current = generation
        queue.async {
            let result = GitRunner.snapshot(for: folder, git: git)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.running = false
                let fresh = current == self.generation
                self.gated.finished(unchanged: !direct && fresh && result == self.snapshot)
                if fresh {
                    self.snapshot = result
                    self.onChange?(result)
                }
                if self.pending {
                    let again = self.pendingDirect
                    self.pending = false
                    self.pendingDirect = false
                    self.start(direct: again)
                }
            }
        }
    }
}
