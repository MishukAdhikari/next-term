import Foundation
import os

/// Open in New Worktree's ignored files: what the source checkout's git ignores (node_modules/, vendor/, .env, build
/// output) brought into the new worktree, so it runs without installing again, as the sheet's choice says (`Choice`).
/// Copy: APFS clones (`clone`), no data copied, the two sharing disk space until either side changes, modes, times and
/// links kept as they are. Link: symbolic links to the main checkout's (`link`), shared, so a change on either side is
/// on both, and nothing copied; a link there made again as it is (`relink`), so it leads within the new worktree, and
/// Composer's autoloader cloned (`composerOwn`). Never in a bare repository: no checkout of it is kept from Remove
/// Worktree (`linkSource`). Leave Out: neither (what `.worktreeinclude` lists is copied, as before).
///
/// - What: git's own list of the ignored entries (`ls-files --others --ignored --directory`, a wholly ignored folder
///   as one entry), only those the new worktree's branch ignores too, so nothing it tracks is ever touched; a link
///   only where the new branch ignores a link too (`linkable`).
/// - Never: .git, another worktree (a registered one, or a folder with a `.git` file), anything on another disk, a
///   socket, FIFO or device, a link leading out of the checkout. Never over anything that is there, never a byte
///   copy (a disk that can't clone gets no copy), never a link followed.
/// - Left out by default (`rule`), as they'd point back at the source checkout: logs, Laravel's cached config,
///   `public/hot`, maintenance mode, pid files and sockets, Swift and Xcode builds, Python virtualenvs. A path the
///   checkout's `.worktreeinclude` lists brings one back. Linked, they'd be the source's own, so the same rules hold.
/// - How: each entry's folders are cloned a level down (`node_modules/<package>`, `vendor/<vendor>`), one clone
///   call each: a whole tree in one call holds the disk for its length (clonefile(2) discourages it). An entry is one
///   link, unless a link in it leads out of it (a workspace package, `node_modules/@acme/utils` →
///   `../../packages/utils`): linked whole, that would be the main checkout's own source, never the branch's. At low
///   I/O priority, one at a time, with Stop between calls.
/// - Removing the worktree (`git worktree remove`, FileManager's removeItem) deletes a link, never what it leads to:
///   neither follows a link into the main checkout (WorktreeCopyTests).
/// Plan: claudedocs/2026-10-09-worktree-from-switch-guard-plan.md, D13b.
public enum WorktreeCopy {
    // MARK: the choice

    /// What the new worktree gets of what git ignores: the sheet's choice, remembered per repository.
    public enum Choice: String, CaseIterable, Sendable {
        /// APFS clones: independent, sharing disk space until either side changes.
        case copy
        /// Symbolic links to the main checkout's: shared, nothing copied.
        case link
        /// Committed files only, and copies of what `.worktreeinclude` lists.
        case leaveOut

        public var title: String {
            switch self {
            case .copy: return "Copy"
            case .link: return "Link"
            case .leaveOut: return "Leave Out"
            }
        }

        /// The choice as it was last left for a repository: `saved` (a raw value), else what "Copy ignored files too"
        /// was before there was a choice (`copiedBefore`: ticked is Copy), else Leave Out.
        public static func remembered(_ saved: String?, copiedBefore: Bool?) -> Choice {
            if let saved, let choice = Choice(rawValue: saved) { return choice }
            return copiedBefore == true ? .copy : .leaveOut
        }
    }

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
        /// The paths cloned, each one clone call (a folder with all it holds); linked, each one link.
        public var copied: [String] = []
        /// They are links to the checkout's (`link`), not clones.
        public var links = false
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

    /// Over the choice: "Ignored files: node_modules/, vendor/, .env…", naming up to three of `ignored` (the sidebar's
    /// ignored entries at the checkout's top, folders with "/"), the usual ones first; worktree folders are never
    /// named. Nil when there is nothing to copy or link.
    public static func choiceTitle(ignored: [String]) -> String? {
        let shown = ignored.filter { !containers.contains($0.hasSuffix("/") ? String($0.dropLast()) : $0) && $0 != ".DS_Store" }
        guard !shown.isEmpty else { return nil }
        let first = ["node_modules/", "vendor/", ".env"]
        let ordered = first.filter(shown.contains) + shown.filter { !first.contains($0) }.sorted()
        return "Ignored files: " + ordered.prefix(3).joined(separator: ", ") + (ordered.count > 3 ? "…" : "")
    }

    /// `choiceTitle` from git's own list (`ignoredEntries`): its entries at the checkout's top.
    public static func choiceTitle(listed: [String]) -> String? {
        choiceTitle(ignored: listed.filter { !($0.hasSuffix("/") ? $0.dropLast() : Substring($0)).contains("/") })
    }

    /// What each choice means, in one plain line after its name. `main`: the checkout links lead to (`linkSource`);
    /// `includes`: the checkout has a `.worktreeinclude`.
    public static func line(_ choice: Choice, main: String, includes: Bool) -> String {
        switch choice {
        case .copy: return "independent clones, no extra space until changed"
        case .link: return "shared with \(main), so changing one changes both"
        case .leaveOut: return includes ? "only what .worktreeinclude lists is copied" : "committed files only"
        }
    }

    /// The sheet's footnote with Copy chosen. `source`: the checkout the clones come from (`linkSource`, else the one
    /// the window shows).
    public static func footnote(checkout: String, source: String) -> String {
        "\(checkout) and its changes stay as they are. The new folder also gets clones of what \(source)’s git ignores, "
            + ".env and keys included (so the same database and services), sharing disk space until either side changes. "
            + "Left out: other worktrees, logs, Python virtualenvs, .build and Laravel’s cached config."
    }

    /// The sheet's footnote with Link chosen: what is shared, and that removing the worktree takes only the links.
    public static func linkFootnote(checkout: String, main: String) -> String {
        "\(checkout) and its changes stay as they are. The new folder also gets links to what \(main)’s git ignores, "
            + ".env and keys included: shared, so an install or an edit in either is in both. Removing the worktree deletes "
            + "only the links. Left out: other worktrees, logs, Python virtualenvs, .build and Laravel’s cached config."
    }

    /// Why Copy is off: the new folder isn't on a disk where it can be cloned from the checkout.
    public static let cantClone = "Copying needs the new folder on the same APFS disk as the checkout: clones share space, a copy would fill the disk."

    /// Why Link is off: a bare repository has no main checkout, and any worktree of it can be removed, with what links
    /// into it lead to.
    public static let cantLink = "Linking needs the repository’s main checkout, and a bare repository has none: any of its worktrees "
        + "can be removed, and what the links lead to with it."

    /// The notice's part: "; copied 72 ignored items, 6 left out; run composer install there", "; linked 3 ignored
    /// items" with what to know before installing there (`warnings`).
    public static func notice(_ report: Report, hints: [String], warnings: [String] = []) -> String {
        guard !report.copied.isEmpty || !report.leftOut.isEmpty || report.stopped else { return "" }
        var text = "; \(report.links ? "linked" : "copied") \(report.entries) ignored item\(report.entries == 1 ? "" : "s")"
        if report.stopped { text += " before Stop" }
        let left = report.leftOut.filter(\.why.isExpected).count
        if left > 0 { text += ", \(left) left out" }
        for warning in warnings { text += "; " + warning }
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

    static let nodeLocks = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb"]

    /// Linked, what to know before installing there: a lock file that differs from `main`'s means the branch wants
    /// other packages than the shared vendor/ or node_modules/ holds, and an install there changes `main`'s too.
    public static func sharedWarnings(differs: Set<String>, vendorLinked: Bool, nodeModulesLinked: Bool, main: String) -> [String] {
        var warnings: [String] = []
        if vendorLinked, differs.contains("composer.lock") {
            warnings.append("composer.lock differs, and vendor/ is shared with \(main): an install there changes both")
        }
        if nodeModulesLinked, let lock = nodeLocks.first(where: differs.contains) {
            warnings.append("\(lock) differs, and node_modules/ is shared with \(main): an install there changes both")
        }
        return warnings
    }

    /// Git Commands' entry: what was cloned or linked and what was left out, with why.
    public static func logText(_ report: Report) -> String {
        let made = report.links
            ? "Linked \(report.copied.count) (shared with the checkout: a change on either side is on both; removing the worktree deletes only the links):"
            : "Cloned \(report.copied.count) (sharing disk space with the checkout until either side changes):"
        var lines = [made]
        lines += report.copied.map { "  " + $0 }
        if !report.leftOut.isEmpty {
            lines.append("Left out:")
            lines += report.leftOut.map { "  \($0.path): \($0.why.reason)" }
        }
        if report.stopped { lines.append("Stopped: what was \(report.links ? "linked" : "cloned") before Stop stays.") }
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

    /// Of `entries` (`entries(from:to:git:)`), the folders a link of the same name would be ignored at `destination`
    /// too, without their "/": git takes a link for a file, so `node_modules/` ignores the folder and never a link to it,
    /// while `/node_modules` or `node_modules` ignores both. Asked before any link is there: git won't say past a link.
    /// Nil when git can't say.
    public static func linkable(_ entries: [String], in destination: String, git: String) -> Set<String>? {
        ignoredThere(entries.filter { $0.hasSuffix("/") }.map { String($0.dropLast()) }, in: destination, git: git)
    }

    /// The checkout links lead to: the repository's main checkout, which Remove Worktree never removes, when it has
    /// files. Nil for a bare repository's folder: any worktree of it can be removed, and links into one would lead
    /// nowhere after, so Link is off there (`cantLink`).
    public static func linkSource(main: String) -> String? {
        var info = stat()
        return lstat(main + "/.git", &info) == 0 ? main : nil
    }

    /// Composer's own in vendor/: its autoloader and its bin proxies. PHP follows links for `__DIR__`, so linked they'd
    /// load the checkout's classes (app/, tests/) in the new worktree, and an install there would point the checkout's
    /// autoloader at the new worktree's: cloned, so they are the new worktree's own (`Engine.ownComposer`).
    static let composerOwn = ["vendor/composer", "vendor/autoload.php", "vendor/bin"]

    /// Why Composer's own is left out when linking on a disk that can't clone it (composer install makes it there).
    static func composerLeftOut(_ main: String) -> LeftOut { .rule("Composer’s autoloader: linked, it would load \(main)’s classes") }

    /// What the link at `path` in `destination` holds to reach the same path in `source` (both as the kernel spells
    /// them, `canonicalPath`): relative when the two are on one volume, so moving the folder holding both keeps it
    /// working (`../xCloud/node_modules`, `../../../node_modules` from `.claude/worktrees/x`), absolute otherwise.
    public static func linkTarget(_ path: String, source: String, destination: String, sameVolume: Bool) -> String {
        let target = source + "/" + path
        guard sameVolume else { return target }
        let from = Array((destination + "/" + path).split(separator: "/").dropLast()) // the folders the link is in
        let to = target.split(separator: "/")
        var shared = 0
        while shared < from.count, shared < to.count, from[shared] == to[shared] { shared += 1 }
        let up = Array(repeating: "..", count: from.count - shared)
        return (up + to.dropFirst(shared).map(String.init)).joined(separator: "/")
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
        bring(entries, from: source, to: destination, worktrees: worktrees, includes: includes, linkable: nil, hasTracked: hasTracked,
              stop: stop, progress: progress)
    }

    /// Links `entries` (from `entries(from:to:git:)`) in `destination` to the same paths in `source` (`linkSource`), one
    /// symbolic link each (`linkTarget`) and nothing copied, with `clone`'s rules for what is left out. A folder is one
    /// link where the new branch ignores a link of its name too (`linkable`), nothing in it is left out a level down
    /// (as `clone` goes) and no link in it leads out of it, else a folder of its own, which git ignores with all that is
    /// in it, holding a link for each thing in it; so is one that holds a worktree, and a Composer vendor/, whose own
    /// files are cloned (`composerOwn`). A link in the checkout is made again as it is, as a clone keeps it. A folder there
    /// already is left as it is: a link goes only where git said it is ignored.
    public static func link(_ entries: [String], from source: String, to destination: String, worktrees: [String], includes: Set<String> = [],
                            linkable: Set<String>, stop: Stop = Stop(), progress: (String, Int, Int) -> Void = { _, _, _ in }) -> Report {
        bring(entries, from: source, to: destination, worktrees: worktrees, includes: includes, linkable: linkable, hasTracked: { _ in false },
              stop: stop, progress: progress)
    }

    /// `clone`, or `link` with `linkable`.
    private static func bring(_ entries: [String], from source: String, to destination: String, worktrees: [String], includes: Set<String>,
                              linkable: Set<String>?, hasTracked: @escaping (String) -> Bool, stop: Stop,
                              progress: (String, Int, Int) -> Void) -> Report {
        var info = stat(), there = stat()
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
        let sameVolume = lstat(destination, &there) == 0 && there.st_dev == info.st_dev
        let links = linkable.map { whole in
            Links(source: canonicalSource, destination: canonicalPath(destination), sameVolume: sameVolume, whole: whole,
                  composer: FileManager.default.fileExists(atPath: source + "/vendor/composer"), clones: canClone(from: source, into: destination))
        }
        var engine = Engine(source: source, destination: destination, device: info.st_dev, avoid: avoid, worktreesInside: inside,
                            includes: includes, hasTracked: hasTracked, stop: stop, links: links)
        engine.report.links = links != nil
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

    /// Linking: where the links lead from and to, as the kernel spells them, whether they can be relative, the
    /// folders a link may stand for whole (`linkable`), and what Composer's own (`composerOwn`) needs.
    private struct Links {
        let source: String
        let destination: String
        let sameVolume: Bool
        let whole: Set<String>
        /// The checkout's vendor/ is Composer's: it has vendor/composer.
        let composer: Bool
        /// The new worktree can get clones from the checkout (`canClone`): Composer's own is cloned.
        let clones: Bool
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
        /// Set when linking, nil when cloning.
        let links: Links?
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
            var info = stat()
            guard lstat(source + "/" + path, &info) == 0 else { return } // gone since git listed it
            if let why = leftOut(path, info) { return leave(path, why) }
            guard info.st_mode & S_IFMT == S_IFDIR else { return bringFile(path, isLink: info.st_mode & S_IFMT == S_IFLNK) }
            let name = (path as NSString).lastPathComponent
            let holdsWorktree = worktreesInside.contains { $0 == path || $0.hasPrefix(path + "/") }
            var there = stat()
            if lstat(destination + "/" + path, &there) == 0 {
                // There already: gone through when this copy made it or, cloning, the new branch tracks something in
                // it (a .gitkeep); else something else made it (a hook's install) and it is left as it is. A link
                // never goes in a folder git wasn't asked about.
                let ours = made.contains(path) || (links == nil && hasTracked(path))
                guard there.st_mode & S_IFMT == S_IFDIR, ours else { return leave(path, .alreadyThere) }
                return goThrough(path, depth: depth)
            }
            if let links {
                if ownComposer(path) { return cloneComposer(path, isFolder: true) }
                // One link for the folder, unless the new branch ignores only a folder there, something in it is left
                // out, or a link in it leads out of it: then a folder of its own, all in it ignored with it, so a link
                // for each thing in it is too. So is a Composer vendor/: its packages linked, Composer's own cloned.
                let whole = depth > 0 || links.whole.contains(path)
                let through = !whole || holdsWorktree || WorktreeCopy.containers.contains(name) || (links.composer && path == "vendor")
                if through || leavesOutInside(path) { return goThrough(path, depth: depth, mode: info.st_mode) }
                return link(path)
            }
            // An entry's folders go a level down, each in a call of its own (node_modules/<package>).
            let through = depth == 0 || holdsWorktree || WorktreeCopy.containers.contains(name)
            if through { return goThrough(path, depth: depth, mode: info.st_mode) }
            clone(path, isFolder: true)
        }

        /// Why `path` (as lstat found it, `info`) is left out, if it is: another disk, a link out of the checkout,
        /// another worktree, a socket, FIFO or device, or a built-in rule `.worktreeinclude` doesn't bring back.
        func leftOut(_ path: String, _ info: stat) -> LeftOut? {
            let from = source + "/" + path
            guard info.st_dev == device else { return .otherDisk }
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: from),
                      WorktreeCopy.linkStaysInside(path, target: target) else { return .linkOut }
                return ruled(path, isFolder: false)
            case S_IFREG:
                return ruled(path, isFolder: false)
            case S_IFDIR:
                if avoid.contains(FileID(info)) { return .worktree }
                var git = stat()
                if lstat(from + "/.git", &git) == 0, git.st_mode & S_IFMT == S_IFREG { return .worktree }
                return ruled(path, isFolder: true, isVirtualenv: FileManager.default.fileExists(atPath: from + "/pyvenv.cfg"))
            default:
                return .special
            }
        }

        func ruled(_ path: String, isFolder: Bool, isVirtualenv: Bool = false) -> LeftOut? {
            guard let rule = WorktreeCopy.rule(for: path, isFolder: isFolder, isVirtualenv: isVirtualenv), !included(path) else { return nil }
            return .rule(rule)
        }

        /// Whether a link for the whole folder at `path` would bring what Copy, going a level down, leaves out (Finder's
        /// .DS_Store aside, harmless shared), or holds a link leading out of it, in it or a level further down (a
        /// workspace package: node_modules/@acme/utils → ../../packages/utils): through a link to the folder, that
        /// would lead to the checkout's own files, never the new worktree's. Then it is gone through instead.
        func leavesOutInside(_ path: String) -> Bool {
            let fm = FileManager.default
            let names = (try? fm.contentsOfDirectory(atPath: source + "/" + path)) ?? []
            return names.contains { name in
                var info = stat()
                guard name != ".DS_Store", lstat(source + "/" + path + "/" + name, &info) == 0 else { return false }
                if leftOut(path + "/" + name, info) != nil { return true }
                switch info.st_mode & S_IFMT {
                case S_IFLNK:
                    return leadsOut(of: path, name)
                case S_IFDIR:
                    // A scope's or a vendor's packages: node_modules/@acme/utils, vendor/acme/pkg.
                    let inner = (try? fm.contentsOfDirectory(atPath: source + "/" + path + "/" + name)) ?? []
                    return inner.contains { child in
                        var link = stat()
                        let relative = name + "/" + child
                        return lstat(source + "/" + path + "/" + relative, &link) == 0 && link.st_mode & S_IFMT == S_IFLNK && leadsOut(of: path, relative)
                    }
                default:
                    return false
                }
            }
        }

        /// Whether the link at `relative` in the folder at `path` leads out of that folder.
        func leadsOut(of path: String, _ relative: String) -> Bool {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: source + "/" + path + "/" + relative) else { return false }
            return !WorktreeCopy.linkStaysInside(relative, target: target)
        }

        /// A file or a link: cloned as it is; linking, linked to, a link made again as it is (`relink`), and Composer's
        /// own cloned (`ownComposer`).
        mutating func bringFile(_ path: String, isLink: Bool) {
            if links == nil {
                clone(path, isFolder: false)
            } else if ownComposer(path) {
                cloneComposer(path, isFolder: false)
            } else if isLink {
                relink(path)
            } else {
                link(path)
            }
        }

        /// Linking, whether `path` is Composer's own (`composerOwn`) or in it.
        func ownComposer(_ path: String) -> Bool {
            guard let links, links.composer else { return false }
            return WorktreeCopy.composerOwn.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        /// Composer's own, linking: cloned, so `__DIR__` is in the new worktree; left out on a disk that can't clone it.
        mutating func cloneComposer(_ path: String, isFolder: Bool) {
            guard links?.clones == true else { return leave(path, WorktreeCopy.composerLeftOut((source as NSString).lastPathComponent)) }
            clone(path, isFolder: isFolder)
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

        /// One symbolic link to the same path in the checkout.
        mutating func link(_ path: String) {
            guard let links else { return }
            makeLink(path, to: WorktreeCopy.linkTarget(path, source: links.source, destination: links.destination, sameVolume: links.sameVolume))
        }

        /// A link in the checkout, made again with its own target (`leftOut` found it staying inside), as a clone keeps
        /// it: it leads within the new worktree (node_modules/@acme/utils → ../../packages/utils, the branch's own),
        /// never through a link to it into the checkout's files.
        mutating func relink(_ path: String) {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: source + "/" + path) else { return } // gone since
            makeLink(path, to: target)
        }

        /// A symbolic link at `path` holding `target`: never over anything, never followed.
        mutating func makeLink(_ path: String, to target: String) {
            guard makeParents(of: path) else { return }
            if symlink(target, destination + "/" + path) == 0 {
                report.copied.append(path)
                return
            }
            let error = errno
            switch error {
            case EEXIST:
                leave(path, .alreadyThere)
            case ENOTSUP:
                report.fatal = "the new worktree’s disk can’t hold links"
            case ENOSPC:
                report.fatal = "the disk is full"
            case EROFS:
                report.fatal = "the new worktree is on a read-only disk"
            default:
                fail(path, error)
            }
        }

        mutating func fail(_ path: String, _ error: Int32) {
            leave(path, .failed(String(cString: strerror(error))))
        }
    }

    // MARK: after

    /// The hints for what was copied (`hints(differs:…)`), reading the lock files of both checkouts and their HEADs.
    /// Linked, never an install, which would change the checkout's own (`warnings`): `composer dump-autoload` when the
    /// cloned autoloader's classmap names the checkout's classes, `composer install` when it was left out (a disk that
    /// can't clone), and `php artisan storage:link`.
    public static func hints(for report: Report, source: String, destination: String, git: String) -> [String] {
        let vendor = report.placed("vendor"), nodeModules = report.placed("node_modules")
        // Laravel's public/storage link, absolute to the source checkout: left out, and made again there.
        let storageLink = report.leftOut.contains(Item("public/storage", .linkOut)) ? ["php artisan storage:link"] : []
        guard vendor || nodeModules else { return storageLink }
        func head(_ root: String) -> String? {
            GitRunner.run(git, ["-C", root, "rev-parse", "HEAD"], timeout: 10).map { String(decoding: $0, as: UTF8.self) }
        }
        if report.links {
            // Linking, nothing in vendor/composer is a link (`composerOwn`): placed, it was cloned.
            if report.placed("vendor/composer") { return (head(source) != head(destination) ? ["composer dump-autoload"] : []) + storageLink }
            let autoloader = report.leftOut.contains(Item("vendor/composer", composerLeftOut((source as NSString).lastPathComponent)))
            return (autoloader ? ["composer install"] : []) + storageLink
        }
        let differs = differingLocks(source: source, destination: destination)
        let classmap = report.placed("vendor/composer") || report.copied.contains("vendor/composer/autoload_classmap.php")
        return hints(differs: differs, vendorCopied: vendor, classmapCopied: classmap, headsDiffer: head(source) != head(destination),
                     nodeModulesCopied: nodeModules) + storageLink
    }

    /// Linked, what to know before installing there (`sharedWarnings`), reading the lock files of both checkouts.
    public static func warnings(for report: Report, source: String, destination: String) -> [String] {
        let vendor = report.placed("vendor"), nodeModules = report.placed("node_modules")
        guard report.links, vendor || nodeModules else { return [] }
        return sharedWarnings(differs: differingLocks(source: source, destination: destination), vendorLinked: vendor,
                              nodeModulesLinked: nodeModules, main: (source as NSString).lastPathComponent)
    }

    /// The lock files both checkouts have, with different contents.
    private static func differingLocks(source: String, destination: String) -> Set<String> {
        Set((["composer.lock"] + nodeLocks).filter { lock in
            let a = FileManager.default.contents(atPath: source + "/" + lock), b = FileManager.default.contents(atPath: destination + "/" + lock)
            return a != nil && b != nil && a != b
        })
    }
}

extension WorktreeCopy.Report {
    /// Whether `folder`, or something in it, was cloned or linked.
    func placed(_ folder: String) -> Bool { copied.contains { $0 == folder || $0.hasPrefix(folder + "/") } }
}
