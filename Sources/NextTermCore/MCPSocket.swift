import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The Unix socket between the app and `nxtrm mcp`: the app listens, and the bridge connects once per tool call.
///
/// Every descriptor made here is close-on-exec as it is made (`DescriptorSweep.closeOnExec`): the sweep before a tab's
/// shell starts would miss one made on another thread between it and the fork, and a shell would keep a copy of the
/// listener. That copy would go on listening after the
/// app closed its own at a quit, or at an update's drain, which keeps the socket file. A connect there would then wait in a
/// backlog nobody accepts, instead of being refused, which `nxtrm mcp` reads as a restart. And the next launch would take
/// it for another Next Term already serving there, and never listen. macOS has neither SOCK_CLOEXEC nor accept4.
public enum MCPSocket {
    /// A socket listening at `path`, owner only (0600) from the moment it exists: its descriptor, or -1 with `errno` set.
    public static func listen(path: String, backlog: Int32 = 16) -> Int32 {
        guard var address = address(path) else { errno = ENAMETOOLONG; return -1 }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        DescriptorSweep.closeOnExec(fd)
        let previousMask = umask(0o077)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previousMask)
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, backlog) == 0 else { return failed(fd) }
        return fd
    }

    /// A connection to the socket at `path`: its descriptor, or -1 with `errno` set to why (ECONNREFUSED: the file is
    /// there and nothing listens; ENOENT: no file).
    public static func connect(path: String) -> Int32 {
        guard var address = address(path) else { errno = ENAMETOOLONG; return -1 }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        DescriptorSweep.closeOnExec(fd)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return failed(fd) }
        return fd
    }

    /// The next connection waiting on `listener`, or -1 with `errno` set (EAGAIN: none waits, on a non-blocking one).
    public static func accept(_ listener: Int32) -> Int32 {
        let fd = Darwin.accept(listener, nil, nil)
        DescriptorSweep.closeOnExec(fd)
        return fd
    }

    private static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    /// Closes `fd` and keeps the errno that made it fail.
    private static func failed(_ fd: Int32) -> Int32 {
        let code = errno
        close(fd)
        errno = code
        return -1
    }
}
