import Foundation

/// What the app hands an agent's bridge (`nxtrm mcp`) about the MCP hub: the servers that apply where the agent works
/// (MCPHubScope), each with whether the bridge may start it, the folder they run in and the login shell's PATH. The
/// bridge asks once as the session starts (its tool list is fixed from then on), and again whenever the catalog needs
/// a server the session hasn't seen (one connected meanwhile).
///
/// The hub is `isActive` only once a server the bridge can start applies: until then the bridge answers exactly as it
/// did before the hub (R17). A project's list is someone's commit, so its servers wait for the user's approval of that
/// list as it is now (`approved`: its file and digest); a remote server waits for the step that runs them in the app.
public struct MCPHubPlan: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// The bridge starts it on first need.
        case ready
        /// The user turned it off here.
        case off
        /// From a project's list the user hasn't approved as it is now.
        case needsApproval = "needs_approval"
        /// A remote server: Next Term doesn't reach those yet.
        case remote
    }

    public struct Server: Codable, Equatable, Sendable {
        public var name: String
        public var state: State
        /// A local server's program and arguments, as its list has them, and its environment's additions.
        public var command: String
        public var args: [String]
        public var env: [String: String]
        /// A remote server's URL.
        public var url: String
        /// The list it is from.
        public var list: String

        public init(name: String, state: State, command: String = "", args: [String] = [], env: [String: String] = [:],
                    url: String = "", list: String) {
            self.name = name
            self.state = state
            self.command = command
            self.args = args
            self.env = env
            self.url = url
            self.list = list
        }

        /// What it starts, one line, for a listing: the program and its arguments, each quoted as a shell needs it.
        public var commandLine: String { ([command] + args).map(ShellQuote.quote).joined(separator: " ") }
    }

    /// The folder the agent works in: where its local servers run.
    public var folder: String
    /// The login shell's PATH, folder by folder (empty: the bridge's own).
    public var path: [String]
    public var servers: [Server]
    /// Lists and entries Next Term passed over, each a sentence for the agent to pass on.
    public var problems: [String]

    public init(folder: String, path: [String] = [], servers: [Server] = [], problems: [String] = []) {
        self.folder = folder
        self.path = path
        self.servers = servers
        self.problems = problems
    }

    /// A server the bridge can start applies: the catalog is offered.
    public var isActive: Bool { servers.contains { $0.state == .ready } }

    public func server(named name: String) -> Server? { servers.first { $0.name == name } }

    /// The plan for an agent in `folder`: the servers `resolution` applies there, in name order, then the ones turned off.
    /// `approved`: the project lists the user approved, as `file + "\0" + digest`.
    public static func make(_ resolution: MCPHubScope.Resolution, folder: String, path: [String], approved: Set<String> = []) -> MCPHubPlan {
        func server(_ applied: MCPHubScope.Applied, off: Bool) -> Server {
            let found = applied.server
            let state: State
            if off {
                state = .off
            } else if found.transport != .stdio {
                state = .remote
            } else if applied.source.place == .project, !approved.contains(applied.source.file + "\u{0}" + applied.source.digest) {
                state = .needsApproval
            } else {
                state = .ready
            }
            return Server(name: found.name, state: state, command: found.command, args: found.args, env: found.env,
                          url: found.url, list: applied.source.file)
        }
        var problems = resolution.unreadable.map { "\($0.file) can't be read: \($0.problem.reason)" }
        problems += resolution.issues.map { "\($0.name) in \($0.file) is passed over: " + $0.reasons.joined(separator: " ") }
        return MCPHubPlan(folder: folder, path: path,
                          servers: resolution.servers.map { server($0, off: false) } + resolution.off.map { server($0, off: true) },
                          problems: problems)
    }

    // MARK: over the socket

    /// The tool the bridge asks the app with: never listed, and answered only for an agent in a Next Term tab.
    public static let tool = "mcp_hub_plan"

    /// The plan as the app's answer carries it.
    public var text: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// The plan in the app's answer; nil for none (no tab, no server, an answer it can't read).
    public static func decode(_ text: String) -> MCPHubPlan? {
        guard !text.isEmpty else { return nil }
        return try? JSONDecoder().decode(MCPHubPlan.self, from: Data(text.utf8))
    }
}
