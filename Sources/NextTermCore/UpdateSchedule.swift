import Foundation

/// When the automatic update check runs: once a day, at 11:00 or the first moment after it, in the Mac's own
/// time zone. Next Term opened before 11:00 waits for it; opened later, it checks if today's check hasn't
/// happened yet. A check that failed (no network, GitHub not answering) doesn't count: it tries again an hour
/// later, and so on until one gets through.
public enum UpdateSchedule {
    /// The hour of the day the check is due, local time.
    public static let hour = 11
    /// After a failed check, how long before the next try.
    public static let retry: TimeInterval = 60 * 60

    /// Today's 11:00 in the calendar's time zone.
    public static func slot(on day: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }

    /// Whether the check is due now: it is 11:00 or later, and no check has got through since 11:00 today.
    /// A failure less than an hour ago holds it back.
    public static func isDue(now: Date, lastSuccess: Date?, lastFailure: Date?, calendar: Calendar) -> Bool {
        let today = slot(on: now, calendar: calendar)
        guard now >= today else { return false }
        if let lastSuccess, lastSuccess >= today { return false }
        if let lastFailure, lastFailure >= today, now.timeIntervalSince(lastFailure) < retry { return false }
        return true
    }

    /// When to look again after `now`: an hour after a failure today, else today's 11:00 while it is ahead,
    /// else tomorrow's.
    public static func next(after now: Date, lastSuccess: Date?, lastFailure: Date?, calendar: Calendar) -> Date {
        let today = slot(on: now, calendar: calendar)
        if now < today { return today }
        let doneToday = lastSuccess.map { $0 >= today } ?? false
        if !doneToday {
            if let lastFailure, lastFailure >= today, now.timeIntervalSince(lastFailure) < retry {
                return lastFailure.addingTimeInterval(retry)
            }
            return now
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        return slot(on: tomorrow, calendar: calendar)
    }
}
