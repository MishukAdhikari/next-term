import Foundation
import Testing
@testable import NextTermCore

/// The automatic update check: once a day at 11:00 or later, local time; a failure tries again an hour later.
@Suite struct UpdateScheduleTests {
    /// Dhaka has no daylight saving; New York's spring change is tested on its own.
    static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    static func at(_ text: String, _ calendar: Calendar) -> Date {
        let parts = text.split(whereSeparator: { "-: ".contains($0) }).map { Int($0)! }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4])
        return calendar.date(from: components)!
    }

    @Test func dueAtElevenOrLaterOncePerDay() {
        let cal = Self.calendar("Asia/Dhaka")
        let at = { Self.at($0, cal) }
        // Opened before 11:00: not yet; it waits for 11:00 today.
        #expect(!UpdateSchedule.isDue(now: at("2026-10-08 09:30"), lastSuccess: nil, lastFailure: nil, calendar: cal))
        #expect(UpdateSchedule.next(after: at("2026-10-08 09:30"), lastSuccess: nil, lastFailure: nil, calendar: cal) == at("2026-10-08 11:00"))
        // At 11:00 and after, due until a check gets through.
        #expect(UpdateSchedule.isDue(now: at("2026-10-08 11:00"), lastSuccess: at("2026-10-07 11:02"), lastFailure: nil, calendar: cal))
        #expect(UpdateSchedule.isDue(now: at("2026-10-08 18:45"), lastSuccess: at("2026-10-07 11:02"), lastFailure: nil, calendar: cal))
        // A check this morning before 11:00 (Check for Updates…) doesn't count for today.
        #expect(UpdateSchedule.isDue(now: at("2026-10-08 12:00"), lastSuccess: at("2026-10-08 10:00"), lastFailure: nil, calendar: cal))
        // Done today: the next is tomorrow at 11:00.
        #expect(!UpdateSchedule.isDue(now: at("2026-10-08 15:00"), lastSuccess: at("2026-10-08 11:00"), lastFailure: nil, calendar: cal))
        #expect(UpdateSchedule.next(after: at("2026-10-08 15:00"), lastSuccess: at("2026-10-08 11:00"), lastFailure: nil, calendar: cal)
                == at("2026-10-09 11:00"))
        // Never checked, opened after 11:00: now.
        #expect(UpdateSchedule.next(after: at("2026-10-08 14:00"), lastSuccess: nil, lastFailure: nil, calendar: cal) == at("2026-10-08 14:00"))
    }

    @Test func aFailureTriesAgainAnHourLater() {
        let cal = Self.calendar("Asia/Dhaka")
        let at = { Self.at($0, cal) }
        let failed = at("2026-10-08 11:00")
        #expect(!UpdateSchedule.isDue(now: at("2026-10-08 11:30"), lastSuccess: nil, lastFailure: failed, calendar: cal))
        #expect(UpdateSchedule.next(after: at("2026-10-08 11:30"), lastSuccess: nil, lastFailure: failed, calendar: cal) == at("2026-10-08 12:00"))
        #expect(UpdateSchedule.isDue(now: at("2026-10-08 12:00"), lastSuccess: nil, lastFailure: failed, calendar: cal))
        // Yesterday's failure holds nothing back today.
        #expect(UpdateSchedule.isDue(now: at("2026-10-08 11:05"), lastSuccess: nil, lastFailure: at("2026-10-07 23:30"), calendar: cal))
    }

    @Test func followsTheMacsTimeZone() {
        // The same moment is 11:00 in Dhaka and 05:00 in London: due in one, not the other.
        let dhaka = Self.calendar("Asia/Dhaka"), london = Self.calendar("Europe/London")
        let moment = Self.at("2026-10-08 11:00", dhaka)
        #expect(UpdateSchedule.isDue(now: moment, lastSuccess: nil, lastFailure: nil, calendar: dhaka))
        #expect(!UpdateSchedule.isDue(now: moment, lastSuccess: nil, lastFailure: nil, calendar: london))
        #expect(UpdateSchedule.next(after: moment, lastSuccess: nil, lastFailure: nil, calendar: london) == Self.at("2026-10-08 11:00", london))
    }

    @Test func daylightSavingDaysKeepElevenOClock() {
        // New York springs forward at 02:00 on 2027-03-14: 11:00 is still 11:00 that day.
        let cal = Self.calendar("America/New_York")
        let slot = UpdateSchedule.slot(on: Self.at("2027-03-14 08:00", cal), calendar: cal)
        #expect(cal.component(.hour, from: slot) == 11 && cal.component(.day, from: slot) == 14)
        #expect(UpdateSchedule.next(after: Self.at("2027-03-13 16:00", cal), lastSuccess: Self.at("2027-03-13 11:00", cal), lastFailure: nil, calendar: cal)
                == slot)
    }
}
