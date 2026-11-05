import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// Signing in end to end against the fake authorization server and resource server on this Mac (MCPHubFakeAuth,
/// MCPHubFakeRemote), with no browser: the test fetches the authorization URL itself, as the browser would. Then the
/// sealed sign-ins file (SignInFile), and the one refresher (SignInRefresher): one refresh for many needs, across two
/// copies, and a refresh token never sent twice.
@Suite(.serialized) struct MCPHubSignInTests {
    final class Setup {
        let auth: MCPHubFakeAuth
        let remote: MCPHubFakeRemote
        let folder: SecretFolder
        let key = SymmetricKey(size: .bits256)
        let store: SignInStore
        let http: MCPHubOAuthHTTP

        init() throws {
            auth = try MCPHubFakeAuth()
            remote = try MCPHubFakeRemote()
            remote.auth = auth
            auth.resource = remote.url.absoluteString
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("nt-signin-\(UUID().uuidString)", isDirectory: true)
            folder = SecretFolder(url: base.appendingPathComponent("Secrets.noindex", isDirectory: true))
            store = SignInStore(folder: folder, key: key)
            http = MCPHubOAuthHTTP(server: remote.url)
        }

        deinit { try? FileManager.default.removeItem(at: folder.url.deletingLastPathComponent()) }

        var challenge: MCPHubOAuthChallenge? { MCPHubOAuthChallenge.bearer("Bearer resource_metadata=\"\(auth.resourceMetadata)\"") }

        /// A sign-in, the "browser" approving at once.
        func signIn(scopes: [String]? = nil) -> Result<SignInFile.Record, MCPHubOAuth.Failure> {
            let flow = MCPHubSignIn(name: "linear", server: remote.url, challenge: challenge, store: store, fetch: http.asFetch, scopes: scopes)
            return flow.run(open: { url in
                DispatchQueue.global().async { _ = MCPHubFakeAuth.signIn(url) }
                return true
            }, until: Date().addingTimeInterval(20))
        }

        func refresher(_ id: String, store: SignInStore? = nil) -> SignInRefresher {
            SignInRefresher(id: id, store: store ?? self.store, fetch: http.asFetch)
        }

        func call(_ token: String) -> Result<[String: Any], MCPHubRemote.Failure> {
            MCPHubRemote(name: "linear", clientVersion: "1").call("echo", arguments: [:],
                                                                   endpoint: .init(url: remote.url, headers: ["Authorization": "Bearer " + token]),
                                                                   until: Date().addingTimeInterval(20))
        }
    }

    // MARK: signing in

    @Test func aSignInRegistersOpensTheBrowserAndKeepsTheTokensSealed() throws {
        let setup = try Setup()
        // The server asks: a 401 with its resource metadata.
        let refused = MCPHubRemote(name: "linear", clientVersion: "1").tools(.init(url: setup.remote.url), until: Date().addingTimeInterval(10))
        guard case .failure(let failure) = refused, case .unauthorized(401, let header) = failure.kind else {
            Issue.record("the server didn't ask for a sign-in")
            return
        }
        #expect(MCPHubOAuthChallenge.bearer(header)?.resourceMetadata == setup.auth.resourceMetadata)

        let record = try setup.signIn().get()
        #expect(record.resource == setup.remote.url.absoluteString && record.issuer == setup.auth.issuer && record.state == .signedIn)
        #expect(record.client.kind == .registered && setup.auth.count("/register") == 1)
        // Every parameter the spec asks for went to the authorization endpoint and the token endpoint.
        let asked = Dictionary(setup.auth.lastAuthorize, uniquingKeysWith: { a, _ in a })
        #expect(asked["code_challenge_method"] == "S256" && asked["resource"] == setup.remote.url.absoluteString)
        #expect(asked["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true && asked["scope"] == "read write")
        let token = Dictionary(setup.auth.lastToken, uniquingKeysWith: { a, _ in a })
        #expect(token["resource"] == setup.remote.url.absoluteString && token["code_verifier"]?.count == 43)

        // The file holds no token in the clear, and the call goes through with the one it seals.
        let data = try #require(try setup.folder.read(SignInFile.name, cap: SignInFile.maxSize))
        let tokens = try #require(setup.store.tokens(record))
        #expect(!String(decoding: data, as: UTF8.self).contains(tokens.access))
        #expect(!String(decoding: data, as: UTF8.self).contains(try #require(tokens.refresh)))
        #expect("\(tokens)" == "•••" && !String(describing: record).contains(tokens.access))
        let answer = try setup.call(tokens.access).get()
        #expect(((answer["content"] as? [[String: Any]])?.first?["text"] as? String) == "hello from remote")
        // A second sign-in reuses the registration.
        _ = try setup.signIn().get()
        #expect(setup.auth.count("/register") == 1)
        #expect((try setup.store.read().get()).records.count == 1)
    }

    @Test func aDeniedOrForeignAnswerIsRefusedAndAStrayRequestWaits() throws {
        let setup = try Setup()
        setup.auth.deny = true
        guard case .failure(let denied) = setup.signIn() else { Issue.record("a denied sign-in was kept"); return }
        #expect(denied.text == "Signing in to linear was cancelled in the browser.")

        setup.auth.deny = false
        setup.auth.iss = .wrong
        guard case .failure(let foreign) = setup.signIn() else { Issue.record("a foreign answer was used"); return }
        #expect(foreign.text.contains("another server") && !foreign.text.contains("script"))
        setup.auth.iss = .missing // advertised, not sent: refused too
        guard case .failure = setup.signIn() else { Issue.record("a missing iss was taken"); return }

        // The loopback listener: a stray request, and one with another state, don't end the wait.
        let listener = try MCPHubLoopback { query in query.contains { $0 == ("state", "good") } ? MCPHubLoopback.page("done") : nil }
        func get(_ path: String) -> Int {
            let done = DispatchSemaphore(value: 0)
            var status = 0
            URLSession(configuration: .ephemeral).dataTask(with: URL(string: "http://127.0.0.1:\(listener.port)\(path)")!) { _, response, _ in
                status = (response as? HTTPURLResponse)?.statusCode ?? 0
                done.signal()
            }.resume()
            _ = done.wait(timeout: .now() + 5)
            return status
        }
        #expect(get("/favicon.ico") == 404)
        #expect(get("/callback?state=bad&code=x") == 404)
        #expect(listener.wait(until: Date().addingTimeInterval(0.2)) == nil)
        #expect(!listener.isClosed && listener.strays == 2)
        #expect(get("/callback?state=good&code=x") == 200)
        #expect(listener.wait(until: Date().addingTimeInterval(1))?.contains { $0 == ("code", "x") } == true)
        #expect(listener.isClosed)
        // One that waited out its time is closed too.
        let idle = try MCPHubLoopback { _ in nil }
        #expect(idle.wait(until: Date().addingTimeInterval(0.1)) == nil)
        idle.close()
        #expect(idle.isClosed)
    }

    @Test func aPathIssuerAndNoS256() throws {
        let setup = try Setup()
        setup.auth.pathIssuer = true
        #expect(try setup.signIn().get().issuer == setup.auth.origin + "/login/oauth")
        let other = try Setup()
        other.auth.s256 = false
        guard case .failure(let why) = other.signIn() else { Issue.record("a server without S256 was signed in to"); return }
        #expect(why.text.contains("PKCE"))
    }

    // MARK: the sealed file

    @Test func theFileRoundTripsAndEveryTamperReadsAsTampered() throws {
        let key = SymmetricKey(size: .bits256)
        let meta = MCPHubOAuthDiscovery.Metadata(resource: "https://a.example/mcp", issuer: "https://a.example", authorizationEndpoint: "https://a.example/a",
                                                 tokenEndpoint: "https://a.example/t")
        let client = MCPHubOAuthRegistration.Client(issuer: "https://a.example", clientID: "c", kind: .registered, secret: "client-secret-value")
        var one = try SignInFile.record(name: "a", metadata: meta, client: client, tokens: .init(access: "access-1", refresh: "refresh-1", expires: nil, scopes: nil),
                                        scopes: [], key: key)
        let two = try SignInFile.record(name: "b", metadata: meta, client: client, tokens: .init(access: "access-2", refresh: nil, expires: nil, scopes: nil),
                                        scopes: [], key: key)
        one.consents = ["claude"]
        one.state = .signedOut(lapse: 1)
        var body = SignInFile.Body(records: [one, two])
        try body.keep(client, key: key)
        let data = try SignInFile.encode(body, key: key)
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["access-1", "refresh-1", "access-2", "client-secret-value"] { #expect(!text.contains(secret)) }
        let read = try SignInFile.read(data, key: key).get()
        #expect(read == body)
        #expect(SignInFile.open(read.records[0], key: key) == .init(access: "access-1", refresh: "refresh-1"))
        #expect(read.registered(key: key).first?.secret == "client-secret-value")
        #expect(SignInFile.read(nil, key: key) == .success(SignInFile.Body()))

        // Each change made outside Next Term breaks the MAC: a consent added, records swapped.
        func tampered(_ change: (inout SignInFile.Body) -> Void) throws -> Bool {
            var outer = try JSONDecoder().decode(SignInFile.Outer.self, from: data)
            var inner = try SignInFile.decoder.decode(SignInFile.Body.self, from: outer.body)
            change(&inner)
            outer.body = try SignInFile.encoder.encode(inner)
            return SignInFile.read(try JSONEncoder().encode(outer), key: key) == .failure(.tampered)
        }
        #expect(try tampered { $0.records[1].consents.append("codex") })
        #expect(try tampered { $0.records.swapAt(0, 1) })
        #expect(try tampered { $0.records[0].state = .signedIn })
        // Another key, or the MAC changed.
        #expect(SignInFile.read(data, key: SymmetricKey(size: .bits256)) == .failure(.tampered))
        var outer = try JSONDecoder().decode(SignInFile.Outer.self, from: data)
        outer.mac[0] ^= 1
        #expect(SignInFile.read(try JSONEncoder().encode(outer), key: key) == .failure(.tampered))
        // A box moved to another record doesn't open there.
        var moved = two
        moved.box = one.box
        #expect(SignInFile.open(moved, key: key) == nil)
    }

    @Test func membersAndStatesALaterReleaseAddsAreReadPast() throws {
        let key = SymmetricKey(size: .bits256)
        let meta = MCPHubOAuthDiscovery.Metadata(resource: "https://a.example/mcp", issuer: "https://a.example", authorizationEndpoint: "https://a.example/a",
                                                 tokenEndpoint: "https://a.example/t")
        let record = try SignInFile.record(name: "a", metadata: meta, client: .init(issuer: "https://a.example", clientID: "c", kind: .registered),
                                           tokens: .init(access: "x", refresh: nil, expires: nil, scopes: nil), scopes: [], key: key)
        var json = try JSONSerialization.jsonObject(with: SignInFile.encoder.encode(SignInFile.Body(records: [record]))) as! [String: Any]
        var records = json["records"] as! [[String: Any]]
        records[0]["later"] = ["anything": 1]
        records[0]["state"] = ["kind": "pausedByPolicy"]
        json["records"] = records
        json["future"] = true
        let inner = try JSONSerialization.data(withJSONObject: json)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: inner, using: SignInFile.indexKey(key)))
        let data = try JSONEncoder().encode(SignInFile.Outer(format: 2, body: inner, mac: mac))
        let read = try SignInFile.read(data, key: key).get()
        #expect(read.records.first?.state == .signedOut(lapse: -1))
    }

    // MARK: refreshing

    @Test func twentyNeedsAtOnceMakeOneRefresh() throws {
        let setup = try Setup()
        setup.auth.accessLife = 30 // inside the minute's margin: the first need refreshes
        let record = try setup.signIn().get()
        setup.auth.accessLife = 3600
        let refresher = setup.refresher(record.id)
        let outcomes = Outcomes()
        DispatchQueue.concurrentPerform(iterations: 20) { _ in outcomes.add(refresher.token()) }
        #expect(setup.auth.count("/token") == 2) // the code's, then one refresh
        #expect(Set(outcomes.all).count == 1)
        guard case .token(let access)? = outcomes.all.first else { Issue.record("no token"); return }
        #expect((try? setup.call(access).get()) != nil)
        let now = try setup.store.read().get().record(id: record.id)
        #expect(now?.generation == 2 && now?.state == .signedIn)
    }

    @Test func twoCopiesShareOneRefresh() throws {
        let setup = try Setup()
        setup.auth.accessLife = 30
        let record = try setup.signIn().get()
        setup.auth.accessLife = 3600
        let first = setup.refresher(record.id)
        let second = setup.refresher(record.id, store: SignInStore(folder: setup.folder, key: setup.key))
        let outcomes = Outcomes()
        DispatchQueue.concurrentPerform(iterations: 2) { index in outcomes.add((index == 0 ? first : second).token()) }
        #expect(setup.auth.count("/token") == 2)
        #expect(first.sent + second.sent == 1)
        #expect(Set(outcomes.all).count == 1)
    }

    @Test func aFlightACrashLeftNeverSendsItsTokenAgain() throws {
        let setup = try Setup()
        let record = try setup.signIn().get()
        let refresh = try #require(setup.store.tokens(record)?.refresh)
        // A copy marked the token spent and then quit before its answer.
        try setup.store.update { body in
            body.records[0].state = .refreshing(spent: SignInFile.digest(refresh))
            return (true, ())
        }
        let tokensBefore = setup.auth.count("/token")
        #expect(setup.refresher(record.id).token() == .signedOut(lapse: 1))
        #expect(setup.auth.count("/token") == tokensBefore)
    }

    @Test func neverSentGivesTheTokenBackAndSentButLostSpendsIt() throws {
        let setup = try Setup()
        setup.auth.accessLife = 30
        let record = try setup.signIn().get()
        // Surely never sent: the token isn't spent, and the next need refreshes with it.
        let offline = SignInRefresher(id: record.id, store: setup.store, fetch: { _ in .failure(.unsent("no network")) })
        #expect(offline.token() == .unreachable("no network"))
        #expect(try setup.store.read().get().record(id: record.id)?.state == .signedIn)
        guard case .token = setup.refresher(record.id).token() else { Issue.record("the unsent token was spent"); return }

        // Sent, and the answer lost: never sent again, so the sign-in lapses.
        try setup.store.update { body in
            body.records[0].accessExpires = Date.distantPast
            return (true, ())
        }
        setup.auth.loseNextRefresh = true
        let refresher = setup.refresher(record.id)
        #expect(refresher.token() == .signedOut(lapse: 2))
        let refreshes = setup.auth.count("/token")
        #expect(refresher.token() == .signedOut(lapse: 2))
        #expect(setup.auth.count("/token") == refreshes)
    }

    @Test func rotationModesAndARefusedToken() throws {
        // No rotation: the old refresh token is kept.
        let still = try Setup()
        still.auth.rotation = .none
        still.auth.accessLife = 30
        let record = try still.signIn().get()
        let first = try #require(still.store.tokens(record)?.refresh)
        guard case .token = still.refresher(record.id).token() else { Issue.record("no token"); return }
        #expect(still.store.tokens(try #require(try still.store.read().get().record(id: record.id)))?.refresh == first)

        // Strict, the grant revoked at the server: the 401's token is refused, the refresh fails, and it lapses.
        let strict = try Setup()
        let signed = try strict.signIn().get()
        let access = try #require(strict.store.tokens(signed)?.access)
        strict.auth.revokeAll()
        guard case .failure(let failure) = strict.call(access), case .unauthorized(401, _) = failure.kind else {
            Issue.record("a revoked token was taken")
            return
        }
        #expect(strict.refresher(signed.id).token(refused: access) == .signedOut(lapse: 1))

        // More access: the state asks to reconnect with the scopes joined, twice at most.
        #expect(try strict.store.needsMoreAccess(id: signed.id, scopes: ["files:write"]))
        #expect(try strict.store.read().get().record(id: signed.id)?.state == .needsMoreAccess(["read", "write", "files:write"]))
        #expect(try strict.store.needsMoreAccess(id: signed.id, scopes: ["files:write"]))
        #expect(try !strict.store.needsMoreAccess(id: signed.id, scopes: ["files:write"]))
        #expect(strict.refresher(signed.id).token() == .needsMoreAccess(["read", "write", "files:write"]))
    }

    @Test func anExpiredRegistrationIsMadeAgain() throws {
        let setup = try Setup()
        setup.auth.registrationLife = 0.5
        setup.auth.accessLife = 30
        let record = try setup.signIn().get()
        Thread.sleep(forTimeInterval: 0.7)
        // The refresh finds the client gone: the sign-in lapses and the registration is forgotten.
        #expect(setup.refresher(record.id).token() == .signedOut(lapse: 1))
        #expect(try setup.store.read().get().clients.isEmpty)
        setup.auth.registrationLife = nil
        _ = try setup.signIn().get()
        #expect(setup.auth.count("/register") == 2)
    }

    final class Outcomes: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var all: [SignInRefresher.Outcome] = []
        func add(_ outcome: SignInRefresher.Outcome) {
            lock.lock()
            all.append(outcome)
            lock.unlock()
        }
    }
}

extension SignInRefresher.Outcome: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(String(describing: self)) }
}
