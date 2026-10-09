import AppKit
import NextTermCore

/// Each restored pane's action, applied once (KTD3, KTD6). A note was shown before the shell started, and a tab on a
/// server connects by itself, so neither waits. A line put back, or an automatic resume, waits until the shell is ready:
/// its first prompt reported and bracketed paste on, so what is typed is inserted as text and never run. Automatic
/// resumes start 400 ms apart, the tabs in view first, and only they press Return. The user typing in a tab first (a key,
/// a paste, a drop) cancels its action; a shell not ready in time gets a note instead. Until each action is applied its
/// tab's record is saved as it was restored, so a restore that stops part-way loses nothing.
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
    }

    /// The panes still waiting, in reading order.
    private var waiting: [Waiting] = []
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
            let types = action == .resume || action == .onTheLine || action == .typeIn
            if types && local && pane.plan.line != nil {
                waiting.append(Waiting(tab: pane.tab, plan: pane.plan, since: now))
            } else if !(safeMode && local) {
                // Shown, or connecting: done. In safe mode a local tab's note waits with the rest.
                settle(pane.tab, .applied)
            } else {
                waiting.append(Waiting(tab: pane.tab, plan: pane.plan, since: now))
            }
        }
    }

    /// Whether any pane's action has not been applied, cancelled or dropped.
    var isWaiting: Bool { !waiting.isEmpty }

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
                                                userTyped: tab.touchedByUser, exited: tab.exited, waited: now - entry.since)
            switch state {
            case .waiting:
                left.append(entry)
            case .cancelled:
                settle(tab, .userInput)
            case .timedOut:
                if !tab.exited { tab.view.feed(text: "\r\n" + RestoreLayout.noteLine(Self.timedOutNote)) }
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
        if waiting.isEmpty { finished() }
    }

    /// An automatic resume: the command the gate built, pasted, then Return. A session a process took since goes on the
    /// line instead, unrun, as its resume command; so does one the user typed over before Return.
    private func resume(_ entry: Waiting) {
        let tab = entry.tab
        guard let command = entry.plan.line, let evidence = tab.restoredRecord?.agent, sessionAvailable(evidence) else {
            if let line = entry.plan.note.line { tab.view.typeIn(line) }
            return settle(tab, .applied)
        }
        tab.view.typeIn(command)
        settle(tab, .applied)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak tab] in
            guard let tab, !tab.exited, !tab.touchedByUser else { return }
            tab.view.send(txt: "\r")
        }
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

    static let timedOutNote = "The shell was not ready in time, so nothing was typed."
}
