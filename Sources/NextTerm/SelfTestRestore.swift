#if DEBUG
import AppKit
import NextTermCore

/// The relaunch harness, in debug builds only: a real quit and relaunch of a throwaway copy of the app, without the
/// release key. `scripts/selftest.sh --relaunch` wraps the debug binary in two app bundles signed ad hoc, in a private
/// folder of its own (`Harness`): the installed copy at a harness version and an update at the next. It launches the
/// installed copy with `--relaunch-harness <folder> update-quit`, waits for it to quit and for the install script to open
/// the swapped app (a stub opener records the call), launches the swapped app with `after-update`, and reads the report
/// both steps wrote.
///
/// Each step launches as the app does (AppDelegate hands it here before plan 005's self-test branch), counts as a
/// self-test for every guard but those pointed at the harness's folder: its defaults suite (the projects open at quit,
/// kept remote tabs, Settings › General), its sessions folder (the session the app saves, and its quit's last save) and
/// its MCP socket. Its quit asks the real questions, answered through their buttons, and its update is staged by the
/// stand-in in `Updater`, installed by the real script against paths in its folder.
@MainActor
enum SelfTestRestore {
    /// Where a run keeps everything, and which step this process is.
    struct Harness: Sendable {
        static let argument = "--relaunch-harness"

        enum Step: String, Sendable {
            /// Stages the update stand-in, then quits through "Relaunch Now", answering the quit's question.
            case updateQuit = "update-quit"
            /// The swapped app, launched again: checks what the quit and the install left.
            case afterUpdate = "after-update"
        }

        let folder: URL
        let step: Step

        /// `--relaunch-harness <folder> <step>`, with the folder a private one of this user's (the driver's `mktemp -d`).
        init?(arguments: [String]) {
            guard let index = arguments.firstIndex(of: Self.argument), index + 2 < arguments.count,
                  let step = Step(rawValue: arguments[index + 2]), arguments[index + 1].hasPrefix("/") else { return nil }
            let path = canonicalPath(arguments[index + 1])
            guard PrivateFolder.isPrivate(path) else { return nil }
            folder = URL(fileURLWithPath: path, isDirectory: true)
            self.step = step
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
        /// The defaults suite, a file in the folder (`defaults.plist`).
        var defaultsSuite: String { folder.path + "/defaults" }
        /// Where the sessions folder is made: the harness's Application Support/Next Term.
        var stateFolder: URL { folder.appendingPathComponent("Application Support/Next Term", isDirectory: true) }
        /// The MCP socket, kept across the relaunch; none when the path is too long for a Unix socket.
        var mcpSocket: String? {
            let path = folder.path + "/mcp.sock"
            return path.utf8.count < 104 ? path : nil
        }
    }

    nonisolated static let harness = Harness(arguments: CommandLine.arguments)
    /// The harness's own defaults suite: AppDelegate's `launchDefaults`, and where remote tabs are kept.
    nonisolated(unsafe) static let defaults: UserDefaults? = harness.flatMap { UserDefaults(suiteName: $0.defaultsSuite) }
    /// The reason the harness gives its quit; nil: the real one ("Relaunch Now" gives `updateRelaunch`). Never `selfTest`,
    /// which only the plain self-test has.
    nonisolated(unsafe) static var quitReason: QuitReason?

    /// The user's own Next Term, whose defaults and folder in Application Support the harness must leave as they are.
    private static let realBundleID = CommandLineLink.bundleIdentifier
    private static var realSupportFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Next Term", isDirectory: true)
    }
    /// Written by the first step in its sessions folder, read back by the second.
    private static let probeName = "harness-probe"

    private static var failures = 0
    /// The buttons to press, in turn, as the app-modal alert holding each shows.
    private static var presses: [String] = []
    private static var pressTimer: Timer?

    /// Runs this process's step, once the launch has shown what it shows.
    static func run(launchKind: LaunchKind) {
        guard let harness else { return }
        Task { @MainActor in
            switch harness.step {
            case .updateQuit: await updateQuit(harness, launchKind: launchKind)
            case .afterUpdate: await afterUpdate(harness, launchKind: launchKind)
            }
        }
    }

    // MARK: the steps

    private static func updateQuit(_ harness: Harness, launchKind: LaunchKind) async {
        record("STEP update-quit, version \(Updater.shared.current?.description ?? "none")")
        try? JSONEncoder().encode(realState()).write(to: harness.realState)
        let app = AppDelegate.shared!
        let installed = Bundle.main.bundleURL.path == harness.install.path
        check(installed && launchKind == .normal, "the harness launches the installed copy as a normal launch",
              "\(Bundle.main.bundleURL.path), \(launchKind)")
        isolationChecks(harness)
        guard let files = sessionChecks(harness) else { return finish() }
        do {
            try files.replace(probeName, with: Data("update-quit \(getpid())".utf8))
        } catch {
            check(false, "the sessions folder takes a file", "\(error)")
        }

        // "Resume where I left off": the quit, which asks nothing about it, saves the whole session, and the relaunch
        // reopens the project.
        if let defaults {
            var settings = LaunchSettings(defaults: defaults)
            settings.opens = .lastProjects
            settings.save(to: defaults)
        }

        // A project window with a command running, so the quit has a question to ask.
        let controller = app.openFolder(harness.project.path, newWindow: false)
        guard let tab = controller.tabs.first, await SelfTest.wait(20, { tab.status.integrated }) else {
            check(false, "the project window's shell starts")
            return finish()
        }
        await saveChecks(harness, files: files, controller: controller, tab: tab)
        await canaryChecks(harness, tab: tab)
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

        // The quit, through the real button and the real question, for the reason "Relaunch Now" gives. It ends as the
        // app's does, so the self-test's Copilot lock folder, which `finish` removes, goes as it ends.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated {
                let reason = AppDelegate.shared.quitReason
                check(reason == .updateRelaunch, "the update quit goes ahead as the update's relaunch", "\(reason)")
            }
            try? FileManager.default.removeItem(at: SelfTest.copilotLockFolder)
        }
        press(["Relaunch Now", "Quit"])
        record("STEP update-quit: quitting")
        Updater.shared.showAvailable()
        // Reached only when the quit was cancelled.
        check(false, "the update quit goes ahead")
        finish()
    }

    private static func afterUpdate(_ harness: Harness, launchKind: LaunchKind) async {
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

        // The quit asked its question, and the harness answered both through their buttons.
        let report = (try? String(contentsOf: harness.report, encoding: .utf8)) ?? ""
        let pressedRelaunch = report.contains("pressed “Relaunch Now”")
        let pressedQuit = report.contains("pressed “Quit”")
        check(pressedRelaunch && pressedQuit, "the update quit asked “Quitting stops…”, and both presses were the buttons'",
              "Relaunch Now \(pressedRelaunch), Quit \(pressedQuit)")

        // The relaunch, a normal launch under "Resume where I left off": the projects open at quit, from the harness's
        // defaults; their window and no Welcome.
        let windows = await SelfTest.wait(10) { !app.controllers.isEmpty }
        let welcome = app.welcomeController?.window?.isVisible == true
        let projects: [String] = app.controllers.compactMap(\.project)
        let reopened: Bool = projects == [harness.project.path]
        check(launchKind == .normal && windows && reopened && !welcome,
              "the relaunch after the update opens the project that was open, and no Welcome window",
              "\(launchKind), projects \(projects), Welcome \(welcome)")
        let saved: [String] = defaults?.stringArray(forKey: "sessionProjects") ?? []
        let remote = defaults?.data(forKey: "remoteTabs").map { String(decoding: $0, as: UTF8.self) } ?? "none"
        let noFlag = defaults?.object(forKey: Updater.relaunchFlagKey) == nil
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
            quitSaveChecks(harness, files: files)
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
        finish()
    }

    // MARK: checks

    /// The harness counts as a self-test, with its defaults, MCP socket, zsh integration and quit reason its own.
    private static func isolationChecks(_ harness: Harness) {
        let app = AppDelegate.shared!
        let ownDefaults = defaults != nil && app.launchDefaults === defaults && SelfTest.keptDefaults === defaults
        let socket = MCPControlServer.shared.path
        let ownSocket = harness.mcpSocket.map { $0 == socket } ?? !socket.hasPrefix(NSHomeDirectory() + "/Library/")
        let zsh = AppSupport.zshIntegrationDirectory?.path ?? "none"
        let ownZsh = zsh.hasPrefix(harness.folder.path + "/")
        let reason = app.quitReason
        check(SelfTest.isRequested && SelfTest.mode == .relaunchHarness && reason != .selfTest,
              "the relaunch harness counts as a self-test, and never quits as the plain one", "quit reason \(reason)")
        check(ownDefaults && ownSocket && ownZsh, "the harness keeps its records, MCP socket and zsh integration in its own folder",
              "defaults \(ownDefaults), socket \(socket), zsh integration \(zsh)")
    }

    /// The harness's sessions folder, as the launch took it (SessionRestore): in its own folder, private, out of backups and
    /// Spotlight, with this copy's path recorded, and held by this process alone. Nil when it can't be used.
    private static func sessionChecks(_ harness: Harness) -> SessionFiles? {
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

    /// The periodic saves (KTD1): two windows, one with a split, reach the state file within 3 seconds, and once it is
    /// steady a status-dot change alone writes nothing.
    private static func saveChecks(_ harness: Harness, files: SessionFiles, controller: TerminalWindowController,
                                   tab: TerminalTab) async {
        AppDelegate.shared.openWindow(directory: harness.project.path)
        controller.split(vertical: true, from: tab, focus: false)
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
        check(SessionRestore.shared.lastSave?.succeeded == true && SessionRestore.shared.lastSave?.panesLeftOut.isEmpty == true,
              "the last save was written and leaves no pane out")
    }

    /// The canaries: a line holding a secret, whose echo the scrollback a quit saves blanks, and a plain one it keeps. The
    /// secret goes in the harness's own file, never in the report, for the relaunch to look for everywhere else.
    private static func canaryChecks(_ harness: Harness, tab: TerminalTab) async {
        let secret = "nt-canary-" + UUID().uuidString.lowercased()
        let plain = "nt-plain-" + UUID().uuidString.lowercased()
        try? Data(secret.utf8).write(to: harness.canary)
        for line in ["PGPASSWORD=\(secret) true", "echo \(plain)"] {
            tab.view.send(txt: line + "\r")
            _ = await SelfTest.wait(5) { tab.status.command == line && !tab.status.running }
        }
        let text = SessionScrollback.capture(tab).text()
        let line = SessionCapture.command(tab)
        check(text.contains(plain) && !text.contains(secret), "the scrollback a quit saves keeps a plain line and blanks a secret one")
        check(line?.line == "echo \(plain)", "the last line is kept when it holds no secret", line?.line ?? "none")
    }

    /// What the update quit left, as this launch found it before it wrote anything: under "Resume where I left off", with no
    /// quit consent ("Relaunch Now" asks nothing that could give it), the whole session marked clean with no consent id
    /// and no marker, nothing left behind, the scrollback named for its session and removed unread by this launch, which
    /// restores nothing, and the install's result. The secret typed before the quit is in no file it left, in the
    /// harness's defaults or in the report.
    private static func quitSaveChecks(_ harness: Harness, files: SessionFiles) {
        let found = SessionRestore.shared.found
        let snapshot = found?.snapshot
        let names: [String] = found?.names ?? []
        let header = snapshot?.header
        let clean = header?.clean == true && header?.resumeConsent == nil && header?.awaitingMarker == nil
        let windows = snapshot?.windows.count ?? 0
        check(clean && windows == 2, "the update quit under Resume saved both windows, clean, with no consent id and no marker",
              "clean \(header?.clean ?? false), consent \(header?.resumeConsent != nil), windows \(windows)")
        let lingering: [String] = names.filter { (name: String) -> Bool in
            name.hasPrefix(".") || name.hasSuffix(SessionFiles.previousSuffix) || name == UpdateMarker.fileName
        }
        check(lingering.isEmpty, "the quit left no previous file, temporary file or marker", "\(lingering)")
        let launch = header?.launchID
        let quitScrollback = names.filter { (name: String) -> Bool in ScrollbackText.parseFileName(name)?.quit == launch }
        let left = ((try? files.names()) ?? []).filter { (name: String) -> Bool in name.hasPrefix(ScrollbackText.filePrefix) }
        check(!quitScrollback.isEmpty && left.isEmpty,
              "the quit saved scrollback named for its session, and this launch, which restores nothing, removed it unread",
              "saved \(quitScrollback.count), left \(left)")
        let data = (try? files.read(InstallResult.fileName, maxSize: InstallResult.maxSize)) ?? nil
        let result = data.flatMap(InstallResult.parse)
        check(result == InstallResult(outcome: .installed, marker: nil), "the install left its result in the sessions folder, naming no marker",
              result.map { "\($0.outcome.rawValue), marker \($0.marker?.uuidString ?? "none")" } ?? "none")

        guard let secret = try? String(contentsOf: harness.canary, encoding: .utf8), !secret.isEmpty else {
            return check(false, "the first step typed its secret canary")
        }
        let folder = files.url
        var holders: [String] = []
        let places: [URL] = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map(folder.appendingPathComponent)
            + [URL(fileURLWithPath: harness.defaultsSuite + ".plist"), harness.report]
        for place in places {
            guard let contents = FileManager.default.contents(atPath: place.path) else { continue }
            if contents.range(of: Data(secret.utf8)) != nil { holders.append(place.lastPathComponent) }
        }
        check(holders.isEmpty, "the secret typed before the quit is in no session file, in the harness's defaults or in the report",
              "\(holders)")
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
        let keys = ["sessionProjects", "remoteTabs", Updater.relaunchFlagKey] + LaunchSettings.Key.all
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
    private static func leakChecks(_ harness: Harness) {
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

    /// Presses each button in `titles` in turn, once an app-modal alert shows it: a click, as the user's. Each press is
    /// in the report before it happens, since the process may quit right after. Gives up after 60 seconds.
    private static func press(_ titles: [String]) {
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
        guard let window = NSApp.modalWindow, let content = window.contentView,
              let button = buttons(in: content).first(where: { $0.title == title }) else { return }
        presses.removeFirst()
        record("PASS [\(harness?.step.rawValue ?? "")] pressed “\(title)”")
        button.performClick(nil)
    }

    private static func buttons(in view: NSView) -> [NSButton] {
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
    private static func record(_ line: String) {
        guard let path = harness?.report.path else { return }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
    }

    /// Ends a step that does not quit: its last line, then the servers that leave files behind, then the process.
    private static func finish() {
        let step = harness?.step.rawValue ?? ""
        record(failures == 0 ? "STEP \(step) PASSED" : "STEP \(step) \(failures) FAILED")
        ClaudeIDEServer.shared.stop()
        CopilotIDEServer.shared.stop()
        MCPControlServer.shared.stop()
        try? FileManager.default.removeItem(at: SelfTest.copilotLockFolder)
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
