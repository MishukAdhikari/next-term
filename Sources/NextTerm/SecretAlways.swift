import AppKit
import CryptoKit
import NextTermCore
import Security

/// Always approvals in the app: who may get one, what the panel offers, and the grants as the sealed file keeps them
/// (SecretAlwaysFile), with their values once a launch's one Touch ID released them.
///
/// - **Who.** Only an agent in one of Next Term's own local tabs, in front of it (`SecretSocket.isFrontAgent`), by its
///   executable's file and running signature and its script under an interpreter (`identity(of:)`). Never outside the
///   tabs, a remote connection or a request whose agent Next Term can't tell; nothing is offered there.
/// - **What for.** A hub server (Next Term sends the key itself) by its URL, header templates and list; a command only
///   when it is fixed: the rules (`SecretAlwaysRules`) refuse it, with a reason the panel shows, otherwise.
/// - **Once per launch.** The first request a grant answers in a launch asks for Touch ID, with no panel: that unlock
///   releases the file's key, checks the file against the vault's floor and every grant against the unlocked vault, and
///   the values. Then the grant answers with no panel and no Touch ID until Next Term quits; locking the Mac doesn't end
///   it (the owner's choice). A key that asks every time is the same for this one command or server, and asks every time
///   elsewhere.
/// - **Ends.** Settings › Secrets removes a grant (in a Touch ID, which raises the floor so it never comes back); a key
///   changed, renamed or deleted takes its grants and values with it; Start Over takes the file with Secrets' folder.
@MainActor
enum SecretAlways {
    static let changed = Notification.Name("NextTermSecretAlwaysChanged")

    /// What the panel offers one request, and what a grant made from it binds.
    struct Offer {
        /// The agent's kind, for the label alone.
        var agent: String
        var identity: SecretAgentIdentity?
        var door: SecretAlwaysDoor
        var keys: [String: String]
        var definition: SecretAlwaysDefinition
        var places: SecretPlaces
        /// Why Always isn't offered, as the panel says it; nil when it is.
        var refusal: String?
        /// What Settings shows of it: the command, or the server's name and URL.
        var summary: String
        /// A command that only bridges to a server at a URL (`npx mcp-remote <url>`): what "Use as an MCP Server" adds.
        var bridge: SecretAlwaysBridge.Server?

        /// The places offered, widest first; none when refused.
        var scopes: [SecretAlwaysScope.Kind] { refusal == nil && identity != nil ? places.scopes : [] }

        /// The request's facts for matching, with the keys' marks as `index` has them.
        func ask(in index: SecretVault.Index?) -> SecretAlwaysAsk? {
            guard let identity, refusal == nil, let index else { return nil }
            var marks: [String: String] = [:]
            for name in keys.keys {
                guard let entry = index.entry(named: name), !entry.isSignIns else { return nil }
                marks[name] = entry.valueMark
            }
            return SecretAlwaysAsk(identity: identity, door: door, keys: keys, marks: marks, definition: definition.digest,
                                   folder: places.folder, project: places.project,
                                   everyUse: SecretAlwaysGrants.everyUse(Array(keys.keys), in: index))
        }

        /// "Always in app", "Always in window-rail", "Always in this folder".
        func label(_ kind: SecretAlwaysScope.Kind) -> String {
            switch kind {
            case .project: return "Always in \(places.project.map { ($0 as NSString).lastPathComponent } ?? "this project")"
            case .worktree: return "Always in \(places.worktree.map { ($0 as NSString).lastPathComponent } ?? "this worktree")"
            case .folder: return "Always in this folder"
            }
        }
    }

    // MARK: offers

    /// The offer for a command (`run_with_secrets` with `words` nil when its text uses the shell's own syntax, or a
    /// wrapper's argv): nil unless `agent` is the agent in front of `tab`, a local tab of Next Term's.
    static func offer(agent: SecretSocket.Agent?, tab: TerminalTab?, door: SecretAlwaysDoor, words: [String]?, keys: [String: String],
                      folder: String, path: String?, resolved: String? = nil, warned: [String: String], warnings: [String],
                      summary: String) -> Offer? {
        guard let agent, let tab, tab.remote == nil, SecretSocket.isFrontAgent(agent, in: tab) else { return nil }
        return offer(agent: AgentName.of(program: agent.program), identity: identity(of: agent), door: door, words: words, keys: keys,
                     folder: folder, path: path, resolved: resolved, warned: warned, warnings: warnings, summary: summary)
    }

    /// The offer for a command from an agent already known to be in front of its tab, by its label and identity.
    static func offer(agent: String, identity: SecretAgentIdentity?, door: SecretAlwaysDoor, words: [String]?, keys: [String: String],
                      folder: String, path: String?, resolved: String? = nil, warned: [String: String], warnings: [String],
                      summary: String) -> Offer {
        let git = GitRunner.locateGit()
        let places = SecretPlaces.of(canonicalPath(folder), git: git, projects: projects())
        let made = SecretAlwaysFacts.command(door: door, words: words, keys: keys, folder: places.folder, path: path, resolved: resolved,
                                             warned: warned, warnings: warnings, git: git)
        let roots = places.scopes.compactMap(places.path(for:))
        var refusal = SecretAlwaysRules.refusal(made.command, scopes: roots, writable: SecretAlwaysFacts.writable)
        if refusal == nil, identity == nil { refusal = SecretAlwaysRules.lead + "Next Term couldn\u{2019}t tell which program \(agent) is." }
        return Offer(agent: agent, identity: identity, door: door, keys: keys, definition: made.definition, places: places, refusal: refusal,
                     summary: summary, bridge: words.flatMap { SecretAlwaysBridge.server($0, keys: keys) })
    }

    /// The offer for a hub server at a URL: by its URL, its header templates and its list.
    static func offer(agent: SecretSocket.Agent?, tab: TerminalTab?, server: MCPHubServer, list: String, keys: [String: String],
                      folder: String) -> Offer? {
        guard let agent, let tab, tab.remote == nil, SecretSocket.isFrontAgent(agent, in: tab) else { return nil }
        return offer(agent: AgentName.of(program: agent.program), identity: identity(of: agent), server: server, list: list, keys: keys,
                     folder: folder)
    }

    static func offer(agent: String, identity: SecretAgentIdentity?, server: MCPHubServer, list: String, keys: [String: String],
                      folder: String) -> Offer {
        let places = SecretPlaces.of(canonicalPath(folder), git: GitRunner.locateGit(), projects: projects())
        let definition = SecretAlwaysFacts.hub(url: server.url, headers: server.headers, list: list, keys: keys)
        let refusal: String? = identity == nil ? SecretAlwaysRules.lead + "Next Term couldn\u{2019}t tell which program \(agent) is." : nil
        return Offer(agent: agent, identity: identity, door: .hub, keys: keys, definition: definition, places: places, refusal: refusal,
                     summary: "\(server.name) \u{00B7} \(server.url)", bridge: nil)
    }

    static func projects() -> [String] {
        AppDelegate.shared?.controllers.compactMap(\.project) ?? []
    }

    // MARK: identity

    /// Script digests already read, by path, with the stamp they were read at: a script changed has another stamp.
    private static var scriptDigests: [String: (stamp: SecretFileStamp, digest: String)] = [:]

    /// The agent's identity: its executable resolved, that file's stamp, the Team ID of its running code when that code
    /// is validly signed, and under an interpreter its script (from the agent's own folder when relative) and the
    /// script's SHA-256. Nil when any of it can't be read, or when the file the kernel ran isn't the one its path names
    /// now (a link started one program and was pointed at another since).
    static func identity(of agent: SecretSocket.Agent) -> SecretAgentIdentity? {
        let path = canonicalPath(agent.path)
        guard path.hasPrefix("/"), let ran = ProcessInspector.executablePath(of: agent.pid),
              SecretAlwaysScope.same(canonicalPath(ran), path, caseSensitive: true),
              let stamp = SecretFileStamp.of(path) else { return nil }
        var identity = SecretAgentIdentity(path: path, stamp: stamp, team: team(of: agent.pid))
        if let script = agent.script {
            let base = script.hasPrefix("/") ? nil : ProcessInspector.currentDirectory(of: agent.pid)
            guard script.hasPrefix("/") || base != nil else { return nil }
            let full = canonicalPath(base.map { ($0 as NSString).appendingPathComponent(script) } ?? script)
            guard let scriptStamp = SecretFileStamp.of(full), let digest = scriptDigest(full, stamp: scriptStamp) else { return nil }
            identity.script = full
            identity.scriptDigest = digest
        }
        return identity
    }

    private static func scriptDigest(_ path: String, stamp: SecretFileStamp) -> String? {
        if let known = scriptDigests[path], known.stamp == stamp { return known.digest }
        guard stamp.size <= 256 << 20, let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        scriptDigests[path] = (stamp, digest)
        return digest
    }

    /// The Team ID of the code `pid` runs, when the kernel holds it valid; nil for unsigned or ad hoc code.
    static func team(of pid: pid_t) -> String? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: the grants

    /// The file's key and the vault's floor, once a launch's Touch ID released them.
    private static var store: SecretAlwaysStore?
    /// The grants as the checked file has them, while the key is held.
    private(set) static var grants: [SecretAlwaysGrant] = []
    /// Each grant's values, by its id, once released.
    private static var held: [String: [String: SecretBytes]] = [:]
    private static var observers: [NSObjectProtocol] = []

    static var folder: SecretFolder { SecretsStore.shared.folder }

    /// Settings' list: the checked grants while the key is held, else the file as it reads unchecked (nothing answers
    /// from that).
    static func listed() -> [SecretAlwaysGrant] {
        startObserving()
        if store != nil { return grants }
        guard folder.exists, let data = try? folder.read(SecretAlwaysFile.name, cap: SecretAlwaysFile.maxSize) else { return [] }
        return SecretAlwaysFile.peek(data)?.grants ?? []
    }

    /// The grant that answers `ask` with values held, used now: no panel, no Touch ID.
    static func heldAnswer(_ ask: SecretAlwaysAsk) -> (grant: SecretAlwaysGrant, values: [String: SecretBytes])? {
        guard store != nil, let grant = SecretAlwaysGrants.first(answering: ask, in: grants), let values = held[grant.id] else { return nil }
        used(grant)
        return (grant, values)
    }

    /// Whether the file may hold a grant for `ask`, by its unchecked read: worth the one Touch ID that checks it. With
    /// the key held, the checked grants say. A file an unlock found tampered with asks no Touch ID again until it changes:
    /// a program writing grants of its own into it gets one bare Touch ID at most, which releases nothing.
    static func mightAnswer(_ ask: SecretAlwaysAsk) -> Bool {
        if store != nil { return SecretAlwaysGrants.first(answering: ask, in: grants) != nil }
        if let tampered, (try? folder.read(SecretAlwaysFile.name, cap: SecretAlwaysFile.maxSize)) == tampered { return false }
        return SecretAlwaysGrants.first(answering: ask, in: listed()) != nil
    }

    /// The file as an unlock found it tampered with, this launch.
    private static var tampered: Data?

    /// What an unlock read and released, carried out of the store's queue.
    private final class Released: @unchecked Sendable {
        var store: SecretAlwaysStore?
        var grants: [SecretAlwaysGrant] = []
        var grant: SecretAlwaysGrant?
        var values: [String: SecretBytes] = [:]
        var tampered = false
    }

    /// One Touch ID, with no panel: the file's key, the file checked against the vault's floor and each grant against the
    /// unlocked vault (a grant whose key changed goes), and when one answers `ask`, its keys' values, held until quit.
    /// Nil when none answers, the file was tampered with, or the user cancelled.
    static func unlockAndAnswer(_ ask: SecretAlwaysAsk, reason: String) async -> (grant: SecretAlwaysGrant, values: [String: SecretBytes])? {
        let folder = folder
        let released = Released()
        let names = ask.keys.keys.sorted()
        let index = try? await SecretsStore.shared.run(makes: false, names: names, reason: reason, change: { vault, _ in
            let always = SecretAlwaysStore(folder: folder, key: try vault.companionKey(SecretAlwaysFile.keyInfo),
                                           floor: vault.index.floor(of: SecretAlwaysFile.name))
            released.store = always
            guard case .success(let body) = always.read() else {
                released.tampered = true
                return nil
            }
            let kept = SecretAlwaysGrants.kept(body.grants, in: vault.index)
            if kept.count != body.grants.count {
                _ = try? always.update { body in
                    body.grants = SecretAlwaysGrants.kept(body.grants, in: vault.index)
                    return (true, ())
                }
            }
            released.grants = kept
            // Decided from the unlocked vault: the keys' marks as it has them, never the unchecked index's.
            var checked = ask
            checked.marks = Dictionary(uniqueKeysWithValues: names.compactMap { name in vault.index.entry(named: name).map { (name, $0.valueMark) } })
            checked.everyUse = SecretAlwaysGrants.everyUse(names, in: vault.index)
            guard let grant = SecretAlwaysGrants.first(answering: checked, in: kept) else { return nil }
            released.grant = grant
            for name in names { released.values[name] = try vault.value(of: name) }
            return nil
        }, line: nil)
        guard index != nil, let always = released.store else { return nil }
        if released.tampered {
            tampered = try? folder.read(SecretAlwaysFile.name, cap: SecretAlwaysFile.maxSize)
            SecretsStore.shared.record(SecretAudit.Line(event: .tamper, names: names, outcome: "always.json changed outside Next Term: no Always approval used"))
            return nil
        }
        take(always, grants: released.grants)
        guard let grant = released.grant else { return nil }
        held[grant.id] = released.values
        used(grant)
        return (grant, copies(released.values))
    }

    /// Allow with an Always choice: one Touch ID releases the keys' values, keeps the grant (the keys' marks as the
    /// unlocked vault has them) and raises the vault's floor past it. Returns the values; the grant's are held until quit.
    static func allow(_ offer: Offer, scope kind: SecretAlwaysScope.Kind, reason: String,
                      line: SecretAudit.Line) async throws -> [String: SecretBytes] {
        guard let identity = offer.identity, offer.refusal == nil, let root = offer.places.path(for: kind),
              let scope = SecretAlwaysScope.at(root, kind: kind) else { throw SecretsStore.Failure.vault(.badName) }
        let folder = folder
        let released = Released()
        let names = offer.keys.keys.sorted()
        let definition = offer.definition.digest
        try await SecretsStore.shared.run(makes: false, names: names, reason: reason, change: { vault, _ in
            for name in names { released.values[name] = try vault.value(of: name) }
            var marks: [String: String] = [:]
            for name in names {
                guard let entry = vault.index.entry(named: name), !entry.isSignIns else { throw SecretVault.Failure.noSuchKey(name) }
                marks[name] = entry.valueMark
            }
            let grant = SecretAlwaysGrant(agent: offer.agent, identity: identity, door: offer.door, keys: offer.keys, marks: marks,
                                          everyUse: Array(SecretAlwaysGrants.everyUse(names, in: vault.index)), definition: definition,
                                          summary: offer.summary, scope: scope)
            let always = SecretAlwaysStore(folder: folder, key: try vault.companionKey(SecretAlwaysFile.keyInfo),
                                           floor: vault.index.floor(of: SecretAlwaysFile.name))
            let written = try always.update(startsOver: true) { body in
                body.grants = SecretAlwaysGrants.adding(grant, to: SecretAlwaysGrants.kept(body.grants, in: vault.index))
                return (true, body.grants)
            }
            always.raised(to: written.sequence)
            released.store = always
            released.grants = written.value
            released.grant = grant
            return try vault.raiseFloor(of: SecretAlwaysFile.name, to: written.sequence)
        }, line: { line })
        guard let always = released.store, let grant = released.grant else { throw SecretsStore.Failure.keyring }
        take(always, grants: released.grants)
        held[grant.id] = copies(released.values)
        return released.values
    }

    /// Removes a grant: in a Touch ID, which raises the vault's floor past the file without it, so it never comes back.
    static func remove(_ id: String) async throws {
        let folder = folder
        let released = Released()
        let gone = listed().first { $0.id == id }
        try await SecretsStore.shared.run(makes: false, names: gone?.names ?? [], reason: "remove an Always approval", change: { vault, _ in
            let always = SecretAlwaysStore(folder: folder, key: try vault.companionKey(SecretAlwaysFile.keyInfo),
                                           floor: vault.index.floor(of: SecretAlwaysFile.name))
            // A file changed outside Next Term is started over empty: removing never needs what it held.
            let written = try always.update(startsOver: true) { body in
                body.grants.removeAll { $0.id == id }
                body.grants = SecretAlwaysGrants.kept(body.grants, in: vault.index)
                return (true, body.grants)
            }
            always.raised(to: written.sequence)
            released.store = always
            released.grants = written.value
            return try vault.raiseFloor(of: SecretAlwaysFile.name, to: written.sequence)
        }, line: { SecretAudit.Line(event: .grantEnd, names: gone?.names ?? [], command: gone?.summary, folder: gone?.scope.path,
                                    approval: .always, outcome: "removed in Settings") })
        held[id] = nil
        if let always = released.store { take(always, grants: released.grants) }
    }

    /// A key replaced, renamed or deleted, here or in another copy: its grants go, and their values with them, from the
    /// file too while its key is held (else the next unlock drops them, by their keys' marks).
    static func keysChanged(_ names: [String]) {
        let going = grants.filter { grant in names.contains { grant.keys[$0] != nil } }
        guard !going.isEmpty else { return }
        for grant in going { held[grant.id] = nil }
        grants.removeAll { grant in going.contains { $0.id == grant.id } }
        if let store {
            _ = try? store.update { body in
                body.grants.removeAll { grant in going.contains { $0.id == grant.id } }
                return (true, ())
            }
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Start Over took Secrets' folder, this file with it.
    static func forget() {
        store = nil
        grants = []
        held = [:]
        NotificationCenter.default.post(name: changed, object: nil)
    }

    private static func take(_ always: SecretAlwaysStore, grants made: [SecretAlwaysGrant]) {
        startObserving()
        store = always
        grants = made
        for id in held.keys where !made.contains(where: { $0.id == id }) { held[id] = nil }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// A grant's first use this launch is its last use, in the file (one write a launch, the floor left as it is).
    private static var usedThisLaunch = Set<String>()
    private static func used(_ grant: SecretAlwaysGrant) {
        guard usedThisLaunch.insert(grant.id).inserted, let store else { return }
        let now = Date()
        _ = try? store.update { body in
            guard let at = body.grants.firstIndex(where: { $0.id == grant.id }) else { return (false, ()) }
            body.grants[at].lastUsed = SignInFile.whole(now)
            return (true, ())
        }
        if let at = grants.firstIndex(where: { $0.id == grant.id }) { grants[at].lastUsed = SignInFile.whole(now) }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func startObserving() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(forName: SecretsStore.keysChanged, object: nil, queue: .main) { note in
            let names = note.userInfo?["names"] as? [String] ?? []
            MainActor.assumeIsolated { keysChanged(names) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: SecretsStore.startedOver, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { forget() }
        })
    }

    private static func copies(_ values: [String: SecretBytes]) -> [String: SecretBytes] {
        values.mapValues { value in value.withUnsafeBytes { SecretBytes([UInt8]($0)) } }
    }

    #if DEBUG
    /// The self-test's clean slate: no key held, no grant, no value.
    static func resetForSelfTest() {
        store = nil
        grants = []
        held = [:]
        tampered = nil
        usedThisLaunch = []
        scriptDigests = [:]
    }
    #endif
}
