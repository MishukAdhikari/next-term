import Foundation

// The update sheet's one state machine (plan 003's U11, R14-R19, R28, KTD2, KTD16): what the sheet shows of each tab, its
// summary, its buttons in each state, the wait for busy tabs, and the update consent, which only "Update Now", or "Wait
// for Them" at its countdown's end, creates. The sheet's lines come from the restore planner (RestorePlanner), run on
// the open windows as the relaunch would run it, so the sheet promises only what the restore does.
//
// States: Idle (nothing busy), Busy (a local tab has an agent working or waiting on the user, a running command, or a
// background or suspended job), Waiting (after "Wait for Them"), Countdown (every waited tab is done). No button is the
// default in any state, so Return confirms nothing: the sheet opens by itself, often while the user types.

/// Why an update can't keep sessions: the box is unchecked and dimmed, and this line says why.
public enum KeepRefusal: Equatable, Sendable {
    /// The app runs from a translocated copy, which the relaunch will not find again.
    case translocated
    /// The last save failed, or the save gate is still closed.
    case notSaved

    public var text: String {
        switch self {
        case .translocated:
            return "Next Term is running from a temporary location, so your sessions can’t be kept. Move it to Applications to "
                + "keep them next time."
        case .notSaved:
            return "Next Term could not save your sessions, so they won’t come back after this update."
        }
    }
}

/// One pane as the update sheet sees it: read from the open windows, and planned as the restore would plan it.
public struct UpdatePane: Equatable, Sendable {
    /// Its tab id.
    public var id: UUID
    /// The tab's title, or its folder.
    public var name: String
    /// A pane split off a tab: listed under it.
    public var split: Bool
    /// What the restore would do to it, and the planner's words for it.
    public var outcome: RestoreOutcome
    public var listLine: String
    /// An agent working or waiting on the user, a command running, or a background or suspended job. A remote tab is never
    /// busy.
    public var busy: Bool
    /// It runs an agent: taken out of the wait, its current turn stops.
    public var agent: Bool
    /// Only its background or suspended jobs make it busy ("Quitting stops…" names them too): taken out of the wait, they
    /// stop, and what runs in front comes back as planned.
    public var jobs = false
    /// A tab on a server.
    public var remote: Bool
    /// Its running command serves a URL, so it never ends by itself.
    public var serving: Bool
    /// The last save left it out: nothing may promise it back.
    public var leftOut: Bool

    public init(id: UUID, name: String, split: Bool = false, outcome: RestoreOutcome, listLine: String, busy: Bool = false,
                agent: Bool = false, remote: Bool = false, serving: Bool = false, leftOut: Bool = false) {
        self.id = id
        self.name = name
        self.split = split
        self.outcome = outcome
        self.listLine = listLine
        self.busy = busy
        self.agent = agent
        self.remote = remote
        self.serving = serving
        self.leftOut = leftOut
    }

    /// Busy, and local: only a local tab can be waited for.
    public var isBusy: Bool { busy && !remote }
}

/// A window's panes, in tab order, under the window's name (its project's folder, or its title).
public struct UpdateWindow: Equatable, Sendable {
    public var name: String
    public var panes: [UpdatePane]

    public init(name: String, panes: [UpdatePane]) {
        self.name = name
        self.panes = panes
    }
}

/// Every pane the relaunch would bring back, as planned now, and why sessions can't be kept, if they can't.
public struct UpdatePlan: Equatable, Sendable {
    public var windows: [UpdateWindow]
    public var refusal: KeepRefusal?

    public init(windows: [UpdateWindow], refusal: KeepRefusal? = nil) {
        self.windows = windows
        self.refusal = refusal
    }

    public var panes: [UpdatePane] { windows.flatMap(\.panes) }

    /// Without the panes in `ids`.
    func removing(_ ids: Set<UUID>) -> UpdatePlan {
        var plan = self
        for index in plan.windows.indices {
            plan.windows[index].panes.removeAll { (pane: UpdatePane) -> Bool in ids.contains(pane.id) }
        }
        return plan
    }
}

/// The update consent (KTD2): the press that lets the update's quit skip the busy question, with the box's state at the
/// press and the plan it covers. It lives in memory only, and only while its staged update exists.
public struct UpdateConsent: Equatable, Sendable {
    /// The staged version it was given for.
    public var version: String
    /// The box was checked: the quit saves the session for the relaunch to bring back.
    public var keep: Bool
    /// Each pane's outcome and whether it was busy, as the press saw them (KTD16 for "Wait for Them").
    public var covered: UpdatePlan

    public init(version: String, keep: Bool, covered: UpdatePlan) {
        self.version = version
        self.keep = keep
        self.covered = covered
    }
}

extension QuitIntent {
    /// The update quit's intent, from its consent: with the box checked the whole session and the marker, else the
    /// tombstone. Its install relaunches either way.
    public static func forUpdate(_ consent: UpdateConsent, from version: String) -> QuitIntent {
        .update(keep: consent.keep, from: version, to: consent.version)
    }

    /// The install script opens the new version once it is in: only the update quit's. Any other quit installs a staged
    /// update with relaunch off ("When I Quit", R17).
    public var relaunches: Bool {
        if case .update = self { return true }
        return false
    }
}

/// A button on the sheet or the wait panel. None is the default.
public enum UpdateButton: String, CaseIterable, Sendable {
    case waitForThem = "Wait for Them"
    case updateNow = "Update Now"
    case whenIQuit = "When I Quit"
    case stopWaiting = "Stop Waiting"
    case cancel = "Cancel"

    public var title: String { rawValue }
    /// Return presses no button (R15).
    public var isDefault: Bool { false }
}

/// One line of "Show Details": a window's name, or a pane's.
public struct UpdateDetail: Equatable, Sendable {
    /// "app", or "<title or folder>: <outcome>".
    public var text: String
    /// VoiceOver's: "<title or folder>, <outcome>".
    public var label: String
    /// 0 for a window, 1 for a tab, 2 for a pane split off it.
    public var indent: Int
    public var pane: UUID?
    /// The line made the plan worse since the sheet last showed.
    public var changed: Bool
}

/// What the sheet shows and does, from its opening to the update quit or its closing.
public struct UpdateFlow: Equatable, Sendable {
    /// Where the sheet was opened from: a manual check with the update staged, the Update button, or the end of a
    /// download. Each reaches the same sheet.
    public enum Entry: CaseIterable, Sendable {
        case check, updateButton, download
    }

    public enum State: Equatable, Sendable {
        case idle, busy, waiting, countdown
    }

    /// What the app does after a press or a change.
    public enum Effect: Equatable, Sendable {
        case none
        /// Sets the update consent, then quits.
        case quit(UpdateConsent)
        /// Closes the sheet; the update stays staged ("When I Quit", "Cancel").
        case close
        /// Shows the wait panel.
        case startWait
        /// Shows "Updating in 10 s".
        case startCountdown
        /// Ends the wait: the panel closes, the MCP refusals lift, and the update stays staged.
        case endWait
        /// The plan got worse: the sheet shows again with the plan now, the changed lines marked.
        case showAgain
    }

    /// Where the box's last state is kept. It only sets how the box starts: it is never consent (R19, R28).
    public static let rememberKey = "resumeAfterUpdate"
    /// How long "Updating in 10 s" counts.
    public static let countdown: TimeInterval = 10
    public static let subtitle = "Next Term quits, installs the update and opens again."
    public static let checkboxTitle = "Reopen windows and resume sessions after the update"

    public let version: String
    /// The plan the sheet shows.
    public private(set) var plan: UpdatePlan
    public private(set) var state: State
    /// The box. Unchecked, and dimmed, when sessions can't be kept.
    public private(set) var keep: Bool
    /// The busy tabs waited for: each starts checked. Fixed when the wait starts, and then only shrinks (KTD16).
    public private(set) var waitSet: Set<UUID>
    /// The consent from "Wait for Them": set only at the countdown's end.
    public private(set) var consent: UpdateConsent?
    /// The plan the user saw when "Wait for Them" was pressed, and the tabs it waited for then.
    private var waitStart: (plan: UpdatePlan, waited: Set<UUID>)?
    /// The panes that made the plan worse, marked when the sheet shows again.
    private var changed: Set<UUID> = []

    public init(version: String, plan: UpdatePlan, remembered: Bool?, from entry: Entry = .updateButton) {
        self.version = version
        self.plan = plan
        keep = plan.refusal == nil && (remembered ?? true)
        waitSet = Set(plan.panes.filter(\.isBusy).map(\.id))
        state = waitSet.isEmpty ? .idle : .busy
    }

    public static func == (a: UpdateFlow, b: UpdateFlow) -> Bool {
        a.version == b.version && a.plan == b.plan && a.state == b.state && a.keep == b.keep && a.waitSet == b.waitSet
            && a.consent == b.consent && a.changed == b.changed && a.waitStart?.plan == b.waitStart?.plan
            && a.waitStart?.waited == b.waitStart?.waited
    }

    public var title: String { "Update Next Term to \(version)?" }

    /// The box can be changed: sessions can be kept.
    public var keepEnabled: Bool { plan.refusal == nil }

    public var buttons: [UpdateButton] {
        switch state {
        case .idle: return [.updateNow, .whenIQuit, .cancel]
        case .busy: return [.waitForThem, .updateNow, .cancel]
        case .waiting: return [.updateNow, .stopWaiting]
        case .countdown: return [.cancel]
        }
    }

    /// The busy tabs, listed first, each with its "Wait for this" checkbox.
    public var busyPanes: [UpdatePane] { plan.panes.filter(\.isBusy) }

    /// The box, in every state: the consent reads it at the press, or at the countdown's end.
    public mutating func setKeep(_ on: Bool) {
        guard keepEnabled else { return }
        keep = on
    }

    /// "Wait for this", for a busy tab, before the wait starts.
    public mutating func setWaited(_ pane: UUID, _ on: Bool) {
        guard state == .busy, busyPanes.contains(where: { (busy: UpdatePane) -> Bool in busy.id == pane }) else { return }
        if on { waitSet.insert(pane) } else { waitSet.remove(pane) }
    }

    /// Sessions are kept: the box is checked, and they can be.
    private var keeps: Bool { keep && keepEnabled }

    /// A pane's words, after its title or folder.
    public func line(_ pane: UpdatePane) -> String {
        if pane.leftOut { return "closes" }
        if pane.isBusy && state != .countdown {
            if waitSet.contains(pane.id) {
                return pane.serving ? "waited for, though it never ends by itself" : "waited for"
            }
            if pane.jobs {
                return "its jobs stop at the update" + (keeps ? "; " + pane.listLine : ", and it closes")
            }
            if pane.agent {
                return "its current turn stops at the update, " + (keeps ? "then " + pane.listLine : "and closes")
            }
            guard keeps else { return "stops at the update, and closes" }
            return pane.outcome == .commandOnTheLine ? "stops at the update, then goes back on the line"
                : "stops at the update, then gets a note"
        }
        if keeps { return pane.listLine }
        switch pane.outcome {
        case .reattach: return "reattaches"
        case .freshConnection: return "connection closes"
        default: return "closes"
        }
    }

    /// One line from the planner: each outcome counted, or "Every tab closes." with the box unchecked.
    public var summary: String {
        let panes = plan.panes
        guard keeps else {
            let reattach = panes.contains { (pane: UpdatePane) -> Bool in pane.outcome == .reattach && !pane.leftOut }
            return "Every tab closes." + (reattach ? " Kept remote tabs reattach." : "")
        }
        var counts: [Category: Int] = [:]
        for pane in panes { counts[Category(pane), default: 0] += 1 }
        let parts: [String] = Category.allCases.compactMap { (category: Category) -> String? in
            counts[category].map(category.words)
        }
        return parts.isEmpty ? "No tabs are open." : parts.joined(separator: " · ")
    }

    /// The outcomes the summary counts, in its order.
    private enum Category: CaseIterable {
        case resume, agentOnTheLine, commandOnTheLine, note, notKept, idle, reattach, freshConnection, closes

        init(_ pane: UpdatePane) {
            if pane.leftOut {
                self = .closes
                return
            }
            switch pane.outcome {
            case .resume: self = .resume
            case .agentOnTheLine: self = .agentOnTheLine
            case .commandOnTheLine: self = .commandOnTheLine
            case .agentNote, .agentHint, .commandNote: self = .note
            case .notKept: self = .notKept
            case .idle: self = .idle
            case .reattach: self = .reattach
            case .freshConnection: self = .freshConnection
            }
        }

        func words(_ count: Int) -> String {
            let one = count == 1
            switch self {
            case .resume: return one ? "1 agent resumes" : "\(count) agents resume"
            case .agentOnTheLine:
                return one ? "1 agent’s resume command goes on the line" : "\(count) agents’ resume commands go on the line"
            case .commandOnTheLine: return one ? "1 command goes back on the line" : "\(count) commands go back on the line"
            case .note: return one ? "1 tab gets a note" : "\(count) tabs get a note"
            case .notKept: return "\(count) not kept"
            case .idle: return one ? "1 tab opens in its folder" : "\(count) tabs open in their folders"
            case .reattach: return one ? "1 remote tab reattaches" : "\(count) remote tabs reattach"
            case .freshConnection: return one ? "1 connection closes" : "\(count) connections close"
            case .closes: return one ? "1 tab closes" : "\(count) tabs close"
            }
        }
    }

    /// "Show Details": each window by name, then its tabs in order, a split pane indented under its tab.
    public var details: [UpdateDetail] {
        var lines: [UpdateDetail] = []
        for window in plan.windows {
            lines.append(UpdateDetail(text: window.name, label: window.name, indent: 0, pane: nil, changed: false))
            for pane in window.panes {
                let words = line(pane)
                lines.append(UpdateDetail(text: pane.name + ": " + words, label: pane.name + ", " + words,
                                          indent: pane.split ? 2 : 1, pane: pane.id, changed: changed.contains(pane.id)))
            }
        }
        return lines
    }

    /// A press on the sheet, the wait panel or the countdown.
    public mutating func press(_ button: UpdateButton) -> Effect {
        guard buttons.contains(button) else { return .none }
        switch button {
        case .updateNow:
            return .quit(UpdateConsent(version: version, keep: keeps, covered: plan))
        case .whenIQuit:
            return .close
        case .cancel:
            if state == .countdown {
                endWait()
                return .endWait
            }
            return .close
        case .waitForThem:
            waitStart = (plan, waitSet)
            if waitSet.isEmpty {
                state = .countdown
                return .startCountdown
            }
            state = .waiting
            return .startWait
        case .stopWaiting:
            endWait()
            return .endWait
        }
    }

    private mutating func endWait() {
        waitStart = nil
        state = busyPanes.isEmpty ? .idle : .busy
    }

    /// The tabs now, while waiting: a waited tab that is no longer busy, or closed, is done and leaves the wait set. Once
    /// it is empty the countdown starts, even while a tab taken out still runs.
    public mutating func refresh(_ current: UpdatePlan) -> Effect {
        guard state == .waiting else { return .none }
        let stillBusy = Set(current.panes.filter(\.isBusy).map(\.id))
        waitSet = waitSet.intersection(stillBusy)
        guard waitSet.isEmpty else { return .none }
        state = .countdown
        return .startCountdown
    }

    /// The countdown's end: the plan again, compared with the one the consent from "Wait for Them" covers, which is the
    /// plan the user saw minus the waited tabs that finished, plus the tabs taken out. Not worse: that consent, and the
    /// quit. Worse: the sheet again, with the plan now and the changed lines marked.
    public mutating func countdownEnded(_ current: UpdatePlan) -> Effect {
        guard state == .countdown, let start = waitStart else { return .none }
        let covered = UpdateConsent(version: version, keep: keeps, covered: start.plan.removing(start.waited))
        guard let worse = Self.worse(current, than: covered) else {
            consent = covered
            return .quit(covered)
        }
        showAgain(current, marking: worse.panes)
        return .showAgain
    }

    /// The sheet shown again while it is up (the Update button, a check): the plan now, with the box, each "Wait for this"
    /// and the marked lines as the user left them. A tab newly busy joins the wait set; one the user took out stays out;
    /// one that finished leaves. While waiting nothing changes: the wait panel comes forward as it is.
    public mutating func replan(_ current: UpdatePlan) {
        guard state == .idle || state == .busy else { return }
        let wasBusy = Set(busyPanes.map(\.id))
        let busyNow = Set(current.panes.filter(\.isBusy).map(\.id))
        let takenOut = wasBusy.subtracting(waitSet)
        plan = current
        if !keepEnabled { keep = false }
        waitSet = busyNow.subtracting(takenOut)
        state = busyNow.isEmpty ? .idle : .busy
    }

    /// The sheet again, with `current` and the lines that made it worse marked.
    public mutating func showAgain(_ current: UpdatePlan, marking panes: Set<UUID>) {
        plan = current
        changed = panes
        consent = nil
        waitStart = nil
        if !keepEnabled { keep = false }
        waitSet = Set(current.panes.filter(\.isBusy).map(\.id))
        state = waitSet.isEmpty ? .idle : .busy
    }

    /// How a plan got worse than the one a consent covers.
    public struct Worsening: Equatable, Sendable {
        /// The panes that made it worse.
        public var panes: Set<UUID>
        /// Sessions the consent kept can't be kept any more.
        public var sessionsLost: Bool
    }

    /// Whether `current` is worse than the plan `consent` covers (KTD2): a tab busy that the covered plan did not hold as
    /// busy; a session the covered plan kept that can no longer be kept; a remote tab the covered plan brought back that
    /// would now be lost. Tabs that finished or closed, and a plan that got better, never count. Nil: not worse.
    public static func worse(_ current: UpdatePlan, than consent: UpdateConsent) -> Worsening? {
        var covered: [UUID: UpdatePane] = [:]
        for pane in consent.covered.panes where covered[pane.id] == nil { covered[pane.id] = pane }
        let keeps = consent.keep && consent.covered.refusal == nil
        var panes = Set<UUID>()
        for pane in current.panes {
            let before = covered[pane.id]
            if pane.isBusy && before?.isBusy != true {
                panes.insert(pane.id)
                continue
            }
            guard let before else { continue }
            let reattached = before.outcome == .reattach && !before.leftOut
            if reattached && (pane.outcome != .reattach || pane.leftOut) {
                panes.insert(pane.id)
                continue
            }
            guard keeps else { continue }
            if pane.leftOut && !before.leftOut {
                panes.insert(pane.id)
            } else if let was = keptRank(before.outcome), let now = keptRank(pane.outcome), now < was {
                panes.insert(pane.id)
            }
        }
        let lost = keeps && current.refusal != nil
        if panes.isEmpty && !lost { return nil }
        return Worsening(panes: panes, sessionsLost: lost)
    }

    /// How much of a session an outcome keeps: resumed, then put back on the line, then a note. Nil for an idle tab, which
    /// finished, and for a remote one, which the remote rule covers.
    private static func keptRank(_ outcome: RestoreOutcome) -> Int? {
        switch outcome {
        case .resume: return 3
        case .agentOnTheLine, .commandOnTheLine: return 2
        case .agentNote, .agentHint, .commandNote, .notKept: return 1
        case .idle, .reattach, .freshConnection: return nil
        }
    }

    /// The sheet never starts, and its quit never goes ahead, while a sheet is attached, a modal window is up, or a quit
    /// asks its questions. Checked at the start and again just before the quit.
    public static func mayStart(sheetAttached: Bool, modalWindow: Bool, askingToQuit: Bool) -> Bool {
        !sheetAttached && !modalWindow && !askingToQuit
    }

    /// Why the quit a press or the countdown's end asks for can't go ahead now, or nil when it can: a sheet, a modal
    /// window or a quit's question is up, or the staged update is no longer the one the consent was given for. Never a
    /// quiet no: the sheet or the wait panel says why, or the sheet shows for the version staged now.
    public static func quitRefusal(for consent: UpdateConsent, staged: String?, sheetAttached: Bool, modalWindow: Bool,
                                   askingToQuit: Bool) -> UpdateQuitRefusal? {
        guard mayStart(sheetAttached: sheetAttached, modalWindow: modalWindow, askingToQuit: askingToQuit) else { return .dialogOpen }
        return staged == consent.version ? nil : .otherVersion
    }

    /// The line the sheet or the wait panel shows when its quit waits for a dialog: Update Now is pressed again once it is
    /// closed; the countdown runs again by itself.
    public var heldLine: String {
        guard state == .countdown else {
            return "The update can’t start while a dialog or sheet is open. Close it, then click Update Now again."
        }
        return "The update starts once the open dialog or sheet is closed."
    }

    /// The one alert after a relaunch the install could not finish (R18), under "<version> was not installed". Nothing is
    /// staged after the relaunch, so the Update button offers the update again only once the check that runs then finds it.
    public static func installFailedText(_ outcome: InstallResult.Outcome) -> String {
        let opened = outcome == .failedRestoredBackup
            ? "The new version could not be put in place, so this version was opened from its backup."
            : "The new version could not be put in place, so this version opened again."
        return opened + " Next Term checks for it again now, and the Update button offers it once that check finds it."
            + "\n\nYou can download it from the release page instead."
    }

    /// The note, once, when the update did not install and no result said so.
    public static let didNotInstallText = "This version opened again. Next Term checks for the update again now, and the "
        + "Update button offers it once that check finds it."
}

/// Why an update quit can't go ahead now.
public enum UpdateQuitRefusal: Equatable, Sendable {
    /// A sheet is attached, a modal window is up, or a quit asks its questions.
    case dialogOpen
    /// The staged update is another version than the consent's, or none.
    case otherVersion
}

/// The agents' approval panels open now, as the update sees them (UpdateHolds): each one registered as it opens and let go
/// as it closes, held once and in the order it opened. Held weakly, so a panel let go of without closing is left out.
public struct OpenPanels<Panel: AnyObject> {
    private struct Entry {
        weak var panel: Panel?
    }

    private var entries: [Entry] = []

    public init() {}

    /// A panel opens. False when it is held already.
    @discardableResult
    public mutating func register(_ panel: Panel) -> Bool {
        entries.removeAll { $0.panel == nil }
        guard !entries.contains(where: { $0.panel === panel }) else { return false }
        entries.append(Entry(panel: panel))
        return true
    }

    /// A panel closes.
    public mutating func unregister(_ panel: Panel) {
        entries.removeAll { $0.panel == nil || $0.panel === panel }
    }

    /// The panels open now, in the order they opened.
    public var all: [Panel] {
        entries.compactMap(\.panel)
    }
}
