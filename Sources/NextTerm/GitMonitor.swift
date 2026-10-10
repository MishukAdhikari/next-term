import AppKit
import NextTermCore

/// Keeps a `GitSnapshot` fresh for one folder. At most one git run at a time. Refreshes set off by file
/// changes go through a `RefreshGate`: a burst (an agent writing fifty files) is one refresh, a steady writer
/// gets one every 2.5 s at most, and a window nobody can see gets none until it shows again.
final class GitMonitor {
    private(set) var snapshot: GitSnapshot?
    /// Called on the main thread after every refresh, with nil when the folder is not in a repository.
    var onChange: ((GitSnapshot?) -> Void)?

    private var directory: String?
    private var running = false
    private var pending = false
    /// Bumped when the folder changes, so a slow git run for the old folder is ignored.
    private var generation = 0
    private var gate = RefreshGate()
    private var timer: DispatchWorkItem?
    private let queue = DispatchQueue(label: "nextterm.git", qos: .utility)
    private static let git = GitRunner.locateGit()

    static var isAvailable: Bool { git != nil }

    /// Seconds on a steady clock, for the gate.
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The window whose visibility gates refreshes set off by file changes; nil counts as visible.
    weak var window: NSWindow? {
        didSet {
            guard window !== oldValue else { return }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let window {
                // Occlusion covers them all; minimizing and hiding are observed too, for a self-test run (see canBeSeen).
                let windowNames: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                                                         NSWindow.didDeminiaturizeNotification]
                let appNames: [Notification.Name] = [NSApplication.didHideNotification, NSApplication.didUnhideNotification]
                let observe = { (name: Notification.Name, object: AnyObject?) in
                    NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                        self?.windowVisibilityChanged()
                    }
                }
                observers = windowNames.map { observe($0, window) } + appNames.map { observe($0, NSApp) }
            }
            windowVisibilityChanged()
        }
    }
    private var observers: [NSObjectProtocol] = []

    deinit {
        timer?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Whether anyone can see the window: not when it is minimized, the app hidden, the window covered by
    /// others or on another Space, or the screen locked or asleep. In a self-test run, whether it is on
    /// screen at all: the run takes half an hour, and a check must not fail because the Mac locked meanwhile.
    static func canBeSeen(_ window: NSWindow?) -> Bool {
        guard let window else { return true }
        if SelfTest.isRequested { return window.isVisible && !window.isMiniaturized }
        return window.occlusionState.contains(.visible)
    }

    private func windowVisibilityChanged() {
        schedule(gate.setVisible(Self.canBeSeen(window), at: Self.now))
    }

    func watch(_ folder: String) {
        guard folder != directory else { return }
        directory = folder
        generation += 1
        snapshot = nil
        cancelTimer()
        onChange?(nil)
        refresh()
    }

    func stop() {
        directory = nil
        generation += 1
        cancelTimer()
    }

    /// Something changed in the folder: refresh when the gate says.
    func refreshSoon() {
        schedule(gate.changed(at: Self.now))
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
        gate.cancel()
    }

    private func schedule(_ due: TimeInterval?) {
        guard let due else { return }
        timer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fire() }
        timer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due - Self.now), execute: work)
    }

    private func fire() {
        timer = nil
        if gate.fire(at: Self.now) {
            refresh()
        } else {
            schedule(gate.due) // early: wait for the rest
        }
    }

    /// Refresh now: after a git command run here, a fetch, or when asked to show the latest.
    func refresh() {
        guard let folder = directory, let git = Self.git else { return }
        if running {
            pending = true
            return
        }
        running = true
        gate.started(at: Self.now)
        timer?.cancel()
        timer = nil
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
