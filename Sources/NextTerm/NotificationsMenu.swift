import AppKit
import NextTermCore

/// The Notifications menu: Settings › Notifications in the menu bar, each choice with its checkmark, saved as it is
/// chosen and read when a notice comes (NotificationSettings), as the Settings pane does. Each item is a command of its
/// own, so Settings › Keyboard Shortcuts can give one a key.
@MainActor
final class NotificationsMenu: NSObject, NSMenuItemValidation {
    static let shared = NotificationsMenu()

    /// Posted when a choice changes here: Settings › Notifications shows it if open.
    nonisolated static let changed = Notification.Name("NextTermNotificationChoicesChanged")

    /// The menu's items, under `menu`.
    func fill(_ menu: NSMenu) {
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ value: String? = nil, tip: String? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.toolTip = tip
            menu.addItem(item)
        }
        add(menu, "When an Agent Needs Your Decision", #selector(toggleNotifyDecisions(_:)),
            tip: "An agent asks for permission or for a choice. Also while you are in Next Term, for a tab you are not looking at.")
        add(menu, "When an Agent Finishes", #selector(toggleNotifyAgentFinished(_:)),
            tip: "An agent stopped and is waiting for your next prompt, or exited.")
        let commands = NSMenu(title: "When a Command Finishes or Fails")
        for choice in CommandNotifications.allCases { add(commands, Self.title(choice), #selector(chooseCommandNotifications(_:)), choice.rawValue) }
        let commandsItem = menu.addItem(withTitle: commands.title, action: nil, keyEquivalent: "")
        commandsItem.submenu = commands
        commandsItem.toolTip = "A build, a test run, a script: anything that is not an agent."
        let threshold = NSMenu(title: "Only for Work That Took at Least")
        for choice in WorkThreshold.allCases { add(threshold, choice.title, #selector(chooseWorkThreshold(_:)), String(choice.rawValue)) }
        let thresholdItem = menu.addItem(withTitle: threshold.title, action: nil, keyEquivalent: "")
        thresholdItem.submenu = threshold
        thresholdItem.toolTip = "For an agent or a command that finished. A decision, a bell or a program’s notification always counts."
        add(menu, "A Program’s Own Bell or Notification", #selector(toggleNotifyProgramAlerts(_:)),
            tip: "A program rang the terminal bell, or sent a notification of its own (OSC 9/777), while you were in another app.")
        add(menu, "Play a Sound", #selector(toggleNotificationSound(_:)))
        menu.addItem(.separator())
        add(menu, "Send Test Notification", #selector(sendTestNotification(_:)))
        add(menu, "Notification Settings…", #selector(showNotificationSettings(_:)))
    }

    /// The command choices in the menu's title case.
    static func title(_ choice: CommandNotifications) -> String {
        switch choice {
        case .inAnotherApp: return "Only When I’m in Another App"
        case .always: return "Always, for Tabs I’m Not Looking At"
        case .never: return "Never"
        }
    }

    // MARK: choosing

    @objc func toggleNotifyDecisions(_ sender: Any?) { toggle(NotificationSettings.Key.decisions) }
    @objc func toggleNotifyAgentFinished(_ sender: Any?) { toggle(NotificationSettings.Key.agentFinished) }
    @objc func toggleNotifyProgramAlerts(_ sender: Any?) { toggle(NotificationSettings.Key.programAlerts) }
    @objc func toggleNotificationSound(_ sender: Any?) { toggle(NotificationSettings.Key.sound) }

    @objc func chooseCommandNotifications(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, CommandNotifications(rawValue: raw) != nil else { return }
        save(raw, NotificationSettings.Key.commands)
    }

    @objc func chooseWorkThreshold(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let seconds = Int(raw), WorkThreshold(rawValue: seconds) != nil else { return }
        save(seconds, NotificationSettings.Key.threshold)
    }

    /// Not shown (macOS has Next Term's notifications off): Settings › Notifications says so, with the way to turn them on.
    @objc func sendTestNotification(_ sender: Any?) {
        AppDelegate.shared.sendTestNotification { shown in
            if !shown { AppDelegate.shared.showSettings(tab: "notifications") }
        }
    }

    @objc func showNotificationSettings(_ sender: Any?) {
        AppDelegate.shared.showSettings(tab: "notifications")
    }

    /// A switch flipped from what is saved now (its default when nothing is).
    private func toggle(_ key: String) {
        save(!(isOn(key)), key)
    }

    private func isOn(_ key: String) -> Bool {
        let settings = NotificationSettings(defaults: .standard)
        switch key {
        case NotificationSettings.Key.decisions: return settings.decisions
        case NotificationSettings.Key.agentFinished: return settings.agentFinished
        case NotificationSettings.Key.programAlerts: return settings.programAlerts
        case NotificationSettings.Key.sound: return settings.sound
        default: return false
        }
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // MARK: checkmarks

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let settings = NotificationSettings(defaults: .standard)
        let on: Bool
        switch item.action {
        case #selector(toggleNotifyDecisions(_:)): on = settings.decisions
        case #selector(toggleNotifyAgentFinished(_:)): on = settings.agentFinished
        case #selector(toggleNotifyProgramAlerts(_:)): on = settings.programAlerts
        case #selector(toggleNotificationSound(_:)): on = settings.sound
        case #selector(chooseCommandNotifications(_:)): on = item.representedObject as? String == settings.commands.rawValue
        case #selector(chooseWorkThreshold(_:)): on = item.representedObject as? String == String(settings.threshold.rawValue)
        default: return true
        }
        item.state = on ? .on : .off
        return true
    }
}
