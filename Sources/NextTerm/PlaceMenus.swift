import AppKit

/// View's layout commands, one builder each, for the menu bar and for each place's right-click, so a title, a checkmark
/// or a key can't differ between them. Titles that follow the state (Hide or Show, Collapse or Expand) and checkmarks
/// are set as a menu opens, by the target's validateMenuItem. The keys here are the defaults: the menu bar takes the
/// user's own from KeyboardShortcuts.apply, a place's menu from `PlaceMenus.userKeys`.
enum LayoutItems {
    /// Hide Project Sidebar (Show while it is hidden), ⌘B. `target` nil: the window in front, as the menu bar has it.
    static func projectSidebar(target: AnyObject?) -> NSMenuItem {
        item("Hide Project Sidebar", #selector(TerminalWindowController.toggleProjectSidebar(_:)), "b", target: target)
    }

    /// Collapse Terminal (Expand while it is folded), ⌘J.
    static func terminalCollapse(target: AnyObject?) -> NSMenuItem {
        item("Collapse Terminal", #selector(TerminalWindowController.toggleTerminalCollapsed(_:)), "j", target: target)
    }

    /// Hide Window Column (Show while it is off), ⌃⇧⌘S, in every window.
    static func windowColumn() -> NSMenuItem {
        item("Hide Window Column", #selector(AppDelegate.toggleWindowColumn(_:)), "s", [.command, .shift, .control], target: AppDelegate.shared)
    }

    /// Collapse Window Column (Expand while it is folded), ⌃⌘S, in every window.
    static func windowColumnFold() -> NSMenuItem {
        item("Collapse Window Column", #selector(AppDelegate.toggleWindowColumnExpanded(_:)), "s", [.command, .control],
             target: AppDelegate.shared)
    }

    /// The project sidebar to `side`: View › Project Sidebar Position's Left or Right, by default titled so.
    static func sidebarSide(_ side: AppDelegate.SidebarSide, title: String? = nil) -> NSMenuItem {
        let made = item(title ?? side.title, #selector(AppDelegate.chooseSidebarSide(_:)), "", target: AppDelegate.shared)
        made.representedObject = side.rawValue
        return made
    }

    /// The window column to `side`: View › Window Column Position's Left or Right, by default titled so.
    static func windowColumnSide(_ side: AppDelegate.SidebarSide, title: String? = nil) -> NSMenuItem {
        let made = item(title ?? side.title, #selector(AppDelegate.chooseWindowColumnSide(_:)), "", target: AppDelegate.shared)
        made.representedObject = side.rawValue
        return made
    }

    /// Window › Merge All Windows: every project window a tab of `window` (nil: the window in front), off while there is
    /// nothing to merge, as AppKit validates it. AppKit's own action, so its key is Window's.
    static func mergeAllWindows(into window: NSWindow?) -> NSMenuItem {
        item("Merge All Windows", #selector(NSWindow.mergeAllWindows(_:)), "", [], target: window)
    }

    /// The terminal to `position` (Bottom, Right, Left, Top), checked where it is.
    static func terminalPosition(_ position: AppDelegate.TerminalPosition) -> NSMenuItem {
        let made = item(position.title, #selector(AppDelegate.setTerminalPosition(_:)), "", target: AppDelegate.shared)
        made.representedObject = position.rawValue
        return made
    }

    /// View › Terminal Position: Bottom, Right, Left and Top.
    static func terminalPositions() -> NSMenu {
        let menu = NSMenu(title: "Terminal Position")
        for position in AppDelegate.TerminalPosition.allCases { menu.addItem(terminalPosition(position)) }
        return menu
    }

    /// A submenu's item, titled as its menu.
    static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let made = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        made.submenu = menu
        return made
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command,
                             target: AnyObject?) -> NSMenuItem {
        let made = NSMenuItem(title: title, action: action, keyEquivalent: key)
        made.keyEquivalentModifierMask = modifiers
        made.target = target
        return made
    }
}

/// What a right-click shows in each place of a window: that place's own commands from View, grouped, then the window's
/// Project Color as a submenu while it has a project. Each acts on the window clicked, not the one in front.
enum PlaceMenus {
    /// The project sidebar's top row: Hide Project Sidebar and Move Project Sidebar to the other side.
    static func sidebar(for window: TerminalWindowController) -> NSMenu {
        let menu = NSMenu(title: "Project Sidebar")
        menu.addItem(LayoutItems.projectSidebar(target: window))
        let other: AppDelegate.SidebarSide = AppDelegate.shared.sidebarSide == .right ? .left : .right
        menu.addItem(LayoutItems.sidebarSide(other, title: "Move Project Sidebar to the \(other.title)"))
        return finished(menu, for: window)
    }

    /// The terminal's top row, its bar or its folded rail: Collapse or Expand Terminal, Terminal Position and Terminal
    /// Tabs, as View has them.
    static func terminal(for window: TerminalWindowController) -> NSMenu {
        let menu = NSMenu(title: "Terminal")
        menu.addItem(LayoutItems.terminalCollapse(target: window))
        menu.addItem(LayoutItems.submenuItem(LayoutItems.terminalPositions()))
        menu.addItem(LayoutItems.submenuItem(TabListMenus.view(target: AppDelegate.shared, window: window)))
        return finished(menu, for: window)
    }

    /// The window column's top row: its own menu (`column`), then the window's Project Color.
    static func windowColumn(for window: TerminalWindowController) -> NSMenu {
        finished(column(window: window), for: window)
    }

    /// The window column: Collapse or Expand Window Column and Move to the other edge, then Merge All Windows (into
    /// `window`), then Hide Window Column.
    static func column(window: TerminalWindowController?) -> NSMenu {
        let menu = NSMenu(title: "Window Column")
        menu.addItem(LayoutItems.windowColumnFold())
        let other: AppDelegate.SidebarSide = AppDelegate.shared.windowColumnOnRight ? .left : .right
        menu.addItem(LayoutItems.windowColumnSide(other, title: "Move to the \(other.title) Edge"))
        menu.addItem(.separator())
        menu.addItem(LayoutItems.mergeAllWindows(into: window?.window))
        menu.addItem(.separator())
        menu.addItem(LayoutItems.windowColumn())
        return userKeys(menu)
    }

    /// Project Color after a separator, while the window has a project; the user's keys on every item.
    private static func finished(_ menu: NSMenu, for window: TerminalWindowController) -> NSMenu {
        if window.projectColorKey != nil {
            menu.addItem(.separator())
            menu.addItem(LayoutItems.submenuItem(ProjectColorMenu.submenu(target: window)))
        }
        return userKeys(menu)
    }

    /// Each item's key as the user has it now (Settings › Keyboard Shortcuts), as the menu bar shows it; none where they
    /// gave it none. In the submenus too.
    @discardableResult
    static func userKeys(_ menu: NSMenu) -> NSMenu {
        for item in menu.items {
            if let submenu = item.submenu { userKeys(submenu) }
            guard let id = KeyboardShortcuts.id(of: item) else { continue }
            KeyboardShortcuts.set(KeyboardShortcuts.shared.chord(for: id), on: item)
        }
        return menu
    }
}
