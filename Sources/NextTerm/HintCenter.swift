import AppKit
import NextTermCore

/// The hints' one place in the app (plan 033 R2): it reads and writes what each hint remembers (HintRules), says
/// whether one may show in a window now, counts its showings, and retires it. Every hint view asks it, so the rules
/// are the same for all: at most one hint up across the app, one a day, never while the user types or an agent works.
@MainActor
final class HintCenter {
    static let shared = HintCenter()

    /// A hint was shown, counted or retired, tips were reset, or turned on or off: a hint view that shows checks again.
    static let changed = Notification.Name("NextTermHintsChanged")

    private let defaults: UserDefaults
    /// The hint up now, and when it came up on the uptime clock, for its exposure.
    private(set) var visible: (hint: Hint, since: TimeInterval)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Settings › General › "Show tips for features you haven't used". Off, no hint shows; on again, those not retired
    /// show again, and Reset Tips brings back the rest.
    var tipsOn: Bool {
        get { HintRules.tipsOn(defaults) }
        set {
            guard newValue != tipsOn else { return }
            defaults.set(newValue, forKey: HintRules.tipsKey)
            if !newValue { visible = nil }
            post()
        }
    }

    func record(_ hint: Hint) -> HintRules.Record { HintRules.load(hint, defaults) }

    /// Whether `hint` shows now in `controller`, its trigger having fired: the moment read from the window (the last
    /// key, its age, the focused tab's agent) and from what else is up. The trigger starts the hint's 60 days, and one
    /// past them retires quietly.
    func eligible(_ hint: Hint, in controller: TerminalWindowController) -> Bool {
        heldBack(hint, situation(hint, in: controller)) == nil
    }

    /// The same for a moment given whole, for the self-test and for a hint whose window is not a terminal window.
    func eligible(_ hint: Hint, _ situation: HintRules.Situation) -> Bool { heldBack(hint, situation) == nil }

    private func heldBack(_ hint: Hint, _ situation: HintRules.Situation) -> HintRules.HeldBack? {
        if situation.tipsOn {
            let triggered: HintRules.Record = HintRules.noteTriggered(situation.record, now: situation.now)
            if triggered != situation.record { HintRules.save(triggered, hint, defaults) }
        }
        let held: HintRules.HeldBack? = HintRules.heldBack(hint, situation)
        if held == .expired { retire(hint, reason: .expired) }
        return held
    }

    /// What `controller` holds now for `hint`'s rules.
    func situation(_ hint: Hint, in controller: TerminalWindowController) -> HintRules.Situation {
        let uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
        let state: TabState? = controller.activeTab?.status.state
        return HintRules.Situation(tipsOn: tipsOn, record: record(hint), lastAnyShownAt: HintRules.lastAnyShownAt(defaults), now: Date(),
                                   noticeVisible: visible != nil || GitToast.isShowing, sinceKey: UserKeys.since,
                                   agentBusy: state == .working || state == .attention, windowAge: uptime - controller.madeAt)
    }

    /// `hint` came up: nothing else shows until it goes (noteHidden).
    func noteShown(_ hint: Hint) {
        visible = (hint, ProcessInfo.processInfo.systemUptime)
        post()
    }

    /// `hint` went: the time it was up counts as a showing from 1 s on.
    func noteHidden(_ hint: Hint) {
        guard let shown = visible, shown.hint == hint else { return }
        visible = nil
        noteExposure(hint, seconds: ProcessInfo.processInfo.systemUptime - shown.since)
    }

    /// `hint` was visible for `seconds`: counted from 1 s, which starts the day before any other hint, and retired at
    /// its limit.
    func noteExposure(_ hint: Hint, seconds: TimeInterval) {
        let now = Date()
        let (record, counted) = HintRules.noteExposure(hint, record(hint), seconds: seconds, now: now)
        guard counted else { return post() }
        HintRules.save(record, hint, defaults)
        HintRules.setLastAnyShownAt(now, defaults)
        post()
    }

    /// `hint` retires for good: its feature was used by any route, its × was clicked, or its 60 days passed. A
    /// retired hint keeps its first reason, and one up goes.
    func retire(_ hint: Hint, reason: HintRules.Retirement) {
        let current: HintRules.Record = record(hint)
        guard current.retired == nil else { return }
        HintRules.save(HintRules.retire(current, reason), hint, defaults)
        if visible?.hint == hint { visible = nil }
        post()
    }

    /// Reset Tips (Settings › General) and Help › Show Tips Again: every tip seen or closed shows again, on its
    /// trigger. The features' own settings stay.
    func reset() {
        HintRules.reset(defaults)
        visible = nil
        post()
    }

    /// Once, on the first launch with hints: a hint whose feature is in use already retires, so nobody who moved the
    /// column or pinned it is taught it after the update. The rest wait for their trigger, as a new user's do.
    func seed(columnSideChosen: Bool, columnExpandedEver: Bool) {
        guard !defaults.bool(forKey: HintRules.seededKey) else { return }
        defaults.set(true, forKey: HintRules.seededKey)
        let inUse = HintRules.InUse(columnSideChosen: columnSideChosen, columnExpandedEver: columnExpandedEver)
        for hint in HintRules.seeded(inUse) { retire(hint, reason: .actionPerformed) }
    }

    private func post() { NotificationCenter.default.post(name: Self.changed, object: nil) }
}
