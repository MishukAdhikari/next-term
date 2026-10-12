import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Secrets' approvals that outlive one request and the limits on asking: the pure rules, with the
// clock injected. The app holds a grant's values; nothing here holds one. `ContinuousClock` serves grants, pauses,
// tickets and cards, so sleep counts; `Date` is only for what Settings and the notes show.

/// A file's identity: device, inode, size and modification time. A grant bound to an agent's or a command's file
/// asks again when that file changes.
public struct SecretFileIdentity: Hashable, Codable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    /// Nanoseconds since 1970.
    public let modified: Int64

    public init(device: UInt64, inode: UInt64, size: Int64, modified: Int64) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modified = modified
    }

    /// The identity of the file at `path`, links followed; nil when there is none.
    public static func of(_ path: String) -> SecretFileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return SecretFileIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino),
                                  size: Int64(info.st_size), modified: modified)
    }
}

/// What a grant is bound to: a request it answers must be identical in every field.
public struct SecretBinding: Hashable, Sendable {
    public enum Source: String, Hashable, Sendable {
        /// `run_with_secrets`.
        case tool
        /// `nxtrm secret run` from an MCP server's config, a script or a person.
        case wrapper
    }

    public var source: Source
    /// Who asks (`MCPWriteControl.asker`, or `wrapper:` with the agent's path and an argv digest).
    public var asker: String
    /// The asking agent's program, as its tab or process tree names it.
    public var program: String
    /// A wrapper's agent: its executable's path and file identity, and its `argv[1]` under an interpreter.
    public var agentPath: String?
    public var agentIdentity: SecretFileIdentity?
    public var agentScript: String?
    /// A wrapper's command: the executable it resolved with its own `PATH`, and that file's identity.
    public var executable: String?
    public var executableIdentity: SecretFileIdentity?
    /// The command: `run_with_secrets`' text, or the wrapper's argv after `--`.
    public var command: [String]
    /// NAME → ENVNAME.
    public var keys: [String: String]
    public var folder: String
    /// `run_with_secrets`: "new" for a new tab, or the tab's id.
    public var target: String?
    /// The variables the panel warned about, by name, with a SHA-256 of each value.
    public var warned: [String: String]
    /// A SHA-256 of the folder's `.env` as read, or "none".
    public var envDigest: String

    public init(source: Source, asker: String, program: String, agentPath: String? = nil, agentIdentity: SecretFileIdentity? = nil,
                agentScript: String? = nil, executable: String? = nil, executableIdentity: SecretFileIdentity? = nil,
                command: [String], keys: [String: String], folder: String, target: String? = nil, warned: [String: String] = [:],
                envDigest: String = "none") {
        self.source = source
        self.asker = asker
        self.program = program
        self.agentPath = agentPath
        self.agentIdentity = agentIdentity
        self.agentScript = agentScript
        self.executable = executable
        self.executableIdentity = executableIdentity
        self.command = command
        self.keys = keys
        self.folder = folder
        self.target = target
        self.warned = warned
        self.envDigest = envDigest
    }

    /// The keys' names, sorted.
    public var names: [String] { keys.keys.sorted() }
}

/// What ends grants.
public enum SecretGrantEvent: Equatable, Sendable {
    case screenLocked, systemSleep, sessionResigned
    /// The display sleeping alone ends nothing.
    case displaySleep
    case quit
    case revoke(String)
    case revokeAll
    /// A key replaced, renamed or deleted.
    case keyChanged(String)
    /// "Pause Key Requests for 1 Hour…".
    case hourPause
    /// Start Over: the vault, and every key a grant holds, is gone.
    case startedOver
    /// MCP or a remote connection typed into this tab (its id, as `MCPWriteControl.asker` gives it): the
    /// `run_with_secrets` grants it asked for end.
    case tabGotInput(String)
}

/// "Allow for 15 minutes", "Allow this command until the Mac locks", or one use within 2 minutes, for a wrapper that
/// left during Touch ID: the same request again, and only that, starts with no panel.
public struct SecretGrant: Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case fifteenMinutes, untilLock, oneUse
    }

    public static let fifteenMinutes: Duration = .seconds(15 * 60)
    public static let oneUseWindow: Duration = .seconds(2 * 60)

    public let id: String
    public let kind: Kind
    public let binding: SecretBinding
    public let made: ContinuousClock.Instant
    /// When it was made, for display.
    public let madeAt: Date
    public private(set) var usesLeft: Int?

    public init(kind: Kind, binding: SecretBinding, made: ContinuousClock.Instant, madeAt: Date = Date(), id: String = UUID().uuidString) {
        self.id = id
        self.kind = kind
        self.binding = binding
        self.made = made
        self.madeAt = madeAt
        usesLeft = kind == .oneUse ? 1 : nil
    }

    public var names: [String] { binding.names }

    /// When it ends on its own: after 15 minutes, or 2 for one use. Until the Mac locks has no end of its own.
    public var expires: ContinuousClock.Instant? {
        switch kind {
        case .fifteenMinutes: return made.advanced(by: Self.fifteenMinutes)
        case .oneUse: return made.advanced(by: Self.oneUseWindow)
        case .untilLock: return nil
        }
    }

    /// How long until it ends on its own, zero once it has; nil for until the Mac locks. The app's timer drops its
    /// values right then.
    public func timeLeft(at now: ContinuousClock.Instant) -> Duration? {
        guard let expires else { return nil }
        return now >= expires ? .zero : expires - now
    }

    public func isExpired(at now: ContinuousClock.Instant) -> Bool {
        if let expires, now >= expires { return true }
        return usesLeft == 0
    }

    /// Whether it answers `binding` at `now`: identical in every field, not expired, not used up.
    public func matches(_ binding: SecretBinding, at now: ContinuousClock.Instant) -> Bool {
        !isExpired(at: now) && binding == self.binding
    }

    /// Whether `event` ends it.
    public func ended(by event: SecretGrantEvent) -> Bool {
        switch event {
        case .screenLocked, .systemSleep, .sessionResigned, .quit, .revokeAll, .hourPause, .startedOver: return true
        case .displaySleep: return false
        case .revoke(let id): return id == self.id
        case .keyChanged(let name): return binding.keys[name] != nil
        case .tabGotInput(let tab): return binding.source == .tool && binding.asker == tab
        }
    }

    mutating func use() {
        if let left = usesLeft { usesLeft = max(0, left - 1) }
    }
}

/// One Allow, as the callers waiting on its panel use it: the request's own caller first, then each identical request
/// that took the panel over, in turn. "Allow once", and a remote approval, which offers only that, starts one command:
/// the first caller uses it, and each later one is refused as used already. The lasting approvals reach every caller,
/// as the grant they make would answer each of them.
public struct SecretApprovalUse: Sendable {
    public let approval: SecretAudit.Approval
    public private(set) var isUsed = false

    public init(_ approval: SecretAudit.Approval) {
        self.approval = approval
    }

    /// "Allow once" and a remote approval.
    public var isSingleUse: Bool { approval == .once || approval == .remote }

    /// Takes a use for the next caller: true when it gets the keys. A single-use approval is spent by the first.
    public mutating func take() -> Bool {
        if isSingleUse, isUsed { return false }
        isUsed = true
        return true
    }
}

/// The grants in force. The app keeps each one's values by its id.
public struct SecretGrantBook: Sendable {
    public private(set) var grants: [SecretGrant] = []

    public init() {}

    public mutating func add(_ grant: SecretGrant) {
        grants.append(grant)
    }

    /// The grant that answers `binding` now, used once (a one-use grant is then spent), or nil.
    public mutating func take(_ binding: SecretBinding, at now: ContinuousClock.Instant) -> SecretGrant? {
        guard let index = grants.firstIndex(where: { $0.matches(binding, at: now) }) else { return nil }
        grants[index].use()
        return grants[index]
    }

    /// Ends the grants `event` ends; returns them.
    @discardableResult
    public mutating func end(_ event: SecretGrantEvent) -> [SecretGrant] {
        let ended = grants.filter { $0.ended(by: event) }
        grants.removeAll { $0.ended(by: event) }
        return ended
    }

    /// Drops the grants expired or used up at `now`; returns them.
    @discardableResult
    public mutating func expire(at now: ContinuousClock.Instant) -> [SecretGrant] {
        let ended = grants.filter { $0.isExpired(at: now) }
        grants.removeAll { $0.isExpired(at: now) }
        return ended
    }
}

/// The limits on asking, which spare normal use: only declined and unanswered requests count.
public struct SecretLimits: Sendable {
    /// One panel shows; up to 5 wait; more get `busy`.
    public static let queueSize = 5
    /// A decline pauses that same request for 10 minutes.
    public static let pause: Duration = .seconds(600)
    /// Declined or unanswered requests in a session, per asker and across all.
    public static let perAsker = 10
    public static let overall = 30
    public static let hour: Duration = .seconds(3600)

    /// Why a request is refused before any panel.
    public enum Refusal: Equatable, Sendable {
        /// The queue is full.
        case busy
        /// The same request was declined within 10 minutes.
        case paused(declinedAt: Date, until: Date)
        /// Decline and Stop Asking, until Next Term quits.
        case stopped
        /// A count is reached.
        case limited
        /// "Pause Key Requests for 1 Hour…".
        case declining(until: Date)
    }

    /// How a request ended. Only `declined` and `unanswered` count.
    public enum Outcome: Sendable {
        case allowed, answeredByGrant, declined, unanswered, tookOver, refusedByLimits
    }

    public struct Pause: Sendable {
        public let asker: String
        public let until: ContinuousClock.Instant
        public let declinedAt: Date
        public let untilDate: Date
    }

    public private(set) var pauses: [SecretBinding: Pause] = [:]
    public private(set) var stopped: Set<String> = []
    public private(set) var counts: [String: Int] = [:]
    public private(set) var total = 0
    public private(set) var hourPause: (until: ContinuousClock.Instant, untilDate: Date)?

    public init() {}

    /// Whether a new request would make the queue too long.
    public static func isBusy(waiting: Int) -> Bool { waiting >= queueSize }

    /// Why a request from `asker` for `binding` is refused at `now`, or nil to let it ask.
    public func admit(asker: String, binding: SecretBinding, at now: ContinuousClock.Instant) -> Refusal? {
        if let hourPause, now < hourPause.until { return .declining(until: hourPause.untilDate) }
        if stopped.contains(asker) { return .stopped }
        if let pause = pauses[binding], now < pause.until { return .paused(declinedAt: pause.declinedAt, until: pause.untilDate) }
        if counts[asker, default: 0] >= Self.perAsker || total >= Self.overall { return .limited }
        return nil
    }

    /// As `admit`, for `run_with_secrets` before its tab exists: the tab's warned variables are not known yet,
    /// so a paused request matches whatever they were. A request the limits refuse opens no tab.
    public func admitBeforeTab(asker: String, binding: SecretBinding, at now: ContinuousClock.Instant) -> Refusal? {
        if let hourPause, now < hourPause.until { return .declining(until: hourPause.untilDate) }
        if stopped.contains(asker) { return .stopped }
        let loose = Self.withoutTab(binding)
        if let pause = pauses.first(where: { now < $0.value.until && Self.withoutTab($0.key) == loose })?.value {
            return .paused(declinedAt: pause.declinedAt, until: pause.untilDate)
        }
        if counts[asker, default: 0] >= Self.perAsker || total >= Self.overall { return .limited }
        return nil
    }

    /// A binding without what only the tab's wrapper knows: its warned variables.
    static func withoutTab(_ binding: SecretBinding) -> SecretBinding {
        var loose = binding
        loose.warned = [:]
        return loose
    }

    /// Records how a request ended, once, when it ends. A decline also pauses that same request for 10 minutes.
    public mutating func record(_ outcome: Outcome, asker: String, binding: SecretBinding, at now: ContinuousClock.Instant,
                                date: Date = Date()) {
        switch outcome {
        case .declined:
            counts[asker, default: 0] += 1
            total += 1
            pauses[binding] = Pause(asker: asker, until: now.advanced(by: Self.pause), declinedAt: date,
                                    untilDate: date.addingTimeInterval(600))
        case .unanswered:
            counts[asker, default: 0] += 1
            total += 1
        case .allowed, .answeredByGrant, .tookOver, .refusedByLimits:
            break
        }
    }

    /// Decline and Stop Asking: the asker is refused until Next Term quits, or Resume.
    public mutating func stop(_ asker: String) {
        stopped.insert(asker)
    }

    /// "Pause Key Requests for 1 Hour…": every request is refused for an hour.
    public mutating func pauseForAnHour(at now: ContinuousClock.Instant, date: Date = Date()) {
        hourPause = (now.advanced(by: Self.hour), date.addingTimeInterval(3600))
    }

    /// Resume Asking: the hour pause ends.
    public mutating func resumeAsking() {
        hourPause = nil
    }

    /// Resume, for a paused request.
    public mutating func resume(_ binding: SecretBinding) {
        pauses[binding] = nil
    }

    /// Resume, for a stopped asker or one whose count is reached. The overall count drops by the asker's own.
    public mutating func resume(asker: String) {
        stopped.remove(asker)
        total = max(0, total - counts[asker, default: 0])
        counts[asker] = nil
    }

    /// The pauses still running at `now`.
    public func activePauses(at now: ContinuousClock.Instant) -> [(binding: SecretBinding, pause: Pause)] {
        pauses.filter { now < $0.value.until }.map { ($0.key, $0.value) }
    }

    /// The askers whose own count is reached.
    public var limitedAskers: [String] {
        counts.filter { $0.value >= Self.perAsker }.map(\.key).sorted()
    }
}
