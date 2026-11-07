import Foundation

/// Codex's app-server, both ways (plan 035 U3): the JSON-RPC lines `codex app-server` writes, turned into what the
/// session model already takes (ACP-shaped `session/update` params and permission requests, KTD2), and the lines Next
/// Term writes back: `initialize` and `initialized`, `thread/start`, `turn/start`, `turn/interrupt`, the answers to the
/// two approvals, and a "method not found" for every other request Codex makes.
///
/// app-server is experimental and versioned with Codex, so the translator checks shapes rather than versions (KTD4): an
/// answer missing what the session needs, or "method not found" for a method it can't do without, is `drift` with R9's
/// note, and `DriftWatch` tells a turn that hears only notifications it doesn't know.
///
/// It holds only what one line can't tell alone: the requests waiting for answers, the thread and turn, the items whose
/// text already came as deltas, the files a change touches, and whether a stop was asked for. It never takes, keeps or
/// writes a credential (R2): not being signed in is told as `authFailure`, nothing more, and Codex's own requests about
/// tokens are refused like any other.
public struct CodexAppServer: Sendable {
    /// Codex asks to run a command or change files.
    public struct Permission: Equatable, Sendable {
        /// The JSON-RPC request's id, which the answer goes back with.
        public let requestID: ACPWire.Value
        /// `item/commandExecution/requestApproval` or `item/fileChange/requestApproval`.
        public let method: String
        /// The item the approval is for.
        public let itemID: String?
        /// The request as `session/request_permission` params, for `ACPSession.requested(permission:params:)`: the whole
        /// command or every path in the title, uncut (R5), and Allow once, Allow always and Reject.
        public let params: ACPWire.Value
    }

    /// How a turn ended (`turn/completed`).
    public struct TurnEnd: Equatable, Sendable {
        /// ACP's stop reason, or nil when the turn failed.
        public let stopReason: String?
        /// What went wrong, when the turn failed.
        public let failure: String?

        public init(stopReason: String?, failure: String?) {
            self.stopReason = stopReason
            self.failure = failure
        }
    }

    public enum Event: Equatable, Sendable {
        /// `initialize` was answered: the server's user agent, kept for the drift note.
        case initialized(userAgent: String)
        /// `thread/start` was answered with the thread's id.
        case threadStarted(String)
        /// A turn started (its `turn/start` answer or `turn/started`), with the id `turn/interrupt` needs.
        case turnStarted(String)
        /// `session/update` params, in order.
        case updates([ACPWire.Value])
        case permission(Permission)
        /// A request Next Term doesn't take: answer it with `unsupportedAnswer` and say `unsupportedNote`.
        case unsupportedRequest(id: ACPWire.Value, method: String)
        /// A request Codex made was settled elsewhere (`serverRequest/resolved`): its menu closes.
        case resolved(ACPWire.Value)
        case turnEnded(TurnEnd)
        /// Codex isn't signed in: say `signInLine`.
        case authFailure
        /// The protocol isn't what the session needs: end it with this note.
        case drift(String)
        /// A notification of a method Next Term doesn't know: ignored, and counted by `DriftWatch`.
        case unknownNotification(String)
        /// One of Next Term's requests (other than a turn's start) was answered with an error.
        case requestFailed(method: String, message: String)
        /// `thread/resume` isn't offered, or failed: the session starts a fresh thread, with a note (plan 035 U7).
        case resumeFailed(String)
        case ignore
    }

    /// What a session says when Codex isn't signed in (R2). Next Term never offers a login of its own.
    public static let signInLine = "Run codex login in a tab to sign in, then start the session again"

    /// The start of every drift note (R9).
    public static let driftLead = "Codex's app-server changed; run codex in a terminal tab for now."

    /// Option ids of a permission's menu.
    public static let allowOnce = "allow_once"
    public static let allowAlways = "allow_always"
    public static let rejectOnce = "reject_once"

    /// The methods the session can't do without: "method not found" for one of them is drift (KTD4).
    static let required: Set<String> = ["initialize", "thread/start", "turn/start", "turn/interrupt"]

    /// Notifications Codex sends today that the transcript doesn't show. They are known, so they aren't counted.
    static let knownQuiet: Set<String> = [
        "thread/started", "thread/status/changed", "thread/readState/changed", "thread/name/updated",
        "thread/settings/updated", "thread/compacted", "thread/closed", "thread/archived", "thread/unarchived",
        "thread/goal/updated", "thread/goal/cleared", "thread/queue/changed", "thread/environment/connected",
        "thread/environment/disconnected", "turn/diff/updated", "turn/moderationMetadata",
        "item/commandExecution/outputDelta", "item/commandExecution/terminalInteraction",
        "item/fileChange/outputDelta", "item/fileChange/patchUpdated", "item/mcpToolCall/progress",
        "item/reasoning/summaryPartAdded", "item/plan/delta", "item/autoApprovalReview/started",
        "item/autoApprovalReview/completed", "hook/started", "hook/completed", "mcpServer/startupStatus/updated",
        "mcpServer/oauthLogin/completed", "account/updated", "account/rateLimits/updated", "account/login/completed",
        "skills/changed", "app/list/updated", "model/rerouted", "model/verification", "model/safetyBuffering/updated",
        "modelProvider/authRecoveryStarted", "modelProvider/authRecoveryCompleted", "warning", "guardianWarning",
        "deprecationNotice", "configWarning", "fs/changed", "process/outputDelta", "process/exited",
    ]

    /// The server's user agent, from `initialize`.
    public private(set) var userAgent: String?
    /// The thread `thread/start` or `thread/resume` gave.
    public private(set) var threadID: String?
    /// The model the thread's start or resume named.
    public private(set) var model: String?
    /// The turn running now, if any.
    public private(set) var turnID: String?

    /// Next Term's requests waiting for answers, by id: their methods.
    private var pending: [Int: String] = [:]
    private var nextID = 0
    /// Messages and reasoning whose text came as deltas: their completed items aren't shown again.
    private var streamed: Set<String> = []
    /// The paths each file change touches, for its approval's title.
    private var changePaths: [String: [String]] = [:]
    /// A stop was asked for in this turn: an interrupted or failed end says Stopped.
    private var interrupting = false
    /// An authentication error was told: the turn's failed end is the same failure.
    private var authFailed = false

    public init() {}

    // MARK: Lines to Codex

    /// `initialize`, with Next Term as the client and no experimental API.
    public mutating func initializeRequest(version: String) -> (id: Int, line: Data) {
        let info = ACPWire.Value.object([
            "name": .string("Next Term"), "title": .string("Next Term"), "version": .string(version),
        ])
        return request("initialize", .object(["clientInfo": info]))
    }

    /// The `initialized` notification, sent once `initialize` is answered.
    public static func initializedNotification() -> Data {
        ACPWire.notification(method: "initialized", params: .object([:]))
    }

    /// `thread/start` in `cwd`, asking before acting (`approvalPolicy: on-request`, so the menu always applies) and,
    /// in a Next Term tab, with Next Term's MCP server under its own name (R11), which replaces a user entry of that name.
    public mutating func threadStartRequest(cwd: String, mcpServer: ACPWire.StdioServer?) -> (id: Int, line: Data) {
        request("thread/start", .object(Self.threadParams(cwd: cwd, mcpServer: mcpServer)))
    }

    /// `thread/resume` of thread `threadID` (a session restored after an update, plan 035 U7), with what `thread/start`
    /// sends, its past turns left out of the answer: the transcript starts from the resume.
    public mutating func threadResumeRequest(threadID: String, cwd: String, mcpServer: ACPWire.StdioServer?) -> (id: Int, line: Data) {
        var params = Self.threadParams(cwd: cwd, mcpServer: mcpServer)
        params["threadId"] = .string(threadID)
        params["excludeTurns"] = .bool(true)
        return request("thread/resume", .object(params))
    }

    private static func threadParams(cwd: String, mcpServer: ACPWire.StdioServer?) -> [String: ACPWire.Value] {
        var params: [String: ACPWire.Value] = ["cwd": .string(cwd), "approvalPolicy": .string("on-request")]
        if let mcpServer {
            let entry = ACPWire.Value.object([
                "command": .string(mcpServer.command),
                "args": .array(mcpServer.arguments.map(ACPWire.Value.string)),
            ])
            params["config"] = .object(["mcp_servers": .object([mcpServer.name: entry])])
        }
        return params
    }

    /// `turn/start`: the user's text as one input. A new turn starts, not stopped.
    public mutating func turnStartRequest(threadID: String, text: String) -> (id: Int, line: Data) {
        interrupting = false
        let input = ACPWire.Value.object(["type": .string("text"), "text": .string(text)])
        return request("turn/start", .object(["threadId": .string(threadID), "input": .array([input])]))
    }

    /// `turn/interrupt`: stops the turn; its `turn/completed` then says interrupted.
    public mutating func interruptRequest(threadID: String, turnID: String) -> (id: Int, line: Data) {
        interrupting = true
        return request("turn/interrupt", .object(["threadId": .string(threadID), "turnId": .string(turnID)]))
    }

    /// `account/read`, to tell a missing login before the first turn. It asks for no token refresh, and only whether an
    /// account is there is read from its answer.
    public mutating func accountReadRequest() -> (id: Int, line: Data) {
        request("account/read", .object([:]))
    }

    /// The decision Codex takes for the menu's option `optionID`: accept, acceptForSession (Allow always, for this
    /// session only, KTD6), or decline. Nil (the turn stopped, the tab closed) cancels: nothing is ever accepted by default.
    public static func decision(for optionID: String?) -> String {
        switch optionID {
        case allowOnce?: return "accept"
        case allowAlways?: return "acceptForSession"
        case rejectOnce?: return "decline"
        default: return "cancel"
        }
    }

    /// The answer to an approval for the menu's option `optionID`.
    public static func response(to permission: Permission, optionID: String?) -> Data {
        let decision = ACPWire.Value.string(decision(for: optionID))
        return ACPWire.result(id: permission.requestID, .object(["decision": decision]))
    }

    /// JSON-RPC's "method not found" (-32601) for a request Next Term doesn't take, so Codex never waits on it.
    public static func unsupportedAnswer(id: ACPWire.Value, method: String) -> Data {
        ACPWire.error(id: id, code: -32601, message: "Next Term's session doesn't handle " + method)
    }

    /// The transcript's note for a request answered with `unsupportedAnswer`.
    public static func unsupportedNote(_ method: String) -> String {
        "Codex asked for " + method + ", which this session doesn't handle; it was declined. Run codex in a terminal tab for that."
    }

    /// R9's note, with what didn't match and the server's user agent when they are known.
    public static func driftNote(userAgent: String?, detail: String?) -> String {
        let parts = [detail, userAgent].compactMap { $0 }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return driftLead }
        return driftLead + " (" + parts.joined(separator: "; ") + ")"
    }

    // MARK: Lines from Codex

    /// One line of Codex's stdout. Anything that isn't a JSON-RPC message is `ignore`.
    public mutating func decode(_ line: some DataProtocol) -> Event {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(line), options: [.fragmentsAllowed]),
              let value = ACPWire.Value(serialized: parsed), case .object(let fields) = value else { return .ignore }
        let id = fields["id"].flatMap { $0 == .null ? nil : $0 }
        if let method = fields["method"]?.string {
            let params = fields["params"] ?? .null
            if let id { return request(id: id, method: method, params: params) }
            return notification(method, params)
        }
        guard let number = id?.int, let method = pending.removeValue(forKey: number) else { return .ignore }
        if let error = fields["error"] {
            let message = error["message"]?.string ?? "an error"
            return failed(method, code: error["code"]?.int, message: message)
        }
        return answered(method, fields["result"] ?? .null)
    }

    private mutating func answered(_ method: String, _ result: ACPWire.Value) -> Event {
        switch method {
        case "initialize":
            guard let agent = result["userAgent"]?.string, !agent.isEmpty else {
                return drift("initialize gave no userAgent")
            }
            userAgent = agent
            return .initialized(userAgent: agent)
        case "thread/start":
            guard let id = result["thread"]?["id"]?.string, !id.isEmpty else {
                return drift("thread/start gave no thread id")
            }
            threadID = id
            model = result["model"]?.string
            return .threadStarted(id)
        case "thread/resume":
            guard let id = result["thread"]?["id"]?.string, !id.isEmpty else { return .resumeFailed("it gave no thread id") }
            threadID = id
            model = result["model"]?.string
            return .threadStarted(id)
        case "turn/start":
            // turn/started names the turn too, so an answer without it isn't drift on its own.
            guard let id = result["turn"]?["id"]?.string, !id.isEmpty else { return .ignore }
            return started(id)
        case "account/read":
            let noAccount: Bool = result["account"] == nil || result["account"] == .null
            let needsOne: Bool = result["requiresOpenaiAuth"]?.bool == true
            return noAccount && needsOne ? .authFailure : .ignore
        default:
            return .ignore
        }
    }

    private mutating func failed(_ method: String, code: Int?, message: String) -> Event {
        if method == "thread/resume" {
            if code == -32601 { return .resumeFailed("it isn't offered") }
            return Self.isAuthentication(message) ? .authFailure : .resumeFailed(message)
        }
        if code == -32601 {
            return Self.required.contains(method) ? drift(method + " is not offered") : .ignore
        }
        if Self.isAuthentication(message) { return .authFailure }
        switch method {
        case "turn/start":
            return .turnEnded(TurnEnd(stopReason: nil, failure: message))
        case "account/read":
            return .ignore
        default:
            return .requestFailed(method: method, message: message)
        }
    }

    private mutating func request(id: ACPWire.Value, method: String, params: ACPWire.Value) -> Event {
        switch method {
        case "item/commandExecution/requestApproval":
            let item = params["itemId"]?.string
            let command = params["command"]?.string ?? ""
            let reason = params["reason"]?.string ?? ""
            let title: String
            if !command.isEmpty { title = command }
            else if !reason.isEmpty { title = reason }
            else { title = "Run a command" }
            return .permission(Permission(requestID: id, method: method, itemID: item,
                                          params: Self.permissionParams(title: title, kind: "execute", item: item)))
        case "item/fileChange/requestApproval":
            let item = params["itemId"]?.string
            let paths = item.flatMap { changePaths[$0] } ?? []
            let title: String
            if !paths.isEmpty { title = Self.editTitle(paths) }
            else if let root = params["grantRoot"]?.string, !root.isEmpty { title = "Write under " + root }
            else if let reason = params["reason"]?.string, !reason.isEmpty { title = reason }
            else { title = "Change files" }
            return .permission(Permission(requestID: id, method: method, itemID: item,
                                          params: Self.permissionParams(title: title, kind: "edit", item: item)))
        default:
            return .unsupportedRequest(id: id, method: method)
        }
    }

    private mutating func notification(_ method: String, _ params: ACPWire.Value) -> Event {
        switch method {
        case "item/agentMessage/delta":
            return delta(params, kind: "agent_message_chunk")
        case "item/reasoning/textDelta", "item/reasoning/summaryTextDelta":
            return delta(params, kind: "agent_thought_chunk")
        case "item/started":
            return item(params["item"], completed: false)
        case "item/completed":
            return item(params["item"], completed: true)
        case "turn/started":
            guard let id = params["turn"]?["id"]?.string, !id.isEmpty else { return .ignore }
            return started(id)
        case "turn/completed":
            return turnCompleted(params["turn"])
        case "turn/plan/updated":
            return .updates([Self.plan(params["plan"])])
        case "thread/tokenUsage/updated":
            return Self.usage(params["tokenUsage"]).map { .updates([$0]) } ?? .ignore
        case "serverRequest/resolved":
            return params["requestId"].map(Event.resolved) ?? .ignore
        case "error":
            // A retried error is passing; a final one ends the turn, which turn/completed tells.
            guard params["willRetry"]?.bool != true, Self.isAuthentication(params["error"]) else { return .ignore }
            authFailed = true
            return .authFailure
        default:
            return Self.knownQuiet.contains(method) ? .ignore : .unknownNotification(method)
        }
    }

    private mutating func started(_ id: String) -> Event {
        guard id != turnID else { return .ignore }
        turnID = id
        return .turnStarted(id)
    }

    private mutating func delta(_ params: ACPWire.Value, kind: String) -> Event {
        guard let text = params["delta"]?.string, !text.isEmpty else { return .ignore }
        if let item = params["itemId"]?.string { streamed.insert(item) }
        return .updates([Self.chunk(kind, text)])
    }

    private mutating func turnCompleted(_ turn: ACPWire.Value?) -> Event {
        let status = turn?["status"]?.string ?? ""
        let stopped = interrupting
        interrupting = false
        turnID = nil
        streamed.removeAll()
        changePaths.removeAll()
        let error = turn?["error"]
        if authFailed {
            authFailed = false
            if status == "failed" { return .ignore }
        }
        switch status {
        case "completed":
            return .turnEnded(TurnEnd(stopReason: "end_turn", failure: nil))
        case "interrupted":
            return .turnEnded(TurnEnd(stopReason: "cancelled", failure: nil))
        default:
            if stopped { return .turnEnded(TurnEnd(stopReason: "cancelled", failure: nil)) }
            if Self.isAuthentication(error) { return .authFailure }
            let message = error?["message"]?.string ?? ""
            guard message.isEmpty else { return .turnEnded(TurnEnd(stopReason: nil, failure: message)) }
            let what = status.isEmpty ? "an error" : status
            return .turnEnded(TurnEnd(stopReason: nil, failure: "Codex ended the turn with " + what))
        }
    }

    /// An `item/started` or `item/completed` as the transcript's update.
    private mutating func item(_ item: ACPWire.Value?, completed: Bool) -> Event {
        guard let item, let id = item["id"]?.string, let type = item["type"]?.string else { return .ignore }
        switch type {
        case "agentMessage":
            guard completed, !streamed.contains(id), let text = item["text"]?.string, !text.isEmpty else { return .ignore }
            return .updates([Self.chunk("agent_message_chunk", text)])
        case "reasoning":
            guard completed, !streamed.contains(id) else { return .ignore }
            let summary = (item["summary"]?.array ?? []).compactMap(\.string)
            let content = (item["content"]?.array ?? []).compactMap(\.string)
            let text = (summary.isEmpty ? content : summary).joined(separator: "\n")
            return text.isEmpty ? .ignore : .updates([Self.chunk("agent_thought_chunk", text)])
        case "commandExecution":
            let title = item["command"]?.string ?? "Run a command"
            var output: String?
            if completed { output = item["aggregatedOutput"]?.string }
            return .updates([Self.toolUpdate(id: id, title: title, kind: "execute", item: item, completed: completed,
                                             content: Self.textContent(output))])
        case "fileChange":
            let changes = item["changes"]?.array ?? []
            let paths = changes.compactMap { $0["path"]?.string }
            if !paths.isEmpty { changePaths[id] = paths }
            let title = paths.isEmpty ? "Change files" : Self.editTitle(paths)
            let diffs = changes.compactMap(Self.diff)
            return .updates([Self.toolUpdate(id: id, title: title, kind: "edit", item: item, completed: completed,
                                             content: diffs)])
        case "mcpToolCall":
            let server = item["server"]?.string ?? ""
            let tool = item["tool"]?.string ?? "a tool"
            let title = server.isEmpty ? tool : server + ": " + tool
            var output: String?
            if completed {
                output = item["error"]?["message"]?.string ?? Self.resultText(item["result"]?["content"])
            }
            return .updates([Self.toolUpdate(id: id, title: title, kind: "other", item: item, completed: completed,
                                             content: Self.textContent(output))])
        case "webSearch":
            let query = item["query"]?.string ?? ""
            let title = query.isEmpty ? "Search the web" : "Search: " + query
            return .updates([Self.toolUpdate(id: id, title: title, kind: "fetch", item: item, completed: completed,
                                             content: [])])
        default:
            return .ignore
        }
    }

    // MARK: Helpers

    private mutating func request(_ method: String, _ params: ACPWire.Value) -> (id: Int, line: Data) {
        nextID += 1
        pending[nextID] = method
        return (nextID, ACPWire.request(id: nextID, method: method, params: params))
    }

    private func drift(_ detail: String) -> Event {
        .drift(Self.driftNote(userAgent: userAgent, detail: detail))
    }

    private static func permissionParams(title: String, kind: String, item: String?) -> ACPWire.Value {
        var call: [String: ACPWire.Value] = ["title": .string(title), "kind": .string(kind)]
        if let item { call["toolCallId"] = .string(item) }
        let options: [ACPWire.Value] = [
            option(allowOnce, "Allow once"), option(allowAlways, "Allow always"), option(rejectOnce, "Reject"),
        ]
        return .object(["toolCall": .object(call), "options": .array(options)])
    }

    private static func option(_ id: String, _ name: String) -> ACPWire.Value {
        .object(["optionId": .string(id), "name": .string(name), "kind": .string(id)])
    }

    private static func chunk(_ kind: String, _ text: String) -> ACPWire.Value {
        let content = ACPWire.Value.object(["type": .string("text"), "text": .string(text)])
        return .object(["update": .object(["sessionUpdate": .string(kind), "content": content])])
    }

    /// Every path a change touches, whole.
    static func editTitle(_ paths: [String]) -> String {
        "Edit " + paths.joined(separator: ", ")
    }

    /// A `tool_call` (started) or `tool_call_update` (completed) for an item.
    private static func toolUpdate(id: String, title: String, kind: String, item: ACPWire.Value, completed: Bool,
                                   content: [ACPWire.Value]) -> ACPWire.Value {
        var update: [String: ACPWire.Value] = [
            "sessionUpdate": .string(completed ? "tool_call_update" : "tool_call"),
            "toolCallId": .string(id),
            "title": .string(title),
            "kind": .string(kind),
            "status": .string(status(item["status"]?.string, completed: completed)),
        ]
        if !content.isEmpty { update["content"] = .array(content) }
        return .object(["update": .object(update)])
    }

    /// ACP's tool status for Codex's item status: a declined command or change ends failed.
    static func status(_ raw: String?, completed: Bool) -> String {
        switch raw {
        case "inProgress"?: return "in_progress"
        case "completed"?: return "completed"
        case "failed"?, "declined"?: return "failed"
        default: return completed ? "completed" : "in_progress"
        }
    }

    private static func textContent(_ output: String?) -> [ACPWire.Value] {
        guard let output, !output.isEmpty else { return [] }
        let text = ACPWire.Value.object(["type": .string("text"), "text": .string(String(output.prefix(4000)))])
        return [.object(["type": .string("content"), "content": text])]
    }

    /// An MCP result's text blocks, joined.
    static func resultText(_ content: ACPWire.Value?) -> String {
        let texts = (content?.array ?? []).compactMap { block -> String? in
            block["type"]?.string == "text" ? block["text"]?.string : nil
        }
        return texts.joined(separator: "\n")
    }

    /// A file change as ACP diff content, when it gives its diff: an added file's text is all new, a deleted one's all
    /// gone, and an update's unified diff is read back into the text before and after its hunks, so the counts match.
    static func diff(_ change: ACPWire.Value) -> ACPWire.Value? {
        guard let path = change["path"]?.string, let diff = change["diff"]?.string, !diff.isEmpty else { return nil }
        var fields: [String: ACPWire.Value] = ["type": .string("diff"), "path": .string(path)]
        switch change["kind"]?["type"]?.string {
        case "add"?:
            fields["newText"] = .string(diff)
        case "delete"?:
            fields["oldText"] = .string(diff)
            fields["newText"] = .string("")
        default:
            let (old, new) = sides(of: diff)
            fields["oldText"] = .string(old)
            fields["newText"] = .string(new)
        }
        return .object(fields)
    }

    /// The text before and after a unified diff's hunks: context lines on both sides, "-" lines before, "+" after.
    static func sides(of diff: String) -> (String, String) {
        var old: [Substring] = []
        var new: [Substring] = []
        var inHunk = false
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                inHunk = true
                continue
            }
            guard inHunk else { continue }
            if line.hasPrefix("+") { new.append(line.dropFirst()) }
            else if line.hasPrefix("-") { old.append(line.dropFirst()) }
            else if line.hasPrefix(" ") {
                old.append(line.dropFirst())
                new.append(line.dropFirst())
            }
        }
        return (old.joined(separator: "\n"), new.joined(separator: "\n"))
    }

    /// `turn/plan/updated`'s steps as a `plan` update.
    static func plan(_ steps: ACPWire.Value?) -> ACPWire.Value {
        let entries: [ACPWire.Value] = (steps?.array ?? []).compactMap { step in
            guard let content = step["step"]?.string else { return nil }
            let status: String
            switch step["status"]?.string {
            case "inProgress"?: status = "in_progress"
            case "completed"?: status = "completed"
            default: status = "pending"
            }
            return .object(["content": .string(content), "status": .string(status), "priority": .string("medium")])
        }
        return .object(["update": .object(["sessionUpdate": .string("plan"), "entries": .array(entries)])])
    }

    /// `thread/tokenUsage/updated` as a `usage_update`: the context the last request used, of the model's window.
    static func usage(_ tokenUsage: ACPWire.Value?) -> ACPWire.Value? {
        guard let used = tokenUsage?["last"]?["totalTokens"]?.int,
              let size = tokenUsage?["modelContextWindow"]?.int, size > 0 else { return nil }
        let update: [String: ACPWire.Value] = [
            "sessionUpdate": .string("usage_update"),
            "used": .number(Double(used)),
            "size": .number(Double(size)),
        ]
        return .object(["update": .object(update)])
    }

    /// A turn error that says Codex isn't signed in: its `codexErrorInfo`, or its words.
    static func isAuthentication(_ error: ACPWire.Value?) -> Bool {
        guard let error else { return false }
        if error["codexErrorInfo"]?.string == "unauthorized" { return true }
        return isAuthentication(error["message"]?.string ?? "")
    }

    /// Codex's words for not being signed in.
    static func isAuthentication(_ text: String) -> Bool {
        let lower = text.lowercased()
        let signs = ["not logged in", "codex login", "401 unauthorized", "please log in", "authentication required"]
        return signs.contains { lower.contains($0) }
    }

    // MARK: Drift over time

    /// Tells a turn that hears only notifications it doesn't know (`ProtocolDriftWatch`, shared with Claude Code's).
    public typealias DriftWatch = ProtocolDriftWatch
}
