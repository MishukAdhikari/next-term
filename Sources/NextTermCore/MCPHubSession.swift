import Foundation

/// The MCP hub in one agent session's bridge (`nxtrm mcp`): the plan the app gave as the session started, the local
/// servers started for it (MCPHubUpstream, one per server, on first need), the remote ones the app reaches for it
/// (`remote`, MCPHubPlan.remoteTool), and the catalog's answers (MCPHubCatalog).
/// Its servers end with it (`stop`), as the session ends (R16): one copy each per session, so a server that keeps state
/// for its client keeps it for this agent alone.
///
/// The catalog is offered for the whole session once its first plan `isActive`, and not at all otherwise: the tool list
/// is fixed when a session starts. A server connected meanwhile is still reached: a name the plan doesn't have, and
/// every mcp_servers, ask the app again (`refresh`).
///
/// TODO(MCP hub step 4, R7): a server the calling agent already has in its own config is not passed over yet. The
/// importer's reader (SecretImport.sources and its entries) sees an agent's files, but not reliably what the agent
/// loads from them: an entry turned off (Codex's `enabled = false`, Claude Code's disabledMcpServers), a project's
/// `.mcp.json` the user hasn't approved in Claude Code, plugins' and managed servers, `--mcp-config` and `-c` flags, and
/// profiles are all outside it; and a match would have to be by command and arguments, which an `nxtrm secret run` or
/// `npx -y` changes. Passing over a server on a wrong guess would hide tools the agent doesn't have. The catalog's three
/// tools never repeat an agent's own; direct tools (step 4) would, and need this settled first.
public final class MCPHubSession: @unchecked Sendable {
    public typealias Refresh = @Sendable () -> MCPHubPlan?
    /// Told when a server's start ends otherwise than its last one did: its name, its list, and why it failed (nil: it
    /// runs, with this many tools). The bridge passes it on to the app, for Settings › MCP Servers to show.
    public typealias Report = @Sendable (_ server: String, _ list: String, _ failure: String?, _ tools: Int) -> Void
    /// Asks the app to reach a remote server (MCPHubPlan.remoteTool's arguments), waiting at most `wait` seconds: its
    /// answer's text and whether it is an error, or nil when the app didn't answer. The keys stay in the app: a server
    /// at a URL gets them in its headers from there, and nothing the bridge holds or the agent can read has them.
    public typealias Remote = @Sendable (_ arguments: [String: Any], _ wait: TimeInterval) -> (text: String, isError: Bool)?

    /// Whether the catalog is offered: fixed as the session starts.
    public let isActive: Bool
    private var plan: MCPHubPlan
    private let refresh: Refresh
    private let report: Report?
    private let remote: Remote?
    /// What `nxtrm` is to this bridge: its own program, so `nxtrm secret run` needs nothing on PATH.
    private let nxtrm: [String]
    private let environment: [String: String]
    private let limits: MCPHubUpstream.Limits
    private let version: String
    private let lock = NSLock()
    private var upstreams: [String: MCPHubUpstream] = [:]
    /// The session ended (`stop`): no server is made or started from then on.
    private var stopped = false
    /// How each remote server's last need ended, for mcp_servers: the app reaches them, so this is what the bridge saw.
    private var remoteStatus: [String: MCPHubUpstream.Status] = [:]

    /// `environment`: the bridge's own, which a server's starts from. `nxtrm`: the program and first arguments `nxtrm`
    /// stands for.
    public init(plan: MCPHubPlan?, refresh: @escaping Refresh, nxtrm: [String], environment: [String: String],
                limits: MCPHubUpstream.Limits = .standard, version: String, report: Report? = nil, remote: Remote? = nil) {
        self.plan = plan ?? MCPHubPlan(folder: "")
        isActive = plan?.isActive ?? false
        self.refresh = refresh
        self.report = report
        self.remote = remote
        self.nxtrm = nxtrm
        self.environment = environment
        self.limits = limits
        self.version = version
    }

    /// The tools listed after Next Term's own: none until a server applies.
    public var tools: [MCPServer.Tool] { isActive ? MCPHubCatalog.tools : [] }

    /// Ends every server it started, and any a call in flight is starting.
    public func stop() {
        lock.lock()
        stopped = true
        let running = Array(upstreams.values)
        upstreams = [:]
        lock.unlock()
        DispatchQueue.concurrentPerform(iterations: running.count) { running[$0].retire() }
    }

    // MARK: the catalog

    /// One catalog tool's answer: a tool result, for the agent.
    public func call(_ tool: String, _ arguments: [String: Any]) -> [String: Any] {
        let deadline = Date().addingTimeInterval(limits.call)
        switch tool {
        case "mcp_servers": return servers()
        case "mcp_tools": return toolsAnswer(arguments, until: deadline)
        case "mcp_call": return callAnswer(arguments, until: deadline)
        default: return MCPHubCatalog.text("Unknown tool \(tool).", isError: true)
        }
    }

    private func servers() -> [String: Any] {
        renew()
        let current = currentPlan
        guard !current.servers.isEmpty else {
            return MCPHubCatalog.text("No MCP server the user connected in Next Term applies in \(current.folder) now.")
        }
        let listed: [[String: Any]] = current.servers.map { server in
            var item: [String: Any] = ["name": server.name, "state": server.state.rawValue, "list": server.list]
            if server.isRemote { item["url"] = server.url } else { item["command"] = server.commandLine }
            if server.state == .needsApproval {
                item["note"] = "Its project's list is waiting for the user's approval in Next Term; it doesn't start until then."
            }
            if server.state == .remote {
                item["note"] = "It uses the older HTTP+SSE transport, which Next Term doesn't reach; its Streamable HTTP URL (often ending in /mcp) works instead."
            }
            if server.state == .ready, server.isRemote {
                switch remoteState(server.name) {
                case .running(let count):
                    item["state"] = "running"
                    item["tools"] = count
                case .failed(let why):
                    item["state"] = "failed"
                    item["error"] = why
                case .notStarted: break
                }
            } else if server.state == .ready {
                switch upstream(server)?.status {
                case .running(let count)?:
                    item["state"] = "running"
                    item["tools"] = count
                case .failed(let why)?:
                    item["state"] = "failed"
                    item["error"] = why
                case .notStarted?: break
                case nil: // its program can't be found
                    item["state"] = "failed"
                    item["error"] = launchFailure(server)
                }
            }
            return item
        }
        var answer: [String: Any] = ["folder": current.folder, "servers": listed]
        if !current.problems.isEmpty { answer["problems"] = current.problems }
        return MCPHubCatalog.text(MCPServer.json(answer))
    }

    private func toolsAnswer(_ arguments: [String: Any], until deadline: Date) -> [String: Any] {
        let words = (arguments["query"] as? String ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        if let name = arguments["server"] as? String, !name.isEmpty {
            let found: [[String: Any]]
            switch tools(of: name, until: deadline) {
            case .failure(let failure): return MCPHubCatalog.text(failure.text, isError: true)
            case .success(let listed): found = listed
            }
            if let wanted = arguments["tool"] as? String, !wanted.isEmpty {
                guard let tool = found.first(where: { $0["name"] as? String == wanted }) else {
                    return MCPHubCatalog.text(missing(wanted, on: name, among: found), isError: true)
                }
                return MCPHubCatalog.text(MCPServer.json(["server": name, "tool": tool]))
            }
            let shown = found.filter { MCPHubCatalog.matches($0, words: words) }.map(MCPHubCatalog.brief)
            return MCPHubCatalog.text(MCPServer.json(["server": name, "tools": shown]))
        }
        if arguments["tool"] != nil { return MCPHubCatalog.text("Name the server the tool is on; mcp_servers lists them.", isError: true) }
        // Every server that can start, at once: one slow to start holds up only its own part of the answer.
        let ready = currentPlan.servers.filter { $0.state == .ready }
        guard !ready.isEmpty else { return MCPHubCatalog.text("No MCP server the user connected in Next Term can start here.", isError: true) }
        let results = Results(count: ready.count)
        DispatchQueue.concurrentPerform(iterations: ready.count) { index in
            results.set(index, tools(of: ready[index].name, until: deadline))
        }
        var servers: [[String: Any]] = []
        for (server, result) in zip(ready, results.all) {
            switch result {
            case .success(let listed)?:
                let shown = listed.filter { MCPHubCatalog.matches($0, words: words) }.map(MCPHubCatalog.brief)
                if !shown.isEmpty || words.isEmpty { servers.append(["server": server.name, "tools": shown]) }
            case .failure(let failure)?: servers.append(["server": server.name, "error": failure.text])
            case nil: break
            }
        }
        return MCPHubCatalog.text(MCPServer.json(["servers": servers]))
    }

    private func callAnswer(_ arguments: [String: Any], until deadline: Date) -> [String: Any] {
        guard let name = arguments["server"] as? String, !name.isEmpty, let tool = arguments["tool"] as? String, !tool.isEmpty else {
            return MCPHubCatalog.text("mcp_call takes a server and a tool; mcp_servers and mcp_tools list them.", isError: true)
        }
        if arguments["arguments"] != nil, !(arguments["arguments"] is [String: Any]) {
            return MCPHubCatalog.text("arguments is an object of the tool's arguments; mcp_tools gives its schema.", isError: true)
        }
        let listed: [[String: Any]]
        switch tools(of: name, until: deadline) {
        case .failure(let failure): return MCPHubCatalog.text(failure.text, isError: true)
        case .success(let found): listed = found
        }
        guard listed.contains(where: { $0["name"] as? String == tool }) else {
            return MCPHubCatalog.text(missing(tool, on: name, among: listed), isError: true)
        }
        if let server = currentPlan.server(named: name), server.isRemote {
            switch reach(server, ["op": "call", "tool": tool, "arguments": arguments["arguments"] as? [String: Any] ?? [:]], until: deadline) {
            case .failure(let failure): return MCPHubCatalog.text(failure.text, isError: true)
            case .success(let answer):
                guard let result = answer["result"] as? [String: Any] else {
                    return MCPHubCatalog.text("Next Term's answer for \(name) had no tool result in it.", isError: true)
                }
                return MCPHubCatalog.fit(result)
            }
        }
        guard let upstream = upstream(named: name) else { return MCPHubCatalog.text("\(name) is gone from Next Term's list.", isError: true) }
        switch upstream.call(tool, arguments: arguments["arguments"] as? [String: Any] ?? [:], until: deadline) {
        case .failure(let failure): return MCPHubCatalog.text(failure.text, isError: true)
        case .success(let result): return MCPHubCatalog.fit(result)
        }
    }

    private func missing(_ tool: String, on server: String, among listed: [[String: Any]]) -> String {
        let names = listed.compactMap { $0["name"] as? String }
        return "\(server) has no tool named \(tool). Its tools: " + (names.isEmpty ? "none" : MCPProjects.listed(names, limit: 30)) + "."
    }

    // MARK: servers

    private var currentPlan: MCPHubPlan {
        lock.lock()
        defer { lock.unlock() }
        return plan
    }

    /// The app's plan now, when it answers: a server whose launch changed, or that is gone, is stopped.
    private func renew() {
        guard let fresh = refresh() else { return }
        lock.lock()
        plan = fresh
        var stale: [MCPHubUpstream] = []
        for (name, running) in upstreams {
            let now = fresh.server(named: name).flatMap { $0.state == .ready ? try? launch($0, in: fresh).get() : nil }
            if now != running.launch {
                stale.append(running)
                upstreams[name] = nil
            }
        }
        lock.unlock()
        stale.forEach { $0.retire() }
    }

    /// A ready server's tools, starting it if it isn't running; a name the plan doesn't have asks the app again first.
    private func tools(of name: String, until deadline: Date) -> Result<[[String: Any]], MCPHubUpstream.Failure> {
        if currentPlan.server(named: name) == nil { renew() }
        guard let server = currentPlan.server(named: name) else {
            let names = currentPlan.servers.map(\.name)
            return .failure(.init("No MCP server named \(name) applies here. " + (names.isEmpty ? "None does." : "These do: " + names.joined(separator: ", ") + ".")))
        }
        switch server.state {
        case .ready: break
        case .off: return .failure(.init("\(name) is turned off for this folder in Next Term."))
        case .needsApproval:
            return .failure(.init("\(name) is in \(server.list), a project's list the user hasn't approved in Next Term; it doesn't start until then."))
        case .remote:
            return .failure(.init("\(name) uses the older HTTP+SSE transport, which Next Term doesn't reach; ask the user to use its "
                + "Streamable HTTP URL (often ending in /mcp) in Next Term › Settings › MCP Servers."))
        }
        if server.isRemote {
            return reach(server, ["op": "tools"], until: deadline).flatMap { answer in
                guard let tools = answer["tools"] as? [[String: Any]] else {
                    return .failure(.init("Next Term's answer for \(name) had no tool list in it."))
                }
                return .success(tools)
            }
        }
        guard let upstream = upstream(server) else {
            if isStopped { return .failure(.init("\(name) was stopped: its session is ending.")) }
            let failure = launchFailure(server)
            report?(name, server.list, failure, 0)
            return .failure(.init(failure))
        }
        let before = upstream.status
        let result = upstream.tools(until: deadline)
        let after = upstream.status
        if after != before {
            switch after {
            case .running(let count): if case .running = before {} else { report?(name, server.list, nil, count) }
            case .failed(let why): report?(name, server.list, why, 0)
            case .notStarted: break
            }
        }
        return result
    }

    // MARK: remote servers

    /// One need of a remote server, through the app: its answer as an object, or why not. The bridge waits a little
    /// longer than the app does, so the app's own sentence about a wait that ran out is the one the agent gets.
    private func reach(_ server: MCPHubPlan.Server, _ need: [String: Any], until deadline: Date) -> Result<[String: Any], MCPHubUpstream.Failure> {
        guard let remote else { return .failure(.init("\(server.name) is reached by Next Term, and this session can't ask it.")) }
        let seconds = max(1, deadline.timeIntervalSinceNow)
        var arguments = need
        arguments["server"] = server.name
        arguments["list"] = server.list
        arguments["url"] = server.url
        arguments["seconds"] = seconds
        let result: Result<[String: Any], MCPHubUpstream.Failure>
        if let answer = remote(arguments, seconds + 5) {
            if answer.isError {
                result = .failure(.init(answer.text))
            } else if let object = (try? JSONSerialization.jsonObject(with: Data(answer.text.utf8))) as? [String: Any] {
                result = .success(object)
            } else {
                result = .failure(.init("Next Term's answer for \(server.name) couldn't be read."))
            }
        } else {
            result = .failure(.init("Next Term didn't answer for \(server.name), which it reaches for this session; it may be restarting. Try again in a moment."))
        }
        lock.lock()
        switch result {
        case .success(let answer):
            if let tools = answer["tools"] as? [[String: Any]] { remoteStatus[server.name] = .running(tools: tools.count) }
        case .failure(let failure): remoteStatus[server.name] = .failed(failure.text) // a tool's own error is a result, not this
        }
        lock.unlock()
        return result
    }

    private func remoteState(_ name: String) -> MCPHubUpstream.Status {
        lock.lock()
        defer { lock.unlock() }
        return remoteStatus[name] ?? .notStarted
    }

    private func upstream(named name: String) -> MCPHubUpstream? {
        lock.lock()
        defer { lock.unlock() }
        return upstreams[name]
    }

    /// The server's upstream, made the first time it is needed (it starts later, on its first need); nil when its
    /// program can't be found, or the session ended. One made for another launch is ended, never left running unlisted.
    private func upstream(_ server: MCPHubPlan.Server) -> MCPHubUpstream? {
        guard let wanted = try? launch(server, in: currentPlan).get() else { return nil }
        lock.lock()
        guard !stopped else { lock.unlock(); return nil }
        if let made = upstreams[server.name], made.launch == wanted { lock.unlock(); return made }
        let replaced = upstreams[server.name]
        let made = MCPHubUpstream(name: server.name, launch: wanted, limits: limits, clientVersion: version)
        upstreams[server.name] = made
        lock.unlock()
        replaced?.retire()
        return made
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func launchFailure(_ server: MCPHubPlan.Server) -> String {
        if case .failure(let failure) = launch(server, in: currentPlan) { return failure.text }
        return "\(server.name) didn't start."
    }

    /// What a local server starts: `nxtrm` as this bridge's own program, a path as it is (one relative to the folder the
    /// server runs in), any other program found along the login shell's PATH. Its environment is the bridge's, with
    /// that PATH and the server's own variables.
    func launch(_ server: MCPHubPlan.Server, in current: MCPHubPlan) -> Result<MCPHubUpstream.Launch, MCPHubUpstream.Failure> {
        let path = current.path.isEmpty ? (environment["PATH"] ?? "").split(separator: ":").map(String.init) : current.path
        var variables = environment
        if !current.path.isEmpty { variables["PATH"] = current.path.joined(separator: ":") }
        for (key, value) in server.env { variables[key] = value }
        let executable: String, arguments: [String]
        if server.command == "nxtrm", let own = nxtrm.first {
            executable = own
            arguments = Array(nxtrm.dropFirst()) + server.args
        } else if server.command.contains("/") {
            executable = server.command.hasPrefix("/") ? server.command : (current.folder as NSString).appendingPathComponent(server.command)
            arguments = server.args
        } else {
            guard let found = path.lazy.map({ ($0 as NSString).appendingPathComponent(server.command) })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                return .failure(.init("\(server.name) didn't start: \(server.command) was not found on the login shell's PATH ("
                    + path.joined(separator: ":") + ")."))
            }
            executable = found
            arguments = server.args
        }
        return .success(MCPHubUpstream.Launch(executable: executable, arguments: arguments, environment: variables, directory: current.folder))
    }

    /// Answers gathered from concurrent work, each in its place.
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Result<[[String: Any]], MCPHubUpstream.Failure>?]
        init(count: Int) { values = Array(repeating: nil, count: count) }
        func set(_ index: Int, _ value: Result<[[String: Any]], MCPHubUpstream.Failure>) {
            lock.lock()
            values[index] = value
            lock.unlock()
        }
        var all: [Result<[[String: Any]], MCPHubUpstream.Failure>?] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }
}
