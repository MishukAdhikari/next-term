import AppKit
import CryptoKit
import NextTermCore
import Security

/// A record in memory whose reads run `onRead` first, on the thread that reads, and that can be lost, as the login
/// keychain's item is by a reset: the self-test's, never the login keychain.
final class SelfTestWatchedRecord: VaultRecord, @unchecked Sendable {
    let inner = MemoryVaultRecord()
    var onRead: (() -> Void)?
    /// True: there is no record, as when the item is gone.
    var gone = false

    func read() throws -> Data? {
        onRead?()
        let data = try inner.read()
        return gone ? nil : data
    }

    func write(_ data: Data) throws {
        try inner.write(data)
    }
}

/// Lines added from any thread, for a check to read after.
final class SelfTestLines: @unchecked Sendable {
    private var all: [String] = []
    private let lock = NSLock()

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        all.append(line)
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return all
    }
}

/// What the record of the vaults made here leaves after a refusal, a failed first Add, and every use of a replaced vault.
extension SelfTest {
    static func secretsRecordStateChecks(_ base: URL) async {
        await secretsUnlistedChecks(base)
        await secretsRecordWaitChecks(base)
        await secretsFailedFirstAddRecordChecks(base)
        await secretsReplacedVaultUseChecks(base)
        await secretsReplacedVaultRemarkChecks(base)
        secretsPinnedKeychainChecks()
    }

    /// A Secure Enclave store over its own folder whose record is `record`.
    static func secretsRecordStore(_ base: URL, _ name: String, record: VaultRecord) -> (SecretsStore, SoftwareKeyring) {
        let keyring = SoftwareKeyring(kind: .secureEnclave)
        let folder = SecretFolder(applicationSupport: base.appendingPathComponent(name, isDirectory: true))
        let store = SecretsStore(folder: folder, presence: StandInPresence(), newKeyring: { keyring }, keyring: { _ in keyring },
                                 record: record)
        return (store, keyring)
    }

    /// A vault Next Term made, whose record is then gone (the login keychain reset): refused, but as unlisted, whose text
    /// says the record is missing, never that the file changed, and Start Over clears it.
    static func secretsUnlistedChecks(_ base: URL) async {
        let record = SelfTestWatchedRecord()
        let (store, _) = secretsRecordStore(base, "record-gone", record: record)
        _ = try? await store.perform(.add(name: "GONE_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                          value: SecretBytes(utf8: secretsValue("record-gone"))))
        let made: Bool = store.index != nil && record.inner.writes == 1
        record.gone = true
        await store.load()
        let first = await secretsFailure(store, .reveal(name: "GONE_KEY"))
        let again = await secretsFailure(store, .reveal(name: "GONE_KEY"))
        let text = SecretsView.statusText(store.protection, waitingForKeychain: false, unlisted: store.isUnlisted)
        let said: Bool = text == SecretsView.unlistedLine && text != SecretsView.tamperedLine
        let bothUnlisted: Bool = first == .vault(.unlisted) && again == .vault(.unlisted)
        let refused: Bool = bothUnlisted && store.protection == .tampered
        let line: Bool = secretsAudit(store).last?.event == .tamper && record.inner.writes == 1
        _ = try? store.startOver()
        let cleared: Bool = !store.isUnlisted && store.protection == .none
        check(made && refused && said && line && cleared,
              "secrets: a vault whose record is gone is refused as unlisted, with its own text, not the tamper text, until Start Over",
              "\(String(describing: first)), \(String(describing: again)), \(store.protection), said \(said), cleared \(cleared)")
    }

    /// Every unlock and first Add reads the record in the login keychain, which may ask for its password: Settings says
    /// "Waiting for the keychain…" while it is read, for a Secure Enclave vault too.
    static func secretsRecordWaitChecks(_ base: URL) async {
        let record = SelfTestWatchedRecord()
        let (store, _) = secretsRecordStore(base, "record-wait", record: record)
        let seen = SelfTestLines()
        record.onRead = { [weak store] in
            let waiting = DispatchQueue.main.sync { MainActor.assumeIsolated { store?.isWaitingForKeychain ?? false } }
            seen.append(waiting ? "waiting" : "not waiting")
        }
        _ = try? await store.perform(.add(name: "WAIT_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                          value: SecretBytes(utf8: secretsValue("record-wait"))))
        _ = try? await store.perform(.reveal(name: "WAIT_KEY"))
        record.onRead = nil
        let reads = seen.lines
        let shown: Bool = reads == ["waiting", "waiting"] && !store.isWaitingForKeychain
        check(shown, "secrets: Settings says Waiting for the keychain while a Secure Enclave vault's record is read, and not after",
              reads.joined(separator: ", "))
    }

    /// A first Add that fails on its value lists nothing: repeated, it never pushes the vaults made before off the record.
    static func secretsFailedFirstAddRecordChecks(_ base: URL) async {
        let record = MemoryVaultRecord()
        let (store, _) = secretsRecordStore(base, "record-failed-add", record: record)
        var failures: [SecretsStore.Failure?] = []
        for _ in 0..<3 {
            let bad: SecretsStore.Action = .add(name: "BAD_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                                value: SecretBytes(utf8: "two\nlines"))
            failures.append(await secretsFailure(store, bad))
        }
        let listedNothing: Bool = record.writes == 0 && record.contents == nil
        let good: SecretsStore.Action = .add(name: "GOOD_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                             value: SecretBytes(utf8: secretsValue("after-failed-adds")))
        let made: Bool = await secretsFailure(store, good) == nil
        let listedOne: Bool = record.writes == 1 && record.contents?.count == 32
        let badValue: Bool = failures.allSatisfy { $0 == .vault(.badValue("BAD_KEY")) }
        check(badValue && listedNothing && made && listedOne,
              "secrets: a first Add that fails on its value lists no vault in the record, and the next Add lists one",
              "\(failures), \(record.writes) writes, made \(made)")
    }

    /// A store holding a listed vault named `name`, whose vault.json is then replaced by one built around a vault key
    /// and keyring of its maker's: the store and the planted bytes, or nil when it couldn't be built.
    static func secretsReplacedStore(_ base: URL, _ folderName: String, name: String) async -> (SecretsStore, Data)? {
        let keyring = SoftwareKeyring(kind: .secureEnclave)
        let theirs = SoftwareKeyring(kind: .secureEnclave)
        let folder = SecretFolder(applicationSupport: base.appendingPathComponent(folderName, isDirectory: true))
        let store = SecretsStore(folder: folder, presence: StandInPresence(), newKeyring: { keyring },
                                 keyring: { $0.publicKey == theirs.publicKey() ? theirs : keyring }, record: MemoryVaultRecord())
        _ = try? await store.perform(.add(name: name, purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                          value: SecretBytes(utf8: secretsValue("replaced-use"))))
        guard store.index != nil, let built = try? SecretVault.create(keyring: theirs),
              let planted = try? built.vault.add(name: name, purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                                 value: SecretBytes(utf8: secretsValue("planted-use"))) else { return nil }
        built.vault.wipe()
        try? store.folder.write(SecretFolder.vaultName, data: planted)
        return (store, planted)
    }

    /// Reveal, copy and use, the import and Undo on a replaced vault: each is refused as tampered, releases nothing, hands
    /// Undo nothing to put back, and leaves vault.json as it was.
    static func secretsReplacedVaultUseChecks(_ base: URL) async {
        guard let (store, planted) = await secretsReplacedStore(base, "record-replaced-uses", name: "USED_KEY") else {
            return check(false, "secrets: the replaced vault for the use checks is built")
        }
        var wrong: [String] = []
        let uses: [SecretsStore.Action] = [.reveal(name: "USED_KEY"), .copy(name: "USED_KEY"), .use(names: ["USED_KEY"])]
        for action in uses {
            await store.load()
            var released: [String: SecretBytes]?
            var failure: SecretsStore.Failure?
            do { released = try await store.perform(action) } catch { failure = error as? SecretsStore.Failure }
            if failure != .vault(.tampered) || released != nil { wrong.append("\(action.event): \(String(describing: failure))") }
        }
        await store.load()
        let key = SecretsStore.ImportKey(name: "IMPORTED_KEY", purpose: "", value: SecretBytes(utf8: secretsValue("imported")))
        do {
            _ = try await store.performImport([key], kept: [:], reason: "import")
            wrong.append("import: done")
        } catch {
            if error as? SecretsStore.Failure != .vault(.tampered) { wrong.append("import: \(error)") }
        }
        await store.load()
        let handed = SelfTestLines()
        do {
            try await store.performUndo(names: ["USED_KEY"], kept: [:], delete: true, reason: "undo") { values, _ in
                handed.append("put \(values.count)")
                return Set(values.keys)
            }
            wrong.append("undo: done")
        } catch {
            if error as? SecretsStore.Failure != .vault(.tampered) { wrong.append("undo: \(error)") }
        }
        let bytes = try? store.folder.read(SecretFolder.vaultName, cap: SecretVault.maxFileSize)
        let unchanged: Bool = bytes == planted && handed.lines.isEmpty
        check(wrong.isEmpty && unchanged,
              "secrets: reveal, copy, use, the import and Undo on a replaced vault are refused as tampered and release nothing",
              (wrong + handed.lines).joined(separator: "; "))
    }

    /// A replaced vault whose mask.key is gone: the unlock that would mark its entries again refuses it first, so neither
    /// vault.json nor mask.key is written.
    static func secretsReplacedVaultRemarkChecks(_ base: URL) async {
        guard let (store, planted) = await secretsReplacedStore(base, "record-replaced-remark", name: "MARKED_KEY") else {
            return check(false, "secrets: the replaced vault for the re-mark check is built")
        }
        try? FileManager.default.removeItem(atPath: store.folder.path(SecretFolder.maskKeyName))
        await store.load()
        let failure = await secretsFailure(store, .add(name: "NEW_KEY", purpose: "", purposeBy: .user, origin: .request,
                                                       writeOnly: true, value: SecretBytes(utf8: secretsValue("remark"))))
        let bytes = try? store.folder.read(SecretFolder.vaultName, cap: SecretVault.maxFileSize)
        let noMaskKey: Bool = !FileManager.default.fileExists(atPath: store.folder.path(SecretFolder.maskKeyName))
        let refused: Bool = failure == .vault(.tampered)
        let unchanged: Bool = bytes == planted
        check(refused && unchanged && noMaskKey,
              "secrets: a replaced vault with mask.key gone is refused before its entries are marked again, and nothing is written",
              "\(String(describing: failure)), unchanged \(unchanged), no mask.key \(noMaskKey)")
    }

    /// The app's login-keychain items, record and vault keys alike, are searched, changed and deleted in the login keychain
    /// alone, and added to it, never to the default keychain: a keychain put ahead of it in the search list, or made the
    /// default, is never used. Checked on the queries, with no keychain call.
    static func secretsPinnedKeychainChecks() {
        let login = LoginKeychain.login
        func searchesLogin(_ query: [String: Any]?) -> Bool {
            guard let login, let list = query?[kSecMatchSearchList as String] as? [SecKeychain], list.count == 1 else { return false }
            return list[0] === login
        }
        func addsToLogin(_ item: [String: Any]?) -> Bool {
            guard let login, let keychain = item?[kSecUseKeychain as String] else { return false }
            return (keychain as AnyObject) === login
        }
        let record = LoginKeychainRecord()
        let item = LoginKeychain(account: LoginKeychain.vaultKeyAccount(publicKey: Data(repeating: 4, count: 65)))
        let path: Bool = LoginKeychain.loginPath.hasSuffix("/Library/Keychains/login.keychain-db")
        let recordPinned: Bool = searchesLogin(record.searchQuery) && addsToLogin(record.addQuery)
        let itemPinned: Bool = searchesLogin(item.searchQuery) && addsToLogin(item.addQuery)
        check(path && recordPinned && itemPinned,
              "secrets: the record and the vault keys are searched in and added to the login keychain alone, never another",
              "path \(path), record \(recordPinned), item \(itemPinned)")
    }
}
