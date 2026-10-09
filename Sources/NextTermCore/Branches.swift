import Foundation

// The branch popup's model: every branch with its upstream state and where it is checked out, the
// worktrees, recent branches, and what git is in the middle of. Read-only; one read is a handful of
// git calls (about 0.15 s on a 40,000-commit repository). Writes are GitOperation's job.
// Design: claudedocs/research_next-term-git-branches (sections 8.3, 8.8, 8.12, 8.13).

/// A local branch or a remote-tracking one.
public struct BranchRef: Equatable, Sendable {
    /// "feat/login"; a remote one keeps its remote: "origin/feat/login".
    public let name: String
    public let isRemote: Bool
    public let sha: String
    public let date: Date?
    /// The branch it tracks, short ("origin/feat/login").
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    /// It tracked a branch that was deleted on the remote.
    public let upstreamGone: Bool
    /// The branch checked out in the worktree that was read.
    public let isHead: Bool
    /// Where it is checked out, in any worktree.
    public let worktree: String?

    public init(name: String, isRemote: Bool, sha: String, date: Date? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0,
                upstreamGone: Bool = false, isHead: Bool = false, worktree: String? = nil) {
        self.name = name
        self.isRemote = isRemote
        self.sha = sha
        self.date = date
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.upstreamGone = upstreamGone
        self.isHead = isHead
        self.worktree = worktree
    }

    /// "origin" for a remote branch.
    public var remote: String? { isRemote ? name.split(separator: "/", maxSplits: 1).first.map(String.init) : nil }
    /// The name without its remote ("feat/login" for "origin/feat/login").
    public var shortName: String { isRemote ? String(name.split(separator: "/", maxSplits: 1).last ?? "") : name }
    public var shortSHA: String { String(sha.prefix(7)) }
    /// "refs/heads/feat/login", "refs/remotes/origin/feat/login": never mistaken for a tag or a file.
    public var fullName: String { (isRemote ? "refs/remotes/" : "refs/heads/") + name }
}

public struct Worktree: Equatable, Sendable {
    public let path: String
    public let head: String?
    /// The branch checked out there; nil when detached (or bare).
    public let branch: String?
    public let isBare: Bool
    /// Why it is locked ("" when locked without a reason); nil when not locked.
    public let lockReason: String?
    /// Its folder is gone; `git worktree prune` would remove the entry.
    public let isPrunable: Bool

    public init(path: String, head: String?, branch: String?, isBare: Bool = false, lockReason: String? = nil, isPrunable: Bool = false) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isBare = isBare
        self.lockReason = lockReason
        self.isPrunable = isPrunable
    }

    public var isDetached: Bool { branch == nil && !isBare }
}

/// What git is in the middle of in a worktree, read from the files it keeps while it waits for you.
public enum GitInProgress: Equatable, Sendable {
    case rebase(branch: String?, onto: String?, step: Int?, total: Int?)
    case merge
    case cherryPick
    case revert
    case bisect

    public var title: String {
        switch self {
        case let .rebase(branch, _, step, total):
            let progress = step.flatMap { s in total.map { " \(s)/\($0)" } } ?? ""
            return "Rebasing" + (branch.map { " \($0)" } ?? "") + progress
        case .merge: return "Merging"
        case .cherryPick: return "Cherry-picking"
        case .revert: return "Reverting"
        case .bisect: return "Bisecting"
        }
    }
}

public struct BranchModel: Equatable, Sendable {
    /// The worktree that was read (its top folder).
    public var root: String
    public var gitDir: String
    /// Shared by every worktree of the repository: refs live here.
    public var commonDir: String
    /// The branch checked out here; nil when HEAD is detached.
    public var current: String?
    public var headSHA: String?
    public var locals: [BranchRef] = []
    public var remotes: [BranchRef] = []
    /// Up to five branches this worktree was on lately, newest first (not the current one).
    public var recent: [String] = []
    public var worktrees: [Worktree] = []
    public var defaultBranch: String?
    /// Each remote's default branch, as its `<remote>/HEAD` names it ("origin": "main"). A clone records
    /// it for origin, and a fetch with git 2.48 or later for any remote; `git remote set-head` sets it.
    public var remoteHeads: [String: String] = [:]
    /// The remotes as `git remote` lists them: a remote's name may hold a "/" ("my/fork").
    public var configuredRemotes: [String] = []
    public var inProgress: GitInProgress?

    public init(root: String, gitDir: String, commonDir: String) {
        self.root = root
        self.gitDir = gitDir
        self.commonDir = commonDir
    }

    public var currentRef: BranchRef? { locals.first { $0.isHead } }
    public func local(_ name: String) -> BranchRef? { locals.first { $0.name == name } }
    public var remoteNames: [String] { Array(Set(remotes.compactMap(\.remote))).sorted() }

    /// A branch others build on, which force push never replaces: main, master, release/*, the default
    /// branch, and the default branch of the remote pushed to.
    public func isShared(_ branch: String, on remote: String) -> Bool {
        ["main", "master", defaultBranch, remoteHeads[remote]].contains(branch) || branch.hasPrefix("release/")
    }

    /// The worktree a branch is checked out in, if it is not this one.
    public func otherWorktree(of branch: BranchRef) -> String? {
        guard let path = branch.worktree, canonicalPath(path) != canonicalPath(root) else { return nil }
        return path
    }

    /// "origin/feat/x" as its remote and the branch there. The longest remote that fits wins ("my/fork"
    /// before "my"); without the list of remotes, the part before the first "/". Nil when no remote fits.
    public func remoteAndBranch(of name: String) -> (remote: String, branch: String)? {
        guard !configuredRemotes.isEmpty else {
            guard let slash = name.firstIndex(of: "/"), name.index(after: slash) < name.endIndex else { return nil }
            return (String(name[..<slash]), String(name[name.index(after: slash)...]))
        }
        let fitting = configuredRemotes.filter { name.hasPrefix($0 + "/") && name.count > $0.count + 1 }
        guard let remote = fitting.max(by: { $0.count < $1.count }) else { return nil }
        return (remote, String(name.dropFirst(remote.count + 1)))
    }

    /// The remote branch a local one tracks, while it is there: nil without an upstream, when it was
    /// deleted on the remote (gone), or when the upstream is another local branch ("feat/x" tracking a
    /// local "feat/x" is not remote "feat"'s "x", so the remotes must have been read).
    public func upstream(of ref: BranchRef) -> (remote: String, branch: String)? {
        guard !ref.isRemote, !ref.upstreamGone, let upstream = ref.upstream, !configuredRemotes.isEmpty else { return nil }
        return remoteAndBranch(of: upstream)
    }

    /// The worktree a folder is in: the longest worktree path that holds it, as worktrees nest
    /// (`<repo>/.claude/worktrees/x` is inside `<repo>`).
    public func worktree(containing folder: String) -> Worktree? {
        let folder = canonicalPath(folder)
        let holding = worktrees.filter { !$0.isBare }.map { ($0, canonicalPath($0.path)) }.filter { folder == $0.1 || folder.hasPrefix($0.1 + "/") }
        return holding.max { $0.1.count < $1.1.count }?.0
    }

    // MARK: reading

    /// Reads the model for the worktree containing `directory`, or nil outside a repository.
    public static func read(at directory: String, git: String, timeout: TimeInterval = 15) -> BranchModel? {
        let base = ["-C", directory, "--no-optional-locks"]
        guard let dirs = GitRunner.run(git, base + ["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir", "--show-toplevel"],
                                       timeout: timeout).map({ String(decoding: $0, as: UTF8.self).split(separator: "\n").map(String.init) }),
              dirs.count >= 3 else { return nil }
        var model = BranchModel(root: dirs[2], gitDir: dirs[0], commonDir: dirs[1])
        let format = "%(refname)%00%(objectname)%00%(committerdate:unix)%00%(upstream:short)%00%(upstream:track,nobracket)%00%(HEAD)%00%(worktreepath)%00%(symref)"
        if let refs = GitRunner.run(git, base + ["for-each-ref", "--format=" + format, "refs/heads", "refs/remotes"], timeout: timeout) {
            let all = parseRefs(refs)
            model.locals = all.filter { !$0.isRemote }
            model.remotes = all.filter(\.isRemote)
            model.remoteHeads = parseRemoteHeads(refs)
        }
        model.current = model.currentRef?.name
        model.headSHA = GitRunner.run(git, base + ["rev-parse", "--verify", "--quiet", "HEAD"], timeout: timeout)
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        if let log = GitRunner.run(git, base + ["reflog", "show", "--format=%gs", "-n", "300", "HEAD"], timeout: timeout, acceptedStatus: [0, 128]) {
            model.recent = parseRecent(String(decoding: log, as: UTF8.self), current: model.current, existing: Set(model.locals.map(\.name)))
        }
        if let list = GitRunner.run(git, base + ["worktree", "list", "--porcelain", "-z"], timeout: timeout) {
            model.worktrees = parseWorktrees(list)
        }
        if let remotes = GitRunner.run(git, base + ["remote"], timeout: timeout) {
            model.configuredRemotes = String(decoding: remotes, as: UTF8.self).split(separator: "\n").map(String.init)
        }
        let originHead = GitRunner.run(git, base + ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], timeout: timeout, acceptedStatus: [0, 1])
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        model.defaultBranch = defaultBranch(originHead: originHead, locals: Set(model.locals.map(\.name)))
        model.inProgress = inProgress(gitDir: model.gitDir)
        return model
    }

    /// `for-each-ref` records, one per line, fields separated by NUL.
    public static func parseRefs(_ data: Data) -> [BranchRef] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 8, f[7].isEmpty else { return nil } // a symref: origin/HEAD
            let isRemote: Bool
            let name: String
            if f[0].hasPrefix("refs/heads/") {
                isRemote = false
                name = String(f[0].dropFirst("refs/heads/".count))
            } else if f[0].hasPrefix("refs/remotes/") {
                isRemote = true
                name = String(f[0].dropFirst("refs/remotes/".count))
            } else {
                return nil
            }
            var ahead = 0, behind = 0
            for part in f[4].split(separator: ",") {
                let words = part.split(separator: " ")
                guard words.count == 2, let n = Int(words[1]) else { continue }
                if words[0] == "ahead" { ahead = n } else if words[0] == "behind" { behind = n }
            }
            return BranchRef(name: name, isRemote: isRemote, sha: f[1], date: Double(f[2]).map(Date.init(timeIntervalSince1970:)),
                             upstream: f[3].isEmpty ? nil : f[3], ahead: ahead, behind: behind, upstreamGone: f[4] == "gone",
                             isHead: f[5] == "*", worktree: f[6].isEmpty ? nil : f[6])
        }
    }

    /// The `<remote>/HEAD` symrefs among the same records: each remote's default branch, by remote.
    public static func parseRemoteHeads(_ data: Data) -> [String: String] {
        var heads: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 8, f[0].hasPrefix("refs/remotes/"), f[0].hasSuffix("/HEAD") else { continue }
            let prefix = String(f[0].dropLast("HEAD".count)) // refs/remotes/origin/
            guard f[7].hasPrefix(prefix), f[7].count > prefix.count else { continue }
            heads[String(prefix.dropFirst("refs/remotes/".count).dropLast())] = String(f[7].dropFirst(prefix.count))
        }
        return heads
    }

    /// The branches HEAD moved to lately ("checkout: moving from A to B"), newest first: switches made in
    /// a terminal or by an agent count too.
    public static func parseRecent(_ reflog: String, current: String?, existing: Set<String>, limit: Int = 5) -> [String] {
        var seen = Set<String>()
        var recent: [String] = []
        for line in reflog.split(separator: "\n") {
            guard line.hasPrefix("checkout: moving from "), let to = line.range(of: " to ", options: .backwards) else { continue }
            let name = String(line[to.upperBound...])
            guard name != current, existing.contains(name), seen.insert(name).inserted else { continue }
            recent.append(name)
            if recent.count == limit { break }
        }
        return recent
    }

    /// `git worktree list --porcelain -z`: attribute lines ending in NUL, a worktree ending in an empty one.
    public static func parseWorktrees(_ data: Data) -> [Worktree] {
        var result: [Worktree] = []
        var path: String?, head: String?, branch: String?, bare = false, lock: String?, prunable = false
        func flush() {
            if let path { result.append(Worktree(path: path, head: head, branch: branch, isBare: bare, lockReason: lock, isPrunable: prunable)) }
            path = nil; head = nil; branch = nil; bare = false; lock = nil; prunable = false
        }
        for field in data.split(separator: 0, omittingEmptySubsequences: false).map({ String(decoding: $0, as: UTF8.self) }) {
            if field.isEmpty { flush(); continue }
            let (key, value) = field.firstIndex(of: " ").map { (String(field[..<$0]), String(field[field.index(after: $0)...])) } ?? (field, "")
            switch key {
            case "worktree": flush(); path = value
            case "HEAD": head = value
            case "branch": branch = value.hasPrefix("refs/heads/") ? String(value.dropFirst("refs/heads/".count)) : value
            case "bare": bare = true
            case "locked": lock = value
            case "prunable": prunable = true
            default: break
            }
        }
        flush()
        return result
    }

    /// origin's HEAD ("origin/main" → "main"), else an existing main, else master.
    public static func defaultBranch(originHead: String?, locals: Set<String>) -> String? {
        if let originHead, let slash = originHead.firstIndex(of: "/") { return String(originHead[originHead.index(after: slash)...]) }
        return ["main", "master"].first(where: locals.contains)
    }

    /// What the files git keeps while it waits say is in progress.
    public static func inProgress(gitDir: String) -> GitInProgress? {
        let fm = FileManager.default
        func read(_ name: String) -> String? {
            (try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent(name), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func branch(_ headName: String?) -> String? {
            headName.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : $0 }
        }
        if fm.fileExists(atPath: (gitDir as NSString).appendingPathComponent("rebase-merge")) {
            return .rebase(branch: branch(read("rebase-merge/head-name")), onto: read("rebase-merge/onto"),
                           step: read("rebase-merge/msgnum").flatMap(Int.init), total: read("rebase-merge/end").flatMap(Int.init))
        }
        if fm.fileExists(atPath: (gitDir as NSString).appendingPathComponent("rebase-apply")) {
            return .rebase(branch: branch(read("rebase-apply/head-name")), onto: nil,
                           step: read("rebase-apply/next").flatMap(Int.init), total: read("rebase-apply/last").flatMap(Int.init))
        }
        if read("MERGE_HEAD") != nil { return .merge }
        if read("CHERRY_PICK_HEAD") != nil { return .cherryPick }
        if read("REVERT_HEAD") != nil { return .revert }
        if read("BISECT_LOG") != nil { return .bisect }
        return nil
    }

    /// The files staged for the next commit (paths from the work tree's root).
    public static func stagedFiles(at root: String, git: String) -> [String] {
        guard let data = GitRunner.run(git, ["-C", root, "--no-optional-locks", "diff", "--cached", "--name-only", "-z"], timeout: 10) else { return [] }
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Whether some remote branch already has `commit` (then undoing it would rewrite history others may
    /// have).
    public static func isPublished(_ commit: String, at root: String, git: String) -> Bool {
        guard let data = GitRunner.run(git, ["-C", root, "--no-optional-locks", "for-each-ref", "--count=1", "--contains", commit, "refs/remotes"],
                                       timeout: 10) else { return true }
        return !data.isEmpty
    }

    /// HEAD's commit and the one HEAD was at before it, from HEAD's reflog: right after a commit that is
    /// its parent, and after an amend the commit it replaced. Nil without an earlier entry (a first commit).
    public static func headAndPrevious(at root: String, git: String) -> (head: String, previous: String)? {
        guard let data = GitRunner.run(git, ["-C", root, "--no-optional-locks", "rev-parse", "HEAD", "HEAD@{1}"], timeout: 10) else { return nil }
        let shas = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        guard shas.count == 2 else { return nil }
        return (shas[0], shas[1])
    }

    // MARK: grouping

    /// Branch names and worktree folders that agents make: shown together under "Agent branches".
    public static let agentPrefixes = ["worktree-", "claude/", "codex/", "cursor/", "copilot/", "opencode/", "vk/"]
    public static let agentWorktreeRoots = ["/.claude/worktrees/", "/.gemini/worktrees/", "/.codex/worktrees/", "/.cursor/worktrees/",
                                            ".worktrees/", "/.local/share/opencode/worktree/", "/conductor/workspaces/"]

    public static func isAgentBranch(_ name: String, worktree: String?) -> Bool {
        if agentPrefixes.contains(where: name.hasPrefix) { return true }
        guard let worktree else { return false }
        return agentWorktreeRoots.contains { worktree.contains($0) }
    }

    /// The folder a branch sits in ("feat" for "feat/login"), nil at the top level.
    public static func folder(of name: String) -> String? {
        name.firstIndex(of: "/").map { String(name[..<$0]) }
    }
}

/// Branch names as git accepts them (`git check-ref-format` on refs/heads/<name>), and a name made from
/// whatever was typed.
public enum BranchName {
    /// Why `name` can't be a new branch, or nil if it can.
    public static func problem(_ name: String, existing: Set<String> = []) -> String? {
        if name.isEmpty { return "A branch needs a name." }
        if existing.contains(name) { return "“\(name)” already exists." }
        if name == "HEAD" || name == "@" { return "“\(name)” is reserved." }
        if name.hasPrefix("-") { return "A branch name can’t start with “-”." }
        if name.hasSuffix("/") || name.hasPrefix("/") || name.contains("//") { return "Slashes separate folders: none at either end, and no two in a row." }
        if name.hasSuffix(".") { return "A branch name can’t end with “.”." }
        if name.contains("..") || name.contains("@{") { return "A branch name can’t contain “..” or “@{”." }
        if let bad = name.first(where: { $0.isWhitespace || "~^:?*[\\".contains($0) || $0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F } }) {
            return bad.isWhitespace ? "A branch name can’t contain spaces." : "A branch name can’t contain “\(bad)”."
        }
        for component in name.split(separator: "/") {
            if component.hasPrefix(".") { return "No part of a branch name can start with “.”." }
            if component.hasSuffix(".lock") { return "No part of a branch name can end with “.lock”." }
        }
        if existing.contains(where: { $0.hasPrefix(name + "/") || name.hasPrefix($0 + "/") }) {
            return "“\(name)” would clash with an existing branch folder."
        }
        return nil
    }

    /// "Fix the login bug" → "fix-the-login-bug": spaces become "-", characters git refuses go.
    public static func suggest(from text: String) -> String {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
            .filter { !"~^:?*[\\".contains($0) && !$0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F } }
        while name.contains("..") { name = name.replacingOccurrences(of: "..", with: ".") }
        while name.contains("//") { name = name.replacingOccurrences(of: "//", with: "/") }
        name = name.replacingOccurrences(of: "@{", with: "@")
        while let first = name.first, first == "-" || first == "/" || first == "." { name.removeFirst() }
        while let last = name.last, last == "/" || last == "." { name.removeLast() }
        return name
    }
}

/// What went wrong, from git's own words (stable English: writes run with LANGUAGE=en).
public enum GitFailure: Equatable, Sendable {
    case lockHeld(path: String?)
    /// Changes git would overwrite; the files it named.
    case localChanges(files: [String])
    case heldByWorktree(path: String?)
    /// `git worktree add` into a folder that is there and not empty.
    case pathExists(path: String?)
    case notFullyMerged
    case tagNotBranch
    case pushRejected
    case leaseFailed
    case diverged
    case conflicts
    case authentication
    case hostKey
    case signing
    case hookFailed
    case network
    case nothingToDo
}

public enum GitOutput {
    /// The first matching class, most specific first; nil when the output says nothing known.
    public static func classify(_ output: String) -> GitFailure? {
        func has(_ text: String) -> Bool { output.localizedCaseInsensitiveContains(text) }
        if has("index.lock': File exists") || has("cannot lock ref") {
            let path = output.range(of: #"'[^']*\.lock'"#, options: .regularExpression).map { String(output[$0].dropFirst().dropLast()) }
            return .lockHeld(path: path)
        }
        if has("would be overwritten by") || has("untracked working tree files would be overwritten") {
            // The files are listed one per line, indented with a tab, after the message.
            let files = output.split(separator: "\n").filter { $0.hasPrefix("\t") }.map { $0.trimmingCharacters(in: .whitespaces) }
            return .localChanges(files: files)
        }
        if has("is already used by worktree at") || has("is already checked out at") || has("used by worktree at")
            || has("refusing to fetch into branch") {
            let path = output.range(of: #"(worktree at|checked out at) '[^']*'"#, options: .regularExpression)
                .map { String(output[$0]).components(separatedBy: "'").dropFirst().first ?? "" }
            return .heldByWorktree(path: path)
        }
        if let match = output.range(of: #"fatal: '[^']+' already exists"#, options: .regularExpression) {
            let quoted = output[match].components(separatedBy: "'")
            return .pathExists(path: quoted.count > 1 ? quoted[1] : nil)
        }
        if has("is not fully merged") { return .notFullyMerged }
        if has("a branch is expected, got tag") { return .tagNotBranch }
        if has("(stale info)") || has("remote ref updated since checkout") { return .leaseFailed }
        if has("[rejected]") || has("\t[rejected]") || (has("rejected") && (has("(fetch first)") || has("(non-fast-forward)"))) { return .pushRejected }
        if has("Not possible to fast-forward") || has("Need to specify how to reconcile divergent branches") { return .diverged }
        if has("CONFLICT (") || has("Could not apply") || has("Applying autostash resulted in conflicts") || has("fix conflicts") { return .conflicts }
        if has("Host key verification failed") || has("REMOTE HOST IDENTIFICATION HAS CHANGED") { return .hostKey }
        if has("Permission denied (publickey") || has("Authentication failed") || has("could not read Username") || has("could not read Password")
            || has("terminal prompts disabled") || has("unable to read askpass response") || has("Device not configured") {
            return .authentication
        }
        if has("gpg failed to sign") || has("Inappropriate ioctl for device") || has("cannot run gpg") { return .signing }
        if (has("hook") && has("failed")) || has("husky - ") || has("command not found") || has("env: node:") || has("git-lfs was not found") {
            return .hookFailed
        }
        if has("Could not resolve host") || has("Connection timed out") || has("unable to access") || has("Could not read from remote repository") {
            return .network
        }
        if has("nothing to commit") || has("Already up to date") || has("Everything up-to-date") { return .nothingToDo }
        return nil
    }
}
