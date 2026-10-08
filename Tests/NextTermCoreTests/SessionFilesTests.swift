import Foundation
import Testing
@testable import NextTermCore

/// The sessions folder, made in a temporary folder of each test's own: its lock, its private files, the claim, the
/// sweeps, and what a read refuses.
@Suite struct SessionFilesTests {
    /// A parent folder for one test, as Application Support/Next Term is for the app. Remove it after.
    func makeParent() throws -> URL {
        let path = canonicalPath(FileManager.default.temporaryDirectory.path) + "/nt-sessions-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        return URL(fileURLWithPath: path)
    }

    /// The folder for a made-up app at /Users/x/Applications/Next Term.app, with its lock taken.
    func owned(in parent: URL, app: String = "/Users/x/Applications/Next Term.app") throws -> SessionFiles {
        let files = try SessionFiles.open(in: parent, bundlePath: app)
        #expect(files.lock())
        return files
    }

    /// Takes the lock just after its holder let it go, waiting out a process another test starts meanwhile: the kernel
    /// copies every descriptor into a new process, close-on-exec ones too, and holds the lock with them until the new
    /// process starts its program. False when it stays held for a second.
    func lockOnceFree(_ files: SessionFiles) -> Bool {
        for _ in 0..<100 {
            if files.lock() { return true }
            usleep(10_000)
        }
        return false
    }

    func mode(_ path: String) -> Int? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Int(info.st_mode & 0o7777)
    }

    func isLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }

    func text(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
    }

    func put(_ text: String, _ path: String, mode: Int = 0o600) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    func failure(_ body: () throws -> Void) -> SessionFiles.Failure? {
        do {
            try body()
            return nil
        } catch {
            return error as? SessionFiles.Failure
        }
    }

    // MARK: the folder

    @Test func eachCopyOfTheAppHasAPrivateFolderNamedForItsPath() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let key = SessionFiles.key(forBundlePath: "/Users/x/Applications/Next Term.app")
        #expect(SessionFiles.isKey(key) && key.count == 32)
        #expect(files.key == key && files.url.lastPathComponent == "sessions-\(key).noindex")
        #expect(files.url.deletingLastPathComponent().path == parent.path)
        #expect(PrivateFolder.isPrivate(files.url.path))
        let excluded = try files.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(excluded == true)
        // Another copy of the app, another folder; the same copy, the same one.
        let other = SessionFiles.key(forBundlePath: "/Users/x/Downloads/Next Term.app")
        #expect(other != key && SessionFiles.key(forBundlePath: "/Users/x/Applications/Next Term.app") == key)
        #expect(!SessionFiles.isKey("../" + key.dropFirst(3)) && !SessionFiles.isKey(key.uppercased()) && !SessionFiles.isKey(""))
        // The app's path is recorded once the lock is taken, for the sweep of folders whose app is gone.
        #expect(SessionFiles.recordedBundlePath(in: files.url) == "/Users/x/Applications/Next Term.app")
        #expect(mode(files.url.appendingPathComponent(SessionFiles.appPathName).path) == 0o600)
    }

    @Test func theKeyFollowsTheAppsRealPath() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let app = parent.appendingPathComponent("Next Term.app").path
        try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: parent.path + "/link.app", withDestinationPath: app)
        #expect(SessionFiles.key(forBundlePath: parent.path + "/link.app") == SessionFiles.key(forBundlePath: app))
    }

    @Test func aLinkOrAnotherUsersFolderAtItsNameIsRefused() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let key = SessionFiles.key(forBundlePath: "/Users/x/Applications/Next Term.app")
        let name = SessionFiles.folderName(key: key)
        // A link planted at its name, to a folder that would pass: never followed, never removed.
        let elsewhere = parent.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(atPath: parent.path + "/" + name, withDestinationPath: elsewhere.path)
        #expect(failure { _ = try SessionFiles.open(in: parent, key: key) } == .notPrivate)
        let untouched = try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty
        #expect(isLink(parent.path + "/" + name) && untouched)
        try FileManager.default.removeItem(atPath: parent.path + "/" + name)
        // A file at its name.
        try put("x", parent.path + "/" + name)
        #expect(failure { _ = try SessionFiles.open(in: parent, key: key) } == .notPrivate)
        try FileManager.default.removeItem(atPath: parent.path + "/" + name)
        // Its own folder, opened to others: closed again.
        try FileManager.default.createDirectory(atPath: parent.path + "/" + name, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        let files = try SessionFiles.open(in: parent, key: key)
        #expect(mode(files.url.path) == 0o700)
        // Another user's: refused.
        #expect(failure { _ = try SessionFiles.open(in: parent, key: key, owner: geteuid() + 1) } == .notPrivate)
        // A key that is not one names no folder.
        #expect(failure { _ = try SessionFiles.open(in: parent, key: "../elsewhere") } == .badName)
    }

    // MARK: the lock

    @Test func onlyOneHolderOfTheLockAtATime() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = try owned(in: parent)
        let second = try SessionFiles.open(in: parent, bundlePath: "/Users/x/Applications/Next Term.app")
        #expect(first.isOwner && !second.lock() && !second.isOwner)
        // Taking it again is a no-op for its holder.
        #expect(first.lock())
        first.unlock()
        #expect(!first.isOwner && lockOnceFree(second) && second.isOwner)
        #expect(!first.lock())
    }

    @Test func closingAnotherDescriptorToTheLockFileKeepsTheLock() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = try owned(in: parent)
        // Something else in the process opens the lock file and closes it: an fcntl lock would be gone now.
        let other = open(first.url.appendingPathComponent(SessionFiles.lockName).path, O_RDONLY | O_CLOEXEC)
        #expect(other >= 0)
        close(other)
        let second = try SessionFiles.open(in: parent, bundlePath: "/Users/x/Applications/Next Term.app")
        #expect(!second.lock())
    }

    @Test func aProcessStartedAfterTheLockDoesNotHoldIt() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = try owned(in: parent)
        // A shell started in a tab: posix_spawn hands it every descriptor not marked close-on-exec.
        var child: pid_t = 0
        let arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
        defer { arguments.forEach { free($0) } }
        #expect(posix_spawn(&child, "/bin/sleep", nil, nil, arguments, nil) == 0)
        defer {
            kill(child, SIGKILL)
            var status: Int32 = 0
            waitpid(child, &status, 0)
        }
        // The app quits (its descriptor closes) while the child runs on.
        first.unlock()
        let second = try SessionFiles.open(in: parent, bundlePath: "/Users/x/Applications/Next Term.app")
        #expect(lockOnceFree(second))
    }

    @Test func somethingPlantedAtTheLocksNameIsRemovedNotLocked() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try SessionFiles.open(in: parent, bundlePath: "/Users/x/Applications/Next Term.app")
        let lock = files.url.appendingPathComponent(SessionFiles.lockName).path
        let victim = parent.appendingPathComponent("victim").path
        try put("theirs", victim)
        // A link (never followed), a named pipe (never waited on) and an empty folder: each goes, and a plain file takes
        // its place.
        let plant: [(String, () throws -> Void)] = [
            ("link", { try FileManager.default.createSymbolicLink(atPath: lock, withDestinationPath: victim) }),
            ("pipe", { #expect(mkfifo(lock, 0o600) == 0) }),
            ("folder", { try FileManager.default.createDirectory(atPath: lock, withIntermediateDirectories: false) }),
        ]
        for (kind, planted) in plant {
            try planted()
            #expect(files.lock(), "\(kind)")
            var info = stat()
            #expect(lstat(lock, &info) == 0 && info.st_mode & S_IFMT == S_IFREG, "\(kind)")
            files.unlock()
            try FileManager.default.removeItem(atPath: lock)
        }
        #expect(text(victim) == "theirs" && mode(victim) == 0o600)
    }

    @Test func onlyTheHolderReadsWritesOrClaims() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let holder = try owned(in: parent)
        try holder.replace("state-v1.json", with: Data("{}".utf8))
        let other = try SessionFiles.open(in: parent, bundlePath: "/Users/x/Applications/Next Term.app")
        #expect(!other.lock())
        #expect(failure { _ = try other.read("state-v1.json", maxSize: 100) } == .notOwner)
        #expect(failure { try other.replace("state-v1.json", with: Data("x".utf8)) } == .notOwner)
        #expect(failure { try other.create("scrollback", with: Data("x".utf8)) } == .notOwner)
        #expect(failure { _ = try other.claim("state-v1.json", as: "taken") } == .notOwner)
        #expect(failure { try other.remove("state-v1.json") } == .notOwner)
        #expect(failure { _ = try other.sweep() } == .notOwner)
        #expect(text(holder.url.appendingPathComponent("state-v1.json").path) == "{}")
    }

    // MARK: writing

    @Test func filesAreTheirOwnersAloneAfterAReplace() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let state = files.url.appendingPathComponent("state-v1.json").path
        try files.replace("state-v1.json", with: Data("one".utf8))
        #expect(text(state) == "one" && mode(state) == 0o600)
        // A file opened to others since: closed again by the next replace.
        chmod(state, 0o644)
        try files.replace("state-v1.json", with: Data("two".utf8))
        #expect(text(state) == "two" && mode(state) == 0o600)
        // The previous one kept, private too.
        try files.replace("state-v1.json", with: Data("three".utf8), keepingPrevious: true)
        #expect(text(state) == "three" && text(state + ".prev") == "two" && mode(state + ".prev") == 0o600)
        // A new file made in one step: never there with other bits, nothing to replace.
        try files.create("scrollback-1", with: Data("rows".utf8))
        #expect(mode(files.url.appendingPathComponent("scrollback-1").path) == 0o600)
        #expect(failure { try files.create("scrollback-1", with: Data("again".utf8)) } == .exists)
        #expect(text(files.url.appendingPathComponent("scrollback-1").path) == "rows")
        // Only plain names inside the folder.
        for name in ["", ".", "..", "../state", "a/b", ".hidden", "a\u{0}b"] {
            #expect(failure { try files.replace(name, with: Data()) } == .badName, "\(name)")
        }
        // Nothing but the files themselves: no temporary file left.
        let names = try files.names()
        #expect(names == [SessionFiles.appPathName, SessionFiles.lockName, "scrollback-1", "state-v1.json", "state-v1.json.prev"])
    }

    @Test func aLinkAtTheTargetIsReplacedNotFollowed() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let victim = parent.appendingPathComponent("victim").path
        try put("theirs", victim, mode: 0o644)
        let state = files.url.appendingPathComponent("state-v1.json").path
        try FileManager.default.createSymbolicLink(atPath: state, withDestinationPath: victim)
        try files.replace("state-v1.json", with: Data("ours".utf8))
        #expect(!isLink(state) && text(state) == "ours" && mode(state) == 0o600)
        #expect(text(victim) == "theirs" && mode(victim) == 0o644)
        // A link is never kept as the previous file either.
        try FileManager.default.removeItem(atPath: state)
        try FileManager.default.createSymbolicLink(atPath: state, withDestinationPath: victim)
        try files.replace("state-v1.json", with: Data("again".utf8), keepingPrevious: true)
        #expect(!isLink(state) && text(state) == "again" && !FileManager.default.fileExists(atPath: state + ".prev"))
        #expect(text(victim) == "theirs")
        // A link where a new file goes: create refuses it, and leaves both alone.
        try FileManager.default.createSymbolicLink(atPath: files.url.appendingPathComponent("scrollback-2").path, withDestinationPath: victim)
        #expect(failure { try files.create("scrollback-2", with: Data("rows".utf8)) } == .exists)
        #expect(text(victim) == "theirs")
    }

    // MARK: reading

    @Test func aTruncatedCurrentFileLoadsThePreviousOne() throws {
        struct Saved: Codable { var generation: Int }
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        func save(_ generation: Int) throws {
            try files.replace("state-v1.json", with: try JSONEncoder().encode(Saved(generation: generation)), keepingPrevious: true)
        }
        func load() -> Int? {
            files.load("state-v1.json", maxSize: 1000) { try? JSONDecoder().decode(Saved.self, from: $0) }?.generation
        }
        try save(1)
        try save(2)
        #expect(load() == 2)
        let state = files.url.appendingPathComponent("state-v1.json").path
        #expect(truncate(state, 5) == 0)
        #expect(load() == 1)
        // The current one gone (a quit cut off between the two steps of a save): the previous one.
        try FileManager.default.removeItem(atPath: state)
        #expect(load() == 1)
        // Neither reads: nothing.
        #expect(truncate(state + ".prev", 3) == 0)
        #expect(load() == nil)
    }

    @Test func onlyAPlainFileOfTheOwnersAloneIsRead() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let folder = files.url.path
        try files.replace("marker.json", with: Data("{}".utf8))
        #expect(try files.read("marker.json", maxSize: 10) == Data("{}".utf8))
        #expect(try files.read("missing.json", maxSize: 10) == nil)
        // Over its cap.
        #expect(failure { _ = try files.read("marker.json", maxSize: 1) } == .tooLarge)
        // A named pipe: refused at once, where a plain open would wait for a writer.
        #expect(mkfifo(folder + "/pipe", 0o600) == 0)
        let started = Date()
        #expect(failure { _ = try files.read("pipe", maxSize: 10) } == .refused)
        #expect(Date().timeIntervalSince(started) < 2)
        // A file with a second name elsewhere, which whoever holds it could change.
        try put("{}", folder + "/linked.json")
        #expect(link(folder + "/linked.json", parent.path + "/outside.json") == 0)
        #expect(failure { _ = try files.read("linked.json", maxSize: 10) } == .refused)
        // A link, even to a plain private file.
        try put("{}", parent.path + "/target.json")
        try FileManager.default.createSymbolicLink(atPath: folder + "/link.json", withDestinationPath: parent.path + "/target.json")
        #expect(failure { _ = try files.read("link.json", maxSize: 10) } == .refused)
        // Open to the group or others.
        try put("{}", folder + "/open.json", mode: 0o640)
        #expect(failure { _ = try files.read("open.json", maxSize: 10) } == .refused)
        // A folder.
        try FileManager.default.createDirectory(atPath: folder + "/folder", withIntermediateDirectories: false)
        #expect(failure { _ = try files.read("folder", maxSize: 10) } == .refused)
    }

    // MARK: claiming

    @Test func aClaimHasExactlyOneWinner() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        try files.replace("marker.json", with: Data("{\"id\": 1}".utf8))
        // Claimers racing, each to a name of its own: the marker moves once.
        let claimers = 16
        let lock = NSLock()
        var winners: [Int] = []
        DispatchQueue.concurrentPerform(iterations: claimers) { index in
            guard (try? files.claim("marker.json", as: "marker.claimed-\(index)")) == true else { return }
            lock.lock()
            winners.append(index)
            lock.unlock()
        }
        #expect(winners.count == 1)
        let names = try files.names()
        #expect(!names.contains("marker.json") && names.filter { $0.hasPrefix("marker.claimed-") }.count == 1)
        // A claim never replaces a claimed file already there, and a marker that is gone is no claim.
        let winner = try #require(winners.first)
        try files.replace("marker.json", with: Data("{\"id\": 2}".utf8))
        #expect(try files.claim("marker.json", as: "marker.claimed-\(winner)") == false)
        #expect(try files.read("marker.claimed-\(winner)", maxSize: 100) == Data("{\"id\": 1}".utf8))
        #expect(try files.read("marker.json", maxSize: 100) == Data("{\"id\": 2}".utf8))
        #expect(try files.claim("gone.json", as: "gone.claimed") == false)
    }

    // MARK: sweeping

    @Test func strayTemporaryFilesAreIgnoredAndSwept() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let folder = files.url.path
        try files.replace("state-v1.json", with: Data("saved".utf8))
        // What a save cut off leaves (SafeWrite's temporary), and what an install script cut off leaves.
        try put("half", folder + "/.state-v1.json.nextterm-\(UUID().uuidString)")
        try put("{}", folder + "/install-result.AbC123")
        let old = Date(timeIntervalSinceNow: -120)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: folder + "/install-result.AbC123")
        // One the install script is writing now.
        try put("{}", folder + "/install-result.XyZ789")
        // Things only a planted hand could put there.
        try FileManager.default.createSymbolicLink(atPath: folder + "/planted", withDestinationPath: parent.path)
        #expect(mkfifo(folder + "/pipe", 0o600) == 0)
        #expect(files.load("state-v1.json", maxSize: 100) { $0 } == Data("saved".utf8))
        try files.replace(InstallResult.fileName, with: Data("{}".utf8))
        let removed = try files.sweep()
        #expect(removed.count == 4)
        let names = try files.names()
        let expected = [SessionFiles.appPathName, "install-result.XyZ789", InstallResult.fileName, SessionFiles.lockName, "state-v1.json"]
        #expect(names == expected)
        #expect(FileManager.default.fileExists(atPath: parent.path))
    }

    @Test func foldersWhoseAppIsGoneAreSwept() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let apps = parent.appendingPathComponent("Applications").path
        try FileManager.default.createDirectory(atPath: apps, withIntermediateDirectories: false)
        func app(_ name: String, exists: Bool) throws -> String {
            let path = apps + "/" + name + ".app"
            if exists { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false) }
            return path
        }
        // This copy's own folder, and a copy still installed.
        let own = try owned(in: parent, app: try app("Next Term", exists: true))
        let installed = try owned(in: parent, app: try app("Next Term Beta", exists: true))
        installed.unlock()
        // Copies deleted since: one quiet, one whose process still runs (it holds its lock), and one named by the
        // install script's folder key (its old app waits in a backup).
        let deleted = try owned(in: parent, app: try app("Old Copy", exists: false))
        deleted.unlock()
        let running = try owned(in: parent, app: try app("Running Copy", exists: false))
        let backup = try owned(in: parent, app: try app("Backup Copy", exists: false))
        backup.unlock()
        // A folder with no app recorded (made, never locked), one opened to others, and a link.
        let unrecorded = try SessionFiles.open(in: parent, bundlePath: try app("Never Locked", exists: false))
        let opened = try owned(in: parent, app: try app("Opened", exists: false))
        opened.unlock()
        chmod(opened.url.path, 0o755)
        let linkName = SessionFiles.folderName(key: SessionFiles.key(forBundlePath: apps + "/Linked.app"))
        try FileManager.default.createSymbolicLink(atPath: parent.path + "/" + linkName, withDestinationPath: deleted.url.path)

        // Swept again while the quiet copy's lock looks held: a process another test starts holds it a moment
        // (`lockOnceFree`).
        var removed: [String] = []
        for _ in 0..<100 where FileManager.default.fileExists(atPath: deleted.url.path) {
            removed += SessionFiles.sweepSiblings(in: parent, keeping: [own.key, backup.key])
            if FileManager.default.fileExists(atPath: deleted.url.path) { usleep(10_000) }
        }
        #expect(removed == [deleted.url.lastPathComponent])
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: parent.path))
        let kept = [own, installed, running, backup, unrecorded, opened].map(\.url.lastPathComponent)
        #expect(left == Set(kept + ["Applications", linkName]))
        #expect(running.isOwner)
    }
}
