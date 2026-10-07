import AppKit
import NextTermCore
import UserNotifications

/// Settings › Notifications, end to end: what a tab's notice posts, with Next Term in front or not, under
/// each setting, and the Settings tab's controls. Posts are captured (AppDelegate.testNotifications), so
/// nothing reaches Notification Center.
extension SelfTest {
    /// Settings › Notifications back to its defaults, whatever is saved (a run stopped halfway, by selftest.sh's
    /// 10 minutes, leaves its choices behind). Call what it returns to put the saved ones back.
    static func defaultNotificationSettings() -> () -> Void {
        let defaults = UserDefaults.standard
        let keys = NotificationSettings.Key.all
        let saved = keys.map { defaults.object(forKey: $0) }
        keys.forEach(defaults.removeObject(forKey:))
        return {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
    }

    static func notificationChecks(_ c: TerminalWindowController) async {
        guard let app = AppDelegate.shared else { return }
        let defaults = UserDefaults.standard
        let restore = defaultNotificationSettings()
        defer { restore() }

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
        app.lastSoundAt = .distantPast
        let done = posted(agent("claude", after: 60), active: true)
        check(done?.content.body == "claude is waiting for you" && done?.content.title == title,
              "notifications: an agent finishing in a background tab notifies while Next Term is in front",
              done.map { "\($0.content.title) | \($0.content.body)" } ?? "nothing posted")
        let subtitle = place == title ? "" : place
        let opens = done?.content.userInfo["tab"] as? String
        let audible = done?.content.sound != nil
        check(done?.content.subtitle == subtitle && audible && opens == back.id.uuidString,
              "naming the window's project, with a sound, and clicking it opens the tab", done?.content.subtitle ?? "nothing posted")
        check(done?.content.threadIdentifier == c.placeName(of: back), "stacked with the window's others in Notification Center",
              done?.content.threadIdentifier ?? "nothing posted")
        // Straight after it: a repeat says nothing new (the guard compares with the tab's last notification).
        check(posted(agent("claude", after: 60), active: true) == nil, "the same notification from a tab is held back for 10 seconds")
        let next = posted(agent("goose", after: 60), active: true)
        check(next != nil && next?.content.sound == nil, "another within 3 seconds comes without a sound, so tabs finishing together make one")
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
            await inFrontChecks(c, front)
            await agentFinishingChecks(c, app)
        } else {
            note("notifications: the tab on screen skipped, the app is not frontmost")
        }

        await settingsChecks(app)
    }

    /// A real agent in a background tab finishing while Next Term is in front: read from its screen, held for
    /// a second, posted. Nothing stands in for NSApp.isActive here.
    private static func agentFinishingChecks(_ c: TerminalWindowController, _ app: AppDelegate) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nextterm-notify-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = dir.appendingPathComponent("claude")
        try? """
        #!/bin/sh
        printf '\\342\\234\\273 Working\\342\\200\\246 (esc to interrupt)\\n'; sleep 6
        printf '\\033[2J\\033[HDone. Ready for your next prompt.\\n'
        read answer
        """.write(to: agent, atomically: true, encoding: .utf8)
        chmod(agent.path, 0o755)
        let tab = c.addTab(directory: nil, select: false)
        _ = await wait(20) { tab.status.integrated }
        c.window?.makeKeyAndOrderFront(nil)
        guard await wait(3, { NSApp.isActive && c.window?.isKeyWindow == true }) else {
            note("notifications: a real agent finishing in Next Term skipped, the app is not frontmost")
            return c.remove(tab)
        }
        tab.view.send(txt: "PATH=\(dir.path):$PATH claude\r")
        check(await wait(4) { tab.status.state == .working && tab.status.screenSynced }, "notifications: a real agent works in a background tab",
              tab.status.state.rawValue)
        let posted = await wait(12) {
            app.testNotifications.contains { $0.identifier == tab.id.uuidString && $0.content.body == "claude is waiting for you" }
        }
        check(posted, "and notifies when it finishes, with Next Term in front", "\(app.testNotifications.suffix(3).map(\.content.body))")
        if !NSApp.isActive { note("notifications: the app lost the front while the agent worked") }
        tab.view.send(txt: "\u{03}")
        _ = await wait(4) { !tab.status.running }
        c.remove(tab)
    }

    /// The window's own sheet or ⌘P panel taking the keyboard leaves its tab in view; another window does not.
    private static func inFrontChecks(_ c: TerminalWindowController, _ front: TerminalTab) async {
        guard let window = c.window else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet) { _ in }
        let sheetKey = await wait(3) { sheet.isKeyWindow }
        check(sheetKey && c.isOnScreen(front), "the tab in front stays in view while its window's sheet has the keyboard")
        window.endSheet(sheet)
        _ = await wait(3) { window.isKeyWindow }

        c.goToFile(nil)
        let panelKey = await wait(3) { NSApp.keyWindow is GoToFilePanel }
        check(panelKey && c.isOnScreen(front), "and while ⌘P’s panel has it")
        c.fileFinder.close()
        window.makeKeyAndOrderFront(nil)
        _ = await wait(3) { window.isKeyWindow }

        // Another window in front, such as Settings, takes it out of view: its agents notify as for any tab.
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.makeKeyAndOrderFront(nil)
        let otherInFront = await wait(3) { other.isKeyWindow && other.isMainWindow }
        check(otherInFront && !c.isOnScreen(front), "but not while another window is in front")
        other.orderOut(nil)
        window.makeKeyAndOrderFront(nil)
        _ = await wait(3) { window.isKeyWindow }
    }

    /// A key you press in a tab an agent drives makes it yours again; text sent to it does not.
    private static func keyPressChecks(_ c: TerminalWindowController, _ tab: TerminalTab) async {
        tab.view.send(txt: " ")
        check(MCPControl.isDriven(tab), "text sent to a tab is not you typing in it")
        tab.view.send(txt: "\u{15}")
        let shown = c.activeTab
        c.show(tab)
        defer { if let shown { c.show(shown) } }
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
    }

    /// The Settings tab: its controls show the defaults, and each one changes what is saved.
    private static func settingsChecks(_ app: AppDelegate) async {
        let defaults = UserDefaults.standard
        let labels = (SettingsWindowController().window?.contentView as? NSTabView)?.tabViewItems.map(\.label) ?? []
        // Branches may add tabs of their own after these (Skills does).
        let named = ["Editor", "Terminal", "Notifications", "Keyboard Shortcuts", "Import"]
        check(Array(labels.prefix(named.count)) == named, "Settings has a Notifications tab",
              labels.joined(separator: " | "))
        NotificationSettings.Key.all.forEach(defaults.removeObject(forKey:))
        let view = NotificationSettingsView(frame: .zero)
        check(view.openSystemSettings.isHidden, "Open Notification Settings… is hidden until macOS says notifications are off")
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
        permissionChecks(view)
    }

    /// What the line about macOS says for each answer it gives, and where its button goes. Not suspending, so
    /// the view's own reading of macOS cannot land in between.
    private static func permissionChecks(_ view: NotificationSettingsView) {
        typealias Permission = AppDelegate.NotificationPermission
        let read = [Permission(.authorized, alertStyle: .banner), Permission(.authorized, alertStyle: .alert),
                    Permission(.authorized, alertStyle: .none), Permission(.denied, alertStyle: .banner), Permission(.notDetermined, alertStyle: .none)]
        check(read == [.allowed, .allowed, .quiet, .off, .notAsked], "macOS’s answer is read: allowed, allowed but without banners, off, not answered",
              "\(read)")
        view.show(.quiet)
        check(!view.openSystemSettings.isHidden && view.permission.stringValue.contains("set to None"),
              "allowed with the style None says so, with Open Notification Settings…", view.permission.stringValue)
        view.show(.allowed)
        check(view.openSystemSettings.isHidden, "allowed, the button goes")
        view.testNotificationSent(false)
        check(!view.openSystemSettings.isHidden && view.permission.stringValue.hasPrefix("macOS didn’t show it"),
              "a test notification macOS refuses says so, instead of nothing happening", view.permission.stringValue)
        let pane = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        let own = Bundle.main.bundleIdentifier.map { pane + "?id=" + $0 } ?? pane
        check(NotificationSettingsView.notificationSettingsURL?.absoluteString == own, "Open Notification Settings… goes to Next Term’s own entry",
              NotificationSettingsView.notificationSettingsURL?.absoluteString ?? "none")
    }
}
