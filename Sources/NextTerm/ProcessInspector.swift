import Darwin
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

    /// The files a process has open (its descriptors on files, by path).
    static func openFiles(of pid: pid_t) -> [String] {
        guard pid > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 8)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard filled > 0 else { return [] }
        return fds.prefix(Int(filled) / stride).compactMap { fd -> String? in
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return nil }
            var info = vnode_fdinfowithpath()
            let wanted = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, wanted) == wanted else { return nil }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw in String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self) }
            return path.isEmpty ? nil : path
        }
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
