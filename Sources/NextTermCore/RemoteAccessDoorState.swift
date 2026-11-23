import Foundation

/// What the Remote access door decides with (U7), under one lock (KTD15): the OAuth authority, the grant store, the
/// refusal counts, and the open-call registry's revokes. The door's sockets are in the app (`RemoteAccessServer`).
///
/// Every revoke path takes this lock and then the registry's: Revoke on the Mac, Revoke All, the kill switch,
/// refresh reuse, a reused code, `/oauth/revoke`, expiry and a new hostname. Just before a call runs, on the main
/// thread, `begin` reads its grant under this lock and hands it to the registry, still under it.
///
/// Grant changes are saved before their reply goes out. A failed save of new tokens answers `server_error`: the
/// authority keeps the old refresh token current, and the new pair is never sent. A failed save of a new grant
/// (Allow) or of new options changes nothing. Every other change applies at once, since a revoke can't wait for a
/// disk: a revoke whose save fails says so, and its save is tried again at each `tick` and at quit, so the grant
/// doesn't come back after a relaunch. Uses are saved at most once an hour.
///
/// Audit lines are queued in order and written on their own queue, never under this lock, so a slow disk, a
/// rotation or the hourly 30-day prune can't hold up the door's queue or the main thread's `begin`. `flushAudit`
/// waits for them. Anything that reads the log while the door runs (the activity view) reads it on that queue too.
/// The app gives every state one queue, which its own reads and writes of the log use while the door is closed, so
/// no two of them rewrite the file at once.
///
/// A door's state serves one start. What it leaves the next state (`carried()`) goes on: the grants when a save
/// failed, the list-changed marks no stream took yet, and the last hour's calls. A change while the door is closed
/// runs on a state of its own made the same way.
///
/// Until a host is saved (Confirm Host), there is no authority, and every route answers nil: the door sends 421.
///
/// Never call into the door's queue (`RemoteAccessServer.stop()`, `isRunning`) inside `update {}`: the door's queue
/// may be waiting for this lock.
public final class RemoteAccessDoorState: @unchecked Sendable { // under `lock`, but `log` lives on `auditQueue`
    public let calls: RemoteAccessCalls
    /// The authority's events, on the main thread: U9 shows the reuse notice and the other Mac notices. Set it
    /// before the door starts.
    public var onEvents: (@MainActor ([RemoteAccessOAuth.Event]) -> Void)?
    /// The grants that just ended, on the main thread: the door closes the approval windows their calls opened on
    /// the Mac. Set it before the door starts.
    public var onGrantsEnded: (@MainActor ([String]) -> Void)?

    private let lock = NSLock()
    private let clock: @Sendable () -> Date
    private let random: @Sendable (Int) -> [UInt8]
    private let report: @Sendable (String) -> Void
    private var authority: RemoteAccessOAuth?
    private var store: RemoteAccessGrantStore
    private var refusals = RemoteAccessRefusals()
    /// The tool calls of the last hour, for the status item (U11).
    private var callCount = RemoteAccessCallCount()
    /// The clients and grants as the file holds them, their last uses aside: a change to them is saved.
    private var saved: Saved
    /// What the store held at launch, for when the host is saved. Revoke All with no host ends its grants here.
    private var loaded: RemoteAccessGrantStore.Loaded
    private let auditQueue: DispatchQueue
    private var log: RemoteAccessAuditLog

    private struct Saved: Equatable {
        var clients: [RemoteAccessOAuth.Client]
        var grants: [RemoteAccessOAuth.Grant]

        init(_ clients: [RemoteAccessOAuth.Client], _ grants: [RemoteAccessOAuth.Grant]) {
            self.clients = clients.map { client in
                var kept = client
                kept.lastUsed = .distantPast
                return kept
            }
            self.grants = grants.map { grant in
                var kept = grant
                kept.lastUsed = .distantPast
                return kept
            }
        }
    }

    /// The state for a door, from the grant store in `folder` (the Remote access folder, or a self-test's temp
    /// folder, KTD18), with the saved public hostname, if there is one. A door's state serves one start: turning
    /// off ends its registry for good, so the next start makes a new one. `report` gets what failed to save or
    /// write; it never holds a token. `auditQueue` is where the log is written, its own when nil. `carried` is
    /// what the last state left: its grants, when the file holds older ones, take their place and are saved at
    /// the first chance; its marks and its call count go on here.
    public init(folder: URL, host: String?, calls: RemoteAccessCalls = RemoteAccessCalls(),
                clock: @escaping @Sendable () -> Date = { Date() },
                random: @escaping @Sendable (Int) -> [UInt8] = RemoteAccessOAuth.systemRandom,
                report: @escaping @Sendable (String) -> Void = { NSLog("%@", $0) },
                auditQueue: DispatchQueue? = nil, carrying carried: Carried? = nil) {
        self.calls = calls
        self.clock = clock
        self.random = random
        self.report = report
        self.auditQueue = auditQueue ?? DispatchQueue(label: "nextterm.remote-access.audit")
        store = RemoteAccessGrantStore(folder: folder)
        log = RemoteAccessAuditLog(folder: folder)
        loaded = store.load(now: clock())
        // What the file holds: grants carried over that differ from it are saved by the next change, tick or quit.
        saved = Saved(loaded.clients, loaded.grants)
        if let carried {
            if let unsaved = carried.unsaved {
                loaded.clients = unsaved.clients
                loaded.grants = unsaved.grants
            }
            callCount = carried.callCount
            for grantID in carried.listChanged { calls.markListChanged(grantID) }
        }
        if let host { setHost(host) }
    }

    /// What a state leaves the next one (see the type's comment).
    public struct Carried: Sendable {
        /// The clients and grants as a state left them, when the file holds older ones.
        public struct Unsaved: Sendable {
            public var clients: [RemoteAccessOAuth.Client]
            public var grants: [RemoteAccessOAuth.Grant]
        }

        /// Nil when the file holds what the state held.
        public var unsaved: Unsaved?
        /// The grants whose options changed since their client last listed its tools (R20).
        public var listChanged: Set<String>
        public var callCount: RemoteAccessCallCount
    }

    /// What the next state takes over from this one: after it turned off, or after a change while the door is
    /// closed.
    public func carried() -> Carried {
        lock.lock()
        defer { lock.unlock() }
        let clients = authority?.clients ?? loaded.clients
        let grants = authority?.grants ?? loaded.grants
        let unsaved = Saved(clients, grants) == saved ? nil : Carried.Unsaved(clients: clients, grants: grants)
        return Carried(unsaved: unsaved, listChanged: calls.listChangedGrants, callCount: callCount)
    }

    public var now: Date { clock() }

    /// The public hostname, or nil until one is saved.
    public var host: String? { locked { authority?.host } }

    /// Confirm Host, or a new hostname: the issuer and the resource follow it, and a new one ends every grant
    /// (R17, KTD17).
    public func setHost(_ host: String) {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        if authority == nil {
            authority = RemoteAccessOAuth(host: host, clients: loaded.clients, grants: loaded.grants, random: random)
        } else {
            authority?.setHost(host, now: now)
        }
        settle(now: now)
    }

    /// Runs `body` on the authority under the lock, then handles its events and saves the clients and grants if
    /// they changed. For pairing on the Mac (U8): open, match, decline, close; Allow is `approve`. Nil without a
    /// host.
    public func update<T>(_ body: (inout RemoteAccessOAuth, Date) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard authority != nil else { return nil }
        let now = clock()
        let value = body(&authority!, now)
        settle(now: now)
        return value
    }

    // MARK: the door's reads

    public func validate(_ token: String?) -> RemoteAccessOAuth.Validation {
        locked { authority?.validate(token, now: clock()) ?? (token == nil ? .missing : .invalid) }
    }

    public func wwwAuthenticate(tokenSent: Bool) -> String? {
        locked { authority?.wwwAuthenticate(tokenSent: tokenSent) }
    }

    public func protectedResourceMetadata() -> Data? { locked { authority?.protectedResourceMetadata() } }

    public func authorizationServerMetadata() -> Data? { locked { authority?.authorizationServerMetadata() } }

    /// The grants as they are now, still active, for Settings and the status item (U11).
    public var grants: [RemoteAccessOAuth.Grant] {
        locked {
            let now = clock()
            return authority?.grants.filter { $0.isActive(at: now) } ?? []
        }
    }

    /// The tool calls of the last hour, allowed, refused or past the limits, to the minute (R37).
    public var callsInLastHour: Int {
        locked { callCount.count(at: clock()) }
    }

    /// A grant's options as they are now, for `initialize` and `tools/list`; nil when it is gone. With `listed`
    /// (a `tools/list`), the grant's list-changed mark goes in the same step, so an options change either shows in
    /// this list or marks the next stream (R20).
    public func options(of grantID: String, listed: Bool) -> RemoteAccessOptions? {
        lock.lock()
        defer { lock.unlock() }
        if listed { calls.clearListChanged(grantID) }
        return authority?.grant(grantID)?.options
    }

    // MARK: OAuth routes

    public func register(_ body: Data) -> RemoteAccessOAuth.Answer? {
        update { authority, now in authority.register(body, now: now) }
    }

    public func authorize(_ query: String?) -> RemoteAccessOAuth.Authorization? {
        update { authority, now in authority.authorize(RemoteAccessOAuth.parameters(query), now: now) }
    }

    public func poll(_ query: String?) -> RemoteAccessOAuth.Authorization? {
        update { authority, now in authority.poll(RemoteAccessOAuth.parameters(query)?["request"], now: now) }
    }

    /// `/oauth/token`: new tokens are saved before they apply and go out. A failed save sends `server_error`, and
    /// the old refresh token stays current.
    public func token(_ body: Data) -> RemoteAccessOAuth.Answer? {
        update { authority, now in
            switch authority.token(RemoteAccessOAuth.parameters(body: body), now: now) {
            case .answer(let answer):
                return answer
            case .issue(let issuance):
                let grants = RemoteAccessGrantStore.replacing(issuance.grant, in: authority.grants)
                do {
                    try store.save(clients: authority.clients, grants: grants, now: now)
                } catch {
                    report("Next Term: Remote access could not save new tokens: \(error)")
                    return RemoteAccessOAuth.serverError
                }
                saved = Saved(authority.clients, grants)
                return authority.apply(issuance) ? issuance.answer : RemoteAccessOAuth.serverError
            }
        }
    }

    /// `/oauth/revoke`: a refresh token ends its grant, which answers its open calls (R38).
    public func revoke(_ body: Data) -> RemoteAccessOAuth.Answer? {
        update { authority, now in authority.revoke(RemoteAccessOAuth.parameters(body: body), now: now).answer }
    }

    // MARK: calls

    /// Just before a call runs, on the main thread: the grant as the authority holds it now, active, under this
    /// lock and then the registry's.
    public func begin(_ id: RemoteAccessCalls.ID, grant grantID: String) -> RemoteAccessCalls.Began {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        let grant = authority?.grant(grantID).flatMap { $0.isActive(at: now) ? $0 : nil }
        return calls.begin(id, grant: grant)
    }

    /// A tool call ran: the grant was used (R17). The file gets it at most once an hour.
    public func noteUse(_ grantID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var authority else { return }
        let now = clock()
        authority.noteUse(grantID, now: now)
        self.authority = authority
        do {
            try store.saveUse(clients: authority.clients, grants: authority.grants, now: now)
        } catch {
            report("Next Term: Remote access could not save a use: \(error)")
        }
    }

    // MARK: on the Mac

    /// Allow's outcome: the new grant, or why the request could not be allowed.
    public typealias Approval = Result<RemoteAccessOAuth.Grant, RemoteAccessOAuth.ApprovalError>

    /// Allow in the pairing window (U8), after Touch ID or the password. The new grant is saved before the
    /// browser can get its code; a failed save throws and changes nothing, so the request still waits and Allow
    /// can be clicked again. Nil without a host.
    public func approve(_ requestID: String, name: String, options: RemoteAccessOptions) throws -> Approval? {
        lock.lock()
        defer { lock.unlock() }
        guard var authority else { return nil }
        let now = clock()
        let result = authority.approve(requestID, name: name, options: options, now: now)
        if case .success = result {
            do {
                try store.save(clients: authority.clients, grants: authority.grants, now: now)
            } catch {
                report("Next Term: Remote access could not save a new connection: \(error)")
                throw error
            }
            saved = Saved(authority.clients, authority.grants)
        }
        self.authority = authority
        settle(now: now)
        return result
    }

    /// Revoke on the Mac: the grant ends, and its open calls are answered at once (R38). It throws when the file
    /// could not be saved; the grant has ended all the same, and the save is tried again at each tick and at quit.
    public func revoke(grant grantID: String) throws {
        try ending { authority, now in _ = authority.revoke(grant: grantID, now: now) }
    }

    /// Revoke All, which throws as `revoke(grant:)` does. With no host saved yet, it ends the grants the file holds.
    public func revokeAll() throws {
        try ending(orStored: true) { authority, now in _ = authority.revokeAll(now: now) }
    }

    /// `body` on the authority; with no host yet, nothing, or with `orStored` the grants the file holds end.
    private func ending(orStored: Bool = false, _ body: (inout RemoteAccessOAuth, Date) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        guard authority != nil else {
            if orStored, let failure = endStored(now: now) { throw failure }
            return
        }
        body(&authority!, now)
        if let failure = settle(now: now) { throw failure }
    }

    /// New options for a grant, after Touch ID or the password (R60). They are saved before they apply; a failed
    /// save throws and changes nothing. The grant's next streamed call carries the list-changed event.
    public func changeOptions(of grantID: String, to options: RemoteAccessOptions) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var authority, var grant = authority.grant(grantID) else { return }
        let now = clock()
        grant.options = options
        let grants = RemoteAccessGrantStore.replacing(grant, in: authority.grants)
        try store.save(clients: authority.clients, grants: grants, now: now)
        saved = Saved(authority.clients, grants)
        authority.changeOptions(of: grantID, to: options)
        self.authority = authority
        settle(now: now)
    }

    /// Turn Off, or Turn Off and Revoke All (R37): access tokens dropped (every grant ended too with
    /// `revokeAll`, the file's own with no host saved), the refusal counts written, then every open call answered.
    public func turnOff(revokeAll: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        if revokeAll, authority == nil { endStored(now: now) }
        if revokeAll { _ = authority?.revokeAll(now: now) }
        authority?.dropAccessTokens()
        settle(now: now)
        var lines = [RemoteAccessAuditEntry.turnedOff(revokeAll: revokeAll, time: now)]
        lines += refusals.flush(now: now)
        append(lines, now: now)
        calls.turnOff()
    }

    /// Every 15 seconds while the door runs: the summed lines whose minute has ended are written, and a grant
    /// change whose save failed is saved again.
    public func tick() {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        append(refusals.due(now: now), now: now)
        if let authority {
            saveIfChanged(authority, now: now)
        } else {
            saveLoadedIfChanged(now: now)
        }
    }

    /// On quit (U9): a grant change whose save failed, and a use the file doesn't hold yet, are written now.
    public func saveOnQuit() throws {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        guard let authority else {
            // No host: only a Revoke All whose save failed, here or in the state before, can have changed them.
            if let failure = saveLoadedIfChanged(now: now) { throw failure }
            return
        }
        if let failure = saveIfChanged(authority, now: now) { throw failure }
        try store.saveOnQuit(clients: authority.clients, grants: authority.grants, now: now)
    }

    // MARK: the audit log

    public func audit(_ entries: [RemoteAccessAuditEntry]) {
        lock.lock()
        defer { lock.unlock() }
        for entry in entries where entry.event == RemoteAccessAuditEntry.callEvent { callCount.note(at: entry.time) }
        append(entries, now: clock())
    }

    /// The activity view's read (U11): the last `count` entries, after every line queued so far, on the audit
    /// queue; `done` gets them there.
    public func readAudit(_ count: Int = RemoteAccessAuditLog.tailCount,
                          done: @escaping @Sendable ([RemoteAccessAuditEntry]) -> Void) {
        let now = clock()
        auditQueue.async { [self] in done(log.tail(count, now: now)) }
    }

    /// Clear Log while the door runs (U11): every audit file goes, after the lines queued so far, on the audit
    /// queue; `done` gets the error there, or nil.
    public func clearAudit(done: @escaping @Sendable (Error?) -> Void) {
        auditQueue.async { [self] in
            do {
                try log.clear()
                done(nil)
            } catch {
                done(error)
            }
        }
    }

    /// A request refused before a valid token, counted for its kind's line a minute (R39).
    public func countRefusal(status: Int, request: RemoteAccessHTTP.Request?) {
        guard let kind = RemoteAccessRefusals.Kind(status: status) else { return }
        countRefusal(kind, request: request)
    }

    public func countRefusal(_ kind: RemoteAccessRefusals.Kind, request: RemoteAccessHTTP.Request?) {
        let first = kind == .wrongHost ? request?.header("host") : request?.path
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        append(refusals.count(kind, first: first ?? "", now: now), now: now)
    }

    /// A call past its grant's limits (R27), summed with the minute's others in one line per grant (R39). It
    /// counts as a call all the same (R37).
    public func countOverLimit(_ grant: RemoteAccessOAuth.Grant, tool: String) {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        callCount.note(at: now)
        append(refusals.countOverLimit(grant: grant, tool: tool, now: now), now: now)
    }

    /// Waits up to `seconds` for every line queued so far to be written: at quit, and in tests. False when they
    /// were not all written in time.
    @discardableResult
    public func flushAudit(within seconds: TimeInterval = 10) -> Bool {
        let done = DispatchSemaphore(value: 0)
        auditQueue.async { done.signal() }
        return done.wait(timeout: .now() + seconds) == .success
    }

    // MARK: under the lock

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// After the authority changed: answers the open calls of each grant that ended, marks the list changed for
    /// each grant whose options changed, saves the clients and grants when they changed (their last uses aside),
    /// writes the events to the audit log, and tells the Mac. The error of a save that failed.
    @discardableResult
    private func settle(now: Date) -> Error? {
        guard var authority else { return nil }
        let events = authority.takeEvents()
        var ended: [String] = []
        var changed: [String] = []
        for event in events {
            switch event {
            case .revoked(let grantID, _, _):
                ended.append(grantID)
            case .optionsChanged(let grantID, _, _, _):
                // The registry keeps the mark: the grant's next streamed call carries the event (R20).
                _ = authority.takeToolListChanged(grantID)
                changed.append(grantID)
            default:
                break
            }
        }
        self.authority = authority
        // The calls first: a revoke answers them at once, whatever the disk does.
        for grantID in changed { calls.markListChanged(grantID) }
        if !ended.isEmpty { calls.revoke(grants: ended) }
        let failure = saveIfChanged(authority, now: now)
        guard !events.isEmpty else { return failure }
        append(events.map { RemoteAccessAuditEntry.event($0, time: now) }, now: now)
        if let onEvents { DispatchQueue.main.async { onEvents(events) } }
        if !ended.isEmpty, let onGrantsEnded { DispatchQueue.main.async { onGrantsEnded(ended) } }
        return failure
    }

    /// Saves the clients and grants when they differ from the file's, their last uses aside. On a failure `saved`
    /// stays as it was, so the next change, tick or quit tries again.
    @discardableResult
    private func saveIfChanged(_ authority: RemoteAccessOAuth, now: Date) -> Error? {
        let current = Saved(authority.clients, authority.grants)
        guard current != saved else { return nil }
        do {
            try store.save(clients: authority.clients, grants: authority.grants, now: now)
            saved = current
            return nil
        } catch {
            report("Next Term: Remote access could not save its grants: \(error)")
            return error
        }
    }

    /// With no host, so no authority: saves the clients and grants the state holds when the file holds others (a
    /// Revoke All whose save failed, here or in the state before). On a failure `saved` stays as it was, so the
    /// next tick or quit tries again. The save's error.
    @discardableResult
    private func saveLoadedIfChanged(now: Date) -> Error? {
        let current = Saved(loaded.clients, loaded.grants)
        guard current != saved else { return nil }
        do {
            try store.save(clients: loaded.clients, grants: loaded.grants, now: now)
            saved = current
            return nil
        } catch {
            report("Next Term: Remote access could not save its grants: \(error)")
            return error
        }
    }

    /// Revoke All with no host saved, so no authority: the file may still hold grants (the last host's, until the
    /// hostname was cleared), and they end all the same, so typing that host back in brings none back. Their
    /// clients stay a day, as after any revoke; each end goes in the audit log. On a failed save they are ended
    /// here all the same, and `saveOnQuit` (or the save when a host is set) tries again. The save's error.
    @discardableResult
    private func endStored(now: Date) -> Error? {
        let ended = loaded.grants
        guard !ended.isEmpty else { return nil }
        var clients = loaded.clients
        for grant in ended {
            guard let index = clients.firstIndex(where: { $0.id == grant.clientID }) else { continue }
            clients[index].lastUsed = max(clients[index].lastUsed, now)
        }
        loaded.clients = clients
        loaded.grants = []
        let events = ended.map { grant in
            RemoteAccessOAuth.Event.revoked(grantID: grant.id, name: grant.name, reason: .revokeAll)
        }
        append(events.map { RemoteAccessAuditEntry.event($0, time: now) }, now: now)
        do {
            try store.save(clients: clients, grants: [], now: now)
            saved = Saved(clients, [])
            return nil
        } catch {
            report("Next Term: Remote access could not save its grants: \(error)")
            return error
        }
    }

    /// Queues the lines for the audit queue, in the order they come.
    private func append(_ entries: [RemoteAccessAuditEntry], now: Date) {
        guard !entries.isEmpty else { return }
        auditQueue.async { [self] in
            do {
                try log.append(entries, now: now)
            } catch {
                report("Next Term: Remote access could not write its audit log: \(error)")
            }
        }
    }
}
