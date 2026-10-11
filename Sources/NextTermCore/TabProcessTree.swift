import Foundation

/// One process as the kernel lists it (sysctl KERN_PROC_ALL), with what a tab's hangup is decided on.
public struct ProcessRecord: Equatable, Sendable {
    public var pid: Int32
    public var parent: Int32
    public var group: Int32
    /// The controlling terminal's device, or `noTerminal` (a process in a session of its own, as an agent's tool
    /// commands are).
    public var terminal: Int32
    /// When it started, in microseconds: a pid seen again with another start time is another process.
    public var started: UInt64
    /// SIGHUP is ignored (nohup): the hangup leaves it running, and it is never sent SIGTERM.
    public var ignoresHangup: Bool
    /// Stopped (Ctrl-Z, SIGSTOP): a hangup reaches it only once it is continued.
    public var stopped: Bool
    /// What the close alerts call it ("next-server", "claude").
    public var name: String

    public static let noTerminal: Int32 = -1 // NODEV

    public init(pid: Int32, parent: Int32, group: Int32, terminal: Int32, started: UInt64, ignoresHangup: Bool = false,
                stopped: Bool = false, name: String) {
        self.pid = pid
        self.parent = parent
        self.group = group
        self.terminal = terminal
        self.started = started
        self.ignoresHangup = ignoresHangup
        self.stopped = stopped
        self.name = name
    }
}

/// What closing a tab hangs up besides its shell: the program in front, and what it started that left its group
/// or the terminal (an agent's `npm run dev`). Signals go to whole groups, foreground first.
public struct HangupPlan: Equatable, Sendable {
    /// The groups to hang up (killpg SIGHUP), the foreground's first.
    public var groups: [Int32] = []
    /// Groups with a stopped member: continued after the hangup (SIGCONT), so it arrives.
    public var stoppedGroups: [Int32] = []
    /// Every process in those groups when the snapshot was taken, foreground first.
    public var targets: [ProcessRecord] = []
    /// The foreground group's members: the program the tab shows as running.
    public var foreground: [ProcessRecord] = []
    /// The targets outside the foreground group: what the program in front started in a group or session of its own.
    public var startedOutside: [ProcessRecord] = []

    public static let none = HangupPlan()

    /// Sent SIGTERM if they outlive the hangup: every target but those ignoring SIGHUP.
    public var stoppable: [ProcessRecord] { targets.filter { !$0.ignoresHangup } }
    /// What the hangup leaves running: the targets ignoring SIGHUP.
    public var keepsRunning: [ProcessRecord] { targets.filter(\.ignoresHangup) }

    /// The same plan with each process called `name(process)`, for the alerts (names from the command line).
    public func named(_ name: (ProcessRecord) -> String) -> HangupPlan {
        func rename(_ list: [ProcessRecord]) -> [ProcessRecord] {
            list.map { record in
                var renamed = record
                renamed.name = name(record)
                return renamed
            }
        }
        var plan = self
        plan.targets = rename(targets)
        plan.foreground = rename(foreground)
        plan.startedOutside = rename(startedOutside)
        return plan
    }
}

/// Decides what a tab's close (tab, window or Quit) hangs up, from one snapshot of the process list taken before
/// any signal. The shell is hung up as always and is never a root: at its prompt nothing else is a target, so its
/// background, disowned and double-forked jobs are left to its own hangup, as in every terminal. With a program in
/// front (tcgetpgrp), the targets are that group's members plus all their descendants that left the group
/// (setpgid) or the terminal (setsid), which is where an agent's dev server lives.
public enum TabProcessTree {
    /// - Parameters:
    ///   - shell: the tab's shell; its own record gives the terminal the front must be on.
    ///   - foregroundGroup: the terminal's foreground group (tcgetpgrp on the pty).
    ///   - remote: a tab on a server: its pty holds only ssh, and what runs on the host is the host's.
    ///   - interactiveShells: members of the front that are interactive shells at their own prompt (`bash`,
    ///     `nix develop`): their jobs are theirs to hang up, so nothing below them is a target.
    public static func plan(snapshot: [ProcessRecord], shell: Int32, foregroundGroup: Int32, remote: Bool = false,
                            interactiveShells: Set<Int32> = []) -> HangupPlan {
        guard !remote, shell > 1, foregroundGroup > 1, foregroundGroup != shell,
              let shellRecord = snapshot.first(where: { $0.pid == shell }),
              foregroundGroup != shellRecord.group, shellRecord.terminal != ProcessRecord.noTerminal else { return .none }
        let front = snapshot.filter {
            $0.group == foregroundGroup && $0.terminal == shellRecord.terminal && $0.pid != shell
        }.sorted { $0.pid < $1.pid }
        guard !front.isEmpty else { return .none }

        var children: [Int32: [ProcessRecord]] = [:]
        for record in snapshot where record.pid != record.parent {
            children[record.parent, default: []].append(record)
        }
        // A terminal of its own below the tab (GNU screen's windows, `script`, an editor's :terminal, dtach,
        // abduco) is that terminal's business, as it always was: when the program holding it ends, its pty hangs
        // up what runs there, and screen, dtach and abduco keep their sessions. So the walk never enters a
        // process on another terminal, nor one with no terminal that holds such a process (screen's server,
        // which sits in a session of its own as an agent's tool does).
        let tabTerminal = shellRecord.terminal
        func onOtherTerminal(_ record: ProcessRecord) -> Bool {
            record.terminal != ProcessRecord.noTerminal && record.terminal != tabTerminal
        }
        let terminalHosts = Set(snapshot.filter(onOtherTerminal).map(\.parent))
        func ownsATerminal(_ record: ProcessRecord) -> Bool {
            if onOtherTerminal(record) { return true }
            return record.terminal == ProcessRecord.noTerminal && terminalHosts.contains(record.pid)
        }
        // Walk down from the front, breadth first, children in pid order.
        var found: [Int32] = []
        var queue = front.filter { !interactiveShells.contains($0.pid) }
        var seen = Set(front.map(\.pid))
        while !queue.isEmpty {
            let next = queue.removeFirst()
            for child in (children[next.pid] ?? []).sorted(by: { $0.pid < $1.pid }) {
                // Before `seen`: a terminal's host never counts toward a group being theirs.
                guard !ownsATerminal(child), seen.insert(child.pid).inserted else { continue }
                queue.append(child)
                let group = child.group
                guard group != foregroundGroup, group > 1, group != shellRecord.group, group != shell else { continue }
                if !found.contains(group) { found.append(group) }
            }
        }
        // A group is hung up only if it is theirs: its leader is one of the descendants, or all of its members are.
        // A child that joined someone else's group (another job's) does not take that job down with it.
        let outsideGroups = found.filter { group in
            if seen.contains(group) { return true }
            return snapshot.allSatisfy { $0.group != group || seen.contains($0.pid) }
        }

        var plan = HangupPlan()
        plan.groups = [foregroundGroup] + outsideGroups
        plan.foreground = front
        plan.startedOutside = outsideGroups.flatMap { group in
            snapshot.filter { $0.group == group }.sorted { $0.pid < $1.pid }
        }
        plan.targets = front + plan.startedOutside
        plan.stoppedGroups = plan.groups.filter { group in plan.targets.contains { $0.group == group && $0.stopped } }
        return plan
    }

    /// Of `waiting`, the processes still alive as themselves (`now` gives the same pid with the same start time)
    /// that don't ignore SIGHUP: they get SIGTERM once the grace is over. Gone, reused and nohup'd pids are left out.
    public static func outlived(_ waiting: [ProcessRecord], now: (Int32) -> ProcessRecord?) -> [ProcessRecord] {
        waiting.filter { record in
            guard !record.ignoresHangup, let current = now(record.pid) else { return false }
            return current.started == record.started && !current.ignoresHangup
        }
    }

    static let shellNames: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "mksh", "tcsh", "csh", "nu", "xonsh", "elvish", "pwsh"]

    /// A shell waiting at its own prompt, not one running a script or a `-c` command: no `-c`, and no argument
    /// that isn't an option.
    public static func isInteractiveShell(name: String, arguments: [String]) -> Bool {
        let base = name.hasPrefix("-") ? String(name.dropFirst()) : name
        guard shellNames.contains(base), !arguments.isEmpty else { return false }
        for argument in arguments.dropFirst() {
            if !argument.hasPrefix("-") { return false } // a script
            if !argument.hasPrefix("--"), argument.dropFirst().contains("c") { return false } // -c, -lc
        }
        return true
    }
}
