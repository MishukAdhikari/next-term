import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The one-shot loopback listener a sign-in's browser comes back to (RFC 8252 §7.3): `http://127.0.0.1:<port>/callback`,
/// bound to 127.0.0.1, and to ::1 at the same port when it's free (a callback registered as `localhost` reaches it
/// whichever address the browser tries first), one per sign-in, closed after the callback or after its life: at the port its client was
/// registered with when it's free (a server may hold the redirect to it), else at one the system picks.
///
/// - Only `GET /callback` whose query `accepts` takes (its `state` is this sign-in's) ends the wait; it is answered
///   with the small page `accepts` gives. Anything else gets a 404 and the wait goes on, so a stray request or a
///   guessed URL never ends a sign-in.
/// - One request a connection, its head read up to 16 KB, two seconds in all to send it.
public final class MCPHubLoopback: @unchecked Sendable {
    /// The page for a request's query, and whether it ends the wait; nil when the query isn't this sign-in's.
    public typealias Accepts = @Sendable ([(String, String)]) -> String?

    public static let life: TimeInterval = 600
    /// How long a connection has to send its request's head.
    static let headTime: TimeInterval = 2

    private let lock = NSLock()
    private var listener: Int32 = -1
    /// The same port on ::1, when it could be had: -1 otherwise.
    private var listener6: Int32 = -1
    public private(set) var port: UInt16 = 0
    private let accepts: Accepts
    private let arrived = DispatchSemaphore(value: 0)
    private var query: [(String, String)]?
    private var ended = false
    /// Requests that didn't end the wait, for the tests.
    public private(set) var strays = 0

    /// `port`: the one to listen on if it's free (0, or taken: one the system picks). `strict`: that port or none, for a
    /// callback the provider holds to its port.
    public init(port wanted: UInt16 = 0, strict: Bool = false, accepts: @escaping Accepts) throws {
        self.accepts = accepts
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        func open(_ port: UInt16) -> Int32 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return -1 }
            // A port this Mac's last sign-in left in TIME_WAIT can be listened on again; one another program listens on
            // can't (that would take SO_REUSEPORT).
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            address.sin_port = port.bigEndian
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0, listen(fd, 8) == 0 else { Darwin.close(fd); return -1 }
            return fd
        }
        listener = wanted == 0 ? -1 : open(wanted)
        if listener < 0, !strict { listener = open(0) }
        guard listener >= 0 else { throw POSIXError(.EADDRINUSE) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) }
        }
        port = UInt16(bigEndian: address.sin_port)
        listener6 = Self.open6(port)
        for fd in [listener, listener6] where fd >= 0 { serveAll(fd) }
    }

    /// A listener on [::1]:`port` (IPv6 only), or -1 when the port is taken there or the Mac has no IPv6 loopback.
    static func open6(_ port: UInt16) -> Int32 {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_loopback
        address.sin6_port = port.bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { Darwin.close(fd); return -1 }
        return fd
    }

    private func serveAll(_ fd: Int32) {
        Thread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { if errno == EINTR { continue } else { return } }
                guard let self else { Darwin.close(client); return }
                self.serve(client)
            }
        }.start()
    }

    deinit { close() }

    /// The redirect URI for this listener.
    public var redirect: String { "http://127.0.0.1:\(port)/callback" }

    /// The callback's query, once it comes; nil when `deadline` passed or the listener was closed first.
    public func wait(until deadline: Date) -> [(String, String)]? {
        _ = arrived.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow))
        lock.lock()
        defer { lock.unlock() }
        return query
    }

    /// Stops listening; a wait ends with nil.
    public func close() {
        lock.lock()
        let fds = [listener, listener6]
        listener = -1
        listener6 = -1
        let wasEnded = ended
        ended = true
        lock.unlock()
        for fd in fds where fd >= 0 { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        if !wasEnded { arrived.signal() }
    }

    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listener < 0
    }

    private func serve(_ fd: Int32) {
        defer { Darwin.close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        // Two seconds for the whole head, not for each read: a connection sending a byte now and then would otherwise
        // hold the one thread that serves, and the browser's callback behind it, until the sign-in's life ran out.
        let deadline = Date().addingTimeInterval(Self.headTime)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 16 * 1024, data.range(of: Data("\r\n\r\n".utf8)) == nil {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { break }
            var wait = timeval(tv_sec: Int(left), tv_usec: Int32((left - left.rounded(.down)) * 1_000_000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        let line = String(decoding: data.prefix(while: { $0 != 0x0D && $0 != 0x0A }), as: UTF8.self).split(separator: " ")
        guard line.count >= 2, line[0] == "GET", let parts = URLComponents(string: String(line[1])), parts.path == "/callback" else {
            return stray(fd)
        }
        let query = MCPHubOAuth.decodeForm(parts.percentEncodedQuery ?? "")
        lock.lock()
        let done = ended
        lock.unlock()
        guard !done, let page = accepts(query) else { return stray(fd) }
        Self.send(fd, status: "200 OK", type: "text/html; charset=utf-8", body: page)
        lock.lock()
        self.query = query
        ended = true
        let listening = [listener, listener6]
        listener = -1
        listener6 = -1
        lock.unlock()
        for fd in listening where fd >= 0 { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        arrived.signal()
    }

    private func stray(_ fd: Int32) {
        lock.lock()
        strays += 1
        lock.unlock()
        Self.send(fd, status: "404 Not Found", type: "text/plain; charset=utf-8", body: "Not found.")
    }

    static func send(_ fd: Int32, status: String, type: String, body: String) {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\n"
            + "Referrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        let all = Data(head.utf8) + bytes
        all.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    /// The callback's page: one sentence, as plain as the browser shows it.
    public static func page(_ sentence: String) -> String {
        let escaped = sentence.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<!doctype html><html><head><meta charset=\"utf-8\"><title>Next Term</title>"
            + "<style>body{font:15px -apple-system,system-ui,sans-serif;margin:20vh auto;max-width:28em;padding:0 1em;color:#1d1d1f}"
            + "@media(prefers-color-scheme:dark){body{background:#1e1e1e;color:#f5f5f7}}</style></head>"
            + "<body><p>\(escaped)</p></body></html>"
    }
}
