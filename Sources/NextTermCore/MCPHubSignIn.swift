import Foundation

/// One sign-in to a remote MCP server, start to end, off the main thread: where it signs in (MCPHubOAuthDiscovery),
/// as which client (MCPHubOAuthRegistration), the loopback listener (MCPHubLoopback), the browser (`open`, which the
/// app gives as NSWorkspace's, never a shell), the callback checked (MCPHubOAuthFlow), the code exchanged, and the
/// sign-in kept (SignInStore). Only the user's click starts one: agents never do.
public final class MCPHubSignIn: @unchecked Sendable {
    public let name: String
    public let server: URL
    let challenge: MCPHubOAuthChallenge?
    let own: MCPHubOAuthRegistration.Own?
    let store: SignInStore
    let fetch: MCPHubOAuth.Fetch
    let metadataDocument: String?
    /// Scopes a reconnect for more access asks for, in place of the chosen ones.
    let scopes: [String]?

    private let lock = NSLock()
    private var listener: MCPHubLoopback?
    private var cancelled = false
    /// Where it signs in, once found: for "Finish signing in at github.com".
    public private(set) var metadata: MCPHubOAuthDiscovery.Metadata?

    public init(name: String, server: URL, challenge: MCPHubOAuthChallenge?, own: MCPHubOAuthRegistration.Own? = nil,
                store: SignInStore, fetch: @escaping MCPHubOAuth.Fetch, metadataDocument: String? = nil, scopes: [String]? = nil) {
        self.name = name
        self.server = server
        self.challenge = challenge
        self.own = own
        self.store = store
        self.fetch = fetch
        self.metadataDocument = metadataDocument
        self.scopes = scopes
    }

    /// Ends a sign-in waiting for the browser; `run` returns `cancelled`.
    public func cancel() {
        lock.lock()
        cancelled = true
        let waiting = listener
        lock.unlock()
        waiting?.close()
    }

    public static let cancelledText = "Sign-in was cancelled."

    /// The sign-in, waiting for the browser until `deadline` (10 minutes at most). `open` opens the authorization URL
    /// and says whether it did. The record kept, or why not, as a sentence.
    public func run(open: (URL) -> Bool, until deadline: Date = Date().addingTimeInterval(MCPHubLoopback.life)) -> Result<SignInFile.Record, MCPHubOAuth.Failure> {
        let metadata: MCPHubOAuthDiscovery.Metadata
        switch MCPHubOAuthDiscovery.discover(server: server, name: name, challenge: challenge, fetch: fetch) {
        case .failure(let failure): return .failure(failure)
        case .success(let found): metadata = found
        }
        lock.lock()
        self.metadata = metadata
        lock.unlock()

        // The listener first: its port is the redirect, and a server that won't take a portless one registers it.
        let state = MCPHubOAuthFlow.random(32)
        let box = PendingBox()
        let listener: MCPHubLoopback
        do {
            listener = try MCPHubLoopback { [name] query in
                guard let pending = box.pending else { return nil }
                switch MCPHubOAuthFlow.callback(query: query, pending: pending) {
                case .notOurs: return nil
                case .code: return MCPHubLoopback.page("Signed in to \(name). You can close this tab and go back to Next Term.")
                case .denied: return MCPHubLoopback.page("Signing in to \(name) was cancelled. You can close this tab.")
                case .wrongIssuer: return MCPHubLoopback.page("This sign-in came back from another server, so Next Term didn\u{2019}t use it.")
                case .error: return MCPHubLoopback.page("\(name) didn\u{2019}t sign you in. You can close this tab and try again in Next Term.")
                }
            }
        } catch {
            return .failure(MCPHubOAuth.Failure("Next Term couldn\u{2019}t listen for the sign-in\u{2019}s answer on this Mac."))
        }
        defer { listener.close() }
        lock.lock()
        self.listener = listener
        let stop = cancelled
        lock.unlock()
        if stop { return .failure(MCPHubOAuth.Failure(Self.cancelledText)) }

        let registered: [MCPHubOAuthRegistration.Client]
        switch store.read() {
        case .success(let body): registered = body.registered(key: store.key)
        case .failure: registered = []
        }
        var client: MCPHubOAuthRegistration.Client
        switch MCPHubOAuthRegistration.choose(name: name, metadata: metadata, own: own, registered: registered, metadataDocument: metadataDocument) {
        case .none(let why): return .failure(MCPHubOAuth.Failure(why))
        case .use(let chosen): client = chosen
        case .register(let endpoint):
            switch MCPHubOAuthRegistration.register(at: endpoint, issuer: metadata.issuer, name: name, exact: listener.redirect, fetch: fetch) {
            case .failure(let failure): return .failure(failure)
            case .success(let made): client = made
            }
        }
        let wanted = scopes ?? metadata.scopes(challenge: challenge)
        let pending = MCPHubOAuthFlow.Pending(state: state, metadata: metadata, client: client, redirect: listener.redirect, scopes: wanted)
        box.pending = pending
        guard let url = pending.authorizationURL, MCPHubOAuthURL.isOpenable(url, server: server) else {
            return .failure(MCPHubOAuth.Failure("\(name)\u{2019}s sign-in address isn\u{2019}t one Next Term opens."))
        }
        guard open(url) else { return .failure(MCPHubOAuth.Failure("Next Term couldn\u{2019}t open your browser to sign in to \(name).")) }

        guard let query = listener.wait(until: min(deadline, Date().addingTimeInterval(MCPHubLoopback.life))) else {
            lock.lock()
            let stopped = cancelled
            lock.unlock()
            return .failure(MCPHubOAuth.Failure(stopped ? Self.cancelledText : "Signing in to \(name) took too long; try again."))
        }
        let code: String
        switch MCPHubOAuthFlow.callback(query: query, pending: pending) {
        case .code(let found): code = found
        case .denied: return .failure(MCPHubOAuth.Failure("Signing in to \(name) was cancelled in the browser."))
        case .wrongIssuer: return .failure(MCPHubOAuth.Failure("The sign-in came back from another server than \(metadata.issuerHost), so Next Term didn\u{2019}t use it."))
        case .error(let error): return .failure(MCPHubOAuth.Failure("\(name) didn\u{2019}t sign you in (\(error))."))
        case .notOurs: return .failure(MCPHubOAuth.Failure("The sign-in\u{2019}s answer wasn\u{2019}t this sign-in\u{2019}s."))
        }
        guard let request = pending.tokenRequest(code: code) else {
            return .failure(MCPHubOAuth.Failure("\(name)\u{2019}s token address isn\u{2019}t one Next Term uses."))
        }
        let tokens: MCPHubOAuthFlow.Tokens
        switch fetch(request) {
        case .failure(let failure): return .failure(MCPHubOAuth.Failure("Next Term couldn\u{2019}t finish signing in to \(name): \(failure.text)"))
        case .success(let response):
            switch MCPHubOAuthFlow.tokens(response) {
            case .success(let got): tokens = got
            case .failure(.invalidClient):
                if client.kind == .registered { _ = try? store.update { body in body.forgetClient(issuer: metadata.issuer); return (true, ()) } }
                return .failure(MCPHubOAuth.Failure("\(name) no longer knows Next Term\u{2019}s registration. Sign in again."))
            case .failure(.invalidGrant): return .failure(MCPHubOAuth.Failure("\(name) didn\u{2019}t accept the sign-in\u{2019}s code; try again."))
            case .failure(.other(let code)): return .failure(MCPHubOAuth.Failure("\(name) didn\u{2019}t finish the sign-in (\(code))."))
            }
        }
        do {
            let record = try SignInFile.record(name: name, server: server, metadata: metadata, client: client, tokens: tokens, scopes: wanted, key: store.key)
            return .success(try store.add(record, client: client))
        } catch {
            return .failure(MCPHubOAuth.Failure("Next Term couldn\u{2019}t keep the sign-in to \(name): \(error.localizedDescription)"))
        }
    }

    private final class PendingBox: @unchecked Sendable {
        private let lock = NSLock()
        private var held: MCPHubOAuthFlow.Pending?
        var pending: MCPHubOAuthFlow.Pending? {
            get { lock.lock(); defer { lock.unlock() }; return held }
            set { lock.lock(); held = newValue; lock.unlock() }
        }
    }
}
