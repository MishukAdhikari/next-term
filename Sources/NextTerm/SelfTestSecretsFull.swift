import AppKit
import NextTermCore

#if DEBUG
/// A vault.json past the 8 MB read cap, as a copy before the write cap could leave it (review finding #10).
extension SelfTest {
    /// Too large, not tampered: Settings says so, an action is refused with it, the grants holding its keys end, a
    /// launch reads it the same, and Start Over clears it.
    static func secretsTooLargeChecks(_ base: URL) async {
        let (store, _) = secretsRecordStore(base, "too-large", record: MemoryVaultRecord())
        _ = try? await store.perform(.add(name: "LARGE_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                          value: SecretBytes(utf8: secretsValue("too-large"))))
        let posted = SelfTestLines()
        let observer = NotificationCenter.default.addObserver(forName: SecretsStore.keysChanged, object: store, queue: nil) { note in
            for name in note.userInfo?["names"] as? [String] ?? [] { posted.append(name) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let big = Data(repeating: UInt8(ascii: " "), count: SecretVault.maxFileSize + 1)
        let wrote: Bool = (try? store.folder.withLock { try store.folder.write(SecretFolder.vaultName, data: big) }) != nil
        store.reloadIfChanged()
        let text = SecretsView.statusText(store.protection, waitingForKeychain: false, unlisted: store.isUnlisted,
                                          tooLarge: store.isTooLarge)
        let said: Bool = store.isTooLarge && store.protection == .tampered && text == SecretsView.tooLargeLine
        let failure = await secretsFailure(store, .reveal(name: "LARGE_KEY"))
        await store.load()
        let atLaunch: Bool = store.isTooLarge && store.protection == .tampered
        _ = try? store.startOver()
        let cleared: Bool = !store.isTooLarge && store.protection == .none
        check(wrote && said && failure == .vault(.tooLarge) && posted.lines == ["LARGE_KEY"] && atLaunch && cleared,
              "secrets: a vault.json past the read cap is too large, not tampered, its grants end, and Start Over clears it",
              "said \(said), \(String(describing: failure)), posted \(posted.lines), launch \(atLaunch), cleared \(cleared)")
    }
}
#endif
