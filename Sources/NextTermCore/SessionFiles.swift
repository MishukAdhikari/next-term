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
/// - **Private.** The folder is made 0700, checked as a real folder of this user's (a link or a file planted at its
///   name is refused, never followed), and worked through an open descriptor of it. It is excluded from backups, and
///   its `.noindex` suffix keeps Spotlight out. Every file is 0600 and opened without following a link.
/// - **One process at a time.** `lock()` takes `flock(LOCK_EX | LOCK_NB)` on `owner.lock` for as long as the process
///   runs, on a descriptor closed on exec, so a shell started in a tab never holds it. Only the holder reads, writes,
///   claims or sweeps; another Next Term launches normally and keeps nothing. A process killed outright lets the lock
///   go with it, whatever its pid becomes. An `fcntl` lock would go whenever any descriptor to the file closed.
/// - **All or nothing.** `replace` writes through `SafeWrite.replace`, with a barrier flush (`F_BARRIERFSYNC`) before the
///   rename. With `keepingPrevious`, the file before it is kept as `<name>.prev`, and `load` falls back to it.
/// - **Untrusted when read.** `read` opens without following a link and without waiting on a named pipe, and takes only a
///   plain file of this user's, with no other name and nothing open to others, under the caller's size cap.
/// - **Claimed once.** `claim` is an exclusive rename: of processes racing for one file, one wins.
/// - **Nothing lingers.** `sweep` removes what a cut-off save or install script left, and anything not a plain file;
///   `sweepSiblings` removes the folders of copies of the app that are gone.
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

    public let url: URL
    /// The folder key: `key(forBundlePath:)` of the app's path.
    public let key: String
    private let owner: uid_t
    /// The canonical path recorded once the lock is taken; none when opened by key.
    private let bundlePath: String?
    /// The folder, held open: files are opened relative to it.
    private let folder: Int32
    private let state = NSLock()
    private var lockDescriptor: Int32 = -1

    private init(url: URL, key: String, owner: uid_t, bundlePath: String?, folder: Int32) {
        self.url = url
        self.key = key
        self.owner = owner
        self.bundlePath = bundlePath
        self.folder = folder
    }

    deinit {
        unlock()
        Darwin.close(folder)
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
        // Its own folder, made under a looser umask or opened since: closed again.
        if info.st_mode & 0o777 != 0o700, fchmod(descriptor, 0o700) != 0 {
            Darwin.close(descriptor)
            throw Failure.notPrivate
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = url
        try? excluded.setResourceValues(values)
        return SessionFiles(url: url, key: key, owner: owner, bundlePath: bundlePath, folder: descriptor)
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

    /// Removes the sessions folders in `parent` whose app is gone: its recorded path is no longer a folder, and no process
    /// holds its lock (a copy moved or deleted while it runs keeps its folder). Folders named by `keys` stay: this copy's,
    /// and one the install script named by its key. So does anything not a private folder of this user's with an app
    /// recorded, and links are never followed. Returns the names removed.
    @discardableResult
    public static func sweepSiblings(in parent: URL, keeping keys: Set<String>, owner: uid_t = geteuid()) -> [String] {
        let names: [String] = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        var removed: [String] = []
        for name in names.sorted() where name.hasPrefix(folderPrefix) && name.hasSuffix(folderSuffix) {
            let key = String(name.dropFirst(folderPrefix.count).dropLast(folderSuffix.count))
            guard isKey(key), !keys.contains(key) else { continue }
            let folder = parent.appendingPathComponent(name)
            guard PrivateFolder.isPrivate(folder.path, owner: owner),
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

    // MARK: the lock

    /// Whether this process holds the folder's lock.
    public var isOwner: Bool {
        state.lock()
        defer { state.unlock() }
        return lockDescriptor >= 0
    }

    /// Takes the folder's lock for as long as the process runs, or until `unlock`, and records the app's path. False when
    /// another process holds it. True at once for its holder.
    public func lock() -> Bool {
        if isOwner { return true }
        guard let descriptor = takeLock() else { return false }
        state.lock()
        lockDescriptor = descriptor
        state.unlock()
        if let bundlePath {
            let data = Data(bundlePath.utf8)
            if (try? read(Self.appPathName, maxSize: Self.appPathMaxSize)) != data { try? replace(Self.appPathName, with: data) }
        }
        return true
    }

    /// The locked descriptor of `owner.lock`. Something not a plain file at its name, which only a planted hand puts there,
    /// is removed first: a link, a named pipe, an empty folder.
    private func takeLock() -> Int32? {
        for _ in 0..<2 {
            let descriptor = openat(folder, Self.lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else {
                let code = errno
                if code == ELOOP { _ = unlinkat(folder, Self.lockName, 0) }
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
        try Self.writeAll(data, to: descriptor)
        guard Self.barrierSync(descriptor) == 0 else { throw Failure.system(errno) }
        written = true
    }

    /// Replaces the file `name` with `data`, all or nothing (`SafeWrite.replace`, with a barrier flush), as a 0600 file.
    /// With `keepingPrevious`, the file there now becomes `<name>.prev` first, replacing the one before. A link or anything
    /// else not a plain file of this user's at `name` is removed, never written through and never kept.
    public func replace(_ name: String, with data: Data, keepingPrevious: Bool = false) throws {
        try ready(name)
        try checkFolder()
        var expected = SafeWrite.Expectation.noFile
        var info = stat()
        if fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            if Self.isOwnFile(info, owner: owner) {
                // Closed to others again if it was opened since: SafeWrite keeps a file's permissions.
                if info.st_mode & 0o7777 != 0o600 { _ = fchmodat(folder, name, 0o600, AT_SYMLINK_NOFOLLOW) }
                if keepingPrevious {
                    guard renameat(folder, name, folder, name + Self.previousSuffix) == 0 else { throw Failure.system(errno) }
                } else {
                    expected = .anything
                }
            } else if info.st_mode & S_IFMT == S_IFDIR {
                throw Failure.refused
            } else if unlinkat(folder, name, 0) != 0 {
                throw Failure.system(errno)
            }
        } else if errno != ENOENT {
            throw Failure.system(errno)
        }
        let path = url.appendingPathComponent(name).path
        do {
            try SafeWrite.replace(path, with: data, expecting: expected, newFileMode: 0o600, system: Self.barrier)
        } catch let failure as SafeWrite.Failure {
            throw Self.failure(failure)
        }
    }

    /// The file `name`, read as untrusted input: nil when there is none. Refuses (`refused`) anything but a plain file of
    /// this user's with no other name and nothing open to others, without following a link or waiting on a named pipe,
    /// and anything over `maxSize` bytes (`tooLarge`).
    public func read(_ name: String, maxSize: Int) throws -> Data? {
        try ready(name)
        let descriptor = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: return nil
            case ELOOP: throw Failure.refused
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
    /// anything not a plain file, which only a planted hand puts there. Returns the names removed.
    @discardableResult
    public func sweep(now: Date = Date()) throws -> [String] {
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
    /// dot (`.`, `..` and SafeWrite's temporaries), no NUL, at most 200 bytes.
    private func ready(_ name: String) throws {
        guard isOwner else { throw Failure.notOwner }
        let bytes = Array(name.utf8)
        let plain = !bytes.isEmpty && bytes.count <= 200 && bytes.first != UInt8(ascii: ".")
            && !bytes.contains(UInt8(ascii: "/")) && !bytes.contains(0)
        guard plain else { throw Failure.badName }
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

    /// SafeWrite's system calls, with a barrier flush in place of `fsync`.
    private static var barrier: SafeWrite.System {
        var system = SafeWrite.System()
        system.fsync = barrierSync
        return system
    }

    /// `fsync`, then a barrier: what was written before is on disk before what is written after, which is cheaper than
    /// `F_FULLFSYNC`. A plain `fsync` where the volume has no barrier.
    static func barrierSync(_ descriptor: Int32) -> Int32 {
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

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        let failure = data.withUnsafeBytes { buffer -> Int32 in
            var offset = 0
            while offset < buffer.count, let start = buffer.baseAddress {
                let count = Darwin.write(descriptor, start + offset, buffer.count - offset)
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
