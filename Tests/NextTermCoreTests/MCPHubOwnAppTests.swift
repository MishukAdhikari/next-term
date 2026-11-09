import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// Signing in with the user's own OAuth app, for a server that can't register Next Term (GitHub's remote MCP server: no
/// registration endpoint, no client metadata documents, and a token endpoint that wants the client secret even with
/// PKCE). The fake authorization server is set up as GitHub is: `ownApp` made at it, DCR and CIMD off, a refused secret
/// answered with HTTP 200 and `incorrect_client_credentials`.
@Suite(.serialized) struct MCPHubOwnAppTests {
    static let clientID = "Ov23liFAKEclient"
    static let secret = "s3cr3t-value+/=with&odd chars"

    final class Setup {
        let auth: MCPHubFakeAuth
        let remote: MCPHubFakeRemote
        let folder: SecretFolder
        let key = SymmetricKey(size: .bits256)
        let store: SignInStore
        let http: MCPHubOAuthHTTP
        /// When the secret was read: how many authorization requests the server had seen by then.
        let reads = Reads()

        final class Reads: @unchecked Sendable {
            private let lock = NSLock()
            private var seen: [(host: String, authorizes: Int)] = []
            func add(_ host: String, _ authorizes: Int) { lock.lock(); seen.append((host, authorizes)); lock.unlock() }
            var all: [(host: String, authorizes: Int)] { lock.lock(); defer { lock.unlock() }; return seen }
        }

        init(secret: String = MCPHubOwnAppTests.secret) throws {
            auth = try MCPHubFakeAuth()
            auth.dcr = false
            auth.cimd = false
            auth.pathIssuer = true // GitHub's issuer has a path
            auth.ownApp = (MCPHubOwnAppTests.clientID, secret)
            remote = try MCPHubFakeRemote()
            remote.auth = auth
            auth.resource = remote.url.absoluteString
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("nt-ownapp-\(UUID().uuidString)", isDirectory: true)
            folder = SecretFolder(url: base.appendingPathComponent("Secrets.noindex", isDirectory: true))
            store = SignInStore(folder: folder, key: key)
            http = MCPHubOAuthHTTP(server: remote.url)
        }

        deinit { try? FileManager.default.removeItem(at: folder.url.deletingLastPathComponent()) }

        var challenge: MCPHubOAuthChallenge? { MCPHubOAuthChallenge.bearer("Bearer resource_metadata=\"\(auth.resourceMetadata)\"") }

        /// A sign-in as the user's own app, its secret read from "Secrets" (`given`) when asked for.
        func signIn(own: MCPHubOAuthRegistration.Own? = MCPHubOAuthRegistration.Own(clientID: MCPHubOwnAppTests.clientID,
                                                                                     secretName: "GITHUB_OAUTH_CLIENT_SECRET"),
                    given: String = MCPHubOwnAppTests.secret) -> Result<SignInFile.Record, MCPHubOAuth.Failure> {
            let auth = auth, reads = reads
            let flow = MCPHubSignIn(name: "GitHub", server: remote.url, challenge: challenge, own: own, readSecret: { host in
                reads.add(host, auth.count("/authorize"))
                return .success(given)
            }, store: store, fetch: http.asFetch)
            return flow.run(open: { url in
                MCPHubFakeAuth.signInSoon(url)
                return true
            }, until: Date().addingTimeInterval(60))
        }
    }

    // MARK: signing in

    @Test func ownAppSignsInWhereNothingRegistersAndTheSecretGoesOnlyToTheTokenEndpoint() throws {
        let setup = try Setup()
        setup.auth.accessLife = 30 // inside the minute's margin: the first need refreshes
        let record = try setup.signIn().get()
        setup.auth.accessLife = 3600
        #expect(record.client.kind == .preRegistered && record.client.clientID == Self.clientID && record.state == .signedIn)
        #expect(record.issuer == setup.auth.issuer && setup.auth.count("/register") == 0)

        // Read once, after the browser came back (the authorization request was out by then), for the issuer's host.
        #expect(setup.reads.all.count == 1 && setup.reads.all.first?.authorizes == 1 && setup.reads.all.first?.host == "127.0.0.1")
        // The authorization URL never carries it; the token request does, once; PKCE and state are as for any sign-in.
        let asked = Dictionary(setup.auth.lastAuthorize, uniquingKeysWith: { a, _ in a })
        #expect(asked["client_secret"] == nil && asked["client_id"] == Self.clientID && asked["code_challenge_method"] == "S256")
        #expect(asked["state"]?.count == 43)
        let token = Dictionary(setup.auth.lastToken, uniquingKeysWith: { a, _ in a })
        #expect(token["client_secret"] == Self.secret && token["code_verifier"]?.count == 43)
        #expect(setup.auth.secretSeen == ["/token"])

        // Nothing in the clear: not in the file, not in the record.
        let data = try #require(try setup.folder.read(SignInFile.name, cap: SignInFile.maxSize))
        #expect(!String(decoding: data, as: UTF8.self).contains(Self.secret))
        #expect(!String(decoding: data, as: UTF8.self).contains(MCPHubOAuth.encode(Self.secret)))
        #expect(record.client.secret == nil)

        // A refresh needs the secret too, and finds it sealed: no second read from Secrets.
        let refreshed = SignInRefresher(id: record.id, store: setup.store, fetch: setup.http.asFetch).token()
        guard case .token = refreshed else { Issue.record("no refresh: \(refreshed)"); return }
        #expect(setup.reads.all.count == 1 && setup.auth.secretSeen == ["/token", "/token"])
        #expect(Dictionary(setup.auth.lastToken, uniquingKeysWith: { a, _ in a })["grant_type"] == "refresh_token")
    }

    @Test func aRefusedSecretIsSaidPlainlyAndNothingIsKept() throws {
        let setup = try Setup()
        let result = setup.signIn(given: "not-the-secret")
        #expect(result == .failure(MCPHubOAuth.Failure(MCPHubSignIn.ownAppRefused("GitHub"))))
        #expect(MCPHubSignIn.ownAppRefused("GitHub") == "GitHub refused the client ID or secret. Check them in Settings \u{203A} MCP Servers \u{203A} Edit\u{2026}")
        let body = try setup.store.read().get()
        #expect(body.records.isEmpty && body.clients.isEmpty)
    }

    @Test func noOwnAppAndNoRegistrationOffersTheOwnApp() throws {
        let setup = try Setup()
        guard case .failure(let failure) = setup.signIn(own: nil) else { Issue.record("signed in with nothing to sign in as"); return }
        #expect(failure.text == "GitHub doesn\u{2019}t let apps register themselves. Sign in with your own OAuth app, or give GitHub a key (a personal access token) instead.")
        #expect(setup.auth.count("/authorize") == 0 && setup.reads.all.isEmpty)
    }

    @Test func anAppBoundToAnotherIssuerIsNeverUsedAndItsSecretNeverRead() throws {
        let setup = try Setup()
        let own = MCPHubOAuthRegistration.Own(clientID: Self.clientID, secretName: "GITHUB_OAUTH_CLIENT_SECRET", issuer: "https://github.com/login/oauth")
        guard case .failure(let failure) = setup.signIn(own: own) else { Issue.record("used an app made elsewhere"); return }
        #expect(failure.text.contains("the OAuth app you gave is for github.com"))
        #expect(setup.reads.all.isEmpty && setup.auth.secretSeen.isEmpty && setup.auth.count("/authorize") == 0)
    }

    // MARK: the rules, alone

    static func metadata(issuer: String = "https://github.com/login/oauth", token: String = "https://github.com/login/oauth/access_token")
        -> MCPHubOAuthDiscovery.Metadata {
        MCPHubOAuthDiscovery.Metadata(resource: "https://api.githubcopilot.com/mcp/", issuer: issuer,
                                      authorizationEndpoint: "https://github.com/login/oauth/authorize", tokenEndpoint: token,
                                      tokenAuthMethods: ["client_secret_basic", "client_secret_post"])
    }

    @Test func theSecretIsSentOnlyToItsIssuersOrigin() throws {
        // A token endpoint elsewhere: the app isn't used, so nothing is read.
        let away = MCPHubOAuthRegistration.choose(name: "GitHub", metadata: Self.metadata(token: "https://collect.example/token"),
                                                  own: .init(clientID: Self.clientID, secretName: "S"), registered: [])
        guard case .none(let why) = away else { Issue.record("chose \(away)"); return }
        #expect(why.contains("doesn\u{2019}t send your OAuth app\u{2019}s secret there"))
        // A public own app (no secret) may still use it.
        guard case .use = MCPHubOAuthRegistration.choose(name: "GitHub", metadata: Self.metadata(token: "https://collect.example/token"),
                                                        own: .init(clientID: Self.clientID), registered: []) else {
            Issue.record("a public app was refused"); return
        }
        // And a request built for elsewhere (a revocation endpoint at another host) carries the client ID alone.
        let client = MCPHubOAuthRegistration.Client(issuer: "https://github.com/login/oauth", clientID: Self.clientID, kind: .preRegistered,
                                                    authMethod: "client_secret_post", secret: Self.secret)
        let there = client.authenticated(MCPHubOAuth.Request(post: URL(string: "https://github.com/login/oauth/access_token")!, form: []))
        #expect(there.value("client_secret") == Self.secret)
        let elsewhere = client.authenticated(MCPHubOAuth.Request(post: URL(string: "https://api.github.com/revoke")!, form: []))
        #expect(elsewhere.value("client_secret") == nil && elsewhere.value("client_id") == Self.clientID)
        var basic = client
        basic.authMethod = "client_secret_basic"
        #expect(basic.authenticated(MCPHubOAuth.Request(post: URL(string: "http://github.com/login/oauth/access_token")!, form: [])).headers["Authorization"] == nil)
        #expect(basic.authenticated(MCPHubOAuth.Request(post: URL(string: "https://github.com:8443/x")!, form: [])).headers["Authorization"] == nil)
        #expect(basic.authenticated(MCPHubOAuth.Request(post: URL(string: "https://GitHub.com/login/oauth/access_token")!, form: [])).headers["Authorization"] != nil)
    }

    @Test func anAppSignedInAtOneIssuerIsBoundThereByTheSealedFile() {
        let kept = MCPHubOAuthRegistration.Client(issuer: "https://github.com/login/oauth", clientID: Self.clientID, kind: .preRegistered,
                                                  authMethod: "client_secret_post")
        let moved = MCPHubOAuthRegistration.choose(name: "GitHub", metadata: Self.metadata(issuer: "https://evil.example", token: "https://evil.example/token"),
                                                   own: .init(clientID: Self.clientID, secretName: "S"), registered: [kept])
        guard case .none(let why) = moved else { Issue.record("chose \(moved)"); return }
        #expect(why.hasPrefix("GitHub now signs in at evil.example"))
        guard case .use(let client) = MCPHubOAuthRegistration.choose(name: "GitHub", metadata: Self.metadata(), own: .init(clientID: Self.clientID, secretName: "S"),
                                                                     registered: [kept]) else { Issue.record("refused at its own issuer"); return }
        #expect(client.secret == nil && client.authMethod == "client_secret_post")
    }

    @Test func twoOwnAppsAtOneIssuerEachKeepTheirSecret() throws {
        let key = SymmetricKey(size: .bits256)
        var body = SignInFile.Body()
        let issuer = "https://github.com/login/oauth"
        for (id, secret) in [("app-a", "secret-a"), ("app-b", "secret-b"), ("app-a", "secret-a2")] {
            try body.keep(.init(issuer: issuer, clientID: id, kind: .preRegistered, authMethod: "client_secret_post", secret: secret), key: key)
        }
        let kept = body.registered(key: key).map { "\($0.clientID)=\($0.secret ?? "")" }.sorted()
        #expect(kept == ["app-a=secret-a2", "app-b=secret-b"])
        // A registration is still one per issuer.
        try body.keep(.init(issuer: issuer, clientID: "dcr-1", kind: .registered), key: key)
        try body.keep(.init(issuer: issuer, clientID: "dcr-2", kind: .registered), key: key)
        #expect(body.clients.filter { $0.client.kind == .registered }.map(\.client.clientID) == ["dcr-2"])
    }

    @Test func gitHubsErrorsAtHTTP200AreErrors() {
        func answer(_ json: String) -> Result<MCPHubOAuthFlow.Tokens, MCPHubOAuthFlow.TokenError> {
            MCPHubOAuthFlow.tokens(MCPHubOAuth.Response(status: 200, body: Data(json.utf8)))
        }
        #expect(answer(#"{"error":"incorrect_client_credentials","error_description":"x"}"#) == .failure(.invalidClient))
        #expect(answer(#"{"error":"bad_verification_code"}"#) == .failure(.invalidGrant))
        #expect(answer(#"{"error":"redirect_uri_mismatch"}"#) == .failure(.other("redirect_uri_mismatch")))
        #expect(answer(#"{"error":"x","access_token":"at"}"#) == .failure(.other("x")))
    }

    // MARK: the entry

    static func read(_ json: String) throws -> MCPHubFile.Value {
        try MCPHubFile.parse(Data(json.utf8)).get().document.entries[0].value
    }

    @Test func theEntryKeepsTheClientIDAndNamesTheSecret() throws {
        let json = """
            {"mcpServers": {"github": {"type": "http", "url": "https://api.githubcopilot.com/mcp/",
              "nextTerm": {"enabled": true, "oauth": {"clientID": "Ov23liABC", "clientSecret": "${secret:GITHUB_OAUTH_CLIENT_SECRET}",
                                                      "issuer": "https://github.com/login/oauth"}}}}}
            """
        let server = try MCPHubServer.decode(name: "github", try Self.read(json), place: .user).get()
        #expect(server.oauth == MCPHubServer.OAuthApp(clientID: "Ov23liABC", secretName: "GITHUB_OAUTH_CLIENT_SECRET",
                                                      issuer: "https://github.com/login/oauth"))
        // Written back as it was, and taken away cleanly.
        var plain = MCPHubServer.remote("github", url: "https://api.githubcopilot.com/mcp/")
        plain.oauth = MCPHubServer.OAuthApp(clientID: "Ov23liABC", secretName: "GITHUB_OAUTH_CLIENT_SECRET")
        let data = try #require(try MCPHubFile.updated(nil, place: .user, .set(plain)).get())
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"clientSecret\": \"${secret:GITHUB_OAUTH_CLIENT_SECRET}\"") && !text.contains("issuer"))
        let back = try MCPHubServer.decode(name: "github", MCPHubFile.parse(data).get().document.entries[0].value, place: .user).get()
        #expect(back == plain)
        plain.oauth = nil
        let gone = try #require(try MCPHubFile.updated(data, place: .user, .set(plain)).get())
        #expect(!String(decoding: gone, as: UTF8.self).contains("oauth"))
    }

    @Test func aSecretWrittenIntoTheEntryIsRefused() throws {
        func reasons(_ oauth: String, type: String = "\"type\": \"http\", \"url\": \"https://api.githubcopilot.com/mcp/\"") throws -> [String] {
            let json = "{\"mcpServers\": {\"github\": {\(type), \"nextTerm\": {\"oauth\": \(oauth)}}}}"
            guard case .failure(let broken) = MCPHubServer.decode(name: "github", try Self.read(json), place: .user) else { return [] }
            return broken.reasons
        }
        let literal = try reasons(#"{"clientID": "Ov23li", "clientSecret": "0123456789abcdef0123456789abcdef01234567"}"#)
        #expect(literal == ["Its nextTerm.oauth.clientSecret is the secret itself. Move it to Secrets, and use ${secret:NAME} in its place."])
        let wrapped = try reasons(#"{"clientID": "Ov23li", "clientSecret": "x${secret:A}"}"#)
        #expect(wrapped.first?.hasPrefix("Its nextTerm.oauth.clientSecret has a ${secret:") == true)
        let noID = try reasons(#"{"clientSecret": "${secret:A}"}"#)
        #expect(noID.first?.hasPrefix("Its nextTerm.oauth.clientID") == true)
        let plainHTTP = try reasons(#"{"clientID": "a", "issuer": "http://github.com/login/oauth"}"#)
        #expect(plainHTTP == ["Its nextTerm.oauth.issuer is not an https address."])
        let command = try reasons(#"{"clientID": "a"}"#, type: "\"command\": \"x\"")
        #expect(command.contains("Its nextTerm.oauth is for a server at a URL; a command signs in by itself."))
    }
}
