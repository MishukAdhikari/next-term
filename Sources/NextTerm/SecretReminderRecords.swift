import Foundation

/// What key rotation reminders keep outside the vault, in `UserDefaults`: writing the vault needs Touch ID, which a
/// reminder must never ask for. Today it holds the keys Rotate…'s Remind Me Tomorrow named, each with the day its one
/// reminder is due; the reminders post it that day. Names and days only, never a value or a link.
@MainActor
enum SecretReminderRecords {
    /// Each key's name, and the start of the day its reminder is due.
    static let remindOnKey = "secretsRemindOn"
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
        let stored: [String: Any] = defaults.dictionary(forKey: remindOnKey) ?? [:]
        return stored.compactMapValues { (day: Any) -> Date? in day as? Date }
    }
}
