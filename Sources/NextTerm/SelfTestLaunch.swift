import AppKit
import NextTermCore

/// What a launch shows, and a Dock click with every window closed: the Welcome window, the projects Settings ›
/// General says to reopen, or a shell window (LaunchDecision). Kept remote tabs wait for the first terminal window.
/// And what a quit asks about resuming (R29).
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
        // The switcher's checks with the Welcome window alone, ending with ⌘N; without the keys, New Terminal as the menu runs it.
        let pressed: Bool = await welcomeLaunchSwitcherChecks(app)
        if !pressed { app.newWindow(nil) }
        let closed = await wait(5) { app.welcomeController?.window?.isVisible != true }
        check(closed && app.controllers.count == 1 && !app.remoteRestorePending,
              "New Terminal closes the Welcome window, and the kept remote tabs' restore starts once its window is open",
              "Welcome closed \(closed), windows \(app.controllers.count), still waiting \(app.remoteRestorePending)")
        generalSettingsChecks()
        quitDialogChecks()
    }

    /// Settings › General back to its defaults, whatever is saved (a run stopped halfway leaves its choices behind).
    /// Call what it returns to put the saved ones back.
    static func defaultLaunchSettings(_ defaults: UserDefaults) -> () -> Void {
        let keys = LaunchSettings.Key.all
        let saved = keys.map { defaults.object(forKey: $0) }
        keys.forEach(defaults.removeObject(forKey:))
        return {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
    }

    /// The General tab: its controls show the defaults, each one saves only its own choice as it changes, where the launch
    /// and the quit read it, and a new tab shows what was saved.
    private static func generalSettingsChecks() {
        let defaults = AppDelegate.shared.launchDefaults
        let restore = defaultLaunchSettings(defaults)
        defer { restore() }
        let view = GeneralSettingsView(frame: .zero)
        let titles: [String] = view.opens.map(\.title)
        let othersOff = view.radio(.lastProjects).state == .off && view.radio(.newTerminal).state == .off
        let welcome = view.radio(.welcome).state == .on && othersOff
        let asks = view.askToResume.state == .on
        let keeps = view.keepScrollback.state == .on
        let labels = view.askToResume.title == "Ask whether to resume when quitting" && view.keepScrollback.title == "Keep scrollback"
        let expected: [String] = ["Show the Welcome window", "Resume where I left off", "Open a new terminal"]
        check(titles == expected && welcome && asks && keeps && labels,
              "Settings › General: At launch shows the Welcome window, At quit asks whether to resume, and scrollback is kept, until changed",
              "\(titles), Welcome \(welcome), asks \(asks), keeps scrollback \(keeps), \(view.askToResume.title), \(view.keepScrollback.title)")
        let group = view.opensGroup
        let role = group.accessibilityRole()
        check(group.isAccessibilityElement() && role == .radioGroup && group.accessibilityLabel() == "At launch",
              "VoiceOver reads the three choices as one radio group, named At launch as its visible label",
              "\(role?.rawValue ?? "no role"), \(group.accessibilityLabel() ?? "no label")")
        let opensHelp: [String] = view.opens.map { $0.accessibilityHelp() ?? "" }
        let askHelp = view.askToResume.accessibilityHelp() ?? ""
        let scrollbackHelp = view.keepScrollback.accessibilityHelp() ?? ""
        let resumeNote = opensHelp.allSatisfy { $0.hasPrefix("Brings back windows, tabs, splits, scrollback and agents.") }
        check(resumeNote && askHelp.contains("always asked about") && scrollbackHelp.contains("best-effort basis"),
              "VoiceOver reads each General note as the help of the controls it is about", "\(opensHelp), \(askHelp), \(scrollbackHelp)")
        generalLayoutChecks()

        // Unchecking Keep scrollback saves false and touches no other key: At launch stays unchosen.
        view.keepScrollback.performClick(nil)
        let stored: [String] = LaunchSettings.Key.all.filter { defaults.object(forKey: $0) != nil }
        let scrollbackOff = defaults.object(forKey: LaunchSettings.Key.keepScrollback) as? Bool == false
        check(scrollbackOff && stored == [LaunchSettings.Key.keepScrollback] && !LaunchSettings(defaults: defaults).opensChosen,
              "unchecking Keep scrollback saves it alone, and At launch stays never chosen", "stored \(stored)")
        view.radio(.lastProjects).performClick(nil)
        view.askToResume.performClick(nil)
        let saved = LaunchSettings(defaults: defaults)
        let savedOpens = defaults.string(forKey: LaunchSettings.Key.opens)
        let onlyOne = view.radio(.welcome).state == .off && view.radio(.newTerminal).state == .off
        check(savedOpens == "lastProjects" && !saved.askToReopenOnQuit && onlyOne,
              "each General control saves its choice as it changes, and one radio button is on at a time",
              "\(savedOpens ?? "nothing saved"), asks \(saved.askToReopenOnQuit), Welcome still on \(!onlyOne)")
        let reopened = GeneralSettingsView(frame: .zero)
        let shown = reopened.radio(.lastProjects).state == .on && reopened.radio(.welcome).state == .off
        check(shown && reopened.askToResume.state == .off && reopened.keepScrollback.state == .off, "and a new General tab shows it",
              "Resume on \(shown), asks \(reopened.askToResume.state == .on), keeps \(reopened.keepScrollback.state == .on)")
        // "Open a new terminal" is saved as newTerminal, alone on, and a new tab shows it.
        view.radio(.newTerminal).performClick(nil)
        let terminalSaved = defaults.string(forKey: LaunchSettings.Key.opens)
        let terminalAlone = view.radio(.welcome).state == .off && view.radio(.lastProjects).state == .off
        let terminalTab = GeneralSettingsView(frame: .zero)
        let terminalShown = terminalTab.radio(.newTerminal).state == .on && terminalTab.radio(.welcome).state == .off
        check(terminalSaved == "newTerminal" && terminalAlone && terminalShown,
              "Open a new terminal saves its choice, turns the other two off, and a new General tab shows it",
              "\(terminalSaved ?? "nothing saved"), others off \(terminalAlone), new tab \(terminalShown)")
        // A stored 0.10 "Reopen the projects that were open" selects Resume where I left off.
        defaults.set("lastProjects", forKey: LaunchSettings.Key.opens)
        let carried = GeneralSettingsView(frame: .zero)
        check(carried.radio(.lastProjects).state == .on && carried.radio(.lastProjects).title == "Resume where I left off",
              "a stored lastProjects selects Resume where I left off")
    }

    /// The General tab's rows, laid out as the other tabs' are: "At launch:" beside the radio buttons, "At quit:",
    /// "Sessions:" and "Windows:" beside their checkboxes, "Privacy:" beside Full Disk Access…, in a 110 pt label column, so the controls start at one edge. The radio group is
    /// named with the label's words, so VoiceOver does not read "At launch:" too. Measured as Auto Layout places each view,
    /// by its alignment rect: a label's frame is 2 pt wider on each side.
    private static func generalLayoutChecks() {
        let view = GeneralSettingsView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        view.layoutSubtreeIfNeeded()
        func placed(_ control: NSView) -> NSRect {
            view.convert(control.alignmentRect(forFrame: control.frame), from: control.superview)
        }
        let launch: NSTextField = view.launchLabel
        let quit: NSTextField = view.quitLabel
        let sessions: NSTextField = view.sessionsLabel
        let windows: NSTextField = view.windowsLabel
        let privacy: NSTextField = view.privacyLabel
        let titles = launch.stringValue == "At launch:" && quit.stringValue == "At quit:" && sessions.stringValue == "Sessions:"
            && windows.stringValue == "Windows:" && view.projectColors.title == "Show project colors"
            && privacy.stringValue == "Privacy:" && view.fullDiskAccess.title == "Full Disk Access…"
        let widths: [CGFloat] = [placed(launch).width, placed(quit).width, placed(sessions).width, placed(windows).width,
                                 placed(privacy).width]
        let column = widths.allSatisfy { abs($0 - 110) < 0.5 }
        let besideRadios = launch.superview != nil && launch.superview === view.opensGroup.superview
        let besideAsk = quit.superview != nil && quit.superview === view.askToResume.superview
        let besideScrollback = sessions.superview != nil && sessions.superview === view.keepScrollback.superview
            && privacy.superview != nil && privacy.superview === view.fullDiskAccess.superview
            && windows.superview != nil && windows.superview === view.projectColors.superview
        let radiosX: CGFloat = placed(view.opensGroup).minX
        let askX: CGFloat = placed(view.askToResume).minX
        let scrollbackX: CGFloat = placed(view.keepScrollback).minX
        let colorsX: CGFloat = placed(view.projectColors).minX
        let labelEnd: CGFloat = placed(launch).maxX
        let oneEdge = abs(radiosX - askX) < 0.5 && abs(radiosX - scrollbackX) < 0.5 && abs(radiosX - colorsX) < 0.5 && radiosX > labelEnd
        let readOnce = !launch.isAccessibilityElement()
        // The notes' rows start with an empty label in the column, which VoiceOver never reaches.
        var blanks: [NSTextField] = []
        var views: [NSView] = [view]
        while let next = views.popLast() {
            if let field = next as? NSTextField, field.stringValue.isEmpty { blanks.append(field) }
            views.append(contentsOf: next.subviews)
        }
        let silent = blanks.count == 5 && blanks.allSatisfy { !$0.isAccessibilityElement() }
        let beside = besideRadios && besideAsk && besideScrollback
        check(titles && column && beside && oneEdge && readOnce && silent,
              "Settings › General: At launch, At quit, Sessions, Windows and Privacy beside their controls, in a 110 pt label column as in the other tabs",
              "titles \(titles), widths \(widths), beside \(besideRadios) \(besideAsk) \(besideScrollback), radios at \(radiosX), checkboxes at \(askX) \(scrollbackX) \(colorsX), label ends at \(labelEnd), VoiceOver once \(readOnce), empty labels silent \(silent)")
        // The three choices, one under another at one edge, none over another.
        let radios: [NSRect] = view.opens.map(placed)
        let radioXs: [CGFloat] = radios.map(\.minX)
        let aligned = radioXs.allSatisfy { abs($0 - radiosX) < 0.5 }
        var apart = radios.allSatisfy { !$0.isEmpty }
        for (index, radio) in radios.enumerated() where index > 0 {
            let above: NSRect = radios[index - 1]
            if radio.maxY > above.minY + 0.5 { apart = false }
        }
        check(radios.count == 3 && aligned && apart,
              "Settings › General: the three At launch choices stand one under another at one edge, none overlapping",
              "\(radios.map { (rect: NSRect) -> String in NSStringFromRect(rect) })")
    }

    /// The quit's resume question (R29), with its dialogs built and never run (QuitReopenPrompt): the plain dialog, the
    /// checkbox on the save-changes and "Quitting stops…" alerts and their Return keys, the quit Apple event's reason, and a
    /// second quit while one asks. Made-up folders: nothing here touches the disk.
    private static func quitDialogChecks() {
        let app = "/Users/x/Code/app"
        let api = "/Users/x/Code/api"
        let prompt = QuitReopenPrompt(projects: [app, api, app], checked: true)
        let dontAsk = prompt.alert.showsSuppressionButton && prompt.alert.suppressionButton?.title == "Don’t ask again"
        let box = prompt.checkbox
        let boxShown = prompt.alert.accessoryView === box && box.title == QuitPolicy.checkboxTitle && box.state == .on
        let named = (box.toolTip ?? "").contains("“app” and “api”")
        check(prompt.alert.messageText == "Quit Next Term?" && prompt.alert.informativeText.isEmpty && dontAsk && boxShown && named,
              "the plain quit dialog reads Quit Next Term?, with the resume checkbox naming each open project once, and Don’t ask again",
              "\(prompt.alert.messageText) “\(prompt.alert.informativeText)”, Don’t ask again \(dontAsk), box \(boxShown), tooltip \(box.toolTip ?? "none")")
        let unchecked = QuitReopenPrompt(projects: [app], checked: false)
        check(unchecked.checkbox.state == .off, "the plain dialog's box starts as the policy says: unchecked under Welcome")
        promptButtonChecks()

        let save = AppDelegate.saveBeforeQuittingAlert(["notes.md"])
        checkboxChecks(save, "the save-changes alert", checked: false, projects: [app, api])
        let stops = AppDelegate.quitStopsAlert([])
        checkboxChecks(stops, "the Quitting stops alert", checked: true, projects: [app, api])
        // Return: the busy alert's Quit carries none, so Return quits nothing; the save-changes alert keeps Save on Return.
        let stopKeys: [String] = stops.buttons.map(\.keyEquivalent)
        let saveKeys: [String] = save.buttons.map(\.keyEquivalent)
        check(stops.buttons.first?.title == "Quit" && stopKeys.first == "" && saveKeys.first == "\r",
              "the Quitting stops alert's Quit has no Return, and the save-changes alert's Save keeps it",
              "Quitting stops \(stopKeys.map { $0.unicodeScalars.map(\.value) }), save-changes \(saveKeys.map { $0.unicodeScalars.map(\.value) })")

        reasonChecks()

        // A second quit while one asks (an MCP call, the Dock's Quit under the dialog) is cancelled at once.
        let delegate = AppDelegate.shared!
        delegate.askingToQuit = true
        let reply = delegate.applicationShouldTerminate(NSApp)
        let stillAsking = delegate.askingToQuit
        delegate.askingToQuit = false
        check(reply == .terminateCancel && stillAsking && !delegate.isTerminating && NSApp.modalWindow == nil,
              "a quit while another quit asks is cancelled, shows nothing, and leaves the first one asking",
              "reply \(reply.rawValue), still asking \(stillAsking), terminating \(delegate.isTerminating)")
    }

    /// The plain dialog's buttons: "Quit" then "Cancel"; Quit carries no key, so Return presses nothing, and Cancel takes
    /// ⎋. Each button answers for itself: Quit with the box's state and Don’t ask again, Cancel with nothing.
    private static func promptButtonChecks() {
        let prompt = QuitReopenPrompt(projects: ["/Users/x/Code/app"], checked: true)
        let buttons: [NSButton] = prompt.alert.buttons
        let titles: [String] = buttons.map(\.title)
        let keys: [String] = buttons.map(\.keyEquivalent)
        check(titles == ["Quit", "Cancel"] && keys == ["", "\u{1b}"],
              "the plain quit dialog has Quit then Cancel; Quit has no Return, and Cancel has ⎋",
              "\(titles), keys \(keys.map { $0.unicodeScalars.map(\.value) })")
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        for resume in [false, true] {
            for dontAskAgain in [false, true] {
                prompt.checkbox.state = resume ? .on : .off
                prompt.alert.suppressionButton?.state = dontAskAgain ? .on : .off
                let quit: QuitAnswer? = prompt.answer(for: NSApplication.ModalResponse(rawValue: first))
                let cancel: QuitAnswer? = prompt.answer(for: NSApplication.ModalResponse(rawValue: first + 1))
                let wanted: QuitAnswer = .quit(resume: resume, dontAskAgain: dontAskAgain)
                check(quit == wanted && cancel == nil,
                      "Quit answers with the box \(resume ? "checked" : "unchecked") and Don’t ask again \(dontAskAgain ? "on" : "off"), and Cancel with nothing",
                      "Quit \(String(describing: quit)), Cancel \(String(describing: cancel))")
            }
        }
    }

    /// The resume checkbox on a quit alert: its title, its starting state, the projects in its tooltip, and no Don’t ask
    /// again.
    private static func checkboxChecks(_ alert: NSAlert, _ name: String, checked: Bool, projects: [String]) {
        let box = QuitReopenPrompt.addCheckbox(to: alert, checked: checked, projects: projects)
        let tip = box.toolTip ?? ""
        let state = box.state == .on
        let named = tip.contains(projects.count > 1 ? "“app” and “api”" : "“app”")
        check(box.title == QuitPolicy.checkboxTitle && state == checked && named && alert.accessoryView === box
              && !alert.showsSuppressionButton,
              "\(name) carries the resume checkbox, \(checked ? "checked" : "unchecked") as the policy says, naming the projects, with no Don’t ask again",
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
        // The run's projects leave the Welcome list too (the self-test's own history), so it lists the one recent project.
        ProjectHistoryRecorder.shared.clear()

        // "Show the Welcome window": the Welcome window, though a recent project is there.
        LaunchSettings().save(to: defaults)
        let welcomeHandled = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        let welcome = await wait(5) { app.welcomeController?.window?.isVisible == true }
        check(welcome && app.controllers.isEmpty && !welcomeHandled,
              "a Dock click with every window closed shows the Welcome window, and opens no project",
              "Welcome \(welcome), windows \(app.controllers.count), AppKit's reopen \(welcomeHandled)")
        // Clear Menu while it shows: its list goes too. The recent project is put back for the next check.
        let listed: [String] = app.welcomeController?.shownProjects ?? []
        app.clearRecentProjects(nil)
        let afterClear: [String] = app.welcomeController?.shownProjects ?? ["no Welcome window"]
        check(listed == [folder] && afterClear.isEmpty, "Clear Menu under the Welcome window empties its list too",
              "listed \(listed), after Clear Menu \(afterClear)")
        app.setRecentProjects([folder])

        // "Resume where I left off": the most recent project.
        app.welcomeController?.window?.close()
        _ = await wait(5) { app.welcomeController?.window?.isVisible != true }
        var reopen = LaunchSettings()
        reopen.opens = .lastProjects
        reopen.save(to: defaults)
        let reopenHandled = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        let opened = await wait(5) { app.controllers.map(\.project) == [folder] }
        check(opened && app.welcomeController?.window?.isVisible != true && !reopenHandled,
              "with Resume where I left off, a Dock click with every window closed opens the most recent project",
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

        // "Open a new terminal": a shell window with no project, not the most recent project and not the Welcome window.
        for controller in app.controllers { controller.window?.close() }
        guard await wait(5, { app.controllers.isEmpty && app.welcomeController?.window?.isVisible != true }) else {
            return note("the windows did not close, so a Dock click under Open a new terminal was not checked")
        }
        var terminal = LaunchSettings()
        terminal.opens = .newTerminal
        terminal.save(to: defaults)
        let terminalHandled = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        let shell = await wait(5) { app.controllers.count == 1 }
        await pause(0.5) // past the reopen's moment, for a second window
        let shellProjects: [String] = app.controllers.map { $0.project ?? "none" }
        let welcomeUp = app.welcomeController?.window?.isVisible == true
        check(shell && shellProjects == ["none"] && !welcomeUp && !terminalHandled,
              "with Open a new terminal, a Dock click with every window closed opens one shell window, and no Welcome window",
              "windows \(shellProjects), Welcome \(welcomeUp), AppKit's reopen \(terminalHandled)")
    }
}
