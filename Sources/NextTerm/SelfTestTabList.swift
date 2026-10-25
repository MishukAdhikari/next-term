import AppKit
import NextTermCore

/// The terminal's tabs in a list down its left or right (View › Terminal Tabs, Settings › Terminal › Tabs). Chosen,
/// the list sits under the terminal's bar at that side with the terminals beside it, each resized once at most; the
/// bar keeps its buttons and window drag and shows no tabs, and the sidebar stays where it was. The same tabs, order
/// and selection; Right mirrors Left; a split tab's panes are rows, and a pane's row gives that pane the keyboard;
/// Rename Tab… opens on the list's row; the tab's menu says Close Tabs Below; the ⋯ menu lists Top, Left and Right;
/// Collapse Tab List and Show Folders; folded to its bar the bar has the tabs back, beside the editor the rail; a
/// narrow window collapses it by itself. Top puts every tab back in the bar. An import from a terminal whose vertical
/// tabs were on brings the list with the files on the right, and Undo Import takes it back. The tabs go back on top at
/// the end, and the widths kept and the last import are put back as they were. A debug build then measures the list's
/// smoothness against the bar's (SelfTestTabListBudget.swift).
extension SelfTest {
    static func tabListChecks(_ c: TerminalWindowController, proj: URL) async {
        guard let window = c.window, let app = AppDelegate.shared else { return check(false, "tab list: the window is open") }
        let defaults = UserDefaults.standard
        let saved = (tabs: app.terminalTabs, folders: app.tabListShowsFolders, position: app.terminalPosition, side: app.sidebarSide,
                     width: defaults.object(forKey: TabListWidth.lastKey), widths: defaults.object(forKey: TabListWidths.key))
        defer {
            app.moveTerminalTabs(to: saved.tabs)
            app.tabListShowsFolders = saved.folders
            restoreDefault(saved.width, TabListWidth.lastKey)
            restoreDefault(saved.widths, TabListWidths.key)
        }
        app.moveTerminalTabs(to: .top)
        app.moveTerminal(to: .bottom)
        var opened: [TerminalTab] = []
        while c.groups.count < 3 { opened.append(c.addTab(directory: proj.path)) }
        for tab in opened { _ = await wait(20) { tab.status.integrated } }
        c.select(1)
        window.layoutIfNeeded()
        let pane = c.terminalPane
        let list = c.tabList
        let onTop: [String] = c.tabBar.items.map(\.title)
        let bar = (inset: c.tabBar.leadingInset, drags: c.tabBar.dragsWindow)
        let sidebarFrame = c.sidebar.frame

        // View › Terminal Tabs: Top, Left, Right, then Show Folders and Collapse Tab List.
        guard let tabsMenu = viewMenuItem("Terminal Tabs")?.submenu,
              let top = tabsMenu.items.first(where: { $0.title == "Top" }),
              let left = tabsMenu.items.first(where: { $0.title == "Left" }) else {
            return check(false, "tab list: View › Terminal Tabs offers Top and Left")
        }
        let menuTitles: [String] = tabsMenu.items.map(\.title)
        check(menuTitles == ["Top", "Left", "Right", "", "Show Folders", "Collapse Tab List"],
              "tab list: View › Terminal Tabs has Top, Left and Right, then Show Folders and Collapse Tab List", menuTitles.joined(separator: ", "))

        // Left: the list under the bar at the terminal's left, the same tabs in it, the bar without them.
        let toLeft = TerminalResizes(c.tabs.map(\.view))
        tabsMenu.performActionForItem(at: tabsMenu.index(of: left))
        window.layoutIfNeeded()
        toLeft.stop()
        let tabRows: [TabListRow] = list.rows.filter { !$0.isPane }
        let plain: [Int] = c.groups.indices.filter { !c.groups[$0].isSplit }
        let sameTabs: Bool = tabRows.count == c.groups.count && plain.allSatisfy { tabRows[safe: $0]?.title == onTop[safe: $0] }
        check(app.terminalTabs == .left && c.listShowsTabs && !list.isHidden && c.tabBar.items.isEmpty && c.tabBar.tabView(at: 0) == nil,
              "tab list: View › Terminal Tabs › Left shows the tabs in the list and none in the bar")
        check(sameTabs && list.selectedIndex == c.activeIndex, "tab list: the same tabs in the same order, the same one selected",
              "\(tabRows.map(\.title)) / \(onTop), selected \(list.selectedIndex) of \(c.activeIndex)")
        let leftFrame: NSRect = list.frame
        let leftTerminals: NSRect = c.container.frame
        let underBar: Bool = abs(leftFrame.maxY - c.tabBar.frame.minY) < 1 && leftFrame.minY < 1
        let atLeft: Bool = leftFrame.minX < 1 && abs(leftTerminals.minX - leftFrame.maxX) < 1 && abs(leftTerminals.maxX - pane.bounds.maxX) < 1
        check(underBar && atLeft, "tab list: Left puts it under the bar at the terminal's left, the terminals beside it",
              "list \(leftFrame), terminals \(leftTerminals) in \(pane.bounds)")
        check(toLeft.most <= 1, "tab list: choosing Left resizes each terminal once at most", "\(toLeft.most) times")
        check(c.tabBar.leadingInset == bar.inset && c.tabBar.dragsWindow == bar.drags && app.sidebarSide == saved.side && c.sidebar.frame == sidebarFrame,
              "tab list: the bar keeps its inset and window drag, and the sidebar stays where it was",
              "inset \(bar.inset) → \(c.tabBar.leadingInset), sidebar \(sidebarFrame) → \(c.sidebar.frame)")
        check(c.tabBar.accessibilityRole() == .group, "tab list: the bar without its tabs is no second tab group to VoiceOver")

        // Settings › Terminal › Tabs follows the menus and chooses Right: the list mirrored at the terminal's right.
        let settings = SettingsWindowController()
        let settingsTabs = settings.window?.contentView as? NSTabView
        let terminalSettings = settingsTabs?.tabViewItems.first { $0.identifier as? String == "terminal" }?.view as? TerminalSettingsView
        terminalSettings?.refresh()
        let popup = terminalSettings?.behaviour.tabs
        let choices: [String] = popup?.itemTitles ?? []
        let followed = popup?.titleOfSelectedItem
        let toRight = TerminalResizes(c.tabs.map(\.view))
        popup?.selectItem(withTitle: "Right")
        if let popup, let action = popup.action { _ = NSApp.sendAction(action, to: popup.target, from: popup) }
        settings.window?.close()
        window.layoutIfNeeded()
        toRight.stop()
        check(choices == ["Top", "Left", "Right"] && followed == "Left" && app.terminalTabs == .right,
              "tab list: Settings › Terminal › Tabs offers Top, Left and Right, follows the menus and moves the tabs",
              "\(choices), shown \(followed ?? "none"), then \(app.terminalTabs.rawValue)")
        let rightFrame: NSRect = list.frame
        let rightTerminals: NSRect = c.container.frame
        let atRight: Bool = abs(rightFrame.maxX - pane.bounds.maxX) < 1 && abs(rightTerminals.maxX - rightFrame.minX) < 1 && rightTerminals.minX < 1
        check(atRight && abs(rightFrame.width - leftFrame.width) < 1 && toRight.most == 0,
              "tab list: Right mirrors Left at the terminal's right, and the terminals keep their size",
              "list \(rightFrame), terminals \(rightTerminals), resized \(toRight.most) times")
        app.moveTerminalTabs(to: .left)
        window.layoutIfNeeded()

        // A split tab: a row per pane under its own, which has no "+1"; a pane's row gives that pane the keyboard.
        if let split = c.split(vertical: true) {
            _ = await wait(20) { split.status.integrated }
            window.layoutIfNeeded()
            let index = c.activeIndex
            let tabRow: Int = list.tabRows[safe: index] ?? 0
            let kinds: [TabListRow.Kind] = list.rows.dropFirst(tabRow + 1).prefix { $0.isPane }.map(\.kind)
            let panes: [TabListRow.Kind] = [.pane(index: 0, count: 2), .pane(index: 1, count: 2)]
            let noCount: Bool = list.rows[safe: tabRow]?.title.contains("  +") == false
            check(kinds == panes && noCount, "tab list: a split tab's panes are rows under it, and its own row has no +1", "\(kinds)")
            let first: TerminalTab? = c.groups[safe: index]?.panes.first
            _ = list.rowView(at: tabRow + 1)?.accessibilityPerformPress()
            check(first != nil && window.firstResponder === first?.view && c.activeGroup?.focused === first,
                  "tab list: a click on a pane's row gives that pane the keyboard")
            c.remove(split)
        } else {
            check(false, "tab list: the tab splits")
        }

        // Rename Tab… opens the field on the selected tab's row; a new name shows there; Esc leaves the name.
        c.select(0)
        window.layoutIfNeeded()
        c.renameTab(nil)
        let field = window.firstResponder as? NSTextView
        let inRow: Bool = field?.isDescendant(of: list.tabRowView(at: 0) ?? NSView()) == true
        field?.insertText("API server", replacementRange: field?.selectedRange() ?? NSRange(location: 0, length: 0))
        window.makeFirstResponder(nil)
        let renamed: Bool = c.groups.first?.focused.userTitle == "API server" && list.rows.first?.title.hasPrefix("API server") == true
        c.renameTab(nil)
        (window.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        let kept: Bool = !list.isEditing && c.groups.first?.focused.userTitle == "API server"
        check(inRow && renamed && kept, "tab list: Rename Tab… opens the field on the list's row, the new name shows there, and Esc leaves it",
              "in the row \(inRow), renamed \(renamed), kept \(kept)")

        // The tab's menu in the list, and the terminal's ⋯.
        let tabMenu: [String] = c.terminalTabMenu(at: 0)?.items.map(\.title) ?? []
        check(tabMenu.contains("Close Tabs Below") && !tabMenu.contains("Close Tabs to the Right"),
              "tab list: a tab's menu in the list says Close Tabs Below", tabMenu.joined(separator: ", "))
        let more = LayoutMenu.terminal()
        more.update()
        let moreTitles: [String] = more.items.map(\.title)
        let from: Int = moreTitles.firstIndex(of: "Terminal Tabs") ?? moreTitles.count
        let tabsPart: [String] = Array(moreTitles.dropFirst(from).prefix(5))
        let leftChecked: Bool = more.items.dropFirst(from).first { $0.title == "Left" }?.state == .on
        let sidebarNext: Bool = moreTitles.dropFirst(from + 5).first { !$0.isEmpty }?.hasPrefix("Move Project Sidebar") == true
        check(tabsPart == ["Terminal Tabs", "Top", "Left", "Right", "Collapse Tab List"] && leftChecked && sidebarNext,
              "tab list: the terminal's ⋯ lists Terminal Tabs with Top, Left (checked) and Right, Collapse Tab List, then the sidebar",
              moreTitles.joined(separator: ", "))

        // Collapse Tab List folds it to its column of marks, and Expand brings it back at its width: each terminal
        // changes size once each way.
        let openWidth: CGFloat = list.frame.width
        let toggled = TerminalResizes(c.tabs.map(\.view))
        c.toggleTabListCollapsed(nil)
        window.layoutIfNeeded()
        let column: Bool = list.isCollapsed && abs(list.frame.width - TabListWidth.collapsedWidth) < 1
            && abs(c.container.frame.minX - list.frame.maxX) < 1
        c.toggleTabListCollapsed(nil)
        window.layoutIfNeeded()
        toggled.stop()
        check(column && !list.isCollapsed && abs(list.frame.width - openWidth) < 1 && toggled.most <= 2,
              "tab list: Collapse Tab List folds it to its column of marks, Expand brings it back at its width, each terminal resized once each way",
              "column \(column), width \(openWidth) → \(list.frame.width), resized \(toggled.most) times")
        if let project = c.project {
            let entry = TabListWidths(propertyList: defaults.dictionary(forKey: TabListWidths.key)).entry(for: project)
            check(entry?.collapsed == false && abs((entry?.width ?? 0) - openWidth) < 1, "tab list: the project keeps its list's width and collapse",
                  "\(String(describing: entry))")
        }

        // Show Folders: a second line under each title, and one line again. Read on a tab whose folder is known: one
        // with none yet (a whole run's earlier tabs can have one) has nothing to say there, and shows one line.
        if let folders = tabsMenu.items.first(where: { $0.title == "Show Folders" }) {
            let known: Int = c.groups.firstIndex { !$0.focused.directory.isEmpty } ?? 0
            tabsMenu.performActionForItem(at: tabsMenu.index(of: folders))
            window.layoutIfNeeded()
            let detail = list.tabRowView(at: known)?.shownDetail
            let tall: Bool = abs((list.tabRowView(at: known)?.frame.height ?? 0) - TabListLayout.twoLineHeight) < 1
            tabsMenu.performActionForItem(at: tabsMenu.index(of: folders))
            window.layoutIfNeeded()
            let folder: String = c.groups[safe: known]?.focused.directory ?? "no tab"
            check(detail?.isEmpty == false && tall && list.tabRowView(at: known)?.shownDetail == nil && !app.tabListShowsFolders,
                  "tab list: Show Folders gives each row its folder on a second line, and turned off one line again",
                  "\(detail ?? "no second line"), tall \(tall), tab \(known) of \(c.groups.count) in “\(folder)”")
        }

        // Folded: to its bar above or below the editor, the bar shows the tabs; beside it, the rail.
        let file = proj.appendingPathComponent("tablist.txt")
        try? "tabs\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        c.openFile(file)
        window.layoutIfNeeded()
        if let editor = c.editorArea.activeEditor, editor.document.path.hasSuffix("tablist.txt") {
            c.toggleTerminalCollapsed(nil)
            window.layoutIfNeeded()
            let inBar: Bool = c.terminalCollapsed && c.barShowsTabs && c.tabBar.items.count == c.groups.count && list.isHidden
            c.toggleTerminalCollapsed(nil)
            window.layoutIfNeeded()
            let backInList: Bool = !c.terminalCollapsed && !list.isHidden && c.tabBar.items.isEmpty
            check(inBar && backInList, "tab list: folded to its bar the bar shows the tabs, and unfolded the list has them again",
                  "in the bar \(inBar), back \(backInList)")
            app.moveTerminal(to: .right)
            window.layoutIfNeeded()
            c.toggleTerminalCollapsed(nil)
            window.layoutIfNeeded()
            let railed: Bool = c.terminalRailed && list.isHidden && !c.terminalRail.isHidden
            c.toggleTerminalCollapsed(nil)
            window.layoutIfNeeded()
            check(railed && !list.isHidden, "tab list: folded beside the editor the rail shows the marks, and the list hides with the terminal")
            app.moveTerminal(to: .bottom)
            c.editorArea.close(editor)
            _ = await wait(2) { c.editorArea.isHidden }
        } else {
            check(false, "tab list: tablist.txt opens")
        }

        // A narrow window: it collapses by itself, and opens again when there is room.
        let savedFrame = window.frame
        let sidebarRoom: CGFloat = c.isSidebarVisible ? c.sidebar.frame.width + 1 : 0
        let height: CGFloat = window.contentView?.frame.height ?? savedFrame.height
        window.setContentSize(NSSize(width: max(window.minSize.width, sidebarRoom + 400), height: height))
        window.layoutIfNeeded()
        let narrow: CGFloat = c.terminalPane.frame.width
        let byRoom: Bool = list.isCollapsed && c.tabListPlace.shown.byRoom
        window.setFrame(savedFrame, display: true)
        window.layoutIfNeeded()
        if narrow - c.tabListPlace.width < TabListWidth.terminalMinimum {
            check(byRoom && !list.isCollapsed, "tab list: in a narrow window it collapses by itself, and opens when there is room again",
                  "terminal pane \(narrow) wide")
        } else {
            note("tab list: the window could not get narrow enough to collapse the list (terminal pane \(narrow) wide)")
        }

        // Top: every tab back in the bar, the renamed one by its new name, and the terminals the pane's whole width.
        tabsMenu.performActionForItem(at: tabsMenu.index(of: top))
        window.layoutIfNeeded()
        let backOnTop: Bool = list.isHidden && c.tabBar.items.count == c.groups.count && c.tabBar.tabView(at: 0) != nil
        let wholeWidth: Bool = c.container.frame.minX < 1 && abs(c.container.frame.maxX - pane.bounds.maxX) < 1
        check(backOnTop && wholeWidth && c.tabBar.items.first?.title.hasPrefix("API server") == true && c.tabBar.accessibilityRole() == .tabGroup,
              "tab list: Top puts every tab back in the bar, the renamed one by its new name, and the terminals the whole width",
              "\(c.tabBar.items.map(\.title)), terminals \(c.container.frame)")
        c.groups.first?.focused.userTitle = nil
        c.refresh()
        await tabListImportChecks(c, app: app)

        for tab in opened { c.requestClose(tab) }
        _ = await wait(3) { opened.allSatisfy { tab in !c.tabs.contains { $0 === tab } } }
        _ = await endSheets(over: window)
        app.moveTerminal(to: saved.position)
        if app.sidebarSide != saved.side { app.toggleSidebarSide(nil) }
        #if DEBUG
        await tabListBudgetChecks(c)
        #endif
    }

    /// An import from a terminal whose vertical tab panel was on, in expanded view: the preview's row reads as the list
    /// on the left with the project files on the right, ticked, with its note; one click applies it in every window,
    /// two lines a row, and says so; Undo Import puts the top, the sidebar on the left and one line back. The settings
    /// file is made up, in a temporary folder.
    private static func tabListImportChecks(_ c: TerminalWindowController, app: AppDelegate) async {
        let coordinator = ImportCoordinator.shared
        let lastBefore = coordinator.last
        let window = ImportWindowController.shared
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("nextterm-import-tabs-\(getpid())")
        defer {
            window.window?.close()
            c.window?.makeKeyAndOrderFront(nil)
            coordinator.last = lastBefore
            try? FileManager.default.removeItem(atPath: root)
        }
        app.moveTerminalTabs(to: .top)
        if app.sidebarSide != .left { app.toggleSidebarSide(nil) }
        app.tabListShowsFolders = false
        c.refresh()
        do {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            let text = "[appearance.vertical_tabs]\nenabled = true\nview_mode = \"expanded\"\n"
            try text.write(toFile: (root as NSString).appendingPathComponent("settings.toml"), atomically: true, encoding: .utf8)
        } catch {
            return check(false, "tab list import: a made-up settings file to read", "\(error)")
        }
        let found = DetectedApp(kind: .warp, name: "Self-test terminal", configPath: root, lastUsed: nil)
        let planned = ImportSources.plan(for: found).settings.first
        let expected = ImportedSetting.tabList(TabListImport(tabs: "left", sidebarSide: "right", showsFolders: true))
        let title: String = planned.map { ImportWindowController.describe($0.setting) } ?? "no row"
        check(planned?.setting == expected && planned?.ticked == true && title == "Tabs on the left, project files on the right"
              && planned?.note == "with each tab’s folder under it, as expanded view had it",
              "tab list import: the preview offers the list on the left with the project files on the right, ticked, with its note",
              "\(title): \(planned?.note ?? "no note")")

        let resizes = TerminalResizes(c.tabs.map(\.view))
        window.importRecommended(from: found)
        await pause(0.3)
        c.window?.layoutIfNeeded()
        resizes.stop()
        let everyWindow: Bool = app.controllers.allSatisfy { $0.tabListSide == .left }
        let twoLines: Bool = abs((c.tabList.tabRowView(at: 0)?.frame.height ?? 0) - TabListLayout.twoLineHeight) < 1
        let sidebarAt: NSRect = c.sidebar.convert(c.sidebar.bounds, to: nil)
        let sidebarRight: Bool = !c.isSidebarVisible || sidebarAt.minX > c.terminalPane.convert(c.terminalPane.bounds, to: nil).minX
        check(app.terminalTabs == .left && app.sidebarSide == .right && app.tabListShowsFolders && everyWindow && c.listShowsTabs
              && twoLines && sidebarRight,
              "tab list import: one click puts every window's tabs in the list on the left, two lines a row, and the sidebar on the right",
              "tabs \(app.terminalTabs), sidebar \(app.sidebarSide), folders \(app.tabListShowsFolders), sidebar at \(sidebarAt)")
        let texts: [String] = importWindowTexts(window)
        check(texts.contains("Tabs moved to the left, project files to the right."), "tab list import: the result names the layout it moved",
              texts.joined(separator: " | "))
        note("tab list import: the most any terminal changed size while the import moved its tabs and the sidebar: \(resizes.most)")
        let changed = coordinator.changedSinceImport()
        check(changed.isEmpty, "tab list import: nothing is named as changed since the import", changed.joined(separator: ", "))

        coordinator.undo()
        c.window?.layoutIfNeeded()
        let backOnTop: Bool = app.controllers.allSatisfy { $0.tabListSide == nil } && c.barShowsTabs && c.tabList.isHidden
        check(app.terminalTabs == .top && app.sidebarSide == .left && !app.tabListShowsFolders && backOnTop,
              "tab list import: Undo Import puts the tabs on top, the sidebar on the left and one line a row back",
              "tabs \(app.terminalTabs), sidebar \(app.sidebarSide), folders \(app.tabListShowsFolders)")
    }

    /// A View menu item by its title.
    private static func viewMenuItem(_ title: String) -> NSMenuItem? {
        NSApp.mainMenu?.items.first { $0.submenu?.title == "View" }?.submenu?.items.first { $0.title == title }
    }

    static func restoreDefault(_ value: Any?, _ key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }
}

/// How often each terminal changed size while watched: a change of where the tabs show resizes each once at most.
/// Sizes, not frames: a view moved within its window is not resized.
final class TerminalResizes: NSObject {
    private var sizes: [ObjectIdentifier: NSSize] = [:]
    private var counts: [ObjectIdentifier: Int] = [:]
    /// Each view's sizes in turn, the first as it was when watched.
    private var history: [ObjectIdentifier: [NSSize]] = [:]
    private var posted: [(view: NSView, was: Bool)] = []

    init(_ views: [NSView]) {
        super.init()
        for view in views {
            posted.append((view, view.postsFrameChangedNotifications))
            sizes[ObjectIdentifier(view)] = view.frame.size
            history[ObjectIdentifier(view)] = [view.frame.size]
            view.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: NSView.frameDidChangeNotification, object: view)
        }
    }

    @objc private func changed(_ notification: Notification) {
        guard let view = notification.object as? NSView else { return }
        let id = ObjectIdentifier(view)
        guard sizes[id] != view.frame.size else { return }
        sizes[id] = view.frame.size
        counts[id, default: 0] += 1
        history[id, default: []].append(view.frame.size)
    }

    /// `view`'s sizes in turn, for a report: "785×300 → 790×300".
    func sizes(_ view: NSView) -> String {
        (history[ObjectIdentifier(view)] ?? []).map { "\(Int($0.width))×\(Int($0.height))" }.joined(separator: " → ")
    }

    /// The most times any one changed size.
    var most: Int { counts.values.max() ?? 0 }

    /// How many times `view` changed size.
    func count(_ view: NSView) -> Int { counts[ObjectIdentifier(view)] ?? 0 }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        for entry in posted { entry.view.postsFrameChangedNotifications = entry.was }
    }
}
