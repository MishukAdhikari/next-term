import Foundation

// The Git Log's model: commits as `git log` lists them (newest first, parents after their children),
// a page at a time, filtered by branch, author, date, paths, message or hash; one commit's details with
// its changed files; one file's diff in a commit. Read-only, like everything GitRunner runs.

/// A branch, tag or HEAD pointing at a commit, from `%D` with `--decorate=full`.
public struct CommitRef: Equatable, Hashable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable { case head, branch, remote, tag, other }
    public let kind: Kind
    /// As shown: "main", "origin/main", "v1.0", "HEAD".
    public let name: String
    /// "refs/heads/main"; "HEAD" for HEAD itself.
    public let fullName: String
    /// The branch checked out ("HEAD -> main").
    public let isCurrent: Bool

    public init(kind: Kind, name: String, fullName: String, isCurrent: Bool = false) {
        self.kind = kind
        self.name = name
        self.fullName = fullName
        self.isCurrent = isCurrent
    }

    /// "HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1.0". A detached HEAD is
    /// "HEAD" on its own; with a branch checked out, HEAD is not listed apart from it.
    public static func parse(decoration: String) -> [CommitRef] {
        var refs: [CommitRef] = []
        for part in decoration.components(separatedBy: ", ") where !part.isEmpty {
            if part.hasPrefix("HEAD -> ") {
                refs.append(ref(String(part.dropFirst("HEAD -> ".count)), isCurrent: true))
            } else if part.hasPrefix("tag: ") {
                refs.append(ref(String(part.dropFirst("tag: ".count)), isCurrent: false))
            } else {
                refs.append(ref(part, isCurrent: false))
            }
        }
        return refs
    }

    private static func ref(_ full: String, isCurrent: Bool) -> CommitRef {
        for (prefix, kind) in [("refs/heads/", Kind.branch), ("refs/remotes/", .remote), ("refs/tags/", .tag)] where full.hasPrefix(prefix) {
            return CommitRef(kind: kind, name: String(full.dropFirst(prefix.count)), fullName: full, isCurrent: isCurrent)
        }
        if full == "HEAD" { return CommitRef(kind: .head, name: "HEAD", fullName: "HEAD") }
        return CommitRef(kind: .other, name: full.hasPrefix("refs/") ? String(full.dropFirst(5)) : full, fullName: full, isCurrent: isCurrent)
    }
}

/// One commit as the log lists it.
public struct Commit: Equatable, Sendable {
    public let sha: String
    /// First parent first. In a log limited to paths, the nearest listed ancestors.
    public let parents: [String]
    public let authorName: String
    public let authorEmail: String
    public let authorDate: Date
    public let committerName: String
    public let committerEmail: String
    public let committerDate: Date
    public let refs: [CommitRef]
    public let subject: String

    public init(sha: String, parents: [String], authorName: String = "", authorEmail: String = "", authorDate: Date = Date(timeIntervalSince1970: 0),
                committerName: String = "", committerEmail: String = "", committerDate: Date = Date(timeIntervalSince1970: 0),
                refs: [CommitRef] = [], subject: String = "") {
        self.sha = sha
        self.parents = parents
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorDate = authorDate
        self.committerName = committerName
        self.committerEmail = committerEmail
        self.committerDate = committerDate
        self.refs = refs
        self.subject = subject
    }

    public var shortSHA: String { String(sha.prefix(7)) }
    public var isMerge: Bool { parents.count > 1 }
}

/// What the log lists.
public struct CommitQuery: Equatable, Sendable {
    public enum Scope: Equatable, Sendable {
        /// Every local and remote branch, every tag, and HEAD.
        case all
        /// One branch, tag or revision ("refs/heads/main", "HEAD", a commit).
        case ref(String)
    }

    public var scope: Scope = .all
    /// In the message, ignoring case: a fixed string, or an extended regular expression with `regex`.
    /// A hash prefix that names a commit lists that commit alone.
    public var text = ""
    public var regex = false
    /// In "Name <email>", ignoring case, always a fixed string.
    public var author = ""
    /// Dates as git reads them: "2025-01-31", "2 weeks ago".
    public var since: String?
    public var until: String?
    /// From the work tree's root.
    public var paths: [String] = []

    public init(scope: Scope = .all, text: String = "", regex: Bool = false, author: String = "", since: String? = nil, until: String? = nil,
                paths: [String] = []) {
        self.scope = scope
        self.text = text
        self.regex = regex
        self.author = author
        self.since = since
        self.until = until
        self.paths = paths
    }

    /// Whether lines can join each commit to its parents. Filtered by message or author, a commit's
    /// parents are mostly not listed, so the graph shows the commits alone.
    public var isConnected: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty && author.trimmingCharacters(in: .whitespaces).isEmpty }

    public var isFiltered: Bool { !isConnected || since != nil || until != nil || !paths.isEmpty }

    /// The text, when it could be the start of a commit id (6 to 40 hex digits).
    public var hashPrefix: String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard (6...40).contains(trimmed.count), trimmed.allSatisfy({ $0.isHexDigit }) else { return nil }
        return trimmed
    }

    /// The `git log` options and revisions after `log`, for one page.
    func arguments(skip: Int, limit: Int, includeHead: Bool) -> [String] {
        var args = ["--topo-order", "--decorate=full", "--no-color", "--encoding=UTF-8", "-z", "--format=" + CommitLog.format,
                    "--skip=\(skip)", "--max-count=\(limit)"]
        let text = self.text.trimmingCharacters(in: .whitespaces), author = self.author.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty || !author.isEmpty {
            args.append("--regexp-ignore-case")
            args.append(regex && !text.isEmpty ? "--extended-regexp" : "--fixed-strings")
        }
        if !text.isEmpty { args.append("--grep=" + text) }
        // --fixed-strings covers --author as well; with a regular expression, the name is escaped instead.
        if !author.isEmpty { args.append("--author=" + (regex && !text.isEmpty ? NSRegularExpression.escapedPattern(for: author) : author)) }
        if let since, !since.isEmpty { args.append("--since=" + since) }
        if let until, !until.isEmpty { args.append("--until=" + until) }
        // Limited to paths, parents are rewritten to the nearest listed ancestors, so lines still join.
        if !paths.isEmpty { args.append("--parents") }
        switch scope {
        case .all:
            args += ["--branches", "--remotes", "--tags"]
            if includeHead { args += ["--end-of-options", "HEAD"] }
        case let .ref(name):
            args += ["--end-of-options", name]
        }
        return args + ["--"] + paths
    }
}

/// A file a commit changed, with its lines added and removed (nil for a binary file).
public struct ChangedFile: Equatable, Sendable {
    public enum Status: String, Sendable {
        case added = "A", modified = "M", deleted = "D", renamed = "R", copied = "C", typeChanged = "T", unmerged = "U", unknown = "X"
    }
    public let path: String
    /// Where a renamed or copied file came from.
    public let oldPath: String?
    public let status: Status
    public var added: Int?
    public var removed: Int?
    /// Git counts no lines in it.
    public var isBinary = false

    public init(path: String, oldPath: String? = nil, status: Status, added: Int? = nil, removed: Int? = nil, isBinary: Bool = false) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.added = added
        self.removed = removed
        self.isBinary = isBinary
    }
}

/// One commit in full: its whole message and the files it changed (against its first parent).
public struct CommitDetails: Equatable, Sendable {
    public let commit: Commit
    public let message: String
    public var files: [ChangedFile]
    /// More files changed than are listed.
    public var truncated = false

    public init(commit: Commit, message: String, files: [ChangedFile] = [], truncated: Bool = false) {
        self.commit = commit
        self.message = message
        self.files = files
        self.truncated = truncated
    }

    /// The message after its first line.
    public var body: String {
        let lines = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        return lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    public var totals: LineStats {
        files.reduce(LineStats()) { LineStats(added: $0.added + ($1.added ?? 0), removed: $0.removed + ($1.removed ?? 0), files: $0.files + 1) }
    }
}

public enum CommitLog {
    public static let pageSize = 1000
    public static let fileLimit = 2000

    /// Ten fields a commit, each ending in NUL (with -z, the commit ends in one too).
    static let format = ["%H", "%P", "%an", "%ae", "%at", "%cn", "%ce", "%ct", "%D", "%s"].joined(separator: "%x00")
    static let fieldCount = 10

    /// `git log -z --format=<format>` output.
    public static func parse(_ data: Data) -> [Commit] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var commits: [Commit] = []
        var i = 0
        while i + fieldCount <= fields.count {
            let f = fields[i..<(i + fieldCount)].map { $0 }
            i += fieldCount
            // A commit's first field follows the previous commit's terminator directly.
            let sha = f[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard sha.count >= 40 else { continue }
            commits.append(Commit(sha: sha, parents: f[1].split(separator: " ").map(String.init),
                                  authorName: f[2], authorEmail: f[3], authorDate: Date(timeIntervalSince1970: Double(f[4]) ?? 0),
                                  committerName: f[5], committerEmail: f[6], committerDate: Date(timeIntervalSince1970: Double(f[7]) ?? 0),
                                  refs: CommitRef.parse(decoration: f[8]), subject: f[9]))
        }
        return commits
    }

    private static func base(_ root: String) -> [String] {
        ["-C", root, "--no-optional-locks", "-c", "log.showSignature=false", "-c", "log.follow=false", "-c", "core.quotepath=off"]
    }

    /// One page of the log, or nil when git fails (not a repository, a bad revision). A query whose
    /// text is a hash prefix of a commit lists that commit alone.
    public static func page(_ query: CommitQuery, skip: Int = 0, limit: Int = pageSize, in root: String, git: String,
                            timeout: TimeInterval = 30) -> [Commit]? {
        if let prefix = query.hashPrefix, let sha = resolve(prefix, in: root, git: git) {
            guard skip == 0 else { return [] }
            return GitRunner.run(git, base(root) + ["log", "--decorate=full", "--no-color", "--encoding=UTF-8", "-z", "--format=" + format,
                                                    "--max-count=1", "--end-of-options", sha, "--"], timeout: timeout).map(parse)
        }
        // HEAD only when there is a commit: on an unborn branch, naming it is an error.
        let hasHead = query.scope != .all || resolve("HEAD", in: root, git: git) != nil
        guard let data = GitRunner.run(git, base(root) + ["log"] + query.arguments(skip: skip, limit: limit, includeHead: hasHead), timeout: timeout) else {
            // A repository without a single commit has nothing to list.
            return hasHead || query.scope != .all ? nil : []
        }
        return parse(data)
    }

    /// The full id of the commit `revision` names, or nil.
    public static func resolve(_ revision: String, in root: String, git: String) -> String? {
        guard !revision.isEmpty, let data = GitRunner.run(git, ["-C", root, "--no-optional-locks", "rev-parse", "--verify", "--quiet", "--end-of-options",
                                                               revision + "^{commit}"], timeout: 10) else { return nil }
        let sha = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.count >= 40 ? sha : nil
    }

    /// A commit's whole message and its changed files (a merge's against its first parent), at most `fileLimit`.
    public static func details(of sha: String, in root: String, git: String, fileLimit: Int = fileLimit) -> CommitDetails? {
        let format = Self.format.replacingOccurrences(of: "%s", with: "%B")
        guard let data = GitRunner.run(git, base(root) + ["log", "--decorate=full", "--no-color", "--encoding=UTF-8", "-z", "--format=" + format,
                                                          "--max-count=1", "--end-of-options", sha, "--"], timeout: 15) else { return nil }
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        guard fields.count >= fieldCount, let parsed = parse(data).first else { return nil }
        let message = fields[fieldCount - 1].trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let commit = Commit(sha: parsed.sha, parents: parsed.parents, authorName: parsed.authorName, authorEmail: parsed.authorEmail,
                            authorDate: parsed.authorDate, committerName: parsed.committerName, committerEmail: parsed.committerEmail,
                            committerDate: parsed.committerDate, refs: parsed.refs, subject: subject)
        var details = CommitDetails(commit: commit, message: message)
        // The first commit is compared with nothing (--root, an option, so before --end-of-options).
        let against = commit.parents.first.map { ["--end-of-options", $0, commit.sha] } ?? ["--root", "--end-of-options", commit.sha]
        if let changes = GitRunner.run(git, base(root) + ["diff-tree", "-r", "-M", "--no-commit-id", "--raw", "--numstat", "-z", "--no-ext-diff",
                                                          "--no-textconv"] + against + ["--"], timeout: 30) {
            let files = parseChanges(changes)
            details.files = Array(files.prefix(fileLimit))
            details.truncated = files.count > fileLimit
        }
        return details
    }

    /// `diff-tree --raw --numstat -z`: the raw records (":100644 100644 a b M NUL path NUL", a rename
    /// "… R087 NUL old NUL new NUL"), then the counts ("1 TAB 2 TAB path NUL", a rename "1 TAB 2 TAB NUL
    /// old NUL new NUL"; "-" for a binary file).
    public static func parseChanges(_ data: Data) -> [ChangedFile] {
        let records = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var files: [ChangedFile] = []
        var index: [String: Int] = [:]
        var i = 0
        while i < records.count {
            let record = records[i]
            i += 1
            if record.hasPrefix(":") {
                let letter = record.split(separator: " ").last?.first.map(String.init) ?? "X"
                let status = ChangedFile.Status(rawValue: letter) ?? .unknown
                guard i < records.count else { break }
                if status == .renamed || status == .copied, i + 1 < records.count {
                    files.append(ChangedFile(path: records[i + 1], oldPath: records[i], status: status))
                    i += 2
                } else {
                    files.append(ChangedFile(path: records[i], status: status))
                    i += 1
                }
                index[files[files.count - 1].path] = files.count - 1
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
        return files
    }

    /// One file's diff in a commit, against its first parent (or nothing, for the first commit). A
    /// renamed file is compared with where it came from.
    public static func diff(of path: String, oldPath: String? = nil, commit: String, parent: String?, in root: String, git: String,
                            context: Int = 3) -> FileDiff? {
        let options = ["--no-color", "--no-ext-diff", "--no-textconv", "-M", "--histogram", "-p", "--full-index", "-U\(context)",
                       "--src-prefix=a/", "--dst-prefix=b/"]
        let against = parent.map { ["--end-of-options", $0, commit] } ?? ["--root", "--end-of-options", commit]
        let paths = [oldPath, path].compactMap { $0 }
        guard let data = GitRunner.run(git, ["-C", root, "--no-optional-locks", "-c", "core.quotepath=off", "diff-tree", "-r", "--no-commit-id"]
                                       + options + against + ["--"] + paths, timeout: 15) else { return nil }
        let files = UnifiedDiff.parse(String(decoding: data, as: UTF8.self))
        return files.first { $0.newPath == path || $0.oldPath == path } ?? files.first ?? FileDiff()
    }

    /// Every ref and where HEAD points, as one string: when it changes, the log is out of date. Two
    /// quick reads, for after the repository's folder changed (most changes there are not to refs).
    public static func refsSignature(in root: String, git: String) -> String? {
        let base = ["-C", root, "--no-optional-locks"]
        guard let refs = GitRunner.run(git, base + ["show-ref", "--head"], timeout: 10, acceptedStatus: [0, 1]) else { return nil }
        let head = GitRunner.run(git, base + ["rev-parse", "--symbolic-full-name", "HEAD"], timeout: 10, acceptedStatus: [0, 128]) ?? Data()
        return String(decoding: head + refs, as: UTF8.self)
    }

    /// Tag names, newest first.
    public static func tags(in root: String, git: String) -> [String] {
        guard let data = GitRunner.run(git, ["-C", root, "--no-optional-locks", "for-each-ref", "--sort=-creatordate", "--format=%(refname)", "refs/tags"],
                                       timeout: 15) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map { String($0.dropFirst("refs/tags/".count)) }
    }

    /// The name commits here are made with (`user.name`), for "Me" in the author filter.
    public static func userName(in root: String, git: String) -> String? {
        GitRunner.run(git, ["-C", root, "config", "user.name"], timeout: 5)
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}
