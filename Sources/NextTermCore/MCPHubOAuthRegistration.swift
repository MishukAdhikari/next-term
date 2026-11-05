import Foundation

/// The OAuth client Next Term signs in as, found in the MCP spec's order:
///
/// 1. **Pre-registered**: the user's own OAuth app for the server (a client ID, and a secret from Secrets for a server
///    that demands one). Bound to the issuer it was first used with: when the server's authorization server changes,
///    it isn't sent there, and the user is told.
/// 2. **A client metadata document** (CIMD): Next Term's client ID is an https URL it controls. Off until Next Term
///    publishes one (`metadataDocument` nil).
/// 3. **Dynamic registration** (RFC 7591), when the server has a registration endpoint: a native client named "Next
///    Term", with the loopback redirect `http://127.0.0.1/callback` (any port, RFC 8252 §7.3), public (no secret), kept
///    per issuer. A registration the server forgot (`invalid_client`; some expire after 90 days) is made again once.
///    A server that won't take a redirect without its port gets the sign-in's exact one.
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

        public init(issuer: String, clientID: String, kind: Kind, authMethod: String = "none", secret: String? = nil,
                    secretExpires: Date? = nil) {
            self.issuer = issuer
            self.clientID = clientID
            self.kind = kind
            self.authMethod = authMethod
            self.secret = secret
            self.secretExpires = secretExpires
        }

        enum CodingKeys: String, CodingKey { case issuer, clientID, kind, authMethod, secretExpires }

        /// `request` with the client named as its auth method says: `client_id` in the form, and the secret in it
        /// (`client_secret_post`) or as Basic (`client_secret_basic`, RFC 6749 §2.3.1's form-encoding first).
        public func authenticated(_ request: MCPHubOAuth.Request) -> MCPHubOAuth.Request {
            var out = request
            var form = out.form ?? []
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
    }

    /// The user's own OAuth app, from the server's entry: its client ID, the secret's value when it names one, and the
    /// issuer it was first used with.
    public struct Own: Equatable, Sendable {
        public var clientID: String
        public var secret: String?
        public var issuer: String?
        public init(clientID: String, secret: String? = nil, issuer: String? = nil) {
            self.clientID = clientID
            self.secret = secret
            self.issuer = issuer
        }
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
            if let bound = own.issuer, bound != metadata.issuer {
                return .none("\(name) now signs in at \(metadata.issuerHost), and the OAuth app you gave is for \(URL(string: bound)?.host ?? bound). "
                    + "Give \(name) an OAuth app made at \(metadata.issuerHost), or remove yours to let Next Term register itself.")
            }
            let method = own.secret == nil ? "none"
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
    public static func body(redirect: String = MCPHubOAuthRegistration.redirect) -> Data {
        let escaped = redirect.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "/", with: "\\/")
        return Data(("{\"client_name\":\"Next Term\",\"application_type\":\"native\",\"redirect_uris\":[\"\(escaped)\"],"
            + "\"grant_types\":[\"authorization_code\",\"refresh_token\"],\"response_types\":[\"code\"],"
            + "\"token_endpoint_auth_method\":\"none\"}").utf8)
    }

    /// Registers Next Term at `endpoint` for `issuer`; `exact`, the sign-in's own redirect with its port, is tried when
    /// the server refuses the portless one.
    public static func register(at endpoint: URL, issuer: String, name: String, exact: String?, fetch: MCPHubOAuth.Fetch,
                                now: Date = Date()) -> Result<Client, MCPHubOAuth.Failure> {
        var tries = [redirect]
        if let exact, exact != redirect { tries.append(exact) }
        var last = "it answered with no client"
        for uri in tries {
            switch fetch(MCPHubOAuth.Request(post: endpoint, json: body(redirect: uri))) {
            case .failure(let failure):
                return .failure(MCPHubOAuth.Failure("Next Term couldn\u{2019}t register with \(name): \(failure.text)"))
            case .success(let response):
                let json = response.json ?? [:]
                guard response.status == 200 || response.status == 201 else {
                    let code = json["error"] as? String
                    last = code.map { "it answered \($0)" } ?? "it answered HTTP \(response.status)"
                    if code == "invalid_redirect_uri" { continue }
                    return .failure(MCPHubOAuth.Failure("\(name) didn\u{2019}t register Next Term: \(last)."))
                }
                guard let id = json["client_id"] as? String, !id.isEmpty else {
                    return .failure(MCPHubOAuth.Failure("\(name) didn\u{2019}t register Next Term: \(last)."))
                }
                let secret = (json["client_secret"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let ends = (json["client_secret_expires_at"] as? NSNumber)?.doubleValue ?? 0
                var method = json["token_endpoint_auth_method"] as? String ?? (secret == nil ? "none" : "client_secret_basic")
                if secret == nil { method = "none" }
                return .success(Client(issuer: issuer, clientID: id, kind: .registered, authMethod: method, secret: secret,
                                       secretExpires: ends > 0 ? Date(timeIntervalSince1970: ends) : nil))
            }
        }
        return .failure(MCPHubOAuth.Failure("\(name) didn\u{2019}t take Next Term\u{2019}s sign-in address: \(last)."))
    }
}
