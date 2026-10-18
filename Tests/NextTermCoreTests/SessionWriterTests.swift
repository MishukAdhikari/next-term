import Foundation
import Testing
@testable import NextTermCore

/// The sessions folder's one writer: the save gate, the periodic saves and what they leave out, and the quit's last save
/// (the whole session, the tombstone, scrollback and the marker), in a temporary folder of each test's own.
@Suite struct SessionWriterTests {
    typealias Snapshot = SessionSnapshot
    typealias Pane = SessionSnapshot.Pane
    typealias Group = SessionSnapshot.Group
    typealias Window = SessionSnapshot.Window

    static let boot = "2F6C1D0A-5B4E-4C3D-9A8B-7E6F5D4C3B2A"
    static let start = Date(timeIntervalSince1970: 1_790_000_000)
    let stateName = SessionSnapshot.fileName()

    /// A made-up id that reads as its number.
    func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    func ids(_ numbers: Int...) -> [UUID] { numbers.map(id) }

    /// A parent folder for one test, as Application Support/Next Term is for the app. Remove it after.
    func makeParent() throws -> URL {
        let path = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-writer-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        return URL(fileURLWithPath: path)
    }

    /// The folder for a made-up app at /Users/x/Applications/Next Term.app, with its lock taken.
    func owned(in parent: URL) throws -> SessionFiles {
        let files = try SessionFiles.open(in: parent, bundlePath: "/Users/x/Applications/Next Term.app")
        #expect(files.lock())
        return files
    }

    /// A writer started at `start`, its gate open unless `gateOpen` is false.
    func writer(_ files: SessionFiles, after generation: Int = 0, launch: Int = 900, boot: String? = SessionWriterTests.boot,
                limits: Snapshot.Limits = .standard, gateOpen: Bool = true) -> SessionWriter {
        let writer = SessionWriter(files: files, launchID: id(launch), after: generation, bootSession: boot, startedAt: Self.start,
                                   limits: limits)
        if gateOpen { writer.openGate() }
        return writer
    }

    func pane(_ n: Int, folder: String = "/Users/sam/Projects/garden") -> Pane {
        Pane(id: id(n), folder: folder, lastSelected: Date(timeIntervalSince1970: 1_789_999_000 + Double(n)))
    }

    /// One window per entry, each tab holding one pane of that number.
    func windows(_ tabs: [[Int]]) -> [Window] {
        tabs.map { (numbers: [Int]) -> Window in
            Window(project: "/Users/sam/Projects/garden", groups: numbers.map { (n: Int) -> Group in Group(root: .pane(pane(n)), focused: id(n)) })
        }
    }

    func state(_ files: SessionFiles, name: String? = nil) throws -> Snapshot? {
        guard let data = try files.read(name ?? stateName, maxSize: 1 << 20) else { return nil }
        return try Snapshot.decode(data)
    }

    func names(_ files: SessionFiles) throws -> [String] { try files.names() }

    func scrollbackNames(_ files: SessionFiles) throws -> [String] {
        try names(files).filter { (name: String) -> Bool in name.hasPrefix(ScrollbackText.filePrefix) }
    }

    func attempts(_ files: SessionFiles) throws -> RestoreAttempts? {
        try files.read(RestoreAttempts.fileName, maxSize: RestoreAttempts.maxSize).map(RestoreAttempts.parse)
    }

    func marker(_ files: SessionFiles) throws -> UpdateMarker? {
        try files.read(UpdateMarker.fileName, maxSize: UpdateMarker.maxSize).flatMap(UpdateMarker.parse)
    }

    /// Scrollback for the quit, by pane number.
    func scrollback(_ numbers: [Int]) -> [QuitScrollback] {
        numbers.map { (n: Int) -> QuitScrollback in QuitScrollback(id: id(700 + n)) { "pane \(n) said hello\r\n" } }
    }

    /// Every write fails, as on a full disk.
    func failWrites(_ files: SessionFiles) {
        files.calls.write = { _, _, _ in
            errno = ENOSPC
            return -1
        }
    }

    func writtenGeneration(_ save: SessionWriter.Save) -> Int? {
        guard case .wrote(let result) = save else { return nil }
        return result.generation
    }

    // MARK: the save gate

    @Test func savingWaitsForTheGateAndThenWritesAnUncleanSnapshot() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let writer = writer(files, after: 41, gateOpen: false)
        let session = windows([[1, 2]])
        #expect(writer.isWaiting(at: Self.start))
        #expect(writer.save(session, now: Self.start.addingTimeInterval(1)) == .waiting)
        #expect(try state(files) == nil)

        writer.openGate()
        #expect(!writer.isWaiting(at: Self.start))
        let save = writer.save(session, now: Self.start.addingTimeInterval(2))
        #expect(writtenGeneration(save) == 42)
        let saved = try #require(try state(files))
        #expect(!saved.header.clean)
        #expect(saved.header.launchID == id(900))
        #expect(saved.header.generation == 42)
        #expect(saved.header.bootSession == Self.boot)
        #expect(saved.header.awaitingMarker == nil && saved.header.resumeConsent == nil)
        #expect(saved.windows == session)
        #expect(writer.lastSave == SessionWriter.SaveResult(generation: 42, savedAt: Self.start.addingTimeInterval(2), succeeded: true,
                                                            panesLeftOut: []))
    }

    @Test func theGateOpensByItselfAtItsDeadline() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let writer = writer(files, gateOpen: false)
        let session = windows([[1]])
        let justBefore = Self.start.addingTimeInterval(SessionWriter.gateDeadline - 0.5)
        #expect(writer.save(session, now: justBefore) == .waiting)
        let deadline = Self.start.addingTimeInterval(SessionWriter.gateDeadline)
        #expect(!writer.isWaiting(at: deadline))
        #expect(writtenGeneration(writer.save(session, now: deadline)) == 1)
        #expect(try state(files)?.windows == session)
    }

    // MARK: periodic saves

    @Test func theFirstSaveOfALaunchReplacesTheQuitsCleanFileAndGenerationsRiseAcrossLaunches() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let session = windows([[1, 2], [3]])
        let quitting = writer(files, after: 6)
        quitting.openGate()
        _ = quitting.save(session)
        #expect(quitting.finish(.quit(resume: true, consent: false), windows: session).stateWritten)
        let clean = try #require(try state(files))
        #expect(clean.header.clean)
        #expect(clean.header.generation == 8)

        // The next launch: the same windows, but its first save marks the file unclean.
        let next = writer(files, after: clean.header.generation, launch: 901)
        next.openGate()
        #expect(writtenGeneration(next.save(session)) == 9)
        let replaced = try #require(try state(files))
        #expect(!replaced.header.clean)
        #expect(replaced.header.launchID == id(901))
        #expect(replaced.windows == session)
    }

    @Test func aGenerationAtItsCapStaysThereAndNeverOverflows() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let cap = Snapshot.Header.maxGeneration
        // As if read from a file past the cap, which decoding refuses.
        let writer = writer(files, after: Int.max)
        #expect(writtenGeneration(writer.save(windows([[1]]))) == cap)
        #expect(writtenGeneration(writer.save(windows([[1, 2]]))) == cap)
        #expect(writer.finish(.quit(resume: true, consent: false), windows: windows([[1]])).stateWritten)
        #expect(try state(files)?.header.generation == cap)
    }

    @Test func anUnchangedSessionWritesNothing() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let writer = writer(files)
        writer.openGate()
        var session = windows([[1, 2]])
        #expect(writtenGeneration(writer.save(session)) == 1)
        #expect(writer.save(session) == .unchanged)
        #expect(try state(files)?.header.generation == 1)

        session[0].selected = 1
        #expect(writtenGeneration(writer.save(session)) == 2)
        #expect(try state(files)?.windows == session)
    }

    @Test func aStatusDotChangeAloneWritesNothingButIsSavedWithTheNextChange() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let writer = writer(files)
        writer.openGate()
        var first = pane(1)
        first.stateBefore = .idle
        let window = { (pane: Pane) -> [Window] in [Window(groups: [Group(root: .pane(pane), focused: pane.id)])] }
        #expect(writtenGeneration(writer.save(window(first))) == 1)

        first.stateBefore = .working
        first.interrupted = true
        #expect(writer.save(window(first)) == .unchanged)
        #expect(try state(files)?.panes.first?.stateBefore == .idle)

        first.folder = "/Users/sam/Projects/garden/web"
        #expect(writtenGeneration(writer.save(window(first))) == 2)
        let saved = try #require(try state(files)?.panes.first)
        #expect(saved.stateBefore == .working)
        #expect(saved.interrupted)
        #expect(saved.folder == "/Users/sam/Projects/garden/web")
    }

    @Test func thePreviousGoodFileIsKept() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let writer = writer(files)
        writer.openGate()
        let before = windows([[1]])
        _ = writer.save(before)
        _ = writer.save(windows([[1, 2]]))
        let previous = try #require(try state(files, name: stateName + SessionFiles.previousSuffix))
        #expect(previous.windows == before)
        #expect(previous.header.generation == 1)
    }

    @Test func theSaveNamesThePanesTheCountCapsLeaveOut() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        var limits = Snapshot.Limits.standard
        limits.panes = 3
        let writer = writer(files, limits: limits)
        writer.openGate()
        let save = writer.save(windows([[1, 2], [3, 4, 5]]))
        guard case .wrote(let result) = save else {
            Issue.record("nothing written: \(save)")
            return
        }
        #expect(result.succeeded)
        #expect(result.panesLeftOut == ids(4, 5))
        #expect(writer.lastSave?.panesLeftOut == ids(4, 5))
        let saved: [UUID] = try #require(try state(files)).panes.map { (pane: Pane) -> UUID in pane.id }
        let expected: [UUID] = ids(1, 2, 3)
        #expect(saved == expected)
    }

    @Test func aFailedSaveIsReportedAndTriedAgain() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let writer = writer(files)
        writer.openGate()
        let session = windows([[1]])
        failWrites(files)
        guard case .wrote(let failed) = writer.save(session) else {
            Issue.record("the save was not tried")
            return
        }
        #expect(!failed.succeeded)
        #expect(writer.lastSave?.succeeded == false)
        #expect(try state(files) == nil)

        files.calls = SessionFiles.Calls()
        #expect(writtenGeneration(writer.save(session)) != nil)
        #expect(writer.lastSave?.succeeded == true)
        #expect(try state(files)?.windows == session)
    }

    // MARK: the quit

    @Test func aQuitUnderWelcomeLeavesOnlyTheTombstone() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        try files.replace(RestoreAttempts.fileName, with: RestoreAttempts(count: 2).data)
        let writer = writer(files)
        writer.openGate()
        let session = windows([[1, 2]])
        _ = writer.save(session)
        _ = writer.save(windows([[1]]))
        // A temporary file a cut-off save left.
        FileManager.default.createFile(atPath: files.url.appendingPathComponent(".state-v1.json.cut").path, contents: Data("{".utf8))

        let quit = writer.finish(.quit(resume: false, consent: true), windows: session, scrollback: scrollback([1, 2]))
        #expect(quit == SessionWriter.QuitSave(stateWritten: true))
        let tombstone = try #require(try state(files))
        #expect(tombstone.header.clean)
        #expect(tombstone.windows.isEmpty)
        #expect(tombstone.header.generation == 3)
        #expect(tombstone.header.resumeConsent == nil && tombstone.header.awaitingMarker == nil)
        let expected: [String] = [SessionFiles.appPathName, SessionFiles.lockName, RestoreAttempts.fileName, stateName].sorted()
        #expect(try names(files) == expected)
        #expect(try attempts(files) == RestoreAttempts())
    }

    @Test func aTombstoneThatFailsToWriteTakesTheLayoutWithIt() throws {
        let intents: [QuitIntent] = [.quit(resume: false, consent: true), .update(keep: false, from: "0.11.0", to: "0.11.1")]
        for intent in intents {
            let parent = try makeParent()
            defer { try? FileManager.default.removeItem(at: parent) }
            let files = try owned(in: parent)
            let writer = writer(files)
            _ = writer.save(windows([[1]]))
            _ = writer.save(windows([[1, 2]]))
            failWrites(files)
            let quit = writer.finish(intent, windows: windows([[1, 2]]))
            files.calls = SessionFiles.Calls()
            #expect(quit == SessionWriter.QuitSave(), "\(intent)")
            // The user turned the layout down: nothing is left that the next launch would bring it back from as after a
            // crash, so it opens as after a quit under Welcome.
            #expect(SessionWriter.load(from: files) == nil, "\(intent)")
            let left: [String] = try names(files).filter { (name: String) -> Bool in name.hasPrefix(stateName) }
            #expect(left.isEmpty, "\(intent): \(left)")
        }
    }

    @Test func anUpdateQuitWithTheBoxUncheckedLeavesTheTombstoneAndNoMarker() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let writer = writer(files)
        writer.openGate()
        let session = windows([[1]])
        _ = writer.save(session)
        let quit = writer.finish(.update(keep: false, from: "0.11.0", to: "0.11.1"), windows: session, scrollback: scrollback([1]))
        #expect(quit == SessionWriter.QuitSave(stateWritten: true))
        let tombstone = try #require(try state(files))
        #expect(tombstone.header.clean && tombstone.windows.isEmpty)
        #expect(tombstone.header.awaitingMarker == nil && tombstone.header.pendingToVersion == nil)
        #expect(try marker(files) == nil)
        #expect(try scrollbackNames(files).isEmpty)
    }

    @Test func aQuitUnderResumeSavesTheWholeSessionCleanWithItsConsentAndScrollback() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        try files.replace(RestoreAttempts.fileName, with: RestoreAttempts(count: 2).data)
        let writer = writer(files)
        writer.openGate()
        _ = writer.save(windows([[1], [2]]))
        _ = writer.save(windows([[1]]))
        var named = pane(1)
        named.scrollback = id(701)
        let session: [Window] = [Window(groups: [Group(root: .pane(named), focused: id(1))])] + windows([[2]])

        let quit = writer.finish(.quit(resume: true, consent: true), windows: session, scrollback: scrollback([1, 2]))
        #expect(quit.stateWritten)
        #expect(quit.awaitedMarker == nil && !quit.markerWritten)
        #expect(quit.scrollback == ids(701, 702))
        let saved = try #require(try state(files))
        #expect(saved.header.clean)
        #expect(saved.windows == session)
        let consent = try #require(saved.header.resumeConsent)
        #expect(quit.resumeConsent == consent)
        #expect(saved.header.awaitingMarker == nil && saved.header.pendingToVersion == nil)
        // Named for the snapshot's launch id, as the next launch's quit restore reads them.
        #expect(saved.header.scrollbackQuit == id(900))
        let expected: [String] = [ScrollbackText.fileName(quit: id(900), id: id(701)), ScrollbackText.fileName(quit: id(900), id: id(702))]
        #expect(try scrollbackNames(files) == expected.sorted())
        let facts = RestoreFacts(lockTaken: true, header: saved.header, windows: saved.windows.count, attempts: RestoreAttempts(count: 1),
                                 attemptsWritten: true, uptime: 5_060, bootSession: Self.boot, version: "0.11.0", resumesAtLaunch: true)
        let decision = LaunchDecision.restoring(facts)
        #expect(decision.kind == .restore(.quit))
        #expect(decision.scrollbackQuit == saved.header.scrollbackQuit)
        let taken = ScrollbackText.take(Set(ids(701)), quit: id(900), from: files)
        #expect(taken == [id(701): "pane 1 said hello\r\n"])
        #expect(!(try names(files)).contains(stateName + SessionFiles.previousSuffix))
        #expect(try marker(files) == nil)
        #expect(try attempts(files) == RestoreAttempts())
    }

    @Test func aQuitUnderResumeWithoutTheConsentHoldsNoConsentID() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let writer = writer(files)
        let quit = writer.finish(.quit(resume: true, consent: false), windows: windows([[1]]))
        #expect(quit.stateWritten && quit.resumeConsent == nil)
        let saved = try #require(try state(files))
        #expect(saved.header.clean)
        #expect(saved.header.resumeConsent == nil)
        #expect(saved.panes.count == 1)
    }

    @Test func anUpdateQuitKeptSavesTheSessionThenScrollbackThenTheMarkerItWaitsFor() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        try files.replace(RestoreAttempts.fileName, with: RestoreAttempts(count: 2).data)
        let writer = writer(files, after: 10)
        writer.openGate()
        let session = windows([[1, 2]])
        _ = writer.save(session)

        let quit = writer.finish(.update(keep: true, from: "0.11.0", to: "0.11.1"), windows: session, scrollback: scrollback([2, 1]),
                                 uptime: 5_000)
        #expect(quit.stateWritten && quit.markerWritten)
        #expect(quit.scrollback == ids(702, 701))
        let saved = try #require(try state(files))
        #expect(!saved.header.clean)
        #expect(saved.header.generation == 12)
        #expect(saved.header.pendingToVersion == "0.11.1")
        #expect(saved.header.resumeConsent == nil)
        let awaited = try #require(saved.header.awaitingMarker)
        #expect(quit.awaitedMarker == awaited)
        let marker = try #require(try marker(files))
        #expect(marker == UpdateMarker(id: awaited, launchID: id(900), fromVersion: "0.11.0", toVersion: "0.11.1", bootSession: Self.boot,
                                       uptime: 5_000))
        // Named for the marker, as the update restore reads them: the quit the header names for its scrollback.
        #expect(saved.header.scrollbackQuit == awaited)
        let expected: [String] = [ScrollbackText.fileName(quit: awaited, id: id(701)), ScrollbackText.fileName(quit: awaited, id: id(702))]
        #expect(try scrollbackNames(files) == expected.sorted())
        #expect(try attempts(files) == RestoreAttempts())

        // The relaunch, a minute on, in the same boot, as the new version: the update's restore.
        let facts = RestoreFacts(lockTaken: true, marker: marker, header: saved.header, windows: saved.windows.count,
                                 consumed: ConsumedMarkers(), attempts: RestoreAttempts(count: 1), attemptsWritten: true,
                                 uptime: 5_060, bootSession: Self.boot, version: "0.11.1")
        let decision = LaunchDecision.restoring(facts)
        #expect(decision.marker == .valid)
        #expect(decision.kind == .restore(.update))
        #expect(decision.scrollback == .read)
        #expect(decision.scrollbackQuit == saved.header.scrollbackQuit)
    }

    @Test func aFailedFinalWriteLeavesNoMarkerAndNoScrollback() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let writer = writer(files)
        writer.openGate()
        let session = windows([[1]])
        _ = writer.save(session)
        failWrites(files)
        let quit = writer.finish(.update(keep: true, from: "0.11.0", to: "0.11.1"), windows: session, scrollback: scrollback([1]))
        #expect(quit == SessionWriter.QuitSave())
        files.calls = SessionFiles.Calls()
        #expect(try marker(files) == nil)
        #expect(try scrollbackNames(files).isEmpty)
        // The last periodic save stays: unclean, waiting for no marker, so the relaunch is a crash restore.
        let left = try #require(try state(files))
        #expect(!left.header.clean && left.header.awaitingMarker == nil)
    }

    @Test func aFailedFinalWriteAtAQuitUnderResumeLeavesTheLastPeriodicSaveUnclean() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        try files.replace(RestoreAttempts.fileName, with: RestoreAttempts(count: 2).data)
        let writer = writer(files)
        writer.openGate()
        let session = windows([[1, 2]])
        _ = writer.save(session)
        failWrites(files)
        let quit = writer.finish(.quit(resume: true, consent: true), windows: session, scrollback: scrollback([1]))
        #expect(!quit.stateWritten && quit.resumeConsent == nil)
        files.calls = SessionFiles.Calls()
        let left = try #require(try state(files))
        #expect(!left.header.clean)
        #expect(left.header.generation == 1)
        #expect(left.header.resumeConsent == nil)
        #expect(left.windows == session)
        // Not a clean quit: the counter stays.
        #expect(try attempts(files) == RestoreAttempts(count: 2))
        let facts = RestoreFacts(lockTaken: true, header: left.header, windows: left.windows.count, attempts: RestoreAttempts(count: 1),
                                 attemptsWritten: true, uptime: 100, bootSession: Self.boot, version: "0.11.0")
        #expect(LaunchDecision.restoring(facts).kind == .restore(.crash))
    }

    @Test func aFailedMarkerWriteKeepsTheSessionAndItsScrollback() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        try files.replace(RestoreAttempts.fileName, with: RestoreAttempts(count: 2).data)
        let writer = writer(files)
        let session = windows([[1]])
        // Only the marker's bytes fail to write.
        files.calls.write = { descriptor, bytes, count in
            if UpdateMarker.parse(Data(bytes: bytes, count: count)) != nil {
                errno = EIO
                return -1
            }
            return Darwin.write(descriptor, bytes, count)
        }
        let quit = writer.finish(.update(keep: true, from: "0.11.0", to: "0.11.1"), windows: session, scrollback: scrollback([1]))
        #expect(quit.stateWritten && !quit.markerWritten)
        #expect(quit.scrollback == ids(701))
        // The install script's result still names the marker the snapshot waits for.
        let saved = try #require(try state(files))
        #expect(quit.awaitedMarker != nil && quit.awaitedMarker == saved.header.awaitingMarker)
        #expect(try marker(files) == nil)
        #expect(try attempts(files) == RestoreAttempts(count: 2))
        // The relaunch, its first try, finds no marker: a crash restore, which deletes the scrollback unread.
        let facts = RestoreFacts(lockTaken: true, header: saved.header, windows: saved.windows.count, attempts: RestoreAttempts(count: 1),
                                 attemptsWritten: true, uptime: 100, bootSession: Self.boot, version: "0.11.1")
        let decision = LaunchDecision.restoring(facts)
        #expect(decision.marker == .missing)
        #expect(decision.kind == .restore(.crash))
        #expect(decision.scrollback == .deleteUnread)
    }

    @Test func noMarkerIsWrittenWithoutABootSessionOrWithVersionsItCouldNotName() throws {
        let cases: [(boot: String?, from: String, to: String)] = [
            (nil, "0.11.0", "0.11.1"),
            (Self.boot, "0.11.0", "0.11.1 beta"),
            (Self.boot, "", "0.11.1"),
        ]
        for (boot, from, to) in cases {
            let parent = try makeParent()
            defer { try? FileManager.default.removeItem(at: parent) }
            let files = try owned(in: parent)
            let quit = writer(files, boot: boot).finish(.update(keep: true, from: from, to: to), windows: windows([[1]]))
            #expect(quit.stateWritten && !quit.markerWritten, "\(String(describing: boot)) \(from) → \(to)")
            #expect(try marker(files) == nil)
        }
    }

    @Test func scrollbackPastTheTimeBudgetIsDroppedButTheStateAndMarkerAreNot() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let writer = writer(files)
        let deadline = Self.start.addingTimeInterval(3)
        let clock = Clock(times: [Self.start.addingTimeInterval(1), deadline, deadline.addingTimeInterval(1)])
        let quit = writer.finish(.update(keep: true, from: "0.11.0", to: "0.11.1"), windows: windows([[1, 2, 3]]),
                                 scrollback: scrollback([1, 2, 3]), deadline: deadline, clock: clock.now)
        #expect(quit.stateWritten && quit.markerWritten)
        #expect(quit.scrollback == ids(701))
        #expect(try scrollbackNames(files).count == 1)
    }

    @Test func scrollbackTheBudgetDropsIsNamedButReadsAsNone() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let writer = writer(files)
        let panes: [Pane] = [1, 2].map { (n: Int) -> Pane in
            var named = pane(n)
            named.scrollback = id(700 + n)
            return named
        }
        let groups: [Group] = panes.map { (pane: Pane) -> Group in Group(root: .pane(pane), focused: pane.id) }
        let deadline = Self.start.addingTimeInterval(3)
        let clock = Clock(times: [Self.start.addingTimeInterval(1), deadline])
        let quit = writer.finish(.quit(resume: true, consent: false), windows: [Window(groups: groups)], scrollback: scrollback([1, 2]),
                                 deadline: deadline, clock: clock.now)
        #expect(quit.scrollback == ids(701))
        // The state file, written first, names both; the one past the budget was never written, and reads as none.
        let named: [UUID] = try #require(try state(files)).panes.compactMap(\.scrollback)
        #expect(named == ids(701, 702))
        let taken = ScrollbackText.take(Set(ids(701, 702)), quit: id(900), from: files)
        #expect(taken == [id(701): "pane 1 said hello\r\n"])
    }

    /// Hands out the times given, then the last one again.
    final class Clock: @unchecked Sendable {
        private var times: [Date]
        init(times: [Date]) { self.times = times }
        func now() -> Date { times.count > 1 ? times.removeFirst() : times[0] }
    }

    @Test func aQuitBeforeTheGateOpensLeavesTheSnapshotTheRestoreReadsFrom() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let quitting = writer(files)
        let session = windows([[1, 2]])
        #expect(quitting.finish(.quit(resume: true, consent: true), windows: session).stateWritten)

        // The next launch quits while its restore is still building: the quit's file stays as it was.
        let next = writer(files, after: 1, launch: 901, gateOpen: false)
        let quit = next.finish(.quit(resume: false, consent: false), windows: [], now: Self.start.addingTimeInterval(1))
        #expect(quit == SessionWriter.QuitSave())
        #expect(next.save(windows([[3]]), now: Self.start.addingTimeInterval(20)) == .finished)
        let kept = try #require(try state(files))
        #expect(kept.header.launchID == id(900) && kept.header.clean && kept.windows == session)
    }

    @Test func afterTheQuitsSaveNothingIsWrittenAgain() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let writer = writer(files)
        writer.openGate()
        let session = windows([[1]])
        #expect(writer.finish(.quit(resume: true, consent: false), windows: session).stateWritten)
        #expect(writer.save(windows([[1, 2]])) == .finished)
        #expect(writer.finish(.quit(resume: false, consent: false), windows: session) == SessionWriter.QuitSave())
        let saved = try #require(try state(files))
        #expect(saved.header.generation == 1 && saved.header.clean && saved.windows == session)
    }

    @Test func aPeriodicSaveInFlightAtTheQuitNeverLandsAfterTheFinalFile() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let writer = writer(files)
        writer.openGate()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let blocked = Flag()
        // The periodic save's first write waits until the quit is under way.
        files.calls.write = { descriptor, bytes, count in
            if blocked.take() {
                entered.signal()
                release.wait()
            }
            return Darwin.write(descriptor, bytes, count)
        }
        let done = DispatchGroup()
        DispatchQueue.global().async(group: done) { _ = writer.save(windows([[1]])) }
        entered.wait()
        let quitting = DispatchSemaphore(value: 0)
        let result = Box<SessionWriter.QuitSave>()
        DispatchQueue.global().async(group: done) {
            quitting.signal()
            result.value = writer.finish(.update(keep: true, from: "0.11.0", to: "0.11.1"), windows: windows([[1, 2]]))
        }
        quitting.wait()
        usleep(50_000)
        release.signal()
        done.wait()
        // A save that comes after the quit's writes nothing.
        #expect(writer.save(windows([[3]])) == .finished)

        let quit = try #require(result.value)
        #expect(quit.markerWritten)
        let saved = try #require(try state(files))
        #expect(saved.header.generation == 2)
        #expect(saved.panes.count == 2)
        #expect(saved.header.awaitingMarker == quit.awaitedMarker)
        let marker = try #require(try marker(files))
        #expect(marker.id == saved.header.awaitingMarker)
        #expect(marker.launchID == saved.header.launchID)
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = true
        /// True once: the first time it is asked.
        func take() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let was = armed
            armed = false
            return was
        }
    }

    final class Box<Value>: @unchecked Sendable {
        var value: Value?
    }

    // MARK: what the launch reads, and the intents

    @Test func theLaunchReadsTheSnapshotOrItsPreviousFile() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        #expect(SessionWriter.load(from: files) == nil)
        let writer = writer(files, after: 4)
        writer.openGate()
        _ = writer.save(windows([[1]]))
        _ = writer.save(windows([[1, 2]]))
        #expect(SessionWriter.load(from: files)?.header.generation == 6)
        try files.replace(stateName, with: Data("{\"header\":".utf8))
        let fallback = try #require(SessionWriter.load(from: files))
        #expect(fallback.header.generation == 5)
        #expect(fallback.panes.count == 1)
    }

    @Test func aSnapshotReadFromThePreviousFileIsUncleanAndHoldsNoConsent() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let session = windows([[1, 2]])
        let quit = writer(files).finish(.quit(resume: true, consent: true), windows: session)
        let consent = try #require(quit.resumeConsent)
        let current = try #require(SessionWriter.load(from: files))
        #expect(current.header.clean && current.header.resumeConsent == consent)

        // The next launch's first save keeps the quit's file as the previous one, consent and all.
        let next = writer(files, after: 1, launch: 901)
        _ = next.save(windows([[3]]))
        let kept = try #require(try state(files, name: stateName + SessionFiles.previousSuffix))
        #expect(kept.header.clean && kept.header.resumeConsent == consent)

        // That launch is killed between its save's two renames, or its file is damaged: the launch after reads the quit's
        // layout as a crash left it, and no agent resumes by itself.
        for damage in ["cut off", "damaged"] {
            if damage == "cut off" {
                try files.remove(stateName)
            } else {
                try files.replace(stateName, with: Data("{\"header\":".utf8))
            }
            let read = try #require(SessionWriter.load(from: files), "\(damage)")
            #expect(read.header.launchID == id(900) && read.windows == session, "\(damage)")
            #expect(!read.header.clean, "\(damage)")
            #expect(read.header.resumeConsent == nil, "\(damage)")
            let facts = RestoreFacts(lockTaken: true, header: read.header, windows: read.windows.count, attempts: RestoreAttempts(count: 1),
                                     attemptsWritten: true, uptime: 100, bootSession: Self.boot, version: "0.11.0")
            #expect(LaunchDecision.restoring(facts).kind == .restore(.crash), "\(damage)")
        }
    }

    /// A save killed part-way (SIGKILL) leaves the folder as it was at that moment: at any write or flush of the save,
    /// between its two renames, or after. The launch after reads a state file from each: the one before, or the new one.
    @Test func aSaveKilledAtAnyPointLeavesAStateThatDecodes() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let writer = writer(files)
        _ = writer.save(windows([[1]]))
        let moments = Moments(folder: files.url)
        files.calls.write = { descriptor, bytes, count in
            moments.take()
            return Darwin.write(descriptor, bytes, count)
        }
        files.calls.fcntl = { descriptor, command in
            moments.take()
            return Darwin.fcntl(descriptor, command)
        }
        _ = writer.save(windows([[1, 2]]))
        files.calls = SessionFiles.Calls()
        moments.take()
        var seen = moments.all
        #expect(seen.count >= 3)
        // Between the renames: the file before moved aside, the new one not yet in its place.
        if let flushed = seen.last(where: { (files: [String: Data]) -> Bool in files.keys.contains { $0.hasPrefix(".") } }),
           let before = flushed[stateName] {
            var between = flushed
            between[stateName] = nil
            between[stateName + SessionFiles.previousSuffix] = before
            seen.append(between)
        } else {
            Issue.record("no moment held the save's temporary file")
        }
        for (index, moment) in seen.enumerated() {
            let copy = try makeParent()
            defer { try? FileManager.default.removeItem(at: copy) }
            let restored = try owned(in: copy)
            for (name, data) in moment {
                let path = restored.url.appendingPathComponent(name).path
                #expect(FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]))
            }
            let read = SessionWriter.load(from: restored)
            let count = read?.panes.count ?? 0
            #expect(count == 1 || count == 2, "moment \(index): \(moment.keys.sorted())")
        }
    }

    /// The files in a folder, by name, each time `take` is called: as a kill then would leave them.
    final class Moments: @unchecked Sendable {
        private let folder: URL
        private let lock = NSLock()
        private var taken: [[String: Data]] = []

        init(folder: URL) { self.folder = folder }

        var all: [[String: Data]] {
            lock.lock()
            defer { lock.unlock() }
            return taken
        }

        func take() {
            let skipped: Set<String> = [SessionFiles.lockName, SessionFiles.appPathName]
            let names: [String] = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            var files: [String: Data] = [:]
            for name in names where !skipped.contains(name) {
                files[name] = FileManager.default.contents(atPath: folder.appendingPathComponent(name).path)
            }
            lock.lock()
            taken.append(files)
            lock.unlock()
        }
    }

    @Test func theQuitReadsTheScrollbackOfTheTabInViewFirstThenEachWindowsTabInFront() {
        // Tabs 1-6: 4 is in view, 2 and 5 are their windows' tabs in front (5 in view too).
        let tabs: [Int] = [1, 2, 3, 4, 5, 6]
        let visible: Set<Int> = [4, 5]
        let fronts: Set<Int> = [2, 5]
        let order: [Int] = SessionWriter.scrollbackOrder(tabs, visible: { (tab: Int) -> Bool in visible.contains(tab) },
                                                         inFront: { (tab: Int) -> Bool in fronts.contains(tab) })
        let expected: [Int] = [4, 5, 2, 1, 3, 6]
        #expect(order == expected)
        let none = SessionWriter.scrollbackOrder(tabs, visible: { (_: Int) -> Bool in false }, inFront: { (_: Int) -> Bool in false })
        #expect(none == tabs)
    }

    @Test func aLogoutRestartOrShutdownStartsNoInstall() {
        #expect(!QuitReason.systemSession.installsStagedUpdate)
        let others: [QuitReason] = QuitReason.allCases.filter { (reason: QuitReason) -> Bool in reason != .systemSession }
        let installs: Bool = others.allSatisfy { (reason: QuitReason) -> Bool in reason.installsStagedUpdate }
        #expect(installs)
    }

    @Test func aQuitsIntentFollowsAtLaunchAndOnlyAUsersQuitCarriesTheConsent() {
        var resume = LaunchSettings()
        resume.opens = .lastProjects
        var welcome = LaunchSettings()
        welcome.opens = .welcome
        #expect(QuitIntent.ordinary(reason: .user, settings: resume, consent: true) == .quit(resume: true, consent: true))
        // Never chosen is Resume, the default: a quit that asked nothing still saves what to bring back.
        #expect(QuitIntent.ordinary(reason: .user, settings: LaunchSettings(), consent: false) == .quit(resume: true, consent: false))
        #expect(QuitIntent.ordinary(reason: .user, settings: resume, consent: false) == .quit(resume: true, consent: false))
        #expect(QuitIntent.ordinary(reason: .user, settings: welcome, consent: true) == .quit(resume: false, consent: false))
        // A logout, restart or shutdown, and an update relaunch, asked nothing that could give it.
        #expect(QuitIntent.ordinary(reason: .systemSession, settings: resume, consent: true) == .quit(resume: true, consent: false))
        #expect(QuitIntent.ordinary(reason: .updateRelaunch, settings: resume, consent: true) == .quit(resume: true, consent: false))
        // The plain self-test never saves.
        #expect(QuitIntent.ordinary(reason: .selfTest, settings: resume, consent: true) == nil)

        #expect(QuitIntent.update(keep: true, from: "1", to: "2").savesSession)
        #expect(!QuitIntent.update(keep: false, from: "1", to: "2").savesSession)
        #expect(QuitIntent.quit(resume: true, consent: false).savesSession)
        #expect(!QuitIntent.quit(resume: false, consent: true).savesSession)
    }

    @Test func theQuitsTimeBudgetGrowsWithTheTabsUpToItsCap() {
        #expect(SessionWriter.quitBudget(tabs: 0) == 1)
        #expect(SessionWriter.quitBudget(tabs: 10) == 2)
        #expect(SessionWriter.quitBudget(tabs: 20) == 3)
        #expect(SessionWriter.quitBudget(tabs: 500) == 4)
    }
}
