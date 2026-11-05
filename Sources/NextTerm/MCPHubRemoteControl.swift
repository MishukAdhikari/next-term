import AppKit
import NextTermCore

/// Remote MCP servers, reached by the app for agents' bridges (MCPHubPlan.remoteTool). The bridge runs as the user under
/// the agent, so a key filled in there, or handed to it over the socket, would be one the agent's own tools could read
/// too; so the bridge sends each need here, and the app alone fills `${secret:NAME}` into the URL and headers, sends the
/// request (MCPHubRemote), and answers with the server's tools or result. The keys are never written, never in an
/// answer (MCPControlServer masks stored values in every one), and never in the bridge.
///
/// - **Which server.** Only an agent in one of this Mac's tabs, and only a server that applies where it works and is
///   ready there, as its plan says, read from the lists as they are now: the bridge's word names it, never decides it.
/// - **Keys.** Released through Secrets' one queue and panel (SecretRequests), as `nxtrm secret run` does for a local
///   server: the panel names the server and its URL, offers "Allow for this session" for the agent's session, and a
///   grant answers the session's later needs with no panel. A need that outlasts its call while the user decides is
///   told so; an approval that comes later is kept two minutes for that agent's next need of the server.
/// - **One connection per server**, shared by every agent: one Mcp-Session-Id, and one sign-in (MCPHubSignIns).
/// - **State.** Each need's end is Settings › MCP Servers' state for the server (MCPHubControl.lastRuns), and its tool
///   list, when it changed, the cached one the next sessions' direct tools are made from (MCPHubManifest).
///
/// - **Signing in** (OAuth, R14): between the keys and the request, the sign-in's state, the agent's consent and a token
///   (MCPHubSignIns.withSignIn); `credentials` adds it as the one more filled header. A 401 to a request that carried
///   a token is refreshed once and sent once more; a second 401 is a lapse, Reconnect in Settings and one notice. A 403
///   `insufficient_scope` asks the user to reconnect with more access. A 401 with a Bearer challenge to a server Next
///   Term has no sign-in for tells the agent to have the user sign in, and Settings shows Sign In….
@MainActor
enum MCPHubRemoteControl {
    /// The connection to each server, by `key`: a server whose URL or headers changed gets a new one.
    static var connections: [String: MCPHubRemote] = [:]
    /// An approval that came after its call stopped waiting: kept for that agent's next need of the server.
    private static var late: [String: (values: [String: String], until: Date)] = [:]

    static var limits: MCPHubUpstream.Limits = .standard

    static func call(_ arguments: [String: Any], caller: TerminalTab?, pid: pid_t?, reply: @escaping MCPControl.Reply) {
        func fail(_ text: String) { reply(MCPServer.CallResult(text: text, isError: true)) }
        guard let folder = MCPHubControl.folder(of: caller) else {
            return fail("Next Term reaches remote MCP servers only for an agent in one of this Mac's tabs.")
        }
        guard let name = arguments["server"] as? String, let list = arguments["list"] as? String, let url = arguments["url"] as? String,
              let op = arguments["op"] as? String, op == "tools" || op == "call" else {
            return fail("That isn't a request Next Term's MCP hub makes.")
        }
        let tool = arguments["tool"] as? String ?? ""
        if op == "call", tool.isEmpty { return fail("Name the tool to call.") }
        let toolArguments = arguments["arguments"] as? [String: Any] ?? [:]
        let seconds = min(limits.call, max(1, (arguments["seconds"] as? NSNumber)?.doubleValue ?? limits.call))
        let deadline = Date().addingTimeInterval(seconds)
        let file = MCPHubControl.userFile ?? MCPHubScope.userPath()
        let tabID = caller?.id.uuidString ?? "" // the tab is found again on the main thread, never carried off it
        DispatchQueue.global(qos: .userInitiated).async {
            let resolution = MCPHubScope.servers(folder: folder, userFile: file)
            let plan = MCPHubPlan.make(resolution, folder: folder, path: [], approved: resolution.approved)
            let applied = resolution.servers.first { $0.name == name && $0.source.file == list }
            let state = plan.server(named: name)?.state
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let applied, applied.server.transport == .http, state == .ready else {
                        return fail("\(name) doesn't apply here now, or isn't ready; mcp_servers lists what does.")
                    }
                    guard applied.server.url == url else {
                        return fail("\(name)'s URL changed in Next Term since this session asked; call again to use the new one.")
                    }
                    let need = Need(server: applied.server, list: list, folder: folder, op: op, tool: tool, arguments: toolArguments,
                                    deadline: deadline, userFile: file)
                    let caller = MCPControl.tab(withID: tabID)
                    withKeys(need, caller: caller, pid: pid, fail: fail) { values in
                        MCPHubSignIns.withSignIn(need.server, deadline: need.deadline, caller: caller, pid: pid, fail: fail) { signIn in
                            reach(need, values: values, signIn: signIn, reply: reply)
                        }
                    }
                }
            }
        }
    }

    struct Need {
        let server: MCPHubServer
        let list: String
        let folder: String
        let op: String
        let tool: String
        let arguments: [String: Any]
        let deadline: Date
        /// The user's list, beside which the server's cached tool list is kept (MCPHubManifest).
        let userFile: String

        var names: [String] {
            var seen = Set<String>()
            return MCPHubRules.secretNames(in: ([server.url] + server.headers.keys.sorted().compactMap { server.headers[$0] })
                .joined(separator: "\n")).filter { seen.insert($0).inserted }
        }

        /// The connection's identity: the server's list, name, URL and headers as written (never a filled value).
        var key: String {
            ([list, server.name, server.url] + server.headers.keys.sorted().map { $0 + ": " + (server.headers[$0] ?? "") })
                .joined(separator: "\u{0}")
        }
    }

    // MARK: keys

    /// The keys the server's URL and headers name, released for this agent (SecretRequests), then `use` with them; none
    /// asked when it names none.
    private static func withKeys(_ need: Need, caller: TerminalTab?, pid: pid_t?, fail: @escaping (String) -> Void,
                                 use: @escaping ([String: String]) -> Void) {
        let names = need.names
        guard !names.isEmpty else { return use([:]) }
        let name = need.server.name
        let keys = SecretReason.keys(names)
        let store = SecretsStore.shared
        store.reloadIfChanged()
        if store.protection == .cantOpen || store.protection == .tampered {
            return fail("\(name) needs \(keys) from Next Term's Secrets, which can't be opened on this Mac; the user can see why in Settings › Secrets.")
        }
        if let missing = names.first(where: { store.index?.entry(named: $0) == nil }) {
            return fail("\(name) needs the key \(missing), which isn't in Next Term's Secrets. Ask the user to add it (request_secret asks "
                + "them), then call again.")
        }
        let asker = MCPWriteControl.asker(connection: nil, requester: nil, caller: caller)
        let lateKey = asker + "\u{0}" + need.key
        if let kept = late.removeValue(forKey: lateKey), kept.until > Date() { return use(kept.values) }
        let facts = SecretsMCP.askedBy(caller: caller, pid: pid, requester: nil)
        let binding = SecretBinding(source: .tool, asker: asker, program: name, command: ["mcp", name, need.server.url],
                                    keys: Dictionary(uniqueKeysWithValues: names.map { ($0, $0) }), folder: need.folder,
                                    target: "mcp:" + need.list)
        let requests = SecretRequests.shared
        if let refusal = requests.precheck(asker: asker, binding: binding, names: names, command: nil, folder: nil) {
            return fail("Next Term didn't ask the user for \(keys) for \(name): " + (SecretsMCP.refusalAnswer(refusal)["note"] as? String ?? "refused."))
        }
        let request = SecretRequests.Request(binding: binding, keys: names.map { SecretRequests.Key(name: $0, envName: $0) },
                                             command: need.server.url, argv: [], folder: need.folder, warnings: [], agentWords: nil,
                                             askedBy: facts, program: name, isRemote: false)
        request.reachesURL = true
        request.titleOverride = "\(SecretsMCP.subject(facts)) asks to reach \(name) with \(keys)"
        // The calling agent's own process (above the bridge), in front of its tab: "Allow for this session" binds to it.
        if let caller, let bridge = pid, let agent = SecretSocket.agentAbove(bridge), SecretSocket.isFrontAgent(agent, in: caller) {
            request.session = SecretRequests.session(agent: agent.pid, in: caller)
        }
        var answered = false
        let waitLeft = max(0, need.deadline.timeIntervalSinceNow - 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + waitLeft) {
            guard !answered else { return }
            answered = true
            fail("Next Term is asking the user on the Mac to let this agent reach \(name) with \(keys). Call again once they have answered.")
        }
        requests.ask(request) { decision in
            var values: [String: String] = [:]
            if case .allowed(let released, _) = decision {
                for (key, value) in released { values[key] = value.utf8String() }
            }
            guard !answered else {
                // The call stopped waiting: an approval is kept for this agent's next need of the server.
                if case .allowed = decision {
                    late[lateKey] = (values, Date().addingTimeInterval(120))
                    // The values are held no longer than their two minutes, used or not.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 121) {
                        MainActor.assumeIsolated {
                            if let kept = late[lateKey], kept.until <= Date() { late[lateKey] = nil }
                        }
                    }
                }
                return
            }
            answered = true
            switch decision {
            case .allowed: use(values)
            case .declined(let stopAsking):
                fail(stopAsking ? "The user chose Decline and Stop Asking, so Next Term won't reach \(name) for you with \(keys) until it quits."
                    : "The user declined letting this agent reach \(name) with \(keys), so nothing was sent.")
            case .refused(let refusal):
                fail("Next Term didn't reach \(name): " + (SecretsMCP.refusalAnswer(refusal)["note"] as? String ?? "refused."))
            case .usedAlready:
                fail("The user chose Allow once, and an identical call used it; call again to be asked again.")
            default:
                fail("Next Term couldn't release \(keys) for \(name)" + ((SecretsMCP.answer(for: decision, tool: "mcp")["note"] as? String).map { ": " + $0 } ?? "."))
            }
        }
    }

    // MARK: reaching

    /// One need of the server, off the main thread, with its keys filled in and its sign-in's token when it has one;
    /// its end is the server's state in Settings.
    private static func reach(_ need: Need, values: [String: String], signIn: MCPHubSignIns.Use?, reply: @escaping MCPControl.Reply) {
        var endpoint: MCPHubRemote.Endpoint
        switch MCPHubRemote.endpoint(for: credentials(need.server, values, token: signIn?.token), values: values) {
        case .failure(let failure): return reply(MCPServer.CallResult(text: failure.text, isError: true))
        case .success(let made): endpoint = made
        }
        endpoint.signedIn = signIn != nil
        let remote = connection(need)
        let at = MCPHubOverview.signInKey(need.server.url)
        DispatchQueue.global(qos: .userInitiated).async {
            func attempt(_ endpoint: MCPHubRemote.Endpoint) -> Result<[String: Any], MCPHubRemote.Failure> {
                let listed = remote.tools(endpoint, until: need.deadline)
                // Its tools as listed now, for the next sessions' direct tools (written only when they changed).
                if case .success(let tools) = listed {
                    let manifest = MCPHubManifest(listed: tools).masked { SecretMask.current.mask($0) }
                    MCPHubManifest.remember(manifest, server: need.server, list: need.list, userFile: need.userFile)
                }
                if need.op == "tools" { return listed.map { ["tools": $0] } }
                // A call is one need, so one approval: the tool's name is checked here, against the list just read.
                return listed.flatMap { tools in
                    let names = tools.compactMap { $0["name"] as? String }
                    guard names.contains(need.tool) else { return .success(["names": names]) }
                    return remote.call(need.tool, arguments: need.arguments, endpoint: endpoint, until: need.deadline)
                        .map { ["result": MCPHubCatalog.fit($0), "names": names] }
                }
            }
            var answer = attempt(endpoint)
            // The sign-in's tokens sent with this need, never in what the agent or Settings is shown, should a server quote one.
            var sent = signIn.map { [$0.token] } ?? []
            func hidden(_ text: String) -> String { sent.reduce(text) { $1.isEmpty ? $0 : $0.replacingOccurrences(of: $1, with: "\u{2022}\u{2022}\u{2022}") } }
            var needsSignIn = false
            var lapse: Int?
            var challenge: String?
            if case .failure(let failure) = answer, case .unauthorized(let status, let header) = failure.kind {
                challenge = header
                let bearer = MCPHubOAuthChallenge.bearer(header)
                if let signIn {
                    if status == 403, bearer?.isInsufficientScope == true {
                        // More access: never fixed silently, since that needs the browser.
                        _ = try? signIn.store.needsMoreAccess(id: signIn.id, scopes: bearer?.scopes ?? [])
                        answer = .failure(MCPHubRemote.Failure(MCPHubSignInWords.moreAccess(need.server.name, scopes: bearer?.scopes ?? []),
                                                               kind: failure.kind))
                    } else if status == 401 {
                        // Refreshed once, and sent once more; a second refusal is a lapse.
                        if case .token(let fresh) = signIn.refresher.token(refused: signIn.token), fresh != signIn.token {
                            var again = endpoint
                            again.headers["Authorization"] = "Bearer " + fresh
                            sent.append(fresh)
                            answer = attempt(again)
                        }
                        if case .failure(let still) = answer, case .unauthorized(401, _) = still.kind {
                            try? signIn.store.signOut(id: signIn.id)
                            lapse = (try? signIn.store.read().get())?.record(id: signIn.id)?.generation ?? 0
                            answer = .failure(MCPHubRemote.Failure(MCPHubSignInWords.lapsed(need.server.name), kind: still.kind))
                        }
                    }
                } else if status == 401, bearer != nil, !endpoint.keyed {
                    needsSignIn = true
                    answer = .failure(MCPHubRemote.Failure(MCPHubSignInWords.needsSignIn(need.server.name), kind: failure.kind))
                }
            }
            let run: MCPHubOverview.Run
            let result: MCPServer.CallResult
            switch answer {
            case .success(let object):
                run = MCPHubOverview.Run(failure: nil, tools: remote.cachedTools?.count ?? 0)
                result = MCPServer.CallResult(text: hidden(MCPServer.json(object)))
            case .failure(let failure):
                // Masked here too, for Settings: a key quoted back in a server's words is never shown there either.
                let text = hidden(SecretMask.current.mask(failure.text))
                run = MCPHubOverview.Run(failure: text, tools: 0, needsSignIn: needsSignIn)
                result = MCPServer.CallResult(text: text, isError: true)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let challenge { MCPHubSignIns.challenges[at] = challenge }
                    if let signIn, let lapse { MCPHubSignIns.lapsed(signIn.id, lapse: lapse, name: need.server.name, url: need.server.url) }
                    let key = MCPHubOverview.runKey(list: need.list, server: need.server.name)
                    if MCPHubControl.lastRuns[key] != run {
                        MCPHubControl.lastRuns[key] = run
                        NotificationCenter.default.post(name: MCPHubControl.changed, object: nil)
                    }
                    reply(result)
                }
            }
        }
    }

    /// The server as it is reached: its own URL and headers, and its sign-in's token as one more header, so the
    /// transport and every need above stay as they are. Made for one need, kept nowhere.
    static func credentials(_ server: MCPHubServer, _ values: [String: String], token: String? = nil) -> MCPHubServer {
        guard let token else { return server }
        var signed = server
        signed.headers["Authorization"] = "Bearer " + token
        return signed
    }

    /// The server's connection: the one made for it as it is written now, or a new one in place of any other.
    private static func connection(_ need: Need) -> MCPHubRemote {
        if let made = connections[need.key] { return made }
        let prefix = need.list + "\u{0}" + need.server.name + "\u{0}"
        // Its URL or headers changed: the old connection goes, and the server ends its session in its own time.
        for old in connections.keys where old.hasPrefix(prefix) { connections[old] = nil }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let made = MCPHubRemote(name: need.server.name, limits: limits, clientVersion: version)
        connections[need.key] = made
        return made
    }
}
