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
/// it); never in the self-test. A failure says nothing and hides nothing: the last answers stay, and a check no source
/// answered tries again an hour later. The answers are kept with the time of the check, so a relaunch within the day
/// shows the same count, less the skills removed since.
@MainActor
enum SkillsUpdateCheck {
    static let answersKey = "SkillsUpdateAnswers"
    private static var observers: [NSObjectProtocol] = []
    private static var timer: Timer?
    private static var checking = false
    /// When the last quiet check got no answer: the next try waits an hour.
    private static var failedAt: Date?

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
            MainActor.assumeIsolated { look() }
        }
        hourly.tolerance = 10 * 60
        RunLoop.main.add(hourly, forMode: .common)
        timer = hourly
        soon()
    }

    /// Half a minute on: the first window, or the network after waking, comes first.
    private static func soon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { look() }
    }

    /// Each look: the day's check when it is due, else the answers less any skill removed outside Next Term.
    private static func look() {
        guard !checking, SkillsStore.home == NSHomeDirectory() else { return }
        // Due a day after the last check (Window › Skills' and Check for Updates count), or with no answers kept yet.
        let kept = UserDefaults.standard.data(forKey: answersKey) != nil
        let due = SkillsWindowController.checksOnOpen
            && SkillUpdates.isDue(now: Date(), lastCheck: kept ? SkillsInstaller.lastCheck : nil, lastFailure: failedAt)
        guard due || !SkillsInstaller.updates.isEmpty else { return }
        checking = true
        Task {
            defer { checking = false }
            let tracked = await SkillsInstaller.tracked()
            guard due, !tracked.isEmpty else { return prune(to: tracked) }
            failedAt = await SkillsInstaller.checkForUpdates(tracked, quietly: true) ? nil : Date()
        }
    }

    /// Drops the answers for skills no longer installed from GitHub (`tracked`, from SkillsInstaller.tracked()), so a
    /// skill removed outside Next Term (`npx skills remove` in a tab) leaves the count.
    static func prune(to tracked: [SkillsInstaller.Tracked]) {
        let left = SkillUpdates.pruned(SkillsInstaller.updates, tracked: Set(tracked.map(\.name)))
        if left != SkillsInstaller.updates { SkillsInstaller.updates = left }
    }

    /// Keeps the answers of the user's own skills for the next launch (`SkillsInstaller.updates` calls it).
    static func keep(_ answers: [String: SkillUpdateState]) {
        guard !SelfTest.isRequested, SkillsStore.home == NSHomeDirectory() else { return }
        UserDefaults.standard.set(SkillUpdates.encode(answers), forKey: answersKey)
    }

    /// The answers kept from a check within the day, for the skills still installed (local files only); older ones are
    /// left for the next check to replace.
    private static func restore() {
        guard !SkillUpdates.isDue(now: Date(), lastCheck: SkillsInstaller.lastCheck),
              let data = UserDefaults.standard.data(forKey: answersKey) else { return }
        let answers = SkillUpdates.decode(data)
        guard !answers.isEmpty else { return }
        Task {
            let tracked = await SkillsInstaller.tracked()
            // Unless a check has answered meanwhile.
            guard SkillsInstaller.updates.isEmpty else { return }
            SkillsInstaller.updates = SkillUpdates.pruned(answers, tracked: Set(tracked.map(\.name)))
        }
    }
}
