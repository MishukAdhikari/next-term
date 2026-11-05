import Foundation
import Testing
@testable import NextTermCore

/// Signing in to a remote MCP server, its pure pieces: the WWW-Authenticate challenge, the URL rules, discovery against
/// fetch tables made from four real servers' answers (probed 2026-11-05), PKCE, the callback and its `iss`, the token
/// answers, and the client's registration.
struct MCPHubOAuthTests {
    // MARK: challenges

    @Test func theFourLiveChallengesAreRead() {
        let github = #"Bearer error="invalid_request", error_description="No access token was provided in this request", resource_metadata="https://api.githubcopilot.com/.well-known/oauth-protected-resource/mcp/""#
        let read = MCPHubOAuthChallenge.bearer(github)
        #expect(read?.error == "invalid_request")
        #expect(read?.errorDescription == "No access token was provided in this request")
        #expect(read?.resourceMetadata == "https://api.githubcopilot.com/.well-known/oauth-protected-resource/mcp/")
        #expect(read?.scopes == [])

        let linear = #"Bearer realm="OAuth", resource_metadata="https://mcp.linear.app/.well-known/oauth-protected-resource/mcp", scope="read write""#
        #expect(MCPHubOAuthChallenge.bearer(linear)?.scopes == ["read", "write"])
        #expect(MCPHubOAuthChallenge.bearer(linear)?.params["realm"] == "OAuth")
        let notion = #"Bearer realm="OAuth", resource_metadata="https://mcp.notion.com/.well-known/oauth-protected-resource/mcp", scope="default""#
        #expect(MCPHubOAuthChallenge.bearer(notion)?.scopes == ["default"])
        let sentry = #"Bearer realm="OAuth", resource_metadata="https://mcp.sentry.dev/.well-known/oauth-protected-resource/mcp", error="invalid_token""#
        #expect(MCPHubOAuthChallenge.bearer(sentry)?.resourceMetadata == "https://mcp.sentry.dev/.well-known/oauth-protected-resource/mcp")
        #expect(MCPHubOAuthChallenge.bearer(sentry)?.scope == nil)
    }

    @Test func severalChallengesQuotesAndCase() {
        let pair = MCPHubOAuthChallenge.parse(#"Basic realm="a, b", BEARER Resource_Metadata="https://x.example/m", scope="a \"b\" c""#)
        #expect(pair.map(\.scheme) == ["basic", "bearer"])
        #expect(pair[0].params["realm"] == "a, b")
        #expect(pair[1].resourceMetadata == "https://x.example/m")
        #expect(pair[1].scope == #"a "b" c"#)

        let token68 = MCPHubOAuthChallenge.parse("Basic dXNlcjpwYXNz==, Bearer scope=x")
        #expect(token68.count == 2)
        #expect(token68[0].token68 == "dXNlcjpwYXNz==")
        #expect(token68[1].scope == "x")

        // A quote left open: what came before it is kept, the parameter it began is dropped.
        let broken = MCPHubOAuthChallenge.parse(#"Bearer scope="read", resource_metadata="https://x.example/m"#)
        #expect(broken.count == 1)
        #expect(broken[0].scope == "read")
        #expect(broken[0].resourceMetadata == nil)

        let more = MCPHubOAuthChallenge.bearer(#"Bearer error="insufficient_scope", scope="files:write", error_description="needs files""#)
        #expect(more?.isInsufficientScope == true)
        #expect(more?.scopes == ["files:write"])
        #expect(MCPHubOAuthChallenge.bearer("Basic realm=x") == nil)
        #expect(MCPHubOAuthChallenge.parse("").isEmpty)
    }

    // MARK: URL rules

    let remote = URL(string: "https://mcp.linear.app/mcp")!
    let local = URL(string: "http://127.0.0.1:8123/mcp")!

    func refused(_ text: String, server: URL? = nil) -> Bool {
        if case .failure = MCPHubOAuthURL.checked(text, server: server ?? remote) { return true }
        return false
    }

    @Test func onlyHttpsAndLoopbackForALocalServerAreUsed() {
        for bad in ["javascript:alert(1)", "data:text/html,hi", "file:///etc/passwd", "vbscript:msgbox", "ftp://x.example/a",
                    "JAVASCRIPT:alert(1)", "https:%2F%2Fevil.example", "https://user:pass@x.example/a", "https://x.example/a#frag",
                    "http://x.example/a", "https://localhost/a", "https://127.0.0.1/a", "https://[::1]/a", "https://10.0.0.1/a",
                    "https://[::ffff:10.0.0.1]/a", "https://[::ffff:127.0.0.1]/a", "https://169.254.169.254/latest", "https://intranet/a",
                    " https://x.example/a", "https://x.example/a b"] {
            #expect(refused(bad), "\(bad) was let through")
        }
        #expect(!refused("https://x.example/a"))
        #expect(!refused("HTTPS://X.Example/a?b=c"))
        #expect(!refused("https://93.184.216.34/a"))
        // A server on this Mac may sign in on this Mac, over http too; one on the internet never may.
        #expect(!refused("http://127.0.0.1:9/authorize", server: local))
        #expect(!refused("http://localhost:9/authorize", server: local))
        #expect(refused("http://127.0.0.1:9/authorize"))
        #expect(MCPHubOAuthURL.canonical(URL(string: "HTTPS://MCP.Linear.App:443/mcp#x")!) == "https://mcp.linear.app/mcp")
        #expect(MCPHubOAuthURL.canonical(URL(string: "https://mcp.linear.app/mcp/")!) == "https://mcp.linear.app/mcp/")
    }

    // MARK: discovery

    /// A fetch answering from a table of URLs, counting what was asked.
    final class Table: @unchecked Sendable {
        var answers: [String: MCPHubOAuth.Response] = [:]
        var asked: [String] = []
        let lock = NSLock()

        func json(_ url: String, _ object: [String: Any], status: Int = 200) {
            answers[url] = MCPHubOAuth.Response(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }

        var fetch: MCPHubOAuth.Fetch {
            { [self] request in
                lock.lock()
                defer { lock.unlock() }
                asked.append(request.url.absoluteString)
                return .success(answers[request.url.absoluteString] ?? MCPHubOAuth.Response(status: 404))
            }
        }
    }

    func asMetadata(issuer: String, registration: Bool = true, s256: Bool = true, iss: Bool = true) -> [String: Any] {
        var object: [String: Any] = ["issuer": issuer, "authorization_endpoint": issuer + "/authorize", "token_endpoint": issuer + "/token",
                                     "authorization_response_iss_parameter_supported": iss]
        if s256 { object["code_challenge_methods_supported"] = ["S256"] }
        if registration { object["registration_endpoint"] = issuer + "/register" }
        return object
    }

    @Test func githubsPathIssuerIsFoundAndNeedsItsOwnApp() throws {
        let table = Table()
        let server = URL(string: "https://api.githubcopilot.com/mcp/")!
        table.json("https://api.githubcopilot.com/.well-known/oauth-protected-resource/mcp/", [
            "resource": "https://api.githubcopilot.com/mcp/", "authorization_servers": ["https://github.com/login/oauth"],
            "scopes_supported": ["repo", "read:org", "notifications"],
        ])
        var github = asMetadata(issuer: "https://github.com/login/oauth", registration: false)
        github["authorization_endpoint"] = "https://github.com/login/oauth/authorize"
        github["scopes_supported"] = ["offline_access"]
        table.json("https://github.com/.well-known/oauth-authorization-server/login/oauth", github)
        let challenge = MCPHubOAuthChallenge.bearer(#"Bearer error="invalid_request", resource_metadata="https://api.githubcopilot.com/.well-known/oauth-protected-resource/mcp/""#)
        let found = try MCPHubOAuthDiscovery.discover(server: server, name: "github", challenge: challenge, fetch: table.fetch).get()
        #expect(found.issuer == "https://github.com/login/oauth")
        #expect(found.resource == "https://api.githubcopilot.com/mcp/")
        #expect(found.issuerHost == "github.com")
        // The challenge names no scope: every one the resource metadata lists, and offline_access, which the server lists.
        #expect(found.scopes(challenge: challenge) == ["repo", "read:org", "notifications", "offline_access"])
        guard case .none(let why) = MCPHubOAuthRegistration.choose(name: "github", metadata: found, own: nil, registered: []) else {
            Issue.record("GitHub was registered with")
            return
        }
        #expect(why.hasPrefix("github doesn\u{2019}t let apps register themselves. Sign in with your own OAuth app"))
        // With the user's own app (and its secret), that one is used.
        let own = MCPHubOAuthRegistration.choose(name: "github", metadata: found, own: .init(clientID: "Iv1.abc", secret: "s3cret"), registered: [])
        guard case .use(let client) = own else { Issue.record("the user's app wasn't used"); return }
        #expect(client.kind == .preRegistered && client.authMethod == "client_secret_post" && client.secret == "s3cret")
    }

    @Test func wellKnownURLsInOrderAndTheTrailingSlashPair() throws {
        let table = Table()
        // No header: the path-inserted URL first, then the root.
        table.json("https://mcp.linear.app/.well-known/oauth-protected-resource", [
            "resource": "https://mcp.linear.app/mcp", "authorization_servers": ["https://mcp.linear.app"],
        ])
        table.json("https://mcp.linear.app/.well-known/oauth-authorization-server", asMetadata(issuer: "https://mcp.linear.app"))
        let found = try MCPHubOAuthDiscovery.discover(server: URL(string: "https://mcp.linear.app/mcp")!, name: "linear", challenge: nil,
                                                      fetch: table.fetch).get()
        #expect(found.resource == "https://mcp.linear.app/mcp")
        #expect(table.asked.prefix(2) == ["https://mcp.linear.app/.well-known/oauth-protected-resource/mcp",
                                          "https://mcp.linear.app/.well-known/oauth-protected-resource"])
        // /mcp/ is another resource than /mcp: its metadata isn't used for it.
        let slash = Table()
        slash.json("https://mcp.linear.app/.well-known/oauth-protected-resource/mcp/", [
            "resource": "https://mcp.linear.app/mcp", "authorization_servers": ["https://mcp.linear.app"],
        ])
        slash.json("https://mcp.linear.app/.well-known/oauth-authorization-server", asMetadata(issuer: "https://mcp.linear.app"))
        let refused = MCPHubOAuthDiscovery.discover(server: URL(string: "https://mcp.linear.app/mcp/")!, name: "linear", challenge: nil, fetch: slash.fetch)
        guard case .failure(let why) = refused else { Issue.record("another resource's metadata was used"); return }
        #expect(why.text.contains("for another server"))
    }

    @Test func aForgedIssuerNoPKCEAPrivateServerAndARedirectAreRefused() {
        let server = URL(string: "https://mcp.example.com/mcp")!
        let challenge = MCPHubOAuthChallenge.bearer(#"Bearer resource_metadata="https://mcp.example.com/prm""#)
        func table(_ issuer: String, _ metadata: [String: Any]?) -> Table {
            let table = Table()
            table.json("https://mcp.example.com/prm", ["resource": "https://mcp.example.com/mcp", "authorization_servers": [issuer]])
            if let metadata { table.json(issuer + "/.well-known/oauth-authorization-server", metadata) }
            return table
        }
        func failure(_ table: Table) -> String? {
            if case .failure(let why) = MCPHubOAuthDiscovery.discover(server: server, name: "x", challenge: challenge, fetch: table.fetch) { return why.text }
            return nil
        }
        // The document names another issuer than the one asked.
        var forged = asMetadata(issuer: "https://auth.example.com")
        forged["issuer"] = "https://evil.example.com"
        #expect(failure(table("https://auth.example.com", forged))?.contains("another issuer") == true)
        // No code_challenge_methods_supported: refused.
        #expect(failure(table("https://auth.example.com", asMetadata(issuer: "https://auth.example.com", s256: false)))?.contains("PKCE") == true)
        // An authorization server in a private network is never asked.
        let inside = table("https://10.0.0.5", asMetadata(issuer: "https://10.0.0.5"))
        #expect(failure(inside) != nil)
        #expect(!inside.asked.contains { $0.hasPrefix("https://10.0.0.5") })
        // A redirect is the answer, never followed.
        let moved = Table()
        moved.answers["https://mcp.example.com/prm"] = MCPHubOAuth.Response(status: 302, headers: ["Location": "https://evil.example.com/prm"])
        #expect(failure(moved) != nil)
        #expect(!moved.asked.contains { $0.contains("evil") })
    }

    // MARK: the flow

    let metadata = MCPHubOAuthDiscovery.Metadata(resource: "https://mcp.linear.app/mcp", issuer: "https://mcp.linear.app",
                                                 authorizationEndpoint: "https://mcp.linear.app/authorize?prompt=consent",
                                                 tokenEndpoint: "https://mcp.linear.app/token", issSupported: true)
    let client = MCPHubOAuthRegistration.Client(issuer: "https://mcp.linear.app", clientID: "abc", kind: .registered)

    @Test func pkceMatchesRFC7636sExample() {
        #expect(MCPHubOAuthFlow.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let made = MCPHubOAuthFlow.PKCE.make()
        #expect(made.verifier.count == 43)
        #expect(made.verifier.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
        #expect(MCPHubOAuthFlow.random(32) != MCPHubOAuthFlow.random(32))
    }

    @Test func theAuthorizationURLCarriesEveryParameter() throws {
        let pending = MCPHubOAuthFlow.Pending(state: "st", pkce: .init(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                                              metadata: metadata, client: client, redirect: "http://127.0.0.1:5555/callback",
                                              scopes: ["read", "write"])
        let url = try #require(pending.authorizationURL)
        let items = MCPHubOAuth.decodeForm(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "")
        let values = Dictionary(items, uniquingKeysWith: { a, _ in a })
        #expect(values["prompt"] == "consent")
        #expect(values["response_type"] == "code" && values["client_id"] == "abc" && values["state"] == "st")
        #expect(values["redirect_uri"] == "http://127.0.0.1:5555/callback")
        #expect(values["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM" && values["code_challenge_method"] == "S256")
        #expect(values["resource"] == "https://mcp.linear.app/mcp" && values["scope"] == "read write")
        #expect(url.absoluteString.contains("scope=read%20write"))
        let token = try #require(pending.tokenRequest(code: "c1"))
        #expect(token.value("code_verifier") == "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(token.value("resource") == "https://mcp.linear.app/mcp" && token.value("client_id") == "abc")
        #expect(token.value("grant_type") == "authorization_code" && token.value("redirect_uri") == "http://127.0.0.1:5555/callback")
    }

    @Test func issIsCheckedByRFC9207sFourCases() {
        #expect(MCPHubOAuthFlow.issAccepted(advertised: true, iss: "https://a.example", expected: "https://a.example"))
        #expect(!MCPHubOAuthFlow.issAccepted(advertised: true, iss: nil, expected: "https://a.example"))
        #expect(!MCPHubOAuthFlow.issAccepted(advertised: false, iss: "https://b.example", expected: "https://a.example"))
        #expect(MCPHubOAuthFlow.issAccepted(advertised: false, iss: nil, expected: "https://a.example"))
        // No normalization: a trailing slash or another case is another issuer.
        #expect(!MCPHubOAuthFlow.issAccepted(advertised: true, iss: "https://a.example/", expected: "https://a.example"))
        #expect(!MCPHubOAuthFlow.issAccepted(advertised: true, iss: "https://A.example", expected: "https://a.example"))

        let pending = MCPHubOAuthFlow.Pending(state: "st", metadata: metadata, client: client, redirect: "http://127.0.0.1:1/callback", scopes: [])
        #expect(MCPHubOAuthFlow.callback(query: [("state", "st"), ("code", "c"), ("iss", "https://mcp.linear.app")], pending: pending) == .code("c"))
        #expect(MCPHubOAuthFlow.callback(query: [("state", "other"), ("code", "c"), ("iss", "https://mcp.linear.app")], pending: pending) == .notOurs)
        // A mismatch is that, never the answer's own words.
        let wrong = MCPHubOAuthFlow.callback(query: [("state", "st"), ("error", "server_error"), ("error_description", "<b>click here</b>"),
                                                     ("iss", "https://evil.example")], pending: pending)
        #expect(wrong == .wrongIssuer)
        #expect(MCPHubOAuthFlow.callback(query: [("state", "st"), ("error", "access_denied"), ("iss", "https://mcp.linear.app")], pending: pending) == .denied)
    }

    @Test func tokenAnswersAreRead() throws {
        func answer(_ status: Int, _ object: [String: Any]) -> MCPHubOAuth.Response {
            MCPHubOAuth.Response(status: status, body: try! JSONSerialization.data(withJSONObject: object))
        }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let full = try MCPHubOAuthFlow.tokens(answer(200, ["access_token": "a", "token_type": "bearer", "expires_in": 3600,
                                                           "refresh_token": "r", "scope": "read write"]), now: now).get()
        #expect(full.access == "a" && full.refresh == "r" && full.expires == now.addingTimeInterval(3600) && full.scopes == ["read", "write"])
        // No expires_in: unknown, used until refused. No refresh token: none.
        let bare = try MCPHubOAuthFlow.tokens(answer(200, ["access_token": "a", "token_type": "Bearer"])).get()
        #expect(bare.expires == nil && bare.refresh == nil && bare.scopes == nil)
        #expect(MCPHubOAuthFlow.tokens(answer(400, ["error": "invalid_grant", "error_description": "x"])) == .failure(.invalidGrant))
        #expect(MCPHubOAuthFlow.tokens(answer(401, ["error": "invalid_client"])) == .failure(.invalidClient))
        #expect(MCPHubOAuthFlow.tokens(answer(500, [:])) == .failure(.other("HTTP 500")))
        #expect(MCPHubOAuthFlow.tokens(answer(200, ["access_token": "a", "token_type": "mac"])) == .failure(.other("a mac token, not a Bearer one")))
        let refresh = try #require(MCPHubOAuthFlow.refreshRequest(refresh: "r", metadata: metadata, client: client))
        #expect(refresh.value("scope") == nil && refresh.value("resource") == metadata.resource && refresh.value("refresh_token") == "r")
    }

    // MARK: registration

    @Test func theClientIsFoundInTheSpecsOrder() {
        var meta = metadata
        meta.registrationEndpoint = "https://mcp.linear.app/register"
        meta.cimdSupported = true
        // Pre-registered first.
        #expect(MCPHubOAuthRegistration.choose(name: "linear", metadata: meta, own: .init(clientID: "mine"), registered: [client])
            == .use(.init(issuer: meta.issuer, clientID: "mine", kind: .preRegistered)))
        // Then a registration kept for this issuer.
        #expect(MCPHubOAuthRegistration.choose(name: "linear", metadata: meta, own: nil, registered: [client]) == .use(client))
        // Then CIMD, only when Next Term has a document and the server takes one.
        #expect(MCPHubOAuthRegistration.choose(name: "linear", metadata: meta, own: nil, registered: [], metadataDocument: "https://nxtrm.example/c.json")
            == .use(.init(issuer: meta.issuer, clientID: "https://nxtrm.example/c.json", kind: .metadataDocument)))
        #expect(MCPHubOAuthRegistration.choose(name: "linear", metadata: meta, own: nil, registered: []) == .register(URL(string: "https://mcp.linear.app/register")!))
        // A client of another issuer is never reused, nor an expired one.
        let other = MCPHubOAuthRegistration.Client(issuer: "https://other.example", clientID: "o", kind: .registered)
        let expired = MCPHubOAuthRegistration.Client(issuer: meta.issuer, clientID: "e", kind: .registered, secretExpires: Date(timeIntervalSince1970: 1))
        #expect(MCPHubOAuthRegistration.choose(name: "linear", metadata: meta, own: nil, registered: [other, expired]) == .register(URL(string: "https://mcp.linear.app/register")!))
        // The user's app made for another issuer isn't sent to this one.
        guard case .none(let why) = MCPHubOAuthRegistration.choose(name: "linear", metadata: meta, own: .init(clientID: "mine", issuer: "https://old.example"), registered: []) else {
            Issue.record("an app was sent to another issuer")
            return
        }
        #expect(why.contains("old.example"))
    }

    @Test func theRegistrationBodyIsExactAndAPortIsRetried() throws {
        #expect(String(decoding: MCPHubOAuthRegistration.body(), as: UTF8.self)
            == #"{"client_name":"Next Term","application_type":"native","redirect_uris":["http:\/\/127.0.0.1\/callback"],"grant_types":["authorization_code","refresh_token"],"response_types":["code"],"token_endpoint_auth_method":"none"}"#)
        let json = try JSONSerialization.jsonObject(with: MCPHubOAuthRegistration.body()) as? [String: Any]
        #expect(json?["redirect_uris"] as? [String] == ["http://127.0.0.1/callback"])

        final class Bodies: @unchecked Sendable { var seen: [String] = [] }
        let bodies = Bodies()
        let fetch: MCPHubOAuth.Fetch = { request in
            let text = String(decoding: request.json ?? Data(), as: UTF8.self)
            bodies.seen.append(text)
            if !text.contains(":5555") {
                return .success(MCPHubOAuth.Response(status: 400, body: Data(#"{"error":"invalid_redirect_uri"}"#.utf8)))
            }
            return .success(MCPHubOAuth.Response(status: 201, body: Data(#"{"client_id":"new","client_secret":"cs","client_secret_expires_at":0,"token_endpoint_auth_method":"client_secret_post"}"#.utf8)))
        }
        let made = try MCPHubOAuthRegistration.register(at: URL(string: "https://a.example/register")!, issuer: "https://a.example", name: "a",
                                                         exact: "http://127.0.0.1:5555/callback", fetch: fetch).get()
        #expect(bodies.seen.count == 2)
        #expect(made.clientID == "new" && made.secret == "cs" && made.secretExpires == nil && made.authMethod == "client_secret_post")
        let posted = made.authenticated(MCPHubOAuth.Request(post: URL(string: "https://a.example/token")!, form: [("grant_type", "x")]))
        #expect(posted.value("client_id") == "new" && posted.value("client_secret") == "cs")
        var basic = made
        basic.authMethod = "client_secret_basic"
        let headed = basic.authenticated(MCPHubOAuth.Request(post: URL(string: "https://a.example/token")!, form: []))
        #expect(headed.headers["Authorization"] == "Basic " + Data("new:cs".utf8).base64EncodedString())
        #expect(headed.value("client_secret") == nil)
        // The secret is never encoded with the client.
        let encoded = String(decoding: try JSONEncoder().encode(made), as: UTF8.self)
        #expect(!encoded.contains("cs\""))
    }
}
