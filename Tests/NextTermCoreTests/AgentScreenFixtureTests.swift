import Foundation
import Testing
@testable import NextTermCore

/// Screens seen live (0.11.67) with real agents: Claude Code's, Codex's and Command Code's folder trust, Command Code's
/// "Build Your Coding Taste" and prompt, Codex finished on its usage limit and Codex updating itself. Each is read as the
/// tab reads it: its text with empty cells as blanks, its question and choices, and the state it leaves the tab in.
@Suite struct AgentScreenFixtureTests {
    /// Claude Code's folder trust as SwiftTerm gave it: every cell its cursor moves skipped over is U+0000.
    static let claudeTrust: [String] = [
        "────────────────────────────────────────────────────────────────────────────────",
        "\u{0}Accessing\u{0}workspace:",
        "",
        "\u{0}/Users/me/Code/app",
        "",
        "\u{0}Quick\u{0}safety\u{0}check:\u{0}Is\u{0}this\u{0}a\u{0}project\u{0}you\u{0}created\u{0}or\u{0}one\u{0}you\u{0}trust?\u{0}(Like\u{0}your\u{0}own\u{0}code,",
        "\u{0}a\u{0}well-known\u{0}open\u{0}source\u{0}project,\u{0}or\u{0}work\u{0}from\u{0}your\u{0}team).\u{0}If\u{0}not,\u{0}take\u{0}a\u{0}moment\u{0}to\u{0}review",
        "\u{0}what's\u{0}in\u{0}this\u{0}folder\u{0}first.",
        "",
        "\u{0}Claude\u{0}Code'll\u{0}be\u{0}able\u{0}to\u{0}read,\u{0}edit,\u{0}and\u{0}execute\u{0}files\u{0}here.",
        "",
        "\u{0}Security\u{0}guide",
        "",
        "\u{0}❯\u{0}1.\u{0}Yes,\u{0}I\u{0}trust\u{0}this\u{0}folder",
        "\u{0}\u{0}\u{0}2.\u{0}No,\u{0}exit",
        "",
        "\u{0}Enter\u{0}to\u{0}confirm\u{0}·\u{0}Esc\u{0}to\u{0}cancel",
    ]

    /// The same question unnumbered, its cursor moved to "No, exit", wrapped narrower.
    static let claudeTrustNo: [String] = [
        "\u{0}Accessing\u{0}workspace:",
        "",
        "\u{0}/Users/me/Code/app",
        "",
        "\u{0}Quick\u{0}safety\u{0}check:\u{0}Is\u{0}this\u{0}a\u{0}project\u{0}you\u{0}created\u{0}or\u{0}one\u{0}you",
        "\u{0}trust?\u{0}(Like\u{0}your\u{0}own\u{0}code,\u{0}a\u{0}well-known\u{0}open\u{0}source\u{0}project,\u{0}or\u{0}work",
        "\u{0}from\u{0}your\u{0}team).",
        "",
        "\u{0}\u{0}\u{0}Yes,\u{0}I\u{0}trust\u{0}this\u{0}folder",
        "\u{0}❯\u{0}No,\u{0}exit",
        "",
        "\u{0}Enter\u{0}to\u{0}confirm\u{0}·\u{0}Esc\u{0}to\u{0}cancel",
    ]

    static let codexTrust: [String] = [
        "> You are in /Users/me/Code/app",
        "",
        "  Trust this folder? Codex can read, edit, and run files here, and run commands as you allow.",
        "",
        "› 1. Trust and continue",
        "  2. Back to Agent Command Center",
        "",
        "  enter continue · esc back",
    ]

    static let codexUsageLimit: [String] = [
        "› fix the flaky login test",
        "",
        "• I fixed the race in LoginTests: the session now waits for the token before it reads it. The suite passes.",
        "",
        "■ You’ve hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit",
        "https://chatgpt.com/codex/settings/usage to purchase more credits or try again at 5:27 PM.",
        "",
        "› Ask Codex to do anything",
        "",
        "  ⚠ 5 warnings · f2 to view                                              100% context left",
    ]

    static let commandCodeTrust: [String] = [
        "╭──────────────────────────────────────────────────────────────────╮",
        "│ Do you trust the files in this folder?                           │",
        "│ /Users/me/Code/app                                               │",
        "│                                                                  │",
        "│ Command Code may read files in this folder. Reading untrusted    │",
        "│ files may lead Command Code to behave in unexpected ways.        │",
        "│                                                                  │",
        "│ With your permission Command Code may execute files in this      │",
        "│ folder. Executing untrusted code is unsafe.                      │",
        "│                                                                  │",
        "│ ❯ 1. Yes, proceed                                                │",
        "│   2. No, exit                                                    │",
        "╰──────────────────────────────────────────────────────────────────╯",
        "  ↑/↓ to navigate · enter to select · esc to exit",
    ]

    static let commandCodeTaste: [String] = [
        "┌────────────────────────────────────────────────────────────┐",
        "│ Build Your Coding Taste                                    │",
        "│                                                            │",
        "│ Found 3 sessions for this project. Analyze those sessions  │",
        "│ to build your coding taste package?                        │",
        "│                                                            │",
        "│ ❯ 1. Yes, learn (recommended)                              │",
        "│   2. Skip                                                  │",
        "│                                                            │",
        "│ ↑↓ · enter ok · esc skip · n never                         │",
        "└────────────────────────────────────────────────────────────┘",
    ]

    static let commandCodeReady: [String] = [
        "  Command Code v1.91.1",
        "  ~/Code/app",
        "",
        "╭──────────────────────────────────────────────────────────────────╮",
        "│ >                                                                │",
        "╰──────────────────────────────────────────────────────────────────╯",
        "  ? for shortcuts                                           glm-4.6",
    ]

    static let commandCodeWorking: [String] = [
        "> add a test for the parser",
        "",
        "⠋ Thinking… esc to interrupt • 12s • ↓ 1.2k tokens",
        "",
        "╭──────────────────────────────────────────────────────────────────╮",
        "│ >                                                                │",
        "╰──────────────────────────────────────────────────────────────────╯",
        "  ? for shortcuts                                           glm-4.6",
    ]

    // MARK: the text

    @Test func emptyCellsReadAsBlanks() {
        #expect(ScreenText.line("\u{0}Accessing\u{0}workspace:") == " Accessing workspace:")
        #expect(ScreenText.line("❯\u{0}No,\u{0}exit") == "❯ No, exit")
        #expect(ScreenText.line("plain") == "plain")
        #expect(ScreenText.trimmedLine("ok\u{0}\u{0} ") == "ok")
        #expect(ScreenText.character("\u{0}") == " " && ScreenText.character("a") == "a")
        #expect(ScreenText.isBlank("\u{0} \u{0}") && !ScreenText.isBlank(" x"))
        let shown = ScreenText.lines(Self.claudeTrust)
        #expect(!shown.joined().unicodeScalars.contains("\u{0}"))
        #expect(shown[1] == " Accessing workspace:")
        #expect(shown[13] == " ❯ 1. Yes, I trust this folder")
    }

    // MARK: questions and choices

    @Test func claudeCodeTrust() throws {
        let question = "Is this a project you created or one you trust?"
        #expect(AgentScreen.activity(screenLines: Self.claudeTrust) == .asking(question))
        #expect(AgentScreen.activity(screenLines: Self.claudeTrust, agent: .claude) == .asking(question))
        let menu = try #require(AgentScreen.menu(screenLines: Self.claudeTrust))
        #expect(menu.question == question)
        #expect(menu.choices == ["Yes, I trust this folder", "No, exit"] && menu.highlighted == 0)
        #expect(menu.index(choice: nil, answer: "No, exit") == .success(1))
        #expect(menu.keys(toPick: 1) == ["down", "enter"])
        // As answer_agent reads it: the question the tab reports, its choices from the same rows.
        #expect(AgentScreen.menu(asking: question, screenLines: Self.claudeTrust, shown: Self.claudeTrust) == menu)

        #expect(AgentScreen.activity(screenLines: Self.claudeTrustNo) == .asking(question))
        let moved = try #require(AgentScreen.menu(screenLines: Self.claudeTrustNo))
        #expect(moved.choices == ["Yes, I trust this folder", "No, exit"] && moved.highlighted == 1)
        let yes = try #require(try? moved.index(choice: nil, answer: "Yes, I trust this folder").get())
        #expect(moved.keys(toPick: yes) == ["up", "enter"])
    }

    @Test func codexTrust() throws {
        #expect(AgentScreen.activity(screenLines: Self.codexTrust) == .asking("Trust this folder?"))
        let menu = try #require(AgentScreen.menu(screenLines: Self.codexTrust))
        #expect(menu.choices == ["Trust and continue", "Back to Agent Command Center"] && menu.highlighted == 0)
        #expect(menu.index(choice: nil, answer: "Trust") == .success(0))
    }

    @Test func commandCodeTrust() throws {
        let question = "Do you trust the files in this folder?"
        #expect(AgentScreen.activity(screenLines: Self.commandCodeTrust, agent: .commandCode) == .asking(question))
        let menu = try #require(AgentScreen.menu(screenLines: Self.commandCodeTrust))
        #expect(menu.question == question)
        #expect(menu.choices == ["Yes, proceed", "No, exit"] && menu.highlighted == 0)
        #expect(menu.keys(toPick: 0) == ["enter"])
    }

    @Test func commandCodeTaste() throws {
        let question = "Analyze those sessions to build your coding taste package?"
        #expect(AgentScreen.activity(screenLines: Self.commandCodeTaste, agent: .commandCode) == .asking(question))
        let menu = try #require(AgentScreen.menu(screenLines: Self.commandCodeTaste))
        #expect(menu.choices == ["Yes, learn (recommended)", "Skip"] && menu.highlighted == 0)
        #expect(menu.index(choice: nil, answer: "Skip") == .success(1))
        // Without a question mark, the box's first row says what it asks.
        var titled = Self.commandCodeTaste
        titled[3] = "│ Found 3 sessions for this project.                         │"
        titled[4] = "│                                                            │"
        #expect(AgentScreen.activity(screenLines: titled) == .asking("Build Your Coding Taste"))
    }

    // MARK: states

    @Test func commandCodePromptWaits() {
        #expect(AgentScreen.activity(screenLines: Self.commandCodeReady, agent: .commandCode) == .waiting)
        #expect(AgentScreen.activity(screenLines: Self.commandCodeWorking, agent: .commandCode) == .working)
        // Its mode in place of the shortcuts hint.
        var accepting = Self.commandCodeReady
        accepting[6] = "  » accept edits on (shift+tab to cycle)"
        #expect(AgentScreen.activity(screenLines: accepting, agent: .commandCode) == .waiting)
        // Another agent's prompt with the same hint (Claude Code's) is read as every agent's.
        #expect(AgentScreen.activity(screenLines: Self.commandCodeReady, agent: .claude) == .idle)
        #expect(AgentScreen.activity(screenLines: Self.commandCodeReady) == .idle)
    }

    @Test func codexFinishedOnItsUsageLimitIsNoQuestion() {
        #expect(AgentScreen.activity(screenLines: Self.codexUsageLimit, agent: .codex) == .idle)
        #expect(AgentScreen.menu(screenLines: Self.codexUsageLimit) == nil)
    }

    @Test func codexUpdatingOrBlank() {
        #expect(AgentScreen.activity(screenLines: Array(repeating: "", count: 40), agent: .codex) == .blank)
        #expect(AgentScreen.activity(screenLines: Array(repeating: "\u{0}\u{0}   ", count: 40), agent: .codex) == .blank)
        #expect(AgentScreen.activity(screenLines: [], agent: .codex) == .blank)
        let updating = [
            "Updating Codex via `npm install -g @openai/codex@latest`...",
            "",
            "changed 1 package in 3s",
        ]
        #expect(AgentScreen.activity(screenLines: updating, agent: .codex) == .working)
        #expect(AgentScreen.activity(screenLines: updating + ["🎉 Update ran successfully! Please restart Codex."], agent: .codex) == .idle)
    }

    @Test func commandCodeTabFollowsItsScreen() {
        var s = TabStatus()
        s.commandStarted("cmd", at: 0)
        // It keeps drawing; its trust question syncs the tab with its screen.
        s.output(at: 0.5)
        #expect(s.state == .working)
        s.observe(agentScreen: AgentScreen.activity(screenLines: Self.commandCodeTrust, agent: .commandCode), at: 1)
        #expect(s.state == .attention && s.question == "Do you trust the files in this folder?")
        #expect(s.takeNotice()?.question == "Do you trust the files in this folder?")
        // Answered: its prompt, drawing all the while, is idle, and its startup is no turn.
        for t in stride(from: 2.0, through: 20, by: 0.25) {
            s.output(at: t)
            s.observe(agentScreen: AgentScreen.activity(screenLines: Self.commandCodeReady, agent: .commandCode), at: t)
            s.tick(at: t)
        }
        #expect(s.state == .idle && s.question == nil && s.takeNotice() == nil)
        // A turn: its working hint, then its prompt again, is a finish.
        s.observe(agentScreen: AgentScreen.activity(screenLines: Self.commandCodeWorking, agent: .commandCode), at: 30)
        #expect(s.state == .working)
        for t in stride(from: 40.0, through: 45, by: 0.25) {
            s.output(at: t)
            s.observe(agentScreen: AgentScreen.activity(screenLines: Self.commandCodeReady, agent: .commandCode), at: t)
            s.tick(at: t)
        }
        #expect(s.state == .done && s.takeNotice()?.topic == .agentFinished)
    }

    @Test func codexBlankWhileUpdatingStaysWorking() {
        var s = TabStatus()
        s.commandStarted("codex", at: 0)
        s.output(at: 0.5)
        #expect(s.state == .working)
        for t in stride(from: 1.0, through: 30, by: 0.25) {
            s.observe(agentScreen: AgentScreen.activity(screenLines: Array(repeating: "", count: 40), agent: .codex), at: t)
            s.tick(at: t)
        }
        #expect(s.state == .working && s.takeNotice() == nil)
    }

    @Test func codexFinishedTurnIsDone() {
        var s = TabStatus()
        s.commandStarted("codex", at: 0)
        s.observe(agentScreen: .working, at: 1)
        s.observe(agentScreen: AgentScreen.activity(screenLines: Self.codexUsageLimit, agent: .codex), at: 20)
        s.tick(at: 22)
        #expect(s.state == .done && s.question == nil)
        #expect(s.takeNotice()?.topic == .agentFinished)
        // It rings as it finishes: a notice, and the tab still says done, not attention.
        s.bell(at: 23)
        #expect(s.takeNotice()?.topic == .programAlert)
        #expect(s.state == .done)
        s.bell(at: 24)
        #expect(s.takeNotice() == nil && s.state == .done)
        // The same bell while it works may be a question its screen doesn't show: amber, as before.
        s.observe(agentScreen: .working, at: 30)
        s.bell(at: 31)
        #expect(s.state == .attention)
    }
}
