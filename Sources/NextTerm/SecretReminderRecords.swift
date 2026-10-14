import Foundation
import NextTermCore

/// What key rotation reminders keep outside the vault, in `UserDefaults`: writing the vault needs Touch ID, which a
/// reminder must never ask for. It holds when each key was last reminded that it is due, the keys Rotate…'s Remind Me
/// Tomorrow named with the day each one reminder is due, and Settings › Secrets' two reminder settings. Names, days and
/// settings only, never a value or a link.
@MainActor
enum SecretReminderRecords {
    /// Each key's name, and the start of the day its Remind Me Tomorrow reminder is due.
    static let remindOnKey = "secretsRemindOn"
    /// Each key's name, and when it was last reminded that it is due.
    static let shownKey = "secretsRemindShown"
    /// Settings › Secrets › "Remind me in Notification Center": on unless turned off.
    static let notifyKey = "secretsRemindInNotificationCenter"
    /// Settings › Secrets › "New keys: Remind me to rotate": days, 0 for Never.
    static let newKeyDaysKey = "secretsNewKeyRemindDays"
    /// Where the records live: the self-test points it at a suite of its own.
    static var defaults: UserDefaults = .standard

    /// Remind about `name` tomorrow, on the Mac's calendar: one reminder, replacing an earlier one for it.
    static func remindTomorrow(_ name: String, now: Date = Date(), calendar: Calendar = .current) {
        let today: Date = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return }
        var days: [String: Date] = remindOn
        days[name] = tomorrow
        defaults.set(days, forKey: remindOnKey)
    }

    /// The names whose reminder Remind Me Tomorrow asked for, and the day each is due.
    static var remindOn: [String: Date] {
        get { dates(remindOnKey) }
        set { defaults.set(newValue, forKey: remindOnKey) }
    }

    /// The names reminded that they are due, and when.
    static var shown: [String: Date] {
        get { dates(shownKey) }
        set { defaults.set(newValue, forKey: shownKey) }
    }

    /// Whether due keys are posted to Notification Center. The Due badge in the list shows either way.
    static var notifies: Bool {
        get { defaults.object(forKey: notifyKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: notifyKey) }
    }

    /// The reminder a new key starts with: nil for Never, the default.
    static var newKeyDays: Int? {
        get { SecretReminder.newKeyDays(stored: defaults.object(forKey: newKeyDaysKey)) }
        set { defaults.set(newValue ?? 0, forKey: newKeyDaysKey) }
    }

    /// Both records carried from the keys `earlier` held to the keys `later` holds: a renamed key's records move to
    /// its new name, a deleted key's go.
    static func carry(from earlier: [SecretVault.Entry]?, to later: [SecretVault.Entry]) {
        let days: [String: Date] = remindOn
        let carriedDays: [String: Date] = SecretReminder.carried(days, from: earlier, to: later)
        if carriedDays != days { remindOn = carriedDays }
        let seen: [String: Date] = shown
        let carriedSeen: [String: Date] = SecretReminder.carried(seen, from: earlier, to: later)
        if carriedSeen != seen { shown = carriedSeen }
    }

    private static func dates(_ key: String) -> [String: Date] {
        let stored: [String: Any] = defaults.dictionary(forKey: key) ?? [:]
        return stored.compactMapValues { (day: Any) -> Date? in day as? Date }
    }
}
