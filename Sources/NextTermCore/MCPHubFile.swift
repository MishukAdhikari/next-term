import Foundation

/// The MCP hub's server list: the MCP servers the user connected in Next Term, which every agent in its tabs reaches
/// through its `next-term` entry (the hub is a gateway: no agent's own config file is ever written for it). Two places
/// hold one, as the skills library has the user's and the project's (MCPHubScope):
/// - The user's, `~/Library/Application Support/Next Term/mcp.json`, beside mcp.sock and Secrets. A server there applies
///   to every project, or only to the folders its `nextTerm.projects` names.
/// - A project's, `.next-term/mcp.json` in the project, to commit for a team. Its servers apply to that project.
///
/// The shape is the common `mcpServers` one, so a block copied from a server's README reads as is. Next Term's own keys
/// sit under one `nextTerm` object per server:
///
///     {
///       "version": 1,
///       "mcpServers": {
///         "github": {
///           "command": "nxtrm",
///           "args": ["secret", "run", "GITHUB_TOKEN", "--", "npx", "-y", "@modelcontextprotocol/server-github"],
///           "nextTerm": {"enabled": true, "projects": "all"}
///         },
///         "linear": {
///           "type": "http", "url": "https://mcp.linear.app/mcp",
///           "headers": {"Authorization": "Bearer ${secret:LINEAR_API_KEY}"},
///           "nextTerm": {"enabled": true, "projects": ["~/Code/app"]}
///         }
///       }
///     }
///
/// Keys never sit in either file (MCPHubRules refuses a value that looks like one): a command gets them through
/// `nxtrm secret run`, a URL or a header names one as `${secret:NAME}`, which only the app fills in.
///
/// What this file does:
/// - **Reads strictly.** RFC 8259 JSON only (SkillJSONText), so every reader takes the file the same way: a key twice at
///   the top is a broken file, a server's name twice is that server refused (`Read.twice`), never one copy picked.
/// - **Keeps what it doesn't know.** Every member is kept as read, in order, numbers as written: a client's own keys in a
///   pasted entry (`cwd`, `timeout`), a newer Next Term's keys in `nextTerm`, top-level keys. A change rewrites only the
///   keys it changes (`updated`).
/// - **Makes no file until the user acts.** `updated` gives bytes for a missing file only for adding a server, approving
///   a project's list or turning a server off (MCPHubChoices, at the top of the user's list); removing from a missing
///   file, or a change that changes nothing, writes nothing. An update to Next Term creates no
///   file and changes no answer of `next-term`'s until the user adds one.
/// - **Never overwrites a file it can't read.** A broken hand edit, or a file from a newer Next Term (`version` above
///   `version`), is refused, not replaced.
public enum MCPHubFile {
    /// The format this Next Term writes, and the newest it changes.
    public static let version = 1
    /// The most of a file read: a list of servers never comes near it.
    public static let maxBytes = SkillLibrary.maxText

    /// Which file: the user's own, or a project's.
    public enum Place: String, Sendable {
        case user
        case project
    }

    // MARK: values

    /// A JSON value as the file holds it. Objects keep their members in order and numbers their text, so what Next
    /// Term doesn't know is written back as it was read.
    public indirect enum Value: Equatable, Sendable {
        case object([Member])
        case array([Value])
        case string(String)
        case number(String)
        case bool(Bool)
        case null

        public var string: String? {
            if case .string(let text) = self { return text }
            return nil
        }

        public var members: [Member]? {
            if case .object(let members) = self { return members }
            return nil
        }

        /// The value of the only member with this key; nil when there is none, or more than one.
        public func member(_ key: String) -> Value? {
            guard let found = members?.filter({ $0.key == key }), found.count == 1 else { return nil }
            return found[0].value
        }
    }

    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: Value

        public init(_ key: String, _ value: Value) {
            self.key = key
            self.value = value
        }
    }

    /// A file's top level, as read.
    public struct Document: Equatable, Sendable {
        /// Every top-level member, in order, `mcpServers` among them.
        public var members: [Member]

        public init(members: [Member] = []) {
            self.members = members
        }

        /// The servers, in the file's order: each name, and its value as read (an object, unless the file is wrong).
        public var entries: [Member] {
            members.first { $0.key == "mcpServers" }?.value.members ?? []
        }
    }

    /// Why a file can't be read at all. The caller keeps the last list it read, and says this.
    public enum Problem: Error, Equatable, Sendable {
        /// Not strict JSON (comments, a trailing comma, anything else).
        case json(SkillJSONText.Problem)
        /// The top level is not an object.
        case notAnObject
        /// A top-level key is there twice (`mcpServers` twice: which one is the list?).
        case keyTwice(String)
        /// `mcpServers` is not an object.
        case serversNotAnObject
        /// `version` is not a whole number.
        case badVersion
        /// A newer Next Term wrote it: read as far as this one knows, never changed.
        case newer(Int)
        /// Over `maxBytes`.
        case tooLarge
        /// Not a plain UTF-8 file inside its folder (a folder, a link out of it, over `maxBytes`).
        case cantRead

        /// Why, in plain words, after "Next Term can't use mcp.json: ".
        public var reason: String {
            switch self {
            case .json(let problem): return problem.reason
            case .notAnObject: return "it is not a JSON object"
            case .keyTwice(let key): return "it has \(key) twice"
            case .serversNotAnObject: return "mcpServers is not an object"
            case .badVersion: return "its version is not a number"
            case .newer(let version): return "a newer Next Term wrote it (version \(version)); update Next Term to change it"
            case .tooLarge: return "it is over 256 KB"
            case .cantRead: return "it is not a plain text file of at most 256 KB, inside its folder"
            }
        }
    }

    /// A file read: its document, and the names that are there more than once (none of their copies is used).
    public struct Read: Equatable, Sendable {
        public var document: Document
        public var twice: Set<String>
        /// From a newer Next Term: usable as far as this one knows, never written (`updated` refuses it).
        public var newer: Int?
    }

    /// Reads a file's bytes. An empty file (or only spaces) is an empty list: someone emptied it.
    public static func parse(_ data: Data) -> Result<Read, Problem> {
        guard data.count <= maxBytes else { return .failure(.tooLarge) }
        let node: SkillJSONText.Node
        switch SkillJSONText.parse(data) {
        case .success(let parsed): node = parsed
        case .failure(.empty): return .success(Read(document: Document(), twice: []))
        case .failure(let problem): return .failure(.json(problem))
        }
        let bytes = [UInt8](data)
        guard node.kind == .object else { return .failure(.notAnObject) }
        var seen = Set<String>()
        for member in node.members where !seen.insert(member.key).inserted { return .failure(.keyTwice(member.key)) }
        let document = Document(members: node.members.map { Member($0.key, value(of: $0.value, in: bytes)) })
        var newer: Int?
        if let version = document.members.first(where: { $0.key == "version" })?.value {
            guard case .number(let text) = version, let number = Int(text), number >= 0 else { return .failure(.badVersion) }
            if number > Self.version { newer = number }
        }
        var twice = Set<String>()
        if let servers = node.members.first(where: { $0.key == "mcpServers" })?.value {
            guard servers.kind == .object else { return .failure(.serversNotAnObject) }
            var names = Set<String>()
            for server in servers.members where !names.insert(server.key).inserted { twice.insert(server.key) }
        }
        return .success(Read(document: document, twice: twice, newer: newer))
    }

    static func value(of node: SkillJSONText.Node, in bytes: [UInt8]) -> Value {
        switch node.kind {
        case .object: return .object(node.members.map { Member($0.key, value(of: $0.value, in: bytes)) })
        case .array: return .array(node.items.map { value(of: $0, in: bytes) })
        case .string: return .string(node.string ?? "")
        case .number: return .number(String(decoding: bytes[node.range], as: UTF8.self))
        case .bool: return .bool(bytes[node.range.lowerBound] == UInt8(ascii: "t"))
        case .null: return .null
        }
    }

    // MARK: changing

    public enum Change: Equatable, Sendable {
        /// Adds the server, or changes the one with its name (every copy of a name there twice becomes this one).
        case set(MCPHubServer)
        /// Removes the server with this name (every copy).
        case remove(String)
        /// The user's choices (MCPHubChoices), in the user's list only: approves a project's list as these bytes'
        /// digest have it (replacing an older approval of it), or turns a server off, or on again, for a folder.
        case approve(file: String, digest: String)
        case turnOff(server: String, folder: String)
        case turnOn(server: String, folder: String)

        /// Whether it makes a list that isn't there: adding a server, approving a list and turning one off are the
        /// user's own acts; removing and turning on again change nothing in a list that isn't there.
        var makesFile: Bool {
            switch self {
            case .set, .approve, .turnOff: return true
            case .remove, .turnOn: return false
            }
        }
    }

    /// Why a change wasn't made: nothing is written.
    public enum Refusal: Error, Equatable, Sendable {
        /// The file there can't be read; it is left as it is for the user to fix.
        case unreadable(Problem)
        /// The server breaks a rule (MCPHubRules), each reason in plain words.
        case invalid([String])
    }

    /// The bytes to write after a change, from the file's bytes as read (`current`, nil when there is no file). Nil
    /// when nothing is to be written: a remove from a missing file or of a name it doesn't have, or a set that changes
    /// nothing. Only an act of the user's (`makesFile`: a server added, a project's list approved, a server turned off)
    /// ever gives bytes for a missing file, so updating Next Term makes none.
    public static func updated(_ current: Data?, place: Place, _ change: Change) -> Result<Data?, Refusal> {
        if case .set(let server) = change {
            let reasons = MCPHubRules.reasons(server, place: place)
            guard reasons.isEmpty else { return .failure(.invalid(reasons)) }
        }
        if let reason = MCPHubChoices.reason(change) { return .failure(.invalid([reason])) }
        switch change {
        case .approve, .turnOff, .turnOn:
            guard place == .user else { return .failure(.invalid(["A project's list keeps no choices; they are yours, in your own list."])) }
        case .set, .remove: break
        }
        var document: Document
        if let current {
            switch parse(current) {
            case .failure(let problem): return .failure(.unreadable(problem))
            case .success(let read):
                if let newer = read.newer { return .failure(.unreadable(.newer(newer))) }
                document = read.document
            }
        } else {
            guard change.makesFile else { return .success(nil) }
            document = Document(members: [Member("version", .number(String(version))), Member("mcpServers", .object([]))])
        }
        let before = document
        var entries = document.entries
        switch change {
        case .set(let server):
            if let at = entries.firstIndex(where: { $0.key == server.name }) {
                entries[at].value = server.merged(into: entries[at].value, place: place)
                entries = entries.enumerated().filter { $0.offset == at || $0.element.key != server.name }.map(\.element)
            } else {
                entries.append(Member(server.name, server.merged(into: .object([]), place: place)))
            }
        case .remove(let name):
            entries.removeAll { $0.key == name }
        case .approve, .turnOff, .turnOn: break
        }
        if let at = document.members.firstIndex(where: { $0.key == "mcpServers" }) {
            document.members[at].value = .object(entries)
        } else {
            document.members.append(Member("mcpServers", .object(entries)))
        }
        var choices = MCPHubChoices.read(document)
        switch change {
        case .approve(let file, let digest) where !choices.isApproved(file, digest: digest):
            choices.approved.removeAll { $0.file == file }
            choices.approved.append(MCPHubChoices.Approval(file: file, digest: digest))
        case .turnOff(let server, let folder):
            if !choices.off.contains(MCPHubChoices.Off(server: server, folder: folder)) {
                choices.off.append(MCPHubChoices.Off(server: server, folder: folder))
            }
        case .turnOn(let server, let folder):
            choices.off.removeAll { $0.server == server && $0.folder == folder }
        case .set, .remove, .approve: break
        }
        if choices != MCPHubChoices.read(document) { document = choices.written(into: document) }
        guard document != before else { return .success(nil) }
        return .success(text(document))
    }

    // MARK: writing

    /// The document as the file's text: two spaces a level, an array of plain values (`args`) on one line, and a
    /// line break at the end.
    public static func text(_ document: Document) -> Data {
        var out = ""
        write(.object(document.members), indent: "", to: &out)
        out += "\n"
        return Data(out.utf8)
    }

    static func write(_ value: Value, indent: String, to out: inout String) {
        switch value {
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            let inner = indent + "  "
            out += "{\n"
            for (index, member) in members.enumerated() {
                out += inner + quoted(member.key) + ": "
                write(member.value, indent: inner, to: &out)
                out += index == members.count - 1 ? "\n" : ",\n"
            }
            out += indent + "}"
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            if items.allSatisfy({ if case .object = $0 { return false }; if case .array = $0 { return false }; return true }) {
                out += "["
                for (index, item) in items.enumerated() {
                    if index > 0 { out += ", " }
                    write(item, indent: indent, to: &out)
                }
                out += "]"
                return
            }
            let inner = indent + "  "
            out += "[\n"
            for (index, item) in items.enumerated() {
                out += inner
                write(item, indent: inner, to: &out)
                out += index == items.count - 1 ? "\n" : ",\n"
            }
            out += indent + "]"
        case .string(let text): out += quoted(text)
        case .number(let text): out += text
        case .bool(let flag): out += flag ? "true" : "false"
        case .null: out += "null"
        }
    }

    /// A JSON string: `"` and `\` escaped, and every control character, as RFC 8259 asks.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
