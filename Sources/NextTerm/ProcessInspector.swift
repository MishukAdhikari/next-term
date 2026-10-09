import Darwin
import Foundation
import NextTermCore

/// Reads live process facts straight from the kernel: no `ps`, no `lsof`.
enum ProcessInspector {
    /// What is in the foreground of the pty. nil when it cannot be read.
    ///
    /// "The shell is in front" is decided by process ID, not name: a `#!/bin/bash` script run from bash
    /// is also called "bash". When the shell's own process exec'd something (`exec ssh host`), the
    /// group is still the shell's but the name is not, and that counts as a running program.
    static func foreground(ptyFileDescriptor fd: Int32, shellPid: pid_t, shellName: String) -> ForegroundProcess? {
        guard fd >= 0, shellPid > 0 else { return nil }
        let pgid = tcgetpgrp(fd)
        guard pgid > 0 else { return nil }
        guard let name = processName(pgid) else {
            // The group leader is gone (e.g. `curl … | sh` after curl exits): unknown, not idle.
            return pgid == shellPid ? ForegroundProcess(isShell: true, name: shellName) : nil
        }
        // The tab's shell process may have exec'd another shell (`exec bash`): still a shell at a prompt.
        // If it exec'd anything else (`exec ssh host`), that program is what runs.
        if pgid == shellPid && (name == shellName || shells.contains(name)) { return ForegroundProcess(isShell: true, name: name) }
        let (path, args) = commandLine(of: pgid) ?? ("", [])
        return ForegroundProcess(isShell: false, name: name, arguments: args, executablePath: path)
    }

    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "mksh", "tcsh", "csh", "nu", "xonsh", "elvish", "pwsh"]

    static func processName(_ pid: pid_t) -> String? {
        var name = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
        return String(cString: name)
    }

    /// Executable path and argv (first 16 arguments) of a process owned by this user.
    static func commandLine(of pid: pid_t) -> (path: String, arguments: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var i = MemoryLayout<Int32>.size
        func nextString() -> String {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            let text = String(decoding: buffer[start..<i], as: UTF8.self)
            return text
        }
        let path = nextString()
        while i < size, buffer[i] == 0 { i += 1 } // padding after the executable path
        var args: [String] = []
        while args.count < min(argc, 16), i < size {
            args.append(nextString())
            i += 1
        }
        return (path, args)
    }

    /// Current working directory of a process.
    static func currentDirectory(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// A process and the processes it started, two generations down: an agent run by a wrapper (node
    /// starting Codex's own binary) does its work in a child.
    static func family(of pid: pid_t) -> [pid_t] {
        func children(_ parent: pid_t) -> [pid_t] {
            let count = proc_listchildpids(parent, nil, 0)
            guard count > 0 else { return [] }
            var pids = [pid_t](repeating: 0, count: Int(count) + 8)
            let filled = proc_listchildpids(parent, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            return filled > 0 ? pids.prefix(Int(filled)).filter { $0 > 0 } : []
        }
        guard pid > 0 else { return [] }
        let first = children(pid)
        return [pid] + first + first.flatMap(children)
    }

    // MARK: agent evidence

    /// The evidence of the agent a tab runs (KTD4), read now: on each periodic save, and again at quit before any
    /// signal reaches the tab. The process leading the tab's foreground group counts only when it descends from the
    /// tab's shell. For an agent that runs itself again in a child (RestoreAgent.relaunchesItself), that child is read
    /// with it; for Copilot CLI, the session its commands are told. The agent's routing variables are compared with the
    /// login shell's (LoginShell.routing), the environment a restored tab's shell starts with: the tab's own shell
    /// shows the kernel no environment, and what its rc files export never reaches that record. Nil when the tab runs
    /// no agent.
    static func agentEvidence(ptyFileDescriptor fd: Int32, shellPid: pid_t, status: TabStatus,
                              home: String = NSHomeDirectory()) -> SessionSnapshot.Evidence? {
        var capture = AgentEvidence.Capture(status: status, home: home)
        capture.shellRouting = LoginShell.routing
        let leaderID = fd >= 0 && shellPid > 0 ? tcgetpgrp(fd) : -1
        if leaderID > 0, let found = agentProcess(leaderID) {
            let agent = RestoreAgent(process: found)
            let readsFiles = agent == .codex
            capture.leader = readsFiles ? holdingFiles(found) : found
            capture.verified = descends(leaderID, from: shellPid)
            if agent?.relaunchesItself == true {
                // Only a child of its own is the agent run again: a copy further down is one its tools started.
                capture.relaunched = children(of: leaderID).compactMap { child -> AgentProcess? in
                    guard let process = agentProcess(child), RestoreAgent(process: process) == agent else { return nil }
                    return readsFiles ? holdingFiles(process) : process
                }
            }
            if agent == .copilot {
                let key = AgentEvidence.copilotSessionKey
                capture.childSessionIDs = descendants(of: leaderID).compactMap { arguments(of: $0, keeping: [key])?.environment[key] }
            }
        }
        return AgentEvidence.capture(capture)
    }

    /// What capture reads of one process: when it started, the file the kernel ran, its whole argv, the variables of
    /// AgentEvidence.environmentKeys by value and of AgentEvidence.routingKeys as digests only, and its folder. Each is
    /// a call of its own, so the start time is read first and again last: a pid the kernel gave another process in
    /// between would mix the two, and reads as none.
    static func agentProcess(_ pid: pid_t) -> AgentProcess? {
        guard let start = startTime(of: pid), let path = executablePath(of: pid),
              let read = arguments(of: pid, keeping: AgentEvidence.environmentKeys, digesting: AgentEvidence.routingKeys) else { return nil }
        let directory = currentDirectory(of: pid)
        guard startTime(of: pid) == start else { return nil }
        return AgentProcess(pid: pid, startedAt: start, executable: path, arguments: read.arguments, environment: read.environment,
                            directory: directory, routing: read.routing)
    }

    /// `process` with the files it holds open, while it is still the process that was read.
    private static func holdingFiles(_ process: AgentProcess) -> AgentProcess? {
        var holding = process
        holding.openFiles = openFiles(of: process.pid)
        return startTime(of: process.pid) == process.startedAt ? holding : nil
    }

    /// When a process started, by the kernel's clock.
    static func startTime(of pid: pid_t) -> Date? {
        guard let info = bsdInfo(pid) else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    static func parent(of pid: pid_t) -> pid_t? {
        bsdInfo(pid).map { pid_t(bitPattern: $0.pbi_ppid) }
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    /// The file the kernel ran for a process (proc_pidpath): its real path, whatever name started it.
    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard pid > 0, proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// A process's whole argv, the variables of `keys` in its environment, and those of `secret` as digests
    /// (KERN_PROCARGS2). Only a process of this user's can be read.
    static func arguments(of pid: pid_t, keeping keys: Set<String>, digesting secret: Set<String> = []) -> ProcessArguments? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard pid > 0, sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return ProcessArguments.parse(Array(buffer.prefix(size)), keeping: keys, digesting: secret)
    }

    /// `pid` is `ancestor`, or below it.
    static func descends(_ pid: pid_t, from ancestor: pid_t) -> Bool {
        var current = pid
        for _ in 0..<64 {
            if current == ancestor { return true }
            guard current > 1, let up = parent(of: current), up != current else { return false }
            current = up
        }
        return false
    }

    /// A process's children.
    static func children(of pid: pid_t) -> [pid_t] {
        guard pid > 0 else { return [] }
        let count = proc_listchildpids(pid, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 8)
        let filled = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(min(Int(filled), pids.count)).filter { $0 > 0 }
    }

    /// The processes below `pid`, nearest first: `depth` generations, at most `limit` of them.
    static func descendants(of pid: pid_t, depth: Int = 2, limit: Int = 64) -> [pid_t] {
        var found: [pid_t] = []
        var generation = [pid]
        for _ in 0..<depth where found.count < limit {
            generation = generation.flatMap(children(of:))
            found += generation
        }
        return Array(found.prefix(limit))
    }

    /// The paths of the files a process holds open (vnodes), at most `limit`.
    static func openFiles(of pid: pid_t, limit: Int = 1024) -> [String] {
        guard pid > 0 else { return [] }
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
        guard filled > 0 else { return [] }
        var paths: [String] = []
        let vnode = UInt32(PROX_FDTYPE_VNODE)
        for descriptor in descriptors.prefix(min(Int(filled) / stride, descriptors.count)) where descriptor.proc_fdtype == vnode {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if !path.isEmpty { paths.append(path) }
            if paths.count >= limit { break }
        }
        return paths
    }

    /// Helper daemons that prompt frameworks keep as children of the shell; not the user's jobs.
    private static let shellHelpers = ["gitstatusd", "zsh", "bash", "fish", "sh"]

    /// Names of the shell's direct child processes, minus prompt helpers (used for shells without
    /// integration, where the shell cannot tell us about its jobs).
    static func childProcessNames(of pid: pid_t) -> [String] {
        guard pid > 0 else { return [] }
        let count = proc_listchildpids(pid, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 8)
        let filled = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).compactMap { child in
            guard child > 0, let name = processName(child) else { return nil }
            return shellHelpers.contains(where: { name.hasPrefix($0) }) ? nil : name
        }
    }
}
