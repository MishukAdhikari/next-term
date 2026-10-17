import Foundation
import Testing
@testable import NextTermCore

/// Answering a herdr agent's question (HerdrAnswer), as MCP, Peek, Go to Agent and a notice all do: the keys to the
/// choice, a read between them and Return, and nothing typed for a question that is not the one the caller saw.
@Suite struct HerdrAnswerTests {
    let list = AgentMenu(question: "Do you want to make this edit?", style: .list, choices: ["Yes", "Yes, always", "No"], highlighted: 0)
    let yesNo = AgentMenu(question: "Allow rm -rf build?", style: .yesNo, choices: ["Yes", "No"], highlighted: nil)

    func asked(_ menu: AgentMenu?, id: String = "q_1", text: String? = nil) -> HerdrAnswer.Asked {
        HerdrAnswer.Asked(id: id, text: text ?? menu?.question ?? "?", menu: menu)
    }

    @Test func aListIsAnsweredWithArrowsThenAReadThenReturn() throws {
        let plan = try HerdrAnswer.plan(asked(list), expected: "q_1", choice: 3, answer: nil).get()
        #expect(plan.moves == ["down", "down"] && plan.index == 2 && plan.label == "No" && plan.style == .list)
        // The cursor reached it, on the same question: Return.
        let there = AgentMenu(question: list.question, style: .list, choices: list.choices, highlighted: 2)
        #expect(HerdrAnswer.next(plan, now: asked(there)) == .pressReturn)
        // It did not, or the question changed or went away meanwhile: nothing more.
        #expect(HerdrAnswer.next(plan, now: asked(list)) == .refused(.cursorElsewhere(choice: "No")))
        #expect(HerdrAnswer.next(plan, now: asked(there, id: "q_2")) == .refused(.changedMeanwhile))
        #expect(HerdrAnswer.next(plan, now: nil) == .refused(.wentAway))
        // The cursor on the choice already: Return at once, with no read between.
        let first = try HerdrAnswer.plan(asked(list), expected: "q_1", choice: nil, answer: "yes").get()
        #expect(first.moves.isEmpty && HerdrAnswer.next(first, now: nil) == .pressReturn)
    }

    @Test func aYesOrNoIsItsLetterAndOneThatTookItIsAnswered() throws {
        let plan = try HerdrAnswer.plan(asked(yesNo), expected: "q_1", choice: 2, answer: nil).get()
        #expect(plan.moves == ["n"] && plan.label == "No")
        #expect(HerdrAnswer.next(plan, now: asked(yesNo)) == .pressReturn)
        #expect(HerdrAnswer.next(plan, now: nil) == .answered)
        #expect(HerdrAnswer.next(plan, now: asked(list, id: "q_9")) == .answered)
        #expect(try HerdrAnswer.plan(asked(yesNo), expected: "q_1", choice: nil, answer: "y").get().moves == ["y"])
    }

    @Test func aQuestionThatIsNotTheOneSeenTypesNothing() {
        #expect(HerdrAnswer.plan(nil, expected: "q_1", choice: 1, answer: nil) == .failure(.notAsking))
        #expect(HerdrAnswer.plan(asked(list, id: "q_2"), expected: "q_1", choice: 1, answer: nil)
            == .failure(.changed(question: list.question, id: "q_2")))
        #expect(HerdrAnswer.plan(asked(nil, text: "Continue?"), expected: "q_1", choice: 1, answer: nil) == .failure(.noChoices(question: "Continue?")))
        // A choice past the list, before anything is sent.
        guard case .failure(.badChoice(let why)) = HerdrAnswer.plan(asked(list), expected: "q_1", choice: 4, answer: nil) else {
            Issue.record("a fourth choice was planned")
            return
        }
        #expect(why.contains("1 to 3"))
        // A list that draws no cursor: the way there is unknown.
        let blind = AgentMenu(question: "Pick", style: .list, choices: ["a", "b"], highlighted: nil)
        #expect(HerdrAnswer.plan(asked(blind), expected: "q_1", choice: 2, answer: nil) == .failure(.noCursor(choice: "b")))
        #expect(HerdrAnswer.Refusal.changed(question: "Allow?", id: "q_2").sentence == "The question changed: it now asks “Allow?”. Nothing was typed.")
    }
}
