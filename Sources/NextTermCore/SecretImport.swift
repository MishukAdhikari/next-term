import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Import from MCP Configs…: plaintext keys move out of the MCP configs Next Term knows, one ticked row at a
/// time, into Secrets, and each server entry is rewritten to start its server through `nxtrm secret run`.
///
/// Core plans and writes; the app asks. Only this file touches `MCPRegistrar`'s internal `JSONC`, `TOMLOutline`,
/// `compact`, `tomlString`, `Plan` and `write(_:to:)`; the sheet sees the public types and functions here.
///
/// - **A finding** is a member of a server's `env` (opencode: `environment`) whose name holds TOKEN, SECRET,
///   PASSWORD, PASSWD, KEY, AUTH, CREDENTIAL or PAT as a word part, or whose value has a token's shape or looks
///   random. References (`${…}`, `$X`, `{env:…}`, `{file:…}`, `op://…`) are skipped. Keys in headers and in the
///   command's arguments are listed, not movable.
/// - **An edit** replaces that one entry and leaves every other byte of the file as it was. JSON entries are
///   rewritten whole (comments inside them are lost); Codex's TOML has its `command` and `args` replaced, the moved
///   keys removed, and `startup_timeout_sec` raised to 30.
/// - **A backup**, one per changed entry, holds the entry as it was with every detected value replaced by a marker:
///   `⟦nextterm:NAME⟧` for a moved key, `⟦nextterm:kept:N⟧` for one left in place, whose values the app seals under
///   the vault key. No backup holds a detected value in plaintext.
/// - **Undo** puts an entry back only while it is still what Next Term wrote, by its SHA-256.
public enum SecretImport {
    /// How long a backup is kept, and Undo offered.
    public static let keptFor: TimeInterval = 30 * 24 * 3600
    /// Codex's start-up wait the wrapper's 25 seconds need.
    public static let codexTimeout = 30

    // MARK: sources

    public enum Client: String, Codable, Sendable, CaseIterable {
        case claudeCode = "claude-code"
        case claudeApp = "claude-app"
        case codex, cursor, gemini, vscode, copilot, opencode, qwen, amp, junie
        case commandCode = "command-code"

        public var name: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .claudeApp: return "the Claude app"
            case .codex: return "Codex"
            case .cursor: return "Cursor"
            case .gemini: return "Gemini CLI"
            case .vscode: return "VS Code"
            case .copilot: return "Copilot CLI"
            case .opencode: return "opencode"
            case .qwen: return "Qwen Code"
            case .amp: return "Amp"
            case .junie: return "Junie"
            case .commandCode: return "Command Code"
            }
        }
    }

    public enum Format: String, Codable, Sendable {
        case json
        /// JSON that its agent reads strictly: no comments or trailing commas, and the result must parse plainly.
        case strictJSON = "strict-json"
        case toml
    }

    /// One MCP config file.
    public struct Source: Sendable, Equatable {
        public let path: String
        public let client: Client
        public let format: Format
        /// JSON: the keys from the top to the servers' object. Nil for Claude Code's `~/.claude.json`, whose
        /// containers (the top-level `mcpServers` and each project's) are found when it is read.
        public let containers: [[String]]?
        /// The app that reads the file once and saves it whole (the Claude app): written only while it is closed.
        public let readOnceBy: String?
        /// The open project it is in, for a project's own file.
        public let project: String?

        public init(path: String, client: Client, format: Format, containers: [[String]]?, readOnceBy: String? = nil, project: String? = nil) {
            self.path = path
            self.client = client
            self.format = format
            self.containers = containers
            self.readOnceBy = readOnceBy
            self.project = project
        }

        /// Claude Code's own `~/.claude.json`, written under its lock.
        public var isClaudeConfig: Bool { client == .claudeCode && containers == nil }
    }

    /// The files the import reads: the agents' own settings, Claude Code's `~/.claude.json`, VS
    /// Code's user `mcp.json`, and in each open project its `.mcp.json`, `.cursor/mcp.json`, `.vscode/mcp.json`,
    /// `.gemini/settings.json` and `.codex/config.toml`. A file is listed once, by its real path.
    public static func sources(home: String = NSHomeDirectory(), projects: [String]) -> [Source] {
        func path(_ relative: String) -> String { (home as NSString).appendingPathComponent(relative) }
        var list: [Source] = []
        for target in MCPRegistrar.targets(home: home) {
            let client: Client
            switch target.id {
            case "codex": client = .codex
            case "gemini": client = .gemini
            case "qwen": client = .qwen
            case "cursor": client = .cursor
            case "opencode": client = .opencode
            case "copilot": client = .copilot
            case "amp": client = .amp
            case "junie": client = .junie
            case "commandcode": client = .commandCode
            case "claude-desktop", "claude-desktop-3p": client = .claudeApp
            default: continue
            }
            let format: Format
            switch target.format {
            case .toml: format = .toml
            case .json(let strict): format = strict ? .strictJSON : .json
            }
            list.append(Source(path: target.file, client: client, format: format,
                               containers: format == .toml ? [["mcp_servers"]] : [[target.container]], readOnceBy: target.readOnceBy))
        }
        list.append(Source(path: path(".claude.json"), client: .claudeCode, format: .json, containers: nil))
        list.append(Source(path: path("Library/Application Support/Code/User/mcp.json"), client: .vscode, format: .json,
                           containers: [["servers"]]))
        for project in projects {
            func file(_ relative: String) -> String { (project as NSString).appendingPathComponent(relative) }
            list.append(Source(path: file(".mcp.json"), client: .claudeCode, format: .json, containers: [["mcpServers"]], project: project))
            list.append(Source(path: file(".cursor/mcp.json"), client: .cursor, format: .json, containers: [["mcpServers"]], project: project))
            list.append(Source(path: file(".vscode/mcp.json"), client: .vscode, format: .json, containers: [["servers"]], project: project))
            list.append(Source(path: file(".gemini/settings.json"), client: .gemini, format: .json, containers: [["mcpServers"]], project: project))
            list.append(Source(path: file(".codex/config.toml"), client: .codex, format: .toml, containers: [["mcp_servers"]], project: project))
        }
        var seen = Set<String>()
        return list.filter { seen.insert(canonicalPath($0.path)).inserted }
    }

    // MARK: findings

    /// Where a server's entry is: the keys to its container, and its name.
    public struct Location: Codable, Sendable, Equatable, Hashable {
        public let container: [String]
        public let server: String

        public init(container: [String], server: String) {
            self.container = container
            self.server = server
        }

        /// "mcpServers.github", "projects["/p"].mcpServers.github".
        public var description: String {
            (container + [server]).map { $0.contains("/") || $0.contains(".") ? "[“\($0)”]" : $0 }.joined(separator: ".")
        }
    }

    public enum Field: Sendable, Equatable, Hashable {
        case env(String)
        case header(String)
        case argument(Int)
    }

    /// One detected value. Its value is in memory only, as `SecretBytes`.
    public struct Finding: Sendable {
        public let id: String
        public let source: Source
        public let location: Location
        public let field: Field
        /// The variable's or header's name, or "argument 3".
        public let variable: String
        public let value: SecretBytes
        /// "GitHub token", or "a key, by its name".
        public let kind: String
        /// Why it can't be moved, or nil.
        public let notMovable: String?
        /// The file is in a git work tree: a change reaches everyone who pulls.
        public let shared: Bool
        /// The entry has comments inside it, which a JSON rewrite loses.
        public let loses: Bool

        public var movable: Bool { notMovable == nil }
        /// The last 4 characters, never more.
        public var lastFour: String { String((value.utf8String() ?? "").suffix(4)) }
    }

    /// What a scan found.
    public struct Scan: Sendable {
        public var findings: [Finding] = []
        /// Entries that already run `nxtrm secret run`: "uses Next Term's Secrets".
        public var wrapped: [(source: Source, location: Location)] = []
        /// Files that could not be read as their format.
        public var unreadable: [(source: Source, reason: String)] = []
        /// The files that were read.
        public var read: [Source] = []
    }

    static let headerReason = "takes its key in a header; Next Term can't wrap it yet. Use the server's sign-in if it has one."
    static let argumentReason = "the key is in the command's arguments"
    public static let claudeAppOpenReason = "quit the Claude app to move this key"

    /// A file's text: its bytes as read, without a UTF-8 byte order mark (writing puts it back).
    static func text(of data: Data) -> String? {
        let mark = Data([0xEF, 0xBB, 0xBF])
        return String(data: data.starts(with: mark) ? data.dropFirst(3) : data, encoding: .utf8)
    }

    /// Reads a plain file of at most 8 MB; nil for anything else (a link to nothing, a folder).
    public static func readFile(_ path: String) -> Data? {
        let real = canonicalPath(path)
        guard isRegularFile(real), let size = (try? FileManager.default.attributesOfItem(atPath: real))?[.size] as? Int,
              size <= 8 * 1024 * 1024 else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    /// Every finding in `sources`. `inGitWorkTree` and `isOpen` (a bundle identifier's app is running) are the
    /// caller's; values stay in memory.
    public static func scan(_ sources: [Source], read: (String) -> Data? = readFile, inGitWorkTree: (String) -> Bool = { _ in false },
                            isOpen: (String) -> Bool = { _ in false }) -> Scan {
        var scan = Scan()
        for source in sources {
            guard let data = read(source.path) else { continue }
            guard let text = text(of: data) else {
                scan.unreadable.append((source, "not UTF-8 text"))
                continue
            }
            scan.read.append(source)
            let shared = inGitWorkTree(source.path)
            let appOpen = source.readOnceBy.map(isOpen) ?? false
            let entries: [Entry]
            switch source.format {
            case .toml:
                guard let found = tomlEntries(text) else {
                    scan.unreadable.append((source, "not TOML Next Term can read"))
                    continue
                }
                entries = found
            case .json, .strictJSON:
                guard let found = jsonEntries(text, source: source) else {
                    scan.unreadable.append((source, "not JSON Next Term can read"))
                    continue
                }
                entries = found
            }
            for entry in entries {
                if entry.isWrapped {
                    scan.wrapped.append((source, entry.location))
                    continue
                }
                for detected in entry.detected {
                    var reason = detected.notMovable ?? entry.notMovable
                    if reason == nil, appOpen { reason = claudeAppOpenReason }
                    let id = [source.path, entry.location.description, "\(detected.field)"].joined(separator: "\u{0}")
                    scan.findings.append(Finding(id: SecretRun.digest(Data(id.utf8)), source: source, location: entry.location,
                                                 field: detected.field, variable: detected.variable, value: detected.value, kind: detected.kind,
                                                 notMovable: reason, shared: shared, loses: entry.hasComments))
                }
            }
        }
        return scan
    }

    /// One server entry, as read: what it runs, what it holds, and where.
    struct Entry {
        var location: Location
        /// The entry's text, as scalar offsets into the file.
        var range: Range<Int>
        var command: [String]
        var args: [String]
        var isWrapped = false
        var notMovable: String?
        var hasComments = false
        var detected: [Detected] = []
    }

    struct Detected {
        var field: Field
        var variable: String
        var value: SecretBytes
        var kind: String
        var notMovable: String?
        /// The value's literal in the file (with its quotes), as scalar offsets.
        var range: Range<Int>
    }

    // MARK: detecting

    static let secretWords: Set<String> = ["TOKEN", "SECRET", "PASSWORD", "PASSWD", "KEY", "AUTH", "CREDENTIAL", "PAT"]
    static let joinedWords: Set<String> = ["APIKEY", "ACCESSKEY", "SECRETKEY", "PRIVATEKEY", "ACCESSTOKEN", "AUTHTOKEN", "APITOKEN"]

    /// A name with a secret word as one of its parts: `GITHUB_PERSONAL_ACCESS_TOKEN`, `api-key`, `apiKey`, `GH_PAT`.
    /// `PATH` and `AUTHOR` are not.
    static func nameLooksSecret(_ name: String) -> Bool {
        var parts: [String] = []
        var current = ""
        var previousLower = false
        for character in name {
            if character == "_" || character == "-" || character == "." || character == " " {
                if !current.isEmpty { parts.append(current) }
                current = ""
                previousLower = false
                continue
            }
            if character.isUppercase, previousLower, !current.isEmpty {
                parts.append(current)
                current = ""
            }
            current.append(character)
            previousLower = character.isLowercase
        }
        if !current.isEmpty { parts.append(current) }
        for part in parts.map({ $0.uppercased() }) {
            if secretWords.contains(part) || joinedWords.contains(part) { return true }
            if part.hasSuffix("S"), secretWords.contains(String(part.dropLast())) { return true }
        }
        return false
    }

    /// A reference, not a key: `${X}`, `$X`, `{env:X}`, `{file:x}`, `${input:x}`, `${user_config.x}`, `op://…`.
    static func isReference(_ value: String) -> Bool {
        let prefixes = ["${", "$", "{env:", "{file:", "${input:", "${user_config.", "op://"]
        return prefixes.contains { value.hasPrefix($0) }
    }

    static let kinds = ["Anthropic key", "OpenAI key", "GitHub token", "GitHub token", "Slack token", "AWS access key", "Google API key",
                        "JSON web token", "private key", "LangSmith key", "Hugging Face token", "Groq key", "Tavily key", "Replicate token",
                        "xAI key", "Pinecone key"]

    /// What a value looks like: a token's shape by name, or nil.
    static func tokenKind(_ value: String) -> String? {
        let range = NSRange(value.startIndex..., in: value)
        for (index, pattern) in MCPRedaction.tokens.enumerated() where pattern.firstMatch(in: value, range: range) != nil {
            return index < kinds.count ? kinds[index] : "a key, by its shape"
        }
        return nil
    }

    /// Whether `value` under `name` is a key the import lists, and what kind. Nil for a reference, an empty or short
    /// value, or a value that only looks like a setting.
    static func detect(name: String, value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isReference(trimmed), MCPRedaction.isValue(trimmed) else { return nil }
        if let kind = tokenKind(trimmed) { return kind }
        if trimmed.count >= 20, MCPRedaction.looksRandom(trimmed) { return "a key, by its shape" }
        if nameLooksSecret(name), trimmed.count >= 8 { return "a key, by its name" }
        return nil
    }

    /// Why a detected env value can't be moved: one Secrets can't keep, or a variable `nxtrm secret run` can't set.
    static func valueRefusal(variable: String, value: String) -> String? {
        // By scalar: "\r\n" is one Character, equal to neither "\r" nor "\n".
        if value.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) { return "the value has line breaks, which Secrets can't keep yet" }
        if value.utf8.count > SecretVault.maxValueBytes { return "the value is over 16 KB" }
        if value.contains("\u{0}") { return "the value holds a NUL character" }
        if !StoredSecretName.isValid(variable) || StoredSecretName.isRefusedEnvName(variable) {
            return "the server reads it as \(variable), which nxtrm secret run can't set"
        }
        return nil
    }

    /// An entry that already starts its server through `nxtrm secret run`.
    static func isWrapped(command: [String]) -> Bool {
        guard let first = command.first else { return false }
        let base = (first as NSString).lastPathComponent
        let rest = Array(command.dropFirst())
        if base == "nxtrm" { return rest.starts(with: ["secret", "run"]) }
        if base == "NextTerm" { return rest.starts(with: ["--cli", "secret", "run"]) }
        return false
    }

    /// The arguments that hold a key: one with a token's shape or a random look, `--flag=<key>`, or the word after a
    /// flag named like a key (`--api-key x`).
    static func argumentFindings(_ args: [(value: String, range: Range<Int>)]) -> [Detected] {
        var found: [Detected] = []
        let dashes = CharacterSet(charactersIn: "-")
        for (index, arg) in args.enumerated() {
            var kind: String?
            if arg.value.hasPrefix("-"), let equals = arg.value.firstIndex(of: "=") {
                let flag = String(arg.value[..<equals]).trimmingCharacters(in: dashes)
                kind = detect(name: flag, value: String(arg.value[arg.value.index(after: equals)...]))
            } else if !arg.value.hasPrefix("-") {
                let previous = index > 0 ? args[index - 1].value : ""
                if previous.hasPrefix("-"), !previous.contains("="), nameLooksSecret(previous.trimmingCharacters(in: dashes)) {
                    kind = detect(name: previous.trimmingCharacters(in: dashes), value: arg.value)
                } else if let shaped = tokenKind(arg.value) {
                    kind = shaped
                } else if arg.value.count >= 20, MCPRedaction.looksRandom(arg.value), !arg.value.contains("/") {
                    kind = "a key, by its shape"
                }
            }
            guard let kind else { continue }
            found.append(Detected(field: .argument(index), variable: "argument \(index + 1)", value: SecretBytes(utf8: arg.value), kind: kind,
                                  notMovable: argumentReason, range: arg.range))
        }
        return found
    }

    // MARK: JSON

    /// The scalar offset of an index in `text`.
    static func offset(_ index: String.Index, in text: String) -> Int {
        text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: index)
    }

    static func offsets(_ range: Range<String.Index>, in text: String) -> Range<Int> {
        offset(range.lowerBound, in: text)..<offset(range.upperBound, in: text)
    }

    /// The containers a JSON source has: its own, or for `~/.claude.json` the top-level `mcpServers` and each
    /// project's.
    static func containers(of source: Source, root: JSONC.Object) -> [[String]] {
        if let containers = source.containers { return containers }
        var list = [["mcpServers"]]
        if let projects = root.member("projects"), case .object(let object) = projects.value {
            for project in object.members {
                guard case .object(let settings) = project.value, settings.member("mcpServers") != nil else { continue }
                list.append(["projects", project.key, "mcpServers"])
            }
        }
        return list
    }

    /// The object at `path` from the root.
    static func object(at path: [String], in root: JSONC.Object) -> JSONC.Object? {
        var current = root
        for key in path {
            guard let member = current.member(key), case .object(let object) = member.value else { return nil }
            current = object
        }
        return current
    }

    static func jsonEntries(_ text: String, source: Source) -> [Entry]? {
        guard let document = JSONC(text), case .object(let root)? = document.root else { return nil }
        let strictRefusal: String? = source.format == .strictJSON && (document.hasComments || document.hasTrailingCommas)
            ? "comments in a file that must be plain JSON" : nil
        var entries: [Entry] = []
        for path in containers(of: source, root: root) {
            guard let servers = object(at: path, in: root) else { continue }
            let repeated = servers.hasRepeatedKeys
            for member in servers.members {
                guard case .object(let object) = member.value else { continue }
                var entry = Entry(location: Location(container: path, server: member.key), range: offsets(member.value.range, in: text),
                                  command: [], args: [])
                entry.hasComments = String(text.unicodeScalars[member.value.range]).contains("//")
                    || String(text.unicodeScalars[member.value.range]).contains("/*")
                read(object, into: &entry, document: document, text: text, client: source.client)
                if repeated || object.hasRepeatedKeys { entry.notMovable = "repeated keys" }
                if entry.notMovable == nil { entry.notMovable = strictRefusal }
                entries.append(entry)
            }
        }
        return entries
    }

    /// An entry's command, arguments, env and headers.
    static func read(_ object: JSONC.Object, into entry: inout Entry, document: JSONC, text: String, client: Client) {
        func string(_ value: JSONC.Value) -> String? { value.object(in: text) as? String }
        func strings(_ value: JSONC.Value?) -> [(value: String, range: Range<Int>)]? {
            guard let value else { return [] }
            guard let elements = document.elements(of: value) else { return nil }
            var list: [(String, Range<Int>)] = []
            for element in elements {
                guard case .scalar(let range) = element, let word = string(element) else { return nil }
                list.append((word, offsets(range, in: text)))
            }
            return list
        }
        for name in ["headers", "http_headers"] { entry.detected += headerFindings(object.member(name)?.value, text: text) }
        let commandValue = object.member("command")?.value
        var args: [(value: String, range: Range<Int>)] = []
        if client == .opencode {
            // opencode: the command and its arguments are one array.
            guard let words = strings(commandValue), !words.isEmpty else { return shapeRefusal(&entry, object) }
            entry.command = [words[0].value]
            args = Array(words.dropFirst())
        } else {
            guard let value = commandValue, case .scalar = value, let command = string(value) else { return shapeRefusal(&entry, object) }
            entry.command = [command]
            guard let words = strings(object.member("args")?.value) else {
                entry.notMovable = "its args are not a list of words"
                return
            }
            args = words
        }
        entry.args = args.map(\.value)
        entry.isWrapped = isWrapped(command: entry.command + entry.args)
        entry.detected += argumentFindings(args)
        let envName = client == .opencode ? "environment" : "env"
        guard let env = object.member(envName) else { return }
        guard case .object(let variables) = env.value else {
            entry.notMovable = "its \(envName) is not an object"
            return
        }
        for variable in variables.members {
            guard case .scalar(let range) = variable.value, let value = string(variable.value), let kind = detect(name: variable.key, value: value) else {
                continue
            }
            entry.detected.append(Detected(field: .env(variable.key), variable: variable.key, value: SecretBytes(utf8: value), kind: kind,
                                           notMovable: valueRefusal(variable: variable.key, value: value), range: offsets(range, in: text)))
        }
    }

    /// An entry with no command to wrap (an HTTP server, an odd shape): its headers and env are still listed.
    static func shapeRefusal(_ entry: inout Entry, _ object: JSONC.Object) {
        let isHTTP = object.member("url") != nil || object.member("httpUrl") != nil
        entry.notMovable = isHTTP ? headerReason : "a shape Next Term can't edit: it has no command to start"
    }

    static func headerFindings(_ value: JSONC.Value?, text: String) -> [Detected] {
        guard let value, case .object(let headers) = value else { return [] }
        var found: [Detected] = []
        for header in headers.members {
            guard case .scalar(let range) = header.value, let raw = header.value.object(in: text) as? String else { continue }
            let bare = raw.hasPrefix("Bearer ") ? String(raw.dropFirst(7)) : raw
            let name = header.key.lowercased() == "authorization" ? "AUTH" : header.key
            guard let kind = detect(name: name, value: bare) else { continue }
            found.append(Detected(field: .header(header.key), variable: header.key, value: SecretBytes(utf8: raw), kind: kind, notMovable: headerReason,
                                  range: offsets(range, in: text)))
        }
        return found
    }

    // MARK: TOML

    /// A TOML value read with its place: a single-line string, an array of them, or an inline table of them.
    struct TOMLReader {
        let outline: TOMLOutline
        let scalars: String.UnicodeScalarView

        init(_ outline: TOMLOutline) {
            self.outline = outline
            scalars = outline.text.unicodeScalars
        }

        func skipSpace(_ i: inout String.Index) {
            while i < scalars.endIndex {
                if scalars[i] == "#" {
                    while i < scalars.endIndex, scalars[i] != "\n" { i = scalars.index(after: i) }
                } else if scalars[i].properties.isWhitespace {
                    i = scalars.index(after: i)
                } else {
                    return
                }
            }
        }

        /// An array of single-line strings at `start`: each with its range, and where the array ends.
        func strings(at start: String.Index) -> (elements: [(value: String, range: Range<String.Index>)], end: String.Index)? {
            guard start < scalars.endIndex, scalars[start] == "[" else { return nil }
            var i = scalars.index(after: start)
            var elements: [(String, Range<String.Index>)] = []
            while true {
                skipSpace(&i)
                guard i < scalars.endIndex else { return nil }
                if scalars[i] == "]" { return (elements, scalars.index(after: i)) }
                guard let (range, value) = outline.string(at: i) else { return nil }
                elements.append((value, range))
                i = range.upperBound
                skipSpace(&i)
                guard i < scalars.endIndex else { return nil }
                if scalars[i] == "," { i = scalars.index(after: i) }
            }
        }

        struct Member {
            let key: String
            /// From the key to the end of its value.
            let range: Range<String.Index>
            let value: (range: Range<String.Index>, text: String)?
        }

        /// An inline table at `start` whose members are single keys: each member, and where the table ends.
        func members(at start: String.Index) -> (members: [Member], end: String.Index)? {
            guard start < scalars.endIndex, scalars[start] == "{" else { return nil }
            var i = scalars.index(after: start)
            var members: [Member] = []
            while true {
                skipSpace(&i)
                guard i < scalars.endIndex else { return nil }
                if scalars[i] == "}" { return (members, scalars.index(after: i)) }
                let keyStart = i
                var key: String
                if scalars[i] == "\"" || scalars[i] == "'" {
                    guard let (range, value) = outline.string(at: i) else { return nil }
                    key = value
                    i = range.upperBound
                } else {
                    var bare = String.UnicodeScalarView()
                    while i < scalars.endIndex, Self.bare.contains(scalars[i]) {
                        bare.append(scalars[i])
                        i = scalars.index(after: i)
                    }
                    guard !bare.isEmpty else { return nil }
                    key = String(bare)
                }
                skipSpace(&i)
                guard i < scalars.endIndex, scalars[i] == "=" else { return nil } // a dotted key: not read here
                i = scalars.index(after: i)
                skipSpace(&i)
                guard let (range, value) = outline.string(at: i) else { return nil }
                i = range.upperBound
                members.append(Member(key: key, range: keyStart..<range.upperBound, value: (range, value)))
                skipSpace(&i)
                guard i < scalars.endIndex else { return nil }
                if scalars[i] == "," { i = scalars.index(after: i) }
                key = ""
            }
        }

        static let bare = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".unicodeScalars)
    }

    /// One `[mcp_servers.NAME]` table and what it holds.
    struct TOMLTable {
        let name: String
        let header: TOMLOutline.Header
        /// From its header to the next table that is not one of its own, short of the comments just above that.
        let range: Range<String.Index>
        let keys: [TOMLOutline.Key]
        /// Keys of `[mcp_servers.NAME.env]`.
        let envKeys: [TOMLOutline.Key]
        let envHeader: TOMLOutline.Header?
    }

    static func tomlTables(_ outline: TOMLOutline) -> [TOMLTable] {
        var tables: [TOMLTable] = []
        let headers = outline.headers
        for (index, header) in headers.enumerated() where !header.isArray && header.path.count == 2 && header.path[0] == "mcp_servers" {
            let name = header.path[1]
            let own = ["mcp_servers", name]
            let next = headers[(index + 1)...].first { !$0.path.starts(with: own) || $0.path == own }
            let end = next.map { outline.commentsAbove($0.line.lowerBound) } ?? outline.text.unicodeScalars.endIndex
            let keys = outline.keys.filter { $0.table == own }
            let envKeys = outline.keys.filter { $0.table == own + ["env"] }
            let envHeader = headers.first { $0.path == own + ["env"] && !$0.isArray }
            tables.append(TOMLTable(name: name, header: header, range: header.line.lowerBound..<max(end, header.line.upperBound), keys: keys,
                                    envKeys: envKeys, envHeader: envHeader))
        }
        return tables
    }

    /// Servers written another way (dotted keys, inline): listed with what to write by hand.
    static func tomlOddServers(_ outline: TOMLOutline) -> Set<String> {
        var names = Set<String>()
        for key in outline.keys {
            let full = key.table + key.path
            guard full.count >= 3, full[0] == "mcp_servers" else { continue }
            let tableShape = key.table == Array(full.prefix(2)) || key.table == Array(full.prefix(3)) && full[2] == "env"
            if !tableShape { names.insert(full[1]) }
        }
        return names
    }

    static func tomlEntries(_ text: String) -> [Entry]? {
        guard let outline = TOMLOutline(text) else { return nil }
        let reader = TOMLReader(outline)
        var entries: [Entry] = []
        let odd = tomlOddServers(outline)
        for table in tomlTables(outline) {
            var entry = Entry(location: Location(container: ["mcp_servers"], server: table.name), range: offsets(table.range, in: text),
                              command: [], args: [])
            if let command = table.keys.first(where: { $0.path == ["command"] }), let (_, value) = outline.string(at: command.value) {
                entry.command = [value]
            } else {
                entry.notMovable = table.keys.contains { $0.path == ["url"] } ? headerReason : "a shape Next Term can't edit: it has no command string"
            }
            var args: [(value: String, range: Range<Int>)] = []
            if let key = table.keys.first(where: { $0.path == ["args"] }) {
                if let (elements, _) = reader.strings(at: key.value) {
                    args = elements.map { ($0.value, offsets($0.range, in: text)) }
                } else {
                    entry.notMovable = entry.notMovable ?? "its args are not a list of words"
                }
            }
            entry.args = args.map(\.value)
            entry.isWrapped = isWrapped(command: entry.command + entry.args)
            entry.detected += argumentFindings(args)
            if let headers = table.keys.first(where: { $0.path == ["http_headers"] }), let (members, _) = reader.members(at: headers.value) {
                for member in members {
                    guard let value = member.value, let kind = detect(name: member.key == "Authorization" ? "AUTH" : member.key,
                                                                       value: value.text.hasPrefix("Bearer ") ? String(value.text.dropFirst(7)) : value.text)
                    else { continue }
                    entry.detected.append(Detected(field: .header(member.key), variable: member.key, value: SecretBytes(utf8: value.text), kind: kind,
                                                   notMovable: headerReason, range: offsets(value.range, in: text)))
                }
            }
            var variables: [(key: String, value: String, range: Range<String.Index>)] = []
            if let env = table.keys.first(where: { $0.path == ["env"] }) {
                if let (members, _) = reader.members(at: env.value) {
                    for member in members { if let value = member.value { variables.append((member.key, value.text, value.range)) } }
                } else {
                    entry.notMovable = entry.notMovable ?? "its env is written in a shape Next Term can't edit"
                }
            }
            for key in table.envKeys where key.path.count == 1 {
                if let (range, value) = outline.string(at: key.value) { variables.append((key.path[0], value, range)) }
            }
            for variable in variables {
                guard let kind = detect(name: variable.key, value: variable.value) else { continue }
                entry.detected.append(Detected(field: .env(variable.key), variable: variable.key, value: SecretBytes(utf8: variable.value), kind: kind,
                                               notMovable: valueRefusal(variable: variable.key, value: variable.value),
                                               range: offsets(variable.range, in: text)))
            }
            if odd.contains(table.name) { entry.notMovable = oddShapeReason(table.name) }
            entries.append(entry)
        }
        // Servers with no table of their own (all dotted keys): what they hold is listed, not movable.
        for name in odd.subtracting(entries.map(\.location.server)).sorted() {
            var entry = Entry(location: Location(container: ["mcp_servers"], server: name), range: 0..<0, command: [], args: [])
            entry.notMovable = oddShapeReason(name)
            for key in outline.keys {
                let full = key.table + key.path
                guard full.count == 4, full[0] == "mcp_servers", full[1] == name, full[2] == "env",
                      let (range, value) = outline.string(at: key.value), let kind = detect(name: full[3], value: value) else { continue }
                entry.detected.append(Detected(field: .env(full[3]), variable: full[3], value: SecretBytes(utf8: value), kind: kind,
                                               notMovable: entry.notMovable, range: offsets(range, in: text)))
            }
            entries.append(entry)
        }
        return entries
    }

    /// Why a server written with dotted keys can't move, with what to write by hand (names only).
    static func oddShapeReason(_ server: String) -> String {
        "written in a shape Next Term can't edit. By hand: in [mcp_servers.\(server)], set command to the nxtrm path and put "
            + "secret, run, the key's name and -- before the old command in args, then remove the key from env"
    }

    // MARK: groups

    /// Identical values, one Next Term key: its findings, its suggested name, and its kind.
    public struct Group: Sendable {
        public let id: String
        public var name: String
        public let value: SecretBytes
        public let findings: [Finding]
        public var kind: String { findings.first?.kind ?? "key" }
        /// "Same value in 3 servers" when it is in more than one.
        public var summary: String? {
            let servers = Set(findings.map { $0.source.path + "\u{0}" + $0.location.description })
            return servers.count > 1 ? "Same value in \(servers.count) servers" : nil
        }
    }

    /// The movable findings grouped by identical value, each group named after its first variable (capitals, `_`); a
    /// clash with a stored key or another group adds `_2`, `_3`. A group holds at most one variable of each entry.
    public static func groups(_ findings: [Finding], stored: [String]) -> [Group] {
        var groups: [(value: SecretBytes, findings: [Finding])] = []
        for finding in findings where finding.movable {
            // An entry that holds the value under two variables needs a key for each: the wrapper takes a name once.
            let sameEntry = { (other: Finding) in other.source.path == finding.source.path && other.location == finding.location }
            if let index = groups.firstIndex(where: { $0.value == finding.value && !$0.findings.contains(where: sameEntry) }) {
                groups[index].findings.append(finding)
            } else {
                groups.append((finding.value, [finding]))
            }
        }
        var taken = Set(stored)
        return groups.map { group in
            let base = StoredSecretName.suggested(from: group.findings[0].variable)
            var name = base
            var number = 2
            while taken.contains(name) {
                let suffix = "_\(number)"
                name = String(base.prefix(StoredSecretName.maxLength - suffix.count)) + suffix
                number += 1
            }
            taken.insert(name)
            return Group(id: group.findings[0].id, name: name, value: group.value, findings: group.findings)
        }
    }

    // MARK: plans

    /// One key to move: its name in Secrets and the findings it replaces.
    public struct Move: Sendable {
        public let name: String
        public let findings: [Finding]

        public init(name: String, findings: [Finding]) {
            self.name = name
            self.findings = findings
        }
    }

    /// One entry's backup: the entry as it was, its detected values replaced by markers, and the SHA-256 of
    /// what Next Term wrote. The values left in place are sealed by the app (`keptBox`); `keptValues` is in memory only.
    public struct EntryBackup: Codable, Sendable {
        public let id: String
        /// The import it was part of: Undo puts an import's entries back together.
        public let batch: String
        public let date: Date
        public let path: String
        public let client: Client
        public let format: Format
        public let location: Location
        /// The keys moved out of it, by their names in Secrets.
        public let names: [String]
        public let original: String
        public let written: String
        public let keptCount: Int
        public var keptBox: Data?
        public var keptValues: [SecretBytes] = []

        enum CodingKeys: String, CodingKey {
            case id, batch, date, path, client, format, location, names, original, written, keptCount = "kept_count", keptBox = "kept_box"
        }

        /// The record's file name in `imports/`.
        public var fileName: String { "\(SecretFolder.day(of: date))-\(id).json" }

        public func encoded() -> Data? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try? encoder.encode(self)
        }

        public static func decode(_ data: Data) -> EntryBackup? {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(EntryBackup.self, from: data)
        }
    }

    /// One file's change: its new text, the bytes it was planned from, and a backup for each entry it changes.
    public struct FileEdit: Sendable {
        public let source: Source
        public let servers: [String]
        public internal(set) var backups: [EntryBackup]
        let moves: [Move]
        let nxtrm: [String]
        let plan: MCPRegistrar.Plan

        public var path: String { source.path }
        /// The keys it moves.
        public var names: [String] { Array(Set(moves.map(\.name))).sorted() }

        /// Sets one backup's sealed kept values: the app seals them during the import's Touch ID.
        public mutating func seal(_ id: String, box: Data?) {
            guard let index = backups.firstIndex(where: { $0.id == id }) else { return }
            backups[index].keptBox = box
        }
    }

    /// Why a file has no edit.
    public struct PlanFailure: Error, Sendable, Equatable {
        public let path: String
        public let reason: String
    }

    static let marker = "⟦nextterm:"

    static func markerText(_ name: String) -> String { "\(marker)\(name)⟧" }
    static func keptMarker(_ index: Int) -> String { "\(marker)kept:\(index)⟧" }

    /// One `FileEdit` per file the chosen moves touch. `nxtrm` is the wrapper's command: the `nxtrm` path, or the app's
    /// binary and `--cli`.
    public static func plan(_ moves: [Move], nxtrm: [String], read: (String) -> Data? = readFile,
                            now: Date = Date()) -> (edits: [FileEdit], failures: [PlanFailure]) {
        var byFile: [String: (Source, [Move])] = [:]
        var order: [String] = []
        for move in moves {
            for finding in move.findings where finding.movable {
                if byFile[finding.source.path] == nil {
                    byFile[finding.source.path] = (finding.source, [])
                    order.append(finding.source.path)
                }
                byFile[finding.source.path]?.1.append(Move(name: move.name, findings: [finding]))
            }
        }
        var edits: [FileEdit] = []
        var failures: [PlanFailure] = []
        let batch = String(UUID().uuidString.lowercased().prefix(12))
        for path in order {
            guard let (source, fileMoves) = byFile[path] else { continue }
            guard let data = read(path) else {
                failures.append(PlanFailure(path: path, reason: "it can't be read"))
                continue
            }
            switch planFile(source, moves: fileMoves, nxtrm: nxtrm, data: data, now: now, batch: batch) {
            case .success(let edit): edits.append(edit)
            case .failure(let failure): failures.append(failure)
            }
        }
        return (edits, failures)
    }

    /// A file's edit from its bytes: each entry changed in turn, each with its backup.
    static func planFile(_ source: Source, moves: [Move], nxtrm: [String], data: Data, now: Date,
                         batch: String) -> Result<FileEdit, PlanFailure> {
        guard var text = text(of: data) else { return .failure(PlanFailure(path: source.path, reason: "not UTF-8 text")) }
        // The moves by entry, in the order the file has them.
        var byEntry: [Location: [(name: String, variable: String)]] = [:]
        var locations: [Location] = []
        for move in moves {
            for finding in move.findings {
                guard case .env(let variable) = finding.field else { continue }
                if byEntry[finding.location] == nil { locations.append(finding.location) }
                byEntry[finding.location, default: []].append((move.name, variable))
            }
        }
        var backups: [EntryBackup] = []
        for location in locations {
            guard let pairs = byEntry[location] else { continue }
            let result = source.format == .toml
                ? editTOML(text, location: location, pairs: pairs, nxtrm: nxtrm)
                : editJSON(text, source: source, location: location, pairs: pairs, nxtrm: nxtrm)
            switch result {
            case .failure(let failure): return .failure(PlanFailure(path: source.path, reason: failure.reason))
            case .success(let edited):
                let id = UUID().uuidString.lowercased().prefix(12)
                backups.append(EntryBackup(id: String(id), batch: batch, date: now, path: source.path, client: source.client, format: source.format,
                                           location: location, names: pairs.map(\.name), original: edited.original, written: edited.written,
                                           keptCount: edited.kept.count, keptBox: nil, keptValues: edited.kept))
                text = edited.text
            }
        }
        var plan = MCPRegistrar.Plan(.registered, text: text)
        plan.original = data
        return .success(FileEdit(source: source, servers: locations.map(\.server), backups: backups, moves: moves, nxtrm: nxtrm, plan: plan))
    }

    /// Why an entry's edit can't be made.
    struct EditFailure: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// What an entry's edit made: the file's new text, the entry's backup text and digest, and the values kept.
    struct Edited {
        var text: String
        var original: String
        var written: String
        var kept: [SecretBytes]
    }

    /// The new args: `secret`, `run`, each `NAME` or `NAME=ENVNAME`, `--`, then the old command and its arguments.
    static func wrapped(_ pairs: [(name: String, variable: String)], nxtrm: [String], command: [String]) -> [String] {
        Array(nxtrm.dropFirst()) + ["secret", "run"] + keyArguments(pairs) + ["--"] + command
    }

    /// Each key as the wrapper takes it: `NAME`, or `NAME=ENVNAME` when the server reads it under another name.
    static func keyArguments(_ pairs: [(name: String, variable: String)]) -> [String] {
        pairs.map { $0.name == $0.variable ? $0.name : "\($0.name)=\($0.variable)" }
    }

    /// The entry's text with every detected value replaced by its marker, and the values kept in place, in order.
    static func marked(_ text: String, entry: Entry, moved: [String: String]) -> (text: String, kept: [SecretBytes]) {
        let scalars = Array(text.unicodeScalars)
        let detected = entry.detected.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var out = String.UnicodeScalarView()
        var cursor = entry.range.lowerBound
        var kept: [SecretBytes] = []
        for found in detected where found.range.lowerBound >= cursor && found.range.upperBound <= entry.range.upperBound {
            out.append(contentsOf: scalars[cursor..<found.range.lowerBound])
            let name: String?
            if case .env(let variable) = found.field { name = moved[variable] } else { name = nil }
            let marker: String
            if let name {
                marker = markerText(name)
            } else {
                marker = keptMarker(kept.count)
                kept.append(found.value)
            }
            out.append(contentsOf: "\"\(marker)\"".unicodeScalars)
            cursor = found.range.upperBound
        }
        out.append(contentsOf: scalars[cursor..<entry.range.upperBound])
        return (String(out), kept)
    }

    static func sha256(_ text: String) -> String { SecretRun.digest(Data(text.utf8)) }

    /// Replaces scalar ranges of `text`. An insertion (an empty range) goes before a change that starts where it does,
    /// so a line added after `args` comes before the `env` line removed there. Ranges that overlap, or run past the
    /// end, give nil: the edit is refused rather than guessed.
    static func replacing(_ text: String, _ changes: [(range: Range<Int>, with: String)]) -> String? {
        let scalars = Array(text.unicodeScalars)
        let ordered = changes.indices.sorted { first, second in
            let a = changes[first].range
            let b = changes[second].range
            if a.lowerBound != b.lowerBound { return a.lowerBound < b.lowerBound }
            if a.isEmpty != b.isEmpty { return a.isEmpty }
            return first < second
        }
        var out = String.UnicodeScalarView()
        var cursor = 0
        for index in ordered {
            let change = changes[index]
            guard change.range.lowerBound >= cursor, change.range.upperBound <= scalars.count else { return nil }
            out.append(contentsOf: scalars[cursor..<change.range.lowerBound])
            out.append(contentsOf: change.with.unicodeScalars)
            cursor = change.range.upperBound
        }
        out.append(contentsOf: scalars[cursor...])
        return String(out)
    }

    /// Why `nxtrm secret run` could not start the entry as planned: its keys and their variables, then the command, as
    /// the wrapper parses them. Nil when they parse.
    static func wrapperRefusal(_ pairs: [(name: String, variable: String)], command: [String]) -> String? {
        guard case .failure(let error) = SecretRun.parse(keyArguments(pairs) + ["--"] + command) else { return nil }
        return "nxtrm secret run couldn't start it that way: \(error.reason); give each key its own name, or edit it by hand"
    }

    static func editJSON(_ text: String, source: Source, location: Location, pairs: [(name: String, variable: String)],
                         nxtrm: [String]) -> Result<Edited, EditFailure> {
        guard let entries = jsonEntries(text, source: source), let entry = entries.first(where: { $0.location == location }) else {
            return .failure(EditFailure("the entry is not there any more"))
        }
        if let reason = entry.notMovable { return .failure(EditFailure(reason)) }
        if let reason = wrapperRefusal(pairs, command: entry.command + entry.args) { return .failure(EditFailure(reason)) }
        guard let document = JSONC(text), case .object(let root)? = document.root, let servers = object(at: location.container, in: root),
              let member = servers.member(location.server), var planned = member.value.object(in: text) as? [String: Any] else {
            return .failure(EditFailure("the entry can't be read"))
        }
        let envKey = source.client == .opencode ? "environment" : "env"
        var env = planned[envKey] as? [String: Any] ?? [:]
        for pair in pairs {
            guard env[pair.variable] is String else { return .failure(EditFailure("\(pair.variable) is not in the entry any more")) }
            env[pair.variable] = nil
        }
        if env.isEmpty {
            planned.removeValue(forKey: envKey)
        } else {
            planned[envKey] = env
        }
        if source.client == .opencode {
            planned["command"] = [nxtrm[0]] + wrapped(pairs, nxtrm: nxtrm, command: entry.command + entry.args)
        } else {
            planned["command"] = nxtrm[0]
            planned["args"] = wrapped(pairs, nxtrm: nxtrm, command: entry.command + entry.args)
        }
        guard let newEntry = MCPRegistrar.compact(planned) else { return .failure(EditFailure("the new entry can't be written")) }
        let moved = Dictionary(pairs.map { ($0.variable, $0.name) }, uniquingKeysWith: { first, _ in first })
        let backup = marked(text, entry: entry, moved: moved)
        guard let updated = replacing(text, [(entry.range, newEntry)]),
              verifyJSON(updated, before: text, source: source, location: location, planned: planned) else {
            return .failure(EditFailure("check failed"))
        }
        return .success(Edited(text: updated, original: backup.text, written: sha256(newEntry), kept: backup.kept))
    }

    /// The edit parses, the entry is what was planned, and every other server is as it was; a strict file parses plainly.
    static func verifyJSON(_ text: String, before: String, source: Source, location: Location, planned: [String: Any]) -> Bool {
        guard let document = JSONC(text), case .object(let root)? = document.root, let servers = object(at: location.container, in: root),
              let member = servers.member(location.server), let written = member.value.object(in: text) as? [String: Any],
              NSDictionary(dictionary: written).isEqual(to: planned) else { return false }
        guard let old = JSONC(before), case .object(let oldRoot)? = old.root, let oldServers = object(at: location.container, in: oldRoot),
              oldServers.members.count == servers.members.count else { return false }
        for (new, previous) in zip(servers.members, oldServers.members) where new.key != location.server {
            guard new.key == previous.key, document.string(new.value.range) == old.string(previous.value.range) else { return false }
        }
        if source.format == .strictJSON, (try? JSONSerialization.jsonObject(with: Data(text.utf8))) == nil { return false }
        return true
    }

    static func editTOML(_ text: String, location: Location, pairs: [(name: String, variable: String)],
                         nxtrm: [String]) -> Result<Edited, EditFailure> {
        guard let entries = tomlEntries(text), let entry = entries.first(where: { $0.location == location }) else {
            return .failure(EditFailure("the entry is not there any more"))
        }
        if let reason = entry.notMovable { return .failure(EditFailure(reason)) }
        if let reason = wrapperRefusal(pairs, command: entry.command + entry.args) { return .failure(EditFailure(reason)) }
        guard let outline = TOMLOutline(text), let table = tomlTables(outline).first(where: { $0.name == location.server }),
              let command = table.keys.first(where: { $0.path == ["command"] }), let commandString = outline.string(at: command.value) else {
            return .failure(EditFailure("the entry can't be read"))
        }
        let reader = TOMLReader(outline)
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let args = wrapped(pairs, nxtrm: nxtrm, command: entry.command + entry.args)
        let argsText = "[" + args.map(MCPRegistrar.tomlString).joined(separator: ", ") + "]"
        var changes: [(range: Range<Int>, with: String)] = [(offsets(commandString.range, in: text), MCPRegistrar.tomlString(nxtrm[0]))]
        // New lines go after args, or after command when there was no args.
        var inserted: [String] = []
        var anchor = command.line.upperBound
        if let argsKey = table.keys.first(where: { $0.path == ["args"] }), let (_, end) = reader.strings(at: argsKey.value) {
            changes.append((offsets(argsKey.value..<end, in: text), argsText))
            anchor = argsKey.line.upperBound
        } else {
            inserted.append("args = " + argsText)
        }
        let moved = Set(pairs.map(\.variable))
        if let env = table.keys.first(where: { $0.path == ["env"] }), let (members, end) = reader.members(at: env.value) {
            let left = members.filter { !moved.contains($0.key) }.map { String(text.unicodeScalars[$0.range]) }
            if left.isEmpty {
                changes.append((offsets(env.line, in: text), ""))
            } else {
                changes.append((offsets(env.value..<end, in: text), "{ " + left.joined(separator: ", ") + " }"))
            }
        }
        for key in table.envKeys where key.path.count == 1 && moved.contains(key.path[0]) {
            changes.append((offsets(key.line, in: text), ""))
        }
        // Codex waits 10 seconds by default: the wrapper's 25-second line needs 30.
        let seconds = table.keys.first { $0.path == ["startup_timeout_sec"] }
        let milliseconds = table.keys.first { $0.path == ["startup_timeout_ms"] }
        if let key = seconds ?? milliseconds {
            let wanted = seconds != nil ? codexTimeout : codexTimeout * 1000
            let value = bareValue(at: key.value, in: text)
            if let number = Double(value.text), number < Double(wanted) {
                changes.append((offsets(key.value..<value.end, in: text), String(wanted)))
            }
        } else {
            inserted.append("startup_timeout_sec = \(codexTimeout)")
        }
        if !inserted.isEmpty {
            let at = offset(anchor, in: text)
            let lineEnds = anchor > text.unicodeScalars.startIndex && text.unicodeScalars[text.unicodeScalars.index(before: anchor)] == "\n"
            let lines = inserted.map { $0 + newline }.joined()
            changes.append((at..<at, (lineEnds ? "" : newline) + lines))
        }
        let movedNames = Dictionary(pairs.map { ($0.variable, $0.name) }, uniquingKeysWith: { first, _ in first })
        let backup = marked(text, entry: entry, moved: movedNames)
        guard let updated = replacing(text, changes) else { return .failure(EditFailure("check failed")) }
        guard let check = TOMLOutline(updated), let newTable = tomlTables(check).first(where: { $0.name == location.server }),
              let newEntry = tomlEntries(updated)?.first(where: { $0.location == location }),
              newEntry.command == [nxtrm[0]], newEntry.args == args,
              !newEntry.detected.contains(where: { if case .env(let name) = $0.field { return moved.contains(name) }; return false }) else {
            return .failure(EditFailure("check failed"))
        }
        // Everything outside the entry is as it was.
        let oldScalars = Array(text.unicodeScalars)
        let newScalars = Array(updated.unicodeScalars)
        let oldRange = entry.range
        let newRange = offsets(newTable.range, in: updated)
        guard Array(oldScalars[..<oldRange.lowerBound]) == Array(newScalars[..<newRange.lowerBound]),
              Array(oldScalars[oldRange.upperBound...]) == Array(newScalars[newRange.upperBound...]) else { return .failure(EditFailure("check failed")) }
        let writtenText = String(String.UnicodeScalarView(newScalars[newRange]))
        return .success(Edited(text: updated, original: backup.text, written: sha256(writtenText), kept: backup.kept))
    }

    /// A bare value (a number) at `index`, and where it ends.
    static func bareValue(at index: String.Index, in text: String) -> (text: String, end: String.Index) {
        let scalars = text.unicodeScalars
        var i = index
        let ends: Set<Unicode.Scalar> = [" ", "\t", "#", "\n", "\r", ","]
        while i < scalars.endIndex, !ends.contains(scalars[i]) { i = scalars.index(after: i) }
        return (String(scalars[index..<i]), i)
    }

    // MARK: writing

    /// How a file's write went.
    public enum Applied: Equatable, Sendable {
        case written
        /// The file changed again after it was planned a second time.
        case changed
        /// Claude Code held its lock for 5 seconds.
        case locked
        /// Read-only, a link to nothing, the Claude app open, or an entry changed since the import.
        case skipped(String)
        case failed(String)
    }

    public static let lockedNote = "Claude Code is saving its settings. Try again in a moment."

    /// Writes one file's edit: read again, planned once more if its bytes changed, under Claude Code's lock for
    /// `~/.claude.json`, through `MCPRegistrar.write(_:to:)`, and checked after.
    public static func apply(_ edit: FileEdit, lockWait: TimeInterval = 5, isOpen: (String) -> Bool = { _ in false },
                             read: (String) -> Data? = readFile) -> Applied {
        if let app = edit.source.readOnceBy, isOpen(app) { return .skipped(claudeAppOpenReason) }
        if let refusal = fileRefusal(edit.path) { return .skipped(refusal) }
        var lock: ClaudeConfigLock?
        if edit.source.isClaudeConfig {
            guard let taken = ClaudeConfigLock.acquire(for: edit.path, wait: lockWait) else { return .locked }
            lock = taken
        }
        defer { lock?.release() }
        guard let current = read(edit.path) else { return .changed }
        var used = edit
        if current != edit.plan.original {
            // Saved by its agent since the plan: once more from what is there now.
            let batch = edit.backups.first?.batch ?? ""
            guard case .success(let again) = planFile(edit.source, moves: edit.moves, nxtrm: edit.nxtrm, data: current, now: Date(), batch: batch),
                  again.written(like: edit) else { return .changed }
            used = again
        }
        let applied = write(used.plan, to: edit.path, read: read)
        guard applied == .written else { return applied }
        guard let back = read(edit.path), verify(used, written: back) else { return .failed("the file reads differently after the write") }
        return .written
    }

    /// Why a file is left as it is: a link to a file that is not there (a write would put a file in its place), or one
    /// this account can't write.
    static func fileRefusal(_ path: String) -> String? {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil, !FileManager.default.fileExists(atPath: path) {
            return "a link to a file that is not there"
        }
        if FileManager.default.fileExists(atPath: path), !FileManager.default.isWritableFile(atPath: path) { return "read-only" }
        return nil
    }

    /// Writes a plan through `MCPRegistrar.write`, then reads the file back.
    static func write(_ plan: MCPRegistrar.Plan, to path: String, read: (String) -> Data?) -> Applied {
        guard let expected = plan.text else { return .failed("nothing to write") }
        switch MCPRegistrar.write(plan, to: path) {
        case .skipped(let reason):
            if reason.contains("changed") { return .changed }
            return reason == "write" ? .failed("the file couldn't be written") : .skipped(reason)
        default: break
        }
        guard let back = read(path), text(of: back) == expected else { return .failed("the file reads differently after the write") }
        return .written
    }

    /// The file as written is what the edit planned: each entry Next Term wrote, by its digest, and nothing else changed.
    public static func verify(_ edit: FileEdit, written data: Data) -> Bool {
        guard let text = text(of: data), text == edit.plan.text else { return false }
        return edit.backups.allSatisfy { backup in entryText(backup.location, format: backup.format, in: text).map(sha256) == backup.written }
    }

    /// The text of the entry at `location` now, or nil when it is not there.
    static func entryText(_ location: Location, format: Format, in text: String) -> String? {
        if format == .toml {
            guard let outline = TOMLOutline(text), let table = tomlTables(outline).first(where: { $0.name == location.server }) else { return nil }
            return String(text.unicodeScalars[table.range])
        }
        guard let document = JSONC(text), case .object(let root)? = document.root, let servers = object(at: location.container, in: root),
              let member = servers.member(location.server) else { return nil }
        return document.string(member.value.range)
    }

    // MARK: Undo

    public enum UndoPlan: Equatable, Sendable {
        case text(String)
        /// The entry is not what Next Term wrote any more.
        case changedSince
        /// A key it held is no longer stored.
        case keyMissing(String)
    }

    /// The file's text with that entry put back: its markers filled from `values` (by name) and `kept` (in order).
    public static func undoPlan(_ backup: EntryBackup, current text: String, values: [String: SecretBytes], kept: [SecretBytes]) -> UndoPlan {
        guard let now = entryText(backup.location, format: backup.format, in: text), sha256(now) == backup.written else {
            return .changedSince
        }
        var filled = backup.original
        for name in Set(backup.names) {
            guard let value = values[name]?.utf8String() else { return .keyMissing(name) }
            filled = filled.replacingOccurrences(of: "\"\(markerText(name))\"", with: literal(value, format: backup.format))
        }
        for (index, value) in kept.enumerated() {
            guard let text = value.utf8String() else { continue }
            filled = filled.replacingOccurrences(of: "\"\(keptMarker(index))\"", with: literal(text, format: backup.format))
        }
        guard !filled.contains(marker) else { return .keyMissing("a value kept in place") }
        guard let range = entryRange(backup.location, format: backup.format, in: text) else { return .changedSince }
        guard let updated = replacing(text, [(range, filled)]) else { return .changedSince }
        return .text(updated)
    }

    static func literal(_ value: String, format: Format) -> String {
        format == .toml ? MCPRegistrar.tomlString(value) : (MCPRegistrar.compact(value) ?? "\"\"")
    }

    static func entryRange(_ location: Location, format: Format, in text: String) -> Range<Int>? {
        if format == .toml {
            guard let outline = TOMLOutline(text), let table = tomlTables(outline).first(where: { $0.name == location.server }) else { return nil }
            return offsets(table.range, in: text)
        }
        guard let document = JSONC(text), case .object(let root)? = document.root, let servers = object(at: location.container, in: root),
              let member = servers.member(location.server) else { return nil }
        return offsets(member.value.range, in: text)
    }

    /// The project files the import reads, by their place in a project.
    static let projectFiles = [".mcp.json", ".cursor/mcp.json", ".vscode/mcp.json", ".gemini/settings.json", ".codex/config.toml"]

    /// A file the import reads: an agent's own settings under `home`, or a project's own file by its name. Undo writes
    /// only to one of these, whatever a backup record in `imports/` says.
    public static func isConfigFile(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let known = sources(home: home, projects: []).map(\.path)
        if known.contains(path) || known.map(canonicalPath).contains(canonicalPath(path)) { return true }
        return projectFiles.contains { path.hasSuffix("/" + $0) }
    }

    /// Puts one entry back, as `apply` writes: read again, under Claude Code's lock for `~/.claude.json`.
    public static func undo(_ backup: EntryBackup, values: [String: SecretBytes], kept: [SecretBytes], home: String = NSHomeDirectory(),
                            lockWait: TimeInterval = 5, isOpen: (String) -> Bool = { _ in false },
                            read: (String) -> Data? = readFile) -> Applied {
        guard isConfigFile(backup.path, home: home) else { return .skipped("it is not an MCP config file Next Term knows") }
        let isClaudeConfig = backup.client == .claudeCode && (backup.path as NSString).lastPathComponent == ".claude.json"
        if backup.client == .claudeApp, isOpen(MCPRegistrar.claudeAppBundle) { return .skipped("quit the Claude app to put this key back") }
        if let refusal = fileRefusal(backup.path) { return .skipped(refusal) }
        var lock: ClaudeConfigLock?
        if isClaudeConfig {
            guard let taken = ClaudeConfigLock.acquire(for: backup.path, wait: lockWait) else { return .locked }
            lock = taken
        }
        defer { lock?.release() }
        guard let data = read(backup.path), let text = text(of: data) else { return .skipped("the file is not there any more") }
        switch undoPlan(backup, current: text, values: values, kept: kept) {
        case .changedSince:
            let file = (backup.path as NSString).abbreviatingWithTildeInPath
            return .skipped("The “\(backup.location.server)” entry in \(file) changed after the import, so Next Term left it. Edit it by hand.")
        case .keyMissing(let name):
            return .skipped("\(name) is no longer in Secrets, so Next Term left the “\(backup.location.server)” entry as it is.")
        case .text(let updated):
            var plan = MCPRegistrar.Plan(.registered, text: updated)
            plan.original = data
            return write(plan, to: backup.path, read: read)
        }
    }

    // MARK: Claude Code's lock

    /// Claude Code's own lock on `~/.claude.json`: the folder `~/.claude.json.lock`, made with an atomic `mkdir`.
    /// Next Term takes it the same way, tried every 100 ms, and removes only a folder it made.
    struct ClaudeConfigLock {
        let path: String

        static func acquire(for file: String, wait: TimeInterval) -> ClaudeConfigLock? {
            let lock = file + ".lock"
            let deadline = Date().addingTimeInterval(wait)
            while true {
                if mkdir(lock, 0o700) == 0 { return ClaudeConfigLock(path: lock) }
                guard errno == EEXIST, Date() < deadline else { return nil }
                usleep(100_000)
            }
        }

        func release() {
            rmdir(path)
        }
    }
}

extension SecretImport.FileEdit {
    /// A second plan writes the same entries as the first, from the same entries: only other parts of the file changed,
    /// so the backups already kept still hold.
    func written(like other: SecretImport.FileEdit) -> Bool {
        guard servers == other.servers, backups.count == other.backups.count else { return false }
        return zip(backups, other.backups).allSatisfy { $0.written == $1.written && $0.original == $1.original && $0.names == $1.names }
    }
}
