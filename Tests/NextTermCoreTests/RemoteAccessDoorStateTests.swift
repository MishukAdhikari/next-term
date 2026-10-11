import Foundation
import Testing
@testable import NextTermCore

/// The door's state: the OAuth authority, the grant store, the audit log and the refusal counts under one lock, as
/// the door uses them. New tokens and new options are saved before they apply; a failed save answers
/// `server_error` or changes nothing; a revoke reaches the open calls at once and the file as soon as it can be
/// written; a `tools/list` reads the options and clears the list-changed mark in one step; calls past a grant's
/// limits are summed in one line a minute. Every clock and the randomness are injected.
@Suite struct RemoteAccessDoorStateTests {
    typealias OAuth = RemoteAccessOAuth
    typealias Flow = RemoteAccessOAuthTests
    typealias Files = RemoteAccessStoreTests
    typealias Entry = RemoteAccessAuditEntry

    static let host = Flow.host

    /// A state on its own folder, with its clock and seeded randomness.
    struct Door {
        let folder = Files.Folder()
        let clock = RemoteAccessCallsTests.Clock()
        let state: RemoteAccessDoorState

        init(host: String? = RemoteAccessDoorStateTests.host, seed: UInt64 = 1) {
            let clock = self.clock
            let random = Flow.Seeded(seed)
            state = RemoteAccessDoorState(folder: folder.url, host: host,
                                          calls: RemoteAccessCalls(clock: { clock.now }),
                                          clock: { clock.now }, random: { random.bytes($0) }, report: { _ in })
        }

        /// The grants the file holds now, as a relaunch would read them.
        func saved() -> [OAuth.Grant] {
            var store = RemoteAccessGrantStore(folder: folder.url)
            return store.load(now: clock.now).grants
        }

        /// The audit lines written so far.
        func lines() -> [Entry] {
            state.flushAudit()
            var log = RemoteAccessAuditLog(folder: folder.url)
            return log.tail(now: clock.now)
        }
    }

    /// A grant paired through the door's routes, with its first tokens.
    struct Paired {
        var grant: OAuth.Grant
        var client: String
        var access: String
        var refresh: String
    }

    static func form(_ parameters: [String: String]) -> String {
        parameters.keys.sorted().map { OAuth.encode($0) + "=" + OAuth.encode(parameters[$0] ?? "") }
            .joined(separator: "&")
    }

    static func body(_ parameters: [String: String]) -> Data { Data(form(parameters).utf8) }

    /// Register, open pairing, authorize, type the code, approve, poll and exchange the code, as the door and the
    /// Mac do.
    static func pair(_ door: Door, options: RemoteAccessOptions = .readOnly) throws -> Paired {
        let state = door.state
        let registration = try #require(state.register(Flow.body(["redirect_uris": [Flow.claude]])))
        let client = try #require(Flow.json(registration.body)["client_id"] as? String)
        _ = state.update { authority, now in authority.openPairing(now: now) }
        let query = form(Flow.authorizeParameters(client: client))
        guard case .waiting(let request, let code)? = state.authorize(query) else {
            throw Flow.Failure("authorize did not wait")
        }
        guard case .request? = state.update({ authority, now in authority.match(code: code, now: now) }) else {
            throw Flow.Failure("no match")
        }
        let approved = try state.approve(request, name: "Claude, phone", options: options)
        let grant = try #require(try approved?.get())
        guard case .redirect(let link)? = state.poll("request=" + OAuth.encode(request)) else {
            throw Flow.Failure("no redirect")
        }
        var exchange: [String: String] = [:]
        exchange["grant_type"] = "authorization_code"
        exchange["code"] = Flow.items(link)["code"] ?? ""
        exchange["redirect_uri"] = Flow.claude
        exchange["client_id"] = client
        exchange["code_verifier"] = Flow.verifier
        exchange["resource"] = "https://\(host)/mcp"
        let answer = try #require(state.token(body(exchange)))
        let tokens = try #require(Flow.tokens(answer))
        return Paired(grant: grant, client: client, access: tokens.access, refresh: tokens.refresh)
    }

    static func refresh(_ door: Door, _ paired: Paired, with token: String? = nil) -> OAuth.Answer? {
        door.state.token(body(Flow.refreshParameters(token ?? paired.refresh, client: paired.client)))
    }

    /// Opens a call for the grant and runs the check just before it runs, as the door does on the main thread.
    static func running(_ door: Door, _ grant: String,
                        streamed: Bool = false) throws -> (id: RemoteAccessCalls.ID, answers: RemoteAccessCallsTests.Answers) {
        let answers = RemoteAccessCallsTests.Answers()
        let opened = door.state.calls.open(grant: grant, connection: 1, streamed: streamed) { answers.add($0) }
        guard case .call(let id, _) = opened else { throw Flow.Failure("no call") }
        guard case .run = door.state.begin(id, grant: grant) else { throw Flow.Failure("not run") }
        return (id, answers)
    }

    // MARK: no host

    /// Until a host is saved, the door answers 421 to everything: every route gives nil, and no token is valid.
    @Test func untilAHostIsSavedNothingIsAnswered() throws {
        let door = Door(host: nil)
        let state = door.state
        #expect(state.host == nil)
        #expect(state.validate(nil) == .missing)
        #expect(state.validate("ntat_x") == .invalid)
        #expect(state.register(Flow.body(["redirect_uris": [Flow.claude]])) == nil)
        #expect(state.protectedResourceMetadata() == nil)
        #expect(state.authorizationServerMetadata() == nil)
        #expect(state.wwwAuthenticate(tokenSent: false) == nil)
        #expect(state.update { _, _ in true } == nil)
        state.setHost("MCP.example.com")
        #expect(state.host == Self.host)
        #expect(state.protectedResourceMetadata() != nil)
    }

    // MARK: saved before they apply

    /// New tokens are saved before they go out: the file holds the new refresh token's hash when the client gets
    /// it, so a relaunch accepts it.
    @Test func newTokensAreSavedBeforeTheyGoOut() throws {
        let door = Door()
        let paired = try Self.pair(door)
        #expect(door.saved().first?.refreshHash == OAuth.hash(paired.refresh))
        guard case .valid(let grant) = door.state.validate(paired.access) else {
            Issue.record("the access token is not valid")
            return
        }
        #expect(grant.id == paired.grant.id)
        let refreshed = try #require(Self.refresh(door, paired))
        let next = try #require(Flow.tokens(refreshed))
        #expect(door.saved().first?.refreshHash == OAuth.hash(next.refresh))
    }

    /// A failed save during rotation answers 500 `server_error`; the new pair is never sent, and the old refresh
    /// token stays current, so the client's next try works once the disk does.
    @Test func aFailedSaveOfNewTokensAnswersServerErrorAndKeepsTheOldRefreshToken() throws {
        let door = Door()
        let paired = try Self.pair(door)
        let before = door.saved()

        Files.lock(door.folder.url)
        defer { Files.unlock(door.folder.url) }
        let failed = try #require(Self.refresh(door, paired))
        #expect(failed.status == 500)
        #expect(Flow.error(failed) == "server_error")
        #expect(Flow.tokens(failed) == nil)
        #expect(door.saved() == before)

        Files.unlock(door.folder.url)
        door.clock.advance(5)
        let retried = try #require(Self.refresh(door, paired))
        let tokens = try #require(Flow.tokens(retried))
        #expect(door.saved().first?.refreshHash == OAuth.hash(tokens.refresh))
        #expect(door.state.validate(tokens.access) != .invalid)
    }

    /// Allow saves the new grant before the browser can get its code. A failed save throws and changes nothing:
    /// no grant, the browser still waits, and Allow works again once the file can be written.
    @Test func aNewGrantIsSavedBeforeTheBrowserGetsItsCodeAndAFailedSaveChangesNothing() throws {
        let door = Door()
        let state = door.state
        let registration = try #require(state.register(Flow.body(["redirect_uris": [Flow.claude]])))
        let client = try #require(Flow.json(registration.body)["client_id"] as? String)
        _ = state.update { authority, now in authority.openPairing(now: now) }
        let query = Self.form(Flow.authorizeParameters(client: client))
        guard case .waiting(let request, let code)? = state.authorize(query),
              case .request? = state.update({ authority, now in authority.match(code: code, now: now) }) else {
            Issue.record("no request")
            return
        }
        let poll = "request=" + OAuth.encode(request)

        Files.lock(door.folder.url)
        #expect(throws: RemoteAccessStoreError.self) {
            try state.approve(request, name: "Claude, phone", options: .readOnly)
        }
        Files.unlock(door.folder.url)
        #expect(door.saved().isEmpty)
        #expect(state.update { authority, _ in authority.grants.isEmpty } == true)
        #expect(state.poll(poll) == .waiting(requestID: request, code: code))
        #expect(!door.lines().map(\.event).contains("pairing.approved"))

        let grant = try #require(try state.approve(request, name: "Claude, phone", options: .readOnly)?.get())
        #expect(door.saved().map(\.id) == [grant.id])
        guard case .redirect(let link)? = state.poll(poll) else {
            Issue.record("no redirect after the save")
            return
        }
        #expect(Flow.items(link)["code"] != nil)
        // A request that is gone is refused as before, and nothing is saved for it.
        guard case .failure(.pairingClosed)? = try state.approve(request, name: "Again", options: .readOnly) else {
            Issue.record("pairing closed after one success")
            return
        }
        #expect(door.saved().map(\.id) == [grant.id])
    }

    /// R60: new options are saved before they apply. A failed save throws and changes nothing: the grant keeps
    /// its options and no list-changed event is due. Once saved, the next stream carries the event.
    @Test func newOptionsAreSavedBeforeTheyApplyAndAFailedSaveChangesNothing() throws {
        let door = Door()
        let state = door.state
        let paired = try Self.pair(door)
        var fewer = RemoteAccessOptions.readOnly
        fewer[.tabs] = false

        Files.lock(door.folder.url)
        #expect(throws: RemoteAccessStoreError.self) { try state.changeOptions(of: paired.grant.id, to: fewer) }
        Files.unlock(door.folder.url)
        #expect(state.options(of: paired.grant.id, listed: false) == .readOnly)
        #expect(door.saved().first?.options == .readOnly)
        let quiet = state.calls.open(grant: paired.grant.id, connection: 1, streamed: true) { _ in }
        guard case .call(_, let unchanged) = quiet else { Issue.record("no call"); return }
        #expect(!unchanged)

        try state.changeOptions(of: paired.grant.id, to: fewer)
        #expect(door.saved().first?.options == fewer)
        #expect(state.options(of: paired.grant.id, listed: false) == fewer)
        let next = state.calls.open(grant: paired.grant.id, connection: 2, streamed: true) { _ in }
        guard case .call(_, let changed) = next else { Issue.record("no call"); return }
        #expect(changed)
        #expect(door.lines().map(\.event).contains("grant.options_changed"))
    }

    // MARK: revokes

    /// R38: Revoke on the Mac answers the grant's open calls at once, ends its tokens and reaches the file.
    @Test func aRevokeOnTheMacAnswersItsOpenCallsAndReachesTheFile() throws {
        let door = Door()
        let paired = try Self.pair(door)
        let call = try Self.running(door, paired.grant.id)
        try door.state.revoke(grant: paired.grant.id)
        #expect(call.answers.texts == [RemoteAccessText.turnedOff])
        #expect(door.state.validate(paired.access) == .invalid)
        #expect(door.saved().isEmpty)
        #expect(door.lines().contains { $0.event == "grant.revoked" && $0.reason == "on_mac" })
    }

    /// A revoke whose save fails still ends the grant at once, and says so. The next tick saves it, so the grant
    /// does not come back after a relaunch.
    @Test func aRevokeWhoseSaveFailedIsSavedAtTheNextTick() throws {
        let door = Door()
        let paired = try Self.pair(door)
        let call = try Self.running(door, paired.grant.id)

        Files.lock(door.folder.url)
        defer { Files.unlock(door.folder.url) }
        #expect(throws: RemoteAccessStoreError.self) { try door.state.revoke(grant: paired.grant.id) }
        #expect(call.answers.texts == [RemoteAccessText.turnedOff])
        #expect(door.state.validate(paired.access) == .invalid)
        door.state.tick()
        #expect(door.saved().map(\.id) == [paired.grant.id])

        Files.unlock(door.folder.url)
        door.clock.advance(15)
        door.state.tick()
        #expect(door.saved().isEmpty)
    }

    /// The same holds at quit: a revoke whose save failed is written then.
    @Test func aRevokeWhoseSaveFailedIsSavedOnQuit() throws {
        let door = Door()
        let paired = try Self.pair(door)
        Files.lock(door.folder.url)
        defer { Files.unlock(door.folder.url) }
        _ = try? door.state.revokeAll()
        #expect(door.saved().map(\.id) == [paired.grant.id])
        #expect(throws: RemoteAccessStoreError.self) { try door.state.saveOnQuit() }
        Files.unlock(door.folder.url)
        try door.state.saveOnQuit()
        #expect(door.saved().isEmpty)
    }

    /// `/oauth/revoke` with the refresh token ends the grant from the network, under the same lock: its open
    /// call is answered at once, and the file follows before the 200 goes out.
    @Test func aClientsRevokeAnswersItsOpenCalls() throws {
        let door = Door()
        let paired = try Self.pair(door)
        let call = try Self.running(door, paired.grant.id)
        let answer = door.state.revoke(Self.body(["token": paired.refresh, "client_id": paired.client]))
        #expect(answer?.status == 200)
        #expect(call.answers.texts == [RemoteAccessText.turnedOff])
        #expect(door.saved().isEmpty)
        #expect(door.state.begin(call.id, grant: paired.grant.id) == .ended)
    }

    /// Reusing a replaced refresh token after the grace ends the grant, answers its open calls and tells the Mac.
    @Test func refreshReuseEndsTheGrantsCalls() throws {
        let door = Door()
        let paired = try Self.pair(door)
        let rotated = try #require(Self.refresh(door, paired))
        #expect(Flow.tokens(rotated) != nil)
        let call = try Self.running(door, paired.grant.id)
        door.clock.advance(OAuth.refreshGrace + 1)
        let reused = try #require(Self.refresh(door, paired))
        #expect(Flow.tokens(reused) == nil)
        #expect(call.answers.texts == [RemoteAccessText.turnedOff])
        #expect(door.saved().isEmpty)
        let events = door.lines().map(\.event)
        #expect(events.contains("grant.refresh_reused"))
    }

    /// Turning off answers every open call, drops the access tokens and keeps the grants; with Revoke All, they go
    /// too. A call opened after it is refused.
    @Test func turningOffAnswersEveryCallAndKeepsTheGrantsUnlessRevokeAll() throws {
        let door = Door()
        let paired = try Self.pair(door)
        let call = try Self.running(door, paired.grant.id)
        door.state.turnOff(revokeAll: false)
        #expect(call.answers.texts == [RemoteAccessText.turnedOff])
        #expect(door.state.validate(paired.access) == .invalid)
        #expect(door.saved().map(\.id) == [paired.grant.id])
        #expect(door.state.calls.open(grant: paired.grant.id, connection: 2, streamed: false) { _ in } == .closed)
        #expect(door.lines().contains { $0.event == "remote.turned_off" && $0.reason == "turn_off" })

        let other = Door()
        _ = try Self.pair(other)
        other.state.turnOff(revokeAll: true)
        #expect(other.saved().isEmpty)
    }

    /// Turn Off and Revoke All with no host saved (the door closed and the hostname cleared, or Confirm Host) still
    /// ends every grant the file holds, so typing that host back in brings none back. The log has each revoke and
    /// the kill switch's line (R37, R39). A save that failed is tried again at quit.
    @Test func revokeAllWithNoHostSavedEndsTheGrantsTheFileHolds() throws {
        let door = Door()
        let paired = try Self.pair(door)
        let clock = door.clock
        let closed = RemoteAccessDoorState(folder: door.folder.url, host: nil, clock: { clock.now },
                                           report: { _ in })
        closed.turnOff(revokeAll: true)
        #expect(door.saved().isEmpty)
        closed.setHost(Self.host)
        #expect(closed.update { authority, _ in authority.grants.isEmpty } == true)
        closed.flushAudit()
        let lines = door.lines()
        #expect(lines.contains { $0.event == "grant.revoked" && $0.grant == paired.grant.id && $0.reason == "revoke_all" })
        #expect(lines.contains { $0.event == "remote.turned_off" && $0.reason == "revoke_all" })
        let again = RemoteAccessDoorState(folder: door.folder.url, host: Self.host, report: { _ in })
        #expect(again.update { authority, _ in authority.grants.isEmpty } == true)

        let locked = Door()
        _ = try Self.pair(locked)
        let failing = RemoteAccessDoorState(folder: locked.folder.url, host: nil, clock: { clock.now },
                                            report: { _ in })
        Files.lock(locked.folder.url)
        failing.turnOff(revokeAll: true)
        Files.unlock(locked.folder.url)
        #expect(locked.saved().count == 1)
        try failing.saveOnQuit()
        #expect(locked.saved().isEmpty)
    }

    // MARK: from one state to the next

    /// The next state on the door's folder and clock, as the next start or a change while the door is closed
    /// makes it, carrying what the last one left.
    static func next(_ door: Door, host: String? = RemoteAccessDoorStateTests.host,
                     carrying carried: RemoteAccessDoorState.Carried?) -> RemoteAccessDoorState {
        let clock = door.clock
        return RemoteAccessDoorState(folder: door.folder.url, host: host,
                                     calls: RemoteAccessCalls(clock: { clock.now }), clock: { clock.now },
                                     report: { _ in }, carrying: carried)
    }

    /// A revoke whose save failed goes to the next state, which takes it over the file's older grants: the grant
    /// doesn't work again there, and that state saves it at its tick. A state whose saves all went through hands
    /// over no grants, so the next one reads the file.
    @Test func aRevokeWhoseSaveFailedGoesToTheNextState() throws {
        let door = Door()
        let paired = try Self.pair(door)
        #expect(door.state.carried().unsaved == nil)

        Files.lock(door.folder.url)
        defer { Files.unlock(door.folder.url) }
        #expect(throws: RemoteAccessStoreError.self) { try door.state.revoke(grant: paired.grant.id) }
        let carried = door.state.carried()
        #expect(carried.unsaved?.grants.isEmpty == true)
        let next = Self.next(door, carrying: carried)
        #expect(door.saved().map(\.id) == [paired.grant.id])
        #expect(next.grants.isEmpty)
        let refreshed = next.token(Self.body(Flow.refreshParameters(paired.refresh, client: paired.client)))
        #expect(refreshed.flatMap(Flow.tokens) == nil)
        #expect(next.carried().unsaved != nil)

        Files.unlock(door.folder.url)
        door.clock.advance(15)
        next.tick()
        #expect(door.saved().isEmpty)
        #expect(next.carried().unsaved == nil)
    }

    /// The same with no host saved: a Revoke All whose save failed goes to the next state, whose tick saves it,
    /// and a host saved after it brings none of those grants back.
    @Test func aRevokeAllWithNoHostWhoseSaveFailedGoesToTheNextState() throws {
        let door = Door()
        _ = try Self.pair(door)
        let closed = Self.next(door, host: nil, carrying: nil)
        Files.lock(door.folder.url)
        defer { Files.unlock(door.folder.url) }
        #expect(throws: RemoteAccessStoreError.self) { try closed.revokeAll() }
        let next = Self.next(door, host: nil, carrying: closed.carried())
        next.tick()
        #expect(door.saved().count == 1)

        Files.unlock(door.folder.url)
        next.tick()
        #expect(door.saved().isEmpty)
        next.setHost(Self.host)
        #expect(next.grants.isEmpty)
    }

    /// R20, R37: a list-changed mark no stream took, made while the door was open or closed, and the last hour's
    /// calls go to the next state, so a change made before a start still reaches the client's next stream.
    @Test func theListChangedMarksAndTheLastHoursCallsGoToTheNextState() throws {
        let door = Door()
        let paired = try Self.pair(door)
        var fewer = RemoteAccessOptions.readOnly
        fewer[.editor] = false
        try door.state.changeOptions(of: paired.grant.id, to: fewer)
        let calls = (0..<3).map { _ in
            Entry.call(time: door.clock.now, grant: paired.grant, tool: "list_tabs", arguments: nil,
                       decision: .allowed)
        }
        door.state.audit(calls)
        door.state.turnOff(revokeAll: false)
        let carried = door.state.carried()
        #expect(carried.unsaved == nil)
        #expect(carried.listChanged == [paired.grant.id])

        let next = Self.next(door, carrying: carried)
        #expect(next.callsInLastHour == 3)
        #expect(next.options(of: paired.grant.id, listed: false) == fewer)
        let opened = next.calls.open(grant: paired.grant.id, connection: 1, streamed: true) { _ in }
        guard case .call(_, let marked) = opened else { Issue.record("no call"); return }
        #expect(marked)
    }

    /// States that share one audit queue (the app's open and closed doors, and its reads of the log) write every
    /// line in the order it was queued, even when each one's first write drops entries past 30 days.
    @Test func statesThatShareAnAuditQueueLoseNoLine() throws {
        let folder = Files.Folder()
        let clock = RemoteAccessCallsTests.Clock()
        let long = clock.now.addingTimeInterval(-40 * 86_400)
        var old = RemoteAccessAuditLog(folder: folder.url)
        try old.append(Entry.tunnel("old", time: long), now: long)
        let queue = DispatchQueue(label: "test.remote-access.audit")
        let states = (0..<2).map { _ in
            RemoteAccessDoorState(folder: folder.url, host: nil, clock: { clock.now }, report: { _ in },
                                  auditQueue: queue)
        }
        var written: [String] = []
        for index in 0..<40 {
            states[index % 2].audit([Entry.tunnel("line \(index)", time: clock.now)])
            written.append("line \(index)")
        }
        #expect(states[0].flushAudit())
        var log = RemoteAccessAuditLog(folder: folder.url)
        #expect(log.tail(now: clock.now).compactMap(\.reason) == written)
    }

    // MARK: the list

    /// R20: a `tools/list` reads the options and clears the mark in one step, so an options change either shows
    /// in that list or marks the next stream. Other methods read the options without clearing it.
    @Test func aToolsListReadsTheOptionsAndClearsTheMarkInOneStep() throws {
        let door = Door()
        let state = door.state
        let paired = try Self.pair(door)
        var fewer = RemoteAccessOptions.readOnly
        fewer[.editor] = false
        try state.changeOptions(of: paired.grant.id, to: fewer)
        #expect(state.options(of: paired.grant.id, listed: false) == fewer)
        let kept = state.calls.open(grant: paired.grant.id, connection: 1, streamed: true) { _ in }
        guard case .call(_, let marked) = kept else { Issue.record("no call"); return }
        #expect(marked)

        try state.changeOptions(of: paired.grant.id, to: .readOnly)
        #expect(state.options(of: paired.grant.id, listed: true) == .readOnly)
        let after = state.calls.open(grant: paired.grant.id, connection: 2, streamed: true) { _ in }
        guard case .call(_, let cleared) = after else { Issue.record("no call"); return }
        #expect(!cleared)
        #expect(state.options(of: "gone", listed: true) == nil)
    }

    // MARK: the audit log

    /// R39: calls past a grant's limits are summed, one line a minute per grant, written at the tick after it.
    @Test func callsPastAGrantsLimitsAreSummedAtTheTick() throws {
        let door = Door()
        let paired = try Self.pair(door)
        for _ in 0..<500 { door.state.countOverLimit(paired.grant, tool: "read_tab") }
        door.clock.advance(30)
        door.state.tick()
        #expect(!door.lines().contains { $0.kind == "too_many_calls" })
        door.clock.advance(30)
        door.state.tick()
        let summed = door.lines().filter { $0.kind == "too_many_calls" }
        #expect(summed.count == 1)
        #expect(summed.first?.count == 500)
        #expect(summed.first?.grant == paired.grant.id)
    }

    /// Lines are written in the order they were queued, off the state's lock; a line that can't be written is
    /// reported, never thrown, and the door goes on.
    @Test func auditLinesKeepTheirOrderAndAFailedWriteGoesOn() throws {
        let door = Door()
        let paired = try Self.pair(door)
        let tools = (0..<20).map { "tool_\($0)" }
        for tool in tools {
            door.state.audit([Entry.call(time: door.clock.now, grant: paired.grant, tool: tool, arguments: nil,
                                         decision: .allowed)])
        }
        #expect(door.lines().compactMap(\.tool) == tools)

        Files.lock(door.folder.url)
        defer { Files.unlock(door.folder.url) }
        Files.lock(door.folder.file("audit.jsonl"))
        defer { Files.unlock(door.folder.file("audit.jsonl")) }
        door.state.audit([Entry.turnedOff(revokeAll: false, time: door.clock.now)])
        #expect(door.state.flushAudit())
        #expect(door.state.validate(paired.access) != .invalid)
    }
}
