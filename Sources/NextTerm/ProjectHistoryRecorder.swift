import AppKit
import NextTermCore

/// Keeps the Welcome window's project history. Every project a window takes is recorded as opened, however it got it:
/// File › Open Project, ⌘O, Open Recent, the Dock, Finder, `nxtrm`, an agent over MCP (`open_project`, or `new_tab`
/// into a folder no window holds), a worktree window, the sidebar, Resume, a restore. Every project no window holds any
/// more is recorded as last used when one of its windows was last in front.
///
/// AppDelegate tells it after each change to what its windows hold (`projectsChanged()`), which every window open, close
/// and project change reaches, and it compares that with what they held before (OpenProjects). What that call does not
/// see it watches itself: windows coming to the front and leaving it, and the quit, which closes no window.
///
/// Main thread only, as the windows are.
final class ProjectHistoryRecorder {
    static let shared = ProjectHistoryRecorder()
    /// Posted on the main thread after the history changed, for the Welcome window to list it as it is now.
    static let didChange = Notification.Name("NextTermProjectHistoryChanged")

    /// Where the history is kept: the user's defaults, or during a self-test a scratch suite emptied as the run starts,
    /// so the fixture windows it opens never push the user's own projects out and the user's history is never written.
    /// Nil when that suite could not be made: the run keeps its history in memory only.
    private let store: ProjectHistoryStore?
    /// The projects used, newest first.
    private(set) var history: ProjectHistory
    private var open = OpenProjects()
    /// The terminal window that has the keyboard as the user put it there; nil while another window has it, or one
    /// brought forward for an agent, which is not a window the user went to.
    private weak var front: TerminalWindowController?
    private var observers: [NSObjectProtocol] = []

    private init() {
        store = SelfTest.isRequested ? ProjectHistoryStore.scratch() : ProjectHistoryStore(defaults: .standard)
        history = store?.load() ?? ProjectHistory()
        let center = NotificationCenter.default
        // No queue: told as it happens, while a window brought forward for an agent is still marked so, and the quit
        // before the app ends.
        let becameKey = center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { [weak self] note in
            self?.windowBecameKey(note.object as? NSWindow)
        }
        let resignedKey = center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: nil) { [weak self] note in
            self?.windowResignedKey(note.object as? NSWindow)
        }
        let quits = center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.quit()
        }
        observers = [becameKey, resignedKey, quits]
    }

    /// What the windows hold changed: a project a window took is opened now, one no window holds any more is closed at
    /// its last time in front.
    func update(_ controllers: [TerminalWindowController]) {
        let now = Date()
        record(open.update(windows(controllers), at: now), at: now, notify: true)
    }

    /// ⌘⌫ on a closed project in the Welcome window: it leaves the history and Recent Projects both. A project a window
    /// holds stays.
    func forget(_ path: String) {
        guard !open.paths.contains(path) else { return }
        if history.lastUsed(path) != nil {
            history.forget(path)
            saved()
        }
        let stored: [String] = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []
        var recent = RecentProjects(stored)
        recent.remove(path)
        if recent.paths != stored { AppDelegate.shared.setRecentProjects(recent.paths) }
    }

    /// Clear Menu: the history goes with Recent Projects. A project still open comes back as its last window closes.
    func clear() {
        guard !history.entries.isEmpty else { return }
        history.clear()
        saved()
    }

    // MARK: watching

    private func windowBecameKey(_ window: NSWindow?) {
        guard let controller = window?.windowController as? TerminalWindowController else { return }
        // Brought forward for an agent: not a window the user went to, as its own last time in front says too.
        guard !controller.keyingForAgent else { return }
        front = controller
        if let path = controller.project { open.sawInFront(path, at: Date()) }
    }

    /// The window the user had in front gave up the keyboard (another window, another app, or its close): in front until now.
    private func windowResignedKey(_ window: NSWindow?) {
        guard let controller = window?.windowController as? TerminalWindowController, controller === front else { return }
        front = nil
        if let path = controller.project { open.sawInFront(path, at: Date()) }
    }

    /// Next Term quits with its windows open: each project is recorded as last used when its window was last in front,
    /// the one with the keyboard now.
    private func quit() {
        let now = Date()
        record(open.quit(windows(AppDelegate.shared.controllers), at: now), at: now, notify: false)
    }

    // MARK: recording

    private func windows(_ controllers: [TerminalWindowController]) -> [OpenProjects.Window] {
        var windows: [OpenProjects.Window] = []
        for controller in controllers where !controller.hasClosed {
            guard let path = controller.project else { continue }
            let id = Int(bitPattern: ObjectIdentifier(controller))
            let isFront: Bool = controller === front && controller.window?.isKeyWindow == true
            windows.append(OpenProjects.Window(id: id, path: path, lastInFront: controller.lastKey, isFront: isFront))
        }
        return windows
    }

    private func record(_ changes: ProjectHistory.Changes, at now: Date, notify: Bool) {
        guard !changes.isEmpty else { return }
        var next: ProjectHistory = history
        next.record(changes, at: now)
        guard next != history else { return }
        history = next
        // At the quit no window is left to tell: only saved.
        if notify { saved() } else { store?.save(next) }
    }

    private func saved() {
        store?.save(history)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
