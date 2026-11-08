import Foundation

// Which "How long" choices the approval panel offers before stored keys are used. A key set to "Ask for Touch ID every
// time it's used" (the default, and how a key saved before that box reads) is used once per approval: while any key a
// request names asks every time, the panel offers Allow once and the time-bound choices (this session, this folder or
// worktree until Next Term quits), which Touch ID confirms once and which then hold for that one command alone; a grant
// in force that held the key before it asked ends.

/// How long an approval lasts, as the panel's Remember offers it. The Always choices outlast Next Term, kept in
/// their own sealed file (SecretAlwaysFile). The others live in memory alone and end when Next Term quits at the latest:
/// "In this worktree until Next Term quits" and "In this folder until Next Term quits" among them.
public enum SecretApprovalChoice: String, CaseIterable, Hashable, Sendable {
    case once, fifteenMinutes, untilLock, session
    case worktreeUntilQuit, folderUntilQuit
    case alwaysProject, alwaysWorktree, alwaysFolder

    /// The audit log's word for it.
    public var approval: SecretAudit.Approval {
        switch self {
        case .once: return .once
        case .fifteenMinutes: return .fifteenMinutes
        case .untilLock: return .untilLock
        case .session: return .session
        case .worktreeUntilQuit: return .worktreeUntilQuit
        case .folderUntilQuit: return .folderUntilQuit
        case .alwaysProject, .alwaysWorktree, .alwaysFolder: return .always
        }
    }

    /// The grant it makes while Next Term runs, in memory alone: none for Allow once, nor for an Always choice, whose
    /// grant is kept.
    public var grantKind: SecretGrant.Kind? {
        switch self {
        case .once, .alwaysProject, .alwaysWorktree, .alwaysFolder: return nil
        case .fifteenMinutes: return .fifteenMinutes
        case .untilLock: return .untilLock
        case .session: return .session
        case .worktreeUntilQuit: return .worktree
        case .folderUntilQuit: return .folder
        }
    }

    /// Where an Always choice holds; nil for the others.
    public var scope: SecretAlwaysScope.Kind? {
        switch self {
        case .alwaysProject: return .project
        case .alwaysWorktree: return .worktree
        case .alwaysFolder: return .folder
        case .once, .fifteenMinutes, .untilLock, .session, .worktreeUntilQuit, .folderUntilQuit: return nil
        }
    }

    public var isAlways: Bool { scope != nil }

    /// Where a choice until Next Term quits holds: the linked worktree or the folder; nil for the others.
    public var untilQuit: SecretAlwaysScope.Kind? {
        switch self {
        case .worktreeUntilQuit: return .worktree
        case .folderUntilQuit: return .folder
        default: return nil
        }
    }

    /// The choice until Next Term quits for `kind` (a project has none: that place is Always's alone).
    public static func untilQuit(_ kind: SecretAlwaysScope.Kind) -> SecretApprovalChoice? {
        switch kind {
        case .worktree: return .worktreeUntilQuit
        case .folder: return .folderUntilQuit
        case .project: return nil
        }
    }

    /// The time-bound choices: this session, and a worktree or folder until Next Term quits. Each binds the exact
    /// command (or hub server), and is offered for a key that asks every time, which Touch ID confirms once.
    public var isTimeBound: Bool { self == .session || untilQuit != nil }

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
    /// The choices offered, in the panel's order: Allow once, the time-bound ones, then Always. Allow once always; Allow
    /// for 15 minutes for a request made on this Mac; Allow this command until the Mac locks for `nxtrm secret run`'s
    /// (`isWrapper`). Only Allow once for a remote connection.
    ///
    /// The time-bound choices: For this session, for an agent's session Next Term can follow (`hasSession`: its run in a
    /// tab, or outside the tabs the requesting agent process by its pid, start time and executable); then, for an agent in
    /// one of Next Term's own tabs whose program Next Term can tell, the places `untilQuit` names (a linked worktree, the
    /// folder) until Next Term quits. Outside the tabs (`outsideTabs`) the requester names its own folder, and a command
    /// Next Term warns about (`warned`, npx -y and the like) runs other code another time, so both get For this session
    /// alone. While any key the request names asks every time (`asksEveryUse`) the time-bound choices stay, which Touch ID
    /// confirms once, and 15 minutes and until lock go.
    ///
    /// After them, the Always choices for the places `always` names (the project, the worktree, the folder): only for an
    /// agent in one of Next Term's own tabs whose request may be kept (SecretAlwaysRules), which the caller decides. A key
    /// that asks every time gets them too: for that one command or server it then asks once per launch, and the panel
    /// says so. Never for a remote connection.
    public static func offered(isWrapper: Bool, isRemote: Bool, asksEveryUse: Bool, hasSession: Bool = false,
                               outsideTabs: Bool = false, warned: Bool = false, untilQuit: [SecretAlwaysScope.Kind] = [],
                               always: [SecretAlwaysScope.Kind] = []) -> [SecretApprovalChoice] {
        guard !isRemote else { return [.once] }
        let places: [SecretApprovalChoice] = always.map(SecretApprovalChoice.always)
        var timeBound: [SecretApprovalChoice] = hasSession ? [.session] : []
        if !outsideTabs, !warned {
            for kind in [SecretAlwaysScope.Kind.worktree, .folder] where untilQuit.contains(kind) {
                if let choice = SecretApprovalChoice.untilQuit(kind) { timeBound.append(choice) }
            }
        }
        guard !asksEveryUse else { return [.once] + timeBound + places }
        return (isWrapper ? [.once, .fifteenMinutes, .untilLock] : [.once, .fifteenMinutes]) + timeBound + places
    }

    /// The choice an Allow keeps once it knows the place (`scope`, as it is now) and the agent program (`agent`): a worktree
    /// or folder choice with either missing (the folder gone since the panel showed, the program no longer told) holds
    /// nothing, so it is Allow once, and the answer says so rather than claiming a grant that was never made.
    public static func holding(_ choice: SecretApprovalChoice, scope: SecretAlwaysScope?, agent: SecretAgentIdentity?) -> SecretApprovalChoice {
        guard let place = choice.untilQuit else { return choice }
        guard let scope, scope.kind == place, agent != nil else { return .once }
        return choice
    }

    /// The grant an Allow makes: the choice's own, or for Allow once whose wrapper stopped waiting (`wrapperGone`), one use
    /// held 2 minutes for its restart. A remembered choice holds for its whole time, gone or not: no 2-minute race.
    public static func grantKind(for choice: SecretApprovalChoice, wrapperGone: Bool) -> SecretGrant.Kind? {
        if choice == .once { return wrapperGone ? .oneUse : nil }
        return choice.grantKind
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

    /// The approval a use's audit line records: 15 minutes or until lock only while every key it names lets approvals
    /// last in `index`, the vault the use unlocked; else Allow once, as `kept` keeps after Touch ID. A key's box ticked in
    /// another copy of Next Term during Touch ID makes no grant, so the line says Allow once. The time-bound choices are
    /// offered for a key that asks every time, which this Touch ID confirms, so they are recorded as they are.
    public static func recorded(_ approval: SecretAudit.Approval?, names: [String],
                                in index: SecretVault.Index?) -> SecretAudit.Approval? {
        guard approval == .fifteenMinutes || approval == .untilLock else { return approval }
        return askingEveryUse(names, in: index).isEmpty ? approval : .once
    }

    /// The keys the lasting grants in force hold that ask every time now, sorted: the grants holding each end
    /// (`SecretGrantEvent.askEveryUse`). A key ticked here or by another copy of Next Term, or gone from the vault. A
    /// one-use grant is Allow once's own use, kept for a wrapper that left during Touch ID, so it is not counted; nor is a
    /// key a time-bound grant was made for while it asked every time (`SecretGrant.everyUse`), which Touch ID confirmed.
    public static func askingNames(heldBy grants: [SecretGrant], in index: SecretVault.Index?) -> [String] {
        let lasting: [SecretGrant] = grants.filter { (grant: SecretGrant) -> Bool in grant.kind != .oneUse }
        var held: Set<String> = []
        for grant in lasting { held.formUnion(grant.names.filter { !grant.everyUse.contains($0) }) }
        // A key gone from the vault ends its grants by its change (`SecretGrantEvent.keyChanged`).
        return askingEveryUse(held.sorted(), in: index)
    }
}
