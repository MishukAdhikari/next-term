import Foundation

/// What an agent session holds, as the agent's ACP messages build it: the conversation, each tool call and its status,
/// the plan, a permission request waiting for an answer, and how each turn ended. `nxtrm agent` draws it
/// (`ACPTranscript`) and reports its state to the tab. Plan 030.
public struct ACPSession: Sendable {
    /// Why a turn ended, as the agent's `stopReason` says.
    public enum StopReason: String, Sendable {
        case endTurn = "end_turn"
        case maxTokens = "max_tokens"
        case maxTurnRequests = "max_turn_requests"
        case refusal
        case cancelled

        /// The turn's closing line.
        public var words: String {
            switch self {
            case .endTurn: return "Done"
            case .maxTokens: return "Hit the token limit"
            case .maxTurnRequests: return "Hit the turn limit"
            case .refusal: return "Refused"
            case .cancelled: return "Stopped"
            }
        }
    }

    public struct ToolCall: Equatable, Sendable {
        public enum Status: String, Sendable {
            case pending, inProgress = "in_progress", completed, failed
        }

        public struct FileChange: Equatable, Sendable {
            public let path: String
            public let added: Int
            public let removed: Int
            /// A new file: the agent gave no text before.
            public let created: Bool
        }

        public let id: String
        public var title: String
        public var kind: String
        public var status: Status
        /// The text the tool call shows (its output), joined.
        public var output: String
        public var changes: [FileChange]
    }

    public struct PlanEntry: Equatable, Sendable {
        public enum Status: String, Sendable {
            case pending, inProgress = "in_progress", completed
        }

        public let content: String
        public let status: Status
    }

    /// A permission request the agent waits on.
    public struct Permission: Equatable, Sendable {
        public struct Option: Equatable, Sendable {
            public let id: String
            public let name: String
            /// allow_once, allow_always, reject_once or reject_always.
            public let kind: String
        }

        /// The agent's request id, which the answer goes back with.
        public let requestID: ACPWire.Value
        /// What the agent asks to do: its tool call's title.
        public let action: String
        /// The options offered here. Allow always is left out: a standing permission one agent could give another
        /// through the tab's keys needs the asking on the Mac that `answer_agent` gains with the app's own channel (R16).
        public let options: [Option]
        /// The option the menu's cursor is on.
        public var highlighted: Int
    }

    public enum Item: Equatable, Sendable {
        case prompt(String)
        case message(String)
        case thought(String)
        /// A tool call, by id (`tools` holds it).
        case tool(String)
        /// The plan as it stands (one per turn, updated in place).
        case plan
        /// A permission request, open while it is `pending`, and how it was answered after.
        case permission(action: String, answer: String?)
        case turnEnded(StopReason)
        /// A line of Next Term's own: an error, a note.
        case note(String)
    }

    public private(set) var items: [Item] = []
    public private(set) var tools: [String: ToolCall] = [:]
    public private(set) var plan: [PlanEntry] = []
    public private(set) var pending: Permission?
    /// A turn is running: from the prompt until the agent answers it.
    public private(set) var working = false
    /// The index in `items` where the current (or last) turn starts.
    public private(set) var turnStart = 0
    public private(set) var lastStop: StopReason?
    /// The agent's commands, for the input line's "/" (R12).
    public private(set) var commands: [String] = []
    /// The context used and its size, and the cost so far, when the agent sends them.
    public private(set) var usage: String?

    public init() {}

    /// The agent's last message of the current or last turn, whole.
    public var lastMessage: String {
        for item in items[turnStart...].reversed() {
            if case .message(let text) = item { return text }
        }
        return ""
    }

    /// The user sends a prompt: a new turn starts.
    public mutating func prompted(_ text: String) {
        turnStart = items.count
        items.append(.prompt(text))
        working = true
        lastStop = nil
    }

    /// The agent answered the prompt: the turn is over. An open permission request is gone with it.
    public mutating func turnEnded(_ raw: String?) {
        let reason = raw.flatMap(StopReason.init(rawValue:)) ?? .endTurn
        if pending != nil { answered("Cancelled") }
        working = false
        lastStop = reason
        items.append(.turnEnded(reason))
    }

    /// The prompt failed: the agent answered it with an error.
    public mutating func turnFailed(_ message: String) {
        if pending != nil { answered("Cancelled") }
        working = false
        lastStop = nil
        items.append(.note("The agent answered with an error: " + Self.oneLine(message, limit: 300)))
    }

    public mutating func note(_ text: String) {
        items.append(.note(text))
    }

    /// A `session/update` notification's params.
    public mutating func apply(update params: ACPWire.Value) {
        guard let update = params["update"], let kind = update["sessionUpdate"]?.string else { return }
        switch kind {
        case "agent_message_chunk":
            append(text: Self.text(of: update["content"]), as: .message(""))
        case "agent_thought_chunk":
            append(text: Self.text(of: update["content"]), as: .thought(""))
        case "user_message_chunk":
            // A replay (session/load) sends the user's words back; a live turn already shows them.
            if !working { append(text: Self.text(of: update["content"]), as: .prompt("")) }
        case "tool_call":
            guard let id = update["toolCallId"]?.string else { return }
            var call = ToolCall(id: id, title: "", kind: "other", status: .pending, output: "", changes: [])
            merge(update, into: &call)
            if tools[id] == nil { items.append(.tool(id)) }
            tools[id] = call
        case "tool_call_update":
            guard let id = update["toolCallId"]?.string else { return }
            if var call = tools[id] {
                merge(update, into: &call)
                tools[id] = call
            } else {
                var call = ToolCall(id: id, title: "", kind: "other", status: .pending, output: "", changes: [])
                merge(update, into: &call)
                tools[id] = call
                items.append(.tool(id))
            }
        case "plan":
            plan = (update["entries"]?.array ?? []).compactMap { entry in
                guard let content = entry["content"]?.string else { return nil }
                return PlanEntry(content: Self.oneLine(content, limit: 200),
                                 status: entry["status"]?.string.flatMap(PlanEntry.Status.init(rawValue:)) ?? .pending)
            }
            if !items[turnStart...].contains(.plan) { items.append(.plan) }
        case "available_commands_update":
            commands = (update["availableCommands"]?.array ?? []).compactMap { $0["name"]?.string }
        case "usage_update":
            usage = Self.usage(update)
        default:
            break
        }
    }

    /// `session/request_permission`: the menu opens. Nil, with nothing changed, when the agent offers no option the
    /// tab can give.
    @discardableResult
    public mutating func requested(permission id: ACPWire.Value, params: ACPWire.Value) -> Permission? {
        let call = params["toolCall"]
        if let call, let callID = call["toolCallId"]?.string {
            if var known = tools[callID] {
                merge(call, into: &known)
                tools[callID] = known
            }
        }
        let title = call?["title"]?.string ?? call?["toolCallId"]?.string.flatMap { tools[$0]?.title } ?? ""
        let options: [Permission.Option] = (params["options"]?.array ?? []).compactMap { option in
            guard let optionID = option["optionId"]?.string, let name = option["name"]?.string,
                  let kind = option["kind"]?.string, kind != "allow_always" else { return nil }
            return Permission.Option(id: optionID, name: Self.oneLine(name, limit: 60), kind: kind)
        }
        guard !options.isEmpty else { return nil }
        let action = Self.oneLine(title.isEmpty ? "act" : title, limit: 140).replacingOccurrences(of: "?", with: "")
        let permission = Permission(requestID: id, action: action, options: options, highlighted: 0)
        pending = permission
        items.append(.permission(action: action, answer: nil))
        return permission
    }

    /// Moves the menu's cursor (up is -1), round neither end.
    public mutating func moveHighlight(_ step: Int) {
        guard var permission = pending else { return }
        permission.highlighted = min(max(permission.highlighted + step, 0), permission.options.count - 1)
        pending = permission
    }

    /// Picks option `index` of the open request: the agent's request id and the option's id to answer with, or nil
    /// when there is no such option.
    public mutating func choose(_ index: Int) -> (requestID: ACPWire.Value, optionID: String)? {
        guard let permission = pending, permission.options.indices.contains(index) else { return nil }
        let option = permission.options[index]
        answered(option.name)
        return (permission.requestID, option.id)
    }

    /// The open request's id, closed as cancelled (the user stopped the turn).
    public mutating func cancelPending() -> ACPWire.Value? {
        guard let permission = pending else { return nil }
        answered("Cancelled")
        return permission.requestID
    }

    private mutating func answered(_ answer: String) {
        guard let permission = pending else { return }
        pending = nil
        if let at = items.lastIndex(of: .permission(action: permission.action, answer: nil)) {
            items[at] = .permission(action: permission.action, answer: answer)
        }
    }

    /// A chunk joins the last item when it is the same kind, else starts one.
    private mutating func append(text: String, as kind: Item) {
        guard !text.isEmpty else { return }
        if let last = items.last, items.count > turnStart {
            switch (last, kind) {
            case (.message(let before), .message):
                items[items.count - 1] = .message(before + text)
                return
            case (.thought(let before), .thought):
                items[items.count - 1] = .thought(before + text)
                return
            case (.prompt(let before), .prompt) where !working:
                items[items.count - 1] = .prompt(before + text)
                return
            default: break
            }
        }
        switch kind {
        case .message: items.append(.message(text))
        case .thought: items.append(.thought(text))
        case .prompt:
            turnStart = items.count
            items.append(.prompt(text))
        default: break
        }
    }

    private func merge(_ update: ACPWire.Value, into call: inout ToolCall) {
        if let title = update["title"]?.string { call.title = Self.oneLine(title, limit: 200) }
        if let kind = update["kind"]?.string { call.kind = kind }
        if let status = update["status"]?.string.flatMap(ToolCall.Status.init(rawValue:)) { call.status = status }
        guard let content = update["content"]?.array else { return }
        var output: [String] = []
        var changes: [ToolCall.FileChange] = []
        for block in content {
            switch block["type"]?.string {
            case "content":
                let text = Self.text(of: block["content"])
                if !text.isEmpty { output.append(text) }
            case "diff":
                guard let path = block["path"]?.string else { continue }
                let old = block["oldText"]?.string
                let new = block["newText"]?.string ?? ""
                let (added, removed) = Self.counts(old: old ?? "", new: new)
                changes.append(.init(path: path, added: added, removed: removed, created: old == nil))
            default:
                break
            }
        }
        // Content replaces what the call showed (ACP's tool_call_update sends the whole list).
        call.output = output.joined(separator: "\n")
        call.changes = changes
    }

    /// Lines added and removed from `old` to `new`.
    static func counts(old: String, new: String) -> (Int, Int) {
        let before = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let after = new.isEmpty ? [] : new.components(separatedBy: "\n")
        var added = 0, removed = 0
        for change in after.difference(from: before) {
            switch change {
            case .insert: added += 1
            case .remove: removed += 1
            }
        }
        return (added, removed)
    }

    /// A content block's text: a text block's, a resource link's name; nothing for an image or audio.
    static func text(of block: ACPWire.Value?) -> String {
        guard let block else { return "" }
        switch block["type"]?.string {
        case "text": return block["text"]?.string ?? ""
        case "resource_link": return block["name"]?.string ?? block["uri"]?.string ?? ""
        case "resource": return block["resource"]?["text"]?.string ?? ""
        default: return ""
        }
    }

    static func usage(_ update: ACPWire.Value) -> String? {
        var parts: [String] = []
        if let used = update["used"]?.int, let size = update["size"]?.int, size > 0 {
            parts.append("Context \(compact(used)) of \(compact(size))")
        }
        if let cost = update["cost"], let amount = cost["amount"].flatMap({ value -> Double? in
            if case .number(let number) = value { return number }
            return nil
        }) {
            let currency = cost["currency"]?.string ?? "USD"
            parts.append(currency == "USD" ? String(format: "$%.2f", amount) : String(format: "%.2f %@", amount, currency))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    static func compact(_ count: Int) -> String {
        count >= 1000 ? String(format: count >= 10_000 ? "%.0fk" : "%.1fk", Double(count) / 1000) : String(count)
    }

    /// One line, control characters out, at most `limit` characters.
    public static func oneLine(_ text: String, limit: Int) -> String {
        let flat = String(text.unicodeScalars.map { scalar -> Character in
            scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) ? " " : Character(scalar)
        }).trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "\u{2026}" : flat
    }
}
