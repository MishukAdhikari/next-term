import AppKit
import NextTermCore

/// The Agents menu's Skills…: Settings › Skills, with how many installed skills have an update (SkillUpdates). On macOS 14
/// and later that is the item's badge, which VoiceOver reads with its title ("Skills…, 2 updates"); on macOS 13 it is in the
/// title ("Skills… (2 updates)"). Nothing shows with no update, or before any check has answered.
extension AppDelegate {
    @objc func showSkillsSettings(_ sender: Any?) { showSettings(tab: "skills") }
}

@MainActor
enum SkillsMenuItem {
    nonisolated static let title = "Skills…"
    private static weak var item: NSMenuItem?
    private static var observer: NSObjectProtocol?

    /// Shows the last check's count on `item`, now and whenever the answers change.
    static func follow(_ item: NSMenuItem) {
        self.item = item
        update()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: SkillsInstaller.updatesChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { update() }
        }
    }

    private static func update() {
        guard let item else { return }
        show(SkillUpdates.count(SkillsInstaller.updates), on: item)
    }

    /// `count` updates on `item`: a badge where there is one, else in its title.
    static func show(_ count: Int, on item: NSMenuItem) {
        if #available(macOS 14.0, *) {
            item.title = title
            item.badge = count > 0 ? NSMenuItemBadge.updates(count: count) : nil
        } else {
            item.title = SkillUpdates.title(title, count: count)
        }
    }
}

/// A quiet check for skill updates, so the Agents menu's count means something without opening a window: once a day at
/// most (SkillUpdates.isDue), looked at a little after launch and after waking, and every hour. Only with skills from
/// GitHub installed and Settings › Skills' update check on; off the main thread (GitHub is asked as Check for Updates asks
/// it); never in the self-test. A failure says nothing here: Settings › Skills shows each skill's answer, as after its own
/// check. The answers are kept with the time of the check, so a relaunch within the day shows the same count.
@MainActor
enum SkillsUpdateCheck {
    static let answersKey = "SkillsUpdateAnswers"
    private static var observers: [NSObjectProtocol] = []
    private static var timer: Timer?
    private static var checking = false

    /// Whether it was started (never in the self-test, which checks so).
    static var started: Bool { timer != nil }

    static func start() {
        guard observers.isEmpty, !SelfTest.isRequested else { return }
        restore()
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { soon() }
        })
        // A Mac that never sleeps still checks once a day.
        let hourly = Timer(timeInterval: 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { checkIfDue() }
        }
        hourly.tolerance = 10 * 60
        RunLoop.main.add(hourly, forMode: .common)
        timer = hourly
        soon()
    }

    /// Half a minute on: the first window, or the network after waking, comes first.
    private static func soon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { checkIfDue() }
    }

    private static func checkIfDue() {
        guard SkillsWindowController.checksOnOpen, !checking, SkillsStore.home == NSHomeDirectory() else { return }
        // Due a day after the last check (Window › Skills' and Check for Updates count), or with no answers kept yet.
        let kept = UserDefaults.standard.data(forKey: answersKey) != nil
        guard !kept || SkillUpdates.isDue(now: Date(), lastCheck: SkillsInstaller.lastCheck) else { return }
        checking = true
        Task {
            defer { checking = false }
            let tracked = await SkillsInstaller.tracked()
            guard !tracked.isEmpty else { return }
            await SkillsInstaller.checkForUpdates(tracked)
        }
    }

    /// Keeps the answers of the user's own skills for the next launch (`SkillsInstaller.updates` calls it).
    static func keep(_ answers: [String: SkillUpdateState]) {
        guard !SelfTest.isRequested, SkillsStore.home == NSHomeDirectory() else { return }
        UserDefaults.standard.set(SkillUpdates.encode(answers), forKey: answersKey)
    }

    /// The answers kept from a check within the day; older ones are left for the next check to replace.
    private static func restore() {
        guard !SkillUpdates.isDue(now: Date(), lastCheck: SkillsInstaller.lastCheck),
              let data = UserDefaults.standard.data(forKey: answersKey) else { return }
        let answers = SkillUpdates.decode(data)
        if !answers.isEmpty { SkillsInstaller.updates = answers }
    }
}
