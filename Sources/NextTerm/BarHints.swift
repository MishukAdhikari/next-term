import AppKit
import NextTermCore

/// The hints that sit in a tab bar's free room (plan 035), each on its pull trigger and put up on HintStage:
/// - H7, terminal beside: a drag of the divider between the editor and the terminal ended at an extreme, the terminal
///   above or below the editor in a window wide enough. In the terminal's bar, a button that moves the terminal to the
///   right, which is the move itself and retires the hint (AppDelegate.moveTerminal, by any route).
/// A trigger whose moment is not right waits on the stage while it still holds. Neither hint is put where its words
/// don't fit whole, and neither ever falls back to a place over text.
@MainActor
final class BarHints {
    static let shared = BarHints()

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
}
