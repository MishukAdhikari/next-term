import AppKit
import NextTermCore
import UserNotifications

/// Key rotation reminders. Once the vault has loaded at launch, then once a day, each key whose "Remind me to rotate"
/// age has passed gets one notification ("OPENAI_API_KEY was last rotated 92 days ago"), at most one a week, while
/// Settings › Secrets' "Remind me in Notification Center" is on; a key Rotate…'s Remind Me Tomorrow named gets its one
/// reminder on that day, whatever the setting, since the user asked for it then. Clicking a due key's notification opens
/// Rotate… for it in Window › Secrets.
///
/// The index is read with no unlock (names and dates only), and nothing it keeps is in the vault, so a reminder never
/// asks for Touch ID. A notification carries the key's name and age, never a value or a link, and goes out through the
/// app's own path, which masks stored keys anyway.
@MainActor
enum SecretReminders {
    private static var timer: Timer?
    private static var observer: NSObjectProtocol?
    /// The keys as last seen, so a rename moves a key's records with it.
    private static var seen: [SecretVault.Entry]?
    /// The day of the last check: the hourly timer checks once a day, and after the Mac wakes on another day.
    private static var lastChecked: Date?
    /// The first check waits for the vault's load, which says whether its keys can be opened on this Mac.
    private static var waitsForLoad = true

    /// Called once at launch, after the marks load. Not in the self-test, which keeps records of its own and checks
    /// when it chooses (`check(now:)`).
    static func start() {
        guard !SelfTest.isRequested, timer == nil else { return }
        seen = SecretsStore.shared.index?.entries
        observer = NotificationCenter.default.addObserver(forName: SecretsStore.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { storeChanged() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { checkOnNewDay() }
        }
    }

    private static func storeChanged() {
        follow()
        guard waitsForLoad else { return }
        waitsForLoad = false
        check()
    }

    private static func checkOnNewDay(now: Date = Date()) {
        guard lastChecked != Calendar.current.startOfDay(for: now) else { return }
        check(now: now)
    }

    /// The records follow the keys as they are now: a renamed key's move to its new name, a deleted key's go. Not while
    /// the vault can't be read, so a refused file never clears them.
    static func follow() {
        guard let entries = SecretsStore.shared.index?.entries else { return }
        SecretReminderRecords.carry(from: seen, to: entries)
        seen = entries
    }

    /// Posts what is due now and records it: a due key's day shown, a Remind Me Tomorrow day used up. Nothing for a
    /// vault refused or saved on another Mac. With "Remind me in Notification Center" off, due keys are posted nothing
    /// and keep only their badge in the list.
    static func check(now: Date = Date()) {
        lastChecked = Calendar.current.startOfDay(for: now)
        waitsForLoad = false // the reload below may post a change: that is no first check
        let store = SecretsStore.shared
        store.reloadIfChanged()
        follow()
        guard store.protection != .tampered, store.protection != .cantOpen, let index = store.index else { return }
        var shown: [String: Date] = SecretReminderRecords.shown
        var remindOn: [String: Date] = SecretReminderRecords.remindOn
        let reminders: [SecretReminder] = SecretAge.toNotify(entries: index.entries, lastShown: shown, remindOn: remindOn, now: now)
        let notifies: Bool = SecretReminderRecords.notifies
        for reminder in reminders {
            switch reminder.kind {
            case .deleteOld:
                remindOn[reminder.name] = nil
                post(reminder, entry: index.entry(named: reminder.name), now: now)
            case .due:
                guard notifies else { continue }
                shown[reminder.name] = now
                post(reminder, entry: index.entry(named: reminder.name), now: now)
            }
        }
        SecretReminderRecords.shown = shown
        SecretReminderRecords.remindOn = remindOn
    }

    private static func post(_ reminder: SecretReminder, entry: SecretVault.Entry?, now: Date) {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body(entry: entry, now: now)
        content.sound = NotificationSettings(defaults: .standard).sound ? .default : nil
        content.threadIdentifier = "secrets"
        content.userInfo = reminder.userInfo
        AppDelegate.shared.deliver(UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: nil))
    }

    /// A reminder's notification, clicked: Window › Secrets with the key selected, and Rotate… open for a due key. For
    /// Remind Me Tomorrow, where to delete the old key.
    static func open(_ reminder: SecretReminder) {
        SecretsWindowController.show()
        guard let view = SecretsWindowController.shared?.secretsView else { return }
        view.reload()
        guard let entry = SecretsStore.shared.index?.entry(named: reminder.name) else {
            return view.say("\(reminder.name) isn\u{2019}t in Secrets any more.")
        }
        switch reminder.kind {
        case .due:
            view.openRotate(named: entry.name)
        case .deleteOld:
            view.select(entry.name)
            view.say(deleteLine(entry))
        }
    }

    /// Where to delete a rotated key's old value: its page, named by its host, or where it was made.
    static func deleteLine(_ entry: SecretVault.Entry) -> String {
        let host: String? = SecretsStore.shared.pageLink(of: entry.name).flatMap { (page: Result<URL, SecretLink.Refusal>) -> String? in
            guard case .success(let url) = page else { return nil }
            return SecretLink.host(of: url)
        }
        guard let host else { return "Delete or deactivate the old \(entry.name) where you made it." }
        return "Delete or deactivate the old \(entry.name) on its page: choose Open \(host) in its right-click menu."
    }
}

/// Settings › Secrets' reminder settings, under the list (Window › Secrets shows them too): "Remind me in Notification
/// Center", on unless turned off, and the age a new key starts with in Add…, `request_secret`'s window, `store_secret`
/// and the import, Never unless set. Both live in the reminders' defaults, not in the vault, so changing them asks for
/// no Touch ID. A change in one window shows in the other.
@MainActor
final class SecretReminderSettingsView: NSStackView {
    static let changed = Notification.Name("NextTermSecretReminderSettingsChanged")
    static let notifyTitle = "Remind me in Notification Center"
    static let notifyHelp = "When a key is past its \u{201C}Remind me to rotate\u{201D} age. Its row shows Due either way."
    static let newKeysTitle = "New keys: Remind me to rotate"

    private(set) var notifyBox = NSButton(checkboxWithTitle: SecretReminderSettingsView.notifyTitle, target: nil, action: nil)
    private(set) var newKeysPopUp = NSPopUpButton(frame: .zero, pullsDown: false)

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        let heading = NSTextField(labelWithString: "Reminders")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        notifyBox.target = self
        notifyBox.action = #selector(notifyChanged)
        let help = SecretApprovalPanel.label(Self.notifyHelp, size: 11)
        help.textColor = .secondaryLabelColor
        newKeysPopUp.target = self
        newKeysPopUp.action = #selector(newKeysChanged)
        newKeysPopUp.setAccessibilityLabel(Self.newKeysTitle)
        let caption = NSTextField(labelWithString: Self.newKeysTitle)
        caption.font = .systemFont(ofSize: 12)
        let newKeys = NSStackView(views: [caption, newKeysPopUp, NSView()])
        newKeys.spacing = 8
        for view in [heading, notifyBox, help, newKeys] { addArrangedSubview(view) }
        for view in [help, newKeys] { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: Self.changed, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// The settings as saved; a saved age off the menu keeps an item of its own.
    @objc func reload() {
        notifyBox.state = SecretReminderRecords.notifies ? .on : .off
        let days: Int? = SecretReminderRecords.newKeyDays
        var choices: [Int] = SecretEditSheet.remindChoices
        if let days, !choices.contains(days) { choices.append(days) }
        newKeysPopUp.removeAllItems()
        for choice in choices.sorted() {
            newKeysPopUp.addItem(withTitle: choice == 0 ? "Never" : "\(choice) days")
            newKeysPopUp.lastItem?.tag = choice
        }
        newKeysPopUp.selectItem(withTag: days ?? 0)
    }

    @objc func notifyChanged() {
        SecretReminderRecords.notifies = notifyBox.state == .on
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    @objc func newKeysChanged() {
        let tag: Int = newKeysPopUp.selectedTag()
        SecretReminderRecords.newKeyDays = tag > 0 ? tag : nil
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}
