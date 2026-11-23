import Foundation
import Testing
@testable import NextTermCore

/// The remote door's HTTP: the parser and its limits, the request checks in their order, and the answers it
/// builds. Every limit is tested at its edge, and seeded random input never gets past it.
@Suite struct RemoteAccessHTTPTests {
    typealias HTTP = RemoteAccessHTTP

    let host = "mcp.example.com"

    func bytes(_ text: String) -> Data { Data(text.utf8) }

    /// The whole input fed at once, past the head that comes out before each request.
    func parse(_ data: Data) -> HTTP.Parsed {
        var parser = HTTP.Parser()
        _ = parser.append(data)
        return nextPastHead(&parser)
    }

    /// The parser's next answer that is not a head.
    func nextPastHead(_ parser: inout HTTP.Parser) -> HTTP.Parsed {
        var parsed = parser.next()
        while case .head = parsed {
            parsed = parser.next()
        }
        return parsed
    }

    func parse(_ text: String) -> HTTP.Parsed { parse(bytes(text)) }

    func request(_ text: String) throws -> HTTP.Request {
        guard case .request(let request) = parse(text) else {
            Issue.record("no request from \(text.debugDescription)")
            throw HTTPTestError.noRequest
        }
        return request
    }

    func status(_ parsed: HTTP.Parsed) -> Int? {
        if case .failure(let failure) = parsed { return failure.status }
        return nil
    }

    /// A POST to /mcp with these header lines, checked against `host`.
    func checked(_ lines: [String]) -> HTTP.Checked? {
        checked("POST", "/mcp", lines)
    }

    /// A request with these header lines, checked against `host`.
    func checked(_ method: String, _ target: String, _ lines: [String]) -> HTTP.Checked? {
        let head = "\(method) \(target) HTTP/1.1\r\n" + lines.map { $0 + "\r\n" }.joined() + "\r\n"
        guard case .request(let request) = parse(head) else { return nil }
        return HTTP.check(request, host: host)
    }

    func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    // MARK: limits as the plan sets them

    @Test func theLimitsAreThePlans() {
        #expect(HTTP.maximumHead == 16 * 1024)
        #expect(HTTP.maximumBody == 1024 * 1024)
        #expect(HTTP.headerDeadline == 10)
        #expect(HTTP.idleDeadline == 30)
    }

    // MARK: happy

    @Test func aPostWithAContentLength() throws {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let text = "POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n" + body
        let request = try request(text)
        #expect(request.method == "POST")
        #expect(request.target == "/mcp")
        #expect(request.path == "/mcp")
        #expect(request.query == nil)
        #expect(request.version == "HTTP/1.1")
        #expect(request.body == bytes(body))
        // Header names compare without case; values keep theirs.
        #expect(request.header("CONTENT-TYPE") == "application/json")
        #expect(request.header("content-type") == "application/json")
        #expect(request.header("Host") == "mcp.example.com")
        #expect(request.header("X-Missing") == nil)
    }

    @Test func aChunkedPost() throws {
        let text = "POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\nTransfer-Encoding: Chunked\r\n\r\n"
            + "5\r\nhello\r\n6;name=value\r\n world\r\nA \r\n, chunked!\r\n0\r\n\r\n"
        let request = try request(text)
        #expect(request.body == bytes("hello world, chunked!"))
    }

    @Test func aChunkedPostWithTrailersKeepsThemOutOfTheHeaders() throws {
        let text = "POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "3\r\nabc\r\n0\r\nOrigin: https://evil.example\r\nHost: evil.example\r\n\r\n"
        let request = try request(text)
        #expect(request.body == bytes("abc"))
        #expect(request.header("origin") == nil)
        #expect(request.values("host") == ["mcp.example.com"])
        #expect(HTTP.check(request, host: host) == .route(.mcp))
    }

    @Test func twoRequestsInOneBufferComeOutOneAtATimeInOrder() throws {
        let first = "POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\nContent-Length: 3\r\n\r\none"
        let second = "POST /oauth/token HTTP/1.1\r\nHost: mcp.example.com\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "3\r\ntwo\r\n0\r\n\r\n"
        var parser = HTTP.Parser()
        let accepted = parser.append(bytes(first + second + "GET /"))
        #expect(accepted)
        guard case .head(let oneHead) = parser.next() else { Issue.record("no first head"); return }
        #expect(oneHead.path == "/mcp")
        #expect(oneHead.body.isEmpty)
        guard case .request(let one) = parser.next() else { Issue.record("no first request"); return }
        #expect(one.path == "/mcp")
        #expect(one.body == bytes("one"))
        // The first waits for its answer: no deadline runs, whatever is buffered behind it.
        #expect(parser.phase == .answering)
        guard case .head(let twoHead) = parser.next() else { Issue.record("no second head"); return }
        #expect(twoHead.path == "/oauth/token")
        guard case .request(let two) = parser.next() else { Issue.record("no second request"); return }
        #expect(two.path == "/oauth/token")
        #expect(two.body == bytes("two"))
        #expect(parser.phase == .answering)
        // The third has only begun.
        #expect(parser.next() == .needMore)
        #expect(parser.phase == .head)
    }

    @Test func oneByteAtATimeGivesTheHeadAtItsBlankLineThenTheRequestAndThePhasesInTurn() throws {
        let text = "POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\nContent-Length: 4\r\n\r\nbody"
        let whole = try request(text)
        var head = whole
        head.body = Data()
        var parser = HTTP.Parser()
        // A new connection's first head is on the header deadline from the start (R8).
        #expect(parser.phase == .head)
        let data = bytes(text)
        let headEnd = text.utf8.count - 4
        for (index, byte) in data.enumerated() {
            _ = parser.append(Data([byte]))
            let parsed = parser.next()
            if index < headEnd - 1 {
                #expect(parsed == .needMore)
                #expect(parser.phase == .head, "after byte \(index)")
            } else if index == headEnd - 1 {
                #expect(parsed == .head(head))
                #expect(parser.phase == .body)
            } else if index < data.count - 1 {
                #expect(parsed == .needMore)
                #expect(parser.phase == .body, "after byte \(index)")
            } else {
                #expect(parsed == .request(whole))
                #expect(parser.phase == .answering)
            }
        }
        #expect(parser.next() == .needMore)
        #expect(parser.phase == .idle)
    }

    @Test func noDeadlineRunsWhileARequestWaitsForItsAnswerWhateverIsBufferedBehindIt() {
        let empty = "POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\nContent-Length: 0\r\n\r\n"
        var parser = HTTP.Parser()
        _ = parser.append(bytes(empty + empty))
        guard case .request = nextPastHead(&parser) else { Issue.record("no first request"); return }
        #expect(parser.phase == .answering)
        _ = parser.append(bytes("POST /mcp"))
        #expect(parser.phase == .answering)
        // Asking for the next one means the first was answered.
        guard case .request = nextPastHead(&parser) else { Issue.record("no second request"); return }
        #expect(parser.phase == .answering)
        #expect(parser.next() == .needMore)
        #expect(parser.phase == .head)
    }

    /// R8: a new connection has 10 seconds for its first request's head, counted from when it opened. The 30 idle
    /// seconds run only between requests, so a connection that never sends a byte can't hold its place for 30.
    @Test func aNewConnectionIsOnTheHeaderDeadlineUntilItsFirstRequestIsWhole() {
        var parser = HTTP.Parser()
        #expect(parser.phase == .head)
        #expect(parser.next() == .needMore)
        #expect(parser.phase == .head)
        _ = parser.append(bytes("GET /.well-known/oauth-authorization-server HTTP/1.1\r\nHost: mcp.example.com\r\n"))
        #expect(parser.next() == .needMore)
        #expect(parser.phase == .head)
        _ = parser.append(bytes("\r\n"))
        guard case .request = nextPastHead(&parser) else { Issue.record("no request"); return }
        #expect(parser.phase == .answering)
        // Answered: from now on the connection waits between requests.
        #expect(parser.next() == .needMore)
        #expect(parser.phase == .idle)
        #expect(HTTP.headerDeadline == 10)
        #expect(HTTP.idleDeadline == 30)
    }

    // MARK: the head before its body

    @Test func theHeadComesOutBeforeItsBodySoAWrongHostIsRefusedBeforeAnyOfIt() {
        let head = "POST /mcp HTTP/1.1\r\nHost: evil.example\r\nOrigin: https://evil.example\r\n"
            + "Content-Length: \(HTTP.maximumBody)\r\n\r\n"
        var parser = HTTP.Parser()
        _ = parser.append(bytes(head))
        guard case .head(let request) = parser.next() else { Issue.record("no head"); return }
        #expect(request.body.isEmpty)
        #expect(HTTP.check(request, host: host) == .refused(status: 421, allow: []))
        // While the body arrives, its own deadline runs; the head never comes out twice.
        #expect(HTTP.bodyDeadline == 30)
        #expect(parser.phase == .body)
        for _ in 0..<100 {
            _ = parser.append(Data([0x61]))
            #expect(parser.next() == .needMore)
            #expect(parser.phase == .body)
        }
    }

    @Test func aFramingFailureCarriesItsHeadSoTheChecksStillAnswerFirst() {
        let both = "Content-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n"
        let wrong = parse("POST /mcp HTTP/1.1\r\nHost: evil.example\r\n" + both)
        guard case .failure(let wrongFailure) = wrong else { Issue.record("no failure"); return }
        #expect(wrongFailure.status == 400)
        #expect(wrongFailure.request?.path == "/mcp")
        #expect(HTTP.refusal(wrongFailure, host: host) == HTTP.refusal(status: 421))
        let right = parse("POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\n" + both)
        guard case .failure(let rightFailure) = right else { Issue.record("no failure"); return }
        #expect(HTTP.refusal(rightFailure, host: host) == HTTP.refusal(status: 400))
    }

    @Test func theTargetSplitsIntoAPathAndAQuery() throws {
        let request = try request("GET /oauth/authorize?response_type=code&state=x%20y HTTP/1.1\r\nHost: mcp.example.com\r\n\r\n")
        #expect(request.path == "/oauth/authorize")
        #expect(request.query == "response_type=code&state=x%20y")
        #expect(request.body.isEmpty)
        let empty = try self.request("GET /oauth/authorize? HTTP/1.1\r\nHost: mcp.example.com\r\n\r\n")
        #expect(empty.path == "/oauth/authorize")
        #expect(empty.query == "")
    }

    @Test func aRequestWithNoBodyIsWholeAtItsBlankLine() throws {
        var parser = HTTP.Parser()
        _ = parser.append(bytes("GET /.well-known/oauth-authorization-server HTTP/1.1\r\nHost: mcp.example.com\r\n"))
        #expect(parser.next() == .needMore)
        _ = parser.append(bytes("\r\n"))
        guard case .head = parser.next() else { Issue.record("no head"); return }
        guard case .request(let request) = parser.next() else { Issue.record("no request"); return }
        #expect(request.body.isEmpty)
        #expect(parser.phase == .answering)
        #expect(parser.next() == .needMore)
        #expect(parser.phase == .idle)
    }

    @Test func aHeaderGivenTwiceHoldsBothValues() throws {
        let request = try request("POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\nAccept: application/json\r\n"
            + "accept: text/event-stream\r\n\r\n")
        #expect(request.values("Accept") == ["application/json", "text/event-stream"])
        #expect(request.header("accept") == "application/json, text/event-stream")
        #expect(request.acceptsEventStream)
    }

    @Test func expectContinueIsTolerated() throws {
        let request = try request("POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\nExpect: 100-continue\r\n"
            + "Content-Length: 2\r\n\r\n{}")
        #expect(request.body == bytes("{}"))
    }

    @Test func theSameContentLengthTwiceIsTolerated() throws {
        let twice = try request("POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\nContent-Length: 2\r\n"
            + "Content-Length: 2\r\n\r\n{}")
        #expect(twice.body == bytes("{}"))
        let listed = try request("POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\nContent-Length: 2, 2\r\n\r\n{}")
        #expect(listed.body == bytes("{}"))
    }

    @Test func http10IsRead() throws {
        let request = try request("GET /.well-known/oauth-protected-resource HTTP/1.0\r\nHost: mcp.example.com\r\n\r\n")
        #expect(request.version == "HTTP/1.0")
    }

    // MARK: the accept header

    @Test func aStreamIsAcceptedOnlyWhenTheAcceptHeaderNamesIt() throws {
        func accepts(_ value: String?) throws -> Bool {
            let line = value.map { "Accept: \($0)\r\n" } ?? ""
            return try request("POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\n\(line)\r\n").acceptsEventStream
        }
        #expect(try accepts("application/json, text/event-stream"))
        #expect(try accepts("TEXT/EVENT-STREAM; q=0.5"))
        #expect(try accepts("text/event-stream;q=1.0"))
        #expect(try !accepts("application/json"))
        #expect(try !accepts("text/event-stream;q=0"))
        #expect(try !accepts("text/event-stream; q=0.000"))
        #expect(try !accepts("text/*"))
        #expect(try !accepts("*/*"))
        #expect(try !accepts("text/event-streams"))
        #expect(try !accepts(nil))
        // A weight that is not an RFC 9110 qvalue is not a yes.
        for weight in ["junk", "", "inf", "nan", "1e0", "2", "1.5", "1.001", "0.0001", ".5", "+1", "-1", " 1", "0x1"] {
            #expect(try !accepts("text/event-stream;q=\(weight)"), "q=\(weight)")
        }
        #expect(try !accepts("text/event-stream; q = 0.5"))
        #expect(try accepts("text/event-stream;q=0.001"))
        #expect(try accepts("text/event-stream;q=1."))
        #expect(try accepts("text/event-stream;Q=1.000"))
        #expect(try accepts("text/event-stream;charset=utf-8;q=0.5"))
    }

    // MARK: the head's limit

    let padStart = "GET /mcp HTTP/1.1\r\nHost: mcp.example.com\r\nX-Pad: "

    /// A request whose head, blank line included, is exactly `size` bytes.
    func head(ofSize size: Int) -> String {
        let pad = size - padStart.utf8.count - 4
        return padStart + String(repeating: "a", count: pad) + "\r\n\r\n"
    }

    @Test func headersOfExactly16KBPassAndOneByteMoreGives431() throws {
        let exact = head(ofSize: HTTP.maximumHead)
        #expect(exact.utf8.count == 16_384)
        let request = try request(exact)
        #expect(request.header("x-pad")?.count == 16_384 - padStart.utf8.count - 4)
        let over = head(ofSize: HTTP.maximumHead + 1)
        #expect(status(parse(over)) == 431)
    }

    @Test func aHeadThatCannotEndWithin16KBGives431BeforeItEnds() {
        let short = padStart + String(repeating: "a", count: HTTP.maximumHead - padStart.utf8.count - 1)
        #expect(parse(short) == .needMore)
        let full = padStart + String(repeating: "a", count: HTTP.maximumHead - padStart.utf8.count)
        #expect(status(parse(full)) == 431)
        // Many short lines are counted the same way.
        let lines = String(repeating: "A: b\r\n", count: HTTP.maximumHead / 6 + 1)
        #expect(status(parse("GET /mcp HTTP/1.1\r\n" + lines)) == 431)
    }

    @Test func aHeadOfExactly16KBFedInPiecesPasses() throws {
        let exact = bytes(head(ofSize: HTTP.maximumHead))
        var parser = HTTP.Parser()
        var parsed = HTTP.Parsed.needMore
        var offset = 0
        while offset < exact.count {
            let end = min(offset + 1000, exact.count)
            _ = parser.append(exact.subdata(in: offset..<end))
            parsed = nextPastHead(&parser)
            offset = end
        }
        guard case .request = parsed else { Issue.record("got \(parsed)"); return }
    }

    // MARK: the body's limit

    func post(contentLength: Int, body: Data) -> Data {
        bytes("POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\nContent-Length: \(contentLength)\r\n\r\n") + body
    }

    @Test func aBodyOf1MBPassesAndOneByteMoreGives413() throws {
        let body = Data(repeating: 0x61, count: HTTP.maximumBody)
        guard case .request(let request) = parse(post(contentLength: body.count, body: body)) else {
            Issue.record("1 MB did not pass"); return
        }
        #expect(request.body.count == 1_048_576)
        // Over the limit, the head alone is enough: nothing of the body need arrive.
        let over = parse(post(contentLength: HTTP.maximumBody + 1, body: Data()))
        #expect(status(over) == 413)
        guard case .failure(let failure) = over else { return }
        #expect(failure.request?.path == "/mcp")
        #expect(failure.request?.body.isEmpty == true)
    }

    @Test func aContentLengthTooLongForAnIntGives413() {
        let text = "POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\nContent-Length: 99999999999999999999999\r\n\r\n"
        #expect(status(parse(text)) == 413)
    }

    func chunked(_ chunks: [Data], trailer: String = "") -> Data {
        var data = bytes("POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\nTransfer-Encoding: chunked\r\n\r\n")
        for chunk in chunks {
            data += bytes(String(chunk.count, radix: 16) + "\r\n") + chunk + bytes("\r\n")
        }
        return data + bytes("0\r\n" + trailer + "\r\n")
    }

    @Test func aChunkedBodyOf1MBPassesAndOneByteMoreGives413() {
        let half = Data(repeating: 0x62, count: HTTP.maximumBody / 2)
        guard case .request(let request) = parse(chunked([half, half])) else {
            Issue.record("1 MB chunked did not pass"); return
        }
        #expect(request.body.count == HTTP.maximumBody)
        #expect(status(parse(chunked([half, half, Data([0x63])]))) == 413)
        // A chunk size past the limit fails from its size line alone.
        let huge = bytes("POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "FFFFFFFFFFFFFFFFFFFF\r\n")
        #expect(status(parse(huge)) == 413)
        let justOver = bytes("POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\nTransfer-Encoding: chunked\r\n\r\n"
            + String(HTTP.maximumBody + 1, radix: 16) + "\r\n")
        #expect(status(parse(justOver)) == 413)
    }

    @Test func manyTinyChunksPastTheFramingAllowanceGive413() {
        // Each one-byte chunk costs five bytes of framing: "1\r\n" and the "\r\n" after its byte.
        let tiny = Array(repeating: Data([0x61]), count: HTTP.maximumChunkFraming / 5 + 1)
        #expect(status(parse(chunked(tiny))) == 413)
        let fewer = Array(repeating: Data([0x61]), count: 1000)
        guard case .request(let request) = parse(chunked(fewer)) else { Issue.record("1000 chunks failed"); return }
        #expect(request.body.count == 1000)
    }

    @Test func aChunkSizeLineOrTrailersPastTheirLimitsFail() {
        let longLine = bytes("POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "1;" + String(repeating: "x", count: HTTP.maximumChunkLine))
        #expect(status(parse(longLine)) == 400)
        let trailer = "X-Pad: " + String(repeating: "t", count: HTTP.maximumHead) + "\r\n"
        #expect(status(parse(chunked([bytes("abc")], trailer: trailer))) == 431)
    }

    // MARK: malformed requests

    @Test func malformedRequestsGive400() {
        let host = "Host: mcp.example.com\r\n"
        let cases: [String] = [
            // A header line without a colon, an empty name, a space before the colon, a folded line.
            "POST /mcp HTTP/1.1\r\n\(host)NoColonHere\r\n\r\n",
            "POST /mcp HTTP/1.1\r\n\(host): value\r\n\r\n",
            "POST /mcp HTTP/1.1\r\n\(host)Content-Length : 0\r\n\r\n",
            "POST /mcp HTTP/1.1\r\n\(host)X-A: b\r\n continued\r\n\r\n",
            "POST /mcp HTTP/1.1\r\n\(host)X(A): b\r\n\r\n",
            // Both framings, two lengths, a length that is not a plain number.
            "POST /mcp HTTP/1.1\r\n\(host)Content-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n",
            "POST /mcp HTTP/1.1\r\n\(host)Content-Length: 3\r\nContent-Length: 4\r\n\r\nabcd",
            "POST /mcp HTTP/1.1\r\n\(host)Content-Length: 3, 4\r\n\r\nabcd",
            "POST /mcp HTTP/1.1\r\n\(host)Content-Length: +3\r\n\r\nabc",
            "POST /mcp HTTP/1.1\r\n\(host)Content-Length: -1\r\n\r\n",
            "POST /mcp HTTP/1.1\r\n\(host)Content-Length: 3a\r\n\r\nabc",
            "POST /mcp HTTP/1.1\r\n\(host)Content-Length:\r\n\r\n",
            "POST /mcp HTTP/1.1\r\n\(host)Content-Length: 0x3\r\n\r\nabc",
            // A transfer coding other than chunked alone.
            "POST /mcp HTTP/1.1\r\n\(host)Transfer-Encoding: gzip\r\n\r\n",
            "POST /mcp HTTP/1.1\r\n\(host)Transfer-Encoding: gzip, chunked\r\n\r\n",
            "POST /mcp HTTP/1.1\r\n\(host)Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n",
            "POST /mcp HTTP/1.0\r\n\(host)Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
            // Two Host headers.
            "POST /mcp HTTP/1.1\r\n\(host)\(host)\r\n",
            "POST /mcp HTTP/1.1\r\n\(host)host: other.example\r\n\r\n",
            // Request lines.
            "\r\nPOST /mcp HTTP/1.1\r\n\(host)\r\n",
            "POST /mcp\r\n\(host)\r\n",
            "POST  /mcp HTTP/1.1\r\n\(host)\r\n",
            "POST /mcp HTTP/1.1 extra\r\n\(host)\r\n",
            "POST /mcp HTTP/2.0\r\n\(host)\r\n",
            "POST /mcp http/1.1\r\n\(host)\r\n",
            "POST * HTTP/1.1\r\n\(host)\r\n",
            "POST http://mcp.example.com/mcp HTTP/1.1\r\n\(host)\r\n",
            "PO(ST /mcp HTTP/1.1\r\n\(host)\r\n",
            " POST /mcp HTTP/1.1\r\n\(host)\r\n",
            // Line ends: a bare LF, a bare CR, a control byte.
            "POST /mcp HTTP/1.1\n\(host)\r\n",
            "POST /mcp HTTP/1.1\r\nHost: mcp.example.com\n\n",
            "POST /mcp HTTP/1.1\r\nHost: mcp.example.com\rX: y\r\n\r\n",
            "POST /mcp HTTP/1.1\r\n\(host)X-A: b\u{0}c\r\n\r\n",
            "POST /mcp HTTP/1.1\r\n\(host)X-A: b\u{1B}c\r\n\r\n",
            "POST /mcp HTTP/1.1\r\n\(host)X-A: b\u{7F}\r\n\r\n",
        ]
        for text in cases {
            #expect(status(parse(text)) == 400, "\(text.debugDescription)")
        }
    }

    @Test func badChunksGive400() {
        let head = "POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\nTransfer-Encoding: chunked\r\n\r\n"
        let bodies = [
            "zz\r\nab\r\n0\r\n\r\n",
            "-1\r\na\r\n0\r\n\r\n",
            "0x2\r\nab\r\n0\r\n\r\n",
            "\r\nab\r\n0\r\n\r\n",
            " 2\r\nab\r\n0\r\n\r\n",
            "+2\r\nab\r\n0\r\n\r\n",
            "2\r\nabc\r\n0\r\n\r\n",
            "2\r\nab\n0\r\n\r\n",
            "2\nab\r\n0\r\n\r\n",
            "2;\u{0}\r\nab\r\n0\r\n\r\n",
            "2\r\nab\r\n0\r\nbad trailer\r\n\r\n",
        ]
        for body in bodies {
            #expect(status(parse(head + body)) == 400, "\(body.debugDescription)")
        }
    }

    @Test func aRepeatedAuthorizationContentTypeOrProtocolVersionGives400() {
        for name in ["Authorization", "Content-Type", "MCP-Protocol-Version"] {
            let line = "\(name): same\r\n"
            let text = "POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\n" + line + line.lowercased() + "\r\n"
            guard case .failure(let failure) = parse(text) else { Issue.record("\(name) twice was read"); continue }
            #expect(failure.status == 400, "\(name)")
            #expect(HTTP.refusal(failure, host: host) == HTTP.refusal(status: 400), "\(name)")
        }
    }

    @Test func aHeaderValueThatIsNotUTF8Gives400() {
        let data = bytes("POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\nX-A: ") + Data([0xFF, 0xFE]) + bytes("\r\n\r\n")
        #expect(status(parse(data)) == 400)
    }

    @Test func junkIsRefusedAtOnceWithoutWaitingForTheHeadToEnd() {
        #expect(status(parse(Data([0x16, 0x03, 0x01, 0x02, 0x00]))) == 400) // a TLS hello
        #expect(status(parse("GET /\u{0}")) == 400)
        #expect(status(parse("SSH-2.0-OpenSSH_9.6\r\n")) == 400)
    }

    @Test func aFailureStays() {
        var parser = HTTP.Parser()
        _ = parser.append(bytes("POST /mcp HTTP/1.1\r\nBroken\r\n\r\n"))
        #expect(status(parser.next()) == 400)
        _ = parser.append(bytes("GET /mcp HTTP/1.1\r\nHost: mcp.example.com\r\n\r\n"))
        #expect(status(parser.next()) == 400)
    }

    @Test func theBufferRefusesMoreThanOneWholeRequestsWorth() {
        var parser = HTTP.Parser()
        let piece = Data(repeating: 0x61, count: 64 * 1024)
        var accepted = true
        var total = 0
        while accepted && total <= HTTP.maximumBuffer {
            accepted = parser.append(piece)
            total += piece.count
        }
        #expect(!accepted)
        #expect(total > HTTP.maximumBuffer)
        #expect(total - piece.count <= HTTP.maximumBuffer)
        // A whole request at every limit fits.
        let largest = HTTP.maximumHead * 2 + HTTP.maximumBody + HTTP.maximumChunkFraming
        #expect(HTTP.maximumBuffer >= largest)
    }

    @Test func anOverflowInOneAppendStillReadsTheHeadSoAnMCPWriteGetsTheJSONRPCError() {
        let length = 1_200_000
        var parser = HTTP.Parser()
        let accepted = parser.append(post(contentLength: length, body: Data(repeating: 0x61, count: length)))
        #expect(!accepted)
        guard case .failure(let failure) = parser.next() else { Issue.record("no failure"); return }
        #expect(failure.status == 413)
        #expect(failure.request?.path == "/mcp")
        #expect(text(HTTP.refusal(failure, host: host)).contains(HTTP.bodyLimitMessage))
    }

    @Test func aRequestAlreadyWholeComesOutBeforeAnOverflowFails() {
        var parser = HTTP.Parser()
        let fits = parser.append(post(contentLength: 2, body: bytes("{}")))
        let overflows = parser.append(Data(repeating: 0x61, count: HTTP.maximumBuffer))
        #expect(fits && !overflows)
        guard case .request(let request) = nextPastHead(&parser) else {
            Issue.record("the whole POST was lost"); return
        }
        #expect(request.body == bytes("{}"))
        guard case .failure = parser.next() else { Issue.record("no failure after it"); return }

        // A 1 MB request whole, then a second cut short by the limit: the first comes out, then the second's head,
        // then 413 with that head, so the write gets the JSON-RPC error.
        var cut = HTTP.Parser()
        let full = Data(repeating: 0x62, count: HTTP.maximumBody)
        let firstFits = cut.append(post(contentLength: full.count, body: full))
        let secondOverflows = cut.append(post(contentLength: full.count, body: full))
        let laterDropped = cut.append(Data([0x63]))
        #expect(firstFits && !secondOverflows && !laterDropped)
        guard case .request(let first) = nextPastHead(&cut) else { Issue.record("no first request"); return }
        #expect(first.body == full)
        guard case .head(let secondHead) = cut.next() else { Issue.record("no second head"); return }
        guard case .failure(let failure) = cut.next() else { Issue.record("no failure"); return }
        #expect(failure.status == 413)
        #expect(failure.request == secondHead)
        #expect(text(HTTP.refusal(failure, host: host)).contains(HTTP.bodyLimitMessage))
    }

    // MARK: the checks, in order

    @Test func hostIgnoresCaseAndAnOptional443() {
        #expect(checked(["Host: MCP.Example.com:443"]) == .route(.mcp))
        #expect(checked(["Host: mcp.example.com"]) == .route(.mcp))
        #expect(checked(["Host: mcp.example.com:8443"]) == .refused(status: 421, allow: []))
        #expect(checked(["Host: mcp.example.com:"]) == .refused(status: 421, allow: []))
        #expect(checked(["Host: mcp.example.com:443:443"]) == .refused(status: 421, allow: []))
        #expect(checked(["Host: mcp.example.com."]) == .refused(status: 421, allow: []))
        #expect(checked(["Host: sub.mcp.example.com"]) == .refused(status: 421, allow: []))
        #expect(checked(["Host: example.com"]) == .refused(status: 421, allow: []))
        #expect(checked(["Host: mcp.example.com.evil.example"]) == .refused(status: 421, allow: []))
        #expect(checked(["Host: "]) == .refused(status: 421, allow: []))
        // The configured name is read the same way.
        #expect(HTTP.hostMatches("mcp.example.com", host: "MCP.EXAMPLE.COM:443"))
        #expect(!HTTP.hostMatches("mcp.example.com", host: ""))
        #expect(!HTTP.hostMatches(nil, host: host))
        #expect(!HTTP.hostMatches("mcp.example.com", host: nil))
    }

    @Test func loopbackAndAMissingHostGive421() {
        for value in ["127.0.0.1:40123", "localhost:40123", "127.0.0.1", "localhost", "[::1]:40123", "0.0.0.0"] {
            #expect(checked(["Host: \(value)"]) == .refused(status: 421, allow: []), "\(value)")
        }
        #expect(checked([]) == .refused(status: 421, allow: []))
    }

    @Test func untilAHostIsSavedEveryRequestGets421() throws {
        let request = try request("POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\n\r\n")
        #expect(HTTP.check(request, host: nil) == .refused(status: 421, allow: []))
        #expect(HTTP.check(request, host: "") == .refused(status: 421, allow: []))
    }

    @Test func twoHostHeadersInAMadeRequestGive421() {
        let request = HTTP.Request(method: "POST", target: "/mcp", headers: [
            HTTP.Header(name: "Host", value: host), HTTP.Header(name: "host", value: host),
        ])
        #expect(HTTP.check(request, host: host) == .refused(status: 421, allow: []))
    }

    @Test func anyOriginGives403() {
        let origins = ["https://mcp.example.com", "https://claude.ai", "https://chatgpt.com", "null", "", "http://127.0.0.1"]
        for origin in origins {
            #expect(checked(["Host: mcp.example.com", "Origin: \(origin)"]) == .refused(status: 403, allow: []),
                    "\(origin)")
        }
        #expect(checked("GET", "/oauth/authorize", ["Host: mcp.example.com", "origin: https://mcp.example.com"])
            == .refused(status: 403, allow: []))
    }

    @Test func pathsOutsideTheDoorsGive404() {
        let paths = ["/", "/.git/config", "/mcp/", "/MCP", "/mcp%2F", "/mcp/x", "/oauth", "/oauth/", "/oauth/other",
                     "/oauth/token/", "/oauth%2Ftoken", "/.well-known/", "/.well-known/openid-configuration",
                     "/.well-known/oauth-protected-resource/other", "/mcp#x", "//mcp", "/./mcp", "/oauth/../mcp"]
        for path in paths {
            #expect(checked(path, ["Host: mcp.example.com"]) == .refused(status: 404, allow: []), "\(path)")
            #expect(checked("GET", path, ["Host: mcp.example.com"]) == .refused(status: 404, allow: []), "\(path)")
        }
    }

    func checked(_ target: String, _ lines: [String]) -> HTTP.Checked? {
        checked("POST", target, lines)
    }

    @Test func eachDoorTakesItsOwnMethods() {
        let doors: [(String, String, HTTP.Route)] = [
            ("POST", "/mcp", .mcp),
            ("GET", "/.well-known/oauth-protected-resource", .protectedResource),
            ("GET", "/.well-known/oauth-protected-resource/mcp", .protectedResource),
            ("GET", "/.well-known/oauth-authorization-server", .authorizationServer),
            ("POST", "/oauth/register", .register),
            ("GET", "/oauth/authorize", .authorize),
            ("GET", "/oauth/authorize/wait", .authorizeWait),
            ("POST", "/oauth/token", .token),
            ("POST", "/oauth/revoke", .revoke),
        ]
        for (method, path, route) in doors {
            #expect(checked(method, path, ["Host: mcp.example.com"]) == .route(route), "\(method) \(path)")
            #expect(checked(method, path + "?a=b", ["Host: mcp.example.com"]) == .route(route), "\(method) \(path)?")
            for other in ["GET", "POST", "DELETE", "PUT", "OPTIONS", "HEAD", "PATCH", "post", "get"] where other != method {
                #expect(checked(other, path, ["Host: mcp.example.com"]) == .refused(status: 405, allow: [method]),
                        "\(other) \(path)")
            }
        }
    }

    @Test func theChecksRunHostThenOriginThenPathThenMethod() {
        // A wrong Host wins over everything else.
        #expect(checked("GET", "/nowhere", ["Host: evil.example", "Origin: https://evil.example"])
            == .refused(status: 421, allow: []))
        // Then an Origin, over a bad path.
        #expect(checked("GET", "/nowhere", ["Host: mcp.example.com", "Origin: https://evil.example"])
            == .refused(status: 403, allow: []))
        // Then the path, over a bad method.
        #expect(checked("DELETE", "/nowhere", ["Host: mcp.example.com"]) == .refused(status: 404, allow: []))
        #expect(checked("DELETE", "/mcp", ["Host: mcp.example.com"]) == .refused(status: 405, allow: ["POST"]))
    }

    // MARK: security

    @Test func forwardedAddressesChangeNoDecision() throws {
        let vendor = ["CF-Connecting-IP: 160.79.104.10", "X-Forwarded-For: 160.79.104.10, 104.16.0.1", "Cf-Ray: 8a1b2c3d4e5f-SJC"]
        let cases: [(String, String, [String])] = [
            ("POST", "/mcp", ["Host: mcp.example.com"]),
            ("POST", "/mcp", ["Host: 127.0.0.1:40123"]),
            ("POST", "/mcp", ["Host: mcp.example.com", "Origin: https://claude.ai"]),
            ("GET", "/mcp", ["Host: mcp.example.com"]),
            ("POST", "/admin", ["Host: mcp.example.com"]),
        ]
        for (method, path, lines) in cases {
            #expect(checked(method, path, lines) == checked(method, path, lines + vendor), "\(method) \(path) \(lines)")
        }
        let request = try request("POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\n" + vendor.joined(separator: "\r\n") + "\r\n\r\n")
        #expect(request.forwarded.connectingIP == "160.79.104.10")
        #expect(request.forwarded.forwardedFor == "160.79.104.10, 104.16.0.1")
        #expect(request.forwarded.ray == "8a1b2c3d4e5f-SJC")
    }

    @Test func forwardedValuesAreCutForTheAuditLog() throws {
        let long = String(repeating: "1", count: 500)
        let request = try request("POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\nX-Forwarded-For: \(long)\r\n\r\n")
        #expect(request.forwarded.forwardedFor?.count == HTTP.Forwarded.maximumLength)
        #expect(request.forwarded.connectingIP == nil)
        #expect(request.forwarded.ray == nil)
    }

    @Test func theHostCompareIsByteForByteWithOnlyASCIILowercased() {
        // The Kelvin sign lowercases to "k" by Unicode's rules, and "e" with a combining accent equals "é" as a
        // String: neither is the saved name's bytes.
        #expect(!HTTP.hostMatches("mcp.wor\u{212A}.dev", host: "mcp.work.dev"))
        #expect(!HTTP.hostMatches("cafe\u{301}.example", host: "caf\u{E9}.example"))
        #expect(!HTTP.hostMatches("CAF\u{C9}.example", host: "caf\u{E9}.example"))
        #expect(HTTP.hostMatches("CAF\u{E9}.EXAMPLE:443", host: "caf\u{E9}.example"))
        #expect(HTTP.hostMatches("MCP.WORK.DEV", host: "mcp.work.dev"))
        let kelvin = "POST /mcp HTTP/1.1\r\nHost: mcp.wor\u{212A}.dev\r\n\r\n"
        guard case .request(let request) = parse(kelvin) else { Issue.record("no request"); return }
        #expect(HTTP.check(request, host: "mcp.work.dev") == .refused(status: 421, allow: []))
    }

    @Test func aDescriptionNeverHoldsTheAuthorizationTheQueryOrTheBody() {
        let secret = "ntat_SECRET"
        let body = "grant_type=refresh_token&refresh_token=\(secret)"
        let text = "POST /oauth/token?access_token=\(secret) HTTP/1.1\r\nHost: mcp.example.com\r\n"
            + "Authorization: Bearer \(secret)\r\nproxy-authorization: Basic \(secret)\r\nCookie: s=\(secret)\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n" + body
        var parser = HTTP.Parser()
        _ = parser.append(bytes(text))
        guard case .head(let head) = parser.next() else { Issue.record("no head"); return }
        guard case .request(let request) = parser.next() else { Issue.record("no request"); return }
        let failure = HTTP.Failure(status: 413, request: request)
        var dumped = ""
        dump(request, to: &dumped)
        dump(failure, to: &dumped)
        let described = [
            "\(request)", String(reflecting: request), "\(failure)", String(reflecting: failure),
            "\(HTTP.Parsed.head(head))", "\(HTTP.Parsed.request(request))", "\(HTTP.Parsed.failure(failure))",
            "\(request.headers)", String(reflecting: request.headers), dumped,
        ]
        for description in described {
            #expect(!description.contains(secret), "\(description)")
        }
        // What is safe to log stays.
        #expect("\(request)".contains("POST /oauth/token"))
        #expect("\(request)".contains("Host: mcp.example.com"))
        #expect("\(request)".contains("Authorization"))
        #expect("\(failure)".contains("413"))
    }

    @Test func aRightForwardedHostWithAWrongHostStillGives421() {
        let lines = ["Host: 127.0.0.1:40123", "X-Forwarded-Host: mcp.example.com", "Forwarded: host=mcp.example.com",
                     "X-Original-Host: mcp.example.com"]
        #expect(checked(lines) == .refused(status: 421, allow: []))
    }

    // MARK: answers

    @Test func aRefusalHasNoBodyNoServerNameAndCloses() {
        #expect(text(HTTP.refusal(status: 421)) == "HTTP/1.1 421 Misdirected Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        #expect(text(HTTP.refusal(status: 404)) == "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        #expect(text(HTTP.refusal(status: 405, allow: ["POST"]))
            == "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nAllow: POST\r\nConnection: close\r\n\r\n")
        #expect(text(HTTP.refusal(status: 431)).hasPrefix("HTTP/1.1 431 Request Header Fields Too Large\r\n"))
        #expect(text(HTTP.refusal(status: 413)).hasPrefix("HTTP/1.1 413 Content Too Large\r\n"))
        #expect(text(HTTP.refusal(status: 403)).hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
        #expect(text(HTTP.refusal(status: 400)).hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
        // The door's answer when a head or a body is too slow to arrive (R8).
        #expect(text(HTTP.refusal(status: 408)).hasPrefix("HTTP/1.1 408 Request Timeout\r\n"))
    }

    /// A registration that succeeds answers 201 with its own reason, not a generic one.
    @Test func aRegistrationAnswersCreated() {
        #expect(HTTP.reason(201) == "Created")
        #expect(text(HTTP.json(status: 201, body: bytes("{}"))).hasPrefix("HTTP/1.1 201 Created\r\n"))
    }

    @Test func aCheckedRefusalAnswersItself() {
        let refused = HTTP.Checked.refused(status: 405, allow: ["POST"])
        #expect(refused.answer == HTTP.refusal(status: 405, allow: ["POST"]))
        #expect(HTTP.Checked.route(.mcp).answer == nil)
    }

    @Test func noAnswerCarriesAServerNameOrCORSOrASecondLength() {
        let headers = [("Server", "Next Term"), ("Access-Control-Allow-Origin", "*"), ("access-control-allow-headers", "x"),
                       ("Content-Length", "999"), ("Connection", "keep-alive"), ("Transfer-Encoding", "chunked"),
                       ("X-Split", "a\r\nSet-Cookie: b"), ("Bad Name", "c"), ("Cache-Control", "no-store")]
        let answer = text(HTTP.response(status: 200, headers: headers, body: bytes("{}")))
        #expect(answer == "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nCache-Control: no-store\r\n\r\n{}")
        let stream = text(HTTP.streamHead(headers: headers))
        #expect(!stream.lowercased().contains("server:"))
        #expect(!stream.lowercased().contains("access-control"))
        #expect(!stream.lowercased().contains("content-length"))
        #expect(!stream.lowercased().contains("chunked"))
        #expect(!stream.contains("Set-Cookie"))
    }

    @Test func aJSONAnswerCarriesItsTypeAndLength() {
        let body = bytes(#"{"ok":true,"name":"é"}"#)
        let answer = text(HTTP.json(status: 200, body: body))
        #expect(answer == "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nContent-Type: application/json\r\n\r\n"
            + #"{"ok":true,"name":"é"}"#)
        let closing = text(HTTP.json(status: 401, body: bytes("{}"), headers: [("WWW-Authenticate", "Bearer x")], close: true))
        #expect(closing == "HTTP/1.1 401 Unauthorized\r\nContent-Length: 2\r\nContent-Type: application/json\r\n"
            + "WWW-Authenticate: Bearer x\r\nConnection: close\r\n\r\n{}")
    }

    @Test func oneEventAndTwoKeepAlivesFrameToExactBytes() {
        let message = bytes(#"{"jsonrpc":"2.0","id":7,"result":{}}"#)
        var stream = HTTP.streamHead()
        stream += HTTP.keepAlive
        stream += HTTP.keepAlive
        stream += HTTP.event(message)
        let head = [
            "HTTP/1.1 200 OK\r\n",
            "Content-Type: text/event-stream\r\n",
            "Cache-Control: no-cache, no-transform\r\n",
            "X-Accel-Buffering: no\r\n",
            "Connection: close\r\n",
            "\r\n",
        ]
        let frames = [
            ": keep-alive\n\n",
            ": keep-alive\n\n",
            "event: message\n",
            #"data: {"jsonrpc":"2.0","id":7,"result":{}}"#,
            "\n\n",
        ]
        let expected = head.joined() + frames.joined()
        #expect(text(stream) == expected)
    }

    @Test func anEventWithLineBreaksKeepsEachLineInItsOwnDataField() {
        #expect(text(HTTP.event(bytes("{\n\"a\": 1\r\n}"))) == "event: message\ndata: {\ndata: \"a\": 1\ndata: }\n\n")
    }

    @Test func aBodyOver1MBOnMCPGetsAJSONRPCErrorThatNamesTheLimit() throws {
        let parsed = parse(post(contentLength: HTTP.maximumBody + 1, body: Data()))
        guard case .failure(let failure) = parsed else { Issue.record("no failure"); return }
        let answer = HTTP.refusal(failure, host: host)
        let answerText = text(answer)
        #expect(answerText.hasPrefix("HTTP/1.1 413 Content Too Large\r\n"))
        #expect(answerText.contains("Content-Type: application/json\r\n"))
        #expect(answerText.contains("Connection: close\r\n"))
        let range = try #require(answer.range(of: bytes("\r\n\r\n")))
        let body = answer.subdata(in: range.upperBound..<answer.count)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["jsonrpc"] as? String == "2.0")
        #expect(object["id"] is NSNull)
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32600)
        #expect(error["message"] as? String == HTTP.bodyLimitMessage)
        #expect(HTTP.bodyLimitMessage.contains("Remote writes are limited to 1 MB."))
    }

    @Test func otherFailuresAreBareAndAWrongHostStillGets421() {
        // A chunked body over the limit on /mcp gets the same JSON-RPC error.
        let half = Data(repeating: 0x62, count: HTTP.maximumBody / 2 + 1)
        guard case .failure(let chunkedFailure) = parse(chunked([half, half])) else { Issue.record("no failure"); return }
        #expect(text(HTTP.refusal(chunkedFailure, host: host)).contains(HTTP.bodyLimitMessage))
        // A body over the limit on the token door is a bare 413.
        let token = bytes("POST /oauth/token HTTP/1.1\r\nHost: mcp.example.com\r\nContent-Length: 2000000\r\n\r\n")
        guard case .failure(let tokenFailure) = parse(token) else { Issue.record("no failure"); return }
        #expect(HTTP.refusal(tokenFailure, host: host) == HTTP.refusal(status: 413))
        // The head was read, so a wrong Host or an Origin answers first.
        let wrongHost = bytes("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:40123\r\nContent-Length: 2000000\r\n\r\n")
        guard case .failure(let hostFailure) = parse(wrongHost) else { Issue.record("no failure"); return }
        #expect(HTTP.refusal(hostFailure, host: host) == HTTP.refusal(status: 421))
        let origin = bytes("POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\nOrigin: https://x.example\r\nContent-Length: 2000000\r\n\r\n")
        guard case .failure(let originFailure) = parse(origin) else { Issue.record("no failure"); return }
        #expect(HTTP.refusal(originFailure, host: host) == HTTP.refusal(status: 403))
        // No head to read: the failure's own status, bare.
        guard case .failure(let headFailure) = parse(head(ofSize: HTTP.maximumHead + 1)) else { Issue.record("no failure"); return }
        #expect(headFailure.request == nil)
        #expect(HTTP.refusal(headFailure, host: host) == HTTP.refusal(status: 431))
        guard case .failure(let badFailure) = parse("POST /mcp HTTP/1.1\r\nBroken\r\n\r\n") else { Issue.record("no failure"); return }
        #expect(HTTP.refusal(badFailure, host: host) == HTTP.refusal(status: 400))
        // Until a host is saved, a failure with a head gets 421 too.
        #expect(HTTP.refusal(tokenFailure, host: nil) == HTTP.refusal(status: 421))
    }

    // MARK: random input

    /// Feeds `data` in pieces whose sizes `random` picks, calling next after each, as the door does.
    func feedInPieces(_ data: Data, _ random: inout SplitMix) -> [HTTP.Parsed] {
        var parser = HTTP.Parser()
        var results: [HTTP.Parsed] = []
        var offset = 0
        while offset < data.count {
            let size = Int.random(in: 1...max(1, min(64, data.count - offset)), using: &random)
            _ = parser.append(data.subdata(in: offset..<(offset + size)))
            offset += size
            var parsed = parser.next()
            while isRead(parsed) {
                results.append(parsed)
                parsed = parser.next()
            }
            if case .failure = parsed {
                results.append(parsed)
                return results
            }
        }
        results.append(parser.next())
        return results
    }

    /// Everything a whole buffer gives, request by request, ending in "need more" or a failure.
    func feedWhole(_ data: Data) -> [HTTP.Parsed] {
        var parser = HTTP.Parser()
        _ = parser.append(data)
        var results: [HTTP.Parsed] = []
        while true {
            let parsed = parser.next()
            results.append(parsed)
            if isRead(parsed) { continue }
            return results
        }
    }

    /// A head or a request: something read, with more to ask for.
    func isRead(_ parsed: HTTP.Parsed) -> Bool {
        switch parsed {
        case .head, .request: return true
        case .needMore, .failure: return false
        }
    }

    func isWithinLimits(_ parsed: HTTP.Parsed) -> Bool {
        switch parsed {
        case .needMore:
            return true
        case .head(let request):
            return request.body.isEmpty && request.target.utf8.count < HTTP.maximumHead
        case .failure(let failure):
            return [400, 413, 431].contains(failure.status)
        case .request(let request):
            return request.body.count <= HTTP.maximumBody && request.target.utf8.count < HTTP.maximumHead
        }
    }

    @Test func randomBytesNeverCrashAndEndInNeedMoreOrA4xx() {
        var random = SplitMix(seed: 2026)
        for round in 0..<3000 {
            let count = Int.random(in: 0...(round % 50 == 0 ? 20_000 : 300), using: &random)
            let data = Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &random) })
            let parsed = parse(data)
            switch parsed {
            case .needMore:
                break
            case .failure(let failure):
                #expect((400..<500).contains(failure.status), "round \(round)")
            case .head, .request:
                Issue.record("random bytes made a request in round \(round)")
            }
        }
    }

    @Test func randomBytesFromHTTPsOwnAlphabetNeverCrash() {
        let alphabet = Array("GETPOST /mcp?&=:;HTTP/1.1\r\n\r\nHost: mcp.example.com\r\nContent-Length: 0123456789abcdef\t ,".utf8)
        var random = SplitMix(seed: 404)
        for round in 0..<3000 {
            let count = Int.random(in: 0...400, using: &random)
            let data = Data((0..<count).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &random)] })
            for parsed in feedWhole(data) {
                #expect(isWithinLimits(parsed), "round \(round)")
            }
        }
    }

    @Test func mutatedRequestsStayWithinTheLimitsWhateverPiecesTheyArriveIn() {
        let seeds: [String] = [
            "POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\nContent-Length: 13\r\n\r\n{\"id\":1,\"x\":}",
            "POST /mcp HTTP/1.1\r\nHost: mcp.example.com\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nabcd\r\n2;x=y\r\nef\r\n0\r\nT: v\r\n\r\n",
            "GET /oauth/authorize?state=1 HTTP/1.1\r\nHost: MCP.example.com:443\r\nAccept: */*\r\n\r\n",
            "POST /oauth/token HTTP/1.1\r\nHost: mcp.example.com\r\nContent-Length: 4\r\n\r\nabcdPOST /mcp HTTP/1.1\r\n\r\n",
        ]
        var random = SplitMix(seed: 77)
        for round in 0..<3000 {
            var data = Array(seeds[round % seeds.count].utf8)
            for _ in 0..<Int.random(in: 1...6, using: &random) {
                let position = Int.random(in: 0...data.count, using: &random)
                switch Int.random(in: 0..<4, using: &random) {
                case 0 where position < data.count:
                    data[position] = UInt8.random(in: 0...255, using: &random)
                case 1 where position < data.count:
                    data.remove(at: position)
                case 2:
                    let pick: [UInt8] = [13, 10, 58, 32, 48, 70, 59, 0, 255]
                    data.insert(pick[Int.random(in: 0..<pick.count, using: &random)], at: position)
                default:
                    data.insert(contentsOf: Array("\r\n".utf8), at: position)
                }
            }
            let whole = feedWhole(Data(data))
            for parsed in whole {
                #expect(isWithinLimits(parsed), "round \(round)")
            }
            // The pieces a request arrives in never change what it parses to.
            let pieces = feedInPieces(Data(data), &random)
            #expect(pieces == whole, "round \(round): \(String(decoding: data, as: UTF8.self).debugDescription)")
        }
    }

    @Test func randomHostsPassOnlyWhenTheyNameTheConfiguredHost() {
        let alphabet = Array("mcpexample.com:443MCP.EXAMPLE-1".utf8)
        var random = SplitMix(seed: 421)
        for _ in 0..<5000 {
            let count = Int.random(in: 0...24, using: &random)
            let value = String(decoding: (0..<count).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &random)] },
                               as: UTF8.self)
            var expected = value.lowercased()
            if expected.hasSuffix(":443") { expected.removeLast(4) }
            #expect(HTTP.hostMatches(value, host: host) == (expected == host), "\(value)")
        }
        #expect(HTTP.hostMatches("mcp.example.com:443", host: host))
    }
}

enum HTTPTestError: Error { case noRequest }
