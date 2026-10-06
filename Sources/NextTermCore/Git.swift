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
        let numstat = base.flatMap { run(git, ["-C", root, "--no-optional-locks", "diff", "--numstat", "-z", $0, "--"], timeout: timeout) } ?? Data()
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
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 1_000_000,
                  let data = try? Data(contentsOf: url), !data.prefix(8000).contains(0) else { continue }
            var lines = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            if let last = data.last, last != 0x0A { lines += 1 }
            counts[path] = lines
        }
        return counts
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
        let common = ["-C", root, "--no-optional-locks", "-c", "core.quotepath=off", "diff", "--no-color", "--no-ext-diff",
                      "--no-textconv", "-M", "-U\(context)"]
        let args: [String]
        if untracked {
            args = common + ["--no-index", "--", "/dev/null", relativePath]
        } else {
            switch base {
            case .head: args = common + ["HEAD", "--", relativePath]
            case .staged: args = common + ["--cached", "--", relativePath]
            case .unstaged: args = common + ["--", relativePath]
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
        var args = ["-C", root, "apply", "--whitespace=nowarn"]
        if cached { args.append("--cached") }
        if reverse { args.append("-R") }
        let input = Data(patch.utf8)
        guard run(git, args + ["--check", "-"], timeout: 15, input: input) != nil else { return false }
        return run(git, args + ["-"], timeout: 15, input: input) != nil
    }

    /// Runs a command and returns its standard output, or nil on failure or timeout.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval,
                    input: Data? = nil, acceptedStatus: Set<Int32> = [0]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        if let stdin, let input {
            DispatchQueue.global().async {
                stdin.fileHandleForWriting.write(input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile() // read before waiting: large output would fill the pipe
        process.waitUntilExit()
        timer.cancel()
        return acceptedStatus.contains(process.terminationStatus) ? data : nil
    }
}
