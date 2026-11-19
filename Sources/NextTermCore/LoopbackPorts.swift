import Foundation

/// Answers whether something listens on a port of this Mac: one TCP connect to the loopback address, closed at once.
public protocol PortConnector: Sendable {
    func answers(host: String, port: Int, timeout: TimeInterval) -> Bool
}

/// The "is it up" look of the Services rows (plan 044, item 3): for each local row with a port on this Mac, one
/// connect to 127.0.0.1 and then ::1, with a short timeout, each port once. It runs when asked (the sidebar shows the
/// group, the window comes forward, a tab's served address changes), never on a timer, and never off this Mac.
public enum LoopbackPorts {
    /// How long one connect may wait. A loopback port that is closed refuses at once; this only bounds a stuck one.
    public static let timeout: TimeInterval = 0.25

    /// The addresses tried, in order: IPv4's loopback, then IPv6's (a server that binds `::1` alone).
    public static let hosts = ["127.0.0.1", "::1"]

    /// Each row's port, for a row on this Mac whose main link names a port on a loopback host. A `.test` site, a
    /// remote server or a link without a port has none.
    public static func ports(_ rows: [ServiceRow]) -> [String: Int] {
        var ports: [String: Int] = [:]
        for row in rows where row.isLocal {
            guard let port = row.link.url.port, let host = row.link.url.host, isLoopback(host) else { continue }
            ports[row.id] = port
        }
        return ports
    }

    /// A host that is this Mac itself: `localhost`, 127.0.0.0/8, `::1`, or the any-address a server binds.
    public static func isLoopback(_ host: String) -> Bool {
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host == "localhost" || host == "::1" || host == "0.0.0.0" || DatabaseEnvironment.isLoopbackIPv4(host)
    }

    /// The ids of the rows whose port answers. Each port is tried once, however many rows share it, the ports side by
    /// side. Call it off the main thread: a stuck port waits `timeout` per address.
    public static func check(_ rows: [ServiceRow], connector: PortConnector = SocketConnector()) -> Set<String> {
        let byRow = ports(rows)
        let unique = Array(Set(byRow.values)).sorted()
        guard !unique.isEmpty else { return [] }
        let answers = Answers(count: unique.count)
        DispatchQueue.concurrentPerform(iterations: unique.count) { (index: Int) in
            let port = unique[index]
            let up = hosts.contains { (host: String) -> Bool in connector.answers(host: host, port: port, timeout: timeout) }
            answers.set(index, up)
        }
        let open = Set(unique.enumerated().compactMap { (pair: (offset: Int, element: Int)) -> Int? in
            answers.get(pair.offset) ? pair.element : nil
        })
        return Set(byRow.compactMap { (pair: (key: String, value: Int)) -> String? in open.contains(pair.value) ? pair.key : nil })
    }

    /// Results written from several threads.
    private final class Answers: @unchecked Sendable {
        private var values: [Bool]
        private let lock = NSLock()
        init(count: Int) { values = Array(repeating: false, count: count) }
        func set(_ index: Int, _ value: Bool) { lock.withLock { values[index] = value } }
        func get(_ index: Int) -> Bool { lock.withLock { values[index] } }
    }
}

/// A non-blocking TCP connect, waited on with `poll` for at most the timeout, and closed whatever it gives. Nothing
/// is sent. Only loopback addresses are tried; any other host answers no.
public struct SocketConnector: PortConnector {
    public init() {}

    public func answers(host: String, port: Int, timeout: TimeInterval) -> Bool {
        guard (1...65535).contains(port) else { return false }
        if host == "127.0.0.1" {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(port).bigEndian)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            return withUnsafePointer(to: &address) { (pointer: UnsafePointer<sockaddr_in>) -> Bool in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { (raw: UnsafePointer<sockaddr>) -> Bool in
                    connect(AF_INET, raw, socklen_t(MemoryLayout<sockaddr_in>.size), timeout)
                }
            }
        }
        if host == "::1" {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(UInt16(port).bigEndian)
            address.sin6_addr = in6addr_loopback
            return withUnsafePointer(to: &address) { (pointer: UnsafePointer<sockaddr_in6>) -> Bool in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { (raw: UnsafePointer<sockaddr>) -> Bool in
                    connect(AF_INET6, raw, socklen_t(MemoryLayout<sockaddr_in6>.size), timeout)
                }
            }
        }
        return false
    }

    private func connect(_ family: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t,
                         _ timeout: TimeInterval) -> Bool {
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return false }
        if Darwin.connect(fd, address, length) == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var waiting = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&waiting, 1, Int32(max(1, timeout * 1000)))
        guard ready == 1 else { return false }
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else { return false }
        return error == 0
    }
}
