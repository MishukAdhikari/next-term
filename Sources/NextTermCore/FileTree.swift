import Foundation

/// The kernel's own spelling of a path (`/tmp` -> `/private/tmp`), which is what FSEvents reports.
/// `URL.resolvingSymlinksInPath()` is not this: it strips `/private` on purpose.
public func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// The project a directory belongs to: the nearest enclosing git work tree, else the directory itself.
public enum ProjectRoot {
    public static func find(from directory: String, fileManager: FileManager = .default) -> String {
        var url = URL(fileURLWithPath: directory).standardizedFileURL
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        while true {
            // `.git` is a directory in a clone and a file in a worktree or submodule.
            if fileManager.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            let parent = url.deletingLastPathComponent()
            if url.path == "/" || url.path == home || parent.path == url.path { break }
            url = parent
        }
        return URL(fileURLWithPath: directory).standardizedFileURL.path
    }
}

/// One entry in the project tree. Children load lazily, the first time a folder is expanded.
public final class FileNode {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    public private(set) weak var parent: FileNode?
    /// nil until loaded.
    public private(set) var children: [FileNode]?

    /// Never shown: version-control internals and Finder litter.
    public static let hiddenNames: Set<String> = [".git", ".DS_Store", ".svn", ".hg"]

    public init(url: URL, parent: FileNode? = nil) {
        self.url = url
        self.parent = parent
        name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
        isSymlink = values?.isSymbolicLink ?? false
        var isDir = values?.isDirectory ?? false
        if isSymlink {
            var target: ObjCBool = false
            isDir = FileManager.default.fileExists(atPath: url.path, isDirectory: &target) && target.boolValue
        }
        // App bundles and other packages behave as files, as in Finder.
        isDirectory = isDir && !(values?.isPackage ?? false)
    }

    public var path: String { url.path }
    public var isLoaded: Bool { children != nil }

    public func loadChildren() {
        children = Self.listing(of: url, parent: self, reusing: [])
    }

    /// Re-reads the folder, keeping existing nodes (and so their expanded state) for entries that remain.
    /// Returns true if anything changed.
    @discardableResult
    public func reload() -> Bool {
        guard isDirectory else { return false }
        let old = children ?? []
        let fresh = Self.listing(of: url, parent: self, reusing: old)
        let changed = fresh.map(\.name) != old.map(\.name) || zip(fresh, old).contains { $0 !== $1 }
        children = fresh
        return changed
    }

    /// Finds the loaded node for a path under this one.
    public func node(at path: String) -> FileNode? {
        if path == self.path { return self }
        guard path.hasPrefix(self.path.hasSuffix("/") ? self.path : self.path + "/"), let children else { return nil }
        for child in children where child.isDirectory {
            if let found = child.node(at: path) { return found }
        }
        return nil
    }

    /// Folders first, then files, each in Finder order ("file2" before "file10").
    static func listing(of url: URL, parent: FileNode, reusing existing: [FileNode]) -> [FileNode] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
        let byName = Dictionary(existing.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let nodes = names.filter { !hiddenNames.contains($0) }.map { name -> FileNode in
            if let node = byName[name] { return node }
            return FileNode(url: url.appendingPathComponent(name), parent: parent)
        }
        return nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
