import Foundation

/// Most recently opened projects first, without duplicates, at most `limit`.
public struct RecentProjects: Equatable, Sendable {
    public static let limit = 10
    public private(set) var paths: [String]

    public init(_ paths: [String] = []) {
        var seen = Set<String>()
        self.paths = Array(paths.filter { seen.insert($0).inserted }.prefix(Self.limit))
    }

    public mutating func add(_ path: String) {
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > Self.limit { paths.removeLast(paths.count - Self.limit) }
    }

    /// Projects brought over from another app: after this list's own, never pushing them out. Returns
    /// the ones added.
    @discardableResult
    public mutating func appendImported(_ imported: [String]) -> [String] {
        var added: [String] = []
        for path in imported where paths.count < Self.limit && !paths.contains(path) {
            paths.append(path)
            added.append(path)
        }
        return added
    }

    public mutating func remove(_ path: String) {
        paths.removeAll { $0 == path }
    }

    /// Undo of a forget: the path back at `index`, where it stood, or at the end when the list is shorter now. One
    /// listed again since stays where it is. Past the limit the last one goes, as for an open.
    public mutating func restore(_ path: String, at index: Int) {
        guard !paths.contains(path) else { return }
        paths.insert(path, at: min(max(index, 0), paths.count))
        if paths.count > Self.limit { paths.removeLast(paths.count - Self.limit) }
    }

    public mutating func clear() {
        paths.removeAll()
    }

    /// The ones whose folder still exists. One in a protected place (ProtectedPlaces: ~/Documents/site, a disk in
    /// /Volumes) is listed as saved, without a look: looking would set off macOS's prompt for that place before the user
    /// opened anything. It is checked when it is opened. One on a disk is listed while the kernel's mount table
    /// (`mounted`) has that disk, so one on an unplugged disk is left out, never chosen and dropped as gone.
    public func existing(fileManager: FileManager = .default, protected: ProtectedPlaces = .current,
                         mounted: Set<String> = ProtectedPlaces.mountPoints()) -> [String] {
        paths.filter { path in
            if protected.holds(path) { return ProtectedPlaces.seemsThere(path, mounted: mounted) }
            var isDir: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    /// "~/Code/xCloud" for display.
    public static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
