import CryptoKit
import Foundation
import LocalAuthentication
import NextTermCore
import Security

// The keyrings that guard Secrets' vault key. The vault's format and crypto are in Core (SecretVault.swift);
// these hold the private keys.

/// A P256 key in this Mac's Secure Enclave, made with user presence: every key agreement needs Touch ID or the Mac
/// password. Its `dataRepresentation` is a blob the vault stores as `keyBlob`, not a keychain item, so no entitlement
/// is needed. The blob opens only on the Mac that made it.
final class SecureEnclaveKeyring: VaultKeyring {
    let kind = VaultKeyringKind.secureEnclave
    private let blob: Data
    /// Known for a key made here; read from the blob otherwise.
    private var knownPublicKey: Data?

    /// Whether the load check opens the blob at launch. A hand check records whether opening it with interaction
    /// not allowed raises a prompt; if it does, this turns off and the first use finds a key that can't open.
    static let loadCheckOpensBlob = true

    static var isAvailable: Bool { SecureEnclave.isAvailable }

    /// The keyring of an existing vault.
    init(blob: Data) {
        self.blob = blob
    }

    private init(blob: Data, publicKey: Data) {
        self.blob = blob
        self.knownPublicKey = publicKey
    }

    /// A new Secure Enclave key, with the access control `UserPresence` evaluates.
    static func make() throws -> SecureEnclaveKeyring {
        guard let control = UserPresence.secureEnclaveAccessControl() else { throw SecretVault.Failure.cantOpen }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(compactRepresentable: false, accessControl: control,
                                                                  authenticationContext: nil)
        return SecureEnclaveKeyring(blob: key.dataRepresentation, publicKey: key.publicKey.x963Representation)
    }

    var keyBlob: Data? { blob }

    func publicKey() throws -> Data {
        if let knownPublicKey { return knownPublicKey }
        let key = try open(context: Self.quietContext())
        return key.publicKey.x963Representation
    }

    /// The load check, with no Touch ID: the key opened from its blob with no interaction allowed, its public key
    /// compared with the vault's. Making the key object and reading its public key need no presence; only the agreement
    /// is gated.
    func check(publicKey: Data) -> Bool {
        guard Self.loadCheckOpensBlob else { return true }
        guard let key = try? open(context: Self.quietContext()) else { return false }
        return key.publicKey.x963Representation == publicKey
    }

    func sharedSecret(with ephemeral: P256.KeyAgreement.PublicKey, context: AnyObject?) throws -> VaultKeyringSecret {
        guard let context = context as? LAContext else { throw SecretVault.Failure.cancelled }
        let key: SecureEnclave.P256.KeyAgreement.PrivateKey
        do {
            key = try open(context: context)
        } catch {
            throw Self.isCancel(error) ? SecretVault.Failure.cancelled : SecretVault.Failure.cantOpen
        }
        do {
            let secret = try key.sharedSecretFromKeyAgreement(with: ephemeral)
            return VaultKeyringSecret(secret: secret, publicKey: key.publicKey.x963Representation)
        } catch {
            throw Self.isCancel(error) ? SecretVault.Failure.cancelled : SecretVault.Failure.cantOpen
        }
    }

    private func open(context: LAContext) throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob, authenticationContext: context)
    }

    private static func quietContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private static func isCancel(_ error: Error) -> Bool {
        UserPresence.failure(error) == .cancelled && error is LAError
    }
}

// MARK: the login keychain

/// One generic password item: the keychain keyring's private key, or the recovery key a copy of the vault key in the
/// login keychain would be wrapped under. The self-test passes an in-memory store, so the keyring's rules are tested
/// without the login keychain.
protocol PasswordStore: AnyObject {
    /// The item's data. Called only after a presence check: macOS may ask for the login password first.
    func read() throws -> Data?
    func write(_ data: Data) throws
    func delete() throws
    /// Whether the item is there: its attributes only, never its data.
    func exists() -> Bool
}

/// A generic password in the login keychain, by `SecItem` calls. The login keychain is a file, so data-protection
/// attributes such as `ThisDeviceOnly` don't apply to it.
final class LoginKeychain: PasswordStore {
    static let service = "Next Term Secrets"
    static let vaultKeyAccount = "vault key"
    static let recoveryAccount = "vault key recovery"

    let service: String
    let account: String

    struct Failure: Error, Equatable, LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "The login keychain refused (\(status))."
        }
    }

    init(service: String = LoginKeychain.service, account: String) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return result as? Data
    }

    func write(_ data: Data) throws {
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Next Term Secrets"
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw Failure(status: update) }
            return
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    func exists() -> Bool {
        var request = query
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess
    }
}

/// A `PasswordStore` in memory: the self-test's, which counts its reads and writes.
final class MemoryPasswordStore: PasswordStore {
    private var data: Data?
    private(set) var reads = 0
    private(set) var writes = 0
    private let lock = NSLock()

    func read() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return data
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        writes += 1
        self.data = data
    }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        data = nil
    }

    func exists() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return data != nil
    }
}

/// On a Mac without a Secure Enclave: a software P256 key kept in the login keychain, read only after Next Term's own
/// presence check passed, never at launch. The gate is Next Term's code, not hardware, so Settings says "less
/// protected".
final class KeychainKeyring: VaultKeyring {
    let kind = VaultKeyringKind.keychain
    let keyBlob: Data? = nil
    private let store: PasswordStore
    /// The key made here, until the vault holding its public key is written.
    private var made: SoftwareKeyring?
    /// Runs on the thread that reads the item, just before: macOS may ask for the login password then.
    var willRead: (() -> Void)?

    init(store: PasswordStore) {
        self.store = store
    }

    /// A new software key, written to the store once.
    static func make(store: PasswordStore) throws -> KeychainKeyring {
        let key = SoftwareKeyring(kind: .keychain)
        var raw = key.rawRepresentation
        defer { raw.resetBytes(in: raw.startIndex..<raw.endIndex) }
        try store.write(raw)
        let keyring = KeychainKeyring(store: store)
        keyring.made = key
        return keyring
    }

    func publicKey() throws -> Data {
        guard let made else { throw SecretVault.Failure.cantOpen } // read only with a presence check
        return made.publicKey()
    }

    /// The item is there. Its data is never read for this.
    func check(publicKey: Data) -> Bool {
        store.exists()
    }

    func sharedSecret(with ephemeral: P256.KeyAgreement.PublicKey, context: AnyObject?) throws -> VaultKeyringSecret {
        guard context != nil else { throw SecretVault.Failure.cancelled }
        if let made { return try made.sharedSecret(with: ephemeral, context: context) }
        willRead?()
        guard var raw = try? store.read() else { throw SecretVault.Failure.cantOpen }
        defer { raw.resetBytes(in: raw.startIndex..<raw.endIndex) }
        guard let key = try? SoftwareKeyring(kind: .keychain, rawRepresentation: raw) else { throw SecretVault.Failure.cantOpen }
        return try key.sharedSecret(with: ephemeral, context: context)
    }
}
