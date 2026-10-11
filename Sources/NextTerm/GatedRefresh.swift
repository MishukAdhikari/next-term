import AppKit
import NextTermCore

/// Runs work that file changes set off when a `RefreshGate` says: the sidebar's git refresh and its Databases scan.
/// A burst is one run, a steady writer gets one every `interval` at most and a slow run earns a rest, and a window
/// nobody can see gets none until it shows again. It keeps the gate's one timer and watches the window.
final class GatedRefresh {
    private var gate: RefreshGate
    private var timer: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    /// Called on the main thread when the gate says to run; the owner tells `started` and `finished`.
    var run: (() -> Void)?

    /// The window whose visibility gates the runs; nil counts as visible.
    weak var window: NSWindow? {
        didSet {
            guard window !== oldValue else { return }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let window {
                observers = NSWindow.visibilityNotifications.map { name, ofApp in
                    NotificationCenter.default.addObserver(forName: name, object: ofApp ? NSApp : window, queue: .main) { [weak self] _ in
                        self?.windowVisibilityChanged()
                    }
                }
            }
            windowVisibilityChanged()
        }
    }

    init(interval: TimeInterval, settle: TimeInterval) {
        gate = RefreshGate(interval: interval, settle: settle)
    }

    deinit {
        timer?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Seconds on a steady clock, for the gate.
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Something changed: run when the gate says.
    func changed() {
        schedule(gate.changed(at: Self.now))
    }

    /// A run started, from the gate or asked for directly: it sees every change before it.
    func started() {
        gate.started(at: Self.now)
        timer?.cancel()
        timer = nil
    }

    /// The run that started last ended: the next one, if a change came meanwhile, after its rest.
    func finished() {
        schedule(gate.finished(at: Self.now))
    }

    /// Nothing due or owed any more: the folder changed, or the window closed.
    func cancel() {
        timer?.cancel()
        timer = nil
        gate.cancel()
    }

    private func windowVisibilityChanged() {
        schedule(gate.setVisible(window?.canBeSeen ?? true, at: Self.now))
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
            run?()
        } else if !gate.isRunning {
            schedule(gate.due) // early: wait for the rest (a run going on reschedules when it ends)
        }
    }
}
