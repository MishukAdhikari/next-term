import Foundation

// The branch popup's writes that take more than a word to get right, as the arguments after
// `git -C <worktree>`, and who holds a worktree's lock. Design: claudedocs/research_next-term-git-branches
// (8.3 worktree row, 8.6, 8.8).

public enum BranchCommand {
    /// Delete on Remote: the branch by its full name, so a tag of the same name is never the one deleted.
    public static func deleteOnRemote(remote: String, branch: String) -> [String] {
        ["push", "--porcelain", remote, "--delete", "refs/heads/" + branch]
    }

    /// Its Undo, while the commit is still here: the branch made again on the remote at that commit.
    public static func restoreOnRemote(remote: String, branch: String, sha: String) -> [String] {
        ["push", "--porcelain", remote, sha + ":refs/heads/" + branch]
    }

    /// Update a branch that isn't checked out: fetch its upstream into it. Without a "+", git moves it
    /// only forward, and refuses ("[rejected] … (non-fast-forward)") when the two have diverged; it
    /// refuses a branch checked out in any worktree too.
    public static func fetchInto(local: String, remote: String, upstream: String) -> [String] {
        ["fetch", remote, "refs/heads/" + upstream + ":refs/heads/" + local]
    }

    /// The branch checked out, forward to its upstream (the changes you carry along are put aside and back).
    public static let fastForward = ["merge", "--ff-only", "--autostash", "@{upstream}"]

    /// Checkout and Update: switch, then forward to the upstream.
    public static func checkoutAndUpdate(_ branch: String) -> [[String]] {
        [["switch", branch], fastForward]
    }

    /// Unlock a worktree whose lock is stale (or one you choose to free).
    public static func unlock(worktree path: String) -> [String] {
        ["worktree", "unlock", path]
    }

    /// Its Undo: locked again, with the same reason.
    public static func lock(worktree path: String, reason: String) -> [String] {
        reason.isEmpty ? ["worktree", "lock", path] : ["worktree", "lock", "--reason", reason, path]
    }
}

/// Who holds a worktree's lock, when its reason names a process. Claude Code locks the worktree it works
/// in, with "claude agent agent-a3910… (pid 7639 start Tue Oct  6 06:05:05 2026)": the start as
/// `ps -o lstart=` prints it in UTC.
public struct LockHolder: Equatable, Sendable {
    public let pid: Int32
    /// When that process started, if the reason says.
    public let started: Date?
    /// The reason's first word, the program that locked it: "claude".
    public let program: String

    public init(pid: Int32, started: Date?, program: String) {
        self.pid = pid
        self.started = started
        self.program = program
    }

    /// The holder a lock reason names, or nil when it names no process.
    public static func parse(_ reason: String) -> LockHolder? {
        guard let match = reason.range(of: #"\(pid [0-9]+( start [^)]*)?\)"#, options: .regularExpression) else { return nil }
        let inside = reason[match].dropFirst("(pid ".count).dropLast()
        let words = inside.split(separator: " ", maxSplits: 1)
        guard let first = words.first, let pid = Int32(first), pid > 0 else { return nil }
        var started: Date?
        if words.count > 1, words[1].hasPrefix("start ") { started = startDate(String(words[1].dropFirst("start ".count))) }
        let program = reason.split(separator: " ").first.map(String.init) ?? ""
        return LockHolder(pid: pid, started: started, program: program.hasPrefix("(") ? "" : program)
    }

    /// "Tue Oct  6 06:05:05 2026" (two spaces before a one-digit day), in UTC.
    static func startDate(_ text: String) -> Date? {
        let words = text.split(separator: " ").joined(separator: " ")
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return format.date(from: words)
    }

    /// Whether the process that locked it still runs: the same pid, started in the same second, since a pid
    /// that ended is soon given to another process. `startTime` gives a running process's start, or nil.
    public func isAlive(startTime: (Int32) -> Date? = LockHolder.startTime(of:)) -> Bool {
        guard let running = startTime(pid) else { return false }
        guard let started else { return true }
        return abs(running.timeIntervalSince(started)) < 1.5
    }

    /// When the process with this pid started; nil when there is none.
    public static func startTime(of pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}

/// What people call an agent, from its program's name: "Claude Code" for claude.
public enum AgentName {
    private static let names: [String: String] = {
        var names = ["claude": "Claude Code", "claude-code": "Claude Code"]
        for target in MCPRegistrar.targets() {
            for program in target.programs { names[program] = target.name }
        }
        return names
    }()

    public static func of(program: String) -> String {
        names[program] ?? program
    }
}
