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
        /// The file could not be edited safely (comments or trailing commas in a strict-JSON file, repeated keys,
        /// read-only, changed while being edited, not parseable, odd shape), or the Claude app is open.
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
        /// Bundle identifiers of desktop apps that read this file too (the ChatGPT app runs its own codex):
        /// one installed also means the agent is.
        public var apps: [String] = []
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
            Target(id: "codex", name: "Codex", programs: ["codex"], markers: [path(".codex")], apps: ["com.openai.codex"],
                   file: path(".codex/config.toml"), format: .toml, container: "mcp_servers", preamble: [:], entry: standard),
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
            // The Claude app reads this file only when it starts, for its chats and the local sessions in its Code
            // tab (where this entry wins over Claude Code's). It keeps its preferences here too, saving the whole
            // file from the copy it read, so Next Term edits it only while Claude is closed (`whileClaudeAppIsOpen`).
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

    /// Installed: one of its programs is on the PATH or one of its apps is installed (`found` maps program names
    /// and bundle identifiers to paths), or a marker folder exists.
    public static func isInstalled(_ target: Target, found: [String: String]) -> Bool {
        let program = target.programs.contains { found[$0] != nil } || target.apps.contains { found[$0] != nil }
        return program || target.markers.contains { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: register / unregister

    /// `programInstalled`: one of the target's programs is on the user's PATH (a missing file is created).
    @discardableResult
    public static func register(_ target: Target, command: String, programInstalled: Bool) -> Status {
        write(plan(target, command: command, programInstalled: programInstalled), to: target.file)
    }

    @discardableResult
    public static func unregister(_ target: Target) -> Status {
        write(plan(target, command: nil, programInstalled: false), to: target.file)
    }

    /// An edit worked out from the file as it was read, not written yet.
    struct Plan {
        var status: Status
        /// What to write (nil: nothing).
        var text: String?
        /// The file's bytes when it was read (nil: there was no file).
        var original: Data?

        init(_ status: Status, text: String? = nil) {
            self.status = status
            self.text = text
        }
    }

    /// Registering `command`, or unregistering (nil).
    static func plan(_ target: Target, command: String?, programInstalled: Bool) -> Plan {
        let exists = FileManager.default.fileExists(atPath: target.file)
        guard exists || (command != nil && programInstalled) else { return Plan(.notInstalled) }
        // A link to a file that is not there (on a volume not mounted): a write would put a file in its place.
        if !exists, (try? FileManager.default.destinationOfSymbolicLink(atPath: target.file)) != nil {
            return Plan(.skipped("a link to a file that is not there"))
        }
        let file = exists ? read(target.file) : nil
        if exists && file == nil { return Plan(.skipped("unreadable")) }
        var planned: Plan
        switch (target.format, command) {
        case (.toml, let command?): planned = registerTOML(file?.text ?? "", command: command)
        case (.toml, nil): planned = unregisterTOML(file?.text ?? "")
        case (.json(let strict), let command?): planned = registerJSON(target, file?.text, command: command, strict: strict)
        case (.json(let strict), nil): planned = unregisterJSON(target, file?.text ?? "", strict: strict)
        }
        planned.original = file?.data
        return planned
    }

    /// Atomic, through symlinks, keeping the file's permissions (0600 stays 0600) and a UTF-8 byte order mark.
    /// A read-only file is left alone, and so is one that changed since it was read (its agent saving it: this
    /// edit would undo that).
    static func write(_ planned: Plan, to path: String) -> Status {
        guard let text = planned.text else { return planned.status }
        let mark = Data([0xEF, 0xBB, 0xBF])
        let marked = planned.original?.starts(with: mark) == true
        let data = (marked ? mark : Data()) + Data(text.utf8)
        let current = FileManager.default.contents(atPath: path)
        if current == data { return planned.status }
        guard current == planned.original else { return .skipped("changed while being edited") }
        if current != nil, !FileManager.default.isWritableFile(atPath: path) { return .skipped("read-only") }
        if current == nil {
            let folder = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        return (try? TextFile.write(data, to: URL(fileURLWithPath: path))) != nil ? planned.status : .skipped("write")
    }

    // MARK: The Claude app

    /// The Claude app reads its file when it starts, and saves the whole file from that copy whenever one of its
    /// settings changes: an edit made while it runs would be undone. So its file waits until it quits.
    public static let claudeAppBundle = "com.anthropic.claudefordesktop"

    /// While the Claude app is open nothing is written. `waiting`: what the edit does once it quits (true: adds
    /// Next Term, false: takes it out; nil: nothing to do).
    public static func whileClaudeAppIsOpen(_ target: Target, command: String?, programInstalled: Bool) -> (status: Status, waiting: Bool?) {
        let planned = plan(target, command: command, programInstalled: programInstalled)
        guard planned.text != nil else { return (planned.status, nil) }
        return (.skipped("the Claude app is open"), command != nil)
    }

    /// For Settings: what waits for the Claude app to quit, once that matches the setting (`on`: a pass for a
    /// setting just changed may still be running); "" for nothing.
    public static func claudeAppNote(waiting: Bool?, on: Bool) -> String {
        guard let waiting, waiting == on else { return "" }
        return on ? " Quit and reopen the Claude app to add it there too." : " Quit the Claude app to remove it there too."
    }

    // MARK: JSON (and JSON with comments)

    /// `text`: nil when there is no file yet.
    private static func registerJSON(_ target: Target, _ text: String?, command: String, strict: Bool) -> Plan {
        guard let entryText = compact(target.entry(command)) else { return Plan(.skipped("entry")) }
        let ours = quote(serverName) + ": " + entryText
        guard let text else {
            var members = target.preamble.sorted { $0.key < $1.key }.map { "  \(quote($0.key)): \($0.value)" }
            members.append("  \(quote(target.container)): {\n    \(ours)\n  }")
            let body = "{\n" + members.joined(separator: ",\n") + "\n}\n"
            return verified(body, target: target, command: command, whole: true)
        }
        guard let document = JSONC(text) else { return Plan(.skipped("not valid JSON")) }
        if let refused = refusal(document, strict: strict) { return Plan(.skipped(refused)) }
        guard case .object(let root)? = document.root else { return Plan(.skipped("not a JSON object")) }
        // JSON parsers take the last of repeated keys; this edit would go to the first.
        if root.hasRepeatedKeys { return Plan(.skipped("repeated keys")) }
        let scalars = text.unicodeScalars
        var updated = text
        if let container = root.member(target.container) {
            guard case .object(let servers) = container.value else { return Plan(.skipped("\(target.container) is not an object")) }
            if servers.hasRepeatedKeys { return Plan(.skipped("repeated keys")) }
            if let existing = servers.member(serverName) {
                let current = Self.command(of: existing.value.object(in: text))
                guard isOurs(command: current) else { return Plan(.nameTaken) }
                if current == command { return Plan(.alreadyRegistered) }
                // Ours, from another copy of the app (moved, or a development build): only its command changes,
                // so what the user added to the entry (env, disabled) stays.
                guard let range = commandRange(of: existing.value, in: document) else { return Plan(.skipped("odd shape")) }
                updated.unicodeScalars.replaceSubrange(range, with: quote(command).unicodeScalars)
                return verified(updated, target: target, command: command, whole: false)
            }
            let inside = scalars.index(after: servers.open)..<scalars.index(before: servers.close)
            if let first = servers.members.first {
                let insertion = "\n" + document.indent(of: first.keyRange.lowerBound) + ours + ","
                updated.unicodeScalars.insert(contentsOf: insertion.unicodeScalars, at: inside.lowerBound)
            } else if inside.isEmpty {
                // {}: ours inside, on the same line, so taking it out leaves {} again.
                updated.unicodeScalars.insert(contentsOf: ours.unicodeScalars, at: inside.lowerBound)
            } else {
                // An empty object over lines: ours on its own line. Comments inside it stay after ours.
                let outer = document.indent(of: container.keyRange.lowerBound)
                let line = "\n" + outer + "  " + ours
                if scalars[inside].allSatisfy(\.properties.isWhitespace) {
                    updated.unicodeScalars.replaceSubrange(inside, with: (line + "\n" + outer).unicodeScalars)
                } else {
                    updated.unicodeScalars.insert(contentsOf: line.unicodeScalars, at: inside.lowerBound)
                }
            }
        } else {
            // The container goes first, in the shape `unregisterJSON` looks for.
            let first = root.members.first
            let indent = first.map { document.indent(of: $0.keyRange.lowerBound) } ?? "  "
            let block = quote(target.container) + ": {\n" + indent + "  " + ours + "\n" + indent + "}"
            if let first {
                // On lines of its own just before the first member's line (a comment on the { line stays there),
                // or, with the first member on the { line ({"a": 1}), just before it on that line.
                let lineStart = document.lineStart(of: first.keyRange.lowerBound)
                let ownLines = lineStart > root.open
                let insertion = ownLines ? indent + block + ",\n" : block + ", "
                let position = ownLines ? lineStart : first.keyRange.lowerBound
                updated.unicodeScalars.insert(contentsOf: insertion.unicodeScalars, at: position)
            } else {
                let insertion = "\n" + indent + block + "\n"
                updated.unicodeScalars.insert(contentsOf: insertion.unicodeScalars, at: scalars.index(after: root.open))
            }
        }
        return verified(updated, target: target, command: command, whole: true)
    }

    private static func unregisterJSON(_ target: Target, _ text: String, strict: Bool) -> Plan {
        guard let document = JSONC(text), case .object(let root)? = document.root else { return Plan(.skipped("not valid JSON")) }
        if root.hasRepeatedKeys { return Plan(.skipped("repeated keys")) }
        guard let container = root.member(target.container), case .object(let servers) = container.value else { return Plan(.removed) }
        if servers.hasRepeatedKeys { return Plan(.skipped("repeated keys")) }
        guard let existing = servers.member(serverName) else { return Plan(.removed) }
        guard isOurs(command: command(of: existing.value.object(in: text))) else { return Plan(.nameTaken) }
        if let refused = refusal(document, strict: strict) { return Plan(.skipped(refused)) }
        // Ours alone in a container that registering added (it is in the shape registering writes): the container
        // goes too. One that was there before keeps its {}.
        let indent = document.indent(of: container.keyRange.lowerBound)
        let line = indent + "  " + quote(serverName) + ": " + document.string(existing.value.range)
        let added = "{\n" + line + "\n" + indent + "}"
        let alone = servers.members.count == 1 && document.string(container.value.range) == added
        let updated = alone ? document.removing(container, from: root) : document.removing(existing, from: servers)
        guard let check = JSONC(updated), case .object(let newRoot)? = check.root else { return Plan(.skipped("check failed")) }
        if alone {
            guard newRoot.member(target.container) == nil, newRoot.members.count == root.members.count - 1 else { return Plan(.skipped("check failed")) }
        } else {
            guard let newContainer = newRoot.member(target.container), case .object(let newServers) = newContainer.value,
                  newServers.member(serverName) == nil, newServers.members.count == servers.members.count - 1,
                  newRoot.members.count == root.members.count else { return Plan(.skipped("check failed")) }
        }
        return Plan(.removed, text: updated)
    }

    /// Why a strict agent's file is left alone: Foundation's parser takes comments and trailing commas, the
    /// agent's own would not.
    private static func refusal(_ document: JSONC, strict: Bool) -> String? {
        guard strict else { return nil }
        if document.hasComments { return "comments in a file that must be plain JSON" }
        if document.hasTrailingCommas { return "trailing commas in a file that must be plain JSON" }
        return nil
    }

    /// The edit, when the result parses and has our command under our name (`whole`: and exactly our entry),
    /// as plain JSON for a strict agent.
    private static func verified(_ text: String, target: Target, command: String, whole: Bool) -> Plan {
        guard let document = JSONC(text), case .object(let root)? = document.root,
              let container = root.member(target.container), case .object(let servers) = container.value,
              let written = servers.member(serverName)?.value.object(in: text) as? [String: Any],
              Self.command(of: written) == command else { return Plan(.skipped("check failed")) }
        if whole, !NSDictionary(dictionary: written).isEqual(to: target.entry(command)) { return Plan(.skipped("check failed")) }
        if case .json(strict: true) = target.format, (try? JSONSerialization.jsonObject(with: Data(text.utf8))) == nil {
            return Plan(.skipped("check failed"))
        }
        return Plan(.registered, text: text)
    }

    /// Where an entry's command string is: `command`, or the first word of a `command` array (opencode).
    private static func commandRange(of entry: JSONC.Value, in document: JSONC) -> Range<String.Index>? {
        guard case .object(let object) = entry, let command = object.member("command") else { return nil }
        if case .scalar(let range) = command.value { return range }
        guard case .scalar(let range)? = document.elements(of: command.value)?.first else { return nil }
        return range
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

    private static func registerTOML(_ text: String, command: String) -> Plan {
        if tomlMentions(text) {
            guard let table = tomlTable(text), let current = tomlCommand(in: text, body: table.body),
                  isOurs(command: current.value) else { return Plan(.nameTaken) }
            if current.value == command { return Plan(.alreadyRegistered) }
            // Ours, from another copy of the app: only the command line changes.
            var updated = text
            updated.replaceSubrange(current.line, with: "command = " + tomlString(command))
            return Plan(.registered, text: updated)
        }
        let table = "[mcp_servers.next-term]\ncommand = \(tomlString(command))\nargs = [\"mcp\"]\n"
        let separator = text.isEmpty || text.hasSuffix("\n\n") ? "" : text.hasSuffix("\n") ? "\n" : "\n\n"
        return Plan(.registered, text: text + separator + table)
    }

    private static func unregisterTOML(_ text: String) -> Plan {
        guard let table = tomlTable(text) else { return Plan(tomlMentions(text) ? .nameTaken : .removed) }
        guard let current = tomlCommand(in: text, body: table.body), isOurs(command: current.value) else { return Plan(.nameTaken) }
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
        return Plan(.removed, text: updated)
    }

    static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: files

    /// A regular file's bytes and text (the text leaves out a UTF-8 byte order mark; `write` puts it back).
    private static func read(_ path: String) -> (data: Data, text: String)? {
        guard isRegularFile(canonicalPath(path)), let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return (data, text)
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
/// value, so an edit can change one member and leave every other byte of the file alone. It is read by
/// Unicode scalar: by Character, a combining mark just after a quote would join the quote.
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
        /// A key that is there twice: JSON parsers take the last one, `member` the first.
        var hasRepeatedKeys: Bool { Set(members.map(\.key)).count < members.count }
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
            JSONC.plain(String(text.unicodeScalars[range])).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed) }
        }
    }

    let text: String
    private let scalars: String.UnicodeScalarView
    private(set) var root: Value?
    private(set) var hasComments = false
    /// A comma just before `}` or `]`.
    private(set) var hasTrailingCommas = false
    private var i: String.Index

    init?(_ text: String) {
        self.text = text
        self.scalars = text.unicodeScalars
        self.i = text.startIndex
        skipSpace()
        guard let value = parseValue() else { return nil }
        skipSpace()
        guard i == scalars.endIndex else { return nil }
        root = value
    }

    /// The text of a range in this document.
    func string(_ range: Range<String.Index>) -> String { String(scalars[range]) }

    private mutating func advance() { i = scalars.index(after: i) }

    private mutating func skipSpace() {
        while i < scalars.endIndex {
            let c = scalars[i]
            if c.properties.isWhitespace || c == "\u{FEFF}" { advance(); continue }
            let next = scalars.index(after: i)
            if c == "/", next < scalars.endIndex {
                if scalars[next] == "/" {
                    hasComments = true
                    while i < scalars.endIndex, scalars[i] != "\n" { advance() }
                    continue
                }
                if scalars[next] == "*" {
                    hasComments = true
                    let rest = scalars.index(after: next)..<scalars.endIndex
                    guard let end = text.range(of: "*/", options: .literal, range: rest) else { i = scalars.endIndex; return }
                    i = end.upperBound
                    continue
                }
            }
            return
        }
    }

    /// Past a comma and the space after it (a `}` or `]` next makes it a trailing comma).
    private mutating func skipComma() {
        advance()
        skipSpace()
        if i < scalars.endIndex, scalars[i] == "}" || scalars[i] == "]" { hasTrailingCommas = true }
    }

    private mutating func parseValue() -> Value? {
        guard i < scalars.endIndex else { return nil }
        switch scalars[i] {
        case "{":
            return parseObject().map(Value.object)
        case "[":
            let start = i
            advance()
            skipSpace()
            while i < scalars.endIndex, scalars[i] != "]" {
                guard parseValue() != nil else { return nil }
                skipSpace()
                guard i < scalars.endIndex else { return nil }
                if scalars[i] == "," { skipComma() } else if scalars[i] != "]" { return nil }
            }
            guard i < scalars.endIndex else { return nil }
            advance()
            return .array(start..<i)
        case "\"":
            let start = i
            guard parseString() != nil else { return nil }
            return .scalar(start..<i)
        default:
            let start = i
            let ends: Set<Unicode.Scalar> = [",", "}", "]", ":", "/"]
            while i < scalars.endIndex, !ends.contains(scalars[i]), !scalars[i].properties.isWhitespace { advance() }
            guard i > start,
                  (try? JSONSerialization.jsonObject(with: Data(text.utf8[start..<i]), options: .fragmentsAllowed)) != nil else { return nil }
            return .scalar(start..<i)
        }
    }

    private mutating func parseString() -> String? {
        let start = i
        advance()
        while i < scalars.endIndex, scalars[i] != "\"" {
            if scalars[i] == "\\" {
                advance()
                guard i < scalars.endIndex else { return nil }
            }
            advance()
        }
        guard i < scalars.endIndex else { return nil }
        advance()
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8[start..<i]), options: .fragmentsAllowed)) as? String
    }

    private mutating func parseObject() -> Object? {
        let open = i
        advance()
        var members: [Member] = []
        skipSpace()
        while i < scalars.endIndex, scalars[i] != "}" {
            guard scalars[i] == "\"" else { return nil }
            let keyStart = i
            guard let key = parseString() else { return nil }
            let keyRange = keyStart..<i
            skipSpace()
            guard i < scalars.endIndex, scalars[i] == ":" else { return nil }
            advance()
            skipSpace()
            guard let value = parseValue() else { return nil }
            members.append(Member(key: key, keyRange: keyRange, value: value))
            skipSpace()
            guard i < scalars.endIndex else { return nil }
            if scalars[i] == "," { skipComma() } else if scalars[i] != "}" { return nil }
        }
        guard i < scalars.endIndex else { return nil }
        advance()
        return Object(open: open, close: i, members: members)
    }

    /// The elements of an array in this document, by position like members (nothing is converted).
    func elements(of array: Value) -> [Value]? {
        guard case .array(let range) = array else { return nil }
        var cursor = self
        cursor.i = scalars.index(after: range.lowerBound)
        var values: [Value] = []
        cursor.skipSpace()
        while cursor.i < range.upperBound, scalars[cursor.i] != "]" {
            guard let value = cursor.parseValue() else { return nil }
            values.append(value)
            cursor.skipSpace()
            guard cursor.i < range.upperBound else { return nil }
            if scalars[cursor.i] == "," {
                cursor.skipComma()
            } else if scalars[cursor.i] != "]" {
                return nil
            }
        }
        return values
    }

    /// Where the line holding `index` starts.
    func lineStart(of index: String.Index) -> String.Index {
        var start = index
        while start > scalars.startIndex, scalars[scalars.index(before: start)] != "\n" { start = scalars.index(before: start) }
        return start
    }

    /// The whitespace that starts the line holding `index`.
    func indent(of index: String.Index) -> String {
        let line = scalars[lineStart(of: index)..<index]
        return String(line.prefix { $0 == " " || $0 == "\t" })
    }

    private func isBlank(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" }

    /// The text without one member of `object`: the member and one comma, and its line when it has one
    /// to itself.
    func removing(_ member: Member, from object: Object) -> String {
        guard let index = object.members.firstIndex(where: { $0.keyRange == member.keyRange }) else { return text }
        var start = member.keyRange.lowerBound
        var end = member.value.range.upperBound
        if index + 1 < object.members.count {
            // Up to where the next member's line starts (taking our comma and line break).
            end = object.members[index + 1].keyRange.lowerBound
            while end > member.value.range.upperBound, isBlank(scalars[scalars.index(before: end)]) { end = scalars.index(before: end) }
            var lineStart = start
            while lineStart > scalars.startIndex, isBlank(scalars[scalars.index(before: lineStart)]) { lineStart = scalars.index(before: lineStart) }
            if lineStart == scalars.startIndex || scalars[scalars.index(before: lineStart)] == "\n" { start = lineStart }
            // Same line as the next member ({"a": 1, "b": 2}): keep that line's start.
            if !scalars[member.value.range.upperBound..<end].contains("\n") {
                end = object.members[index + 1].keyRange.lowerBound
                start = member.keyRange.lowerBound
            }
        } else if index > 0 {
            // The last member: from the end of the previous one, so its comma goes.
            start = object.members[index - 1].value.range.upperBound
            // A trailing comma after us stays valid JSONC, but drop it too.
            var after = end
            while after < scalars.endIndex, scalars[after].properties.isWhitespace { after = scalars.index(after: after) }
            if after < scalars.endIndex, scalars[after] == "," { end = scalars.index(after: after) }
        } else {
            // The only member: the object becomes {} with its closing brace where it was.
            start = scalars.index(after: object.open)
            end = scalars.index(before: object.close)
        }
        var result = text
        result.unicodeScalars.removeSubrange(start..<end)
        return result
    }

    /// Plain JSON: comments removed, trailing commas dropped.
    static func plain(_ text: String) -> String? {
        let scalars = text.unicodeScalars
        var out = String.UnicodeScalarView()
        var i = scalars.startIndex
        /// Just past the `*/` that closes a comment opened before `from`.
        func commentEnd(_ from: String.Index) -> String.Index? {
            text.range(of: "*/", options: .literal, range: from..<scalars.endIndex)?.upperBound
        }
        while i < scalars.endIndex {
            let c = scalars[i]
            if c == "\"" {
                let start = i
                i = scalars.index(after: i)
                while i < scalars.endIndex, scalars[i] != "\"" {
                    if scalars[i] == "\\" {
                        i = scalars.index(after: i)
                        if i == scalars.endIndex { return nil }
                    }
                    i = scalars.index(after: i)
                }
                guard i < scalars.endIndex else { return nil }
                i = scalars.index(after: i)
                out.append(contentsOf: scalars[start..<i])
                continue
            }
            let next = scalars.index(after: i)
            if c == "/", next < scalars.endIndex, scalars[next] == "/" {
                while i < scalars.endIndex, scalars[i] != "\n" { i = scalars.index(after: i) }
                continue
            }
            if c == "/", next < scalars.endIndex, scalars[next] == "*" {
                guard let end = commentEnd(scalars.index(after: next)) else { return nil }
                i = end
                out.append(" ")
                continue
            }
            if c == "," {
                // A comma followed (past space and comments) by } or ] is a trailing comma.
                var j = next
                while j < scalars.endIndex {
                    if scalars[j].properties.isWhitespace { j = scalars.index(after: j); continue }
                    let after = scalars.index(after: j)
                    if scalars[j] == "/", after < scalars.endIndex, scalars[after] == "/" {
                        while j < scalars.endIndex, scalars[j] != "\n" { j = scalars.index(after: j) }
                        continue
                    }
                    if scalars[j] == "/", after < scalars.endIndex, scalars[after] == "*", let end = commentEnd(scalars.index(after: after)) {
                        j = end
                        continue
                    }
                    break
                }
                if j < scalars.endIndex, scalars[j] == "}" || scalars[j] == "]" {
                    i = next
                    continue
                }
            }
            out.append(c)
            i = next
        }
        return String(out)
    }
}
