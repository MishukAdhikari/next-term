import CryptoKit
import Foundation

/// A server's tools as Next Term last saw them listed, kept beside the user's list in `mcp-tools.noindex` (a sidecar, so
/// the list itself stays as written), one file a server: what a new session's direct tools are made from (MCPHubDirect),
/// so `tools/list` never waits for a server to start (R5).
///
/// - **Whose.** A file is for one server as one list has it now (`identity`: the list, the name, and what it runs or
///   reaches, keys as their `${secret:NAME}`), so a server whose command or URL changed has none until it runs again.
/// - **When.** Written by the app alone: for a local server when an agent's bridge has it running and its list differs
///   from the one the session started with (MCPHubSession's report), for a remote one each time the app lists its tools.
///   A server added meanwhile has none, so the first session after it is added reaches it through the catalog only:
///   learning its tools at the start would mean starting a local server (an `npx` fetching its package can take longer
///   than an agent waits for `tools/list`) or asking the user for a remote server's key before anyone used it, and a
///   server that fails would hold up every new session until it works. Its first use writes the file, and the next
///   session lists its tools.
/// - **What.** Only what direct tools need: each tool's name, title, description (cut at `descriptionLimit`), input
///   schema (left out when it isn't an object schema or is over `schemaLimit`, so one odd tool can't break the agent's
///   whole list) and annotations' hints. A server's text is a third party's: kept short, never followed.
public struct MCPHubManifest: Codable, Equatable, Sendable {
    public struct Tool: Codable, Equatable, Sendable {
        /// Its name on its server, as listed: what a call sends.
        public var name: String
        public var title: String?
        public var description: String?
        /// Its input schema as JSON text, keys sorted; nil when it can't be listed as an agent's own tool.
        public var inputSchema: String?
        public var readOnlyHint: Bool?
        public var destructiveHint: Bool?
        public var idempotentHint: Bool?
        public var openWorldHint: Bool?

        public init(name: String, title: String? = nil, description: String? = nil, inputSchema: String? = #"{"type":"object"}"#,
                    readOnlyHint: Bool? = nil, destructiveHint: Bool? = nil, idempotentHint: Bool? = nil, openWorldHint: Bool? = nil) {
            self.name = name
            self.title = title
            self.description = description
            self.inputSchema = inputSchema
            self.readOnlyHint = readOnlyHint
            self.destructiveHint = destructiveHint
            self.idempotentHint = idempotentHint
            self.openWorldHint = openWorldHint
        }

        /// One tool of a `tools/list` answer; nil without a name.
        public init?(listed: [String: Any]) {
            guard let name = listed["name"] as? String, !name.isEmpty else { return nil }
            let annotations = listed["annotations"] as? [String: Any] ?? [:]
            func hint(_ key: String) -> Bool? { (annotations[key] as? NSNumber).map(\.boolValue) }
            let title = (listed["title"] as? String) ?? (annotations["title"] as? String)
            self.init(name: name, title: title.map { MCPHubManifest.cut($0, MCPHubManifest.titleLimit) },
                      description: (listed["description"] as? String).map { MCPHubManifest.cut($0, MCPHubManifest.descriptionLimit) },
                      inputSchema: MCPHubManifest.schema(listed["inputSchema"]),
                      readOnlyHint: hint("readOnlyHint"), destructiveHint: hint("destructiveHint"),
                      idempotentHint: hint("idempotentHint"), openWorldHint: hint("openWorldHint"))
        }

        /// The same tool through the same cuts, for one from elsewhere (a bridge's report).
        public init(checking tool: Tool) {
            let schema = tool.inputSchema.flatMap { text in
                (try? JSONSerialization.jsonObject(with: Data(text.utf8))).flatMap { MCPHubManifest.schema($0) }
            }
            self.init(name: tool.name, title: tool.title.map { MCPHubManifest.cut($0, MCPHubManifest.titleLimit) },
                      description: tool.description.map { MCPHubManifest.cut($0, MCPHubManifest.descriptionLimit) },
                      inputSchema: schema, readOnlyHint: tool.readOnlyHint, destructiveHint: tool.destructiveHint,
                      idempotentHint: tool.idempotentHint, openWorldHint: tool.openWorldHint)
        }
    }

    /// How many tools the server listed.
    public var count: Int
    /// Its tools, the first `toolLimit` of them.
    public var tools: [Tool]

    /// A tool named past `nameLimit` is left out: it stays with the catalog.
    public init(tools: [Tool], count: Int? = nil) {
        let named = tools.filter { $0.name.utf8.count <= Self.nameLimit }
        self.tools = Array(named.prefix(Self.toolLimit))
        self.count = count ?? named.count
    }

    /// A `tools/list` answer's tools, as kept.
    public init(listed: [[String: Any]]) {
        self.init(tools: listed.compactMap(Tool.init(listed:)))
    }

    /// The same tools with `mask` over their words and schemas: stored keys' values never reach the file (R13), as they
    /// never reach an answer.
    public func masked(_ mask: (String) -> String) -> MCPHubManifest {
        var made = self
        for index in made.tools.indices {
            made.tools[index].title = made.tools[index].title.map(mask)
            made.tools[index].description = made.tools[index].description.map(mask)
            made.tools[index].inputSchema = made.tools[index].inputSchema.map(mask)
        }
        return made
    }

    /// Every tool it listed is here.
    public var isComplete: Bool { tools.count == count }

    /// The longest description kept: a third party's words in every session's context, so a sentence or two of
    /// purpose and arguments, not a manual (mcp_tools gives a tool's whole description, live).
    public static let descriptionLimit = 1_024
    public static let titleLimit = 100
    /// The longest tool name kept, MCP's own 128: its name goes into every session's context too (a direct tool's title).
    public static let nameLimit = 128
    /// The longest input schema kept, as JSON text; a larger one is reached through mcp_call alone.
    public static let schemaLimit = 16_384
    /// The most tools kept: far more than a session's budget of direct tools (MCPHubDirect.budget).
    public static let toolLimit = 200

    /// Cut by Unicode scalars, not characters: a character can hold any number of combining marks, so a limit counted in
    /// characters wouldn't limit what reaches the agent.
    static func cut(_ text: String, _ limit: Int) -> String {
        guard text.unicodeScalars.count > limit else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit - 1))) + "\u{2026}"
    }

    /// An input schema as JSON text, keys sorted: only an object schema (`"type": "object"`, what the agents' APIs take
    /// for a tool's input) within `schemaLimit`. A tool that gives none takes no arguments.
    static func schema(_ value: Any?) -> String? {
        guard let value else { return #"{"type":"object"}"# }
        guard let object = value as? [String: Any], object["type"] as? String == "object",
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              data.count <= schemaLimit else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Its digest, for whether a server's list changed: the same tools give the same digest.
    public var digest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: the sidecar

    /// The sidecar's folder, beside the user's list: Spotlight leaves a `.noindex` folder alone.
    public static func folder(userFile: String) -> String {
        ((userFile as NSString).deletingLastPathComponent as NSString).appendingPathComponent("mcp-tools.noindex")
    }

    /// A server as one list has it now: the list, its name, what it runs or reaches, keys as written (never a value).
    public static func identity(_ server: MCPHubServer, list: String) -> String {
        // In steps with their types: as one expression it is too much for the type checker on a slower machine (CI).
        let env: [String] = server.env.keys.sorted().map { (key: String) -> String in key + "=" + (server.env[key] ?? "") }
        let headers: [String] = server.headers.keys.sorted().map { (key: String) -> String in key + ": " + (server.headers[key] ?? "") }
        var parts: [String] = [list, server.name, server.transport.rawValue, server.command]
        parts += server.args
        parts += env
        parts.append(server.url)
        parts += headers
        return SHA256.hash(data: Data(parts.joined(separator: "\u{0}").utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The server's file: `<name>-<identity>.json`.
    public static func file(_ server: MCPHubServer, list: String, userFile: String) -> String {
        (folder(userFile: userFile) as NSString).appendingPathComponent(server.name + "-" + identity(server, list: list) + ".json")
    }

    /// What the file holds on disk.
    private struct Stored: Codable {
        var version: Int
        var server: String
        var manifest: MCPHubManifest
    }

    private static let version = 1

    /// The server's tools as last seen; nil when none were, or its file can't be read.
    public static func read(_ server: MCPHubServer, list: String, userFile: String) -> MCPHubManifest? {
        guard let data = FileManager.default.contents(atPath: file(server, list: list, userFile: userFile)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.version == version else { return nil }
        return stored.manifest
    }

    /// The cached lists of the servers `resolution` applies, by name, for a plan (MCPHubPlan.allotDirect).
    public static func read(_ resolution: MCPHubScope.Resolution, userFile: String) -> [String: MCPHubManifest] {
        var found: [String: MCPHubManifest] = [:]
        for applied in resolution.servers {
            found[applied.name] = read(applied.server, list: applied.source.file, userFile: userFile)
        }
        return found
    }

    /// Keeps the server's tools, unless they are what its file has already: whether the file was written. A file of the
    /// same server's name not written for 30 days (one for a command it no longer runs) goes then.
    @discardableResult
    public static func remember(_ manifest: MCPHubManifest, server: MCPHubServer, list: String, userFile: String) -> Bool {
        guard read(server, list: list, userFile: userFile) != manifest else { return false }
        let folder = folder(userFile: userFile)
        let path = file(server, list: list, userFile: userFile)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard (try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])) != nil,
              let data = try? encoder.encode(Stored(version: version, server: server.name, manifest: manifest)),
              (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil else { return false }
        let old = Date().addingTimeInterval(-30 * 86_400)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        where name.hasPrefix(server.name + "-") && name.hasSuffix(".json") && name != (path as NSString).lastPathComponent {
            let other = (folder as NSString).appendingPathComponent(name)
            // Only `<name>-<16 hex>.json`: a server named `a` never takes `a-b`'s files.
            let rest = name.dropFirst(server.name.count + 1).dropLast(5)
            guard rest.count == 16, rest.allSatisfy(\.isHexDigit) else { continue }
            if let modified = (try? FileManager.default.attributesOfItem(atPath: other))?[.modificationDate] as? Date, modified < old {
                try? FileManager.default.removeItem(atPath: other)
            }
        }
        return true
    }
}
