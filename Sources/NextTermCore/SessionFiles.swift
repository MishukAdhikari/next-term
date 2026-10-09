import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The sessions folder: where one copy of the app keeps what an update relaunch or a crash reads back (the session
/// snapshot, the update marker, scrollback, the install script's result), as
/// `Application Support/Next Term/sessions-<key>.noindex`, the key naming the app's path.
///
/// What it guarantees:
/// - **Private.** The folder is made 0700 with no ACL (none set on it, none inherited from its parent), checked as a real
///   folder of this user's (a link or a file planted at its name is refused, never followed), and worked through an
///   open descriptor of it. It is excluded from backups, and its `.noindex` suffix keeps Spotlight out. Every file is
///   0600 and opened without following a link.
/// - **One process at a time.** `lock()` takes `flock(LOCK_EX | LOCK_NB)` on `owner.lock` for as long as the process
///   runs, on a descriptor closed on exec, so a shell started in a tab never holds it. Only the holder reads, writes,
///   claims or sweeps; another Next Term launches normally and keeps nothing. A process killed outright lets the lock
///   go with it, whatever its pid becomes. An `fcntl` lock would go whenever any descriptor to the file closed. The
///   lock's own files (`owner.lock`, `app-path`) are no caller's to write, remove or claim.
/// - **All or nothing.** `replace` writes through `SafeWrite.replace`, with a barrier flush (`F_BARRIERFSYNC`) before the
///   rename. With `keepingPrevious`, the file before it is kept as `<name>.prev` once the new bytes are on disk, and only
///   while it still reads: `load` falls back to it. A save that fails leaves both as they were.
/// - **Untrusted when read.** `read` opens without following a link and without waiting on a named pipe, and takes only a
///   plain file of this user's, with no other name and nothing open to others, under the caller's size cap.
/// - **Claimed once.** `claim` is an exclusive rename: of processes racing for one file, one wins.
/// - **Nothing lingers.** `sweep` removes what a cut-off save or install script left, and anything not a plain file,
///   never the temporary file of a save in flight; `sweepSiblings` removes the folders of copies of the app that have
///   been gone a while.
///
/// Use: `lock()` once, then the rest from any thread; each call is its own system calls.
public final class SessionFiles: @unchecked Sendable {
    /// Why nothing was read or written.
    public enum Failure: Error, Equatable, Sendable {
        /// What is at the folder's name is not a folder of this user's that only it can reach: a link, a file, another
        /// user's folder.
        case notPrivate
        /// This process does not hold the folder's lock: another Next Term does, or it was never taken.
        case notOwner
        /// Not a plain name of a file in the folder, or not a folder key.
        case badName
        /// Not a plain file of this user's alone: a link, a named pipe, a folder, a file with a second name, one open to
        /// others.
        case refused
        /// Bigger than the caller's cap.
        case tooLarge
        /// Something is at the name already (`create`), or turned up there while the file was written.
        case exists
        /// A system call failed with this `errno`.
        case system(Int32)
    }

    /// The file whose `flock` makes a process the folder's owner.
    public static let lockName = "owner.lock"
    /// The canonical path of the app the folder is for, recorded once the lock is taken.
    public static let appPathName = "app-path"
    /// Added to a file's name for the one `replace(keepingPrevious:)` kept.
    public static let previousSuffix = ".prev"
    static let folderPrefix = "sessions-"
    static let folderSuffix = ".noindex"
    /// The longest app path read back.
    static let appPathMaxSize = 4096
    /// How old the install script's temporary result must be before it is swept: a younger one may be its now.
    static let scriptTemporaryAge: TimeInterval = 60
    /// How long a folder whose app is gone stays untouched before `sweepSiblings` removes it. An install moves the app
    /// away for a moment, and when neither app can go back in, the old one waits in its backup for its first launch.
    static let goneAppAge: TimeInterval = 7 * 24 * 60 * 60

    /// Which file `replace` keeps as the one before: the file there now, when it reads back whole, as `load` would read
    /// it. One that no longer does never takes the place of the good one kept before it.
    public struct Previous {
        /// The most of the file there now that is read.
        public let maxSize: Int
        /// Whether it reads: true when `load`'s decode takes it.
        public let isGood: (Data) -> Bool

        public init(maxSize: Int, isGood: @escaping (Data) -> Bool) {
            self.maxSize = maxSize
            self.isGood = isGood
        }
    }

    /// The system calls every file is written (`write`) and flushed (`fcntl`, `F_BARRIERFSYNC`) with, which a test fails
    /// or watches. Set before the folder is used from more than one thread.
    struct Calls {
        var write: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }
        var fcntl: (Int32, Int32) -> Int32 = { Darwin.fcntl($0, $1) }
    }

    var calls = Calls()

    public let url: URL
    /// The folder key: `key(forBundlePath:)` of the app's path.
    public let key: String
    private let owner: uid_t
    /// The canonical path recorded once the lock is taken; none when opened by key.
    private let bundlePath: String?
    /// The folder, held open: files are opened relative to it.
    let folder: Int32
    private let state = NSLock()
    private var lockDescriptor: Int32 = -1
    /// Shared by the saves (`replace`), taken alone by `sweep`: a sweep never removes the temporary file of a save in
    /// flight.
    private let writes: UnsafeMutablePointer<pthread_rwlock_t>

    private init(url: URL, key: String, owner: uid_t, bundlePath: String?, folder: Int32) {
        self.url = url
        self.key = key
        self.owner = owner
        self.bundlePath = bundlePath
        self.folder = folder
        writes = .allocate(capacity: 1)
        writes.initialize(to: pthread_rwlock_t())
        pthread_rwlock_init(writes, nil)
    }

    deinit {
        unlock()
        Darwin.close(folder)
        pthread_rwlock_destroy(writes)
        writes.deinitialize(count: 1)
        writes.deallocate()
    }

    // MARK: the folder

    /// The key of the folder for the app at `path`: the first 16 bytes of the SHA-256 of its canonical path, in lowercase
    /// hex. Each copy of the app has its own.
    public static func key(forBundlePath path: String) -> String {
        let digest = SHA256.hash(data: Data(canonicalPath(path).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `text` is a folder key: 32 lowercase hex digits, so it can name nothing outside the parent folder.
    public static func isKey(_ text: String) -> Bool {
        let hex = UInt8(ascii: "0")...UInt8(ascii: "9")
        let letters = UInt8(ascii: "a")...UInt8(ascii: "f")
        return text.utf8.count == 32 && text.utf8.allSatisfy { hex.contains($0) || letters.contains($0) }
    }

    public static func folderName(key: String) -> String { folderPrefix + key + folderSuffix }

    /// The folder in `parent` for the app at `bundlePath`, made when it is not there. `parent` is made 0700 when it is not
    /// there either. The app's path is recorded when the lock is taken. `owner` is for the tests.
    public static func open(in parent: URL, bundlePath: String, owner: uid_t = geteuid()) throws -> SessionFiles {
        try open(in: parent, key: key(forBundlePath: bundlePath), bundlePath: canonicalPath(bundlePath), owner: owner)
    }

    /// The folder in `parent` with this key: the install script hands an old app opened from its backup the key of its
    /// install path. Records no app path.
    public static func open(in parent: URL, key: String, owner: uid_t = geteuid()) throws -> SessionFiles {
        try open(in: parent, key: key, bundlePath: nil, owner: owner)
    }

    private static func open(in parent: URL, key: String, bundlePath: String?, owner: uid_t) throws -> SessionFiles {
        guard isKey(key) else { throw Failure.badName }
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: attributes)
        let url = parent.appendingPathComponent(folderName(key: key), isDirectory: true)
        if mkdir(url.path, 0o700) != 0, errno != EEXIST { throw Failure.system(errno) }
        // Opened without following a link at its name, then checked through the descriptor: what is checked is what is used.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            throw code == ELOOP || code == ENOTDIR ? Failure.notPrivate : Failure.system(code)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == owner else {
            Darwin.close(descriptor)
            throw Failure.notPrivate
        }
        // Its own folder, made under a looser umask or opened since: closed again, its ACL too.
        if info.st_mode & 0o777 != 0o700, fchmod(descriptor, 0o700) != 0 {
            Darwin.close(descriptor)
            throw Failure.notPrivate
        }
        guard removeACL(descriptor) else {
            Darwin.close(descriptor)
            throw Failure.notPrivate
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = url
        try? excluded.setResourceValues(values)
        return SessionFiles(url: url, key: key, owner: owner, bundlePath: bundlePath, folder: descriptor)
    }

    /// Removes the ACL of the folder at `descriptor`, which would open it to others whatever its mode: one set on it, or
    /// one inherited from its parent when it was made (which the files made in it would inherit in turn). False when it
    /// stays.
    private static func removeACL(_ descriptor: Int32) -> Bool {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return true }
        acl_free(UnsafeMutableRawPointer(acl))
        guard let none = acl_init(0) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(none)) }
        return acl_set_fd_np(descriptor, none, ACL_TYPE_EXTENDED) == 0
    }

    /// The app path recorded in the sessions folder at `folder`, read as untrusted: nil when there is none, or it is not a
    /// plain private file holding an absolute path.
    public static func recordedBundlePath(in folder: URL, owner: uid_t = geteuid()) -> String? {
        let path = folder.appendingPathComponent(appPathName).path
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, isPrivateFile(info, owner: owner),
              let data = try? readAll(descriptor, maxSize: appPathMaxSize),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let isPath = text.hasPrefix("/") && !text.contains("\0") && !text.contains("\n")
        return isPath ? text : nil
    }

    /// Removes the sessions folders in `parent` whose app is gone: its recorded path is no longer a folder, no process
    /// holds its lock (a copy moved or deleted while it runs keeps its folder), and nothing in it changed for
    /// `goneAppAge` (an install moves the app away a moment, and a backup can wait for its first launch). Folders named
    /// by `keys` stay: this copy's, and one the install script named by its key. So does anything not a private folder of
    /// this user's with an app recorded, and links are never followed. Returns the names removed.
    @discardableResult
    public static func sweepSiblings(in parent: URL, keeping keys: Set<String>, now: Date = Date(),
                                     owner: uid_t = geteuid()) -> [String] {
        let names: [String] = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        var removed: [String] = []
        for name in names.sorted() where name.hasPrefix(folderPrefix) && name.hasSuffix(folderSuffix) {
            let key = String(name.dropFirst(folderPrefix.count).dropLast(folderSuffix.count))
            guard isKey(key), !keys.contains(key) else { continue }
            let folder = parent.appendingPathComponent(name)
            guard PrivateFolder.isPrivate(folder.path, owner: owner), !isRecent(folder.path, now: now),
                  let app = recordedBundlePath(in: folder, owner: owner), !isFolder(app) else { continue }
            let lock = Darwin.open(folder.appendingPathComponent(lockName).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard lock >= 0 else { continue }
            defer { Darwin.close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0, (try? FileManager.default.removeItem(at: folder)) != nil else { continue }
            removed.append(name)
        }
        return removed
    }

    private static func isFolder(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// Whether a file was added to, replaced in or removed from the folder at `path` less than `goneAppAge` ago. Every
    /// write in it is one of those: a file is never changed in place.
    private static func isRecent(_ path: String, now: Date) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return true }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        return now.timeIntervalSince(modified) < goneAppAge
    }

    // MARK: the lock

    /// Whether this process holds the folder's lock.
    public var isOwner: Bool {
        state.lock()
        defer { state.unlock() }
        return lockDescriptor >= 0
    }

    /// Takes the folder's lock for as long as the process runs, or until `unlock`, and records the app's path. False when
    /// another process holds it. True for its holder, from any thread, even while another takes it.
    public func lock() -> Bool {
        guard let taken = holdLock() else { return false }
        if taken, let bundlePath {
            let data = Data(bundlePath.utf8)
            let recorded = try? readFile(Self.appPathName, maxSize: Self.appPathMaxSize)
            if recorded != data { try? write(Self.appPathName, data, keepingPrevious: nil) }
        }
        return true
    }

    /// True when the lock is taken now, false when this instance held it already, nil when another process holds it.
    private func holdLock() -> Bool? {
        state.lock()
        defer { state.unlock() }
        if lockDescriptor >= 0 { return false }
        guard let descriptor = takeLock() else { return nil }
        lockDescriptor = descriptor
        return true
    }

    /// The locked descriptor of `owner.lock`. Something not a plain file at its name, which only a planted hand puts there,
    /// is removed first: a link, a named pipe, a socket, an empty folder.
    private func takeLock() -> Int32? {
        for _ in 0..<2 {
            let descriptor = openat(folder, Self.lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else {
                let code = errno
                if code == ELOOP || code == EOPNOTSUPP { _ = unlinkat(folder, Self.lockName, 0) }
                if code == EISDIR { _ = unlinkat(folder, Self.lockName, AT_REMOVEDIR) }
                continue
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                Darwin.close(descriptor)
                _ = unlinkat(folder, Self.lockName, 0)
                continue
            }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return descriptor }
            Darwin.close(descriptor)
            return nil
        }
        return nil
    }

    /// Lets the lock go: the process no longer reads or writes the folder.
    public func unlock() {
        state.lock()
        let descriptor = lockDescriptor
        lockDescriptor = -1
        state.unlock()
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    // MARK: files

    /// A new file, 0600, made only when nothing is at its name (a link planted there included). For scrollback, which is
    /// written once and read once.
    public func create(_ name: String, with data: Data) throws {
        try ready(name)
        let descriptor = openat(folder, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw errno == EEXIST ? Failure.exists : Failure.system(errno) }
        var written = false
        defer {
            Darwin.close(descriptor)
            if !written { unlinkat(folder, name, 0) }
        }
        // 0600 whatever the umask, which is never changed (it is the whole process's).
        guard fchmod(descriptor, 0o600) == 0 else { throw Failure.system(errno) }
        try Self.writeAll(data, to: descriptor, with: calls.write)
        guard Self.barrierSync(descriptor, fcntl: calls.fcntl) == 0 else { throw Failure.system(errno) }
        written = true
    }

    /// Replaces the file `name` with `data`, all or nothing (`SafeWrite.replace`, with a barrier flush), as a 0600 file.
    /// With `previous`, the file there now becomes `<name>.prev` once the new bytes are on disk, replacing the one before,
    /// when it reads (`read`) as `previous` says; one that no longer does is replaced, and the one before stays. A link or
    /// anything else not a plain file of this user's at `name` is removed, never written through and never kept.
    public func replace(_ name: String, with data: Data, keepingPrevious previous: Previous? = nil) throws {
        try ready(name)
        try write(name, data, keepingPrevious: previous)
    }

    /// `replace`, for the lock's own files too.
    private func write(_ name: String, _ data: Data, keepingPrevious previous: Previous?) throws {
        try checkFolder()
        // Read before the saves' lock is taken: `isGood` is the caller's.
        let keep = previous.map { reads(name, as: $0) } ?? false
        pthread_rwlock_rdlock(writes)
        defer { pthread_rwlock_unlock(writes) }
        var expected = SafeWrite.Expectation.noFile
        var info = stat()
        if fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            if Self.isOwnFile(info, owner: owner) {
                // Closed to others again if it was opened since: SafeWrite keeps a file's permissions.
                if info.st_mode & 0o7777 != 0o600 { _ = fchmodat(folder, name, 0o600, AT_SYMLINK_NOFOLLOW) }
                expected = .anything
            } else if info.st_mode & S_IFMT == S_IFDIR {
                throw Failure.refused
            } else if unlinkat(folder, name, 0) != 0 {
                throw Failure.system(errno)
            }
        } else if errno != ENOENT {
            throw Failure.system(errno)
        }
        var system = self.system
        if keep, expected == .anything {
            // Only once the new bytes are on disk, just before they take the name: a save that fails leaves both files.
            let folder = folder
            system.beforeRename = { _ in _ = renameat(folder, name, folder, name + Self.previousSuffix) }
        }
        let path = url.appendingPathComponent(name).path
        do {
            try SafeWrite.replace(path, with: data, expecting: expected, newFileMode: 0o600, system: system)
        } catch let failure as SafeWrite.Failure {
            throw Self.failure(failure)
        }
    }

    /// Whether the file `name` reads as `previous` says.
    private func reads(_ name: String, as previous: Previous) -> Bool {
        guard let data = try? readFile(name, maxSize: previous.maxSize) else { return false }
        return previous.isGood(data)
    }

    /// The file `name`, read as untrusted input: nil when there is none. Refuses (`refused`) anything but a plain file of
    /// this user's with no other name and nothing open to others, without following a link or waiting on a named pipe,
    /// and anything over `maxSize` bytes (`tooLarge`).
    public func read(_ name: String, maxSize: Int) throws -> Data? {
        try ready(name)
        return try readFile(name, maxSize: maxSize)
    }

    /// `read`, for the lock's own files too.
    private func readFile(_ name: String, maxSize: Int) throws -> Data? {
        let descriptor = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: return nil
            case ELOOP, EOPNOTSUPP: throw Failure.refused // a link; a socket
            default: throw Failure.system(errno)
            }
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Failure.system(errno) }
        guard Self.isPrivateFile(info, owner: owner) else { throw Failure.refused }
        guard info.st_size <= maxSize else { throw Failure.tooLarge }
        return try Self.readAll(descriptor, maxSize: maxSize)
    }

    /// The file `name` as `decode` reads it, else its previous one (`replace(keepingPrevious:)`): the current one is
    /// missing (a quit cut off between the two steps of a save), refused, or does not decode.
    public func load<T>(_ name: String, maxSize: Int, decode: (Data) -> T?) -> T? {
        for candidate in [name, name + Self.previousSuffix] {
            if let data = try? read(candidate, maxSize: maxSize), let value = decode(data) { return value }
        }
        return nil
    }

    /// Renames `name` to `claimed`, only if nothing is at `claimed`: true for the one caller that moved it, false when it
    /// is gone (another claimed it) or `claimed` is taken.
    public func claim(_ name: String, as claimed: String) throws -> Bool {
        try ready(name)
        try ready(claimed)
        if renameatx_np(folder, name, folder, claimed, UInt32(RENAME_EXCL)) == 0 { return true }
        let code = errno
        guard code == ENOENT || code == EEXIST else { throw Failure.system(code) }
        return false
    }

    /// Removes the file `name`; nothing when it is not there.
    public func remove(_ name: String) throws {
        try ready(name)
        guard unlinkat(folder, name, 0) == 0 || errno == ENOENT else { throw Failure.system(errno) }
    }

    /// Every name in the folder, sorted.
    public func names() throws -> [String] {
        guard isOwner else { throw Failure.notOwner }
        try checkFolder()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { throw Failure.system(EIO) }
        return names.sorted()
    }

    /// Removes what a cut-off write left (SafeWrite's temporary files, and the install script's once a minute old) and
    /// anything not a plain file, which only a planted hand puts there. Waits for the saves in flight, and holds the next
    /// ones until it is done. Returns the names removed.
    @discardableResult
    public func sweep(now: Date = Date()) throws -> [String] {
        pthread_rwlock_wrlock(writes)
        defer { pthread_rwlock_unlock(writes) }
        var removed: [String] = []
        for name in try names() {
            var info = stat()
            guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            guard Self.isLeftover(name, info, now: now) || kind != S_IFREG else { continue }
            if kind == S_IFDIR {
                guard (try? FileManager.default.removeItem(at: url.appendingPathComponent(name))) != nil else { continue }
            } else if unlinkat(folder, name, 0) != 0 {
                continue
            }
            removed.append(name)
        }
        return removed
    }

    /// A file a cut-off write left: SafeWrite's temporary (no name of the folder's own starts with a dot), or the install
    /// script's (`install-result.XXXXXX`) once it is old enough not to be one it is writing now.
    private static func isLeftover(_ name: String, _ info: stat, now: Date) -> Bool {
        if name.hasPrefix(".") { return true }
        guard name.hasPrefix("install-result."), name != InstallResult.fileName else { return false }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        return now.timeIntervalSince(modified) > scriptTemporaryAge
    }

    // MARK: checks

    /// Throws unless this process holds the lock and `name` is a plain name in the folder: no slash, not starting with a
    /// dot (`.`, `..` and SafeWrite's temporaries), no NUL, at most 200 bytes, and not one of the lock's own files.
    private func ready(_ name: String) throws {
        guard isOwner else { throw Failure.notOwner }
        let bytes = Array(name.utf8)
        let plain = !bytes.isEmpty && bytes.count <= 200 && bytes.first != UInt8(ascii: ".")
            && !bytes.contains(UInt8(ascii: "/")) && !bytes.contains(0)
        guard plain, name != Self.lockName, name != Self.appPathName else { throw Failure.badName }
    }

    /// Throws unless the folder's path still leads to the folder held open: for the calls that go by path.
    private func checkFolder() throws {
        var here = stat()
        var held = stat()
        guard lstat(url.path, &here) == 0, fstat(folder, &held) == 0, here.st_dev == held.st_dev, here.st_ino == held.st_ino else {
            throw Failure.notPrivate
        }
    }

    /// A plain file of `owner`'s with no other name.
    private static func isOwnFile(_ info: stat, owner: uid_t) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == owner && info.st_nlink == 1
    }

    /// And nothing open to the group or others.
    private static func isPrivateFile(_ info: stat, owner: uid_t) -> Bool {
        isOwnFile(info, owner: owner) && info.st_mode & 0o077 == 0
    }

    // MARK: system calls

    /// SafeWrite's system calls: `calls.write`, and a barrier flush in place of `fsync`.
    private var system: SafeWrite.System {
        var system = SafeWrite.System()
        let calls = calls
        system.write = calls.write
        system.fsync = { Self.barrierSync($0, fcntl: calls.fcntl) }
        return system
    }

    /// `fsync`, then a barrier: what was written before is on disk before what is written after, which is cheaper than
    /// `F_FULLFSYNC`. A plain `fsync` where the volume has no barrier.
    static func barrierSync(_ descriptor: Int32, fcntl: (Int32, Int32) -> Int32) -> Int32 {
        if fcntl(descriptor, F_BARRIERFSYNC) != -1 { return 0 }
        return Darwin.fsync(descriptor)
    }

    private static func failure(_ failure: SafeWrite.Failure) -> Failure {
        switch failure {
        case .changed: return .exists
        case .readOnly, .locked, .notAFile: return .refused
        case .system(let code): return .system(code)
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32,
                                 with write: (Int32, UnsafeRawPointer, Int) -> Int) throws {
        let failure = data.withUnsafeBytes { buffer -> Int32 in
            var offset = 0
            while offset < buffer.count, let start = buffer.baseAddress {
                let count = write(descriptor, start + offset, buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return count < 0 ? errno : EIO }
                offset += count
            }
            return 0
        }
        guard failure == 0 else { throw Failure.system(failure) }
    }

    /// Everything left to read, refused once it passes `maxSize`: a file can grow after its `fstat`.
    private static func readAll(_ descriptor: Int32, maxSize: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Failure.system(errno) }
            if count == 0 { return data }
            data.append(buffer, count: count)
            guard data.count <= maxSize else { throw Failure.tooLarge }
        }
    }
}
