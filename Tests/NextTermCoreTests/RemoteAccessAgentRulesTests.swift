import Foundation
import Testing
@testable import NextTermCore

/// R57's list and the door's screen reads (U14): the mode on Claude Code's footer, its input line, the bypass flags,
/// the one-time labels and what a permission prompt approves. The screens are made up, in Claude Code's shapes: its full
/// prompt box, and the rules newer versions draw above and below the line.
@Suite struct RemoteAccessAgentRulesTests {
    typealias Rules = RemoteAccessAgentRules

    static func boxed(_ input: String, _ footer: String) -> [String] {
        ["⏺ Done. The tests pass.", "", "╭──────────────────────────────────────────╮",
         "│ > \(input)" + String(repeating: " ", count: max(0, 38 - input.count)) + " │",
         "╰──────────────────────────────────────────╯", "  " + footer]
    }

    static func ruled(_ input: String, _ footer: String) -> [String] {
        ["⏺ Done. The tests pass.", "", "──────────────────────────────────────────", "> \(input)",
         "──────────────────────────────────────────", "  " + footer]
    }

    @Test func theFooterSaysTheModeAndWhetherItAsks() {
        for shape in [Self.boxed, Self.ruled] {
            #expect(Rules.mode(program: "claude", screenLines: shape("", "? for shortcuts")) == .asks("default"))
            #expect(Rules.mode(program: "claude", screenLines: shape("", "⏵⏵ accept edits on (shift+tab to cycle)")) == .asks("accept edits"))
            #expect(Rules.mode(program: "claude", screenLines: shape("", "⏵⏵ auto-accept edits on (shift+tab to cycle)"))
                == .asks("auto-accept edits"))
            #expect(Rules.mode(program: "claude", screenLines: shape("", "⏸ plan mode on (shift+tab to cycle)")) == .asks("plan mode"))
            #expect(Rules.mode(program: "claude", screenLines: shape("", "⏵⏵ bypass permissions on (shift+tab to cycle)"))
                == .neverAsks("bypass permissions"))
            #expect(Rules.mode(program: "claude", screenLines: shape("", "⏵⏵ auto mode on (shift+tab to cycle)")) == .neverAsks("auto mode"))
            // A footer that says no mode Next Term knows: not readable.
            #expect(Rules.mode(program: "claude", screenLines: shape("", "something else")) == .hidden)
        }
        // Not on the list.
        #expect(Rules.mode(program: "aider", screenLines: Self.boxed("", "? for shortcuts")) == .unlisted)
        #expect(Rules.mode(program: "codex", screenLines: Self.boxed("", "? for shortcuts")) == .unlisted)
    }

    @Test func aQuestionOrNoInputLineHidesTheMode() {
        let asking = [
            "╭──────────────────────────────────────────────────────────────╮",
            "│ Bash command                                                 │",
            "│   npm test                                                   │",
            "│ Do you want to proceed?                                      │",
            "│ ❯ 1. Yes                                                     │",
            "│   2. Yes, and don't ask again for npm commands               │",
            "│   3. No, and tell Claude what to do differently (esc)        │",
            "╰──────────────────────────────────────────────────────────────╯",
        ]
        #expect(Rules.mode(program: "claude", screenLines: asking) == .hidden)
        #expect(!Rules.showsInput(program: "claude", screenLines: asking))
        // A trust-folder screen: no input line.
        let trust = ["Do you trust the files in this folder?", "", "❯ 1. Yes, proceed", "  2. No, exit", "", "Enter to confirm · Esc to exit"]
        #expect(Rules.mode(program: "claude", screenLines: trust) == .hidden)
        // Working, with its box and footer: the mode shows.
        let working = ["✻ Pondering… (12s · esc to interrupt)", ""] + Self.boxed("", "⏵⏵ accept edits on (shift+tab to cycle)")
        #expect(Rules.mode(program: "claude", screenLines: working) == .asks("accept edits"))
    }

    @Test func theInputLineIsTheRowUnderTheBoxsTop() {
        #expect(Rules.inputLine(program: "claude", screenLines: Self.boxed("", "? for shortcuts")) == .empty)
        #expect(Rules.inputLine(program: "claude", screenLines: Self.boxed("fix the", "? for shortcuts")) == .text("fix the"))
        #expect(Rules.inputLine(program: "claude", screenLines: Self.ruled("!", "? for shortcuts")) == .text("!"))
        #expect(Rules.inputLine(program: "claude", screenLines: Self.ruled("", "? for shortcuts")) == .empty)
        // A quoted "> " in the transcript is not the line.
        #expect(Rules.inputLine(program: "claude", screenLines: ["> earlier prompt", "⏺ Answer."]) == .unseen)
        #expect(Rules.inputLine(program: "aider", screenLines: Self.boxed("", "? for shortcuts")) == .unseen)
    }

    @Test func bypassFlagsOnACommandLine() {
        #expect(Rules.hasBypassFlag("claude --dangerously-skip-permissions", program: "claude"))
        #expect(Rules.hasBypassFlag("claude --permission-mode bypassPermissions", program: "claude"))
        #expect(Rules.hasBypassFlag("claude --permission-mode=bypassPermissions", program: "claude"))
        #expect(!Rules.hasBypassFlag("claude --permission-mode acceptEdits", program: "claude"))
        #expect(!Rules.hasBypassFlag("claude", program: "claude"))
        for line in ["codex --yolo", "codex --dangerously-bypass-approvals-and-sandbox", "codex --full-auto",
                     "codex --ask-for-approval never", "codex -a never", "codex --ask-for-approval=never"] {
            #expect(Rules.hasBypassFlag(line, program: "codex"), "\(line)")
        }
        for line in ["gemini -y", "gemini --yolo", "gemini --approval-mode yolo", "qwen --approval-mode=yolo"] {
            let program = String(line.split(separator: " ")[0])
            #expect(Rules.hasBypassFlag(line, program: program), "\(line)")
        }
        #expect(!Rules.hasBypassFlag("gemini -yv", program: "gemini"))
        #expect(!Rules.hasBypassFlag("aider --yes", program: "aider"))
    }

    @Test func onlyNoAndTheListedLabelsAreOneTime() {
        for label in ["Yes", "yes", "No", "No, and tell Claude what to do differently", "No, and tell Claude what to do differently (esc)"] {
            #expect(Rules.isOneTime(label, program: "claude"), "\(label)")
        }
        for label in ["Yes, and don't ask again for npm commands", "Yes, allow all edits during this session", "Yes, allow for this project",
                      "Yes, and remember this", "Yes, allow always", "Modify with external editor", "Yes, and don’t ask again"] {
            #expect(!Rules.isOneTime(label, program: "claude"), "\(label)")
        }
        // An agent with no recorded labels: only a No.
        #expect(Rules.isOneTime("No", program: "codex") && !Rules.isOneTime("Yes, proceed", program: "codex"))
    }

    @Test func aPermissionPromptSaysWhatItApproves() {
        let asking = [
            "╭──────────────────────────────────────────────────────────────╮",
            "│ Bash command                                                 │",
            "│   npm test -- --watch=false                                  │",
            "│ Do you want to proceed?                                      │",
            "│ ❯ 1. Yes                                                     │",
            "│   3. No, and tell Claude what to do differently (esc)        │",
            "╰──────────────────────────────────────────────────────────────╯",
        ]
        #expect(Rules.approves(screenLines: asking) == "npm test -- --watch=false")
        #expect(Rules.approves(screenLines: Self.boxed("", "? for shortcuts")) == nil)
    }
}
