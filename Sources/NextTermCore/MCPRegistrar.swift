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
        /// The bundle identifier of a desktop app that reads this file only when it starts and saves the whole file
        /// from that copy (the Claude app): the file is edited only while it is closed (see `pass`).
        public var readOnceBy: String?
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

    /// The Claude app's own folder, in the home folder.
    static let claudeAppFolder = "Library/Application Support/Claude"

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
            Target(id: "claude-desktop", name: "the Claude app", programs: [], markers: [path(claudeAppFolder)],
                   readOnceBy: claudeAppBundle, file: path(claudeAppFolder + "/claude_desktop_config.json"),
                   format: .json(strict: true), container: "mcpServers", preamble: [:], entry: standard),
            // Set up for a third-party platform (Bedrock, Vertex), the Claude app keeps its files in a folder of its own.
            Target(id: "claude-desktop-3p", name: "the Claude app", programs: [], markers: [path(claudeAppFolder + "-3p")],
                   readOnceBy: claudeAppBundle, file: path(claudeAppFolder + "-3p/claude_desktop_config.json"),
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
        var planned = plan(target, text: file?.text, command: command)
        planned.original = file?.data
        // Said before anything waits on it (the Claude app's file waits for it to quit); `write` checks again.
        if planned.text != nil, exists, !FileManager.default.isWritableFile(atPath: target.file) { return Plan(.skipped("read-only")) }
        return planned
    }

    /// The edit of a file's text (nil: there is no file).
    static func plan(_ target: Target, text: String?, command: String?) -> Plan {
        switch (target.format, command) {
        case (.toml, let command?): return registerTOML(text ?? "", command: command)
        case (.toml, nil): return unregisterTOML(text ?? "")
        case (.json(let strict), let command?): return registerJSON(target, text, command: command, strict: strict)
        case (.json(let strict), nil): return unregisterJSON(target, text ?? "", strict: strict)
        }
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
    /// Next Term, false: takes it out; nil: nothing to do, or nothing it could do: a read-only file).
    public static func whileClaudeAppIsOpen(_ target: Target, command: String?, programInstalled: Bool) -> (status: Status, waiting: Bool?) {
        let planned = plan(target, command: command, programInstalled: programInstalled)
        guard planned.text != nil else { return (planned.status, nil) }
        return (.skipped(claudeAppIsOpen), command != nil)
    }

    static let claudeAppIsOpen = "the Claude app is open"

    /// For Settings: what waits for the Claude app to quit, once that matches the setting (`on`: a pass for a
    /// setting just changed may still be running), or why its file was left as it is; "" for nothing.
    public static func claudeAppNote(waiting: Bool?, on: Bool, statuses: [String: Status] = [:]) -> String {
        if let waiting {
            guard waiting == on else { return "" }
            return on ? " Quit and reopen the Claude app to add it there too." : " Quit the Claude app to remove it there too."
        }
        for id in ["claude-desktop", "claude-desktop-3p"] {
            if case .skipped(let reason)? = statuses[id], reason != claudeAppIsOpen { return " The Claude app's file was left as it is (\(reason))." }
        }
        return ""
    }

    // MARK: A pass over the agents

    /// What a pass found: each target's status, and what waits for the Claude app to quit (see `whileClaudeAppIsOpen`).
    public struct Pass: Equatable, Sendable {
        public var statuses: [String: Status] = [:]
        public var waiting: Bool?
    }

    /// Registers `command` in `targets` (nil: unregisters). The file of an app that reads it once (`Target.readOnceBy`)
    /// is left for later while `isOpen` (asked just before the file would be edited) says that app runs. `found`: the
    /// programs and apps found (see `isInstalled`).
    public static func pass(_ targets: [Target], command: String?, found: [String: String], isOpen: (String) -> Bool) -> Pass {
        var result = Pass()
        for target in targets {
            let installed = isInstalled(target, found: found)
            if let app = target.readOnceBy, isOpen(app) {
                let open = whileClaudeAppIsOpen(target, command: command, programInstalled: installed)
                result.statuses[target.id] = open.status
                result.waiting = result.waiting ?? open.waiting
            } else if let command {
                result.statuses[target.id] = register(target, command: command, programInstalled: installed)
            } else {
                result.statuses[target.id] = unregister(target)
            }
        }
        return result
    }

    /// The statuses after a pass: one over every agent (`whole`) replaces them, one over the Claude app's files only
    /// updates those.
    public static func merged(_ previous: [String: Status], _ pass: [String: Status], whole: Bool) -> [String: Status] {
        whole ? pass : previous.merging(pass) { _, new in new }
    }

    /// Desktop apps named beside the agent whose file they read (`Target.apps`).
    public static let appNames = ["com.openai.codex": "the ChatGPT app"]

    /// For Settings: "Registered in Claude Code, Codex, the ChatGPT app and the Claude app." (`statuses` by target id,
    /// and "claude" for Claude Code; `apps`: the bundle identifiers of the desktop apps found).
    public static func summary(_ statuses: [String: Status], apps: Set<String>, home: String = NSHomeDirectory()) -> String {
        var names: [String: [String]] = ["claude": ["Claude Code"]]
        for target in targets(home: home) {
            names[target.id] = [target.name] + target.apps.filter { apps.contains($0) }.compactMap { appNames[$0] }
        }
        func sortKey(_ name: String) -> String { (name.hasPrefix("the ") ? String(name.dropFirst(4)) : name).lowercased() }
        func named(_ wanted: (Status) -> Bool) -> [String] {
            let found = Set(statuses.filter { wanted($0.value) }.keys.flatMap { names[$0] ?? [] })
            return found.sorted { sortKey($0) < sortKey($1) }
        }
        let registered = named { $0 == .registered || $0 == .alreadyRegistered }
        let taken = named { $0 == .nameTaken }
        var text = "Not registered in any agent yet."
        if !registered.isEmpty { text = "Registered in " + ListFormatter.localizedString(byJoining: registered) + "." }
        if !taken.isEmpty {
            let list = ListFormatter.localizedString(byJoining: taken)
            let verb = taken.count == 1 ? " already has" : " already have"
            text += " " + list.prefix(1).uppercased() + list.dropFirst() + verb + " another server named “next-term”, left as it is."
        }
        return text
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
        let newline = document.lineEnding
        var updated = text
        let insertion: (text: String, at: String.Index)
        if let container = root.member(target.container) {
            guard case .object(let servers) = container.value else { return Plan(.skipped("\(target.container) is not an object")) }
            if servers.hasRepeatedKeys { return Plan(.skipped("repeated keys")) }
            if let existing = servers.member(serverName) {
                // Foundation reads the first of a repeated command, the agents the last: whose entry it is cannot be told.
                if case .object(let entry) = existing.value, entry.hasRepeatedKeys { return Plan(.skipped("repeated keys")) }
                let current = Self.command(of: existing.value.object(in: text))
                guard isOurs(command: current) else { return Plan(.nameTaken) }
                if current == command { return Plan(.alreadyRegistered) }
                // Ours, from another copy of the app (moved, or a development build): only its command changes,
                // so what the user added to the entry (env, disabled) stays.
                guard let range = commandRange(of: existing.value, in: document) else { return Plan(.skipped("odd shape")) }
                updated.unicodeScalars.replaceSubrange(range, with: quote(command).unicodeScalars)
                return verified(updated, target: target, command: command, whole: false)
            }
            // Ours goes first, where taking it out gives the text back as it was (see `JSONC.insertion`). An empty {}
            // takes it on the same line, which also keeps it apart from a container registering added.
            insertion = document.insertion(into: servers, spread: false) { _ in ours }
        } else {
            // The container goes first, in the shape `unregisterJSON` looks for (for the indent of the line it starts on).
            insertion = document.insertion(into: root, spread: true) { indent in
                quote(target.container) + ": {" + newline + indent + "  " + ours + newline + indent + "}"
            }
        }
        updated.unicodeScalars.insert(contentsOf: insertion.text.unicodeScalars, at: insertion.at)
        return verified(updated, target: target, command: command, whole: true)
    }

    private static func unregisterJSON(_ target: Target, _ text: String, strict: Bool) -> Plan {
        guard let document = JSONC(text), case .object(let root)? = document.root else { return Plan(.skipped("not valid JSON")) }
        if root.hasRepeatedKeys { return Plan(.skipped("repeated keys")) }
        guard let container = root.member(target.container), case .object(let servers) = container.value else { return Plan(.removed) }
        if servers.hasRepeatedKeys { return Plan(.skipped("repeated keys")) }
        guard let existing = servers.member(serverName) else { return Plan(.removed) }
        if case .object(let entry) = existing.value, entry.hasRepeatedKeys { return Plan(.skipped("repeated keys")) }
        guard isOurs(command: command(of: existing.value.object(in: text))) else { return Plan(.nameTaken) }
        if let refused = refusal(document, strict: strict) { return Plan(.skipped(refused)) }
        // Ours alone in a container that registering added (it is in the shape registering writes): the container
        // goes too. One that was there before keeps what it had, since registering puts ours in it in another shape;
        // unless the agent has saved the file in its own format since, which can give it that shape.
        let indent = document.indent(of: container.keyRange.lowerBound)
        let line = indent + "  " + quote(serverName) + ": " + document.string(existing.value.range)
        let added = "{" + document.lineEnding + line + document.lineEnding + indent + "}"
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

    /// Where Codex keeps its servers, and ours among them.
    private static let tomlServers = ["mcp_servers"]
    private static let tomlOurs = ["mcp_servers", serverName]

    /// What Codex's file has under mcp_servers.next-term.
    enum TOMLEntry: Equatable {
        case absent
        /// One [mcp_servers.next-term] table, with its subtables (Codex adds `[mcp_servers.next-term.tools.<tool>]`
        /// on "Always allow"): `whole` runs from its header to the next table that is not one of them, less the
        /// comments just above that one; `command`, its command string, and `value`, what that says.
        case table(whole: Range<String.Index>, command: Range<String.Index>, value: String)
        /// Written some other way (dotted keys, inline, as an array), or without a command string: not Next Term's
        /// to change. Codex refuses its whole file over a second definition, so ours is never added beside it.
        case other
    }

    static func tomlEntry(_ outline: TOMLOutline) -> TOMLEntry {
        func isUnder(_ path: [String]) -> Bool { path.starts(with: tomlOurs) }
        let headers = outline.headers.filter { isUnder($0.path) }
        let keys = outline.keys.filter { isUnder($0.table + $0.path) }
        guard !headers.isEmpty || !keys.isEmpty else { return .absent }
        let own = headers.filter { $0.path == tomlOurs }
        guard own.count == 1, let header = own.first, headers.allSatisfy({ !$0.isArray }),
              keys.allSatisfy({ isUnder($0.table) }) else { return .other }
        let commands = keys.filter { $0.table == tomlOurs && $0.path == ["command"] }
        guard commands.count == 1, let command = outline.string(at: commands[0].value) else { return .other }
        // The table and its subtables, in one run.
        var end = outline.text.endIndex
        if let next = outline.headers.first(where: { $0.line.lowerBound > header.line.lowerBound && !isUnder($0.path) }) {
            end = outline.commentsAbove(next.line.lowerBound)
        }
        guard headers.allSatisfy({ $0.line.lowerBound < end }) else { return .other }
        return .table(whole: header.line.lowerBound..<end, command: command.range, value: command.value)
    }

    /// mcp_servers written inline (`mcp_servers = { … }`) or as an array of tables: a table of ours cannot go beside it.
    static func tomlServersAreNotATable(_ outline: TOMLOutline) -> Bool {
        outline.keys.contains { $0.table + $0.path == tomlServers } || outline.headers.contains { $0.isArray && $0.path.starts(with: tomlServers) }
    }

    private static func registerTOML(_ text: String, command: String) -> Plan {
        guard let outline = TOMLOutline(text) else { return Plan(.skipped("not valid TOML")) }
        if tomlServersAreNotATable(outline) { return Plan(.skipped("mcp_servers is not a table of its own")) }
        var updated = text
        switch tomlEntry(outline) {
        case .other:
            return Plan(.nameTaken)
        case .table(_, let range, let current):
            guard isOurs(command: current) else { return Plan(.nameTaken) }
            if current == command { return Plan(.alreadyRegistered) }
            // Ours, from another copy of the app: only the command's string changes (its line's indent and comment stay).
            updated.unicodeScalars.replaceSubrange(range, with: tomlString(command).unicodeScalars)
        case .absent:
            // At the end, set apart by a blank line, ending as the file did (with a line break or not), so taking it
            // out gives the file back as it was.
            let newline = text.contains("\r\n") ? "\r\n" : "\n"
            let ending = text.isEmpty || text.hasSuffix(newline) ? newline : ""
            let table = "[mcp_servers.next-term]" + newline + "command = " + tomlString(command) + newline + "args = [\"mcp\"]" + ending
            let separator = text.isEmpty ? "" : text.hasSuffix(newline) ? newline : newline + newline
            updated = text + separator + table
        }
        // The result read back: one table of ours, with this command.
        guard let check = TOMLOutline(updated), !tomlServersAreNotATable(check),
              case .table(_, _, let written) = tomlEntry(check), written == command else { return Plan(.skipped("check failed")) }
        return Plan(.registered, text: updated)
    }

    private static func unregisterTOML(_ text: String) -> Plan {
        guard let outline = TOMLOutline(text) else { return Plan(text.contains(serverName) ? .skipped("not valid TOML") : .removed) }
        guard case .table(let whole, _, let current) = tomlEntry(outline) else {
            if tomlEntry(outline) == .other { return Plan(.nameTaken) }
            let inline = tomlServersAreNotATable(outline) && text.contains(serverName)
            return Plan(inline ? .skipped("mcp_servers is not a table of its own") : .removed)
        }
        guard isOurs(command: current) else { return Plan(.nameTaken) }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var before = String(text.unicodeScalars[..<whole.lowerBound])
        let after = String(text.unicodeScalars[whole.upperBound...])
        // Last in the file: the blank line that set it apart goes with it, and the file ends as our table did.
        if after.isEmpty, text.unicodeScalars[whole].last == "\n" {
            if before.hasSuffix(newline + newline) { before.removeLast() }
        } else if after.isEmpty {
            while before.hasSuffix(newline) { before.removeLast() }
        }
        var updated = before + after
        let three = newline + newline + newline
        if !text.contains(three) { while updated.contains(three) { updated = updated.replacingOccurrences(of: three, with: newline + newline) } }
        guard let check = TOMLOutline(updated), tomlEntry(check) == .absent else { return Plan(.skipped("check failed")) }
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

    private func isBlank(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\r" }

    /// The file's line break: "\r\n" when it has one, so lines added match the others.
    var lineEnding: String { text.contains("\r\n") ? "\r\n" : "\n" }

    /// Just past a comment that starts at `index`, if one does (`//` up to its line break, `/* */` to its end).
    private func commentEnd(at index: String.Index) -> String.Index? {
        let next = scalars.index(after: index)
        guard scalars[index] == "/", next < scalars.endIndex else { return nil }
        if scalars[next] == "/" {
            var end = next
            while end < scalars.endIndex, scalars[end] != "\n" { end = scalars.index(after: end) }
            return end
        }
        guard scalars[next] == "*" else { return nil }
        return text.range(of: "*/", options: .literal, range: scalars.index(after: next)..<scalars.endIndex)?.upperBound
    }

    /// The start of the next line, when only blanks and comments follow `index` on its line (nil: something else
    /// does, or the text ends).
    func lineAfter(_ index: String.Index) -> String.Index? {
        var i = scalars.index(after: index)
        while i < scalars.endIndex {
            if scalars[i] == "\n" { return scalars.index(after: i) }
            if isBlank(scalars[i]) {
                i = scalars.index(after: i)
            } else if let end = commentEnd(at: i) {
                i = end
            } else {
                return nil
            }
        }
        return nil
    }

    /// Where a new first member goes in `object`, so that `removing` it gives this text back: on a line of its own
    /// at the start of the line after the `{` line when the members start on a later line (a comment on the `{`
    /// line, or above the first member, stays where it was), and before the first member when it is on the `{` line.
    /// In an object with only space inside, just after the `{`, the space kept after it; one with only comments
    /// gets it on the line after the `{` line. `spread`: an empty {} gets it on a line of its own, not inside the
    /// braces on their line. `member`: its text, for the indent of the line it starts on.
    func insertion(into object: Object, spread: Bool, member: (String) -> String) -> (text: String, at: String.Index) {
        let newline = lineEnding
        let afterOpen = scalars.index(after: object.open)
        if let first = object.members.first {
            let indent = indent(of: first.keyRange.lowerBound)
            if let next = lineAfter(object.open) { return (indent + member(indent) + "," + newline, next) }
            return (member(indent) + ", ", first.keyRange.lowerBound)
        }
        let inner = indent(of: object.open) + "  "
        let inside = scalars[afterOpen..<scalars.index(before: object.close)]
        if inside.isEmpty, spread { return (newline + inner + member(inner) + newline, afterOpen) }
        if !inside.allSatisfy(\.properties.isWhitespace), let next = lineAfter(object.open) {
            return (inner + member(inner) + newline, next)
        }
        return (member(indent(of: object.open)), afterOpen)
    }

    /// `member`'s line, when it has one to itself: from the line's start to just past its line break, with only blanks
    /// before the member and only blanks, a comma (`comma`: one is needed) and a comment on one line after it.
    private func ownLine(_ member: Member, comma needed: Bool) -> Range<String.Index>? {
        var start = member.keyRange.lowerBound
        while start > scalars.startIndex, isBlank(scalars[scalars.index(before: start)]) { start = scalars.index(before: start) }
        guard start == scalars.startIndex || scalars[scalars.index(before: start)] == "\n" else { return nil }
        var end = member.value.range.upperBound
        var comma = false
        while end < scalars.endIndex {
            let c = scalars[end]
            if c == "\n" { return comma || !needed ? start..<scalars.index(after: end) : nil }
            if isBlank(c) || (c == "," && !comma) {
                comma = comma || c == ","
                end = scalars.index(after: end)
            } else if let after = commentEnd(at: end), !scalars[end..<after].contains("\n") {
                end = after
            } else {
                return nil
            }
        }
        return nil
    }

    /// Where the comma after `index` is, past blanks, line breaks and comments (nil: something else comes first).
    private func comma(after index: String.Index) -> String.Index? {
        var i = index
        while i < scalars.endIndex {
            if scalars[i] == "," { return i }
            if scalars[i].properties.isWhitespace {
                i = scalars.index(after: i)
            } else if let end = commentEnd(at: i) {
                i = end
            } else {
                return nil
            }
        }
        return nil
    }

    /// The text without one member of `object`: the member and one comma, and its line when it has one to itself.
    /// What else is around it (comments above or beside it, line breaks, the space in its object) stays, so
    /// taking out a member put where `insertion` puts one gives the text back as it was.
    func removing(_ member: Member, from object: Object) -> String {
        guard let index = object.members.firstIndex(where: { $0.keyRange == member.keyRange }) else { return text }
        let key = member.keyRange.lowerBound
        let valueEnd = member.value.range.upperBound
        // Blanks before the member on its line.
        var lead = key
        while lead > scalars.startIndex, isBlank(scalars[scalars.index(before: lead)]) { lead = scalars.index(before: lead) }
        var removals: [Range<String.Index>] = []
        if index + 1 < object.members.count {
            let next = object.members[index + 1].keyRange.lowerBound
            if !scalars[valueEnd..<next].contains("\n") {
                // The next member on the same line ({"a": 1, "b": 2}): up to it.
                removals = [key..<next]
            } else if let line = ownLine(member, comma: true) {
                removals = [line]
            } else if let comma = comma(after: valueEnd) {
                removals = [lead..<scalars.index(after: comma)]
            }
        } else if index > 0 {
            // The last member: the comma before it goes (a trailing comma after it instead, when it has one).
            let before = comma(after: object.members[index - 1].value.range.upperBound)
            let trailing = comma(after: valueEnd)
            if let line = ownLine(member, comma: false) {
                removals = [line] + (before.map { [$0..<scalars.index(after: $0)] } ?? [])
            } else if let trailing {
                removals = [lead..<scalars.index(after: trailing)]
            } else if let before {
                removals = [lead..<valueEnd, before..<scalars.index(after: before)]
            }
        } else {
            let afterOpen = scalars.index(after: object.open)
            let inside = afterOpen..<scalars.index(before: object.close)
            if let line = ownLine(member, comma: false) {
                // On a line of its own: that line goes, and with only space left the object becomes {}.
                let rest = scalars[afterOpen..<line.lowerBound] + scalars[line.upperBound..<inside.upperBound]
                removals = [rest.allSatisfy(\.properties.isWhitespace) ? inside : line]
            } else {
                let trailing = comma(after: valueEnd)
                removals = [key..<(trailing.map { scalars.index(after: $0) } ?? valueEnd)]
            }
        }
        var result = text
        for range in removals.sorted(by: { $0.lowerBound > $1.lowerBound }) { result.unicodeScalars.removeSubrange(range) }
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

/// TOML read only as far as editing one table safely needs: where each table header and each key is, with its full
/// path, past strings, comments, and arrays and inline tables over several lines. Read by Unicode scalar, like `JSONC`.
/// nil for text it cannot follow (a string or bracket left open, a line that is neither a header nor a key).
struct TOMLOutline {
    struct Header {
        let path: [String]
        /// `[[…]]`.
        let isArray: Bool
        /// From the line's start to just past its line break.
        let line: Range<String.Index>
    }

    struct Key {
        /// The table it is in, and its own path (`a.b = 1` in [t]: ["t"] and ["a", "b"]).
        let table: [String]
        let path: [String]
        /// Where its value starts.
        let value: String.Index
    }

    let text: String
    private let scalars: String.UnicodeScalarView
    private(set) var headers: [Header] = []
    private(set) var keys: [Key] = []
    /// The lines that hold only a comment: where each ends (just past its line break) → where it starts.
    private var comments: [String.Index: String.Index] = [:]
    private var i: String.Index

    init?(_ text: String) {
        self.text = text
        scalars = text.unicodeScalars
        i = scalars.startIndex
        var table: [String] = []
        while i < scalars.endIndex {
            let lineStart = i
            skipBlanks()
            guard i < scalars.endIndex else { break }
            if scalars[i] == "#" {
                guard endOfLine() else { return nil }
                comments[i] = lineStart
                continue
            }
            if scalars[i] == "\r" || scalars[i] == "\n" {
                guard endOfLine() else { return nil }
                continue
            }
            if scalars[i] == "[" {
                advance()
                let isArray = i < scalars.endIndex && scalars[i] == "["
                if isArray { advance() }
                guard let path = parseKey(), take("]"), !isArray || take("]"), endOfLine() else { return nil }
                headers.append(Header(path: path, isArray: isArray, line: lineStart..<i))
                table = path
                continue
            }
            guard let path = parseKey(), take("=") else { return nil }
            skipBlanks()
            let value = i
            guard skipValue(), endOfLine() else { return nil }
            keys.append(Key(table: table, path: path, value: value))
        }
    }

    /// Where the comment lines just above `lineStart` start (`lineStart` when there are none).
    func commentsAbove(_ lineStart: String.Index) -> String.Index {
        var start = lineStart
        while let above = comments[start] { start = above }
        return start
    }

    /// The single-line string that starts at `index`: its range and what it says.
    func string(at index: String.Index) -> (range: Range<String.Index>, value: String)? {
        var cursor = self
        cursor.i = index
        guard let value = cursor.parseString(), !cursor.isMultiLine(at: index) else { return nil }
        return (index..<cursor.i, value)
    }

    /// What a bare key is made of.
    private static let bare = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".unicodeScalars)

    private mutating func advance() { i = scalars.index(after: i) }

    private func isMultiLine(at index: String.Index) -> Bool {
        let quote = scalars[index]
        return scalars[index...].prefix(3).elementsEqual([quote, quote, quote])
    }

    private mutating func skipBlanks() {
        while i < scalars.endIndex, scalars[i] == " " || scalars[i] == "\t" { advance() }
    }

    /// Past blanks, line breaks and comments (inside an array or inline table).
    private mutating func skipSpace() {
        while i < scalars.endIndex {
            if scalars[i] == "#" {
                while i < scalars.endIndex, scalars[i] != "\n" { advance() }
            } else if scalars[i].properties.isWhitespace {
                advance()
            } else {
                return
            }
        }
    }

    private mutating func take(_ c: Unicode.Scalar) -> Bool {
        skipBlanks()
        guard i < scalars.endIndex, scalars[i] == c else { return false }
        advance()
        return true
    }

    /// Past blanks, a comment and the line break (or the end of the text); false when something else is there.
    private mutating func endOfLine() -> Bool {
        skipBlanks()
        if i < scalars.endIndex, scalars[i] == "#" {
            while i < scalars.endIndex, scalars[i] != "\n", scalars[i] != "\r" { advance() }
        }
        if i < scalars.endIndex, scalars[i] == "\r" { advance() }
        guard i < scalars.endIndex else { return true }
        guard scalars[i] == "\n" else { return false }
        advance()
        return true
    }

    /// A key, dotted or not: bare words and quoted strings between dots.
    private mutating func parseKey() -> [String]? {
        var path: [String] = []
        while true {
            skipBlanks()
            guard i < scalars.endIndex else { return nil }
            if scalars[i] == "\"" || scalars[i] == "'" {
                guard !isMultiLine(at: i), let part = parseString() else { return nil }
                path.append(part)
            } else {
                var part = String.UnicodeScalarView()
                while i < scalars.endIndex, Self.bare.contains(scalars[i]) {
                    part.append(scalars[i])
                    advance()
                }
                guard !part.isEmpty else { return nil }
                path.append(String(part))
            }
            skipBlanks()
            guard i < scalars.endIndex, scalars[i] == "." else { return path }
            advance()
        }
    }

    /// A single-line string, basic ("…", with escapes) or literal ('…').
    private mutating func parseString() -> String? {
        guard i < scalars.endIndex, scalars[i] == "\"" || scalars[i] == "'" else { return nil }
        let quote = scalars[i]
        advance()
        var value = String.UnicodeScalarView()
        while i < scalars.endIndex, scalars[i] != quote {
            guard scalars[i] != "\n", scalars[i] != "\r" else { return nil }
            guard quote == "\"", scalars[i] == "\\" else {
                value.append(scalars[i])
                advance()
                continue
            }
            advance()
            guard i < scalars.endIndex else { return nil }
            let escape = scalars[i]
            advance()
            switch escape {
            case "n": value.append("\n")
            case "t": value.append("\t")
            case "r": value.append("\r")
            case "b": value.append("\u{8}")
            case "f": value.append("\u{C}")
            case "e": value.append("\u{1B}")
            case "\"", "\\": value.append(escape)
            case "u", "U":
                let digits = escape == "u" ? 4 : 8
                guard let end = scalars.index(i, offsetBy: digits, limitedBy: scalars.endIndex),
                      let code = UInt32(String(scalars[i..<end]), radix: 16), let scalar = Unicode.Scalar(code) else { return nil }
                value.append(scalar)
                i = end
            default: return nil
            }
        }
        guard i < scalars.endIndex else { return nil }
        advance()
        return String(value)
    }

    /// Past a value: a string of any kind, an array, an inline table, or a bare one (a number, a date, true).
    private mutating func skipValue() -> Bool {
        guard i < scalars.endIndex else { return false }
        let c = scalars[i]
        if c == "\"" || c == "'" {
            guard isMultiLine(at: i) else { return parseString() != nil }
            // """…""" or '''…''': up to three quotes in a row, with up to two more just before them inside.
            i = scalars.index(i, offsetBy: 3)
            while i < scalars.endIndex {
                if c == "\"", scalars[i] == "\\" {
                    advance()
                    if i < scalars.endIndex { advance() }
                    continue
                }
                if isMultiLine(at: i) {
                    i = scalars.index(i, offsetBy: 3)
                    var extra = 0
                    while extra < 2, i < scalars.endIndex, scalars[i] == c {
                        advance()
                        extra += 1
                    }
                    return true
                }
                advance()
            }
            return false
        }
        if c == "[" || c == "{" {
            let close: Unicode.Scalar = c == "[" ? "]" : "}"
            advance()
            while true {
                skipSpace()
                guard i < scalars.endIndex else { return false }
                if scalars[i] == close {
                    advance()
                    return true
                }
                if c == "{" {
                    guard parseKey() != nil, take("=") else { return false }
                    skipBlanks()
                }
                guard skipValue() else { return false }
                skipSpace()
                guard i < scalars.endIndex else { return false }
                if scalars[i] == "," {
                    advance()
                } else if scalars[i] != close {
                    return false
                }
            }
        }
        let start = i
        let ends: Set<Unicode.Scalar> = [",", "]", "}", "#", "\n", "\r"]
        while i < scalars.endIndex, !ends.contains(scalars[i]) { advance() }
        return i > start
    }
}
