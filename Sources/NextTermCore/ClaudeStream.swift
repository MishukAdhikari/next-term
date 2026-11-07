import Foundation

/// Claude Code's stream-json, both ways (plan 035 U2): the lines `claude -p --input-format stream-json --output-format
/// stream-json --verbose --include-partial-messages --permission-prompt-tool stdio` writes, turned into what the session
/// model already takes (ACP-shaped `session/update` params and permission requests, KTD2), and the lines Next Term writes
/// back: a prompt, the answer to a permission or a question, and the `initialize` and `interrupt` control requests.
///
/// It holds only what one line can't tell alone: the messages whose text already came as deltas, the tool calls kept out
/// of the transcript, the context the last message used, and whether a stop was asked for. It never takes, keeps or
/// writes a credential (R2): an authentication error is told as `authFailure`, nothing more.
public struct ClaudeStream: Sendable {
    /// What `system/init` says about the session.
    public struct Init: Equatable, Sendable {
        /// The control channel's features (`interrupt_receipt_v1`, ...), which Next Term checks rather than versions.
        public let capabilities: [String]
        public let model: String?
        public let tools: [String]
        public let mcpServers: [MCPServerStatus]
        /// The slash commands, for the input line's "/".
        public let commands: [String]
        /// The session's id, which `claude --resume` takes (a restore after an update resumes it, plan 035 U7).
        public var sessionID: String? = nil
    }

    public struct MCPServerStatus: Equatable, Sendable {
        public let name: String
        public let status: String

        public init(name: String, status: String) {
            self.name = name
            self.status = status
        }
    }

    /// Claude asks to use a tool (`can_use_tool`).
    public struct Permission: Equatable, Sendable {
        /// The control request's id, which the answer goes back with.
        public let requestID: String
        public let toolName: String
        public let toolUseID: String?
        /// The tool's input, sent back unchanged with an allow.
        public let input: ACPWire.Value
        /// Claude's permission suggestions: what Allow always gives back, kept to this session.
        public let suggestions: [ACPWire.Value]
        /// The request as `session/request_permission` params, for `ACPSession.requested(permission:params:)`: the
        /// whole input in the title, uncut (R5), and Allow once, Allow always (only with suggestions) and Reject.
        public let params: ACPWire.Value
    }

    /// Claude asks the user questions (its AskUserQuestion tool): one menu each, answered together after the last.
    public struct Question: Equatable, Sendable {
        public struct Item: Equatable, Sendable {
            public let question: String
            public let header: String
            /// The options' labels, which are also their answers.
            public let options: [String]
            public let multiSelect: Bool
        }

        public let requestID: String
        public let toolUseID: String?
        public let input: ACPWire.Value
        public let items: [Item]

        /// Question `index` as `session/request_permission` params, for `ACPSession.requested(permission:params:question:)`
        /// with `question: true`: the question as the title, each option's label as its id and name.
        public func params(at index: Int) -> ACPWire.Value {
            guard items.indices.contains(index) else { return .object([:]) }
            let item = items[index]
            var call: [String: ACPWire.Value] = ["title": .string(item.question), "kind": .string("other")]
            if let toolUseID { call["toolCallId"] = .string(toolUseID) }
            let options: [ACPWire.Value] = item.options.map { label in
                .object(["optionId": .string(label), "name": .string(label), "kind": .string("allow_once")])
            }
            return .object(["toolCall": .object(call), "options": .array(options)])
        }
    }

    /// How a turn ended (`result`).
    public struct TurnEnd: Equatable, Sendable {
        /// ACP's stop reason, or nil when the turn failed.
        public let stopReason: String?
        /// What went wrong, when the turn failed.
        public let failure: String?
        /// A `usage_update` as `session/update` params, when Claude gave usage or cost.
        public let usage: ACPWire.Value?

        /// The usage line the closing line shows.
        public var usageLine: String? {
            usage?["update"].flatMap(ACPSession.usage)
        }
    }

    public enum Event: Equatable, Sendable {
        case initialized(Init)
        /// `session/update` params, in order.
        case updates([ACPWire.Value])
        case permission(Permission)
        case question(Question)
        case turnEnded(TurnEnd)
        /// The answer to one of Next Term's control requests (`initialize`, `interrupt`).
        case controlResponse(requestID: String, response: ACPWire.Value?, error: String?)
        /// Claude withdrew a control request it made (the menu it opened closes).
        case cancelRequest(String)
        /// A control request Next Term doesn't take; answer it with `controlError`.
        case unknownControl(requestID: String, subtype: String)
        /// Claude isn't signed in: say `signInLine`.
        case authFailure
        /// A JSON object of a type Next Term doesn't know (its type, or "" with none): counted by the drift watch
        /// (`ProtocolDriftWatch.observe(claude:at:)`), as Codex's unknown notifications are.
        case unknownLine(String)
        case ignore
    }

    /// The line types Claude Code writes today that aren't shown: known, so they aren't counted as drift.
    static let knownQuiet: Set<String> = [
        "keep_alive", "rate_limit_event", "tool_progress", "auth_status", "streamlined_text", "streamlined_tool_use_summary",
    ]

    /// The start of the note that ends a session whose stream isn't what Next Term reads (plan 035 U7, as R9's for Codex).
    public static let driftLead = "Claude Code's stream changed; run claude in a terminal tab for now."

    /// How long the `initialize` control request may go unanswered before the session ends with the drift note.
    public static let initializeTimeout: TimeInterval = 30

    /// The drift note, with what didn't match and the version when they are known.
    public static func driftNote(version: String?, detail: String?) -> String {
        let named: String? = version.map { "Claude Code " + $0 }
        let parts = [detail, named].compactMap { $0 }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return driftLead }
        return driftLead + " (" + parts.joined(separator: "; ") + ")"
    }

    /// What a session says when Claude Code isn't signed in (R2). Next Term never offers a login of its own.
    public static let signInLine = "Run claude in a tab to sign in, then start the session again"

    /// Messages whose text and thinking came as `stream_event` deltas: their whole `assistant` line isn't shown again.
    private var streamed: Set<String> = []
    /// The message the deltas belong to, from its `message_start`.
    private var streamingID: String?
    /// Deltas came with no `message_start` to name their message.
    private var streamedUnnamed = false
    /// TodoWrite and AskUserQuestion calls: the plan and the menu show them, so their results don't either.
    private var hidden: Set<String> = []
    /// The context the last message used, in tokens.
    private var lastContext: Int?
    /// A stop was asked for in this turn: its result says Stopped.
    private var interrupting = false
    /// An authentication error was told: the turn's result is the same failure.
    private var authFailed = false
    private var nextRequest = 0

    public init() {}

    // MARK: Lines from Claude

    /// One line of Claude's stdout. Anything that isn't a JSON object of a known type is `ignore`.
    public mutating func decode(_ line: some DataProtocol) -> Event {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(line), options: [.fragmentsAllowed]),
              let value = ACPWire.Value(serialized: parsed), case .object = value else { return .ignore }
        guard let type = value["type"]?.string else { return .unknownLine("") }
        switch type {
        case "system":
            return value["subtype"]?.string == "init" ? .initialized(Self.initInfo(value)) : .ignore
        case "stream_event":
            return streamEvent(value)
        case "assistant":
            return assistant(value)
        case "user":
            return user(value)
        case "result":
            return result(value)
        case "control_request":
            return controlRequest(value)
        case "control_response":
            guard let response = value["response"], let id = response["request_id"]?.string else { return .ignore }
            if response["subtype"]?.string == "error" {
                return .controlResponse(requestID: id, response: nil, error: response["error"]?.string ?? "an error")
            }
            return .controlResponse(requestID: id, response: response["response"] ?? .null, error: nil)
        case "control_cancel_request":
            return value["request_id"]?.string.map(Event.cancelRequest) ?? .ignore
        default:
            return Self.knownQuiet.contains(type) ? .ignore : .unknownLine(type)
        }
    }

    /// The capabilities in `system/init`, or in the `initialize` control response: a list of names, or an object whose
    /// true keys are the names.
    public static func capabilities(in value: ACPWire.Value?) -> [String] {
        guard let field = value?["capabilities"] else { return [] }
        if let names = field.array { return names.compactMap(\.string) }
        if case .object(let flags) = field { return flags.filter { $0.value.bool == true }.keys.sorted() }
        return []
    }

    private static func initInfo(_ value: ACPWire.Value) -> Init {
        let servers: [MCPServerStatus] = (value["mcp_servers"]?.array ?? []).compactMap { server in
            guard let name = server["name"]?.string else { return nil }
            return MCPServerStatus(name: name, status: server["status"]?.string ?? "")
        }
        let tools = (value["tools"]?.array ?? []).compactMap(\.string)
        let commands = (value["slash_commands"]?.array ?? []).compactMap(\.string)
        return Init(capabilities: capabilities(in: value), model: value["model"]?.string, tools: tools,
                    mcpServers: servers, commands: commands, sessionID: value["session_id"]?.string)
    }

    private mutating func streamEvent(_ value: ACPWire.Value) -> Event {
        // A subagent's words aren't the session's; its tool calls show through the assistant lines.
        guard value["parent_tool_use_id"]?.string == nil, let event = value["event"] else { return .ignore }
        switch event["type"]?.string {
        case "message_start":
            streamingID = event["message"]?["id"]?.string
            return .ignore
        case "content_block_delta":
            guard let delta = event["delta"] else { return .ignore }
            let update: ACPWire.Value
            switch delta["type"]?.string {
            case "text_delta":
                update = ACPWire.chunk("agent_message_chunk", delta["text"]?.string ?? "")
            case "thinking_delta":
                update = ACPWire.chunk("agent_thought_chunk", delta["thinking"]?.string ?? "")
            default:
                return .ignore
            }
            if let streamingID { streamed.insert(streamingID) } else { streamedUnnamed = true }
            return .updates([update])
        default:
            return .ignore
        }
    }

    private mutating func assistant(_ value: ACPWire.Value) -> Event {
        if value["error"]?.string == "authentication_failed" {
            authFailed = true
            return .authFailure
        }
        guard let message = value["message"] else { return .ignore }
        let main = value["parent_tool_use_id"]?.string == nil
        let id = message["id"]?.string
        let named = id.map { streamed.contains($0) } ?? false
        let alreadyShown: Bool = named || streamedUnnamed
        if main, let context = Self.context(message["usage"]) { lastContext = context }
        var updates: [ACPWire.Value] = []
        for block in message["content"]?.array ?? [] {
            switch block["type"]?.string {
            case "text":
                guard main, !alreadyShown, let text = block["text"]?.string else { continue }
                updates.append(ACPWire.chunk("agent_message_chunk", text))
            case "thinking":
                guard main, !alreadyShown, let text = block["thinking"]?.string else { continue }
                updates.append(ACPWire.chunk("agent_thought_chunk", text))
            case "tool_use":
                if let update = toolUse(block) { updates.append(update) }
            default:
                continue
            }
        }
        // The marks last until the turn's result: Claude writes a line per content block, all with the message's id.
        return updates.isEmpty ? .ignore : .updates(updates)
    }

    /// A `tool_use` block as a `tool_call`, or TodoWrite's list as the plan.
    private mutating func toolUse(_ block: ACPWire.Value) -> ACPWire.Value? {
        guard let id = block["id"]?.string, let name = block["name"]?.string else { return nil }
        let input = block["input"] ?? .object([:])
        if name == "TodoWrite" {
            hidden.insert(id)
            let entries: [ACPWire.Value] = (input["todos"]?.array ?? []).compactMap { todo in
                guard let content = todo["content"]?.string else { return nil }
                let status = todo["status"]?.string ?? "pending"
                return .object(["content": .string(content), "status": .string(status), "priority": .string("medium")])
            }
            return .object(["update": .object(["sessionUpdate": .string("plan"), "entries": .array(entries)])])
        }
        if name == "AskUserQuestion" {
            hidden.insert(id)
            return nil
        }
        var update: [String: ACPWire.Value] = [
            "sessionUpdate": .string("tool_call"),
            "toolCallId": .string(id),
            "title": .string(Self.title(tool: name, input: input)),
            "kind": .string(Self.kind(of: name)),
            "status": .string("in_progress"),
        ]
        let diffs = Self.diffs(tool: name, input: input)
        if !diffs.isEmpty { update["content"] = .array(diffs) }
        return .object(["update": .object(update)])
    }

    private mutating func user(_ value: ACPWire.Value) -> Event {
        guard let content = value["message"]?["content"]?.array else { return .ignore }
        var updates: [ACPWire.Value] = []
        for block in content {
            switch block["type"]?.string {
            case "tool_result":
                guard let id = block["tool_use_id"]?.string, !hidden.contains(id) else { continue }
                let failed = block["is_error"]?.bool == true
                var update: [String: ACPWire.Value] = [
                    "sessionUpdate": .string("tool_call_update"),
                    "toolCallId": .string(id),
                    "status": .string(failed ? "failed" : "completed"),
                ]
                let content = ACPWire.textContent(Self.resultText(block["content"]))
                if !content.isEmpty { update["content"] = .array(content) }
                updates.append(.object(["update": .object(update)]))
            case "text":
                // Claude's own note that a stop was asked for.
                if block["text"]?.string?.hasPrefix("[Request interrupted") == true { interrupting = true }
            default:
                continue
            }
        }
        return updates.isEmpty ? .ignore : .updates(updates)
    }

    private mutating func result(_ value: ACPWire.Value) -> Event {
        let subtype = value["subtype"]?.string ?? ""
        let isError = value["is_error"]?.bool == true
        let text = value["result"]?.string ?? ""
        let stopped = interrupting
        interrupting = false
        streamed.removeAll()
        streamingID = nil
        streamedUnnamed = false
        // A hidden call's result comes before the turn's result line, which ends the turn.
        hidden.removeAll()
        if authFailed {
            authFailed = false
            if isError { return .ignore }
        }
        if isError, Self.isAuthentication(text) { return .authFailure }
        let usage = usageUpdate(value)
        if stopped { return .turnEnded(TurnEnd(stopReason: "cancelled", failure: nil, usage: usage)) }
        if subtype == "error_max_turns" {
            return .turnEnded(TurnEnd(stopReason: "max_turn_requests", failure: nil, usage: usage))
        }
        if subtype == "success", !isError {
            return .turnEnded(TurnEnd(stopReason: "end_turn", failure: nil, usage: usage))
        }
        let errors = (value["errors"]?.array ?? []).compactMap(\.string).joined(separator: "; ")
        let failure: String
        if !errors.isEmpty { failure = errors }
        else if !text.isEmpty { failure = text }
        else { failure = "Claude Code ended the turn with " + (subtype.isEmpty ? "an error" : subtype) }
        return .turnEnded(TurnEnd(stopReason: nil, failure: failure, usage: usage))
    }

    private func controlRequest(_ value: ACPWire.Value) -> Event {
        guard let id = value["request_id"]?.string, let request = value["request"] else { return .ignore }
        let subtype = request["subtype"]?.string ?? ""
        guard subtype == "can_use_tool" else { return .unknownControl(requestID: id, subtype: subtype) }
        let tool = request["tool_name"]?.string ?? ""
        let input = request["input"] ?? .object([:])
        let toolUseID = request["tool_use_id"]?.string
        if tool == "AskUserQuestion" {
            let items: [Question.Item] = (input["questions"]?.array ?? []).compactMap { question in
                guard let words = question["question"]?.string else { return nil }
                let labels = (question["options"]?.array ?? []).compactMap { $0["label"]?.string }
                guard !labels.isEmpty else { return nil }
                return Question.Item(question: words, header: question["header"]?.string ?? "", options: labels,
                                     multiSelect: question["multiSelect"]?.bool == true)
            }
            return .question(Question(requestID: id, toolUseID: toolUseID, input: input, items: items))
        }
        let suggestions = request["permission_suggestions"]?.array ?? []
        var options: [ACPWire.Value] = [ACPWire.option(ACPWire.allowOnce, "Allow once")]
        if !suggestions.isEmpty { options.append(ACPWire.option(ACPWire.allowAlways, "Allow always")) }
        options.append(ACPWire.option(ACPWire.rejectOnce, "Reject"))
        var call: [String: ACPWire.Value] = [
            "title": .string(Self.title(tool: tool, input: input)),
            "kind": .string(Self.kind(of: tool)),
        ]
        if let toolUseID { call["toolCallId"] = .string(toolUseID) }
        let params = ACPWire.Value.object(["toolCall": .object(call), "options": .array(options)])
        return .permission(Permission(requestID: id, toolName: tool, toolUseID: toolUseID, input: input,
                                      suggestions: suggestions, params: params))
    }

    // MARK: Lines to Claude

    /// A prompt: one user message on Claude's stdin. A new turn starts, not stopped.
    public mutating func userMessage(_ text: String) -> Data {
        interrupting = false
        let message = ACPWire.Value.object(["role": .string("user"), "content": .string(text)])
        return ACPWire.line(["type": .string("user"), "session_id": .string(""), "message": message, "parent_tool_use_id": .null])
    }

    /// The `initialize` control request, which opens the control channel; the session is ready at its answer (KTD3).
    public mutating func initializeRequest() -> (id: String, line: Data) {
        controlRequest(["subtype": .string("initialize")])
    }

    /// The `interrupt` control request: stops the turn and keeps the process (a SIGINT would end `claude -p`).
    public mutating func interruptRequest() -> (id: String, line: Data) {
        interrupting = true
        return controlRequest(["subtype": .string("interrupt")])
    }

    /// The answer to a permission for the menu's option `optionID`: allow with the input unchanged, Allow always with
    /// Claude's suggestions kept to this session (KTD6), or deny. Nil (the turn stopped, the tab closed) denies: nothing
    /// is ever allowed by default.
    public static func response(to permission: Permission, optionID: String?) -> Data {
        switch optionID {
        case ACPWire.allowOnce?:
            return success(permission.requestID, ["behavior": .string("allow"), "updatedInput": permission.input])
        case ACPWire.allowAlways?:
            let kept: [ACPWire.Value] = permission.suggestions.map { suggestion in
                guard case .object(var fields) = suggestion else { return suggestion }
                // Never a rule in a settings file: Allow always lasts for this session only.
                fields["destination"] = .string("session")
                return .object(fields)
            }
            let answer: [String: ACPWire.Value] = [
                "behavior": .string("allow"),
                "updatedInput": permission.input,
                "updatedPermissions": .array(kept),
            ]
            return success(permission.requestID, answer)
        case ACPWire.rejectOnce?:
            return deny(requestID: permission.requestID, message: "The user rejected this in Next Term.")
        default:
            return deny(requestID: permission.requestID, message: "The user stopped this in Next Term.")
        }
    }

    /// Deny a request, with the message Claude reads.
    public static func deny(requestID: String, message: String) -> Data {
        success(requestID, ["behavior": .string("deny"), "message": .string(message)])
    }

    /// The answers to every question of an AskUserQuestion call, in their order, in one control response: allow, with
    /// the input and each question's answer under `answers`.
    public static func answer(_ question: Question, with labels: [String]) -> Data {
        var answers: [String: ACPWire.Value] = [:]
        for (item, label) in zip(question.items, labels) { answers[item.question] = .string(label) }
        var input: [String: ACPWire.Value] = [:]
        if case .object(let fields) = question.input { input = fields }
        input["answers"] = .object(answers)
        return success(question.requestID, ["behavior": .string("allow"), "updatedInput": .object(input)])
    }

    /// An error answering Claude's control request `requestID` (one Next Term doesn't take).
    public static func controlError(requestID: String, message: String) -> Data {
        let response = ACPWire.Value.object(["subtype": .string("error"), "request_id": .string(requestID),
                                             "error": .string(message)])
        return ACPWire.line(["type": .string("control_response"), "response": response])
    }

    // MARK: Helpers

    private mutating func controlRequest(_ request: [String: ACPWire.Value]) -> (id: String, line: Data) {
        nextRequest += 1
        let tail = UUID().uuidString.prefix(8).lowercased()
        let id = "req_\(nextRequest)_\(tail)"
        let data = ACPWire.line(["type": .string("control_request"), "request_id": .string(id), "request": .object(request)])
        return (id, data)
    }

    private static func success(_ requestID: String, _ answer: [String: ACPWire.Value]) -> Data {
        let response = ACPWire.Value.object(["subtype": .string("success"), "request_id": .string(requestID),
                                             "response": .object(answer)])
        return ACPWire.line(["type": .string("control_response"), "response": response])
    }

    /// The tool and its main input, whole: `Bash(rm -rf build)`, `Edit(/project/app.py)`.
    static func title(tool: String, input: ACPWire.Value) -> String {
        let keys = ["command", "file_path", "notebook_path", "path", "pattern", "url", "query", "description"]
        guard let main = keys.lazy.compactMap({ input[$0]?.string }).first(where: { !$0.isEmpty }) else { return tool }
        return tool + "(" + main + ")"
    }

    /// ACP's tool kind for Claude's tool.
    static func kind(of tool: String) -> String {
        switch tool {
        case "Bash", "BashOutput", "KillShell": return "execute"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "edit"
        case "Read": return "read"
        case "Glob", "Grep", "LS": return "search"
        case "WebFetch", "WebSearch": return "fetch"
        case "Task": return "think"
        default: return "other"
        }
    }

    /// The file changes an Edit, MultiEdit or Write input makes, as ACP diff content.
    static func diffs(tool: String, input: ACPWire.Value) -> [ACPWire.Value] {
        guard let path = input["file_path"]?.string else { return [] }
        func diff(_ old: String?, _ new: String) -> ACPWire.Value {
            var fields: [String: ACPWire.Value] = ["type": .string("diff"), "path": .string(path), "newText": .string(new)]
            if let old { fields["oldText"] = .string(old) }
            return .object(fields)
        }
        switch tool {
        case "Edit":
            return [diff(input["old_string"]?.string ?? "", input["new_string"]?.string ?? "")]
        case "MultiEdit":
            return (input["edits"]?.array ?? []).map { edit in
                diff(edit["old_string"]?.string ?? "", edit["new_string"]?.string ?? "")
            }
        case "Write":
            // Whether the file was there before isn't in the input: shown as created.
            return [diff(nil, input["content"]?.string ?? "")]
        default:
            return []
        }
    }

    /// A tool result's text: a string, or its text blocks joined.
    static func resultText(_ content: ACPWire.Value?) -> String {
        guard let content else { return "" }
        if let text = content.string { return text }
        let texts = (content.array ?? []).compactMap { block -> String? in
            block["type"]?.string == "text" ? block["text"]?.string : nil
        }
        return texts.joined(separator: "\n")
    }

    /// The tokens a message's `usage` puts in the context: input, both caches, and output.
    static func context(_ usage: ACPWire.Value?) -> Int? {
        guard let usage else { return nil }
        let keys = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
        let counts = keys.compactMap { usage[$0]?.int }
        guard !counts.isEmpty else { return nil }
        return counts.reduce(0, +)
    }

    /// `result`'s usage and cost as a `usage_update`: the context the last message used, the model's context window,
    /// and the cost in US dollars.
    private func usageUpdate(_ value: ACPWire.Value) -> ACPWire.Value? {
        var update: [String: ACPWire.Value] = ["sessionUpdate": .string("usage_update")]
        var windows: [Int] = []
        if case .object(let models)? = value["modelUsage"] {
            windows = models.values.compactMap { $0["contextWindow"]?.int }
        }
        if let used = lastContext ?? Self.context(value["usage"]), let size = windows.max() {
            update["used"] = .number(Double(used))
            update["size"] = .number(Double(size))
        }
        if case .number(let cost)? = value["total_cost_usd"] {
            update["cost"] = .object(["amount": .number(cost), "currency": .string("USD")])
        }
        guard update.count > 1 else { return nil }
        return .object(["update": .object(update)])
    }

    /// Claude's words for not being signed in.
    static func isAuthentication(_ text: String) -> Bool {
        let lower = text.lowercased()
        let signs = ["invalid api key", "please run /login", "not logged in", "authentication_error", "oauth token"]
        return signs.contains { lower.contains($0) }
    }
}
