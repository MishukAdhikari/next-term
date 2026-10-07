import AppKit
import Network
import NextTermCore

/// Fetches the repositories open in Next Term's windows by itself, so "Pull 3" appears in the sidebar
/// without a click: on a timer while Next Term is the active app, and as the branch popup opens when the
/// last fetch is old. FetchSchedule has the rules; the fetches run on GitWriter's queue for the repository
/// (after any write of yours, never beside it), can't prompt, and leave FETCH_HEAD alone.
/// Settings › Editor › Git turns it down or off.
final class BackgroundFetcher {
    static let shared = BackgroundFetcher()
    /// Posted on the main thread after a background fetch that worked, with the repository (its common git
    /// folder, canonical) as `object`: the sidebar and the branch popup read git again.
    static let fetched = Notification.Name("NextTermBackgroundFetched")

    private(set) var schedule: FetchSchedule
    private var timer: Timer?
    private let network = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []
    private var started = false
    /// Low Power Mode and the network, as the system last said.
    private var conditions = FetchSchedule.Conditions()

    private init() {
        schedule = FetchSchedule(frequency: Self.savedFrequency)
    }

    private static var savedFrequency: FetchFrequency {
        FetchFrequency(rawValue: UserDefaults.standard.string(forKey: "backgroundFetch") ?? "") ?? .standard
    }

    /// Settings › Editor › Git: "Fetch in the background".
    var frequency: FetchFrequency {
        get { Self.savedFrequency }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "backgroundFetch")
            configure()
        }
    }

    /// For the self-test: fetch only the repository of the work tree at `root`, every `interval`, and as
    /// the popup opens once the last fetch is `staleAfter` old, as if Next Term were in front on an
    /// ordinary network, whatever the setting. While the self-test runs and this is nil, nothing is
    /// fetched: it never touches your own repositories.
    var test: (root: String, interval: TimeInterval, staleAfter: TimeInterval)? {
        didSet { configure() }
    }

    /// At launch: watch the app, the power and the network, and start the timer.
    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.restartTimer() })
        }
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.conditions.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            self?.configure()
        })
        conditions.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        network.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive, constrained = path.isConstrained, offline = path.status != .satisfied
            DispatchQueue.main.async {
                guard let self else { return }
                self.conditions.expensiveNetwork = expensive
                self.conditions.constrainedNetwork = constrained
                self.conditions.offline = offline
                self.configure() // back on an ordinary network, it catches up at once
            }
        }
        network.start(queue: DispatchQueue(label: "nextterm.fetch-network", qos: .utility))
        configure()
    }

    private func configure() {
        if let test {
            schedule.frequency = .standard
            schedule.interval = test.interval
            schedule.staleAfter = test.staleAfter
            schedule.conditions = FetchSchedule.Conditions()
        } else {
            schedule.frequency = Self.savedFrequency
            schedule.staleAfter = FetchSchedule().staleAfter
            schedule.conditions = conditions
        }
        restartTimer()
    }

    /// Ticks while Next Term is active and the setting has an interval; the first one at once.
    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard started, let every = schedule.checkEvery, test != nil || (NSApp.isActive && !SelfTest.isRequested) else { return }
        let timer = Timer(timeInterval: every, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = every / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        for (repository, root) in openRepositories() { consider(repository, root: root, .timer) }
    }

    /// The branch popup opened on `directory`: fetch if the last fetch is old. The popup has drawn
    /// already; its counts update when the fetch ends.
    func popupOpened(directory: String) {
        let repository = GitWriter.repository(of: directory)
        if mayFetch(repository) { consider(repository, root: ProjectRoot.find(from: directory), .popupOpened) }
    }

    /// A fetch you started worked, of `remote` or (nil) of every remote: it counts as the last one, and
    /// background fetch takes up a remote it had left because git needed a password.
    func fetchedByHand(repository: String, remote: String? = nil) {
        schedule.fetchedByHand(canonicalPath(repository), remote: remote, at: Date())
    }

    /// When Next Term itself last fetched the repository `directory` is in.
    func lastFetch(at directory: String) -> Date? { schedule.lastFetch(of: GitWriter.repository(of: directory)) }

    /// The repositories shown in windows' sidebars, each once, with a work tree of it to run git in.
    private func openRepositories() -> [(repository: String, root: String)] {
        var seen = Set<String>()
        var result: [(repository: String, root: String)] = []
        for controller in AppDelegate.shared?.controllers ?? [] {
            guard let root = controller.sidebar.git.snapshot?.root else { continue }
            let repository = GitWriter.repository(of: root)
            guard mayFetch(repository), seen.insert(repository).inserted else { continue }
            result.append((repository, root))
        }
        return result
    }

    /// Any repository, except while the self-test runs: then only the one it set up.
    private func mayFetch(_ repository: String) -> Bool {
        guard let test else { return !SelfTest.isRequested }
        return GitWriter.repository(of: test.root) == repository
    }

    /// A fetch or pull Next Term runs for you in the repository, or one typed in a tab in it.
    private func otherFetchRunning(_ repository: String) -> Bool {
        if GitWriter.shared.isTalkingToRemote(repository: repository) { return true }
        let tabs = AppDelegate.shared?.controllers.flatMap(\.tabs) ?? []
        return tabs.contains { tab in
            guard tab.remote == nil, tab.status.running, FetchSchedule.isFetchCommand(tab.status.command) else { return false }
            return GitWriter.repository(of: tab.liveDirectory) == repository
        }
    }

    private func consider(_ repository: String, root: String, _ trigger: FetchSchedule.Trigger) {
        let fetchedOnDisk = GitRunner.lastSuccessfulFetch(root: root)
        let decision = schedule.decision(for: repository, trigger, now: Date(), active: test != nil || NSApp.isActive,
                                         fetchedOnDisk: fetchedOnDisk, otherFetchRunning: otherFetchRunning(repository))
        guard decision == .fetch, let git = GitWriter.git else { return }
        schedule.started(repository, at: Date())
        DispatchQueue.global(qos: .utility).async {
            let tracked = FetchSchedule.trackedRemotes(at: root, git: git)
            DispatchQueue.main.async {
                let remotes = self.schedule.remotesToFetch(repository, from: tracked, fetchedOnDisk: fetchedOnDisk)
                self.fetch(repository, root: root, remotes: remotes)
            }
        }
    }

    private func fetch(_ repository: String, root: String, remotes: [String]) {
        guard !remotes.isEmpty else { return schedule.finished(repository, at: Date(), [:]) }
        GitWriter.shared.fetchInBackground(in: root, repository: repository, remotes: remotes) { [weak self] results in
            guard let self else { return }
            // Each remote by itself: one that needs a password waits alone, and one that answered is a fetch.
            var outcomes: [String: FetchSchedule.Outcome] = [:]
            for (remote, result) in zip(remotes, results) {
                outcomes[remote] = FetchSchedule.outcome(status: result.status, output: result.output)
            }
            self.schedule.finished(repository, at: Date(), outcomes)
            if outcomes.values.contains(.fetched) { NotificationCenter.default.post(name: Self.fetched, object: repository) }
        }
    }
}
