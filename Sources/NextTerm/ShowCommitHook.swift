import AppKit

extension TerminalWindowController {
    /// Shows one commit of the repository at `root`. Until the commit history view takes this over, it
    /// copies the commit's hash and says so.
    func showCommit(sha: String, root: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sha, forType: .string)
        GitToast.show("Copied \(sha.prefix(7))", in: window)
    }
}
