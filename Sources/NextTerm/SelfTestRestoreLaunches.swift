#if DEBUG
import AppKit
import Darwin
import NextTermCore

/// The relaunch harness's launches after the update (plan 003's U10, R2, R21, R29-R32), each a step of its own that
/// `scripts/selftest.sh --relaunch` runs in turn, on the same folder and the same installed copy:
///
/// - `after-welcome-quit` (AE19): the quit before it unchecked the box, so the launch shows the Welcome window and brings
///   back no tab. Then a project window with three tabs, one split at 0.3 with a line in its scrollback, and the
///   stand-in Claude Code running in the first, named in its own session file; the quit checks the box and presses Quit.
/// - `after-quit-checked` (AE17): the quit restore with the consent brings the layout and scrollback back with no Welcome
///   window, and the stand-in resumes its session once. Then a quit with "Ask whether to resume when quitting" off.
/// - `after-quit-unasked` (AE18): the quit restore without it puts `claude --resume S` on the line, unrun. Then the
///   stand-in runs again, and a logout quits.
/// - `open-request` (AE21, and AE18 after a logout): launched as `nxtrm` launches it, naming another folder, the restore
///   comes back with that folder's window in front, and the line on the prompt again. Then the stand-in runs again, and
///   once the restore has settled the step crashes: SIGKILL, from itself.
/// - `after-crash` (AE6, R2): the crash restore brings every window and tab back without scrollback, the line on the
///   prompt, and runs nothing. Then the stand-in runs again, and the step crashes before its restore settles: the first
///   restore that does not finish. `fail-again` crashes in the launch's own turn: the second.
/// - `safe-mode-try-again` (R21): safe mode's one alert, under which a periodic save keeps what each tab held; "Try
///   Again" puts the line back, unrun, once, and resumes nothing. Then a crash: the third, so `set-aside` sets the
///   snapshot aside and its alert says where. That launch runs the stand-in once more and crashes, then `fail-once` and
///   `fail-again` crash at once, and `safe-mode-keep` answers safe mode with "Keep As Is": nothing is typed.
///
/// The stand-in is a program named claude in a folder the driver makes outside the temporary folders (`Harness.agent`),
/// which notes each run's arguments; its session is in a Claude store in that folder, which capture and the restore read
/// for the harness in place of the user's (`RestorePlanning.agentHome`). The resume gate's other checks are the user's
/// Mac's: the steps say which failed, when one does.
extension SelfTestRestore {
    // MARK: AE19's launch, then AE17's quit

    static func afterWelcomeQuit(_ harness: Harness, restore: LaunchRestoreResult) async {
        record("STEP after-welcome-quit")
        let app = AppDelegate.shared!
        isolationChecks(harness)
        let decision = SessionRestore.shared.found?.decision
        let opens = defaults.map { (suite: UserDefaults) -> LaunchOpens in LaunchSettings(defaults: suite).opens }
        let welcome = await SelfTest.wait(10) { app.welcomeController?.window?.isVisible == true }
        guard let files = sessionChecks(harness) else { return finish() }
        let scrollback: [String] = ((try? files.names()) ?? []).filter { $0.hasPrefix(ScrollbackText.filePrefix) }
        let underWelcome: Bool = opens == .welcome
        let normal: Bool = decision?.kind == .normal && restore == .notRun
        check(underWelcome && normal && welcome && app.controllers.isEmpty && scrollback.isEmpty,
              "AE19: after a quit whose resume box was unchecked, the launch shows the Welcome window and brings back no tab or scrollback",
              "Welcome saved \(underWelcome), \(String(describing: decision?.kind)), \(restore), Welcome shown \(welcome), "
                  + "windows \(app.controllers.count), scrollback left \(scrollback.count)")

        // AE17's given: `app` with three tabs, the second split at 0.3 with a line in its scrollback, and Claude Code idle in
        // the first, its session named in its own file.
        let id = claudeSession(harness)
        guard harness.standIn != nil, writeTranscript(harness, id: id) else {
            check(false, "AE17: the stand-in Claude Code and its own store are in the folder the driver made for them")
            return finish()
        }
        let controller = app.openFolder(harness.project.path, newWindow: false)
        guard let claudeTab = controller.tabs.first else {
            check(false, "AE17: the project window opens with a tab")
            return finish()
        }
        let splitTab = controller.addTab(directory: harness.project.path, select: false)
        let idleTab = controller.addTab(directory: harness.project.path, select: false)
        let started = await SelfTest.wait(20) { [claudeTab, splitTab, idleTab].allSatisfy(\.status.integrated) }
        _ = controller.split(vertical: true, from: splitTab, focus: false)
        if let group = controller.group(of: splitTab), case .split(let split) = group.root {
            split.dividers = [0.3]
            group.layout()
        }
        let plain = "nt-quit-plain-" + UUID().uuidString.lowercased()
        try? Data(plain.utf8).write(to: quitPlainFile(harness))
        splitTab.view.send(txt: "echo \(plain)\r")
        _ = await SelfTest.wait(5) { splitTab.status.command == "echo \(plain)" && !splitTab.status.running }
        claudeTab.view.send(txt: "claude\r")
        let named = await nameClaudeSession(harness, in: claudeTab, id: id)
        let saved = await savedClaude(files, tab: claudeTab, id: id)
        let standIn: Bool = saved != nil && saved?.executable == harness.standIn?.path
        check(started && named && standIn,
              "AE17: the stand-in Claude Code runs in the project's first tab, and capture reads its session from its own file",
              "shells \(started), named \(named), evidence \(String(describing: saved))")
        // The login shell's routing variables, which capture compares the agent's with, are read by now.
        _ = await SelfTest.wait(10) { LoginShell.routing != nil }
        if let saved = await savedClaude(files, tab: claudeTab, id: id) {
            let failed = gateFailures(harness, evidence: saved)
            check(failed.isEmpty, "AE17: the stand-in passes every resume check but its session's, which it holds open until the quit",
                  "failed: \(failed.map(\.rawValue)); “routing” fails when this Mac's login shell sets a provider variable the "
                      + "harness's own shells do not, such as ANTHROPIC_BASE_URL, AWS_PROFILE or HTTPS_PROXY")
        }

        // ⌘Q: Claude Code runs, so "Quitting stops…" asks, with the resume box unchecked under Welcome. Checked, then Quit.
        record("STEP after-welcome-quit: quitting with the resume box checked")
        answerQuitQuestion(box: true, press: QuitPromptButton.quit.title)
        NSApp.terminate(nil)
        check(false, "AE17: the quit with the resume box checked goes ahead")
        finish()
    }

    /// AE17's quit, as its last save left it: the box showed unchecked, as "At launch" read Welcome, and its press checked
    /// it, so "At launch" reads Resume, and the clean snapshot holds the windows and a consent id.
    static func checkedQuitSaved(_ harness: Harness) {
        let snapshot = SessionRestore.shared.files.flatMap { SessionWriter.load(from: $0) }
        let opens = defaults.map { (suite: UserDefaults) -> LaunchOpens in LaunchSettings(defaults: suite).opens }
        let header = snapshot?.header
        let windows = snapshot?.windows.count ?? 0
        let boxWasOff: Bool = quitQuestion?.box == false
        let resume: Bool = opens == .lastProjects
        let saved: Bool = header?.clean == true && header?.resumeConsent != nil
        check(boxWasOff && resume && saved && windows == 1,
              "AE17: the box showed unchecked under Welcome, the quit went ahead with it checked: At launch reads Resume, and the "
                  + "last save holds the window and a consent id",
              "box \(String(describing: quitQuestion?.box)), Resume \(resume), clean \(header?.clean ?? false), "
                  + "consent \(header?.resumeConsent != nil), windows \(windows)")
        recordStepEnd()
    }

    // MARK: AE17's launch, then AE18's quit

    static func afterQuitChecked(_ harness: Harness, restore: LaunchRestoreResult, runs before: [String]) async {
        record("STEP after-quit-checked")
        let app = AppDelegate.shared!
        isolationChecks(harness)
        let decision = SessionRestore.shared.found?.decision
        let welcome = app.welcomeController?.window?.isVisible == true
        let quitRestore: Bool = decision?.kind == .restore(.quit) && restore == .openedWindows
        let consented: Bool = decision?.quitConsent == true
        check(quitRestore && consented && !welcome,
              "AE17: the launch after the quit with the box checked is a quit restore with the consent, and no Welcome window shows",
              "\(String(describing: decision?.kind)), consent \(decision?.quitConsent ?? false), \(restore), Welcome \(welcome)")
        guard let files = sessionChecks(harness) else { return finish() }
        let tab = await restoredLayoutChecks(harness, savedAt: .quit, label: "AE17")
        let id = claudeSession(harness)
        guard let tab else {
            check(false, "AE17: the stand-in's tab comes back")
            return finish()
        }
        let resumed = await SelfTest.wait(20) { standInRuns(harness).count > before.count }
        await SelfTest.pause(2)
        let new = Array(standInRuns(harness).dropFirst(before.count))
        check(resumed && new == ["--resume \(id)"] && tab.status.running,
              "AE17: the stand-in Claude Code resumes its session once its shell is ready, and once", "runs since the launch \(new)")
        let outcome = MCPRestoredTabs.details(tab)?.fields["outcome"] as? String
        check(outcome == "resume", "AE17: MCP says the tab resumed", outcome ?? "no details")

        // AE18's given: the same Claude tab, under Resume, with "Ask whether to resume when quitting" off. The resumed
        // stand-in names its session in its own file, as Claude Code does. One the gate kept from resuming waits on the
        // line instead: Return runs it, so the steps after this one still have it.
        if !tab.status.running { tab.view.send(txt: "\r") }
        let named = await nameClaudeSession(harness, in: tab, id: id)
        let saved = await savedClaude(files, tab: tab, id: id)
        check(named && saved != nil, "AE18: the resumed stand-in's session is read from its own file again")
        if let defaults {
            var settings = LaunchSettings(defaults: defaults)
            settings.askToReopenOnQuit = false
            settings.save(.askToReopenOnQuit, to: defaults)
        }
        record("STEP after-quit-checked: quitting with Ask off")
        answerQuitQuestion(box: nil, press: QuitPromptButton.quit.title)
        NSApp.terminate(nil)
        check(false, "AE18: the quit with Ask off goes ahead")
        finish()
    }

    /// AE18's quit, as its last save left it: no question about resuming (Claude Code runs, so "Quitting stops…" asks, with
    /// no box), "At launch" still reads Resume, and the snapshot holds the windows and no consent id.
    static func unaskedQuitSaved(_ harness: Harness) {
        let snapshot = SessionRestore.shared.files.flatMap { SessionWriter.load(from: $0) }
        let opens = defaults.map { (suite: UserDefaults) -> LaunchOpens in LaunchSettings(defaults: suite).opens }
        let header = snapshot?.header
        let noBox: Bool = quitQuestion?.box == nil
        let resume: Bool = opens == .lastProjects
        let saved: Bool = header?.clean == true && header?.resumeConsent == nil
        let windows = snapshot?.windows.count ?? 0
        check(noBox && resume && saved && windows == 1,
              "AE18: with Ask off the quit asks nothing about resuming, and its last save holds the window and no consent id",
              "box \(String(describing: quitQuestion?.box)), Resume \(resume), clean \(header?.clean ?? false), "
                  + "consent \(header?.resumeConsent != nil)")
        recordStepEnd()
    }

    // MARK: AE18's launch, then a logout

    static func afterQuitUnasked(_ harness: Harness, restore: LaunchRestoreResult, runs before: [String]) async {
        record("STEP after-quit-unasked")
        let app = AppDelegate.shared!
        isolationChecks(harness)
        let decision = SessionRestore.shared.found?.decision
        let welcome = app.welcomeController?.window?.isVisible == true
        let quitRestore: Bool = decision?.kind == .restore(.quit) && restore == .openedWindows
        let consented: Bool = decision?.quitConsent == true
        check(quitRestore && !consented && !welcome,
              "AE18: the launch after a quit that asked nothing is a quit restore without the consent, and no Welcome window shows",
              "\(String(describing: decision?.kind)), consent \(decision?.quitConsent ?? false), \(restore), Welcome \(welcome)")
        guard let files = sessionChecks(harness) else { return finish() }
        let tab = await restoredLayoutChecks(harness, savedAt: .quit, label: "AE18")
        await putBackChecks(harness, tab: tab, runs: before, label: "AE18")
        guard let tab else { return finish() }

        // A logout, with "Ask" on again: Return runs the line, so the stand-in runs again, named in its own file.
        let id = claudeSession(harness)
        tab.view.send(txt: "\r")
        let named = await nameClaudeSession(harness, in: tab, id: id)
        let saved = await savedClaude(files, tab: tab, id: id)
        check(named && saved != nil, "AE18: Return runs the line put back, and the stand-in's session is read from its own file")
        if let defaults {
            var settings = LaunchSettings(defaults: defaults)
            settings.askToReopenOnQuit = true
            settings.save(.askToReopenOnQuit, to: defaults)
        }
        quitReason = .systemSession
        record("STEP after-quit-unasked: quitting as a logout")
        answerQuitQuestion(box: nil, press: QuitPromptButton.quit.title)
        NSApp.terminate(nil)
        check(false, "AE18: the quit for a logout goes ahead")
        finish()
    }

    /// The logout's quit (R3, R30), as its last save left it: it went ahead as a logout, asked nothing about resuming though
    /// "Ask" is on, and saved the windows with no consent id.
    static func logoutQuitSaved(_ harness: Harness) {
        let snapshot = SessionRestore.shared.files.flatMap { SessionWriter.load(from: $0) }
        let header = snapshot?.header
        let reason = AppDelegate.shared.quitReason
        let logout: Bool = reason == .systemSession
        let noBox: Bool = quitQuestion?.box == nil
        let saved: Bool = header?.clean == true && header?.resumeConsent == nil
        let windows = snapshot?.windows.count ?? 0
        check(logout && noBox && saved && windows == 1,
              "AE18: a logout asks nothing about resuming, with Ask on, and saves the window with no consent id",
              "\(reason), box \(String(describing: quitQuestion?.box)), clean \(header?.clean ?? false), consent \(header?.resumeConsent != nil)")
        recordStepEnd()
    }

    // MARK: AE21's request launch, then a crash

    static func openRequest(_ harness: Harness, restore: LaunchRestoreResult, runs before: [String]) async {
        record("STEP open-request")
        let app = AppDelegate.shared!
        isolationChecks(harness)
        let decision = SessionRestore.shared.found?.decision
        let welcome = app.welcomeController?.window?.isVisible == true
        let ordered: [NSWindow] = NSApp.orderedWindows.filter { (window: NSWindow) -> Bool in
            app.controllers.contains { $0.window === window }
        }
        let requested = app.controllers.first { $0.project == harness.api.path }
        let restored = app.controllers.first { $0.project == harness.project.path }
        let front = requested?.window != nil && ordered.first === requested?.window
        let notRestored = requested?.tabs.allSatisfy { $0.restoredRecord == nil } ?? false
        let quitRestore: Bool = decision?.kind == .restore(.quit) && restore == .openedWindows
        let consented: Bool = decision?.quitConsent == true
        check(quitRestore && !consented,
              "AE21: a launch that names a folder after a quit under Resume restores the quit's session too",
              "\(String(describing: decision?.kind)), consent \(decision?.quitConsent ?? false), \(restore)")
        check(restored != nil && requested != nil && front && notRestored && !welcome,
              "AE21: the restored window and the folder the launch names are both open, that folder's window in front, and no Welcome window",
              "restored \(restored != nil), requested \(requested != nil), in front \(front), Welcome \(welcome)")
        guard let files = sessionChecks(harness) else { return finish() }
        let tab = await restoredLayoutChecks(harness, savedAt: .quit, label: "AE18 after a logout")
        await putBackChecks(harness, tab: tab, runs: before, label: "AE18 after a logout")
        guard let tab else { return finish() }

        // The crash's given (AE6): Claude Code running with its session named. The restore has settled once the counter
        // reads 0 again, so the next launch counts its own restore from 1.
        let id = claudeSession(harness)
        tab.view.send(txt: "\r")
        let named = await nameClaudeSession(harness, in: tab, id: id)
        let saved = await savedClaude(files, tab: tab, id: id)
        let settled = await SelfTest.wait(RestoreAttempts.settleTime + 40) { attempts(files) == 0 }
        check(named && saved != nil && settled,
              "R2: before the crash, the stand-in runs with its session named, and the restore has settled",
              "named \(named), saved \(saved != nil), counter \(attempts(files) ?? -1)")
        crash()
    }

    // MARK: AE6's crash restore, then the first restore that does not finish

    static func afterCrash(_ harness: Harness, restore: LaunchRestoreResult, runs before: [String]) async {
        record("STEP after-crash")
        let app = AppDelegate.shared!
        isolationChecks(harness)
        let decision = SessionRestore.shared.found?.decision
        let welcome = app.welcomeController?.window?.isVisible == true
        let crashRestore: Bool = decision?.kind == .restore(.crash) && restore == .openedWindows
        check(crashRestore && !welcome,
              "AE6: the launch after the crash is a crash restore, and no Welcome window shows",
              "\(String(describing: decision?.kind)), \(restore), Welcome \(welcome)")
        guard let files = sessionChecks(harness) else { return finish() }
        let windows = SessionRestore.shared.found?.snapshot?.windows.count ?? 0
        check(windows == 2 && app.controllers.count == 2, "AE6: both windows the crash left come back",
              "saved \(windows), open \(app.controllers.count)")
        let tab = await restoredLayoutChecks(harness, savedAt: nil, label: "AE6")
        await putBackChecks(harness, tab: tab, runs: before, label: "AE6")
        let running = app.controllers.flatMap(\.tabs).filter(\.status.running).count
        check(running == 0, "R2: after a crash nothing runs by itself", "\(running) tabs run a command")
        guard let tab else { return finish() }

        // What the next launches restore: the stand-in running again. This restore has not settled when the step crashes,
        // so it is the first that did not finish.
        let id = claudeSession(harness)
        tab.view.send(txt: "\r")
        let named = await nameClaudeSession(harness, in: tab, id: id)
        let saved = await savedClaude(files, tab: tab, id: id)
        let counted = attempts(files)
        check(named && saved != nil && counted == 1, "R21: the crash restore crashes before it settles, the stand-in running",
              "named \(named), saved \(saved != nil), counter \(counted ?? -1)")
        crash()
    }

    // MARK: R21: restores that do not finish

    /// A crash restore that does not finish: the launch's decision checked, then a crash in the launch's own turn, before
    /// any tab's action runs or anything is saved, so the snapshot stays as the launch before left it.
    static func failRestore(attempt count: Int) -> Never {
        let sessions = SessionRestore.shared
        let decision = sessions.found?.decision
        let counted = sessions.files.flatMap { attempts($0) }
        let crashRestore: Bool = decision?.kind == .restore(.crash)
        check(crashRestore && counted == count,
              "R21: a crash restore that does not finish, try \(count)", "\(String(describing: decision?.kind)), counter \(counted ?? -1)")
        crash()
    }

    /// Safe mode's alert, which the launch shows in a turn of its own (SessionRestoreAlerts), where the main queue waits:
    /// a timer in the common modes, set in the launch's own turn, reads it and what the tabs hold under it, waits 2.5
    /// seconds, a periodic save's time and more, then presses `button`.
    static func answerSafeMode(_ harness: Harness, with button: String) {
        let started = Date()
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { safeModeTick(harness, button: button, startedAt: started) }
        }
        RunLoop.main.add(timer, forMode: .common)
        modalTimer = timer
    }

    /// When safe mode's alert first showed.
    private static var safeModeShownAt: Date?

    private static func safeModeTick(_ harness: Harness, button title: String, startedAt started: Date) {
        guard let window = NSApp.modalWindow, let content = window.contentView,
              let button = buttons(in: content).first(where: { $0.title == title }) else {
            if Date().timeIntervalSince(started) > 60 {
                stopModalTimer()
                check(false, "R21: safe mode's alert shows “\(title)”")
            }
            return
        }
        let tab = claudeTab()
        if safeModeShownAt == nil {
            safeModeShownAt = Date()
            let titles = Set(buttons(in: content).filter { !$0.isHidden && !$0.title.isEmpty }.map(\.title))
            let shown = texts(in: content)
            let note = tab?.screenTail(40).joined(separator: "\n").contains("Nothing ran, because the last two restores did not finish.") ?? false
            let offered: Set<String> = [RestoreAlertText.keepAsIs, RestoreAlertText.tryAgain]
            check(shown.contains(RestoreAlertText.safeModeTitle) && titles == offered,
                  "R21: two restores that did not finish give safe mode, with one alert offering Keep As Is and Try Again",
                  "buttons \(titles)")
            let held: Bool = tab?.restoredRecord?.pending?.state == .pending
            check(note && held,
                  "R21: under it, the stand-in's tab says what it held and nothing ran, its action held")
        }
        guard let shownAt = safeModeShownAt, Date().timeIntervalSince(shownAt) >= 2.5 else { return }
        stopModalTimer()
        // The saves go on under the alert, and a pane whose action waits is saved as it was restored.
        let id = claudeSession(harness)
        let kept = tab.flatMap { (tab: TerminalTab) -> SessionSnapshot.Evidence? in
            SessionRestore.shared.files.flatMap { SessionWriter.load(from: $0) }?.panes.first { $0.id == tab.id }?.agent
        }
        check(kept?.sessionID == id, "R21: 2.5 seconds into safe mode, the state file still holds the stand-in's session",
              String(describing: kept))
        record("PASS [\(harness.step.rawValue)] pressed “\(title)”")
        button.performClick(nil)
    }

    /// Safe mode's Try Again (R21): the line goes back, unrun, once, and nothing resumes. Then a crash before it settles:
    /// the third restore that does not finish.
    static func afterTryAgain(_ harness: Harness, restore: LaunchRestoreResult, runs before: [String]) async {
        record("STEP safe-mode-try-again")
        isolationChecks(harness)
        let decision = SessionRestore.shared.found?.decision
        let safeMode: Bool = decision?.kind == .safeMode(.crash) && restore == .openedWindows
        check(safeMode, "R21: the third launch restores in safe mode",
              "\(String(describing: decision?.kind)), \(restore)")
        guard let files = sessionChecks(harness) else { return finish() }
        let id = claudeSession(harness)
        guard let tab = claudeTab() else {
            check(false, "R21: the stand-in's tab comes back in safe mode")
            return finish()
        }
        let applied = await SelfTest.wait(20) { tab.restoredRecord?.pending?.state == .applied }
        await SelfTest.pause(3)
        let line = bottomLine(tab)
        let once = line.components(separatedBy: "claude --resume \(id)").count == 2
        let ran = standInRuns(harness).count != before.count
        check(applied && once && !tab.status.running && !ran,
              "R21: Try Again puts claude --resume S on the line, unrun, once, and resumes nothing",
              "applied \(applied), line “\(line)”, stand-in ran \(ran)")
        let counted = attempts(files)
        check(counted == RestoreAttempts.safeMode + 1, "R21: Try Again counts its try first", "counter \(counted ?? -1)")
        crash()
    }

    /// The set-aside alert, read under it by a timer set in the launch's own turn, then its OK.
    static func answerSetAside(_ harness: Harness) {
        let started = Date()
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { setAsideTick(startedAt: started) }
        }
        RunLoop.main.add(timer, forMode: .common)
        modalTimer = timer
    }

    private static func setAsideTick(startedAt started: Date) {
        guard let window = NSApp.modalWindow, let content = window.contentView,
              texts(in: content).contains(RestoreAlertText.setAsideTitle),
              let ok = buttons(in: content).first(where: { $0.title == "OK" }) else {
            if Date().timeIntervalSince(started) > 60 {
                stopModalTimer()
                check(false, "R21: an alert says the previous session was set aside")
            }
            return
        }
        stopModalTimer()
        let folder = SessionRestore.shared.files?.url.path ?? ""
        let expected = RestoreAlertText.setAsideText(folder: folder, name: SessionLaunch.setAsideName)
        let shown = texts(in: content)
        check(!folder.isEmpty && shown.contains(expected), "R21: one alert says the snapshot was set aside, and names the file it went to",
              "\(shown)")
        record("PASS [\(harness?.step.rawValue ?? "")] pressed “OK”")
        ok.performClick(nil)
    }

    /// After the set-aside alert: the launch is a normal one, the snapshot moved out of the way. Then the stand-in runs in a
    /// window of the project again, and the step crashes: the next two launches crash at once, for safe mode again.
    static func afterSetAside(_ harness: Harness, restore: LaunchRestoreResult) async {
        record("STEP set-aside")
        let app = AppDelegate.shared!
        isolationChecks(harness)
        let decision = SessionRestore.shared.found?.decision
        guard let files = sessionChecks(harness) else { return finish() }
        let names: [String] = (try? files.names()) ?? []
        let moved = names.contains(SessionLaunch.setAsideName)
        let restoredTabs = app.controllers.flatMap(\.tabs).filter { $0.restoredRecord != nil }.count
        let quarantine: Bool = decision?.kind == .quarantine && restore == .notRun
        let startOver: Bool = attempts(files) == 0
        check(quarantine && moved && restoredTabs == 0 && startOver,
              "R21: a third restore that did not finish sets the snapshot aside, the launch restores nothing, and the tries start over",
              "\(String(describing: decision?.kind)), \(restore), set aside \(moved), restored tabs \(restoredTabs), counter \(attempts(files) ?? -1)")

        let id = claudeSession(harness)
        let controller = app.openFolder(harness.project.path, newWindow: false)
        guard let tab = controller.tabs.first, await SelfTest.wait(20, { tab.status.integrated }) else {
            check(false, "R21: the project window's shell starts after the snapshot was set aside")
            return finish()
        }
        tab.view.send(txt: "claude\r")
        let named = await nameClaudeSession(harness, in: tab, id: id)
        let saved = await savedClaude(files, tab: tab, id: id)
        check(named && saved != nil, "R21: the stand-in runs again before the next crash, its session named")
        crash()
    }

    /// Safe mode's Keep As Is (R21): every action dropped, nothing typed or run, and the restore done. The last step.
    static func afterKeepAsIs(_ harness: Harness, restore: LaunchRestoreResult, runs before: [String]) async {
        record("STEP safe-mode-keep")
        let app = AppDelegate.shared!
        isolationChecks(harness)
        let sessions = SessionRestore.shared
        let decision = sessions.found?.decision
        let safeMode: Bool = decision?.kind == .safeMode(.crash) && restore == .openedWindows
        check(safeMode,
              "R21: two more restores that did not finish give safe mode again", "\(String(describing: decision?.kind)), \(restore)")
        guard let tab = claudeTab() else {
            check(false, "R21: the stand-in's tab comes back in safe mode")
            return finish()
        }
        _ = await SelfTest.wait(20) { tab.status.integrated }
        await SelfTest.pause(3)
        let line = bottomLine(tab)
        let ran = standInRuns(harness).count != before.count
        let running = app.controllers.flatMap(\.tabs).filter(\.status.running).count
        let dismissed: Bool = tab.restoredRecord?.pending?.state == .dismissed
        let done: Bool = sessions.phase == .done
        check(dismissed && !line.contains("claude --resume") && running == 0 && !ran && done,
              "R21: Keep As Is leaves each tab as it is: nothing typed or run, and the restore done",
              "\(String(describing: tab.restoredRecord?.pending?.state)), line “\(line)”, running \(running), stand-in ran \(ran), "
                  + "\(sessions.phase)")
        leakChecks(harness)
        finish()
    }

    // MARK: the stand-in Claude Code

    /// The session id the stand-in names, made once for the run and kept in the harness's folder.
    static func claudeSession(_ harness: Harness) -> String {
        let file = harness.folder.appendingPathComponent("claude-session")
        if let kept = try? String(contentsOf: file, encoding: .utf8), RestoreAgent.claude.isSessionID(kept) { return kept }
        let id = UUID().uuidString.lowercased()
        try? Data(id.utf8).write(to: file)
        return id
    }

    /// Each run of the stand-in so far, as it noted its arguments: one line each, "" for none.
    static func standInRuns(_ harness: Harness) -> [String] {
        guard let runs = harness.agentRuns, let text = try? String(contentsOf: runs, encoding: .utf8) else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// The plain line the split pane echoed before AE17's quit, for the restores after it to find above their divider.
    private static func quitPlainFile(_ harness: Harness) -> URL { harness.folder.appendingPathComponent("quit-plain") }

    /// The stand-in's session as Claude Code keeps it, in the harness's store: a transcript for the project, which the
    /// restore finds the session by, free once no process holds it.
    private static func writeTranscript(_ harness: Harness, id: String) -> Bool {
        guard let store = harness.claudeStore else { return false }
        let project = harness.project.path
        let folder = store.appendingPathComponent("projects/" + AgentSessions.claudeFolderName(project), isDirectory: true)
        let line: [String: Any] = ["type": "user", "cwd": project, "sessionId": id, "timestamp": ISO8601DateFormatter().string(from: Date()),
                                   "message": ["role": "user", "content": "harness"]]
        let made = (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                             attributes: [.posixPermissions: 0o700])) != nil
        guard made, var data = try? JSONSerialization.data(withJSONObject: line) else { return false }
        data.append(0x0A)
        return (try? data.write(to: folder.appendingPathComponent(id + ".jsonl"))) != nil
    }

    /// The stand-in now running in `tab`, named as Claude Code names itself: sessions/<pid>.json in the harness's store,
    /// for its pid and start time, so capture reads session `id` from it exactly.
    private static func nameClaudeSession(_ harness: Harness, in tab: TerminalTab, id: String) async -> Bool {
        let running = await SelfTest.wait(10) { tab.status.running && tab.status.kind == .agent }
        let leader = tcgetpgrp(tab.view.process.childfd)
        guard running, leader > 0, let start = ProcessInspector.startTime(of: leader), let store = harness.claudeStore else { return false }
        let sessions = store.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let record: [String: Any] = ["pid": Int(leader), "sessionId": id, "cwd": harness.project.path,
                                     "procStart": AgentEvidence.procStartText(start), "status": "idle"]
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return false }
        let path = sessions.appendingPathComponent("\(leader).json").path
        return FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// The stand-in's evidence once a periodic save holds it for `tab`: session `id`, read from its own file.
    private static func savedClaude(_ files: SessionFiles, tab: TerminalTab, id: String) async -> SessionSnapshot.Evidence? {
        var found: SessionSnapshot.Evidence?
        _ = await SelfTest.wait(15) {
            found = SessionWriter.load(from: files)?.panes.first { $0.id == tab.id }?.agent
            return found?.sessionID == id && found?.source == .sessionFile
        }
        return found?.sessionID == id && found?.source == .sessionFile ? found : nil
    }

    /// The resume gate (KTD5) on what capture read of the stand-in, with its session taken as free: a running stand-in
    /// holds it open, and the quit frees it. The checks that fail.
    private static func gateFailures(_ harness: Harness, evidence: SessionSnapshot.Evidence) -> [ResumeCheck] {
        let project = harness.project.path
        let facts = ResumeFacts.read(for: evidence, projects: [project], tabFolder: project, sessionAvailable: true,
                                     home: RestorePlanning.agentHome)
        switch evidence.gate(facts) {
        case .resume: return []
        case .onTheLine(let failed): return failed
        case .note: return [.automatic]
        }
    }

    /// The tab a restore brought the stand-in back in: the one whose record names Claude Code.
    private static func claudeTab() -> TerminalTab? {
        AppDelegate.shared.controllers.flatMap(\.tabs).first { $0.restoredRecord?.agent?.agent == .claude }
    }

    // MARK: checks

    /// The windows a restore built from the snapshot the launch found: every tab with the id it had, the project's split
    /// at 0.3, and the split pane's scrollback above its divider when the quit saved it (`savedAt`), or none in any tab.
    /// Returns the tab the stand-in ran in.
    private static func restoredLayoutChecks(_ harness: Harness, savedAt: ScrollbackText.SavedAt?, label: String) async -> TerminalTab? {
        let app = AppDelegate.shared!
        let saved = Set(SessionRestore.shared.found?.snapshot?.panes.map(\.id) ?? [])
        let restored: [TerminalTab] = app.controllers.flatMap(\.tabs).filter { saved.contains($0.id) }
        check(!saved.isEmpty && restored.count == saved.count, "\(label): every tab comes back with the id it had",
              "saved \(saved.count), back \(restored.count)")
        let window = app.controllers.first { $0.project == harness.project.path }
        var fractions: [CGFloat] = []
        var splitPane: TerminalTab?
        for group in window?.groups ?? [] {
            if case .split(let split) = group.root {
                fractions = split.dividers
                splitPane = group.panes.first
            }
        }
        let atThird = fractions.count == 1 && abs((fractions.first ?? 0) - 0.3) < 0.01
        check(window?.groups.count == 3 && atThird, "\(label): the project window's three tabs come back, the split left at 0.3 at 0.3",
              "tabs \(window?.groups.count ?? 0), dividers \(fractions)")
        let plain = (try? String(contentsOf: quitPlainFile(harness), encoding: .utf8)) ?? ""
        _ = await SelfTest.wait(10) { splitPane?.status.integrated == true }
        let shown = splitPane?.screenTail(400).joined(separator: "\n") ?? ""
        if let savedAt {
            check(splitPane?.restoreDivider != nil && shown.contains(savedAt.divider) && !plain.isEmpty && shown.contains(plain),
                  "\(label): the split pane shows the scrollback saved at the quit, its line above the divider")
        } else {
            let none = restored.allSatisfy { $0.restoreDivider == nil }
            check(none && !plain.isEmpty && !shown.contains(plain), "\(label): no tab shows scrollback")
        }
        return claudeTab()
    }

    /// The stand-in's tab after a restore that does not resume it: `claude --resume S` waits on its prompt line, unrun, and
    /// the stand-in did not run.
    private static func putBackChecks(_ harness: Harness, tab: TerminalTab?, runs before: [String], label: String) async {
        guard let tab else { return check(false, "\(label): the stand-in's tab comes back") }
        let id = claudeSession(harness)
        let applied = await SelfTest.wait(20) { tab.restoredRecord?.pending?.state == .applied }
        await SelfTest.pause(2)
        let line = bottomLine(tab)
        let ran = standInRuns(harness).count != before.count
        check(applied && line.contains("claude --resume \(id)") && !tab.status.running && !ran,
              "\(label): claude --resume S waits on the stand-in's prompt line, unrun, and nothing resumed it",
              "applied \(applied), line “\(line)”, stand-in ran \(ran)")
        let outcome = MCPRestoredTabs.details(tab)?.fields["outcome"] as? String
        check(outcome == "agent_on_the_line", "\(label): MCP says the agent's resume command is on the line", outcome ?? "no details")
    }

    /// The restore attempts counter as the sessions folder holds it now; nil when there is none or it does not read.
    private static func attempts(_ files: SessionFiles) -> Int? {
        guard let data = (try? files.read(RestoreAttempts.fileName, maxSize: RestoreAttempts.maxSize)) ?? nil else { return nil }
        return RestoreAttempts.parse(data).count
    }

    private static func bottomLine(_ tab: TerminalTab) -> String {
        tab.liveTail(4).last { (line: String) -> Bool in !line.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }

    private static func texts(in view: NSView) -> [String] {
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { texts(in: $0) }
    }

    // MARK: quitting and crashing

    /// The quit's question as the harness answered it: whether its alert had the resume box, and how the box showed.
    private(set) static var quitQuestion: (shown: Bool, box: Bool?)?
    private static var modalTimer: Timer?

    private static func stopModalTimer() {
        modalTimer?.invalidate()
        modalTimer = nil
    }

    /// Answers the quit's question once one shows: its resume box set to `box` (nil: as it showed), then `button`. A timer
    /// in the common modes, which fire under the app-modal alert. A quit that asks nothing goes ahead before it is needed.
    static func answerQuitQuestion(box wanted: Bool?, press title: String) {
        let started = Date()
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { quitQuestionTick(box: wanted, button: title, startedAt: started) }
        }
        RunLoop.main.add(timer, forMode: .common)
        modalTimer = timer
    }

    private static func quitQuestionTick(box wanted: Bool?, button title: String, startedAt started: Date) {
        guard let window = NSApp.modalWindow, let content = window.contentView,
              let button = buttons(in: content).first(where: { $0.title == title }) else {
            if Date().timeIntervalSince(started) > 60 {
                stopModalTimer()
                check(false, "a quit question shows “\(title)”")
            }
            return
        }
        stopModalTimer()
        let box = buttons(in: content).first { $0.title == QuitPolicy.checkboxTitle }
        let showed: Bool? = box.map { $0.state == .on }
        quitQuestion = (true, showed)
        if let box, let wanted, (box.state == .on) != wanted { box.performClick(nil) }
        let said = showed.map { $0 ? "checked" : "unchecked" } ?? "not there"
        record("PASS [\(harness?.step.rawValue ?? "")] pressed “\(title)”, the resume box \(said) as it showed")
        button.performClick(nil)
    }

    /// Ends a step as a crash ends Next Term: its last line, the servers that would leave files outside the harness's folder
    /// stopped, then SIGKILL. No quit runs: no last save, and the restore attempts counter stays as it is.
    static func crash() -> Never {
        recordStepEnd()
        ClaudeIDEServer.shared.stop()
        CopilotIDEServer.shared.stop()
        try? FileManager.default.removeItem(at: SelfTest.copilotLockFolder)
        kill(getpid(), SIGKILL)
        exit(1)
    }
}
#endif
