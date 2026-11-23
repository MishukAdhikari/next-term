import CoreGraphics
import Testing
@testable import NextTermCore

struct HintTriggersTests {
    private func beside(_ position: TerminalPosition = .bottom, collapsed: Bool = false, editor: Bool = true, share: CGFloat,
                        width: CGFloat = 1200) -> Bool {
        HintTriggers.terminalBeside(position: position, collapsed: collapsed, editorShown: editor, terminalShare: share, workWidth: width)
    }

    @Test func aDividerDraggedToAnExtremeAboveOrBelowFiresIt() {
        #expect(beside(share: 0.10) && beside(share: 0.90) && beside(.top, share: 0.05))
        #expect(!beside(share: 0.15) && !beside(share: 0.50) && !beside(share: 0.85))
        #expect(beside(share: 0.149) && beside(share: 0.851))
    }

    @Test func notBesideAlreadyFoldedWithoutAnEditorOrInANarrowWindow() {
        #expect(!beside(.right, share: 0.1) && !beside(.left, share: 0.9))
        #expect(!beside(collapsed: true, share: 0.05))
        #expect(!beside(editor: false, share: 0.05))
        #expect(!beside(share: 0.1, width: 959) && beside(share: 0.1, width: 960))
    }

    @Test func itsWordsAreAButtonWithTheMenuAndTheAgentInItsHelp() {
        #expect(HintWords.terminalBeside.words == "Move terminal to the right")
        #expect(HintWords.terminalBeside.help == "Or ⋯ › Move Terminal To. Or ask your agent: ‘put the terminal on the right’.")
    }

    @Test func linesSelectedWithAnAgentWaitingForAPromptFireTheSendHint() {
        func send(focused: Bool = true, _ first: Int = 3, _ last: Int = 5, runs: Bool = true, busy: Bool = false, secret: Bool = false) -> Bool {
            HintTriggers.sendSelection(editorFocused: focused, first: first, last: last, agentRuns: runs, agentBusy: busy, holdsSecrets: secret)
        }
        #expect(send() && send(3, 4))
        // One line is no selection worth teaching for; nor the editor without the keyboard, no agent, a busy one, a .env.
        #expect(!send(3, 3) && !send(focused: false) && !send(runs: false) && !send(busy: true) && !send(secret: true))
    }

    @Test func theSendHintSaysWhatTheDiffsAskButtonSays() {
        #expect(HintWords.ask(agent: "Claude Code", key: "⌥⌘K") == "⌥⌘K Ask Claude Code")
        #expect(HintWords.ask(agent: "Codex", key: nil) == "Ask Codex" && HintWords.ask(agent: "Codex", key: "") == "Ask Codex")
        let words = HintWords.sendSelection(agent: "Claude Code", key: "⌥⌘K")
        #expect(words.words == "⌥⌘K Ask Claude Code")
        #expect(words.help == "Types the selected lines into Claude Code’s prompt. Or ask your agent: ‘look at my selection’.")
    }
}
