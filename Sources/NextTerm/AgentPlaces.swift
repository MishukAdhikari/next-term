import AppKit
import NextTermCore

/// Where each local agent tab's agent works: its checkout and branch, for the one mark a tab gets when that is
/// not what its window shows or its branch was switched under it. Once a second while something moves, slowing to
/// every 2 and then every 4 seconds while looks find nothing new (QuietBackoff), and back to once a second when an
/// agent starts or ends, a shell tab runs git that can move HEAD, Next Term runs such git itself, or a look finds a
/// change. Each look reads each agent's own folder (its process's, or the one its session record names after a move the process
/// didn't make) and what its session record says it wrote since, git's worktree list for its repository (read
/// again only when a HEAD or a git folder changed), then WorktreeLifecycle, the one record of where each agent
/// works. The reads run off the main thread; remote tabs get nothing.
/// Design: claudedocs/2026-10-09-brainstorm-branch-aware-agents (R1–R10, R30).
final class AgentPlaces {
    static let shared = AgentPlaces()

    /// Where each agent tab's agent works, as it counts (by tab id).
    private(set) var places: [String: AgentPlace] = [:]
    /// The linked worktrees each tab's agent worked in since this version first ran (by tab id), kept after it ends.
    private(set) var history: [String: [String]] = [:]
    /// How each agent tab's agent came to be where it is (by tab id): whether that was before this version first ran.
    private(set) var placements: [String: WorktreeLifecycle.Placement] = [:]
    /// Told, on the main thread, the tabs (by id) whose agents ended at the last look.
    var agentsEnded: ((Set<String>) -> Void)?
    /// Each agent tab's folder as last read, not held (by tab id), with the agent's process.
    private var folders: [String: (pid: Int32, folder: String, at: Date)] = [:]
    /// What each window shows, by the folder it shows: its repository and checkout.
    private var shown: [String: (repository: String, checkout: Checkout)] = [:]
    /// When Next Term itself last ran git that can move HEAD, by checkout: the developer's switches. And the
    /// branch each went to, when it named one.
    private var ownSwitches: [String: Date] = [:]
    private var ownTargets: [String: String] = [:]
    /// git commands that can move HEAD, run lately in shell tabs.
    private var shellCommands: [PlaceSighting.ShellCommand] = []
    private var commandsSeen: [String: Int] = [:]
    private var reading = false
    private var timer: Timer?
    /// How long until the next look: longer while looks find nothing new.
    private var pace = QuietBackoff()
    /// The agent tabs at the last look, with their processes and whether they worked: a change is an agent that
    /// started, ended or turned, and the looks go back to once a second.
    private var probed: [String] = []

    // Read and written on `queue` only.
    private let queue = DispatchQueue(label: "nextterm.places", qos: .utility)
    private var lifecycle = WorktreeLifecycle(since: AgentPlaces.firstRun)
    /// Each agent's process folder, and since when it has been there.
    private var processFolders: [String: (pid: Int32, folder: String?, since: Date)] = [:]
    /// The repository each agent run is matched against: the one it started in.
    private var startRepositories: [String: (startedAt: Date, repository: String?)] = [:]
    private var repositoryCache: [String: (found: (commonDir: String, root: String)?, at: Date)] = [:]
    private var roots: [String: String] = [:]
    private var checkoutCache: [String: (signature: String, checkouts: [Checkout])] = [:]
    /// Claude Code transcripts by session id, and when one was last looked for and not found.
    private var transcripts: [String: String] = [:]
    /// The agents' session records, followed as they grow.
    private var records = SessionRecords()
    private var missingTranscripts: [String: Date] = [:]
    /// Command Code's session file for each agent run (by tab id), and when it was last looked for.
    private var commandCodeFiles: [String: (startedAt: Date, path: String?, looked: Date)] = [:]
    /// Codex's rollout for each agent run (by tab id), found by listing its processes' open files: listed again every
    /// 4 seconds, or at once when its process or folder changed; the one found last is followed in between.
    private var codexRollouts: [String: (listing: Relisting, rollout: String?)] = [:]
    static let codexRelisting: TimeInterval = 4

    /// The moment this version first followed what agents write, kept once: what they did before it is the baseline,
    /// never offered.
    static let firstRun: Date = {
        let key = "agentWorktreesSince"
        if let stored = UserDefaults.standard.object(forKey: key) as? Date { return stored }
        let now = Date()
        UserDefaults.standard.set(now, forKey: key)
        return now
    }()

    private init() {
        schedule()
        agentsEnded = { [weak self] ended in
            guard let history = self?.history else { return }
            MainActor.assumeIsolated { WorktreeEndOffer.agentsEnded(ended, history: history) }
        }
    }

    // MARK: what the app asks

    /// The folder `tab`'s agent works in: its process's own folder, or the one its session record names after
    /// a `cd` its process didn't make; never the shell's, which stays where the agent was started. The
    /// branch popup credits agents to worktrees by it, and its agent guard looks for agents by it.
    func agentFolder(of tab: TerminalTab) -> String {
        let pgid = tcgetpgrp(tab.view.process.childfd)
        if let seen = folders[tab.id.uuidString], seen.pid == pgid, Date().timeIntervalSince(seen.at) < 5 { return seen.folder }
        return Self.readFolder(of: tab, pid: pgid)
    }

    /// The agent's folder, read now: its process's (the agent leads the pty's foreground group), or the folder
    /// Claude Code's transcript names last when that was written since the agent started (its shell's `cd`).
    static func readFolder(of tab: TerminalTab, pid: Int32) -> String {
        let status = tab.status
        guard pid > 0, let since = status.runningSince else { return tab.liveDirectory }
        let started = SessionStore.startDate(of: tab, since: since)
        let agent = AgentKind(program: status.program) ?? AgentKind(program: CommandClassifier.programName(status.expandedCommand))
        let record = agent == .claude ? AgentLocation.claudeFolder(pid: pid, home: SessionStore.home) : nil
        let process = ProcessInspector.currentDirectory(of: pid)
        return AgentLocation.folder(process: process, processSince: started, record: record, startedAt: started) ?? tab.liveDirectory
    }

    /// `tab`'s mark in `controller`'s window, when its agent works in another checkout than the window
    /// shows or its branch was switched under it.
    func mark(for tab: TerminalTab, in controller: TerminalWindowController) -> PlaceMark? {
        guard let place = place(of: tab) else { return nil }
        let window = Self.shownFolder(of: controller).flatMap { shown[$0] }
        return PlaceMark.of(place, shownRepository: window?.repository, shown: window?.checkout)
    }

    /// list_tabs' fields for a local agent tab: the checkout its agent works in, its branch, and whether
    /// the window shows that ("same"), another checkout ("elsewhere"), or the chat's branch was switched under
    /// it ("switched_under").
    func fields(of tab: TerminalTab, in controller: TerminalWindowController) -> [String: Any] {
        guard let place = place(of: tab) else { return [:] }
        let window = Self.shownFolder(of: controller).flatMap { shown[$0] }
        var fields: [String: Any] = ["checkout": place.checkout.path,
                                     "sync": PlaceMark.sync(place, shownRepository: window?.repository, shown: window?.checkout)]
        switch place.checkout.head {
        case let .branch(name): fields["branch"] = name
        case let .detached(commit): fields["detached_at"] = String(commit.prefix(7))
        }
        if let switched = place.switched {
            fields["chat_branch"] = switched.from.name
            switch switched.by {
            case .you: fields["switched_by"] = "you"
            case .tab: fields["switched_by"] = "shell_tab"
            case .agent: fields["switched_by"] = "agent_tab"
            case .unknown: fields["switched_by"] = "unknown"
            }
            if let key = switched.by.tabKey { fields["switched_by_tab"] = key.lowercased() }
        }
        if let offer = offers.state(of: tab.id.uuidString, in: place.checkout.path) { fields["worktree_offer"] = offer.rawValue }
        return fields
    }

    // MARK: the offer to open a worktree as a project

    /// What the strip above each agent tab has offered (WorktreeLifecycle.Offers), kept in UserDefaults; a self-test's
    /// stays in memory.
    private(set) var offers = WorktreeLifecycle.Offers(stored: SelfTest.isRequested ? nil
        : UserDefaults.standard.object(forKey: WorktreeLifecycle.Offers.defaultsKey))

    /// The linked worktree `tab`'s agent works in, when it is not the checkout `controller`'s window shows nor the
    /// repository's main one, and git still lists it on disk.
    private func otherWorktree(of tab: TerminalTab, in controller: TerminalWindowController) -> (checkout: Checkout, shown: String?)? {
        guard let place = place(of: tab), !place.checkout.isMain else { return nil }
        let shown = Self.shownFolder(of: controller).flatMap { self.shown[$0] }?.checkout.path
        guard place.checkout.path != shown, FileManager.default.fileExists(atPath: place.checkout.path) else { return nil }
        return (place.checkout, shown)
    }

    /// The worktree whose strip shows above `tab` now, in front in `controller`'s window: offered once the person
    /// hasn't typed in that tab for HintRules' quiet interval.
    func worktreeStrip(for tab: TerminalTab, in controller: TerminalWindowController) -> Checkout? {
        guard let found = otherWorktree(of: tab, in: controller) else { return nil }
        let key = tab.id.uuidString
        return changingOffers { offers in
            offers.strip(for: key, placement: placements[key], isMain: false, shown: found.shown,
                         sinceUserKey: TerminalTab.now - tab.lastUserInputAt) == found.checkout.path ? found.checkout : nil
        }
    }

    /// The worktree `tab`'s menu and its place mark may open as a project: offered, or held by Not Now.
    func offerableWorktree(of tab: TerminalTab, in controller: TerminalWindowController) -> Checkout? {
        guard let checkout = otherWorktree(of: tab, in: controller)?.checkout,
              offers.offerable(tab.id.uuidString, checkout.path) else { return nil }
        return checkout
    }

    /// Whether Not Now holds the strip for the worktree `tab`'s agent works in: its place mark brings it back.
    func offerHeld(_ tab: TerminalTab, in controller: TerminalWindowController) -> Bool {
        guard let checkout = otherWorktree(of: tab, in: controller)?.checkout else { return false }
        return offers.state(of: tab.id.uuidString, in: checkout.path) == .dismissed
    }

    /// Not Now on `tab`'s strip for `worktree`.
    func dismissOffer(_ tab: TerminalTab, worktree: String) {
        changingOffers { $0.dismiss(tab.id.uuidString, worktree) }
    }

    /// The place mark's click: the strip Not Now held shows again. False when none was held.
    @discardableResult
    func reoffer(_ tab: TerminalTab, worktree: String) -> Bool {
        changingOffers { $0.reoffer(tab.id.uuidString, worktree) }
    }

    /// `tab` was opened in `worktree`'s own window.
    func offerOpened(_ tab: TerminalTab, worktree: String) {
        changingOffers { $0.opened(tab.id.uuidString, worktree) }
    }

    /// Agents seen in a worktree before this version first ran keep it as the baseline, in tabs not in front too.
    private func noteOfferBaselines() {
        changingOffers { offers in
            for (key, placement) in placements where placement.baseline {
                offers.note(key, placement: placement, isMain: places[key]?.checkout.isMain ?? true)
            }
        }
    }

    /// Changes the offers and keeps them when they changed, forgetting tabs that closed.
    @discardableResult
    private func changingOffers<T>(_ change: (inout WorktreeLifecycle.Offers) -> T) -> T {
        var changed = offers
        let result = change(&changed)
        guard changed != offers else { return result }
        if !SelfTest.isRequested, let app = AppDelegate.shared {
            changed.keep(only: Set(app.controllers.flatMap(\.tabs).map(\.id.uuidString)))
            UserDefaults.standard.set(changed.stored, forKey: WorktreeLifecycle.Offers.defaultsKey)
        }
        offers = changed
        return result
    }

    /// Keep Going: the branch now checked out becomes the chat's own.
    func keepGoing(_ tab: TerminalTab) {
        let key = tab.id.uuidString
        queue.async { [self] in
            lifecycle.keepGoing(key)
            let places = lifecycle.places
            DispatchQueue.main.async { self.places = places }
        }
    }

    /// Next Term is about to run git `steps` in the checkout at `root`, or just did: if they can move HEAD,
    /// a switch there now is the developer's.
    func noteOwnGit(_ steps: [[String]], in root: String) {
        guard !root.isEmpty, steps.contains(where: AgentLocation.movesHead(arguments:)) else { return }
        let path = canonicalPath(root)
        ownSwitches[path] = Date()
        ownTargets[path] = steps.compactMap(AgentLocation.switchTarget(arguments:)).last
        // The switch shows in the next look, which comes within a second again.
        if pace.reset() { schedule() }
    }

    private func place(of tab: TerminalTab) -> AgentPlace? {
        guard tab.remote == nil, tab.status.running, tab.status.kind == .agent else { return nil }
        return places[tab.id.uuidString]
    }

    /// The folder a window shows: its project, or the folder its sidebar follows.
    static func shownFolder(of controller: TerminalWindowController) -> String? {
        controller.project ?? controller.sidebar.root?.path
    }

    // MARK: the looks

    /// Sets the clock to the pace's wait. Each wakeup has a fifth of it as tolerance, so it may join the system's others.
    private func schedule() {
        timer?.invalidate()
        let interval = pace.interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// What a look found: a change brings the next one within a second, nothing new waits longer.
    private func noteLook(moved: Bool) {
        if pace.note(moved: moved) { schedule() }
    }

    /// One agent tab, as read on the main thread.
    private struct Probe {
        let key: String
        let title: String
        let agent: AgentKind?
        let pid: Int32
        let startedAt: Date
        let working: Bool
        let shellFolder: String
    }

    private func tick() {
        guard let app = AppDelegate.shared else { return }
        let now = Date()
        let commandsBefore = shellCommands.count
        noteShellCommands(app.controllers, at: now)
        var probes: [Probe] = []
        var windows = Set<String>()
        for controller in app.controllers {
            if let folder = Self.shownFolder(of: controller) { windows.insert(folder) }
            for tab in controller.tabs {
                let status = tab.status
                guard tab.remote == nil, status.running, status.kind == .agent, let since = status.runningSince else { continue }
                let pid = tcgetpgrp(tab.view.process.childfd)
                guard pid > 0 else { continue }
                let agent = AgentKind(program: status.program) ?? AgentKind(program: CommandClassifier.programName(status.expandedCommand))
                probes.append(Probe(key: tab.id.uuidString, title: tab.title, agent: agent, pid: pid,
                                    startedAt: SessionStore.startDate(of: tab, since: since), working: status.state == .working,
                                    shellFolder: tab.directory))
            }
        }
        let probed = probes.map { "\($0.key) \($0.pid) \($0.working)" }
        let started = probed != self.probed || shellCommands.count > commandsBefore
        self.probed = probed
        guard !probes.isEmpty else {
            noteLook(moved: started || !places.isEmpty || !folders.isEmpty)
            if !places.isEmpty || !folders.isEmpty {
                places = [:]
                folders = [:]
                // The record outlives the agents: it is told none runs, never started over.
                queue.async { [self] in
                    lifecycle.update(PlaceSighting(), at: now) { _, _, _ in .none }
                    let history = lifecycle.history, ended = lifecycle.ended
                    DispatchQueue.main.async {
                        self.placements = [:]
                        self.publish(history: history, ended: ended)
                    }
                }
            }
            return
        }
        guard !reading, let git = GitWriter.git else { return }
        reading = true
        ownSwitches = ownSwitches.filter { now.timeIntervalSince($0.value) < 60 }
        ownTargets = ownTargets.filter { ownSwitches[$0.key] != nil }
        shellCommands.removeAll { now.timeIntervalSince($0.at) > 60 }
        var sighting = PlaceSighting()
        sighting.ownSwitches = ownSwitches
        sighting.ownTargets = ownTargets
        sighting.shellCommands = shellCommands
        let home = SessionStore.home
        queue.async { [self] in
            let read = self.read(probes, windows: windows, sighting: sighting, git: git, home: home, at: now)
            DispatchQueue.main.async { [self] in
                reading = false
                noteLook(moved: started || moved(to: read))
                places = read.places
                folders = read.folders
                shown = read.shown
                placements = read.placements
                noteOfferBaselines()
                publish(history: read.history, ended: read.ended)
            }
        }
    }

    /// Whether a look's read differs from what the last one published: a place, a placement, a worktree in an agent's
    /// history, an agent's folder, a checkout a window shows, or an agent that ended.
    private func moved(to read: Read) -> Bool {
        guard read.places == places, read.placements == placements, read.history == history, read.ended.isEmpty,
              read.folders.mapValues(\.folder) == folders.mapValues(\.folder),
              read.shown.keys == shown.keys else { return true }
        return read.shown.contains { folder, now in
            shown[folder].map { $0.repository != now.repository || $0.checkout != now.checkout } ?? true
        }
    }

    private func publish(history: [String: [String]], ended: Set<String>) {
        self.history = history
        if !ended.isEmpty { agentsEnded?(ended) }
    }

    /// Shell tabs that started a git command that can move HEAD since the last look: a switch in that
    /// checkout is theirs.
    private func noteShellCommands(_ controllers: [TerminalWindowController], at now: Date) {
        var seen: [String: Int] = [:]
        for tab in controllers.flatMap(\.tabs) where tab.remote == nil && tab.status.kind != .agent {
            let key = tab.id.uuidString
            let count = tab.status.commandsStarted
            seen[key] = count
            guard let before = commandsSeen[key], count > before else { continue }
            if AgentLocation.movesHead(tab.status.command) || AgentLocation.movesHead(tab.status.expandedCommand) {
                shellCommands.append(PlaceSighting.ShellCommand(key: key, title: tab.title, folder: canonicalPath(tab.liveDirectory), at: now))
            }
        }
        commandsSeen = seen
    }

    // MARK: off the main thread

    private struct Read {
        var places: [String: AgentPlace] = [:]
        var folders: [String: (pid: Int32, folder: String, at: Date)] = [:]
        var shown: [String: (repository: String, checkout: Checkout)] = [:]
        var history: [String: [String]] = [:]
        var ended: Set<String> = []
        var placements: [String: WorktreeLifecycle.Placement] = [:]
    }

    private func read(_ probes: [Probe], windows: Set<String>, sighting start: PlaceSighting, git: String, home: String, at now: Date) -> Read {
        var sighting = start
        var result = Read()
        // The windows' repositories first: an agent that starts in one of their checkouts (or in a submodule
        // there) is matched against it.
        var windowRepositories: [String: String] = [:]
        for folder in windows {
            guard let found = repository(of: canonicalPath(folder), git: git, at: now) else { continue }
            windowRepositories[folder] = found.commonDir
            if sighting.repositories[found.commonDir] == nil {
                sighting.repositories[found.commonDir] = checkouts(of: found.commonDir, git: git, at: now)
            }
        }
        var sighted: [(probe: Probe, folder: String)] = []
        for probe in probes {
            let (folder, writes) = agentFolder(probe, home: home)
            sighted.append((probe, folder))
            guard let repository = startRepository(probe, folder: folder, known: sighting.repositories, git: git, at: now) else { continue }
            if sighting.repositories[repository] == nil {
                sighting.repositories[repository] = checkouts(of: repository, git: git, at: now)
            }
            sighting.agents.append(PlaceSighting.Agent(key: probe.key, title: probe.title, repository: repository, folder: folder,
                                                       working: probe.working, startedAt: probe.startedAt, writes: writes))
        }
        // Every read of this look is done (git's can take a while under load, between one agent's folder and the
        // next): what it saw is stamped now, after it was read, so no move or switch holds from before it happened.
        let seen = Date()
        for (probe, folder) in sighted { result.folders[probe.key] = (probe.pid, folder, seen) }
        let keys = Set(probes.map(\.key))
        processFolders = processFolders.filter { keys.contains($0.key) }
        startRepositories = startRepositories.filter { keys.contains($0.key) }
        commandCodeFiles = commandCodeFiles.filter { keys.contains($0.key) }
        codexRollouts = codexRollouts.filter { keys.contains($0.key) }
        lifecycle.update(sighting, at: seen) { checkout, from, commit in
            AgentLocation.change(in: checkout, from: from, commit: commit, git: git)
        }
        result.places = lifecycle.places
        result.history = lifecycle.history
        result.placements = lifecycle.placements
        result.ended = lifecycle.ended
        for (folder, repository) in windowRepositories {
            if let checkout = AgentLocation.checkout(containing: canonicalPath(folder), in: sighting.repositories[repository] ?? []) {
                result.shown[folder] = (repository, checkout)
            }
        }
        return result
    }

    /// Where an agent works now: its process's folder, or its session record's when that is newer; and what the
    /// record says it wrote since the last look, its paths made canonical as the checkouts' are.
    private func agentFolder(_ probe: Probe, home: String) -> (folder: String, writes: [DatedWrite]) {
        let process = ProcessInspector.currentDirectory(of: probe.pid)
        var since = probe.startedAt
        if let last = processFolders[probe.key], last.pid == probe.pid {
            since = last.folder == process ? last.since : Date()
        }
        processFolders[probe.key] = (probe.pid, process, since)
        let record = recorded(probe, process: process, home: home)
        let folder = AgentLocation.folder(process: process, processSince: since, record: record?.folder, startedAt: probe.startedAt)
        let writes = (record?.writes ?? []).map { DatedWrite(signal: WriteSignal(path: canonicalPath($0.signal.path), kind: $0.signal.kind), at: $0.at) }
        return (canonicalPath(folder ?? probe.shellFolder), writes)
    }

    /// The agent's session record, for agents that record moves their process doesn't make (Claude Code's shell
    /// `cd`, Codex's `/cd`, Copilot CLI's workspace) and what they write (Claude Code, Codex, Command Code). Only
    /// what was written to the record since the last look is read; the folder named before holds until a newer
    /// line names another.
    private func recorded(_ probe: Probe, process: String?, home: String) -> RecordRead? {
        switch probe.agent {
        case .claude?:
            guard let session = records.claudeSession(pid: probe.pid, home: home) else { return nil }
            if let known = transcripts[session.id], isRegularFile(known) { return records.follow(known, kind: .claude) }
            // Where it should be, each time; a look through every project folder at most every 10 s (a new
            // session has no transcript until its first message).
            let scanning = missingTranscripts[session.id].map { Date().timeIntervalSince($0) >= 10 } ?? true
            guard let found = AgentLocation.claudeTranscript(id: session.id, started: session.started, home: home, scanning: scanning) else {
                if missingTranscripts.count > 200 { missingTranscripts.removeAll() }
                if scanning { missingTranscripts[session.id] = Date() }
                return nil
            }
            if transcripts.count > 200 { transcripts.removeAll() }
            transcripts[session.id] = found
            return records.follow(found, kind: .claude)
        case .codex?:
            // The rollout its process holds open (node's child, when Codex runs through npm), listed again only when
            // its turn comes, its process or folder changed, or the file found last is gone.
            let now = Date(), signature = "\(probe.pid)\n\(process ?? "")"
            var known = codexRollouts[probe.key] ?? (Relisting(every: Self.codexRelisting), nil)
            if known.listing.due(signature, at: now) || known.rollout.map(isRegularFile) == false {
                known.rollout = Self.codexRollout(of: probe.pid, home: home)
                known.listing.listed(signature, at: now)
            }
            codexRollouts[probe.key] = known
            return known.rollout.map { records.follow($0, kind: .codex) }
        case .copilot?:
            return records.copilotFolder(pid: probe.pid, home: home).map { RecordRead(folder: $0) }
        case .commandCode?:
            // The newest session file started in its folder since it started, looked for again every 10 s until found.
            var known = commandCodeFiles[probe.key]
            if known?.startedAt != probe.startedAt || known?.path.map(isRegularFile) == false { known = nil }
            if known == nil || (known?.path == nil && Date().timeIntervalSince(known?.looked ?? .distantPast) >= 10) {
                known = (probe.startedAt, LiveChat.commandCodeFile(folder: probe.shellFolder, since: probe.startedAt, home: home), Date())
            }
            commandCodeFiles[probe.key] = known
            // Its folder is where it started, which its process says too: only its writes are wanted.
            return known?.path.map { RecordRead(folder: nil, writes: records.follow($0, kind: .commandCode).writes) }
        default:
            return nil
        }
    }

    /// The Codex rollout held open by `pid` or one of its children.
    private static func codexRollout(of pid: Int32, home: String) -> String? {
        for pid in ProcessInspector.family(of: pid).prefix(12) {
            if let rollout = ProcessInspector.openFiles(of: pid).first(where: { AgentLocation.isCodexRollout($0, home: home) }) {
                return rollout
            }
        }
        return nil
    }

    /// The repository an agent run is matched against: the one holding the folder it started in, kept for
    /// the run (a folder in another repository later is no move). A window's repository wins when the
    /// folder is in one of its checkouts.
    private func startRepository(_ probe: Probe, folder: String, known: [String: [Checkout]], git: String, at now: Date) -> String? {
        if let start = startRepositories[probe.key], start.startedAt == probe.startedAt { return start.repository }
        // The repository whose checkout holding the folder is the deepest (a clone kept inside another's folder).
        let holding = known.compactMap { repository, checkouts in
            AgentLocation.checkout(containing: folder, in: checkouts).map { (repository: repository, depth: $0.path.count) }
        }
        let found = holding.max { $0.depth < $1.depth }?.repository ?? repository(of: folder, git: git, at: now)?.commonDir
        startRepositories[probe.key] = (probe.startedAt, found)
        return found
    }

    /// The repository holding `folder`, kept (a folder outside one is asked about again after 30 s).
    private func repository(of folder: String, git: String, at now: Date) -> (commonDir: String, root: String)? {
        if let cached = repositoryCache[folder], cached.found != nil || now.timeIntervalSince(cached.at) < 30 { return cached.found }
        let found = AgentLocation.repository(of: folder, git: git)
        if repositoryCache.count > 200 { repositoryCache.removeAll() }
        repositoryCache[folder] = (found, now)
        if let found, roots[found.commonDir] == nil { roots[found.commonDir] = found.root }
        return found
    }

    /// A repository's checkouts: `git worktree list` again only when a HEAD or a git folder changed, and
    /// every 30 s (a branch's own commits move no HEAD file).
    private func checkouts(of repository: String, git: String, at now: Date) -> [Checkout] {
        let signature = AgentLocation.signature(commonDir: repository) + "\n" + String(Int(now.timeIntervalSince1970 / 30))
        let cached = checkoutCache[repository]
        if let cached, cached.signature == signature { return cached.checkouts }
        let root = cached?.checkouts.first(where: \.isMain)?.path ?? roots[repository] ?? repository
        guard let fresh = AgentLocation.checkouts(in: root, git: git) else { return cached?.checkouts ?? [] }
        checkoutCache[repository] = (signature, fresh)
        return fresh
    }
}
