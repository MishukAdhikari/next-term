import Foundation

// Which "How long" choices the approval panel offers before stored keys are used. A key set to "Ask for Touch ID every
// time it's used" (the default, and how a key saved before that box reads) is used once per approval: while any key a
// request names asks every time, the panel offers only Allow once, and a grant in force that holds the key ends.

/// How long an approval lasts, as the panel's "How long" offers it.
public enum SecretApprovalChoice: String, CaseIterable, Hashable, Sendable {
    case once, fifteenMinutes, untilLock

    /// The audit log's word for it.
    public var approval: SecretAudit.Approval {
        switch self {
        case .once: return .once
        case .fifteenMinutes: return .fifteenMinutes
        case .untilLock: return .untilLock
        }
    }

    /// The grant it makes: none for Allow once.
    public var grantKind: SecretGrant.Kind? {
        switch self {
        case .once: return nil
        case .fifteenMinutes: return .fifteenMinutes
        case .untilLock: return .untilLock
        }
    }
}

public enum SecretApprovalChoices {
    /// The choices offered, in the panel's order. Allow once always; Allow for 15 minutes for a request made on this
    /// Mac; Allow this command until the Mac locks for `nxtrm secret run`'s (`isWrapper`). Only Allow once for a remote
    /// connection, and while any key the request names asks every time (`asksEveryUse`).
    public static func offered(isWrapper: Bool, isRemote: Bool, asksEveryUse: Bool) -> [SecretApprovalChoice] {
        guard !isRemote, !asksEveryUse else { return [.once] }
        return isWrapper ? [.once, .fifteenMinutes, .untilLock] : [.once, .fifteenMinutes]
    }

    /// The keys among `names` that ask every time, in their order: each one `index` says so of (a key saved before
    /// the box among them), and each name it doesn't hold, or every name with no index, since a key not found is never
    /// trusted with a lasting approval.
    public static func askingEveryUse(_ names: [String], in index: SecretVault.Index?) -> [String] {
        names.filter { (name: String) -> Bool in index?.entry(named: name)?.asksEveryUse ?? true }
    }

    /// The choice an Allow keeps: the one chosen while it is still offered, else Allow once. A key's box ticked while
    /// the panel was up takes the lasting choices away.
    public static func kept(_ chosen: SecretApprovalChoice, offered: [SecretApprovalChoice]) -> SecretApprovalChoice {
        offered.contains(chosen) ? chosen : .once
    }

    /// The keys the lasting grants in force hold that ask every time now, sorted: the grants holding each end
    /// (`SecretGrantEvent.askEveryUse`). A key ticked here or by another copy of Next Term, or gone from the vault. A
    /// one-use grant is Allow once's own use, kept for a wrapper that left during Touch ID, so it is not counted.
    public static func askingNames(heldBy grants: [SecretGrant], in index: SecretVault.Index?) -> [String] {
        let lasting: [SecretGrant] = grants.filter { (grant: SecretGrant) -> Bool in grant.kind != .oneUse }
        let held: Set<String> = Set(lasting.flatMap(\.names))
        return askingEveryUse(held.sorted(), in: index)
    }
}
