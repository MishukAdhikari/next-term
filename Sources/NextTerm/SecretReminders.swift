import AppKit
import NextTermCore
import UserNotifications

/// Key rotation reminders. Once the vault has loaded at launch, then once a day, each key whose "Remind me to rotate"
/// age has passed gets one notification ("OPENAI_API_KEY was last rotated 92 days ago"), at most one a week, while
/// Settings › Secrets' "Remind me in Notification Center" is on; a key Rotate…'s Remind Me Tomorrow named gets its one
/// reminder on that day, whatever the setting, since the user asked for it then. More than three keys due at once share
/// one notification. Clicking a due key's notification opens Rotate… for it in the Secrets window. A key renamed, deleted
/// or given a new value has its notification taken back from Notification Center.
///
/// The index is read with no unlock (names and dates only), and nothing it keeps is in the vault, so a reminder never
/// asks for Touch ID. A notification carries the key's name and age, never a value or a link, and goes out through the
/// app's own path, which masks stored keys anyway.
@MainActor
enum SecretReminders {
    /// Posted after each check, so an open list reads its ages again: a key may have come due since midnight.
    static let checked = Notification.Name("NextTermSecretRemindersChecked")
    private static var timer: Timer?
    private static var observer: NSObjectProtocol?
    /// The keys as last seen, so a rename moves a key's records with it.
    private static var seen: [SecretVault.Entry]?
    /// The day of the last check: the hourly timer checks once a day, and after the Mac wakes on another day.
    private static var lastChecked: Date?
    /// The first check waits for the vault's load, which says whether its keys can be opened on this Mac.
    private static var waitsForLoad = true

    /// Called once at launch, after the marks load. Not in the self-test, which keeps records of its own and starts
    /// reminders itself (`startForSelfTest`), on days of its choosing.
    static func start() {
        guard !SelfTest.isRequested else { return }
        begin()
    }

    private static func begin() {
        guard timer == nil else { return }
        seen = SecretsStore.shared.index?.entries
        waitsForLoad = true
        observer = NotificationCenter.default.addObserver(forName: SecretsStore.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { storeChanged() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { checkOnNewDay() }
        }
    }

    private static func storeChanged() {
        follow()
        guard waitsForLoad, SecretsStore.shared.hasLoaded else { return }
        waitsForLoad = false
        check(now: currentDate())
    }

    private static func checkOnNewDay() {
        let now: Date = currentDate()
        guard lastChecked != Calendar.current.startOfDay(for: now) else { return }
        check(now: now)
    }

    /// Now, as the checks read it, and the Secrets menu's due rows: in the self-test, the day it set.
    static func currentDate() -> Date {
        #if DEBUG
        if let selfTestNow { return selfTestNow }
        #endif
        return Date()
    }

    /// The records follow the keys as they are now: a renamed key's move to its new name, a deleted key's go, and the
    /// notification of a key renamed, deleted or given a new value since is taken back. With no vault (never made,
    /// started over, or gone since), no key's records stay. A vault that can't be read clears nothing.
    static func follow() {
        let store = SecretsStore.shared
        guard let entries = store.index?.entries else {
            if store.hasLoaded, store.protection == .none { forgetAll() }
            return
        }
        let gone: [String] = SecretReminder.withdrawn(from: seen, to: entries)
        withdraw(gone.map { (name: String) -> String in SecretReminder(name: name, kind: .due).identifier })
        SecretReminderRecords.carry(from: seen, to: entries)
        seen = entries
    }

    /// Every record and every posted reminder gone: the keys they named are no longer in Secrets.
    private static func forgetAll() {
        var names = Set<String>((seen ?? []).map(\.name))
        names.formUnion(SecretReminderRecords.shown.keys)
        names.formUnion(SecretReminderRecords.remindOn.keys)
        seen = []
        guard !names.isEmpty else { return }
        var ids: [String] = names.sorted().map { (name: String) -> String in SecretReminder(name: name, kind: .due).identifier }
        ids.append(SecretReminder(name: "", kind: .severalDue).identifier)
        withdraw(ids)
        SecretReminderRecords.shown = [:]
        SecretReminderRecords.remindOn = [:]
    }

    /// Takes posted reminders back from Notification Center; in the self-test, from its record of them.
    private static func withdraw(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        if SelfTest.isRequested {
            AppDelegate.shared.testNotifications.removeAll { (request: UNNotificationRequest) -> Bool in
                identifiers.contains(request.identifier)
            }
            return
        }
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Posts what is due now and records it: a due key's day shown, a Remind Me Tomorrow day used up. Nothing for a
    /// vault refused or saved on another Mac. With "Remind me in Notification Center" off, due keys are posted nothing
    /// and keep only their badge in the list. More than `SecretReminder.mostApart` due keys at once get one notification
    /// for all of them, and one check makes one sound at most.
    static func check(now: Date = Date()) {
        lastChecked = Calendar.current.startOfDay(for: now)
        waitsForLoad = false // the reload below may post a change: that is no first check
        let store = SecretsStore.shared
        store.reloadIfChanged()
        follow()
        NotificationCenter.default.post(name: checked, object: nil)
        guard store.protection != .tampered, store.protection != .cantOpen, let index = store.index else { return }
        var shown: [String: Date] = SecretReminderRecords.shown
        var remindOn: [String: Date] = SecretReminderRecords.remindOn
        let reminders: [SecretReminder] = SecretAge.toNotify(entries: index.entries, lastShown: shown, remindOn: remindOn, now: now)
        let notifies: Bool = SecretReminderRecords.notifies
        var posted: [SecretReminder] = []
        for reminder in reminders {
            switch reminder.kind {
            case .deleteOld:
                remindOn[reminder.name] = nil
                posted.append(reminder)
            case .due, .severalDue:
                guard notifies else { continue }
                shown[reminder.name] = now
                posted.append(reminder)
            }
        }
        SecretReminderRecords.shown = shown
        SecretReminderRecords.remindOn = remindOn
        post(posted, index: index, now: now)
    }

    /// The reminders, several due keys folded into one. That one stands for each of them: their own from earlier weeks
    /// are taken back. The first makes the sound, if tabs haven't made one in the last 3 seconds.
    private static func post(_ reminders: [SecretReminder], index: SecretVault.Index, now: Date) {
        let folded: [SecretReminder] = SecretReminder.folded(reminders)
        if folded.contains(where: { (reminder: SecretReminder) -> Bool in reminder.kind == .severalDue }) {
            let due: [SecretReminder] = reminders.filter { (reminder: SecretReminder) -> Bool in reminder.kind == .due }
            withdraw(due.map(\.identifier))
        }
        let delegate: AppDelegate = AppDelegate.shared
        let sinceSound: TimeInterval = Date().timeIntervalSince(delegate.lastSoundAt)
        var sound: Bool = NotificationSettings(defaults: .standard).sound && sinceSound >= 3
        for reminder in folded {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body(entry: index.entry(named: reminder.name), now: now)
            content.sound = sound ? .default : nil
            content.threadIdentifier = "secrets"
            content.userInfo = reminder.userInfo
            if sound { delegate.lastSoundAt = Date() }
            sound = false
            delegate.deliver(UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: nil))
        }
    }

    /// A reminder's notification, clicked: the Secrets window with the key selected, and Rotate… open for a due key, as
    /// its button would open it. For Remind Me Tomorrow, where to delete the old key; for several due keys, how many
    /// are due now. With a sheet open on the list, nothing moves behind it: a line says what to do.
    static func open(_ reminder: SecretReminder) {
        SecretsWindowController.show()
        guard let view = SecretsWindowController.shared?.secretsView else { return }
        view.reload()
        guard reminder.kind != .severalDue else { return openSeveral(view) }
        guard let entry = SecretsStore.shared.index?.entry(named: reminder.name) else {
            return view.say("\(reminder.name) isn\u{2019}t in Secrets any more.")
        }
        if reminder.kind == .deleteOld {
            if !view.hasOpenSheet { view.select(entry.name) }
            return view.say(deleteLine(entry))
        }
        guard !view.hasOpenSheet else {
            return view.say("\(entry.name) is due to rotate. Finish or cancel what\u{2019}s open, then choose Rotate… for it.")
        }
        guard !view.openRotate(named: entry.name) else { return }
        view.say("\(entry.name) is due to rotate, but Secrets can\u{2019}t change its keys now.")
    }

    /// Several due keys' notification, clicked: the first key due now selected, and how many are due.
    private static func openSeveral(_ view: SecretsView) {
        let now: Date = currentDate()
        let entries: [SecretVault.Entry] = SecretsStore.shared.index?.entries ?? []
        let due: [SecretVault.Entry] = entries.filter { (entry: SecretVault.Entry) -> Bool in SecretAge.due(entry: entry, now: now) }
        guard let first = due.first else { return view.say("No key is due to rotate now.") }
        if !view.hasOpenSheet { view.select(first.name) }
        guard due.count > 1 else { return view.say("\(first.name) is due to rotate: choose Rotate… for it.") }
        view.say("\(due.count) keys are due to rotate: each reads Due in the list. Choose Rotate… for each.")
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

    #if DEBUG
    /// The self-test's day: checks read it instead of the clock while it is set.
    static var selfTestNow: Date?

    /// The self-test: reminders started as a launch starts them, before a load (`SecretsStore.load()`) posts the first
    /// change.
    static func startForSelfTest() { begin() }

    /// The self-test: reminders stopped as a quit stops them, the records kept.
    static func stopForSelfTest() {
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        seen = nil
        lastChecked = nil
        waitsForLoad = true
    }

    /// The self-test: the hourly timer, fired now.
    static func fireTimerForSelfTest() { timer?.fire() }
    #endif
}

/// Settings › Secrets' reminder settings, under the list (the Secrets window shows them too): "Remind me in Notification
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
