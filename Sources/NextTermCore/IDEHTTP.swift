import Foundation

/// HTTP/1.1 as GitHub Copilot CLI speaks it to its editor (CopilotIDEServer): one request at a time on a
/// kept-alive connection, with a body sent either with a Content-Length or chunked (node's http client
/// chunks a body it was given no length for, which is how the CLI sends every request).
public enum IDEHTTP {
    public struct Request: Equatable, Sendable {
        public var method = ""
        public var path = ""
        /// Names lowercased; a header given twice holds both values, joined by ", ".
        public var headers: [String: String] = [:]
        public var body = Data()

        public func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    public enum Parsed: Equatable, Sendable {
        /// A whole request, and what follows it in the buffer.
        case request(Request, rest: Data)
        /// Not all of it has arrived yet.
        case incomplete
        /// Not HTTP, or too large: answer 400 and close.
        case invalid
    }

    /// open_diff carries a whole file.
    public static let maximumBody = 32 << 20
    static let maximumHead = 64 << 10

    private static let lineEnd = Data("\r\n".utf8)
    private static let headEnd = Data("\r\n\r\n".utf8)

    public static func parse(_ data: Data, maximumBody: Int = maximumBody) -> Parsed {
        let buffer = data.startIndex == 0 ? data : Data(data) // indices from 0 below
        guard let end = buffer.range(of: headEnd) else { return buffer.count > maximumHead ? .invalid : .incomplete }
        guard end.lowerBound <= maximumHead, let head = String(data: buffer[0..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count == 3, first[2].hasPrefix("HTTP/1.") else { return .invalid }
        var request = Request(method: String(first[0]), path: String(first[1]))
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .invalid }
            request.headers[name] = request.headers[name].map { $0 + ", " + value } ?? value
        }
        let start = end.upperBound
        if request.header("transfer-encoding")?.lowercased().contains("chunked") == true {
            return chunked(buffer, from: start, request: request, maximumBody: maximumBody)
        }
        let length: Int
        if let text = request.header("content-length") {
            guard let value = Int(text), value >= 0 else { return .invalid }
            length = value
        } else {
            length = 0
        }
        guard length <= maximumBody else { return .invalid }
        guard buffer.count - start >= length else { return .incomplete }
        request.body = buffer[start..<(start + length)]
        return .request(request, rest: Data(buffer[(start + length)...]))
    }

    /// A chunked body: `<hex size>[;extension]\r\n<bytes>\r\n` … `0\r\n`, trailers, `\r\n`.
    private static func chunked(_ buffer: Data, from start: Int, request: Request, maximumBody: Int) -> Parsed {
        var request = request
        var body = Data()
        var position = start
        while true {
            guard let lineRange = buffer.range(of: lineEnd, in: position..<buffer.count) else { return .incomplete }
            guard let line = String(data: buffer[position..<lineRange.lowerBound], encoding: .ascii),
                  let hex = line.split(separator: ";", omittingEmptySubsequences: false).first,
                  let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else { return .invalid }
            position = lineRange.upperBound
            if size == 0 { break }
            guard body.count + size <= maximumBody else { return .invalid }
            guard buffer.count - position >= size + 2 else { return .incomplete }
            guard buffer[(position + size)..<(position + size + 2)] == lineEnd else { return .invalid }
            body.append(buffer[position..<(position + size)])
            position += size + 2
        }
        // Trailers, if any, up to an empty line.
        while true {
            guard let lineRange = buffer.range(of: lineEnd, in: position..<buffer.count) else { return .incomplete }
            let empty = lineRange.lowerBound == position
            position = lineRange.upperBound
            if empty { break }
        }
        request.body = body
        return .request(request, rest: Data(buffer[position...]))
    }

    // MARK: answers

    public static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }

    /// A whole answer, with its length. `close`: the connection ends after it (a refusal).
    public static func response(status: Int, headers: [(String, String)] = [], body: Data = Data(), close: Bool = false) -> Data {
        var head = "HTTP/1.1 \(status) \(reason(status))\r\nContent-Length: \(body.count)\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        if close { head += "Connection: close\r\n" }
        return Data((head + "\r\n").utf8) + body
    }

    /// The start of an event stream, sent chunked so the connection can stay open.
    public static func streamHead(headers: [(String, String)] = []) -> Data {
        var head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache, no-transform\r\n"
        head += "Connection: keep-alive\r\nTransfer-Encoding: chunked\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        return Data((head + "\r\n").utf8)
    }

    /// One chunk of a chunked answer.
    public static func chunk(_ data: Data) -> Data {
        Data((String(data.count, radix: 16) + "\r\n").utf8) + data + lineEnd
    }

    /// A JSON-RPC message as one server-sent event: `event: message`, then the JSON on one line.
    public static func event(_ message: [String: Any]) -> Data? {
        guard let json = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]),
              let line = String(data: json, encoding: .utf8) else { return nil }
        return Data("event: message\ndata: \(line)\n\n".utf8)
    }
}
