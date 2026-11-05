#if DEBUG
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A fake remote MCP server on this Mac, for the unit tests and the self-test (debug builds only): Streamable HTTP on
/// 127.0.0.1 at a port of its own, one request a connection. Its tools: `echo` (says hello, with `said` back), `big`
/// (300,000 characters) and `slow` (answers after `slowSeconds`). What it does otherwise is set on it:
///
/// - `bearer`: the key it wants as `Authorization: Bearer …`; any other gets a 401 with a WWW-Authenticate.
/// - `sessions`: it gives an Mcp-Session-Id at initialize and wants it on every request after; `endSessions()` forgets
///   them, so the next request gets a 404.
/// - `stream`: a tools/call is answered as an event stream, a notification and a ping of its own before the answer.
/// - `version`: the MCP version it answers (default: the one asked, when it is 2025-06-18 or newer, else 2025-06-18).
/// - `redirect`: every POST is answered 307 to this URL.
///
/// `seen` keeps each request's method and headers (names lowercased), for the tests to look at.
public final class MCPHubFakeRemote: @unchecked Sendable {
    public struct Seen: Sendable {
        public let method: String
        public let headers: [String: String]
        public let body: String
    }

    public var bearer: String?
    public var sessions = false
    public var stream = false
    public var version: String?
    public var redirect: String?
    public var slowSeconds: Double = 5

    private let lock = NSLock()
    private var listener: Int32 = -1
    public private(set) var port: UInt16 = 0
    private var known = Set<String>()
    private var seenList: [Seen] = []

    public init() throws {
        listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 16) == 0 else { close(listener); throw POSIXError(.EADDRINUSE) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) }
        }
        port = UInt16(bigEndian: address.sin_port)
        let fd = listener
        let thread = Thread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { if errno == EINTR { continue } else { return } }
                guard let self else { close(client); return }
                Thread { self.serve(client) }.start() // its own thread: a busy test run's queues never hold it up
            }
        }
        thread.start()
    }

    deinit { stop() }

    public var url: URL { URL(string: "http://127.0.0.1:\(port)/mcp")! }

    public func stop() {
        lock.lock()
        let fd = listener
        listener = -1
        lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
    }

    public var seen: [Seen] {
        lock.lock()
        defer { lock.unlock() }
        return seenList
    }

    public func endSessions() {
        lock.lock()
        known = []
        lock.unlock()
    }

    // MARK: serving

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        var head: [String] = []
        var bodyStart = 0
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { return }
            data.append(contentsOf: buffer[0..<count])
            if let end = data.range(of: Data("\r\n\r\n".utf8)) {
                head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                bodyStart = end.upperBound
                break
            }
        }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        while data.count - bodyStart < length {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        let body = data.count > bodyStart ? Data(data[bodyStart...]) : Data()
        let verb = head.first?.split(separator: " ").first.map(String.init) ?? ""
        let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let method = verb == "POST" ? (message["method"] as? String ?? "(answer)") : verb
        lock.lock()
        seenList.append(Seen(method: method, headers: headers, body: String(decoding: body, as: UTF8.self)))
        lock.unlock()

        if let redirect { return send(fd, status: "307 Temporary Redirect", headers: ["Location": redirect], body: "") }
        if let bearer, headers["authorization"] != "Bearer \(bearer)" {
            return send(fd, status: "401 Unauthorized",
                        headers: ["WWW-Authenticate": #"Bearer resource_metadata="http://127.0.0.1/.well-known/oauth-protected-resource""#],
                        body: "")
        }
        guard verb == "POST" else { return send(fd, status: verb == "DELETE" ? "200 OK" : "405 Method Not Allowed", headers: [:], body: "") }
        var extra: [String: String] = [:]
        if sessions {
            if method == "initialize" {
                let id = UUID().uuidString
                lock.lock()
                known.insert(id)
                lock.unlock()
                extra["Mcp-Session-Id"] = id
            } else {
                lock.lock()
                let isKnown = headers["mcp-session-id"].map { known.contains($0) } ?? false
                lock.unlock()
                guard headers["mcp-session-id"] != nil else { return send(fd, status: "400 Bad Request", headers: [:], body: "no session") }
                guard isKnown else { return send(fd, status: "404 Not Found", headers: [:], body: "") }
            }
        }
        guard let id = message["id"], message["method"] != nil else {
            return send(fd, status: "202 Accepted", headers: extra, body: "") // a notification, or an answer to its ping
        }
        let params = message["params"] as? [String: Any] ?? [:]
        let result: Any
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            let answered = version ?? (["2025-11-25", "2025-06-18"].contains(asked) ? asked : "2025-06-18")
            result = ["protocolVersion": answered, "capabilities": ["tools": [String: Any]()],
                      "serverInfo": ["name": "fake-remote", "version": "1"]]
        case "tools/list":
            result = ["tools": [
                ["name": "echo", "description": "Says hello back", "inputSchema": ["type": "object"]],
                ["name": "big", "description": "A long answer", "inputSchema": ["type": "object"]],
                ["name": "slow", "description": "Answers late", "inputSchema": ["type": "object"]],
            ]]
        case "tools/call":
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            switch params["name"] as? String {
            case "echo":
                result = ["content": [["type": "text", "text": "hello from remote"]], "structuredContent": ["said": arguments["say"] ?? ""]]
            case "big": result = ["content": [["type": "text", "text": String(repeating: "a", count: 300_000)]]]
            case "slow":
                Thread.sleep(forTimeInterval: slowSeconds)
                result = ["content": [["type": "text", "text": "late"]]]
            default: result = ["content": [["type": "text", "text": "no such tool"]], "isError": true]
            }
        default:
            return answer(fd, ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "no \(method)"]], extra: extra)
        }
        let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        if stream, method == "tools/call" {
            let events = [["jsonrpc": "2.0", "method": "notifications/progress", "params": ["progress": 1]],
                          ["jsonrpc": "2.0", "id": "server-1", "method": "ping"], reply]
            let text = events.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
                .map { "event: message\ndata: " + String(decoding: $0, as: UTF8.self) + "\n\n" }.joined()
            var all = extra
            all["Content-Type"] = "text/event-stream"
            return send(fd, status: "200 OK", headers: all, body: text)
        }
        answer(fd, reply, extra: extra)
    }

    private func answer(_ fd: Int32, _ message: [String: Any], extra: [String: String]) {
        let text = (try? JSONSerialization.data(withJSONObject: message)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var all = extra
        all["Content-Type"] = "application/json"
        send(fd, status: "200 OK", headers: all, body: text)
    }

    private func send(_ fd: Int32, status: String, headers: [String: String], body: String) {
        var text = "HTTP/1.1 \(status)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n"
        for (key, value) in headers { text += "\(key): \(value)\r\n" }
        text += "\r\n" + body
        let data = Data(text.utf8)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }
}
#endif
