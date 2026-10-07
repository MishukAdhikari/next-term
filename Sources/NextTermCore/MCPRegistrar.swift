import Foundation

/// Registers Next Term's MCP server (`nxtrm mcp`) in the AI agents on this Mac, so any of them can drive
/// Next Term. Each agent keeps its servers in its own file and format; only Next Term's entry is
/// written, by text, so everything else in the file (comments included) stays byte for byte. An entry
/// named `next-term` that is not Next Term's is never touched. Turning the setting off removes ours.
/// Claude Code keeps its servers in a file it rewrites itself, so the app registers there with
/// `claude mcp add-json` instead (see `claudeEntry`).
public enum MCPRegistrar {
    public enum Status: Equatable, Sendable {
        case registered
        /// There already, pointing at this app.
        case alreadyRegistered
        case removed
        /// Not installed (no configuration and no program): nothing written.
        case notInstalled
        /// A `next-term` entry that is not Next Term's.
        case nameTaken
        /// The file could not be edited safely (comments or trailing commas in a strict-JSON file, not parseable, odd shape).
        case skipped(String)
    }

    public enum Format: Sendable, Equatable { case json(strict: Bool), toml }

    /// One agent's user-level MCP configuration.
    public struct Target: Sendable {
        public let id: String
        public let name: String
        /// Program names: when one is installed, a missing configuration file is created.
        public let programs: [String]
        /// Folders whose existence also means the agent is installed (Cursor's command is now the
        /// generic `agent`, too common a name to look for; its ~/.cursor folder says it is there; the
        /// Claude app has no command at all).
        public var markers: [String] = []
        public let file: String
        public let format: Format
        /// JSON: the top-level key holding the servers (`mcpServers`, `mcp`, `amp.mcpServers`).
        public let container: String
        /// Top-level members a new file starts with (Qwen's `$version`, opencode's `$schema`), as JSON.
        public let preamble: [String: String]
        /// The entry for a command path.
        public let entry: @Sendable (String) -> [String: Any]
    }

    public static let serverName = "next-term"

    /// The agents, from claudedocs/research_next-term-mcp-registration (paths and shapes checked against
    /// each agent's source). Claude Code is registered through its own command line instead.
    public static func targets(home: String = NSHomeDirectory()) -> [Target] {
        func path(_ relative: String) -> String { (home as NSString).appendingPathComponent(relative) }
        func existing(_ candidates: [String]) -> String {
            candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
        }
        let standard: @Sendable (String) -> [String: Any] = { ["command": $0, "args": ["mcp"]] }
        // opencode reads opencode.json, then opencode.jsonc (later wins): write the one that exists.
        let opencode = existing([path(".config/opencode/opencode.jsonc"), path(".config/opencode/opencode.json")])
        let amp = existing([path(".config/amp/settings.json"), path(".config/amp/settings.jsonc")])
        return [
            Target(id: "codex", name: "Codex", programs: ["codex"], file: path(".codex/config.toml"), format: .toml,
                   container: "mcp_servers", preamble: [:], entry: standard),
            Target(id: "gemini", name: "Gemini CLI", programs: ["gemini"], file: path(".gemini/settings.json"),
                   format: .json(strict: false), container: "mcpServers", preamble: [:], entry: standard),
            Target(id: "qwen", name: "Qwen Code", programs: ["qwen"], file: path(".qwen/settings.json"),
                   format: .json(strict: false), container: "mcpServers", preamble: ["$version": "4"],
                   entry: { ["command": $0, "args": ["mcp"], "alwaysLoadTools": true] }),
            Target(id: "cursor", name: "Cursor", programs: ["cursor-agent"], markers: [path(".cursor")], file: path(".cursor/mcp.json"),
                   format: .json(strict: false), container: "mcpServers", preamble: [:],
                   entry: { ["type": "stdio", "command": $0, "args": ["mcp"]] }),
            Target(id: "opencode", name: "opencode", programs: ["opencode"], file: opencode,
                   format: .json(strict: false), container: "mcp", preamble: ["$schema": #""https://opencode.ai/config.json""#],
                   entry: { ["type": "local", "command": [$0, "mcp"], "enabled": true] }),
            Target(id: "copilot", name: "Copilot CLI", programs: ["copilot"], file: path(".copilot/mcp-config.json"),
                   format: .json(strict: false), container: "mcpServers", preamble: [:],
                   entry: { ["type": "local", "command": $0, "args": ["mcp"], "tools": ["*"]] }),
            Target(id: "amp", name: "Amp", programs: ["amp"], file: amp,
                   format: .json(strict: false), container: "amp.mcpServers", preamble: [:], entry: standard),
            Target(id: "junie", name: "Junie", programs: ["junie"], file: path(".junie/mcp/mcp.json"),
                   format: .json(strict: false), container: "mcpServers", preamble: [:],
                   entry: { ["command": $0, "args": ["mcp"], "enabled": true] }),
            Target(id: "commandcode", name: "Command Code", programs: ["commandcode", "command-code"], file: path(".commandcode/mcp.json"),
                   format: .json(strict: true), container: "mcpServers", preamble: [:],
                   entry: { ["transport": "stdio", "command": $0, "args": ["mcp"], "enabled": true] }),
            // The Claude app's chats read only this file, and only when the app starts (its Code tab uses
            // Claude Code's entry). The app keeps its own preferences in the same file.
            Target(id: "claude-desktop", name: "Claude app", programs: [], markers: [path("Library/Application Support/Claude")],
                   file: path("Library/Application Support/Claude/claude_desktop_config.json"),
                   format: .json(strict: true), container: "mcpServers", preamble: [:], entry: standard),
        ]
    }

    /// The command of an entry: `command` as a string, or the first word of a `command` array (opencode).
    static func command(of value: Any?) -> String? {
        guard let entry = value as? [String: Any] else { return nil }
        return (entry["command"] as? String) ?? ((entry["command"] as? [Any])?.first as? String)
    }

    /// Next Term's: `nxtrm` inside an app bundle (any copy: moved, renamed, a development build).
    public static func isOurs(command: String?) -> Bool {
        guard let command else { return false }
        return (command as NSString).lastPathComponent == "nxtrm" && command.contains(".app/Contents/Resources/bin/")
    }

    /// Installed: one of its programs is on the PATH (`found` maps names to paths), or a marker folder exists.
    public static func isInstalled(_ target: Target, found: [String: String]) -> Bool {
        target.programs.contains { found[$0] != nil } || target.markers.contains { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: register / unregister

    /// `programInstalled`: one of the target's programs is on the user's PATH (a missing file is created).
    @discardableResult
    public static func register(_ target: Target, command: String, programInstalled: Bool) -> Status {
        let exists = FileManager.default.fileExists(atPath: target.file)
        guard exists || programInstalled else { return .notInstalled }
        switch target.format {
        case .toml: return registerTOML(target, command: command)
        case .json(let strict): return registerJSON(target, command: command, strict: strict)
        }
    }

    @discardableResult
    public static func unregister(_ target: Target) -> Status {
        guard FileManager.default.fileExists(atPath: target.file) else { return .notInstalled }
        switch target.format {
        case .toml: return unregisterTOML(target)
        case .json(let strict): return unregisterJSON(target, strict: strict)
        }
    }

    // MARK: JSON (and JSON with comments)

    private static func registerJSON(_ target: Target, command: String, strict: Bool) -> Status {
        let entry = target.entry(command)
        guard let entryText = compact(entry) else { return .skipped("entry") }
        guard FileManager.default.fileExists(atPath: target.file) else {
            try? FileManager.default.createDirectory(atPath: (target.file as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            var members = target.preamble.sorted { $0.key < $1.key }.map { "  \(quote($0.key)): \($0.value)" }
            members.append("  \(quote(target.container)): {\n    \(quote(serverName)): \(entryText)\n  }")
            let body = "{\n" + members.joined(separator: ",\n") + "\n}\n"
            return verifiedWrite(body, to: target.file, target: target, expecting: command) ? .registered : .skipped("write")
        }
        guard let text = read(target.file) else { return .skipped("unreadable") }
        guard let document = JSONC(text) else { return .skipped("not valid JSON") }
        if strict && document.hasComments { return .skipped("comments in a file that must be plain JSON") }
        // Foundation's parser lets a trailing comma through; the agent's own would not.
        if strict && JSONC.plain(text) != text { return .skipped("trailing commas in a file that must be plain JSON") }
        guard case .object(let root)? = document.root else { return .skipped("not a JSON object") }
        var updated = text
        if let container = root.member(target.container) {
            guard case .object(let servers) = container.value else { return .skipped("\(target.container) is not an object") }
            let outer = document.indent(of: container.keyRange.lowerBound)
            if let existing = servers.member(serverName) {
                let current = Self.command(of: existing.value.object(in: text))
                guard isOurs(command: current) else { return .nameTaken }
                if current == command { return .alreadyRegistered }
                // Ours, from another copy of the app (moved, or a development build): point it here.
                updated.replaceSubrange(existing.value.range, with: entryText)
            } else if let first = servers.members.first {
                let insertion = "\n" + document.indent(of: first.keyRange.lowerBound) + quote(serverName) + ": " + entryText + ","
                updated.insert(contentsOf: insertion, at: text.index(after: servers.open))
            } else {
                // An empty object: ours on its own line. Comments inside it stay after ours.
                let inside = text.index(after: servers.open)..<text.index(before: servers.close)
                let line = "\n" + outer + "  " + quote(serverName) + ": " + entryText
                if text[inside].allSatisfy(\.isWhitespace) {
                    updated.replaceSubrange(inside, with: line + "\n" + outer)
                } else {
                    updated.insert(contentsOf: line, at: inside.lowerBound)
                }
            }
        } else {
            let indent = root.members.first.map { document.indent(of: $0.keyRange.lowerBound) } ?? "  "
            let block = quote(target.container) + ": {\n" + indent + "  " + quote(serverName) + ": " + entryText + "\n" + indent + "}"
            let insertion = "\n" + indent + block + (root.members.isEmpty ? "\n" : ",")
            updated.insert(contentsOf: insertion, at: text.index(after: root.open))
        }
        return verifiedWrite(updated, to: target.file, target: target, expecting: command) ? .registered : .skipped("check failed")
    }

    private static func unregisterJSON(_ target: Target, strict: Bool) -> Status {
        guard let text = read(target.file), let document = JSONC(text), case .object(let root)? = document.root else {
            return .skipped("not valid JSON")
        }
        guard let container = root.member(target.container), case .object(let servers) = container.value,
              let existing = servers.member(serverName) else { return .removed }
        guard isOurs(command: command(of: existing.value.object(in: text))) else { return .nameTaken }
        if strict && document.hasComments { return .skipped("comments in a file that must be plain JSON") }
        // Ours alone in its container (which registering added): the container goes too.
        let alone = servers.members.count == 1 && JSONC(String(document.text[servers.open..<servers.close]))?.hasComments == false
        let updated = alone ? document.removing(container, from: root) : document.removing(existing, from: servers)
        guard let check = JSONC(updated), case .object(let newRoot)? = check.root else { return .skipped("check failed") }
        if alone {
            guard newRoot.member(target.container) == nil, newRoot.members.count == root.members.count - 1 else { return .skipped("check failed") }
        } else {
            guard let newContainer = newRoot.member(target.container), case .object(let newServers) = newContainer.value,
                  newServers.member(serverName) == nil, newServers.members.count == servers.members.count - 1,
                  newRoot.members.count == root.members.count else { return .skipped("check failed") }
        }
        return writeRaw(updated, to: target.file) ? .removed : .skipped("write")
    }

    /// Writes only when the result parses and has exactly our command under our name.
    private static func verifiedWrite(_ text: String, to path: String, target: Target, expecting command: String) -> Bool {
        guard let document = JSONC(text), case .object(let root)? = document.root,
              let container = root.member(target.container), case .object(let servers) = container.value,
              let entry = servers.member(serverName),
              let written = entry.value.object(in: text) as? [String: Any],
              NSDictionary(dictionary: written).isEqual(to: target.entry(command)) else { return false }
        if case .json(strict: true) = target.format, (try? JSONSerialization.jsonObject(with: Data(text.utf8))) == nil { return false }
        return writeRaw(text, to: path)
    }

    // MARK: Claude Code

    public enum ClaudeEntry: Equatable, Sendable {
        case absent
        case ours(command: String)
        case taken
    }

    /// The `next-term` server in Claude Code's user configuration (`~/.claude.json`, top-level `mcpServers`).
    public static func claudeEntry(configuration text: String?) -> ClaudeEntry {
        guard let text, let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let entry = (json["mcpServers"] as? [String: Any])?[serverName] else { return .absent }
        guard let command = command(of: entry), isOurs(command: command) else { return .taken }
        return .ours(command: command)
    }

    /// What `claude mcp add-json` takes.
    public static func claudeJSON(command: String) -> String {
        compact(["type": "stdio", "command": command, "args": ["mcp"]]) ?? "{}"
    }

    // MARK: TOML (Codex)

    /// Any form of a `next-term` server Codex would read: a duplicate stops Codex loading its whole config.
    static func tomlMentions(_ text: String) -> Bool {
        let patterns = [#"(?m)^[ \t]*\[[ \t]*mcp_servers[ \t]*\.[ \t]*["']?next-term["']?[ \t]*[\].]"#,
                        #"(?m)^[ \t]*["']?next-term["']?[ \t]*=[ \t]*\{"#,
                        #"(?m)^[ \t]*mcp_servers[ \t]*\.[ \t]*["']?next-term["']?[ \t]*[.=]"#]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// Our table: from its header line to the next header that is not one of its subtables (Codex adds
    /// `[mcp_servers.next-term.tools.<tool>]` on "Always allow"). `body` is the table's own keys.
    static func tomlTable(_ text: String) -> (whole: Range<String.Index>, body: Range<String.Index>)? {
        guard let header = text.range(of: #"(?m)^\[mcp_servers\.next-term\][ \t]*(#[^\n]*)?(\n|$)"#, options: .regularExpression) else {
            return nil
        }
        var bodyEnd: String.Index?
        var end = text.endIndex
        var search = header.upperBound
        while search < text.endIndex,
              let next = text.range(of: #"(?m)^[ \t]*\["#, options: .regularExpression, range: search..<text.endIndex) {
            if bodyEnd == nil { bodyEnd = next.lowerBound }
            let lineEnd = text[next.lowerBound...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
            if text[next.lowerBound..<lineEnd].trimmingCharacters(in: .whitespaces).hasPrefix("[mcp_servers.next-term.") {
                search = lineEnd
                continue
            }
            end = next.lowerBound
            break
        }
        return (header.lowerBound..<end, header.upperBound..<(bodyEnd ?? end))
    }

    /// The `command = "…"` line in a table body: its range and its value.
    static func tomlCommand(in text: String, body: Range<String.Index>) -> (line: Range<String.Index>, value: String)? {
        guard let match = text.range(of: #"(?m)^[ \t]*command[ \t]*=[^\n]*"#, options: .regularExpression, range: body) else { return nil }
        let line = text[match]
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let raw = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("'") {
            let rest = raw.dropFirst()
            guard let close = rest.firstIndex(of: "'") else { return nil }
            return (match, String(rest[..<close]))
        }
        guard raw.hasPrefix("\"") else { return nil }
        var value = ""
        var i = raw.index(after: raw.startIndex)
        while i < raw.endIndex, raw[i] != "\"" {
            if raw[i] == "\\" {
                i = raw.index(after: i)
                guard i < raw.endIndex else { return nil }
                switch raw[i] {
                case "n": value.append("\n")
                case "t": value.append("\t")
                case "u", "U":
                    let digits = raw[i] == "u" ? 4 : 8
                    let start = raw.index(after: i)
                    guard let end = raw.index(start, offsetBy: digits, limitedBy: raw.endIndex),
                          let code = UInt32(raw[start..<end], radix: 16), let scalar = Unicode.Scalar(code) else { return nil }
                    value.unicodeScalars.append(scalar)
                    i = raw.index(before: end)
                default: value.append(raw[i])
                }
            } else {
                value.append(raw[i])
            }
            i = raw.index(after: i)
        }
        return i < raw.endIndex ? (match, value) : nil
    }

    private static func registerTOML(_ target: Target, command: String) -> Status {
        let text = FileManager.default.fileExists(atPath: target.file) ? read(target.file) : ""
        guard let text else { return .skipped("unreadable") }
        if tomlMentions(text) {
            guard let table = tomlTable(text), let current = tomlCommand(in: text, body: table.body),
                  isOurs(command: current.value) else { return .nameTaken }
            if current.value == command { return .alreadyRegistered }
            // Ours, from another copy of the app: only the command line changes.
            var updated = text
            updated.replaceSubrange(current.line, with: "command = " + tomlString(command))
            return writeRaw(updated, to: target.file) ? .registered : .skipped("write")
        }
        try? FileManager.default.createDirectory(atPath: (target.file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let table = "[mcp_servers.next-term]\ncommand = \(tomlString(command))\nargs = [\"mcp\"]\n"
        let separator = text.isEmpty || text.hasSuffix("\n\n") ? "" : text.hasSuffix("\n") ? "\n" : "\n\n"
        return writeRaw(text + separator + table, to: target.file) ? .registered : .skipped("write")
    }

    private static func unregisterTOML(_ target: Target) -> Status {
        guard let text = read(target.file) else { return .skipped("unreadable") }
        guard let table = tomlTable(text) else { return tomlMentions(text) ? .nameTaken : .removed }
        guard let current = tomlCommand(in: text, body: table.body), isOurs(command: current.value) else { return .nameTaken }
        var before = String(text[..<table.whole.lowerBound])
        let after = String(text[table.whole.upperBound...])
        // The blank line that set our table apart goes with it.
        if after.isEmpty {
            while before.hasSuffix("\n\n") { before.removeLast() }
        } else if before.hasSuffix("\n\n") && after.hasPrefix("\n") == false {
            // [a]\n\n[ours]\n\n[b] → [a]\n\n[b]: the blank line after ours stays as the separator.
        }
        var updated = before + after
        if !text.contains("\n\n\n") { while updated.contains("\n\n\n") { updated = updated.replacingOccurrences(of: "\n\n\n", with: "\n\n") } }
        return writeRaw(updated, to: target.file) ? .removed : .skipped("write")
    }

    static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: files

    private static func read(_ path: String) -> String? {
        guard isRegularFile(canonicalPath(path)), let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Atomic, through symlinks, keeping the file's permissions (0600 stays 0600); nothing if unchanged.
    private static func writeRaw(_ text: String, to path: String) -> Bool {
        if let current = FileManager.default.contents(atPath: path), current == Data(text.utf8) { return true }
        return (try? TextFile.write(Data(text.utf8), to: URL(fileURLWithPath: path))) != nil
    }

    static func compact(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func quote(_ key: String) -> String { compact(key) ?? "\"\(key)\"" }
}

/// JSON that may have comments (`//`, `/* */`) and trailing commas, parsed with the position of every
/// value, so an edit can change one member and leave every other byte of the file alone.
struct JSONC {
    struct Member {
        let key: String
        let keyRange: Range<String.Index>
        let value: Value
    }

    struct Object {
        /// The `{`.
        let open: String.Index
        /// Just past the `}`.
        let close: String.Index
        let members: [Member]
        func member(_ key: String) -> Member? { members.first { $0.key == key } }
    }

    enum Value {
        case object(Object)
        case array(Range<String.Index>)
        case scalar(Range<String.Index>)

        var range: Range<String.Index> {
            switch self {
            case .object(let object): return object.open..<object.close
            case .array(let range), .scalar(let range): return range
            }
        }

        /// The value as Foundation objects.
        func object(in text: String) -> Any? {
            JSONC.plain(String(text[range])).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed) }
        }
    }

    let text: String
    private(set) var root: Value?
    private(set) var hasComments = false
    private var i: String.Index

    init?(_ text: String) {
        self.text = text
        self.i = text.startIndex
        skipSpace()
        guard let value = parseValue() else { return nil }
        skipSpace()
        guard i == text.endIndex else { return nil }
        root = value
    }

    private mutating func skipSpace() {
        while i < text.endIndex {
            let c = text[i]
            if c.isWhitespace || c == "\u{FEFF}" { i = text.index(after: i); continue }
            let next = text.index(after: i)
            if c == "/", next < text.endIndex {
                if text[next] == "/" {
                    hasComments = true
                    while i < text.endIndex, text[i] != "\n" { i = text.index(after: i) }
                    continue
                }
                if text[next] == "*" {
                    hasComments = true
                    guard let end = text.range(of: "*/", range: text.index(after: next)..<text.endIndex) else { i = text.endIndex; return }
                    i = end.upperBound
                    continue
                }
            }
            return
        }
    }

    private mutating func parseValue() -> Value? {
        guard i < text.endIndex else { return nil }
        switch text[i] {
        case "{":
            return parseObject().map(Value.object)
        case "[":
            let start = i
            i = text.index(after: i)
            skipSpace()
            while i < text.endIndex, text[i] != "]" {
                guard parseValue() != nil else { return nil }
                skipSpace()
                guard i < text.endIndex else { return nil }
                if text[i] == "," { i = text.index(after: i); skipSpace() } else if text[i] != "]" { return nil }
            }
            guard i < text.endIndex else { return nil }
            i = text.index(after: i)
            return .array(start..<i)
        case "\"":
            let start = i
            guard parseString() != nil else { return nil }
            return .scalar(start..<i)
        default:
            let start = i
            while i < text.endIndex, !",}]:".contains(text[i]), !text[i].isWhitespace, text[i] != "/" { i = text.index(after: i) }
            guard i > start,
                  (try? JSONSerialization.jsonObject(with: Data(text[start..<i].utf8), options: .fragmentsAllowed)) != nil else { return nil }
            return .scalar(start..<i)
        }
    }

    private mutating func parseString() -> String? {
        let start = i
        i = text.index(after: i)
        while i < text.endIndex, text[i] != "\"" {
            if text[i] == "\\" {
                i = text.index(after: i)
                guard i < text.endIndex else { return nil }
            }
            i = text.index(after: i)
        }
        guard i < text.endIndex else { return nil }
        i = text.index(after: i)
        return (try? JSONSerialization.jsonObject(with: Data(text[start..<i].utf8), options: .fragmentsAllowed)) as? String
    }

    private mutating func parseObject() -> Object? {
        let open = i
        i = text.index(after: i)
        var members: [Member] = []
        skipSpace()
        while i < text.endIndex, text[i] != "}" {
            guard text[i] == "\"" else { return nil }
            let keyStart = i
            guard let key = parseString() else { return nil }
            let keyRange = keyStart..<i
            skipSpace()
            guard i < text.endIndex, text[i] == ":" else { return nil }
            i = text.index(after: i)
            skipSpace()
            guard let value = parseValue() else { return nil }
            members.append(Member(key: key, keyRange: keyRange, value: value))
            skipSpace()
            guard i < text.endIndex else { return nil }
            if text[i] == "," { i = text.index(after: i); skipSpace() } else if text[i] != "}" { return nil }
        }
        guard i < text.endIndex else { return nil }
        i = text.index(after: i)
        return Object(open: open, close: i, members: members)
    }

    /// The elements of an array in this document, by position like members (nothing is converted).
    func elements(of array: Value) -> [Value]? {
        guard case .array(let range) = array else { return nil }
        var cursor = self
        cursor.i = text.index(after: range.lowerBound)
        var values: [Value] = []
        cursor.skipSpace()
        while cursor.i < range.upperBound, text[cursor.i] != "]" {
            guard let value = cursor.parseValue() else { return nil }
            values.append(value)
            cursor.skipSpace()
            guard cursor.i < range.upperBound else { return nil }
            if text[cursor.i] == "," {
                cursor.i = text.index(after: cursor.i)
                cursor.skipSpace()
            } else if text[cursor.i] != "]" {
                return nil
            }
        }
        return values
    }

    /// The whitespace that starts the line holding `index`.
    func indent(of index: String.Index) -> String {
        var start = index
        while start > text.startIndex, text[text.index(before: start)] != "\n" { start = text.index(before: start) }
        return String(text[start..<index].prefix { $0 == " " || $0 == "\t" })
    }

    private func isBlank(_ c: Character) -> Bool { c == " " || c == "\t" }

    /// The text without one member of `object`: the member and one comma, and its line when it has one
    /// to itself.
    func removing(_ member: Member, from object: Object) -> String {
        guard let index = object.members.firstIndex(where: { $0.keyRange == member.keyRange }) else { return text }
        var start = member.keyRange.lowerBound
        var end = member.value.range.upperBound
        if index + 1 < object.members.count {
            // Up to where the next member's line starts (taking our comma and line break).
            end = object.members[index + 1].keyRange.lowerBound
            while end > member.value.range.upperBound, isBlank(text[text.index(before: end)]) { end = text.index(before: end) }
            var lineStart = start
            while lineStart > text.startIndex, isBlank(text[text.index(before: lineStart)]) { lineStart = text.index(before: lineStart) }
            if lineStart == text.startIndex || text[text.index(before: lineStart)] == "\n" { start = lineStart }
            // Same line as the next member ({"a": 1, "b": 2}): keep that line's start.
            if !text[member.value.range.upperBound..<end].contains("\n") {
                end = object.members[index + 1].keyRange.lowerBound
                start = member.keyRange.lowerBound
            }
        } else if index > 0 {
            // The last member: from the end of the previous one, so its comma goes.
            start = object.members[index - 1].value.range.upperBound
            // A trailing comma after us stays valid JSONC, but drop it too.
            var after = end
            while after < text.endIndex, text[after].isWhitespace { after = text.index(after: after) }
            if after < text.endIndex, text[after] == "," { end = text.index(after: after) }
        } else {
            // The only member: the object becomes {} with its closing brace where it was.
            start = text.index(after: object.open)
            end = text.index(before: object.close)
        }
        var result = text
        result.removeSubrange(start..<end)
        return result
    }

    /// Plain JSON: comments removed, trailing commas dropped.
    static func plain(_ text: String) -> String? {
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\"" {
                let start = i
                i = text.index(after: i)
                while i < text.endIndex, text[i] != "\"" {
                    if text[i] == "\\" {
                        i = text.index(after: i)
                        if i == text.endIndex { return nil }
                    }
                    i = text.index(after: i)
                }
                guard i < text.endIndex else { return nil }
                i = text.index(after: i)
                out += text[start..<i]
                continue
            }
            let next = text.index(after: i)
            if c == "/", next < text.endIndex, text[next] == "/" {
                while i < text.endIndex, text[i] != "\n" { i = text.index(after: i) }
                continue
            }
            if c == "/", next < text.endIndex, text[next] == "*" {
                guard let end = text.range(of: "*/", range: text.index(after: next)..<text.endIndex) else { return nil }
                i = end.upperBound
                out.append(" ")
                continue
            }
            if c == "," {
                // A comma followed (past space and comments) by } or ] is a trailing comma.
                var j = next
                while j < text.endIndex {
                    if text[j].isWhitespace { j = text.index(after: j); continue }
                    let after = text.index(after: j)
                    if text[j] == "/", after < text.endIndex, text[after] == "/" {
                        while j < text.endIndex, text[j] != "\n" { j = text.index(after: j) }
                        continue
                    }
                    if text[j] == "/", after < text.endIndex, text[after] == "*",
                       let end = text.range(of: "*/", range: text.index(after: after)..<text.endIndex) {
                        j = end.upperBound
                        continue
                    }
                    break
                }
                if j < text.endIndex, text[j] == "}" || text[j] == "]" {
                    i = next
                    continue
                }
            }
            out.append(c)
            i = next
        }
        return out
    }
}
