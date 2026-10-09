import AppKit
import NextTermCore
import Security

/// Secrets' vault in the app: the marks at launch, the load check, and every use and change, each after one presence
/// check (KTD2, KTD4, KTD5, KTD21). The format and crypto are Core's `SecretVault`; the folder is `SecretFolder`.
///
/// - `loadMarks()` reads `vault.json` and `mask.key` synchronously, with no crypto and no keychain read, before the
///   MCP socket starts, so the first MCP answer is already masked.
/// - `load()` runs the keyring's load check off the main thread, which needs no Touch ID, and sets `protection`.
/// - `perform(_:reason:facts:)` asks for presence, then on its own queue takes the vault's lock, unlocks, makes the
///   change, writes, drops the vault key and writes the audit line. Cancel or failure changes nothing.
/// - In the self-test it works on a temporary folder with a software keyring and a stand-in presence check that
///   passes at once and counts its calls. The real vault, `mask.key` and the login keychain are never touched.
@MainActor
final class SecretsStore {
    /// Posted after the index, the protection or the last uses changed.
    static let changed = Notification.Name("NextTermSecretsChanged")
    /// Posted when the Mac locks, sleeps or the session resigns: grants and pending cards end (U4).
    static let locked = Notification.Name("NextTermSecretsLocked")

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
        /// F-a: with a copy of the vault key in the login keychain.
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

    enum Action {
        case add(name: String, purpose: String, purposeBy: SecretVault.PurposeBy, origin: SecretVault.Origin, writeOnly: Bool,
                 value: SecretBytes)
        case edit(name: String, newName: String?, purpose: String?, purposeBy: SecretVault.PurposeBy)
        case replace(name: String, value: SecretBytes, writeOnly: Bool, origin: SecretVault.Origin?)
        case makeWriteOnly(name: String)
        case delete(name: String)
        case reveal(name: String)
        case copy(name: String)
        case use(names: [String])

        var names: [String] {
            switch self {
            case .add(let name, _, _, _, _, _), .edit(let name, _, _, _), .replace(let name, _, _, _), .makeWriteOnly(let name),
                 .delete(let name), .reveal(let name), .copy(let name):
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
            case .makeWriteOnly: return .writeOnly
            case .delete: return .delete
            case .reveal: return .reveal
            case .copy: return .copy
            case .use: return .use
            }
        }

        /// The sheet's reason when the caller gives none (KTD4).
        var reason: String {
            switch self {
            case .add(let name, _, _, _, _, _): return SecretReason.save(name)
            case .edit(let name, let newName, _, _):
                if let newName, newName != name { return SecretReason.rename(name, to: newName) }
                return SecretReason.changePurpose(name)
            case .replace(let name, _, _, _): return SecretReason.replace(name)
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

        var errorDescription: String? {
            switch self {
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
    private let queue = DispatchQueue(label: "NextTerm.secrets")

    /// The names, what each is for, flags and dates, read with no key.
    private(set) var index: SecretVault.Index?
    private(set) var protection: Protection = .none
    /// For each name, its newest `use` line.
    private(set) var lastUse: [String: SecretAudit.Line] = [:]
    /// True while a keychain vault's key is read: macOS may ask for the login password ("Waiting for the keychain…").
    private(set) var isWaitingForKeychain = false
    private var indexDate: Date?
    private var observers: [NSObjectProtocol] = []

    init(folder: SecretFolder, presence: PresenceCheck, newKeyring: @escaping () throws -> VaultKeyring,
         keyring: @escaping (SecretVault.Index) -> VaultKeyring) {
        self.folder = folder
        self.presence = presence
        self.newKeyring = newKeyring
        self.keyring = keyring
    }

    // MARK: the stores

    private static func appStore() -> SecretsStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SecretsStore(folder: SecretFolder(applicationSupport: support), presence: UserPresence.shared,
                            newKeyring: makeKeyring, keyring: appKeyring)
    }

    /// The self-test's: a temporary folder, one software keyring, and a presence check that passes and counts.
    private static func selfTestStore() -> SecretsStore {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-secrets-\(getpid())", isDirectory: true)
        let keyring = SoftwareKeyring(kind: .secureEnclave)
        return SecretsStore(folder: SecretFolder(applicationSupport: base), presence: StandInPresence(),
                            newKeyring: { keyring }, keyring: { _ in keyring })
    }

    /// The keyring a new vault gets: the Secure Enclave where there is one, else the login keychain. A debug build
    /// alone reads `NEXTTERM_SECRETS_KEYRING=keychain`, to make a "less protected" vault where a Secure Enclave is (H-d).
    nonisolated static func makeKeyring() throws -> VaultKeyring {
        let keychain = { try KeychainKeyring.make(store: LoginKeychain(account: LoginKeychain.vaultKeyAccount)) }
        #if DEBUG
        if ProcessInfo.processInfo.environment["NEXTTERM_SECRETS_KEYRING"] == "keychain" { return try keychain() }
        #endif
        return SecureEnclaveKeyring.isAvailable ? try SecureEnclaveKeyring.make() : try keychain()
    }

    /// An existing vault's keyring: the kind it records.
    nonisolated static func appKeyring(for index: SecretVault.Index) -> VaultKeyring {
        switch index.keyring {
        case .secureEnclave: return SecureEnclaveKeyring(blob: index.keyBlob ?? Data())
        case .keychain: return KeychainKeyring(store: LoginKeychain(account: LoginKeychain.vaultKeyAccount))
        }
    }

    // MARK: launch

    /// The marks, read synchronously at launch with no crypto and no keychain read: `vault.json`'s index and
    /// `mask.key`. Masking publishes them (U3). Sets `marksLoaded`.
    func loadMarks() {
        defer { Self.marksLoaded = true }
        guard folder.exists, let data = try? folder.read(SecretFolder.vaultName, cap: SecretVault.maxFileSize),
              let index = try? SecretVault.index(from: data) else { return }
        self.index = index
        indexDate = folder.modificationDate(of: SecretFolder.vaultName)
    }

    /// The index and the load check, off the main thread: the keyring's `check()` needs no Touch ID. A key that is not
    /// this Mac's sets `protection` to `.cantOpen` at once.
    func load() async {
        let folder = folder
        let keyring = keyring
        let found = await onQueue { () -> (SecretVault.Index?, Protection, Data) in
            let audit = folder.exists ? folder.readAudit() : Data()
            guard folder.exists else { return (nil, .none, audit) }
            let data: Data?
            do {
                data = try folder.read(SecretFolder.vaultName, cap: SecretVault.maxFileSize)
            } catch {
                return (nil, .tampered, audit)
            }
            guard let data else { return (nil, .none, audit) }
            guard let index = try? SecretVault.index(from: data) else { return (nil, .tampered, audit) }
            let opens = keyring(index).check(publicKey: index.publicKey)
            return (index, opens ? Self.protection(of: index) : .cantOpen, audit)
        }
        index = found.0
        protection = found.1
        lastUse = SecretAudit.lastUse(in: found.2)
        indexDate = folder.modificationDate(of: SecretFolder.vaultName)
        if !SelfTest.isRequested { startObserving() }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    nonisolated static func protection(of index: SecretVault.Index) -> Protection {
        switch index.keyring {
        case .secureEnclave: return index.hasRecovery ? .secureEnclaveWithRecovery : .secureEnclave
        case .keychain: return .lessProtected
        }
    }

    /// `vault.json` read again when its modification date changed (another copy of Next Term saved it): before each
    /// operation, and when Next Term becomes active.
    func reloadIfChanged() {
        let date = folder.modificationDate(of: SecretFolder.vaultName)
        guard date != indexDate else { return }
        indexDate = date
        guard date != nil else {
            // Gone: another copy started over.
            index = nil
            protection = .none
            NotificationCenter.default.post(name: Self.changed, object: self)
            return
        }
        let data = try? folder.read(SecretFolder.vaultName, cap: SecretVault.maxFileSize)
        if let data, let read = try? SecretVault.index(from: data) {
            index = read
            if protection == .none { protection = Self.protection(of: read) }
        } else {
            protection = .tampered
        }
        NotificationCenter.default.post(name: Self.changed, object: self)
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
        if protection == .tampered { throw Failure.vault(.tampered) }
        if protection == .cantOpen { throw Failure.vault(.cantOpen) }
        if index == nil, !action.isAdd { throw Failure.vault(.noSuchKey(action.names.first ?? "")) }
        let isKeychain = index?.keyring == .keychain
        let control = index?.keyring == .secureEnclave ? UserPresence.secureEnclaveAccessControl() : nil
        let token: AnyObject
        do {
            token = try await presence.confirm(reason: reason ?? action.reason, accessControl: control)
        } catch let failure as UserPresence.Failure {
            throw failure == .cancelled ? Failure.cancelled : Failure.unavailable
        }
        defer { presence.finish(token) }
        if isKeychain { setWaitingForKeychain(true) }
        let folder = folder
        let keyring = keyring
        let newKeyring = newKeyring
        let result = await onQueue { () -> Result<Work, Error> in
            Result { try Self.work(action, facts: facts, folder: folder, keyring: keyring, newKeyring: newKeyring, token: token) }
        }
        if isKeychain { setWaitingForKeychain(false) }
        switch result {
        case .success(let work):
            if let changed = work.index { index = changed }
            if protection == .none, let index { protection = Self.protection(of: index) }
            indexDate = folder.modificationDate(of: SecretFolder.vaultName)
            if action.event == .use, let line = work.line { for name in action.names { lastUse[name] = line } }
            NotificationCenter.default.post(name: Self.changed, object: self)
            return work.values
        case .failure(let error):
            throw handle(error, action: action, facts: facts)
        }
    }

    /// What a failed perform says, and what it leaves: a tampered vault or one that can't open is noted, with a
    /// `tamper` line for the first.
    private func handle(_ error: Error, action: Action, facts: Facts) -> Failure {
        let failure: Failure
        switch error {
        case let vault as SecretVault.Failure: failure = .vault(vault)
        case let folder as SecretFolder.Failure: failure = folder == .notPrivate ? .vault(.tampered) : .folder(folder)
        case is Failure: failure = error as? Failure ?? .keyring
        default: failure = .keyring
        }
        if failure == .vault(.tampered) {
            protection = .tampered
            let line = SecretAudit.Line(event: .tamper, names: action.names, who: facts.who, command: facts.command,
                                        folder: facts.folder, outcome: "refused")
            try? folder.appendAudit(SecretAudit.encode(line))
            NotificationCenter.default.post(name: Self.changed, object: self)
        } else if failure == .vault(.cantOpen) {
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
        var values: [String: SecretBytes] = [:]
        var line: SecretAudit.Line?
    }

    /// Under the vault's lock: unlock (or make the vault, for the first add), the change, the write; then the audit line.
    nonisolated private static func work(_ action: Action, facts: Facts, folder: SecretFolder,
                                         keyring: (SecretVault.Index) -> VaultKeyring, newKeyring: () throws -> VaultKeyring,
                                         token: AnyObject) throws -> Work {
        try folder.ensure()
        var vault: SecretVault?
        defer { vault?.wipe() }
        var work = Work()
        var earlier: SecretVault.Origin?
        try folder.withLock {
            try folder.update { current in
                let opened: SecretVault
                if let vault, let current {
                    try vault.reload(current)
                    opened = vault
                } else if let current {
                    let index = try SecretVault.index(from: current)
                    opened = try SecretVault.unlock(current, keyring: keyring(index), context: token)
                } else {
                    guard action.isAdd else { throw SecretVault.Failure.noSuchKey(action.names.first ?? "") }
                    let made: (vault: SecretVault, maskKey: SecretBytes)
                    do {
                        made = try SecretVault.create(keyring: newKeyring())
                    } catch let failure as SecretVault.Failure {
                        throw failure
                    } catch {
                        throw Failure.keyring
                    }
                    let maskKey = made.maskKey.withUnsafeBytes { Data($0) }
                    try folder.write(SecretFolder.maskKeyName, data: maskKey)
                    opened = made.vault
                }
                vault = opened
                return try apply(action, to: opened, values: &work.values, earlier: &earlier)
            }
        }
        work.index = vault?.index
        let line = SecretAudit.Line(event: action.event, names: action.names, who: facts.who, command: facts.command,
                                    folder: facts.folder, approval: facts.approval, outcome: "done",
                                    earlierOrigin: earlier?.rawValue)
        try? folder.appendAudit(SecretAudit.encode(line))
        work.line = line
        return work
    }

    /// The action on an unlocked vault: the new file's bytes, or nil when nothing is written (reveal, copy, use).
    nonisolated private static func apply(_ action: Action, to vault: SecretVault, values: inout [String: SecretBytes],
                                          earlier: inout SecretVault.Origin?) throws -> Data? {
        switch action {
        case .add(let name, let purpose, let purposeBy, let origin, let writeOnly, let value):
            return try vault.add(name: name, purpose: purpose, purposeBy: purposeBy, origin: origin, writeOnly: writeOnly, value: value)
        case .edit(let name, let newName, let purpose, let purposeBy):
            return try vault.edit(name, newName: newName, purpose: purpose, purposeBy: purposeBy)
        case .replace(let name, let value, let writeOnly, let origin):
            earlier = vault.index.entry(named: name)?.origin
            return try vault.replace(name, value: value, writeOnly: writeOnly, origin: origin)
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

    // MARK: Start Over

    /// Keeps the old folder as `Secrets-<date>.old.noindex` and makes a new, empty one. The next Add makes the vault.
    @discardableResult
    func startOver(on date: Date = Date()) throws -> URL? {
        var kept: URL?
        if folder.exists { kept = try folder.retire(on: date) }
        try folder.ensure()
        index = nil
        protection = .none
        lastUse = [:]
        indexDate = nil
        let line = SecretAudit.Line(event: .startOver, names: [], outcome: kept.map { "kept \($0.lastPathComponent)" })
        try? folder.appendAudit(SecretAudit.encode(line))
        NotificationCenter.default.post(name: Self.changed, object: self)
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

/// The self-test's presence check: it passes at once, or refuses when told to, and counts its calls. Never a sheet.
@MainActor
final class StandInPresence: PresenceCheck {
    private(set) var calls = 0
    var approves = true

    func confirm(reason: String, accessControl: SecAccessControl?) async throws -> AnyObject {
        calls += 1
        guard approves else { throw UserPresence.Failure.cancelled }
        return NSObject()
    }

    func finish(_ token: AnyObject) {}
}
