import Foundation

/// Where each agent tab's agent works, kept in one place: the place mark, list_tabs and what is offered about a
/// worktree all read it, and never work it out again themselves. Built on PlaceTracker (branches, switches under a
/// chat), it adds what an agent's session record says it did: a file written, a command run in a folder, a worktree
/// made. Those count at once. A folder move still holds for 3 s, and counts only when the folder changes: Claude
/// Code names its project folder on every line, which would otherwise pull the record back each turn.
///
/// What came before this version first ran is the baseline: it places the agent, but is never offered and never
/// enters a tab's history of the worktrees it worked in. That is decided by when each line was written, not by when
/// Next Term first read it, so a transcript first read late (a relaunch, a record read anew) is judged the same.
///
/// It outlives the agents: a tab's history stays after its agent ends, and the tabs whose agents ended are
/// reported. Pure: the reads (git, processes, session records) are the caller's, and time is passed in.
public struct WorktreeLifecycle {
    /// How long a worktree an agent made may take to show in git's list before its signal is dropped.
    public static let createdWait: TimeInterval = 10

    /// The moment this version first ran.
    public let since: Date
    public private(set) var tracker = PlaceTracker()
    /// How each agent tab's agent came to be where it is (by tab key).
    public private(set) var placements: [String: Placement] = [:]
    /// The linked worktrees each tab's agent worked in after this version first ran, first one first (by tab key):
    /// what it wrote in or made, and where its folder moved. Kept after the agent ends.
    public private(set) var history: [String: [String]] = [:]
    /// The tabs whose agents ended at the last look.
    public private(set) var ended: Set<String> = []
    private var agents: [String: AgentState] = [:]

    /// Where each agent tab's agent works, as it counts (by tab key).
    public var places: [String: AgentPlace] { tracker.places }

    public struct Placement: Equatable, Sendable {
        public enum How: Equatable, Sendable {
            /// It wrote a file or ran a command there.
            case wrote
            /// It made that worktree.
            case created
            /// Its folder is there: where it was first seen, or a move that held.
            case moved
        }

        /// The checkout's path.
        public let checkout: String
        public let how: How
        /// When: the line's time for a write, the look's for a folder.
        public let at: Date
        /// It was there before this version first ran.
        public let baseline: Bool

        public init(checkout: String, how: How, at: Date, baseline: Bool) {
            self.checkout = checkout
            self.how = how
            self.at = at
            self.baseline = baseline
        }
    }

    private struct AgentState {
        let startedAt: Date
        let repository: String
        /// The checkout its folder was in when a write last placed it: its folder counts again once it names another.
        var folderAtWrite: String??
        /// Worktrees it made that git doesn't list yet, each kept until its time is up.
        var pending: [(write: DatedWrite, until: Date)] = []
        /// The newest line's time: a line no newer, read again (a record read anew), is no new signal.
        var newest: Date?
    }

    public init(since: Date) {
        self.since = since
    }

    /// Takes one look. `classify` says what a held HEAD change in a checkout is (AgentLocation.change).
    public mutating func update(_ seen: PlaceSighting, at now: Date,
                                classify: (Checkout, _ from: CheckoutHead, _ commit: String?) -> HeadChange) {
        var fed = seen
        var placedNow: [String: Placement] = [:]
        fed.agents = seen.agents.map { agent in
            var state = agents[agent.key] ?? AgentState(startedAt: agent.startedAt, repository: agent.repository)
            if state.startedAt != agent.startedAt || state.repository != agent.repository {
                state = AgentState(startedAt: agent.startedAt, repository: agent.repository) // a new run starts over
            }
            let checkouts = seen.repositories[agent.repository] ?? []
            let folderCheckout = agent.folder.flatMap { AgentLocation.checkout(containing: $0, in: checkouts)?.path }
            if let placement = take(agent.writes, of: agent.key, into: &state, checkouts: checkouts, at: now) {
                placedNow[agent.key] = placement
                state.folderAtWrite = .some(folderCheckout)
                agents[agent.key] = state
                var placed = agent.seen(in: nil)
                placed.placed = placement.checkout
                return placed
            }
            var fedAgent = agent
            if case let .some(atWrite) = state.folderAtWrite {
                if folderCheckout == nil || folderCheckout == atWrite {
                    fedAgent = agent.seen(in: nil) // the folder it had when it wrote: no move
                } else {
                    state.folderAtWrite = nil
                }
            }
            agents[agent.key] = state
            return fedAgent
        }

        let keys = Set(seen.agents.map(\.key))
        ended = Set(agents.keys).subtracting(keys)
        agents = agents.filter { keys.contains($0.key) }
        tracker.update(fed, at: now, classify: classify)

        // The record: a write's placement as it was, or a folder's once it counts.
        var placements: [String: Placement] = [:]
        for agent in seen.agents {
            guard let place = tracker.places[agent.key] else { continue }
            let path = place.checkout.path
            if let placement = placedNow[agent.key], placement.checkout == path {
                placements[agent.key] = placement
            } else if let known = self.placements[agent.key], known.checkout == path {
                placements[agent.key] = known
            } else {
                // First seen there, or a move that held: a first sight of an agent started before this version is the baseline.
                let first = self.placements[agent.key] == nil
                let placement = Placement(checkout: path, how: .moved, at: now, baseline: first && agent.startedAt < since)
                placements[agent.key] = placement
                note(placement, of: agent.key, isMain: place.checkout.isMain)
            }
        }
        self.placements = placements
    }

    /// Keep Going: the branch now checked out becomes the chat's working branch.
    public mutating func keepGoing(_ key: String) {
        tracker.keepGoing(key)
    }

    /// Folds an agent's new writes, and the worktrees it made still waiting for git's list, into where it is: the
    /// newest that lands in a checkout of its repository wins. A worktree it made counts once git lists that very
    /// folder; any other signal counts in the checkout holding it. One outside the repository is ignored.
    private mutating func take(_ writes: [DatedWrite], of key: String, into state: inout AgentState, checkouts: [Checkout],
                               at now: Date) -> Placement? {
        let fresh = writes.filter { write in state.newest.map { write.at > $0 } ?? true }
        if let latest = fresh.map(\.at).max() { state.newest = max(state.newest ?? latest, latest) }
        let waiting = state.pending.filter { $0.until >= now }
        state.pending = []
        let all = waiting + fresh.map { ($0, now.addingTimeInterval(Self.createdWait)) }
        var placement: Placement?
        for (write, until) in all.sorted(by: { $0.write.at < $1.write.at }) {
            let checkout: Checkout?
            if write.signal.kind == .created {
                checkout = checkouts.first { $0.path == write.signal.path && !AgentLocation.isSubagentWorktree($0.path) }
                if checkout == nil { state.pending.append((write, until)) }
            } else {
                checkout = AgentLocation.checkout(containing: write.signal.path, in: checkouts)
            }
            guard let checkout else { continue }
            let found = Placement(checkout: checkout.path, how: write.signal.kind == .created ? .created : .wrote, at: write.at,
                                  baseline: write.at < since)
            placement = found
            note(found, of: key, isMain: checkout.isMain)
        }
        return placement
    }

    private mutating func note(_ placement: Placement, of key: String, isMain: Bool) {
        guard !placement.baseline, !isMain, !(history[key] ?? []).contains(placement.checkout) else { return }
        history[key, default: []].append(placement.checkout)
    }
}

// MARK: - The offer: Open as Project, from the strip above the tab

extension WorktreeLifecycle {
    /// What the strip above an agent tab has offered: Open as Project for a linked worktree its agent works in, other
    /// than the one the window shows. Once per worktree per tab, never while the person types in that tab, never for a
    /// worktree its agent was in before this version first ran (and never after, in that tab: the person knew of it).
    /// Not Now holds it until the tab's place mark brings it back. Pure, read from the record by the caller; kept in
    /// UserDefaults by the app, as `stored`, so a restored tab doesn't ask again.
    public struct Offers: Equatable, Sendable {
        public enum State: String, Sendable {
            /// Its agent was there before this version first ran: never offered.
            case baseline
            /// The strip shows it while the agent is there, until it is answered.
            case offered
            /// Not Now: held until the place mark brings it back.
            case dismissed
            /// Opened as its own project.
            case opened
        }

        /// The UserDefaults key the app keeps it under.
        public static let defaultsKey = "worktreeOffers"

        /// By tab key, then by the worktree's path.
        public private(set) var states: [String: [String: State]] = [:]

        public init() {}

        /// From what UserDefaults kept (`stored`); anything else is nothing.
        public init(stored: Any?) {
            guard let tabs = stored as? [String: [String: String]] else { return }
            for (key, worktrees) in tabs {
                let known = worktrees.compactMapValues(State.init(rawValue:))
                if !known.isEmpty { states[key] = known }
            }
        }

        /// As UserDefaults keeps it.
        public var stored: [String: [String: String]] { states.mapValues { $0.mapValues(\.rawValue) } }

        public func state(of key: String, in worktree: String) -> State? { states[key]?[worktree] }

        /// The worktree `key`'s strip shows now, if any, given where its agent works (`placement`, nil when nowhere
        /// known), whether that is the repository's main checkout, the checkout its window shows, and how long ago the
        /// person last typed in that tab. A worktree first seen as the baseline stays it; one never seen is offered once
        /// the tab has been quiet for HintRules' quiet interval.
        public mutating func strip(for key: String, placement: Placement?, isMain: Bool, shown: String?,
                                   sinceUserKey: TimeInterval) -> String? {
            guard let placement, !isMain, placement.checkout != shown else { return nil }
            let worktree = placement.checkout
            switch state(of: key, in: worktree) {
            case nil:
                if placement.baseline {
                    states[key, default: [:]][worktree] = .baseline
                    return nil
                }
                guard sinceUserKey >= HintRules.quietKeys else { return nil }
                states[key, default: [:]][worktree] = .offered
                return worktree
            case .offered?:
                return worktree
            case .baseline?, .dismissed?, .opened?:
                return nil
            }
        }

        /// Notes a placement seen in a tab the strip doesn't look at now (one not in front): a worktree first seen as
        /// the baseline is kept as the baseline, so a later look doesn't take it for new.
        public mutating func note(_ key: String, placement: Placement?, isMain: Bool) {
            guard let placement, placement.baseline, !isMain, state(of: key, in: placement.checkout) == nil else { return }
            states[key, default: [:]][placement.checkout] = .baseline
        }

        /// The strip or the tab's menu may open it as a project: offered, or held by Not Now.
        public func offerable(_ key: String, _ worktree: String) -> Bool {
            [.offered, .dismissed].contains(state(of: key, in: worktree))
        }

        /// Not Now.
        public mutating func dismiss(_ key: String, _ worktree: String) {
            guard state(of: key, in: worktree) == .offered else { return }
            states[key]?[worktree] = .dismissed
        }

        /// The place mark's click after Not Now: offered again. False when it wasn't held.
        @discardableResult
        public mutating func reoffer(_ key: String, _ worktree: String) -> Bool {
            guard state(of: key, in: worktree) == .dismissed else { return false }
            states[key]?[worktree] = .offered
            return true
        }

        /// Open as Project went through.
        public mutating func opened(_ key: String, _ worktree: String) {
            states[key, default: [:]][worktree] = .opened
        }

        /// Forgets the tabs not in `keys` (closed ones).
        public mutating func keep(only keys: Set<String>) {
            states = states.filter { keys.contains($0.key) }
        }

// MARK: - Removal once an agent ends
// Kept apart from the record above: what is offered when an agent tab's agent ends.

extension WorktreeLifecycle {
    /// The worktrees to offer removing now that the agents of the `ended` tabs ended: each linked worktree one of them
    /// worked in after this version first ran (`history`, so never the baseline), that no window shows (`open`: the
    /// folders the windows show; one inside it counts) and that was never offered (`offered`), first one first, each once.
    /// Whether removing it would lose anything is the caller's to ask then: one that would is not offered.
    public static func removalOffers(ended: Set<String>, history: [String: [String]], open: [String], offered: Set<String>) -> [String] {
        var found: [String] = []
        for key in ended.sorted() {
            for path in history[key] ?? [] where !offered.contains(path) && !found.contains(path) {
                guard !open.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) else { continue }
                found.append(path)
            }
        }
        return found
    }
}
