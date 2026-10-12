import Darwin

/// Descriptors a new tab's shell must not inherit. SwiftTerm starts the shell with forkpty and execve and closes
/// nothing in between, so without close-on-exec every shell holds the pty masters of the tabs opened before it
/// (and the MCP socket, git's output files, framework caches): after a crash or Force Quit those masters stay
/// open, the kernel never hangs those tabs up, and their shells and programs run on.
public enum DescriptorSweep {
    /// Marks every open descriptor from 3 up close-on-exec (proc_pidinfo PROC_PIDLISTFDS, then fcntl), right before
    /// a shell starts. Returns how many it marked.
    @discardableResult
    public static func markCloseOnExec() -> Int {
        let pid = getpid()
        let stride = MemoryLayout<proc_fdinfo>.stride
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return 0 }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 32)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard filled > 0 else { return 0 }
        var marked = 0
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fd > 2 {
            let flags = fcntl(fd.proc_fd, F_GETFD)
            if flags >= 0, flags & FD_CLOEXEC == 0, fcntl(fd.proc_fd, F_SETFD, flags | FD_CLOEXEC) == 0 { marked += 1 }
        }
        return marked
    }

    /// Marks one descriptor close-on-exec, as soon as it is made (sockets and accept have no flag for it here).
    public static func closeOnExec(_ fd: Int32) {
        guard fd >= 0 else { return }
        let flags = fcntl(fd, F_GETFD)
        if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
    }

    /// Whether `fd` closes as a process this one starts runs its program.
    public static func isCloseOnExec(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFD)
        return flags >= 0 && flags & FD_CLOEXEC != 0
    }
}
