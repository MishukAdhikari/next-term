import Foundation
import Testing
@testable import NextTermCore

/// OpenCode's screens, made up in the layout OpenCode 1.19's TUI draws (its prompt footer, permission.tsx and
/// question.tsx): the session column with its "┃" box border, the prompt hidden while OpenCode asks, and the
/// footer under the prompt. The 2.x rows are the ones read from OpenCode 2.0's source.
enum OpencodeScreens {
    static let transcript = [
        "  ┃  fix the login test",
        "",
        "     I'll run the tests first, then look at the failing case.",
        "",
    ]

    static func footer(_ left: String, right: String = "12.4K (6%) · $0.03  ctrl+p commands") -> [String] {
        [
            "  ┃",
            "  ┃  Build · claude-sonnet-4-5 Anthropic",
            "  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀",
            left.padding(toLength: 64, withPad: " ", startingAt: 0) + right,
        ]
    }

    static let working = transcript + footer("   ■■■⬝⬝⬝⬝⬝ esc interrupt")
    static let ready = transcript + footer("   ~/code/shop")

    static let shellPermission = transcript + [
        "  ┃",
        "  ┃  △ Permission required",
        "  ┃    # Shell command",
        "  ┃",
        "  ┃  $ npm test",
        "  ┃",
        "  ┃",
        "  ┃   Allow once   Allow always   Reject                  ctrl+f fullscreen  ⇆ select  enter confirm",
        "  ┃",
    ]

    static let editPermission = transcript + [
        "  ┃",
        "  ┃  △ Permission required",
        "  ┃    → Edit src/app.ts",
        "  ┃",
        "  ┃   1   import { login } from \"./auth\"",
        "  ┃   2 - const retries = 1",
        "  ┃   2 + const retries = 3",
        "  ┃",
        "  ┃   Allow once   Allow always   Reject                  ctrl+f fullscreen  ⇆ select  enter confirm",
        "  ┃",
    ]

    /// OpenCode 2.x: no title line for a shell request, and "Always allow" in the buttons.
    static let shellPermission2 = transcript + [
        "  ┃",
        "  ┃  △ Permission required",
        "  ┃",
        "  ┃  $ npm test",
        "  ┃",
        "  ┃",
        "  ┃   Allow once   Always allow   Reject                  ctrl+f fullscreen  ⇆ select  enter confirm",
        "  ┃",
    ]

    static let alwaysAllow = transcript + [
        "  ┃",
        "  ┃  △ Always allow",
        "  ┃",
        "  ┃  This will allow bash until OpenCode is restarted.",
        "  ┃",
        "  ┃",
        "  ┃   Confirm   Cancel                                                   ⇆ select  enter confirm",
        "  ┃",
    ]

    static let rejectMessage = transcript + [
        "  ┃",
        "  ┃  △ Reject permission",
        "  ┃",
        "  ┃  Tell OpenCode what to do differently",
        "  ┃",
        "  ┃",
        "  ┃                                                              enter confirm  esc cancel",
        "  ┃",
    ]

    static let question = transcript + [
        "  ┃",
        "  ┃  Which database should the tests use?",
        "  ┃",
        "  ┃  1. Postgres",
        "  ┃     The same as production",
        "  ┃  2. SQLite",
        "  ┃     Faster, in a file",
        "  ┃  3. Type your own answer",
        "  ┃",
        "  ┃  ↑↓ select  enter submit  esc dismiss",
        "  ┃",
    ]

    /// Several questions: the question's tabs above it, "⇆ tab" in the hints.
    static let questions = transcript + [
        "  ┃",
        "  ┃   Database   Runner   Confirm",
        "  ┃",
        "  ┃  Which database should the tests use?",
        "  ┃",
        "  ┃  1. Postgres",
        "  ┃  2. SQLite",
        "  ┃  3. Type your own answer",
        "  ┃",
        "  ┃  ⇆ tab  ↑↓ select  enter confirm  esc dismiss",
        "  ┃",
    ]

    /// Sidebar text OpenCode draws beside the session in a pane wider than 120 columns.
    static let sidebar = ["Fix the login test", "", "Context", "12,431 tokens", "6% used", "$0.03 spent", "",
                          "LSP", "• typescript", "", "Modified Files", "src/app.ts +3 -1", "", "~/code/shop:main"]

    /// `rows` 98 columns wide, with the sidebar's 42 beside them, as OpenCode draws 140 columns.
    static func withSidebar(_ rows: [String]) -> [String] {
        rows.enumerated().map { index, row in
            let session = row.count < 98 ? row.padding(toLength: 98, withPad: " ", startingAt: 0) : row
            return session + "  " + sidebar[index % sidebar.count]
        }
    }

    /// `rows` with the "│" gutter some themes and multiplexers show in place of "┃".
    static func withThinBorder(_ rows: [String]) -> [String] {
        rows.map { $0.replacingOccurrences(of: "┃", with: "│") }
    }
}

@Suite struct AgentScreenOpencodeTests {
    func read(_ lines: [String]) -> AgentActivity { AgentScreen.activity(screenLines: lines, opencode: true) }

    @Test func workingWhileTheInterruptHintShows() {
        #expect(read(OpencodeScreens.working) == .working)
        #expect(read(OpencodeScreens.transcript + OpencodeScreens.footer("   ■■■⬝⬝⬝⬝⬝ esc again to interrupt")) == .working)
        #expect(read(OpencodeScreens.transcript + OpencodeScreens.footer("   [⋯] esc interrupt", right: "")) == .working)
        // The --mini footer, on the main screen.
        #expect(read(["  fix the login test", "", " ⬝■■ esc stop"]) == .working)
        // Claude Code's hint is not OpenCode's: in an OpenCode tab it is read as every agent's hint.
        #expect(read(["✻ Pondering… (12s · esc to interrupt)"]) == .working)
    }

    @Test func readyWhileItsOwnFooterShowsAlone() {
        #expect(read(OpencodeScreens.ready) == .ready)
        // The keys are the user's own: any key word before "commands" or "agents".
        for right in ["ctrl+k commands", "f1 commands", "ctrl+x p commands", "tab agents  ctrl+p commands", "tab agents"] {
            #expect(read(OpencodeScreens.transcript + OpencodeScreens.footer("   ~/code/shop", right: right)) == .ready, "\(right)")
        }
        // Shell mode's footer.
        #expect(read(OpencodeScreens.transcript + OpencodeScreens.footer("   ~/code/shop", right: "esc exit shell mode")) == .ready)
        // The home screen's empty prompt, before any footer is drawn.
        #expect(read(["", "  ┃  Ask anything… \"Fix a TODO in the codebase\"", "  ┃", "  ┃  Build · gpt-5 OpenAI"]) == .ready)
        // "commands" in prose, without a key word before it at the footer's place, is not the footer.
        for prose in ["     Here are the commands", "     I ran the shell commands", "     It found 3 commands", "     Run these commands  to see"] {
            #expect(read(OpencodeScreens.transcript + [prose]) == .idle, "\(prose)")
        }
    }

    @Test func permissionPrompts() {
        #expect(read(OpencodeScreens.shellPermission) == .asking("Permission required: Shell command ($ npm test)"))
        #expect(read(OpencodeScreens.editPermission) == .asking("Permission required: Edit src/app.ts"))
        #expect(read(OpencodeScreens.shellPermission2) == .asking("Permission required: $ npm test"))
        // OpenCode 2.x with nothing to save: two buttons.
        var twoButtons = OpencodeScreens.shellPermission2
        twoButtons[twoButtons.count - 2] = "  ┃   Allow once   Reject                       ctrl+f fullscreen  ⇆ select  enter confirm"
        #expect(read(twoButtons) == .asking("Permission required: $ npm test"))
        // Narrow: the hints go under the buttons.
        var narrow = OpencodeScreens.editPermission
        narrow.insert(contentsOf: ["  ┃", "  ┃   ctrl+f fullscreen  ⇆ select  enter confirm"], at: narrow.count - 1)
        narrow[narrow.count - 4] = "  ┃   Allow once   Allow always   Reject"
        #expect(read(narrow) == .asking("Permission required: Edit src/app.ts"))
    }

    @Test func theStepsAfterAPermissionPrompt() {
        #expect(read(OpencodeScreens.alwaysAllow) == .asking("Always allow: This will allow bash until OpenCode is restarted."))
        #expect(read(OpencodeScreens.rejectMessage) == .asking("Reject permission: Tell OpenCode what to do differently"))
    }

    @Test func theQuestionForm() {
        #expect(read(OpencodeScreens.question) == .asking("Which database should the tests use?"))
        #expect(read(OpencodeScreens.questions) == .asking("Which database should the tests use?"))
        // Several answers: the hint is dropped from the words.
        var many = OpencodeScreens.question
        many[many.count - 10] = "  ┃  Which checks should run? (select all that apply)"
        many[many.count - 8] = "  ┃  1. [ ] Lint"
        many[many.count - 6] = "  ┃  2. [✓] Unit tests"
        many[many.count - 4] = "  ┃  3. [ ] Type your own answer"
        many[many.count - 2] = "  ┃  ⇆ tab  ↑↓ select  enter toggle  esc dismiss"
        #expect(read(many) == .asking("Which checks should run?"))
        // A question that turns the typed answer off has no row for it.
        var fixed = OpencodeScreens.question
        fixed.remove(at: fixed.count - 4)
        #expect(read(fixed) == .asking("Which database should the tests use?"))
        // A long question wraps.
        var long = OpencodeScreens.question
        long[long.count - 10] = "  ┃  Which database should the tests use when they run in CI and on"
        long.insert("  ┃  each developer's machine?", at: long.count - 9)
        #expect(read(long) == .asking("Which database should the tests use when they run in CI and on each developer's machine?"))
    }

    @Test func theReviewOfSeveralAnswers() {
        let review = OpencodeScreens.transcript + [
            "  ┃",
            "  ┃   Database   Runner   Confirm",
            "  ┃",
            "  ┃  Review",
            "  ┃",
            "  ┃  Database: SQLite",
            "  ┃",
            "  ┃  Runner: (not answered)",
            "  ┃",
            "  ┃  ⇆ tab  enter submit  esc dismiss",
            "  ┃",
        ]
        #expect(read(review) == .asking("Review: Database: SQLite; Runner: (not answered)"))
    }

    @Test func theSidebarAndTheBorderChangeNothing() {
        let screens: [[String]] = [
            OpencodeScreens.working, OpencodeScreens.ready, OpencodeScreens.shellPermission, OpencodeScreens.editPermission,
            OpencodeScreens.shellPermission2, OpencodeScreens.alwaysAllow, OpencodeScreens.rejectMessage,
            OpencodeScreens.question, OpencodeScreens.questions,
        ]
        for screen in screens {
            let plain = read(screen)
            #expect(plain != .idle)
            #expect(read(OpencodeScreens.withSidebar(screen)) == plain, "\(plain)")
            #expect(read(OpencodeScreens.withThinBorder(screen)) == plain, "\(plain)")
        }
    }

    @Test func onlyTheBottomOfTheScreenCounts() {
        // A permission prompt answered long ago, 30 rows up in the transcript, under today's idle footer.
        let old = OpencodeScreens.shellPermission + Array(repeating: "     output", count: 30) + OpencodeScreens.footer("   ~/code/shop")
        #expect(read(old) == .ready)
        let form = OpencodeScreens.question + Array(repeating: "     output", count: 30) + OpencodeScreens.footer("   ~/code/shop")
        #expect(read(form) == .ready)
        // The header alone, or the buttons alone, is not the prompt.
        #expect(read(OpencodeScreens.transcript + ["  ┃  △ Permission required", "  ┃    # Shell command"]) == .idle)
        #expect(read(OpencodeScreens.transcript + ["     Allow once   Allow always   Reject"]) == .idle)
    }

    @Test func otherAgentsNeverSeeOpencodesShapes() {
        // Without `opencode`, these screens read as they always have.
        #expect(AgentScreen.activity(screenLines: OpencodeScreens.working) == .idle)
        #expect(AgentScreen.activity(screenLines: OpencodeScreens.ready) == .idle)
        #expect(AgentScreen.activity(screenLines: OpencodeScreens.shellPermission) == .idle)
        #expect(AgentScreen.activity(screenLines: OpencodeScreens.question) == .idle)
        #expect(AgentScreen.activity(screenLines: OpencodeScreens.alwaysAllow) == .idle)
    }

    @Test func anotherAgentsShapesInItsTranscriptAreNotItsOwn() {
        // The model quotes Claude Code's prompt, and OpenCode's own footer is under it: OpenCode waits for a prompt.
        let quoted = [
            "     Claude Code asks this before an edit:",
            "     Do you want to make this edit to login.ts?",
            "     ❯ 1. Yes",
            "       2. No, and tell Claude what to do differently (esc)",
            "     ✻ Pondering… (12s · esc to interrupt)",
        ]
        #expect(read(OpencodeScreens.transcript + quoted + OpencodeScreens.footer("   ~/code/shop")) == .ready)
        #expect(read(OpencodeScreens.transcript + quoted + OpencodeScreens.footer("   ■■■⬝⬝⬝⬝⬝ esc interrupt")) == .working)
        #expect(read(quoted + OpencodeScreens.shellPermission) == .asking("Permission required: Shell command ($ npm test)"))
    }

    @Test func opencodesOwnTitles() {
        #expect(AgentScreen.isOpencode(title: "OpenCode"))
        #expect(AgentScreen.isOpencode(title: "OC | Fix the login test"))
        #expect(!AgentScreen.isOpencode(title: "OCaml"))
        #expect(!AgentScreen.isOpencode(title: "opencode"))
        #expect(!AgentScreen.isOpencode(title: "OC|x"))
        #expect(!AgentScreen.isOpencode(title: ""))
    }

    @Test func aLongQuestionIsCut() {
        var long = OpencodeScreens.question
        long[long.count - 10] = "  ┃  " + String(repeating: "Which one? ", count: 30)
        guard case .asking(let asked) = read(long) else { return #expect(Bool(false)) }
        #expect(asked.count == 200)
    }
}

/// Screens from the review of OpenCode's reading: secrets, long commands, 2.x's "Always allow" body, hints in prose.
extension OpencodeScreens {
    /// The shell prompt (1.19) with `command` as its body rows, and `gap` blank rows between them and the buttons: two
    /// (the box's padding and the buttons' own), or fewer when the command fills the box and runs on under them.
    static func shell(_ command: [String], gap: Int = 2) -> [String] {
        transcript + ["  ┃", "  ┃  △ Permission required", "  ┃    # Shell command", "  ┃"]
            + command.map { "  ┃  " + $0 } + Array(repeating: "  ┃", count: gap)
            + ["  ┃   Allow once   Allow always   Reject                  ctrl+f fullscreen  ⇆ select  enter confirm", "  ┃"]
    }

    /// OpenCode 2.x with "Always allow" selected: the body says what it saves in place of the command (permission.tsx,
    /// `permissionAlwaysLines`).
    static let shellAlways2 = transcript + [
        "  ┃",
        "  ┃  △ Permission required",
        "  ┃",
        "  ┃  This will always allow shell for this project.",
        "  ┃",
        "  ┃",
        "  ┃   Allow once   Always allow   Reject                  ctrl+f fullscreen  ⇆ select  enter confirm",
        "  ┃",
    ]
}

extension AgentScreenOpencodeTests {
    func asked(_ lines: [String]) -> String? {
        guard case .asking(let words) = read(lines) else { return nil }
        return words
    }

    @Test func secretsInTheQuestionAreMasked() {
        let curl = OpencodeScreens.shell(["$ curl -H 'Authorization: Bearer ghp_abcdefghijklmnopqrstuvwxyz0123456789' https://api.github.com"])
        let words = asked(curl) ?? ""
        #expect(words.hasPrefix("Permission required: Shell command ($ curl -H "), "\(words)")
        #expect(!words.contains("ghp_abcdefghij") && words.contains(MCPRedaction.mask), "\(words)")
        var fetch = OpencodeScreens.editPermission
        fetch[6] = "  ┃    % WebFetch https://deploy:hunter2secret@hooks.example.com/build"
        let fetched = asked(fetch) ?? ""
        #expect(fetched.hasPrefix("Permission required: WebFetch https://") && !fetched.contains("hunter2secret"), "\(fetched)")
    }

    @Test func aCommandOnSeveralRowsIsQuotedWhole() {
        let wrapped = OpencodeScreens.shell(["$ rm -rf build && npm ci && npm run build && npm test -- --coverage",
                                             "--runInBand && git push origin main --force"])
        #expect(asked(wrapped) == "Permission required: Shell command ($ rm -rf build && npm ci && npm run build "
            + "&& npm test -- --coverage --runInBand && git push origin main --force)")
        // A command with a blank line in it: every row down to the buttons.
        let heredoc = OpencodeScreens.shell(["$ cat > notes.txt <<'EOF'", "first", "", "last", "EOF"])
        #expect(asked(heredoc) == "Permission required: Shell command ($ cat > notes.txt <<'EOF' first last EOF)")
        // Spaces inside a command are the command's, not the gap before the sidebar.
        #expect(asked(OpencodeScreens.shell(["$ echo one   two"])) == "Permission required: Shell command ($ echo one   two)")
        #expect(asked(OpencodeScreens.withSidebar(OpencodeScreens.shell(["$ echo one   two"])))
            == "Permission required: Shell command ($ echo one   two)")
        let wrappedBeside = OpencodeScreens.withSidebar(wrapped)
        #expect(asked(wrappedBeside) == asked(wrapped))
    }

    @Test func aCommandCutShortSaysSo() {
        // The box is full: the command runs on under the buttons, so less than the box's padding is left above them.
        let full = OpencodeScreens.shell(["$ for f in a b c; do", "    echo $f"], gap: 1)
        #expect(asked(full) == "Permission required: Shell command ($ for f in a b c; do echo $f …)")
        // Past 200 characters, the words end in "…".
        let long = OpencodeScreens.shell(["$ npm test -- " + String(repeating: "--grep login ", count: 20)])
        let words = asked(long) ?? ""
        #expect(words.count == 200 && words.hasSuffix("…"), "\(words.count)")
    }

    @Test func alwaysAllowsBodyIn2xIsTheSameQuestion() {
        let always = asked(OpencodeScreens.shellAlways2)
        #expect(always == "Permission required: This will always allow shell for this project.")
        let shown = "Permission required: $ npm test"
        #expect(AgentScreen.sameQuestion(shown, always ?? ""))
        // The header alone (its rows above the lines read, in fullscreen): the same prompt, read with less of it.
        #expect(AgentScreen.sameQuestion(shown, "Permission required"))
        #expect(AgentScreen.sameQuestion("Permission required: Edit src/app.ts", "Permission required"))
        // Another request is another question.
        #expect(!AgentScreen.sameQuestion(shown, "Permission required: $ rm -rf build"))
        #expect(!AgentScreen.sameQuestion("Permission required: Edit src/app.ts", always ?? ""))
        #expect(!AgentScreen.sameQuestion("Which database should the tests use?", "Permission required"))
        #expect(!AgentScreen.sameQuestion("Permission required", shown))
    }

    @Test func hintWordsInTheTranscriptAreNotTheForm() {
        let quoted = #"     78  /// The question form's hint row (1.19): "esc dismiss" with "enter submit""#
        let working = OpencodeScreens.transcript + [quoted] + OpencodeScreens.footer("   ■■⬝⬝⬝⬝⬝⬝ esc interrupt")
        #expect(read(working) == .working)
        // Its own hint row, with no options above it, is not the form either; only the review tab has none.
        for hint in ["  ┃  ↑↓ select  enter submit  esc dismiss", "  ┃  ⇆ tab  enter submit  esc dismiss"] {
            #expect(read(OpencodeScreens.transcript + [hint] + OpencodeScreens.footer("   ~/code/shop")) == .ready, "\(hint)")
        }
    }

    @Test func proseWithAKeyWordBeforeCommandsIsNotTheFooter() {
        for prose in ["     You can set up these commands", "     Open a new tab agents", "     Jump to the end commands"] {
            #expect(read(OpencodeScreens.transcript + [prose]) == .idle, "\(prose)")
        }
    }
}
