import Foundation

/// When a pane or tab Next Term opened to run one command for an agent (run_command, run_with_secrets' new tab, the
/// password manager's import tab) closes by itself once that command has finished.
///
/// It closes a few seconds after a command that ended with exit code 0, so the user is not left with a pile of
/// finished panes. It stays when the command failed or its shell reports no exit code (the user reads what went
/// wrong), when the user chose Keep Open, when they typed in it after it finished, and when it is the last pane in
/// its window, as closing it would close the window too.
public enum CommandPaneClose {
    /// How long the pane shows "Closes in 3 s" before it closes.
    public static let delay: TimeInterval = 3

    /// Whether the pane should close now that its command has ended.
    public static func closes(exitCode: Int32?, kept: Bool, userTyped: Bool, lastInWindow: Bool = false) -> Bool {
        exitCode == 0 && !kept && !userTyped && !lastInWindow
    }

    /// The words of the countdown, by whole seconds left, at least 1.
    public static func countdown(_ secondsLeft: TimeInterval) -> String {
        "Closes in \(max(1, Int(secondsLeft.rounded(.up)))) s"
    }
}
