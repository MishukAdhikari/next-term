import AppKit
import NextTermCore
import UserNotifications

#if DEBUG
/// Key rotation reminders, on the self-test's temporary vault and a defaults suite of the run's own: the settings under
/// the list and the reminder Add… starts with; a key past its "Remind me to rotate" age shows Due; one check posts one
/// notification (into `testNotifications`, never Notification Center) and the next posts none until a week has passed;
/// the switch off posts no due one; a click opens Rotate…; Remind Me Tomorrow's day posts its one reminder. Days ahead
/// are the `now` the checks are given, never the clock. The value is made up at run time.
extension SelfTest {
    static func secretReminderChecks() async {
        let store = SecretsStore.shared
        AppDelegate.shared.showSecrets(nil)
        guard let controller = SecretsWindowController.shared, let window = controller.window, window.isVisible else {
            return check(false, "secret reminders: Window › Secrets opens its window")
        }
        defer { window.close() }
        let suiteName = "nt-selftest-reminders-\(getpid())"
        let saved = SecretReminderRecords.defaults
        SecretReminderRecords.defaults = UserDefaults(suiteName: suiteName) ?? saved
        defer {
            SecretReminderRecords.defaults = saved
            UserDefaults().removePersistentDomain(forName: suiteName)
            NotificationCenter.default.post(name: SecretReminderSettingsView.changed, object: nil)
        }
        let view = controller.secretsView
        await secretReminderSettingsChecks(view)
        let name = "REMIND_ROTATE_KEY"
        let add: SecretsStore.Action = .add(name: name, purpose: "rag-api", purposeBy: .user, origin: .settings, writeOnly: false,
                                            value: SecretBytes(utf8: secretsValue("made-up-")), remindDays: 30)
        do {
            try await store.perform(add)
        } catch {
            return check(false, "secret reminders: a made-up key with a 30-day reminder is saved", "\(error)")
        }
        let calendar = Calendar.current
        let due: Date = calendar.date(byAdding: .day, value: 31, to: Date()) ?? Date()
        secretReminderBadgeCheck(name, due)
        secretReminderPostChecks(name, due)
        await secretReminderOpenCheck(view, name)
        secretReminderTomorrowChecks(name, due)
        _ = try? await store.perform(.delete(name: name))
    }

    /// The posted reminders about `name`, newest last.
    static func secretReminders(about name: String) -> [UNNotificationRequest] {
        AppDelegate.shared.testNotifications.filter { (request: UNNotificationRequest) -> Bool in
            request.identifier == "secret-rotate-" + name
        }
    }

    /// Under the list: "Remind me in Notification Center", on, and new keys' reminder, Never, as a new install has
    /// them; the pop-up sets the reminder Add… starts with.
    static func secretReminderSettingsChecks(_ view: SecretsView) async {
        let settings = view.reminderSettings
        settings.reload()
        check(settings.notifyBox.state == .on && settings.newKeysPopUp.titleOfSelectedItem == "Never",
              "secret reminders: Remind me in Notification Center is on, and new keys start with Never",
              settings.newKeysPopUp.titleOfSelectedItem ?? "none")
        settings.notifyBox.performClick(nil)
        let off: Bool = !SecretReminderRecords.notifies
        settings.notifyBox.performClick(nil)
        check(off && SecretReminderRecords.notifies, "secret reminders: the switch turns Notification Center reminders off and on")
        secretsPick(90, in: settings.newKeysPopUp)
        view.add()
        let starts: Int? = view.sheet?.remindPopUp?.selectedTag()
        view.sheet?.cancelButton.performClick(nil)
        _ = await wait(5) { view.sheet == nil }
        secretsPick(0, in: settings.newKeysPopUp)
        check(starts == 90 && SecretReminderRecords.newKeyDays == nil,
              "secret reminders: Add… starts with the reminder set for new keys", "\(String(describing: starts))")
    }

    /// The Rotated cell: today, the age alone; past the key's 30 days, led by Due, which a screen reader says too.
    static func secretReminderBadgeCheck(_ name: String, _ due: Date) {
        guard let entry = SecretsStore.shared.index?.entry(named: name) else {
            return check(false, "secret reminders: the key is listed")
        }
        let today = NSTextField(labelWithString: "")
        SecretsView.fillRotatedCell(today, entry, now: Date())
        let later = NSTextField(labelWithString: "")
        SecretsView.fillRotatedCell(later, entry, now: due)
        let spoken: String = later.accessibilityLabel() ?? ""
        check(today.stringValue == "Added today" && later.stringValue == "Due Added 31 days ago"
              && spoken == "Added 31 days ago, due to rotate",
              "secret reminders: past its reminder's age, a key's Rotated cell reads Due", "\(later.stringValue), \(spoken)")
    }

    /// One check posts one notification for the due key, with its name and age only; the next posts none; three days
    /// on, none; eight days on, one again, unless the switch is off.
    static func secretReminderPostChecks(_ name: String, _ due: Date) {
        let calendar = Calendar.current
        AppDelegate.shared.testNotifications = []
        SecretReminders.check(now: due)
        let posted: [UNNotificationRequest] = secretReminders(about: name)
        let body: String = posted.first?.content.body ?? ""
        let info: [AnyHashable: Any] = posted.first?.content.userInfo ?? [:]
        let expected = "\(name) was added 31 days ago and hasn\u{2019}t been rotated since"
        check(posted.count == 1 && body == expected && info["secret"] as? String == name && info.count == 2,
              "secret reminders: a due key gets one notification with its name and age", body)
        SecretReminders.check(now: due)
        let soon: Date = calendar.date(byAdding: .day, value: 3, to: due) ?? due
        SecretReminders.check(now: soon)
        check(secretReminders(about: name).count == 1, "secret reminders: the next checks that week post none")
        let week: Date = calendar.date(byAdding: .day, value: 8, to: due) ?? due
        SecretReminderRecords.notifies = false
        SecretReminders.check(now: week)
        let quiet: Bool = secretReminders(about: name).count == 1
        SecretReminderRecords.notifies = true
        SecretReminders.check(now: week)
        check(quiet && secretReminders(about: name).count == 2,
              "secret reminders: a week on it comes again, and not while Remind me in Notification Center is off")
    }

    /// Clicking the reminder (its notification's userInfo, as the app's response handler reads it) opens Rotate… for
    /// the key in Window › Secrets.
    static func secretReminderOpenCheck(_ view: SecretsView, _ name: String) async {
        let info: [AnyHashable: Any] = secretReminders(about: name).last?.content.userInfo ?? [:]
        guard let reminder = SecretReminder(userInfo: info) else {
            return check(false, "secret reminders: the notification names its key")
        }
        SecretReminders.open(reminder)
        _ = await wait(5) { view.rotateSheet != nil }
        check(view.rotateSheet?.name == name, "secret reminders: clicking a due key's reminder opens Rotate… for it")
        view.rotateSheet?.cancelButton.performClick(nil)
        _ = await wait(5) { view.rotateSheet == nil }
    }

    /// Remind Me Tomorrow: nothing that day, one reminder to delete the old key the next, even with the switch off,
    /// then its record is gone.
    static func secretReminderTomorrowChecks(_ name: String, _ due: Date) {
        let calendar = Calendar.current
        let day: Date = calendar.date(byAdding: .day, value: 20, to: due) ?? due
        SecretReminderRecords.remindTomorrow(name, now: day)
        SecretReminderRecords.notifies = false
        defer { SecretReminderRecords.notifies = true }
        AppDelegate.shared.testNotifications = []
        SecretReminders.check(now: day)
        let none: Bool = secretReminders(about: name).isEmpty
        let next: Date = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        SecretReminders.check(now: next)
        SecretReminders.check(now: next)
        let posted: [UNNotificationRequest] = secretReminders(about: name)
        let body: String = posted.first?.content.body ?? ""
        let expected = "Delete or deactivate the old \(name) where you made it, if you haven\u{2019}t yet"
        check(none && posted.count == 1 && body == expected && SecretReminderRecords.remindOn[name] == nil,
              "secret reminders: Remind Me Tomorrow posts one reminder the next day, then its record is gone", body)
    }
}
#endif
