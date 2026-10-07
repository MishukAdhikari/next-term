import Foundation

/// A terminal's child process, at its exit.
public enum ExitStatus {
    /// The raw waitpid status `pid` exited with, when `reported` (what SwiftTerm handed over) is a 0 it may
    /// have read too early. SwiftTerm calls waitpid with WNOHANG as soon as the kernel posts the exit, and
    /// on macOS that event can come a moment before the process can be reaped: waitpid then returns 0 and
    /// the status stays 0, a clean exit. A dropped ssh (255) closed its tab instead of saying the
    /// connection was lost, and a shell that failed closed without its exit code. A process still there
    /// to reap is waited for, briefly (it has exited); one already reaped had a real 0, which stays.
    public static func confirmed(_ reported: Int32?, pid: Int32, within seconds: TimeInterval = 0.2) -> Int32? {
        guard reported == nil || reported == 0, pid > 0 else { return reported }
        let deadline = Date().addingTimeInterval(seconds)
        var status: Int32 = 0
        while true {
            let reaped = waitpid(pid, &status, WNOHANG)
            if reaped == pid { return status }
            if reaped < 0, errno != EINTR { return reported } // reaped already (or not a child): the status was real
            if reaped == 0, Date() >= deadline { return reported }
            usleep(1_000)
        }
    }
}
