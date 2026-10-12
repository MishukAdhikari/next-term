import AppKit
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
        func planted(_ name: String, shared: Data) async -> (SecretsStore, MemoryKeychain) {
            let keychain = MemoryKeychain()
            try? keychain.item(LoginKeychain.sharedVaultKeyAccount).add(shared)
            let (store, _) = secretsKeychainStore(base, name, keychain: keychain)
            try? store.folder.ensure()
            try? store.folder.write(SecretFolder.maskKeyName, data: maskKey)
            try? store.folder.write(SecretFolder.vaultName, data: file)
            await store.load()
            return (store, keychain)
        }

        let (store, keychain) = await planted("keychain-shared", shared: key.rawRepresentation)
        let revealed = try? await store.perform(.reveal(name: "SHARED_KEY"))
        let shared = try? keychain.item(LoginKeychain.sharedVaultKeyAccount).read()
        check(revealed?["SHARED_KEY"] == SecretBytes(utf8: value) && (try? keychain.item(own).read()) == key.rawRepresentation
                && shared == key.rawRepresentation,
              "secrets: a vault whose key is in the shared keychain item opens, and its key is copied to an item of its own",
              keychain.accounts.joined(separator: ", "))

        let (other, otherKeychain) = await planted("keychain-shared-other", shared: SoftwareKeyring(kind: .keychain).rawRepresentation)
        var failure: SecretsStore.Failure?
        do { try await other.perform(.reveal(name: "SHARED_KEY")) } catch { failure = error as? SecretsStore.Failure }
        check(failure == .vault(.cantOpen) && otherKeychain.accounts == [LoginKeychain.sharedVaultKeyAccount],
              "secrets: another vault's key in the shared keychain item opens nothing and is copied nowhere",
              "\(String(describing: failure)), \(otherKeychain.accounts.joined(separator: ", "))")
    }

    /// Cancel or Deny at macOS's keychain prompt is a cancel, which leaves Secrets usable. A failed open that the load
    /// check still passes leaves it usable too; only one the load check fails as well says Secrets can't open.
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
        for (status, button) in [(errSecUserCanceled, "Cancel"), (errSecAuthFailed, "Deny")] {
            item.readFailure = status
            let refused = await reveal()
            check(refused.failure == .cancelled && store.protection == .lessProtected,
                  "secrets: \(button) at the keychain prompt is a cancel, and Secrets stays usable",
                  "\(String(describing: refused.failure)), \(store.protection)")
        }
        item.readFailure = errSecNotAvailable
        let failed = await reveal()
        check(failed.failure == .vault(.cantOpen) && store.protection == .lessProtected,
              "secrets: a keychain read that fails while the vault's item is there doesn't mark Secrets can't open",
              "\(String(describing: failed.failure)), \(store.protection)")
        item.readFailure = nil
        let opened = await reveal()
        check(opened.values?["PROMPT_KEY"] == SecretBytes(utf8: value),
              "secrets: the next approval opens the vault after a refused keychain read", "\(String(describing: opened.failure))")
        try? item.delete()
        let gone = await reveal()
        check(gone.failure == .vault(.cantOpen) && store.protection == .cantOpen,
              "secrets: a keychain item that is gone, which the load check finds too, marks Secrets can't open", "\(store.protection)")
    }
}
