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

    /// A remote's HEAD ("origin/HEAD"): a pointer to its default branch, not a branch to check out.
    public var isRemoteHead: Bool { kind == .remote && fullName.hasSuffix("/HEAD") }

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

    func with(parents: [String]) -> Commit {
        Commit(sha: sha, parents: parents, authorName: authorName, authorEmail: authorEmail, authorDate: authorDate, committerName: committerName,
               committerEmail: committerEmail, committerDate: committerDate, refs: refs, subject: subject)
    }
}

/// The commits a query lists, in order (newest first, each after its children), as `git rev-list`
/// gives them: only their ids, kept as bytes (a million commits in about 40 MB), with, for a log
/// limited to paths, each one's parents there, the nearest listed ancestors, which only the walk knows.
public struct CommitOrder: Equatable, Sendable {
    /// The ids one after another, each `width` hex digits (40, or 64 in a SHA-256 repository).
    private let bytes: [UInt8]
    private let width: Int
    /// "parent parent", by place; only for a log limited to paths.
    private let rewritten: [String]?
    public let count: Int

    public init(ids: [String], parents: [[String]]? = nil) {
        let width = ids.first?.utf8.count ?? 40
        let ids = ids.filter { $0.utf8.count == width }
        self.width = width
        bytes = ids.flatMap { Array($0.lowercased().utf8) }
        count = ids.count
        rewritten = parents.map { $0.prefix(ids.count).map { $0.joined(separator: " ") } }
    }

    /// `git rev-list` output: an id a line, followed by its parents with `--parents`.
    init(revList data: Data, withParents: Bool) {
        var bytes: [UInt8] = [], parents: [String] = []
        var width = 0, count = 0
        bytes.reserveCapacity(data.count)
        for line in data.split(separator: UInt8(ascii: "\n")) {
            let id = line.prefix { $0 != UInt8(ascii: " ") }
            if width == 0 { width = id.count }
            guard id.count == width, width > 0 else { continue }
            bytes += id
            count += 1
            if withParents { parents.append(String(decoding: line.dropFirst(width + 1), as: UTF8.self)) }
        }
        self.bytes = bytes
        self.width = max(width, 1)
        self.count = count
        rewritten = withParents ? parents : nil
    }

    public func id(at index: Int) -> String { String(decoding: bytes[(index * width)..<((index + 1) * width)], as: UTF8.self) }

    public func ids(_ range: Range<Int>) -> [String] { range.map(id(at:)) }

    /// Limited to paths, the parents the log shows for the commit here; nil otherwise.
    func parents(at index: Int) -> [String]? { rewritten.map { $0[index].split(separator: " ").map(String.init) } }

    /// Where the commit with this id, or the first whose id starts with it, is listed.
    public func index(of sha: String) -> Int? {
        let prefix = Array(sha.lowercased().utf8)
        guard count > 0, !prefix.isEmpty, prefix.count <= width else { return nil }
        return bytes.withUnsafeBufferPointer { all in
            prefix.withUnsafeBufferPointer { wanted in
                (0..<count).first { memcmp(all.baseAddress! + $0 * width, wanted.baseAddress!, wanted.count) == 0 }
            }
        }
    }
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
    /// The author is a whole name (picked from a list), not part of a name or an address: "Ann" is
    /// not also "Joanne" or "Ann Lee".
    public var exactAuthor = false
    /// Dates as git reads them: "2025-01-31", "2 weeks ago".
    public var since: String?
    public var until: String?
    /// From the work tree's root.
    public var paths: [String] = []

    public init(scope: Scope = .all, text: String = "", regex: Bool = false, author: String = "", exactAuthor: Bool = false, since: String? = nil,
                until: String? = nil, paths: [String] = []) {
        self.scope = scope
        self.text = text
        self.regex = regex
        self.author = author
        self.exactAuthor = exactAuthor
        self.since = since
        self.until = until
        self.paths = paths
    }

    /// Whether lines can join each commit to its parents. Filtered by message or author, a commit's
    /// parents are mostly not listed, so the graph shows the commits alone.
    public var isConnected: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty && author.trimmingCharacters(in: .whitespaces).isEmpty }

    public var isFiltered: Bool { !isConnected || since != nil || until != nil || !paths.isEmpty }

    /// Searching text or names: a UTF-8 locale, so ignoring case covers “Ü” and “É”, not only A to Z
    /// (GitRunner reads everything else in the C locale).
    var environment: [String: String] { isConnected ? [:] : ["LC_ALL": "en_US.UTF-8"] }

    /// Why git could not run the query, known before asking it: a regular expression that does not
    /// compile (git reads it with the same regcomp).
    public var problem: String? {
        let text = self.text.trimmingCharacters(in: .whitespaces)
        guard regex, !text.isEmpty else { return nil }
        var compiled = regex_t()
        let result = regcomp(&compiled, text, REG_EXTENDED | REG_ICASE | REG_NOSUB)
        if result == 0 { regfree(&compiled) }
        return result == 0 ? nil : "This is not a valid regular expression. Turn off .* to search for the text as it is."
    }

    /// The text, when it could be the start of a commit id (6 to 40 hex digits).
    public var hashPrefix: String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard (6...40).contains(trimmed.count), trimmed.allSatisfy({ $0.isHexDigit }) else { return nil }
        return trimmed
    }

    /// The `git rev-list` options and revisions after `rev-list`: the ids the query lists, in order.
    func arguments(includeHead: Bool) -> [String] {
        var args = ["--topo-order"]
        let text = self.text.trimmingCharacters(in: .whitespaces), author = self.author.trimmingCharacters(in: .whitespaces)
        // --fixed-strings covers --author as well, so with any regular expression (the text's, or the
        // anchored one for a whole name) the other part is escaped instead.
        let exact = exactAuthor && !author.isEmpty
        let patterns = (regex && !text.isEmpty) || exact
        let escape = { (part: String) in patterns ? NSRegularExpression.escapedPattern(for: part) : part }
        if !text.isEmpty || !author.isEmpty {
            args.append("--regexp-ignore-case")
            args.append(patterns ? "--extended-regexp" : "--fixed-strings")
        }
        if !text.isEmpty { args.append("--grep=" + (regex ? text : escape(text))) }
        // git matches the author against "Name <email> time zone".
        if !author.isEmpty { args.append("--author=" + (exact ? "^" + escape(author) + " <" : escape(author))) }
        // git knows no "today": it takes it for now, as it does any word it does not know, and since
        // now lists nothing. Since today is since midnight (until today, until now, is right as it is).
        if let since, !since.isEmpty {
            let today = since.trimmingCharacters(in: .whitespaces).lowercased() == "today"
            args.append("--since=" + (today ? "midnight" : since))
        }
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
    /// The files' lines were counted (not in a partial clone without their contents).
    public var isCounted = true
    /// The files were listed: not when git could not read the commit's trees (a treeless clone, offline).
    public var isListed = true

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

    /// Paths are file names, never patterns: `[1].txt` is that file, and `:weird.txt` too.
    private static func base(_ root: String) -> [String] {
        ["-C", root, "--no-optional-locks", "--literal-pathspecs", "-c", "log.showSignature=false", "-c", "log.follow=false", "-c", "core.quotepath=off"]
    }

    /// Every commit the query lists, in order, as ids; nil when git fails (not a repository, a bad
    /// revision). A query whose text is a hash prefix of a commit lists that commit alone. One walk of
    /// the history, however long: pages then read their commits by id, so none walks it again.
    public static func order(_ query: CommitQuery, in root: String, git: String, timeout: TimeInterval = 60) -> CommitOrder? {
        if let prefix = query.hashPrefix, let sha = resolve(prefix, in: root, git: git) { return CommitOrder(ids: [sha]) }
        // HEAD only when there is a commit: on an unborn branch, naming it is an error.
        let hasHead = query.scope != .all || resolve("HEAD", in: root, git: git) != nil
        guard let data = GitRunner.run(git, base(root) + ["rev-list"] + query.arguments(includeHead: hasHead), timeout: timeout,
                                       environment: query.environment) else {
            // A repository without a single commit has nothing to list.
            return hasHead || query.scope != .all ? nil : CommitOrder(ids: [])
        }
        return CommitOrder(revList: data, withParents: !query.paths.isEmpty)
    }

    /// The commits at these places in the order, in full: `git log --no-walk` on their ids, which reads
    /// only those commits. Nil when git fails. Each git run lists up to ten pages: reading the refs for
    /// the branch and tag badges is most of its time when a repository has thousands of them.
    public static func commits(_ range: Range<Int>, of order: CommitOrder, in root: String, git: String, timeout: TimeInterval = 30) -> [Commit]? {
        let range = range.clamped(to: 0..<order.count)
        var commits: [Commit] = []
        commits.reserveCapacity(range.count)
        for start in stride(from: range.lowerBound, to: range.upperBound, by: pageSize * 10) {
            let part = start..<min(start + pageSize * 10, range.upperBound)
            let ids = order.ids(part)
            // The ids on standard input (from a file): ten thousand would make a long command line.
            let args = ["log", "--no-walk=unsorted", "--decorate=full", "--no-color", "--encoding=UTF-8", "-z", "--format=" + format, "--stdin"]
            guard let data = GitRunner.run(git, base(root) + args, timeout: timeout, input: Data(ids.joined(separator: "\n").utf8 + [10])) else { return nil }
            let page = parse(data)
            // As asked, one for one; anything else means the repository changed under us.
            guard page.map(\.sha) == ids else { return nil }
            commits += zip(page, part).map { commit, index in order.parents(at: index).map { commit.with(parents: $0) } ?? commit }
        }
        return commits
    }

    /// One page of the log, reading the order first: for a single read. The Git Log keeps the order
    /// and asks `commits` for each page.
    public static func page(_ query: CommitQuery, skip: Int = 0, limit: Int = pageSize, in root: String, git: String,
                            timeout: TimeInterval = 30) -> [Commit]? {
        guard let order = order(query, in: root, git: git, timeout: timeout) else { return nil }
        let start = min(skip, order.count)
        return commits(start..<min(order.count, start + limit), of: order, in: root, git: git, timeout: timeout)
    }

    /// Whether git reads `text` as a date. Words it does not know it takes for the moment it runs, so a
    /// date that comes out as now is not one, unless it says so.
    public static func isDate(_ text: String, in root: String, git: String, now: Date = Date()) -> Bool {
        let words = text.trimmingCharacters(in: .whitespaces).lowercased()
        if words.isEmpty || words == "now" || words == "today" { return true }
        guard let data = GitRunner.run(git, ["-C", root, "rev-parse", "--since=" + words], timeout: 5) else { return false }
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.hasPrefix("--max-age="), let stamp = Double(output.dropFirst("--max-age=".count)) else { return false }
        return abs(stamp - now.timeIntervalSince1970) >= 2
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
        // Counting lines and finding renames read the files. In a partial clone, those not downloaded
        // stay so (reading a commit must not fetch them); the files are then listed without counts.
        let noFetch = ["GIT_NO_LAZY_FETCH": "1"]
        let options = ["diff-tree", "-r", "--no-commit-id", "--raw", "-z", "--no-ext-diff", "--no-textconv"]
        let listing = base(root) + options + against + ["--"]
        if let changes = GitRunner.run(git, base(root) + options + ["-M", "--numstat"] + against + ["--"], timeout: 30, environment: noFetch) {
            details.files = parseChanges(changes)
        } else if let changes = GitRunner.run(git, listing, timeout: 30, environment: noFetch) ?? GitRunner.run(git, listing, timeout: 30) {
            // The second run is for a treeless clone: listing the files needs the two trees, which git
            // then downloads (trees only, never the files in them).
            details.files = parseChanges(changes)
            details.isCounted = false
        } else {
            details.isListed = false
        }
        details.truncated = details.files.count > fileLimit
        details.files = Array(details.files.prefix(fileLimit))
        return details
    }

    /// A commit's whole message alone, without reading its files (which a treeless clone would download).
    public static func message(of sha: String, in root: String, git: String) -> String? {
        let args = ["log", "--no-color", "--encoding=UTF-8", "--format=%B", "--max-count=1", "--end-of-options", sha, "--"]
        guard let data = GitRunner.run(git, base(root) + args, timeout: 15) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard let data = GitRunner.run(git, ["-C", root, "--no-optional-locks", "--literal-pathspecs", "-c", "core.quotepath=off", "diff-tree", "-r", "--no-commit-id"]
                                       + options + against + ["--"] + paths, timeout: 15) else { return nil }
        let files = UnifiedDiff.parse(String(decoding: data, as: UTF8.self))
        let new = files.first { $0.newPath == path }, old = files.first { $0.oldPath == path }
        // A file that became a link (or a link that became a file) is two patches, the old one deleted
        // and the new one added: both halves, as one change to the path.
        if var both = new, let old, both.isNew, old.isDeleted {
            both.oldPath = old.oldPath
            both.oldBlob = old.oldBlob
            both.isBinary = both.isBinary || old.isBinary
            both.hunks = old.hunks + both.hunks
            both.header = old.header + both.header
            return both
        }
        return new ?? old ?? files.first ?? FileDiff()
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
        GitRunner.run(git, ["-C", root, "--no-optional-locks", "config", "user.name"], timeout: 5)
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}
