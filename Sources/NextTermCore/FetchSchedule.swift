import Foundation

// Background fetch: Next Term fetches the repositories open in its windows by itself, so "Pull 3" shows
// without a click. These are the rules; the app runs the fetches (through GitWriter's queue, so never at
// the same time as one of your own git writes). Design: claudedocs/research_next-term-git-branches (8.10,
// 8.12).

/// How often Next Term fetches by itself (Settings › Editor › Git).
public enum FetchFrequency: String, CaseIterable, Sendable {
    case fiveMinutes = "5", tenMinutes = "10", thirtyMinutes = "30", onPopup = "popup", off

    /// Every 10 minutes: as often as some git clients, a good deal less than others.
    public static let standard = FetchFrequency.tenMinutes

    public var title: String {
        switch self {
        case .fiveMinutes: return "Every 5 minutes"
        case .tenMinutes: return "Every 10 minutes"
        case .thirtyMinutes: return "Every 30 minutes"
        case .onPopup: return "Only when opening the branch popup"
        case .off: return "Off"
        }
    }

    /// The time between fetches while a window is open; nil when nothing fetches on a timer.
    public var interval: TimeInterval? {
        switch self {
        case .fiveMinutes: return 5 * 60
        case .tenMinutes: return 10 * 60
        case .thirtyMinutes: return 30 * 60
        case .onPopup, .off: return nil
        }
    }
}

/// When to fetch each repository in the background. Pure: it is told the time and what is going on, and
/// remembers only what it was told, so its rules can be tested without waiting.
///
/// - On a timer, every `interval`, while a window for the repository is open (the app asks only about
///   those) and Next Term is the active app.
/// - When the branch popup opens, if the last fetch is over `staleAfter` old.
/// - Never while another fetch for the repository runs: one of its own, or yours in a tab.
/// - Paused in Low Power Mode and on an expensive, constrained or missing network; and for a repository,
///   after git said it needs a person (a password, a passphrase, a host key), until a fetch you start
///   succeeds.
///
/// Repositories are named by their common git folder, so the worktrees of one share a schedule.
public struct FetchSchedule: Sendable {
    public var frequency: FetchFrequency {
        didSet { interval = frequency.interval }
    }
    /// The frequency's interval; the self-test sets a shorter one.
    public var interval: TimeInterval?
    /// How old the last fetch must be for the branch popup to fetch as it opens.
    public var staleAfter: TimeInterval = 5 * 60
    public var conditions = Conditions()

    public init(frequency: FetchFrequency = .standard) {
        self.frequency = frequency
        interval = frequency.interval
    }

    /// What pauses every background fetch while it lasts.
    public struct Conditions: Equatable, Sendable {
        public var lowPowerMode = false
        /// A personal hotspot, or another network the system says costs money.
        public var expensiveNetwork = false
        /// Low Data Mode.
        public var constrainedNetwork = false
        public var offline = false

        public init(lowPowerMode: Bool = false, expensiveNetwork: Bool = false, constrainedNetwork: Bool = false, offline: Bool = false) {
            self.lowPowerMode = lowPowerMode
            self.expensiveNetwork = expensiveNetwork
            self.constrainedNetwork = constrainedNetwork
            self.offline = offline
        }
    }

    public enum Trigger: Sendable {
        /// The interval came round.
        case timer
        /// The branch popup opened (it draws first; its counts update when the fetch ends).
        case popupOpened
    }

    public enum Decision: Equatable, Sendable {
        case fetch
        case skip(Reason)
    }

    /// Why a fetch is not made now.
    public enum Reason: Equatable, Sendable {
        /// The setting: off, or (for the timer) only when opening the popup.
        case off
        /// Next Term is not the active app.
        case inactive
        /// A fetch for the repository is under way, Next Term's or one in a tab.
        case running
        /// Git asked for a password, a passphrase or a host key; a fetch you start turns it back on.
        case needsPerson
        case lowPower
        /// Expensive, constrained, or none.
        case network
        /// The last fetch is recent enough.
        case recent
    }

    /// How a background fetch ended.
    public enum Outcome: Equatable, Sendable {
        case fetched
        /// No local branch tracks a remote: nothing to fetch, and nothing to try again until the interval.
        case nothingToFetch
        /// Unreachable, timed out, or anything else that may pass by itself.
        case failed
        /// It needs a password, a passphrase or a host key: stop until a fetch you start succeeds.
        case needsPerson
    }

    private struct State: Sendable {
        /// The last fetch that succeeded, background or by hand through Next Term.
        var fetched: Date?
        /// The last background attempt, whatever came of it.
        var tried: Date?
        var running = false
        /// When git last said it needs a person.
        var needsPersonSince: Date?
    }

    private var states: [String: State] = [:]

    /// Whether to fetch `repository` now. `fetchedOnDisk` is FETCH_HEAD's date (a fetch or pull in a
    /// terminal, or by an agent); `otherFetchRunning`, whether one runs now.
    public func decision(for repository: String, _ trigger: Trigger, now: Date, active: Bool,
                         fetchedOnDisk: Date? = nil, otherFetchRunning: Bool = false) -> Decision {
        let state = states[repository] ?? State()
        let threshold: TimeInterval
        switch trigger {
        case .timer:
            guard let interval else { return .skip(.off) }
            threshold = interval
        case .popupOpened:
            guard frequency != .off else { return .skip(.off) }
            threshold = staleAfter
        }
        if state.running || otherFetchRunning { return .skip(.running) }
        if let since = state.needsPersonSince, !(fetchedOnDisk.map { $0 > since } ?? false) { return .skip(.needsPerson) }
        if conditions.lowPowerMode { return .skip(.lowPower) }
        if conditions.expensiveNetwork || conditions.constrainedNetwork || conditions.offline { return .skip(.network) }
        if trigger == .timer && !active { return .skip(.inactive) }
        guard let last = [state.fetched, state.tried, fetchedOnDisk].compactMap({ $0 }).max() else { return .fetch }
        let age = now.timeIntervalSince(last)
        // The timer fetches once the interval has passed; the popup only when the fetch is over its age.
        let due = trigger == .timer ? age >= threshold : age > threshold
        return due ? .fetch : .skip(.recent)
    }

    /// A background fetch of `repository` began.
    public mutating func started(_ repository: String, at now: Date) {
        states[repository, default: State()].running = true
        states[repository, default: State()].tried = now
    }

    public mutating func finished(_ repository: String, at now: Date, _ outcome: Outcome) {
        var state = states[repository] ?? State()
        state.running = false
        switch outcome {
        case .fetched:
            state.fetched = now
            state.needsPersonSince = nil
        case .needsPerson:
            state.needsPersonSince = now
        case .nothingToFetch, .failed:
            break
        }
        states[repository] = state
    }

    /// A fetch you started succeeded: it counts as the last fetch, and turns background fetch back on.
    public mutating func fetchedByHand(_ repository: String, at now: Date) {
        states[repository, default: State()].fetched = now
        states[repository, default: State()].needsPersonSince = nil
    }

    /// When Next Term itself last fetched `repository`. A background fetch leaves FETCH_HEAD alone, so
    /// "Last fetched" is the newer of this and FETCH_HEAD's date.
    public func lastFetch(of repository: String) -> Date? { states[repository]?.fetched }

    public func isRunning(_ repository: String) -> Bool { states[repository]?.running ?? false }

    /// Whether git's need of a person has paused `repository`.
    public func isPausedForPerson(_ repository: String) -> Bool { states[repository]?.needsPersonSince != nil }

    // MARK: the commands

    /// One remote's background fetch. FETCH_HEAD is left as it is (a `git pull` in a tab reads it between
    /// its own fetch and merge), and no maintenance starts behind your back.
    public static func arguments(remote: String) -> [String] {
        ["fetch", "--no-write-fetch-head", "--no-auto-maintenance", "--porcelain", remote]
    }

    /// The remotes some local branch tracks, from `git for-each-ref --format=%(upstream:remotename)
    /// refs/heads`, each once, in order. Not "." (a branch tracking another local one), and nothing that
    /// could be read as an option or is a URL rather than a remote's name.
    public static func trackedRemotes(_ output: String) -> [String] {
        var remotes: [String] = []
        for line in output.split(separator: "\n") {
            let name = line.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != ".", !name.hasPrefix("-"), !name.contains(":"), !remotes.contains(name) else { continue }
            remotes.append(name)
        }
        return remotes
    }

    /// The remotes some local branch of the work tree at `root` tracks (a read, with --no-optional-locks).
    public static func trackedRemotes(at root: String, git: String) -> [String] {
        let args = ["-C", root, "--no-optional-locks", "for-each-ref", "--format=%(upstream:remotename)", "refs/heads"]
        return trackedRemotes(GitRunner.run(git, args, timeout: 10).map { String(decoding: $0, as: UTF8.self) } ?? "")
    }

    /// How often the app looks at the schedule: a tenth of the interval, between half a second and a minute.
    public var checkEvery: TimeInterval? { interval.map { min(60, max(0.5, $0 / 10)) } }

    /// How a background fetch went, from its exit status and what git printed.
    public static func outcome(status: Int32, output: String) -> Outcome {
        if status == 0 { return .fetched }
        switch GitOutput.classify(output) {
        case .authentication?, .hostKey?: return .needsPerson
        default: return .failed
        }
    }

    /// Whether a command line typed in a tab fetches: `git fetch`, `git pull`, `git remote update`, also
    /// with git's own options first (`git -C app pull`) or after `cd x &&`.
    public static func isFetchCommand(_ line: String) -> Bool {
        CommandClassifier.segments(line).contains { segment in
            let (name, args) = CommandClassifier.parse(segment)
            guard name == "git" else { return false }
            var rest = args[...]
            while let first = rest.first, first.hasPrefix("-") {
                rest.removeFirst()
                // Options whose value is the next word.
                if ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"].contains(first) { rest = rest.dropFirst() }
            }
            switch rest.first {
            case "fetch", "pull": return true
            case "remote": return rest.dropFirst().first == "update"
            default: return false
            }
        }
    }
}
