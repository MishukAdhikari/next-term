import AppKit
import NextTermCore

/// Settings › Notifications: which of a tab's notices reach Notification Center, and whether macOS lets
/// them. Each choice is saved as it changes and read when a notice comes (NotificationSettings).
final class NotificationSettingsView: NSView {
    let decisions = NSButton(checkboxWithTitle: "When an agent needs your decision", target: nil, action: nil)
    let agentFinished = NSButton(checkboxWithTitle: "When an agent finishes", target: nil, action: nil)
    let commands = NSPopUpButton()
    let threshold = NSPopUpButton()
    let programAlerts = NSButton(checkboxWithTitle: "A program’s own bell or notification (OSC 9/777)", target: nil, action: nil)
    let sound = NSButton(checkboxWithTitle: "Play a sound", target: nil, action: nil)
    /// Whether macOS lets Next Term notify you.
    let permission = NSTextField(wrappingLabelWithString: "")
    let openSystemSettings = NSButton(title: "Open Notification Settings…", target: nil, action: nil)
    let sendTest = NSButton(title: "Send Test Notification", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        decisions.toolTip = "An agent asks for permission or for a choice. Also while you are in Next Term, for a tab you are not looking at."
        agentFinished.toolTip = "An agent stopped and is waiting for your next prompt, or exited. Also while you are in Next Term, for a tab you are not looking at, unless another agent drives it over MCP."
        programAlerts.toolTip = "A program rang the terminal bell, or sent a notification of its own, while you were in another app."
        for button in [decisions, agentFinished, programAlerts, sound] {
            button.target = self
            button.action = #selector(checkboxChanged(_:))
        }
        for choice in CommandNotifications.allCases {
            commands.addItem(withTitle: choice.title)
            commands.lastItem?.representedObject = choice.rawValue
        }
        commands.target = self
        commands.action = #selector(commandsChanged)
        commands.toolTip = "A build, a test run, a script: anything that is not an agent."
        // VoiceOver reads the popups on their own, without the label beside them.
        commands.setAccessibilityLabel("When a command finishes or fails")
        for choice in WorkThreshold.allCases {
            threshold.addItem(withTitle: choice.title)
            threshold.lastItem?.representedObject = choice.rawValue
        }
        threshold.target = self
        threshold.action = #selector(thresholdChanged)
        threshold.toolTip = "For an agent or a command that finished. A decision, a bell or a program’s notification always counts."
        threshold.setAccessibilityLabel("Only for work that took at least")
        permission.textColor = .secondaryLabelColor
        permission.font = .systemFont(ofSize: 11)
        permission.preferredMaxLayoutWidth = 400
        openSystemSettings.bezelStyle = .rounded
        openSystemSettings.isHidden = true // until macOS says notifications are off
        openSystemSettings.target = self
        openSystemSettings.action = #selector(openNotificationSettings)
        sendTest.bezelStyle = .rounded
        sendTest.target = self
        sendTest.action = #selector(sendTestNotification)

        func row(_ title: String, _ views: [NSView]) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let stack = NSStackView(views: [label] + views)
            stack.spacing = 10
            return stack
        }
        let note = NSTextField(wrappingLabelWithString: "Never for the tab you are looking at. Clicking a notification takes you to its tab. The tab marks, the Dock badge and VoiceOver’s announcements come whatever is chosen here, and the same message from a tab is not repeated within 10 seconds.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.preferredMaxLayoutWidth = 420
        let stack = NSStackView(views: [
            row("Agents:", [decisions]),
            row("", [agentFinished]),
            row("Commands:", [NSTextField(labelWithString: "When one finishes or fails:"), commands]),
            row("Finished work:", [NSTextField(labelWithString: "Only for work that took at least:"), threshold]),
            row("Programs:", [programAlerts]),
            row("Sound:", [sound]),
            row("macOS:", [permission]),
            row("", [sendTest, openSystemSettings]),
            note,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
        refresh()
        // Back from System Settings, the permission may have changed.
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refresh() }
    }

    @objc private func appBecameActive() { refreshPermission() }

    func refresh() {
        let settings = NotificationSettings(defaults: .standard)
        decisions.state = settings.decisions ? .on : .off
        agentFinished.state = settings.agentFinished ? .on : .off
        programAlerts.state = settings.programAlerts ? .on : .off
        sound.state = settings.sound ? .on : .off
        commands.selectItem(at: CommandNotifications.allCases.firstIndex(of: settings.commands) ?? 0)
        threshold.selectItem(at: WorkThreshold.allCases.firstIndex(of: settings.threshold) ?? 0)
        refreshPermission()
    }

    private func refreshPermission() {
        AppDelegate.shared?.notificationPermission { [weak self] status in self?.show(status) }
    }

    func show(_ status: AppDelegate.NotificationPermission) {
        switch status {
        case .allowed: permission.stringValue = "macOS lets Next Term show notifications."
        case .quiet: permission.stringValue = "Allowed, but set to None in System Settings: they go to Notification Center without a banner."
        case .off: permission.stringValue = "Notifications for Next Term are off in System Settings."
        case .notAsked: permission.stringValue = "You haven’t answered macOS’s question yet. Send Test Notification asks again."
        case .unavailable: permission.stringValue = "Only the installed app can show notifications."
        }
        openSystemSettings.isHidden = status != .off && status != .quiet
        sendTest.isEnabled = status != .unavailable
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        let key: String
        switch sender {
        case decisions: key = NotificationSettings.Key.decisions
        case agentFinished: key = NotificationSettings.Key.agentFinished
        case programAlerts: key = NotificationSettings.Key.programAlerts
        case sound: key = NotificationSettings.Key.sound
        default: return
        }
        UserDefaults.standard.set(sender.state == .on, forKey: key)
    }

    @objc private func commandsChanged() {
        guard let raw = commands.selectedItem?.representedObject as? String else { return }
        UserDefaults.standard.set(raw, forKey: NotificationSettings.Key.commands)
    }

    @objc private func thresholdChanged() {
        guard let seconds = threshold.selectedItem?.representedObject as? Int else { return }
        UserDefaults.standard.set(seconds, forKey: NotificationSettings.Key.threshold)
    }

    /// System Settings › Notifications at Next Term's own entry (without a bundle, the list of apps; a macOS
    /// that ignores the id opens the list too).
    static var notificationSettingsURL: URL? {
        let pane = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        guard let id = Bundle.main.bundleIdentifier else { return URL(string: pane) }
        return URL(string: pane + "?id=" + id)
    }

    @objc private func openNotificationSettings() {
        guard let url = Self.notificationSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func sendTestNotification() {
        AppDelegate.shared.sendTestNotification { [weak self] shown in self?.testNotificationSent(shown) }
    }

    /// What came of Send Test Notification: not shown means macOS has Next Term's notifications off.
    func testNotificationSent(_ shown: Bool) {
        guard shown else {
            permission.stringValue = "macOS didn’t show it: notifications for Next Term are off."
            openSystemSettings.isHidden = false
            return
        }
        refreshPermission()
    }
}
