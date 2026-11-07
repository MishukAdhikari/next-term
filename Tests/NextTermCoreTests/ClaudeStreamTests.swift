import Foundation
import Testing
@testable import NextTermCore

/// Claude Code's stream-json (plan 035 U2): the lines `claude -p` writes, turned into the session model's ACP-shaped
/// updates and requests, and the lines Next Term writes back. Fixture lines only; no real CLI runs.
@Suite struct ClaudeStreamTests {
    private func decode(_ stream: inout ClaudeStream, _ line: String) -> ClaudeStream.Event {
        stream.decode(Data(line.utf8))
    }

    /// The JSON object a line Next Term writes holds.
    private func object(_ data: Data) -> ACPWire.Value {
        #expect(data.last == 0x0A)
        #expect(!data.dropLast().contains(0x0A))
        let parsed = try? JSONSerialization.jsonObject(with: data)
        return parsed.flatMap { ACPWire.Value(serialized: $0) } ?? .null
    }

    /// A session built from the updates `lines` decode to.
    private func session(_ lines: [String], prompt: String = "go") -> (ACPSession, [ClaudeStream.Event]) {
        var stream = ClaudeStream()
        var session = ACPSession()
        session.prompted(prompt)
        var events: [ClaudeStream.Event] = []
        for line in lines {
            let event = decode(&stream, line)
            events.append(event)
            if case .updates(let updates) = event { updates.forEach { session.apply(update: $0) } }
            if case .turnEnded(let end) = event {
                if let usage = end.usage { session.apply(update: usage) }
                if let failure = end.failure { session.turnFailed(failure) } else { session.turnEnded(end.stopReason) }
            }
        }
        return (session, events)
    }

    // MARK: Happy path

    @Test func theInitLineGivesCapabilitiesModelToolsAndServers() {
        var stream = ClaudeStream()
        let line = #"{"type":"system","subtype":"init","cwd":"/project","session_id":"s-1","tools":["Bash","Edit","Read"],"mcp_servers":[{"name":"next-term","status":"connected"}],"model":"claude-test","permissionMode":"default","slash_commands":["compact","review"],"capabilities":["interrupt_receipt_v1"],"uuid":"u-1"}"#
        guard case .initialized(let info) = decode(&stream, line) else { Issue.record("not init"); return }
        #expect(info.capabilities.contains("interrupt_receipt_v1"))
        #expect(info.model == "claude-test")
        #expect(info.tools == ["Bash", "Edit", "Read"])
        #expect(info.mcpServers == [.init(name: "next-term", status: "connected")])
        #expect(info.commands == ["compact", "review"])
        // Capabilities given as an object's keys read the same.
        let keyed = #"{"type":"system","subtype":"init","capabilities":{"interrupt_receipt_v1":true,"old":false}}"#
        guard case .initialized(let other) = decode(&stream, keyed) else { Issue.record("not init"); return }
        #expect(other.capabilities == ["interrupt_receipt_v1"])
    }

    @Test func streamedTextAndTheFinalMessageGiveOneMessage() {
        let (session, _) = session([
            #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[]}},"parent_tool_use_id":null}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Reading"}},"parent_tool_use_id":null}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello, "}},"parent_tool_use_id":null}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"world."}},"parent_tool_use_id":null}"#,
            #"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"thinking","thinking":"Reading","signature":"x"},{"type":"text","text":"Hello, world."}]},"parent_tool_use_id":null}"#,
        ])
        #expect(session.items == [.prompt("go"), .thought("Reading"), .message("Hello, world.")])
    }

    @Test func withoutDeltasTheAssistantsTextAndThinkingShow() {
        let (session, _) = session([
            #"{"type":"assistant","message":{"id":"msg_2","role":"assistant","content":[{"type":"thinking","thinking":"Plan it"},{"type":"text","text":"Done it."}]},"parent_tool_use_id":null}"#,
        ])
        #expect(session.items == [.prompt("go"), .thought("Plan it"), .message("Done it.")])
    }

    @Test func aBashToolUseAndItsResultEndCompleted() {
        let (session, events) = session([
            #"{"type":"assistant","message":{"id":"msg_3","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls -la","description":"List files"}}]},"parent_tool_use_id":null}"#,
            #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"total 0","is_error":false}]},"parent_tool_use_id":null}"#,
            #"{"type":"assistant","message":{"id":"msg_4","role":"assistant","content":[{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file_path":"/project/missing.txt"}}]},"parent_tool_use_id":null}"#,
            #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_2","type":"tool_result","content":[{"type":"text","text":"File does not exist."}],"is_error":true}]},"parent_tool_use_id":null}"#,
        ])
        #expect(session.items == [.prompt("go"), .tool("toolu_1"), .tool("toolu_2")])
        #expect(session.tools["toolu_1"]?.title == "Bash(ls -la)")
        #expect(session.tools["toolu_1"]?.kind == "execute")
        #expect(session.tools["toolu_1"]?.status == .completed)
        #expect(session.tools["toolu_2"]?.title == "Read(/project/missing.txt)")
        #expect(session.tools["toolu_2"]?.status == .failed)
        #expect(session.tools["toolu_2"]?.output == "File does not exist.")
        guard case .updates(let first) = events[0] else { Issue.record("no updates"); return }
        #expect(first.first?["update"]?["sessionUpdate"]?.string == "tool_call")
    }

    @Test func editAndWriteInputsGiveFileChanges() {
        let (session, _) = session([
            #"{"type":"assistant","message":{"id":"msg_5","role":"assistant","content":[{"type":"tool_use","id":"toolu_e","name":"Edit","input":{"file_path":"/project/app.py","old_string":"a = 1","new_string":"a = 2\nb = 3"}},{"type":"tool_use","id":"toolu_w","name":"Write","input":{"file_path":"/project/new.py","content":"x\ny\n"}}]},"parent_tool_use_id":null}"#,
        ])
        #expect(session.tools["toolu_e"]?.title == "Edit(/project/app.py)")
        #expect(session.tools["toolu_e"]?.kind == "edit")
        #expect(session.tools["toolu_e"]?.changes == [.init(path: "/project/app.py", added: 2, removed: 1, created: false)])
        #expect(session.tools["toolu_w"]?.changes.first?.created == true)
        #expect(session.tools["toolu_w"]?.changes.first?.path == "/project/new.py")
    }

    @Test func todoWriteGivesThePlanAndNoToolCall() {
        let (session, _) = session([
            #"{"type":"assistant","message":{"id":"msg_6","role":"assistant","content":[{"type":"tool_use","id":"toolu_t","name":"TodoWrite","input":{"todos":[{"content":"Find the bug","status":"completed","activeForm":"Finding"},{"content":"Fix it","status":"in_progress","activeForm":"Fixing"},{"content":"Test","status":"pending","activeForm":"Testing"}]}}]},"parent_tool_use_id":null}"#,
            #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_t","type":"tool_result","content":"Todos have been modified successfully."}]},"parent_tool_use_id":null}"#,
        ])
        #expect(session.items == [.prompt("go"), .plan])
        #expect(session.plan.map(\.content) == ["Find the bug", "Fix it", "Test"])
        #expect(session.plan.map(\.status) == [.completed, .inProgress, .pending])
        #expect(session.tools.isEmpty)
    }

    @Test func aSuccessfulResultEndsTheTurnWithAUsageLine() {
        let (session, events) = session([
            #"{"type":"assistant","message":{"id":"msg_7","role":"assistant","content":[{"type":"text","text":"Hi."}],"usage":{"input_tokens":100,"cache_creation_input_tokens":2000,"cache_read_input_tokens":10000,"output_tokens":245}},"parent_tool_use_id":null}"#,
            #"{"type":"result","subtype":"success","is_error":false,"duration_ms":1200,"num_turns":1,"result":"Hi.","session_id":"s-1","total_cost_usd":0.0123,"usage":{"input_tokens":100,"cache_creation_input_tokens":2000,"cache_read_input_tokens":10000,"output_tokens":245},"modelUsage":{"claude-test":{"contextWindow":200000}}}"#,
        ])
        guard case .turnEnded(let end) = events[1] else { Issue.record("no end"); return }
        #expect(end.stopReason == "end_turn")
        #expect(end.failure == nil)
        #expect(end.usageLine == "Context 12k of 200k \u{00B7} $0.01")
        #expect(session.lastStop == .endTurn)
        #expect(session.usage == "Context 12k of 200k \u{00B7} $0.01")
        #expect(session.items.last == .turnEnded(.endTurn))
    }

    @Test func turnLimitsMapToTheirStopReasons() {
        var stream = ClaudeStream()
        let limit = #"{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":5}"#
        guard case .turnEnded(let end) = decode(&stream, limit) else { Issue.record("no end"); return }
        #expect(end.stopReason == "max_turn_requests")
        #expect(end.failure == nil)
    }

    // MARK: Permissions

    private let bashAsk = #"{"type":"control_request","request_id":"perm-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf build && echo this is a long command that goes on well past any width a menu line or a title would be cut at, so it must come through whole"},"tool_use_id":"toolu_9"}}"#
    private let bashAskWithSuggestions = #"{"type":"control_request","request_id":"perm-2","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf build"},"tool_use_id":"toolu_10","permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf build"}],"behavior":"allow","destination":"localSettings"},{"type":"setMode","mode":"acceptEdits","destination":"projectSettings"}]}}"#

    @Test func aToolPermissionWithoutSuggestionsOffersAllowOnceAndReject() {
        var stream = ClaudeStream()
        guard case .permission(let asked) = decode(&stream, bashAsk) else { Issue.record("no permission"); return }
        #expect(asked.requestID == "perm-1")
        #expect(asked.toolName == "Bash")
        let options = asked.params["options"]?.array ?? []
        #expect(options.compactMap { $0["kind"]?.string } == ["allow_once", "reject_once"])
        #expect(options.compactMap { $0["name"]?.string } == ["Allow once", "Reject"])
        // The whole command, uncut.
        let command = "rm -rf build && echo this is a long command that goes on well past any width a menu line or a title would be cut at, so it must come through whole"
        #expect(asked.params["toolCall"]?["title"]?.string == "Bash(" + command + ")")
        #expect(asked.params["toolCall"]?["toolCallId"]?.string == "toolu_9")
        var session = ACPSession()
        session.prompted("clean")
        #expect(session.requested(permission: .string(asked.requestID), params: asked.params)?.options.count == 2)
    }

    @Test func eachChoiceEncodesItsControlResponse() {
        var stream = ClaudeStream()
        guard case .permission(let asked) = decode(&stream, bashAsk) else { Issue.record("no permission"); return }
        let allow = object(ClaudeStream.response(to: asked, optionID: "allow_once"))
        #expect(allow["type"]?.string == "control_response")
        #expect(allow["response"]?["subtype"]?.string == "success")
        #expect(allow["response"]?["request_id"]?.string == "perm-1")
        #expect(allow["response"]?["response"]?["behavior"]?.string == "allow")
        #expect(allow["response"]?["response"]?["updatedInput"] == asked.input)
        #expect(allow["response"]?["response"]?["updatedPermissions"] == nil)
        let reject = object(ClaudeStream.response(to: asked, optionID: "reject_once"))
        #expect(reject["response"]?["request_id"]?.string == "perm-1")
        #expect(reject["response"]?["response"]?["behavior"]?.string == "deny")
        #expect(reject["response"]?["response"]?["message"]?.string?.isEmpty == false)
        // Stopped or closed: denied, never allowed.
        let cancelled = object(ClaudeStream.response(to: asked, optionID: nil))
        #expect(cancelled["response"]?["response"]?["behavior"]?.string == "deny")
    }

    @Test func allowAlwaysIsOfferedWithSuggestionsAndKeptToTheSession() {
        var stream = ClaudeStream()
        guard case .permission(let asked) = decode(&stream, bashAskWithSuggestions) else { Issue.record("no permission"); return }
        let options = asked.params["options"]?.array ?? []
        #expect(options.compactMap { $0["kind"]?.string } == ["allow_once", "allow_always", "reject_once"])
        let always = object(ClaudeStream.response(to: asked, optionID: "allow_always"))
        let answer = always["response"]?["response"]
        #expect(answer?["behavior"]?.string == "allow")
        let updates = answer?["updatedPermissions"]?.array ?? []
        #expect(updates.count == 2)
        // Nothing is written to a settings file: every destination is the session.
        #expect(updates.allSatisfy { $0["destination"]?.string == "session" })
        #expect(updates.first?["rules"]?.array?.first?["ruleContent"]?.string == "rm -rf build")
        #expect(updates.last?["mode"]?.string == "acceptEdits")
    }

    @Test func aControlCancelAndAnUnknownControlRequestAreTold() {
        var stream = ClaudeStream()
        #expect(decode(&stream, #"{"type":"control_cancel_request","request_id":"perm-1"}"#) == .cancelRequest("perm-1"))
        #expect(decode(&stream, #"{"type":"control_request","request_id":"h-1","request":{"subtype":"hook_callback","callback_id":"c"}}"#)
                == .unknownControl(requestID: "h-1", subtype: "hook_callback"))
        let refusal = object(ClaudeStream.controlError(requestID: "h-1", message: "Next Term doesn\u{2019}t offer hook_callback"))
        #expect(refusal["response"]?["subtype"]?.string == "error")
        #expect(refusal["response"]?["request_id"]?.string == "h-1")
        #expect(refusal["response"]?["error"]?.string == "Next Term doesn\u{2019}t offer hook_callback")
    }

    // MARK: AskUserQuestion

    private let twoQuestions = #"{"type":"control_request","request_id":"q-1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","tool_use_id":"toolu_q","input":{"questions":[{"question":"Which database should we use?","header":"Database","options":[{"label":"Postgres","description":"A server"},{"label":"SQLite","description":"A file"}],"multiSelect":false},{"question":"Add a cache","header":"Cache","options":[{"label":"Yes","description":""},{"label":"No","description":""}],"multiSelect":false}]}}}"#

    @Test func askUserQuestionBecomesQuestionMenusAnsweredOnce() {
        var stream = ClaudeStream()
        guard case .question(let asked) = decode(&stream, twoQuestions) else { Issue.record("no question"); return }
        #expect(asked.requestID == "q-1")
        #expect(asked.items.map(\.question) == ["Which database should we use?", "Add a cache"])
        #expect(asked.items.map(\.options) == [["Postgres", "SQLite"], ["Yes", "No"]])
        var session = ACPSession()
        session.prompted("set up")
        var picks: [String] = []
        for index in asked.items.indices {
            let menu = session.requested(permission: .string(asked.requestID), params: asked.params(at: index), question: true)
            #expect(menu?.isQuestion == true)
            #expect(!ACPTranscript.lines(session, from: 0, width: 100).contains { $0.text.contains(ACPTranscript.questionLead) })
            guard let (_, option) = session.choose(index == 0 ? 1 : 0) else { Issue.record("no option"); return }
            picks.append(option)
        }
        #expect(picks == ["SQLite", "Yes"])
        let answer = object(ClaudeStream.answer(asked, with: picks))
        #expect(answer["response"]?["request_id"]?.string == "q-1")
        let response = answer["response"]?["response"]
        #expect(response?["behavior"]?.string == "allow")
        #expect(response?["updatedInput"]?["questions"] == asked.input["questions"])
        #expect(response?["updatedInput"]?["answers"] == .object(["Which database should we use?": .string("SQLite"),
                                                                   "Add a cache": .string("Yes")]))
    }

    @Test func theQuestionsToolCallStaysOutOfTheTranscript() {
        let (session, _) = session([
            #"{"type":"assistant","message":{"id":"msg_q","role":"assistant","content":[{"type":"tool_use","id":"toolu_q","name":"AskUserQuestion","input":{"questions":[]}}]},"parent_tool_use_id":null}"#,
            #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_q","type":"tool_result","content":"User has answered."}]},"parent_tool_use_id":null}"#,
        ])
        #expect(session.items == [.prompt("go")])
    }

    // MARK: Errors

    @Test func anErrorResultEndsAsAFailureWithItsMessage() {
        var stream = ClaudeStream()
        let line = #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["The tool runner crashed"]}"#
        guard case .turnEnded(let end) = decode(&stream, line) else { Issue.record("no end"); return }
        #expect(end.stopReason == nil)
        #expect(end.failure == "The tool runner crashed")
        let bare = #"{"type":"result","subtype":"error_max_budget_usd","is_error":true}"#
        guard case .turnEnded(let other) = decode(&stream, bare) else { Issue.record("no end"); return }
        #expect(other.failure?.contains("error_max_budget_usd") == true)
        let apiError = #"{"type":"result","subtype":"success","is_error":true,"result":"API Error: 500 Internal server error"}"#
        guard case .turnEnded(let third) = decode(&stream, apiError) else { Issue.record("no end"); return }
        #expect(third.failure == "API Error: 500 Internal server error")
    }

    @Test func linesThatArentKnownAreIgnored() {
        var stream = ClaudeStream()
        #expect(decode(&stream, "Loading plugins...") == .ignore)
        #expect(decode(&stream, "") == .ignore)
        #expect(decode(&stream, #"{"type":"rate_limit_event","rate_limit_info":{}}"#) == .ignore)
        #expect(decode(&stream, #"{"type":"system","subtype":"compact_boundary"}"#) == .ignore)
        #expect(decode(&stream, #"[1,2]"#) == .ignore)
    }

    @Test func anAuthenticationErrorGivesTheSignInLine() {
        var stream = ClaudeStream()
        let assistant = #"{"type":"assistant","message":{"id":"msg_a","role":"assistant","content":[{"type":"text","text":"Invalid API key · Please run /login"}]},"parent_tool_use_id":null,"error":"authentication_failed"}"#
        #expect(decode(&stream, assistant) == .authFailure)
        // The result after it is the same failure, told once.
        let result = #"{"type":"result","subtype":"success","is_error":true,"result":"Invalid API key · Please run /login"}"#
        #expect(decode(&stream, result) == .ignore)
        var fresh = ClaudeStream()
        #expect(decode(&fresh, result) == .authFailure)
        #expect(ClaudeStream.signInLine == "Run claude in a tab to sign in, then start the session again")
    }

    // MARK: Lines to Claude

    @Test func aPromptIsOneUserMessageLine() {
        var stream = ClaudeStream()
        let line = object(stream.userMessage("two\nlines"))
        #expect(line["type"]?.string == "user")
        #expect(line["message"]?["role"]?.string == "user")
        #expect(line["message"]?["content"]?.string == "two\nlines")
        #expect(line["parent_tool_use_id"] == .null)
    }

    @Test func interruptAndInitializeGoWithFreshRequestIDs() {
        var stream = ClaudeStream()
        let initialize = stream.initializeRequest()
        let first = stream.interruptRequest()
        let second = stream.interruptRequest()
        #expect(Set([initialize.id, first.id, second.id]).count == 3)
        let initLine = object(initialize.line)
        #expect(initLine["type"]?.string == "control_request")
        #expect(initLine["request_id"]?.string == initialize.id)
        #expect(initLine["request"]?["subtype"]?.string == "initialize")
        let interrupt = object(first.line)
        #expect(interrupt["type"]?.string == "control_request")
        #expect(interrupt["request_id"]?.string == first.id)
        #expect(interrupt["request"] == .object(["subtype": .string("interrupt")]))
        // The answers to them.
        let ok = #"{"type":"control_response","response":{"subtype":"success","request_id":"\#(initialize.id)","response":{"commands":[],"capabilities":["interrupt_receipt_v1"]}}}"#
        guard case .controlResponse(let id, let result, let error) = decode(&stream, ok) else { Issue.record("no response"); return }
        #expect(id == initialize.id)
        #expect(error == nil)
        #expect(ClaudeStream.capabilities(in: result) == ["interrupt_receipt_v1"])
        let failed = #"{"type":"control_response","response":{"subtype":"error","request_id":"\#(first.id)","error":"No turn to interrupt"}}"#
        #expect(decode(&stream, failed) == .controlResponse(requestID: first.id, response: nil, error: "No turn to interrupt"))
    }

    @Test func anInterruptedTurnEndsCancelled() {
        var stream = ClaudeStream()
        _ = stream.userMessage("long job")
        _ = stream.interruptRequest()
        #expect(decode(&stream, #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"parent_tool_use_id":null}"#) == .ignore)
        let result = #"{"type":"result","subtype":"error_during_execution","is_error":true}"#
        guard case .turnEnded(let end) = decode(&stream, result) else { Issue.record("no end"); return }
        #expect(end.stopReason == "cancelled")
        #expect(end.failure == nil)
        // The next prompt's turn is not taken as stopped.
        _ = stream.userMessage("next")
        guard case .turnEnded(let next) = decode(&stream, #"{"type":"result","subtype":"success","is_error":false}"#) else { Issue.record("no end"); return }
        #expect(next.stopReason == "end_turn")
    }
}
