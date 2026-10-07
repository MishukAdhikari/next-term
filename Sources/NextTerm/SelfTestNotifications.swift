import AppKit
import NextTermCore
import UserNotifications

/// Settings › Notifications, end to end: what a tab's notice posts, with Next Term in front or not, under
/// each setting, and the Settings tab's controls. Posts are captured (AppDelegate.testNotifications), so
/// nothing reaches Notification Center.
extension SelfTest {
    static func notificationChecks(_ c: TerminalWindowController) async {
        guard let app = AppDelegate.shared else { return }
        let defaults = UserDefaults.standard
        let keys = NotificationSettings.Key.all
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        keys.forEach(defaults.removeObject(forKey:))

        // A tab in the background: never the one on screen.
        let back = c.addTab(directory: nil, select: false)
        defer { c.requestClose(back) }
        _ = await wait(20) { back.status.integrated }
        check(!c.isOnScreen(back), "notifications: a tab that is not selected is not on screen")

        /// What `notice` from the background tab posts, with Next Term in front (`active`) or not: nil for nothing.
        func posted(_ notice: TabNotice, active: Bool) -> UNNotificationRequest? {
            let before = app.testNotifications.count
            app.post(notice, tab: back, in: c, appActive: active)
            return app.testNotifications.dropFirst(before).last { $0.identifier == back.id.uuidString }
        }
        func agent(_ program: String, after seconds: TimeInterval) -> TabNotice {
            TabNotice(state: .done, command: program, program: program, kind: .agent, stillRunning: true, duration: seconds)
        }
        func command(_ program: String, _ state: TabState = .done) -> TabNotice {
            TabNotice(state: state, command: program, program: program, kind: .command, stillRunning: false, duration: 60)
        }
        func decision(_ program: String) -> TabNotice {
            TabNotice(state: .attention, command: program, program: program, kind: .agent, stillRunning: true,
                      question: "Do you want to make this edit to notes.md?")
        }
        func bell(_ program: String) -> TabNotice {
            TabNotice(state: .attention, command: program, program: program, kind: .command, stillRunning: true,
                      duration: .infinity, fromProgram: true)
        }

        // An agent that finished, in a tab you are not looking at, with Next Term in front.
        let title = Typography.shortened(back.title, to: 80)
        let place = Typography.shortened(c.placeName(of: back), to: 60)
        let done = posted(agent("claude", after: 60), active: true)
        check(done?.content.body == "claude is waiting for you" && done?.content.title == title,
              "notifications: an agent finishing in a background tab notifies while Next Term is in front",
              done.map { "\($0.content.title) | \($0.content.body)" } ?? "nothing posted")
        let subtitle = place == title ? "" : place
        let opens = done?.content.userInfo["tab"] as? String
        let audible = done?.content.sound != nil
        check(done?.content.subtitle == subtitle && audible && opens == back.id.uuidString,
              "naming the window's project, with a sound, and clicking it opens the tab", done?.content.subtitle ?? "nothing posted")
        check(posted(agent("claude", after: 60), active: true) == nil, "the same notification from a tab is held back for 10 seconds")
        defaults.set(false, forKey: NotificationSettings.Key.agentFinished)
        check(posted(agent("codex", after: 60), active: true) == nil && posted(agent("codex", after: 60), active: false) == nil,
              "with “When an agent finishes” off, it does not, in Next Term or from another app")
        defaults.removeObject(forKey: NotificationSettings.Key.agentFinished)

        // A tab another agent drives over MCP: in Next Term its agent finishing is that agent's news, not yours.
        MCPControl.driven.insert(back.id)
        check(posted(agent("opencode", after: 60), active: true) == nil, "an agent finishing in a tab another agent drives does not notify in Next Term")
        let drivenAway = posted(agent("opencode", after: 60), active: false)
        check(drivenAway?.content.body == "opencode is waiting for you", "but does from another app", drivenAway?.content.body ?? "nothing posted")
        check(posted(decision("opencode"), active: true) != nil, "and its decisions notify in Next Term too")
        await keyPressChecks(c, back)
        check(posted(agent("amp", after: 60), active: true) != nil, "once you have typed in it, its agent finishing notifies you again")

        // A decision, whatever the threshold; off, none.
        let asked = posted(decision("claude"), active: true)
        check(asked?.content.title == "claude needs your decision" && asked?.content.body == "Do you want to make this edit to notes.md?",
              "a decision notifies while Next Term is in front, with the question", asked?.content.title ?? "nothing posted")
        defaults.set(false, forKey: NotificationSettings.Key.decisions)
        check(posted(decision("gemini"), active: false) == nil, "with “When an agent needs your decision” off, it does not")
        defaults.removeObject(forKey: NotificationSettings.Key.decisions)

        // A command: by default only from another app; Always, also in Next Term; Never, not at all.
        check(posted(command("make"), active: true) == nil, "a command finishing in a background tab does not notify while Next Term is in front")
        check(posted(command("make"), active: false)?.content.body == "make finished", "but does from another app")
        defaults.set(CommandNotifications.always.rawValue, forKey: NotificationSettings.Key.commands)
        let failed = posted(command("npm", .failed), active: true)
        check(failed?.content.body.hasPrefix("npm failed") == true, "with “Always, for tabs I’m not looking at”, it does in Next Term too",
              failed?.content.body ?? "nothing posted")
        defaults.set(CommandNotifications.never.rawValue, forKey: NotificationSettings.Key.commands)
        check(posted(command("cargo"), active: false) == nil, "with “Never”, not even from another app")
        defaults.removeObject(forKey: NotificationSettings.Key.commands)

        // How long the work took.
        defaults.set(WorkThreshold.thirtySeconds.rawValue, forKey: NotificationSettings.Key.threshold)
        check(posted(agent("gemini", after: 29), active: true) == nil && posted(agent("gemini", after: 30), active: true) != nil,
              "“Only for work that took at least 30 seconds” holds back 29 seconds of work, not 30")
        defaults.removeObject(forKey: NotificationSettings.Key.threshold)

        // Sound off: the notification comes, silent.
        defaults.set(false, forKey: NotificationSettings.Key.sound)
        let silent = posted(agent("qwen", after: 60), active: true)
        check(silent != nil && silent?.content.sound == nil, "with “Play a sound” off, it has no sound")
        defaults.removeObject(forKey: NotificationSettings.Key.sound)

        // A program's own bell or notification: from another app only (in Next Term the amber mark says it).
        check(posted(bell("make"), active: true) == nil && posted(bell("make"), active: false)?.content.body == "make needs your attention",
              "a program’s bell notifies from another app only")
        defaults.set(false, forKey: NotificationSettings.Key.programAlerts)
        check(posted(bell("npm"), active: false) == nil, "and not at all with its setting off")
        defaults.removeObject(forKey: NotificationSettings.Key.programAlerts)

        // Never for the tab you are looking at.
        NSApp.activate(ignoringOtherApps: true)
        c.window?.makeKeyAndOrderFront(nil)
        if let front = c.activeTab, await wait(3, { NSApp.isActive && c.window?.isKeyWindow == true && !c.terminalRailed }) {
            let before = app.testNotifications.count
            app.post(agent("aider", after: 60), tab: front, in: c, appActive: true)
            app.post(decision("aider"), tab: front, in: c, appActive: true)
            check(c.isOnScreen(front) && app.testNotifications.count == before, "no notification for the tab on screen, not even a decision")
        } else {
            note("notifications: the tab on screen skipped, the app is not frontmost")
        }

        await settingsChecks(app)
    }

    /// A key you press in a tab an agent drives makes it yours again; text sent to it does not.
    private static func keyPressChecks(_ c: TerminalWindowController, _ tab: TerminalTab) async {
        tab.view.send(txt: " ")
        check(MCPControl.isDriven(tab), "text sent to a tab is not you typing in it")
        tab.view.send(txt: "\u{15}")
        let shown = c.activeTab
        c.show(tab)
        guard let window = c.window, window.makeFirstResponder(tab.view),
              let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                                           isARepeat: false, keyCode: 49) else {
            note("notifications: a key press in a driven tab skipped, its terminal could not take the keyboard")
            MCPControl.typedByUser(tab)
            return
        }
        window.sendEvent(space)
        check(!MCPControl.isDriven(tab), "a key you press in a tab an agent drives makes it yours again")
        tab.view.send(txt: "\u{15}") // the space typed at its prompt
        if let shown { c.show(shown) }
    }

    /// The Settings tab: its controls show the defaults, and each one changes what is saved.
    private static func settingsChecks(_ app: AppDelegate) async {
        let defaults = UserDefaults.standard
        let labels = (SettingsWindowController().window?.contentView as? NSTabView)?.tabViewItems.map(\.label) ?? []
        check(labels == ["Editor", "Terminal", "Notifications", "Keyboard Shortcuts", "Import"], "Settings has a Notifications tab",
              labels.joined(separator: " | "))
        NotificationSettings.Key.all.forEach(defaults.removeObject(forKey:))
        let view = NotificationSettingsView(frame: .zero)
        let boxes = [view.decisions, view.agentFinished, view.programAlerts, view.sound]
        let allOn = boxes.allSatisfy { $0.state == .on }
        let choices = [view.commands.titleOfSelectedItem, view.threshold.titleOfSelectedItem]
        check(allOn && choices == ["Only when I’m in another app", "5 seconds"],
              "Settings › Notifications: everything on, commands only from another app, 5 seconds",
              "\(boxes.map(\.state.rawValue)) \(view.commands.titleOfSelectedItem ?? "") \(view.threshold.titleOfSelectedItem ?? "")")
        check(view.commands.itemTitles == CommandNotifications.allCases.map(\.title) && view.threshold.itemTitles == WorkThreshold.allCases.map(\.title),
              "with every choice listed", (view.commands.itemTitles + view.threshold.itemTitles).joined(separator: " | "))
        for box in boxes { box.performClick(nil) }
        view.commands.selectItem(at: CommandNotifications.allCases.firstIndex(of: .always) ?? 0)
        if let action = view.commands.action { NSApp.sendAction(action, to: view.commands.target, from: view.commands) }
        view.threshold.selectItem(at: WorkThreshold.allCases.firstIndex(of: .fiveMinutes) ?? 0)
        if let action = view.threshold.action { NSApp.sendAction(action, to: view.threshold.target, from: view.threshold) }
        var expected = NotificationSettings()
        expected.decisions = false
        expected.agentFinished = false
        expected.programAlerts = false
        expected.sound = false
        expected.commands = .always
        expected.threshold = .fiveMinutes
        check(NotificationSettings(defaults: defaults) == expected, "each control saves its choice, read at the next notice",
              "\(NotificationSettings(defaults: defaults))")
        let reopened = NotificationSettingsView(frame: .zero)
        let reopenedOff = [reopened.decisions, reopened.agentFinished, reopened.programAlerts, reopened.sound].allSatisfy { $0.state == .off }
        let reopenedChoices = [reopened.commands.titleOfSelectedItem, reopened.threshold.titleOfSelectedItem]
        check(reopenedOff && reopenedChoices == [CommandNotifications.always.title, WorkThreshold.fiveMinutes.title], "and shows it again")

        // What macOS allows, and a test notification (captured, silent as set).
        check(await wait(3) { !view.permission.stringValue.isEmpty }, "it says whether macOS lets Next Term notify", view.permission.stringValue)
        let before = app.testNotifications.count
        if let action = view.sendTest.action { NSApp.sendAction(action, to: view.sendTest.target, from: view.sendTest) }
        let test = app.testNotifications.dropFirst(before).last
        check(test?.identifier == "test" && test?.content.sound == nil, "Send Test Notification sends one, with the sound as set",
              test?.identifier ?? "nothing posted")
    }
}
