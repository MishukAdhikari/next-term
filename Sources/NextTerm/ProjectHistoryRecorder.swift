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
@MainActor
final class ProjectHistoryRecorder {
    static let shared = ProjectHistoryRecorder()
    /// Posted on the main thread after the history changed, or what the windows hold did (a project opened or closed,
    /// a window more or fewer on one), for the Welcome window to list them as they are now. A close can leave the
    /// history as it was (a window never in front, one of a project's two) and still change the dots and counts.
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
    /// Where the terminal window the user had in front last was, as it came forward or gave up the keyboard (its close
    /// too): the display the Welcome window comes up on when shown from no window, as when that window was the last.
    private(set) var lastFrontFrame: CGRect?
    private var observers: [NSObjectProtocol] = []

    private init() {
        store = SelfTest.isRequested ? ProjectHistoryStore.scratch() : ProjectHistoryStore(defaults: .standard)
        history = store?.load() ?? ProjectHistory()
        let center = NotificationCenter.default
        // No queue: told as it happens, while a window brought forward for an agent is still marked so, and the quit
        // before the app ends. AppKit posts these on the main thread.
        let becameKey = center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.windowBecameKey(window) }
        }
        let resignedKey = center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: nil) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.windowResignedKey(window) }
        }
        let quits = center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.quit() }
        }
        observers = [becameKey, resignedKey, quits]
    }

    /// How many windows hold each open project, as at the last look: what `didChange` tells of beside the history.
    var windowCounts: [String: Int] { open.windowCounts }

    /// What the windows hold changed: a project a window took is opened now, one no window holds any more is closed at
    /// its last time in front. The Welcome list is told whenever the history or the open projects' windows changed.
    func update(_ controllers: [TerminalWindowController]) {
        let now = Date()
        let counts: [String: Int] = open.windowCounts
        let recorded: Bool = record(open.update(windows(controllers), at: now), at: now)
        if recorded || open.windowCounts != counts { changed() }
    }

    /// ⌘⌫ on a closed project in the Welcome window: it leaves the history and Recent Projects both. A project a window
    /// holds stays. Each list is written only if it held the project.
    func forget(_ path: String) {
        var recent = RecentProjects(UserDefaults.standard.stringArray(forKey: "recentProjects") ?? [])
        let listed: RecentProjects = recent
        let forgot: Bool = history.forget(path, recent: &recent, open: open.paths)
        // Recent Projects first, so the Welcome list told next reads both as they are now.
        if recent != listed { AppDelegate.shared.setRecentProjects(recent.paths) }
        guard forgot else { return }
        store?.save(history)
        changed()
    }

    /// Clear Menu: the closed projects leave the history with Recent Projects. An open one keeps its place and time, so
    /// it is still listed after its window closes, even a window never in front.
    func clear() {
        var next: ProjectHistory = history
        next.clear(keeping: open.paths)
        guard next != history else { return }
        history = next
        store?.save(next)
        changed()
    }

    // MARK: watching

    private func windowBecameKey(_ window: NSWindow?) {
        guard let controller = window?.windowController as? TerminalWindowController else { return }
        // Brought forward for an agent: not a window the user went to, as its own last time in front says too.
        guard !controller.keyingForAgent else { return }
        front = controller
        lastFrontFrame = window?.frame
        if let path = controller.project { open.sawInFront(path, at: Date()) }
    }

    /// The window the user had in front gave up the keyboard (another window, another app, or its close): in front until now.
    private func windowResignedKey(_ window: NSWindow?) {
        guard let controller = window?.windowController as? TerminalWindowController, controller === front else { return }
        front = nil
        lastFrontFrame = window?.frame
        if let path = controller.project { open.sawInFront(path, at: Date()) }
    }

    /// Next Term quits with its windows open: each project is recorded as last used when its window was last in front,
    /// the one with the keyboard now.
    private func quit() {
        let now = Date()
        // Only saved: no window is left to tell.
        record(open.quit(windows(AppDelegate.shared.controllers), at: now), at: now)
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

    /// Records what a look saw and saves the history if it changed; true then.
    @discardableResult
    private func record(_ changes: ProjectHistory.Changes, at now: Date) -> Bool {
        guard !changes.isEmpty else { return false }
        var next: ProjectHistory = history
        next.record(changes, at: now)
        guard next != history else { return false }
        history = next
        store?.save(next)
        return true
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
