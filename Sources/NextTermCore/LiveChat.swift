import Foundation

/// A live chat of an agent's terminal session (plan 041): the items the agent writes to its own transcript as it runs,
/// read again from where the last read ended. Claude Code's transcript, Codex's rollout and Command Code's session file
/// are each read here. The reading is lenient: a record of a type it does not know becomes `unknown`, a record it knows
/// to be the agent's own bookkeeping is left out, and a line not yet whole waits for the rest. Every text shown is passed
/// through `MCPRedaction` first, so a key pasted into a session is masked in the chat as it is in read_file.
public enum LiveChat {
    /// The agents whose sessions are read for a live chat. Others have none, and their tabs offer no chat view.
    public enum Agent: String, Sendable, CaseIterable {
        case claude, codex, commandCode

        public init?(_ kind: AgentKind) {
            switch kind {
            case .claude: self = .claude
            case .codex: self = .codex
            case .commandCode: self = .commandCode
            default: return nil
            }
        }
    }

    /// A file's change, as lines that begin with "+", "-" or " ".
    public struct Diff: Equatable, Sendable {
        public var path: String
        public var lines: [String]

        public init(path: String, lines: [String]) {
            self.path = path
            self.lines = lines
        }

        public var added: Int { lines.filter { $0.hasPrefix("+") }.count }
        public var removed: Int { lines.filter { $0.hasPrefix("-") }.count }
    }

    /// One step of a plan or to-do list the agent keeps.
    public struct PlanStep: Equatable, Sendable {
        public enum Status: String, Equatable, Sendable { case pending, active, done }
        public var text: String
        public var status: Status

        public init(text: String, status: Status) {
            self.text = text
            self.status = status
        }
    }

    /// A tool the agent called: its name, one line saying what on (a command, a file, a pattern), and a change or a plan
    /// when it made one.
    public struct ToolCall: Equatable, Sendable {
        public var id: String?
        public var name: String
        public var summary: String
        public var diff: Diff?
        public var plan: [PlanStep]?

        public init(id: String?, name: String, summary: String, diff: Diff? = nil, plan: [PlanStep]? = nil) {
            self.id = id
            self.name = name
            self.summary = summary
            self.diff = diff
            self.plan = plan
        }
    }

    public enum Kind: Equatable, Sendable {
        /// What the user typed.
        case user(String)
        /// The agent's words.
        case text(String)
        /// Its reasoning, shown folded.
        case thinking(String)
        case tool(ToolCall)
        /// A tool's answer, for the call with this id.
        case result(callID: String?, output: String, isError: Bool)
        /// The agent compacted its context here.
        case compacted
        /// A turn ended, with how long it took when the agent says.
        case turnEnd(durationMs: Int?)
        case error(String)
        /// A record of a type not known here, by its type.
        case unknown(String)
    }

    /// One item of the chat. Its id is where its line starts in the file and which block of the line it is, the same
    /// on every read.
    public struct Item: Equatable, Sendable {
        public let id: String
        public var kind: Kind

        public init(id: String, kind: Kind) {
            self.id = id
            self.kind = kind
        }
    }

    /// A tool's output is cut to this many characters before it is masked and shown.
    public static let outputLimit = 4_000
    /// A long transcript is read from this many bytes before its end at first, not from its start.
    public static let startBytes = 1_048_576

    /// Reads one session file in steps: `feed` takes the bytes appended since the last step and gives the items they
    /// complete. A line not yet whole waits in `pending`.
    public struct Reader: Sendable {
        public let agent: Agent
        /// Where in the file the next bytes start.
        public private(set) var offset: Int
        private var pending = Data()
        /// Started inside the file: the first line may be a part of one, and is dropped.
        private var skipFirst: Bool
        private let masks: Bool

        /// `start`: the byte the reading starts at (0, or `startBytes` before a long file's end).
        public init(agent: Agent, start: Int = 0, masks: Bool = true) {
            self.agent = agent
            self.offset = start
            self.skipFirst = start > 0
            self.masks = masks
        }

        /// Where a file of `size` bytes is first read from.
        public static func start(size: Int) -> Int { max(0, size - LiveChat.startBytes) }

        /// The items in `data`, the bytes that follow `offset` in the file.
        public mutating func feed(_ data: Data) -> [Item] {
            guard !data.isEmpty else { return [] }
            let lineStart = offset - pending.count
            pending.append(data)
            offset += data.count
            var items: [Item] = []
            var start = pending.startIndex
            var position = lineStart
            while let newline = pending[start...].firstIndex(of: 0x0A) {
                let line = pending[start..<newline]
                let lineOffset = position
                position += line.count + 1
                start = pending.index(after: newline)
                if skipFirst {
                    skipFirst = false
                    continue
                }
                items += LiveChat.items(line: Data(line), at: lineOffset, agent: agent, masks: masks)
            }
            pending = Data(pending[start...])
            return items
        }
    }

    /// The items of one line: none for an empty or unreadable one (a line cut mid-write is read again only if it ends).
    public static func items(line: Data, at offset: Int, agent: Agent, masks: Bool = true) -> [Item] {
        guard !line.isEmpty, let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return [] }
        let kinds: [Kind]
        switch agent {
        case .claude: kinds = claude(record)
        case .codex: kinds = codex(record)
        case .commandCode: kinds = commandCode(record)
        }
        return kinds.enumerated().map { index, kind in
            Item(id: "\(offset)#\(index)", kind: masks ? masked(kind) : kind)
        }
    }

    // MARK: Claude Code

    /// Claude Code's bookkeeping records: never shown.
    static let claudeQuiet: Set<String> = [
        "attachment", "queue-operation", "last-prompt", "permission-mode", "mode", "atis-latch", "ai-title",
        "custom-title", "summary", "pr-link", "api-request", "api-request-blob", "api-request-shape", "session-owner",
        "file-history-snapshot", "file-history-delta", "tools-used", "cost-state", "tag", "agent-name",
    ]

    static func claude(_ record: [String: Any]) -> [Kind] {
        if record["isSidechain"] as? Bool == true { return [] }
        let type = record["type"] as? String ?? ""
        let content = (record["message"] as? [String: Any])?["content"]
        switch type {
        case "user":
            var kinds: [Kind] = []
            if let prompt = AgentSessions.claudePrompt(record) {
                kinds.append(.user(prompt))
            } else if record["isMeta"] as? Bool != true, let blocks = content as? [[String: Any]],
                      blocks.contains(where: { $0["type"] as? String == "image" }) {
                kinds.append(.user("[Image]"))
            }
            if let blocks = content as? [[String: Any]] {
                kinds += blocks.compactMap(result)
            }
            return kinds
        case "assistant":
            if record["isApiErrorMessage"] as? Bool == true {
                return [.error(blockText(content) ?? "The request failed.")]
            }
            if let text = content as? String { return text.isEmpty ? [] : [.text(text)] }
            return (content as? [[String: Any]] ?? []).compactMap(assistantBlock)
        case "system":
            switch record["subtype"] as? String {
            case "compact_boundary": return [.compacted]
            case "turn_duration": return [.turnEnd(durationMs: record["durationMs"] as? Int)]
            case "api_error": return [.error(record["content"] as? String ?? "The request failed.")]
            default: return []
            }
        default:
            return claudeQuiet.contains(type) || type.isEmpty ? [] : [.unknown(type)]
        }
    }

    /// An assistant's content block, shared by Claude Code and Command Code (both write Anthropic's blocks).
    static func assistantBlock(_ block: [String: Any]) -> Kind? {
        switch block["type"] as? String {
        case "text":
            let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : .text(text)
        case "thinking":
            let text = (block["thinking"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : .thinking(text)
        case "tool_use":
            return .tool(toolCall(id: block["id"] as? String, name: block["name"] as? String ?? "tool",
                                  input: block["input"] as? [String: Any] ?? [:]))
        default:
            return nil
        }
    }

    /// A tool_result block: its text, cut to `outputLimit`.
    static func result(_ block: [String: Any]) -> Kind? {
        guard block["type"] as? String == "tool_result" else { return nil }
        let output = blockText(block["content"]) ?? ""
        return .result(callID: block["tool_use_id"] as? String, output: cut(output), isError: block["is_error"] as? Bool == true)
    }

    /// The text of content that is a string or a list of text blocks.
    static func blockText(_ content: Any?) -> String? {
        if let string = content as? String { return string }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { $0["text"] as? String }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// A tool call from its name and input: a one-line summary from the input's usual keys, a diff for an edit or a
    /// file written, a plan for a to-do list.
    static func toolCall(id: String?, name: String, input: [String: Any]) -> ToolCall {
        let path = (input["file_path"] ?? input["path"] ?? input["notebook_path"]) as? String
        var call = ToolCall(id: id, name: name, summary: summary(input))
        if let old = (input["old_string"] ?? input["old_str"]) as? String, let new = (input["new_string"] ?? input["new_str"]) as? String {
            let removed: [String] = lines(old, "-")
            let added: [String] = lines(new, "+")
            call.diff = Diff(path: path ?? "", lines: removed + added)
        } else if let edits = input["edits"] as? [[String: Any]] {
            let all: [String] = edits.flatMap { (edit: [String: Any]) -> [String] in
                let removed: [String] = lines(edit["old_string"] as? String ?? "", "-")
                let added: [String] = lines(edit["new_string"] as? String ?? "", "+")
                return removed + added
            }
            call.diff = Diff(path: path ?? "", lines: all)
        } else if let path, let content = input["content"] as? String, ["write", "write_file", "create_file"].contains(name.lowercased()) {
            call.diff = Diff(path: path, lines: lines(content, "+"))
        }
        if let todos = (input["todos"] ?? input["plan"]) as? [[String: Any]] {
            call.plan = todos.compactMap(planStep)
        }
        return call
    }

    static func planStep(_ todo: [String: Any]) -> PlanStep? {
        guard let text = (todo["content"] ?? todo["step"] ?? todo["text"]) as? String else { return nil }
        let status: PlanStep.Status
        switch todo["status"] as? String {
        case "completed", "done": status = .done
        case "in_progress", "active": status = .active
        default: status = .pending
        }
        return PlanStep(text: text, status: status)
    }

    /// The input's first usual key, on one line: a command, a file, a pattern, an address, a description.
    static func summary(_ input: [String: Any]) -> String {
        for key in ["command", "cmd", "file_path", "path", "notebook_path", "pattern", "query", "url", "description", "skill", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty { return oneLine(value) }
            if let words = input[key] as? [String], !words.isEmpty { return oneLine(words.joined(separator: " ")) }
        }
        return ""
    }

    static func oneLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 200 ? String(trimmed.prefix(200)) + "…" : trimmed
    }

    static func lines(_ text: String, _ mark: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return text.components(separatedBy: "\n").map { mark + $0 }
    }

    static func cut(_ text: String) -> String {
        text.count > outputLimit ? String(text.prefix(outputLimit)) + "\n…" : text
    }

    // MARK: Codex

    static func codex(_ record: [String: Any]) -> [Kind] {
        let payload = record["payload"] as? [String: Any] ?? [:]
        switch record["type"] as? String {
        case "response_item":
            return codexItem(payload)
        case "event_msg":
            switch payload["type"] as? String {
            case "task_complete": return [.turnEnd(durationMs: payload["duration_ms"] as? Int)]
            case "error", "stream_error": return [.error(payload["message"] as? String ?? "The request failed.")]
            default: return []
            }
        case "compacted":
            return [.compacted]
        case "session_meta", "turn_context", "token_usage_record", "world_state":
            return []
        case let type?:
            return [.unknown(type)]
        default:
            return []
        }
    }

    static func codexItem(_ item: [String: Any]) -> [Kind] {
        switch item["type"] as? String {
        case "message":
            let text = (blockText(item["content"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            switch item["role"] as? String {
            case "user":
                if text.hasPrefix("<environment_context>") || text.hasPrefix("<user_instructions>") || text.hasPrefix("# AGENTS.md") { return [] }
                return [.user(text)]
            case "assistant":
                return [.text(text)]
            default:
                return []
            }
        case "reasoning":
            let summary = (item["summary"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            return summary.isEmpty ? [] : [.thinking(summary)]
        case "custom_tool_call":
            let name = item["name"] as? String ?? "tool"
            let input = item["input"] as? String ?? ""
            var call = ToolCall(id: item["call_id"] as? String, name: name, summary: oneLine(input))
            if name == "apply_patch" { call.diff = patch(input); call.summary = call.diff?.path ?? call.summary }
            return [.tool(call)]
        case "function_call":
            let name = item["name"] as? String ?? "tool"
            let arguments = (item["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any] ?? [:]
            return [.tool(toolCall(id: item["call_id"] as? String, name: name, input: arguments))]
        case "local_shell_call":
            let command = ((item["action"] as? [String: Any])?["command"] as? [String] ?? []).joined(separator: " ")
            return [.tool(ToolCall(id: item["call_id"] as? String, name: "shell", summary: oneLine(command)))]
        case "custom_tool_call_output", "function_call_output", "local_shell_call_output":
            let output = item["output"] as? String ?? blockText(item["output"]) ?? ""
            return [.result(callID: item["call_id"] as? String, output: cut(output), isError: false)]
        case "additional_tools":
            return []
        case let type?:
            return [.unknown(type)]
        default:
            return []
        }
    }

    /// apply_patch's text as a diff: the first file it names, and its +/- and context lines.
    static func patch(_ text: String) -> Diff? {
        var path = ""
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(prefix) {
                if path.isEmpty { path = String(line.dropFirst(prefix.count)) }
            }
            if line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix(" ") { lines.append(line) }
        }
        return path.isEmpty && lines.isEmpty ? nil : Diff(path: path, lines: lines)
    }

    // MARK: Command Code

    static func commandCode(_ record: [String: Any]) -> [Kind] {
        switch record["type"] as? String {
        case "message":
            let message = record["message"] as? [String: Any] ?? [:]
            let content = message["content"]
            switch message["role"] as? String {
            case "user":
                var kinds: [Kind] = []
                let blocks: [[String: Any]] = content as? [[String: Any]] ?? []
                let parts: [String] = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                let raw: String = parts.isEmpty ? (content as? String ?? "") : parts.joined(separator: "\n")
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { kinds.append(.user(text)) }
                kinds += (content as? [[String: Any]] ?? []).compactMap(result)
                return kinds
            case "assistant":
                if let text = content as? String { return text.isEmpty ? [] : [.text(text)] }
                return (content as? [[String: Any]] ?? []).compactMap(assistantBlock)
            default:
                return []
            }
        case "session":
            return []
        case let type?:
            return [.unknown(type)]
        default:
            return []
        }
    }

    /// The session file a Command Code tab writes: `id`'s when its line resumed one, else the newest transcript (not its
    /// checkpoints or prompts files) whose header's folder is `folder` and that was written since `since`, the time the
    /// agent started. In ~/.commandcode/projects/<project>/<id>.jsonl.
    public static func commandCodeFile(folder: String, since: Date, id: String? = nil, home: String = NSHomeDirectory()) -> String? {
        let base = (home as NSString).appendingPathComponent(".commandcode/projects")
        guard let projects = try? FileManager.default.contentsOfDirectory(atPath: base) else { return nil }
        let want = canonicalPath(folder)
        // An id that is not a plain name could lead out of the folder: it names no file.
        if let id, id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) == nil { return nil }
        var best: (path: String, date: Date)?
        for project in projects where !project.hasPrefix(".") {
            let directory = (base as NSString).appendingPathComponent(project)
            if let id {
                let path = (directory as NSString).appendingPathComponent(id + ".jsonl")
                if FileManager.default.fileExists(atPath: path) { return path }
                continue
            }
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for file in files where file.hasSuffix(".jsonl") && !file.dropLast(6).contains(".") {
                let path = (directory as NSString).appendingPathComponent(file)
                guard let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date, date >= since,
                      date > (best?.date ?? .distantPast),
                      let head = AgentSessions.readHead(path, bytes: 8192),
                      let first = head.split(separator: 0x0A, maxSplits: 1).first,
                      let header = (try? JSONSerialization.jsonObject(with: Data(first))) as? [String: Any],
                      header["type"] as? String == "session", let cwd = header["cwd"] as? String, canonicalPath(cwd) == want else { continue }
                best = (path, date)
            }
        }
        return best?.path
    }

    // MARK: Masking

    static func masked(_ kind: Kind) -> Kind {
        func m(_ text: String) -> String { MCPRedaction.redact(text).text }
        switch kind {
        case .user(let text): return .user(m(text))
        case .text(let text): return .text(m(text))
        case .thinking(let text): return .thinking(m(text))
        case .error(let text): return .error(m(text))
        case .result(let id, let output, let isError): return .result(callID: id, output: m(output), isError: isError)
        case .tool(var call):
            call.summary = m(call.summary)
            call.diff = call.diff.map { Diff(path: $0.path, lines: $0.lines.map(m)) }
            call.plan = call.plan?.map { PlanStep(text: m($0.text), status: $0.status) }
            return .tool(call)
        case .compacted, .turnEnd, .unknown: return kind
        }
    }
}
