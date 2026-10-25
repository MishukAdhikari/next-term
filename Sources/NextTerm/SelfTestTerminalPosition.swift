import AppKit
import NextTermCore

/// Terminal Position. The position it has chosen again, or the sidebar moved to its other side, leaves the work
/// area as it is: a folded terminal stays folded and the divider stays put. Beside the editor and above or below
/// it, each keeps its own share of the work area for the editor, placed so neither pane goes under its minimum.
/// Folded to its bar above or below the editor, the tab in front is out of sight, and a terminal taking the
/// keyboard unfolds, as behind the rail. With no file open a chosen position says where the terminal goes, and
/// Settings › Terminal › Position chooses it as the menus do.
extension SelfTest {
    static func terminalPositionChecks(_ c: TerminalWindowController, proj: URL) async {
        guard let window = c.window, let app = AppDelegate.shared, let pane = c.tabBar.superview,
              let work = c.editorArea.superview as? NSSplitView else { return check(false, "position: the work area is a split view") }
        let saved = (position: app.terminalPosition, side: app.sidebarSide, shares: savedEditorShares())
        let file = proj.appendingPathComponent("position.txt")
        try? "position\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        c.openFile(file)
        guard let editor = c.editorArea.activeEditor, editor.document.path.hasSuffix("position.txt") else {
            return check(false, "position: position.txt opens")
        }
        app.moveTerminal(to: .bottom)
        window.layoutIfNeeded()
        /// A View › Terminal Position item, as the menu has it.
        func menuItem(_ position: TerminalPosition) -> NSMenuItem {
            let item = NSMenuItem(title: position.title, action: #selector(AppDelegate.setTerminalPosition(_:)), keyEquivalent: "")
            item.representedObject = position.rawValue
            return item
        }

        // The divider somewhere other than the editor's share (as a window resize leaves it): the position it has
        // chosen again, and the sidebar moved to its other side and back, leave it there.
        work.setPosition((work.bounds.height * 0.5).rounded(), ofDividerAt: 0)
        window.layoutIfNeeded()
        let editorHeight = c.editorArea.frame.height
        app.setTerminalPosition(menuItem(.bottom))
        app.toggleSidebarSide(nil)
        app.toggleSidebarSide(nil)
        window.layoutIfNeeded()
        check(abs(c.editorArea.frame.height - editorHeight) < 1 && app.sidebarSide == saved.side,
              "position: choosing the one it has, or moving the sidebar, leaves the divider where it is",
              "editor \(editorHeight) → \(c.editorArea.frame.height)")

        // Folded to its bar: the same, and it stays folded.
        c.toggleTerminalCollapsed(nil)
        window.layoutIfNeeded()
        let bar = pane.frame.height
        app.setTerminalPosition(menuItem(.bottom))
        window.layoutIfNeeded()
        let keptByPosition = c.terminalCollapsed && abs(pane.frame.height - bar) < 1
        app.toggleSidebarSide(nil)
        window.layoutIfNeeded()
        let keptBySide = c.terminalCollapsed && abs(pane.frame.height - bar) < 1
        app.toggleSidebarSide(nil)
        window.layoutIfNeeded()
        check(keptByPosition && keptBySide && c.terminalCollapsed && app.sidebarSide == saved.side,
              "position: choosing the one it has, or moving the sidebar, leaves a folded terminal folded",
              "position \(keptByPosition), sidebar \(keptBySide), \(bar) → \(pane.frame.height)")

        // Folded to its bar, the tab in front is out of sight: what happens in it is news, as behind the rail. Taking
        // the keyboard (⌃Tab, ⌘1–⌘9, ⌘T) unfolds it, as the rail does.
        let unseenFolded = c.activeTab.map { !c.isOnScreen($0) } ?? false
        let inFront = c.activeTab // the project's tab: the checks after these read the project in the sidebar
        c.cycleTab(by: 1)
        window.layoutIfNeeded()
        check(!c.terminalCollapsed && pane.frame.height > bar + 50, "position: folded to its bar, switching tabs from the keyboard unfolds it",
              "\(bar) → \(pane.frame.height)")
        if c.activeTab.map(c.isOnScreen) == true {
            check(unseenFolded, "position: folded to its bar, the tab in front counts as out of sight")
        } else {
            note("position: the window is not in front, so a folded terminal's tab in front was not checked as out of sight")
        }
        c.toggleTerminalCollapsed(nil)
        let added = c.addTab(directory: proj.path) // what ⌘T does
        window.layoutIfNeeded()
        check(!c.terminalCollapsed && c.activeTab === added, "position: folded to its bar, a new tab unfolds it")
        _ = await wait(10) { added.status.integrated }
        added.status.setVisible(true)
        c.requestClose(added)
        if c.terminalCollapsed { c.toggleTerminalCollapsed(nil) }
        // ⌃Tab went round to the window's first tab, in /tmp, and a window with no project follows its tab: back to the
        // tab that was in front, so the sidebar and git are the project's again.
        if let inFront { c.show(inFront) }

        // Each orientation keeps its own share: one beside the editor is no height above or below it. The panes'
        // minimums: 240 points beside, the tab bar and 60 above or below.
        let beside: CGFloat = 240, stacked: CGFloat = TabBarView.height + 60
        app.setEditorFraction(0.4, sideBySide: true)
        app.setEditorFraction(0.7, sideBySide: false)
        app.moveTerminal(to: .right)
        window.layoutIfNeeded()
        let wantedWidth = EditorShare.editorLength(share: 0.4, of: work.bounds.width, thickness: work.dividerThickness,
                                                   editorMinimum: beside, terminalMinimum: beside)
        let width = c.editorArea.frame.width
        app.moveTerminal(to: .bottom)
        window.layoutIfNeeded()
        let wantedHeight = EditorShare.editorLength(share: 0.7, of: work.bounds.height, thickness: work.dividerThickness,
                                                    editorMinimum: stacked, terminalMinimum: stacked)
        let height = c.editorArea.frame.height
        check(abs(width - wantedWidth) < 2 && abs(height - wantedHeight) < 2, "position: beside the editor and above or below it, each keeps its own share",
              "width \(width) of \(wantedWidth), height \(height) of \(wantedHeight)")
        // A share that would squeeze the terminal under its minimum, on top this time: it keeps its minimum.
        app.setEditorFraction(0.9, sideBySide: false)
        app.moveTerminal(to: .top)
        window.layoutIfNeeded()
        check(pane.frame.height >= stacked - 1 && c.editorArea.frame.height >= stacked - 1,
              "position: a share applied leaves each pane its minimum", "terminal \(pane.frame.height), editor \(c.editorArea.frame.height)")
        restoreEditorShares(saved.shares)

        // With no file open the terminal fills the window, so a position chosen then says where it goes. With a
        // file open it just moves.
        let notices = GitToast.count
        app.setTerminalPosition(menuItem(.right))
        let quietWithFile = GitToast.count == notices
        c.editorArea.close(editor)
        _ = await wait(2) { c.editorArea.isHidden }
        app.setTerminalPosition(menuItem(.left))
        let notice = GitToast.text
        if TerminalWindow.front === window {
            check(quietWithFile && c.editorArea.isHidden && notice == TerminalPosition.left.noticeWithNoFileOpen,
                  "position: chosen with no file open, a notice says the terminal moves there when a file is open", notice ?? "none")
        } else {
            note("position: the window is not in front, so the notice with no file open was not checked")
        }
        GitToast.dismiss()

        // Settings › Terminal › Position: the four places, the one chosen, following the menus, and choosing there.
        let settings = SettingsWindowController()
        let tabs = settings.window?.contentView as? NSTabView
        let terminalSettings = tabs?.tabViewItems.first { $0.identifier as? String == "terminal" }?.view as? TerminalSettingsView
        terminalSettings?.refresh()
        let popup = terminalSettings?.behaviour.position
        let titles = popup?.itemTitles ?? []
        let shown = popup?.titleOfSelectedItem
        app.setTerminalPosition(menuItem(.right))
        let followed = popup?.titleOfSelectedItem
        popup?.selectItem(withTitle: "Top")
        if let popup, let action = popup.action { _ = NSApp.sendAction(action, to: popup.target, from: popup) }
        let chosen = app.terminalPosition
        settings.window?.close()
        GitToast.dismiss()
        let places: [String] = TerminalPosition.allCases.map(\.title)
        let listed: Bool = titles == places && shown == "Left"
        check(listed && followed == "Right" && chosen == .top,
              "position: Settings › Terminal › Position offers the four places, follows the menus and moves the terminal",
              "\(titles), shown \(shown ?? "none"), then \(followed ?? "none"), chosen \(chosen.rawValue)")

        app.moveTerminal(to: saved.position)
        if app.sidebarSide != saved.side { app.toggleSidebarSide(nil) }
        restoreEditorShares(saved.shares)
    }

    /// The editor's shares as stored (each orientation's, and the one kept for both before), to put back.
    static func savedEditorShares() -> [String: Any] {
        var shares: [String: Any] = [:]
        for key in EditorShare.keys { shares[key] = UserDefaults.standard.object(forKey: key) }
        return shares
    }

    static func restoreEditorShares(_ shares: [String: Any]) {
        for key in EditorShare.keys {
            if let value = shares[key] { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
}
