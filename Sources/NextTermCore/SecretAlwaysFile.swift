import CryptoKit
import Foundation

/// The Always approvals (SecretAlwaysGrants.swift): `always.json` beside `vault.json` in Secrets' folder, sealed as
/// `sign-ins.json` is, under a key only an unlock of the vault gives (`SecretVault.companionKey`), released once per
/// launch with Touch ID and held until Next Term quits.
///
/// - **The body** (every grant, and a `sequence` counted up by every write) is HMAC-SHA256'd under HKDF(K, "index"),
///   checked over the bytes as stored. A program that adds a grant, widens one or swaps two breaks the MAC: the file
///   reads as tampered, and nothing in it answers.
/// - **No older copy.** The vault's MAC'd index keeps a floor for this file (`SecretVault.Index.floors`), raised in the
///   Touch ID that makes or removes a grant: a body below it is an older copy put back, a removed grant with it, and
///   reads as tampered, after a relaunch too. A write between (a grant's last use) only counts up.
/// - **No file** is no grant: deleting it can only take approvals away.
public enum SecretAlwaysFile {
    public static let name = "always.json"
    public static let lockName = "always.lock"
    public static let format = 1
    public static let maxSize = 2 * 1024 * 1024
    /// `SecretVault.companionKey`'s info for this file's key.
    public static let keyInfo = "always"
    static let indexInfo = "nextterm always index/1"

    public struct Body: Codable, Equatable, Sendable {
        public var grants: [SecretAlwaysGrant]
        public var sequence: Int

        public init(grants: [SecretAlwaysGrant] = [], sequence: Int = 0) {
            self.grants = grants
            self.sequence = sequence
        }
    }

    struct Outer: Codable {
        var format: Int
        var body: Data
        var mac: Data
    }

    public enum Failure: Error, Equatable {
        /// The MAC or the shape is wrong, or the body is older than the vault's floor: changed outside Next Term.
        case tampered
    }

    /// The body of `data` (nil: no file, no grant), its MAC checked over the bytes as stored, and its sequence no lower
    /// than `floor`.
    public static func read(_ data: Data?, key: SymmetricKey, floor: Int) -> Result<Body, Failure> {
        guard let data else { return .success(Body(sequence: floor)) }
        guard let outer = try? JSONDecoder().decode(Outer.self, from: data), outer.format >= 1,
              HMAC<SHA256>.isValidAuthenticationCode(outer.mac, authenticating: outer.body, using: indexKey(key)),
              let body = try? decoder.decode(Body.self, from: outer.body), body.sequence >= floor,
              body.grants.count <= SecretAlwaysGrants.maxCount else { return .failure(.tampered) }
        return .success(body)
    }

    /// The body with no key and no MAC check, for Settings' list alone: nothing read here answers a request.
    public static func peek(_ data: Data?) -> Body? {
        guard let data, let outer = try? JSONDecoder().decode(Outer.self, from: data) else { return nil }
        return try? decoder.decode(Body.self, from: outer.body)
    }

    public static func encode(_ body: Body, key: SymmetricKey) throws -> Data {
        let inner = try encoder.encode(body)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: inner, using: indexKey(key)))
        return try JSONEncoder().encode(Outer(format: format, body: inner, mac: mac))
    }

    static func indexKey(_ key: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data(indexInfo.utf8), outputByteCount: 32)
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

/// The Always approvals as kept in Secrets' folder, with their key in hand and the vault's floor known: reads, and
/// changes made under `always.lock` (flock, so another copy of Next Term waits), each read again and written whole.
public final class SecretAlwaysStore: @unchecked Sendable {
    public let folder: SecretFolder
    let key: SymmetricKey
    /// The vault's floor as the unlock read it, raised by each change this launch made with the vault unlocked.
    public private(set) var floor: Int

    public init(folder: SecretFolder, key: SymmetricKey, floor: Int) {
        self.folder = folder
        self.key = key
        self.floor = floor
    }

    /// The grants now; `tampered` when the file was changed outside Next Term or is older than the floor.
    public func read() -> Result<SecretAlwaysFile.Body, SecretAlwaysFile.Failure> {
        guard folder.exists else { return .success(SecretAlwaysFile.Body(sequence: floor)) }
        guard let data = try? folder.read(SecretAlwaysFile.name, cap: SecretAlwaysFile.maxSize) else { return .failure(.tampered) }
        return SecretAlwaysFile.read(data, key: key, floor: floor)
    }

    /// `change` on the body under the lock, written when it returns true; the new sequence comes back with its value. A
    /// tampered file is started over empty only when `startsOver` (a grant the user makes in the panel's Touch ID, which
    /// then raises the floor past every copy): otherwise it throws `tampered` and nothing is written.
    @discardableResult
    public func update<T>(startsOver: Bool = false,
                          _ change: (inout SecretAlwaysFile.Body) throws -> (write: Bool, value: T)) throws -> (sequence: Int, value: T) {
        try folder.ensure()
        return try folder.withLock(SecretAlwaysFile.lockName) {
            let stored = try folder.read(SecretAlwaysFile.name, cap: SecretAlwaysFile.maxSize)
            var body: SecretAlwaysFile.Body
            switch SecretAlwaysFile.read(stored, key: key, floor: floor) {
            case .success(let read): body = read
            case .failure(let failure):
                guard startsOver else { throw failure }
                // Past any copy put back: the old file's sequence, when it can be read at all, and the floor.
                body = SecretAlwaysFile.Body(sequence: max(floor, SecretAlwaysFile.peek(stored)?.sequence ?? 0))
            }
            let (write, value) = try change(&body)
            if write {
                body.sequence += 1
                try folder.write(SecretAlwaysFile.name, data: try SecretAlwaysFile.encode(body, key: key),
                                 expecting: stored.map { .contents($0) } ?? .noFile)
            }
            return (body.sequence, value)
        }
    }

    /// The floor the vault now keeps, after a change raised it there.
    public func raised(to sequence: Int) {
        floor = max(floor, sequence)
    }
}
