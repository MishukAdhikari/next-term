import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// Next Term's OAuth authority for the remote door: metadata, registration, the pairing that is approved on the
/// Mac, the code and refresh exchanges with rotation, the 60-second grace and reuse, expiry, revokes and an
/// options change. Every clock is injected, and so is the randomness.
@Suite struct RemoteAccessOAuthTests {
    typealias OAuth = RemoteAccessOAuth

    static let host = "mcp.example.com"
    static let claude = "https://claude.ai/api/mcp/auth_callback"
    static let chatGPT = "https://chatgpt.com/connector_platform_oauth_redirect"
    /// 2027-01-15 08:00:00 UTC, so minutes and days add up plainly.
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    static let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk-and-some-more"

    /// Randomness that repeats from run to run (SplitMix64).
    final class Seeded: @unchecked Sendable {
        var state: UInt64

        init(_ seed: UInt64) { state = seed }

        func bytes(_ count: Int) -> [UInt8] {
            var bytes: [UInt8] = []
            while bytes.count < count {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                z ^= z >> 31
                for shift in stride(from: 0, to: 64, by: 8) where bytes.count < count {
                    bytes.append(UInt8(truncatingIfNeeded: z >> UInt64(shift)))
                }
            }
            return bytes
        }
    }

    static func authority(seed: UInt64 = 1, clients: [OAuth.Client] = [], grants: [OAuth.Grant] = []) -> OAuth {
        let random = Seeded(seed)
        return OAuth(host: host, clients: clients, grants: grants, random: { random.bytes($0) })
    }

    static func challenge(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let base64 = Data(digest).base64EncodedString()
        let urlSafe = base64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return urlSafe.replacingOccurrences(of: "=", with: "")
    }

    static func json(_ data: Data) -> [String: Any] {
        let object = try? JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    static func body(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// The query items of a redirect.
    static func items(_ link: String) -> [String: String] {
        let parts = URLComponents(string: link)?.queryItems ?? []
        var items: [String: String] = [:]
        for item in parts { items[item.name] = item.value ?? "" }
        return items
    }

    /// Registers a client with these callbacks and returns its id.
    static func register(_ oauth: inout OAuth, _ uris: [String] = [claude], now: Date = start,
                         extra: [String: Any] = [:]) -> String? {
        var metadata = extra
        metadata["redirect_uris"] = uris
        let answer = oauth.register(body(metadata), now: now)
        guard answer.status == 201 else { return nil }
        return json(answer.body)["client_id"] as? String
    }

    static func authorizeParameters(client: String, redirect: String = claude, state: String = "s-123",
                                    verifier: String = verifier) -> [String: String] {
        var parameters: [String: String] = [:]
        parameters["response_type"] = "code"
        parameters["client_id"] = client
        parameters["redirect_uri"] = redirect
        parameters["state"] = state
        parameters["code_challenge"] = challenge(verifier)
        parameters["code_challenge_method"] = "S256"
        parameters["resource"] = "https://\(host)/mcp"
        return parameters
    }

    /// What a pairing leaves: the authority, the grant, the code's redirect and the client.
    struct Paired {
        var oauth: OAuth
        var grant: OAuth.Grant
        var client: String
        var redirect: String
    }

    /// Register, open pairing, authorize, match the code, approve and poll to the redirect.
    static func pair(_ options: RemoteAccessOptions = .readOnly, seed: UInt64 = 1, now: Date = start,
                     tweak: (inout [String: String]) -> Void = { _ in }) throws -> Paired {
        var oauth = authority(seed: seed)
        let client = try #require(register(&oauth, now: now))
        oauth.openPairing(now: now)
        var parameters = authorizeParameters(client: client)
        tweak(&parameters)
        guard case .waiting(let id, let code) = oauth.authorize(parameters, now: now) else {
            throw Failure("authorize did not wait")
        }
        guard case .request(let request) = oauth.match(code: code, now: now) else { throw Failure("no match") }
        #expect(request.id == id)
        let grant = try oauth.approve(id, name: "Claude, phone", options: options, now: now).get()
        guard case .redirect(let link) = oauth.poll(id, now: now) else { throw Failure("no redirect") }
        return Paired(oauth: oauth, grant: grant, client: client, redirect: link)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func exchangeParameters(_ paired: Paired, verifier: String = verifier) -> [String: String] {
        var parameters: [String: String] = [:]
        parameters["grant_type"] = "authorization_code"
        parameters["code"] = items(paired.redirect)["code"] ?? ""
        parameters["redirect_uri"] = claude
        parameters["client_id"] = paired.client
        parameters["code_verifier"] = verifier
        parameters["resource"] = "https://\(host)/mcp"
        return parameters
    }

    static func refreshParameters(_ refresh: String, client: String) -> [String: String] {
        ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": client]
    }

    struct Tokens: Equatable {
        var access: String
        var refresh: String
        var scope: String
        var expiresIn: Int
    }

    static func tokens(_ answer: OAuth.Answer) -> Tokens? {
        let object = json(answer.body)
        guard answer.status == 200, let access = object["access_token"] as? String,
              let refresh = object["refresh_token"] as? String else { return nil }
        let scope = object["scope"] as? String ?? ""
        let expiresIn = object["expires_in"] as? Int ?? 0
        return Tokens(access: access, refresh: refresh, scope: scope, expiresIn: expiresIn)
    }

    /// Runs a token request the way the door does: an issue is saved, then applied, then sent.
    static func send(_ oauth: inout OAuth, _ parameters: [String: String], now: Date) -> OAuth.Answer {
        switch oauth.token(parameters, now: now) {
        case .answer(let answer):
            return answer
        case .issue(let issue):
            let applied = oauth.apply(issue)
            #expect(applied)
            return issue.answer
        }
    }

    static func error(_ answer: OAuth.Answer) -> String? {
        json(answer.body)["error"] as? String
    }

    /// A paired grant with its first pair of tokens.
    static func exchanged(_ options: RemoteAccessOptions = .readOnly, seed: UInt64 = 1) throws -> (Paired, Tokens) {
        var paired = try pair(options, seed: seed)
        let answer = send(&paired.oauth, exchangeParameters(paired), now: start)
        let first = try #require(Self.tokens(answer))
        return (paired, first)
    }

    static func minutes(_ count: Double) -> Date { start.addingTimeInterval(count * 60) }
    static func days(_ count: Double) -> Date { start.addingTimeInterval(count * 24 * 3600) }

    func isValid(_ oauth: OAuth, _ token: String, at now: Date) -> Bool {
        if case .valid = oauth.validate(token, now: now) { return true }
        return false
    }

    // MARK: the whole flow

    @Test func aClientRegistersPairsOnTheMacAndGetsTokens() throws {
        var oauth = Self.authority()
        let registered = oauth.register(Self.body(["redirect_uris": [Self.claude], "client_name": "Claude"]),
                                        now: Self.start)
        #expect(registered.status == 201)
        let document = Self.json(registered.body)
        let client = try #require(document["client_id"] as? String)
        #expect(document["redirect_uris"] as? [String] == [Self.claude])
        #expect(document["token_endpoint_auth_method"] as? String == "none")
        #expect(document["client_secret"] == nil)
        #expect(document["client_name"] as? String == "Claude")

        oauth.openPairing(now: Self.start)
        let parameters = Self.authorizeParameters(client: client)
        guard case .waiting(let id, let code) = oauth.authorize(parameters, now: Self.start) else {
            Issue.record("authorize did not wait")
            return
        }
        #expect(code.count == 6 && code.allSatisfy(\.isASCII) && code.allSatisfy(\.isNumber))
        #expect(id.count >= 22)
        #expect(oauth.poll(id, now: Self.start) == .waiting(requestID: id, code: code))

        guard case .request(let request) = oauth.match(code: code, now: Self.start) else {
            Issue.record("the code matched nothing")
            return
        }
        #expect(request.redirectHost == "claude.ai")
        #expect(request.clientName == "Claude")
        #expect(request.suggestedName == "Claude")
        let grant = try oauth.approve(id, name: "Claude, phone", options: .readOnly, now: Self.start).get()
        #expect(grant.name == "Claude, phone")
        #expect(grant.options == .readOnly)
        #expect(grant.clientID == client)
        #expect(grant.redirectHost == "claude.ai")
        // Pairing closes after one success.
        #expect(!oauth.pairingIsOpen(now: Self.start))

        // The browser's next reload goes back to claude.ai with the code, the state and the issuer.
        guard case .redirect(let link) = oauth.poll(id, now: Self.start.addingTimeInterval(2)) else {
            Issue.record("no redirect after approval")
            return
        }
        #expect(link.hasPrefix(Self.claude + "?"))
        let items = Self.items(link)
        #expect(items["state"] == "s-123")
        #expect(items["iss"] == "https://mcp.example.com")
        #expect((items["code"] ?? "").count >= 43)

        let paired = Paired(oauth: oauth, grant: grant, client: client, redirect: link)
        let exchange = oauth.token(Self.exchangeParameters(paired), now: Self.start.addingTimeInterval(3))
        guard case .issue(let issue) = exchange else {
            Issue.record("the code was not exchanged")
            return
        }
        // Nothing changes until the app saved the grant and applies it.
        #expect(oauth.grant(grant.id)?.refreshHash == nil)
        #expect(issue.grant.refreshHash != nil)
        let applied = oauth.apply(issue)
        #expect(applied)
        let first = try #require(Self.tokens(issue.answer))
        #expect(first.expiresIn == 900)
        #expect(first.scope == "nt.observe")
        #expect(Self.json(issue.answer.body)["token_type"] as? String == "Bearer")
        #expect(oauth.grant(grant.id)?.refreshHash == OAuth.hash(first.refresh))

        guard case .valid(let validated) = oauth.validate(first.access, now: Self.minutes(1)) else {
            Issue.record("the access token did not validate")
            return
        }
        #expect(validated.id == grant.id)
        #expect(validated.options == .readOnly)

        let refreshed = Self.send(&oauth, Self.refreshParameters(first.refresh, client: client), now: Self.minutes(14))
        let second = try #require(Self.tokens(refreshed))
        #expect(second.access != first.access)
        #expect(second.refresh != first.refresh)
        #expect(isValid(oauth, second.access, at: Self.minutes(20)))
        // The new refresh token lives until the grant ends.
        #expect(oauth.grant(grant.id)?.refreshHash == OAuth.hash(second.refresh))
        #expect(oauth.grant(grant.id)?.replacedHash == OAuth.hash(first.refresh))
    }

    @Test func theChatGPTCallbackIsAccepted() throws {
        var oauth = Self.authority()
        let client = try #require(Self.register(&oauth, [Self.chatGPT]))
        oauth.openPairing(now: Self.start)
        let parameters = Self.authorizeParameters(client: client, redirect: Self.chatGPT)
        guard case .waiting(let id, let code) = oauth.authorize(parameters, now: Self.start),
              case .request(let request) = oauth.match(code: code, now: Self.start) else {
            Issue.record("ChatGPT could not pair")
            return
        }
        #expect(request.redirectHost == "chatgpt.com")
        #expect(request.suggestedName == "ChatGPT")
        _ = try oauth.approve(id, name: "", options: .readOnly, now: Self.start).get()
        #expect(oauth.grants.first?.name == "ChatGPT")
        guard case .redirect(let link) = oauth.poll(id, now: Self.start) else {
            Issue.record("no redirect")
            return
        }
        #expect(link.hasPrefix(Self.chatGPT + "?"))
        #expect(Self.items(link)["iss"] == "https://mcp.example.com")
    }

    @Test func theMetadataHasItsFieldsAndNoClientMetadataDocuments() {
        let oauth = OAuth(host: "MCP.Example.com")
        let resource = Self.json(oauth.protectedResourceMetadata())
        #expect(resource["resource"] as? String == "https://mcp.example.com/mcp")
        #expect(resource["authorization_servers"] as? [String] == ["https://mcp.example.com"])
        #expect(resource["scopes_supported"] as? [String] == ["nt.observe", "nt.control"])
        #expect(resource["bearer_methods_supported"] as? [String] == ["header"])

        let server = Self.json(oauth.authorizationServerMetadata())
        #expect(server["issuer"] as? String == "https://mcp.example.com")
        #expect(server["authorization_endpoint"] as? String == "https://mcp.example.com/oauth/authorize")
        #expect(server["token_endpoint"] as? String == "https://mcp.example.com/oauth/token")
        #expect(server["registration_endpoint"] as? String == "https://mcp.example.com/oauth/register")
        #expect(server["revocation_endpoint"] as? String == "https://mcp.example.com/oauth/revoke")
        #expect(server["response_types_supported"] as? [String] == ["code"])
        #expect(server["grant_types_supported"] as? [String] == ["authorization_code", "refresh_token"])
        #expect(server["code_challenge_methods_supported"] as? [String] == ["S256"])
        #expect(server["token_endpoint_auth_methods_supported"] as? [String] == ["none"])
        #expect(server["authorization_response_iss_parameter_supported"] as? Bool == true)
        #expect(server["scopes_supported"] as? [String] == ["nt.observe", "nt.control", "offline_access"])
        #expect(server["client_id_metadata_document_supported"] == nil)
        // The documents are fixed: an options change never changes them.
        var changed = oauth
        changed.openPairing(now: Self.start)
        #expect(changed.authorizationServerMetadata() == oauth.authorizationServerMetadata())
    }

    @Test func theChallengeOnA401NamesTheResourceMetadata() {
        let oauth = Self.authority()
        let bare = #"Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp""#
        #expect(oauth.wwwAuthenticate(tokenSent: false) == bare)
        #expect(oauth.wwwAuthenticate(tokenSent: true) == bare + #", error="invalid_token""#)
        #expect(OAuth.bearer("Bearer ntat_abc") == "ntat_abc")
        #expect(OAuth.bearer("bearer   ntat_abc ") == "ntat_abc")
        #expect(OAuth.bearer("Basic dXNlcg==") == nil)
        #expect(OAuth.bearer("Bearer") == nil)
        #expect(OAuth.bearer(nil) == nil)
        #expect(oauth.validate(nil, now: Self.start) == .missing)
        #expect(oauth.validate("ntat_nothing", now: Self.start) == .invalid)
    }

    // MARK: access tokens

    @Test func anAccessTokenLastsFifteenMinutes() throws {
        let (paired, tokens) = try Self.exchanged()
        #expect(isValid(paired.oauth, tokens.access, at: Self.minutes(14).addingTimeInterval(59)))
        #expect(!isValid(paired.oauth, tokens.access, at: Self.minutes(15).addingTimeInterval(1)))
        // A refresh token is not an access token.
        #expect(paired.oauth.validate(tokens.refresh, now: Self.start) == .invalid)
    }

    @Test func tokensAreThePrefixAnd43Base64URLCharacters() throws {
        let (_, tokens) = try Self.exchanged()
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        for (token, prefix) in [(tokens.access, "ntat_"), (tokens.refresh, "ntrt_")] {
            #expect(token.hasPrefix(prefix))
            let text = token.dropFirst(prefix.count)
            #expect(text.count == 43)
            #expect(text.allSatisfy { alphabet.contains($0) })
            #expect(!token.contains("="))
        }
    }

    // MARK: refresh: rotation, grace and reuse

    @Test func aReuseWithinSixtySecondsGetsTheSamePairOnceAndASecondRevokes() throws {
        var (paired, first) = try Self.exchanged()
        let refreshed = Self.send(&paired.oauth, Self.refreshParameters(first.refresh, client: paired.client),
                                  now: Self.minutes(10))
        let second = try #require(Self.tokens(refreshed))
        _ = paired.oauth.takeEvents()

        // A lost reply: the old token again, 59 seconds later, gets the same pair, and nothing is cancelled.
        let late = Self.minutes(10).addingTimeInterval(59)
        let again = paired.oauth.token(Self.refreshParameters(first.refresh, client: paired.client), now: late)
        guard case .answer(let answer) = again else {
            Issue.record("a grace reuse needs nothing saved")
            return
        }
        let replayed = try #require(Self.tokens(answer))
        #expect(replayed.access == second.access)
        #expect(replayed.refresh == second.refresh)
        #expect(isValid(paired.oauth, second.access, at: late))
        #expect(paired.oauth.grant(paired.grant.id) != nil)
        #expect(paired.oauth.takeEvents().isEmpty)

        // A second reuse revokes the grant.
        let twice = Self.send(&paired.oauth, Self.refreshParameters(first.refresh, client: paired.client),
                              now: late.addingTimeInterval(0.5))
        #expect(Self.error(twice) == "invalid_grant")
        #expect(paired.oauth.grant(paired.grant.id) == nil)
        #expect(!isValid(paired.oauth, second.access, at: late))
        let refused = Self.send(&paired.oauth, Self.refreshParameters(second.refresh, client: paired.client),
                                now: late.addingTimeInterval(1))
        #expect(Self.error(refused) == "invalid_grant")
        let events = paired.oauth.takeEvents()
        #expect(events == [.refreshReused(grantID: paired.grant.id, name: "Claude, phone"),
                           .revoked(grantID: paired.grant.id, name: "Claude, phone", reason: .refreshReuse)])
    }

    /// AE4: a key replaced at 10:00 and used again at 10:05 revokes the grant; the same reuse at 10:00:30 gets
    /// the pair issued at 10:00 again.
    @Test func aReuseAfterSixtySecondsRevokesTheGrant() throws {
        var (paired, first) = try Self.exchanged()
        let tenAM = Self.minutes(10)
        let refreshed = Self.send(&paired.oauth, Self.refreshParameters(first.refresh, client: paired.client),
                                  now: tenAM)
        let second = try #require(Self.tokens(refreshed))

        var early = paired.oauth
        let halfMinute = Self.send(&early, Self.refreshParameters(first.refresh, client: paired.client),
                                   now: tenAM.addingTimeInterval(30))
        let replayed = try #require(Self.tokens(halfMinute))
        #expect(replayed.access == second.access && replayed.refresh == second.refresh)
        // The access token keeps its own end: 870 of its 900 seconds are left.
        #expect(replayed.expiresIn == 870)
        #expect(early.grant(paired.grant.id) != nil)

        _ = paired.oauth.takeEvents()
        let fiveMinutes = Self.send(&paired.oauth, Self.refreshParameters(first.refresh, client: paired.client),
                                    now: tenAM.addingTimeInterval(300))
        #expect(Self.error(fiveMinutes) == "invalid_grant")
        #expect(paired.oauth.grant(paired.grant.id) == nil)
        #expect(!isValid(paired.oauth, second.access, at: tenAM.addingTimeInterval(300)))
        let events = paired.oauth.takeEvents()
        #expect(events.first == .refreshReused(grantID: paired.grant.id, name: "Claude, phone"))
        let notice = OAuth.reuseNotice(grantName: "ChatGPT, work")
        #expect(notice == "A key for 'ChatGPT, work' was used twice. Access was cut. Pair again on the Mac.")
    }

    @Test func afterARelaunchAGraceReuseGetsANewPairThatReplacesTheRotation() throws {
        var (paired, first) = try Self.exchanged()
        let tenAM = Self.minutes(10)
        let refreshed = Self.send(&paired.oauth, Self.refreshParameters(first.refresh, client: paired.client),
                                  now: tenAM)
        let rotated = try #require(Self.tokens(refreshed))

        // A relaunch: only what the grant file holds comes back.
        var relaunched = Self.authority(seed: 7, clients: paired.oauth.clients, grants: paired.oauth.grants)
        let late = tenAM.addingTimeInterval(40)
        let grace = relaunched.token(Self.refreshParameters(first.refresh, client: paired.client), now: late)
        guard case .issue(let issue) = grace else {
            Issue.record("after a relaunch a grace reuse makes a new pair, which must be saved")
            return
        }
        let applied = relaunched.apply(issue)
        #expect(applied)
        let fresh = try #require(Self.tokens(issue.answer))
        #expect(fresh.refresh != rotated.refresh)
        #expect(fresh.access != rotated.access)
        #expect(isValid(relaunched, fresh.access, at: late))

        // The rotation's refresh token stops working; the new one works.
        let old = Self.send(&relaunched, Self.refreshParameters(rotated.refresh, client: paired.client),
                            now: late.addingTimeInterval(1))
        #expect(Self.error(old) == "invalid_grant")
        #expect(relaunched.grant(paired.grant.id) != nil)
        // The grace is spent: the replaced token once more revokes.
        var spent = relaunched
        let twice = Self.send(&spent, Self.refreshParameters(first.refresh, client: paired.client),
                              now: late.addingTimeInterval(2))
        #expect(Self.error(twice) == "invalid_grant")
        #expect(spent.grant(paired.grant.id) == nil)
        let next = Self.send(&relaunched, Self.refreshParameters(fresh.refresh, client: paired.client),
                             now: late.addingTimeInterval(3))
        #expect(Self.tokens(next) != nil)
    }

    @Test func aRotationThatWasNotSavedLeavesTheOldRefreshTokenCurrent() throws {
        var (paired, first) = try Self.exchanged()
        let parameters = Self.refreshParameters(first.refresh, client: paired.client)
        guard case .issue(let unsaved) = paired.oauth.token(parameters, now: Self.minutes(5)) else {
            Issue.record("a rotation must wait for the save")
            return
        }
        // The save failed: the new pair is never applied or sent.
        #expect(OAuth.serverError.status == 500)
        #expect(Self.error(OAuth.serverError) == "server_error")
        let never = try #require(Self.tokens(unsaved.answer))
        #expect(paired.oauth.validate(never.access, now: Self.minutes(5)) == .invalid)
        #expect(paired.oauth.grant(paired.grant.id)?.refreshHash == OAuth.hash(first.refresh))

        let retried = Self.send(&paired.oauth, parameters, now: Self.minutes(6))
        let second = try #require(Self.tokens(retried))
        #expect(second.refresh != never.refresh)
        let lost = Self.send(&paired.oauth, Self.refreshParameters(never.refresh, client: paired.client),
                             now: Self.minutes(7))
        #expect(Self.error(lost) == "invalid_grant")
        // An issue that no longer fits the grant is not applied.
        let stale = paired.oauth.apply(unsaved)
        #expect(!stale)
    }

    @Test func anExchangeThatWasNotSavedCanBeRetriedWithTheSameCode() throws {
        var paired = try Self.pair()
        let parameters = Self.exchangeParameters(paired)
        guard case .issue = paired.oauth.token(parameters, now: Self.start) else {
            Issue.record("the code was not exchanged")
            return
        }
        let retried = Self.send(&paired.oauth, parameters, now: Self.start.addingTimeInterval(5))
        #expect(Self.tokens(retried) != nil)
        #expect(paired.oauth.grant(paired.grant.id) != nil)
    }

    // MARK: expiry

    @Test func aGrantEndsAfterFourteenDaysUnusedOrNinetyDaysInAll() throws {
        var (paired, first) = try Self.exchanged()
        var idle = paired.oauth
        let unused = Self.send(&idle, Self.refreshParameters(first.refresh, client: paired.client),
                               now: Self.days(14).addingTimeInterval(1))
        #expect(Self.error(unused) == "invalid_grant")
        #expect(idle.grant(paired.grant.id) == nil)
        #expect(idle.takeEvents().last == .revoked(grantID: paired.grant.id, name: "Claude, phone", reason: .expired))

        // Used every day: a tool call counts as use, and so does a refresh.
        var refresh = first.refresh
        for day in 1...89 {
            let now = Self.days(Double(day))
            paired.oauth.noteUse(paired.grant.id, now: now)
            let answer = Self.send(&paired.oauth, Self.refreshParameters(refresh, client: paired.client), now: now)
            refresh = try #require(Self.tokens(answer)).refresh
        }
        let lastAccess = paired.oauth.grant(paired.grant.id)
        #expect(lastAccess?.lastUsed == Self.days(89))
        let after = Self.send(&paired.oauth, Self.refreshParameters(refresh, client: paired.client),
                              now: Self.days(90).addingTimeInterval(1))
        #expect(Self.error(after) == "invalid_grant")
        #expect(paired.oauth.grant(paired.grant.id) == nil)
    }

    @Test func anAccessTokenFailsOnceItsGrantHasEnded() throws {
        var (paired, first) = try Self.exchanged()
        #expect(paired.oauth.grant(paired.grant.id)?.endsAt == Self.days(14))
        // Validation alone never extends a grant; a tool call does.
        #expect(isValid(paired.oauth, first.access, at: Self.minutes(10)))
        #expect(paired.oauth.grant(paired.grant.id)?.lastUsed == Self.start)
        for day in stride(from: 13.0, to: 90, by: 13) {
            paired.oauth.noteUse(paired.grant.id, now: Self.days(day))
        }
        // An access token issued five minutes before the 90 days end stops working with its grant.
        let late = Self.days(90).addingTimeInterval(-300)
        let answer = Self.send(&paired.oauth, Self.refreshParameters(first.refresh, client: paired.client), now: late)
        let tokens = try #require(Self.tokens(answer))
        #expect(paired.oauth.grant(paired.grant.id)?.endsAt == Self.days(90))
        #expect(isValid(paired.oauth, tokens.access, at: Self.days(90).addingTimeInterval(-1)))
        #expect(!isValid(paired.oauth, tokens.access, at: Self.days(90).addingTimeInterval(1)))
    }

    // MARK: pairing

    @Test func aFourthWaitingRequestIsRefused() throws {
        var oauth = Self.authority()
        let client = try #require(Self.register(&oauth))
        oauth.openPairing(now: Self.start)
        var codes: Set<String> = []
        for index in 0..<3 {
            let parameters = Self.authorizeParameters(client: client, state: "s\(index)")
            guard case .waiting(_, let code) = oauth.authorize(parameters, now: Self.start) else {
                Issue.record("request \(index) did not wait")
                return
            }
            codes.insert(code)
        }
        #expect(codes.count == 3)
        let fourth = oauth.authorize(Self.authorizeParameters(client: client, state: "s3"), now: Self.start)
        #expect(fourth == .tooMany)
        #expect(oauth.waitingCount(now: Self.start) == 3)
    }

    @Test func aCodeTypedForAnExpiredRequestMatchesNothing() throws {
        var oauth = Self.authority()
        let client = try #require(Self.register(&oauth))
        oauth.openPairing(now: Self.start)
        guard case .waiting(let id, let code) = oauth.authorize(Self.authorizeParameters(client: client),
                                                               now: Self.start) else {
            Issue.record("no request")
            return
        }
        // Pairing opened again, so only the request's own 10 minutes run out.
        oauth.openPairing(now: Self.minutes(9))
        _ = oauth.takeEvents()
        let late = Self.minutes(10).addingTimeInterval(1)
        #expect(oauth.match(code: code, now: late) == .noMatch)
        #expect(oauth.poll(id, now: late) == .expired)
        #expect(oauth.takeEvents() == [.pairingExpired(requestID: id, clientID: client)])
        #expect(throws: OAuth.ApprovalError.noRequest) {
            try oauth.approve(id, name: "Late", options: .readOnly, now: late).get()
        }
    }

    /// AE2: a stranger who found the hostname adds the connector while pairing is closed.
    @Test func whilePairingIsClosedAuthorizeShowsTheClosedPage() throws {
        var oauth = Self.authority()
        let client = try #require(Self.register(&oauth))
        _ = oauth.takeEvents()
        #expect(oauth.authorize(Self.authorizeParameters(client: client), now: Self.start) == .closed)
        #expect(oauth.takeEvents().isEmpty)
        #expect(oauth.waitingCount(now: Self.start) == 0)

        // While it is open, the stranger's request waits unseen and expires; only the typed code is approved.
        oauth.openPairing(now: Self.start)
        guard case .waiting(let stranger, _) = oauth.authorize(Self.authorizeParameters(client: client, state: "x"),
                                                              now: Self.start),
              case .waiting(let mine, let myCode) = oauth.authorize(Self.authorizeParameters(client: client),
                                                                   now: Self.start) else {
            Issue.record("the requests did not wait")
            return
        }
        guard case .request(let matched) = oauth.match(code: myCode, now: Self.start) else {
            Issue.record("my code matched nothing")
            return
        }
        #expect(matched.id == mine)
        _ = try oauth.approve(mine, name: "Claude", options: .readOnly, now: Self.start).get()
        #expect(oauth.poll(stranger, now: Self.start) == .closed)
        #expect(oauth.grants.count == 1)
    }

    @Test func pairingClosesAfterTenMinutesOrWhenTheMacClosesIt() throws {
        var oauth = Self.authority()
        let client = try #require(Self.register(&oauth))
        oauth.openPairing(now: Self.start)
        #expect(oauth.pairingEnds == Self.minutes(10))
        #expect(oauth.pairingIsOpen(now: Self.minutes(9)))
        #expect(!oauth.pairingIsOpen(now: Self.minutes(10)))
        guard case .waiting(let id, _) = oauth.authorize(Self.authorizeParameters(client: client), now: Self.start) else {
            Issue.record("no request")
            return
        }
        // Closing the window before a code matched declines nothing: the browser gets the closed page.
        oauth.closePairing(now: Self.minutes(1))
        #expect(oauth.poll(id, now: Self.minutes(1)) == .closed)
        #expect(oauth.authorize(Self.authorizeParameters(client: client), now: Self.minutes(1)) == .closed)
        // Opening it again does not bring the old request back.
        oauth.openPairing(now: Self.minutes(2))
        #expect(oauth.poll(id, now: Self.minutes(2)) == .closed)
    }

    @Test func declineSendsTheBrowserBackWithAccessDenied() throws {
        var oauth = Self.authority()
        let client = try #require(Self.register(&oauth))
        oauth.openPairing(now: Self.start)
        guard case .waiting(let id, let code) = oauth.authorize(Self.authorizeParameters(client: client),
                                                               now: Self.start),
              case .request = oauth.match(code: code, now: Self.start) else {
            Issue.record("no request")
            return
        }
        let declined = oauth.decline(id, now: Self.start)
        #expect(declined)
        guard case .redirect(let link) = oauth.poll(id, now: Self.start) else {
            Issue.record("no redirect after decline")
            return
        }
        let items = Self.items(link)
        #expect(items["error"] == "access_denied")
        #expect(items["state"] == "s-123")
        #expect(items["iss"] == "https://mcp.example.com")
        #expect(items["code"] == nil)
        #expect(oauth.grants.isEmpty)
        #expect(oauth.takeEvents().contains(.pairingDeclined(requestID: id, clientID: client)))
    }

    @Test func fiveWrongCodesClosePairing() throws {
        var oauth = Self.authority()
        let client = try #require(Self.register(&oauth))
        oauth.openPairing(now: Self.start)
        guard case .waiting(let id, let code) = oauth.authorize(Self.authorizeParameters(client: client),
                                                               now: Self.start) else {
            Issue.record("no request")
            return
        }
        let wrong = code == "000000" ? "000001" : "000000"
        for _ in 0..<4 { #expect(oauth.match(code: wrong, now: Self.start) == .noMatch) }
        #expect(oauth.match(code: wrong, now: Self.start) == .closed)
        #expect(!oauth.pairingIsOpen(now: Self.start))
        #expect(oauth.match(code: code, now: Self.start) == .closed)
        #expect(oauth.poll(id, now: Self.start) == .closed)
        #expect(oauth.takeEvents().contains(.pairingClosed(.wrongCodes)))
    }

    // MARK: resource and scope

    @Test func theResourceIsComparedWithoutCaseAPortOrATrailingSlash() throws {
        let oauth = Self.authority()
        #expect(oauth.isOwnResource("https://MCP.example.com/mcp/"))
        #expect(oauth.isOwnResource("HTTPS://mcp.example.com:443/mcp"))
        #expect(oauth.isOwnResource(nil))
        #expect(!oauth.isOwnResource("https://mcp.example.com/mcp2"))
        #expect(!oauth.isOwnResource("https://mcp.example.com/MCP"))
        #expect(!oauth.isOwnResource("https://mcp.example.com/mcp//"))
        #expect(!oauth.isOwnResource("http://mcp.example.com/mcp"))
        #expect(!oauth.isOwnResource("https://mcp.example.com:8443/mcp"))
        #expect(!oauth.isOwnResource("https://mcp.example.com/mcp?x=1"))
        #expect(!oauth.isOwnResource("https://other.example.com/mcp"))
        // Only ASCII letters fold: the Kelvin sign is not a k.
        #expect(!OAuth(host: "mk.example.com").isOwnResource("https://m\u{212A}.example.com/mcp"))
        #expect(!oauth.isOwnResource(""))
    }

    @Test func aMissingResourceIsTheDoorsOwnAndAnotherGetsInvalidTarget() throws {
        // Missing at authorize and at token.
        var paired = try Self.pair { $0["resource"] = nil }
        var parameters = Self.exchangeParameters(paired)
        parameters["resource"] = nil
        #expect(Self.tokens(Self.send(&paired.oauth, parameters, now: Self.start)) != nil)

        // Another resource at authorize goes back with invalid_target.
        var oauth = Self.authority()
        let client = try #require(Self.register(&oauth))
        oauth.openPairing(now: Self.start)
        var other = Self.authorizeParameters(client: client)
        other["resource"] = "https://other.example.com/mcp"
        guard case .redirect(let link) = oauth.authorize(other, now: Self.start) else {
            Issue.record("another resource did not redirect")
            return
        }
        #expect(Self.items(link)["error"] == "invalid_target")
        #expect(Self.items(link)["state"] == "s-123")

        // And at token.
        var later = try Self.pair()
        var wrong = Self.exchangeParameters(later)
        wrong["resource"] = "https://other.example.com/mcp"
        #expect(Self.error(Self.send(&later.oauth, wrong, now: Self.start)) == "invalid_target")
    }

    @Test func aRequestedScopeNeverChangesTheGrant() throws {
        let scopes: [String?] = [nil, "offline_access", "nt.unknown write:all", "nt.control", "nt.observe nt.control"]
        for scope in scopes {
            var paired = try Self.pair(.readOnly) { $0["scope"] = scope }
            #expect(paired.grant.options == .readOnly)
            let answer = Self.send(&paired.oauth, Self.exchangeParameters(paired), now: Self.start)
            let tokens = try #require(Self.tokens(answer))
            #expect(tokens.scope == "nt.observe")
        }
        let control = try Self.exchanged(.control).1
        #expect(control.scope == "nt.observe nt.control")
        let custom = try Self.exchanged(.customStart).1
        #expect(custom.scope == "nt.observe nt.control")
    }

    @Test func theScopeNamesControlOnlyForOptionsThatAdmitAControlTool() {
        #expect(OAuth.scope(for: .readOnly) == "nt.observe")
        var servers = RemoteAccessOptions.readOnly
        servers[.serversRead] = true
        #expect(OAuth.scope(for: servers) == "nt.observe")
        // Text and Keys options admit no tool by themselves, Checks never do, and the Secrets options are a stub
        // that admits nothing until the secret tools are in the base.
        var widened = RemoteAccessOptions.readOnly
        widened[.anySlash] = true
        widened[.everyKey] = true
        widened[.listSecrets] = true
        widened[.useSecrets] = true
        widened[.askOnMac] = false
        #expect(OAuth.scope(for: widened) == "nt.observe")
        var typing = RemoteAccessOptions.readOnly
        typing[.typeAsking] = true
        #expect(OAuth.scope(for: typing) == "nt.observe nt.control")
        var writes = RemoteAccessOptions.readOnly
        writes[.writeTools] = true
        #expect(OAuth.scope(for: writes) == "nt.observe nt.control")
    }

    // MARK: options change

    @Test func changingOptionsKeepsTheTokensAndChangesTheNextValidation() throws {
        var (paired, tokens) = try Self.exchanged()
        _ = paired.oauth.takeEvents()
        let didChange = paired.oauth.changeOptions(of: paired.grant.id, to: .control)
        #expect(didChange)
        guard case .valid(let grant) = paired.oauth.validate(tokens.access, now: Self.minutes(1)) else {
            Issue.record("an options change ended the access token")
            return
        }
        #expect(grant.options == .control)
        #expect(grant.preset == .control)
        let events = paired.oauth.takeEvents()
        let changed = OAuth.Event.optionsChanged(grantID: paired.grant.id, name: "Claude, phone", old: .readOnly,
                                                 new: .control)
        #expect(events == [changed])
        // The door's next streamed call carries tools/list_changed once.
        let marked = paired.oauth.takeToolListChanged(paired.grant.id)
        #expect(marked)
        let markedAgain = paired.oauth.takeToolListChanged(paired.grant.id)
        #expect(!markedAgain)

        // The refresh token still works, and its reply's scope follows the new options.
        let refreshed = Self.send(&paired.oauth, Self.refreshParameters(tokens.refresh, client: paired.client),
                                  now: Self.minutes(2))
        #expect(Self.tokens(refreshed)?.scope == "nt.observe nt.control")

        // The same options again change nothing and log nothing; an unknown grant changes nothing.
        let same = paired.oauth.changeOptions(of: paired.grant.id, to: .control)
        #expect(same)
        #expect(paired.oauth.takeEvents().isEmpty)
        let unmarked = paired.oauth.takeToolListChanged(paired.grant.id)
        #expect(!unmarked)
        let unknown = paired.oauth.changeOptions(of: "nope", to: .readOnly)
        #expect(!unknown)
    }

    // MARK: registration

    @Test func registrationKeepsOnlyTheTwoVendorCallbacks() throws {
        var oauth = Self.authority()
        let lookalikes = [Self.claude + "/x", "http://claude.ai/api/mcp/auth_callback"]
        let refused = oauth.register(Self.body(["redirect_uris": lookalikes]), now: Self.start)
        #expect(refused.status == 400)
        #expect(Self.error(refused) == "invalid_redirect_uri")
        #expect(oauth.clients.isEmpty)
        let droppedURIs = OAuth.Event.registrationDropped(clientID: nil, field: "redirect_uris", values: lookalikes)
        #expect(oauth.takeEvents() == [droppedURIs])

        let metadata: [String: Any] = [
            "redirect_uris": [Self.claude + "/x", Self.claude],
            "token_endpoint_auth_method": "client_secret_post",
        ]
        let kept = oauth.register(Self.body(metadata), now: Self.start)
        #expect(kept.status == 201)
        let document = Self.json(kept.body)
        #expect(document["redirect_uris"] as? [String] == [Self.claude])
        #expect(document["token_endpoint_auth_method"] as? String == "none")
        let client = try #require(document["client_id"] as? String)
        #expect(oauth.clients.map(\.redirectURIs) == [[Self.claude]])
        let events = oauth.takeEvents()
        #expect(events.contains(.registrationDropped(clientID: client, field: "redirect_uris", values: [Self.claude + "/x"])))
        let method = OAuth.Event.registrationDropped(clientID: client, field: "token_endpoint_auth_method",
                                                     values: ["client_secret_post"])
        #expect(events.contains(method))

        let missing = oauth.register(Self.body(["client_name": "x"]), now: Self.start)
        #expect(Self.error(missing) == "invalid_redirect_uri")
        let notJSON = oauth.register(Data("redirect_uris=x".utf8), now: Self.start)
        #expect(Self.error(notJSON) == "invalid_client_metadata")
    }

    @Test func theClientNameIsKeptUpTo100PrintableCharacters() throws {
        var oauth = Self.authority()
        let long = String(repeating: "a", count: 150)
        _ = Self.register(&oauth, extra: ["client_name": "Cla\u{0}ude\n\u{202E}"])
        _ = Self.register(&oauth, extra: ["client_name": long])
        _ = Self.register(&oauth, extra: ["client_name": " \u{7}\n "])
        #expect(oauth.clients.map(\.name) == ["Claude", String(repeating: "a", count: 100), nil])
    }

    @Test func clientsWithoutAGrantAreCappedAndTheOldestIsDropped() throws {
        var clients: [OAuth.Client] = []
        for index in 0..<20 {
            let registered = Self.start.addingTimeInterval(Double(index) * 60)
            clients.append(OAuth.Client(id: "c\(index)", name: nil, redirectURIs: [Self.claude],
                                        registered: registered, lastUsed: registered))
        }
        let granted = OAuth.Client(id: "granted", name: "Claude", redirectURIs: [Self.claude],
                                   registered: Self.days(-30), lastUsed: Self.days(-30))
        let grant = OAuth.Grant(id: "g1", name: "Claude", clientID: "granted", clientName: "Claude",
                                redirectHost: "claude.ai", options: .readOnly, host: Self.host,
                                created: Self.days(-1), lastUsed: Self.days(-1))
        var oauth = Self.authority(clients: [granted] + clients, grants: [grant])
        let now = Self.minutes(30)
        oauth.openPairing(now: now)
        let added = try #require(Self.register(&oauth, now: now))
        let ids = oauth.clients.map(\.id)
        #expect(!ids.contains("c0"))
        #expect(ids.contains("c1"))
        #expect(ids.contains("granted"))
        #expect(ids.contains(added))
        #expect(oauth.clients.count == 21)
    }

    @Test func registrationsAreLimitedPerPairingWindowAndPerHourOutsideOne() throws {
        var oauth = Self.authority()
        for _ in 0..<5 { #expect(Self.register(&oauth) != nil) }
        let sixth = oauth.register(Self.body(["redirect_uris": [Self.claude]]), now: Self.minutes(59))
        #expect(sixth.status == 429)
        // An hour later there is room again.
        #expect(Self.register(&oauth, now: Self.minutes(61)) != nil)

        var window = Self.authority()
        window.openPairing(now: Self.start)
        for _ in 0..<10 { #expect(Self.register(&window) != nil) }
        let eleventh = window.register(Self.body(["redirect_uris": [Self.claude]]), now: Self.start)
        #expect(eleventh.status == 429)
    }

    @Test func clientsWithoutAGrantAreDroppedAfterADayUnused() throws {
        var oauth = Self.authority()
        let idle = try #require(Self.register(&oauth))
        var paired = try Self.pair()
        // A day later the idle client is gone; a client with a grant stays.
        oauth.openPairing(now: Self.days(1).addingTimeInterval(1))
        #expect(!oauth.clients.contains { $0.id == idle })
        paired.oauth.openPairing(now: Self.days(2))
        #expect(paired.oauth.clients.contains { $0.id == paired.client })
        // An unknown client gets a page, never a redirect.
        let parameters = Self.authorizeParameters(client: idle)
        guard case .invalid = oauth.authorize(parameters, now: Self.days(1).addingTimeInterval(2)) else {
            Issue.record("an unknown client was redirected")
            return
        }
    }

    // MARK: authorize errors

    @Test func errorsBeforeTheRedirectIsTrustedGiveAPage() throws {
        var oauth = Self.authority()
        let client = try #require(Self.register(&oauth))
        oauth.openPairing(now: Self.start)
        var unknown = Self.authorizeParameters(client: client)
        unknown["client_id"] = "unknown"
        var otherRedirect = Self.authorizeParameters(client: client)
        otherRedirect["redirect_uri"] = Self.chatGPT
        for parameters in [unknown, otherRedirect] {
            guard case .invalid = oauth.authorize(parameters, now: Self.start) else {
                Issue.record("expected a page for \(parameters)")
                continue
            }
        }
        guard case .invalid = oauth.authorize(nil, now: Self.start) else {
            Issue.record("a repeated parameter must give a page")
            return
        }
        // A client with one callback may leave redirect_uri out.
        var implicit = Self.authorizeParameters(client: client)
        implicit["redirect_uri"] = nil
        guard case .waiting = oauth.authorize(implicit, now: Self.start) else {
            Issue.record("the only callback was not used")
            return
        }
    }

    @Test func thePlainMethodAndAMissingChallengeAreRefused() throws {
        var oauth = Self.authority()
        let client = try #require(Self.register(&oauth))
        oauth.openPairing(now: Self.start)
        var plain = Self.authorizeParameters(client: client)
        plain["code_challenge_method"] = "plain"
        var missing = Self.authorizeParameters(client: client)
        missing["code_challenge"] = nil
        var noMethod = Self.authorizeParameters(client: client)
        noMethod["code_challenge_method"] = nil
        var noState = Self.authorizeParameters(client: client)
        noState["state"] = nil
        var token = Self.authorizeParameters(client: client)
        token["response_type"] = "token"
        let cases: [([String: String], String)] = [
            (plain, "invalid_request"), (missing, "invalid_request"), (noMethod, "invalid_request"),
            (noState, "invalid_request"), (token, "unsupported_response_type"),
        ]
        for (parameters, expected) in cases {
            guard case .redirect(let link) = oauth.authorize(parameters, now: Self.start) else {
                Issue.record("expected a redirect for \(expected)")
                continue
            }
            let items = Self.items(link)
            #expect(link.hasPrefix(Self.claude + "?"))
            #expect(items["error"] == expected)
            #expect(items["iss"] == "https://mcp.example.com")
            #expect(items["state"] == parameters["state"])
        }
        #expect(oauth.waitingCount(now: Self.start) == 0)
    }

    // MARK: token errors

    @Test func aReusedCodeGetsInvalidGrantAndRevokesTheGrant() throws {
        var (paired, tokens) = try Self.exchanged()
        _ = paired.oauth.takeEvents()
        let again = Self.send(&paired.oauth, Self.exchangeParameters(paired), now: Self.start.addingTimeInterval(10))
        #expect(Self.error(again) == "invalid_grant")
        #expect(paired.oauth.grant(paired.grant.id) == nil)
        #expect(!isValid(paired.oauth, tokens.access, at: Self.start.addingTimeInterval(10)))
        let events = paired.oauth.takeEvents()
        #expect(events == [.codeReused(grantID: paired.grant.id, name: "Claude, phone"),
                           .revoked(grantID: paired.grant.id, name: "Claude, phone", reason: .codeReuse)])
    }

    @Test func aWrongVerifierOrALateCodeGetsInvalidGrant() throws {
        var paired = try Self.pair()
        let wrong = Self.exchangeParameters(paired, verifier: String(repeating: "x", count: 43))
        #expect(Self.error(Self.send(&paired.oauth, wrong, now: Self.start)) == "invalid_grant")
        // The code is spent: the right verifier after a wrong one is a reuse.
        let right = Self.send(&paired.oauth, Self.exchangeParameters(paired), now: Self.start)
        #expect(Self.error(right) == "invalid_grant")
        #expect(paired.oauth.grant(paired.grant.id) == nil)

        var late = try Self.pair()
        let expired = Self.send(&late.oauth, Self.exchangeParameters(late), now: Self.start.addingTimeInterval(61))
        #expect(Self.error(expired) == "invalid_grant")

        var otherClient = try Self.pair()
        var parameters = Self.exchangeParameters(otherClient)
        parameters["client_id"] = "someone-else"
        #expect(Self.error(Self.send(&otherClient.oauth, parameters, now: Self.start)) == "invalid_grant")

        var otherRedirect = try Self.pair()
        var redirected = Self.exchangeParameters(otherRedirect)
        redirected["redirect_uri"] = Self.chatGPT
        #expect(Self.error(Self.send(&otherRedirect.oauth, redirected, now: Self.start)) == "invalid_grant")
    }

    @Test func badTokenRequestsAreNamed() throws {
        var oauth = Self.authority()
        #expect(Self.error(Self.send(&oauth, ["grant_type": "password"], now: Self.start)) == "unsupported_grant_type")
        #expect(Self.error(Self.send(&oauth, [:], now: Self.start)) == "invalid_request")
        let noCode = ["grant_type": "authorization_code", "client_id": "c"]
        #expect(Self.error(Self.send(&oauth, noCode, now: Self.start)) == "invalid_request")
        let unknownRefresh = Self.refreshParameters("ntrt_nothing", client: "c")
        #expect(Self.error(Self.send(&oauth, unknownRefresh, now: Self.start)) == "invalid_grant")
        guard case .answer(let repeated) = oauth.token(nil, now: Self.start) else {
            Issue.record("a repeated parameter must be refused")
            return
        }
        #expect(Self.error(repeated) == "invalid_request")
        #expect(repeated.status == 400)
    }

    @Test func aTokenIssuedUnderOneHostFailsAfterTheHostChanges() throws {
        var (paired, tokens) = try Self.exchanged()
        _ = paired.oauth.takeEvents()
        let ended = paired.oauth.setHost("other.example.com", now: Self.minutes(1))
        #expect(ended == [paired.grant.id])
        #expect(paired.oauth.validate(tokens.access, now: Self.minutes(1)) == .invalid)
        let refreshed = Self.send(&paired.oauth, Self.refreshParameters(tokens.refresh, client: paired.client),
                                  now: Self.minutes(2))
        #expect(Self.error(refreshed) == "invalid_grant")
        #expect(paired.oauth.takeEvents() == [.revoked(grantID: paired.grant.id, name: "Claude, phone",
                                                       reason: .hostChanged)])
        #expect(paired.oauth.issuer == "https://other.example.com")

        // A grant saved under another host does not come back.
        let reloaded = OAuth(host: "third.example.com", grants: [paired.grant])
        #expect(reloaded.grants.isEmpty)
    }

    // MARK: revokes

    @Test func afterRevokeAllNoTokenValidates() throws {
        var (paired, first) = try Self.exchanged()
        paired.oauth.openPairing(now: Self.minutes(1))
        let client = try #require(Self.register(&paired.oauth, now: Self.minutes(1)))
        let parameters = Self.authorizeParameters(client: client)
        guard case .waiting(let id, _) = paired.oauth.authorize(parameters, now: Self.minutes(1)) else {
            Issue.record("the second request did not wait")
            return
        }
        _ = try paired.oauth.approve(id, name: "Second", options: .control, now: Self.minutes(1)).get()
        #expect(paired.oauth.grants.count == 2)
        let ended = paired.oauth.revokeAll(now: Self.minutes(2))
        #expect(ended.count == 2)
        #expect(paired.oauth.grants.isEmpty)
        #expect(paired.oauth.validate(first.access, now: Self.minutes(2)) == .invalid)
        let refreshed = Self.send(&paired.oauth, Self.refreshParameters(first.refresh, client: paired.client),
                                  now: Self.minutes(2))
        #expect(Self.error(refreshed) == "invalid_grant")
        let reasons = paired.oauth.takeEvents().compactMap { event -> OAuth.RevokeReason? in
            if case .revoked(_, _, let reason) = event { return reason }
            return nil
        }
        #expect(reasons == [.revokeAll, .revokeAll])
    }

    @Test func revokingAGrantOnTheMacEndsItsTokens() throws {
        var (paired, tokens) = try Self.exchanged()
        let revoked = paired.oauth.revoke(grant: paired.grant.id, now: Self.minutes(1))
        #expect(revoked)
        let again = paired.oauth.revoke(grant: paired.grant.id, now: Self.minutes(1))
        #expect(!again)
        #expect(paired.oauth.validate(tokens.access, now: Self.minutes(1)) == .invalid)
        #expect(paired.oauth.takeEvents().last == .revoked(grantID: paired.grant.id, name: "Claude, phone",
                                                            reason: .onMac))
        // The client stays a day after its grant ends, so the vendor can pair again with it.
        var later = try Self.exchanged().0
        let ended = later.oauth.revoke(grant: later.grant.id, now: Self.days(2))
        #expect(ended)
        later.oauth.openPairing(now: Self.days(3).addingTimeInterval(-60))
        #expect(later.oauth.clients.contains { $0.id == later.client })
        later.oauth.openPairing(now: Self.days(3).addingTimeInterval(1))
        #expect(!later.oauth.clients.contains { $0.id == later.client })
    }

    @Test func aClientRevokingItsRefreshTokenEndsTheGrant() throws {
        var (paired, tokens) = try Self.exchanged()
        // An access token alone: only it ends.
        let access = paired.oauth.revoke(["token": tokens.access, "client_id": paired.client], now: Self.minutes(1))
        #expect(access.answer.status == 200)
        #expect(access.ended.isEmpty)
        #expect(paired.oauth.validate(tokens.access, now: Self.minutes(1)) == .invalid)
        #expect(paired.oauth.grant(paired.grant.id) != nil)
        // Another client's revoke changes nothing, and still gets 200.
        let stranger = paired.oauth.revoke(["token": tokens.refresh, "client_id": "other"], now: Self.minutes(1))
        #expect(stranger.answer.status == 200)
        #expect(stranger.ended.isEmpty)
        // The refresh token ends the grant.
        let refresh = paired.oauth.revoke(["token": tokens.refresh, "token_type_hint": "refresh_token"],
                                          now: Self.minutes(1))
        #expect(refresh.answer.status == 200)
        #expect(refresh.ended == [paired.grant.id])
        #expect(paired.oauth.grant(paired.grant.id) == nil)
        #expect(paired.oauth.takeEvents().last == .revoked(grantID: paired.grant.id, name: "Claude, phone",
                                                            reason: .client))
        let unknown = paired.oauth.revoke(["token": "ntrt_nothing"], now: Self.minutes(1))
        #expect(unknown.answer.status == 200)
        let missing = paired.oauth.revoke([:], now: Self.minutes(1))
        #expect(missing.answer.status == 400)
    }

    @Test func turningOffDropsAccessTokensAndKeepsGrants() throws {
        var (paired, tokens) = try Self.exchanged()
        paired.oauth.dropAccessTokens()
        #expect(paired.oauth.validate(tokens.access, now: Self.minutes(1)) == .invalid)
        #expect(paired.oauth.grant(paired.grant.id) != nil)
        let refreshed = Self.send(&paired.oauth, Self.refreshParameters(tokens.refresh, client: paired.client),
                                  now: Self.minutes(2))
        let next = try #require(Self.tokens(refreshed))
        #expect(isValid(paired.oauth, next.access, at: Self.minutes(2)))
    }

    // MARK: events

    @Test func oneApprovalEmitsItsEventsInOrder() throws {
        var oauth = Self.authority()
        let client = try #require(Self.register(&oauth, extra: ["client_name": "Claude"]))
        oauth.openPairing(now: Self.start)
        guard case .waiting(let id, let code) = oauth.authorize(Self.authorizeParameters(client: client),
                                                               now: Self.start),
              case .request = oauth.match(code: code, now: Self.start) else {
            Issue.record("no request")
            return
        }
        let grant = try oauth.approve(id, name: "Claude, phone", options: .customStart, now: Self.start).get()
        let expected: [OAuth.Event] = [
            .clientRegistered(clientID: client, clientName: "Claude", redirectHosts: ["claude.ai"]),
            .pairingOpened(until: Self.minutes(10)),
            .pairingAsked(requestID: id, clientID: client, clientName: "Claude", redirectHost: "claude.ai"),
            .pairingApproved(requestID: id, grantID: grant.id, name: "Claude, phone", options: .customStart),
            .pairingClosed(.approved),
        ]
        #expect(oauth.takeEvents() == expected)
        #expect(oauth.takeEvents().isEmpty)
        #expect(expected.map(\.kind) == ["client.registered", "pairing.opened", "pairing.asked", "pairing.approved",
                                         "pairing.closed"])
    }

    @Test func noDescriptionShowsAToken() throws {
        var (paired, tokens) = try Self.exchanged()
        guard case .issue(let issue) = paired.oauth.token(Self.refreshParameters(tokens.refresh, client: paired.client),
                                                          now: Self.minutes(1)) else {
            Issue.record("no issue")
            return
        }
        let texts = [String(describing: issue), String(reflecting: issue), String(describing: issue.answer),
                     String(reflecting: issue.answer)]
        for text in texts {
            #expect(!text.contains("ntat_"))
            #expect(!text.contains("ntrt_"))
        }
    }

    // MARK: form parameters

    @Test func formParametersDecodeAndRefuseRepeats() {
        let parsed = OAuth.parameters("a=1&b=two+words&c=%2B%26&d&&e=")
        #expect(parsed == ["a": "1", "b": "two words", "c": "+&", "d": "", "e": ""])
        #expect(OAuth.parameters("a=1&a=2") == nil)
        #expect(OAuth.parameters("a=%zz") == nil)
        #expect(OAuth.parameters(nil) == [:])
        #expect(OAuth.parameters(body: Data([0xFF, 0xFE])) == nil)
        #expect(OAuth.parameters(body: Data("grant_type=refresh_token".utf8)) == ["grant_type": "refresh_token"])
        #expect(OAuth.waitPath(for: "abc") == "/oauth/authorize/wait?request=abc")
    }
}
