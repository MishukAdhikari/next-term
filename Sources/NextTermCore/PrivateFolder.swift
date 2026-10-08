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
    static func make(at url: URL) throws -> PrivateFolder {
        let manager = FileManager.default
        try manager.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard isPrivate(url.path) else { throw NotPrivate(path: url.path) }
        return PrivateFolder(url: url)
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
