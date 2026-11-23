import AppKit
import NextTermCore

/// The hints that sit in a tab bar's free room (plan 035), each on its pull trigger and put up on HintStage:
/// - H7, terminal beside: a drag of the divider between the editor and the terminal ended at an extreme, the terminal
///   above or below the editor in a window wide enough. In the terminal's bar, a button that moves the terminal to the
///   right, which is the move itself and retires the hint (AppDelegate.moveTerminal, by any route).
/// - H4, send the selection: two or more lines selected in the editor, the same for a second, with a local agent in the
///   window that can take a prompt. In the editor's bar, Send to Agent's own words ("⌥⌘K Ask Claude Code"), a button
///   that types the lines into the agent's prompt; sending by any route retires it (TerminalWindowController.send), and
///   so does an agent reading the selection (get_editor_selection). It goes when the selection does.
/// A trigger whose moment is not right waits on the stage while it still holds. Neither hint is put where its words
/// don't fit whole, and neither ever falls back to a place over text.
@MainActor
final class BarHints {
    static let shared = BarHints()

    /// How long the editor's selection must stay the same before H4's trigger fires. The self-test stands in.
    static var selectionDwell: TimeInterval = HintTriggers.selectionDwell

    /// The selection H4 waits on, and the wait for it to settle.
    private var settling: DispatchWorkItem?

    private init() {}

    // MARK: H7

    /// H7's trigger: in `controller`, the divider was let go at an extreme. It waits while the terminal stays there.
    func terminalDividerReleased(in controller: TerminalWindowController) {
        HintStage.shared.wait(for: .terminalBeside, holds: { [weak controller] in
            guard let controller, !controller.hasClosed else { return false }
            return controller.terminalDividerAtExtreme
        }, show: { [weak controller] front in
            guard let controller, front === controller, controller.terminalDividerAtExtreme,
                  HintCenter.shared.eligible(.terminalBeside, in: controller) else { return false }
            return HintStage.shared.put(Self.terminalBesideLine(), in: controller.tabBar)
        })
    }

    /// "Move terminal to the right": a button that does it.
    static func terminalBesideLine() -> HintLine {
        let words = HintWords.terminalBeside
        return HintLine(.terminalBeside, words: words.words, help: words.help, action: {
            AppDelegate.shared.moveTerminal(to: .right)
        })
    }

    // MARK: H4

    /// The editor's selection in `controller` changed: H4 up for a selection that went (fewer than two lines) goes, and
    /// one that holds two or more lines for `selectionDwell` fires its trigger.
    func editorSelectionChanged(in controller: TerminalWindowController) {
        settling?.cancel()
        settling = nil
        let lines = controller.editorLines
        guard let lines, lines.last > lines.first else { return HintStage.shared.hide(.sendSelection) }
        guard !HintStage.suppressed, HintCenter.shared.tipsOn, HintCenter.shared.record(.sendSelection).retired == nil else { return }
        let work = DispatchWorkItem { [weak self, weak controller] in
            MainActor.assumeIsolated {
                guard let self, let controller else { return }
                self.settling = nil
                self.selectionSettled(lines.editor, lines.range, in: controller)
            }
        }
        settling = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.selectionDwell, execute: work)
    }

    /// H4's trigger: `range` stayed selected in `editor`. It waits while the same lines stay selected there.
    private func selectionSettled(_ editor: CodeEditorView, _ range: NSRange, in controller: TerminalWindowController) {
        let same: () -> Bool = { [weak controller, weak editor] in
            guard let controller, let editor, !controller.hasClosed, let lines = controller.editorLines else { return false }
            return lines.editor === editor && lines.range == range
        }
        guard same() else { return }
        HintStage.shared.wait(for: .sendSelection, holds: same, show: { [weak controller] front in
            guard let controller, front === controller, same(), let line = Self.sendSelectionLine(in: controller),
                  HintCenter.shared.eligible(.sendSelection, in: controller) else { return false }
            return HintStage.shared.put(line, in: controller.editorArea.tabBar)
        })
    }

    /// "⌥⌘K Ask Claude Code" for the lines selected in `controller` now, when the trigger's facts hold (HintTriggers):
    /// nil with no local agent, one working or waiting on a decision, or a file that usually holds secrets.
    static func sendSelectionLine(in controller: TerminalWindowController) -> HintLine? {
        guard let lines = controller.editorLines else { return nil }
        let tab: TerminalTab? = controller.agentTab
        let state: TabState? = tab?.status.state
        let document = lines.editor.document
        let secret: Bool = document.holdsSecrets || MCPProjects.secretReason(document.path) != nil
        guard HintTriggers.sendSelection(editorFocused: true, first: lines.first, last: lines.last, agentRuns: tab != nil,
                                         agentBusy: state == .working || state == .attention, holdsSecrets: secret),
              let tab else { return nil }
        let key: String? = KeyboardShortcuts.shared.key(for: #selector(TerminalWindowController.sendToAgent(_:)))?.display
        let words = HintWords.sendSelection(agent: TerminalWindowController.agentName(of: tab), key: key)
        let line = HintLine(.sendSelection, words: words.words, help: words.help, action: { [weak controller] in
            controller?.sendEditorSelection()
        })
        line.button?.setAccessibilityLabel(words.words)
        return line
    }
}
