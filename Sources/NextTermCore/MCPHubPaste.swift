import Foundation

/// Settings › MCP Servers › Paste a Config…: the servers in a snippet copied from a server's README, ready to add to the
/// user's list. Every common shape is read:
/// - `{"mcpServers": {"github": {…}, …}}` (Claude Code, Cursor and most READMEs), or VS Code's `{"servers": {…}}`, also
///   inside its `"mcp"`;
/// - the servers alone, `{"github": {…}}`, or a member cut out of a bigger file, `"github": {…}`;
/// - one server alone, `{"command": "npx", "args": […]}`, named from its package or its URL's host.
/// Comments and trailing commas are taken (JSONC.plain), and so is a Markdown fence around it. VS Code's and Windsurf's
/// own spellings become the common ones (`serverUrl`, `streamableHttp`).
///
/// Keys never reach the list (R13): a value that looks like one, by Secrets' own detection, is taken out of the entry
/// and listed as a `Key` with a name for Secrets; the entry gets it back as `nxtrm secret run NAME=VARIABLE --` in front
/// of its command, or `${secret:NAME}` in its header (`server(keys:)`). A placeholder the README asks the user to
/// replace (`<YOUR_TOKEN>`) under a key-like name is a key too, with no value: the user gives it, or picks a stored one.
public enum MCPHubPaste {
    /// A key the snippet holds, or asks for.
    public struct Key: Equatable, Sendable {
        public enum Place: Equatable, Sendable {
            /// An environment variable of a local server.
            case env(String)
            /// A header of a remote server.
            case header(String)
        }

        public let place: Place
        /// What it looks like ("GitHub token"), or nil for a placeholder.
        public let kind: String?
        /// The key as pasted; nil for a placeholder, which the user fills in or matches to a stored key.
        public let value: SecretBytes?
        /// The name it gets in Secrets: the variable's, when that is a key's name, else the server's and `TOKEN`.
        public var name: String
        /// A header's text around the key (`Bearer `), kept when `${secret:NAME}` takes its place.
        let prefix: String

        /// Where it was, in words: "GITHUB_TOKEN", "the Authorization header".
        public var whereText: String {
            switch place {
            case .env(let variable): return variable
            case .header(let header): return "the \(header) header"
            }
        }
    }

    /// One server found.
    public struct Found: Equatable, Sendable {
        /// Its name as pasted, and the name it gets (MCPHubRules.suggestedName), which the user may change.
        public let pastedName: String
        public var name: String
        /// The entry as pasted, keys taken out.
        let entry: MCPHubFile.Value
        public var keys: [Key]
        /// Keys Next Term can't take out for the user: in an argument, or a URL. Each a sentence; the server can't be
        /// added until it is fixed by hand.
        public let stuck: [String]

        /// The server with `keys` put back as references to Secrets, named as each key is now, or why it can't be added.
        public func server() -> Result<MCPHubServer, MCPHubServer.Broken> {
            guard stuck.isEmpty else { return .failure(MCPHubServer.Broken(reasons: stuck)) }
            var members = entry.members ?? []
            let isLocal = members.contains { $0.key == "command" }
            if isLocal {
                let pairs = keys.compactMap { key -> (name: String, variable: String)? in
                    if case .env(let variable) = key.place { return (key.name, variable) }
                    return nil
                }
                if !pairs.isEmpty {
                    let command = entry.member("command")?.string ?? ""
                    let args = entry.member("args").flatMap { value -> [String]? in
                        if case .array(let items) = value { return items.compactMap(\.string) }
                        return nil
                    } ?? []
                    let current = MCPHubOverview.keys(of: MCPHubServer.local(name, command: command, args: args))
                    let made = MCPHubOverview.wrapped(current.inner, keys: current.keys + pairs)
                    set("command", .string(made.command), in: &members)
                    set("args", .array(made.args.map { .string($0) }), in: &members)
                }
            } else {
                var headers = entry.member("headers")?.members ?? []
                for key in keys {
                    guard case .header(let header) = key.place else { continue }
                    let value = MCPHubFile.Value.string(key.prefix + "${secret:\(key.name)}")
                    if let at = headers.firstIndex(where: { $0.key == header }) { headers[at].value = value } else {
                        headers.append(MCPHubFile.Member(header, value))
                    }
                }
                if !headers.isEmpty { set("headers", .object(headers), in: &members) }
            }
            return MCPHubServer.decode(name: name, .object(members), place: .user)
        }

        private func set(_ key: String, _ value: MCPHubFile.Value, in members: inout [MCPHubFile.Member]) {
            if let at = members.firstIndex(where: { $0.key == key }) { members[at].value = value } else {
                members.append(MCPHubFile.Member(key, value))
            }
        }
    }

    public enum Problem: Error, Equatable, Sendable {
        /// Not JSON, even read leniently.
        case notJSON
        /// JSON, with no server in it.
        case noServers

        public var sentence: String {
            switch self {
            case .notJSON: return "This isn\u{2019}t a JSON config. Copy the block that starts with { from the server\u{2019}s README."
            case .noServers: return "No MCP server was found in it: a server has a command to run or a url to reach."
            }
        }
    }

    /// The servers in `text`, in its order. `stored`: the names of the keys in Secrets, so a key's name isn't one of
    /// them unless it is that key (a placeholder for it).
    public static func read(_ text: String, stored: Set<String> = []) -> Result<[Found], Problem> {
        guard let root = parse(unfenced(text)) else { return .failure(.notJSON) }
        let entries = servers(in: root)
        guard !entries.isEmpty else { return .failure(.noServers) }
        var taken = Set<String>(), found: [Found] = []
        for (pasted, value) in entries {
            var name = MCPHubRules.suggestedName(from: pasted)
            var number = 2
            while taken.contains(name) { name = MCPHubRules.suggestedName(from: pasted + "-\(number)"); number += 1 }
            taken.insert(name)
            found.append(take(name: name, pasted: pasted, value, stored: stored))
        }
        return .success(found)
    }

    // MARK: reading

    /// The text inside a Markdown fence (```json … ```), or the text.
    static func unfenced(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.components(separatedBy: "\n")
        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// The snippet as a value: whole, or as the members of an object (`"github": {…},` cut out of a file).
    static func parse(_ text: String) -> MCPHubFile.Value? {
        for candidate in [text, "{" + text + "}"] {
            guard let plain = JSONC.plain(candidate), JSONC.isShallow(plain),
                  case .success(let node) = SkillJSONText.parse(Data(plain.utf8)) else { continue }
            let value = MCPHubFile.value(of: node, in: [UInt8](plain.utf8))
            if case .object = value { return value }
        }
        return nil
    }

    /// The servers a value holds, by name, in order.
    static func servers(in root: MCPHubFile.Value) -> [(String, MCPHubFile.Value)] {
        if isServer(root) { return [(guessedName(root), root)] }
        for path in [["mcpServers"], ["servers"], ["mcp", "servers"], ["mcp", "mcpServers"]] {
            var value: MCPHubFile.Value? = root
            for key in path { value = value?.member(key) }
            if let members = value?.members { return members.filter { isServer($0.value) }.map { ($0.key, $0.value) } }
        }
        return (root.members ?? []).filter { isServer($0.value) }.map { ($0.key, $0.value) }
    }

    static func isServer(_ value: MCPHubFile.Value) -> Bool {
        value.members != nil && ["command", "url", "serverUrl", "httpUrl"].contains { value.member($0)?.string != nil }
    }

    /// A name for a server pasted alone: its package (`@scope/server-github` gives `server-github`), or its URL's host.
    static func guessedName(_ value: MCPHubFile.Value) -> String {
        if let url = (value.member("url") ?? value.member("serverUrl") ?? value.member("httpUrl"))?.string,
           let host = URLComponents(string: url)?.host {
            let parts = host.split(separator: ".")
            return String(parts.count > 2 ? parts[parts.count - 2] : parts.first ?? "server")
        }
        let args = value.member("args").flatMap { value -> [String]? in
            if case .array(let items) = value { return items.compactMap(\.string) }
            return nil
        } ?? []
        if let package = args.first(where: { !$0.hasPrefix("-") }) {
            let bare = package.split(separator: "@").first { !$0.isEmpty }.map(String.init) ?? package
            return (bare as NSString).lastPathComponent
        }
        return value.member("command")?.string.map { ($0 as NSString).lastPathComponent } ?? "server"
    }

    /// One entry: spellings made the common ones, and its keys taken out.
    static func take(name: String, pasted: String, _ value: MCPHubFile.Value, stored: Set<String>) -> Found {
        var members = value.members ?? []
        // VS Code's and Windsurf's spellings.
        for at in members.indices {
            if members[at].key == "serverUrl" || members[at].key == "httpUrl" { members[at].key = "url" }
            if members[at].key == "type", let type = members[at].value.string,
               ["streamableHttp", "streamable-http", "streamable_http", "remote"].contains(type) {
                members[at].value = .string("http")
            }
            if members[at].key == "type", members[at].value.string == "local" { members[at].value = .string("stdio") }
        }
        var keys: [Key] = [], stuck: [String] = []
        var keyNames = Set<String>()
        /// A pasted key never takes a stored key's name, so it can't replace one by surprise; a placeholder does, since
        /// it may be asking for that very key.
        func keyName(_ wanted: String, pasted: Bool = true) -> String {
            var name = wanted, number = 2
            while keyNames.contains(name) || (pasted && stored.contains(name)) { name = wanted + "_\(number)"; number += 1 }
            keyNames.insert(name)
            return name
        }
        let fallback = name.uppercased().replacingOccurrences(of: "-", with: "_") + "_TOKEN"

        if let at = members.firstIndex(where: { $0.key == "env" }), let env = members[at].value.members {
            var kept: [MCPHubFile.Member] = []
            for variable in env {
                guard let text = variable.value.string else { kept.append(variable); continue }
                let wanted = StoredSecretName.isValid(variable.key) && !StoredSecretName.isRefusedEnvName(variable.key) ? variable.key : fallback
                if let kind = SecretImport.detect(name: variable.key, value: text) {
                    keys.append(Key(place: .env(variable.key), kind: kind, value: SecretBytes(utf8: text), name: keyName(wanted), prefix: ""))
                } else if SecretImport.nameLooksSecret(variable.key), isAskedFor(text) {
                    keys.append(Key(place: .env(variable.key), kind: nil, value: nil, name: keyName(wanted, pasted: false), prefix: ""))
                } else {
                    kept.append(variable)
                }
            }
            if kept.isEmpty { members.remove(at: at) } else { members[at].value = .object(kept) }
        }
        if let at = members.firstIndex(where: { $0.key == "headers" }), let headers = members[at].value.members {
            var kept: [MCPHubFile.Member] = []
            for header in headers {
                guard let text = header.value.string else { kept.append(header); continue }
                let bearer = text.hasPrefix("Bearer ") ? "Bearer " : ""
                let bare = String(text.dropFirst(bearer.count))
                let looksAsked = (header.key.lowercased() == "authorization" || SecretImport.nameLooksSecret(header.key)) && isAskedFor(bare)
                if let kind = SecretImport.headerKind(name: header.key, value: text) {
                    keys.append(Key(place: .header(header.key), kind: kind, value: SecretBytes(utf8: bare), name: keyName(fallback), prefix: bearer))
                } else if looksAsked {
                    keys.append(Key(place: .header(header.key), kind: nil, value: nil, name: keyName(fallback, pasted: false), prefix: bearer))
                } else {
                    kept.append(header)
                }
            }
            if kept.isEmpty { members.remove(at: at) } else { members[at].value = .object(kept) }
        }
        let args = members.first { $0.key == "args" }.flatMap { member -> [String]? in
            if case .array(let items) = member.value { return items.compactMap(\.string) }
            return nil
        } ?? []
        for found in SecretImport.argumentFindings(args.map { ($0, 0..<0) }) {
            stuck.append("An argument holds what looks like a key (\(found.kind)). Put it in an environment variable instead, and paste again.")
        }
        if let url = members.first(where: { $0.key == "url" })?.value.string,
           let reason = MCPHubRules.urlReason(url), reason.contains("key") || reason.contains("password") {
            stuck.append(reason)
        }
        return Found(pastedName: pasted, name: name, entry: .object(members), keys: keys, stuck: stuck)
    }

    /// A value a README puts where the user's key goes: `<YOUR_TOKEN>`, `your-api-key`, `${GITHUB_TOKEN}`, `sk-...`, or
    /// nothing.
    static func isAskedFor(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || SecretImport.isPlaceholder(trimmed) || SecretImport.isReference(trimmed)
            || (trimmed.hasPrefix("<") && trimmed.hasSuffix(">"))
    }
}
