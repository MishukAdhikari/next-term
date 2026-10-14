import Foundation
import Testing
@testable import NextTermCore

/// A key's age as the Rotated column and `list_secrets` tell it, on fixed dates in one time zone.
@Suite struct SecretAgeTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()

    /// 13 Oct 2026, 15:00 UTC.
    static let now: Date = date(2026, 10, 13, hour: 15)

    static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        return calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
    }

    /// A made-up entry added on `created`, its value last set on `valueSet` (nil: saved before that was recorded).
    static func entry(created: Date, valueSet: Date?, remindDays: Int? = nil) -> SecretVault.Entry {
        var entry = SecretVault.Entry(id: "made-up-id", name: "AGE_KEY", purpose: "", purposeBy: .user, origin: .settings,
                                      writeOnly: false, created: created, changed: created, box: Data(), marks: [])
        entry.valueSet = valueSet
        entry.remindDays = remindDays
        return entry
    }

    static func text(_ entry: SecretVault.Entry, now: Date = now) -> String {
        SecretAge.text(entry: entry, now: now, calendar: calendar)
    }

    static func due(_ entry: SecretVault.Entry, now: Date = now) -> Bool {
        SecretAge.due(entry: entry, now: now, calendar: calendar)
    }

    @Test func daysAreCalendarDaysNotSpansOf24Hours() {
        let late = Self.date(2026, 10, 12, hour: 23, minute: 59)
        let early = Self.date(2026, 10, 13, hour: 0, minute: 1)
        #expect(SecretAge.days(from: late, to: early, calendar: Self.calendar) == 1)
        #expect(SecretAge.days(from: early, to: Self.now, calendar: Self.calendar) == 0)
        #expect(SecretAge.days(from: Self.date(2026, 7, 13), to: Self.now, calendar: Self.calendar) == 92)
        // A date ahead of now (the clock was set back) is today, never a negative age.
        #expect(SecretAge.days(from: Self.date(2026, 10, 20), to: Self.now, calendar: Self.calendar) == 0)
    }

    @Test func aKeyNeverGivenANewValueReadsAdded() {
        let today = Self.date(2026, 10, 13, hour: 9)
        #expect(Self.text(Self.entry(created: today, valueSet: today)) == "Added today")
        let yesterday = Self.date(2026, 10, 12)
        #expect(Self.text(Self.entry(created: yesterday, valueSet: yesterday)) == "Added yesterday")
        let earlier = Self.date(2026, 10, 1)
        #expect(Self.text(Self.entry(created: earlier, valueSet: earlier)) == "Added 12 days ago")
        // Saved before the date was recorded: its age counts from when it was made.
        #expect(Self.text(Self.entry(created: Self.date(2026, 9, 3), valueSet: nil)) == "Added 40 days ago")
    }

    @Test func aKeyGivenANewValueReadsItsAge() {
        let created = Self.date(2025, 1, 2)
        #expect(Self.text(Self.entry(created: created, valueSet: Self.date(2026, 10, 13, hour: 8))) == "Today")
        #expect(Self.text(Self.entry(created: created, valueSet: Self.date(2026, 10, 12))) == "Yesterday")
        #expect(Self.text(Self.entry(created: created, valueSet: Self.date(2026, 10, 1))) == "12 days ago")
        #expect(Self.text(Self.entry(created: created, valueSet: Self.date(2026, 7, 13))) == "92 days ago")
    }

    @Test func pastAYearTheDateIsShown() {
        let created = Self.date(2024, 1, 2)
        let yearAgo = Self.date(2025, 10, 13)
        #expect(Self.text(Self.entry(created: created, valueSet: yearAgo)) == "365 days ago")
        #expect(Self.text(Self.entry(created: created, valueSet: Self.date(2025, 8, 3))) == "3 Aug 2025")
        let old = Self.date(2025, 8, 3)
        #expect(Self.text(Self.entry(created: old, valueSet: old)) == "Added 3 Aug 2025")
    }

    @Test func aReminderIsDueOnceItsDaysHavePassed() {
        let created = Self.date(2026, 1, 5)
        #expect(!Self.due(Self.entry(created: created, valueSet: Self.date(2026, 7, 13))))
        #expect(Self.due(Self.entry(created: created, valueSet: Self.date(2026, 7, 13), remindDays: 90)))
        #expect(Self.due(Self.entry(created: created, valueSet: Self.date(2026, 7, 15), remindDays: 90)))
        #expect(!Self.due(Self.entry(created: created, valueSet: Self.date(2026, 7, 16), remindDays: 90)))
        // A key saved before the date was recorded counts from when it was made: early, never late.
        #expect(Self.due(Self.entry(created: Self.date(2026, 9, 1), valueSet: nil, remindDays: 30)))
        #expect(!Self.due(Self.entry(created: Self.date(2026, 9, 20), valueSet: nil, remindDays: 30)))
    }

    @Test func theDayIsWrittenAsListsWriteIt() {
        #expect(SecretAge.day(Self.date(2026, 10, 12, hour: 23, minute: 30), calendar: Self.calendar) == "2026-10-12")
        #expect(SecretAge.day(Self.date(2026, 1, 5), calendar: Self.calendar) == "2026-01-05")
    }
}
