import CryptoKit
import Foundation

// Secrets: this Mac's record of the vaults Next Term made, kept outside vault.json.
//
// Every check inside vault.json is keyed by the vault key the file itself wraps, and wrapping needs only a public key.
// So a whole vault built elsewhere, around a vault key of its maker's, wrapped under a key its maker holds or under this
// Mac's own public key, passes them all, and a value added to it would be sealed under a key its maker knows. Each vault
// key commits to a binding, which tells nothing of the key, and the record lists the bindings of the vaults Next Term made
// on this Mac. Before anything is sealed into a vault or released from it, its binding must be listed: one that isn't
// was not made by Next Term here, so it is tampered.
//
// The record is trusted as it reads, so the app keeps it where a program that only writes files can't: an item in the
// login keychain, its searches and adds pinned to that keychain. A program of the user's that can add login-keychain
// items can still forge it, by making the item where Next Term hasn't yet or, if macOS lets it with no prompt, by
// changing or replacing it. That program is not stopped here.

/// Where this Mac keeps the bindings of the vaults Next Term made, outside Secrets' folder. The app keeps them in an item
/// of its own in the login keychain; `MemoryVaultRecord` serves the tests and the self-test.
public protocol VaultRecord: AnyObject {
    /// The record's bytes, or nil when there is no record. Throws `SecretVault.Failure.cancelled` when the user refused
    /// a prompt, and `keyUnavailable` when it couldn't be read just now.
    func read() throws -> Data?
    /// Replaces the record's bytes. Throws as `read` does.
    func write(_ data: Data) throws
}

/// A record in memory, which counts its writes: the tests' and the self-test's, never the login keychain.
public final class MemoryVaultRecord: VaultRecord, @unchecked Sendable {
    private var data: Data?
    private var written = 0
    private var refusal: SecretVault.Failure?
    private let lock = NSLock()

    public init(_ contents: Data? = nil) {
        data = contents
    }

    public var contents: Data? { locked { data } }
    public var writes: Int { locked { written } }

    /// What every read and write throws, as a keychain the user refused or couldn't reach would. Nil: they work.
    public var failure: SecretVault.Failure? {
        get { locked { refusal } }
        set { locked { refusal = newValue } }
    }

    public func read() throws -> Data? {
        try locked {
            if let refusal { throw refusal }
            return data
        }
    }

    public func write(_ data: Data) throws {
        try locked {
            if let refusal { throw refusal }
            self.data = data
            written += 1
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

extension SecretVault {
    static let bindingInfo = "nextterm binding/1"
    /// How many vaults the record lists, newest last. Start Over then Add makes one more.
    public static let maxRecordedVaults = 64

    /// 32 bytes this vault's key commits to: HKDF-SHA256 of the vault key, info `nextterm binding/1`. They tell nothing
    /// of the key.
    public func binding() throws -> Data {
        Self.binding(of: try unlockedKey())
    }

    /// Before anything is sealed into this vault or released from it: throws `tampered` unless the record lists it, so a
    /// vault.json Next Term didn't make on this Mac (built around a vault key of someone else's) gets no value and gives
    /// none. No record at all throws `unlisted`: refused the same, but its text says the record is missing, since
    /// restoring the file wouldn't help. A record that can't be read throws its own failure.
    public func bind(to record: VaultRecord) throws {
        let own = try binding()
        guard let data = try record.read() else { throw Failure.unlisted }
        guard let listed = Self.bindings(in: data), listed.contains(own) else { throw Failure.tampered }
    }

    /// Lists this vault, just made, in the record, before its vault.json is written. The vaults made before stay listed,
    /// up to `maxRecordedVaults`; a record that is not a list of bindings is started again.
    public func record(in record: VaultRecord) throws {
        let own = try binding()
        var listed = try record.read().flatMap(Self.bindings(in:)) ?? []
        guard !listed.contains(own) else { return }
        listed.append(own)
        try record.write(Data(listed.suffix(Self.maxRecordedVaults).joined()))
    }

    static func binding(of vaultKey: SymmetricKey) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: vaultKey, info: Data(bindingInfo.utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    /// The record's bindings, or nil when it is not a list of 32-byte bindings.
    static func bindings(in data: Data) -> [Data]? {
        guard !data.isEmpty, data.count % 32 == 0 else { return nil }
        return stride(from: 0, to: data.count, by: 32).map { offset in
            let start = data.startIndex + offset
            return data.subdata(in: start..<start + 32)
        }
    }
}
