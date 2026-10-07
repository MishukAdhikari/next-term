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

/// Claude Code's question form (its AskUserQuestion tool), as Claude Code 2.1.280 draws it: each screen
/// was read from the real CLI in a pty, its model answered by a stand-in API.
@Suite struct ClaudeQuestionFormTests {
    static let form = [
        "❯ Ask me which approach to take",
        "────────────────────────────────────────────────────────────────────────────────────────────────────",
        " ☐ Approach",
        "",
        "Which approach should I take for the parser?",
        "",
        "❯ 1. Rewrite it",
        "     Start over with a cleaner design",
        "  2. Patch the bug",
        "     Smallest change that fixes the crash",
        "  3. Leave it",
        "     Ship as is and file an issue",
        "  4. Type something.",
        "────────────────────────────────────────────────────────────────────────────────────────────────────",
        "  5. Chat about this",
        "",
        "Enter to select · ↑/↓ to navigate · Esc to cancel",
    ]

    @Test func theModelsQuestionIsADecision() throws {
        #expect(AgentScreen.activity(screenLines: Self.form) == .asking("Which approach should I take for the parser?"))
        let menu = try #require(AgentScreen.menu(screenLines: Self.form))
        #expect(menu.question == "Which approach should I take for the parser?")
        // The model's options only: the row for an answer of your own and "Chat about this" are not choices.
        #expect(menu.choices == ["Rewrite it", "Patch the bug", "Leave it"])
        #expect(menu.highlighted == 0 && menu.keys(toPick: 1) == ["down", "enter"])
        // The cursor on the row of your own: the arrows still count from there.
        var other = Self.form
        other[6] = "  1. Rewrite it"
        other[12] = "❯ 4. Type something."
        let moved = try #require(AgentScreen.menu(screenLines: other))
        #expect(moved.highlighted == 3 && moved.keys(toPick: 0) == ["up", "up", "up", "enter"])
        // Below a long transcript: the form is still read in full.
        #expect(AgentScreen.activity(screenLines: Array(repeating: "output", count: 60) + Self.form) == .asking("Which approach should I take for the parser?"))
    }

    @Test func aLongQuestionWrapsWithAGutter() throws {
        let narrow = [
            "────────────────────────────────────────────────────────",
            " ☐ Deploy",
            "",
            "│ How should the website deploy when a release is tagged",
            "│ on the main branch of the repository?",
            "",
            "  1. On every tag",
            "     A workflow builds the site and pushes it to the",
            "     server whenever a release tag is created",
            "  2. By hand",
            "     Run the deploy script yourself",
            "  3. Nightly",
            "     A scheduled job",
            "  4. Never",
            "     Keep it as it is",
            "❯ 5. ab", // typed into the row of your own: its placeholder is gone
            "────────────────────────────────────────────────────────",
            "  6. Chat about this",
            "",
            "Enter to select · ↑/↓ to navigate · ctrl+g to edit in",
            "Vim · Esc to cancel",
        ]
        let asked = "How should the website deploy when a release is tagged on the main branch of the repository?"
        #expect(AgentScreen.activity(screenLines: narrow) == .asking(asked))
        let menu = try #require(AgentScreen.menu(screenLines: narrow))
        #expect(menu.choices == ["On every tag", "By hand", "Nightly", "Never"] && menu.highlighted == 4)
        // The options reach above what the host passed: still a decision, but no choices to pick.
        let cut = Array(narrow.suffix(14))
        #expect(AgentScreen.activity(screenLines: cut) == .asking(AgentScreen.formFallback))
        #expect(AgentScreen.menu(screenLines: cut) == nil)
    }

    @Test func previewsBesideTheOptions() throws {
        let preview = [
            " ☐ Layout",
            "",
            "Which layout do you prefer for the settings page?",
            "",
            "  1. Sidebar                      ┌──────────────────────────────────────────┐",
            "❯ 2. Tabs                         │ [General] [Keys]                         │",
            "                                  │  1. Font: Menlo                          │",
            "                                  │  Size: 13                                │",
            "                                  └──────────────────────────────────────────┘",
            "",
            "                                  Notes: press n to add notes",
            "",
            "────────────────────────────────────────────────────────────────────────────────────────────────────",
            "  Chat about this",
            "",
            "Enter to select · ↑/↓ to navigate · n to add notes · Esc to cancel",
        ]
        #expect(AgentScreen.activity(screenLines: preview) == .asking("Which layout do you prefer for the settings page?"))
        let menu = try #require(AgentScreen.menu(screenLines: preview))
        // No row of your own beside a preview; the numbered line inside the preview is not an option.
        #expect(menu.choices == ["Sidebar", "Tabs"] && menu.highlighted == 1)
    }

    @Test func severalQuestionsAndSeveralAnswers() throws {
        let first = [
            "←  ☐ Next  ☐ Scope  ✔ Submit  →",
            "",
            "What should I build next?",
            "",
            "❯ 1. Remote tabs",
            "     Terminal tabs on your servers over SSH",
            "  2. Import",
            "     Settings and shortcuts from other apps",
            "  3. Type something.",
            "────────────────────────────────────────────────────────────────────────────────────────────────────",
            "  4. Chat about this",
            "",
            "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
        ]
        #expect(AgentScreen.activity(screenLines: first) == .asking("What should I build next?"))
        #expect(try #require(AgentScreen.menu(screenLines: first)).choices == ["Remote tabs", "Import"])
        let several = [
            "←  ☐ Next  ☐ Scope  ✔ Submit  →",
            "",
            "Which parts should the release include?",
            "",
            "❯ 1. [ ] Docs",
            "         The site pages",
            "  2. [ ] Notes",
            "         Release notes",
            "  3. [ ] Screenshots",
            "         New images",
            "  4. [ ] Type something",
            "     Submit",
            "────────────────────────────────────────────────────────────────────────────────────────────────────",
            "  5. Chat about this",
            "",
            "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
        ]
        // A decision, but one choice and Return does not answer it: no menu to answer with.
        #expect(AgentScreen.activity(screenLines: several) == .asking("Which parts should the release include?"))
        #expect(AgentScreen.menu(screenLines: several) == nil)
        let review = [
            "←  ☐ Next  ☐ Scope  ✔ Submit  →",
            "",
            "Review your answers",
            "",
            "⚠ You have not answered all questions",
            "",
            "Ready to submit your answers?",
            "",
            "❯ 1. Submit answers",
            "  2. Cancel",
        ]
        #expect(AgentScreen.activity(screenLines: review) == .asking("Ready to submit your answers?"))
        let menu = try #require(AgentScreen.menu(screenLines: review))
        #expect(menu.choices == ["Submit answers", "Cancel"] && menu.highlighted == 0)
    }

    @Test func numberedListsInTheAgentsOutputAreNotQuestions() {
        let answered = [
            "⏺ User answered Claude's questions:",
            "  ⎿  · How should the website deploy when a release is",
            "     tagged on the main branch of the repository? → ab",
            "",
            "⏺ OK",
            "",
            "✻ Churned for 0s · done 6:18 PM",
            "",
            "────────────────────────────────────────────────────────",
            "❯",
            "────────────────────────────────────────────────────────",
            "  ⏸ manual mode on · ? for shortcuts · ← for agents",
        ]
        #expect(AgentScreen.activity(screenLines: answered) == .idle)
        let prose = [
            "⏺ Which approach should I take for the parser?",
            "",
            "  1. Rewrite it",
            "  2. Patch the bug",
            "  3. Type something.",
            "  4. Chat about this",
            "",
            "────────────────────────────────────────────────────────",
            "❯",
            "────────────────────────────────────────────────────────",
            "  ? for shortcuts",
        ]
        #expect(AgentScreen.activity(screenLines: prose) == .idle)
        #expect(AgentScreen.menu(screenLines: prose) == nil)
        // Another picker with the same hint, not a question to the user from the model.
        let picker = ["Select model", "", "❯ 1. Default (recommended)", "  2. Opus", "", "Enter to select · Esc to exit"]
        #expect(AgentScreen.activity(screenLines: picker) == .idle)
        // Such a list in the transcript with that picker open under it: the hint is the picker's, not the list's.
        let both = Array(prose.dropLast(3)) + picker
        #expect(AgentScreen.activity(screenLines: both) == .idle)
        #expect(AgentScreen.menu(screenLines: both) == nil)
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
