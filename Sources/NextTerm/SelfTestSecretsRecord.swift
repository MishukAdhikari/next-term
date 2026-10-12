import AppKit
import CryptoKit
import NextTermCore
import Security

/// This Mac's record of the vaults Next Term made, over records in memory: never the login keychain. A whole vault.json
/// built elsewhere passes every check inside the file; the record is what refuses it, when its maker wrote files only.
/// One that can also add login-keychain items can forge the record, which these checks don't cover.
extension SelfTest {
    static func secretsRecordChecks(_ base: URL) async {
        await secretsReplacedVaultChecks(base)
        await secretsReplacedKeychainVaultChecks(base)
        await secretsPlantedVaultChecks(base)
        await secretsRecordKeepsChecks(base)
        await secretsRecordFailureChecks(base)
        secretsAppRecordChecks()
        await secretsRecordStateChecks(base)
    }

    /// The action's failure, or nil when it went through.
    static func secretsFailure(_ store: SecretsStore, _ action: SecretsStore.Action) async -> SecretsStore.Failure? {
        do {
            try await store.perform(action)
            return nil
        } catch {
            return error as? SecretsStore.Failure ?? .keyring
        }
    }

    /// An Add and a Replace on the vault `store` holds now, each after `load()`, so each reaches the unlock: their
    /// failures, and whether vault.json's bytes stayed `planted`.
    static func secretsWritesInto(_ store: SecretsStore, planted: Data, name: String) async -> ([SecretsStore.Failure?], Bool) {
        let typed = SecretBytes(utf8: secretsValue("typed-after-the-swap"))
        let actions: [SecretsStore.Action] = [
            .add(name: "NEW_KEY", purpose: "", purposeBy: .user, origin: .request, writeOnly: true, value: typed),
            .replace(name: name, value: typed, writeOnly: false, origin: nil),
        ]
        var failures: [SecretsStore.Failure?] = []
        for action in actions {
            await store.load()
            failures.append(await secretsFailure(store, action))
        }
        let bytes = try? store.folder.read(SecretFolder.vaultName, cap: SecretVault.maxFileSize)
        return (failures, bytes == planted)
    }

    /// The finding's scenario on a Secure Enclave vault: vault.json replaced by one built around a vault key and a Secure
    /// Enclave key of its maker's (the app opens whatever blob the file holds), the name and purpose copied. Its file
    /// checks out, so load() finds nothing; Add and Replace are refused as tampered and write nothing.
    static func secretsReplacedVaultChecks(_ base: URL) async {
        let keyring = SoftwareKeyring(kind: .secureEnclave)
        let theirs = SoftwareKeyring(kind: .secureEnclave)
        let record = MemoryVaultRecord()
        let folder = SecretFolder(applicationSupport: base.appendingPathComponent("record-replaced", isDirectory: true))
        let store = SecretsStore(folder: folder, presence: StandInPresence(), newKeyring: { keyring },
                                 keyring: { $0.publicKey == theirs.publicKey() ? theirs : keyring }, record: record)
        _ = try? await store.perform(.add(name: "DEPLOY_TOKEN", purpose: "deploys", purposeBy: .user, origin: .settings,
                                          writeOnly: false, value: SecretBytes(utf8: secretsValue("deploy-record"))))
        let listed: Bool = record.writes == 1 && record.contents?.count == 32
        guard let built = try? SecretVault.create(keyring: theirs),
              let planted = try? built.vault.add(name: "DEPLOY_TOKEN", purpose: "deploys", purposeBy: .user, origin: .settings,
                                                 writeOnly: false, value: SecretBytes(utf8: secretsValue("planted"))) else {
            return check(false, "secrets: the replaced vault is built")
        }
        built.vault.wipe()
        try? store.folder.write(SecretFolder.vaultName, data: planted)
        await store.load()
        let quiet: Bool = store.protection == .secureEnclave && store.index?.names == ["DEPLOY_TOKEN"]
        let (failures, unchanged) = await secretsWritesInto(store, planted: planted, name: "DEPLOY_TOKEN")
        let expected: [SecretsStore.Failure?] = [.vault(.tampered), .vault(.tampered)]
        let refused: Bool = failures == expected
        let tamperLine: Bool = secretsAudit(store).last?.event == .tamper
        check(listed && quiet && refused && unchanged && store.protection == .tampered && tamperLine,
              "secrets: a whole vault.json built with its own Secure Enclave key loads quietly, but Add and Replace are refused as tampered and write nothing",
              "listed \(listed), quiet \(quiet), \(failures), unchanged \(unchanged), \(store.protection)")
    }

    /// The same on a keychain vault: the replacement's key is in an item its maker added to the login keychain (here,
    /// the self-test's keychain in memory), as any program of the user's can.
    static func secretsReplacedKeychainVaultChecks(_ base: URL) async {
        let keychain = MemoryKeychain()
        let (store, _) = secretsKeychainStore(base, "record-replaced-keychain", keychain: keychain)
        _ = try? await store.perform(.add(name: "KEYCHAIN_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                          value: SecretBytes(utf8: secretsValue("keychain-record"))))
        let theirs = SoftwareKeyring(kind: .keychain)
        try? keychain.item(LoginKeychain.vaultKeyAccount(publicKey: theirs.publicKey())).add(theirs.rawRepresentation)
        guard store.index != nil, let built = try? SecretVault.create(keyring: theirs),
              let planted = try? built.vault.add(name: "KEYCHAIN_KEY", purpose: "", purposeBy: .user, origin: .settings,
                                                 writeOnly: false, value: SecretBytes(utf8: secretsValue("planted"))) else {
            return check(false, "secrets: the replaced keychain vault is built")
        }
        built.vault.wipe()
        try? store.folder.write(SecretFolder.vaultName, data: planted)
        let (failures, unchanged) = await secretsWritesInto(store, planted: planted, name: "KEYCHAIN_KEY")
        let expected: [SecretsStore.Failure?] = [.vault(.tampered), .vault(.tampered)]
        let refused: Bool = failures == expected
        check(refused && unchanged && store.protection == .tampered,
              "secrets: a whole keychain vault.json whose key is in an item its maker added is refused as tampered, and nothing is written",
              "\(failures), unchanged \(unchanged), \(store.protection)")
    }

    /// A vault.json planted where Next Term never made one, its vault key wrapped under this Mac's own key (wrapping needs
    /// only the public key), by a program that wrote the file and left the login keychain alone: there is no record, so
    /// the first Add is refused as unlisted and the file is left as it was.
    static func secretsPlantedVaultChecks(_ base: URL) async {
        let keyring = SoftwareKeyring(kind: .secureEnclave)
        let (store, presence) = secretsStore(base, "record-planted", keyring: keyring)
        guard let built = try? SecretVault.create(keyring: keyring),
              let planted = try? built.vault.add(name: "PLANTED_KEY", purpose: "", purposeBy: .user, origin: .settings,
                                                 writeOnly: false, value: SecretBytes(utf8: secretsValue("planted"))) else {
            return check(false, "secrets: the planted vault is built")
        }
        built.vault.wipe()
        try? store.folder.ensure()
        try? store.folder.write(SecretFolder.vaultName, data: planted)
        let (failures, unchanged) = await secretsWritesInto(store, planted: planted, name: "PLANTED_KEY")
        let expected: [SecretsStore.Failure?] = [.vault(.unlisted), .vault(.unlisted)]
        let refused: Bool = failures == expected
        check(refused && unchanged && presence.calls == 2,
              "secrets: a vault.json planted where none was made, with no record written, is refused as unlisted at the first Add",
              "\(failures), unchanged \(unchanged), \(presence.calls) presence checks")
    }

    /// Start Over then Add lists the new vault and keeps the old one listed, so the kept vault put back, as from a
    /// backup, still opens.
    static func secretsRecordKeepsChecks(_ base: URL) async {
        let keyring = SoftwareKeyring(kind: .secureEnclave)
        let (store, _) = secretsStore(base, "record-kept", keyring: keyring)
        let first = secretsValue("kept-record")
        _ = try? await store.perform(.add(name: "FIRST_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                          value: SecretBytes(utf8: first)))
        let kept = try? store.startOver()
        _ = try? await store.perform(.add(name: "SECOND_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                          value: SecretBytes(utf8: secretsValue("second-record"))))
        let both: Bool = (store.record as? MemoryVaultRecord)?.contents?.count == 64
        var revealed: SecretBytes?
        if let kept, let data = try? Data(contentsOf: kept.appendingPathComponent(SecretFolder.vaultName)) {
            try? store.folder.write(SecretFolder.vaultName, data: data)
            await store.load()
            revealed = (try? await store.perform(.reveal(name: "FIRST_KEY")))?["FIRST_KEY"]
        }
        let opened: Bool = revealed == SecretBytes(utf8: first)
        check(both && opened, "secrets: Start Over then Add keeps the old vault listed, so the kept vault put back still opens",
              "both listed \(both), opened \(opened), \(store.protection)")
    }

    /// A record whose keychain prompt was refused, or that can't be read just now, is no tampering: the action fails,
    /// Secrets stays usable, and the next try works. A first Add whose record can't be written makes no vault.
    static func secretsRecordFailureChecks(_ base: URL) async {
        let keyring = SoftwareKeyring(kind: .secureEnclave)
        let record = MemoryVaultRecord()
        let folder = SecretFolder(applicationSupport: base.appendingPathComponent("record-failure", isDirectory: true))
        let store = SecretsStore(folder: folder, presence: StandInPresence(), newKeyring: { keyring }, keyring: { _ in keyring },
                                 record: record)
        let value = secretsValue("record-failure")
        let add: SecretsStore.Action = .add(name: "RECORD_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                            value: SecretBytes(utf8: value))
        record.failure = .cancelled
        let unmade = await secretsFailure(store, add)
        let noVault: Bool = store.index == nil && !FileManager.default.fileExists(atPath: store.folder.path(SecretFolder.vaultName))
        record.failure = nil
        let made: Bool = await secretsFailure(store, add) == nil
        check(unmade == .cancelled && noVault && made, "secrets: a first Add whose record is refused makes no vault, and the next Add makes one",
              "\(String(describing: unmade)), no vault \(noVault), made \(made)")

        let cases: [(SecretVault.Failure, SecretsStore.Failure)] = [(.cancelled, .cancelled), (.keyUnavailable, .vault(.keyUnavailable))]
        var wrong: [String] = []
        for (failure, expected) in cases {
            record.failure = failure
            let got = await secretsFailure(store, .reveal(name: "RECORD_KEY"))
            if got != expected || store.protection != .secureEnclave {
                wrong.append("\(failure): \(String(describing: got)), \(store.protection)")
            }
        }
        record.failure = nil
        let revealed = (try? await store.perform(.reveal(name: "RECORD_KEY")))?["RECORD_KEY"]
        let opened: Bool = revealed == SecretBytes(utf8: value)
        check(wrong.isEmpty && opened, "secrets: a record that can't be read just now is no tampering: Secrets stays usable and the next try opens",
              wrong.joined(separator: "; "))
    }

    /// The app's record is Next Term's own login-keychain item, checked here with no keychain call, and a refused prompt
    /// is a cancel; the self-test's store keeps its record in memory.
    static func secretsAppRecordChecks() {
        let item = SecretsStore.appRecord() as? LoginKeychainRecord
        let named: Bool = item?.service == LoginKeychain.service && item?.account == LoginKeychainRecord.account
        let inMemory: Bool = SecretsStore.shared.record is MemoryVaultRecord
        let statuses = [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed, errSecNotAvailable]
        let read: [SecretVault.Failure] = statuses.map { LoginKeychainRecord.failure($0) }
        let mapped: Bool = read == [.cancelled, .cancelled, .cancelled, .keyUnavailable]
        check(named && inMemory && mapped,
              "secrets: the app's record of its vaults is Next Term's login-keychain item, a refused prompt is a cancel, and the self-test's record is in memory",
              "\(item?.account ?? "no item"), in memory \(inMemory), \(read)")
    }
}
