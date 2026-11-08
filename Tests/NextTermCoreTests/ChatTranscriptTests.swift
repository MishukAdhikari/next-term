import Foundation
import Testing
@testable import NextTermCore

/// The chat tab's transcript (plan 037 U1): the blocks the native view draws from a session, with ids that stay put as
/// the session grows, the diff that tells the view what to touch, and the plain text MCP's `read_tab` gives.
@Suite struct ChatTranscriptTests {
    private func json(_ text: String) -> ACPWire.Value {
        let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        return parsed.flatMap { ACPWire.Value(serialized: $0) } ?? .null
    }

    private func update(_ body: String) -> ACPWire.Value { json(#"{"sessionId":"s1","update":"# + body + "}") }

    private func chunk(_ kind: String, _ text: String) -> ACPWire.Value {
        update(#"{"sessionUpdate":"\#(kind)","content":{"type":"text","text":"\#(text)"}}"#)
    }

    private func blocks(_ session: ACPSession, expanded: Set<String> = [], times: [Int: TimeInterval] = [:]) -> [ChatBlock] {
        ChatTranscript.blocks(from: session, expanded: expanded, thoughtTimes: times)
    }

    // MARK: blocks

    @Test func aTurnGivesItsPromptOneMessageAndItsClosingLine() {
        var session = ACPSession()
        session.prompted("hello")
        for text in ["Hi", " there", "!"] { session.apply(update: chunk("agent_message_chunk", text)) }
        let during = blocks(session)
        #expect(during.map(\.id) == ["item:0", "item:1"])
        #expect(during[0].content == .prompt(text: "hello"))
        #expect(during[1].content == .message(markdown: "Hi there!", streaming: true))
        session.apply(update: update(#"{"sessionUpdate":"usage_update","used":1200,"size":200000}"#))
        session.turnEnded("end_turn")
        let after = blocks(session)
        #expect(after.count == 3)
        #expect(after[1].content == .message(markdown: "Hi there!", streaming: false))
        #expect(after[2].content == .turnEnded(words: "Done", usage: "Context 1.2k of 200k", reason: .endTurn))
    }

    @Test func onlyTheLastClosingLineCarriesTheUsage() {
        var session = ACPSession()
        session.prompted("one")
        session.turnEnded("end_turn")
        session.prompted("two")
        session.apply(update: update(#"{"sessionUpdate":"usage_update","used":10,"size":100}"#))
        session.turnEnded("cancelled")
        let ends = blocks(session).compactMap { block -> ChatBlock.Content? in
            if case .turnEnded = block.content { return block.content }
            return nil
        }
        #expect(ends == [.turnEnded(words: "Done", usage: nil, reason: .endTurn),
                         .turnEnded(words: "Stopped", usage: "Context 10 of 100", reason: .cancelled)])
    }

    @Test func aToolCallAndItsUpdateGiveOneRow() throws {
        var session = ACPSession()
        session.prompted("test")
        session.apply(update: update(#"{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Bash(npm test)","kind":"execute","status":"in_progress"}"#))
        let running = try #require(blocks(session).last)
        #expect(running.id == "tool:t1")
        guard case .tool(let tool) = running.content else { Issue.record("not a tool"); return }
        #expect(tool.status == .inProgress)
        #expect(tool.statusWord == "running")
        #expect(!tool.expanded)
        session.apply(update: update(#"{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed","content":[{"type":"content","content":{"type":"text","text":"ok\n3 passed"}}]}"#))
        let rows = blocks(session)
        #expect(rows.count == 2)
        guard case .tool(let done) = rows[1].content else { Issue.record("not a tool"); return }
        #expect(done.status == .completed)
        #expect(done.output == "ok\n3 passed")
        #expect(done.title == "Bash(npm test)")
        #expect(done.kind == "execute")
        session.apply(update: update(#"{"sessionUpdate":"tool_call","toolCallId":"t2","title":"Bash(false)","status":"failed"}"#))
        guard case .tool(let failed) = blocks(session)[2].content else { Issue.record("not a tool"); return }
        #expect(failed.status == .failed)
        #expect(failed.statusWord == "failed")
    }

    @Test func aToolRowExpandsByItsID() {
        var session = ACPSession()
        session.prompted("x")
        session.apply(update: update(#"{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Read(a)","status":"completed"}"#))
        guard case .tool(let tool) = blocks(session, expanded: ["tool:t1"])[1].content else { Issue.record("not a tool"); return }
        #expect(tool.expanded)
    }

    @Test func anEditGivesItsToolThenAChangeRowAndAWriteACreatedOne() {
        var session = ACPSession()
        session.prompted("edit")
        session.apply(update: update(#"{"sessionUpdate":"tool_call","toolCallId":"e1","title":"Edit(src/a.swift)","kind":"edit","status":"in_progress","content":[{"type":"diff","path":"src/a.swift","oldText":"a\nb","newText":"a\nc\nd"}]}"#))
        session.apply(update: update(#"{"sessionUpdate":"tool_call","toolCallId":"w1","title":"Write(new.txt)","kind":"edit","status":"in_progress","content":[{"type":"diff","path":"new.txt","newText":"x"}]}"#))
        let rows = blocks(session)
        #expect(rows.map(\.id) == ["item:0", "tool:e1", "change:e1:0", "tool:w1", "change:w1:0"])
        #expect(rows[2].content == .change(ChatChange(toolID: "e1", path: "src/a.swift", added: 2, removed: 1, created: false)))
        #expect(rows[4].content == .change(ChatChange(toolID: "w1", path: "new.txt", added: 1, removed: 0, created: true)))
    }

    @Test func thinkingIsFoldedUntilExpandedAndTimed() {
        var session = ACPSession()
        session.prompted("why")
        session.apply(update: chunk("agent_thought_chunk", "Look"))
        session.apply(update: chunk("agent_thought_chunk", "ing at it"))
        let live = blocks(session)
        #expect(live[1].id == "item:1")
        guard case .thought(let thought) = live[1].content else { Issue.record("not a thought"); return }
        #expect(thought.text == "Looking at it")
        #expect(thought.folded)
        #expect(thought.thinking)
        #expect(thought.title == "Thinking\u{2026}")
        session.apply(update: chunk("agent_message_chunk", "Because"))
        guard case .thought(let timed) = blocks(session, times: [1: 12.4])[1].content else { Issue.record("not a thought"); return }
        #expect(timed.seconds == 12)
        #expect(!timed.thinking)
        #expect(timed.title == "Thought for 12 s")
        guard case .thought(let open) = blocks(session, expanded: ["item:1"])[1].content else { Issue.record("not a thought"); return }
        #expect(!open.folded)
        #expect(open.title == "Thought")
    }

    @Test func twoPlanUpdatesGiveOnePlanBlockWithTheLatestEntries() {
        var session = ACPSession()
        session.prompted("plan")
        session.apply(update: update(#"{"sessionUpdate":"plan","entries":[{"content":"one","status":"pending"}]}"#))
        session.apply(update: update(#"{"sessionUpdate":"plan","entries":[{"content":"one","status":"completed"},{"content":"two","status":"in_progress"}]}"#))
        let plans = blocks(session).filter { $0.id == "plan" }
        #expect(plans.count == 1)
        #expect(plans.first?.content == .plan([ACPSession.PlanEntry(content: "one", status: .completed),
                                               ACPSession.PlanEntry(content: "two", status: .inProgress)]))
        // A later turn's plan moves the one block there: the session keeps only the latest entries.
        session.turnEnded("end_turn")
        session.prompted("again")
        session.apply(update: update(#"{"sessionUpdate":"plan","entries":[{"content":"three","status":"pending"}]}"#))
        let all = blocks(session)
        #expect(all.filter { $0.id == "plan" }.count == 1)
        #expect(all.last?.id == "plan")
    }

    @Test func anAnsweredRequestIsARowAndAnOpenOneIsNot() throws {
        var session = ACPSession()
        session.prompted("clean")
        let params = json(#"{"toolCall":{"toolCallId":"b1","title":"Bash(rm -rf build)"},"options":[{"optionId":"allow_once","name":"Allow once","kind":"allow_once"},{"optionId":"reject_once","name":"Reject","kind":"reject_once"}]}"#)
        session.requested(permission: .number(5), params: params)
        #expect(!blocks(session).contains { if case .answered = $0.content { return true } else { return false } })
        _ = session.choose(0)
        let row = try #require(blocks(session).last)
        #expect(row.content == .answered(action: "Bash(rm -rf build)", answer: "Allow once", outcome: .allowed))
        #expect(ChatTranscript.answerLine(action: "Bash(rm -rf build)", answer: "Allow once") == "Allowed once: Bash(rm -rf build)")
        #expect(ChatTranscript.answerLine(action: "Bash(x)", answer: "Allow always") == "Allowed always: Bash(x)")
        #expect(ChatTranscript.answerLine(action: "Bash(x)", answer: "Reject") == "Rejected: Bash(x)")
        #expect(ChatTranscript.answerLine(action: "Bash(x)", answer: "Cancelled") == "Cancelled: Bash(x)")
        // A question's answer is the user's pick.
        #expect(ChatTranscript.answerLine(action: "Which database", answer: "Postgres") == "Which database: Postgres")
        #expect(ChatTranscript.outcome(of: "Reject") == .rejected)
        #expect(ChatTranscript.outcome(of: "Cancelled") == .cancelled)
        #expect(ChatTranscript.outcome(of: "Postgres") == .answered)
    }

    @Test func notesAreToldApartFromErrors() {
        var session = ACPSession()
        session.note("Claude Code 2.1.4")
        session.prompted("x")
        session.turnFailed("boom")
        let rows = blocks(session)
        #expect(rows.first?.content == .note(text: "Claude Code 2.1.4", tone: .info))
        #expect(rows.last?.content == .note(text: "The agent answered with an error: boom", tone: .error))
        #expect(ChatTranscript.tone(of: ClaudeStream.driftNote(version: nil, detail: nil)) == .warning)
        #expect(ChatTranscript.tone(of: CodexAppServer.driftLead) == .warning)
    }

    // MARK: diff

    @Test func aChunkOnTheLastMessageUpdatesOnlyThatBlock() {
        var session = ACPSession()
        session.prompted("go")
        session.apply(update: chunk("agent_message_chunk", "a"))
        let old = blocks(session)
        session.apply(update: chunk("agent_message_chunk", "b"))
        let change = ChatTranscript.diff(old: old, new: blocks(session))
        #expect(change.updated == ["item:1"])
        #expect(change.inserted.isEmpty && change.removed.isEmpty)
    }

    @Test func aNewToolIsInsertedAndNothingChangedIsEmpty() {
        var session = ACPSession()
        session.prompted("go")
        let old = blocks(session)
        session.apply(update: update(#"{"sessionUpdate":"tool_call","toolCallId":"t9","title":"Grep(x)","status":"pending"}"#))
        let new = blocks(session)
        let change = ChatTranscript.diff(old: old, new: new)
        #expect(change.inserted == ["tool:t9"])
        #expect(change.updated.isEmpty && change.removed.isEmpty)
        let none = ChatTranscript.diff(old: new, new: new)
        #expect(none.inserted.isEmpty && none.updated.isEmpty && none.removed.isEmpty)
        #expect(none.isEmpty)
    }

    @Test func aMovedBlockIsRemovedAndInsertedAgain() {
        let a = ChatBlock(id: "a", content: .note(text: "a", tone: .info))
        let b = ChatBlock(id: "b", content: .note(text: "b", tone: .info))
        let change = ChatTranscript.diff(old: [a, b], new: [b, a])
        #expect(Set(change.removed).isSubset(of: ["a", "b"]) && !change.removed.isEmpty)
        #expect(change.removed == change.inserted)
    }

    // MARK: plain text

    @Test func plainTextReadsAsTheSessionTabsTranscript() {
        var session = ACPSession()
        session.prompted("list files")
        session.apply(update: chunk("agent_thought_chunk", "hmm"))
        session.apply(update: update(#"{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Bash(ls)","status":"completed"}"#))
        session.apply(update: update(#"{"sessionUpdate":"tool_call","toolCallId":"e1","title":"Edit(src/a.swift)","status":"completed","content":[{"type":"diff","path":"src/a.swift","oldText":"a\nb","newText":"a\nc\nd"}]}"#))
        session.apply(update: update(#"{"sessionUpdate":"plan","entries":[{"content":"look","status":"completed"},{"content":"fix","status":"pending"}]}"#))
        session.apply(update: chunk("agent_message_chunk", "Here are **the** files"))
        session.turnEnded("end_turn")
        let text = ChatTranscript.plainText(blocks(session, times: [1: 3]), lastLines: 100)
        #expect(text.components(separatedBy: "\n") == [
            "\u{203A} list files",
            "\u{2234} Thought for 3 s",
            "\u{2713} Bash(ls) \u{00B7} done",
            "\u{2713} Edit(src/a.swift) \u{00B7} done",
            "    Edited src/a.swift (+2 \u{2212}1)",
            "  \u{2611} look",
            "  \u{2610} fix",
            "Here are **the** files",
            "Done",
        ])
    }

    @Test func plainTextKeepsALongCommandWholeAndGivesTheLastLines() {
        var session = ACPSession()
        let command = "Bash(" + String(repeating: "x", count: 300) + ")"
        session.prompted("go")
        session.apply(update: update(#"{"sessionUpdate":"tool_call","toolCallId":"t1","title":"\#(command)","status":"pending"}"#))
        let text = ChatTranscript.plainText(blocks(session), lastLines: 100)
        #expect(text.contains(command))
        session.apply(update: chunk("agent_message_chunk", "1\\n2\\n3\\n4\\n5\\n6"))
        let tail = ChatTranscript.plainText(blocks(session), lastLines: 5)
        #expect(tail == "2\n3\n4\n5\n6")
        #expect(ChatTranscript.plainText(blocks(session), lastLines: 0) == "")
    }

    @Test func aPromptOfSeveralLinesIndentsItsLaterOnes() {
        var session = ACPSession()
        session.prompted("one\ntwo")
        #expect(ChatTranscript.plainText(blocks(session), lastLines: 10) == "\u{203A} one\n  two")
    }

    // MARK: robustness

    @Test func oddSessionsNeverTrap() {
        var session = ACPSession()
        // Updates of the wrong shape, ids nobody sent, a tool update before its call, a permission with no options.
        for body in [#"{"sessionUpdate":"tool_call_update","toolCallId":"ghost","status":"completed"}"#,
                     #"{"sessionUpdate":"tool_call","toolCallId":7}"#,
                     #"{"sessionUpdate":"plan","entries":"no"}"#,
                     #"{"sessionUpdate":"agent_message_chunk","content":42}"#,
                     #"{"sessionUpdate":"tool_call","toolCallId":"d","content":[{"type":"diff","path":5,"newText":null}]}"#,
                     #"{"sessionUpdate":"usage_update","used":"lots","size":0}"#] {
            session.apply(update: update(body))
        }
        session.apply(update: .null)
        session.apply(update: json(#"{"update":[1,2]}"#))
        session.requested(permission: .null, params: json(#"{"options":[]}"#))
        session.turnEnded("nonsense")
        let rows = blocks(session, expanded: ["nothing"], times: [99: -5, 0: .infinity])
        _ = ChatTranscript.plainText(rows, lastLines: -3)
        _ = ChatTranscript.diff(old: rows, new: [])
        #expect(rows.contains { $0.id == "tool:ghost" })
    }

    @Test func aThoughtTimeThatIsNoNumberIsLeftOut() {
        var session = ACPSession()
        session.prompted("x")
        session.apply(update: chunk("agent_thought_chunk", "a"))
        session.turnEnded("end_turn")
        for time in [TimeInterval.nan, .infinity, -1] {
            guard case .thought(let thought) = blocks(session, times: [1: time])[1].content else { Issue.record("not a thought"); return }
            #expect(thought.seconds == nil, "\(time)")
        }
    }
}
