import Testing
@testable import NextTermCore

/// An agent's spinner frame at the start of its title: left out when the tab's ring is still or off.
@Suite struct AgentTitleTests {
    @Test func aSpinnerFrameAtTheStartIsLeftOut() {
        #expect(AgentTitle.withoutSpinnerFrame("⠋ Fixing the tests") == "Fixing the tests")
        #expect(AgentTitle.withoutSpinnerFrame("◐ Reading files") == "Reading files")
        #expect(AgentTitle.withoutSpinnerFrame("⠹\u{00A0}x") == "x")
        // Claude Code's ✳ says it waits for you: a state, kept.
        #expect(AgentTitle.withoutSpinnerFrame("✳ Slack thread") == "✳ Slack thread")
        #expect(AgentTitle.withoutSpinnerFrame("zsh") == "zsh")
        #expect(AgentTitle.withoutSpinnerFrame("make ⠋") == "make ⠋")
        #expect(AgentTitle.withoutSpinnerFrame("") == "")
    }
}
