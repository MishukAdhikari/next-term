import AppKit
import NextTermCore

/// What a launch shows, and a Dock click with every window closed: the Welcome window, or the projects Settings ›
/// General says to reopen (LaunchDecision). Kept remote tabs wait for the first terminal window, and the relaunch
/// after "Relaunch Now" is told by the flag the quit before it leaves. And what a quit asks about reopening.
extension SelfTest {
    /// First of all: the self-test launches as a normal launch does, with the Welcome window whatever is saved, and
    /// then opens its window as New Terminal does, for every check after this one. Settings › General is checked here
    /// too, and the quit's dialogs, built and never run.
    static func launchChecks() async {
        let app = AppDelegate.shared!
        let welcome: Bool = await wait(5) { () -> Bool in app.welcomeController?.window?.isVisible == true }
        check(welcome && app.controllers.isEmpty, "a launch that names nothing shows the Welcome window, and no terminal window",
              "Welcome \(welcome), terminal windows \(app.controllers.count)")
        check(app.remoteRestorePending, "kept remote tabs wait for the first terminal window, rather than opening one under the Welcome window")
        relaunchFlagChecks()
        app.newWindow(nil)
        let closed = await wait(5) { app.welcomeController?.window?.isVisible != true }
        check(closed && app.controllers.count == 1 && !app.remoteRestorePending,
              "New Terminal closes the Welcome window, and the kept remote tabs' restore starts once its window is open",
              "Welcome closed \(closed), windows \(app.controllers.count), still waiting \(app.remoteRestorePending)")
        generalSettingsChecks()
        quitDialogChecks()
    }

    /// Settings › General back to its defaults, whatever is saved (a run stopped halfway leaves its choices behind).
    /// Call what it returns to put the saved ones back.
    private static func defaultLaunchSettings(_ defaults: UserDefaults) -> () -> Void {
        let keys = LaunchSettings.Key.all
        let saved = keys.map { defaults.object(forKey: $0) }
        keys.forEach(defaults.removeObject(forKey:))
        return {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
    }

    /// The General tab: its controls show the defaults, each one saves its choice as it changes, where the launch and
    /// the quit read it, and a new tab shows what was saved.
    private static func generalSettingsChecks() {
        let defaults = AppDelegate.shared.launchDefaults
        let restore = defaultLaunchSettings(defaults)
        defer { restore() }
        let view = GeneralSettingsView(frame: .zero)
        let titles: [String] = view.opens.map(\.title)
        let welcome = view.radio(.welcome).state == .on && view.radio(.lastProjects).state == .off
        let asks = view.askToReopen.state == .on
        check(titles == ["Show the Welcome window", "Reopen the projects that were open"] && welcome && asks,
              "Settings › General: When Next Term opens shows the Welcome window, and a quit asks whether to reopen projects, until changed",
              "\(titles), Welcome \(welcome), asks \(asks)")
        let group = view.opensGroup
        let role = group.accessibilityRole()
        check(group.isAccessibilityElement() && role == .radioGroup && group.accessibilityLabel() == "When Next Term opens",
              "VoiceOver reads the two choices as one radio group, When Next Term opens",
              "\(role?.rawValue ?? "no role"), \(group.accessibilityLabel() ?? "no label")")
        let help: [String] = (view.opens + [view.askToReopen]).map { $0.accessibilityHelp() ?? "" }
        let opensHelp = help.dropLast().allSatisfy { $0.contains("always opens directly") }
        check(opensHelp && help.last?.contains("always asked about") == true,
              "VoiceOver reads each General note as the help of the controls it is about", "\(help)")

        view.radio(.lastProjects).performClick(nil)
        view.askToReopen.performClick(nil)
        let saved = LaunchSettings(defaults: defaults)
        let savedOpens = defaults.string(forKey: LaunchSettings.Key.opens)
        let onlyOne = view.radio(.welcome).state == .off
        check(savedOpens == "lastProjects" && !saved.askToReopenOnQuit && onlyOne,
              "each General control saves its choice as it changes, and one radio button is on at a time",
              "\(savedOpens ?? "nothing saved"), asks \(saved.askToReopenOnQuit), Welcome still on \(!onlyOne)")
        let reopened = GeneralSettingsView(frame: .zero)
        let shown = reopened.radio(.lastProjects).state == .on && reopened.radio(.welcome).state == .off
        check(shown && reopened.askToReopen.state == .off, "and a new General tab shows it",
              "Reopen on \(shown), asks \(reopened.askToReopen.state == .on)")
    }

    /// The quit's reopen question, with its dialogs built and never run (QuitReopenPrompt): the prompt alone, the
    /// checkbox on the save-changes and "Quitting stops…" alerts, the quit Apple event's reason, and a second quit
    /// while one asks. Made-up folders: nothing here touches the disk.
    private static func quitDialogChecks() {
        let app = "/Users/x/Code/app"
        let api = "/Users/x/Code/api"
        let prompt = QuitReopenPrompt(projects: [app, api, app], returnKeyReopens: false)
        let text = prompt.alert.informativeText
        let named = text.contains("reopen “app” and “api”, or show the Welcome window") && text.contains("Settings › General")
        let dontAsk = prompt.alert.showsSuppressionButton && prompt.alert.suppressionButton?.title == "Don’t ask again"
        check(prompt.alert.messageText == "Reopen these projects next time?" && named && dontAsk,
              "the reopen prompt names each open project once, says both outcomes, and has Don’t ask again",
              "\(prompt.alert.messageText) \(text), Don’t ask again \(dontAsk)")
        let one = QuitReopenPrompt(projects: [app, app], returnKeyReopens: false)
        check(one.alert.messageText == "Reopen this project next time?" && one.alert.informativeText.contains("reopen “app”, or"),
              "with one project open, the reopen prompt asks about this project", one.alert.messageText)
        let alike = QuitReopenPrompt(projects: ["/Users/x/work/app", "/Users/x/home/app"], returnKeyReopens: false)
        check(alike.alert.informativeText.contains("reopen “work/app” and “home/app”,"),
              "two projects in folders of one name are told apart by their parent folders", alike.alert.informativeText)
        promptButtonChecks(returnKeyReopens: false, ["Don’t Reopen", "Cancel", "Reopen"])
        promptButtonChecks(returnKeyReopens: true, ["Reopen", "Cancel", "Don’t Reopen"])

        let save = AppDelegate.saveBeforeQuittingAlert(["notes.md"])
        checkboxChecks(save, "the save-changes alert", checked: false, projects: [app, api])
        let stops = AppDelegate.quitStopsAlert([])
        checkboxChecks(stops, "the Quitting stops alert", checked: true, projects: [app, api])
        let saveOne = AppDelegate.saveBeforeQuittingAlert(["notes.md"])
        checkboxChecks(saveOne, "the save-changes alert", checked: true, projects: [app])
        let stopsOne = AppDelegate.quitStopsAlert([])
        checkboxChecks(stopsOne, "the Quitting stops alert", checked: false, projects: [app])

        reasonChecks()

        // A second quit while one asks (an MCP call, the Dock's Quit under the prompt) is cancelled at once.
        let delegate = AppDelegate.shared!
        delegate.askingToQuit = true
        let reply = delegate.applicationShouldTerminate(NSApp)
        let stillAsking = delegate.askingToQuit
        delegate.askingToQuit = false
        check(reply == .terminateCancel && stillAsking && !delegate.isTerminating && NSApp.modalWindow == nil,
              "a quit while another quit asks is cancelled, shows nothing, and leaves the first one asking",
              "reply \(reply.rawValue), still asking \(stillAsking), terminating \(delegate.isTerminating)")
    }

    /// The prompt's buttons under one setting: the matching choice first, the default with Return; "Cancel" next with
    /// ⎋; the other choice last, with ⌘D or ⌘R; and each button answers for itself, Cancel with nothing even with Don’t
    /// ask again checked.
    private static func promptButtonChecks(returnKeyReopens: Bool, _ expected: [String]) {
        let prompt = QuitReopenPrompt(projects: ["/Users/x/Code/app"], returnKeyReopens: returnKeyReopens)
        let buttons: [NSButton] = prompt.alert.buttons
        let titles: [String] = buttons.map(\.title)
        let keys: [String] = buttons.map(\.keyEquivalent)
        let setting = returnKeyReopens ? "Reopen" : "the Welcome window"
        let otherKey = returnKeyReopens ? "d" : "r"
        let command = buttons.last?.keyEquivalentModifierMask == .command
        check(titles == expected && keys == ["\r", "\u{1b}", otherKey] && command,
              "under \(setting), the reopen prompt's default is \(expected[0]), with Cancel on ⎋ and \(expected[2]) on ⌘\(otherKey.uppercased())",
              "\(titles), keys \(keys.map { $0.unicodeScalars.map { $0.value } }), ⌘ \(command)")
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        for dontAskAgain in [false, true] {
            prompt.alert.suppressionButton?.state = dontAskAgain ? .on : .off
            var wrong: [String] = []
            for (index, title) in titles.enumerated() {
                let answer: QuitAnswer? = prompt.answer(for: NSApplication.ModalResponse(rawValue: first + index))
                let wanted: QuitAnswer?
                switch title {
                case "Reopen": wanted = .reopen(dontAskAgain: dontAskAgain)
                case "Don’t Reopen": wanted = .dontReopen(dontAskAgain: dontAskAgain)
                default: wanted = nil
                }
                if answer != wanted { wrong.append("\(title): \(String(describing: answer))") }
            }
            check(wrong.isEmpty, "under \(setting), each reopen prompt button answers for itself, and Cancel with nothing (Don’t ask again \(dontAskAgain))",
                  wrong.joined(separator: "; "))
        }
    }

    /// The reopen checkbox on a quit alert: its title by the count of projects ("app" alone, or "app" and "api"), its
    /// starting state, the projects in its tooltip, and no Don’t ask again.
    private static func checkboxChecks(_ alert: NSAlert, _ name: String, checked: Bool, projects: [String]) {
        let box = QuitReopenPrompt.addCheckbox(to: alert, checked: checked, projects: projects)
        let tip = box.toolTip ?? ""
        let state = box.state == .on
        let several = projects.count > 1
        let title = several ? "Reopen these projects next time" : "Reopen this project next time"
        let named = tip.contains(several ? "reopens “app” and “api” next" : "reopens “app” next")
        check(box.title == title && state == checked && named && alert.accessoryView === box && !alert.showsSuppressionButton,
              "\(name) carries \(title), \(checked ? "checked" : "unchecked") as the setting is, naming the projects, with no Don’t ask again",
              "\(box.title), on \(state), tooltip \(tip), suppression \(alert.showsSuppressionButton)")
    }

    /// A quit Apple event as loginwindow sends it, with `kAEQuitReason` as a type code or an enumerated one, reads as
    /// a logout, restart or shutdown; one with no reason, or no event (⌘Q), as the user's.
    private static func reasonChecks() {
        func quitEvent(_ why: NSAppleEventDescriptor?, eventID: AEEventID = kAEQuitApplication) -> NSAppleEventDescriptor {
            let event = NSAppleEventDescriptor.appleEvent(withEventClass: kCoreEventClass, eventID: eventID, targetDescriptor: nil,
                                                          returnID: AEReturnID(kAutoGenerateReturnID),
                                                          transactionID: AETransactionID(kAnyTransactionID))
            if let why { event.setAttribute(why, forKeyword: kAEQuitReason) }
            return event
        }
        let shutdown = QuitReopenPrompt.reason(of: quitEvent(NSAppleEventDescriptor(typeCode: kAEShutDown)))
        let logout = QuitReopenPrompt.reason(of: quitEvent(NSAppleEventDescriptor(enumCode: kAEReallyLogOut)))
        let plain = QuitReopenPrompt.reason(of: quitEvent(nil))
        let none = QuitReopenPrompt.reason(of: nil)
        let other = QuitReopenPrompt.reason(of: quitEvent(NSAppleEventDescriptor(typeCode: kAEShutDown), eventID: kAEOpenDocuments))
        check(shutdown == .systemSession && logout == .systemSession && plain == .user && none == .user && other == .user,
              "a quit event with a logout, restart or shutdown reason is the system session's, either way it is sent; any other quit is the user's",
              "shutdown \(shutdown), logout \(logout), no reason \(plain), no event \(none), not a quit event \(other)")
    }

    /// The flag's two ends meet: the quit that installs an update after "Relaunch Now" writes it, and the next launch
    /// takes it, once. On a throwaway defaults suite.
    private static func relaunchFlagChecks() {
        let name = "nextterm-selftest-relaunch-\(getpid())"
        guard let defaults = UserDefaults(suiteName: name) else { return check(false, "a defaults suite for the relaunch flag") }
        defer { defaults.removePersistentDomain(forName: name) }
        let key = Updater.relaunchFlagKey
        let now = Date()
        Updater.flagRelaunch(in: defaults, now: now)
        let relaunch: LaunchKind = AppDelegate.takeLaunchKind(request: false, defaults: defaults, now: now.addingTimeInterval(5))
        let taken = defaults.object(forKey: key) == nil
        check(relaunch == .updateRelaunch && taken, "the launch after Relaunch Now takes its flag as the update relaunch, once",
              "\(relaunch), flag left \(!taken)")
        Updater.flagRelaunch(in: defaults, now: now.addingTimeInterval(-16 * 60))
        let stale: LaunchKind = AppDelegate.takeLaunchKind(request: false, defaults: defaults, now: now)
        let staleTaken = defaults.object(forKey: key) == nil
        let request: LaunchKind = AppDelegate.takeLaunchKind(request: true, defaults: defaults, now: now)
        check(stale == .normal && staleTaken && request == .request,
              "a flag 16 minutes old is a normal launch, and is taken too; with no flag, a launch that names a folder is a request",
              "\(stale), flag left \(!staleTaken), request \(request)")
    }

    /// Last of all, after the Welcome window's own Dock check: with every window closed, the Welcome window too, a
    /// Dock click shows what Settings › General says. The settings and the recent projects are put back.
    static func noWindowDockChecks() async {
        let app = AppDelegate.shared!
        let defaults = app.launchDefaults
        let restore = defaultLaunchSettings(defaults)
        let savedRecents = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []
        defer {
            restore()
            app.setRecentProjects(savedRecents)
        }
        for controller in app.controllers { controller.window?.close() }
        app.welcomeController?.window?.close()
        guard await wait(5, { app.controllers.isEmpty && app.welcomeController?.window?.isVisible != true }) else {
            return note("the windows did not close, so a Dock click with none open was not checked")
        }
        let folder = URL(fileURLWithPath: canonicalPath(NSTemporaryDirectory())).appendingPathComponent("nt-dock-reopen-\(getpid())").path
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        app.setRecentProjects([folder])

        // "Show the Welcome window": the Welcome window, though a recent project is there.
        LaunchSettings().save(to: defaults)
        let welcomeHandled = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        let welcome = await wait(5) { app.welcomeController?.window?.isVisible == true }
        check(welcome && app.controllers.isEmpty && !welcomeHandled,
              "a Dock click with every window closed shows the Welcome window, and opens no project",
              "Welcome \(welcome), windows \(app.controllers.count), AppKit's reopen \(welcomeHandled)")

        // "Reopen the projects that were open": the most recent project.
        app.welcomeController?.window?.close()
        _ = await wait(5) { app.welcomeController?.window?.isVisible != true }
        var reopen = LaunchSettings()
        reopen.opens = .lastProjects
        reopen.save(to: defaults)
        let reopenHandled = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        let opened = await wait(5) { app.controllers.map(\.project) == [folder] }
        check(opened && app.welcomeController?.window?.isVisible != true && !reopenHandled,
              "with Reopen the projects that were open, a Dock click with every window closed opens the most recent project",
              "windows \(app.controllers.map { $0.project ?? "none" }), AppKit's reopen \(reopenHandled)")

        // `nxtrm` with every window closed: its request and the reopen that brings Next Term to the front come in
        // either order. Reopen first, the window is still the request's: a bare `nxtrm` gets its home terminal, and the
        // most recent project does not open beside it.
        for controller in app.controllers { controller.window?.close() }
        guard await wait(5, { app.controllers.isEmpty && app.welcomeController?.window?.isVisible != true }) else {
            return note("the windows did not close, so nxtrm with none open was not checked")
        }
        let raceHandled = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        app.handle(OpenCommand(items: []))
        let home = await wait(5) { app.controllers.count == 1 }
        await pause(1) // past the moment the reopen waits for a request
        let projects: [String] = app.controllers.map { $0.project ?? "none" }
        let welcomeShown = app.welcomeController?.window?.isVisible == true
        check(home && projects == ["none"] && !welcomeShown && !raceHandled,
              "nxtrm with every window closed opens what it asked for, and the Dock reopen it comes with adds nothing",
              "windows \(projects), Welcome \(welcomeShown), AppKit's reopen \(raceHandled)")
    }
}
