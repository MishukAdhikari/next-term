import AppKit
import NextTermCore

/// A place a hint can go: the window column (its list's foot, the pinned column's, beside the rail) or a tab bar's free
/// room. It puts a line up only where its words fit whole and over chrome, never over text, and says false otherwise.
@MainActor
protocol HintPlace: AnyObject {
    /// Puts `line` up; false, and nothing put up, when there is no room for it now.
    func showHint(_ line: HintLine) -> Bool
    /// Takes the line up down, wherever it is.
    func removeHint()
    /// The line up goes with its place (the hover list it sits in), so no wait takes it down.
    var hintGoesWithPlace: Bool { get }
}

/// The one stage every hint is put up on (plan 035): one hint up across the app, its × retiring it, a passive one
/// taken down after a few seconds (longer while the pointer is on it) or with its place, and the triggers whose moment
/// is not right yet (the user typing, an agent working, a window under a minute old, another hint or a notice up)
/// waiting while they still hold, ten minutes at most, looked at once a second. Each hint's own triggers, words and
/// place live with its feature (ColumnHints, BarHints); the rules are HintCenter's.
@MainActor
final class HintStage {
    static let shared = HintStage()
    /// None while the self-test's other parts run, whose geometry and notices were written without hints.
    static var suppressed = false

    /// How long a line not in a hover list stays up.
    static var stays: TimeInterval = 8
    /// How long a trigger waits for its moment, and how often it looks. The self-test stands in for these.
    static var waitsAtMost: TimeInterval = HintWaits.atMost
    static var looksEvery: TimeInterval = 1
    /// The window the user works in: Next Term's key window while it is in front. The self-test stands in.
    static var front: () -> TerminalWindowController? = {
        NSApp.isActive ? NSApp.keyWindow?.windowController as? TerminalWindowController : nil
    }

    /// A waiting trigger: whether it still holds, and an attempt to put its hint up in the window in front, true once up.
    struct Trigger {
        let holds: () -> Bool
        let show: (TerminalWindowController) -> Bool
    }

    /// The hint up now, and where.
    private(set) var shown: (hint: Hint, line: HintLine, place: HintPlace)?
    private var waits = HintWaits()
    private var triggers: [Hint: Trigger] = [:]
    private var looking: Timer?
    /// Counts the hints put up: a wait to take one down whose count has moved on does nothing.
    private var showings = 0

    private init() {
        NotificationCenter.default.addObserver(forName: HintCenter.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.centerChanged() }
        }
    }

    /// Whether `hint`'s trigger is waiting for its moment.
    func isWaiting(_ hint: Hint) -> Bool { waits.contains(hint) }

    // MARK: waiting

    /// `hint`'s trigger fired: it is tried now, then once a second while `holds` and tips are on and it is not retired.
    func wait(for hint: Hint, holds: @escaping () -> Bool, show: @escaping (TerminalWindowController) -> Bool) {
        guard !Self.suppressed, HintCenter.shared.tipsOn, HintCenter.shared.record(hint).retired == nil else { return }
        waits.start(hint, now: ProcessInfo.processInfo.systemUptime)
        triggers[hint] = Trigger(holds: holds, show: show)
        look()
        guard looking == nil, !waits.isEmpty else { return }
        let timer = Timer(timeInterval: Self.looksEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
        RunLoop.main.add(timer, forMode: .common)
        looking = timer
    }

    /// Each waiting trigger: dropped once it no longer holds or has waited too long, put up once its moment is right.
    func look() {
        waits.drop(now: ProcessInfo.processInfo.systemUptime, atMost: Self.waitsAtMost) { [triggers] (hint: Hint) -> Bool in
            HintCenter.shared.tipsOn && HintCenter.shared.record(hint).retired == nil && triggers[hint]?.holds() == true
        }
        for hint in Hint.allCases where !waits.contains(hint) { triggers[hint] = nil }
        if shown == nil, let controller = Self.front() {
            for hint in waits.order {
                guard let trigger = triggers[hint], trigger.show(controller) else { continue }
                waits.remove(hint)
                triggers[hint] = nil
                break
            }
        }
        stopLookingIfDone()
    }

    private func stopLookingIfDone() {
        guard waits.isEmpty else { return }
        looking?.invalidate()
        looking = nil
    }

    // MARK: up and down

    /// `line` up in `place`, counted from now, its × retiring it; one not in a hover list goes after `stays`. False
    /// when a hint is up already or the place has no room.
    @discardableResult
    func put(_ line: HintLine, in place: HintPlace) -> Bool {
        guard !Self.suppressed, shown == nil, place.showHint(line) else { return false }
        let hint: Hint = line.hint
        line.onClose = { [weak self] in
            HintCenter.shared.retire(hint, reason: .closed)
            self?.hide()
        }
        HintCenter.shared.noteShown(hint)
        shown = (hint, line, place)
        showings += 1
        if !place.hintGoesWithPlace { takeDownLater(showings) }
        return true
    }

    /// After `stays`, the hint put up as `showing` goes, unless the pointer is on it: then once it has left.
    private func takeDownLater(_ showing: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stays) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.showings == showing, let shown = self.shown else { return }
                if shown.line.hovering { return self.takeDownLater(showing) }
                self.hide()
            }
        }
    }

    /// The hint up goes, its showing counted as long as it was up.
    func hide() {
        guard let up = shown else { return }
        shown = nil
        up.place.removeHint()
        HintCenter.shared.noteHidden(up.hint)
    }

    /// `hint`, if it is the one up, goes.
    func hide(_ hint: Hint) {
        guard shown?.hint == hint else { return }
        hide()
    }

    /// `place`'s hint lost its room: it goes.
    func placeWent(in place: HintPlace) {
        guard let up = shown, up.place === place else { return place.removeHint() }
        hide()
    }

    /// HintCenter no longer has the hint up (it retired by use or ×, tips went off, or were reset): its line goes,
    /// and nothing more is counted. A hint at its last showing stays until it goes as it would.
    private func centerChanged() {
        guard let up = shown, HintCenter.shared.visible?.hint != up.hint else { return }
        shown = nil
        up.place.removeHint()
    }

    #if DEBUG
    /// For the self-test: nothing up or waiting, as at launch.
    func resetForTest() {
        hide()
        waits.removeAll()
        triggers = [:]
        looking?.invalidate()
        looking = nil
    }
    #endif
}
