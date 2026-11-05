import Foundation

/// Where a remote MCP server signs in, found as the MCP spec's authorization server discovery says, every URL held to
/// MCPHubOAuthURL's rules and fetched with no redirect followed:
///
/// 1. **Its protected resource metadata** (RFC 9728): the `resource_metadata` URL of its 401's Bearer challenge when it
///    has one, else the well-known URL with the server's path inserted (`/.well-known/oauth-protected-resource/mcp`),
///    then the root one. The document's `resource` must be identical to the server's URL (or, from the root, to its
///    origin), or the document isn't used: RFC 9728 §3.3.
/// 2. **Its authorization server's metadata**, for each server the document lists in order: for an issuer with a path,
///    `/.well-known/oauth-authorization-server/<path>`, `/.well-known/openid-configuration/<path>`, then
///    `<issuer>/.well-known/openid-configuration`; without one, the first two at the root. The document's `issuer`
///    must be identical to the issuer the URL was made from, or it isn't used.
/// 3. **PKCE with S256** must be listed in `code_challenge_methods_supported`, or the sign-in is refused.
///
/// The first authorization server that passes is the one used.
public enum MCPHubOAuthDiscovery {
    /// What a sign-in needs to know of the server and its authorization server: found once, kept with the sign-in.
    public struct Metadata: Codable, Equatable, Sendable {
        /// The PRM's `resource`, sent as RFC 8707's resource on every request.
        public var resource: String
        public var issuer: String
        public var authorizationEndpoint: String
        public var tokenEndpoint: String
        public var registrationEndpoint: String?
        public var revocationEndpoint: String?
        /// The PRM's `scopes_supported`.
        public var resourceScopes: [String]
        /// The authorization server's `scopes_supported`.
        public var serverScopes: [String]
        /// RFC 9207's `authorization_response_iss_parameter_supported`.
        public var issSupported: Bool
        public var cimdSupported: Bool
        public var tokenAuthMethods: [String]

        public init(resource: String, issuer: String, authorizationEndpoint: String, tokenEndpoint: String,
                    registrationEndpoint: String? = nil, revocationEndpoint: String? = nil, resourceScopes: [String] = [],
                    serverScopes: [String] = [], issSupported: Bool = false, cimdSupported: Bool = false,
                    tokenAuthMethods: [String] = []) {
            self.resource = resource
            self.issuer = issuer
            self.authorizationEndpoint = authorizationEndpoint
            self.tokenEndpoint = tokenEndpoint
            self.registrationEndpoint = registrationEndpoint
            self.revocationEndpoint = revocationEndpoint
            self.resourceScopes = resourceScopes
            self.serverScopes = serverScopes
            self.issSupported = issSupported
            self.cimdSupported = cimdSupported
            self.tokenAuthMethods = tokenAuthMethods
        }

        /// The issuer's host, as Settings names where a server signs in ("Signs in at github.com").
        public var issuerHost: String { URL(string: issuer)?.host ?? issuer }

        /// The scopes to ask for (the spec's scope selection): the challenge's, else every one the PRM lists, else none;
        /// with `offline_access` added when the authorization server lists it, so a refresh token may come.
        public func scopes(challenge: MCPHubOAuthChallenge?) -> [String] {
            var wanted = challenge?.scopes ?? []
            if wanted.isEmpty { wanted = resourceScopes }
            if serverScopes.contains("offline_access"), !wanted.contains("offline_access") { wanted.append("offline_access") }
            return wanted
        }
    }

    /// The server's metadata, or why it can't be signed in to, as a sentence naming `name`.
    public static func discover(server: URL, name: String, challenge: MCPHubOAuthChallenge?,
                                fetch: MCPHubOAuth.Fetch) -> Result<Metadata, MCPHubOAuth.Failure> {
        // 1. The resource metadata.
        var reasons: [String] = []
        var found: (document: [String: Any], resource: String)?
        for candidate in resourceCandidates(server: server, challenge: challenge) {
            guard case .success(let url) = MCPHubOAuthURL.checked(candidate.url, server: server) else {
                reasons.append("its resource metadata URL isn\u{2019}t one Next Term uses")
                continue
            }
            switch document(url, fetch: fetch) {
            case .failure(let why): reasons.append(why.text)
            case .success(let document):
                guard let resource = document["resource"] as? String else { reasons.append("its resource metadata names no resource"); continue }
                guard candidate.allowed.contains(resource) else {
                    // RFC 9728 §3.3: a document for another resource is not used.
                    reasons.append("its resource metadata is for another server (\(resource))")
                    continue
                }
                found = (document, resource)
            }
            if found != nil { break }
        }
        guard let found else {
            return .failure(MCPHubOAuth.Failure("\(name) asks for a sign-in, and Next Term couldn\u{2019}t find where: "
                + (reasons.first ?? "it has no resource metadata") + "."))
        }
        let servers = (found.document["authorization_servers"] as? [String]) ?? []
        guard !servers.isEmpty else {
            return .failure(MCPHubOAuth.Failure("\(name) asks for a sign-in, and its resource metadata names no authorization server."))
        }
        let resourceScopes = (found.document["scopes_supported"] as? [String]) ?? []

        // 2. Each authorization server, in order: the first whose metadata passes.
        var refusal: String?
        for issuer in servers {
            guard case .success(let issuerURL) = MCPHubOAuthURL.checked(issuer, server: server) else {
                refusal = refusal ?? "its authorization server (\(issuer)) isn\u{2019}t one Next Term signs in through"
                continue
            }
            var metadata: [String: Any]?
            for url in serverCandidates(issuer: issuerURL) {
                guard case .success(let document) = document(url, fetch: fetch) else { continue }
                // The issuer must be identical, with no normalization, or the document isn't used.
                guard document["issuer"] as? String == issuer else {
                    refusal = refusal ?? "its authorization server\u{2019}s metadata names another issuer"
                    continue
                }
                metadata = document
                break
            }
            guard let metadata else {
                refusal = refusal ?? "its authorization server (\(issuerURL.host ?? issuer)) has no metadata"
                continue
            }
            // 3. PKCE with S256, or no sign-in.
            guard let methods = metadata["code_challenge_methods_supported"] as? [String], methods.contains("S256") else {
                refusal = "its authorization server doesn\u{2019}t say it supports PKCE (S256), which Next Term requires"
                continue
            }
            func endpoint(_ key: String) -> String? {
                guard let text = metadata[key] as? String, case .success = MCPHubOAuthURL.checked(text, server: server) else { return nil }
                return text
            }
            guard let authorization = endpoint("authorization_endpoint"), let token = endpoint("token_endpoint") else {
                refusal = "its authorization server\u{2019}s sign-in or token address isn\u{2019}t one Next Term uses"
                continue
            }
            return .success(Metadata(
                resource: found.resource, issuer: issuer, authorizationEndpoint: authorization, tokenEndpoint: token,
                registrationEndpoint: endpoint("registration_endpoint"), revocationEndpoint: endpoint("revocation_endpoint"),
                resourceScopes: resourceScopes, serverScopes: (metadata["scopes_supported"] as? [String]) ?? [],
                issSupported: metadata["authorization_response_iss_parameter_supported"] as? Bool ?? false,
                cimdSupported: metadata["client_id_metadata_document_supported"] as? Bool ?? false,
                tokenAuthMethods: (metadata["token_endpoint_auth_methods_supported"] as? [String]) ?? []))
        }
        return .failure(MCPHubOAuth.Failure("\(name) can\u{2019}t be signed in to: " + (refusal ?? "no authorization server answered") + "."))
    }

    /// Where the resource metadata is looked for, in order, each with the `resource` values its document may name.
    static func resourceCandidates(server: URL, challenge: MCPHubOAuthChallenge?) -> [(url: String, allowed: Set<String>)] {
        let written = server.absoluteString
        let canonical = MCPHubOAuthURL.canonical(server)
        let origin = MCPHubOAuthURL.origin(server)
        var out: [(String, Set<String>)] = []
        if let named = challenge?.resourceMetadata { out.append((named, [written, canonical])) }
        // The path as written, its trailing slash kept: /mcp and /mcp/ are two resources.
        let path = URLComponents(url: server, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? server.path
        if !path.isEmpty, path != "/" {
            out.append((origin + "/.well-known/oauth-protected-resource" + path, [written, canonical]))
        }
        out.append((origin + "/.well-known/oauth-protected-resource", [written, canonical, origin, origin + "/"]))
        return out
    }

    /// Where an authorization server's metadata is looked for, in the spec's order.
    static func serverCandidates(issuer: URL) -> [URL] {
        let origin = MCPHubOAuthURL.origin(issuer)
        var path = issuer.path
        if path.hasSuffix("/") { path.removeLast() }
        let texts: [String]
        if path.isEmpty {
            texts = [origin + "/.well-known/oauth-authorization-server", origin + "/.well-known/openid-configuration"]
        } else {
            texts = [origin + "/.well-known/oauth-authorization-server" + path, origin + "/.well-known/openid-configuration" + path,
                     origin + path + "/.well-known/openid-configuration"]
        }
        return texts.compactMap(URL.init(string:))
    }

    /// A JSON document at `url`, or why not.
    static func document(_ url: URL, fetch: MCPHubOAuth.Fetch) -> Result<[String: Any], MCPHubOAuth.Failure> {
        switch fetch(MCPHubOAuth.Request(get: url)) {
        case .failure(let failure): return .failure(MCPHubOAuth.Failure(failure.text))
        case .success(let response):
            if (300..<400).contains(response.status) { return .failure(MCPHubOAuth.Failure("\(url.host ?? "it") redirected Next Term, which follows no redirect for a sign-in")) }
            guard response.status == 200 else { return .failure(MCPHubOAuth.Failure("\(url.host ?? "it") answered HTTP \(response.status)")) }
            guard let json = response.json else { return .failure(MCPHubOAuth.Failure("\(url.host ?? "it") answered with something that isn\u{2019}t JSON")) }
            return .success(json)
        }
    }
}
