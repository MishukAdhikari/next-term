import AppKit
import NextTermCore

/// The restore's plan for every pane (RestorePlanner), read off the main thread within a fixed time budget (KTD10): the
/// folders first, each checked on its own, so one on a stalled network volume reads as not checked in time rather than
/// holding the launch; then the planner, with the gate's facts and the agents' session stores. A planner that does not
/// finish in time is replaced by one that reads nothing more: no agent resumes, and nothing is guessed.
enum RestorePlanning {
    /// How long the folder checks may take, all together.
    static let folderBudget: TimeInterval = 2
    /// How long the planner may take after them.
    static let planBudget: TimeInterval = 4

    /// Every pane's plan, and what was found of each folder in time.
    struct Planned {
        var plans: [PanePlan]
        var folders: [String: FolderCheck]

        /// The folder was found gone. One not checked in time may still be there.
        func isGone(_ path: String) -> Bool { folders[path] == .gone }
    }

    static func plan(_ snapshot: SessionSnapshot, kind: SessionSnapshot.RestoreKind, safeMode: Bool,
                     quitConsent: Bool) -> Planned {
        let home = NSHomeDirectory()
        let checks = check(folders(in: snapshot, home: home), within: folderBudget)
        let checkFolder = { (path: String) -> FolderCheck in checks[path] ?? .notChecked }
        let hosts = hostNames()
        let lookup = SessionLookup.live(home: home)
        let world = RestorePlanner.World(home: home, checkFolder: checkFolder, resumeFacts: { evidence, folder, projects in
            ResumeFacts.read(for: evidence, projects: projects, tabFolder: folder,
                             sessionAvailable: lookup.available(evidence, home: home), home: home)
        }, sessions: lookup, hostNames: hosts)
        let result = Result()
        let done = DispatchSemaphore(value: 0)
        let job = Job(snapshot: snapshot, kind: kind, safeMode: safeMode, quitConsent: quitConsent, world: world)
        DispatchQueue.global(qos: .userInitiated).async {
            result.set(job.run())
            done.signal()
        }
        if done.wait(timeout: .now() + planBudget) == .success, let plans = result.plans { return Planned(plans: plans, folders: checks) }
        // Out of time: the same plan with nothing more read. Folders keep what was found of them.
        let empty = SessionLookup(read: { _, _, _ in [] }, newest: { _, _, _, _ in nil })
        let blind = RestorePlanner.World(home: home, checkFolder: checkFolder, resumeFacts: { _, _, _ in ResumeFacts() },
                                         sessions: empty, hostNames: hosts)
        let plans = RestorePlanner.plan(snapshot, kind: kind, safeMode: safeMode, quitConsent: quitConsent, world: blind)
        return Planned(plans: plans, folders: checks)
    }

    /// The names the user gave hosts, by host id.
    static func hostNames() -> [String: String] {
        var names: [String: String] = [:]
        for host in RemoteHosts.all where names[host.id] == nil { names[host.id] = host.name }
        return names
    }

    /// Every folder the planner may ask about: each project, each local pane's folder and its session's, with the folders
    /// above them (a tab whose folder is gone opens in the nearest one left), and home.
    static func folders(in snapshot: SessionSnapshot, home: String) -> Set<String> {
        var paths: Set<String> = [home]
        func add(_ path: String?) {
            guard let path, let lexical = RestorePlanner.lexical(path) else { return }
            var current = lexical
            for _ in 0..<64 {
                paths.insert(current)
                guard current != "/" else { break }
                current = (current as NSString).deletingLastPathComponent
            }
        }
        for window in snapshot.windows { add(window.project) }
        for pane in snapshot.panes where pane.remote == nil {
            add(pane.folder)
            add(pane.agent?.sessionFolder)
        }
        return paths
    }

    /// Each of `paths` checked at once, each on its own: those not done within `budget` are left out, and read as not
    /// checked in time.
    static func check(_ paths: Set<String>, within budget: TimeInterval) -> [String: FolderCheck] {
        let found = Checks()
        let group = DispatchGroup()
        for path in paths {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                found.set(path, RestorePlanner.World.check(path))
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + budget)
        return found.all
    }

    /// The folder checks as they come in, from any thread.
    private final class Checks: @unchecked Sendable {
        private let lock = NSLock()
        private var found: [String: FolderCheck] = [:]

        func set(_ path: String, _ check: FolderCheck) {
            lock.lock()
            found[path] = check
            lock.unlock()
        }

        var all: [String: FolderCheck] {
            lock.lock()
            defer { lock.unlock() }
            return found
        }
    }

    /// The planner's answer, from its queue.
    private final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: [PanePlan]?

        func set(_ plans: [PanePlan]) {
            lock.lock()
            answer = plans
            lock.unlock()
        }

        var plans: [PanePlan]? {
            lock.lock()
            defer { lock.unlock() }
            return answer
        }
    }

    /// One planner run, handed to its queue whole.
    private struct Job: @unchecked Sendable {
        let snapshot: SessionSnapshot
        let kind: SessionSnapshot.RestoreKind
        let safeMode: Bool
        let quitConsent: Bool
        let world: RestorePlanner.World

        func run() -> [PanePlan] {
            RestorePlanner.plan(snapshot, kind: kind, safeMode: safeMode, quitConsent: quitConsent, world: world)
        }
    }
}

/// A restored pane: its tab, and what the restore does to it.
struct RestoredPane {
    let tab: TerminalTab
    let plan: PanePlan
}

/// The snapshot's windows built in one main-thread turn (KTD10): each window in its saved frame on a screen still
/// there, its tabs in order with their splits, divider positions, focused and zoomed pane, each pane in its folder with
/// its id, title, restored scrollback and note. Shells start once their pane has its real size; a tab on a server starts
/// once ssh's environment is read. A kept remote tab reattaches in its place, a plain one opens a fresh connection; a
/// host removed or re-pointed since is not followed.
@MainActor
enum RestoreBuild {
    struct Built {
        /// Front to back.
        var windows: [TerminalWindowController] = []
        var panes: [RestoredPane] = []
        /// The kept remote records the windows brought back: they wait for no other window.
        var keptRemote: [RemoteTabRecord] = []
        /// The plain remote tabs not reopened, and why.
        var skipped: [String] = []
    }

    static func build(_ snapshot: SessionSnapshot, planned: RestorePlanning.Planned, scrollback: [UUID: String],
                      savedAt: ScrollbackText.SavedAt?) -> Built {
        let app: AppDelegate = AppDelegate.shared
        var maker = PaneMaker(plans: planned.plans, scrollback: scrollback, savedAt: savedAt)
        maker.taken = Set(app.controllers.flatMap(\.tabs).map(\.id))
        let screens: [RestoreLayout.Screen] = NSScreen.screens.map { (screen: NSScreen) -> RestoreLayout.Screen in
            RestoreLayout.Screen(name: screen.localizedName, frame: frame(screen.frame))
        }
        var shown: [(controller: TerminalWindowController, window: SessionSnapshot.Window)] = []
        for window in snapshot.windows {
            guard let controller = build(window, screens: screens, gone: planned.isGone, maker: &maker) else { continue }
            shown.append((controller, window))
        }
        // Back to front, so the window used last ends in front, with the keyboard.
        for entry in shown.reversed() {
            app.openWindow(restored: entry.controller)
            if entry.window.minimized { entry.controller.window?.miniaturize(nil) }
        }
        for entry in shown where entry.window.fullScreen && !entry.window.minimized {
            entry.controller.window?.toggleFullScreen(nil)
        }
        let remote = maker.remoteToStart
        RemoteConnection.whenShellRead {
            for tab in remote where !tab.exited { tab.start() }
        }
        let windows: [TerminalWindowController] = shown.map(\.controller)
        return Built(windows: windows, panes: maker.panes, keptRemote: maker.keptRemote, skipped: maker.skipped)
    }

    /// One window, laid out and filled but not shown; nil when none of its tabs could be built.
    private static func build(_ window: SessionSnapshot.Window, screens: [RestoreLayout.Screen], gone: (String) -> Bool,
                              maker: inout PaneMaker) -> TerminalWindowController? {
        // A project folder gone since: a plain window, its tabs in the folders left.
        let project = window.project.flatMap { (path: String) -> String? in RestorePlanner.lexical(path) }
            .flatMap { (path: String) -> String? in gone(path) ? nil : path }
        let controller = TerminalWindowController(directory: nil, project: project, firstTab: false)
        if let saved = RestoreLayout.frame(window.frame, on: window.screen, screens: screens) {
            let rect = NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
            controller.window?.setFrame(rect, display: false)
        } else {
            controller.window?.center()
        }
        var selected = 0
        for (index, group) in window.groups.enumerated() {
            guard let root = maker.node(group.root, in: controller) else { continue }
            let tabs = maker.tabs
            guard let focused = tabs[group.focused] ?? root.panes.first else { continue }
            let zoomed = group.zoomed.flatMap { (id: UUID) -> TerminalTab? in tabs[id] }
            let built = PaneGroup(root: root, focused: focused, zoomed: zoomed)
            let local: [TerminalTab] = built.panes.filter { (tab: TerminalTab) -> Bool in tab.remote == nil }
            controller.insertRestored(built, starting: local)
            if index == window.selected { selected = controller.groups.count - 1 }
        }
        guard !controller.groups.isEmpty else {
            controller.window?.close() // its timer goes with it
            return nil
        }
        controller.select(selected)
        controller.refresh()
        return controller
    }

    /// Makes each pane's tab, as the windows are built.
    @MainActor
    private struct PaneMaker {
        let plans: [UUID: PanePlan]
        let scrollback: [UUID: String]
        let savedAt: ScrollbackText.SavedAt?
        /// Tab ids in use: a restored tab never takes one an open tab has.
        var taken: Set<UUID> = []
        /// The tabs made, by the pane id the snapshot gives them.
        var tabs: [UUID: TerminalTab] = [:]
        var panes: [RestoredPane] = []
        var keptRemote: [RemoteTabRecord] = []
        var remoteToStart: [TerminalTab] = []
        var skipped: [String] = []

        init(plans: [PanePlan], scrollback: [UUID: String], savedAt: ScrollbackText.SavedAt?) {
            var byPane: [UUID: PanePlan] = [:]
            for plan in plans where byPane[plan.pane] == nil { byPane[plan.pane] = plan }
            self.plans = byPane
            self.scrollback = scrollback
            self.savedAt = savedAt
        }

        /// A tree of the snapshot's, as panes: a pane that could not be made leaves its split, its room going to its
        /// neighbour, and a split left with one pane is that pane. The other dividers stay where they were.
        mutating func node(_ node: SessionSnapshot.Node, in controller: TerminalWindowController) -> PaneGroup.Node? {
            switch node {
            case .pane(let pane):
                return tab(for: pane, in: controller).map(PaneGroup.Node.pane)
            case .split(let split):
                var children: [PaneGroup.Node] = []
                var dropped: [Int] = []
                for (index, child) in split.children.enumerated() {
                    if let built = self.node(child, in: controller) { children.append(built) } else { dropped.append(index) }
                }
                guard children.count > 1 else { return children.first }
                let built = PaneGroup.Split(vertical: split.vertical, children: children)
                let dividers = RestoreLayout.dividers(split.dividers, children: split.children.count, dropped: dropped)
                built.dividers = dividers.map { (divider: Double) -> CGFloat in CGFloat(divider) }
                return .split(built)
            }
        }

        /// The pane's tab, with its id, title, folder or server, its record (saved unchanged while its action waits), its
        /// scrollback and its note. Nil for a tab on a host removed or re-pointed since.
        mutating func tab(for pane: SessionSnapshot.Pane, in controller: TerminalWindowController) -> TerminalTab? {
            guard let plan = plans[pane.id] else { return nil }
            var id = pane.id
            if taken.contains(id) { id = UUID() }
            let tab: TerminalTab
            if let record = pane.remote {
                let found = RemoteConnection.host(of: record)
                guard let host = found.host else {
                    // A kept record waits in the saved records too, and is told about there.
                    if plan.outcome != .reattach, let problem = found.problem { skipped.append(problem) }
                    return nil
                }
                let keep: KeepMode = plan.outcome == .reattach ? record.keep : .off
                let session: String? = keep == .off ? nil : record.session
                let remote = RemoteTab(host: host, directory: record.directory, session: session, keep: keep)
                tab = controller.restoredTab(directory: nil, remote: remote, id: id)
                if keep != .off { keptRemote.append(record) }
                remoteToStart.append(tab)
            } else {
                tab = controller.restoredTab(directory: plan.folder ?? pane.folder, remote: nil, id: id)
            }
            taken.insert(id)
            tab.userTitle = pane.userTitle
            tab.lastSelected = pane.lastSelected
            var record = pane
            record.id = id
            record.pending = plan.pending
            tab.restoredRecord = record
            if let name = pane.scrollback, let text = scrollback[name], let savedAt { tab.restoredScrollback = (text, savedAt) }
            tab.restoreNote = plan.note.shownBeforeShell()
            tabs[pane.id] = tab
            panes.append(RestoredPane(tab: tab, plan: plan))
            return tab
        }
    }

    private static func frame(_ rect: NSRect) -> SessionSnapshot.Frame {
        SessionSnapshot.Frame(x: Double(rect.origin.x), y: Double(rect.origin.y), width: Double(rect.width), height: Double(rect.height))
    }
}
