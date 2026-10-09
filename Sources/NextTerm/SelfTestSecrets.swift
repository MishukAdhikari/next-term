import AppKit
import NextTermCore

/// Secrets on temporary vaults only: the store, masking, the panel and grants, the wrapper. The self-test's store works
/// on a temporary folder with a software keyring and a presence check that passes and counts; the real
/// `Secrets.noindex`, `mask.key`, socket, login keychain and clipboard are never touched, and lock events are injected,
/// never posted.
extension SelfTest {
    static func secretsChecks(_ c: TerminalWindowController, proj: URL) async {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-secrets-checks-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: SecretsStore.shared.folder.url.deletingLastPathComponent().deletingLastPathComponent())
        }
        let realFolder = SecretFolder(applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
        let realBefore = secretsFolderDate(realFolder.url)
        await secretsStoreChecks(base)
        check(secretsFolderDate(realFolder.url) == realBefore, "secrets: the real Secrets.noindex is untouched (unchanged, or not there)",
              "\(String(describing: realBefore)) → \(String(describing: secretsFolderDate(realFolder.url)))")
    }

    /// The folder's own modification date, without following a link; nil when nothing is there.
    static func secretsFolderDate(_ url: URL) -> Date? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
    }

    /// A store over its own temporary folder, with its own keyring and presence check.
    static func secretsStore(_ base: URL, _ name: String, keyring: VaultKeyring) -> (SecretsStore, StandInPresence) {
        let presence = StandInPresence()
        let folder = SecretFolder(applicationSupport: base.appendingPathComponent(name, isDirectory: true))
        return (SecretsStore(folder: folder, presence: presence, newKeyring: { keyring }, keyring: { _ in keyring }), presence)
    }

    /// `file` with the body's first entry changed by `edit` and the old MAC kept: a hand that changed the file.
    static func secretsTampered(_ file: Data, _ edit: (inout [String: Any]) -> Void) -> Data? {
        guard var outer = try? JSONSerialization.jsonObject(with: file) as? [String: Any],
              let bodyText = outer["body"] as? String, let bodyData = Data(base64Encoded: bodyText),
              var body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              var entries = body["entries"] as? [[String: Any]], !entries.isEmpty else { return nil }
        edit(&entries[0])
        body["entries"] = entries
        guard let changed = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        outer["body"] = changed.base64EncodedString()
        return try? JSONSerialization.data(withJSONObject: outer)
    }

    static func secretsAudit(_ store: SecretsStore) -> [SecretAudit.Line] {
        SecretAudit.lines(in: store.folder.readAudit())
    }

    // MARK: U2, the store

    static func secretsStoreChecks(_ base: URL) async {
        let store = SecretsStore.shared
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
        check(store.folder.url.path.hasPrefix(NSTemporaryDirectory()) && !store.folder.url.path.hasPrefix(support),
              "secrets: the self-test's store works on a temporary folder", store.folder.url.path)
        guard let presence = store.presence as? StandInPresence else {
            return check(false, "secrets: the self-test's store has the stand-in presence check")
        }
        let token = "ghp_selftestvalue0123456789abcdefghijkl"
        func auditHolds(_ value: String) -> Bool { String(decoding: store.folder.readAudit(), as: UTF8.self).contains(value) }

        // The first add makes the vault: vault.json and a 32-byte mask.key, both 0600, mask.key out of backups.
        let calls = presence.calls
        let added = (try? await store.perform(.add(name: "GITHUB_TOKEN", purpose: "GitHub MCP server", purposeBy: .user,
                                                   origin: .settings, writeOnly: false, value: SecretBytes(utf8: token)))) != nil
        let vaultPath = store.folder.path(SecretFolder.vaultName)
        let maskPath = store.folder.path(SecretFolder.maskKeyName)
        func mode(_ path: String) -> mode_t {
            var info = stat()
            return lstat(path, &info) == 0 ? info.st_mode & 0o777 : 0
        }
        let maskSize = (try? fm.attributesOfItem(atPath: maskPath)[.size] as? Int) ?? 0
        let excluded = (try? URL(fileURLWithPath: maskPath).resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
        check(added && mode(vaultPath) == 0o600 && mode(maskPath) == 0o600 && maskSize == 32 && excluded,
              "secrets: the first add writes vault.json and a 32-byte mask.key, both 0600, mask.key excluded from backup",
              "added \(added), modes \(String(mode(vaultPath), radix: 8)) \(String(mode(maskPath), radix: 8)), \(maskSize) bytes, excluded \(excluded)")
        check(presence.calls == calls + 1 && store.index?.names == ["GITHUB_TOKEN"] && store.protection == .secureEnclave,
              "secrets: one presence check for the add, and the key is listed", "\(presence.calls - calls) checks, \(store.index?.names ?? [])")

        // Each change through perform writes one audit line, with no value in it.
        let replacement = "ghp_replacedvalue0123456789abcdefghijk"
        let steps: [(String, SecretsStore.Action, SecretAudit.Event)] = [
            ("edit", .edit(name: "GITHUB_TOKEN", newName: nil, purpose: "GitHub, for the MCP server", purposeBy: .user), .edit),
            ("replace", .replace(name: "GITHUB_TOKEN", value: SecretBytes(utf8: replacement), writeOnly: false, origin: nil), .replace),
            ("reveal", .reveal(name: "GITHUB_TOKEN"), .reveal),
            ("make write-only", .makeWriteOnly(name: "GITHUB_TOKEN"), .writeOnly),
            ("delete", .delete(name: "GITHUB_TOKEN"), .delete),
        ]
        for (label, action, event) in steps {
            let before = secretsAudit(store).count
            let values = try? await store.perform(action)
            let lines = secretsAudit(store)
            check(values != nil && lines.count == before + 1 && lines.last?.event == event && !auditHolds(token) && !auditHolds(replacement),
                  "secrets: \(label) writes one audit line, with no value", "\(lines.count - before) lines, last \(lines.last?.event.rawValue ?? "none")")
            if label == "reveal" {
                check(values?["GITHUB_TOKEN"] == SecretBytes(utf8: replacement), "secrets: reveal gives the replaced value")
            }
        }

        // A cancelled presence check writes nothing.
        _ = try? await store.perform(.add(name: "STRIPE_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                          value: SecretBytes(utf8: "sk_test-selftest0123456789abcdef")))
        let bytes = fm.contents(atPath: vaultPath)
        let audit = store.folder.readAudit()
        presence.approves = false
        var refusal: SecretsStore.Failure?
        do { try await store.perform(.delete(name: "STRIPE_KEY")) } catch { refusal = error as? SecretsStore.Failure }
        presence.approves = true
        check(refusal == .cancelled && fm.contents(atPath: vaultPath) == bytes && store.folder.readAudit() == audit,
              "secrets: a cancelled presence check writes nothing, to the vault or the audit log", "\(String(describing: refusal))")
        _ = try? await store.perform(.delete(name: "STRIPE_KEY"))

        await secretsTamperChecks(base)
        await secretsStartOverChecks(base)
        await secretsKeychainChecks(base)
        secretsLockEventChecks(store)
    }

    /// A planted vault with a changed purpose, and one made with another keyring.
    static func secretsTamperChecks(_ base: URL) async {
        let keyring = SoftwareKeyring(kind: .secureEnclave)
        let (store, presence) = secretsStore(base, "tampered", keyring: keyring)
        try? store.folder.ensure()
        guard let made = try? SecretVault.create(keyring: keyring),
              let file = try? made.vault.add(name: "DEPLOY_TOKEN", purpose: "deploys", purposeBy: .user, origin: .settings,
                                             writeOnly: false, value: SecretBytes(utf8: "deploy-selftest-0123456789abcdef")),
              let planted = secretsTampered(file, { $0["purpose"] = "changed by hand" }) else {
            return check(false, "secrets: the tampered vault is planted")
        }
        try? store.folder.write(SecretFolder.vaultName, data: planted)
        await store.load()
        var refusal: SecretsStore.Failure?
        var released: [String: SecretBytes]?
        do { released = try await store.perform(.use(names: ["DEPLOY_TOKEN"])) } catch { refusal = error as? SecretsStore.Failure }
        let tamperLine = secretsAudit(store).last
        check(refusal == .vault(.tampered) && released == nil && store.protection == .tampered && tamperLine?.event == .tamper,
              "secrets: a planted vault.json with a changed purpose releases nothing, and writes a tamper line",
              "\(String(describing: refusal)), protection \(store.protection), last line \(tamperLine?.event.rawValue ?? "none")")
        check(presence.calls == 1, "secrets: the tampered vault was found at its one use", "\(presence.calls) presence checks")

        // keyBlob and publicKey from another keyring: can't open, found at load() with no presence call.
        let (other, otherPresence) = secretsStore(base, "another-mac", keyring: SoftwareKeyring(kind: .secureEnclave))
        try? other.folder.ensure()
        try? other.folder.write(SecretFolder.vaultName, data: file)
        await other.load()
        check(other.protection == .cantOpen && otherPresence.calls == 0,
              "secrets: a vault made by another keyring can't open, found at load() with no presence check",
              "protection \(other.protection), \(otherPresence.calls) presence checks")
    }

    /// Start Over twice on one day keeps both old folders, and leaves an empty one.
    static func secretsStartOverChecks(_ base: URL) async {
        let keyring = SoftwareKeyring(kind: .secureEnclave)
        let (store, _) = secretsStore(base, "start-over", keyring: keyring)
        _ = try? await store.perform(.add(name: "FIRST_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                          value: SecretBytes(utf8: "first-selftest-0123456789abcdef")))
        let day = Date()
        let first = try? store.startOver(on: day)
        _ = try? await store.perform(.add(name: "SECOND_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                          value: SecretBytes(utf8: "second-selftest-0123456789abcdef")))
        let second = try? store.startOver(on: day)
        let name = SecretFolder.day(of: day)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: store.folder.url.path)) ?? ["?"]
        check(first?.lastPathComponent == "Secrets-\(name).old.noindex" && second?.lastPathComponent == "Secrets-\(name)-2.old.noindex",
              "secrets: Start Over twice on one day keeps both old folders",
              "\(first?.lastPathComponent ?? "none"), \(second?.lastPathComponent ?? "none")")
        check(left.allSatisfy { $0.hasPrefix("audit.log") } && store.index == nil && store.protection == .none,
              "secrets: Start Over leaves an empty Secrets, its log saying so", left.joined(separator: ", "))
    }

    /// The keychain keyring's rules over an in-memory store: never the login keychain.
    static func secretsKeychainChecks(_ base: URL) async {
        let memory = MemoryPasswordStore()
        let presence = StandInPresence()
        let folder = SecretFolder(applicationSupport: base.appendingPathComponent("keychain", isDirectory: true))
        let store = SecretsStore(folder: folder, presence: presence, newKeyring: { try KeychainKeyring.make(store: memory) },
                                 keyring: { _ in KeychainKeyring(store: memory) })
        let value = "keychain-selftest-0123456789abcdef"
        _ = try? await store.perform(.add(name: "KEYCHAIN_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                          value: SecretBytes(utf8: value)))
        check(memory.writes == 1 && memory.reads == 0 && store.protection == .lessProtected,
              "secrets: the keychain keyring writes its item once, at the first add", "\(memory.writes) writes, \(memory.reads) reads")
        presence.approves = false
        _ = try? await store.perform(.reveal(name: "KEYCHAIN_KEY"))
        presence.approves = true
        check(memory.reads == 0, "secrets: a cancelled presence check reads nothing from the keychain", "\(memory.reads) reads")
        let revealed = try? await store.perform(.reveal(name: "KEYCHAIN_KEY"))
        check(revealed?["KEYCHAIN_KEY"] == SecretBytes(utf8: value) && memory.reads == 1,
              "secrets: after the presence check the keychain keyring reads its item and opens the vault", "\(memory.reads) reads")
        await store.load()
        check(memory.reads == 1 && store.protection == .lessProtected, "secrets: the keychain keyring's load check never reads the item",
              "\(memory.reads) reads")
        try? memory.delete()
        await store.load()
        check(store.protection == .cantOpen, "secrets: a deleted keychain item gives can't open at load()", "\(store.protection)")
    }

    /// Lock events come through `handleLockEvent(_:)`; the distributed lock notification is never posted.
    static func secretsLockEventChecks(_ store: SecretsStore) {
        var posted: [SecretsStore.LockEvent] = []
        var distributed = 0
        let local = NotificationCenter.default.addObserver(forName: SecretsStore.locked, object: nil, queue: nil) { note in
            if let event = note.userInfo?["event"] as? SecretsStore.LockEvent { posted.append(event) }
        }
        let lock = DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil,
                                                                       queue: nil) { _ in distributed += 1 }
        store.handleLockEvent(.screenLocked)
        store.handleLockEvent(.systemSleep)
        store.handleLockEvent(.sessionResigned)
        store.handleLockEvent(.displaySleep)
        NotificationCenter.default.removeObserver(local)
        DistributedNotificationCenter.default().removeObserver(lock)
        check(posted == [.screenLocked, .systemSleep, .sessionResigned] && distributed == 0,
              "secrets: a lock, a sleep and the session resigning post locked; the display sleeping doesn't, and nothing is posted to other apps",
              "\(posted), \(distributed) distributed")
    }
}
