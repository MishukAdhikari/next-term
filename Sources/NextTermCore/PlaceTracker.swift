import Foundation

// Each agent tab's place (its checkout and branch, held), its working branch, and whether that branch was
// switched under it, kept from what the app sees each second. Pure: the reads (git, processes, session
// records) are the caller's, and time is passed in. Design: claudedocs/2026-10-09-brainstorm-branch-aware-agents (R1–R5).

/// Who switched a checkout's branch, as far as Next Term can tell (R4).
public enum SwitchAuthor: Equatable, Sendable {
    /// Next Term's own switch, from the branch popup.
    case you
    /// A `git` command a shell tab ran there.
    case tab(key: String, title: String)
    /// The one agent that was working there.
    case agent(key: String, title: String)
    /// Nobody Next Term can name; this many agents were working there at the time.
    case unknown(working: Int)

    /// The tab that made it, when one did.
    public var tabKey: String? {
        switch self {
        case let .tab(key, _), let .agent(key, _): return key
        case .you, .unknown: return nil
        }
    }
}

/// A branch switched under a chat: the branch it was on, the one now checked out, when and by whom.
public struct BranchSwitch: Equatable, Sendable {
    public let from: CheckoutHead
    public let to: CheckoutHead
    public let at: Date
    public let by: SwitchAuthor
}

/// Where an agent tab's agent works, as it counts (held).
public struct AgentPlace: Equatable, Sendable {
    /// The repository's git common folder.
    public let repository: String
    /// Its checkout, on the branch that counts.
    public let checkout: Checkout
    /// The branch its chat works on: set at its first turn, moved along by its own switches. nil before
    /// its first turn (it follows the checkout).
    public let workingBranch: CheckoutHead?
    /// Its branch was switched under it, and is not back.
    public let switched: BranchSwitch?
}

/// What one look at the app saw.
public struct PlaceSighting {
    /// Each repository's checkouts (by git common folder), as read just now.
    public var repositories: [String: [Checkout]] = [:]
    public var agents: [Agent] = []
    /// When Next Term itself last switched each checkout (by its path).
    public var ownSwitches: [String: Date] = [:]
    /// The branch that switch went to, when it named one: a switch to another branch is not it.
    public var ownTargets: [String: String] = [:]
    /// `git` commands that move HEAD, run in shell tabs lately.
    public var shellCommands: [ShellCommand] = []

    public init() {}

    public struct Agent {
        public let key: String
        public let title: String
        /// The repository it is matched against: the window's, when its folder is in one of its checkouts.
        public let repository: String
        /// Where it works now (AgentLocation.folder); nil when that can't be read.
        public let folder: String?
        public let working: Bool
        /// When this run of the agent started: a new run in the tab starts over.
        public let startedAt: Date

        public init(key: String, title: String, repository: String, folder: String?, working: Bool, startedAt: Date = .distantPast) {
            self.key = key
            self.title = title
            self.repository = repository
            self.folder = folder
            self.working = working
            self.startedAt = startedAt
        }
    }

    public struct ShellCommand {
        public let key: String
        public let title: String
        public let folder: String
        public let at: Date

        public init(key: String, title: String, folder: String, at: Date) {
            self.key = key
            self.title = title
            self.folder = folder
            self.at = at
        }
    }
}

public struct PlaceTracker {
    /// A switch is the developer's or a shell tab's when theirs came this long before it was seen.
    public static let ownWindow: TimeInterval = 10
    /// An agent counts as working at a switch when it was working this soon before it was seen.
    public static let workingWindow: TimeInterval = 2

    public private(set) var places: [String: AgentPlace] = [:]
    private var heads: [String: Held<CheckoutHead>] = [:]
    /// The commit each checkout was at when its held head last counted (for renames).
    private var commits: [String: String] = [:]
    private var checkouts: [String: Checkout] = [:]
    private var agents: [String: AgentState] = [:]
    /// Own switches and shell commands already credited with a switch: each is credited once.
    private var credited: Set<String> = []

    private struct AgentState {
        var repository: String
        var startedAt: Date
        var location = Held<String>()
        var hadTurn = false
        var lastWorking: Date?
        var workingBranch: CheckoutHead?
        var switched: BranchSwitch?
    }

    public init() {}

    /// The held head of the checkout at `path`, or what was read when none has counted yet.
    public func head(of path: String) -> CheckoutHead? { heads[path]?.value ?? checkouts[path]?.head }

    /// What the checkout at `path` is on as last read, unless git is in the middle of something there: a
    /// chat's first turn takes it, so a switch made just before the turn (not counted yet) isn't one under it.
    func headNow(of path: String) -> CheckoutHead? {
        guard let checkout = checkouts[path], !checkout.busy else { return head(of: path) }
        return checkout.head
    }

    /// Takes one look. `classify` says what a held HEAD change in a checkout is (AgentLocation.change).
    public mutating func update(_ seen: PlaceSighting, at now: Date,
                                classify: (Checkout, _ from: CheckoutHead, _ commit: String?) -> HeadChange) {
        // The checkouts' heads first: a switch is attributed to the agents where they are.
        var switches: [(checkout: Checkout, change: Held<CheckoutHead>.Change, kind: HeadChange)] = []
        var live = Set<String>()
        for checkout in seen.repositories.values.joined() {
            live.insert(checkout.path)
            checkouts[checkout.path] = checkout
            var held = heads[checkout.path] ?? Held()
            if let change = held.see(checkout.head, at: now, blocked: checkout.busy) {
                if let from = change.from {
                    switches.append((checkout, change, classify(checkout, from, commits[checkout.path])))
                }
                if let commit = checkout.commit { commits[checkout.path] = commit }
            }
            heads[checkout.path] = held
        }
        heads = heads.filter { live.contains($0.key) }
        checkouts = checkouts.filter { live.contains($0.key) }
        commits = commits.filter { live.contains($0.key) }

        for agent in seen.agents { see(agent, in: seen.repositories[agent.repository] ?? [], at: now) }
        let keys = Set(seen.agents.map(\.key))
        agents = agents.filter { keys.contains($0.key) }

        for (checkout, change, kind) in switches {
            switch kind {
            case .switched: switched(checkout.path, to: change.to, since: change.since, at: now, seen: seen)
            case let .renamed(old, new): follow(checkout.path, from: .branch(old), to: .branch(new))
            case .none: if let from = change.from { follow(checkout.path, from: from, to: change.to) }
            }
        }
        rebuild()
    }

    /// Keep Going: the branch now checked out becomes the chat's working branch.
    public mutating func keepGoing(_ key: String) {
        guard var state = agents[key], let path = state.location.value, let head = head(of: path) else { return }
        state.workingBranch = head
        state.switched = nil
        agents[key] = state
        rebuild()
    }

    // MARK: agents

    private mutating func see(_ agent: PlaceSighting.Agent, in repository: [Checkout], at now: Date) {
        let fresh = AgentState(repository: agent.repository, startedAt: agent.startedAt)
        var state = agents[agent.key] ?? fresh
        if state.repository != agent.repository || state.startedAt != agent.startedAt { state = fresh }
        if let folder = agent.folder, let checkout = AgentLocation.checkout(containing: folder, in: repository) {
            if let move = state.location.see(checkout.path, at: now, blocked: checkout.busy), move.from != nil, state.hadTurn {
                // It moved itself: its working branch is where it went.
                state.workingBranch = head(of: checkout.path)
                state.switched = nil
            }
        } else if let held = state.location.value {
            // A folder outside every checkout of the repository is no move: the agent stays where it was, and
            // a move it had started over there must hold anew.
            _ = state.location.see(held, at: now)
        }
        if agent.working {
            state.lastWorking = now
            if !state.hadTurn, let path = state.location.value {
                state.hadTurn = true
                state.workingBranch = headNow(of: path)
            }
        }
        agents[agent.key] = state
    }

    /// The checkout at `path` was switched to `head`, first seen at `since`: the agent that made it moves
    /// along, and every other chat there that has had a turn is marked, unless it is back on its branch.
    private mutating func switched(_ path: String, to head: CheckoutHead, since: Date, at now: Date, seen: PlaceSighting) {
        let here = agents.filter { $0.value.location.value == path }
        let author = author(of: path, to: head, since: since, at: now, seen: seen, here: here)
        var maker: String?
        if case let .agent(key, _) = author { maker = key }
        for (key, var state) in here where state.hadTurn {
            if key == maker || state.workingBranch == head {
                state.workingBranch = head
                state.switched = nil
            } else if let working = state.workingBranch {
                state.switched = BranchSwitch(from: working, to: head, at: now, by: author)
            }
            agents[key] = state
        }
    }

    /// R4: Next Term's own switch (to that branch, when it named one), then a shell tab's git command in
    /// that checkout, then the one agent working there; else nobody.
    private mutating func author(of path: String, to head: CheckoutHead, since: Date, at now: Date, seen: PlaceSighting,
                                 here: [String: AgentState]) -> SwitchAuthor {
        let from = since.addingTimeInterval(-Self.ownWindow)
        if credited.count > 500 { credited.removeAll() } // long past any window
        let target = seen.ownTargets[path].map { head == .branch($0) } ?? true
        if let own = seen.ownSwitches[path], own >= from, own <= now, target, credited.insert("own \(path) \(own.timeIntervalSince1970)").inserted {
            return .you
        }
        let all = Array(checkouts.values)
        let shell = seen.shellCommands.filter { command in
            command.at >= from && command.at <= now && !credited.contains(Self.creditKey(command))
                && AgentLocation.checkout(containing: command.folder, in: all)?.path == path
        }
        if let latest = shell.max(by: { $0.at < $1.at }) {
            credited.insert(Self.creditKey(latest))
            return .tab(key: latest.key, title: latest.title)
        }
        let working = here.filter { ($0.value.lastWorking ?? .distantPast) >= since.addingTimeInterval(-Self.workingWindow) }
        guard working.count == 1, let key = working.first?.key else { return .unknown(working: working.count) }
        return .agent(key: key, title: seen.agents.first { $0.key == key }?.title ?? "")
    }

    private static func creditKey(_ command: PlaceSighting.ShellCommand) -> String { "tab \(command.key) \(command.at.timeIntervalSince1970)" }

    /// A commit on a detached HEAD, or a branch renamed in place: working branches follow.
    private mutating func follow(_ path: String, from old: CheckoutHead, to new: CheckoutHead) {
        func moved(_ head: CheckoutHead) -> CheckoutHead { head == old ? new : head }
        for (key, var state) in agents where state.location.value == path {
            state.workingBranch = state.workingBranch.map(moved)
            state.switched = state.switched.map { BranchSwitch(from: moved($0.from), to: moved($0.to), at: $0.at, by: $0.by) }
            agents[key] = state
        }
    }

    private mutating func rebuild() {
        var places: [String: AgentPlace] = [:]
        for (key, var state) in agents {
            guard let path = state.location.value, let checkout = checkouts[path], let head = head(of: path) else { continue }
            // A mark clears as soon as its condition ends: the branch is back.
            if state.switched != nil, state.workingBranch == head {
                state.switched = nil
                agents[key] = state
            }
            places[key] = AgentPlace(repository: state.repository, checkout: checkout.on(head), workingBranch: state.workingBranch,
                                     switched: state.switched)
        }
        self.places = places
    }
}
