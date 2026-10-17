import Foundation
import Testing
@testable import NextTermCore

@Suite struct LaunchSettingsTests {
    @Test func defaults() {
        let s = LaunchSettings()
        #expect(s.opens == LaunchOpens.welcome)
        #expect(!s.opensChosen)
        #expect(s.askToReopenOnQuit)
        #expect(s.keepScrollback)
        // In the order of the radio buttons. Compared outside `#expect`, where arrays are slow to type-check.
        let titles: [String] = LaunchOpens.allCases.map(\.title)
        let expected: [String] = ["Show the Welcome window", "Resume where I left off", "Open a new terminal"]
        let same: Bool = titles == expected
        #expect(same, "\(titles)")
    }

    @Test func aStoredNewTerminalReadsBack() throws {
        // "Open a new terminal" is kept as `newTerminal`. A build from before it reads that as any unknown value, the
        // Welcome window, and so does this one for a value it does not know.
        let (defaults, name) = try TestDefaults.make("launch-settings-new-terminal")
        defer { TestDefaults.remove(defaults, name) }
        var terminal = LaunchSettings()
        terminal.opens = .newTerminal
        terminal.save(.opens, to: defaults)
        let stored: String? = defaults.string(forKey: LaunchSettings.Key.opens)
        #expect(stored == "newTerminal")
        let read = LaunchSettings(defaults: defaults)
        #expect(read.opens == .newTerminal && read.opensChosen)
        #expect(read.opens.title == "Open a new terminal")
        defaults.set("newTerminals", forKey: LaunchSettings.Key.opens)
        let unknown = LaunchSettings(defaults: defaults)
        #expect(unknown.opens == .welcome && !unknown.opensChosen)
    }

    @Test func readAndSavedInTheDefaults() throws {
        let (defaults, name) = try TestDefaults.make("launch-settings-tests")
        defer { TestDefaults.remove(defaults, name) }
        // Never set, for a new user and for one updating into this release: the Welcome window, never chosen, Ask on, and
        // scrollback kept.
        #expect(LaunchSettings(defaults: defaults) == LaunchSettings())
        #expect(!LaunchSettings(defaults: defaults).opensChosen)
        var changed = LaunchSettings()
        changed.opens = .lastProjects
        changed.askToReopenOnQuit = false
        changed.keepScrollback = false
        #expect(changed.opensChosen)
        changed.save(to: defaults)
        let opens: String? = defaults.string(forKey: LaunchSettings.Key.opens)
        let ask: Bool? = defaults.object(forKey: LaunchSettings.Key.askToReopenOnQuit) as? Bool
        let scrollback: Bool? = defaults.object(forKey: LaunchSettings.Key.keepScrollback) as? Bool
        #expect(opens == "lastProjects")
        #expect(ask == false)
        #expect(scrollback == false)
        #expect(LaunchSettings(defaults: defaults) == changed)
        var welcome = LaunchSettings()
        welcome.opens = .welcome
        welcome.save(to: defaults)
        let reset: String? = defaults.string(forKey: LaunchSettings.Key.opens)
        #expect(reset == "welcome")
        #expect(LaunchSettings(defaults: defaults) == welcome)
        #expect(LaunchSettings(defaults: defaults).opensChosen)
        // Something that is not one of the choices reads as the default, never chosen.
        defaults.set("everything", forKey: LaunchSettings.Key.opens)
        defaults.set("sometimes", forKey: LaunchSettings.Key.askToReopenOnQuit)
        defaults.set("often", forKey: LaunchSettings.Key.keepScrollback)
        #expect(LaunchSettings(defaults: defaults) == LaunchSettings())
        #expect(Set(LaunchSettings.Key.all).count == 3)
    }

    @Test func aStoredReopenReadsAsResume() throws {
        // 0.10 stored "Reopen the projects that were open" as `lastProjects`: 0.11 reads it as "Resume where I left off".
        let (defaults, name) = try TestDefaults.make("launch-settings-resume")
        defer { TestDefaults.remove(defaults, name) }
        defaults.set("lastProjects", forKey: LaunchSettings.Key.opens)
        let read = LaunchSettings(defaults: defaults)
        #expect(read.opens == .lastProjects && read.opensChosen)
        #expect(read.opens.title == "Resume where I left off")
    }

    @Test func eachSettingSavesOnlyItsOwnKey() throws {
        // Settings › General's controls: "At launch" counts as chosen only once the user chose it.
        let (defaults, name) = try TestDefaults.make("launch-settings-own-key")
        defer { TestDefaults.remove(defaults, name) }
        var settings = LaunchSettings(defaults: defaults)
        settings.keepScrollback = false
        settings.save(.keepScrollback, to: defaults)
        settings.askToReopenOnQuit = false
        settings.save(.askToReopenOnQuit, to: defaults)
        let stored: [String] = defaults.dictionaryRepresentation().keys.filter { LaunchSettings.Key.all.contains($0) }.sorted()
        let expected: [String] = [LaunchSettings.Key.askToReopenOnQuit, LaunchSettings.Key.keepScrollback].sorted()
        let same: Bool = stored == expected
        #expect(same, "\(stored)")
        let read = LaunchSettings(defaults: defaults)
        #expect(!read.opensChosen && !read.keepScrollback && !read.askToReopenOnQuit)
        settings.opens = .lastProjects
        settings.save(.opens, to: defaults)
        #expect(LaunchSettings(defaults: defaults).opensChosen)
        // A whole save of settings whose "At launch" nobody chose leaves it unchosen.
        let (other, name2) = try TestDefaults.make("launch-settings-whole")
        defer { TestDefaults.remove(other, name2) }
        LaunchSettings().save(to: other)
        let unchosen: Any? = other.object(forKey: LaunchSettings.Key.opens)
        let unset: Bool = unchosen == nil
        #expect(unset)
        #expect(!LaunchSettings(defaults: other).opensChosen)
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

    /// Under any setting but Reopen the folders open at the last quit are never checked: a look at one in ~/Documents
    /// would ask for Documents before anything was shown.
    @Test func onlyReopenChecksTheProjectsOpenAtTheLastQuit() {
        for opens in LaunchOpens.allCases where opens != .lastProjects {
            for mayOfferImport in [false, true] {
                var launch = input(.normal, opens)
                launch.mayOfferImport = mayOfferImport
                var checked: [String] = []
                let shown = LaunchDecision.opening(launch) { (path: String) -> Bool in
                    checked.append(path)
                    return true
                }
                #expect(checked.isEmpty, "\(opens): \(checked)")
                let expected: LaunchOpening = opens == .newTerminal ? .newTerminal : (mayOfferImport ? .importThenWelcome : .welcome)
                #expect(shown == expected, "\(opens), import \(mayOfferImport)")
            }
        }
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

    @Test func aRestoreThatLeftNoTerminalWindowFallsBackToTheSetting() {
        // Rows 6 to 8, for every kind but the Dock click, and whatever the restore said.
        let kinds: [LaunchKind] = [.normal, .request]
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

    @Test func openANewTerminalTakesTheWelcomeWindowsPlace() {
        // A launch that names nothing and restores nothing: a shell window, never the projects open at the last quit.
        #expect(decide(input(.normal, .newTerminal)) == .newTerminal)
        #expect(decide(input(.normal, .newTerminal), existing: []) == .newTerminal)
        // A request that opened nothing goes on as a normal launch.
        #expect(decide(input(.request, .newTerminal)) == .newTerminal)
        // A restore that left no terminal window falls back to the setting too.
        for restore in LaunchRestoreResult.allCases {
            var launch = input(.normal, .newTerminal)
            launch.restore = restore
            #expect(decide(launch) == .newTerminal, "\(restore)")
        }
    }

    @Test func openANewTerminalAddsNothingToTheWindowsALaunchOpened() {
        // A restore that built windows, or `nxtrm` with a folder: those windows, and no extra shell window.
        var restored = input(.normal, .newTerminal)
        restored.restore = .openedWindows
        restored.terminalWindowOpen = true
        #expect(decide(restored) == .nothing)
        var request = input(.request, .newTerminal)
        request.terminalWindowOpen = true
        #expect(decide(request) == .nothing)
    }

    @Test func openANewTerminalOnADockClickWithNoWindow() {
        // A shell window, not the most recent project and not the Welcome window.
        #expect(decide(input(.dockReopen, .newTerminal)) == .newTerminal)
        #expect(decide(input(.dockReopen, .newTerminal), existing: []) == .newTerminal)
        var reopen = input(.dockReopen, .newTerminal)
        reopen.mayOfferImport = true
        #expect(decide(reopen) == .newTerminal)
    }

    @Test func openANewTerminalIsAChoiceTheImportOfferNeverOverrides() {
        // The offer stays pending while no app to import from was ever found and no project was opened, which is how a
        // user who only opens shell windows launches: the shell window they chose, not the Welcome window. A first launch
        // has chosen nothing, and still gets the offer.
        var later = input(.normal, .newTerminal)
        later.mayOfferImport = true
        later.recentProjects = []
        #expect(decide(later) == .newTerminal)
        #expect(decide(later, existing: []) == .newTerminal)
        var first = LaunchInput(kind: .normal, restore: .notRun, terminalWindowOpen: false, settings: LaunchSettings(),
                                sessionProjects: [], recentProjects: [], mayOfferImport: true)
        #expect(decide(first) == .importThenWelcome)
        first.settings.opens = .welcome
        #expect(decide(first) == .importThenWelcome)
    }
}

// MARK: - The restore step

/// Made-up ids, versions and boot sessions for the restore step.
enum RestoreFixture {
    static let marker = UUID(uuidString: "6f1c2a3b-4d5e-4f60-8172-93a4b5c6d7e8")!
    static let other = UUID(uuidString: "0d9e8f7a-6b5c-4d3e-8f2a-1b0c9d8e7f6a")!
    static let launch = UUID(uuidString: "0a1b2c3d-4e5f-4061-8273-8495a6b7c8d9")!
    static let boot = "3C9D2E1F-5A6B-4C7D-8E9F-0A1B2C3D4E5F"
    static let from = "0.11.0"
    static let to = "0.11.1"
    static let savedAt = Date(timeIntervalSince1970: 1_790_000_000)

    /// The update quit's marker, written at 1,000 s of uptime.
    static var updateMarker: UpdateMarker {
        UpdateMarker(id: marker, launchID: launch, fromVersion: from, toVersion: to, bootSession: boot, uptime: 1000)
    }

    /// The update quit's header: unclean, waiting for the marker, for the update to `to`.
    static func header(clean: Bool = false, awaiting: UUID? = marker,
                       launchID: UUID = launch) -> SessionSnapshot.Header {
        SessionSnapshot.Header(launchID: launchID, generation: 7, clean: clean, bootSession: boot,
                               awaitingMarker: awaiting, pendingToVersion: awaiting == nil ? nil : to, savedAt: savedAt)
    }

    /// The relaunch 30 s after the update quit, into the new version: the lock taken, the marker claimed, two windows,
    /// the first launch since the counter reset, written before the snapshot was read.
    static func update() -> RestoreFacts {
        RestoreFacts(lockTaken: true, marker: updateMarker, header: header(), windows: 2, consumed: ConsumedMarkers(),
                     attempts: RestoreAttempts(count: 1), attemptsWritten: true, uptime: 1030, bootSession: boot,
                     version: to)
    }

    /// The launch after a crash: no marker, an unclean snapshot with two windows.
    static func crash() -> RestoreFacts {
        var facts = update()
        facts.marker = nil
        facts.header = header(awaiting: nil, launchID: other)
        return facts
    }
}

@Suite struct UpdateMarkerTests {
    @Test func readsBackAsWritten() throws {
        let marker = RestoreFixture.updateMarker
        let parsed = try #require(UpdateMarker.parse(marker.data))
        #expect(parsed == marker)
        let text = String(decoding: marker.data, as: UTF8.self)
        // Ids as MCP shows them, and nothing but the six fields.
        #expect(text.contains(RestoreFixture.marker.uuidString.lowercased()))
        let object = try #require(try JSONSerialization.jsonObject(with: marker.data) as? [String: Any])
        let keys: [String] = object.keys.sorted()
        let expected: [String] = ["bootSession", "fromVersion", "id", "launchID", "toVersion", "uptime"]
        let same: Bool = keys == expected
        #expect(same, "\(keys)")
    }

    /// The marker is read as untrusted: anything but six good fields is no marker at all.
    @Test func anythingElseIsNoMarker() throws {
        let written = RestoreFixture.updateMarker.data
        let good = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        func parsed(_ change: (inout [String: Any]) -> Void) -> UpdateMarker? {
            var object = good
            change(&object)
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return UpdateMarker.parse(data)
        }
        let unchanged: UpdateMarker? = parsed { _ in }
        #expect(unchanged == RestoreFixture.updateMarker)
        let extra: UpdateMarker? = parsed { $0["extra"] = "ignored" }
        #expect(extra == RestoreFixture.updateMarker)
        let changes: [(String, (inout [String: Any]) -> Void)] = [
            ("no id", { $0["id"] = nil }),
            ("an id that is no UUID", { $0["id"] = "../state" }),
            ("no launch id", { $0["launchID"] = nil }),
            ("a version with a blank", { $0["toVersion"] = "0.11 beta" }),
            ("a version with a slash", { $0["fromVersion"] = "../0.11" }),
            ("an empty version", { $0["toVersion"] = "" }),
            ("a version too long", { $0["toVersion"] = String(repeating: "1", count: 65) }),
            ("no boot session", { $0["bootSession"] = nil }),
            ("a boot session with a slash", { $0["bootSession"] = "a/b" }),
            ("a negative uptime", { $0["uptime"] = -1 }),
            ("an uptime as text", { $0["uptime"] = "1000" }),
        ]
        for (name, change) in changes {
            #expect(parsed(change) == nil, "\(name)")
        }
        #expect(UpdateMarker.parse(Data("not json".utf8)) == nil)
        #expect(UpdateMarker.parse(Data("[]".utf8)) == nil)
        var padded = RestoreFixture.updateMarker.data
        padded.append(Data(repeating: UInt8(ascii: " "), count: UpdateMarker.maxSize))
        #expect(UpdateMarker.parse(padded) == nil)
    }

    @Test func theClocksItIsReadOn() throws {
        // This boot's session: the same each time, and a token the marker keeps.
        let boot = try #require(UpdateMarker.currentBootSession())
        #expect(UpdateMarker.currentBootSession() == boot)
        var marker = RestoreFixture.updateMarker
        marker.bootSession = boot
        #expect(UpdateMarker.parse(marker.data)?.bootSession == boot)
        // Seconds since boot, never going back.
        let first = UpdateMarker.uptimeNow()
        let second = UpdateMarker.uptimeNow()
        #expect(first > 0)
        #expect(second >= first)
    }
}

@Suite struct RestoreAttemptsTests {
    @Test func launchesAndTryAgainRaiseItAndTheRestResetIt() {
        let two = RestoreAttempts(count: 2)
        #expect(two.after(.launch).count == 3)
        #expect(two.after(.tryAgain).count == 3)
        #expect(two.after(.settled).count == 0)
        #expect(two.after(.cleanQuit).count == 0)
        #expect(two.after(.markerWritten).count == 0)
        #expect(two.after(.setAside).count == 0)
        #expect(RestoreAttempts().count == 0)
        #expect(RestoreAttempts(count: -4).count == 0)
        #expect(RestoreAttempts.safeMode == 3)
        #expect(RestoreAttempts.quarantine == 4)
        #expect(RestoreAttempts.settleTime == 60)
    }

    @Test func readsBackAsWrittenAndFailsClosedOtherwise() {
        for count in [0, 1, 3, 4, 17] {
            #expect(RestoreAttempts.parse(RestoreAttempts(count: count).data).count == count)
        }
        #expect(RestoreAttempts.parse(Data("2\n".utf8)).count == 2)
        // A counter that does not read is no fresh start: it counts a restore that did not finish, so the launch,
        // raising it, restores in safe mode.
        let overlong = String(repeating: "1", count: RestoreAttempts.maxSize + 1)
        for text in ["", "x", "-3", "1.5", "3 3", overlong] {
            #expect(RestoreAttempts.parse(Data(text.utf8)) == RestoreAttempts.unread, "\(text)")
        }
        #expect(RestoreAttempts.unread.after(.launch).count == RestoreAttempts.safeMode)
        // More digits than a number holds is a count past the cap, not none.
        for text in [String(repeating: "9", count: 40), "99999999999999999999999\n"] {
            #expect(RestoreAttempts.parse(Data(text.utf8)).count == RestoreAttempts.most, "\(text)")
        }
        // It never counts past its cap, however many launches fail.
        var attempts = RestoreAttempts(count: Int.max)
        attempts = attempts.after(.launch)
        #expect(attempts.count > RestoreAttempts.quarantine)
        #expect(RestoreAttempts.parse(attempts.data) == attempts)
    }
}

@Suite struct ConsumedMarkersTests {
    @Test func remembersTheMarkersClaimed() throws {
        let record = ConsumedMarkers().adding(RestoreFixture.marker)
        #expect(record.contains(RestoreFixture.marker))
        #expect(!record.contains(RestoreFixture.other))
        let read = try #require(ConsumedMarkers.parse(record.data))
        #expect(read == record)
        #expect(ConsumedMarkers.parse(Data("[]".utf8)) == ConsumedMarkers())
        // Only the newest are kept, and the file stays small.
        var many = ConsumedMarkers()
        for n in 0..<100 {
            many = many.adding(UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!)
        }
        #expect(many.ids.count == ConsumedMarkers.kept)
        #expect(many.contains(UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", 99))!))
        #expect(!many.contains(UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", 0))!))
        #expect(many.data.count <= ConsumedMarkers.maxSize)
        #expect(ConsumedMarkers.parse(many.data) == many)
    }

    @Test func aRecordThatDoesNotReadIsNone() {
        for text in ["", "{}", "[\"../x\"]", "[1]", "not json"] {
            #expect(ConsumedMarkers.parse(Data(text.utf8)) == nil, "\(text)")
        }
        var big = Data("[".utf8)
        big.append(Data(repeating: UInt8(ascii: " "), count: ConsumedMarkers.maxSize))
        big.append(Data("]".utf8))
        #expect(ConsumedMarkers.parse(big) == nil)
    }
}

/// The claim, in a sessions folder of each test's own, made in a temporary folder.
@Suite struct UpdateMarkerClaimTests {
    /// The folder for a made-up app at /Users/x/Applications/Next Term.app, with its lock taken, and its parent to remove.
    func owned() throws -> (files: SessionFiles, parent: URL) {
        let path = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-claim-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        let parent = URL(fileURLWithPath: path)
        let files = try SessionFiles.open(in: parent, bundlePath: "/Users/x/Applications/Next Term.app")
        #expect(files.lock())
        return (files, parent)
    }

    @Test func claimsTheMarkerWaiting() throws {
        let (files, parent) = try owned()
        defer { try? FileManager.default.removeItem(at: parent) }
        var consumed: ConsumedMarkers? = ConsumedMarkers()
        #expect(UpdateMarker.claim(in: files, consumed: &consumed) == nil)
        try files.replace(UpdateMarker.fileName, with: RestoreFixture.updateMarker.data)
        #expect(UpdateMarker.claim(in: files, consumed: &consumed) == RestoreFixture.updateMarker)
        // Taken once: it now waits under its claimed name for the launch to record it, and the record is the launch's.
        let names: [String] = try files.names()
        #expect(!names.contains(UpdateMarker.fileName))
        #expect(names.contains(UpdateMarker.claimedName))
        #expect(consumed == ConsumedMarkers())
        // What is claimed but is no marker is none.
        try files.remove(UpdateMarker.claimedName)
        try files.replace(UpdateMarker.fileName, with: Data("not a marker".utf8))
        #expect(UpdateMarker.claim(in: files, consumed: &consumed) == nil)
    }

    /// A launch that ended between its claim and removing the claimed file left it there. The name is fixed, so it
    /// would block every claim after it, and every update relaunch would restore as after a crash.
    @Test func aClaimALaunchLeftIsUsedUpAndNeverBlocksTheNext() throws {
        let (files, parent) = try owned()
        defer { try? FileManager.default.removeItem(at: parent) }
        var next = RestoreFixture.updateMarker
        next.id = RestoreFixture.other
        try files.replace(UpdateMarker.claimedName, with: RestoreFixture.updateMarker.data)
        try files.replace(UpdateMarker.fileName, with: next.data)
        var consumed: ConsumedMarkers? = ConsumedMarkers()
        #expect(UpdateMarker.claim(in: files, consumed: &consumed) == next)
        #expect(consumed == ConsumedMarkers().adding(RestoreFixture.marker))
        // The left marker put back is used up.
        try files.replace(UpdateMarker.claimedName, with: RestoreFixture.updateMarker.data)
        try files.replace(UpdateMarker.fileName, with: RestoreFixture.updateMarker.data)
        consumed = ConsumedMarkers()
        let replayed = UpdateMarker.claim(in: files, consumed: &consumed)
        #expect(replayed == RestoreFixture.updateMarker)
        var facts = RestoreFixture.update()
        facts.marker = replayed
        facts.consumed = consumed
        #expect(LaunchDecision.check(facts) == .consumed)
        // A left file that is no marker goes too, and a record that does not read stays unread.
        try files.replace(UpdateMarker.claimedName, with: Data("not a marker".utf8))
        try files.replace(UpdateMarker.fileName, with: next.data)
        var unread: ConsumedMarkers? = nil
        #expect(UpdateMarker.claim(in: files, consumed: &unread) == next)
        #expect(unread == nil)
        // A link planted there is removed, never followed.
        let outside = parent.appendingPathComponent("outside.json")
        try RestoreFixture.updateMarker.data.write(to: outside)
        try files.remove(UpdateMarker.claimedName)
        let claimedPath = files.url.appendingPathComponent(UpdateMarker.claimedName).path
        try FileManager.default.createSymbolicLink(atPath: claimedPath, withDestinationPath: outside.path)
        try files.replace(UpdateMarker.fileName, with: next.data)
        consumed = ConsumedMarkers()
        #expect(UpdateMarker.claim(in: files, consumed: &consumed) == next)
        #expect(consumed == ConsumedMarkers())
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
}

/// What a launch restores (plan 003's U6), from the facts its launch hook gathered.
@Suite struct LaunchRestoreTests {
    func decide(_ facts: RestoreFacts) -> RestoreDecision { LaunchDecision.restoring(facts) }

    @Test func aLockNotTakenLaunchesNormallyAndKeepsNothing() {
        // Another Next Term holds the folder: whatever this one would have found there, it reads, writes and claims
        // nothing.
        var facts = RestoreFixture.update()
        facts.lockTaken = false
        facts.installResult = InstallResult(outcome: .failedKeptOld, marker: RestoreFixture.marker)
        facts.version = RestoreFixture.from
        let decision = decide(facts)
        #expect(decision.kind == .normal)
        #expect(decision.marker == .missing)
        #expect(!decision.saves)
        #expect(decision.consumes.isEmpty)
        #expect(decision.scrollback == .leave)
        #expect(decision.installAlert == nil)
        #expect(!decision.didNotInstallNote)
        #expect(decision.attemptsReset == .never)
        #expect(decision.launchRestore(openedWindow: false) == .notRun)
    }

    @Test func aValidMarkerGivesAnUpdateRestoreInTheNewVersionAndInTheOld() {
        // The update installed, or it failed and the old version runs.
        for version in [RestoreFixture.to, RestoreFixture.from] {
            var facts = RestoreFixture.update()
            facts.version = version
            let decision = decide(facts)
            #expect(decision.marker == .valid, "\(version)")
            #expect(decision.kind == .restore(.update), "\(version)")
            #expect(decision.saves)
            #expect(decision.consumes == [RestoreFixture.marker])
            #expect(decision.scrollback == .read)
            #expect(decision.attemptsReset == .afterRestore)
            #expect(decision.launchRestore(openedWindow: true) == .openedWindows)
            #expect(decision.launchRestore(openedWindow: false) == .openedNoWindow)
        }
        // Fifteen minutes on the uptime clock still counts.
        var late = RestoreFixture.update()
        late.uptime = 1000 + UpdateMarker.lifetime
        #expect(decide(late).kind == .restore(.update))
    }

    /// A marker that does not hold: the launch restores as after a crash when the snapshot is unclean, and launches
    /// normally otherwise. Either way the marker is used up, with the one the snapshot waits for, and scrollback is
    /// deleted unread.
    @Test func aMarkerThatDoesNotHoldGivesACrashRestoreOrANormalLaunch() {
        let fixture = RestoreFixture.self
        let cases: [(String, UpdateMarker.Check, (inout RestoreFacts) -> Void)] = [
            ("another boot", .otherBoot, { $0.bootSession = "11111111-2222-4333-8444-555555555555" }),
            ("no boot session read", .otherBoot, { $0.bootSession = nil }),
            ("over fifteen minutes", .stale, { $0.uptime = 1000 + UpdateMarker.lifetime + 1 }),
            ("from the future", .stale, { $0.uptime = 999 }),
            ("an uptime that is no number", .stale, { $0.uptime = .nan }),
            ("neither of its versions", .otherVersion, { $0.version = "0.12.0" }),
            ("consumed before", .consumed, { $0.consumed = ConsumedMarkers().adding(fixture.marker) }),
            ("a consumed record that does not read", .consumed, { $0.consumed = nil }),
            ("the snapshot waits for another", .notAwaited, { $0.header?.awaitingMarker = fixture.other }),
            ("the snapshot waits for none", .notAwaited, { $0.header?.awaitingMarker = nil }),
            ("another launch wrote it", .notAwaited, { $0.header?.launchID = fixture.other }),
        ]
        for (name, check, change) in cases {
            var facts = RestoreFixture.update()
            change(&facts)
            let awaited: UUID? = facts.header?.awaitingMarker
            let used: [UUID] = awaited == fixture.other ? [fixture.marker, fixture.other] : [fixture.marker]
            let unclean = decide(facts)
            #expect(unclean.marker == check, "\(name)")
            #expect(unclean.kind == .restore(.crash), "\(name)")
            #expect(unclean.consumes == used, "\(name)")
            #expect(unclean.scrollback == .deleteUnread, "\(name)")
            facts.header?.clean = true
            let clean = decide(facts)
            #expect(clean.marker == check, "\(name)")
            #expect(clean.kind == .normal, "\(name)")
            #expect(clean.consumes == used, "\(name)")
            #expect(clean.scrollback == .deleteUnread, "\(name)")
            #expect(clean.attemptsReset == .afterLaunch, "\(name)")
        }
        // No snapshot that reads: nothing to restore with or without the marker.
        var none = RestoreFixture.update()
        none.header = nil
        #expect(decide(none).marker == .notAwaited)
        #expect(decide(none).kind == .normal)
    }

    @Test func aCleanTombstoneAndNoMarkerLeavesTheLaunchToTheTable() {
        // R3: a normal quit and relaunch shows what plan 005's rows say.
        var facts = RestoreFixture.crash()
        facts.header = RestoreFixture.header(clean: true, awaiting: nil)
        facts.windows = 0
        let decision = decide(facts)
        #expect(decision.kind == .normal)
        #expect(decision.marker == .missing)
        #expect(decision.saves)
        #expect(decision.consumes.isEmpty)
        #expect(decision.scrollback == .deleteUnread)
        #expect(decision.attemptsReset == .afterLaunch)
        let restore = decision.launchRestore(openedWindow: false)
        #expect(restore == .notRun)
        let app = "/Users/x/Code/app"
        var launch = LaunchInput(kind: .normal, restore: restore, terminalWindowOpen: false, settings: LaunchSettings(),
                                 sessionProjects: [app], recentProjects: [app], mayOfferImport: false)
        #expect(LaunchDecision.opening(launch) { _ in true } == .welcome)
        launch.settings.opens = .lastProjects
        #expect(LaunchDecision.opening(launch) { _ in true } == .reopen([app]))
    }

    @Test func aSnapshotWithNoWindowsCountsAsNone() {
        var crash = RestoreFixture.crash()
        crash.windows = 0
        #expect(decide(crash).kind == .normal)
        var update = RestoreFixture.update()
        update.windows = 0
        let decision = decide(update)
        #expect(decision.marker == .valid)
        #expect(decision.kind == .normal)
        #expect(decision.consumes == [RestoreFixture.marker])
        #expect(decision.scrollback == .deleteUnread)
    }

    /// KTD13: the raised counter less one is the restores that did not finish. Two give safe mode, three set the
    /// snapshot aside.
    @Test func failedRestoresHoldBackThenSetTheSnapshotAside() {
        let kinds: [(SessionSnapshot.RestoreKind, RestoreFacts)] = [
            (.update, RestoreFixture.update()),
            (.crash, RestoreFixture.crash()),
        ]
        for (kind, base) in kinds {
            var facts = base
            for count in [1, 2] {
                facts.attempts = RestoreAttempts(count: count)
                #expect(decide(facts).kind == .restore(kind), "\(kind), \(count)")
            }
            facts.attempts = RestoreAttempts(count: 3)
            let safe = decide(facts)
            #expect(safe.kind == .safeMode(kind), "\(kind)")
            // Layout only: no scrollback, and the restore settles once Keep As Is or Try Again ends it.
            #expect(safe.scrollback == .deleteUnread)
            #expect(safe.attemptsReset == .afterRestore)
            #expect(safe.launchRestore(openedWindow: true) == .openedWindows)
            for count in [4, 9] {
                facts.attempts = RestoreAttempts(count: count)
                let aside = decide(facts)
                #expect(aside.kind == .quarantine, "\(kind), \(count)")
                #expect(aside.saves)
                #expect(aside.scrollback == .deleteUnread)
                // The tries counted were that snapshot's: the next one gets its own.
                #expect(aside.attemptsReset == .afterSetAside)
                #expect(aside.launchRestore(openedWindow: false) == .notRun)
            }
        }
        // Nothing to restore: no safe mode and nothing set aside, however high the counter.
        var tombstone = RestoreFixture.crash()
        tombstone.header?.clean = true
        for count in [3, 4, 9] {
            tombstone.attempts = RestoreAttempts(count: count)
            #expect(decide(tombstone).kind == .normal, "\(count)")
        }
    }

    /// A raised counter that was not written (a full disk, a refused file) would not count this try if it crashed, and
    /// the same snapshot would be restored forever. Such a restore runs nothing.
    @Test func aCounterNotWrittenHoldsTheRestoreAtSafeMode() {
        let kinds: [(SessionSnapshot.RestoreKind, RestoreFacts)] = [
            (.update, RestoreFixture.update()),
            (.crash, RestoreFixture.crash()),
        ]
        for (kind, base) in kinds {
            var facts = base
            facts.attemptsWritten = false
            for count in [1, 2, 3] {
                facts.attempts = RestoreAttempts(count: count)
                #expect(decide(facts).kind == .safeMode(kind), "\(kind), \(count)")
            }
            facts.attempts = RestoreAttempts(count: 4)
            #expect(decide(facts).kind == .quarantine, "\(kind)")
        }
        // Nothing to restore is still a normal launch.
        var tombstone = RestoreFixture.crash()
        tombstone.header?.clean = true
        tombstone.attemptsWritten = false
        #expect(decide(tombstone).kind == .normal)
    }

    @Test func anAwaitedMarkerThatNeverCameIsACrashThatSaysTheUpdateDidNotInstall() {
        // The snapshot waits for a marker, and none was written (or it was lost).
        var facts = RestoreFixture.update()
        facts.marker = nil
        facts.version = RestoreFixture.from
        let old = decide(facts)
        #expect(old.marker == .missing)
        #expect(old.kind == .restore(.crash))
        #expect(old.installAlert == nil)
        #expect(old.didNotInstallNote)
        // The update went in after all: nothing to tell.
        facts.version = RestoreFixture.to
        #expect(!decide(facts).didNotInstallNote)
        // A valid marker in the old version (the script never ran): the note too.
        var stranded = RestoreFixture.update()
        stranded.version = RestoreFixture.from
        #expect(decide(stranded).didNotInstallNote)
        #expect(!decide(RestoreFixture.update()).didNotInstallNote)
        // A snapshot no update was installing for says nothing.
        #expect(!decide(RestoreFixture.crash()).didNotInstallNote)
    }

    /// R18 tells the user once. A launch that crashes before its first save leaves the update quit's header as it was,
    /// so the next launch reads it again: the launch before has told the user already.
    @Test func theUserIsToldOnceAcrossACrash() {
        // The alert: the old version restores, the result is read and removed, and the marker is used up.
        var first = RestoreFixture.update()
        first.version = RestoreFixture.from
        first.installResult = InstallResult(outcome: .failedKeptOld, marker: RestoreFixture.marker)
        let alerted = decide(first)
        #expect(alerted.installAlert == .failedKeptOld)
        #expect(!alerted.didNotInstallNote)
        var second = first
        second.marker = nil
        second.installResult = nil
        second.consumed = alerted.consumes.reduce(ConsumedMarkers()) { $0.adding($1) }
        second.attempts = RestoreAttempts(count: 2)
        let again = decide(second)
        #expect(again.kind == .restore(.crash))
        #expect(again.installAlert == nil)
        #expect(!again.didNotInstallNote)
        // The note: no marker came, and the launch that said so takes the one the snapshot waits for.
        var noted = first
        noted.marker = nil
        noted.installResult = nil
        let told = decide(noted)
        #expect(told.didNotInstallNote)
        #expect(told.consumes == [RestoreFixture.marker])
        noted.consumed = told.consumes.reduce(ConsumedMarkers()) { $0.adding($1) }
        noted.attempts = RestoreAttempts(count: 2)
        #expect(decide(noted).kind == .restore(.crash))
        #expect(!decide(noted).didNotInstallNote)
        // A record that does not read cannot say it was not told: nothing more is said.
        noted.consumed = nil
        #expect(!decide(noted).didNotInstallNote)
    }

    /// The note is shown with what restores: with nothing restored, no tab carries it.
    @Test func theNoteShowsOnlyWithWhatRestores() {
        var facts = RestoreFixture.update()
        facts.marker = nil
        facts.version = RestoreFixture.from
        facts.attempts = RestoreAttempts(count: 3)
        #expect(decide(facts).kind == .safeMode(.crash))
        #expect(decide(facts).didNotInstallNote)
        facts.attempts = RestoreAttempts(count: 4)
        #expect(decide(facts).kind == .quarantine)
        #expect(!decide(facts).didNotInstallNote)
        facts.attempts = RestoreAttempts(count: 1)
        facts.windows = 0
        #expect(decide(facts).kind == .normal)
        #expect(!decide(facts).didNotInstallNote)
    }

    /// The version an update installs is the valid marker's to-version, whatever the header says it was.
    @Test func theNoteGoesByTheMarkersToVersion() {
        var facts = RestoreFixture.update()
        facts.header?.pendingToVersion = "9.9.9"
        #expect(decide(facts).kind == .restore(.update))
        #expect(!decide(facts).didNotInstallNote)
        facts.version = RestoreFixture.from
        #expect(decide(facts).didNotInstallNote)
        // Without a valid marker the header's is the one there is.
        facts.marker = nil
        facts.version = RestoreFixture.to
        #expect(decide(facts).didNotInstallNote)
        facts.version = "9.9.9"
        #expect(!decide(facts).didNotInstallNote)
    }

    @Test func aFailedInstallGivesOneAlertAlongsideWhateverRestoreApplies() {
        let failures: [InstallResult.Outcome] = [.failedKeptOld, .failedRestoredBackup]
        for outcome in failures {
            let result = InstallResult(outcome: outcome, marker: RestoreFixture.marker)
            // AE7: the old version restores the update's sessions, and the alert is the only word of it.
            var update = RestoreFixture.update()
            update.version = RestoreFixture.from
            update.installResult = result
            let restored = decide(update)
            #expect(restored.kind == .restore(.update), "\(outcome)")
            #expect(restored.installAlert == outcome)
            #expect(!restored.didNotInstallNote)
            // In a version that is neither, as after a crash: the alert, and still no note.
            update.version = "0.10.9"
            let other = decide(update)
            #expect(other.kind == .restore(.crash), "\(outcome)")
            #expect(other.installAlert == outcome)
            #expect(!other.didNotInstallNote)
            // With nothing to restore.
            var normal = RestoreFixture.crash()
            normal.header = nil
            normal.installResult = result
            #expect(decide(normal).kind == .normal)
            #expect(decide(normal).installAlert == outcome)
        }
        // An update that went in says nothing.
        var installed = RestoreFixture.update()
        installed.installResult = InstallResult(outcome: .installed, marker: RestoreFixture.marker)
        #expect(decide(installed).installAlert == nil)
        #expect(!decide(installed).didNotInstallNote)
    }

    /// KTD12: the old app opened from its backup names its install path's folder. A release build takes that folder only
    /// when its app is gone and it holds the result that says so, written at the quit its snapshot was saved at.
    @Test func aBackupOpenArgumentIsAcceptedOnlyUnderItsCheck() {
        let key = "0123456789abcdef0123456789abcdef"
        let app = "/Applications/Next Term.app"
        let stranded = InstallResult(outcome: .failedRestoredBackup, marker: RestoreFixture.marker)
        func accepts(key: String = key, recorded: String? = app, there: Bool = false,
                     result: InstallResult? = stranded, awaiting: UUID? = RestoreFixture.marker) -> Bool {
            LaunchDecision.acceptsBackupOpen(key: key, recordedBundlePath: recorded, result: result,
                                             awaitingMarker: awaiting) { (path: String) -> Bool in there && path == app }
        }
        #expect(accepts())
        #expect(!accepts(there: true))
        #expect(!accepts(recorded: nil))
        #expect(!accepts(result: nil))
        #expect(!accepts(result: InstallResult(outcome: .failedKeptOld, marker: RestoreFixture.marker)))
        #expect(!accepts(result: InstallResult(outcome: .installed, marker: RestoreFixture.marker)))
        for bad in ["", "../sessions", key.uppercased(), String(key.dropLast()), key + "0"] {
            #expect(!accepts(key: bad), "\(bad)")
        }
        // "When I Quit": a normal quit wrote the tombstone and no marker, and the script ran with relaunch off.
        let quitInstall = InstallResult(outcome: .failedRestoredBackup, marker: nil)
        #expect(accepts(result: quitInstall, awaiting: nil))
        #expect(!accepts(there: true, result: quitInstall, awaiting: nil))
        // A result for another quit than the snapshot's.
        #expect(!accepts(result: InstallResult(outcome: .failedRestoredBackup, marker: RestoreFixture.other)))
        #expect(!accepts(result: quitInstall))
        #expect(!accepts(awaiting: nil))
        #expect(!accepts(awaiting: RestoreFixture.other))
    }
}

/// The quit restore (R3, R30, R32): the launch after a quit under "Resume where I left off" brings the session back, and
/// lets agents resume by themselves only with the quit consent's one-time id, used once.
@Suite struct QuitRestoreTests {
    static let consent = UUID(uuidString: "5a4b3c2d-1e0f-4a9b-8c7d-6e5f4a3b2c1d")!

    func decide(_ facts: RestoreFacts) -> RestoreDecision { LaunchDecision.restoring(facts) }

    /// The launch after a quit under Resume: no marker, the quit's clean snapshot with two windows, and its consent id
    /// when the user let that quit go ahead with the box checked. `resumes`: "At launch" reads Resume now.
    func quit(consent: UUID? = nil, resumes: Bool = true) -> RestoreFacts {
        var facts = RestoreFixture.crash()
        var header = RestoreFixture.header(clean: true, awaiting: nil, launchID: RestoreFixture.other)
        header.resumeConsent = consent
        facts.header = header
        facts.resumesAtLaunch = resumes
        return facts
    }

    @Test func aCleanSnapshotWithWindowsUnderResumeIsAQuitRestoreThatReadsItsScrollback() {
        let decision = decide(quit())
        #expect(decision.kind == .restore(.quit))
        #expect(decision.marker == .missing)
        #expect(!decision.quitConsent)
        #expect(decision.consumes.isEmpty)
        // Its scrollback is named for the snapshot's launch, which saved it at the quit.
        #expect(decision.scrollback == .read)
        #expect(decision.scrollbackQuit == RestoreFixture.other)
        #expect(decision.attemptsReset == .afterRestore)
        #expect(!decision.didNotInstallNote)
        #expect(decision.launchRestore(openedWindow: true) == .openedWindows)
        #expect(decision.launchRestore(openedWindow: false) == .openedNoWindow)
    }

    @Test func underWelcomeNothingComesBackAndItsScrollbackIsDeletedUnread() {
        // AE19: the user unchecked the box, or changed the setting since.
        let decision = decide(quit(consent: Self.consent, resumes: false))
        #expect(decision.kind == .normal)
        #expect(!decision.quitConsent)
        #expect(decision.scrollback == .deleteUnread)
        #expect(decision.scrollbackQuit == nil)
        #expect(decision.attemptsReset == .afterLaunch)
        #expect(decision.launchRestore(openedWindow: false) == .notRun)
        // The tombstone, under either setting.
        var tombstone = quit()
        tombstone.windows = 0
        #expect(decide(tombstone).kind == .normal)
    }

    @Test func anUnusedConsentIDGivesTheConsentAndIsListedToConsumeFirst() {
        // AE17: the launch records the id as used before it restores, so it lets agents resume once.
        let decision = decide(quit(consent: Self.consent))
        #expect(decision.kind == .restore(.quit))
        #expect(decision.quitConsent)
        #expect(decision.consumes == [Self.consent])
    }

    @Test func aConsumedOrMissingIDGivesAQuitRestoreWithoutTheConsent() {
        // AE18: Ask off, a logout, Don't ask again: no id. Each agent's resume command waits on the line.
        #expect(!decide(quit()).quitConsent)
        var used = quit(consent: Self.consent)
        used.consumed = ConsumedMarkers().adding(Self.consent)
        let again = decide(used)
        #expect(again.kind == .restore(.quit))
        #expect(!again.quitConsent)
        // A record that does not read cannot say the id is unused.
        var unread = quit(consent: Self.consent)
        unread.consumed = nil
        #expect(decide(unread).kind == .restore(.quit))
        #expect(!decide(unread).quitConsent)
    }

    @Test func onlyACleanSnapshotThatWaitsForNoMarkerIsAQuitRestore() {
        // An unclean snapshot is a crash's, whatever the setting, and its consent id is no consent.
        var crash = quit(consent: Self.consent)
        crash.header?.clean = false
        let crashed = decide(crash)
        #expect(crashed.kind == .restore(.crash))
        #expect(!crashed.quitConsent)
        #expect(crashed.scrollback == .deleteUnread)
        // One waiting for an update's marker that never came is no quit's.
        var awaiting = quit()
        awaiting.header?.awaitingMarker = RestoreFixture.marker
        #expect(decide(awaiting).kind == .normal)
        // An update restore stays one under Resume, with no quit consent.
        var update = RestoreFixture.update()
        update.resumesAtLaunch = true
        update.header?.resumeConsent = Self.consent
        let updated = decide(update)
        #expect(updated.kind == .restore(.update))
        #expect(!updated.quitConsent)
        #expect(updated.scrollbackQuit == RestoreFixture.marker)
        // Without the lock nothing is read.
        var locked = quit(consent: Self.consent)
        locked.lockTaken = false
        #expect(decide(locked).kind == .normal)
        #expect(!decide(locked).quitConsent)
        #expect(decide(locked).consumes.isEmpty)
    }

    @Test func aQuitRestoreThatFailsTwiceGivesSafeModeAndAThirdSetsItAside() {
        var facts = quit(consent: Self.consent)
        facts.attempts = RestoreAttempts(count: 3)
        let safe = decide(facts)
        #expect(safe.kind == .safeMode(.quit))
        // Nothing resumes by itself out of safe mode, and the id is used up all the same.
        #expect(!safe.quitConsent)
        #expect(safe.consumes == [Self.consent])
        #expect(safe.scrollback == .deleteUnread)
        #expect(safe.scrollbackQuit == nil)
        facts.attempts = RestoreAttempts(count: 4)
        #expect(decide(facts).kind == .quarantine)
        // A counter that was not written runs nothing either.
        facts.attempts = RestoreAttempts(count: 1)
        facts.attemptsWritten = false
        #expect(decide(facts).kind == .safeMode(.quit))
        #expect(!decide(facts).quitConsent)
    }
}

/// The counter across launches: a sessions folder moved as the app moves it, through the real restore step.
@Suite struct RestoreSequenceTests {
    struct Folder {
        var attempts = RestoreAttempts()
        var header: SessionSnapshot.Header? = RestoreFixture.header(clean: true, awaiting: nil)
        var windows = 0
        /// A marker waiting to be claimed.
        var marker: UpdateMarker?
        var consumed = ConsumedMarkers()
        var uptime: TimeInterval = 5000
        var generation = 0
        /// "At launch" reads "Resume where I left off".
        var resumes = false

        /// A launch: the counter rises before anything is read, the marker is claimed, and the restore step decides.
        /// A quarantine sets the snapshot aside, and the counter starts over.
        mutating func launch() -> RestoreDecision {
            attempts = attempts.after(.launch)
            uptime += 5
            let claimed = marker
            marker = nil
            var facts = RestoreFacts(lockTaken: true, marker: claimed, header: header, windows: windows,
                                     consumed: consumed, attempts: attempts, attemptsWritten: true, uptime: uptime,
                                     bootSession: RestoreFixture.boot, version: RestoreFixture.to)
            facts.resumesAtLaunch = resumes
            let decision = LaunchDecision.restoring(facts)
            consumed = decision.consumes.reduce(consumed) { $0.adding($1) }
            if decision.kind == .quarantine {
                header = nil
                windows = 0
            }
            if decision.attemptsReset == .afterSetAside { attempts = attempts.after(.setAside) }
            return decision
        }

        /// The launch saves its windows: the first save of a launch is unclean.
        mutating func save() {
            generation += 1
            let launch = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", generation))!
            header = RestoreFixture.header(awaiting: nil, launchID: launch)
            windows = 2
        }

        /// A minute passes with the launch's restore applied, or with nothing restored.
        mutating func settle() {
            uptime += RestoreAttempts.settleTime
            attempts = attempts.after(.settled)
        }

        mutating func tryAgain() { attempts = attempts.after(.tryAgain) }

        /// ⌘Q: the tombstone.
        mutating func quit() {
            header?.clean = true
            windows = 0
            attempts = attempts.after(.cleanQuit)
        }

        /// ⌘Q under "Resume where I left off": the whole session, clean, with a fresh consent id when the box was checked.
        mutating func quitUnderResume(consent: UUID?) {
            save()
            header?.clean = true
            header?.resumeConsent = consent
            resumes = true
            attempts = attempts.after(.cleanQuit)
        }

        /// The update quit: the final save waits for the marker, written last.
        mutating func updateQuit() {
            save()
            header?.awaitingMarker = RestoreFixture.marker
            header?.pendingToVersion = RestoreFixture.to
            marker = UpdateMarker(id: RestoreFixture.marker, launchID: header?.launchID ?? UUID(),
                                  fromVersion: RestoreFixture.from, toVersion: RestoreFixture.to,
                                  bootSession: RestoreFixture.boot, uptime: uptime)
            attempts = attempts.after(.markerWritten)
        }
    }

    @Test func restoresThatNeverFinishEndInSafeModeThenASetAsideSnapshot() {
        var folder = Folder()
        folder.updateQuit()
        #expect(folder.launch().kind == .restore(.update))
        // It crashes while it builds, before any save: the marker is used up, so it comes back as after a crash.
        #expect(folder.launch().kind == .restore(.crash))
        #expect(folder.attempts.count == 2)
        #expect(folder.launch().kind == .safeMode(.crash))
        let aside = folder.launch()
        #expect(aside.kind == .quarantine)
        #expect(aside.attemptsReset == .afterSetAside)
        #expect(folder.attempts.count == 0)
        // That launch saves its own windows and crashes within its first minute: its snapshot was never tried, so the
        // next launch restores it rather than setting it aside too.
        folder.save()
        #expect(folder.launch().kind == .restore(.crash))
        #expect(folder.attempts.count == 1)
    }

    /// A launch after a quit-restore launch that was killed before it saved anything: the same snapshot, its consent id
    /// used up, so its agents' resume commands go on the line; never a second automatic resume.
    @Test func aQuitConsentIsUsedOnceAcrossARestoreThatCrashed() {
        var folder = Folder()
        _ = folder.launch()
        folder.quitUnderResume(consent: QuitRestoreTests.consent)
        let first = folder.launch()
        #expect(first.kind == .restore(.quit))
        #expect(first.quitConsent)
        // It crashed while it built: the snapshot is as the quit left it.
        let second = folder.launch()
        #expect(second.kind == .restore(.quit))
        #expect(!second.quitConsent)
        #expect(folder.attempts.count == 2)
        #expect(folder.launch().kind == .safeMode(.quit))
        // A quit without the box checked: a quit restore again, with no consent.
        var unchecked = Folder()
        _ = unchecked.launch()
        unchecked.quitUnderResume(consent: nil)
        #expect(unchecked.launch().kind == .restore(.quit))
        #expect(!unchecked.launch().quitConsent)
    }

    @Test func aCleanQuitResetsIt() {
        var folder = Folder()
        _ = folder.launch()
        folder.save()
        // A crash, and a restore that crashes again before its minute is up.
        #expect(folder.launch().kind == .restore(.crash))
        #expect(folder.attempts.count == 2)
        folder.quit()
        #expect(folder.attempts.count == 0)
        #expect(folder.launch().kind == .normal)
        folder.save()
        // The next crash is one failed restore, not two.
        #expect(folder.launch().kind == .restore(.crash))
        #expect(folder.attempts.count == 2)
    }

    @Test func aMarkerWriteResetsIt() {
        var folder = Folder()
        _ = folder.launch()
        folder.save()
        #expect(folder.launch().kind == .restore(.crash))
        // The update quit comes before the crash restore's minute is up.
        folder.updateQuit()
        #expect(folder.attempts.count == 0)
        #expect(folder.launch().kind == .restore(.update))
        #expect(folder.attempts.count == 1)
    }

    @Test func aLaunchThatRestoredNothingResetsItAMinuteIn() {
        var folder = Folder()
        let first = folder.launch()
        #expect(first.kind == .normal)
        #expect(first.attemptsReset == .afterLaunch)
        folder.settle()
        folder.save()
        // Normal launch, crash, relaunch: a crash restore, counted as the first try.
        #expect(folder.launch().kind == .restore(.crash))
        #expect(folder.attempts.count == 1)
        // Crash after crash, each well after its restore settled, never reaches safe mode.
        for _ in 0..<5 {
            folder.settle()
            folder.save()
            #expect(folder.launch().kind == .restore(.crash))
        }
    }

    @Test func tryAgainCountsAsAnotherTry() {
        var folder = Folder()
        _ = folder.launch()
        folder.save()
        _ = folder.launch()
        #expect(folder.launch().kind == .safeMode(.crash))
        // Try Again applies the actions, and they crash too: the snapshot is set aside.
        folder.tryAgain()
        #expect(folder.attempts.count == 4)
        #expect(folder.launch().kind == .quarantine)
        // Try Again that works settles like any restore.
        var settled = Folder()
        _ = settled.launch()
        settled.save()
        _ = settled.launch()
        #expect(settled.launch().kind == .safeMode(.crash))
        settled.tryAgain()
        settled.settle()
        #expect(settled.launch().kind == .restore(.crash))
    }

    @Test func earlyCleanQuitsDoNotSendTheNextCrashToSafeMode() {
        var folder = Folder()
        // Launches the user quits within their first minute.
        for _ in 0..<5 {
            #expect(folder.launch().kind == .normal)
            folder.save()
            folder.quit()
        }
        _ = folder.launch()
        folder.save()
        let crash = folder.launch()
        #expect(crash.kind == .restore(.crash))
        #expect(folder.attempts.count == 2)
    }
}
