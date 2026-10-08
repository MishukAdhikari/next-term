import Darwin
import Foundation

/// Which process is at the other end of a loopback connection to the Claude Code link.
///
/// opencode reads Claude Code's lock files, but in a Next Term tab, where `CLAUDE_CODE_SSE_PORT` is set,
/// it connects to that port without the token (and without the "mcp" subprotocol). ClaudeIDEServer takes
/// such a connection only when the process holding its socket is opencode running in one of this app's own
/// tabs: it is looked for among the descendants of the tabs' shells, by the two ports of its TCP socket.
/// Any other client without the token is refused, as before.
public enum IDEPeer {
    /// How processes are looked up: the kernel's (libproc), or a stand-in for the tests.
    public struct Processes: Sendable {
        public var children: @Sendable (pid_t) -> [pid_t]
        /// The TCP sockets a process holds, by local and remote port.
        public var sockets: @Sendable (pid_t) -> [(local: UInt16, remote: UInt16)]
        /// The executable's path.
        public var path: @Sendable (pid_t) -> String?

        public init(children: @escaping @Sendable (pid_t) -> [pid_t],
                    sockets: @escaping @Sendable (pid_t) -> [(local: UInt16, remote: UInt16)],
                    path: @escaping @Sendable (pid_t) -> String?) {
            self.children = children
            self.sockets = sockets
            self.path = path
        }

        public static let system = Processes(children: { childPids($0) }, sockets: { tcpSockets($0) }, path: { executablePath($0) })
    }

    /// How deep and how many processes under the tabs' shells are looked at (a shell, a wrapper, the agent
    /// and its helpers are a few levels at most).
    static let maximumDepth = 8
    static let maximumProcesses = 512

    /// The processes under `shells` (not the shells themselves) holding the client end of the connection
    /// from `clientPort` to `serverPort`, nearest first.
    public static func holders(clientPort: UInt16, serverPort: UInt16, under shells: [pid_t],
                               processes: Processes = .system) -> [pid_t] {
        var found: [pid_t] = []
        var seen = Set(shells)
        var level = shells.flatMap(processes.children)
        var depth = 0
        while !level.isEmpty, depth < maximumDepth, seen.count < maximumProcesses {
            var next: [pid_t] = []
            for pid in level where pid > 1 && seen.insert(pid).inserted {
                if processes.sockets(pid).contains(where: { $0.local == clientPort && $0.remote == serverPort }) {
                    found.append(pid)
                }
                next += processes.children(pid)
            }
            level = next
            depth += 1
        }
        return found
    }

    /// opencode's own executable: `opencode` (Homebrew, its install script, npm's platform package), or
    /// `opencode.exe`, the name npm's and bun's `opencode-ai` link the same binary under (its bin/opencode.exe).
    public static func isOpencode(path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        return name == "opencode" || name == "opencode.exe"
    }

    /// The opencode process in one of the tabs (under `shells`) that holds this connection's socket, or nil.
    public static func opencode(clientPort: UInt16, serverPort: UInt16, under shells: [pid_t],
                                processes: Processes = .system) -> pid_t? {
        holders(clientPort: clientPort, serverPort: serverPort, under: shells, processes: processes)
            .first { processes.path($0).map(isOpencode) ?? false }
    }

    // MARK: the kernel's view

    static func childPids(_ pid: pid_t) -> [pid_t] {
        guard pid > 0 else { return [] }
        let count = proc_listchildpids(pid, nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 8)
        let filled = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).filter { $0 > 0 }
    }

    static func tcpSockets(_ pid: pid_t) -> [(local: UInt16, remote: UInt16)] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
        guard filled > 0 else { return [] }
        var result: [(local: UInt16, remote: UInt16)] = []
        for descriptor in descriptors.prefix(Int(filled) / stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
                  info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let ports = info.psi.soi_proto.pri_tcp.tcpsi_ini
            // Network byte order, in the low 16 bits.
            let local = UInt16(bigEndian: UInt16(truncatingIfNeeded: ports.insi_lport))
            let remote = UInt16(bigEndian: UInt16(truncatingIfNeeded: ports.insi_fport))
            result.append((local, remote))
        }
        return result
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
