import Foundation

// Which "How long" choices the approval panel offers before stored keys are used. A key set to "Ask for Touch ID every
// time it's used" (the default, and how a key saved before that box reads) is used once per approval: while any key a
// request names asks every time, the panel offers only Allow once, and a grant in force that holds the key ends.

/// How long an approval lasts, as the panel's Remember offers it. The Always choices outlast Next Term, kept in
/// their own sealed file (SecretAlwaysFile).
public enum SecretApprovalChoice: String, CaseIterable, Hashable, Sendable {
    case once, fifteenMinutes, untilLock, session
    case alwaysProject, alwaysWorktree, alwaysFolder

    /// The audit log's word for it.
    public var approval: SecretAudit.Approval {
        switch self {
        case .once: return .once
        case .fifteenMinutes: return .fifteenMinutes
        case .untilLock: return .untilLock
        case .session: return .session
        case .alwaysProject, .alwaysWorktree, .alwaysFolder: return .always
        }
    }

    /// The grant it makes while Next Term runs: none for Allow once, nor for an Always choice, whose grant is kept.
    public var grantKind: SecretGrant.Kind? {
        switch self {
        case .once, .alwaysProject, .alwaysWorktree, .alwaysFolder: return nil
        case .fifteenMinutes: return .fifteenMinutes
        case .untilLock: return .untilLock
        case .session: return .session
        }
    }

    /// Where an Always choice holds; nil for the others.
    public var scope: SecretAlwaysScope.Kind? {
        switch self {
        case .alwaysProject: return .project
        case .alwaysWorktree: return .worktree
        case .alwaysFolder: return .folder
        case .once, .fifteenMinutes, .untilLock, .session: return nil
        }
    }

    public var isAlways: Bool { scope != nil }

    /// The Always choice for `kind`.
    public static func always(_ kind: SecretAlwaysScope.Kind) -> SecretApprovalChoice {
        switch kind {
        case .project: return .alwaysProject
        case .worktree: return .alwaysWorktree
        case .folder: return .alwaysFolder
        }
    }
}

public enum SecretApprovalChoices {
    /// The choices offered, in the panel's order. Allow once always; Allow for 15 minutes for a request made on this
    /// Mac; Allow for this session for an agent's session Next Term can follow (`hasSession`); Allow this command until
    /// the Mac locks for `nxtrm secret run`'s (`isWrapper`). Only Allow once for a remote connection, and while any key
    /// the request names asks every time (`asksEveryUse`).
    ///
    /// After them, the Always choices for the places `always` names (the project, the worktree, the folder): only for an
    /// agent in one of Next Term's own tabs whose request may be kept (SecretAlwaysRules), which the caller decides. A key
    /// that asks every time gets them too: for that one command or server it then asks once per launch, and the panel
    /// says so. Never for a remote connection.
    public static func offered(isWrapper: Bool, isRemote: Bool, asksEveryUse: Bool, hasSession: Bool = false,
                               always: [SecretAlwaysScope.Kind] = []) -> [SecretApprovalChoice] {
        guard !isRemote else { return [.once] }
        let places: [SecretApprovalChoice] = always.map(SecretApprovalChoice.always)
        guard !asksEveryUse else { return [.once] + places }
        // Allow for this session when the request comes from an agent's session Next Term can follow to its end: the
        // widest of those that end, so after them.
        let session: [SecretApprovalChoice] = hasSession ? [.session] : []
        return (isWrapper ? [.once, .fifteenMinutes, .untilLock] : [.once, .fifteenMinutes]) + session + places
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

    /// The approval a use's audit line records: a lasting one (15 minutes, until lock) only while every key it names
    /// lets approvals last in `index`, the vault the use unlocked; else Allow once, as `kept` keeps after Touch ID. A
    /// key's box ticked in another copy of Next Term during Touch ID makes no grant, so the line says Allow once.
    public static func recorded(_ approval: SecretAudit.Approval?, names: [String],
                                in index: SecretVault.Index?) -> SecretAudit.Approval? {
        guard approval == .fifteenMinutes || approval == .untilLock || approval == .session else { return approval }
        return askingEveryUse(names, in: index).isEmpty ? approval : .once
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
