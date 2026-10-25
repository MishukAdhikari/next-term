import Foundation

/// A key's age: how long since its value was last set (`Entry.lastSet`), as the Rotated column says it, and whether
/// its "Remind me to rotate" age has passed. Pure, and counted in calendar days on the Mac's calendar, so a key set
/// late yesterday is a day old this morning.
public enum SecretAge {
    /// Past this many days the Rotated column shows the date: "3 Aug 2025".
    public static let daysShown = 365

    /// Whole calendar days from `date` to `now`; a date ahead of now (the clock was set back) is 0.
    public static func days(from date: Date, to now: Date, calendar: Calendar = .current) -> Int {
        let start: Date = calendar.startOfDay(for: date)
        let end: Date = calendar.startOfDay(for: now)
        let days: Int = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        return max(0, days)
    }

    /// Whether the key got a value after it was added: by Replace…, a rotation, or an import over it. A key saved
    /// before the date was recorded reads as never given one.
    public static func wasGivenNewValue(_ entry: SecretVault.Entry) -> Bool {
        guard let valueSet = entry.valueSet else { return false }
        return valueSet > entry.created
    }

    /// The Rotated column: "Today", "Yesterday", "12 days ago", or past a year "3 Aug 2025". A key never given a new
    /// value reads "Added today", "Added 12 days ago", and so on.
    public static func text(entry: SecretVault.Entry, now: Date, calendar: Calendar = .current) -> String {
        let age: String = ageText(since: entry.lastSet, now: now, calendar: calendar)
        guard !wasGivenNewValue(entry) else { return age }
        let lowered: String = age.first.map { (first: Character) -> String in first.lowercased() + age.dropFirst() } ?? age
        let isDate: Bool = days(from: entry.lastSet, to: now, calendar: calendar) > daysShown
        return "Added " + (isDate ? age : lowered)
    }

    /// Whether the key's reminder is due: it has one, and its value was last set that many days ago or more. A key
    /// saved before the date was recorded counts from when it was made, so its reminder can come early, never late.
    public static func due(entry: SecretVault.Entry, now: Date, calendar: Calendar = .current) -> Bool {
        guard let remind = entry.remindDays else { return false }
        return days(from: entry.lastSet, to: now, calendar: calendar) >= remind
    }

    /// A due key's help, for the Rotated cell's tooltip and the Secrets menu's due row: "94 days ago. Due: you asked to
    /// be reminded to rotate it after 90 days." Nil when the key isn't due.
    public static func dueHelp(entry: SecretVault.Entry, now: Date, calendar: Calendar = .current) -> String? {
        guard due(entry: entry, now: now, calendar: calendar), let remind = entry.remindDays else { return nil }
        let age: String = text(entry: entry, now: now, calendar: calendar)
        let after: String = remind == 1 ? "1 day" : "\(remind) days"
        return "\(age). Due: you asked to be reminded to rotate it after \(after)."
    }

    /// At most one reminder about a due key in this many days.
    public static let reminderGap = 7

    /// The reminders to post now, in the list's order: each key whose Remind Me Tomorrow day has come (`remindOn`, once:
    /// the caller drops the record when it posts), else each due key not reminded in the last `reminderGap` days
    /// (`lastShown`). A key gets one at most. A day in `lastShown` after today means the clock was set back, so it no
    /// longer holds the reminder back.
    public static func toNotify(entries: [SecretVault.Entry], lastShown: [String: Date], remindOn: [String: Date], now: Date,
                                calendar: Calendar = .current) -> [SecretReminder] {
        let today: Date = calendar.startOfDay(for: now)
        var reminders: [SecretReminder] = []
        for entry in entries {
            if let day = remindOn[entry.name], calendar.startOfDay(for: day) <= today {
                reminders.append(SecretReminder(name: entry.name, kind: .deleteOld))
                continue
            }
            guard due(entry: entry, now: now, calendar: calendar) else { continue }
            if let shown = lastShown[entry.name], calendar.startOfDay(for: shown) <= today,
               days(from: shown, to: now, calendar: calendar) < reminderGap {
                continue
            }
            reminders.append(SecretReminder(name: entry.name, kind: .due))
        }
        return reminders
    }

    /// The day as `list_secrets` gives it and GitHub's new-token form names it: `2026-10-12`, always in the Gregorian
    /// calendar, on the day of `calendar`'s time zone. A Mac set to the Buddhist or Japanese calendar still gets 2026.
    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        SecretFolder.day(of: date, timeZone: calendar.timeZone)
    }

    private static func ageText(since date: Date, now: Date, calendar: Calendar) -> String {
        let count: Int = days(from: date, to: now, calendar: calendar)
        switch count {
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2...daysShown: return "\(count) days ago"
        default: return dateText(date, calendar: calendar)
        }
    }

    /// "3 Aug 2025", in English as the rest of the app's text is.
    private static func dateText(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }
}
