import Foundation

// Compare with Current and Show Diff with Working Tree, from the branch popup: the commits only on a
// branch and only on what is checked out, the files the branch changed since the two parted, and the
// files on disk that differ from a branch. Read-only, like everything GitRunner runs.
// Design: claudedocs/research_next-term-git-branches (sections 8.6 to 8.8).

/// A commit that only one side of a comparison has.
public struct ComparedCommit: Equatable, Sendable {
    public enum Side: Equatable, Sendable {
        /// Only on the branch compared (git's right side of `HEAD...branch`).
        case branch
        /// Only on what is checked out, HEAD (the left side).
        case current
    }
    public let side: Side
    public let sha: String
    public let shortSHA: String
    public let authorName: String
    public let authorDate: Date
    public let subject: String
    /// The other side has a commit with the same change, by git's patch id: a cherry-pick.
    public let isEquivalent: Bool

    public init(side: Side, sha: String, shortSHA: String, authorName: String, authorDate: Date, subject: String, isEquivalent: Bool = false) {
        self.side = side
        self.sha = sha
        self.shortSHA = shortSHA
        self.authorName = authorName
        self.authorDate = authorDate
        self.subject = subject
        self.isEquivalent = isEquivalent
    }
}

/// A branch compared with what is checked out.
public struct BranchComparison: Equatable, Sendable {
    /// "refs/heads/feat/x", or "refs/remotes/origin/x".
    public let branch: String
    /// The branch checked out; nil when HEAD is detached.
    public var current: String?
    /// Newest first, at most `BranchCompare.commitLimit` each.
    public var branchOnly: [ComparedCommit] = []
    public var currentOnly: [ComparedCommit] = []
    /// How many there are in all: more than are listed when a side reaches the limit.
    public var branchCount = 0
    public var currentCount = 0
    /// The newest commit both have; nil when they have none in common.
    public var mergeBase: String?
    /// What the branch changed since the merge base; empty without one.
    public var files: [ChangedFile] = []

    public init(branch: String) { self.branch = branch }

    /// Both at the same commit: nothing on either side.
    public var isSameCommit: Bool { branchCount == 0 && currentCount == 0 }
}

public enum BranchCompare {
    public static let commitLimit = 500
    /// Six fields a commit, separated by NUL, a commit a line (a subject is one line).
    static let format = "%m%x00%H%x00%h%x00%an%x00%at%x00%s"

    /// "feat/x" for "refs/heads/feat/x", "origin/x" for "refs/remotes/origin/x".
    public static func displayName(_ ref: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where ref.hasPrefix(prefix) { return String(ref.dropFirst(prefix.count)) }
        return ref
    }

    // MARK: commands

    /// Paths are file names, never patterns; signatures are not checked while listing.
    static func base(_ root: String) -> [String] {
        ["-C", root, "--no-optional-locks", "--literal-pathspecs", "-c", "core.quotepath=off", "-c", "log.showSignature=false"]
    }

    /// The commits only on one side of `HEAD...<branch>`, newest first: `<` or `>` for its side, `=` for
    /// one whose change the other side has too. One side at a time, so a busy side can't crowd the other
    /// out of the limit, and so a `=` commit's side is known (its mark doesn't say).
    public static func logArguments(branch: String, side: ComparedCommit.Side, limit: Int = commitLimit) -> [String] {
        let only = side == .current ? "--left-only" : "--right-only"
        let options = ["log", "--left-right", only, "--cherry-mark", "--max-count=\(limit)", "--no-color", "--encoding=UTF-8"]
        return options + ["--format=" + format, "--end-of-options", "HEAD..." + branch, "--"]
    }

    /// How many commits are only on each side, current first: `rev-list --left-right --count`.
    public static func countArguments(branch: String) -> [String] {
        ["rev-list", "--left-right", "--count", "--end-of-options", "HEAD..." + branch, "--"]
    }

    /// The files `branch` changed since it parted from HEAD: against their merge base.
    public static func filesArguments(branch: String) -> [String] {
        ["diff-tree", "-r", "-z", "--name-status", "-M", "--merge-base", "--end-of-options", "HEAD", branch, "--"]
    }

    /// One file's change on `branch` since it parted from HEAD. A renamed file is compared with where it
    /// came from, so both paths are given.
    public static func fileDiffArguments(path: String, oldPath: String? = nil, branch: String, context: Int = 3) -> [String] {
        var args = ["diff-tree", "-r", "-p", "--histogram", "-M", "--merge-base", "--no-color", "--no-ext-diff", "--no-textconv", "--full-index"]
        args += ["-U\(context)", "--src-prefix=a/", "--dst-prefix=b/", "--end-of-options", "HEAD", branch, "--"]
        if let oldPath { args.append(oldPath) }
        args.append(path)
        return args
    }

    /// The files on disk (tracked ones) that differ from `branch`: the branch's tree against the working
    /// tree. Untracked files are not listed.
    public static func workingTreeArguments(branch: String) -> [String] {
        ["diff-index", "-z", "--name-status", "-M", "--end-of-options", branch, "--"]
    }

    // MARK: parsing

    /// `log --left-right --cherry-mark --format=<format>`: a commit a line. Lines without a side mark, a
    /// full id and all six fields are left out. `side` is where they all are (the log lists one side).
    public static func parseLog(_ data: Data, side: ComparedCommit.Side) -> [ComparedCommit] {
        // By byte, not by Character: a subject ending in "\r" would join "\r\n" into one Character.
        data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            let f = line.split(separator: 0, maxSplits: 5, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            guard f.count == 6, ["<", ">", "="].contains(f[0]), f[1].count >= 40 else { return nil }
            return ComparedCommit(side: side, sha: f[1], shortSHA: f[2], authorName: f[3], authorDate: Date(timeIntervalSince1970: Double(f[4]) ?? 0),
                                  subject: f[5], isEquivalent: f[0] == "=")
        }
    }

    /// `rev-list --left-right --count`: "current TAB branch".
    public static func parseCounts(_ data: Data) -> (current: Int, branch: Int)? {
        let parts = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
        guard parts.count == 2, let current = Int(parts[0]), let branch = Int(parts[1]) else { return nil }
        return (current, branch)
    }

    /// `--name-status -z`: "M NUL path NUL", and for a rename or copy "R100 NUL old NUL new NUL".
    public static func parseNameStatus(_ data: Data) -> [ChangedFile] {
        let records = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var files: [ChangedFile] = []
        var i = 0
        while i < records.count {
            let code = records[i]
            i += 1
            guard let letter = code.first, i < records.count else { continue }
            let status = ChangedFile.Status(rawValue: String(letter)) ?? .unknown
            if status == .renamed || status == .copied {
                guard i + 1 < records.count else { break }
                files.append(ChangedFile(path: records[i + 1], oldPath: records[i], status: status))
                i += 2
            } else {
                files.append(ChangedFile(path: records[i], status: status))
                i += 1
            }
        }
        return files
    }

    // MARK: reading

    /// `branch` compared with HEAD: the commits only on each side, then the files the branch changed.
    /// Nil when git fails (no commit checked out yet, a branch that is gone).
    public static func compare(_ branch: String, in root: String, git: String, limit: Int = commitLimit,
                               timeout: TimeInterval = 30) -> BranchComparison? {
        let base = base(root)
        guard let mine = GitRunner.run(git, base + logArguments(branch: branch, side: .current, limit: limit), timeout: timeout),
              let theirs = GitRunner.run(git, base + logArguments(branch: branch, side: .branch, limit: limit), timeout: timeout) else { return nil }
        var result = BranchComparison(branch: branch)
        result.currentOnly = parseLog(mine, side: .current)
        result.branchOnly = parseLog(theirs, side: .branch)
        result.currentCount = result.currentOnly.count
        result.branchCount = result.branchOnly.count
        // At the limit, there may be more: count them all (cheap, without comparing changes).
        if result.currentCount >= limit || result.branchCount >= limit,
           let counts = GitRunner.run(git, base + countArguments(branch: branch), timeout: timeout).flatMap(parseCounts) {
            result.currentCount = counts.current
            result.branchCount = counts.branch
        }
        result.current = current(in: root, git: git)
        // merge-base exits 1 when there is none: unrelated histories have no files to compare.
        let mergeBase = GitRunner.run(git, base + ["merge-base", "--end-of-options", "HEAD", branch], timeout: timeout, acceptedStatus: [0, 1])
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        guard mergeBase.count >= 40 else { return result }
        result.mergeBase = mergeBase
        guard let files = GitRunner.run(git, base + filesArguments(branch: branch), timeout: timeout) else { return nil }
        result.files = parseNameStatus(files)
        return result
    }

    /// The branch checked out; nil when HEAD is detached.
    public static func current(in root: String, git: String) -> String? {
        let name = GitRunner.run(git, base(root) + ["symbolic-ref", "--quiet", "--short", "HEAD"], timeout: 10, acceptedStatus: [0, 1])
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return name.isEmpty ? nil : name
    }

    /// The tracked files on disk that differ from `branch`; nil when git fails.
    public static func workingTreeFiles(against branch: String, in root: String, git: String, timeout: TimeInterval = 30) -> [ChangedFile]? {
        GitRunner.run(git, base(root) + workingTreeArguments(branch: branch), timeout: timeout).map(parseNameStatus)
    }

    /// One file's change on `branch` since it parted from HEAD; nil when git fails.
    public static func diff(of path: String, oldPath: String? = nil, branch: String, in root: String, git: String, context: Int = 3) -> FileDiff? {
        let args = base(root) + fileDiffArguments(path: path, oldPath: oldPath, branch: branch, context: context)
        guard let data = GitRunner.run(git, args, timeout: 15) else { return nil }
        return CommitLog.file(at: path, in: UnifiedDiff.parse(String(decoding: data, as: UTF8.self)))
    }
}
