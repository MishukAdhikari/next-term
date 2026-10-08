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
///
/// Reading a folder (`readChildren`) touches the disk and may run on any thread; installing the result
/// (`install`) mutates the tree and belongs to the main thread.
public final class FileNode {
    /// Folders with more entries than this show the first ones and a "… N more" note.
    public static let maxChildren = 5000

    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    public private(set) weak var parent: FileNode?
    /// nil until loaded.
    public private(set) var children: [FileNode]?
    /// Entries left out because the folder is larger than `maxChildren`.
    public private(set) var hiddenCount = 0

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

    /// A folder's entries as fresh nodes, folders first, in Finder order ("file2" before "file10"), without the
    /// ones `hiding` leaves out. Safe on any thread.
    public static func readChildren(of url: URL, hiding: FileHiding? = nil) -> (nodes: [FileNode], hidden: Int) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return ([], 0) }
        let nodes = names.filter { !hiddenNames.contains($0) }
            .map { FileNode(url: url.appendingPathComponent($0)) }
            .filter { hiding?.hides($0.path, isDirectory: $0.isDirectory) != true }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        return (Array(nodes.prefix(maxChildren)), max(0, nodes.count - maxChildren))
    }

    /// Installs a listing, keeping the existing node (and so its expanded state and loaded children)
    /// for every entry that is still there. Returns true if anything changed.
    @discardableResult
    public func install(_ listing: (nodes: [FileNode], hidden: Int)) -> Bool {
        let old = children ?? []
        let byName = Dictionary(old.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let merged = listing.nodes.map { fresh -> FileNode in
            if let existing = byName[fresh.name], existing.isDirectory == fresh.isDirectory { return existing }
            fresh.parent = self
            return fresh
        }
        let changed = children == nil || merged.count != old.count || zip(merged, old).contains { $0 !== $1 }
            || listing.hidden != hiddenCount
        children = merged
        hiddenCount = listing.hidden
        return changed
    }

    /// Reads and installs synchronously (tests, small folders).
    public func loadChildren() {
        install(Self.readChildren(of: url))
    }

    @discardableResult
    public func reload(hiding: FileHiding? = nil) -> Bool {
        guard isDirectory else { return false }
        return install(Self.readChildren(of: url, hiding: hiding))
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

    /// Path relative to `root` ("" for root itself), or nil if outside it.
    public func relativePath(to root: String) -> String? {
        if path == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }
}

/// File operations for the project tree, with the rules the UI relies on.
public enum FileOps {
    /// Why a name cannot be used, or nil if it can.
    public static func problem(withName name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "A name can’t be empty." }
        if name.contains("/") { return "A name can’t contain “/”." }
        if name == "." || name == ".." { return "“\(name)” is reserved." }
        if name.contains("\0") || name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return "A name can’t contain control characters."
        }
        if name.utf8.count > 255 { return "That name is too long." }
        return nil
    }

    /// `name` if free in `folder`, else "name 2.ext", "name 3.ext", … (like Finder's Keep Both).
    public static func availableName(_ name: String, in folder: URL, fileManager: FileManager = .default) -> String {
        func taken(_ candidate: String) -> Bool {
            fileManager.fileExists(atPath: folder.appendingPathComponent(candidate).path)
                || (try? folder.appendingPathComponent(candidate).checkResourceIsReachable()) == true
        }
        guard taken(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty || name.hasPrefix(".") && !name.dropFirst().contains(".") ? name : (name as NSString).deletingPathExtension
        let suffix = stem == name ? "" : "." + ext
        var n = 2
        while taken("\(stem) \(n)\(suffix)") { n += 1 }
        return "\(stem) \(n)\(suffix)"
    }

    /// Whether `source` can be moved into `folder`: not into itself, a descendant, or where it already is.
    public static func canMove(_ source: URL, into folder: URL) -> Bool {
        let from = canonicalPath(source.path), to = canonicalPath(folder.path)
        if to == from || to.hasPrefix(from + "/") { return false }
        return canonicalPath(source.deletingLastPathComponent().path) != to
    }

    /// Moves (or copies) items into a folder, keeping both when a name is taken.
    /// Returns where each item went, in order, for undo.
    public static func transfer(_ sources: [URL], into folder: URL, copy: Bool,
                                fileManager: FileManager = .default) throws -> [(from: URL, to: URL)] {
        var done: [(URL, URL)] = []
        for source in sources {
            guard copy || canMove(source, into: folder) else { continue }
            let target = folder.appendingPathComponent(availableName(source.lastPathComponent, in: folder, fileManager: fileManager))
            if copy { try fileManager.copyItem(at: source, to: target) } else { try fileManager.moveItem(at: source, to: target) }
            done.append((source, target))
        }
        return done
    }

    /// Renames in place. Case-only renames ("readme" -> "README") work on case-insensitive volumes.
    public static func rename(_ url: URL, to newName: String, fileManager: FileManager = .default) throws -> URL {
        if let problem = problem(withName: newName) {
            throw NSError(domain: "NextTerm", code: 1, userInfo: [NSLocalizedDescriptionKey: problem])
        }
        let target = url.deletingLastPathComponent().appendingPathComponent(newName)
        if target.lastPathComponent == url.lastPathComponent { return url }
        let caseOnly = target.lastPathComponent.lowercased() == url.lastPathComponent.lowercased()
        if !caseOnly, fileManager.fileExists(atPath: target.path) {
            throw NSError(domain: "NextTerm", code: 2, userInfo: [NSLocalizedDescriptionKey: "“\(newName)” already exists here."])
        }
        if caseOnly { // through a temporary name, or the volume sees no change
            let temp = url.deletingLastPathComponent().appendingPathComponent(".nextterm-rename-\(UUID().uuidString)")
            try fileManager.moveItem(at: url, to: temp)
            try fileManager.moveItem(at: temp, to: target)
        } else {
            try fileManager.moveItem(at: url, to: target)
        }
        return target
    }
}

/// A plain file (not a named pipe, socket or device): only these are read. Opening a named pipe waits
/// for a writer, which could be forever.
public func isRegularFile(_ path: String) -> Bool {
    var info = stat()
    return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
}
