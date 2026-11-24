import Foundation
import Testing
@testable import NextTermCore

@Suite struct ListenerRetireTests {
    private func listener() throws -> (fd: Int32, address: sockaddr_in) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0 && listen(fd, 8) == 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        return (fd, address)
    }

    /// A retired listener frees its port at once but keeps its number, so an accept loop that comes round late finds
    /// no socket there (never another listener's), and the loop closes the number as it ends.
    @Test func aRetiredListenerFreesItsPortAndKeepsItsNumberUntilTheLoopEnds() throws {
        var (fd, address) = try listener()
        ListenerRetire.retire(fd)
        var info = stat()
        #expect(fstat(fd, &info) == 0 && info.st_mode & S_IFMT != S_IFSOCK)
        #expect(accept(fd, nil, nil) < 0 && errno == ENOTSOCK)

        let again = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(again) }
        var on: Int32 = 1
        setsockopt(again, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(again, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(bound == 0 && listen(again, 8) == 0)

        ListenerRetire.loopEnded(fd)
        #expect(fcntl(fd, F_GETFD) < 0)
    }

    /// A loop that ends while its socket still listens leaves the socket to its owner's retire.
    @Test func aLoopEndingOnALiveListenerLeavesIt() throws {
        let (fd, _) = try listener()
        ListenerRetire.loopEnded(fd)
        #expect(fcntl(fd, F_GETFD) >= 0)
        ListenerRetire.retire(fd)
        ListenerRetire.loopEnded(fd)
        #expect(fcntl(fd, F_GETFD) < 0)
    }

    /// An accept blocked in its loop wakes when the listener is retired.
    @Test func aBlockedAcceptWakes() throws {
        let (fd, _) = try listener()
        let woke = DispatchSemaphore(value: 0)
        Thread {
            while accept(fd, nil, nil) >= 0 {}
            ListenerRetire.loopEnded(fd)
            woke.signal()
        }.start()
        Thread.sleep(forTimeInterval: 0.1)
        ListenerRetire.retire(fd)
        #expect(woke.wait(timeout: .now() + 3) == .success)
    }
}
