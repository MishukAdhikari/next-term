import AppKit
import SwiftTerm
import NextTermCore

/// The right-click menus (the terminal, its tabs, the editor's tabs): what they list, that each command does
/// what it says and is a menu-bar command too, Reopen Closed Tab, closing several tabs asking once, and a
/// tooltip following a remapped key. Then, with only the Welcome window open, the ways into remote work
/// from it.
extension SelfTest {
    static func menuChecks(_ c: TerminalWindowController) async {
        let app = AppDelegate.shared!
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-menus-\(getpid())")
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["a.txt", "b.txt", "c.txt"] { try? "one\ntwo\nthree\n".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        try? "first\nsecond\nthird\n".write(to: folder.appendingPathComponent("src/notes.txt"), atomically: true, encoding: .utf8)
        let savedClipboard = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let savedClipboard { NSPasteboard.general.setString(savedClipboard, forType: .string) }
        }

        // A window of its own: Close Other Tabs must not take the other checks' tabs.
        let w = app.openWindow(directory: folder.path)
        guard let window = w.window, let first = w.tabs.first else { return check(false, "menus: a window for the menu checks") }
        _ = await wait(20) { first.status.integrated }
        await menuBarChecks(w)
        await terminalMenuChecks(w, tab: first, folder: folder)
        await tabMenuChecks(w, folder: folder)
        await editorTabMenuChecks(w, folder: folder)
        await firstShellChecks(folder: folder)
        await tooltipRemapChecks(c)

        for tab in w.tabs { w.remove(tab) }
        _ = await wait(3) { !app.controllers.contains { $0 === w } }
        if app.controllers.contains(where: { $0 === w }) { window.close() }
        c.window?.makeKeyAndOrderFront(nil)
    }

    /// The commands the menus share are in the menu bar too, so Settings can give each a key.
    private static func menuBarChecks(_ w: TerminalWindowController) async {
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
        let all = items(NSApp.mainMenu ?? NSMenu())
        let titles = ["Duplicate Tab", "Reopen Closed Tab", "Close Other Tabs", "Close Tabs to the Right", "Reveal in Finder", "Copy Path", "Copy Relative Path"]
        let shell = NSApp.mainMenu?.items.first { $0.title == "Shell" }?.submenu?.items.map(\.title) ?? []
        let missing = titles.filter { !shell.contains($0) }
        check(missing.isEmpty, "menus: the Shell menu has the tab and file commands the right-click menus use", missing.joined(separator: ", "))
        let reopen = all.first { $0.action == #selector(TerminalWindowController.reopenClosedTab(_:)) }
        check(reopen?.keyEquivalent == "t" && reopen?.keyEquivalentModifierMask == [.command, .shift], "menus: Reopen Closed Tab is ⇧⌘T")
        let ids = ["duplicateTab:", "reopenClosedTab:", "closeOtherTabs:", "closeTabsToTheRight:", "revealInFinder:", "copyFilePath:", "copyRelativeFilePath:"]
        let listed = KeyboardShortcuts.shared.commands.map(\.id)
        check(ids.allSatisfy(listed.contains), "menus: Settings › Keyboard Shortcuts lists them", ids.filter { !listed.contains($0) }.joined(separator: ", "))
        let copyPath = NSMenuItem(title: "Copy Path", action: #selector(TerminalWindowController.copyFilePath(_:)), keyEquivalent: "")
        check(w.editorArea.activePath != nil || !w.validateMenuItem(copyPath), "menus: Copy Path is off with no file open")
    }

    /// Every right-click command names its menu-bar command (its id), and shows the key that has now.
    private static func commandsMatchTheMenuBar(_ menu: NSMenu, _ name: String) {
        let shortcuts = KeyboardShortcuts.shared
        var wrong: [String] = []
        for item in menu.items {
            guard let id = item.identifier?.rawValue else { continue }
            guard let command = shortcuts.commands.first(where: { $0.id == id }) else {
                wrong.append("\(item.title) (\(id), not in the menu bar)")
                continue
            }
            let inMenuBar = command.item.flatMap(KeyboardShortcuts.chord(of:))
            if KeyboardShortcuts.chord(of: item) != inMenuBar { wrong.append("\(item.title) (\(id))") }
        }
        check(wrong.isEmpty, "menus: \(name)'s commands are menu-bar commands, with their keys shown", wrong.joined(separator: ", "))
    }

    private static func titles(_ menu: NSMenu) -> [String] { menu.items.filter { !$0.isSeparatorItem }.map(\.title) }

    private static func run(_ title: String, in menu: NSMenu) -> Bool {
        guard let index = menu.items.firstIndex(where: { $0.title == title }), menu.items[index].isEnabled, menu.items[index].action != nil else { return false }
        menu.performActionForItem(at: index)
        return true
    }

    // MARK: the terminal

    private static func terminalMenuChecks(_ w: TerminalWindowController, tab: TerminalTab, folder: URL) async {
        let view = tab.view
        view.selectNone()
        let plain = w.terminalMenu(for: tab, link: nil)
        check(titles(plain) == ["Copy", "Paste", "Select All", "Clear", "Find…", "Split Right", "Split Down"],
              "menus: the terminal's menu", titles(plain).joined(separator: ", "))
        check(plain.items.first { $0.title == "Copy" }?.isEnabled == false, "menus: Copy is off with nothing selected")
        NSPasteboard.general.clearContents()
        let empty = w.terminalMenu(for: tab, link: nil).items.first { $0.title == "Paste" }
        NSPasteboard.general.setString("paste me", forType: .string)
        let full = w.terminalMenu(for: tab, link: nil).items.first { $0.title == "Paste" }
        check(empty?.isEnabled == false && full?.isEnabled == true, "menus: Paste is on only with text on the clipboard")
        commandsMatchTheMenuBar(plain, "the terminal")

        // Two lines of output, the second selected: Copy copies it.
        view.feed(text: "\u{1b}[2J\u{1b}[H")
        view.feed(text: "https://example.com/docs\r\n  see src/notes.txt:3 here\r\nmenu marker line\r\n")
        let terminal = view.getTerminal()
        let top = terminal.buffer.yDisp
        view.selection.setSelection(start: Position(col: 0, row: top + 2), end: Position(col: 16, row: top + 2))
        let selected = w.terminalMenu(for: tab, link: nil)
        NSPasteboard.general.clearContents()
        let copied = run("Copy", in: selected) ? NSPasteboard.general.string(forType: .string) : nil
        check(copied?.trimmingCharacters(in: .whitespaces) == "menu marker line", "menus: Copy copies the terminal's selection", copied ?? "nothing")

        // The link under the pointer, found as ⌘-click finds it.
        let size = view.getOptimalFrameSize()
        func point(row: Int, col: Int) -> NSPoint {
            let cellHeight = size.height / CGFloat(terminal.rows)
            let cellWidth = size.width / CGFloat(terminal.cols)
            return NSPoint(x: (CGFloat(col) + 0.5) * cellWidth, y: view.frame.height - (CGFloat(row) + 0.5) * cellHeight)
        }
        let url = view.link(at: point(row: 0, col: 4))
        check(url == "https://example.com/docs", "menus: a right-click finds the link under the pointer", url ?? "none")
        let web = w.terminalMenu(for: tab, link: url)
        check(titles(web).prefix(2) == ["Open Link", "Copy Link"], "menus: a link adds Open Link and Copy Link", titles(web).joined(separator: ", "))
        check(run("Copy Link", in: web) && NSPasteboard.general.string(forType: .string) == "https://example.com/docs", "menus: Copy Link copies it")
        view.lastClickPoint = point(row: 1, col: 8)
        let path = view.link(at: point(row: 1, col: 8))
        let file = w.terminalMenu(for: tab, link: path)
        check(titles(file).prefix(2) == ["Open “notes.txt”", "Reveal in Finder"], "menus: a path adds Open and Reveal in Finder",
              (path ?? "no path") + ": " + titles(file).joined(separator: ", "))
        if run("Open “notes.txt”", in: file), await wait(3, { w.editorArea.activeEditor?.document.name == "notes.txt" }), let editor = w.editorArea.activeEditor {
            let line = editor.document.lines.line(at: editor.textView.selectedRange().location) + 1
            check(line == 3, "menus: Open opens the file at its line, as ⌘-click does", "line \(line)")
            w.editorArea.close(editor)
        } else {
            check(false, "menus: Open opens the file in the editor", w.editorArea.activeName ?? "nothing open")
        }
        let remoteStyle = w.terminalMenu(for: tab, link: "custom-app://do-something")
        check(titles(remoteStyle).first == "Copy", "menus: a link ⌘-click would refuse (another scheme) adds nothing")

        // Select All, Clear, Split Right from the menu.
        _ = run("Select All", in: w.terminalMenu(for: tab, link: nil))
        check(view.selectionActive, "menus: Select All selects the terminal's text")
        view.feed(text: "clear me\r\n")
        _ = run("Clear", in: w.terminalMenu(for: tab, link: nil))
        check(await wait(3) { !tab.screenTail(40).joined().contains("clear me") }, "menus: Clear empties the terminal",
              tab.screenTail(3).joined(separator: " | "))
        let group = w.group(of: tab)
        _ = run("Split Right", in: w.terminalMenu(for: tab, link: nil))
        check(group?.panes.count == 2, "menus: Split Right splits the pane clicked")
        if let pane = group?.panes.first(where: { $0 !== tab }) { w.remove(pane) }

        await sendSelectionChecks(w, tab: tab, folder: folder)
    }

    /// Send Selection to Agent: only with a selection and an agent; the text reaches the agent's prompt as
    /// a quote, Enter not pressed.
    private static func sendSelectionChecks(_ w: TerminalWindowController, tab: TerminalTab, folder: URL) async {
        let view = tab.view
        let fakeBin = folder.appendingPathComponent("bin")
        try? FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(at: fakeBin.appendingPathComponent("claude"), withDestinationURL: URL(fileURLWithPath: "/bin/cat"))
        let agent = w.addTab(directory: folder.path)
        _ = await wait(20) { agent.status.integrated }
        // cat's output goes nowhere (it would echo the paste markers); the tty's echo shows what it was given.
        agent.view.send(txt: "\u{15}PATH=\(fakeBin.path):$PATH claude >/dev/null\r")
        _ = await wait(5) { agent.status.running && agent.status.kind == .agent }
        w.show(tab)
        view.selectNone()
        check(!titles(w.terminalMenu(for: tab, link: nil)).contains("Send Selection to Agent"), "menus: no Send Selection to Agent with nothing selected")
        view.feed(text: "\u{1b}[2J\u{1b}[Hsend me one\r\nsend me two\r\n")
        let top = view.getTerminal().buffer.yDisp
        view.selection.setSelection(start: Position(col: 0, row: top), end: Position(col: 11, row: top + 1))
        let menu = w.terminalMenu(for: tab, link: nil)
        check(w.agentTab === agent && titles(menu).last == "Send Selection to Agent", "menus: Send Selection to Agent with a selection and an agent",
              titles(menu).joined(separator: ", "))
        agent.view.feed(text: "\u{1b}[?2004h") // the agent takes pastes, as agents do
        _ = run("Send Selection to Agent", in: menu)
        func quoted() -> Bool {
            let rows = agent.screenTail(10)
            guard let at = rows.firstIndex(where: { $0.hasSuffix("send me one") }), rows.indices.contains(at + 1) else { return false }
            return rows[at + 1] == "send me two" && rows[..<at].joined().contains("```text")
        }
        check(await wait(4) { quoted() }, "menus: the selection reaches the agent as a quote, line by line", agent.screenTail(6).joined(separator: " | "))
        check(w.activeTab === agent && w.window?.firstResponder === agent.view, "menus: and the agent's tab takes the keyboard")
        agent.view.feed(text: "\u{1b}[?2004l")
        // ⌥⌘K does the same from a terminal with a selection.
        w.show(tab)
        view.selection.setSelection(start: Position(col: 0, row: top), end: Position(col: 11, row: top))
        let sendItem = NSMenuItem(title: "Send to Agent", action: #selector(TerminalWindowController.sendToAgent(_:)), keyEquivalent: "")
        check(w.validateMenuItem(sendItem), "menus: Edit › Send to Agent is on in a terminal with a selection")
        view.selectNone()
        check(!w.validateMenuItem(sendItem), "menus: and off without one")
        agent.view.send(txt: "\u{03}")
        _ = await wait(3) { !agent.status.running }
        w.remove(agent)
    }

    // MARK: terminal tabs

    private static func tabMenuChecks(_ w: TerminalWindowController, folder: URL) async {
        guard let window = w.window, let first = w.tabs.first, let firstGroup = w.group(of: first) else { return }
        let alone = w.terminalTabMenu(at: 0) ?? NSMenu()
        check(titles(alone) == ["Rename…", "Split Right", "Split Down", "Duplicate Tab", "Close Tab", "Close Other Tabs", "Close Tabs to the Right"],
              "menus: a terminal tab's menu", titles(alone).joined(separator: ", "))
        let others = alone.items.first { $0.title == "Close Other Tabs" }
        let right = alone.items.first { $0.title == "Close Tabs to the Right" }
        check(others?.isEnabled == false && right?.isEnabled == false, "menus: with one tab there are no others to close")
        check(w.tabBar.menu(forTabAt: 0) != nil && w.editorArea.tabBar.menu(forTabAt: 0) == nil, "menus: the tab bar asks its delegate for a tab's menu")
        commandsMatchTheMenuBar(alone, "a terminal tab")

        // Duplicate: a new tab next to it, in its folder.
        _ = run("Duplicate Tab", in: alone)
        guard w.groups.count == 2, let copy = w.groups[1].panes.first else { return check(false, "menus: Duplicate Tab opens a tab") }
        _ = await wait(20) { copy.status.integrated }
        check(canonicalPath(copy.currentDirectory()) == canonicalPath(folder.path) && w.activeIndex == 1,
              "menus: Duplicate Tab opens a tab beside it, in its folder", copy.currentDirectory())
        // Rename acts on the tab clicked, not the one in front: the name typed is the clicked tab's.
        _ = run("Rename…", in: w.terminalTabMenu(at: 0) ?? NSMenu())
        let field = window.firstResponder as? NSTextView
        let inClicked = field?.isDescendant(of: w.tabBar.tabView(at: 0) ?? NSView()) == true
        field?.insertText("Renamed here", replacementRange: field?.selectedRange() ?? NSRange(location: 0, length: 0))
        window.makeFirstResponder(nil)
        check(inClicked && w.activeIndex == 1 && first.userTitle == "Renamed here" && copy.userTitle == nil,
              "menus: Rename… edits the name of the tab clicked", "\(first.userTitle ?? "no name"), \(copy.userTitle ?? "no name")")
        first.userTitle = nil
        // Split from a tab not in front: that tab comes forward, split.
        w.select(0)
        _ = run("Split Down", in: w.terminalTabMenu(at: 1) ?? NSMenu())
        check(w.activeIndex == 1 && w.groups[1].panes.count == 2, "menus: Split Down splits the tab clicked")

        // Close Other Tabs asks once when one of them is busy, as closing it alone would.
        let last = w.addTab(directory: folder.path)
        _ = await wait(20) { last.status.integrated }
        first.userTitle = "Reopen me"
        first.view.send(txt: "\u{15}sleep 30\r")
        _ = await wait(5) { first.status.running }
        guard let lastIndex = w.groups.firstIndex(where: { $0.contains(last) }) else { return }
        _ = run("Close Other Tabs", in: w.terminalTabMenu(at: lastIndex) ?? NSMenu())
        let asked = await wait(3) { window.attachedSheet != nil }
        let words = sheetText(window)
        check(asked && words.contains("Close 2 tabs?") && words.contains("sleep 30"), "menus: Close Other Tabs asks once, naming what would stop", words)
        _ = await press("Cancel", inSheetOf: window)
        check(w.groups.count == 3, "menus: Cancel closes nothing")
        _ = run("Close Other Tabs", in: w.terminalTabMenu(at: lastIndex) ?? NSMenu())
        _ = await wait(3) { window.attachedSheet != nil }
        _ = await press("Close Tabs", inSheetOf: window)
        check(await wait(3) { w.groups.count == 1 && w.tabs.first === last }, "menus: Close Tabs closes the others, the one clicked stays")
        check(!w.groups.contains { $0 === firstGroup }, "menus: with all their panes")

        // Reopen Closed Tab: the busy tab, by its folder and name, with a fresh shell.
        let reopenItem = NSMenuItem(title: "Reopen Closed Tab", action: #selector(TerminalWindowController.reopenClosedTab(_:)), keyEquivalent: "")
        check(w.validateMenuItem(reopenItem) && ClosedTabs.entries.last?.title == "Reopen me",
              "menus: the closed tab is remembered (the panes nothing ran in are not)", ClosedTabs.entries.last?.title ?? "none")
        w.reopenClosedTab(nil)
        guard let again = w.tabs.first(where: { $0 !== last }) else { return check(false, "menus: Reopen Closed Tab opens a tab") }
        _ = await wait(20) { again.status.integrated }
        check(again.userTitle == "Reopen me" && canonicalPath(again.currentDirectory()) == canonicalPath(folder.path) && !again.status.running,
              "menus: Reopen Closed Tab brings back its folder and name, not what ran", "\(again.userTitle ?? "no name") \(again.currentDirectory())")

        // Close Tabs to the Right, from the first tab; Close Tab, from one not in front.
        _ = run("Close Tabs to the Right", in: w.terminalTabMenu(at: 0) ?? NSMenu())
        check(await wait(3) { w.groups.count == 1 && w.tabs.first === last && !w.tabs.contains { $0 === again } },
              "menus: Close Tabs to the Right closes the tabs after the one clicked")
        let extra = w.addTab(directory: folder.path)
        _ = await wait(20) { extra.status.integrated } // a shell still starting up may have children to warn about
        w.select(0)
        _ = run("Close Tab", in: w.terminalTabMenu(at: 1) ?? NSMenu())
        check(await wait(3) { w.groups.count == 1 && !w.tabs.contains { $0 === extra } }, "menus: Close Tab closes the tab clicked")
    }

    // MARK: editor tabs

    private static func editorTabMenuChecks(_ c2: TerminalWindowController, folder: URL) async {
        guard let window = c2.window else { return }
        let area = c2.editorArea
        for name in ["a.txt", "b.txt", "c.txt"] { c2.openFile(folder.appendingPathComponent(name)) }
        guard area.panes.count == 3, let a = area.panes.first, let b = area.editors.first(where: { $0.document.name == "b.txt" }) else {
            return check(false, "menus: three files open", "\(area.panes.count)")
        }
        let menu = c2.editorTabMenu(at: 0) ?? NSMenu()
        check(titles(menu) == ["Close", "Close Others", "Close Tabs to the Right", "Show in Project Sidebar", "Copy Path", "Copy Relative Path", "Reveal in Finder"],
              "menus: an editor tab's menu", titles(menu).joined(separator: ", "))
        commandsMatchTheMenuBar(menu, "an editor tab")
        let close = menu.items.first { $0.title == "Close" }
        check(close?.keyEquivalent == "w" && close?.keyEquivalentModifierMask == .command, "menus: and shows the keys, ⌘W for Close")
        let aPath = canonicalPath(folder.appendingPathComponent("a.txt").path)
        _ = run("Copy Path", in: menu)
        check(canonicalPath(NSPasteboard.general.string(forType: .string) ?? "") == aPath, "menus: Copy Path copies the tab's file, not the one in front",
              NSPasteboard.general.string(forType: .string) ?? "nothing")
        _ = run("Copy Relative Path", in: menu)
        check(NSPasteboard.general.string(forType: .string) == "a.txt", "menus: Copy Relative Path copies it from the sidebar's folder",
              NSPasteboard.general.string(forType: .string) ?? "nothing")
        let sidebarWasVisible = c2.isSidebarVisible
        if sidebarWasVisible { c2.toggleProjectSidebar(nil) }
        _ = run("Show in Project Sidebar", in: menu)
        let revealed = await wait(5) { c2.sidebar.selection.map { canonicalPath($0.url.path) } == [aPath] }
        check(c2.isSidebarVisible && revealed, "menus: Show in Project Sidebar brings the sidebar back, the tab's file selected in it",
              c2.sidebar.selection.map(\.url.lastPathComponent).joined(separator: ", "))
        if !sidebarWasVisible { c2.toggleProjectSidebar(nil) } // as it was (the setting is the user's)

        // Close Others asks once about the unsaved file among them, and the agent's proposal it would reject.
        b.textView.insertText("edited ", replacementRange: NSRange(location: 0, length: 0))
        check(b.document.isDirty, "menus: a file with unsaved changes")
        let proposal = openProposal(in: area, folder: folder)
        func menuOfA() -> NSMenu { area.panes.firstIndex { $0 === a }.flatMap { c2.editorTabMenu(at: $0) } ?? NSMenu() }
        _ = run("Close Others", in: menuOfA())
        let asked = await wait(3) { window.attachedSheet != nil }
        let words = sheetText(window)
        check(asked && words.contains("Save changes to “b.txt” before closing?") && words.contains("Closing rejects the changes Self-test proposes to “c.txt”."),
              "menus: Close Others asks about the unsaved file and the proposal it would reject", words)
        _ = await press("Cancel", inSheetOf: window)
        let kept = await wait(3) { window.attachedSheet == nil }
        check(kept && area.panes.count == 4 && b.document.isDirty && !proposal.isDecided, "menus: Cancel closes nothing and rejects nothing",
              "\(area.panes.count) open")
        let bFile = folder.appendingPathComponent("b.txt")
        func bOnDisk() -> String { (try? String(contentsOf: bFile, encoding: .utf8)) ?? "" }
        _ = run("Close Others", in: menuOfA())
        _ = await wait(3) { window.attachedSheet != nil }
        _ = await press("Save", inSheetOf: window)
        check(await wait(3) { area.panes.count == 1 && area.panes.first === a } && bOnDisk() == "edited one\ntwo\nthree\n" && proposal.isDecided,
              "menus: Save saves the file, then closes the others, rejecting the proposal", "\(area.panes.count) open, b.txt: \(bOnDisk())")

        // Close Tabs to the Right with only a proposal there still asks, naming it.
        let another = openProposal(in: area, folder: folder)
        _ = run("Close Tabs to the Right", in: menuOfA())
        _ = await wait(3) { window.attachedSheet != nil }
        let rightWords = sheetText(window)
        check(rightWords.contains("Close “c.txt ✻ Self-test”?") && rightWords.contains("Closing rejects the changes Self-test proposes"),
              "menus: closing an agent's proposal among others asks first", rightWords)
        _ = await press("Close Tab", inSheetOf: window)
        check(await wait(3) { area.panes.count == 1 } && another.isDecided, "menus: Close Tab closes it, rejecting it")

        // Don't Save closes the others and leaves the file as it was on disk.
        c2.openFile(bFile)
        if let again = area.editors.first(where: { $0.document.name == "b.txt" }) {
            again.textView.insertText("again ", replacementRange: NSRange(location: 0, length: 0))
        }
        _ = run("Close Others", in: menuOfA())
        let askedAgain = await wait(3) { window.attachedSheet != nil }
        check(askedAgain && !sheetText(window).contains("rejects"), "menus: with no proposal among them, it asks about the file alone", sheetText(window))
        _ = await press("Don’t Save", inSheetOf: window)
        check(await wait(3) { area.panes.count == 1 && area.panes.first === a } && bOnDisk() == "edited one\ntwo\nthree\n",
              "menus: Don’t Save closes the others, the tab clicked stays, the file as it was", "\(area.panes.count) open, b.txt: \(bOnDisk())")
        let alone = c2.editorTabMenu(at: 0) ?? NSMenu()
        check(alone.items.first { $0.title == "Close Others" }?.isEnabled == false, "menus: one file has no others to close")
        _ = run("Close", in: alone)
        check(await wait(3) { area.panes.isEmpty }, "menus: Close closes the file")
    }

    /// An agent's proposed change to c.txt, open in the editor.
    private static func openProposal(in area: EditorArea, folder: URL) -> DiffPane {
        let path = canonicalPath(folder.appendingPathComponent("c.txt").path)
        let proposal = DiffPane.Proposal(original: "one\ntwo\nthree\n", proposed: "one\n2\nthree\n", author: "Self-test", tag: "close-others", client: nil)
        return area.openProposal(for: path, proposal: proposal) { _, _ in }
    }

    // MARK: a window opened for one tab

    /// A window opened for a tab (a saved server, ⇧⌘T with no window) closes the shell it starts with: only
    /// that one, only while the window holds just the two, and only while nothing ran in it.
    private static func firstShellChecks(folder: URL) async {
        let app = AppDelegate.shared!
        let x = app.openWindow(directory: folder.path)
        guard x.tabs.count == 1 else { return check(false, "menus: a new window starts with one shell", "\(x.tabs.count) tabs") }
        let first = x.addTab(directory: folder.path)
        app.closeFirstShell(of: x, keeping: first)
        check(x.tabs.count == 1 && x.tabs.first === first, "menus: a new window's first shell makes way for the tab it was opened for")
        _ = await wait(20) { first.status.integrated }
        let middle = x.addTab(directory: folder.path)
        let last = x.addTab(directory: folder.path)
        app.closeFirstShell(of: x, keeping: last)
        check(x.tabs.count == 3, "menus: a window with more tabs than that keeps them all", "\(x.tabs.count) tabs")
        x.remove(middle)
        first.view.send(txt: "\u{15}true\r")
        _ = await wait(5) { first.status.commandsStarted > 0 }
        app.closeFirstShell(of: x, keeping: last)
        check(x.tabs.count == 2 && x.tabs.first === first, "menus: and a first shell something ran in stays",
              "\(x.tabs.count) tabs, \(first.status.commandsStarted) commands run")
        for tab in x.tabs { x.remove(tab) }
        _ = await wait(3) { !app.controllers.contains { $0 === x } }
        if app.controllers.contains(where: { $0 === x }) { x.window?.close() }
    }

    // MARK: tooltips

    /// A tooltip that names a key follows the key Settings gives its command, and shows none without one.
    private static func tooltipRemapChecks(_ c: TerminalWindowController) async {
        let shortcuts = KeyboardShortcuts.shared
        let saved = UserDefaults.standard.data(forKey: "keyBindings")
        defer {
            UserDefaults.standard.set(saved, forKey: "keyBindings")
            shortcuts.apply()
        }
        let id = "toggleTerminalCollapsed:"
        shortcuts.set(KeyChord(key: "j", command: true, control: true), for: id)
        check(c.terminalRail.toolTip == "Expand the terminal (⌃⌘J)", "tooltips: the rail's follows a new key", c.terminalRail.toolTip ?? "none")
        shortcuts.set(nil, for: id)
        check(c.terminalRail.toolTip == "Expand the terminal", "tooltips: and names none when the command has none", c.terminalRail.toolTip ?? "none")
        shortcuts.reset(id)
        check(c.terminalRail.toolTip == "Expand the terminal (⌘J)", "tooltips: and back", c.terminalRail.toolTip ?? "none")
        let closeOthers = "closeOtherTabs:"
        shortcuts.set(KeyChord(key: "w", command: true, option: true, control: true), for: closeOthers)
        let shown = c.terminalTabMenu(at: 0)?.items.first { $0.title == "Close Other Tabs" }
        check(shown?.keyEquivalent == "w" && shown?.keyEquivalentModifierMask == [.command, .option, .control],
              "menus: a key given in Settings shows in the right-click menus")
        shortcuts.reset(closeOthers)
    }

    // MARK: the Welcome window

    /// Last, after the Welcome reopen checks: with only the Welcome window open, ⌥⌘T and Connect to Server…
    /// bring the remote sheet over it (Cancel leaves it as it was), a saved host is a click from a window
    /// with a tab on it, and ⇧⌘T reopens a closed tab in a window of its own.
    static func welcomeRemoteChecks() async {
        let app = AppDelegate.shared!
        for controller in app.controllers { controller.window?.close() }
        app.showWelcome(nil)
        let alone = await wait(5) { app.controllers.isEmpty && app.welcomeController?.window?.isVisible == true }
        guard alone, let welcome = app.welcomeController, let welcomeWindow = welcome.window else {
            return check(false, "welcome: only the Welcome window is open for the remote checks", "\(app.controllers.count) windows")
        }
        let savedHosts = RemoteHosts.all
        let savedLast = UserDefaults.standard.string(forKey: "lastRemoteHost")
        defer {
            RemoteHosts.all = savedHosts
            UserDefaults.standard.set(savedLast, forKey: "lastRemoteHost")
        }
        let host = RemoteHost(name: "selftest-welcome", destination: "nt@selftest.invalid", directory: "~", keep: .off)
        RemoteHosts.save(host)
        UserDefaults.standard.set(host.id, forKey: "lastRemoteHost")
        app.showWelcome(nil)
        check(welcome.shownServers.first == "selftest-welcome", "welcome: saved hosts are listed, the one used last first", welcome.shownServers.joined(separator: ", "))
        let button = welcome.connectServerButton
        let key = KeyboardShortcuts.shared.chord(for: "newRemoteTab:").map { " (\($0.display))" } ?? ""
        let tip = "Open a tab on one of your servers, over ssh" + key
        let wired = button.action == #selector(AppDelegate.newRemoteTab(_:))
        check(button.title == "Connect to Server…" && wired && button.toolTip == tip,
              "welcome: Connect to Server…, its tooltip naming its key", button.toolTip ?? "no tooltip")

        let target = NSApp.target(forAction: #selector(TerminalWindowController.newRemoteTab(_:)), to: nil, from: nil) as AnyObject?
        check(target === app, "welcome: ⌥⌘T reaches Next Term with only the Welcome window open", target.map { "\(type(of: $0))" } ?? "nothing")
        // The menu-bar item itself is on, as AppKit validates it before ⌥⌘T can choose it.
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
        let remoteItem = items(NSApp.mainMenu ?? NSMenu()).first { $0.action == #selector(TerminalWindowController.newRemoteTab(_:)) }
        remoteItem?.menu?.update()
        check(remoteItem?.isEnabled == true, "welcome: Shell › New Remote Tab… is on with only the Welcome window open", remoteItem?.title ?? "no such item")
        NSApp.sendAction(#selector(TerminalWindowController.newRemoteTab(_:)), to: nil, from: nil)
        check(await wait(3) { welcomeWindow.attachedSheet?.title == "New Remote Tab" }, "welcome: ⌥⌘T brings the remote sheet over the Welcome window")
        _ = await press("Cancel", inSheetOf: welcomeWindow)
        check(await wait(3) { welcomeWindow.attachedSheet == nil } && app.controllers.isEmpty && welcomeWindow.isVisible,
              "welcome: Cancel leaves the Welcome window as it was, with no window opened")
        button.performClick(nil)
        check(await wait(3) { welcomeWindow.attachedSheet?.title == "New Remote Tab" }, "welcome: so does Connect to Server…")
        _ = await press("Cancel", inSheetOf: welcomeWindow)
        _ = await wait(3) { welcomeWindow.attachedSheet == nil }

        #if DEBUG
        // A click on the saved host: a window with a tab on it, alone. A stand-in ssh that only waits.
        let standIn = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nt-welcome-ssh-\(getpid())")
        try? "#!/bin/sh\nexec sleep 30\n".write(to: standIn, atomically: true, encoding: .utf8)
        chmod(standIn.path, 0o755)
        RemoteConnection.testSSHPath = standIn.path
        defer {
            RemoteConnection.testSSHPath = nil
            try? FileManager.default.removeItem(at: standIn)
        }
        welcome.serverEntry(at: 0)?.performClick(nil)
        let opened = await wait(5) { app.controllers.count == 1 && app.controllers[0].tabs.count == 1 }
        let remote = app.controllers.first?.tabs.first?.remote
        check(opened && remote?.host.id == host.id && !welcomeWindow.isVisible, "welcome: a saved host opens a window with a tab on it, alone",
              "\(app.controllers.count) windows, \(app.controllers.first?.tabs.count ?? 0) tabs, host \(remote?.host.name ?? "none")")
        if let w = app.controllers.first {
            for tab in w.tabs { w.remove(tab) }
        }
        let back = await wait(5) { app.controllers.isEmpty && welcomeWindow.isVisible }
        // ⇧⌘T with only the Welcome window: the remote tab just closed, in a window of its own.
        let reopenTarget = NSApp.target(forAction: #selector(TerminalWindowController.reopenClosedTab(_:)), to: nil, from: nil) as AnyObject?
        if back, reopenTarget === app {
            NSApp.sendAction(#selector(TerminalWindowController.reopenClosedTab(_:)), to: nil, from: nil)
            let reopened = await wait(5) { app.controllers.count == 1 && app.controllers[0].tabs.count == 1 }
            check(reopened && app.controllers.first?.tabs.first?.remote?.host.id == host.id,
                  "welcome: ⇧⌘T reopens the closed tab in a window of its own", "\(app.controllers.first?.tabs.count ?? 0) tabs")
            if let w = app.controllers.first {
                for tab in w.tabs { w.remove(tab) }
            }
            _ = await wait(5) { app.controllers.isEmpty }
        } else {
            check(false, "welcome: ⇧⌘T reaches Next Term with only the Welcome window open", "back \(back)")
        }
        #else
        note("welcome: a saved host's entry needs a debug build (the stand-in ssh is debug-only)")
        #endif
    }

    // MARK: sheets

    private static func sheetText(_ window: NSWindow) -> String {
        func fields(_ view: NSView) -> [String] { view.subviews.flatMap { ($0 as? NSTextField).map { [$0.stringValue] } ?? fields($0) } }
        return window.attachedSheet?.contentView.map(fields)?.joined(separator: " ") ?? ""
    }

    private static func press(_ title: String, inSheetOf window: NSWindow) async -> Bool {
        func buttons(_ view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) } }
        guard await wait(5, { window.attachedSheet?.contentView.map(buttons)?.contains { $0.title == title } == true }),
              let button = window.attachedSheet?.contentView.map(buttons)?.first(where: { $0.title == title }) else { return false }
        button.performClick(nil)
        return true
    }
}
