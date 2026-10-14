import Foundation
import Testing
@testable import NextTermCore

/// What a key rotation reminder says and carries (the key's name and age only, never a value or a link), the
/// notification it is, the records that follow a renamed key, and the default age for new keys.
@Suite struct SecretReminderNoticeTests {
    static let calendar: Calendar = SecretAgeTests.calendar
    static let now: Date = SecretAgeTests.now

    static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        SecretAgeTests.date(year, month, day, hour: hour)
    }

    static func entry(_ name: String, id: String? = nil, created: Date = date(2026, 1, 5), valueSet: Date? = nil,
                      remindDays: Int? = 90, link: String? = nil) -> SecretVault.Entry {
        SecretReminderTests.entry(name, id: id, created: created, valueSet: valueSet, remindDays: remindDays, link: link)
    }

    static func body(_ reminder: SecretReminder, _ entry: SecretVault.Entry?) -> String {
        reminder.body(entry: entry, now: now, calendar: calendar)
    }

    @Test func aDueKeySaysItsNameAndHowLongAgoItWasRotated() {
        let rotated = Self.entry("OPENAI_API_KEY", valueSet: Self.date(2026, 7, 13), link: "https://platform.example.com/keys")
        let due = SecretReminder(name: rotated.name, kind: .due)
        #expect(due.title == "Time to rotate a key")
        #expect(Self.body(due, rotated) == "OPENAI_API_KEY was last rotated 92 days ago")
        let added = Self.entry("COHERE_API_KEY", created: Self.date(2026, 7, 13), valueSet: Self.date(2026, 7, 13))
        let addedBody: String = Self.body(SecretReminder(name: added.name, kind: .due), added)
        #expect(addedBody == "COHERE_API_KEY was added 92 days ago and hasn\u{2019}t been rotated since")
        let old = Self.entry("OLD_KEY", created: Self.date(2026, 10, 12), valueSet: nil, remindDays: 1)
        let oneDay: String = Self.body(SecretReminder(name: old.name, kind: .due), old)
        #expect(oneDay == "OLD_KEY was added 1 day ago and hasn\u{2019}t been rotated since")
        // The link is never in a reminder.
        #expect(!Self.body(due, rotated).contains("example"))
    }

    @Test func remindMeTomorrowSaysToDeleteTheOldKey() {
        let reminder = SecretReminder(name: "GITHUB_TOKEN", kind: .deleteOld)
        #expect(reminder.title == "Delete an old key")
        let entry = Self.entry("GITHUB_TOKEN", valueSet: Self.date(2026, 10, 12), link: "https://github.com/settings/tokens")
        let expected = "Delete or deactivate the old GITHUB_TOKEN where you made it, if you haven\u{2019}t yet"
        #expect(Self.body(reminder, entry) == expected)
        #expect(Self.body(reminder, nil) == expected)
    }

    @Test func eachKeyHasOneNotificationThatNamesOnlyTheKey() {
        let due = SecretReminder(name: "OPENAI_API_KEY", kind: .due)
        let delete = SecretReminder(name: "OPENAI_API_KEY", kind: .deleteOld)
        #expect(due.identifier == "secret-rotate-OPENAI_API_KEY")
        #expect(delete.identifier == due.identifier)
        #expect(due.userInfo == ["secret": "OPENAI_API_KEY", "secretReminder": "due"])
        #expect(delete.userInfo == ["secret": "OPENAI_API_KEY", "secretReminder": "deleteOld"])
    }

    @Test func aClickedNotificationNamesItsReminder() {
        let info: [AnyHashable: Any] = ["secret": "OPENAI_API_KEY", "secretReminder": "deleteOld"]
        #expect(SecretReminder(userInfo: info) == SecretReminder(name: "OPENAI_API_KEY", kind: .deleteOld))
        // A kind a later release adds reads as due: the Rotate sheet is the safe place to land.
        let later: [AnyHashable: Any] = ["secret": "OPENAI_API_KEY", "secretReminder": "somethingNew"]
        #expect(SecretReminder(userInfo: later) == SecretReminder(name: "OPENAI_API_KEY", kind: .due))
        #expect(SecretReminder(userInfo: ["secret": "OPENAI_API_KEY"]) == SecretReminder(name: "OPENAI_API_KEY", kind: .due))
        // A tab's notification, and a name no key could have, are not reminders.
        #expect(SecretReminder(userInfo: ["tab": "3F2A0C1E-0000-4000-8000-000000000000"]) == nil)
        #expect(SecretReminder(userInfo: ["secret": "not a name"]) == nil)
        #expect(SecretReminder(userInfo: ["secret": 42]) == nil)
    }

    @Test func recordsFollowARenameAndGoWithTheKey() {
        let shown: [String: Date] = ["OLD_NAME": Self.date(2026, 10, 1), "GONE_KEY": Self.date(2026, 10, 2),
                                     "SAME_KEY": Self.date(2026, 10, 3), "AGAIN_KEY": Self.date(2026, 10, 4)]
        let earlier: [SecretVault.Entry] = [Self.entry("OLD_NAME", id: "a"), Self.entry("GONE_KEY", id: "b"),
                                            Self.entry("SAME_KEY", id: "c"), Self.entry("AGAIN_KEY", id: "d")]
        // Renamed, deleted, kept, and deleted then added again under its name (another id: a new key).
        let later: [SecretVault.Entry] = [Self.entry("NEW_NAME", id: "a"), Self.entry("SAME_KEY", id: "c"),
                                          Self.entry("AGAIN_KEY", id: "e")]
        let carried: [String: Date] = SecretReminder.carried(shown, from: earlier, to: later)
        #expect(carried == ["NEW_NAME": Self.date(2026, 10, 1), "SAME_KEY": Self.date(2026, 10, 3)])
    }

    @Test func withNoEarlierListRecordsStayForTheKeysStillStored() {
        let shown: [String: Date] = ["KEPT_KEY": Self.date(2026, 10, 1), "GONE_KEY": Self.date(2026, 10, 2)]
        let later: [SecretVault.Entry] = [Self.entry("KEPT_KEY")]
        #expect(SecretReminder.carried(shown, from: nil, to: later) == ["KEPT_KEY": Self.date(2026, 10, 1)])
        // A record the earlier list didn't have keeps to its name.
        #expect(SecretReminder.carried(shown, from: [], to: later) == ["KEPT_KEY": Self.date(2026, 10, 1)])
    }

    @Test func theDefaultForNewKeysIsNeverUnlessAnAgeIsSaved() {
        #expect(SecretReminder.newKeyDays(stored: nil) == nil)
        #expect(SecretReminder.newKeyDays(stored: 0) == nil)
        #expect(SecretReminder.newKeyDays(stored: 90) == 90)
        #expect(SecretReminder.newKeyDays(stored: 45) == 45)
        #expect(SecretReminder.newKeyDays(stored: -3) == nil)
        #expect(SecretReminder.newKeyDays(stored: 99_999) == nil)
        #expect(SecretReminder.newKeyDays(stored: "90") == nil)
    }
}
