import AppKit
import CryptoKit
import NextTermCore
import UserNotifications

/// Next Term's sign-ins to remote MCP servers (R14, R15), for every agent: Next Term is the server's one OAuth client
/// and its one refresher, and an agent never sees or sends a token (the spec's token passthrough rule).
///
/// - **The key.** The sign-ins are sealed in `sign-ins.json` (SignInFile) under a key only the vault releases: its
///   hidden `NEXT_TERM_SIGN_INS` entry, made write-only in the Touch ID of the first sign-in. The key is released at the
///   first need of a launch that has none, with one presence check, and held until Next Term quits, the Mac locking
///   included (D2), so an agent working overnight stays signed in. A launch that never uses a signed-in server asks
///   nothing.
/// - **Signing in** starts only from the user's click (Settings, the Add sheet): the browser, never a web view, with
///   the loopback redirect (MCPHubSignIn). Agents never start one.
/// - **Each need** (`withSignIn`, between MCPHubRemoteControl's keys and its request): the sign-in's state, then R15's
///   consent for the calling agent's kind (once, on the Mac, recorded in the sealed file), then a token from the
///   sign-in's one refresher, off the main thread.
/// - **A lapse** is one notice (once for each lapse, as program alerts are), never a modal; Settings shows Reconnect.
@MainActor
enum MCPHubSignIns {
    /// The sign-ins' key, once released.
    private static var key: SymmetricKey?
    private static var startOver: NSObjectProtocol?
    /// Needs waiting for the key's one presence check.
    private static var unlocking: [(SymmetricKey?) -> Void]?
    private static var refreshers: [String: SignInRefresher] = [:]
    /// The lapses noticed: "id:generation".
    private static var noticed = Set<String>()
    /// Don't Allow, until Next Term quits: "id\0agent".
    private static var refused = Set<String>()
    /// Needs waiting on one consent panel: "id\0agent".
    private static var asking: [String: [(Bool) -> Void]] = [:]
    /// The panel shown for each consent being asked.
    private(set) static var panels: [String: AgentApprovalWindow] = [:]
    /// The last WWW-Authenticate each server sent, by `MCPHubOverview.signInKey`, so a sign-in starts where it said.
    static var challenges: [String: String] = [:]
    /// Sign-ins waiting for the browser, by `MCPHubOverview.signInKey`.
    private(set) static var running: [String: MCPHubSignIn] = [:]

    #if DEBUG
    /// The self-test's: the agent a caller is, and the browser.
    static var agentForTest: ((TerminalTab?) -> String?)?
    static var openForTest: ((URL) -> Bool)?
    #endif

    static var folder: SecretFolder { SecretsStore.shared.folder }

    // MARK: reading, for Settings

    /// The sign-ins as the file has them, unchecked: for Settings' states only.
    static func peek() -> SignInFile.Body? {
        guard folder.exists, let data = try? folder.read(SignInFile.name, cap: SignInFile.maxSize) else { return nil }
        return SignInFile.peek(data)
    }

    /// Each sign-in's state for Settings, by `MCPHubOverview.signInKey`.
    static func states() -> [String: MCPHubOverview.SignIn] {
        var found: [String: MCPHubOverview.SignIn] = [:]
        for record in peek()?.records ?? [] { found[MCPHubOverview.signInKey(record.resource)] = MCPHubOverview.SignIn(record.state) }
        return found
    }

    /// The sign-in for a server's URL, unchecked.
    static func record(for url: String) -> SignInFile.Record? {
        let key = MCPHubOverview.signInKey(url)
        return peek()?.records.first { MCPHubOverview.signInKey($0.resource) == key }
    }

    static var isHeld: Bool { key != nil }

    // MARK: the key

    /// The key, released once a launch; `makes`: made when the vault has none (the first sign-in). Nil when the user
    /// didn't approve, or there is none to release.
    static func withKey(reason: String, makes: Bool, _ done: @escaping (SymmetricKey?) -> Void) {
        if startOver == nil {
            // Start Over in Secrets retires the folder, the sign-ins with it: the key held is no one's now.
            startOver = NotificationCenter.default.addObserver(forName: SecretsStore.startedOver, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { forget() }
            }
        }
        if let key { return done(key) }
        if unlocking != nil {
            unlocking?.append(done)
            return
        }
        unlocking = [done]
        Task { @MainActor in
            let got = await unlock(reason: reason, makes: makes)
            if let got { key = got }
            let waiting = unlocking ?? []
            unlocking = nil
            for each in waiting { each(got) }
        }
    }

    private static func unlock(reason: String, makes: Bool) async -> SymmetricKey? {
        let store = SecretsStore.shared
        store.reloadIfChanged()
        let name = SecretVault.signInsName
        if store.held?.signIns != nil {
            guard let values = try? await store.perform(.use(names: [name]), reason: reason),
                  let text = values[name]?.utf8String(), let data = Data(base64Encoded: text), data.count == 32 else { return nil }
            return SymmetricKey(data: data)
        }
        guard makes else { return nil }
        let made = SymmetricKey(size: .bits256)
        let text = made.withUnsafeBytes { Data($0) }.base64EncodedString()
        do {
            try await store.run(makes: true, names: [name], reason: reason, change: { vault, maskKey in
                try vault.add(name: name, purpose: "Next Term\u{2019}s sign-ins to MCP servers", purposeBy: .user, origin: .settings,
                              writeOnly: true, value: SecretBytes(utf8: text), maskKey: maskKey, kind: .signIns)
            }, line: nil)
            return made
        } catch {
            return nil
        }
    }

    /// Start Over in Secrets retired the folder, the sign-ins with it.
    static func forget() {
        key = nil
        refreshers = [:]
    }

    private static func store(_ key: SymmetricKey) -> SignInStore { SignInStore(folder: folder, key: key) }

    private static func refresher(_ record: SignInFile.Record, key: SymmetricKey) -> SignInRefresher? {
        if let made = refreshers[record.id] { return made }
        guard let url = URL(string: record.resource) else { return nil }
        let made = SignInRefresher(id: record.id, store: store(key), fetch: MCPHubOAuthHTTP(server: url).asFetch)
        refreshers[record.id] = made
        return made
    }

    // MARK: signing in

    /// Sign In… or Reconnect… for `server` (in its list or not yet): Touch ID when the key isn't held (made with the
    /// first sign-in), then the browser. `progress` gets Settings' line while the browser is out; `done` nil when signed
    /// in, else why not.
    static func signIn(_ server: MCPHubServer, scopes: [String]? = nil, progress: @escaping (String) -> Void,
                       done: @escaping (String?) -> Void) {
        guard let url = URL(string: server.url), server.transport != .stdio else { return done("Only a server at a URL signs in.") }
        let name = server.name
        let at = MCPHubOverview.signInKey(server.url)
        guard running[at] == nil else { return done("A sign-in to \(name) is waiting in your browser already.") }
        let more: [String]? = scopes ?? {
            if case .needsMoreAccess(let wanted)? = record(for: server.url)?.state { return wanted }
            return nil
        }()
        withKey(reason: "keep your sign-in to \(name) in Secrets", makes: true) { key in
            guard let key else { return done("Not approved, so Next Term didn\u{2019}t sign in to \(name).") }
            let challenge = MCPHubOAuthChallenge.bearer(challenges[at])
            let flow = MCPHubSignIn(name: name, server: url, challenge: challenge, store: store(key),
                                    fetch: MCPHubOAuthHTTP(server: url).asFetch, scopes: more)
            running[at] = flow
            DispatchQueue.global(qos: .userInitiated).async {
                let result = flow.run(open: { authorization in
                    var opened = false
                    DispatchQueue.main.sync {
                        MainActor.assumeIsolated {
                            opened = open(authorization)
                            progress(MCPHubSignInWords.finishing(name, at: flow.metadata?.issuerHost))
                        }
                    }
                    return opened
                })
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        running[at] = nil
                        switch result {
                        case .success(let record):
                            refreshers[record.id] = nil
                            // The need that asked for a sign-in is history now: Settings shows the sign-in.
                            for (runKey, run) in MCPHubControl.lastRuns where run.needsSignIn && runKey.hasSuffix("\u{0}" + name) {
                                MCPHubControl.lastRuns[runKey] = nil
                            }
                            NSApp.activate(ignoringOtherApps: true) // back from the browser, where the user just was
                            NotificationCenter.default.post(name: MCPHubControl.changed, object: nil)
                            done(nil)
                        case .failure(let failure):
                            done(failure.text == MCPHubSignIn.cancelledText ? nil : failure.text)
                        }
                    }
                }
            }
        }
    }

    /// Cancel while the browser is out.
    static func cancelSignIn(_ url: String) {
        running[MCPHubOverview.signInKey(url)]?.cancel()
    }

    static func isSigningIn(_ url: String) -> Bool { running[MCPHubOverview.signInKey(url)] != nil }

    /// Opens the authorization URL in the user's own browser: LaunchServices, never a shell, and checked again first.
    private static func open(_ url: URL) -> Bool {
        #if DEBUG
        if let openForTest { return openForTest(url) }
        #endif
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        return NSWorkspace.shared.open(url)
    }

    // MARK: signing out

    /// Sign Out, or the last entry for its URL removed: the sign-in goes from the file, then is revoked at the server
    /// (RFC 7009, best effort, ten seconds), or the user is told how to end it there. The last one takes the vault's
    /// key with it, in the one Touch ID it asks. `done` gets what to say.
    static func signOut(url: String, name: String, done: @escaping (String) -> Void) {
        guard let record = record(for: url) else { return done("Signed out of \(name).") }
        let last = (peek()?.records.count ?? 0) <= 1
        let store = SecretsStore.shared
        let folder = folder
        final class Taken: @unchecked Sendable {
            var removed: (record: SignInFile.Record, tokens: SignInFile.Tokens?)?
            var client: MCPHubOAuthRegistration.Client?
            var key: SymmetricKey?
        }
        let taken = Taken()
        let held = key
        func remove(with key: SymmetricKey) throws {
            let signIns = SignInStore(folder: folder, key: key)
            if case .success(let body) = signIns.read() {
                taken.client = body.registered(key: key).first { $0.issuer == record.issuer && $0.clientID == record.client.clientID }
            }
            taken.removed = try signIns.remove(id: record.id)
            taken.key = key
        }
        func finish() {
            key = last ? nil : taken.key
            refreshers[record.id] = nil
            NotificationCenter.default.post(name: MCPHubControl.changed, object: nil)
            guard let removed = taken.removed, let tokens = removed.tokens else { return done("Signed out of \(name).") }
            let client = taken.client ?? removed.record.client
            DispatchQueue.global(qos: .utility).async {
                let said = revoke(removed.record, tokens: tokens, client: client, name: name)
                DispatchQueue.main.async { done(said) }
            }
        }
        if let held, !last {
            do { try remove(with: held) } catch { return done("Next Term couldn\u{2019}t sign out of \(name): \(error.localizedDescription)") }
            return finish()
        }
        Task { @MainActor in
            do {
                try await store.run(makes: false, names: [SecretVault.signInsName], reason: "sign out of \(name)", change: { vault, _ in
                    let signInsKey: SymmetricKey
                    if let held {
                        signInsKey = held
                    } else {
                        let value = try vault.value(of: SecretVault.signInsName)
                        guard let text = value.utf8String(), let data = Data(base64Encoded: text) else { throw SecretVault.Failure.tampered }
                        signInsKey = SymmetricKey(data: data)
                    }
                    try remove(with: signInsKey)
                    guard last else { return nil }
                    try? FileManager.default.removeItem(atPath: folder.path(SignInFile.name))
                    return try vault.delete(SecretVault.signInsName)
                }, line: nil)
                finish()
            } catch SecretsStore.Failure.cancelled {
                done("Not approved, so you\u{2019}re still signed in to \(name).")
            } catch {
                done("Next Term couldn\u{2019}t sign out of \(name): " + ((error as? LocalizedError)?.errorDescription ?? "\(error)"))
            }
        }
    }

    /// Settings › Secrets › Sign Out of All…: every sign-in goes, revoked where the server can, and the vault's key
    /// with them, in one Touch ID.
    static func signOutAll(done: @escaping (String) -> Void) {
        let count = peek()?.records.count ?? 0
        let folder = folder
        let held = key
        final class Taken: @unchecked Sendable {
            var all: [(record: SignInFile.Record, tokens: SignInFile.Tokens?, client: MCPHubOAuthRegistration.Client)] = []
        }
        let taken = Taken()
        Task { @MainActor in
            do {
                try await SecretsStore.shared.run(makes: false, names: [SecretVault.signInsName], reason: "sign out of every MCP server",
                                                  change: { vault, _ in
                    var signInsKey = held
                    if signInsKey == nil, let text = try? vault.value(of: SecretVault.signInsName).utf8String(), let data = Data(base64Encoded: text) {
                        signInsKey = SymmetricKey(data: data)
                    }
                    if let signInsKey, case .success(let body) = SignInStore(folder: folder, key: signInsKey).read() {
                        let clients = body.registered(key: signInsKey)
                        taken.all = body.records.map { record in
                            (record, SignInFile.open(record, key: signInsKey),
                             clients.first { $0.issuer == record.issuer && $0.clientID == record.client.clientID } ?? record.client)
                        }
                    }
                    try? FileManager.default.removeItem(atPath: folder.path(SignInFile.name))
                    return try vault.delete(SecretVault.signInsName)
                }, line: nil)
            } catch SecretsStore.Failure.cancelled {
                return done("Not approved, so you\u{2019}re still signed in.")
            } catch {
                return done("Next Term couldn\u{2019}t sign out: " + ((error as? LocalizedError)?.errorDescription ?? "\(error)"))
            }
            forget()
            NotificationCenter.default.post(name: MCPHubControl.changed, object: nil)
            let all = taken.all
            DispatchQueue.global(qos: .utility).async {
                for each in all {
                    if let tokens = each.tokens { _ = revoke(each.record, tokens: tokens, client: each.client, name: each.record.name) }
                }
            }
            done(count == 1 ? "Signed out of 1 MCP server." : "Signed out of \(count) MCP servers.")
        }
    }

    /// Revokes at the server: the refresh token, or the access token when there is none. Nil said when revoked.
    nonisolated private static func revoke(_ record: SignInFile.Record, tokens: SignInFile.Tokens, client: MCPHubOAuthRegistration.Client,
                                           name: String) -> String {
        guard let url = URL(string: record.resource),
              let request = MCPHubOAuthFlow.revocationRequest(token: tokens.refresh ?? tokens.access,
                                                              hint: tokens.refresh == nil ? "access_token" : "refresh_token",
                                                              metadata: record.metadata, client: client) else {
            return MCPHubSignInWords.revokeByHand(name, host: record.metadata.issuerHost)
        }
        _ = MCPHubOAuthHTTP(server: url).fetch(request, seconds: 10)
        return "Signed out of \(name), and ended its sign-in at \(record.metadata.issuerHost)."
    }

    // MARK: each need

    /// What a need with a sign-in carries: the token, and the one refresher and store, for a 401's refresh.
    struct Use {
        let id: String
        let name: String
        let token: String
        let refresher: SignInRefresher
        let store: SignInStore
    }

    /// The agent a caller is, for R15: its tab's agent kind, or nil for anything that isn't an agent in one of this
    /// Mac's tabs.
    static func agent(_ caller: TerminalTab?) -> String? {
        #if DEBUG
        if let agentForTest { return agentForTest(caller) }
        #endif
        guard let caller, caller.status.running, caller.status.kind == .agent else { return nil }
        return MCPHubSignInWords.agentKey(program: caller.status.program)
    }

    /// Between a need's keys and its request: `use` with the sign-in's token, or nil when the server has no sign-in in
    /// Next Term (or is given its own Authorization header, a key, which no sign-in joins); `fail` with the sentence when
    /// the sign-in can't be used for this agent now.
    static func withSignIn(_ server: MCPHubServer, deadline: Date, caller: TerminalTab?, pid: pid_t?,
                           fail: @escaping (String) -> Void, use: @escaping (Use?) -> Void) {
        if server.headers.keys.contains(where: { $0.lowercased() == "authorization" }) { return use(nil) }
        guard let found = record(for: server.url) else { return use(nil) }
        let name = server.name
        switch found.state {
        case .signedOut(let lapse):
            notice(found.id, lapse: lapse, name: name, url: server.url)
            return fail(MCPHubSignInWords.lapsed(name))
        case .needsMoreAccess(let scopes): return fail(MCPHubSignInWords.moreAccess(name, scopes: scopes))
        case .signedIn, .refreshing: break
        }
        guard let agent = agent(caller) else { return fail(MCPHubSignInWords.notAnAgent(name)) }
        withKey(reason: "use its sign-in to \(name) for your agents", makes: false) { key in
            guard let key else { return fail(MCPHubSignInWords.notUnlocked(name)) }
            let signIns = store(key)
            guard case .success(let body) = signIns.read() else { return fail(MCPHubSignInWords.tampered(name)) }
            guard let record = body.record(id: found.id) else { return use(nil) }
            consent(record, agent: agent, name: name, store: signIns, deadline: deadline, caller: caller, pid: pid, fail: fail) {
                guard let refresher = refresher(record, key: key) else { return fail(MCPHubSignInWords.lapsed(name)) }
                DispatchQueue.global(qos: .userInitiated).async {
                    let outcome = refresher.token()
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            switch outcome {
                            case .token(let token):
                                use(Use(id: record.id, name: name, token: token, refresher: refresher, store: signIns))
                            case .signedOut(let lapse):
                                lapsed(record.id, lapse: lapse, name: name, url: server.url)
                                fail(MCPHubSignInWords.lapsed(name))
                            case .needsMoreAccess(let scopes): fail(MCPHubSignInWords.moreAccess(name, scopes: scopes))
                            case .unreachable: fail(MCPHubSignInWords.unreachable(name))
                            case .missing: use(nil)
                            case .tampered: fail(MCPHubSignInWords.tampered(name))
                            }
                        }
                    }
                }
            }
        }
    }

    /// R15: the first time each agent kind uses each sign-in, the user approves once on the Mac; recorded in the sealed
    /// file, so an agent can't grant itself. Don't Allow refuses that agent for the sign-in until Next Term quits. A need
    /// that outlasts its call while the user decides is told so; an Allow that comes later is kept in the file for the
    /// agent's next need.
    private static func consent(_ record: SignInFile.Record, agent: String, name: String, store: SignInStore, deadline: Date,
                                caller: TerminalTab?, pid: pid_t?, fail: @escaping (String) -> Void, granted: @escaping () -> Void) {
        if record.consents.contains(agent) { return granted() }
        let title = MCPHubSignInWords.agentTitle(agent)
        let ask = record.id + "\u{0}" + agent
        if refused.contains(ask) { return fail(MCPHubSignInWords.declined(agent: title, name)) }
        var answered = false
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow - 1)) {
            guard !answered else { return }
            answered = true
            fail(MCPHubSignInWords.asking(agent: title, name))
        }
        let reply: (Bool) -> Void = { allowed in
            guard !answered else { return }
            answered = true
            if allowed { granted() } else { fail(MCPHubSignInWords.declined(agent: title, name)) }
        }
        if asking[ask] != nil {
            asking[ask]?.append(reply)
            return
        }
        asking[ask] = [reply]
        let words = MCPHubSignInWords.consent(agent: title, name)
        let facts = SecretsMCP.askedBy(caller: caller, pid: pid, requester: nil)
        let requester = [title, facts.tab.map { "in " + $0 }, facts.project.map { "of " + ($0 as NSString).lastPathComponent }]
            .compactMap { $0 }.joined(separator: " ")
        let request = AgentApprovalWindow.Request(title: words.title, requester: requester, agentWords: nil, details: words.details,
                                                  approveTitle: "Allow", declineTitle: "Don\u{2019}t Allow")
        func answer(_ allowed: Bool) {
            panels[ask] = nil
            if allowed {
                try? store.setConsent(id: record.id, agent: agent, allowed: true)
                NotificationCenter.default.post(name: MCPHubControl.changed, object: nil)
            } else {
                refused.insert(ask)
            }
            let waiting = asking.removeValue(forKey: ask) ?? []
            for each in waiting { each(allowed) }
        }
        let window = AgentApprovalWindow(request, approve: { window in
            window.finish()
            answer(true)
        }, decline: { _ in answer(false) })
        panels[ask] = window
        window.present()
    }

    /// Settings' Change…: an agent no longer allowed. Asks for the key when it isn't held.
    static func removeConsent(url: String, agent: String, done: @escaping (String?) -> Void) {
        guard let found = record(for: url) else { return done(nil) }
        withKey(reason: "change who uses your sign-in to \(found.name)", makes: false) { key in
            guard let key else { return done("Not approved, so nothing changed.") }
            do {
                try store(key).setConsent(id: found.id, agent: agent, allowed: false)
                refused.remove(found.id + "\u{0}" + agent)
                NotificationCenter.default.post(name: MCPHubControl.changed, object: nil)
                done(nil)
            } catch {
                done(error.localizedDescription)
            }
        }
    }

    // MARK: lapses

    /// A sign-in lapsed: Settings shows Reconnect, and the user gets one notice for it.
    static func lapsed(_ id: String, lapse: Int, name: String, url: String) {
        refreshers[id] = nil
        NotificationCenter.default.post(name: MCPHubControl.changed, object: nil)
        notice(id, lapse: lapse, name: name, url: url)
    }

    /// One notice for each lapse, keyed by the sign-in and its generation, as program alerts are allowed to show.
    static func notice(_ id: String, lapse: Int, name: String, url: String) {
        guard noticed.insert(id + ":" + String(lapse)).inserted else { return }
        guard NotificationSettings(defaults: .standard).programAlerts else { return }
        let words = MCPHubSignInWords.notice(name)
        let content = UNMutableNotificationContent()
        content.title = words.title
        content.body = words.body
        content.threadIdentifier = "mcp-sign-in"
        content.userInfo = [Self.noticeKey: url]
        AppDelegate.shared.deliver(UNNotificationRequest(identifier: "mcp-sign-in-\(id)-\(lapse)", content: content, trigger: nil))
    }

    nonisolated static let noticeKey = "mcp_sign_in"

    /// The notice, clicked: Settings › MCP Servers with the server selected and Reconnect… beside it.
    static func openReconnect(_ url: String) {
        AppDelegate.shared.showMCPServer(url: url)
    }
}
