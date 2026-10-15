import AppKit
import CryptoKit
import NextTermCore
import Security

/// Secrets' vault in the app: the marks at launch, the load check, and every use and change, each after one presence
/// check. The format and crypto are Core's `SecretVault`; the folder is `SecretFolder`.
///
/// - `loadMarks()` reads `vault.json` and `mask.key` synchronously, with no crypto and no keychain read, before the
///   MCP socket starts, so the first MCP answer is already masked.
/// - `load()` runs the keyring's load check off the main thread, which needs no Touch ID, and sets `protection`.
/// - `perform(_:reason:facts:)` asks for presence, then on its own queue takes the vault's lock, unlocks, makes the
///   change, writes, drops the vault key and writes the audit line. Cancel or failure changes no key. A vault that
///   this Mac's record of the vaults Next Term made (`record`, a login-keychain item) doesn't list is tampered, however
///   well its file checks out, so no value is sealed into it or released from it. With no record at all it is refused
///   the same, as unlisted, with its own text. A program that can add login-keychain items can forge the record.
/// - In the self-test it works on a temporary folder with a software keyring, a record in memory and a stand-in
///   presence check that passes at once and counts its calls. The real vault, `mask.key` and the login keychain are
///   never touched.
@MainActor
final class SecretsStore {
    /// Posted after the index, the protection or the last uses changed.
    static let changed = Notification.Name("NextTermSecretsChanged")
    /// Posted when the Mac locks, sleeps or the session resigns: grants and pending cards end.
    static let locked = Notification.Name("NextTermSecretsLocked")
    /// Posted with `names` when keys were replaced, renamed or deleted: the grants holding them end.
    static let keysChanged = Notification.Name("NextTermSecretsKeysChanged")
    /// Posted when the vault is gone, by Start Over here or in another copy of Next Term: every grant ends.
    static let startedOver = Notification.Name("NextTermSecretsStartedOver")

    /// `loadMarks()` ran.
    nonisolated(unsafe) static var marksLoaded = false
    /// Whether the marks were loaded when the MCP socket started: `startAgentControl()` records it, for the self-test.
    nonisolated(unsafe) static var marksLoadedBeforeSocket = false

    static let shared: SecretsStore = SelfTest.isRequested ? selfTestStore() : appStore()

    /// What guards the vault, as Settings says it.
    enum Protection: Equatable {
        /// No vault yet.
        case none
        case secureEnclave
        /// With a copy of the vault key in the login keychain, so updates keep working.
        case secureEnclaveWithRecovery
        /// The keychain keyring.
        case lessProtected
        case tampered
        case cantOpen
    }

    enum LockEvent: Equatable {
        case screenLocked, systemSleep, sessionResigned
        /// The display sleeping alone ends nothing.
        case displaySleep
    }

    /// A key Add… saves, with its facts. A new fact is a member here, with a default, so no match on `Action` changes.
    struct NewKey {
        var name: String
        var purpose: String
        var purposeBy: SecretVault.PurposeBy
        var origin: SecretVault.Origin
        var writeOnly: Bool
        var value: SecretBytes
        /// "Where it came from", checked against the stored keys and the value before Touch ID is asked.
        var link: String?
        var linkFrom: SecretVault.LinkFrom?
        var remindDays: Int?
    }

    /// What Edit… changes. Nil leaves a fact as it is; for `link` and `remindDays`, `.some(nil)` clears it.
    struct KeyEdit {
        var name: String
        var newName: String?
        var purpose: String?
        var purposeBy: SecretVault.PurposeBy
        var link: String??
        var linkFrom: SecretVault.LinkFrom?
        var remindDays: Int??

        /// How many of what it's for, its page and its reminder this changes.
        var factsChanged: Int {
            let changes: [Bool] = [purpose != nil, link != nil, remindDays != nil]
            return changes.filter { (changed: Bool) -> Bool in changed }.count
        }
    }

    /// What Rotate… saves: the new value, made at the provider, and the page and reminder set in its sheet. For `link`
    /// and `remindDays`, nil leaves them as they are and `.some(nil)` clears them.
    struct KeyRotation {
        var name: String
        var value: SecretBytes
        var link: String?? = nil
        var linkFrom: SecretVault.LinkFrom? = nil
        var remindDays: Int?? = nil
    }

    enum Action {
        case add(NewKey)
        case edit(KeyEdit)
        case replace(name: String, value: SecretBytes, writeOnly: Bool, origin: SecretVault.Origin?)
        /// A key rotation: the old value stays masked for 30 days.
        case rotate(KeyRotation)
        case makeWriteOnly(name: String)
        case delete(name: String)
        case reveal(name: String)
        case copy(name: String)
        case use(names: [String])

        static func add(name: String, purpose: String, purposeBy: SecretVault.PurposeBy, origin: SecretVault.Origin,
                        writeOnly: Bool, value: SecretBytes, link: String? = nil, linkFrom: SecretVault.LinkFrom? = nil,
                        remindDays: Int? = nil) -> Action {
            .add(NewKey(name: name, purpose: purpose, purposeBy: purposeBy, origin: origin, writeOnly: writeOnly, value: value,
                        link: link, linkFrom: linkFrom, remindDays: remindDays))
        }

        static func edit(name: String, newName: String?, purpose: String?, purposeBy: SecretVault.PurposeBy,
                         link: String?? = nil, linkFrom: SecretVault.LinkFrom? = nil, remindDays: Int?? = nil) -> Action {
            .edit(KeyEdit(name: name, newName: newName, purpose: purpose, purposeBy: purposeBy, link: link, linkFrom: linkFrom,
                          remindDays: remindDays))
        }

        var names: [String] {
            switch self {
            case .add(let key): return [key.name]
            case .edit(let change): return [change.name]
            case .rotate(let change): return [change.name]
            case .replace(let name, _, _, _), .makeWriteOnly(let name), .delete(let name), .reveal(let name), .copy(let name):
                return [name]
            case .use(let names):
                return names
            }
        }

        var event: SecretAudit.Event {
            switch self {
            case .add: return .add
            case .edit: return .edit
            case .replace: return .replace
            case .rotate: return .rotate
            case .makeWriteOnly: return .writeOnly
            case .delete: return .delete
            case .reveal: return .reveal
            case .copy: return .copy
            case .use: return .use
            }
        }

        /// The sheet's reason when the caller gives none.
        var reason: String {
            switch self {
            case .add(let key): return SecretReason.save(key.name)
            case .edit(let change):
                let name = change.name
                if let newName = change.newName, newName != name { return SecretReason.rename(name, to: newName) }
                if change.factsChanged > 1 { return SecretReason.changeDetails(name) }
                if change.link != nil { return SecretReason.changeLink(name) }
                if change.remindDays != nil { return SecretReason.changeReminder(name) }
                return SecretReason.changePurpose(name)
            case .replace(let name, _, _, _): return SecretReason.replace(name)
            case .rotate(let change): return SecretReason.rotate(change.name)
            case .makeWriteOnly(let name): return SecretReason.makeWriteOnly(name)
            case .delete(let name): return SecretReason.delete(name)
            case .reveal(let name): return SecretReason.show(name)
            case .copy(let name): return SecretReason.copy(name)
            case .use(let names): return "use \(SecretReason.keys(names))"
            }
        }

        var isAdd: Bool {
            if case .add = self { return true }
            return false
        }

        /// Why a link this sets can't be kept, checked on the Mac before Touch ID is asked: the vault checks it again
        /// with no stored keys at hand, so the stored keys (`holdsStoredKey`) and the value being added are looked for
        /// here.
        var linkRefusal: SecretLink.Refusal? {
            let text: String?
            var value: SecretBytes?
            switch self {
            case .add(let key):
                text = key.link
                value = key.value
            case .edit(let change):
                text = change.link ?? nil
            case .rotate(let change):
                text = change.link ?? nil
                value = change.value
            default:
                return nil
            }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let mask: (String) -> Bool = { (candidate: String) -> Bool in SecretsStore.holdsStoredKey(candidate) }
            guard case .failure(let refusal) = SecretLink.check(text, mask: mask, value: value) else { return nil }
            return refusal
        }

        /// The keys whose value or name this changes, so the grants holding them end.
        var changedNames: [String]? {
            switch self {
            case .replace(let name, _, _, _), .delete(let name): return [name]
            case .rotate(let change): return [change.name]
            case .edit(let change):
                guard let newName = change.newName, newName != change.name else { return nil }
                return [change.name]
            default: return nil
            }
        }
    }

    /// Who asked and for what, for the audit line: the panel's Asked by facts, the command, the folder, the approval.
    struct Facts {
        var who: String?
        var command: String?
        var folder: String?
        var approval: SecretAudit.Approval?

        init(who: String? = nil, command: String? = nil, folder: String? = nil, approval: SecretAudit.Approval? = nil) {
            self.who = who
            self.command = command
            self.folder = folder
            self.approval = approval
        }
    }

    enum Failure: Error, Equatable, LocalizedError {
        case cancelled
        case unavailable
        case vault(SecretVault.Failure)
        case folder(SecretFolder.Failure)
        case keyring
        /// The key has no "Where it came from" link (any more).
        case noPage(String)

        var errorDescription: String? {
            switch self {
            case .noPage(let name): return "\(name) has no page."
            case .cancelled: return "Not approved."
            case .unavailable: return UserPresence.Failure.unavailable.errorDescription
            case .vault(let failure): return failure.errorDescription
            case .folder(let failure): return failure.errorDescription
            case .keyring: return "Next Term couldn’t make the key that guards Secrets on this Mac."
            }
        }
    }

    let folder: SecretFolder
    let presence: PresenceCheck
    private let newKeyring: () throws -> VaultKeyring
    private let keyring: (SecretVault.Index) -> VaultKeyring
    /// This Mac's record of the vaults Next Term made: a vault it doesn't list is tampered, so nothing is sealed into it.
    let record: VaultRecord
    private let queue = DispatchQueue(label: "NextTerm.secrets")

    /// The names, what each is for, flags and dates, read with no key.
    private(set) var index: SecretVault.Index?
    private(set) var protection: Protection = .none
    /// Whether `load()` has run: until then `protection` hasn't said whether the keys open on this Mac.
    private(set) var hasLoaded = false
    /// For each name, its newest `use` line.
    private(set) var lastUse: [String: SecretAudit.Line] = [:]
    /// True while an action uses the login keychain, which every one does: an unlock reads the record, a first add
    /// writes it, and a keychain vault's key is read. macOS may ask for the login password ("Waiting for the keychain…").
    private(set) var isWaitingForKeychain = false
    /// With `protection` `.tampered`: the vault was refused because this Mac has no record of the vaults Next Term made,
    /// not because its file changed, so Settings says that instead of the tamper text.
    private(set) var isUnlisted = false
    /// With `protection` `.tampered`: vault.json is larger than Next Term reads (a copy before the write cap wrote it),
    /// not changed, so Settings says that instead of the tamper text.
    private(set) var isTooLarge = false
    private var indexDate: Date?
    /// The bytes of vault.json Next Term last wrote, or last read and MAC-checked in an unlock. A link opens with no
    /// unlock only from those bytes: lists read the index with no MAC check, and any process of the user's can write
    /// the file and set its date.
    private var vouch: SecretLink.Vouch?
    private var observers: [NSObjectProtocol] = []

    init(folder: SecretFolder, presence: PresenceCheck, newKeyring: @escaping () throws -> VaultKeyring,
         keyring: @escaping (SecretVault.Index) -> VaultKeyring, record: VaultRecord) {
        self.folder = folder
        self.presence = presence
        self.newKeyring = newKeyring
        self.keyring = keyring
        self.record = record
    }

    // MARK: the stores

    private static func appStore() -> SecretsStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SecretsStore(folder: SecretFolder(applicationSupport: support), presence: UserPresence.shared,
                            newKeyring: makeKeyring, keyring: appKeyring, record: appRecord())
    }

    /// The self-test's: a temporary folder, one software keyring, a record in memory, and a presence check that passes
    /// and counts.
    private static func selfTestStore() -> SecretsStore {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-secrets-\(getpid())", isDirectory: true)
        let keyring = SoftwareKeyring(kind: .secureEnclave)
        return SecretsStore(folder: SecretFolder(applicationSupport: base), presence: StandInPresence(),
                            newKeyring: { keyring }, keyring: { _ in keyring }, record: MemoryVaultRecord())
    }

    /// The app's record of the vaults it made: its login-keychain item.
    nonisolated static func appRecord() -> VaultRecord {
        LoginKeychainRecord()
    }

    /// The keyring a new vault gets: the Secure Enclave where there is one, else the login keychain. A debug build
    /// alone reads `NEXTTERM_SECRETS_KEYRING=keychain`, to make a "less protected" vault where a Secure Enclave is, for
    /// a hand check.
    nonisolated static func makeKeyring() throws -> VaultKeyring {
        let keychain = { try KeychainKeyring.make(items: loginItem) }
        #if DEBUG
        if ProcessInfo.processInfo.environment["NEXTTERM_SECRETS_KEYRING"] == "keychain" { return try keychain() }
        #endif
        return SecureEnclaveKeyring.isAvailable ? try SecureEnclaveKeyring.make() : try keychain()
    }

    /// An existing vault's keyring: the kind it records.
    nonisolated static func appKeyring(for index: SecretVault.Index) -> VaultKeyring {
        switch index.keyring {
        case .secureEnclave: return SecureEnclaveKeyring(blob: index.keyBlob ?? Data())
        case .keychain: return KeychainKeyring(publicKey: index.publicKey, items: loginItem)
        }
    }

    /// The login keychain's item of Next Term's service by account: what the app's keychain keyrings use.
    nonisolated static func loginItem(_ account: String) -> PasswordStore {
        LoginKeychain(account: account)
    }

    // MARK: launch

    /// The marks, read synchronously at launch with no crypto and no keychain read: `vault.json`'s index and
    /// `mask.key`, published as `SecretMask.current`. Sets `marksLoaded`.
    func loadMarks() {
        defer { Self.marksLoaded = true }
        // The code hash a wrapper must have is read now, at launch, from the program that is running, not at the first
        // request, when the file at its path may have been replaced.
        _ = PeerCode.current
        // The date before the read: a file another copy writes in between is read again at the next check, never
        // taken as seen.
        let date = folder.modificationDate(of: SecretFolder.vaultName)
        guard folder.exists, let data = try? folder.read(SecretFolder.vaultName, cap: SecretVault.maxFileSize),
              let index = try? SecretVault.index(from: data) else { return }
        self.index = index
        indexDate = date
        publishMarks()
    }

    /// `SecretMask.current` from the index and `mask.key`. A missing `mask.key` turns masking off until the next
    /// unlock, which makes a new one and new marks for every entry.
    func publishMarks() {
        guard let index, let data = try? folder.read(SecretFolder.maskKeyName, cap: 64), data.count == SecretVault.maskKeyLength else {
            SecretMask.current = .empty
            return
        }
        SecretMask.current = SecretMask(key: SymmetricKey(data: data), index: index)
    }

    /// The index and the load check, off the main thread: the keyring's `check()` needs no Touch ID. A key that is not
    /// this Mac's sets `protection` to `.cantOpen` at once.
    func load() async {
        let folder = folder
        let keyring = keyring
        let found = await onQueue { () -> (SecretVault.Index?, Protection, Data, Bool, Date?) in
            let audit = folder.exists ? folder.readAudit() : Data()
            guard folder.exists else { return (nil, .none, audit, false, nil) }
            // The date before the read: a file another copy writes in between is read again at the next check.
            let date = folder.modificationDate(of: SecretFolder.vaultName)
            let data: Data?
            do {
                data = try folder.read(SecretFolder.vaultName, cap: SecretVault.maxFileSize)
            } catch {
                return (nil, .tampered, audit, SecretVault.isTooLarge(error), date)
            }
            guard let data else { return (nil, .none, audit, false, date) }
            guard let index = try? SecretVault.index(from: data) else { return (nil, .tampered, audit, false, date) }
            let opens = keyring(index).check(publicKey: index.publicKey)
            return (index, opens ? Self.protection(of: index) : .cantOpen, audit, false, date)
        }
        index = found.0
        protection = found.1
        isUnlisted = false
        isTooLarge = found.3
        lastUse = SecretAudit.lastUse(in: found.2)
        indexDate = found.4
        hasLoaded = true
        publishMarks()
        if !SelfTest.isRequested { startObserving() }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// What an action on a vault refused at load or since throws.
    private var refusal: Failure {
        if isTooLarge { return .vault(.tooLarge) }
        return .vault(isUnlisted ? .unlisted : .tampered)
    }

    nonisolated static func protection(of index: SecretVault.Index) -> Protection {
        switch index.keyring {
        case .secureEnclave: return index.hasRecovery ? .secureEnclaveWithRecovery : .secureEnclave
        case .keychain: return .lessProtected
        }
    }

    /// `vault.json` read again when its modification date changed (another copy of Next Term saved it): before each
    /// operation, before a grant answers, and when Next Term becomes active. Keys the other copy replaced, renamed or
    /// deleted are posted in `keysChanged`, as a change here posts them, so the grants holding them end; all of them when
    /// the file can no longer be read. The check is one `lstat` while the date is the same.
    func reloadIfChanged() {
        let date = folder.modificationDate(of: SecretFolder.vaultName)
        guard date != indexDate else { return }
        indexDate = date
        guard date != nil else {
            // Gone: another copy started over.
            index = nil
            protection = .none
            isUnlisted = false
            isTooLarge = false
            NotificationCenter.default.post(name: Self.changed, object: self)
            NotificationCenter.default.post(name: Self.startedOver, object: self)
            return
        }
        var data: Data?
        var tooLarge = false
        do {
            data = try folder.read(SecretFolder.vaultName, cap: SecretVault.maxFileSize)
        } catch {
            tooLarge = SecretVault.isTooLarge(error)
        }
        let earlier = index
        let read: SecretVault.Index? = data.flatMap { try? SecretVault.index(from: $0) }
        if let read {
            index = read
            if protection == .none { protection = Self.protection(of: read) }
        } else {
            protection = .tampered
            isUnlisted = false
            isTooLarge = tooLarge
        }
        publishMarks()
        NotificationCenter.default.post(name: Self.changed, object: self)
        let changedNames = SecretVault.Index.changedNames(from: earlier, to: read)
        if !changedNames.isEmpty {
            NotificationCenter.default.post(name: Self.keysChanged, object: self, userInfo: ["names": changedNames])
        }
    }

    /// The observers of the Mac locking, sleeping and the session resigning, and of Next Term becoming active. Not in
    /// the self-test, which calls `handleLockEvent(_:)` itself.
    func startObserving() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SecretsStore.shared.handleLockEvent(.screenLocked) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SecretsStore.shared.handleLockEvent(.systemSleep) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SecretsStore.shared.handleLockEvent(.sessionResigned) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SecretsStore.shared.handleLockEvent(.displaySleep) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                                queue: .main) { _ in
            MainActor.assumeIsolated { SecretsStore.shared.reloadIfChanged() }
        })
    }

    /// A lock, a sleep or the session resigning ends what waits on the Mac being in use: it posts `locked`. The
    /// display sleeping alone posts nothing.
    func handleLockEvent(_ event: LockEvent) {
        guard event != .displaySleep else { return }
        NotificationCenter.default.post(name: Self.locked, object: self, userInfo: ["event": event])
    }

    // MARK: use and change

    /// One presence check, then the action on the vault: the values it releases (reveal, copy, use), or none. The first
    /// add makes the vault. Throws `Failure`; nothing changes on a failure.
    @discardableResult
    func perform(_ action: Action, reason: String? = nil, facts: Facts = Facts()) async throws -> [String: SecretBytes] {
        reloadIfChanged()
        if protection == .tampered { throw refusal }
        if protection == .cantOpen { throw Failure.vault(.cantOpen) }
        if index == nil, !action.isAdd { throw Failure.vault(.noSuchKey(action.names.first ?? "")) }
        if let refusal = action.linkRefusal { throw Failure.vault(.badLink(refusal)) }
        let control = index?.keyring == .secureEnclave ? UserPresence.secureEnclaveAccessControl() : nil
        let token: AnyObject
        do {
            token = try await presence.confirm(reason: reason ?? action.reason, accessControl: control)
        } catch let failure as UserPresence.Failure {
            throw failure == .cancelled ? Failure.cancelled : Failure.unavailable
        }
        defer { presence.finish(token) }
        setWaitingForKeychain(true) // the record, at least, is in the login keychain
        let folder = folder
        let keyring = keyring
        let newKeyring = newKeyring
        let record = record
        #if DEBUG
        let afterLock = afterLockForSelfTest
        #endif
        let result = await onQueue { () -> Result<Work, Error> in
            let result = Result {
                try Self.work(action, facts: facts, folder: folder, keyring: keyring, newKeyring: newKeyring, record: record,
                              token: token)
            }
            #if DEBUG
            afterLock?()
            #endif
            return result
        }
        setWaitingForKeychain(false)
        switch result {
        case .success(let work):
            let earlier = index
            took(work)
            if action.event == .use, let line = work.line { for name in action.names { lastUse[name] = line } }
            publishMarks()
            NotificationCenter.default.post(name: Self.changed, object: self)
            postKeysChanged(action.changedNames ?? [], since: earlier)
            return work.values
        case .failure(let error):
            reloadIfChanged() // new marks for a mask.key made again stay, even when the action failed
            throw handle(error, action: action, facts: facts)
        }
    }

    #if DEBUG
    /// The self-test's: runs on the store's queue once a perform has let the vault's lock go, before the main actor
    /// takes its result, where another copy's write may land.
    var afterLockForSelfTest: (() -> Void)?
    #endif

    /// The index a change left under the vault's lock, with vault.json's date taken there too: a write by another copy
    /// after the lock was let go has another date, so the next check reads it.
    private func took(_ work: Work) {
        if let changed = work.index {
            index = changed
            indexDate = work.date
        }
        if let vouched = work.vouch { vouch = vouched }
        if protection == .none, let index { protection = Self.protection(of: index) }
    }

    /// `keysChanged` for `names` (what this change replaced, renamed or deleted) and for the keys another copy changed
    /// since this copy had `earlier` (while Touch ID was asked, before this change took the lock), so the grants
    /// holding any of them end.
    private func postKeysChanged(_ names: [String], since earlier: SecretVault.Index?) {
        var all = names
        for name in SecretVault.Index.changedNames(from: earlier, to: index) where !all.contains(name) { all.append(name) }
        guard !all.isEmpty else { return }
        NotificationCenter.default.post(name: Self.keysChanged, object: self, userInfo: ["names": all])
    }

    /// What a failed perform says, and what it leaves: a tampered or unlisted vault is noted, with a `tamper` line, and a
    /// vault its keyring can't open on this Mac (its item gone or holding another key, a blob or key agreement that fails)
    /// is noted as one at once, as the load check would, so Settings shows Start Over. A keyring's cancel (such as Cancel
    /// at macOS's keychain prompt) is the user's, as at the presence check; it and a key the keyring couldn't reach
    /// just then (`keyUnavailable`) leave Secrets as it was, for the next try.
    private func handle(_ error: Error, action: Action, facts: Facts) -> Failure {
        let failure: Failure
        switch error {
        case let vault as SecretVault.Failure: failure = vault == .cancelled ? .cancelled : .vault(vault)
        case let folder as SecretFolder.Failure: failure = folder == .notPrivate ? .vault(.tampered) : .folder(folder)
        case is Failure: failure = error as? Failure ?? .keyring
        default: failure = .keyring
        }
        if failure == .vault(.tampered) || failure == .vault(.unlisted) {
            protection = .tampered
            isUnlisted = failure == .vault(.unlisted)
            isTooLarge = false
            let outcome = isUnlisted ? "refused: no record of this Mac's vaults" : "refused"
            let line = SecretAudit.Line(event: .tamper, names: action.names, who: facts.who, command: facts.command,
                                        folder: facts.folder, outcome: outcome)
            try? folder.appendAudit(SecretAudit.encode(line, masking: { SecretMask.current.mask($0) }))
            NotificationCenter.default.post(name: Self.changed, object: self)
        } else if failure == .vault(.cantOpen), index != nil, protection != .cantOpen {
            protection = .cantOpen
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
        return failure
    }

    private func setWaitingForKeychain(_ waiting: Bool) {
        isWaitingForKeychain = waiting
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// What a perform did, off the main thread.
    struct Work {
        var index: SecretVault.Index?
        /// vault.json's modification date, taken under the lock after the change.
        var date: Date?
        var values: [String: SecretBytes] = [:]
        var line: SecretAudit.Line?
        /// The bytes the unlock MAC-checked, or the change wrote.
        var vouch: SecretLink.Vouch?
    }

    /// Under the vault's lock: unlock (or make the vault, for the first add), the change, the write; then the audit line.
    nonisolated private static func work(_ action: Action, facts: Facts, folder: SecretFolder,
                                         keyring: (SecretVault.Index) -> VaultKeyring, newKeyring: () throws -> VaultKeyring,
                                         record: VaultRecord, token: AnyObject) throws -> Work {
        var values: [String: SecretBytes] = [:]
        var earlier: SecretVault.Origin?
        var work = try unlocked(makes: action.isAdd, firstName: action.names.first, folder: folder, keyring: keyring,
                                newKeyring: newKeyring, record: record, token: token) { vault, maskKey in
            try apply(action, to: vault, maskKey: maskKey, values: &values, earlier: &earlier)
        }
        work.values = values
        let line = SecretAudit.Line(event: action.event, names: action.names, who: facts.who, command: facts.command,
                                    folder: facts.folder, approval: facts.approval, outcome: "done",
                                    earlierOrigin: earlier?.rawValue)
        try? folder.appendAudit(SecretAudit.encode(line, masking: { SecretMask.current.mask($0) }))
        work.line = line
        return work
    }

    /// The vault unlocked under its lock (or made, when `makes` and there is none), `change` run on it, and what it
    /// returns written; the vault key dropped after. A missing `mask.key` is made again, with new marks. A vault the
    /// record doesn't list is tampered: whatever its file says, it was not made here, so nothing is sealed into it or
    /// released from it. A vault made here is listed once its first action checked out, before its vault.json is
    /// written, so a first add that fails (a bad value) lists nothing.
    nonisolated private static func unlocked(makes: Bool, firstName: String?, folder: SecretFolder,
                                             keyring: (SecretVault.Index) -> VaultKeyring, newKeyring: () throws -> VaultKeyring,
                                             record: VaultRecord, token: AnyObject,
                                             change: (SecretVault, SymmetricKey?) throws -> Data?) throws -> Work {
        try folder.ensure()
        var vault: SecretVault?
        defer { vault?.wipe() }
        var work = Work()
        try folder.withLock {
            var maskKey: SymmetricKey?
            // The keyring a first add made: the keychain item it added is deleted when its vault wasn't written.
            var madeKeyring: VaultKeyring?
            defer { discardUnwritten(madeKeyring, folder: folder) }
            // The vault a first add made, until it is listed in the record.
            var unlisted: SecretVault?
            if let data = try folder.read(SecretFolder.maskKeyName, cap: 64), data.count == SecretVault.maskKeyLength {
                maskKey = SymmetricKey(data: data)
            }
            /// The vault `current` holds: unlocked once, then read again on a retry; or made, for the first add, with a
            /// new `mask.key`.
            func opened(_ current: Data?) throws -> SecretVault {
                if let vault, let current {
                    try vault.reload(current)
                    return vault
                }
                if let current {
                    let index = try SecretVault.index(from: current)
                    let unlocked = try SecretVault.unlock(current, keyring: keyring(index), context: token)
                    do {
                        try unlocked.bind(to: record)
                    } catch {
                        unlocked.wipe()
                        throw error
                    }
                    vault = unlocked
                    return unlocked
                }
                guard makes else { throw SecretVault.Failure.noSuchKey(firstName ?? "") }
                let made: (vault: SecretVault, maskKey: SecretBytes)
                do {
                    let fresh = try newKeyring()
                    madeKeyring = fresh
                    made = try SecretVault.create(keyring: fresh)
                } catch let failure as SecretVault.Failure {
                    throw failure
                } catch {
                    throw Failure.keyring
                }
                vault = made.vault // wiped after, whatever fails next
                unlisted = made.vault
                let maskData = made.maskKey.withUnsafeBytes { Data($0) }
                try folder.write(SecretFolder.maskKeyName, data: maskData)
                maskKey = SymmetricKey(data: maskData)
                return made.vault
            }
            // A missing mask.key is made again, with new marks for every entry, in a write of its own before the action.
            // The marks are written first, then the key: a failure between them leaves the key missing, so the next
            // unlock marks them again, and never leaves marks under a key that was lost. An action that fails keeps them.
            if maskKey == nil {
                let fresh = SymmetricKey(size: .bits256)
                let remarked = try folder.update { current in
                    guard let current else { return nil } // no vault yet: the first add makes the key with it
                    return try opened(current).remark(maskKey: fresh)
                }
                if remarked != nil {
                    try folder.write(SecretFolder.maskKeyName, data: fresh.withUnsafeBytes { Data($0) })
                    maskKey = fresh
                }
            }
            _ = try folder.update { current in
                let open = try opened(current) // the first add sets maskKey here
                let data = try change(open, maskKey)
                // Listed before its vault.json is written: a vault.json this Mac's record doesn't list is never made.
                if let made = unlisted, data != nil {
                    try made.record(in: record)
                    unlisted = nil
                }
                return data
            }
            work.date = folder.modificationDate(of: SecretFolder.vaultName)
        }
        work.index = vault?.index
        // Unlocked, its MAC checked, and written when the change made a new file: those are the bytes on disk now.
        work.vouch = vault.map { (opened: SecretVault) -> SecretLink.Vouch in SecretLink.Vouch(file: opened.file) }
        return work
    }

    /// After a first add, under the vault's lock: the keychain item its new keyring added is deleted unless
    /// `vault.json` names that key (the vault was written, even by a write that then failed) or can't be read to tell.
    /// A first add that failed leaves no item that opens nothing.
    nonisolated private static func discardUnwritten(_ keyring: VaultKeyring?, folder: SecretFolder) {
        guard let made = keyring as? KeychainKeyring, let publicKey = try? made.publicKey() else { return }
        let current: Data?
        do {
            current = try folder.read(SecretFolder.vaultName, cap: SecretVault.maxFileSize)
        } catch {
            return
        }
        if let current, (try? SecretVault.index(from: current))?.publicKey == publicKey { return }
        made.discard()
    }

    // MARK: a key's page

    /// Whether a text holds a stored key's value, as masking finds them: a link must not.
    nonisolated static func holdsStoredKey(_ text: String) -> Bool {
        SecretMask.current.masked(text).count > 0
    }

    /// The link a key's row shows and its menu names, checked again as it is shown: nil when it has none. The index
    /// it reads had no MAC check, so opening it goes through `checkedPage(of:)`.
    func pageLink(of name: String) -> Result<URL, SecretLink.Refusal>? {
        guard let link = index?.entry(named: name)?.link else { return nil }
        let mask: (String) -> Bool = { (candidate: String) -> Bool in Self.holdsStoredKey(candidate) }
        return SecretLink.check(link, mask: mask, value: nil)
    }

    /// The page to open for a key, from vault.json's bytes as Next Term last wrote or checked them: read now, and when
    /// they are still those, its index is read from them. When they aren't (another process wrote the file since, or
    /// none was checked since launch), an unlock checks them first: one Touch ID, "check NAME's page", whose MAC check
    /// either vouches for the file or reports it as changed outside Next Term. The link is checked again before it is
    /// handed back; the caller opens it with `ServiceLinks.open`.
    func checkedPage(of name: String) async throws -> URL {
        reloadIfChanged()
        if protection == .tampered { throw refusal }
        if protection == .cantOpen { throw Failure.vault(.cantOpen) }
        var checked: SecretVault.Index? = vouchedIndex()
        if checked == nil {
            // The index from the bytes that unlock MAC-checked, as it handed it back: not `self.index`, which a reload
            // from disk could replace before this reads it.
            checked = try await run(makes: false, names: [name], reason: SecretReason.checkLink(name),
                                    change: { (_: SecretVault, _: SymmetricKey?) -> Data? in nil }, line: nil)
        }
        guard let link = checked?.entry(named: name)?.link else { throw Failure.noPage(name) }
        let mask: (String) -> Bool = { (candidate: String) -> Bool in Self.holdsStoredKey(candidate) }
        switch SecretLink.check(link, mask: mask, value: nil) {
        case .success(let url): return url
        case .failure(let refusal): throw Failure.vault(.badLink(refusal))
        }
    }

    /// The index of vault.json as it is now, when its bytes are the ones Next Term vouches for; else nil.
    private func vouchedIndex() -> SecretVault.Index? {
        guard let vouch, let data = try? folder.read(SecretFolder.vaultName, cap: SecretVault.maxFileSize),
              vouch.covers(data) else { return nil }
        return try? SecretVault.index(from: data)
    }

    // MARK: the import

    /// A key the import saves.
    struct ImportKey {
        var name: String
        var purpose: String
        var value: SecretBytes
    }

    /// One Touch ID for an import: saves its keys (origin `import`) and seals each backup's kept values under the vault
    /// key. A key an earlier move stored with the same value is kept as it is (`SecretVault.isReusable`). Returns the
    /// sealed boxes by backup id, and the names it stored itself. Nothing is saved on a failure.
    func performImport(_ keys: [ImportKey], kept: [String: [SecretBytes]],
                       reason: String) async throws -> (boxes: [String: Data], stored: Set<String>) {
        var boxes: [String: Data] = [:]
        var stored = Set<String>()
        let names = keys.map(\.name)
        let remindDays: Int? = SecretReminderRecords.newKeyDays // new keys start with Settings › Secrets' reminder
        try await run(makes: true, names: names, reason: reason) { vault, maskKey in
            var file: Data?
            stored = [] // the change may run again, on a vault.json read again
            for key in keys {
                // Stored by an earlier try whose file was left as it was: the same value under that name is used as
                // it is, not stored twice. Another value, or a key not a move's, is refused, as add refuses it.
                if try vault.isReusable(key.name, for: key.value) { continue }
                file = try vault.add(name: key.name, purpose: key.purpose, purposeBy: .user, origin: .import, writeOnly: false, value: key.value,
                                     remindDays: remindDays, maskKey: maskKey)
                stored.insert(key.name)
            }
            for (id, values) in kept where !values.isEmpty { boxes[id] = try vault.sealBackup(values, id: id) }
            return file
        } line: { SecretAudit.Line(event: .import, names: names, outcome: "moved \(names.count) \(names.count == 1 ? "key" : "keys")") }
        return (boxes, stored)
    }

    /// One Touch ID for an Undo: the keys' values and each backup's kept values, handed to `put`, which writes the
    /// files and says which keys' entries all went back. A write-only key's value is never handed over: Next Term never
    /// shows it again, in a file either, so its entries are left. With `delete`, those keys are then deleted from
    /// Secrets, in the same unlock; a key whose entry was left stays stored. `put` runs once, even when the vault's
    /// write is tried again.
    func performUndo(names: [String], kept: [String: Data], delete: Bool, reason: String,
                     put: @escaping @Sendable ([String: SecretBytes], [String: [SecretBytes]]) -> Set<String>) async throws {
        var deleted: [String] = []
        var putBack: Set<String>?
        try await run(makes: false, names: names, reason: reason) { vault, _ in
            var values: [String: SecretBytes] = [:]
            for name in names {
                guard let entry = vault.index.entry(named: name), !entry.writeOnly else { continue }
                values[name] = try vault.value(of: name)
            }
            var opened: [String: [SecretBytes]] = [:]
            for (id, box) in kept { opened[id] = try vault.openBackup(box, id: id) }
            let back = putBack ?? put(values, opened)
            putBack = back
            guard delete else { return nil }
            var file: Data?
            for name in names where back.contains(name) && vault.index.entry(named: name) != nil {
                file = try vault.delete(name)
                deleted.append(name)
            }
            return file
        } line: { SecretAudit.Line(event: .undo, names: names, outcome: deleted.isEmpty ? "put back" : "put back, and deleted \(deleted.joined(separator: ", "))") }
        if !deleted.isEmpty { NotificationCenter.default.post(name: Self.keysChanged, object: self, userInfo: ["names": deleted]) }
    }

    /// A presence check, then `change` on the unlocked vault off the main thread, then `line`, when given, in the audit
    /// log. Returns the index the unlock read and MAC-checked, as `change` left it.
    @discardableResult
    func run(makes: Bool, names: [String], reason: String, change: @escaping (SecretVault, SymmetricKey?) throws -> Data?,
                     line: (() -> SecretAudit.Line)?) async throws -> SecretVault.Index? {
        reloadIfChanged()
        if protection == .tampered { throw refusal }
        if protection == .cantOpen { throw Failure.vault(.cantOpen) }
        if index == nil, !makes { throw Failure.vault(.noSuchKey(names.first ?? "")) }
        let control = index?.keyring == .secureEnclave ? UserPresence.secureEnclaveAccessControl() : nil
        let token: AnyObject
        do {
            token = try await presence.confirm(reason: reason, accessControl: control)
        } catch let failure as UserPresence.Failure {
            throw failure == .cancelled ? Failure.cancelled : Failure.unavailable
        }
        defer { presence.finish(token) }
        setWaitingForKeychain(true) // the record, at least, is in the login keychain
        let folder = folder
        let keyring = keyring
        let newKeyring = newKeyring
        let record = record
        let box = UncheckedBox(change)
        let result = await onQueue { () -> Result<Work, Error> in
            Result {
                try Self.unlocked(makes: makes, firstName: names.first, folder: folder, keyring: keyring, newKeyring: newKeyring,
                                  record: record, token: token, change: box.value)
            }
        }
        setWaitingForKeychain(false)
        switch result {
        case .success(let work):
            let earlier = index
            took(work)
            if let line { try? folder.appendAudit(SecretAudit.encode(line(), masking: { SecretMask.current.mask($0) })) }
            publishMarks()
            NotificationCenter.default.post(name: Self.changed, object: self)
            postKeysChanged([], since: earlier)
            return work.index
        case .failure(let error):
            reloadIfChanged()
            throw handle(error, action: .use(names: names), facts: Facts())
        }
    }

    // MARK: backups

    /// Writes an import's backups to `imports/`, 0600, excluded from backups.
    func saveBackups(_ backups: [SecretImport.EntryBackup]) throws {
        _ = try folder.ensureImports()
        for backup in backups {
            guard let data = backup.encoded() else { continue }
            try folder.write(SecretFolder.importsName + "/" + backup.fileName, data: data)
        }
    }

    /// The backups younger than 30 days, newest first. Older ones are removed.
    func recentBackups(now: Date = Date()) -> [SecretImport.EntryBackup] {
        let imports = folder.url.appendingPathComponent(SecretFolder.importsName)
        guard PrivateFolder.isPrivate(imports.path, owner: geteuid()),
              let names = try? FileManager.default.contentsOfDirectory(atPath: imports.path) else { return [] }
        var found: [SecretImport.EntryBackup] = []
        for name in names where name.hasSuffix(".json") {
            // A record's id is in its file's name: one whose id names another file (a crafted id) is not read.
            guard let data = try? folder.read(SecretFolder.importsName + "/" + name, cap: 1 << 20),
                  let backup = SecretImport.EntryBackup.decode(data), Self.isPlainID(backup.id), name.hasSuffix("-\(backup.id).json") else { continue }
            if now.timeIntervalSince(backup.date) > SecretImport.keptFor {
                try? FileManager.default.removeItem(at: imports.appendingPathComponent(name))
                continue
            }
            found.append(backup)
        }
        return found.sorted { $0.date > $1.date }
    }

    /// Removes a backup's record: the file in `imports/` whose name ends with its id.
    func removeBackup(_ backup: SecretImport.EntryBackup) {
        let imports = folder.url.appendingPathComponent(SecretFolder.importsName)
        guard Self.isPlainID(backup.id), let names = try? FileManager.default.contentsOfDirectory(atPath: imports.path) else { return }
        for name in names where name.hasSuffix("-\(backup.id).json") { try? FileManager.default.removeItem(at: imports.appendingPathComponent(name)) }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// A backup's id as Next Term makes them: lowercase letters, digits and hyphens.
    nonisolated static func isPlainID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// The action on an unlocked vault: the new file's bytes, or nil when nothing is written (reveal, copy, use).
    nonisolated private static func apply(_ action: Action, to vault: SecretVault, maskKey: SymmetricKey?,
                                          values: inout [String: SecretBytes], earlier: inout SecretVault.Origin?) throws -> Data? {
        switch action {
        case .add(let key):
            return try vault.add(name: key.name, purpose: key.purpose, purposeBy: key.purposeBy, origin: key.origin,
                                 writeOnly: key.writeOnly, value: key.value, link: key.link, linkFrom: key.linkFrom,
                                 remindDays: key.remindDays, maskKey: maskKey)
        case .edit(let change):
            return try vault.edit(change.name, newName: change.newName, purpose: change.purpose, purposeBy: change.purposeBy,
                                  link: change.link, linkFrom: change.linkFrom, remindDays: change.remindDays)
        case .replace(let name, let value, let writeOnly, let origin):
            earlier = vault.index.entry(named: name)?.origin
            return try vault.replace(name, value: value, writeOnly: writeOnly, origin: origin, maskKey: maskKey)
        case .rotate(let change):
            earlier = vault.index.entry(named: change.name)?.origin
            return try vault.rotate(change.name, value: change.value, origin: .settings, link: change.link,
                                    linkFrom: change.linkFrom, remindDays: change.remindDays, maskKey: maskKey)
        case .makeWriteOnly(let name):
            return try vault.makeWriteOnly(name)
        case .delete(let name):
            return try vault.delete(name)
        case .reveal(let name), .copy(let name):
            values[name] = try vault.shownValue(of: name)
            return nil
        case .use(let names):
            for name in names { values[name] = try vault.value(of: name) }
            return nil
        }
    }

    /// An audit line for what happens outside `perform`: a use a grant answered, a decline, a grant made or ended, a
    /// refusal. Its text is masked when it is written.
    func record(_ line: SecretAudit.Line) {
        guard folder.exists else { return } // no vault yet: nothing to log against
        try? folder.appendAudit(SecretAudit.encode(line, masking: { SecretMask.current.mask($0) }))
        if line.event == .use {
            for name in line.names { lastUse[name] = line }
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }

    // MARK: Start Over

    /// Keeps the old folder as `Secrets-<date>.old.noindex` and makes a new, empty one. The next Add makes the vault.
    @discardableResult
    func startOver(on date: Date = Date()) throws -> URL? {
        var kept: URL?
        if folder.exists { kept = try folder.retire(on: date) }
        try folder.ensure()
        index = nil
        protection = .none
        isUnlisted = false
        isTooLarge = false
        lastUse = [:]
        indexDate = nil
        vouch = nil
        publishMarks()
        let line = SecretAudit.Line(event: .startOver, names: [], outcome: kept.map { "kept \($0.lastPathComponent)" })
        try? folder.appendAudit(SecretAudit.encode(line, masking: { SecretMask.current.mask($0) }))
        NotificationCenter.default.post(name: Self.changed, object: self)
        // Every grant holds values of the old vault: a key added again under its name must ask again.
        NotificationCenter.default.post(name: Self.startedOver, object: self)
        return kept
    }

    // MARK: the queue

    private func onQueue<T>(_ body: @escaping () -> T) async -> T {
        let queue = queue
        return await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
            queue.async { done.resume(returning: body()) }
        }
    }
}

/// A value handed to the store's queue: the closures `run` takes are used on that queue alone, while their caller waits.
final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// The self-test's presence check: it passes at once, or refuses when told to, and counts its calls. Never a sheet.
@MainActor
final class StandInPresence: PresenceCheck {
    private(set) var calls = 0
    var approves = true

    func confirm(reason: String, accessControl: SecAccessControl?) async throws -> AnyObject {
        calls += 1
        #if DEBUG
        reasons.append(reason)
        if holds, !(await hold()) { throw UserPresence.Failure.cancelled }
        #endif
        guard approves else { throw UserPresence.Failure.cancelled }
        return NSObject()
    }

    func finish(_ token: AnyObject) {}

    #if DEBUG
    /// Each check's reason, in order, as the sheet would show it: key names, never a value.
    private(set) var reasons: [String] = []
    /// A sheet left up: while set, each check waits for `release(approving:)`. One is up at a time, as with
    /// `UserPresence`: a second check waits its turn until the first ends.
    var holds = false
    /// A cancelled asker's check ends at once, as `UserPresence` invalidating its context does. Off, the approval can
    /// still come after the asker has gone, as one given while its window was closing.
    var endsOnCancel = true
    /// Checks ended by their asker's cancel.
    private(set) var cancelledHolds = 0
    private var held: (id: Int, done: CheckedContinuation<Bool, Never>)?
    private var heldCount = 0
    private var sheetUp = false
    private var turns: [CheckedContinuation<Void, Never>] = []
    var isHolding: Bool { held != nil }

    /// Ends the sheet that is up, if one is; the next check waiting its turn comes up.
    func release(approving: Bool) {
        let done = held?.done
        held = nil
        done?.resume(returning: approving)
    }

    private func hold() async -> Bool {
        if sheetUp {
            await withCheckedContinuation { turns.append($0) }
        } else {
            sheetUp = true
        }
        defer {
            if turns.isEmpty { sheetUp = false } else { turns.removeFirst().resume() } // the turn passes on
        }
        if Task.isCancelled { return false } // cancelled while it waited its turn
        if !holds { return true } // no longer held: it goes through
        heldCount += 1
        let id = heldCount
        return await withTaskCancellationHandler {
            await withCheckedContinuation { held = (id, $0) }
        } onCancel: {
            Task { @MainActor in self.endOnCancel(id) }
        }
    }

    /// Ends check `id` when it is the one up: a cancel that arrives late never ends a newer check.
    private func endOnCancel(_ id: Int) {
        guard endsOnCancel, held?.id == id else { return }
        cancelledHolds += 1
        release(approving: false)
    }
    #endif
}
