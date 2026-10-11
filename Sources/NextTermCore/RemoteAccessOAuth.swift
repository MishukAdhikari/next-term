import CryptoKit
import Foundation
import Security

/// Next Term's own OAuth 2.1 authorization server for the Remote access door (R9 to R18, R60), as a value with
/// no I/O: the clock comes in with every call and the randomness is injected. The app keeps one under a lock
/// (RemoteAccessServer), saves what changes through the grant store, and sends the answers.
///
/// A client registers (only the claude.ai and chatgpt.com callbacks, public clients), opens `/oauth/authorize`
/// while pairing is open on the Mac, and its browser shows a 6-digit code. The user types that code on the Mac,
/// names the grant and picks its options; that approval issues a single-use code bound to PKCE. The token
/// endpoint answers from memory and never waits for the user. Access tokens last 15 minutes and live only here;
/// refresh tokens are replaced on every use and kept only as SHA-256 hashes, with one reuse within 60 seconds
/// forgiven and any other reuse ending the grant. Requested scopes never change a grant: it holds the options
/// the user picked on the Mac, and they change only there.
public struct RemoteAccessOAuth: Sendable {
    // MARK: limits

    /// How long an access token works (R16).
    public static let accessTokenLifetime: TimeInterval = 15 * 60
    /// How long an authorization code can be exchanged, once.
    public static let codeLifetime: TimeInterval = 60
    /// How long Connect a Client keeps pairing open (R11).
    public static let pairingWindow: TimeInterval = 10 * 60
    /// How long a pairing request waits for its code to be typed on the Mac (R14).
    public static let requestLifetime: TimeInterval = 10 * 60
    /// Pairing requests waiting at once, at most (R14).
    public static let maximumWaiting = 3
    /// A refresh token replaced less than this long ago works once more and gets the pair that replaced it (R16).
    public static let refreshGrace: TimeInterval = 60
    /// A grant ends after this long without use: a successful refresh or a tool call (R17).
    public static let grantIdleLimit: TimeInterval = 14 * 24 * 3600
    /// A grant ends this long after it was created, used or not (R17).
    public static let grantLifetime: TimeInterval = 90 * 24 * 3600
    /// Registrations an hour while pairing is closed.
    public static let registrationsPerHour = 5
    /// Registrations in one pairing window.
    public static let registrationsPerWindow = 10
    /// Clients without a grant that are kept; past it the oldest of them is dropped.
    public static let maximumClientsWithoutGrant = 20
    /// A client without a grant is dropped after this long unused.
    public static let clientUnusedLimit: TimeInterval = 24 * 3600
    /// A client's own name is kept up to this many Unicode scalars of printable text, in whole characters.
    public static let maximumClientName = 100
    /// A grant's name, as typed on the Mac, is kept up to this many Unicode scalars, in whole characters.
    public static let maximumGrantName = 100
    /// The longest `state` a client may send, in UTF-8 bytes; it comes back in the redirect.
    public static let maximumState = 1024
    /// Wrong codes typed on the Mac before pairing closes.
    public static let wrongCodeLimit = 5
    /// How long a used code is remembered, so a second exchange of it ends its grant.
    static let usedCodeMemory: TimeInterval = 10 * 60
    /// How long a finished request (approved, declined, closed or expired) is remembered, so its browser still
    /// gets its redirect or its page.
    static let requestMemory: TimeInterval = 60 * 60
    /// Values a dropped-at-registration event keeps, each cut to `droppedValueLength` UTF-8 bytes.
    static let droppedValues = 10
    static let droppedValueLength = 200
    /// Refresh tokens a grant remembers as replaced besides the latest, about a day of refreshes every 15
    /// minutes. A reuse of any of them ends the grant; an older one is only unknown.
    static let replacedTokenMemory = 100

    // MARK: fixed values

    /// The only callbacks registration keeps (R10).
    public static let claudeCallback = "https://claude.ai/api/mcp/auth_callback"
    public static let chatGPTCallback = "https://chatgpt.com/connector_platform_oauth_redirect"
    public static let redirectURIs = [claudeCallback, chatGPTCallback]

    /// Token prefixes, so secret scanners can spot them (R18).
    public static let accessPrefix = "ntat_"
    public static let refreshPrefix = "ntrt_"

    /// The scopes the metadata lists. They are words for the vendor's screen: the grant's options decide.
    public static let observeScope = "nt.observe"
    public static let controlScope = "nt.control"

    // MARK: records

    /// A registered client (RFC 7591).
    public struct Client: Equatable, Sendable, Codable {
        public var id: String
        /// The client's own words, printable and cut to `maximumClientName`.
        public var name: String?
        /// Only the vendor callbacks it asked for.
        public var redirectURIs: [String]
        public var registered: Date
        /// Registered, or last named by an authorize request or a grant that ended.
        public var lastUsed: Date

        public init(id: String, name: String?, redirectURIs: [String], registered: Date, lastUsed: Date) {
            self.id = id
            self.name = name
            self.redirectURIs = redirectURIs
            self.registered = registered
            self.lastUsed = lastUsed
        }
    }

    /// One pairing: what the user named and allowed on the Mac, and the hashes of its refresh tokens. The grant
    /// store saves it as it is; it never holds a token in the clear.
    public struct Grant: Equatable, Sendable, Codable {
        public var id: String
        public var name: String
        public var clientID: String
        public var clientName: String?
        /// claude.ai or chatgpt.com.
        public var redirectHost: String
        public var options: RemoteAccessOptions
        /// The public hostname it was issued under. A token works only under it (KTD17).
        public var host: String
        public var created: Date
        /// The last successful refresh or tool call.
        public var lastUsed: Date
        /// SHA-256 of the current refresh token, in hex. Nil until the code is exchanged.
        public var refreshHash: String?
        /// SHA-256 of the refresh token it replaced last, and when: the one the 60-second grace is for.
        public var replacedHash: String?
        public var replacedAt: Date?
        /// SHA-256 of the refresh tokens replaced before that one, oldest first, at most `replacedTokenMemory`.
        public var earlierHashes: [String]

        public init(id: String, name: String, clientID: String, clientName: String?, redirectHost: String,
                    options: RemoteAccessOptions, host: String, created: Date, lastUsed: Date,
                    refreshHash: String? = nil, replacedHash: String? = nil, replacedAt: Date? = nil,
                    earlierHashes: [String] = []) {
            self.id = id
            self.name = name
            self.clientID = clientID
            self.clientName = clientName
            self.redirectHost = redirectHost
            self.options = options
            self.host = host
            self.created = created
            self.lastUsed = lastUsed
            self.refreshHash = refreshHash
            self.replacedHash = replacedHash
            self.replacedAt = replacedAt
            self.earlierHashes = earlierHashes
        }

        /// When it ends: 14 days after its last use, or 90 days after it was created, whichever comes first.
        public var endsAt: Date {
            let idle = lastUsed.addingTimeInterval(RemoteAccessOAuth.grantIdleLimit)
            let lifetime = created.addingTimeInterval(RemoteAccessOAuth.grantLifetime)
            return min(idle, lifetime)
        }

        public func isActive(at now: Date) -> Bool { now < endsAt }

        /// The preset its options carry the name of.
        public var preset: RemoteAccessPreset { options.preset }

        /// Whether `key` is the hash of a refresh token it replaced, the last one or an earlier one.
        func replaced(_ key: String) -> Bool {
            RemoteAccessOAuth.same(replacedHash, key) || replacedEarlier(key)
        }

        /// Whether `key` is the hash of a refresh token it replaced before the last one.
        func replacedEarlier(_ key: String) -> Bool {
            earlierHashes.contains { RemoteAccessOAuth.same($0, key) }
        }

        /// Adds a replaced token's hash to the earlier ones, keeping the last `replacedTokenMemory`.
        mutating func rememberEarlier(_ hash: String?) {
            guard let hash else { return }
            earlierHashes.append(hash)
            let extra = earlierHashes.count - RemoteAccessOAuth.replacedTokenMemory
            if extra > 0 { earlierHashes.removeFirst(extra) }
        }
    }

    /// A browser waiting for its code to be typed on the Mac. Its description shows neither its id, its code nor
    /// where it goes back to: the id lets a browser fetch the redirect, and the redirect carries the code.
    public struct PairingRequest: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
        CustomReflectable {
        public enum Outcome: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
            case waiting
            /// Approved or declined: where the browser goes back to.
            case redirect(String)
            /// Pairing closed before its code was typed.
            case closed
            /// Its 10 minutes ran out.
            case expired

            public var description: String {
                switch self {
                case .waiting: return "waiting"
                case .redirect: return "redirect"
                case .closed: return "closed"
                case .expired: return "expired"
                }
            }

            public var debugDescription: String { description }
        }

        /// 128 random bits: the browser's key to its own request.
        public let id: String
        /// Six digits, unique among the waiting requests.
        public let code: String
        public let clientID: String
        public let clientName: String?
        public let redirectURI: String
        public let created: Date
        let redirectGiven: Bool
        let challenge: String
        let state: String
        public internal(set) var outcome: Outcome

        /// claude.ai or chatgpt.com, for the pairing window.
        public var redirectHost: String { RemoteAccessOAuth.host(of: redirectURI) }

        public var expires: Date { created.addingTimeInterval(RemoteAccessOAuth.requestLifetime) }

        /// The name the pairing window starts with.
        public var suggestedName: String { RemoteAccessOAuth.suggestedName(redirectHost: redirectHost) }

        var isWaiting: Bool { outcome == .waiting }

        /// A short hash of the id, for the audit log and descriptions.
        public var logID: String { RemoteAccessOAuth.logID(id) }

        public var description: String { "pairing request \(logID) for \(redirectHost), \(outcome)" }
        public var debugDescription: String { description }
        public var customMirror: Mirror {
            Mirror(self, children: ["request": logID, "clientID": clientID, "outcome": outcome.description])
        }
    }

    /// An authorization code, kept by its hash.
    struct AuthorizationCode: Sendable {
        let grantID: String
        let clientID: String
        let redirectURI: String
        let redirectGiven: Bool
        let challenge: String
        let issued: Date
        var used = false

        var expires: Date { issued.addingTimeInterval(RemoteAccessOAuth.codeLifetime) }
    }

    /// An access token, kept by its hash.
    struct AccessToken: Sendable {
        let grantID: String
        let host: String
        let expires: Date
    }

    /// The last pair a refresh issued for a grant, kept for 60 seconds so a lost reply can be sent again.
    struct RecentPair: Sendable {
        let access: String
        let refresh: String
        let accessExpires: Date
        /// The refresh token's hash this pair replaced: the one that may come once more.
        let replacedHash: String
        let issued: Date
        var graceUsed: Bool
    }

    // MARK: answers

    /// A JSON answer for an OAuth endpoint. Send it with `Cache-Control: no-store`: it may hold a token or a
    /// client id. Its description shows only the status and the size, so a log line cannot leak a token.
    public struct Answer: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
        CustomReflectable {
        public var status: Int
        /// JSON, or empty for a revoke.
        public var body: Data

        public init(status: Int, body: Data) {
            self.status = status
            self.body = body
        }

        public var description: String { "\(status), \(body.count) bytes" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["status": status, "bodySize": body.count]) }
    }

    /// What the door does with `/oauth/authorize` and `/oauth/authorize/wait`. Its description shows no request
    /// id, code or link.
    public enum Authorization: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
        CustomReflectable {
        /// The page with the code, which reloads itself to `waitPath(for:)`.
        case waiting(requestID: String, code: String)
        /// 302 to this link: the client's callback with a code, or with an error.
        case redirect(String)
        /// "Pairing is closed. On your Mac, open Next Term › Settings › Remote Access › Connect a Client."
        case closed
        /// "Not approved in time. Start again from your Mac."
        case expired
        /// Three requests are waiting already.
        case tooMany
        /// The request can't be trusted with a redirect: the page says why.
        case invalid(String)

        public var description: String {
            switch self {
            case .waiting(let requestID, _): return "waiting, request \(RemoteAccessOAuth.logID(requestID))"
            case .redirect(let link): return "redirect to \(RemoteAccessOAuth.host(of: link))"
            case .closed: return "closed"
            case .expired: return "expired"
            case .tooMany: return "too many"
            case .invalid(let reason): return "invalid: \(reason)"
            }
        }

        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["authorization": description]) }
    }

    /// What a code typed on the Mac matches.
    public enum Match: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
        CustomReflectable {
        case request(PairingRequest)
        case noMatch
        /// Pairing is closed, or this was the fifth wrong code.
        case closed

        public var description: String {
            switch self {
            case .request(let request): return request.description
            case .noMatch: return "no match"
            case .closed: return "closed"
            }
        }

        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["match": description]) }
    }

    public enum ApprovalError: Error, Equatable, Sendable {
        /// No waiting request has that id (it expired, was declined, or pairing closed it).
        case noRequest
        case pairingClosed
    }

    /// A token request's outcome.
    public enum TokenOutcome: Equatable, Sendable {
        /// Send it now. What it changed is applied already: a refusal, a revoke, a grace reuse.
        case answer(Answer)
        /// New tokens. Save `issuance.grant` with the grant store, then `apply` it, then send `issuance.answer`.
        /// If the save fails, send `serverError` and apply nothing: the old refresh token stays current and the
        /// new pair is never sent. Hold the authority's lock from `token` to `apply`.
        case issue(Issuance)
    }

    /// New tokens, not yet in force.
    public struct Issuance: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
        CustomReflectable {
        /// The grant as it is once applied: its new refresh hash, and its last use for a refresh.
        public let grant: Grant
        /// The token reply to send once applied.
        public let answer: Answer
        let access: String
        let refresh: String
        let accessExpires: Date
        let issued: Date
        /// The refresh hash the grant must still hold for this to apply.
        let expectedRefreshHash: String?
        /// The code it exchanges, which `apply` spends.
        let codeKey: String?
        /// A refresh that replaced a token: its pair is kept 60 seconds for a lost reply.
        let replacedHash: String?
        /// A grace reuse after a relaunch: the grace is spent once it applies.
        let graceUsed: Bool

        public var description: String { "new tokens for \(grant.id)" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["grant": grant.id, "answer": answer]) }
    }

    /// An access token's check.
    public enum Validation: Equatable, Sendable {
        /// The grant, with its options as they are now.
        case valid(Grant)
        /// No token was sent: 401 without an error.
        case missing
        /// Unknown, expired, revoked, or from another host: 401 with `error="invalid_token"`.
        case invalid
    }

    /// A client's revoke (RFC 7009): the answer, and the grants it ended, for the open-call registry.
    public struct Revocation: Equatable, Sendable {
        public let answer: Answer
        public let ended: [String]
    }

    /// Why a grant ended.
    public enum RevokeReason: String, Equatable, Sendable {
        /// Revoke on the Mac.
        case onMac = "on_mac"
        /// Revoke All, or Turn Off and Revoke All.
        case revokeAll = "revoke_all"
        /// A replaced refresh token was used again.
        case refreshReuse = "refresh_reuse"
        /// An authorization code was exchanged twice.
        case codeReuse = "code_reuse"
        /// The client revoked its own token.
        case client
        /// 14 days unused, or 90 in all.
        case expired
        /// The public hostname changed.
        case hostChanged = "host_changed"
    }

    /// Why pairing closed.
    public enum PairingClosed: String, Equatable, Sendable {
        case approved
        case onMac = "on_mac"
        case timedOut = "timed_out"
        case wrongCodes = "wrong_codes"
    }

    /// What the audit log records (R39). Tokens, codes and hashes never appear in one, and neither does a request
    /// id: a request appears by its `PairingRequest.logID`.
    public enum Event: Equatable, Sendable {
        case clientRegistered(clientID: String, clientName: String?, redirectHosts: [String])
        /// Values registration dropped or answered otherwise; `clientID` is nil when it was refused.
        case registrationDropped(clientID: String?, field: String, values: [String])
        case pairingOpened(until: Date)
        case pairingClosed(PairingClosed)
        case pairingAsked(request: String, clientID: String, clientName: String?, redirectHost: String)
        case pairingApproved(request: String, grantID: String, name: String, options: RemoteAccessOptions)
        case pairingDeclined(request: String, clientID: String)
        case pairingExpired(request: String, clientID: String)
        case optionsChanged(grantID: String, name: String, old: RemoteAccessOptions, new: RemoteAccessOptions)
        /// The Mac shows `reuseNotice(grantName:)`.
        case refreshReused(grantID: String, name: String)
        case codeReused(grantID: String, name: String)
        case revoked(grantID: String, name: String, reason: RevokeReason)
        /// Turned off: every access token was dropped, and the grants stay.
        case accessTokensDropped

        /// The event's name in an audit line.
        public var kind: String {
            switch self {
            case .clientRegistered: return "client.registered"
            case .registrationDropped: return "client.dropped_values"
            case .pairingOpened: return "pairing.opened"
            case .pairingClosed: return "pairing.closed"
            case .pairingAsked: return "pairing.asked"
            case .pairingApproved: return "pairing.approved"
            case .pairingDeclined: return "pairing.declined"
            case .pairingExpired: return "pairing.expired"
            case .optionsChanged: return "grant.options_changed"
            case .refreshReused: return "grant.refresh_reused"
            case .codeReused: return "grant.code_reused"
            case .revoked: return "grant.revoked"
            case .accessTokensDropped: return "tokens.dropped"
            }
        }
    }

    /// What the Mac shows when a replaced refresh token comes back and the grant ends (AE4).
    public static func reuseNotice(grantName: String) -> String {
        "A key for '\(grantName)' was used twice. Access was cut. Pair again on the Mac."
    }

    /// What the door sends when the grant store could not save new tokens.
    public static let serverError = failure(500, "server_error", "Next Term could not save the new key. Try again.")

    // MARK: state

    /// The public hostname, lowercased: the issuer and the resource are built from it.
    public private(set) var host: String
    public private(set) var clients: [Client]
    public private(set) var grants: [Grant]
    public private(set) var requests: [PairingRequest] = []
    /// When pairing closes; nil while it is closed.
    public private(set) var pairingEnds: Date?
    /// Audit events not yet taken.
    public private(set) var events: [Event] = []
    private var codes: [String: AuthorizationCode] = [:]
    private var accessTokens: [String: AccessToken] = [:]
    private var recentPairs: [String: RecentPair] = [:]
    private var registrationsOutside: [Date] = []
    private var registrationsInWindow = 0
    private var wrongCodes = 0
    private var listChanged: Set<String> = []
    private let random: @Sendable (Int) -> [UInt8]

    /// Random bytes from the system's secure generator.
    public static let systemRandom: @Sendable (Int) -> [UInt8] = { count in
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status != errSecSuccess else { return bytes }
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = generator.next() }
        return bytes
    }

    /// The authority for a hostname, with the clients and grants the grant store kept. A grant saved under
    /// another hostname ends here: a new hostname ends every grant (R17, KTD17). Each one ended emits a
    /// `revoked` event with `hostChanged`, so the app deletes it from the grant store.
    public init(host: String, clients: [Client] = [], grants: [Grant] = [],
                random: @escaping @Sendable (Int) -> [UInt8] = RemoteAccessOAuth.systemRandom) {
        let lowered = Self.asciiLowercased(host)
        self.host = lowered
        self.clients = clients
        self.grants = grants.filter { $0.host == lowered }
        self.random = random
        for grant in grants where grant.host != lowered {
            events.append(.revoked(grantID: grant.id, name: grant.name, reason: .hostChanged))
        }
    }

    /// `https://<host>`.
    public var issuer: String { "https://\(host)" }
    /// `https://<host>/mcp`.
    public var resource: String { "https://\(host)/mcp" }
    /// Where the protected resource metadata is, for the 401 challenge.
    public var resourceMetadataURL: String { "https://\(host)/.well-known/oauth-protected-resource/mcp" }

    /// The grant with this id, with its options as they are now.
    public func grant(_ id: String) -> Grant? {
        grants.first { $0.id == id }
    }

    /// Takes the audit events gathered since the last call.
    public mutating func takeEvents() -> [Event] {
        defer { events.removeAll() }
        return events
    }

    /// A new public hostname ends every grant and drops every token and request (R17, KTD17). Returns the
    /// grants it ended.
    @discardableResult
    public mutating func setHost(_ newHost: String, now: Date) -> [String] {
        let lowered = Self.asciiLowercased(newHost)
        guard lowered != host else { return [] }
        host = lowered
        let ended = grants.map(\.id)
        for id in ended { end(id, reason: .hostChanged, now: now) }
        accessTokens.removeAll()
        recentPairs.removeAll()
        codes.removeAll()
        requests.removeAll()
        return ended
    }

    // MARK: metadata

    /// The protected resource metadata (RFC 9728), at both of its paths.
    public func protectedResourceMetadata() -> Data {
        var document: [String: Any] = [:]
        document["resource"] = resource
        document["authorization_servers"] = [issuer]
        document["scopes_supported"] = [Self.observeScope, Self.controlScope]
        document["bearer_methods_supported"] = ["header"]
        return Self.json(document)
    }

    /// The authorization server metadata (RFC 8414). It lists a registration endpoint and no client metadata
    /// documents, so both vendors register (KTD6), and it says the redirect carries `iss`.
    public func authorizationServerMetadata() -> Data {
        var document: [String: Any] = [:]
        document["issuer"] = issuer
        document["authorization_endpoint"] = issuer + "/oauth/authorize"
        document["token_endpoint"] = issuer + "/oauth/token"
        document["registration_endpoint"] = issuer + "/oauth/register"
        document["revocation_endpoint"] = issuer + "/oauth/revoke"
        document["response_types_supported"] = ["code"]
        document["grant_types_supported"] = ["authorization_code", "refresh_token"]
        document["code_challenge_methods_supported"] = ["S256"]
        document["token_endpoint_auth_methods_supported"] = ["none"]
        document["revocation_endpoint_auth_methods_supported"] = ["none"]
        document["authorization_response_iss_parameter_supported"] = true
        document["scopes_supported"] = [Self.observeScope, Self.controlScope, "offline_access"]
        return Self.json(document)
    }

    /// The `WWW-Authenticate` value of a 401 from `/mcp`.
    public func wwwAuthenticate(tokenSent: Bool) -> String {
        let value = "Bearer resource_metadata=\"\(resourceMetadataURL)\""
        return tokenSent ? value + ", error=\"invalid_token\"" : value
    }

    // MARK: registration

    /// Registers a public client (RFC 7591). Only the two vendor callbacks are kept, and a registration with
    /// neither is refused. Any client authentication it asks for is answered with `none`. What it dropped goes
    /// to the audit log. 5 an hour while pairing is closed, 10 in one pairing window; every attempt counts,
    /// refused or not, and the limit is checked before the body is read.
    public mutating func register(_ body: Data, now: Date) -> Answer {
        prune(now)
        guard registrationAllowed(now) else {
            let text = "Too many apps tried to connect. On your Mac, open Next Term › Settings › Remote Access › Connect a Client, then try again."
            return Self.failure(429, "temporarily_unavailable", text)
        }
        if pairingIsOpen(now: now) {
            registrationsInWindow += 1
        } else {
            registrationsOutside.append(now)
        }
        let parsed = try? JSONSerialization.jsonObject(with: body)
        guard let metadata = parsed as? [String: Any] else {
            return Self.failure(400, "invalid_client_metadata", "The registration is not a JSON object.")
        }
        var kept: [String] = []
        var droppedURIs: [String] = []
        let uris = metadata["redirect_uris"]
        if let list = uris as? [Any] {
            for value in list {
                if let uri = value as? String, Self.redirectURIs.contains(uri) {
                    if !kept.contains(uri) { kept.append(uri) }
                } else if droppedURIs.count < Self.droppedValues {
                    droppedURIs.append(Self.shown(value))
                }
            }
        } else if let uris {
            // RFC 7591 asks for a list: one value on its own is dropped.
            droppedURIs.append(Self.shown(uris))
        }
        var dropped: [(String, [String])] = []
        if !droppedURIs.isEmpty { dropped.append(("redirect_uris", droppedURIs)) }
        if let method = metadata["token_endpoint_auth_method"], method as? String != "none" {
            dropped.append(("token_endpoint_auth_method", [Self.shown(method)]))
        }
        let grantTypes = Self.unsupported(metadata["grant_types"], ["authorization_code", "refresh_token"])
        if !grantTypes.isEmpty { dropped.append(("grant_types", grantTypes)) }
        let responseTypes = Self.unsupported(metadata["response_types"], ["code"])
        if !responseTypes.isEmpty { dropped.append(("response_types", responseTypes)) }

        guard !kept.isEmpty else {
            recordDropped(dropped, clientID: nil)
            return Self.failure(400, "invalid_redirect_uri", "Next Term pairs only with claude.ai and chatgpt.com.")
        }
        let name = Self.printable(metadata["client_name"] as? String, limit: Self.maximumClientName)
        let client = Client(id: newID(), name: name, redirectURIs: kept, registered: now, lastUsed: now)
        makeRoomForClient()
        clients.append(client)
        let hosts = kept.map(Self.host(of:))
        events.append(.clientRegistered(clientID: client.id, clientName: name, redirectHosts: hosts))
        recordDropped(dropped, clientID: client.id)

        var document: [String: Any] = [:]
        document["client_id"] = client.id
        document["client_id_issued_at"] = Int(now.timeIntervalSince1970)
        document["redirect_uris"] = kept
        document["token_endpoint_auth_method"] = "none"
        document["grant_types"] = ["authorization_code", "refresh_token"]
        document["response_types"] = ["code"]
        if let name { document["client_name"] = name }
        return Answer(status: 201, body: Self.json(document))
    }

    private func registrationAllowed(_ now: Date) -> Bool {
        if pairingIsOpen(now: now) { return registrationsInWindow < Self.registrationsPerWindow }
        let lastHour = registrationsOutside.filter { now.timeIntervalSince($0) < 3600 }
        return lastHour.count < Self.registrationsPerHour
    }

    /// Only clients without a grant count toward the 20 kept. When those are full, the oldest of them goes,
    /// unless a browser is waiting on it.
    private mutating func makeRoomForClient() {
        let granted = Set(grants.map(\.clientID))
        let waiting = Set(requests.filter(\.isWaiting).map(\.clientID))
        while clients.filter({ !granted.contains($0.id) }).count >= Self.maximumClientsWithoutGrant {
            let candidates = clients.filter { !granted.contains($0.id) && !waiting.contains($0.id) }
            guard let oldest = candidates.min(by: { $0.registered < $1.registered }) else { return }
            clients.removeAll { $0.id == oldest.id }
        }
    }

    /// The dropped values come as `shown(_:)` gives them, at most `droppedValues` for each field.
    private mutating func recordDropped(_ dropped: [(String, [String])], clientID: String?) {
        for (field, values) in dropped {
            events.append(.registrationDropped(clientID: clientID, field: field, values: values))
        }
    }

    // MARK: pairing on the Mac

    /// Connect a Client: pairing opens for 10 minutes. Requests that arrive never alert the Mac.
    public mutating func openPairing(now: Date) {
        prune(now)
        let ends = now.addingTimeInterval(Self.pairingWindow)
        pairingEnds = ends
        registrationsInWindow = 0
        wrongCodes = 0
        events.append(.pairingOpened(until: ends))
    }

    /// The pairing window closed on the Mac. Waiting requests get the closed page; nothing is declined.
    public mutating func closePairing(now: Date) {
        prune(now)
        guard pairingIsOpen(now: now) else { return }
        close(.onMac)
    }

    public func pairingIsOpen(now: Date) -> Bool {
        guard let pairingEnds else { return false }
        return now < pairingEnds
    }

    /// Requests waiting for their code.
    public func waitingCount(now: Date) -> Int {
        requests.filter { $0.isWaiting && now < $0.expires }.count
    }

    /// The request whose code was typed on the Mac. Each miss counts, and the fifth closes pairing.
    public mutating func match(code: String, now: Date) -> Match {
        prune(now)
        guard pairingIsOpen(now: now) else { return .closed }
        let typed = code.filter { !$0.isWhitespace }
        let found = requests.first { $0.isWaiting && IDELink.constantTimeEqual($0.code, typed) }
        if let found { return .request(found) }
        wrongCodes += 1
        guard wrongCodes >= Self.wrongCodeLimit else { return .noMatch }
        close(.wrongCodes)
        return .closed
    }

    /// Allow on the Mac, after Touch ID or the password: creates the grant with the name and options shown, and
    /// sends the browser back with a single-use code bound to its client, callback and PKCE challenge. Pairing
    /// then closes. It takes the request's id from `match`, not the code again, so the request approved is the
    /// one the window showed. An empty name becomes the suggested one.
    public mutating func approve(_ requestID: String, name: String, options: RemoteAccessOptions,
                                 now: Date) -> Result<Grant, ApprovalError> {
        prune(now)
        guard pairingIsOpen(now: now) else { return .failure(.pairingClosed) }
        guard let index = requests.firstIndex(where: { $0.id == requestID && $0.isWaiting }),
              clients.contains(where: { $0.id == requests[index].clientID }) else { return .failure(.noRequest) }
        let request = requests[index]
        let typed = Self.printable(name, limit: Self.maximumGrantName)
        let grant = Grant(id: newID(), name: typed ?? request.suggestedName, clientID: request.clientID,
                          clientName: request.clientName, redirectHost: request.redirectHost, options: options,
                          host: host, created: now, lastUsed: now)
        grants.append(grant)
        let code = newSecret()
        codes[Self.hash(code)] = AuthorizationCode(grantID: grant.id, clientID: request.clientID,
                                                  redirectURI: request.redirectURI,
                                                  redirectGiven: request.redirectGiven,
                                                  challenge: request.challenge, issued: now)
        let items = [("code", code), ("state", request.state), ("iss", issuer)]
        requests[index].outcome = .redirect(Self.link(request.redirectURI, items))
        events.append(.pairingApproved(request: request.logID, grantID: grant.id, name: grant.name, options: options))
        close(.approved)
        return .success(grant)
    }

    /// Decline on the Mac, or the window closed after a code matched: the browser goes back with
    /// `error=access_denied`.
    @discardableResult
    public mutating func decline(_ requestID: String, now: Date) -> Bool {
        prune(now)
        guard let index = requests.firstIndex(where: { $0.id == requestID && $0.isWaiting }) else { return false }
        let request = requests[index]
        let items = [("error", "access_denied"), ("state", request.state), ("iss", issuer)]
        requests[index].outcome = .redirect(Self.link(request.redirectURI, items))
        events.append(.pairingDeclined(request: request.logID, clientID: request.clientID))
        return true
    }

    private mutating func close(_ reason: PairingClosed) {
        pairingEnds = nil
        for index in requests.indices where requests[index].isWaiting {
            requests[index].outcome = .closed
        }
        events.append(.pairingClosed(reason))
    }

    // MARK: authorize

    /// The path the code page reloads to.
    public static func waitPath(for requestID: String) -> String {
        "/oauth/authorize/wait?request=" + encode(requestID)
    }

    /// `GET /oauth/authorize`, its query parsed by `parameters(_:)` (nil when a name repeats). A request that
    /// can't be trusted with a redirect (an unknown client, a callback it did not register) gets a page; later
    /// errors go back to the client with `error`, `state` and `iss`. `scope` is never read: the grant gets the
    /// options picked on the Mac. With pairing open, the request waits for its code to be typed there.
    public mutating func authorize(_ parameters: [String: String]?, now: Date) -> Authorization {
        prune(now)
        guard let parameters else { return .invalid("The request repeats a parameter.") }
        guard let clientID = parameters["client_id"],
              let clientIndex = clients.firstIndex(where: { $0.id == clientID }) else {
            return .invalid("This app is not registered with Next Term. Remove the connector and add it again.")
        }
        let client = clients[clientIndex]
        let given = parameters["redirect_uri"]
        let redirect: String
        if let given {
            guard client.redirectURIs.contains(given) else { return .invalid("The callback was not registered.") }
            redirect = given
        } else {
            guard client.redirectURIs.count == 1 else { return .invalid("The request has no callback.") }
            redirect = client.redirectURIs[0]
        }
        clients[clientIndex].lastUsed = now

        var state = parameters["state"]
        if let given = state, given.isEmpty || given.utf8.count > Self.maximumState { state = nil }
        guard parameters["response_type"] == "code" else {
            return errorRedirect(redirect, "unsupported_response_type", state: state)
        }
        guard let state else { return errorRedirect(redirect, "invalid_request", state: nil) }
        guard let challenge = parameters["code_challenge"], Self.isChallenge(challenge),
              parameters["code_challenge_method"] == "S256" else {
            return errorRedirect(redirect, "invalid_request", state: state)
        }
        guard isOwnResource(parameters["resource"]) else {
            return errorRedirect(redirect, "invalid_target", state: state)
        }
        guard pairingIsOpen(now: now) else { return .closed }
        guard waitingCount(now: now) < Self.maximumWaiting, let code = newCode() else { return .tooMany }
        let request = PairingRequest(id: newID(), code: code, clientID: client.id, clientName: client.name,
                                     redirectURI: redirect, created: now, redirectGiven: given != nil,
                                     challenge: challenge, state: state, outcome: .waiting)
        requests.append(request)
        events.append(.pairingAsked(request: request.logID, clientID: client.id, clientName: client.name,
                                    redirectHost: request.redirectHost))
        return .waiting(requestID: request.id, code: code)
    }

    /// `GET /oauth/authorize/wait`: the code page again, or where the browser goes now.
    public mutating func poll(_ requestID: String?, now: Date) -> Authorization {
        prune(now)
        guard let requestID, let request = requests.first(where: { $0.id == requestID }) else {
            return .invalid("This pairing request is not known. Start again from your Mac.")
        }
        switch request.outcome {
        case .waiting:
            return pairingIsOpen(now: now) ? .waiting(requestID: request.id, code: request.code) : .closed
        case .redirect(let link):
            return .redirect(link)
        case .closed:
            return .closed
        case .expired:
            return .expired
        }
    }

    private func errorRedirect(_ uri: String, _ error: String, state: String?) -> Authorization {
        var items = [("error", error)]
        if let state { items.append(("state", state)) }
        items.append(("iss", issuer))
        return .redirect(Self.link(uri, items))
    }

    /// Whether a `resource` names this door: the scheme and host compared without ASCII case, `:443` and one
    /// trailing slash dropped. A missing one means the door's own.
    public func isOwnResource(_ value: String?) -> Bool {
        guard let value else { return true }
        return Self.normalizedResource(value) == resource
    }

    // MARK: token

    /// `POST /oauth/token`, its form parsed by `parameters(body:)`. It answers from memory and never waits for
    /// the user (R13). Refusals answer 400 with an OAuth error; new tokens come back as an issuance to save.
    public mutating func token(_ parameters: [String: String]?, now: Date) -> TokenOutcome {
        prune(now)
        guard let parameters else { return .answer(Self.failure(400, "invalid_request", "A parameter is repeated.")) }
        guard isOwnResource(parameters["resource"]) else {
            return .answer(Self.failure(400, "invalid_target", "That is not this Next Term's address."))
        }
        switch parameters["grant_type"] {
        case "authorization_code":
            return exchange(parameters, now: now)
        case "refresh_token":
            return refresh(parameters, now: now)
        case nil:
            return .answer(Self.failure(400, "invalid_request", "grant_type is missing."))
        default:
            return .answer(Self.failure(400, "unsupported_grant_type"))
        }
    }

    private mutating func exchange(_ parameters: [String: String], now: Date) -> TokenOutcome {
        guard let code = parameters["code"], let verifier = parameters["code_verifier"],
              let clientID = parameters["client_id"] else {
            return .answer(Self.failure(400, "invalid_request", "code, code_verifier and client_id are needed."))
        }
        let key = Self.hash(code)
        guard let entry = codes[key] else { return .answer(Self.invalidGrant) }
        if entry.used {
            // A code exchanged twice: the grant it made ends (RFC 6749 4.1.2).
            if let grant = self.grant(entry.grantID) {
                events.append(.codeReused(grantID: grant.id, name: grant.name))
                end(grant.id, reason: .codeReuse, now: now)
            }
            return .answer(Self.invalidGrant)
        }
        // A failed check spends the code; a success spends it when it applies, so a failed save can be retried.
        let redirectMatches = parameters["redirect_uri"].map { $0 == entry.redirectURI } ?? !entry.redirectGiven
        let fits = now < entry.expires && entry.clientID == clientID && redirectMatches
        guard fits, Self.verifies(verifier, challenge: entry.challenge),
              let grant = self.grant(entry.grantID), grant.isActive(at: now) else {
            codes[key]?.used = true
            return .answer(Self.invalidGrant)
        }
        return .issue(issuance(for: grant, now: now, codeKey: key))
    }

    private mutating func refresh(_ parameters: [String: String], now: Date) -> TokenOutcome {
        guard let presented = parameters["refresh_token"] else {
            return .answer(Self.failure(400, "invalid_request", "refresh_token is missing."))
        }
        let key = Self.hash(presented)
        if let current = grants.first(where: { Self.same($0.refreshHash, key) }) {
            if let clientID = parameters["client_id"], clientID != current.clientID {
                return .answer(Self.invalidGrant)
            }
            var rotated = current
            rotated.rememberEarlier(current.replacedHash)
            rotated.replacedHash = key
            rotated.replacedAt = now
            rotated.lastUsed = now
            return .issue(issuance(for: rotated, now: now, replaced: key))
        }
        if let grant = grants.first(where: { $0.replacedEarlier(key) }) {
            return reused(grant, now: now)
        }
        guard let grant = grants.first(where: { Self.same($0.replacedHash, key) }) else {
            return .answer(Self.invalidGrant)
        }
        let recent = recentPairs[grant.id]
        let replacedAt = grant.replacedAt ?? .distantPast
        let inGrace = now.timeIntervalSince(replacedAt) < Self.refreshGrace && recent?.graceUsed != true
        if inGrace, let recent, recent.replacedHash == key {
            // A lost reply, or two refreshes at once: the same pair again, once.
            recentPairs[grant.id]?.graceUsed = true
            let left = Int(recent.accessExpires.timeIntervalSince(now))
            let answer = tokenAnswer(access: recent.access, refresh: recent.refresh, expiresIn: max(left, 0),
                                     options: grant.options)
            return .answer(answer)
        }
        if inGrace, recent == nil {
            // After a relaunch the pair is gone: a new one, which replaces the rotation's. The rotation's
            // refresh token is then a replaced one too, so if it comes back the grant ends and the Mac is told.
            var renewed = grant
            renewed.rememberEarlier(grant.refreshHash)
            renewed.lastUsed = now
            return .issue(issuance(for: renewed, now: now, replaced: key, graceUsed: true))
        }
        return reused(grant, now: now)
    }

    /// A replaced refresh token came back: the grant ends and the Mac shows `reuseNotice(grantName:)` (R16).
    private mutating func reused(_ grant: Grant, now: Date) -> TokenOutcome {
        events.append(.refreshReused(grantID: grant.id, name: grant.name))
        end(grant.id, reason: .refreshReuse, now: now)
        return .answer(Self.invalidGrant)
    }

    /// New tokens for a grant, as an issuance that changes nothing until it applies. The grant comes with its
    /// refresh hash as it is now, which `apply` expects to find.
    private func issuance(for grant: Grant, now: Date, codeKey: String? = nil, replaced: String? = nil,
                          graceUsed: Bool = false) -> Issuance {
        let access = Self.accessPrefix + Self.base64URL(random(32))
        let refresh = Self.refreshPrefix + Self.base64URL(random(32))
        var updated = grant
        updated.refreshHash = Self.hash(refresh)
        let lifetime = Self.accessTokenLifetime
        let answer = tokenAnswer(access: access, refresh: refresh, expiresIn: Int(lifetime), options: grant.options)
        return Issuance(grant: updated, answer: answer, access: access, refresh: refresh,
                        accessExpires: now.addingTimeInterval(lifetime), issued: now,
                        expectedRefreshHash: grant.refreshHash, codeKey: codeKey,
                        replacedHash: replaced, graceUsed: graceUsed)
    }

    /// Puts new tokens in force, once the grant store saved `issuance.grant`. False when the grant changed since
    /// (revoked, or another refresh came first): send `invalid_grant` instead of its answer.
    @discardableResult
    public mutating func apply(_ issuance: Issuance) -> Bool {
        let id = issuance.grant.id
        guard let index = grants.firstIndex(where: { $0.id == id }),
              grants[index].refreshHash == issuance.expectedRefreshHash else { return false }
        if let codeKey = issuance.codeKey {
            guard let code = codes[codeKey], !code.used else { return false }
            codes[codeKey]?.used = true
        }
        grants[index].refreshHash = issuance.grant.refreshHash
        grants[index].replacedHash = issuance.grant.replacedHash
        grants[index].replacedAt = issuance.grant.replacedAt
        grants[index].earlierHashes = issuance.grant.earlierHashes
        grants[index].lastUsed = max(grants[index].lastUsed, issuance.grant.lastUsed)
        let access = AccessToken(grantID: id, host: host, expires: issuance.accessExpires)
        accessTokens[Self.hash(issuance.access)] = access
        if let replaced = issuance.replacedHash {
            recentPairs[id] = RecentPair(access: issuance.access, refresh: issuance.refresh,
                                         accessExpires: issuance.accessExpires, replacedHash: replaced,
                                         issued: issuance.issued, graceUsed: issuance.graceUsed)
        }
        return true
    }

    private func tokenAnswer(access: String, refresh: String, expiresIn: Int, options: RemoteAccessOptions) -> Answer {
        var document: [String: Any] = [:]
        document["access_token"] = access
        document["token_type"] = "Bearer"
        document["expires_in"] = expiresIn
        document["refresh_token"] = refresh
        document["scope"] = Self.scope(for: options)
        return Answer(status: 200, body: Self.json(document))
    }

    static let invalidGrant = failure(400, "invalid_grant", "This key is not valid any more. Connect again.")

    // MARK: scope

    /// The `scope` a token reply carries: `nt.observe`, plus `nt.control` while the options admit a control
    /// tool. It is a word for the vendor's screen; the door enforces the options themselves.
    public static func scope(for options: RemoteAccessOptions) -> String {
        admitsControlTool(options) ? "\(observeScope) \(controlScope)" : observeScope
    }

    /// Whether these options admit a control tool: one that only options outside See admit and that is not
    /// marked read-only (R19). The Agents, Shells, Tabs and More tools options name no tool until the control
    /// options are built, and each will admit one, so until then each of them counts while it is on. Text and
    /// Keys admit no tool by themselves, Checks never do, and the Secrets options count only by the tools they
    /// name: they are a stub that admits nothing until the secret tools are in the base.
    static func admitsControlTool(_ options: RemoteAccessOptions, table: [MCPServer.Tool] = MCPServer.tools) -> Bool {
        let seeOptions = RemoteAccessOption.all.filter { $0.group == .see }
        let seeTools = Set(seeOptions.flatMap(\.tools))
        let actingTools = Set(table.filter { !$0.readOnly && !seeTools.contains($0.name) }.map(\.name))
        let namedLater: Set<RemoteAccessOption.Group> = [.agents, .shells, .tabs, .moreTools]
        for option in RemoteAccessOption.all where option.group != .see && options[option.id] {
            if option.tools.isEmpty, namedLater.contains(option.group) { return true }
            if option.tools.contains(where: actingTools.contains) { return true }
        }
        return false
    }

    // MARK: checks and revokes

    /// The token from an `Authorization: Bearer …` header, or nil.
    public static func bearer(_ authorization: String?) -> String? {
        guard let authorization else { return nil }
        let parts = authorization.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    /// An access token's check, by its hash: the grant with its current options, while the token has not
    /// expired, the grant is active, and both were issued under this host.
    public func validate(_ token: String?, now: Date) -> Validation {
        guard let token, !token.isEmpty else { return .missing }
        guard token.hasPrefix(Self.accessPrefix), let entry = accessTokens[Self.hash(token)],
              now < entry.expires, entry.host == host,
              let grant = self.grant(entry.grantID), grant.host == host, grant.isActive(at: now) else {
            return .invalid
        }
        return .valid(grant)
    }

    /// A tool call ran: the grant was used (R17).
    public mutating func noteUse(_ grantID: String, now: Date) {
        guard let index = grants.firstIndex(where: { $0.id == grantID }) else { return }
        grants[index].lastUsed = max(grants[index].lastUsed, now)
    }

    /// Replaces a grant's options. Only the app calls it, after Touch ID or the password on the Mac (R60). Its
    /// tokens keep working, the next validation returns the new options, and the door's next streamed call for
    /// the grant carries `notifications/tools/list_changed`. False for an unknown grant.
    @discardableResult
    public mutating func changeOptions(of grantID: String, to options: RemoteAccessOptions) -> Bool {
        guard let index = grants.firstIndex(where: { $0.id == grantID }) else { return false }
        let old = grants[index].options
        guard old != options else { return true }
        grants[index].options = options
        listChanged.insert(grantID)
        let name = grants[index].name
        events.append(.optionsChanged(grantID: grantID, name: name, old: old, new: options))
        return true
    }

    /// Whether the grant's tool list changed since the client last learned it, clearing the mark.
    public mutating func takeToolListChanged(_ grantID: String) -> Bool {
        listChanged.remove(grantID) != nil
    }

    /// Revoke on the Mac. False for an unknown grant.
    @discardableResult
    public mutating func revoke(grant grantID: String, reason: RevokeReason = .onMac, now: Date) -> Bool {
        guard grant(grantID) != nil else { return false }
        end(grantID, reason: reason, now: now)
        return true
    }

    /// Revoke All: every grant ends. Returns the grants it ended.
    @discardableResult
    public mutating func revokeAll(now: Date) -> [String] {
        let ended = grants.map(\.id)
        for id in ended { end(id, reason: .revokeAll, now: now) }
        accessTokens.removeAll()
        recentPairs.removeAll()
        codes.removeAll()
        return ended
    }

    /// `POST /oauth/revoke` (RFC 7009). A refresh token ends its grant; an access token ends only itself.
    /// A token of another client changes nothing. Always 200, unless no token was sent.
    public mutating func revoke(_ parameters: [String: String]?, now: Date) -> Revocation {
        prune(now)
        guard let token = parameters?["token"], !token.isEmpty else {
            return Revocation(answer: Self.failure(400, "invalid_request", "token is missing."), ended: [])
        }
        let done = Revocation(answer: Answer(status: 200, body: Data()), ended: [])
        let clientID = parameters?["client_id"]
        let key = Self.hash(token)
        if let entry = accessTokens[key] {
            let owner = grant(entry.grantID)?.clientID
            guard clientID == nil || clientID == owner else { return done }
            accessTokens.removeValue(forKey: key)
            return done
        }
        let found = grants.first { Self.same($0.refreshHash, key) || $0.replaced(key) }
        guard let grant = found, clientID == nil || clientID == grant.clientID else { return done }
        end(grant.id, reason: .client, now: now)
        return Revocation(answer: done.answer, ended: [grant.id])
    }

    /// Turned off, or quitting: every access token is dropped and the grants stay (R37).
    public mutating func dropAccessTokens() {
        accessTokens.removeAll()
        recentPairs.removeAll()
        events.append(.accessTokensDropped)
    }

    private mutating func end(_ grantID: String, reason: RevokeReason, now: Date) {
        guard let index = grants.firstIndex(where: { $0.id == grantID }) else { return }
        let grant = grants.remove(at: index)
        accessTokens = accessTokens.filter { $0.value.grantID != grantID }
        codes = codes.filter { $0.value.grantID != grantID }
        recentPairs.removeValue(forKey: grantID)
        listChanged.remove(grantID)
        // Its client stays a day, so the vendor can pair again with it.
        if let client = clients.firstIndex(where: { $0.id == grant.clientID }) {
            clients[client].lastUsed = max(clients[client].lastUsed, now)
        }
        events.append(.revoked(grantID: grantID, name: grant.name, reason: reason))
    }

    // MARK: housekeeping

    /// Ends what ran out: the pairing window, waiting requests, codes, access tokens, recent pairs, grants and
    /// unused clients. Every call that changes something runs it first.
    private mutating func prune(_ now: Date) {
        if let pairingEnds, now >= pairingEnds { close(.timedOut) }
        for index in requests.indices where requests[index].isWaiting && now >= requests[index].expires {
            requests[index].outcome = .expired
            let request = requests[index]
            events.append(.pairingExpired(request: request.logID, clientID: request.clientID))
        }
        requests.removeAll { now.timeIntervalSince($0.created) >= Self.requestMemory }
        codes = codes.filter { now.timeIntervalSince($0.value.issued) < Self.usedCodeMemory }
        accessTokens = accessTokens.filter { now < $0.value.expires }
        recentPairs = recentPairs.filter { now.timeIntervalSince($0.value.issued) < Self.refreshGrace }
        for grant in grants where !grant.isActive(at: now) {
            end(grant.id, reason: .expired, now: now)
        }
        let granted = Set(grants.map(\.clientID))
        let waiting = Set(requests.filter(\.isWaiting).map(\.clientID))
        clients.removeAll { client in
            let unused = now.timeIntervalSince(client.lastUsed) >= Self.clientUnusedLimit
            return unused && !granted.contains(client.id) && !waiting.contains(client.id)
        }
        registrationsOutside.removeAll { now.timeIntervalSince($0) >= 3600 }
    }

    // MARK: randomness

    /// 128 random bits as base64url: ids for clients, grants and requests.
    private func newID() -> String {
        Self.base64URL(random(16))
    }

    /// 256 random bits as base64url: authorization codes.
    private func newSecret() -> String {
        Self.base64URL(random(32))
    }

    /// Six uniform random digits that no waiting request holds, or nil if none turned up.
    private func newCode() -> String? {
        let taken = Set(requests.filter(\.isWaiting).map(\.code))
        // The largest multiple of a million below 2^32, so every code is as likely.
        let limit: UInt32 = 4_294_000_000
        for _ in 0..<100 {
            let bytes = random(4)
            let value = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard value < limit else { continue }
            let code = String(format: "%06u", value % 1_000_000)
            if !taken.contains(code) { return code }
        }
        return nil
    }

    // MARK: helpers

    /// SHA-256 of a token, in lowercase hex: how refresh tokens are stored and access tokens looked up.
    public static func hash(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Base64url without padding (RFC 4648 §5).
    static func base64URL(_ bytes: [UInt8]) -> String {
        let base64 = Data(bytes).base64EncodedString()
        let dashed = base64.replacingOccurrences(of: "+", with: "-")
        let underscored = dashed.replacingOccurrences(of: "/", with: "_")
        return underscored.replacingOccurrences(of: "=", with: "")
    }

    /// PKCE S256 (RFC 7636): base64url(SHA-256(verifier)) equals the challenge, compared in constant time.
    static func verifies(_ verifier: String, challenge: String) -> Bool {
        let bytes = Array(verifier.utf8)
        guard (43...128).contains(bytes.count), bytes.allSatisfy(isUnreserved) else { return false }
        let digest = SHA256.hash(data: Data(bytes))
        return IDELink.constantTimeEqual(base64URL(Array(digest)), challenge)
    }

    /// An S256 challenge: 43 base64url characters.
    static func isChallenge(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count == 43 && bytes.allSatisfy { isUnreserved($0) && $0 != 46 && $0 != 126 }
    }

    /// RFC 3986 unreserved: letters, digits, "-", ".", "_" and "~".
    static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122, 45, 46, 95, 126: return true
        default: return false
        }
    }

    /// Two hashes the same, in constant time; nil never matches.
    static func same(_ stored: String?, _ key: String) -> Bool {
        guard let stored else { return false }
        return IDELink.constantTimeEqual(stored, key)
    }

    /// A resource with its scheme and host in ASCII lowercase, `:443` and one trailing slash dropped.
    static func normalizedResource(_ value: String) -> String? {
        guard let separator = value.range(of: "://") else { return nil }
        let scheme = asciiLowercased(String(value[..<separator.lowerBound]))
        let rest = value[separator.upperBound...]
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        var authority = asciiLowercased(String(rest[..<slash]))
        var path = String(rest[slash...])
        if authority.hasSuffix(":443") { authority.removeLast(4) }
        if path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(authority)\(path)"
    }

    /// Only A to Z fold, so no Unicode case mapping makes another name match.
    static func asciiLowercased(_ text: String) -> String {
        let bytes = text.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func host(of uri: String) -> String {
        URLComponents(string: uri)?.host ?? uri
    }

    static func suggestedName(redirectHost: String) -> String {
        switch redirectHost {
        case "claude.ai": return "Claude"
        case "chatgpt.com": return "ChatGPT"
        default: return redirectHost
        }
    }

    /// Text with control, format, private-use and unassigned characters and line breaks removed, trimmed and
    /// cut to `limit` Unicode scalars in whole characters; nil when nothing is left.
    static func printable(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let hidden: Set<Unicode.GeneralCategory> = [
            .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator,
        ]
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !hidden.contains(scalar.properties.generalCategory) {
            scalars.append(scalar)
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespaces)
        let cut = prefix(trimmed, scalars: limit)
        return cut.isEmpty ? nil : cut
    }

    /// The whole characters at the start of `text` that hold at most `limit` Unicode scalars. Each mark stacked
    /// on a letter counts, so a name that looks short can't be long. The character that holds the scalar past
    /// the limit goes whole: a boundary depends only on what comes before it and on the scalar after it, so
    /// every boundary before that character is one in the full text too.
    static func prefix(_ text: String, scalars limit: Int) -> String {
        var head = String(text.unicodeScalars.prefix(limit + 1))
        guard head.unicodeScalars.count > limit else { return text }
        head.removeLast()
        return head
    }

    /// `text` cut to at most `limit` UTF-8 bytes, between Unicode scalars.
    static func prefix(_ text: String, bytes limit: Int) -> String {
        var used = 0
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            used += UTF8.width(scalar)
            guard used <= limit else { break }
            kept.append(scalar)
        }
        return String(kept)
    }

    /// A registration value for the audit log: text cut to `droppedValueLength` UTF-8 bytes, and anything else
    /// only by its JSON kind. A value from the network is never described, so a deeply nested one costs nothing.
    static func shown(_ value: Any) -> String {
        if let text = value as? String { return prefix(text, bytes: droppedValueLength) }
        if value is NSArray { return "(array)" }
        if value is NSDictionary { return "(object)" }
        if value is NSNull { return "(null)" }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "(boolean)" : "(number)"
        }
        return "(value)"
    }

    /// The values of a list field that are not in `supported`, at most `droppedValues`, as `shown(_:)` gives
    /// them. A value that is not a list is dropped whole.
    static func unsupported(_ value: Any?, _ supported: [String]) -> [String] {
        guard let value else { return [] }
        guard let list = value as? [Any] else { return [shown(value)] }
        var found: [String] = []
        for item in list {
            if let text = item as? String, supported.contains(text) { continue }
            found.append(shown(item))
            if found.count == droppedValues { break }
        }
        return found
    }

    /// A short hash of a pairing request's id: enough to follow a request through the audit log, and no help
    /// in fetching its redirect.
    static func logID(_ requestID: String) -> String {
        String(hash("pairing-request:" + requestID).prefix(16))
    }

    /// A callback with query items added.
    static func link(_ uri: String, _ items: [(String, String)]) -> String {
        let query = items.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&")
        let separator = uri.contains("?") ? "&" : "?"
        return uri + separator + query
    }

    /// Percent-encodes everything but the unreserved characters.
    static func encode(_ text: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// The parameters of a query or an `application/x-www-form-urlencoded` body: "+" is a space and "%XX" a
    /// byte. Nil when a name comes twice (RFC 6749 §3.1), an escape is bad, or the text is not UTF-8.
    public static func parameters(_ text: String?) -> [String: String]? {
        var result: [String: String] = [:]
        guard let text else { return result }
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = decode(parts[0]) else { return nil }
            let value = parts.count > 1 ? decode(parts[1]) : ""
            guard let value, result[name] == nil else { return nil }
            result[name] = value
        }
        return result
    }

    /// The parameters of a form body; nil when it is not UTF-8 or a name repeats.
    public static func parameters(body: Data) -> [String: String]? {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        return parameters(text)
    }

    private static func decode(_ text: Substring) -> String? {
        text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    static func failure(_ status: Int, _ error: String, _ description: String? = nil) -> Answer {
        var document: [String: Any] = ["error": error]
        if let description { document["error_description"] = description }
        return Answer(status: status, body: json(document))
    }

    static func json(_ document: [String: Any]) -> Data {
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        return (try? JSONSerialization.data(withJSONObject: document, options: options)) ?? Data("{}".utf8)
    }
}

extension RemoteAccessOAuth: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Counts only: the authority holds the last pair of tokens in the clear for 60 seconds, and request ids and
    /// codes while they wait.
    public var description: String {
        "OAuth for \(host): \(clients.count) clients, \(grants.count) grants, \(requests.count) requests"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        let children: KeyValuePairs<String, Any> = [
            "host": host, "clients": clients.count, "grants": grants.count, "requests": requests.count,
        ]
        return Mirror(self, children: children)
    }
}
