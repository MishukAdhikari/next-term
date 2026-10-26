import Foundation

/// With many windows open, Next Term says once that the window column can help, or that it can go: a notice in the
/// window the user just opened, with a button that does it. It never changes the setting by itself, never takes the
/// keyboard, and stops for good once the user has switched the column either way (they know where it is).
///
/// - The column off: once, with at least two more windows open than when it was hidden (five at least), and two weeks
///   or more after hiding it. "6 windows open. Show the window column (⌃⇧⌘S)?" Show, or Don't Ask Again.
/// - The column on: once, with five windows or more, how to hide it. "6 windows open. Hide the window column (⌃⇧⌘S)?"
///   Hide, or Keep It.
public enum WindowColumnOffer {
    /// "Many": five windows open.
    public static let many = 5
    /// How long after hiding it the column is offered again, at the soonest.
    public static let wait: TimeInterval = 14 * 24 * 60 * 60
    /// The offer to show it was made (or needs no making: the user switched it on).
    public static let showOfferedKey = "windowColumnShowOffered"
    /// How many windows were open when it was last hidden.
    public static let hiddenWithKey = "windowColumnHiddenWith"
    /// When it was last hidden, in seconds since 1970.
    public static let hiddenAtKey = "windowColumnHiddenAt"
    /// The note on how to hide it was shown (or needs no showing: the user switched it).
    public static let hideTipKey = "windowColumnHideTipShown"
    /// Every key it keeps, for the self-test to put back.
    public static let keys = [showOfferedKey, hiddenWithKey, hiddenAtKey, hideTipKey]

    public enum Kind: Equatable, Sendable {
        case show, hide
    }

    /// What it remembers.
    public struct Record: Equatable, Sendable {
        public var showOffered: Bool
        public var hiddenWith: Int?
        public var hiddenAt: Date?
        public var hideTipShown: Bool

        public init(showOffered: Bool = false, hiddenWith: Int? = nil, hiddenAt: Date? = nil, hideTipShown: Bool = false) {
            self.showOffered = showOffered
            self.hiddenWith = hiddenWith
            self.hiddenAt = hiddenAt
            self.hideTipShown = hideTipShown
        }

        public init(_ defaults: UserDefaults) {
            showOffered = defaults.bool(forKey: WindowColumnOffer.showOfferedKey)
            hiddenWith = defaults.object(forKey: WindowColumnOffer.hiddenWithKey) as? Int
            hiddenAt = (defaults.object(forKey: WindowColumnOffer.hiddenAtKey) as? Double).map { Date(timeIntervalSince1970: $0) }
            hideTipShown = defaults.bool(forKey: WindowColumnOffer.hideTipKey)
        }
    }

    /// From how many windows the column is offered again, when it was hidden with `hiddenWith` open: two more than
    /// then, and five at least. Hidden before this was kept (0.11.26): as if with two.
    public static func showsFrom(hiddenWith: Int?) -> Int { max(many, (hiddenWith ?? 2) + 2) }

    /// The notice due as a window opens, with `windows` open and the column `shown` or not; nil for none.
    public static func offer(shown: Bool, windows: Int, record: Record, now: Date) -> Kind? {
        if shown { return !record.hideTipShown && windows >= many ? .hide : nil }
        guard !record.showOffered, windows >= showsFrom(hiddenWith: record.hiddenWith) else { return nil }
        if let at = record.hiddenAt, now.timeIntervalSince(at) < wait { return nil }
        return .show
    }

    /// The notice's line, one short line: "6 windows open. Show the window column (⌃⇧⌘S)?" `key`: View › Show (or
    /// Hide) Window Column's key as the user has it; nil leaves the parenthesis out.
    public static func text(_ kind: Kind, windows: Int, key: String?) -> String {
        let verb: String = kind == .show ? "Show" : "Hide"
        return "\(windows) windows open. \(verb) the window column\(WindowColumnSettings.keyNote(key))?"
    }

    /// Its two buttons: the one that does it, and the one that doesn't.
    public static func buttons(_ kind: Kind) -> (button: String, other: String) {
        kind == .show ? ("Show", "Don’t Ask Again") : ("Hide", "Keep It")
    }

    /// The notice was shown: each is shown once, answered or not.
    public static func noteShown(_ kind: Kind, _ defaults: UserDefaults) {
        defaults.set(true, forKey: kind == .show ? showOfferedKey : hideTipKey)
    }

    /// Don't Ask Again, or the column hidden from the note: neither notice again.
    public static func finish(_ defaults: UserDefaults) {
        defaults.set(true, forKey: showOfferedKey)
        defaults.set(true, forKey: hideTipKey)
    }

    /// Hidden before the time was kept (0.11.26): the wait starts now, so nobody who just hid it is asked at once.
    public static func stampHidden(shown: Bool, now: Date, _ defaults: UserDefaults) {
        guard !shown, defaults.object(forKey: hiddenAtKey) == nil else { return }
        defaults.set(now.timeIntervalSince1970, forKey: hiddenAtKey)
    }

    /// The setting changed, by the menu, the key, Settings, a notice or an agent: whoever switched it knows how, so
    /// the note on hiding it is never needed. Shown, nothing is offered again; hidden, the count and the time are kept
    /// for the offer to show it again.
    public static func columnSet(shown: Bool, windows: Int, now: Date, _ defaults: UserDefaults) {
        defaults.set(true, forKey: hideTipKey)
        if shown {
            defaults.set(true, forKey: showOfferedKey)
        } else {
            defaults.set(windows, forKey: hiddenWithKey)
            defaults.set(now.timeIntervalSince1970, forKey: hiddenAtKey)
        }
    }
}
