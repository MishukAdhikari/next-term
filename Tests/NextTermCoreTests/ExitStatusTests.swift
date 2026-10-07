import Foundation
import Testing
@testable import NextTermCore

@Suite struct ExitStatusTests {
    /// A child running `/bin/sh -c script`.
    private func spawn(_ script: String) -> pid_t {
        var pid: pid_t = 0
        let words: [String] = ["/bin/sh", "-c", script]
        let args: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
        defer { args.forEach { free($0) } }
        #expect(posix_spawn(&pid, "/bin/sh", nil, nil, args, nil) == 0)
        return pid
    }

    /// Until `pid` has exited, leaving it there to reap (as when the exit event beat the reaping).
    private func waitForExitWithoutReaping(_ pid: pid_t) {
        var info = siginfo_t()
        _ = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
    }

    @Test func aZeroReadBeforeTheProcessCouldBeReapedIsReadAgain() {
        let pid = spawn("exit 255")
        waitForExitWithoutReaping(pid)
        let status = ExitStatus.confirmed(0, pid: pid)
        #expect(status.map { ($0 >> 8) & 0xFF } == 255)
        #expect(waitpid(pid, nil, WNOHANG) == -1) // and it is reaped: no zombie left behind
    }

    @Test func aRealCleanExitStaysClean() {
        let pid = spawn("exit 0")
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0) // reaped with its status, as SwiftTerm usually manages
        #expect(ExitStatus.confirmed(0, pid: pid) == 0)
        #expect(ExitStatus.confirmed(nil, pid: pid) == nil)
    }

    @Test func aStatusThatWasReadIsKept() {
        let pid = spawn("exit 3")
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        #expect(ExitStatus.confirmed(status, pid: pid) == status)
        #expect(ExitStatus.confirmed(0, pid: 0) == 0)
    }

    @Test func aProcessStillRunningIsNotWaitedForLong() {
        let pid = spawn("sleep 5")
        defer { kill(pid, SIGKILL); _ = waitpid(pid, nil, 0) }
        let started = Date()
        #expect(ExitStatus.confirmed(0, pid: pid, within: 0.05) == 0)
        #expect(Date().timeIntervalSince(started) < 1)
    }
}
