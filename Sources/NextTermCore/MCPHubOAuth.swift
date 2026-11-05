import Foundation

/// Signing in to a remote MCP server with OAuth (the MCP spec's authorization, 2026-07-28): Next Term is the server's
/// one OAuth client, for every agent, and its one refresher. The pieces, each pure and given its requests' `Fetch`:
///
/// - MCPHubOAuthChallenge reads the 401's WWW-Authenticate; MCPHubOAuthURL holds every URL to its rules.
/// - MCPHubOAuthDiscovery finds the server's resource metadata (RFC 9728) and its authorization server's (RFC 8414).
/// - MCPHubOAuthRegistration finds the client: the user's own, or one registered for Next Term (RFC 7591).
/// - MCPHubOAuthFlow makes PKCE, `state`, the authorization URL, and reads the callback and the token answers.
/// - SignInFile keeps the tokens sealed beside the vault; SignInRefresher refreshes each sign-in once at a time.
///
/// The requests go through `MCPHubOAuthHTTP` in the app, the tests' fake through the same one.
public enum MCPHubOAuth {
    /// One request of a sign-in: a GET of metadata, or a POST of a form (token, revocation) or JSON (registration).
    public struct Request: Sendable {
        public var method: String
        public var url: URL
        public var form: [(String, String)]?
        public var json: Data?
        public var headers: [String: String]

        public init(get url: URL) {
            method = "GET"
            self.url = url
            form = nil
            json = nil
            headers = ["Accept": "application/json"]
        }

        public init(post url: URL, form: [(String, String)], headers: [String: String] = [:]) {
            method = "POST"
            self.url = url
            self.form = form
            json = nil
            self.headers = headers.merging(["Accept": "application/json"]) { a, _ in a }
        }

        public init(post url: URL, json: Data) {
            method = "POST"
            self.url = url
            form = nil
            self.json = json
            headers = ["Accept": "application/json"]
        }

        /// The body as sent: the form encoded (RFC 3986's unreserved characters alone left as they are), or the JSON.
        public var body: Data? {
            if let json { return json }
            guard let form else { return nil }
            return Data(form.map { MCPHubOAuth.encode($0.0) + "=" + MCPHubOAuth.encode($0.1) }.joined(separator: "&").utf8)
        }

        /// The form's value for `name`, for the tests and the fake.
        public func value(_ name: String) -> String? { form?.first { $0.0 == name }?.1 }
    }

    public struct Response: Sendable {
        public var status: Int
        /// Names lowercased.
        public var headers: [String: String]
        public var body: Data

        public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
            self.status = status
            self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
            self.body = body
        }

        public var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
    }

    /// Why a request got no answer. `unsent`: it surely never left (no address, no connection, a rule refused it), so a
    /// refresh token in it isn't spent; `lost`: some of it may have left, so a refresh token in it is spent.
    public enum FetchFailure: Error, Equatable, Sendable {
        case unsent(String)
        case lost(String)

        public var text: String {
            switch self {
            case .unsent(let text), .lost(let text): return text
            }
        }
    }

    public typealias Fetch = @Sendable (Request) -> Result<Response, FetchFailure>

    /// Why a sign-in step failed, as a sentence for the user (Settings) or the agent.
    public struct Failure: Error, Equatable, Sendable, ExpressibleByStringLiteral {
        public let text: String
        public init(_ text: String) { self.text = text }
        public init(stringLiteral text: String) { self.text = text }
    }

    static func encode(_ text: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// A form body read back (`a=b&c=d`), for the fake and the loopback callback's query.
    public static func decodeForm(_ text: String) -> [(String, String)] {
        text.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decoded(_ part: Substring) -> String {
                String(part).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(part)
            }
            return (decoded(parts[0]), parts.count > 1 ? decoded(parts[1]) : "")
        }
    }
}

/// The sign-in's requests, sent as MCPHubRemote sends a call's: an ephemeral session with no cookies and no cache, no
/// redirect followed (a 3xx comes back as it is), and the server's name resolved and held to MCPHubAddress's rule, the
/// one a server's own URL is, before the request and again against the address the connection used: a sign-in server
/// in the user's own network over https is reached as the MCP server there is; link-local, reserved and, for a server
/// not on this Mac, this Mac's addresses never are.
public final class MCPHubOAuthHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public let server: URL
    let limit: Int
    private var session: URLSession!
    private let lock = NSLock()
    private var exchanges: [Int: Exchange] = [:]

    final class Exchange: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var response: HTTPURLResponse?
        var body = Data()
        var error: Error?
        var address: String?
        var proxy = false
        var tooLarge = false
    }

    public init(server: URL, limit: Int = 1 << 20) {
        self.server = server
        self.limit = limit
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: MCPHubRemote.delegateQueue("sign-in"))
    }

    deinit { session.invalidateAndCancel() }

    /// One request, within `seconds`.
    public func fetch(_ request: MCPHubOAuth.Request, seconds: TimeInterval = 15) -> Result<MCPHubOAuth.Response, MCPHubOAuth.FetchFailure> {
        let host = request.url.host ?? ""
        if case .failure(let why) = MCPHubOAuthURL.checked(request.url.absoluteString, server: server) {
            return .failure(.unsent("\(host) isn\u{2019}t one Next Term signs in through: " + why.text + "."))
        }
        let deadline = Date().addingTimeInterval(seconds)
        guard let addresses = MCPHubAddress.resolve(host, until: deadline) else {
            return .failure(.unsent("Looking up \(host) took too long."))
        }
        if let why = reason(request.url, addresses: addresses) { return .failure(.unsent(why)) }
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: seconds)
        urlRequest.httpMethod = request.method
        for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
        if request.form != nil { urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
        if request.json != nil { urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        urlRequest.setValue("NextTerm", forHTTPHeaderField: "User-Agent")
        urlRequest.httpBody = request.body
        let task = session.dataTask(with: urlRequest)
        let exchange = Exchange()
        lock.lock()
        exchanges[task.taskIdentifier] = exchange
        lock.unlock()
        defer {
            lock.lock()
            exchanges[task.taskIdentifier] = nil
            lock.unlock()
        }
        task.resume()
        guard exchange.done.wait(timeout: .now() + seconds + 1) == .success else {
            task.cancel()
            let why = "\(host) didn\u{2019}t answer in time."
            return .failure(task.countOfBytesSent > 0 || exchange.response != nil ? .lost(why) : .unsent(why))
        }
        if !exchange.proxy, let address = MCPHubAddress.connected(exchange.address), let why = reason(request.url, addresses: [address]) {
            return .failure(.lost(why))
        }
        if exchange.tooLarge { return .failure(.lost("\(host) sent an answer larger than a sign-in\u{2019}s.")) }
        guard let response = exchange.response else {
            let never: Set<URLError.Code> = [.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
                                             .badURL, .unsupportedURL, .appTransportSecurityRequiresSecureConnection]
            let why = "\(host) can\u{2019}t be reached" + (exchange.error.map { ": " + $0.localizedDescription } ?? ".")
            if let code = (exchange.error as? URLError)?.code, never.contains(code), task.countOfBytesSent == 0 { return .failure(.unsent(why)) }
            return .failure(.lost(why))
        }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        return .success(MCPHubOAuth.Response(status: response.statusCode, headers: headers, body: exchange.body))
    }

    /// The fetch to hand the sign-in's pieces.
    public var asFetch: MCPHubOAuth.Fetch { { [self] request in fetch(request) } }

    /// Why `url`'s host, at these addresses, isn't reached for a sign-in; nil when it may be. MCPHubAddress's rule, and
    /// this Mac only for a server on this Mac (MCPHubOAuthURL.checked has refused the rest by name already).
    func reason(_ url: URL, addresses: [[UInt8]]) -> String? {
        let host = url.host ?? ""
        if MCPHubOAuthURL.isThisMac(url) {
            guard MCPHubOAuthURL.isThisMac(server) else {
                return "\(host) is this Mac, where a sign-in for \(server.host ?? "this server") never goes."
            }
            return !addresses.isEmpty && addresses.allSatisfy { MCPHubAddress.kind($0) == .loopback } ? nil
                : "\(host) should be this Mac, and it resolves to another machine."
        }
        return MCPHubAddress.reason(url: url, addresses: addresses, name: "The sign-in server")
    }

    // MARK: delegate

    private func exchange(_ task: URLSessionTask) -> Exchange? {
        lock.lock()
        defer { lock.unlock() }
        return exchanges[task.taskIdentifier]
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        exchange(dataTask)?.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let exchange = exchange(dataTask) else { return }
        if exchange.body.count + data.count > limit {
            exchange.tooLarge = true
            dataTask.cancel()
            return
        }
        exchange.body.append(data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // never followed: the 3xx is the answer
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let exchange = exchange(task), let last = metrics.transactionMetrics.last(where: { $0.remoteAddress != nil }) else { return }
        exchange.address = last.remoteAddress
        exchange.proxy = last.isProxyConnection
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let exchange = exchange(task) else { return }
        if !exchange.tooLarge { exchange.error = error }
        exchange.done.signal()
    }
}
