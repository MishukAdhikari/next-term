import AppKit
import CryptoKit
import NextTermCore
import UserNotifications

/// Secrets on temporary vaults only: the store, masking, the panel and grants, the wrapper. The self-test's store works
/// on a temporary folder with a software keyring and a presence check that passes and counts; the real
/// `Secrets.noindex`, `mask.key`, socket, login keychain and clipboard are never touched, and lock events are injected,
/// never posted.
extension SelfTest {
    /// A debug build's: a release build has no wrapper self-test form, so there the part would fail its wrapper checks
    /// and could only type a ticket line for the real socket.
    static func secretsChecks(_ c: TerminalWindowController, proj: URL) async {
        #if DEBUG
        await secretsDebugBuildChecks(c, proj: proj)
        #else
        note("secrets: skipped in a release build, which has no wrapper self-test form; scripts/selftest.sh's debug build runs them")
        #endif
    }

    private static func secretsDebugBuildChecks(_ c: TerminalWindowController, proj: URL) async {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-secrets-checks-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: base)
            // The self-test store's own temporary folder, and only that: never a folder outside the temporary one.
            let storeBase = SecretsStore.shared.folder.url.deletingLastPathComponent().deletingLastPathComponent()
            if storeBase.lastPathComponent.hasPrefix("nt-secrets-"), storeBase.path.hasPrefix(canonicalPath(NSTemporaryDirectory()))
                || storeBase.path.hasPrefix(NSTemporaryDirectory()) {
                try? FileManager.default.removeItem(at: storeBase)
            }
        }
        let realFolder = SecretFolder(applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
        let realBefore = secretsFolderDate(realFolder.url)
        let savedMask = SecretMask.current
        // The tabs and windows run_with_secrets opens come forward at once: the self-test's own keys would hold them back.
        let keysIgnored = UserKeys.ignoredForTest
        UserKeys.ignoredForTest = true
        defer {
            SecretMask.current = savedMask
            UserKeys.ignoredForTest = keysIgnored
            SecretClipboard.shared.pasteboard.releaseGlobally()
        }
        await secretsStoreChecks(base)
        await secretsMaskingChecks(c, base: base)
        await secretsPanelChecks(base)
        #if DEBUG
        await secretsAllowOnceChecks()
        #endif
        await secretsWrapperChecks(base)
        await secretsToolChecks(c, base: base, proj: proj)
        await secretsSettingsChecks(base: base)
        await secretsImportChecks(base: base)
        await secretsRemoteChecks(proj: proj)
        check(secretsFolderDate(realFolder.url) == realBefore, "secrets: the real Secrets.noindex is untouched (unchanged, or not there)",
              "\(String(describing: realBefore)) → \(String(describing: secretsFolderDate(realFolder.url)))")
    }

    /// The folder's own modification date, without following a link; nil when nothing is there.
    static func secretsFolderDate(_ url: URL) -> Date? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
    }

    /// A store over its own temporary folder, with its own keyring, record in memory and presence check.
    static func secretsStore(_ base: URL, _ name: String, keyring: VaultKeyring) -> (SecretsStore, StandInPresence) {
        let presence = StandInPresence()
        let folder = SecretFolder(applicationSupport: base.appendingPathComponent(name, isDirectory: true))
        let store = SecretsStore(folder: folder, presence: presence, newKeyring: { keyring }, keyring: { _ in keyring },
                                 record: MemoryVaultRecord())
        return (store, presence)
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

    // MARK: the store

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
        await secretsRecordChecks(base)
        await secretsStartOverChecks(base)
        await secretsRemarkChecks(base)
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

    /// A missing mask.key is made again at the next unlock, with new marks for every entry, and they stay when that
    /// action then fails.
    static func secretsRemarkChecks(_ base: URL) async {
        let (store, _) = secretsStore(base, "remark", keyring: SoftwareKeyring(kind: .secureEnclave))
        defer { SecretsStore.shared.publishMarks() } // the shared store's marks again
        let value = secretsValue("remark")
        _ = try? await store.perform(.add(name: "REMARK_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                          value: SecretBytes(utf8: value)))
        try? FileManager.default.removeItem(atPath: store.folder.path(SecretFolder.maskKeyName))
        var failure: SecretsStore.Failure?
        do { try await store.perform(.delete(name: "NOT_STORED")) } catch { failure = error as? SecretsStore.Failure }
        let key = try? store.folder.read(SecretFolder.maskKeyName, cap: 64)
        let file = try? store.folder.read(SecretFolder.vaultName, cap: SecretVault.maxFileSize)
        var masked = "no mask"
        if let key, let file, let index = try? SecretVault.index(from: file) {
            masked = SecretMask(key: SymmetricKey(data: key), index: index).mask("printed \(value) here")
        }
        check(failure == .vault(.noSuchKey("NOT_STORED")) && key?.count == 32 && masked.contains("•••") && !masked.contains(value),
              "secrets: a missing mask.key is made again at the next unlock with new marks, which stay when that action fails",
              "\(String(describing: failure)), \(key?.count ?? 0) bytes")
    }

    /// The keychain keyring's rules over an in-memory keychain: never the login keychain.
    static func secretsKeychainChecks(_ base: URL) async {
        let keychain = MemoryKeychain()
        let (store, presence) = secretsKeychainStore(base, "keychain", keychain: keychain)
        let value = "keychain-selftest-0123456789abcdef"
        _ = try? await store.perform(.add(name: "KEYCHAIN_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                          value: SecretBytes(utf8: value)))
        let own = store.index.map { LoginKeychain.vaultKeyAccount(publicKey: $0.publicKey) }
        let ownOnly: Bool = keychain.accounts == own.map { [$0] }
        check(keychain.writes == 1 && keychain.reads == 0 && ownOnly && store.protection == .lessProtected,
              "secrets: the keychain keyring writes its item once, at the first add, under the vault's own account",
              "\(keychain.writes) writes, \(keychain.reads) reads, \(keychain.accounts.joined(separator: ", "))")
        presence.approves = false
        _ = try? await store.perform(.reveal(name: "KEYCHAIN_KEY"))
        presence.approves = true
        check(keychain.reads == 0, "secrets: a cancelled presence check reads nothing from the keychain", "\(keychain.reads) reads")
        let revealed = try? await store.perform(.reveal(name: "KEYCHAIN_KEY"))
        check(revealed?["KEYCHAIN_KEY"] == SecretBytes(utf8: value) && keychain.reads == 1,
              "secrets: after the presence check the keychain keyring reads its item and opens the vault", "\(keychain.reads) reads")
        await store.load()
        check(keychain.reads == 1 && store.protection == .lessProtected, "secrets: the keychain keyring's load check never reads the item",
              "\(keychain.reads) reads")
        if let own { try? keychain.item(own).delete() }
        await store.load()
        check(store.protection == .cantOpen, "secrets: a deleted keychain item gives can't open at load()", "\(store.protection)")
        await secretsKeychainItemChecks(base)
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

/// An agent's `nxtrm mcp` bridge, for the Secrets checks: a tool's answer text and whether it is an error.
final class SecretsMCPClient {
    let mcp: MCPTestClient
    private var next = 700

    init?(socket: String) {
        guard let mcp = MCPTestClient(socket: socket) else { return nil }
        self.mcp = mcp
    }

    @MainActor
    func start() async {
        _ = await mcp.call(next, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "selftest", "version": "1"]])
    }

    @MainActor
    func call(_ name: String, _ arguments: [String: Any] = [:], timeout: Double = 30) async -> (text: String, isError: Bool) {
        next += 1
        let reply = await mcp.call(next, "tools/call", ["name": name, "arguments": arguments], timeout: timeout)
        let result = reply?["result"] as? [String: Any]
        let error = (reply?["error"] as? [String: Any])?["message"] as? String
        let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? error ?? "(no answer)"
        return (text, result?["isError"] as? Bool ?? true)
    }

    func close() { mcp.close() }
}

extension SelfTest {
    // MARK: masking

    /// A random value for a check, never typed: written to a file the tab reads with `K=$(cat …)`.
    static func secretsValue(_ prefix: String) -> String {
        prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + "Q7"
    }

    /// Closes a check's tabs without asking, as close_tab force does: a wrapper or a fake agent may still run
    /// in one, and asking would leave a "Close tab?" sheet up for the checks that come after. None may be left.
    static func closeSecretsTabs(_ tabs: [TerminalTab], _ what: String) {
        var windows: [NSWindow] = []
        for tab in tabs {
            guard let c = MCPControl.controller(of: tab) else { continue }
            if let window = c.window { windows.append(window) }
            c.remove(tab)
        }
        let asking = windows.filter { $0.attachedSheet != nil }
        check(asking.isEmpty, "secrets: closing the \(what) tabs leaves no sheet up",
              asking.map(sheetText).joined(separator: "; "))
    }

    /// Stored keys are masked in what agents read and in notifications, from the marks alone, with no unlock.
    static func secretsMaskingChecks(_ c: TerminalWindowController, base: URL) async {
        let app = AppDelegate.shared!
        check(SecretsStore.marksLoadedBeforeSocket, "secrets: the marks were loaded before the MCP socket started")
        defer { MCPControl.fieldMasks = true }

        // A vault with one value, made with a software keyring, and its mask.key, in a folder of its own; then the
        // marks alone, as at launch.
        let value = secretsValue("ntmask")
        let keyring = SoftwareKeyring(kind: .secureEnclave)
        let (store, presence) = secretsStore(base, "marks", keyring: keyring)
        guard let made = try? SecretVault.create(keyring: keyring) else { return check(false, "secrets: a vault for the masking checks") }
        let maskData = made.maskKey.withUnsafeBytes { Data($0) }
        let file = try? made.vault.add(name: "MASK_PROBE", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                       value: SecretBytes(utf8: value), maskKey: SymmetricKey(data: maskData))
        // A value whose quotes an answer's JSON escapes, so the pass over its text alone misses it.
        let quotedToken = secretsValue("ntjson")
        let quoted = #"{"client":""# + quotedToken + #""}"#
        let withQuoted = try? made.vault.add(name: "MASK_QUOTED", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                             value: SecretBytes(utf8: quoted), maskKey: SymmetricKey(data: maskData))
        made.vault.wipe()
        try? store.folder.ensure()
        try? store.folder.write(SecretFolder.maskKeyName, data: maskData)
        if let file = withQuoted ?? file { try? store.folder.write(SecretFolder.vaultName, data: file) }
        let agreements = keyring.agreementCount
        store.loadMarks()
        check(!SecretMask.current.isEmpty && presence.calls == 0 && keyring.agreementCount == agreements,
              "secrets: the marks load with no unlock and no presence check", "\(SecretMask.current.marks.count) marks, \(presence.calls) checks")

        let valueFile = base.appendingPathComponent("value.txt")
        try? value.write(to: valueFile, atomically: true, encoding: .utf8)
        let tab = c.addTab(directory: base.path, select: false)
        defer { closeSecretsTabs([tab], "masking") }
        guard await wait(20, { tab.status.integrated }),
              let client = SecretsMCPClient(socket: MCPControlServer.shared.path) else {
            return check(false, "secrets: a tab and an MCP bridge for the masking checks")
        }
        defer { client.close() }
        await client.start()
        let id = tab.id.uuidString.lowercased()
        tab.view.send(txt: "K=$(cat \(ShellQuote.quote(valueFile.path))); printf '%s\\n' \"$K\"\r")
        let printed = await wait(10) { tab.screenTail().joined().contains(value) }
        let read = await client.call("read_tab", ["tab_id": id])
        let waited = await client.call("wait_for_tab", ["tab_id": id, "timeout_seconds": 5])
        check(printed && read.text.contains("•••") && !read.text.contains(value) && !waited.text.contains(value) && waited.text.contains("•••"),
              "secrets: read_tab and wait_for_tab show ••• where a tab printed a stored key", String(read.text.suffix(200)))
        await secretsWrappedTailCheck(tab, client: client, value: value)
        await secretsHardWrappedTailCheck(tab, client: client, value: value)
        await secretsIndentedTailCheck(tab, client: client, value: value)
        await secretsWrappedWaitCheck(tab, client: client, value: value)
        await secretsWrappedChoiceCheck(c, base: base, client: client, value: value, valueFile: valueFile)

        // A program sets the tab's title to the value (OSC 0), while its command runs.
        tab.view.send(txt: "printf '\\e]0;%s\\a' \"$K\"; sleep 6\r")
        let titled = await wait(10) { tab.title.contains(value) }
        let listed = await client.call("list_tabs")
        check(titled && listed.text.contains("•••") && !listed.text.contains(value),
              "secrets: list_tabs shows ••• in a title a program set to a stored key", titled ? "" : "the title never held it")
        let restore = defaultNotificationSettings()
        let before = app.testNotifications.count
        app.post(TabNotice(state: .attention, command: "sleep", program: "sleep", kind: .agent, stillRunning: true,
                           question: "Use \(value) for the deploy?"), tab: tab, in: c, appActive: false)
        restore()
        let note = app.testNotifications.dropFirst(before).last { $0.identifier == tab.id.uuidString }
        check(note.map { $0.content.subtitle.contains("•••") && !$0.content.subtitle.contains(value) } == true,
              "secrets: a decision notification for that tab has ••• in its subtitle", note?.content.subtitle ?? "no notification")
        check(note.map { $0.content.body.contains("•••") && !$0.content.body.contains(value) } == true,
              "secrets: a notification built from a question holding a stored key shows ••• in its body", note?.content.body ?? "")
        MCPControl.fieldMasks = false
        let unmaskedFields = await client.call("list_tabs")
        MCPControl.fieldMasks = true
        check(titled && unmaskedFields.text.contains("•••") && !unmaskedFields.text.contains(value),
              "secrets: with the field masks off, the last pass over each answer still masks the title")
        await secretsSkillAnswerCheck(client, base: base, quoted: quoted, token: quotedToken)
        _ = await wait(10) { !tab.status.running }

        // A title report (CSI 21 t) never types the title back.
        tab.view.send(txt: "printf '\\e]0;%s\\a' \"$K\"; printf '\\e[21t'; IFS= read -rs -t 1 -d '\\' reply; "
                      + "case \"$reply\" in *\"$K\"*) echo L\"\"EAK;; *) echo NO\"\"LEAK;; esac\r")
        func row(_ word: String) -> Bool { tab.screenTail().contains { $0.trimmingCharacters(in: .whitespaces) == word } }
        let answered = await wait(10) { row("NOLEAK") || row("LEAK") }
        check(answered && row("NOLEAK") && !row("LEAK"),
              "secrets: a title report gives an empty title, so a title holding a key never comes back as input",
              tab.screenTail().suffix(3).joined(separator: " | "))

        // The selection sent to IDE clients.
        let params = ClaudeIDEServer.selectionParams(path: base.appendingPathComponent("notes.txt").path, text: "copy \(value) here",
                                                     start: (0, 0), end: (0, 10))
        check(params["text"] as? String == "copy ••• here", "secrets: the selection sent to IDE clients is masked", "\(params["text"] ?? "")")
        let gemini = GeminiIDEServer.masked([["path": base.appendingPathComponent("notes.txt").path, "selectedText": "copy \(value) here"]])
        check(gemini.first?["selectedText"] as? String == "copy ••• here", "secrets: the selection Gemini CLI and Qwen Code are told of is masked too",
              "\(gemini.first?["selectedText"] ?? "")")
    }

    /// read_tab with a window that starts on the second row of a key a wrap split: the row above is masked with it, so
    /// no part of the key's tail shows. The key starts 8 columns before the right edge, and `lines` is counted so the
    /// window's first row is the one the wrap continued onto.
    static func secretsWrappedTailCheck(_ tab: TerminalTab, client: SecretsMCPClient, value: String) async {
        let tail = String(value.dropFirst(8))
        tab.view.send(txt: "printf '%*s%s\\n' $((COLUMNS - 8)) '' \"$K\"; printf 'after\\n'\r")
        let shown = await wait(10) { tab.screenTail().contains("after") && !tab.status.running }
        let rows = tab.screenTail(60)
        guard shown, let second = rows.lastIndex(where: { $0.hasPrefix(tail) }) else {
            return check(false, "secrets: a key a wrap split shows on two rows", rows.suffix(4).joined(separator: " | "))
        }
        let read = await client.call("read_tab", ["tab_id": tab.id.uuidString.lowercased(), "lines": rows.count - second])
        let characters = Array(tail)
        let pieces = (0...(characters.count - 6)).map { String(characters[$0..<$0 + 6]) }
        check(read.text.contains("•••") && !pieces.contains { read.text.contains($0) },
              "secrets: read_tab whose window starts on the second row of a key a wrap split shows ••• and none of its tail",
              String(read.text.suffix(200)))
    }

    /// As `secretsWrappedTailCheck`, with the key split by a newline, as agent UIs (Ink, ratatui) wrap: no row is marked
    /// as the terminal's wrap, and the rows above the window are masked with it all the same.
    static func secretsHardWrappedTailCheck(_ tab: TerminalTab, client: SecretsMCPClient, value: String) async {
        let tail = String(value.dropFirst(8))
        tab.view.send(txt: "printf '%.8s\\n%s\\n' \"$K\" \"${K#????????}\"; printf 'after-newline\\n'\r")
        let shown = await wait(10) { tab.screenTail().contains("after-newline") && !tab.status.running }
        let rows = tab.screenTail(60)
        guard shown, let second = rows.lastIndex(of: tail) else {
            return check(false, "secrets: a key a newline split shows on two rows", rows.suffix(4).joined(separator: " | "))
        }
        let read = await client.call("read_tab", ["tab_id": tab.id.uuidString.lowercased(), "lines": rows.count - second])
        let characters = Array(tail)
        let pieces = (0...(characters.count - 6)).map { String(characters[$0..<$0 + 6]) }
        check(read.text.contains("•••") && !pieces.contains { read.text.contains($0) },
              "secrets: read_tab whose window starts on the second row of a key a newline split shows ••• and none of its tail",
              String(read.text.suffix(200)))
    }

    /// As `secretsHardWrappedTailCheck`, with the key's two rows drawn as agent UIs draw a tool's output: indented as
    /// Claude Code indents it ("  ⎿  ", then "     "), and in a box ("│ … │"). The edges between the two parts are left
    /// out of the match, so the window starting on the second row shows none of the key's tail.
    static func secretsIndentedTailCheck(_ tab: TerminalTab, client: SecretsMCPClient, value: String) async {
        let tail = String(value.dropFirst(8))
        let characters = Array(tail)
        let pieces = (0...(characters.count - 6)).map { String(characters[$0..<$0 + 6]) }
        let shapes = [(name: "indented", first: "  ⎿  ", next: "     ", close: ""),
                      (name: "boxed", first: "│ ", next: "│ ", close: " │")]
        for shape in shapes {
            let mark = "after-\(shape.name)"
            let rowsArguments = "'\(shape.first)' \"$K\" '\(shape.close)' '\(shape.next)' \"${K#????????}\" '\(shape.close)'"
            tab.view.send(txt: "printf '%s%.8s%s\\n%s%s%s\\n' \(rowsArguments); printf '\(mark)\\n'\r")
            let shown = await wait(10) { tab.screenTail().contains(mark) && !tab.status.running }
            let rows = tab.screenTail(60)
            guard shown, let second = rows.lastIndex(of: shape.next + tail + shape.close) else {
                check(false, "secrets: a key split over two \(shape.name) rows shows on two rows", rows.suffix(4).joined(separator: " | "))
                continue
            }
            let read = await client.call("read_tab", ["tab_id": tab.id.uuidString.lowercased(), "lines": rows.count - second])
            check(read.text.contains("•••") && !pieces.contains { read.text.contains($0) },
                  "secrets: read_tab whose window starts on the second of a key's two \(shape.name) rows shows ••• and none of its tail",
                  String(read.text.suffix(200)))
        }
    }

    /// wait_for_tab reads the last 40 rows. Keys a wrap split fill them, two rows each, and the same rows with one more
    /// line after them move the window by a row, so one of the two windows starts on a key's second row: neither shows
    /// any of a key's tail.
    static func secretsWrappedWaitCheck(_ tab: TerminalTab, client: SecretsMCPClient, value: String) async {
        let id = tab.id.uuidString.lowercased()
        let tail = String(value.dropFirst(8))
        let characters = Array(tail)
        let pieces = (0...(characters.count - 6)).map { String(characters[$0..<$0 + 6]) }
        let keys = "for i in $(seq 25); do printf '%*s%s\\n' $((COLUMNS - 8)) '' \"$K\"; done; "
        var startsOnTail = false
        for (round, extra) in ["", "printf 'x\\n'; "].enumerated() {
            let mark = "wrapped-wait-\(round)"
            tab.view.send(txt: keys + extra + "printf 'wrapped-wait-%s\\n' \(round)\r")
            let done = await wait(15) { !tab.status.running && tab.screenTail().contains(mark) }
            if tab.screenTail(40).first?.hasPrefix(tail) == true { startsOnTail = true }
            let waited = await client.call("wait_for_tab", ["tab_id": id, "timeout_seconds": 5])
            check(done && waited.text.contains("•••") && !pieces.contains { waited.text.contains($0) },
                  "secrets: wait_for_tab over rows of keys a wrap split shows ••• and none of a key's tail (\(round + 1) of 2)",
                  String(waited.text.suffix(200)))
        }
        check(startsOnTail, "secrets: one of wait_for_tab's two windows starts on the second row of a key a wrap split",
              tab.screenTail(40).prefix(2).joined(separator: " | "))
    }

    /// The choices of an agent's question are read from rows masked over whole lines: a key the terminal wrapped inside
    /// a choice is masked, though the choice's label is its first row only. A stand-in agent named claude asks.
    static func secretsWrappedChoiceCheck(_ c: TerminalWindowController, base: URL, client: SecretsMCPClient,
                                          value: String, valueFile: URL) async {
        let bin = base.appendingPathComponent("choice-bin")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let agent = bin.appendingPathComponent("claude")
        // The key starts so that all but its last 4 characters end the first choice's row.
        try? """
        #!/bin/sh
        K=$(cat \(ShellQuote.quote(valueFile.path)))
        cols=$(stty size | cut -d' ' -f2)
        pad=$((cols - 10 - ${#K})); [ "$pad" -lt 0 ] && pad=0
        printf 'Do you want to use the stored key?\\n'
        printf '\\342\\235\\257 1. Yes, use %*s%s\\n' "$pad" '' "$K"
        printf '  2. No\\n'
        while true; do sleep 1; done
        """.write(to: agent, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.path)
        let tab = c.addTab(directory: base.path, select: false)
        defer { closeSecretsTabs([tab], "choices") }
        guard await wait(20, { tab.status.integrated }) else { return check(false, "secrets: a tab for the choices check") }
        tab.view.send(txt: "PATH=\(ShellQuote.quote(bin.path)):$PATH claude\r")
        let asked = await wait(15) { tab.status.question == "Do you want to use the stored key?" }
        let read = await client.call("read_tab", ["tab_id": tab.id.uuidString.lowercased(), "lines": 10])
        let answer = (try? JSONSerialization.jsonObject(with: Data(read.text.utf8))) as? [String: Any]
        let choices = answer?["choices"] as? [String] ?? []
        let head = Array(value.dropLast(4))
        let pieces = (0...(head.count - 6)).map { String(head[$0..<$0 + 6]) }
        let shows = pieces.contains { piece in choices.contains { $0.contains(piece) } }
        check(asked && choices.count == 2 && choices[0].contains("•••") && !shows,
              "secrets: the choices of an agent's question show ••• for a key the terminal wrapped inside one, and none of it",
              choices.joined(separator: " | "))
        tab.view.send(txt: "\u{03}")
        _ = await wait(5) { !tab.status.running }
    }

    /// get_skill gives a SKILL.md whole, with no field mask: a stored value in it whose quotes the answer's JSON escapes
    /// is still masked, by the last pass over each answer's strings. The skill is in a home folder of its own.
    static func secretsSkillAnswerCheck(_ client: SecretsMCPClient, base: URL, quoted: String, token: String) async {
        let home = base.appendingPathComponent("skills-home").path
        let folder = (home as NSString).appendingPathComponent(".agents/skills/nt-mask-probe")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? "---\nname: nt-mask-probe\ndescription: The masking probe.\n---\nDeploy with \(quoted) as the account.\n"
            .write(toFile: folder + "/SKILL.md", atomically: true, encoding: .utf8)
        let savedHome = SkillsStore.home
        SkillsStore.home = home
        let got = await client.call("get_skill", ["name": "nt-mask-probe"])
        SkillsStore.home = savedHome
        check(!got.isError && got.text.contains("Deploy with ••• as the account") && !got.text.contains(token),
              "secrets: get_skill masks a stored value in a skill's text, though its quotes are escaped in the answer",
              String(got.text.suffix(200)))
    }
}

/// A request's answers, collected as they come.
@MainActor
final class SecretsAnswers {
    private(set) var all: [SecretRequests.Decision] = []
    func take(_ decision: SecretRequests.Decision) { all.append(decision) }
    var last: SecretRequests.Decision? { all.last }
}

extension SelfTest {
    // MARK: the panel and grants

    /// A request as the socket or the tools build one, with Next Term's facts filled in.
    static func secretsRequest(asker: String, command: [String], source: SecretBinding.Source = .wrapper, names: [String] = ["PANEL_KEY"],
                               remote: String? = nil, agent: String? = "Codex", checked: Bool = true, tab: String? = nil,
                               programTitle: String? = nil, words: String? = nil, folder: String = NSTemporaryDirectory()) -> SecretRequests.Request {
        let keys = names.map { SecretRequests.Key(name: $0, envName: $0) }
        let map = Dictionary(uniqueKeysWithValues: keys.map { ($0.name, $0.envName) })
        // The binding's program as the product fills it: a wrapper's is the agent's above it ("codex" for Codex, "" for
        // none), run_with_secrets' is its command line's first word.
        let agentProgram = agent.map { ($0.split(separator: " ").first.map(String.init) ?? $0).lowercased() } ?? ""
        let bound = source == .wrapper ? agentProgram : SecretRun.programName(ofCommand: command.first ?? "")
        let binding = SecretBinding(source: source, asker: asker, program: bound, command: command, keys: map, folder: folder)
        var facts = SecretRequests.AskedBy()
        facts.agent = agent
        facts.checkedNxtrm = checked && source == .wrapper
        facts.connection = remote
        facts.tab = tab
        facts.programTitle = programTitle
        facts.pid = 4242
        facts.executable = "/usr/bin/true"
        facts.arguments = ["NextTerm", "--cli", "secret", "run"] + names + ["--"] + command
        let shown = source == .wrapper ? command.map(SecretApprovalPanel.escaped).joined(separator: " ") : command.joined(separator: " ")
        let argv = source == .wrapper ? command : ["/bin/sh", "-c"] + command
        // The program its panel names: a wrapper's argv's first word, run_with_secrets' command line's.
        let program = source == .wrapper ? ((command.first ?? "") as NSString).lastPathComponent
            : SecretRun.programName(ofCommand: command.first ?? "")
        return SecretRequests.Request(binding: binding, keys: keys, command: shown, argv: argv, folder: folder, warnings: [],
                                      agentWords: words, askedBy: facts, program: program, isRemote: remote != nil)
    }

    static func secretsAllowed(_ decision: SecretRequests.Decision?) -> (values: [String: SecretBytes], how: SecretAudit.Approval)? {
        if case .allowed(let values, let how)? = decision { return (values, how) }
        return nil
    }

    static func secretsRefusal(_ decision: SecretRequests.Decision?) -> SecretLimits.Refusal? {
        if case .refused(let refusal)? = decision { return refusal }
        return nil
    }

    static func secretsPanelChecks(_ base: URL) async {
        let requests = SecretRequests.shared
        let store = SecretsStore.shared
        requests.resetForSelfTest()
        defer { requests.resetForSelfTest() }
        let value = secretsValue("panel")
        _ = try? await store.perform(.add(name: "PANEL_KEY", purpose: "the panel checks", purposeBy: .agent, origin: .settings,
                                          writeOnly: true, value: SecretBytes(utf8: value)))

        // A wrapper's request: Next Term's facts in their own rows, Details, and "until the Mac locks".
        let answers = SecretsAnswers()
        let command = ["npx", "-y", "server@1.0.0", "two words"]
        let wrapper = secretsRequest(asker: "wrapper:selftest-a", command: command, tab: "tab 3",
                                     programTitle: "evil\u{202E}title\u{0007}\u{200B}x")
        requests.ask(wrapper) { answers.take($0) }
        guard let panel = wrapper.panel, let window = panel.window else { return check(false, "secrets: a wrapper's request shows the panel") }
        let shown = texts(window.contentView)
        check(shown.contains("Asked through Next Term's own nxtrm (checked)") && shown.contains("Codex, going by its program's name")
              && panel.durationChoice[.untilLock] != nil && panel.durationChoice[.once]?.state == .on,
              "secrets: a wrapper's panel shows the checked nxtrm row, the agent going by its program's name, and until the Mac locks",
              shown)
        check(panel.detailsDisclosure.state == .off && shown.contains("\(wrapper.askedBy.arguments.count) arguments:") && shown.contains("\"two words\""),
              "secrets: Details, closed at first, lists every argument escaped, with their count")
        check(shown.contains("Tab title (set by a program): eviltitlex") && !shown.contains("\u{202E}") && !shown.contains("\u{200B}"),
              "secrets: a tab title's control, bidi and zero-width characters are stripped")
        check(SecretApprovalPanel.shownCommand("npm test\r\nnpx -y x\u{202E}\u{200B}", limit: 200) == "npm test\\r\\nnpx -y x\\u{202e}\\u{200b}",
              "secrets: the panel's command shows line breaks, bidi and zero-width characters escaped, never as spaces or taken out")
        check(shown.contains("(an agent wrote this)") && shown.contains("Write-only"),
              "secrets: the key's row marks an agent's purpose and the write-only badge")
        check(!window.isKeyWindow && window.collectionBehavior.contains(.canJoinAllSpaces) && window.collectionBehavior.contains(.fullScreenAuxiliary)
              && window.level == .floating && window.styleMask.contains(.nonactivatingPanel)
              && panel.allowButton.keyEquivalent.isEmpty && panel.allowButton.refusesFirstResponder,
              "secrets: the panel never takes the keyboard, joins every Space and full-screen windows, floats, and has no default button")
        check(SecretApprovalPanel.title(wrapper) == "Codex asks to start npx with PANEL_KEY", "secrets: the panel's title names the agent, the program and the key",
              SecretApprovalPanel.title(wrapper))

        // "Allow for 15 minutes": the same request again needs no panel, until the Mac locks.
        panel.durationChoice[.fifteenMinutes]?.performClick(nil)
        panel.allowButton.performClick(nil)
        _ = await wait(10) { !answers.all.isEmpty }
        let allowed = secretsAllowed(answers.last)
        check(allowed?.values["PANEL_KEY"] == SecretBytes(utf8: value) && allowed?.how == .fifteenMinutes && wrapper.panel == nil,
              "secrets: Allow for 15 minutes gives the key, after the presence check")
        let again = secretsRequest(asker: "wrapper:selftest-a", command: command, tab: "tab 3")
        requests.ask(again) { answers.take($0) }
        check(secretsAllowed(answers.last)?.how == .grant && again.panel == nil && requests.grants.count == 1,
              "secrets: the same request within 15 minutes starts with no panel")
        store.handleLockEvent(.screenLocked)
        let afterLock = secretsRequest(asker: "wrapper:selftest-a", command: command, tab: "tab 3")
        let afterLockWaits = requests.ask(afterLock) { answers.take($0) }
        check(requests.grants.isEmpty && afterLock.panel != nil, "secrets: locking the Mac ends the grant, and the same request asks again")

        // A pending card: its wrapper stopped waiting.
        if let afterLockWaits { requests.wrapperLeft(afterLockWaits) }
        check(afterLock.panel?.durationChoice[.fifteenMinutes]?.state == .on && afterLock.panel?.durationChoice[.once]?.isEnabled == false,
              "secrets: a pending card has Allow for 15 minutes chosen and Allow once off")
        let takeover = secretsRequest(asker: "wrapper:selftest-a", command: command, tab: "tab 3")
        let takeoverWaits = requests.ask(takeover) { answers.take($0) }
        check(takeover.panel == nil && afterLock.panel != nil && requests.queue.count == 1 && afterLock.panel?.durationChoice[.once]?.isEnabled == true
              && takeoverWaits?.request === afterLock,
              "secrets: an identical request takes the card over, and does not queue")
        // The wrapper that took it over stops waiting too: the card is a card again.
        if let takeoverWaits { requests.wrapperLeft(takeoverWaits) }
        check(afterLock.gone && afterLock.panel?.durationChoice[.once]?.isEnabled == false,
              "secrets: when the wrapper that took a card over leaves, the card says so again")
        afterLock.panel?.declineButton.performClick(nil)

        // Two identical wrappers wait on one panel: the first leaving leaves the second waiting, and it gets the answer.
        // Their own asker: the card just declined pauses its own request for 10 minutes, so it would refuse them.
        let first = secretsRequest(asker: "wrapper:selftest-twins", command: command, tab: "tab 3")
        let firstWaits = requests.ask(first) { _ in }
        let secondAnswers = SecretsAnswers()
        let second = secretsRequest(asker: "wrapper:selftest-twins", command: command, tab: "tab 3")
        requests.ask(second) { secondAnswers.take($0) }
        if let firstWaits { requests.wrapperLeft(firstWaits) }
        check(!first.gone && first.panel?.durationChoice[.once]?.isEnabled == true && secondAnswers.all.isEmpty,
              "secrets: the first of two identical wrappers leaving is no pending card while the second waits")
        first.panel?.declineButton.performClick(nil)
        check({ if case .declined? = secondAnswers.last { return true }; return false }(),
              "secrets: the wrapper still waiting gets the answer")

        // The wrapper leaves while the user is in the Touch ID sheet after "Allow once": a one-use approval, the panel
        // stays up saying so, and the request waiting behind it gets its panel.
        let stopping = secretsRequest(asker: "wrapper:selftest-stopping", command: ["node", "server.js"], tab: "tab 3")
        let stoppingWaits = requests.ask(stopping) { _ in }
        let behind = secretsRequest(asker: "wrapper:selftest-behind", command: ["node", "other.js"], tab: "tab 4")
        requests.ask(behind) { answers.take($0) }
        let stoppingPanel = stopping.panel
        stoppingPanel?.allowButton.performClick(nil)
        if let stoppingWaits { requests.wrapperLeft(stoppingWaits) }
        _ = await wait(10) { behind.panel != nil }
        let lingers = stoppingPanel?.window.map { $0.isVisible && texts($0.contentView).contains(SecretApprovalPanel.stoppedDuringApprovalText) }
        check(behind.panel != nil && lingers == true && requests.grants.contains { $0.kind == .oneUse },
              "secrets: a wrapper that leaves during Touch ID after Allow once gets a one-use approval, its panel says so, and the next request shows")
        stoppingPanel?.close()
        behind.panel?.declineButton.performClick(nil)
        let restartAnswers = SecretsAnswers()
        let restarted = secretsRequest(asker: "wrapper:selftest-stopping", command: ["node", "server.js"], tab: "tab 3")
        requests.ask(restarted) { restartAnswers.take($0) }
        check(secretsAllowed(restartAnswers.last)?.how == .grant && restarted.panel == nil && !requests.grants.contains { $0.kind == .oneUse },
              "secrets: restarted within 2 minutes, it is answered by that one-use approval, once")

        // Start Over ends every grant: a key added again under the same name asks again. (A store of its own starts
        // over, so the shared one keeps its keys; the grants listen to any.)
        let kept = secretsRequest(asker: "wrapper:selftest-start-over", command: ["node", "kept.js"], tab: "tab 3")
        requests.ask(kept) { answers.take($0) }
        kept.panel?.durationChoice[.fifteenMinutes]?.performClick(nil)
        kept.panel?.allowButton.performClick(nil)
        let granted = await wait(10) { requests.grants.contains { $0.binding == kept.binding } }
        let (scratch, _) = secretsStore(base, "start-over-grants", keyring: SoftwareKeyring(kind: .secureEnclave))
        _ = try? scratch.startOver()
        check(granted && requests.grants.isEmpty, "secrets: Start Over ends every grant, so a key added again under its name asks again")

        // Decline pauses that request only; Decline and Stop Asking stops the asker.
        let tool = secretsRequest(asker: "selftest-tab-x", command: ["npm test"], source: .tool, agent: "Claude Code")
        requests.ask(tool) { answers.take($0) }
        tool.panel?.declineButton.performClick(nil)
        let paused = secretsRequest(asker: "selftest-tab-x", command: ["npm test"], source: .tool, agent: "Claude Code")
        requests.ask(paused) { answers.take($0) }
        let pausedRefusal = secretsRefusal(answers.last)
        let other = secretsRequest(asker: "selftest-tab-x", command: ["npm run e2e"], source: .tool, agent: "Claude Code")
        requests.ask(other) { answers.take($0) }
        let otherShown = other.panel != nil
        check({ if case .paused? = pausedRefusal { return true }; return false }() && otherShown,
              "secrets: Decline pauses that same request; another from the same agent still shows the panel")
        other.panel?.stopButton.performClick(nil)
        let third = secretsRequest(asker: "selftest-tab-x", command: ["npm run lint"], source: .tool, agent: "Claude Code")
        requests.ask(third) { answers.take($0) }
        check(secretsRefusal(answers.last) == .stopped, "secrets: Decline and Stop Asking refuses that agent's next, different request")

        // A remote request offers only "Allow once".
        let remote = secretsRequest(asker: "remote:grant-1", command: ["npm test"], source: .tool, remote: "Claude, phone", agent: nil)
        requests.ask(remote) { answers.take($0) }
        check(remote.panel.map { Array($0.durationChoice.keys) == [.once] } == true
              && SecretApprovalPanel.title(remote) == "The remote connection “Claude, phone” asks to run npm with PANEL_KEY",
              "secrets: a remote request's panel names the connection and offers only Allow once")
        remote.panel?.declineButton.performClick(nil)

        // A big request keeps its buttons on screen.
        let names = (1...20).map { "BIG_KEY_\($0)" }
        let big = secretsRequest(asker: "selftest-big", command: [String(repeating: "x", count: 2000)], source: .tool, names: names,
                                 agent: "Claude Code", words: String(repeating: "w", count: 500))
        requests.ask(big) { answers.take($0) }
        if let bigWindow = big.panel?.window, let screen = bigWindow.screen ?? NSScreen.main, let allow = big.panel?.allowButton {
            bigWindow.layoutIfNeeded()
            let button = bigWindow.convertToScreen(allow.convert(allow.bounds, to: nil))
            check(screen.visibleFrame.contains(bigWindow.frame) && bigWindow.frame.contains(button),
                  "secrets: a panel with 20 keys, a 2,000-character command and 500 characters of words keeps its buttons on screen",
                  "window \(bigWindow.frame), button \(button), screen \(screen.visibleFrame)")
        } else {
            check(false, "secrets: the big request shows a panel")
        }

        // The hour pause, after its confirm.
        big.panel?.pauseButton.performClick(nil)
        _ = await wait(5) { big.panel?.pauseAlert != nil }
        big.panel?.pauseAlert?.buttons.first?.performClick(nil)
        _ = await wait(5) { requests.pausedUntil != nil }
        let next = secretsRequest(asker: "selftest-after-pause", command: ["true"], source: .tool, agent: "Claude Code")
        requests.ask(next) { answers.take($0) }
        let until = requests.pausedUntil
        check(until.map { abs($0.timeIntervalSinceNow - 3600) < 120 } == true && { if case .declining? = secretsRefusal(answers.last) { return true }; return false }(),
              "secrets: Pause Key Requests for 1 Hour, after its confirm, refuses the next request and says until when")
        requests.resumeAsking()
        _ = try? await store.perform(.delete(name: "PANEL_KEY"))
    }
}

/// A wrapper run by the self-test: its exit code, and what it wrote to standard output and standard error.
final class SecretsWrapperRun: @unchecked Sendable {
    let process = Process()
    private let output = Pipe()
    private let errors = Pipe()
    private(set) var stdout = Data()
    private(set) var stderr = Data()
    private var launched = false

    /// What a careless parent leaves a program it starts: SIGPIPE, SIGINT and SIGTERM ignored, and fd 7 open. `Process`
    /// starts every child clean, so only this `/bin/sh` step shows whether the wrapper's own resets before `execve` work.
    static let carelessParent = "trap '' PIPE INT TERM; exec 7</dev/null"

    /// The wrapper's own argv before the arguments after `secret run`: its path, then six.
    static let ownArguments = 7

    /// `padding`: that many more arguments ("a") at the end of the wrapper's argv. `/bin/sh` adds them as it execs the
    /// wrapper, since `Process` raises an Objective-C exception, which Swift can't catch, past 4,096 arguments.
    /// `careless`: the wrapper starts as `carelessParent` leaves it.
    init(_ arguments: [String], environment: [String: String] = [:], wait: Int = 20, directory: URL? = nil, padding: Int = 0,
         careless: Bool = false) {
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let own = ["--cli", "--self-test-secret-wrapper", SelfTest.mcpSocketPath, String(wait), "secret", "run"] + arguments
        if padding > 0 || careless {
            let exec = "exec \"$@\"" + (padding > 0 ? " $(/usr/bin/jot -b a \(padding))" : "")
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", (careless ? Self.carelessParent + "; " : "") + exec, "sh", executable] + own
        } else {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = own
        }
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
    }

    func start() -> Bool {
        launched = (try? process.run()) != nil
        if !launched {
            // Nothing else would close the pipes' writing ends, and a read would wait for them for ever.
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
        }
        return launched
    }

    /// Waits for it to end, without blocking the main thread. Nil when it never started, or did not end in time.
    @MainActor
    func finish(within seconds: Double = 40) async -> Int32? {
        guard launched else { return nil }
        guard await SelfTest.wait(seconds, { !self.process.isRunning }) else {
            // SIGKILL: a careless one ignores the SIGTERM of terminate().
            kill(process.processIdentifier, SIGKILL)
            return nil
        }
        stdout = output.fileHandleForReading.readDataToEndOfFile()
        stderr = errors.fileHandleForReading.readDataToEndOfFile()
        return process.terminationStatus
    }

    var errorText: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension SelfTest {
    // MARK: nxtrm secret run

    static func secretsWrapperChecks(_ base: URL) async {
        let requests = SecretRequests.shared
        let store = SecretsStore.shared
        requests.resetForSelfTest()
        defer { requests.resetForSelfTest() }
        guard MCPControlServer.shared.isRunning else { return check(false, "secrets: the self-test's MCP socket is up for the wrapper") }
        let value = secretsValue("wrap")
        _ = try? await store.perform(.add(name: "WRAP_KEY", purpose: "the wrapper checks", purposeBy: .user, origin: .settings,
                                          writeOnly: false, value: SecretBytes(utf8: value)))
        _ = try? await store.perform(.add(name: "OTHER_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                          value: SecretBytes(utf8: secretsValue("other"))))
        defer {
            Task { @MainActor in
                _ = try? await store.perform(.delete(name: "WRAP_KEY"))
                _ = try? await store.perform(.delete(name: "OTHER_KEY"))
            }
        }
        let out = base.appendingPathComponent("wrapper", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func read(_ name: String) -> String {
            ((try? String(contentsOf: out.appendingPathComponent(name), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Allowed: the child gets the key (it writes only its length), not OTHER_KEY, only fds 0 to 2, and SIGPIPE, SIGINT and
        // SIGTERM at their defaults, though the wrapper started with fd 7 open and those ignored.
        await secretsCarelessParentCheck(in: out)
        let script = "printf %s \"$K\" | wc -c | tr -d ' ' > len; if [ -z \"${OTHER_KEY+x}\" ]; then echo gone > other; fi; "
            + secretsDescriptorsAndSignals(prefix: "")
        let allowed = SecretsWrapperRun(["WRAP_KEY=K", "--", "/bin/sh", "-c", script], environment: ["OTHER_KEY": "exported-in-the-parent"],
                                        directory: out, careless: true)
        let started = allowed.start()
        let shown = await wait(15) { requests.showing?.panel != nil }
        let panel = requests.showing?.panel
        let title = requests.showing.map(SecretApprovalPanel.title) ?? "no panel"
        check(started && shown && title.contains("asks to start sh with WRAP_KEY"), "secrets: nxtrm secret run shows the panel", title)
        panel?.allowButton.performClick(nil)
        let allowedExit = await allowed.finish()
        check(allowedExit == 0 && read("len") == String(value.utf8.count) && allowed.stdout.isEmpty,
              "secrets: after Allow the command runs with the key in its environment, and nothing goes to stdout",
              "exit \(String(describing: allowedExit)), len \(read("len")), \(allowed.errorText)")
        check(read("other") == "gone", "secrets: a stored key's name exported in the parent is gone in the command")
        check(read("fds").isEmpty && read("signals") == "DEFAULT DEFAULT DEFAULT",
              "secrets: the command has only fds 0 to 2, and SIGPIPE, SIGINT and SIGTERM at their defaults, from a careless parent",
              "fds [\(read("fds"))], PIPE INT TERM \(read("signals"))")
        check(!String(decoding: store.folder.readAudit(), as: UTF8.self).contains(value), "secrets: the audit log holds no value")

        // Declined: exit 1 and its line.
        let declined = SecretsWrapperRun(["WRAP_KEY", "--", "/usr/bin/true"])
        _ = declined.start()
        _ = await wait(15) { requests.showing?.panel != nil }
        requests.showing?.panel?.declineButton.performClick(nil)
        let declinedExit = await declined.finish()
        check(declinedExit == 1 && declined.errorText == "nxtrm: Next Term declined WRAP_KEY for true." && declined.stdout.isEmpty,
              "secrets: a declined wrapper exits 1 with its line", declined.errorText)
        #if DEBUG
        await secretsWrapperTwinsChecks(out)
        #endif

        // An unknown name, and an argument holding a stored value: exit 2, no panel.
        let unknown = SecretsWrapperRun(["NOT_STORED", "--", "/usr/bin/true"])
        _ = unknown.start()
        let unknownExit = await unknown.finish()
        check(unknownExit == 2 && unknown.errorText.contains("no key named NOT_STORED") && unknown.stdout.isEmpty && requests.showing == nil,
              "secrets: a name not stored exits 2, with no panel", unknown.errorText)
        let holding = SecretsWrapperRun(["WRAP_KEY", "--", "/bin/echo", value])
        _ = holding.start()
        let holdingExit = await holding.finish()
        check(holdingExit == 2 && holding.errorText.contains("holds a stored key’s value") && holding.stdout.isEmpty && requests.showing == nil,
              "secrets: an argument holding a stored value exits 2, with no panel", holding.errorText)

        // No answer within the wait: the timed-out line, and the panel becomes a pending card that an identical request takes over.
        let away = SecretsWrapperRun(["WRAP_KEY", "--", "/usr/bin/true", "away"], wait: 2)
        _ = away.start()
        let awayExit = await away.finish()
        _ = await wait(5) { requests.showing?.gone == true }
        let card = requests.showing
        check(awayExit == 1 && away.errorText == "nxtrm: WRAP_KEY is waiting for your approval in Next Term. Allow it there, then restart this command."
              && away.stdout.isEmpty && card?.panel?.durationChoice[.once]?.isEnabled == false,
              "secrets: with no answer in time the wrapper says so, and the panel becomes a pending card", away.errorText)
        let again = SecretsWrapperRun(["WRAP_KEY", "--", "/usr/bin/true", "away"], wait: 10)
        _ = again.start()
        _ = await wait(5) { card?.panel?.durationChoice[.once]?.isEnabled == true }
        check(requests.queue.count == 1 && requests.showing === card && card?.panel?.durationChoice[.once]?.isEnabled == true,
              "secrets: a second identical request takes the card over")
        card?.panel?.declineButton.performClick(nil)
        _ = await again.finish()

        // Refused, with no panel: a program that is not nxtrm, a lying argv, and argv over the caps. Each for its own reason.
        let nc = Process()
        nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        nc.arguments = ["-U", SelfTest.mcpSocketPath]
        let ncIn = Pipe(), ncOut = Pipe()
        nc.standardInput = ncIn
        nc.standardOutput = ncOut
        nc.standardError = FileHandle.nullDevice
        let beforeNc = secretsAudit(store).count
        if (try? nc.run()) != nil {
            // An nc that is already gone is no SIGPIPE, and no exception, for Next Term.
            let writer = ncIn.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? writer.write(contentsOf: Data(#"{"tool":"secret_run","arguments":{}}"#.utf8 + [0x0A]))
            try? writer.close()
            _ = await wait(10) { !nc.isRunning }
            if nc.isRunning { nc.terminate() }
            let said = String(decoding: ncOut.fileHandleForReading.availableData, as: UTF8.self)
            check(said.contains("\"refused\"") && requests.showing == nil, "secrets: a program that is not nxtrm gets refused at the socket, and no panel shows",
                  said)
            let ncReason = await secretsRefusalReason(store, after: beforeNc)
            check(ncReason == "the program at the socket is not Next Term's own nxtrm", "secrets: the refusal is in the audit log", ncReason)
        }
        let claimed = (try? JSONEncoder().encode([Bundle.main.executablePath ?? "", "--cli", "secret", "run", "WRAP_KEY", "--", "/usr/bin/true"]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let liar = SecretsWrapperRun(["WRAP_KEY", "--", "/usr/bin/true"], environment: ["NEXTTERM_SELFTEST_ARGV_FULL": claimed])
        let beforeLiar = secretsAudit(store).count
        _ = liar.start()
        let liarExit = await liar.finish()
        let liarReason = await secretsRefusalReason(store, after: beforeLiar)
        let liarRefused = liarExit == 1 && liar.errorText == "nxtrm: Next Term refused this request."
        check(liarRefused && liar.stdout.isEmpty && liarReason == "its arguments are not nxtrm secret run's" && requests.showing == nil,
              "secrets: a wrapper whose argv is not the one it sent is refused for that, with no panel and nothing on stdout",
              "\(liar.errorText) (\(liarReason))")
        await secretsArgumentCapChecks(requests: requests, store: store)
    }

    /// The probe a wrapped command runs in its folder: the descriptors open above 2, one a line, into `<prefix>fds`, and
    /// how SIGPIPE, SIGINT and SIGTERM stand ("DEFAULT" or "IGNORE" each) into `<prefix>signals`. macOS's ps has no
    /// column for ignored signals; perl, with no PERL5OPT, reads each as it inherited it.
    static func secretsDescriptorsAndSignals(prefix: String) -> String {
        let descriptors = "for n in 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 255; do "
            + "if [ -e /dev/fd/$n ]; then echo $n >> \(prefix)fds; fi; done; "
        let signals = #"PERL5OPT= /usr/bin/perl -e 'print join " ", map { defined $SIG{$_} ? $SIG{$_} : "DEFAULT" } qw(PIPE INT TERM)'"#
        return descriptors + signals + " > \(prefix)signals"
    }

    /// The control for the allowed wrapper's check: the careless parent alone, with no wrapper between it and the probe,
    /// leaves fd 7 open and the three signals ignored. Without it, a pass there could mean the parent was never careless.
    static func secretsCarelessParentCheck(in folder: URL) async {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/sh")
        probe.arguments = ["-c", SecretsWrapperRun.carelessParent + "; exec \"$@\"", "sh",
                           "/bin/sh", "-c", secretsDescriptorsAndSignals(prefix: "control-")]
        probe.currentDirectoryURL = folder
        probe.standardInput = FileHandle.nullDevice
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        let ran = (try? probe.run()) != nil
        var ended = false
        if ran { ended = await wait(10) { !probe.isRunning } }
        if ran, !ended { kill(probe.processIdentifier, SIGKILL) }
        func read(_ name: String) -> String {
            let text = (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let fds = read("control-fds"), signals = read("control-signals")
        check(ended && fds == "7" && signals == "IGNORE IGNORE IGNORE",
              "secrets: the careless parent the wrapper starts from leaves fd 7 open and SIGPIPE, SIGINT and SIGTERM ignored",
              "ran \(ran), fds [\(fds)], PIPE INT TERM \(signals)")
    }

    /// The outcome of the first `refused` audit line after the log's first `before` lines, once the main thread wrote it
    /// (the socket queues it there after its answer): "no refused line" when none comes within `seconds`.
    static func secretsRefusalReason(_ store: SecretsStore, after before: Int, within seconds: Double = 5) async -> String {
        func found() -> SecretAudit.Line? {
            let lines = secretsAudit(store)
            // A log that rotated in between starts over.
            let fresh = lines.count >= before ? lines.dropFirst(before) : lines[...]
            return fresh.first { $0.event == .refused }
        }
        _ = await wait(seconds) { found() != nil }
        guard let line = found() else { return "no refused line" }
        return line.outcome ?? "no reason"
    }

    /// `ProcessInspector.fullCommandLine`'s cap on a wrapper's whole argv, its own path included.
    static let secretsArgumentCap = 4096

    /// A wrapper's argv at the cap, and one over it, padded by `/bin/sh` as it execs. Both ask for NOT_STORED, which shows
    /// no panel: at the cap the app reads the argv and answers that the name is not stored (exit 2); one over, it refuses
    /// before it reads the names, for the caps.
    static func secretsArgumentCapChecks(requests: SecretRequests, store: SecretsStore) async {
        let arguments = ["NOT_STORED", "--", "/usr/bin/true"]
        let padding = secretsArgumentCap - SecretsWrapperRun.ownArguments - arguments.count

        let atCap = SecretsWrapperRun(arguments, padding: padding)
        let beforeAtCap = secretsAudit(store).count
        _ = atCap.start()
        let atCapExit = await atCap.finish()
        let atCapReason = await secretsRefusalReason(store, after: beforeAtCap, within: 1)
        let atCapAnswered = atCapExit == 2 && atCap.errorText.contains("no key named NOT_STORED")
        check(atCapAnswered && atCap.stdout.isEmpty && atCapReason == "no refused line" && requests.showing == nil,
              "secrets: a wrapper with 4,096 arguments in all, its own path included, gets past the caps (a name not stored: exit 2)",
              "exit \(String(describing: atCapExit)), \(atCap.errorText) (\(atCapReason))")

        let over = SecretsWrapperRun(arguments, padding: padding + 1)
        let beforeOver = secretsAudit(store).count
        _ = over.start()
        let overExit = await over.finish()
        let overReason = await secretsRefusalReason(store, after: beforeOver)
        let overRefused = overExit == 1 && over.errorText == "nxtrm: Next Term refused this request."
        check(overRefused && over.stdout.isEmpty && overReason == "its arguments are over the caps or can't be read" && requests.showing == nil,
              "secrets: a wrapper with 4,097 arguments in all is refused for the caps, with no panel and nothing on stdout",
              "exit \(String(describing: overExit)), \(over.errorText) (\(overReason))")
    }
}

extension SelfTest {
    // MARK: the MCP tools

    /// A secret tool called in-process as a local agent's call, its answer as JSON.
    static func secretsTool(_ tool: String, _ arguments: [String: Any], pid: pid_t? = nil, approval: MCPApproval = .askOnMac,
                            requester: String? = nil, connection: String? = nil) async -> [String: Any] {
        await withCheckedContinuation { continuation in
            MCPControl.call(tool, arguments, caller: pid, approval: approval, requester: requester, connection: connection) { result in
                let object = (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any]
                continuation.resume(returning: object ?? ["error": result.text, "isError": result.isError])
            }
        }
    }

    /// A call that waits for the user, started now and awaited later.
    static func secretsStart(_ tool: String, _ arguments: [String: Any], pid: pid_t? = nil, requester: String? = nil,
                             connection: String? = nil, approval: MCPApproval = .askOnMac) -> Task<[String: Any], Never> {
        Task { @MainActor in await secretsTool(tool, arguments, pid: pid, approval: approval, requester: requester, connection: connection) }
    }

    static func secretsJSON(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    static func secretsToolChecks(_ c: TerminalWindowController, base: URL, proj: URL) async {
        let requests = SecretRequests.shared
        let store = SecretsStore.shared
        requests.resetForSelfTest()
        let savedWithin = SecretsMCP.answerWithin
        let savedWindow = SecretRequests.ticketWindow
        defer {
            requests.resetForSelfTest()
            SecretsMCP.answerWithin = savedWithin
            SecretRequests.ticketWindow = savedWindow
        }
        let value = secretsValue("tool")
        _ = try? await store.perform(.add(name: "TOOL_KEY", purpose: "the tool checks", purposeBy: .user, origin: .settings,
                                          writeOnly: false, value: SecretBytes(utf8: value)))
        await secretsListChecks(value: value)
        await secretsRequestChecks()
        await secretsStoreToolChecks(c, base: base)
        await secretsRunChecks(c, base: base, proj: proj, value: value)
        await secretsArrivalChecks(c)
        for name in store.index?.names ?? [] { _ = try? await store.perform(.delete(name: name)) }
    }

    /// list_secrets: names and facts, never a value; a tampered vault lists nothing.
    static func secretsListChecks(value: String) async {
        let store = SecretsStore.shared
        let listed = await secretsTool("list_secrets", [:])
        let rows = listed["secrets"] as? [[String: Any]] ?? []
        let row = rows.first { $0["name"] as? String == "TOOL_KEY" }
        check(listed["vault"] as? String == "ok" && row?["for"] as? String == "the tool checks" && row?["purpose_by"] as? String == "user"
              && row?["added_by"] as? String == "user" && row?["write_only"] as? Bool == false && listed["protected_by"] as? String == "secure-enclave"
              && !secretsJSON(listed).contains(value),
              "secrets: list_secrets gives names, what each is for, who wrote it and added it, and the protection, and no value",
              secretsJSON(listed))

        // A vault changed by hand: the first use finds it, and list_secrets then names nothing.
        let vaultPath = store.folder.path(SecretFolder.vaultName)
        guard let original = FileManager.default.contents(atPath: vaultPath),
              let planted = secretsTampered(original, { $0["purpose"] = "changed by hand" }) else {
            return check(false, "secrets: a tampered vault for list_secrets")
        }
        try? store.folder.write(SecretFolder.vaultName, data: planted)
        store.reloadIfChanged()
        _ = try? await store.perform(.reveal(name: "TOOL_KEY"))
        let tampered = await secretsTool("list_secrets", [:])
        check(tampered["vault"] as? String == "tampered" && (tampered["secrets"] as? [Any])?.isEmpty == true,
              "secrets: with a tampered vault, list_secrets answers tampered and lists no names", secretsJSON(tampered))
        try? store.folder.write(SecretFolder.vaultName, data: original)
        await store.load()
    }

    /// request_secret: the window, the prefilled purpose, Save, and the paste clear on the private pasteboard.
    static func secretsRequestChecks() async {
        let requests = SecretRequests.shared
        let reason = String(repeating: "to run the billing tests ", count: 20)
        let call = secretsStart("request_secret", ["name": "STRIPE_KEY", "reason": reason])
        _ = await wait(10) { requests.showing?.requestWindow != nil }
        guard let window = requests.showing?.requestWindow, let shown = window.window else {
            return check(false, "secrets: request_secret opens its window")
        }
        let purpose = window.purposeField.stringValue
        check(purpose.count <= 200 && purpose.hasSuffix("…") && shown.title == "An agent outside Next Term's tabs asks you to add STRIPE_KEY",
              "secrets: request_secret's window prefills what it's for with at most 200 characters, ending in …", "\(purpose.count): \(shown.title)")
        check(!shown.isKeyWindow && window.saveButton.keyEquivalent.isEmpty && window.declineButton.keyEquivalent.isEmpty
              && window.stopButton.keyEquivalent.isEmpty && !(shown is NSPanel),
              "secrets: the request window is an ordinary window that never takes the keyboard on its own and has no default button")
        let pasteboard = SecretClipboard.shared.pasteboard
        let general = NSPasteboard.general.changeCount
        pasteboard.clearContents()
        pasteboard.setString("sk_test-selftest_pasted_0123456789", forType: .string)
        window.valueField.stringValue = "sk_test-selftest_pasted_0123456789"
        window.recordPaste()
        window.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: window.valueField))
        window.saveButton.performClick(nil)
        let answer = await call.value
        check(answer["status"] as? String == "saved" && answer["name"] as? String == "STRIPE_KEY" && answer["replaced"] as? Bool == false
              && !secretsJSON(answer).contains("sk_test-selftest_pasted"),
              "secrets: the agent gets saved and the name, and no value", secretsJSON(answer))
        check(pasteboard.string(forType: .string) == nil && window.statusLabel.stringValue.contains(SecretClipboard.clearedLine)
              && NSPasteboard.general.changeCount == general,
              "secrets: a paste into the value field is cleared on Save, on the self-test's own pasteboard",
              window.statusLabel.stringValue)
        window.close()

        // No answer within the wait: pending with a request id, then the answer when it comes.
        SecretsMCP.answerWithin = 1
        let first = await secretsTool("request_secret", ["name": "LATER_KEY", "reason": "later"])
        let id = first["request_id"] as? String ?? ""
        check(first["status"] as? String == "pending" && !id.isEmpty, "secrets: an unanswered request answers pending with a request id",
              secretsJSON(first))
        requests.showing?.requestWindow?.declineButton.performClick(nil)
        let polled = await secretsTool("request_secret", ["request_id": id])
        let stranger = await secretsTool("request_secret", ["request_id": "nosuchid"])
        check(polled["status"] as? String == "declined" && stranger["status"] as? String == "refused" && stranger["note"] as? String == "No such request.",
              "secrets: asking again with the request id gives the answer; an unknown id is no such request", secretsJSON(polled))
        SecretsMCP.answerWithin = 50
    }

    /// store_secret: the panel's lines, Save, masking from then on, and replacing a key the user added.
    static func secretsStoreToolChecks(_ c: TerminalWindowController, base: URL) async {
        let requests = SecretRequests.shared
        let store = SecretsStore.shared
        let value = secretsValue("deploy")
        let call = secretsStart("store_secret", ["name": "DEPLOY_TOKEN", "value": value, "reason": "made for the deploy script"])
        _ = await wait(10) { requests.showing?.panel != nil }
        guard let panel = requests.showing?.panel, let window = panel.window else { return check(false, "secrets: store_secret shows the panel") }
        let shown = texts(window.contentView)
        check(shown.contains("This key is already in the agent's conversation.") && panel.durationChoice.isEmpty && panel.pauseButton.isHidden
              && panel.allowButton.title == "Save" && window.title == "An agent outside Next Term's tabs asks to save a key it holds"
              && !shown.contains(value),
              "secrets: store_secret's panel says the value is in the agent's conversation, has Save and no How long, and never shows the value",
              shown)
        panel.allowButton.performClick(nil)
        let saved = await call.value
        let entry = store.index?.entry(named: "DEPLOY_TOKEN")
        check(saved["status"] as? String == "saved" && saved["replaced"] as? Bool == false && entry?.origin == .agent
              && entry?.purpose == "made for the deploy script" && entry?.purposeBy == .agent,
              "secrets: Save stores the agent's key, with its reason as what it's for", secretsJSON(saved))

        // A tab that prints it: read_tab shows •••.
        let file = base.appendingPathComponent("deploy.txt")
        try? value.write(to: file, atomically: true, encoding: .utf8)
        let tab = c.addTab(directory: base.path, select: false)
        defer { closeSecretsTabs([tab], "store_secret") }
        if await wait(20, { tab.status.integrated }) {
            tab.view.send(txt: "cat \(ShellQuote.quote(file.path)); echo\r")
            _ = await wait(10) { tab.screenTail().joined().contains(value) }
            let read = await secretsTool("read_tab", ["tab_id": tab.id.uuidString.lowercased()])
            check((read["screen"] as? String).map { $0.contains("•••") && !$0.contains(value) } == true,
                  "secrets: read_tab of a tab that prints a key store_secret saved shows •••")
        }

        // Replacing a key the user added: its title and warning, and the audit line's earlier origin.
        _ = try? await store.perform(.add(name: "USER_KEY", purpose: "mine", purposeBy: .user, origin: .settings, writeOnly: false,
                                          value: SecretBytes(utf8: secretsValue("user"))))
        let replace = secretsStart("store_secret", ["name": "USER_KEY", "value": secretsValue("agentsown"), "reason": "rotated"])
        _ = await wait(10) { requests.showing?.panel != nil }
        let replacing = requests.showing?.panel
        let replaceShown = texts(replacing?.window?.contentView)
        check(replacing?.window?.title == "An agent outside Next Term's tabs asks to replace USER_KEY, a key you added"
              && replaceShown.contains("This replaces the key you added on") && replaceShown.contains("will get the agent's value"),
              "secrets: store_secret replacing a key the user added says so in its title and a warning", replaceShown)
        replacing?.allowButton.performClick(nil)
        let replaced = await replace.value
        let line = secretsAudit(store).last
        check(replaced["replaced"] as? Bool == true && line?.event == .replace && line?.earlierOrigin == "settings"
              && store.index?.entry(named: "USER_KEY")?.purpose == "mine",
              "secrets: the replace keeps what the key is for, and its audit line holds the earlier origin",
              "\(line?.event.rawValue ?? "none") \(line?.earlierOrigin ?? "none")")
    }

    /// run_with_secrets: the tab, the ticket line, the panel, the run; tab_id; grants and the .env; refusals; tickets.
    static func secretsRunChecks(_ c: TerminalWindowController, base: URL, proj: URL, value: String) async {
        let requests = SecretRequests.shared
        let app = AppDelegate.shared!
        let folder = proj.appendingPathComponent("secrets-run", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var opened: [TerminalTab] = []
        defer {
            closeSecretsTabs(opened, "run_with_secrets")
            try? FileManager.default.removeItem(at: folder)
        }
        func newTabs(since before: Set<UUID>) -> [TerminalTab] {
            app.controllers.flatMap(\.tabs).filter { !before.contains($0.id) }
        }
        func tabIDs() -> Set<UUID> { Set(app.controllers.flatMap(\.tabs).map(\.id)) }
        func screen(_ tab: TerminalTab?) -> String { tab.map { $0.screenTail().joined(separator: "\n") } ?? "" }
        let command = #"printf "%s" "$K" | wc -c | tr -d ' '; echo LEN"#
        let arguments: [String: Any] = ["secrets": ["TOOL_KEY=K"], "command": command, "directory": folder.path, "reason": "the length"]

        // A new tab, the ticket line in the self-test form, the panel, Allow, the run. The tab is the ticket's, found by
        // its id: a folder no window holds gets a new project window first, whose own first tab is new too. The ticket
        // is read before its wrapper redeems it, which drops it.
        let before = tabIDs()
        let call = secretsStart("run_with_secrets", arguments)
        var ticket: (id: String, tab: UUID)?
        _ = await wait(15) {
            if ticket == nil, let made = requests.tickets.values.first(where: { !before.contains($0.tabID) }) {
                ticket = (made.id, made.tabID)
            }
            return requests.showing?.panel != nil
        }
        let tab = app.controllers.flatMap(\.tabs).first { $0.id == ticket?.tab }
        // Whether it is its window's selected tab now, as it opened: nothing has chosen a tab since.
        let selectedThen = tab.flatMap { tab in MCPControl.controller(of: tab).map { $0.activeTab === tab } }
        opened += newTabs(since: before)
        // The screen's rows, without their breaks or spaces: the ticket line is longer than a row.
        let typed = secretsUnwrapped(screen(tab))
        let ticketWords = "secretrun--ticket" + (ticket?.id ?? "none")
        check(tab != nil && typed.contains("--self-test-secret-wrapper") && typed.contains(ticketWords)
              && !typed.contains(secretsUnwrapped(command)),
              "secrets: run_with_secrets opens a tab and types only the ticket line, in the self-test form", String(screen(tab).suffix(300)))
        // As any tab an agent opens (AgentArrival): selected or not, as its window allows, it waits for the user's click.
        let tabWindow = tab.flatMap { MCPControl.controller(of: $0)?.window }
        check(tab?.view.awaitsChoice == true && tabWindow != nil && tabWindow?.firstResponder !== tab?.view,
              "secrets: the new tab does not take the keyboard until the user clicks it",
              "waits \(tab?.view.awaitsChoice == true), first responder \(String(describing: tabWindow?.firstResponder))")
        // Its title names the program and the key, and it counts as driven by MCP. Asked from outside Next Term's tabs,
        // it has no opened_by (the late ticket below is asked from a tab).
        let isDriven = tab.map { MCPControl.isDriven($0) } ?? false
        check(tab?.userTitle == "printf · with TOOL_KEY" && isDriven && tab?.openedBy == nil,
              "secrets: the new tab's title names the program and the key, it counts as driven by MCP, and it has no opened_by",
              "\(tab?.userTitle ?? "no title"), driven \(isDriven), opened by \(tab?.openedBy?.uuidString ?? "none")")
        let panel = requests.showing?.panel
        let title = panel?.window?.title ?? ""
        check(title == "A program outside Next Term's tabs asks to run printf with TOOL_KEY"
              && texts(panel?.window?.contentView).contains("Runs as a shell command") && panel?.durationChoice[.untilLock] == nil,
              "secrets: the panel shows the command as a shell command, with no until-the-Mac-locks choice", title)
        panel?.allowButton.performClick(nil)
        let started = await call.value
        let length = String(value.utf8.count)
        let ran = await wait(15) { screen(tab).contains("\(length)LEN") || screen(tab).contains("\(length)\nLEN") }
        check(started["status"] as? String == "started" && started["approved"] as? String == "once"
              && started["tab_id"] as? String == tab?.id.uuidString.lowercased() && selectedThen != nil
              && started["selected"] as? Bool == selectedThen && ran && !secretsJSON(started).contains(value),
              "secrets: after Allow the command runs in its tab with the key, and the agent gets started with the tab's id "
                  + "and whether it was its window's selected tab when it opened",
              secretsJSON(started) + ", selected then \(String(describing: selectedThen))")
        if let tab {
            _ = await wait(10) { !tab.status.running }
            // zsh's fc lists the lines before the one running it. The bracket in each pattern keeps this line's own
            // text from matching: none of the last nine holds the command, and the last one is the ticket line.
            let ticketPattern = "[-]-ticket " + (ticket?.id ?? "none")
            let history = "echo HIST$(fc -ln -9 | grep -c 'w[c] -c')LAST$(fc -ln -1 | grep -c '\(ticketPattern)')"
            tab.view.send(txt: "if [ -z \"${K+x}\" ]; then echo NO\"\"K; fi; \(history)\r")
            let clean = await wait(10) { screen(tab).contains("NOK") && secretsUnwrapped(screen(tab)).contains("HIST0LAST1") }
            check(clean, "secrets: the tab's shell has no K after the run, and its history holds only the ticket line", String(screen(tab).suffix(200)))
        }
        // A used ticket can't be used again.
        let ticketID = ticket?.id ?? ""
        let reuse = SecretsWrapperRun(["--ticket", ticketID])
        _ = reuse.start()
        let reuseExit = await reuse.finish()
        check(SecretRun.isTicket(ticketID) && reuseExit == 1 && reuse.errorText.contains("expired or was used already") && requests.showing == nil,
              "secrets: a used ticket gets expired", reuse.errorText)
        // The shell read the self-test's own zsh config, never the user's: its ZDOTDIR, as zsh has it once started.
        if let tab {
            let own = SelfTest.shellConfigFolder ?? ""
            if await wait(10, { !tab.status.running }) {
                tab.view.send(txt: "[[ ${ZDOTDIR-} == \(ShellQuote.quote(own)) ]] && echo ZD\"\"OWN || echo ZD\"\"OTHER=${ZDOTDIR-unset}\r")
                let answered = await wait(10) { screen(tab).contains("ZDOWN") || screen(tab).contains("ZDOTHER=") }
                check(!own.isEmpty && answered && screen(tab).contains("ZDOWN"),
                      "secrets: the tab run_with_secrets opens reads the self-test's own zsh config, not the user's",
                      "test config \(own), " + (answered ? String(screen(tab).suffix(200)) : "no answer"))
            } else {
                note("secrets: the zsh config of the tab run_with_secrets opened was not asked: its shell stayed busy")
            }
        }

        #if DEBUG
        await secretsRunTwiceChecks(arguments: arguments, value: value, opened: &opened)
        #endif

        // "Allow for 15 minutes": the same call starts with no panel, until the folder's .env changes.
        let again = secretsStart("run_with_secrets", arguments)
        _ = await wait(15) { requests.showing?.panel != nil }
        for tab in newTabs(since: before) where !opened.contains(where: { $0 === tab }) { opened.append(tab) }
        requests.showing?.panel?.durationChoice[.fifteenMinutes]?.performClick(nil)
        requests.showing?.panel?.allowButton.performClick(nil)
        _ = await again.value
        let granted = await secretsTool("run_with_secrets", arguments)
        for tab in newTabs(since: before) where !opened.contains(where: { $0 === tab }) { opened.append(tab) }
        check(granted["status"] as? String == "started" && granted["approved"] as? String == "by an earlier approval",
              "secrets: within 15 minutes the same call starts with no panel", secretsJSON(granted))
        try? "OPENAI_BASE_URL=https://example.invalid\n".write(to: folder.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let changed = secretsStart("run_with_secrets", arguments)
        let asked = await wait(15) { requests.showing?.panel != nil }
        for tab in newTabs(since: before) where !opened.contains(where: { $0 === tab }) { opened.append(tab) }
        check(asked && texts(requests.showing?.panel?.window?.contentView).contains(".env in this folder sets OPENAI_BASE_URL. The key may go to that address."),
              "secrets: after the .env changes, the same call shows the panel again, with its warning")
        requests.showing?.panel?.declineButton.performClick(nil)
        let declined = await changed.value
        // Its tab, by the answer's tab_id, is still open and shows the wrapper's line, so the agent can read why.
        let declinedTab = app.controllers.flatMap(\.tabs).first { $0.id.uuidString.lowercased() == declined["tab_id"] as? String }
        let saysWhy = await wait(10) { secretsUnwrapped(screen(declinedTab)).contains("nxtrm:NextTermdeclined") }
        check(declined["status"] as? String == "declined" && declinedTab?.exited == false && saysWhy,
              "secrets: a declined run answers declined and names the tab, which stays open", secretsJSON(declined))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(".env"))
        requests.revokeAll()

        await secretsRunTabChecks(c, folder: folder, base: base, opened: &opened)
        await secretsRunRefusalChecks(folder: folder, value: value, arguments: arguments, before: tabIDs())
        await secretsTicketChecks(c, folder: folder, arguments: arguments, opened: &opened)
    }

    /// tab_id: the tab's environment warns before Allow, the command runs in directory, and the tabs that are refused.
    static func secretsRunTabChecks(_ c: TerminalWindowController, folder: URL, base: URL, opened: inout [TerminalTab]) async {
        let requests = SecretRequests.shared
        let tab = c.addTab(directory: base.path, select: false)
        opened.append(tab)
        guard await wait(20, { tab.status.integrated }) else { return check(false, "secrets: a tab for tab_id") }
        tab.view.send(txt: "export NODE_OPTIONS=--no-warnings\r")
        _ = await wait(5) { !tab.status.running }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let id = tab.id.uuidString.lowercased()
        let call = secretsStart("run_with_secrets", ["secrets": ["TOOL_KEY"], "command": "pwd > where", "directory": folder.path, "tab_id": id])
        _ = await wait(15) { requests.showing?.panel != nil }
        let shown = texts(requests.showing?.panel?.window?.contentView)
        check(shown.contains("NODE_OPTIONS is set: it can change what this command runs.") && shown.contains("with that tab's environment"),
              "secrets: with tab_id, the panel names that tab and warns about its NODE_OPTIONS before Allow", shown)
        requests.showing?.panel?.allowButton.performClick(nil)
        _ = await call.value
        let whereFile = folder.appendingPathComponent("where")
        let ranThere = await wait(10) { (try? String(contentsOf: whereFile, encoding: .utf8))?.contains(folder.path) == true }
        check(ranThere, "secrets: with tab_id of a tab in another folder, the command runs in directory")

        // The caller's own tab, a busy tab, a tab that is not there.
        _ = await wait(10) { !tab.status.running }
        let own = await secretsTool("run_with_secrets", ["secrets": ["TOOL_KEY"], "command": "true", "directory": folder.path, "tab_id": id],
                                    pid: tab.view.process.shellPid)
        check(own["status"] as? String == "refused" && (own["note"] as? String)?.contains("your own tab") == true,
              "secrets: tab_id of the caller's own tab is refused", secretsJSON(own))
        tab.view.send(txt: "sleep 20\r")
        _ = await wait(5) { tab.status.running }
        let busy = await secretsTool("run_with_secrets", ["secrets": ["TOOL_KEY"], "command": "true", "directory": folder.path, "tab_id": id])
        check(busy["status"] as? String == "refused" && (busy["note"] as? String)?.contains("running something") == true,
              "secrets: tab_id of a busy tab is refused", secretsJSON(busy))
        tab.view.send(txt: "\u{03}")
        // A remote tab is refused the same way (givenTab): the self-test opens none.

        // fish, when it is installed: the line is quoted for it and runs.
        let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let fish else { return }
        let fishTab = c.addTab(directory: base.path, select: false)
        opened.append(fishTab)
        guard await wait(20, { fishTab.status.integrated }) else { return }
        fishTab.view.send(txt: "exec \(fish) --no-config\r")
        _ = await wait(10) { SecretsMCP.shellName(of: fishTab) == "fish" }
        try? await Task.sleep(nanoseconds: 500_000_000)
        let fishCall = secretsStart("run_with_secrets", ["secrets": ["TOOL_KEY"], "command": "true", "directory": folder.path,
                                                          "tab_id": fishTab.id.uuidString.lowercased()])
        let fishAsked = await wait(15) { requests.showing?.panel != nil }
        check(fishAsked, "secrets: in a fish tab the ticket line runs and asks", fishTab.screenTail().suffix(3).joined(separator: " | "))
        requests.showing?.panel?.declineButton.performClick(nil)
        _ = await fishCall.value
    }

    /// Refusals before any tab: a stored value in the command, a reached count, a vault that can't open.
    static func secretsRunRefusalChecks(folder: URL, value: String, arguments: [String: Any], before: Set<UUID>) async {
        let requests = SecretRequests.shared
        let store = SecretsStore.shared
        func tabCount() -> Int { AppDelegate.shared.controllers.flatMap(\.tabs).count }
        let count = tabCount()
        let holding = await secretsTool("run_with_secrets", ["secrets": ["TOOL_KEY"], "command": "echo \(value)", "directory": folder.path])
        check(holding["status"] as? String == "value_in_command" && tabCount() == count && !secretsJSON(holding).contains(value),
              "secrets: a command holding a stored value gets value_in_command, and no tab opens", secretsJSON(holding))
        let unknown = await secretsTool("run_with_secrets", ["secrets": ["NOT_STORED"], "command": "true", "directory": folder.path])
        check(unknown["status"] as? String == "unknown" && tabCount() == count, "secrets: a name not stored gets unknown, and no tab opens")
        // "\r\n" is one Character: the one-line check goes by scalar, so /bin/sh never gets a second line.
        let twoLines = await secretsTool("run_with_secrets", ["secrets": ["TOOL_KEY"], "command": "true\r\necho second", "directory": folder.path])
        check(twoLines["status"] as? String == "refused" && tabCount() == count,
              "secrets: a command with a CRLF in it is refused, and no tab opens", secretsJSON(twoLines))

        // The asker's count: ten declines, then limited, with no tab.
        requests.resetForSelfTest()
        for index in 0..<10 {
            let request = secretsRequest(asker: "outside", command: ["count \(index)"], source: .tool, names: ["TOOL_KEY"], agent: nil)
            requests.ask(request) { _ in }
            request.panel?.declineButton.performClick(nil)
        }
        let limited = await secretsTool("run_with_secrets", arguments)
        check(limited["status"] as? String == "limited" && tabCount() == count,
              "secrets: with the asker's count reached, run_with_secrets gets limited and opens no tab", secretsJSON(limited))
        requests.resetForSelfTest()

        // A vault this Mac's keyring can't open.
        let vaultPath = store.folder.path(SecretFolder.vaultName)
        let original = FileManager.default.contents(atPath: vaultPath)
        let other = SoftwareKeyring(kind: .secureEnclave)
        if let original, let made = try? SecretVault.create(keyring: other),
           let foreign = try? made.vault.add(name: "TOOL_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                             value: SecretBytes(utf8: secretsValue("foreign"))) {
            try? store.folder.write(SecretFolder.vaultName, data: foreign)
            await store.load()
            let cant = await secretsTool("run_with_secrets", arguments)
            check(store.protection == .cantOpen && cant["status"] as? String == "cant_open" && tabCount() == count,
                  "secrets: with a vault the keyring can't open, run_with_secrets gets cant_open and opens no tab", secretsJSON(cant))
            try? store.folder.write(SecretFolder.vaultName, data: original)
            await store.load()
        }
    }

    /// Tickets: one redeemed from outside its tab is refused; one not redeemed in time ends.
    static func secretsTicketChecks(_ c: TerminalWindowController, folder: URL, arguments: [String: Any],
                                    opened: inout [TerminalTab]) async {
        let requests = SecretRequests.shared
        let before = Set(AppDelegate.shared.controllers.flatMap(\.tabs).map(\.id))
        let call = secretsStart("run_with_secrets", arguments)
        _ = await wait(10) { requests.tickets.values.first?.typedAt != nil }
        let id = requests.tickets.keys.first ?? ""
        // Redeemed from no tab of Next Term's, before the tab's own wrapper starts: refused, and the ticket waits on.
        var outside: SecretRun.Answer?
        let asked = SecretRun.Request(names: [], map: [:], argv: [], executable: "", directory: "/", argvFull: [], warn: [:], ticket: id)
        requests.redeem(ticket: id, peerTab: nil, request: asked) { outside = $0 }
        check(outside?.status == .refused && requests.tickets[id] != nil,
              "secrets: a ticket redeemed from outside its tab is refused, and its own tab can still redeem it")
        // From another of Next Term's tabs, in the same turn, so still before the ticket's own wrapper.
        let ticketTab = requests.tickets[id]?.tabID
        let otherTab = AppDelegate.shared.controllers.flatMap(\.tabs).first { $0.id != ticketTab }
        var fromOther: SecretRun.Answer?
        if let otherTab, ticketTab != nil { requests.redeem(ticket: id, peerTab: otherTab, request: asked) { fromOther = $0 } }
        check(fromOther?.status == .refused && requests.tickets[id] != nil,
              "secrets: a ticket redeemed from another of Next Term's tabs is refused, and its own tab can still redeem it")
        _ = await wait(15) { requests.showing?.panel != nil }
        requests.showing?.panel?.declineButton.performClick(nil)
        _ = await call.value
        requests.resetForSelfTest()

        // Asked from a tab of Next Term's (its shell's pid stands for an agent there): the new tab's opened_by is that tab.
        // The window's own tab, never one run_with_secrets opened above, which may now be its selected one.
        let asker = c.tabs.first { tab in
            !MCPControl.isDriven(tab) && !opened.contains { $0 === tab } && !tab.exited && tab.remote == nil
        }
        SecretRequests.ticketWindow = .milliseconds(150)
        let late = await secretsTool("run_with_secrets", ["secrets": ["TOOL_KEY"], "command": "true", "directory": folder.path],
                                     pid: asker?.view.process.shellPid)
        // The note may go on to say where the tab opened (AgentArrival).
        let lateNote = late["note"] as? String ?? ""
        check(late["status"] as? String == "refused" && lateNote.hasPrefix("The tab's shell did not start nxtrm within 30 seconds."),
              "secrets: a ticket not redeemed in time ends refused", secretsJSON(late))
        SecretRequests.ticketWindow = .seconds(30)
        for tab in AppDelegate.shared.controllers.flatMap(\.tabs) where !before.contains(tab.id) { opened.append(tab) }
        // Its tab by the id in the answer: a new tab goes in after the window's active one, so not always last.
        let lateTab = opened.first { $0.id.uuidString.lowercased() == late["tab_id"] as? String }
        func expired() -> Bool {
            secretsUnwrapped(lateTab?.screenTail().joined() ?? "").contains(secretsUnwrapped("expired or was used already"))
        }
        _ = await wait(10) { expired() }
        check(lateTab != nil && expired(), "secrets: its wrapper, starting late, gets expired",
              lateTab.map { String($0.screenTail().joined(separator: "\n").suffix(200)) } ?? "no tab with the answer's tab_id")
        check(asker != nil && lateTab?.openedBy == asker?.id, "secrets: a tab run_with_secrets opens for an agent in a tab has that tab as its opened_by",
              "opened by \(lateTab?.openedBy?.uuidString ?? "none"), asked from \(asker?.id.uuidString ?? "no tab")")
    }

    /// Text as it reads on the screen whatever the window's width: without line breaks or spaces, since a line longer
    /// than a row goes on in the next one, and a row's trailing spaces are trimmed.
    static func secretsUnwrapped(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }
}

extension SelfTest {
    // MARK: Settings › Secrets and Window › Secrets

    static func secretsSettingsChecks(base: URL) async {
        let store = SecretsStore.shared
        let requests = SecretRequests.shared
        requests.resetForSelfTest()
        defer { requests.resetForSelfTest() }

        // The last Settings tab, after Skills; Window › Secrets with no key.
        let tabs = (SettingsWindowController().window?.contentView as? NSTabView)?.tabViewItems.compactMap { $0.identifier as? String } ?? []
        let skills = tabs.firstIndex(of: "skills")
        check(tabs.last == "secrets" && skills.map { $0 < tabs.count - 1 } == true, "secrets: Secrets is the last Settings tab, after Skills",
              tabs.joined(separator: ", "))
        let windowMenu = NSApp.mainMenu?.items.first { $0.submenu?.title == "Window" }?.submenu
        let item = windowMenu?.items.first { $0.title == "Secrets" }
        let afterSkills = windowMenu.map { menu in
            (menu.items.firstIndex { $0.title == "Skills" } ?? -1) < (menu.items.firstIndex { $0.title == "Secrets" } ?? -1)
        } ?? false
        check(item != nil && item?.keyEquivalent == "" && item?.action == #selector(AppDelegate.showSecrets(_:)) && afterSkills,
              "secrets: Window › Secrets comes after Skills and has no key")
        AppDelegate.shared.showSecrets(nil)
        guard let controller = SecretsWindowController.shared, let window = controller.window, window.isVisible else {
            return check(false, "secrets: Window › Secrets opens its window")
        }
        defer { window.close() }
        let view = controller.secretsView
        guard let presence = store.presence as? StandInPresence else { return }

        // Add through the sheet; a write-only key has no Reveal or Copy, and says so under the table.
        func addThroughSheet(_ name: String, value: String, writeOnly: Bool) async {
            view.add()
            guard let sheet = view.sheet else { return check(false, "secrets: Add… opens its sheet") }
            sheet.nameField.stringValue = name.lowercased().replacingOccurrences(of: "_", with: "-")
            sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: sheet.nameField))
            sheet.purposeField.stringValue = "the Settings checks"
            sheet.valueField.stringValue = value
            sheet.writeOnlyBox.state = writeOnly ? .on : .off
            sheet.refresh()
            sheet.saveButton.performClick(nil)
            _ = await wait(10) { view.entries.contains { $0.name == name } && view.sheet == nil }
        }
        let shownValue = secretsValue("shown")
        await addThroughSheet("SHOWN_KEY", value: shownValue, writeOnly: false)
        await addThroughSheet("HIDDEN_KEY", value: secretsValue("hidden"), writeOnly: true)
        check(view.entries.map(\.name).contains("SHOWN_KEY") && view.entries.first { $0.name == "HIDDEN_KEY" }?.writeOnly == true,
              "secrets: Add… through the sheet lists the key, its name made capitals with _ as typed")
        view.select("HIDDEN_KEY")
        check(!view.revealButton.isEnabled && !view.copyButton.isEnabled && view.editButton.isEnabled && view.replaceButton.isEnabled
              && view.deleteButton.isEnabled && !view.writeOnlyLabel.isHidden && view.writeOnlyLabel.stringValue == SecretsView.writeOnlyLine,
              "secrets: a write-only key has Reveal and Copy off, Edit, Replace and Delete on, and the line under the table")

        // Make Write-Only… asks first; Cancel changes nothing.
        view.select("SHOWN_KEY")
        let calls = presence.calls
        view.writeOnlyButton.performClick(nil)
        _ = await wait(5) { view.alert != nil }
        let asked = view.alert?.messageText == "Make SHOWN_KEY write-only?"
        view.alert?.buttons.last?.performClick(nil)
        _ = await wait(5) { view.alert == nil }
        check(asked && store.index?.entry(named: "SHOWN_KEY")?.writeOnly == false && presence.calls == calls,
              "secrets: Make Write-Only… asks first, and Cancel changes nothing")

        // Copy, on the self-test's own pasteboard: this Mac only, both markers, cleared after the delay unless changed.
        let clipboard = SecretClipboard.shared
        let general = NSPasteboard.general.changeCount
        clipboard.clearAfter = 0.5
        defer { clipboard.clearAfter = 60 }
        view.copyButton.performClick(nil)
        _ = await wait(10) { clipboard.pasteboard.string(forType: .string) == shownValue }
        let types = clipboard.pasteboard.types ?? []
        check(clipboard.preparedForThisMacOnly && types.contains(SecretClipboard.concealedType) && types.contains(SecretClipboard.transientType)
              && view.actionLabel.stringValue == SecretClipboard.copiedLine,
              "secrets: Copy puts the key on the pasteboard for this Mac only, marked concealed and transient, and says it clears in 60 seconds",
              types.map(\.rawValue).joined(separator: ", "))
        #if DEBUG
        // One pasteboard write holds the value with both markers, read back from the pasteboard: nothing there just
        // before it, all three just after it, and nothing written since. A clipboard manager reading between writes
        // never sees the value unmarked.
        let write = clipboard.lastCopyWrite
        let marked = [SecretClipboard.concealedType, SecretClipboard.transientType, .string]
        let before = write?.before ?? [.string]
        let after = write?.after ?? []
        check(before.isEmpty && marked.allSatisfy(after.contains) && Set(after) == Set(types)
              && clipboard.pasteboard.pasteboardItems?.count == 1,
              "secrets: Copy writes the key in one write that holds the concealed and transient markers too",
              before.map(\.rawValue).joined(separator: "+") + " then " + after.map(\.rawValue).joined(separator: "+"))
        #endif
        let cleared = await wait(5) { clipboard.pasteboard.string(forType: .string) == nil }
        check(cleared, "secrets: Copy's pasteboard is cleared after the delay when nothing was copied since")
        view.copyButton.performClick(nil)
        _ = await wait(10) { clipboard.pasteboard.string(forType: .string) == shownValue }
        clipboard.pasteboard.clearContents()
        clipboard.pasteboard.setString("something else", forType: .string)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        check(clipboard.pasteboard.string(forType: .string) == "something else" && NSPasteboard.general.changeCount == general,
              "secrets: what was copied since is kept, and the general pasteboard was never touched")

        // Reveal shows the value in a field that can't be selected: only Copy puts a value on a pasteboard.
        view.select("SHOWN_KEY")
        view.revealButton.performClick(nil)
        _ = await wait(10) { view.revealField != nil }
        check(view.revealField?.stringValue == shownValue && view.revealField?.isSelectable == false,
              "secrets: Reveal shows the value after Touch ID, in a field that can't be selected or copied from")
        view.closeReveal()
        #if DEBUG
        await secretsRevealEndChecks(presence: presence, shownValue: shownValue)
        #endif

        // Allowed now lists a grant, and Revoke ends it.
        let request = secretsRequest(asker: "wrapper:selftest-settings", command: ["true"], names: ["SHOWN_KEY"])
        let answers = SecretsAnswers()
        requests.ask(request) { answers.take($0) }
        request.panel?.durationChoice[.fifteenMinutes]?.performClick(nil)
        request.panel?.allowButton.performClick(nil)
        _ = await wait(10) { !requests.grants.isEmpty }
        view.reload()
        // A wrapper's grant is named for the agent above it.
        let row = requests.grants.first.map { SecretsView.grantText($0) } ?? "no grant"
        let listed = view.allowedRows.count == 1 && row.hasPrefix("Codex: SHOWN_KEY for true in ")
        view.allowedRows.first?.revoke.performClick(nil)
        check(listed && requests.grants.isEmpty && view.allowedRows.isEmpty, "secrets: Allowed now lists a grant, named for its agent, and Revoke ends it",
              row)

        // With agent control off and a key stored, the line says what that means.
        SecretsView.agentControlIsOn = { false }
        view.reload()
        let offShown = !view.agentControlLabel.isHidden
        SecretsView.agentControlIsOn = { AppDelegate.shared.agentControl }
        view.reload()
        check(offShown && view.agentControlLabel.isHidden == AppDelegate.shared.agentControl,
              "secrets: with agent control off and a key stored, Settings › Secrets says agents can't use the keys")

        // A vault the keyring can't open: the text and Start Over… right after load(), before any use.
        let vaultPath = store.folder.path(SecretFolder.vaultName)
        if let original = FileManager.default.contents(atPath: vaultPath) {
            let other = SoftwareKeyring(kind: .secureEnclave)
            if let made = try? SecretVault.create(keyring: other),
               let foreign = try? made.vault.add(name: "SHOWN_KEY", purpose: "", purposeBy: .user, origin: .settings, writeOnly: false,
                                                 value: SecretBytes(utf8: secretsValue("foreign"))) {
                try? store.folder.write(SecretFolder.vaultName, data: foreign)
                let before = presence.calls
                await store.load()
                check(view.statusLabel.stringValue == SecretsView.cantOpenLine && !view.startOverButton.isHidden && presence.calls == before,
                      "secrets: a vault the keyring can't open shows the can't-open text and Start Over… right after load, with no Touch ID",
                      view.statusLabel.stringValue)
            }
            // A tampered one shows its text after its first use.
            if let planted = secretsTampered(original, { $0["purpose"] = "changed by hand" }) {
                try? store.folder.write(SecretFolder.vaultName, data: planted)
                await store.load()
                let quiet = view.statusLabel.stringValue != SecretsView.tamperedLine
                _ = try? await store.perform(.reveal(name: "SHOWN_KEY"))
                check(quiet && view.statusLabel.stringValue == SecretsView.tamperedLine && !view.startOverButton.isHidden,
                      "secrets: a tampered vault shows the tamper text and Start Over… after its first use", view.statusLabel.stringValue)
            }
            try? store.folder.write(SecretFolder.vaultName, data: original)
            await store.load()
        }
        for name in ["SHOWN_KEY", "HIDDEN_KEY"] { _ = try? await store.perform(.delete(name: name)) }
    }
}

extension SelfTest {
    // MARK: the import

    /// Fixture configs in a temporary home: the sheet moves one group, the files run the wrapper, the backups hold
    /// markers, and Undo puts the entries back. With agent control off, the sheet refuses.
    static func secretsImportChecks(base: URL) async {
        let store = SecretsStore.shared
        let home = base.appendingPathComponent("import-home", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: home.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let token = "ghp_" + "SelfTest" + secretsValue("")
        let cursor = home.appendingPathComponent(".cursor/mcp.json")
        let codex = home.appendingPathComponent(".codex/config.toml")
        let cursorText = """
            {
              // the self-test's servers
              "mcpServers": {
                "github": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"], "env": {"GITHUB_TOKEN": "\(token)"}},
                "other": {"command": "other-server"}
              }
            }

            """
        let codexText = """
            [mcp_servers.github]
            command = "npx"
            args = ["-y", "@modelcontextprotocol/server-github"]
            env = { GITHUB_TOKEN = "\(token)" }

            """
        try? cursorText.write(to: cursor, atomically: true, encoding: .utf8)
        try? codexText.write(to: codex, atomically: true, encoding: .utf8)
        func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

        let savedSetup = SecretsView.importSetup
        defer { SecretsView.importSetup = savedSetup }
        var setup = SecretImportSheet.Setup()
        setup.home = home.path
        setup.agentControl = false
        setup.lockWait = 0.5
        setup.nxtrm = SecretImportSheet.nxtrmCommand()
        SecretsView.importSetup = { setup }
        AppDelegate.shared.showSecrets(nil)
        guard let controller = SecretsWindowController.shared, let window = controller.window else {
            return check(false, "secrets: Window › Secrets for the import checks")
        }
        defer { window.close() }
        let view = controller.secretsView

        // Agent control off: the refusal, and nothing else.
        view.importKeys()
        let refused = view.importSheet
        check(refused?.headerLabel.stringValue == SecretImportSheet.refusal && refused?.groupRows.isEmpty == true && refused?.moveButton.isEnabled == false,
              "secrets: with agent control off, the import says to turn it on first and moves nothing", refused?.headerLabel.stringValue ?? "no sheet")
        refused?.closeSheet()
        _ = await wait(5) { view.importSheet == nil }

        // Run from a disk image or a translocated copy (no lasting nxtrm path): the refusal to move it first, and nothing else.
        check(setup.nxtrm != nil, "secrets: this run has an nxtrm command the import may write", "\(Bundle.main.bundlePath)")
        let lasting = setup.nxtrm
        setup.agentControl = true
        setup.nxtrm = nil
        SecretsView.importSetup = { setup }
        view.importKeys()
        let unplaced = view.importSheet
        // The scan runs off the main thread: long enough for one to have shown its rows, had it started.
        let scanned = await wait(2) { unplaced?.scan != nil || unplaced?.groupRows.isEmpty == false }
        check(unplaced?.headerLabel.stringValue == SecretImportSheet.placeRefusal && unplaced?.groupRows.isEmpty == true && !scanned
              && unplaced?.moveButton.isEnabled == false && read(cursor) == cursorText,
              "secrets: from a copy whose path won't last, the import says to move Next Term to Applications and moves nothing",
              unplaced?.headerLabel.stringValue ?? "no sheet")
        unplaced?.closeSheet()
        _ = await wait(5) { view.importSheet == nil }
        setup.nxtrm = lasting

        // On: one group for the token in two files, unticked; ticked and moved after the confirm and one Touch ID.
        SecretsView.importSetup = { setup }
        view.importKeys()
        guard let sheet = view.importSheet else { return check(false, "secrets: Import from MCP Configs… opens its sheet") }
        _ = await wait(10) { !sheet.groupRows.isEmpty }
        let row = sheet.groupRows.first
        check(sheet.groupRows.count == 1 && row?.box.state == .off && row?.group.name == "GITHUB_TOKEN" && row?.group.summary == "Same value in 2 servers"
              && !sheet.moveButton.isEnabled,
              "secrets: the import finds one key in two files, as one unticked group named after its variable",
              "\(sheet.groupRows.map(\.group.name))")
        sheet.tick("GITHUB_TOKEN")
        sheet.moveButton.performClick(nil)
        _ = await wait(5) { sheet.confirmAlert != nil }
        let confirm = sheet.confirmAlert
        check(confirm?.messageText == "Move 1 key into Secrets?" && confirm?.informativeText.contains(".cursor/mcp.json") == true
              && confirm?.informativeText.contains(SecretImportSheet.startsAfter) == true,
              "secrets: the confirm names the files and says how the servers start afterwards", confirm?.informativeText ?? "")
        confirm?.buttons.first?.performClick(nil)
        _ = await wait(15) { !sheet.summaryLabel.isHidden }
        let cursorAfter = read(cursor)
        let codexAfter = read(codex)
        check(sheet.summaryLabel.stringValue.hasPrefix("Moved 1 key from 2 files.") && store.index?.entry(named: "GITHUB_TOKEN")?.origin == .import,
              "secrets: the key is saved, and the summary says what moved", sheet.summaryLabel.stringValue)
        check(cursorAfter.contains("\"secret\",\"run\",\"GITHUB_TOKEN\",\"--\",\"npx\"") && !cursorAfter.contains(token)
              && cursorAfter.contains("// the self-test's servers") && codexAfter.contains("\"secret\", \"run\", \"GITHUB_TOKEN\", \"--\", \"npx\"")
              && codexAfter.contains("startup_timeout_sec = 30") && !codexAfter.contains(token),
              "secrets: both files now start the server through nxtrm secret run, with no key in them", cursorAfter)
        let backups = store.recentBackups()
        let records = backups.compactMap { $0.encoded() }.map { String(decoding: $0, as: UTF8.self) }
        check(backups.count == 2 && backups.allSatisfy { $0.original.contains("⟦nextterm:GITHUB_TOKEN⟧") } && records.allSatisfy { !$0.contains(token) },
              "secrets: each changed entry has a backup with a marker in place of the key, and no key")
        sheet.closeSheet()
        _ = await wait(5) { view.importSheet == nil }

        // Undo, after its confirm: the entries are as they were, and the backups go.
        view.reload()
        guard let undo = view.importRows.first?.undo else { return check(false, "secrets: Recent imports lists the import, with Undo") }
        undo.performClick(nil)
        _ = await wait(5) { view.alert != nil }
        check(view.alert?.messageText == "Put 1 key back into these files as plain text?" && view.undoDeleteBox?.state == .off,
              "secrets: Undo asks first, with deleting the keys off")
        view.alert?.buttons.first?.performClick(nil)
        _ = await wait(15) { read(cursor).contains(token) && read(codex).contains(token) }
        check(read(cursor) == cursorText && read(codex) == codexText,
              "secrets: Undo puts each entry back as it was", read(codex))
        _ = await wait(5) { store.recentBackups().isEmpty }
        check(store.recentBackups().isEmpty && store.index?.entry(named: "GITHUB_TOKEN") != nil,
              "secrets: the backups that went back are removed, and the key stays in Secrets")
        #if DEBUG
        await secretsImportReportChecks(view: view, home: home, token: token, cursorText: cursorText, codexText: codexText)
        #endif
        _ = try? await store.perform(.delete(name: "GITHUB_TOKEN"))
    }
}

extension SelfTest {
    // MARK: remote connections

    /// A remote connection, as the remote door will call: run_with_secrets still shows the panel, with only "Allow
    /// once", and asks Touch ID even when the connection's changes are pre-approved; the same call asks again;
    /// request_secret and store_secret are refused; list_secrets holds no value.
    static func secretsRemoteChecks(proj: URL) async {
        let requests = SecretRequests.shared
        let store = SecretsStore.shared
        requests.resetForSelfTest()
        let folder = proj.appendingPathComponent("secrets-remote", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = AppDelegate.shared!
        let before = Set(app.controllers.flatMap(\.tabs).map(\.id))
        defer {
            requests.resetForSelfTest()
            closeSecretsTabs(app.controllers.flatMap(\.tabs).filter { !before.contains($0.id) }, "remote")
            try? FileManager.default.removeItem(at: folder)
        }
        let value = secretsValue("remote")
        _ = try? await store.perform(.add(name: "REMOTE_KEY", purpose: "the remote checks", purposeBy: .user, origin: .settings,
                                          writeOnly: false, value: SecretBytes(utf8: value)))
        let requester = "the connection “test”"
        let grant = MCPApproval.preApprovedByGrant("grant-1")
        let arguments: [String: Any] = ["secrets": ["REMOTE_KEY=K"], "command": #"printf "%s" "$K" | wc -c"#, "directory": folder.path,
                                        "reason": "from the phone"]
        let presence = store.presence as? StandInPresence
        let asked = presence?.calls ?? 0

        // The panel names the connection and offers only "Allow once"; Allow asks for presence.
        let call = secretsStart("run_with_secrets", arguments, requester: requester, connection: "grant-1", approval: grant)
        let shown = await wait(15) { requests.showing?.panel != nil }
        let panel = requests.showing?.panel
        check(shown && panel?.window?.title == "The remote connection “test” asks to run printf with REMOTE_KEY"
              && panel?.durationChoice[.once] != nil && panel?.durationChoice[.fifteenMinutes] == nil && panel?.durationChoice[.untilLock] == nil,
              "secrets: a remote run_with_secrets shows the panel, naming the connection, with only Allow once, though its changes are pre-approved",
              panel?.window?.title ?? "no panel")
        panel?.allowButton.performClick(nil)
        let started = await call.value
        check(started["status"] as? String == "started" && started["approved"] as? String == "once" && started["tab_id"] != nil
              && (presence?.calls ?? 0) == asked + 1 && !secretsJSON(started).contains(value),
              "secrets: after Allow and one presence check, the remote gets started with the tab's id and no value", secretsJSON(started))

        // The same call asks again: no grant is made for a remote request.
        let again = secretsStart("run_with_secrets", arguments, requester: requester, connection: "grant-1", approval: grant)
        let askedAgain = await wait(15) { requests.showing?.panel != nil }
        check(askedAgain && requests.grants.isEmpty, "secrets: the same remote call shows the panel again, and no grant is kept")
        requests.showing?.panel?.declineButton.performClick(nil)
        _ = await again.value

        // Adding keys is for someone at the Mac.
        let phone = secretsValue("phone")
        let request = await secretsTool("request_secret", ["name": "PHONE_KEY", "reason": "x"], approval: grant, requester: requester,
                                        connection: "grant-1")
        let stored = await secretsTool("store_secret", ["name": "PHONE_KEY", "value": phone, "reason": "x"], approval: grant,
                                       requester: requester, connection: "grant-1")
        check(request["status"] as? String == "refused" && request["note"] as? String == "Only someone at the Mac can add keys."
              && stored["status"] as? String == "refused" && stored["note"] as? String == "Only someone at the Mac can add keys."
              && requests.showing == nil && store.index?.entry(named: "PHONE_KEY") == nil && !secretsJSON(stored).contains(phone),
              "secrets: remote request_secret and store_secret are refused, with no window or panel", secretsJSON(stored))

        // Listing works as on the Mac, with no value.
        let listed = await secretsTool("list_secrets", [:], approval: grant, requester: requester, connection: "grant-1")
        let names = (listed["secrets"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        check(listed["vault"] as? String == "ok" && names.contains("REMOTE_KEY") && !secretsJSON(listed).contains(value),
              "secrets: a remote list_secrets lists names and holds no value", secretsJSON(listed))
        _ = try? await store.perform(.delete(name: "REMOTE_KEY"))
    }
}
