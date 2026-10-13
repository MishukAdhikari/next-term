import Foundation
import Testing
@testable import NextTermCore

@Suite struct ProjectHistoryTests {
    /// A moment `seconds` after 1970: whole seconds, so a time read back from the defaults is the same `Date`.
    private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    @Test func openingMovesAProjectToTheFrontWithItsNewTime() {
        var history = ProjectHistory()
        history.record(opened: "/code/a", at: at(100))
        history.record(opened: "/code/b", at: at(200))
        history.record(opened: "/code/a", at: at(300))
        // Compared outside `#expect`, where arrays are slow to type-check.
        let paths: [String] = history.paths
        let same: Bool = paths == ["/code/a", "/code/b"]
        #expect(same, "\(paths)")
        #expect(history.lastUsed("/code/a") == at(300))
        #expect(history.lastUsed("/code/b") == at(200))
        #expect(history.lastUsed("/code/none") == nil)
        // Two opens in the same second: the later call comes first.
        history.record(opened: "/code/b", at: at(300))
        #expect(history.paths.first == "/code/b")
    }

    @Test func aCloseKeepsTheLaterOfTheStoredTimeAndItsOwn() {
        var history = ProjectHistory()
        history.record(opened: "/code/b", at: at(400))
        history.record(opened: "/code/a", at: at(500))
        // Opened at 500, its window last in front before that: a clock gone back, or a stale time. The stored one stays.
        history.record(closed: "/code/a", lastUsed: at(300))
        #expect(history.lastUsed("/code/a") == at(500))
        #expect(history.paths.first == "/code/a")
        // b's window was in front after a was opened: b moves up, at that time.
        history.record(closed: "/code/b", lastUsed: at(600))
        #expect(history.lastUsed("/code/b") == at(600))
        let paths: [String] = history.paths
        let same: Bool = paths == ["/code/b", "/code/a"]
        #expect(same, "\(paths)")
        // A close of a project the history no longer holds (cleared while its window was open) adds it at its time.
        history.record(closed: "/code/c", lastUsed: at(450))
        let withC: [String] = history.paths
        let sameWithC: Bool = withC == ["/code/b", "/code/a", "/code/c"]
        #expect(sameWithC, "\(withC)")
    }

    @Test func keepsTheNewestFifty() {
        var history = ProjectHistory()
        for i in 0...ProjectHistory.limit {
            history.record(opened: "/code/p\(i)", at: at(Double(1_000 + i)))
        }
        #expect(ProjectHistory.limit == 50)
        #expect(history.entries.count == 50)
        #expect(history.paths.first == "/code/p50")
        #expect(history.paths.last == "/code/p1")
        #expect(history.lastUsed("/code/p0") == nil)
        // A close past the limit, older than every kept one, is not kept either.
        history.record(closed: "/code/old", lastUsed: at(10))
        #expect(history.entries.count == 50)
        #expect(history.lastUsed("/code/old") == nil)
    }

    @Test func forgetAndClear() {
        var history = ProjectHistory()
        history.record(opened: "/code/a", at: at(100))
        history.record(opened: "/code/b", at: at(200))
        history.forget("/code/b")
        history.forget("/code/none")
        let paths: [String] = history.paths
        let same: Bool = paths == ["/code/a"]
        #expect(same, "\(paths)")
        history.clear()
        #expect(history.entries.isEmpty)
        #expect(history == ProjectHistory())
    }

    @Test func timesAreKeptToTheMillisecondSoAHistoryReadsBackTheSame() {
        // Times as `Date()` gives them, after 2001 and before it: a history read back from the defaults is equal to the
        // one written, and a close at the same time as the stored one changes nothing.
        var unequal: [Double] = []
        var moved: [Double] = []
        for i in 0..<2_000 {
            let late: Double = 781_000_000 + Double(i) * 1_234.567_891_3
            let early: Double = -900_000_000 + Double(i) * 987.654_321_7
            for seconds in [late, early] {
                let date = Date(timeIntervalSinceReferenceDate: seconds)
                var history = ProjectHistory()
                history.record(opened: "/code/a", at: date)
                var loaded = ProjectHistory(stored: history.stored)
                if loaded != history { unequal.append(seconds) }
                loaded.record(closed: "/code/a", lastUsed: date)
                if loaded != history { moved.append(seconds) }
                // Kept to the nearest millisecond: half of one at most, and a little float over it at a tie.
                let kept: Double = history.lastUsed("/code/a")?.timeIntervalSince(date) ?? 1
                if abs(kept) > 0.000_501 { moved.append(seconds) }
            }
        }
        #expect(unequal.isEmpty, "\(unequal.prefix(5))")
        #expect(moved.isEmpty, "\(moved.prefix(5))")
        // A stored time finer than a millisecond reads as the millisecond.
        let fine = ProjectHistory(stored: [["/code/a", 100.123_456_7] as [Any]])
        #expect(fine.lastUsed("/code/a") == at(100.123))
        #expect(ProjectHistory(stored: fine.stored) == fine)
    }

    @Test func aCloseFromAWindowNeverInFrontRecordsNothing() {
        // A window's last time in front starts at `Date.distantPast`: one closed before it was ever in front has no
        // time, and its project keeps the one it was opened at, or stays out of a history that no longer holds it.
        var history = ProjectHistory()
        history.record(opened: "/code/a", at: at(100))
        history.record(closed: "/code/a", lastUsed: .distantPast)
        history.record(closed: "/code/gone", lastUsed: .distantPast)
        let paths: [String] = history.paths
        let same: Bool = paths == ["/code/a"]
        #expect(same, "\(paths)")
        #expect(history.lastUsed("/code/a") == at(100))
        // Nor does any time the defaults could not keep: before 1970, or past `Date.distantFuture`.
        history.record(opened: "/code/b", at: at(-1))
        history.record(closed: "/code/c", lastUsed: at(1e12))
        history.record(opened: "/code/d", at: .distantFuture)
        let kept: [String] = history.paths
        let sameKept: Bool = kept == ["/code/d", "/code/a"]
        #expect(sameKept, "\(kept)")
        #expect(ProjectHistory(stored: history.stored) == history)
        // A stored time that far ahead is no time either.
        let stored: [Any] = [["/code/far", 1e12] as [Any], ["/code/a", 100.0] as [Any]]
        let read: [String] = ProjectHistory(stored: stored).paths
        let sameRead: Bool = read == ["/code/a"]
        #expect(sameRead, "\(read)")
    }

    @Test func anOpenSetsItsOwnTimeEvenAnEarlierOne() {
        // With the clock gone back, an open sets the earlier time, and the list stays newest first by time; so a time
        // once set far ahead by a wrong clock is mended by the project's next open. A close only moves a time forward.
        var history = ProjectHistory()
        history.record(opened: "/code/a", at: at(500))
        history.record(opened: "/code/b", at: at(400))
        #expect(history.paths.first == "/code/a")
        history.record(opened: "/code/a", at: at(100))
        let paths: [String] = history.paths
        let same: Bool = paths == ["/code/b", "/code/a"]
        #expect(same, "\(paths)")
        #expect(history.lastUsed("/code/a") == at(100))
    }

    @Test func readsOnlyTheWellFormedStoredPairs() {
        // One pair a line: a long literal of mixed arrays is slow to type-check.
        var stored: [Any] = []
        stored.append(["/code/a", 100.0] as [Any])
        stored.append([42, 300.0] as [Any]) // not a path
        stored.append(["/code/b"] as [Any]) // no time
        stored.append(["/code/c", -5.0] as [Any]) // before 1970
        stored.append(["/code/d", "200"] as [Any]) // a time that is not a number
        stored.append(["/code/e", true] as [Any]) // nor is a Bool
        stored.append(["code/f", 250.0] as [Any]) // not an absolute path
        stored.append(["", 250.0] as [Any])
        stored.append("/code/g")
        stored.append(["/code/h", 200] as [Any]) // whole seconds, stored as an integer
        stored.append(["/code/a", 50.0] as [Any]) // a second pair for a: its older time is dropped
        stored.append(["/code/i", Double.nan] as [Any])
        stored.append(["/code/j", 100.0, "more"] as [Any]) // not a pair
        let history = ProjectHistory(stored: stored)
        let paths: [String] = history.paths
        let same: Bool = paths == ["/code/h", "/code/a"]
        #expect(same, "\(paths)")
        #expect(history.lastUsed("/code/h") == at(200))
        #expect(history.lastUsed("/code/a") == at(100))
        #expect(ProjectHistory(stored: []) == ProjectHistory())
    }

    @Test func storedPairsReadBackNewestFirstAndCapped() {
        // Written out of order, or by a build with a larger cap: read newest first, the newest 50.
        var stored: [Any] = []
        for i in 0..<60 {
            let pair: [Any] = ["/code/p\(i)", Double(1_000 + i)]
            stored.append(pair)
        }
        let history = ProjectHistory(stored: stored)
        #expect(history.entries.count == 50)
        #expect(history.paths.first == "/code/p59")
        #expect(history.paths.last == "/code/p10")
        // Written back as [path, seconds since 1970] pairs, newest first, and read back the same.
        let written: [[Any]] = history.stored
        #expect(written.count == 50)
        #expect(written.first?.first as? String == "/code/p59")
        #expect(written.first?.last as? Double == 1_059)
        #expect(ProjectHistory(stored: written) == history)
    }

    @Test func storedTiesKeepTheirOrderAndANewerDuplicateWins() {
        var stored: [Any] = []
        stored.append(["/code/a", 100.0] as [Any])
        stored.append(["/code/b", 200.0] as [Any])
        stored.append(["/code/c", 100.0] as [Any])
        stored.append(["/code/b", 300.0] as [Any]) // b's later time wins, where its pair stands
        stored.append(["/code/a", 300.0] as [Any]) // so does a's, after b's: equal times keep the stored order
        stored.append(["/code/c", 100.0] as [Any]) // an equal time for c keeps its first place
        let history = ProjectHistory(stored: stored)
        let paths: [String] = history.paths
        let same: Bool = paths == ["/code/b", "/code/a", "/code/c"]
        #expect(same, "\(paths)")
        #expect(history.lastUsed("/code/a") == at(300))
        #expect(history.lastUsed("/code/c") == at(100))
    }

    @Test func aLongStoredListReadsInTime() {
        // A key holding far more than 50 pairs (`defaults write`, or a build with a larger cap), each path twice.
        var stored: [Any] = []
        for i in 0..<20_000 {
            let pair: [Any] = ["/code/p\(i % 10_000)", Double(1_000 + i)]
            stored.append(pair)
        }
        let clock = ContinuousClock()
        var history = ProjectHistory()
        let elapsed = clock.measure { history = ProjectHistory(stored: stored) }
        #expect(history.entries.count == 50)
        #expect(history.paths.first == "/code/p9999")
        #expect(history.lastUsed("/code/p9999") == at(20_999))
        // Well under 0.1 s in a debug build on a recent Mac; one search a pair took seconds.
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }

    @Test func aCloseIntoAFullHistoryDropsTheOldest() {
        var history = ProjectHistory()
        for i in 0..<ProjectHistory.limit {
            history.record(opened: "/code/p\(i)", at: at(Double(1_000 + i)))
        }
        history.record(closed: "/code/new", lastUsed: at(1_025))
        #expect(history.entries.count == 50)
        #expect(history.lastUsed("/code/p0") == nil)
        #expect(history.lastUsed("/code/new") == at(1_025))
        // Ahead of p25, used at the same moment.
        #expect(history.paths.firstIndex(of: "/code/new") == 24)
        #expect(history.paths.firstIndex(of: "/code/p25") == 25)
    }

    @Test func existingLeavesOutARemovedFolder() throws {
        let base = FileManager.default.temporaryDirectory
        let kept = base.appendingPathComponent("nt-history-kept-\(UUID().uuidString)", isDirectory: true)
        let removed = base.appendingPathComponent("nt-history-removed-\(UUID().uuidString)", isDirectory: true)
        let file = base.appendingPathComponent("nt-history-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: removed, withIntermediateDirectories: true)
        try Data().write(to: file)
        defer {
            try? FileManager.default.removeItem(at: kept)
            try? FileManager.default.removeItem(at: file)
        }
        var history = ProjectHistory()
        history.record(opened: kept.path, at: at(100))
        history.record(opened: removed.path, at: at(200))
        history.record(opened: file.path, at: at(300))
        try FileManager.default.removeItem(at: removed)
        let existing: [String] = history.existing().map(\.path)
        let same: Bool = existing == [kept.path]
        #expect(same, "\(existing)")
        // Reading leaves the history itself as it was: a folder on a drive not mounted now comes back with it.
        #expect(history.entries.count == 3)
    }

    @Test func theStoreKeepsItsOwnKeyBesideRecentProjects() throws {
        let name = "nextterm-project-history-tests-\(getpid())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["/code/recent"], forKey: "recentProjects")
        let store = ProjectHistoryStore(defaults: defaults)
        #expect(store.load() == ProjectHistory())
        var history = ProjectHistory()
        history.record(opened: "/code/a", at: at(100))
        history.record(opened: "/code/b", at: at(200))
        store.save(history)
        #expect(ProjectHistory.key == "projectHistory")
        #expect(defaults.array(forKey: ProjectHistory.key)?.count == 2)
        #expect(store.load() == history)
        // Recent Projects, for File › Open Recent and the Dock menu, is left as it was.
        let recent: [String]? = defaults.stringArray(forKey: "recentProjects")
        let sameRecent: Bool = recent == ["/code/recent"]
        #expect(sameRecent)
        // A value of another type under the key reads as an empty history.
        defaults.set("not a list", forKey: ProjectHistory.key)
        #expect(store.load() == ProjectHistory())
    }

    @Test func aSelfTestKeepsItsHistoryInAScratchSuiteEmptiedAtTheStart() throws {
        // The suite the app's self-test uses is its own, never the app's domain.
        let appSuite: String = ProjectHistoryStore.scratchSuite
        #expect(appSuite != CommandLineLink.bundleIdentifier)
        #expect(appSuite.hasPrefix(CommandLineLink.bundleIdentifier + "."))
        #expect(ProjectHistoryStore.isScratch(appSuite))
        // Here a suite of the test's own, as a run before this one left it.
        let name = CommandLineLink.bundleIdentifier + ".self-test.project-history-tests-\(getpid())"
        let earlier = try #require(UserDefaults(suiteName: name))
        defer { earlier.removePersistentDomain(forName: name) }
        var left = ProjectHistory()
        left.record(opened: "/fixture/earlier", at: at(100))
        ProjectHistoryStore(defaults: earlier).save(left)
        let scratch = try #require(ProjectHistoryStore.scratch(suiteName: name))
        #expect(scratch.load() == ProjectHistory())
        var history = ProjectHistory()
        history.record(opened: "/fixture/shop", at: at(200))
        scratch.save(history)
        #expect(scratch.load() == history)
    }

    @Test func onlyASelfTestsOwnSuiteIsEverEmptied() throws {
        // Decided without emptying anything: a wrong answer here never wipes a real domain on the machine running it.
        let prefix: String = CommandLineLink.bundleIdentifier + ".self-test."
        #expect(ProjectHistoryStore.isScratch(prefix + "project-history-tests-42"))
        var refused: [String] = []
        refused.append("")
        refused.append(CommandLineLink.bundleIdentifier) // the app's settings
        refused.append(UserDefaults.globalDomain)
        refused.append("NextTerm") // a debug executable's own domain, run outside a bundle
        refused.append(Bundle.main.bundleIdentifier ?? "") // the process running this
        refused.append("com.example.other-app")
        refused.append(prefix) // the prefix alone
        refused.append(CommandLineLink.bundleIdentifier + ".self-testing")
        refused.append(prefix + "a/b") // a path
        refused.append(prefix + "..") // nor a way out of the folder the defaults keep
        refused.append("/private/tmp/" + prefix + "x")
        let allowed: [String] = refused.filter { ProjectHistoryStore.isScratch($0) }
        #expect(allowed.isEmpty, "\(allowed)")
        // And `scratch` asks it: a suite of the test's own named otherwise is left as it was.
        let name = "nextterm-project-history-not-scratch-\(getpid())"
        let other = try #require(UserDefaults(suiteName: name))
        defer { other.removePersistentDomain(forName: name) }
        other.set("kept", forKey: "value")
        #expect(ProjectHistoryStore.scratch(suiteName: name) == nil)
        #expect(other.string(forKey: "value") == "kept")
    }
}

/// What the open windows say at each look: which projects a window took, which no window holds any more, and when each
/// of those was last in front.
@Suite struct OpenProjectsTests {
    private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    /// A window `id` on `path`, last in front at `seconds` (never, for nil); `front`: it has the keyboard now.
    private func window(_ id: Int, _ path: String, _ seconds: Double?, front: Bool = false) -> OpenProjects.Window {
        let lastInFront: Date = seconds.map(at) ?? .distantPast
        return OpenProjects.Window(id: id, path: path, lastInFront: lastInFront, isFront: front)
    }

    private func entry(_ path: String, _ seconds: Double) -> ProjectHistory.Entry {
        ProjectHistory.Entry(path: path, lastUsed: at(seconds))
    }

    /// Compared through typed parameters, not inside `#expect`, where array literals are slow to type-check.
    private func same(_ entries: [ProjectHistory.Entry], _ expected: [ProjectHistory.Entry]) -> Bool { entries == expected }
    private func same(_ paths: [String], _ expected: [String]) -> Bool { paths == expected }

    @Test func aFolderAWindowTakesIsOpenedAndOneNoWindowHoldsIsClosed() {
        var open = OpenProjects()
        let first: ProjectHistory.Changes = open.update([window(1, "/code/b", nil), window(2, "/code/a", nil)], at: at(100))
        let opened: [String] = first.opened
        let bothOpened: Bool = opened == ["/code/a", "/code/b"]
        #expect(bothOpened, "\(opened)")
        #expect(first.closed.isEmpty)
        // a's window came to the front at 200 (a look at another change saw it), then closed.
        #expect(open.update([window(1, "/code/b", nil), window(2, "/code/a", 200)], at: at(250)).isEmpty)
        let second: ProjectHistory.Changes = open.update([window(1, "/code/b", nil)], at: at(300))
        #expect(second.opened.isEmpty)
        #expect(same(second.closed, [entry("/code/a", 200)]), "\(second.closed)")
        let paths: [String] = open.paths
        #expect(same(paths, ["/code/b"]), "\(paths)")
        // Nothing changed since: nothing to record.
        #expect(open.update([window(1, "/code/b", nil)], at: at(400)).isEmpty)
    }

    @Test func aProjectStayingOpenRecordsNothingUntilItsLastWindowCloses() {
        var open = OpenProjects()
        _ = open.update([window(1, "/code/a", nil)], at: at(100))
        // Its window came to the front at 200, then at 300: still open, nothing to record.
        #expect(open.update([window(1, "/code/a", 200)], at: at(250)).isEmpty)
        #expect(open.update([window(1, "/code/a", 300)], at: at(350)).isEmpty)
        let changes: ProjectHistory.Changes = open.update([], at: at(400))
        #expect(changes.opened.isEmpty)
        #expect(same(changes.closed, [entry("/code/a", 300)]), "\(changes.closed)")
    }

    @Test func twoWindowsOnOneFolderCloseAsOne() {
        var open = OpenProjects()
        let windows: [OpenProjects.Window] = [window(1, "/code/a", 300), window(2, "/code/a", 200), window(3, "/code/b", 100)]
        let first: ProjectHistory.Changes = open.update(windows, at: at(400))
        #expect(same(first.opened, ["/code/a", "/code/b"]), "\(first.opened)")
        // The window of a's two that was in front last closes: a is still open, and keeps that window's time.
        let one: ProjectHistory.Changes = open.update([window(2, "/code/a", 200), window(3, "/code/b", 100)], at: at(500))
        #expect(one.isEmpty)
        let both: ProjectHistory.Changes = open.update([window(3, "/code/b", 100)], at: at(600))
        #expect(same(both.closed, [entry("/code/a", 300)]), "\(both.closed)")
    }

    @Test func aTimeInFrontSeenSinceTheLastLookIsTheClosesTime() {
        var open = OpenProjects()
        _ = open.update([window(1, "/code/a", 100), window(2, "/code/b", 500)], at: at(150))
        // a's window came to the front at 300 and left it at 350, seen as it happened, not at a look.
        open.sawInFront("/code/a", at: at(300))
        open.sawInFront("/code/a", at: at(350))
        // A time older than one kept changes nothing.
        open.sawInFront("/code/a", at: at(200))
        // b's own window says a later time than the one seen: that one is b's.
        open.sawInFront("/code/b", at: at(400))
        let changes: ProjectHistory.Changes = open.update([], at: at(600))
        let closed: [ProjectHistory.Entry] = changes.closed
        let expected: [ProjectHistory.Entry] = [entry("/code/a", 350), entry("/code/b", 500)]
        let same: Bool = closed == expected
        #expect(same, "\(closed)")
        // A folder seen in front that no window had at a look is neither opened nor closed.
        open.sawInFront("/code/x", at: at(700))
        #expect(open.update([], at: at(800)).isEmpty)
    }

    @Test func aWindowTakingAnotherProjectWhileInFrontClosesTheOldOneThen() {
        // Open Recent in a's window, in this window: it takes b while it has the keyboard, which it got at 100.
        var open = OpenProjects()
        _ = open.update([window(1, "/code/a", 100, front: true)], at: at(150))
        let changes: ProjectHistory.Changes = open.update([window(1, "/code/b", 100, front: true)], at: at(900))
        #expect(same(changes.opened, ["/code/b"]), "\(changes.opened)")
        #expect(same(changes.closed, [entry("/code/a", 900)]), "\(changes.closed)")
        // Behind another window, the old project closes at the window's own last time in front.
        var behind = OpenProjects()
        _ = behind.update([window(1, "/code/a", 100)], at: at(150))
        let later: ProjectHistory.Changes = behind.update([window(1, "/code/b", 100)], at: at(900))
        #expect(same(later.closed, [entry("/code/a", 100)]), "\(later.closed)")
    }

    @Test func aQuitClosesEveryOpenProjectAtItsOwnTime() {
        var open = OpenProjects()
        let windows: [OpenProjects.Window] = [window(1, "/code/a", 100), window(2, "/code/b", 200), window(3, "/code/c", nil)]
        _ = open.update(windows, at: at(250))
        open.sawInFront("/code/a", at: at(260))
        // b's window has the keyboard as Next Term quits: in front until then. c's never came to the front.
        let atQuit: [OpenProjects.Window] = [window(1, "/code/a", 100), window(2, "/code/b", 300, front: true),
                                             window(3, "/code/c", nil)]
        let quit: ProjectHistory.Changes = open.quit(atQuit, at: at(400))
        #expect(quit.opened.isEmpty)
        let closed: [ProjectHistory.Entry] = quit.closed
        var expected: [ProjectHistory.Entry] = [entry("/code/a", 260), entry("/code/b", 400)]
        expected.append(ProjectHistory.Entry(path: "/code/c", lastUsed: .distantPast))
        let same: Bool = closed == expected
        #expect(same, "\(closed)")
        #expect(open.paths.isEmpty)
        // The windows are still there as the app ends: a look then opens nothing again, and closes nothing twice.
        #expect(open.update(atQuit, at: at(410)).isEmpty)
        #expect(open.quit(atQuit, at: at(420)).isEmpty)
    }

    @Test func aQuitAlsoOpensAWindowNoLookSaw() {
        var open = OpenProjects()
        _ = open.update([window(1, "/code/a", 100)], at: at(150))
        let quit: ProjectHistory.Changes = open.quit([window(1, "/code/a", 100), window(2, "/code/d", nil)], at: at(400))
        #expect(same(quit.opened, ["/code/d"]), "\(quit.opened)")
        let closed: [String] = quit.closed.map(\.path)
        let both: Bool = closed == ["/code/a", "/code/d"]
        #expect(both, "\(closed)")
    }

    @Test func recordingTheChangesOpensAtTheLookAndClosesAtTheirTimes() {
        var history = ProjectHistory()
        history.record(opened: "/code/old", at: at(50))
        var open = OpenProjects()
        let opening: ProjectHistory.Changes = open.update([window(1, "/code/a", nil), window(2, "/code/b", nil)], at: at(100))
        history.record(opening, at: at(100))
        #expect(history.lastUsed("/code/a") == at(100))
        #expect(history.lastUsed("/code/b") == at(100))
        // a's window came to the front at 300; b's never did, so its close leaves its open time as it is.
        open.sawInFront("/code/a", at: at(300))
        history.record(open.update([], at: at(500)), at: at(500))
        #expect(history.lastUsed("/code/a") == at(300))
        #expect(history.lastUsed("/code/b") == at(100))
        let paths: [String] = history.paths
        let order: Bool = paths == ["/code/a", "/code/b", "/code/old"]
        #expect(order, "\(paths)")
        // Nothing to record leaves the history as it was.
        let before: ProjectHistory = history
        history.record(ProjectHistory.Changes(opened: [], closed: []), at: at(600))
        #expect(history == before)
    }
}
