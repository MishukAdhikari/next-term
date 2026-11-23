import Testing
@testable import NextTermCore

/// The card an agent session's own request makes (plan 047).
@Suite struct ChatDecisionSessionTests {
    private func pending(_ params: ACPWire.Value, question: Bool = false, highlight: Int = 0) -> ACPSession.Permission {
        var session = ACPSession()
        session.requested(permission: .string("p"), params: params, question: question)
        if highlight != 0 { session.moveHighlight(highlight) }
        return session.pending!
    }

    @Test func aPermissionKeepsItsOptionsKindsAndHighlight() {
        let permission = pending(.object([
            "toolCall": .object(["toolCallId": .string("t"), "title": .string("Edit(Login.swift)")]),
            "options": .array([
                .object(["optionId": .string("a"), "name": .string("Allow"), "kind": .string("allow_once")]),
                .object(["optionId": .string("b"), "name": .string("Allow always"), "kind": .string("allow_always")]),
                .object(["optionId": .string("c"), "name": .string("Reject"), "kind": .string("reject_once")]),
            ]),
        ]), highlight: 2)
        let card = ChatDecision.from(permission: permission, agent: "Gemini CLI")
        #expect(card.title == permission.action)
        #expect(card.lead == "Gemini CLI asks to:")
        #expect(card.choices.map(\.name) == ["Allow", "Allow always", "Reject"])
        #expect(card.choices.map(\.number) == [1, 2, 3])
        #expect(card.choices.map(\.needsMac) == [false, true, false])
        #expect(card.highlighted == 2 && card.rejectIndex == 2 && card.defaultIndex == 0)
        #expect(!card.isQuestion)
        // The words the tab reports for it, so answer_agent's question is the card's.
        #expect(card.question == ACPTranscript.question(permission))
    }

    @Test func aQuestionHasNoLeadAndNoReject() {
        let permission = pending(.object([
            "toolCall": .object(["toolCallId": .string("q"), "title": .string("Which environment")]),
            "options": .array([
                .object(["optionId": .string("0"), "name": .string("Staging"), "kind": .string("allow_once")]),
                .object(["optionId": .string("1"), "name": .string("Production"), "kind": .string("allow_once")]),
            ]),
        ]), question: true, highlight: 1)
        let card = ChatDecision.from(permission: permission, agent: "Claude Code")
        #expect(card.isQuestion && card.lead == nil && card.rejectIndex == nil)
        #expect(card.title == permission.action + "?")
        #expect(card.highlighted == 1)
        #expect(card.question == ACPTranscript.question(permission))
    }
}
