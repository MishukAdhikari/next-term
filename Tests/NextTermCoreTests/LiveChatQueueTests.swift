import Foundation
import Testing
@testable import NextTermCore

/// Messages typed while Claude Code works: read into the turn they show as prompts where they were read; still waiting
/// they show at the foot, marked queued; taken as the next prompt they show once, as that prompt.
@Suite struct LiveChatQueueTests {
    func items(_ records: [[String: Any]]) -> [LiveChat.Item] {
        records.enumerated().flatMap { index, record in
            LiveChat.items(line: try! JSONSerialization.data(withJSONObject: record), at: index * 100, agent: .claude, masks: false)
        }
    }

    func enqueue(_ text: String) -> [String: Any] { ["type": "queue-operation", "operation": "enqueue", "content": text] }
    let dequeue: [String: Any] = ["type": "queue-operation", "operation": "dequeue"]
    func absorbed(_ text: String) -> [[String: Any]] {
        [["type": "queue-operation", "operation": "remove", "content": text, "reason": "absorbed_mid_turn"],
         ["type": "attachment", "attachment": ["type": "queued_command", "prompt": text, "commandMode": "prompt",
                                               "origin": ["kind": "human"], "humanTurn": true]]]
    }
    func user(_ text: String) -> [String: Any] { ["type": "user", "message": ["role": "user", "content": text]] }

    func prompts(_ blocks: [ChatBlock]) -> [String] {
        blocks.compactMap { if case .prompt(let text) = $0.content { return text } else { return nil } }
    }

    @Test func aMessageReadIntoTheTurnShowsAsAPrompt() {
        let blocks = LiveChat.blocks(items([user("fix it"), enqueue("also the docs")] + absorbed("also the docs")))
        #expect(prompts(blocks) == ["fix it", "also the docs"])
        #expect(!blocks.contains { if case .note = $0.content { return true } else { return false } })
    }

    @Test func aMessageStillWaitingShowsAtTheFootMarkedQueued() {
        let blocks = LiveChat.blocks(items([user("fix it"), enqueue("when you are done share the pr"), enqueue("it was mentioned")]))
        #expect(prompts(blocks) == ["fix it", "when you are done share the pr", "it was mentioned"])
        if case .note(let text, _) = blocks.last?.content { #expect(text.hasPrefix("2 queued")) } else { Issue.record("no queued note") }
    }

    @Test func oneTakenAsTheNextPromptShowsOnceAsThatPrompt() {
        // Claude Code's dequeue has no text: the oldest message leaves, and the prompt record follows.
        let blocks = LiveChat.blocks(items([user("fix it"), enqueue("next one"), dequeue, user("next one")]))
        #expect(prompts(blocks) == ["fix it", "next one"])
    }

    @Test func messagesNotTheUsersKeepTheQueuesOrderButNeverShow() {
        let blocks = LiveChat.blocks(items([enqueue("<task-notification>\n<task-id>x</task-id>"), enqueue("mine"), dequeue]))
        #expect(prompts(blocks) == ["mine"]) // the notice left first; mine still waits
    }

    @Test func takenBackTheyGo() {
        let one = LiveChat.blocks(items([enqueue("oops"), ["type": "queue-operation", "operation": "remove", "content": "oops"]]))
        #expect(prompts(one).isEmpty)
        let all = LiveChat.blocks(items([enqueue("a"), enqueue("b"), ["type": "queue-operation", "operation": "popAll"]]))
        #expect(prompts(all).isEmpty)
    }
}
