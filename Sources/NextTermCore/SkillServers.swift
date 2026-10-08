import Foundation

// The MCP servers a skill folder brings, for each agent that would use them, and when that agent adds or
// starts them (as of October 2026). Read offline from the folder's own files: no agent runs, and Next
// Term adds, starts, registers and removes none of these servers.
// - Claude Code: the servers of the plugin the folder also is (SkillPackage). Claude Code starts them in
//   every session while the plugin "<name>@skills-dir" is on, unless an installed plugin of that name
//   takes its place (hand check H7).
// - Codex: entries of type mcp in agents/openai.yaml's `dependencies.tools`. When the user names the skill
//   with $name in Codex itself (its CLI, IDE extension or app), Codex offers to add the missing ones to
//   ~/.codex/config.toml, and adds them with no question under approval "never" with full access. It
//   matches what is there by transport and address, keeps a stdio entry's command with no arguments, and
//   skips a name that already has a table (openai/codex @9b73858, core/src/mcp_skill_dependencies.rs, :137).
// - Amp: `mcpServers` in SKILL.md's front matter, else an mcp.json beside it. Amp connects to them, and
//   starts any program among them, when it finds the skill, and shows their tools once the skill loads
//   (ampcode.com/docs/customize/skills). Whether it asks first is not documented.

public struct SkillServers: Equatable, Sendable {
    public typealias Server = SkillPackage.Server

    /// The Claude Code plugin the folder also is, whose servers Claude Code starts; nil for none.
    public let claudePlugin: SkillPackage.ClaudePlugin?
    /// agents/openai.yaml's MCP dependencies, as Codex reads them: `.http` (streamable HTTP) or `.stdio`.
    public let codex: [Server]
    /// agents/openai.yaml as spelled on disk, when it exists.
    public let codexFile: String?
    /// The servers Amp connects to.
    public let amp: [Server]
    /// Where Amp's servers come from: SKILL.md (its front matter) or mcp.json; nil: neither names any.
    public let ampFile: String?
    /// mcp.json beside SKILL.md, which Amp ignores because the front matter names `mcpServers`.
    public let ampIgnored: String?
    /// Files with server entries Next Term could not read.
    public let unread: [SkillPackage.Unread]
    /// SKILL.md's front matter uses YAML forms that can bring in keys Next Term doesn't see: anchors,
    /// aliases, merge keys, tags, `?` keys or lines it can't place.
    public let frontMatterUnread: Bool
    /// SKILL.md as spelled on disk.
    public let skillFile: String

    public var claude: [Server] { claudePlugin?.servers ?? [] }
    public var claudeCount: Int { claudePlugin?.serverCount ?? 0 }

    var hasCodex: Bool { codexFile.map { file in !codex.isEmpty || unread.contains { $0.file == file } } ?? false }
    var ampUnread: Bool {
        guard let ampFile else { return false }
        return unread.contains { $0.file == ampFile } || (ampFile == skillFile && frontMatterUnread)
    }
    var hasAmp: Bool { ampFile != nil && (!amp.isEmpty || ampUnread) }

    /// Amp would start a program of the skill's when it finds it.
    public var ampRunsPrograms: Bool { amp.contains { $0.command != nil } }

    /// The front matter's `mcpServers` was read in full, so the row shows what it holds.
    public var frontMatterServersRead: Bool { ampFile == skillFile && !ampUnread }

    /// No agent would use a server from this folder: the review shows no "Needs MCP servers" row.
    public var isEmpty: Bool { claudeCount == 0 && !hasCodex && !hasAmp }

    /// The files the row lists, in its order.
    public var files: [String] {
        var files: [String] = []
        for server in claude where !files.contains(server.file) { files.append(server.file) }
        if hasCodex, let codexFile { files.append(codexFile) }
        if hasAmp, let ampFile, !files.contains(ampFile) { files.append(ampFile) }
        return files
    }

    /// Reads the servers in a downloaded skill folder. `skillText` is SKILL.md as written.
    public static func read(folder: String, skillText: String, skillFile: String = "SKILL.md", package: SkillPackage?) -> SkillServers {
        let reader = PackageReader(folder: folder, home: nil)
        var unread: [SkillPackage.Unread] = []
        let codex = readCodex(reader)
        unread += codex.unread
        let amp = readAmp(reader, skillText: skillText, skillFile: skillFile)
        unread += amp.unread
        return SkillServers(claudePlugin: package?.claude, codex: codex.servers, codexFile: codex.file, amp: amp.servers,
                            ampFile: amp.file, ampIgnored: amp.ignored, unread: unread, frontMatterUnread: amp.frontMatterUnread,
                            skillFile: skillFile)
    }

    /// The command that names the skill in Codex, as Settings › Skills shows it: `$name`, or
    /// `$plugin:name` when a package manifest gives Codex a namespace.
    public static func codexTrigger(name: String, package: SkillPackage?) -> String {
        guard let plugin = package?.codexName else { return "$" + name }
        return "$" + SkillReview.oneLine(plugin, limit: 60) + ":" + name
    }

    // MARK: flags

    /// What "Worth a look" says about the servers.
    var flags: [SkillReview.Flag] {
        var flags: [SkillReview.Flag] = []
        if frontMatterUnread {
            let text = "\(skillFile)'s front matter uses YAML forms Next Term does not read. Agents may read keys this review doesn't show."
            flags.append(SkillPackage.warning(skillFile, text))
        }
        for server in amp where server.command != nil {
            let name = SkillReview.oneLine(server.name, limit: 60)
            flags.append(SkillPackage.warning(server.file, "Declares an MCP server, “\(name)”, that runs a program. Amp starts it when it finds the skill."))
        }
        for entry in unread {
            let text = "Next Term could not read every MCP server entry in it (\(entry.reason)). An agent may add or start servers this review doesn't show."
            flags.append(SkillPackage.warning(entry.file, text))
        }
        for server in codex + amp where !SkillPackage.isASCII(server.name) { flags.append(SkillPackage.nonASCIIServer(server)) }
        return flags
    }
}

// MARK: - Codex

extension SkillServers {
    /// Codex reads only this name (openai/codex at 9b73858): an `agents/openai.yml` is not a Codex file.
    static let codexPath = "agents/openai.yaml"

    static func readCodex(_ reader: PackageReader) -> (file: String?, servers: [Server], unread: [SkillPackage.Unread]) {
        guard let contents = reader.contents(codexPath) else { return (nil, [], []) }
        let file = reader.spelling(codexPath)
        switch contents {
        case .failure(let unread): return (file, [], [unread])
        case .success(let data):
            let (servers, unread) = codexDependencies(String(decoding: data, as: UTF8.self), file: file)
            return (file, servers, unread)
        }
    }

    /// `dependencies.tools` entries of type mcp, as Codex reads them. Any entry Codex would skip, and any
    /// form the reader doesn't read there, makes the file unread; so does one that mentions MCP and
    /// yields no entry. Never "none" for a file that may hold one.
    static func codexDependencies(_ text: String, file: String) -> ([Server], [SkillPackage.Unread]) {
        let yaml = SkillYAML(text)
        var servers: [Server] = []
        var problems = yaml.problems.map { "it uses YAML Next Term does not read (\($0))" }
        switch yaml.root {
        case .map(let entries):
            let dependencies = entries.filter { $0.key == "dependencies" }
            if dependencies.count > 1 { problems.append("it has the key “dependencies” twice") }
            if let value = dependencies.first?.value { readDependencies(value, file: file, into: &servers, problems: &problems) }
        case .empty: break
        default: problems.append("it is not a map of keys")
        }
        if servers.isEmpty, problems.isEmpty, text.lowercased().contains("mcp") {
            problems.append("it mentions MCP, but holds no MCP entry Next Term could read")
        }
        let unread = problems.first.map { [SkillPackage.Unread(file: file, reason: $0)] } ?? []
        return (servers, unread)
    }

    static func readDependencies(_ value: SkillYAML.Node, file: String, into servers: inout [Server], problems: inout [String]) {
        guard case .map(let entries) = value else {
            if value != .empty { problems.append(form(value) ?? "its dependencies are not a map") }
            return
        }
        let tools = entries.filter { $0.key == "tools" }
        if tools.count > 1 { problems.append("it has the key “tools” twice") }
        guard let list = tools.first?.value, list != .empty else { return }
        guard case .list(let items) = list else { return problems.append(form(list) ?? "its dependencies' tools are not a list") }
        for item in items { readTool(item, file: file, into: &servers, problems: &problems) }
    }

    /// A form the YAML reader does not read, in words; nil for a node it read.
    static func form(_ node: SkillYAML.Node) -> String? {
        switch node {
        case .flow: return "it uses YAML Next Term does not read (a flow collection)"
        case .unread(let why): return "it uses YAML Next Term does not read (\(why))"
        default: return nil
        }
    }

    static func readTool(_ item: SkillYAML.Node, file: String, into servers: inout [Server], problems: inout [String]) {
        guard case .map(let entries) = item else { return problems.append(form(item) ?? "a tool entry is not a map") }
        var fields: [String: String] = [:]
        for entry in entries {
            switch entry.value {
            case .scalar(let text):
                if fields[entry.key] != nil { return problems.append("a tool entry has the key “\(SkillReview.oneLine(entry.key, limit: 40))” twice") }
                fields[entry.key] = text
            case .empty: continue
            default: return problems.append(form(entry.value) ?? "a tool entry holds a list or a map")
            }
        }
        guard let type = fields["type"] else { return problems.append("a tool entry has no type") }
        guard asciiLowercased(type) == "mcp" else { return }
        guard let name = fields["value"], !name.isEmpty else { return problems.append("an MCP entry has no value (its name)") }
        let quoted = "“" + SkillReview.oneLine(name, limit: 60) + "”"
        let transport = fields["transport"].map(asciiLowercased) ?? "streamable_http"
        switch transport {
        case "streamable_http":
            guard let url = fields["url"], trimmed(url) != nil else { return problems.append("its MCP entry \(quoted) has no url") }
            servers.append(Server(name: name, transport: .http, command: nil, args: [], url: url, bundle: nil, headersHelper: nil, file: file))
        case "stdio":
            guard let command = fields["command"], trimmed(command) != nil else { return problems.append("its MCP entry \(quoted) has no command") }
            servers.append(Server(name: name, transport: .stdio, command: command, args: [], url: nil, bundle: nil, headersHelper: nil, file: file))
        default:
            problems.append("its MCP entry \(quoted) has a transport Codex does not add (“\(SkillReview.oneLine(transport, limit: 40))”)")
        }
    }

    /// Codex compares these ignoring ASCII case only.
    static func asciiLowercased(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            (65...90).contains(scalar.value) ? Unicode.Scalar(scalar.value + 32)! : scalar
        }))
    }

    /// Trimmed, as Codex trims an address; nil when nothing is left.
    static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

// MARK: - Codex's config

extension SkillServers {
    /// The `[mcp_servers.<name>]` tables of ~/.codex/config.toml, with their address.
    public struct CodexConfig: Equatable, Sendable {
        public struct Table: Equatable, Sendable {
            public let name: String
            public let url: String?
            public let command: String?

            public init(name: String, url: String?, command: String?) {
                self.name = name
                self.url = url
                self.command = command
            }
        }

        public var tables: [Table]
        /// Every server table was read: no inline table, dotted key or multi-line string that could hold
        /// one. When false, nothing is said to match, and nothing to be missing.
        public var complete: Bool

        public init(tables: [Table] = [], complete: Bool = true) {
            self.tables = tables
            self.complete = complete
        }
    }

    /// What Codex would do with one dependency, given the config.
    public enum CodexStatus: Equatable, Sendable {
        /// Codex offers to add it (or adds it without asking, as the line says).
        case adds
        /// A table with its address is there already, under this name.
        case present(String)
        /// A table of the same name with another address: Codex asks, then keeps that one.
        case keepsYours
        /// The config could not be read in full.
        case unknown
    }

    /// Reads ~/.codex/config.toml in `home`. No file: no tables. A file that can't be read, or is over the
    /// review's 5 MB cap, is incomplete.
    public static func codexConfig(home: String) -> CodexConfig {
        let path = (home as NSString).appendingPathComponent(".codex/config.toml")
        var info = stat()
        guard stat(path, &info) == 0 else { return CodexConfig() }
        guard Int(info.st_size) <= SkillReview.maxReadSize, let data = FileManager.default.contents(atPath: path) else {
            return CodexConfig(complete: false)
        }
        return codexConfig(String(decoding: data, as: UTF8.self))
    }

    /// The server tables in a Codex config's text (nil: no file). `[mcp_servers.x.env]` and other
    /// sub-tables are not servers.
    public static func codexConfig(_ text: String?) -> CodexConfig {
        guard let text else { return CodexConfig() }
        var reader = CodexConfigReader()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) where reader.config.complete {
            reader.read(raw.hasSuffix("\r") ? raw.dropLast() : raw)
        }
        reader.finish()
        return reader.config
    }

    /// Whether a config table is the server a dependency names, as Codex matches them: the transport,
    /// then the URL or command, trimmed. A name alone never matches.
    public static func matches(_ dependency: Server, _ table: CodexConfig.Table) -> Bool {
        if dependency.transport == .stdio {
            guard let wanted = trimmed(dependency.command) else { return false }
            return trimmed(table.command) == wanted
        }
        guard let wanted = trimmed(dependency.url) else { return false }
        return trimmed(table.url) == wanted
    }

    public static func codexStatus(_ dependency: Server, in config: CodexConfig) -> CodexStatus {
        guard config.complete else { return .unknown }
        if let table = config.tables.first(where: { matches(dependency, $0) }) { return .present(table.name) }
        return config.tables.contains { $0.name == dependency.name } ? .keepsYours : .adds
    }
}

/// Reads a Codex config line by line: table headers, `key = value` lines, and arrays over several lines.
/// Anything that could define a server it doesn't see makes the config incomplete.
struct CodexConfigReader {
    var config = SkillServers.CodexConfig()
    /// The current table's key path; empty at the root.
    var table: [String] = []
    var server: (name: String, url: String?, command: String?)?
    /// Open `[` of an array that goes on over lines.
    var openArrays = 0

    mutating func finish() {
        if let server { config.tables.append(.init(name: server.name, url: server.url, command: server.command)) }
        server = nil
    }

    mutating func incomplete() { config.complete = false }

    mutating func read(_ line: Substring) {
        if openArrays > 0 {
            guard let depth = TOMLText.depth(line), depth.curly == 0 else { return incomplete() }
            openArrays += depth.square
            if openArrays < 0 { incomplete() }
            return
        }
        let body = line.trimmingCharacters(in: .whitespaces)
        if body.isEmpty || body.hasPrefix("#") { return }
        // A multi-line string can hold lines that look like tables.
        if body.contains("\"\"\"") || body.contains("'''") { return incomplete() }
        if body.hasPrefix("[") { return header(Substring(body)) }
        guard let (keys, rest) = TOMLText.keys(Substring(body)), rest.first == "=" else { return incomplete() }
        value(keys, rest.dropFirst().drop { $0 == " " || $0 == "\t" })
    }

    mutating func header(_ body: Substring) {
        finish()
        guard let header = TOMLText.header(body) else {
            table = []
            return incomplete()
        }
        table = header.path
        if header.array {
            if table.first == "mcp_servers" { incomplete() }
            return
        }
        guard table.count == 2, table[0] == "mcp_servers" else { return }
        if config.tables.contains(where: { $0.name == table[1] }) { return incomplete() }
        server = (table[1], nil, nil)
    }

    mutating func value(_ keys: [String], _ value: Substring) {
        let path = table + keys
        let servers = path.first == "mcp_servers"
        // `mcp_servers.x.url = …` at the root, or `x.url = …` in [mcp_servers], defines a server.
        if keys.count > 1, servers, table.count < 2 { incomplete() }
        if server != nil, keys.count == 1, keys[0] == "url" || keys[0] == "command" {
            guard let text = TOMLText.string(value) else { return incomplete() }
            if keys[0] == "url" { server?.url = text } else { server?.command = text }
            return
        }
        if value.hasPrefix("{") {
            // An inline table: a server, or all of them, when it sits at [mcp_servers] or above.
            if servers, path.count <= 2 { incomplete() }
            guard let depth = TOMLText.depth(value), depth.curly == 0, depth.square == 0 else { return incomplete() }
            return
        }
        if value.hasPrefix("[") {
            guard let depth = TOMLText.depth(value), depth.curly == 0, depth.square >= 0 else { return incomplete() }
            openArrays = depth.square
        }
    }
}

/// The little of TOML the Codex config reader needs: keys, table headers, strings, and bracket depth.
enum TOMLText {
    static func isBare(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
    }

    /// A dotted key (`a."b.c".d`), and what follows it.
    static func keys(_ text: Substring) -> ([String], Substring)? {
        var path: [String] = []
        var rest = text.drop { $0 == " " || $0 == "\t" }
        while true {
            if rest.first == "\"" || rest.first == "'" {
                guard let (key, after) = string(prefix: rest) else { return nil }
                path.append(key)
                rest = after
            } else {
                let bare = rest.prefix(while: isBare)
                guard !bare.isEmpty else { return nil }
                path.append(String(bare))
                rest = rest.dropFirst(bare.count)
            }
            rest = rest.drop { $0 == " " || $0 == "\t" }
            guard rest.first == "." else { return (path, rest) }
            rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" }
        }
    }

    /// `[a.b]` or `[[a.b]]`, with only a comment after it.
    static func header(_ text: Substring) -> (path: [String], array: Bool)? {
        let array = text.hasPrefix("[[")
        guard let (path, rest) = keys(text.dropFirst(array ? 2 : 1)) else { return nil }
        let close = array ? "]]" : "]"
        guard rest.hasPrefix(close) else { return nil }
        let after = rest.dropFirst(close.count).drop { $0 == " " || $0 == "\t" }
        return after.isEmpty || after.hasPrefix("#") ? (path, array) : nil
    }

    /// A value that is one string, with only a comment after it.
    static func string(_ value: Substring) -> String? {
        guard let (text, after) = string(prefix: value) else { return nil }
        let rest = after.drop { $0 == " " || $0 == "\t" }
        return rest.isEmpty || rest.hasPrefix("#") ? text : nil
    }

    /// A basic (`"…"`, with escapes) or literal (`'…'`) string at the start, and what follows it.
    static func string(prefix text: Substring) -> (String, Substring)? {
        guard let quote = text.first, quote == "\"" || quote == "'" else { return nil }
        var out = ""
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            if character == quote { return (out, text[text.index(after: index)...]) }
            guard quote == "\"", character == "\\" else {
                out.append(character)
                index = text.index(after: index)
                continue
            }
            guard let (escaped, next) = escape(text, after: index) else { return nil }
            out += escaped
            index = next
        }
        return nil
    }

    /// One escape in a basic string, starting at its backslash.
    static func escape(_ text: Substring, after backslash: Substring.Index) -> (String, Substring.Index)? {
        let at = text.index(after: backslash)
        guard at < text.endIndex else { return nil }
        let simple: [Character: String] = ["\"": "\"", "\\": "\\", "b": "\u{8}", "t": "\t", "n": "\n", "f": "\u{C}", "r": "\r", "e": "\u{1B}"]
        if let plain = simple[text[at]] { return (plain, text.index(after: at)) }
        let digits = text[at] == "u" ? 4 : text[at] == "U" ? 8 : 0
        guard digits > 0 else { return nil }
        let start = text.index(after: at)
        guard let end = text.index(start, offsetBy: digits, limitedBy: text.endIndex),
              let value = UInt32(text[start..<end], radix: 16), let scalar = Unicode.Scalar(value) else { return nil }
        return (String(scalar), end)
    }

    /// How many `[` and `{` a line leaves open, outside strings and before a comment; nil for a string
    /// that does not end on the line.
    static func depth(_ text: Substring) -> (square: Int, curly: Int)? {
        var square = 0
        var curly = 0
        var index = text.startIndex
        while index < text.endIndex {
            switch text[index] {
            case "#": return (square, curly)
            case "\"", "'":
                guard let (_, after) = string(prefix: text[index...]) else { return nil }
                index = after.startIndex
                continue
            case "[": square += 1
            case "]": square -= 1
            case "{": curly += 1
            case "}": curly -= 1
            default: break
            }
            index = text.index(after: index)
        }
        return (square, curly)
    }
}

// MARK: - Amp

extension SkillServers {
    struct AmpRead {
        var file: String?
        var ignored: String?
        var servers: [Server] = []
        var unread: [SkillPackage.Unread] = []
        var frontMatterUnread = false
    }

    /// `mcpServers` in the front matter wins; else an mcp.json beside SKILL.md.
    static func readAmp(_ reader: PackageReader, skillText: String, skillFile: String) -> AmpRead {
        var read = AmpRead()
        let yaml = frontMatterBlock(skillText).map { SkillYAML($0, quotedTopKeys: true) }
        read.frontMatterUnread = !(yaml?.problems.isEmpty ?? true)
        let hasJSON = reader.exists("mcp.json")
        guard case .map(let entries) = yaml?.root, entries.contains(where: { $0.key == "mcpServers" }) else {
            guard hasJSON else { return read }
            read.file = reader.spelling("mcp.json")
            readAmpJSON(reader, into: &read)
            return read
        }
        read.file = skillFile
        if hasJSON { read.ignored = reader.spelling("mcp.json") }
        let declared = entries.filter { $0.key == "mcpServers" }
        var problems: [String] = []
        if declared.count > 1 { problems.append("it has the key “mcpServers” twice") }
        if let node = declared.first?.value { readAmpServers(node, file: skillFile, into: &read.servers, problems: &problems) }
        if read.servers.isEmpty, problems.isEmpty { problems.append("it names mcpServers, but holds no server Next Term could read") }
        if let first = problems.first { read.unread.append(SkillPackage.Unread(file: skillFile, reason: first)) }
        return read
    }

    static func readAmpJSON(_ reader: PackageReader, into read: inout AmpRead) {
        var found = PackageReader.Found()
        reader.readServerPath("mcp.json", file: "mcp.json", into: &found)
        let file = read.file ?? "mcp.json"
        if !found.outside.isEmpty { found.couldNotRead(file, "it leads outside the skill folder") }
        for server in found.servers {
            if server.command == nil && server.url == nil {
                found.couldNotRead(server.file, "its MCP server “\(SkillReview.oneLine(server.name, limit: 60))” has no command or url")
            } else {
                read.servers.append(server)
            }
        }
        read.unread += found.uniqueUnread
    }

    /// A map of servers, as YAML or as a JSON map on one line.
    static func readAmpServers(_ node: SkillYAML.Node, file: String, into servers: inout [Server], problems: inout [String]) {
        var named: [(String, Any?)] = []
        switch node {
        case .map(let entries): named = entries.map { ($0.key, plain($0.value)) }
        case .flow(let text):
            guard let map = flowJSON(text) as? [String: Any] else { return problems.append("its mcpServers is not a JSON map Next Term could read") }
            named = map.keys.sorted().map { ($0, map[$0]) }
        default:
            return problems.append(form(node) ?? "its mcpServers is not a map of servers")
        }
        for (name, value) in named {
            let quoted = "“" + SkillReview.oneLine(name, limit: 60) + "”"
            guard let config = value as? [String: Any] else {
                problems.append("its MCP server \(quoted) uses YAML Next Term does not read")
                continue
            }
            let server = PackageReader.server(name, config, file: file)
            guard server.command != nil || server.url != nil else {
                problems.append("its MCP server \(quoted) has no command or url")
                continue
            }
            servers.append(server)
        }
    }

    /// A YAML node as JSON values; nil when anything in it is not read (a flow value must be JSON).
    static func plain(_ node: SkillYAML.Node) -> Any? {
        switch node {
        case .scalar(let text): return text
        case .empty: return NSNull()
        case .flow(let text): return flowJSON(text)
        case .unread: return nil
        case .list(let items):
            var values: [Any] = []
            for item in items {
                guard let value = plain(item) else { return nil }
                values.append(value)
            }
            return values
        case .map(let entries):
            var values: [String: Any] = [:]
            for entry in entries {
                guard values[entry.key] == nil, let value = plain(entry.value) else { return nil }
                values[entry.key] = value
            }
            return values
        }
    }

    /// A flow value read as strict JSON (no comments, no key twice), after any comment that follows it.
    static func flowJSON(_ text: String) -> Any? {
        var json = Substring(text)
        if let close = json.lastIndex(where: { $0 == "]" || $0 == "}" }) {
            let after = json[json.index(after: close)...].drop { $0 == " " || $0 == "\t" }
            if after.hasPrefix("#") { json = json[...close] }
        }
        let data = Data(json.utf8)
        guard case .success(let node) = SkillJSONText.parse(data), SkillJSONText.duplicateKey(in: node) == nil else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// The lines between SKILL.md's first two `---` lines, as SkillFrontMatter reads them.
    static func frontMatterBlock(_ text: String) -> String? {
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines.removeFirst()
        guard let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        return lines[..<end].joined(separator: "\n")
    }
}

// MARK: - The lines

extension SkillServers {
    /// One agent's line in "Needs MCP servers".
    public struct Line: Equatable, Sendable {
        public let agent: String
        /// The agent, the files that declare the servers and the servers, then what the agent does.
        public let text: String
        /// Codex: the tables it would add to ~/.codex/config.toml, a line each.
        public let preview: [String]
    }

    /// What the row ends with.
    public static let closing = "Next Term adds none of these. Each agent decides as above."

    /// One line per agent that would use the skill's servers. `choice` is Claude Code's link, `start`
    /// how its plugin would start, `clashes` the plugins its name meets (the install plan's), `readsShared`
    /// that Claude Code reads ~/.agents/skills through a linked ~/.claude/skills (so it loads the folder
    /// whatever the choice), `codex` what ~/.codex/config.toml holds, `trigger` the skill's Codex command
    /// (`$name`).
    public func lines(choice: SkillInstall.ClaudeLink, start: SkillPackage.Start, clashes: [SkillInstall.Clash] = [],
                      readsShared: Bool = false, codex config: CodexConfig, trigger: String) -> [Line] {
        var lines: [Line] = []
        if let line = claudeLine(choice: readsShared ? .link : choice, start: start, clashes: clashes, readsShared: readsShared) {
            lines.append(line)
        }
        if let line = codexLine(config, trigger: trigger) { lines.append(line) }
        if let line = ampLine() { lines.append(line) }
        return lines
    }

    func claudeLine(choice: SkillInstall.ClaudeLink, start: SkillPackage.Start, clashes: [SkillInstall.Clash], readsShared: Bool) -> Line? {
        guard let plugin = claudePlugin, plugin.serverCount > 0 else { return nil }
        let key = "“" + SkillReview.oneLine(plugin.name, limit: 60) + "@skills-dir”"
        let installed = clashes.first { $0.kind == .installed }
        let condition: String
        if choice == .skip {
            condition = "Left out of Claude Code, so these don't start there."
        } else if start == .offByKey {
            condition = "Your Claude Code settings keep the plugin off (\(key): false), so these don't start until you turn it on in /plugin."
        } else if !plugin.mayLoadAsPlugin {
            // Hand check H2: Claude Code 2.1.280 loads only the plain skill then.
            condition = "Claude Code loads only its skill, not its plugin, because its plugin.json has no usable name, so these don't start there "
                + "(as of October 2026). A later version may start them."
        } else if let installed {
            // Hand check H7: an installed plugin of the same name wins, even turned off.
            let name = "“" + SkillReview.oneLine(installed.name, limit: 60) + "”"
            condition = "Claude Code keeps your installed \(name), so these don't start there (as of October 2026)."
        } else if start == .offByManifest {
            condition = "Claude Code adds the plugin turned off, only because its manifest says so. These start once it is on."
        } else if readsShared {
            condition = "Claude Code reads ~/.agents/skills through your linked ~/.claude/skills, so it starts these every time Claude Code opens, "
                + "without asking you, until you turn it off in Claude Code's /plugin."
        } else {
            condition = "If you add it to Claude Code, it starts these every time Claude Code opens, without asking you, until you turn it off "
                + "in Claude Code's /plugin."
        }
        let described = Self.described(plugin.servers, count: plugin.serverCount)
        return Line(agent: "Claude Code", text: Self.lead("Claude Code", files: files(of: plugin.servers), servers: described) + " " + condition, preview: [])
    }

    func codexLine(_ config: CodexConfig, trigger: String) -> Line? {
        guard hasCodex, let codexFile else { return nil }
        let shown = Array(codex.prefix(SkillPackage.cap))
        var said = ["If you name this skill with `\(SkillReview.oneLine(trigger, limit: 80))` in Codex itself (its CLI, IDE extension or app), "
            + "Codex offers to add these to ~/.codex/config.toml. If you let Codex work without asking and with full access, it adds them "
            + "without asking you."]
        var present: [String] = []
        var keeps: [Server] = []
        var unknown: [String] = []
        var adds: [Server] = []
        for server in shown {
            let name = "“" + SkillReview.oneLine(server.name, limit: 60) + "”"
            switch Self.codexStatus(server, in: config) {
            case .adds: adds.append(server)
            case .present(let table): present.append(table == server.name ? name : name + " (as “" + SkillReview.oneLine(table, limit: 60) + "”)")
            case .keepsYours: keeps.append(server)
            case .unknown: unknown.append(name)
            }
        }
        if !present.isEmpty { said.append("Already in your Codex config: \(SkillPackage.list(present)).") }
        if !keeps.isEmpty { said.append(Self.keepsSentence(keeps)) }
        if !unknown.isEmpty { said.append("Next Term could not read all of ~/.codex/config.toml: check it for \(SkillPackage.list(unknown)).") }
        if unread.contains(where: { $0.file == codexFile }) { said.append("Next Term could not read every entry in \(codexFile): check it there.") }
        if adds.contains(where: { $0.transport == .stdio }) { said.append("Codex keeps a program's command, with no arguments.") }
        if !adds.isEmpty { said.append("It would add:") }
        let servers = codex.isEmpty ? "no entry Next Term could read." : Self.described(shown, count: codex.count)
        let text = Self.lead("Codex", files: [codexFile], servers: servers) + " " + said.joined(separator: " ")
        return Line(agent: "Codex", text: text, preview: adds.flatMap(Self.codexTable))
    }

    static func keepsSentence(_ servers: [Server]) -> String {
        let names = SkillPackage.list(servers.map { "“" + SkillReview.oneLine($0.name, limit: 60) + "”" })
        let programs = servers.allSatisfy { $0.transport == .stdio }
        let one = servers.count == 1
        let elsewhere = programs ? (one ? "which runs another program" : "which run other programs") : (one ? "which connects elsewhere" : "which connect elsewhere")
        return "Codex would ask, then keep your own \(names), \(elsewhere)."
    }

    func ampLine() -> Line? {
        guard hasAmp, let ampFile else { return nil }
        var said = ["Amp reads ~/.agents/skills. It connects to these, and starts any program among them, when it finds the skill, and shows "
            + "their tools once the skill loads. A server of the same name in Amp's own settings wins."]
        if let ampIgnored { said.append("Amp uses \(skillFile)'s mcpServers and ignores \(ampIgnored).") }
        if ampUnread { said.append("Next Term could not read every entry in \(ampFile): check it there.") }
        let servers = amp.isEmpty ? "no entry Next Term could read." : Self.described(Array(amp.prefix(SkillPackage.cap)), count: amp.count)
        return Line(agent: "Amp", text: Self.lead("Amp", files: [ampFile], servers: servers) + " " + said.joined(separator: " "), preview: [])
    }

    func files(of servers: [Server]) -> [String] {
        var files: [String] = []
        for server in servers where !files.contains(server.file) { files.append(server.file) }
        return files
    }

    /// "Claude Code, from .mcp.json: “docs” runs the program `node server.js`."
    static func lead(_ agent: String, files: [String], servers: String) -> String {
        "\(agent), from \(SkillPackage.list(files)): \(servers)"
    }

    /// The servers, each in words, then "and N more", ending with a full stop.
    static func described(_ servers: [Server], count: Int) -> String {
        var said = servers.map(describe)
        if let more = SkillPackage.more(count - servers.count) { said.append(more) }
        return said.joined(separator: "; ") + "."
    }

    /// One server in plain words: “docs” runs the program `node server.js`.
    static func describe(_ server: Server) -> String {
        let name = "“" + SkillReview.oneLine(server.name, limit: 60) + "”"
        if server.transport == .bundle {
            let place = SkillReview.oneLine(server.bundle ?? "", limit: 120)
            return server.url == nil ? "\(name) is an MCP bundle at \(place), which Claude Code unpacks and runs"
                : "\(name) is an MCP bundle from \(place), which Claude Code downloads, unpacks and runs"
        }
        var said: String
        if let command = server.command {
            let line = ([command] + server.args).joined(separator: " ")
            said = "\(name) runs the program `\(SkillReview.oneLine(line, limit: 120))`"
        } else if let url = server.url {
            said = "\(name) connects to \(SkillReview.oneLine(url))"
        } else {
            said = "\(name), which Next Term could not read"
        }
        if let helper = server.headersHelper { said += ", and runs `\(SkillReview.oneLine(helper, limit: 120))` for its headers" }
        return said
    }

    /// The table Codex would add for a dependency: `url` for streamable HTTP, `command` (and no
    /// arguments) for stdio.
    static func codexTable(_ server: Server) -> [String] {
        let name = SkillReview.oneLine(server.name, limit: 60)
        let key = !name.isEmpty && name.allSatisfy(TOMLText.isBare) ? name : tomlString(name)
        let value = server.transport == .stdio ? "command = " + tomlString(SkillReview.oneLine(server.command ?? ""))
            : "url = " + tomlString(SkillReview.oneLine(server.url ?? ""))
        return ["[mcp_servers.\(key)]", value]
    }

    static func tomlString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - A small YAML reader

/// The YAML that skills use, read by indentation: maps and lists in block form, quoted and bare
/// scalars, and comments. Not a YAML parser, and it says what it doesn't read. A form that can't change
/// other keys stays where it stands, as `.unread` (a block scalar, a quoted key, a value over several
/// lines) or `.flow` (`[…]` and `{…}`, as written), so the caller decides whether it matters there. A form
/// that can bring in keys from elsewhere, or hide them (anchors, aliases, merge keys, tags, `?` keys, a
/// line it can't place, a tab in the indentation), is listed in `problems`.
struct SkillYAML {
    indirect enum Node: Equatable {
        case scalar(String)
        case map([Entry])
        case list([Node])
        /// `[…]` or `{…}`, as written.
        case flow(String)
        /// `key:` with nothing after it or under it.
        case empty
        /// A form the reader does not read, and what it is.
        case unread(String)
    }

    struct Entry: Equatable {
        let key: String
        let value: Node
    }

    struct Line {
        let indent: Int
        let text: Substring
    }

    var root: Node = .empty
    var problems: [String] = []
    private var lines: [Line] = []
    private var at = 0
    private var top = 0
    /// Quoted keys at the top level read as their text, as SkillFrontMatter reads them.
    private let quotedTopKeys: Bool

    init(_ text: String, quotedTopKeys: Bool = false) {
        self.quotedTopKeys = quotedTopKeys
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            let indent = line.prefix { $0 == " " }.count
            var body = line.dropFirst(indent)
            while let last = body.last, last == " " || last == "\t" { body = body.dropLast() }
            if body.isEmpty || body.hasPrefix("#") { continue }
            if body.hasPrefix("\t") {
                problem("a tab in its indentation")
                continue
            }
            if indent == 0, body.hasPrefix("---") || body == "..." {
                // A document start is fine before anything else; another document is not read.
                if !lines.isEmpty || body != "---" { problem("a second YAML document") }
                continue
            }
            lines.append(Line(indent: indent, text: body))
        }
        guard let first = lines.first else { return }
        top = first.indent
        root = node(top)
        if at < lines.count { problem("a line out of place") }
    }

    mutating func problem(_ text: String) {
        if !problems.contains(text) { problems.append(text) }
    }

    static func isItem(_ text: Substring) -> Bool { text == "-" || text.hasPrefix("- ") }

    mutating func node(_ indent: Int) -> Node {
        Self.isItem(lines[at].text) ? list(indent) : map(indent)
    }

    /// Skips the lines deeper than `indent`.
    mutating func skip(_ indent: Int) {
        while at < lines.count, lines[at].indent > indent { at += 1 }
    }

    /// Whether lines deeper than `indent` go on from a value that ends on its own line (and skips them).
    mutating func continued(_ indent: Int) -> Bool {
        guard at < lines.count, lines[at].indent > indent else { return false }
        skip(indent)
        return true
    }

    mutating func map(_ indent: Int) -> Node {
        var entries: [Entry] = []
        while at < lines.count, lines[at].indent == indent, !Self.isItem(lines[at].text) {
            let text = lines[at].text
            at += 1
            if text == "?" || text.hasPrefix("? ") {
                problem("a ? key")
                skip(indent)
                continue
            }
            guard let (key, quoted, rest) = Self.splitKey(text), !key.isEmpty else {
                problem("a line out of place")
                skip(indent)
                continue
            }
            if !quoted, let first = key.first, "&*!|>%@`[{".contains(first) {
                problem("a key Next Term does not read")
                skip(indent)
                continue
            }
            if !quoted, key == "<<" { problem("a merge key (<<)") }
            var value = self.value(rest, indent: indent, sameIndentList: true)
            if quoted, !(quotedTopKeys && indent == top) { value = .unread("a quoted key") }
            entries.append(Entry(key: key, value: value))
        }
        return .map(entries)
    }

    mutating func list(_ indent: Int) -> Node {
        var items: [Node] = []
        while at < lines.count, lines[at].indent == indent, Self.isItem(lines[at].text) {
            let after = lines[at].text.dropFirst()
            let gap = after.prefix { $0 == " " }.count
            let content = after.dropFirst(gap)
            if Self.startsEntry(content) {
                // A map whose first entry is on the item's line: its keys line up after "- ".
                lines[at] = Line(indent: indent + 1 + gap, text: content)
                items.append(map(indent + 1 + gap))
                continue
            }
            at += 1
            if Self.isItem(content) {
                skip(indent)
                items.append(.unread("a list inside a list on one line"))
            } else {
                items.append(value(content, indent: indent, sameIndentList: false))
            }
        }
        return .list(items)
    }

    /// What follows `key:`, or a list item's text. `sameIndentList`: list items at the key's own indent
    /// belong to it, as YAML allows for a key's value.
    mutating func value(_ rest: Substring, indent: Int, sameIndentList: Bool) -> Node {
        let text = rest.drop { $0 == " " || $0 == "\t" }
        guard let first = text.first, first != "#" else { return nested(indent, sameIndentList: sameIndentList) }
        switch first {
        case "&", "*", "!":
            problem("an anchor, alias or tag (&, * or !)")
            skip(indent)
            return .unread("an anchor, alias or tag")
        case "|", ">":
            skip(indent)
            return .unread("a block scalar (| or >)")
        case "[", "{":
            var flow = String(text)
            while at < lines.count, lines[at].indent > indent {
                flow += "\n" + lines[at].text
                at += 1
            }
            return .flow(flow)
        case "\"", "'":
            guard let (scalar, after) = Self.quoted(text) else {
                skip(indent)
                return .unread("a quoted value over several lines")
            }
            let tail = after.drop { $0 == " " || $0 == "\t" }
            guard tail.isEmpty || tail.hasPrefix("#") else {
                skip(indent)
                return .unread("text after a quoted value")
            }
            return continued(indent) ? .unread("a value over several lines") : .scalar(scalar)
        case "?" where text.count == 1 || text.dropFirst().first == " ":
            problem("a ? key")
            skip(indent)
            return .unread("a ? key")
        default:
            let plain = Self.plain(text)
            return continued(indent) ? .unread("a value over several lines") : .scalar(plain)
        }
    }

    /// The block under a key with nothing after it.
    mutating func nested(_ indent: Int, sameIndentList: Bool) -> Node {
        guard at < lines.count else { return .empty }
        let next = lines[at]
        if next.indent > indent {
            let node = self.node(next.indent)
            guard at < lines.count, lines[at].indent > indent else { return node }
            skip(indent)
            return .unread("lines out of place")
        }
        if sameIndentList, next.indent == indent, Self.isItem(next.text) { return list(indent) }
        return .empty
    }

    /// A list item's text that is a map's first entry.
    static func startsEntry(_ text: Substring) -> Bool {
        guard let first = text.first, !"[{&*!|>?#".contains(first), !isItem(text) else { return false }
        return splitKey(text) != nil
    }

    /// A `key: value` line's key, whether it was quoted, and the text after its colon. A bare key ends at
    /// the first colon followed by a space (or the line's end), so `https://` stays in a value.
    static func splitKey(_ text: Substring) -> (String, Bool, Substring)? {
        if let quote = text.first, quote == "\"" || quote == "'" {
            guard let (key, after) = quoted(text) else { return nil }
            let rest = after.drop { $0 == " " || $0 == "\t" }
            guard rest.first == ":" else { return nil }
            let value = rest.dropFirst()
            guard value.isEmpty || value.first == " " || value.first == "\t" else { return nil }
            return (key, true, value)
        }
        let end = commentStart(text) ?? text.endIndex
        var index = text.startIndex
        while index < end {
            let next = text.index(after: index)
            if text[index] == ":", next == end || text[next] == " " || text[next] == "\t" {
                return (text[..<index].trimmingCharacters(in: .whitespaces), false, text[next...])
            }
            index = next
        }
        return nil
    }

    /// Where a comment starts: a `#` after a space or tab.
    static func commentStart(_ text: Substring) -> Substring.Index? {
        var previous: Character = " "
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "#", previous == " " || previous == "\t" { return index }
            previous = text[index]
            index = text.index(after: index)
        }
        return nil
    }

    /// A bare scalar, without a comment after it.
    static func plain(_ text: Substring) -> String {
        let cut = commentStart(text).map { text[..<$0] } ?? text
        return cut.trimmingCharacters(in: .whitespaces)
    }

    /// A quoted scalar at the start (`"…"` with escapes, or `'…'` with `''`), and what follows it; nil when
    /// it does not end on the line or holds an escape YAML doesn't have.
    static func quoted(_ text: Substring) -> (String, Substring)? {
        guard let quote = text.first else { return nil }
        var out = ""
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            if character == quote {
                let next = text.index(after: index)
                guard quote == "'", next < text.endIndex, text[next] == "'" else { return (out, text[next...]) }
                out.append("'")
                index = text.index(after: next)
                continue
            }
            guard quote == "\"", character == "\\" else {
                out.append(character)
                index = text.index(after: index)
                continue
            }
            guard let (escaped, next) = escape(text, after: index) else { return nil }
            out += escaped
            index = next
        }
        return nil
    }

    static let escapes: [Character: String] = [
        "0": "\0", "a": "\u{7}", "b": "\u{8}", "t": "\t", "\t": "\t", "n": "\n", "v": "\u{B}", "f": "\u{C}", "r": "\r",
        "e": "\u{1B}", " ": " ", "\"": "\"", "/": "/", "\\": "\\", "N": "\u{85}", "_": "\u{A0}", "L": "\u{2028}", "P": "\u{2029}",
    ]

    /// One escape in a double-quoted scalar, starting at its backslash.
    static func escape(_ text: Substring, after backslash: Substring.Index) -> (String, Substring.Index)? {
        let at = text.index(after: backslash)
        guard at < text.endIndex else { return nil }
        if let plain = escapes[text[at]] { return (plain, text.index(after: at)) }
        let digits = text[at] == "x" ? 2 : text[at] == "u" ? 4 : text[at] == "U" ? 8 : 0
        guard digits > 0 else { return nil }
        let start = text.index(after: at)
        guard let end = text.index(start, offsetBy: digits, limitedBy: text.endIndex),
              let value = UInt32(text[start..<end], radix: 16), let scalar = Unicode.Scalar(value) else { return nil }
        return (String(scalar), end)
    }
}
