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
/// says so, fed once what the shell printed is between sequences. Until each action is applied its tab's record is saved
/// as it was restored, so a restore that stops part-way loses nothing.
///
/// An automatic resume's action settles only after its start watch (StartWatcher): once its agent has started, or once
/// a start that failed has put its plain resume form back on the line. An agent's line put back is watched too, when the
/// user runs it.
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
    /// Automatic resumes typed whose Return has not gone yet, by tab, each with its line as typed and its plan.
    private var typed: [UUID: (line: RestoreLayout.LineWatch, plan: PanePlan)] = [:]
    /// Automatic resumes whose Return went, by tab, until their start watch settles (KTD6).
    private var watching: [UUID: StartWatcher] = [:]
    /// Safe mode holds every action until Keep As Is or Try Again.
    private(set) var held: Bool
    private var queue = RestoreLayout.ResumeQueue()
    private var timer: Timer?
    /// Every action is applied, cancelled or dropped.
    var onSettled: (() -> Void)?
    /// Whether an automatic resume's session may still be resumed, read as it runs (KTD5): no process took it since.
    var sessionAvailable: (SessionSnapshot.Evidence) -> Bool = { (evidence: SessionSnapshot.Evidence) -> Bool in
        let home = RestorePlanning.agentHome
        return SessionLookup.live(home: home).available(evidence, home: home)
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
            // From the shell's first byte, which comes in a later turn: a note after it starts waits to be between sequences.
            if local { pane.tab.view.watchSequences() }
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

    /// Whether any pane's action has not been applied, cancelled or dropped: one waiting for its shell, a resume typed
    /// whose Return has not gone, or one whose start is watched.
    var isWaiting: Bool { !waiting.isEmpty || !typed.isEmpty || !watching.isEmpty }

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
                if let line = entry.plan.line {
                    tab.view.typeIn(line)
                    if entry.plan.outcome == .agentOnTheLine { StartWatcher.arm(tab, session: entry.plan.session?.id, line: line) }
                }
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
            if let line {
                tab.view.typeIn(line)
                StartWatcher.arm(tab, session: entry.plan.session?.id, line: line)
            }
            settle(tab, .applied)
        case .run(let command):
            tab.view.typeIn(command)
            var line = entry.line
            line.typed(writes: tab.view.inputWrites)
            typed[tab.id] = (line, entry.plan)
            DispatchQueue.main.asyncAfter(deadline: .now() + RestoreLayout.returnDelay) { [weak self] in
                MainActor.assumeIsolated { self?.pressReturn(tab) }
            }
        }
    }

    /// A typed resume's Return, onto the line it typed alone: anything put there since leaves the line as it is, the
    /// command and what came after it, and nothing runs. Once its Return goes, its start is watched (KTD6), and its
    /// action settles with the watch's verdict, which MCP reads from then on.
    private func pressReturn(_ tab: TerminalTab) {
        guard let held = typed.removeValue(forKey: tab.id) else { return }
        let after = RestoreLayout.afterResumeTyped(lineTaken: Self.taken(held.line, in: tab), exited: tab.exited)
        guard after == .press else {
            settle(tab, after.event)
            if !isWaiting { finished() }
            return
        }
        let id = tab.id
        let watcher = StartWatcher(tab, session: held.plan.session?.id, line: nil)
        watching[id] = watcher
        watcher.onSettled = { [weak self, weak tab] (report: StartWatch.Report) in
            guard let self else { return }
            self.watching[id] = nil
            if let tab {
                MCPRestoredTabs.started(tab, report)
                self.settle(tab, .applied)
            }
            if !self.isWaiting { self.finished() }
        }
        tab.view.send(txt: "\r")
        MCPRestoredTabs.started(tab, StartWatch.Report(verdict: .watching))
        watcher.begin()
    }

    /// Whether anything but the restore reached the tab's line since `line` was taken.
    private static func taken(_ line: RestoreLayout.LineWatch, in tab: TerminalTab) -> Bool {
        line.taken(userTyped: tab.touchedByUser, writes: tab.view.inputWrites)
    }

    /// A note after the shell started, on a line of its own: what happened is not what the tab said before it started.
    /// It is fed once what the shell printed is between sequences, so it never joins one the output left open.
    static func note(_ text: String, in tab: TerminalTab) {
        tab.view.feedBetweenSequences("\r\n" + RestoreLayout.noteLine(text))
    }

    /// The pane's action moves on (applied, cancelled by the user, dropped), and its record with it. No note follows.
    private func settle(_ tab: TerminalTab, _ event: SessionSnapshot.PendingAction.Event) {
        let next = tab.restoredRecord?.pending?.after(event)
        tab.restoredRecord?.pending = next
        tab.view.endSequenceWatch()
    }

    private func finished() {
        timer?.invalidate()
        timer = nil
        waiting = []
        onSettled?()
    }
}

/// The start watch for one tab (KTD6, StartWatch): for 5 seconds after an automatic resume's Return, or after the user
/// runs an agent's line the restore put back, it reads the shell's end mark and, for Claude Code, Codex and Qwen Code,
/// the session file of the agent the tab runs. A start that failed puts the agent's plain resume form back on the line,
/// unrun, once per tab, under a note that quotes the agent's error; a new session gets a note. A line it puts back is
/// watched the same way when the user runs it, and a second failure gives the note alone.
///
/// It reads the tab's command marks (`TerminalTab.onCommandMark`), one watcher per tab: the start mark says where the
/// agent's output begins, and the end mark brings its status, with the screen holding what the agent printed and nothing
/// after it. Notes and lines wait for the shell to read a line again, as the restore's own do, and nothing is typed
/// onto a line anything else reached first.
@MainActor
final class StartWatcher {
    /// The watcher each tab's command marks go to, by tab id.
    private static var byTab: [UUID: StartWatcher] = [:]
    /// The most rows of output read for the agent's error.
    static let rowsRead = 60

    private weak var tab: TerminalTab?
    private let tabID: UUID
    private let start: StartWatch.Start
    /// The tab had its one fallback already: a failure now gives the note alone.
    private let fallbackUsed: Bool
    /// The line on the prompt this waits for the user to run.
    private var armed: String?
    private var watch: StartWatch.Watch?
    /// The command watched started: the end mark after it is its own.
    private var started = false
    /// The first row of its output, scroll-invariant.
    private var outputRow: Int?
    /// The tab's writes into its shell when the watch began: any after them are the user's.
    private var writes = 0
    /// The agent's error, read at the end mark.
    private var error: String?
    private var lastRead: TimeInterval = -.infinity
    private var timer: Timer?
    /// After a verdict, what waits for the shell to read a line again, since when, and the line as it stood then.
    private var after: (verdict: StartWatch.Verdict, step: StartWatch.Step, since: TimeInterval, line: RestoreLayout.LineWatch)?
    /// A new session's note, shown once its agent ends: fed into a running agent's screen, it would break its drawing.
    private var heldNote: String?
    /// Told once, when the watch has settled and what it does is done.
    var onSettled: ((StartWatch.Report) -> Void)?

    /// A watch on what runs in `tab` for `session`, the one its agent's record and plan name: the restore's own resume
    /// (`line` nil), or `line`, a line put back. It takes the tab's command marks from now.
    init(_ tab: TerminalTab, session: String?, line: String?, fallbackUsed: Bool = false) {
        self.tab = tab
        tabID = tab.id
        let evidence = tab.restoredRecord?.agent ?? SessionSnapshot.Evidence(agent: .unknown)
        start = StartWatch.Start(evidence: evidence, session: session, line: line)
        self.fallbackUsed = fallbackUsed
        install()
    }

    /// Waits for the user to run `line`, an agent's line the restore put on `tab`'s prompt, unrun, for `session`. A line
    /// that names no session starts a new one, so there is nothing to watch.
    static func arm(_ tab: TerminalTab, session: String?, line: String, fallbackUsed: Bool = false) {
        guard session != nil, tab.remote == nil, tab.restoredRecord?.agent != nil else { return }
        let watcher = StartWatcher(tab, session: session, line: line, fallbackUsed: fallbackUsed)
        watcher.armed = line.trimmingCharacters(in: .whitespaces)
    }

    /// The Return went: the watch starts now.
    func begin() {
        guard let tab else { return finish(StartWatch.Report(verdict: .leftAsIs)) }
        watch = StartWatch.Watch(session: start.session, since: TerminalTab.now)
        writes = tab.view.inputWrites
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] (timer: Timer) in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func install() {
        Self.byTab = Self.byTab.filter { (entry: (key: UUID, value: StartWatcher)) -> Bool in entry.value.tab != nil }
        Self.byTab[tabID] = self
        tab?.onCommandMark = { [weak self] (event: ShellIntegration.Event) in self?.mark(event) }
    }

    /// Its command marks go to no watcher any more, unless another took them since.
    private func uninstall() {
        guard Self.byTab[tabID] === self else { return }
        Self.byTab[tabID] = nil
        tab?.onCommandMark = nil
    }

    /// A command mark, as it is read: nothing is fed from here.
    private func mark(_ event: ShellIntegration.Event) {
        guard let tab else { return }
        switch event {
        case .commandStarted(let line, _):
            if let armed {
                // The user ran something else: the line is theirs now, and nothing is watched.
                guard line.trimmingCharacters(in: .whitespaces) == armed else { return uninstall() }
                self.armed = nil
                begin()
            } else if watch == nil || started {
                return uninstall()
            }
            started = true
            outputRow = (tab.lastTextRow() ?? -1) + 1
        case .commandFinished(let status):
            if let note = heldNote {
                heldNote = nil
                uninstall()
                // Fed in a later turn: the terminal is still reading what brought the mark.
                DispatchQueue.main.async { [weak tab] in
                    MainActor.assumeIsolated {
                        if let tab, !tab.exited { RestoreActions.note(note, in: tab) }
                    }
                }
                return
            }
            guard started, var watch, watch.end == nil else { return }
            if tab.view.inputWrites != writes { watch.key() }
            watch.ended(status: status, at: TerminalTab.now)
            self.watch = watch
            error = StartWatch.error(in: printed(tab))
        default:
            break
        }
    }

    private func tick() {
        guard let tab else { return finish(StartWatch.Report(verdict: after?.verdict ?? .leftAsIs)) }
        let now = TerminalTab.now
        if let after { return apply(after, tab, now: now) }
        // The shell ended under it: nothing to fall back to.
        guard !tab.exited else { return finish(StartWatch.Report(verdict: .leftAsIs)) }
        guard var watch else { return }
        if tab.view.inputWrites != writes { watch.key() }
        if watch.end == nil, start.agent.fileSource != nil, now - lastRead >= StartWatch.fileInterval {
            lastRead = now
            watch.read(sessionFile: sessionFile(tab))
        }
        self.watch = watch
        let verdict = watch.verdict(at: now)
        guard verdict.settled else { return }
        self.watch = nil
        let step = StartWatch.step(verdict, start: start, fallbackUsed: fallbackUsed, error: error)
        switch (verdict, step) {
        case (_, .nothing):
            finish(StartWatch.Report(verdict: verdict))
        case (.newSession, .note(let note)):
            // The agent runs, in another session: its note waits for it to end, and MCP has it now.
            heldNote = note
            finish(StartWatch.Report(verdict: verdict, note: note), keepingMarks: true)
        default:
            after = (verdict, step, now, RestoreLayout.LineWatch(writes: tab.view.inputWrites))
        }
    }

    /// After a failed start, once the shell reads a line again: the note, then the plain resume form on the line, unrun,
    /// which is watched in turn when the user runs it. Anything put on the line first, or a shell not ready in time, gets
    /// the note alone, and nothing is typed.
    private func apply(_ after: (verdict: StartWatch.Verdict, step: StartWatch.Step, since: TimeInterval, line: RestoreLayout.LineWatch),
                       _ tab: TerminalTab, now: TimeInterval) {
        let taken = after.line.taken(userTyped: false, writes: tab.view.inputWrites)
        let state = RestoreLayout.readiness(integrated: tab.status.integrated, bracketedPaste: tab.view.getTerminal().bracketedPasteMode,
                                            userTyped: taken, exited: tab.exited, waited: now - after.since)
        switch (state, after.step) {
        case (.waiting, _):
            return
        case (.ready, .putBack(let line, let note)):
            RestoreActions.note(note, in: tab)
            tab.view.typeIn(line)
            finish(StartWatch.Report(verdict: after.verdict, note: note, lineBack: true))
            StartWatcher.arm(tab, session: start.session, line: line, fallbackUsed: true)
        case (.ready, .note(let note)):
            RestoreActions.note(note, in: tab)
            finish(StartWatch.Report(verdict: after.verdict, note: note))
        default:
            let alone = StartWatch.step(after.verdict, start: start, fallbackUsed: true, error: error)
            guard case .note(let note) = alone else { return finish(StartWatch.Report(verdict: after.verdict)) }
            if !tab.exited { RestoreActions.note(note, in: tab) }
            finish(StartWatch.Report(verdict: after.verdict, note: note))
        }
    }

    /// Done: the timer stops, the marks go to no one (unless a new session's note waits for its agent to end), and the
    /// verdict is told, once.
    private func finish(_ report: StartWatch.Report, keepingMarks: Bool = false) {
        timer?.invalidate()
        timer = nil
        after = nil
        watch = nil
        if !keepingMarks { uninstall() }
        let told = onSettled
        onSettled = nil
        told?(report)
    }

    /// The id the session file of the agent the tab runs names, read now: Claude Code's, Codex's or Qwen Code's own
    /// record of that process (ProcessInspector.agentEvidence). Nil when it names none, or the tab runs another agent.
    private func sessionFile(_ tab: TerminalTab) -> String? {
        guard let source = start.agent.fileSource else { return nil }
        let read = ProcessInspector.agentEvidence(ptyFileDescriptor: tab.view.process.childfd, shellPid: tab.view.process.shellPid,
                                                  status: tab.status, home: RestorePlanning.agentHome)
        guard let read, read.agent == start.agent, read.source == source else { return nil }
        return read.sessionID
    }

    /// What the command printed, from its first row of output to the last row with text, wrapped rows joined: at most
    /// `rowsRead` rows, the last ones.
    private func printed(_ tab: TerminalTab) -> [String] {
        let terminal = tab.view.getTerminal()
        guard let first = outputRow, let last = tab.lastTextRow() else { return [] }
        let from = max(first, last - Self.rowsRead + 1, terminal.buffer.totalLinesTrimmed)
        guard from <= last else { return [] }
        var lines: [String] = []
        for row in from...last {
            guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
            let text = line.translateToString(trimRight: true)
            if line.isWrapped, !lines.isEmpty {
                lines[lines.count - 1] += text
            } else {
                lines.append(text)
            }
        }
        return lines
    }
}
