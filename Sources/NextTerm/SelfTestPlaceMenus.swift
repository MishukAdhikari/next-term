import AppKit
import NextTermCore

/// Each place's right-click on the top row shows that place's own commands from View, grouped, then the window's
/// Project Color as a submenu: the project sidebar (Hide Project Sidebar, Move Project Sidebar to the other side), the
/// terminal's bar and its folded rail (Collapse or Expand Terminal, Terminal Position, Terminal Tabs), the window column
/// (Collapse Window Column, Move to the other edge, Merge All Windows, Hide Window Column). The editor's bar keeps the Project Color choices
/// alone. Titles follow the state, checkmarks the setting, each key is the menu bar's, and each command acts on the
/// window clicked. A window with no project has the commands and no Project Color.
extension SelfTest {
    static func placeMenuChecks(_ c: TerminalWindowController, app: AppDelegate, repo: String) async {
        let saved = (side: app.sidebarSide, position: app.terminalPosition, sidebar: c.isSidebarVisible)
        defer {
            if app.sidebarSide != saved.side { app.toggleSidebarSide(nil) }
            app.moveTerminal(to: saved.position)
            if c.isSidebarVisible != saved.sidebar { c.toggleProjectSidebar(nil) }
            if c.terminalCollapsed { c.expandTerminal() }
        }
        if !c.isSidebarVisible { c.toggleProjectSidebar(nil) }
        if c.editorArea.isHidden {
            c.openFile(URL(fileURLWithPath: repo + "/a.txt"))
            _ = await wait(5) { !c.editorArea.isHidden }
        }
        app.moveTerminal(to: .bottom)
        let colorTitles: [String] = titles(ProjectColorMenu.submenu())

        // The project sidebar: Hide and Move to the other side, then Project Color.
        let otherSide: String = app.sidebarSide == .right ? "Left" : "Right"
        guard let sidebar = c.sidebar.header.onTopRowMenu?() else { return check(false, "place menus: the project sidebar's top row has a menu") }
        let sidebarTitles: [String] = titles(sidebar)
        let hideKey: String = KeyboardShortcuts.shared.chord(for: "toggleProjectSidebar:")?.display ?? ""
        check(sidebarTitles == ["Hide Project Sidebar", "Move Project Sidebar to the \(otherSide)", "—", "Project Color"]
              && key(sidebar.items[0]) == hideKey && !hideKey.isEmpty && titles(sidebar.items.last?.submenu) == colorTitles,
              "place menus: the project sidebar's right-click has Hide Project Sidebar (\(hideKey)) and Move Project Sidebar to the \(otherSide), then Project Color",
              sidebarTitles.joined(separator: " | "))
        await screenshot(sidebar, in: c.sidebar.header, suffix: "-menu-sidebar")
        perform(sidebar, "Move Project Sidebar to the \(otherSide)")
        let moved: Bool = app.sidebarSide.title == otherSide
        let offered: String = (c.sidebar.header.onTopRowMenu?()).map(titles)?.dropFirst().first ?? ""
        check(moved && offered == "Move Project Sidebar to the \(saved.side.title)",
              "place menus: Move Project Sidebar to the \(otherSide) moves it there, and the menu then offers \(saved.side.title)",
              "moved \(moved), then “\(offered)”")
        if app.sidebarSide != saved.side { app.toggleSidebarSide(nil) }
        perform(sidebar, "Hide Project Sidebar")
        let hidden: Bool = !c.isSidebarVisible
        let showTitle: String = (c.sidebar.header.onTopRowMenu?()).map(titles)?.first ?? ""
        if !c.isSidebarVisible { c.toggleProjectSidebar(nil) }
        check(hidden && showTitle == "Show Project Sidebar", "place menus: Hide Project Sidebar hides this window's, and the menu then says Show",
              "hidden \(hidden), then “\(showTitle)”")

        // The terminal's bar: Collapse Terminal, Terminal Position and Terminal Tabs as View has them, then Project Color.
        guard let terminal = c.tabBar.onTopRowMenu?() else { return check(false, "place menus: the terminal's bar has a menu") }
        let terminalTitles: [String] = titles(terminal)
        let positions: NSMenu? = terminal.items.first { $0.title == "Terminal Position" }?.submenu
        let checked: [String] = positions.map { (menu: NSMenu) -> [String] in
            menu.update()
            return menu.items.filter { $0.state == .on }.map(\.title)
        } ?? []
        let tabsTitles: [String] = titles(terminal.items.first { $0.title == "Terminal Tabs" }?.submenu)
        let viewTabs: [String] = titles(TabListMenus.view(target: app))
        let collapseKey: String = KeyboardShortcuts.shared.chord(for: "toggleTerminalCollapsed:")?.display ?? ""
        check(terminalTitles == ["Collapse Terminal", "Terminal Position", "Terminal Tabs", "—", "Project Color"]
              && titles(positions) == ["Bottom", "Right", "Left", "Top"] && checked == ["Bottom"] && tabsTitles == viewTabs
              && key(terminal.items[0]) == collapseKey && !collapseKey.isEmpty,
              "place menus: the terminal's right-click has Collapse Terminal (\(collapseKey)), Terminal Position (Bottom checked) and Terminal Tabs, then Project Color",
              "\(terminalTitles.joined(separator: " | ")); positions \(titles(positions)), checked \(checked); tabs \(tabsTitles)")
        await screenshot(terminal, in: c.tabBar, suffix: "-menu-terminal")
        if let positions, let right = positions.items.first(where: { $0.title == "Right" }) {
            positions.performActionForItem(at: positions.index(of: right))
        }
        check(app.terminalPosition == .right, "place menus: Terminal Position › Right moves the terminal there", app.terminalPosition.rawValue)
        app.moveTerminal(to: .left)
        layOutPlaces(c)
        perform(terminal, "Collapse Terminal")
        layOutPlaces(c)
        let rail: [String] = c.terminalRailed ? (c.terminalRail.onTopRowMenu?()).map(titles) ?? [] : []
        check(c.terminalCollapsed && rail == ["Expand Terminal", "Terminal Position", "Terminal Tabs", "—", "Project Color"],
              "place menus: Collapse Terminal folds it, and the folded rail's right-click says Expand Terminal",
              "collapsed \(c.terminalCollapsed), railed \(c.terminalRailed), rail \(rail.joined(separator: " | "))")
        if c.terminalRailed, let menu = c.terminalRail.onTopRowMenu?() {
            await screenshot(menu, in: c.terminalRail, suffix: "-menu-terminal-rail")
            perform(menu, "Expand Terminal")
        }
        check(!c.terminalCollapsed, "place menus: Expand Terminal on the rail brings the terminal back")
        app.moveTerminal(to: .bottom)
        layOutPlaces(c)

        // The window column's top row: its own group, then Project Color.
        let fold: String = app.windowColumnExpanded ? "Collapse Window Column" : "Expand Window Column"
        let otherEdge: String = app.windowColumnOnRight ? "Left" : "Right"
        let column: NSMenu? = c.windowColumn.onTopRowMenu?()
        let columnTitles: [String] = column.map(titles) ?? []
        check(columnTitles == [fold, "Move to the \(otherEdge) Edge", "—", "Merge All Windows", "—", "Hide Window Column", "—", "Project Color"]
              && titles(WindowColumnView.columnMenu()) == Array(columnTitles.prefix(6)),
              "place menus: the window column's top row has its own menu, then Project Color", columnTitles.joined(separator: " | "))
        if let column, !c.windowColumn.isHiddenOrHasHiddenAncestor { await screenshot(column, in: c.windowColumn, suffix: "-menu-window-column") }

        // The editor's bar: the Project Color choices alone, under their heading, as before.
        let editor: [String] = (c.editorArea.tabBar.onTopRowMenu?()).map { $0.items.map(\.title) } ?? []
        check(editor.first == "Project Color" && editor.count == 15, "place menus: the editor's bar keeps the Project Color choices",
              editor.joined(separator: " | "))

        // Every key is the menu bar's, in every place's menu and its submenus.
        var differ: [String] = []
        for menu in [sidebar, terminal, column].compactMap({ $0 }) { compareKeys(menu, &differ) }
        check(differ.isEmpty, "place menus: each command's key is the one the menu bar shows", differ.joined(separator: ", "))
    }

    /// The window column's Merge All Windows, as Window › Merge All Windows: on while two project windows are apart, it
    /// makes the other a project tab of the window clicked, and is off then, with nothing left to merge.
    static func columnMergeChecks(_ c: TerminalWindowController) async {
        let app: AppDelegate = AppDelegate.shared
        guard let host = c.window, await bringToFront(host), NSApp.isActive else {
            return note("column merge checks skipped: Next Term isn't the app in front")
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-colmerge-\(getpid())")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let saved: (mode: NSWindow.TabbingMode, id: String) = (host.tabbingMode, host.tabbingIdentifier)
        host.tabbingMode = .automatic // made while windows were kept apart
        host.tabbingIdentifier = WindowTabbing.projectIdentifier
        let other = app.openWindow(directory: root.path, project: root.path)
        defer {
            if other.window?.tabGroup?.windows.count ?? 0 > 1 { other.window?.moveTabToNewWindow(nil) }
            if !other.hasClosed { for tab in other.tabs { other.remove(tab) } } // its last tab takes the window
            host.tabbingMode = saved.mode
            host.tabbingIdentifier = saved.id
            c.titleBarChanged(force: true)
            try? FileManager.default.removeItem(at: root)
        }
        _ = await wait(20) { other.tabs.first?.status.integrated == true }
        _ = await bringToFront(host)
        // The menu kept while its item is used: an item holds its menu weakly.
        var menu: NSMenu? = nil
        func merge() -> NSMenuItem? {
            menu = c.windowColumn.onTopRowMenu?()
            menu?.update()
            return menu?.items.first { $0.title == "Merge All Windows" }
        }
        let on: Bool = merge()?.isEnabled == true
        if let item = merge(), let menu { menu.performActionForItem(at: menu.index(of: item)) }
        let merged: Bool = await wait(3) { host.tabGroup?.windows.count == 2 && other.window?.tabGroup === host.tabGroup }
        let off: Bool = merge()?.isEnabled == false
        check(on && merged && off,
              "window column: Merge All Windows in its right-click makes the other project window a tab of this one, and is off then",
              "on \(on), group \(host.tabGroup?.windows.count ?? 0), off after \(off)")
    }

    /// A window with no project: the places' commands, with no Project Color and nothing on the editor's bar.
    static func noProjectPlaceMenuChecks(_ c: TerminalWindowController) {
        let sidebar: [String] = (c.sidebar.header.onTopRowMenu?()).map(titles) ?? []
        let terminal: [String] = (c.tabBar.onTopRowMenu?()).map(titles) ?? []
        check(sidebar.count == 2 && terminal.count == 3 && !(sidebar + terminal).contains("Project Color")
              && c.editorArea.tabBar.onTopRowMenu?() == nil,
              "place menus: a window with no project has the places' commands and no Project Color",
              "\(sidebar.joined(separator: " | ")); \(terminal.joined(separator: " | "))")
    }

    /// The titles as the menu shows them on opening (validated), a separator as "—".
    private static func titles(_ menu: NSMenu?) -> [String] {
        guard let menu else { return [] }
        menu.update()
        return menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    private static func key(_ item: NSMenuItem) -> String { KeyboardShortcuts.chord(of: item)?.display ?? "" }

    private static func perform(_ menu: NSMenu, _ title: String) {
        menu.update()
        guard let item = menu.items.first(where: { $0.title == title }) else { return check(false, "place menus: “\(title)” is in the menu") }
        menu.performActionForItem(at: menu.index(of: item))
    }

    private static func layOutPlaces(_ c: TerminalWindowController) {
        c.window?.contentView?.layoutSubtreeIfNeeded()
        c.window?.displayIfNeeded()
    }

    /// The items whose key differs from the menu bar's item with the same command.
    private static func compareKeys(_ menu: NSMenu, _ differ: inout [String]) {
        for item in menu.items {
            if let submenu = item.submenu { compareKeys(submenu, &differ) }
            guard let id = KeyboardShortcuts.id(of: item), let bar = NSApp.mainMenu.flatMap({ menuBarItem(id, in: $0) }) else { continue }
            if key(item) != key(bar) { differ.append("\(item.title) \(key(item)) vs \(key(bar))") }
        }
    }

    private static func menuBarItem(_ id: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if !item.isHidden, KeyboardShortcuts.id(of: item) == id { return item }
            if let submenu = item.submenu, let found = menuBarItem(id, in: submenu) { return found }
        }
        return nil
    }

    /// The menu as it opens from `view`, captured on screen (an app may capture its own windows) and closed again.
    static func screenshot(_ menu: NSMenu, in view: NSView, suffix: String) async {
        guard let base = reportPath, view.window?.isVisible == true else { return }
        await pause(0.3)
        final class Shot { var image: CGImage? }
        let shot = Shot()
        let pid = Int(getpid())
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let timer = Timer(timeInterval: 0.6, repeats: false) { _ in
            let infos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
            // The menu's own window: of this app's at the menu level, the one of the menu's size.
            func off(_ info: [String: Any]) -> CGFloat {
                guard let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) })
                else { return .greatestFiniteMagnitude }
                return abs(bounds.width - menu.size.width) + abs(bounds.height - menu.size.height)
            }
            let mine = infos.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == menuLevel }
            if let number = mine.min(by: { off($0) < off($1) })?[kCGWindowNumber as String] as? Int {
                shot.image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(number), [.boundsIgnoreFraming, .bestResolution])
            }
            menu.cancelTracking()
        }
        RunLoop.main.add(timer, forMode: .common)
        menu.popUp(positioning: nil, at: NSPoint(x: min(60, view.bounds.width / 2), y: view.bounds.height / 2), in: view)
        timer.invalidate()
        guard let image = shot.image else { return note("screenshot of the menu\(suffix) failed") }
        let path = (base as NSString).deletingPathExtension + suffix + ".png"
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        note("screenshot: \(path)")
    }
}
