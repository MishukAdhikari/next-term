import AppKit
import NextTermCore
import UserNotifications

#if DEBUG
/// Key rotation reminders as a launch runs them, on the self-test's days (`SecretReminders.selfTestNow`), never the
/// clock: started before the load, the load's change posts the due key's one notification; started again, as at the next
/// launch, none; the hourly timer a week on, one, and none again that day. Still started, a rename takes the old name's
/// notification back and moves its record, and a delete drops it. Notifications land in `testNotifications`.
extension SelfTest {
    /// The name the key is renamed to.
    static func secretReminderRenamed(_ name: String) -> String { name + "_RENAMED" }

    static func secretReminderLaunchChecks(_ name: String, _ due: Date) async {
        let store = SecretsStore.shared
        SecretReminderRecords.shown = [:]
        AppDelegate.shared.testNotifications = []
        SecretReminders.selfTestNow = due
        SecretReminders.startForSelfTest()
        defer {
            SecretReminders.stopForSelfTest()
            SecretReminders.selfTestNow = nil
        }
        let before: Bool = secretReminders(about: name).isEmpty
        await store.load()
        _ = await wait(5) { !secretReminders(about: name).isEmpty }
        let first: [UNNotificationRequest] = secretReminders(about: name)
        let body: String = first.first?.content.body ?? "none"
        let expected = "\(name) was added 31 days ago and hasn\u{2019}t been rotated since"
        check(before && first.count == 1 && body == expected,
              "secret reminders: started at launch, the check once the load is done posts the due key's one notification", body)
        SecretReminders.stopForSelfTest()
        SecretReminders.startForSelfTest()
        await store.load()
        _ = await wait(1) { secretReminders(about: name).count > 1 }
        check(secretReminders(about: name).count == 1, "secret reminders: started again, as at the next launch, it posts none that week")
        SecretReminders.selfTestNow = Calendar.current.date(byAdding: .day, value: 8, to: due) ?? due
        SecretReminders.fireTimerForSelfTest()
        let weekOn: Int = secretReminders(about: name).count
        SecretReminders.fireTimerForSelfTest()
        check(weekOn == 2 && secretReminders(about: name).count == 2,
              "secret reminders: the hourly timer posts it again a week on, and once that day", "\(weekOn)")
        await secretReminderFollowChecks(name)
    }

    /// While started: renamed, the key's notification is taken back and its record moves to the new name; deleted,
    /// the record goes.
    static func secretReminderFollowChecks(_ name: String) async {
        let store = SecretsStore.shared
        let renamed: String = secretReminderRenamed(name)
        do {
            try await store.perform(.edit(name: name, newName: renamed, purpose: nil, purposeBy: .user))
        } catch {
            return check(false, "secret reminders: the key is renamed", "\(error)")
        }
        _ = await wait(5) { secretReminders(about: name).isEmpty }
        let shown: [String: Date] = SecretReminderRecords.shown
        check(secretReminders(about: name).isEmpty && shown[renamed] != nil && shown[name] == nil,
              "secret reminders: renamed, a key's notification is taken back and its record moves to its new name")
        do {
            try await store.perform(.delete(name: renamed))
        } catch {
            return check(false, "secret reminders: the renamed key is deleted", "\(error)")
        }
        _ = await wait(5) { SecretReminderRecords.shown[renamed] == nil }
        check(SecretReminderRecords.shown[renamed] == nil, "secret reminders: deleted, a key's record goes")
    }
}
#endif
