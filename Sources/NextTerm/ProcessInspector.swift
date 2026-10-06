import Darwin

/// Reads live process facts straight from the kernel: no `ps`, no `lsof`.
enum ProcessInspector {
    /// Name of the process group in the foreground of the pty (what the user is running).
    static func foregroundProcessName(ptyFileDescriptor fd: Int32) -> String? {
        guard fd >= 0 else { return nil }
        let pgid = tcgetpgrp(fd)
        guard pgid > 0 else { return nil }
        var name = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pgid, &name, UInt32(name.count)) > 0 else { return nil }
        return String(cString: name)
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
}
