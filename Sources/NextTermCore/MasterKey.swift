import CommonCrypto
import CryptoKit
import Foundation

/// The master key: a passphrase the user sets once, before Remote access first turns on, and a recovery key shown
/// once beside it. Turning Remote access on, choosing Control, turning on an option that widens a connection,
/// showing the tunnel's token and changing the host name each need it, besides Touch ID. Stop and Revoke never do.
///
/// - Only verifiers are kept: PBKDF2-HMAC-SHA256 over the key with a random salt gives a derived key, and its
///   HMAC over a fixed label is what is stored. Neither the key nor the derived key is ever written.
/// - It is changed only by the user who knows it, or who holds the recovery key: `change(current:to:)` and
///   `recover(with:newKey:)`. There is no other way to replace it but `reset()`, which the app offers only beside
///   revoking every connection and forgetting the tunnel.
/// - Wrong tries are counted in the record: after `freeTries` each waits twice as long as the one before, from
///   `firstWait` seconds; after `tooManyTries` Remote access must turn off (`lockedOut`) until the right key is
///   typed on the Mac.
///
/// No MCP tool reaches this type: it is not in MCPServer's tables, and the app asks for the key only in its own
/// window. No key, guess or derived value ever goes into an error, a description or a log.
public struct MasterKeyRecord: Codable, Equatable, Sendable {
    /// The key's verifier.
    public var key: MasterKey.Verifier
    /// The recovery key's verifier.
    public var recovery: MasterKey.Verifier
    /// Wrong tries since the last right one, and when the last one was.
    public var wrongTries: Int
    public var lastWrong: Date?
    /// When the key was set or last changed.
    public var changed: Date

    public init(key: MasterKey.Verifier, recovery: MasterKey.Verifier, changed: Date) {
        self.key = key
        self.recovery = recovery
        self.wrongTries = 0
        self.lastWrong = nil
        self.changed = changed
    }
}

public enum MasterKey {
    /// PBKDF2's rounds. About half a second on Apple silicon: slow enough that a stolen record resists guessing.
    public static let defaultRounds: UInt32 = 1_200_000
    /// The shortest key accepted.
    public static let minimumLength = 12
    /// Tries without a wait, the first wait, and the try that turns Remote access off.
    public static let freeTries = 5
    public static let firstWait: TimeInterval = 30
    public static let tooManyTries = 10

    /// What is stored for one key: the salt, the rounds, and the HMAC of the derived key over `label`.
    public struct Verifier: Codable, Equatable, Sendable {
        public let salt: Data
        public let rounds: UInt32
        public let check: Data

        static let label = Data("Next Term master key v1".utf8)

        /// A verifier for `key`, with a fresh salt.
        public static func make(_ key: String, rounds: UInt32 = MasterKey.defaultRounds) -> Verifier {
            var salt = Data(count: 32)
            _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            return Verifier(salt: salt, rounds: rounds, check: check(key, salt: salt, rounds: rounds))
        }

        /// Whether `key` is the one this verifier was made from, compared in constant time.
        public func matches(_ key: String) -> Bool {
            let other = Self.check(key, salt: salt, rounds: rounds)
            guard other.count == check.count else { return false }
            return zip(other, check).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
        }

        static func check(_ key: String, salt: Data, rounds: UInt32) -> Data {
            let derived = SymmetricKey(data: pbkdf2(Array(key.precomposedStringWithCanonicalMapping.utf8), salt: salt, rounds: rounds))
            return Data(HMAC<SHA256>.authenticationCode(for: label, using: derived))
        }
    }

    /// Why a key can't be used as the master key.
    public enum Weakness: Equatable, Sendable {
        case tooShort
        case allOneCharacter
        case sameAsRecoveryKey
    }

    /// Why a new key is refused: nil when it can be set.
    public static func weakness(of key: String, recovery: String? = nil) -> Weakness? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < minimumLength { return .tooShort }
        if Set(trimmed).count == 1 { return .allOneCharacter }
        if let recovery, normalizedRecovery(trimmed) == normalizedRecovery(recovery) { return .sameAsRecoveryKey }
        return nil
    }

    /// A recovery key: 128 random bits as 8 groups of 4 characters from an alphabet without look-alikes
    /// ("K7QD-…"), shown once.
    public static func makeRecoveryKey() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") // 32 letters: no 0/O, 1/I
        var bytes = [UInt8](repeating: 0, count: 20)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // 20 bytes = 160 bits; 32 characters of 5 bits use them all.
        var bits = 0, value = 0
        var characters: [Character] = []
        for byte in bytes {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                characters.append(alphabet[(value >> bits) & 31])
            }
        }
        return stride(from: 0, to: characters.count, by: 4).map { String(characters[$0..<min($0 + 4, characters.count)]) }
            .joined(separator: "-")
    }

    /// The recovery key as typed: case, spaces and dashes don't matter.
    public static func normalizedRecovery(_ text: String) -> String {
        text.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// A record for a new key and its recovery key.
    public static func set(_ key: String, recovery: String, now: Date = Date(), rounds: UInt32 = defaultRounds) -> MasterKeyRecord {
        MasterKeyRecord(key: .make(key, rounds: rounds), recovery: .make(normalizedRecovery(recovery), rounds: rounds), changed: now)
    }

    /// What a try gets.
    public enum Outcome: Equatable, Sendable {
        case right
        case wrong(triesLeftBeforeWait: Int)
        /// Too soon after the last wrong try: nothing was checked.
        case wait(seconds: Int)
        /// Remote access must turn off; the right key, typed on the Mac, clears it.
        case lockedOut
    }

    /// How long the next try must wait after `record`'s wrong tries, at `now`.
    public static func waitLeft(_ record: MasterKeyRecord, now: Date = Date()) -> TimeInterval {
        guard record.wrongTries >= freeTries, let last = record.lastWrong else { return 0 }
        let wait = firstWait * pow(2, Double(record.wrongTries - freeTries))
        return max(0, last.addingTimeInterval(wait).timeIntervalSince(now))
    }

    /// Whether so many wrong tries were made that Remote access must stay off.
    public static func lockedOut(_ record: MasterKeyRecord) -> Bool { record.wrongTries >= tooManyTries }

    /// Checks `key` against `record`, counting a wrong try in it. `onMac`: the try was typed in Next Term's own
    /// window on the Mac, the only place a locked-out key can be cleared from.
    public static func attempt(_ key: String, record: inout MasterKeyRecord, onMac: Bool, now: Date = Date()) -> Outcome {
        if lockedOut(record), !onMac { return .lockedOut }
        let wait = waitLeft(record, now: now)
        if wait > 0 { return .wait(seconds: Int(wait.rounded(.up))) }
        if record.key.matches(key) {
            record.wrongTries = 0
            record.lastWrong = nil
            return .right
        }
        record.wrongTries += 1
        record.lastWrong = now
        if lockedOut(record) { return .lockedOut }
        return .wrong(triesLeftBeforeWait: max(0, freeTries - record.wrongTries))
    }

    /// Why a change was refused.
    public enum ChangeRefusal: Error, Equatable, Sendable {
        case wrongKey(Outcome)
        case weak(Weakness)
        case sameAsBefore
    }

    /// The key changed, given the current one: a new record, with a new recovery key when `newRecovery` is given
    /// (the old one stays otherwise). The caller ends every remote grant.
    public static func change(current: String, to newKey: String, newRecovery: String? = nil, record: inout MasterKeyRecord,
                              now: Date = Date(), rounds: UInt32 = defaultRounds) -> Result<MasterKeyRecord, ChangeRefusal> {
        let outcome = attempt(current, record: &record, onMac: true, now: now)
        guard outcome == .right else { return .failure(.wrongKey(outcome)) }
        return replace(with: newKey, newRecovery: newRecovery, record: record, now: now, rounds: rounds)
    }

    /// The key replaced by one who holds the recovery key. A new recovery key is required: the old one was used.
    public static func recover(with recoveryKey: String, newKey: String, newRecovery: String, record: inout MasterKeyRecord,
                               now: Date = Date(), rounds: UInt32 = defaultRounds) -> Result<MasterKeyRecord, ChangeRefusal> {
        let wait = waitLeft(record, now: now)
        if wait > 0 { return .failure(.wrongKey(.wait(seconds: Int(wait.rounded(.up))))) }
        guard record.recovery.matches(normalizedRecovery(recoveryKey)) else {
            record.wrongTries += 1
            record.lastWrong = now
            return .failure(.wrongKey(lockedOut(record) ? .lockedOut : .wrong(triesLeftBeforeWait: max(0, freeTries - record.wrongTries))))
        }
        return replace(with: newKey, newRecovery: newRecovery, record: record, now: now, rounds: rounds)
    }

    private static func replace(with newKey: String, newRecovery: String?, record: MasterKeyRecord, now: Date,
                                rounds: UInt32) -> Result<MasterKeyRecord, ChangeRefusal> {
        if let weak = weakness(of: newKey, recovery: newRecovery) { return .failure(.weak(weak)) }
        if record.key.matches(newKey) { return .failure(.sameAsBefore) }
        var next = MasterKeyRecord(key: .make(newKey, rounds: rounds), recovery: record.recovery, changed: now)
        if let newRecovery { next.recovery = .make(normalizedRecovery(newRecovery), rounds: rounds) }
        return .success(next)
    }

    static func pbkdf2(_ typed: [UInt8], salt: Data, rounds: UInt32) -> Data {
        // An empty try has no bytes to point at: it is read as one zero byte, which no key that can be set is.
        let password = typed.isEmpty ? [0] : typed
        var derived = [UInt8](repeating: 0, count: 32)
        salt.withUnsafeBytes { saltBytes in
            password.withUnsafeBufferPointer { passwordBytes in
                _ = passwordBytes.baseAddress!.withMemoryRebound(to: Int8.self, capacity: password.count) { pointer in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pointer, password.count,
                                         saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &derived, derived.count)
                }
            }
        }
        defer { for index in derived.indices { derived[index] = 0 } }
        return Data(derived)
    }
}

/// Where the master key's record lives: `master-key.json`, a `0600` file in Remote access's `0700` folder, written
/// whole and renamed into place as the grants file is. It holds verifiers and the wrong-try count, nothing else.
public struct MasterKeyStore: Sendable {
    public let url: URL

    public init(folder: URL = RemoteAccessStore.defaultFolder()) {
        url = folder.appendingPathComponent("master-key.json")
    }

    /// The record, or nil when no master key was set (or the file can't be read as one).
    public func load() -> MasterKeyRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MasterKeyRecord.self, from: data)
    }

    public func save(_ record: MasterKeyRecord) throws {
        try RemoteAccessStore.prepare(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try RemoteAccessStore.replace(url, with: try encoder.encode(record))
    }

    /// Forgets the master key: only beside revoking every connection and forgetting the tunnel (Reset Remote Access).
    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
