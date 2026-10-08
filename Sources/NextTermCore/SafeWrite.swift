import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The one way Next Term writes a file that is yours: an editor save, a diff's revert and its undo, Replace in
/// Files and its undo, an agent's settings (MCP registration, Gemini's and Qwen's IDE switch), the skills lock
/// file and records. A new writer of your files should come through here too.
///
/// What `replace` guarantees:
/// - **All or nothing.** The bytes go to a temporary file beside the file, are flushed to disk (`fsync`), and
///   the temporary file is renamed over the file in one step: a reader sees the old bytes or the new, never
///   part of them, and a full disk or a failed write leaves the old file as it was.
/// - **Private from the start.** The temporary file is made here, with `O_CREAT | O_EXCL | O_NOFOLLOW` at 0600:
///   nothing already at its name (a file, a link someone put there) is used, and no other account can read
///   it while it fills. Only once the bytes are in is it given the file's permissions.
/// - **The file's permissions** (read, write and execute for owner, group and others; not setuid, setgid or
///   sticky): a script stays executable, an owner-only `.env` stays owner-only. A new file gets
///   `newFileMode`, 0600 unless the caller says otherwise. Its group is kept when this account may set it;
///   when it can't be, the group's permissions are dropped, so no account can read the file that couldn't before.
/// - **Its extended attributes** (Finder tags and comments, the quarantine flag), copied before the rename.
/// - **Through links.** `path` may be a link: the file it points to is replaced, and the link stays a link. A
///   link to a file that is not there (on a volume not mounted) is refused, since a file would take its place.
/// - **Read-only stays read-only.** A file this account can't write is refused (`readOnly`): renaming over it
///   would work, but would undo what the read-only mark is for. So is anything but a plain file (`notAFile`).
/// - **No lost saves, where the caller asks** (`expecting`). Just before the rename the file is read again,
///   and when it no longer holds what the caller read (`contents`), or one turned up where there was none
///   (`noFile`), nothing is written (`changed`): the new bytes were made from the old ones, and would undo
///   that save. A new file is put in place only while there is still none: with `renamex_np`'s
///   `RENAME_EXCL`, or on a volume without it (exFAT), a plain rename once `lstat` finds nothing there.
/// - **Nothing left behind.** On every failure the temporary file is removed and the file is as it was.
///
/// What it does not:
/// - **It is not a lock.** A save by another program between that last check and the rename is still
///   replaced: macOS has no lock that other programs honour. The window is a few system calls.
/// - **The file's identity.** It is a new file under the old name: a program that has the file open keeps
///   reading the old bytes, and other hard links to it keep the old bytes too (they are no longer the same
///   file). Its owner becomes this account (a file of another account's that you may write through its
///   group); its ACL, file flags (`chflags`) and creation date are not copied.
/// - **The folder's own flush.** The folder is not `fsync`ed, and `fsync` is not `F_FULLFSYNC`: after a power
///   loss just after a write, the file can still have the old bytes, whole. It never has a part of either.
/// - **Missing folders.** The file's folder must be there, and this account must be able to write in it.
public enum SafeWrite {
    /// What the file must still hold just before it is replaced; otherwise nothing is written.
    public enum Expectation: Equatable, Sendable {
        /// Whatever it holds now: the caller has decided (an editor save, after the user chose).
        case anything
        /// No file: one that turns up meanwhile is left as it is.
        case noFile
        /// These bytes, the ones the new bytes were made from: a save by someone else since is kept.
        case contents(Data)
    }

    /// Why nothing was written. The file is as it was, and no temporary file is left.
    public enum Failure: Error, Equatable, LocalizedError {
        /// The file is not as the caller read it any more (`Expectation`): another program saved it.
        case changed
        /// This account can't write the file.
        case readOnly
        /// Not a plain file (a folder, a named pipe), or a link to a file that is not there.
        case notAFile
        /// A system call failed with this `errno`: no space left, a folder this account can't write in, a
        /// volume that went away.
        case system(Int32)

        public var errorDescription: String? {
            switch self {
            case .changed: return "It changed on disk while it was being written, so nothing was written."
            case .readOnly: return "It is read-only."
            case .notAFile: return "It is not a plain file, or it is a link to a file that is not there."
            case .system(EACCES), .system(EPERM): return "You don’t have permission to write in its folder."
            case .system(ENOSPC): return "The disk is full."
            case .system(EROFS): return "The disk it is on is read-only."
            case .system(let code): return String(cString: strerror(code)) + "."
            }
        }
    }

    /// Replaces the file at `path` with `data`, or throws `Failure` and changes nothing (see `SafeWrite`).
    public static func replace(_ path: String, with data: Data, expecting expected: Expectation = .anything,
                               newFileMode: mode_t = 0o600) throws {
        try replace(path, with: data, expecting: expected, newFileMode: newFileMode, system: System())
    }

    /// The system calls `replace` makes that a test can fail on purpose, and a look at the temporary file just
    /// before the check and the rename.
    struct System {
        var write: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }
        var fsync: (Int32) -> Int32 = { Darwin.fsync($0) }
        var rename: (String, String) -> Int32 = { Darwin.rename($0, $1) }
        /// Fails with ENOTSUP on exFAT, and EINVAL on a volume that refuses the flag.
        var exclusiveRename: (String, String) -> Int32 = { renamex_np($0, $1, UInt32(RENAME_EXCL)) }
        var beforeRename: (_ temporary: String) -> Void = { _ in }
    }

    static func replace(_ path: String, with data: Data, expecting expected: Expectation, newFileMode: mode_t,
                        system: System) throws {
        let target = canonicalPath(path)
        var info = stat()
        let exists = stat(target, &info) == 0
        if exists {
            guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.notAFile }
            if access(target, W_OK) != 0 { throw errno == EACCES ? Failure.readOnly : Failure.system(errno) }
        } else {
            guard errno == ENOENT else { throw Failure.system(errno) }
            var link = stat()
            if lstat(target, &link) == 0 { throw Failure.notAFile } // a link to a file that is not there
        }

        let folder = (target as NSString).deletingLastPathComponent
        let name = (target as NSString).lastPathComponent
        // Within the 255 bytes a name can have.
        let temporary = folder + "/." + (name.utf8.count > 200 ? "" : name) + ".nextterm-" + UUID().uuidString
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.system(errno) }
        var isOpen = true
        var placed = false
        defer {
            if isOpen { close(descriptor) }
            if !placed { unlink(temporary) }
        }

        let failure = data.withUnsafeBytes { buffer -> Int32 in
            var offset = 0
            while offset < buffer.count, let start = buffer.baseAddress {
                let count = system.write(descriptor, start + offset, buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return count < 0 ? errno : EIO }
                offset += count
            }
            return 0
        }
        guard failure == 0 else { throw Failure.system(failure) }
        var mode = exists ? info.st_mode & 0o777 : newFileMode & 0o777
        if exists {
            copyExtendedAttributes(of: target, to: descriptor)
            if !keepGroup(info.st_gid, of: descriptor) { mode &= ~0o070 }
        }
        guard fchmod(descriptor, mode) == 0, system.fsync(descriptor) == 0 else { throw Failure.system(errno) }
        isOpen = false
        guard close(descriptor) == 0 else { throw Failure.system(errno) }

        system.beforeRename(temporary)
        guard holds(expected, target) else { throw Failure.changed }
        if expected == .noFile {
            try putNew(temporary, at: target, system: system)
        } else if system.rename(temporary, target) != 0 {
            throw Failure.system(errno)
        }
        placed = true
    }

    /// Whether the file is still as the caller expects.
    private static func holds(_ expected: Expectation, _ path: String) -> Bool {
        switch expected {
        case .anything:
            return true
        case .noFile:
            var info = stat()
            return lstat(path, &info) != 0 && errno == ENOENT
        case .contents(let data):
            return FileManager.default.contents(atPath: path) == data
        }
    }

    /// Renames the temporary file to `target` only if nothing is there.
    private static func putNew(_ temporary: String, at target: String, system: System) throws {
        if system.exclusiveRename(temporary, target) == 0 { return }
        let failure = errno
        if failure == EEXIST { throw Failure.changed }
        guard failure == ENOTSUP || failure == EINVAL else { throw Failure.system(failure) }
        // No exclusive rename on this volume (exFAT): a plain one, once there is still nothing there.
        var info = stat()
        guard lstat(target, &info) != 0, errno == ENOENT else { throw Failure.changed }
        guard system.rename(temporary, target) == 0 else { throw Failure.system(errno) }
    }

    /// Finder tags and comments, the quarantine flag and the rest, as far as they can be copied.
    private static func copyExtendedAttributes(of path: String, to descriptor: Int32) {
        let source = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard source >= 0 else { return }
        defer { close(source) }
        _ = fcopyfile(source, descriptor, nil, copyfile_flags_t(COPYFILE_XATTR))
    }

    /// Gives the temporary file the file's group (a new file takes its folder's). False when that can't be done.
    private static func keepGroup(_ group: gid_t, of descriptor: Int32) -> Bool {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return false }
        return info.st_gid == group || fchown(descriptor, uid_t.max, group) == 0
    }
}
