import Foundation

/// What Settings › MCP Servers lists: the user's own list, entry by entry (Personal), or the servers that apply in a
/// project and why each is in the state it is (Project), from the same reading agents' plans come from (MCPHubScope,
/// MCPHubPlan), so Settings and what an agent gets never disagree. Reads nothing: the caller passes the lists as read,
/// and how each server's last start in an agent's session ended (`runs`, by `runKey`), which only the app knows.
public enum MCPHubOverview {
    public enum State: Equatable, Sendable {
        /// It starts (or, at a URL, is reached) the first time an agent needs it; with the tool count of its last start,
        /// when it had one.
        case ready(tools: Int?)
        /// Its last start in an agent's session failed (or, at a URL, its last need didn't reach it), and why.
        case failed(String)
        /// Its entry turns it off.
        case off
        /// The user turned it off for this project (MCPHubChoices.off).
        case offHere
        /// From a project's list the user hasn't approved as it is now.
        case needsApproval
        /// A remote server of the older HTTP+SSE kind: kept, never reached.
        case remote
        /// It breaks a rule, or is in its file twice: never used.
        case broken([String])
        /// A list nearer in the order has a server of its name (MCPHubScope).
        case shadowed
        /// At a URL: the server asked for a sign-in (a 401 with a Bearer challenge), and Next Term has none for it.
        case needsSignIn
        /// At a URL: signed in through Next Term, with the tool count of its last need when it had one.
        case signedIn(tools: Int?)
        /// At a URL: Next Term's sign-in lapsed (refused, or its refresh token spent); the user reconnects.
        case signedOut
        /// At a URL: the server asked for more access than the sign-in has, these scopes; the user reconnects.
        case needsMoreAccess([String])
    }

    /// A sign-in Next Term keeps for a server at a URL (SignInFile), as Settings shows it.
    public enum SignIn: Equatable, Sendable {
        case signedIn
        case signedOut
        case needsMoreAccess([String])

        public init(_ state: SignInFile.State) {
            switch state {
            case .signedIn, .refreshing: self = .signedIn // a refresh in flight is still signed in
            case .signedOut: self = .signedOut
            case .needsMoreAccess(let scopes): self = .needsMoreAccess(scopes)
            }
        }
    }

    /// Where `signIns` finds a server's sign-in: its URL's canonical form (MCPHubOAuthURL.canonical).
    public static func signInKey(_ url: String) -> String {
        URL(string: url).map(MCPHubOAuthURL.canonical) ?? url
    }

    /// How a server's last start in an agent's session ended.
    public struct Run: Equatable, Sendable {
        public var failure: String?
        public var tools: Int
        /// The failure was a 401 asking for a sign-in Next Term doesn't have.
        public var needsSignIn: Bool

        public init(failure: String?, tools: Int, needsSignIn: Bool = false) {
            self.failure = failure
            self.tools = tools
            self.needsSignIn = needsSignIn
        }
    }

    public static func runKey(list: String, server: String) -> String { list + "\u{0}" + server }

    public struct Row: Equatable, Sendable {
        public let name: String
        /// Nil for an entry that can't be used (`broken`).
        public let server: MCPHubServer?
        /// The list it is in, and that list's place and bytes' digest.
        public let list: String
        public let place: MCPHubFile.Place
        public let digest: String
        public let state: State

        /// At a URL: reached by the app rather than started.
        public var isRemote: Bool { server.map { $0.transport != .stdio } ?? false }
    }

    // MARK: Personal

    /// Every entry of the user's list, in the file's order.
    public static func personal(_ user: MCPHubScope.Source?, runs: [String: Run] = [:], signIns: [String: SignIn] = [:]) -> [Row] {
        guard let user, case .success(let read) = user.read else { return [] }
        var rows: [Row] = [], seen = Set<String>()
        for entry in read.document.entries {
            if read.twice.contains(entry.key) {
                if seen.insert(entry.key).inserted {
                    rows.append(Row(name: entry.key, server: nil, list: user.file, place: .user, digest: user.digest,
                                    state: .broken(["It is in the file twice."])))
                }
                continue
            }
            switch MCPHubServer.decode(name: entry.key, entry.value, place: .user) {
            case .failure(let broken):
                rows.append(Row(name: entry.key, server: nil, list: user.file, place: .user, digest: user.digest, state: .broken(broken.reasons)))
            case .success(let server):
                let state: State = !server.enabled ? .off : server.transport == .sse ? .remote : ran(server, user.file, runs, signIns)
                rows.append(Row(name: server.name, server: server, list: user.file, place: .user, digest: user.digest, state: state))
            }
        }
        return rows
    }

    // MARK: Project

    /// What applies to an agent in `folder`, as its plan has it: the servers that apply, in name order, then the ones
    /// turned off, the shadowed ones and the ones that can't be used.
    public static func project(_ folder: String, user: MCPHubScope.Source?, projects: [MCPHubScope.Source], home: String,
                               runs: [String: Run] = [:], signIns: [String: SignIn] = [:]) -> (rows: [Row], unreadable: [MCPHubScope.Unreadable]) {
        let resolution = MCPHubScope.resolve(folder: folder, user: user, projects: projects, home: home)
        let plan = MCPHubPlan.make(resolution, folder: folder, path: [], approved: resolution.approved)
        func row(_ applied: MCPHubScope.Applied, _ state: State) -> Row {
            Row(name: applied.name, server: applied.server, list: applied.source.file, place: applied.source.place,
                digest: applied.source.digest, state: state)
        }
        var rows: [Row] = resolution.servers.map { applied in
            switch plan.server(named: applied.name)?.state {
            case .needsApproval?: return row(applied, .needsApproval)
            case .remote?: return row(applied, .remote)
            default: return row(applied, ran(applied.server, applied.source.file, runs, signIns))
            }
        }
        rows += resolution.off.map { row($0, resolution.offHere.contains($0.name) ? .offHere : .off) }
        rows += resolution.shadowed.map { row($0, .shadowed) }
        let sources = (user.map { [$0] } ?? []) + projects
        rows += resolution.issues.map { issue in
            let source = sources.first { $0.file == issue.file }
            return Row(name: issue.name, server: nil, list: issue.file, place: source?.place ?? .project, digest: source?.digest ?? "",
                       state: .broken(issue.reasons))
        }
        return (rows, resolution.unreadable)
    }

    /// The state its last need left, and for a server at a URL, its sign-in: a lapse or more access first, since the
    /// next need would end there; a sign-in whose need then failed for another reason shows that reason.
    static func ran(_ server: MCPHubServer, _ list: String, _ runs: [String: Run], _ signIns: [String: SignIn] = [:]) -> State {
        let run = runs[runKey(list: list, server: server.name)]
        let signIn = server.transport == .stdio ? nil : signIns[signInKey(server.url)]
        switch signIn {
        case .signedOut?: return .signedOut
        case .needsMoreAccess(let scopes)?: return .needsMoreAccess(scopes)
        case .signedIn?:
            if let failure = run?.failure, run?.needsSignIn != true { return .failed(failure) }
            return .signedIn(tools: run.flatMap { $0.failure == nil ? $0.tools : nil })
        case nil:
            guard let run else { return .ready(tools: nil) }
            if run.needsSignIn { return .needsSignIn }
            if let failure = run.failure { return .failed(failure) }
            return .ready(tools: run.tools)
        }
    }

    // MARK: words

    /// The state in a few words, for the table. `remote`: a server at a URL, which is reached rather than started.
    public static func stateText(_ state: State, remote: Bool = false) -> String {
        switch state {
        case .ready(let tools?): return "Ready · \(tools) \(tools == 1 ? "tool" : "tools")"
        case .ready(nil): return "Ready"
        case .failed: return remote ? "Couldn\u{2019}t reach" : "Didn\u{2019}t start"
        case .off: return "Off"
        case .offHere: return "Off in this project"
        case .needsApproval: return "Needs your approval"
        case .remote: return "Not reached (SSE)"
        case .broken: return "Can\u{2019}t be used"
        case .shadowed: return "Replaced by another"
        case .needsSignIn: return "Needs sign-in"
        case .signedIn(let tools?): return "Signed in \u{00B7} \(tools) \(tools == 1 ? "tool" : "tools")"
        case .signedIn(nil): return "Signed in"
        case .signedOut: return "Signed out \u{2014} Reconnect\u{2026}"
        case .needsMoreAccess: return "Needs more access \u{2014} Reconnect\u{2026}"
        }
    }

    /// The state in a sentence, for its tooltip.
    public static func stateTip(_ state: State, remote: Bool = false) -> String {
        switch state {
        case .ready(let tools?) where remote:
            return "Next Term reached it for an agent, with \(tools) \(tools == 1 ? "tool" : "tools"). Every agent in Next Term uses the same connection."
        case .ready(nil) where remote:
            return "Next Term reaches it the first time an agent in Next Term uses it, with its keys from Secrets; the agent never gets them."
        case .failed(let why) where remote: return "The last time an agent used it, Next Term couldn\u{2019}t reach it: \(why)"
        case .ready(let tools?): return "It started in an agent\u{2019}s session with \(tools) \(tools == 1 ? "tool" : "tools"). It starts for each session that uses it."
        case .ready(nil): return "It starts the first time an agent in Next Term uses it, in that agent\u{2019}s folder."
        case .failed(let why): return "Its last start in an agent\u{2019}s session failed: \(why)"
        case .off: return "Turned off: agents don\u{2019}t get it."
        case .offHere: return "You turned it off in this project: agents here don\u{2019}t get it."
        case .needsApproval: return "It comes with the project. Nothing in the project\u{2019}s list starts until you approve the list as it is now."
        case .remote: return "It uses the older HTTP+SSE transport, which Next Term doesn\u{2019}t reach. Most servers also answer at a Streamable HTTP URL, often ending in /mcp: use that one."
        case .broken(let reasons): return reasons.joined(separator: " ")
        case .shadowed: return "A server of the same name nearer this project is used instead."
        case .needsSignIn:
            return "It asks you to sign in. Sign in once, and Next Term keeps you signed in for every agent; the agents never get the sign-in."
        case .signedIn(let tools?):
            return "Next Term is signed in to it for your agents, and reached it with \(tools) \(tools == 1 ? "tool" : "tools"). The agents never get the sign-in."
        case .signedIn(nil): return "Next Term is signed in to it for your agents. The agents never get the sign-in."
        case .signedOut: return "Next Term\u{2019}s sign-in lapsed. Reconnect to sign in again; until then agents can\u{2019}t use it."
        case .needsMoreAccess(let scopes):
            return "It needs more access than you gave (\(scopes.joined(separator: " "))). Reconnect to give it; until then agents can\u{2019}t use it for that."
        }
    }

    /// What it runs or reaches, on one line: the program and its arguments as a shell would take them, or the URL.
    public static func runsText(_ server: MCPHubServer) -> String {
        server.transport == .stdio ? ([server.command] + server.args).map(ShellQuote.quote).joined(separator: " ") : server.url
    }

    /// Approve…'s list of a project's servers: each one with what it runs or reaches, then what it sets in its
    /// environment or headers, which change what runs as much as the command does (NODE_OPTIONS, a header naming a
    /// stored key). Every one is listed: an approval covers the whole list, so none may hide behind a count.
    public static func approvalLines(_ entries: [(name: String, server: MCPHubServer)]) -> [String] {
        var lines: [String] = []
        for (name, server) in entries {
            lines.append("\u{2022} \(name): " + runsText(server))
            let set = server.transport == .stdio ? server.env.map { "\($0.key)=\($0.value)" } : server.headers.map { "\($0.key): \($0.value)" }
            lines += set.sorted().map { "    " + $0 }
        }
        return lines
    }

    /// Where a server applies, for the table: all projects, the folders a user's server names, or the project whose
    /// list it is in.
    public static func appliesText(_ row: Row, home: String) -> String {
        if row.place == .project {
            let top = ((row.list as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            return (top as NSString).lastPathComponent + "\u{2019}s list"
        }
        guard let server = row.server else { return "Yours" }
        switch server.projects {
        case .all: return "All projects"
        case .only(let folders): return folders.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        }
    }

    // MARK: commands

    /// A command line as the shell splits it: quotes kept together and taken off, a backslash keeping the next
    /// character. What the Add sheet's one field becomes: the program, then its arguments.
    public static func words(_ line: String) -> [String] { AgentKind.words(line.trimmingCharacters(in: .whitespaces)) }

    /// A local server's keys, as `nxtrm secret run NAME=ENVNAME -- …` in front of its command names them; none when its
    /// command isn't one. `inner`: the command after `--`, and its arguments.
    public static func keys(of server: MCPHubServer) -> (keys: [(name: String, variable: String)], inner: [String]) {
        let words = [server.command] + server.args
        guard server.transport == .stdio, SecretImport.isWrapped(command: words) else { return ([], words) }
        let rest = Array(words.dropFirst((server.command as NSString).lastPathComponent == "nxtrm" ? 3 : 4))
        guard case .success(let invocation) = SecretRun.parse(rest), invocation.ticket == nil else { return ([], words) }
        return (invocation.names.map { ($0, invocation.map[$0] ?? $0) }, invocation.argv)
    }

    /// The command and arguments that start `inner` with these keys in its environment: `nxtrm secret run` in front, or
    /// `inner` itself with none.
    public static func wrapped(_ inner: [String], keys: [(name: String, variable: String)]) -> (command: String, args: [String]) {
        guard !keys.isEmpty else { return (inner.first ?? "", Array(inner.dropFirst())) }
        let pairs = keys.map { $0.name == $0.variable ? $0.name : $0.name + "=" + $0.variable }
        return ("nxtrm", ["secret", "run"] + pairs + ["--"] + inner)
    }
}
