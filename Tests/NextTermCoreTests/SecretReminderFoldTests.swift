import Foundation
import Testing
@testable import NextTermCore

/// Which posted reminders a change to the keys takes back (a rename, a delete, a new value), and several keys due at
/// once folded into one notification. Fixed dates, made-up names.
@Suite struct SecretReminderFoldTests {
    static let calendar: Calendar = SecretAgeTests.calendar
    static let now: Date = SecretAgeTests.now

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        SecretAgeTests.date(year, month, day, hour: 12)
    }

    static func entry(_ name: String, id: String? = nil, valueSet: Date? = nil) -> SecretVault.Entry {
        SecretReminderTests.entry(name, id: id, created: date(2026, 1, 5), valueSet: valueSet, remindDays: 30)
    }

    static func due(_ name: String) -> SecretReminder { SecretReminder(name: name, kind: .due) }

    @Test func aRenamedDeletedOrRotatedKeysReminderIsTakenBack() {
        let earlier: [SecretVault.Entry] = [Self.entry("OLD_NAME", id: "a"), Self.entry("GONE_KEY", id: "b"),
                                            Self.entry("SAME_KEY", id: "c"), Self.entry("AGAIN_KEY", id: "d"),
                                            Self.entry("ROTATED_KEY", id: "e", valueSet: Self.date(2026, 7, 1))]
        // Renamed, deleted, kept, deleted and added again under its name, and given a new value.
        let later: [SecretVault.Entry] = [Self.entry("NEW_NAME", id: "a"), Self.entry("SAME_KEY", id: "c"),
                                          Self.entry("AGAIN_KEY", id: "f"),
                                          Self.entry("ROTATED_KEY", id: "e", valueSet: Self.date(2026, 10, 13))]
        let gone: [String] = SecretReminder.withdrawn(from: earlier, to: later)
        #expect(gone == ["OLD_NAME", "GONE_KEY", "AGAIN_KEY", "ROTATED_KEY"])
    }

    @Test func nothingIsTakenBackWithNoEarlierListOrNoChange() {
        let keys: [SecretVault.Entry] = [Self.entry("SAME_KEY"), Self.entry("SET_KEY", valueSet: Self.date(2026, 7, 1))]
        #expect(SecretReminder.withdrawn(from: nil, to: keys).isEmpty)
        #expect(SecretReminder.withdrawn(from: keys, to: keys).isEmpty)
        // A key added since has nothing posted to take back.
        let added: [SecretVault.Entry] = keys + [Self.entry("NEW_KEY")]
        #expect(SecretReminder.withdrawn(from: keys, to: added).isEmpty)
    }

    @Test func upToThreeDueKeysGetOneNotificationEach() {
        let three: [SecretReminder] = [Self.due("A_KEY"), Self.due("B_KEY"), Self.due("C_KEY")]
        #expect(SecretReminder.folded(three) == three)
        #expect(SecretReminder.folded([]).isEmpty)
    }

    @Test func moreThanThreeDueKeysGetOneNotificationForAll() {
        let tomorrow = SecretReminder(name: "ROTATED_KEY", kind: .deleteOld)
        let reminders: [SecretReminder] = [Self.due("A_KEY"), tomorrow, Self.due("B_KEY"), Self.due("C_KEY"), Self.due("D_KEY")]
        let several = SecretReminder(name: "A_KEY", kind: .severalDue, others: 3)
        // Remind Me Tomorrow's stays its own: the user asked for that one.
        #expect(SecretReminder.folded(reminders) == [several, tomorrow])
        #expect(several.title == "Time to rotate keys")
        let body: String = several.body(entry: nil, now: Self.now, calendar: Self.calendar)
        #expect(body == "A_KEY and 3 other keys are past their \u{201C}Remind me to rotate\u{201D} age")
        let one = SecretReminder(name: "A_KEY", kind: .severalDue, others: 1)
        #expect(one.body(entry: nil, now: Self.now, calendar: Self.calendar)
            == "A_KEY and 1 other key are past their \u{201C}Remind me to rotate\u{201D} age")
    }

    @Test func theFoldedNotificationIsOneOfItsOwnAndNamesItsFirstKey() {
        let several = SecretReminder(name: "A_KEY", kind: .severalDue, others: 3)
        // No key's name is lowercase, so it never replaces one key's notification, nor one key's it.
        #expect(several.identifier == "secret-rotate-several")
        #expect(several.userInfo == ["secret": "A_KEY", "secretReminder": "severalDue"])
        // Clicked, it names its first key; how many are due is read again then.
        #expect(SecretReminder(userInfo: several.userInfo) == SecretReminder(name: "A_KEY", kind: .severalDue))
    }
}
