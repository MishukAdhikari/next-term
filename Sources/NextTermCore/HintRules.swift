import Foundation

/// A tip that teaches one feature once, in the chrome beside it, at the moment the user is near it, then retires for
/// good. Each is shown only on its pull trigger (the user doing the related thing), never at launch, on a new window or
/// after an update.
public enum Hint: String, CaseIterable, Sendable {
    /// The window column's hover list: it can move to the other edge.
    case columnSide
    /// A needs-you mark in a window behind: Go to Next Agent Needing You jumps to it.
    case nextAgent
    /// The column's first appearance: rest on it to see the windows, double-click to keep it open.
    case columnBasics

    /// How the hint asks: a passive line, or a notice with a button that does it.
    public enum Kind: Sendable {
        case passive, action
    }

    /// All three are passive lines; a hint with a button of its own is an `action`.
    public var kind: Kind { .passive }

    /// How many real exposures it gets: three for a line, one for a notice with an action (asking twice is nagging).
    public var limit: Int { kind == .passive ? 3 : 1 }
}

/// The rules every hint follows (plan 033 R2): when one may show, what counts as having seen it, and why it retires,
/// with what it remembers in UserDefaults. Pure but for the store's load and save, which take the defaults they use.
public enum HintRules {
    /// The least time between any two hints, across the app: a day.
    public static let spacing: TimeInterval = 24 * 60 * 60
    /// How long the user must not have typed in the window.
    public static let quietKeys: TimeInterval = 2
    /// How long the window must have been open.
    public static let settledWindow: TimeInterval = 60
    /// How long a hint must stay visible for the showing to count: a fast swipe past it uses nothing up.
    public static let exposure: TimeInterval = 1
    /// How long after it first could have shown a hint retires quietly, seen or not.
    public static let expiry: TimeInterval = 60 * 24 * 60 * 60

    /// Why a hint retired. It never shows again until Reset Tips.
    public enum Retirement: String, CaseIterable, Sendable {
        /// The user did the thing, by any route: the menu, the key, a click or an agent.
        case actionPerformed
        /// The user closed it with ×.
        case closed
        /// It was shown its limit of times.
        case countReached
        /// It could have shown for 60 days.
        case expired
    }

    /// What one hint remembers.
    public struct Record: Equatable, Sendable {
        /// Its real exposures (1 s or more).
        public var shown: Int
        public var lastShownAt: Date?
        /// When its trigger first fired with the hint still due.
        public var firstEligibleAt: Date?
        public var retired: Retirement?

        public init(shown: Int = 0, lastShownAt: Date? = nil, firstEligibleAt: Date? = nil, retired: Retirement? = nil) {
            self.shown = shown
            self.lastShownAt = lastShownAt
            self.firstEligibleAt = firstEligibleAt
            self.retired = retired
        }
    }

    /// What the moment holds when a hint's trigger fires.
    public struct Situation: Equatable, Sendable {
        /// Settings › General › "Show tips for features you haven't used".
        public var tipsOn: Bool
        public var record: Record
        /// When any hint last counted a showing.
        public var lastAnyShownAt: Date?
        public var now: Date
        /// Another hint or a notice (the window column offer, the import banner, a ghost notice) is up.
        public var noticeVisible: Bool
        /// Seconds since the last key in the window (UserKeys.since).
        public var sinceKey: TimeInterval
        /// The focused tab's agent is working, or waiting on a decision.
        public var agentBusy: Bool
        /// Seconds since the window opened.
        public var windowAge: TimeInterval

        public init(tipsOn: Bool = true, record: Record = Record(), lastAnyShownAt: Date? = nil, now: Date, noticeVisible: Bool = false,
                    sinceKey: TimeInterval = .infinity, agentBusy: Bool = false, windowAge: TimeInterval = .infinity) {
            self.tipsOn = tipsOn
            self.record = record
            self.lastAnyShownAt = lastAnyShownAt
            self.now = now
            self.noticeVisible = noticeVisible
            self.sinceKey = sinceKey
            self.agentBusy = agentBusy
            self.windowAge = windowAge
        }
    }

    /// Why a hint does not show now, the first rule that holds it back; for the self-test and for reading the rules.
    public enum HeldBack: Equatable, Sendable {
        case tipsOff, retired, limitReached, expired, tooSoon, noticeVisible, typing, agentBusy, windowNew
    }

    /// Whether `hint` shows now, its trigger having fired.
    public static func eligible(_ hint: Hint, _ situation: Situation) -> Bool { heldBack(hint, situation) == nil }

    /// What holds `hint` back now; nil, it shows. Its own state first (off, retired, used up, expired), then the
    /// moment's: a day since any hint, nothing else up, no typing for 2 s, no busy agent, a window open a minute.
    public static func heldBack(_ hint: Hint, _ situation: Situation) -> HeldBack? {
        let record = situation.record
        guard situation.tipsOn else { return .tipsOff }
        guard record.retired == nil else { return .retired }
        guard record.shown < hint.limit else { return .limitReached }
        if isExpired(record, now: situation.now) { return .expired }
        if let last = situation.lastAnyShownAt, situation.now.timeIntervalSince(last) < spacing { return .tooSoon }
        if situation.noticeVisible { return .noticeVisible }
        if situation.sinceKey < quietKeys { return .typing }
        if situation.agentBusy { return .agentBusy }
        if situation.windowAge < settledWindow { return .windowNew }
        return nil
    }

    /// 60 days since the hint first could have shown.
    public static func isExpired(_ record: Record, now: Date) -> Bool {
        guard let first = record.firstEligibleAt else { return false }
        return now.timeIntervalSince(first) >= expiry
    }

    /// Whether a showing that lasted `seconds` counts as seen.
    public static func counts(_ seconds: TimeInterval) -> Bool { seconds >= exposure }

    /// The trigger fired with the hint still due: the 60 days start, once.
    public static func noteTriggered(_ record: Record, now: Date) -> Record {
        guard record.retired == nil, record.firstEligibleAt == nil else { return record }
        var record = record
        record.firstEligibleAt = now
        return record
    }

    /// The hint was visible for `seconds`: from 1 s it counts, and the last of its limit retires it. Returns the record
    /// and whether the showing counted, for `lastAnyShownAt`.
    public static func noteExposure(_ hint: Hint, _ record: Record, seconds: TimeInterval, now: Date) -> (record: Record, counted: Bool) {
        guard counts(seconds), record.retired == nil else { return (record, false) }
        var record = record
        record.shown += 1
        record.lastShownAt = now
        if record.shown >= hint.limit { record.retired = .countReached }
        return (record, true)
    }

    /// Retires the hint for `reason`; one retired already keeps its first reason.
    public static func retire(_ record: Record, _ reason: Retirement) -> Record {
        guard record.retired == nil else { return record }
        var record = record
        record.retired = reason
        return record
    }

    // MARK: the store

    /// Settings › General's checkbox, on unless turned off. Not a `hint.` key: Reset Tips leaves it as it is.
    public static let tipsKey = "showTips"
    /// When any hint last counted a showing, in seconds since 1970.
    public static let lastAnyShownKey = "hint.lastAnyShownAt"
    /// The upgrade seeding has run (HintCenter.seed): it runs once, and Reset Tips leaves it, so a reset shows again
    /// the tips of features already used.
    public static let seededKey = "hint.seeded"

    /// One of a hint's keys: `hint.<id>.shown`, `.lastShownAt`, `.firstEligibleAt` or `.retired`.
    public enum Field: String, CaseIterable, Sendable {
        case shown, lastShownAt, firstEligibleAt, retired
    }

    public static func key(_ hint: Hint, _ field: Field) -> String { "hint.\(hint.rawValue).\(field.rawValue)" }

    /// What Reset Tips clears: every hint's keys and the time of the last one.
    public static let resetKeys: [String] = Hint.allCases.flatMap { hint in Field.allCases.map { key(hint, $0) } } + [lastAnyShownKey]
    /// Every key the hints keep, for the self-test to put back.
    public static let keys: [String] = resetKeys + [seededKey, tipsKey]

    /// Whether tips are on in `defaults`.
    public static func tipsOn(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: tipsKey) as? Bool ?? true }

    public static func load(_ hint: Hint, _ defaults: UserDefaults) -> Record {
        func date(_ field: Field) -> Date? {
            (defaults.object(forKey: key(hint, field)) as? Double).map { Date(timeIntervalSince1970: $0) }
        }
        return Record(shown: defaults.integer(forKey: key(hint, .shown)), lastShownAt: date(.lastShownAt),
                      firstEligibleAt: date(.firstEligibleAt),
                      retired: defaults.string(forKey: key(hint, .retired)).flatMap(Retirement.init(rawValue:)))
    }

    /// Saves `record`; a field it doesn't have is removed, so a fresh record leaves no key behind.
    public static func save(_ record: Record, _ hint: Hint, _ defaults: UserDefaults) {
        func set(_ value: Any?, _ field: Field) {
            if let value { defaults.set(value, forKey: key(hint, field)) } else { defaults.removeObject(forKey: key(hint, field)) }
        }
        set(record.shown > 0 ? record.shown : nil, .shown)
        set(record.lastShownAt?.timeIntervalSince1970, .lastShownAt)
        set(record.firstEligibleAt?.timeIntervalSince1970, .firstEligibleAt)
        set(record.retired?.rawValue, .retired)
    }

    public static func lastAnyShownAt(_ defaults: UserDefaults) -> Date? {
        (defaults.object(forKey: lastAnyShownKey) as? Double).map { Date(timeIntervalSince1970: $0) }
    }

    public static func setLastAnyShownAt(_ date: Date, _ defaults: UserDefaults) {
        defaults.set(date.timeIntervalSince1970, forKey: lastAnyShownKey)
    }

    /// Reset Tips and Help › Show Tips Again: tips seen or closed show again. The features' own settings, the off
    /// switch and the seeding mark stay.
    public static func reset(_ defaults: UserDefaults) {
        resetKeys.forEach(defaults.removeObject(forKey:))
    }

    // MARK: updates

    /// What an install already shows of each feature, for the upgrade seeding.
    public struct InUse: Equatable, Sendable {
        /// The window column was put on a side of its own (`windowColumnSide`).
        public var columnSideChosen: Bool
        /// The column was ever pinned unfolded or folded back (its setting was ever written).
        public var columnExpandedEver: Bool

        public init(columnSideChosen: Bool = false, columnExpandedEver: Bool = false) {
            self.columnSideChosen = columnSideChosen
            self.columnExpandedEver = columnExpandedEver
        }
    }

    /// The hints whose feature is in use already, retired as `actionPerformed` by the seeding. Every other hint stays
    /// due, and waits for its trigger like a new user's: no what's-new popover, ever. Nothing kept tells whether Go to
    /// Next Agent Needing You was used before hints came in, so `nextAgent` is never seeded; its first use from now on
    /// retires it (HintCenter.retire).
    public static func seeded(_ inUse: InUse) -> [Hint] {
        Hint.allCases.filter { hint in
            switch hint {
            case .columnSide: return inUse.columnSideChosen
            case .columnBasics: return inUse.columnExpandedEver
            case .nextAgent: return false
            }
        }
    }
}
