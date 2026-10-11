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

    /// A Unix socket at `path`: bound at a short name (a socket's path has at most 104 bytes), then moved there.
    func plantSocket(_ path: String) {
        let short = FileManager.default.temporaryDirectory.path + "/nt-\(UUID().uuidString.prefix(8)).sock"
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(short.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            bytes.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buffer.count))) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) }
        }
        #expect(bound == 0 && rename(short, path) == 0)
    }

    /// Whether `path` (never followed) has an ACL.
    func hasACL(_ path: String) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
        acl_free(UnsafeMutableRawPointer(acl))
        return true
    }

    /// Adds `entry` to the ACL of `path`, as `chmod +a` does.
    func addACL(_ entry: String, to path: String) throws {
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", entry, path]
        try chmod.run()
        chmod.waitUntilExit()
        #expect(chmod.terminationStatus == 0)
    }

    /// Keeps the file there now as the one before, whatever it holds.
    let anyPrevious = SessionFiles.Previous(maxSize: 1 << 20) { _ in true }

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

    @Test func threadsTakingTheLockAtOnceAllHoldIt() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        // A folder of its own for each round: nothing else ever held its lock.
        for round in 0..<50 {
            let files = try SessionFiles.open(in: parent, bundlePath: "/Users/x/Applications/Copy \(round).app")
            let lock = NSLock()
            var refused = 0
            DispatchQueue.concurrentPerform(iterations: 4) { _ in
                guard !files.lock() else { return }
                lock.lock()
                refused += 1
                lock.unlock()
            }
            #expect(refused == 0 && files.isOwner, "round \(round)")
        }
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
        // Nor the folder's descriptor.
        #expect(fcntl(first.folder, F_GETFD) & FD_CLOEXEC != 0)
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
        // A link (never followed), a named pipe (never waited on), a socket and an empty folder: each goes, and a plain
        // file takes its place.
        let plant: [(String, () throws -> Void)] = [
            ("link", { try FileManager.default.createSymbolicLink(atPath: lock, withDestinationPath: victim) }),
            ("pipe", { #expect(mkfifo(lock, 0o600) == 0) }),
            ("socket", { plantSocket(lock) }),
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
        try files.replace("state-v1.json", with: Data("three".utf8), keepingPrevious: anyPrevious)
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
        try files.replace("state-v1.json", with: Data("again".utf8), keepingPrevious: anyPrevious)
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
        func decode(_ data: Data) -> Saved? { try? JSONDecoder().decode(Saved.self, from: data) }
        func save(_ generation: Int) throws {
            let data = try JSONEncoder().encode(Saved(generation: generation))
            try files.replace("state-v1.json", with: data, keepingPrevious: .init(maxSize: 1000) { decode($0) != nil })
        }
        func load() -> Int? {
            files.load("state-v1.json", maxSize: 1000, decode: decode)?.generation
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

    @Test func aCurrentFileThatNoLongerReadsNeverTakesThePlaceOfTheGoodOne() throws {
        struct Saved: Codable { var generation: Int }
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        func decode(_ data: Data) -> Saved? { try? JSONDecoder().decode(Saved.self, from: data) }
        func save(_ generation: Int) throws {
            let data = try JSONEncoder().encode(Saved(generation: generation))
            try files.replace("state-v1.json", with: data, keepingPrevious: .init(maxSize: 1000) { decode($0) != nil })
        }
        func generation(_ name: String) -> Int? {
            (try? files.read(name, maxSize: 1000)).flatMap { $0 }.flatMap(decode)?.generation
        }
        try save(1)
        try save(2)
        let state = files.url.appendingPathComponent("state-v1.json").path
        #expect(truncate(state, 5) == 0)
        // The next save replaces the cut-off file, and the good one before it stays.
        try save(3)
        #expect(generation("state-v1.json") == 3 && generation("state-v1.json.prev") == 1)
        try save(4)
        #expect(generation("state-v1.json") == 4 && generation("state-v1.json.prev") == 3)
        // Nor one over its cap.
        try files.replace("state-v1.json", with: Data(repeating: 32, count: 2000))
        try save(5)
        #expect(generation("state-v1.json") == 5 && generation("state-v1.json.prev") == 3)
    }

    @Test func aSaveThatFailsLeavesBothFilesAsTheyWere() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        try files.replace("state-v1.json", with: Data("one".utf8))
        try files.replace("state-v1.json", with: Data("two".utf8), keepingPrevious: anyPrevious)
        // A full disk.
        files.calls.write = { _, _, _ in
            errno = ENOSPC
            return -1
        }
        let three = Data("three".utf8)
        #expect(failure { try files.replace("state-v1.json", with: three, keepingPrevious: anyPrevious) } == .system(ENOSPC))
        #expect(failure { try files.replace("state-v1.json", with: three) } == .system(ENOSPC))
        #expect(failure { try files.create("scrollback-1", with: Data("rows".utf8)) } == .system(ENOSPC))
        #expect(try files.read("state-v1.json", maxSize: 100) == Data("two".utf8))
        #expect(try files.read("state-v1.json.prev", maxSize: 100) == Data("one".utf8))
        // Nothing left half-made.
        #expect(try files.names() == [SessionFiles.appPathName, SessionFiles.lockName, "state-v1.json", "state-v1.json.prev"])
    }

    @Test func everyFileIsFlushedWithABarrierBeforeItTakesItsName() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        var commands: [Int32] = []
        files.calls.fcntl = { descriptor, command in
            commands.append(command)
            return fcntl(descriptor, command)
        }
        try files.replace("state-v1.json", with: Data("one".utf8))
        try files.replace("state-v1.json", with: Data("two".utf8), keepingPrevious: anyPrevious)
        try files.create("scrollback-1", with: Data("rows".utf8))
        #expect(commands == [F_BARRIERFSYNC, F_BARRIERFSYNC, F_BARRIERFSYNC])
        // A volume with no barrier: a plain fsync, and the file is written.
        files.calls.fcntl = { _, _ in
            errno = ENOTSUP
            return -1
        }
        try files.replace("state-v1.json", with: Data("three".utf8))
        #expect(try files.read("state-v1.json", maxSize: 100) == Data("three".utf8))
    }

    @Test func noCallerTouchesTheLocksOwnFiles() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let holder = try owned(in: parent)
        try holder.replace("marker.json", with: Data("{}".utf8))
        for name in [SessionFiles.lockName, SessionFiles.appPathName] {
            #expect(failure { try holder.replace(name, with: Data("x".utf8)) } == .badName, "\(name)")
            #expect(failure { try holder.replace(name, with: Data("x".utf8), keepingPrevious: anyPrevious) } == .badName, "\(name)")
            #expect(failure { try holder.create(name, with: Data("x".utf8)) } == .badName, "\(name)")
            #expect(failure { try holder.remove(name) } == .badName, "\(name)")
            #expect(failure { _ = try holder.read(name, maxSize: 4096) } == .badName, "\(name)")
            #expect(failure { _ = try holder.claim(name, as: "taken") } == .badName, "\(name)")
            #expect(failure { _ = try holder.claim("marker.json", as: name) } == .badName, "\(name)")
        }
        // The lock is still its holder's alone, and the app's path as the lock recorded it.
        let second = try SessionFiles.open(in: parent, bundlePath: "/Users/x/Applications/Next Term.app")
        #expect(!second.lock())
        #expect(SessionFiles.recordedBundlePath(in: holder.url) == "/Users/x/Applications/Next Term.app")
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
        // A socket.
        plantSocket(folder + "/socket")
        #expect(failure { _ = try files.read("socket", maxSize: 10) } == .refused)
    }

    @Test func theRecordedAppPathIsReadAsUntrusted() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let recorded = files.url.appendingPathComponent(SessionFiles.appPathName).path
        #expect(SessionFiles.recordedBundlePath(in: files.url) == "/Users/x/Applications/Next Term.app")
        // Another user's.
        #expect(SessionFiles.recordedBundlePath(in: files.url, owner: geteuid() + 1) == nil)
        // Open to others.
        chmod(recorded, 0o644)
        #expect(SessionFiles.recordedBundlePath(in: files.url) == nil)
        // Not one absolute path: relative, two lines, empty, or longer than any path.
        for path in ["Applications/Next Term.app", "/Users/x/A.app\n/Users/x/B.app", "", "/" + String(repeating: "a", count: 5000)] {
            try put(path, recorded)
            #expect(SessionFiles.recordedBundlePath(in: files.url) == nil, "\(path.prefix(40))")
        }
        // A link, to a file that would pass.
        try put("/Users/x/Elsewhere.app", parent.path + "/elsewhere")
        try FileManager.default.removeItem(atPath: recorded)
        try FileManager.default.createSymbolicLink(atPath: recorded, withDestinationPath: parent.path + "/elsewhere")
        #expect(SessionFiles.recordedBundlePath(in: files.url) == nil)
    }

    @Test func noACLOpensTheFolderToOthers() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        // One the folder would inherit from its parent when it is made.
        try addACL("everyone allow list,search,add_file,add_subdirectory,read,write,file_inherit,directory_inherit", to: parent.path)
        let files = try owned(in: parent)
        #expect(!hasACL(files.url.path))
        try files.replace("state-v1.json", with: Data("{}".utf8))
        try files.create("scrollback-1", with: Data("rows".utf8))
        let made = ["state-v1.json", "scrollback-1", SessionFiles.lockName, SessionFiles.appPathName]
        #expect(made.allSatisfy { !hasACL(files.url.appendingPathComponent($0).path) })
        // One set on it since: gone the next time it is opened.
        try addACL("everyone allow list,search,add_file,read,write", to: files.url.path)
        #expect(hasACL(files.url.path))
        _ = try SessionFiles.open(in: parent, bundlePath: "/Users/x/Applications/Next Term.app")
        #expect(!hasACL(files.url.path))
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

    @Test func aSweepNeverRemovesASaveInFlight() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let files = try owned(in: parent)
        let data = Data(repeating: 7, count: 1 << 20)
        let previous = SessionFiles.Previous(maxSize: 2 << 20) { _ in true }
        // A sweep on another thread all the while.
        let stop = Flag()
        let stopped = DispatchSemaphore(value: 0)
        Thread {
            while !stop.isSet {
                _ = try? files.sweep()
                usleep(200)
            }
            stopped.signal()
        }.start()
        var failures: [String] = []
        for _ in 0..<20 {
            do {
                try files.replace("state-v1.json", with: data, keepingPrevious: previous)
            } catch {
                failures.append("\(error)")
            }
        }
        stop.set()
        stopped.wait()
        #expect(failures.isEmpty)
        #expect(try files.read("state-v1.json", maxSize: 2 << 20) == data)
    }

    @Test func aFolderUsedLatelyIsKeptWhileItsAppIsAway() throws {
        let parent = try makeParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let app = parent.appendingPathComponent("Next Term.app").path
        try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: false)
        // A copy quits for an update: it leaves its marker, and the install moves it aside a moment (or for good, when
        // neither app can go back and the backup waits for its first launch).
        let quitting = try owned(in: parent, app: app)
        try quitting.replace("marker.json", with: Data("{}".utf8))
        quitting.unlock()
        try FileManager.default.moveItem(atPath: app, toPath: app + ".held")
        let other = try owned(in: parent, app: "/Users/x/Applications/Other.app")
        #expect(SessionFiles.sweepSiblings(in: parent, keeping: [other.key]).isEmpty)
        #expect(FileManager.default.fileExists(atPath: quitting.url.appendingPathComponent("marker.json").path))
        // Untouched for longer than that: gone.
        let later = Date(timeIntervalSinceNow: SessionFiles.goneAppAge + 60)
        var removed: [String] = []
        for _ in 0..<100 where FileManager.default.fileExists(atPath: quitting.url.path) {
            removed += SessionFiles.sweepSiblings(in: parent, keeping: [other.key], now: later)
            if FileManager.default.fileExists(atPath: quitting.url.path) { usleep(10_000) }
        }
        #expect(removed == [quitting.url.lastPathComponent])
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

        // Once they have been gone a while (`aFolderUsedLatelyIsKeptWhileItsAppIsAway`). Swept again while the quiet copy's
        // lock looks held: a process another test starts holds it a moment (`lockOnceFree`).
        let later = Date(timeIntervalSinceNow: SessionFiles.goneAppAge + 60)
        var removed: [String] = []
        for _ in 0..<100 where FileManager.default.fileExists(atPath: deleted.url.path) {
            removed += SessionFiles.sweepSiblings(in: parent, keeping: [own.key, backup.key], now: later)
            if FileManager.default.fileExists(atPath: deleted.url.path) { usleep(10_000) }
        }
        #expect(removed == [deleted.url.lastPathComponent])
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: parent.path))
        let kept = [own, installed, running, backup, unrecorded, opened].map(\.url.lastPathComponent)
        #expect(left == Set(kept + ["Applications", linkName]))
        #expect(running.isOwner)
    }

    /// A flag one thread sets and another reads.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }
}
