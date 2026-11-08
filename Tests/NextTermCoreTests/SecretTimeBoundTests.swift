import Foundation
import Testing
@testable import NextTermCore

/// The time-bound approvals: For this session (inside a tab, or outside the tabs the agent process by pid, start time and
/// executable), In this worktree until Next Term quits and In this folder until Next Term quits. Which are offered, what
/// each matches, what ends each, and that none is kept on disk. Every value and path is made up, or a folder of the test's own.
@Suite struct SecretTimeBoundOfferTests {
    /// The owner's case: Codex outside Next Term's tabs, a wrapper running `npx -y mcp-remote …` (warned), a key that asks
    /// every time, in a linked worktree. For this session is offered beside Only this time; the folder and worktree are
    /// not, as the requester names its own folder there.
    @Test func outsideTheTabsOnlyForThisSessionIsOffered() {
        let owner = SecretApprovalChoices.offered(isWrapper: true, isRemote: false, asksEveryUse: true, hasSession: true, outsideTabs: true,
                                                  warned: true, untilQuit: [.worktree, .folder])
        #expect(owner == [.once, .session])
        let plain = SecretApprovalChoices.offered(isWrapper: true, isRemote: false, asksEveryUse: false, hasSession: true, outsideTabs: true,
                                                  untilQuit: [.worktree, .folder])
        #expect(plain == [.once, .fifteenMinutes, .untilLock, .session])
    }

    /// In a tab, all three: the session, the worktree, the folder, in that order, before Always.
    @Test func inATabTheSessionTheWorktreeAndTheFolder() {
        let offered = SecretApprovalChoices.offered(isWrapper: true, isRemote: false, asksEveryUse: false, hasSession: true,
                                                    untilQuit: [.folder, .worktree], always: [.project, .worktree, .folder])
        #expect(offered == [.once, .fifteenMinutes, .untilLock, .session, .worktreeUntilQuit, .folderUntilQuit,
                            .alwaysProject, .alwaysWorktree, .alwaysFolder])
        // Outside a linked worktree: the folder alone. A project is never a place until quit.
        let folder = SecretApprovalChoices.offered(isWrapper: false, isRemote: false, asksEveryUse: false, hasSession: true,
                                                   untilQuit: [.project, .folder])
        #expect(folder == [.once, .fifteenMinutes, .session, .folderUntilQuit])
    }

    /// A key that asks every time: the time-bound choices stay (Touch ID confirms them once); 15 minutes and until lock go.
    @Test func aKeyThatAsksEveryTimeKeepsTheTimeBoundChoices() {
        let offered = SecretApprovalChoices.offered(isWrapper: true, isRemote: false, asksEveryUse: true, hasSession: true,
                                                    untilQuit: [.worktree, .folder], always: [.folder])
        #expect(offered == [.once, .session, .worktreeUntilQuit, .folderUntilQuit, .alwaysFolder])
        // With no session to follow and no place, still only Allow once.
        #expect(SecretApprovalChoices.offered(isWrapper: true, isRemote: false, asksEveryUse: true) == [.once])
    }

    /// A command Next Term warns about (npx -y): only For this session, of the time-bound ones; the warning stays.
    @Test func aWarnedCommandGetsOnlyForThisSession() {
        let offered = SecretApprovalChoices.offered(isWrapper: true, isRemote: false, asksEveryUse: false, hasSession: true, warned: true,
                                                    untilQuit: [.worktree, .folder])
        #expect(offered == [.once, .fifteenMinutes, .untilLock, .session])
        let every = SecretApprovalChoices.offered(isWrapper: true, isRemote: false, asksEveryUse: true, hasSession: true, warned: true,
                                                  untilQuit: [.worktree, .folder])
        #expect(every == [.once, .session])
    }

    /// A remote connection keeps Only this time, whatever else is true.
    @Test func aRemoteConnectionKeepsOnlyThisTime() {
        for asks in [false, true] {
            let offered = SecretApprovalChoices.offered(isWrapper: true, isRemote: true, asksEveryUse: asks, hasSession: true,
                                                        untilQuit: [.worktree, .folder], always: [.folder])
            #expect(offered == [.once])
        }
    }

    /// Nothing time-bound is kept on disk: none is an Always choice (whose grant goes in always.json); each makes a grant
    /// in memory, which a quit ends.
    @Test func noTimeBoundChoiceIsKept() {
        for choice in [SecretApprovalChoice.session, .worktreeUntilQuit, .folderUntilQuit] {
            #expect(choice.isTimeBound && !choice.isAlways && choice.scope == nil)
            #expect(choice.grantKind != nil)
            let grant = SecretGrant(kind: choice.grantKind!, binding: placedBinding(), made: .now, session: "pid:9:1.0")
            #expect(grant.ended(by: .quit))
        }
        #expect(SecretApprovalChoice.worktreeUntilQuit.untilQuit == .worktree && SecretApprovalChoice.folderUntilQuit.untilQuit == .folder)
        #expect(SecretApprovalChoice.worktreeUntilQuit.approval == .worktreeUntilQuit)
        #expect(SecretApprovalChoice.folderUntilQuit.approval == .folderUntilQuit)
        #expect(SecretApprovalChoice.untilQuit(.project) == nil)
        #expect(!SecretApprovalChoice.fifteenMinutes.isTimeBound && !SecretApprovalChoice.alwaysFolder.isTimeBound)
    }

    /// The places offered until quit: the linked worktree when in one, and the folder unless it is that worktree's root.
    @Test func thePlacesOfferedUntilQuit() {
        #expect(SecretPlaces(folder: "/w/app/src", project: "/w/app").untilQuitScopes == [.folder])
        #expect(SecretPlaces(folder: "/w/app-wt/src", project: "/w/app", worktree: "/w/app-wt").untilQuitScopes == [.worktree, .folder])
        #expect(SecretPlaces(folder: "/w/app-wt", project: "/w/app", worktree: "/w/app-wt").untilQuitScopes == [.worktree])
    }
}

/// A late approval: the MCP server stopped waiting. Only this time holds one use for 2 minutes; a remembered choice holds
/// for its whole time.
@Suite struct SecretLateApprovalTests {
    @Test func onlyThisTimeHoldsTwoMinutesARememberedChoiceItsWholeTime() {
        #expect(SecretApprovalChoices.grantKind(for: .once, wrapperGone: true) == .oneUse)
        #expect(SecretApprovalChoices.grantKind(for: .once, wrapperGone: false) == nil)
        for choice in [SecretApprovalChoice.session, .worktreeUntilQuit, .folderUntilQuit, .fifteenMinutes, .untilLock] {
            #expect(SecretApprovalChoices.grantKind(for: choice, wrapperGone: true) == choice.grantKind)
        }
        let start = ContinuousClock.now
        let oneUse = SecretGrant(kind: .oneUse, binding: placedBinding(), made: start)
        #expect(oneUse.isExpired(at: start.advanced(by: .seconds(121))))
        let session = SecretGrant(kind: .session, binding: placedBinding(), made: start, session: "pid:9:1.0", wide: false)
        #expect(session.matches(placedBinding(), session: "pid:9:1.0", at: start.advanced(by: .seconds(3 * 3600))))
        #expect(session.expires == nil)
    }
}

/// A folder of the test's own, with a linked-worktree-shaped layout: <base>/app-wt/src and a sibling <base>/app-wt-evil.
private struct Places {
    let base: String
    let worktree: String
    let src: String
    let evil: String

    init() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("nt-timebound-\(UUID().uuidString)").path
        for folder in [made + "/app-wt/src", made + "/app-wt-evil"] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        base = canonicalPath(made) // /var/folders is /private/var/folders
        worktree = base + "/app-wt"
        src = worktree + "/src"
        evil = base + "/app-wt-evil"
    }

    func remove() { try? FileManager.default.removeItem(atPath: base) }
}

private let codex = SecretAgentIdentity(path: "/opt/codex/bin/codex", stamp: SecretFileStamp(device: 1, inode: 7, size: 70, modified: 1, changed: 2),
                                        team: "TEAM123")

private func placedBinding(folder: String = "/w/app", source: SecretBinding.Source = .wrapper, asker: String = "wrapper:/opt/codex:ab",
                           command: [String] = ["mcp-server", "--stdio"], keys: [String: String] = ["PE_TOKEN": "PE_TOKEN"]) -> SecretBinding {
    SecretBinding(source: source, asker: asker, program: "codex", agentPath: "/opt/codex/bin/codex", command: command, keys: keys,
                  folder: folder, target: source == .tool ? "new" : nil)
}

@Suite struct SecretPlacedGrantTests {
    let start = ContinuousClock.now

    @Test func aFolderGrantAnswersTheSameCommandInThatFolderOnly() throws {
        let places = try Places()
        defer { places.remove() }
        let scope = try #require(SecretAlwaysScope.at(places.src, kind: .folder))
        let grant = SecretGrant(kind: .folder, binding: placedBinding(folder: places.src), made: start, scope: scope, agent: codex)
        #expect(grant.matches(placedBinding(folder: places.src), agent: codex, at: start))
        // A day later: no end of its own.
        #expect(grant.matches(placedBinding(folder: places.src), agent: codex, at: start.advanced(by: .seconds(86_400))))
        #expect(!grant.matches(placedBinding(folder: places.worktree), agent: codex, at: start), "the folder above")
        #expect(!grant.matches(placedBinding(folder: places.evil), agent: codex, at: start), "another folder")
        #expect(!grant.matches(placedBinding(folder: places.src, command: ["mcp-server", "--http"]), agent: codex, at: start), "another command")
        #expect(!grant.matches(placedBinding(folder: places.src, keys: ["PE_TOKEN": "OTHER"]), agent: codex, at: start), "another ENVNAME")
        #expect(!grant.matches(placedBinding(folder: places.src), agent: nil, at: start), "no agent program known")
        var other = codex
        other.stamp = SecretFileStamp(device: 1, inode: 7, size: 71, modified: 1, changed: 3)
        #expect(!grant.matches(placedBinding(folder: places.src), agent: other, at: start), "the agent updated")
        // The folder deleted and made again under its path: another inode.
        #expect(!grant.matches(placedBinding(folder: places.src), agent: codex, at: start, identify: { _ in (scope.device, scope.inode + 1) }))
    }

    @Test func aWorktreeGrantAnswersAnywhereInsideByWholeComponents() throws {
        let places = try Places()
        defer { places.remove() }
        let scope = try #require(SecretAlwaysScope.at(places.worktree, kind: .worktree))
        let grant = SecretGrant(kind: .worktree, binding: placedBinding(folder: places.worktree), made: start, scope: scope, agent: codex)
        #expect(grant.matches(placedBinding(folder: places.worktree), agent: codex, at: start))
        #expect(grant.matches(placedBinding(folder: places.src), agent: codex, at: start), "a folder inside it")
        #expect(!grant.matches(placedBinding(folder: places.evil), agent: codex, at: start), "a sibling sharing its name's start")
        #expect(!grant.matches(placedBinding(folder: places.base), agent: codex, at: start), "the folder above")
    }

    /// run_with_secrets from another tab of the same agent program, in the same folder: the asking tab is not part of it.
    @Test func aToolGrantIsNotBoundToItsAskingTab() throws {
        let places = try Places()
        defer { places.remove() }
        let scope = try #require(SecretAlwaysScope.at(places.src, kind: .folder))
        let grant = SecretGrant(kind: .folder, binding: placedBinding(folder: places.src, source: .tool, asker: "tab-1"), made: start,
                                scope: scope, agent: codex)
        #expect(grant.matches(placedBinding(folder: places.src, source: .tool, asker: "tab-2"), agent: codex, at: start))
        // A wrapper's asker carries its agent and argv, so it stays.
        let wrapper = SecretGrant(kind: .folder, binding: placedBinding(folder: places.src), made: start, scope: scope, agent: codex)
        #expect(!wrapper.matches(placedBinding(folder: places.src, asker: "wrapper:/opt/claude:cd"), agent: codex, at: start))
    }

    /// What ends a worktree or folder grant: quit, Revoke All, Start Over, a key change, the hour's pause, its revoke. A
    /// lock, a sleep and a switch of users don't; nor a session's end.
    @Test func whatEndsAPlacedGrant() throws {
        let places = try Places()
        defer { places.remove() }
        for kind in [SecretGrant.Kind.worktree, .folder] {
            let scope = try #require(SecretAlwaysScope.at(places.worktree, kind: kind == .worktree ? .worktree : .folder))
            let grant = SecretGrant(kind: kind, binding: placedBinding(folder: places.worktree), made: start, id: "g", scope: scope, agent: codex)
            for event in [SecretGrantEvent.quit, .revokeAll, .startedOver, .keyChanged("PE_TOKEN"), .hourPause, .revoke("g")] {
                #expect(grant.ended(by: event), "\(kind) \(event)")
            }
            for event in [SecretGrantEvent.screenLocked, .systemSleep, .sessionResigned, .displaySleep, .sessionEnded("pid:9:1.0"),
                          .keyChanged("OTHER"), .revoke("h")] {
                #expect(!grant.ended(by: event), "\(kind) \(event)")
            }
            #expect(grant.session == nil && grant.expires == nil)
        }
    }

    /// The scope and agent are a placed grant's alone: another kind keeps neither.
    @Test func onlyAPlacedGrantKeepsAPlace() throws {
        let places = try Places()
        defer { places.remove() }
        let scope = try #require(SecretAlwaysScope.at(places.src, kind: .folder))
        let grant = SecretGrant(kind: .fifteenMinutes, binding: placedBinding(), made: start, scope: scope, agent: codex)
        #expect(grant.scope == nil && grant.agent == nil && !grant.wide)
    }
}

@Suite struct SecretTimeBoundSessionTests {
    let start = ContinuousClock.now

    /// Outside the tabs, or for a key that asks every time: the same request again, of the same session, and only that.
    @Test func anExactSessionGrantAnswersOnlyTheSameRequest() {
        let session = "pid:4242:1700000000.5|exe:4242:abc"
        let warned = placedBinding(command: ["npx", "-y", "mcp-remote", "https://mcp.example.com/mcp"])
        var binding = warned
        binding.warned = ["NODE_OPTIONS": "d1"]
        let grant = SecretGrant(kind: .session, binding: binding, made: start, session: session, wide: false)
        // Warnings and all, as the panel showed them.
        #expect(grant.matches(binding, session: session, plain: false, at: start))
        #expect(!grant.matches(binding, session: "pid:4242:1700000001.5|exe:4242:abc", plain: false, at: start), "a reused pid")
        #expect(!grant.matches(binding, session: nil, plain: false, at: start))
        var other = binding
        other.command = ["npx", "-y", "mcp-remote", "https://evil.example.com/mcp"]
        #expect(!grant.matches(other, session: session, plain: true, at: start), "another command, even plain")
        // Through a lock and a sleep; ended by its session's end.
        #expect(!grant.ended(by: .screenLocked) && !grant.ended(by: .systemSleep))
        #expect(grant.ended(by: .sessionEnded(session)) && grant.ended(by: .quit))
    }

    /// A tab's session, as today: any plain command of the session; and now the warned request it was made for too.
    @Test func aWideSessionGrantAlsoAnswersItsOwnWarnedRequest() {
        let session = "tab:T:1|pid:9:1.0"
        var shown = SecretBinding(source: .wrapper, asker: "wrapper:/opt/codex:ab", program: "codex", agentPath: "/opt/codex/bin/codex",
                                  command: ["npx", "-y", "pkg"], keys: ["GITHUB_TOKEN": "GITHUB_TOKEN"], folder: "/w/app")
        shown.warned = ["NODE_OPTIONS": "d1"]
        let grant = SecretGrant(kind: .session, binding: shown, made: start, session: session)
        #expect(grant.wide)
        #expect(grant.matches(shown, session: session, plain: false, at: start))
        var plain = shown
        plain.command = ["gh", "api", "user"]
        plain.asker = "wrapper:/opt/codex:cd"
        plain.warned = [:]
        #expect(grant.matches(plain, session: session, plain: true, at: start))
        var otherWarned = plain
        otherWarned.command = ["npx", "-y", "other"]
        #expect(!grant.matches(otherWarned, session: session, plain: false, at: start), "another warned command still asks")
    }

    /// A key that asked every time when the grant was made: Touch ID confirmed it, so its asking doesn't end the grant.
    /// One ticked since does.
    @Test func everyUseKeysConfirmedByTouchIDKeepTheGrant() throws {
        let index = try SecretApprovalChoicesTests.index()
        let confirmed = SecretGrant(kind: .session, binding: placedBinding(keys: ["ASKS_KEY": "ASKS_KEY"]), made: start, session: "pid:9:1.0",
                                    wide: false, everyUse: ["ASKS_KEY", "NOT_HELD"])
        #expect(confirmed.everyUse == ["ASKS_KEY"])
        #expect(!confirmed.ended(by: .askEveryUse("ASKS_KEY")))
        #expect(SecretApprovalChoices.askingNames(heldBy: [confirmed], in: index).isEmpty)
        let before = SecretGrant(kind: .folder, binding: placedBinding(keys: ["ASKS_KEY": "ASKS_KEY"]), made: start)
        #expect(before.ended(by: .askEveryUse("ASKS_KEY")))
        #expect(SecretApprovalChoices.askingNames(heldBy: [confirmed, before], in: index) == ["ASKS_KEY"])
        // Still ends with the key's change, and a one-use grant records none.
        #expect(confirmed.ended(by: .keyChanged("ASKS_KEY")))
        #expect(SecretGrant(kind: .oneUse, binding: placedBinding(), made: start, everyUse: ["PE_TOKEN"]).everyUse.isEmpty)
    }
}

/// An agent outside Next Term's tabs: its session is its process by pid, start time and executable.
@Suite struct SecretOutsideSessionTests {
    @Test func theSessionNamesThePidItsStartAndItsExecutable() throws {
        let session = try #require(SecretSessions.outside(pid: 4242, started: 1_700_000_000.25, executable: "/opt/codex/bin/codex"))
        #expect(session.hasPrefix("pid:4242:1700000000.25|exe:4242:"))
        #expect(SecretSessions.isOutsideTabs(session))
        #expect(!SecretSessions.isOutsideTabs("tab:T:1|pid:9:1.0"))
        #expect(SecretSessions.outside(pid: 1, started: 1, executable: "/bin/x") == nil)
        #expect(SecretSessions.outside(pid: 4242, started: nil, executable: "/bin/x") == nil)
        #expect(SecretSessions.outside(pid: 4242, started: 1, executable: nil) == nil)
        #expect(SecretSessions.outside(pid: 4242, started: 1, executable: "relative") == nil)
    }

    @Test func itIsLiveOnlyWhileThatSameProcessRunsTheSameProgram() throws {
        let session = try #require(SecretSessions.outside(pid: 4242, started: 1_700_000_000.25, executable: "/opt/codex/bin/codex"))
        let noTab: (String) -> String? = { _ in nil }
        #expect(SecretSessions.isLive(session, process: { _ in (1_700_000_000.25, "/opt/codex/bin/codex") }, tab: noTab))
        #expect(!SecretSessions.isLive(session, process: { _ in nil }, tab: noTab), "exited")
        #expect(!SecretSessions.isLive(session, process: { _ in (1_700_000_100.0, "/opt/codex/bin/codex") }, tab: noTab), "a reused pid")
        #expect(!SecretSessions.isLive(session, process: { _ in (1_700_000_000.25, "/usr/bin/python3") }, tab: noTab), "exec'd another program")
        #expect(!SecretSessions.isLive(session, process: { _ in (1_700_000_000.25, nil) }, tab: noTab), "its program unreadable")
    }

    /// A tab's session as before: its run in its tab and its process.
    @Test func aTabSessionChecksItsRunAndItsProcess() {
        let session = "tab:T-1:3|" + SecretSessions.process(pid: 9, started: 1.5)
        #expect(SecretSessions.isLive(session, process: { _ in (1.5, nil) }, tab: { $0 == "T-1" ? "tab:T-1:3" : nil }))
        #expect(!SecretSessions.isLive(session, process: { _ in (1.5, nil) }, tab: { _ in "tab:T-1:4" }), "another run in the tab")
        #expect(!SecretSessions.isLive("", process: { _ in (1.5, nil) }, tab: { _ in nil }))
        #expect(!SecretSessions.isLive("odd:1:2", process: { _ in (1.5, nil) }, tab: { _ in nil }))
    }
}
