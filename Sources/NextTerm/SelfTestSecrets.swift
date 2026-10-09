import AppKit
import CryptoKit
import NextTermCore
import UserNotifications

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
        let savedMask = SecretMask.current
        defer {
            SecretMask.current = savedMask
            SecretClipboard.shared.pasteboard.releaseGlobally()
        }
        await secretsStoreChecks(base)
        await secretsMaskingChecks(c, base: base)
        await secretsPanelChecks(base)
        await secretsWrapperChecks(base)
        await secretsToolChecks(c, base: base, proj: proj)
        await secretsSettingsChecks(base: base)
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
    // MARK: U3, masking

    /// A random value for a check, never typed: written to a file the tab reads with `K=$(cat …)`.
    static func secretsValue(_ prefix: String) -> String {
        prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + "Q7"
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
        made.vault.wipe()
        try? store.folder.ensure()
        try? store.folder.write(SecretFolder.maskKeyName, data: maskData)
        if let file { try? store.folder.write(SecretFolder.vaultName, data: file) }
        let agreements = keyring.agreementCount
        store.loadMarks()
        check(!SecretMask.current.isEmpty && presence.calls == 0 && keyring.agreementCount == agreements,
              "secrets: the marks load with no unlock and no presence check", "\(SecretMask.current.marks.count) marks, \(presence.calls) checks")

        let valueFile = base.appendingPathComponent("value.txt")
        try? value.write(to: valueFile, atomically: true, encoding: .utf8)
        let tab = c.addTab(directory: base.path, select: false)
        defer { c.requestClose(tab) }
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
    // MARK: U4, the panel and grants

    /// A request as the socket or the tools build one, with Next Term's facts filled in.
    static func secretsRequest(asker: String, command: [String], source: SecretBinding.Source = .wrapper, names: [String] = ["PANEL_KEY"],
                               remote: String? = nil, agent: String? = "Codex", checked: Bool = true, tab: String? = nil,
                               programTitle: String? = nil, words: String? = nil, folder: String = NSTemporaryDirectory()) -> SecretRequests.Request {
        let keys = names.map { SecretRequests.Key(name: $0, envName: $0) }
        let map = Dictionary(uniqueKeysWithValues: keys.map { ($0.name, $0.envName) })
        let binding = SecretBinding(source: source, asker: asker, program: command.first ?? "", command: command, keys: map, folder: folder)
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
        return SecretRequests.Request(binding: binding, keys: keys, command: shown, argv: argv, folder: folder, warnings: [],
                                      agentWords: words, askedBy: facts, program: ((command.first ?? "") as NSString).lastPathComponent,
                                      isRemote: remote != nil)
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
        requests.ask(afterLock) { answers.take($0) }
        check(requests.grants.isEmpty && afterLock.panel != nil, "secrets: locking the Mac ends the grant, and the same request asks again")

        // A pending card: its wrapper stopped waiting.
        requests.wrapperLeft(afterLock)
        check(afterLock.panel?.durationChoice[.fifteenMinutes]?.state == .on && afterLock.panel?.durationChoice[.once]?.isEnabled == false,
              "secrets: a pending card has Allow for 15 minutes chosen and Allow once off")
        let takeover = secretsRequest(asker: "wrapper:selftest-a", command: command, tab: "tab 3")
        requests.ask(takeover) { answers.take($0) }
        check(takeover.panel == nil && afterLock.panel != nil && requests.queue.count == 1 && afterLock.panel?.durationChoice[.once]?.isEnabled == true,
              "secrets: an identical request takes the card over, and does not queue")
        afterLock.panel?.declineButton.performClick(nil)

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

    init(_ arguments: [String], environment: [String: String] = [:], wait: Int = 20, directory: URL? = nil) {
        process.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        process.currentDirectoryURL = directory
        process.arguments = ["--cli", "--self-test-secret-wrapper", SelfTest.mcpSocketPath, String(wait), "secret", "run"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
    }

    func start() -> Bool { (try? process.run()) != nil }

    /// Waits for it to end, without blocking the main thread.
    @MainActor
    func finish(within seconds: Double = 40) async -> Int32? {
        guard await SelfTest.wait(seconds, { !self.process.isRunning }) else {
            process.terminate()
            return nil
        }
        stdout = output.fileHandleForReading.readDataToEndOfFile()
        stderr = errors.fileHandleForReading.readDataToEndOfFile()
        return process.terminationStatus
    }

    var errorText: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension SelfTest {
    // MARK: U5, nxtrm secret run

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

        // Allowed: the child gets the key (it writes only its length), not OTHER_KEY, only fds 0 to 2, SIGPIPE at its default.
        let script = "printf %s \"$K\" | wc -c | tr -d ' ' > len; if [ -z \"${OTHER_KEY+x}\" ]; then echo gone > other; fi; "
            + "for n in 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 255; do if [ -e /dev/fd/$n ]; then echo $n >> fds; fi; done; "
            + "ps -o ignored= -p $$ > ignored"
        let allowed = SecretsWrapperRun(["WRAP_KEY=K", "--", "/bin/sh", "-c", script], environment: ["OTHER_KEY": "exported-in-the-parent"],
                                        directory: out)
        let started = allowed.start()
        let shown = await wait(15) { requests.showing?.panel != nil }
        let panel = requests.showing?.panel
        let title = requests.showing.map(SecretApprovalPanel.title) ?? "no panel"
        check(started && shown && title.contains("asks to start sh with WRAP_KEY"), "secrets: nxtrm secret run shows the panel", title)
        panel?.allowButton.performClick(nil)
        let allowedExit = await allowed.finish()
        let ignored = UInt64(read("ignored"), radix: 16) ?? UInt64.max
        check(allowedExit == 0 && read("len") == String(value.utf8.count) && allowed.stdout.isEmpty,
              "secrets: after Allow the command runs with the key in its environment, and nothing goes to stdout",
              "exit \(String(describing: allowedExit)), len \(read("len")), \(allowed.errorText)")
        check(read("other") == "gone", "secrets: a stored key's name exported in the parent is gone in the command")
        check(read("fds").isEmpty && ignored & (1 << 12) == 0,
              "secrets: the command has only fds 0 to 2, and SIGPIPE at its default", "fds [\(read("fds"))], ignored \(read("ignored"))")
        check(!String(decoding: store.folder.readAudit(), as: UTF8.self).contains(value), "secrets: the audit log holds no value")

        // Declined: exit 1 and its line.
        let declined = SecretsWrapperRun(["WRAP_KEY", "--", "/usr/bin/true"])
        _ = declined.start()
        _ = await wait(15) { requests.showing?.panel != nil }
        requests.showing?.panel?.declineButton.performClick(nil)
        let declinedExit = await declined.finish()
        check(declinedExit == 1 && declined.errorText == "nxtrm: Next Term declined WRAP_KEY for true." && declined.stdout.isEmpty,
              "secrets: a declined wrapper exits 1 with its line", declined.errorText)

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
              && card?.panel?.durationChoice[.once]?.isEnabled == false,
              "secrets: with no answer in time the wrapper says so, and the panel becomes a pending card", away.errorText)
        let again = SecretsWrapperRun(["WRAP_KEY", "--", "/usr/bin/true", "away"], wait: 10)
        _ = again.start()
        _ = await wait(5) { card?.panel?.durationChoice[.once]?.isEnabled == true }
        check(requests.queue.count == 1 && requests.showing === card && card?.panel?.durationChoice[.once]?.isEnabled == true,
              "secrets: a second identical request takes the card over")
        card?.panel?.declineButton.performClick(nil)
        _ = await again.finish()

        // Refused, with no panel: a program that is not nxtrm, a lying argv, and argv over the caps.
        let nc = Process()
        nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        nc.arguments = ["-U", SelfTest.mcpSocketPath]
        let ncIn = Pipe(), ncOut = Pipe()
        nc.standardInput = ncIn
        nc.standardOutput = ncOut
        nc.standardError = FileHandle.nullDevice
        if (try? nc.run()) != nil {
            ncIn.fileHandleForWriting.write(Data(#"{"tool":"secret_run","arguments":{}}"#.utf8 + [0x0A]))
            try? ncIn.fileHandleForWriting.close()
            _ = await wait(10) { !nc.isRunning }
            if nc.isRunning { nc.terminate() }
            let said = String(decoding: ncOut.fileHandleForReading.availableData, as: UTF8.self)
            check(said.contains("\"refused\"") && requests.showing == nil, "secrets: a program that is not nxtrm gets refused at the socket, and no panel shows",
                  said)
            check(secretsAudit(store).last.map { $0.event == .refused } == true, "secrets: the refusal is in the audit log")
        }
        let claimed = (try? JSONEncoder().encode([Bundle.main.executablePath ?? "", "--cli", "secret", "run", "WRAP_KEY", "--", "/usr/bin/true"]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let liar = SecretsWrapperRun(["WRAP_KEY", "--", "/usr/bin/true"], environment: ["NEXTTERM_SELFTEST_ARGV_FULL": claimed])
        _ = liar.start()
        let liarExit = await liar.finish()
        check(liarExit == 1 && liar.errorText == "nxtrm: Next Term refused this request." && requests.showing == nil,
              "secrets: a wrapper whose argv is not the one it sent is refused, with no panel", liar.errorText)
        let many = SecretsWrapperRun(["WRAP_KEY", "--", "/usr/bin/true"] + Array(repeating: "a", count: 4097))
        _ = many.start()
        let manyExit = await many.finish()
        check(manyExit == 1 && many.errorText == "nxtrm: Next Term refused this request." && requests.showing == nil,
              "secrets: a wrapper with 4,097 arguments after -- is refused, with no panel", many.errorText)
    }
}

extension SelfTest {
    // MARK: U6, the MCP tools

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
        defer { c.requestClose(tab) }
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
            for tab in opened { MCPControl.controller(of: tab)?.requestClose(tab) }
            try? FileManager.default.removeItem(at: folder)
        }
        func newTabs(since before: Set<UUID>) -> [TerminalTab] {
            app.controllers.flatMap(\.tabs).filter { !before.contains($0.id) }
        }
        func tabIDs() -> Set<UUID> { Set(app.controllers.flatMap(\.tabs).map(\.id)) }
        let command = #"printf "%s" "$K" | wc -c | tr -d ' '; echo LEN"#
        let arguments: [String: Any] = ["secrets": ["TOOL_KEY=K"], "command": command, "directory": folder.path, "reason": "the length"]

        // A new tab, the ticket line in the self-test form, the panel, Allow, the run.
        let before = tabIDs()
        let call = secretsStart("run_with_secrets", arguments)
        _ = await wait(15) { requests.showing?.panel != nil }
        let tab = newTabs(since: before).first
        if let tab { opened.append(tab) }
        let typed = tab.map { $0.screenTail().joined(separator: "\n") } ?? ""
        check(tab != nil && typed.contains("--self-test-secret-wrapper") && typed.contains("secret run --ticket") && !typed.contains(command),
              "secrets: run_with_secrets opens a tab and types only the ticket line, in the self-test form", typed.suffix(300).description)
        check(tab.map { MCPControl.controller(of: $0)?.activeTab !== $0 } == true, "secrets: the new tab does not take the keyboard")
        let panel = requests.showing?.panel
        let title = panel?.window?.title ?? ""
        check(title == "A program outside Next Term's tabs asks to run printf with TOOL_KEY"
              && texts(panel?.window?.contentView).contains("Runs as a shell command") && panel?.durationChoice[.untilLock] == nil,
              "secrets: the panel shows the command as a shell command, with no until-the-Mac-locks choice", title)
        panel?.allowButton.performClick(nil)
        let started = await call.value
        let length = String(value.utf8.count)
        func screen(_ tab: TerminalTab?) -> String { tab.map { $0.screenTail().joined(separator: "\n") } ?? "" }
        let ran = await wait(15) { screen(tab).contains("\(length)LEN") || screen(tab).contains("\(length)\nLEN") }
        check(started["status"] as? String == "started" && started["approved"] as? String == "once"
              && started["tab_id"] as? String == tab?.id.uuidString.lowercased() && ran && !secretsJSON(started).contains(value),
              "secrets: after Allow the command runs in its tab with the key, and the agent gets started with the tab's id",
              secretsJSON(started))
        if let tab {
            _ = await wait(10) { !tab.status.running }
            tab.view.send(txt: "if [ -z \"${K+x}\" ]; then echo NO\"\"K; fi; echo HIST$(fc -ln -9 | grep -c 'w[c] -c')\r")
            let clean = await wait(10) { screen(tab).contains("NOK") && screen(tab).contains("HIST0") }
            check(clean, "secrets: the tab's shell has no K after the run, and its history holds only the ticket line", String(screen(tab).suffix(200)))
        }
        // A used ticket can't be used again.
        let ticketID = screen(tab).components(separatedBy: "--ticket ").last.map { String($0.prefix(26)) } ?? ""
        let reuse = SecretsWrapperRun(["--ticket", ticketID])
        _ = reuse.start()
        let reuseExit = await reuse.finish()
        check(SecretRun.isTicket(ticketID) && reuseExit == 1 && reuse.errorText.contains("expired or was used already") && requests.showing == nil,
              "secrets: a used ticket gets expired", reuse.errorText)

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
        check(declined["status"] as? String == "declined" && declined["tab_id"] != nil,
              "secrets: a declined run answers declined and names the tab, which stays open", secretsJSON(declined))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(".env"))
        requests.revokeAll()

        await secretsRunTabChecks(c, folder: folder, base: base, opened: &opened)
        await secretsRunRefusalChecks(folder: folder, value: value, arguments: arguments, before: tabIDs())
        await secretsTicketChecks(folder: folder, arguments: arguments, opened: &opened)
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
    static func secretsTicketChecks(folder: URL, arguments: [String: Any], opened: inout [TerminalTab]) async {
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
        _ = await wait(15) { requests.showing?.panel != nil }
        requests.showing?.panel?.declineButton.performClick(nil)
        _ = await call.value
        requests.resetForSelfTest()

        SecretRequests.ticketWindow = .milliseconds(150)
        let late = await secretsTool("run_with_secrets", ["secrets": ["TOOL_KEY"], "command": "true", "directory": folder.path])
        check(late["status"] as? String == "refused" && late["note"] as? String == "The tab's shell did not start nxtrm within 30 seconds.",
              "secrets: a ticket not redeemed in time ends refused", secretsJSON(late))
        SecretRequests.ticketWindow = .seconds(30)
        for tab in AppDelegate.shared.controllers.flatMap(\.tabs) where !before.contains(tab.id) { opened.append(tab) }
        let lateTab = opened.last
        _ = await wait(10) { lateTab?.screenTail().joined().contains("expired or was used already") == true }
        check(lateTab?.screenTail().joined().contains("expired or was used already") == true,
              "secrets: its wrapper, starting late, gets expired")
    }
}

extension SelfTest {
    // MARK: U7, Settings › Secrets and Window › Secrets

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
        let cleared = await wait(5) { clipboard.pasteboard.string(forType: .string) == nil }
        check(cleared, "secrets: Copy's pasteboard is cleared after the delay when nothing was copied since")
        view.copyButton.performClick(nil)
        _ = await wait(10) { clipboard.pasteboard.string(forType: .string) == shownValue }
        clipboard.pasteboard.clearContents()
        clipboard.pasteboard.setString("something else", forType: .string)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        check(clipboard.pasteboard.string(forType: .string) == "something else" && NSPasteboard.general.changeCount == general,
              "secrets: what was copied since is kept, and the general pasteboard was never touched")

        // Allowed now lists a grant, and Revoke ends it.
        let request = secretsRequest(asker: "wrapper:selftest-settings", command: ["true"], names: ["SHOWN_KEY"])
        let answers = SecretsAnswers()
        requests.ask(request) { answers.take($0) }
        request.panel?.durationChoice[.fifteenMinutes]?.performClick(nil)
        request.panel?.allowButton.performClick(nil)
        _ = await wait(10) { !requests.grants.isEmpty }
        view.reload()
        let listed = view.allowedRows.count == 1 && SecretsView.grantText(requests.grants[0]).contains("SHOWN_KEY")
        view.allowedRows.first?.revoke.performClick(nil)
        check(listed && requests.grants.isEmpty && view.allowedRows.isEmpty, "secrets: Allowed now lists a grant, and Revoke ends it")

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
