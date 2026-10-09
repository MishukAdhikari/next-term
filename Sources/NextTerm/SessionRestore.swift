import AppKit
import NextTermCore

/// The sessions folder this launch holds, and its one writer (KTD1, KTD18). At launch it takes the folder, when no other
/// Next Term holds it, and reads what the last quit or crash left. From then on it saves the session every 2 seconds
/// when anything saved changed (`SessionWriter`), once the save gate opens: when the launch's windows are built, or 10
/// seconds on. At every quit that holds the folder, `finishAtQuit` writes the quit's last save, in order: the state file,
/// scrollback, the update's marker; then Updater spawns the install script, and the tabs are terminated.
///
/// A copy of Next Term that cannot take the folder saves nothing. Neither does the plain self-test; the relaunch harness
/// saves in its own folder (`SelfTest.sessionsParent`).
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

    /// What the launch found in the sessions folder before it wrote anything.
    struct Found {
        /// The snapshot the last quit or crash left, else its previous file; nil when neither reads.
        var snapshot: SessionSnapshot?
        /// Every name in the folder.
        var names: [String]
    }

    private(set) var found: Found?
    /// The folder, held for as long as Next Term runs; nil when another Next Term holds it.
    private(set) var files: SessionFiles?
    private var writer: SessionWriter?
    private let queue = DispatchQueue(label: "Next Term session saves", qos: .utility)
    private var timer: Timer?
    /// A periodic save is on the queue: the next tick waits for it.
    private var saving = false
    /// The quit consent (R30): the user let this quit go ahead with the resume box checked, on the dialog that carried it.
    /// Set by that press and cleared when the quit is cancelled; only a user's quit reads it. No quit dialog carries the
    /// box yet, so no quit has it.
    var quitConsent = false

    /// The last save's result: whether it was written, and the panes the file leaves out, which nothing may promise back.
    var lastSave: SessionWriter.SaveResult? { writer?.lastSave }

    // MARK: the launch

    /// Takes the sessions folder for this launch and starts the periodic saves, which wait for `openGate`. What the folder
    /// held is read first (`found`). No launch restores from it yet, so the scrollback a quit saved is removed unread
    /// (KTD9), with any temporary file a cut-off save left.
    func start() {
        guard files == nil, let parent = SelfTest.sessionsParent,
              let files = try? SessionFiles.open(in: parent, bundlePath: Bundle.main.bundlePath), files.lock() else { return }
        self.files = files
        let snapshot = SessionWriter.load(from: files)
        found = Found(snapshot: snapshot, names: (try? files.names()) ?? [])
        _ = try? files.sweep()
        ScrollbackText.removeAll(from: files)
        writer = SessionWriter(files: files, after: snapshot?.header.generation ?? 0, bootSession: UpdateMarker.currentBootSession())
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
    /// the whole session and `keepScrollback` is on, the visible tab first, until the quit's time budget runs out. Then the
    /// writer saves the state file, the scrollback and the marker, after any save in flight.
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
            for tab in Self.scrollbackOrder(tabs) {
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

    /// The tabs whose scrollback is read first: the one the user is looking at, then each window's tab in front, then the
    /// rest, in window order. A budget that runs out drops the last.
    private static func scrollbackOrder(_ tabs: [TerminalTab]) -> [TerminalTab] {
        let fronts: [TerminalTab] = AppDelegate.shared.controllers.compactMap(\.activeTab)
        func rank(_ tab: TerminalTab) -> Int {
            if tab.status.visible { return 0 }
            return fronts.contains { $0 === tab } ? 1 : 2
        }
        let ranked: [(offset: Int, element: TerminalTab)] = Array(tabs.enumerated())
        let sorted = ranked.sorted { (a: (offset: Int, element: TerminalTab), b: (offset: Int, element: TerminalTab)) -> Bool in
            let left = rank(a.element)
            let right = rank(b.element)
            return left != right ? left < right : a.offset < b.offset
        }
        return sorted.map(\.element)
    }
}
