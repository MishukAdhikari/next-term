import AppKit
import NextTermCore

/// Where each local agent tab's agent works: its checkout and branch, held 3 s, for the one mark a tab gets
/// when that is not what its window shows or its branch was switched under it. Once a second while an agent
/// runs in a local tab: each agent's own folder (its process's, or the one its session record names after
/// a move the process didn't make), git's worktree list for its repository (read again only when a HEAD or
/// a git folder changed), then PlaceTracker. The reads run off the main thread; remote tabs get nothing.
/// Design: claudedocs/2026-10-09-brainstorm-branch-aware-agents (R1–R10, R30).
final class AgentPlaces {
    static let shared = AgentPlaces()

    /// Where each agent tab's agent works, as it counts (by tab id).
    private(set) var places: [String: AgentPlace] = [:]
    /// Each agent tab's folder as last read, not held (by tab id), with the agent's process.
    private var folders: [String: (pid: Int32, folder: String, at: Date)] = [:]
    /// What each window shows, by the folder it shows: its repository and checkout.
    private var shown: [String: (repository: String, checkout: Checkout)] = [:]
    /// When Next Term itself last ran git that can move HEAD, by checkout: the developer's switches.
    private var ownSwitches: [String: Date] = [:]
    /// git commands that can move HEAD, run lately in shell tabs.
    private var shellCommands: [PlaceSighting.ShellCommand] = []
    private var commandsSeen: [String: Int] = [:]
    private var reading = false
    private var timer: Timer?

    // Read and written on `queue` only.
    private let queue = DispatchQueue(label: "nextterm.places", qos: .utility)
    private var tracker = PlaceTracker()
    /// Each agent's process folder, and since when it has been there.
    private var processFolders: [String: (pid: Int32, folder: String?, since: Date)] = [:]
    /// The repository each agent run is matched against: the one it started in.
    private var startRepositories: [String: (startedAt: Date, repository: String?)] = [:]
    private var repositoryCache: [String: (found: (commonDir: String, root: String)?, at: Date)] = [:]
    private var roots: [String: String] = [:]
    private var checkoutCache: [String: (signature: String, checkouts: [Checkout])] = [:]
    /// Claude Code transcripts by session id, and when one was last looked for and not found.
    private var transcripts: [String: String] = [:]
    private var missingTranscripts: [String: Date] = [:]

    private init() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
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
        return fields
    }

    /// Keep Going: the branch now checked out becomes the chat's own.
    func keepGoing(_ tab: TerminalTab) {
        let key = tab.id.uuidString
        queue.async { [self] in
            tracker.keepGoing(key)
            let places = tracker.places
            DispatchQueue.main.async { self.places = places }
        }
    }

    /// Next Term is about to run git `steps` in the checkout at `root`, or just did: if they can move HEAD,
    /// a switch there now is the developer's.
    func noteOwnGit(_ steps: [[String]], in root: String) {
        guard !root.isEmpty, steps.contains(where: AgentLocation.movesHead(arguments:)) else { return }
        ownSwitches[canonicalPath(root)] = Date()
    }

    private func place(of tab: TerminalTab) -> AgentPlace? {
        guard tab.remote == nil, tab.status.running, tab.status.kind == .agent else { return nil }
        return places[tab.id.uuidString]
    }

    /// The folder a window shows: its project, or the folder its sidebar follows.
    static func shownFolder(of controller: TerminalWindowController) -> String? {
        controller.project ?? controller.sidebar.root?.path
    }

    // MARK: once a second

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
        guard !probes.isEmpty else {
            if !places.isEmpty || !folders.isEmpty {
                places = [:]
                folders = [:]
                queue.async { [self] in tracker = PlaceTracker() }
            }
            return
        }
        guard !reading, let git = GitWriter.git else { return }
        reading = true
        ownSwitches = ownSwitches.filter { now.timeIntervalSince($0.value) < 60 }
        shellCommands.removeAll { now.timeIntervalSince($0.at) > 60 }
        var sighting = PlaceSighting()
        sighting.ownSwitches = ownSwitches
        sighting.shellCommands = shellCommands
        let home = SessionStore.home
        queue.async { [self] in
            let read = self.read(probes, windows: windows, sighting: sighting, git: git, home: home, at: now)
            DispatchQueue.main.async { [self] in
                reading = false
                places = read.places
                folders = read.folders
                shown = read.shown
            }
        }
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
        for probe in probes {
            let folder = agentFolder(probe, home: home)
            result.folders[probe.key] = (probe.pid, folder, now)
            guard let repository = startRepository(probe, folder: folder, known: sighting.repositories, git: git, at: now) else { continue }
            if sighting.repositories[repository] == nil {
                sighting.repositories[repository] = checkouts(of: repository, git: git, at: now)
            }
            sighting.agents.append(PlaceSighting.Agent(key: probe.key, title: probe.title, repository: repository, folder: folder,
                                                       working: probe.working, startedAt: probe.startedAt))
        }
        let keys = Set(probes.map(\.key))
        processFolders = processFolders.filter { keys.contains($0.key) }
        startRepositories = startRepositories.filter { keys.contains($0.key) }
        tracker.update(sighting, at: now) { checkout, from, commit in
            AgentLocation.change(in: checkout, from: from, commit: commit, git: git)
        }
        result.places = tracker.places
        for (folder, repository) in windowRepositories {
            if let checkout = AgentLocation.checkout(containing: canonicalPath(folder), in: sighting.repositories[repository] ?? []) {
                result.shown[folder] = (repository, checkout)
            }
        }
        return result
    }

    /// Where an agent works now: its process's folder, or its session record's when that is newer.
    private func agentFolder(_ probe: Probe, home: String) -> String {
        let process = ProcessInspector.currentDirectory(of: probe.pid)
        var since = probe.startedAt
        if let last = processFolders[probe.key], last.pid == probe.pid {
            since = last.folder == process ? last.since : Date()
        }
        processFolders[probe.key] = (probe.pid, process, since)
        let record = recordedFolder(probe, home: home)
        let folder = AgentLocation.folder(process: process, processSince: since, record: record, startedAt: probe.startedAt)
        return canonicalPath(folder ?? probe.shellFolder)
    }

    /// The folder the agent's session record names last, for agents that record moves their process doesn't
    /// make: Claude Code's shell `cd`, Codex's `/cd`, Copilot CLI's workspace. Only the record's end is read.
    private func recordedFolder(_ probe: Probe, home: String) -> RecordedFolder? {
        switch probe.agent {
        case .claude?:
            guard let session = AgentLocation.claudeSession(pid: probe.pid, home: home) else { return nil }
            if let known = transcripts[session.id], isRegularFile(known) { return AgentLocation.claudeFolder(transcript: known) }
            if let missed = missingTranscripts[session.id], Date().timeIntervalSince(missed) < 10 { return nil }
            guard let found = AgentLocation.claudeTranscript(id: session.id, started: session.started, home: home) else {
                if missingTranscripts.count > 200 { missingTranscripts.removeAll() }
                missingTranscripts[session.id] = Date()
                return nil
            }
            if transcripts.count > 200 { transcripts.removeAll() }
            transcripts[session.id] = found
            return AgentLocation.claudeFolder(transcript: found)
        case .codex?:
            // The rollout its process holds open (node's child, when Codex runs through npm).
            for pid in ProcessInspector.family(of: probe.pid).prefix(12) {
                if let rollout = ProcessInspector.openFiles(of: pid).first(where: { AgentLocation.isCodexRollout($0, home: home) }) {
                    return AgentLocation.codexFolder(rollout: rollout)
                }
            }
            return nil
        case .copilot?:
            return AgentLocation.copilotFolder(pid: probe.pid, home: home)
        default:
            return nil
        }
    }

    /// The repository an agent run is matched against: the one holding the folder it started in, kept for
    /// the run (a folder in another repository later is no move). A window's repository wins when the
    /// folder is in one of its checkouts.
    private func startRepository(_ probe: Probe, folder: String, known: [String: [Checkout]], git: String, at now: Date) -> String? {
        if let start = startRepositories[probe.key], start.startedAt == probe.startedAt { return start.repository }
        let found = known.first { AgentLocation.checkout(containing: folder, in: $0.value) != nil }?.key
            ?? repository(of: folder, git: git, at: now)?.commonDir
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
