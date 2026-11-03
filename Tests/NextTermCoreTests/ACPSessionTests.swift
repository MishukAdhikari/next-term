import Foundation
import Testing
@testable import NextTermCore

/// Agent sessions (plan 030): the ACP wire, the session the agent's messages build, the transcript drawn from it, and
/// the menu a permission request becomes, which Next Term's agent reader has to read as any agent's question.
@Suite struct ACPSessionTests {
    private func value(_ json: String) -> ACPWire.Value {
        guard case .notification(_, let params) = ACPWire.decode(Data(#"{"jsonrpc":"2.0","method":"x","params":"#.utf8) + Data(json.utf8) + Data("}".utf8))! else {
            fatalError("not decoded")
        }
        return params
    }

    private func update(_ json: String) -> ACPWire.Value {
        value(#"{"sessionId":"s1","update":"# + json + "}")
    }

    @Test func theWireTellsResponsesRequestsAndNotificationsApart() {
        #expect(ACPWire.decode(Data(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}"#.utf8))
                == .response(id: .number(1), result: .object(["protocolVersion": .number(1)]), error: nil))
        #expect(ACPWire.decode(Data(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Authentication required"}}"#.utf8))
                == .response(id: .number(2), result: nil, error: "Authentication required"))
        #expect(ACPWire.decode(Data(#"{"jsonrpc":"2.0","id":"p1","method":"session/request_permission","params":{}}"#.utf8))
                == .request(id: .string("p1"), method: "session/request_permission", params: .object([:])))
        #expect(ACPWire.decode(Data(#"{"jsonrpc":"2.0","method":"session/update","params":{"a":true}}"#.utf8))
                == .notification(method: "session/update", params: .object(["a": .bool(true)])))
        // A true is a true and a 1 a number; a line that isn't JSON-RPC is passed over.
        #expect(ACPWire.decode(Data(#"{"jsonrpc":"2.0","method":"m","params":{"t":true,"n":1}}"#.utf8))
                == .notification(method: "m", params: .object(["t": .bool(true), "n": .number(1)])))
        #expect(ACPWire.decode(Data("Loading config...".utf8)) == nil)
    }

    @Test func linesToTheAgentAreOneLineWithWholeIds() {
        let request = String(decoding: ACPWire.request(id: 3, method: "session/prompt",
                                                       params: ACPWire.promptParams(session: "s", text: "two\nlines")), as: UTF8.self)
        #expect(request.hasSuffix("\n"))
        #expect(request.dropLast().contains("\n") == false)
        #expect(request.contains(#""id":3,"#))
        #expect(request.contains(#""text":"two\nlines""#))
        let answer = String(decoding: ACPWire.result(id: .string("p1"), ACPWire.permissionOutcome(optionID: "reject")), as: UTF8.self)
        #expect(answer.contains(#""outcome":{"optionId":"reject","outcome":"selected"}"#))
        let cancelled = String(decoding: ACPWire.result(id: .number(7), ACPWire.permissionOutcome(optionID: nil)), as: UTF8.self)
        #expect(cancelled.contains(#""outcome":{"outcome":"cancelled"}"#))
    }

    @Test func newSessionGivesNextTermsMCPServerOnStdio() {
        let params = ACPWire.newSessionParams(cwd: "/p", servers: [.init(name: "next-term", command: "/A/NextTerm", arguments: ["--cli", "mcp"])])
        let server = params["mcpServers"]?.array?.first
        #expect(server?["command"]?.string == "/A/NextTerm")
        #expect(server?["args"] == .array([.string("--cli"), .string("mcp")]))
        #expect(server?["env"] == .array([]))
        #expect(ACPWire.newSessionParams(cwd: "/p", servers: [])["mcpServers"] == .array([]))
    }

    @Test func aTurnBuildsTheConversationToolCallsAndPlan() {
        var session = ACPSession()
        session.prompted("list the TODOs")
        #expect(session.working)
        session.apply(update: update(#"{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"Looking"}}"#))
        session.apply(update: update(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"I found "}}"#))
        session.apply(update: update(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"three."}}"#))
        session.apply(update: update(#"{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Read src/app.py","kind":"read","status":"pending"}"#))
        session.apply(update: update(#"{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed"}"#))
        session.apply(update: update(#"{"sessionUpdate":"tool_call","toolCallId":"t2","title":"Edit app.py","kind":"edit","status":"completed","content":[{"type":"diff","path":"app.py","oldText":"a\nb","newText":"a\nc\nd"}]}"#))
        session.apply(update: update(#"{"sessionUpdate":"plan","entries":[{"content":"Find","status":"completed","priority":"high"},{"content":"Fix","status":"in_progress","priority":"high"}]}"#))
        session.apply(update: update(#"{"sessionUpdate":"plan","entries":[{"content":"Find","status":"completed","priority":"high"},{"content":"Fix","status":"completed","priority":"high"}]}"#))
        session.apply(update: update(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"All fixed."}}"#))
        session.turnEnded("end_turn")
        #expect(!session.working)
        #expect(session.lastStop == .endTurn)
        #expect(session.items == [.prompt("list the TODOs"), .thought("Looking"), .message("I found three."), .tool("t1"), .tool("t2"),
                                  .plan, .message("All fixed."), .turnEnded(.endTurn)])
        #expect(session.tools["t1"]?.status == .completed)
        #expect(session.tools["t2"]?.changes == [.init(path: "app.py", added: 2, removed: 1, created: false)])
        #expect(session.plan.map(\.status) == [.completed, .completed])
        #expect(session.lastMessage == "All fixed.")
        session.prompted("again")
        #expect(session.lastMessage == "")
    }

    @Test func eachStopReasonHasItsClosingLine() {
        #expect(ACPSession.StopReason.endTurn.words == "Done")
        #expect(ACPSession.StopReason.cancelled.words == "Stopped")
        #expect(ACPSession.StopReason.refusal.words == "Refused")
        #expect(ACPSession.StopReason.maxTokens.words == "Hit the token limit")
        #expect(ACPSession.StopReason.maxTurnRequests.words == "Hit the turn limit")
    }

    private let permission = #"{"sessionId":"s1","toolCall":{"toolCallId":"t9","title":"Run `rm -rf build`?","kind":"execute","status":"pending"},"options":[{"optionId":"a1","name":"Allow once","kind":"allow_once"},{"optionId":"a2","name":"Always allow","kind":"allow_always"},{"optionId":"r1","name":"Reject","kind":"reject_once"},{"optionId":"r2","name":"Always reject","kind":"reject_always"}]}"#

    @Test func aPermissionRequestOffersTheAgentsOptions() {
        var session = ACPSession()
        session.prompted("clean up")
        let asked = session.requested(permission: .string("p1"), params: value(permission))
        #expect(asked?.options.map(\.name) == ["Allow once", "Always allow", "Reject", "Always reject"])
        #expect(session.option(at: 1)?.kind == "allow_always")
        #expect(asked?.action == "Run `rm -rf build`")
        session.moveHighlight(1)
        session.moveHighlight(5)
        #expect(session.pending?.highlighted == 3)
        let picked = session.choose(2)
        #expect(picked?.requestID == .string("p1"))
        #expect(picked?.optionID == "r1")
        #expect(session.pending == nil)
        #expect(session.items.last == .permission(action: "Run `rm -rf build`", answer: "Reject"))
        // No options: nothing opens.
        let none = value(#"{"sessionId":"s1","toolCall":{"toolCallId":"t1"},"options":[]}"#)
        #expect(session.requested(permission: .number(4), params: none) == nil)
        #expect(session.pending == nil)
    }

    @Test func stoppingTheTurnCancelsTheOpenRequest() {
        var session = ACPSession()
        session.prompted("clean up")
        session.requested(permission: .number(9), params: value(permission))
        #expect(session.cancelPending() == .number(9))
        #expect(session.items.last == .permission(action: "Run `rm -rf build`", answer: "Cancelled"))
        session.turnEnded("cancelled")
        #expect(session.items.last == .turnEnded(.cancelled))
    }

    /// The menu is read by AgentScreen exactly as an agent's own: a question, its choices, the cursor, and the keys
    /// answer_agent presses. This is what makes the tab's mark, the notification's buttons and answer_agent work.
    @Test func thePermissionMenuReadsAsAnAgentsQuestion() {
        var session = ACPSession()
        session.prompted("clean up")
        session.apply(update: update(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"I'll remove the build folder."}}"#))
        session.requested(permission: .string("p1"), params: value(permission))
        let screen = ACPTranscript.lines(session, from: 0, width: 100).map(\.text)
            + [ACPTranscript.inputLine(session, typed: "", width: 100).text]
        let activity = AgentScreen.activity(screenLines: screen, mask: .empty)
        #expect(activity == .asking("Do you want to allow: Run `rm -rf build`?"))
        let menu = AgentScreen.menu(screenLines: screen, mask: .empty)
        #expect(menu?.choices == ["Allow once", "Always allow", "Reject", "Always reject"])
        #expect(menu?.style == .list)
        #expect(menu?.highlighted == 0)
        #expect(menu?.keys(toPick: 2) == ["down", "down", "enter"])
        // Answered, the question is gone from the screen.
        _ = session.choose(0)
        let after = ACPTranscript.lines(session, from: 0, width: 100).map(\.text)
        #expect(AgentScreen.activity(screenLines: after, mask: .empty) == .idle)
    }

    @Test func theTranscriptDrawsEachKindOnItsLines() {
        var session = ACPSession()
        session.note("Gemini CLI is ready.")
        session.prompted("summarise README")
        session.apply(update: update(#"{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Read README.md","kind":"read","status":"failed","content":[{"type":"content","content":{"type":"text","text":"No such file\nmore"}}]}"#))
        session.apply(update: update(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"It has no README."}}"#))
        session.turnEnded("refusal")
        let lines = ACPTranscript.lines(session, from: 0, width: 60)
        #expect(lines.map(\.text) == ["! Gemini CLI is ready.", "", "\u{203A} summarise README", "\u{2717} Read README.md \u{00B7} failed",
                                      "    No such file", "It has no README.", "Refused"])
        #expect(lines[3].style == .red)
        #expect(ACPTranscript.inputLine(session, typed: "next", width: 60).text == "\u{203A} next")
        session.prompted("go")
        #expect(ACPTranscript.inputLine(session, typed: "", width: 60).text == "Working \u{2014} \u{2303}C to stop")
    }

    @Test func longTextWrapsAtSpacesAndLongWordsBreak() {
        #expect(ACPTranscript.wrap("one two three four", width: 9, first: "", rest: "") == ["one two", "three", "four"])
        #expect(ACPTranscript.wrap("abcdefghij", width: 4, first: "", rest: "") == ["abcd", "efgh", "ij"])
        #expect(ACPTranscript.wrap("a\nb", width: 10, first: "> ", rest: "  ") == ["> a", "  b"])
    }

    @Test func installedAgentsAreTheKnownOnesOnThePath() {
        let present: Set<String> = ["/usr/local/bin/gemini", "/opt/bin/cursor-agent"]
        let found = ACPAgent.installed(path: "/usr/local/bin:/opt/bin") { present.contains($0) }
        #expect(found.map(\.id) == ["gemini", "cursor"])
        #expect(ACPAgent.named("cursor-agent")?.arguments == ["acp"])
        #expect(ACPAgent.named("Gemini")?.arguments == ["--acp"])
        #expect(ACPAgent.named("claude") == nil)
        #expect(ACPAgent.listed([]) == "none of them is installed here")
    }

    @Test func anAgentSessionIsAnAgentTabThatIsNoOtherAgent() {
        #expect(CommandClassifier.kind(of: "nxtrm agent gemini") == .agent)
        #expect(CommandClassifier.kind(of: "nxtrm agent --help") == .command)
        #expect(CommandClassifier.kind(of: "nxtrm agent") == .command)
        let process = ForegroundProcess(isShell: false, name: "NextTerm",
                                        arguments: ["/Applications/Next Term.app/Contents/MacOS/NextTerm", "--cli", "agent", "opencode"])
        #expect(CommandClassifier.kind(of: process) == .agent)
        // Never "opencode": OpenCode's own screen reader would read the session's text.
        #expect(CommandClassifier.programName(of: process) == "nxtrm agent")
        // The line new_tab and the menu type, by the launcher a build has.
        #expect(CommandClassifier.kind(of: "nxtrm agent gemini --prompt 'fix it'") == .agent)
        #expect(CommandClassifier.kind(of: "/Users/me/next-term/.build/debug/NextTerm --cli agent gemini") == .agent)
        #expect(CommandClassifier.programName("PATH=/x:$PATH /Users/me/next-term/.build/debug/NextTerm --cli agent gemini") == "nxtrm agent")
        #expect(CommandClassifier.programName("nxtrm agent opencode") == "nxtrm agent")
        #expect(CommandClassifier.programName("nxtrm .") == "nxtrm")
        let open = ForegroundProcess(isShell: false, name: "NextTerm", arguments: ["/A/NextTerm", "--cli", "."])
        #expect(CommandClassifier.kind(of: open) == .command)
    }

    @Test func aSessionsLineQuotesItsFirstPrompt() {
        let gemini = ACPAgent.named("gemini")!
        #expect(gemini.sessionLine(launcher: "nxtrm", prompt: nil) == "nxtrm agent gemini")
        #expect(gemini.sessionLine(launcher: "nxtrm", prompt: "  ") == "nxtrm agent gemini")
        #expect(gemini.sessionLine(launcher: "'/A B/nxtrm'", prompt: "fix Bob's test") == "'/A B/nxtrm' agent gemini --prompt 'fix Bob'\\''s test'")
    }
}
