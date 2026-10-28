import Foundation

/// Which caller opened each tab over MCP (new_tab, new_remote_tab, split_pane). rename_tab renames only the caller's own
/// tab and the tabs it opened: approval windows name tabs, and a tab the user named, or another agent's, is not this
/// agent's to name (010a review). Callers outside the tabs share one key, as their approval windows share one name.
enum MCPTabOpeners {
    private static var opener: [UUID: String] = [:]

    private static func key(_ caller: TerminalTab?) -> String { caller?.id.uuidString ?? "outside" }

    static func record(_ tab: TerminalTab, openedBy caller: TerminalTab?) { opener[tab.id] = key(caller) }

    static func mayRename(_ tab: TerminalTab, caller: TerminalTab?) -> Bool {
        if let caller, tab === caller { return true }
        return opener[tab.id] == key(caller)
    }

    static let refusal = "rename_tab names only your own tab and the tabs you opened (new_tab, new_remote_tab, split_pane); the others are the user's to rename (Rename Tab…)."
}
