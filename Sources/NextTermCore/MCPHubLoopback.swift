import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The one-shot loopback listener a sign-in's browser comes back to (RFC 8252 §7.3): `http://127.0.0.1:<port>/callback`,
/// bound to 127.0.0.1 only, at a port the system picks, one per sign-in, closed after the callback or after its life.
///
/// - Only `GET /callback` whose query `accepts` takes (its `state` is this sign-in's) ends the wait; it is answered
///   with the small page `accepts` gives. Anything else gets a 404 and the wait goes on, so a stray request or a
///   guessed URL never ends a sign-in.
/// - One request a connection, its head read up to 16 KB, two seconds to send it.
public final class MCPHubLoopback: @unchecked Sendable {
    /// The page for a request's query, and whether it ends the wait; nil when the query isn't this sign-in's.
    public typealias Accepts = @Sendable ([(String, String)]) -> String?

    public static let life: TimeInterval = 600

    private let lock = NSLock()
    private var listener: Int32 = -1
    public private(set) var port: UInt16 = 0
    private let accepts: Accepts
    private let arrived = DispatchSemaphore(value: 0)
    private var query: [(String, String)]?
    private var ended = false
    /// Requests that didn't end the wait, for the tests.
    public private(set) var strays = 0

    public init(accepts: @escaping Accepts) throws {
        self.accepts = accepts
        listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 8) == 0 else { Darwin.close(listener); throw POSIXError(.EADDRINUSE) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) }
        }
        port = UInt16(bigEndian: address.sin_port)
        let fd = listener
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
        let fd = listener
        listener = -1
        let wasEnded = ended
        ended = true
        lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
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
        var wait = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 16 * 1024, data.range(of: Data("\r\n\r\n".utf8)) == nil {
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
        let listening = listener
        listener = -1
        lock.unlock()
        if listening >= 0 { shutdown(listening, SHUT_RDWR); Darwin.close(listening) }
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
