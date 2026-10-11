import AppKit
import NextTermCore

/// Keeps a `GitSnapshot` fresh for one folder. At most one git run at a time. Refreshes set off by file
/// changes go through a `GatedRefresh`: a burst (an agent writing fifty files) is one refresh, a steady writer
/// gets one every 2.5 s at most (less often where a refresh is slow), and a window nobody can see gets none
/// until it shows again.
final class GitMonitor {
    private(set) var snapshot: GitSnapshot?
    /// Called on the main thread after every refresh, with nil when the folder is not in a repository.
    var onChange: ((GitSnapshot?) -> Void)?

    private var directory: String?
    private var running = false
    private var pending = false
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
        gated.run = { [weak self] in self?.refresh() }
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

    func stop() {
        directory = nil
        generation += 1
        gated.cancel()
    }

    /// Something changed in the folder: refresh when the gate says.
    func refreshSoon() {
        gated.changed()
    }

    /// Refresh now: after a git command run here, a fetch, or when asked to show the latest.
    func refresh() {
        guard let folder = directory, let git = Self.git else { return }
        if running {
            pending = true
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
                self.gated.finished()
                if current == self.generation {
                    self.snapshot = result
                    self.onChange?(result)
                }
                if self.pending {
                    self.pending = false
                    self.refresh()
                }
            }
        }
    }
}
