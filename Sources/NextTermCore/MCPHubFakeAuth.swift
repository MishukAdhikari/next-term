#if DEBUG
import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A fake OAuth authorization server on this Mac, the companion of MCPHubFakeRemote, for the unit tests and the
/// self-test (debug builds only): 127.0.0.1 at a port of its own, one request a connection. It serves the remote's
/// protected resource metadata, its own metadata, registration, an authorization endpoint with no UI (a 302 straight
/// back to the redirect, as if the user approved), tokens and revocation. What it does is set on it:
///
/// - **Metadata**: `cimd`, `dcr`, `iss` (`.on`, `.off`, `.wrong`, `.missing`: advertised and not sent), `s256`, and
///   `pathIssuer` (its issuer has a path, as GitHub's does).
/// - **Authorization**: `deny` answers `error=access_denied`.
/// - **Tokens**: `rotation` (`.strict`: each refresh gives a new refresh token and the old one ends at once; `.grace`:
///   the old one works until the new one is first used; `.none`: no new one), `accessLife`, `reuseKillsGrant` (a spent
///   refresh token sent again ends the whole grant), `registrationLife` (a client is forgotten after it), and
///   `loseNextRefresh` (the next refresh is taken and its answer never sent, as a dropped connection).
/// - `revokeAll()` ends every grant at the server, as the user revoking access there.
///
/// `counts` keeps how many requests each path got, for the tests.
public final class MCPHubFakeAuth: @unchecked Sendable {
    public enum Rotation: Sendable { case strict, grace, none }
    public enum Iss: Sendable { case on, off, wrong, missing }

    public var cimd = true
    public var dcr = true
    public var iss: Iss = .on
    public var s256 = true
    public var pathIssuer = false
    public var deny = false
    public var rotation: Rotation = .strict
    public var accessLife: TimeInterval = 3600
    public var reuseKillsGrant = true
    public var registrationLife: TimeInterval?
    public var loseNextRefresh = false
    public var scopes = ["read", "write"]
    /// The resource its tokens are for: the fake remote's URL.
    public var resource = ""

    private let lock = NSLock()
    private var listener: Int32 = -1
    public private(set) var port: UInt16 = 0
    private var countsByPath: [String: Int] = [:]
    private var clients: [String: Date] = [:]
    private var codes: [String: (client: String, challenge: String, redirect: String, resource: String, scope: String)] = [:]
    private struct Access { let grant: String; let resource: String; let expires: Date; let scope: String }
    private var access: [String: Access] = [:]
    /// Each refresh token: its grant, and whether it still works.
    private var refreshes: [String: (grant: String, live: Bool, spent: Bool, previous: String?)] = [:]
    private var deadGrants = Set<String>()
    public private(set) var lastAuthorize: [(String, String)] = []
    public private(set) var lastToken: [(String, String)] = []

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
        guard bound == 0, listen(listener, 32) == 0 else { close(listener); throw POSIXError(.EADDRINUSE) }
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
                guard let self else { close(client); return }
                Thread { self.serve(client) }.start()
            }
        }.start()
    }

    deinit { stop() }

    public func stop() {
        lock.lock()
        let fd = listener
        listener = -1
        lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
    }

    public var origin: String { "http://127.0.0.1:\(port)" }
    public var issuer: String { pathIssuer ? origin + "/login/oauth" : origin }
    /// The resource metadata URL a 401 names.
    public var resourceMetadata: String { origin + "/.well-known/oauth-protected-resource/mcp" }

    public func count(_ path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return countsByPath[path] ?? 0
    }

    public var counts: [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return countsByPath
    }

    /// Every grant ends: its access and refresh tokens no longer work.
    public func revokeAll() {
        lock.lock()
        for value in access.values { deadGrants.insert(value.grant) }
        for value in refreshes.values { deadGrants.insert(value.grant) }
        lock.unlock()
    }

    /// Every registered client is forgotten, as a registration's life running out.
    public func expireRegistrations() {
        lock.lock()
        for id in clients.keys { clients[id] = .distantPast }
        lock.unlock()
    }

    /// Whether `token` is a live access token for `resource`, and its scopes.
    public func validate(_ token: String, resource: String) -> (valid: Bool, scope: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let found = access[token], !deadGrants.contains(found.grant), found.expires > Date(), found.resource == resource else {
            return (false, "")
        }
        return (true, found.scope)
    }

    /// What a browser does with the authorization URL: GETs it, and returns the redirect's URL (with code, state and
    /// iss) without following it.
    public static func approve(_ url: URL) -> URL? {
        let done = DispatchSemaphore(value: 0)
        final class Stop: NSObject, URLSessionTaskDelegate {
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
        }
        // Its own serial queue under the delegate, as Next Term's sessions have (MCPHubRemote.delegateQueue): the default
        // concurrent one waits for a free CPU, and a busy test run (CI) held the browser past the sign-in's wait.
        let session = URLSession(configuration: .ephemeral, delegate: Stop(), delegateQueue: MCPHubRemote.delegateQueue("fake-browser"))
        var location: URL?
        session.dataTask(with: url) { _, response, _ in
            if let http = response as? HTTPURLResponse, let text = http.value(forHTTPHeaderField: "Location") { location = URL(string: text) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 10)
        session.invalidateAndCancel()
        return location
    }

    /// `signIn` on a thread of its own, as a browser runs apart from Next Term: never a global queue, which a busy
    /// process (a parallel test run) can leave waiting for a free CPU past the sign-in's wait.
    public static func signInSoon(_ url: URL) {
        Thread { _ = signIn(url) }.start()
    }

    /// `approve`, then the redirect opened as the browser would: GET to the loopback listener. The page's text.
    public static func signIn(_ url: URL) -> String? {
        guard let back = approve(url) else { return nil }
        let done = DispatchSemaphore(value: 0)
        var page: String?
        URLSession(configuration: .ephemeral, delegate: nil, delegateQueue: MCPHubRemote.delegateQueue("fake-browser")).dataTask(with: back) { data, _, _ in
            page = data.map { String(decoding: $0, as: UTF8.self) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 10)
        return page
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
        let words = head.first?.split(separator: " ") ?? []
        let verb = words.first.map(String.init) ?? ""
        let target = words.count > 1 ? String(words[1]) : "/"
        let parts = URLComponents(string: target)
        let path = parts?.path ?? target
        lock.lock()
        countsByPath[path, default: 0] += 1
        lock.unlock()
        let form = MCPHubOAuth.decodeForm(String(decoding: body, as: UTF8.self))
        func value(_ name: String) -> String? { form.first { $0.0 == name }?.1 }

        switch (verb, path) {
        case ("GET", "/.well-known/oauth-protected-resource/mcp"), ("GET", "/.well-known/oauth-protected-resource"):
            return json(fd, 200, ["resource": resource, "authorization_servers": [issuer], "scopes_supported": scopes])
        case ("GET", "/.well-known/oauth-authorization-server"), ("GET", "/.well-known/oauth-authorization-server/login/oauth"):
            guard (path == "/.well-known/oauth-authorization-server") != pathIssuer else { return json(fd, 404, [:]) }
            var metadata: [String: Any] = [
                "issuer": issuer, "authorization_endpoint": origin + "/authorize", "token_endpoint": origin + "/token",
                "revocation_endpoint": origin + "/revoke", "response_types_supported": ["code"],
                "grant_types_supported": ["authorization_code", "refresh_token"], "token_endpoint_auth_methods_supported": ["none"],
                "scopes_supported": scopes,
            ]
            if s256 { metadata["code_challenge_methods_supported"] = ["S256"] }
            if iss != .off { metadata["authorization_response_iss_parameter_supported"] = true }
            if cimd { metadata["client_id_metadata_document_supported"] = true }
            if dcr { metadata["registration_endpoint"] = origin + "/register" }
            return json(fd, 200, metadata)
        case ("POST", "/register"):
            guard dcr else { return json(fd, 404, [:]) }
            let id = "client-" + UUID().uuidString.prefix(8).lowercased()
            lock.lock()
            clients[id] = registrationLife.map { Date().addingTimeInterval($0) } ?? .distantFuture
            lock.unlock()
            return json(fd, 201, ["client_id": id, "token_endpoint_auth_method": "none", "client_id_issued_at": Int(Date().timeIntervalSince1970)])
        case ("GET", "/authorize"):
            let query = MCPHubOAuth.decodeForm(parts?.percentEncodedQuery ?? "")
            lock.lock()
            lastAuthorize = query
            lock.unlock()
            func q(_ name: String) -> String { query.first { $0.0 == name }?.1 ?? "" }
            var back = URLComponents(string: q("redirect_uri"))
            var items = [URLQueryItem(name: "state", value: q("state"))]
            switch iss {
            case .on, .off: if iss == .on { items.append(URLQueryItem(name: "iss", value: issuer)) }
            case .wrong: items.append(URLQueryItem(name: "iss", value: "https://evil.example"))
            case .missing: break
            }
            if deny {
                items.append(URLQueryItem(name: "error", value: "access_denied"))
                items.append(URLQueryItem(name: "error_description", value: "<script>alert(1)</script>"))
            } else {
                let code = "code-" + UUID().uuidString.lowercased()
                lock.lock()
                codes[code] = (q("client_id"), q("code_challenge"), q("redirect_uri"), q("resource"), q("scope"))
                lock.unlock()
                items.append(URLQueryItem(name: "code", value: code))
            }
            back?.queryItems = items
            return send(fd, status: "302 Found", headers: ["Location": back?.string ?? ""], body: "")
        case ("POST", "/token"):
            lock.lock()
            lastToken = form
            lock.unlock()
            let client = value("client_id") ?? ""
            lock.lock()
            let known = clients[client]
            lock.unlock()
            if let known, known <= Date() { return json(fd, 401, ["error": "invalid_client"]) }
            if known == nil, !client.hasPrefix("https://") { return json(fd, 401, ["error": "invalid_client"]) }
            switch value("grant_type") {
            case "authorization_code":
                lock.lock()
                let found = codes.removeValue(forKey: value("code") ?? "")
                lock.unlock()
                guard let found, found.client == client, found.redirect == value("redirect_uri"),
                      found.resource == value("resource"), found.resource == resource,
                      MCPHubOAuthFlow.challenge(value("code_verifier") ?? "") == found.challenge else {
                    return json(fd, 400, ["error": "invalid_grant"])
                }
                return json(fd, 200, issue(grant: UUID().uuidString, scope: found.scope, refresh: true))
            case "refresh_token":
                let token = value("refresh_token") ?? ""
                lock.lock()
                let lose = loseNextRefresh
                loseNextRefresh = false
                guard let found = refreshes[token], !deadGrants.contains(found.grant), value("resource") == resource else {
                    lock.unlock()
                    return json(fd, 400, ["error": "invalid_grant"])
                }
                if !found.live {
                    if reuseKillsGrant { deadGrants.insert(found.grant) }
                    lock.unlock()
                    return json(fd, 400, ["error": "invalid_grant"])
                }
                // The new token's first use ends the one it replaced (grace).
                if let previous = found.previous { refreshes[previous]?.live = false }
                switch rotation {
                case .strict: refreshes[token]?.live = false
                case .grace, .none: break
                }
                lock.unlock()
                let answer = issue(grant: found.grant, scope: scopes.joined(separator: " "), refresh: rotation != .none, previous: rotation == .grace ? token : nil)
                if lose { return } // taken, and the answer never sent
                return json(fd, 200, answer)
            default:
                return json(fd, 400, ["error": "unsupported_grant_type"])
            }
        case ("POST", "/revoke"):
            let token = value("token") ?? ""
            lock.lock()
            if let grant = refreshes[token]?.grant ?? access[token]?.grant { deadGrants.insert(grant) }
            lock.unlock()
            return send(fd, status: "200 OK", headers: [:], body: "")
        default:
            return json(fd, 404, ["error": "not_found"])
        }
    }

    private func issue(grant: String, scope: String, refresh: Bool, previous: String? = nil) -> [String: Any] {
        let token = "at-" + UUID().uuidString.lowercased()
        lock.lock()
        defer { lock.unlock() }
        access[token] = Access(grant: grant, resource: resource, expires: Date().addingTimeInterval(accessLife), scope: scope)
        var answer: [String: Any] = ["access_token": token, "token_type": "Bearer", "expires_in": accessLife, "scope": scope]
        if refresh {
            let next = "rt-" + UUID().uuidString.lowercased()
            refreshes[next] = (grant, true, false, previous)
            answer["refresh_token"] = next
        }
        return answer
    }

    private func json(_ fd: Int32, _ status: Int, _ object: [String: Any]) {
        let text = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let reason = [200: "OK", 201: "Created", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found"][status] ?? "Status"
        send(fd, status: "\(status) \(reason)", headers: ["Content-Type": "application/json"], body: text)
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
