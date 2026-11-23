import AppKit
import NextTermCore

/// One clock for every window's chores: reading agents' screens, settling their states, posting notices, looking at
/// the open files on disk. Every window wakes on the same beat, and only as often as something on it is worth
/// watching, so an idle Next Term costs the Mac almost nothing (Energy Impact counts wakeups as much as CPU time):
///
/// - `watching`, 4 times a second: Next Term is the app in use and a window someone can see runs a command or an
///   agent. Marks and questions show up as fast as they did with a ticker per window.
/// - `background`, once a second: something runs, but in a window no one is looking at, or with another app in use.
///   Notices and the Dock badge still come within a second.
/// - `idle`, every 2 seconds: nothing runs anywhere. Output in any tab (a command starting where the shell reports
///   nothing) brings the pace back at once (`noteOutput`).
///
/// Each beat has a quarter of its length as tolerance, so macOS can fold it in with other wakeups.
final class WindowTicker {
    static let shared = WindowTicker()

    typealias Pace = TickerPace

    private var timer: Timer?
    private(set) var pace: Pace?
    /// A retune asked for from output (`noteOutput`), at most once per run-loop turn.
    private var retuneQueued = false

    /// Starts the beat if it isn't running: a window opened. It looks once the run loop's turn ends, when the new
    /// window is among the app's windows.
    func start() {
        guard timer == nil else { return }
        DispatchQueue.main.async { [weak self] in self?.retune() }
    }

    /// Output came in somewhere while idle: a command may have started where the shell doesn't say so, and only a
    /// beat's look at the tab's foreground process sees it. One beat comes a quarter of a second later, as it would
    /// at the watching pace, and the pace is looked at again after it.
    func noteOutput() {
        guard pace == .idle || timer == nil, !retuneQueued else { return }
        retuneQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Pace.watching.rawValue) { [weak self] in
            guard let self else { return }
            self.retuneQueued = false
            guard !AppDelegate.shared.controllers.isEmpty else { return self.stop() }
            self.fire(prompted: true)
        }
    }

    /// The pace may have changed: the app came forward or went back, a window showed or hid, a command ended.
    func retune() {
        let controllers = AppDelegate.shared.controllers
        guard !controllers.isEmpty else { return stop() }
        let wanted = Pace.pace(active: NSApp.isActive, windows: controllers.map { ($0.canBeSeen, $0.runsSomething) })
        guard wanted != pace || timer == nil else { return }
        timer?.invalidate()
        pace = wanted
        let timer = Timer(timeInterval: wanted.rawValue, repeats: true) { [weak self] _ in self?.fire() }
        timer.tolerance = wanted.tolerance
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        pace = nil
    }

    /// One beat for every window; `prompted` by output (`noteOutput`), it looks at foreground processes whenever the
    /// last look was.
    private func fire(prompted: Bool = false) {
        let interval = pace?.rawValue ?? Pace.watching.rawValue
        for controller in AppDelegate.shared.controllers { controller.tick(interval: interval, prompted: prompted) }
        retune()
    }
}
