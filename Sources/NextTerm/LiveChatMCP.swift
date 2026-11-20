import AppKit
import NextTermCore

/// The live chat over MCP (plan 041 U5): list_tabs says which view a tab that offers one shows, and switch_view changes
/// it. A view change only: nothing is typed into the agent, and it asks nothing.
@MainActor
enum LiveChatMCP {
    /// The pane that shows `tab`.
    static func pane(of tab: TerminalTab) -> PaneView? {
        guard let controller = MCPControl.controller(of: tab), let group = controller.groups.first(where: { $0.contains(tab) }) else { return nil }
        return group.paneView(tab)
    }

    /// list_tabs: `view` (chat or terminal) for a tab whose agent has a live chat while the setting is on; nothing else.
    static func listFields(_ tab: TerminalTab) -> [String: Any] {
        guard LiveChatView.isOn, LiveChatView.offers(tab), let pane = pane(of: tab) else { return [:] }
        return ["view": pane.showsChat ? "chat" : "terminal"].merging(TokenBudgets.fields(tab)) { $1 }
    }

    /// switch_view: shows the tab's session as a chat or its terminal. Refused, with why, for a tab that offers no chat.
    static func switchView(_ tab: TerminalTab, _ arguments: [String: Any]) -> MCPServer.CallResult {
        guard let view = arguments["view"] as? String, ["chat", "terminal"].contains(view) else {
            return MCPControl.fail("view is chat or terminal.")
        }
        guard LiveChatView.isOn else {
            return MCPControl.fail("The chat view is off (Settings › Agents › Chat view for agent tabs); the tab shows its terminal.")
        }
        guard LiveChatView.offers(tab) else {
            return MCPControl.fail("That tab offers no chat view: only a local tab running Claude Code, Codex or Command Code, or an agent session Next Term started (new_tab agent_session), does.")
        }
        guard let pane = pane(of: tab) else { return MCPControl.fail("That tab is gone.") }
        pane.setChat(shown: view == "chat")
        return MCPControl.ok(["id": tab.id.uuidString.lowercased(), "view": pane.showsChat ? "chat" : "terminal"])
    }
}
