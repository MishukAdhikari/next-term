import Foundation

/// The one refresher of one sign-in: every agent session's need of the server asks it for an access token, and
/// concurrent needs share one refresh.
///
/// - **A token valid for more than a minute** is used as it is.
/// - **Otherwise one flight**: the first need starts it, the others wait for it (`NSLock` and a `DispatchGroup`, in the
///   style of MCPHubRemote's start). Under `sign-ins.lock`, which another copy of Next Term waits for, the record is
///   read again: when another copy refreshed meanwhile, its tokens are taken and nothing is sent.
/// - **A refresh token is sent once.** Before it is sent the record says `refreshing` with its digest; a crash then
///   leaves that, and the next flight finds it under the lock and goes to Reconnect, never sending it again. A request
///   that surely never left (no address, no connection) gives the token back; one that may have left and got no
///   answer, or any answer but a new token, spends it (D4: strict; a provider's reuse detection would end the grant).
/// - **No timers**: a refresh happens only when a need asks.
public final class SignInRefresher: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        case token(String)
        /// The sign-in lapsed at this generation: the user reconnects.
        case signedOut(lapse: Int)
        case needsMoreAccess([String])
        /// The sign-in server couldn't be reached and nothing was spent: try again.
        case unreachable(String)
        /// No such sign-in (removed), or the file was changed outside Next Term.
        case missing
        case tampered
    }

    public let id: String
    let store: SignInStore
    let fetch: MCPHubOAuth.Fetch
    /// A token closer than this to its end is refreshed first.
    public var margin: TimeInterval = 60

    private let lock = NSLock()
    private final class Flight: @unchecked Sendable {
        let group = DispatchGroup()
        var outcome: Outcome?
    }
    private var flight: Flight?
    /// How many refreshes this refresher sent, for the tests.
    public private(set) var sent = 0

    public init(id: String, store: SignInStore, fetch: @escaping MCPHubOAuth.Fetch) {
        self.id = id
        self.store = store
        self.fetch = fetch
    }

    /// A token for one need. `refused`: the access token the server just answered 401 to, so it isn't given again.
    public func token(refused: String? = nil, now: @escaping () -> Date = Date.init) -> Outcome {
        if refused == nil, let quick = usable(now: now()) { return quick }
        lock.lock()
        if let flight {
            lock.unlock()
            flight.group.wait()
            lock.lock()
            let outcome = flight.outcome
            lock.unlock()
            // The flight that just ended answered for every need that waited on it.
            if let outcome, outcome != .token(refused ?? "\u{0}") { return outcome }
            return token(refused: refused, now: now)
        }
        let mine = Flight()
        mine.group.enter()
        flight = mine
        lock.unlock()
        let outcome = fly(refused: refused, now: now)
        lock.lock()
        mine.outcome = outcome
        flight = nil
        lock.unlock()
        mine.group.leave()
        return outcome
    }

    /// The token as the file has it, when it is good for more than `margin`; nil when a flight is needed.
    private func usable(now: Date) -> Outcome? {
        switch store.read() {
        case .failure: return .tampered
        case .success(let body):
            guard let record = body.record(id: id) else { return .missing }
            switch record.state {
            case .signedOut(let lapse): return .signedOut(lapse: lapse)
            case .needsMoreAccess(let scopes): return .needsMoreAccess(scopes)
            case .refreshing: return nil // another copy's flight, or one a crash left: the lock settles which
            case .signedIn: break
            }
            if let ends = record.accessExpires, ends.timeIntervalSince(now) <= margin { return nil }
            guard let tokens = store.tokens(record) else { return .tampered }
            return .token(tokens.access)
        }
    }

    /// One flight under the file's lock.
    private func fly(refused: String?, now: () -> Date) -> Outcome {
        do {
            return try store.withLock { () -> Outcome in
                guard case .success(let body) = store.read() else { return .tampered }
                guard var record = body.record(id: id) else { return .missing }
                switch record.state {
                case .signedOut(let lapse): return .signedOut(lapse: lapse)
                case .needsMoreAccess(let scopes): return .needsMoreAccess(scopes)
                case .refreshing:
                    // Nobody else holds the lock, so this is a flight that never finished: its token is spent.
                    return try lapse(&record)
                case .signedIn: break
                }
                guard let tokens = store.tokens(record) else { return .tampered }
                // Another copy (or flight) refreshed meanwhile: its token is taken, and nothing is sent.
                let fresh = record.accessExpires.map { $0.timeIntervalSince(now()) > margin } ?? true
                if fresh, tokens.access != refused { return .token(tokens.access) }
                guard let refresh = tokens.refresh else { return try lapse(&record) }
                guard let request = MCPHubOAuthFlow.refreshRequest(refresh: refresh, metadata: record.metadata, client: client(for: record, body)) else {
                    return try lapse(&record)
                }
                // Spent from here: the state says so before a byte leaves.
                record.state = .refreshing(spent: SignInFile.digest(refresh))
                try write(record)
                lock.lock()
                sent += 1
                lock.unlock()
                switch fetch(request) {
                case .failure(.unsent(let why)):
                    record.state = .signedIn // never left: the token isn't spent
                    try write(record)
                    return .unreachable(why)
                case .failure(.lost):
                    return try lapse(&record)
                case .success(let response):
                    switch MCPHubOAuthFlow.tokens(response, now: now()) {
                    case .success(let new):
                        // A server that doesn't rotate gives no new refresh token: the old one is kept.
                        try SignInFile.seal(SignInFile.Tokens(access: new.access, refresh: new.refresh ?? refresh), into: &record, key: store.key)
                        record.generation += 1
                        record.accessExpires = new.expires.map(SignInFile.whole)
                        if let scopes = new.scopes { record.granted = scopes }
                        record.state = .signedIn
                        try write(record)
                        return .token(new.access)
                    case .failure(.invalidClient):
                        // The client is gone: the next sign-in registers again.
                        try store.locked { body in
                            body.forgetClient(issuer: record.issuer)
                            return (true, ())
                        }
                        return try lapse(&record)
                    case .failure:
                        return try lapse(&record)
                    }
                }
            }
        } catch {
            return .unreachable("Next Term couldn\u{2019}t keep its sign-in to \(id): \(error.localizedDescription)")
        }
    }

    /// The record's client, its secret opened when it is a registered one's.
    private func client(for record: SignInFile.Record, _ body: SignInFile.Body) -> MCPHubOAuthRegistration.Client {
        if record.client.kind != .metadataDocument,
           let known = body.registered(key: store.key).first(where: { $0.issuer == record.issuer && $0.clientID == record.client.clientID }) {
            return known
        }
        return record.client
    }

    private func lapse(_ record: inout SignInFile.Record) throws -> Outcome {
        record.state = .signedOut(lapse: record.generation)
        try write(record)
        return .signedOut(lapse: record.generation)
    }

    /// The record written in place, under the lock already held.
    private func write(_ record: SignInFile.Record) throws {
        try store.locked { body in
            guard let at = body.records.firstIndex(where: { $0.id == record.id }) else { return (false, ()) }
            body.records[at] = record
            return (true, ())
        }
    }
}
