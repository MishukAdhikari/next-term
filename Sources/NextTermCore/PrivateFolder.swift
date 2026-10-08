import Foundation

/// A folder only this user can reach, made the way `mktemp -d` makes one: a new folder with a random name, mode 0700,
/// checked to be a real folder, not a link, owned by this user. An update's disk image waits in one, out of the shared
/// temporary folder, from its download through its checksum check and the mount.
public struct PrivateFolder: Sendable {
    public let url: URL

    /// What is at `path` is not a private folder made here: a name already taken, or a link planted there.
    public struct NotPrivate: LocalizedError {
        public let path: String
        public var errorDescription: String? { "A private folder could not be made at \(path)." }
    }

    /// A new one in `parent`, the temporary folder unless told otherwise, named `prefix` and a random part.
    public static func make(in parent: URL = FileManager.default.temporaryDirectory, prefix: String) throws -> PrivateFolder {
        try make(at: parent.appendingPathComponent(prefix + UUID().uuidString))
    }

    /// At `url`, which nothing may hold yet. A folder or a link already there is refused, never used or followed: the
    /// folder is made without its intermediate folders, which would take a folder that is there, or one a link leads to.
    /// One made here that fails the check (an unusual umask) is removed: a link put in its place goes, never what it
    /// leads to. `owner` is for the tests.
    static func make(at url: URL, owner: uid_t = geteuid()) throws -> PrivateFolder {
        let manager = FileManager.default
        try manager.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard isPrivate(url.path, owner: owner) else {
            try? manager.removeItem(at: url)
            throw NotPrivate(path: url.path)
        }
        return PrivateFolder(url: url)
    }

    /// The private folders in `parent` named `prefix` and more, made before `cutoff`: ones a quit or a crash left
    /// behind. A newer one may be another Next Term's, in use now. Links are never followed.
    public static func leftovers(in parent: URL = FileManager.default.temporaryDirectory, prefix: String,
                                 madeBefore cutoff: Date) -> [PrivateFolder] {
        let names: [String] = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        return names.sorted().filter { $0.hasPrefix(prefix) }.compactMap { name -> PrivateFolder? in
            let url = parent.appendingPathComponent(name)
            var info = stat()
            guard isPrivate(url.path), lstat(url.path, &info) == 0 else { return nil }
            let made = Date(timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec))
            return made < cutoff ? PrivateFolder(url: url) : nil
        }
    }

    /// Whether `path` itself, not what a link there leads to, is a plain file owned by `owner`.
    public static func isOwnFile(_ path: String, owner: uid_t = geteuid()) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        return info.st_uid == owner
    }

    /// Whether a volume is mounted at `path`: it is on another device than the folder holding it.
    public static func isMountPoint(_ path: String) -> Bool {
        var info = stat()
        var holder = stat()
        let parent = (path as NSString).deletingLastPathComponent
        guard lstat(path, &info) == 0, lstat(parent, &holder) == 0 else { return false }
        return info.st_dev != holder.st_dev
    }

    /// Whether `path` itself, not what a link there leads to, is a folder owned by `owner` that no one else can enter,
    /// read or write.
    public static func isPrivate(_ path: String, owner: uid_t = geteuid()) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        return info.st_uid == owner && info.st_mode & 0o777 == 0o700
    }

    /// Removes it and everything in it. Nothing happens when it is gone already.
    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
