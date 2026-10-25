import Darwin
import Foundation
import Testing
@testable import NextTermCore

@Suite struct PeerCodeTests {
    @Test func oneHashPerSliceJoinedWithOr() throws {
        let slices = PeerCode.architectures(of: "/usr/bin/true")
        let hashes = PeerCode.sliceHashes(of: "/usr/bin/true")
        #expect(!slices.isEmpty && hashes.count == slices.count, "\(slices.count) slices, \(hashes.count) hashes")
        #expect(hashes.allSatisfy { $0.count == 20 } && Set(hashes).count == hashes.count)
        let requirement = try #require(PeerCode.requirement(for: hashes))
        #expect(requirement.components(separatedBy: " or ").count == hashes.count)
        #expect(requirement.hasPrefix("cdhash H\"") && requirement.hasSuffix("\""))
        #expect(PeerCode.requirement(for: []) == nil)
        #expect(PeerCode.sliceHashes(of: "/nonexistent/program").isEmpty)
    }

    @Test func aSocketPairInThisProcessPasses() throws {
        var fds: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let token = try #require(PeerCode.auditToken(of: fds[0]))
        #expect(PeerCode.pid(token) == getpid() && PeerCode.effectiveUser(token) == geteuid())
        let me = PeerCode(path: try #require(Self.executablePath()))
        #expect(me.requirementText != nil)
        #expect(me.isThisProgram(auditToken: token))
        #expect(PeerCode.isSameProcess(socket: fds[0], as: token))
        // Another program's hashes: the same process fails them.
        #expect(!PeerCode(path: "/usr/bin/true").isThisProgram(auditToken: token))
        // A zeroed token fails.
        #expect(!me.isThisProgram(auditToken: audit_token_t()))
    }

    /// This test process's own executable, as the kernel names it.
    static func executablePath() -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
