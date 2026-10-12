#if DEBUG
import AppKit
import NextTermCore

/// The relaunch harness, in debug builds only: a real quit and relaunch of a throwaway copy of the app, without the
/// release key. `scripts/selftest.sh --relaunch` wraps the debug binary in two app bundles signed ad hoc, in a private
/// folder of its own (`Harness`): the installed copy at a harness version and an update at the next. It launches the
/// installed copy with `--relaunch-harness <folder> update-quit`, waits for it to quit and for the install script to open
/// the swapped app (a stub opener records the call), launches the swapped app with `after-update`, then with each later
/// step in turn (SelfTestRestoreLaunches: quits with and without the resume box, a request launch, crashes, restores that
/// do not finish, safe mode and a snapshot set aside), and reads the report every step wrote.
///
/// Each step launches as the app does, its launch hook included (AppDelegate hands it here after the hook, before plan
/// 005's self-test branch), counts as a
/// self-test for every guard but those pointed at the harness's folder: its defaults suite (the projects open at quit,
/// kept remote tabs, Settings › General), its sessions folder (the session the app saves, and its quit's last save) and
/// its MCP socket. Its shells read a zsh config of its own, which keeps their history in its folder. Its quits ask the
/// real questions, answered through their buttons, and its update is staged by the stand-in in `Updater`, installed by
/// the real script against paths in its folder. The update sheet's real "Update Now", with "Reopen windows and resume
/// sessions after the update" checked, gives the update consent, so the after-update launch is an update restore: its
/// windows, tabs, split and scrollback come back, and the command running at the quit waits on the prompt line. It ends
/// with a quit of its own, the plain quit dialog's box unchecked: under Welcome.
@MainActor
enum SelfTestRestore {
    /// Where a run keeps everything, and which step this process is.
    struct Harness: Sendable {
        static let argument = "--relaunch-harness"

        enum Step: String, Sendable {
            /// Stages the update stand-in, then quits through the update sheet's "Update Now".
            case updateQuit = "update-quit"
            /// The swapped app, launched again: checks what the quit and the install left, then quits under Welcome.
            case afterUpdate = "after-update"
            /// AE19's launch after that quit, then AE17's quit: the stand-in Claude Code runs, once more with an option it
            /// rejects on a resume, and the resume box is checked.
            case afterWelcomeQuit = "after-welcome-quit"
            /// AE17's quit restore, whose consent resumes the stand-in, and AE31's resume that fails at start, then AE18's
            /// quit with "Ask" off.
            case afterQuitChecked = "after-quit-checked"
            /// AE18's quit restore, which puts the stand-in's resume command on the line, then a logout.
            case afterQuitUnasked = "after-quit-unasked"
            /// AE21's request launch after the logout, then a crash once its restore has settled.
            case openRequest = "open-request"
            /// AE6's crash restore, then a crash before it settles: the first restore that does not finish.
            case afterCrash = "after-crash"
            /// A crash restore that crashes at once: the first restore that does not finish.
            case failOnce = "fail-once"
            /// A crash restore that crashes at once: the second restore that does not finish.
            case failAgain = "fail-again"
            /// Safe mode after two, answered "Try Again", then a crash: the third restore that does not finish.
            case safeModeTryAgain = "safe-mode-try-again"
            /// The snapshot set aside after three, then the stand-in again and a crash, for two more.
            case setAside = "set-aside"
            /// Safe mode again, answered "Keep As Is". The last step.
            case safeModeKeep = "safe-mode-keep"
        }

        let folder: URL
        let step: Step
        /// The stand-in Claude Code's own folder (`bin/claude`, the runs it notes in `runs`, and the home whose `.claude`
        /// store capture and the restore read for it), which the driver makes outside the temporary folders and names in
        /// `agent-folder`: the resume gate keeps an agent's code and store out of those. Nil when there is none.
        let agent: URL?

        /// `--relaunch-harness <folder> <step>`, with the folder a private one of this user's (the driver's `mktemp -d`).
        init?(arguments: [String]) {
            guard let index = arguments.firstIndex(of: Self.argument), index + 2 < arguments.count,
                  let step = Step(rawValue: arguments[index + 2]), arguments[index + 1].hasPrefix("/") else { return nil }
            let path = canonicalPath(arguments[index + 1])
            guard PrivateFolder.isPrivate(path) else { return nil }
            folder = URL(fileURLWithPath: path, isDirectory: true)
            self.step = step
            let named = (try? String(contentsOf: folder.appendingPathComponent("agent-folder"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let agentPath = named.flatMap { (path: String) -> String? in path.hasPrefix("/") ? canonicalPath(path) : nil }
            agent = agentPath.flatMap { (path: String) -> URL? in
                PrivateFolder.isPrivate(path) ? URL(fileURLWithPath: path, isDirectory: true) : nil
            }
        }

        /// The installed copy, which the install replaces.
        var install: URL { folder.appendingPathComponent("install/Next Term.app") }
        /// The update the stand-in stages: a copy at the next harness version.
        var update: URL { folder.appendingPathComponent("update/Next Term.app") }
        /// The new folder the stand-in stages the update in.
        var staging: URL { folder.appendingPathComponent("staging") }
        /// Opens nothing: records each call in `opened`.
        var opener: URL { folder.appendingPathComponent("bin/open") }
        var opened: URL { folder.appendingPathComponent("opened") }
        /// The project the first step opens, and the relaunch reopens.
        var project: URL { folder.appendingPathComponent("project") }
        var report: URL { folder.appendingPathComponent("report.txt") }
        /// What the first step read of the user's own state, for the second to compare.
        var realState: URL { folder.appendingPathComponent("real-state.json") }
        /// The secret the first step typed, for the second to look for: never in the report, which is searched for it too.
        var canary: URL { folder.appendingPathComponent("canary") }
        /// The zsh config the harness's shells read in place of the user's (`prepareShells`), and their history.
        var zdotdir: URL { folder.appendingPathComponent("zsh", isDirectory: true) }
        var history: URL { folder.appendingPathComponent("zsh_history") }
        /// The defaults suite, a file in the folder (`defaults.plist`).
        var defaultsSuite: String { folder.path + "/defaults" }
        /// Where the sessions folder is made: the harness's Application Support/Next Term.
        var stateFolder: URL { folder.appendingPathComponent("Application Support/Next Term", isDirectory: true) }
        /// The MCP socket, kept across the relaunch; none when the path is too long for a Unix socket.
        var mcpSocket: String? {
            let path = folder.path + "/mcp.sock"
            return path.utf8.count < 104 ? path : nil
        }
        /// The folder the request launch names (AE21).
        var api: URL { folder.appendingPathComponent("api", isDirectory: true) }
        /// The stand-in Claude Code: a program named claude that notes each run's arguments in `agentRuns`, then waits. A
        /// resume that carries `--permission-mode` exits at once with status 1, and so does any resume while `failPlain`
        /// is there (scripts/selftest.sh).
        var standIn: URL? { agent?.appendingPathComponent("bin/claude") }
        var agentRuns: URL? { agent?.appendingPathComponent("runs") }
        var failPlain: URL? { agent?.appendingPathComponent("fail-plain") }
        /// The home capture and the restore read agent stores in (`RestorePlanning.agentHome`), and its Claude store.
        var agentHome: URL? { agent?.appendingPathComponent("home", isDirectory: true) }
        var claudeStore: URL? { agentHome?.appendingPathComponent(".claude", isDirectory: true) }
    }

    nonisolated static let harness = Harness(arguments: CommandLine.arguments)
    /// Where capture and the restore read agent stores for the harness, in place of the user's home: its stand-in Claude
    /// Code's session is never in the user's own store (RestorePlanning.agentHome).
    nonisolated static let agentHome: String? = harness?.agentHome?.path
    /// The harness's own defaults suite: AppDelegate's `launchDefaults`, and where remote tabs are kept.
    nonisolated(unsafe) static let defaults: UserDefaults? = harness.flatMap { UserDefaults(suiteName: $0.defaultsSuite) }
    /// The reason the harness gives its quit; nil: the real one (the update sheet's consent gives `updateRelaunch`). Never
    /// `selfTest`, which only the plain self-test has.
    nonisolated(unsafe) static var quitReason: QuitReason?

    /// The user's own Next Term, whose defaults and folder in Application Support the harness must leave as they are.
    private static let realBundleID = CommandLineLink.bundleIdentifier
    private static var realSupportFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Next Term", isDirectory: true)
    }
    /// Written by the first step in its sessions folder, read back by the second.
    private static let probeName = "harness-probe"
    /// The defaults key plan 005's relaunch flag used, which the update's marker replaced: no quit or launch writes it.
    private static let oldRelaunchFlag = "updateRelaunchAt"

    private(set) static var failures = 0
    /// The canaries the first step typed: a line holding `secret`, and `plain`, which the quit's scrollback keeps.
    private static var canaries: (secret: String, plain: String)?
    /// The buttons to press, in turn, as the app-modal alert holding each shows.
    private static var presses: [String] = []
    private static var pressTimer: Timer?

    /// Before the launch opens any tab: the harness's shells read a zsh config of its own (`TerminalTab.testUserZDOTDIR`),
    /// which keeps their history in its folder, so the lines it types, the canaries among them, never reach the user's
    /// history file. `claude` in them is the stand-in, first on their path.
    static func prepareShells() {
        guard let harness else { return }
        try? FileManager.default.createDirectory(at: harness.zdotdir, withIntermediateDirectories: true)
        func quote(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var zshrc = "# The relaunch harness's own zsh config: its history stays in its folder.\nHISTFILE=\(quote(harness.history.path))\n"
        // A short prompt, as the build check's shells have: macOS's default names the user and the Mac, and a check's detail
        // quotes the line it ends.
        zshrc += "PROMPT='%1~ %# '\n"
        if let bin = harness.standIn?.deletingLastPathComponent() {
            zshrc += "# Its stand-in Claude Code comes first.\npath=(\(quote(bin.path)) $path)\n"
        }
        try? zshrc.write(to: harness.zdotdir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        TerminalTab.testUserZDOTDIR = harness.zdotdir.path
    }

    /// Runs this process's step, once the launch has shown what it shows: `restore` is what its launch hook restored. What
    /// must happen before the launch's restore can type or save anything, or under an alert the launch shows in a turn of
    /// its own, where the main queue waits, starts here, in the launch's own turn.
    static func run(restore: LaunchRestoreResult) {
        guard let harness else { return }
        // The stand-in's runs before this launch's restore could start it.
        let runs = standInRuns(harness)
        switch harness.step {
        case .failOnce: failRestore(attempt: 1)
        case .failAgain: failRestore(attempt: 2)
        case .safeModeTryAgain: answerSafeMode(harness, with: RestoreAlertText.tryAgain)
        case .safeModeKeep: answerSafeMode(harness, with: RestoreAlertText.keepAsIs)
        case .setAside: answerSetAside(harness)
        default: break
        }
        Task { @MainActor in
            switch harness.step {
            case .updateQuit: await updateQuit(harness, restore: restore)
            case .afterUpdate: await afterUpdate(harness, restore: restore)
            case .afterWelcomeQuit: await afterWelcomeQuit(harness, restore: restore)
            case .afterQuitChecked: await afterQuitChecked(harness, restore: restore, runs: runs)
            case .afterQuitUnasked: await afterQuitUnasked(harness, restore: restore, runs: runs)
            case .openRequest: await openRequest(harness, restore: restore, runs: runs)
            case .afterCrash: await afterCrash(harness, restore: restore, runs: runs)
            case .safeModeTryAgain: await afterTryAgain(harness, restore: restore, runs: runs)
            case .setAside: await afterSetAside(harness, restore: restore)
            case .safeModeKeep: await afterKeepAsIs(harness, restore: restore, runs: runs)
            case .failOnce, .failAgain: break
            }
        }
    }

    // MARK: the steps

    private static func updateQuit(_ harness: Harness, restore: LaunchRestoreResult) async {
        record("STEP update-quit, version \(Updater.shared.current?.description ?? "none")")
        try? JSONEncoder().encode(realState()).write(to: harness.realState)
        let app = AppDelegate.shared!
        let installed = Bundle.main.bundleURL.path == harness.install.path
        check(installed && restore == .notRun, "the harness launches the installed copy, with nothing to restore in its new folder",
              "\(Bundle.main.bundleURL.path), \(restore)")
        isolationChecks(harness)
        guard let files = sessionChecks(harness) else { return finish() }
        do {
            try files.replace(probeName, with: Data("update-quit \(getpid())".utf8))
        } catch {
            check(false, "the sessions folder takes a file", "\(error)")
        }

        // "Resume where I left off": the last quit's plain dialog starts checked, and the update's own box decides what the
        // relaunch brings back.
        if let defaults {
            var settings = LaunchSettings(defaults: defaults)
            settings.opens = .lastProjects
            settings.save(to: defaults)
        }

        // A project window with a command running, so the sheet has a busy tab to show.
        let controller = app.openFolder(harness.project.path, newWindow: false)
        guard let tab = controller.tabs.first, await SelfTest.wait(20, { tab.status.integrated }) else {
            check(false, "the project window's shell starts")
            return finish()
        }
        let opened = await saveChecks(harness, files: files, controller: controller, tab: tab)
        await canaryChecks(harness, tab: tab, split: opened.split)
        await captureChecks(harness, window: opened.other)
        tab.view.send(txt: "sleep 600\r")
        check(await SelfTest.wait(5) { tab.status.running }, "a command runs in the project window")

        // The stand-in update, staged as a download is.
        let version: AppVersion
        do {
            version = try await Updater.shared.stageStandIn(harness.update, in: harness.staging, replacing: harness.install,
                                                             opener: harness.opener)
        } catch {
            check(false, "the stand-in update is staged", (error as? Updater.UpdateError)?.text ?? error.localizedDescription)
            return finish()
        }
        let staged = Updater.shared.stagedApp?.path ?? ""
        let target = Updater.shared.installTarget
        let inside = [staged, target.app, target.open].allSatisfy { $0.hasPrefix(harness.folder.path + "/") }
        check(Updater.shared.badge == .relaunch(version) && inside,
              "the stand-in stages the update, to install and open only paths in the harness's folder",
              "staged \(staged), install \(target.app), open \(target.open)")

        // The quit, through the update sheet's real button, for the reason its consent gives. It ends as the app's does, so
        // the self-test's Copilot lock folder, which `finish` removes, goes as it ends.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated {
                let reason = AppDelegate.shared.quitReason
                check(reason == .updateRelaunch, "the update quit goes ahead as the update's relaunch", "\(reason)")
            }
            try? FileManager.default.removeItem(at: SelfTest.copilotLockFolder)
        }
        // An MCP client asks before the quit, and leaves a wait for the running command in flight across it.
        await mcpBeforeUpdateQuit(harness, busy: tab)
        Updater.shared.showAvailable()
        let sheet = UpdateKeepSessions.shared.flow
        let busy = sheet?.state == .busy && sheet?.keep == true && sheet?.waitSet == [tab.id]
        check(busy, "the update sheet shows the running command as busy and waited for, with the box checked",
              "\(String(describing: sheet?.state)), keep \(sheet?.keep ?? false), waited \(sheet?.waitSet.count ?? 0)")
        // AE13: every MCP tool once while the sheet is open, before its Update Now.
        await mcpWithUpdateSheet(harness)
        press([UpdateButton.updateNow.title])
        record("STEP update-quit: quitting")
        // The press quits the app; reached only when the quit did not go ahead.
        await SelfTest.pause(60)
        check(false, "the update quit goes ahead")
        finish()
    }

    private static func afterUpdate(_ harness: Harness, restore: LaunchRestoreResult) async {
        record("STEP after-update, version \(Updater.shared.current?.description ?? "none")")
        let app = AppDelegate.shared!
        isolationChecks(harness)

        // The install: the update runs from the installed copy's path, opened through the stub, and nothing is left.
        let updateVersion = Bundle(url: harness.update)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let swapped = Bundle.main.bundleURL.path == harness.install.path && Updater.shared.current?.description == updateVersion
        check(swapped, "the install put the update in place of the installed copy",
              "\(Bundle.main.bundleURL.path) at \(Updater.shared.current?.description ?? "none"), update \(updateVersion ?? "none")")
        let calls: [[String]] = openedCalls(harness)
        let opened: Bool = calls == [[harness.install.path]]
        check(opened, "the install opened the installed path once, through the harness's stub opener", "\(calls)")
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: harness.install.deletingLastPathComponent().path)) ?? []
        let leftovers = backups.filter { $0 != harness.install.lastPathComponent }
        let stagingGone = !FileManager.default.fileExists(atPath: harness.staging.path)
        check(stagingGone && leftovers.isEmpty, "the install removed its staging folder and the old copy's backup",
              "staging there \(!stagingGone), beside the app \(leftovers)")

        // The update sheet's Update Now was the button's press, and the update quit asked nothing more: no "Quitting
        // stops…", though a command ran (R16).
        let report = (try? String(contentsOf: harness.report, encoding: .utf8)) ?? ""
        let pressedUpdate = report.contains("pressed “Update Now”")
        let pressedQuit = report.contains("pressed “Quit”")
        check(pressedUpdate && !pressedQuit, "the update quit went ahead on the sheet's Update Now, with no Quitting stops alert",
              "Update Now \(pressedUpdate), Quit \(pressedQuit)")

        // The relaunch: the update restore brings the project's window back, with the other one, and no Welcome window.
        let windows = await SelfTest.wait(10) { !app.controllers.isEmpty }
        let welcome = app.welcomeController?.window?.isVisible == true
        let projects: [String] = app.controllers.compactMap(\.project)
        let reopened: Bool = projects == [harness.project.path]
        check(restore == .openedWindows && windows && reopened && !welcome,
              "the relaunch after the update brings back the project that was open, and no Welcome window",
              "\(restore), projects \(projects), Welcome \(welcome)")
        await restoreChecks(harness, restore: restore)
        await mcpAfterUpdate(harness)
        let saved: [String] = defaults?.stringArray(forKey: "sessionProjects") ?? []
        let remote = defaults?.data(forKey: "remoteTabs").map { String(decoding: $0, as: UTF8.self) } ?? "none"
        let noFlag = defaults?.object(forKey: oldRelaunchFlag) == nil
        let suiteFile = FileManager.default.fileExists(atPath: harness.defaultsSuite + ".plist")
        check(saved == [harness.project.path] && remote == "[]" && noFlag && suiteFile,
              "the projects open at quit and the kept remote tabs are in the harness's defaults, and no quit wrote the relaunch flag",
              "projects \(saved), remote tabs \(remote), no flag \(noFlag), suite file \(suiteFile)")

        // The sessions folder: the first step's lock went with its process, its file reads back, and its quit's last save
        // is what this launch found.
        if let files = sessionChecks(harness) {
            let probe = (try? files.read(probeName, maxSize: 1024)).flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) }
            check(probe?.hasPrefix("update-quit ") == true, "the file the first step wrote in the sessions folder reads back",
                  probe ?? "none")
            await quitSaveChecks(harness, files: files)
        }

        // Nothing outside the harness's folder changed: what only the harness could have put there, whoever else runs,
        // and the rest as the first step found it, unless the user's own Next Term ran meanwhile and changed it itself.
        leakChecks(harness)
        let before = (try? Data(contentsOf: harness.realState)).flatMap { try? JSONDecoder().decode(RealState.self, from: $0) }
        let after = realState()
        if let before {
            let names = Set(before.items.keys).union(after.items.keys)
            let changed: [String] = names.sorted().filter { before.items[$0] != after.items[$0] }
            if !before.running, !after.running {
                check(changed.isEmpty, "the user's own defaults, MCP socket and folder in Application Support are as they were",
                      "changed: \(changed)")
            } else if !changed.isEmpty {
                record("NOTE [after-update] your own Next Term ran meanwhile, so these changes may be its own: \(changed)")
            }
        } else {
            check(false, "the first step recorded the user's own state")
        }
        welcomeQuit()
    }

    // MARK: checks

    /// The harness counts as a self-test, with its defaults, MCP socket, zsh integration and quit reason its own.
    static func isolationChecks(_ harness: Harness) {
        let app = AppDelegate.shared!
        let ownDefaults = defaults != nil && app.launchDefaults === defaults && SelfTest.keptDefaults === defaults
        let socket = MCPControlServer.shared.path
        let ownSocket = harness.mcpSocket.map { $0 == socket } ?? !socket.hasPrefix(NSHomeDirectory() + "/Library/")
        let zsh = AppSupport.zshIntegrationDirectory?.path ?? "none"
        let ownConfig = TerminalTab.testUserZDOTDIR == harness.zdotdir.path
        let ownZsh = zsh.hasPrefix(harness.folder.path + "/") && ownConfig
        let reason = app.quitReason
        check(SelfTest.isRequested && SelfTest.mode == .relaunchHarness && reason != .selfTest,
              "the relaunch harness counts as a self-test, and never quits as the plain one", "quit reason \(reason)")
        check(ownDefaults && ownSocket && ownZsh,
              "the harness keeps its records, MCP socket, zsh integration, and its shells' config and history in its own folder",
              "defaults \(ownDefaults), socket \(socket), zsh integration \(zsh), own zsh config \(ownConfig)")
    }

    /// The harness's sessions folder, as the launch took it (SessionRestore): in its own folder, private, out of backups and
    /// Spotlight, with this copy's path recorded, and held by this process alone. Nil when it can't be used.
    static func sessionChecks(_ harness: Harness) -> SessionFiles? {
        guard let parent = SelfTest.sessionsParent, parent == harness.stateFolder else {
            check(false, "the harness makes its sessions folder in its own folder", SelfTest.sessionsParent?.path ?? "none")
            return nil
        }
        guard let files = SessionRestore.shared.files else {
            check(false, "the launch holds the harness's sessions folder")
            return nil
        }
        let locked = files.isOwner
        let second = try? SessionFiles.open(in: parent, bundlePath: Bundle.main.bundlePath)
        let alone = second?.lock() == false
        let inside = files.url.path.hasPrefix(harness.folder.path + "/") && files.url.pathExtension == "noindex"
        let excluded = (try? files.url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
        let recorded = SessionFiles.recordedBundlePath(in: files.url) == canonicalPath(Bundle.main.bundlePath)
        let isPrivate = PrivateFolder.isPrivate(files.url.path)
        check(locked && alone, "this process holds the sessions folder's lock, and a second holder is refused",
              "locked \(locked), second refused \(alone)")
        check(inside && isPrivate && excluded && recorded,
              "the sessions folder is in the harness's folder, private, out of backups and Spotlight, with this copy's path",
              "\(files.url.path), private \(isPrivate), excluded \(excluded), recorded \(recorded)")
        return locked ? files : nil
    }

    /// The periodic saves (KTD1): two windows, one with a split at 0.3, reach the state file within 3 seconds, and once it
    /// is steady a status-dot change alone writes nothing. Returns the split pane and the second window.
    private static func saveChecks(_ harness: Harness, files: SessionFiles, controller: TerminalWindowController,
                                   tab: TerminalTab) async -> (split: TerminalTab?, other: TerminalWindowController) {
        let other = AppDelegate.shared.openWindow(directory: harness.project.path)
        let pane = controller.split(vertical: true, from: tab, focus: false)
        // Its divider where a hand left it, for the restore to put back.
        if let group = controller.group(of: tab), case .split(let split) = group.root {
            split.dividers = [0.3]
            group.layout()
        }
        let split = { (window: SessionSnapshot.Window) -> Bool in
            window.groups.contains { (group: SessionSnapshot.Group) -> Bool in group.panes.count == 2 }
        }
        let saved = await SelfTest.wait(3) {
            guard let windows = SessionWriter.load(from: files)?.windows else { return false }
            return windows.count == 2 && windows.contains(where: split)
        }
        let found = SessionWriter.load(from: files)
        check(saved && found?.header.clean == false, "two windows, one with a split, are in the state file within 3 seconds, unclean",
              "windows \(found?.windows.count ?? 0), clean \(found?.header.clean ?? true)")

        // Steady: no save for a whole tick and more, the new pane's shell started.
        var generation = found?.header.generation
        for _ in 0..<5 {
            await SelfTest.pause(2.5)
            let now = SessionWriter.load(from: files)?.header.generation
            if now == generation { break }
            generation = now
        }
        tab.status.needsAttention()
        await SelfTest.pause(3)
        let after = SessionWriter.load(from: files)?.header.generation
        check(generation != nil && after == generation, "a status-dot change alone writes nothing",
              "generation \(generation ?? -1), then \(after ?? -1)")
        // Cleared as a look at the tab clears it: a hidden tab's mark outlasts the command it runs next, and the update's
        // save would report this tab's state before as attention, where the MCP check expects running.
        tab.status.setVisible(true)
        controller.refreshVisibility()
        check(SessionRestore.shared.lastSave?.succeeded == true && SessionRestore.shared.lastSave?.panesLeftOut.isEmpty == true,
              "the last save was written and leaves no pane out")
        return (pane, other)
    }

    /// The canaries: a line holding a secret, whose echo the scrollback a quit saves blanks, and a plain one it keeps. The
    /// secret line is also the split pane's last, so the quit saves that pane's record with it, unless the secret check
    /// drops it (R11). The secret goes in the harness's own file, never in the report, for the quit (`quitSaved`) and the
    /// relaunch to look for everywhere else; the plain line is looked for in the scrollback the quit saves, which proves
    /// the search finds what is there.
    private static func canaryChecks(_ harness: Harness, tab: TerminalTab, split: TerminalTab?) async {
        let secret = "nt-canary-" + UUID().uuidString.lowercased()
        let plain = "nt-plain-" + UUID().uuidString.lowercased()
        canaries = (secret, plain)
        try? Data(secret.utf8).write(to: harness.canary)
        let secretLine = "PGPASSWORD=\(secret) true"
        for line in [secretLine, "echo \(plain)"] {
            tab.view.send(txt: line + "\r")
            _ = await SelfTest.wait(5) { tab.status.command == line && !tab.status.running }
        }
        let text = SessionScrollback.capture(tab).text()
        let line = SessionCapture.command(tab)
        check(text.contains(plain) && !text.contains(secret), "the scrollback a quit saves keeps a plain line and blanks a secret one")
        check(line?.line == "echo \(plain)", "the last line is kept when it holds no secret", line?.line ?? "none")

        guard let split, await SelfTest.wait(20, { split.status.integrated }) else {
            return check(false, "the split pane's shell starts")
        }
        split.view.send(txt: secretLine + "\r")
        let ran = await SelfTest.wait(5) { split.status.command == secretLine && !split.status.running }
        let kept = SessionCapture.command(split)
        let verdict: String = kept.map { (command: SessionSnapshot.Command) -> String in "\(command.check)" } ?? "none"
        // Only the verdict goes in the report: a line kept by mistake would put the secret there.
        check(ran && kept?.check == .secret && kept?.line == nil, "the split pane's last line, which holds a secret, is not kept",
              "ran \(ran), verdict \(verdict)")
    }

    /// The quit's capture with 20 tabs (KTD18): the windows and each tab's scrollback, read as the quit reads them, take
    /// less than the time the quit allows that many tabs. The tabs open in the second window and stay for the quit.
    private static func captureChecks(_ harness: Harness, window: TerminalWindowController) async {
        let app = AppDelegate.shared!
        let missing = max(0, 20 - app.controllers.flatMap(\.tabs).count)
        var added: [TerminalTab] = []
        for _ in 0..<missing { added.append(window.addTab(directory: harness.project.path, select: false)) }
        let started = await SelfTest.wait(30) { added.allSatisfy { (tab: TerminalTab) -> Bool in tab.status.integrated } }
        let tabs: [TerminalTab] = app.controllers.flatMap(\.tabs)
        let budget = SessionWriter.quitBudget(tabs: tabs.count)
        let clock = Date()
        let read: [Int] = tabs.map { (tab: TerminalTab) -> Int in SessionScrollback.capture(tab).text().utf8.count }
        let windows = SessionCapture.windows(app.controllers)
        let took = Date().timeIntervalSince(clock)
        let timing = String(format: "read in %.2f s of %.1f s", took, budget)
        check(started && tabs.count >= 20 && read.count == tabs.count && took < budget,
              "the quit's capture of 20 tabs and their scrollback stays within the quit's budget",
              "\(tabs.count) tabs in \(windows.count) windows, shells started \(started), \(timing)")
    }

    /// What the update quit left, as this launch found it before it wrote anything: with the sheet's box checked, the whole
    /// session, unclean and waiting for the marker, with no consent id, the marker beside it, nothing else left behind, the
    /// scrollback named for its marker, read by this launch's update restore and removed, and the install's result, naming
    /// the marker, taken once. The secret typed before the quit is in no file the install left or
    /// the sessions folder holds now, in the harness's defaults, in the unified log or in the report; the quit's own files,
    /// its scrollback among them, were searched as it wrote them (`quitSaved`).
    private static func quitSaveChecks(_ harness: Harness, files: SessionFiles) async {
        let found = SessionRestore.shared.found
        let snapshot = found?.snapshot
        let names: [String] = found?.names ?? []
        let header = snapshot?.header
        let awaiting = header?.clean == false && header?.resumeConsent == nil && header?.awaitingMarker != nil
        let windows = snapshot?.windows.count ?? 0
        check(awaiting && windows == 2 && names.contains(UpdateMarker.fileName),
              "the update quit saved both windows, waiting for its marker, with no consent id, and wrote the marker",
              "clean \(header?.clean ?? true), consent \(header?.resumeConsent != nil), awaiting \(header?.awaitingMarker != nil), windows \(windows)")
        let lingering: [String] = names.filter { (name: String) -> Bool in
            name.hasPrefix(".") || name.hasSuffix(SessionFiles.previousSuffix)
        }
        check(lingering.isEmpty, "the quit left no previous file or temporary file", "\(lingering)")
        // An update quit names its scrollback for its marker, as the update restore reads it.
        let quit = header?.scrollbackQuit
        let quitScrollback = names.filter { (name: String) -> Bool in quit != nil && ScrollbackText.parseFileName(name)?.quit == quit }
        let left = ((try? files.names()) ?? []).filter { (name: String) -> Bool in name.hasPrefix(ScrollbackText.filePrefix) }
        check(!quitScrollback.isEmpty && left.isEmpty,
              "the quit saved scrollback named for its marker, and this launch's update restore read it and removed it",
              "saved \(quitScrollback.count), left \(left)")
        let result = found?.installResult
        let resultLeft = ((try? files.names()) ?? []).contains(InstallResult.fileName)
        check(result == InstallResult(outcome: .installed, marker: header?.awaitingMarker) && !resultLeft,
              "the install left its result in the sessions folder, naming the quit's marker, and the launch took it once",
              result.map { "\($0.outcome.rawValue), marker \($0.marker?.uuidString ?? "none"), left \(resultLeft)" } ?? "none")

        guard let secret = try? String(contentsOf: harness.canary, encoding: .utf8), !secret.isEmpty else {
            return check(false, "the first step typed its secret canary")
        }
        let folder = files.url
        let places: [URL] = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map(folder.appendingPathComponent)
            + [URL(fileURLWithPath: harness.defaultsSuite + ".plist"), harness.report]
        var holding = holders(of: secret, in: places)
        let log = await unifiedLog(harness)
        if let log, log.range(of: Data(secret.utf8)) != nil { holding.append("the unified log") }
        check(log != nil, "the unified log of the harness's copies of the app reads, to be searched")
        check(holding.isEmpty,
              "the secret typed before the quit is in no session file, in the harness's defaults, in the unified log or in the report",
              "\(holding)")
    }

    /// `text` with every blank left out.
    static func whole(_ text: String) -> String { text.replacingOccurrences(of: " ", with: "") }

    /// A tab's last 400 rows joined, with every blank left out: in a pane as narrow as the split's at 0.3 (about 28
    /// columns in the harness's window) a divider or a canary wraps over rows, and a row before a wrap loses its trailing
    /// blank, so a line looked for in rows joined by newlines would never be found, nor ever wrongly found.
    static func shownWhole(_ tab: TerminalTab?) -> String { whole(tab?.screenTail(400).joined() ?? "") }

    /// The update restore (plan 003's U10), as the after-update launch built it: every tab with the id it had, both windows,
    /// the split at 0.3, the scrollback above its divider, `sleep 600` (running at the quit) back on the prompt line and not
    /// run, the split pane whose line held a secret saying it was not kept and showing no part of it, no restored tab taken
    /// for reuse, and the restore done once each action ran.
    private static func restoreChecks(_ harness: Harness, restore: LaunchRestoreResult) async {
        let app = AppDelegate.shared!
        let sessions = SessionRestore.shared
        let decision = sessions.found?.decision
        let update = decision?.kind == .restore(.update) && decision?.quitConsent == false
        check(update && restore == .openedWindows,
              "the launch after the sheet's Update Now, its box checked, is an update restore",
              "\(String(describing: decision?.kind)), consent \(decision?.quitConsent ?? false), \(restore)")
        let saved = Set(sessions.found?.snapshot?.panes.map(\.id) ?? [])
        let open = Set(app.controllers.flatMap(\.tabs).map(\.id))
        check(!saved.isEmpty && saved == open, "every restored tab keeps the id it had", "saved \(saved.count), open \(open.count)")
        let window = app.controllers.first { $0.project == harness.project.path }
        let group = window?.groups.first
        var fractions: [CGFloat] = []
        if let group, case .split(let split) = group.root { fractions = split.dividers }
        let split = fractions.count == 1 && abs((fractions.first ?? 0) - 0.3) < 0.01
        check(app.controllers.count == 2 && split, "both windows come back, and a split left at 0.3 comes back at 0.3",
              "windows \(app.controllers.count), dividers \(fractions)")
        guard let first = group?.panes.first, let second = group?.panes.dropFirst().first else {
            return check(false, "the project window's split tab comes back with both panes")
        }
        // Applied once the line is written to the pty; zsh echoes it a few turns later, and in the narrow pane it wraps.
        let applied = await SelfTest.wait(20) { first.restoredRecord?.pending?.state == .applied }
        var line = ""
        let echoed = await SelfTest.wait(3) {
            line = SelfTest.lastLine(first)
            return line.hasSuffix("sleep 600")
        }
        check(applied && echoed && !first.status.running,
              "sleep 600, running at the quit, waits on the prompt line and does not run", "applied \(applied), line “\(line)”")
        let shown = shownWhole(first)
        check(first.restoreDivider != nil && shown.contains(whole(ScrollbackText.SavedAt.update.divider)),
              "the project tab shows the scrollback saved at the update, above its divider",
              "divider \(first.restoreDivider != nil), \(first.view.getTerminal().cols) columns")
        let secret = (try? String(contentsOf: harness.canary, encoding: .utf8)) ?? ""
        let noted = second.screenTail(40).joined(separator: "\n")
        let screens = app.controllers.flatMap(\.tabs).map { (tab: TerminalTab) -> String in shownWhole(tab) }
        let leaked = !secret.isEmpty && screens.contains { (screen: String) -> Bool in screen.contains(whole(secret)) }
        check(noted.contains("was not kept") && !secret.isEmpty && !leaked,
              "the split pane whose last line held a secret says it was not kept, and no tab shows the secret", "leaked \(leaked)")
        let tabs: [TerminalTab] = app.controllers.flatMap(\.tabs)
        let reusable = tabs.contains(where: \.isUntouched) || app.controllers.contains(where: \.isPristine)
        check(!reusable, "no restored tab is taken for reuse by nxtrm, ⌥⌘O or MCP new_tab")
        let done = await SelfTest.wait(30) { sessions.phase == .done }
        check(done, "every restored tab's action ran, or was dropped, and the restore is done", "\(sessions.phase)")
    }

    /// Of `places`, the names of those whose bytes hold `text`.
    private static func holders(of text: String, in places: [URL]) -> [String] {
        let needle = Data(text.utf8)
        let holding: [URL] = places.filter { (place: URL) -> Bool in
            FileManager.default.contents(atPath: place.path)?.range(of: needle) != nil
        }
        return holding.map(\.lastPathComponent)
    }

    /// What the unified log holds of the harness's copies of the app (the processes run from its folder) over the last 20
    /// minutes, as `log show` prints it; nil when it could not be read.
    private static func unifiedLog(_ harness: Harness) async -> Data? {
        let folder = harness.folder.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let predicate = "processImagePath BEGINSWITH \"\(folder)/\""
        let arguments = ["show", "--last", "20m", "--style", "compact", "--info", "--debug", "--predicate", predicate]
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
                process.arguments = arguments
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return continuation.resume(returning: nil) }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0 ? data : nil)
            }
        }
    }

    // MARK: the quits' last saves

    /// The quit's last save, as it left the sessions folder: AppDelegate hands it here once it is written, before the
    /// install starts and the tabs are terminated.
    static func quitSaved() {
        guard let harness else { return }
        switch harness.step {
        case .updateQuit:
            quitSaveSearch()
            recordStepEnd()
        case .afterUpdate: welcomeQuitChecks()
        case .afterWelcomeQuit: checkedQuitSaved(harness)
        case .afterQuitChecked: unaskedQuitSaved(harness)
        case .afterQuitUnasked: logoutQuitSaved(harness)
        case .openRequest, .afterCrash, .failOnce, .failAgain, .safeModeTryAgain, .setAside, .safeModeKeep:
            check(false, "this step ends without a quit")
            recordStepEnd()
        }
    }

    /// The update quit's files, as it wrote them: the scrollback it saved holds the plain canary, and no file holds the
    /// secret one: the state file, the marker, and the scrollback, which the relaunch removes unread.
    private static func quitSaveSearch() {
        guard let files = SessionRestore.shared.files, let canaries else {
            return check(false, "the update quit's last save is searched for the canaries")
        }
        let own: Set<String> = [SessionFiles.lockName, SessionFiles.appPathName]
        let names: [String] = ((try? files.names()) ?? []).filter { (name: String) -> Bool in !own.contains(name) }
        let saved: [URL] = names.map { (name: String) -> URL in files.url.appendingPathComponent(name) }
        let scrollback: [URL] = saved.filter { (file: URL) -> Bool in file.lastPathComponent.hasPrefix(ScrollbackText.filePrefix) }
        let plain = holders(of: canaries.plain, in: scrollback)
        let secret = holders(of: canaries.secret, in: saved)
        check(!plain.isEmpty, "the scrollback the update quit saved holds the plain line: the search finds what is there",
              "\(scrollback.count) scrollback files")
        check(secret.isEmpty, "the secret typed before the quit is in no file its last save left, its scrollback included", "\(secret)")
    }

    /// The last quit, the user's own: the plain quit dialog's box, checked under Resume, unchecked, then its "Quit", sets
    /// "Show the Welcome window", and the quit's last save, which reads the setting once the answer is saved, is the
    /// tombstone (`welcomeQuitChecks`). First, with the dialog open, every MCP tool once (AE13); should those calls not
    /// get to run under the dialog, the answer goes after two minutes all the same, and their check fails.
    private static func welcomeQuit() {
        record("STEP after-update: quitting under Welcome")
        Task { @MainActor in
            if let harness { await mcpWithQuitDialog(harness) }
            answerQuit()
        }
        let fallback = Timer(timeInterval: 120, repeats: false) { _ in
            MainActor.assumeIsolated { answerQuit() }
        }
        RunLoop.main.add(fallback, forMode: .common)
        NSApp.terminate(nil)
        // Reached only when the quit was cancelled.
        check(false, "the quit under Welcome goes ahead")
        finish()
    }

    /// The quit dialog's answer is queued.
    private static var quitAnswered = false

    /// The user's answer to the plain quit dialog, once: the box unchecked, then "Quit".
    private static func answerQuit() {
        guard !quitAnswered else { return }
        quitAnswered = true
        press([QuitPolicy.checkboxTitle, QuitPromptButton.quit.title])
    }

    /// What the quit under Welcome left: the answer saved, and in the sessions folder the tombstone alone, clean, with no
    /// window, consent id or marker, and no previous file, temporary file, scrollback or marker beside it. Then the step's
    /// last line: the app's own quit ends the process.
    private static func welcomeQuitChecks() {
        let opens = defaults.map { (suite: UserDefaults) -> LaunchOpens in LaunchSettings(defaults: suite).opens }
        if let files = SessionRestore.shared.files {
            let snapshot = SessionWriter.load(from: files)
            let header = snapshot?.header
            let clean = header?.clean == true
            let empty = snapshot?.windows.isEmpty == true
            let nothingElse = header?.resumeConsent == nil && header?.awaitingMarker == nil
            let names: [String] = (try? files.names()) ?? []
            let lingering: [String] = names.filter { (name: String) -> Bool in
                let left = name.hasPrefix(".") || name.hasSuffix(SessionFiles.previousSuffix) || name == UpdateMarker.fileName
                return left || name.hasPrefix(ScrollbackText.filePrefix)
            }
            check(opens == .welcome && clean && empty && nothingElse && lingering.isEmpty,
                  "the quit under Welcome, the user's answer, leaves only the tombstone",
                  "Welcome saved \(opens == .welcome), clean \(clean), no windows \(empty), left \(lingering)")
        } else {
            check(false, "the quit under Welcome holds the sessions folder")
        }
        recordStepEnd()
        try? FileManager.default.removeItem(at: SelfTest.copilotLockFolder)
    }

    /// What the harness must leave as it is outside its folder, as one step found it.
    private struct RealState: Codable {
        /// Whether the user's own Next Term ran, which changes some of it itself.
        var running: Bool
        /// Each thing, by name: as `describe` or `identity` puts it.
        var items: [String: String]
    }

    /// The user's own Next Term's defaults (the keys a launch and a quit write, and Settings › General), and what is in its
    /// folder in Application Support: its MCP socket, its zsh integration and the rest.
    private static func realState() -> RealState {
        var items: [String: String] = [:]
        let keys = ["sessionProjects", "remoteTabs", oldRelaunchFlag] + LaunchSettings.Key.all
        for key in keys {
            items["defaults " + key] = describe(CFPreferencesCopyAppValue(key as CFString, realBundleID as CFString))
        }
        let folder = realSupportFolder
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            items["Application Support " + name] = identity(folder.appendingPathComponent(name).path)
        }
        items["zsh integration"] = identity(folder.appendingPathComponent("shell/zsh/.zshenv").path)
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: realBundleID).isEmpty
        return RealState(running: running, items: items)
    }

    /// What only the harness could have put in the user's own state, whoever else runs: a value in the user's Next Term
    /// defaults that names the harness's folder, or a sessions folder for this copy in the user's Application Support.
    static func leakChecks(_ harness: Harness) {
        let domain = UserDefaults.standard.persistentDomain(forName: realBundleID) ?? [:]
        // JSON (kept remote tabs) writes each slash as `\/`.
        let paths = [harness.folder.path, harness.folder.path.replacingOccurrences(of: "/", with: "\\/")]
        let naming: [String] = domain.keys.sorted().filter { key in
            let text = describeText(domain[key])
            return paths.contains { text.contains($0) }
        }
        let key = SessionFiles.key(forBundlePath: Bundle.main.bundlePath)
        let sessions = realSupportFolder.appendingPathComponent(SessionFiles.folderName(key: key)).path
        let noSessions = identity(sessions) == "none"
        check(naming.isEmpty && noSessions, "nothing in the user's own defaults or Application Support is the harness's",
              "defaults naming its folder \(naming), \(sessions) there \(!noSessions)")
    }

    /// A value as text, data as UTF-8: what a path in it would read as.
    private static func describeText(_ value: Any?) -> String {
        guard let data = value as? Data else { return describe(value) }
        return String(decoding: data, as: UTF8.self)
    }

    private static func describe(_ value: Any?) -> String {
        switch value {
        case nil: return "none"
        case let data as Data: return data.base64EncodedString()
        case let date as Date: return String(date.timeIntervalSince1970)
        case let some?: return String(describing: some)
        }
    }

    /// What is at `path` (never followed), by device, inode and change time; "none" when nothing is.
    private static func identity(_ path: String) -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else { return "none" }
        return "\(info.st_dev):\(info.st_ino):\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
    }

    /// Each call the stub opener recorded, as its arguments: each ends in a NUL, each call in a record separator.
    private static func openedCalls(_ harness: Harness) -> [[String]] {
        guard let data = FileManager.default.contents(atPath: harness.opened.path) else { return [] }
        let calls = String(decoding: data, as: UTF8.self).split(separator: "\u{1E}")
        return calls.map { call in call.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init) }
    }

    // MARK: pressing buttons

    /// Presses each button in `titles` in turn, once an app-modal alert, or the update sheet, shows it: a click, as the
    /// user's. Each press is in the report before it happens, since the process may quit right after. Gives up after 60
    /// seconds.
    static func press(_ titles: [String]) {
        presses = titles
        let started = Date()
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { pressNext(startedAt: started) }
        }
        // The common modes include the modal panel's, so it fires while an alert runs.
        RunLoop.main.add(timer, forMode: .common)
        pressTimer = timer
    }

    private static func pressNext(startedAt started: Date) {
        guard let title = presses.first else {
            pressTimer?.invalidate()
            return
        }
        if Date().timeIntervalSince(started) > 60 {
            check(false, "an alert shows “\(title)”")
            presses = []
            return
        }
        guard let window = NSApp.modalWindow ?? UpdateKeepSessions.shared.sheet?.window, let content = window.contentView,
              let button = buttons(in: content).first(where: { $0.title == title }) else { return }
        presses.removeFirst()
        record("PASS [\(harness?.step.rawValue ?? "")] pressed “\(title)”")
        button.performClick(nil)
    }

    static func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons(in: $0) }
    }

    // MARK: the report

    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if !ok { failures += 1 }
        let text = detail()
        let step = harness?.step.rawValue ?? ""
        record("\(ok ? "PASS" : "FAIL") [\(step)] \(name)\(ok || text.isEmpty ? "" : " — \(text)")")
    }

    /// One line, appended to the report as it happens: a step that quits or is stopped still says how far it got.
    static func record(_ line: String) {
        guard let path = harness?.report.path else { return }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
    }

    /// The step's last line, which the driver looks for: whether every check of this process passed.
    static func recordStepEnd() {
        let step = harness?.step.rawValue ?? ""
        record(failures == 0 ? "STEP \(step) PASSED" : "STEP \(step) \(failures) FAILED")
    }

    /// Ends a step that does not quit: its last line, then the servers that leave files behind, then the process.
    static func finish() {
        recordStepEnd()
        ClaudeIDEServer.shared.stop()
        CopilotIDEServer.shared.stop()
        MCPControlServer.shared.stop()
        try? FileManager.default.removeItem(at: SelfTest.copilotLockFolder)
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
