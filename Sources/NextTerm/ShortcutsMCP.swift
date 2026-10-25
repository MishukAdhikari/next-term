import AppKit
import NextTermCore

/// list_shortcuts and show_settings (MCPShortcuts): the user's keys as Next Term has them now, and Settings at a tab, for
/// an agent that sets Next Term up for the user (the next-term-setup skill).
@MainActor
enum ShortcutsMCP {
    /// Every command with the key it has now (chord(for:), which the menus, the parts and Settings all read, not the menu
    /// item, which holds no key for editor commands while the menus are closed), titled as its menu item reads now.
    static func listShortcuts(_ arguments: [String: Any]) -> MCPServer.CallResult {
        let shortcuts = KeyboardShortcuts.shared
        let commands = shortcuts.commands.map { command -> MCPShortcuts.Command in
            let title = command.item?.title ?? command.title
            // A menu item's path is its menu's ("View › Terminal Position"); a part's key keeps the part's name.
            let place = command.item == nil ? command.path : [command.path, title].filter { !$0.isEmpty }.joined(separator: " › ")
            return MCPShortcuts.Command(title: title, place: place, key: shortcuts.chord(for: command.id)?.display,
                                        defaultKey: shortcuts.baseChord(for: command.id)?.display, changed: shortcuts.isCustomised(command.id),
                                        note: shortcuts.sharing(command.id))
        }
        return MCPControl.ok(MCPShortcuts.answer(set: shortcuts.preset.name, commands: commands, query: arguments["query"] as? String))
    }

    /// Settings at the tab, in front without the keyboard (the user may be typing), when Next Term is the app in front;
    /// else its Dock icon bounces, as for the approval window.
    static func showSettings(_ arguments: [String: Any]) -> MCPServer.CallResult {
        let tab = (arguments["tab"] as? String ?? "").lowercased()
        guard MCPShortcuts.settingsTabs.contains(tab) else {
            return MCPControl.fail("tab is one of " + MCPShortcuts.settingsTabs.joined(separator: ", ") + ".")
        }
        AppDelegate.shared.showSettings(tab: tab, forAgent: true)
        let front = NSApp.isActive
        if !front { NSApp.requestUserAttention(.informationalRequest) }
        return MCPControl.ok(["tab": tab, "shown": true, "front": front])
    }
}
