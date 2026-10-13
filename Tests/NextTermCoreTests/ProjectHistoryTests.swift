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
        // Here a suite of the test's own, as a run before this one left it.
        let name = "nextterm-project-history-scratch-tests-\(getpid())"
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
        // The app's own domain cannot be a scratch suite.
        #expect(ProjectHistoryStore.scratch(suiteName: "") == nil)
    }
}
