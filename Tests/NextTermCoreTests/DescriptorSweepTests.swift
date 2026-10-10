import Foundation
import Testing
@testable import NextTermCore

@Suite(.serialized) struct DescriptorSweepTests {
    /// What a new tab's shell would inherit: every descriptor from 3 up is marked close-on-exec, the standard
    /// three are left as they are.
    @Test func marksEveryDescriptorFromThreeUpCloseOnExec() {
        var ends: [Int32] = [0, 0]
        #expect(pipe(&ends) == 0)
        let high = dup2(ends[0], 700)
        defer {
            close(ends[0])
            close(ends[1])
            close(high)
        }
        #expect(fcntl(ends[0], F_GETFD) & FD_CLOEXEC == 0)
        let standard = (0...2).map { fcntl($0, F_GETFD) }
        let marked = DescriptorSweep.markCloseOnExec()
        #expect(marked >= 3)
        for fd in [ends[0], ends[1], high] {
            #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0, "descriptor \(fd)")
        }
        #expect((0...2).map { fcntl($0, F_GETFD) } == standard)
    }

    @Test func marksOneDescriptor() {
        let fd = open("/dev/null", O_RDONLY)
        defer { close(fd) }
        #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC == 0)
        DescriptorSweep.closeOnExec(fd)
        #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
    }
}
