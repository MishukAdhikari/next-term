import Foundation

/// The kernel's own spelling of a path (`/tmp` -> `/private/tmp`), which is what FSEvents reports.
/// `URL.resolvingSymlinksInPath()` is not this: it strips `/private` on purpose.
public func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// The project a directory belongs to: the nearest enclosing git work tree, else the directory itself. The look up stops
/// at the home folder (`home`, the user's when nil). What may be a project at all is `project(from:)`'s
/// (ProtectedPlaces.swift).
public enum ProjectRoot {
    public static func find(from directory: String, home: String? = nil, fileManager: FileManager = .default) -> String {
        var url = URL(fileURLWithPath: directory).standardizedFileURL
        let home = home.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
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
    /// A folder (a package is a file, as in Finder). A link `targetUnopened` has its name's guess until the user opens
    /// it (`settleKind`).
    public private(set) var isDirectory: Bool
    public let isSymlink: Bool
    /// Where a symlink leads, absolute: followed a link at a time by lstat and readlink (`resolve(link:protected:)`), up to
    /// the first protected place the link is not in, and spelled on from there as the links say. nil for anything else.
    public let linkTarget: String?
    /// The link leads into a protected place the link is not in (ProtectedPlaces.isUnopened: a link in ~ to
    /// ~/Documents/notes, or to ~/Dropbox/x where ~/Dropbox is a link into ~/Library/CloudStorage). Nothing in that place
    /// is looked at until the user opens the link: macOS would ask for it.
    public let targetUnopened: Bool
    /// The kind is what is on disk: false only for a link `targetUnopened` the user has not opened yet, whose kind is its
    /// name's guess.
    public private(set) var kindSettled: Bool
    private let isPackage: Bool
    public private(set) weak var parent: FileNode?
    /// nil until loaded.
    public private(set) var children: [FileNode]?
    /// Entries left out because the folder is larger than `maxChildren`.
    public private(set) var hiddenCount = 0
    /// macOS refused to list it (FolderAccess.isPrivacyDenial): it shows a line saying so in place of its entries.
    public private(set) var accessDenied = false

    /// Never shown: version-control internals and Finder litter.
    public static let hiddenNames: Set<String> = [".git", ".DS_Store", ".svn", ".hg"]

    /// `folder`: where the folder `url` is in really is, its links followed (`read` gives it): a link is in the place that
    /// is in, not the one its spelling says (~/notes/latest, ~/notes a link to ~/Documents/notes, is in Documents).
    public init(url: URL, parent: FileNode? = nil, protected: ProtectedPlaces = .current, in folder: String? = nil) {
        self.url = url
        self.parent = parent
        name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
        isSymlink = values?.isSymbolicLink ?? false
        isPackage = values?.isPackage ?? false
        var isDir = values?.isDirectory ?? false
        let resolved: (path: String, unopened: Bool)? = isSymlink ? Self.resolve(link: url, in: folder, protected: protected) : nil
        let unopened: Bool = resolved?.unopened ?? false
        if let resolved, unopened {
            // A look past the link would ask for that place, though the user opened neither it nor the link: its name
            // tells a folder ("notes") from a file ("notes.txt"), and the user's expand or open makes the real look.
            isDir = URL(fileURLWithPath: resolved.path).pathExtension.isEmpty
        } else if isSymlink {
            // Every link on the way is outside the protected places, or in the one the link is in: followed as before.
            var folder: ObjCBool = false
            isDir = FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
        }
        linkTarget = resolved?.path
        targetUnopened = unopened
        kindSettled = !unopened
        // App bundles and other packages behave as files, as in Finder.
        isDirectory = isDir && !isPackage
    }

    /// Where the link at `url` leads (a relative target is from the link's folder, `folder` when given), and whether that
    /// is in a protected place the link is not in (ProtectedPlaces.isUnopened). Each link on the way is followed as the
    /// kernel follows it, but by lstat and readlink, a component at a time (`resolved(_:stoppingAt:)`), and the walk stops
    /// at the first spelling in such a place: nothing in it is looked at, though a link may lead there through others
    /// (~/.zshrc to ~/Dropbox/zshrc, ~/Dropbox a link into ~/Library/CloudStorage). nil when the link can't be read.
    static func resolve(link url: URL, in folder: String? = nil, protected: ProtectedPlaces) -> (path: String, unopened: Bool)? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        let folder: String = folder ?? url.deletingLastPathComponent().path
        let absolute: String = destination.hasPrefix("/") ? destination : folder + "/" + destination
        let link: String = folder + "/" + url.lastPathComponent
        let walked: (path: String, stopped: Bool) = resolved(absolute) { (spelling: String) -> Bool in
            protected.isUnopened(spelling, from: link)
        }
        return (walked.path, walked.stopped)
    }

    /// The most links a walk follows, as the kernel's MAXSYMLINKS: more is a loop, or as good as one.
    static let maxLinks = 32

    /// `path` (absolute) with its links followed, as `realpath` would, but a component at a time by lstat and readlink, and
    /// never into a spelling `stops` turns down: there the walk ends, with that spelling and what was left of the path
    /// (`stopped`), and nothing in it is looked at. `.` and `..` are taken in turn, after the links before them, as the
    /// kernel takes them. A component that is not there ends the walk too (not stopped): a dangling link leads nowhere
    /// further. So does a loop, or a link that can't be read (stopped: neither is followed).
    static func resolved(_ path: String, stoppingAt stops: (String) -> Bool) -> (path: String, stopped: Bool) {
        // What is left, the next component last; and the walk so far, a real folder, "" for /.
        var left: [Substring] = path.split(separator: "/").reversed()
        var done: String = ""
        var links: Int = 0
        func rest(after spelling: String) -> String { lexical(spelling + "/" + left.reversed().joined(separator: "/")) }
        while let part = left.popLast() {
            if part == "." { continue }
            if part == ".." {
                // `done` has no link in it, so its spelling's parent is its real one.
                done = String(done[..<(done.lastIndex(of: "/") ?? done.startIndex)])
                continue
            }
            let next: String = done + "/" + part
            if stops(next) { return (rest(after: next), true) }
            var info = stat()
            guard lstat(next, &info) == 0 else { return (rest(after: next), false) }
            guard info.st_mode & S_IFMT == S_IFLNK else {
                done = next
                continue
            }
            links += 1
            guard links <= maxLinks, let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: next) else {
                return (rest(after: next), true)
            }
            if destination.hasPrefix("/") { done = "" }
            left.append(contentsOf: destination.split(separator: "/").reversed())
        }
        return (done.isEmpty ? "/" : done, false)
    }

    /// `absolute` with `.` and `..` resolved by the spelling alone: Foundation's standardizing looks on disk to spell
    /// /private/var as /var.
    static func lexical(_ absolute: String) -> String {
        var parts: [Substring] = []
        for part in absolute.split(separator: "/") where part != "." {
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// What the link at `url` leads to, read past it for the user's own open of it (macOS may ask for the place it is in,
    /// and holds the look until the user answers, so not on the main thread): a folder, or not (a file, or nothing there);
    /// nil when the look was refused (macOS's Don't Allow, or the folder's own permissions), so its kind is still a guess.
    public static func isFolder(followingLinkAt url: URL) -> Bool? {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            let code: Int32 = errno
            return code == EPERM || code == EACCES ? nil : false
        }
        return info.st_mode & S_IFMT == S_IFDIR
    }

    /// The user opened a link whose kind was its name's guess (`targetUnopened`): `folder`, what
    /// `isFolder(followingLinkAt:)` read past it, is its kind from now on, and its folder's order follows. nil (the look
    /// was refused) leaves the guess. Returns whether the kind changed. Main thread, as `install`.
    @discardableResult
    public func settleKind(_ folder: Bool?) -> Bool {
        guard targetUnopened, !kindSettled, let folder else { return false }
        kindSettled = true
        let settled: Bool = folder && !isPackage
        guard settled != isDirectory else { return false }
        isDirectory = settled
        if !settled {
            // A file has no entries: whatever a read of it as a folder left goes.
            children = nil
            hiddenCount = 0
            accessDenied = false
        }
        parent?.children?.sort(by: Self.precedes)
        return true
    }

    /// Folders first, then Finder order ("file2" before "file10").
    static func precedes(_ a: FileNode, _ b: FileNode) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    public var path: String { url.path }
    public var isLoaded: Bool { children != nil }

    /// A folder's entries as fresh nodes, folders first, in Finder order ("file2" before "file10"), without the
    /// ones `hiding` leaves out. Safe on any thread.
    public static func readChildren(of url: URL, hiding: FileHiding? = nil) -> (nodes: [FileNode], hidden: Int) {
        let listing = read(url, hiding: hiding)
        return (listing.nodes, listing.hidden)
    }

    /// What one read of a folder found: its entries, how many were left out, and whether macOS refused it.
    public struct Listing {
        public var nodes: [FileNode]
        public var hidden: Int
        public var denied: Bool
    }

    /// `readChildren`, saying too whether macOS's privacy protection refused the folder (FolderAccess.isPrivacyDenial), so
    /// the tree can say so where the user asked for it. Only the folder itself is listed: a tree is read a folder at a
    /// time, as the user opens them.
    public static func read(_ url: URL, hiding: FileHiding? = nil, protected: ProtectedPlaces = .current) -> Listing {
        ProtectedPlaces.noteListed(url.path)
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        } catch {
            return Listing(nodes: [], hidden: 0, denied: isPrivacyDenial(error, reading: url, protected: protected))
        }
        // Where the folder really is, for the links in it: the listing went there already, so the walk goes nowhere new.
        let folder: String = resolved(url.path) { _ in false }.path
        let nodes = names.filter { !hiddenNames.contains($0) }
            .map { FileNode(url: url.appendingPathComponent($0), protected: protected, in: folder) }
            .filter { hiding?.hides($0.path, isDirectory: $0.isDirectory) != true }
            .sorted(by: precedes)
        return Listing(nodes: Array(nodes.prefix(maxChildren)), hidden: max(0, nodes.count - maxChildren), denied: false)
    }

    /// The read of `url` failed with `error`: whether macOS refused it (FolderAccess.isPrivacyDenial), as spelled or where
    /// its links lead. Through a link it is the place the link leads to that macOS refused (~/notes to ~/Documents/notes,
    /// ~/Dropbox into ~/Library/CloudStorage), not the link's own spelling: that place is found link by link
    /// (`resolved(_:stoppingAt:)`), up to the first protected spelling, so nothing in one is looked at.
    static func isPrivacyDenial(_ error: Error, reading url: URL, protected: ProtectedPlaces) -> Bool {
        if FolderAccess.isPrivacyDenial(error, path: url.path, protected: protected) { return true }
        let led: String = resolved(url.path, stoppingAt: protected.holds).path
        return led != url.path && FolderAccess.isPrivacyDenial(error, path: led, protected: protected)
    }

    /// Installs a read (`install`), and whether macOS refused it. Returns true if anything changed.
    @discardableResult
    public func install(_ listing: Listing) -> Bool {
        let deniedChanged = accessDenied != listing.denied
        accessDenied = listing.denied
        let changed = install((listing.nodes, listing.hidden))
        return changed || deniedChanged
    }

    /// Installs a listing, keeping the existing node (and so its expanded state and loaded children)
    /// for every entry that is still there. Returns true if anything changed.
    @discardableResult
    public func install(_ listing: (nodes: [FileNode], hidden: Int)) -> Bool {
        let old = children ?? []
        let byName = Dictionary(old.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var reordered = false
        let merged = listing.nodes.map { fresh -> FileNode in
            if let existing = byName[fresh.name], existing.isDirectory == fresh.isDirectory || existing.keepsKind(over: fresh) {
                // A kind the user's open settled is not the fresh guess's: its place in the order is not either.
                if existing.isDirectory != fresh.isDirectory { reordered = true }
                return existing
            }
            fresh.parent = self
            return fresh
        }
        let ordered: [FileNode] = reordered ? merged.sorted(by: Self.precedes) : merged
        let changed = children == nil || ordered.count != old.count || zip(ordered, old).contains { $0 !== $1 }
            || listing.hidden != hiddenCount
        children = ordered
        hiddenCount = listing.hidden
        return changed
    }

    /// A link whose kind the user's open settled (`settleKind`) stays over a fresh read's guess of the same link: each
    /// read guesses again from the name, and only the user's look tells what is there.
    private func keepsKind(over fresh: FileNode) -> Bool {
        targetUnopened && kindSettled && fresh.targetUnopened && linkTarget == fresh.linkTarget
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
