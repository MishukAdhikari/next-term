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

    /// Shared through git: a `.git` (a clone's folder, or a worktree's file) in the file's folder or one above it, on
    /// the path as given or on the one it resolves to. Reads and writes follow a link, so a config linked into a dotfiles
    /// repository is changed, and committed, there.
    public static func isInGitWorkTree(_ path: String) -> Bool {
        if hasGitAbove(path) { return true }
        let real = canonicalPath(path)
        return real != path && hasGitAbove(real)
    }

    static func hasGitAbove(_ path: String) -> Bool {
        var folder = (path as NSString).deletingLastPathComponent
        while folder.count > 1 {
            if FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(".git")) { return true }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return false
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
        /// Files that are there but could not be read, or read as their format, or list more than the import shows.
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
        guard var text = String(data: data.starts(with: mark) ? data.dropFirst(3) : data, encoding: .utf8) else { return nil }
        // Native UTF-8, so a position's offset is found at once (`offset(_:in:)`).
        text.makeContiguousUTF8()
        return text
    }

    /// The largest file the import reads.
    static let maxFileSize = 8 * 1024 * 1024
    static let tooLargeReason = "it is larger than the 8 MB Next Term reads"
    static let cantReadReason = "Next Term can't open it"

    /// Reads a plain file of at most 8 MB; nil for anything else (a link to nothing, a folder).
    public static func readFile(_ path: String) -> Data? {
        let real = canonicalPath(path)
        guard isRegularFile(real), let size = (try? FileManager.default.attributesOfItem(atPath: real))?[.size] as? Int,
              size <= maxFileSize else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    /// The most keys and wrapped servers one file lists: past it, the file is reported, not listed row by row (a crafted
    /// project file could list a hundred thousand).
    static let maxListed = 1_000
    static let tooManyReason = "it lists more than 1,000 keys or servers, more than Next Term shows"

    /// Every finding in `sources`. `inGitWorkTree` and `isOpen` (a bundle identifier's app is running) are the
    /// caller's; values stay in memory. `stop` (by default, the task is cancelled) is asked between files, between a
    /// file's servers, and every so often in a Codex file's envs, one long value or many short ones: true ends the scan
    /// with what it found in the files before. The file it stopped in is not listed, since part of it was not read.
    public static func scan(_ sources: [Source], read: (String) -> Data? = readFile, inGitWorkTree: (String) -> Bool = { _ in false },
                            isOpen: (String) -> Bool = { _ in false }, stop: () -> Bool = { Task.isCancelled }) -> Scan {
        var scan = Scan()
        for source in sources {
            if stop() { break }
            guard let data = read(source.path) else {
                // Reported, not passed over: "no keys found" would be a false all-clear.
                if let reason = unreadReason(source.path) { scan.unreadable.append((source, reason)) }
                continue
            }
            guard let text = text(of: data) else {
                scan.unreadable.append((source, "not UTF-8 text"))
                continue
            }
            let parsed: [Entry]?
            switch source.format {
            case .toml: parsed = tomlEntries(text, stop: stop)
            case .json, .strictJSON: parsed = jsonEntries(text, source: source, stop: stop)
            }
            // Stopped in this file: what was read of it is not all it holds.
            if stop() { break }
            scan.read.append(source)
            guard let entries = parsed else {
                scan.unreadable.append((source, source.format == .toml ? "not TOML Next Term can read" : "not JSON Next Term can read"))
                continue
            }
            let shared = inGitWorkTree(source.path)
            let appOpen = source.readOnceBy.map(isOpen) ?? false
            guard entries.reduce(0, { $0 + ($1.isWrapped ? 1 : $1.detected.count) }) <= maxListed else {
                scan.unreadable.append((source, tooManyReason))
                continue
            }
            for entry in entries {
                if entry.isWrapped {
                    scan.wrapped.append((source, entry.location))
                    continue
                }
                guard !entry.detected.isEmpty else { continue }
                // Where the entry is, read once for all its values: a server's name can be millions of characters long.
                let place: String = source.path + "\u{0}" + entry.location.description + "\u{0}"
                var entryHash = SHA256()
                entryHash.update(data: Data(place.utf8))
                for detected in entry.detected {
                    var reason = detected.notMovable ?? entry.notMovable
                    if reason == nil, appOpen { reason = claudeAppOpenReason }
                    let id = findingID(entryHash, field: detected.field)
                    scan.findings.append(Finding(id: id, source: source, location: entry.location,
                                                 field: detected.field, variable: detected.variable, value: detected.value, kind: detected.kind,
                                                 notMovable: reason, shared: shared, loses: entry.hasComments))
                }
            }
        }
        return scan
    }

    /// A finding's id: the digest of its file's path, its entry's place and its field, with `entryHash` holding the path
    /// and the place already (`SecretRun.digest` of the three, joined by NULs).
    static func findingID(_ entryHash: SHA256, field: Field) -> String {
        var hash = entryHash
        hash.update(data: Data("\(field)".utf8))
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Why a file the scan couldn't read is reported: a plain file over 8 MB, or one this account can't open. Nil for one
    /// that is not there, a folder or a link to nothing, which the scan passes over.
    static func unreadReason(_ path: String) -> String? {
        let real = canonicalPath(path)
        guard isRegularFile(real) else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: real))?[.size] as? Int ?? 0
        return size > maxFileSize ? tooLargeReason : cantReadReason
    }

    /// One server entry, as read: what it runs, what it holds, and where.
    struct Entry {
        var location: Location
        /// The entry's text, as UTF-8 offsets into the file.
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
        /// The value's literal in the file (with its quotes), as UTF-8 offsets.
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

    /// True in every client: Claude Code fills in `${X}` and opencode `{env:X}`, but Codex fills in neither, so it doesn't
    /// say this file's agent would have.
    static let referenceReason = "the value has a reference such as ${…} in it, which some agents fill in when they start "
        + "the server; Secrets would keep it as written"

    /// `value` with each reference inside it taken out (`${X}`, `{env:X}`, `{file:x}`, `${input:x}`, `${user_config.x}`),
    /// or nil when it holds none. The agent fills those in when it starts the server, so the rest is what the file holds.
    /// A bare `$X` inside a value is not one: passwords have `$` in them. Each byte is read once, so a crafted value of
    /// many openings and no `}` takes no longer than its length.
    static func withoutReferences(_ value: String) -> String? {
        let bytes: [UInt8] = Array(value.utf8)
        let close = UInt8(ascii: "}")
        var kept: [UInt8] = []
        var copied = 0
        var index = 0
        while index < bytes.count {
            guard let opening = referenceOpening(bytes, at: index) else {
                index += 1
                continue
            }
            let start = index + opening
            // No `}` after this opening: none after a later one either.
            guard let end = bytes[start...].firstIndex(of: close) else { break }
            guard end > start else {
                index += 1
                continue
            }
            kept.append(contentsOf: bytes[copied..<index])
            index = end + 1
            copied = index
        }
        guard copied > 0 else { return nil }
        kept.append(contentsOf: bytes[copied...])
        return String(decoding: kept, as: UTF8.self)
    }

    static let referenceOpenings: [[UInt8]] = [Array("${".utf8), Array("{env:".utf8), Array("{file:".utf8)]

    /// The length of a reference's opening at `index` (`${`, `{env:`, `{file:`), or nil.
    static func referenceOpening(_ bytes: [UInt8], at index: Int) -> Int? {
        let first = bytes[index]
        guard first == UInt8(ascii: "$") || first == UInt8(ascii: "{") else { return nil }
        for opening in referenceOpenings where bytes.count - index >= opening.count {
            if bytes[index..<(index + opening.count)].elementsEqual(opening) { return opening.count }
        }
        return nil
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
    /// value, or a value that only looks like a setting, once the references in it are taken out (`withoutReferences`).
    static func detect(name: String, value: String) -> String? {
        let whole = value.trimmingCharacters(in: .whitespaces)
        // The agent fills a reference in at start: a value is judged by the rest, which is what the file holds.
        let trimmed = withoutReferences(whole)?.trimmingCharacters(in: .whitespaces) ?? whole
        guard !trimmed.isEmpty, !isReference(trimmed), MCPRedaction.isValue(trimmed) else { return nil }
        if let kind = tokenKind(trimmed) { return kind }
        if trimmed.count >= 20, MCPRedaction.looksRandom(trimmed) { return "a key, by its shape" }
        if nameLooksSecret(name), trimmed.count >= 8 { return "a key, by its name" }
        return nil
    }

    /// Why a detected env value can't be moved: one Secrets can't keep, or a variable `nxtrm secret run` can't set.
    static func valueRefusal(variable: String, value: String) -> String? {
        if withoutReferences(value) != nil { return referenceReason }
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

    /// The UTF-8 offset of an index in `text`: found at once in native text, where counting scalars walks the text from
    /// its start, and a scan that did so for each value took time that grows with the square of the file.
    static func offset(_ index: String.Index, in text: String) -> Int {
        text.utf8.distance(from: text.utf8.startIndex, to: index)
    }

    static func offsets(_ range: Range<String.Index>, in text: String) -> Range<Int> {
        offset(range.lowerBound, in: text)..<offset(range.upperBound, in: text)
    }

    /// One servers' object of a JSON source: the keys to it, the object, and whether a key on the way to it is written
    /// twice. JSON parsers read the last of a repeated key and `member(_:)` the first, so each copy is a container of its
    /// own: a key in either is listed, and none moves.
    struct Container {
        let path: [String]
        let servers: JSONC.Object
        let repeated: Bool
    }

    /// The containers a JSON source has: its own, or for `~/.claude.json` the top-level `mcpServers` and each project's.
    /// Each project is read where the walk finds it, not looked up again from the top, so many projects take no longer
    /// than reading them.
    static func containers(of source: Source, root: JSONC.Object) -> [Container] {
        if let paths = source.containers {
            return paths.flatMap { path in objects(at: path, in: root).map { Container(path: path, servers: $0.object, repeated: $0.repeated) } }
        }
        var list = objects(at: ["mcpServers"], in: root).map { Container(path: ["mcpServers"], servers: $0.object, repeated: $0.repeated) }
        let copies = objects(at: ["projects"], in: root)
        // How often each project is there, over every copy of `projects`.
        var counts: [String: Int] = [:]
        for copy in copies { for project in copy.object.members { counts[project.key, default: 0] += 1 } }
        for copy in copies {
            for project in copy.object.members {
                guard case .object(let settings) = project.value else { continue }
                let twice = copy.repeated || counts[project.key, default: 0] > 1
                for servers in objects(at: ["mcpServers"], in: settings) {
                    list.append(Container(path: ["projects", project.key, "mcpServers"], servers: servers.object, repeated: twice || servers.repeated))
                }
            }
        }
        return list
    }

    /// Every object at `path` from `root`, each copy of a key written twice on the way, and whether one was.
    static func objects(at path: [String], in root: JSONC.Object) -> [(object: JSONC.Object, repeated: Bool)] {
        var level = [(object: root, repeated: false)]
        for key in path {
            var next: [(object: JSONC.Object, repeated: Bool)] = []
            for (object, repeated) in level {
                let copies = object.members.filter { $0.key == key }
                for copy in copies {
                    if case .object(let inner) = copy.value { next.append((inner, repeated || copies.count > 1)) }
                }
            }
            level = next
        }
        return level
    }

    /// The object at `path` from the root, when no key on the way to it is written twice: Undo and the check after a
    /// write never take a copy its agent doesn't read for the one it does.
    static func object(at path: [String], in root: JSONC.Object) -> JSONC.Object? {
        let found = objects(at: path, in: root)
        guard found.count == 1, let only = found.first, !only.repeated else { return nil }
        return only.object
    }

    static func jsonEntries(_ text: String, source: Source, stop: () -> Bool = { false }) -> [Entry]? {
        guard let document = JSONC(text) else { return nil }
        return jsonEntries(document, source: source, stop: stop)
    }

    /// The entries of a parsed file: a plan reads them from the document it edits, so the file is parsed once. `stop` is
    /// asked before each server: true ends the reading with the entries read so far (a cancelled scan drops them).
    static func jsonEntries(_ document: JSONC, source: Source, stop: () -> Bool = { false }) -> [Entry]? {
        guard case .object(let root)? = document.root else { return nil }
        let text = document.text
        let strictRefusal: String? = source.format == .strictJSON && (document.hasComments || document.hasTrailingCommas)
            ? "comments in a file that must be plain JSON" : nil
        var entries: [Entry] = []
        for container in containers(of: source, root: root) {
            // Asked for each project's servers too: `~/.claude.json` can list many projects with none.
            if stop() { return entries }
            let repeated = container.repeated || container.servers.hasRepeatedKeys
            for member in container.servers.members {
                if stop() { return entries }
                guard case .object(let object) = member.value else { continue }
                var entry = Entry(location: Location(container: container.path, server: member.key), range: offsets(member.value.range, in: text),
                                  command: [], args: [])
                let entryText = document.string(member.value.range)
                entry.hasComments = entryText.contains("//") || entryText.contains("/*")
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
        // Its server reads the last; a ticked row could be the other, and the value in use would be lost.
        if variables.hasRepeatedKeys { entry.notMovable = "repeated keys" }
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
        /// How many values `leaves` reads between two asks to stop, counted across all the values a file's reading passes
        /// it, so a small file never asks and a long run of short keys does.
        static let stopEvery = 1_024
        /// What ends a bare value (a number, a date, true), as `TOMLOutline` reads one.
        static let valueEnds: Set<Unicode.Scalar> = [",", "]", "}", "#", "\n", "\r"]

        /// A string in a value: its path below the value's key, where it is, what it says, and whether it is multi-line.
        struct Leaf {
            let path: [String]
            let range: Range<String.Index>
            let value: String
            let multiLine: Bool
            /// Where the element of the value's outermost inline table that holds it starts (the value's start when it
            /// is in none): strings with the same one are under the same first key, written once.
            let outer: String.Index
        }

        /// The strings `leaves` found in a value.
        struct Leaves {
            var found: [Leaf] = []
            /// The value is not a table of strings `want` keys down: a string or anything else at another depth, a
            /// number, true, a list, or a table that deep or deeper. As an env, one Codex refuses (it reads `env` as a
            /// map of strings). The strings `want` keys down are listed all the same.
            var offShape = false
            /// `stop` said to stop before the value's end, so `found` is not all it holds.
            var stopped = false
        }

        /// The strings in the value at `start` that are `want` keys below its key, each with those keys: the value itself
        /// when `want` is 0, or the strings of an inline table, in inline tables in it too, under their keys (dotted ones
        /// too). Strings in arrays are passed over, and so is each string at another depth, so a value with a million
        /// strings deeper than `want` keeps none of them; a negative `want` lists nothing. Followed with a list of what is
        /// still open, not by recursion (see `JSONC.parseValue`), and with one path of at most `want` keys kept in place:
        /// each element cuts it back to its table's and adds its own key. Copied whole for each element, a dotted key
        /// 250,000 keys long with 125,000 keys beside it in its value took about 3×10^10 copies.
        ///
        /// `read` counts the values read, across all the calls one file's reading makes, so a run of short keys counts
        /// as one long value does: `stop` is asked at every `stopEvery`th, and true ends the reading, `stopped`. Nil when
        /// the value can't be followed.
        func leaves(at start: String.Index, want: Int, read: inout Int, stop: () -> Bool) -> Leaves? {
            var leaves = Leaves()
            // Each array or inline table still open: what closes it, how many keys down it is, and whether it is in an
            // array.
            var open: [(close: Unicode.Scalar, depth: Int, inArray: Bool)] = []
            var i = start
            // How many keys down the value at `i` is, below the value's key; `path` holds the first of them, up to `want`.
            var depth = 0
            var path: [String] = []
            var outer = start
            while true {
                read += 1
                if read % Self.stopEvery == 0, stop() {
                    leaves.stopped = true
                    return leaves
                }
                // At a value.
                guard i < scalars.endIndex else { return nil }
                let c = scalars[i]
                let inArray = open.last.map { $0.close == "]" || $0.inArray } ?? false
                if c == "{" || c == "[" {
                    guard open.count < JSONC.maxDepth else { return nil }
                    // Only a table above the strings wanted fits the shape.
                    if c == "[" || depth >= want { leaves.offShape = true }
                    open.append((c == "{" ? "}" : "]", depth, inArray))
                    i = scalars.index(after: i)
                } else {
                    if c == "\"" || c == "'" {
                        guard let string = anyString(at: i) else { return nil }
                        if depth != want {
                            leaves.offShape = true
                        } else if !inArray {
                            let leaf = Leaf(path: path, range: string.range, value: string.value, multiLine: string.multiLine,
                                            outer: outer)
                            leaves.found.append(leaf)
                        }
                        i = string.range.upperBound
                    } else {
                        let from = i
                        while i < scalars.endIndex, !Self.valueEnds.contains(scalars[i]) { i = scalars.index(after: i) }
                        guard i > from else { return nil }
                        leaves.offShape = true
                    }
                    guard let last = open.last else { return leaves }
                    guard separator(&i, close: last.close) else { return nil }
                }
                // Past each table or array this closes, and what that closes in turn.
                while true {
                    skipSpace(&i)
                    guard i < scalars.endIndex, let last = open.last else { return nil }
                    guard scalars[i] == last.close else { break }
                    i = scalars.index(after: i)
                    open.removeLast()
                    guard let enclosing = open.last else { return leaves }
                    guard separator(&i, close: enclosing.close) else { return nil }
                }
                guard let last = open.last else { return nil }
                // Back to the path of the table or array this element is in.
                depth = last.depth
                if path.count > depth { path.removeSubrange(depth...) }
                // An element of an inline table starts with its key.
                if last.close == "}" {
                    if depth == 0 { outer = i }
                    guard let key = key(at: &i), i < scalars.endIndex, scalars[i] == "=" else { return nil }
                    i = scalars.index(after: i)
                    skipSpace(&i)
                    depth += key.count
                    path += key.prefix(max(0, want - path.count))
                }
            }
        }

        /// After an element: past a comma, or at `close`; false when something else is there.
        func separator(_ i: inout String.Index, close: Unicode.Scalar) -> Bool {
            skipSpace(&i)
            guard i < scalars.endIndex else { return false }
            guard scalars[i] == "," else { return scalars[i] == close }
            i = scalars.index(after: i)
            return true
        }

        /// A key at `i`, dotted or not: bare words and single-line quoted strings between dots. `i` ends past it.
        func key(at i: inout String.Index) -> [String]? {
            var path: [String] = []
            while true {
                skipSpace(&i)
                guard i < scalars.endIndex else { return nil }
                if scalars[i] == "\"" || scalars[i] == "'" {
                    guard let (range, value) = outline.string(at: i) else { return nil }
                    path.append(value)
                    i = range.upperBound
                } else {
                    let from = i
                    while i < scalars.endIndex, Self.bare.contains(scalars[i]) { i = scalars.index(after: i) }
                    guard i > from else { return nil }
                    path.append(String(scalars[from..<i]))
                }
                skipSpace(&i)
                guard i < scalars.endIndex, scalars[i] == "." else { return path }
                i = scalars.index(after: i)
            }
        }

        /// A string of any kind at `index`: its range, what it says, and whether it is multi-line.
        func anyString(at index: String.Index) -> (range: Range<String.Index>, value: String, multiLine: Bool)? {
            if let (range, value) = outline.string(at: index) { return (range, value, false) }
            return multiLineString(at: index).map { ($0.range, $0.value, true) }
        }

        /// Three of `quote` from `index` on.
        func isTriple(_ quote: Unicode.Scalar, at index: String.Index) -> Bool {
            scalars[index...].prefix(3).elementsEqual([quote, quote, quote])
        }

        /// A multi-line string at `index` (`"""…"""` or `'''…'''`), as TOML reads it: a line break just after the opening
        /// quotes is not part of it, a basic one's escapes are read, and a backslash at the end of one of its lines takes
        /// the line break and the blanks after it. Up to two quotes just before the closing three are its own.
        func multiLineString(at index: String.Index) -> (range: Range<String.Index>, value: String)? {
            guard index < scalars.endIndex else { return nil }
            let quote = scalars[index]
            guard quote == "\"" || quote == "'", isTriple(quote, at: index) else { return nil }
            var i = scalars.index(index, offsetBy: 3)
            let crlf: [Unicode.Scalar] = ["\r", "\n"]
            if i < scalars.endIndex, scalars[i] == "\n" {
                i = scalars.index(after: i)
            } else if scalars[i...].prefix(2).elementsEqual(crlf) {
                i = scalars.index(i, offsetBy: 2)
            }
            var value = String.UnicodeScalarView()
            while i < scalars.endIndex {
                let c = scalars[i]
                if c == quote, isTriple(quote, at: i) {
                    var end = i
                    var run = 0
                    while end < scalars.endIndex, scalars[end] == quote, run < 5 {
                        end = scalars.index(after: end)
                        run += 1
                    }
                    for _ in 3..<run { value.append(quote) }
                    return (index..<end, String(value))
                }
                i = scalars.index(after: i)
                guard quote == "\"", c == "\\" else {
                    value.append(c)
                    continue
                }
                guard i < scalars.endIndex, let unescaped = escape(at: &i) else { return nil }
                value.append(contentsOf: unescaped)
            }
            return nil
        }

        /// What the escape after a backslash at `i` in a multi-line basic string stands for, with `i` past it: at the end
        /// of a line, nothing, and the blanks and line breaks after it go too. Nil for one TOML doesn't have.
        func escape(at i: inout String.Index) -> String.UnicodeScalarView? {
            let c = scalars[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" {
                var j = i
                while j < scalars.endIndex, scalars[j] == " " || scalars[j] == "\t" { j = scalars.index(after: j) }
                guard j < scalars.endIndex, scalars[j] == "\n" || scalars[j] == "\r" else { return nil }
                while j < scalars.endIndex, scalars[j].properties.isWhitespace { j = scalars.index(after: j) }
                i = j
                return String.UnicodeScalarView()
            }
            i = scalars.index(after: i)
            let simple: [Unicode.Scalar: Unicode.Scalar] = ["n": "\n", "t": "\t", "r": "\r", "b": "\u{8}", "f": "\u{C}", "e": "\u{1B}",
                                                           "\"": "\"", "\\": "\\"]
            if let scalar = simple[c] { return String.UnicodeScalarView([scalar]) }
            guard c == "u" || c == "U" else { return nil }
            guard let end = scalars.index(i, offsetBy: c == "u" ? 4 : 8, limitedBy: scalars.endIndex),
                  let code = UInt32(String(scalars[i..<end]), radix: 16), let scalar = Unicode.Scalar(code) else { return nil }
            i = end
            return String.UnicodeScalarView([scalar])
        }
    }

    /// One `[mcp_servers.NAME]` table and what it holds.
    struct TOMLTable {
        let name: String
        let header: TOMLOutline.Header
        /// From its header to the next table that is not one of its own, short of the comments just above that.
        let range: Range<String.Index>
        /// The keys under this header, not those of another place that writes the same table.
        let keys: [TOMLOutline.Key]
        /// Keys of its `[mcp_servers.NAME.env]` tables.
        let envKeys: [TOMLOutline.Key]
        /// Its `[mcp_servers.NAME.env]` headers: two are an env written twice, and `[[…]]` is not the map Codex reads.
        let envHeaders: [TOMLOutline.Header]
        /// The file writes `[mcp_servers.NAME]` more than once, which Codex refuses.
        let isRepeated: Bool
    }

    static func tomlTables(_ outline: TOMLOutline) -> [TOMLTable] { tomlLayout(outline).tables }

    /// The header each key is under, for keys taken in the file's order: one walk over the headers for all of them.
    struct TOMLHeaderWalk {
        let headers: [TOMLOutline.Header]
        private var current = -1

        init(_ outline: TOMLOutline) { headers = outline.headers }

        /// The index in `headers` of the header `key` is under, -1 when it is above them all. Each key is past the last.
        mutating func header(of key: TOMLOutline.Key) -> Int {
            while current + 1 < headers.count, headers[current + 1].line.lowerBound < key.line.lowerBound { current += 1 }
            return current
        }
    }

    /// The servers' tables, from one walk over the headers and one over the keys, and the keys under `mcp_servers` that
    /// none of them holds: dotted keys from above, a server written as an inline table or an array of tables, an env
    /// table with no server table. Each key goes with the header it is under, and each `[mcp_servers.NAME.env]` table
    /// with the server's table above it (its first, when none is above), so a table written thousands of times holds only
    /// its own keys at each place. Read as one list of keys for the name, which each place walked, a crafted project file
    /// took time that grows with the square of its places.
    static func tomlLayout(_ outline: TOMLOutline) -> (tables: [TOMLTable], loose: [TOMLOutline.Key]) {
        let headers = outline.headers
        // Both lists are in the file's order.
        var keysUnder = [[TOMLOutline.Key]](repeating: [], count: headers.count)
        var top: [TOMLOutline.Key] = []
        var walk = TOMLHeaderWalk(outline)
        for key in outline.keys {
            let current = walk.header(of: key)
            if current >= 0 {
                keysUnder[current].append(key)
            } else if key.path.first == "mcp_servers" {
                top.append(key)
            }
        }
        var places: [String: Int] = [:]
        var last: [String: Int] = [:]
        var envTables: [Int: [Int]] = [:]
        var envFirst: [String: [Int]] = [:]
        for (index, header) in headers.enumerated() where header.path.count >= 2 && header.path[0] == "mcp_servers" {
            let name = header.path[1]
            if header.path.count == 2 {
                places[name, default: 0] += 1
                guard !header.isArray else { continue }
                if last[name] == nil { envTables[index] = envFirst.removeValue(forKey: name) }
                last[name] = index
            } else if header.path.count == 3 && header.path[2] == "env" {
                if let server = last[name] {
                    envTables[server, default: []].append(index)
                } else {
                    envFirst[name, default: []].append(index)
                }
            }
        }
        var tables: [TOMLTable] = []
        var held = [Bool](repeating: false, count: headers.count)
        for (index, header) in headers.enumerated() where !header.isArray && header.path.count == 2 && header.path[0] == "mcp_servers" {
            let name = header.path[1]
            let own = ["mcp_servers", name]
            // Only this table's own tables are passed over, so the walks over all the tables take one pass.
            let next = headers[(index + 1)...].first { !$0.path.starts(with: own) || $0.path == own }
            let end = next.map { outline.commentsAbove($0.line.lowerBound) } ?? outline.text.unicodeScalars.endIndex
            let env = envTables[index] ?? []
            held[index] = true
            for table in env { held[table] = true }
            tables.append(TOMLTable(name: name, header: header, range: header.line.lowerBound..<max(end, header.line.upperBound),
                                    keys: keysUnder[index], envKeys: env.flatMap { keysUnder[$0] }, envHeaders: env.map { headers[$0] },
                                    isRepeated: places[name, default: 0] > 1))
        }
        var loose = top
        for (index, header) in headers.enumerated() where !held[index] && header.path.first == "mcp_servers" { loose += keysUnder[index] }
        return (tables, loose)
    }

    /// Servers written another way (dotted keys, inline, env keys dotted in the server's table): listed with what to
    /// write by hand. Each key is told from its first three keys, so a long table header is not put together again for
    /// each key under it. A name is put in the set once for each place it is written: a header's name once for all
    /// the keys under that header, a key's own once for that key. Put in for each key under a header, a name 400,000
    /// characters long with 40,000 keys under it was hashed 40,000 times, 10 seconds in a debug build.
    static func tomlOddServers(_ outline: TOMLOutline) -> Set<String> {
        var names = Set<String>()
        var walk = TOMLHeaderWalk(outline)
        // The header whose name is in the set already.
        var named = -1
        for key in outline.keys {
            let header = walk.header(of: key)
            var full = Array(key.table.prefix(3))
            full += key.path.prefix(3 - full.count)
            guard full.count >= 2, full[0] == "mcp_servers" else { continue }
            // In the server's table and not a dotted env key, or in its env table: told by the table's length, so no name
            // is read again.
            let dottedEnv = key.path.count > 1 && key.path[0] == "env"
            let tableShape = key.table.count == 2 && !dottedEnv || key.table.count == 3 && key.table[2] == "env"
            guard !tableShape else { continue }
            if key.table.count >= 2 {
                guard header != named else { continue }
                named = header
            }
            names.insert(full[1])
        }
        return names
    }

    static func tomlEntries(_ text: String, stop: () -> Bool = { false }) -> [Entry]? {
        guard let outline = TOMLOutline(text) else { return nil }
        return tomlEntries(outline, stop: stop)
    }

    /// The entries of a read outline: a plan reads them from the outline it edits, so the file is read once. `stop` is
    /// asked before each server, and once every `TOMLReader.stopEvery` values read in the envs and variables checked,
    /// counted across all of them: true ends the reading with the entries read so far (a cancelled scan drops them).
    /// Nil when a value that could hold a server's env can't be followed.
    static func tomlEntries(_ outline: TOMLOutline, stop: () -> Bool = { false }) -> [Entry]? {
        let text = outline.text
        let reader = TOMLReader(outline)
        var entries: [Entry] = []
        let odd = tomlOddServers(outline)
        let layout = tomlLayout(outline)
        // The values read in the envs and the variables checked so far, for `stop`.
        var read = 0
        for table in layout.tables {
            if stop() { return entries }
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
            // Its env, wherever this place writes it: inline, with dotted keys, or in its env tables.
            let inline = table.keys.filter { $0.path == ["env"] }
            let dotted = table.keys.filter { $0.path.count > 1 && $0.path[0] == "env" }
            if let env = inline.first, reader.members(at: env.value) == nil { entry.notMovable = entry.notMovable ?? envShapeReason }
            if table.envHeaders.contains(where: \.isArray) { entry.notMovable = envShapeReason }
            if odd.contains(table.name) { entry.notMovable = oddShapeReason(table.name) }
            guard let env = envValues(inline + dotted + table.envKeys, reader: reader, read: &read, stop: stop) else { return nil }
            if env.stopped { return entries }
            // Something in it other than strings four keys down: an env Codex refuses.
            if env.offShape { entry.notMovable = entry.notMovable ?? envShapeReason }
            let variables = env.variables
            let names = variables.map(\.variable)
            // A variable named twice, or the env written twice (inline, dotted or as a table, or a table twice): Codex
            // refuses the file, or which one it reads is unsure.
            let written = inline.count + (dotted.isEmpty ? 0 : 1) + table.envHeaders.count
            if Set(names).count < names.count || written > 1 { entry.notMovable = "repeated keys" }
            // The table written twice, as a repeated key in JSON: Codex refuses the file, and which place is the server
            // can't be told.
            if table.isRepeated { entry.notMovable = "repeated keys" }
            guard let detected = envFindings(variables, text: text, refusal: nil, read: &read, stop: stop) else { return entries }
            entry.detected += detected
            entries.append(entry)
        }
        // Keys no server table holds, sorted by server in one pass: what they write in a server's env is listed, not
        // movable, with the server's first table, or as a server of its own when it has none. The keys are in the file's
        // order, and their variables go to their server in runs, one for each place a server's name is written (a
        // header, a key, or an element of `mcp_servers = {…}`), so a long name is hashed once for each place it is
        // written, not once for each variable under it: 40,000 variables under a name 400,000 characters long took 10
        // seconds in a debug build.
        typealias Variables = [(variable: String, leaf: TOMLReader.Leaf)]
        var loose: [String: Variables] = [:]
        var run: (place: String.Index, server: String, variables: Variables)?
        var walk = TOMLHeaderWalk(outline)
        for key in layout.loose {
            // Only a key that is a server, its env or one of its variables can hold one (`mcp_servers = {…}` too).
            // Told by its length first, so a long table header is not put together again for each key under it.
            guard key.table.count + key.path.count <= 4 else { continue }
            let full = key.table + key.path
            guard full.count <= 2 || full[2] == "env" else { continue }
            // An env in a shape Codex refuses changes nothing here: these servers don't move anyway.
            guard let env = envValues([key], reader: reader, read: &read, stop: stop) else { return nil }
            if env.stopped { return entries }
            guard !env.variables.isEmpty else { continue }
            // Where the server's name is written, when the key or its header writes it.
            let header = walk.header(of: key)
            var written: String.Index?
            if key.table.count >= 2 {
                written = walk.headers[header].line.lowerBound
            } else if full.count >= 2 {
                written = key.line.lowerBound
            }
            for variable in env.variables {
                let place = written ?? variable.leaf.outer
                if place != run?.place {
                    if let done = run { loose[done.server, default: []] += done.variables }
                    run = (place, variable.server, [])
                }
                run?.variables.append((variable.variable, variable.leaf))
            }
        }
        if let done = run { loose[done.server, default: []] += done.variables }
        var first: [String: Int] = [:]
        for (index, entry) in entries.enumerated() where first[entry.location.server] == nil { first[entry.location.server] = index }
        for (name, variables) in loose {
            guard let index = first[name] else { continue }
            let refusal = oddShapeReason(name)
            entries[index].notMovable = entries[index].notMovable ?? refusal
            let named = variables.map { (name, $0.variable, $0.leaf) }
            guard let detected = envFindings(named, text: text, refusal: refusal, read: &read, stop: stop) else { return entries }
            entries[index].detected += detected
        }
        for name in odd.union(loose.keys).subtracting(first.keys).sorted() {
            if stop() { return entries }
            var entry = Entry(location: Location(container: ["mcp_servers"], server: name), range: 0..<0, command: [], args: [])
            entry.notMovable = oddShapeReason(name)
            let named = (loose[name] ?? []).map { (name, $0.variable, $0.leaf) }
            guard let detected = envFindings(named, text: text, refusal: entry.notMovable, read: &read, stop: stop) else { return entries }
            entry.detected = detected
            entries.append(entry)
        }
        return entries
    }

    static let envShapeReason = "its env is written in a shape Next Term can't edit"

    /// The env variables some keys write, as `envValues` read them.
    struct EnvValues {
        var variables: [(server: String, variable: String, leaf: TOMLReader.Leaf)] = []
        /// Something in them is not a string four keys down: a key below a variable, a table, a number, true or a list.
        /// Codex reads `env` as a map of strings, and refuses the file with anything else in it.
        var offShape = false
        /// `stop` said to stop in a value, so `variables` is not all the keys write.
        var stopped = false
    }

    /// The env variables `keys` write, as Codex reads them: each string at `mcp_servers.SERVER.env.NAME`, however the key
    /// and its value spell that path. Only the strings four keys down are kept, and a key's own path is put together
    /// only when it has some, so a long dotted key is not copied for each string in its value. `read` and `stop` go to
    /// `TOMLReader.leaves`. Nil when a value can't be followed.
    static func envValues(_ keys: [TOMLOutline.Key], reader: TOMLReader, read: inout Int, stop: () -> Bool) -> EnvValues? {
        var values = EnvValues()
        for key in keys {
            let above = key.table.count + key.path.count
            guard let leaves = reader.leaves(at: key.value, want: 4 - above, read: &read, stop: stop) else { return nil }
            values.offShape = values.offShape || leaves.offShape
            if leaves.stopped {
                values.stopped = true
                return values
            }
            guard !leaves.found.isEmpty else { continue }
            // Four keys in all: the key's and its table's, then those below it in its value.
            let prefix = key.table + key.path
            for leaf in leaves.found {
                let path = prefix + leaf.path
                guard path[0] == "mcp_servers", path[2] == "env" else { continue }
                values.variables.append((path[1], path[3], leaf))
            }
        }
        return values
    }

    /// The keys among env `variables`: each refused for its value, for being multi-line (which an edit doesn't read
    /// yet), or for `refusal`. Each variable checked counts in `read` as a value read does, and `stop` is asked at every
    /// `TOMLReader.stopEvery`th: true ends the checking, nil. Checked with no ask, a million variables took 9 seconds
    /// in a debug build after the last ask in their values.
    static func envFindings(_ variables: [(server: String, variable: String, leaf: TOMLReader.Leaf)], text: String,
                            refusal: String?, read: inout Int, stop: () -> Bool) -> [Detected]? {
        var found: [Detected] = []
        for (_, variable, leaf) in variables {
            read += 1
            if read % TOMLReader.stopEvery == 0, stop() { return nil }
            guard let kind = detect(name: variable, value: leaf.value) else { continue }
            let reason = refusal ?? valueRefusal(variable: variable, value: leaf.value) ?? (leaf.multiLine ? envShapeReason : nil)
            found.append(Detected(field: .env(variable), variable: variable, value: SecretBytes(utf8: leaf.value), kind: kind, notMovable: reason,
                                  range: offsets(leaf.range, in: text)))
        }
        return found
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
        /// `name` is a stored key that holds this value already: the move uses it and stores no second copy.
        public var reusesStored = false
        public var kind: String { findings.first?.kind ?? "key" }
        /// "Same value in 3 servers" when it is in more than one.
        public var summary: String? {
            let servers = Set(findings.map { $0.source.path + "\u{0}" + $0.location.description })
            return servers.count > 1 ? "Same value in \(servers.count) servers" : nil
        }
    }

    /// The keys an earlier move stored whose marks show they hold `value` (no value is read), in the vault's order:
    /// what a group of that value may use instead of a second copy. Only a move's keys (origin `import`): one added in
    /// Settings or by an agent is the user's own. Never a write-only one: an Undo of the move that used it couldn't put
    /// it back. The value's mark is worked out once.
    public static func reusable(holding value: SecretBytes, in index: SecretVault.Index?, mask: SecretMask) -> [String] {
        guard let index, let mark = mask.mark(of: value) else { return [] }
        let held = index.entries.filter { $0.origin == .import && !$0.writeOnly && $0.marks.contains(mark) }
        return held.map(\.name)
    }

    /// The movable findings grouped by identical value, each group named after its first variable (capitals, `_`); a
    /// clash with a stored key or another group adds `_2`, `_3`. A group holds at most one variable of each entry.
    /// `holding` names the stored keys that hold a value already (`reusable`): each group of that value takes one of
    /// them (`reusesStored`), the one named as its variable first, and no two groups take the same one. So an import
    /// tried again after its file was left as it was uses the keys the first try stored, one per variable, instead of
    /// second copies under `_2`.
    public static func groups(_ findings: [Finding], stored: [String],
                              holding: (SecretBytes) -> [String] = { _ in [] }) -> [Group] {
        struct Place: Hashable {
            let path: String
            let location: Location
        }
        var groups: [(value: SecretBytes, findings: [Finding], places: Set<Place>)] = []
        // The groups by their value's digest (in memory only): a finding finds its group at once, not by a walk over all.
        var byValue: [SHA256.Digest: [Int]] = [:]
        for finding in findings where finding.movable {
            let place = Place(path: finding.source.path, location: finding.location)
            let digest = finding.value.withUnsafeBytes { SHA256.hash(data: $0) }
            // An entry that holds the value under two variables needs a key for each: the wrapper takes a name once.
            let same = byValue[digest]?.first { groups[$0].value == finding.value && !groups[$0].places.contains(place) }
            if let index = same {
                groups[index].findings.append(finding)
                groups[index].places.insert(place)
            } else {
                byValue[digest, default: []].append(groups.count)
                groups.append((finding.value, [finding], [place]))
            }
        }
        var taken = Set(stored)
        let reusing = storedKeys(for: groups.map { ($0.value, $0.findings[0].variable) }, taken: taken, holding: holding)
        // Where each name's numbers go on from: names are only ever taken, so the ones below are taken still.
        var numbers: [String: Int] = [:]
        return groups.enumerated().map { position, group in
            if let name = reusing[position] {
                var reused = Group(id: group.findings[0].id, name: name, value: group.value, findings: group.findings)
                reused.reusesStored = true
                return reused
            }
            let base = StoredSecretName.suggested(from: group.findings[0].variable)
            var name = base
            var number = numbers[base] ?? 2
            while taken.contains(name) {
                let suffix = "_\(number)"
                name = String(base.prefix(StoredSecretName.maxLength - suffix.count)) + suffix
                number += 1
            }
            numbers[base] = number
            taken.insert(name)
            return Group(id: group.findings[0].id, name: name, value: group.value, findings: group.findings)
        }
    }

    /// The stored key each group uses, by its position, when one holds its value: first the groups whose variable's
    /// name is one of those keys take it, then the others take the next one left. Each key goes to one group at most,
    /// and only a key that is stored (`taken`).
    static func storedKeys(for groups: [(value: SecretBytes, variable: String)], taken: Set<String>,
                           holding: (SecretBytes) -> [String]) -> [Int: String] {
        let candidates: [[String]] = groups.map { group in holding(group.value).filter { taken.contains($0) } }
        var chosen: [Int: String] = [:]
        var used = Set<String>()
        for (position, group) in groups.enumerated() {
            let own = StoredSecretName.suggested(from: group.variable)
            guard candidates[position].contains(own), !used.contains(own) else { continue }
            chosen[position] = own
            used.insert(own)
        }
        for position in groups.indices where chosen[position] == nil {
            guard let next = candidates[position].first(where: { !used.contains($0) }) else { continue }
            chosen[position] = next
            used.insert(next)
        }
        return chosen
    }

    // MARK: the wrapper's command

    /// A path an agent's config can keep: absolute, and not in a disk image (`/Volumes/`) or in a copy macOS moved
    /// aside to run it (App Translocation), which are gone after an eject or a relaunch.
    public static func lasts(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.hasPrefix("/Volumes/") && !path.contains("/AppTranslocation/")
    }

    /// The command a wrapped entry starts, from the first place that still works after a relaunch: a link on PATH
    /// (`links`, the installed one first) into an app that is there and lasts, then the running app's own `nxtrm`
    /// script, then its binary with `--cli`, these two only when the app itself lasts (`appLasts`: not translocated,
    /// not on a disk image or a read-only volume). Nil when none does: the import refuses, as MCP registration does.
    public static func wrapperCommand(links: [(path: String, target: String)], script: String?, executable: String?, appLasts: Bool,
                                      exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String]? {
        for link in links where lasts(link.path) && lasts(link.target) && exists(link.target) { return [link.path] }
        guard appLasts else { return nil }
        if let script, lasts(script) { return [script] }
        if let executable, lasts(executable) { return [executable, "--cli"] }
        return nil
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
        /// Of `names`, the keys the move stored itself; the others it used, stored by an earlier move. Nil in a backup
        /// written before this was recorded, when every move stored all its keys.
        public var stored: [String]?

        /// The keys the move stored itself: what an Undo of it may delete.
        public var storedNames: [String] { stored ?? names }

        enum CodingKeys: String, CodingKey {
            case id, batch, date, path, client, format, location, names, original, written, keptCount = "kept_count", keptBox = "kept_box"
            case stored
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
        /// The names `nxtrm secret run` takes out when it starts a server: the vault's and this import's.
        let taken: Set<String>
        /// Each entry's variables taken out with the moved keys, because the wrapper would take them out at start, in
        /// the file's order of entries. Undo puts them back with the rest of the entry.
        public let dropped: [(server: String, variables: [String])]

        public var path: String { source.path }
        /// The keys it moves.
        public var names: [String] { Array(Set(moves.map(\.name))).sorted() }

        /// Sets one backup's sealed kept values: the app seals them during the import's Touch ID.
        public mutating func seal(_ id: String, box: Data?) {
            guard let index = backups.firstIndex(where: { $0.id == id }) else { return }
            backups[index].keptBox = box
        }

        /// Records in each backup which of its keys the import stored (`stored`), the others being keys it used.
        public mutating func setStored(_ stored: Set<String>) {
            for index in backups.indices { backups[index].stored = backups[index].names.filter(stored.contains) }
        }
    }

    /// The sheet's line for the variables the written entries dropped (`FileEdit.dropped`): which left which server, a
    /// server's name cut at 60 characters. Nil when none did.
    public static func droppedText(_ dropped: [(server: String, variables: [String])]) -> String? {
        guard !dropped.isEmpty else { return nil }
        var places: [String] = []
        var count = 0
        for entry in dropped where !entry.variables.isEmpty {
            let names: [String] = entry.variables
            let head: String = names.dropLast().joined(separator: ", ")
            let listed: String = names.count <= 2 ? SecretRun.keysText(names) : head + " and " + names[names.count - 1]
            let long: Bool = entry.server.prefix(61).count > 60
            let server: String = long ? String(entry.server.prefix(60)) + "…" : entry.server
            places.append("\(listed) from “\(server)”")
            count += names.count
        }
        guard !places.isEmpty else { return nil }
        let opening = "Also taken out, because nxtrm secret run removes the name of every key in Secrets that a server doesn’t ask for: "
        let undo: String = count == 1 ? "Undo puts it back." : "Undo puts them back."
        return opening + places.joined(separator: "; ") + ". " + undo
    }

    /// Before the plan, for the confirm: the values the scan found (`findings`) that a wrapped entry would drop although no
    /// move takes them (rows not ticked), in the scan's order. Each is in an entry a move wraps, under a variable that
    /// entry doesn't ask for, named like a key the wrapper takes out at start: the vault's (`stored`) or a move's. After the
    /// write, such a value is only in the entry's backup. A file that then fails to plan keeps what it holds.
    public static func droppedFindings(_ moves: [Move], among findings: [Finding], stored: [String]) -> [Finding] {
        func entry(_ finding: Finding) -> String { finding.source.path + "\u{0}" + finding.location.description }
        var asked: [String: Set<String>] = [:]
        var moved: Set<String> = []
        for move in moves {
            for finding in move.findings where finding.movable {
                asked[entry(finding), default: []].insert(finding.variable)
                moved.insert(finding.id)
            }
        }
        let movedNames: [String] = moves.filter { $0.findings.contains(where: \.movable) }.map(\.name)
        let taken: Set<String> = Set(stored).union(movedNames)
        return findings.filter { finding in
            guard case .env(let name) = finding.field, !moved.contains(finding.id), let wanted = asked[entry(finding)] else { return false }
            return taken.contains(name) && !wanted.contains(name)
        }
    }

    /// The confirm's paragraph for `droppedFindings` (a variable and its server's name, cut at 60 characters): where each
    /// is, that its server would never get it, that its value is then only in the backup, and how to keep it. Three are
    /// named, the rest counted. Nil when there are none.
    public static func droppedWarning(_ dropped: [(variable: String, server: String)]) -> String? {
        guard !dropped.isEmpty else { return nil }
        let places: [String] = dropped.prefix(3).map { item in
            let long: Bool = item.server.prefix(61).count > 60
            let server: String = long ? String(item.server.prefix(60)) + "…" : item.server
            return "\(item.variable) in “\(server)”"
        }
        let more: Int = dropped.count - places.count
        let listed: String
        if more > 0 {
            listed = places.joined(separator: ", ") + " and \(more) more"
        } else if places.count == 1 {
            listed = places[0]
        } else {
            listed = places.dropLast().joined(separator: ", ") + " and " + places[places.count - 1]
        }
        let days = Int(keptFor / (24 * 3600))
        let one: Bool = dropped.count == 1
        let reach: String = one ? "so the server would never get it, and after this its value is only in the backup"
            : "so the servers would never get them, and after this their values are only in the backups"
        let keep: String = one ? "To keep it in Secrets, tick its row too." : "To keep them in Secrets, tick their rows too."
        return "Not ticked, but taken out too: \(listed). nxtrm secret run removes the name of every key in Secrets that a server "
            + "doesn’t ask for, \(reach) Next Term keeps for \(days) days. \(keep)"
    }

    /// What an Undo's "Also delete these keys" deletes: only keys the undone moves stored themselves, and none that
    /// entries it doesn't put back still name (another import's in the list, or one of its own left wrapped). A key a
    /// move used because an earlier move had stored it stays, since other entries may use it, even once that earlier
    /// move's backup is gone.
    public struct UndoKeys: Equatable, Sendable {
        /// The keys it may delete, once their entries all went back.
        public let deletable: Set<String>
        /// Kept: stored before the undone moves, which used them.
        public let storedBefore: [String]
        /// Kept: entries this Undo doesn't put back name them.
        public let usedElsewhere: [String]

        public init(undoing backups: [EntryBackup], others: [EntryBackup]) {
            let names = Set(backups.flatMap(\.names))
            let stored = Set(backups.flatMap(\.storedNames)).intersection(names)
            let elsewhere = Set(others.flatMap(\.names))
            deletable = stored.subtracting(elsewhere)
            storedBefore = names.subtracting(stored).sorted()
            usedElsewhere = stored.intersection(elsewhere).sorted()
        }

        /// What Undo says about the keys of `back` (whose entries all went back) it kept although asked to delete them;
        /// nil when it kept none.
        public func keptText(_ back: Set<String>) -> String? {
            let before = storedBefore.filter(back.contains)
            let elsewhere = usedElsewhere.filter(back.contains)
            var lines: [String] = []
            if !before.isEmpty {
                let one = before.count == 1
                lines.append("\(SecretRun.keysText(before)) \(one ? "stays" : "stay") in Secrets: \(one ? "it was" : "they were") "
                    + "there before this import, and other entries may use \(one ? "it" : "them").")
            }
            if !elsewhere.isEmpty {
                let one = elsewhere.count == 1
                lines.append("\(SecretRun.keysText(elsewhere)) \(one ? "stays" : "stay") in Secrets: entries this Undo doesn’t "
                    + "put back still use \(one ? "it" : "them").")
            }
            return lines.isEmpty ? nil : lines.joined(separator: " ")
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
    /// binary and `--cli`. `stored` is the vault's names: with the names this import stores (the moves of the files that
    /// plan), what the wrapper takes out of a server's environment unless the entry asks for it, so a wrapped entry drops
    /// a variable of that name too. `isOpen` is asked now, not taken from the scan: a file an app saves whole (the
    /// Claude app's) is left while that app runs, and its moves store no key.
    public static func plan(_ moves: [Move], nxtrm: [String], stored: [String] = [], isOpen: (String) -> Bool = { _ in false },
                            read: (String) -> Data? = readFile, now: Date = Date()) -> (edits: [FileEdit], failures: [PlanFailure]) {
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
        // Each file read once: a second pass plans from the same bytes.
        var left: [PlanFailure] = []
        var files: [(source: Source, moves: [Move], data: Data)] = []
        for path in order {
            guard let (source, fileMoves) = byFile[path] else { continue }
            if let app = source.readOnceBy, isOpen(app) {
                left.append(PlanFailure(path: path, reason: claudeAppOpenReason))
                continue
            }
            guard let data = read(path) else {
                left.append(PlanFailure(path: path, reason: "it can't be read"))
                continue
            }
            files.append((source, fileMoves, data))
        }
        let batch = String(UUID().uuidString.lowercased().prefix(12))
        let movedNames: [String] = moves.filter { $0.findings.contains(where: \.movable) }.map(\.name)
        var taken: Set<String> = Set(stored).union(movedNames)
        var planned = planFiles(files, nxtrm: nxtrm, now: now, batch: batch, taken: taken)
        // The import stores only the keys of the files that planned (the sheet's `move`): a move whose every file failed
        // stores nothing, and the wrapper takes out no variable of its name. Planned again without it, until none is
        // left; the names only ever shrink, so it stops.
        for _ in moves.indices {
            let plannedNames: [String] = planned.edits.flatMap(\.names)
            let kept: Set<String> = taken.intersection(Set(stored).union(plannedNames))
            if kept == taken { break }
            taken = kept
            planned = planFiles(files, nxtrm: nxtrm, now: now, batch: batch, taken: taken)
        }
        // The failures in the files' order, as one pass gave them.
        let place: [String: Int] = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let failures: [PlanFailure] = (left + planned.failures).sorted { (place[$0.path] ?? 0) < (place[$1.path] ?? 0) }
        return (planned.edits, failures)
    }

    /// `plan`'s pass over the files it read, in order.
    static func planFiles(_ files: [(source: Source, moves: [Move], data: Data)], nxtrm: [String], now: Date, batch: String,
                          taken: Set<String>) -> (edits: [FileEdit], failures: [PlanFailure]) {
        var edits: [FileEdit] = []
        var failures: [PlanFailure] = []
        for file in files {
            let result = planFile(file.source, moves: file.moves, nxtrm: nxtrm, data: file.data, now: now, batch: batch, taken: taken)
            switch result {
            case .success(let edit): edits.append(edit)
            case .failure(let failure): failures.append(failure)
            }
        }
        return (edits, failures)
    }

    /// A file's edit from its bytes: every entry it changes planned from one reading of the file, each with its backup.
    /// Planned entry by entry, each read the whole file again, and a file with many keys took minutes.
    static func planFile(_ source: Source, moves: [Move], nxtrm: [String], data: Data, now: Date,
                         batch: String, taken: Set<String> = []) -> Result<FileEdit, PlanFailure> {
        guard let text = text(of: data) else { return .failure(PlanFailure(path: source.path, reason: "not UTF-8 text")) }
        // The moves by entry, in the order they come, and the values the scan found there: what Secrets stores.
        var byEntry: [Location: [(name: String, variable: String)]] = [:]
        var values: [Location: [String: SecretBytes]] = [:]
        var locations: [Location] = []
        for move in moves {
            for finding in move.findings {
                guard case .env(let variable) = finding.field else { continue }
                if byEntry[finding.location] == nil { locations.append(finding.location) }
                byEntry[finding.location, default: []].append((move.name, variable))
                values[finding.location, default: [:]][variable] = finding.value
            }
        }
        let entries = locations.map { EntryMove(location: $0, pairs: byEntry[$0] ?? [], expected: values[$0] ?? [:]) }
        let result = source.format == .toml
            ? editTOML(text, entries: entries, nxtrm: nxtrm, taken: taken)
            : editJSON(text, source: source, entries: entries, nxtrm: nxtrm, taken: taken)
        let edited: Edited
        switch result {
        case .failure(let failure): return .failure(PlanFailure(path: source.path, reason: failure.reason))
        case .success(let made): edited = made
        }
        var backups: [EntryBackup] = []
        for (entry, made) in zip(entries, edited.entries) {
            let id = UUID().uuidString.lowercased().prefix(12)
            backups.append(EntryBackup(id: String(id), batch: batch, date: now, path: source.path, client: source.client, format: source.format,
                                       location: entry.location, names: entry.pairs.map(\.name), original: made.original,
                                       written: made.written, keptCount: made.kept.count, keptBox: nil, keptValues: made.kept))
        }
        var plan = MCPRegistrar.Plan(.registered, text: edited.text)
        plan.original = data
        var dropped: [(server: String, variables: [String])] = []
        for (entry, made) in zip(entries, edited.entries) where !made.dropped.isEmpty {
            dropped.append((entry.location.server, made.dropped))
        }
        let servers: [String] = locations.map(\.server)
        return .success(FileEdit(source: source, servers: servers, backups: backups, moves: moves, nxtrm: nxtrm, plan: plan, taken: taken,
                                 dropped: dropped))
    }

    /// Why an entry's edit can't be made.
    struct EditFailure: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// One entry to change: its keys (each name in Secrets and the variable it leaves), and the values the scan found
    /// there, which Secrets stores.
    struct EntryMove {
        let location: Location
        let pairs: [(name: String, variable: String)]
        let expected: [String: SecretBytes]
    }

    /// What one entry's edit made: its backup text, the digest of what Next Term wrote, the values kept, and the
    /// variables it dropped because the wrapper would take them out (sorted).
    struct EditedEntry {
        var original: String
        var written: String
        var kept: [SecretBytes]
        var dropped: [String] = []
    }

    /// What a file's edit made: its new text, and each entry's, in order.
    struct Edited {
        var text: String
        var entries: [EditedEntry]
    }

    /// The first of each location in `entries`, as `first(where:)` finds it, for the locations wanted.
    static func firstByLocation(_ entries: [Entry], wanted: Set<Location>) -> [Location: Entry] {
        var found: [Location: Entry] = [:]
        for entry in entries where wanted.contains(entry.location) && found[entry.location] == nil { found[entry.location] = entry }
        return found
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
    /// `bytes` is the file's UTF-8, taken once for all its entries.
    static func marked(_ bytes: [UInt8], entry: Entry, moved: [String: String]) -> (text: String, kept: [SecretBytes]) {
        let detected = entry.detected.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var out: [UInt8] = []
        var cursor = entry.range.lowerBound
        var kept: [SecretBytes] = []
        for found in detected where found.range.lowerBound >= cursor && found.range.upperBound <= entry.range.upperBound {
            out.append(contentsOf: bytes[cursor..<found.range.lowerBound])
            let name: String?
            if case .env(let variable) = found.field { name = moved[variable] } else { name = nil }
            let marker: String
            if let name {
                marker = markerText(name)
            } else {
                marker = keptMarker(kept.count)
                kept.append(found.value)
            }
            out.append(contentsOf: "\"\(marker)\"".utf8)
            cursor = found.range.upperBound
        }
        out.append(contentsOf: bytes[cursor..<entry.range.upperBound])
        return (String(decoding: out, as: UTF8.self), kept)
    }

    static func sha256(_ text: String) -> String { SecretRun.digest(Data(text.utf8)) }

    /// Replaces UTF-8 ranges of `text` (each from `offsets`, so on scalar boundaries). An insertion (an empty range) goes
    /// before a change that starts where it does, so a line added after `args` comes before the `env` line removed there.
    /// Ranges that overlap, or run past the end, give nil: the edit is refused rather than guessed.
    static func replacing(_ text: String, _ changes: [(range: Range<Int>, with: String)]) -> String? {
        let bytes = Array(text.utf8)
        let ordered = changes.indices.sorted { first, second in
            let a = changes[first].range
            let b = changes[second].range
            if a.lowerBound != b.lowerBound { return a.lowerBound < b.lowerBound }
            if a.isEmpty != b.isEmpty { return a.isEmpty }
            return first < second
        }
        var out: [UInt8] = []
        var cursor = 0
        for index in ordered {
            let change = changes[index]
            guard change.range.lowerBound >= cursor, change.range.upperBound <= bytes.count else { return nil }
            out.append(contentsOf: bytes[cursor..<change.range.lowerBound])
            out.append(contentsOf: change.with.utf8)
            cursor = change.range.upperBound
        }
        out.append(contentsOf: bytes[cursor...])
        return String(decoding: out, as: UTF8.self)
    }

    /// Why `nxtrm secret run` could not start the entry as planned: its keys and their variables, then the command, as
    /// the wrapper parses them. Nil when they parse.
    static func wrapperRefusal(_ pairs: [(name: String, variable: String)], command: [String]) -> String? {
        guard case .failure(let error) = SecretRun.parse(keyArguments(pairs) + ["--"] + command) else { return nil }
        return "nxtrm secret run couldn't start it that way: \(error.reason); give each key its own name, or edit it by hand"
    }

    /// Why an entry is left: the value in the file is not the one the scan found, which Secrets would store.
    static func changedReason(_ variable: String) -> String { "\(variable) changed since the scan; open the import again" }

    /// Why an entry can't lose `variable` now: it is not there, or its value is not `expected`, the one the scan found
    /// and Secrets stores (taken out, a newer key would be in neither place). Nil when it is that value.
    static func changeRefusal(_ entry: Entry, variable: String, expected: SecretBytes?) -> String? {
        guard let detected = entry.detected.first(where: { $0.field == .env(variable) }), let expected, detected.value == expected else {
            return changedReason(variable)
        }
        return nil
    }

    /// The JSON entries' edits, made on one parse of the file and checked on one parse of the result. `taken`: the names
    /// the wrapper takes out at start, which leave each entry too unless it asks for them.
    static func editJSON(_ text: String, source: Source, entries moves: [EntryMove], nxtrm: [String],
                         taken: Set<String> = []) -> Result<Edited, EditFailure> {
        guard let document = JSONC(text), case .object(let root)? = document.root, let entries = jsonEntries(document, source: source) else {
            return .failure(EditFailure("the entry is not there any more"))
        }
        let wanted = Set(moves.map(\.location))
        let found = firstByLocation(entries, wanted: wanted)
        let members = jsonMembers(of: source, root: root, wanted: wanted)
        let bytes = Array(text.utf8)
        let envKey = source.client == .opencode ? "environment" : "env"
        var changes: [(range: Range<Int>, with: String)] = []
        var planned: [Location: [String: Any]] = [:]
        var made: [EditedEntry] = []
        for move in moves {
            guard let entry = found[move.location] else { return .failure(EditFailure("the entry is not there any more")) }
            if let reason = entry.notMovable { return .failure(EditFailure(reason)) }
            if let reason = wrapperRefusal(move.pairs, command: entry.command + entry.args) { return .failure(EditFailure(reason)) }
            guard let member = members[move.location], var object = member.value.object(in: text) as? [String: Any] else {
                return .failure(EditFailure("the entry can't be read"))
            }
            var env = object[envKey] as? [String: Any] ?? [:]
            for pair in move.pairs {
                guard env[pair.variable] is String else { return .failure(EditFailure("\(pair.variable) is not in the entry any more")) }
                if let reason = changeRefusal(entry, variable: pair.variable, expected: move.expected[pair.variable]) {
                    return .failure(EditFailure(reason))
                }
                env[pair.variable] = nil
            }
            // A stored key's name the entry doesn't ask for: the wrapper takes it out at start, so it leaves the file too.
            let dropped: [String] = env.keys.filter { taken.contains($0) }.sorted()
            for name in dropped { env[name] = nil }
            if env.isEmpty {
                object.removeValue(forKey: envKey)
            } else {
                object[envKey] = env
            }
            let args = wrapped(move.pairs, nxtrm: nxtrm, command: entry.command + entry.args)
            if source.client == .opencode {
                object["command"] = [nxtrm[0]] + args
            } else {
                object["command"] = nxtrm[0]
                object["args"] = args
            }
            guard let newEntry = MCPRegistrar.compact(object) else { return .failure(EditFailure("the new entry can't be written")) }
            let moved = Dictionary(move.pairs.map { ($0.variable, $0.name) }, uniquingKeysWith: { first, _ in first })
            let backup = marked(bytes, entry: entry, moved: moved)
            changes.append((entry.range, newEntry))
            planned[move.location] = object
            made.append(EditedEntry(original: backup.text, written: sha256(newEntry), kept: backup.kept, dropped: dropped))
        }
        guard let updated = replacing(text, changes), verifyJSON(updated, before: document, source: source, planned: planned) else {
            return .failure(EditFailure("check failed"))
        }
        return .success(Edited(text: updated, entries: made))
    }

    /// The member of each wanted location, the first of its name in its container, as `object(at:)` and `member(_:)` find
    /// it, in one walk over the containers.
    static func jsonMembers(of source: Source, root: JSONC.Object, wanted: Set<Location>) -> [Location: JSONC.Member] {
        let paths = Set(wanted.map(\.container))
        var members: [Location: JSONC.Member] = [:]
        for container in containers(of: source, root: root) where paths.contains(container.path) {
            for member in container.servers.members {
                let location = Location(container: container.path, server: member.key)
                if wanted.contains(location), members[location] == nil { members[location] = member }
            }
        }
        return members
    }

    /// The edit parses, each entry is what was planned, and every other server in their containers is as it was; a
    /// strict file parses plainly.
    static func verifyJSON(_ text: String, before old: JSONC, source: Source, planned: [Location: [String: Any]]) -> Bool {
        guard let document = JSONC(text), case .object(let root)? = document.root, case .object(let oldRoot)? = old.root else { return false }
        let paths = Set(planned.keys.map(\.container))
        func byPath(_ root: JSONC.Object) -> [[String]: JSONC.Object] {
            let list = containers(of: source, root: root).filter { paths.contains($0.path) }
            return Dictionary(list.map { ($0.path, $0.servers) }, uniquingKeysWith: { first, _ in first })
        }
        let now = byPath(root)
        let before = byPath(oldRoot)
        for path in paths {
            guard let servers = now[path], let oldServers = before[path], servers.members.count == oldServers.members.count else { return false }
            var checked = Set<String>()
            for (new, previous) in zip(servers.members, oldServers.members) {
                guard new.key == previous.key else { return false }
                if checked.insert(new.key).inserted, let wanted = planned[Location(container: path, server: new.key)] {
                    guard let written = new.value.object(in: text) as? [String: Any], NSDictionary(dictionary: written).isEqual(to: wanted) else {
                        return false
                    }
                } else if document.string(new.value.range) != old.string(previous.value.range) {
                    return false
                }
            }
            for location in planned.keys where location.container == path && !checked.contains(location.server) { return false }
        }
        if source.format == .strictJSON, (try? JSONSerialization.jsonObject(with: Data(text.utf8))) == nil { return false }
        return true
    }

    /// The TOML entries' edits, made on one reading of the file and checked on one reading of the result. `taken`, as for
    /// `editJSON`.
    static func editTOML(_ text: String, entries moves: [EntryMove], nxtrm: [String],
                         taken: Set<String> = []) -> Result<Edited, EditFailure> {
        guard let outline = TOMLOutline(text) else { return .failure(EditFailure("the entry is not there any more")) }
        let wanted = Set(moves.map(\.location))
        let names = Set(wanted.map(\.server))
        let found = firstByLocation(tomlEntries(outline) ?? [], wanted: wanted)
        let tables = firstTables(outline, named: names)
        let reader = TOMLReader(outline)
        let bytes = Array(text.utf8)
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var changes: [(range: Range<Int>, with: String)] = []
        var argsWanted: [Location: [String]] = [:]
        var made: [EditedEntry] = []
        for move in moves {
            guard let entry = found[move.location] else { return .failure(EditFailure("the entry is not there any more")) }
            if let reason = entry.notMovable { return .failure(EditFailure(reason)) }
            for pair in move.pairs {
                if let reason = changeRefusal(entry, variable: pair.variable, expected: move.expected[pair.variable]) {
                    return .failure(EditFailure(reason))
                }
            }
            if let reason = wrapperRefusal(move.pairs, command: entry.command + entry.args) { return .failure(EditFailure(reason)) }
            guard let table = tables[move.location.server],
                  let own = tomlChanges(table, move: move, command: entry.command + entry.args, nxtrm: nxtrm, reader: reader, newline: newline,
                                        taken: taken)
            else {
                return .failure(EditFailure("the entry can't be read"))
            }
            changes += own.changes
            argsWanted[move.location] = own.args
            let moved = Dictionary(move.pairs.map { ($0.variable, $0.name) }, uniquingKeysWith: { first, _ in first })
            let backup = marked(bytes, entry: entry, moved: moved)
            made.append(EditedEntry(original: backup.text, written: "", kept: backup.kept, dropped: own.dropped))
        }
        guard let updated = replacing(text, changes), let check = TOMLOutline(updated) else { return .failure(EditFailure("check failed")) }
        let newFound = firstByLocation(tomlEntries(check) ?? [], wanted: wanted)
        let newTables = firstTables(check, named: names)
        // Each entry now starts the wrapper and holds none of its moved keys, nor what it dropped.
        var spans: [(old: Range<Int>, new: Range<Int>)] = []
        for (move, entryMade) in zip(moves, made) {
            let moved: Set<String> = Set(move.pairs.map(\.variable)).union(entryMade.dropped)
            guard let old = found[move.location], let table = newTables[move.location.server], let newEntry = newFound[move.location],
                  newEntry.command == [nxtrm[0]], newEntry.args == argsWanted[move.location],
                  !newEntry.detected.contains(where: { if case .env(let name) = $0.field { return moved.contains(name) }; return false }) else {
                return .failure(EditFailure("check failed"))
            }
            spans.append((old.range, offsets(table.range, in: updated)))
        }
        // Everything outside the entries is as it was.
        let newBytes = Array(updated.utf8)
        guard sameOutside(bytes, newBytes, spans) else { return .failure(EditFailure("check failed")) }
        for index in made.indices {
            made[index].written = sha256(String(decoding: newBytes[spans[index].new], as: UTF8.self))
        }
        return .success(Edited(text: updated, entries: made))
    }

    /// The first table of each name wanted, as `first(where:)` finds it.
    static func firstTables(_ outline: TOMLOutline, named names: Set<String>) -> [String: TOMLTable] {
        var tables: [String: TOMLTable] = [:]
        for table in tomlTables(outline) where names.contains(table.name) && tables[table.name] == nil { tables[table.name] = table }
        return tables
    }

    /// The bytes outside the spans (each an entry's range before and after the edit) are the same, in the same order.
    static func sameOutside(_ old: [UInt8], _ new: [UInt8], _ spans: [(old: Range<Int>, new: Range<Int>)]) -> Bool {
        var oldCursor = 0
        var newCursor = 0
        for span in spans.sorted(by: { $0.old.lowerBound < $1.old.lowerBound }) {
            guard span.old.lowerBound >= oldCursor, span.new.lowerBound >= newCursor, span.old.upperBound <= old.count,
                  span.new.upperBound <= new.count,
                  old[oldCursor..<span.old.lowerBound].elementsEqual(new[newCursor..<span.new.lowerBound]) else { return false }
            oldCursor = span.old.upperBound
            newCursor = span.new.upperBound
        }
        return old[oldCursor...].elementsEqual(new[newCursor...])
    }

    typealias TOMLEntryChanges = (changes: [(range: Range<Int>, with: String)], args: [String], dropped: [String])

    /// One TOML entry's changes, as UTF-8 ranges of the file, its new args, and what it dropped: `command` and `args`
    /// replaced (or `args` added), the moved keys taken out of `env` with any variable named in `taken` (the wrapper
    /// would take it out at start), and the start-up wait raised to 30 seconds. Nil when its command can't be read.
    static func tomlChanges(_ table: TOMLTable, move: EntryMove, command old: [String], nxtrm: [String], reader: TOMLReader,
                            newline: String, taken: Set<String> = []) -> TOMLEntryChanges? {
        let outline = reader.outline
        let text = outline.text
        guard let command = table.keys.first(where: { $0.path == ["command"] }), let commandString = outline.string(at: command.value) else {
            return nil
        }
        let args = wrapped(move.pairs, nxtrm: nxtrm, command: old)
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
        let moved = Set(move.pairs.map(\.variable))
        var dropped: Set<String> = []
        func leaves(_ name: String) -> Bool {
            if moved.contains(name) { return true }
            guard taken.contains(name) else { return false }
            dropped.insert(name)
            return true
        }
        if let env = table.keys.first(where: { $0.path == ["env"] }), let (members, end) = reader.members(at: env.value) {
            let left = members.filter { !leaves($0.key) }.map { String(text.unicodeScalars[$0.range]) }
            if left.isEmpty {
                changes.append((offsets(env.line, in: text), ""))
            } else {
                changes.append((offsets(env.value..<end, in: text), "{ " + left.joined(separator: ", ") + " }"))
            }
        }
        for key in table.envKeys where key.path.count == 1 {
            if leaves(key.path[0]) { changes.append((offsets(key.line, in: text), "")) }
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
        return (changes, args, dropped.sorted())
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
    /// `~/.claude.json`, through `MCPRegistrar.write(_:to:)`, and checked after. `isOpen` is asked just before the write.
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
            let replanned = planFile(edit.source, moves: edit.moves, nxtrm: edit.nxtrm, data: current, now: Date(), batch: batch,
                                     taken: edit.taken)
            guard case .success(let again) = replanned,
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
        // Every entry found in one reading of the file: one reading each took time that grows with entries times file.
        let ranges = entryRanges(edit.backups.map(\.location), format: edit.source.format, in: text)
        let bytes = Array(text.utf8)
        return edit.backups.allSatisfy { backup in
            ranges[backup.location].map { sha256(String(decoding: bytes[$0], as: UTF8.self)) } == backup.written
        }
    }

    /// The text of the entry at `location` now, or nil when it is not there.
    static func entryText(_ location: Location, format: Format, in text: String) -> String? {
        entryRange(location, format: format, in: text).map { String(decoding: Array(text.utf8)[$0], as: UTF8.self) }
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
        entryRanges([location], format: format, in: text)[location]
    }

    /// Where each entry at `locations` is now, as UTF-8 offsets, from one reading of the file: in TOML the first table of
    /// its server's name, in JSON the first member of its name in its container. One not there is left out.
    static func entryRanges(_ locations: [Location], format: Format, in text: String) -> [Location: Range<Int>] {
        var ranges: [Location: Range<Int>] = [:]
        if format == .toml {
            guard let outline = TOMLOutline(text) else { return [:] }
            let tables = firstTables(outline, named: Set(locations.map(\.server)))
            for location in locations { ranges[location] = tables[location.server].map { offsets($0.range, in: text) } }
            return ranges
        }
        guard let document = JSONC(text), case .object(let root)? = document.root else { return [:] }
        let wanted = Set(locations)
        for path in Set(locations.map(\.container)) {
            guard let servers = object(at: path, in: root) else { continue }
            for member in servers.members {
                let location = Location(container: path, server: member.key)
                if wanted.contains(location), ranges[location] == nil { ranges[location] = offsets(member.value.range, in: text) }
            }
        }
        return ranges
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
