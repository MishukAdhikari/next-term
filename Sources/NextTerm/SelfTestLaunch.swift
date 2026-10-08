import AppKit
import NextTermCore

/// What a launch shows, and a Dock click with every window closed: the Welcome window, or the projects Settings ›
/// General says to reopen (LaunchDecision). Kept remote tabs wait for the first terminal window, and the relaunch
/// after "Relaunch Now" is told by the flag the quit before it leaves.
extension SelfTest {
    /// First of all: the self-test launches as a normal launch does, with the Welcome window whatever is saved, and
    /// then opens its window as New Terminal does, for every check after this one.
    static func launchChecks() async {
        let app = AppDelegate.shared!
        let welcome = await wait(5) { app.welcomeController?.window?.isVisible == true }
        check(welcome && app.controllers.isEmpty, "a launch that names nothing shows the Welcome window, and no terminal window",
              "Welcome \(welcome), terminal windows \(app.controllers.count)")
        check(app.remoteRestorePending, "kept remote tabs wait for the first terminal window, rather than opening one under the Welcome window")
        relaunchFlagChecks()
        app.newWindow(nil)
        let closed = await wait(5) { app.welcomeController?.window?.isVisible != true }
        check(closed && app.controllers.count == 1 && !app.remoteRestorePending,
              "New Terminal closes the Welcome window, and the kept remote tabs' restore starts once its window is open",
              "Welcome closed \(closed), windows \(app.controllers.count), still waiting \(app.remoteRestorePending)")
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
        let keys = LaunchSettings.Key.all
        let saved = keys.map { defaults.object(forKey: $0) }
        let savedRecents = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
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
    }
}
