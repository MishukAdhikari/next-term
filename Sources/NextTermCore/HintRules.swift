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

    /// The command whose key the hint teaches or whose feature it is, as the shortcut table names it: a key the user
    /// rebound for it means they know it, and the seeding retires the hint. Nil for a hint with no command of its own.
    public var command: String? {
        switch self {
        case .nextAgent: return "goToNextAgentNeedingYou:"
        case .columnSide, .columnBasics: return nil
        }
    }

    /// It sits in a tab bar, beside where the Update button would be: that button holds it back.
    public var inTabBar: Bool { false }

    /// Its feature leaves nothing behind that says it was used, so an install that had it before the hint gets a watch
    /// (HintRules.watch) in place of a fact: use in those days retires the hint before it ever shows.
    public var traceless: Bool {
        switch self {
        case .nextAgent: return true
        case .columnSide, .columnBasics: return false
        }
    }
}

/// What else may be up when a hint's trigger fires: any of them holds every hint back, so one thing speaks at a time.
public struct HintNotices: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Another hint.
    public static let hint = HintNotices(rawValue: 1 << 0)
    /// A toast: a git command's, or the window column's offer to show or hide it.
    public static let toast = HintNotices(rawValue: 1 << 1)
    /// A sheet on the window or a modal panel: the Add Task sheet and its offer, an alert.
    public static let sheet = HintNotices(rawValue: 1 << 2)
    /// The import window, "Coming from another app?" or an agent's request with its banner.
    public static let importWindow = HintNotices(rawValue: 1 << 3)
    /// A notice in the focused tab's terminal: the suggestions' question about a plugin, or their first-use hint.
    public static let ghostNotice = HintNotices(rawValue: 1 << 4)
    /// The Update button in the window's tab bar, for a hint that would sit in a tab bar beside it.
    public static let updateButton = HintNotices(rawValue: 1 << 5)
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
    /// How long an install that had a traceless feature before its hint waits, watching for its use, before the hint
    /// may show: two weeks.
    public static let watch: TimeInterval = 14 * 24 * 60 * 60

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
        /// When the seeding started its watch (an install that had the feature before the hint): nothing shows for
        /// `HintRules.watch` from then, and nothing starts its 60 days.
        public var watchFrom: Date?

        public init(shown: Int = 0, lastShownAt: Date? = nil, firstEligibleAt: Date? = nil, retired: Retirement? = nil, watchFrom: Date? = nil) {
            self.shown = shown
            self.lastShownAt = lastShownAt
            self.firstEligibleAt = firstEligibleAt
            self.retired = retired
            self.watchFrom = watchFrom
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
        /// Another hint or a notice is up (HintNotices).
        public var notices: HintNotices
        public var noticeVisible: Bool { !notices.isEmpty }
        /// Seconds since the last key in the window (UserKeys.since).
        public var sinceKey: TimeInterval
        /// The focused tab's agent is working, or waiting on a decision.
        public var agentBusy: Bool
        /// Seconds since the window opened.
        public var windowAge: TimeInterval

        public init(tipsOn: Bool = true, record: Record = Record(), lastAnyShownAt: Date? = nil, now: Date, notices: HintNotices = [],
                    sinceKey: TimeInterval = .infinity, agentBusy: Bool = false, windowAge: TimeInterval = .infinity) {
            self.tipsOn = tipsOn
            self.record = record
            self.lastAnyShownAt = lastAnyShownAt
            self.now = now
            self.notices = notices
            self.sinceKey = sinceKey
            self.agentBusy = agentBusy
            self.windowAge = windowAge
        }
    }

    /// Why a hint does not show now, the first rule that holds it back; for the self-test and for reading the rules.
    public enum HeldBack: Equatable, Sendable {
        case tipsOff, retired, limitReached, watching, expired, tooSoon, noticeVisible, typing, agentBusy, windowNew
    }

    /// Whether `hint` shows now, its trigger having fired.
    public static func eligible(_ hint: Hint, _ situation: Situation) -> Bool { heldBack(hint, situation) == nil }

    /// What holds `hint` back now; nil, it shows. Its own state first (off, retired, used up, watched, expired), then the
    /// moment's: a day since any hint, nothing else up, no typing for 2 s, no busy agent, a window open a minute.
    public static func heldBack(_ hint: Hint, _ situation: Situation) -> HeldBack? {
        let record = situation.record
        guard situation.tipsOn else { return .tipsOff }
        guard record.retired == nil else { return .retired }
        guard record.shown < hint.limit else { return .limitReached }
        if isWatching(record, now: situation.now) { return .watching }
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

    /// Within the two weeks of its watch.
    public static func isWatching(_ record: Record, now: Date) -> Bool {
        guard let from = record.watchFrom else { return false }
        return now.timeIntervalSince(from) < watch
    }

    /// Whether a showing that lasted `seconds` counts as seen.
    public static func counts(_ seconds: TimeInterval) -> Bool { seconds >= exposure }

    /// The trigger fired with the hint still due: the 60 days start, once, and not while it is watched.
    public static func noteTriggered(_ record: Record, now: Date) -> Record {
        guard record.retired == nil, record.firstEligibleAt == nil, !isWatching(record, now: now) else { return record }
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
    /// The first seeding, for the three hints 0.11.38 brought, has run. Kept and still written, so a version from
    /// before per-hint seeding finds it; read only when `seededHintsKey` is missing.
    public static let seededKey = "hint.seeded"
    /// The hints the seeding has looked at, each once (`seed`): a hint a later version brings is seeded at the first
    /// launch that knows it. Reset Tips leaves it, so a reset shows again the tips of features already used.
    public static let seededHintsKey = "hint.seededHints"

    /// One of a hint's keys: `hint.<id>.shown`, `.lastShownAt`, `.firstEligibleAt`, `.retired` or `.watchFrom`.
    public enum Field: String, CaseIterable, Sendable {
        case shown, lastShownAt, firstEligibleAt, retired, watchFrom
    }

    public static func key(_ hint: Hint, _ field: Field) -> String { "hint.\(hint.rawValue).\(field.rawValue)" }

    /// What Reset Tips clears: every hint's keys and the time of the last one.
    public static let resetKeys: [String] = Hint.allCases.flatMap { hint in Field.allCases.map { key(hint, $0) } } + [lastAnyShownKey]
    /// Every key the hints keep, for the self-test to put back.
    public static let keys: [String] = resetKeys + [seededKey, seededHintsKey, tipsKey]

    /// Whether tips are on in `defaults`.
    public static func tipsOn(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: tipsKey) as? Bool ?? true }

    public static func load(_ hint: Hint, _ defaults: UserDefaults) -> Record {
        func date(_ field: Field) -> Date? {
            (defaults.object(forKey: key(hint, field)) as? Double).map { Date(timeIntervalSince1970: $0) }
        }
        return Record(shown: defaults.integer(forKey: key(hint, .shown)), lastShownAt: date(.lastShownAt),
                      firstEligibleAt: date(.firstEligibleAt),
                      retired: defaults.string(forKey: key(hint, .retired)).flatMap(Retirement.init(rawValue:)), watchFrom: date(.watchFrom))
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
        set(record.watchFrom?.timeIntervalSince1970, .watchFrom)
    }

    public static func lastAnyShownAt(_ defaults: UserDefaults) -> Date? {
        (defaults.object(forKey: lastAnyShownKey) as? Double).map { Date(timeIntervalSince1970: $0) }
    }

    public static func setLastAnyShownAt(_ date: Date, _ defaults: UserDefaults) {
        defaults.set(date.timeIntervalSince1970, forKey: lastAnyShownKey)
    }

    /// Reset Tips and Help › Show Tips Again: tips seen or closed show again, and a watch ends. The features' own
    /// settings, the off switch and the seeding marks stay.
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
        /// A terminal position was ever chosen (`terminalPosition` was written, even back to Bottom).
        public var terminalPositionChosen: Bool
        /// A repository's worktrees were ever folded into its row (`windowColumnFolded` was written).
        public var worktreesFoldedEver: Bool
        /// The install was used before this launch (Recent Projects is not empty): a traceless feature may have been
        /// used, so its hint is watched rather than due.
        public var existingInstall: Bool
        /// The commands the user gave a key of their own, or took the key from (the shortcut table's overrides).
        public var overrides: Set<String>

        public init(columnSideChosen: Bool = false, columnExpandedEver: Bool = false, terminalPositionChosen: Bool = false,
                    worktreesFoldedEver: Bool = false, existingInstall: Bool = false, overrides: Set<String> = []) {
            self.columnSideChosen = columnSideChosen
            self.columnExpandedEver = columnExpandedEver
            self.terminalPositionChosen = terminalPositionChosen
            self.worktreesFoldedEver = worktreesFoldedEver
            self.existingInstall = existingInstall
            self.overrides = overrides
        }
    }

    /// What the seeding does with one hint.
    public enum Seed: Equatable, Sendable {
        /// Its feature is in use: retired as `actionPerformed`, never shown.
        case retire
        /// Nothing says whether its feature was used: two weeks of watching first, in which a use retires it.
        case watch
        /// Due, waiting for its trigger like a new user's.
        case due
    }

    /// What the seeding does with `hint` on an install that has `inUse`. A key of the user's own for its command
    /// retires any hint; then each hint's own fact; a traceless feature on an install used before is watched. Nothing
    /// is ever shown by the seeding: no what's-new popover, ever.
    public static func seed(_ hint: Hint, _ inUse: InUse) -> Seed {
        if let command = hint.command, inUse.overrides.contains(command) { return .retire }
        switch hint {
        case .columnSide: return inUse.columnSideChosen ? .retire : .due
        case .columnBasics: return inUse.columnExpandedEver ? .retire : .due
        case .nextAgent: break
        }
        return hint.traceless && inUse.existingInstall ? .watch : .due
    }

    /// The hints `defaults` has not seeded yet. Without the per-hint list, an install that ran the first seeding
    /// (`seededKey`) has seeded the three hints it knew.
    public static func unseeded(_ defaults: UserDefaults) -> [Hint] {
        let done: Set<String> = seededNames(defaults)
        return Hint.allCases.filter { !done.contains($0.rawValue) }
    }

    private static func seededNames(_ defaults: UserDefaults) -> Set<String> {
        if let names = defaults.stringArray(forKey: seededHintsKey) { return Set(names) }
        guard defaults.bool(forKey: seededKey) else { return [] }
        return Set([Hint.columnSide, .nextAgent, .columnBasics].map(\.rawValue))
    }

    /// Seeds each hint not seeded yet, once, from `inUse`: retires those in use, starts the watch of the traceless
    /// ones, and marks all of them seeded (names a later version wrote are kept). Returns what it did, by hint.
    @discardableResult
    public static func seed(_ inUse: InUse, _ defaults: UserDefaults, now: Date) -> [Hint: Seed] {
        let due: [Hint] = unseeded(defaults)
        var done: [Hint: Seed] = [:]
        for hint in due {
            let seed: Seed = seed(hint, inUse)
            done[hint] = seed
            var record: Record = load(hint, defaults)
            switch seed {
            case .retire: record = retire(record, .actionPerformed)
            case .watch: if record.retired == nil, record.watchFrom == nil { record.watchFrom = now }
            case .due: continue
            }
            save(record, hint, defaults)
        }
        if !due.isEmpty || defaults.stringArray(forKey: seededHintsKey) == nil {
            let names: Set<String> = seededNames(defaults).union(due.map(\.rawValue))
            defaults.set(names.sorted(), forKey: seededHintsKey)
        }
        defaults.set(true, forKey: seededKey)
        return done
    }
}
