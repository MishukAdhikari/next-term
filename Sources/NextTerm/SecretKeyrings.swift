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
            throw Self.failure(error)
        }
        do {
            let secret = try key.sharedSecretFromKeyAgreement(with: ephemeral)
            return VaultKeyringSecret(secret: secret, publicKey: key.publicKey.x963Representation)
        } catch {
            throw Self.failure(error)
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

    /// What a failed open or key agreement means. An `LAError` that is a cancel is the user's, and any other `LAError`
    /// is LocalAuthentication's, which the next try may pass: neither marks Secrets can't open. A CryptoKit or Security
    /// error is a key that doesn't open on this Mac (another Mac's blob, a reset Secure Enclave), which does.
    static func failure(_ error: Error) -> SecretVault.Failure {
        guard error is LAError else { return .cantOpen }
        return UserPresence.failure(error) == .cancelled ? .cancelled : .keyUnavailable
    }
}

// MARK: the login keychain

/// One generic password item: a keychain vault's private key, or the recovery key a copy of the vault key in the
/// login keychain would be wrapped under. The self-test passes an in-memory store, so the keyring's rules are tested
/// without the login keychain.
protocol PasswordStore: AnyObject {
    /// The item's data. Called only after a presence check: macOS may ask for the login password first.
    func read() throws -> Data?
    /// Adds the item. One that is there already is an error and is never written over: it may be the only key that
    /// opens a vault.
    func add(_ data: Data) throws
    func delete() throws
    /// Whether the item is there: its attributes only, never its data. Nil when the keychain wouldn't say (locked and
    /// its unlock cancelled, or no interaction allowed): that is no sign the item is gone.
    func exists() -> Bool?
}

/// A generic password in the login keychain, by `SecItem` calls. The login keychain is a file, so data-protection
/// attributes such as `ThisDeviceOnly` don't apply to it.
final class LoginKeychain: PasswordStore {
    static let service = "Next Term Secrets"
    /// The one item earlier builds kept every keychain vault's key in. Read only to move the current vault's key to an
    /// item of its own; never written.
    static let sharedVaultKeyAccount = "vault key"
    static let recoveryAccount = "vault key recovery"
    /// Cancel or Deny at macOS's keychain prompt, or a keychain that can't ask just now: the user did not approve this
    /// time, and the next try may ask again.
    static let refusals: [OSStatus] = [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed]

    /// What a search's status says of the item: there, gone, or nil when the keychain refused to say.
    static func existence(_ status: OSStatus) -> Bool? {
        if status == errSecSuccess { return true }
        return refusals.contains(status) ? nil : false
    }

    /// A keychain vault's own item: named after its public key, so a new vault (after Start Over) never touches the
    /// item of the vault it replaced.
    static func vaultKeyAccount(publicKey: Data) -> String {
        let hash = SHA256.hash(data: publicKey).prefix(16).map { String(format: "%02x", $0) }.joined()
        return sharedVaultKeyAccount + " " + hash
    }

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

    func add(_ data: Data) throws {
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Next Term Secrets"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    func exists() -> Bool? {
        var request = query
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return Self.existence(SecItemCopyMatching(request as CFDictionary, &result))
    }
}

/// This Mac's record of the vaults Next Term made: one login-keychain item of Next Term's service, outside Secrets'
/// folder, with the vaults' bindings in its generic attribute. It is read as an attribute, never as data, so it needs
/// no keychain password after an update, as the keychain keyring's load check doesn't.
final class LoginKeychainRecord: VaultRecord {
    static let account = "vault bindings"

    let service: String
    let account: String

    init(service: String = LoginKeychain.service, account: String = LoginKeychainRecord.account) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read() throws -> Data? {
        var request = query
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Self.failure(status) }
        let attributes = result as? [String: Any]
        return attributes?[kSecAttrGeneric as String] as? Data ?? Data()
    }

    func write(_ data: Data) throws {
        let change = [kSecAttrGeneric as String: data]
        var status = SecItemUpdate(query as CFDictionary, change as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecAttrGeneric as String] = data
            item[kSecAttrLabel as String] = "Next Term Secrets"
            item[kSecValueData as String] = Data()
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Self.failure(status) }
    }

    /// A refused prompt is the user's cancel; any other failure, a record out of reach just now. Neither says the vault
    /// was tampered with.
    static func failure(_ status: OSStatus) -> SecretVault.Failure {
        LoginKeychain.refusals.contains(status) ? .cancelled : .keyUnavailable
    }
}

/// A `PasswordStore` in memory: the self-test's, which counts its reads and writes.
final class MemoryPasswordStore: PasswordStore {
    private var data: Data?
    private(set) var reads = 0
    /// The adds that wrote the item.
    private(set) var writes = 0
    private var failure: OSStatus?
    private var searchStatus: OSStatus?
    private let lock = NSLock()

    /// The status every read fails with, as the login keychain's do when the user cancels its prompt. Nil: reads work.
    var readFailure: OSStatus? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return failure
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            failure = newValue
        }
    }

    /// The status every search for the item fails with, as the login keychain's does when it is locked and the user
    /// cancels its unlock. Nil: searches work.
    var searchFailure: OSStatus? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return searchStatus
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            searchStatus = newValue
        }
    }

    func read() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        if let failure { throw LoginKeychain.Failure(status: failure) }
        return data
    }

    func add(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard self.data == nil else { throw LoginKeychain.Failure(status: errSecDuplicateItem) }
        writes += 1
        self.data = data
    }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        data = nil
    }

    func exists() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        if let searchStatus { return LoginKeychain.existence(searchStatus) }
        return data != nil
    }
}

/// In-memory items by account: the self-test's login keychain.
final class MemoryKeychain {
    private var items: [String: MemoryPasswordStore] = [:]
    private let lock = NSLock()

    /// The account's item, empty until something is added to it.
    func item(_ account: String) -> PasswordStore { store(account) }

    func store(_ account: String) -> MemoryPasswordStore {
        lock.lock()
        defer { lock.unlock() }
        if let found = items[account] { return found }
        let made = MemoryPasswordStore()
        items[account] = made
        return made
    }

    /// The accounts whose item is there, sorted.
    var accounts: [String] { all.filter { $0.value.exists() == true }.map(\.key).sorted() }
    var reads: Int { all.values.reduce(0) { $0 + $1.reads } }
    var writes: Int { all.values.reduce(0) { $0 + $1.writes } }

    private var all: [String: MemoryPasswordStore] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// On a Mac without a Secure Enclave: a software P256 key kept in the login keychain, read only after Next Term's own
/// presence check passed, never at launch. The gate is Next Term's code, not hardware, so Settings says "less
/// protected". Each vault's key is an item of its own, named after the vault's public key.
final class KeychainKeyring: VaultKeyring {
    /// The item of one account: the login keychain's, or the self-test's in memory.
    typealias Items = (String) -> PasswordStore

    let kind = VaultKeyringKind.keychain
    let keyBlob: Data? = nil
    private let items: Items
    /// The public key of the vault this keyring opens, which names its item.
    private let vaultPublicKey: Data
    /// The key made here, until the vault holding its public key is written.
    private var made: SoftwareKeyring?
    /// Runs on the thread that reads the item, just before: macOS may ask for the login password then.
    var willRead: (() -> Void)?

    /// The keyring of an existing vault, whose public key the vault records.
    init(publicKey: Data, items: @escaping Items) {
        self.vaultPublicKey = publicKey
        self.items = items
    }

    /// A new software key, added to an item of its own. An item that is there already is an error, never written over.
    static func make(items: @escaping Items) throws -> KeychainKeyring {
        let key = SoftwareKeyring(kind: .keychain)
        var raw = key.rawRepresentation
        defer { raw.resetBytes(in: raw.startIndex..<raw.endIndex) }
        try items(LoginKeychain.vaultKeyAccount(publicKey: key.publicKey())).add(raw)
        let keyring = KeychainKeyring(publicKey: key.publicKey(), items: items)
        keyring.made = key
        return keyring
    }

    func publicKey() throws -> Data {
        guard let made else { throw SecretVault.Failure.cantOpen } // read only with a presence check
        return made.publicKey()
    }

    /// Deletes the item `make` added, for a first add whose vault was never written, so no item is left that opens
    /// nothing. The keyring of an existing vault deletes nothing.
    func discard() {
        guard let made else { return }
        try? items(LoginKeychain.vaultKeyAccount(publicKey: made.publicKey())).delete()
        self.made = nil
    }

    /// The item of the vault this keyring opens, named after its public key.
    var ownItem: PasswordStore { items(LoginKeychain.vaultKeyAccount(publicKey: vaultPublicKey)) }

    /// The vault's item is there, or the shared item of earlier builds. Their data is never read for this. A keychain
    /// that wouldn't say (locked and its unlock cancelled) passes: only an item that is surely gone fails the check.
    func check(publicKey: Data) -> Bool {
        guard items(LoginKeychain.vaultKeyAccount(publicKey: publicKey)).exists() == false else { return true }
        return items(LoginKeychain.sharedVaultKeyAccount).exists() != false
    }

    func sharedSecret(with ephemeral: P256.KeyAgreement.PublicKey, context: AnyObject?) throws -> VaultKeyringSecret {
        guard context != nil else { throw SecretVault.Failure.cancelled }
        if let made { return try made.sharedSecret(with: ephemeral, context: context) }
        willRead?()
        let own = ownItem
        if let key = try Self.key(in: own) { return try key.sharedSecret(with: ephemeral, context: context) }
        // A vault from an earlier build, whose key is in the one shared item: that item opens this vault only when its
        // key is this vault's, and the key is then added to the vault's own item. The shared item is left as it is.
        guard let key = try Self.key(in: items(LoginKeychain.sharedVaultKeyAccount)), key.publicKey() == vaultPublicKey else {
            throw SecretVault.Failure.cantOpen
        }
        var raw = key.rawRepresentation
        defer { raw.resetBytes(in: raw.startIndex..<raw.endIndex) }
        try? own.add(raw)
        return try key.sharedSecret(with: ephemeral, context: context)
    }

    /// The key an item holds, or nil when the item is not there. An item that can't be read is not passed over for
    /// another. A read the user refused is `cancelled`, and any other failed read `keyUnavailable`: the next try may
    /// work, so neither marks Secrets can't open. Data that is no key is `cantOpen`, which does.
    private static func key(in item: PasswordStore) throws -> SoftwareKeyring? {
        let read: Data?
        do {
            read = try item.read()
        } catch {
            throw isRefused(error) ? SecretVault.Failure.cancelled : SecretVault.Failure.keyUnavailable
        }
        guard var raw = read else { return nil }
        defer { raw.resetBytes(in: raw.startIndex..<raw.endIndex) }
        guard let key = try? SoftwareKeyring(kind: .keychain, rawRepresentation: raw) else { throw SecretVault.Failure.cantOpen }
        return key
    }

    /// A read the user refused: one of `LoginKeychain.refusals`.
    static func isRefused(_ error: Error) -> Bool {
        guard let failure = error as? LoginKeychain.Failure else { return false }
        return LoginKeychain.refusals.contains(failure.status)
    }
}
