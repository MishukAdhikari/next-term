import AppKit
import CryptoKit
import LocalAuthentication
import NextTermCore
import Security

/// The keychain keyring's items, over an in-memory keychain: never the login keychain.
extension SelfTest {
    /// A store over its own temporary folder whose vaults use the keychain keyring, with its items in `keychain`.
    static func secretsKeychainStore(_ base: URL, _ name: String, keychain: MemoryKeychain) -> (SecretsStore, StandInPresence) {
        let presence = StandInPresence()
        let folder = SecretFolder(applicationSupport: base.appendingPathComponent(name, isDirectory: true))
        let store = SecretsStore(folder: folder, presence: presence, newKeyring: { try KeychainKeyring.make(items: keychain.item) },
                                 keyring: { KeychainKeyring(publicKey: $0.publicKey, items: keychain.item) })
        return (store, presence)
    }

    /// Each keychain vault keeps its key in an item of its own: Start Over and the next Add leave the kept vault's
    /// item as it was, so the kept folder still opens; a key is never written over an item that is there; and a vault
    /// whose key is still in the one item earlier builds shared opens with it only when that key is the vault's.
    static func secretsKeychainItemChecks(_ base: URL) async {
        let keychain = MemoryKeychain()
        let (store, _) = secretsKeychainStore(base, "keychain-items", keychain: keychain)
        let first = secretsValue("first-keychain")
        _ = try? await store.perform(.add(name: "FIRST_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                          value: SecretBytes(utf8: first)))
        guard let old = store.index else { return check(false, "secrets: the first keychain vault is made") }
        let oldItem = keychain.item(LoginKeychain.vaultKeyAccount(publicKey: old.publicKey))
        let oldKey = try? oldItem.read()
        let kept = try? store.startOver()
        _ = try? await store.perform(.add(name: "SECOND_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                          value: SecretBytes(utf8: secretsValue("second-keychain"))))
        let made = store.index.map { $0.publicKey != old.publicKey } ?? false
        check(made && oldKey != nil && (try? oldItem.read()) == oldKey && keychain.accounts.count == 2,
              "secrets: Add after Start Over gives the new keychain vault an item of its own and leaves the kept vault's",
              keychain.accounts.joined(separator: ", "))
        var opened: SecretBytes?
        if let kept, let data = try? Data(contentsOf: kept.appendingPathComponent(SecretFolder.vaultName)),
           let vault = try? SecretVault.unlock(data, keyring: KeychainKeyring(publicKey: old.publicKey, items: keychain.item),
                                               context: NSObject()) {
            opened = try? vault.value(of: "FIRST_KEY")
            vault.wipe()
        }
        check(opened == SecretBytes(utf8: first), "secrets: the vault Start Over kept still opens with its own keychain item")

        let taken = MemoryPasswordStore()
        try? taken.add(Data("there before".utf8))
        let overwrote = (try? KeychainKeyring.make(items: { _ in taken })) != nil
        check(!overwrote && (try? taken.read()) == Data("there before".utf8) && taken.writes == 1,
              "secrets: a new keychain key is never written over an item that is there", "\(taken.writes) writes")

        // A first Add that fails after its key was made (here, a value with a line break) leaves no item behind.
        let fresh = MemoryKeychain()
        let (unmade, _) = secretsKeychainStore(base, "keychain-failed-add", keychain: fresh)
        var refused: SecretsStore.Failure?
        do {
            try await unmade.perform(.add(name: "BAD_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                          value: SecretBytes(utf8: "two\nlines")))
        } catch {
            refused = error as? SecretsStore.Failure
        }
        let left = fresh.accounts
        _ = try? await unmade.perform(.add(name: "GOOD_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                           value: SecretBytes(utf8: secretsValue("after-failed-add"))))
        let madeOne: Bool = unmade.index != nil && fresh.accounts.count == 1
        check(refused == .vault(.badValue("BAD_KEY")) && left.isEmpty && madeOne,
              "secrets: a first keychain Add that fails leaves no item behind, and the next Add makes one",
              "\(String(describing: refused)), left \(left.joined(separator: ", ")), then \(fresh.accounts.count)")
        await secretsSharedItemChecks(base)
        await secretsKeychainPromptChecks(base)
    }

    /// A vault made when every keychain vault kept its key in one shared item.
    static func secretsSharedItemChecks(_ base: URL) async {
        let key = SoftwareKeyring(kind: .keychain)
        let value = secretsValue("shared-keychain")
        guard let made = try? SecretVault.create(keyring: key),
              let file = try? made.vault.add(name: "SHARED_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                             value: SecretBytes(utf8: value)) else {
            return check(false, "secrets: the vault with its key in the shared item is planted")
        }
        let maskKey = made.maskKey.withUnsafeBytes { Data($0) }
        made.vault.wipe()
        let own = LoginKeychain.vaultKeyAccount(publicKey: key.publicKey())
        let shared = LoginKeychain.sharedVaultKeyAccount
        func planted(_ name: String, account: String, key: Data) async -> (SecretsStore, MemoryKeychain) {
            let keychain = MemoryKeychain()
            try? keychain.item(account).add(key)
            let (store, _) = secretsKeychainStore(base, name, keychain: keychain)
            try? store.folder.ensure()
            try? store.folder.write(SecretFolder.maskKeyName, data: maskKey)
            try? store.folder.write(SecretFolder.vaultName, data: file)
            await store.load()
            return (store, keychain)
        }

        let (store, keychain) = await planted("keychain-shared", account: shared, key: key.rawRepresentation)
        let revealed = try? await store.perform(.reveal(name: "SHARED_KEY"))
        let opened: Bool = revealed?["SHARED_KEY"] == SecretBytes(utf8: value)
        let copied: Bool = (try? keychain.item(own).read()) == key.rawRepresentation
        let kept: Bool = (try? keychain.item(shared).read()) == key.rawRepresentation
        check(opened && copied && kept,
              "secrets: a vault whose key is in the shared keychain item opens, and its key is copied to an item of its own",
              keychain.accounts.joined(separator: ", "))

        // Another vault's key, in the shared item or in the vault's own: the load check passes on the item, and the first
        // use, which finds the key isn't this vault's, marks Secrets can't open, so Settings shows Start Over.
        let otherKey = SoftwareKeyring(kind: .keychain).rawRepresentation
        for (account, which, folder) in [(shared, "shared", "keychain-other-shared"), (own, "vault's own", "keychain-other-own")] {
            let (other, otherKeychain) = await planted(folder, account: account, key: otherKey)
            let before = other.protection
            var failure: SecretsStore.Failure?
            do { try await other.perform(.reveal(name: "SHARED_KEY")) } catch { failure = error as? SecretsStore.Failure }
            let copiedNowhere: Bool = otherKeychain.accounts == [account]
            let marked: Bool = before == .lessProtected && other.protection == .cantOpen
            check(failure == .vault(.cantOpen) && copiedNowhere && marked,
                  "secrets: another vault's key in the \(which) keychain item opens nothing, is copied nowhere, and marks Secrets can't open",
                  "\(String(describing: failure)), \(before) then \(other.protection), \(otherKeychain.accounts.joined(separator: ", "))")
        }
    }

    /// Cancel or Deny at macOS's keychain prompt, or a keychain that can't ask just now, is a cancel, which leaves Secrets
    /// usable. Another failed read is a key out of reach just now, which leaves it usable too, and never says the keys
    /// are another Mac's. An item that is gone says Secrets can't open.
    static func secretsKeychainPromptChecks(_ base: URL) async {
        let keychain = MemoryKeychain()
        let (store, _) = secretsKeychainStore(base, "keychain-prompt", keychain: keychain)
        let value = secretsValue("prompt-keychain")
        _ = try? await store.perform(.add(name: "PROMPT_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                          value: SecretBytes(utf8: value)))
        guard let index = store.index else { return check(false, "secrets: the keychain vault for the prompt checks is made") }
        let item = keychain.store(LoginKeychain.vaultKeyAccount(publicKey: index.publicKey))
        func reveal() async -> (values: [String: SecretBytes]?, failure: SecretsStore.Failure?) {
            do {
                return (try await store.perform(.reveal(name: "PROMPT_KEY")), nil)
            } catch {
                return (nil, error as? SecretsStore.Failure)
            }
        }
        let refusals = [(errSecUserCanceled, "Cancel at the keychain prompt"), (errSecAuthFailed, "Deny at the keychain prompt"),
                        (errSecInteractionNotAllowed, "a keychain that can't ask just now")]
        for (status, what) in refusals {
            item.readFailure = status
            let refused = await reveal()
            check(refused.failure == .cancelled && store.protection == .lessProtected,
                  "secrets: \(what) is a cancel, and Secrets stays usable",
                  "\(String(describing: refused.failure)), \(store.protection)")
        }
        item.readFailure = errSecNotAvailable
        let failed = await reveal()
        let text = failed.failure?.errorDescription ?? ""
        let neutral: Bool = !text.isEmpty && !text.contains("another Mac")
        check(failed.failure == .vault(.keyUnavailable) && neutral && store.protection == .lessProtected,
              "secrets: another failed keychain read is a key out of reach just now, never another Mac's, and Secrets stays usable",
              "\(String(describing: failed.failure)), \(store.protection)")
        item.readFailure = nil
        let opened = await reveal()
        check(opened.values?["PROMPT_KEY"] == SecretBytes(utf8: value),
              "secrets: the next approval opens the vault after a refused keychain read", "\(String(describing: opened.failure))")
        // A keychain that won't say whether the item is there (locked and its unlock cancelled, or no interaction
        // allowed) passes the load check: only an item that is surely gone fails it.
        var marked: [String] = []
        for status in LoginKeychain.refusals {
            item.searchFailure = status
            await store.load()
            if store.protection != .lessProtected { marked.append("\(status): \(store.protection)") }
        }
        item.searchFailure = nil
        let statuses = [errSecSuccess, errSecItemNotFound, errSecNotAvailable] + LoginKeychain.refusals
        let said: [Bool?] = statuses.map { LoginKeychain.existence($0) }
        let unsaid: [Bool?] = LoginKeychain.refusals.map { _ -> Bool? in nil }
        let expected: [Bool?] = [true, false, false] + unsaid
        check(marked.isEmpty && said == expected,
              "secrets: a keychain search that is refused says nothing of the item, and doesn't mark Secrets can't open at load()",
              "\(marked.joined(separator: ", ")) \(said)")
        try? item.delete()
        let gone = await reveal()
        check(gone.failure == .vault(.cantOpen) && store.protection == .cantOpen,
              "secrets: a keychain item that is gone marks Secrets can't open at the first use", "\(store.protection)")
        await secretsKeyringFailureChecks(base)
    }
}

/// A keyring whose load check passes but whose key agreement fails with `failure`: a key that turns out not to open
/// only at the first use, as a Secure Enclave key can.
final class SelfTestFailingKeyring: VaultKeyring {
    let kind = VaultKeyringKind.secureEnclave
    let keyBlob: Data? = nil
    private let inner: SoftwareKeyring
    private let failure: SecretVault.Failure

    init(_ inner: SoftwareKeyring, failure: SecretVault.Failure) {
        self.inner = inner
        self.failure = failure
    }

    func publicKey() throws -> Data { inner.publicKey() }
    func check(publicKey: Data) -> Bool { true }
    func sharedSecret(with ephemeral: P256.KeyAgreement.PublicKey, context: AnyObject?) throws -> VaultKeyringSecret {
        throw failure
    }
}

extension SelfTest {
    /// A key that turns out not to open at the first use, though the load check passed, marks Secrets can't open, so
    /// Settings shows Start Over; a key out of reach just now leaves Secrets usable. And how the Secure Enclave
    /// keyring reads an error.
    static func secretsKeyringFailureChecks(_ base: URL) async {
        let key = SoftwareKeyring(kind: .secureEnclave)
        let cases: [(SecretVault.Failure, SecretsStore.Protection, String)] = [
            (.cantOpen, .cantOpen, "a key that turns out not to open at the first use marks Secrets can't open"),
            (.keyUnavailable, .secureEnclave, "a key out of reach just now leaves Secrets usable"),
        ]
        for (n, (failure, after, name)) in cases.enumerated() {
            let stub = SelfTestFailingKeyring(key, failure: failure)
            let folder = SecretFolder(applicationSupport: base.appendingPathComponent("keyring-failure-\(n)", isDirectory: true))
            let store = SecretsStore(folder: folder, presence: StandInPresence(), newKeyring: { key }, keyring: { _ in stub })
            _ = try? await store.perform(.add(name: "STUB_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                              value: SecretBytes(utf8: secretsValue("stub-keyring"))))
            let before = store.protection
            var got: SecretsStore.Failure?
            do { try await store.perform(.reveal(name: "STUB_KEY")) } catch { got = error as? SecretsStore.Failure }
            check(before == .secureEnclave && got == .vault(failure) && store.protection == after, "secrets: \(name)",
                  "\(before) then \(store.protection), \(String(describing: got))")
        }
        let errors: [(Error, SecretVault.Failure)] = [
            (LAError(.userCancel), .cancelled),
            (LAError(.notInteractive), .cancelled),
            (LAError(.biometryLockout), .keyUnavailable),
            (LAError(.invalidContext), .keyUnavailable),
            (CryptoKitError.incorrectParameterSize, .cantOpen),
            (NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode)), .cantOpen),
        ]
        let read = errors.map { SecureEnclaveKeyring.failure($0.0) }
        check(read == errors.map(\.1),
              "secrets: a Secure Enclave cancel is Not approved, another LocalAuthentication error a key out of reach just now, and a CryptoKit or Security error a key that can't open",
              "\(read)")
    }
}
