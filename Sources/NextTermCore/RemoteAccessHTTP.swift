import Foundation

/// HTTP/1.1 for the Remote access door: a parser with hard limits, the door's request checks in their order, and
/// the answers it sends. The door (RemoteAccessServer) owns the socket and the clocks; everything here is pure.
///
/// The parser is its own, not `IDEHTTP`'s or `GeminiIDEServer`'s: it caps the head at 16 KB and the body at 1 MB,
/// reads a body by `Content-Length` or chunked, compares header names without case, and refuses what other
/// parsers could read another way (both framings, two lengths, two Host headers, a bare CR or LF, a folded line).
public enum RemoteAccessHTTP {
    // MARK: limits

    /// The request line and every header line, the blank line that ends them included. Over it: 431.
    public static let maximumHead = 16 * 1024
    /// A request's body, however it is framed. Over it: 413, and on `/mcp` a JSON-RPC error that names the limit.
    public static let maximumBody = 1024 * 1024
    /// One chunk-size line of a chunked body, extensions and its CRLF included. Over it: 400.
    public static let maximumChunkLine = 1024
    /// The bytes a chunked body may spend on framing (size lines and the CRLF after each chunk) on top of the
    /// body itself. Over it: 413, so a body cut into one-byte chunks cannot cost six times its size.
    public static let maximumChunkFraming = 64 * 1024
    /// The most a connection's buffer holds: one whole request at every limit (head, body, framing, trailers).
    /// More than that while a request waits for its answer is a client sending too much; the door closes.
    public static let maximumBuffer = maximumHead + maximumBody + maximumChunkFraming + maximumHead

    /// Seconds a client has to send a request's head once it has begun. Enforced by the door.
    public static let headerDeadline: TimeInterval = 10
    /// Seconds a connection may sit between requests. Enforced by the door, and only between requests: never
    /// while a request waits for its answer.
    public static let idleDeadline: TimeInterval = 30

    /// What a tool call too large for the door gets, as a JSON-RPC error (R8). The local 5 MB limit of
    /// `write_file` stays as it is.
    public static let bodyLimitMessage = "Remote writes are limited to 1 MB. Send a smaller change, or make it on your Mac."

    // MARK: requests

    public struct Header: Equatable, Sendable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public struct Request: Equatable, Sendable {
        public var method: String
        /// The request target as sent: always starts with "/".
        public var target: String
        public var version: String
        /// In the order they came, names as sent.
        public var headers: [Header]
        public var body: Data

        public init(method: String, target: String, version: String = "HTTP/1.1", headers: [Header] = [], body: Data = Data()) {
            self.method = method
            self.target = target
            self.version = version
            self.headers = headers
            self.body = body
        }

        /// The target up to its "?", exactly as sent: nothing decoded, nothing folded.
        public var path: String {
            guard let mark = target.firstIndex(of: "?") else { return target }
            return String(target[..<mark])
        }

        /// The target after its "?", or nil without one.
        public var query: String? {
            guard let mark = target.firstIndex(of: "?") else { return nil }
            return String(target[target.index(after: mark)...])
        }

        /// Every value of this header, in order. Names compare without case.
        public func values(_ name: String) -> [String] {
            let wanted = name.lowercased()
            return headers.filter { $0.name.lowercased() == wanted }.map(\.value)
        }

        /// This header's values joined by ", ", or nil when it is absent.
        public func header(_ name: String) -> String? {
            let found = values(name)
            return found.isEmpty ? nil : found.joined(separator: ", ")
        }

        /// Whether the Accept header names `text/event-stream` with a weight above zero (KTD11). Wildcards do
        /// not count: a tool call answers as a stream only when the client names it.
        public var acceptsEventStream: Bool {
            let ranges = values("accept").flatMap { $0.split(separator: ",") }
            return ranges.contains { range in
                let parts = range.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                guard parts.first == "text/event-stream" else { return false }
                let weights = parts.dropFirst().filter { $0.hasPrefix("q=") }
                guard let weight = weights.first.flatMap({ Double($0.dropFirst(2)) }) else { return true }
                return weight > 0
            }
        }

        /// The forwarding headers, for the audit log only.
        public var forwarded: Forwarded {
            Forwarded(forwardedFor: header("x-forwarded-for"), connectingIP: header("cf-connecting-ip"),
                      ray: header("cf-ray"))
        }
    }

    /// What the tunnel says about the client, copied for the audit log (R7). No decision reads it: the door
    /// decides from the Host header and the token alone.
    public struct Forwarded: Equatable, Sendable {
        /// Each value is cut to this many characters.
        public static let maximumLength = 200

        public var forwardedFor: String?
        public var connectingIP: String?
        public var ray: String?

        public init(forwardedFor: String? = nil, connectingIP: String? = nil, ray: String? = nil) {
            self.forwardedFor = forwardedFor.map { String($0.prefix(Self.maximumLength)) }
            self.connectingIP = connectingIP.map { String($0.prefix(Self.maximumLength)) }
            self.ray = ray.map { String($0.prefix(Self.maximumLength)) }
        }
    }

    /// Why a request could not be read. The door answers `refusal(_:host:)` and closes.
    public struct Failure: Equatable, Sendable, Error {
        /// 400 (malformed), 413 (body too large) or 431 (head too large).
        public var status: Int
        /// The request's head, with no body, when it was read whole before the failure.
        public var request: Request?

        public init(status: Int, request: Request? = nil) {
            self.status = status
            self.request = request
        }
    }

    public enum Parsed: Equatable, Sendable {
        /// Not all of the next request has arrived.
        case needMore
        /// The next request, whole. Ask for the one after it only once this one is answered.
        case request(Request)
        /// The bytes are not a request this door reads. Every later call gives the same failure.
        case failure(Failure)
    }

    /// Where a connection's next request stands, for the door's deadlines.
    public enum Phase: Equatable, Sendable {
        /// No byte of the next request yet: the idle deadline applies.
        case idle
        /// Its head has begun: the header deadline applies.
        case head
        /// Its head is whole and its body is still arriving.
        case body
    }

    // MARK: the parser

    /// Feed it bytes with `append`, then call `next` for the next whole request. Requests come out one at a
    /// time, in order: a pipelined request waits in the buffer until the door asks for it.
    public struct Parser: Sendable {
        private enum Stage: Sendable {
            case head
            case length(Int)
            case chunkSize
            case chunkData(Int)
            case trailers
        }

        private var buffer: [UInt8] = []
        private var failed: Failure?
        private var stage = Stage.head
        /// Bytes of the current request read so far.
        private var cursor = 0
        /// How far past `cursor` the search for the current line's end has checked every byte.
        private var searched = 0
        private var request: Request?
        private var body: [UInt8] = []
        private var framing = 0
        private var trailerStart = 0

        public init() {}

        public var phase: Phase {
            switch stage {
            case .head: return buffer.isEmpty ? .idle : .head
            default: return .body
            }
        }

        /// Adds bytes that arrived. False when the buffer would pass `maximumBuffer`: the bytes are dropped, every
        /// later `next` fails with 413, and the door closes the connection.
        public mutating func append(_ data: Data) -> Bool {
            guard failed == nil else { return true }
            guard buffer.count + data.count <= RemoteAccessHTTP.maximumBuffer else {
                failed = Failure(status: 413)
                return false
            }
            buffer.append(contentsOf: data)
            return true
        }

        public mutating func next() -> Parsed {
            if let failed { return .failure(failed) }
            do {
                guard let request = try step() else { return .needMore }
                return .request(request)
            } catch let failure as Failure {
                failed = failure
                return .failure(failure)
            } catch {
                let failure = Failure(status: 400)
                failed = failure
                return .failure(failure)
            }
        }

        // MARK: stages

        private mutating func step() throws -> Request? {
            while true {
                switch stage {
                case .head:
                    guard try readHeadLine() else { return nil }
                case .length(let length):
                    guard buffer.count - cursor >= length else { return nil }
                    body = Array(buffer[cursor..<(cursor + length)])
                    cursor += length
                    return finish()
                case .chunkSize:
                    guard try readChunkSize() else { return nil }
                case .chunkData(let size):
                    guard buffer.count - cursor >= size + 2 else { return nil }
                    guard buffer[cursor + size] == 13, buffer[cursor + size + 1] == 10 else { throw bad() }
                    body.append(contentsOf: buffer[cursor..<(cursor + size)])
                    cursor += size + 2
                    stage = .chunkSize
                case .trailers:
                    guard try readTrailerLine() else { return nil }
                    if case .head = stage { return finish() }
                }
            }
        }

        /// One head line, if it has arrived. True when it was read and the stage may have moved on.
        private mutating func readHeadLine() throws -> Bool {
            let limit = RemoteAccessHTTP.maximumHead
            guard let line = try nextLine(limit: limit) else {
                if buffer.count >= limit { throw Failure(status: 431) }
                return false
            }
            guard var request else {
                guard !line.isEmpty else { throw bad() }
                self.request = try Self.requestLine(line)
                return true
            }
            guard line.isEmpty else {
                request.headers.append(try Self.headerLine(line))
                self.request = request
                return true
            }
            try startBody(of: request)
            return true
        }

        /// The head is whole: pick the body's framing from it.
        private mutating func startBody(of request: Request) throws {
            let hosts = request.values("host")
            guard hosts.count <= 1 else { throw bad() }
            let lengths = request.values("content-length")
            let codings = request.values("transfer-encoding")
            if !codings.isEmpty {
                guard lengths.isEmpty, request.version == "HTTP/1.1" else { throw bad() }
                let coding = codings.joined(separator: ",").trimmingCharacters(in: .whitespaces)
                guard coding.lowercased() == "chunked" else { throw bad() }
                stage = .chunkSize
                return
            }
            guard !lengths.isEmpty else {
                stage = .length(0)
                return
            }
            let length = try Self.contentLength(lengths, request: request)
            stage = .length(length)
        }

        private mutating func readChunkSize() throws -> Bool {
            let start = cursor
            guard let line = try nextLine(limit: start + RemoteAccessHTTP.maximumChunkLine) else {
                if buffer.count - start >= RemoteAccessHTTP.maximumChunkLine { throw bad() }
                return false
            }
            framing += cursor - start + 2
            guard framing <= RemoteAccessHTTP.maximumChunkFraming else { throw tooLarge() }
            let size = try chunkSize(line)
            if size == 0 {
                trailerStart = cursor
                stage = .trailers
            } else {
                stage = .chunkData(size)
            }
            return true
        }

        private func chunkSize(_ line: [UInt8]) throws -> Int {
            let semicolon = line.firstIndex(of: 59) ?? line.count
            var digits = line[..<semicolon]
            // Spaces or tabs may stand before the ";", never before the size.
            while let last = digits.last, last == 32 || last == 9 { digits.removeLast() }
            guard !digits.isEmpty, digits.allSatisfy(Self.isHexDigit) else { throw bad() }
            let significant = digits.drop { $0 == 48 }
            guard significant.count <= 8 else { throw tooLarge() }
            var size = 0
            for digit in significant {
                size = size * 16 + Self.hexValue(digit)
            }
            guard size <= RemoteAccessHTTP.maximumBody - body.count else { throw tooLarge() }
            return size
        }

        /// One trailer line, if it has arrived. Trailers are read and dropped: no decision reads them.
        private mutating func readTrailerLine() throws -> Bool {
            let limit = trailerStart + RemoteAccessHTTP.maximumHead
            guard let line = try nextLine(limit: limit) else {
                if buffer.count >= limit { throw Failure(status: 431, request: request) }
                return false
            }
            if line.isEmpty {
                stage = .head
            } else {
                _ = try Self.headerLine(line)
            }
            return true
        }

        /// The request is whole: hand it out and keep what follows it.
        private mutating func finish() -> Request? {
            guard var request else { return nil }
            request.body = Data(body)
            buffer.removeFirst(cursor)
            stage = .head
            cursor = 0
            searched = 0
            self.request = nil
            body = []
            framing = 0
            trailerStart = 0
            return request
        }

        // MARK: lines

        /// The next CRLF-ended line from `cursor`, without its CRLF, if its LF is in the buffer before byte
        /// `limit`. Every byte is checked on the way, once: a control byte, a bare CR or a bare LF fails at once.
        private mutating func nextLine(limit: Int) throws -> [UInt8]? {
            let end = min(buffer.count, limit)
            var index = cursor + searched
            while index < end {
                let byte = buffer[index]
                if byte == 10 {
                    guard index > cursor, buffer[index - 1] == 13 else { throw bad() }
                    let line = Array(buffer[cursor..<(index - 1)])
                    cursor = index + 1
                    searched = 0
                    return line
                }
                if byte == 13 {
                    // A CR must end its line; wait for the byte after it.
                    guard index + 1 < buffer.count else { break }
                    guard buffer[index + 1] == 10 else { throw bad() }
                } else if Self.isControl(byte) {
                    throw bad()
                }
                index += 1
            }
            searched = index - cursor
            return nil
        }

        private func bad() -> Failure {
            Failure(status: 400, request: headIfWhole)
        }

        private func tooLarge() -> Failure {
            Failure(status: 413, request: headIfWhole)
        }

        /// The head, once it was read whole.
        private var headIfWhole: Request? {
            if case .head = stage { return nil }
            return request
        }

        // MARK: the head's parts

        private static func requestLine(_ line: [UInt8]) throws -> Request {
            let parts = line.split(separator: 32, omittingEmptySubsequences: false)
            guard parts.count == 3 else { throw Failure(status: 400) }
            let method = parts[0], target = parts[1], version = parts[2]
            guard !method.isEmpty, method.allSatisfy(isTokenByte) else { throw Failure(status: 400) }
            guard target.first == 47, target.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw Failure(status: 400) }
            let versionText = String(decoding: version, as: UTF8.self)
            guard versionText == "HTTP/1.1" || versionText == "HTTP/1.0" else { throw Failure(status: 400) }
            return Request(method: String(decoding: method, as: UTF8.self), target: String(decoding: target, as: UTF8.self),
                           version: versionText)
        }

        private static func headerLine(_ line: [UInt8]) throws -> Header {
            guard let colon = line.firstIndex(of: 58) else { throw Failure(status: 400) }
            let name = line[..<colon]
            // No empty name, no space before the colon, no folded line.
            guard !name.isEmpty, name.allSatisfy(isTokenByte) else { throw Failure(status: 400) }
            guard let value = String(bytes: line[(colon + 1)...], encoding: .utf8) else { throw Failure(status: 400) }
            let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            return Header(name: String(decoding: name, as: UTF8.self), value: trimmed)
        }

        /// Every Content-Length value, lists included, must be the same plain decimal number.
        private static func contentLength(_ values: [String], request: Request) throws -> Int {
            let items = values.flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
            let numbers = items.map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = numbers.first else { throw Failure(status: 400, request: request) }
            for number in numbers {
                let digits = number.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
                guard !number.isEmpty, digits, number == first else { throw Failure(status: 400, request: request) }
            }
            let significant = first.drop { $0 == "0" }
            guard significant.count <= 9, let length = Int(first), length <= RemoteAccessHTTP.maximumBody else {
                throw Failure(status: 413, request: request)
            }
            return length
        }

        // MARK: bytes

        private static let tokenSymbols = Set("!#$%&'*+-.^_`|~".utf8)

        /// RFC 9110's tchar.
        private static func isTokenByte(_ byte: UInt8) -> Bool {
            switch byte {
            case 48...57, 65...90, 97...122: return true
            default: return tokenSymbols.contains(byte)
            }
        }

        /// A byte no head line may hold: controls but the tab (CR and LF are checked as line ends).
        private static func isControl(_ byte: UInt8) -> Bool {
            (byte < 32 && byte != 9) || byte == 127
        }

        private static func isHexDigit(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }

        private static func hexValue(_ byte: UInt8) -> Int {
            switch byte {
            case 48...57: return Int(byte - 48)
            case 65...70: return Int(byte - 55)
            default: return Int(byte - 87)
            }
        }
    }

    // MARK: the checks

    /// The doors the door answers (R4, the plan's Endpoints table).
    public enum Route: Equatable, Sendable, CaseIterable {
        case mcp
        case protectedResource
        case authorizationServer
        case register
        case authorize
        case authorizeWait
        case token
        case revoke

        /// The route for a path, compared exactly: nothing decoded, no trailing slash, case kept.
        public init?(path: String) {
            switch path {
            case "/mcp": self = .mcp
            case "/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp":
                self = .protectedResource
            case "/.well-known/oauth-authorization-server": self = .authorizationServer
            case "/oauth/register": self = .register
            case "/oauth/authorize": self = .authorize
            case "/oauth/authorize/wait": self = .authorizeWait
            case "/oauth/token": self = .token
            case "/oauth/revoke": self = .revoke
            default: return nil
            }
        }

        /// The one method each door takes. GET and DELETE on `/mcp` get 405 (KTD10: no session, no GET stream).
        public var method: String {
            switch self {
            case .mcp, .register, .token, .revoke: return "POST"
            case .protectedResource, .authorizationServer, .authorize, .authorizeWait: return "GET"
            }
        }
    }

    public enum Checked: Equatable, Sendable {
        case route(Route)
        /// Answer `answer` and close. `allow` is the method a 405 names.
        case refused(status: Int, allow: [String])

        /// What to send for a refusal; nil for a route.
        public var answer: Data? {
            guard case .refused(let status, let allow) = self else { return nil }
            return RemoteAccessHTTP.refusal(status: status, allow: allow)
        }
    }

    /// The door's rules, in order: Host (421), Origin (403), path (404), method (405). `host` is the saved public
    /// hostname; until there is one, every request gets 421. No rule reads the peer address or a forwarding
    /// header (R7).
    public static func check(_ request: Request, host: String?) -> Checked {
        let hosts = request.values("host")
        guard hosts.count == 1, hostMatches(hosts[0], host: host) else { return .refused(status: 421, allow: []) }
        guard request.values("origin").isEmpty else { return .refused(status: 403, allow: []) }
        guard let route = Route(path: request.path) else { return .refused(status: 404, allow: []) }
        guard request.method == route.method else { return .refused(status: 405, allow: [route.method]) }
        return .route(route)
    }

    /// Whether a Host value names the saved hostname: both lowercased, an optional ":443" dropped, then equal.
    /// Loopback, another port, a trailing dot and every other value fail.
    public static func hostMatches(_ value: String?, host: String?) -> Bool {
        guard let value, let host else { return false }
        let wanted = normalizedHost(host)
        return !wanted.isEmpty && normalizedHost(value) == wanted
    }

    private static func normalizedHost(_ value: String) -> String {
        let lower = value.lowercased()
        return lower.hasSuffix(":443") ? String(lower.dropLast(4)) : lower
    }

    // MARK: answers

    public static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Content Too Large"
        case 421: return "Misdirected Request"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }

    /// A whole answer with its length. It never carries a `Server` header or a CORS header (R4, R6): those are
    /// dropped, and so are a length, a framing or a `Connection` passed in, and any header that is not one line.
    /// `close`: the connection ends after it.
    public static func response(status: Int, headers: [(String, String)] = [], body: Data = Data(),
                                close: Bool = false) -> Data {
        var head = "HTTP/1.1 \(status) \(reason(status))\r\n"
        head += "Content-Length: \(body.count)\r\n"
        for (name, value) in allowed(headers, reserved: []) {
            head += "\(name): \(value)\r\n"
        }
        if close { head += "Connection: close\r\n" }
        return Data((head + "\r\n").utf8) + body
    }

    /// A JSON answer.
    public static func json(status: Int, body: Data, headers: [(String, String)] = [], close: Bool = false) -> Data {
        var all = [("Content-Type", "application/json")]
        all += allowed(headers, reserved: ["content-type"])
        return response(status: status, headers: all, body: body, close: close)
    }

    /// A refusal: the status, no body, and the connection closes. A 405 names the method its door takes.
    public static func refusal(status: Int, allow: [String] = []) -> Data {
        let headers = allow.isEmpty ? [] : [("Allow", allow.joined(separator: ", "))]
        return response(status: status, headers: headers, close: true)
    }

    /// The answer to a request that could not be read. When its head was read, the checks answer first, so a
    /// wrong Host still gets 421. A body over the limit on `/mcp` gets a JSON-RPC error that names the limit
    /// (R8); its id is null, because the body that holds the id is never read.
    public static func refusal(_ failure: Failure, host: String?) -> Data {
        guard let request = failure.request else { return refusal(status: failure.status) }
        let checked = check(request, host: host)
        if let answer = checked.answer { return answer }
        guard failure.status == 413, checked == .route(.mcp) else { return refusal(status: failure.status) }
        return json(status: 413, body: bodyLimitError, close: true)
    }

    private static var bodyLimitError: Data {
        var error: [String: Any] = [:]
        error["code"] = -32600
        error["message"] = bodyLimitMessage
        var message: [String: Any] = [:]
        message["jsonrpc"] = "2.0"
        message["id"] = NSNull()
        message["error"] = error
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        return (try? JSONSerialization.data(withJSONObject: message, options: options)) ?? Data()
    }

    /// The head of an event stream (KTD11). It has no length and no chunking: the body ends when the
    /// connection closes, so the door closes it after the result.
    public static func streamHead(headers: [(String, String)] = []) -> Data {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/event-stream\r\n"
        head += "Cache-Control: no-cache, no-transform\r\n"
        head += "X-Accel-Buffering: no\r\n"
        let reserved: Set<String> = ["content-type", "cache-control", "x-accel-buffering"]
        for (name, value) in allowed(headers, reserved: reserved) {
            head += "\(name): \(value)\r\n"
        }
        head += "Connection: close\r\n"
        return Data((head + "\r\n").utf8)
    }

    /// One JSON-RPC message as an event: `event: message`, then a `data:` line for each of its lines.
    public static func event(_ json: Data) -> Data {
        let text = String(decoding: json, as: UTF8.self)
        let lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
        var frame = "event: message\n"
        for line in lines {
            frame += "data: \(line)\n"
        }
        return Data((frame + "\n").utf8)
    }

    /// The comment a stream sends every 20 seconds while a call runs (R25).
    public static let keepAlive = Data(": keep-alive\n\n".utf8)

    /// The headers an answer may carry: never `Server`, CORS, a length, a framing or `Connection` (the builders
    /// set those), nor one that `reserved` names, nor one that is not a single clean line.
    private static func allowed(_ headers: [(String, String)], reserved: Set<String>) -> [(String, String)] {
        let builderOwned: Set<String> = ["server", "content-length", "transfer-encoding", "connection"]
        return headers.filter { name, value in
            let lower = name.lowercased()
            guard !builderOwned.contains(lower), !reserved.contains(lower) else { return false }
            guard !lower.hasPrefix("access-control-") else { return false }
            let nameIsToken = !name.isEmpty && name.unicodeScalars.allSatisfy { isTokenScalar($0) }
            let valueIsOneLine = !value.unicodeScalars.contains { $0.value < 32 && $0 != "\t" }
            return nameIsToken && valueIsOneLine
        }
    }

    private static func isTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.isASCII else { return false }
        if CharacterSet.alphanumerics.contains(scalar) { return true }
        return "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar)
    }
}
