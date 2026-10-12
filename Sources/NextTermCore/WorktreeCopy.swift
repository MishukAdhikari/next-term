import Foundation
import os

/// Open in New Worktree's "Copy ignored files too": what the source checkout's git ignores (node_modules/, vendor/,
/// .env, build output) cloned into the new worktree, so it runs without installing again. APFS clones: no data is
/// copied, the two share disk space until either side changes, and modes, times and links are kept as they are.
///
/// - What: git's own list of the ignored entries (`ls-files --others --ignored --directory`, a wholly ignored folder
///   as one entry), only those the new worktree's branch ignores too, so nothing it tracks is ever touched.
/// - Never: .git, another worktree (a registered one, or a folder with a `.git` file), anything on another disk, a
///   socket, FIFO or device, a link leading out of the checkout. Never over anything that is there, never a byte
///   copy (a disk that can't clone gets no copy), never a link followed.
/// - Left out by default (`rule`), as they'd point back at the source checkout: logs, Laravel's cached config,
///   `public/hot`, maintenance mode, pid files and sockets, Swift and Xcode builds, Python virtualenvs. A path the
///   checkout's `.worktreeinclude` lists brings one back.
/// - How: each entry's folders are cloned a level down (`node_modules/<package>`, `vendor/<vendor>`), one clone
///   call each: a whole tree in one call holds the disk for its length (clonefile(2) discourages it). At low I/O
///   priority, one at a time, with Stop between calls.
/// Plan: claudedocs/2026-10-09-worktree-from-switch-guard-plan.md, D13b.
public enum WorktreeCopy {
    // MARK: what is left out

    /// Why a path wasn't copied.
    public enum LeftOut: Equatable, Sendable {
        case worktree, repository, linkOut, special, otherDisk, alreadyThere, notIgnoredThere
        /// A built-in rule, with its reason.
        case rule(String)
        /// It couldn't be copied (strerror).
        case failed(String)

        public var reason: String {
            switch self {
            case .worktree: return "another worktree"
            case .repository: return "a repository of its own"
            case .linkOut: return "a link out of the checkout"
            case .special: return "not a file or folder"
            case .otherDisk: return "on another disk"
            case .alreadyThere: return "already there"
            case .notIgnoredThere: return "the new branch doesn’t ignore it"
            case let .rule(reason): return reason
            case let .failed(error): return error
            }
        }

        /// Left out by design, not for an error: the notice counts these, a question lists the others.
        public var isExpected: Bool {
            if case .failed = self { return false }
            return true
        }
    }

    public struct Item: Equatable, Sendable {
        public var path: String
        public var why: LeftOut
        public init(_ path: String, _ why: LeftOut) {
            self.path = path
            self.why = why
        }
    }

    public struct Report: Equatable, Sendable {
        /// The paths cloned, each one clone call (a folder with all it holds).
        public var copied: [String] = []
        /// How many of the entries git listed got something copied: what the notice counts.
        public var entries = 0
        public var leftOut: [Item] = []
        /// Stop was pressed: what was copied stays.
        public var stopped = false
        /// Why the copy ended before the end (no space left, a disk that can't clone, git couldn't say).
        public var fatal: String?
        public init() {}

        /// What went wrong, for the question after: errors, never what was left out by design.
        public var failures: [Item] { leftOut.filter { !$0.why.isExpected } }
    }

    /// What is left out by default, and why, for `path` (relative to the checkout): what would point back at the
    /// source checkout once copied, or belong to a process running there. A folder holding `pyvenv.cfg` is a
    /// virtualenv (`isVirtualenv`).
    public static func rule(for path: String, isFolder: Bool, isVirtualenv: Bool = false) -> String? {
        let name = (path as NSString).lastPathComponent
        if name == ".DS_Store" { return "Finder’s own" }
        if !isFolder, name.hasSuffix(".log") { return "a log of this checkout’s" }
        if path == "storage/logs" || path.hasPrefix("storage/logs/") { return "a log of this checkout’s" }
        if path.hasPrefix("bootstrap/cache/"), name.hasSuffix(".php") { return "Laravel’s cache, with this checkout’s paths in it" }
        if path == "public/hot" { return "points at this checkout’s Vite server" }
        if path == "storage/framework/down" || path == "storage/framework/maintenance.php" { return "this checkout’s maintenance mode" }
        if !isFolder, name.hasSuffix(".pid") || name.hasSuffix(".sock") { return "a running process’s" }
        if isFolder, name == ".build" || name == "DerivedData" { return "a Swift or Xcode build, tied to this checkout’s path" }
        if isFolder, isVirtualenv { return "a Python virtualenv, tied to this checkout’s path" }
        return nil
    }

    /// Folders that hold worktrees (Claude Code's, worktrunk's, Conductor's): never cloned whole, gone through.
    static let containers: Set<String> = [".claude", ".worktrees", "worktrees", ".conductor"]

    /// Whether a link at `path` (relative to the checkout) with `target` stays inside the checkout: a relative
    /// target that never climbs above the checkout's top (`node_modules/.bin/vite` → `../vite/bin/vite.js`).
    public static func linkStaysInside(_ path: String, target: String) -> Bool {
        guard !target.isEmpty, !target.hasPrefix("/") else { return false }
        var depth = path.split(separator: "/").count - 1 // the folders the link is in
        for part in target.split(separator: "/", omittingEmptySubsequences: true) {
            if part == ".." { depth -= 1 } else if part != "." { depth += 1 }
            if depth < 0 { return false }
        }
        return true
    }

    // MARK: what it says

    /// The checkbox: "Copy ignored files too: node_modules/, vendor/, .env…", naming up to three of `ignored` (the
    /// sidebar's ignored entries at the checkout's top, folders with "/"), the usual ones first; worktree folders
    /// are never named. Nil when there is nothing to copy.
    public static func checkboxTitle(ignored: [String]) -> String? {
        let shown = ignored.filter { !containers.contains($0.hasSuffix("/") ? String($0.dropLast()) : $0) && $0 != ".DS_Store" }
        guard !shown.isEmpty else { return nil }
        let first = ["node_modules/", "vendor/", ".env"]
        let ordered = first.filter(shown.contains) + shown.filter { !first.contains($0) }.sorted()
        return "Copy ignored files too: " + ordered.prefix(3).joined(separator: ", ") + (ordered.count > 3 ? "…" : "")
    }

    /// The sheet's footnote while the box is ticked.
    public static func footnote(checkout: String) -> String {
        "\(checkout) and its changes stay as they are. The new folder also gets clones of what \(checkout)’s git ignores, "
            + ".env and keys included (so the same database and services), sharing disk space until either side changes. "
            + "Left out: other worktrees, logs, Python virtualenvs, .build and Laravel’s cached config."
    }

    /// Why the box is off: the new folder isn't on a disk where it can be cloned from the checkout.
    public static let cantClone = "Copying needs the new folder on the same APFS disk as the checkout: clones share space, a copy would fill the disk."

    /// The notice's part: "; copied 72 ignored items, 6 left out; run composer install there".
    public static func notice(_ report: Report, hints: [String]) -> String {
        guard !report.copied.isEmpty || !report.leftOut.isEmpty || report.stopped else { return "" }
        var text = "; copied \(report.entries) ignored item\(report.entries == 1 ? "" : "s")"
        if report.stopped { text += " before Stop" }
        let left = report.leftOut.filter(\.why.isExpected).count
        if left > 0 { text += ", \(left) left out" }
        if !hints.isEmpty { text += "; run " + hints.joined(separator: " and ") + " there" }
        return text
    }

    /// What to run in the new worktree: `composer install` when composer.lock differs between the two (vendor/ was
    /// copied), `composer dump-autoload` when only the code does (its optimized classmap names the source's
    /// classes), the package manager's install when its lock file differs (node_modules/ was copied). Never `npm ci`:
    /// it deletes node_modules.
    public static func hints(differs: Set<String>, vendorCopied: Bool, classmapCopied: Bool, headsDiffer: Bool, nodeModulesCopied: Bool) -> [String] {
        var hints: [String] = []
        if vendorCopied {
            if differs.contains("composer.lock") { hints.append("composer install") } else if classmapCopied, headsDiffer { hints.append("composer dump-autoload") }
        }
        if nodeModulesCopied {
            let installs = [("package-lock.json", "npm install"), ("yarn.lock", "yarn install"), ("pnpm-lock.yaml", "pnpm install"),
                            ("bun.lock", "bun install"), ("bun.lockb", "bun install")]
            for (lock, install) in installs where differs.contains(lock) && !hints.contains(install) { hints.append(install) }
        }
        return hints
    }

    /// Git Commands' entry: what was cloned and what was left out, with why.
    public static func logText(_ report: Report) -> String {
        var lines = ["Cloned \(report.copied.count) (sharing disk space with the checkout until either side changes):"]
        lines += report.copied.map { "  " + $0 }
        if !report.leftOut.isEmpty {
            lines.append("Left out:")
            lines += report.leftOut.map { "  \($0.path): \($0.why.reason)" }
        }
        if report.stopped { lines.append("Stopped: what was cloned before Stop stays.") }
        if let fatal = report.fatal { lines.append("Ended early: \(fatal)") }
        return lines.joined(separator: "\n")
    }

    // MARK: reading git

    /// The ignored entries at `root`: a wholly ignored folder as one entry ending in "/". Nil when git can't say.
    public static func ignoredEntries(in root: String, git: String) -> [String]? {
        GitRunner.run(git, ["-C", root, "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory", "--no-empty-directory"],
                      timeout: 60).map(split)
    }

    /// Which of `paths` the checkout at `root` ignores (folders as "dir/"). Nil when git can't say.
    public static func ignoredThere(_ paths: [String], in root: String, git: String) -> Set<String>? {
        guard !paths.isEmpty else { return [] }
        let input = Data(paths.joined(separator: "\0").utf8) + Data([0])
        return GitRunner.run(git, ["-C", root, "check-ignore", "-z", "--stdin"], timeout: 60, acceptedStatus: [0, 1], input: input)
            .map { Set(split($0)) }
    }

    private static func split(_ data: Data) -> [String] {
        data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The entries to clone: the source's ignored entries the new worktree ignores too. A folder the new branch
    /// doesn't ignore as a whole (no pattern names it, though everything in it is ignored) is gone through, a level
    /// at a time, for what it does ignore; what it tracks or doesn't ignore is never touched. Nil when git can't say.
    public static func entries(from source: String, to destination: String, git: String) -> [String]? {
        guard let listed = ignoredEntries(in: source, git: git) else { return nil }
        return keep(listed, source: source, depth: 0) { ignoredThere($0, in: destination, git: git) }
    }

    /// `entries`, with what the new worktree ignores asked of `ignored`.
    static func keep(_ paths: [String], source: String, depth: Int, ignored: ([String]) -> Set<String>?) -> [String]? {
        guard let there = ignored(paths) else { return nil }
        var kept: [String] = []
        for path in paths {
            if there.contains(path) {
                kept.append(path)
            } else if path.hasSuffix("/"), depth < 4 {
                let folder = String(path.dropLast())
                let children = ((try? FileManager.default.contentsOfDirectory(atPath: source + "/" + folder)) ?? []).sorted().map { name -> String in
                    var info = stat()
                    let child = folder + "/" + name
                    return lstat(source + "/" + child, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR ? child + "/" : child
                }
                guard let inside = keep(children, source: source, depth: depth + 1, ignored: ignored) else { return nil }
                kept += inside
            }
        }
        return kept
    }

    /// Whether the checkout at `root` tracks anything in `folder` (`clone`'s `hasTracked`); true when git can't say,
    /// so a folder there is gone through, never taken for something a hook made.
    public static func tracks(_ folder: String, in root: String, git: String) -> Bool {
        GitRunner.run(git, ["-C", root, "ls-files", "-z", "--", folder], timeout: 30).map { !$0.isEmpty } ?? true
    }

    /// The registered worktrees of the repository at `root`, as git lists them now.
    public static func worktrees(of root: String, git: String) -> [String] {
        guard let data = GitRunner.run(git, ["-C", root, "worktree", "list", "--porcelain", "-z"], timeout: 30) else { return [] }
        return split(data).compactMap { $0.hasPrefix("worktree ") ? String($0.dropFirst("worktree ".count)) : nil }
    }

    /// Whether the new worktree can get clones: `folder` (or the nearest folder of it that exists) on the same disk as
    /// `source`, and that disk clones files.
    public static func canClone(from source: String, into folder: String) -> Bool {
        var at = folder
        var info = stat(), here = stat()
        while lstat(at, &info) != 0 {
            let up = (at as NSString).deletingLastPathComponent
            guard up != at, !up.isEmpty else { return false }
            at = up
        }
        guard lstat(source, &here) == 0, here.st_dev == info.st_dev else { return false }
        return (try? URL(fileURLWithPath: source).resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?.volumeSupportsFileCloning == true
    }

    // MARK: cloning

    /// Stop Copying, from the main thread; read between clone calls.
    public final class Stop: @unchecked Sendable {
        private let flag = OSAllocatedUnfairLock(initialState: false)
        public init() {}
        public func set() { flag.withLock { $0 = true } }
        public var isSet: Bool { flag.withLock { $0 } }
    }

    struct FileID: Hashable {
        let device: dev_t
        let inode: ino_t
        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
        }
        init?(_ path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            self.init(info)
        }
    }

    /// Clones `entries` (from `entries(from:to:git:)`) from `source` into `destination`, a worktree of the same
    /// repository as `worktrees` lists them. `includes`: the paths `.worktreeinclude` lists, which bring back what a
    /// rule leaves out. `hasTracked`: whether the new worktree tracks something in a folder (that one is gone through
    /// rather than left out, when it is there already). `progress` gets each entry as it starts, with its place.
    public static func clone(_ entries: [String], from source: String, to destination: String, worktrees: [String], includes: Set<String> = [],
                             hasTracked: @escaping (String) -> Bool, stop: Stop = Stop(), progress: (String, Int, Int) -> Void = { _, _, _ in }) -> Report {
        var info = stat()
        guard lstat(source, &info) == 0 else {
            var report = Report()
            report.fatal = "the checkout is gone"
            return report
        }
        let canonicalSource = canonicalPath(source)
        var avoid = Set(worktrees.compactMap(FileID.init))
        if let own = FileID(source) { avoid.remove(own) }
        if let new = FileID(destination) { avoid.insert(new) }
        let inside = (worktrees + [destination]).map(canonicalPath).compactMap { path -> String? in
            path.hasPrefix(canonicalSource + "/") ? String(path.dropFirst(canonicalSource.count + 1)) : nil
        }
        var engine = Engine(source: source, destination: destination, device: info.st_dev, avoid: avoid, worktreesInside: inside,
                            includes: includes, hasTracked: hasTracked, stop: stop)
        // A clone is metadata only, but many at once still keep the disk busy: behind the tabs' own reads.
        let policy = getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_UTILITY)
        defer { if policy >= 0 { setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, policy) } }
        for (index, entry) in entries.enumerated() {
            if engine.report.fatal != nil { break }
            if stop.isSet {
                engine.report.stopped = true
                break
            }
            let path = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
            guard !path.isEmpty, WorktreeInclude.isInside(path) else { continue }
            progress(path, index + 1, entries.count)
            let before = engine.report.copied.count
            engine.place(path, depth: 0)
            if engine.report.copied.count > before { engine.report.entries += 1 }
        }
        return engine.report
    }

    private struct Engine {
        let source: String
        let destination: String
        let device: dev_t
        let avoid: Set<FileID>
        /// The worktrees inside the source checkout, relative to it: a folder holding one is gone through.
        let worktreesInside: [String]
        let includes: Set<String>
        let hasTracked: (String) -> Bool
        let stop: Stop
        var report = Report()
        /// Folders this copy made at the destination.
        var made: Set<String> = []

        func included(_ path: String) -> Bool {
            includes.contains(path) || includes.contains { $0.hasPrefix(path + "/") }
        }

        mutating func leave(_ path: String, _ why: LeftOut) { report.leftOut.append(Item(path, why)) }

        mutating func place(_ path: String, depth: Int) {
            guard report.fatal == nil else { return }
            if stop.isSet {
                report.stopped = true
                return
            }
            let from = source + "/" + path
            var info = stat()
            guard lstat(from, &info) == 0 else { return } // gone since git listed it
            guard info.st_dev == device else { return leave(path, .otherDisk) }
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: from),
                      WorktreeCopy.linkStaysInside(path, target: target) else { return leave(path, .linkOut) }
                if let rule = WorktreeCopy.rule(for: path, isFolder: false), !included(path) { return leave(path, .rule(rule)) }
                clone(path, isFolder: false)
            case S_IFREG:
                if let rule = WorktreeCopy.rule(for: path, isFolder: false), !included(path) { return leave(path, .rule(rule)) }
                clone(path, isFolder: false)
            case S_IFDIR:
                if avoid.contains(FileID(info)) { return leave(path, .worktree) }
                var git = stat()
                if lstat(from + "/.git", &git) == 0, git.st_mode & S_IFMT == S_IFREG { return leave(path, .worktree) }
                let virtualenv = FileManager.default.fileExists(atPath: from + "/pyvenv.cfg")
                if let rule = WorktreeCopy.rule(for: path, isFolder: true, isVirtualenv: virtualenv), !included(path) { return leave(path, .rule(rule)) }
                let name = (path as NSString).lastPathComponent
                let holdsWorktree = worktreesInside.contains { $0 == path || $0.hasPrefix(path + "/") }
                // An entry's folders go a level down, each in a call of its own (node_modules/<package>).
                let through = depth == 0 || holdsWorktree || WorktreeCopy.containers.contains(name)
                var there = stat()
                if lstat(destination + "/" + path, &there) == 0 {
                    // There already: gone through when this copy made it or the new branch tracks something in it
                    // (a .gitkeep); else something else made it (a hook's install) and it is left as it is.
                    guard there.st_mode & S_IFMT == S_IFDIR, made.contains(path) || hasTracked(path) else { return leave(path, .alreadyThere) }
                    return goThrough(path, depth: depth)
                }
                if through { return goThrough(path, depth: depth, mode: info.st_mode) }
                clone(path, isFolder: true)
            default:
                leave(path, .special)
            }
        }

        /// Each thing in the folder at `path`, placed on its own; the folder made at the destination first when
        /// missing (with the source's mode).
        mutating func goThrough(_ path: String, depth: Int, mode: mode_t? = nil) {
            if let mode {
                guard makeParents(of: path) else { return }
                guard mkdir(destination + "/" + path, mode & 0o7777) == 0 || errno == EEXIST else { return fail(path, errno) }
                made.insert(path)
            }
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: source + "/" + path)) ?? []).sorted()
            for name in names {
                guard report.fatal == nil, !report.stopped else { return }
                place(path + "/" + name, depth: depth + 1)
            }
        }

        /// The folders on the way to `path` at the destination: real folders, made when missing (never through a link).
        mutating func makeParents(of path: String) -> Bool {
            var parent = ""
            for part in path.split(separator: "/").dropLast() {
                parent += (parent.isEmpty ? "" : "/") + part
                var info = stat()
                if lstat(destination + "/" + parent, &info) == 0 {
                    guard info.st_mode & S_IFMT == S_IFDIR else {
                        leave(path, .failed("“\(parent)” isn’t a folder in the new worktree"))
                        return false
                    }
                    continue
                }
                var mode: mode_t = 0o755
                if lstat(source + "/" + parent, &info) == 0 { mode = info.st_mode & 0o7777 }
                guard mkdir(destination + "/" + parent, mode) == 0 || errno == EEXIST else {
                    fail(path, errno)
                    return false
                }
                made.insert(parent)
            }
            return true
        }

        /// One clone call: the file, the link (as it is) or the folder with all it holds. A folder that won't clone
        /// whole (a root-owned file in it, a socket) is gone through, so only what can't be cloned is left out.
        mutating func clone(_ path: String, isFolder: Bool) {
            guard makeParents(of: path) else { return }
            if clonefile(source + "/" + path, destination + "/" + path, UInt32(CLONE_NOFOLLOW)) == 0 {
                report.copied.append(path)
                return
            }
            let error = errno
            switch error {
            case EEXIST:
                leave(path, .alreadyThere)
            case EXDEV, ENOTSUP:
                report.fatal = "this disk can’t clone files, and Next Term never copies them byte by byte"
            case ENOSPC:
                report.fatal = "the disk is full"
            case EROFS:
                report.fatal = "the new worktree is on a read-only disk"
            default:
                guard isFolder else { return fail(path, error) }
                var info = stat()
                guard lstat(source + "/" + path, &info) == 0 else { return fail(path, error) }
                goThrough(path, depth: 1, mode: info.st_mode)
            }
        }

        mutating func fail(_ path: String, _ error: Int32) {
            leave(path, .failed(String(cString: strerror(error))))
        }
    }

    // MARK: after

    /// The hints for what was copied (`hints(differs:…)`), reading the lock files of both checkouts and their HEADs.
    public static func hints(for report: Report, source: String, destination: String, git: String) -> [String] {
        func copied(_ folder: String) -> Bool { report.copied.contains { $0 == folder || $0.hasPrefix(folder + "/") } }
        let vendor = copied("vendor"), nodeModules = copied("node_modules")
        // Laravel's public/storage link, absolute to the source checkout: left out, and made again there.
        let storageLink = report.leftOut.contains(Item("public/storage", .linkOut)) ? ["php artisan storage:link"] : []
        guard vendor || nodeModules else { return storageLink }
        let locks = ["composer.lock", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb"]
        let differs = Set(locks.filter { lock in
            let a = FileManager.default.contents(atPath: source + "/" + lock), b = FileManager.default.contents(atPath: destination + "/" + lock)
            return a != nil && b != nil && a != b
        })
        func head(_ root: String) -> String? {
            GitRunner.run(git, ["-C", root, "rev-parse", "HEAD"], timeout: 10).map { String(decoding: $0, as: UTF8.self) }
        }
        let classmap = copied("vendor/composer") || report.copied.contains("vendor/composer/autoload_classmap.php")
        return hints(differs: differs, vendorCopied: vendor, classmapCopied: classmap, headsDiffer: head(source) != head(destination),
                     nodeModulesCopied: nodeModules) + storageLink
    }
}
