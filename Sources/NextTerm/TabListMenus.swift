import AppKit
import NextTermCore

/// Where the terminal's tabs go, in the menus: View › Terminal Tabs, and the terminal's ⋯ under its places, as
/// Terminal Position is in both. Top, Left or Right apply to every window; Show Folders and Collapse Tab List act on
/// the list, so they work with Left or Right. None has a key of its own; Settings › Keyboard Shortcuts can give each
/// one, since it collects the View menu's commands.
enum TabListMenus {
    /// View › Terminal Tabs: Top, Left, Right, then Show Folders and Collapse Tab List, whose title follows the list
    /// of the window in front (Expand Tab List while it is collapsed).
    static func view(target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Terminal Tabs")
        addPlaces(to: menu, target: target, indented: false)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Folders", action: #selector(AppDelegate.toggleTabListFolders(_:)), keyEquivalent: "").target = target
        menu.addItem(withTitle: "Collapse Tab List", action: #selector(TerminalWindowController.toggleTabListCollapsed(_:)), keyEquivalent: "")
        return menu
    }

    /// The terminal's ⋯: the heading Terminal Tabs with Top, Left and Right under it, laid out as Move Terminal To
    /// is, and with a list, Collapse Tab List.
    static func items(into menu: NSMenu) {
        guard let app = AppDelegate.shared else { return }
        let heading = menu.addItem(withTitle: "Terminal Tabs", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        addPlaces(to: menu, target: app, indented: true)
        guard app.terminalTabs.listSide != nil else { return }
        let collapse = menu.addItem(withTitle: "Collapse Tab List", action: #selector(TerminalWindowController.toggleTabListCollapsed(_:)),
                                    keyEquivalent: "")
        collapse.indentationLevel = 1
    }

    /// Top, Left and Right, checked as AppDelegate.validateMenuItem says; each its own command, by its value.
    private static func addPlaces(to menu: NSMenu, target: AppDelegate, indented: Bool) {
        for tabs in TerminalTabsSetting.allCases {
            let item = menu.addItem(withTitle: tabs.title, action: #selector(AppDelegate.setTerminalTabs(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = tabs.rawValue
            if indented { item.indentationLevel = 1 }
        }
    }
}
