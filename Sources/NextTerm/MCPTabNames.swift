import Foundation

/// How an approval window names a tab: its place in its window and its title as shown, cleaned as the secrets panel
/// cleans text (SecretsMCP names its target tab this way). A title is the user's or an agent's words (new_tab,
/// rename_tab), so it never stands for the tab alone (010a review).
@MainActor
enum MCPTabNames {
    /// "tab 2 “api”"; "a tab “api”" when it is in no window.
    static func named(_ tab: TerminalTab) -> String { position(tab) + " “" + title(tab) + "”" }

    /// "tab 2": the tab (or the split tab a pane is in) by its place in its window; "a tab" when in none.
    static func position(_ tab: TerminalTab) -> String {
        MCPControl.controller(of: tab).flatMap { (controller: TerminalWindowController) -> String? in
            controller.groups.firstIndex { $0.contains(tab) }.map { (index: Int) -> String in "tab \(index + 1)" }
        } ?? "a tab"
    }

    /// The title with nothing that hides or reorders text, cut at 60 characters, stored keys masked.
    static func title(_ tab: TerminalTab) -> String { SecretApprovalPanel.sanitized(tab.title, limit: 60) }
}
