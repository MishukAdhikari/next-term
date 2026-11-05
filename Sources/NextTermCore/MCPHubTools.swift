import Foundation

/// add_mcp_server and list_mcp_servers (R10): an agent connects an MCP server in Next Term for every agent in its tabs,
/// once the user approves on the Mac, seeing exactly what will run or be reached and where it applies; and reads which
/// servers are connected, with their state, never a key. Next Term's own tools, not the hub's catalog (MCPHubCatalog):
/// listed once the user has a list of servers (MCPServer.listed: before it, tools/list is as it was, R17), deferred (used
/// once in a while, so tool search finds them), as apply_setup and add_task are. The app side is MCPHubAgentTools; this
/// Mac only.
///
/// A key never goes in the list (R13): add_mcp_server takes stored keys by name in `secrets` (a command gets them
/// through `nxtrm secret run`, a URL as its Bearer header) and refuses a value that looks like one, before anyone is
/// asked, pointing the agent to request_secret.
extension MCPServer {
    /// The arguments add_mcp_server takes; any other is refused.
    static let addServerArguments: Set<String> = ["name", "command", "args", "env", "url", "headers", "secrets", "project", "reason"]

    public static let hubTools: [Tool] = [
        Tool(name: "list_mcp_servers", title: "List the MCP servers",
             description: "The MCP servers connected in Next Term, which every agent started in its tabs can use through Next Term (no agent's own config holds them): each one's name, kind (local: a command; remote: a URL), where it applies (all projects, some folders, or a project's own .next-term/mcp.json), and its state: ready (with its tool count once it has started), failed (and why), off, off_here, needs_approval (a project's list the user hasn't approved), not_reached (a remote server), broken (and why) or shadowed. With your tab's project, also what applies there. Never a key, nor what a key holds. This Mac only.",
             inputSchema: #"{"type": "object", "properties": {}, "additionalProperties": false}"#,
             readOnly: true, destructive: false, idempotent: true, timeout: 15, alwaysLoad: false),
        Tool(name: "add_mcp_server", title: "Ask to connect an MCP server",
             description: "Asks the user to connect an MCP server in Next Term, so every agent started in its tabs can use it from then on; no agent's own config is changed. Give name, and command (with args and env) for a local server or url (with headers) for a remote one. Keys never go in: name keys stored in Secrets in secrets (list_secrets shows them; a key not stored: request_secret first). A command gets them through nxtrm secret run, a URL as its Authorization: Bearer header; a value that looks like a key is refused and nothing is asked. The user is asked on the Mac first, seeing exactly what will run or be reached and where it applies, and nothing is added if declined. project: only there; default: every project. Answers added (its name and where it applies), or why not. This Mac only.",
             inputSchema: #"{"type": "object", "properties": {"name": {"type": "string", "description": "The server's name: lowercase letters, digits and - between them, at most 32."}, "command": {"type": "string", "description": "A local server's program, such as npx."}, "args": {"type": "array", "items": {"type": "string"}, "maxItems": 100, "description": "The program's arguments."}, "env": {"type": "object", "additionalProperties": {"type": "string"}, "description": "Environment variables that are not keys."}, "url": {"type": "string", "description": "Instead of command: a remote server's URL (https://)."}, "headers": {"type": "object", "additionalProperties": {"type": "string"}, "description": "A remote server's headers that are not keys; ${secret:NAME} stands for a stored key."}, "secrets": {"type": "array", "items": {"type": "string", "pattern": "^[A-Z][A-Z0-9_]{0,63}(=[A-Z][A-Z0-9_]{0,63})?$"}, "maxItems": 20, "description": "Keys from Secrets, by name: NAME, or NAME=ENVNAME to set it as another variable (a command). A URL takes one, as its Bearer header."}, "project": {"type": "string", "description": "An open project's folder (as list_projects gives it) or its name: the server applies only there. Default: every project."}, "reason": {"type": "string", "description": "Why, in a sentence; shown to the user as your words when they are asked."}}, "required": ["name"], "additionalProperties": false}"#,
             readOnly: false, destructive: true, idempotent: false, timeout: 60, alwaysLoad: false),
    ]

    public static func isHubTool(_ name: String) -> Bool { hubTools.contains { $0.name == name } }

    /// What add_mcp_server asks to add, checked: the server (keys as references, for every project until the app sets
    /// `projects`), the project as given (nil: every project), and the stored keys it names.
    public struct AddServerRequest {
        public var server: MCPHubServer
        public let project: Any?
        public let secrets: [String]
    }

    static let nothingAsked = " Nothing was asked."
    /// The refusal's end for a value that looks like a key.
    public static let useRequestSecret = "Keys never go in Next Term's list: ask the user for it with request_secret (list_secrets "
        + "shows the stored ones), then pass its name in secrets."

    /// add_mcp_server's arguments, checked before anyone is asked: anything wrong is refused with no window.
    public static func addServerRequest(_ arguments: [String: Any]) -> Result<AddServerRequest, MCPToolError> {
        func refuse(_ text: String) -> Result<AddServerRequest, MCPToolError> { .failure(MCPToolError(text + nothingAsked)) }
        if let unknown = arguments.keys.sorted().first(where: { !addServerArguments.contains($0) }) {
            return refuse("add_mcp_server takes no argument \(unknown): only name, command, args, env, url, headers, secrets, project and reason.")
        }
        guard let name = arguments["name"] as? String else { return refuse("Give name: the server's name, such as github.") }
        if let reason = MCPHubRules.nameReason(name) {
            return refuse(reason + " Try \(MCPHubRules.suggestedName(from: name)).")
        }
        for key in ["command", "url", "reason"] where arguments[key] != nil && !(arguments[key] is String) {
            return refuse("\(key) is text.")
        }
        let command = arguments["command"] as? String, url = arguments["url"] as? String
        guard (command == nil) != (url == nil) else {
            return refuse("Give command (a local server's program) or url (a remote server's), one of the two.")
        }
        func strings(_ key: String) -> [String]?? {
            guard let value = arguments[key] else { return .some(nil) }
            guard let list = value as? [Any], list.allSatisfy({ $0 is String }) else { return nil }
            return .some(list.compactMap { $0 as? String })
        }
        func table(_ key: String) -> [String: String]?? {
            guard let value = arguments[key] else { return .some(nil) }
            guard let object = value as? [String: Any], object.values.allSatisfy({ $0 is String }) else { return nil }
            return .some(object.compactMapValues { $0 as? String })
        }
        guard let args = strings("args") else { return refuse("args is a list of words.") }
        guard let secrets = strings("secrets") else { return refuse("secrets is a list of stored keys' names.") }
        guard let env = table("env") else { return refuse("env is an object of text values.") }
        guard let headers = table("headers") else { return refuse("headers is an object of text values.") }
        let names = secrets ?? []
        var pairs: [(name: String, variable: String)] = []
        for item in names {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.allSatisfy(StoredSecretName.isValid), !parts.isEmpty else {
                return refuse("\(item) is not a key's name, nor NAME=ENVNAME: " + StoredSecretName.rule)
            }
            pairs.append((parts[0], parts.count == 2 ? parts[1] : parts[0]))
        }
        var server: MCPHubServer
        if let command {
            if headers != nil { return refuse("headers are for a remote server (url); a command takes env.") }
            let wrapped = MCPHubOverview.wrapped([command] + (args ?? []), keys: pairs)
            server = .local(name, command: wrapped.command, args: wrapped.args, env: env ?? [:])
        } else {
            if args != nil || env != nil { return refuse("args and env are for a local server (command); a URL takes headers.") }
            var all = headers ?? [:]
            if !pairs.isEmpty {
                guard pairs.count == 1, pairs[0].name == pairs[0].variable else {
                    return refuse("A URL takes one key in secrets, by its name alone, as its Bearer header; for another header, use ${secret:NAME} in headers.")
                }
                guard !all.keys.contains(where: { $0.lowercased() == "authorization" }) else {
                    return refuse("headers has an Authorization header already; give the key there as ${secret:\(pairs[0].name)}, or in secrets, not both.")
                }
                all["Authorization"] = "Bearer ${secret:\(pairs[0].name)}"
            }
            server = .remote(name, url: url ?? "", headers: all)
        }
        let reasons = MCPHubRules.reasons(server, place: .user)
        if !reasons.isEmpty {
            let isKey = reasons.contains { $0.contains("looks like a key") || $0.contains("password") }
            return refuse(reasons.joined(separator: " ") + (isKey ? " " + useRequestSecret : ""))
        }
        let used = MCPHubRules.secretNames(in: ([server.url] + Array(server.headers.values)).joined(separator: "\n"))
        return .success(AddServerRequest(server: server, project: arguments["project"], secrets: pairs.map(\.name) + used.filter { !pairs.map(\.name).contains($0) }))
    }

    /// What the user is asked: what will run or be reached, with which keys, and where. `commandShown`: the approval
    /// shows the command line in its own box, so it isn't said again here.
    public static func addServerDetails(_ server: MCPHubServer, appliesTo: String, commandShown: Bool = false) -> String {
        var lines: [String] = []
        let keys = MCPHubOverview.keys(of: server).keys
        if server.transport == .stdio {
            let inner = MCPHubOverview.keys(of: server).inner
            if !commandShown { lines.append("Runs: " + inner.map(ShellQuote.quote).joined(separator: " ")) }
            if !keys.isEmpty {
                lines.append("Keys from Secrets: " + keys.map { $0.name == $0.variable ? $0.name : "\($0.name) as \($0.variable)" }.joined(separator: ", "))
            }
            for (name, value) in server.env.sorted(by: { $0.key < $1.key }) { lines.append("\(name)=\(value)") }
        } else {
            lines.append("Reaches: " + server.url)
            for (name, value) in server.headers.sorted(by: { $0.key < $1.key }) { lines.append("\(name): \(value)") }
            let named = MCPHubRules.secretNames(in: ([server.url] + Array(server.headers.values)).joined(separator: "\n"))
            if !named.isEmpty { lines.append("Keys from Secrets: " + named.joined(separator: ", ")) }
        }
        lines.append("Applies to: " + appliesTo)
        lines.append("")
        lines.append(server.transport == .stdio
            ? "Every agent started in Next Term can use it: it starts in each agent\u{2019}s session, in its project\u{2019}s folder. No agent\u{2019}s own config changes."
            : "Every agent started in Next Term can use it. No agent\u{2019}s own config changes.")
        return lines.joined(separator: "\n")
    }

    // MARK: list_mcp_servers

    /// A state as the answer spells it, and its reason when it has one.
    static func stateFields(_ state: MCPHubOverview.State) -> [String: Any] {
        switch state {
        case .ready(let tools?): return ["state": "ready", "tools": tools]
        case .ready(nil): return ["state": "ready"]
        case .failed(let why): return ["state": "failed", "why": why]
        case .off: return ["state": "off"]
        case .offHere: return ["state": "off_here"]
        case .needsApproval: return ["state": "needs_approval"]
        case .remote: return ["state": "not_reached"]
        case .broken(let reasons): return ["state": "broken", "why": reasons.joined(separator: " ")]
        case .shadowed: return ["state": "shadowed"]
        }
    }

    static func row(_ row: MCPHubOverview.Row, home: String) -> [String: Any] {
        var fields: [String: Any] = ["name": row.name, "list": row.place == .user ? "yours" : row.list]
        if let server = row.server {
            fields["kind"] = server.transport == .stdio ? "local" : "remote"
            if row.place == .user {
                switch server.projects {
                case .all: fields["applies"] = "all projects"
                case .only(let folders): fields["applies"] = folders
                }
            } else {
                fields["applies"] = "this project (its .next-term/mcp.json)"
            }
        }
        fields.merge(stateFields(row.state)) { $1 }
        return fields
    }

    /// list_mcp_servers' answer: the user's list, and what applies in the caller's project when it has one.
    public static func listServersAnswer(personal: [MCPHubOverview.Row], project: (folder: String, rows: [MCPHubOverview.Row])?,
                                         home: String) -> [String: Any] {
        var answer: [String: Any] = ["servers": personal.map { row($0, home: home) }]
        if let project {
            answer["project"] = project.folder
            answer["in_this_project"] = project.rows.map { row($0, home: home) }
        }
        if personal.isEmpty && (project?.rows.isEmpty ?? true) {
            answer["note"] = "No MCP server is connected in Next Term yet. add_mcp_server asks the user to connect one."
        }
        return answer
    }
}
