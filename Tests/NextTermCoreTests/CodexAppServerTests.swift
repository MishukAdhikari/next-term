import Foundation
import Testing
@testable import NextTermCore

/// Codex's app-server (plan 035 U3): the JSON-RPC lines `codex app-server` writes, turned into the session model's
/// ACP-shaped updates and requests, and the lines Next Term writes back. Fixture lines only; no real CLI runs.
@Suite struct CodexAppServerTests {
    private func decode(_ codex: inout CodexAppServer, _ line: String) -> CodexAppServer.Event {
        codex.decode(Data(line.utf8))
    }

    /// The JSON object a line Next Term writes holds.
    private func object(_ data: Data) -> ACPWire.Value {
        #expect(data.last == 0x0A)
        #expect(!data.dropLast().contains(0x0A))
        let parsed = try? JSONSerialization.jsonObject(with: data)
        return parsed.flatMap { ACPWire.Value(serialized: $0) } ?? .null
    }

    /// A translator that has sent `initialize` (id 1) and `thread/start` (id 2) and had both answered.
    private func started() -> CodexAppServer {
        var codex = CodexAppServer()
        _ = codex.initializeRequest(version: "1.0")
        _ = codex.threadStartRequest(cwd: "/project", mcpServer: nil)
        _ = decode(&codex, #"{"id":1,"result":{"userAgent":"codex_test/0.0.1","codexHome":"/home/.codex","platformFamily":"unix","platformOs":"macos"}}"#)
        _ = decode(&codex, #"{"id":2,"result":{"thread":{"id":"thr_1","turns":[]},"model":"test-model","cwd":"/project","approvalPolicy":"on-request"}}"#)
        return codex
    }

    /// A session built from the updates `lines` decode to.
    private func session(_ codex: inout CodexAppServer, _ lines: [String]) -> (ACPSession, [CodexAppServer.Event]) {
        var session = ACPSession()
        session.prompted("go")
        var events: [CodexAppServer.Event] = []
        for line in lines {
            let event = decode(&codex, line)
            events.append(event)
            switch event {
            case .updates(let updates): updates.forEach { session.apply(update: $0) }
            case .permission(let permission): session.requested(permission: permission.requestID, params: permission.params)
            case .turnEnded(let end):
                if let failure = end.failure { session.turnFailed(failure) } else { session.turnEnded(end.stopReason) }
            default: break
            }
        }
        return (session, events)
    }

    // MARK: Encoding

    @Test func initializeAndInitializedAndThreadStartEncode() {
        var codex = CodexAppServer()
        let initialize = codex.initializeRequest(version: "0.11.50")
        let first = object(initialize.line)
        #expect(first["jsonrpc"]?.string == "2.0")
        #expect(first["method"]?.string == "initialize")
        #expect(first["id"]?.int == initialize.id)
        #expect(first["params"]?["clientInfo"]?["name"]?.string == "Next Term")
        #expect(first["params"]?["clientInfo"]?["version"]?.string == "0.11.50")
        // Off the experimental API.
        #expect(first["params"]?["capabilities"]?["experimentalApi"]?.bool != true)

        let initialized = object(CodexAppServer.initializedNotification())
        #expect(initialized["method"]?.string == "initialized")
        #expect(initialized["id"] == nil)

        let server = ACPWire.StdioServer(name: "next-term-test", command: "/Applications/Test.app/Contents/MacOS/Test",
                                         arguments: ["--cli", "mcp"])
        let thread = codex.threadStartRequest(cwd: "/project", mcpServer: server)
        #expect(thread.id != initialize.id)
        let start = object(thread.line)
        #expect(start["method"]?.string == "thread/start")
        #expect(start["params"]?["cwd"]?.string == "/project")
        #expect(start["params"]?["approvalPolicy"]?.string == "on-request")
        let entry = start["params"]?["config"]?["mcp_servers"]?["next-term-test"]
        #expect(entry?["command"]?.string == "/Applications/Test.app/Contents/MacOS/Test")
        #expect(entry?["args"] == .array([.string("--cli"), .string("mcp")]))

        // Outside a Next Term tab: no config at all, the user's own servers only.
        let bare = object(codex.threadStartRequest(cwd: "/project", mcpServer: nil).line)
        #expect(bare["params"]?["config"] == nil)
        #expect(bare["params"]?["approvalPolicy"]?.string == "on-request")
    }

    @Test func turnStartAndInterruptEncodeWithFreshIDs() {
        var codex = started()
        let turn = codex.turnStartRequest(threadID: "thr_1", text: "fix the test")
        let start = object(turn.line)
        #expect(start["method"]?.string == "turn/start")
        #expect(start["params"]?["threadId"]?.string == "thr_1")
        #expect(start["params"]?["input"] == .array([.object(["type": .string("text"), "text": .string("fix the test")])]))
        let stop = codex.interruptRequest(threadID: "thr_1", turnID: "turn_1")
        #expect(stop.id > turn.id)
        let interrupt = object(stop.line)
        #expect(interrupt["method"]?.string == "turn/interrupt")
        #expect(interrupt["params"] == .object(["threadId": .string("thr_1"), "turnId": .string("turn_1")]))
    }

    // MARK: Happy path

    @Test func initializeThenThreadStartGiveTheUserAgentAndTheThread() {
        var codex = CodexAppServer()
        let initialize = codex.initializeRequest(version: "1.0")
        let answer = #"{"id":\#(initialize.id),"result":{"userAgent":"codex_test/0.0.1","codexHome":"/home/.codex","platformFamily":"unix","platformOs":"macos"}}"#
        #expect(decode(&codex, answer) == .initialized(userAgent: "codex_test/0.0.1"))
        #expect(codex.userAgent == "codex_test/0.0.1")
        let thread = codex.threadStartRequest(cwd: "/project", mcpServer: nil)
        let started = #"{"id":\#(thread.id),"result":{"thread":{"id":"thr_9","turns":[]},"model":"test-model"}}"#
        #expect(decode(&codex, started) == .threadStarted("thr_9"))
        #expect(codex.threadID == "thr_9")
    }

    @Test func aTurnWithDeltasACommandAndCompletionGivesTheTranscript() {
        var codex = started()
        let turn = codex.turnStartRequest(threadID: "thr_1", text: "go")
        let (session, events) = session(&codex, [
            #"{"id":\#(turn.id),"result":{"turn":{"id":"turn_1","items":[],"status":"inProgress"}}}"#,
            #"{"method":"turn/started","params":{"threadId":"thr_1","turn":{"id":"turn_1","items":[],"status":"inProgress"}}}"#,
            #"{"method":"item/started","params":{"threadId":"thr_1","turnId":"turn_1","startedAtMs":1,"item":{"type":"agentMessage","id":"msg_1","text":""}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"threadId":"thr_1","turnId":"turn_1","itemId":"msg_1","delta":"Looking "}}"#,
            #"{"method":"item/agentMessage/delta","params":{"threadId":"thr_1","turnId":"turn_1","itemId":"msg_1","delta":"now."}}"#,
            #"{"method":"item/completed","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"agentMessage","id":"msg_1","text":"Looking now."}}}"#,
            #"{"method":"item/started","params":{"threadId":"thr_1","turnId":"turn_1","startedAtMs":2,"item":{"type":"commandExecution","id":"cmd_1","command":"git status --porcelain && swift build --product NextTerm 2>&1 | tail -n 40","cwd":"/project","commandActions":[],"status":"inProgress"}}}"#,
            #"{"method":"item/commandExecution/outputDelta","params":{"threadId":"thr_1","turnId":"turn_1","itemId":"cmd_1","delta":"ok"}}"#,
            #"{"method":"item/completed","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"commandExecution","id":"cmd_1","command":"git status --porcelain && swift build --product NextTerm 2>&1 | tail -n 40","cwd":"/project","commandActions":[],"status":"completed","exitCode":0,"aggregatedOutput":"Build complete!"}}}"#,
            #"{"method":"turn/completed","params":{"threadId":"thr_1","turn":{"id":"turn_1","items":[],"status":"completed"}}}"#,
        ])
        #expect(events[0] == .turnStarted("turn_1"))
        // The notification repeats the id the answer gave: nothing new.
        #expect(events[1] == .ignore)
        #expect(codex.turnID == nil)
        #expect(session.items == [.prompt("go"), .message("Looking now."), .tool("cmd_1"), .turnEnded(.endTurn)])
        let tool = session.tools["cmd_1"]
        // The whole command, uncut.
        #expect(tool?.title == "git status --porcelain && swift build --product NextTerm 2>&1 | tail -n 40")
        #expect(tool?.kind == "execute")
        #expect(tool?.status == .completed)
        #expect(tool?.output == "Build complete!")
        guard case .turnEnded(let end) = events.last else { Issue.record("no end"); return }
        #expect(end.stopReason == "end_turn")
        #expect(end.failure == nil)
    }

    @Test func aCompletedMessageWithNoDeltasShowsItsText() {
        var codex = started()
        let (session, _) = session(&codex, [
            #"{"method":"item/completed","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"agentMessage","id":"msg_2","text":"All done."}}}"#,
        ])
        #expect(session.items == [.prompt("go"), .message("All done.")])
    }

    @Test func aFailedCommandEndsFailed() {
        var codex = started()
        let (session, _) = session(&codex, [
            #"{"method":"item/started","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"commandExecution","id":"cmd_2","command":"false","cwd":"/project","commandActions":[],"status":"inProgress"}}}"#,
            #"{"method":"item/completed","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"commandExecution","id":"cmd_2","command":"false","cwd":"/project","commandActions":[],"status":"failed","exitCode":1,"aggregatedOutput":""}}}"#,
            #"{"method":"item/started","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"commandExecution","id":"cmd_3","command":"rm -rf build","cwd":"/project","commandActions":[],"status":"inProgress"}}}"#,
            #"{"method":"item/completed","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"commandExecution","id":"cmd_3","command":"rm -rf build","cwd":"/project","commandActions":[],"status":"declined"}}}"#,
        ])
        #expect(session.tools["cmd_2"]?.status == .failed)
        #expect(session.tools["cmd_3"]?.status == .failed)
    }

    @Test func aFileChangeGivesCountsFromItsDiff() {
        var codex = started()
        let diff = "--- a/app.py\n+++ b/app.py\n@@ -1,3 +1,4 @@\n import os\n-a = 1\n+a = 2\n+b = 3\n print(a)\n"
        let escaped = diff.replacingOccurrences(of: "\n", with: "\\n")
        let (session, _) = session(&codex, [
            #"{"method":"item/started","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"fileChange","id":"fc_1","status":"inProgress","changes":[{"path":"/project/app.py","kind":{"type":"update"},"diff":"\#(escaped)"},{"path":"/project/new.py","kind":{"type":"add"},"diff":"x\ny\n"}]}}}"#,
            #"{"method":"item/completed","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"fileChange","id":"fc_1","status":"completed","changes":[{"path":"/project/app.py","kind":{"type":"update"},"diff":"\#(escaped)"},{"path":"/project/new.py","kind":{"type":"add"},"diff":"x\ny\n"}]}}}"#,
        ])
        let tool = session.tools["fc_1"]
        #expect(tool?.kind == "edit")
        #expect(tool?.status == .completed)
        #expect(tool?.title == "Edit /project/app.py, /project/new.py")
        #expect(tool?.changes.first == .init(path: "/project/app.py", added: 2, removed: 1, created: false))
        #expect(tool?.changes.last?.created == true)
        #expect(tool?.changes.last?.path == "/project/new.py")
    }

    @Test func aFileChangeWithNoDiffHasNoCounts() {
        var codex = started()
        let (session, _) = session(&codex, [
            #"{"method":"item/started","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"fileChange","id":"fc_2","status":"inProgress","changes":[{"path":"/project/app.py","kind":{"type":"update"},"diff":""}]}}}"#,
        ])
        #expect(session.tools["fc_2"]?.changes == [])
        #expect(session.tools["fc_2"]?.title == "Edit /project/app.py")
    }

    @Test func anMCPToolCallStartsAndCompletes() {
        var codex = started()
        let (session, _) = session(&codex, [
            #"{"method":"item/started","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"mcpToolCall","id":"mcp_1","server":"next-term","tool":"list_tabs","arguments":{},"status":"inProgress"}}}"#,
            #"{"method":"item/completed","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"mcpToolCall","id":"mcp_1","server":"next-term","tool":"list_tabs","arguments":{},"status":"completed","result":{"content":[{"type":"text","text":"2 tabs"}]}}}}"#,
            #"{"method":"item/started","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"mcpToolCall","id":"mcp_2","server":"docs","tool":"search","arguments":{"q":"x"},"status":"inProgress"}}}"#,
            #"{"method":"item/completed","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"mcpToolCall","id":"mcp_2","server":"docs","tool":"search","arguments":{"q":"x"},"status":"failed","error":{"message":"timed out"}}}}"#,
        ])
        #expect(session.tools["mcp_1"]?.title == "next-term: list_tabs")
        #expect(session.tools["mcp_1"]?.status == .completed)
        #expect(session.tools["mcp_1"]?.output == "2 tabs")
        #expect(session.tools["mcp_2"]?.status == .failed)
        #expect(session.tools["mcp_2"]?.output == "timed out")
    }

    // MARK: Reasoning, plan and usage

    @Test func reasoningDeltasAreThoughtsShownOnce() {
        var codex = started()
        let (session, _) = session(&codex, [
            #"{"method":"item/reasoning/summaryTextDelta","params":{"threadId":"thr_1","turnId":"turn_1","itemId":"rs_1","summaryIndex":0,"delta":"Checking "}}"#,
            #"{"method":"item/reasoning/textDelta","params":{"threadId":"thr_1","turnId":"turn_1","itemId":"rs_1","contentIndex":0,"delta":"the tests"}}"#,
            #"{"method":"item/completed","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"reasoning","id":"rs_1","summary":["Checking the tests"],"content":[]}}}"#,
            #"{"method":"item/completed","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"reasoning","id":"rs_2","summary":["Then the build"],"content":[]}}}"#,
        ])
        #expect(session.items == [.prompt("go"), .thought("Checking the tests"), .thought("Then the build")]
            || session.items == [.prompt("go"), .thought("Checking the testsThen the build")])
    }

    @Test func thePlanUpdateGivesEntriesWithStatuses() {
        var codex = started()
        let (session, _) = session(&codex, [
            #"{"method":"turn/plan/updated","params":{"threadId":"thr_1","turnId":"turn_1","explanation":null,"plan":[{"step":"Find the bug","status":"completed"},{"step":"Fix it","status":"inProgress"},{"step":"Test","status":"pending"}]}}"#,
        ])
        #expect(session.items == [.prompt("go"), .plan])
        #expect(session.plan.map(\.content) == ["Find the bug", "Fix it", "Test"])
        #expect(session.plan.map(\.status) == [.completed, .inProgress, .pending])
    }

    @Test func tokenUsageGivesTheUsageLine() {
        var codex = started()
        let (session, events) = session(&codex, [
            #"{"method":"thread/tokenUsage/updated","params":{"threadId":"thr_1","turnId":"turn_1","tokenUsage":{"last":{"inputTokens":12000,"cachedInputTokens":8000,"outputTokens":345,"reasoningOutputTokens":100,"totalTokens":12345},"total":{"inputTokens":50000,"cachedInputTokens":30000,"outputTokens":900,"reasoningOutputTokens":200,"totalTokens":50900},"modelContextWindow":272000}}}"#,
        ])
        guard case .updates(let updates) = events[0] else { Issue.record("no update"); return }
        #expect(updates.first?["update"]?["sessionUpdate"]?.string == "usage_update")
        #expect(session.usage == "Context 12k of 272k")
        // No window known: nothing to show.
        var other = started()
        let bare = #"{"method":"thread/tokenUsage/updated","params":{"threadId":"thr_1","turnId":"turn_1","tokenUsage":{"last":{"inputTokens":1,"cachedInputTokens":0,"outputTokens":1,"reasoningOutputTokens":0,"totalTokens":2},"total":{"inputTokens":1,"cachedInputTokens":0,"outputTokens":1,"reasoningOutputTokens":0,"totalTokens":2}}}}"#
        #expect(decode(&other, bare) == .ignore)
    }

    // MARK: Approvals

    private let commandApproval = #"{"id":7,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_1","turnId":"turn_1","itemId":"cmd_9","startedAtMs":5,"command":"rm -rf build && find . -name '*.o' -delete && echo a-long-tail-that-must-not-be-cut","cwd":"/project","reason":"needs write access"}}"#

    @Test func aCommandApprovalOffersThreeChoicesWithTheWholeCommand() {
        var codex = started()
        guard case .permission(let permission) = decode(&codex, commandApproval) else { Issue.record("no permission"); return }
        #expect(permission.requestID == .number(7))
        #expect(permission.method == "item/commandExecution/requestApproval")
        let options = (permission.params["options"]?.array ?? []).compactMap { $0["optionId"]?.string }
        #expect(options == ["allow_once", "allow_always", "reject_once"])
        let kinds = (permission.params["options"]?.array ?? []).compactMap { $0["kind"]?.string }
        #expect(kinds == ["allow_once", "allow_always", "reject_once"])
        let title = permission.params["toolCall"]?["title"]?.string
        #expect(title == "rm -rf build && find . -name '*.o' -delete && echo a-long-tail-that-must-not-be-cut")
        #expect(permission.params["toolCall"]?["toolCallId"]?.string == "cmd_9")
        #expect(permission.params["toolCall"]?["kind"]?.string == "execute")
        var session = ACPSession()
        #expect(session.requested(permission: permission.requestID, params: permission.params) != nil)
    }

    @Test func eachChoiceEncodesItsDecision() {
        var codex = started()
        guard case .permission(let permission) = decode(&codex, commandApproval) else { Issue.record("no permission"); return }
        let cases: [(String?, String)] = [
            ("allow_once", "accept"), ("allow_always", "acceptForSession"), ("reject_once", "decline"), (nil, "cancel"),
        ]
        for (option, decision) in cases {
            let answer = object(CodexAppServer.response(to: permission, optionID: option))
            #expect(answer["id"] == .number(7))
            #expect(answer["jsonrpc"]?.string == "2.0")
            #expect(answer["result"] == .object(["decision": .string(decision)]))
            #expect(answer["error"] == nil)
        }
    }

    @Test func aFileChangeApprovalNamesThePathsAndEncodesTheSame() {
        var codex = started()
        _ = decode(&codex, #"{"method":"item/started","params":{"threadId":"thr_1","turnId":"turn_1","item":{"type":"fileChange","id":"fc_7","status":"inProgress","changes":[{"path":"/project/a.swift","kind":{"type":"update"},"diff":""},{"path":"/project/b.swift","kind":{"type":"delete"},"diff":"gone\n"}]}}}"#)
        let line = #"{"id":"req-8","method":"item/fileChange/requestApproval","params":{"threadId":"thr_1","turnId":"turn_1","itemId":"fc_7","startedAtMs":6}}"#
        guard case .permission(let permission) = decode(&codex, line) else { Issue.record("no permission"); return }
        #expect(permission.requestID == .string("req-8"))
        #expect(permission.params["toolCall"]?["title"]?.string == "Edit /project/a.swift, /project/b.swift")
        #expect(permission.params["toolCall"]?["kind"]?.string == "edit")
        let options = (permission.params["options"]?.array ?? []).compactMap { $0["optionId"]?.string }
        #expect(options == ["allow_once", "allow_always", "reject_once"])
        let cases: [(String?, String)] = [
            ("allow_once", "accept"), ("allow_always", "acceptForSession"), ("reject_once", "decline"), (nil, "cancel"),
        ]
        for (option, decision) in cases {
            let answer = object(CodexAppServer.response(to: permission, optionID: option))
            #expect(answer["id"] == .string("req-8"))
            #expect(answer["result"] == .object(["decision": .string(decision)]))
        }
        // A root to write under, with no item seen first.
        let grant = #"{"id":9,"method":"item/fileChange/requestApproval","params":{"threadId":"thr_1","turnId":"turn_1","itemId":"fc_x","startedAtMs":6,"grantRoot":"/project/out"}}"#
        guard case .permission(let other) = decode(&codex, grant) else { Issue.record("no permission"); return }
        #expect(other.params["toolCall"]?["title"]?.string == "Write under /project/out")
    }

    @Test func otherServerRequestsAreUnsupportedAndAnsweredMethodNotFound() {
        var codex = started()
        let methods = ["item/tool/requestUserInput", "item/permissions/requestApproval", "mcpServer/elicitation/request",
                       "item/tool/call", "execCommandApproval", "applyPatchApproval",
                       "account/chatgptAuthTokens/refresh", "something/new"]
        for (index, method) in methods.enumerated() {
            let line = #"{"id":\#(100 + index),"method":"\#(method)","params":{"threadId":"thr_1"}}"#
            #expect(decode(&codex, line) == .unsupportedRequest(id: .number(Double(100 + index)), method: method))
        }
        let answer = object(CodexAppServer.unsupportedAnswer(id: .number(100), method: "item/tool/requestUserInput"))
        #expect(answer["id"] == .number(100))
        #expect(answer["result"] == nil)
        #expect(answer["error"]?["code"]?.int == -32601)
        #expect(answer["error"]?["message"]?.string?.contains("item/tool/requestUserInput") == true)
        #expect(CodexAppServer.unsupportedNote("item/tool/requestUserInput").contains("item/tool/requestUserInput"))
    }

    @Test func serverRequestResolvedClosesTheMenu() {
        var codex = started()
        let line = #"{"method":"serverRequest/resolved","params":{"threadId":"thr_1","requestId":7}}"#
        #expect(decode(&codex, line) == .resolved(.number(7)))
        let named = #"{"method":"serverRequest/resolved","params":{"threadId":"thr_1","requestId":"req-8"}}"#
        #expect(decode(&codex, named) == .resolved(.string("req-8")))
    }

    // MARK: Interrupt

    @Test func anInterruptedTurnEndsCancelled() {
        var codex = started()
        _ = codex.turnStartRequest(threadID: "thr_1", text: "go")
        _ = decode(&codex, #"{"method":"turn/started","params":{"threadId":"thr_1","turn":{"id":"turn_4","items":[],"status":"inProgress"}}}"#)
        #expect(codex.turnID == "turn_4")
        let stop = codex.interruptRequest(threadID: "thr_1", turnID: "turn_4")
        #expect(decode(&codex, #"{"id":\#(stop.id),"result":{}}"#) == .ignore)
        let (session, events) = session(&codex, [
            #"{"method":"turn/completed","params":{"threadId":"thr_1","turn":{"id":"turn_4","items":[],"status":"interrupted"}}}"#,
        ])
        guard case .turnEnded(let end) = events[0] else { Issue.record("no end"); return }
        #expect(end.stopReason == "cancelled")
        #expect(session.items.last == .turnEnded(.cancelled))
        #expect(ACPSession.StopReason.cancelled.words == "Stopped")
    }

    @Test func aFailedInterruptIsTold() {
        var codex = started()
        let stop = codex.interruptRequest(threadID: "thr_1", turnID: "turn_4")
        let line = #"{"id":\#(stop.id),"error":{"code":-32600,"message":"no active turn"}}"#
        #expect(decode(&codex, line) == .requestFailed(method: "turn/interrupt", message: "no active turn"))
    }

    @Test func aFailedTurnEndsWithItsError() {
        var codex = started()
        let (session, events) = session(&codex, [
            #"{"method":"turn/completed","params":{"threadId":"thr_1","turn":{"id":"turn_5","items":[],"status":"failed","error":{"message":"The model is overloaded.","codexErrorInfo":"serverOverloaded"}}}}"#,
        ])
        guard case .turnEnded(let end) = events[0] else { Issue.record("no end"); return }
        #expect(end.stopReason == nil)
        #expect(end.failure == "The model is overloaded.")
        #expect(session.working == false)
        // A turn/start answered with an error is a failed turn too.
        var other = started()
        let turn = other.turnStartRequest(threadID: "thr_1", text: "go")
        let line = #"{"id":\#(turn.id),"error":{"code":-32600,"message":"thread not found"}}"#
        #expect(decode(&other, line) == .turnEnded(.init(stopReason: nil, failure: "thread not found")))
    }

    // MARK: Auth

    @Test func notSignedInGivesTheCodexLoginLine() {
        #expect(CodexAppServer.signInLine.contains("codex login"))
        var codex = started()
        let error = #"{"method":"error","params":{"threadId":"thr_1","turnId":"turn_1","willRetry":false,"error":{"message":"401 Unauthorized","codexErrorInfo":"unauthorized"}}}"#
        #expect(decode(&codex, error) == .authFailure)
        // The turn's end that follows is the same failure, told once.
        let end = #"{"method":"turn/completed","params":{"threadId":"thr_1","turn":{"id":"turn_1","items":[],"status":"failed","error":{"message":"401 Unauthorized","codexErrorInfo":"unauthorized"}}}}"#
        #expect(decode(&codex, end) == .ignore)

        var alone = started()
        #expect(decode(&alone, end) == .authFailure)

        // account/read with no account, where one is needed.
        var reading = started()
        let read = reading.accountReadRequest()
        #expect(object(read.line)["method"]?.string == "account/read")
        #expect(decode(&reading, #"{"id":\#(read.id),"result":{"account":null,"requiresOpenaiAuth":true}}"#) == .authFailure)
        let fine = reading.accountReadRequest()
        #expect(decode(&reading, #"{"id":\#(fine.id),"result":{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}}"#) == .ignore)

        // thread/start refused for no login.
        var refused = CodexAppServer()
        let thread = refused.threadStartRequest(cwd: "/project", mcpServer: nil)
        let line = #"{"id":\#(thread.id),"error":{"code":-32600,"message":"Not logged in. Run codex login."}}"#
        #expect(decode(&refused, line) == .authFailure)
    }

    @Test func aRetriedErrorIsIgnored() {
        var codex = started()
        let line = #"{"method":"error","params":{"threadId":"thr_1","turnId":"turn_1","willRetry":true,"error":{"message":"stream disconnected"}}}"#
        #expect(decode(&codex, line) == .ignore)
    }

    // MARK: Protocol drift

    @Test func theDriftNoteNamesTheUserAgentWhenKnown() {
        #expect(CodexAppServer.driftNote(userAgent: nil, detail: nil) == "Codex's app-server changed; run codex in a terminal tab for now.")
        let note = CodexAppServer.driftNote(userAgent: "codex_test/0.0.1", detail: "thread/start gave no thread id")
        #expect(note.hasPrefix("Codex's app-server changed; run codex in a terminal tab for now."))
        #expect(note.contains("codex_test/0.0.1"))
        #expect(note.contains("thread/start gave no thread id"))
    }

    @Test func initializeWithNoUserAgentIsDrift() {
        var codex = CodexAppServer()
        let initialize = codex.initializeRequest(version: "1.0")
        guard case .drift(let note) = decode(&codex, #"{"id":\#(initialize.id),"result":{"platform":"x"}}"#) else {
            Issue.record("no drift"); return
        }
        #expect(note.hasPrefix("Codex's app-server changed"))
    }

    @Test func threadStartWithNoThreadIDIsDrift() {
        var codex = CodexAppServer()
        let initialize = codex.initializeRequest(version: "1.0")
        _ = decode(&codex, #"{"id":\#(initialize.id),"result":{"userAgent":"codex_test/0.0.1"}}"#)
        let thread = codex.threadStartRequest(cwd: "/project", mcpServer: nil)
        guard case .drift(let note) = decode(&codex, #"{"id":\#(thread.id),"result":{"thread":{"name":"x"}}}"#) else {
            Issue.record("no drift"); return
        }
        #expect(note.contains("codex_test/0.0.1"))
    }

    @Test func methodNotFoundOnARequiredMethodIsDrift() {
        for method in ["initialize", "thread/start", "turn/start", "turn/interrupt"] {
            var codex = CodexAppServer()
            let id: Int
            switch method {
            case "initialize": id = codex.initializeRequest(version: "1.0").id
            case "thread/start": id = codex.threadStartRequest(cwd: "/project", mcpServer: nil).id
            case "turn/start": id = codex.turnStartRequest(threadID: "thr_1", text: "go").id
            default: id = codex.interruptRequest(threadID: "thr_1", turnID: "turn_1").id
            }
            let line = #"{"id":\#(id),"error":{"code":-32601,"message":"method not found"}}"#
            guard case .drift(let note) = decode(&codex, line) else { Issue.record("no drift for \(method)"); continue }
            #expect(note.contains(method))
        }
        // account/read is a check of Next Term's own, not one the session needs.
        var codex = CodexAppServer()
        let read = codex.accountReadRequest()
        #expect(decode(&codex, #"{"id":\#(read.id),"error":{"code":-32601,"message":"method not found"}}"#) == .ignore)
    }

    @Test func unknownNotificationsAreCountedAndTheTurnEndsAfterSixtyQuietSeconds() {
        var codex = started()
        #expect(decode(&codex, #"{"method":"item/agentMessage/textDelta2","params":{}}"#) == .unknownNotification("item/agentMessage/textDelta2"))
        #expect(decode(&codex, #"{"method":"thread/status/changed","params":{"threadId":"thr_1","status":{"type":"active"}}}"#) == .ignore)
        // A line that isn't JSON-RPC is nothing.
        #expect(decode(&codex, "not json") == .ignore)

        let start = Date(timeIntervalSinceReferenceDate: 1000)
        var watch = CodexAppServer.DriftWatch()
        #expect(!watch.isDrifting(at: start.addingTimeInterval(500)))
        watch.turnStarted(at: start)
        watch.observe(.updates([]), at: start.addingTimeInterval(5))
        // Quiet with nothing at all is a slow turn, not drift.
        #expect(!watch.isDrifting(at: start.addingTimeInterval(200)))
        watch.observe(.unknownNotification("a/b"), at: start.addingTimeInterval(10))
        watch.observe(.unknownNotification("a/c"), at: start.addingTimeInterval(30))
        #expect(watch.unknownCount == 2)
        #expect(!watch.isDrifting(at: start.addingTimeInterval(64)))
        #expect(watch.isDrifting(at: start.addingTimeInterval(65)))
        // A known notification resets the quiet.
        watch.observe(.updates([]), at: start.addingTimeInterval(66))
        #expect(!watch.isDrifting(at: start.addingTimeInterval(100)))
        watch.observe(.unknownNotification("a/b"), at: start.addingTimeInterval(101))
        #expect(watch.isDrifting(at: start.addingTimeInterval(126)))
        #expect(watch.unknownCount == 3)
        // The turn's end stops the watch; the next turn counts again from nothing.
        watch.observe(.turnEnded(.init(stopReason: "end_turn", failure: nil)), at: start.addingTimeInterval(127))
        #expect(!watch.isDrifting(at: start.addingTimeInterval(500)))
        watch.turnStarted(at: start.addingTimeInterval(600))
        #expect(watch.unknownCount == 0)
        watch.observe(.unknownNotification("a/b"), at: start.addingTimeInterval(601))
        #expect(!watch.isDrifting(at: start.addingTimeInterval(659)))
        #expect(watch.isDrifting(at: start.addingTimeInterval(660)))
    }

    // MARK: Credentials

    @Test func noLineNextTermWritesHoldsACredential() {
        var codex = CodexAppServer()
        let lines = [
            codex.initializeRequest(version: "1.0").line, CodexAppServer.initializedNotification(),
            codex.threadStartRequest(cwd: "/project", mcpServer: nil).line,
            codex.turnStartRequest(threadID: "thr_1", text: "hi").line, codex.accountReadRequest().line,
        ]
        for line in lines {
            let text = String(decoding: line, as: UTF8.self).lowercased()
            #expect(!text.contains("token"))
            #expect(!text.contains("apikey"))
            #expect(!text.contains("password"))
        }
        // account/read asks for no token refresh.
        let read = object(codex.accountReadRequest().line)
        #expect(read["params"]?["refreshToken"]?.bool != true)
    }
}
