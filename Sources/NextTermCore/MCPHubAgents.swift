import Foundation

/// The MCP servers set up in agents' own configs, for Settings › MCP Servers › Found in your agents (R9) and the one offer
/// Next Term makes for a server added to one after the update (R11). Read with Secrets' own reader of agents' MCP
/// configs (SecretImport.sources and its JSON and TOML walks), and only read: an agent's file is never written for the
/// hub (R4). Each server comes as Paste a Config… would read it (MCPHubPaste.Found), its keys taken out for Secrets, so
/// Add goes the paste path's way.
///
/// One server set up in several agents is one row, naming each agent. Next Term's own entry is never one, and nor is a
/// server the user's list has already (by its name, or by what it runs).
public enum MCPHubAgents {
    public struct Server: Equatable, Sendable {
        /// The name it gets in Next Term's list (MCPHubRules.suggestedName of the agent's).
        public var name: String { found.name }
        /// Its name in the agent's config.
        public var pastedName: String { found.pastedName }
        /// The agents that have it, in the order their files were read, and those files.
        public internal(set) var agents: [SecretImport.Client]
        public internal(set) var files: [String]
        /// The project it is set up for: a project's own file, or a project of Claude Code's `~/.claude.json`.
        public let project: String?
        public let found: MCPHubPaste.Found
        /// What it runs or reaches, its keys left out: the program and its arguments, or the URL.
        public let runs: String

        /// One server, wherever it is set up: its name and what it runs.
        public var id: String { name + "\u{0}" + runs }

        /// The agents in words: "Codex", "Codex and Claude Code", "Codex, Cursor and Claude Code".
        public var agentsText: String { MCPHubAgents.list(agents.map(\.name)) }
    }

    // MARK: reading

    /// The servers in `sources`, in their order, one row a server. `stored`: the names of the keys in Secrets
    /// (MCPHubPaste.read). A file that can't be read adds nothing.
    public static func servers(in sources: [SecretImport.Source], read: (String) -> Data? = SecretImport.readFile,
                               stored: Set<String> = []) -> [Server] {
        merged(sources.map { self.read($0, read: read, stored: stored).servers })
    }

    /// One agent's file as read: not there, there and not read (larger than Secrets reads, not text, not parsed: in the
    /// middle of a save, say), or its servers. The offer tells the last two apart: a file it couldn't read is no baseline.
    public enum FileRead: Equatable, Sendable {
        case missing
        case unreadable
        case read([Server])

        public var servers: [Server] {
            if case .read(let servers) = self { return servers }
            return []
        }
    }

    /// The servers in one file.
    public static func read(_ source: SecretImport.Source, read: (String) -> Data? = SecretImport.readFile,
                            stored: Set<String> = []) -> FileRead {
        guard let data = read(source.path) else { return FileManager.default.fileExists(atPath: source.path) ? .unreadable : .missing }
        guard let text = SecretImport.text(of: data), let entries = entries(of: source, text: text) else { return .unreadable }
        return .read(entries.compactMap { name, value, project in
            guard !isNextTerms(name, value) else { return nil }
            let found = MCPHubPaste.take(name: MCPHubRules.suggestedName(from: name), pasted: name, value, stored: stored)
            return Server(agents: [source.client], files: [source.path], project: project ?? source.project, found: found, runs: runsText(found))
        })
    }

    /// Files' servers read one by one (so the app reads again only a file that changed), as one list: a server in
    /// several is one row, its agents and files in the order read.
    public static func merged(_ lists: [[Server]]) -> [Server] {
        var rows: [Server] = []
        for server in lists.joined() {
            guard let at = rows.firstIndex(where: { $0.id == server.id }) else { rows.append(server); continue }
            for agent in server.agents where !rows[at].agents.contains(agent) { rows[at].agents.append(agent) }
            for file in server.files where !rows[at].files.contains(file) { rows[at].files.append(file) }
        }
        return rows
    }

    /// The servers not in the user's list yet: none of its names, and none running what one of its servers runs.
    public static func notAdded(_ servers: [Server], user: MCPHubScope.Source?) -> [Server] {
        let rows = MCPHubOverview.personal(user)
        let names = Set(rows.map(\.name))
        let runs = Set(rows.compactMap(\.server).map(inner))
        return servers.filter { !names.contains($0.name) && !runs.contains($0.runs) }
    }

    /// Each server entry of a file, with the project it is set up for (Claude Code's per-project servers). Nil when the
    /// file doesn't parse.
    static func entries(of source: SecretImport.Source, text: String) -> [(name: String, value: MCPHubFile.Value, project: String?)]? {
        switch source.format {
        case .toml: return tomlEntries(text)
        case .json, .strictJSON:
            guard let document = JSONC(text), case .object(let root)? = document.root else { return nil }
            var out: [(String, MCPHubFile.Value, String?)] = []
            for container in SecretImport.containers(of: source, root: root) {
                let project = container.path.count == 3 && container.path[0] == "projects" ? container.path[1] : nil
                for member in container.servers.members {
                    guard case .object = member.value, let value = MCPHubPaste.parse(document.string(member.value.range)) else { continue }
                    out.append((member.key, value, project))
                }
            }
            return out
        }
    }

    /// Codex's `[mcp_servers.NAME]` tables as the common shape: `command`, `args`, `env` (inline, dotted or its own
    /// table), `url`, `http_headers` as `headers`, and `bearer_token_env_var` as the `Authorization` header asking for
    /// that key.
    static func tomlEntries(_ text: String) -> [(name: String, value: MCPHubFile.Value, project: String?)]? {
        guard let outline = TOMLOutline(text) else { return nil }
        let reader = SecretImport.TOMLReader(outline)
        var out: [(String, MCPHubFile.Value, String?)] = []
        for table in SecretImport.tomlLayout(outline).tables where !table.isRepeated {
            var members: [MCPHubFile.Member] = []
            var env: [MCPHubFile.Member] = [], headers: [MCPHubFile.Member] = []
            for key in table.keys + table.envKeys {
                let full = key.table + key.path
                guard full.count >= 3, full[0] == "mcp_servers", full[1] == table.name else { continue }
                let path = Array(full.dropFirst(2))
                switch path {
                case ["command"], ["url"]:
                    if let (_, value) = outline.string(at: key.value) { members.append(MCPHubFile.Member(path[0], .string(value))) }
                case ["args"]:
                    if let (elements, _) = reader.strings(at: key.value) {
                        members.append(MCPHubFile.Member("args", .array(elements.map { .string($0.value) })))
                    }
                case ["env"], ["http_headers"]:
                    for member in reader.members(at: key.value)?.members ?? [] {
                        guard let value = member.value?.text else { continue }
                        let pair = MCPHubFile.Member(member.key, .string(value))
                        if path == ["env"] { env.append(pair) } else { headers.append(pair) }
                    }
                case ["bearer_token_env_var"]:
                    if let (_, variable) = outline.string(at: key.value) {
                        headers.append(MCPHubFile.Member("Authorization", .string("Bearer ${\(variable)}")))
                    }
                default:
                    if path.count == 2, path[0] == "env", let (_, value) = outline.string(at: key.value) {
                        env.append(MCPHubFile.Member(path[1], .string(value)))
                    }
                }
            }
            if !env.isEmpty { members.append(MCPHubFile.Member("env", .object(env))) }
            if !headers.isEmpty { members.append(MCPHubFile.Member("headers", .object(headers))) }
            let value = MCPHubFile.Value.object(members)
            guard MCPHubPaste.isServer(value) else { continue }
            out.append((table.name, value, nil))
        }
        return out
    }

    /// Next Term's own entry, which agent control writes: by its name, or a command that is `nxtrm mcp`.
    static func isNextTerms(_ name: String, _ value: MCPHubFile.Value) -> Bool {
        if name == MCPRegistrar.serverName { return true }
        let words = commandWords(value)
        guard words.last == "mcp", let first = words.first else { return false }
        return (first as NSString).lastPathComponent == "nxtrm" || words.contains("--cli")
    }

    /// An entry's program and arguments (OpenCode's one array, or `command` and `args`).
    static func commandWords(_ value: MCPHubFile.Value) -> [String] {
        func strings(_ value: MCPHubFile.Value?) -> [String] {
            if case .array(let items)? = value { return items.compactMap(\.string) }
            return []
        }
        if let command = value.member("command")?.string { return [command] + strings(value.member("args")) }
        return strings(value.member("command"))
    }

    /// What a found server runs, its keys left out: the command inside `nxtrm secret run`, or the URL. A key the paste
    /// path can't take out (in an argument, in the URL: that server can't be added as it is) is masked, so Settings never
    /// shows it.
    static func runsText(_ found: MCPHubPaste.Found) -> String {
        if let url = found.entry.member("url")?.string { return CommandSecrets.mask(url) }
        let words = commandWords(found.entry)
        return CommandSecrets.mask(inner(.local(found.name, command: words.first ?? "", args: Array(words.dropFirst()))))
    }

    /// The same for a server of the user's list.
    static func inner(_ server: MCPHubServer) -> String {
        guard server.transport == .stdio else { return server.url }
        return MCPHubOverview.keys(of: server).inner.map(ShellQuote.quote).joined(separator: " ")
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return names[0] + " and " + names[1]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    // MARK: the offer (R11)

    /// What the offer has seen: the servers' names, and the files whose servers were the baseline.
    public struct Seen: Equatable, Sendable {
        public var servers: Set<String>
        public var files: Set<String>

        public init(servers: Set<String> = [], files: Set<String> = []) {
            self.servers = servers
            self.files = files
        }
    }

    /// What is due for an offer now, from each agent's file as read (`files`, in the order read). `seen`: nil the first
    /// time this version looks. A file's servers are its baseline, seen and never offered, the first time it is read
    /// (R11, R17): at that first look, or later for one that couldn't be read then (larger than Secrets reads, or caught
    /// in the middle of a save), so an update never offers what was already there. A file not there at the first look
    /// is a baseline with nothing in it: what it gets later is news. `added`: the names in the user's list, which are
    /// seen as they are found. Gives the servers to offer (one a name, merged across files, in their order) and `seen`
    /// as it is now; the caller adds each offered server to it as the offer shows, so none is ever offered twice.
    public static func due(_ files: [(path: String, read: FileRead)], seen: Seen?, added: Set<String>) -> (offer: [Server], seen: Seen) {
        let first = seen == nil
        var seen = seen ?? Seen()
        for (path, read) in files where !seen.files.contains(path) {
            switch read {
            case .missing:
                if first { seen.files.insert(path) }
            case .unreadable: break
            case .read(let servers):
                seen.servers.formUnion(servers.map(\.name))
                seen.files.insert(path)
            }
        }
        var offer: [Server] = []
        for server in merged(files.map(\.read.servers)) where !seen.servers.contains(server.name) {
            if added.contains(server.name) {
                seen.servers.insert(server.name)
            } else if !offer.contains(where: { $0.name == server.name }) {
                offer.append(server)
            }
        }
        return (offer, seen)
    }

    /// The offer's sentence: “linear” is new in Codex. Use it in every agent? The server's name leads, so a narrow
    /// window that cuts the sentence short still says which server it is.
    public static func offerText(_ server: Server) -> String {
        "\u{201C}\(server.pastedName)\u{201D} is new in \(server.agentsText). Use it in every agent?"
    }
}
