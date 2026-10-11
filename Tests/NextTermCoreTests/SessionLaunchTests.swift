import Foundation
import Testing
@testable import NextTermCore

/// The launch hook's reads and writes in the sessions folder (KTD13, KTD14), in a folder of each test's own: the counter
/// raised and written before anything is read, the snapshot, the marker claimed, the install result taken once, what the
/// decision consumes recorded before the claim goes, and a snapshot set aside.
@Suite struct SessionLaunchTests {
    /// The folder for a made-up app at /Users/x/Applications/Next Term.app, with its lock taken, and its parent to remove.
    func owned() throws -> (files: SessionFiles, parent: URL) {
        let path = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-launch-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        let parent = URL(fileURLWithPath: path)
        let files = try SessionFiles.open(in: parent, bundlePath: "/Users/x/Applications/Next Term.app")
        #expect(files.lock())
        return (files, parent)
    }

    /// The update quit's state file: two windows, unclean, waiting for the fixture's marker.
    func updateSnapshot() -> SessionSnapshot {
        let pane = SessionSnapshot.Pane(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, folder: "/Users/x/app")
        let other = SessionSnapshot.Pane(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, folder: "/Users/x/api")
        let windows = [pane, other].map { (pane: SessionSnapshot.Pane) -> SessionSnapshot.Window in
            SessionSnapshot.Window(project: pane.folder, groups: [SessionSnapshot.Group(root: .pane(pane), focused: pane.id)])
        }
        return SessionSnapshot(header: RestoreFixture.header(), windows: windows)
    }

    func counter(_ files: SessionFiles) -> String? {
        let data: Data? = (try? files.read(RestoreAttempts.fileName, maxSize: RestoreAttempts.maxSize)) ?? nil
        return data.map { String(decoding: $0, as: UTF8.self) }
    }

    func read(_ files: SessionFiles, resumes: Bool = false) -> SessionLaunch.Found {
        SessionLaunch.read(files, version: RestoreFixture.to, resumesAtLaunch: resumes, uptime: 1030, bootSession: RestoreFixture.boot)
    }

    @Test func theCounterIsRaisedAndWrittenBeforeAnythingIsRead() throws {
        let (files, parent) = try owned()
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = read(files)
        #expect(first.facts.lockTaken)
        #expect(first.facts.attempts.count == 1 && first.facts.attemptsWritten)
        #expect(counter(files) == "1\n")
        #expect(first.snapshot == nil && first.facts.header == nil && first.facts.windows == 0)
        #expect(first.facts.marker == nil && first.facts.installResult == nil)
        #expect(first.facts.consumed == ConsumedMarkers())
        #expect(LaunchDecision.restoring(first.facts).kind == .normal)
        #expect(read(files).facts.attempts.count == 2)
        // A counter that does not read counts a restore that did not finish: raised, it holds the next restore at safe mode.
        try files.replace(RestoreAttempts.fileName, with: Data("garbage".utf8))
        let unread = read(files)
        #expect(unread.facts.attempts.count == RestoreAttempts.safeMode)
        #expect(counter(files) == "3\n")
    }

    @Test func itReadsTheSnapshotClaimsTheMarkerAndTakesTheResultOnce() throws {
        let (files, parent) = try owned()
        defer { try? FileManager.default.removeItem(at: parent) }
        let snapshot = updateSnapshot()
        try files.replace(SessionSnapshot.fileName(), with: try snapshot.encoded())
        try files.replace(UpdateMarker.fileName, with: RestoreFixture.updateMarker.data)
        let result = InstallResult(outcome: .installed, marker: RestoreFixture.marker)
        try files.replace(InstallResult.fileName, with: Data(result.json.utf8))
        let found = read(files, resumes: true)
        #expect(found.snapshot?.header == snapshot.header && found.snapshot?.windows.count == 2)
        #expect(found.facts.header == snapshot.header && found.facts.windows == 2)
        #expect(found.facts.marker == RestoreFixture.updateMarker)
        #expect(found.facts.installResult == result)
        #expect(found.facts.resumesAtLaunch)
        #expect(found.facts.version == RestoreFixture.to && found.facts.bootSession == RestoreFixture.boot)
        let decision = LaunchDecision.restoring(found.facts)
        #expect(decision.kind == .restore(.update))
        // The result is read once; the marker waits under its claimed name until the decision is recorded.
        let names: [String] = try files.names()
        #expect(!names.contains(InstallResult.fileName) && !names.contains(UpdateMarker.fileName))
        #expect(names.contains(UpdateMarker.claimedName))
        let again = read(files)
        #expect(again.facts.installResult == nil)
        // The claim left over is used up by the next claim, so the marker never restores twice.
        #expect(again.facts.marker == nil)
        #expect(again.facts.consumed == ConsumedMarkers().adding(RestoreFixture.marker))
    }

    @Test func recordingWritesWhatTheDecisionConsumesThenRemovesTheClaim() throws {
        let (files, parent) = try owned()
        defer { try? FileManager.default.removeItem(at: parent) }
        try files.replace(SessionSnapshot.fileName(), with: try updateSnapshot().encoded())
        try files.replace(UpdateMarker.fileName, with: RestoreFixture.updateMarker.data)
        let found = read(files)
        let decision = LaunchDecision.restoring(found.facts)
        #expect(SessionLaunch.record(decision, consumed: found.facts.consumed, in: files))
        let names: [String] = try files.names()
        #expect(!names.contains(UpdateMarker.claimedName))
        let data: Data? = (try? files.read(ConsumedMarkers.fileName, maxSize: ConsumedMarkers.maxSize)) ?? nil
        #expect(data.flatMap(ConsumedMarkers.parse) == ConsumedMarkers().adding(RestoreFixture.marker))
        // Read again, the marker put back is refused.
        try files.replace(UpdateMarker.fileName, with: RestoreFixture.updateMarker.data)
        let replayed = read(files)
        #expect(LaunchDecision.check(replayed.facts) == .consumed)
        // A record that does not read is replaced by one that holds what this launch used, not kept unread forever.
        try files.replace(ConsumedMarkers.fileName, with: Data("not a record".utf8))
        let unread = read(files)
        #expect(unread.facts.consumed == nil)
        let quitConsent = UUID(uuidString: "5a4b3c2d-1e0f-4a9b-8c7d-6e5f4a3b2c1d")!
        var used = LaunchDecision.restoring(unread.facts)
        used.consumes = [quitConsent]
        #expect(SessionLaunch.record(used, consumed: unread.facts.consumed, in: files))
        let rewritten: Data? = (try? files.read(ConsumedMarkers.fileName, maxSize: ConsumedMarkers.maxSize)) ?? nil
        #expect(rewritten.flatMap(ConsumedMarkers.parse) == ConsumedMarkers().adding(quitConsent))
        // Nothing to consume writes nothing.
        try files.remove(ConsumedMarkers.fileName)
        var none = used
        none.consumes = []
        #expect(SessionLaunch.record(none, consumed: ConsumedMarkers(), in: files))
        #expect(!(try files.names()).contains(ConsumedMarkers.fileName))
    }

    @Test func aSnapshotSetAsideIsMovedOutOfTheWayWithItsPreviousFile() throws {
        let (files, parent) = try owned()
        defer { try? FileManager.default.removeItem(at: parent) }
        #expect(SessionLaunch.setAside(in: files) == nil)
        let state = SessionSnapshot.fileName()
        let first = try updateSnapshot().encoded()
        try files.replace(state, with: first)
        try files.replace(state + SessionFiles.previousSuffix, with: first)
        let name = try #require(SessionLaunch.setAside(in: files))
        #expect(name == SessionLaunch.setAsideName)
        #expect(SessionWriter.load(from: files) == nil)
        let names: [String] = try files.names()
        #expect(!names.contains(state) && !names.contains(state + SessionFiles.previousSuffix))
        let kept: Data? = (try? files.read(name, maxSize: 1 << 20)) ?? nil
        #expect(kept == first)
        // A later one takes the place of the one set aside before.
        var later = updateSnapshot()
        later.header.generation = 9
        let second = try later.encoded()
        try files.replace(state, with: second)
        #expect(SessionLaunch.setAside(in: files) == name)
        let replaced: Data? = (try? files.read(name, maxSize: 1 << 20)) ?? nil
        #expect(replaced == second)
        // The name is no state file's: no launch reads it as one.
        #expect(!SessionLaunch.setAsideName.hasPrefix("state-v"))
    }

    /// Runs `body` while the folder refuses every new file (its mode at 0500), then gives it back its own mode.
    func refusingWrites(_ files: SessionFiles, _ body: () throws -> Void) rethrows {
        chmod(files.url.path, 0o500)
        defer { chmod(files.url.path, 0o700) }
        try body()
    }

    /// The quit's state file under "Resume where I left off", with the box checked: clean, two windows, a consent id.
    func consentedQuit(_ files: SessionFiles) throws {
        var snapshot = updateSnapshot()
        snapshot.header = RestoreFixture.header(clean: true, awaiting: nil)
        snapshot.header.resumeConsent = QuitRestoreTests.consent
        try files.replace(SessionSnapshot.fileName(), with: try snapshot.encoded())
    }

    @Test func aQuitConsentHoldsOnlyOnceItsIDIsOnRecordAndOnlyOnce() throws {
        let (files, parent) = try owned()
        defer { try? FileManager.default.removeItem(at: parent) }
        try consentedQuit(files)
        let found = read(files, resumes: true)
        let decision = LaunchDecision.restoring(found.facts)
        #expect(decision.kind == .restore(.quit) && decision.quitConsent)
        #expect(decision.consumes == [QuitRestoreTests.consent])
        // The record of used ids cannot be written: a launch killed after this one would find the id unused and resume
        // the agents again, so this one does not resume them either.
        refusingWrites(files) {
            let recorded = SessionLaunch.record(decision, consumed: found.facts.consumed, in: files)
            #expect(!recorded)
            #expect(!decision.consentHolds(recorded: recorded))
        }
        // Written: it holds, for this launch alone.
        let recorded = SessionLaunch.record(decision, consumed: found.facts.consumed, in: files)
        #expect(recorded && decision.consentHolds(recorded: recorded))
        let next = LaunchDecision.restoring(read(files, resumes: true).facts)
        #expect(next.kind == .restore(.quit) && !next.quitConsent && !next.consentHolds(recorded: true))
    }

    @Test func aRecordNotWrittenKeepsTheClaimForTheNextLaunchToUseUp() throws {
        let (files, parent) = try owned()
        defer { try? FileManager.default.removeItem(at: parent) }
        try files.replace(SessionSnapshot.fileName(), with: try updateSnapshot().encoded())
        try files.replace(UpdateMarker.fileName, with: RestoreFixture.updateMarker.data)
        let found = read(files)
        let decision = LaunchDecision.restoring(found.facts)
        #expect(decision.kind == .restore(.update) && !decision.quitConsent)
        refusingWrites(files) {
            #expect(!SessionLaunch.record(decision, consumed: found.facts.consumed, in: files))
        }
        let names: [String] = try files.names()
        #expect(names.contains(UpdateMarker.claimedName) && !names.contains(ConsumedMarkers.fileName))
        // The next claim uses the one left up: the marker never restores twice.
        try files.replace(UpdateMarker.fileName, with: RestoreFixture.updateMarker.data)
        let again = read(files)
        #expect(again.facts.consumed == ConsumedMarkers().adding(RestoreFixture.marker))
        #expect(LaunchDecision.check(again.facts) == .consumed)
    }

    /// Safe mode's Try Again counts its try first, as a launch does; a try the folder refuses to count runs nothing.
    @Test func aTryTheFolderRefusesIsNotCounted() throws {
        let (files, parent) = try owned()
        defer { try? FileManager.default.removeItem(at: parent) }
        _ = read(files)
        _ = read(files)
        refusingWrites(files) {
            #expect(SessionLaunch.count(.tryAgain, in: files) == nil)
        }
        #expect(counter(files) == "2\n")
        #expect(SessionLaunch.count(.tryAgain, in: files) == RestoreAttempts(count: 3))
    }

    @Test func eventsMoveTheCounterAsWritten() throws {
        let (files, parent) = try owned()
        defer { try? FileManager.default.removeItem(at: parent) }
        _ = read(files)
        _ = read(files)
        #expect(SessionLaunch.count(.tryAgain, in: files) == RestoreAttempts(count: 3))
        #expect(counter(files) == "3\n")
        #expect(SessionLaunch.count(.settled, in: files) == RestoreAttempts())
        #expect(counter(files) == "0\n")
        // A counter that does not read is raised from where a counter that does not read stands.
        try files.replace(RestoreAttempts.fileName, with: Data("x".utf8))
        #expect(SessionLaunch.count(.tryAgain, in: files) == RestoreAttempts.unread.after(.tryAgain))
    }

    // MARK: the folder a launch takes

    static let app = "/Users/x/Applications/Next Term.app"
    static let backup = "/Users/x/Applications/.next-term-backup.Ab12Cd/Next Term.app"
    static let stranded = InstallResult(outcome: .failedRestoredBackup, marker: RestoreFixture.marker)

    func makeParent() throws -> URL {
        let path = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-launch-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        return URL(fileURLWithPath: path)
    }

    /// The update quit's folder for the app at `app`, as the install script leaves it when neither app could go back in:
    /// the snapshot waiting for the fixture's marker, `result`, and the lock let go. Its key.
    func strand(in parent: URL, app: String = Self.app, result: InstallResult? = Self.stranded) throws -> String {
        let files = try SessionFiles.open(in: parent, bundlePath: app)
        #expect(files.lock())
        try files.replace(SessionSnapshot.fileName(), with: try updateSnapshot().encoded())
        if let result { try files.replace(InstallResult.fileName, with: Data(result.json.utf8)) }
        files.unlock()
        return files.key
    }

    func take(_ parent: URL, bundlePath: String = Self.backup, arguments: [String], appThere: Bool = false) -> SessionFiles? {
        SessionLaunch.takeFolder(in: parent, bundlePath: bundlePath, arguments: arguments) { (_: String) -> Bool in appThere }
    }

    /// Takes the lock just after its holder let it go: a process another test starts meanwhile holds a copy of it a
    /// moment (SessionFilesTests.lockOnceFree). False when it stays held for a second.
    func lockSoon(_ files: SessionFiles) -> Bool {
        for _ in 0..<100 {
            if files.lock() { return true }
            usleep(10_000)
        }
        return false
    }

    func keyArguments(_ key: String) -> [String] {
        [Self.backup + "/Contents/MacOS/Next Term", InstallScript.folderKeyArgument, key]
    }

    /// KTD12: the old app the install script opens from its backup takes the folder the script names by its key, when
    /// that folder's app is gone and it holds the result saying so for the marker its snapshot waits for. The result
    /// stays for the read that follows, which gives the one alert, and the folder keeps the install path as its app's.
    @Test func theOldAppOpenedFromItsBackupTakesTheFolderItsKeyNames() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let key = try strand(in: parent)
        // Tried again while the folder's lock looks held, as `lockSoon` does.
        var tried: SessionFiles?
        for _ in 0..<100 where tried?.key != key {
            tried?.unlock()
            tried = take(parent, arguments: keyArguments(key))
            if tried?.key != key { usleep(10_000) }
        }
        let taken = try #require(tried)
        #expect(taken.key == key && taken.isOwner)
        #expect(SessionFiles.recordedBundlePath(in: taken.url) == canonicalPath(Self.app))
        let found = read(taken)
        #expect(found.facts.installResult == Self.stranded)
        #expect(found.facts.header?.awaitingMarker == RestoreFixture.marker)
        // No folder was made for the backup's own path.
        let folders = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        #expect(folders == [SessionFiles.folderName(key: key)])
    }

    /// Any other use of the argument is ignored, and the app takes its own folder, leaving the named one as it was.
    @Test func aFolderKeyIsIgnoredUnlessItsCheckPasses() throws {
        let own = SessionFiles.key(forBundlePath: Self.backup)
        let cases: [(String, InstallResult?, Bool, (String) -> [String])] = [
            ("its app is there", Self.stranded, true, keyArguments),
            ("no result", nil, false, keyArguments),
            ("the old app was kept", InstallResult(outcome: .failedKeptOld, marker: RestoreFixture.marker), false, keyArguments),
            ("installed", InstallResult(outcome: .installed, marker: RestoreFixture.marker), false, keyArguments),
            ("a result for another quit", InstallResult(outcome: .failedRestoredBackup, marker: RestoreFixture.other), false,
             keyArguments),
            ("no key after the argument", Self.stranded, false, { (_: String) -> [String] in [Self.backup, InstallScript.folderKeyArgument] }),
            ("not a key", Self.stranded, false, { (_: String) -> [String] in [Self.backup, InstallScript.folderKeyArgument, "../x"] }),
            ("no argument", Self.stranded, false, { (_: String) -> [String] in [Self.backup] }),
        ]
        for (name, result, appThere, arguments) in cases {
            let parent = try makeParent()
            defer { try? FileManager.default.removeItem(at: parent) }
            let key = try strand(in: parent, result: result)
            let taken = take(parent, arguments: arguments(key), appThere: appThere)
            #expect(taken?.key == own && taken?.isOwner == true, "\(name)")
            let left = try SessionFiles.open(in: parent, key: key)
            #expect(lockSoon(left), "\(name)")
            let data: Data? = (try? left.read(InstallResult.fileName, maxSize: InstallResult.maxSize)) ?? nil
            #expect(data.flatMap(InstallResult.parse) == result, "\(name): the named folder is left as it was")
        }
    }

    /// A key that names no folder makes none, and a folder another Next Term holds is not taken from it.
    @Test func aFolderKeyNeverMakesAFolderOrTakesAHeldOne() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let missing = SessionFiles.key(forBundlePath: "/Users/x/Gone/Next Term.app")
        let own = try #require(take(parent, arguments: keyArguments(missing)))
        #expect(own.key == SessionFiles.key(forBundlePath: Self.backup))
        own.unlock()
        #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent(SessionFiles.folderName(key: missing)).path))
        let key = try strand(in: parent)
        let holder = try SessionFiles.open(in: parent, key: key)
        #expect(lockSoon(holder))
        let taken = take(parent, arguments: keyArguments(key))
        #expect(taken?.key == SessionFiles.key(forBundlePath: Self.backup))
        #expect(holder.isOwner)
    }

    /// A translocated copy runs from a new random path each launch, so a folder it made would never be read or removed:
    /// it takes none, and makes none.
    @Test func aTranslocatedCopyTakesNoFolder() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let translocated = "/private/var/folders/zz/abc/T/AppTranslocation/0A1B2C3D-4E5F/d/Next Term.app"
        #expect(SessionLaunch.isTranslocated(bundlePath: translocated))
        #expect(!SessionLaunch.isTranslocated(bundlePath: Self.app))
        #expect(take(parent, bundlePath: translocated, arguments: [translocated]) == nil)
        let key = try strand(in: parent)
        #expect(take(parent, bundlePath: translocated, arguments: keyArguments(key)) == nil)
        let folders = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        #expect(folders == [SessionFiles.folderName(key: key)])
    }
}
