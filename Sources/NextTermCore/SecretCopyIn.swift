import CryptoKit
import Foundation

// Keys copied in from a file an import read: the preview's ticked rows saved in one unlock, each new key with origin
// `import`, its page and what it's for, and a record Undo reads. The file is never written. The record holds names,
// entry ids and the dates their values were set, never a value, so Undo deletes only keys whose value is still the one
// copied in. A key the copy-in replaced keeps no old value to put back: Undo leaves it, and the confirm says so first.

public enum SecretCopyIn {
    /// A ticked row as the vault takes it: a new key, or a new value for a key stored already.
    public struct Planned: Sendable {
        public let name: String
        public let value: SecretBytes
        /// What a new key is for: fixed text from the file's name and folder, or the app that wrote an export.
        public let purpose: String
        /// Its page, as the link rules gave it when the file was read; nil when it has none, or it holds a stored key.
        public let link: String?
        public let linkFrom: SecretVault.LinkFrom?
        /// A key of this name is stored: it gets the new value and keeps what it's for, and its page when it has one.
        public let replaces: Bool
        /// "Never show": a new key is saved write-only, and so is a key it replaces, which stays write-only either way.
        public internal(set) var writeOnly: Bool = false
    }

    /// Why ticked rows can't be saved: the preview checks names as they are typed, so this is a last check.
    public enum Problem: Error, Equatable, Sendable {
        case badName(String)
        case sameName(String)
    }

    /// The ticked rows as keys to save, in the preview's order, named as it shows them. A row with a refusal is never
    /// saved. A page that holds a stored key (`holdsKey`, as masking finds them) is left out: the file's own values
    /// were looked for when it was read.
    public static func plan(_ rows: [SourceRow], purpose: String, stored: Set<String>,
                            holdsKey: (String) -> Bool = { (_: String) -> Bool in false }) throws -> [Planned] {
        var names = Set<String>()
        var planned: [Planned] = []
        for row in rows where row.ticked && row.refusal == nil {
            guard StoredSecretName.isValid(row.name) else { throw Problem.badName(row.name) }
            guard names.insert(row.name).inserted else { throw Problem.sameName(row.name) }
            var link: String? = row.link?.url.absoluteString
            if let text = link, holdsKey(text) { link = nil }
            let from: SecretVault.LinkFrom? = link == nil ? nil : linkFrom(row.link)
            planned.append(Planned(name: row.name, value: row.value, purpose: purpose, link: link, linkFrom: from,
                                   replaces: stored.contains(row.name), writeOnly: row.neverShow))
        }
        return planned
    }

    /// The names more than one of `ticked` has, the names of the preview's ticked rows: each such row is marked, as
    /// `plan` refuses them. One pass, however many rows the preview lists.
    public static func repeatedNames(_ ticked: [String]) -> Set<String> {
        var seen = Set<String>()
        var repeated = Set<String>()
        for name in ticked where !seen.insert(name).inserted { repeated.insert(name) }
        return repeated
    }

    /// A page from the file is the import's; one suggested from the value or the name is a suggestion.
    static func linkFrom(_ hint: SecretSources.LinkHint?) -> SecretVault.LinkFrom? {
        switch hint {
        case .source?: return .imported
        case .suggested?: return .suggested
        case nil: return nil
        }
    }

    /// The planned keys saved in `vault`, in one change: each new key with origin `import`, its page, what it's for,
    /// `remindDays` (the reminder new keys start with) and `asksEveryUse` (whether they ask for Touch ID every time);
    /// each key it replaces with its new value and origin `import`, never shown when it was or the row says so.
    /// The vault may have changed since the plan: a key planned as new that is stored now is refused (`nameTaken`),
    /// since the confirm never named it, and nothing is saved; one planned as a replace that is gone now is added.
    /// Returns the file to write (nil when nothing changed) and the record for Undo, under `id`.
    public static func apply(_ planned: [Planned], to vault: SecretVault, source: String, format: SecretSources.Format,
                             remindDays: Int?, asksEveryUse: Bool = true, maskKey: SymmetricKey?,
                             id: String = UUID().uuidString.lowercased(),
                             now: Date = Date()) throws -> (file: Data?, record: Record) {
        var added: [Record.Added] = []
        var replaced: [String] = []
        let save: () throws -> Void = { () throws -> Void in
            for key in planned {
                if key.replaces, let entry = vault.index.entry(named: key.name) {
                    let writeOnly: Bool = entry.writeOnly || key.writeOnly
                    _ = try vault.replace(key.name, value: key.value, writeOnly: writeOnly, origin: .import,
                                          maskKey: maskKey, now: now)
                    if entry.link == nil, let link = key.link {
                        _ = try vault.edit(key.name, link: .some(link), linkFrom: key.linkFrom, now: now)
                    }
                    replaced.append(key.name)
                    continue
                }
                // A key stored since the plan makes `add` throw `nameTaken`.
                _ = try vault.add(name: key.name, purpose: key.purpose, purposeBy: .user, origin: .import,
                                  writeOnly: key.writeOnly, value: key.value, link: key.link, linkFrom: key.linkFrom,
                                  remindDays: remindDays, asksEveryUse: asksEveryUse, maskKey: maskKey, now: now)
                if let entry = vault.index.entry(named: key.name) {
                    added.append(Record.Added(name: entry.name, id: entry.id, valueSet: entry.lastSet))
                }
            }
        }
        let file: Data? = planned.isEmpty ? nil : try vault.batch(now: now, save)
        let date: Date = SecretVault.whole(now)
        let record = Record(id: id, date: date, source: source, format: format.rawValue, added: added, replaced: replaced)
        return (file, record)
    }
}

// MARK: - The record Undo reads

extension SecretCopyIn {
    /// What a copy-in saved, for Undo in Recent imports: in the vault folder's `imports/`, beside the MCP-config
    /// import's backups, for 30 days. Names, entry ids and dates only.
    public struct Record: Codable, Equatable, Sendable {
        /// A key the copy-in added, and when its value was set then.
        public struct Added: Codable, Equatable, Sendable {
            public let name: String
            public let id: String
            public let valueSet: Date
        }

        static let kindName = "copy-in"

        /// Tells a copy-in's record from a backup in the same folder.
        public let kind: String
        public let id: String
        public let date: Date
        /// Where the keys came from, as Recent imports says it: ".env in rag-api", "Bitwarden".
        public let source: String
        /// The format the file was read as (`SecretSources.Format`'s raw value).
        public let format: String
        public let added: [Added]
        /// Keys it gave a new value: Undo can't put their old values back, so it leaves them.
        public let replaced: [String]

        public init(id: String, date: Date, source: String, format: String, added: [Added], replaced: [String]) {
            kind = Self.kindName
            self.id = id
            self.date = date
            self.source = source
            self.format = format
            self.added = added
            self.replaced = replaced
        }

        /// The keys it saved, added first, as it named them.
        public var names: [String] { added.map(\.name) + replaced }

        /// The record's file name in `imports/`: a backup's name has no `copy-`.
        public var fileName: String { "\(SecretFolder.day(of: date))-copy-\(id).json" }

        public func encoded() -> Data? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try? encoder.encode(self)
        }

        /// A copy-in's record, or nil for anything else in the folder (a backup, a crafted file).
        public static func decode(_ data: Data) -> Record? {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let record = try? decoder.decode(Record.self, from: data), record.kind == kindName else { return nil }
            return record
        }
    }

    /// What an Undo of a copy-in does, by the keys' names now.
    public struct UndoPlan: Equatable, Sendable {
        /// Keys it deletes: each still holds the value copied in, though it may have been renamed.
        public let deletes: [String]
        /// Keys copied in whose value was set again since: they stay.
        public let changed: [String]
        /// Keys the copy-in gave a new value: their old values are gone, so they stay.
        public let replaced: [String]
        /// Keys copied in that are gone already.
        public let gone: [String]
        /// Keys copied in that entries an MCP-config import rewrote start with: a later move used each instead of
        /// storing a second copy, so they stay.
        public let inUse: [String]

        public init(deletes: [String], changed: [String], replaced: [String], gone: [String], inUse: [String] = []) {
            self.deletes = deletes
            self.changed = changed
            self.replaced = replaced
            self.gone = gone
            self.inUse = inUse
        }
    }

    /// Each key the record added, found by its entry id: deleted while its value is still the one copied in and it
    /// is an import's, unless `usedElsewhere` names it. That is every key the recent MCP-config moves' entries name,
    /// as a move's own Undo keeps a key other entries still use: a move may use a key copied in that holds its value.
    public static func undoPlan(_ record: Record, index: SecretVault.Index?,
                                usedElsewhere: Set<String> = []) -> UndoPlan {
        var deletes: [String] = []
        var changed: [String] = []
        var gone: [String] = []
        var inUse: [String] = []
        for added in record.added {
            let entry: SecretVault.Entry? = index?.entries.first { (entry: SecretVault.Entry) -> Bool in
                entry.id == added.id
            }
            guard let entry else {
                gone.append(added.name)
                continue
            }
            // A key no import added (a record written by another process can name any key's id and date, which
            // vault.json shows unlocked) stays, as one changed since does.
            if entry.lastSet == added.valueSet, entry.origin == .import {
                if usedElsewhere.contains(entry.name) {
                    inUse.append(entry.name)
                } else {
                    deletes.append(entry.name)
                }
            } else {
                changed.append(entry.name)
            }
        }
        let replaced: [String] = record.replaced.filter { (name: String) -> Bool in index?.entry(named: name) != nil }
        return UndoPlan(deletes: deletes, changed: changed, replaced: replaced, gone: gone, inUse: inUse)
    }

    /// The Undo on an unlocked vault: its plan from the vault's own index and `usedElsewhere`, as the confirm read
    /// them, then each key it names deleted. The file to write is nil when nothing was deleted; `left` is the record
    /// to keep in its place, nil when the record goes.
    public static func undo(_ record: Record, in vault: SecretVault,
                            usedElsewhere: Set<String> = []) throws -> (file: Data?, plan: UndoPlan, left: Record?) {
        let plan: UndoPlan = undoPlan(record, index: vault.index, usedElsewhere: usedElsewhere)
        var file: Data?
        if !plan.deletes.isEmpty {
            file = try vault.batch {
                for name in plan.deletes { _ = try vault.delete(name) }
            }
        }
        return (file, plan, left(record, after: plan, index: vault.index))
    }

    /// What stays of `record` once its Undo ran: the keys it added that the Undo kept only because entries an
    /// MCP-config import rewrote start with them, named as they are now, under the same id and file, so Undo can
    /// delete them once that import is undone. Nil when the Undo kept none so: the record goes. Keys that changed
    /// since, or that it replaced, stay for good and leave the record.
    public static func left(_ record: Record, after plan: UndoPlan, index: SecretVault.Index?) -> Record? {
        guard !plan.inUse.isEmpty, let index else { return nil }
        let inUse: Set<String> = Set(plan.inUse)
        var kept: [Record.Added] = []
        for added in record.added {
            let entry: SecretVault.Entry? = index.entries.first { (entry: SecretVault.Entry) -> Bool in
                entry.id == added.id
            }
            guard let entry, inUse.contains(entry.name) else { continue }
            kept.append(Record.Added(name: entry.name, id: added.id, valueSet: added.valueSet))
        }
        guard !kept.isEmpty else { return nil }
        return Record(id: record.id, date: record.date, source: record.source, format: record.format, added: kept,
                      replaced: [])
    }
}

// MARK: - What a copy-in says

extension SecretCopyIn {
    /// The audit line's outcome: "copied 3 keys from a .env file". No name of the file: the audit keeps no path.
    public static func auditOutcome(count: Int, format: SecretSources.Format) -> String {
        "copied \(count) \(count == 1 ? "key" : "keys") from \(formatNoun(format))"
    }

    /// "a .env file", "a Bitwarden export".
    public static func formatNoun(_ format: SecretSources.Format) -> String {
        switch format {
        case .env: return "a .env file"
        case .json: return "a JSON file"
        case .toml: return "a TOML file"
        case .yaml: return "a YAML file"
        case .csv: return "a CSV file"
        case .bitwarden: return "a Bitwarden export"
        case .onePassword: return "a 1Password export"
        case .bws: return "a Bitwarden Secrets Manager list"
        }
    }

    /// "Copied 3 keys into Secrets."
    public static func copiedText(_ count: Int) -> String {
        "Copied \(count) \(count == 1 ? "key" : "keys") into Secrets."
    }

    /// What the done sheet says about the file the keys came from, which the copy-in left as it was: for a `.env`, how
    /// to start the project with the keys from Secrets instead; for an agent's config Next Term can't rewrite, that it
    /// still holds them; for any other file, that it still holds them. An export gets nil: the sheet offers to move it
    /// to the Trash instead. `readAs` holds the name the file gave each key, by its name in Secrets: a key renamed in
    /// the preview is set as the project reads it (`NAME=ENVNAME`).
    public static func doneLine(names: [String], file: String, format: SecretSources.Format, agent: String?,
                                exported: Bool = false, readAs: [String: String] = [:]) -> String? {
        guard !names.isEmpty, !exported else { return nil }
        let one: Bool = names.count == 1
        let holds: String = "\(file) still holds \(one ? "this key" : "these keys")"
        if agent != nil { return holds + "; Next Term can\u{2019}t rewrite it yet." }
        guard format == .env else {
            return holds + ". Delete \(one ? "it" : "them") from it once nothing reads \(one ? "it" : "them") there."
        }
        let pairs: [String] = names.map { (name: String) -> String in runPair(name, readAs: readAs[name]) }
        let run: String = "nxtrm secret run " + pairs.joined(separator: " ") + " -- <your command>"
        return holds + ". Start the project with \(run), then delete \(one ? "it" : "them") from \(file)."
    }

    /// `NAME`, or `NAME=ENVNAME` when the file names the key otherwise and `secret run` can set that name.
    static func runPair(_ name: String, readAs: String?) -> String {
        guard let envName = readAs, envName != name, StoredSecretName.isValid(envName),
              !StoredSecretName.isRefusedEnvName(envName) else { return name }
        return name + "=" + envName
    }

    /// "15 Oct: OPENAI_API_KEY and PINECONE_API_KEY, copied from .env in rag-api", for Recent imports.
    public static func recentText(_ record: Record, day: String) -> String {
        "\(day): \(SecretRun.keysText(record.names)), copied from \(record.source)"
    }
}

extension SecretCopyIn.UndoPlan {
    /// What Undo did, for the line under the list: what it deleted, then each key it left and why.
    public var text: String {
        if deletes.isEmpty, changed.isEmpty, replaced.isEmpty, inUse.isEmpty {
            guard !gone.isEmpty else { return "Nothing to delete." }
            return "Nothing to delete: \(SecretRun.keysText(gone)) \(gone.count == 1 ? "is" : "are") gone already."
        }
        let first: String = deletes.isEmpty ? "Nothing deleted." : "Deleted \(SecretRun.keysText(deletes))."
        var lines: [String] = [first]
        if let kept = keptText { lines.append(kept) }
        if !gone.isEmpty {
            lines.append("\(SecretRun.keysText(gone)) \(gone.count == 1 ? "is" : "are") gone already.")
        }
        return lines.joined(separator: " ")
    }

    /// Why the keys Undo leaves stay: changed since, replacing a key whose old value is gone, or started with by
    /// entries an MCP-config import rewrote. Nil when none stay.
    public var keptText: String? {
        var lines: [String] = []
        if !changed.isEmpty {
            let one: Bool = changed.count == 1
            lines.append("\(SecretRun.keysText(changed)) changed since the import, so \(one ? "it stays" : "they stay").")
        }
        if !replaced.isEmpty {
            let one: Bool = replaced.count == 1
            let had: String = one ? "it replaced a key you had, whose old value is gone"
                : "they replaced keys you had, whose old values are gone"
            lines.append("\(SecretRun.keysText(replaced)) \(one ? "stays" : "stay"): \(had).")
        }
        if !inUse.isEmpty {
            let one: Bool = inUse.count == 1
            let stay: String = "\(SecretRun.keysText(inUse)) \(one ? "stays" : "stay") in Secrets"
            let them: String = one ? "it" : "them"
            lines.append(stay + ": entries an MCP-config import rewrote start with \(them). Once that import is undone, "
                + "Undo here deletes \(them).")
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }
}
