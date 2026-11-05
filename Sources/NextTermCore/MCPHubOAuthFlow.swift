import CryptoKit
import Security
import Foundation

/// The authorization code flow, as a native app runs it (RFC 8252) with the MCP spec's rules:
///
/// - **PKCE** (RFC 7636): a 32-byte random verifier, base64url without padding (43 characters), and its S256 challenge.
/// - **state**: 32 random bytes, used once, kept with the verifier, the issuer, the resource, the scopes, the client and
///   the redirect in one `Pending`, in memory only: nothing is written before the tokens.
/// - **resource** (RFC 8707): on the authorization request, the token request and every refresh.
/// - **iss** (RFC 9207), checked against the issuer recorded before the browser opened: when the server says it sends
///   `iss`, it must be there and identical; when it doesn't say so and `iss` is there, it must be identical; when
///   neither, the answer is taken. No normalization. A mismatch never shows the answer's `error_description`.
public enum MCPHubOAuthFlow {
    /// PKCE's verifier and challenge.
    public struct PKCE: Equatable, Sendable {
        public let verifier: String
        public var challenge: String { MCPHubOAuthFlow.challenge(verifier) }
        public init(verifier: String) { self.verifier = verifier }
        public static func make() -> PKCE { PKCE(verifier: MCPHubOAuthFlow.random(32)) }
    }

    /// One sign-in between opening the browser and the callback.
    public struct Pending: Sendable {
        public let state: String
        public let pkce: PKCE
        public let metadata: MCPHubOAuthDiscovery.Metadata
        public let client: MCPHubOAuthRegistration.Client
        public let redirect: String
        public let scopes: [String]

        public init(state: String = MCPHubOAuthFlow.random(32), pkce: PKCE = .make(), metadata: MCPHubOAuthDiscovery.Metadata,
                    client: MCPHubOAuthRegistration.Client, redirect: String, scopes: [String]) {
            self.state = state
            self.pkce = pkce
            self.metadata = metadata
            self.client = client
            self.redirect = redirect
            self.scopes = scopes
        }

        /// The URL the browser opens: the authorization endpoint (any query it has kept) with the request's parameters.
        public var authorizationURL: URL? {
            guard var parts = URLComponents(string: metadata.authorizationEndpoint) else { return nil }
            var items = (parts.queryItems ?? []).filter { !Self.ours.contains($0.name) }
            items += [
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "client_id", value: client.clientID),
                URLQueryItem(name: "redirect_uri", value: redirect),
                URLQueryItem(name: "code_challenge", value: pkce.challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "resource", value: metadata.resource),
            ]
            if !scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " "))) }
            // `+` and the other sub-delimiters percent-encoded too, so no server reads a value two ways.
            parts.percentEncodedQuery = items.map { MCPHubOAuth.encode($0.name) + "=" + MCPHubOAuth.encode($0.value ?? "") }
                .joined(separator: "&")
            return parts.url
        }

        static let ours: Set<String> = ["response_type", "client_id", "redirect_uri", "code_challenge", "code_challenge_method",
                                        "state", "resource", "scope"]

        /// The token request for the code the callback brought.
        public func tokenRequest(code: String) -> MCPHubOAuth.Request? {
            guard let url = URL(string: metadata.tokenEndpoint) else { return nil }
            let form: [(String, String)] = [("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirect),
                                            ("code_verifier", pkce.verifier), ("resource", metadata.resource)]
            return client.authenticated(MCPHubOAuth.Request(post: url, form: form))
        }
    }

    /// What the browser came back with.
    public enum Callback: Equatable, Sendable {
        case code(String)
        /// The user said no at the server (`access_denied`).
        case denied
        /// Another error code the server gave; its description is never shown.
        case error(String)
        /// `iss` broke RFC 9207's rule: the answer came from another server.
        case wrongIssuer
        /// No code and no error, or `state` isn't this sign-in's: not this sign-in's answer.
        case notOurs
    }

    /// The callback's query read against `pending`.
    public static func callback(query: [(String, String)], pending: Pending) -> Callback {
        func value(_ name: String) -> String? { query.first { $0.0 == name }?.1 }
        guard let state = value("state"), constantTimeEqual(state, pending.state) else { return .notOurs }
        guard issAccepted(advertised: pending.metadata.issSupported, iss: value("iss"), expected: pending.metadata.issuer) else {
            return .wrongIssuer
        }
        if let error = value("error") { return error == "access_denied" ? .denied : .error(error) }
        guard let code = value("code"), !code.isEmpty else { return .notOurs }
        return .code(code)
    }

    /// RFC 9207's four cases, compared exactly.
    public static func issAccepted(advertised: Bool, iss: String?, expected: String) -> Bool {
        switch (advertised, iss) {
        case (true, let iss?): return iss == expected
        case (true, nil): return false
        case (false, let iss?): return iss == expected
        case (false, nil): return true
        }
    }

    // MARK: tokens

    /// A token answer, read.
    public struct Tokens: Equatable, Sendable {
        public var access: String
        public var refresh: String?
        /// Nil when the answer gave no `expires_in`: the token is used until the server refuses it.
        public var expires: Date?
        public var scopes: [String]?
        public var type: String

        public init(access: String, refresh: String?, expires: Date?, scopes: [String]?, type: String = "Bearer") {
            self.access = access
            self.refresh = refresh
            self.expires = expires
            self.scopes = scopes
            self.type = type
        }
    }

    /// What a token endpoint's error means for the sign-in.
    public enum TokenError: Error, Equatable, Sendable {
        /// `invalid_grant`: the code or refresh token is no good; a new sign-in is needed.
        case invalidGrant
        /// `invalid_client`: the client is gone (a registration expired); register again.
        case invalidClient
        /// Anything else, with the error code (never the description) or the HTTP status.
        case other(String)
    }

    /// The token endpoint's answer to a code or a refresh.
    public static func tokens(_ response: MCPHubOAuth.Response, now: Date = Date()) -> Result<Tokens, TokenError> {
        let json = response.json
        guard response.status == 200 else {
            switch json?["error"] as? String {
            case "invalid_grant"?: return .failure(.invalidGrant)
            case "invalid_client"?, "unauthorized_client"?: return .failure(.invalidClient)
            case let code?: return .failure(.other(code))
            case nil: return .failure(.other("HTTP \(response.status)"))
            }
        }
        guard let json, let access = json["access_token"] as? String, !access.isEmpty else { return .failure(.other("no access token")) }
        let type = json["token_type"] as? String ?? "Bearer"
        guard type.lowercased() == "bearer" else { return .failure(.other("a \(type) token, not a Bearer one")) }
        let seconds = (json["expires_in"] as? NSNumber)?.doubleValue ?? (json["expires_in"] as? String).flatMap(Double.init)
        let refresh = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let scopes = (json["scope"] as? String).map { MCPHubOAuthChallenge.words($0) }
        return .success(Tokens(access: access, refresh: refresh, expires: seconds.map { now.addingTimeInterval($0) }, scopes: scopes))
    }

    /// The refresh request: no `scope`, so the grant keeps the scopes it has.
    public static func refreshRequest(refresh: String, metadata: MCPHubOAuthDiscovery.Metadata,
                                      client: MCPHubOAuthRegistration.Client) -> MCPHubOAuth.Request? {
        guard let url = URL(string: metadata.tokenEndpoint) else { return nil }
        let form: [(String, String)] = [("grant_type", "refresh_token"), ("refresh_token", refresh), ("resource", metadata.resource)]
        return client.authenticated(MCPHubOAuth.Request(post: url, form: form))
    }

    /// RFC 7009's revocation request for `token`, or nil when the server has no revocation endpoint.
    public static func revocationRequest(token: String, hint: String, metadata: MCPHubOAuthDiscovery.Metadata,
                                         client: MCPHubOAuthRegistration.Client) -> MCPHubOAuth.Request? {
        guard let text = metadata.revocationEndpoint, let url = URL(string: text) else { return nil }
        return client.authenticated(MCPHubOAuth.Request(post: url, form: [("token", token), ("token_type_hint", hint)]))
    }

    // MARK: bytes

    /// `count` random bytes, base64url without padding.
    public static func random(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "no random bytes")
        defer { SecretBytes.wipe(&bytes) }
        return base64url(Data(bytes))
    }

    public static func challenge(_ verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for index in x.indices { difference |= x[index] ^ y[index] }
        return difference == 0
    }
}
