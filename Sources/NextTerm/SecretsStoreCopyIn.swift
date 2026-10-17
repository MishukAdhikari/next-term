import AppKit
import CryptoKit
import NextTermCore

/// Import From › A File…'s side of the vault: the ticked rows copied in under one Touch ID, the record Undo reads, and
/// that Undo. The file the keys came from is never written. Core's `SecretCopyIn` plans and saves; this runs it.
extension SecretsStore {
    /// One Touch ID ("copy 3 keys from .env"), then the planned keys saved in one unlock, one audit line ("copied 3 keys
    /// from a .env file") and the record for Undo in `imports/`. The record is written after the vault: a record that
    /// failed to save leaves the keys in, with no Undo, and `undoSaved` says so for the done view. Nothing is saved on
    /// a failure.
    /// An agent's import_secrets request (`asked`) puts who asked and its reason on the audit line, never on a key.
    func performCopyIn(_ planned: [SecretCopyIn.Planned], source: String, format: SecretSources.Format,
                       reason: String, asked: SecretImportAsk? = nil) async throws -> (record: SecretCopyIn.Record, undoSaved: Bool) {
        let names: [String] = planned.map(\.name)
        let remindDays: Int? = SecretReminderRecords.newKeyDays // new keys start with Settings › Secrets' reminder
        let asks: Bool = SecretNewKeyDefaults.asksEveryUse // and its New keys default
        let id: String = UUID().uuidString.lowercased()
        let who: String? = asked?.askedBy
        let command: String? = asked?.command
        let box = CopyInBox()
        try await run(makes: true, names: names, reason: reason) {
            (vault: SecretVault, maskKey: SymmetricKey?) -> Data? in
            // The change may run again, on a vault.json read again: the record is the last run's.
            let done = try SecretCopyIn.apply(planned, to: vault, source: source, format: format, remindDays: remindDays,
                                              asksEveryUse: asks, maskKey: maskKey, id: id)
            box.record = done.record
            return done.file
        } line: { () -> SecretAudit.Line in
            let outcome: String = SecretCopyIn.auditOutcome(count: names.count, format: format)
            return SecretAudit.Line(event: .import, names: names, who: who, command: command, outcome: outcome)
        }
        guard let record = box.record else { throw Failure.vault(.changed) }
        let undoSaved: Bool = (try? saveCopyIn(record)) != nil
        NotificationCenter.default.post(name: Self.changed, object: self)
        return (record, undoSaved)
    }

    /// One Touch ID, then the keys the copy-in added that still hold the value it copied in deleted in one unlock; the
    /// others stay. The record goes once its Undo ran.
    func performCopyInUndo(_ record: SecretCopyIn.Record) async throws -> SecretCopyIn.UndoPlan {
        let plan: SecretCopyIn.UndoPlan = SecretCopyIn.undoPlan(record, index: index)
        let box = CopyInBox()
        let reason: String = SecretReason.removeCopied(max(plan.deletes.count, 1))
        try await run(makes: false, names: plan.deletes, reason: reason) {
            (vault: SecretVault, _: SymmetricKey?) -> Data? in
            let undone = try SecretCopyIn.undo(record, in: vault)
            box.plan = undone.plan
            return undone.file
        } line: { () -> SecretAudit.Line in
            let deleted: [String] = box.plan?.deletes ?? []
            let outcome: String = "deleted \(deleted.count) \(deleted.count == 1 ? "key" : "keys") an import copied in"
            return SecretAudit.Line(event: .undo, names: deleted, outcome: outcome)
        }
        removeCopyIn(record)
        return box.plan ?? plan
    }

    // MARK: records

    /// Writes a copy-in's record to `imports/`, 0600, excluded from backups, as the backups are. Throws when it isn't
    /// written, so the done view can say there is no Undo.
    func saveCopyIn(_ record: SecretCopyIn.Record) throws {
        _ = try folder.ensureImports()
        guard Self.isPlainID(record.id), let data = record.encoded() else { throw CocoaError(.fileWriteUnknown) }
        try folder.write(SecretFolder.importsName + "/" + record.fileName, data: data)
    }

    /// The copy-ins younger than 30 days, newest first. Older records are removed.
    func recentCopyIns(now: Date = Date()) -> [SecretCopyIn.Record] {
        let imports: URL = folder.url.appendingPathComponent(SecretFolder.importsName)
        guard PrivateFolder.isPrivate(imports.path, owner: geteuid()),
              let names = try? FileManager.default.contentsOfDirectory(atPath: imports.path) else { return [] }
        var found: [SecretCopyIn.Record] = []
        for name in names where name.hasSuffix(".json") && name.contains("-copy-") {
            // A record's id is in its file's name: one whose id names another file (a crafted id) is not read.
            guard let data = try? folder.read(SecretFolder.importsName + "/" + name, cap: 1 << 20),
                  let record = SecretCopyIn.Record.decode(data), Self.isPlainID(record.id),
                  name.hasSuffix("-copy-\(record.id).json") else { continue }
            if now.timeIntervalSince(record.date) > SecretImport.keptFor {
                try? FileManager.default.removeItem(at: imports.appendingPathComponent(name))
                continue
            }
            found.append(record)
        }
        return found.sorted { (a: SecretCopyIn.Record, b: SecretCopyIn.Record) -> Bool in a.date > b.date }
    }

    /// Removes a copy-in's record: the file in `imports/` whose name ends with its id.
    func removeCopyIn(_ record: SecretCopyIn.Record) {
        let imports: URL = folder.url.appendingPathComponent(SecretFolder.importsName)
        guard Self.isPlainID(record.id),
              let names = try? FileManager.default.contentsOfDirectory(atPath: imports.path) else { return }
        for name in names where name.hasSuffix("-copy-\(record.id).json") {
            try? FileManager.default.removeItem(at: imports.appendingPathComponent(name))
        }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

/// What a copy-in or its Undo did in the unlock, filled on the store's queue while the main actor waits.
final class CopyInBox: @unchecked Sendable {
    private let lock = NSLock()
    private var heldRecord: SecretCopyIn.Record?
    private var heldPlan: SecretCopyIn.UndoPlan?

    var record: SecretCopyIn.Record? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return heldRecord
        }
        set {
            lock.lock()
            heldRecord = newValue
            lock.unlock()
        }
    }

    var plan: SecretCopyIn.UndoPlan? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return heldPlan
        }
        set {
            lock.lock()
            heldPlan = newValue
            lock.unlock()
        }
    }
}
