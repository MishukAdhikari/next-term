import CryptoKit
import Foundation

/// Next Term's sign-ins to remote MCP servers: `sign-ins.json` beside `vault.json` in Secrets' folder, sealed under a
/// key (`K`) that only the vault releases (its hidden `NEXT_TERM_SIGN_INS` entry, behind the Secure Enclave and
/// presence). A refresh token rotates while nobody is at the Mac, and every vault write asks for Touch ID, so the
/// tokens can't be vault entries; this file is the vault's companion instead, and holds no token in the clear.
///
/// - **Each record**: the server's resource, its authorization server's metadata, the client, a `generation` counted
///   up by each refresh, the agents the user allowed (R15), and its state. Its tokens are in `box`: AES-GCM under
///   HKDF(K, id), with the id, resource, issuer and client ID as associated data, so a box moved to another record
///   doesn't open.
/// - **Each registered client**, per issuer, its secret (when the server gave one) sealed the same way.
/// - **The whole body** is HMAC-SHA256'd under HKDF(K, "index"), checked over the bytes as stored, as vault.json's is.
///   An agent can read the file and finds no token; one that adds a consent, swaps records or changes a state breaks
///   the MAC, and Next Term reads the file as tampered: signed out, never granted.
/// - **Lenient**: members and states a later release adds are read past (an unknown state is a lapse).
public enum SignInFile {
    public static let name = "sign-ins.json"
    public static let lockName = "sign-ins.lock"
    public static let format = 1
    public static let maxSize = 2 * 1024 * 1024
    static let indexInfo = "nextterm sign-ins index/1"
    static let boxInfo = "nextterm sign-in/1"
    static let clientInfo = "nextterm sign-in client/1"

    public enum State: Equatable, Sendable, Codable {
        case signedIn
        /// A refresh was sent, or was about to be, with the refresh token whose SHA-256 this is: if this is still the
        /// state when the lock is next taken, its answer was lost, and that token is never sent again.
        case refreshing(spent: String)
        /// The sign-in lapsed at this generation: the user reconnects. The notice is shown once per lapse.
        case signedOut(lapse: Int)
        /// The server asked for more access (a 403 `insufficient_scope`): reconnect with these scopes.
        case needsMoreAccess([String])

        enum CodingKeys: String, CodingKey { case kind, spent, lapse, scopes }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try? container.decode(String.self, forKey: .kind) {
            case "signedIn"?: self = .signedIn
            case "refreshing"?: self = .refreshing(spent: (try? container.decode(String.self, forKey: .spent)) ?? "")
            case "needsMoreAccess"?: self = .needsMoreAccess((try? container.decode([String].self, forKey: .scopes)) ?? [])
            case "signedOut"?: self = .signedOut(lapse: (try? container.decode(Int.self, forKey: .lapse)) ?? 0)
            default: self = .signedOut(lapse: -1) // a state a later release added: signed out here
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .signedIn: try container.encode("signedIn", forKey: .kind)
            case .refreshing(let spent):
                try container.encode("refreshing", forKey: .kind)
                try container.encode(spent, forKey: .spent)
            case .signedOut(let lapse):
                try container.encode("signedOut", forKey: .kind)
                try container.encode(lapse, forKey: .lapse)
            case .needsMoreAccess(let scopes):
                try container.encode("needsMoreAccess", forKey: .kind)
                try container.encode(scopes, forKey: .scopes)
            }
        }
    }

    public struct Record: Codable, Equatable, Sendable {
        public let id: String
        /// The server's name when it was signed in to, for notices.
        public var name: String
        public var resource: String
        public var metadata: MCPHubOAuthDiscovery.Metadata
        public var client: MCPHubOAuthRegistration.Client
        public var generation: Int
        /// The agents the user allowed to use this sign-in (R15), lowercased: `claude`, `codex`.
        public var consents: [String]
        public var state: State
        /// The scopes asked for, and the ones the server granted (its token answer's `scope`).
        public var scopes: [String]
        public var granted: [String]?
        public var accessExpires: Date?
        /// How many times the server asked for more access with the same scopes, so Next Term stops offering at two.
        public var stepUps: Int?
        public var signedInAt: Date
        var box: Data

        public var issuer: String { metadata.issuer }
    }

    /// A registered client, its secret sealed.
    public struct Client: Codable, Equatable, Sendable {
        public var client: MCPHubOAuthRegistration.Client
        var secretBox: Data?
    }

    public struct Body: Codable, Equatable, Sendable {
        public var records: [Record]
        public var clients: [Client]

        public init(records: [Record] = [], clients: [Client] = []) {
            self.records = records
            self.clients = clients
        }

        public func record(id: String) -> Record? { records.first { $0.id == id } }
        public func record(resource: String) -> Record? { records.first { $0.resource == resource } }

        /// Registered clients, their secrets opened with `key`.
        public func registered(key: SymmetricKey) -> [MCPHubOAuthRegistration.Client] {
            clients.map { stored in
                var client = stored.client
                if let box = stored.secretBox { client.secret = SignInFile.openText(box, key: SignInFile.clientKey(key, issuer: client.issuer), data: SignInFile.clientData(client)) }
                return client
            }
        }

        /// Keeps `client` for its issuer, in place of any other for it: a registered one, or the user's own app (its
        /// secret copied here from Secrets, sealed, so a refresh needs no Touch ID).
        public mutating func keep(_ client: MCPHubOAuthRegistration.Client, key: SymmetricKey) throws {
            guard client.kind != .metadataDocument else { return }
            var stored = Client(client: client, secretBox: nil)
            stored.client.secret = nil
            if let secret = client.secret {
                stored.secretBox = try SignInFile.sealText(secret, key: SignInFile.clientKey(key, issuer: client.issuer), data: SignInFile.clientData(client))
            }
            clients.removeAll { $0.client.issuer == client.issuer && $0.client.kind == client.kind }
            clients.append(stored)
        }

        /// Forgets the registered client for `issuer` (the server said `invalid_client`): the next sign-in registers again.
        public mutating func forgetClient(issuer: String) { clients.removeAll { $0.client.issuer == issuer && $0.client.kind == .registered } }
    }

    /// The tokens a record's box holds.
    public struct Tokens: Equatable, Sendable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
        public var access: String
        public var refresh: String?

        public init(access: String, refresh: String?) {
            self.access = access
            self.refresh = refresh
        }

        public var description: String { "•••" }
        public var debugDescription: String { "•••" }
    }

    struct Outer: Codable {
        var format: Int
        var body: Data
        var mac: Data
    }

    public enum Failure: Error, Equatable {
        /// The MAC, a box or the file's shape is wrong: changed outside Next Term.
        case tampered
    }

    // MARK: reading and writing

    /// The body of `data` (nil: no file yet, an empty body), its MAC checked over the body's bytes as stored.
    public static func read(_ data: Data?, key: SymmetricKey) -> Result<Body, Failure> {
        guard let data else { return .success(Body()) }
        guard let outer = try? JSONDecoder().decode(Outer.self, from: data), outer.format >= 1,
              HMAC<SHA256>.isValidAuthenticationCode(outer.mac, authenticating: outer.body, using: indexKey(key)),
              let body = try? decoder.decode(Body.self, from: outer.body) else { return .failure(.tampered) }
        return .success(body)
    }

    public static func encode(_ body: Body, key: SymmetricKey) throws -> Data {
        let inner = try encoder.encode(body)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: inner, using: indexKey(key)))
        return try JSONEncoder().encode(Outer(format: format, body: inner, mac: mac))
    }

    /// A new record for a sign-in just made, its tokens sealed.
    public static func record(name: String, metadata: MCPHubOAuthDiscovery.Metadata, client: MCPHubOAuthRegistration.Client,
                              tokens: MCPHubOAuthFlow.Tokens, scopes: [String], key: SymmetricKey, now: Date = Date()) throws -> Record {
        var made = Record(id: UUID().uuidString.lowercased(), name: name, resource: metadata.resource, metadata: metadata, client: client,
                          generation: 1, consents: [], state: .signedIn, scopes: scopes, granted: tokens.scopes,
                          accessExpires: tokens.expires.map(whole), stepUps: nil, signedInAt: whole(now), box: Data())
        made.client.secret = nil
        try seal(Tokens(access: tokens.access, refresh: tokens.refresh), into: &made, key: key)
        return made
    }

    /// Seals `tokens` into the record's box.
    public static func seal(_ tokens: Tokens, into record: inout Record, key: SymmetricKey) throws {
        let json = try JSONEncoder().encode(tokens)
        record.box = try AES.GCM.seal(json, using: boxKey(key, id: record.id), authenticating: boxData(record)).combined ?? Data()
    }

    /// The record's tokens, or nil when its box doesn't open (moved from another record, or changed).
    public static func open(_ record: Record, key: SymmetricKey) -> Tokens? {
        guard let box = try? AES.GCM.SealedBox(combined: record.box),
              var json = try? AES.GCM.open(box, using: boxKey(key, id: record.id), authenticating: boxData(record)) else { return nil }
        defer { SecretBytes.wipe(&json) }
        return try? JSONDecoder().decode(Tokens.self, from: json)
    }

    // MARK: keys

    static func indexKey(_ key: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data(indexInfo.utf8), outputByteCount: 32)
    }

    static func boxKey(_ key: SymmetricKey, id: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data(id.utf8), info: Data(boxInfo.utf8), outputByteCount: 32)
    }

    static func clientKey(_ key: SymmetricKey, issuer: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data(issuer.utf8), info: Data(clientInfo.utf8), outputByteCount: 32)
    }

    /// The box's associated data: id, resource, issuer and client ID, each with its length.
    static func boxData(_ record: Record) -> Data {
        var data = Data()
        for field in [record.id, record.resource, record.metadata.issuer, record.client.clientID] {
            SecretVault.appendField(Data(field.utf8), to: &data)
        }
        return data
    }

    static func clientData(_ client: MCPHubOAuthRegistration.Client) -> Data {
        var data = Data()
        for field in [client.issuer, client.clientID] { SecretVault.appendField(Data(field.utf8), to: &data) }
        return data
    }

    static func sealText(_ text: String, key: SymmetricKey, data: Data) throws -> Data {
        try AES.GCM.seal(Data(text.utf8), using: key, authenticating: data).combined ?? Data()
    }

    static func openText(_ box: Data, key: SymmetricKey, data: Data) -> String? {
        guard let sealed = try? AES.GCM.SealedBox(combined: box), let plain = try? AES.GCM.open(sealed, using: key, authenticating: data) else {
            return nil
        }
        return String(data: plain, encoding: .utf8)
    }

    /// A date in whole seconds, as the file keeps it, so a record reads back equal.
    public static func whole(_ date: Date) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }

    /// A refresh token's SHA-256, hex: what `refreshing` keeps, never the token.
    public static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

/// The sign-ins as kept in Secrets' folder, with `K` in hand: reads, and changes made under `sign-ins.lock` (flock, so
/// another copy of Next Term waits), each one read again and written whole.
public final class SignInStore: @unchecked Sendable {
    public let folder: SecretFolder
    let key: SymmetricKey

    public init(folder: SecretFolder, key: SymmetricKey) {
        self.folder = folder
        self.key = key
    }

    /// The sign-ins now; `tampered` when the file was changed outside Next Term.
    public func read() -> Result<SignInFile.Body, SignInFile.Failure> {
        guard folder.exists else { return .success(SignInFile.Body()) }
        guard let data = try? folder.read(SignInFile.name, cap: SignInFile.maxSize) else { return .failure(.tampered) }
        return SignInFile.read(data, key: key)
    }

    /// `change` on the body under the lock, written when it returns true. A tampered file is started over empty only
    /// when `startsOver` (the user signing in again): otherwise it throws `tampered` and nothing is written.
    @discardableResult
    public func update<T>(startsOver: Bool = false, _ change: (inout SignInFile.Body) throws -> (write: Bool, value: T)) throws -> T {
        try folder.ensure()
        return try folder.withLock(SignInFile.lockName) {
            try locked(startsOver: startsOver, change)
        }
    }

    /// `update`'s work, for a caller already holding the lock.
    func locked<T>(startsOver: Bool = false, _ change: (inout SignInFile.Body) throws -> (write: Bool, value: T)) throws -> T {
        let current = try folder.read(SignInFile.name, cap: SignInFile.maxSize)
        var body: SignInFile.Body
        switch SignInFile.read(current, key: key) {
        case .success(let read): body = read
        case .failure(let failure):
            guard startsOver else { throw failure }
            body = SignInFile.Body()
        }
        let (write, value) = try change(&body)
        if write {
            try folder.write(SignInFile.name, data: try SignInFile.encode(body, key: key),
                             expecting: current.map { .contents($0) } ?? .noFile)
        }
        return value
    }

    /// Runs `body` holding `sign-ins.lock`.
    func withLock<T>(_ body: () throws -> T) throws -> T {
        try folder.ensure()
        return try folder.withLock(SignInFile.lockName, body)
    }

    /// The record's tokens.
    public func tokens(_ record: SignInFile.Record) -> SignInFile.Tokens? { SignInFile.open(record, key: key) }

    /// Adds a sign-in, in place of any other for its resource, keeping the consents the old one had; and keeps a
    /// registered client for its issuer.
    @discardableResult
    public func add(_ record: SignInFile.Record, client: MCPHubOAuthRegistration.Client) throws -> SignInFile.Record {
        try update(startsOver: true) { body in
            var made = record
            if let old = body.record(resource: record.resource) {
                made.consents = old.consents
                body.records.removeAll { $0.id == old.id }
            }
            body.records.append(made)
            try body.keep(client, key: key)
            return (true, made)
        }
    }

    /// Removes a sign-in; returns it (with its tokens, for revoking) when it was there.
    @discardableResult
    public func remove(id: String) throws -> (record: SignInFile.Record, tokens: SignInFile.Tokens?)? {
        try update { body in
            guard let found = body.record(id: id) else { return (false, nil) }
            body.records.removeAll { $0.id == id }
            return (true, (found, SignInFile.open(found, key: key)))
        }
    }

    /// The sign-in's consent for `agent` (lowercased) added or removed.
    public func setConsent(id: String, agent: String, allowed: Bool) throws {
        try update { body in
            guard let at = body.records.firstIndex(where: { $0.id == id }) else { return (false, ()) }
            let name = agent.lowercased()
            var consents = body.records[at].consents.filter { $0 != name }
            if allowed { consents.append(name) }
            guard consents != body.records[at].consents else { return (false, ()) }
            body.records[at].consents = consents
            return (true, ())
        }
    }

    /// The server asked for more access: the scopes it wants joined to the granted ones, and the state that asks the
    /// user to reconnect. False when it asked twice already for these scopes (the spec's retry limit).
    @discardableResult
    public func needsMoreAccess(id: String, scopes: [String]) throws -> Bool {
        try update { body in
            guard let at = body.records.firstIndex(where: { $0.id == id }) else { return (false, false) }
            var record = body.records[at]
            var wanted = record.granted ?? record.scopes
            for scope in scopes where !wanted.contains(scope) { wanted.append(scope) }
            if case .needsMoreAccess(let earlier) = record.state, earlier == wanted {
                record.stepUps = (record.stepUps ?? 1) + 1
            } else {
                record.stepUps = 1
            }
            record.state = .needsMoreAccess(wanted)
            body.records[at] = record
            return (true, (record.stepUps ?? 1) <= 2)
        }
    }

    /// Marks the sign-in signed out at its generation (a 401 after a refresh, or one refused at the server).
    public func signOut(id: String) throws {
        try update { body in
            guard let at = body.records.firstIndex(where: { $0.id == id }) else { return (false, ()) }
            if case .signedOut = body.records[at].state { return (false, ()) }
            body.records[at].state = .signedOut(lapse: body.records[at].generation)
            return (true, ())
        }
    }
}
