import Foundation
import Testing
@testable import NextTermCore

/// The session journal (plan 047 U1): every change `nxtrm agent` makes to its session is written as a line, and the app's
/// replay of those lines holds the same session. Fixture lines only; no agent runs.
@Suite struct ACPSessionJournalTests {
    /// Collects what a recorder writes.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = Data()
        var data: Data { lock.lock(); defer { lock.unlock() }; return stored }
        func append(_ data: Data) { lock.lock(); stored.append(data); lock.unlock() }
    }

    private func recording() -> (ACPSession, Sink) {
        let sink = Sink()
        var session = ACPSession()
        session.recorder = ACPSessionJournal.Recorder { sink.append($0) }
        return (session, sink)
    }

    private func same(_ a: ACPSession, _ b: ACPSession) {
        #expect(a.items == b.items)
        #expect(a.tools == b.tools)
        #expect(a.plan == b.plan)
        #expect(a.pending == b.pending)
        #expect(a.working == b.working)
        #expect(a.lastStop == b.lastStop)
        #expect(a.commands == b.commands)
        #expect(a.usage == b.usage)
        #expect(ChatTranscript.blocks(from: a, expanded: [], thoughtTimes: [:])
                == ChatTranscript.blocks(from: b, expanded: [], thoughtTimes: [:]))
    }

    private func update(_ fields: [String: ACPWire.Value]) -> ACPWire.Value {
        .object(["update": .object(fields)])
    }

    private func chunk(_ kind: String, _ text: String) -> ACPWire.Value {
        update(["sessionUpdate": .string(kind), "content": .object(["type": .string("text"), "text": .string(text)])])
    }

    @Test func aStreamedTurnWithToolsAPlanAndAPermissionReplaysTheSame() {
        var (session, sink) = recording()
        session.note("Starting Claude Code (stream-json)…")
        session.prompted("Fix the login test")
        session.apply(update: chunk("agent_thought_chunk", "Reading "))
        session.apply(update: chunk("agent_thought_chunk", "the test"))
        session.apply(update: chunk("agent_message_chunk", "Let me "))
        session.apply(update: chunk("agent_message_chunk", "look."))
        session.apply(update: update(["sessionUpdate": .string("tool_call"), "toolCallId": .string("t1"),
                                      "title": .string("Bash(swift test)"), "kind": .string("execute"),
                                      "status": .string("in_progress")]))
        session.apply(update: update(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("t1"),
                                      "status": .string("completed")]))
        session.apply(update: update(["sessionUpdate": .string("plan"), "entries": .array([
            .object(["content": .string("Find the failing case"), "status": .string("completed")]),
            .object(["content": .string("Fix it"), "status": .string("in_progress")]),
        ])]))
        let params: ACPWire.Value = .object([
            "toolCall": .object(["toolCallId": .string("t2"), "title": .string("Edit(Login.swift)")]),
            "options": .array([
                .object(["optionId": .string("allow"), "name": .string("Allow"), "kind": .string("allow_once")]),
                .object(["optionId": .string("always"), "name": .string("Allow always"), "kind": .string("allow_always")]),
                .object(["optionId": .string("reject"), "name": .string("Reject"), "kind": .string("reject_once")]),
            ]),
        ])
        session.requested(permission: .string("p-1"), params: params)
        session.moveHighlight(1)
        session.moveHighlight(-1)
        _ = session.choose(0)
        session.apply(update: chunk("agent_message_chunk", "Fixed."))
        session.turnEnded("end_turn")

        let replayed = ACPSessionJournal.session(from: sink.data)
        same(session, replayed)
        #expect(replayed.items.contains(.message("Let me look.")))
        #expect(replayed.lastStop == .endTurn)
    }

    @Test func aWaitingPermissionAndAQuestionReplayAsCards() {
        var (session, sink) = recording()
        session.prompted("Deploy")
        let params: ACPWire.Value = .object([
            "toolCall": .object(["toolCallId": .string("q1"), "title": .string("Which environment?")]),
            "options": .array([
                .object(["optionId": .string("0"), "name": .string("Staging"), "kind": .string("allow_once")]),
                .object(["optionId": .string("1"), "name": .string("Production"), "kind": .string("allow_once")]),
            ]),
        ])
        session.requested(permission: .string("q-1"), params: params, question: true)
        session.moveHighlight(1)
        let replayed = ACPSessionJournal.session(from: sink.data)
        same(session, replayed)
        #expect(replayed.pending?.isQuestion == true)
        #expect(replayed.pending?.highlighted == 1)
        #expect(replayed.pending?.options.map(\.name) == ["Staging", "Production"])
    }

    @Test func aStoppedTurnAndAFailedOneReplayTheSame() {
        var (session, sink) = recording()
        session.prompted("one")
        let params: ACPWire.Value = .object(["options": .array([
            .object(["optionId": .string("a"), "name": .string("Allow"), "kind": .string("allow_once")]),
        ])])
        session.requested(permission: .number(7), params: params)
        _ = session.cancelPending()
        session.turnEnded("cancelled")
        session.prompted("two")
        session.turnFailed("rate limited")
        // A permission with no options changes nothing, here and in the replay.
        session.requested(permission: .number(8), params: .object(["options": .array([])]))
        same(session, ACPSessionJournal.session(from: sink.data))
    }

    @Test func aClaudeStreamTurnReplaysTheSame() {
        var (session, sink) = recording()
        var stream = ClaudeStream()
        session.prompted("go")
        let lines = [
            #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[]}},"parent_tool_use_id":null}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello, "}},"parent_tool_use_id":null}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"world."}},"parent_tool_use_id":null}"#,
            #"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"Hello, world."}]},"parent_tool_use_id":null}"#,
            #"{"type":"assistant","message":{"id":"msg_3","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls -la"}}]},"parent_tool_use_id":null}"#,
            #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"total 0","is_error":false}]},"parent_tool_use_id":null}"#,
        ]
        for line in lines {
            if case .updates(let updates) = stream.decode(Data(line.utf8)) { updates.forEach { session.apply(update: $0) } }
        }
        session.turnEnded(nil)
        let replayed = ACPSessionJournal.session(from: sink.data)
        same(session, replayed)
        #expect(replayed.items == [.prompt("go"), .message("Hello, world."), .tool("toolu_1"), .turnEnded(.endTurn)])
    }

    @Test func theReaderWaitsForAWholeLineAndSkipsWhatItDoesntKnow() {
        var data = ACPSessionJournal.line(.prompted("hi"))
        data.append(Data(#"{"v":2,"op":"something_newer","x":1}"#.utf8))
        data.append(0x0A)
        data.append(Data("not json\n".utf8))
        data.append(ACPSessionJournal.line(.note("done")))
        var reader = ACPSessionJournal.Reader()
        let cut = data.count - 5
        let first = reader.feed(data.prefix(cut))
        #expect(first == [.prompted("hi")])
        let rest = reader.feed(data.suffix(from: cut))
        #expect(rest == [.note("done")])
    }

    @Test func everyOpSurvivesItsLine() {
        let ops: [ACPSessionJournal.Op] = [
            .prompted("a\nb \"quoted\" /path"), .turnEnded(nil), .turnEnded("max_tokens"), .turnFailed("x"), .note("n"),
            .update(chunk("agent_message_chunk", "é ✓")), .requested(id: .number(3), params: .object([:]), question: true),
            .requested(id: .string("r"), params: .null, question: false), .highlight(-1), .chose(2), .cancelled,
        ]
        for op in ops {
            let line = ACPSessionJournal.line(op)
            #expect(line.last == 0x0A)
            #expect(!line.dropLast().contains(0x0A))
            #expect(ACPSessionJournal.op(line: line.dropLast()) == op)
        }
    }
}
