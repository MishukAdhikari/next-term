import AppKit
import NextTermCore

#if DEBUG
/// Another copy of Next Term changing vault.json while this one works (review finding #12): a key it deletes ends this
/// copy's grants, whenever its write lands, and a grant never answers with it.
extension SelfTest {
    static func secretsOtherCopyChecks(_ base: URL) async {
        await secretsOtherCopyAfterLockChecks(base)
        await secretsOtherCopyDuringTouchIDChecks(base)
    }

    /// Another copy's change: vault.json opened with `keyring`, changed, and written under the vault's lock, as that
    /// copy's store writes it. On any thread.
    nonisolated static func secretsOtherCopyWrite(_ folder: SecretFolder, keyring: VaultKeyring,
                                                  _ change: (SecretVault) throws -> Data) {
        _ = try? folder.withLock {
            try folder.update { current in
                guard let current else { return nil }
                let vault = try SecretVault.unlock(current, keyring: keyring, context: nil)
                defer { vault.wipe() }
                return try change(vault)
            }
        }
    }

    /// A store over its own folder holding FIRST_KEY and SECOND_KEY, and the names it posts in `keysChanged` from then.
    private static func secretsTwoKeyStore(_ base: URL, _ name: String) async
        -> (store: SecretsStore, keyring: SoftwareKeyring, posted: SelfTestLines, observer: NSObjectProtocol) {
        let (store, keyring) = secretsRecordStore(base, name, record: MemoryVaultRecord())
        for key in ["FIRST_KEY", "SECOND_KEY"] {
            _ = try? await store.perform(.add(name: key, purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                              value: SecretBytes(utf8: secretsValue(key.lowercased()))))
        }
        let posted = SelfTestLines()
        let observer = NotificationCenter.default.addObserver(forName: SecretsStore.keysChanged, object: store, queue: nil) { note in
            for name in note.userInfo?["names"] as? [String] ?? [] { posted.append(name) }
        }
        return (store, keyring, posted, observer)
    }

    /// The other copy deletes SECOND_KEY just after this copy's change let the vault's lock go, before this copy took
    /// the result: vault.json's date this copy keeps is the one under the lock, so the next check reads the deletion.
    static func secretsOtherCopyAfterLockChecks(_ base: URL) async {
        let (store, keyring, posted, observer) = await secretsTwoKeyStore(base, "other-copy-after-lock")
        defer { NotificationCenter.default.removeObserver(observer) }
        let folder = store.folder
        store.afterLockForSelfTest = {
            secretsOtherCopyWrite(folder, keyring: keyring) { try $0.delete("SECOND_KEY") }
        }
        let failure = await secretsFailure(store, .edit(name: "FIRST_KEY", newName: nil, purpose: "A purpose", purposeBy: .user))
        store.afterLockForSelfTest = nil
        store.reloadIfChanged()
        let made: Bool = failure == nil && store.index?.entry(named: "FIRST_KEY") != nil
        let gone: Bool = store.index?.entry(named: "SECOND_KEY") == nil
        let ended: Bool = posted.lines.contains("SECOND_KEY")
        check(made && gone && ended,
              "secrets: a key another copy deletes just after this copy's change let the lock go is read at the next check, "
                  + "and its grants end",
              "\(String(describing: failure)), gone \(gone), posted \(posted.lines)")
    }

    /// The other copy deletes SECOND_KEY while Touch ID is asked for a change here: the change reads it under the lock,
    /// and its grants end as the change is saved, with no check needed after.
    static func secretsOtherCopyDuringTouchIDChecks(_ base: URL) async {
        let (store, keyring, posted, observer) = await secretsTwoKeyStore(base, "other-copy-touch-id")
        defer { NotificationCenter.default.removeObserver(observer) }
        guard let presence = store.presence as? StandInPresence else {
            return check(false, "secrets: the other-copy store has the stand-in presence check")
        }
        presence.holds = true
        let edit = Task { @MainActor in
            await secretsFailure(store, .edit(name: "FIRST_KEY", newName: nil, purpose: "Another purpose", purposeBy: .user))
        }
        let asked = await wait(10) { presence.isHolding }
        secretsOtherCopyWrite(store.folder, keyring: keyring) { try $0.delete("SECOND_KEY") }
        presence.holds = false
        presence.release(approving: true)
        let failure = await edit.value
        let gone: Bool = store.index?.entry(named: "SECOND_KEY") == nil
        let ended: Bool = posted.lines.contains("SECOND_KEY")
        check(asked && failure == nil && gone && ended,
              "secrets: a key another copy deletes while Touch ID is asked for a change here ends its grants when the change is saved",
              "asked \(asked), \(String(describing: failure)), gone \(gone), posted \(posted.lines)")
    }

    /// A grant holding a key another copy deleted never answers with it: `SecretRequests.ask` reads vault.json first,
    /// and the grant ends. The other copy's file is this one's from before the key was added, as its delete leaves it.
    static func secretsOtherCopyGrantChecks() async {
        let requests = SecretRequests.shared
        let store = SecretsStore.shared
        requests.resetForSelfTest()
        let earlierNow = requests.now
        defer {
            requests.resetForSelfTest()
            requests.now = earlierNow
        }
        requests.now = { .now }
        _ = try? await store.perform(.add(name: "COPY_KEEP_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                          value: SecretBytes(utf8: secretsValue("copy-keep"))))
        let withoutKey = try? store.folder.read(SecretFolder.vaultName, cap: SecretVault.maxFileSize)
        _ = try? await store.perform(.add(name: "COPY_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                          value: SecretBytes(utf8: secretsValue("copy"))))
        let first = secretsRequest(asker: "wrapper:selftest-other-copy", command: ["node", "copy.js"], names: ["COPY_KEY"], tab: "tab 3")
        requests.ask(first) { _ in }
        first.panel?.durationChoice[.fifteenMinutes]?.performClick(nil)
        first.panel?.allowButton.performClick(nil)
        let made = await wait(10) { !requests.heldGrants.isEmpty }
        if let withoutKey { _ = try? store.folder.withLock { try store.folder.write(SecretFolder.vaultName, data: withoutKey) } }
        let answers = SecretsAnswers()
        let again = secretsRequest(asker: "wrapper:selftest-other-copy", command: ["node", "copy.js"], names: ["COPY_KEY"], tab: "tab 3")
        requests.ask(again) { answers.take($0) }
        let fromGrant: Bool = secretsAllowed(answers.last)?.how == .grant
        let ended: Bool = requests.heldGrants.isEmpty && requests.book.grants.isEmpty
        check(withoutKey != nil && made && !fromGrant && ended,
              "secrets: a grant holding a key another copy deleted ends before it answers, and never hands the key out",
              "made \(made), from the grant \(fromGrant), ended \(ended)")
        _ = try? await store.perform(.delete(name: "COPY_KEEP_KEY"))
    }
}
#endif
