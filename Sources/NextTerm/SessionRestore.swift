import AppKit
import NextTermCore

/// The sessions folder this launch holds, and its one writer (KTD1, KTD18). At launch (`launch`, the launch hook) it
/// takes the folder, when no other Next Term holds it, reads what the last update, quit or crash left, and brings it back
/// as the restore step decides (LaunchDecision.restoring): every window, tab and split built in one turn
/// (SessionRestoreBuild), then each pane's action applied once its shell is ready (RestoreActions). From then on it saves
/// the session every 2 seconds when anything saved changed (`SessionWriter`), once the save gate opens: when the launch's
/// windows are built. At every quit that holds the folder, `finishAtQuit` writes the quit's last save, in order: the
/// state file, scrollback, the update's marker; then Updater spawns the install script, and the tabs are terminated.
///
/// A copy of Next Term that cannot take the folder, or runs translocated, restores and saves nothing. Neither does the plain self-test; the
/// relaunch harness restores and saves in its own folder (`SelfTest.sessionsParent`).
@MainActor
final class SessionRestore {
    static let shared = SessionRestore()

    /// Where the launch's restore is: MCP reads it to know which tools a tab may take.
    enum Phase: Sendable {
        /// Nothing is being restored.
        case normal
        /// Restored tabs wait for their actions.
        case restoringTabs
        /// The layout came back with nothing typed or run, until "Try Again".
        case safeMode
        /// Every restored tab's action has run, or been cancelled.
        case done
    }

    private(set) var phase = Phase.normal

    /// What the launch found in the sessions folder before it wrote anything, and what it decided.
    struct Found {
        /// The snapshot the last quit or crash left, else its previous file; nil when neither reads.
        var snapshot: SessionSnapshot?
        /// Every name in the folder.
        var names: [String]
        /// The install script's result, taken from the folder.
        var installResult: InstallResult?
        var decision: RestoreDecision
    }

    private(set) var found: Found?
    /// The folder, held for as long as Next Term runs; nil when another Next Term holds it.
    private(set) var files: SessionFiles?
    private var writer: SessionWriter?
    private let queue = DispatchQueue(label: "Next Term session saves", qos: .utility)
    private var timer: Timer?
    /// A periodic save is on the queue: the next tick waits for it.
    private var saving = false
    /// The restored panes' actions, while any waits (or safe mode holds them).
    private(set) var actions: RestoreActions?
    /// The quit consent (R30): the user let this quit go ahead with the resume box checked, on the dialog that carried it.
    /// Set by that press, once the quit goes ahead (AppDelegate, QuitAsking); cleared as each quit starts asking and when
    /// it is cancelled, so none outlives its quit. Only a user's quit reads it.
    var quitConsent = false

    /// The last save's result: whether it was written, and the panes the file leaves out, which nothing may promise back.
    var lastSave: SessionWriter.SaveResult? { writer?.lastSave }

    // MARK: the launch

    /// The launch hook (KTD14), after the zsh integration is written and before the self-test branch and
    /// `--open-request`: a request launch restores too, so the quit's session is not lost to its first save (R32).
    ///
    /// It takes the sessions folder (`SessionLaunch.takeFolder`: the app's own, the one the install script names when it
    /// opens the old app from its backup, none for a translocated copy) and sweeps the folders of copies gone a while,
    /// raises the restore attempts counter, claims the update's marker and reads the snapshot (SessionLaunch), and the
    /// restore step decides. What the decision uses up (the marker, a quit consent id) is recorded before anything is
    /// restored. Scrollback is read for an update or quit restore, and removed unread otherwise. Remote saving is held
    /// while the windows are built, synchronously, so no MCP call runs meanwhile; each pane's action then waits for its
    /// shell. Safe mode builds the layout alone and asks Keep As Is or Try Again; a snapshot set aside is said once. Then
    /// saving starts. Returns the launch table's restore input: windows built, or none, and plan 005's rows apply.
    func launch(settings: LaunchSettings) -> LaunchRestoreResult {
        guard files == nil, let parent = SelfTest.sessionsParent else { return .notRun }
        let taken = SessionLaunch.takeFolder(in: parent, bundlePath: Bundle.main.bundlePath, arguments: CommandLine.arguments)
        let kept: Set<String> = taken.map { (files: SessionFiles) -> Set<String> in [files.key] } ?? []
        DispatchQueue.global(qos: .utility).async { SessionFiles.sweepSiblings(in: parent, keeping: kept) }
        guard let files = taken else { return .notRun }
        self.files = files
        let names: [String] = (try? files.names()) ?? []
        let version = Updater.shared.current?.description ?? ""
        let read = SessionLaunch.read(files, version: version, resumesAtLaunch: settings.opens == .lastProjects)
        let decision = LaunchDecision.restoring(read.facts)
        found = Found(snapshot: read.snapshot, names: names, installResult: read.facts.installResult, decision: decision)
        // A quit consent lets agents resume once: only when its id is on record as used before the restore runs.
        let recorded = SessionLaunch.record(decision, consumed: read.facts.consumed, in: files)
        _ = try? files.sweep()
        let scrollback = takeScrollback(decision, snapshot: read.snapshot, files: files)
        writer = SessionWriter(files: files, after: read.snapshot?.header.generation ?? 0, bootSession: UpdateMarker.currentBootSession())
        startSaving()
        var opened = false
        switch decision.kind {
        case .restore(let kind):
            let consent = decision.consentHolds(recorded: recorded)
            if let snapshot = read.snapshot { opened = restore(snapshot, kind: kind, safeMode: false, consent: consent, scrollback: scrollback) }
        case .safeMode(let kind):
            if let snapshot = read.snapshot { opened = restore(snapshot, kind: kind, safeMode: true, consent: false, scrollback: [:]) }
        case .quarantine:
            setAside(files)
        case .normal:
            break
        }
        openGate()
        if decision.attemptsReset == .afterLaunch { settle(after: RestoreAttempts.settleTime) }
        return decision.launchRestore(openedWindow: opened)
    }

    /// The scrollback an update or quit restore reads, by the name its panes give it: each file removed once read, and
    /// every other removed unread (KTD9).
    private func takeScrollback(_ decision: RestoreDecision, snapshot: SessionSnapshot?, files: SessionFiles) -> [UUID: String] {
        guard decision.scrollback == .read, let snapshot else {
            ScrollbackText.removeAll(from: files)
            return [:]
        }
        let ids = Set(snapshot.panes.compactMap(\.scrollback))
        return ScrollbackText.take(ids, quit: decision.scrollbackQuit, from: files)
    }

    /// Builds the snapshot's windows in this turn (KTD10) and hands each pane's action to `RestoreActions`. Nothing a
    /// request names has opened yet: AppDelegate holds what `application(_:open:)` names until this has run, and opens it
    /// after, in front of these windows (R32). True when a window was built.
    private func restore(_ snapshot: SessionSnapshot, kind: SessionSnapshot.RestoreKind, safeMode: Bool, consent: Bool,
                         scrollback: [UUID: String]) -> Bool {
        RemoteConnection.holdRestore()
        let planned = RestorePlanning.plan(snapshot, kind: kind, safeMode: safeMode, quitConsent: consent)
        let savedAt: ScrollbackText.SavedAt? = kind == .update ? .update : kind == .quit ? .quit : nil
        let built = RestoreBuild.build(snapshot, planned: planned, scrollback: scrollback, savedAt: savedAt)
        RemoteConnection.releaseRestore(kept: built.keptRemote)
        RemoteConnection.tellSkipped(built.skipped, kept: false)
        let actions = RestoreActions(panes: built.panes, safeMode: safeMode)
        MCPRestoredTabs.restored(built.panes)
        self.actions = actions
        actions.onSettled = { [weak self] in self?.restoreSettled() }
        phase = safeMode ? .safeMode : .restoringTabs
        actions.start()
        if safeMode { DispatchQueue.main.async { SessionRestoreAlerts.askAfterSafeMode() } }
        return !built.windows.isEmpty
    }

    /// Safe mode's Try Again (R21): one more try, counted first, applies each pane's action. A try the folder refuses to
    /// count runs nothing, as a launch's does (`LaunchDecision.restoring`): if it crashed, the next launch would not know.
    /// Its actions are then dropped, as Keep As Is drops them. False when it ran nothing.
    func tryAgain() -> Bool {
        guard phase == .safeMode, let actions, let files else { return false }
        guard SessionLaunch.count(.tryAgain, in: files) != nil else {
            actions.keepAsIs()
            return false
        }
        phase = .restoringTabs
        actions.tryAgain()
        return true
    }

    /// Safe mode's Keep As Is: every action dropped, and the tabs stay as they are.
    func keepAsIs() {
        guard phase == .safeMode, let actions else { return }
        actions.keepAsIs()
    }

    /// Every restored pane's action ran, was cancelled by the user, or was dropped: the restore is done, and the counter
    /// resets a minute on (KTD13).
    private func restoreSettled() {
        phase = .done
        actions = nil
        settle(after: RestoreAttempts.settleTime)
    }

    /// Three restores did not finish: the snapshot is set aside, its tries start over, and one alert says where it went.
    private func setAside(_ files: SessionFiles) {
        let name = SessionLaunch.setAside(in: files)
        if name != nil {
            SessionLaunch.count(.setAside, in: files)
        } else {
            settle(after: RestoreAttempts.settleTime)
        }
        let folder = files.url.path
        DispatchQueue.main.async { SessionRestoreAlerts.tellSetAside(folder: folder, name: name) }
    }

    /// Resets the restore attempts counter `delay` from now, unless Next Term quits first (a quit resets it itself).
    private func settle(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                let sessions = SessionRestore.shared
                guard let files = sessions.files, !AppDelegate.shared.isTerminating, sessions.phase != .safeMode,
                      sessions.actions == nil else { return }
                SessionLaunch.count(.settled, in: files)
            }
        }
    }

    /// The periodic saves, which wait for `openGate`.
    private func startSaving() {
        let timer = Timer(timeInterval: SessionWriter.interval, repeats: true) { _ in
            MainActor.assumeIsolated { SessionRestore.shared.tick() }
        }
        // The common modes include a modal panel's: a session is saved while a dialog is up too.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Lets saving start: the launch's windows are built, or there was nothing to build.
    func openGate() {
        writer?.openGate()
    }

    /// A periodic save: the windows captured now, written on the writer's queue when anything saved changed.
    private func tick() {
        guard let writer, !saving, !AppDelegate.shared.isTerminating, !writer.isWaiting(at: Date()) else { return }
        let windows = SessionCapture.windows(AppDelegate.shared.controllers)
        saving = true
        queue.async {
            _ = writer.save(windows)
            DispatchQueue.main.async { MainActor.assumeIsolated { SessionRestore.shared.saving = false } }
        }
    }

    // MARK: the quit

    /// What the install script is handed: where to leave its result, the marker the state file waits for, and the folder
    /// key an old app opened from its backup finds its sessions by. All nil when this launch holds no folder.
    struct Finished {
        var folder: String?
        var marker: UUID?
        var folderKey: String?
    }

    /// The quit's last save (KTD18), on every quit that holds the folder: the periodic saves stop, the windows are captured
    /// (each agent's evidence read again, before any signal reaches its tab), each tab's scrollback too when the quit saves
    /// the whole session and `keepScrollback` is on, the tabs in view first (`SessionWriter.scrollbackOrder`), until the
    /// quit's time budget runs out. Then the writer saves the state file, the scrollback and the marker, after any save in
    /// flight.
    func finishAtQuit(_ intent: QuitIntent, keepScrollback: Bool) -> Finished {
        guard let writer, let files else { return Finished() }
        timer?.invalidate()
        timer = nil
        let controllers = AppDelegate.shared.controllers
        let tabs: [TerminalTab] = controllers.flatMap(\.tabs)
        let deadline = Date().addingTimeInterval(SessionWriter.quitBudget(tabs: tabs.count))
        var captures: [SessionScrollback.Capture] = []
        var named: [UUID: UUID] = [:]
        if intent.savesSession && keepScrollback {
            let fronts: [TerminalTab] = controllers.compactMap(\.activeTab)
            let ordered = SessionWriter.scrollbackOrder(tabs, visible: { (tab: TerminalTab) -> Bool in tab.status.visible },
                                                        inFront: { (tab: TerminalTab) -> Bool in fronts.contains { $0 === tab } })
            for tab in ordered {
                guard Date() < deadline else { break }
                let capture = SessionScrollback.capture(tab)
                captures.append(capture)
                named[tab.id] = capture.id
            }
        }
        let windows = SessionCapture.windows(controllers, scrollback: named)
        let scrollback: [QuitScrollback] = captures.map { (capture: SessionScrollback.Capture) -> QuitScrollback in
            QuitScrollback(id: capture.id) { capture.text() }
        }
        let saved = writer.finish(intent, windows: windows, scrollback: scrollback, deadline: deadline)
        return Finished(folder: files.url.path, marker: saved.awaitedMarker, folderKey: files.key)
    }
}
