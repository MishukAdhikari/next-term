import Foundation

/// One remote MCP server, reached by the app for every agent session that uses it: MCP's Streamable HTTP transport
/// (2025-03-26 and later), each message a POST whose answer is JSON or a short event stream. The app holds one per
/// server, so one connection (one Mcp-Session-Id) serves every agent, and its keys never leave the app: each need is
/// given the URL and headers with `${secret:NAME}` already filled in (`Endpoint`), used for that need and kept nowhere.
///
/// - **Sessions.** The Mcp-Session-Id the server gives at initialize goes with every later request; a 404 to one
///   means the server ended it, so Next Term starts a new one and asks once more.
/// - **Versions.** Next Term offers its newest MCP version and speaks the one the server answers, if it knows it,
///   sending it as MCP-Protocol-Version from then on; one it doesn't know ends the start (MCP's lifecycle).
/// - **Limits.** As a local server's (MCPHubUpstream.Limits): 30 seconds to start, 50 for a call, 32 MB an answer.
/// - **Where.** MCPHubAddress's one rule: https to a domain on the internet or the user's own network, http to this Mac
///   or a Tailscale name, checked before each request and again against the address the connection used. No redirect is followed to
///   another server, nor one that would turn a call into a GET, so a key is never sent where its URL didn't say.
/// - **Keys refused.** A 401 or 403 is `Failure.Kind.unauthorized`, with the server's WWW-Authenticate: the sentence
///   tells the agent to have the user check the key in Settings › MCP Servers. Signing in with OAuth comes later, at
///   that seam: the challenge names the server's resource metadata, and the token it gets is one more filled header.
///
/// The older HTTP+SSE transport (2024-11-05: a GET stream, and POSTs to the endpoint it names) is not spoken; an `sse`
/// entry stays listed as one Next Term doesn't reach (MCPHubPlan.State.remote). No GET stream is opened for the
/// server's own messages either: Next Term offers servers nothing to ask of it, and a tool list is asked again when old.
public final class MCPHubRemote: @unchecked Sendable {
    /// The URL and headers for one need, keys filled in. `keyed`: a key from Secrets is in them, for what a 401 says.
    public struct Endpoint: Sendable {
        public var url: URL
        public var headers: [String: String]
        public var keyed: Bool

        public init(url: URL, headers: [String: String] = [:], keyed: Bool = false) {
            self.url = url
            self.headers = headers
            self.keyed = keyed
        }
    }

    /// Why a need wasn't met, as a sentence for the agent; `unauthorized` when the server refused the key (or its lack).
    public struct Failure: Error, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case other
            /// HTTP 401 or 403, with the server's WWW-Authenticate when it sent one: where an OAuth sign-in starts.
            case unauthorized(status: Int, challenge: String?)
        }

        public let text: String
        public let kind: Kind

        public init(_ text: String, kind: Kind = .other) {
            self.text = text
            self.kind = kind
        }
    }

    /// How long a tool list is used before it is asked for again.
    public static let listLife: TimeInterval = 300

    public let name: String
    let limits: MCPHubUpstream.Limits
    let clientVersion: String
    private let urlSession: URLSession
    private let router: Router

    private let lock = NSLock()
    /// Held while starting, so a second need waits for the first one's start.
    private let starting = NSLock()
    private var started = false
    private var sessionID: String?
    private var version: String?
    private var listed: [[String: Any]]?
    private var listedAt = Date.distantPast
    private var lastFailure: String?
    private var nextID = 1

    public init(name: String, limits: MCPHubUpstream.Limits = .standard, clientVersion: String) {
        self.name = name
        self.limits = limits
        self.clientVersion = clientVersion
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForResource = max(limits.call, limits.start) + 10
        router = Router(limit: limits.message)
        urlSession = URLSession(configuration: configuration, delegate: router, delegateQueue: Self.delegateQueue("remote"))
    }

    /// The queue a URL session's delegate is called on, for a session whose caller waits on a semaphore for what the
    /// delegate says: one serial dispatch queue of its own under it. An OperationQueue's own queue is a concurrent one,
    /// which GCD runs only while a CPU is free of the process's other work at its QoS or above, so a busy moment (a dozen
    /// threads computing, a test run's suites in parallel) held an answer that had already arrived for 18 to 30 seconds
    /// and the call timed out. A serial queue is overcommitting: GCD gives it a thread whenever it has work.
    static func delegateQueue(_ label: String) -> OperationQueue {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.underlyingQueue = DispatchQueue(label: "nextterm.mcp-hub." + label, qos: .userInitiated)
        return queue
    }

    deinit { urlSession.invalidateAndCancel() }

    /// The endpoint for `server` with each `${secret:NAME}` in its URL and headers filled from `values` (the app's, just
    /// released from the vault): in a header as it is, in the URL percent-encoded. Never kept: made for one need.
    /// A key with a line break can't be a header's, and a server whose URL no longer parses after filling is refused.
    public static func endpoint(for server: MCPHubServer, values: [String: String]) -> Result<Endpoint, Failure> {
        let names = MCPHubRules.secretNames(in: ([server.url] + Array(server.headers.values)).joined(separator: "\n"))
        if let missing = names.first(where: { values[$0] == nil }) {
            return .failure(Failure("\(server.name) needs the key \(missing) from Secrets, and Next Term didn't get it."))
        }
        // RFC 3986's unreserved characters alone, as SecretMask's percent-encoded form has them: a key in a sentence
        // that quotes the URL (a redirect's, or one that can't be reached) is then masked like any other.
        let query = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func filled(_ text: String, inURL: Bool) -> String {
            var out = text
            for name in Set(names) {
                let value = values[name] ?? ""
                out = out.replacingOccurrences(of: "${secret:\(name)}",
                                               with: inURL ? value.addingPercentEncoding(withAllowedCharacters: query) ?? "" : value)
            }
            return out
        }
        var headers: [String: String] = [:]
        for (key, value) in server.headers {
            let full = filled(value, inURL: false)
            if full.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) {
                return .failure(Failure("A key in \(server.name)'s \(key) header has a line break, which a header can't carry; "
                    + "ask the user to check it in Next Term › Settings › Secrets."))
            }
            headers[key] = full
        }
        guard let url = URL(string: filled(server.url, inURL: true)), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host?.isEmpty == false else {
            return .failure(Failure("\(server.name)'s URL isn't one Next Term can reach once its key is in it."))
        }
        return .success(Endpoint(url: url, headers: headers, keyed: !names.isEmpty))
    }

    // MARK: state

    public var status: MCPHubUpstream.Status {
        lock.lock()
        defer { lock.unlock() }
        if let listed, started { return .running(tools: listed.count) }
        if let lastFailure { return .failed(lastFailure) }
        return .notStarted
    }

    /// The tools it listed last, without reaching it: nil before its first start, or after a failure.
    public var cachedTools: [[String: Any]]? {
        lock.lock()
        defer { lock.unlock() }
        return started ? listed : nil
    }

    // MARK: needs

    /// Its tools, starting a session first when there is none, and asking again when the list is old.
    public func tools(_ endpoint: Endpoint, until deadline: Date) -> Result<[[String: Any]], Failure> {
        if let fresh = freshList() { return .success(fresh) }
        guard starting.lock(before: deadline) else {
            return .failure(Failure("\(name) is still being reached for another call; try again in a moment."))
        }
        defer { starting.unlock() }
        if let fresh = freshList() { return .success(fresh) }
        let until = min(deadline, Date().addingTimeInterval(limits.start))
        var result = list(endpoint, until: until)
        if case .failure(let failure) = result, failure == Self.expired {
            reset()
            result = list(endpoint, until: until)
        }
        lock.lock()
        switch result {
        case .success(let tools):
            listed = tools
            listedAt = Date()
            lastFailure = nil
        case .failure(let failure):
            lastFailure = failure == Self.expired ? "\(name) ended Next Term's session twice in a row." : failure.text
            started = false
            listed = nil
        }
        lock.unlock()
        if case .failure(let failure) = result, failure == Self.expired {
            return .failure(Failure("\(name) ended Next Term's session twice in a row; try again in a moment."))
        }
        return result
    }

    /// Calls one of its tools: the result object it answered (content, isError, structuredContent), as it is.
    public func call(_ tool: String, arguments: [String: Any], endpoint: Endpoint, until deadline: Date) -> Result<[String: Any], Failure> {
        for attempt in 0..<2 {
            if case .failure(let failure) = tools(endpoint, until: deadline) { return .failure(failure) }
            let answer: [String: Any]
            switch exchange("tools/call", ["name": tool, "arguments": arguments], endpoint: endpoint, until: deadline) {
            case .failure(let failure):
                if failure == Self.expired, attempt == 0 { reset(); continue } // the server ended the session: a new one
                if failure == Self.expired { return .failure(Failure("\(name) ended Next Term's session twice in a row.")) }
                if case .unauthorized = failure.kind { remember(failure) }
                return .failure(failure)
            case .success(let found): answer = found
            }
            if let error = answer["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "no message"
                return .failure(Failure("\(name) answered \(tool) with an error: \(message)"))
            }
            guard let result = answer["result"] as? [String: Any] else {
                return .failure(Failure("\(name) answered \(tool) with something that isn't a tool's result."))
            }
            return .success(result)
        }
        return .failure(Failure("\(name) didn't answer \(tool)."))
    }

    // MARK: starting

    private func freshList() -> [[String: Any]]? {
        lock.lock()
        defer { lock.unlock() }
        guard started, let listed, Date().timeIntervalSince(listedAt) < Self.listLife else { return nil }
        return listed
    }

    private func reset() {
        lock.lock()
        started = false
        sessionID = nil
        version = nil
        listed = nil
        lock.unlock()
    }

    /// A refused key: the session is over for Next Term, and the next need starts a new one.
    private func remember(_ failure: Failure) {
        lock.lock()
        lastFailure = failure.text
        started = false
        listed = nil
        lock.unlock()
    }

    /// A session (initialize, then initialized) when there is none, then every page of its tool list.
    private func list(_ endpoint: Endpoint, until deadline: Date) -> Result<[[String: Any]], Failure> {
        lock.lock()
        let isStarted = started
        lock.unlock()
        if !isStarted, case .failure(let failure) = initialize(endpoint, until: deadline) { return .failure(failure) }
        var tools: [[String: Any]] = []
        var cursor: String?
        for _ in 0..<50 {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let page: [String: Any]
            switch exchange("tools/list", params, endpoint: endpoint, until: deadline) {
            case .failure(let failure): return .failure(failure)
            case .success(let answer): page = answer
            }
            guard let result = page["result"] as? [String: Any], let found = result["tools"] as? [[String: Any]] else {
                return .failure(Failure("\(name) was reached, and its tool list isn't one MCP has."))
            }
            tools += found.filter { $0["name"] is String }
            cursor = result["nextCursor"] as? String
            if cursor == nil || tools.count >= 2_000 { break }
        }
        return .success(tools)
    }

    private func initialize(_ endpoint: Endpoint, until deadline: Date) -> Result<Void, Failure> {
        let hello: [String: Any] = [
            "protocolVersion": MCPServer.supportedVersions[0], "capabilities": [String: Any](),
            "clientInfo": ["name": MCPServer.name, "title": "Next Term", "version": clientVersion],
        ]
        let reply: Reply
        switch post(request: "initialize", hello, endpoint: endpoint, until: deadline) {
        case .failure(let failure): return .failure(failure)
        case .success(let got): reply = got
        }
        let answer = reply.message ?? [:]
        if let error = answer["error"] as? [String: Any] {
            return .failure(Failure("\(name) refused Next Term's start: \(error["message"] as? String ?? "no reason given")."))
        }
        guard let result = answer["result"] as? [String: Any] else {
            return .failure(Failure("\(name) answered Next Term's start with something that isn't MCP's."))
        }
        guard let spoken = result["protocolVersion"] as? String, MCPServer.supportedVersions.contains(spoken) else {
            let named = (result["protocolVersion"] as? String).map { "MCP version \($0)" } ?? "no MCP version"
            return .failure(Failure("\(name) answered with \(named), and Next Term speaks "
                + MCPServer.supportedVersions.joined(separator: ", ") + "."))
        }
        // Visible ASCII only, as MCP says; anything else is no session id.
        let id = reply.headers["mcp-session-id"].flatMap { value in
            !value.isEmpty && value.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) ? value : nil
        }
        lock.lock()
        sessionID = id
        version = spoken
        lock.unlock()
        let note = post(request: nil, ["jsonrpc": "2.0", "method": "notifications/initialized"], endpoint: endpoint, until: deadline)
        if case .failure(let failure) = note, failure.kind != .other || failure == Self.expired { return .failure(failure) }
        lock.lock()
        started = true
        lock.unlock()
        return .success(())
    }

    // MARK: messages

    /// The failure that means the server ended the session (a 404 to a request that carried its id).
    static let expired = Failure("session ended")

    /// One request and the message that answers it, in a session already started.
    private func exchange(_ method: String, _ params: [String: Any], endpoint: Endpoint, until deadline: Date) -> Result<[String: Any], Failure> {
        switch post(request: method, params, endpoint: endpoint, until: deadline) {
        case .failure(let failure): return .failure(failure)
        case .success(let reply): return .success(reply.message ?? [:])
        }
    }

    struct Reply {
        var status: Int
        /// Header names lowercased.
        var headers: [String: String]
        /// The answer to the request, by its id; nil for a notification's.
        var message: [String: Any]?
    }

    /// POSTs one message: a request (`method`, then `params` are its params) or, with no method, `params` as the whole
    /// message (a notification). A request's answer is found by its id in the JSON or event stream that comes back.
    private func post(request method: String?, _ params: [String: Any], endpoint: Endpoint, until deadline: Date) -> Result<Reply, Failure> {
        var id: Int?
        var message = params
        lock.lock()
        let session = sessionID, spoken = version
        if let method {
            id = nextID
            nextID += 1
            message = ["jsonrpc": "2.0", "id": id ?? 0, "method": method, "params": params]
        }
        lock.unlock()
        guard JSONSerialization.isValidJSONObject(message),
              let body = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else {
            return .failure(Failure("Next Term couldn't write that call to \(name) as JSON."))
        }
        let host = endpoint.url.host ?? ""
        guard let addresses = MCPHubAddress.resolve(host, until: deadline) else {
            return .failure(Failure("\(name) can't be reached: looking up \(host) took longer than the call may."))
        }
        if let reason = MCPHubAddress.reason(url: endpoint.url, addresses: addresses, name: name) { return .failure(Failure(reason)) }
        let left = deadline.timeIntervalSinceNow
        guard left > 0 else { return .failure(Failure("\(name) didn't answer Next Term's \(method == "initialize" ? "start" : "call") in time.")) }

        // URLSession's own timeout a moment after the deadline, so the wait here is the one that ends it.
        var request = URLRequest(url: endpoint.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: left + 1)
        request.httpMethod = "POST"
        request.httpBody = body
        // The server's own headers first, so none of them can stand in for the transport's.
        for (key, value) in endpoint.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("NextTerm/\(clientVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
        request.setValue(spoken, forHTTPHeaderField: "MCP-Protocol-Version")

        let task = urlSession.dataTask(with: request)
        let exchange = router.begin(task, origin: endpoint.url, expecting: id, name: name)
        task.resume()
        let what = method == "initialize" ? "start" : method == nil ? "notice" : "call"
        guard exchange.done.wait(timeout: .now() + max(0, left)) == .success else {
            task.cancel()
            router.end(task)
            return .failure(Failure("\(name) didn't answer Next Term's \(what) in time."))
        }
        router.end(task)
        answerRequests(exchange.serverRequests, endpoint: endpoint)
        if let refused = exchange.refusedRedirect { return .failure(Failure(refused)) }
        if exchange.tooLarge {
            let most = ByteCountFormatter.string(fromByteCount: Int64(limits.message), countStyle: .binary)
            return .failure(Failure("\(name) sent an answer over the \(most) Next Term reads."))
        }
        // The address the connection used (not through a proxy): a name that resolved elsewhere by then is thrown away.
        if !exchange.viaProxy, let used = MCPHubAddress.connected(exchange.remoteAddress),
           let reason = MCPHubAddress.reason(url: endpoint.url, addresses: [used], name: name) {
            return .failure(Failure(reason))
        }
        guard let response = exchange.response else {
            if (exchange.error as? URLError)?.code == .timedOut { return .failure(Failure("\(name) didn't answer Next Term's \(what) in time.")) }
            let why = exchange.error.map { ": " + $0.localizedDescription } ?? "."
            return .failure(Failure("\(name) can't be reached at \(Self.shown(endpoint.url))\(why)"))
        }
        let status = response.statusCode
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        if status == 401 || status == 403 {
            if Self.isCloudflareAccess(headers: headers, body: exchange.body) {
                return .failure(Failure(Self.cloudflareAccess(name, status: status, sent: endpoint.headers),
                                        kind: .unauthorized(status: status, challenge: headers["www-authenticate"])))
            }
            return .failure(unauthorized(status, challenge: headers["www-authenticate"], keyed: endpoint.keyed))
        }
        if status == 404, session != nil { return .failure(Self.expired) }
        guard (200..<300).contains(status) else {
            let said = String(decoding: exchange.body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let quoted = said.isEmpty ? "" : ": " + MCPRedaction.redact(String(said.prefix(200))).text
            return .failure(Failure("\(name) answered Next Term's \(what) with HTTP \(status)\(quoted)"))
        }
        guard let id else { return .success(Reply(status: status, headers: headers, message: nil)) }
        if exchange.answer == nil { exchange.finish() }
        guard let answer = exchange.answer else {
            if exchange.error != nil, !exchange.found {
                return .failure(Failure("\(name)'s answer to Next Term's \(what) broke off: \(exchange.error?.localizedDescription ?? "")"))
            }
            return .failure(Failure("\(name) answered Next Term's \(what), and no MCP message in it is the answer (id \(id))."))
        }
        return .success(Reply(status: status, headers: headers, message: answer))
    }

    /// What the agent is told of a 401 or 403: the user checks the key in Settings › MCP Servers.
    func unauthorized(_ status: Int, challenge: String?, keyed: Bool) -> Failure {
        let code = "HTTP \(status)"
        let text: String
        if keyed {
            text = "\(name) refused the key Next Term sent (\(code)). Ask the user to check \(name)'s key in Next Term › Settings › MCP Servers, "
                + "and in Settings › Secrets that the key is the right one and still valid."
        } else {
            text = "\(name) asks for a key or a sign-in (\(code)), and Next Term sends none. Ask the user to give \(name) its key in "
                + "Next Term › Settings › MCP Servers (a header with a key from Secrets); Next Term doesn't sign in to servers yet."
        }
        return Failure(text, kind: .unauthorized(status: status, challenge: challenge))
    }

    /// Whether a 401 or 403 (or a redirect, `to`) is Cloudflare Access asking for a sign-in: its login host, its
    /// `cf-access-*` headers, its challenge, or its login page's address in the body. Never followed.
    static func isCloudflareAccess(headers: [String: String] = [:], body: Data = Data(), to target: URL? = nil) -> Bool {
        if let host = target?.host?.lowercased(), host == "cloudflareaccess.com" || host.hasSuffix(".cloudflareaccess.com") { return true }
        if target?.path.hasPrefix("/cdn-cgi/access/") == true { return true }
        if headers.keys.contains(where: { $0.lowercased().hasPrefix("cf-access-") }) { return true }
        if headers.first(where: { $0.key.lowercased() == "www-authenticate" })?.value.lowercased().contains("cloudflare-access") == true { return true }
        return String(decoding: body.prefix(8192), as: UTF8.self).lowercased().contains("cloudflareaccess.com")
    }

    /// What the agent is told of a server behind Cloudflare Access: a service token's two headers, in Settings.
    static func cloudflareAccess(_ name: String, status: Int?, sent: [String: String]) -> String {
        let code = status.map { " (HTTP \($0))" } ?? ""
        if sent.keys.contains(where: { $0.lowercased() == "cf-access-client-id" }) {
            return "\(name) is behind Cloudflare Access, which refused the service token Next Term sent\(code). Ask the user to check "
                + "\(name)\u{2019}s CF-Access-Client-Id and CF-Access-Client-Secret headers in Next Term › Settings › MCP Servers, and the token in Cloudflare."
        }
        return "\(name) is behind Cloudflare Access, which asks for a sign-in Next Term doesn\u{2019}t give\(code). Ask the user to add a "
            + "service token\u{2019}s two headers to \(name) in Next Term › Settings › MCP Servers: CF-Access-Client-Id and "
            + "CF-Access-Client-Secret, each a key from Secrets."
    }

    /// The server's own requests that came in an event stream: a ping is answered, anything else refused, since Next
    /// Term offers servers nothing to ask of it. Not waited for.
    private func answerRequests(_ requests: [[String: Any]], endpoint: Endpoint) {
        for request in requests {
            guard let id = request["id"], !(id is NSNull) else { continue }
            let method = request["method"] as? String ?? ""
            let answer: [String: Any] = method == "ping"
                ? ["jsonrpc": "2.0", "id": id, "result": [String: Any]()]
                : ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Next Term doesn't offer \(method)"]]
            DispatchQueue.global(qos: .utility).async { [self] in
                _ = post(request: nil, answer, endpoint: endpoint, until: Date().addingTimeInterval(5))
            }
        }
    }

    /// A URL as a sentence shows it: its scheme, host, port and path, never its query (which may hold a key).
    static func shown(_ url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.query = nil
        parts?.fragment = nil
        parts?.user = nil
        parts?.password = nil
        return parts?.string ?? url.absoluteString
    }

    // MARK: transport

    /// One request in flight: what came back, read as it comes, so an event stream ends as soon as it holds the answer.
    final class Exchange: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        let origin: URL
        let expecting: Int?
        let name: String
        let limit: Int
        var response: HTTPURLResponse?
        var body = Data()
        var isStream = false
        private var line = Data()
        private var event: [String] = []
        var answer: [String: Any]?
        var found = false
        var serverRequests: [[String: Any]] = []
        static let mostServerRequests = 8
        var tooLarge = false
        var refusedRedirect: String?
        var remoteAddress: String?
        var viaProxy = false
        var error: Error?

        init(origin: URL, expecting: Int?, name: String, limit: Int) {
            self.origin = origin
            self.expecting = expecting
            self.name = name
            self.limit = limit
        }

        /// Data as it comes: kept whole for JSON, and read line by line for an event stream. True once the answer is in.
        func received(_ data: Data) -> Bool {
            if body.count + data.count > limit {
                tooLarge = true
                return true
            }
            body.append(data)
            guard isStream else { return false }
            for byte in data {
                guard byte == 0x0A else { line.append(byte); continue }
                var text = String(decoding: line, as: UTF8.self)
                line.removeAll(keepingCapacity: true)
                if text.hasSuffix("\r") { text.removeLast() }
                if text.isEmpty {
                    if dispatch() { return true }
                } else if text.hasPrefix("data:") {
                    var value = String(text.dropFirst(5))
                    if value.hasPrefix(" ") { value.removeFirst() }
                    event.append(value)
                }
                // event:, id:, retry: and comments say nothing Next Term needs.
            }
            return false
        }

        /// One event's data: an MCP message, or a batch of them.
        private func dispatch() -> Bool {
            defer { event = [] }
            guard !event.isEmpty, let object = try? JSONSerialization.jsonObject(with: Data(event.joined(separator: "\n").utf8)) else {
                return false
            }
            return take(object)
        }

        /// The body once it is whole: a JSON answer read, or an event stream's last event, sent with no blank line after it.
        func finish() {
            if isStream {
                if !line.isEmpty || !event.isEmpty { _ = received(Data([0x0A, 0x0A])) }
            } else if let object = try? JSONSerialization.jsonObject(with: body) {
                _ = take(object)
            }
        }

        private func take(_ object: Any) -> Bool {
            let messages = (object as? [[String: Any]]) ?? ((object as? [String: Any]).map { [$0] } ?? [])
            for message in messages {
                if message["method"] is String {
                    // A request or a notification of the server's own: each request is answered with a POST of its
                    // own, so a few at most, or one answer could make Next Term send thousands.
                    if serverRequests.count < Self.mostServerRequests { serverRequests.append(message) }
                } else if let expecting, (message["id"] as? NSNumber)?.intValue == expecting {
                    answer = message
                    found = true
                    return true
                }
            }
            return false
        }
    }

    /// The URL session's delegate: each task's data to its exchange, the redirect rule, and the address it used.
    final class Router: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var exchanges: [Int: Exchange] = [:]
        let limit: Int

        init(limit: Int) { self.limit = limit }

        func begin(_ task: URLSessionTask, origin: URL, expecting: Int?, name: String) -> Exchange {
            let exchange = Exchange(origin: origin, expecting: expecting, name: name, limit: limit)
            lock.lock()
            exchanges[task.taskIdentifier] = exchange
            lock.unlock()
            return exchange
        }

        func end(_ task: URLSessionTask) {
            lock.lock()
            exchanges[task.taskIdentifier] = nil
            lock.unlock()
        }

        private func exchange(_ task: URLSessionTask) -> Exchange? {
            lock.lock()
            defer { lock.unlock() }
            return exchanges[task.taskIdentifier]
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let exchange = exchange(dataTask), let http = response as? HTTPURLResponse {
                exchange.response = http
                let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                exchange.isStream = type.hasPrefix("text/event-stream")
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard let exchange = exchange(dataTask) else { return }
            // The answer in: the stream is let go (a server may keep it open); what came is enough.
            if exchange.received(data) { dataTask.cancel() }
        }

        /// Only to the same scheme, host and port, and only a 307 or 308, which keep the POST and its body.
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let exchange = exchange(task) else { return completionHandler(nil) }
            let target = request.url
            let same = target?.scheme?.lowercased() == exchange.origin.scheme?.lowercased()
                && target?.host?.lowercased() == exchange.origin.host?.lowercased()
                && (target?.port ?? Self.port(target)) == (exchange.origin.port ?? Self.port(exchange.origin))
            if same, response.statusCode == 307 || response.statusCode == 308 { return completionHandler(request) }
            let place = target.map(MCPHubRemote.shown) ?? "another address"
            if MCPHubRemote.isCloudflareAccess(to: target) {
                exchange.refusedRedirect = MCPHubRemote.cloudflareAccess(exchange.name, status: nil, sent: task.originalRequest?.allHTTPHeaderFields ?? [:])
            } else if same {
                exchange.refusedRedirect = "\(exchange.name) redirected Next Term with HTTP \(response.statusCode) to \(place), "
                    + "which would turn its calls into GETs. Ask the user to use that URL for \(exchange.name) in Settings › MCP Servers."
            } else {
                exchange.refusedRedirect = "\(exchange.name) redirected Next Term to \(place). Next Term follows no redirect to another "
                    + "server, so its key never goes where its URL didn't say; if that is \(exchange.name)'s own address, ask the user "
                    + "to use it in Settings › MCP Servers."
            }
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            guard let exchange = exchange(task), let last = metrics.transactionMetrics.last(where: { $0.remoteAddress != nil }) else { return }
            exchange.remoteAddress = last.remoteAddress
            exchange.viaProxy = last.isProxyConnection
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let exchange = exchange(task) else { return }
            // Cancelled here once the answer was in, or the answer grew too large: no error of the server's.
            let ours = (error as? URLError)?.code == .cancelled && (exchange.found || exchange.tooLarge)
            if exchange.refusedRedirect == nil, !ours { exchange.error = error }
            exchange.done.signal()
        }

        static func port(_ url: URL?) -> Int? {
            switch url?.scheme?.lowercased() {
            case "https": return 443
            case "http": return 80
            default: return nil
            }
        }
    }
}
