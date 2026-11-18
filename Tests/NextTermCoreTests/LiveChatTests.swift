import Foundation
import Testing
@testable import NextTermCore

/// The live chat's readers (plan 041 U1), on made-up lines in each agent's shape.
@Suite struct LiveChatTests {
    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func read(_ lines: [String], _ agent: LiveChat.Agent, masks: Bool = false) -> [LiveChat.Kind] {
        var reader = LiveChat.Reader(agent: agent, masks: masks)
        return reader.feed(Data((lines.joined(separator: "\n") + "\n").utf8)).map(\.kind)
    }

    @Test func claudeTurnsReadAsPromptThinkingToolResultTextAndEnd() {
        let kinds = read([
            line(["type": "permission-mode", "permissionMode": "default"]),
            line(["type": "mode", "mode": "x"]),
            line(["type": "atis-latch", "atis": true]),
            line(["type": "session-owner", "accountUuid": "a"]),
            line(["type": "user", "message": ["role": "user", "content": "Fix the login test"]]),
            line(["type": "user", "isMeta": true, "message": ["role": "user", "content": "<local-command-caveat>x</local-command-caveat>"]]),
            line(["type": "assistant", "message": ["content": [["type": "thinking", "thinking": "Look at the test first."]]]]),
            line(["type": "assistant", "message": ["content": [["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "npm test\nmore"]]]]]),
            line(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "t1", "content": "1 failing", "is_error": true]]]]),
            line(["type": "assistant", "message": ["content": [["type": "text", "text": "The redirect loops."]]]]),
            line(["type": "system", "subtype": "turn_duration", "durationMs": 4200]),
            line(["type": "assistant", "isSidechain": true, "message": ["content": [["type": "text", "text": "a subagent's"]]]]),
            line(["type": "brand-new-record", "x": 1]),
        ], .claude)
        #expect(kinds == [
            .user("Fix the login test"),
            .thinking("Look at the test first."),
            .tool(LiveChat.ToolCall(id: "t1", name: "Bash", summary: "npm test")),
            .result(callID: "t1", output: "1 failing", isError: true),
            .text("The redirect loops."),
            .turnEnd(durationMs: 4200),
            .unknown("brand-new-record"),
        ])
    }

    @Test func editsWritesAndToDosBecomeDiffsAndPlans() {
        let kinds = read([
            line(["type": "assistant", "message": ["content": [["type": "tool_use", "id": "e", "name": "Edit",
                                                                "input": ["file_path": "/p/a.swift", "old_string": "a\nb", "new_string": "c"]]]]]),
            line(["type": "assistant", "message": ["content": [["type": "tool_use", "id": "w", "name": "Write",
                                                                "input": ["file_path": "/p/new.md", "content": "one\ntwo"]]]]]),
            line(["type": "assistant", "message": ["content": [["type": "tool_use", "id": "p", "name": "TodoWrite",
                                                                "input": ["todos": [["content": "Read", "status": "completed"],
                                                                                    ["content": "Fix", "status": "in_progress"],
                                                                                    ["content": "Test", "status": "pending"]]]]]]]),
        ], .claude)
        guard kinds.count == 3, case .tool(let edit) = kinds[0], case .tool(let write) = kinds[1], case .tool(let plan) = kinds[2] else {
            Issue.record("\(kinds)")
            return
        }
        #expect(edit.diff == LiveChat.Diff(path: "/p/a.swift", lines: ["-a", "-b", "+c"]))
        #expect(edit.diff?.added == 1 && edit.diff?.removed == 2)
        #expect(write.diff == LiveChat.Diff(path: "/p/new.md", lines: ["+one", "+two"]))
        #expect(plan.plan?.map(\.status) == [.done, .active, .pending])
    }

    @Test func codexRolloutReadsMessagesReasoningCallsPatchesAndTheEnd() {
        let kinds = read([
            line(["type": "session_meta", "payload": ["id": "x"]]),
            line(["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "<environment_context>cwd</environment_context>"]]]]),
            line(["type": "response_item", "payload": ["type": "message", "role": "developer", "content": [["type": "input_text", "text": "rules"]]]]),
            line(["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Add rate limits"]]]]),
            line(["type": "response_item", "payload": ["type": "reasoning", "summary": [["type": "summary_text", "text": "Plan it."]]]]),
            line(["type": "response_item", "payload": ["type": "function_call", "name": "shell", "call_id": "c1",
                                                      "arguments": "{\"command\":[\"rg\",\"limit\"]}"]]),
            line(["type": "response_item", "payload": ["type": "function_call_output", "call_id": "c1", "output": "none"]]),
            line(["type": "response_item", "payload": ["type": "custom_tool_call", "name": "apply_patch", "call_id": "c2",
                                                      "input": "*** Begin Patch\n*** Update File: src/a.ts\n@@\n-old\n+new\n*** End Patch"]]),
            line(["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Added a token bucket."]]]]),
            line(["type": "event_msg", "payload": ["type": "token_count"]]),
            line(["type": "event_msg", "payload": ["type": "task_complete", "duration_ms": 900]]),
            line(["type": "compacted", "payload": ["message": "x"]]),
        ], .codex)
        #expect(kinds.count == 8)
        #expect(kinds[0] == .user("Add rate limits"))
        #expect(kinds[1] == .thinking("Plan it."))
        #expect(kinds[2] == .tool(LiveChat.ToolCall(id: "c1", name: "shell", summary: "rg limit")))
        #expect(kinds[3] == .result(callID: "c1", output: "none", isError: false))
        if case .tool(let patch) = kinds[4] {
            #expect(patch.diff == LiveChat.Diff(path: "src/a.ts", lines: ["-old", "+new"]) && patch.summary == "src/a.ts")
        } else {
            Issue.record("\(kinds[4])")
        }
        #expect(kinds[5] == .text("Added a token bucket."))
        #expect(kinds[6] == .turnEnd(durationMs: 900))
        #expect(kinds[7] == .compacted)
    }

    @Test func commandCodeSessionsReadLikeAnthropicBlocks() {
        let kinds = read([
            line(["type": "session", "version": 3, "id": "s"]),
            line(["type": "message", "message": ["role": "user", "content": [["type": "text", "text": "Tidy the readme"]]]]),
            line(["type": "message", "message": ["role": "assistant", "content": [["type": "thinking", "thinking": "Read it."],
                                                                                  ["type": "tool_use", "id": "r", "name": "read_file", "input": ["file_path": "README.md"]]]]]),
            line(["type": "message", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "r", "content": [["type": "text", "text": "# Title"]]]]]]),
            line(["type": "message", "message": ["role": "assistant", "content": [["type": "text", "text": "Done."]]]]),
        ], .commandCode)
        #expect(kinds == [
            .user("Tidy the readme"),
            .thinking("Read it."),
            .tool(LiveChat.ToolCall(id: "r", name: "read_file", summary: "README.md")),
            .result(callID: "r", output: "# Title", isError: false),
            .text("Done."),
        ])
    }

    /// A line still being written waits; the ids are where each line starts, the same however the bytes arrive.
    @Test func aPartLineWaitsAndIdsAreTheLinesOffsets() {
        let first = line(["type": "user", "message": ["content": "one"]])
        let second = line(["type": "assistant", "message": ["content": [["type": "text", "text": "two"]]]])
        let bytes = Data((first + "\n" + second + "\n").utf8)
        var reader = LiveChat.Reader(agent: .claude, masks: false)
        let cut = first.utf8.count + 10
        let early = reader.feed(bytes.prefix(cut))
        let late = reader.feed(bytes.suffix(from: cut))
        #expect(early.map(\.id) == ["0#0"] && early.map(\.kind) == [.user("one")])
        #expect(late.map(\.id) == ["\(first.utf8.count + 1)#0"] && late.map(\.kind) == [.text("two")])
        #expect(reader.offset == bytes.count)
        var whole = LiveChat.Reader(agent: .claude, masks: false)
        #expect(whole.feed(bytes).map(\.id) == (early + late).map(\.id))
    }

    /// Read from inside a long file, the first (possibly cut) line is dropped.
    @Test func startedInsideAFileItDropsTheFirstLine() {
        let a = line(["type": "user", "message": ["content": "first"]])
        let b = line(["type": "user", "message": ["content": "second"]])
        let bytes = Data((a + "\n" + b + "\n").utf8)
        var reader = LiveChat.Reader(agent: .claude, start: 5, masks: false)
        #expect(reader.feed(bytes.suffix(from: 5)).map(\.kind) == [.user("second")])
        #expect(LiveChat.Reader.start(size: 10) == 0 && LiveChat.Reader.start(size: LiveChat.startBytes + 7) == 7)
    }

    @Test func keysInWhatIsShownAreMasked() {
        let token = "ghp_" + String(repeating: "a1B2", count: 9)
        let kinds = read([
            line(["type": "user", "message": ["content": "my token is \(token) ok"]]),
            line(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "t", "content": "API_KEY=\(token)"]]]]),
        ], .claude, masks: true)
        let shown = kinds.map { "\($0)" }.joined()
        #expect(!shown.contains(token) && shown.contains(MCPRedaction.mask))
    }

    @Test func longOutputsAreCut() {
        let kinds = read([line(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "t",
                                                                          "content": String(repeating: "x", count: 9_000)]]]])], .claude)
        guard case .result(_, let output, _) = kinds.first else { Issue.record("\(kinds)"); return }
        #expect(output.count == LiveChat.outputLimit + 2)
    }

    /// A Command Code tab's file: the resumed id's, else the newest written since the agent started in that folder.
    @Test func aCommandCodeTabsFileIsTheNewestOfItsFolderOrItsResumedOne() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-livechat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent(".commandcode/projects/p")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let folder = canonicalPath(home.path)
        func write(_ id: String, cwd: String, ago: TimeInterval) throws {
            let url = project.appendingPathComponent(id + ".jsonl")
            try (line(["type": "session", "id": id, "cwd": cwd]) + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ago)], ofItemAtPath: url.path)
        }
        try write("old", cwd: folder, ago: 3600)
        try write("new", cwd: folder, ago: 10)
        try write("elsewhere", cwd: "/somewhere/else", ago: 1)
        try "x".write(to: project.appendingPathComponent("new.checkpoints.jsonl"), atomically: true, encoding: .utf8)
        let since = Date().addingTimeInterval(-600)
        #expect(LiveChat.commandCodeFile(folder: folder, since: since, home: home.path)?.hasSuffix("/new.jsonl") == true)
        #expect(LiveChat.commandCodeFile(folder: folder, since: since, id: "old", home: home.path)?.hasSuffix("/old.jsonl") == true)
        #expect(LiveChat.commandCodeFile(folder: folder, since: Date().addingTimeInterval(5), home: home.path) == nil)
        #expect(LiveChat.commandCodeFile(folder: folder, since: since, id: "../x", home: home.path) == nil)
    }

    /// Items as the renderer's blocks: a result goes into its call's row, a call with no result runs until a turn end,
    /// an edit is followed by its change and a to-do list by its plan.
    @Test func itemsBecomeBlocksWithResultsInTheirRows() {
        let items: [LiveChat.Item] = [
            .init(id: "1", kind: .user("Fix it")),
            .init(id: "2", kind: .thinking("Look.")),
            .init(id: "3", kind: .tool(.init(id: "a", name: "Bash", summary: "npm test"))),
            .init(id: "4", kind: .result(callID: "a", output: "1 failing", isError: true)),
            .init(id: "5", kind: .tool(.init(id: "b", name: "Edit", summary: "/p/a.swift",
                                             diff: .init(path: "/p/a.swift", lines: ["-a", "+b", "+c"])))),
            .init(id: "6", kind: .tool(.init(id: "c", name: "TodoWrite", summary: "", plan: [.init(text: "Fix", status: .active)]))),
            .init(id: "7", kind: .text("Fixed.")),
            .init(id: "8", kind: .turnEnd(durationMs: 4_200)),
            .init(id: "9", kind: .tool(.init(id: "d", name: "Read", summary: "x"))),
            .init(id: "10", kind: .unknown("new")),
        ]
        let blocks = LiveChat.blocks(items, expanded: ["2"])
        #expect(blocks.map(\.id) == ["1", "2", "3", "5", "5#change", "6", "6#plan", "7", "8", "9"])
        guard case .thought(let thought) = blocks[1].content, case .tool(let bash) = blocks[2].content,
              case .tool(let edit) = blocks[3].content, case .change(let change) = blocks[4].content,
              case .plan(let plan) = blocks[6].content, case .turnEnded(let words, _, _) = blocks[8].content,
              case .tool(let running) = blocks[9].content else {
            Issue.record("\(blocks)")
            return
        }
        #expect(!thought.folded)
        #expect(bash.title == "Bash(npm test)" && bash.kind == "execute" && bash.status == .failed && bash.output == "1 failing")
        #expect(edit.status == .completed && edit.kind == "edit")
        #expect(change.added == 2 && change.removed == 1 && change.path == "/p/a.swift")
        #expect(plan.map(\.status) == [.inProgress])
        #expect(words == "Done in 4 s")
        #expect(running.status == .inProgress && running.kind == "read")
    }

    /// A question the agent's own screen asks, as the chat's card: "always" needs the Mac, "No" is Esc's.
    @Test func aScreensQuestionBecomesACard() {
        let card = ChatDecision.from(question: "Do you want to proceed?", choices: ["Yes", "Yes, and don't ask again", "No"],
                                     highlighted: 0, escape: 2)
        #expect(card.choices.map(\.number) == [1, 2, 3])
        #expect(card.choices.allSatisfy { !$0.needsMac })
        #expect(card.choices.map(\.kind) == ["allow_once", "allow_always", "reject_once"])
        #expect(card.rejectIndex == 2 && card.highlighted == 0 && !card.isQuestion)
        let pick = ChatDecision.from(question: "Which file?", choices: ["a.ts", "b.ts", "c.ts"], highlighted: 7, escape: nil)
        #expect(pick.isQuestion && pick.highlighted == 2)
    }

    @Test func onlyClaudeCodexAndCommandCodeHaveALiveChat() {
        #expect(LiveChat.Agent(.claude) == .claude && LiveChat.Agent(.codex) == .codex && LiveChat.Agent(.commandCode) == .commandCode)
        #expect(LiveChat.Agent(.gemini) == nil && LiveChat.Agent(.opencode) == nil)
    }
}
