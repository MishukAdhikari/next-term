import Foundation

// Where each local agent works: the checkout of the repository (the main one or a linked worktree) that
// holds its folder, and that checkout's branch, read from git. A move or a branch change counts once it has
// held for 3 s with no git operation in progress there. Who switched a checkout decides which chats in it
// were switched under (PlaceTracker). Design: claudedocs/2026-10-09-brainstorm-branch-aware-agents (R1–R6).

/// What a checkout's HEAD is on.
public enum CheckoutHead: Hashable, Sendable {
    case branch(String)
    /// Detached at a commit (its full id).
    case detached(String)

    /// "fix/7027-sso", or "detached at abc1234".
    public var name: String {
        switch self {
        case let .branch(name): return name
        case let .detached(commit): return "detached at " + commit.prefix(7)
        }
    }
}

/// One checkout of a repository, as `git worktree list` lists it.
public struct Checkout: Equatable, Sendable {
    /// Its top folder.
    public let path: String
    public let head: CheckoutHead
    /// The commit HEAD is at; nil before the first commit.
    public let commit: String?
    /// The repository's main checkout (the first one `git worktree list` names), not a linked worktree.
    public let isMain: Bool
    /// git is in the middle of a rebase, merge, cherry-pick, revert, `am` or bisect here.
    public let busy: Bool

    public init(path: String, head: CheckoutHead, commit: String? = nil, isMain: Bool = false, busy: Bool = false) {
        self.path = path
        self.head = head
        self.commit = commit
        self.isMain = isMain
        self.busy = busy
    }

    /// "xCloud" for the main checkout, "worktree pr-7050" for a linked one.
    public var title: String {
        let folder = (path as NSString).lastPathComponent
        return isMain ? folder : "worktree " + folder
    }

    /// The same checkout with its HEAD on `head` (what a held value says, not the newest read).
    func on(_ head: CheckoutHead) -> Checkout {
        Checkout(path: path, head: head, commit: commit, isMain: isMain, busy: busy)
    }
}

/// A folder an agent's session record names, and when it was written there.
public struct RecordedFolder: Equatable, Sendable {
    public let folder: String
    public let at: Date

    public init(folder: String, at: Date) {
        self.folder = folder
        self.at = at
    }
}

/// How a held HEAD change reads: a real switch, a branch renamed in place (working branches follow the
/// new name), or nothing (commits on a detached HEAD).
public enum HeadChange: Equatable, Sendable {
    case switched
    case renamed(from: String, to: String)
    case none
}

public enum AgentLocation {
    /// How long a new location or branch must hold before it counts (R3).
    public static let hold: TimeInterval = 3

    // MARK: checkouts

    /// The repository holding `folder`: its git common folder and the top folder of the checkout. nil
    /// outside one.
    public static func repository(of folder: String, git: String) -> (commonDir: String, root: String)? {
        let args = ["-C", folder, "--no-optional-locks", "rev-parse", "--path-format=absolute", "--git-common-dir", "--show-toplevel"]
        guard let data = GitRunner.run(git, args, timeout: 10) else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        guard lines.count >= 2 else { return nil }
        return (canonicalPath(lines[0]), canonicalPath(lines[1]))
    }

    /// The repository's checkouts, from `git worktree list` run in one of them, each with what git is in
    /// the middle of there. nil when git can't say.
    public static func checkouts(in root: String, git: String) -> [Checkout]? {
        guard let data = GitRunner.run(git, ["-C", root, "--no-optional-locks", "worktree", "list", "--porcelain", "-z"], timeout: 10) else { return nil }
        return checkouts(BranchModel.parseWorktrees(data)) { path in gitDir(ofCheckout: path).map(isBusy) ?? false }
    }

    /// `git worktree list`'s entries as checkouts: bare and prunable ones left out, paths made canonical,
    /// the first one the main checkout.
    static func checkouts(_ worktrees: [Worktree], canonical: (String) -> String = canonicalPath, busy: (String) -> Bool) -> [Checkout] {
        worktrees.enumerated().compactMap { index, worktree -> Checkout? in
            guard !worktree.isBare, !worktree.isPrunable else { return nil }
            let path = canonical(worktree.path)
            let commit = worktree.head.flatMap { $0.allSatisfy { $0 == "0" } ? nil : $0 }
            let head: CheckoutHead = worktree.branch.map(CheckoutHead.branch) ?? .detached(commit ?? "")
            return Checkout(path: path, head: head, commit: commit, isMain: index == 0, busy: busy(path))
        }
    }

    /// A checkout's own git folder: the `.git` folder in it, or the one its `.git` file names (a linked
    /// worktree's `<common>/worktrees/<name>`), where its HEAD and in-progress files are.
    public static func gitDir(ofCheckout path: String) -> String? {
        let dotGit = (path as NSString).appendingPathComponent(".git")
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isFolder) else { return nil }
        if isFolder.boolValue { return dotGit }
        guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
        let dir = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
        return dir.hasPrefix("/") ? dir : URL(fileURLWithPath: path).appendingPathComponent(dir).standardized.path
    }

    /// What changes when a checkout of the repository switches, starts or ends a git operation, or when a
    /// worktree comes or goes: when each checkout's git folder and HEAD last changed. No git process: while
    /// it is the same, the last `checkouts` still hold.
    public static func signature(commonDir: String) -> String {
        func stamp(_ path: String) -> String {
            let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            return date.map { String($0.timeIntervalSince1970) } ?? "-"
        }
        let admin = (commonDir as NSString).appendingPathComponent("worktrees")
        var parts = [stamp(commonDir), stamp(commonDir + "/HEAD"), stamp(admin)]
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: admin)) ?? []).sorted() {
            let folder = (admin as NSString).appendingPathComponent(name)
            parts.append(name + " " + stamp(folder) + " " + stamp(folder + "/HEAD"))
        }
        return parts.joined(separator: "\n")
    }

    /// git is in the middle of something in this git folder: a rebase, merge, cherry-pick, revert, `am`
    /// (rebase-apply) or bisect.
    public static func isBusy(gitDir: String) -> Bool {
        BranchModel.inProgress(gitDir: gitDir) != nil
    }

    /// The checkout holding `folder`: the one with the longest path that contains it, since worktrees nest
    /// (`xCloud/.claude/worktrees/pr-7050/app` is in pr-7050, not in xCloud). A subagent's worktree doesn't
    /// count (R5): a folder in one is in the checkout around it. nil outside every checkout (another
    /// repository, a separate clone). Paths are compared as given: pass canonical ones.
    public static func checkout(containing folder: String, in checkouts: [Checkout]) -> Checkout? {
        let holding = checkouts.filter { checkout in
            !isSubagentWorktree(checkout.path) && (folder == checkout.path || folder.hasPrefix(checkout.path + "/"))
        }
        return holding.max { $0.path.count < $1.path.count }
    }

    /// Claude Code's isolated worktrees for its subagents: `.claude/worktrees/agent-<id>`.
    public static func isSubagentWorktree(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard parts.count >= 3, parts[parts.count - 2] == "worktrees", parts[parts.count - 3] == ".claude" else { return false }
        let name = parts[parts.count - 1]
        guard name.hasPrefix("agent-") else { return false }
        let id = name.dropFirst(6)
        return id.count >= 6 && id.allSatisfy { $0.isLetter || $0.isNumber }
    }

    // MARK: the agent's folder

    /// Where an agent works (Q5): its process's folder, or the folder its session record names when that
    /// record is newer than the process folder's last change. A record from before the agent started (a
    /// resumed chat's last run) never counts.
    public static func folder(process: String?, processSince: Date, record: RecordedFolder?, startedAt: Date) -> String? {
        guard let record, record.at >= startedAt else { return process }
        guard let process else { return record.folder }
        return record.at >= processSince ? record.folder : process
    }

    // MARK: session records (their tails only)

    /// The JSON lines in the last `bytes` of a file (the line cut at the start dropped), and when it was
    /// last written. Never the whole file: transcripts can be megabytes.
    static func tail(_ path: String, bytes: Int = 65536) -> (lines: [[String: Any]], modified: Date)? {
        guard isRegularFile(path), let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        var data = (try? handle.read(upToCount: bytes)) ?? Data()
        if start > 0, let newline = data.firstIndex(of: 0x0A) { data = data[(newline + 1)...] }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any]
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
        return (lines, modified)
    }

    /// Claude Code: the `cwd` of the transcript's last line that has one (its shell's folder after a `cd`),
    /// sub-agents' lines left out, with that line's time.
    static func claudeFolder(_ lines: [[String: Any]], modified: Date) -> RecordedFolder? {
        for line in lines.reversed() where line["isSidechain"] as? Bool != true {
            guard let cwd = line["cwd"] as? String, !cwd.isEmpty else { continue }
            let at = (line["timestamp"] as? String).flatMap(AgentSessions.parseDate) ?? modified
            return RecordedFolder(folder: cwd, at: at)
        }
        return nil
    }

    /// Codex: the folder of the last turn (`turn_context`), or of settings applied to the thread since
    /// (`/cd`), with that line's time.
    static func codexFolder(_ lines: [[String: Any]], modified: Date) -> RecordedFolder? {
        for line in lines.reversed() {
            let payload = line["payload"] as? [String: Any]
            var cwd: String?
            if line["type"] as? String == "turn_context" {
                cwd = payload?["cwd"] as? String
            } else if line["type"] as? String == "event_msg", payload?["type"] as? String == "thread_settings_applied" {
                cwd = (payload?["thread_settings"] as? [String: Any])?["cwd"] as? String
            }
            guard let cwd, !cwd.isEmpty else { continue }
            let at = (line["timestamp"] as? String).flatMap(AgentSessions.parseDate) ?? modified
            return RecordedFolder(folder: cwd, at: at)
        }
        return nil
    }

    /// The session the `claude` with process `pid` has open, and the folder it started in, from
    /// ~/.claude/sessions/<pid>.json.
    public static func claudeSession(pid: Int32, home: String) -> (id: String, started: String?)? {
        let record = (home as NSString).appendingPathComponent(".claude/sessions/\(pid).json")
        guard let data = AgentSessions.readHead(record, bytes: 16384),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = json["sessionId"] as? String, AgentStoreFiles.isPlainName(id) else { return nil }
        return (id, json["cwd"] as? String)
    }

    /// A Claude Code session's transcript: in the project folder named after the folder it started in, or,
    /// moved, in any project folder when `scanning` (a look through all of them: callers keep what it finds).
    public static func claudeTranscript(id: String, started: String?, home: String, scanning: Bool = true) -> String? {
        let projects = (home as NSString).appendingPathComponent(".claude/projects")
        if let started {
            let path = "\(projects)/\(AgentSessions.claudeFolderName(started))/\(id).jsonl"
            if isRegularFile(path) { return path }
        }
        guard scanning else { return nil }
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? []
        return folders.lazy.map { "\(projects)/\($0)/\(id).jsonl" }.first(where: isRegularFile)
    }

    /// The folder Claude Code's transcript at `path` names last.
    public static func claudeFolder(transcript path: String) -> RecordedFolder? {
        guard let (lines, modified) = tail(path) else { return nil }
        return claudeFolder(lines, modified: modified)
    }

    /// The folder the transcript of the `claude` with process `pid` names last.
    public static func claudeFolder(pid: Int32, home: String) -> RecordedFolder? {
        guard let session = claudeSession(pid: pid, home: home),
              let transcript = claudeTranscript(id: session.id, started: session.started, home: home) else { return nil }
        return claudeFolder(transcript: transcript)
    }

    /// The folder Codex's rollout at `path` (the one its process holds open) names last.
    public static func codexFolder(rollout path: String) -> RecordedFolder? {
        guard let (lines, modified) = tail(path) else { return nil }
        return codexFolder(lines, modified: modified)
    }

    /// Whether `path` is a Codex rollout under `home`: ~/.codex/sessions/…/rollout-….jsonl.
    public static func isCodexRollout(_ path: String, home: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return path.hasPrefix((home as NSString).appendingPathComponent(".codex/sessions") + "/") && name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
    }

    /// Copilot CLI: the `cwd` in workspace.yaml of the session the `copilot` with process `pid` has open
    /// (the folder holding its `inuse.<pid>.lock`), as of the file's last write.
    public static func copilotFolder(pid: Int32, home: String) -> RecordedFolder? {
        let base = (home as NSString).appendingPathComponent(".copilot/session-state")
        for (name, path) in AgentStoreFiles.written(in: base, since: nil) where AgentStoreFiles.isPlainName(name) {
            guard FileManager.default.fileExists(atPath: path + "/inuse.\(pid).lock") else { continue }
            let workspace = path + "/workspace.yaml"
            guard let text = AgentSessions.readHead(workspace, bytes: 65536).map({ String(decoding: $0, as: UTF8.self) }),
                  let cwd = CopilotSessions.flatYAML(text)["cwd"], !cwd.isEmpty else { return nil }
            return RecordedFolder(folder: cwd, at: AgentStoreFiles.modified(workspace) ?? .distantPast)
        }
        return nil
    }

    // MARK: who switched

    /// A command line that can move a checkout's HEAD: `git switch`, `checkout`, `rebase`, `merge`,
    /// `pull`, `reset`, `bisect`, `branch -m`/`-M`, `gh pr checkout` (or `gh co`). Run in a shell tab, it
    /// says that tab switched (R4).
    public static func movesHead(_ commandLine: String) -> Bool {
        CommandClassifier.segments(commandLine).contains { segment in
            let (name, args) = CommandClassifier.parse(segment)
            if name == "gh" {
                let words = args.filter { !$0.hasPrefix("-") }
                return words.first == "co" || (words.first == "pr" && words.dropFirst().first == "checkout")
            }
            return name == "git" && movesHead(arguments: args)
        }
    }

    /// The same for git's arguments, as Next Term runs them (`["switch", "main"]`).
    public static func movesHead(arguments args: [String]) -> Bool {
        // The subcommand is the first word after git's own options (`-C dir` and `-c key=value` take one).
        var index = 0
        while index < args.count, args[index].hasPrefix("-") {
            index += args[index] == "-C" || args[index] == "-c" ? 2 : 1
        }
        guard index < args.count else { return false }
        let rest = args[(index + 1)...]
        switch args[index] {
        case "switch", "checkout", "rebase", "merge", "pull", "reset", "bisect": return true
        case "branch": return rest.contains { $0 == "-m" || $0 == "-M" || $0 == "--move" }
        default: return false
        }
    }

    /// One entry of a HEAD reflog: where it moved from and to, and why ("commit: Fix it").
    public struct ReflogEntry: Equatable, Sendable {
        public let old: String
        public let new: String
        public let message: String
    }

    /// `logs/HEAD`'s lines: "<old> <new> <who> <when> <zone>\t<message>".
    static func parseReflog(_ text: String) -> [ReflogEntry] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            let fields = parts[0].split(separator: " ")
            guard fields.count >= 2 else { return nil }
            return ReflogEntry(old: String(fields[0]), new: String(fields[1]), message: parts.count > 1 ? String(parts[1]) : "")
        }
    }

    /// HEAD went from `old` to `new` by commits alone ("commit: …", "commit (amend): …"), as the reflog's
    /// last entries say.
    static func onlyCommits(from old: String, to new: String, in entries: [ReflogEntry]) -> Bool {
        var at = new
        for entry in entries.reversed() where entry.new == at {
            guard entry.message.hasPrefix("commit") else { return false }
            at = entry.old
            if at == old { return true }
        }
        return false
    }

    /// What a held HEAD change in a checkout is (R3a): commits made on a detached HEAD are no switch; a
    /// branch renamed in place (the old name gone, HEAD at the same commit) is a rename; anything else is
    /// a switch.
    static func change(from old: CheckoutHead, commit oldCommit: String?, to new: CheckoutHead, commit newCommit: String?,
                       reflog: [ReflogEntry], oldBranchExists: Bool) -> HeadChange {
        switch (old, new) {
        case let (.detached(a), .detached(b)):
            return a == b || onlyCommits(from: a, to: b, in: reflog) ? .none : .switched
        case let (.branch(a), .branch(b)):
            if a == b { return .none }
            let renamed = reflog.last?.message == "Branch: renamed refs/heads/\(a) to refs/heads/\(b)"
            return renamed || (!oldBranchExists && oldCommit != nil && oldCommit == newCommit) ? .renamed(from: a, to: b) : .switched
        default:
            return .switched
        }
    }

    /// The same, reading the checkout's reflog and asking git whether the old branch is still there.
    public static func change(in checkout: Checkout, from old: CheckoutHead, commit oldCommit: String?, git: String) -> HeadChange {
        var reflog: [ReflogEntry] = []
        if let dir = gitDir(ofCheckout: checkout.path), let handle = FileHandle(forReadingAtPath: dir + "/logs/HEAD") {
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 8192 ? size - 8192 : 0)
            reflog = parseReflog(String(decoding: (try? handle.read(upToCount: 8192)) ?? Data(), as: UTF8.self))
        }
        var exists = true
        if case let .branch(name) = old {
            let found = GitRunner.run(git, ["-C", checkout.path, "rev-parse", "--verify", "--quiet", "refs/heads/" + name], timeout: 10, acceptedStatus: [0, 1])
            exists = found.map { !$0.isEmpty } ?? true
        }
        return change(from: old, commit: oldCommit, to: checkout.head, commit: checkout.commit, reflog: reflog, oldBranchExists: exists)
    }
}

/// A value that changes only once a new one has held for `hold` seconds, and not while it is blocked (git
/// in the middle of something there). The first value counts at once, unless blocked.
public struct Held<Value: Equatable>: Equatable {
    public private(set) var value: Value?
    private var candidate: Value?
    /// When the candidate was first seen.
    private var firstSeen: Date?
    /// When it last started holding: its first sight, or the first sight after a git operation.
    private var holdingSince: Date?
    private var wasBlocked = false
    public let hold: TimeInterval

    public init(hold: TimeInterval = AgentLocation.hold) { self.hold = hold }

    public struct Change: Equatable {
        public let from: Value?
        public let to: Value
        /// When the new value was first seen.
        public let since: Date
    }

    /// Takes what was seen at `now`; returns the change once it counts.
    public mutating func see(_ seen: Value, at now: Date, blocked: Bool = false) -> Change? {
        if seen == value {
            candidate = nil
            wasBlocked = false
            return nil
        }
        if candidate != seen {
            candidate = seen
            firstSeen = now
            holdingSince = now
        }
        if blocked || wasBlocked { holdingSince = now }
        wasBlocked = blocked
        if blocked { return nil }
        guard value == nil || now.timeIntervalSince(holdingSince ?? now) >= hold else { return nil }
        let change = Change(from: value, to: seen, since: firstSeen ?? now)
        value = seen
        candidate = nil
        return change
    }
}
