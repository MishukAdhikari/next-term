import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Secrets: the vault's format and crypto. The app owns the keyrings, Touch ID and the UI; this file owns what is
// on disk and what seals it.
//
// - A random 256-bit vault key seals everything. A keyring (the Secure Enclave, or a software key in the login
//   keychain) guards it: an ephemeral P256 key agrees with the keyring's public key, HKDF-SHA256 gives a wrap key,
//   and AES-GCM seals the vault key with it. Unwrapping needs the keyring's private key, which on the Secure Enclave
//   is the step the hardware gates behind Touch ID or the Mac password.
// - Each value is sealed with AES-GCM under a key derived from the vault key and the entry's id. Its associated data
//   holds the id, the name, the write-only flag and the origin, so changing any of them in the file breaks the seal.
// - The index (names, what each key is for, flags, dates) is authenticated with HMAC-SHA256 over the body's exact
//   bytes as stored. Verification never encodes again, so a change in Foundation's encoder never breaks a vault.
//
// No value ever goes into an error, a description or a log: errors carry names only.

// MARK: values

/// A key's value while Next Term holds it: bytes wiped with `memset_s` when the last reference goes. It prints as
/// "•••" (`description`, `debugDescription`, `dump`), and it is not `Codable`, so it can't be encoded by accident.
/// What it was made from (a `String`, a `Data`) is the caller's to wipe or drop.
public final class SecretBytes: @unchecked Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible,
                                CustomReflectable {
    private var bytes: [UInt8]

    public init(_ bytes: [UInt8]) { self.bytes = bytes }
    public convenience init(_ data: Data) { self.init([UInt8](data)) }
    public convenience init(utf8 text: String) { self.init(Array(text.utf8)) }

    /// Takes `data`'s bytes and wipes `data`: for a value CryptoKit hands back as `Data`.
    convenience init(consuming data: inout Data) {
        self.init([UInt8](data))
        Self.wipe(&data)
    }

    deinit { Self.wipe(&bytes) }

    public var count: Int { bytes.count }
    public var isEmpty: Bool { bytes.isEmpty }

    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try bytes.withUnsafeBytes(body)
    }

    /// The value as text: for the few places that need one (a command's environment, Reveal). A `String` can't be
    /// wiped, so the caller keeps it no longer than it must. Nil when the bytes are not UTF-8.
    public func utf8String() -> String? {
        String(bytes: bytes, encoding: .utf8)
    }

    /// The bytes compared in time that does not depend on where they differ.
    public static func == (a: SecretBytes, b: SecretBytes) -> Bool {
        guard a.bytes.count == b.bytes.count else { return false }
        var difference: UInt8 = 0
        for index in a.bytes.indices { difference |= a.bytes[index] ^ b.bytes[index] }
        return difference == 0
    }

    public var description: String { "•••" }
    public var debugDescription: String { "•••" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .class) }

    /// Overwrites bytes that held a value with zeros (`memset_s`, which the compiler can't drop).
    public static func wipe(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return }
            _ = memset_s(base, buffer.count, 0, buffer.count)
        }
    }

    public static func wipe(_ data: inout Data) {
        data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return }
            _ = memset_s(base, buffer.count, 0, buffer.count)
        }
    }
}

// MARK: names

/// A key's name: capital letters, digits and underscores, starting with a letter, at most 64 characters. ASCII only,
/// so a look-alike letter can't pose as another key.
public enum StoredSecretName {
    public static let maxLength = 64
    public static let rule = "Capital letters, digits and _, starting with a letter."

    public static func isValid(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard let first = bytes.first, bytes.count <= maxLength, isLetter(first) else { return false }
        return bytes.allSatisfy { isLetter($0) || isDigit($0) || $0 == UInt8(ascii: "_") }
    }

    /// A name made from a variable's name or what the user typed: uppercased, with other characters made `_`, and
    /// `KEY_` in front when it would not start with a letter. "github-token" is GITHUB_TOKEN, "2fa" is KEY_2FA.
    public static func suggested(from text: String) -> String {
        let mapped = text.uppercased().unicodeScalars.map { scalar -> Character in
            let value = scalar.value
            let isAllowed = (65...90).contains(value) || (48...57).contains(value) || value == 95
            return isAllowed ? Character(scalar) : "_"
        }
        var name = String(mapped)
        while name.hasPrefix("_") { name.removeFirst() }
        while name.hasSuffix("_") { name.removeLast() }
        if name.isEmpty { return "KEY" }
        if let first = name.utf8.first, !isLetter(first) { name = "KEY_" + name }
        return String(name.prefix(maxLength))
    }

    /// Environment names a key is never given as: ones that change how a shell, a dynamic linker or an interpreter
    /// runs the command, or what Next Term and git read.
    public static let refusedEnvNames: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "PWD", "OLDPWD", "IFS", "PS1", "PS2", "PS4",
        "PROMPT_COMMAND", "TERM", "LANG", "LC_ALL", "ENV", "BASH_ENV", "ZDOTDIR", "NODE_OPTIONS", "NODE_PATH",
        "PYTHONPATH", "PYTHONSTARTUP", "PYTHONHOME", "PERL5OPT", "PERL5LIB", "RUBYOPT", "RUBYLIB", "LD_PRELOAD",
        "LD_LIBRARY_PATH", "GCONV_PATH", "ELECTRON_RUN_AS_NODE",
    ]
    public static let refusedEnvPrefixes = ["DYLD_", "GIT_", "NEXTTERM_"]

    public static func isRefusedEnvName(_ name: String) -> Bool {
        refusedEnvNames.contains(name) || refusedEnvPrefixes.contains { name.hasPrefix($0) }
    }

    /// What a key is for, from an agent's reason: one line, its line breaks and control characters made spaces,
    /// and over 200 characters cut at the last space before the 200th character, with "…" added.
    public static func purpose(fromReason reason: String) -> String {
        let scalars = reason.unicodeScalars.map { scalar -> Unicode.Scalar in
            let category = scalar.properties.generalCategory
            let isBreak = category == .control || category == .lineSeparator || category == .paragraphSeparator
            return isBreak ? " " : scalar
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        let line = String(view).trimmingCharacters(in: .whitespaces)
        let limit = SecretVault.maxPurposeLength
        guard line.count > limit else { return line }
        let head = line.prefix(limit - 1)
        let cut = head.lastIndex(of: " ").map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    static func isLetter(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") }
    static func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }
}

// MARK: keyrings

/// What guards the vault key.
public enum VaultKeyringKind: String, Codable, Sendable {
    /// A P256 key in the Secure Enclave, with user presence: its blob opens only on the Mac that made it.
    case secureEnclave = "secure-enclave"
    /// A software P256 key kept in the login keychain, read only after Next Term's own Touch ID check: less protected.
    case keychain
}

/// The keyring's side of an unwrap: the shared secret, and the public key of the private key that made it.
public struct VaultKeyringSecret {
    public let secret: SharedSecret
    /// The opened key's public key, x963. A key whose public key differs from the vault's is not the vault's key.
    public let publicKey: Data

    public init(secret: SharedSecret, publicKey: Data) {
        self.secret = secret
        self.publicKey = publicKey
    }
}

/// A P256 key-agreement key that guards the vault key. The app supplies the Secure Enclave and keychain keyrings;
/// `SoftwareKeyring` serves the tests and the self-test.
public protocol VaultKeyring: AnyObject {
    var kind: VaultKeyringKind { get }
    /// What the vault stores as `keyBlob`: the Secure Enclave key's `dataRepresentation`. Nil for other keyrings.
    var keyBlob: Data? { get }
    /// The public key, x963, of a key this keyring has made or holds. Wrapping uses it, with no presence.
    func publicKey() throws -> Data
    /// The load check, which needs no presence: whether this keyring's key is the one whose public key the vault
    /// records. The keychain keyring can only say whether its item is there.
    func check(publicKey: Data) -> Bool
    /// The shared secret with `ephemeral`. `context` is the presence the app evaluated (an `LAContext`); on the Secure
    /// Enclave this is the step the hardware gates. Throws `SecretVault.Failure.cancelled` when the user did not
    /// approve, and `cantOpen` (or any other error) when the key can't be opened.
    func sharedSecret(with ephemeral: P256.KeyAgreement.PublicKey, context: AnyObject?) throws -> VaultKeyringSecret
}

/// A software P256 key held in memory: for the tests and the self-test, and the key the keychain keyring keeps.
public final class SoftwareKeyring: VaultKeyring {
    public let kind: VaultKeyringKind
    let key: P256.KeyAgreement.PrivateKey
    private let lock = NSLock()
    private var agreements = 0

    public init(kind: VaultKeyringKind = .keychain, key: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey()) {
        self.kind = kind
        self.key = key
    }

    /// The key from its `rawRepresentation`, as the keychain keyring stores it.
    public convenience init(kind: VaultKeyringKind = .keychain, rawRepresentation: Data) throws {
        self.init(kind: kind, key: try P256.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation))
    }

    /// The private key's bytes, for the keychain keyring to store. Wiped by the caller.
    public var rawRepresentation: Data { key.rawRepresentation }
    public var keyBlob: Data? { nil }
    public func publicKey() -> Data { key.publicKey.x963Representation }
    public func check(publicKey: Data) -> Bool { publicKey == self.publicKey() }

    /// How many key agreements it made: the self-test checks that a load check made none.
    public var agreementCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return agreements
    }

    public func sharedSecret(with ephemeral: P256.KeyAgreement.PublicKey, context: AnyObject?) throws -> VaultKeyringSecret {
        lock.lock()
        agreements += 1
        lock.unlock()
        let secret = try key.sharedSecretFromKeyAgreement(with: ephemeral)
        return VaultKeyringSecret(secret: secret, publicKey: publicKey())
    }
}

// MARK: the vault

/// `vault.json`, unlocked or not: `{"format": 1, "body": "<base64 of the body's UTF-8 JSON>", "mac": "<base64>"}`.
/// The body (`Index`) holds the keyring's facts, the wrapped vault key, and each entry with its sealed value.
///
/// Use: `index(from:)` reads the names and marks with no key (lists, masking at launch). `create(keyring:)` makes a
/// new vault; `unlock(_:keyring:context:)` opens one after the app's presence check. The changes each return the new
/// file's bytes, which the caller writes. `wipe()` drops the vault key, which the caller does as soon as it is done.
/// The vault key and the entry keys are CryptoKit `SymmetricKey` values; Apple documents nothing about wiping their
/// memory, so nothing is claimed about it.
public final class SecretVault {
    public static let format = 1
    public static let maxEntries = 500
    public static let maxValueBytes = 16 * 1024
    public static let maxPurposeLength = 200
    public static let maxFileSize = 8 * 1024 * 1024
    /// The length of `mask.key`.
    public static let maskKeyLength = 32
    /// The length of the recovery key, for a copy of the vault key in the login keychain.
    public static let recoveryKeyLength = 32

    static let wrapSalt = Data("NextTerm Secrets wrap 1".utf8)
    static let wrapLabel = "nextterm-wrap/1"
    static let recoveryLabel = "recovery"
    static let secretLabel = "nextterm-secret/1"
    static let entryInfo = "nextterm entry/1"
    static let indexInfo = "nextterm index/1"
    static let importInfo = "nextterm import/1"
    static let recoveryInfo = "nextterm recovery/1"

    /// Why nothing was released or changed. Each carries names only, never a value.
    public enum Failure: Error, Equatable, LocalizedError {
        /// The index's MAC, a seal, or the file's shape is wrong: it was changed outside Next Term.
        case tampered
        /// The keyring can't open the vault: another Mac's key, a reset Secure Enclave, a missing keychain item.
        case cantOpen
        /// The user did not approve.
        case cancelled
        /// The vault key was dropped (`wipe()`).
        case locked
        /// `vault.json` is over its size cap.
        case tooLarge
        /// The file changed on disk under a change, and changed again on the retry.
        case changed
        case badName
        case nameTaken(String)
        case noSuchKey(String)
        case tooManyKeys
        case valueTooLong(String)
        case badValue(String)
        case badPurpose
        case writeOnly(String)

        public var errorDescription: String? {
            switch self {
            case .tampered:
                return "Secrets’ file was changed outside Next Term, so no key is released. Start Over, or restore the file from a backup."
            case .cantOpen:
                return "These keys were saved on another Mac, or this Mac’s Secure Enclave was reset, so they can’t be opened here."
            case .cancelled: return "Not approved."
            case .locked: return "Secrets is locked."
            case .tooLarge: return "Secrets’ file is too large to read."
            case .changed: return "Secrets’ file changed while it was being saved, so nothing was saved. Try again."
            case .badName: return "A name uses capital letters, digits and _, starts with a letter, and has at most 64 characters."
            case .nameTaken(let name): return "There is already a key named \(name)."
            case .noSuchKey(let name): return "No key named \(name)."
            case .tooManyKeys: return "Secrets holds at most \(SecretVault.maxEntries) keys."
            case .valueTooLong(let name): return "\(name) is longer than 16 KB."
            case .badValue(let name): return "\(name) is empty, or holds a line break or a NUL character, or is not text."
            case .badPurpose: return "What a key is for is one line of at most \(SecretVault.maxPurposeLength) characters."
            case .writeOnly(let name): return "\(name) is write-only: Next Term never shows it again."
            }
        }
    }

    /// Where a key came from. A key "you added" is any origin but `agent`.
    public enum Origin: String, Codable, Sendable {
        case settings, request, agent
        case `import`
    }

    /// Who wrote what a key is for.
    public enum PurposeBy: String, Codable, Sendable {
        case user, agent
    }

    /// One form of a value as masking finds it, with no value in it: its length, a 16-bit head and a 16-byte tag.
    public struct Mark: Codable, Equatable, Hashable, Sendable {
        public let length: Int
        public let head: UInt16
        public let tag: Data

        public init(length: Int, head: UInt16, tag: Data) {
            self.length = length
            self.head = head
            self.tag = tag
        }
    }

    /// One key: its facts in the clear (authenticated by the index's MAC) and its value sealed.
    public struct Entry: Codable, Equatable, Sendable {
        public let id: String
        public internal(set) var name: String
        public internal(set) var purpose: String
        public internal(set) var purposeBy: PurposeBy
        public internal(set) var origin: Origin
        public internal(set) var writeOnly: Bool
        public let created: Date
        public internal(set) var changed: Date
        /// AES-GCM's combined form: nonce, ciphertext, tag.
        var box: Data
        public internal(set) var marks: [Mark]

        /// Added by the user: in Settings, through `request_secret` or the import. Not by an agent's `store_secret`.
        public var addedByUser: Bool { origin != .agent }
    }

    struct Wrapped: Codable, Equatable, Sendable {
        var ephemeral: Data
        var box: Data
    }

    struct Recovery: Codable, Equatable, Sendable {
        var box: Data
    }

    /// The body: what the index's MAC covers. Readable with no key, for lists and the marks at launch.
    public struct Index: Codable, Equatable, Sendable {
        public internal(set) var format: Int
        public internal(set) var keyring: VaultKeyringKind
        public internal(set) var keyBlob: Data?
        public internal(set) var publicKey: Data
        var wrapped: Wrapped
        var recovery: Recovery?
        public internal(set) var entries: [Entry]

        /// Whether the second wrap, under the login keychain's recovery key, is there.
        public var hasRecovery: Bool { recovery != nil }

        public func entry(named name: String) -> Entry? { entries.first { $0.name == name } }
        public var names: [String] { entries.map(\.name) }
    }

    /// vault.json's outer object.
    struct File: Codable, Equatable {
        var format: Int
        var body: Data
        var mac: Data
    }

    public private(set) var index: Index
    /// vault.json's bytes as they are now: what was read, or what the last change made.
    public private(set) var file: Data
    private var vaultKey: SymmetricKey?

    private init(index: Index, file: Data, vaultKey: SymmetricKey) {
        self.index = index
        self.file = file
        self.vaultKey = vaultKey
    }

    // MARK: making and opening

    /// A new, empty vault guarded by `keyring`, unlocked, and the 32 random bytes of its `mask.key`. Wrapping needs no
    /// presence. The caller writes `mask.key` with the first `vault.json`, under the same lock.
    public static func create(keyring: VaultKeyring) throws -> (vault: SecretVault, maskKey: SecretBytes) {
        let vaultKey = SymmetricKey(size: .bits256)
        let publicKey = try keyring.publicKey()
        let wrapped = try wrap(vaultKey, for: publicKey, kind: keyring.kind)
        let index = Index(format: format, keyring: keyring.kind, keyBlob: keyring.keyBlob, publicKey: publicKey,
                          wrapped: wrapped, recovery: nil, entries: [])
        let file = try encodeFile(index, key: vaultKey)
        return (SecretVault(index: index, file: file, vaultKey: vaultKey), randomBytes(maskKeyLength))
    }

    /// The body, read with no key and no MAC check: names, what each is for, flags, dates and marks. For lists and
    /// for masking at launch; nothing here is trusted for a release. Throws `tampered` for a file that is not a vault,
    /// and `tooLarge` past 8 MB.
    public static func index(from data: Data) throws -> Index {
        try decode(data).index
    }

    /// The vault, unlocked: the keyring's shared secret unwraps the vault key, then the index's MAC is checked over
    /// the body's bytes as stored, before any value is decrypted. Throws `cantOpen` when the keyring's key is not the
    /// vault's, `tampered` when the wrap or the MAC fails, and `cancelled` when the user did not approve.
    public static func unlock(_ data: Data, keyring: VaultKeyring, context: AnyObject?) throws -> SecretVault {
        let (file, index) = try decode(data)
        guard index.keyring == keyring.kind else { throw Failure.cantOpen }
        guard let ephemeral = try? P256.KeyAgreement.PublicKey(x963Representation: index.wrapped.ephemeral) else {
            throw Failure.tampered
        }
        let opened: VaultKeyringSecret
        do {
            opened = try keyring.sharedSecret(with: ephemeral, context: context)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.cantOpen
        }
        guard opened.publicKey == index.publicKey else { throw Failure.cantOpen }
        let wrapKey = Self.wrapKey(opened.secret, ephemeral: index.wrapped.ephemeral, recipient: index.publicKey)
        let label = wrapData(index.keyring.rawValue)
        guard let vaultKey = openKey(index.wrapped.box, using: wrapKey, authenticating: label) else { throw Failure.tampered }
        guard isAuthentic(file, key: vaultKey) else { throw Failure.tampered }
        return SecretVault(index: index, file: data, vaultKey: vaultKey)
    }

    /// The vault, unlocked with the login keychain's recovery key alone (after the app's presence check), when
    /// the Secure Enclave key no longer opens. Throws `cantOpen` for a vault with no second wrap or another key.
    public static func unlock(_ data: Data, recovery: SecretBytes) throws -> SecretVault {
        let (file, index) = try decode(data)
        guard let box = index.recovery?.box, recovery.count == recoveryKeyLength else { throw Failure.cantOpen }
        let key = recoveryKey(recovery)
        guard let vaultKey = openKey(box, using: key, authenticating: wrapData(recoveryLabel)) else { throw Failure.cantOpen }
        guard isAuthentic(file, key: vaultKey) else { throw Failure.tampered }
        return SecretVault(index: index, file: data, vaultKey: vaultKey)
    }

    /// Takes `data`, which changed on disk since this vault was read, with the vault key in hand: for a change's one
    /// retry. Throws `changed` when it is not this vault any more (another copy started over), `tampered` when it is
    /// not a vault.
    public func reload(_ data: Data) throws {
        let key = try unlockedKey()
        let (file, index) = try Self.decode(data)
        guard Self.isAuthentic(file, key: key) else { throw Failure.changed }
        self.index = index
        self.file = data
    }

    /// Drops the vault key. Every later call but `index` throws `locked`.
    public func wipe() {
        vaultKey = nil
    }

    public var isUnlocked: Bool { vaultKey != nil }

    // MARK: changes

    /// Adds a key. The value is trimmed of white space at both ends; one holding NUL, CR or LF is refused, and so is
    /// one over 16 KB. With `maskKey` (`mask.key`), the entry gets the value's masking marks, made here with the value
    /// at hand (`SecretMask.marks(for:key:)`).
    public func add(name: String, purpose: String, purposeBy: PurposeBy, origin: Origin, writeOnly: Bool,
                    value: SecretBytes, maskKey: SymmetricKey? = nil, now: Date = Date()) throws -> Data {
        let key = try unlockedKey()
        guard StoredSecretName.isValid(name) else { throw Failure.badName }
        guard index.entry(named: name) == nil else { throw Failure.nameTaken(name) }
        guard index.entries.count < Self.maxEntries else { throw Failure.tooManyKeys }
        let purpose = try Self.checkedPurpose(purpose)
        let value = try Self.normalized(value, name: name)
        let id = UUID().uuidString.lowercased()
        let box = try Self.seal(value, key: key, id: id, name: name, writeOnly: writeOnly, origin: origin)
        let date = Self.whole(now)
        let marks = maskKey.map { SecretMask.marks(for: value, key: $0) } ?? []
        let entry = Entry(id: id, name: name, purpose: purpose, purposeBy: purposeBy, origin: origin, writeOnly: writeOnly,
                          created: date, changed: date, box: box, marks: marks)
        index.entries.append(entry)
        return try written(key)
    }

    /// Renames a key, changes what it is for, or both. A new name seals the value again, since the name is in its seal.
    public func edit(_ name: String, newName: String? = nil, purpose: String? = nil, purposeBy: PurposeBy? = nil,
                     now: Date = Date()) throws -> Data {
        let key = try unlockedKey()
        var (position, entry) = try find(name)
        if let newName, newName != name {
            guard StoredSecretName.isValid(newName) else { throw Failure.badName }
            guard index.entry(named: newName) == nil else { throw Failure.nameTaken(newName) }
            let value = try Self.open(entry, key: key)
            entry.box = try Self.seal(value, key: key, id: entry.id, name: newName, writeOnly: entry.writeOnly, origin: entry.origin)
            entry.name = newName
        }
        if let purpose {
            entry.purpose = try Self.checkedPurpose(purpose)
            entry.purposeBy = purposeBy ?? .user
        }
        entry.changed = Self.whole(now)
        index.entries[position] = entry
        return try written(key)
    }

    /// A new value for a key, write-only or not. `origin`, when given, is who replaced it (`agent` for an agent's
    /// `store_secret`); the key's purpose stays.
    public func replace(_ name: String, value: SecretBytes, writeOnly: Bool, origin: Origin? = nil, maskKey: SymmetricKey? = nil,
                        now: Date = Date()) throws -> Data {
        let key = try unlockedKey()
        var (position, entry) = try find(name)
        let value = try Self.normalized(value, name: name)
        let origin = origin ?? entry.origin
        entry.box = try Self.seal(value, key: key, id: entry.id, name: name, writeOnly: writeOnly, origin: origin)
        entry.origin = origin
        entry.writeOnly = writeOnly
        entry.marks = maskKey.map { SecretMask.marks(for: value, key: $0) } ?? []
        entry.changed = Self.whole(now)
        index.entries[position] = entry
        return try written(key)
    }

    /// Makes a normal key write-only, one way: its value is sealed again with the flag.
    public func makeWriteOnly(_ name: String, now: Date = Date()) throws -> Data {
        let key = try unlockedKey()
        var (position, entry) = try find(name)
        guard !entry.writeOnly else { return file }
        let value = try Self.open(entry, key: key)
        entry.box = try Self.seal(value, key: key, id: entry.id, name: name, writeOnly: true, origin: entry.origin)
        entry.writeOnly = true
        entry.changed = Self.whole(now)
        index.entries[position] = entry
        return try written(key)
    }

    public func delete(_ name: String) throws -> Data {
        let key = try unlockedKey()
        let (position, _) = try find(name)
        index.entries.remove(at: position)
        return try written(key)
    }

    /// Gives every entry new marks under `maskKey`: after a missing `mask.key` was made again.
    public func remark(maskKey: SymmetricKey) throws -> Data {
        let key = try unlockedKey()
        for position in index.entries.indices {
            let value = try Self.open(index.entries[position], key: key)
            index.entries[position].marks = SecretMask.marks(for: value, key: maskKey)
        }
        return try written(key)
    }

    // MARK: values

    /// A key's value, to hand to a command: write-only keys included. Throws `tampered` when its seal fails.
    public func value(of name: String) throws -> SecretBytes {
        let key = try unlockedKey()
        let (_, entry) = try find(name)
        return try Self.open(entry, key: key)
    }

    /// A key's value, to show or copy: refused for a write-only key.
    public func shownValue(of name: String) throws -> SecretBytes {
        let (_, entry) = try find(name)
        guard !entry.writeOnly else { throw Failure.writeOnly(name) }
        return try value(of: name)
    }

    // MARK: the import's kept values

    /// Seals the values the import detected but did not move, for one backup record, under a key derived from
    /// the vault key and the record's id.
    public func sealBackup(_ values: [SecretBytes], id: String) throws -> Data {
        let key = try unlockedKey()
        var plain = Data()
        for value in values {
            Self.appendField(value.withUnsafeBytes { Data($0) }, to: &plain)
        }
        defer { SecretBytes.wipe(&plain) }
        let sealed = try AES.GCM.seal(plain, using: Self.importKey(key, id: id), authenticating: Data(id.utf8))
        guard let combined = sealed.combined else { throw Failure.tampered }
        return combined
    }

    public func openBackup(_ box: Data, id: String) throws -> [SecretBytes] {
        let key = try unlockedKey()
        guard let sealed = try? AES.GCM.SealedBox(combined: box),
              var plain = try? AES.GCM.open(sealed, using: Self.importKey(key, id: id), authenticating: Data(id.utf8)) else {
            throw Failure.tampered
        }
        defer { SecretBytes.wipe(&plain) }
        var values: [SecretBytes] = []
        var offset = plain.startIndex
        while offset < plain.endIndex {
            guard plain.endIndex - offset >= 4 else { throw Failure.tampered }
            let length = plain[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            offset += 4
            guard plain.endIndex - offset >= length else { throw Failure.tampered }
            values.append(SecretBytes([UInt8](plain[offset..<offset + length])))
            offset += length
        }
        return values
    }

    // MARK: the second wrap, under the login keychain's recovery key

    /// Also wraps the vault key under a 32-byte recovery key, which the app keeps in the login keychain.
    public func addRecovery(key recovery: SecretBytes) throws -> Data {
        let key = try unlockedKey()
        guard recovery.count == Self.recoveryKeyLength else { throw Failure.cantOpen }
        let sealed = try AES.GCM.seal(Self.bytes(of: key), using: Self.recoveryKey(recovery),
                                      authenticating: Self.wrapData(Self.recoveryLabel))
        guard let combined = sealed.combined else { throw Failure.tampered }
        index.recovery = Recovery(box: combined)
        return try written(key)
    }

    /// Wraps the vault key under a new keyring: the rescue with the recovery key, after the old Secure Enclave key
    /// stopped opening.
    public func rewrap(under keyring: VaultKeyring) throws -> Data {
        let key = try unlockedKey()
        let publicKey = try keyring.publicKey()
        index.wrapped = try Self.wrap(key, for: publicKey, kind: keyring.kind)
        index.keyring = keyring.kind
        index.keyBlob = keyring.keyBlob
        index.publicKey = publicKey
        return try written(key)
    }

    // MARK: the crypto

    func unlockedKey() throws -> SymmetricKey {
        guard let vaultKey else { throw Failure.locked }
        return vaultKey
    }

    func find(_ name: String) throws -> (Int, Entry) {
        guard let position = index.entries.firstIndex(where: { $0.name == name }) else { throw Failure.noSuchKey(name) }
        return (position, index.entries[position])
    }

    private func written(_ key: SymmetricKey) throws -> Data {
        file = try Self.encodeFile(index, key: key)
        return file
    }

    static func wrap(_ vaultKey: SymmetricKey, for publicKey: Data, kind: VaultKeyringKind) throws -> Wrapped {
        let recipient = try P256.KeyAgreement.PublicKey(x963Representation: publicKey)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let ephemeralData = ephemeral.publicKey.x963Representation
        let key = wrapKey(shared, ephemeral: ephemeralData, recipient: publicKey)
        let sealed = try AES.GCM.seal(bytes(of: vaultKey), using: key, authenticating: wrapData(kind.rawValue))
        guard let box = sealed.combined else { throw Failure.tampered }
        return Wrapped(ephemeral: ephemeralData, box: box)
    }

    /// HKDF-SHA256 over the shared secret, salt `NextTerm Secrets wrap 1`, info the ephemeral key's x963 then the
    /// keyring's.
    static func wrapKey(_ shared: SharedSecret, ephemeral: Data, recipient: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: wrapSalt, sharedInfo: ephemeral + recipient, outputByteCount: 32)
    }

    /// `nextterm-wrap/1` followed by the keyring's kind, or `recovery`.
    static func wrapData(_ kind: String) -> Data {
        Data((wrapLabel + kind).utf8)
    }

    static func recoveryKey(_ recovery: SecretBytes) -> SymmetricKey {
        let material = recovery.withUnsafeBytes { SymmetricKey(data: $0) }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: material, salt: wrapSalt, info: Data(recoveryInfo.utf8), outputByteCount: 32)
    }

    static func entryKey(_ vaultKey: SymmetricKey, id: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: vaultKey, info: Data((entryInfo + id).utf8), outputByteCount: 32)
    }

    static func indexKey(_ vaultKey: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: vaultKey, info: Data(indexInfo.utf8), outputByteCount: 32)
    }

    static func importKey(_ vaultKey: SymmetricKey, id: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: vaultKey, info: Data((importInfo + id).utf8), outputByteCount: 32)
    }

    /// Each field as a big-endian `UInt32` length, then its UTF-8 bytes: `nextterm-secret/1`, the id, the name, the
    /// write-only flag as "1" or "0", and the origin.
    static func associatedData(id: String, name: String, writeOnly: Bool, origin: Origin) -> Data {
        var data = Data()
        for field in [secretLabel, id, name, writeOnly ? "1" : "0", origin.rawValue] {
            appendField(Data(field.utf8), to: &data)
        }
        return data
    }

    static func appendField(_ field: Data, to data: inout Data) {
        let length = UInt32(field.count).bigEndian
        withUnsafeBytes(of: length) { data.append(contentsOf: $0) }
        data.append(field)
    }

    static func seal(_ value: SecretBytes, key: SymmetricKey, id: String, name: String, writeOnly: Bool,
                     origin: Origin) throws -> Data {
        let entryKey = entryKey(key, id: id)
        let data = associatedData(id: id, name: name, writeOnly: writeOnly, origin: origin)
        let sealed = try value.withUnsafeBytes { try AES.GCM.seal($0, using: entryKey, authenticating: data) }
        guard let box = sealed.combined else { throw Failure.tampered }
        return box
    }

    static func open(_ entry: Entry, key: SymmetricKey) throws -> SecretBytes {
        let entryKey = entryKey(key, id: entry.id)
        let data = associatedData(id: entry.id, name: entry.name, writeOnly: entry.writeOnly, origin: entry.origin)
        guard let sealed = try? AES.GCM.SealedBox(combined: entry.box),
              var plain = try? AES.GCM.open(sealed, using: entryKey, authenticating: data) else {
            throw Failure.tampered
        }
        return SecretBytes(consuming: &plain)
    }

    static func openKey(_ box: Data, using key: SymmetricKey, authenticating data: Data) -> SymmetricKey? {
        guard let sealed = try? AES.GCM.SealedBox(combined: box),
              var plain = try? AES.GCM.open(sealed, using: key, authenticating: data), plain.count == 32 else { return nil }
        defer { SecretBytes.wipe(&plain) }
        return SymmetricKey(data: plain)
    }

    static func bytes(of key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    static func randomBytes(_ count: Int) -> SecretBytes {
        var generator = SystemRandomNumberGenerator()
        return SecretBytes((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// The body encoded once; the MAC over exactly those bytes; both in base64 in the outer object.
    static func encodeFile(_ index: Index, key: SymmetricKey) throws -> Data {
        let body = try encoder.encode(index)
        return try encodeFile(body: body, key: key)
    }

    static func encodeFile(body: Data, key: SymmetricKey) throws -> Data {
        let mac = Data(HMAC<SHA256>.authenticationCode(for: body, using: indexKey(key)))
        return try encoder.encode(File(format: format, body: body, mac: mac))
    }

    static func isAuthentic(_ file: File, key: SymmetricKey) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(file.mac, authenticating: file.body, using: indexKey(key))
    }

    /// The outer object and the body, decoded as untrusted input: the format on both, the limits, the names.
    static func decode(_ data: Data) throws -> (file: File, index: Index) {
        guard data.count <= maxFileSize else { throw Failure.tooLarge }
        guard let file = try? decoder.decode(File.self, from: data), file.format == format,
              let index = try? decoder.decode(Index.self, from: file.body), index.format == file.format,
              isWellFormed(index) else {
            throw Failure.tampered
        }
        return (file, index)
    }

    static func isWellFormed(_ index: Index) -> Bool {
        guard index.entries.count <= maxEntries else { return false }
        var names = Set<String>()
        var ids = Set<String>()
        for entry in index.entries {
            guard StoredSecretName.isValid(entry.name), !entry.id.isEmpty, entry.id.utf8.count <= 64,
                  entry.purpose.count <= maxPurposeLength, names.insert(entry.name).inserted,
                  ids.insert(entry.id).inserted else { return false }
        }
        return true
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// What a key is for: trimmed, one line, at most 200 characters.
    static func checkedPurpose(_ text: String) throws -> String {
        let purpose = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasBreak = purpose.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || $0 == "\u{2028}" || $0 == "\u{2029}" }
        guard !hasBreak, purpose.count <= maxPurposeLength else { throw Failure.badPurpose }
        return purpose
    }

    /// The value trimmed of white space at both ends; refused when empty, over 16 KB, not UTF-8, or holding NUL, CR or
    /// LF.
    static func normalized(_ value: SecretBytes, name: String) throws -> SecretBytes {
        let spaces: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D]
        let trimmed: [UInt8] = value.withUnsafeBytes { buffer in
            var start = buffer.startIndex
            var end = buffer.endIndex
            while start < end, spaces.contains(buffer[start]) { start += 1 }
            while end > start, spaces.contains(buffer[end - 1]) { end -= 1 }
            return Array(buffer[start..<end])
        }
        let result = SecretBytes(trimmed)
        guard !result.isEmpty else { throw Failure.badValue(name) }
        guard result.count <= maxValueBytes else { throw Failure.valueTooLong(name) }
        let isClean = result.withUnsafeBytes { buffer in !buffer.contains(0) && !buffer.contains(0x0A) && !buffer.contains(0x0D) }
        guard isClean, result.withUnsafeBytes(isUTF8) else { throw Failure.badValue(name) }
        return result
    }

    /// Whether bytes are valid UTF-8, without making a `String` of them.
    static func isUTF8(_ buffer: UnsafeRawBufferPointer) -> Bool {
        var iterator = buffer.makeIterator()
        var decoder = Unicode.UTF8()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue: continue
            case .emptyInput: return true
            case .error: return false
            }
        }
    }

    /// Dates are stored to the second (ISO 8601), so the one in memory is too.
    static func whole(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}

// MARK: the folder

/// `Application Support/Next Term/Secrets.noindex`: `vault.json` (the index and every sealed value), `mask.key`,
/// `vault.lock`, `audit.log` and `audit.log.1`, and `imports/`.
///
/// - **Private.** Made 0700 with `PrivateFolder.make(at:)`, and checked with `PrivateFolder.isPrivate` before each
///   use: a link, a file or another user's folder at its name is refused, never followed. Its `.noindex` name keeps
///   Spotlight out.
/// - **Untrusted when read.** A file is opened without following a link and without waiting on a named pipe, and read
///   only when it is a plain file of this user's with no other name, under the caller's cap.
/// - **Whole changes.** Writes go through `SafeWrite.replace`, expecting the bytes read, under `flock(LOCK_EX)` on
///   `vault.lock`, so two copies of Next Term never undo each other.
/// - **Backups.** `mask.key`, the audit log and `imports/` are marked excluded from backups. macOS can reset that
///   mark, so it is a reduction, not a guarantee.
public final class SecretFolder: @unchecked Sendable {
    public static let folderName = "Secrets.noindex"
    public static let vaultName = "vault.json"
    public static let maskKeyName = "mask.key"
    public static let lockName = "vault.lock"
    public static let auditName = "audit.log"
    public static let olderAuditName = "audit.log.1"
    public static let importsName = "imports"

    /// Why nothing was read or written.
    public enum Failure: Error, Equatable, LocalizedError {
        /// What is at the folder's name is not a folder only this user can reach: a link, a file, another user's
        /// folder, or one open to others.
        case notPrivate
        /// What is at a file's name is not a plain file of this user's: a link, a folder, a file with a second name.
        case refused
        /// Bigger than the caller's cap: refused unread.
        case tooLarge
        /// The file changed between the read and the write, and again on the retry.
        case changed
        /// `SafeWrite` refused or failed.
        case write(SafeWrite.Failure)
        /// A system call failed with this `errno`.
        case system(Int32)

        public var errorDescription: String? {
            switch self {
            case .notPrivate: return "Secrets’ folder is not one only you can open, so Next Term doesn’t use it."
            case .refused: return "A file in Secrets’ folder is not a plain file of yours, so Next Term doesn’t read it."
            case .tooLarge: return "A file in Secrets’ folder is too large to read."
            case .changed: return "Secrets’ file changed while it was being saved, so nothing was saved. Try again."
            case .write(let failure): return failure.errorDescription
            case .system(let code): return String(cString: strerror(code)) + "."
            }
        }
    }

    public let url: URL
    let owner: uid_t
    /// Runs just before a write: the tests change the file there.
    var beforeWrite: ((String) -> Void)?

    /// The folder for the Application Support folder `applicationSupport`.
    public convenience init(applicationSupport: URL, owner: uid_t = geteuid()) {
        let url = applicationSupport.appendingPathComponent("Next Term", isDirectory: true)
            .appendingPathComponent(Self.folderName, isDirectory: true)
        self.init(url: url, owner: owner)
    }

    public init(url: URL, owner: uid_t = geteuid()) {
        self.url = url
        self.owner = owner
    }

    public func path(_ name: String) -> String { url.appendingPathComponent(name).path }

    /// Whether anything is at the folder's name (a link included).
    public var exists: Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// Makes the folder, 0700, when nothing is at its name; else checks that it is private.
    public func ensure() throws {
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if !exists {
            do {
                _ = try PrivateFolder.make(at: url, owner: owner)
            } catch {
                guard exists else { throw error } // another copy made it meanwhile: checked below
            }
        }
        try checkPrivate()
    }

    public func checkPrivate() throws {
        guard PrivateFolder.isPrivate(url.path, owner: owner) else { throw Failure.notPrivate }
    }

    /// The file `name`, read as untrusted input, or nil when there is none.
    public func read(_ name: String, cap: Int) throws -> Data? {
        try checkPrivate()
        let descriptor = open(path(name), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: return nil
            case ELOOP: throw Failure.refused
            default: throw Failure.system(errno)
            }
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Failure.system(errno) }
        guard isOwnFile(info) else { throw Failure.refused }
        guard info.st_size <= cap else { throw Failure.tooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Failure.system(errno) }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
            guard data.count <= cap else { throw Failure.tooLarge }
        }
        return data
    }

    /// Replaces the file `name` with `data` (`SafeWrite.replace`), 0600. A link or anything else not a plain file of
    /// this user's at its name is refused, never written through.
    public func write(_ name: String, data: Data, expecting: SafeWrite.Expectation = .anything) throws {
        try checkPrivate()
        let target = path(name)
        var info = stat()
        if lstat(target, &info) == 0 {
            guard isOwnFile(info) else { throw Failure.refused }
            if info.st_mode & 0o777 != 0o600 { _ = chmod(target, 0o600) }
        }
        beforeWrite?(name)
        do {
            try SafeWrite.replace(target, with: data, expecting: expecting, newFileMode: 0o600)
        } catch SafeWrite.Failure.changed {
            throw Failure.changed
        } catch let failure as SafeWrite.Failure {
            throw Failure.write(failure)
        }
        if name == Self.maskKeyName { exclude(name) }
    }

    /// Runs `body` holding `flock(LOCK_EX)` on `vault.lock`, waiting for another copy of Next Term to let it go. Not
    /// to be nested: a second lock in the same process waits for the first.
    @discardableResult
    public func withLock<T>(_ body: () throws -> T) throws -> T {
        try checkPrivate()
        let descriptor = open(path(Self.lockName), O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw errno == ELOOP ? Failure.refused : Failure.system(errno) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner else {
            throw Failure.refused
        }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw Failure.system(errno) }
        }
        return try body()
    }

    /// Inside `withLock`: reads `name` (nil when there is none), hands its bytes to `change`, and writes what `change`
    /// returns, expecting the bytes it read. When the file changed in between, it reads again and calls `change` once
    /// more; a second change throws `changed`. `change` returning nil writes nothing. Returns what was written.
    @discardableResult
    public func update(_ name: String = SecretFolder.vaultName, cap: Int = SecretVault.maxFileSize,
                       _ change: (_ current: Data?) throws -> Data?) throws -> Data? {
        for attempt in 0..<2 {
            let current = try read(name, cap: cap)
            guard let new = try change(current) else { return nil }
            do {
                try write(name, data: new, expecting: current.map { .contents($0) } ?? .noFile)
                return new
            } catch Failure.changed where attempt == 0 {
                continue
            }
        }
        throw Failure.changed
    }

    /// Appends one line to `audit.log`, 0600, with `O_APPEND`. At 1 MB the log becomes `audit.log.1` first, replacing
    /// the older one.
    public func appendAudit(_ line: Data) throws {
        try checkPrivate()
        let target = path(Self.auditName)
        var info = stat()
        var isNew = true
        if lstat(target, &info) == 0 {
            guard isOwnFile(info) else { throw Failure.refused }
            if SecretAudit.needsRotation(size: Int(info.st_size), adding: line.count) {
                guard rename(target, path(Self.olderAuditName)) == 0 else { throw Failure.system(errno) }
            } else {
                isNew = false
            }
        }
        let descriptor = open(target, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw errno == ELOOP ? Failure.refused : Failure.system(errno) }
        defer { close(descriptor) }
        guard fstat(descriptor, &info) == 0, isOwnFile(info) else { throw Failure.refused }
        try line.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count, let base = buffer.baseAddress {
                let count = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.system(count < 0 ? errno : EIO) }
                offset += count
            }
        }
        if isNew { excludeFromBackup() }
    }

    /// The audit log, the older file first, read as untrusted input.
    public func readAudit() -> Data {
        let cap = SecretAudit.maxSize * 2
        let older = (try? read(Self.olderAuditName, cap: cap)) ?? nil
        let current = (try? read(Self.auditName, cap: cap)) ?? nil
        return (older ?? Data()) + (current ?? Data())
    }

    /// `imports/`, made 0700 and excluded from backups when it is not there.
    public func ensureImports() throws -> URL {
        try checkPrivate()
        let imports = url.appendingPathComponent(Self.importsName, isDirectory: true)
        if mkdir(imports.path, 0o700) != 0, errno != EEXIST { throw Failure.system(errno) }
        guard PrivateFolder.isPrivate(imports.path, owner: owner) else { throw Failure.notPrivate }
        exclude(Self.importsName)
        return imports
    }

    /// Marks `mask.key`, the audit log and `imports/` excluded from backups, where they are.
    public func excludeFromBackup() {
        for name in [Self.maskKeyName, Self.auditName, Self.olderAuditName, Self.importsName] { exclude(name) }
    }

    func exclude(_ name: String) {
        var info = stat()
        guard lstat(path(name), &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { return }
        var item = url.appendingPathComponent(name)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? item.setResourceValues(values)
    }

    /// When `name` last changed, or nil when it is not there.
    public func modificationDate(of name: String) -> Date? {
        var info = stat()
        guard lstat(path(name), &info) == 0 else { return nil }
        let time = info.st_mtimespec
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }

    // MARK: Start Over

    /// Start Over's name for the old folder: `Secrets-<day>.old.noindex`, then `Secrets-<day>-2.old.noindex`, `-3` and
    /// so on while a name is taken.
    public static func oldName(day: String, taken: (String) -> Bool) -> String {
        var name = "Secrets-\(day).old.noindex"
        var number = 2
        while taken(name) {
            name = "Secrets-\(day)-\(number).old.noindex"
            number += 1
        }
        return name
    }

    /// The local date as `yyyy-MM-dd`, in the Gregorian calendar.
    public static func day(of date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Renames the folder to its old name (`oldName`), never replacing anything there: an exclusive rename, which
    /// takes the next name when it finds one taken. Returns where it went. The next `ensure()` makes a new, empty one.
    @discardableResult
    public func retire(on date: Date = Date(), timeZone: TimeZone = .current) throws -> URL {
        let parent = url.deletingLastPathComponent()
        let day = Self.day(of: date, timeZone: timeZone)
        for _ in 0..<1000 {
            let name = Self.oldName(day: day) { candidate in
                var info = stat()
                return lstat(parent.appendingPathComponent(candidate).path, &info) == 0
            }
            let target = parent.appendingPathComponent(name, isDirectory: true)
            if renamex_np(url.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            guard errno == EEXIST else { throw Failure.system(errno) }
        }
        throw Failure.system(EEXIST)
    }

    /// A plain file of this user's with no other name.
    func isOwnFile(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == owner && info.st_nlink == 1
    }
}
