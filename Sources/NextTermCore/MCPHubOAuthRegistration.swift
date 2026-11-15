import Foundation

/// The OAuth client Next Term signs in as, found in the MCP spec's order:
///
/// 1. **Pre-registered**: the user's own OAuth app for the server (a client ID, and a secret from Secrets for a server
///    that demands one). Bound to the issuer it was first used with: when the server's authorization server changes,
///    it isn't sent there, and the user is told.
/// 2. **A client metadata document** (CIMD): Next Term's client ID is an https URL it controls. Off until Next Term
///    publishes one (`metadataDocument` nil).
/// 3. **Dynamic registration** (RFC 7591), when the server has a registration endpoint: a native client named "Next
///    Term", public (no secret), kept per issuer, with two loopback redirects: `http://127.0.0.1/callback` (any port,
///    RFC 8252 §7.3) and the sign-in's own `http://127.0.0.1:<port>/callback`. Not every server lets the port vary at
///    its authorization endpoint, so the port is kept with the client and later sign-ins listen on it again; when it's
///    taken, Next Term registers again. A server that won't take two redirects gets the exact one alone, then the
///    portless one. A registration the server forgot (`invalid_client`; some expire after 90 days) is made again once.
/// 4. **None of them**: a sentence offering the user's own OAuth app or a key in a header.
public enum MCPHubOAuthRegistration {
    /// The redirect registered: loopback, by address, any port.
    public static let redirect = "http://127.0.0.1/callback"

    public struct Client: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case preRegistered, registered, metadataDocument
        }

        public var issuer: String
        public var clientID: String
        public var kind: Kind
        /// `none`, `client_secret_post` or `client_secret_basic`.
        public var authMethod: String
        /// Never encoded: SignInFile seals it apart, and pre-registered ones live in Secrets.
        public var secret: String?
        /// When a registered client's secret ends (RFC 7591's `client_secret_expires_at`); nil for never.
        public var secretExpires: Date?
        /// A registered client's loopback port, the one its exact redirect names, which its sign-ins listen on: 0 when
        /// the server took only the portless redirect (any port), nil for a registration kept before ports were (it is
        /// made again at its next sign-in, since its server may hold it to a port long gone).
        public var port: UInt16?

        public init(issuer: String, clientID: String, kind: Kind, authMethod: String = "none", secret: String? = nil,
                    secretExpires: Date? = nil, port: UInt16? = nil) {
            self.issuer = issuer
            self.clientID = clientID
            self.kind = kind
            self.authMethod = authMethod
            self.secret = secret
            self.secretExpires = secretExpires
            self.port = port
        }

        enum CodingKeys: String, CodingKey { case issuer, clientID, kind, authMethod, secretExpires, port }

        /// Whether a sign-in listening on `listening` can use this client as it is: anything but a registered one whose
        /// port is unknown, or is another.
        public func fits(listening: UInt16) -> Bool {
            guard kind == .registered else { return true }
            guard let port else { return false }
            return port == 0 || port == listening
        }

        /// `request` with the client named as its auth method says: `client_id` in the form, and the secret in it
        /// (`client_secret_post`) or as Basic (`client_secret_basic`, RFC 6749 §2.3.1's form-encoding first).
        ///
        /// The user's own app's secret goes only to its issuer's own origin (scheme, host and port), where its token
        /// endpoint is: a server whose metadata names a token or revocation endpoint elsewhere gets the client ID alone.
        public func authenticated(_ request: MCPHubOAuth.Request) -> MCPHubOAuth.Request {
            var out = request
            var form = out.form ?? []
            let secret = kind == .preRegistered && !Self.sameOrigin(request.url, issuer) ? nil : secret
            if authMethod == "client_secret_basic", let secret {
                let pair = MCPHubOAuth.encode(clientID) + ":" + MCPHubOAuth.encode(secret)
                out.headers["Authorization"] = "Basic " + Data(pair.utf8).base64EncodedString()
            } else {
                form.append(("client_id", clientID))
                if authMethod == "client_secret_post", let secret { form.append(("client_secret", secret)) }
            }
            out.form = form
            return out
        }

        public func hasExpired(now: Date = Date()) -> Bool { secretExpires.map { $0 <= now } ?? false }

        /// Whether `url` is at `issuer`'s origin: the same scheme, host and port, compared lowercased.
        public static func sameOrigin(_ url: URL, _ issuer: String) -> Bool {
            guard let other = URL(string: issuer), let a = url.scheme?.lowercased(), let b = other.scheme?.lowercased(), a == b,
                  let host = url.host?.lowercased(), host == other.host?.lowercased() else { return false }
            let defaultPort = a == "https" ? 443 : 80
            return (url.port ?? defaultPort) == (other.port ?? defaultPort)
        }
    }

    /// The user's own OAuth app, from the server's entry: its client ID, the secret's value or the name of the key in
    /// Secrets that holds it (read at token time only, MCPHubSignIn's `readSecret`), and the issuer it was first used
    /// with.
    public struct Own: Equatable, Sendable {
        public var clientID: String
        public var secret: String?
        public var secretName: String?
        public var issuer: String?
        public init(clientID: String, secret: String? = nil, secretName: String? = nil, issuer: String? = nil) {
            self.clientID = clientID
            self.secret = secret
            self.secretName = secretName
            self.issuer = issuer
        }

        public var hasSecret: Bool { secret != nil || secretName != nil }
    }

    public enum Choice: Equatable, Sendable {
        case use(Client)
        case register(URL)
        /// No way to sign in as Next Term: the sentence for the user.
        case none(String)
    }

    /// Which client a sign-in uses, before any request.
    public static func choose(name: String, metadata: MCPHubOAuthDiscovery.Metadata, own: Own?, registered: [Client],
                              metadataDocument: String? = nil, now: Date = Date()) -> Choice {
        if let own {
            // Bound by the entry's issuer, or else by where this client ID was signed in with before (kept sealed).
            let bound = own.issuer ?? registered.first { $0.kind == .preRegistered && $0.clientID == own.clientID }?.issuer
            if let bound, bound != metadata.issuer {
                return .none("\(name) now signs in at \(metadata.issuerHost), and the OAuth app you gave is for \(URL(string: bound)?.host ?? bound). "
                    + "Give \(name) an OAuth app made at \(metadata.issuerHost), or remove yours to let Next Term register itself.")
            }
            if own.hasSecret, URL(string: metadata.tokenEndpoint).map({ Client.sameOrigin($0, metadata.issuer) }) != true {
                return .none("\(name)\u{2019}s token address isn\u{2019}t at \(metadata.issuerHost), so Next Term doesn\u{2019}t send your OAuth app\u{2019}s secret there.")
            }
            let method = !own.hasSecret ? "none"
                : metadata.tokenAuthMethods.contains("client_secret_post") || metadata.tokenAuthMethods.isEmpty ? "client_secret_post"
                : "client_secret_basic"
            return .use(Client(issuer: metadata.issuer, clientID: own.clientID, kind: .preRegistered, authMethod: method, secret: own.secret))
        }
        if let known = registered.first(where: { $0.kind == .registered && $0.issuer == metadata.issuer && !$0.hasExpired(now: now) }) { return .use(known) }
        if let metadataDocument, metadata.cimdSupported {
            return .use(Client(issuer: metadata.issuer, clientID: metadataDocument, kind: .metadataDocument))
        }
        if let text = metadata.registrationEndpoint, let url = URL(string: text) { return .register(url) }
        return .none("\(name) doesn\u{2019}t let apps register themselves. Sign in with your own OAuth app, or give \(name) a key "
            + "(a personal access token) instead.")
    }

    /// The registration's body, exactly: members in this order.
    public static func body(redirects: [String] = [MCPHubOAuthRegistration.redirect]) -> Data {
        let escaped = redirects.map {
            "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "/", with: "\\/") + "\""
        }.joined(separator: ",")
        return Data(("{\"client_name\":\"Next Term\",\"application_type\":\"native\",\"redirect_uris\":[\(escaped)],"
            + "\"grant_types\":[\"authorization_code\",\"refresh_token\"],\"response_types\":[\"code\"],"
            + "\"token_endpoint_auth_method\":\"none\"}").utf8)
    }

    /// Registers Next Term at `endpoint` for `issuer`, for a sign-in listening at `exact` (its redirect with the port):
    /// both redirects first, then the exact one alone, then the portless one, for a server that refuses a list or a port.
    public static func register(at endpoint: URL, issuer: String, name: String, exact: String?, fetch: MCPHubOAuth.Fetch,
                                now: Date = Date()) -> Result<Client, MCPHubOAuth.Failure> {
        var tries: [[String]] = [[redirect]]
        if let exact, exact != redirect { tries = [[redirect, exact], [exact], [redirect]] }
        let exactPort = exact.flatMap { URL(string: $0)?.port }.map { UInt16(clamping: $0) }
        var last = "it answered with no client"
        for uris in tries {
            switch fetch(MCPHubOAuth.Request(post: endpoint, json: body(redirects: uris))) {
            case .failure(let failure):
                return .failure(MCPHubOAuth.Failure("Next Term couldn\u{2019}t register with \(name): \(failure.text)"))
            case .success(let response):
                let json = response.json ?? [:]
                guard response.status == 200 || response.status == 201 else {
                    let code = json["error"] as? String
                    last = code.map { "it answered \($0)" } ?? "it answered HTTP \(response.status)"
                    // A redirect refused, or a list of two read as bad metadata: the next try.
                    if code == "invalid_redirect_uri" || (code == "invalid_client_metadata" && uris.count > 1) { continue }
                    return .failure(MCPHubOAuth.Failure("\(name) didn\u{2019}t register Next Term: \(last)."))
                }
                guard let id = json["client_id"] as? String, !id.isEmpty else {
                    return .failure(MCPHubOAuth.Failure("\(name) didn\u{2019}t register Next Term: \(last)."))
                }
                let secret = (json["client_secret"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let ends = (json["client_secret_expires_at"] as? NSNumber)?.doubleValue ?? 0
                var method = json["token_endpoint_auth_method"] as? String ?? (secret == nil ? "none" : "client_secret_basic")
                if secret == nil { method = "none" }
                // The port its sign-ins listen on: the exact redirect's, when it was registered; any, when only the
                // portless one was.
                let port: UInt16? = uris.contains { $0 != redirect } ? exactPort : 0
                return .success(Client(issuer: issuer, clientID: id, kind: .registered, authMethod: method, secret: secret,
                                       secretExpires: ends > 0 ? Date(timeIntervalSince1970: ends) : nil, port: port))
            }
        }
        return .failure(MCPHubOAuth.Failure("\(name) didn\u{2019}t take Next Term\u{2019}s sign-in address: \(last)."))
    }
}
