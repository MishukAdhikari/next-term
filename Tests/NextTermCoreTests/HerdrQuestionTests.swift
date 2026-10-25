import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// A blocked agent's question, read from its own pane (`herdr agent read --source visible`) the way a local agent's
/// screen is read, from hand-written stand-ins of what Claude Code and Codex draw.
@Suite struct HerdrQuestionTests {
    func fixture(_ name: String) throws -> String {
        try String(contentsOf: HerdrListingTests.fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func claudesQuestionAndItsThreeChoices() throws {
        let read = try #require(HerdrAgents.question(onScreen: try fixture("agent-read-visible-claude-question.txt")))
        #expect(read.text == "Do you want to make this edit to login.ts?")
        #expect(read.menu?.choices == ["Yes", "Yes, and don't ask again this session", "No, and tell Claude what to do differently"])
        #expect(read.menu?.style == .list && read.menu?.highlighted == 0)
    }

    @Test func codexsYesOrNo() throws {
        let read = try #require(HerdrAgents.question(onScreen: try fixture("agent-read-visible-codex-question.txt")))
        #expect(read.text == "Allow rm -rf build?")
        #expect(read.menu == AgentMenu(question: "Allow rm -rf build?", style: .yesNo, choices: ["Yes", "No"], highlighted: nil))
    }

    @Test func aScreenWithNoQuestionLeavesHerdrsWords() throws {
        #expect(HerdrAgents.question(onScreen: try fixture("agent-read-recent.txt")) == nil)
        var agents = HerdrAgents()
        _ = agents.update([HerdrAgent(paneID: "w2:p1", kind: "codex", status: .blocked, stateSeq: 4)], focusedTab: nil, tabVisible: false, now: 0)
        let read = HerdrAgents.question(onScreen: try fixture("agent-read-recent.txt"))
        agents.setQuestion(pane: "w2:p1", seq: 4, text: read?.text, choices: read?.menu?.choices ?? [])
        #expect(agents.activity == .asking("codex (w2:p1) needs a decision") && agents.nextRead == nil)
    }

    @Test func aStoredKeyInAChoiceIsMasked() throws {
        let value = "Rk7vQp2xLm9nWz4cTb8hYq3sJ6dF"
        let key = SymmetricKey(size: .bits256)
        let mask = SecretMask(key: key, marks: SecretMask.marks(for: SecretBytes(utf8: value), key: key))
        let screen = """
            Do you want to run curl -H \(value) api.example.com?
            ❯ 1. Yes
              2. Yes, and use \(value) again
              3. No, and tell Claude what to do differently (esc)
            """
        let read = try #require(HerdrAgents.question(onScreen: screen, mask: mask))
        #expect(read.text == "Do you want to run curl -H ••• api.example.com?")
        #expect(read.menu?.choices == ["Yes", "Yes, and use ••• again", "No, and tell Claude what to do differently"])
        let joined = (read.menu?.choices ?? []).joined()
        #expect(!joined.contains("Rk7vQ"))
    }
}
