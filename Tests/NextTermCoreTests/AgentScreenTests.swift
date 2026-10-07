import Foundation
import Testing
@testable import NextTermCore

@Suite struct AgentScreenTests {
    @Test func claudeCodeWorkingAndIdle() {
        let working = [
            "> fix the login test",
            "",
            "✻ Pondering… (12s · ↓ 1.2k tokens · esc to interrupt)",
            "",
            "╭──────────────────────────────────────────╮",
            "│ >                                        │",
            "╰──────────────────────────────────────────╯",
            "  ⏵⏵ auto-accept edits on (shift+tab to cycle)",
        ]
        #expect(AgentScreen.activity(screenLines: working) == .working)
        let idle = [
            "⏺ Done. The login test passes now.",
            "",
            "╭──────────────────────────────────────────╮",
            "│ >                                        │",
            "╰──────────────────────────────────────────╯",
            "  ? for shortcuts                 ctx 31% · 14:02:17", // a status line clock keeps redrawing
        ]
        #expect(AgentScreen.activity(screenLines: idle) == .idle)
    }

    @Test func claudeCodePermissionPrompt() {
        let asking = [
            "╭──────────────────────────────────────────────────────────────╮",
            "│ Edit file                                                    │",
            "│ src/auth/login.ts                                            │",
            "│ Do you want to make this edit to login.ts?                   │",
            "│ ❯ 1. Yes                                                     │",
            "│   2. Yes, and don't ask again this session (shift+tab)       │",
            "│   3. No, and tell Claude what to do differently (esc)        │",
            "╰──────────────────────────────────────────────────────────────╯",
        ]
        #expect(AgentScreen.activity(screenLines: asking) == .asking("Do you want to make this edit to login.ts?"))
    }

    @Test func codexApprovalAndWorking() {
        let asking = [
            "  Would you like to run the following command?",
            "  $ npm test",
            "› 1. Yes, proceed",
            "  2. Yes, and don't ask again for commands that start with `npm`",
            "  3. No, and tell Codex what to do differently (esc)",
        ]
        #expect(AgentScreen.activity(screenLines: asking) == .asking("Would you like to run the following command?"))
        #expect(AgentScreen.activity(screenLines: ["• Working (5s • esc to interrupt)", "", "› Ask Codex to do anything"]) == .working)
    }

    @Test func commandCodeAndGemini() {
        let cc = ["Do you want to run npm install?", "❯ Yes", "  No", "↑↓ navigate · Enter to select · Esc to cancel"]
        #expect(AgentScreen.activity(screenLines: cc) == .asking("Do you want to run npm install?"))
        #expect(AgentScreen.activity(screenLines: ["⠋ Thinking esc to interrupt • 3s"]) == .working)
        #expect(AgentScreen.activity(screenLines: ["⠏ Reading files... (esc to cancel, 12s)"]) == .working)
    }

    @Test func aQuestionWithoutChoicesIsNotADecision() {
        // The agent's prose may ask a question; without choices on screen it is not blocked on you.
        #expect(AgentScreen.activity(screenLines: ["Do you want to refactor the parser next?", "> "]) == .idle)
        // Only the bottom of the screen counts: an old prompt scrolled far up is history.
        let old = ["Do you want to proceed?", "❯ 1. Yes"] + Array(repeating: "output", count: 40) + ["> "]
        #expect(AgentScreen.activity(screenLines: old) == .idle)
    }
}

@Suite struct AgentSyncTests {
    @Test func screenDecidesOnceItHasSpoken() {
        var s = TabStatus()
        s.commandStarted("claude", at: 0)
        s.observe(agentScreen: .working, at: 1)
        #expect(s.state == .working && s.screenSynced)
        // An idle agent redrawing its status line: output keeps coming, but the screen says idle.
        s.observe(agentScreen: .idle, at: 30)
        s.output(at: 31)
        s.output(at: 32)
        s.tick(at: 33)
        #expect(s.state == .done)
        #expect(s.takeNotice()?.stillRunning == true) // 29 s of work: notify
    }

    @Test func decisionsNotifyWithTheQuestion() {
        var s = TabStatus()
        s.commandStarted("codex", at: 0)
        s.observe(agentScreen: .working, at: 1)
        s.observe(agentScreen: .asking("Would you like to run the following command?"), at: 3)
        #expect(s.state == .attention)
        let notice = s.takeNotice()
        #expect(notice?.question == "Would you like to run the following command?")
        s.observe(agentScreen: .asking("Would you like to run the following command?"), at: 4)
        #expect(s.takeNotice() == nil) // the same question notifies once
        s.observe(agentScreen: .working, at: 6) // answered
        #expect(s.state == .working && s.question == nil)
    }

    @Test func unknownAgentsFallBackToOutputTiming() {
        var s = TabStatus()
        s.commandStarted("junie", at: 0)
        s.observe(agentScreen: .idle, at: 0.5) // nothing recognisable yet: timing decides
        s.output(at: 1)
        #expect(s.state == .working && !s.screenSynced)
        s.tick(at: 1 + TabStatus.quietAfter)
        #expect(s.state == .done)
    }

    @Test func plainCommandsShowNoSpinner() {
        var s = TabStatus()
        s.commandStarted("npm install", at: 0)
        #expect(s.running && s.state == .idle)
        s.commandFinished(exitCode: 1, at: 20)
        #expect(s.state == .failed) // still told how it ended
    }

    @Test func eachNewQuestionGetsANewNumber() {
        var s = TabStatus()
        s.commandStarted("claude", at: 0)
        s.observe(agentScreen: .asking("Do you want to make this edit to a.ts?"), at: 1)
        #expect(s.questionSerial == 1)
        s.observe(agentScreen: .asking("Do you want to make this edit to a.ts?"), at: 2) // the same one, still on screen
        #expect(s.questionSerial == 1)
        s.observe(agentScreen: .working, at: 3)
        s.observe(agentScreen: .asking("Do you want to make this edit to a.ts?"), at: 4) // same words, a new question
        #expect(s.questionSerial == 2)
        let tab = "4F1C"
        let first = AgentScreen.questionID(tab: tab, serial: 1, question: "Q?")
        #expect(first.hasPrefix("q_") && first.count == 18)
        #expect(first == AgentScreen.questionID(tab: tab.lowercased(), serial: 1, question: "Q?")) // stable
        #expect(first != AgentScreen.questionID(tab: tab, serial: 2, question: "Q?"))
        #expect(first != AgentScreen.questionID(tab: "other", serial: 1, question: "Q?"))
        #expect(first != AgentScreen.questionID(tab: tab, serial: 1, question: "R?"))
    }
}

@Suite struct AgentMenuTests {
    let claude = [
        "╭──────────────────────────────────────────────────────────────╮",
        "│ Edit file                                                    │",
        "│ Do you want to make this edit to login.ts?                   │",
        "│ ❯ 1. Yes                                                     │",
        "│   2. Yes, and don't ask again this session (shift+tab)       │",
        "│   3. No, and tell Claude what to do differently (esc)        │",
        "╰──────────────────────────────────────────────────────────────╯",
    ]

    @Test func claudeCodesListAndItsKeys() throws {
        let menu = try #require(AgentScreen.menu(screenLines: claude))
        #expect(menu.question == "Do you want to make this edit to login.ts?")
        #expect(menu.style == .list && menu.highlighted == 0)
        #expect(menu.choices == ["Yes", "Yes, and don't ask again this session", "No, and tell Claude what to do differently"])
        // Arrows to the choice, then Return: never the digit, which some agents take as the answer by itself.
        #expect(menu.keys(toPick: 0) == ["enter"])
        #expect(menu.keys(toPick: 2) == ["down", "down", "enter"])
        #expect(menu.keys(toPick: 3) == nil)
        // The cursor moved to "No": back up from there.
        var moved = claude
        moved[3] = "│   1. Yes                                                     │"
        moved[5] = "│ ❯ 3. No, and tell Claude what to do differently (esc)        │"
        #expect(try #require(AgentScreen.menu(screenLines: moved)).keys(toPick: 0) == ["up", "up", "enter"])
    }

    @Test func codexGeminiAndCommandCode() throws {
        let codex = try #require(AgentScreen.menu(screenLines: [
            "  Would you like to run the following command?",
            "  $ npm test",
            "› 1. Yes, proceed (y)",
            "  2. Yes, and don't ask again for commands that start with `npm` (a)",
            "  3. No, and tell Codex what to do differently (esc)",
        ]))
        #expect(codex.choices == ["Yes, proceed", "Yes, and don't ask again for commands that start with `npm`", "No, and tell Codex what to do differently"])
        #expect(codex.highlighted == 0)
        // Unnumbered, the cursor on the second line: the line above it is a choice too.
        let cc = try #require(AgentScreen.menu(screenLines: ["Do you want to run npm install?", "  Yes", "❯ No", "↑↓ navigate · Enter to select · Esc to cancel"]))
        #expect(cc.choices == ["Yes", "No"] && cc.highlighted == 1)
        #expect(cc.keys(toPick: 0) == ["up", "enter"])
        // No cursor drawn: where the arrows start is unknown, so no keys.
        let bare = try #require(AgentScreen.menu(screenLines: ["Do you want to proceed?", "1. Yes", "2. No"]))
        #expect(bare.highlighted == nil && bare.keys(toPick: 1) == nil)
    }

    @Test func yesNoPrompts() throws {
        let menu = try #require(AgentScreen.menu(screenLines: ["Do you want to overwrite config.json? (y/n)"]))
        #expect(menu.style == .yesNo && menu.choices == ["Yes", "No"])
        #expect(menu.keys(toPick: 0) == ["y", "enter"] && menu.keys(toPick: 1) == ["n", "enter"])
        #expect(menu.index(choice: nil, answer: "n") == .success(1))
        #expect(menu.index(choice: nil, answer: "Yes") == .success(0))
    }

    @Test func answersByNumberOrWords() throws {
        let menu = try #require(AgentScreen.menu(screenLines: claude))
        #expect(menu.index(choice: 3, answer: nil) == .success(2))
        #expect(menu.index(choice: nil, answer: "2") == .success(1))
        #expect(menu.index(choice: nil, answer: "yes") == .success(0)) // exact wins over the longer "Yes, and…"
        #expect(menu.index(choice: nil, answer: "No") == .success(2)) // the only choice starting so
        #expect(menu.index(choice: nil, answer: "Yes, and don’t") == .success(1)) // curly apostrophe
        guard case .failure(let range) = menu.index(choice: 4, answer: nil) else { Issue.record("4 of 3"); return }
        #expect(range.text.contains("1 to 3"))
        guard case .failure = menu.index(choice: nil, answer: "maybe") else { Issue.record("not a choice"); return }
        guard case .failure = menu.index(choice: nil, answer: nil) else { Issue.record("nothing given"); return }
    }

    @Test func noMenuWithoutAQuestion() {
        #expect(AgentScreen.menu(screenLines: ["⏺ Done.", "> "]) == nil)
        #expect(AgentScreen.menu(screenLines: ["Do you want to refactor the parser next?", "> "]) == nil)
    }
}
