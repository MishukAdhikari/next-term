import Foundation
import NextTermCore

/// Keeps a `GitSnapshot` fresh for one folder. At most one git run at a time; bursts of file events
/// (an agent writing fifty files) collapse into one refresh.
final class GitMonitor {
    private(set) var snapshot: GitSnapshot?
    /// Called on the main thread after every refresh, with nil when the folder is not in a repository.
    var onChange: ((GitSnapshot?) -> Void)?

    private var directory: String?
    private var running = false
    private var pending = false
    /// Bumped when the folder changes, so a slow git run for the old folder is ignored.
    private var generation = 0
    private var debounce: DispatchWorkItem?
    private let queue = DispatchQueue(label: "nextterm.git", qos: .utility)
    private static let git = GitRunner.locateGit()

    static var isAvailable: Bool { git != nil }

    func watch(_ folder: String) {
        guard folder != directory else { return }
        directory = folder
        generation += 1
        snapshot = nil
        onChange?(nil)
        refresh()
    }

    func stop() {
        directory = nil
        generation += 1
        debounce?.cancel()
    }

    /// Refresh after things settle for a moment.
    func refreshSoon() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func refresh() {
        guard let folder = directory, let git = Self.git else { return }
        if running {
            pending = true
            return
        }
        running = true
        let current = generation
        queue.async {
            let result = GitRunner.snapshot(for: folder, git: git)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.running = false
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
