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
    /// More than that while a request waits for its answer is a client sending too much: the bytes past it are
    /// dropped, what arrived whole still comes out, and then the door answers 413 and closes.
    public static let maximumBuffer = maximumHead + maximumBody + maximumChunkFraming + maximumHead

    /// Seconds a client has to send a request's head once it has begun, and a new connection its first one from
    /// when it opened. Enforced by the door.
    public static let headerDeadline: TimeInterval = 10
    /// Seconds a request's body has to arrive once its head is whole: 1 MB in 30 seconds is about 35 KB a second.
    /// Enforced by the door, so a body that trickles in cannot hold a connection.
    public static let bodyDeadline: TimeInterval = 30
    /// Seconds a connection may sit between requests. Enforced by the door, and only between requests: never
    /// while a request waits for its answer.
    public static let idleDeadline: TimeInterval = 30

    /// What a tool call too large for the door gets, as a JSON-RPC error (R8). The local 5 MB limit of
    /// `write_file` stays as it is.
    public static let bodyLimitMessage = "Remote writes are limited to 1 MB. Send a smaller change, or make it on your Mac."

    // MARK: requests

    public struct Header: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
        CustomReflectable {
        /// Headers whose values never show in a description or a mirror, so a careless log line cannot leak a
        /// token (R39).
        public static let hiddenNames: Set<String> = ["authorization", "proxy-authorization", "cookie"]

        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }

        /// The value, or "(hidden)" for a header `hiddenNames` lists.
        var shownValue: String {
            Self.hiddenNames.contains(name.lowercased()) ? "(hidden)" : value
        }

        public var description: String { "\(name): \(shownValue)" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["name": name, "value": shownValue]) }
    }

    public struct Request: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
        CustomReflectable {
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
        /// not count, and neither does a weight that is not a qvalue: a tool call answers as a stream only when
        /// the client names it plainly.
        public var acceptsEventStream: Bool {
            let ranges = values("accept").flatMap { $0.split(separator: ",") }
            return ranges.contains { range in
                let parts = range.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                guard parts.first == "text/event-stream" else { return false }
                let weights = parts.dropFirst().compactMap(Self.weight)
                guard let weight = weights.first else { return true }
                guard let thousandths = RemoteAccessHTTP.qvalue(weight) else { return false }
                return thousandths > 0
            }
        }

        /// A parameter's value when its name is "q", spaces around the name allowed.
        private static func weight(_ parameter: String) -> Substring? {
            guard let equals = parameter.firstIndex(of: "=") else { return nil }
            let name = parameter[..<equals].trimmingCharacters(in: .whitespaces)
            return name == "q" ? parameter[parameter.index(after: equals)...] : nil
        }

        /// The forwarding headers, for the audit log only.
        public var forwarded: Forwarded {
            Forwarded(forwardedFor: header("x-forwarded-for"), connectingIP: header("cf-connecting-ip"),
                      ray: header("cf-ray"))
        }

        /// For a log line: the method, the path, the headers as `Header` shows them, and the body's size. The
        /// query and the body never show, since either may hold a token or a code (R39).
        public var description: String {
            let lines = headers.map(\.description).joined(separator: ", ")
            return "\(method) \(shownTarget) \(version) [\(lines)] body: \(body.count) bytes"
        }

        public var debugDescription: String { description }

        public var customMirror: Mirror {
            let children: KeyValuePairs<String, Any> = [
                "method": method, "target": shownTarget, "version": version, "headers": headers,
                "bodySize": body.count,
            ]
            return Mirror(self, children: children)
        }

        /// The path, with "?…" in place of a query.
        private var shownTarget: String {
            query == nil ? path : path + "?…"
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
    public struct Failure: Equatable, Sendable, Error, CustomStringConvertible, CustomDebugStringConvertible {
        /// 400 (malformed), 413 (body too large) or 431 (head too large).
        public var status: Int
        /// The request's head, with no body, when it was read whole before the failure.
        public var request: Request?

        public init(status: Int, request: Request? = nil) {
            self.status = status
            self.request = request
        }

        /// The status, then the head as `Request` shows it, when there is one.
        public var description: String {
            guard let request else { return "\(status)" }
            return "\(status) \(request)"
        }

        public var debugDescription: String { description }
    }

    public enum Parsed: Equatable, Sendable {
        /// Not all of the next request has arrived.
        case needMore
        /// The next request's head, whole, before any of its body is read. Check it now (and the door reads its
        /// token), so a refusal goes out and the connection closes before the body arrives. Every request comes
        /// out this way first, with a body or not, and then as `request`.
        case head(Request)
        /// The next request, whole. Ask for the one after it only once this one is answered.
        case request(Request)
        /// The bytes are not a request this door reads. Every later call gives the same failure.
        case failure(Failure)
    }

    /// Where a connection stands, for the door's deadlines.
    public enum Phase: Equatable, Sendable {
        /// Between requests, with no byte of the next one yet: the idle deadline applies.
        case idle
        /// Its head has begun, or the connection is new and its first request has not come whole: the header
        /// deadline applies (R8).
        case head
        /// Its head was handed out and its body is still arriving: the body deadline applies.
        case body
        /// A request was handed out whole and the door has not asked for the next one, so it waits for its
        /// answer: no deadline applies, whatever is buffered behind it.
        case answering
    }

    // MARK: the parser

    /// Feed it bytes with `append`, then call `next`. Each request comes out twice: first its head, as soon as it
    /// is whole, so the door can refuse it before reading the body; then whole. Requests come out one at a time,
    /// in order: a pipelined request waits in the buffer until the door asks for it, and asking means the one
    /// before it was answered.
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
        /// A request was handed out whole, and `next` has not been called since.
        private var answering = false
        /// A request was handed out whole: the connection is no longer new.
        private var served = false
        /// Bytes past `maximumBuffer` were dropped.
        private var overflowed = false

        public init() {}

        public var phase: Phase {
            if answering { return .answering }
            switch stage {
            case .head: return buffer.isEmpty && served ? .idle : .head
            default: return .body
            }
        }

        /// Adds bytes that arrived. False when the buffer would pass `maximumBuffer`: the bytes past it are
        /// dropped, now and later, and the door stops reading. `next` still hands out what arrived whole, then
        /// fails with 413, carrying the head that was cut short when it was read.
        public mutating func append(_ data: Data) -> Bool {
            guard failed == nil else { return true }
            guard !overflowed else { return false }
            let room = RemoteAccessHTTP.maximumBuffer - buffer.count
            guard data.count > room else {
                buffer.append(contentsOf: data)
                return true
            }
            buffer.append(contentsOf: data.prefix(room))
            overflowed = true
            return false
        }

        /// The next head, request or failure. Calling it after a request means that request was answered.
        public mutating func next() -> Parsed {
            if let failed { return .failure(failed) }
            answering = false
            do {
                let parsed = try step()
                if parsed == .needMore, overflowed { throw tooLarge() }
                if case .request = parsed {
                    answering = true
                    served = true
                }
                return parsed
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

        private mutating func step() throws -> Parsed {
            while true {
                switch stage {
                case .head:
                    guard try readHeadLine() else { return .needMore }
                    // Past the blank line the head is whole: it goes out before any of the body is read.
                    if case .head = stage { continue }
                    if let request { return .head(request) }
                case .length(let length):
                    guard buffer.count - cursor >= length else { return .needMore }
                    body = Array(buffer[cursor..<(cursor + length)])
                    cursor += length
                    return finish()
                case .chunkSize:
                    guard try readChunkSize() else { return .needMore }
                case .chunkData(let size):
                    guard buffer.count - cursor >= size + 2 else { return .needMore }
                    guard buffer[cursor + size] == 13, buffer[cursor + size + 1] == 10 else { throw bad() }
                    body.append(contentsOf: buffer[cursor..<(cursor + size)])
                    cursor += size + 2
                    stage = .chunkSize
                case .trailers:
                    guard try readTrailerLine() else { return .needMore }
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

        /// Headers a request carries once at most: a second one could be read either way.
        private static let singleHeaders = ["host", "authorization", "content-type", "mcp-protocol-version"]

        /// The head is whole: pick the body's framing from it. A failure here carries the head, so the checks
        /// still answer first.
        private mutating func startBody(of request: Request) throws {
            let malformed = Failure(status: 400, request: request)
            for name in Self.singleHeaders where request.values(name).count > 1 {
                throw malformed
            }
            let lengths = request.values("content-length")
            let codings = request.values("transfer-encoding")
            if !codings.isEmpty {
                guard lengths.isEmpty, request.version == "HTTP/1.1" else { throw malformed }
                let coding = codings.joined(separator: ",").trimmingCharacters(in: .whitespaces)
                guard coding.lowercased() == "chunked" else { throw malformed }
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
        private mutating func finish() -> Parsed {
            guard var request else { return .needMore }
            request.body = Data(body)
            buffer.removeFirst(cursor)
            stage = .head
            cursor = 0
            searched = 0
            self.request = nil
            body = []
            framing = 0
            trailerStart = 0
            return .request(request)
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

    /// Whether a Host value names the saved hostname: ASCII letters lowercased in both, an optional ":443"
    /// dropped, then the same bytes. Nothing else is folded, so no Unicode case or form makes another name match.
    /// Loopback, another port, a trailing dot and every other value fail.
    public static func hostMatches(_ value: String?, host: String?) -> Bool {
        guard let value, let host else { return false }
        let wanted = normalizedHost(host)
        return !wanted.isEmpty && normalizedHost(value) == wanted
    }

    private static func normalizedHost(_ value: String) -> [UInt8] {
        var bytes = value.utf8.map { byte -> UInt8 in
            (65...90).contains(byte) ? byte + 32 : byte
        }
        if bytes.count >= 4, bytes.suffix(4).elementsEqual(":443".utf8) {
            bytes.removeLast(4)
        }
        return bytes
    }

    /// An RFC 9110 qvalue in thousandths: "0" or "1", then at most three decimals, never above 1. Nil for
    /// anything else, spaces, signs and exponents included.
    private static func qvalue(_ text: Substring) -> Int? {
        let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let whole = parts[0]
        let decimals = parts.count > 1 ? Array(parts[1].utf8) : []
        guard whole == "0" || whole == "1", decimals.count <= 3 else { return nil }
        guard decimals.allSatisfy({ (48...57).contains($0) }) else { return nil }
        var thousandths = whole == "1" ? 1000 : 0
        for (place, digit) in decimals.enumerated() {
            let scale = [100, 10, 1][place]
            thousandths += Int(digit - 48) * scale
        }
        return thousandths <= 1000 ? thousandths : nil
    }

    // MARK: answers

    public static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
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
