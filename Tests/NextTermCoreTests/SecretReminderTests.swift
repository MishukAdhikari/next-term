import Foundation
import Testing
@testable import NextTermCore

/// Key rotation reminders: which keys are due, which get a notification now (one a week at most, and Remind Me
/// Tomorrow's once), what it says, and how its records follow a rename. Fixed dates, made-up names.
@Suite struct SecretReminderTests {
    static let calendar: Calendar = SecretAgeTests.calendar
    /// 13 Oct 2026, 15:00 UTC.
    static let now: Date = SecretAgeTests.now

    static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        SecretAgeTests.date(year, month, day, hour: hour, minute: minute)
    }

    /// A made-up entry, its id from its name unless given.
    static func entry(_ name: String, id: String? = nil, created: Date, valueSet: Date?,
                      remindDays: Int? = nil, link: String? = nil) -> SecretVault.Entry {
        var entry = SecretVault.Entry(id: id ?? "id-" + name, name: name, purpose: "", purposeBy: .user, origin: .settings,
                                      writeOnly: false, created: created, changed: created, box: Data(), marks: [])
        entry.valueSet = valueSet
        entry.remindDays = remindDays
        entry.link = link
        return entry
    }

    static func notify(_ entries: [SecretVault.Entry], shown: [String: Date] = [:],
                       remindOn: [String: Date] = [:], now: Date = now) -> [SecretReminder] {
        SecretAge.toNotify(entries: entries, lastShown: shown, remindOn: remindOn, now: now, calendar: calendar)
    }

    /// A key due 92 days after it was last rotated, with a 90-day reminder.
    static let dueKey: SecretVault.Entry = entry("OPENAI_API_KEY", created: date(2026, 1, 5),
                                                 valueSet: date(2026, 7, 13), remindDays: 90)

    @Test func dueCountsFromTheLastValueOrFromWhenTheKeyWasMade() {
        let made: Date = Self.date(2026, 7, 5)
        let old = Self.entry("OLD_KEY", created: made, valueSet: nil, remindDays: 90)
        #expect(SecretAge.due(entry: old, now: Self.now, calendar: Self.calendar))
        let fresh = Self.entry("FRESH_KEY", created: made, valueSet: Self.date(2026, 10, 3), remindDays: 90)
        #expect(!SecretAge.due(entry: fresh, now: Self.now, calendar: Self.calendar))
        let never = Self.entry("NEVER_KEY", created: Self.date(2020, 1, 1), valueSet: nil)
        #expect(!SecretAge.due(entry: never, now: Self.now, calendar: Self.calendar))
    }

    @Test func aDueKeyIsNotifiedAtMostOnceAWeek() {
        let name: String = Self.dueKey.name
        let due = SecretReminder(name: name, kind: .due)
        #expect(Self.notify([Self.dueKey]) == [due])
        #expect(Self.notify([Self.dueKey], shown: [name: Self.date(2026, 10, 10)]).isEmpty)
        #expect(Self.notify([Self.dueKey], shown: [name: Self.date(2026, 10, 6, hour: 23)]) == [due])
        #expect(Self.notify([Self.dueKey], shown: [name: Self.date(2026, 10, 5)]) == [due])
        // Shown on a day after today: the clock was set back since, so it may come again.
        #expect(Self.notify([Self.dueKey], shown: [name: Self.date(2026, 11, 2)]) == [due])
        // Another key's record changes nothing for this one.
        #expect(Self.notify([Self.dueKey], shown: ["OTHER_KEY": Self.date(2026, 10, 12)]) == [due])
    }

    @Test func keysNotDueAreNeverNotified() {
        let fresh = Self.entry("FRESH_KEY", created: Self.date(2026, 1, 5), valueSet: Self.date(2026, 10, 3), remindDays: 90)
        let never = Self.entry("NEVER_KEY", created: Self.date(2020, 1, 1), valueSet: nil)
        #expect(Self.notify([fresh, never]).isEmpty)
    }

    @Test func remindMeTomorrowComesOnItsDayOnce() {
        let rotated = Self.entry("GITHUB_TOKEN", created: Self.date(2026, 1, 5), valueSet: Self.date(2026, 10, 12), remindDays: 90)
        let delete = SecretReminder(name: "GITHUB_TOKEN", kind: .deleteOld)
        #expect(Self.notify([rotated], remindOn: ["GITHUB_TOKEN": Self.date(2026, 10, 13, hour: 0)]) == [delete])
        // Next Term wasn't running that day: the reminder comes the next time it checks.
        #expect(Self.notify([rotated], remindOn: ["GITHUB_TOKEN": Self.date(2026, 10, 9, hour: 0)]) == [delete])
        #expect(Self.notify([rotated], remindOn: ["GITHUB_TOKEN": Self.date(2026, 10, 14, hour: 0)]).isEmpty)
        // A key that is due too gets one notification, not two: the one it asked for.
        let both: [SecretReminder] = Self.notify([Self.dueKey], remindOn: [Self.dueKey.name: Self.date(2026, 10, 13, hour: 0)])
        #expect(both == [SecretReminder(name: Self.dueKey.name, kind: .deleteOld)])
        // A key deleted since gets none.
        #expect(Self.notify([], remindOn: ["GITHUB_TOKEN": Self.date(2026, 10, 13, hour: 0)]).isEmpty)
    }

    @Test func remindersKeepTheListsOrder() {
        let second = Self.entry("SECOND_KEY", created: Self.date(2026, 1, 5), valueSet: nil, remindDays: 30)
        let names: [String] = Self.notify([Self.dueKey, second]).map(\.name)
        #expect(names == ["OPENAI_API_KEY", "SECOND_KEY"])
    }

    /// Ages are calendar days on the Mac's calendar, so a daylight-saving change (a 23- or 25-hour day) moves nothing.
    @Test func daylightSavingDaysCountAsCalendarDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        func local(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let parts = DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)
            return calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
        }
        // Clocks go forward on 8 Mar 2026: under 24 hours apart, two calendar days.
        #expect(SecretAge.days(from: local(3, 7, 23, 30), to: local(3, 9, 0, 10), calendar: calendar) == 2)
        // Clocks go back on 1 Nov 2026: over 48 hours apart, two calendar days.
        #expect(SecretAge.days(from: local(10, 31, 0, 30), to: local(11, 2, 0, 45), calendar: calendar) == 2)
        // A 30-day reminder set in October is due on its 30th calendar day, at any hour.
        let set: Date = local(10, 20, 22)
        let key = Self.entry("DST_KEY", created: set, valueSet: set, remindDays: 30)
        #expect(!SecretAge.due(entry: key, now: local(11, 18, 23, 59), calendar: calendar))
        #expect(SecretAge.due(entry: key, now: local(11, 19, 0, 5), calendar: calendar))
        let shown: [String: Date] = ["DST_KEY": local(11, 19, 9)]
        let later: [SecretReminder] = SecretAge.toNotify(entries: [key], lastShown: shown, remindOn: [:],
                                                         now: local(11, 26, 0, 5), calendar: calendar)
        #expect(later == [SecretReminder(name: "DST_KEY", kind: .due)])
    }
}
