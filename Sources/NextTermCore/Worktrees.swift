import Foundation

// Open in New Worktree: a branch, tag or commit checked out in a folder of its own, so the checkout an
// agent works in is never touched. Where the folder goes and what it is called, the `git worktree add`
// that makes it, the ignored files `.worktreeinclude` copies into it, the window it opens in, the agent
// guard's words, and why Remove Worktree… refuses. Plan: claudedocs/2026-10-09-worktree-from-switch-guard-plan.md.

/// What a new worktree checks out.
public enum WorktreeTarget: Equatable, Sendable {
    /// A local branch.
    case branch(String)
    /// A remote branch, split by BranchModel.remoteAndBranch (a remote's name may hold a "/", so never
    /// BranchRef.shortName). With `localExists` the local branch of that name is used, as Checkout does;
    /// else it is made, tracking the remote one.
    case remoteBranch(remote: String, branch: String, localExists: Bool)
    /// A tag or a commit, detached: `revision` as git reads it (refs/tags/v2.9.0, a sha), `shown` as people do.
    case revision(String, shown: String)
    /// A new branch from `base` (nil: HEAD). `noTrack` as New Branch has it: a remote base under another name.
    case newBranch(String, base: String?, noTrack: Bool)

    /// What the sheet's title names: "fix/7027-sso", "origin/rakib/new-panel", "v2.9.0".
    public var shown: String {
        switch self {
        case let .branch(name): return name
        case let .remoteBranch(remote, branch, _): return remote + "/" + branch
        case let .revision(_, shown): return shown
        case let .newBranch(name, _, _): return name
        }
    }

    /// The branch the worktree is on; nil when it is detached.
    public var branchName: String? {
        switch self {
        case let .branch(name): return name
        case let .remoteBranch(_, branch, _): return branch
        case .revision: return nil
        case let .newBranch(name, _, _): return name
        }
    }

    /// The short part of the folder's name: a branch's last segment (`fix/7027-sso` gives `7027-sso`), a tag's
    /// own name, a commit's short sha.
    public var shortName: String {
        switch self {
        case let .branch(name), let .newBranch(name, _, _): return Self.lastSegment(name)
        case let .remoteBranch(_, branch, _): return Self.lastSegment(branch)
        case let .revision(_, shown):
            let isSHA = shown.count >= 8 && shown.count <= 64 && shown.allSatisfy(\.isHexDigit)
            return isSHA ? String(shown.prefix(7)) : shown.replacingOccurrences(of: "/", with: "-")
        }
    }

    private static func lastSegment(_ name: String) -> String {
        name.split(separator: "/").last.map(String.init) ?? name
    }

    /// `git worktree add`'s arguments for a folder at `path` (absolute, so never read as an option).
    public func addArguments(path: String) -> [String] {
        switch self {
        case let .branch(name):
            return ["worktree", "add", path, name]
        case let .remoteBranch(remote, branch, localExists):
            if localExists { return ["worktree", "add", path, branch] }
            return ["worktree", "add", "--track", "-b", branch, path, remote + "/" + branch]
        case let .revision(revision, _):
            return ["worktree", "add", "--detach", path, revision]
        case let .newBranch(name, base, noTrack):
            return ["worktree", "add"] + (noTrack ? ["--no-track"] : []) + ["-b", name, path, base ?? "HEAD"]
        }
    }
}

/// Where new worktrees go (Settings › Editor › Git): beside the repository, `~/Code/xCloud-wt-<name>`, or
/// inside it under `.claude/worktrees/<name>`, which is used only for a repository that ignores that folder.
public enum WorktreeLocation: String, CaseIterable, Sendable {
    case beside
    case claudeWorktrees
}

public enum WorktreeFolder {
    /// The folder new worktrees go in, and what their names start with.
    public struct Place: Equatable, Sendable {
        public let folder: String
        public let prefix: String

        public init(folder: String, prefix: String) {
            self.folder = folder
            self.prefix = prefix
        }
    }

    /// The repository's main checkout, from its common git folder: the folder that holds `.git`; a bare
    /// repository's own folder.
    public static func mainCheckout(commonDir: String) -> String {
        let common = (commonDir as NSString).standardizingPath
        return (common as NSString).lastPathComponent == ".git" ? (common as NSString).deletingLastPathComponent : common
    }

    /// "xCloud" for ~/Code/xCloud, "app" for a bare ~/Code/app.git.
    public static func repositoryName(mainCheckout: String) -> String {
        let name = (mainCheckout as NSString).lastPathComponent
        return name.hasSuffix(".git") && name.count > 4 ? String(name.dropLast(4)) : name
    }

    /// Beside the main checkout (never beside a linked worktree the window shows), named `<repo>-wt-<name>`;
    /// inside it under `.claude/worktrees` when Settings asks and the repository ignores that folder.
    public static func place(mainCheckout: String, location: WorktreeLocation, claudeWorktreesIgnored: Bool) -> Place {
        let bare = (mainCheckout as NSString).lastPathComponent.hasSuffix(".git")
        if location == .claudeWorktrees, claudeWorktreesIgnored, !bare {
            return Place(folder: mainCheckout + "/.claude/worktrees", prefix: "")
        }
        return Place(folder: (mainCheckout as NSString).deletingLastPathComponent, prefix: repositoryName(mainCheckout: mainCheckout) + "-wt-")
    }

    /// Whether the repository ignores `.claude/worktrees/` (its .gitignore, info/exclude or your global
    /// ignore file). Only reads; Next Term never edits an ignore file.
    public static func ignoresClaudeWorktrees(mainCheckout: String, git: String) -> Bool {
        GitRunner.run(git, ["-C", mainCheckout, "check-ignore", "-q", "--no-index", ".claude/worktrees/next-term-probe"], timeout: 10) != nil
    }

    /// The name the sheet starts with: `prefix` and the short part, then -2, -3… while that is taken.
    public static func suggestedName(prefix: String, short: String, isTaken: (String) -> Bool) -> String {
        var part = normalized(short)
        while let first = part.first, first == "." || first == "-" { part.removeFirst() }
        if part.isEmpty { part = "worktree" }
        let base = prefix + part
        guard isTaken(base) else { return base }
        var number = 2
        while isTaken("\(base)-\(number)") { number += 1 }
        return "\(base)-\(number)"
    }

    /// A "/" typed by habit becomes "-", as it is typed.
    public static func normalized(_ typed: String) -> String {
        typed.replacingOccurrences(of: "/", with: "-")
    }

    /// The name as it is used: spaces at either end go.
    public static func finalName(_ typed: String) -> String {
        normalized(typed).trimmingCharacters(in: .whitespaces)
    }

    /// Why `name` can't be the new folder in `folder`, shown under the field with Create off; nil when it can.
    /// `isTaken`: something is there (a folder, a file or a link); `isRegistered`: git lists a worktree there.
    public static func problem(_ name: String, in folder: String, isTaken: (String) -> Bool, isRegistered: (String) -> Bool,
                               home: String = NSHomeDirectory()) -> String? {
        let name = finalName(name)
        if name.isEmpty { return "The folder needs a name." }
        if name.hasPrefix(".") { return "A folder name can’t start with “.”." }
        if name.hasPrefix("-") { return "A folder name can’t start with “-”." }
        if let bad = name.first(where: { $0 == ":" || $0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F } }) {
            return bad == ":" ? "A folder name can’t contain “:”." : "A folder name can’t contain control characters."
        }
        if name.utf8.count > 255 || (folder + "/" + name).utf8.count >= 1024 { return "That name is too long for a folder." }
        if isRegistered(name) { return "Git still lists a worktree there whose folder is gone: choose Remove Worktree… on its row first." }
        if isTaken(name) { return "Already exists in " + RecentProjects.abbreviate(folder, home: home) }
        return nil
    }

    /// Makes the new worktree's folder, empty, before git runs (git takes an empty folder), so a folder that
    /// appeared since the sheet checked its name is never taken for the new worktree: git would fail on it
    /// after making the branch. The reason it can't, or nil once it is made.
    public static func claim(_ path: String, home: String = NSHomeDirectory()) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        guard mkdir(path, 0o755) != 0 else { return nil }
        let code = errno
        if code == EEXIST { return "Already exists in " + RecentProjects.abbreviate(parent, home: home) }
        return "Can’t make the folder: " + String(cString: strerror(code)) + "."
    }

    /// Removes a claimed folder git didn't make a worktree in: only while it is empty.
    public static func release(_ path: String) {
        rmdir(path)
    }

    /// Something is at `path`: a folder, a file, or a link (a broken one too).
    public static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    public static func sheetTitle(_ target: WorktreeTarget) -> String {
        "Open \(target.shown) in a New Worktree"
    }

    /// The sheet's footnote: the checkout and its changes stay; what the new folder gets.
    public static func sheetInfo(checkout: String, includes: Bool) -> String {
        let stays = "\(checkout) and its changes stay as they are. "
        if includes { return stays + "The new folder gets committed files, and copies of the ignored files .worktreeinclude lists." }
        return stays + "The new folder gets committed files only: no .env, vendor/ or node_modules/. List files in .worktreeinclude to copy them."
    }

    /// The full path under the field: "~/Code/xCloud-wt-7027-sso".
    public static func pathLine(folder: String, name: String, home: String = NSHomeDirectory()) -> String {
        RecentProjects.abbreviate(folder + "/" + finalName(name), home: home)
    }
}

/// A worktree's own window (D9): titled "xCloud ▸ 7027-sso", kept out of Recent Projects.
public enum WorktreeWindow {
    public struct Repository: Equatable, Sendable {
        public let name: String
        public let mainCheckout: String

        public init(name: String, mainCheckout: String) {
            self.name = name
            self.mainCheckout = mainCheckout
        }
    }

    /// "xCloud ▸ 7027-sso": the repository's name and the folder's, without the "<repo>-wt-" it starts with
    /// (in any case: his own folders are xcloud-wt-aichat).
    public static func title(repository: String, folder: String) -> String {
        let prefix = repository + "-wt-"
        let short = folder.count > prefix.count && folder.lowercased().hasPrefix(prefix.lowercased()) ? String(folder.dropFirst(prefix.count)) : folder
        return repository + " ▸ " + short
    }

    /// The repository of the linked worktree whose top folder is `path`; nil for a main checkout or a folder
    /// outside a repository. Reads `.git` and git's own files, no git run.
    public static func repository(ofLinkedWorktree path: String) -> Repository? {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path + "/.git", isDirectory: &isFolder), !isFolder.boolValue,
              let common = GitRunner.commonGitDir(root: path) else { return nil }
        let main = WorktreeFolder.mainCheckout(commonDir: common)
        guard canonicalPath(main) != canonicalPath(path), FileManager.default.fileExists(atPath: common + "/worktrees") else { return nil }
        return Repository(name: WorktreeFolder.repositoryName(mainCheckout: main), mainCheckout: canonicalPath(main))
    }
}

/// The question asked before changing the files under a working agent, for every caller: its title, the
/// line that names the agents and what would change, and the buttons. Only a switch offers a new worktree:
/// Update, Merge, Rebase and Continue act on the branch the agent has checked out, which git can't check
/// out a second time.
public enum AgentGuard {
    public struct Agent: Equatable, Sendable {
        /// The program as the tab runs it ("claude"); named with AgentName.
        public let program: String
        public let tab: String

        public init(program: String, tab: String) {
            self.program = program
            self.tab = tab
        }

        public var name: String { program.isEmpty ? "An agent" : AgentName.of(program: program) }
    }

    public enum Action: Equatable, Sendable {
        /// Checkout, Checkout and Update, a tag or revision, New Branch switching to it: to `target` when known.
        case switching(to: String?)
        case updating, merging, rebasing, continuing, skipping, aborting
    }

    public static let openInNewWorktree = "Open in New Worktree…"

    public static func title(_ agents: [Agent]) -> String {
        agents.count > 1 ? "\(agents.count) agents are working in this folder" : "\(agents.first?.name ?? "An agent") is working in this folder"
    }

    /// "In the tab “✳ Fix it”. Switching to fix/7027-sso changes the files under it."; with several, each
    /// agent and its tab.
    public static func info(_ agents: [Agent], _ action: Action) -> String {
        let doing = phrase(action)
        guard agents.count > 1 else { return "In the tab “\(agents.first?.tab ?? "")”. \(doing) changes the files under it." }
        let each = agents.map { "\($0.name) in “\(shortened($0.tab))”" }
        let list = each.dropLast().joined(separator: ", ") + " and " + (each.last ?? "")
        return "\(list). \(doing) changes the files under them."
    }

    public static func anyway(_ action: Action) -> String {
        switch action {
        case .switching: return "Switch Anyway"
        case .updating: return "Update Anyway"
        case .merging: return "Merge Anyway"
        case .rebasing: return "Rebase Anyway"
        case .continuing: return "Continue Anyway"
        case .skipping: return "Skip Anyway"
        case .aborting: return "Abort Anyway"
        }
    }

    /// The safe way first (Return), then the risky one, then Cancel (Esc).
    public static func buttons(_ action: Action, worktree: Bool) -> [String] {
        if case .switching = action, worktree { return [openInNewWorktree, anyway(action), "Cancel"] }
        return [anyway(action), "Cancel"]
    }

    private static func phrase(_ action: Action) -> String {
        switch action {
        case let .switching(target): return target.map { "Switching to \($0)" } ?? "Switching branches"
        case .updating: return "Updating"
        case .merging: return "Merging"
        case .rebasing: return "Rebasing"
        case .continuing: return "Continuing"
        case .skipping: return "Skipping"
        case .aborting: return "Aborting"
        }
    }

    /// A tab's title in a list of several: cut at a word, with an ellipsis.
    static func shortened(_ title: String, to limit: Int = 24) -> String {
        guard title.count > limit else { return title }
        var cut = String(title.prefix(limit - 1))
        if let space = cut.lastIndex(of: " "), cut.distance(from: space, to: cut.endIndex) <= 10 { cut = String(cut[..<space]) }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// `.worktreeinclude` (as Claude Code reads it): gitignore patterns for the ignored files a new worktree gets
/// copies of. A file is copied only when the repository ignores it too, only from inside the checkout,
/// never through a link, and never over a file that is there. Nothing else is copied and no script runs.
public enum WorktreeInclude {
    public static let fileName = ".worktreeinclude"

    public static func exists(in root: String) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: root + "/" + fileName, isDirectory: &isFolder) && !isFolder.boolValue
    }

    /// The paths to copy: listed by the file's patterns, ignored by the repository, and inside the checkout.
    public static func select(listed: [String], ignored: Set<String>) -> [String] {
        listed.filter { ignored.contains($0) && isInside($0) }
    }

    /// A path relative to the checkout that stays in it: no "..", ".", empty or absolute part, never in .git.
    static func isInside(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." } && parts.first != ".git"
    }

    /// The untracked files the checkout's `.worktreeinclude` matches that the repository ignores, sorted.
    /// Two reads with git: the files the patterns match, then which of them are ignored.
    public static func files(in root: String, git: String) -> [String] {
        guard exists(in: root) else { return [] }
        guard let listed = GitRunner.run(git, ["-C", root, "ls-files", "-z", "--others", "--ignored", "--exclude-from=" + root + "/" + fileName],
                                         timeout: 60) else { return [] }
        let paths = split(listed)
        guard !paths.isEmpty else { return [] }
        let input = Data(paths.joined(separator: "\0").utf8) + Data([0])
        let ignored = GitRunner.run(git, ["-C", root, "check-ignore", "-z", "--stdin"], timeout: 60, acceptedStatus: [0, 1], input: input).map(split) ?? []
        return select(listed: paths, ignored: Set(ignored)).sorted()
    }

    private static func split(_ data: Data) -> [String] {
        data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Copies each path from `source` to the same place under `destination`. Regular files only; a link on
    /// either side (the file, or a folder on its way) is skipped, so nothing is read or written outside the
    /// two checkouts; a file already at the destination is kept.
    public static func copy(_ paths: [String], from source: String, to destination: String) -> (copied: [String], skipped: [String]) {
        var copied: [String] = [], skipped: [String] = []
        for path in paths {
            if copyOne(path, from: source, to: destination) { copied.append(path) } else { skipped.append(path) }
        }
        return (copied, skipped)
    }

    private static func copyOne(_ path: String, from source: String, to destination: String) -> Bool {
        guard isInside(path) else { return false }
        let parts = path.split(separator: "/").map(String.init)
        // The source: real folders on the way, and a regular file.
        var from = source
        for part in parts.dropLast() {
            from += "/" + part
            guard kind(of: from) == S_IFDIR else { return false }
        }
        from += "/" + parts[parts.count - 1]
        guard kind(of: from) == S_IFREG else { return false }
        // The destination: real folders on the way (made when missing), and nothing at the file's place.
        var to = destination
        for part in parts.dropLast() {
            to += "/" + part
            switch kind(of: to) {
            case .some(S_IFDIR): continue
            case nil: guard mkdir(to, 0o755) == 0 else { return false }
            default: return false
            }
        }
        to += "/" + parts[parts.count - 1]
        guard kind(of: to) == nil else { return false }
        return (try? FileManager.default.copyItem(atPath: from, toPath: to)) != nil
    }

    /// The type bits of what is at `path`, without following a link; nil when nothing is there.
    private static func kind(of path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }
}

/// Remove Worktree… (D14): `git worktree remove <path>`, never forced, so the branch stays and so do changes.
/// It is refused, with the reason, while anything is in it; a folder deleted by hand is forgotten instead.
public enum WorktreeRemoval {
    public struct Facts: Equatable, Sendable {
        public var isMain = false
        /// Its folder is gone ("missing" in the popup).
        public var isMissing = false
        /// Live agents working in it.
        public var agents: [AgentGuard.Agent] = []
        /// Windows open on it, by title.
        public var windows: [String] = []
        /// Windows with a tab in it, by title.
        public var tabWindows: [String] = []
        /// nil when it isn't locked.
        public var lockReason: String?
        public var holder: LockHolder?
        public var holderAlive = false
        /// Changed and untracked files, as `git status` counts them.
        public var changedFiles = 0

        public init(isMain: Bool = false, isMissing: Bool = false, agents: [AgentGuard.Agent] = [], windows: [String] = [], tabWindows: [String] = [],
                    lockReason: String? = nil, holder: LockHolder? = nil, holderAlive: Bool = false, changedFiles: Int = 0) {
            self.isMain = isMain
            self.isMissing = isMissing
            self.agents = agents
            self.windows = windows
            self.tabWindows = tabWindows
            self.lockReason = lockReason
            self.holder = holder
            self.holderAlive = holderAlive
            self.changedFiles = changedFiles
        }
    }

    public enum Verdict: Equatable, Sendable {
        case remove
        /// Its folder is gone: forget git's entry for it (`worktree remove` of that one only).
        case forget
        /// Not now, and why; `goTo`: a window or tab is in it, to bring forward.
        case refuse(String, goTo: Bool)
        /// Locked, by nothing that still runs: it can be unlocked first.
        case unlockFirst(String)
    }

    /// The first reason that holds, in this order: main checkout, a lock on a missing folder, agents, windows,
    /// tabs, a lock, changes.
    public static func verdict(_ facts: Facts) -> Verdict {
        if facts.isMain { return .refuse("It is the repository’s main checkout.", goTo: false) }
        if facts.isMissing, facts.lockReason == nil { return .forget }
        if let agent = facts.agents.first { return .refuse("\(agent.name) is working in it, in the tab “\(agent.tab)”.", goTo: true) }
        if let window = facts.windows.first { return .refuse("The window “\(window)” is open on it.", goTo: true) }
        if let window = facts.tabWindows.first { return .refuse("A tab in “\(window)” is in it.", goTo: true) }
        if let reason = facts.lockReason {
            if let holder = facts.holder {
                let who = "\(AgentName.of(program: holder.program)) (pid \(holder.pid))"
                return facts.holderAlive ? .refuse("\(who) holds it.", goTo: false) : .unlockFirst("It is locked by \(who), which has ended.")
            }
            return .unlockFirst(reason.isEmpty ? "It is locked, with no reason given." : "It is locked: \(reason).")
        }
        if facts.changedFiles > 0 { return .refuse("It has \(facts.changedFiles) changed file\(facts.changedFiles == 1 ? "" : "s").", goTo: false) }
        return .remove
    }

    /// Never --force: git refuses a worktree with changes, and the branch stays.
    public static func arguments(path: String) -> [String] {
        ["worktree", "remove", path]
    }

    /// The changed and untracked files in the worktree at `path` (git status's count); nil when git can't say.
    public static func changedFiles(at path: String, git: String) -> Int? {
        GitRunner.run(git, ["-C", path, "status", "--porcelain", "-z", "--untracked-files=normal"], timeout: 30).map(countStatus)
    }

    /// The entries in `git status --porcelain -z`: "XY path", and after a rename or copy its old path, which
    /// is no entry of its own.
    public static func countStatus(_ data: Data) -> Int {
        let fields = data.split(separator: 0)
        var count = 0, index = fields.startIndex
        while index < fields.endIndex {
            let first = fields[index].first
            count += 1
            index += first == UInt8(ascii: "R") || first == UInt8(ascii: "C") ? 2 : 1
        }
        return count
    }
}
