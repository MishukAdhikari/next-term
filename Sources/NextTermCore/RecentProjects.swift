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

    public mutating func remove(_ path: String) {
        paths.removeAll { $0 == path }
    }

    public mutating func clear() {
        paths.removeAll()
    }

    /// The ones whose folder still exists.
    public func existing(fileManager: FileManager = .default) -> [String] {
        paths.filter { path in
            var isDir: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    /// "~/Code/xCloud" for display.
    public static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
