import AppKit
import NextTermCore

/// Each restored pane's action, applied once (KTD3, KTD6). A note was shown before the shell started, and a tab on a
/// server connects by itself, so neither waits. A line put back, or an automatic resume, waits until the shell is ready:
/// its first prompt reported and bracketed paste on, so what is typed is inserted as text and never run. Its note said so
/// before the shell started (`RestoreNote.shownBeforeShell`): what happens then, unless the user types first. Automatic
/// resumes start 400 ms apart, the tabs in view first, and only they press Return. An action types only onto a line
/// nothing else reached (`RestoreLayout.LineWatch`): the user putting anything in the tab first (`TerminalTab.userInput`:
/// a key, a paste, a drop, Insert Path, a suggested command), or any text written into its shell, cancels it, and once a
/// resume is typed, withholds its Return. A shell not ready in time, or a session a process took since, gets a note that
/// says so. Until each action is applied its tab's record is saved as it was restored, so a restore that stops part-way
/// loses nothing.
///
/// In safe mode nothing waits for a shell: each tab shows what it held, until Keep As Is drops every action or Try Again
/// applies them, once.
@MainActor
final class RestoreActions {
    private struct Waiting {
        let tab: TerminalTab
        let plan: PanePlan
        /// When it started to wait, on the uptime clock.
        var since: TimeInterval
        /// Whether its line is still the restore's.
        let line: RestoreLayout.LineWatch
    }

    /// The panes still waiting, in reading order.
    private var waiting: [Waiting] = []
    /// Automatic resumes typed whose Return has not gone yet, by tab, each with its line as typed.
    private var typed: [UUID: RestoreLayout.LineWatch] = [:]
    /// Safe mode holds every action until Keep As Is or Try Again.
    private(set) var held: Bool
    private var queue = RestoreLayout.ResumeQueue()
    private var timer: Timer?
    /// Every action is applied, cancelled or dropped.
    var onSettled: (() -> Void)?
    /// Whether an automatic resume's session may still be resumed, read as it runs (KTD5): no process took it since.
    var sessionAvailable: (SessionSnapshot.Evidence) -> Bool = { (evidence: SessionSnapshot.Evidence) -> Bool in
        SessionLookup.live().available(evidence, home: NSHomeDirectory())
    }

    init(panes: [RestoredPane], safeMode: Bool) {
        held = safeMode
        let now = TerminalTab.now
        for pane in panes {
            let action = pane.plan.outcome.action
            let local = pane.tab.remote == nil
            let types = action.types
            let line = RestoreLayout.LineWatch(writes: pane.tab.view.inputWrites)
            let entry = Waiting(tab: pane.tab, plan: pane.plan, since: now, line: line)
            if types && local && pane.plan.line != nil {
                waiting.append(entry)
            } else if !(safeMode && local) {
                // Shown, or connecting: done. In safe mode a local tab's note waits with the rest.
                settle(pane.tab, .applied)
            } else {
                waiting.append(entry)
            }
        }
    }

    /// Whether any pane's action has not been applied, cancelled or dropped: one waiting for its shell, or a resume typed
    /// whose Return has not gone.
    var isWaiting: Bool { !waiting.isEmpty || !typed.isEmpty }

    /// Starts waiting for the shells; in safe mode, for Keep As Is or Try Again.
    func start() {
        guard !held else { return }
        // What is left in safe mode's notes only says what the tab held: nothing to apply.
        waiting.removeAll { (entry: Waiting) -> Bool in
            guard entry.plan.line == nil else { return false }
            settle(entry.tab, .applied)
            return true
        }
        guard !waiting.isEmpty else { return finished() }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // The common modes include a modal panel's: a resume does not wait for a dialog to close.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Try Again: each action is applied as after any restore, from now.
    func tryAgain() {
        guard held else { return }
        held = false
        let now = TerminalTab.now
        for index in waiting.indices { waiting[index].since = now }
        start()
    }

    /// Keep As Is: every action is dropped, and the tabs stay as they are.
    func keepAsIs() {
        guard held else { return }
        held = false
        for entry in waiting { settle(entry.tab, .dismissed) }
        waiting = []
        finished()
    }

    private func tick() {
        let now = TerminalTab.now
        var ready: [UUID] = []
        var left: [Waiting] = []
        for entry in waiting {
            let tab = entry.tab
            let state = RestoreLayout.readiness(integrated: tab.status.integrated, bracketedPaste: tab.view.getTerminal().bracketedPasteMode,
                                                userTyped: Self.taken(entry.line, in: tab), exited: tab.exited, waited: now - entry.since)
            switch state {
            case .waiting:
                left.append(entry)
            case .cancelled:
                settle(tab, .userInput)
            case .timedOut:
                if !tab.exited { Self.note(RestoreLayout.timedOutNote, in: tab) }
                settle(tab, .dismissed)
            case .ready where entry.plan.outcome == .resume:
                ready.append(tab.id)
                left.append(entry)
            case .ready:
                if let line = entry.plan.line { tab.view.typeIn(line) }
                settle(tab, .applied)
            }
        }
        waiting = left
        let visible = Set(left.filter { (entry: Waiting) -> Bool in entry.tab.status.visible }.map(\.tab.id))
        if let next = queue.next(ready: ready, visible: visible, now: now), let index = waiting.firstIndex(where: { $0.tab.id == next }) {
            resume(waiting.remove(at: index))
        }
        if !isWaiting { finished() }
    }

    /// An automatic resume: its session read again (KTD5), then the command the gate built, pasted, and its Return
    /// `RestoreLayout.returnDelay` later. A session a process took since goes on the line instead, unrun, as its resume
    /// command, and the tab says why.
    private func resume(_ entry: Waiting) {
        let tab = entry.tab
        let available = tab.restoredRecord?.agent.map(sessionAvailable) ?? false
        switch RestoreLayout.resumeStart(entry.plan, sessionAvailable: available) {
        case .putBack(let line, let note):
            if let note { Self.note(note, in: tab) }
            if let line { tab.view.typeIn(line) }
            settle(tab, .applied)
        case .run(let command):
            tab.view.typeIn(command)
            var line = entry.line
            line.typed(writes: tab.view.inputWrites)
            typed[tab.id] = line
            DispatchQueue.main.asyncAfter(deadline: .now() + RestoreLayout.returnDelay) { [weak self] in
                MainActor.assumeIsolated { self?.pressReturn(tab) }
            }
        }
    }

    /// A typed resume's Return, onto the line it typed alone: anything put there since leaves the line as it is, the
    /// command and what came after it, and nothing runs.
    private func pressReturn(_ tab: TerminalTab) {
        guard let line = typed.removeValue(forKey: tab.id) else { return }
        let after = RestoreLayout.afterResumeTyped(lineTaken: Self.taken(line, in: tab), exited: tab.exited)
        if after == .press { tab.view.send(txt: "\r") }
        settle(tab, after.event)
        if !isWaiting { finished() }
    }

    /// Whether anything but the restore reached the tab's line since `line` was taken.
    private static func taken(_ line: RestoreLayout.LineWatch, in tab: TerminalTab) -> Bool {
        line.taken(userTyped: tab.touchedByUser, writes: tab.view.inputWrites)
    }

    /// A note after the shell started, on a line of its own: what happened is not what the tab said before it started.
    private static func note(_ text: String, in tab: TerminalTab) {
        tab.view.feed(text: "\r\n" + RestoreLayout.noteLine(text))
    }

    /// The pane's action moves on (applied, cancelled by the user, dropped), and its record with it.
    private func settle(_ tab: TerminalTab, _ event: SessionSnapshot.PendingAction.Event) {
        let next = tab.restoredRecord?.pending?.after(event)
        tab.restoredRecord?.pending = next
    }

    private func finished() {
        timer?.invalidate()
        timer = nil
        waiting = []
        onSettled?()
    }
}
