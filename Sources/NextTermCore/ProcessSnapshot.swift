import Darwin

/// The kernel's process list (sysctl KERN_PROC), read straight: no `ps`.
public enum ProcessSnapshot {
    /// Every process now, zombies left out (they can't be signalled into ending). nil if the kernel would not list them.
    public static func take() -> [ProcessRecord]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<4 { // processes started between asking the size and reading: room for more, and try again
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64)
            size = procs.count * stride
            let read = procs.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
            if read != 0 {
                if errno == ENOMEM { continue }
                return nil
            }
            return procs.prefix(size / stride).compactMap(record)
        }
        return nil
    }

    /// One process now, or nil if it is gone (or a zombie).
    public static func record(of pid: Int32) -> ProcessRecord? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return record(info)
    }

    static func record(_ info: kinfo_proc) -> ProcessRecord? {
        let proc = info.kp_proc
        guard proc.p_stat != SZOMB, proc.p_pid >= 0 else { return nil }
        let started = proc.p_un.__p_starttime
        var comm = proc.p_comm
        let name = withUnsafeBytes(of: &comm) { raw in String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let hangup: UInt32 = 1 << UInt32(SIGHUP - 1)
        return ProcessRecord(pid: proc.p_pid, parent: info.kp_eproc.e_ppid, group: info.kp_eproc.e_pgid,
                             terminal: info.kp_eproc.e_tdev,
                             started: UInt64(max(0, started.tv_sec)) * 1_000_000 + UInt64(max(0, started.tv_usec)),
                             ignoresHangup: proc.p_sigignore & hangup != 0, stopped: proc.p_stat == SSTOP, name: name)
    }
}
