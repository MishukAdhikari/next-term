import Foundation

/// How a path differs from HEAD. Ordered by how much a folder containing it should stand out.
public enum GitChange: Int, Comparable, Sendable {
    case ignored, untracked, added, renamed, deleted, modified, conflicted

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Lines added and removed, and how many files changed.
public struct LineStats: Equatable, Sendable {
    public var added = 0
    public var removed = 0
    public var files = 0

    public init(added: Int = 0, removed: Int = 0, files: Int = 0) {
        self.added = added
        self.removed = removed
        self.files = files
    }

    static func + (a: Self, b: Self) -> Self {
        LineStats(added: a.added + b.added, removed: a.removed + b.removed, files: a.files + b.files)
    }
}

/// One read of a repository's state: branch, upstream, and every changed path with its line counts,
/// rolled up to folders. Paths are relative to the work-tree root, without a leading or trailing "/".
public struct GitSnapshot: Sendable {
    public var root: String
    /// nil when HEAD is detached.
    public var branch: String?
    /// Short commit id of HEAD; nil before the first commit.
    public var head: String?
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    public var files: [String: GitChange] = [:]
    public var fileStats: [String: LineStats] = [:]
    /// Untracked or ignored folders git reports as a whole ("node_modules/").
    public var wholeFolders: [String: GitChange] = [:]
    /// Strongest change below each folder (ignored entries do not count).
    public var folderChanges: [String: GitChange] = [:]
    public var folderStats: [String: LineStats] = [:]

    public init(root: String) { self.root = root }

    /// Sum over all changed files.
    public var totals: LineStats { folderStats[""] ?? LineStats() }

    public func count(of change: GitChange) -> Int {
        files.values.filter { $0 == change }.count + wholeFolders.values.filter { $0 == change }.count
    }

    /// The change to show for a path in the tree.
    public func change(at relativePath: String, isDirectory: Bool) -> GitChange? {
        if isDirectory, let whole = wholeFolders[relativePath] { return whole }
        if let own = isDirectory ? folderChanges[relativePath] : files[relativePath] { return own }
        return inherited(relativePath)
    }

    public func stats(at relativePath: String, isDirectory: Bool) -> LineStats? {
        let stats = isDirectory ? folderStats[relativePath] : fileStats[relativePath]
        guard let stats, stats.added + stats.removed + stats.files > 0 else { return nil }
        return stats
    }

    /// Inside an untracked or ignored folder, everything is untracked or ignored.
    private func inherited(_ path: String) -> GitChange? {
        var current = path
        while let slash = current.lastIndex(of: "/") {
            current = String(current[..<slash])
            if let whole = wholeFolders[current] { return whole }
        }
        return nil
    }

    // MARK: parsing

    /// Parses `git status --porcelain=v2 --branch -z` and `git diff --numstat -z` output.
    public static func parse(root: String, status: Data, numstat: Data) -> GitSnapshot {
        var snapshot = GitSnapshot(root: root)
        let records = status.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var i = 0
        while i < records.count {
            let record = records[i]
            i += 1
            guard let kind = record.first else { continue }
            switch kind {
            case "#":
                snapshot.readHeader(record)
            case "1":
                // 1 XY sub mH mI mW hH hI path
                let f = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard f.count == 9 else { continue }
                snapshot.files[String(f[8])] = ordinaryChange(String(f[1]))
            case "2":
                // 2 XY sub mH mI mW hH hI Xscore path NUL origPath
                let f = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard f.count == 10 else { continue }
                let xy = String(f[1])
                snapshot.files[String(f[9])] = xy.contains("C") ? .added : .renamed
                i += 1 // the original path
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let f = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard f.count == 11 else { continue }
                snapshot.files[String(f[10])] = .conflicted
            case "?", "!":
                guard record.count > 2 else { continue }
                let path = String(record.dropFirst(2))
                let change: GitChange = kind == "?" ? .untracked : .ignored
                if path.hasSuffix("/") {
                    snapshot.wholeFolders[String(path.dropLast())] = change
                } else {
                    snapshot.files[path] = change
                }
            default:
                continue
            }
        }
        snapshot.readNumstat(numstat)
        snapshot.rollUp()
        return snapshot
    }

    private mutating func readHeader(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return }
        switch parts[1] {
        case "branch.oid": head = parts[2] == "(initial)" ? nil : String(parts[2].prefix(8))
        case "branch.head": branch = parts[2] == "(detached)" ? nil : parts[2]
        case "branch.upstream": upstream = parts[2]
        case "branch.ab":
            let ab = parts[2].split(separator: " ")
            if ab.count == 2 {
                ahead = Int(ab[0].dropFirst()) ?? 0
                behind = Int(ab[1].dropFirst()) ?? 0
            }
        default: break
        }
    }

    static func ordinaryChange(_ xy: String) -> GitChange {
        let x = xy.first ?? ".", y = xy.dropFirst().first ?? "."
        if x == "A" { return .added }
        if x == "D" || y == "D" { return .deleted }
        return .modified
    }

    /// `added<TAB>removed<TAB>path NUL`, or for a rename `added<TAB>removed<TAB> NUL old NUL new NUL`.
    /// Binary files report "-" and count as zero lines.
    private mutating func readNumstat(_ data: Data) {
        let records = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var i = 0
        while i < records.count {
            let fields = records[i].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            i += 1
            guard fields.count == 3 else { continue }
            var path = String(fields[2])
            if path.isEmpty, i + 1 < records.count { // rename: the new path is the second of the next two
                path = records[i + 1]
                i += 2
            }
            fileStats[path] = LineStats(added: Int(fields[0]) ?? 0, removed: Int(fields[1]) ?? 0, files: 1)
        }
    }

    /// Adds untracked files' line counts (as GitHub shows new files), which git diff does not report.
    public mutating func addUntrackedLines(_ counts: [String: Int]) {
        for (path, lines) in counts where files[path] == .untracked {
            fileStats[path] = LineStats(added: lines, removed: 0, files: 1)
        }
        rollUp()
    }

    /// Folder change = strongest change below it; folder stats = sum below it ("" is the whole tree).
    private mutating func rollUp() {
        folderChanges = [:]
        folderStats = [:]
        var changed = files.filter { $0.value != .ignored }
        for (folder, change) in wholeFolders where change != .ignored { changed[folder] = change }
        for (path, change) in changed {
            let stats = fileStats[path] ?? LineStats(files: 1)
            var current = path
            while true {
                let parent: String
                if let slash = current.lastIndex(of: "/") { parent = String(current[..<slash]) } else { parent = "" }
                folderChanges[parent] = max(folderChanges[parent] ?? change, change)
                folderStats[parent, default: LineStats()] = folderStats[parent, default: LineStats()] + stats
                if parent.isEmpty { break }
                current = parent
            }
        }
    }
}

/// Runs git. Read-only commands only, with `--no-optional-locks` so a refresh never takes the index
/// lock out from under the user's own git commands.
public enum GitRunner {
    /// A real git binary. Never the /usr/bin/git stub when no developer tools are installed: running it
    /// would pop up the "install command line developer tools" dialog.
    public static func locateGit(fileManager: FileManager = .default) -> String? {
        let candidates = [
            "/opt/homebrew/bin/git", "/usr/local/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/usr/bin/git", // Linux
        ]
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            if path == "/usr/bin/git" {
                #if os(macOS)
                continue // the stub; the real binaries are above
                #endif
            }
            return path
        }
        return nil
    }

    /// The repository state for the work tree containing `directory`, or nil if there is none.
    public static func snapshot(for directory: String, git: String, timeout: TimeInterval = 15) -> GitSnapshot? {
        guard let top = run(git, ["-C", directory, "rev-parse", "--show-toplevel"], timeout: timeout),
              let root = String(data: top, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !root.isEmpty else { return nil }
        guard let status = run(git, ["-C", root, "--no-optional-locks", "status", "--porcelain=v2", "--branch", "-z",
                                     "--untracked-files=normal", "--ignored=matching"], timeout: timeout) else { return nil }
        var snapshot = GitSnapshot.parse(root: root, status: status, numstat: Data())
        // Lines changed against HEAD (staged and unstaged together); before the first commit, against nothing.
        let base = snapshot.head == nil ? emptyTree(git: git, root: root) : "HEAD"
        // Plumbing, not `git diff`: the porcelain refreshes and rewrites .git/index (taking index.lock) even
        // with --no-optional-locks, which can make an agent's `git commit` fail mid-refresh.
        let numstat = base.flatMap { run(git, ["-C", root, "--no-optional-locks", "diff-index", "--numstat", "-z", "-M", $0, "--"], timeout: timeout) } ?? Data()
        snapshot = GitSnapshot.parse(root: root, status: status, numstat: numstat)
        snapshot.addUntrackedLines(countLines(of: snapshot.files.filter { $0.value == .untracked }.map(\.key), in: root))
        return snapshot
    }

    private static func emptyTree(git: String, root: String) -> String? {
        run(git, ["-C", root, "hash-object", "-t", "tree", "/dev/null"], timeout: 5)
            .flatMap { String(data: $0, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Line counts for new files, as GitHub shows them; skips binaries, big files and huge sets.
    static func countLines(of paths: [String], in root: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for path in paths.prefix(500) {
            let url = URL(fileURLWithPath: root).appendingPathComponent(path)
            guard isRegularFile(url.path), let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 1_000_000,
                  let data = try? Data(contentsOf: url), !data.prefix(8000).contains(0) else { continue }
            var lines = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            if let last = data.last, last != 0x0A { lines += 1 }
            counts[path] = lines
        }
        return counts
    }

    /// The diff between two texts (an agent's proposed version against the file on disk), by git's
    /// histogram diff on temporary files.
    public static func diff(old: String, new: String, git: String, context: Int = 3) -> FileDiff? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("next-term-diff-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = folder.appendingPathComponent("a"), b = folder.appendingPathComponent("b")
        guard (try? Data(old.utf8).write(to: a)) != nil, (try? Data(new.utf8).write(to: b)) != nil else { return nil }
        let args = ["--no-optional-locks", "diff", "--no-index", "--no-color", "--no-ext-diff", "--histogram", "-U\(context)",
                    "--src-prefix=a/", "--dst-prefix=b/", "--", a.path, b.path]
        // Exit 1 means "they differ", the expected case.
        guard let data = run(git, args, timeout: 15, acceptedStatus: [0, 1]), let text = String(data: data, encoding: .utf8) else { return nil }
        return UnifiedDiff.parse(text).first ?? FileDiff()
    }

    /// Whether git tracks the file (an untracked file's diff is all additions).
    public static func isTracked(_ relativePath: String, in root: String, git: String) -> Bool {
        run(git, ["-C", root, "ls-files", "--error-unmatch", "--", relativePath], timeout: 10) != nil
    }

    /// What a diff compares.
    public enum DiffBase: Sendable {
        /// Working tree against HEAD: staged and unstaged changes together.
        case head
        /// Staged changes: index against HEAD.
        case staged
        /// Unstaged changes: working tree against the index.
        case unstaged
    }

    /// The diff of one file, or nil if it has none. Untracked files diff against nothing.
    /// `context` lines around each change (a large number gives the whole file).
    public static func diff(of relativePath: String, in root: String, git: String, base: DiffBase = .head,
                            context: Int = 3, untracked: Bool = false) -> FileDiff? {
        // Plumbing (diff-index, diff-files) so reading a diff never rewrites .git/index; see snapshot().
        let options = ["--no-color", "--no-ext-diff", "--no-textconv", "-M", "--histogram", "-p", "--full-index", "-U\(context)"]
        let prefix = ["-C", root, "--no-optional-locks", "-c", "core.quotepath=off", "-c", "diff.autoRefreshIndex=false"]
        let args: [String]
        if untracked {
            // Porcelain here, so pin the a/ b/ prefixes: a user's diff.noprefix would otherwise change them.
            args = prefix + ["diff", "--no-index", "--src-prefix=a/", "--dst-prefix=b/"] + options + ["--", "/dev/null", relativePath]
        } else {
            switch base {
            case .head: args = prefix + ["diff-index"] + options + ["HEAD", "--", relativePath]
            case .staged: args = prefix + ["diff-index", "--cached"] + options + ["HEAD", "--", relativePath]
            case .unstaged: args = prefix + ["diff-files"] + options + ["--", relativePath]
            }
        }
        // `diff --no-index` exits 1 when the files differ, which is the expected case here.
        guard let data = run(git, args, timeout: 15, acceptedStatus: untracked ? [0, 1] : [0]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return UnifiedDiff.parse(text).first
    }

    /// Applies a patch: to the index (`cached`, i.e. stage it) or to the working tree, forwards or
    /// reversed (revert). Checks first, so a patch that no longer fits changes nothing.
    @discardableResult
    public static func apply(_ patch: String, in root: String, git: String, cached: Bool, reverse: Bool) -> Bool {
        // The patch goes in a file, not through stdin: a pipe's write end inherited by another process
        // starting at the same moment would keep git waiting for the end of input forever.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("next-term-\(UUID().uuidString).patch")
        guard (try? Data(patch.utf8).write(to: file)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: file) }
        var args = ["-C", root, "apply", "--whitespace=nowarn"]
        if cached { args.append("--cached") }
        if reverse { args.append("-R") }
        guard run(git, args + ["--check", file.path], timeout: 15) != nil else { return false }
        return run(git, args + [file.path], timeout: 15) != nil
    }

    /// Runs a command and returns its standard output, or nil on failure or timeout. Never waits longer
    /// than `timeout` (plus a few seconds to stop the process): a stuck git must not hang the caller.
    ///
    /// Output goes to a temporary file, not a pipe. A pipe's end is inherited by any process started at
    /// the same moment (another git, or a new tab's shell, which can live for days), and the end of the
    /// output would never arrive while it is open. A file has no end to wait for: the exit is enough.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                    acceptedStatus: Set<Int32> = [0]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Inherited GIT_* variables (GIT_DIR, GIT_INDEX_FILE, GIT_WORK_TREE from the shell that launched
        // the app) would point every command at the wrong repository: start from a clean slate.
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        // No fsmonitor daemon spawned by our reads.
        env["GIT_CONFIG_COUNT"] = "1"
        env["GIT_CONFIG_KEY_0"] = "core.fsmonitor"
        env["GIT_CONFIG_VALUE_0"] = "false"
        process.environment = env

        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("next-term-out-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forWritingTo: outputURL) else { return nil }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            try? output.close()
            return nil
        }
        try? output.close() // the child has its own copy
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
            return nil
        }
        guard acceptedStatus.contains(process.terminationStatus) else { return nil }
        return try? Data(contentsOf: outputURL)
    }
}
