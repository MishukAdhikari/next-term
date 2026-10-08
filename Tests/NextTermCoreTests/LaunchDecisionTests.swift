import Foundation
import Testing
@testable import NextTermCore

@Suite struct LaunchSettingsTests {
    @Test func defaults() {
        let s = LaunchSettings()
        #expect(s.opens == LaunchOpens.welcome)
        #expect(s.askToReopenOnQuit)
        // In the order of the radio buttons. Compared outside `#expect`, where arrays are slow to type-check.
        let titles: [String] = LaunchOpens.allCases.map(\.title)
        let expected: [String] = ["Show the Welcome window", "Reopen the projects that were open"]
        let same: Bool = titles == expected
        #expect(same, "\(titles)")
    }

    @Test func readAndSavedInTheDefaults() throws {
        let name = "nextterm-launch-settings-tests-\(getpid())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        // Never set, for a new user and for one updating into this release: the Welcome window, and Ask on.
        #expect(LaunchSettings(defaults: defaults) == LaunchSettings())
        var changed = LaunchSettings()
        changed.opens = .lastProjects
        changed.askToReopenOnQuit = false
        changed.save(to: defaults)
        let opens: String? = defaults.string(forKey: LaunchSettings.Key.opens)
        let ask: Bool? = defaults.object(forKey: LaunchSettings.Key.askToReopenOnQuit) as? Bool
        #expect(opens == "lastProjects")
        #expect(ask == false)
        #expect(LaunchSettings(defaults: defaults) == changed)
        LaunchSettings().save(to: defaults)
        let reset: String? = defaults.string(forKey: LaunchSettings.Key.opens)
        #expect(reset == "welcome")
        #expect(LaunchSettings(defaults: defaults) == LaunchSettings())
        // Something that is not one of the choices reads as the default.
        defaults.set("everything", forKey: LaunchSettings.Key.opens)
        defaults.set("sometimes", forKey: LaunchSettings.Key.askToReopenOnQuit)
        #expect(LaunchSettings(defaults: defaults) == LaunchSettings())
        #expect(Set(LaunchSettings.Key.all).count == 2)
    }
}

/// The launch table, with made-up folders and a made-up disk: `exists` is told which folders are there.
@Suite struct LaunchDecisionTests {
    let app = "/Users/x/Code/app"
    let api = "/Users/x/Code/api"
    let web = "/Users/x/Code/web"

    /// Nothing open yet, `app` and `api` open at the last quit, `api` opened most recently.
    func input(_ kind: LaunchKind, _ opens: LaunchOpens = .welcome) -> LaunchInput {
        var settings = LaunchSettings()
        settings.opens = opens
        return LaunchInput(kind: kind, restore: .notRun, terminalWindowOpen: false, settings: settings,
                           sessionProjects: [app, api], recentProjects: [api, app, web], mayOfferImport: false)
    }

    /// What the launch shows, with only `existing` on disk (every made-up folder when not given).
    func decide(_ input: LaunchInput, existing: Set<String>? = nil) -> LaunchOpening {
        let onDisk: Set<String> = existing ?? [app, api, web]
        return LaunchDecision.opening(input) { (path: String) -> Bool in onDisk.contains(path) }
    }

    /// Row 1: a terminal window is open already, so the launch adds nothing, whatever else is true.
    @Test(arguments: LaunchKind.allCases) func aTerminalWindowOpenShowsNothingMore(_ kind: LaunchKind) {
        for restore in LaunchRestoreResult.allCases {
            for opens in LaunchOpens.allCases {
                for mayOfferImport in [false, true] {
                    var launch = input(kind, opens)
                    launch.restore = restore
                    launch.terminalWindowOpen = true
                    launch.mayOfferImport = mayOfferImport
                    #expect(decide(launch) == .nothing, "\(kind), \(restore), \(opens), import \(mayOfferImport)")
                }
            }
        }
    }

    @Test func aNormalLaunchShowsTheWelcomeWindowByDefault() {
        // AE1: the projects from the last quit are there, and only listed.
        #expect(decide(input(.normal)) == .welcome)
        #expect(decide(input(.normal, .welcome), existing: []) == .welcome)
    }

    @Test func reopenBringsBackTheProjectsOpenAtTheLastQuitThatStillExist() {
        // AE4.
        #expect(decide(input(.normal, .lastProjects)) == .reopen([app, api]))
        #expect(decide(input(.normal, .lastProjects), existing: [app, web]) == .reopen([app]))
        #expect(decide(input(.normal, .lastProjects), existing: [web]) == .welcome)
        // No project open at the last quit: the Welcome window, never the most recent project.
        var none = input(.normal, .lastProjects)
        none.sessionProjects = []
        #expect(decide(none) == .welcome)
    }

    @Test func aReopenKeepsTheSavedOrderAndDropsRepeats() {
        var launch = input(.normal, .lastProjects)
        launch.sessionProjects = [api, app, api, web, app]
        #expect(decide(launch) == .reopen([api, app, web]))
        #expect(decide(launch, existing: [app, api]) == .reopen([api, app]))
    }

    @Test func aRequestThatOpenedNothingFollowsTheSetting() {
        // AE2: `nxtrm` or a drop that opened its window meets row 1; one that opened none goes on as a normal launch.
        #expect(decide(input(.request, .welcome)) == .welcome)
        #expect(decide(input(.request, .lastProjects)) == .reopen([app, api]))
        #expect(decide(input(.request, .lastProjects), existing: [web]) == .welcome)
        // Only a normal launch offers the import.
        var first = input(.request)
        first.mayOfferImport = true
        #expect(decide(first) == .welcome)
    }

    @Test func theFirstRunOffersTheImportThenTheWelcomeWindow() {
        // AE3: `importOffered` unset and no recent project.
        var first = input(.normal)
        first.mayOfferImport = true
        #expect(decide(first) == .importThenWelcome)
        first.settings.opens = .lastProjects
        #expect(decide(first, existing: []) == .importThenWelcome)
        // Saved projects that exist still reopen under Reopen.
        #expect(decide(first) == .reopen([app, api]))
        // A Dock click never offers it.
        var reopen = input(.dockReopen)
        reopen.mayOfferImport = true
        #expect(decide(reopen) == .welcome)
    }

    @Test func aDockClickWithNoWindowFollowsTheSetting() {
        // AE5: the Welcome window, whatever was open at the last quit.
        #expect(decide(input(.dockReopen, .welcome)) == .welcome)
        // Reopen: the most recent project that still exists, not the last quit's.
        #expect(decide(input(.dockReopen, .lastProjects)) == .reopen([api]))
        #expect(decide(input(.dockReopen, .lastProjects), existing: [app, web]) == .reopen([app]))
        #expect(decide(input(.dockReopen, .lastProjects), existing: []) == .welcome)
        var noRecent = input(.dockReopen, .lastProjects)
        noRecent.recentProjects = []
        #expect(decide(noRecent) == .welcome)
        // Whatever a restore did.
        for restore in LaunchRestoreResult.allCases {
            var launch = input(.dockReopen, .lastProjects)
            launch.restore = restore
            #expect(decide(launch) == .reopen([api]))
            launch.settings.opens = .welcome
            #expect(decide(launch) == .welcome)
        }
    }

    @Test func theRelaunchAfterRelaunchNowReopensTheSavedProjectsWhateverTheSetting() {
        // AE10.
        #expect(decide(input(.updateRelaunch, .welcome)) == .reopen([app, api]))
        #expect(decide(input(.updateRelaunch, .lastProjects)) == .reopen([app, api]))
        #expect(decide(input(.updateRelaunch, .welcome), existing: [api]) == .reopen([api]))
        // None left: the setting decides, as for a normal launch.
        #expect(decide(input(.updateRelaunch, .welcome), existing: [web]) == .welcome)
        #expect(decide(input(.updateRelaunch, .lastProjects), existing: [web]) == .welcome)
        var first = input(.updateRelaunch)
        first.mayOfferImport = true
        #expect(decide(first, existing: []) == .welcome)
    }

    @Test func aRestoreThatLeftNoTerminalWindowFallsBackToTheSetting() {
        // Rows 6 to 8, for every kind but the Dock click, and whatever the restore said.
        let kinds: [LaunchKind] = [.normal, .request, .updateRelaunch]
        let restores: [LaunchRestoreResult] = [.openedNoWindow, .openedWindows]
        for kind in kinds {
            for restore in restores {
                var launch = input(kind, .welcome)
                launch.restore = restore
                #expect(decide(launch) == .welcome, "\(kind), \(restore)")
                launch.settings.opens = .lastProjects
                #expect(decide(launch) == .reopen([app, api]), "\(kind), \(restore)")
                #expect(decide(launch, existing: []) == .welcome, "\(kind), \(restore)")
            }
        }
    }

    @Test func theRelaunchFlagCountsForFifteenMinutes() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(!LaunchDecision.isUpdateRelaunch(flaggedAt: nil, now: now))
        #expect(!LaunchDecision.isUpdateRelaunch(flaggedAt: now.addingTimeInterval(1), now: now)) // from the future
        #expect(!LaunchDecision.isUpdateRelaunch(flaggedAt: now.addingTimeInterval(-(15 * 60 + 1)), now: now))
        #expect(LaunchDecision.isUpdateRelaunch(flaggedAt: now, now: now))
        #expect(LaunchDecision.isUpdateRelaunch(flaggedAt: now.addingTimeInterval(-14 * 60), now: now))
        #expect(LaunchDecision.isUpdateRelaunch(flaggedAt: now.addingTimeInterval(-15 * 60), now: now))
    }
}
