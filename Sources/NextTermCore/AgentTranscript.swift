import Foundation

/// Peek's Conversation: an agent's last turns, read from the tail of its own transcript, found only by the session herdr
/// names for it (`agent_session`) or, for an agent tab on this Mac, the session Next Term's readers tie to it; never the
/// newest file, nor one picked by folder. For the agents whose stores Next Term already reads: Claude Code
/// (`<config>/projects/*/<id>.jsonl`, the config being `$CLAUDE_CONFIG_DIR`, else `~/.claude`) and Codex (the rollout
/// file under `~/.codex/sessions` whose name holds the id), or a `path` herdr gives under the home folder. Only the last
/// 256 KB are read. Anything else (no session, an agent it does not read, two files that match, a tail that does not
/// parse) is no conversation, with one line saying why, and Peek shows the screen. herdr has no conversation of its own
/// to give (`agent read` is the screen), so this is a thin bridge, to step aside once herdr has one.
public enum AgentTranscript {
    /// The most of a transcript read, from its end.
    public static let tailBytes = 262_144
    /// The turns shown.
    public static let shownTurns = 12

    /// The transcript formats read.
    public enum Kind: String, Equatable, Sendable {
        case claude, codex

        /// From herdr's or a tab's name for what runs ("claude", "codex").
        public init?(agent: String?) {
            switch agent?.lowercased() {
            case "claude", "claude-code", "claude code": self = .claude
            case "codex": self = .codex
            default: return nil
            }
        }
    }

    /// Where a transcript is: an agent's session id in its store, or a path herdr gave.
    public enum Locator: Equatable, Sendable {
        case claude(id: String)
        case codex(id: String)
        case path(String, kind: Kind)

        public var kind: Kind {
            switch self {
            case .claude: return .claude
            case .codex: return .codex
            case .path(_, let kind): return kind
            }
        }
    }

    /// Why there is no conversation to show; `reason` says it in a line.
    public enum Unread: Error, Equatable, Sendable {
        case noSession
        case notRead(agent: String)
        case badID
        case outsideHome
        case none
        case ambiguous
        case unparsed
        case unreachable(String)

        public var reason: String {
            switch self {
            case .noSession: return "herdr names no session for this agent."
            case .notRead(let agent): return "Next Term reads no \(agent) transcript yet."
            case .badID: return "The session herdr names is not one Next Term looks for."
            case .outsideHome: return "The transcript herdr names is outside the home folder, so it is not read."
            case .none: return "The transcript is not where the session points."
            case .ambiguous: return "More than one transcript matches the session, so none is read."
            case .unparsed: return "The transcript's end does not read as a conversation."
            case .unreachable(let why): return why
            }
        }
    }

    /// The transcript of an agent of kind `agent` whose session is `session` (herdr's reference to it), on a machine
    /// whose home folder is `home`; nil for a host's, where the script checks that a path lies under its home.
    public static func locate(agent: String?, session: AgentSessionRef?, home: String?) -> Result<Locator, Unread> {
        let named = session?.agent.isEmpty == false ? session?.agent : agent
        guard let kind = Kind(agent: named) ?? Kind(agent: agent) else { return .failure(.notRead(agent: named ?? agent ?? "this agent's")) }
        guard let session else { return .failure(.noSession) }
        if session.kind == "path" {
            let path = session.value
            guard path.hasPrefix("/"), !path.contains("/../"), !path.hasSuffix("/..") else { return .failure(.outsideHome) }
            if let home {
                let inside = home.hasSuffix("/") ? home : home + "/"
                guard (path as NSString).standardizingPath.hasPrefix(inside) else { return .failure(.outsideHome) }
            }
            return .success(.path(path, kind: kind))
        }
        guard isID(session.value) else { return .failure(.badID) }
        return .success(kind == .claude ? .claude(id: session.value) : .codex(id: session.value))
    }

    /// The same for an agent tab on this Mac, from the session Next Term's readers tie to it.
    public static func locate(agent: AgentKind, sessionID: String?) -> Result<Locator, Unread> {
        guard let kind = Kind(agent: agent.rawValue) else { return .failure(.notRead(agent: agent.name)) }
        guard let sessionID else { return .failure(.noSession) }
        guard isID(sessionID) else { return .failure(.badID) }
        return .success(kind == .claude ? .claude(id: sessionID) : .codex(id: sessionID))
    }

    /// A session id that may stand in a file pattern: letters, digits, `.`, `_` and `-`, 128 at most, never a glob.
    static func isID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard (1...128).contains(bytes.count), bytes.first != UInt8(ascii: ".") else { return false }
        return bytes.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_")
                || byte == UInt8(ascii: "-")
        }
    }

    // MARK: finding it

    /// The files that may be it on this Mac, under `home` with `environment`'s `CLAUDE_CONFIG_DIR` and `CODEX_HOME`.
    public static func candidates(_ locator: Locator, home: String, environment: [String: String] = [:]) -> [String] {
        let manager = FileManager.default
        switch locator {
        case .path(let path, _):
            return manager.fileExists(atPath: path) ? [path] : []
        case .claude(let id):
            let config = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.claude"
            let projects = config + "/projects"
            let folders = (try? manager.contentsOfDirectory(atPath: projects)) ?? []
            return folders.sorted().map { projects + "/" + $0 + "/" + id + ".jsonl" }.filter { manager.fileExists(atPath: $0) }
        case .codex(let id):
            let base = (environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.codex") + "/sessions"
            guard let walk = manager.enumerator(atPath: base) else { return [] }
            var found: [String] = []
            while let next = walk.nextObject() as? String {
                let name = (next as NSString).lastPathComponent
                if name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"), name.contains(id) { found.append(base + "/" + next) }
            }
            return found.sorted()
        }
    }

    /// The one file it is, from `candidates`: exactly one, or why not.
    public static func only(_ candidates: [String]) -> Result<String, Unread> {
        switch candidates.count {
        case 0: return .failure(.none)
        case 1: return .success(candidates[0])
        default: return .failure(.ambiguous)
        }
    }

    /// For a host: the script that finds the file as `candidates` does there (a path herdr gave only under the host's
    /// home), then prints after RemoteShell.marker `count<TAB>n` and, for exactly one, `size<TAB>bytes` and, unless the
    /// size is still `knownSize`, `tail<TAB>` and its last `tailBytes` in base64; then `end`. Only fixed text and the
    /// checked id or quoted path go into it.
    public static func script(_ locator: Locator, knownSize: Int? = nil) -> String {
        let find: String
        switch locator {
        case .path(let path, _):
            find = "for nt_f in \(RemoteShell.quote(path)); do case $nt_f in \"$HOME\"/*) [ -f \"$nt_f\" ] && printf '%s\\n' \"$nt_f\" ;; esac; done"
        case .claude(let id):
            find = "for nt_f in \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\"/projects/*/\(id).jsonl; do [ -f \"$nt_f\" ] && printf '%s\\n' \"$nt_f\"; done"
        case .codex(let id):
            find = "find \"${CODEX_HOME:-$HOME/.codex}/sessions\" -type f -name 'rollout-*\(id)*.jsonl' 2>/dev/null"
        }
        return """
            printf '\\n%s\\n' \(RemoteShell.quote(RemoteShell.marker))
            nt_m=$(\(find) | head -n 3)
            nt_n=$(printf '%s' "$nt_m" | grep -c . 2>/dev/null)
            printf 'count\\t%s\\n' "${nt_n:-0}"
            if [ "${nt_n:-0}" -eq 1 ]; then
              nt_s=$(wc -c < "$nt_m" | tr -d ' ')
              printf 'size\\t%s\\n' "$nt_s"
              if [ "$nt_s" != \(RemoteShell.quote(knownSize.map(String.init) ?? "-")) ]; then
                printf 'tail\\t'; tail -c \(tailBytes) "$nt_m" | base64 | tr -d '\\n'; echo
              fi
            fi
            printf 'end\\n'
            """
    }

    /// The host's answer: the file's size and its tail (nil when the size was the one known), or why there is none.
    public static func answer(_ output: String) -> Result<(size: Int, tail: Data?), Unread> {
        guard let lines = RemoteShell.payload(output) else { return .failure(.unreachable("The host did not answer.")) }
        var count = 0, size = 0
        var tail: Data?
        var ended = false
        for line in lines {
            if line == "end" {
                ended = true
                break
            }
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2 else { continue }
            switch fields[0] {
            case "count": count = Int(fields[1]) ?? 0
            case "size": size = Int(fields[1]) ?? 0
            case "tail": tail = Data(base64Encoded: fields[1])
            default: break
            }
        }
        guard ended else { return .failure(.unreachable("The host's answer was cut off.")) }
        if count == 0 { return .failure(.none) }
        if count > 1 { return .failure(.ambiguous) }
        return .success((size, tail))
    }

    /// The last `tailBytes` of the file at `path` on this Mac, and its size; nil when it cannot be read.
    public static func readTail(_ path: String) -> (size: Int, tail: Data)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(tailBytes) ? end - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        return (Int(end), data)
    }

    // MARK: reading it

    /// One turn of the conversation: the user's message, or the agent's text, with how many tools it ran meanwhile.
    public struct Turn: Equatable, Sendable {
        public enum Role: Equatable, Sendable { case user, agent }
        public var role: Role
        public var text: String
        public var tools: Int

        public init(role: Role, text: String, tools: Int = 0) {
            self.role = role
            self.text = text
            self.tools = tools
        }
    }

    /// The turns in a transcript's tail: its first line is dropped (the tail may start inside it), each whole line read
    /// as `kind` writes them, the agent's lines between two user messages one turn. nil when no line reads as one of
    /// the transcript's records.
    public static func turns(tail: Data, kind: Kind) -> [Turn]? {
        var lines = String(decoding: tail, as: UTF8.self).components(separatedBy: "\n")
        guard lines.count > 1 else { return nil }
        lines.removeFirst()
        var turns: [Turn] = []
        var read = false
        for line in lines where !line.isEmpty {
            guard let data = line.data(using: .utf8), let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            read = true
            let parts = kind == .claude ? claude(record) : codex(record)
            for part in parts { add(part, to: &turns) }
        }
        return read ? turns : nil
    }

    /// One record's part: a user's message, the agent's text, or tools it ran.
    enum Part: Equatable {
        case user(String)
        case agent(String)
        case tools(Int)
    }

    private static func add(_ part: Part, to turns: inout [Turn]) {
        switch part {
        case .user(let text):
            turns.append(Turn(role: .user, text: text))
        case .agent(let text):
            if let last = turns.last, last.role == .agent, last.text.isEmpty {
                turns[turns.count - 1].text = text
            } else if let last = turns.last, last.role == .agent, last.tools == 0 {
                turns[turns.count - 1].text += "\n" + text
            } else {
                turns.append(Turn(role: .agent, text: text))
            }
        case .tools(let count):
            if turns.last?.role == .agent {
                turns[turns.count - 1].tools += count
            } else {
                turns.append(Turn(role: .agent, text: "", tools: count))
            }
        }
    }

    /// Claude Code's lines: `user` with the prompt as its picker shows it (tool results and system notes left out), and
    /// `assistant` with its text blocks, its tool calls counted.
    static func claude(_ record: [String: Any]) -> [Part] {
        if record["isSidechain"] as? Bool == true { return [] }
        let content = (record["message"] as? [String: Any])?["content"]
        switch record["type"] as? String {
        case "user":
            return AgentSessions.claudePrompt(record).map { [.user($0)] } ?? []
        case "assistant":
            guard let blocks = content as? [[String: Any]] else { return (content as? String).map { [.agent($0)] } ?? [] }
            var parts: [Part] = []
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { parts.append(.agent(text)) }
                case "tool_use":
                    parts.append(.tools(1))
                default:
                    break
                }
            }
            return parts
        default:
            return []
        }
    }

    /// Codex's rollout lines: `response_item` messages of the user and the assistant (its own context notes left out),
    /// and its tool and shell calls counted.
    static func codex(_ record: [String: Any]) -> [Part] {
        let item = (record["type"] as? String) == "response_item" ? record["payload"] as? [String: Any] : nil
        guard let item = item ?? (record["role"] != nil ? record : nil) else { return [] }
        switch item["type"] as? String {
        case "message":
            let text = AgentStoreFiles.text(item["content"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return [] }
            switch item["role"] as? String {
            case "user":
                // The context Codex adds as a user message is not the user's.
                if text.hasPrefix("<environment_context>") || text.hasPrefix("<user_instructions>") || text.hasPrefix("# AGENTS.md") { return [] }
                return [.user(text)]
            case "assistant":
                return [.agent(text)]
            default:
                return []
            }
        case "function_call", "custom_tool_call", "local_shell_call":
            return [.tools(1)]
        default:
            return []
        }
    }

    /// The last `shownTurns` turns as Peek shows them: "You:" and the agent's name before each, the tools between as
    /// "ran 6 tools", each turn's text cut to 2,000 characters, stored keys masked.
    public static func text(_ turns: [Turn], agent: String, mask: SecretMask = .current) -> String {
        let shown = turns.suffix(shownTurns).map { turn -> String in
            let words = turn.text.count > 2000 ? String(turn.text.prefix(2000)) + "…" : turn.text
            switch turn.role {
            case .user:
                return "You: " + words
            case .agent:
                let ran = turn.tools > 0 ? "  (ran \(turn.tools) tool\(turn.tools == 1 ? "" : "s"))" : ""
                return words.isEmpty ? "\(agent) ran \(turn.tools) tool\(turn.tools == 1 ? "" : "s")" : "\(agent): " + words + ran
            }
        }
        return mask.mask(shown.joined(separator: "\n\n"))
    }
}
