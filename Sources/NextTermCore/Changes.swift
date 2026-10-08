import Foundation

// The Git Diff tab's model: the files "All changes", "Uncommitted" or one commit changes, with their lines
// added and removed; the branch "All changes" counts from and where this branch parted from it; and the
// diffs the All files page shows. Read-only, like everything GitRunner runs.

/// What the Git Diff tab shows.
public enum ChangeScope: Equatable, Hashable, Sendable {
    /// Everything this branch changed since it parted from its base, committed or not, together.
    case all
    /// The work tree and the index against HEAD.
    case uncommitted
    /// One commit's changes, against its first parent.
    case commit(String)
}

/// The repository as the Git Diff tab needs it: what is checked out, the base and where the two parted.
public struct ChangeContext: Equatable, Sendable {
    /// "refs/heads/feat/x"; nil when HEAD is detached.
    public var branch: String?
    /// HEAD's full id; nil before the first commit.
    public var head: String?
    /// The branch "All changes" counts from ("refs/remotes/origin/main"); nil when there is none.
    public var base: String?
    /// The base when none is chosen: the upstream's default branch, else main or master.
    public var defaultBase: String?
    /// The newest commit HEAD and the base share; nil without a base, on it, or when they share none.
    public var mergeBase: String?
    /// What is checked out is the base itself (main, on main or origin/main).
    public var isOnBase = false
    /// Branches to count from instead, local then remote, by full name.
    public var bases: [String] = []

    public init(branch: String? = nil, head: String? = nil, base: String? = nil, mergeBase: String? = nil, isOnBase: Bool = false) {
        self.branch = branch
        self.head = head
        self.base = base
        self.mergeBase = mergeBase
        self.isOnBase = isOnBase
    }

    /// What `scope` reads: All changes is Uncommitted on the base itself, and with nothing to count from.
    public func effective(_ scope: ChangeScope) -> ChangeScope {
        guard scope == .all else { return scope }
        return isOnBase || mergeBase == nil ? .uncommitted : .all
    }

    /// "main" for "refs/heads/main", "origin/main" for "refs/remotes/origin/main".
    public var baseName: String? { base.map(BranchCompare.displayName) }
    public var branchName: String? { branch.map(BranchCompare.displayName) }
}

/// The files a scope changes.
public struct ChangeSet: Equatable, Sendable {
    public var files: [ChangedFile] = []
    /// Which of the files git doesn't track yet: listed as added, their lines from the file on disk.
    public var untracked: Set<String> = []
    /// More files changed than are listed.
    public var truncated = false
    /// A commit's first parent (nil for the first commit).
    public var parent: String?

    public init(files: [ChangedFile] = [], untracked: Set<String> = [], truncated: Bool = false, parent: String? = nil) {
        self.files = files
        self.untracked = untracked
        self.truncated = truncated
        self.parent = parent
    }

    public var totals: LineStats {
        files.reduce(LineStats()) { LineStats(added: $0.added + ($1.added ?? 0), removed: $0.removed + ($1.removed ?? 0), files: $0.files + 1) }
    }

    public func file(at path: String) -> ChangedFile? { files.first { $0.path == path } }
}

/// The branch "All changes" counts from.
public enum ChangeBase {
    /// `chosen` while it exists; else the default branch of the upstream's remote (its remote HEAD,
    /// "refs/remotes/origin/HEAD" naming "refs/remotes/origin/main"), or of origin without an upstream;
    /// else main or master: the upstream remote's, then the local ones, then origin's.
    /// `refs`: every branch by full name; `remoteHeads`: each remote's default branch, by remote name.
    public static func pick(chosen: String?, upstream: String?, refs: Set<String>, remoteHeads: [String: String]) -> String? {
        if let chosen, refs.contains(chosen) { return chosen }
        // The remote the upstream is on: the longest remote name that starts it ("a/b" before "a").
        let remote = remoteHeads.keys.sorted { $0.count > $1.count }.first { name in upstream?.hasPrefix("refs/remotes/\(name)/") == true }
            ?? upstreamRemote(upstream)
        if let remote, let head = remoteHeads[remote], refs.contains(head) { return head }
        if remote == nil, let head = remoteHeads["origin"], refs.contains(head) { return head }
        var names: [String] = []
        if let remote { names += ["refs/remotes/\(remote)/main", "refs/remotes/\(remote)/master"] }
        names += ["refs/heads/main", "refs/heads/master", "refs/remotes/origin/main", "refs/remotes/origin/master"]
        return names.first { refs.contains($0) }
    }

    /// "origin" for "refs/remotes/origin/feat/x": the part after refs/remotes/ up to the next slash.
    static func upstreamRemote(_ upstream: String?) -> String? {
        guard let upstream, upstream.hasPrefix("refs/remotes/") else { return nil }
        let rest = upstream.dropFirst("refs/remotes/".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        return String(rest[..<slash])
    }

    /// Whether `branch` ("refs/heads/main") is `base` itself, or what a remote calls the same branch
    /// ("refs/remotes/origin/main").
    public static func isOnBase(branch: String?, base: String?, remotes: [String]) -> Bool {
        guard let branch, let base, branch.hasPrefix("refs/heads/") else { return false }
        if branch == base { return true }
        let name = branch.dropFirst("refs/heads/".count)
        return remotes.contains { base == "refs/remotes/\($0)/\(name)" }
    }

    /// `for-each-ref --format=%(refname)%00%(symref)%00%(upstream)`: the branches (a remote's HEAD
    /// left out), each remote's default branch, and the upstream of each local branch.
    public static func parseRefs(_ data: Data) -> (refs: [String], remoteHeads: [String: String], upstreams: [String: String]) {
        var refs: [String] = []
        var heads: [String: String] = [:], upstreams: [String: String] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            let f = line.split(separator: 0, maxSplits: 2, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            guard f.count == 3, f[0].hasPrefix("refs/") else { continue }
            if !f[1].isEmpty {
                // A symbolic ref: a remote's HEAD names its default branch.
                if f[0].hasPrefix("refs/remotes/"), f[0].hasSuffix("/HEAD") {
                    heads[String(f[0].dropFirst("refs/remotes/".count).dropLast("/HEAD".count))] = f[1]
                }
                continue
            }
            refs.append(f[0])
            if !f[2].isEmpty { upstreams[f[0]] = f[2] }
        }
        return (refs, heads, upstreams)
    }
}

public enum Changes {
    /// At most this many files are listed.
    public static let fileLimit = 3000
    /// A file with more lines changed than this waits for "Show anyway" on the All files page.
    public static let largeLines = 3000

    /// Paths are file names, never patterns; reading a diff never rewrites the index.
    static func base(_ root: String) -> [String] {
        ["-C", root, "--no-optional-locks", "--literal-pathspecs", "-c", "core.quotepath=off", "-c", "diff.autoRefreshIndex=false"]
    }

    private static func text(_ data: Data?) -> String {
        data.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }

    // MARK: the context

    /// What is checked out, the base (`chosen` while it exists) and where HEAD parted from it; nil when
    /// git fails (not a repository).
    public static func context(in root: String, git: String, chosen: String?) -> ChangeContext? {
        let base = base(root)
        guard let listing = GitRunner.run(git, base + ["for-each-ref", "--format=%(refname)%00%(symref)%00%(upstream)", "refs/heads", "refs/remotes"],
                                          timeout: 15) else { return nil }
        var context = ChangeContext()
        context.head = CommitLog.resolve("HEAD", in: root, git: git)
        let branch = text(GitRunner.run(git, base + ["symbolic-ref", "--quiet", "HEAD"], timeout: 10, acceptedStatus: [0, 1]))
        context.branch = branch.isEmpty ? nil : branch
        let (refs, heads, upstreams) = ChangeBase.parseRefs(listing)
        let remotes = text(GitRunner.run(git, base + ["remote"], timeout: 10)).split(separator: "\n").map(String.init)
        let upstream = context.branch.flatMap { upstreams[$0] }
        context.defaultBase = ChangeBase.pick(chosen: nil, upstream: upstream, refs: Set(refs), remoteHeads: heads)
        context.base = ChangeBase.pick(chosen: chosen, upstream: upstream, refs: Set(refs), remoteHeads: heads)
        context.isOnBase = ChangeBase.isOnBase(branch: context.branch, base: context.base, remotes: remotes)
        let local = refs.filter { $0.hasPrefix("refs/heads/") }, remote = refs.filter { $0.hasPrefix("refs/remotes/") }
        context.bases = Array((local + remote).prefix(400))
        if let target = context.base, context.head != nil, !context.isOnBase {
            // Exit 1: no commit in common. With two (branches that merged each other), git picks one.
            let found = text(GitRunner.run(git, base + ["merge-base", "--end-of-options", "HEAD", target], timeout: 15, acceptedStatus: [0, 1]))
            context.mergeBase = found.count >= 40 ? found : nil
        }
        return context
    }

    // MARK: the files

    /// The files `scope` changes, with their counts; nil when git fails. All changes and Uncommitted list
    /// files git doesn't track yet too, counted from the disk.
    public static func files(_ scope: ChangeScope, context: ChangeContext, in root: String, git: String) -> ChangeSet? {
        switch context.effective(scope) {
        case let .commit(sha):
            guard let details = CommitLog.details(of: sha, in: root, git: git, fileLimit: fileLimit) else { return nil }
            return ChangeSet(files: details.files, truncated: details.truncated, parent: details.commit.parents.first)
        case .all:
            guard let mergeBase = context.mergeBase else { return nil }
            return workingTree(against: mergeBase, in: root, git: git)
        case .uncommitted:
            guard let tree = context.head ?? emptyTree(in: root, git: git) else { return nil }
            return workingTree(against: tree, in: root, git: git)
        }
    }

    static func emptyTree(in root: String, git: String) -> String? {
        let id = text(GitRunner.run(git, ["-C", root, "hash-object", "-t", "tree", "/dev/null"], timeout: 5))
        return id.isEmpty ? nil : id
    }

    /// The files on disk that differ from `tree` (staged or not), and the untracked ones.
    static func workingTree(against tree: String, in root: String, git: String) -> ChangeSet? {
        let args = ["diff-index", "-z", "-M", "--raw", "--numstat", "--no-ext-diff", "--no-textconv", "--end-of-options", tree, "--"]
        guard let data = GitRunner.run(git, base(root) + args, timeout: 30) else { return nil }
        var set = ChangeSet(files: parseRawNumstat(data))
        let untracked = untrackedFiles(in: root, git: git)
        let listed = Set(set.files.map(\.path))
        let new = untracked.filter { !listed.contains($0) }
        let counts = GitRunner.countLines(of: Array(new.prefix(fileLimit)), in: root)
        set.files += new.map { ChangedFile(path: $0, status: .added, added: counts[$0], removed: counts[$0] == nil ? nil : 0) }
        set.truncated = set.files.count > fileLimit
        set.files = Array(set.files.prefix(fileLimit))
        // The listed ones only: 30,000 files of an unignored node_modules are not looked up one by one.
        set.untracked = Set(set.files.map(\.path)).intersection(new)
        return set
    }

    /// Untracked files, one by one (not folders as a whole), leaving out what .gitignore does.
    static func untrackedFiles(in root: String, git: String) -> [String] {
        guard let data = GitRunner.run(git, base(root) + ["ls-files", "-z", "--others", "--exclude-standard"], timeout: 30) else { return [] }
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// `diff-index --raw --numstat -z`: the raw records, then the counts (as CommitLog.parseChanges reads
    /// them). A file git lists only because it hasn't looked at it since it was touched is left out:
    /// modified, the same mode, no id for the file on disk, and no line changed (no count at all, or 0 and 0).
    public static func parseRawNumstat(_ data: Data) -> [ChangedFile] {
        let records = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var files: [ChangedFile] = []
        var index: [String: Int] = [:]
        var unsure = Set<String>()
        var i = 0
        while i < records.count {
            let record = records[i]
            i += 1
            if record.hasPrefix(":") {
                // ":100644 100644 <old id> <new id> M"
                let fields = record.split(separator: " ")
                let status = fields.last?.first.map { ChangedFile.Status(rawValue: String($0)) ?? .unknown } ?? .unknown
                guard i < records.count else { break }
                let file: ChangedFile
                if status == .renamed || status == .copied, i + 1 < records.count {
                    file = ChangedFile(path: records[i + 1], oldPath: records[i], status: status)
                    i += 2
                } else {
                    file = ChangedFile(path: records[i], status: status)
                    i += 1
                }
                if fields.count == 5, status == .modified, fields[0].dropFirst() == fields[1], fields[3].allSatisfy({ $0 == "0" }) {
                    unsure.insert(file.path)
                }
                index[file.path] = files.count
                files.append(file)
                continue
            }
            let counts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard counts.count == 3 else { continue }
            var path = String(counts[2])
            if path.isEmpty, i + 1 < records.count { // a rename: the new path is the second of the next two
                path = records[i + 1]
                i += 2
            }
            if let at = index[path] {
                files[at].added = Int(counts[0])
                files[at].removed = Int(counts[1])
                files[at].isBinary = counts[0] == "-"
            }
        }
        return files.filter { !(unsure.contains($0.path) && ($0.added ?? 0) == 0 && ($0.removed ?? 0) == 0 && !$0.isBinary) }
    }

    // MARK: the diffs

    /// Whether the All files page waits for "Show anyway" before showing a file's diff.
    public static func isLarge(_ file: ChangedFile) -> Bool { (file.added ?? 0) + (file.removed ?? 0) > largeLines }

    /// Every listed file's diff in `scope`, three lines of context, by path: the tracked files' from one git
    /// run (in parts when some are left out), the untracked ones' from the disk. Large files are left out,
    /// to read one by one with `diff(of:…)`.
    public static func diffs(_ scope: ChangeScope, context: ChangeContext, set: ChangeSet, in root: String, git: String) -> [String: FileDiff]? {
        let scope = context.effective(scope)
        var result: [String: FileDiff] = [:]
        let tracked = set.files.filter { !set.untracked.contains($0.path) }
        let wanted = tracked.filter { !isLarge($0) }
        if !wanted.isEmpty {
            // The whole change at once when nothing is left out; otherwise by name, a rename with both its names.
            let whole = wanted.count == tracked.count && !set.truncated
            let names: [String] = whole ? [] : wanted.flatMap { [$0.oldPath, $0.path].compactMap { $0 } }
            let parts: [[String]] = whole ? [[]] : stride(from: 0, to: names.count, by: 400).map { Array(names[$0..<min($0 + 400, names.count)]) }
            for part in parts {
                guard let files = trackedDiffs(scope, context: context, set: set, paths: part, in: root, git: git) else { return nil }
                for file in files { result[file.path] = file }
            }
        }
        for file in set.files where set.untracked.contains(file.path) && !isLarge(file) {
            if let diff = untrackedDiff(file.path, in: root) { result[file.path] = diff }
        }
        return result
    }

    private static func trackedDiffs(_ scope: ChangeScope, context: ChangeContext, set: ChangeSet, paths: [String], in root: String,
                                     git: String) -> [FileDiff]? {
        switch scope {
        case .uncommitted:
            return GitRunner.diffs(in: root, git: git, base: .head, paths: paths)
        case .all:
            guard let mergeBase = context.mergeBase else { return nil }
            return GitRunner.diffs(in: root, git: git, base: .ref(mergeBase), paths: paths)
        case let .commit(sha):
            let options = ["diff-tree", "-r", "--no-commit-id", "-p", "-M", "--histogram", "--full-index", "-U3", "--no-color", "--no-ext-diff",
                           "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/"]
            let against = set.parent.map { ["--end-of-options", $0, sha] } ?? ["--root", "--end-of-options", sha]
            guard let data = GitRunner.run(git, base(root) + options + against + ["--"] + paths, timeout: 30) else { return nil }
            return UnifiedDiff.parse(GitRunner.diffText(data))
        }
    }

    /// One file's diff in `scope`, with `lines` of context (`UnifiedRows.wholeFile` for all of it); nil when
    /// git fails, or for an untracked file that isn't text.
    public static func diff(of file: ChangedFile, scope: ChangeScope, context: ChangeContext, set: ChangeSet, in root: String, git: String,
                            lines: Int = UnifiedRows.context) -> FileDiff? {
        if set.untracked.contains(file.path) { return untrackedDiff(file.path, in: root, limit: nil) }
        switch context.effective(scope) {
        case .uncommitted:
            return GitRunner.diff(of: file.path, in: root, git: git, base: .head, context: lines)
        case .all:
            guard let mergeBase = context.mergeBase else { return nil }
            return GitRunner.diff(of: file.path, in: root, git: git, base: .ref(mergeBase), context: lines, oldPath: file.oldPath)
        case let .commit(sha):
            return CommitLog.diff(of: file.path, oldPath: file.oldPath, commit: sha, parent: set.parent, in: root, git: git, context: lines)
        }
    }

    /// An untracked file as a diff that adds every line, up to `limit` bytes (nil: no limit); nil for a file
    /// that is gone, too big or not a regular file.
    static func untrackedDiff(_ path: String, in root: String, limit: Int? = 2_000_000) -> FileDiff? {
        let url = URL(fileURLWithPath: root).appendingPathComponent(path)
        guard isRegularFile(url.path) else { return nil }
        if let limit, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > limit { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UnifiedRows.addedFile(path: path, data: data)
    }
}
