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

    @Test func alwaysAllowsBodyIn2xIsItsSelectionMoved() {
        let always = asked(OpencodeScreens.shellAlways2) ?? ""
        #expect(always == "Permission required: This will always allow shell for this project.")
        let shown = "Permission required: $ npm test"
        // The request's own command, then what "Always allow" saves: its selection moved onto that button.
        #expect(AgentScreen.selectionMoved(from: shown, to: always))
        // Back from it, the command shown can be another request's (OpenCode keeps the selection across requests).
        #expect(!AgentScreen.selectionMoved(from: always, to: shown))
        #expect(!AgentScreen.selectionMoved(from: always, to: "Permission required: $ rm -rf build"))
        // The header alone is another question, never the same request read with less of it.
        #expect(!AgentScreen.selectionMoved(from: "Permission required: Edit src/a.ts", to: "Permission required"))
        #expect(!AgentScreen.selectionMoved(from: shown, to: "Permission required"))
        #expect(!AgentScreen.selectionMoved(from: "Permission required", to: always))
        #expect(!AgentScreen.selectionMoved(from: "Permission required", to: shown))
        // Two requests are two questions.
        #expect(!AgentScreen.selectionMoved(from: shown, to: "Permission required: $ rm -rf build"))
        #expect(!AgentScreen.selectionMoved(from: "Permission required: Edit src/app.ts", to: always))
        #expect(!AgentScreen.selectionMoved(from: "Permission required: Shell command ($ npm test)", to: always))
        #expect(!AgentScreen.selectionMoved(from: "Which database should the tests use?", to: always))
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

/// OpenCode's screens as rows with their backgrounds: the button row coloured as OpenCode draws it, every other row text.
extension OpencodeScreens {
    /// `lines`, the row holding every one of `labels` in order coloured: each button (its label and a cell either side)
    /// on `chosen` when it is the `selected` one, else on `other`; the rest of that row on the row's own background.
    static func rows(_ lines: [String], selected: Int?, labels: [String] = ButtonRows.permission,
                     chosen: Int = ButtonRows.warm, other: Int = ButtonRows.grey) -> [ScreenRow] {
        lines.map { (line: String) -> ScreenRow in
            let plain = ScreenRow(line)
            guard let spans = plain.spans(of: labels) else { return plain }
            var cells = Array(repeating: ButtonRows.row, count: line.count)
            for (index, span) in spans.enumerated() {
                let padded: Range<Int> = max(0, span.lowerBound - 1)..<min(cells.count, span.upperBound + 1)
                for offset in padded { cells[offset] = index == selected ? chosen : other }
            }
            return ScreenRow(text: line, cells: cells)
        }
    }

    static func menu(_ rows: [ScreenRow]) -> AgentMenu? { AgentScreen.menu(screenRows: rows, opencode: true) }
    static func refusal(_ rows: [ScreenRow]) -> String? { AgentScreen.menuRefusal(screenRows: rows, opencode: true) }
    static func text(_ lines: [String]) -> [ScreenRow] { lines.map(ScreenRow.init) }

    /// The question form with `count` options and no row for a typed answer.
    static func options(_ count: Int) -> [String] {
        let asked: [String] = ["  ┃", "  ┃  Which fixture should the tests load?", "  ┃"]
        let listed: [String] = (1...count).map { (number: Int) -> String in "  ┃  \(number). Fixture \(number)" }
        let hints: [String] = ["  ┃", "  ┃  ↑↓ select  enter submit  esc dismiss", "  ┃"]
        return transcript + asked + listed + hints
    }
}

extension AgentScreenOpencodeTests {
    @Test func thePermissionPromptsButtonsAndTheirKeys() throws {
        let menu = try #require(OpencodeScreens.menu(OpencodeScreens.rows(OpencodeScreens.shellPermission, selected: 0)))
        #expect(menu.question == "Permission required: Shell command ($ npm test)")
        #expect(menu.style == .row && menu.choices == ["Allow once", "Allow always", "Reject"])
        #expect(menu.highlighted == 0 && menu.escape == 2)
        // Return alone on the selected button; Right to the next; Esc alone for Reject.
        #expect(menu.keys(toPick: 0) == ["enter"])
        #expect(menu.keys(toPick: 1) == ["right", "enter"])
        #expect(menu.keys(toPick: 2) == ["escape"])
        // The selection carried over to Reject: the shorter way round, as the row wraps.
        let moved = try #require(OpencodeScreens.menu(OpencodeScreens.rows(OpencodeScreens.shellPermission, selected: 2)))
        #expect(moved.highlighted == 2)
        #expect(moved.keys(toPick: 0) == ["right", "enter"])
        #expect(moved.keys(toPick: 1) == ["left", "enter"])
        #expect(moved.keys(toPick: 2) == ["escape"])
        // Words as the caller gives them.
        #expect(menu.index(choice: nil, answer: "allow once") == .success(0))
        #expect(menu.index(choice: nil, answer: "Reject") == .success(2))
        guard case .failure(let both) = menu.index(choice: nil, answer: "Allow") else { return #expect(Bool(false)) }
        #expect(both.text.contains("the start of more than one choice"))
    }

    @Test func aSelectionNotShownLeavesOnlyEsc() throws {
        // A theme where the buttons share one background.
        let rows = OpencodeScreens.rows(OpencodeScreens.shellPermission, selected: nil)
        let menu = try #require(OpencodeScreens.menu(rows))
        #expect(menu.highlighted == nil)
        #expect(menu.keys(toPick: 0) == nil && menu.keys(toPick: 1) == nil)
        #expect(menu.keys(toPick: 2) == ["escape"])
        #expect(menu.refusal(toPick: 0) == "That screen does not show which choice is selected, so the way to “Allow once” is unknown; nothing was typed. press_keys can answer.")
        // The screen's text alone has no colours at all.
        let plain = try #require(OpencodeScreens.menu(OpencodeScreens.text(OpencodeScreens.shellPermission)))
        #expect(plain.highlighted == nil && plain.keys(toPick: 2) == ["escape"])
    }

    @Test func everyPermissionScreensMenuAsksWhatTheTabAsks() throws {
        let screens: [[String]] = [
            OpencodeScreens.shellPermission, OpencodeScreens.editPermission, OpencodeScreens.shellPermission2,
            OpencodeScreens.withSidebar(OpencodeScreens.shellPermission), OpencodeScreens.withThinBorder(OpencodeScreens.editPermission),
        ]
        for screen in screens {
            let labels = screen == OpencodeScreens.shellPermission2 ? ["Allow once", "Always allow", "Reject"] : ButtonRows.permission
            let menu = try #require(OpencodeScreens.menu(OpencodeScreens.rows(screen, selected: 1, labels: labels)))
            #expect(.asking(menu.question) == read(screen))
            #expect(menu.choices == labels && menu.highlighted == 1, "\(menu.choices)")
        }
        // 2.x with "Always allow" selected draws what it would save in place of the command: its own words, which ask
        // neither the command's question nor another's.
        let always = try #require(OpencodeScreens.menu(OpencodeScreens.rows(OpencodeScreens.shellAlways2, selected: 1,
                                                                               labels: ["Allow once", "Always allow", "Reject"])))
        #expect(always.asks("Permission required: This will always allow shell for this project.") && always.highlighted == 1)
        #expect(!always.asks("Permission required: $ npm test") && !always.asks("Permission required"))
        #expect(!always.asks("Permission required: Edit src/app.ts") && !always.asks("Which database should the tests use?"))
    }

    @Test func twoButtonsAndNarrowPanes() throws {
        // OpenCode 2.x with nothing to save: Allow once and Reject. 2.x draws each button on a background of its own, the
        // selected one on action.primary.focused and the other on action.primary.base, over a row on a third
        // (permission.tsx, SessionQuestion): two backgrounds, neither the row's, do not say which is selected. So Allow
        // once is refused, and Reject is Esc (a hand check confirms this on real OpenCode).
        let labels = ["Allow once", "Reject"]
        var two = OpencodeScreens.shellPermission2
        two[two.count - 2] = "  ┃   Allow once   Reject                       ctrl+f fullscreen  ⇆ select  enter confirm"
        let menu = try #require(OpencodeScreens.menu(OpencodeScreens.rows(two, selected: 0, labels: labels)))
        #expect(menu.question == "Permission required: $ npm test")
        #expect(menu.choices == labels && menu.highlighted == nil && menu.escape == 1)
        #expect(menu.keys(toPick: 0) == nil && menu.keys(toPick: 1) == ["escape"])
        // A pane narrower than 80 columns: the hints go under the buttons, which stay in a row.
        var narrow = OpencodeScreens.editPermission
        narrow.insert(contentsOf: ["  ┃", "  ┃   ctrl+f fullscreen  ⇆ select  enter confirm"], at: narrow.count - 1)
        narrow[narrow.count - 4] = "  ┃   Allow once   Allow always   Reject"
        let narrowMenu = try #require(OpencodeScreens.menu(OpencodeScreens.rows(narrow, selected: 2)))
        #expect(narrowMenu.question == "Permission required: Edit src/app.ts" && narrowMenu.highlighted == 2)
        #expect(narrowMenu.keys(toPick: 1) == ["left", "enter"])
    }

    @Test func theConfirmStepAndTheRejectStep() throws {
        let labels = ["Confirm", "Cancel"]
        // OpenCode's default theme: the unselected button on the row's own background.
        let rows = OpencodeScreens.rows(OpencodeScreens.alwaysAllow, selected: 0, labels: labels, other: ButtonRows.row)
        let confirm = try #require(OpencodeScreens.menu(rows))
        #expect(confirm.question == "Always allow: This will allow bash until OpenCode is restarted.")
        #expect(confirm.style == .row && confirm.choices == labels && confirm.escape == 1 && confirm.highlighted == 0)
        #expect(confirm.keys(toPick: 0) == ["enter"] && confirm.keys(toPick: 1) == ["escape"])
        // A sub-agent's "Reject permission" step asks for a message: a question with no choices.
        let reject = OpencodeScreens.text(OpencodeScreens.rejectMessage)
        #expect(OpencodeScreens.menu(reject) == nil)
        #expect(OpencodeScreens.refusal(reject) == AgentScreen.Opencode.rejectStepRefusal)
    }
}

extension AgentScreenOpencodeTests {
    @Test func aSingleQuestionIsAnsweredByItsDigit() throws {
        // OpenCode 1.19 draws the selected option on a background of its own: here Postgres, the first.
        let menu = try #require(OpencodeScreens.menu(OpencodeScreens.form(OpencodeScreens.question, selected: 0)))
        #expect(menu.question == "Which database should the tests use?")
        // "Type your own answer" is not a choice: picking it opens a text box.
        #expect(menu.style == .digits && menu.choices == ["Postgres", "SQLite"])
        // The digit alone picks and sends: no Return after it.
        #expect(menu.keys(toPick: 0) == ["1"] && menu.keys(toPick: 1) == ["2"])
        #expect(menu.index(choice: 2, answer: nil) == .success(1))
        #expect(menu.index(choice: nil, answer: "sqlite") == .success(1))
        // With the sidebar beside it, or SQLite selected, the same.
        #expect(OpencodeScreens.menu(OpencodeScreens.form(OpencodeScreens.withSidebar(OpencodeScreens.question), selected: 0)) == menu)
        #expect(try #require(OpencodeScreens.menu(OpencodeScreens.form(OpencodeScreens.question, selected: 1))).keys(toPick: 0) == ["1"])
        // A question that turns the typed answer off lists every option, and a digit picks whatever is selected.
        var fixed = OpencodeScreens.question
        fixed.remove(at: fixed.count - 4)
        let plain = try #require(OpencodeScreens.menu(OpencodeScreens.text(fixed)))
        #expect(plain.choices == ["Postgres", "SQLite"] && plain.keys(toPick: 1) == ["2"])
        let three = try #require(OpencodeScreens.menu(OpencodeScreens.text(OpencodeScreens.options(3))))
        #expect(three.choices == ["Fixture 1", "Fixture 2", "Fixture 3"] && three.keys(toPick: 2) == ["3"])
    }

    @Test func onlyOptionsOneToNineHaveADigit() throws {
        let menu = try #require(OpencodeScreens.menu(OpencodeScreens.text(OpencodeScreens.options(11))))
        #expect(menu.choices.count == 11)
        #expect(menu.keys(toPick: 8) == ["9"])
        // Never "1" then "0": OpenCode binds one digit per option, to nine.
        #expect(menu.keys(toPick: 9) == nil && menu.keys(toPick: 10) == nil)
        #expect(menu.refusal(toPick: 9) == "OpenCode picks options 1 to 9 by their digit, and “Fixture 10” is option 10; nothing was typed. press_keys can answer: Down to it, then Return.")
    }

    @Test func aFormWithSeveralQuestionsOrAnswersHasNoMenu() {
        let questions = OpencodeScreens.text(OpencodeScreens.questions)
        #expect(OpencodeScreens.menu(questions) == nil)
        #expect(OpencodeScreens.refusal(questions) == "This form asks several questions; press_keys can answer it: a digit picks, Right goes to the next question.")
        var many = OpencodeScreens.question
        many[many.count - 10] = "  ┃  Which checks should run? (select all that apply)"
        many[many.count - 8] = "  ┃  1. [ ] Lint"
        many[many.count - 6] = "  ┃  2. [✓] Unit tests"
        many[many.count - 4] = "  ┃  3. [ ] Type your own answer"
        many[many.count - 2] = "  ┃  ⇆ tab  ↑↓ select  enter toggle  esc dismiss"
        #expect(OpencodeScreens.menu(OpencodeScreens.text(many)) == nil)
        #expect(OpencodeScreens.refusal(OpencodeScreens.text(many)) == "This question takes several answers; press_keys can answer it: a digit picks or drops one, Right goes on to Confirm, and Return sends.")
        // Its last tab, the review: Return sends.
        let review = OpencodeScreens.transcript + ["  ┃", "  ┃   Database   Runner   Confirm", "  ┃", "  ┃  Review", "  ┃",
                                                   "  ┃  Database: SQLite", "  ┃", "  ┃  ⇆ tab  enter submit  esc dismiss", "  ┃"]
        #expect(OpencodeScreens.menu(OpencodeScreens.text(review)) == nil)
        #expect(OpencodeScreens.refusal(OpencodeScreens.text(review))?.hasPrefix("This form shows its answers to review") == true)
        // A single question, a permission prompt, and no question at all: nothing to refuse.
        #expect(OpencodeScreens.refusal(OpencodeScreens.text(OpencodeScreens.question)) == nil)
        #expect(OpencodeScreens.refusal(OpencodeScreens.text(OpencodeScreens.shellPermission)) == nil)
        #expect(OpencodeScreens.refusal(OpencodeScreens.text(OpencodeScreens.working)) == nil)
        // Other agents' tabs never get OpenCode's refusals.
        #expect(AgentScreen.menuRefusal(screenRows: questions, opencode: false) == nil)
    }

    @Test func otherScreensInAnOpencodeTabReadAsBefore() throws {
        // OpenCode working or waiting for a prompt: no menu.
        #expect(OpencodeScreens.menu(OpencodeScreens.text(OpencodeScreens.working)) == nil)
        #expect(OpencodeScreens.menu(OpencodeScreens.text(OpencodeScreens.ready)) == nil)
        // A tab titled as OpenCode that shows another agent's prompt, none of OpenCode's shapes: every agent's menu.
        let claude = ["Do you want to make this edit to login.ts?", "❯ 1. Yes", "  2. No, and tell Claude what to do differently (esc)"]
        #expect(OpencodeScreens.menu(OpencodeScreens.text(claude)) == AgentScreen.menu(screenLines: claude))
        // Not OpenCode: rows read as their text, as every agent's menu has.
        let rows = OpencodeScreens.rows(OpencodeScreens.shellPermission, selected: 0)
        #expect(AgentScreen.menu(screenRows: rows, opencode: false) == nil)
        #expect(AgentScreen.menu(screenRows: OpencodeScreens.text(claude), opencode: false) == AgentScreen.menu(screenLines: claude))
    }

    @Test func aRowOfButtonsTakesTheShorterWayRound() {
        let row = AgentMenu(question: "Pick", style: .row, choices: ["A", "B", "C"], highlighted: 0)
        #expect(row.escape == nil)
        #expect(row.keys(toPick: 0) == ["enter"])
        #expect(row.keys(toPick: 1) == ["right", "enter"])
        #expect(row.keys(toPick: 2) == ["left", "enter"])
        let fromLast = AgentMenu(question: "Pick", style: .row, choices: ["A", "B", "C"], highlighted: 2)
        #expect(fromLast.keys(toPick: 0) == ["right", "enter"] && fromLast.keys(toPick: 1) == ["left", "enter"])
        let unknown = AgentMenu(question: "Pick", style: .row, choices: ["A", "B"], highlighted: nil, escape: 1)
        #expect(unknown.keys(toPick: 0) == nil && unknown.keys(toPick: 1) == ["escape"])
        // Every other agent's menu asks only its own words.
        let list = AgentMenu(question: "Do you want to proceed?", style: .list, choices: ["Yes", "No"], highlighted: 0)
        #expect(list.asks("Do you want to proceed?") && !list.asks("Permission required"))
    }
}

/// The question form's harder cases: a fullscreen prompt on a tall pane, Esc on 2.x's fullscreen prompt, a digit and an answer of your own.
extension OpencodeScreens {
    /// `lines` as OpenCode 1.19 colours its question form: the option numbered `selected + 1`, from its number to the end
    /// of its label, on the selected option's background (`backgroundElement`), every other cell on the box's own.
    static func form(_ lines: [String], selected: Int?) -> [ScreenRow] {
        lines.map { (line: String) -> ScreenRow in
            var cells: [Int] = Array(repeating: ButtonRows.row, count: line.count)
            let number: Int? = AgentScreen.Opencode.optionNumber(AgentScreen.Opencode.cell(line))
            guard let number, number - 1 == selected, let digit = line.firstIndex(where: { $0.isNumber }) else {
                return ScreenRow(text: line, cells: cells)
            }
            let start: Int = line.distance(from: line.startIndex, to: digit)
            let label: String = AgentScreen.Opencode.cell(line)
            for offset in start..<min(cells.count, start + label.count) { cells[offset] = ButtonRows.grey }
            return ScreenRow(text: line, cells: cells)
        }
    }

    /// A fullscreen permission prompt in a pane `height` rows tall: `top` (its header and what follows) at the top, the
    /// row of `buttons` at the bottom, more than `AgentScreen.scannedLines` rows apart.
    static func fullscreen(_ top: [String], buttons: String, height: Int = 60) -> [String] {
        let filler: [String] = Array(repeating: "  ┃", count: height - top.count - 3)
        return ["  ┃"] + top + filler + [buttons, "  ┃"]
    }

    static let fullscreenEdit = fullscreen(
        ["  ┃  △ Permission required", "  ┃    → Edit src/app.ts", "  ┃", "  ┃   1   import { login } from \"./auth\""],
        buttons: "  ┃   Allow once   Allow always   Reject                  ctrl+f minimize  ⇆ select  enter confirm")
    static let fullscreenShell2 = fullscreen(
        ["  ┃  △ Permission required", "  ┃", "  ┃  $ npm test"],
        buttons: "  ┃   Allow once   Always allow   Reject                  ctrl+f minimize  ⇆ select  enter confirm")
    static let labels2 = ["Allow once", "Always allow", "Reject"]
}

extension AgentScreenOpencodeTests {
    @Test func aFullscreenPromptIsReadFromItsHeader() throws {
        // Its header is further up than the rows read for other agents; OpenCode's whole screen is read.
        let tall = OpencodeScreens.fullscreenEdit
        #expect(tall.count > AgentScreen.scannedLines)
        #expect(read(tall) == .asking("Permission required: Edit src/app.ts"))
        let menu = try #require(OpencodeScreens.menu(OpencodeScreens.rows(tall, selected: 0)))
        #expect(menu.question == "Permission required: Edit src/app.ts" && menu.highlighted == 0)
        // Another request's prompt, fullscreen too: its own words, not the first's.
        var other = tall
        other[2] = "  ┃    → Edit src/b.ts"
        #expect(read(other) == .asking("Permission required: Edit src/b.ts"))
        // 1.19 rejects on Esc, fullscreen or not.
        #expect(!menu.shrinksFirst && menu.keys(toPick: 2) == ["escape"])
    }

    @Test func escOnAFullscreen2xPromptShrinksItFirst() throws {
        let labels = OpencodeScreens.labels2
        let menu = try #require(OpencodeScreens.menu(OpencodeScreens.rows(OpencodeScreens.fullscreenShell2, selected: 0, labels: labels)))
        #expect(menu.question == "Permission required: $ npm test")
        // 2.x: Esc on a fullscreen prompt only shrinks it, so Reject takes a second Esc (sent once it shows shrunk).
        #expect(menu.shrinksFirst && menu.keys(toPick: 2) == ["escape", "escape"])
        #expect(menu.keys(toPick: 0) == ["enter"] && menu.keys(toPick: 1) == ["right", "enter"])
        // Shrunk, the same question: Esc alone.
        let small = try #require(OpencodeScreens.menu(OpencodeScreens.rows(OpencodeScreens.shellPermission2, selected: 0, labels: labels)))
        #expect(small.question == menu.question && !small.shrinksFirst && small.keys(toPick: 2) == ["escape"])
        // Two buttons in a narrow pane, the hints under them.
        var narrow = OpencodeScreens.fullscreenShell2
        narrow[narrow.count - 2] = "  ┃   Allow once   Reject"
        narrow.insert("  ┃   ctrl+f minimize  ⇆ select  enter confirm", at: narrow.count - 1)
        let two = try #require(OpencodeScreens.menu(OpencodeScreens.rows(narrow, selected: nil, labels: ["Allow once", "Reject"])))
        #expect(two.shrinksFirst && two.keys(toPick: 1) == ["escape", "escape"])
        // "minimize" in the sidebar beside a shrunk prompt is not its hint.
        var beside = OpencodeScreens.shellPermission2
        beside[beside.count - 2] += "   minimize the bundle"
        let sidebar = try #require(OpencodeScreens.menu(OpencodeScreens.rows(beside, selected: 0, labels: labels)))
        #expect(!sidebar.shrinksFirst && sidebar.keys(toPick: 2) == ["escape"])
    }
}

extension AgentScreenOpencodeTests {
    @Test func aDigitIsNeverTypedIntoAnAnswerOfYourOwn() throws {
        // 1.19 with its box for an answer of your own open, under that row (its placeholder): its digit keys are off,
        // and a digit would land in the box.
        var typing = OpencodeScreens.question
        typing.insert("  ┃     Type your own answer", at: typing.count - 3)
        let open = try #require(OpencodeScreens.menu(OpencodeScreens.form(typing, selected: 2)))
        #expect(.asking(open.question) == read(typing) && open.choices == ["Postgres", "SQLite"])
        #expect(open.keys(toPick: 0) == nil && open.keys(toPick: 1) == nil)
        #expect(open.refusal(toPick: 1) == AgentScreen.Opencode.ownAnswerOpen)
        // Text typed in it, with the selection moved off by the mouse: still open.
        typing[typing.count - 4] = "  ┃     MySQL 8"
        let typed = try #require(OpencodeScreens.menu(OpencodeScreens.form(typing, selected: 0)))
        #expect(typed.keys(toPick: 1) == nil && typed.refusal(toPick: 1) == AgentScreen.Opencode.ownAnswerOpen)
        // The selection on "Type your own answer": 2.x types a key into that answer there.
        let onOwn = try #require(OpencodeScreens.menu(OpencodeScreens.form(OpencodeScreens.question, selected: 2)))
        #expect(onOwn.keys(toPick: 0) == nil && onOwn.refusal(toPick: 0) == AgentScreen.Opencode.ownAnswerSelected)
        // No option shown selected (2.x marks it by its text's colour alone): it may be on that row.
        let unseen = try #require(OpencodeScreens.menu(OpencodeScreens.text(OpencodeScreens.question)))
        #expect(unseen.choices == ["Postgres", "SQLite"] && unseen.keys(toPick: 1) == nil)
        #expect(unseen.refusal(toPick: 1) == AgentScreen.Opencode.optionNotShown)
        // Two options shown selected at once: not plain either.
        let rows = OpencodeScreens.form(OpencodeScreens.question, selected: 0)
        let both = zip(rows, OpencodeScreens.form(OpencodeScreens.question, selected: 1)).map { (pair: (ScreenRow, ScreenRow)) -> ScreenRow in
            pair.0.backgrounds.count > 1 ? pair.0 : pair.1
        }
        #expect(try #require(OpencodeScreens.menu(both)).keys(toPick: 1) == nil)
    }

    @Test func optionsAreMaskedAsTheQuestionIs() throws {
        var secret = OpencodeScreens.question
        secret[secret.count - 8] = "  ┃  1. curl -H 'Authorization: Bearer ghp_abcdefghijklmnopqrstuvwxyz0123456789' https://api.github.com"
        let menu = try #require(OpencodeScreens.menu(OpencodeScreens.form(secret, selected: 1)))
        #expect(menu.choices.count == 2 && menu.choices[1] == "SQLite")
        #expect(!menu.choices[0].contains("ghp_abcdefghij") && menu.choices[0].contains(MCPRedaction.mask), "\(menu.choices[0])")
        #expect(menu.keys(toPick: 0) == ["1"])
    }
}
