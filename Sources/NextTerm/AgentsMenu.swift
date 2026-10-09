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
