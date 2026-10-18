import Foundation

/// A key rotation reminder Next Term posts about one key: its "Remind me to rotate" age has passed, or Rotate…'s Remind
/// Me Tomorrow asked for one today. It says the key's name and age and nothing else: never a value, a part of one, or a
/// link. The records it is shown by (when each key was last reminded) live outside the vault, keyed by name, so a
/// reminder never needs Touch ID.
public struct SecretReminder: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// The key's "Remind me to rotate" age has passed.
        case due
        /// Remind Me Tomorrow, after a rotation: delete or deactivate the old key.
        case deleteOld
        /// More than `mostApart` keys due at once, in one notification: `name` is the first in the list's order.
        case severalDue
    }

    public let name: String
    public let kind: Kind
    /// For `severalDue`: how many other keys are due with `name`. Not carried by a click, which reads them again.
    public let others: Int

    public init(name: String, kind: Kind, others: Int = 0) {
        self.name = name
        self.kind = kind
        self.others = others
    }

    /// The notification's identifier: one per key, so a newer reminder about it replaces an older one. Several keys'
    /// one has its own, in lowercase, which no key's name can be.
    public var identifier: String { "secret-rotate-" + (kind == .severalDue ? "several" : name) }

    /// What the notification carries, for its click: the key's name and the reminder's kind.
    public var userInfo: [String: String] { ["secret": name, "secretReminder": kind.rawValue] }

    /// The reminder a clicked notification names, or nil for any other notification. A kind this build doesn't know
    /// reads as `due`, whose click opens Rotate….
    public init?(userInfo: [AnyHashable: Any]) {
        guard let name = userInfo["secret"] as? String, StoredSecretName.isValid(name) else { return nil }
        let kind: Kind = (userInfo["secretReminder"] as? String).flatMap(Kind.init(rawValue:)) ?? .due
        self.init(name: name, kind: kind)
    }

    public var title: String {
        switch kind {
        case .due: return "Time to rotate a key"
        case .deleteOld: return "Delete an old key"
        case .severalDue: return "Time to rotate keys"
        }
    }

    /// "OPENAI_API_KEY was last rotated 92 days ago": the name and the age, from the entry as stored now.
    public func body(entry: SecretVault.Entry?, now: Date, calendar: Calendar = .current) -> String {
        if kind == .severalDue {
            let others: String = self.others == 1 ? "1 other key" : "\(self.others) other keys"
            return "\(name) and \(others) are past their \u{201C}Remind me to rotate\u{201D} age"
        }
        guard kind == .due, let entry else {
            return "Delete or deactivate the old \(name) where you made it, if you haven\u{2019}t yet"
        }
        let days: Int = SecretAge.days(from: entry.lastSet, to: now, calendar: calendar)
        let ago: String = days == 1 ? "1 day ago" : "\(days) days ago"
        guard SecretAge.wasGivenNewValue(entry) else {
            return "\(name) was added \(ago) and hasn\u{2019}t been rotated since"
        }
        return "\(name) was last rotated \(ago)"
    }

    /// The default "Remind me to rotate" for new keys, as Settings › Secrets saved it: nil (Never) for nothing saved,
    /// 0, or an age outside `SecretVault.remindRange`.
    public static func newKeyDays(stored: Any?) -> Int? {
        guard let days = stored as? Int, days > 0, SecretVault.remindRange.contains(days) else { return nil }
        return days
    }

    /// Records by key name (when each was last reminded, or the day Remind Me Tomorrow set) carried from the keys
    /// `earlier` held to the keys `later` holds: a renamed key's record moves to its new name, since a rename keeps a
    /// key's id; a deleted key's goes, as does one whose name now holds another key (deleted and added again). A record
    /// for a name `earlier` didn't hold stays only while `later` holds that name.
    public static func carried(_ records: [String: Date], from earlier: [SecretVault.Entry]?,
                               to later: [SecretVault.Entry]) -> [String: Date] {
        var idsBefore: [String: String] = [:]
        for entry in earlier ?? [] { idsBefore[entry.name] = entry.id }
        var namesNow: [String: String] = [:]
        for entry in later { namesNow[entry.id] = entry.name }
        let heldNow = Set(later.map(\.name))
        var kept: [String: Date] = [:]
        for (name, date) in records {
            let newName: String?
            if let id = idsBefore[name] {
                newName = namesNow[id]
            } else {
                newName = heldNow.contains(name) ? name : nil
            }
            guard let newName else { continue }
            let other: Date? = kept[newName]
            kept[newName] = other.map { (seen: Date) -> Date in max(seen, date) } ?? date
        }
        return kept
    }
}

extension SecretReminder {
    /// More due keys than this in one check get one notification for all of them, not one each.
    public static let mostApart = 3

    /// The reminders as posted: past `mostApart` due keys at once, one `severalDue` reminder for all of them, where the
    /// first stood. Remind Me Tomorrow's stay one each, since the user asked for each.
    public static func folded(_ reminders: [SecretReminder]) -> [SecretReminder] {
        let due: [SecretReminder] = reminders.filter { (reminder: SecretReminder) -> Bool in reminder.kind == .due }
        guard due.count > mostApart, let first = due.first else { return reminders }
        let several = SecretReminder(name: first.name, kind: .severalDue, others: due.count - 1)
        var posted: [SecretReminder] = []
        for reminder in reminders {
            if reminder.kind != .due {
                posted.append(reminder)
            } else if reminder == first {
                posted.append(several)
            }
        }
        return posted
    }

    /// The names whose posted reminder no longer holds, from the keys `earlier` held to the keys `later` holds: a key
    /// renamed (its old name), deleted, or given a new value since (rotated, replaced or imported over). A name that
    /// now holds another key (deleted and added again) is one of them. Nothing without an earlier list.
    public static func withdrawn(from earlier: [SecretVault.Entry]?, to later: [SecretVault.Entry]) -> [String] {
        guard let earlier else { return [] }
        var byID: [String: SecretVault.Entry] = [:]
        for entry in later { byID[entry.id] = entry }
        var names: [String] = []
        for entry in earlier {
            let holds: Bool = byID[entry.id].map { (key: SecretVault.Entry) -> Bool in
                key.name == entry.name && key.lastSet <= entry.lastSet
            } ?? false
            if !holds { names.append(entry.name) }
        }
        return names
    }
}
