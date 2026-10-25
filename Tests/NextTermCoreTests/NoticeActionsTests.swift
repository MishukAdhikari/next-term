import CryptoKit
import Foundation
import Testing
@testable import NextTermCore

/// The buttons on an agent's notice (NoticeActions): a decision's choices, four at most, and Reply on a finish.
@Suite struct NoticeActionsTests {
    @Test func twoChoicesAreTwoButtonsAndFiveAreNone() {
        #expect(NoticeActions.plan(choices: ["Yes", "No"]) == [NoticeActions.Action(id: "choice.1", title: "1 Yes"),
                                                                NoticeActions.Action(id: "choice.2", title: "2 No")])
        #expect(NoticeActions.plan(choices: ["a", "b", "c", "d", "e"]) == nil)
        #expect(NoticeActions.plan(choices: []) == nil)
        #expect(NoticeActions.choice("choice.2") == 2 && NoticeActions.choice("choice.5") == nil && NoticeActions.choice("reply") == nil)
    }

    @Test func titlesAreCutAndMasked() {
        let long = String(repeating: "x", count: 60)
        let cut = NoticeActions.plan(choices: [long])?.first?.title ?? ""
        #expect(cut.count == 2 + NoticeActions.titleLength && cut.hasSuffix("…"))
        let value = "Rk7vQp2xLm9nWz4cTb8hYq3sJ6dF"
        let key = SymmetricKey(size: .bits256)
        let mask = SecretMask(key: key, marks: SecretMask.marks(for: SecretBytes(utf8: value), key: key))
        #expect(NoticeActions.plan(choices: ["Use \(value)"], mask: mask)?.first?.title == "1 Use •••")
    }

    @Test func aStaleQuestionPlansNoKeysAndAReplyWithAStoredKeyIsRefused() {
        let menu = AgentMenu(question: "Allow?", style: .yesNo, choices: ["Yes", "No"], highlighted: nil)
        let now = HerdrAnswer.Asked(id: "q_new", text: "Allow?", menu: menu)
        #expect(HerdrAnswer.plan(now, expected: "q_old", choice: 1, answer: nil) == .failure(.changed(question: "Allow?", id: "q_new")))
        let value = "Rk7vQp2xLm9nWz4cTb8hYq3sJ6dF"
        let key = SymmetricKey(size: .bits256)
        let mask = SecretMask(key: key, marks: SecretMask.marks(for: SecretBytes(utf8: value), key: key))
        #expect(HerdrCommand.textRefusal("use \(value) now", mask: mask) != nil)
        #expect(HerdrCommand.textRefusal("run the tests", mask: mask) == nil)
    }

    @Test func theCategoriesKeepTheNewestSixtyFourAndTheFinishOnes() {
        var kept: [String] = []
        for index in 0..<70 { kept = NoticeActions.kept(kept, adding: NoticeActions.category(for: "t/p\(index)")) }
        #expect(kept.count == NoticeActions.maxCategories && kept.first == NoticeActions.finishCategory)
        #expect(kept.last == "agent.t/p69" && !kept.contains("agent.t/p0"))
        // Added again: once, as the newest.
        kept = NoticeActions.kept(kept, adding: "agent.t/p30")
        #expect(kept.filter { $0 == "agent.t/p30" }.count == 1 && kept.last == "agent.t/p30")
        #expect(NoticeActions.kept([], adding: NoticeActions.finishCategory) == [NoticeActions.finishCategory])
    }
}
